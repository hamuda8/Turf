//! Merchant dashboard API /api/app/orgs/:orgId/merchant (src/routes/app/merchant.js): pickup
//! places, shipments, quotes, API keys, webhooks, statements, settings.

const std = @import("std");
const val = @import("../lib/val.zig");
const db = @import("../lib/db.zig");
const web = @import("../web.zig");
const a_ = @import("../app.zig");
const messages = @import("../messages.zig");
const allocation = @import("../services/allocation.zig");
const shipments = @import("../services/shipments.zig");
const apikeys = @import("../services/apikeys.zig");
const webhooks = @import("../services/webhooks.zig");
const audit = @import("../services/audit.zig");
const statements = @import("../services/statements.zig");
const claims = @import("../services/claims.zig");
const places = @import("../services/places.zig");
const emails = @import("../services/emails.zig");
const moderation = @import("../services/moderation.zig");
const shared = @import("merchant_shared.zig");
const common = @import("common.zig");
const Val = val.Val;
const Req = web.Req;
const V = web.V;
const route = web.route;
const routeMw = web.routeMw;
const need = web.need;
const needAny = web.needAny;

pub const routes = [_]web.Route{
    routeMw(.GET, "/places", &.{needAny(&.{ "shipments.create", "shipments.view", "org.settings" })}, listPlaces),
    routeMw(.POST, "/places", &.{needAny(&.{ "org.settings", "shipments.create" })}, addPlace),
    routeMw(.PATCH, "/places/:id", &.{needAny(&.{ "org.settings", "shipments.create" })}, updatePlace),
    routeMw(.POST, "/places/:id/default", &.{need(&.{"org.settings"})}, defaultPlace),
    routeMw(.DELETE, "/places/:id", &.{need(&.{"org.settings"})}, removePlace),
    routeMw(.PATCH, "/settings", &.{need(&.{"org.settings"})}, settings),
    routeMw(.GET, "/carriers", &.{need(&.{"shipments.view"})}, carriers),
    routeMw(.POST, "/quotes", &.{need(&.{"shipments.create"})}, quotes),
    routeMw(.POST, "/shipments/bulk", &.{need(&.{"shipments.create"})}, bulkCreate),
    routeMw(.POST, "/shipments", &.{need(&.{"shipments.create"})}, create),
    routeMw(.GET, "/shipments", &.{need(&.{"shipments.view"})}, listShipments),
    routeMw(.GET, "/shipments/:id", &.{need(&.{"shipments.view"})}, get),
    routeMw(.GET, "/shipments/:id/pod-photo", &.{need(&.{"shipments.view"})}, podPhoto),
    routeMw(.POST, "/shipments/:id/cancel", &.{need(&.{"shipments.cancel"})}, cancel),
    routeMw(.GET, "/reports", &.{needAny(&.{ "shipments.view", "finance.view" })}, common.reportFor("merchant")),
    routeMw(.GET, "/reports/shipments", &.{needAny(&.{ "shipments.view", "finance.view" })}, common.reportRowsFor("merchant")),
    routeMw(.GET, "/stats", &.{need(&.{"shipments.view"})}, stats),
    routeMw(.PATCH, "/shipments/:id", &.{need(&.{"shipments.create"})}, patch),
    routeMw(.POST, "/shipments/:id/reschedule", &.{need(&.{"shipments.create"})}, reschedule),
    routeMw(.POST, "/shipments/:id/return-request", &.{need(&.{"shipments.create"})}, returnRequest),
    routeMw(.GET, "/claims", &.{need(&.{"shipments.view"})}, listClaims),
    routeMw(.POST, "/shipments/:id/claims", &.{need(&.{"shipments.create"})}, openClaim),
    routeMw(.POST, "/claims/:claimId/withdraw", &.{need(&.{"shipments.create"})}, withdrawClaim),
    routeMw(.GET, "/statements", &.{need(&.{"finance.view"})}, listStatements),
    routeMw(.GET, "/statement", &.{need(&.{"finance.view"})}, statement),
    routeMw(.GET, "/api-keys", &.{need(&.{"api.manage"})}, listKeys),
    routeMw(.POST, "/api-keys", &.{need(&.{"api.manage"})}, createKey),
    routeMw(.DELETE, "/api-keys/:keyId", &.{need(&.{"api.manage"})}, revokeKey),
    routeMw(.GET, "/webhook", &.{need(&.{"api.manage"})}, getWebhook),
    routeMw(.PUT, "/webhook", &.{need(&.{"api.manage"})}, setWebhook),
    routeMw(.DELETE, "/webhook", &.{need(&.{"api.manage"})}, deleteWebhook),
    routeMw(.POST, "/webhook/rotate", &.{need(&.{"api.manage"})}, rotateWebhook),
    routeMw(.POST, "/webhook/test", &.{need(&.{"api.manage"})}, testWebhook),
};

fn org(r: *Req) Val {
    return r.orgCtx().org;
}

fn actor(r: *Req) !Val {
    return val.from(r.a, .{ .type = "user", .id = r.orgCtx().member.get("userId"), .name = r.orgCtx().member.get("name") });
}

fn ok(r: *Req) !void {
    return r.json(200, .{ .ok = true });
}

fn out(r: *Req, s: Val) !void {
    return r.json(200, try shared.shipmentOut(r.a, s));
}

// ---- Pickup places ---------------------------------------------------------------------------------

/// Pickup places are copied onto shipments, where couriers read them.
fn checkedPlace(r: *Req, place: Val) !Val {
    _ = try moderation.check(r, moderation.subjectOf(r), .{ .type = "place", .field = "label" }, try val.from(r.a, .{
        .label = place.get("label"),
        .name = place.get("name"),
        .area = place.get("area"),
        .street = place.get("street"),
        .details = place.get("details"),
    }), &.{});
    return place;
}

fn listPlaces(r: *Req) !void {
    const list = try val.newArr(r.a);
    for (try places.placesOf(r.a, org(r))) |p| try list.push(try places.placeView(r.a, p));
    return r.json(200, list);
}

fn parsedPlace(r: *Req) !Val {
    const body = (try V.obj(r, r.body, "place", .{})).?;
    const place = try checkedPlace(r, try places.parsePlace(r, body, shipments.parse_address_fn));
    try place.set("isDefault", (try V.boolean(r, body.get("isDefault"), "place.isDefault", .{ .optional = true })) orelse false);
    return place;
}

fn addPlace(r: *Req) !void {
    const doc = try places.addPlace(r, org(r), try parsedPlace(r));
    audit.audit(r.a, org(r).get("_id"), r.orgCtx().member, "merchant.place_added", .{ .id = doc.get("_id"), .label = doc.get("label") });
    return r.json(201, try places.placeView(r.a, doc));
}

fn placeId(r: *Req) !Val {
    return .{ .oid = (try V.id(r, .{ .str = r.param("id") }, "id", .{})).? };
}

fn updatePlace(r: *Req) !void {
    const place = try parsedPlace(r);
    const doc = try places.updatePlace(r, org(r), try placeId(r), place);
    return r.json(200, try places.placeView(r.a, doc));
}

fn defaultPlace(r: *Req) !void {
    try places.setDefaultPlace(r, org(r), try placeId(r));
    return ok(r);
}

fn removePlace(r: *Req) !void {
    try places.removePlace(r, org(r), try placeId(r));
    audit.audit(r.a, org(r).get("_id"), r.orgCtx().member, "merchant.place_removed", .{ .id = r.param("id") });
    return ok(r);
}

fn settings(r: *Req) !void {
    const a = r.a;
    const b = (try V.obj(r, r.body, "body", .{})).?;
    const set = try val.newObj(a);
    var place_saved = false;
    if (b.get("website") != .undef) try set.set("merchant.website", if (b.get("website").truthy()) Val{ .str = (try V.url(r, b.get("website"), "website", .{})).? } else Val.null);
    if (b.get("defaultStrategy") != .undef) try set.set("merchant.defaultStrategy", (try V.oneOf(r, b.get("defaultStrategy"), "defaultStrategy", &allocation.strategies, .{})).?);
    if (b.get("defaultPickup").truthy()) {
        // Older clients: the default address becomes (or replaces) the default pickup place.
        const place = try places.parsePlace(r, b.get("defaultPickup"), shipments.parse_address_fn);
        const current = try places.defaultPlace(a, org(r));
        const with_default = try val.spread(a, .{ place, .{ .isDefault = true } });
        if (current.truthy() and !(current.get("_id") == .str and std.mem.eql(u8, current.s("_id").?, "default"))) {
            _ = try places.updatePlace(r, org(r), current.get("_id"), with_default);
        } else _ = try places.addPlace(r, org(r), with_default);
        place_saved = true;
    }
    if (b.get("emailNotifications") != .undef) {
        // Field by field, so the daily summary's bookkeeping (lastSummaryDay) is kept.
        const e = try emails.parseEmailSettings(r, b.get("emailNotifications"));
        for (e.obj.keys.items, e.obj.vals.items) |k, v| try set.set(try std.fmt.allocPrint(a, "merchant.emailNotifications.{s}", .{k}), v);
    }
    if (set.obj.count() == 0 and !place_saved) return r.badRequest("Nothing to update", null, "nothing_to_update", null);
    const keys = try val.newArr(a);
    for (set.obj.keys.items) |k| try keys.push(k);
    if (set.obj.count() > 0) _ = try db.col("orgs").updateOne(a, .{ ._id = org(r).get("_id") }, .{ .@"$set" = try val.spread(a, .{ set, .{ .updatedAt = a_.now() } }) }, .{});
    audit.audit(a, org(r).get("_id"), r.orgCtx().member, "merchant.settings_updated", keys);
    return ok(r);
}

// ---- Shipping --------------------------------------------------------------------------------------

fn carriers(r: *Req) !void {
    return r.json(200, try shared.listCarriersFor(r, org(r)));
}

fn quotes(r: *Req) !void {
    return r.json(200, try shared.quoteFor(r, org(r), r.body, false));
}

fn bulkCreate(r: *Req) !void {
    return r.json(200, try shared.bulkFor(r, org(r), r.body, try actor(r), false));
}

fn create(r: *Req) !void {
    const res = try shared.createFor(r, org(r), r.body, try actor(r), false);
    return r.json(if (res.t("created")) 201 else 200, res.get("shipment"));
}

fn listShipments(r: *Req) !void {
    return r.json(200, try shared.listFor(r, org(r), std.mem.eql(u8, r.qs("test") orelse "", "1")));
}

fn get(r: *Req) !void {
    const s = try shipments.getShipmentForMerchant(r, org(r).get("_id"), r.param("id"), null);
    return r.json(200, .{ .shipment = try shared.shipmentOut(r.a, s), .tracking = try shared.trackingFor(r, org(r), r.param("id"), shared.langOf(r), null) });
}

fn podPhoto(r: *Req) !void {
    const s = try shipments.getShipmentForMerchant(r, org(r).get("_id"), r.param("id"), null);
    if (!s.path("pod.photoId").truthy()) return r.notFound("Photo");
    return common.sendPhoto(r, s.path("pod.photoId"));
}

fn cancel(r: *Req) !void {
    const s = try shipments.getShipmentForMerchant(r, org(r).get("_id"), r.param("id"), null);
    const reason = try moderation.checkedText(r, "reason", try V.str(r, r.body.get("reason"), "reason", .{ .max = 300, .optional = true }), .{ .type = "shipment", .id = r.param("id"), .field = "cancel" });
    return out(r, try shipments.cancelShipment(r, s, try actor(r), reason));
}

fn stats(r: *Req) !void {
    const a = r.a;
    const id = org(r).get("_id");
    const by_status = try db.col("shipments").aggregate(a, .{
        .{ .@"$match" = .{ .merchantId = id, .status = .{ .@"$nin" = &messages.final_statuses } } },
        .{ .@"$group" = .{ ._id = "$status", .n = .{ .@"$sum" = 1 } } },
    });
    const last30 = try db.col("shipments").aggregate(a, .{
        .{ .@"$match" = .{ .merchantId = id, .createdAt = .{ .@"$gte" = val.Date{ .ms = a_.nowMs() - 30 * 86400_000 } } } },
        .{ .@"$group" = .{ ._id = "$status", .n = .{ .@"$sum" = 1 } } },
    });
    const cod = try db.col("shipments").aggregate(a, .{
        .{ .@"$match" = .{ .merchantId = id, .@"cod.collectedAt" = .{ .@"$ne" = null }, .@"cod.remittedAt" = null } },
        .{ .@"$group" = .{ ._id = "$cod.currency", .amount = .{ .@"$sum" = "$cod.amount" }, .count = .{ .@"$sum" = 1 } } },
    });
    const open = try val.newObj(a);
    for (by_status) |s| try open.obj.put(try val.toStr(a, s.get("_id")), s.get("n"));
    const recent = try val.newObj(a);
    for (last30) |s| try recent.obj.put(try val.toStr(a, s.get("_id")), s.get("n"));
    const awaiting = try val.newArr(a);
    for (cod) |c| try awaiting.push(.{ .currency = c.get("_id"), .amount = c.get("amount"), .count = c.get("count") });
    return r.json(200, .{ .open = open, .last30Days = recent, .codAwaitingPayout = awaiting });
}

fn patch(r: *Req) !void {
    const s = try shipments.getShipmentForMerchant(r, org(r).get("_id"), r.param("id"), null);
    return out(r, try shipments.updateDetails(r, s, r.body, try actor(r)));
}

fn reschedule(r: *Req) !void {
    const s = try shipments.getShipmentForMerchant(r, org(r).get("_id"), r.param("id"), null);
    const date = r.body.get("date");
    return out(r, try shipments.reschedule(r, s, if (date.isNullish()) Val.null else date, try actor(r)));
}

fn returnRequest(r: *Req) !void {
    const s = try shipments.getShipmentForMerchant(r, org(r).get("_id"), r.param("id"), null);
    const ret = try claims.requestCustomerReturn(r, org(r), s, r.body, try actor(r));
    return r.json(201, try shared.shipmentOut(r.a, ret));
}

fn listClaims(r: *Req) !void {
    return r.json(200, try claims.listClaims(r.a, try val.from(r.a, .{ .merchantId = org(r).get("_id") })));
}

fn openClaim(r: *Req) !void {
    const s = try shipments.getShipmentForMerchant(r, org(r).get("_id"), r.param("id"), null);
    return r.json(201, try claims.openClaim(r, org(r), s, r.body, try actor(r)));
}

fn withdrawClaim(r: *Req) !void {
    try claims.withdrawClaim(r, org(r).get("_id"), .{ .oid = (try V.id(r, .{ .str = r.param("claimId") }, "claimId", .{})).? });
    return ok(r);
}

// ---- Statements -------------------------------------------------------------------------------------

fn listStatements(r: *Req) !void {
    const p = try statements.periodOf(r, r.qs("from"), r.qs("to"));
    return r.json(200, .{ .from = p.from_text, .to = p.to_text, .carriers = try statements.counterparties(r.a, "merchant", org(r).get("_id"), p.from, p.to) });
}

fn statement(r: *Req) !void {
    const p = try statements.periodOf(r, r.qs("from"), r.qs("to"));
    const carrier_id: Val = .{ .oid = (try V.id(r, r.q("carrierId"), "carrierId", .{})).? };
    const st = try statements.statement(r.a, carrier_id, org(r).get("_id"), p.from, p.to);
    if (std.mem.eql(u8, r.qs("format") orelse "", "csv")) {
        const name = try std.fmt.allocPrint(r.a, "statement-{s}-{s}-{s}.csv", .{ if (st.t("carrierName")) try val.toStr(r.a, st.get("carrierName")) else "carrier", p.from_text, p.to_text });
        return common.sendCsv(r, name, try statements.statementCsv(r.a, st, r.qs("lang") orelse "en"));
    }
    return r.json(200, try val.spread(r.a, .{ .{ .from = p.from_text, .to = p.to_text }, st }));
}

// ---- Developers -------------------------------------------------------------------------------------

fn listKeys(r: *Req) !void {
    return r.json(200, try apikeys.listApiKeys(r.a, org(r).get("_id")));
}

fn createKey(r: *Req) !void {
    const mode = (try V.oneOf(r, r.body.get("mode"), "mode", &.{ "live", "test" }, .{ .optional = true })) orelse "live";
    return r.json(201, try apikeys.createApiKey(r, r.orgCtx(), (try V.str(r, r.body.get("name"), "name", .{ .max = 60 })).?, mode));
}

fn revokeKey(r: *Req) !void {
    try apikeys.revokeApiKey(r, r.orgCtx(), .{ .oid = (try V.id(r, .{ .str = r.param("keyId") }, "keyId", .{})).? });
    return ok(r);
}

fn getWebhook(r: *Req) !void {
    return r.json(200, .{ .webhook = try webhooks.webhookView(r.a, org(r)), .deliveries = try webhooks.recentDeliveries(r.a, org(r).get("_id")) });
}

fn setWebhook(r: *Req) !void {
    return r.json(200, try webhooks.setWebhook(r, r.orgCtx(), (try V.url(r, r.body.get("url"), "url", .{})).?));
}

fn deleteWebhook(r: *Req) !void {
    try webhooks.deleteWebhook(r, r.orgCtx());
    return ok(r);
}

fn rotateWebhook(r: *Req) !void {
    return r.json(200, .{ .secret = try webhooks.rotateWebhookSecret(r, r.orgCtx()) });
}

fn testWebhook(r: *Req) !void {
    return r.json(200, try webhooks.sendTest(r, r.orgCtx()));
}
