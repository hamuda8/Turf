//! A JavaScript-like dynamic value, so the port keeps Turf-js's document shapes exactly: objects
//! keep key order, numbers are f64, `undef` is JavaScript's `undefined` (left out of JSON objects,
//! stored as null by the Node MongoDB driver), dates are milliseconds and ObjectIds stay typed.
//! Converts to and from JSON (the way `JSON.stringify` / Express send it) and BSON (the way the
//! Node driver writes it: whole numbers that fit in 32 bits as int32, everything else as double).
//!
//! Objects and arrays are pointers, so like in JavaScript a change through one reference is seen
//! through every other. Everything is allocated from an arena that lives as long as the request.

const std = @import("std");
const bson = @import("mongo").bson;

pub const ObjectId = bson.ObjectId;
pub const Allocator = std.mem.Allocator;

/// A JavaScript `Date` (milliseconds since the epoch). Wrapped so `from` can tell it from a number.
pub const Date = struct { ms: i64 };

pub const Val = union(enum) {
    undef,
    null,
    bool: bool,
    num: f64,
    str: []const u8,
    arr: *Arr,
    obj: *Obj,
    oid: ObjectId,
    date: i64,
    bin: []const u8,

    pub const empty_str: Val = .{ .str = "" };

    // ---- Reading -------------------------------------------------------------------------

    /// `v[key]` for objects, else undefined.
    pub fn get(v: Val, key: []const u8) Val {
        return switch (v) {
            .obj => |o| o.get(key) orelse .undef,
            .arr => |a| if (std.fmt.parseInt(usize, key, 10)) |i| (if (i < a.items.items.len) a.items.items[i] else .undef) else |_| (if (std.mem.eql(u8, key, "length")) Val{ .num = @floatFromInt(a.items.items.len) } else .undef),
            else => .undef,
        };
    }

    /// `v.a.b.c` with optional chaining: undefined as soon as a step is missing.
    pub fn path(v: Val, p: []const u8) Val {
        var cur = v;
        var it = std.mem.splitScalar(u8, p, '.');
        while (it.next()) |k| {
            cur = cur.get(k);
            if (cur == .undef) return .undef;
        }
        return cur;
    }

    pub fn at(v: Val, i: usize) Val {
        return switch (v) {
            .arr => |a| if (i < a.items.items.len) a.items.items[i] else .undef,
            else => .undef,
        };
    }

    /// The elements of an array (empty for anything else).
    pub fn items(v: Val) []Val {
        return switch (v) {
            .arr => |a| a.items.items,
            else => &.{},
        };
    }

    pub fn len(v: Val) usize {
        return switch (v) {
            .arr => |a| a.items.items.len,
            .str => |x| x.len,
            else => 0,
        };
    }

    pub fn asStr(v: Val) ?[]const u8 {
        return switch (v) {
            .str => |x| x,
            else => null,
        };
    }

    pub fn asNum(v: Val) ?f64 {
        return switch (v) {
            .num => |x| x,
            else => null,
        };
    }

    pub fn boolean(v: Val) ?bool {
        return switch (v) {
            .bool => |b| b,
            else => null,
        };
    }

    pub fn objectId(v: Val) ?ObjectId {
        return switch (v) {
            .oid => |x| x,
            else => null,
        };
    }

    pub fn dateMs(v: Val) ?i64 {
        return switch (v) {
            .date => |d| d,
            else => null,
        };
    }

    pub fn asObj(v: Val) ?*Obj {
        return switch (v) {
            .obj => |o| o,
            else => null,
        };
    }

    /// Field shortcuts: `v.s("name")` is `v.name` when it is a string.
    pub fn s(v: Val, key: []const u8) ?[]const u8 {
        return v.get(key).asStr();
    }
    pub fn n(v: Val, key: []const u8) ?f64 {
        return v.get(key).asNum();
    }
    pub fn id(v: Val, key: []const u8) ?ObjectId {
        return v.get(key).objectId();
    }
    /// `Boolean(v[key])`
    pub fn t(v: Val, key: []const u8) bool {
        return v.get(key).truthy();
    }

    pub fn isUndef(v: Val) bool {
        return v == .undef;
    }

    /// `v === null || v === undefined`
    pub fn isNullish(v: Val) bool {
        return v == .undef or v == .null;
    }

    /// `v === undefined || v === null || v === ''`: what the validators call missing.
    pub fn isMissing(v: Val) bool {
        return switch (v) {
            .undef, .null => true,
            .str => |x| x.len == 0,
            else => false,
        };
    }

    pub fn isObj(v: Val) bool {
        return v == .obj;
    }
    pub fn isArr(v: Val) bool {
        return v == .arr;
    }

    /// JavaScript truthiness.
    pub fn truthy(v: Val) bool {
        return switch (v) {
            .undef, .null => false,
            .bool => |b| b,
            .num => |x| x != 0 and !std.math.isNan(x),
            .str => |x| x.len > 0,
            else => true,
        };
    }

    /// `===` for primitives, `.equals()` for ObjectIds, same reference for objects and arrays.
    pub fn eql(a: Val, b: Val) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .undef, .null => true,
            .bool => |x| x == b.bool,
            .num => |x| x == b.num,
            .str => |x| std.mem.eql(u8, x, b.str),
            .oid => |x| std.mem.eql(u8, &x.bytes, &b.oid.bytes),
            .date => |x| x == b.date,
            .arr => |x| x == b.arr,
            .obj => |x| x == b.obj,
            .bin => |x| std.mem.eql(u8, x, b.bin),
        };
    }

    /// Same id: ObjectIds by value, strings by text (`String(a) === String(b)` on ids).
    pub fn sameId(a: Val, b: Val) bool {
        if (a == .oid and b == .oid) return std.mem.eql(u8, &a.oid.bytes, &b.oid.bytes);
        if (a == .str and b == .str) return std.mem.eql(u8, a.str, b.str);
        if (a == .oid and b == .str) return std.mem.eql(u8, &a.oid.toHex(), b.str);
        if (a == .str and b == .oid) return std.mem.eql(u8, a.str, &b.oid.toHex());
        return false;
    }

    // ---- Writing -------------------------------------------------------------------------

    /// `v[key] = x` (v must be an object). `x` is anything `from` accepts.
    pub fn set(v: Val, key: []const u8, x: anytype) !void {
        const o = v.asObj() orelse return error.NotAnObject;
        try o.put(key, try from(o.a, x));
    }

    pub fn push(v: Val, x: anytype) !void {
        const arr_ = switch (v) {
            .arr => |a| a,
            else => return error.NotAnArray,
        };
        try arr_.items.append(arr_.a, try from(arr_.a, x));
    }

    /// `delete v[key]`
    pub fn del(v: Val, key: []const u8) void {
        if (v.asObj()) |o| o.remove(key);
    }

    /// A shallow copy (`{ ...v }` or `[...v]`).
    pub fn copy(v: Val, a: Allocator) !Val {
        return switch (v) {
            .obj => |o| .{ .obj = try o.clone(a) },
            .arr => |x| blk: {
                const out = try newArr(a);
                try out.arr.items.appendSlice(a, x.items.items);
                break :blk out;
            },
            else => v,
        };
    }

    /// A deep copy (structuredClone).
    pub fn deepCopy(v: Val, a: Allocator) !Val {
        return switch (v) {
            .obj => |o| blk: {
                const out = try newObj(a);
                for (o.keys.items, o.vals.items) |k, x| try out.obj.put(try a.dupe(u8, k), try x.deepCopy(a));
                break :blk out;
            },
            .arr => |x| blk: {
                const out = try newArr(a);
                for (x.items.items) |e| try out.arr.items.append(a, try e.deepCopy(a));
                break :blk out;
            },
            .str => |x| .{ .str = try a.dupe(u8, x) },
            .bin => |x| .{ .bin = try a.dupe(u8, x) },
            else => v,
        };
    }

    pub fn jsonStringify(v: Val, w: *std.json.Stringify) !void {
        try writeJson(v, w);
    }
};

pub const Obj = struct {
    a: Allocator,
    keys: std.ArrayList([]const u8) = .empty,
    vals: std.ArrayList(Val) = .empty,

    pub fn get(o: *const Obj, key: []const u8) ?Val {
        for (o.keys.items, 0..) |k, i| if (std.mem.eql(u8, k, key)) return o.vals.items[i];
        return null;
    }

    pub fn has(o: *const Obj, key: []const u8) bool {
        return o.get(key) != null;
    }

    /// Sets `key`, keeping its position when it exists (JavaScript property order).
    pub fn put(o: *Obj, key: []const u8, v: Val) !void {
        for (o.keys.items, 0..) |k, i| if (std.mem.eql(u8, k, key)) {
            o.vals.items[i] = v;
            return;
        };
        try o.keys.append(o.a, key);
        try o.vals.append(o.a, v);
    }

    pub fn remove(o: *Obj, key: []const u8) void {
        for (o.keys.items, 0..) |k, i| if (std.mem.eql(u8, k, key)) {
            _ = o.keys.orderedRemove(i);
            _ = o.vals.orderedRemove(i);
            return;
        };
    }

    pub fn count(o: *const Obj) usize {
        return o.keys.items.len;
    }

    pub fn clone(o: *const Obj, a: Allocator) !*Obj {
        const out = try a.create(Obj);
        out.* = .{ .a = a };
        try out.keys.appendSlice(a, o.keys.items);
        try out.vals.appendSlice(a, o.vals.items);
        return out;
    }
};

pub const Arr = struct {
    a: Allocator,
    items: std.ArrayList(Val) = .empty,
};

pub fn newObj(a: Allocator) !Val {
    const o = try a.create(Obj);
    o.* = .{ .a = a };
    return .{ .obj = o };
}

pub fn newArr(a: Allocator) !Val {
    const x = try a.create(Arr);
    x.* = .{ .a = a };
    return .{ .arr = x };
}

/// An array of the given values.
pub fn arrOf(a: Allocator, vals: []const Val) !Val {
    const out = try newArr(a);
    try out.arr.items.appendSlice(a, vals);
    return out;
}

pub fn strVal(s: []const u8) Val {
    return .{ .str = s };
}

pub fn numVal(x: anytype) Val {
    return .{ .num = switch (@typeInfo(@TypeOf(x))) {
        .int, .comptime_int => @floatFromInt(x),
        else => @floatCast(x),
    } };
}

/// `{ ...a, ...b, ... }`: a new object with the fields of each object in order.
pub fn spread(a: Allocator, parts: anytype) !Val {
    const out = try newObj(a);
    inline for (parts) |p| {
        const v = try from(a, p);
        if (v.asObj()) |o| for (o.keys.items, o.vals.items) |k, x| try out.obj.put(k, x);
    }
    return out;
}

/// Converts a Zig value to a Val: Val as is; strings; numbers; bools; null; optionals (null
/// becomes `undefined`, so a missing optional field is left out of JSON and stored as null, like
/// a JavaScript `undefined`); ObjectId; Date; struct literals become objects (in field order);
/// tuples and slices become arrays.
pub fn from(a: Allocator, x: anytype) error{OutOfMemory}!Val {
    const T = @TypeOf(x);
    switch (T) {
        Val => return x,
        ObjectId => return .{ .oid = x },
        Date => return .{ .date = x.ms },
        bson.DateTime => return .{ .date = x.ms },
        bson.Doc => return fromBson(a, x) catch .null,
        *Obj => return .{ .obj = x },
        *Arr => return .{ .arr = x },
        else => {},
    }
    switch (@typeInfo(T)) {
        .bool => return .{ .bool = x },
        .int, .comptime_int => return .{ .num = @floatFromInt(x) },
        .float, .comptime_float => return .{ .num = @floatCast(x) },
        .null => return .null,
        .optional => return if (x) |y| from(a, y) else .undef,
        .@"enum", .enum_literal => return .{ .str = @tagName(x) },
        .pointer => |p| {
            if (p.size == .one) switch (@typeInfo(p.child)) {
                .array => |arr_info| {
                    if (arr_info.child == u8) return .{ .str = x };
                    const out = try newArr(a);
                    for (x) |e| try out.arr.items.append(a, try from(a, e));
                    return out;
                },
                else => return from(a, x.*),
            };
            if (p.child == u8) return .{ .str = x };
            const out = try newArr(a);
            for (x) |e| try out.arr.items.append(a, try from(a, e));
            return out;
        },
        .array => |arr_info| {
            if (arr_info.child == u8) return .{ .str = try a.dupe(u8, &x) };
            const out = try newArr(a);
            for (x) |e| try out.arr.items.append(a, try from(a, e));
            return out;
        },
        .@"struct" => |st| {
            if (st.is_tuple) {
                const out = try newArr(a);
                inline for (x) |e| try out.arr.items.append(a, try from(a, e));
                return out;
            }
            const out = try newObj(a);
            inline for (comptime std.meta.fieldNames(T)) |name| {
                try out.obj.put(name, try from(a, @field(x, name)));
            }
            return out;
        },
        else => @compileError("cannot convert " ++ @typeName(T) ++ " to Val"),
    }
}

// ---- JSON -------------------------------------------------------------------------------------

pub const ParseError = error{ InvalidJson, OutOfMemory };

/// Parses JSON text (any value at the top). Duplicate keys: the last one wins, like JSON.parse.
pub fn parseJson(a: Allocator, text: []const u8) ParseError!Val {
    var scanner = std.json.Scanner.initCompleteInput(a, text);
    defer scanner.deinit();
    const v = parseValue(a, &scanner, 0) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidJson,
    };
    const end = scanner.next() catch return error.InvalidJson;
    if (end != .end_of_document) return error.InvalidJson;
    return v;
}

fn parseValue(a: Allocator, sc: *std.json.Scanner, depth: usize) !Val {
    if (depth > 200) return error.InvalidJson;
    const tok = try sc.nextAlloc(a, .alloc_always);
    return switch (tok) {
        .object_begin => blk: {
            const out = try newObj(a);
            while (true) {
                const k = try sc.nextAlloc(a, .alloc_always);
                switch (k) {
                    .object_end => break,
                    .allocated_string => |key| try out.obj.put(key, try parseValue(a, sc, depth + 1)),
                    else => return error.InvalidJson,
                }
            }
            break :blk out;
        },
        .array_begin => blk: {
            const out = try newArr(a);
            while (true) {
                if (try sc.peekNextTokenType() == .array_end) {
                    _ = try sc.next();
                    break;
                }
                try out.arr.items.append(a, try parseValue(a, sc, depth + 1));
            }
            break :blk out;
        },
        .allocated_string => |x| .{ .str = x },
        .allocated_number => |x| .{ .num = std.fmt.parseFloat(f64, x) catch return error.InvalidJson },
        .true => .{ .bool = true },
        .false => .{ .bool = false },
        .null => .null,
        else => error.InvalidJson,
    };
}

/// `JSON.stringify(v)`.
pub fn toJson(a: Allocator, v: Val) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    var w: std.json.Stringify = .{ .writer = &out.writer };
    try writeJson(v, &w);
    return out.written();
}

fn writeJson(v: Val, w: *std.json.Stringify) std.Io.Writer.Error!void {
    switch (v) {
        .undef, .null => try w.write(null),
        .bool => |b| try w.write(b),
        .num => |x| {
            try w.beginWriteRaw();
            try writeNumber(w.writer, x);
            w.endWriteRaw();
        },
        .str => |x| try w.write(x),
        .oid => |x| try w.write(&x.toHex()),
        .date => |ms| {
            var buf: [32]u8 = undefined;
            try w.write(isoTime(&buf, ms));
        },
        .bin => |x| {
            // bson's Binary.toJSON: base64 text.
            try w.beginWriteRaw();
            try w.writer.writeByte('"');
            try std.base64.standard.Encoder.encodeWriter(w.writer, x);
            try w.writer.writeByte('"');
            w.endWriteRaw();
        },
        .arr => |x| {
            try w.beginArray();
            for (x.items.items) |e| try writeJson(e, w);
            try w.endArray();
        },
        .obj => |o| {
            try w.beginObject();
            for (o.keys.items, o.vals.items) |k, e| {
                if (e == .undef) continue;
                try w.objectField(k);
                try writeJson(e, w);
            }
            try w.endObject();
        },
    }
}

/// JSON that keeps types (Extended JSON style: {"$date": ms}, {"$oid": hex}, {"$bin": base64}),
/// for keeping a value outside the request arena (caches) and reading it back with
/// `parseJsonDates`.
pub fn toJsonTyped(a: Allocator, v: Val) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    try writeTyped(&out.writer, v);
    return out.written();
}

fn writeTyped(w: *std.Io.Writer, v: Val) std.Io.Writer.Error!void {
    switch (v) {
        .undef => try w.writeAll("{\"$undef\":1}"),
        .null => try w.writeAll("null"),
        .bool => |b| try w.writeAll(if (b) "true" else "false"),
        .num => |x| if (std.math.isFinite(x)) try writeNumber(w, x) else try w.writeAll("null"),
        .str => |x| try std.json.Stringify.encodeJsonString(x, .{}, w),
        .oid => |x| try w.print("{{\"$oid\":\"{s}\"}}", .{&x.toHex()}),
        .date => |ms| try w.print("{{\"$date\":{d}}}", .{ms}),
        .bin => |x| {
            try w.writeAll("{\"$bin\":\"");
            try std.base64.standard.Encoder.encodeWriter(w, x);
            try w.writeAll("\"}");
        },
        .arr => |x| {
            try w.writeByte('[');
            for (x.items.items, 0..) |e, i| {
                if (i > 0) try w.writeByte(',');
                try writeTyped(w, e);
            }
            try w.writeByte(']');
        },
        .obj => |o| {
            try w.writeByte('{');
            for (o.keys.items, o.vals.items, 0..) |k, e, i| {
                if (i > 0) try w.writeByte(',');
                try std.json.Stringify.encodeJsonString(k, .{}, w);
                try w.writeByte(':');
                try writeTyped(w, e);
            }
            try w.writeByte('}');
        },
    }
}

/// Reads `toJsonTyped` output back.
pub fn parseJsonDates(a: Allocator, text: []const u8) !Val {
    return revive(a, try parseJson(a, text));
}

fn revive(a: Allocator, v: Val) !Val {
    switch (v) {
        .obj => |o| {
            if (o.count() == 1) {
                const k = o.keys.items[0];
                const x = o.vals.items[0];
                if (std.mem.eql(u8, k, "$date")) if (x.asNum()) |ms| return .{ .date = @intFromFloat(ms) };
                if (std.mem.eql(u8, k, "$oid")) if (x.asStr()) |h| return .{ .oid = ObjectId.parse(h) catch return v };
                if (std.mem.eql(u8, k, "$undef")) return .undef;
                if (std.mem.eql(u8, k, "$bin")) if (x.asStr()) |b| {
                    const out = try a.alloc(u8, std.base64.standard.Decoder.calcSizeForSlice(b) catch return v);
                    std.base64.standard.Decoder.decode(out, b) catch return v;
                    return .{ .bin = out };
                };
            }
            for (o.vals.items) |*e| e.* = try revive(a, e.*);
            return v;
        },
        .arr => |x| {
            for (x.items.items) |*e| e.* = try revive(a, e.*);
            return v;
        },
        else => return v,
    }
}

/// A number the way JavaScript prints it (`String(x)`); NaN and infinities as `null` (JSON).
pub fn writeNumber(w: *std.Io.Writer, x: f64) !void {
    if (!std.math.isFinite(x)) return w.writeAll("null");
    if (x == @trunc(x) and @abs(x) < 1e21) {
        if (@abs(x) < 9.007199254740992e15) return w.print("{d}", .{@as(i64, @intFromFloat(x))});
        return w.print("{d:.0}", .{x});
    }
    if (@abs(x) >= 1e21 or (@abs(x) < 1e-6 and x != 0)) return w.print("{e}", .{x});
    return w.print("{d}", .{x});
}

/// `String(x)` for a number.
pub fn numStr(a: Allocator, x: f64) ![]const u8 {
    if (std.math.isNan(x)) return "NaN";
    if (std.math.isInf(x)) return if (x > 0) "Infinity" else "-Infinity";
    var out: std.Io.Writer.Allocating = .init(a);
    try writeNumber(&out.writer, x);
    return out.written();
}

/// "2026-10-11T12:00:00.000Z" (Date.prototype.toISOString)
pub fn isoTime(buf: []u8, ms: i64) []const u8 {
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@divFloor(ms, 1000)) };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        yd.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(), @as(u64, @intCast(@mod(ms, 1000))),
    }) catch unreachable;
}

pub fn isoAlloc(a: Allocator, ms: i64) ![]const u8 {
    var buf: [32]u8 = undefined;
    return a.dupe(u8, isoTime(&buf, ms));
}

/// `new Date(text).getTime()` for the formats Turf's clients send: ISO dates ("2026-10-11",
/// "2026-10-11T12:30", "2026-10-11T12:30:00.000Z", "+03:00" offsets) and epoch milliseconds.
/// A date-only string is UTC; a date-time without a zone is local time, taken as UTC here
/// (the servers run in UTC). Null for anything else (an Invalid Date).
pub fn parseDate(text: []const u8) ?i64 {
    const s = std.mem.trim(u8, text, " ");
    if (s.len < 4) return null;
    var i: usize = 0;
    const digits = struct {
        fn take(src: []const u8, pos: *usize, count_: usize) ?i64 {
            if (pos.* + count_ > src.len) return null;
            const v = std.fmt.parseInt(i64, src[pos.* .. pos.* + count_], 10) catch return null;
            for (src[pos.* .. pos.* + count_]) |c| if (!std.ascii.isDigit(c)) return null;
            pos.* += count_;
            return v;
        }
    };
    const year = digits.take(s, &i, 4) orelse return null;
    var month: i64 = 1;
    var day: i64 = 1;
    var hh: i64 = 0;
    var mm: i64 = 0;
    var ss: i64 = 0;
    var frac: i64 = 0;
    var offset_min: i64 = 0;
    if (i < s.len and s[i] == '-') {
        i += 1;
        month = digits.take(s, &i, 2) orelse return null;
        if (i < s.len and s[i] == '-') {
            i += 1;
            day = digits.take(s, &i, 2) orelse return null;
        }
    }
    if (i < s.len and (s[i] == 'T' or s[i] == ' ')) {
        i += 1;
        hh = digits.take(s, &i, 2) orelse return null;
        if (i >= s.len or s[i] != ':') return null;
        i += 1;
        mm = digits.take(s, &i, 2) orelse return null;
        if (i < s.len and s[i] == ':') {
            i += 1;
            ss = digits.take(s, &i, 2) orelse return null;
            if (i < s.len and s[i] == '.') {
                i += 1;
                const start = i;
                while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
                if (i == start) return null;
                const f = s[start..@min(i, start + 3)];
                frac = std.fmt.parseInt(i64, f, 10) catch return null;
                var k = f.len;
                while (k < 3) : (k += 1) frac *= 10;
            }
        }
        if (i < s.len and s[i] == 'Z') {
            i += 1;
        } else if (i < s.len and (s[i] == '+' or s[i] == '-')) {
            const sign: i64 = if (s[i] == '-') -1 else 1;
            i += 1;
            const oh = digits.take(s, &i, 2) orelse return null;
            if (i < s.len and s[i] == ':') i += 1;
            const om = digits.take(s, &i, 2) orelse return null;
            offset_min = sign * (oh * 60 + om);
        }
    }
    if (i != s.len) return null;
    if (month < 1 or month > 12 or day < 1 or day > 31 or hh > 24 or mm > 59 or ss > 59) return null;
    const days = daysFromCivil(year, month, day);
    if (day > daysInMonth(year, month)) return null;
    return ((days * 86400 + hh * 3600 + mm * 60 + ss) - offset_min * 60) * 1000 + frac;
}

pub fn daysInMonth(year: i64, month: i64) i64 {
    const leap = (@mod(year, 4) == 0 and @mod(year, 100) != 0) or @mod(year, 400) == 0;
    return switch (month) {
        2 => if (leap) 29 else 28,
        4, 6, 9, 11 => 30,
        else => 31,
    };
}

/// Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's algorithm).
pub fn daysFromCivil(y_: i64, m: i64, d: i64) i64 {
    const y = if (m <= 2) y_ - 1 else y_;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = if (m > 2) m - 3 else m + 9;
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

pub const Civil = struct { year: i64, month: i64, day: i64, hour: i64, minute: i64, second: i64, weekday: i64 };

/// UTC calendar fields of a time (weekday 0 = Sunday, like getUTCDay).
pub fn civil(ms: i64) Civil {
    const secs = @divFloor(ms, 1000);
    const days = @divFloor(secs, 86400);
    const rem = secs - days * 86400;
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    const y = yoe + era * 400 + @as(i64, if (m <= 2) 1 else 0);
    return .{ .year = y, .month = m, .day = d, .hour = @divFloor(rem, 3600), .minute = @divFloor(@mod(rem, 3600), 60), .second = @mod(rem, 60), .weekday = @mod(days + 4, 7) };
}

// ---- BSON -------------------------------------------------------------------------------------

pub const BsonError = error{ OutOfMemory, InvalidBson, UnsupportedBsonType };

/// A BSON document as a Val (strings are copied into `a`).
pub fn fromBson(a: Allocator, d: bson.Doc) BsonError!Val {
    const out = try newObj(a);
    var it = d.iterator();
    while (try it.next()) |e| try out.obj.put(try a.dupe(u8, e.key), try fromBsonValue(a, e.value));
    return out;
}

pub fn fromBsonValue(a: Allocator, v: bson.Value) BsonError!Val {
    return switch (v) {
        .double => |x| .{ .num = x },
        .int32 => |x| .{ .num = @floatFromInt(x) },
        .int64 => |x| .{ .num = @floatFromInt(x) },
        .string => |x| .{ .str = try a.dupe(u8, x) },
        .document => |d| fromBson(a, d),
        .array => |d| blk: {
            const out = try newArr(a);
            var it = d.iterator();
            while (try it.next()) |e| try out.arr.items.append(a, try fromBsonValue(a, e.value));
            break :blk out;
        },
        .object_id => |x| .{ .oid = x },
        .boolean => |x| .{ .bool = x },
        .datetime => |x| .{ .date = x.ms },
        .null => .null,
        .binary => |x| .{ .bin = try a.dupe(u8, x.data) },
        .timestamp => |x| .{ .num = @floatFromInt(x >> 32) },
        else => .null,
    };
}

/// A Val object (or any value `from` accepts) as a BSON document, the way the Node driver
/// serializes it (`undefined` as null).
pub fn toBson(a: Allocator, x: anytype) !bson.Doc {
    const v = try from(a, x);
    var b = try bson.Builder.init(a);
    switch (v) {
        .obj => |o| for (o.keys.items, o.vals.items) |k, e| try writeBson(&b, k, e),
        .arr => |arr_| for (arr_.items.items, 0..) |e, i| {
            var buf: [20]u8 = undefined;
            try writeBson(&b, std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable, e);
        },
        else => return error.NotAnObject,
    }
    return b.finish();
}

pub fn writeBson(b: *bson.Builder, key: []const u8, v: Val) !void {
    switch (v) {
        .undef, .null => try b.null_(key),
        .bool => |x| try b.boolean(key, x),
        .num => |x| {
            // js-bson: whole numbers within int32 range are int32, -0 and the rest are doubles.
            if (x == @trunc(x) and x >= -2147483648.0 and x <= 2147483647.0 and !(x == 0 and std.math.signbit(x)))
                try b.int32(key, @intFromFloat(x))
            else
                try b.double(key, x);
        },
        .str => |x| try b.string(key, x),
        .oid => |x| try b.objectId(key, x),
        .date => |x| try b.datetime(key, .{ .ms = x }),
        .bin => |x| try b.binary(key, .{ .data = x }),
        .arr => |x| {
            try b.beginArray(key);
            for (x.items.items) |e| try writeBson(b, "", e);
            try b.end();
        },
        .obj => |o| {
            try b.beginDoc(key);
            for (o.keys.items, o.vals.items) |k, e| try writeBson(b, k, e);
            try b.end();
        },
    }
}

// ---- JavaScript string helpers -------------------------------------------------------------------

/// `s.length` in JavaScript: UTF-16 code units.
pub fn jsLength(s: []const u8) usize {
    var count_: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const l = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        count_ += if (l == 4) 2 else 1;
        i += l;
    }
    return count_;
}

/// `s.slice(0, n)` in UTF-16 code units (never splits a character).
pub fn jsSlice(s: []const u8, max_units: usize) []const u8 {
    var units: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const l = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        const u: usize = if (l == 4) 2 else 1;
        if (units + u > max_units) break;
        units += u;
        i += @min(l, s.len - i);
    }
    return s[0..i];
}

/// Whitespace that `String.prototype.trim` removes (ASCII and the common Unicode spaces).
pub fn jsTrim(s: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = s.len;
    while (start < end) {
        const l = spaceLen(s[start..]);
        if (l == 0) break;
        start += l;
    }
    while (end > start) {
        var k: usize = 1;
        var found = false;
        while (k <= 3 and k <= end - start) : (k += 1) {
            if (spaceLen(s[end - k .. end]) == k) {
                end -= k;
                found = true;
                break;
            }
        }
        if (!found) break;
    }
    return s[start..end];
}

fn spaceLen(s: []const u8) usize {
    if (s.len == 0) return 0;
    switch (s[0]) {
        ' ', '\t', '\n', '\r', 0x0b, 0x0c => return 1,
        else => {},
    }
    const seqs = [_][]const u8{ "\u{00A0}", "\u{FEFF}", "\u{2028}", "\u{2029}", "\u{202F}", "\u{205F}", "\u{3000}", "\u{1680}", "\u{2000}", "\u{2001}", "\u{2002}", "\u{2003}", "\u{2004}", "\u{2005}", "\u{2006}", "\u{2007}", "\u{2008}", "\u{2009}", "\u{200A}" };
    for (seqs) |q| if (std.mem.startsWith(u8, s, q)) return q.len;
    return 0;
}

/// `s.toLowerCase()` for ASCII letters (other characters are kept).
pub fn lower(a: Allocator, s: []const u8) ![]const u8 {
    const out = try a.dupe(u8, s);
    for (out) |*c| c.* = std.ascii.toLower(c.*);
    return out;
}

pub fn upper(a: Allocator, s: []const u8) ![]const u8 {
    const out = try a.dupe(u8, s);
    for (out) |*c| c.* = std.ascii.toUpper(c.*);
    return out;
}

/// `String(v)` for the values that reach text: strings, numbers, ids, booleans.
pub fn toStr(a: Allocator, v: Val) ![]const u8 {
    return switch (v) {
        .str => |x| x,
        .num => |x| numStr(a, x),
        .oid => |x| a.dupe(u8, &x.toHex()),
        .bool => |b| if (b) "true" else "false",
        .null => "null",
        .undef => "undefined",
        .date => |ms| isoAlloc(a, ms),
        .arr => |x| blk: {
            var out: std.ArrayList(u8) = .empty;
            for (x.items.items, 0..) |e, i| {
                if (i > 0) try out.append(a, ',');
                if (!e.isNullish()) try out.appendSlice(a, try toStr(a, e));
            }
            break :blk out.items;
        },
        .obj => "[object Object]",
        .bin => |x| x,
    };
}

/// `Number(v)` (NaN when not a number).
pub fn toNum(v: Val) f64 {
    return switch (v) {
        .num => |x| x,
        .bool => |b| if (b) 1 else 0,
        .null => 0,
        .str => |x| strToNum(x),
        .date => |ms| @floatFromInt(ms),
        else => std.math.nan(f64),
    };
}

/// `Number("...")`: empty or blank is 0, anything else must be a whole number literal.
pub fn strToNum(text: []const u8) f64 {
    const s = jsTrim(text);
    if (s.len == 0) return 0;
    if (std.mem.eql(u8, s, "Infinity") or std.mem.eql(u8, s, "+Infinity")) return std.math.inf(f64);
    if (std.mem.eql(u8, s, "-Infinity")) return -std.math.inf(f64);
    if (s.len > 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X')) {
        return @floatFromInt(std.fmt.parseInt(u64, s[2..], 16) catch return std.math.nan(f64));
    }
    for (s) |c| if (!(std.ascii.isDigit(c) or c == '.' or c == 'e' or c == 'E' or c == '+' or c == '-')) return std.math.nan(f64);
    return std.fmt.parseFloat(f64, s) catch std.math.nan(f64);
}

/// `Math.max(a, b)`: NaN when either is NaN.
pub fn jsMax(x: f64, y: f64) f64 {
    if (std.math.isNan(x) or std.math.isNan(y)) return std.math.nan(f64);
    return @max(x, y);
}

pub fn jsMin(x: f64, y: f64) f64 {
    if (std.math.isNan(x) or std.math.isNan(y)) return std.math.nan(f64);
    return @min(x, y);
}

/// `(v || 0)` for a number field.
pub fn or0(v: Val) f64 {
    return if (v.truthy()) toNum(v) else 0;
}

/// `(v ?? d)` for a number field.
pub fn numOr(v: Val, d: f64) f64 {
    return if (v.isNullish()) d else toNum(v);
}

/// A number as a Val, NaN included (JSON prints it as null, like JavaScript).
pub fn numV(x: f64) Val {
    return .{ .num = x };
}

/// `Math.round`: halves go up (towards +Infinity).
pub fn jsRound(x: f64) f64 {
    return @floor(x + 0.5);
}

/// `Math.round(x * 10^d) / 10^d`
pub fn round(x: f64, comptime d: u32) f64 {
    const f = std.math.pow(f64, 10, d);
    return jsRound(x * f) / f;
}

/// `parseInt(s, 10)`: leading whitespace, optional sign, then digits; NaN without digits.
pub fn parseIntJs(s_: []const u8) f64 {
    const s = jsTrim(s_);
    var i: usize = 0;
    var neg = false;
    if (i < s.len and (s[i] == '+' or s[i] == '-')) {
        neg = s[i] == '-';
        i += 1;
    }
    const start = i;
    var v: f64 = 0;
    while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) v = v * 10 + @as(f64, @floatFromInt(s[i] - '0'));
    if (i == start) return std.math.nan(f64);
    return if (neg) -v else v;
}

/// `parseFloat(s)`
pub fn parseFloatJs(s_: []const u8) f64 {
    const s = jsTrim(s_);
    var i: usize = 0;
    if (i < s.len and (s[i] == '+' or s[i] == '-')) i += 1;
    while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
    if (i < s.len and s[i] == '.') {
        i += 1;
        while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
    }
    if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
        var j = i + 1;
        if (j < s.len and (s[j] == '+' or s[j] == '-')) j += 1;
        const ds = j;
        while (j < s.len and std.ascii.isDigit(s[j])) j += 1;
        if (j > ds) i = j;
    }
    return std.fmt.parseFloat(f64, s[0..i]) catch std.math.nan(f64);
}

/// Whether `list` (an array of strings) contains `s`.
pub fn includesStr(list: Val, s: []const u8) bool {
    for (list.items()) |e| if (e == .str and std.mem.eql(u8, e.str, s)) return true;
    return false;
}

/// Whether `list` contains a value equal to `x` (ids by value).
pub fn includesId(list: Val, x: Val) bool {
    for (list.items()) |e| if (e.sameId(x)) return true;
    return false;
}

pub fn contains(comptime T: type, list: []const T, x: T) bool {
    for (list) |e| {
        if (T == []const u8) {
            if (std.mem.eql(u8, e, x)) return true;
        } else if (e == x) return true;
    }
    return false;
}

pub fn eqlStr(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

const testing = std.testing;

test "JSON round trip keeps key order, numbers and leaves undefined out" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try parseJson(a, "{\"b\":1,\"a\":[1.5,\"x\",null,true],\"c\":{\"d\":-2}}");
    try v.set("e", @as(?u8, null));
    try v.set("f", Date{ .ms = 0 });
    try testing.expectEqualStrings("{\"b\":1,\"a\":[1.5,\"x\",null,true],\"c\":{\"d\":-2},\"f\":\"1970-01-01T00:00:00.000Z\"}", try toJson(a, v));
    try testing.expectEqual(@as(f64, -2), v.path("c.d").asNum().?);
}

test "numbers print like JavaScript" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("5", try numStr(a, 5.0));
    try testing.expectEqualStrings("0.1", try numStr(a, 0.1));
    try testing.expectEqualStrings("1234.56", try numStr(a, 1234.56));
    try testing.expectEqualStrings("-3", try numStr(a, -3.0));
    var x: f64 = 0.1;
    x += 0.2;
    try testing.expectEqualStrings("0.30000000000000004", try numStr(a, x));
}

test "BSON round trip" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const id = ObjectId.generateAt(testing.io, 1);
    const d = try toBson(a, .{ ._id = id, .n = 3, .f = 2.5, .big = 1e12, .s = "x", .u = @as(?u8, null), .at = Date{ .ms = 5 }, .l = .{ 1, "a" } });
    try testing.expectEqual(@as(i32, 3), d.get("n").?.int32);
    try testing.expectEqual(@as(f64, 1e12), d.get("big").?.double);
    try testing.expect(d.get("u").? == .null);
    const v = try fromBson(a, d);
    try testing.expect(v.get("_id").sameId(.{ .oid = id }));
    try testing.expectEqual(@as(i64, 5), v.get("at").date);
    try testing.expectEqualStrings("a", v.get("l").at(1).str);
}

test "dates" {
    try testing.expectEqual(@as(?i64, 0), parseDate("1970-01-01"));
    try testing.expectEqual(@as(?i64, 1_791_720_000_000), parseDate("2026-10-11T12:00:00.000Z"));
    try testing.expectEqual(@as(?i64, 1_791_720_000_000), parseDate("2026-10-11T15:00:00+03:00"));
    try testing.expectEqual(@as(?i64, null), parseDate("nope"));
    const c = civil(1_791_720_000_000);
    try testing.expectEqual(@as(i64, 2026), c.year);
    try testing.expectEqual(@as(i64, 10), c.month);
    try testing.expectEqual(@as(i64, 11), c.day);
    try testing.expectEqual(@as(i64, 12), c.hour);
    try testing.expectEqual(@as(i64, 0), c.weekday);
}

test "string helpers" {
    try testing.expectEqual(@as(usize, 3), jsLength("دمش"));
    try testing.expectEqualStrings("ab", jsTrim("\u{00A0} ab \n"));
    try testing.expectEqualStrings("دم", jsSlice("دمشق", 2));
    try testing.expectEqual(@as(f64, 12), parseIntJs(" 12px"));
    try testing.expect(std.math.isNan(strToNum("12px")));
    try testing.expectEqual(@as(f64, 0), strToNum(""));
}

/// `new Date(v).getTime()`: numbers are milliseconds, strings are parsed, null is the epoch;
/// null result for an Invalid Date.
pub fn newDate(v: Val) ?i64 {
    return switch (v) {
        .num => |x| if (std.math.isFinite(x)) @as(i64, @intFromFloat(@trunc(x))) else null,
        .str => |s| parseDate(s),
        .date => |ms| ms,
        .null => 0,
        .bool => |b| if (b) 1 else 0,
        else => null,
    };
}
