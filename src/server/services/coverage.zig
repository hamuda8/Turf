//! Where inside a governorate a carrier works (src/services/coverage.js). A covered governorate is
//! covered everywhere unless the carrier narrows it down:
//!   carrier.areas = { RD: { cities: ['Jaramana', 'جرمانا'], radiusKm: 20 } }
//! An address is covered when its city is listed, or its pin is within radiusKm of one of the
//! carrier's active hubs there. Addresses without a pin are judged by city alone; with no city
//! list there, they are accepted.

const std = @import("std");
const val = @import("../lib/val.zig");
const db = @import("../lib/db.zig");
const web = @import("../web.zig");
const geo = @import("../geo.zig");
const Val = val.Val;
const Req = web.Req;
const V = web.V;

const max_cities = 100;

/// "Al-Tall", "al tall", "التل", "تل" -> the same key. Arabic and English stay different words.
pub fn normCity(a: std.mem.Allocator, input: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var view = std.unicode.Utf8View.init(input) catch std.unicode.Utf8View.initUnchecked(input);
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        var c = cp;
        if (c < 128) c = std.ascii.toLower(@intCast(c));
        if ((c >= 0x064B and c <= 0x0652) or c == 0x0640) continue;
        if (c == 0x0623 or c == 0x0625 or c == 0x0622) c = 0x0627;
        if (c == 0x0649) c = 0x064A;
        if (c == 0x0629) c = 0x0647;
        switch (c) {
            '-', '_', '\'', 0x2019, '`', '.', ',' => c = ' ',
            else => {},
        }
        var buf: [4]u8 = undefined;
        const l = std.unicode.utf8Encode(c, &buf) catch continue;
        try out.appendSlice(a, buf[0..l]);
    }
    var col: std.ArrayList(u8) = .empty;
    var sp = false;
    for (out.items) |c| {
        if (std.ascii.isWhitespace(c)) {
            if (!sp) try col.append(a, ' ');
            sp = true;
        } else {
            try col.append(a, c);
            sp = false;
        }
    }
    var s: []const u8 = std.mem.trim(u8, col.items, " ");
    if (std.mem.startsWith(u8, s, "al ") or std.mem.startsWith(u8, s, "el ")) s = s[3..];
    const al = "ال";
    if (std.mem.startsWith(u8, s, al)) {
        const rest = s[al.len..];
        var n: usize = 0;
        var rv = std.unicode.Utf8View.initUnchecked(rest).iterator();
        while (rv.nextCodepoint()) |cp| {
            if (cp == ' ' or cp == '\t' or cp == '\n') break;
            n += 1;
            if (n >= 2) break;
        }
        if (n >= 2) s = rest;
    }
    return s;
}

fn normCityV(a: std.mem.Allocator, v: Val) ![]const u8 {
    return normCity(a, if (v.isNullish()) "" else try val.toStr(a, v));
}

/// Validates { gov: { cities, radiusKm } } for governorates the carrier covers.
pub fn parseAreas(r: *Req, value: Val, coverage: Val) !Val {
    const a = r.a;
    const out = try val.newObj(a);
    if (value.isNullish()) return out;
    _ = try V.obj(r, value, "areas", .{});
    const o = value.asObj().?;
    for (o.keys.items, o.vals.items) |gov, rule| {
        if (!val.includesStr(coverage, gov)) continue;
        const f = try std.fmt.allocPrint(a, "areas.{s}", .{gov});
        _ = try V.obj(r, rule, f, .{});
        const cities_in = rule.get("cities");
        const list = (try V.arr(r, if (cities_in.isNullish()) try val.newArr(a) else cities_in, try std.fmt.allocPrint(a, "{s}.cities", .{f}), .{ .max = max_cities })).?;
        const unique = try val.newArr(a);
        var seen: std.ArrayList([]const u8) = .empty;
        for (list, 0..) |c, i| {
            const s = (try V.str(r, c, try std.fmt.allocPrint(a, "{s}.cities[{d}]", .{ f, i }), .{ .max = 80 })).?;
            const k = try normCity(a, s);
            if (k.len > 0 and !val.contains([]const u8, seen.items, k)) {
                try seen.append(a, k);
                try unique.push(s);
            }
        }
        const rk = rule.get("radiusKm");
        const radius: Val = if (rk.isNullish() or (rk == .str and rk.str.len == 0)) .null else .{ .num = (try V.num(r, rk, try std.fmt.allocPrint(a, "{s}.radiusKm", .{f}), .{ .min = 1, .max = 300 })).? };
        if (unique.items().len > 0 or radius.truthy()) try out.obj.put(gov, try val.from(a, .{ .cities = unique, .radiusKm = radius }));
    }
    return out;
}

/// Carriers with a distance rule need their hub locations; loads them once (sets carrier._hubs).
pub fn attachHubs(a: std.mem.Allocator, carriers: []const Val) !void {
    const need = try val.newArr(a);
    var list: std.ArrayList(Val) = .empty;
    for (carriers) |c| {
        if (c.get("_hubs") != .undef) continue;
        const areas = c.path("carrier.areas").asObj() orelse continue;
        const any = for (areas.vals.items) |ar| {
            if (ar.get("radiusKm").truthy()) break true;
        } else false;
        if (!any) continue;
        try need.push(c.get("_id"));
        try list.append(a, c);
    }
    if (list.items.len == 0) return;
    const hubs = try db.col("hubs").find(a, .{ .orgId = .{ .@"$in" = need }, .active = true }, .{ .projection = try val.from(a, .{ .orgId = 1, .governorate = 1, .location = 1 }) });
    for (list.items) |c| {
        const mine = try val.newArr(a);
        for (hubs) |h| if (h.get("orgId").sameId(c.get("_id"))) try mine.push(h);
        try c.set("_hubs", mine);
    }
}

/// Is this address inside the carrier's area? (The governorate itself is checked elsewhere.)
pub fn coversAddress(a: std.mem.Allocator, carrier: Val, address: Val) !bool {
    const gov = address.get("governorate");
    const rule = if (gov.asStr()) |g| carrier.path("carrier.areas").get(g) else Val.undef;
    if (!rule.truthy()) return true;
    const key = try normCityV(a, address.get("city"));
    for (rule.get("cities").items()) |c| if (std.mem.eql(u8, try normCityV(a, c), key)) return true;
    const pin: ?Val = if (!address.path("location.coordinates").isNullish()) address.get("location") else null;
    const radius = rule.get("radiusKm");
    var hubs: std.ArrayList(Val) = .empty;
    if (radius.truthy()) for (carrier.get("_hubs").items()) |h| {
        if (h.get("governorate").eql(gov) and h.get("location").truthy()) try hubs.append(a, h);
    };
    if (pin != null and hubs.items.len > 0) {
        const rk = radius.asNum() orelse 0;
        for (hubs.items) |h| if (geo.distanceKmV(h.get("location"), pin.?) <= rk) return true;
        return false;
    }
    return rule.get("cities").items().len == 0;
}
