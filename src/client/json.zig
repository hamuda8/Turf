//! Reading the server's JSON the way the JS client did (`s.dropoff.phone`): every answer is
//! kept as a std.json.Value tree and read with dotted paths. Missing fields read as "", 0,
//! false or empty lists, never as errors. Also a small writer for request bodies.

const std = @import("std");

pub const V = std.json.Value;

/// The value at a dotted path ("dropoff.phone", "items.0.name"), or null.
pub fn get(v: ?V, path: []const u8) ?V {
    var cur = v orelse return null;
    if (path.len == 0) return cur;
    var it = std.mem.splitScalar(u8, path, '.');
    while (it.next()) |part| {
        switch (cur) {
            .object => |o| cur = o.get(part) orelse return null,
            .array => |a| {
                const i = std.fmt.parseInt(usize, part, 10) catch return null;
                if (i >= a.items.len) return null;
                cur = a.items[i];
            },
            else => return null,
        }
    }
    return cur;
}

/// Present and not null.
pub fn has(v: ?V, path: []const u8) bool {
    const x = get(v, path) orelse return false;
    return x != .null;
}

/// A string field, or "" (numbers are not turned into text here; see `text`).
pub fn str(v: ?V, path: []const u8) []const u8 {
    const x = get(v, path) orelse return "";
    return switch (x) {
        .string => |s| s,
        .number_string => |s| s,
        else => "",
    };
}

pub fn strOr(v: ?V, path: []const u8, fallback: []const u8) []const u8 {
    const s = str(v, path);
    return if (s.len > 0) s else fallback;
}

/// Any scalar as text (strings as they are, numbers in their shortest form), in `a`.
pub fn text(a: std.mem.Allocator, v: ?V, path: []const u8) []const u8 {
    const x = get(v, path) orelse return "";
    return switch (x) {
        .string, .number_string => |s| s,
        .integer => |i| std.fmt.allocPrint(a, "{d}", .{i}) catch "",
        .float => |f| std.fmt.allocPrint(a, "{d}", .{f}) catch "",
        .bool => |b| if (b) "true" else "false",
        else => "",
    };
}

pub fn num(v: ?V, path: []const u8) ?f64 {
    const x = get(v, path) orelse return null;
    return switch (x) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

pub fn numOr(v: ?V, path: []const u8, fallback: f64) f64 {
    return num(v, path) orelse fallback;
}

pub fn int(v: ?V, path: []const u8) i64 {
    const f = num(v, path) orelse return 0;
    if (!std.math.isFinite(f)) return 0;
    return @intFromFloat(@round(f));
}

pub fn boolean(v: ?V, path: []const u8) bool {
    const x = get(v, path) orelse return false;
    return switch (x) {
        .bool => |b| b,
        .integer => |i| i != 0,
        .string => |s| s.len > 0,
        .array => |a| a.items.len > 0,
        .object => true,
        else => false,
    };
}

pub fn arr(v: ?V, path: []const u8) []const V {
    const x = get(v, path) orelse return &.{};
    return switch (x) {
        .array => |a| a.items,
        else => &.{},
    };
}

pub fn obj(v: ?V, path: []const u8) ?V {
    const x = get(v, path) orelse return null;
    return if (x == .object) x else null;
}

/// Whether the string list at `path` contains `s` (permissions).
pub fn contains(v: ?V, path: []const u8, s: []const u8) bool {
    for (arr(v, path)) |x| if (x == .string and std.mem.eql(u8, x.string, s)) return true;
    return false;
}

/// `{ en, ar }` objects from the API in the current language (`pick` in the JS client).
pub fn pick(v: ?V, path: []const u8, lang: []const u8) []const u8 {
    const o = get(v, path) orelse return "";
    if (o == .string) return o.string;
    const s = str(o, lang);
    return if (s.len > 0) s else str(o, "en");
}

/// Parses `body` into `a`; null when it is not JSON.
pub fn parse(a: std.mem.Allocator, body: []const u8) ?V {
    if (std.mem.trim(u8, body, " \r\n\t").len == 0) return null;
    return std.json.parseFromSliceLeaky(V, a, body, .{ .allocate = .alloc_always }) catch null;
}

/// Writes a value as JSON text.
pub fn stringify(a: std.mem.Allocator, v: V) []const u8 {
    return std.fmt.allocPrint(a, "{f}", .{std.json.fmt(v, .{})}) catch "null";
}

// ---- Building request bodies ------------------------------------------------------------------

/// A JSON object written field by field:
///   var b = json.Obj.init(a); b.str("name", n); b.num("weightKg", 2); b.begin("dropoff"); ... b.end();
///   const body = b.done();
pub const Obj = struct {
    out: std.ArrayList(u8) = .empty,
    a: std.mem.Allocator,
    /// Whether the open object/array at each depth has a member yet.
    firsts: [16]bool = @splat(true),
    depth: usize = 0,

    pub fn init(a: std.mem.Allocator) Obj {
        var o: Obj = .{ .a = a };
        o.out.append(a, '{') catch {};
        return o;
    }

    fn sep(o: *Obj) void {
        if (!o.firsts[o.depth]) o.out.append(o.a, ',') catch {};
        o.firsts[o.depth] = false;
    }

    fn name(o: *Obj, n: []const u8) void {
        o.sep();
        if (n.len > 0) o.out.print(o.a, "{f}:", .{std.json.fmt(n, .{})}) catch {};
    }

    pub fn str(o: *Obj, n: []const u8, v: []const u8) void {
        o.name(n);
        o.out.print(o.a, "{f}", .{std.json.fmt(v, .{})}) catch {};
    }

    /// Only when not empty (optional fields the server treats as absent).
    pub fn strOpt(o: *Obj, n: []const u8, v: []const u8) void {
        const t = std.mem.trim(u8, v, " \t\r\n");
        if (t.len > 0) o.str(n, t);
    }

    pub fn num(o: *Obj, n: []const u8, v: f64) void {
        o.name(n);
        o.out.print(o.a, "{d}", .{v}) catch {};
    }

    pub fn int(o: *Obj, n: []const u8, v: i64) void {
        o.name(n);
        o.out.print(o.a, "{d}", .{v}) catch {};
    }

    pub fn boolean(o: *Obj, n: []const u8, v: bool) void {
        o.name(n);
        o.out.appendSlice(o.a, if (v) "true" else "false") catch {};
    }

    pub fn nul(o: *Obj, n: []const u8) void {
        o.name(n);
        o.out.appendSlice(o.a, "null") catch {};
    }

    /// Already-encoded JSON.
    pub fn raw(o: *Obj, n: []const u8, json_text: []const u8) void {
        o.name(n);
        o.out.appendSlice(o.a, json_text) catch {};
    }

    pub fn value(o: *Obj, n: []const u8, v: V) void {
        o.raw(n, stringify(o.a, v));
    }

    /// A nested object; close it with `end`.
    pub fn begin(o: *Obj, n: []const u8) void {
        o.name(n);
        o.out.append(o.a, '{') catch {};
        o.depth += 1;
        o.firsts[o.depth] = true;
    }

    /// A nested array; add members with an empty name ("") and close it with `endArray`.
    pub fn beginArray(o: *Obj, n: []const u8) void {
        o.name(n);
        o.out.append(o.a, '[') catch {};
        o.depth += 1;
        o.firsts[o.depth] = true;
    }

    pub fn end(o: *Obj) void {
        o.out.append(o.a, '}') catch {};
        o.depth -= 1;
    }

    pub fn endArray(o: *Obj) void {
        o.out.append(o.a, ']') catch {};
        o.depth -= 1;
    }

    pub fn done(o: *Obj) []const u8 {
        o.out.append(o.a, '}') catch {};
        return o.out.items;
    }
};

test "paths and the writer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = parse(a, "{\"a\":{\"b\":[1,{\"c\":\"x\"}]},\"n\":2.5,\"t\":true}").?;
    try std.testing.expectEqualStrings("x", str(v, "a.b.1.c"));
    try std.testing.expectEqual(@as(f64, 2.5), num(v, "n").?);
    try std.testing.expect(boolean(v, "t"));
    try std.testing.expectEqual(@as(usize, 2), arr(v, "a.b").len);
    var b = Obj.init(a);
    b.str("name", "A \"q\"");
    b.begin("x");
    b.num("n", 1);
    b.end();
    b.beginArray("l");
    b.str("", "p");
    b.int("", 3);
    b.endArray();
    try std.testing.expectEqualStrings("{\"name\":\"A \\\"q\\\"\",\"x\":{\"n\":1},\"l\":[\"p\",3]}", b.done());
}
