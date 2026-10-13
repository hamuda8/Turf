//! Shipments (src/services/shipments.js): creation with immediate carrier allocation, the status
//! state machine, the event timeline, and the views for merchants, carriers and public tracking.

const std = @import("std");
const val = @import("mongo").val;
const db = @import("../lib/db.zig");
const web = @import("../web.zig");
const a_ = @import("../app.zig");
const geo = @import("../geo.zig");
const crypto = @import("../crypto.zig");
const messages = @import("../messages.zig");
const bus = @import("../bus.zig");
const allocation = @import("allocation.zig");
const relay = @import("relay.zig");
const pricing = @import("pricing.zig");
const platform = @import("platform.zig");
const places = @import("places.zig");
const moderation = @import("moderation.zig");
const Val = val.Val;
const Req = web.Req;
const V = web.V;
const Allocator = std.mem.Allocator;

pub const status_list = messages.status_list;
/// standard: the carrier's usual service level · express: same-hour, straight to the recipient.
pub const services = [_][]const u8{ "standard", "express" };
pub const open_task_statuses = [_][]const u8{ "pending", "assigned", "accepted", "in_progress" };

const Rule = struct { code: []const u8, to: ?[]const u8 = null, from: []const []const u8 };

const not_final = blk: {
    var out: []const []const u8 = &.{};
    for (messages.statuses) |s| {
        var final = false;
        for (messages.final_statuses) |f| {
            if (std.mem.eql(u8, f, s.code)) final = true;
        }
        if (!final) out = out ++ &[_][]const u8{s.code};
    }
    break :blk out;
};

const editable = [_][]const u8{ "awaiting_carrier", "awaiting_pickup", "picked_up", "at_hub", "in_transit", "delivery_failed" };

/// event code -> resulting status (null = unchanged) and the statuses it may be applied in.
const transitions = [_]Rule{
    .{ .code = "pickup_assigned", .from = &.{"awaiting_pickup"} },
    .{ .code = "picked_up", .to = "picked_up", .from = &.{"awaiting_pickup"} },
    .{ .code = "arrived_at_hub", .to = "at_hub", .from = &.{ "picked_up", "at_hub", "in_transit", "out_for_delivery", "delivery_failed", "returning" } },
    .{ .code = "departed_hub", .to = "in_transit", .from = &.{"at_hub"} },
    .{ .code = "out_for_delivery", .to = "out_for_delivery", .from = &.{ "picked_up", "at_hub", "delivery_failed" } },
    .{ .code = "delivered", .to = "delivered", .from = &.{"out_for_delivery"} },
    .{ .code = "delivery_failed", .to = "delivery_failed", .from = &.{"out_for_delivery"} },
    .{ .code = "return_started", .to = "returning", .from = &.{ "picked_up", "at_hub", "in_transit", "delivery_failed" } },
    .{ .code = "returned", .to = "returned", .from = &.{"returning"} },
    .{ .code = "cancelled", .to = "cancelled", .from = &.{ "awaiting_pickup", "awaiting_carrier" } },
    .{ .code = "lost", .to = "lost", .from = &.{ "picked_up", "at_hub", "in_transit", "out_for_delivery", "delivery_failed", "returning" } },
    .{ .code = "damage_reported", .from = &.{ "picked_up", "at_hub", "in_transit", "out_for_delivery", "delivery_failed", "returning", "delivered", "returned" } },
    .{ .code = "customer_return_requested", .from = &.{"delivered"} },
    .{ .code = "carrier_accepted", .to = "awaiting_pickup", .from = &.{"awaiting_carrier"} },
    .{ .code = "no_carrier_found", .to = "cancelled", .from = &.{"awaiting_carrier"} },
    .{ .code = "handed_over", .to = "at_hub", .from = &.{ "picked_up", "in_transit", "at_hub" } },
    .{ .code = "handed_back", .to = "returning", .from = &.{ "returning", "at_hub" } },
    .{ .code = "details_updated", .from = &editable },
    .{ .code = "rescheduled", .from = &editable },
    .{ .code = "recipient_location_set", .from = &.{ "awaiting_carrier", "awaiting_pickup", "picked_up", "at_hub", "in_transit", "out_for_delivery", "delivery_failed" } },
    .{ .code = "note", .from = not_final },
    .{ .code = "recipient_rated", .from = &.{"delivered"} },
    .{ .code = "recipient_problem", .from = &.{"delivered"} },
};

fn rule(code: []const u8) ?Rule {
    for (transitions) |t| if (std.mem.eql(u8, t.code, code)) return t;
    return null;
}

// ---- Input parsing -------------------------------------------------------------------------------

fn orNullStr(s: ?[]const u8) Val {
    return if (s) |x| (if (x.len > 0) Val{ .str = x } else .null) else .null;
}

/// An address is a map pin, or a governorate and city, or both. The phone is required only for
/// a recipient (require_contact); the name is always optional.
pub fn parseAddress(r: *Req, input: Val, field: []const u8, require_contact: bool) anyerror!Val {
    const a = r.a;
    _ = try V.obj(r, input, field, .{});
    const f = struct {
        fn f(al: Allocator, base: []const u8, k: []const u8) []const u8 {
            return std.fmt.allocPrint(al, "{s}.{s}", .{ base, k }) catch k;
        }
    }.f;
    const location = (try V.point(r, input.get("location"), f(a, field, "location"), .{ .optional = true })) orelse Val.null;
    var gov: Val = .null;
    if (input.get("governorate").truthy()) {
        const code = try geo.governorateCode(a, input.get("governorate"), false);
        gov = .{ .str = (try V.oneOf(r, if (code) |c| Val{ .str = c } else .undef, f(a, field, "governorate"), geo.codes, .{})).? };
    }
    const city = orNullStr(try V.str(r, input.get("city"), f(a, field, "city"), .{ .max = 80, .optional = true }));
    if (location == .null and !(gov != .null and city != .null))
        return r.badRequest("Pin the address on the map, or give its governorate and city", f(a, field, "location"), "address_required", null);
    return val.from(a, .{
        .name = orNullStr(try V.str(r, input.get("name"), f(a, field, "name"), .{ .max = 120, .optional = true })),
        .phone = orNullStr(try V.phone(r, input.get("phone"), f(a, field, "phone"), .{ .optional = !require_contact })),
        .governorate = gov,
        .city = city,
        .area = orNullStr(try V.str(r, input.get("area"), f(a, field, "area"), .{ .max = 120, .optional = true })),
        .street = orNullStr(try V.str(r, input.get("street"), f(a, field, "street"), .{ .max = 200, .optional = true })),
        .details = orNullStr(try V.str(r, input.get("details"), f(a, field, "details"), .{ .max = 500, .optional = true })),
        .location = location,
    });
}

fn parseAddressFn(r: *Req, body: Val, field: []const u8, require_contact: bool) anyerror!Val {
    return parseAddress(r, body, field, require_contact);
}
pub const parse_address_fn: places.ParseAddressFn = parseAddressFn;

/// Optional { length, width, height } in cm; all three or none.
pub fn parseDimensions(r: *Req, d: Val) !Val {
    if (d.isNullish() or (d == .str and d.str.len == 0)) return .null;
    _ = try V.obj(r, d, "parcel.dimensionsCm", .{});
    const keys = [_][]const u8{ "length", "width", "height" };
    const all_missing = for (keys) |k| {
        if (!d.get(k).isMissing()) break false;
    } else true;
    if (all_missing) return .null;
    return val.from(r.a, .{
        .length = (try V.num(r, d.get("length"), "parcel.dimensionsCm.length", .{ .min = 1, .max = 1000 })).?,
        .width = (try V.num(r, d.get("width"), "parcel.dimensionsCm.width", .{ .min = 1, .max = 1000 })).?,
        .height = (try V.num(r, d.get("height"), "parcel.dimensionsCm.height", .{ .min = 1, .max = 1000 })).?,
    });
}

fn isOptionId(s: []const u8) bool {
    // /^[0-9a-f]{24}(\.[0-9a-f]{24})?(-[0-9a-f]{24}(\.[0-9a-f]{24})?)*$/
    var it = std.mem.splitScalar(u8, s, '-');
    while (it.next()) |part| {
        var p = std.mem.splitScalar(u8, part, '.');
        var n: usize = 0;
        while (p.next()) |hex| {
            n += 1;
            if (n > 2 or hex.len != 24) return false;
            for (hex) |c| if (!(std.ascii.isDigit(c) or (c >= 'a' and c <= 'f'))) return false;
        }
    }
    return true;
}

/// `quote`: pricing only (POST /quotes), so the recipient's phone may still be unknown.
pub fn parseShipmentInput(r: *Req, body: Val, merchant: Val, quote_only: bool) !Val {
    const a = r.a;
    _ = try V.obj(r, body, "body", .{});
    // pickup: an address, the id of a saved pickup place, or nothing (the store's default place).
    var pickup: Val = undefined;
    const bp = body.get("pickup");
    if (bp == .obj or bp == .arr) {
        // A person sending a parcel must be reachable; a store's places carry their own contact.
        pickup = try parseAddress(r, bp, "pickup", merchant.t("personal"));
    } else {
        const place = if (!bp.isNullish()) try places.placeById(a, merchant, .{ .str = (try V.str(r, bp, "pickup", .{ .max = 40 })).? }) else try places.defaultPlace(a, merchant);
        if (!place.truthy()) {
            if (!bp.isNullish()) return r.badRequest("No saved pickup place with this id", "pickup", "place_not_found", null);
            return r.badRequest("pickup is required (or save a pickup place in your settings)", "pickup", "pickup_required", null);
        }
        const address = try place.copy(a);
        for ([_][]const u8{ "_id", "label", "isDefault", "createdAt", "updatedAt" }) |k| address.del(k);
        const pid = place.get("_id");
        try address.set("placeId", if (pid == .str and std.mem.eql(u8, pid.str, "default")) Val.null else pid);
        pickup = address;
    }
    const parcel = (try V.obj(r, body.get("parcel"), "parcel", .{})).?;
    const carrier = if (body.get("carrier").isNullish()) Val{ .str = "auto" } else body.get("carrier");
    if (!(carrier == .str and std.mem.eql(u8, carrier.str, "auto"))) _ = try V.id(r, carrier, "carrier", .{});
    const option = try V.str(r, body.get("option"), "option", .{ .max = 200, .optional = true });
    if (option) |o| if (o.len > 0 and !isOptionId(o)) return r.badRequest("option must be the id of a quoted route", "option", "option_invalid", null);

    const strategy = (try V.oneOf(r, body.get("strategy"), "strategy", &allocation.strategies, .{ .optional = true })) orelse
        (if (merchant.path("merchant.defaultStrategy").asStr()) |s| (if (s.len > 0) s else "balanced") else "balanced");
    const cod_in = if (body.path("cod.amount").isNullish()) body.get("codAmount") else body.path("cod.amount");
    const pieces = try V.num(r, parcel.get("pieces"), "parcel.pieces", .{ .min = 1, .max = 999, .integer = true, .optional = true });
    return val.from(a, .{
        .reference = orNullStr(try V.str(r, body.get("reference"), "reference", .{ .max = 100, .optional = true })),
        .carrier = carrier,
        .option = orNullStr(option),
        .strategy = strategy,
        .service = (try V.oneOf(r, body.get("service"), "service", &services, .{ .optional = true })) orelse "standard",
        .pickup = pickup,
        .dropoff = try parseAddress(r, body.get("dropoff"), "dropoff", !quote_only),
        .parcel = .{
            .weightKg = (try V.num(r, parcel.get("weightKg"), "parcel.weightKg", .{ .min = 0.01, .max = 20000 })).?,
            .description = orNullStr(try V.str(r, parcel.get("description"), "parcel.description", .{ .max = 300, .optional = true })),
            .pieces = if (pieces) |p| (if (p != 0) p else 1) else 1,
            .value = if (try V.num(r, parcel.get("value"), "parcel.value", .{ .min = 0, .max = 1e12, .optional = true })) |v| Val{ .num = v } else Val.null,
            .fragile = (try V.boolean(r, parcel.get("fragile"), "parcel.fragile", .{ .optional = true })) orelse false,
            .dimensionsCm = try parseDimensions(r, parcel.get("dimensionsCm")),
        },
        .codAmount = (try V.num(r, cod_in, "cod.amount", .{ .min = 0, .max = 1e12, .optional = true })) orelse 0,
        .notes = orNullStr(try V.str(r, body.get("notes"), "notes", .{ .max = 500, .optional = true })),
        .requireDeliveryCode = (try V.boolean(r, body.get("requireDeliveryCode"), "requireDeliveryCode", .{ .optional = true })) orelse true,
    });
}

/// Validates a shipment body and fills in what its map pins say (governorate, city).
pub fn prepareShipmentInput(r: *Req, body: Val, merchant: Val, quote_only: bool) !Val {
    const a = r.a;
    const input = try parseShipmentInput(r, body, merchant, quote_only);
    _ = try places.resolveAddress(a, input.get("pickup"));
    _ = try places.resolveAddress(a, input.get("dropoff"));
    // An express courier drives straight to the door, priced by distance: both ends need a pin.
    if (std.mem.eql(u8, input.s("service") orelse "", "express")) {
        if (!input.path("dropoff.location").truthy()) return r.badRequest("Express delivery needs the recipient pinned on the map", "dropoff.location", "express_needs_pin", null);
        if (!input.path("pickup.location").truthy()) return r.badRequest("Express delivery needs the pickup pinned on the map", if (input.path("pickup.placeId").truthy()) "pickup" else "pickup.location", "express_needs_pin", null);
    }
    // What couriers, carriers and the recipient will read; the store's owner answers for it.
    if (!quote_only) {
        const texts = try val.from(a, .{
            .reference = input.get("reference"),
            .notes = input.get("notes"),
            .@"parcel.description" = input.path("parcel.description"),
            .@"dropoff.name" = input.path("dropoff.name"),
            .@"dropoff.area" = input.path("dropoff.area"),
            .@"dropoff.street" = input.path("dropoff.street"),
            .@"dropoff.details" = input.path("dropoff.details"),
            .@"pickup.name" = input.path("pickup.name"),
            .@"pickup.area" = input.path("pickup.area"),
            .@"pickup.street" = input.path("pickup.street"),
            .@"pickup.details" = input.path("pickup.details"),
        });
        const outcome = try moderation.check(r, moderation.subjectOfOrg(a, merchant), .{ .type = "shipment", .field = "create" }, texts, &.{});
        try input.set("moderation", try moderation.stamp(a, outcome));
    }
    return input;
}

// ---- Creation ------------------------------------------------------------------------------------

pub fn allocationRequest(a: Allocator, input: Val, merchant: Val, mode: []const u8) !Val {
    return val.from(a, .{
        .pickup = input.get("pickup"),
        .dropoff = input.get("dropoff"),
        .weightKg = input.path("parcel.weightKg"),
        .codAmount = input.get("codAmount"),
        .parcel = input.get("parcel"),
        .merchantId = merchant.get("_id"),
        .mode = mode,
        .strategy = input.get("strategy"),
        .service = input.get("service"),
    });
}

fn isAuto(input: Val) bool {
    return input.get("carrier") == .str and std.mem.eql(u8, input.s("carrier").?, "auto");
}

/// Ranks every route without creating anything (POST /quotes): { options, excluded }.
pub fn quote(r: *Req, merchant: Val, input: Val) !Val {
    const a = r.a;
    if (!isAuto(input)) {
        const carrier = (try db.col("orgs").findOne(a, .{ ._id = (try V.id(r, input.get("carrier"), "carrier", .{})).?, .type = "carrier" }, .{})) orelse return r.notFound("Carrier");
        const m = try allocation.measureCarrier(r, carrier, try allocationRequest(a, input, merchant, "direct"));
        if (m.get("reason").truthy()) {
            const reason = try val.toStr(a, m.get("reason"));
            return r.failf(422, reason, "This carrier cannot take this shipment ({s})", .{reason}, .{});
        }
        return val.from(a, .{ .options = .{m}, .excluded = 0 });
    }
    return allocation.rankOptions(r, try allocationRequest(a, input, merchant, "auto"));
}

/// Creates a shipment and allocates it to a carrier at once. actor: { type, id, name }.
/// Returns { shipment, created } (created=false when `reference` was already used).
pub fn createShipment(r: *Req, merchant: Val, input: Val, actor: Val) !Val {
    const a = r.a;
    if (std.mem.eql(u8, merchant.s("status") orelse "", "pending")) return r.fail(403, "org_pending", "This store account is waiting for approval by Turf", .{});
    if (input.t("reference")) {
        if (try db.col("shipments").findOne(a, .{ .merchantId = merchant.get("_id"), .externalRef = input.get("reference") }, .{})) |existing|
            return val.from(a, .{ .shipment = existing, .created = false });
    }

    var chosen: Val = undefined;
    var alternatives: usize = 0;
    if (isAuto(input)) {
        const ranked = try allocation.rankOptions(r, try allocationRequest(a, input, merchant, "auto"));
        const options = ranked.get("options").items();
        if (options.len == 0) {
            if (std.mem.eql(u8, input.s("service") orelse "", "express")) return r.fail(422, "no_express_available", "No carrier can deliver this order express right now", .{});
            return r.fail(422, "no_carrier_available", "No carrier currently serves this route with these requirements", .{});
        }
        if (input.t("option")) {
            chosen = for (options) |o| {
                if (o.get("id").eql(input.get("option"))) break o;
            } else return r.fail(422, "option_unavailable", "The chosen route is no longer available; ask for a new quote", .{});
        } else chosen = options[0];
        alternatives = options.len - 1;
    } else {
        const carrier = (try db.col("orgs").findOne(a, .{ ._id = (try V.id(r, input.get("carrier"), "carrier", .{})).?, .type = "carrier" }, .{})) orelse return r.notFound("Carrier");
        const m = try allocation.measureCarrier(r, carrier, try allocationRequest(a, input, merchant, "direct"));
        if (m.get("reason").truthy()) {
            const reason = try val.toStr(a, m.get("reason"));
            return r.failf(422, reason, "This carrier cannot take this shipment ({s})", .{reason}, .{});
        }
        chosen = m;
    }

    const carrier = chosen.get("carrier");
    const now_ms = a_.nowMs();
    const now: Val = .{ .date = now_ms };
    const q = chosen.get("quote");
    const zone = q.get("zone");
    const is_chain = chosen.t("chain");
    const carrier_ids = try val.newArr(a);
    if (is_chain) {
        for (chosen.get("carriers").items()) |c| try carrier_ids.push(c.get("_id"));
    } else try carrier_ids.push(carrier.get("_id"));
    const promise_h = if (is_chain) val.toNum(chosen.path("metrics.etaHours")) else pricing.promiseHours(carrier, zone.asStr() orelse "", input.s("service"));
    const promised: i64 = now_ms + @as(i64, @intFromFloat(promise_h * 3600_000));

    const shipment = try val.from(a, .{
        .trackingNumber = try crypto.newTrackingNumber(a),
        .publicToken = try crypto.randomToken(a, 18),
        .labelToken = try crypto.randomToken(a, 18),
        .merchantId = merchant.get("_id"),
        .merchantName = merchant.get("name"),
        .carrierId = carrier.get("_id"),
        .carrierName = carrier.get("name"),
        .carrierIds = carrier_ids,
    });
    if (is_chain) {
        try shipment.set("legs", try relay.legsForShipment(a, chosen));
        try shipment.set("legIndex", 0);
    }
    if (input.t("reference")) try shipment.set("externalRef", input.get("reference"));
    const mode: []const u8 = if (!isAuto(input)) "direct" else if (input.t("option")) "chosen" else "auto";
    const cod_amount = input.n("codAmount") orelse 0;
    const rest = try val.from(a, .{
        .createdBy = actor,
        .status = "awaiting_pickup",
        .statusAt = now,
        .zone = zone,
        .service = input.get("service"),
        .allocation = .{
            .mode = mode,
            .strategy = if (isAuto(input)) input.get("strategy") else Val.null,
            .score = if (chosen.get("score").isNullish()) Val.null else chosen.get("score"),
            .metrics = chosen.get("metrics"),
            .alternatives = alternatives,
            .decidedAt = now,
        },
        .pickup = input.get("pickup"),
        .dropoff = input.get("dropoff"),
        .parcel = input.get("parcel"),
        .cod = if (cod_amount > 0) try val.from(a, .{ .amount = cod_amount, .currency = q.get("currency"), .collectedAt = null, .collectedBy = null, .settledAt = null, .remittedAt = null }) else Val.null,
        .price = .{ .amount = q.get("amount"), .currency = q.get("currency"), .breakdown = q.get("breakdown") },
        .roadKm = q.get("roadKm"),
        .promisedBy = val.Date{ .ms = promised },
        .requireCode = input.get("requireDeliveryCode"),
        .deliveryCode = try crypto.newDeliveryCode(a),
        .custody = .{ .type = "merchant" },
        .currentTaskId = null,
        .attempts = 0,
        .notes = input.get("notes"),
        .moderation = if (input.t("moderation")) input.get("moderation") else Val.null,
        .pod = null,
        .createdAt = now,
        .updatedAt = now,
    });
    for (rest.obj.keys.items, rest.obj.vals.items) |k, v| try shipment.obj.put(k, v);

    _ = db.col("shipments").insertOne(a, shipment) catch |e| {
        // Two concurrent requests with the same reference: return the winner.
        if (e == error.DuplicateKey and input.t("reference")) {
            if (try db.col("shipments").findOne(a, .{ .merchantId = merchant.get("_id"), .externalRef = input.get("reference") }, .{})) |existing|
                return val.from(a, .{ .shipment = existing, .created = false });
        }
        return e;
    };

    var carrier_label: Val = carrier.get("name");
    if (is_chain) {
        var names: std.ArrayList([]const u8) = .empty;
        for (chosen.get("carriers").items()) |c| try names.append(a, try val.toStr(a, c.get("name")));
        carrier_label = .{ .str = try std.mem.join(a, " → ", names.items) };
    }
    _ = try db.col("shipment_events").insertMany(a, &.{
        try eventDoc(a, shipment, "created", .{ .actor = actor, .params = try val.from(a, .{ .merchant = merchant.get("name") }), .at = now_ms }),
        try eventDoc(a, shipment, "carrier_assigned", .{ .actor = try val.from(a, .{ .type = "system" }), .params = try val.from(a, .{ .carrier = carrier_label }), .at = now_ms }),
    });
    bus.emit(r, "shipment.created", .{ .shipment = shipment, .carrier = carrier, .merchant = merchant });
    return val.from(a, .{ .shipment = shipment, .created = true });
}

// ---- Events & state machine ----------------------------------------------------------------------

pub const EventOpts = struct {
    actor: Val = .undef,
    params: Val = .undef,
    hub: Val = .undef,
    location: Val = .undef,
    status: ?[]const u8 = null,
    at: ?i64 = null,
    note: Val = .undef,
    internal: bool = false,
    set: Val = .undef,
    unset: Val = .undef,
    inc: Val = .undef,
};

pub fn eventDoc(a: Allocator, shipment: Val, code: []const u8, o: EventOpts) !Val {
    const hub = o.hub;
    return val.from(a, .{
        .shipmentId = shipment.get("_id"),
        .carrierId = shipment.get("carrierId"),
        .merchantId = shipment.get("merchantId"),
        .code = code,
        .status = if (o.status) |s| Val{ .str = s } else shipment.get("status"),
        .at = val.Date{ .ms = o.at orelse a_.nowMs() },
        .actor = if (o.actor.truthy()) o.actor else try val.from(a, .{ .type = "system" }),
        .params = if (o.params == .undef) try val.newObj(a) else o.params,
        .hubId = if (hub.get("_id").truthy()) hub.get("_id") else Val.null,
        .location = if (o.location.truthy()) o.location else if (hub.get("location").truthy()) hub.get("location") else Val.null,
        .note = if (o.note.truthy()) o.note else Val.null,
        .internal = o.internal,
    });
}

/// Whether `code` may be applied to a shipment in `status` (check before side effects).
pub fn canApply(code: []const u8, status: []const u8) bool {
    const t = rule(code) orelse return false;
    return val.contains([]const u8, t.from, status);
}

/// Records an event and applies its status transition atomically.
pub fn applyEvent(r: *Req, shipment: Val, code: []const u8, o: EventOpts) !Val {
    const a = r.a;
    const t = rule(code) orelse return error.UnknownEventCode;
    const status = shipment.s("status") orelse "";
    if (!val.contains([]const u8, t.from, status))
        return r.conflict(try std.fmt.allocPrint(a, "Cannot apply \"{s}\" while the shipment is \"{s}\"", .{ code, status }), "wrong_status", .{ .status = status });

    const now_ms = a_.nowMs();
    const now: Val = .{ .date = now_ms };
    const set = try val.spread(a, .{o.set});
    try set.set("updatedAt", now);
    if (t.to) |to| {
        try set.set("status", to);
        try set.set("statusAt", now);
        if (std.mem.eql(u8, to, "delivered")) {
            try set.set("deliveredAt", now);
            // Practice shipments pay no Turf fees. Fees are fixed at delivery, so later rule
            // changes don't rewrite history.
            if (!shipment.t("test")) {
                const ids = try val.newArr(a);
                const carrier_ids = if (shipment.get("carrierIds").truthy()) shipment.get("carrierIds") else try val.arrOf(a, &.{shipment.get("carrierId")});
                for (carrier_ids.items()) |id| try ids.push(id);
                try ids.push(shipment.get("merchantId"));
                const orgs = try db.col("orgs").find(a, .{ ._id = .{ .@"$in" = ids } }, .{});
                var carriers: std.ArrayList(Val) = .empty;
                for (carrier_ids.items()) |id| for (orgs) |org| if (org.get("_id").sameId(id)) {
                    try carriers.append(a, org);
                    break;
                };
                var merchant: Val = .undef;
                for (orgs) |org| if (org.get("_id").sameId(shipment.get("merchantId"))) {
                    merchant = org;
                    break;
                };
                try set.set("platformFees", try platform.feesFor(a, "delivered", shipment, carriers.items, .undef, merchant));
            }
        }
    }
    const update = try val.from(a, .{ .@"$set" = set });
    if (o.unset != .undef) try update.set("$unset", o.unset);
    if (o.inc != .undef) try update.set("$inc", o.inc);

    const updated = (try db.col("shipments").findOneAndUpdate(a, .{ ._id = shipment.get("_id"), .status = status }, update, .{ .returnDocument = .after })) orelse
        return r.conflict("The shipment changed at the same time. Please refresh and try again.", "changed_meanwhile", null);

    const params = try val.spread(a, .{o.params});
    if (o.hub.truthy()) {
        try params.set("hub", o.hub.get("name"));
        try params.set("city", o.hub.get("city"));
    }
    var eo = o;
    eo.params = params;
    eo.at = now_ms;
    const event = try eventDoc(a, updated, code, eo);
    _ = try db.col("shipment_events").insertOne(a, event);
    bus.emit(r, "shipment.event", .{ .shipment = updated, .event = event, .previousStatus = status });
    return updated;
}

// ---- Queries -------------------------------------------------------------------------------------

fn isHex24(s: []const u8) bool {
    if (s.len != 24) return false;
    for (s) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

/// test: true = practice shipments only, false = real ones only, null = both.
pub fn getShipmentForMerchant(r: *Req, merchant_id: Val, id_or_tracking: []const u8, test_only: ?bool) !Val {
    const a = r.a;
    const q = if (isHex24(id_or_tracking))
        try val.from(a, .{ ._id = (try V.id(r, .{ .str = id_or_tracking }, "id", .{})).?, .merchantId = merchant_id })
    else
        try val.from(a, .{ .trackingNumber = try val.upper(a, id_or_tracking), .merchantId = merchant_id });
    if (test_only) |t| {
        if (t) try q.set("test", true) else try q.set("test", .{ .@"$ne" = true });
    }
    return (try db.col("shipments").findOne(a, q, .{})) orelse r.notFound("Shipment");
}

/// A shipment the carrier currently handles. For relays: `past` also finds shipments it already
/// handed over; `incoming` also those another company is bringing to it.
pub fn getShipmentForCarrier(r: *Req, carrier_id: Val, id_or_tracking: []const u8, past: bool, incoming: bool) !Val {
    const a = r.a;
    const key = if (isHex24(id_or_tracking)) try val.from(a, .{ ._id = (try V.id(r, .{ .str = id_or_tracking }, "id", .{})).? }) else blk: {
        var t: std.ArrayList(u8) = .empty;
        for (id_or_tracking) |c| {
            const u = std.ascii.toUpper(c);
            if (std.ascii.isDigit(u) or (u >= 'A' and u <= 'Z')) try t.append(a, u);
        }
        break :blk try val.from(a, .{ .trackingNumber = t.items });
    };
    var s = try db.col("shipments").findOne(a, try val.spread(a, .{ key, .{ .carrierId = carrier_id } }), .{});
    if (s == null and (past or incoming)) s = try db.col("shipments").findOne(a, try val.spread(a, .{ key, .{ .carrierIds = carrier_id } }), .{});
    const sh = s orelse return r.notFound("Shipment");
    if (!sh.get("carrierId").sameId(carrier_id)) {
        var idx: ?usize = null;
        for (sh.get("legs").items(), 0..) |l, i| if (l.get("carrierId").sameId(carrier_id)) {
            idx = i;
            break;
        };
        const li: f64 = sh.n("legIndex") orelse 0;
        const allowed = if (idx) |i| (past and @as(f64, @floatFromInt(i)) < li) or (incoming and @as(f64, @floatFromInt(i)) == li + 1) else false;
        if (!allowed) return r.notFound("Shipment");
    }
    return sh;
}

pub const ListOpts = struct { limit: i64 = 50, before: ?i64 = null, status: Val = .undef, q: ?[]const u8 = null };

/// /[.*+?^${}()|[\]\\]/g escaped with a backslash.
fn regexEscape(a: Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| {
        if (std.mem.indexOfScalar(u8, ".*+?^${}()|[]\\", c) != null) try out.append(a, '\\');
        try out.append(a, c);
    }
    return out.items;
}

pub fn listShipments(a: Allocator, filter: Val, o: ListOpts) ![]Val {
    const query = try val.spread(a, .{filter});
    if (o.status.truthy()) try query.set("status", if (o.status == .arr) try val.from(a, .{ .@"$in" = o.status }) else o.status);
    if (o.before) |b| try query.set("createdAt", .{ .@"$lt" = val.Date{ .ms = b } });
    if (o.q) |raw| if (raw.len > 0) {
        const term = val.jsSlice(val.jsTrim(raw), 60);
        const escaped = try regexEscape(a, term);
        const norm = try normalizeTrackingNumber(a, term);
        const search = try val.from(a, .{
            .{ .trackingNumber = norm orelse try val.upper(a, term) },
            .{ .externalRef = term },
            .{ .@"dropoff.phone" = .{ .@"$regex" = escaped } },
            .{ .@"dropoff.name" = .{ .@"$regex" = escaped, .@"$options" = "i" } },
        });
        // Keep any condition the caller already put in $or.
        if (query.get("$or") != .undef) {
            const and_list = try val.newArr(a);
            for (query.get("$and").items()) |x| try and_list.push(x);
            try and_list.push(.{ .@"$or" = query.get("$or") });
            try and_list.push(.{ .@"$or" = search });
            try query.set("$and", and_list);
            query.del("$or");
        } else try query.set("$or", search);
    };
    return db.col("shipments").find(a, query, .{ .sort = try val.from(a, .{ .createdAt = -1 }), .limit = o.limit });
}

pub fn eventsFor(a: Allocator, shipment_id: Val, include_internal: bool) ![]Val {
    const q = try val.from(a, .{ .shipmentId = shipment_id });
    if (!include_internal) try q.set("internal", .{ .@"$ne" = true });
    return db.col("shipment_events").find(a, q, .{ .sort = try val.from(a, .{ .at = 1, ._id = 1 }), .limit = 1000 });
}

pub const Live = struct { task: Val, courier: Val };

/// Live courier info for a shipment, only while a task carrying it is in progress.
pub fn liveCourierFor(a: Allocator, shipment: Val) !?Live {
    if (!shipment.t("currentTaskId")) return null;
    const task = (try db.col("tasks").findOne(a, .{ ._id = shipment.get("currentTaskId"), .status = "in_progress" }, .{})) orelse return null;
    if (!task.t("courierId")) return null;
    const courier = (try db.col("memberships").findOne(a, .{ ._id = task.get("courierId") }, .{})) orelse return null;
    return .{ .task = task, .courier = courier };
}

// ---- Views ---------------------------------------------------------------------------------------

pub fn addressView(a: Allocator, addr: Val, full: bool) !Val {
    if (!addr.truthy()) return .null;
    const g = geo.governorate(addr.s("governorate") orelse "");
    const base = try val.from(a, .{
        .governorate = addr.get("governorate"),
        .governorateName = if (g) |x| try val.from(a, .{ .en = x.en, .ar = x.ar }) else Val.null,
        .city = addr.get("city"),
        .area = addr.get("area"),
    });
    if (!full) return base;
    return val.spread(a, .{ base, .{ .name = addr.get("name"), .phone = addr.get("phone"), .street = addr.get("street"), .details = addr.get("details"), .location = try web.toLatLng(a, addr.get("location")) } });
}

fn firstName(name: Val) Val {
    const s = val.jsTrim(name.asStr() orelse "");
    var it = std.mem.tokenizeAny(u8, s, " \t\r\n");
    const first = it.next() orelse return .null;
    return .{ .str = first };
}

pub fn courierLiveView(a: Allocator, courier: Val, task: Val, shipment: Val) !Val {
    const vehicle = courier.path("courier.vehicle");
    const view = try val.from(a, .{
        .name = firstName(courier.get("name")),
        .vehicle = if (vehicle.truthy()) vehicle else Val.null,
        .taskType = task.get("type"),
        .location = try web.toLatLng(a, courier.get("lastLocation")),
        .heading = if (courier.get("lastHeading").isNullish()) Val.null else courier.get("lastHeading"),
        .speedKmh = if (courier.get("lastSpeedKmh").isNullish()) Val.null else courier.get("lastSpeedKmh"),
        .updatedAt = if (courier.get("lastLocationAt").truthy()) courier.get("lastLocationAt") else Val.null,
        .etaMinutes = null,
    });
    const tt = task.s("type") orelse "";
    const target = if (std.mem.eql(u8, tt, "delivery") or std.mem.eql(u8, tt, "direct")) try geo.approxPoint(a, shipment.get("dropoff")) else task.path("to.location");
    if (courier.get("lastLocation").truthy() and target.truthy() and vehicle.truthy()) {
        if (geo.vehicle(vehicle.asStr() orelse "")) |vp| {
            const km = geo.roadKm(geo.distanceKmV(courier.get("lastLocation"), target));
            try view.set("etaMinutes", val.jsMax(1, val.jsRound((km / vp.speedKmh) * 60) + 2));
        }
    }
    return view;
}

pub fn courierLiveViewOpt(a: Allocator, live: ?Live, shipment: Val) !Val {
    const l = live orelse return .null;
    return courierLiveView(a, l.courier, l.task, shipment);
}

fn eventView(a: Allocator, e: Val, lang: []const u8) !Val {
    return val.from(a, .{
        .code = e.get("code"),
        .status = e.get("status"),
        .text = try messages.eventText(a, e, lang),
        .textAr = try messages.eventText(a, e, "ar"),
        .textEn = try messages.eventText(a, e, "en"),
        .at = e.get("at"),
        .location = try web.toLatLng(a, e.get("location")),
    });
}

fn orNull(v: Val) Val {
    return if (v.truthy()) v else .null;
}

/// Tracking information shared with merchants and the public tracking page.
pub fn trackingView(a: Allocator, shipment: Val, events: []const Val, live: ?Live, lang: []const u8, audience: []const u8) !Val {
    const full = !std.mem.eql(u8, audience, "public");
    const is_merchant = std.mem.eql(u8, audience, "merchant");
    const status = shipment.s("status") orelse "";
    const evs = try val.newArr(a);
    for (events) |e| try evs.push(try eventView(a, e, lang));
    const cod = shipment.get("cod");
    return val.from(a, .{
        .trackingNumber = shipment.get("trackingNumber"),
        .reference = if (is_merchant) orNull(shipment.get("externalRef")) else Val.undef,
        .status = shipment.get("status"),
        .statusText = messages.statusText(status, lang),
        .statusTextAr = messages.statusText(status, "ar"),
        .statusTextEn = messages.statusText(status, "en"),
        .service = if (shipment.t("service")) shipment.get("service") else Val{ .str = "standard" },
        .updatedAt = shipment.get("statusAt"),
        .promisedBy = shipment.get("promisedBy"),
        .scheduledFor = orNull(shipment.get("scheduledFor")),
        .deliveredAt = orNull(shipment.get("deliveredAt")),
        .carrier = .{ .id = shipment.get("carrierId"), .name = shipment.get("carrierName") },
        .merchant = .{ .name = shipment.get("merchantName") },
        .pickup = try addressView(a, shipment.get("pickup"), is_merchant),
        .dropoff = try addressView(a, shipment.get("dropoff"), full),
        // The recipient gives this code to the courier at handover; never shown to the courier.
        .deliveryCode = if (shipment.t("requireCode") and !messages.isFinal(status)) shipment.get("deliveryCode") else Val.null,
        .cod = if (cod.truthy()) try val.from(a, .{ .amount = cod.get("amount"), .currency = cod.get("currency") }) else Val.null,
        .attempts = shipment.get("attempts"),
        .courier = try courierLiveViewOpt(a, live, shipment),
        .events = evs,
        .trackingUrl = null,
    });
}

/// Milestones anyone holding the tracking number may see.
const lookup_events = [_][]const u8{
    "created",          "carrier_assigned", "pickup_assigned", "picked_up",   "arrived_at_hub", "departed_hub", "out_for_delivery",
    "delivered",        "delivery_failed",  "return_started",  "returned",    "cancelled",      "request_sent", "carrier_accepted",
    "no_carrier_found", "rescheduled",      "lost",            "handed_over", "handed_back",
};

pub fn lookupView(a: Allocator, shipment: Val, events: []const Val) !Val {
    const place = struct {
        fn f(al: Allocator, addr: Val) !Val {
            if (!addr.truthy()) return .null;
            const g = geo.governorate(addr.s("governorate") orelse "");
            return val.from(al, .{ .governorate = addr.get("governorate"), .governorateName = if (g) |x| try val.from(al, .{ .en = x.en, .ar = x.ar }) else Val.null, .city = orNull(addr.get("city")) });
        }
    }.f;
    const text = struct {
        fn f(al: Allocator, e: Val, lang: []const u8) ![]const u8 {
            if (std.mem.eql(u8, e.s("code") orelse "", "out_for_delivery")) return messages.statusText("out_for_delivery", lang);
            return messages.eventText(al, e, lang);
        }
    }.f;
    const status = shipment.s("status") orelse "";
    const evs = try val.newArr(a);
    for (events) |e| if (val.contains([]const u8, &lookup_events, e.s("code") orelse "")) {
        try evs.push(.{ .code = e.get("code"), .status = e.get("status"), .textAr = try text(a, e, "ar"), .textEn = try text(a, e, "en"), .at = e.get("at") });
    };
    return val.from(a, .{
        .trackingNumber = shipment.get("trackingNumber"),
        .status = shipment.get("status"),
        .statusTextAr = messages.statusText(status, "ar"),
        .statusTextEn = messages.statusText(status, "en"),
        .service = if (shipment.t("service")) shipment.get("service") else Val{ .str = "standard" },
        .updatedAt = shipment.get("statusAt"),
        .promisedBy = if (messages.isFinal(status)) Val.null else orNull(shipment.get("promisedBy")),
        .scheduledFor = orNull(shipment.get("scheduledFor")),
        .deliveredAt = orNull(shipment.get("deliveredAt")),
        .carrier = .{ .name = shipment.get("carrierName") },
        .merchant = .{ .name = shipment.get("merchantName") },
        .from = try place(a, shipment.get("pickup")),
        .to = try place(a, shipment.get("dropoff")),
        .events = evs,
    });
}

/// A typed tracking number in its stored form, or null. Spaces, dashes and lower case are
/// fine, the TRF prefix may be left out, and O / I / L are read as 0 / 1 / 1.
pub fn normalizeTrackingNumber(a: Allocator, raw: []const u8) !?[]const u8 {
    var s: std.ArrayList(u8) = .empty;
    for (raw) |c| {
        const u = std.ascii.toUpper(c);
        if (std.ascii.isDigit(u) or (u >= 'A' and u <= 'Z')) try s.append(a, u);
    }
    var t = s.items;
    if (std.mem.startsWith(u8, t, "TRF")) t = t[3..];
    for (t) |*c| switch (c.*) {
        'O' => c.* = '0',
        'I', 'L' => c.* = '1',
        else => {},
    };
    if (t.len != 10) return null;
    for (t) |c| switch (c) {
        '0'...'9', 'A'...'H', 'J', 'K', 'M', 'N', 'P'...'T', 'V'...'Z' => {},
        else => return null,
    };
    return try std.fmt.allocPrint(a, "TRF{s}", .{t});
}

/// The tracking numbers in typed or pasted text. Commas, semicolons and new lines separate
/// numbers; spaces do too, unless they are inside one number ("TRF 7K2M9 Q4XA8").
pub fn splitTrackingNumbers(a: Allocator, text: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    // Split on [\n,،;]+
    var chunks: std.ArrayList([]const u8) = .empty;
    var start: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const sep_len: usize = if (text[i] == '\n' or text[i] == ',' or text[i] == ';') 1 else if (std.mem.startsWith(u8, text[i..], "،")) "،".len else 0;
        if (sep_len > 0) {
            try chunks.append(a, text[start..i]);
            i += sep_len;
            start = i;
        } else i += 1;
    }
    try chunks.append(a, text[start..]);
    for (chunks.items) |chunk| {
        var words: std.ArrayList([]const u8) = .empty;
        var it = std.mem.tokenizeAny(u8, val.jsTrim(chunk), " \t\r\x0b\x0c");
        while (it.next()) |w| try words.append(a, w);
        const long = struct {
            fn f(w: []const u8) bool {
                var n: usize = 0;
                for (w) |c| if (std.ascii.isAlphanumeric(c)) {
                    n += 1;
                };
                return n >= 10;
            }
        }.f;
        const all_long = for (words.items) |w| {
            if (!long(w)) break false;
        } else true;
        if (words.items.len > 1 and all_long) {
            try out.appendSlice(a, words.items);
        } else {
            const joined = try std.mem.concat(a, u8, words.items);
            if (joined.len > 0) try out.append(a, joined);
        }
    }
    return out.items;
}

/// The full shipment as the merchant API shows it.
pub fn merchantView(a: Allocator, s: Val) !Val {
    const is_test = s.t("test");
    var route: Val = .null;
    if (relay.isRelay(s)) {
        route = try val.newArr(a);
        for (s.get("legs").items()) |l| {
            const to = l.get("to");
            try route.push(.{
                .carrier = .{ .id = l.get("carrierId"), .name = l.get("carrierName") },
                .from = l.path("from.governorate"),
                .to = if (to.truthy()) to.get("governorate") else Val.null,
                .handoverHub = if (to.truthy()) try val.from(a, .{ .name = to.get("hubName"), .city = to.get("city") }) else Val.null,
                .price = l.get("price"),
                .status = l.get("status"),
            });
        }
    }
    const pod = s.get("pod");
    const fb = s.get("feedback");
    const alloc = s.get("allocation");
    return val.from(a, .{
        .id = s.get("_id"),
        .trackingNumber = s.get("trackingNumber"),
        .reference = if (s.t("externalRef")) s.get("externalRef") else orNull(s.get("testRef")),
        .@"test" = if (is_test) Val{ .bool = true } else Val.undef,
        .kind = if (s.t("kind")) s.get("kind") else Val{ .str = "delivery" },
        .service = if (s.t("service")) s.get("service") else Val{ .str = "standard" },
        .returnOf = orNull(s.get("returnOf")),
        .returnShipmentId = orNull(s.get("returnShipmentId")),
        .damaged = s.t("damaged"),
        .status = s.get("status"),
        .statusText = messages.statusText(s.s("status") orelse "", "en"),
        .statusTextAr = messages.statusText(s.s("status") orelse "", "ar"),
        .carrier = .{ .id = if (is_test) Val{ .str = "test" } else s.get("carrierId"), .name = s.get("carrierName") },
        .route = route,
        .allocation = .{ .mode = alloc.get("mode"), .strategy = alloc.get("strategy"), .alternatives = alloc.get("alternatives"), .metrics = alloc.get("metrics") },
        .pickup = try addressView(a, s.get("pickup"), true),
        .dropoff = try addressView(a, s.get("dropoff"), true),
        .parcel = s.get("parcel"),
        .cod = s.get("cod"),
        .price = s.get("price"),
        .promisedBy = s.get("promisedBy"),
        .scheduledFor = orNull(s.get("scheduledFor")),
        .deliveredAt = orNull(s.get("deliveredAt")),
        .deliveryCode = if (s.t("requireCode")) s.get("deliveryCode") else Val.null,
        .attempts = s.get("attempts"),
        .notes = s.get("notes"),
        .pod = if (pod.truthy()) try val.from(a, .{ .receiverName = pod.get("receiverName"), .at = pod.get("at"), .method = pod.get("method"), .hasPhoto = pod.get("photoId").truthy() }) else Val.null,
        .feedback = if (fb.truthy()) try val.from(a, .{ .rating = fb.get("rating"), .problem = fb.get("problem"), .comment = fb.get("comment"), .at = fb.get("at") }) else Val.null,
        .createdAt = s.get("createdAt"),
        .updatedAt = s.get("updatedAt"),
    });
}

/// The shipment as carrier staff see it (no delivery code: staff must not be able to fake a
/// handover). On a relay each carrier sees the route, but only its own price.
pub fn carrierView(a: Allocator, s: Val, viewer_id: Val) !Val {
    const rest = try s.copy(a);
    rest.del("deliveryCode");
    rest.del("publicToken");
    rest.del("labelToken");
    if (relay.isRelay(s)) {
        const viewer = if (viewer_id == .id) viewer_id else s.get("carrierId");
        const legs = try val.newArr(a);
        for (s.get("legs").items()) |l| {
            const copy = try l.copy(a);
            if (!l.get("carrierId").sameId(viewer)) try copy.set("price", Val.undef);
            try legs.push(copy);
        }
        try rest.set("legs", legs);
        try rest.set("price", .{ .amount = try relay.carrierPrice(s, viewer), .currency = s.path("price.currency"), .breakdown = null });
        try rest.set("isCurrentCarrier", s.get("carrierId").sameId(viewer));
    }
    const label = s.get("labelToken");
    return val.spread(a, .{ rest, .{
        .service = if (s.t("service")) s.get("service") else Val{ .str = "standard" },
        .labelPath = if (label.truthy()) Val{ .str = try std.fmt.allocPrint(a, "/label/{s}", .{try val.toStr(a, label)}) } else Val.null,
        .statusText = messages.statusText(s.s("status") orelse "", "en"),
        .statusTextAr = messages.statusText(s.s("status") orelse "", "ar"),
        .pickup = try addressView(a, s.get("pickup"), true),
        .dropoff = try addressView(a, s.get("dropoff"), true),
    } });
}

// ---- Merchant / recipient actions ----------------------------------------------------------------

pub fn cancelShipment(r: *Req, shipment: Val, actor: Val, reason: ?[]const u8) !Val {
    const a = r.a;
    if (!std.mem.eql(u8, shipment.s("status") orelse "", "awaiting_pickup"))
        return r.conflict("Only shipments that have not been picked up yet can be cancelled", "cancel_too_late", null);
    const open_task = try db.col("tasks").findOne(a, .{ .shipmentIds = shipment.get("_id"), .status = .{ .@"$in" = &open_task_statuses } }, .{});
    if (open_task) |t| if (std.mem.eql(u8, t.s("status") orelse "", "in_progress"))
        return r.conflict("A courier is already collecting this shipment", "being_collected", null);
    const updated = try applyEvent(r, shipment, "cancelled", .{
        .actor = actor,
        .note = if (reason) |x| (if (x.len > 0) Val{ .str = x } else .null) else .null,
        .set = try val.from(a, .{ .currentTaskId = null, .custody = .{ .type = "merchant" } }),
    });
    if (open_task) |t| {
        // Pull it from the courier's pickup run; cancel the run if nothing remains.
        const remaining = try val.newArr(a);
        for (t.get("shipmentIds").items()) |id| if (!id.sameId(shipment.get("_id"))) try remaining.push(id);
        if (remaining.items().len > 0) {
            _ = try db.col("tasks").updateOne(a, .{ ._id = t.get("_id") }, .{ .@"$set" = .{ .shipmentIds = remaining, .updatedAt = a_.now() } }, .{});
        } else {
            _ = try db.col("tasks").updateOne(a, .{ ._id = t.get("_id") }, .{ .@"$set" = .{ .status = "cancelled", .cancelledAt = a_.now(), .updatedAt = a_.now() } }, .{});
        }
        bus.emit(r, "task.changed", .{ .taskId = t.get("_id"), .carrierId = t.get("carrierId"), .courierId = t.get("courierId") });
    }
    return updated;
}

/// The recipient pins the exact drop-off point from the tracking page.
pub fn setRecipientLocation(r: *Req, shipment: Val, point: Val) !Val {
    const st = shipment.s("status") orelse "";
    if (val.contains([]const u8, &.{ "delivered", "returning", "returned", "cancelled" }, st))
        return r.conflict("This shipment can no longer be changed", "cannot_change", null);
    return applyEvent(r, shipment, "recipient_location_set", .{
        .actor = try val.from(r.a, .{ .type = "recipient" }),
        .set = try val.from(r.a, .{ .@"dropoff.location" = point, .@"dropoff.locationSource" = "recipient" }),
    });
}

// ---- Editing after creation ----------------------------------------------------------------------

/// Changes the recipient's contact and address details (store or carrier staff). The governorate
/// can't change (price and coverage depend on it); the city can.
pub fn updateDetails(r: *Req, shipment: Val, body: Val, actor: Val) !Val {
    const a = r.a;
    const st = shipment.s("status") orelse "";
    if (!val.contains([]const u8, &editable, st)) {
        if (std.mem.eql(u8, st, "out_for_delivery")) return r.conflict("The courier is on the way: call them to change the details", "courier_on_the_way", null);
        return r.conflict("This shipment can no longer be changed", "cannot_change", null);
    }
    _ = try V.obj(r, body, "body", .{});
    const set = try val.newObj(a);
    var changed: std.ArrayList([]const u8) = .empty;
    if (body.get("dropoff") != .undef) {
        const d = (try V.obj(r, body.get("dropoff"), "dropoff", .{})).?;
        if (d.get("governorate") != .undef and !d.get("governorate").eql(shipment.path("dropoff.governorate")))
            return r.badRequest("The governorate cannot change after creation. Cancel and create a new shipment instead.", "dropoff.governorate", "governorate_locked", null);
        const fields = [_][]const u8{ "name", "phone", "city", "area", "street", "details", "location" };
        for (fields) |k| {
            if (d.get(k) == .undef) continue;
            const value: Val = if (std.mem.eql(u8, k, "name"))
                .{ .str = (try V.str(r, d.get(k), "dropoff.name", .{ .max = 120 })).? }
            else if (std.mem.eql(u8, k, "phone"))
                .{ .str = (try V.phone(r, d.get(k), "dropoff.phone", .{})).? }
            else if (std.mem.eql(u8, k, "city"))
                .{ .str = (try V.str(r, d.get(k), "dropoff.city", .{ .max = 80 })).? }
            else if (std.mem.eql(u8, k, "area"))
                orNullStr(try V.str(r, d.get(k), "dropoff.area", .{ .max = 120, .optional = true }))
            else if (std.mem.eql(u8, k, "street"))
                orNullStr(try V.str(r, d.get(k), "dropoff.street", .{ .max = 200, .optional = true }))
            else if (std.mem.eql(u8, k, "details"))
                orNullStr(try V.str(r, d.get(k), "dropoff.details", .{ .max = 500, .optional = true }))
            else if (d.get(k) == .null) Val.null else (try V.point(r, d.get(k), "dropoff.location", .{})).?;
            const current = shipment.path("dropoff").get(k);
            if (std.mem.eql(u8, try val.toJson(a, value), try val.toJson(a, if (current.isNullish()) Val.null else current))) continue;
            try set.set(try std.fmt.allocPrint(a, "dropoff.{s}", .{k}), value);
            if (std.mem.eql(u8, k, "location")) try set.set("dropoff.locationSource", if (value.truthy()) Val{ .str = "sender" } else Val.null);
            try changed.append(a, k);
        }
    }
    if (body.get("notes") != .undef) {
        const notes = orNullStr(try V.str(r, body.get("notes"), "notes", .{ .max = 500, .optional = true }));
        const current = if (shipment.t("notes")) shipment.get("notes") else Val.null;
        if (!notes.eql(current)) {
            try set.set("notes", notes);
            try changed.append(a, "notes");
        }
    }
    if (changed.items.len == 0) return shipment;
    // Content checks on the changed texts.
    const texts = try val.newObj(a);
    for (set.obj.keys.items, set.obj.vals.items) |k, v| {
        if (v != .str) continue;
        if (std.mem.indexOf(u8, k, "phone") != null or std.mem.indexOf(u8, k, "governorate") != null or std.mem.indexOf(u8, k, "city") != null or std.mem.indexOf(u8, k, "locationSource") != null) continue;
        try texts.obj.put(k, v);
    }
    if (texts.obj.count() > 0) {
        const subject = if (std.mem.eql(u8, actor.s("type") orelse "", "user") and actor.get("id").truthy())
            try val.from(a, .{ .userId = actor.get("id"), .name = orNull(actor.get("name")) })
        else
            moderation.subjectOfOrg(a, (try db.col("orgs").findOne(a, .{ ._id = shipment.get("merchantId") }, .{ .projection = try val.from(a, .{ .ownerUserId = 1, .name = 1 }) })) orelse Val.undef);
        try set.set("moderation", try moderation.stamp(a, try moderation.check(r, subject, .{ .type = "shipment", .id = try val.toStr(a, shipment.get("_id")), .field = "update" }, texts, &.{})));
    }
    return applyEvent(r, shipment, "details_updated", .{ .actor = actor, .params = try val.from(a, .{ .fields = try std.mem.join(a, ", ", changed.items) }), .set = set });
}

/// YYYY-MM-DD today in Syria (UTC+3), so "today" matches the local calendar.
pub fn localToday(a: Allocator) ![]const u8 {
    return dayOf(a, a_.nowMs() + 3 * 3600_000);
}

pub fn dayOf(a: Allocator, ms: i64) ![]const u8 {
    const iso = try val.isoAlloc(a, ms);
    return iso[0..10];
}

/// Chooses the day the parcel should be delivered (null clears it), up to 14 days ahead.
pub fn reschedule(r: *Req, shipment: Val, date: Val, actor: Val) !Val {
    const a = r.a;
    if (!val.contains([]const u8, &editable, shipment.s("status") orelse "")) return r.conflict("This shipment can no longer be rescheduled", "cannot_reschedule", null);
    var day: Val = .null;
    if (date != .null) {
        const d = date.asStr() orelse "";
        const ok = d.len == 10 and d[4] == '-' and d[7] == '-' and for ([_]usize{ 0, 1, 2, 3, 5, 6, 8, 9 }) |i| {
            if (!std.ascii.isDigit(d[i])) break false;
        } else true;
        if (!ok or val.parseDate(d) == null) return r.badRequest("date must look like 2026-10-12", "date", null, null);
        const today = try localToday(a);
        const max = try dayOf(a, a_.nowMs() + 3 * 3600_000 + 14 * 86400_000);
        if (std.mem.order(u8, d, today) == .lt or std.mem.order(u8, d, max) == .gt) return r.badRequest("Choose a day between today and 14 days from now", "date", "day_range", .{ .n = 14 });
        day = .{ .str = d };
    }
    return applyEvent(r, shipment, "rescheduled", .{ .actor = actor, .params = try val.from(a, .{ .date = if (day == .null) Val{ .str = "" } else day }), .set = try val.from(a, .{ .scheduledFor = day }) });
}

test normalizeTrackingNumber {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("TRF0K7M9Q2XAB", (try normalizeTrackingNumber(a, "trf-ok7m9 q2xab")).?);
    try std.testing.expect((try normalizeTrackingNumber(a, "nope")) == null);
    const parts = try splitTrackingNumbers(a, "TRF 7K2M9 Q4XA8, TRF1234567890 TRF0987654321");
    try std.testing.expectEqual(@as(usize, 3), parts.len);
}
