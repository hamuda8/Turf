//! Fixed-window in-memory rate limiter (src/ratelimit.js) on zig-core's http.RateLimiter: one
//! process, the same headers and 429.

const std = @import("std");
const http = @import("http");
const web = @import("web.zig");
const a_ = @import("app.zig");
const Req = web.Req;

/// One store for every limit; keys are "name:key".
var limiter: http.RateLimiter = .{};

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
            const now = a_.nowMs();
            const e = limiter.hit(a_.app.io, a_.app.gpa, full, window_ms, now);
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
