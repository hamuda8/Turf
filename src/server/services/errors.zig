//! Error monitoring without an external service (src/services/errors.js): server and browser
//! errors grouped by fingerprint in error_log (kept 30 days), shown in Control. A new kind of
//! error (or one coming back after a quiet period) alerts the platform admins by push, and
//! optionally ALERT_WEBHOOK_URL.

const std = @import("std");
const val = @import("../lib/val.zig");
const db = @import("../lib/db.zig");
const web = @import("../web.zig");
const a_ = @import("../app.zig");
const push = @import("push.zig");
const Val = val.Val;

const alert_quiet_ms = 6 * 3600_000;

pub fn recordError(a: std.mem.Allocator, source: []const u8, message: []const u8, stack: []const u8, where: ?[]const u8) void {
    recordErrorInner(a, source, message, stack, where) catch |e| std.log.err("Could not record error: {t}", .{e});
}

fn firstFrame(stack: []const u8) []const u8 {
    var it = std.mem.splitScalar(u8, stack, '\n');
    while (it.next()) |l| {
        const t = std.mem.trim(u8, l, " \t\r");
        if (std.mem.startsWith(u8, t, "at ")) return t;
    }
    return "";
}

fn recordErrorInner(a: std.mem.Allocator, source: []const u8, message: []const u8, stack: []const u8, where: ?[]const u8) !void {
    const msg = val.jsSlice(if (message.len > 0) message else "Unknown error", 500);
    var h: [20]u8 = undefined;
    var sha = std.crypto.hash.Sha1.init(.{});
    sha.update(source);
    sha.update("|");
    sha.update(msg);
    sha.update("|");
    sha.update(firstFrame(stack));
    sha.final(&h);
    const fingerprint = try a.dupe(u8, &std.fmt.bytesToHex(h, .lower));
    const now = a_.now();
    const before = try db.col("error_log").findOneAndUpdate(a, .{ .fingerprint = fingerprint }, .{
        .@"$inc" = .{ .count = 1 },
        .@"$set" = .{ .source = source, .message = msg, .stack = val.jsSlice(stack, 4000), .where = if (where) |w| Val{ .str = val.jsSlice(w, 300) } else Val.null, .lastAt = now },
        .@"$setOnInsert" = .{ .firstAt = now },
    }, .{ .upsert = true, .returnDocument = .before });
    if (before) |b| if (b.get("alertedAt").dateMs()) |at| if (now.date - at < alert_quiet_ms) return;
    _ = try db.col("error_log").updateOne(a, .{ .fingerprint = fingerprint }, .{ .@"$set" = .{ .alertedAt = now } }, .{});
    const text = try std.fmt.allocPrint(a, "{s} error: {s}{s}{s}{s}", .{
        if (std.mem.eql(u8, source, "browser")) "Browser" else "Server", msg,
        if (where != null) " (" else "", where orelse "", if (where != null) ")" else "",
    });
    alert(a, text);
}

fn alert(a: std.mem.Allocator, text: []const u8) void {
    const url = std.fmt.allocPrint(a, "{s}/turf/error_log", .{a_.cfg().control_url}) catch return;
    for (a_.cfg().platform_admin_user_ids) |uid| {
        push.sendToUser(a, uid, val.from(a, .{ .title = "Turf", .body = val.jsSlice(text, 180), .url = url, .tag = "turf-errors" }) catch continue);
    }
    if (a_.cfg().alert_webhook_url) |hook| {
        const line = std.fmt.allocPrint(a, "Turf: {s}", .{text}) catch return;
        const body = val.toJson(a, val.from(a, .{ .text = line, .content = line }) catch return) catch return;
        _ = a_.upstreamTimeout(a, hook, .{ .method = .POST, .body = body, .retry = false }, 8000) catch {};
    }
}

/// The hook web.zig calls for unexpected errors in a request.
pub fn fromRequest(r: *web.Req, err: anyerror) void {
    const where = if (r.ctx) |c| std.fmt.allocPrint(r.a, "{s} {s}", .{ @tagName(c.method), c.path }) catch null else null;
    recordError(r.a, "server", @errorName(err), "", where);
}
