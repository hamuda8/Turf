//! Courier duty, GPS positions and safety alerts (src/services/tracking.js). Positions arrive in
//! batches from the driver app (it buffers while offline); the newest is kept on the membership,
//! every one in courier_positions (expired after LOCATION_RETENTION_DAYS).

const std = @import("std");
const val = @import("../lib/val.zig");
const db = @import("../lib/db.zig");
const web = @import("../web.zig");
const a_ = @import("../app.zig");
const geo = @import("../geo.zig");
const bus = @import("../bus.zig");
const Val = val.Val;
const Req = web.Req;
const Allocator = std.mem.Allocator;

const max_batch = 200;
const max_age_ms = 24 * 3600_000;
/// 50 m counts as "moved" for long-stop detection.
const move_threshold_km = 0.05;
const speeding_repeat_min = 15;

pub const alert_types = [_][]const u8{ "sos", "signal_lost", "long_stop", "speeding", "tracking_paused" };
const tracking_alerts = [_][]const u8{ "signal_lost", "tracking_paused" };

fn resolveTrackingAlerts(r: *Req, courier_id: Val, resolution: []const u8) !void {
    const a = r.a;
    const open = try db.col("alerts").find(a, .{ .courierId = courier_id, .type = .{ .@"$in" = &tracking_alerts }, .status = .{ .@"$ne" = "resolved" } }, .{});
    if (open.len == 0) return;
    const ids = try val.newArr(a);
    for (open) |x| try ids.push(x.get("_id"));
    _ = try db.col("alerts").updateMany(a, .{ ._id = .{ .@"$in" = ids } }, .{ .@"$set" = .{ .status = "resolved", .resolvedAt = a_.now(), .resolution = resolution } }, .{});
    for (open) |x| bus.emit(r, "alert.updated", .{ .alert = try val.spread(a, .{ x, .{ .status = "resolved", .resolution = resolution } }) });
}

/// The driver app reports whether it is on screen; "background" means updates may stop.
pub fn setAppState(r: *Req, courier: Val, state: []const u8) !void {
    const a = r.a;
    const now = a_.now();
    _ = try db.col("memberships").updateOne(a, .{ ._id = courier.get("_id") }, .{ .@"$set" = .{ .appState = .{ .state = state, .at = now } } }, .{});
    if (std.mem.eql(u8, state, "foreground")) try resolveTrackingAlerts(r, courier.get("_id"), "auto");
    bus.emit(r, "courier.duty", .{ .courier = try val.spread(a, .{ courier, .{ .appState = .{ .state = state, .at = now } } }) });
}

fn optRange(v: Val, min: f64, max: f64) Val {
    if (v == .null) return .null;
    const x = val.toNum(v);
    if (!std.math.isFinite(x) or x < min or x > max) return .null;
    return .{ .num = x };
}

fn parsePoint(r: *Req, p: Val, i: usize) !Val {
    const a = r.a;
    const f = try std.fmt.allocPrint(a, "positions[{d}]", .{i});
    if (p != .obj and p != .arr) return r.badRequest(try std.fmt.allocPrint(a, "{s} must be an object", .{f}), f, null, null);
    const lat = val.toNum(p.get("lat"));
    const lng = val.toNum(p.get("lng"));
    if (!std.math.isFinite(lat) or lat < -90 or lat > 90 or !std.math.isFinite(lng) or lng < -180 or lng > 180)
        return r.badRequest(try std.fmt.allocPrint(a, "{s} has invalid coordinates", .{f}), f, null, null);
    const at = val.newDate(p.get("at")) orelse return r.badRequest(try std.fmt.allocPrint(a, "{s}.at must be a timestamp", .{f}), f, null, null);
    const speed = p.get("speed");
    return val.from(a, .{
        .location = .{ .type = "Point", .coordinates = .{ lng, lat } },
        .at = val.Date{ .ms = at },
        .accuracy = optRange(p.get("accuracy"), 0, 100_000),
        // The browser gives m/s.
        .speedKmh = if (speed.isNullish()) Val.null else optRange(.{ .num = val.toNum(speed) * 3.6 }, 0, 500),
        .heading = optRange(p.get("heading"), 0, 360),
        .battery = optRange(p.get("battery"), 0, 1),
    });
}

pub fn setDuty(r: *Req, courier: Val, on_duty: bool) !void {
    const a = r.a;
    if (!on_duty) {
        if (try db.col("tasks").count(a, .{ .courierId = courier.get("_id"), .status = "in_progress" }, .{}) > 0)
            return r.conflict("Finish or hand over your active tasks before going off duty", "active_tasks_off_duty", null);
    }
    const now = a_.now();
    _ = try db.col("memberships").updateOne(a, .{ ._id = courier.get("_id") }, .{
        .@"$set" = .{ .@"duty.onDuty" = on_duty, .@"duty.since" = now, .appState = .{ .state = "foreground", .at = now } },
        .@"$push" = .{ .dutyLog = .{ .@"$each" = .{.{ .onDuty = on_duty, .at = now }}, .@"$slice" = -200 } },
    }, .{});
    if (!on_duty) try resolveTrackingAlerts(r, courier.get("_id"), "off_duty");
    bus.emit(r, "courier.duty", .{ .courier = try val.spread(a, .{ courier, .{ .duty = .{ .onDuty = on_duty, .since = now } } }) });
}

pub fn recordPositions(r: *Req, courier: Val, raw: Val) !Val {
    const a = r.a;
    if (raw != .arr or raw.items().len == 0) return r.badRequest("positions must be a non-empty array", "positions", null, null);
    if (raw.items().len > max_batch) return r.badRequest(try std.fmt.allocPrint(a, "At most {d} positions per request", .{max_batch}), "positions", null, null);
    const now = a_.nowMs();
    var points: std.ArrayList(Val) = .empty;
    for (raw.items(), 0..) |p, i| {
        const pt = try parsePoint(r, p, i);
        const at = pt.get("at").date;
        if (at <= now + 60_000 and at >= now - max_age_ms) try points.append(a, pt);
    }
    const Cmp = struct {
        fn lt(_: void, x: Val, y: Val) bool {
            return x.get("at").date < y.get("at").date;
        }
    };
    std.mem.sort(Val, points.items, {}, Cmp.lt);
    if (points.items.len == 0) return val.from(a, .{ .accepted = 0 });

    var docs: std.ArrayList(Val) = .empty;
    for (points.items) |p| try docs.append(a, try val.spread(a, .{ .{ .courierId = courier.get("_id"), .carrierId = courier.get("orgId") }, p }));
    _ = try db.col("courier_positions").insertMany(a, docs.items);

    // Speeding is checked on every batch, including old points sent late from the offline buffer.
    try checkSpeeding(r, courier, points.items);

    const latest = points.items[points.items.len - 1];
    if (courier.get("lastLocationAt").dateMs()) |last| if (latest.get("at").date <= last) return val.from(a, .{ .accepted = points.items.len });

    const set = try val.from(a, .{
        .lastLocation = latest.get("location"),
        .lastLocationAt = latest.get("at"),
        .lastAccuracy = latest.get("accuracy"),
        .lastSpeedKmh = latest.get("speedKmh"),
        .lastHeading = latest.get("heading"),
        .lastBattery = latest.get("battery"),
    });
    // When the courier last really moved, for long-stop detection.
    const anchor = courier.get("moveAnchor");
    if (!anchor.truthy() or geo.distanceKmV(anchor, latest.get("location")) > move_threshold_km) {
        try set.set("moveAnchor", latest.get("location"));
        try set.set("lastMovedAt", latest.get("at"));
    }
    _ = try db.col("memberships").updateOne(a, .{ ._id = courier.get("_id") }, .{ .@"$set" = set }, .{});

    // A fresh position resolves a signal-lost alert automatically.
    const lost = try db.col("alerts").find(a, .{ .courierId = courier.get("_id"), .type = "signal_lost", .status = .{ .@"$ne" = "resolved" } }, .{});
    if (lost.len > 0) {
        const ids = try val.newArr(a);
        for (lost) |x| try ids.push(x.get("_id"));
        _ = try db.col("alerts").updateMany(a, .{ ._id = .{ .@"$in" = ids } }, .{ .@"$set" = .{ .status = "resolved", .resolvedAt = a_.now(), .resolution = "auto" } }, .{});
        for (lost) |x| bus.emit(r, "alert.updated", .{ .alert = try val.spread(a, .{ x, .{ .status = "resolved", .resolution = "auto" } }) });
    }
    bus.emit(r, "courier.position", .{ .courier = try val.spread(a, .{ courier, set }) });
    return val.from(a, .{ .accepted = points.items.len });
}

fn checkSpeeding(r: *Req, courier: Val, points: []const Val) !void {
    const a = r.a;
    const v = geo.vehicle(courier.path("courier.vehicle").asStr() orelse "") orelse return;
    const limit = v.speedLimit orelse return;
    // Two consecutive readings over the limit filter out single GPS glitches.
    var streak: usize = 0;
    var worst: ?Val = null;
    for (points) |p| {
        const sp = p.get("speedKmh");
        const acc = p.get("accuracy");
        if (sp != .null and val.toNum(sp) > limit and (acc == .null or val.toNum(acc) < 50)) {
            streak += 1;
            if (worst == null or val.toNum(sp) > val.toNum(worst.?.get("speedKmh"))) worst = p;
        } else streak = 0;
        if (streak >= 2) break;
    }
    if (streak < 2) return;
    if (try db.col("alerts").findOne(a, .{ .courierId = courier.get("_id"), .type = "speeding", .at = .{ .@"$gt" = val.Date{ .ms = a_.nowMs() - speeding_repeat_min * 60_000 } } }, .{}) != null) return;
    _ = try raiseAlert(r, courier, "speeding", worst.?.get("location"), try val.from(a, .{ .speedKmh = val.jsRound(val.toNum(worst.?.get("speedKmh"))), .limitKmh = limit }), .undef);
}

pub fn raiseAlert(r: *Req, courier: Val, alert_type: []const u8, location: Val, details: Val, note: Val) !Val {
    const a = r.a;
    const alert = try val.from(a, .{
        .carrierId = courier.get("orgId"),
        .courierId = courier.get("_id"),
        .courierName = courier.get("name"),
        .vehicle = if (courier.path("courier.vehicle").truthy()) courier.path("courier.vehicle") else Val.null,
        .type = alert_type,
        .status = "open",
        .at = a_.now(),
        .location = if (location.truthy()) location else if (courier.get("lastLocation").truthy()) courier.get("lastLocation") else Val.null,
        .details = if (details == .undef) try val.newObj(a) else details,
        .note = if (note.truthy()) note else Val.null,
    });
    _ = try db.col("alerts").insertOne(a, alert);
    bus.emit(r, "alert.raised", .{ .alert = alert });
    return alert;
}

pub fn sos(r: *Req, courier: Val, location: Val, note: Val) !Val {
    const battery = courier.get("lastBattery");
    return raiseAlert(r, courier, "sos", location, try val.from(r.a, .{ .battery = if (battery.isNullish()) Val.null else battery }), note);
}

pub fn listAlerts(a: Allocator, carrier_id: Val, status: ?[]const u8) ![]Val {
    const q = try val.from(a, .{ .carrierId = carrier_id });
    if (status) |s| {
        if (std.mem.eql(u8, s, "open")) try q.set("status", .{ .@"$in" = .{ "open", "acknowledged" } }) else if (s.len > 0) try q.set("status", s);
    }
    return db.col("alerts").find(a, q, .{ .sort = try val.from(a, .{ .at = -1 }), .limit = 200 });
}

pub fn updateAlert(r: *Req, ctx: *const web.OrgCtx, alert_id: Val, status: []const u8, note: ?[]const u8) !Val {
    const a = r.a;
    const set = try val.from(a, .{ .status = status });
    try set.set(try std.fmt.allocPrint(a, "{s}At", .{status}), a_.now());
    try set.set(try std.fmt.allocPrint(a, "{s}By", .{status}), .{ .userId = ctx.member.get("userId"), .name = ctx.member.get("name") });
    if (note) |n| if (n.len > 0) try set.set("resolutionNote", n);
    const alert = (try db.col("alerts").findOneAndUpdate(a, .{ ._id = alert_id, .carrierId = ctx.org.get("_id") }, .{ .@"$set" = set }, .{ .returnDocument = .after })) orelse return r.notFound("Alert");
    bus.emit(r, "alert.updated", .{ .alert = alert });
    return alert;
}

/// Position history for a courier between two times (for replaying a route).
pub fn positionHistory(a: Allocator, courier_id: Val, from: i64, to: i64) ![]Val {
    return db.col("courier_positions").find(a, .{ .courierId = courier_id, .at = .{ .@"$gte" = val.Date{ .ms = from }, .@"$lte" = val.Date{ .ms = to } } }, .{
        .projection = try val.from(a, .{ ._id = 0, .location = 1, .at = 1, .speedKmh = 1 }),
        .sort = try val.from(a, .{ .at = 1 }),
        .limit = 5000,
    });
}
