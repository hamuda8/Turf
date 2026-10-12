//! In-process pub/sub delivered to browsers over Server-Sent Events (src/realtime.js).
//!
//! Channels: carrier:<orgId>, fleet:<orgId>, alerts:<orgId>, merchant:<orgId>, shipment:<id>,
//! courier:<memberId>. Each stream is served by its own connection task; publishers only queue
//! the message for it and wake it, so a slow client never blocks the publisher.

const std = @import("std");
const Io = std.Io;
const http = @import("http");
const val = @import("lib/val.zig");
const web = @import("web.zig");
const a_ = @import("app.zig");
const Val = val.Val;
const Req = web.Req;

const heartbeat_ms = 25_000;
const max_streams_per_ip = 30;

const Stream = struct {
    lock: Io.Mutex = .init,
    cond: Io.Condition = .init,
    /// Encoded events waiting to be written (owned by gpa).
    pending: std.ArrayList([]u8) = .empty,
};

var lock: Io.Mutex = .init;
/// channel (owned) -> streams
var channels: std.StringHashMapUnmanaged(std.ArrayList(*Stream)) = .empty;
/// ip (owned) -> open streams
var per_ip: std.StringHashMapUnmanaged(u32) = .empty;

/// Opens the event stream for `channel_names` and serves it until the client leaves. Answers 429
/// when this address has too many streams open.
pub fn subscribe(r: *Req, channel_names: []const []const u8, initial_event: ?[]const u8, initial_data: Val) !void {
    const ctx = r.ctx orelse return;
    const io = a_.app.io;
    const gpa = a_.app.gpa;
    const ip = r.ip();
    const full = blk: {
        lock.lockUncancelable(io);
        defer lock.unlock(io);
        const open = per_ip.get(ip) orelse 0;
        if (open >= max_streams_per_ip) break :blk true;
        if (per_ip.getPtr(ip)) |n| n.* += 1 else {
            const k = try gpa.dupe(u8, ip);
            per_ip.put(gpa, k, 1) catch gpa.free(k);
        }
        break :blk false;
    };
    if (full) return r.json(429, .{ .@"error" = .{ .code = "too_many_streams", .message = "Too many open live streams" } });
    var stream: Stream = .{};
    defer releaseIp(ip);

    try ctx.setHeader("content-type", "text/event-stream; charset=utf-8");
    try ctx.setHeader("cache-control", "no-cache, no-transform");
    try ctx.setHeader("x-accel-buffering", "no");
    ctx.responded = true;
    ctx.close_connection = true;
    var buf: [4096]u8 = undefined;
    var w = try ctx.request.respondStreaming(&buf, .{ .respond_options = .{ .extra_headers = ctx.response_headers.items, .keep_alive = false } });
    try w.writer.writeAll("retry: 5000\n\n");
    if (initial_event) |ev| try w.writer.writeAll(try encode(r.a, ev, initial_data));
    try w.flush();

    try join(channel_names, &stream);
    defer leave(channel_names, &stream);

    while (true) {
        stream.lock.lockUncancelable(io);
        if (stream.pending.items.len == 0) {
            stream.cond.waitTimeout(io, &stream.lock, .{ .duration = .{ .raw = .fromMilliseconds(heartbeat_ms), .clock = .awake } }) catch |e| switch (e) {
                error.Timeout => {},
                error.Canceled => {
                    stream.lock.unlock(io);
                    return;
                },
            };
        }
        const batch = stream.pending.toOwnedSlice(gpa) catch &.{};
        stream.lock.unlock(io);
        defer {
            for (batch) |m| gpa.free(m);
            gpa.free(batch);
        }
        if (batch.len == 0) {
            w.writer.writeAll(": ping\n\n") catch return;
        } else for (batch) |m| w.writer.writeAll(m) catch return;
        w.flush() catch return;
    }
}

fn releaseIp(ip: []const u8) void {
    const io = a_.app.io;
    lock.lockUncancelable(io);
    defer lock.unlock(io);
    const n = per_ip.getPtr(ip) orelse return;
    if (n.* <= 1) {
        const kv = per_ip.fetchRemove(ip).?;
        a_.app.gpa.free(kv.key);
    } else n.* -= 1;
}

fn join(names: []const []const u8, s: *Stream) !void {
    const io = a_.app.io;
    const gpa = a_.app.gpa;
    lock.lockUncancelable(io);
    defer lock.unlock(io);
    for (names) |name| {
        const gop = try channels.getOrPut(gpa, name);
        if (!gop.found_existing) {
            gop.key_ptr.* = try gpa.dupe(u8, name);
            gop.value_ptr.* = .empty;
        }
        try gop.value_ptr.append(gpa, s);
    }
}

fn leave(names: []const []const u8, s: *Stream) void {
    const io = a_.app.io;
    const gpa = a_.app.gpa;
    lock.lockUncancelable(io);
    defer lock.unlock(io);
    for (names) |name| {
        const list = channels.getPtr(name) orelse continue;
        for (list.items, 0..) |x, i| if (x == s) {
            _ = list.swapRemove(i);
            break;
        };
        if (list.items.len == 0) {
            list.deinit(gpa);
            const kv = channels.fetchRemove(name).?;
            gpa.free(kv.key);
        }
    }
    // Messages queued after the last write.
    s.lock.lockUncancelable(io);
    defer s.lock.unlock(io);
    for (s.pending.items) |m| gpa.free(m);
    s.pending.deinit(gpa);
}

fn encode(a: std.mem.Allocator, event: []const u8, data: Val) ![]const u8 {
    return std.fmt.allocPrint(a, "event: {s}\ndata: {s}\n\n", .{ event, try val.toJson(a, data) });
}

/// Sends `event` with `data` to every stream on `channel`.
pub fn publish(channel: []const u8, event: []const u8, data: Val) void {
    const io = a_.app.io;
    const gpa = a_.app.gpa;
    if (!hasSubscribers(channel)) return;
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    const msg = encode(scratch.allocator(), event, data) catch return;
    lock.lockUncancelable(io);
    defer lock.unlock(io);
    const list = channels.get(channel) orelse return;
    for (list.items) |s| {
        const copy = gpa.dupe(u8, msg) catch continue;
        s.lock.lockUncancelable(io);
        s.pending.append(gpa, copy) catch gpa.free(copy);
        s.lock.unlock(io);
        s.cond.signal(io);
    }
}

pub fn hasSubscribers(channel: []const u8) bool {
    const io = a_.app.io;
    lock.lockUncancelable(io);
    defer lock.unlock(io);
    return channels.contains(channel);
}

/// "carrier:<id>" and the like.
pub fn chan(a: std.mem.Allocator, prefix: []const u8, id: Val) []const u8 {
    return std.fmt.allocPrint(a, "{s}:{s}", .{ prefix, val.toStr(a, id) catch "" }) catch "";
}
