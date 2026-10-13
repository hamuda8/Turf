//! Merchant API v1 (src/routes/v1.js): server-to-server, authenticated with secret API keys,
//! documented at /developers.

const std = @import("std");
const val = @import("../lib/val.zig");
const web = @import("../web.zig");
const geo = @import("../geo.zig");
const messages = @import("../messages.zig");
const ratelimit = @import("../ratelimit.zig");
const realtime = @import("../realtime.zig");
const allocation = @import("../services/allocation.zig");
const shipments = @import("../services/shipments.zig");
const apikeys = @import("../services/apikeys.zig");
const testmode = @import("../services/testmode.zig");
const claims = @import("../services/claims.zig");
const places = @import("../services/places.zig");
const moderation = @import("../services/moderation.zig");
const shared = @import("merchant_shared.zig");
const Val = val.Val;
const Req = web.Req;
const V = web.V;
const route = web.route;
const routeMw = web.routeMw;

/// Express order: JSON body (2 MB: bulk uploads carry up to 500 shipments), reference data,
/// then the API key and the per-key rate limit, the routes, and the v1 404.
pub fn handle(r: *Req, path: []const u8) !void {
    try web.parseBody(r, 2 * 1024 * 1024);
    if (try web.runRoutes(r, &open_routes, path)) return;
    try apikeys.apiKeyAuth(r);
    try ratelimit.limit("v1", 60_000, 600, byKey)(r);
    if (try web.runRoutes(r, &key_routes, path)) return;
    const c = r.ctx.?;
    const url = if (c.query.len > 0) try std.fmt.allocPrint(r.a, "{s}?{s}", .{ c.path, c.query }) else c.path;
    return r.failf(404, "not_found", "No such endpoint: {s} {s}", .{ @tagName(c.method), url }, .{});
}

fn byKey(r: *Req) []const u8 {
    return val.toStr(r.a, r.api_key.get("_id")) catch "";
}

const open_routes = [_]web.Route{
    route(.GET, "/governorates", governorates),
    route(.GET, "/statuses", statuses),
};

const key_routes = [_]web.Route{
    route(.GET, "/carriers", carriers),
    route(.GET, "/places", listPlaces),
    route(.POST, "/quotes", quotes),
    route(.POST, "/shipments", create),
    routeMw(.POST, "/shipments/bulk", &.{ratelimit.limit("v1-bulk", 60_000, 10, byKey)}, bulkCreate),
    route(.GET, "/shipments", list),
    route(.GET, "/shipments/:id", get),
    route(.GET, "/shipments/:id/tracking", tracking),
    route(.GET, "/shipments/:id/stream", stream),
    route(.POST, "/shipments/:id/cancel", cancel),
    route(.PATCH, "/shipments/:id", patch),
    route(.POST, "/shipments/:id/reschedule", reschedule),
    route(.POST, "/shipments/:id/return-request", returnRequest),
    route(.POST, "/shipments/:id/claims", openClaim),
    route(.GET, "/claims", listClaims),
    route(.POST, "/shipments/:id/simulate", simulate),
};

fn governorates(r: *Req) !void {
    const out = try val.newArr(r.a);
    for (geo.governorates) |g| try out.push(.{ .code = g.code, .en = g.en, .ar = g.ar });
    return r.json(200, out);
}

fn statuses(r: *Req) !void {
    const a = r.a;
    const st = try val.newArr(a);
    for (messages.statuses) |s| try st.push(.{ .code = s.code, .en = s.en, .ar = s.ar });
    const fr = try val.newArr(a);
    for (messages.failure_reasons) |s| try fr.push(.{ .code = s.code, .en = s.en, .ar = s.ar });
    return r.json(200, .{ .statuses = st, .failureReasons = fr, .strategies = &allocation.strategies });
}

fn actor(r: *Req) !Val {
    return val.from(r.a, .{ .type = "api", .id = r.api_key.get("_id"), .name = r.api_key.get("name") });
}

fn testOnly(r: *Req) ?bool {
    return r.test_mode;
}

fn sendOut(r: *Req, s: Val) !void {
    return r.json(200, try shared.shipmentOut(r.a, s));
}

fn carriers(r: *Req) !void {
    if (r.test_mode) return r.json(200, .{ .data = .{.{ .id = testmode.test_carrier_id, .name = testmode.test_carrier_name, .slug = "turf-test", .@"test" = true }} });
    return r.json(200, .{ .data = try shared.listCarriersFor(r, r.merchant) });
}

/// The store's saved pickup places; pass an id as `pickup` when creating.
fn listPlaces(r: *Req) !void {
    const data = try val.newArr(r.a);
    for (try places.placesOf(r.a, r.merchant)) |p| try data.push(try places.placeView(r.a, p));
    return r.json(200, .{ .data = data });
}

fn quotes(r: *Req) !void {
    return r.json(200, try shared.quoteFor(r, r.merchant, r.body, r.test_mode));
}

fn create(r: *Req) !void {
    const res = try shared.createFor(r, r.merchant, r.body, try actor(r), r.test_mode);
    const created = res.t("created");
    try r.setHeader("idempotent-replayed", if (created) "false" else "true");
    return r.json(if (created) 201 else 200, res.get("shipment"));
}

/// Many shipments at once (up to 500): { rows: [shipment | flat CSV row] }.
fn bulkCreate(r: *Req) !void {
    return r.json(200, try shared.bulkFor(r, r.merchant, r.body, try actor(r), r.test_mode));
}

fn list(r: *Req) !void {
    return r.json(200, try shared.listFor(r, r.merchant, r.test_mode));
}

fn load(r: *Req) !Val {
    return shipments.getShipmentForMerchant(r, r.merchant.get("_id"), r.param("id"), testOnly(r));
}

fn get(r: *Req) !void {
    return sendOut(r, try load(r));
}

fn tracking(r: *Req) !void {
    return r.json(200, try shared.trackingFor(r, r.merchant, r.param("id"), shared.langOf(r), testOnly(r)));
}

fn stream(r: *Req) !void {
    const s = try load(r);
    const initial = try shared.trackingFor(r, r.merchant, r.param("id"), shared.langOf(r), testOnly(r));
    return realtime.subscribe(r, &.{realtime.chan(r.a, "shipment", s.get("_id"))}, "tracking", initial);
}

fn cancel(r: *Req) !void {
    const s = try load(r);
    const reason = try moderation.checkedText(r, "reason", try V.str(r, r.body.get("reason"), "reason", .{ .max = 300, .optional = true }), .{ .type = "shipment", .id = r.param("id"), .field = "cancel" });
    return sendOut(r, try shipments.cancelShipment(r, s, try actor(r), reason));
}

fn patch(r: *Req) !void {
    const s = try load(r);
    return sendOut(r, try shipments.updateDetails(r, s, r.body, try actor(r)));
}

fn reschedule(r: *Req) !void {
    const s = try load(r);
    const date = r.body.get("date");
    return sendOut(r, try shipments.reschedule(r, s, if (date.isNullish()) Val.null else date, try actor(r)));
}

/// The customer sends a delivered parcel back: creates a linked return shipment.
fn returnRequest(r: *Req) !void {
    const s = try load(r);
    return r.json(201, try shared.shipmentOut(r.a, try claims.requestCustomerReturn(r, r.merchant, s, r.body, try actor(r))));
}

fn openClaim(r: *Req) !void {
    const s = try load(r);
    return r.json(201, try claims.openClaim(r, r.merchant, s, r.body, try actor(r)));
}

fn listClaims(r: *Req) !void {
    return r.json(200, .{ .data = try claims.listClaims(r.a, try val.from(r.a, .{ .merchantId = r.merchant.get("_id") })) });
}

/// Test mode only: move a practice shipment to a status (same webhooks as real ones).
fn simulate(r: *Req) !void {
    if (!r.test_mode) return r.fail(403, "test_key_required", "Use a test key (turf_test_...) to simulate status changes", .{});
    const s = try shipments.getShipmentForMerchant(r, r.merchant.get("_id"), r.param("id"), true);
    const to = (try V.oneOf(r, r.body.get("to"), "to", testmode.simulate_targets, .{})).?;
    return sendOut(r, try testmode.simulate(r, s, to));
}
