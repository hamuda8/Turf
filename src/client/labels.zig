//! Text for values the server sends as codes (statuses, task types, permissions, error codes),
//! by their Turf-js i18n key, translated like any other text.

const std = @import("std");
const zui = @import("zui");
const keys = @import("keys.zig");

/// The English text of a Turf-js key, translated; the key itself when unknown.
pub fn k(key: []const u8) []const u8 {
    return zui.i18n.t(keys.map.get(key) orelse key);
}

/// The English text of a key, or null.
pub fn english(key: []const u8) ?[]const u8 {
    return keys.map.get(key);
}

/// `prefix ++ value` ("status." ++ "delivered").
pub fn of(comptime prefix: []const u8, value: []const u8) []const u8 {
    var buf: [128]u8 = undefined;
    if (prefix.len + value.len > buf.len) return value;
    @memcpy(buf[0..prefix.len], prefix);
    @memcpy(buf[prefix.len..][0..value.len], value);
    const key = buf[0 .. prefix.len + value.len];
    const e = keys.map.get(key) orelse return value;
    return zui.i18n.t(e);
}

pub fn status(s: []const u8) []const u8 {
    return of("status.", s);
}

pub fn taskType(s: []const u8) []const u8 {
    return of("task.type.", s);
}

pub fn taskStatus(s: []const u8) []const u8 {
    return of("task.status.", s);
}

pub fn vehicle(s: []const u8) []const u8 {
    return of("vehicle.", s);
}

/// Validation rule -> English, for error messages.
pub fn rule(r: []const u8) ?[]const u8 {
    return lookup("valid.", r);
}

pub fn code(c: []const u8) ?[]const u8 {
    return lookup("error.", c);
}

fn lookup(comptime prefix: []const u8, v: []const u8) ?[]const u8 {
    var buf: [128]u8 = undefined;
    if (prefix.len + v.len > buf.len) return null;
    @memcpy(buf[0..prefix.len], prefix);
    @memcpy(buf[prefix.len..][0..v.len], v);
    return keys.map.get(buf[0 .. prefix.len + v.len]);
}

test "families" {
    try std.testing.expectEqualStrings("Delivered", status("delivered"));
    try std.testing.expectEqualStrings("odd", status("odd"));
}

/// A Turf-js template key translated and filled: `tf(a, "driver.since", .{ .when = x })`.
pub fn tf(a: std.mem.Allocator, key: []const u8, args: anytype) []const u8 {
    return zui.i18n.tf(a, keys.map.get(key) orelse key, args);
}
