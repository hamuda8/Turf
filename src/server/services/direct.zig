//! Direct shipping for individuals ("send a parcel"), switched on and off in Control
//! (src/services/direct.js). Each person has a hidden one-person store (orgs.personal = true),
//! so tracking, labels and payouts work as for stores. A request is offered to the best carrier
//! first; if it declines or doesn't answer within DIRECT_OFFER_MINUTES it goes to the next one;
//! if nobody accepts it is cancelled. While offered, the shipment is "awaiting_carrier" with no
//! carrierId.

const std = @import("std");
const val = @import("../lib/val.zig");
const db = @import("../lib/db.zig");
const web = @import("../web.zig");
const a_ = @import("../app.zig");
const crypto = @import("../crypto.zig");
const bus = @import("../bus.zig");
const allocation = @import("allocation.zig");
const pricing = @import("pricing.zig");
const shipments_ = @import("shipments.zig");
const platform = @import("platform.zig");
const audit = @import("audit.zig");
const Val = val.Val;
const Req = web.Req;
const Allocator = std.mem.Allocator;

pub const offer_queue_size = 5;
const max_open_requests = 5;
const max_requests_per_day = 20;

/// 404 when the feature is off, so its pages and API simply don't exist.
pub fn requireDirect(r: *Req) !void {
    if (!try platform.featureOn(r.a, "directShipping")) return r.fail(404, "not_found", "No such endpoint", .{});
}

/// The person's hidden one-person store, created on first use.
pub fn personalOrg(r: *Req, user: Val) !Val {
    const a = r.a;
    if (try db.col("orgs").findOne(a, .{ .personal = true, .ownerUserId = user.get("id") }, .{})) |existing| return existing;
    const now = a_.now();
    const org = try val.from(a, .{
        .type = "merchant",
        .personal = true,
        .name = if (user.t("username")) user.get("username") else user.get("email"),
        .slug = try std.fmt.allocPrint(a, "u-{s}", .{try val.toStr(a, user.get("id"))}),
        .status = "active",
        .ownerUserId = user.get("id"),
        .contact = .{ .phone = null, .email = user.get("email"), .governorate = null },
        .branding = .{ .appName = if (user.t("username")) user.get("username") else Val{ .str = "Turf" }, .shortName = "Turf", .primaryColor = "#8A3324", .accentColor = "#030200", .assetsVersion = null },
        .merchant = .{ .website = null, .defaultPickup = null, .webhook = null, .defaultStrategy = "balanced" },
        .createdAt = now,
        .updatedAt = now,
    });
    _ = db.col("orgs").insertOne(a, org) catch |e| switch (e) {
        error.DuplicateKey => return (try db.col("orgs").findOne(a, .{ .personal = true, .ownerUserId = user.get("id") }, .{})) orelse e,
        else => return e,
    };
    _ = try db.col("memberships").insertOne(a, .{
        .orgId = org.get("_id"), .orgType = "merchant", .userId = user.get("id"), .email = user.get("email"), .name = user.get("username"),
        .isOwner = true, .roleId = null, .status = "active", .courier = null, .joinedAt = now,
    });
    return org;
}

fn requestFor(a: Allocator, input: Val, org: Val) !Val {
    return val.from(a, .{
        .pickup = input.get("pickup"),
        .dropoff = input.get("dropoff"),
        .weightKg = input.path("parcel.weightKg"),
        .codAmount = input.get("codAmount"),
        .parcel = input.get("parcel"),
        .merchantId = org.get("_id"),
        .mode = "individual",
        .strategy = input.get("strategy"),
    });
}

/// Carriers that would take this request, best first.
pub fn quoteDirect(r: *Req, org: Val, input: Val) ![]Val {
    const ranked = try allocation.rankCarriers(r, try requestFor(r.a, input, org));
    const c = input.get("carrier");
    if (c == .str and std.mem.eql(u8, c.str, "auto")) return ranked;
    var out: std.ArrayList(Val) = .empty;
    for (ranked) |m| if (m.path("carrier._id").sameId(c)) try out.append(r.a, m);
    return out.items;
}

/// Creates the request and offers it to the first carrier.
pub fn createDirectRequest(r: *Req, user: Val, org: Val, input: Val) !Val {
    const a = r.a;
    const open = try db.col("shipments").count(a, .{ .merchantId = org.get("_id"), .status = .{ .@"$in" = .{ "awaiting_carrier", "awaiting_pickup" } } }, .{});
    const today = try db.col("shipments").count(a, .{ .merchantId = org.get("_id"), .createdAt = .{ .@"$gte" = val.Date{ .ms = a_.nowMs() - 86400_000 } } }, .{});
    if (open >= max_open_requests) return r.conflict(try std.fmt.allocPrint(a, "You already have {d} parcels waiting. Wait until they are picked up.", .{open}), "direct_too_many_open", .{ .n = open });
    if (today >= max_requests_per_day) return r.fail(429, "rate_limited", "Too many requests today. Try again tomorrow.", .{});

    const all = try quoteDirect(r, org, input);
    const ranked = all[0..@min(all.len, offer_queue_size)];
    if (ranked.len == 0) return r.fail(422, "no_carrier_available", "No shipping company currently accepts this request", .{});

    const now_ms = a_.nowMs();
    const now: Val = .{ .date = now_ms };
    const queue = try val.newArr(a);
    for (ranked) |m| {
        const q = m.get("quote");
        try queue.push(.{
            .carrierId = m.path("carrier._id"),
            .carrierName = m.path("carrier.name"),
            .price = .{ .amount = q.get("amount"), .currency = q.get("currency"), .breakdown = q.get("breakdown") },
            .zone = q.get("zone"),
            .roadKm = q.get("roadKm"),
            .slaHours = pricing.slaHours(m.get("carrier"), q.s("zone") orelse ""),
            .metrics = m.get("metrics"),
        });
    }
    const first = queue.at(0);
    const created_by = try val.from(a, .{ .type = "user", .id = user.get("id"), .name = user.get("username") });
    const cod_amount = input.n("codAmount") orelse 0;
    const is_auto = input.get("carrier") == .str and std.mem.eql(u8, input.s("carrier").?, "auto");
    const shipment = try val.from(a, .{
        .trackingNumber = try crypto.newTrackingNumber(a),
        .publicToken = try crypto.randomToken(a, 18),
        .labelToken = try crypto.randomToken(a, 18),
        .merchantId = org.get("_id"),
        .merchantName = org.get("name"),
        .personal = true,
        .senderUserId = user.get("id"),
        .carrierId = null,
        .carrierName = null,
        .carrierIds = .{},
        .createdBy = created_by,
        .status = "awaiting_carrier",
        .statusAt = now,
        .zone = first.get("zone"),
        .allocation = .{ .mode = if (is_auto) "auto" else "direct", .strategy = input.get("strategy"), .score = null, .metrics = null, .alternatives = queue.items().len - 1, .decidedAt = null },
        .offer = .{ .queue = queue, .index = 0, .offeredAt = now, .expiresAt = val.Date{ .ms = now_ms + a_.cfg().direct_offer_minutes * 60_000 }, .declined = .{} },
        .pickup = input.get("pickup"),
        .dropoff = input.get("dropoff"),
        .parcel = input.get("parcel"),
        .cod = if (cod_amount > 0) try val.from(a, .{ .amount = cod_amount, .currency = first.path("price.currency"), .collectedAt = null, .collectedBy = null, .settledAt = null, .remittedAt = null }) else Val.null,
        .price = first.get("price"),
        .roadKm = first.get("roadKm"),
        .promisedBy = null,
        .requireCode = input.get("requireDeliveryCode"),
        .deliveryCode = try crypto.newDeliveryCode(a),
        .custody = .{ .type = "merchant" },
        .currentTaskId = null,
        .attempts = 0,
        .notes = input.get("notes"),
        .pod = null,
        .createdAt = now,
        .updatedAt = now,
    });
    _ = try db.col("shipments").insertOne(a, shipment);
    _ = try db.col("shipment_events").insertOne(a, .{
        .shipmentId = shipment.get("_id"), .code = "request_sent", .status = "awaiting_carrier", .params = .{}, .actor = created_by, .at = now, .internal = false,
    });
    notifyOffer(r, shipment);
    return shipment;
}

fn offerIndex(s: Val) usize {
    const x = s.path("offer.index").asNum() orelse 0;
    return if (x < 0) 0 else @intFromFloat(x);
}

fn notifyOffer(r: *Req, s: Val) void {
    const offer = s.path("offer.queue").at(offerIndex(s));
    bus.emit(r, "direct.offer", .{ .shipment = s, .carrierId = offer.get("carrierId") });
}

/// Requests currently offered to a carrier.
pub fn requestsFor(a: Allocator, carrier_id: Val) ![]Val {
    const list = try db.col("shipments").find(a, .{ .status = "awaiting_carrier" }, .{ .sort = try val.from(a, .{ .createdAt = 1 }), .limit = 200 });
    var out: std.ArrayList(Val) = .empty;
    for (list) |s| if (s.path("offer.queue").at(offerIndex(s)).get("carrierId").sameId(carrier_id)) try out.append(a, s);
    return out.items;
}

const Offered = struct { s: Val, offer: Val };

fn loadOffered(r: *Req, carrier_id: Val, shipment_id: Val) !Offered {
    const s = (try db.col("shipments").findOne(r.a, .{ ._id = shipment_id, .status = "awaiting_carrier" }, .{})) orelse return r.notFound("Request");
    const offer = s.path("offer.queue").at(offerIndex(s));
    if (!offer.get("carrierId").truthy() or !offer.get("carrierId").sameId(carrier_id)) return r.conflict("This request is no longer offered to your company", "offer_gone", null);
    return .{ .s = s, .offer = offer };
}

/// The carrier accepts: the request becomes its shipment, ready for pickup.
pub fn acceptRequest(r: *Req, ctx: *const web.OrgCtx, shipment_id: Val) !Val {
    const a = r.a;
    const o = try loadOffered(r, ctx.org.get("_id"), shipment_id);
    const now_ms = a_.nowMs();
    const now: Val = .{ .date = now_ms };
    const actor = try val.from(a, .{ .type = "user", .id = ctx.member.get("userId"), .name = ctx.member.get("name") });
    const set = try val.from(a, .{
        .carrierId = o.offer.get("carrierId"),
        .carrierName = o.offer.get("carrierName"),
        .carrierIds = .{o.offer.get("carrierId")},
        .price = o.offer.get("price"),
        .zone = o.offer.get("zone"),
        .roadKm = o.offer.get("roadKm"),
        .promisedBy = val.Date{ .ms = now_ms + @as(i64, @intFromFloat(val.toNum(o.offer.get("slaHours")) * 3600_000)) },
        .@"allocation.metrics" = o.offer.get("metrics"),
        .@"allocation.decidedAt" = now,
        .@"offer.acceptedAt" = now,
    });
    if (o.s.t("cod")) try set.set("cod.currency", o.offer.path("price.currency"));
    const updated = try shipments_.applyEvent(r, o.s, "carrier_accepted", .{ .actor = actor, .params = try val.from(a, .{ .carrier = o.offer.get("carrierName") }), .set = set });
    audit.audit(a, ctx.org.get("_id"), ctx.member, "direct.request_accepted", .{ .trackingNumber = o.s.get("trackingNumber") });
    // From here on it is a normal shipment (auto-dispatch, live updates, webhooks).
    const merchant = (try db.col("orgs").findOne(a, .{ ._id = o.s.get("merchantId") }, .{})) orelse Val.null;
    bus.emit(r, "shipment.created", .{ .shipment = updated, .carrier = ctx.org, .merchant = merchant });
    bus.emit(r, "direct.answered", .{ .shipment = updated, .accepted = true });
    return updated;
}

/// The carrier declines: the request goes to the next one.
pub fn declineRequest(r: *Req, ctx: *const web.OrgCtx, shipment_id: Val, reason: ?[]const u8) !Val {
    const o = try loadOffered(r, ctx.org.get("_id"), shipment_id);
    const rs: Val = if (reason) |x| (if (x.len > 0) Val{ .str = x } else .null) else .null;
    audit.audit(r.a, ctx.org.get("_id"), ctx.member, "direct.request_declined", .{ .trackingNumber = o.s.get("trackingNumber"), .reason = rs });
    return advanceOffer(r, o.s, try val.from(r.a, .{ .carrierId = ctx.org.get("_id"), .reason = if (rs == .null) Val{ .str = "declined" } else rs }));
}

/// Moves a request to its next carrier, or cancels it when nobody is left.
pub fn advanceOffer(r: *Req, s: Val, declined: Val) !Val {
    const a = r.a;
    const now_ms = a_.nowMs();
    const now: Val = .{ .date = now_ms };
    const idx = offerIndex(s);
    const next = idx + 1;
    const entry = try val.spread(a, .{ declined, .{ .at = now } });
    const queue = s.path("offer.queue");
    if (next < queue.items().len) {
        const updated = try db.col("shipments").findOneAndUpdate(a, .{ ._id = s.get("_id"), .status = "awaiting_carrier", .@"offer.index" = idx }, .{
            .@"$set" = .{ .@"offer.index" = next, .@"offer.offeredAt" = now, .@"offer.expiresAt" = val.Date{ .ms = now_ms + a_.cfg().direct_offer_minutes * 60_000 }, .price = queue.at(next).get("price"), .updatedAt = now },
            .@"$push" = .{ .@"offer.declined" = entry },
        }, .{ .returnDocument = .after });
        if (updated) |u| notifyOffer(r, u);
        return updated orelse .null;
    }
    _ = try db.col("shipments").updateOne(a, .{ ._id = s.get("_id"), .status = "awaiting_carrier" }, .{ .@"$push" = .{ .@"offer.declined" = entry } }, .{});
    const saved = r.err;
    const cancelled = shipments_.applyEvent(r, s, "no_carrier_found", .{ .actor = try val.from(a, .{ .type = "system" }), .set = try val.from(a, .{ .custody = .{ .type = "merchant" } }) }) catch {
        r.err = saved;
        return .null;
    };
    bus.emit(r, "direct.answered", .{ .shipment = cancelled, .accepted = false });
    return cancelled;
}

/// Offers nobody answered in time move on (every 30 s).
pub fn expireOffers(r: *Req) !usize {
    const a = r.a;
    const expired = try db.col("shipments").find(a, .{ .status = "awaiting_carrier", .@"offer.expiresAt" = .{ .@"$lt" = a_.now() } }, .{ .limit = 100 });
    for (expired) |s| {
        const offer = s.path("offer.queue").at(offerIndex(s));
        _ = advanceOffer(r, s, try val.from(a, .{ .carrierId = if (offer.get("carrierId").truthy()) offer.get("carrierId") else Val.null, .reason = "no_answer" })) catch |e| std.log.err("Offer expiry failed: {t}", .{e});
    }
    return expired.len;
}

/// The sender cancels before pickup.
pub fn cancelDirect(r: *Req, user: Val, shipment: Val) !Val {
    const a = r.a;
    const st = shipment.s("status") orelse "";
    if (!std.mem.eql(u8, st, "awaiting_carrier") and !std.mem.eql(u8, st, "awaiting_pickup"))
        return r.conflict("Only parcels that have not been picked up yet can be cancelled", "cancel_too_late", null);
    const actor = try val.from(a, .{ .type = "user", .id = user.get("id"), .name = user.get("username") });
    if (std.mem.eql(u8, st, "awaiting_carrier"))
        return shipments_.applyEvent(r, shipment, "cancelled", .{ .actor = actor, .set = try val.from(a, .{ .custody = .{ .type = "merchant" } }) });
    return shipments_.cancelShipment(r, shipment, actor, null);
}

/// Every 30 s. Run as its own task.
pub fn loop() void {
    while (true) {
        a_.app.io.sleep(.fromSeconds(30), .awake) catch return;
        if (!bus.enabled[@intFromEnum(bus.Service.direct)]) continue;
        var arena = std.heap.ArenaAllocator.init(a_.app.gpa);
        defer arena.deinit();
        var r = Req.background(arena.allocator());
        _ = expireOffers(&r) catch |e| std.log.err("Offer expiry failed: {t}", .{e});
        bus.flush(&r);
    }
}
