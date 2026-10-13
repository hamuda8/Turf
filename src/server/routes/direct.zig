//! Direct shipping for individuals: the sender's API /api/app/direct (src/routes/app/direct.js).
//! Every endpoint answers 404 while the feature is switched off in Control.

const std = @import("std");
const val = @import("../lib/val.zig");
const web = @import("../web.zig");
const shipments = @import("../services/shipments.zig");
const direct = @import("../services/direct.zig");
const shared = @import("merchant_shared.zig");
const Val = val.Val;
const Req = web.Req;
const V = web.V;
const route = web.route;
const Allocator = std.mem.Allocator;

pub fn guard(r: *Req) !void {
    try direct.requireDirect(r);
}

pub const routes = [_]web.Route{
    route(.POST, "/quotes", quotes),
    route(.POST, "/shipments", create),
    route(.GET, "/shipments", list),
    route(.GET, "/shipments/:id", get),
    route(.POST, "/shipments/:id/cancel", cancel),
};

fn optionOut(a: Allocator, m: Val) !Val {
    return val.from(a, .{
        .carrier = .{ .id = m.path("carrier._id"), .name = m.path("carrier.name") },
        .price = .{ .amount = m.path("quote.amount"), .currency = m.path("quote.currency") },
        .etaHours = m.path("metrics.etaHours"),
        .reliability = m.path("metrics.reliability"),
    });
}

fn senderView(a: Allocator, s: Val, events: []const Val, live: ?shipments.Live, lang: []const u8) !Val {
    const view = try val.spread(a, .{ .{ .id = s.get("_id") }, try shipments.trackingView(a, s, events, live, lang, "merchant"), try shared.links(a, s) });
    try view.set("price", s.get("price"));
    try view.set("parcel", s.get("parcel"));
    try view.set("createdAt", s.get("createdAt"));
    // While companies are being asked: who and until when (never who declined).
    if (std.mem.eql(u8, s.s("status") orelse "", "awaiting_carrier")) {
        const idx = s.path("offer.index").asNum() orelse 0;
        const cur = s.path("offer.queue").at(@intFromFloat(idx));
        try view.set("offer", .{
            .carrierName = if (cur.t("carrierName")) cur.get("carrierName") else Val.null,
            .expiresAt = s.path("offer.expiresAt"),
            .position = idx + 1,
            .of = s.path("offer.queue").items().len,
        });
    } else try view.set("offer", null);
    return view;
}

fn quotes(r: *Req) !void {
    const org = try direct.personalOrg(r, r.user);
    const input = try shipments.prepareShipmentInput(r, r.body, org, false);
    const out = try val.newArr(r.a);
    for (try direct.quoteDirect(r, org, input)) |m| try out.push(try optionOut(r.a, m));
    return r.json(200, .{ .options = out });
}

fn create(r: *Req) !void {
    const org = try direct.personalOrg(r, r.user);
    const input = try shipments.prepareShipmentInput(r, r.body, org, false);
    const s = try direct.createDirectRequest(r, r.user, org, input);
    return r.json(201, try senderView(r.a, s, &.{}, null, shared.langOf(r)));
}

fn list(r: *Req) !void {
    const a = r.a;
    const org = try direct.personalOrg(r, r.user);
    const items = try shipments.listShipments(a, try val.from(a, .{ .merchantId = org.get("_id") }), .{ .limit = 100 });
    const out = try val.newArr(a);
    for (items) |s| try out.push(.{
        .id = s.get("_id"),
        .trackingNumber = s.get("trackingNumber"),
        .status = s.get("status"),
        .carrierName = s.get("carrierName"),
        .dropoff = .{ .name = s.path("dropoff.name"), .phone = s.path("dropoff.phone"), .city = s.path("dropoff.city"), .governorate = s.path("dropoff.governorate") },
        .price = s.get("price"),
        .createdAt = s.get("createdAt"),
    });
    return r.json(200, out);
}

fn get(r: *Req) !void {
    const a = r.a;
    const org = try direct.personalOrg(r, r.user);
    const s = try shipments.getShipmentForMerchant(r, org.get("_id"), (try V.str(r, .{ .str = r.param("id") }, "id", .{ .max = 40 })).?, null);
    const events = try shipments.eventsFor(a, s.get("_id"), false);
    const live = try shipments.liveCourierFor(a, s);
    return r.json(200, try senderView(a, s, events, live, shared.langOf(r)));
}

fn cancel(r: *Req) !void {
    const a = r.a;
    const org = try direct.personalOrg(r, r.user);
    const s = try shipments.getShipmentForMerchant(r, org.get("_id"), (try V.str(r, .{ .str = r.param("id") }, "id", .{ .max = 40 })).?, null);
    const updated = try direct.cancelDirect(r, r.user, s);
    return r.json(200, try senderView(a, updated, try shipments.eventsFor(a, updated.get("_id"), false), null, shared.langOf(r)));
}
