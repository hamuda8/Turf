//! After delivery: customer returns, lost or damaged parcels, and claims (src/services/claims.js).
//!
//! A customer return is a new linked shipment (returnOf / returnShipmentId) from the customer
//! back to the store, by the original carrier when it still covers the route. Claims ask the
//! carrier for compensation (lost, damaged or late); the carrier accepts (maybe for another
//! amount) or rejects; accepted compensation is added to the store's payout.

const std = @import("std");
const val = @import("../lib/val.zig");
const db = @import("../lib/db.zig");
const web = @import("../web.zig");
const a_ = @import("../app.zig");
const bus = @import("../bus.zig");
const shipments_ = @import("shipments.zig");
const allocation = @import("allocation.zig");
const places = @import("places.zig");
const audit = @import("audit.zig");
const moderation = @import("moderation.zig");
const Val = val.Val;
const Req = web.Req;
const V = web.V;
const Allocator = std.mem.Allocator;

pub const return_days = 30;
pub const claim_types = [_][]const u8{ "lost", "damaged", "late" };
const claim_days = 60;

fn eq(x: []const u8, y: []const u8) bool {
    return std.mem.eql(u8, x, y);
}

fn orNullStr(s: ?[]const u8) Val {
    return if (s) |x| (if (x.len > 0) Val{ .str = x } else .null) else .null;
}

// ---- Customer returns ----------------------------------------------------------------------------

pub fn requestCustomerReturn(r: *Req, merchant: Val, shipment: Val, body: Val, actor: Val) !Val {
    const a = r.a;
    if (!eq(shipment.s("status") orelse "", "delivered")) return r.conflict("Only delivered parcels can be returned by the customer", "return_not_delivered", null);
    if (shipment.t("returnShipmentId")) return r.conflict("A return was already created for this parcel", "return_exists", null);
    if (shipment.t("test")) return r.conflict("Use the test API to create practice shipments", "test_shipment", null);
    const delivered_at = val.newDate(shipment.get("deliveredAt")) orelse 0;
    if (a_.nowMs() - delivered_at > return_days * 86400_000) return r.conflict(try std.fmt.allocPrint(a, "Returns can be requested up to {d} days after delivery", .{return_days}), "return_too_late", .{ .n = return_days });
    const b = (try V.obj(r, if (body.truthy()) body else try val.newObj(a), "body", .{})).?;
    const reason = orNullStr(try V.str(r, b.get("reason"), "reason", .{ .max = 300, .optional = true }));
    // The carrier and the courier read the reason.
    const check = try moderation.check(r, moderation.subjectOfOrg(a, merchant), .{ .type = "shipment", .id = try val.toStr(a, shipment.get("_id")), .field = "return" }, try val.from(a, .{ .reason = reason }), &.{});
    const home = try places.defaultPlace(a, merchant);
    const destination = if (home.truthy()) blk: {
        const d = try home.copy(a);
        for ([_][]const u8{ "_id", "label", "isDefault", "createdAt", "updatedAt" }) |k| d.del(k);
        break :blk d;
    } else shipment.get("pickup");
    const desc = shipment.path("parcel.description");
    var notes: std.ArrayList([]const u8) = .empty;
    if (reason.truthy()) try notes.append(a, try std.fmt.allocPrint(a, "Return reason: {s}", .{reason.str}));
    if (try V.str(r, b.get("notes"), "notes", .{ .max = 300, .optional = true })) |n| if (n.len > 0) try notes.append(a, n);
    const input = try val.from(a, .{
        .moderation = try moderation.stamp(a, check),
        .reference = null,
        .carrier = "auto",
        .strategy = "balanced",
        .pickup = try shipment.get("dropoff").copy(a),
        .dropoff = try destination.copy(a),
        .parcel = try val.spread(a, .{ shipment.get("parcel"), .{ .description = if (desc.truthy()) Val{ .str = try std.fmt.allocPrint(a, "Return: {s}", .{try val.toStr(a, desc)}) } else Val{ .str = "Customer return" } } }),
        .codAmount = 0,
        .notes = if (notes.items.len > 0) Val{ .str = try std.mem.join(a, " · ", notes.items) } else Val.null,
        .requireDeliveryCode = false,
    });
    // Prefer the carrier that delivered it.
    if (try db.col("orgs").findOne(a, .{ ._id = shipment.get("carrierId") }, .{})) |original| {
        const m = try allocation.measureCarrier(r, original, try val.from(a, .{ .pickup = input.get("pickup"), .dropoff = input.get("dropoff"), .weightKg = input.path("parcel.weightKg"), .codAmount = 0, .merchantId = merchant.get("_id"), .mode = "direct" }));
        if (!m.get("reason").truthy()) try input.set("carrier", try val.toStr(a, original.get("_id")));
    }
    const created = try shipments_.createShipment(r, merchant, input, actor);
    const ret = created.get("shipment");
    _ = try db.col("shipments").updateOne(a, .{ ._id = ret.get("_id") }, .{ .@"$set" = .{ .returnOf = shipment.get("_id"), .kind = "customer_return" } }, .{});
    const saved = r.err;
    _ = shipments_.applyEvent(r, shipment, "customer_return_requested", .{
        .actor = actor,
        .params = try val.from(a, .{ .tracking = ret.get("trackingNumber") }),
        .note = reason,
        .set = try val.from(a, .{ .returnShipmentId = ret.get("_id") }),
    }) catch {
        r.err = saved;
        _ = try db.col("shipments").updateOne(a, .{ ._id = shipment.get("_id") }, .{ .@"$set" = .{ .returnShipmentId = ret.get("_id") } }, .{});
    };
    return val.spread(a, .{ ret, .{ .returnOf = shipment.get("_id"), .kind = "customer_return" } });
}

// ---- Lost / damaged ------------------------------------------------------------------------------

fn staffActor(a: Allocator, ctx: *const web.OrgCtx) !Val {
    return val.from(a, .{ .type = "user", .id = ctx.member.get("userId"), .name = ctx.member.get("name") });
}

pub fn markLost(r: *Req, ctx: *const web.OrgCtx, shipment: Val, note: ?[]const u8) !Val {
    const a = r.a;
    const n = note orelse "";
    if (n.len == 0) return r.badRequest("Explain what happened", "note", "explain", null);
    if (shipment.t("currentTaskId")) {
        if (try db.col("tasks").findOne(a, .{ ._id = shipment.get("currentTaskId"), .status = "in_progress" }, .{}) != null)
            return r.conflict("This parcel is on an active task. Finish or reassign the task first.", "on_active_task", null);
    }
    const updated = try shipments_.applyEvent(r, shipment, "lost", .{ .actor = try staffActor(a, ctx), .note = .{ .str = n }, .set = try val.from(a, .{ .currentTaskId = null, .lostAt = a_.now() }) });
    audit.audit(a, ctx.org.get("_id"), ctx.member, "shipment.marked_lost", .{ .trackingNumber = shipment.get("trackingNumber") });
    return updated;
}

pub fn reportDamage(r: *Req, ctx: *const web.OrgCtx, shipment: Val, note: ?[]const u8) !Val {
    const a = r.a;
    const n = note orelse "";
    if (n.len == 0) return r.badRequest("Describe the damage", "note", "explain", null);
    return shipments_.applyEvent(r, shipment, "damage_reported", .{ .actor = try staffActor(a, ctx), .note = .{ .str = n }, .params = try val.from(a, .{ .note = n }), .set = try val.from(a, .{ .damaged = true }) });
}

// ---- Claims --------------------------------------------------------------------------------------

fn claimOut(a: Allocator, c: Val) !Val {
    return val.spread(a, .{ c, .{ .id = c.get("_id") } });
}

pub fn openClaim(r: *Req, merchant: Val, shipment: Val, body: Val, actor: Val) !Val {
    const a = r.a;
    const b = (try V.obj(r, body, "body", .{})).?;
    const t = (try V.oneOf(r, b.get("type"), "type", &claim_types, .{})).?;
    if (shipment.t("test")) return r.conflict("Test shipments have no claims", "test_shipment", null);
    if (!shipment.t("carrierId")) return r.conflict("No shipping company has this parcel", "no_carrier_yet", null);
    const st = shipment.s("status") orelse "";
    if (eq(t, "lost") and !val.contains([]const u8, &.{ "lost", "in_transit", "at_hub", "picked_up", "out_for_delivery", "delivery_failed", "returning" }, st))
        return r.conflict("A lost claim needs a parcel that was picked up and not delivered", "claim_lost_invalid", null);
    if (eq(t, "damaged") and !eq(st, "delivered") and !eq(st, "returned") and !shipment.t("damaged"))
        return r.conflict("A damage claim is made after delivery (or once damage was reported)", "claim_damage_invalid", null);
    if (eq(t, "late")) {
        const promised = val.newDate(shipment.get("promisedBy"));
        const done = if (shipment.t("deliveredAt")) val.newDate(shipment.get("deliveredAt")) orelse a_.nowMs() else a_.nowMs();
        if (!(shipment.t("promisedBy") and promised != null and done > promised.?)) return r.conflict("This parcel was not late", "claim_not_late", null);
    }
    if (a_.nowMs() - (val.newDate(shipment.get("createdAt")) orelse 0) > claim_days * 86400_000)
        return r.conflict(try std.fmt.allocPrint(a, "Claims can be opened up to {d} days after the shipment", .{claim_days}), "claim_too_late", .{ .n = claim_days });
    if (try db.col("claims").findOne(a, .{ .shipmentId = shipment.get("_id"), .status = "open" }, .{}) != null)
        return r.conflict("There is already an open claim for this parcel", "claim_exists", null);
    // The carrier reads the description.
    const description = (try V.str(r, b.get("description"), "description", .{ .min = 5, .max = 1000 })).?;
    const subject = if (eq(actor.s("type") orelse "", "user") and actor.get("id").truthy())
        try val.from(a, .{ .userId = actor.get("id"), .name = if (actor.t("name")) actor.get("name") else Val.null })
    else
        moderation.subjectOfOrg(a, merchant);
    const outcome = try moderation.check(r, subject, .{ .type = "claim", .id = try val.toStr(a, shipment.get("_id")), .field = "description" }, try val.from(a, .{ .description = description }), &.{});
    const now = a_.now();
    const claim = try val.from(a, .{
        .moderation = try moderation.stamp(a, outcome),
        .shipmentId = shipment.get("_id"),
        .trackingNumber = shipment.get("trackingNumber"),
        .merchantId = merchant.get("_id"),
        .merchantName = merchant.get("name"),
        .carrierId = shipment.get("carrierId"),
        .carrierName = shipment.get("carrierName"),
        .type = t,
        .amount = (try V.num(r, b.get("amount"), "amount", .{ .min = 0, .max = 1e12 })).?,
        .currency = if (shipment.path("price.currency").truthy()) shipment.path("price.currency") else Val{ .str = "SYP" },
        .description = description,
        .status = "open",
        .openedBy = actor,
        .createdAt = now,
        .updatedAt = now,
    });
    _ = try db.col("claims").insertOne(a, claim);
    bus.emit(r, "claim.changed", .{ .claim = claim });
    return claimOut(a, claim);
}

pub fn decideClaim(r: *Req, ctx: *const web.OrgCtx, claim_id: Val, body: Val) !Val {
    const a = r.a;
    const b = (try V.obj(r, body, "body", .{})).?;
    const decision = (try V.oneOf(r, b.get("decision"), "decision", &.{ "accepted", "rejected" }, .{})).?;
    const claim = (try db.col("claims").findOne(a, .{ ._id = claim_id, .carrierId = ctx.org.get("_id") }, .{})) orelse return r.notFound("Claim");
    if (!eq(claim.s("status") orelse "", "open")) return r.conflict("This claim was already decided", "claim_decided", null);
    const set = try val.from(a, .{ .status = decision, .decidedAt = a_.now(), .decidedBy = .{ .id = ctx.member.get("userId"), .name = ctx.member.get("name") }, .updatedAt = a_.now() });
    if (eq(decision, "accepted")) {
        try set.set("compensation", if (b.get("amount") == .undef) claim.get("amount") else Val{ .num = (try V.num(r, b.get("amount"), "amount", .{ .min = 0, .max = 1e12 })).? });
        try set.set("response", orNullStr(try V.str(r, b.get("response"), "response", .{ .max = 1000, .optional = true })));
    } else try set.set("response", (try V.str(r, b.get("response"), "response", .{ .min = 3, .max = 1000 })).?);
    // The store reads the response.
    if (set.get("response").truthy())
        _ = try moderation.check(r, try val.from(a, .{ .userId = ctx.member.get("userId"), .name = ctx.member.get("name") }), .{ .type = "claim", .id = try val.toStr(a, claim.get("_id")), .field = "response" }, try val.from(a, .{ .response = set.get("response") }), &.{});
    const updated = (try db.col("claims").findOneAndUpdate(a, .{ ._id = claim.get("_id"), .status = "open" }, .{ .@"$set" = set }, .{ .returnDocument = .after })) orelse
        return r.conflict("This claim was already decided", "claim_decided", null);
    audit.audit(a, ctx.org.get("_id"), ctx.member, try std.fmt.allocPrint(a, "claim.{s}", .{decision}), .{ .trackingNumber = claim.get("trackingNumber"), .compensation = if (set.get("compensation").isNullish()) Val.null else set.get("compensation") });
    bus.emit(r, "claim.changed", .{ .claim = updated });
    return claimOut(a, updated);
}

pub fn listClaims(a: Allocator, filter: Val) ![]Val {
    const list = try db.col("claims").find(a, filter, .{ .sort = try val.from(a, .{ .createdAt = -1 }), .limit = 300 });
    for (list) |*c| c.* = try claimOut(a, c.*);
    return list;
}

pub fn withdrawClaim(r: *Req, merchant_id: Val, claim_id: Val) !void {
    const res = try db.col("claims").updateOne(r.a, .{ ._id = claim_id, .merchantId = merchant_id, .status = "open" }, .{ .@"$set" = .{ .status = "withdrawn", .updatedAt = a_.now() } }, .{});
    if (res.matched == 0) return r.fail(409, "conflict", "Only open claims can be withdrawn", .{});
}
