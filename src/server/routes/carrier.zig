//! Carrier console API /api/app/orgs/:orgId/carrier (src/routes/app/carrier.js): settings, hubs,
//! shipments, dispatch, fleet, safety, finance.

const std = @import("std");
const val = @import("../lib/val.zig");
const db = @import("../lib/db.zig");
const web = @import("../web.zig");
const a_ = @import("../app.zig");
const geo = @import("../geo.zig");
const messages = @import("../messages.zig");
const carriers = @import("../services/carriers.zig");
const coverage = @import("../services/coverage.zig");
const relay = @import("../services/relay.zig");
const earnings = @import("../services/earnings.zig");
const reports = @import("../services/reports.zig");
const shipments = @import("../services/shipments.zig");
const tasks = @import("../services/tasks.zig");
const ops = @import("../services/operations.zig");
const tracking = @import("../services/tracking.zig");
const push = @import("../services/push.zig");
const audit = @import("../services/audit.zig");
const statements = @import("../services/statements.zig");
const direct = @import("../services/direct.zig");
const claims = @import("../services/claims.zig");
const moderation = @import("../services/moderation.zig");
const common = @import("common.zig");
const Val = val.Val;
const Req = web.Req;
const V = web.V;
const route = web.route;
const routeMw = web.routeMw;
const need = web.need;
const needAny = web.needAny;
const Allocator = std.mem.Allocator;

pub const routes = [_]web.Route{
    routeMw(.PATCH, "/settings", &.{need(&.{"org.settings"})}, settings),
    route(.GET, "/hubs", listHubs),
    routeMw(.POST, "/hubs", &.{need(&.{"hubs.manage"})}, createHub),
    routeMw(.PATCH, "/hubs/:hubId", &.{need(&.{"hubs.manage"})}, updateHub),
    routeMw(.GET, "/hubs/:hubId/contents", &.{needAny(&.{ "shipments.view", "hub.scan" })}, hubContents),
    routeMw(.POST, "/hubs/:hubId/check-in", &.{need(&.{"hub.scan"})}, checkIn),
    routeMw(.GET, "/shipments", &.{need(&.{"shipments.view"})}, listShipments),
    routeMw(.GET, "/shipments/:id", &.{need(&.{"shipments.view"})}, getShipment),
    routeMw(.GET, "/shipments/:id/pod-photo", &.{need(&.{"shipments.view"})}, podPhoto),
    routeMw(.PATCH, "/shipments/:id", &.{need(&.{"shipments.manage"})}, patchShipment),
    routeMw(.POST, "/shipments/:id/reschedule", &.{need(&.{"shipments.manage"})}, reschedule),
    routeMw(.POST, "/shipments/:id/lost", &.{need(&.{"shipments.manage"})}, markLost),
    routeMw(.POST, "/shipments/:id/damage", &.{need(&.{"shipments.manage"})}, reportDamage),
    routeMw(.GET, "/claims", &.{need(&.{"shipments.view"})}, listClaims),
    routeMw(.POST, "/claims/:claimId/decide", &.{need(&.{"shipments.manage"})}, decideClaim),
    routeMw(.POST, "/shipments/:id/notes", &.{need(&.{"shipments.manage"})}, addNote),
    routeMw(.POST, "/shipments/:id/deliver", &.{need(&.{"shipments.manage"})}, manualDeliver),
    routeMw(.POST, "/shipments/:id/return", &.{need(&.{"shipments.manage"})}, startReturn),
    routeMw(.POST, "/shipments/:id/cancel", &.{need(&.{"shipments.manage"})}, cancel),
    routeMw(.GET, "/tasks", &.{needAny(&.{ "dispatch.manage", "fleet.view" })}, listTasks),
    routeMw(.POST, "/tasks/suggestions", &.{need(&.{"dispatch.manage"})}, planSuggestions),
    routeMw(.POST, "/tasks", &.{need(&.{"dispatch.manage"})}, createTask),
    routeMw(.GET, "/tasks/:taskId/suggestions", &.{need(&.{"dispatch.manage"})}, taskSuggestions),
    routeMw(.POST, "/tasks/:taskId/assign", &.{need(&.{"dispatch.manage"})}, assignTask),
    routeMw(.POST, "/tasks/:taskId/cancel", &.{need(&.{"dispatch.manage"})}, cancelTask),
    routeMw(.GET, "/fleet", &.{needAny(&.{ "fleet.view", "dispatch.manage" })}, fleet),
    routeMw(.GET, "/fleet/:courierId/history", &.{need(&.{"fleet.view"})}, fleetHistory),
    routeMw(.GET, "/alerts", &.{need(&.{"alerts.manage"})}, listAlerts),
    routeMw(.PATCH, "/alerts/:alertId", &.{need(&.{"alerts.manage"})}, updateAlert),
    routeMw(.GET, "/alerts/push", &.{need(&.{"alerts.manage"})}, sosStatus),
    routeMw(.POST, "/alerts/push", &.{need(&.{"alerts.manage"})}, setSos),
    routeMw(.GET, "/requests", &.{need(&.{"dispatch.manage"})}, listRequests),
    routeMw(.POST, "/requests/:id/accept", &.{need(&.{"dispatch.manage"})}, acceptRequest),
    routeMw(.POST, "/requests/:id/decline", &.{need(&.{"dispatch.manage"})}, declineRequest),
    routeMw(.GET, "/clients", &.{need(&.{"org.settings"})}, listClients),
    routeMw(.POST, "/clients", &.{need(&.{"org.settings"})}, addClient),
    routeMw(.DELETE, "/clients/:merchantId", &.{need(&.{"org.settings"})}, removeClient),
    routeMw(.GET, "/blocked", &.{need(&.{"org.settings"})}, listBlocked),
    routeMw(.POST, "/blocked", &.{need(&.{"org.settings"})}, block),
    routeMw(.DELETE, "/blocked/:merchantId", &.{need(&.{"org.settings"})}, unblock),
    routeMw(.GET, "/finance/statements", &.{need(&.{"finance.view"})}, financeStatements),
    routeMw(.GET, "/finance/statement", &.{need(&.{"finance.view"})}, financeStatement),
    routeMw(.GET, "/finance/cod", &.{need(&.{"finance.view"})}, codSummary),
    routeMw(.POST, "/finance/cod/settle", &.{need(&.{"finance.manage"})}, settleCod),
    routeMw(.POST, "/finance/cod/remit", &.{need(&.{"finance.manage"})}, remitCod),
    routeMw(.GET, "/reports", &.{needAny(&.{ "shipments.view", "finance.view" })}, common.reportFor("carrier")),
    routeMw(.GET, "/reports/shipments", &.{needAny(&.{ "shipments.view", "finance.view" })}, common.reportRowsFor("carrier")),
    routeMw(.GET, "/stats", &.{needAny(&.{ "shipments.view", "fleet.view" })}, stats),
};

fn orgId(r: *Req) Val {
    return r.orgCtx().org.get("_id");
}

fn staff(r: *Req) !Val {
    return val.from(r.a, .{ .type = "user", .id = r.orgCtx().member.get("userId"), .name = r.orgCtx().member.get("name") });
}

fn ok(r: *Req) !void {
    return r.json(200, .{ .ok = true });
}

fn idParam(r: *Req, name: []const u8) !Val {
    return .{ .oid = (try V.id(r, .{ .str = r.param(name) }, name, .{})).? };
}

fn view(r: *Req, s: Val) !void {
    return r.json(200, try shipments.carrierView(r.a, s, orgId(r)));
}

// ---- Settings -------------------------------------------------------------------------------------

fn isCurrency(s: []const u8) bool {
    if (s.len != 3) return false;
    for (s) |c| if (!std.ascii.isUpper(c)) return false;
    return true;
}

fn settings(r: *Req) !void {
    const a = r.a;
    const b = (try V.obj(r, r.body, "body", .{})).?;
    const changes = try val.newObj(a);
    if (b.get("coverage") != .undef) {
        const list = (try V.arr(r, b.get("coverage"), "coverage", .{ .max = 14 })).?;
        const out = try val.newArr(a);
        for (list, 0..) |x, i| {
            const g = (try V.oneOf(r, x, try std.fmt.allocPrint(a, "coverage[{d}]", .{i}), geo.codes, .{})).?;
            if (!val.includesStr(out, g)) try out.push(g);
        }
        try changes.set("coverage", out);
    }
    if (b.get("courierPay") != .undef) try changes.set("courierPay", try earnings.parseCourierPay(r, b.get("courierPay")));
    if (b.get("areas") != .undef) try changes.set("areas", try coverage.parseAreas(r, b.get("areas"), if (changes.get("coverage") != .undef) changes.get("coverage") else r.orgCtx().org.path("carrier.coverage")));
    for ([_][]const u8{ "acceptMarketplace", "acceptDirect", "acceptIndividuals", "autoDispatch", "directLocal" }) |flag| {
        if (b.get(flag) != .undef) try changes.set(flag, (try V.boolean(r, b.get(flag), flag, .{})).?);
    }
    if (b.get("visibility") != .undef) try changes.set("visibility", (try V.oneOf(r, b.get("visibility"), "visibility", &.{ "network", "private" }, .{})).?);
    if (b.get("maxWeightKg") != .undef) try changes.set("maxWeightKg", (try V.num(r, b.get("maxWeightKg"), "maxWeightKg", .{ .min = 0.5, .max = 50000 })).?);
    if (b.get("maxAttempts") != .undef) try changes.set("maxAttempts", (try V.num(r, b.get("maxAttempts"), "maxAttempts", .{ .min = 1, .max = 10, .integer = true })).?);
    if (b.get("currency") != .undef) try changes.set("currency", (try V.str(r, b.get("currency"), "currency", .{ .min = 3, .max = 3, .pattern = isCurrency })).?);
    if (b.get("pricing") != .undef) {
        const p = (try V.obj(r, b.get("pricing"), "pricing", .{})).?;
        const Money = struct {
            fn f(rq: *Req, pv: Val, k: []const u8, max: f64, optional: bool) !f64 {
                const v = if (optional and pv.get(k).isNullish()) Val{ .num = 0 } else pv.get(k);
                return (try V.num(rq, v, try std.fmt.allocPrint(rq.a, "pricing.{s}", .{k}), .{ .min = 0, .max = max })).?;
            }
        };
        const m = Money.f;
        try changes.set("pricing", .{
            .localBase = try m(r, p, "localBase", 1e10, false),
            .nationalBase = try m(r, p, "nationalBase", 1e10, false),
            .includedKg = try m(r, p, "includedKg", 1000, false),
            .perKg = try m(r, p, "perKg", 1e10, false),
            .perKm = try m(r, p, "perKm", 1e10, false),
            .codPercent = (try V.num(r, p.get("codPercent"), "pricing.codPercent", .{ .min = 0, .max = 100 })).?,
            .codMin = try m(r, p, "codMin", 1e10, false),
            .volumetricDivisor = (try V.num(r, if (p.get("volumetricDivisor").isNullish()) Val{ .num = 0 } else p.get("volumetricDivisor"), "pricing.volumetricDivisor", .{ .min = 0, .max = 100000 })).?,
            .fragileFee = try m(r, p, "fragileFee", 1e10, true),
            .extraPieceFee = try m(r, p, "extraPieceFee", 1e10, true),
            .valuePercent = (try V.num(r, if (p.get("valuePercent").isNullish()) Val{ .num = 0 } else p.get("valuePercent"), "pricing.valuePercent", .{ .min = 0, .max = 100 })).?,
            .routes = try parseRoutes(r, p.get("routes")),
        });
    }
    if (b.get("sla") != .undef) {
        const s = (try V.obj(r, b.get("sla"), "sla", .{})).?;
        try changes.set("sla", .{
            .localHours = (try V.num(r, s.get("localHours"), "sla.localHours", .{ .min = 1, .max = 720 })).?,
            .nationalHours = (try V.num(r, s.get("nationalHours"), "sla.nationalHours", .{ .min = 1, .max = 720 })).?,
        });
    }
    if (b.get("express") != .undef) try changes.set("express", try parseExpress(r, b.get("express")));
    if (b.get("codEnabled") != .undef) try changes.set("cod.enabled", (try V.boolean(r, b.get("codEnabled"), "codEnabled", .{})).?);
    if (changes.obj.count() == 0) return r.badRequest("Nothing to update", null, "nothing_to_update", null);
    try carriers.updateCarrierSettings(r, r.orgCtx(), changes);
    return ok(r);
}

/// /^([01]\d|2[0-3]):[0-5]\d$/
fn isTime(s: []const u8) bool {
    if (s.len != 5 or s[2] != ':') return false;
    for ([_]usize{ 0, 1, 3, 4 }) |i| if (!std.ascii.isDigit(s[i])) return false;
    const h = (s[0] - '0') * 10 + (s[1] - '0');
    return h <= 23 and s[3] <= '5';
}

/// Express (same-hour) card: whether it is offered, its promise, limits, prices and hours.
fn parseExpress(r: *Req, body: Val) !Val {
    const a = r.a;
    const e = (try V.obj(r, body, "express", .{})).?;
    const enabled = (try V.boolean(r, e.get("enabled"), "express.enabled", .{})).?;
    var hours: Val = .null;
    const h = e.get("hours");
    if (!h.isNullish() and (h.get("from").truthy() or h.get("to").truthy())) {
        const from = (try V.str(r, h.get("from"), "express.hours.from", .{ .pattern = isTime })).?;
        const to = (try V.str(r, h.get("to"), "express.hours.to", .{ .pattern = isTime })).?;
        if (std.mem.eql(u8, from, to)) return r.badRequest("Opening and closing times must differ", "express.hours.to", "hours_same", null);
        hours = try val.from(a, .{ .from = from, .to = to });
    }
    return val.from(a, .{
        .enabled = enabled,
        .minutes = (try V.num(r, e.get("minutes"), "express.minutes", .{ .min = 15, .max = 360, .integer = true })).?,
        .maxKm = (try V.num(r, e.get("maxKm"), "express.maxKm", .{ .min = 1, .max = 200 })).?,
        .maxWeightKg = (try V.num(r, e.get("maxWeightKg"), "express.maxWeightKg", .{ .min = 0.5, .max = 1000 })).?,
        .base = (try V.num(r, e.get("base"), "express.base", .{ .min = 0, .max = 1e10 })).?,
        .perKm = (try V.num(r, if (e.get("perKm").isNullish()) Val{ .num = 0 } else e.get("perKm"), "express.perKm", .{ .min = 0, .max = 1e10 })).?,
        .hours = hours,
    });
}

/// Base prices for governorate pairs: one rule per pair (either direction).
fn parseRoutes(r: *Req, list: Val) !Val {
    const a = r.a;
    const out = try val.newArr(a);
    if (list.isNullish()) return out;
    var seen: std.ArrayList([]const u8) = .empty;
    for ((try V.arr(r, list, "pricing.routes", .{ .max = 200 })).?, 0..) |x, i| {
        const f = try std.fmt.allocPrint(a, "pricing.routes.{d}", .{i});
        _ = try V.obj(r, x, f, .{});
        const from = (try V.oneOf(r, x.get("from"), try std.fmt.allocPrint(a, "{s}.from", .{f}), geo.codes, .{})).?;
        const to = (try V.oneOf(r, x.get("to"), try std.fmt.allocPrint(a, "{s}.to", .{f}), geo.codes, .{})).?;
        const pair = if (std.mem.order(u8, from, to) == .gt) try std.fmt.allocPrint(a, "{s}-{s}", .{ to, from }) else try std.fmt.allocPrint(a, "{s}-{s}", .{ from, to });
        if (val.contains([]const u8, seen.items, pair)) return r.badRequest("This route is listed twice", try std.fmt.allocPrint(a, "{s}.to", .{f}), "route_twice", null);
        try seen.append(a, pair);
        try out.push(.{ .from = from, .to = to, .base = (try V.num(r, x.get("base"), try std.fmt.allocPrint(a, "{s}.base", .{f}), .{ .min = 0, .max = 1e10 })).? });
    }
    return out;
}

// ---- Hubs -----------------------------------------------------------------------------------------

const hub_types = [_][]const u8{ "hub", "branch", "pickup_point" };

/// /^[A-Za-z0-9-]+$/
fn isHubCode(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-')) return false;
    return true;
}

fn hubBody(r: *Req, b: Val, partial: bool) !Val {
    const a = r.a;
    const data = try val.newObj(a);
    if (try V.str(r, b.get("name"), "name", .{ .max = 80, .optional = partial })) |x| try data.set("name", x);
    if (try V.str(r, b.get("code"), "code", .{ .min = 2, .max = 10, .pattern = isHubCode, .optional = partial })) |x| try data.set("code", try val.upper(a, x));
    if (try V.oneOf(r, b.get("type"), "type", &hub_types, .{ .optional = partial })) |x| try data.set("type", x);
    if (try V.oneOf(r, b.get("governorate"), "governorate", geo.codes, .{ .optional = partial })) |x| try data.set("governorate", x);
    if (try V.str(r, b.get("city"), "city", .{ .max = 80, .optional = partial })) |x| try data.set("city", x);
    if (try V.str(r, b.get("address"), "address", .{ .max = 300, .optional = true })) |x| try data.set("address", x);
    if (try V.phone(r, b.get("phone"), "phone", .{ .optional = true })) |x| try data.set("phone", x);
    if (try V.point(r, b.get("location"), "location", .{ .optional = partial })) |x| try data.set("location", x);
    if (partial and b.get("active") != .undef) try data.set("active", (try V.boolean(r, b.get("active"), "active", .{})).?);
    return data;
}

fn hubView(a: Allocator, h: Val) !Val {
    return val.spread(a, .{ h, .{ .location = try web.toLatLng(a, h.get("location")) } });
}

/// Hub names appear on relay routes and tracking pages.
fn checkedHub(r: *Req, data: Val) !Val {
    if (data.get("name") != .undef or data.get("address") != .undef)
        _ = try moderation.check(r, moderation.subjectOf(r), .{ .type = "hub", .field = "name" }, try val.from(r.a, .{ .name = data.get("name"), .address = data.get("address") }), &.{});
    return data;
}

fn listHubs(r: *Req) !void {
    const out = try val.newArr(r.a);
    for (try carriers.listHubs(r.a, orgId(r), false)) |h| try out.push(try hubView(r.a, h));
    return r.json(200, out);
}

fn createHub(r: *Req) !void {
    const data = try checkedHub(r, try hubBody(r, r.body, false));
    return r.json(201, try hubView(r.a, try carriers.createHub(r, r.orgCtx(), data)));
}

fn updateHub(r: *Req) !void {
    const id = try idParam(r, "hubId");
    try carriers.updateHub(r, r.orgCtx(), id, try checkedHub(r, try hubBody(r, r.body, true)));
    return ok(r);
}

/// What is in a hub right now, and what each parcel needs next.
fn hubContents(r: *Req) !void {
    const a = r.a;
    const hub = try carriers.getHub(r, orgId(r), try idParam(r, "hubId"));
    const list = try db.col("shipments").find(a, .{ .carrierId = orgId(r), .@"custody.type" = "hub", .@"custody.hubId" = hub.get("_id"), .status = .{ .@"$nin" = &messages.final_statuses } }, .{ .sort = try val.from(a, .{ .statusAt = 1 }), .limit = 5000 });
    const today = try shipments.localToday(a);
    const out = try val.newArr(a);
    for (list) |s| {
        const st = s.s("status") orelse "";
        const next: []const u8 = if (std.mem.eql(u8, st, "returning"))
            "return"
        else if (relay.mustHandOver(s))
            "handover"
        else if (s.s("scheduledFor") != null and s.s("scheduledFor").?.len > 0 and std.mem.order(u8, s.s("scheduledFor").?, today) == .gt)
            "scheduled"
        else if (s.path("dropoff.governorate").eql(hub.get("governorate"))) "delivery" else "transfer";
        const cod = s.get("cod");
        try out.push(.{
            .id = s.get("_id"),
            .trackingNumber = s.get("trackingNumber"),
            .status = s.get("status"),
            .next = next,
            .planned = s.get("currentTaskId").truthy(),
            .since = s.get("statusAt"),
            .scheduledFor = if (s.t("scheduledFor")) s.get("scheduledFor") else Val.null,
            .merchantName = s.get("merchantName"),
            .dropoff = .{ .name = s.path("dropoff.name"), .governorate = s.path("dropoff.governorate"), .city = s.path("dropoff.city"), .area = if (s.path("dropoff.area").truthy()) s.path("dropoff.area") else Val.null },
            .weightKg = s.path("parcel.weightKg"),
            .cod = if (cod.truthy()) try val.from(a, .{ .amount = cod.get("amount"), .currency = cod.get("currency") }) else Val.null,
            .labelPath = if (s.t("labelToken")) Val{ .str = try std.fmt.allocPrint(a, "/label/{s}", .{try val.toStr(a, s.get("labelToken"))}) } else Val.null,
        });
    }
    return r.json(200, .{ .hub = try hubView(a, hub), .shipments = out });
}

fn checkIn(r: *Req) !void {
    const hub = try carriers.getHub(r, orgId(r), try idParam(r, "hubId"));
    if (!hub.t("active")) return r.badRequest("This hub is not active", null, "hub_inactive", null);
    const code = (try V.str(r, r.body.get("trackingNumber"), "trackingNumber", .{ .max = 40 })).?;
    // Our parcel, or a relay parcel another company is bringing to us.
    const shipment = try shipments.getShipmentForCarrier(r, orgId(r), code, false, true);
    return view(r, try ops.hubCheckIn(r, r.orgCtx(), hub, shipment));
}

// ---- Shipments ------------------------------------------------------------------------------------

/// Shipments that need someone to plan the next step; later-scheduled ones wait for their day.
fn needsAction(a: Allocator) !Val {
    return val.from(a, .{
        .status = .{ .@"$in" = .{ "awaiting_pickup", "at_hub", "delivery_failed", "returning" } },
        .currentTaskId = null,
        .@"$or" = .{ .{ .scheduledFor = null }, .{ .scheduledFor = .{ .@"$exists" = false } }, .{ .scheduledFor = .{ .@"$lte" = try shipments.localToday(a) } } },
    });
}

fn listShipments(r: *Req) !void {
    const a = r.a;
    const v = r.qs("view") orelse "";
    const filter = if (std.mem.eql(u8, v, "handed_over"))
        try val.from(a, .{ .carrierIds = orgId(r), .carrierId = .{ .@"$ne" = orgId(r) } })
    else
        try val.from(a, .{ .carrierId = orgId(r) });
    const merge = struct {
        fn f(dst: Val, src: Val) !void {
            for (src.obj.keys.items, src.obj.vals.items) |k, x| try dst.obj.put(k, x);
        }
    }.f;
    if (std.mem.eql(u8, v, "needs_action")) try merge(filter, try needsAction(a));
    if (std.mem.eql(u8, v, "scheduled")) try merge(filter, try val.from(a, .{ .scheduledFor = .{ .@"$gt" = try shipments.localToday(a) }, .status = .{ .@"$nin" = &messages.final_statuses } }));
    if (std.mem.eql(u8, v, "active")) try filter.set("status", .{ .@"$nin" = &messages.final_statuses });
    // Recipients reported a problem after delivery.
    if (std.mem.eql(u8, v, "problems")) try filter.set("feedback.problem", .{ .@"$type" = "string" });
    if (r.qs("hubId")) |h| if (h.len > 0) {
        try filter.set("custody.type", "hub");
        try filter.set("custody.hubId", (try V.id(r, .{ .str = h }, "hubId", .{})).?);
    };
    const status = if (r.qs("status")) |s| (if (s.len > 0) try V.oneOf(r, .{ .str = s }, "status", messages.status_list, .{}) else null) else null;
    const list = try shipments.listShipments(a, filter, .{
        .status = if (status) |s| Val{ .str = s } else .undef,
        .q = r.qs("q"),
        .before = common.dateQuery(r, "before"),
        .limit = @intFromFloat(val.jsMin(200, common.numberOr(r.q("limit"), 50))),
    });
    const out = try val.newArr(a);
    for (list) |s| try out.push(try shipments.carrierView(a, s, orgId(r)));
    return r.json(200, out);
}

fn getShipment(r: *Req) !void {
    const a = r.a;
    // Includes relay shipments this company already handed over (read-only history).
    const s = try shipments.getShipmentForCarrier(r, orgId(r), r.param("id"), true, false);
    const events = try shipments.eventsFor(a, s.get("_id"), true);
    const task_list = try db.col("tasks").find(a, .{ .shipmentIds = s.get("_id") }, .{ .sort = try val.from(a, .{ .createdAt = -1 }) });
    const ids = try val.newArr(a);
    for (task_list) |t| if (t.get("courierId").truthy()) try ids.push(t.get("courierId"));
    const couriers = try db.col("memberships").find(a, .{ ._id = .{ .@"$in" = ids } }, .{ .projection = try val.from(a, .{ .name = 1, .courier = 1 }) });
    const live = try shipments.liveCourierFor(a, s);
    const evs = try val.newArr(a);
    for (events) |e| try evs.push(try val.spread(a, .{ e, .{ .location = try web.toLatLng(a, e.get("location")), .textAr = try messages.eventText(a, e, "ar"), .textEn = try messages.eventText(a, e, "en") } }));
    const ts = try val.newArr(a);
    for (task_list) |t| {
        var name: Val = .null;
        for (couriers) |c| if (c.get("_id").sameId(t.get("courierId"))) {
            if (c.t("name")) name = c.get("name");
        };
        try ts.push(try val.spread(a, .{ t, .{ .courierName = name } }));
    }
    return r.json(200, .{
        .shipment = try shipments.carrierView(a, s, orgId(r)),
        .labelUrl = try std.fmt.allocPrint(a, "/label/{s}", .{try val.toStr(a, s.get("labelToken"))}),
        .events = evs,
        .tasks = ts,
        .courier = try shipments.courierLiveViewOpt(a, live, s),
    });
}

fn podPhoto(r: *Req) !void {
    const s = try shipments.getShipmentForCarrier(r, orgId(r), r.param("id"), true, false);
    if (!s.path("pod.photoId").truthy()) return r.notFound("Photo");
    return common.sendPhoto(r, s.path("pod.photoId"));
}

fn patchShipment(r: *Req) !void {
    const s = try shipments.getShipmentForCarrier(r, orgId(r), r.param("id"), false, false);
    return view(r, try shipments.updateDetails(r, s, r.body, try staff(r)));
}

fn reschedule(r: *Req) !void {
    const s = try shipments.getShipmentForCarrier(r, orgId(r), r.param("id"), false, false);
    const date = r.body.get("date");
    return view(r, try shipments.reschedule(r, s, if (date.isNullish()) Val.null else date, try staff(r)));
}

fn checkedNote(r: *Req, field: []const u8, optional: bool) !?[]const u8 {
    const note = try V.str(r, r.body.get("note"), "note", .{ .max = 500, .optional = optional });
    return moderation.checkedText(r, "note", note, .{ .type = "shipment", .id = r.param("id"), .field = field });
}

fn markLost(r: *Req) !void {
    const s = try shipments.getShipmentForCarrier(r, orgId(r), r.param("id"), false, false);
    return view(r, try claims.markLost(r, r.orgCtx(), s, try checkedNote(r, "lost", false)));
}

fn reportDamage(r: *Req) !void {
    const s = try shipments.getShipmentForCarrier(r, orgId(r), r.param("id"), true, false);
    return view(r, try claims.reportDamage(r, r.orgCtx(), s, try checkedNote(r, "damage", false)));
}

fn listClaims(r: *Req) !void {
    const filter = try val.from(r.a, .{ .carrierId = orgId(r) });
    if (r.qs("status")) |s| if (s.len > 0) try filter.set("status", (try V.oneOf(r, .{ .str = s }, "status", &.{ "open", "accepted", "rejected", "withdrawn" }, .{})).?);
    return r.json(200, try claims.listClaims(r.a, filter));
}

fn decideClaim(r: *Req) !void {
    return r.json(200, try claims.decideClaim(r, r.orgCtx(), try idParam(r, "claimId"), r.body));
}

fn addNote(r: *Req) !void {
    const s = try shipments.getShipmentForCarrier(r, orgId(r), r.param("id"), false, false);
    const note = (try V.str(r, r.body.get("note"), "note", .{ .max = 500 })).?;
    const visible = (try V.boolean(r, r.body.get("visibleToCustomer"), "visibleToCustomer", .{ .optional = true })) orelse false;
    _ = try ops.addNote(r, r.orgCtx(), s, note, visible);
    return ok(r);
}

fn manualDeliver(r: *Req) !void {
    const s = try shipments.getShipmentForCarrier(r, orgId(r), r.param("id"), false, false);
    const note = try checkedNote(r, "deliver", false);
    const receiver = try V.str(r, r.body.get("receiverName"), "receiverName", .{ .max = 120, .optional = true });
    const cod = try V.boolean(r, r.body.get("codCollected"), "codCollected", .{ .optional = true });
    return view(r, try ops.manualDeliver(r, r.orgCtx(), s, receiver, note, if (cod) |c| Val{ .bool = c } else .undef));
}

fn startReturn(r: *Req) !void {
    const s = try shipments.getShipmentForCarrier(r, orgId(r), r.param("id"), false, false);
    const note = try checkedNote(r, "return", true);
    return view(r, try ops.startReturn(r, r.orgCtx(), s, if (note) |n| Val{ .str = n } else .undef));
}

fn cancel(r: *Req) !void {
    const s = try shipments.getShipmentForCarrier(r, orgId(r), r.param("id"), false, false);
    const note = try checkedNote(r, "cancel", false);
    return view(r, try ops.carrierCancel(r, r.orgCtx(), s, if (note) |n| Val{ .str = n } else .undef));
}

// ---- Tasks / dispatch -----------------------------------------------------------------------------

fn taskInput(r: *Req, b: Val) !Val {
    const a = r.a;
    const ids = try val.newArr(a);
    for ((try V.arr(r, b.get("shipmentIds"), "shipmentIds", .{ .max = 500 })).?, 0..) |v, i| try ids.push(.{ .oid = (try V.id(r, v, try std.fmt.allocPrint(a, "shipmentIds[{d}]", .{i}), .{})).? });
    const out = try val.from(a, .{ .type = (try V.oneOf(r, b.get("type"), "type", &tasks.task_types, .{})).?, .shipmentIds = ids });
    if (try V.id(r, b.get("toHubId"), "toHubId", .{ .optional = true })) |h| try out.set("toHubId", h) else try out.set("toHubId", Val.undef);
    return out;
}

fn withNames(a: Allocator, list: []const Val) !Val {
    const ids = try val.newArr(a);
    const sids = try val.newArr(a);
    for (list) |t| {
        if (t.get("courierId").truthy()) try ids.push(t.get("courierId"));
        for (t.get("shipmentIds").items()) |s| try sids.push(s);
    }
    const couriers = try db.col("memberships").find(a, .{ ._id = .{ .@"$in" = ids } }, .{ .projection = try val.from(a, .{ .name = 1, .courier = 1 }) });
    const ships = try db.col("shipments").find(a, .{ ._id = .{ .@"$in" = sids } }, .{ .projection = try val.from(a, .{ .trackingNumber = 1, .status = 1, .@"dropoff.governorate" = 1, .@"dropoff.city" = 1 }) });
    const out = try val.newArr(a);
    for (list) |t| {
        var c: Val = .undef;
        for (couriers) |x| if (x.get("_id").sameId(t.get("courierId"))) {
            c = x;
            break;
        };
        const ss = try val.newArr(a);
        for (t.get("shipmentIds").items()) |id| for (ships) |s| if (s.get("_id").sameId(id)) {
            try ss.push(s);
            break;
        };
        try out.push(try val.spread(a, .{ t, .{
            .courierName = if (c.t("name")) c.get("name") else Val.null,
            .courierVehicle = if (c.path("courier.vehicle").truthy()) c.path("courier.vehicle") else Val.null,
            .from = try val.spread(a, .{ t.get("from"), .{ .location = try web.toLatLng(a, t.path("from.location")) } }),
            .to = try val.spread(a, .{ t.get("to"), .{ .location = try web.toLatLng(a, t.path("to.location")) } }),
            .shipments = ss,
        } }));
    }
    return out;
}

fn listTasks(r: *Req) !void {
    const a = r.a;
    const q = try val.from(a, .{ .carrierId = orgId(r) });
    const v = if (r.qs("view")) |x| (if (x.len > 0) x else "open") else "open";
    if (std.mem.eql(u8, v, "open")) {
        try q.set("status", .{ .@"$in" = .{ "pending", "assigned", "accepted", "in_progress" } });
    } else if (std.mem.eql(u8, v, "pending")) {
        try q.set("status", "pending");
    } else if (std.mem.eql(u8, v, "done")) try q.set("status", .{ .@"$in" = .{ "completed", "failed", "cancelled" } });
    if (r.qs("courierId")) |c| if (c.len > 0) try q.set("courierId", (try V.id(r, .{ .str = c }, "courierId", .{})).?);
    const list = try db.col("tasks").find(a, q, .{ .sort = try val.from(a, .{ .createdAt = -1 }), .limit = 200 });
    return r.json(200, try withNames(a, list));
}

fn planSuggestions(r: *Req) !void {
    const plan = try tasks.planTask(r, r.orgCtx().org, try taskInput(r, r.body));
    const t = try val.from(r.a, .{ .type = plan.type, .from = plan.from, .to = plan.to });
    return r.json(200, try tasks.suggestCouriers(r.a, orgId(r), t, plan.shipments));
}

fn createTask(r: *Req) !void {
    const input = try taskInput(r, r.body);
    if (try V.id(r, r.body.get("courierId"), "courierId", .{ .optional = true })) |c| try input.set("courierId", c);
    const task = try tasks.createTask(r, r.orgCtx().org, input, try staff(r));
    return r.json(201, (try withNames(r.a, &.{task})).at(0));
}

fn taskSuggestions(r: *Req) !void {
    const task = try tasks.getTask(r, orgId(r), try idParam(r, "taskId"));
    const list = try db.col("shipments").find(r.a, .{ ._id = .{ .@"$in" = task.get("shipmentIds") } }, .{});
    return r.json(200, try tasks.suggestCouriers(r.a, orgId(r), task, list));
}

fn assignTask(r: *Req) !void {
    const task = try tasks.getTask(r, orgId(r), try idParam(r, "taskId"));
    const updated = try tasks.assignTask(r, r.orgCtx().org, task, .{ .oid = (try V.id(r, r.body.get("courierId"), "courierId", .{})).? }, try staff(r));
    return r.json(200, (try withNames(r.a, &.{updated})).at(0));
}

fn cancelTask(r: *Req) !void {
    const task = try tasks.getTask(r, orgId(r), try idParam(r, "taskId"));
    return r.json(200, try tasks.cancelTask(r, r.orgCtx().org, task, try staff(r)));
}

// ---- Fleet ----------------------------------------------------------------------------------------

fn orNull(v: Val) Val {
    return if (v.isNullish()) .null else v;
}

fn fleet(r: *Req) !void {
    const a = r.a;
    const couriers = try tasks.listCouriers(a, orgId(r), false);
    const open = try db.col("tasks").aggregate(a, .{
        .{ .@"$match" = .{ .carrierId = orgId(r), .status = .{ .@"$in" = .{ "assigned", "accepted", "in_progress" } } } },
        .{ .@"$group" = .{ ._id = "$courierId", .n = .{ .@"$sum" = 1 }, .active = .{ .@"$sum" = .{ .@"$cond" = .{ .{ .@"$eq" = .{ "$status", "in_progress" } }, 1, 0 } } } } },
    });
    const out = try val.newArr(a);
    for (couriers) |c| {
        var o: Val = .undef;
        for (open) |x| if (x.get("_id").truthy() and x.get("_id").sameId(c.get("_id"))) {
            o = x;
        };
        try out.push(.{
            .courierId = c.get("_id"),
            .name = c.get("name"),
            .vehicle = c.path("courier.vehicle"),
            .plate = c.path("courier.plate"),
            .phone = c.path("courier.phone"),
            .onDuty = c.path("duty.onDuty").truthy(),
            .dutySince = if (c.path("duty.since").truthy()) c.path("duty.since") else Val.null,
            .location = try web.toLatLng(a, c.get("lastLocation")),
            .at = if (c.t("lastLocationAt")) c.get("lastLocationAt") else Val.null,
            .speedKmh = orNull(c.get("lastSpeedKmh")),
            .heading = orNull(c.get("lastHeading")),
            .battery = orNull(c.get("lastBattery")),
            .appState = if (c.path("appState.state").truthy()) c.path("appState.state") else Val.null,
            .appStateAt = if (c.path("appState.at").truthy()) c.path("appState.at") else Val.null,
            .openTasks = val.or0(o.get("n")),
            .activeTasks = val.or0(o.get("active")),
        });
    }
    return r.json(200, out);
}

fn fleetHistory(r: *Req) !void {
    const a = r.a;
    const courier_id = try idParam(r, "courierId");
    _ = (try db.col("memberships").findOne(a, .{ ._id = courier_id, .orgId = orgId(r) }, .{})) orelse return r.notFound("Courier");
    const to = if (r.qs("to")) |t| (if (t.len > 0) val.newDate(.{ .str = t }) else a_.nowMs()) else a_.nowMs();
    const from = if (r.qs("from")) |f| (if (f.len > 0) val.newDate(.{ .str = f }) else if (to) |tt| tt - 8 * 3600_000 else null) else if (to) |tt| tt - 8 * 3600_000 else null;
    if (from == null or to == null or to.? - from.? > 7 * 86400_000) return r.badRequest("Choose a time range of at most 7 days", null, "range_max", .{ .n = 7 });
    const points = try tracking.positionHistory(a, courier_id, from.?, to.?);
    const out = try val.newArr(a);
    for (points) |p| try out.push(try val.spread(a, .{ try web.toLatLng(a, p.get("location")), .{ .at = p.get("at"), .speedKmh = p.get("speedKmh") } }));
    return r.json(200, out);
}

// ---- Safety alerts --------------------------------------------------------------------------------

fn listAlerts(r: *Req) !void {
    const a = r.a;
    const status = if (r.qs("status")) |s| (if (s.len > 0) s else "open") else "open";
    const out = try val.newArr(a);
    for (try tracking.listAlerts(a, orgId(r), status)) |x| try out.push(try val.spread(a, .{ x, .{ .location = try web.toLatLng(a, x.get("location")) } }));
    return r.json(200, out);
}

fn updateAlert(r: *Req) !void {
    const alert = try tracking.updateAlert(r, r.orgCtx(), try idParam(r, "alertId"), (try V.oneOf(r, r.body.get("status"), "status", &.{ "acknowledged", "resolved" }, .{})).?, try V.str(r, r.body.get("note"), "note", .{ .max = 500, .optional = true }));
    return r.json(200, try val.spread(r.a, .{ alert, .{ .location = try web.toLatLng(r.a, alert.get("location")) } }));
}

/// SOS notifications on the caller's own device.
fn sosStatus(r: *Req) !void {
    const endpoint = try V.str(r, r.q("endpoint"), "endpoint", .{ .max = 2000, .optional = true });
    return r.json(200, try push.sosStatus(r.a, orgId(r), r.user, endpoint));
}

fn setSos(r: *Req) !void {
    const endpoint = (try V.str(r, r.body.get("endpoint"), "endpoint", .{ .max = 2000 })).?;
    const enabled = (try V.boolean(r, r.body.get("enabled"), "enabled", .{})).?;
    try push.setSosForDevice(r, orgId(r), r.user, endpoint, enabled);
    audit.audit(r.a, orgId(r), r.orgCtx().member, if (enabled) "alerts.device_on" else "alerts.device_off", .{ .name = r.orgCtx().member.get("name"), .device = val.jsSlice(r.header("user-agent") orelse "", 120) });
    return r.json(200, try push.sosStatus(r.a, orgId(r), r.user, endpoint));
}

// ---- Requests from individuals (direct shipping) --------------------------------------------------

fn requestOut(a: Allocator, s: Val) !Val {
    const idx: usize = @intFromFloat(s.path("offer.index").asNum() orelse 0);
    const cod = s.get("cod");
    return val.from(a, .{
        .id = s.get("_id"),
        .trackingNumber = s.get("trackingNumber"),
        .createdAt = s.get("createdAt"),
        .expiresAt = s.path("offer.expiresAt"),
        .price = s.path("offer.queue").at(idx).get("price"),
        .pickup = .{ .governorate = s.path("pickup.governorate"), .city = s.path("pickup.city"), .area = s.path("pickup.area"), .location = try web.toLatLng(a, s.path("pickup.location")) },
        .dropoff = .{ .governorate = s.path("dropoff.governorate"), .city = s.path("dropoff.city"), .area = s.path("dropoff.area") },
        .parcel = s.get("parcel"),
        .cod = if (cod.truthy()) try val.from(a, .{ .amount = cod.get("amount"), .currency = cod.get("currency") }) else Val.null,
        .notes = s.get("notes"),
    });
}

fn listRequests(r: *Req) !void {
    try direct.requireDirect(r);
    const out = try val.newArr(r.a);
    for (try direct.requestsFor(r.a, orgId(r))) |s| try out.push(try requestOut(r.a, s));
    return r.json(200, out);
}

fn acceptRequest(r: *Req) !void {
    try direct.requireDirect(r);
    return view(r, try direct.acceptRequest(r, r.orgCtx(), try idParam(r, "id")));
}

fn declineRequest(r: *Req) !void {
    try direct.requireDirect(r);
    _ = try direct.declineRequest(r, r.orgCtx(), try idParam(r, "id"), try V.str(r, r.body.get("reason"), "reason", .{ .max = 200, .optional = true }));
    return ok(r);
}

// ---- Own customers (private carriers) and blocked stores ------------------------------------------

fn listClients(r: *Req) !void {
    const a = r.a;
    const ids = r.orgCtx().org.path("carrier.clientMerchants");
    const list = try db.col("orgs").find(a, .{ ._id = .{ .@"$in" = if (ids == .arr) ids else try val.newArr(a) }, .type = "merchant" }, .{ .projection = try val.from(a, .{ .name = 1, .slug = 1, .status = 1 }), .sort = try val.from(a, .{ .name = 1 }) });
    const out = try val.newArr(a);
    for (list) |m| try out.push(.{ .id = m.get("_id"), .name = m.get("name"), .slug = m.get("slug"), .status = m.get("status") });
    return r.json(200, out);
}

fn addClient(r: *Req) !void {
    const a = r.a;
    var slug = try val.lower(a, (try V.str(r, r.body.get("store"), "store", .{ .max = 60 })).?);
    // "https://turf.example/o/my-store/..." or "my-store"
    if (std.mem.lastIndexOf(u8, slug, "/o/")) |i| slug = slug[i + 3 ..];
    if (std.mem.indexOfScalar(u8, slug, '/')) |i| slug = slug[0..i];
    const merchant = (try db.col("orgs").findOne(a, .{ .slug = slug, .type = "merchant" }, .{})) orelse return r.fail(404, "not_found", "No store with this address", .{ .field = "store" });
    _ = try db.col("orgs").updateOne(a, .{ ._id = orgId(r) }, .{ .@"$addToSet" = .{ .@"carrier.clientMerchants" = merchant.get("_id") }, .@"$set" = .{ .updatedAt = a_.now() } }, .{});
    audit.audit(a, orgId(r), r.orgCtx().member, "carrier.client_added", .{ .merchant = merchant.get("name") });
    return r.json(201, .{ .id = merchant.get("_id"), .name = merchant.get("name"), .slug = merchant.get("slug"), .status = merchant.get("status") });
}

fn removeClient(r: *Req) !void {
    const id = try idParam(r, "merchantId");
    _ = try db.col("orgs").updateOne(r.a, .{ ._id = orgId(r) }, .{ .@"$pull" = .{ .@"carrier.clientMerchants" = id }, .@"$set" = .{ .updatedAt = a_.now() } }, .{});
    audit.audit(r.a, orgId(r), r.orgCtx().member, "carrier.client_removed", .{ .merchantId = id });
    return ok(r);
}

fn listBlocked(r: *Req) !void {
    const a = r.a;
    const ids = r.orgCtx().org.path("carrier.blockedMerchants");
    const list = try db.col("orgs").find(a, .{ ._id = .{ .@"$in" = if (ids == .arr) ids else try val.newArr(a) } }, .{ .projection = try val.from(a, .{ .name = 1, .slug = 1, .personal = 1 }), .sort = try val.from(a, .{ .name = 1 }) });
    const out = try val.newArr(a);
    for (list) |m| try out.push(.{ .id = m.get("_id"), .name = m.get("name"), .slug = if (m.t("personal")) Val.null else m.get("slug"), .personal = m.t("personal") });
    return r.json(200, out);
}

/// A blocked store can no longer give this company new shipments; ones in progress continue.
fn block(r: *Req) !void {
    const a = r.a;
    const merchant_id: Val = .{ .oid = (try V.id(r, r.body.get("merchantId"), "merchantId", .{})).? };
    // Only stores this company has worked with can be blocked (no guessing other ids).
    const proj = try val.from(a, .{ ._id = 1 });
    const known = (try db.col("shipments").findOne(a, .{ .carrierIds = orgId(r), .merchantId = merchant_id }, .{ .projection = proj })) orelse
        (try db.col("shipments").findOne(a, .{ .carrierId = orgId(r), .merchantId = merchant_id }, .{ .projection = proj }));
    if (known == null) return r.notFound("Store");
    const merchant = (try db.col("orgs").findOne(a, .{ ._id = merchant_id, .type = "merchant" }, .{ .projection = try val.from(a, .{ .name = 1 }) })) orelse return r.notFound("Store");
    const reason = try V.str(r, r.body.get("reason"), "reason", .{ .max = 300, .optional = true });
    _ = try db.col("orgs").updateOne(a, .{ ._id = orgId(r) }, .{ .@"$addToSet" = .{ .@"carrier.blockedMerchants" = merchant_id }, .@"$set" = .{ .updatedAt = a_.now() } }, .{});
    audit.audit(a, orgId(r), r.orgCtx().member, "carrier.store_blocked", .{ .merchant = merchant.get("name"), .reason = if (reason) |x| (if (x.len > 0) Val{ .str = x } else Val.null) else Val.null });
    return r.json(201, .{ .ok = true });
}

fn unblock(r: *Req) !void {
    const id = try idParam(r, "merchantId");
    _ = try db.col("orgs").updateOne(r.a, .{ ._id = orgId(r) }, .{ .@"$pull" = .{ .@"carrier.blockedMerchants" = id }, .@"$set" = .{ .updatedAt = a_.now() } }, .{});
    audit.audit(r.a, orgId(r), r.orgCtx().member, "carrier.store_unblocked", .{ .merchantId = id });
    return ok(r);
}

// ---- Statements and cash on delivery --------------------------------------------------------------

fn financeStatements(r: *Req) !void {
    const p = try statements.periodOf(r, r.qs("from"), r.qs("to"));
    return r.json(200, .{ .from = p.from_text, .to = p.to_text, .merchants = try statements.counterparties(r.a, "carrier", orgId(r), p.from, p.to) });
}

fn financeStatement(r: *Req) !void {
    const p = try statements.periodOf(r, r.qs("from"), r.qs("to"));
    const merchant_id: Val = .{ .oid = (try V.id(r, r.q("merchantId"), "merchantId", .{})).? };
    const st = try statements.statement(r.a, orgId(r), merchant_id, p.from, p.to);
    if (std.mem.eql(u8, r.qs("format") orelse "", "csv")) {
        const name = try std.fmt.allocPrint(r.a, "statement-{s}-{s}-{s}.csv", .{ if (st.t("merchantName")) try val.toStr(r.a, st.get("merchantName")) else "store", p.from_text, p.to_text });
        return common.sendCsv(r, name, try statements.statementCsv(r.a, st, r.qs("lang") orelse "en"));
    }
    return r.json(200, try val.spread(r.a, .{ .{ .from = p.from_text, .to = p.to_text }, st }));
}

fn codSummary(r: *Req) !void {
    return r.json(200, try ops.codSummary(r.a, orgId(r)));
}

fn shipmentIds(r: *Req) !Val {
    const ids = try val.newArr(r.a);
    for ((try V.arr(r, r.body.get("shipmentIds"), "shipmentIds", .{ .max = 2000 })).?, 0..) |v, i| try ids.push(.{ .oid = (try V.id(r, v, try std.fmt.allocPrint(r.a, "shipmentIds[{d}]", .{i}), .{})).? });
    return ids;
}

fn settleCod(r: *Req) !void {
    return r.json(200, .{ .settled = try ops.settleCod(r, r.orgCtx(), try shipmentIds(r)) });
}

fn remitCod(r: *Req) !void {
    return r.json(200, .{ .remitted = try ops.remitCod(r, r.orgCtx(), try shipmentIds(r)) });
}

// ---- Dashboard ------------------------------------------------------------------------------------

fn stats(r: *Req) !void {
    const a = r.a;
    const id = orgId(r);
    // Midnight UTC (Turf-js uses the server's local midnight; the servers run in UTC).
    const start: Val = .{ .date = @divFloor(a_.nowMs(), 86400_000) * 86400_000 };
    const by_status = try db.col("shipments").aggregate(a, .{
        .{ .@"$match" = .{ .carrierId = id, .status = .{ .@"$nin" = &messages.final_statuses } } },
        .{ .@"$group" = .{ ._id = "$status", .n = .{ .@"$sum" = 1 } } },
    });
    const open = try val.newObj(a);
    for (by_status) |s| try open.obj.put(try val.toStr(a, s.get("_id")), s.get("n"));
    return r.json(200, .{
        .open = open,
        .createdToday = try db.col("shipments").count(a, .{ .carrierId = id, .createdAt = .{ .@"$gte" = start } }, .{}),
        .deliveredToday = try db.col("shipments").count(a, .{ .carrierId = id, .deliveredAt = .{ .@"$gte" = start } }, .{}),
        .onDuty = try db.col("memberships").count(a, .{ .orgId = id, .@"duty.onDuty" = true, .status = "active" }, .{}),
        .openAlerts = try db.col("alerts").count(a, .{ .carrierId = id, .status = .{ .@"$in" = .{ "open", "acknowledged" } } }, .{}),
        .pendingTasks = try db.col("tasks").count(a, .{ .carrierId = id, .status = "pending" }, .{}),
        .needsAction = try db.col("shipments").count(a, try val.spread(a, .{ .{ .carrierId = id }, try needsAction(a) }), .{}),
    });
}
