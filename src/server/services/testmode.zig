//! API test mode (src/services/testmode.js): shipments made with a test key (turf_test_...) are
//! practice shipments (test: true): no real carrier sees them, they are not billed and don't
//! count in statements. The store moves them through every status with /simulate and gets the
//! same webhooks as for real ones.

const std = @import("std");
const val = @import("mongo").val;
const db = @import("../lib/db.zig");
const web = @import("../web.zig");
const a_ = @import("../app.zig");
const crypto = @import("../crypto.zig");
const bus = @import("../bus.zig");
const shipments_ = @import("shipments.zig");
const Val = val.Val;
const Req = web.Req;
const Allocator = std.mem.Allocator;

pub const test_carrier_id = "test";
pub const test_carrier_name = "Turf Test Carrier";

fn national(input: Val) bool {
    return !input.path("pickup.governorate").eql(input.path("dropoff.governorate"));
}

/// A predictable test price: 2,000 + 500 per kg above 1 kg (+1,000 between governorates).
pub fn testQuote(a: Allocator, input: Val) !Val {
    const nat = national(input);
    const amount = 2000 + val.jsMax(0, @ceil(val.toNum(input.path("parcel.weightKg")) - 1)) * 500 + @as(f64, if (nat) 1000 else 0);
    const base: f64 = if (nat) 3000 else 2000;
    return val.from(a, .{ .amount = amount, .currency = "SYP", .breakdown = .{ .base = base, .weight = amount - base, .distance = 0, .cod = 0 }, .zone = if (nat) "national" else "local" });
}

fn etaHours(input: Val, zone: []const u8) f64 {
    if (std.mem.eql(u8, input.s("service") orelse "", "express")) return 1;
    return if (std.mem.eql(u8, zone, "local")) 24 else 72;
}

pub fn testOption(a: Allocator, input: Val) !Val {
    const q = try testQuote(a, input);
    return val.from(a, .{
        .carrier = .{ .id = test_carrier_id, .name = test_carrier_name, .slug = "turf-test", .logoUrl = null },
        .price = .{ .amount = q.get("amount"), .currency = q.get("currency"), .breakdown = q.get("breakdown") },
        .zone = q.get("zone"),
        .service = input.get("service"),
        .etaHours = etaHours(input, q.s("zone").?),
        .distanceKm = null,
        .reliability = 1,
        .load = 0,
        .score = 1,
        .@"test" = true,
    });
}

pub fn createTestShipment(r: *Req, merchant: Val, input: Val, actor: Val) !Val {
    const a = r.a;
    if (input.t("reference")) {
        if (try db.col("shipments").findOne(a, .{ .merchantId = merchant.get("_id"), .testRef = input.get("reference") }, .{})) |existing|
            return val.from(a, .{ .shipment = existing, .created = false });
    }
    const now_ms = a_.nowMs();
    const now: Val = .{ .date = now_ms };
    const q = try testQuote(a, input);
    const cod_amount = input.n("codAmount") orelse 0;
    const shipment = try val.from(a, .{
        .@"test" = true,
        .trackingNumber = try crypto.newTrackingNumber(a),
        .publicToken = try crypto.randomToken(a, 18),
        .labelToken = try crypto.randomToken(a, 18),
        .merchantId = merchant.get("_id"),
        .merchantName = merchant.get("name"),
        .carrierId = null,
        .carrierName = test_carrier_name,
        .carrierIds = .{},
    });
    // Separate from externalRef, so test references never block real ones.
    if (input.t("reference")) try shipment.set("testRef", input.get("reference"));
    const rest = try val.from(a, .{
        .createdBy = actor,
        .status = "awaiting_pickup",
        .statusAt = now,
        .zone = q.get("zone"),
        .service = input.get("service"),
        .allocation = .{ .mode = "test", .strategy = null, .score = null, .metrics = null, .alternatives = 0, .decidedAt = now },
        .pickup = input.get("pickup"),
        .dropoff = input.get("dropoff"),
        .parcel = input.get("parcel"),
        .cod = if (cod_amount > 0) try val.from(a, .{ .amount = cod_amount, .currency = "SYP", .collectedAt = null, .collectedBy = null, .settledAt = null, .remittedAt = null }) else Val.null,
        .price = .{ .amount = q.get("amount"), .currency = q.get("currency"), .breakdown = q.get("breakdown") },
        .roadKm = null,
        .promisedBy = val.Date{ .ms = now_ms + @as(i64, @intFromFloat(etaHours(input, q.s("zone").?) * 3600_000)) },
        .requireCode = input.get("requireDeliveryCode"),
        .deliveryCode = try crypto.newDeliveryCode(a),
        .custody = .{ .type = "merchant" },
        .currentTaskId = null,
        .attempts = 0,
        .notes = input.get("notes"),
        .pod = null,
        .createdAt = now,
        .updatedAt = now,
    });
    for (rest.obj.keys.items, rest.obj.vals.items) |k, v| try shipment.obj.put(k, v);
    _ = db.col("shipments").insertOne(a, shipment) catch |e| {
        if (e == error.DuplicateKey and input.t("reference")) {
            if (try db.col("shipments").findOne(a, .{ .merchantId = merchant.get("_id"), .testRef = input.get("reference") }, .{})) |existing|
                return val.from(a, .{ .shipment = existing, .created = false });
        }
        return e;
    };
    _ = try db.col("shipment_events").insertMany(a, &.{
        try val.from(a, .{ .shipmentId = shipment.get("_id"), .carrierId = null, .merchantId = merchant.get("_id"), .code = "created", .status = "awaiting_pickup", .params = .{ .merchant = merchant.get("name") }, .actor = actor, .at = now, .internal = false, .hubId = null, .location = null, .note = null }),
        try val.from(a, .{ .shipmentId = shipment.get("_id"), .carrierId = null, .merchantId = merchant.get("_id"), .code = "carrier_assigned", .status = "awaiting_pickup", .params = .{ .carrier = test_carrier_name }, .actor = .{ .type = "system" }, .at = now, .internal = false, .hubId = null, .location = null, .note = null }),
    });
    bus.emit(r, "shipment.created", .{ .shipment = shipment, .carrier = null, .merchant = merchant });
    return val.from(a, .{ .shipment = shipment, .created = true });
}

const Path = struct { target: []const u8, steps: []const []const u8 };

/// Event sequences that reach each target status from the start.
const paths = [_]Path{
    .{ .target = "picked_up", .steps = &.{"picked_up"} },
    .{ .target = "at_hub", .steps = &.{ "picked_up", "arrived_at_hub" } },
    .{ .target = "in_transit", .steps = &.{ "picked_up", "arrived_at_hub", "departed_hub" } },
    .{ .target = "out_for_delivery", .steps = &.{ "picked_up", "arrived_at_hub", "out_for_delivery" } },
    .{ .target = "delivered", .steps = &.{ "picked_up", "arrived_at_hub", "out_for_delivery", "delivered" } },
    .{ .target = "delivery_failed", .steps = &.{ "picked_up", "arrived_at_hub", "out_for_delivery", "delivery_failed" } },
    .{ .target = "returned", .steps = &.{ "picked_up", "arrived_at_hub", "return_started", "returned" } },
};

pub const simulate_targets = blk: {
    var out: []const []const u8 = &.{};
    for (paths) |p| out = out ++ &[_][]const u8{p.target};
    break :blk out;
};

fn statusAfter(code: []const u8) []const u8 {
    const map = [_][2][]const u8{ .{ "picked_up", "picked_up" }, .{ "arrived_at_hub", "at_hub" }, .{ "departed_hub", "in_transit" }, .{ "out_for_delivery", "out_for_delivery" }, .{ "delivered", "delivered" }, .{ "delivery_failed", "delivery_failed" }, .{ "return_started", "returning" }, .{ "returned", "returned" } };
    for (map) |m| if (std.mem.eql(u8, m[0], code)) return m[1];
    return "";
}

/// Moves a test shipment forward to `target`, emitting every step (and its webhook).
pub fn simulate(r: *Req, shipment: Val, target: []const u8) !Val {
    const a = r.a;
    if (!shipment.t("test")) return r.fail(403, "not_a_test_shipment", "Only test shipments can be simulated", .{});
    const path = for (paths) |p| {
        if (std.mem.eql(u8, p.target, target)) break p;
    } else return r.badRequest(try std.fmt.allocPrint(a, "to must be one of: {s}", .{try std.mem.join(a, ", ", simulate_targets)}), "to", null, null);
    const st = shipment.s("status") orelse "";
    // Continue from where the shipment is now.
    var steps: ?[]const []const u8 = null;
    if (std.mem.eql(u8, st, "awaiting_pickup")) {
        steps = path.steps;
    } else for (path.steps, 0..) |code, i| if (std.mem.eql(u8, statusAfter(code), st)) {
        steps = path.steps[i + 1 ..];
        break;
    };
    if (steps == null or steps.?.len == 0) return r.conflict(try std.fmt.allocPrint(a, "A \"{s}\" test shipment cannot move to \"{s}\"", .{ st, target }), "wrong_status", .{ .status = st });
    const test_hub = try val.from(a, .{ ._id = null, .name = "Test Hub", .city = shipment.path("dropoff.city") });
    var s = shipment;
    for (steps.?) |code| {
        var o: shipments_.EventOpts = .{ .actor = try val.from(a, .{ .type = "system", .name = "Test mode" }) };
        if (std.mem.eql(u8, code, "arrived_at_hub") or std.mem.eql(u8, code, "departed_hub")) o.hub = test_hub;
        if (std.mem.eql(u8, code, "out_for_delivery")) o.params = try val.from(a, .{ .courier = "Test", .vehicle = "motorbike" });
        if (std.mem.eql(u8, code, "delivery_failed")) {
            o.params = try val.from(a, .{ .reason = "recipient_unreachable" });
            o.inc = try val.from(a, .{ .attempts = 1 });
        }
        if (std.mem.eql(u8, code, "delivered")) {
            o.set = try val.from(a, .{ .custody = .{ .type = "recipient" }, .pod = .{ .method = "code", .receiverName = "Test recipient", .at = a_.now() } });
            if (s.t("cod")) try o.set.set("cod.collectedAt", a_.now());
        }
        if (std.mem.eql(u8, code, "return_started")) o.set = try val.from(a, .{ .returnRequired = true });
        if (std.mem.eql(u8, code, "returned")) o.set = try val.from(a, .{ .custody = .{ .type = "merchant" } });
        s = try shipments_.applyEvent(r, s, code, o);
    }
    return s;
}
