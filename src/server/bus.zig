//! In-process domain events (src/bus.js). Services emit facts ("shipment.event"); other services
//! react (live updates, webhooks, auto-dispatch, push, emails) without the emitter knowing them.
//!
//! Turf-js runs listeners after the emitting code's current step; here they run once the request
//! has been answered (or at the end of a background job's step), in the order Turf-js starts its
//! services. Listener failures are logged, never passed back.

const std = @import("std");
const val = @import("lib/val.zig");
const web = @import("web.zig");
const Val = val.Val;
const Req = web.Req;

pub const Listener = *const fn (r: *Req, payload: Val) anyerror!void;

pub const Binding = struct { event: []const u8, name: []const u8, listener: Listener };

/// Every listener, in Turf-js's start order (live, webhooks, dispatch, push, direct, emails).
/// Set by main.
pub var bindings: []const Binding = &.{};

/// Which services listen (the test harness starts only some of them, like Turf-js's helpers).
pub var enabled: [6]bool = @splat(true);

pub const Service = enum(u3) { live, webhooks, dispatch, push, direct, emails };

pub fn serviceOf(name: []const u8) ?Service {
    return std.meta.stringToEnum(Service, name);
}

pub fn emit(r: *Req, name: []const u8, payload: anytype) void {
    const p = val.from(r.a, payload) catch return;
    r.events.append(r.a, .{ .name = name, .payload = p }) catch {};
}

/// Runs the listeners of every queued event (and of events they emit in turn).
pub fn flush(r: *Req) void {
    var i: usize = 0;
    while (i < r.events.items.len) : (i += 1) {
        const e = r.events.items[i];
        for (bindings) |b| {
            if (!std.mem.eql(u8, b.event, e.name)) continue;
            if (serviceOf(b.name)) |s| if (!enabled[@intFromEnum(s)]) continue;
            const saved = r.err;
            b.listener(r, e.payload) catch |err| {
                std.log.err("Listener for \"{s}\" failed: {t}", .{ e.name, err });
            };
            r.err = saved;
        }
    }
    r.events.clearRetainingCapacity();
}
