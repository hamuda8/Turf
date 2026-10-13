//! Merchant webhooks (src/services/webhooks.js): every public shipment change is POSTed to the
//! merchant's endpoint, signed with HMAC-SHA256, and retried with exponential backoff.
//!
//! Signature header:  Turf-Signature: t=<unix seconds>,v1=<hex hmac of "<t>.<raw body>">

const std = @import("std");
const Io = std.Io;
const val = @import("mongo").val;
const db = @import("../lib/db.zig");
const web = @import("../web.zig");
const a_ = @import("../app.zig");
const crypto = @import("../crypto.zig");
const messages = @import("../messages.zig");
const audit = @import("audit.zig");
const shipments = @import("shipments.zig");
const bus = @import("../bus.zig");
const Val = val.Val;
const Req = web.Req;

const backoff_minutes = [_]i64{ 1, 5, 30, 120, 360, 720, 1440 };
const max_attempts = backoff_minutes.len + 1;
const timeout_ms = 10_000;

// ---- Configuration ------------------------------------------------------------------------------

pub fn setWebhook(r: *Req, ctx: *const web.OrgCtx, url: []const u8) !Val {
    const a = r.a;
    if (a_.cfg().is_production) try assertPublicHost(r, url);
    const secret = try std.fmt.allocPrint(a, "whsec_{s}", .{try crypto.randomToken(a, 24)});
    const existing = ctx.org.path("merchant.webhook");
    // Keep the existing secret when only the URL changes, so receivers don't break.
    const sealed: []const u8 = if (existing.s("secretSealed")) |s| (if (s.len > 0) s else try crypto.encrypt(a, secret)) else try crypto.encrypt(a, secret);
    const webhook = try val.from(a, .{ .url = url, .secretSealed = sealed, .enabled = true, .updatedAt = a_.now() });
    _ = try db.col("orgs").updateOne(a, .{ ._id = ctx.org.get("_id") }, .{ .@"$set" = .{ .@"merchant.webhook" = webhook } }, .{});
    audit.audit(a, ctx.org.get("_id"), ctx.member, "webhook.updated", .{ .url = url });
    return val.from(a, .{ .url = url, .enabled = true, .secret = try crypto.decrypt(a, sealed) });
}

pub fn rotateWebhookSecret(r: *Req, ctx: *const web.OrgCtx) ![]const u8 {
    if (!ctx.org.path("merchant.webhook").truthy()) return r.badRequest("Set a webhook URL first", null, "webhook_first", null);
    const secret = try std.fmt.allocPrint(r.a, "whsec_{s}", .{try crypto.randomToken(r.a, 24)});
    _ = try db.col("orgs").updateOne(r.a, .{ ._id = ctx.org.get("_id") }, .{ .@"$set" = .{ .@"merchant.webhook.secretSealed" = try crypto.encrypt(r.a, secret) } }, .{});
    audit.audit(r.a, ctx.org.get("_id"), ctx.member, "webhook.secret_rotated", .{});
    return secret;
}

pub fn deleteWebhook(r: *Req, ctx: *const web.OrgCtx) !void {
    _ = try db.col("orgs").updateOne(r.a, .{ ._id = ctx.org.get("_id") }, .{ .@"$set" = .{ .@"merchant.webhook" = null } }, .{});
    audit.audit(r.a, ctx.org.get("_id"), ctx.member, "webhook.deleted", .{});
}

pub fn webhookView(a: std.mem.Allocator, org: Val) !Val {
    const w = org.path("merchant.webhook");
    if (!w.truthy()) return .null;
    return val.from(a, .{ .url = w.get("url"), .enabled = w.get("enabled"), .secret = try crypto.decrypt(a, w.s("secretSealed") orelse "") });
}

pub fn recentDeliveries(a: std.mem.Allocator, org_id: Val) ![]Val {
    return db.col("webhook_deliveries").find(a, .{ .orgId = org_id }, .{
        .projection = try val.from(a, .{ .payload = 0 }),
        .sort = try val.from(a, .{ .createdAt = -1 }),
        .limit = 50,
    });
}

// ---- SSRF protection ----------------------------------------------------------------------------
// In production webhooks may only reach public addresses.

const blocked_v4 = [_]struct { base: [4]u8, bits: u5 }{
    .{ .base = .{ 0, 0, 0, 0 }, .bits = 8 },      .{ .base = .{ 10, 0, 0, 0 }, .bits = 8 },     .{ .base = .{ 100, 64, 0, 0 }, .bits = 10 },
    .{ .base = .{ 127, 0, 0, 0 }, .bits = 8 },    .{ .base = .{ 169, 254, 0, 0 }, .bits = 16 }, .{ .base = .{ 172, 16, 0, 0 }, .bits = 12 },
    .{ .base = .{ 192, 0, 0, 0 }, .bits = 24 },   .{ .base = .{ 192, 0, 2, 0 }, .bits = 24 },   .{ .base = .{ 192, 88, 99, 0 }, .bits = 24 },
    .{ .base = .{ 192, 168, 0, 0 }, .bits = 16 }, .{ .base = .{ 198, 18, 0, 0 }, .bits = 15 },  .{ .base = .{ 198, 51, 100, 0 }, .bits = 24 },
    .{ .base = .{ 203, 0, 113, 0 }, .bits = 24 }, .{ .base = .{ 224, 0, 0, 0 }, .bits = 4 },    .{ .base = .{ 240, 0, 0, 0 }, .bits = 4 },
};

fn parseV4(s: []const u8) ?u32 {
    var it = std.mem.splitScalar(u8, s, '.');
    var n: u32 = 0;
    var parts: usize = 0;
    while (it.next()) |p| {
        if (p.len == 0 or p.len > 3) return null;
        // net.isIPv4 rejects leading zeros ("01").
        if (p.len > 1 and p[0] == '0') return null;
        const x = std.fmt.parseInt(u8, p, 10) catch return null;
        n = (n << 8) | x;
        parts += 1;
    }
    return if (parts == 4) n else null;
}

fn isV6(s: []const u8) bool {
    if (std.mem.indexOfScalar(u8, s, ':') == null) return false;
    _ = Io.net.Ip6Address.parse(s, 0) catch return false;
    return true;
}

pub fn isPrivateIp(ip: []const u8) bool {
    if (parseV4(ip)) |n| {
        for (blocked_v4) |range| {
            const base = std.mem.readInt(u32, &range.base, .big);
            const shift: u5 = @intCast(32 - @as(u6, range.bits));
            if ((n >> shift) == (base >> shift)) return true;
        }
        return false;
    }
    if (!isV6(ip)) return true;
    var buf: [64]u8 = undefined;
    const lower = std.ascii.lowerString(buf[0..@min(ip.len, 64)], ip[0..@min(ip.len, 64)]);
    // IPv6 forms that embed an IPv4 address: mapped, compatible, NAT64.
    if (std.mem.lastIndexOfScalar(u8, lower, ':')) |c| if (parseV4(lower[c + 1 ..]) != null) {
        return std.mem.startsWith(u8, lower, "::") or std.mem.startsWith(u8, lower, "64:ff9b:") or isPrivateIp(lower[c + 1 ..]);
    };
    if (std.mem.startsWith(u8, lower, "::ffff:") or std.mem.startsWith(u8, lower, "64:ff9b:")) return true;
    const first_s = lower[0 .. std.mem.indexOfScalar(u8, lower, ':') orelse lower.len];
    const first: u32 = if (first_s.len == 0) 0 else std.fmt.parseInt(u32, first_s, 16) catch 0;
    return std.mem.eql(u8, lower, "::") or std.mem.eql(u8, lower, "::1") or
        (first & 0xfe00) == 0xfc00 or (first & 0xffc0) == 0xfe80 or (first & 0xffc0) == 0xfec0 or (first & 0xff00) == 0xff00 or
        std.mem.startsWith(u8, lower, "2001:db8:") or std.mem.startsWith(u8, lower, "100::");
}

fn isIp(s: []const u8) bool {
    return parseV4(s) != null or isV6(s);
}

/// Every address `host` resolves to (text form), or empty when it does not resolve.
fn resolveAll(a: std.mem.Allocator, host: []const u8) ![]const []const u8 {
    const io = a_.app.io;
    const hn = Io.net.HostName.init(host) catch return &.{};
    var buf: [32]Io.net.HostName.LookupResult = undefined;
    var q: Io.Queue(Io.net.HostName.LookupResult) = .init(&buf);
    hn.lookup(io, &q, .{ .port = 443 }) catch return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    while (q.getOne(io) catch null) |res| switch (res) {
        .address => |addr| try out.append(a, try @import("http").formatIp(a, addr)),
        else => {},
    };
    return out.items;
}

fn hostOf(url: []const u8) ?[]const u8 {
    const u = std.Uri.parse(url) catch return null;
    const h = (u.host orelse return null).percent_encoded;
    return std.mem.trim(u8, h, "[]");
}

fn assertPublicHost(r: *Req, url: []const u8) !void {
    const u = std.Uri.parse(url) catch return r.badRequest("Webhook URLs must use https", "url", "https_only", null);
    if (!std.mem.eql(u8, u.scheme, "https")) return r.badRequest("Webhook URLs must use https", "url", "https_only", null);
    const host = hostOf(url) orelse "";
    const addresses: []const []const u8 = if (isIp(host)) &.{host} else try resolveAll(r.a, host);
    if (addresses.len == 0) return r.badRequest("Webhook host could not be resolved", "url", "host_unresolved", null);
    for (addresses) |ip| if (isPrivateIp(ip)) return r.badRequest("Webhook URLs must point to a public server", "url", "public_only", null);
}

// ---- Delivery -----------------------------------------------------------------------------------

fn enqueue(a: std.mem.Allocator, org_id: Val, kind: []const u8, data: Val) !void {
    const org = try db.col("orgs").findOne(a, .{ ._id = org_id }, .{ .projection = try val.from(a, .{ .@"merchant.webhook" = 1 }) });
    const w = if (org) |o| o.path("merchant.webhook") else Val.undef;
    if (!w.get("enabled").truthy()) return;
    const now = a_.now();
    const id = try db.col("webhook_deliveries").insertOne(a, .{
        .orgId = org_id,
        .type = kind,
        .url = w.get("url"),
        .status = "pending",
        .attempts = 0,
        .nextAttemptAt = now,
        .createdAt = now,
        .payload = null,
    });
    const payload = try val.from(a, .{ .id = try val.toStr(a, id), .type = kind, .createdAt = try val.isoAlloc(a, now.date), .data = data });
    _ = try db.col("webhook_deliveries").updateOne(a, .{ ._id = id }, .{ .@"$set" = .{ .payload = payload } }, .{});
}

/// Sends a test event right away and reports the result.
pub fn sendTest(r: *Req, ctx: *const web.OrgCtx) !Val {
    const w = ctx.org.path("merchant.webhook");
    if (!w.truthy()) return r.badRequest("Set a webhook URL first", null, "webhook_first", null);
    const payload = try val.from(r.a, .{ .id = try std.fmt.allocPrint(r.a, "test_{s}", .{try crypto.randomToken(r.a, 6)}), .type = "ping", .createdAt = try val.isoAlloc(r.a, a_.nowMs()), .data = .{ .message = "Hello from Turf" } });
    return deliver(r.a, w.s("url") orelse "", try crypto.decrypt(r.a, w.s("secretSealed") orelse ""), payload);
}

fn post(a: std.mem.Allocator, url: []const u8, headers: []const std.http.Header, body: []const u8) !Val {
    const host = hostOf(url) orelse "";
    if (a_.cfg().is_production) {
        const u = std.Uri.parse(url) catch return val.from(a, .{ .ok = false, .status = null, .@"error" = "Invalid URL" });
        if (!std.mem.eql(u8, u.scheme, "https")) return val.from(a, .{ .ok = false, .status = null, .@"error" = "Webhook URLs must use https" });
        // The resolved addresses are checked before connecting (Turf-js checks inside the
        // socket's lookup; std.http resolves on its own, so a rebinding window remains).
        const addrs: []const []const u8 = if (isIp(host)) &.{host} else try resolveAll(a, host);
        for (addrs) |ip| if (isPrivateIp(ip)) return val.from(a, .{ .ok = false, .status = null, .@"error" = "Webhook URLs must point to a public server" });
    }
    const res = a_.upstreamTimeout(a, url, .{ .method = .POST, .body = body, .headers = headers, .retry = false, .max_body = 1 << 20, .user_agent = "Turf-Webhooks/1" }, timeout_ms) catch |e| {
        return val.from(a, .{ .ok = false, .status = null, .@"error" = if (e == error.Timeout) "Timed out" else @errorName(e) });
    };
    const st = @backingInt(res.status);
    return val.from(a, .{ .ok = st >= 200 and st < 300, .status = st });
}

fn deliver(a: std.mem.Allocator, url: []const u8, secret: []const u8, payload: Val) !Val {
    const body = try val.toJson(a, payload);
    const t = @divFloor(a_.nowMs(), 1000);
    const signed = try std.fmt.allocPrint(a, "{d}.{s}", .{ t, body });
    return post(a, url, &.{
        .{ .name = "turf-event", .value = payload.s("type") orelse "" },
        .{ .name = "turf-delivery", .value = payload.s("id") orelse "" },
        .{ .name = "turf-signature", .value = try std.fmt.allocPrint(a, "t={d},v1={s}", .{ t, try crypto.hmacHex(a, secret, signed) }) },
    }, body);
}

fn processQueue(a: std.mem.Allocator) !void {
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        const job = (try db.col("webhook_deliveries").findOneAndUpdate(a, .{ .status = "pending", .nextAttemptAt = .{ .@"$lte" = a_.now() }, .payload = .{ .@"$ne" = null } }, .{
            .@"$set" = .{ .status = "sending", .lockedAt = a_.now() },
        }, .{ .sort = try val.from(a, .{ .nextAttemptAt = 1 }), .returnDocument = .after })) orelse return;
        const org = try db.col("orgs").findOne(a, .{ ._id = job.get("orgId") }, .{ .projection = try val.from(a, .{ .@"merchant.webhook" = 1 }) });
        const w = if (org) |o| o.path("merchant.webhook") else Val.undef;
        if (!w.get("enabled").truthy()) {
            _ = try db.col("webhook_deliveries").updateOne(a, .{ ._id = job.get("_id") }, .{ .@"$set" = .{ .status = "skipped" } }, .{});
            continue;
        }
        const result = try deliver(a, w.s("url") orelse "", try crypto.decrypt(a, w.s("secretSealed") orelse ""), job.get("payload"));
        const attempts = (job.n("attempts") orelse 0) + 1;
        const set = try val.from(a, .{ .attempts = attempts, .lastAttemptAt = a_.now(), .lastStatus = result.get("status"), .lastError = if (result.get("error").truthy()) result.get("error") else Val.null });
        if (result.t("ok")) {
            try set.set("status", "delivered");
        } else if (attempts >= max_attempts) {
            try set.set("status", "failed");
        } else {
            try set.set("status", "pending");
            const idx: usize = @intFromFloat(attempts - 1);
            try set.set("nextAttemptAt", val.Date{ .ms = a_.nowMs() + backoff_minutes[idx] * 60_000 });
        }
        _ = try db.col("webhook_deliveries").updateOne(a, .{ ._id = job.get("_id") }, .{ .@"$set" = set }, .{});
    }
}

pub fn onShipmentCreated(r: *Req, e: Val) !void {
    const s = e.get("shipment");
    try enqueue(r.a, s.get("merchantId"), "shipment.created", try val.from(r.a, .{ .shipment = try shipments.merchantView(r.a, s) }));
}

pub fn onShipmentEvent(r: *Req, e: Val) !void {
    const s = e.get("shipment");
    const event = e.get("event");
    const code = event.s("code") orelse "";
    if (event.t("internal") or std.mem.eql(u8, code, "created") or std.mem.eql(u8, code, "carrier_assigned")) return;
    try enqueue(r.a, s.get("merchantId"), "shipment.updated", try val.from(r.a, .{
        .shipment = try shipments.merchantView(r.a, s),
        .event = .{ .code = code, .at = event.get("at"), .textEn = try messages.eventText(r.a, event, "en"), .textAr = try messages.eventText(r.a, event, "ar") },
    }));
}

/// Every 5 s: delivers due webhooks. Run as its own task.
pub fn loop() void {
    {
        var arena = std.heap.ArenaAllocator.init(a_.app.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        // Recover jobs left "sending" by a crash.
        _ = db.col("webhook_deliveries").updateMany(a, .{ .status = "sending", .lockedAt = .{ .@"$lt" = val.Date{ .ms = a_.nowMs() - 5 * 60_000 } } }, .{ .@"$set" = .{ .status = "pending" } }, .{}) catch {};
    }
    while (true) {
        a_.app.io.sleep(.fromSeconds(5), .awake) catch return;
        if (!bus.enabled[@backingInt(bus.Service.webhooks)]) continue;
        var arena = std.heap.ArenaAllocator.init(a_.app.gpa);
        defer arena.deinit();
        processQueue(arena.allocator()) catch |e| std.log.err("Webhook queue failed: {t}", .{e});
    }
}

test isPrivateIp {
    try std.testing.expect(isPrivateIp("10.1.2.3"));
    try std.testing.expect(isPrivateIp("127.0.0.1"));
    try std.testing.expect(!isPrivateIp("8.8.8.8"));
    try std.testing.expect(isPrivateIp("::1"));
    try std.testing.expect(isPrivateIp("::ffff:127.0.0.1"));
    try std.testing.expect(isPrivateIp("fd00::1"));
    try std.testing.expect(!isPrivateIp("2606:4700::1111"));
    try std.testing.expect(isPrivateIp("not an ip"));
}
