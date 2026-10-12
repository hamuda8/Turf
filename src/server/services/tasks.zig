//! Courier tasks (src/services/tasks.js). A task moves one or more shipments between places:
//!
//!   pickup    merchant address -> hub         (one or more shipments, same merchant)
//!   direct    merchant address -> recipient   (one shipment)
//!   delivery  hub / courier    -> recipient   (one shipment)
//!   transfer  hub -> hub                      (line-haul)
//!   return    hub / courier    -> merchant    (on a relay: back to the handover hub)
//!   handover  merchant / hub   -> the next carrier's hub (relay shipments)
//!
//! Lifecycle: pending -> assigned -> accepted -> in_progress -> completed | failed (cancelled
//! before in_progress). Starting and finishing drives the shipments through applyEvent.

const std = @import("std");
const val = @import("../lib/val.zig");
const db = @import("../lib/db.zig");
const web = @import("../web.zig");
const a_ = @import("../app.zig");
const geo = @import("../geo.zig");
const crypto = @import("../crypto.zig");
const messages = @import("../messages.zig");
const bus = @import("../bus.zig");
const shipments_ = @import("shipments.zig");
const relay = @import("relay.zig");
const moderation = @import("moderation.zig");
const earnings = @import("earnings.zig");
const branding = @import("branding.zig");
const Val = val.Val;
const Req = web.Req;
const Allocator = std.mem.Allocator;

pub const task_types = [_][]const u8{ "pickup", "direct", "delivery", "transfer", "return", "handover" };
const max_code_failures = 5;

fn eq(x: []const u8, y: []const u8) bool {
    return std.mem.eql(u8, x, y);
}

// ---- Couriers ------------------------------------------------------------------------------------

fn courierRoleIds(a: Allocator, org_id: Val) !Val {
    const roles = try db.col("roles").find(a, .{ .orgId = org_id, .permissions = "courier.work" }, .{ .projection = try val.from(a, .{ ._id = 1 }) });
    const out = try val.newArr(a);
    for (roles) |r| try out.push(r.get("_id"));
    return out;
}

pub fn isCourier(a: Allocator, member: ?Val) !bool {
    const m = member orelse return false;
    if (!eq(m.s("status") orelse "", "active") or !m.t("courier")) return false;
    if (m.t("isOwner")) return true;
    if (!m.t("roleId")) return false;
    const role = (try db.col("roles").findOne(a, .{ ._id = m.get("roleId") }, .{})) orelse return false;
    return val.includesStr(role.get("permissions"), "courier.work");
}

pub fn listCouriers(a: Allocator, org_id: Val, on_duty_only: bool) ![]Val {
    const q = try val.from(a, .{
        .orgId = org_id,
        .status = "active",
        .courier = .{ .@"$ne" = null },
        .@"$or" = .{ .{ .isOwner = true }, .{ .roleId = .{ .@"$in" = try courierRoleIds(a, org_id) } } },
    });
    if (on_duty_only) try q.set("duty.onDuty", true);
    return db.col("memberships").find(a, q, .{});
}

fn vehicleOf(c: Val) ?*const geo.Vehicle {
    return geo.vehicle(c.path("courier.vehicle").asStr() orelse "");
}

fn capacityOf(c: Val) f64 {
    const own = c.path("courier.capacityKg");
    if (!own.isNullish()) return val.toNum(own);
    return if (vehicleOf(c)) |v| v.capacityKg else std.math.nan(f64);
}

fn rangeOf(c: Val) f64 {
    const own = c.path("courier.rangeKm");
    if (!own.isNullish()) return val.toNum(own);
    return if (vehicleOf(c)) |v| v.rangeKm else std.math.nan(f64);
}

/// Ranks on-duty couriers for a task. Couriers that can't do it are listed too, with the reason,
/// so dispatchers see why someone isn't suggested.
pub fn suggestCouriers(a: Allocator, carrier_id: Val, task: Val, list: []const Val) ![]Val {
    const couriers = try listCouriers(a, carrier_id, true);
    if (couriers.len == 0) return &.{};
    const ids = try val.newArr(a);
    for (couriers) |c| try ids.push(c.get("_id"));
    const open_counts = try db.col("tasks").aggregate(a, .{
        .{ .@"$match" = .{ .carrierId = carrier_id, .courierId = .{ .@"$in" = ids }, .status = .{ .@"$in" = .{ "assigned", "accepted", "in_progress" } } } },
        .{ .@"$group" = .{ ._id = "$courierId", .n = .{ .@"$sum" = 1 } } },
    });
    var heaviest = -std.math.inf(f64);
    var total: f64 = 0;
    for (list) |s| {
        const w = val.toNum(s.path("parcel.weightKg"));
        heaviest = val.jsMax(heaviest, w);
        total += w;
    }
    const from_loc = task.path("from.location");
    const to_loc = task.path("to.location");
    const task_km: ?f64 = if (from_loc.truthy() and to_loc.truthy()) geo.roadKm(geo.distanceKmV(from_loc, to_loc)) else null;
    const stale_before = a_.nowMs() - a_.cfg().stale_location_minutes * 60_000;

    var out: std.ArrayList(Val) = .empty;
    for (couriers) |c| {
        var open: f64 = 0;
        for (open_counts) |o| if (o.get("_id").sameId(c.get("_id"))) {
            open = val.or0(o.get("n"));
        };
        const to_start: ?f64 = if (c.get("lastLocation").truthy() and from_loc.truthy()) geo.roadKm(geo.distanceKmV(c.get("lastLocation"), from_loc)) else null;
        const last_at = c.get("lastLocationAt").dateMs();
        const stale = last_at == null or last_at.? < stale_before;
        var reason: Val = .null;
        if (val.jsMax(heaviest, total) > capacityOf(c)) {
            reason = .{ .str = "too_heavy_for_vehicle" };
        } else if (task_km != null and task_km.? + (to_start orelse 0) > rangeOf(c)) reason = .{ .str = "too_far_for_vehicle" };
        // Lower is better: km to reach the start, plus a penalty per open task and for an unknown position.
        const cost = (to_start orelse 25) + open * 4 + @as(f64, if (stale) 15 else 0);
        try out.append(a, try val.from(a, .{
            .courierId = c.get("_id"),
            .name = c.get("name"),
            .vehicle = c.path("courier.vehicle"),
            .openTasks = open,
            .distanceToStartKm = if (to_start) |d| Val{ .num = val.jsRound(d * 10) / 10 } else Val.null,
            .locationStale = stale,
            .eligible = reason == .null,
            .reason = reason,
            .cost = val.jsRound(cost * 10) / 10,
        }));
    }
    const Cmp = struct {
        fn lessThan(_: void, p: Val, q: Val) bool {
            const e = @as(f64, if (q.t("eligible")) 1 else 0) - @as(f64, if (p.t("eligible")) 1 else 0);
            if (e != 0) return e < 0;
            return val.toNum(p.get("cost")) - val.toNum(q.get("cost")) < 0;
        }
    };
    std.mem.sort(Val, out.items, {}, Cmp.lessThan);
    return out.items;
}

// ---- Creation ------------------------------------------------------------------------------------

fn hubPlace(a: Allocator, hub: Val) !Val {
    return val.from(a, .{ .kind = "hub", .hubId = hub.get("_id"), .label = try std.fmt.allocPrint(a, "{s} ({s})", .{ try val.toStr(a, hub.get("name")), try val.toStr(a, hub.get("code")) }), .location = hub.get("location") });
}

fn courierPlace(a: Allocator, courier: Val) !Val {
    return val.from(a, .{ .kind = "courier", .courierId = courier.get("_id"), .label = courier.get("name"), .location = if (courier.get("lastLocation").truthy()) courier.get("lastLocation") else Val.null });
}

fn addressPlace(a: Allocator, address: Val) !Val {
    var parts: std.ArrayList([]const u8) = .empty;
    for ([_][]const u8{ "name", "area", "city" }) |k| if (address.t(k)) try parts.append(a, try val.toStr(a, address.get(k)));
    return val.from(a, .{ .kind = "address", .label = try std.mem.join(a, " — ", parts.items), .location = try geo.approxPoint(a, address), .exact = address.get("location").truthy() });
}

fn loadShipments(r: *Req, carrier_id: Val, shipment_ids: []const Val) ![]Val {
    const a = r.a;
    const unique = try val.newArr(a);
    for (shipment_ids) |id| {
        var dup = false;
        for (unique.items()) |u| if (u.sameId(id)) {
            dup = true;
        };
        if (!dup) try unique.push(id);
    }
    const list = try db.col("shipments").find(a, .{ ._id = .{ .@"$in" = unique }, .carrierId = carrier_id }, .{});
    if (list.len != unique.items().len) return r.notFound("Shipment");
    if (try db.col("tasks").findOne(a, .{ .shipmentIds = .{ .@"$in" = unique }, .status = .{ .@"$in" = &shipments_.open_task_statuses } }, .{}) != null)
        return r.conflict("One of these shipments is already part of an open task", "already_on_task", null);
    return list;
}

fn requireStatuses(r: *Req, list: []const Val, allowed: []const []const u8, task_type: []const u8) !void {
    for (list) |s| {
        const st = s.s("status") orelse "";
        if (!val.contains([]const u8, allowed, st)) {
            const tn = try val.toStr(r.a, s.get("trackingNumber"));
            return r.conflict(try std.fmt.allocPrint(r.a, "{s} is \"{s}\" and cannot be added to a {s} task", .{ tn, st, task_type }), "cannot_add_to_task", .{ .tracking = tn, .status = st });
        }
    }
}

fn custodyKey(a: Allocator, s: Val) ![]const u8 {
    const c = s.get("custody");
    const id = if (c.get("hubId").truthy()) try val.toStr(a, c.get("hubId")) else if (c.get("courierId").truthy()) try val.toStr(a, c.get("courierId")) else "";
    return std.fmt.allocPrint(a, "{s}:{s}", .{ try val.toStr(a, c.get("type")), id });
}

fn sameCustody(r: *Req, list: []const Val) !Val {
    const first = try custodyKey(r.a, list[0]);
    for (list[1..]) |s| if (!eq(try custodyKey(r.a, s), first)) return r.conflict("All shipments in this task must be in the same place", "not_same_place", null);
    return list[0].get("custody");
}

fn allSame(a: Allocator, list: []const Val, key: []const u8) !bool {
    const first = try val.toStr(a, list[0].path(key));
    for (list[1..]) |s| if (!eq(try val.toStr(a, s.path(key)), first)) return false;
    return true;
}

fn custodyPlace(r: *Req, carrier_id: Val, custody: Val, shipment: Val) !Val {
    const a = r.a;
    const t = custody.s("type") orelse "";
    if (eq(t, "hub")) {
        var hub = try db.col("hubs").findOne(a, .{ ._id = custody.get("hubId"), .orgId = carrier_id }, .{});
        // A relay parcel handed back at another company's hub is collected from there.
        if (hub == null and shipment.truthy() and relay.isHandoffHubFor(shipment, carrier_id, custody.get("hubId")))
            hub = try db.col("hubs").findOne(a, .{ ._id = custody.get("hubId") }, .{});
        return hubPlace(a, hub orelse return r.notFound("Hub"));
    }
    if (eq(t, "courier")) {
        const courier = (try db.col("memberships").findOne(a, .{ ._id = custody.get("courierId") }, .{})) orelse return r.notFound("Courier");
        return courierPlace(a, courier);
    }
    return r.conflict("This shipment is not in the carrier's hands", "not_in_hands", null);
}

pub const Plan = struct { type: []const u8, from: Val, to: Val, shipments: []Val };

/// Validates a prospective task and works out where it starts and ends.
/// input: { type, shipmentIds, toHubId? }
pub fn planTask(r: *Req, carrier: Val, input: Val) !Plan {
    const a = r.a;
    const t = input.s("type") orelse "";
    const list = try loadShipments(r, carrier.get("_id"), input.get("shipmentIds").items());
    const single = eq(t, "direct") or eq(t, "delivery");
    if (single and list.len != 1) return r.badRequest(try std.fmt.allocPrint(a, "A {s} task carries exactly one shipment", .{t}), "shipmentIds", "one_shipment", null);
    // A carrier in the middle of a relay brings the parcel to the next company, never to the recipient.
    if (single) for (list) |s| if (relay.mustHandOver(s)) return r.conflict("This parcel continues with another shipping company: plan a handover instead", "plan_handover", null);
    if (eq(t, "handover")) for (list) |s| if (!relay.mustHandOver(s)) return r.conflict("Only parcels that continue with another shipping company can be handed over", "no_handover_needed", null);

    var from: Val = undefined;
    var to: Val = undefined;
    const to_hub_id = input.get("toHubId");
    if (eq(t, "handover")) {
        try requireStatuses(r, list, &.{ "awaiting_pickup", "at_hub" }, t);
        const first_hub = try val.toStr(a, relay.currentLeg(list[0]).path("to.hubId"));
        for (list) |s| if (!eq(try val.toStr(a, relay.currentLeg(s).path("to.hubId")), first_hub)) return r.conflict("These parcels go to different handover points", "different_handover_points", null);
        const all_waiting = for (list) |s| {
            if (!eq(s.s("status") orelse "", "awaiting_pickup")) break false;
        } else true;
        if (all_waiting) {
            if (!try allSame(a, list, "merchantId")) return r.conflict("A pickup run can only collect from one merchant", "one_merchant_pickup", null);
            from = try addressPlace(a, list[0].get("pickup"));
        } else from = try custodyPlace(r, carrier.get("_id"), try sameCustody(r, list), list[0]);
        to = try relay.handoffPlace(r, list[0]);
    } else if (eq(t, "pickup") or eq(t, "direct")) {
        try requireStatuses(r, list, &.{"awaiting_pickup"}, t);
        if (!try allSame(a, list, "merchantId")) return r.conflict("A pickup run can only collect from one merchant", "one_merchant_pickup", null);
        from = try addressPlace(a, list[0].get("pickup"));
        if (eq(t, "direct")) {
            to = try addressPlace(a, list[0].get("dropoff"));
        } else {
            if (!to_hub_id.truthy()) return r.badRequest("toHubId is required for pickup tasks", "toHubId", "required", null);
            const hub = (try db.col("hubs").findOne(a, .{ ._id = to_hub_id, .orgId = carrier.get("_id"), .active = true }, .{})) orelse return r.notFound("Hub");
            to = try hubPlace(a, hub);
        }
    } else if (eq(t, "delivery")) {
        try requireStatuses(r, list, &.{ "at_hub", "delivery_failed" }, t);
        from = try custodyPlace(r, carrier.get("_id"), list[0].get("custody"), list[0]);
        to = try addressPlace(a, list[0].get("dropoff"));
    } else if (eq(t, "transfer")) {
        try requireStatuses(r, list, &.{"at_hub"}, t);
        const custody = try sameCustody(r, list);
        from = try custodyPlace(r, carrier.get("_id"), custody, list[0]);
        if (!to_hub_id.truthy()) return r.badRequest("toHubId is required for transfer tasks", "toHubId", "required", null);
        if (custody.get("hubId").truthy() and custody.get("hubId").sameId(to_hub_id)) return r.badRequest("The destination hub must be different", "toHubId", "hub_same", null);
        const hub = (try db.col("hubs").findOne(a, .{ ._id = to_hub_id, .orgId = carrier.get("_id"), .active = true }, .{})) orelse return r.notFound("Hub");
        to = try hubPlace(a, hub);
    } else if (eq(t, "return")) {
        try requireStatuses(r, list, &.{ "at_hub", "delivery_failed", "returning" }, t);
        if (!try allSame(a, list, "merchantId")) return r.conflict("A return run can only go to one merchant", "one_merchant_return", null);
        from = try custodyPlace(r, carrier.get("_id"), try sameCustody(r, list), list[0]);
        // Later carriers on a relay bring returns back to the handover hub; the first returns to the sender.
        var back: usize = 0;
        for (list) |s| if (relay.previousLeg(s).truthy()) {
            back += 1;
        };
        if (back > 0 and back != list.len) return r.conflict("These returns go to different places", "different_return_places", null);
        to = if (back > 0) try relay.handbackPlace(r, list[0]) else try addressPlace(a, list[0].get("pickup"));
    } else {
        return r.badRequest(try std.fmt.allocPrint(a, "type must be one of: {s}", .{try std.mem.join(a, ", ", &task_types)}), "type", null, null);
    }
    return .{ .type = t, .from = from, .to = to, .shipments = list };
}

/// Builds and inserts a task. input: { type, shipmentIds, toHubId?, courierId? }
pub fn createTask(r: *Req, carrier: Val, input: Val, actor: Val) !Val {
    const a = r.a;
    const plan = try planTask(r, carrier, input);
    if (input.get("courierId").truthy()) {
        // Checked before inserting, so a bad courier doesn't leave an orphan task holding the parcels.
        const courier = try db.col("memberships").findOne(a, .{ ._id = input.get("courierId"), .orgId = carrier.get("_id") }, .{});
        if (!try isCourier(a, courier)) return r.badRequest("This member is not an active courier", "courierId", "not_courier", null);
    }
    const now = a_.now();
    const ids = try val.newArr(a);
    for (plan.shipments) |s| try ids.push(s.get("_id"));
    const task = try val.from(a, .{
        .carrierId = carrier.get("_id"),
        .type = plan.type,
        .status = "pending",
        .courierId = null,
        .shipmentIds = ids,
        .from = plan.from,
        .to = plan.to,
        .auto = eq(actor.s("type") orelse "", "system"),
        .createdBy = actor,
    });
    // Express parcels: the task is urgent until the promised time.
    for (plan.shipments) |s| if (eq(s.s("service") orelse "", "express")) {
        try task.set("express", true);
        try task.set("dueBy", s.get("promisedBy"));
        break;
    };
    try task.set("createdAt", now);
    try task.set("updatedAt", now);
    _ = try db.col("tasks").insertOne(a, task);
    // Claim the shipments; if another task claimed one in the meantime, roll back.
    const claim = try db.col("shipments").updateMany(a, .{ ._id = .{ .@"$in" = ids }, .currentTaskId = null }, .{ .@"$set" = .{ .currentTaskId = task.get("_id"), .updatedAt = now } }, .{});
    if (claim.modified != ids.items().len) {
        _ = try db.col("shipments").updateMany(a, .{ .currentTaskId = task.get("_id") }, .{ .@"$set" = .{ .currentTaskId = null } }, .{});
        _ = try db.col("tasks").deleteOne(a, .{ ._id = task.get("_id") });
        return r.conflict("One of these shipments was just added to another task", "already_on_task", null);
    }
    if (input.get("courierId").truthy()) return assignTask(r, carrier, task, input.get("courierId"), actor);
    bus.emit(r, "task.changed", .{ .taskId = task.get("_id"), .carrierId = carrier.get("_id"), .courierId = null });
    return task;
}

pub fn getTask(r: *Req, carrier_id: Val, task_id: Val) !Val {
    return (try db.col("tasks").findOne(r.a, .{ ._id = task_id, .carrierId = carrier_id }, .{})) orelse r.notFound("Task");
}

// ---- Dispatcher actions --------------------------------------------------------------------------

pub fn assignTask(r: *Req, carrier: Val, task: Val, courier_id: Val, actor: Val) !Val {
    const a = r.a;
    const st = task.s("status") orelse "";
    if (!val.contains([]const u8, &.{ "pending", "assigned", "accepted" }, st)) {
        // In-progress tasks can be handed to another courier too (a breakdown, say).
        if (!eq(st, "in_progress")) return r.conflict(try std.fmt.allocPrint(a, "A {s} task cannot be reassigned", .{st}), "task_wrong_state", null);
    }
    const courier = try db.col("memberships").findOne(a, .{ ._id = courier_id, .orgId = carrier.get("_id") }, .{});
    if (!try isCourier(a, courier)) return r.badRequest("This member is not an active courier", "courierId", "not_courier", null);
    const c = courier.?;
    const now = a_.now();
    const handover = eq(st, "in_progress");
    const set = try val.from(a, .{ .courierId = c.get("_id"), .assignedAt = now, .updatedAt = now });
    if (!handover) try set.set("status", "assigned");
    const update = try val.from(a, .{ .@"$set" = set });
    if (handover) try update.set("$push", .{ .handovers = .{ .from = task.get("courierId"), .to = c.get("_id"), .at = now, .by = actor } });
    const updated = (try db.col("tasks").findOneAndUpdate(a, .{ ._id = task.get("_id"), .status = st }, update, .{ .returnDocument = .after })) orelse
        return r.conflict("The task changed at the same time. Please refresh.", "changed_meanwhile", null);
    if (handover) _ = try db.col("shipments").updateMany(a, .{ ._id = .{ .@"$in" = task.get("shipmentIds") }, .@"custody.type" = "courier" }, .{ .@"$set" = .{ .@"custody.courierId" = c.get("_id") } }, .{});
    bus.emit(r, "task.changed", .{ .taskId = task.get("_id"), .carrierId = carrier.get("_id"), .courierId = c.get("_id"), .previousCourierId = task.get("courierId") });
    return updated;
}

pub fn cancelTask(r: *Req, carrier: Val, task: Val, actor: Val) !Val {
    const a = r.a;
    const st = task.s("status") orelse "";
    if (!val.contains([]const u8, &.{ "pending", "assigned", "accepted" }, st))
        return r.conflict("Only tasks that have not started can be cancelled. Reassign started tasks instead.", "task_started", null);
    const now = a_.now();
    const updated = (try db.col("tasks").findOneAndUpdate(a, .{ ._id = task.get("_id"), .status = st }, .{ .@"$set" = .{ .status = "cancelled", .cancelledAt = now, .cancelledBy = actor, .updatedAt = now } }, .{ .returnDocument = .after })) orelse
        return r.conflict("The task changed at the same time. Please refresh.", "changed_meanwhile", null);
    _ = try db.col("shipments").updateMany(a, .{ .currentTaskId = task.get("_id") }, .{ .@"$set" = .{ .currentTaskId = null, .updatedAt = now } }, .{});
    bus.emit(r, "task.changed", .{ .taskId = task.get("_id"), .carrierId = carrier.get("_id"), .courierId = task.get("courierId") });
    return updated;
}

// ---- Courier actions -----------------------------------------------------------------------------

fn assertMine(r: *Req, task: Val, courier: Val) !void {
    if (!task.get("courierId").truthy() or !task.get("courierId").sameId(courier.get("_id"))) return r.forbidden("This task is not assigned to you");
}

fn setTask(r: *Req, task: Val, from_status: []const u8, set: Val) !Val {
    const s = try val.spread(r.a, .{ set, .{ .updatedAt = a_.now() } });
    return (try db.col("tasks").findOneAndUpdate(r.a, .{ ._id = task.get("_id"), .status = from_status }, .{ .@"$set" = s }, .{ .returnDocument = .after })) orelse
        r.conflict("The task changed at the same time. Please refresh.", "changed_meanwhile", null);
}

fn courierActor(a: Allocator, courier: Val) !Val {
    return val.from(a, .{ .type = "courier", .id = courier.get("_id"), .name = courier.get("name") });
}

pub fn acceptTask(r: *Req, task: Val, courier: Val) !Val {
    const a = r.a;
    try assertMine(r, task, courier);
    const st = task.s("status") orelse "";
    if (!eq(st, "assigned")) return r.conflict(try std.fmt.allocPrint(a, "Cannot accept a {s} task", .{st}), "task_wrong_state", null);
    const updated = try setTask(r, task, "assigned", try val.from(a, .{ .status = "accepted", .acceptedAt = a_.now() }));
    const t = task.s("type") orelse "";
    if (eq(t, "pickup") or eq(t, "direct")) {
        const list = try db.col("shipments").find(a, .{ ._id = .{ .@"$in" = task.get("shipmentIds") } }, .{});
        for (list) |s| {
            const saved = r.err;
            _ = shipments_.applyEvent(r, s, "pickup_assigned", .{ .actor = try courierActor(a, courier), .params = try val.from(a, .{ .courier = courier.get("name") }) }) catch {};
            r.err = saved;
        }
    }
    bus.emit(r, "task.changed", .{ .taskId = task.get("_id"), .carrierId = task.get("carrierId"), .courierId = courier.get("_id") });
    return updated;
}

pub fn declineTask(r: *Req, task: Val, courier: Val, reason: ?[]const u8) !Val {
    const a = r.a;
    try assertMine(r, task, courier);
    const st = task.s("status") orelse "";
    if (!eq(st, "assigned") and !eq(st, "accepted")) return r.conflict(try std.fmt.allocPrint(a, "Cannot decline a {s} task", .{st}), "task_wrong_state", null);
    const updated = try setTask(r, task, st, try val.from(a, .{
        .status = "pending",
        .courierId = null,
        .lastDeclined = .{ .courierId = courier.get("_id"), .reason = if (reason) |x| (if (x.len > 0) Val{ .str = x } else Val.null) else Val.null, .at = a_.now() },
    }));
    bus.emit(r, "task.changed", .{ .taskId = task.get("_id"), .carrierId = task.get("carrierId"), .courierId = courier.get("_id"), .declined = true });
    return updated;
}

fn firstName(name: Val) []const u8 {
    var it = std.mem.tokenizeAny(u8, val.jsTrim(name.asStr() orelse ""), " \t\r\n");
    return it.next() orelse "";
}

/// The courier starts the task. For pickups, `missing` parcels (not ready) are dropped from the run.
pub fn startTask(r: *Req, task: Val, courier: Val, location: Val, missing_ids: []const Val) !Val {
    const a = r.a;
    try assertMine(r, task, courier);
    const st = task.s("status") orelse "";
    if (!eq(st, "accepted")) {
        if (eq(st, "assigned")) return r.conflict("Accept the task first", "accept_first", null);
        return r.conflict(try std.fmt.allocPrint(a, "Cannot start a {s} task", .{st}), "task_wrong_state", null);
    }
    const t = task.s("type") orelse "";
    if (missing_ids.len > 0 and !eq(t, "pickup")) return r.badRequest("Only pickup runs can leave parcels behind", "missingShipmentIds", null, null);
    var missing: std.ArrayList([]const u8) = .empty;
    for (missing_ids) |m| try missing.append(a, try val.toStr(a, m));
    const keep = try val.newArr(a);
    const dropped = try val.newArr(a);
    for (task.get("shipmentIds").items()) |id| {
        if (val.contains([]const u8, missing.items, try val.toStr(a, id))) try dropped.push(id) else try keep.push(id);
    }
    if (keep.items().len == 0) return r.badRequest("Nothing left to pick up. Report the pickup as failed instead.", "missingShipmentIds", "nothing_left", null);

    // Every parcel is validated before the task changes state, so a refusal leaves nothing half-done.
    const list = try db.col("shipments").find(a, .{ ._id = .{ .@"$in" = keep } }, .{});
    const first_step: []const u8 = if (eq(t, "pickup") or eq(t, "direct")) "picked_up" else if (eq(t, "delivery")) "out_for_delivery" else if (eq(t, "transfer")) "departed_hub" else "";
    for (list) |s| {
        const sst = s.s("status") orelse "";
        const ok = if (!s.get("currentTaskId").truthy() or !s.get("currentTaskId").sameId(task.get("_id")))
            false
        else if (eq(t, "return"))
            eq(sst, "returning") or shipments_.canApply("return_started", sst)
        else if (eq(t, "handover"))
            shipments_.canApply(if (eq(sst, "awaiting_pickup")) "picked_up" else "departed_hub", sst)
        else
            shipments_.canApply(first_step, sst);
        if (!ok) {
            const tn = try val.toStr(a, s.get("trackingNumber"));
            return r.conflict(try std.fmt.allocPrint(a, "{s} is \"{s}\" and can no longer go on this task. Ask your dispatcher.", .{ tn, sst }), "parcel_cannot_go", .{ .tracking = tn, .status = sst });
        }
    }
    if (list.len != keep.items().len) return r.conflict("Some parcels were removed from this task. Refresh and try again.", "task_parcels_changed", null);

    // Compare-and-set on the parcel list so a concurrent removal isn't overwritten.
    const updated = (try db.col("tasks").findOneAndUpdate(a, .{ ._id = task.get("_id"), .status = "accepted", .shipmentIds = task.get("shipmentIds") }, .{
        .@"$set" = .{ .status = "in_progress", .startedAt = a_.now(), .shipmentIds = keep, .startLocation = if (location.truthy()) location else Val.null, .updatedAt = a_.now() },
    }, .{ .returnDocument = .after })) orelse return r.conflict("The task changed at the same time. Please refresh.", "changed_meanwhile", null);
    if (dropped.items().len > 0) _ = try db.col("shipments").updateMany(a, .{ ._id = .{ .@"$in" = dropped }, .currentTaskId = task.get("_id") }, .{ .@"$set" = .{ .currentTaskId = null, .updatedAt = a_.now() } }, .{});

    const actor = try courierActor(a, courier);
    const custody = try val.from(a, .{ .type = "courier", .courierId = courier.get("_id") });
    const from_hub: Val = if (eq(task.path("from.kind").asStr() orelse "", "hub")) ((try db.col("hubs").findOne(a, .{ ._id = task.path("from.hubId") }, .{})) orelse .null) else .null;
    const vehicle_params = try val.from(a, .{ .courier = firstName(courier.get("name")), .vehicle = courier.path("courier.vehicle") });
    const set_custody = try val.from(a, .{ .custody = custody });
    for (list) |s0| {
        const sst = s0.s("status") orelse "";
        if (eq(t, "pickup")) {
            _ = try shipments_.applyEvent(r, s0, "picked_up", .{ .actor = actor, .location = location, .set = set_custody });
        } else if (eq(t, "direct")) {
            const s1 = try shipments_.applyEvent(r, s0, "picked_up", .{ .actor = actor, .location = location, .set = set_custody });
            _ = try shipments_.applyEvent(r, s1, "out_for_delivery", .{ .actor = actor, .location = location, .params = vehicle_params });
        } else if (eq(t, "delivery")) {
            _ = try shipments_.applyEvent(r, s0, "out_for_delivery", .{ .actor = actor, .location = location, .params = vehicle_params, .set = set_custody });
        } else if (eq(t, "transfer")) {
            _ = try shipments_.applyEvent(r, s0, "departed_hub", .{ .actor = actor, .location = location, .hub = from_hub, .set = set_custody });
        } else if (eq(t, "handover")) {
            if (eq(sst, "awaiting_pickup")) {
                _ = try shipments_.applyEvent(r, s0, "picked_up", .{ .actor = actor, .location = location, .set = set_custody });
            } else _ = try shipments_.applyEvent(r, s0, "departed_hub", .{ .actor = actor, .location = location, .hub = from_hub, .set = set_custody });
        } else if (eq(t, "return")) {
            if (eq(sst, "returning")) {
                _ = try db.col("shipments").updateOne(a, .{ ._id = s0.get("_id") }, .{ .@"$set" = .{ .custody = custody } }, .{});
            } else _ = try shipments_.applyEvent(r, s0, "return_started", .{ .actor = actor, .location = location, .set = try val.from(a, .{ .custody = custody, .returnRequired = true }) });
        }
    }
    bus.emit(r, "task.changed", .{ .taskId = task.get("_id"), .carrierId = task.get("carrierId"), .courierId = courier.get("_id") });
    return updated;
}

pub fn decodeJpeg(r: *Req, data_url: Val) ![]const u8 {
    const prefix = "data:image/jpeg;base64,";
    const s = data_url.asStr() orelse "";
    if (!std.mem.startsWith(u8, s, prefix)) return r.badRequest("photo must be a JPEG data URL", "photo", "photo_invalid", null);
    const buf = branding.base64Loose(r.a, s[prefix.len..]) catch return r.badRequest("photo is not a valid JPEG", "photo", "photo_invalid", null);
    if (buf.len < 3 or buf[0] != 0xff or buf[1] != 0xd8 or buf[2] != 0xff) return r.badRequest("photo is not a valid JPEG", "photo", "photo_invalid", null);
    if (buf.len > 400_000) return r.badRequest("photo is too large", "photo", "file_too_large", null);
    return buf;
}

/// The courier finishes the task. For deliveries: pod = { code?, receiverName?, photo?, codCollected? }.
pub fn completeTask(r: *Req, task: Val, courier: Val, location: Val, pod: Val, client_at: Val) !Val {
    const a = r.a;
    try assertMine(r, task, courier);
    const st = task.s("status") orelse "";
    if (!eq(st, "in_progress")) return r.conflict(try std.fmt.allocPrint(a, "Cannot complete a {s} task", .{st}), "task_wrong_state", null);
    const actor = try courierActor(a, courier);
    const now = a_.now();
    const list = try db.col("shipments").find(a, .{ ._id = .{ .@"$in" = task.get("shipmentIds") } }, .{});
    const t = task.s("type") orelse "";
    const loc: Val = if (location.truthy()) location else .null;

    if (eq(t, "delivery") or eq(t, "direct")) {
        const s = list[0];
        if (s.t("requireCode")) {
            // Reserve an attempt atomically first, so parallel requests can't each pass the limit.
            const reserved = try db.col("shipments").findOneAndUpdate(a, .{ ._id = s.get("_id"), .codeFailures = .{ .@"$not" = .{ .@"$gte" = max_code_failures } } }, .{ .@"$inc" = .{ .codeFailures = 1 } }, .{});
            if (reserved == null) return r.conflict("Too many wrong codes. Ask your dispatcher to confirm this delivery.", "too_many_wrong_codes", null);
            const code = pod.get("code");
            if (!code.truthy() or !crypto.safeEqual(val.jsTrim(try val.toStr(a, code)), s.s("deliveryCode") orelse ""))
                return r.badRequest("The delivery code is not correct", "code", "wrong_code", null);
            // Correct code: the attempt is given back.
            _ = try db.col("shipments").updateOne(a, .{ ._id = s.get("_id") }, .{ .@"$inc" = .{ .codeFailures = -1 } }, .{});
        }
        if (s.t("cod") and !(pod.get("codCollected") == .bool and pod.get("codCollected").bool)) return r.badRequest("Confirm that you collected the cash amount", "codCollected", "confirm_cash", null);

        var photo_id: Val = .null;
        if (pod.t("photo")) {
            const buf = try decodeJpeg(r, pod.get("photo"));
            // The store and the carrier see the proof photo.
            _ = try moderation.check(r, try val.from(a, .{ .userId = courier.get("userId"), .name = if (courier.t("name")) courier.get("name") else Val.null }), .{ .type = "shipment", .id = try val.toStr(a, s.get("_id")), .field = "pod-photo" }, .undef, &.{.{ .id = "photo", .bytes = buf }});
            photo_id = try db.col("pod_photos").insertOne(a, .{ .shipmentId = s.get("_id"), .data = Val{ .bin = buf }, .contentType = "image/jpeg", .at = now });
        }
        const receiver: Val = if (pod.get("receiverName").asStr()) |n| (if (val.jsSlice(val.jsTrim(n), 120).len > 0) Val{ .str = val.jsSlice(val.jsTrim(n), 120) } else .null) else .null;
        const set = try val.from(a, .{
            .custody = .{ .type = "recipient" },
            .currentTaskId = null,
            .pod = .{
                .method = if (s.t("requireCode")) "code" else if (photo_id.truthy()) "photo" else "courier_confirmation",
                .receiverName = receiver,
                .photoId = photo_id,
                .at = now,
                // Done without a connection and sent later: when it really happened.
                .recordedAt = if (client_at.truthy()) client_at else Val.null,
                .location = loc,
                .courierId = courier.get("_id"),
            },
        });
        if (s.t("cod")) {
            try set.set("cod.collectedAt", now);
            try set.set("cod.collectedBy", courier.get("_id"));
        }
        _ = try shipments_.applyEvent(r, s, "delivered", .{ .actor = actor, .location = location, .set = set });
    } else if (eq(t, "pickup") or eq(t, "transfer")) {
        const hub = (try db.col("hubs").findOne(a, .{ ._id = task.path("to.hubId") }, .{})) orelse Val.null;
        for (list) |s| _ = try shipments_.applyEvent(r, s, "arrived_at_hub", .{ .actor = actor, .hub = hub, .set = try val.from(a, .{ .custody = .{ .type = "hub", .hubId = hub.get("_id") }, .currentTaskId = null }) });
    } else if (eq(t, "handover")) {
        const hub = (try db.col("hubs").findOne(a, .{ ._id = task.path("to.hubId") }, .{})) orelse Val.null;
        for (list) |s| _ = try handOver(r, s, hub, actor, pod.get("receiverName"));
    } else if (eq(t, "return") and eq(task.path("to.kind").asStr() orelse "", "hub")) {
        const hub = (try db.col("hubs").findOne(a, .{ ._id = task.path("to.hubId") }, .{})) orelse Val.null;
        for (list) |s| _ = try handBack(r, s, hub, actor);
    } else if (eq(t, "return")) {
        for (list) |s| _ = try shipments_.applyEvent(r, s, "returned", .{ .actor = actor, .location = location, .set = try val.from(a, .{ .custody = .{ .type = "merchant" }, .currentTaskId = null }) });
    }

    const payer = (try db.col("orgs").findOne(a, .{ ._id = task.get("carrierId") }, .{ .projection = try val.from(a, .{ .carrier = 1 }) })) orelse Val.null;
    const updated = try setTask(r, task, "in_progress", try val.from(a, .{ .status = "completed", .completedAt = now, .recordedAt = if (client_at.truthy()) client_at else Val.null, .endLocation = loc, .pay = try earnings.payFor(a, payer, task, "completed") }));
    bus.emit(r, "task.changed", .{ .taskId = task.get("_id"), .carrierId = task.get("carrierId"), .courierId = courier.get("_id"), .completed = true });
    return updated;
}

/// The courier reports that the task could not be done.
pub fn failTask(r: *Req, task: Val, courier: Val, carrier: Val, reason: Val, note: Val, location: Val, reschedule_for: Val, client_at: Val) !Val {
    const a = r.a;
    try assertMine(r, task, courier);
    const reason_s = reason.asStr() orelse "";
    if (messages.find(&messages.failure_reasons, reason_s) == null)
        return r.badRequest(try std.fmt.allocPrint(a, "reason must be one of: {s}", .{try std.mem.join(a, ", ", messages.failure_reason_codes)}), "reason", null, null);
    const actor = try courierActor(a, courier);
    const now = a_.now();
    const t = task.s("type") orelse "";
    const st = task.s("status") orelse "";
    const note_v: Val = if (note.truthy()) note else .null;

    if (eq(t, "delivery") or eq(t, "direct")) {
        if (!eq(st, "in_progress")) return r.conflict("Start the delivery before reporting a failed attempt", "start_first", null);
        var s = (try db.col("shipments").findOne(a, .{ ._id = task.get("shipmentIds").at(0) }, .{})) orelse Val.null;
        s = try shipments_.applyEvent(r, s, "delivery_failed", .{
            .actor = actor,
            .location = location,
            .note = note,
            .params = try val.from(a, .{ .reason = reason_s }),
            .set = try val.from(a, .{ .currentTaskId = null, .lastFailure = .{ .reason = reason_s, .note = note_v, .at = now } }),
            .inc = try val.from(a, .{ .attempts = 1 }),
        });
        // The recipient asked for another day: keep the parcel for that day (not counted towards returns).
        if (reschedule_for.truthy()) {
            s = try shipments_.reschedule(r, s, reschedule_for, actor);
        } else {
            const max_attempts = val.or0(carrier.path("carrier.maxAttempts"));
            if (val.toNum(s.get("attempts")) >= (if (max_attempts == 0) 3 else max_attempts))
                _ = try shipments_.applyEvent(r, s, "return_started", .{ .actor = try val.from(a, .{ .type = "system" }), .set = try val.from(a, .{ .returnRequired = true }) });
        }
    } else if (eq(t, "pickup")) {
        if (!eq(st, "accepted") and !eq(st, "in_progress")) return r.conflict(try std.fmt.allocPrint(a, "Cannot fail a {s} task", .{st}), "task_wrong_state", null);
        if (eq(st, "in_progress")) return r.conflict("Parcels are already picked up. Complete the task at the hub instead.", "already_picked_up", null);
        _ = try db.col("shipments").updateMany(a, .{ .currentTaskId = task.get("_id") }, .{ .@"$set" = .{ .currentTaskId = null, .updatedAt = now } }, .{});
    } else {
        return r.conflict("Transfers and returns cannot be failed. Contact your dispatcher to reassign the task.", "cannot_fail_transfer", null);
    }

    const updated = try setTask(r, task, st, try val.from(a, .{
        .status = "failed",
        .failedAt = now,
        .recordedAt = if (client_at.truthy()) client_at else Val.null,
        .failure = .{ .reason = reason_s, .note = note_v },
        .endLocation = if (location.truthy()) location else Val.null,
        .pay = try earnings.payFor(a, carrier, task, "failed"),
    }));
    bus.emit(r, "task.changed", .{ .taskId = task.get("_id"), .carrierId = task.get("carrierId"), .courierId = courier.get("_id"), .failed = true });
    return updated;
}

// ---- Views ---------------------------------------------------------------------------------------

/// The task as its courier sees it: recipient contact to call, never the delivery code.
pub fn taskViewForCourier(a: Allocator, task: Val) !Val {
    const list = try db.col("shipments").find(a, .{ ._id = .{ .@"$in" = task.get("shipmentIds") } }, .{ .projection = try val.from(a, .{ .deliveryCode = 0, .publicToken = 0, .labelToken = 0, .allocation = 0, .price = 0 }) });
    return val.spread(a, .{ task, .{ .shipments = list } });
}

// ---- Relay handovers -----------------------------------------------------------------------------

/// The parcel reaches the next carrier's hub: from now on it is that carrier's shipment.
pub fn handOver(r: *Req, shipment: Val, hub: Val, actor: Val, receiver_name: Val) !Val {
    const a = r.a;
    const li: usize = @intFromFloat(shipment.n("legIndex") orelse 0);
    const next = shipment.get("legs").at(li + 1);
    const name = if (receiver_name.asStr()) |n| val.jsSlice(val.jsTrim(n), 120) else "";
    return shipments_.applyEvent(r, shipment, "handed_over", .{
        .actor = actor,
        .hub = hub,
        .params = try val.from(a, .{ .from = shipment.get("carrierName"), .to = next.get("carrierName") }),
        .note = if (name.len > 0) Val{ .str = try std.fmt.allocPrint(a, "Received by {s}", .{name}) } else .undef,
        .set = try relay.handOverSet(a, shipment, hub),
    });
}

/// A returning relay parcel is back at the handover hub: the previous carrier takes it home.
pub fn handBack(r: *Req, shipment: Val, hub: Val, actor: Val) !Val {
    const a = r.a;
    const li: usize = @intFromFloat(shipment.n("legIndex") orelse 0);
    const prev = shipment.get("legs").at(li - 1);
    return shipments_.applyEvent(r, shipment, "handed_back", .{
        .actor = actor,
        .hub = hub,
        .params = try val.from(a, .{ .from = shipment.get("carrierName"), .to = prev.get("carrierName") }),
        .set = try val.spread(a, .{ try relay.handBackSet(a, shipment, hub), .{ .returnRequired = true } }),
    });
}
