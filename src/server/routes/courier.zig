//! Driver app API /api/app/orgs/:orgId/courier (src/routes/app/courier.js): duty, GPS, tasks,
//! proof of delivery, SOS, navigation.

const std = @import("std");
const val = @import("../lib/val.zig");
const db = @import("../lib/db.zig");
const web = @import("../web.zig");
const a_ = @import("../app.zig");
const geo = @import("../geo.zig");
const ratelimit = @import("../ratelimit.zig");
const audit = @import("../services/audit.zig");
const tasks = @import("../services/tasks.zig");
const tracking = @import("../services/tracking.zig");
const routing = @import("../services/routing.zig");
const earnings = @import("../services/earnings.zig");
const moderation = @import("../services/moderation.zig");
const Val = val.Val;
const Req = web.Req;
const V = web.V;
const route = web.route;
const routeMw = web.routeMw;
const Allocator = std.mem.Allocator;

/// Only couriers of a carrier can use the driver app (onlyType + the courier check).
pub fn guard(r: *Req) !void {
    try web.onlyType("carrier")(r);
    const oc = r.orgCtx();
    if (!oc.perms.has("courier.work") or !try tasks.isCourier(r.a, oc.member)) return r.forbidden("Only couriers can use the driver app");
    r.courier = oc.member;
}

fn byCourier(r: *Req) []const u8 {
    return val.toStr(r.a, r.courier.get("_id")) catch "";
}

pub const routes = [_]web.Route{
    route(.GET, "/me", me),
    route(.POST, "/consent", consent),
    route(.POST, "/duty", duty),
    routeMw(.POST, "/positions", &.{ratelimit.limit("positions", 60_000, 30, byCourier)}, positions),
    route(.POST, "/presence", presence),
    route(.POST, "/sos", sos),
    route(.GET, "/tasks", listTasks),
    route(.GET, "/tasks/:taskId", getTask),
    route(.POST, "/tasks/:taskId/accept", accept),
    route(.POST, "/tasks/:taskId/decline", decline),
    route(.POST, "/tasks/:taskId/start", startTask),
    routeMw(.POST, "/tasks/:taskId/complete", &.{ratelimit.limit("complete", 60_000, 20, byCourier)}, complete),
    route(.POST, "/tasks/:taskId/fail", fail),
    routeMw(.GET, "/route", &.{ratelimit.limit("route", 60_000, 30, byCourier)}, navigate),
};

fn loc(r: *Req, b: Val) !Val {
    return (try V.point(r, b.get("location"), "location", .{ .optional = true })) orelse .null;
}

/// Actions sent late from the phone's outbox carry the time they were really done.
fn clientAt(b: Val) Val {
    if (!b.get("clientAt").truthy()) return .null;
    const at = val.newDate(b.get("clientAt")) orelse return .null;
    const age = a_.nowMs() - at;
    return if (age >= -5 * 60_000 and age <= 48 * 3600_000) .{ .date = at } else .null;
}

fn myTask(r: *Req) !Val {
    const task = try tasks.getTask(r, r.orgCtx().org.get("_id"), .{ .oid = (try V.id(r, .{ .str = r.param("taskId") }, "taskId", .{})).? });
    if (!task.get("courierId").truthy() or !task.get("courierId").sameId(r.courier.get("_id"))) return r.forbidden("This task is not assigned to you");
    return task;
}

fn withLoc(a: Allocator, x: Val) !Val {
    return val.spread(a, .{ x, .{ .location = try web.toLatLng(a, x.get("location")) } });
}

fn taskOut(a: Allocator, t: Val) !Val {
    const ships = try val.newArr(a);
    for (t.get("shipments").items()) |s| try ships.push(try val.spread(a, .{ s, .{ .pickup = try withLoc(a, s.get("pickup")), .dropoff = try withLoc(a, s.get("dropoff")) } }));
    return val.spread(a, .{ t, .{ .from = try withLoc(a, t.get("from")), .to = try withLoc(a, t.get("to")), .shipments = ships } });
}

fn ok(r: *Req) !void {
    return r.json(200, .{ .ok = true });
}

/// Couriers agree to location sharing before their first shift; a new consent text raises the
/// version so everyone is asked again.
const location_consent_version = 1;

fn hasLocationConsent(m: Val) bool {
    return val.or0(m.path("consent.location.version")) >= location_consent_version;
}

fn me(r: *Req) !void {
    const a = r.a;
    const c = r.courier;
    const org = r.orgCtx().org;
    // Midnight UTC (Turf-js uses the server's local midnight; the servers run in UTC).
    const start = @divFloor(a_.nowMs(), 86400_000) * 86400_000;
    const week_ago = start - 6 * 86400_000;
    const tomorrow = start + 86400_000;
    const done_today = try db.col("tasks").count(a, .{ .courierId = c.get("_id"), .status = "completed", .completedAt = .{ .@"$gte" = val.Date{ .ms = start } } }, .{});
    const cash = try db.col("shipments").aggregate(a, .{
        .{ .@"$match" = .{ .carrierId = org.get("_id"), .@"cod.collectedBy" = c.get("_id"), .@"cod.settledAt" = null } },
        .{ .@"$group" = .{ ._id = "$cod.currency", .amount = .{ .@"$sum" = "$cod.amount" }, .count = .{ .@"$sum" = 1 } } },
    });
    const cash_out = try val.newArr(a);
    for (cash) |x| try cash_out.push(.{ .currency = x.get("_id"), .amount = x.get("amount"), .count = x.get("count") });
    const v = geo.vehicle(c.path("courier.vehicle").asStr() orelse "");
    return r.json(200, .{
        .memberId = c.get("_id"),
        .name = c.get("name"),
        .courier = c.get("courier"),
        .vehicleDefaults = if (v) |vh| try val.from(a, .{ .rangeKm = vh.rangeKm, .capacityKg = vh.capacityKg, .speedKmh = vh.speedKmh, .speedLimit = if (vh.speedLimit) |s| Val{ .num = s } else Val.null, .routing = vh.routing }) else Val.undef,
        .onDuty = c.path("duty.onDuty").truthy(),
        .dutySince = if (c.path("duty.since").truthy()) c.path("duty.since") else Val.null,
        .needsLocationConsent = !hasLocationConsent(c),
        .locationRetentionDays = a_.cfg().location_retention_days,
        .doneToday = done_today,
        .cashInHand = cash_out,
        // Pay only shows when the company set courier rates.
        .summary = .{
            .today = try earnings.courierSummary(a, org.get("_id"), c.get("_id"), start, tomorrow),
            .week = try earnings.courierSummary(a, org.get("_id"), c.get("_id"), week_ago, tomorrow),
            .currency = org.path("carrier.currency"),
            .paid = org.path("carrier.courierPay").truthy(),
        },
    });
}

fn consent(r: *Req) !void {
    const version = (try V.num(r, r.body.get("version"), "version", .{ .min = 1, .integer = true })).?;
    if (version != location_consent_version) return r.fail(409, "consent_outdated", "Please reload the app to see the current consent text", .{});
    const c = try val.from(r.a, .{ .version = version, .at = a_.now(), .userAgent = val.jsSlice(r.header("user-agent") orelse "", 200) });
    _ = try db.col("memberships").updateOne(r.a, .{ ._id = r.courier.get("_id") }, .{ .@"$set" = .{ .@"consent.location" = c } }, .{});
    audit.audit(r.a, r.orgCtx().org.get("_id"), r.orgCtx().member, "courier.location_consent", .{ .version = version });
    return r.json(200, .{ .ok = true, .version = version });
}

fn duty(r: *Req) !void {
    const on = (try V.boolean(r, r.body.get("onDuty"), "onDuty", .{})).?;
    if (on and !hasLocationConsent(r.courier)) return r.fail(409, "consent_required", "Agree to location sharing before starting your shift", .{});
    try tracking.setDuty(r, r.courier, on);
    return r.json(200, .{ .onDuty = on });
}

/// Phones send a batch every ~15 s; bursts are allowed when an offline buffer is flushed.
fn positions(r: *Req) !void {
    if (!r.courier.path("duty.onDuty").truthy()) return r.json(200, .{ .accepted = 0, .offDuty = true });
    return r.json(200, try tracking.recordPositions(r, r.courier, r.body.get("positions")));
}

/// The app reports when it goes to the background or comes back.
fn presence(r: *Req) !void {
    const state = (try V.oneOf(r, r.body.get("state"), "state", &.{ "foreground", "background" }, .{})).?;
    if (r.courier.path("duty.onDuty").truthy()) try tracking.setAppState(r, r.courier, state);
    return ok(r);
}

fn sos(r: *Req) !void {
    const note = try moderation.checkedText(r, "note", try V.str(r, r.body.get("note"), "note", .{ .max = 300, .optional = true }), .{ .type = "alert", .field = "sos" });
    const alert = try tracking.sos(r, r.courier, try loc(r, r.body), if (note) |n| Val{ .str = n } else .undef);
    return r.json(201, .{ .id = alert.get("_id"), .at = alert.get("at") });
}

fn listTasks(r: *Req) !void {
    const a = r.a;
    const start: Val = .{ .date = @divFloor(a_.nowMs(), 86400_000) * 86400_000 };
    const list = try db.col("tasks").find(a, .{
        .courierId = r.courier.get("_id"),
        .@"$or" = .{
            .{ .status = .{ .@"$in" = .{ "assigned", "accepted", "in_progress" } } },
            .{ .status = .{ .@"$in" = .{ "completed", "failed" } }, .updatedAt = .{ .@"$gte" = start } },
        },
    }, .{ .sort = try val.from(a, .{ .createdAt = 1 }) });
    const out = try val.newArr(a);
    for (list) |t| try out.push(try taskOut(a, try tasks.taskViewForCourier(a, t)));
    return r.json(200, out);
}

fn getTask(r: *Req) !void {
    return r.json(200, try taskOut(r.a, try tasks.taskViewForCourier(r.a, try myTask(r))));
}

fn accept(r: *Req) !void {
    _ = try tasks.acceptTask(r, try myTask(r), r.courier);
    return ok(r);
}

fn decline(r: *Req) !void {
    _ = try tasks.declineTask(r, try myTask(r), r.courier, try V.str(r, r.body.get("reason"), "reason", .{ .max = 300, .optional = true }));
    return ok(r);
}

fn startTask(r: *Req) !void {
    const a = r.a;
    const task = try myTask(r);
    const location = try loc(r, r.body);
    var missing: std.ArrayList(Val) = .empty;
    if (try V.arr(r, r.body.get("missingShipmentIds"), "missingShipmentIds", .{ .max = 500, .optional = true })) |list| {
        for (list, 0..) |v, i| try missing.append(a, .{ .oid = (try V.id(r, v, try std.fmt.allocPrint(a, "missingShipmentIds[{d}]", .{i}), .{})).? });
    }
    _ = try tasks.startTask(r, task, r.courier, location, missing.items);
    return ok(r);
}

fn complete(r: *Req) !void {
    const a = r.a;
    const pod = (try V.obj(r, r.body.get("pod"), "pod", .{ .optional = true })) orelse try val.newObj(a);
    const task = try myTask(r);
    const location = try loc(r, r.body);
    const at = clientAt(r.body);
    const p = try val.from(a, .{
        .code = try V.str(r, pod.get("code"), "pod.code", .{ .max = 10, .optional = true }),
        .receiverName = try V.str(r, pod.get("receiverName"), "pod.receiverName", .{ .max = 120, .optional = true }),
        .photo = if (pod.get("photo").truthy()) pod.get("photo") else Val.null,
        .codCollected = try V.boolean(r, pod.get("codCollected"), "pod.codCollected", .{ .optional = true }),
    });
    _ = try tasks.completeTask(r, task, r.courier, location, p, at);
    return ok(r);
}

fn fail(r: *Req) !void {
    const task = try myTask(r);
    const b = r.body;
    const note = try moderation.checkedText(r, "note", try V.str(r, b.get("note"), "note", .{ .max = 500, .optional = true }), .{ .type = "shipment", .field = "fail" });
    const reschedule = std.mem.eql(u8, b.s("reason") orelse "", "reschedule_requested") and b.get("rescheduleFor").truthy();
    _ = try tasks.failTask(r, task, r.courier, r.orgCtx().org, b.get("reason"), if (note) |n| Val{ .str = n } else .undef, try loc(r, b), if (reschedule) b.get("rescheduleFor") else Val.null, clientAt(b));
    return ok(r);
}

fn navigate(r: *Req) !void {
    const Parse = struct {
        fn f(rq: *Req, v: Val, field: []const u8) ![2]f64 {
            const s = if (v.isNullish()) "" else try val.toStr(rq.a, v);
            var it = std.mem.splitScalar(u8, s, ',');
            const lat = val.strToNum(it.next() orelse "");
            const lng = if (it.next()) |x| val.strToNum(x) else std.math.nan(f64);
            _ = try V.point(rq, try val.from(rq.a, .{ .lat = lat, .lng = lng }), field, .{});
            return .{ lat, lng };
        }
    };
    const v = geo.vehicle(r.courier.path("courier.vehicle").asStr() orelse "") orelse return error.UnknownVehicle;
    const from = try Parse.f(r, r.q("from"), "from");
    const to = try Parse.f(r, r.q("to"), "to");
    return r.json(200, try routing.route(r, v.routing, from[0], from[1], to[0], to[1]));
}
