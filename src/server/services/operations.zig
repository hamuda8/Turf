//! Carrier staff operations on shipments outside the courier task flow
//! (src/services/operations.js): hub check-in, manual delivery, returns, notes, cancelling, and
//! cash on delivery.

const std = @import("std");
const val = @import("mongo").val;
const db = @import("../lib/db.zig");
const web = @import("../web.zig");
const a_ = @import("../app.zig");
const bus = @import("../bus.zig");
const shipments_ = @import("shipments.zig");
const relay = @import("relay.zig");
const tasks = @import("tasks.zig");
const moderation = @import("moderation.zig");
const Val = val.Val;
const Req = web.Req;
const OrgCtx = web.OrgCtx;
const Allocator = std.mem.Allocator;

fn eq(x: []const u8, y: []const u8) bool {
    return std.mem.eql(u8, x, y);
}

fn staffActor(a: Allocator, ctx: *const OrgCtx) !Val {
    return val.from(a, .{ .type = "user", .id = ctx.member.get("userId"), .name = ctx.member.get("name") });
}

/// Takes a shipment out of a task that has not started yet; cancels the task when nothing is left.
pub fn detachFromPlannedTask(r: *Req, shipment: Val, actor: Val) !void {
    const a = r.a;
    if (!shipment.t("currentTaskId")) return;
    const now = a_.now();
    if (try db.col("tasks").findOne(a, .{ ._id = shipment.get("currentTaskId") }, .{})) |task| {
        const st = task.s("status") orelse "";
        if (val.contains([]const u8, &.{ "pending", "assigned", "accepted" }, st)) {
            const left = try db.col("tasks").findOneAndUpdate(a, .{ ._id = task.get("_id"), .status = st }, .{ .@"$pull" = .{ .shipmentIds = shipment.get("_id") }, .@"$set" = .{ .updatedAt = now } }, .{ .returnDocument = .after });
            if (left) |l| if (l.get("shipmentIds").items().len == 0) {
                _ = try db.col("tasks").updateOne(a, .{ ._id = task.get("_id"), .status = st }, .{ .@"$set" = .{ .status = "cancelled", .cancelledAt = now, .cancelledBy = actor } }, .{});
            };
            bus.emit(r, "task.changed", .{ .taskId = task.get("_id"), .carrierId = task.get("carrierId"), .courierId = task.get("courierId") });
        }
    }
    _ = try db.col("shipments").updateOne(a, .{ ._id = shipment.get("_id"), .currentTaskId = shipment.get("currentTaskId") }, .{ .@"$set" = .{ .currentTaskId = null } }, .{});
}

fn goesTo(task: Val, hub: Val) bool {
    return eq(task.path("to.kind").asStr() orelse "", "hub") and task.path("to.hubId").sameId(hub.get("_id"));
}

/// Removes a parcel from the in-progress task bringing it to this hub; finishes the task when empty.
fn finishArrivingTask(r: *Req, shipment: Val, hub: Val) !void {
    const a = r.a;
    if (!shipment.t("currentTaskId")) return;
    const task = (try db.col("tasks").findOne(a, .{ ._id = shipment.get("currentTaskId"), .status = "in_progress" }, .{})) orelse return;
    if (!goesTo(task, hub)) return;
    try checkInFromTask(r, task, shipment);
}

fn checkInFromTask(r: *Req, task: Val, shipment: Val) !void {
    const a = r.a;
    const now = a_.now();
    const left = try db.col("tasks").findOneAndUpdate(a, .{ ._id = task.get("_id"), .status = "in_progress" }, .{
        .@"$pull" = .{ .shipmentIds = shipment.get("_id") },
        .@"$push" = .{ .checkedIn = shipment.get("_id") },
        .@"$set" = .{ .updatedAt = now },
    }, .{ .returnDocument = .after });
    const empty = if (left) |l| l.get("shipmentIds").items().len == 0 else false;
    if (empty) _ = try db.col("tasks").updateOne(a, .{ ._id = task.get("_id"), .status = "in_progress" }, .{ .@"$set" = .{ .status = "completed", .completedAt = now } }, .{});
    // completed: !left?.shipmentIds.length (true also when the task vanished)
    bus.emit(r, "task.changed", .{ .taskId = task.get("_id"), .carrierId = task.get("carrierId"), .courierId = task.get("courierId"), .completed = left == null or empty });
}

/// The next carrier of a relay receives the parcel at one of its hubs.
fn relayCheckIn(r: *Req, ctx: *const OrgCtx, hub: Val, shipment: Val) !Val {
    const a = r.a;
    const next = relay.nextLeg(shipment);
    if (!next.truthy() or !next.get("carrierId").sameId(ctx.org.get("_id")) or shipment.t("returnRequired"))
        return r.conflict("This parcel is not coming to your company", "not_coming_here", null);
    const st = shipment.s("status") orelse "";
    if (!val.contains([]const u8, &.{ "picked_up", "in_transit", "at_hub" }, st))
        return r.conflict(try std.fmt.allocPrint(a, "A \"{s}\" parcel cannot be handed over yet", .{st}), "cannot_hand_over", .{ .status = st });
    try finishArrivingTask(r, shipment, hub);
    const fresh = (try db.col("shipments").findOne(a, .{ ._id = shipment.get("_id") }, .{})) orelse return r.notFound("Shipment");
    return tasks.handOver(r, fresh, hub, try staffActor(a, ctx), .undef);
}

/// A hub operator scans a parcel into a hub: a merchant dropping it at a branch, a courier
/// handing it in, or a parcel moved between hubs outside a task. Every check runs before
/// anything changes, so a refused scan has no side effects.
pub fn hubCheckIn(r: *Req, ctx: *const OrgCtx, hub: Val, shipment: Val) !Val {
    const a = r.a;
    // Relay: the next company scans the parcel in at its hub, which completes the handover.
    if (!shipment.get("carrierId").sameId(ctx.org.get("_id"))) return relayCheckIn(r, ctx, hub, shipment);
    const st = shipment.s("status") orelse "";
    // Relay return arriving at the handover hub: it goes back to the previous company.
    const prev = relay.previousLeg(shipment);
    if (prev.truthy() and shipment.t("returnRequired") and prev.path("to.hubId").truthy() and prev.path("to.hubId").sameId(hub.get("_id")) and (eq(st, "returning") or eq(st, "at_hub"))) {
        try finishArrivingTask(r, shipment, hub);
        return tasks.handBack(r, shipment, hub, try staffActor(a, ctx));
    }
    const custody = shipment.get("custody");
    if (eq(custody.s("type") orelse "", "hub") and custody.get("hubId").truthy() and custody.get("hubId").sameId(hub.get("_id")) and eq(st, "at_hub"))
        return r.conflict("This parcel is already checked in at this hub", "already_checked_in", null);
    if (!eq(st, "awaiting_pickup") and !shipments_.canApply("arrived_at_hub", st))
        return r.conflict(try std.fmt.allocPrint(a, "A \"{s}\" parcel cannot be checked in", .{st}), "cannot_check_in", .{ .status = st });
    const actor = try staffActor(a, ctx);
    const task: ?Val = if (shipment.t("currentTaskId")) try db.col("tasks").findOne(a, .{ ._id = shipment.get("currentTaskId") }, .{}) else null;
    const arriving: ?Val = if (task) |t| (if (eq(t.s("status") orelse "", "in_progress")) t else null) else null;
    if (arriving) |t| if (!goesTo(t, hub)) return r.conflict("This parcel is on an active task going somewhere else", "task_elsewhere", null);

    var s = shipment;
    if (eq(st, "awaiting_pickup")) s = try shipments_.applyEvent(r, s, "picked_up", .{ .actor = actor, .hub = hub, .params = try val.newObj(a) });
    const updated = try shipments_.applyEvent(r, s, "arrived_at_hub", .{ .actor = actor, .hub = hub, .set = try val.from(a, .{ .custody = .{ .type = "hub", .hubId = hub.get("_id") }, .currentTaskId = null }) });
    if (arriving) |t| {
        // A courier delivering to this hub: check the parcel in, finish the task once all are in.
        try checkInFromTask(r, t, shipment);
    } else if (task) |t| {
        // The parcel showed up before its planned task started: drop it from that task.
        try detachFromPlannedTask(r, try val.spread(a, .{ shipment, .{ .currentTaskId = t.get("_id") } }), actor);
    }
    return updated;
}

/// Staff confirms a delivery by hand (the recipient lost the code; verified by phone).
pub fn manualDeliver(r: *Req, ctx: *const OrgCtx, shipment: Val, receiver_name: ?[]const u8, note: ?[]const u8, cod_collected: Val) !Val {
    const a = r.a;
    if (!eq(shipment.s("status") orelse "", "out_for_delivery")) return r.conflict("Only shipments out for delivery can be confirmed", "not_out_for_delivery", null);
    const n = note orelse "";
    if (n.len == 0) return r.badRequest("Explain how the delivery was verified", "note", "explain", null);
    if (shipment.t("cod") and !(cod_collected == .bool and cod_collected.bool)) return r.badRequest("Confirm that the cash amount was collected", "codCollected", "confirm_cash", null);
    const now = a_.now();
    const task: ?Val = if (shipment.t("currentTaskId")) try db.col("tasks").findOne(a, .{ ._id = shipment.get("currentTaskId") }, .{}) else null;
    const courier_id: Val = if (task) |t| (if (t.t("courierId")) t.get("courierId") else .null) else .null;
    const set = try val.from(a, .{
        .custody = .{ .type = "recipient" },
        .currentTaskId = null,
        .pod = .{ .method = "staff_override", .receiverName = if (receiver_name) |x| (if (x.len > 0) Val{ .str = x } else Val.null) else Val.null, .note = n, .at = now, .by = ctx.member.get("userId"), .courierId = courier_id },
    });
    if (shipment.t("cod")) {
        try set.set("cod.collectedAt", now);
        try set.set("cod.collectedBy", courier_id);
    }
    const updated = try shipments_.applyEvent(r, shipment, "delivered", .{ .actor = try staffActor(a, ctx), .set = set, .note = .{ .str = n } });
    if (task) |t| if (eq(t.s("status") orelse "", "in_progress")) {
        _ = try db.col("tasks").updateOne(a, .{ ._id = t.get("_id") }, .{ .@"$set" = .{ .status = "completed", .completedAt = now, .updatedAt = now, .override = true } }, .{});
        bus.emit(r, "task.changed", .{ .taskId = t.get("_id"), .carrierId = t.get("carrierId"), .courierId = t.get("courierId"), .completed = true });
    };
    return updated;
}

/// Starts a return for a shipment that can't be delivered (e.g. the merchant asks).
pub fn startReturn(r: *Req, ctx: *const OrgCtx, shipment: Val, note: Val) !Val {
    const a = r.a;
    const st = shipment.s("status") orelse "";
    if (!shipments_.canApply("return_started", st)) return r.conflict(try std.fmt.allocPrint(a, "A \"{s}\" parcel cannot be returned", .{st}), "cannot_return", .{ .status = st });
    if (shipment.t("currentTaskId")) {
        if (try db.col("tasks").findOne(a, .{ ._id = shipment.get("currentTaskId"), .status = "in_progress" }, .{}) != null)
            return r.conflict("This parcel is on an active task. Wait until it is completed.", "on_active_task", null);
    }
    // Any planned (not started) delivery or transfer no longer applies.
    try detachFromPlannedTask(r, shipment, try staffActor(a, ctx));
    const started = try shipments_.applyEvent(r, try val.spread(a, .{ shipment, .{ .currentTaskId = null } }), "return_started", .{
        .actor = try staffActor(a, ctx),
        .note = note,
        .set = try val.from(a, .{ .returnRequired = true, .currentTaskId = null }),
    });
    // A relay parcel already at the handover hub goes straight back to the previous company.
    const prev = relay.previousLeg(started);
    const custody = started.get("custody");
    if (prev.truthy() and eq(custody.s("type") orelse "", "hub") and prev.path("to.hubId").truthy() and prev.path("to.hubId").sameId(custody.get("hubId"))) {
        const hub = (try db.col("hubs").findOne(a, .{ ._id = custody.get("hubId") }, .{})) orelse Val.null;
        return tasks.handBack(r, started, hub, try staffActor(a, ctx));
    }
    return started;
}

pub fn addNote(r: *Req, ctx: *const OrgCtx, shipment: Val, note: []const u8, visible_to_customer: bool) !Val {
    const a = r.a;
    // The merchant, and the recipient when visible, read this.
    _ = try moderation.check(r, try val.from(a, .{ .userId = ctx.member.get("userId"), .name = ctx.member.get("name") }), .{ .type = "shipment", .id = try val.toStr(a, shipment.get("_id")), .field = "note" }, try val.from(a, .{ .note = note }), &.{});
    return shipments_.applyEvent(r, shipment, "note", .{
        .actor = try staffActor(a, ctx),
        .params = try val.from(a, .{ .note = note }),
        .note = .{ .str = note },
        .internal = !visible_to_customer,
    });
}

/// The carrier cancels a shipment it cannot fulfil (only before pickup).
pub fn carrierCancel(r: *Req, ctx: *const OrgCtx, shipment: Val, note: Val) !Val {
    const a = r.a;
    if (!eq(shipment.s("status") orelse "", "awaiting_pickup")) return r.conflict("Only shipments not yet picked up can be cancelled. Start a return instead.", "cancel_too_late", null);
    const task: ?Val = if (shipment.t("currentTaskId")) try db.col("tasks").findOne(a, .{ ._id = shipment.get("currentTaskId") }, .{}) else null;
    if (task) |t| if (eq(t.s("status") orelse "", "in_progress")) return r.conflict("A courier is collecting this shipment right now", "being_collected", null);
    const updated = try shipments_.applyEvent(r, shipment, "cancelled", .{ .actor = try staffActor(a, ctx), .note = note, .set = try val.from(a, .{ .currentTaskId = null }) });
    if (task != null) try detachFromPlannedTask(r, shipment, try staffActor(a, ctx));
    return updated;
}

// ---- Cash on delivery ----------------------------------------------------------------------------

/// The courier hands collected cash to the carrier.
pub fn settleCod(r: *Req, ctx: *const OrgCtx, ids: Val) !i64 {
    const res = try db.col("shipments").updateMany(r.a, .{ ._id = .{ .@"$in" = ids }, .carrierId = ctx.org.get("_id"), .@"cod.collectedAt" = .{ .@"$ne" = null }, .@"cod.settledAt" = null }, .{
        .@"$set" = .{ .@"cod.settledAt" = a_.now(), .@"cod.settledBy" = ctx.member.get("userId") },
    }, .{});
    return res.modified;
}

/// The carrier pays collected cash out to the merchant.
pub fn remitCod(r: *Req, ctx: *const OrgCtx, ids: Val) !i64 {
    const res = try db.col("shipments").updateMany(r.a, .{ ._id = .{ .@"$in" = ids }, .carrierId = ctx.org.get("_id"), .@"cod.settledAt" = .{ .@"$ne" = null }, .@"cod.remittedAt" = null }, .{
        .@"$set" = .{ .@"cod.remittedAt" = a_.now(), .@"cod.remittedBy" = ctx.member.get("userId") },
    }, .{});
    return res.modified;
}

pub fn codSummary(a: Allocator, carrier_id: Val) !Val {
    const by_courier = try db.col("shipments").aggregate(a, .{
        .{ .@"$match" = .{ .carrierId = carrier_id, .@"cod.collectedAt" = .{ .@"$ne" = null }, .@"cod.settledAt" = null } },
        .{ .@"$group" = .{ ._id = "$cod.collectedBy", .amount = .{ .@"$sum" = "$cod.amount" }, .count = .{ .@"$sum" = 1 }, .ids = .{ .@"$push" = "$_id" } } },
    });
    const by_merchant = try db.col("shipments").aggregate(a, .{
        .{ .@"$match" = .{ .carrierId = carrier_id, .@"cod.settledAt" = .{ .@"$ne" = null }, .@"cod.remittedAt" = null } },
        .{ .@"$group" = .{ ._id = "$merchantId", .merchantName = .{ .@"$first" = "$merchantName" }, .amount = .{ .@"$sum" = "$cod.amount" }, .count = .{ .@"$sum" = 1 }, .ids = .{ .@"$push" = "$_id" } } },
    });
    const cids = try val.newArr(a);
    for (by_courier) |c| if (c.get("_id").truthy()) try cids.push(c.get("_id"));
    const couriers = try db.col("memberships").find(a, .{ ._id = .{ .@"$in" = cids } }, .{ .projection = try val.from(a, .{ .name = 1 }) });
    const to_settle = try val.newArr(a);
    for (by_courier) |c| {
        var name: Val = .{ .str = "—" };
        for (couriers) |x| if (x.get("_id").sameId(c.get("_id"))) {
            if (x.t("name")) name = x.get("name");
        };
        try to_settle.push(try val.spread(a, .{ c, .{ .courierName = name } }));
    }
    return val.from(a, .{ .toSettle = to_settle, .toRemit = by_merchant });
}
