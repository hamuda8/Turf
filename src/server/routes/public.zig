//! Public tracking API /api/public (src/routes/public.js), addressed by a shipment's secret
//! tracking token. Open CORS so storefronts can call it from the browser without API keys;
//! /lookup finds parcels by tracking number with less detail.

const std = @import("std");
const val = @import("../lib/val.zig");
const db = @import("../lib/db.zig");
const web = @import("../web.zig");
const ratelimit = @import("../ratelimit.zig");
const realtime = @import("../realtime.zig");
const shipments = @import("../services/shipments.zig");
const branding = @import("../services/branding.zig");
const errors = @import("../services/errors.zig");
const platform = @import("../services/platform.zig");
const feedback = @import("../services/feedback.zig");
const shared = @import("merchant_shared.zig");
const Val = val.Val;
const Req = web.Req;
const V = web.V;
const route = web.route;
const routeMw = web.routeMw;
const Allocator = std.mem.Allocator;

pub fn handle(r: *Req, path: []const u8) !void {
    try r.setHeader("access-control-allow-origin", "*");
    try r.setHeader("access-control-allow-methods", "GET, POST, OPTIONS");
    try r.setHeader("access-control-allow-headers", "Content-Type");
    if (r.method() == .OPTIONS) return r.send(204, "text/plain; charset=utf-8", "");
    try web.parseBody(r, 10 * 1024);
    try ratelimit.limit("public", 60_000, 120, null)(r);
    if (try web.runRoutes(r, &routes, path)) return;
    return r.fail(404, "not_found", "Not found", .{});
}

const routes = [_]web.Route{
    route(.GET, "/platform", platformInfo),
    routeMw(.POST, "/client-errors", &.{ratelimit.limit("client-errors", 60_000, 10, null)}, clientErrors),
    routeMw(.GET, "/lookup", &.{ratelimit.limit("lookup", 60_000, 20, null)}, lookup),
    route(.GET, "/track/:token", track),
    route(.GET, "/track/:token/stream", trackStream),
    routeMw(.POST, "/track/:token/location", &.{ratelimit.limit("recipient-location", 3600_000, 10, null)}, setLocation),
    routeMw(.POST, "/track/:token/reschedule", &.{ratelimit.limit("recipient-reschedule", 3600_000, 10, null)}, reschedule),
    routeMw(.POST, "/track/:token/feedback", &.{ratelimit.limit("recipient-feedback", 3600_000, 10, null)}, sendFeedback),
};

/// Switched-on features and the announcement, for public pages.
fn platformInfo(r: *Req) !void {
    try r.setHeader("cache-control", "public, max-age=30");
    return r.json(200, try platform.publicInfo(r.a));
}

/// Browser errors from our pages. Strict per-IP limit.
fn clientErrors(r: *Req) !void {
    const b = r.body;
    const str = struct {
        fn f(v: Val, max: usize) []const u8 {
            return if (v.asStr()) |s| val.jsSlice(s, max) else "";
        }
    }.f;
    const message = str(b.get("message"), 500);
    if (message.len > 0) errors.recordError(r.a, "browser", message, str(b.get("stack"), 4000), str(b.get("page"), 300));
    return r.end(204);
}

/// Up to max_lookup tracking numbers at once, answered in the order asked.
const max_lookup = 10;

fn lookup(r: *Req) !void {
    const a = r.a;
    const n = r.q("n");
    const text = if (n.isNullish()) "" else try val.toStr(a, n);
    const asked = try shipments.splitTrackingNumbers(a, text);
    if (asked.len == 0) return r.badRequest("n is required: one or more tracking numbers", "n", "required", null);
    if (asked.len > max_lookup) return r.badRequest(try std.fmt.allocPrint(a, "At most {d} tracking numbers at once", .{max_lookup}), "n", "lookup_max", .{ .n = max_lookup });
    var numbers: std.ArrayList(?[]const u8) = .empty;
    const wanted = try val.newArr(a);
    for (asked) |x| {
        const nn = try shipments.normalizeTrackingNumber(a, x);
        try numbers.append(a, nn);
        if (nn) |v| try wanted.push(v);
    }
    const found = try db.col("shipments").find(a, .{ .trackingNumber = .{ .@"$in" = wanted } }, .{});
    const cids = try val.newArr(a);
    for (found) |s| if (s.get("carrierId").truthy()) try cids.push(s.get("carrierId"));
    const carriers = try db.col("orgs").find(a, .{ ._id = .{ .@"$in" = cids } }, .{ .projection = try val.from(a, .{ .branding = 1, .contact = 1, .slug = 1, .name = 1 }) });
    const results = try val.newArr(a);
    for (asked, numbers.items) |raw, num| {
        var s: Val = .undef;
        if (num) |nv| for (found) |x| if (std.mem.eql(u8, x.s("trackingNumber") orelse "", nv)) {
            s = x;
            break;
        };
        if (s == .undef) {
            try results.push(.{ .query = raw, .found = false });
            continue;
        }
        const v = try shipments.lookupView(a, s, try shipments.eventsFor(a, s.get("_id"), false));
        var carrier: Val = .undef;
        if (s.get("carrierId").truthy()) for (carriers) |c| if (c.get("_id").sameId(s.get("carrierId"))) {
            carrier = c;
        };
        const b = if (carrier != .undef) try branding.publicBranding(a, carrier) else Val.null;
        try v.set("carrier", .{ .name = s.get("carrierName"), .phone = if (carrier.path("contact.phone").truthy()) carrier.path("contact.phone") else Val.null, .logoUrl = if (b.get("logoUrl").truthy()) b.get("logoUrl") else Val.null });
        try results.push(try val.spread(a, .{ .{ .query = raw, .found = true }, v }));
    }
    try r.setHeader("cache-control", "no-store");
    return r.json(200, .{ .results = results });
}

fn byToken(r: *Req, token: []const u8) !Val {
    const valid = token.len >= 16 and token.len <= 40 and for (token) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) break false;
    } else true;
    if (!valid) return r.notFound("Shipment");
    return (try db.col("shipments").findOne(r.a, .{ .publicToken = token }, .{})) orelse r.notFound("Shipment");
}

pub fn publicTracking(a: Allocator, s: Val, lang: []const u8) !Val {
    const events = try shipments.eventsFor(a, s.get("_id"), false);
    const live = try shipments.liveCourierFor(a, s);
    const carrier = try db.col("orgs").findOne(a, .{ ._id = s.get("carrierId") }, .{ .projection = try val.from(a, .{ .name = 1, .slug = 1, .branding = 1, .contact = 1 }) });
    const view = try shipments.trackingView(a, s, events, live, lang, "public");
    const b = if (carrier) |c| try branding.publicBranding(a, c) else Val.null;
    try view.set("carrier", .{
        .name = s.get("carrierName"),
        .phone = if (carrier) |c| (if (c.path("contact.phone").truthy()) c.path("contact.phone") else Val.null) else Val.null,
        .logoUrl = if (b.get("logoUrl").truthy()) b.get("logoUrl") else Val.null,
        .primaryColor = if (b.get("primaryColor").truthy()) b.get("primaryColor") else Val.null,
        .onPrimary = if (b.get("onPrimary").truthy()) b.get("onPrimary") else Val.null,
    });
    const st = s.s("status") orelse "";
    try view.set("canSetLocation", val.contains([]const u8, &.{ "awaiting_pickup", "picked_up", "at_hub", "in_transit", "out_for_delivery", "delivery_failed" }, st));
    try view.set("locationShared", std.mem.eql(u8, s.path("dropoff.locationSource").asStr() orelse "", "recipient"));
    // The recipient may choose another delivery day until the parcel is out for delivery.
    try view.set("canReschedule", val.contains([]const u8, &.{ "awaiting_pickup", "picked_up", "at_hub", "in_transit", "delivery_failed" }, st));
    const fb = try feedback.feedbackView(a, s);
    for (fb.obj.keys.items, fb.obj.vals.items) |k, x| try view.obj.put(k, x);
    return view;
}

fn track(r: *Req) !void {
    const s = try byToken(r, r.param("token"));
    try r.setHeader("cache-control", "no-store");
    return r.json(200, try publicTracking(r.a, s, shared.langOf(r)));
}

fn trackStream(r: *Req) !void {
    const s = try byToken(r, r.param("token"));
    return realtime.subscribe(r, &.{realtime.chan(r.a, "shipment", s.get("_id"))}, "tracking", try publicTracking(r.a, s, shared.langOf(r)));
}

fn setLocation(r: *Req) !void {
    const s = try byToken(r, r.param("token"));
    const point = (try V.point(r, r.body, "location", .{})).?;
    _ = try shipments.setRecipientLocation(r, s, point);
    return r.json(200, .{ .ok = true });
}

/// The recipient chooses the day they can receive the parcel.
fn reschedule(r: *Req) !void {
    const s = try byToken(r, r.param("token"));
    const date = r.body.get("date");
    const updated = try shipments.reschedule(r, s, if (date.isNullish()) Val.null else date, try val.from(r.a, .{ .type = "recipient" }));
    return r.json(200, .{ .ok = true, .scheduledFor = if (updated.t("scheduledFor")) updated.get("scheduledFor") else Val.null });
}

/// After delivery: a rating and/or a problem report, once.
fn sendFeedback(r: *Req) !void {
    const s = try byToken(r, r.param("token"));
    const updated = try feedback.submitFeedback(r, s, r.body);
    return r.json(200, try val.spread(r.a, .{ .{ .ok = true }, try feedback.feedbackView(r.a, updated) }));
}
