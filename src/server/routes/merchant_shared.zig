//! Merchant operations shared by the merchant dashboard (cookie auth) and the merchant API /api/v1
//! (API keys), so both behave identically (src/routes/merchantShared.js).

const std = @import("std");
const val = @import("../lib/val.zig");
const db = @import("../lib/db.zig");
const web = @import("../web.zig");
const a_ = @import("../app.zig");
const geo = @import("../geo.zig");
const messages = @import("../messages.zig");
const shipments = @import("../services/shipments.zig");
const allocation = @import("../services/allocation.zig");
const branding = @import("../services/branding.zig");
const testmode = @import("../services/testmode.zig");
const bulk = @import("../services/bulk.zig");
const moderation = @import("../services/moderation.zig");
const common = @import("common.zig");
const Val = val.Val;
const Req = web.Req;
const V = web.V;
const Allocator = std.mem.Allocator;

pub fn links(a: Allocator, s: Val) !Val {
    const base = a_.cfg().public_url;
    const token = try val.toStr(a, s.get("publicToken"));
    return val.from(a, .{
        .trackingUrl = try std.fmt.allocPrint(a, "{s}/t/{s}", .{ base, token }),
        .embedUrl = try std.fmt.allocPrint(a, "{s}/embed/t/{s}", .{ base, token }),
        .labelUrl = try std.fmt.allocPrint(a, "{s}/label/{s}", .{ base, try val.toStr(a, s.get("labelToken")) }),
        .trackingToken = s.get("publicToken"),
    });
}

pub fn shipmentOut(a: Allocator, s: Val) !Val {
    return val.spread(a, .{ try shipments.merchantView(a, s), try links(a, s) });
}

pub fn listCarriersFor(r: *Req, merchant: Val) !Val {
    const a = r.a;
    // Restricted companies (moderation layer 2) are not listed; a store can still pick them by slug.
    const q = try val.spread(a, .{ .{ .type = "carrier", .status = "active", .@"carrier.pricing" = .{ .@"$ne" = null }, .@"carrier.acceptDirect" = true }, try moderation.browsable(a) });
    const pickup = try V.oneOf(r, r.q("pickup"), "pickup", geo.codes, .{ .optional = true });
    const dropoff = try V.oneOf(r, r.q("dropoff"), "dropoff", geo.codes, .{ .optional = true });
    const govs = try val.newArr(a);
    if (pickup) |p| try govs.push(p);
    if (dropoff) |d| try govs.push(d);
    if (govs.items().len > 0) try q.set("carrier.coverage", .{ .@"$all" = govs });
    try q.set("carrier.blockedMerchants", .{ .@"$ne" = merchant.get("_id") });
    try q.set("$or", .{ .{ .@"carrier.visibility" = .{ .@"$ne" = "private" } }, .{ .@"carrier.clientMerchants" = merchant.get("_id") } });
    const list = try db.col("orgs").find(a, q, .{ .sort = try val.from(a, .{ .name = 1 }), .limit = 200 });
    const out = try val.newArr(a);
    for (list) |c| {
        const b = try branding.publicBranding(a, c);
        const e = c.path("carrier.express");
        try out.push(.{
            .id = c.get("_id"),
            .name = c.get("name"),
            .slug = c.get("slug"),
            .logoUrl = if (b.get("logoUrl").truthy()) Val{ .str = try std.fmt.allocPrint(a, "{s}{s}", .{ a_.cfg().public_url, b.s("logoUrl").? }) } else Val.null,
            .coverage = c.path("carrier.coverage"),
            .maxWeightKg = c.path("carrier.maxWeightKg"),
            .cashOnDelivery = c.path("carrier.cod.enabled").truthy(),
            .currency = c.path("carrier.currency"),
            .sla = c.path("carrier.sla"),
            // Same-hour delivery, when the company offers it.
            .express = if (e.get("enabled").truthy()) try val.from(a, .{ .minutes = e.get("minutes"), .maxKm = e.get("maxKm"), .maxWeightKg = e.get("maxWeightKg"), .hours = if (e.get("hours").truthy()) e.get("hours") else Val.null }) else Val.null,
            .phone = if (c.path("contact.phone").truthy()) c.path("contact.phone") else Val.null,
        });
    }
    return out;
}

pub fn quoteFor(r: *Req, merchant: Val, body: Val, test_mode: bool) !Val {
    const a = r.a;
    // A price is asked before the customer typed their phone (a store's checkout).
    const input = try shipments.prepareShipmentInput(r, body, merchant, true);
    if (test_mode) return val.from(a, .{ .strategy = null, .options = .{try testmode.testOption(a, input)}, .@"test" = true });
    const q = try shipments.quote(r, merchant, input);
    const options = try val.newArr(a);
    for (q.get("options").items()) |m| {
        if (m.t("chain")) {
            try options.push(try allocation.chainOptionView(a, m));
            continue;
        }
        const v = try allocation.optionView(a, m, try branding.publicBranding(a, m.get("carrier")));
        if (v.path("carrier.logoUrl").truthy()) try v.get("carrier").set("logoUrl", try std.fmt.allocPrint(a, "{s}{s}", .{ a_.cfg().public_url, v.path("carrier.logoUrl").str }));
        try options.push(v);
    }
    const auto = input.get("carrier") == .str and std.mem.eql(u8, input.s("carrier").?, "auto");
    return val.from(a, .{ .strategy = if (auto) input.get("strategy") else Val.null, .excluded = q.get("excluded"), .options = options });
}

pub fn createFor(r: *Req, merchant: Val, body: Val, actor: Val, test_mode: bool) !Val {
    const input = try shipments.prepareShipmentInput(r, body, merchant, false);
    const res = if (test_mode) try testmode.createTestShipment(r, merchant, input, actor) else try shipments.createShipment(r, merchant, input, actor);
    return val.from(r.a, .{ .shipment = try shipmentOut(r.a, res.get("shipment")), .created = res.get("created") });
}

/// Many shipments at once; each row's result says created or error (with the field).
pub fn bulkFor(r: *Req, merchant: Val, body: Val, actor: Val, test_mode: bool) !Val {
    const a = r.a;
    const results = try bulk.createBulk(r, merchant, body.get("rows"), actor, test_mode);
    var created: usize = 0;
    var failed: usize = 0;
    const out = try val.newArr(a);
    for (results) |x| {
        if (x.t("ok")) {
            if (x.t("created")) created += 1;
            try out.push(.{ .row = x.get("row"), .ok = true, .shipment = try shipmentOut(a, x.get("shipment")) });
        } else {
            failed += 1;
            try out.push(x);
        }
    }
    return val.from(a, .{ .created = created, .failed = failed, .results = out });
}

/// test: practice shipments (test keys / the store's "Test" filter) instead of real ones.
pub fn listFor(r: *Req, merchant: Val, test_mode: bool) !Val {
    const a = r.a;
    const limit: i64 = @intFromFloat(val.jsMin(100, val.jsMax(1, common.numberOr(r.q("limit"), 25))));
    const status = if (r.qs("status")) |s| (if (s.len > 0) try V.oneOf(r, .{ .str = s }, "status", messages.status_list, .{}) else null) else null;
    const filter = try val.from(a, .{ .merchantId = merchant.get("_id") });
    if (test_mode) try filter.set("test", true) else try filter.set("test", .{ .@"$ne" = true });
    const list = try shipments.listShipments(a, filter, .{
        .limit = limit + 1,
        .status = if (status) |s| Val{ .str = s } else .undef,
        .q = r.qs("q"),
        .before = common.dateQuery(r, "before"),
    });
    const page = list[0..@min(list.len, @as(usize, @intCast(limit)))];
    const data = try val.newArr(a);
    for (page) |s| try data.push(try shipmentOut(a, s));
    const more = list.len > page.len;
    return val.from(a, .{ .data = data, .hasMore = more, .nextBefore = if (more) page[page.len - 1].get("createdAt") else Val.null });
}

pub fn trackingFor(r: *Req, merchant: Val, id_or_tracking: []const u8, lang: []const u8, test_only: ?bool) !Val {
    const a = r.a;
    const s = try shipments.getShipmentForMerchant(r, merchant.get("_id"), id_or_tracking, test_only);
    const events = try shipments.eventsFor(a, s.get("_id"), false);
    const live = try shipments.liveCourierFor(a, s);
    return val.spread(a, .{ try shipments.trackingView(a, s, events, live, lang, "merchant"), try links(a, s) });
}

pub fn langOf(r: *Req) []const u8 {
    if (std.mem.eql(u8, r.qs("lang") orelse "", "ar")) return "ar";
    if (std.mem.startsWith(u8, r.header("accept-language") orelse "", "ar")) return "ar";
    return "en";
}
