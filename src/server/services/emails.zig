//! Email updates for stores (src/services/emails.js). Events are queued and sent together, one
//! email per store every BATCH_MINUTES at most; the daily summary goes out at 08:00 Syria time.
//! merchant.emailNotifications = { enabled, to (null = the owner), events, dailySummary }.
//! Practice (test) shipments never send emails.

const std = @import("std");
const val = @import("../lib/val.zig");
const db = @import("../lib/db.zig");
const web = @import("../web.zig");
const a_ = @import("../app.zig");
const bus = @import("../bus.zig");
const mailer = @import("../mailer.zig");
const messages = @import("../messages.zig");
const Val = val.Val;
const Req = web.Req;
const V = web.V;
const Allocator = std.mem.Allocator;

pub const email_events = [_][]const u8{ "delivered", "delivery_failed", "return_started", "returned", "lost", "damage_reported", "recipient_problem" };
pub const default_events = [_][]const u8{ "delivery_failed", "return_started", "lost", "damage_reported", "recipient_problem" };
const batch_minutes = 5;
const max_items = 50;
const tz_ms = 3 * 3600_000;
const summary_hour = 8;

/// Settings with defaults (on for problems, to the owner) when the store never changed them.
pub fn emailSettings(a: Allocator, org: Val) !Val {
    const e = org.path("merchant.emailNotifications");
    return val.from(a, .{
        .enabled = if (e.get("enabled").isNullish()) Val{ .bool = true } else e.get("enabled"),
        .to = if (e.get("to").truthy()) e.get("to") else Val.null,
        .events = if (e.get("events").truthy()) e.get("events") else try val.from(a, &default_events),
        .dailySummary = if (e.get("dailySummary").isNullish()) Val{ .bool = false } else e.get("dailySummary"),
        .lastSummaryDay = e.get("lastSummaryDay"),
    });
}

/// /^[^\s@<>,;]+@[^\s@<>,;]+\.[^\s@<>,;]+$/
fn isAddress(s: []const u8) bool {
    for (s) |c| if (std.ascii.isWhitespace(c) or c == '<' or c == '>' or c == ',' or c == ';') return false;
    return web.isEmail(s);
}

pub fn parseEmailSettings(r: *Req, value: Val) !Val {
    const a = r.a;
    const v = (try V.obj(r, value, "emailNotifications", .{})).?;
    const to = try V.str(r, v.get("to"), "emailNotifications.to", .{ .max = 200, .optional = true, .pattern = isAddress });
    const ev_in = if (v.get("events").isNullish()) try val.newArr(a) else v.get("events");
    const list = (try V.arr(r, ev_in, "emailNotifications.events", .{ .max = email_events.len })).?;
    const events = try val.newArr(a);
    for (list, 0..) |x, i| {
        const e = (try V.oneOf(r, x, try std.fmt.allocPrint(a, "emailNotifications.events[{d}]", .{i}), &email_events, .{})).?;
        if (!val.includesStr(events, e)) try events.push(e);
    }
    const ds = v.get("dailySummary");
    return val.from(a, .{
        .enabled = (try V.boolean(r, v.get("enabled"), "emailNotifications.enabled", .{})).?,
        .to = if (to) |t| (if (t.len > 0) Val{ .str = t } else Val.null) else Val.null,
        .events = events,
        .dailySummary = (try V.boolean(r, if (ds.isNullish()) Val{ .bool = false } else ds, "emailNotifications.dailySummary", .{})).?,
    });
}

fn recipientFor(a: Allocator, org: Val) !?[]const u8 {
    const s = try emailSettings(a, org);
    if (s.s("to")) |t| return t;
    const owner = try db.col("users").findOne(a, .{ ._id = org.get("ownerUserId") }, .{ .projection = try val.from(a, .{ .email = 1 }) });
    return if (owner) |o| (if (o.s("email")) |e| (if (e.len > 0) e else null) else null) else null;
}

fn link(a: Allocator, org: Val, shipment_id: Val) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}/o/{s}/shipments/{s}", .{ a_.cfg().public_url, try val.toStr(a, org.get("slug")), try val.toStr(a, shipment_id) });
}

pub fn esc(a: Allocator, v: Val) ![]const u8 {
    const s = if (v.isNullish()) "" else try val.toStr(a, v);
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| switch (c) {
        '&' => try out.appendSlice(a, "&amp;"),
        '<' => try out.appendSlice(a, "&lt;"),
        '>' => try out.appendSlice(a, "&gt;"),
        '"' => try out.appendSlice(a, "&quot;"),
        '\'' => try out.appendSlice(a, "&#39;"),
        else => try out.append(a, c),
    };
    return out.items;
}

// ---- Queue ---------------------------------------------------------------------------------------

/// shipment.event listener.
pub fn queueEvent(r: *Req, e: Val) !void {
    const a = r.a;
    const shipment = e.get("shipment");
    const event = e.get("event");
    const code = event.s("code") orelse "";
    if (shipment.t("test") or !val.contains([]const u8, &email_events, code)) return;
    const org = (try db.col("orgs").findOne(a, .{ ._id = shipment.get("merchantId") }, .{ .projection = try val.from(a, .{ .type = 1, .merchant = 1, .personal = 1 }) })) orelse return;
    if (!std.mem.eql(u8, org.s("type") orelse "", "merchant") or org.t("personal")) return;
    const s = try emailSettings(a, org);
    if (!s.t("enabled") or !val.includesStr(s.get("events"), code)) return;
    _ = try db.col("email_queue").insertOne(a, .{
        .orgId = org.get("_id"),
        .shipmentId = shipment.get("_id"),
        .code = code,
        .trackingNumber = shipment.get("trackingNumber"),
        .reference = if (shipment.t("externalRef")) shipment.get("externalRef") else Val.null,
        .recipient = if (shipment.path("dropoff.name").truthy()) shipment.path("dropoff.name") else Val.null,
        .textEn = try messages.eventText(a, event, "en"),
        .textAr = try messages.eventText(a, event, "ar"),
        .at = a_.now(),
        .sentAt = null,
    });
}

fn batchEmail(a: Allocator, org: Val, items: []const Val) !mailer.Mail {
    const shown = items[0..@min(items.len, max_items)];
    const more = items.len - shown.len;
    const name = try val.toStr(a, org.get("name"));
    const subject = try std.fmt.allocPrint(a, "Turf · {s}: {d} shipment update{s} · {d} تحديث", .{ name, items.len, if (items.len == 1) "" else "s", items.len });
    var text: std.ArrayList(u8) = .empty;
    try text.print(a, "تحديثات شحنات {s}\nShipment updates for {s}\n", .{ name, name });
    for (shown) |i| {
        const ref = if (i.t("reference")) try std.fmt.allocPrint(a, " ({s})", .{try val.toStr(a, i.get("reference"))}) else "";
        try text.print(a, "\n{s}{s} · {s}\n  {s}\n  {s}\n  {s}", .{ try val.toStr(a, i.get("trackingNumber")), ref, if (i.t("recipient")) try val.toStr(a, i.get("recipient")) else "", try val.toStr(a, i.get("textAr")), try val.toStr(a, i.get("textEn")), try link(a, org, i.get("shipmentId")) });
    }
    const settings_url = try std.fmt.allocPrint(a, "{s}/o/{s}/settings", .{ a_.cfg().public_url, try val.toStr(a, org.get("slug")) });
    try text.print(a, "\n{s}\n\n{s}\nلإيقاف هذه الرسائل أو تغييرها: الإعدادات ← إشعارات البريد. To change these emails: Settings → Email updates.", .{ if (more > 0) try std.fmt.allocPrint(a, "\n+ {d} …", .{more}) else "", settings_url });

    var html: std.ArrayList(u8) = .empty;
    try html.print(a, "<div style=\"font-family:system-ui,sans-serif;max-width:640px\">\n<h2 style=\"margin:0 0 4px\">{s}</h2>\n<p style=\"color:#64748b;margin:0 0 16px\" dir=\"rtl\">تحديثات الشحنات</p>\n<table style=\"border-collapse:collapse;width:100%\">", .{try esc(a, org.get("name"))});
    for (shown) |i| {
        const ref = if (i.t("reference")) try std.fmt.allocPrint(a, " <span style=\"color:#64748b\">({s})</span>", .{try esc(a, i.get("reference"))}) else "";
        try html.print(a, "<tr style=\"border-top:1px solid #e2e8f0\"><td style=\"padding:8px 4px;vertical-align:top\">\n<a href=\"{s}\" style=\"font-family:monospace\">{s}</a>{s}<br><span style=\"color:#64748b\">{s}</span></td>\n<td style=\"padding:8px 4px\"><div dir=\"rtl\">{s}</div><div>{s}</div></td></tr>", .{
            try esc(a, .{ .str = try link(a, org, i.get("shipmentId")) }), try esc(a, i.get("trackingNumber")), ref, try esc(a, i.get("recipient")), try esc(a, i.get("textAr")), try esc(a, i.get("textEn")),
        });
    }
    try html.print(a, "</table>\n{s}\n<p style=\"color:#64748b;font-size:12px;margin-top:24px\"><a href=\"{s}\">الإعدادات ← إشعارات البريد · Settings → Email updates</a></p></div>", .{ if (more > 0) try std.fmt.allocPrint(a, "<p>+ {d} …</p>", .{more}) else "", try esc(a, .{ .str = settings_url }) });
    return .{ .to = "", .subject = subject, .text = text.items, .html = html.items };
}

/// Sends what is waiting, one email per store, once its oldest update is BATCH_MINUTES old.
pub fn processEmailQueue(a: Allocator, now_ms: i64, force: bool) !void {
    const now: Val = .{ .date = now_ms };
    const q = try val.from(a, .{ .sentAt = null });
    if (!force) try q.set("at", .{ .@"$lte" = val.Date{ .ms = now_ms - batch_minutes * 60_000 } });
    const org_ids = try db.col("email_queue").distinct(a, "orgId", q);
    for (org_ids) |org_id| {
        const items = try db.col("email_queue").find(a, .{ .orgId = org_id, .sentAt = null }, .{ .sort = try val.from(a, .{ .at = 1 }) });
        const ids = try val.newArr(a);
        for (items) |i| try ids.push(i.get("_id"));
        // Claimed first, so a slow send can't be picked up twice.
        _ = try db.col("email_queue").updateMany(a, .{ ._id = .{ .@"$in" = ids }, .sentAt = null }, .{ .@"$set" = .{ .sentAt = now } }, .{});
        const org = (try db.col("orgs").findOne(a, .{ ._id = org_id }, .{})) orelse continue;
        if (!(try emailSettings(a, org)).t("enabled")) continue;
        const to = (try recipientFor(a, org)) orelse continue;
        var mail = try batchEmail(a, org, items);
        mail.to = to;
        mailer.sendMail(a, mail) catch |err| {
            std.log.err("Store email to {s} failed: {t}", .{ try val.toStr(a, org.get("slug")), err });
            _ = try db.col("email_queue").updateMany(a, .{ ._id = .{ .@"$in" = ids } }, .{ .@"$set" = .{ .sentAt = null, .lastError = @errorName(err) }, .@"$inc" = .{ .tries = 1 } }, .{});
            // Give up after 5 tries.
            _ = try db.col("email_queue").deleteMany(a, .{ ._id = .{ .@"$in" = ids }, .tries = .{ .@"$gte" = 5 } });
        };
    }
}

// ---- Daily summary -------------------------------------------------------------------------------

/// Yesterday (Syria time) for one store.
pub fn dailySummary(a: Allocator, org: Val, now_ms: i64) !Val {
    const local_midnight = @divFloor(now_ms + tz_ms, 86400_000) * 86400_000 - tz_ms;
    const from = local_midnight - 86400_000;
    const range = try val.from(a, .{ .@"$gte" = val.Date{ .ms = from }, .@"$lt" = val.Date{ .ms = local_midnight } });
    const base = try val.from(a, .{ .merchantId = org.get("_id"), .@"test" = .{ .@"$ne" = true } });
    const created = try db.col("shipments").count(a, try val.spread(a, .{ base, .{ .createdAt = range } }), .{});
    const delivered = try db.col("shipments").count(a, try val.spread(a, .{ base, .{ .deliveredAt = range } }), .{});
    const events = try db.col("shipment_events").find(a, .{ .merchantId = org.get("_id"), .code = .{ .@"$in" = .{ "delivery_failed", "returned" } }, .at = range }, .{ .projection = try val.from(a, .{ .shipmentId = 1, .code = 1 }) });
    const cod = try db.col("shipments").aggregate(a, .{
        .{ .@"$match" = try val.spread(a, .{ base, .{ .@"cod.collectedAt" = range } }) },
        .{ .@"$group" = .{ ._id = "$cod.currency", .amount = .{ .@"$sum" = "$cod.amount" } } },
    });
    const open = try db.col("shipments").count(a, try val.spread(a, .{ base, .{ .status = .{ .@"$in" = .{ "awaiting_pickup", "picked_up", "at_hub", "in_transit", "out_for_delivery", "delivery_failed", "returning" } } } }), .{});
    // Practice shipments are left out.
    const sids = try val.newArr(a);
    for (events) |e| try sids.push(e.get("shipmentId"));
    const practice = try db.col("shipments").find(a, .{ ._id = .{ .@"$in" = sids }, .@"test" = true }, .{ .projection = try val.from(a, .{ ._id = 1 }) });
    var failed: usize = 0;
    var returned: usize = 0;
    for (events) |e| {
        var skip = false;
        for (practice) |p| if (p.get("_id").sameId(e.get("shipmentId"))) {
            skip = true;
        };
        if (skip) continue;
        if (std.mem.eql(u8, e.s("code") orelse "", "delivery_failed")) failed += 1 else returned += 1;
    }
    const cod_out = try val.newArr(a);
    for (cod) |c| try cod_out.push(.{ .currency = c.get("_id"), .amount = c.get("amount") });
    return val.from(a, .{ .day = (try val.isoAlloc(a, from + tz_ms))[0..10], .created = created, .delivered = delivered, .failed = failed, .returned = returned, .cod = cod_out, .open = open });
}

/// Number.prototype.toLocaleString('en'): thousands separated by commas, up to 3 decimals.
pub fn localeNumber(a: Allocator, x: f64) ![]const u8 {
    if (!std.math.isFinite(x)) return val.numStr(a, x);
    const rounded = val.jsRound(x * 1000) / 1000;
    const neg = rounded < 0;
    const abs = @abs(rounded);
    const int_part: u64 = @intFromFloat(@floor(abs));
    var frac = abs - @floor(abs);
    var digits: std.ArrayList(u8) = .empty;
    const s = try std.fmt.allocPrint(a, "{d}", .{int_part});
    for (s, 0..) |c, i| {
        if (i > 0 and (s.len - i) % 3 == 0) try digits.append(a, ',');
        try digits.append(a, c);
    }
    if (frac > 0.0000001) {
        try digits.append(a, '.');
        var n: usize = 0;
        var buf: [3]u8 = undefined;
        while (n < 3) : (n += 1) {
            frac *= 10;
            const d: u8 = @intFromFloat(@floor(frac + 1e-9));
            buf[n] = '0' + @as(u8, @min(d, 9));
            frac -= @floatFromInt(d);
        }
        var end: usize = 3;
        while (end > 0 and buf[end - 1] == '0') end -= 1;
        try digits.appendSlice(a, buf[0..end]);
    }
    return if (neg) std.fmt.allocPrint(a, "-{s}", .{digits.items}) else digits.items;
}

fn summaryEmail(a: Allocator, org: Val, s: Val) !mailer.Mail {
    var cod_parts: std.ArrayList([]const u8) = .empty;
    for (s.get("cod").items()) |c| try cod_parts.append(a, try std.fmt.allocPrint(a, "{s} {s}", .{ try localeNumber(a, val.toNum(c.get("amount"))), try val.toStr(a, c.get("currency")) }));
    const cod = if (cod_parts.items.len > 0) try std.mem.join(a, ", ", cod_parts.items) else "0";
    const Row = struct { ar: []const u8, en: []const u8, v: []const u8 };
    const rows = [_]Row{
        .{ .ar = "شحنات جديدة", .en = "New shipments", .v = try val.toStr(a, s.get("created")) },
        .{ .ar = "تم التسليم", .en = "Delivered", .v = try val.toStr(a, s.get("delivered")) },
        .{ .ar = "محاولات فاشلة", .en = "Failed attempts", .v = try val.toStr(a, s.get("failed")) },
        .{ .ar = "أُعيدت", .en = "Returned", .v = try val.toStr(a, s.get("returned")) },
        .{ .ar = "نقد محصّل", .en = "Cash collected", .v = cod },
        .{ .ar = "قيد التنفيذ الآن", .en = "In progress now", .v = try val.toStr(a, s.get("open")) },
    };
    const name = try val.toStr(a, org.get("name"));
    const day = try val.toStr(a, s.get("day"));
    const subject = try std.fmt.allocPrint(a, "Turf · {s}: {s} · {s} delivered", .{ name, day, try val.toStr(a, s.get("delivered")) });
    const reports = try std.fmt.allocPrint(a, "{s}/o/{s}/reports", .{ a_.cfg().public_url, try val.toStr(a, org.get("slug")) });
    var text: std.ArrayList(u8) = .empty;
    try text.print(a, "{s} — {s}\n", .{ name, day });
    for (rows) |row| try text.print(a, "\n{s} / {s}: {s}", .{ row.ar, row.en, row.v });
    try text.print(a, "\n\n{s}", .{reports});
    var html: std.ArrayList(u8) = .empty;
    try html.print(a, "<div style=\"font-family:system-ui,sans-serif;max-width:520px\"><h2 style=\"margin:0\">{s}</h2><p style=\"color:#64748b\">{s}</p>\n<table style=\"border-collapse:collapse;width:100%\">", .{ try esc(a, org.get("name")), try esc(a, s.get("day")) });
    for (rows) |row| try html.print(a, "<tr style=\"border-top:1px solid #e2e8f0\"><td style=\"padding:6px 4px\">{s}</td><td style=\"padding:6px 4px\" dir=\"rtl\">{s}</td><td style=\"padding:6px 4px;text-align:end;font-weight:700\">{s}</td></tr>", .{ try esc(a, .{ .str = row.en }), try esc(a, .{ .str = row.ar }), try esc(a, .{ .str = row.v }) });
    try html.print(a, "</table>\n<p><a href=\"{s}\">التقارير · Reports</a></p></div>", .{try esc(a, .{ .str = reports })});
    return .{ .to = "", .subject = subject, .text = text.items, .html = html.items };
}

pub fn sendDailySummaries(a: Allocator, now_ms: i64) !void {
    if (val.civil(now_ms + tz_ms).hour < summary_hour) return;
    const today = (try val.isoAlloc(a, now_ms + tz_ms))[0..10];
    const orgs = try db.col("orgs").find(a, .{
        .type = "merchant",
        .status = "active",
        .personal = .{ .@"$ne" = true },
        .@"merchant.emailNotifications.enabled" = true,
        .@"merchant.emailNotifications.dailySummary" = true,
        .@"merchant.emailNotifications.lastSummaryDay" = .{ .@"$ne" = today },
    }, .{});
    for (orgs) |org| {
        // Marked first, so a crash or restart can't send it twice.
        const claimed = try db.col("orgs").updateOne(a, .{ ._id = org.get("_id"), .@"merchant.emailNotifications.lastSummaryDay" = .{ .@"$ne" = today } }, .{ .@"$set" = .{ .@"merchant.emailNotifications.lastSummaryDay" = today } }, .{});
        if (claimed.modified == 0) continue;
        const s = try dailySummary(a, org, now_ms);
        if (!s.t("created") and !s.t("delivered") and !s.t("failed") and !s.t("open")) continue;
        const to = (try recipientFor(a, org)) orelse continue;
        var mail = try summaryEmail(a, org, s);
        mail.to = to;
        mailer.sendMail(a, mail) catch |err| std.log.err("Daily summary to {s} failed: {t}", .{ try val.toStr(a, org.get("slug")), err });
    }
}

/// Every minute. Run as its own task.
pub fn loop() void {
    while (true) {
        a_.app.io.sleep(.fromSeconds(60), .awake) catch return;
        if (!bus.enabled[@intFromEnum(bus.Service.emails)]) continue;
        var arena = std.heap.ArenaAllocator.init(a_.app.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        processEmailQueue(a, a_.nowMs(), false) catch |e| std.log.err("Store emails failed: {t}", .{e});
        sendDailySummaries(a, a_.nowMs()) catch |e| std.log.err("Daily summaries failed: {t}", .{e});
    }
}

test localeNumber {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("20,000", try localeNumber(arena.allocator(), 20000));
    try std.testing.expectEqualStrings("1,234.5", try localeNumber(arena.allocator(), 1234.5));
}
