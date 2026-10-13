//! Addresses from map pins, and a store's saved pickup places (src/services/places.js).
//!
//! A pin is enough to ship: when an address has a location but no governorate or city, Turf asks
//! Wufour Maps what is there (reverse geocoding); when Maps cannot answer, the nearest
//! governorate centre decides. Stores keep pickup places under merchant.places; one is the
//! default. The old single merchant.defaultPickup is read as a place until one is saved.

const std = @import("std");
const Io = std.Io;
const val = @import("mongo").val;
const db = @import("../lib/db.zig");
const web = @import("../web.zig");
const a_ = @import("../app.zig");
const geo = @import("../geo.zig");
const Val = val.Val;
const Req = web.Req;
const V = web.V;

const reverse_timeout_ms = 4000;
const cache_ms = 10 * 60_000;
const max_cache = 2000;

var cache_lock: Io.Mutex = .init;
/// "lat,lng" (owned) -> { value as typed JSON (owned), until }
var cache: std.StringArrayHashMapUnmanaged(struct { json: []u8, until: i64 }) = .empty;

/// What Wufour Maps knows about a point, or null (never fails).
pub fn reverseGeocode(a: std.mem.Allocator, point: Val) !Val {
    const c = geo.coords(point) orelse return .null;
    const lng = c[0];
    const lat = c[1];
    const key = try std.fmt.allocPrint(a, "{d:.4},{d:.4}", .{ lat, lng });
    const io = a_.app.io;
    const gpa = a_.app.gpa;
    {
        cache_lock.lockUncancelable(io);
        defer cache_lock.unlock(io);
        if (cache.get(key)) |hit| if (hit.until > a_.nowMs()) return val.parseJsonDates(a, hit.json);
    }
    var value: Val = .null;
    fetch: {
        const url = try std.fmt.allocPrint(a, "{s}/api/v1/reverse?lat={s}&lng={s}", .{ a_.cfg().maps_internal_url, try val.numStr(a, lat), try val.numStr(a, lng) });
        const headers: []const std.http.Header = if (a_.cfg().maps_api_key.len > 0) &.{.{ .name = "x-maps-api-key", .value = a_.cfg().maps_api_key }} else &.{};
        const res = a_.upstreamTimeout(a, url, .{ .headers = headers }, reverse_timeout_ms) catch break :fetch;
        if (@backingInt(res.status) < 200 or @backingInt(res.status) >= 300) break :fetch;
        const data = val.parseJson(a, res.body) catch break :fetch;
        if (data.get("success").truthy() and data.get("place").truthy()) value = data.get("place");
    }
    const text = try val.toJsonTyped(a, value);
    cache_lock.lockUncancelable(io);
    defer cache_lock.unlock(io);
    if (cache.count() >= max_cache) {
        const k0 = cache.keys()[0];
        const v0 = cache.values()[0];
        cache.orderedRemoveAt(0);
        gpa.free(k0);
        gpa.free(v0.json);
    }
    if (cache.fetchOrderedRemove(key)) |old| {
        gpa.free(old.key);
        gpa.free(old.value.json);
    }
    const k = gpa.dupe(u8, key) catch return value;
    const j = gpa.dupe(u8, text) catch {
        gpa.free(k);
        return value;
    };
    cache.put(gpa, k, .{ .json = j, .until = a_.nowMs() + cache_ms }) catch {
        gpa.free(k);
        gpa.free(j);
    };
    return value;
}

/// Fills in the governorate and city of an address from its pin (mutates and returns it).
pub fn resolveAddress(a: std.mem.Allocator, address: Val) !Val {
    if (address.path("location.coordinates").isNullish() or (address.t("governorate") and address.t("city"))) return address;
    const place = try reverseGeocode(a, address.get("location"));
    const c = geo.coords(address.get("location")).?;
    const from_maps: ?[]const u8 = if (place.t("state")) try geo.governorateCode(a, place.get("state"), true) else null;
    const by_distance = geo.nearestGovernorate(c[1], c[0]);
    if (!address.t("governorate")) try address.set("governorate", from_maps orelse by_distance.code);
    const g = geo.governorate(address.s("governorate") orelse "") orelse by_distance;
    if (!address.t("city")) try address.set("city", if (place.t("city")) place.get("city") else Val{ .str = g.en });
    if (!address.t("area")) try address.set("area", if (place.t("area")) place.get("area") else Val.null);
    if (!address.t("street")) try address.set("street", if (place.t("street")) place.get("street") else Val.null);
    return address;
}

// ---- Saved pickup places ------------------------------------------------------------------------

const max_places = 500;

/// The store's pickup places (the legacy default address counts as one until a place is saved).
pub fn placesOf(a: std.mem.Allocator, org: Val) ![]Val {
    const list = org.path("merchant.places");
    if (list == .arr and list.items().len > 0) return list.items();
    const legacy = org.path("merchant.defaultPickup");
    if (!legacy.truthy()) return &.{};
    const p = try val.spread(a, .{ .{ ._id = "default", .label = if (legacy.t("name")) legacy.get("name") else legacy.get("city") }, legacy, .{ .isDefault = true } });
    const out = try a.alloc(Val, 1);
    out[0] = p;
    return out;
}

pub fn defaultPlace(a: std.mem.Allocator, org: Val) !Val {
    const list = try placesOf(a, org);
    for (list) |p| if (p.t("isDefault")) return p;
    return if (list.len > 0) list[0] else .null;
}

/// A saved place by id (or "default").
pub fn placeById(a: std.mem.Allocator, org: Val, id: Val) !Val {
    const list = try placesOf(a, org);
    if (id == .str and std.mem.eql(u8, id.str, "default")) return defaultPlace(a, org);
    const want = try val.toStr(a, id);
    for (list) |p| if (std.mem.eql(u8, try val.toStr(a, p.get("_id")), want)) return p;
    return .null;
}

/// Public shape (lat/lng instead of GeoJSON).
pub fn placeView(a: std.mem.Allocator, p: Val) !Val {
    const c = p.path("location.coordinates");
    return val.from(a, .{
        .id = try val.toStr(a, p.get("_id")),
        .label = p.get("label"),
        .name = p.get("name"),
        .phone = p.get("phone"),
        .governorate = p.get("governorate"),
        .city = p.get("city"),
        .area = p.get("area"),
        .street = p.get("street"),
        .details = p.get("details"),
        .location = if (!c.isNullish()) try val.from(a, .{ .lat = c.at(1), .lng = c.at(0) }) else Val.null,
        .isDefault = p.t("isDefault"),
    });
}

pub const ParseAddressFn = *const fn (r: *Req, body: Val, field: []const u8, require_contact: bool) anyerror!Val;

/// Validates a place body: a label plus an address.
pub fn parsePlace(r: *Req, body: Val, parseAddress: ParseAddressFn) !Val {
    _ = try V.obj(r, body, "place", .{});
    const address = try parseAddress(r, body, "place", false);
    const label = try V.str(r, body.get("label"), "place.label", .{ .max = 80, .optional = true });
    const lab: Val = if (label) |l| (if (l.len > 0) Val{ .str = l } else .undef) else .undef;
    const final: Val = if (lab != .undef) lab else if (address.t("name")) address.get("name") else if (address.t("city")) address.get("city") else Val.null;
    return val.spread(r.a, .{ .{ .label = final }, address });
}

/// Stored places, after moving the legacy default address into the list.
fn storedPlaces(a: std.mem.Allocator, org: Val) ![]Val {
    const list = org.path("merchant.places");
    var out: std.ArrayList(Val) = .empty;
    if (list == .arr) try out.appendSlice(a, list.items());
    const legacy = org.path("merchant.defaultPickup");
    if (out.items.len > 0 or !legacy.truthy()) return out.items;
    try out.append(a, try val.spread(a, .{ .{ ._id = val.ObjectId.generate(a_.app.io), .label = if (legacy.t("name")) legacy.get("name") else legacy.get("city") }, legacy, .{ .isDefault = true, .createdAt = a_.now() } }));
    return out.items;
}

fn save(a: std.mem.Allocator, org: Val, places: []const Val) !void {
    _ = try db.col("orgs").updateOne(a, .{ ._id = org.get("_id") }, .{ .@"$set" = .{ .@"merchant.places" = places, .@"merchant.defaultPickup" = null, .updatedAt = a_.now() } }, .{});
}

fn sameIdStr(a: std.mem.Allocator, x: Val, y: Val) !bool {
    return std.mem.eql(u8, try val.toStr(a, x), try val.toStr(a, y));
}

pub fn addPlace(r: *Req, org: Val, place: Val) !Val {
    const a = r.a;
    const places = try storedPlaces(a, org);
    if (places.len >= max_places) return r.badRequest(try std.fmt.allocPrint(a, "At most {d} pickup places", .{max_places}), "place", "places_max", .{ .n = max_places });
    const doc = try val.spread(a, .{ .{ ._id = val.ObjectId.generate(a_.app.io) }, place });
    try doc.set("isDefault", if (place.t("isDefault")) place.get("isDefault") else Val{ .bool = places.len == 0 });
    try doc.set("createdAt", a_.now());
    if (doc.t("isDefault")) for (places) |p| try p.set("isDefault", false);
    _ = try resolveAddress(a, doc);
    var all: std.ArrayList(Val) = .empty;
    try all.appendSlice(a, places);
    try all.append(a, doc);
    try save(a, org, all.items);
    return doc;
}

pub fn updatePlace(r: *Req, org: Val, id: Val, place: Val) !Val {
    const a = r.a;
    const places = try storedPlaces(a, org);
    const i = for (places, 0..) |p, k| {
        if (try sameIdStr(a, p.get("_id"), id)) break k;
    } else return r.notFound("Place");
    const doc = try val.spread(a, .{ places[i], place, .{ ._id = places[i].get("_id"), .updatedAt = a_.now() } });
    const was_default = places[i].get("isDefault");
    if (place.t("isDefault")) for (places) |p| try p.set("isDefault", false);
    try doc.set("isDefault", if (place.t("isDefault")) place.get("isDefault") else was_default);
    _ = try resolveAddress(a, doc);
    places[i] = doc;
    try save(a, org, places);
    return doc;
}

pub fn setDefaultPlace(r: *Req, org: Val, id: Val) !void {
    const a = r.a;
    const places = try storedPlaces(a, org);
    const found = for (places) |p| {
        if (try sameIdStr(a, p.get("_id"), id)) break true;
    } else false;
    if (!found) return r.notFound("Place");
    for (places) |p| try p.set("isDefault", try sameIdStr(a, p.get("_id"), id));
    try save(a, org, places);
}

pub fn removePlace(r: *Req, org: Val, id: Val) !void {
    const a = r.a;
    const places = try storedPlaces(a, org);
    var rest: std.ArrayList(Val) = .empty;
    for (places) |p| if (!try sameIdStr(a, p.get("_id"), id)) try rest.append(a, p);
    if (rest.items.len == places.len) return r.notFound("Place");
    if (rest.items.len > 0) {
        const any = for (rest.items) |p| {
            if (p.t("isDefault")) break true;
        } else false;
        if (!any) try rest.items[0].set("isDefault", true);
    }
    try save(a, org, rest.items);
}
