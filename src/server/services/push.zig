//! Web Push (src/services/push.js): reaches a phone even when Turf is closed ("tracking paused,
//! tap to resume", new tasks, SOS alerts). Encryption (RFC 8291) and VAPID signing (RFC 8292)
//! come from zig-core's push module; the VAPID key pair lives in settings { _id: 'vapid' } in
//! the same shape Turf-js writes (base64url public key, PKCS#8 PEM private key), so both
//! servers share it.

const std = @import("std");
const Io = std.Io;
const zpush = @import("push");
const val = @import("../lib/val.zig");
const db = @import("../lib/db.zig");
const web = @import("../web.zig");
const a_ = @import("../app.zig");
const permissions = @import("../permissions.zig");
const Val = val.Val;
const Req = web.Req;
const b64url = std.base64.url_safe_no_pad;

/// Push services browsers use; in production subscriptions pointing elsewhere are refused (an
/// endpoint is a URL this server will POST to).
fn allowedPushHost(host: []const u8) bool {
    const exact = [_][]const u8{ "fcm.googleapis.com", "android.googleapis.com", "web.push.apple.com" };
    for (exact) |h| if (std.mem.eql(u8, host, h)) return true;
    const suffixes = [_][]const u8{ ".push.services.mozilla.com", ".notify.windows.com", ".push.apple.com" };
    for (suffixes) |s| if (std.mem.endsWith(u8, host, s)) return true;
    return false;
}

// ---- VAPID keys ---------------------------------------------------------------------------------

var vapid_lock: Io.Mutex = .init;
var vapid_public: ?[]u8 = null;
/// The private scalar, base64url (what zig-core's Vapid takes).
var vapid_private: ?[]u8 = null;

const P256 = std.crypto.ecc.P256;

/// PKCS#8 for a P-256 key the way Node exports it (with the public key).
fn pkcs8Pem(a: std.mem.Allocator, private: [32]u8, public: [65]u8) ![]const u8 {
    const prefix = [_]u8{ 0x30, 0x81, 0x87, 0x02, 0x01, 0x00, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x04, 0x6d, 0x30, 0x6b, 0x02, 0x01, 0x01, 0x04, 0x20 };
    const mid = [_]u8{ 0xa1, 0x44, 0x03, 0x42, 0x00 };
    var der: [prefix.len + 32 + mid.len + 65]u8 = undefined;
    @memcpy(der[0..prefix.len], &prefix);
    @memcpy(der[prefix.len..][0..32], &private);
    @memcpy(der[prefix.len + 32 ..][0..mid.len], &mid);
    @memcpy(der[prefix.len + 32 + mid.len ..], &public);
    const b64 = try a.alloc(u8, std.base64.standard.Encoder.calcSize(der.len));
    _ = std.base64.standard.Encoder.encode(b64, &der);
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "-----BEGIN PRIVATE KEY-----\n");
    var i: usize = 0;
    while (i < b64.len) : (i += 64) {
        try out.appendSlice(a, b64[i..@min(i + 64, b64.len)]);
        try out.append(a, '\n');
    }
    try out.appendSlice(a, "-----END PRIVATE KEY-----\n");
    return out.items;
}

/// The private scalar from a PKCS#8 (or SEC1) PEM: the 32 bytes after INTEGER 1, OCTET STRING 32.
fn privateFromPem(a: std.mem.Allocator, pem: []const u8) ![32]u8 {
    var body: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, pem, '\n');
    while (it.next()) |line| {
        const l = std.mem.trim(u8, line, " \r\t");
        if (l.len == 0 or std.mem.startsWith(u8, l, "-----")) continue;
        try body.appendSlice(a, l);
    }
    const der = try a.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(body.items));
    try std.base64.standard.Decoder.decode(der, body.items);
    const marker = [_]u8{ 0x02, 0x01, 0x01, 0x04, 0x20 };
    const i = std.mem.indexOf(u8, der, &marker) orelse return error.BadKey;
    if (i + marker.len + 32 > der.len) return error.BadKey;
    return der[i + marker.len ..][0..32].*;
}

fn loadVapid(a: std.mem.Allocator) !void {
    const io = a_.app.io;
    const gpa = a_.app.gpa;
    {
        vapid_lock.lockUncancelable(io);
        defer vapid_lock.unlock(io);
        if (vapid_public != null) return;
    }
    var doc = try db.col("settings").findOne(a, .{ ._id = "vapid" }, .{});
    if (doc == null) {
        var private: [32]u8 = undefined;
        const kp = while (true) {
            io.random(&private);
            const s = P256.scalar.Scalar.fromBytes(private, .big) catch continue;
            if (s.isZero()) continue;
            break (P256.basePoint.mul(s.toBytes(.big), .big) catch continue).toUncompressedSec1();
        };
        const pub_b64 = try a.alloc(u8, b64url.Encoder.calcSize(65));
        _ = b64url.Encoder.encode(pub_b64, &kp);
        const fresh = try val.from(a, .{ ._id = "vapid", .publicKey = pub_b64, .privateKeyPem = try pkcs8Pem(a, private, kp), .createdAt = a_.now() });
        _ = db.col("settings").insertOne(a, fresh) catch |e| switch (e) {
            // Another process created it first.
            error.DuplicateKey => {},
            else => return e,
        };
        doc = try db.col("settings").findOne(a, .{ ._id = "vapid" }, .{});
    }
    const d = doc orelse return error.NoVapid;
    const private = try privateFromPem(a, d.s("privateKeyPem") orelse return error.BadKey);
    var priv_b64: [43]u8 = undefined;
    _ = b64url.Encoder.encode(&priv_b64, &private);
    vapid_lock.lockUncancelable(io);
    defer vapid_lock.unlock(io);
    if (vapid_public != null) return;
    vapid_public = try gpa.dupe(u8, d.s("publicKey") orelse return error.BadKey);
    vapid_private = try gpa.dupe(u8, &priv_b64);
}

pub fn publicKey(a: std.mem.Allocator) ![]const u8 {
    try loadVapid(a);
    return vapid_public.?;
}

fn subject() []const u8 {
    const u = a_.cfg().public_url;
    return if (std.mem.startsWith(u8, u, "https:")) u else "mailto:admin@turf.local";
}

/// encryptPayload(plaintext, { p256dh, auth }, { asPrivate, salt }): the aes128gcm body.
pub fn encryptPayload(a: std.mem.Allocator, plaintext: []const u8, p256dh: []const u8, auth: []const u8, as_private: ?[]const u8, salt: ?[]const u8) ![]u8 {
    var fixed: ?zpush.Ephemeral = null;
    if (as_private) |ap| {
        var e: zpush.Ephemeral = undefined;
        try b64url.Decoder.decode(&e.private_key, ap);
        try b64url.Decoder.decode(&e.salt, salt orelse return error.BadKey);
        fixed = e;
    }
    return zpush.encrypt(a, a_.app.io, .{ .endpoint = "", .p256dh = p256dh, .auth = auth }, plaintext, fixed);
}

// ---- Subscriptions ------------------------------------------------------------------------------

fn b64urlLen(s: []const u8) usize {
    const clean = std.mem.trimEnd(u8, s, "=");
    return b64url.Decoder.calcSizeForSlice(clean) catch 0;
}

pub fn saveSubscription(r: *Req, user: Val, sub: Val, user_agent: ?[]const u8) !void {
    if (sub != .obj or sub.get("endpoint") != .str or (sub.get("keys") != .obj and sub.get("keys") != .arr and sub.get("keys") != .null))
        return r.badRequest("Invalid push subscription", "subscription", null, null);
    const endpoint = sub.s("endpoint").?;
    const uri = std.Uri.parse(endpoint) catch return r.badRequest("Invalid push endpoint", "subscription", null, null);
    if (a_.cfg().is_production) {
        const host = if (uri.host) |h| h.percent_encoded else "";
        if (!std.mem.eql(u8, uri.scheme, "https") or !allowedPushHost(host)) return r.badRequest("Unsupported push service", "subscription", null, null);
    }
    const keys = sub.get("keys");
    const p256dh = keys.get("p256dh");
    const auth = keys.get("auth");
    if (p256dh != .str or b64urlLen(p256dh.str) != 65 or auth != .str or b64urlLen(auth.str) != 16)
        return r.badRequest("Invalid push subscription keys", "subscription", null, null);
    _ = try db.col("push_subscriptions").updateOne(r.a, .{ .endpoint = endpoint }, .{
        .@"$set" = .{ .userId = user.get("id"), .keys = .{ .p256dh = p256dh, .auth = auth }, .userAgent = val.jsSlice(user_agent orelse "", 300), .updatedAt = a_.now() },
        .@"$setOnInsert" = .{ .createdAt = a_.now() },
    }, .{ .upsert = true });
}

pub fn removeSubscription(a: std.mem.Allocator, user: Val, endpoint: []const u8) !void {
    _ = try db.col("push_subscriptions").deleteOne(a, .{ .endpoint = endpoint, .userId = user.get("id") });
}

// ---- Sending ------------------------------------------------------------------------------------

pub const SendOpts = struct { ttl: u32 = 3600, extra_query: Val = .undef };

/// Sends `payload` ({ title, body, url, tag, urgent?, requireInteraction? }) to every device of
/// a user; returns how many accepted it. Never fails.
pub fn sendToUser(a: std.mem.Allocator, user_id: anytype, payload: Val) void {
    _ = sendToUserOpts(a, val.from(a, user_id) catch return, payload, .{}) catch |e| std.log.warn("push: {t}", .{e});
}

pub fn sendToUserOpts(a: std.mem.Allocator, user_id: Val, payload: Val, o: SendOpts) !usize {
    const q = try val.spread(a, .{ .{ .userId = user_id }, o.extra_query });
    const subs = try db.col("push_subscriptions").find(a, q, .{});
    if (subs.len == 0) return 0;
    try loadVapid(a);
    const vapid: zpush.Vapid = .{ .public_key = vapid_public.?, .private_key = vapid_private.?, .subject = subject() };
    const plaintext = try val.toJson(a, payload);
    var sent: usize = 0;
    for (subs) |sub| {
        const status = sendOne(a, vapid, sub, plaintext, payload, o.ttl) catch null;
        if (status) |st| {
            if (st == 404 or st == 410) {
                _ = db.col("push_subscriptions").deleteOne(a, .{ ._id = sub.get("_id") }) catch {};
            } else if (st >= 200 and st < 300) sent += 1;
        }
    }
    return sent;
}

fn sendOne(a: std.mem.Allocator, vapid: zpush.Vapid, sub: Val, plaintext: []const u8, payload: Val, ttl: u32) !u16 {
    const endpoint = sub.s("endpoint") orelse return error.BadEndpoint;
    const body = try zpush.encrypt(a, a_.app.io, .{ .endpoint = endpoint, .p256dh = sub.path("keys.p256dh").asStr() orelse "", .auth = sub.path("keys.auth").asStr() orelse "" }, plaintext, null);
    const auth = try zpush.vapidHeader(a, vapid, endpoint, @divFloor(a_.nowMs(), 1000));
    var headers: std.ArrayList(std.http.Header) = .empty;
    try headers.append(a, .{ .name = "authorization", .value = auth });
    try headers.append(a, .{ .name = "content-encoding", .value = "aes128gcm" });
    try headers.append(a, .{ .name = "ttl", .value = try std.fmt.allocPrint(a, "{d}", .{ttl}) });
    try headers.append(a, .{ .name = "urgency", .value = if (payload.t("urgent")) "high" else "normal" });
    if (payload.s("tag")) |tag| if (tag.len > 0) {
        var topic: std.ArrayList(u8) = .empty;
        for (tag) |c| if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-') try topic.append(a, c);
        try headers.append(a, .{ .name = "topic", .value = topic.items[0..@min(topic.items.len, 32)] });
    };
    const res = try a_.upstreamTimeout(a, endpoint, .{ .method = .POST, .body = body, .content_type = "application/octet-stream", .headers = headers.items, .retry = false }, 10_000);
    return @intFromEnum(res.status);
}

/// User ids of active members holding `permission`.
fn membersWith(a: std.mem.Allocator, org_id: Val, org_type: []const u8, permission: []const u8) !Val {
    const members = try db.col("memberships").find(a, .{ .orgId = org_id, .status = "active" }, .{});
    const roles = try db.col("roles").find(a, .{ .orgId = org_id }, .{});
    const out = try val.newArr(a);
    for (members) |m| {
        var role: Val = .undef;
        if (m.get("roleId").truthy()) for (roles) |rl| if (rl.get("_id").sameId(m.get("roleId"))) {
            role = rl;
            break;
        };
        const perms = try permissions.effectivePermissions(a, org_type, m, role);
        if (perms.has(permission)) try out.push(m.get("userId"));
    }
    return out;
}

/// Push to every active member of an org holding `permission`.
pub fn sendToMembersWith(a: std.mem.Allocator, org_id: Val, org_type: []const u8, permission: []const u8, payload: Val, o: SendOpts) !void {
    for ((try membersWith(a, org_id, org_type, permission)).items()) |uid| _ = sendToUserOpts(a, uid, payload, o) catch {};
}

// ---- SOS alerts per device ------------------------------------------------------------------------
// Anyone can switch SOS alerts off on their own device, per company; the alerts page shows how
// many devices still receive SOS and every change is logged.

fn sosQuery(a: std.mem.Allocator, org_id: Val) !Val {
    return val.from(a, .{ .sosMutedOrgs = .{ .@"$ne" = org_id } });
}

pub fn sosStatus(a: std.mem.Allocator, org_id: Val, user: Val, endpoint: ?[]const u8) !Val {
    const user_ids = try membersWith(a, org_id, "carrier", "alerts.manage");
    const devices = try db.col("push_subscriptions").count(a, try val.spread(a, .{ .{ .userId = .{ .@"$in" = user_ids } }, try sosQuery(a, org_id) }), .{});
    const mine = if (endpoint) |e| (if (e.len > 0) try db.col("push_subscriptions").findOne(a, .{ .endpoint = e, .userId = user.get("id") }, .{}) else null) else null;
    var this_device = false;
    if (mine) |m| {
        this_device = true;
        for (m.get("sosMutedOrgs").items()) |id| if (id.sameId(org_id)) {
            this_device = false;
        };
    }
    return val.from(a, .{ .devices = devices, .thisDevice = this_device, .subscribed = mine != null });
}

pub fn setSosForDevice(r: *Req, org_id: Val, user: Val, endpoint: []const u8, enabled: bool) !void {
    const upd = if (enabled) try val.from(r.a, .{ .@"$pull" = .{ .sosMutedOrgs = org_id } }) else try val.from(r.a, .{ .@"$addToSet" = .{ .sosMutedOrgs = org_id } });
    const res = try db.col("push_subscriptions").updateOne(r.a, .{ .endpoint = endpoint, .userId = user.get("id") }, upd, .{});
    if (res.matched == 0) return r.badRequest("This device is not registered for notifications", "endpoint", null, null);
}

// ---- Domain events -> notifications -------------------------------------------------------------

fn orgSlug(a: std.mem.Allocator, org_id: Val) !?Val {
    return db.col("orgs").findOne(a, .{ ._id = org_id }, .{ .projection = try val.from(a, .{ .slug = 1, .type = 1 }) });
}

/// task.changed: a task was assigned to a courier.
pub fn onTaskChanged(a: std.mem.Allocator, e: Val) !void {
    const courier_id = e.get("courierId");
    if (!courier_id.truthy() or e.t("declined") or e.t("completed") or e.t("failed")) return;
    const task = (try db.col("tasks").findOne(a, .{ ._id = e.get("taskId") }, .{})) orelse return;
    if (!std.mem.eql(u8, task.s("status") orelse "", "assigned") or !task.get("courierId").sameId(courier_id)) return;
    const courier = (try db.col("memberships").findOne(a, .{ ._id = courier_id }, .{})) orelse return;
    const org = (try orgSlug(a, task.get("carrierId"))) orelse return;
    const tid = try val.toStr(a, task.get("_id"));
    _ = try sendToUserOpts(a, courier.get("userId"), try val.from(a, .{
        .kind = "task",
        .title = "مهمة جديدة · New task",
        .body = try std.fmt.allocPrint(a, "{s} → {s}", .{ try val.toStr(a, task.path("from.label")), try val.toStr(a, task.path("to.label")) }),
        .url = try std.fmt.allocPrint(a, "/o/{s}/driver/task/{s}", .{ try val.toStr(a, org.get("slug")), tid }),
        .tag = try std.fmt.allocPrint(a, "task-{s}", .{tid}),
        .urgent = true,
    }), .{});
}

/// alert.raised: SOS to the people who handle alerts; tracking problems to the courier's phone.
pub fn onAlertRaised(a: std.mem.Allocator, e: Val) !void {
    const alert = e.get("alert");
    const org = (try orgSlug(a, alert.get("carrierId"))) orelse return;
    const slug = try val.toStr(a, org.get("slug"));
    const t = alert.s("type") orelse "";
    if (std.mem.eql(u8, t, "sos")) {
        try sendToMembersWith(a, alert.get("carrierId"), "carrier", "alerts.manage", try val.from(a, .{
            .kind = "sos",
            .title = try std.fmt.allocPrint(a, "SOS · {s}", .{try val.toStr(a, alert.get("courierName"))}),
            .body = if (alert.t("note")) alert.get("note") else Val{ .str = "طلب استغاثة · Emergency alert" },
            .url = try std.fmt.allocPrint(a, "/o/{s}/alerts", .{slug}),
            .tag = try std.fmt.allocPrint(a, "sos-{s}", .{try val.toStr(a, alert.get("_id"))}),
            .urgent = true,
            .requireInteraction = true,
        }), .{ .ttl = 24 * 3600, .extra_query = try sosQuery(a, alert.get("carrierId")) });
    }
    // The courier's own phone: bring the app back to the front so tracking resumes.
    if (std.mem.eql(u8, t, "tracking_paused") or std.mem.eql(u8, t, "signal_lost")) {
        const courier = (try db.col("memberships").findOne(a, .{ ._id = alert.get("courierId") }, .{})) orelse return;
        _ = try sendToUserOpts(a, courier.get("userId"), try val.from(a, .{
            .kind = "resume",
            .title = "التتبع متوقف · Tracking paused",
            .body = "افتح التطبيق لمتابعة مشاركة موقعك · Open Turf to resume location sharing",
            .url = try std.fmt.allocPrint(a, "/o/{s}/driver", .{slug}),
            .tag = "turf-shift",
            .urgent = true,
            .requireInteraction = true,
        }), .{ .ttl = 15 * 60 });
    }
}

test "PKCS#8 round trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var priv: [32]u8 = undefined;
    for (&priv, 0..) |*b, i| b.* = @intCast(i + 1);
    const public = (try P256.basePoint.mul(priv, .big)).toUncompressedSec1();
    const pem = try pkcs8Pem(arena.allocator(), priv, public);
    try std.testing.expectEqual(priv, try privateFromPem(arena.allocator(), pem));
}
