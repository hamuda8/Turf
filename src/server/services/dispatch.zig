//! Automatic dispatch and the safety watchdog (src/services/dispatch.js).
//!
//! Auto-dispatch (carrier.autoDispatch): a new shipment gets a pickup run to the nearest hub (or
//! a direct delivery); a parcel reaching a hub in the recipient's governorate gets its last-mile
//! delivery; each task goes to the best eligible on-duty courier, or waits and is retried every
//! minute. Express orders are planned this way for every carrier offering express.
//!
//! Watchdog (every minute): signal-lost, tracking-paused and long-stop alerts.

const std = @import("std");
const val = @import("../lib/val.zig");
const db = @import("../lib/db.zig");
const web = @import("../web.zig");
const a_ = @import("../app.zig");
const geo = @import("../geo.zig");
const bus = @import("../bus.zig");
const tasks = @import("tasks.zig");
const tracking = @import("tracking.zig");
const relay = @import("relay.zig");
const shipments_ = @import("shipments.zig");
const Val = val.Val;
const Req = web.Req;
const Allocator = std.mem.Allocator;

fn system(a: Allocator) !Val {
    return val.from(a, .{ .type = "system" });
}

fn eq(x: []const u8, y: []const u8) bool {
    return std.mem.eql(u8, x, y);
}

fn nearestHub(a: Allocator, carrier_id: Val, point: Val) !?Val {
    if (!point.truthy()) return null;
    const hubs = try db.col("hubs").find(a, .{ .orgId = carrier_id, .active = true }, .{});
    if (hubs.len == 0) return null;
    var best = hubs[0];
    for (hubs[1..]) |h| {
        if (geo.distanceKmV(h.get("location"), point) < geo.distanceKmV(best.get("location"), point)) best = h;
    }
    return best;
}

fn assignBest(r: *Req, carrier: Val, task: Val) !void {
    const a = r.a;
    const list = try db.col("shipments").find(a, .{ ._id = .{ .@"$in" = task.get("shipmentIds") } }, .{});
    if (list.len == 0) return;
    const suggestions = try tasks.suggestCouriers(a, carrier.get("_id"), task, list);
    for (suggestions) |s| if (s.t("eligible")) {
        _ = try tasks.assignTask(r, carrier, task, s.get("courierId"), try system(a));
        return;
    };
}

/// shipment.created
pub fn autoPlanNewShipment(r: *Req, e: Val) !void {
    const a = r.a;
    const shipment = e.get("shipment");
    const carrier = e.get("carrier");
    if (shipment.t("test") or !carrier.truthy()) return;
    if (eq(shipment.s("service") orelse "", "express")) {
        const task = try tasks.createTask(r, carrier, try val.from(a, .{ .type = "direct", .shipmentIds = .{shipment.get("_id")} }), try system(a));
        try assignBest(r, carrier, task);
        return;
    }
    if (!carrier.path("carrier.autoDispatch").truthy()) return;
    const hub = try nearestHub(a, carrier.get("_id"), try geo.approxPoint(a, shipment.get("pickup")));
    // The first company of a relay without a hub takes the parcel straight to the next company.
    if (relay.mustHandOver(shipment) and hub == null) {
        const handover = try tasks.createTask(r, carrier, try val.from(a, .{ .type = "handover", .shipmentIds = .{shipment.get("_id")} }), try system(a));
        try assignBest(r, carrier, handover);
        return;
    }
    const local = eq(shipment.s("zone") orelse "", "local");
    const go_direct = hub == null or (carrier.path("carrier.directLocal").truthy() and local);
    // Long distance without hubs: a dispatcher plans it.
    if (hub == null and !local) return;
    const input = if (go_direct)
        try val.from(a, .{ .type = "direct", .shipmentIds = .{shipment.get("_id")} })
    else
        try val.from(a, .{ .type = "pickup", .shipmentIds = .{shipment.get("_id")}, .toHubId = hub.?.get("_id") });
    const task = try tasks.createTask(r, carrier, input, try system(a));
    try assignBest(r, carrier, task);
}

/// shipment.event: a parcel reached a hub; plan its next step for auto-dispatch carriers.
pub fn autoPlanFromHub(r: *Req, e: Val) !void {
    const a = r.a;
    const shipment = e.get("shipment");
    const event = e.get("event");
    const code = event.s("code") orelse "";
    if (!(eq(code, "arrived_at_hub") or eq(code, "handed_over")) or shipment.t("returnRequired")) return;
    // Rescheduled for a later day: planned on that day by planScheduledDeliveries.
    if (shipment.s("scheduledFor")) |day| if (day.len > 0 and std.mem.order(u8, day, try shipments_.localToday(a)) == .gt) return;
    const carrier = (try db.col("orgs").findOne(a, .{ ._id = shipment.get("carrierId") }, .{})) orelse return;
    if (!carrier.path("carrier.autoDispatch").truthy()) return;
    const hub = (try db.col("hubs").findOne(a, .{ ._id = event.get("hubId") }, .{})) orelse return;
    var input: Val = undefined;
    if (relay.mustHandOver(shipment)) {
        input = try val.from(a, .{ .type = "handover", .shipmentIds = .{shipment.get("_id")} });
    } else if (hub.get("governorate").eql(shipment.path("dropoff.governorate"))) {
        input = try val.from(a, .{ .type = "delivery", .shipmentIds = .{shipment.get("_id")} });
    } else {
        // No hub there: a dispatcher plans the long-distance leg.
        const target = (try db.col("hubs").findOne(a, .{ .orgId = carrier.get("_id"), .active = true, .governorate = shipment.path("dropoff.governorate") }, .{})) orelse return;
        input = try val.from(a, .{ .type = "transfer", .shipmentIds = .{shipment.get("_id")}, .toHubId = target.get("_id") });
    }
    const task = tasks.createTask(r, carrier, input, try system(a)) catch |err| {
        // Someone already planned it (or is detaching an old plan).
        if (err == error.Http and r.err != null and r.err.?.status == 409) return;
        return err;
    };
    try assignBest(r, carrier, task);
}

/// Auto-dispatch carriers: parcels whose rescheduled day has come get their delivery planned.
pub fn planScheduledDeliveries(r: *Req) !void {
    const a = r.a;
    const due = try db.col("shipments").find(a, .{
        .scheduledFor = .{ .@"$lte" = try shipments_.localToday(a) },
        .status = .{ .@"$in" = .{ "at_hub", "delivery_failed" } },
        .currentTaskId = null,
        .returnRequired = .{ .@"$ne" = true },
    }, .{ .limit = 200 });
    for (due) |s| {
        if (relay.mustHandOver(s)) continue;
        const carrier = (try db.col("orgs").findOne(a, .{ ._id = s.get("carrierId") }, .{})) orelse continue;
        if (!carrier.path("carrier.autoDispatch").truthy() or !eq(carrier.s("status") orelse "", "active")) continue;
        const task = tasks.createTask(r, carrier, try val.from(a, .{ .type = "delivery", .shipmentIds = .{s.get("_id")} }), try system(a)) catch |err| {
            if (!(err == error.Http and r.err != null and r.err.?.status == 409)) std.log.err("Scheduled delivery planning failed: {t}", .{err});
            continue;
        };
        _ = try db.col("shipments").updateOne(a, .{ ._id = s.get("_id") }, .{ .@"$unset" = .{ .scheduledFor = "" } }, .{});
        assignBest(r, carrier, task) catch |err| std.log.err("Scheduled delivery planning failed: {t}", .{err});
    }
}

pub fn retryPendingAutoTasks(r: *Req) !void {
    const a = r.a;
    const pending = try db.col("tasks").find(a, .{ .status = "pending", .auto = true }, .{ .limit = 200 });
    var carriers: std.StringHashMapUnmanaged(?Val) = .empty;
    for (pending) |task| {
        const key = try val.toStr(a, task.get("carrierId"));
        if (!carriers.contains(key)) try carriers.put(a, key, try db.col("orgs").findOne(a, .{ ._id = task.get("carrierId") }, .{}));
        const carrier = carriers.get(key).? orelse continue;
        if (!(carrier.path("carrier.autoDispatch").truthy() or task.t("express")) or !eq(carrier.s("status") orelse "", "active")) continue;
        assignBest(r, carrier, task) catch |err| std.log.err("Auto-assign retry failed: {t}", .{err});
    }
}

pub fn watchdog(r: *Req) !void {
    const a = r.a;
    const now = a_.nowMs();
    const cfg = a_.cfg();
    const stale_before = val.Date{ .ms = now - cfg.stale_location_minutes * 60_000 };

    // On duty, but no position for a while.
    const stale = try db.col("memberships").find(a, .{
        .@"duty.onDuty" = true,
        .status = "active",
        .@"$or" = .{ .{ .lastLocationAt = .{ .@"$lt" = stale_before } }, .{ .lastLocationAt = null, .@"duty.since" = .{ .@"$lt" = stale_before } } },
    }, .{});
    for (stale) |courier| {
        if (try db.col("alerts").findOne(a, .{ .courierId = courier.get("_id"), .type = "signal_lost", .status = .{ .@"$ne" = "resolved" } }, .{}) == null) {
            _ = try tracking.raiseAlert(r, courier, "signal_lost", .undef, try val.from(a, .{
                .lastSeenAt = if (courier.get("lastLocationAt").truthy()) courier.get("lastLocationAt") else Val.null,
                .battery = if (courier.get("lastBattery").isNullish()) Val.null else courier.get("lastBattery"),
                .appInBackground = eq(courier.path("appState.state").asStr() orelse "", "background"),
            }), .undef);
        }
    }

    // The driver app has been in the background: the phone may have stopped sending locations.
    const paused = try db.col("memberships").find(a, .{
        .@"duty.onDuty" = true,
        .status = "active",
        .@"appState.state" = "background",
        .@"appState.at" = .{ .@"$lt" = val.Date{ .ms = now - cfg.paused_alert_minutes * 60_000 } },
    }, .{});
    for (paused) |courier| {
        if (try db.col("alerts").findOne(a, .{ .courierId = courier.get("_id"), .type = "tracking_paused", .status = .{ .@"$ne" = "resolved" } }, .{}) == null) {
            _ = try tracking.raiseAlert(r, courier, "tracking_paused", .undef, try val.from(a, .{
                .since = courier.path("appState.at"),
                .battery = if (courier.get("lastBattery").isNullish()) Val.null else courier.get("lastBattery"),
            }), .undef);
        }
    }

    // Carrying parcels, but not moving for a long time (the signal is fine).
    const active = try db.col("tasks").distinct(a, "courierId", .{ .status = "in_progress" });
    if (active.len > 0) {
        const stopped = try db.col("memberships").find(a, .{
            ._id = .{ .@"$in" = active },
            .lastMovedAt = .{ .@"$lt" = val.Date{ .ms = now - cfg.long_stop_minutes * 60_000 } },
            .lastLocationAt = .{ .@"$gt" = stale_before },
        }, .{});
        for (stopped) |courier| {
            if (try db.col("alerts").findOne(a, .{ .courierId = courier.get("_id"), .type = "long_stop", .at = .{ .@"$gt" = courier.get("lastMovedAt") } }, .{}) == null) {
                _ = try tracking.raiseAlert(r, courier, "long_stop", .undef, try val.from(a, .{ .stoppedSince = courier.get("lastMovedAt") }), .undef);
            }
        }
    }
}

fn step(comptime name: []const u8, f: *const fn (*Req) anyerror!void) void {
    var arena = std.heap.ArenaAllocator.init(a_.app.gpa);
    defer arena.deinit();
    var r = Req.background(arena.allocator());
    f(&r) catch |e| std.log.err(name ++ " failed: {t}", .{e});
    bus.flush(&r);
}

/// Every minute: watchdog, retries and scheduled deliveries. Run as its own task.
pub fn loop() void {
    while (true) {
        a_.app.io.sleep(.fromSeconds(60), .awake) catch return;
        if (!bus.enabled[@intFromEnum(bus.Service.dispatch)]) continue;
        step("Watchdog", watchdog);
        step("Auto-dispatch retry", retryPendingAutoTasks);
        step("Scheduled deliveries", planScheduledDeliveries);
    }
}
