//! In-process pub/sub delivered to browsers over Server-Sent Events (src/realtime.js), on
//! zig-core's http.sse.Hub: each stream is served by its own connection task, publishers only
//! queue the message, so a slow client never blocks the publisher.
//!
//! Channels: carrier:<orgId>, fleet:<orgId>, alerts:<orgId>, merchant:<orgId>, shipment:<id>,
//! courier:<memberId>.

const std = @import("std");
const http = @import("http");
const val = @import("mongo").val;
const web = @import("web.zig");
const a_ = @import("app.zig");
const Val = val.Val;
const Req = web.Req;

var hub: http.sse.Hub = undefined;
var ready = false;

/// Sets up the hub (main, once a_.app exists). Up to 30 streams per address.
pub fn init() void {
    hub = .init(a_.app.io, a_.app.gpa);
    ready = true;
}

/// Opens the event stream for `channel_names` and serves it until the client leaves. Answers 429
/// when this address has too many streams open.
pub fn subscribe(r: *Req, channel_names: []const []const u8, initial_event: ?[]const u8, initial_data: Val) !void {
    const ctx = r.ctx orelse return;
    const first = if (initial_event) |ev| try encode(r.a, ev, initial_data) else null;
    if (!ready) return error.NotStarted;
    hub.serve(ctx, r.ip(), channel_names, .{ .first = first }) catch |e| switch (e) {
        error.TooManyStreams => return r.json(429, .{ .@"error" = .{ .code = "too_many_streams", .message = "Too many open live streams" } }),
        else => return e,
    };
}

fn encode(a: std.mem.Allocator, event: []const u8, data: Val) ![]const u8 {
    return http.sse.encode(a, event, try val.toJson(a, data));
}

/// Sends `event` with `data` to every stream on `channel`.
pub fn publish(channel: []const u8, event: []const u8, data: Val) void {
    if (!hasSubscribers(channel)) return;
    var scratch = std.heap.ArenaAllocator.init(a_.app.gpa);
    defer scratch.deinit();
    hub.publishEncoded(channel, encode(scratch.allocator(), event, data) catch return);
}

pub fn hasSubscribers(channel: []const u8) bool {
    return ready and hub.hasSubscribers(channel);
}

/// "carrier:<id>" and the like.
pub fn chan(a: std.mem.Allocator, prefix: []const u8, id: Val) []const u8 {
    return std.fmt.allocPrint(a, "{s}:{s}", .{ prefix, val.toStr(a, id) catch "" }) catch "";
}
