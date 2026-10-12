//! Geography helpers (src/geo.js): Syrian governorates (ISO 3166-2:SY codes without "SY-"),
//! vehicle profiles, and distance math.

const std = @import("std");
const val = @import("lib/val.zig");
const Val = val.Val;

pub const Governorate = struct { code: []const u8, en: []const u8, ar: []const u8, center: [2]f64, aliases: []const []const u8 };

pub const governorates = [_]Governorate{
    .{ .code = "DI", .en = "Damascus", .ar = "دمشق", .center = .{ 36.2765, 33.5138 }, .aliases = &.{ "damascus", "dimashq", "damas", "الشام" } },
    .{ .code = "RD", .en = "Rif Dimashq", .ar = "ريف دمشق", .center = .{ 36.5, 33.4 }, .aliases = &.{ "rif dimashq", "rural damascus", "damascus countryside", "rif damascus", "ريف الشام" } },
    .{ .code = "HL", .en = "Aleppo", .ar = "حلب", .center = .{ 37.1343, 36.2021 }, .aliases = &.{ "aleppo", "halab", "alep" } },
    .{ .code = "HI", .en = "Homs", .ar = "حمص", .center = .{ 36.7137, 34.7324 }, .aliases = &.{ "homs", "hims", "hommos" } },
    .{ .code = "HM", .en = "Hama", .ar = "حماة", .center = .{ 36.7578, 35.1318 }, .aliases = &.{ "hama", "hamah" } },
    .{ .code = "LA", .en = "Latakia", .ar = "اللاذقية", .center = .{ 35.7915, 35.5317 }, .aliases = &.{ "latakia", "lattakia", "ladhiqiyah", "al ladhiqiyah" } },
    .{ .code = "TA", .en = "Tartus", .ar = "طرطوس", .center = .{ 35.8866, 34.889 }, .aliases = &.{ "tartus", "tartous", "tartoos" } },
    .{ .code = "ID", .en = "Idlib", .ar = "إدلب", .center = .{ 36.6339, 35.9306 }, .aliases = &.{ "idlib", "idleb" } },
    .{ .code = "DR", .en = "Daraa", .ar = "درعا", .center = .{ 36.1021, 32.6189 }, .aliases = &.{ "daraa", "dara", "deraa" } },
    .{ .code = "SU", .en = "As-Suwayda", .ar = "السويداء", .center = .{ 36.5695, 32.709 }, .aliases = &.{ "as suwayda", "suwayda", "sweida", "as sweida", "suweida" } },
    .{ .code = "QU", .en = "Quneitra", .ar = "القنيطرة", .center = .{ 35.824, 33.125 }, .aliases = &.{ "quneitra", "al qunaytirah", "qunaytirah" } },
    .{ .code = "DY", .en = "Deir ez-Zor", .ar = "دير الزور", .center = .{ 40.1408, 35.3359 }, .aliases = &.{ "deir ez zor", "deir ezzor", "dayr az zawr", "deir al zor", "deir ez-zor" } },
    .{ .code = "RA", .en = "Raqqa", .ar = "الرقة", .center = .{ 39.0081, 35.9594 }, .aliases = &.{ "raqqa", "ar raqqah", "al raqqah", "raqqah" } },
    .{ .code = "HA", .en = "Al-Hasakah", .ar = "الحسكة", .center = .{ 40.7477, 36.5024 }, .aliases = &.{ "al hasakah", "hasakah", "hassakeh", "hasaka", "al hasaka" } },
};

pub const codes = blk: {
    var out: []const []const u8 = &.{};
    for (governorates) |g| out = out ++ &[_][]const u8{g.code};
    break :blk out;
};

pub fn governorate(code: []const u8) ?*const Governorate {
    for (&governorates) |*g| if (std.mem.eql(u8, g.code, code)) return g;
    return null;
}

pub fn isCode(code: []const u8) bool {
    return governorate(code) != null;
}

/// normName of src/geo.js: lower case, no Arabic diacritics or tatweel, one alef and one heh,
/// no "governorate"/"province" words, punctuation as spaces, no leading article.
pub fn normName(a: std.mem.Allocator, input: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var view = std.unicode.Utf8View.init(input) catch std.unicode.Utf8View.initUnchecked(input);
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        var c = cp;
        if (c < 128) c = std.ascii.toLower(@intCast(c));
        if ((c >= 0x064B and c <= 0x0652) or c == 0x0640) continue;
        if (c == 0x0623 or c == 0x0625 or c == 0x0622) c = 0x0627;
        if (c == 0x0629) c = 0x0647;
        switch (c) {
            '-', '_', '\'', 0x2019, '`', '.', ',' => c = ' ',
            else => {},
        }
        var buf: [4]u8 = undefined;
        const l = std.unicode.utf8Encode(c, &buf) catch continue;
        try out.appendSlice(a, buf[0..l]);
    }
    var s: []const u8 = out.items;
    const muhafaza = "محافظه";
    // ^(محافظه|governorate of)\s*
    if (std.mem.startsWith(u8, s, muhafaza)) {
        s = std.mem.trimStart(u8, s[muhafaza.len..], " \t\r\n");
    } else if (std.mem.startsWith(u8, s, "governorate of")) {
        s = std.mem.trimStart(u8, s["governorate of".len..], " \t\r\n");
    }
    // \s*(governorate|province|محافظه)\s*$
    {
        const t = std.mem.trimEnd(u8, s, " \t\r\n");
        for ([_][]const u8{ "governorate", "province", muhafaza }) |w| if (std.mem.endsWith(u8, t, w)) {
            s = std.mem.trimEnd(u8, t[0 .. t.len - w.len], " \t\r\n");
            break;
        };
    }
    // \s+ -> ' ', trim
    var col: std.ArrayList(u8) = .empty;
    var sp = false;
    for (s) |c| {
        if (std.ascii.isWhitespace(c)) {
            if (!sp) try col.append(a, ' ');
            sp = true;
        } else {
            try col.append(a, c);
            sp = false;
        }
    }
    s = std.mem.trim(u8, col.items, " ");
    // ^(al|el|ar|as|ad) (the article)
    for ([_][]const u8{ "al ", "el ", "ar ", "as ", "ad " }) |p| if (std.mem.startsWith(u8, s, p)) {
        s = s[p.len..];
        break;
    };
    // ^ال(?=\S{2,})
    const al = "ال";
    if (std.mem.startsWith(u8, s, al)) {
        const rest = s[al.len..];
        var cps: usize = 0;
        var rv = std.unicode.Utf8View.initUnchecked(rest).iterator();
        while (rv.nextCodepoint()) |cp| {
            if (cp == ' ' or cp == '\t') break;
            cps += 1;
            if (cps >= 2) break;
        }
        if (cps >= 2) s = rest;
    }
    return s;
}

/// "DI", "Damascus", "دمشق", "محافظة دمشق", "Rural Damascus" -> "DI". Unknown values pass through
/// trimmed (so validation can say what was wrong), or null with `strict`.
pub fn governorateCode(a: std.mem.Allocator, value: Val, strict: bool) !?[]const u8 {
    const raw: []const u8 = if (value.isNullish()) "" else try val.toStr(a, value);
    const v = try normName(a, raw);
    if (v.len == 0) return if (strict) null else (if (value.isNullish()) null else raw);
    for (governorates) |g| {
        if (std.ascii.eqlIgnoreCase(g.code, v) and std.mem.eql(u8, try val.lower(a, g.code), v)) return g.code;
        if (std.mem.eql(u8, try normName(a, g.en), v) or std.mem.eql(u8, try normName(a, g.ar), v)) return g.code;
        for (g.aliases) |al| if (std.mem.eql(u8, try normName(a, al), v)) return g.code;
    }
    for (governorates) |g| {
        if (std.mem.indexOf(u8, v, try normName(a, g.en)) != null or std.mem.indexOf(u8, v, try normName(a, g.ar)) != null) return g.code;
        for (g.aliases) |al| if (std.mem.indexOf(u8, v, try normName(a, al)) != null) return g.code;
    }
    return if (strict) null else val.jsTrim(raw);
}

/// The governorate whose centre is closest to a point.
pub fn nearestGovernorate(lat: f64, lng: f64) *const Governorate {
    var best: *const Governorate = &governorates[0];
    var best_d = std.math.inf(f64);
    for (&governorates) |*g| {
        const d = distanceKm(.{ lng, lat }, g.center);
        if (d < best_d) {
            best_d = d;
            best = g;
        }
    }
    return best;
}

pub const Vehicle = struct { name: []const u8, rangeKm: f64, capacityKg: f64, speedKmh: f64, speedLimit: ?f64, routing: []const u8 };

pub const vehicles = [_]Vehicle{
    .{ .name = "foot", .rangeKm = 6, .capacityKg = 10, .speedKmh = 4.5, .speedLimit = null, .routing = "walk" },
    .{ .name = "bicycle", .rangeKm = 15, .capacityKg = 15, .speedKmh = 14, .speedLimit = 50, .routing = "bicycle" },
    .{ .name = "ebike", .rangeKm = 30, .capacityKg = 20, .speedKmh = 20, .speedLimit = 50, .routing = "bicycle" },
    .{ .name = "motorbike", .rangeKm = 80, .capacityKg = 40, .speedKmh = 35, .speedLimit = 100, .routing = "motorcycle" },
    .{ .name = "car", .rangeKm = 600, .capacityKg = 300, .speedKmh = 45, .speedLimit = 130, .routing = "car" },
    .{ .name = "van", .rangeKm = 600, .capacityKg = 1500, .speedKmh = 45, .speedLimit = 120, .routing = "car" },
    .{ .name = "truck", .rangeKm = 1000, .capacityKg = 20000, .speedKmh = 50, .speedLimit = 100, .routing = "truck" },
};

pub const vehicle_types = blk: {
    var out: []const []const u8 = &.{};
    for (vehicles) |v| out = out ++ &[_][]const u8{v.name};
    break :blk out;
};

pub fn vehicle(name: []const u8) ?*const Vehicle {
    for (&vehicles) |*v| if (std.mem.eql(u8, v.name, name)) return v;
    return null;
}

/// VEHICLES as the API sends it ({ foot: { rangeKm, ... }, ... }).
pub fn vehiclesJson(a: std.mem.Allocator) !Val {
    const out = try val.newObj(a);
    for (vehicles) |v| try out.obj.put(v.name, try val.from(a, .{
        .rangeKm = v.rangeKm,
        .capacityKg = v.capacityKg,
        .speedKmh = v.speedKmh,
        .speedLimit = if (v.speedLimit) |x| Val{ .num = x } else Val.null,
        .routing = v.routing,
    }));
    return out;
}

const earth_radius_km = 6371.0;

fn rad(d: f64) f64 {
    return d * std.math.pi / 180.0;
}

/// Great-circle distance in km between two [lng, lat] pairs.
pub fn distanceKm(p1: [2]f64, p2: [2]f64) f64 {
    const d_lat = rad(p2[1] - p1[1]);
    const d_lng = rad(p2[0] - p1[0]);
    const h = std.math.pow(f64, @sin(d_lat / 2), 2) + @cos(rad(p1[1])) * @cos(rad(p2[1])) * std.math.pow(f64, @sin(d_lng / 2), 2);
    return 2 * earth_radius_km * std.math.asin(@sqrt(h));
}

/// [lng, lat] of a GeoJSON Point or a [lng, lat] array value.
pub fn coords(v: Val) ?[2]f64 {
    const c = if (v == .arr) v else v.get("coordinates");
    const lng = c.at(0).asNum() orelse return null;
    const lat = c.at(1).asNum() orelse return null;
    return .{ lng, lat };
}

/// distanceKm for two GeoJSON Points (or [lng, lat] arrays). NaN when one is missing.
pub fn distanceKmV(p1: Val, p2: Val) f64 {
    const x = coords(p1) orelse return std.math.nan(f64);
    const y = coords(p2) orelse return std.math.nan(f64);
    return distanceKm(x, y);
}

/// Rough road distance from straight-line distance (Syrian roads detour about 30%).
pub fn roadKm(straight: f64) f64 {
    return straight * 1.3;
}

/// The point of an address: its exact location if known, else the governorate centre.
pub fn approxPoint(a: std.mem.Allocator, address: Val) !Val {
    if (!address.path("location.coordinates").isNullish()) return address.get("location");
    const g = governorate(address.s("governorate") orelse "") orelse return .null;
    return val.from(a, .{ .type = "Point", .coordinates = .{ g.center[0], g.center[1] } });
}

test governorateCode {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("DI", (try governorateCode(a, .{ .str = "دمشق" }, false)).?);
    try std.testing.expectEqualStrings("DI", (try governorateCode(a, .{ .str = "محافظة دمشق" }, false)).?);
    try std.testing.expectEqualStrings("RD", (try governorateCode(a, .{ .str = "Rural Damascus" }, false)).?);
    try std.testing.expectEqualStrings("HL", (try governorateCode(a, .{ .str = "Aleppo Governorate, Syria" }, false)).?);
    try std.testing.expectEqualStrings("Atlantis", (try governorateCode(a, .{ .str = "Atlantis" }, false)).?);
    try std.testing.expect((try governorateCode(a, .{ .str = "Atlantis" }, true)) == null);
}
