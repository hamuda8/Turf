//! Fixed-window in-memory rate limiter (src/ratelimit.js): one process, same headers and 429.

const std = @import("std");
const Io = std.Io;
const web = @import("web.zig");
const a_ = @import("app.zig");
const Req = web.Req;

const Entry = struct { count: u32, reset_at: i64 };

var lock: Io.Mutex = .init;
/// "name:key" (owned) -> window
var hits: std.StringHashMapUnmanaged(Entry) = .empty;

fn prune(now: i64) void {
    const gpa = a_.app.gpa;
    var dead: std.ArrayList([]const u8) = .empty;
    defer dead.deinit(gpa);
    var it = hits.iterator();
    while (it.next()) |e| if (e.value_ptr.reset_at <= now) dead.append(gpa, e.key_ptr.*) catch {};
    for (dead.items) |k| {
        _ = hits.remove(k);
        gpa.free(k);
    }
}

/// Counts one request; returns the window after counting it.
fn count(key: []const u8, window_ms: i64) Entry {
    const io = a_.app.io;
    const gpa = a_.app.gpa;
    const now = a_.nowMs();
    lock.lockUncancelable(io);
    defer lock.unlock(io);
    if (hits.getPtr(key)) |e| {
        if (e.reset_at <= now) e.* = .{ .count = 0, .reset_at = now + window_ms };
        e.count += 1;
        return e.*;
    }
    if (hits.count() > 50_000) prune(now);
    const k = gpa.dupe(u8, key) catch return .{ .count = 1, .reset_at = now + window_ms };
    const e: Entry = .{ .count = 1, .reset_at = now + window_ms };
    hits.put(gpa, k, e) catch gpa.free(k);
    return e;
}

pub const KeyFn = *const fn (r: *Req) []const u8;

fn byIp(r: *Req) []const u8 {
    return r.ip();
}

/// rateLimit({ windowMs, max, key, name }) as middleware.
pub fn limit(comptime name: []const u8, comptime window_ms: i64, comptime max: u32, comptime key: ?KeyFn) web.Handler {
    return struct {
        fn f(r: *Req) anyerror!void {
            const k = (key orelse byIp)(r);
            const full = try std.fmt.allocPrint(r.a, "{s}:{s}", .{ name, k });
            const e = count(full, window_ms);
            const now = a_.nowMs();
            const reset_s = @divFloor(e.reset_at - now + 999, 1000);
            try r.setHeader("ratelimit-limit", try std.fmt.allocPrint(r.a, "{d}", .{max}));
            try r.setHeader("ratelimit-remaining", try std.fmt.allocPrint(r.a, "{d}", .{if (e.count >= max) 0 else max - e.count}));
            try r.setHeader("ratelimit-reset", try std.fmt.allocPrint(r.a, "{d}", .{reset_s}));
            if (e.count > max) {
                try r.setHeader("retry-after", try std.fmt.allocPrint(r.a, "{d}", .{reset_s}));
                return r.fail(429, "rate_limited", "Too many requests, slow down", .{});
            }
        }
    }.f;
}
