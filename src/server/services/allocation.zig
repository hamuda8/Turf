//! Carrier allocation (src/services/allocation.js): every way a shipment can travel (one carrier,
//! or a chain with handovers at hubs: relay.zig), measured, filtered and ranked by the
//! merchant's strategy. The same list is what the store sees in a quote.
//!
//! Metrics: price, etaHours (SLA blended with observed delivery times), distanceKm (nearest hub
//! to the pickup), reliability (Bayesian-smoothed delivered share), load (open shipments per
//! courier). Strategies: balanced (weighted mix) or cheapest / fastest / nearest / reliable.
//! Express: carriers offering it, within their limits, with a courier on shift; no chains.

const std = @import("std");
const val = @import("mongo").val;
const db = @import("../lib/db.zig");
const web = @import("../web.zig");
const a_ = @import("../app.zig");
const geo = @import("../geo.zig");
const messages = @import("../messages.zig");
const pricing = @import("pricing.zig");
const coverage = @import("coverage.zig");
const moderation = @import("moderation.zig");
const relay = @import("relay.zig");
const Val = val.Val;
const Req = web.Req;
const Allocator = std.mem.Allocator;

pub const strategies = [_][]const u8{ "balanced", "cheapest", "fastest", "nearest", "reliable" };

const w_price = 0.3;
const w_eta = 0.25;
const w_reliability = 0.25;
const w_distance = 0.1;
const w_load = 0.1;

// Reliability prior: like 8 delivered out of 10 until real history exists.
const prior_delivered = 8.0;
const prior_total = 10.0;
const min_history_for_eta = 20;
const history_days = 90;

pub const max_price_ratio = 2.5;
pub const max_eta_ratio = 2.0;
pub const eta_slack_hours = 24.0;
pub const max_options = 12;

fn includesId(list: Val, id: Val) bool {
    for (list.items()) |x| if (x.sameId(id)) return true;
    return false;
}

/// Why a specific carrier can't take this shipment (null = it can).
pub fn ineligibilityReason(a: Allocator, carrier: Val, req: Val) !?[]const u8 {
    const c = carrier.get("carrier");
    const mode = req.s("mode") orelse "";
    const merchant_id = req.get("merchantId");
    if (!std.mem.eql(u8, carrier.s("status") orelse "", "active")) return "carrier_not_active";
    if (!c.get("pricing").truthy()) return "carrier_not_configured";
    if (std.mem.eql(u8, c.s("visibility") orelse "", "private") and !includesId(c.get("clientMerchants"), merchant_id)) return "carrier_private";
    if (std.mem.eql(u8, mode, "direct") and !c.t("acceptDirect")) return "carrier_not_accepting_direct_orders";
    if (std.mem.eql(u8, mode, "auto") and !c.t("acceptMarketplace")) return "carrier_not_accepting_marketplace_orders";
    if (std.mem.eql(u8, mode, "individual") and !c.t("acceptIndividuals")) return "carrier_not_accepting_individuals";
    const pickup = req.get("pickup");
    const dropoff = req.get("dropoff");
    if (!val.includesId(c.get("coverage"), pickup.get("governorate"))) return "pickup_not_covered";
    if (!val.includesId(c.get("coverage"), dropoff.get("governorate"))) return "dropoff_not_covered";
    if (!try coverage.coversAddress(a, carrier, pickup)) return "pickup_area_not_covered";
    if (!try coverage.coversAddress(a, carrier, dropoff)) return "dropoff_area_not_covered";
    if (val.toNum(req.get("weightKg")) > val.toNum(c.get("maxWeightKg"))) return "too_heavy";
    if (val.toNum(req.get("codAmount")) > 0 and !c.path("cod.enabled").truthy()) return "cod_not_supported";
    if (includesId(c.get("blockedMerchants"), merchant_id)) return "merchant_blocked";
    if (std.mem.eql(u8, req.s("service") orelse "", "express")) return pricing.expressReason(a, carrier, req, a_.nowMs());
    return null;
}

fn modeFlag(mode: []const u8) []const u8 {
    if (std.mem.eql(u8, mode, "direct")) return "carrier.acceptDirect";
    if (std.mem.eql(u8, mode, "individual")) return "carrier.acceptIndividuals";
    return "carrier.acceptMarketplace";
}

/// Carriers that may take part at all: active, priced, open to this kind of order.
fn candidateCarriers(a: Allocator, req: Val, whole_route: bool) ![]Val {
    const merchant_id = req.get("merchantId");
    const q = try val.spread(a, .{
        .{ .type = "carrier", .status = "active" },
        // Restricted companies (moderation layer 2) are never ranked automatically.
        try moderation.browsable(a),
        .{
            .@"carrier.pricing" = .{ .@"$ne" = null },
            .@"carrier.maxWeightKg" = .{ .@"$gte" = req.get("weightKg") },
            .@"carrier.blockedMerchants" = .{ .@"$ne" = merchant_id },
        },
    });
    try q.set(modeFlag(req.s("mode") orelse ""), true);
    // Private carriers only serve their own customers.
    try q.set("$or", .{ .{ .@"carrier.visibility" = .{ .@"$ne" = "private" } }, .{ .@"carrier.clientMerchants" = merchant_id } });
    if (std.mem.eql(u8, req.s("service") orelse "", "express")) try q.set("carrier.express.enabled", true);
    if (whole_route) {
        try q.set("carrier.coverage", .{ .@"$all" = .{ req.path("pickup.governorate"), req.path("dropoff.governorate") } });
        if (val.toNum(req.get("codAmount")) > 0) try q.set("carrier.cod.enabled", true);
    }
    const list = try db.col("orgs").find(a, q, .{});
    try coverage.attachHubs(a, list);
    return list;
}

fn eligibleCarriers(a: Allocator, req: Val) ![]Val {
    const carriers = try candidateCarriers(a, req, true);
    var ok: std.ArrayList(Val) = .empty;
    for (carriers) |c| if ((try ineligibilityReason(a, c, req)) == null) try ok.append(a, c);
    return withCourierOnDuty(a, ok.items, req);
}

/// Express needs a courier who can leave now: carriers with nobody on shift are left out.
fn withCourierOnDuty(a: Allocator, carriers: []Val, req: Val) ![]Val {
    if (!std.mem.eql(u8, req.s("service") orelse "", "express") or carriers.len == 0) return carriers;
    const ids = try val.newArr(a);
    for (carriers) |c| try ids.push(c.get("_id"));
    const on = try db.col("memberships").distinct(a, "orgId", .{ .orgId = .{ .@"$in" = ids }, .status = "active", .courier = .{ .@"$ne" = null }, .@"duty.onDuty" = true });
    var out: std.ArrayList(Val) = .empty;
    for (carriers) |c| for (on) |id| if (id.sameId(c.get("_id"))) {
        try out.append(a, c);
        break;
    };
    return out.items;
}

const Stats = struct { reliability: f64, load: f64, couriers: f64, distance: ?f64, observed: ?f64 };
const StatsMap = std.StringHashMapUnmanaged(Stats);

fn findAgg(list: []const Val, id: Val) Val {
    for (list) |x| if (x.get("_id").sameId(id)) return x;
    return .undef;
}

/// History, load and hub distance per carrier (by id).
fn carrierStats(a: Allocator, carriers: []const Val, req: Val) !StatsMap {
    const ids = try val.newArr(a);
    for (carriers) |c| try ids.push(c.get("_id"));
    const zone = pricing.zoneOf(req.get("pickup"), req.get("dropoff"));
    const since = val.Date{ .ms = a_.nowMs() - history_days * 86400_000 };
    const cond_delivered = try val.from(a, .{ .@"$eq" = .{ "$status", "delivered" } });
    const cond_zone = try val.from(a, .{ .@"$and" = .{ cond_delivered, .{ .@"$eq" = .{ "$zone", zone } } } });
    const history = try db.col("shipments").aggregate(a, .{
        .{ .@"$match" = .{ .carrierId = .{ .@"$in" = ids }, .createdAt = .{ .@"$gte" = since }, .status = .{ .@"$in" = .{ "delivered", "returned" } } } },
        .{ .@"$group" = .{
            ._id = "$carrierId",
            .delivered = .{ .@"$sum" = .{ .@"$cond" = .{ cond_delivered, 1, 0 } } },
            .returned = .{ .@"$sum" = .{ .@"$cond" = .{ .{ .@"$eq" = .{ "$status", "returned" } }, 1, 0 } } },
            .zoneDelivered = .{ .@"$sum" = .{ .@"$cond" = .{ cond_zone, 1, 0 } } },
            .zoneHours = .{ .@"$avg" = .{ .@"$cond" = .{ cond_zone, .{ .@"$divide" = .{ .{ .@"$subtract" = .{ "$deliveredAt", "$createdAt" } }, 3600_000 } }, null } } },
        } },
    });
    const open_counts = try db.col("shipments").aggregate(a, .{
        .{ .@"$match" = .{ .carrierId = .{ .@"$in" = ids }, .status = .{ .@"$nin" = &messages.final_statuses } } },
        .{ .@"$group" = .{ ._id = "$carrierId", .n = .{ .@"$sum" = 1 } } },
    });
    const courier_counts = try db.col("memberships").aggregate(a, .{
        .{ .@"$match" = .{ .orgId = .{ .@"$in" = ids }, .status = "active", .courier = .{ .@"$ne" = null } } },
        .{ .@"$group" = .{ ._id = "$orgId", .n = .{ .@"$sum" = 1 } } },
    });
    const hubs = try db.col("hubs").find(a, .{ .orgId = .{ .@"$in" = ids }, .active = true }, .{ .projection = try val.from(a, .{ .orgId = 1, .location = 1 }) });

    const pickup_point = try geo.approxPoint(a, req.get("pickup"));
    var stats: StatsMap = .empty;
    for (carriers) |carrier| {
        const h = findAgg(history, carrier.get("_id"));
        const delivered = val.or0(h.get("delivered"));
        const finished = delivered + val.or0(h.get("returned"));
        const open = val.or0(findAgg(open_counts, carrier.get("_id")).get("n"));
        const couriers = val.or0(findAgg(courier_counts, carrier.get("_id")).get("n"));
        var distance: ?f64 = null;
        if (pickup_point.truthy()) for (hubs) |x| if (x.get("orgId").sameId(carrier.get("_id"))) {
            const d = geo.distanceKmV(x.get("location"), pickup_point);
            distance = if (distance) |cur| val.jsMin(cur, d) else d;
        };
        const zh = h.get("zoneHours");
        try stats.put(a, try val.toStr(a, carrier.get("_id")), .{
            .reliability = val.jsRound(((delivered + prior_delivered) / (finished + prior_total)) * 1000) / 1000,
            .load = val.jsRound((open / @max(1, couriers)) * 10) / 10,
            .couriers = couriers,
            .distance = if (distance) |d| val.jsRound(d * 10) / 10 else null,
            .observed = if (h != .undef and val.or0(h.get("zoneDelivered")) >= min_history_for_eta and zh.truthy()) val.toNum(zh) else null,
        });
    }
    return stats;
}

fn optNum(x: ?f64) Val {
    return if (x) |v| Val{ .num = v } else .null;
}

fn singleOption(a: Allocator, carrier: Val, req: Val, stats: *const StatsMap) !Val {
    const quote = try pricing.quotePrice(a, carrier, req);
    const st = stats.get(try val.toStr(a, carrier.get("_id"))).?;
    const express = std.mem.eql(u8, req.s("service") orelse "", "express");
    const sla = pricing.promiseHours(carrier, quote.s("zone") orelse "", req.s("service"));
    // Express promises a trip time; standard history says nothing about it.
    const eta = if (st.observed != null and st.observed.? != 0 and !express) val.jsRound(((sla + st.observed.?) / 2) * 10) / 10 else sla;
    return val.from(a, .{
        .id = try val.toStr(a, carrier.get("_id")),
        .chain = false,
        .service = if (express) "express" else "standard",
        .carrier = carrier,
        .quote = quote,
        .metrics = .{ .price = quote.get("amount"), .etaHours = eta, .distanceKm = optNum(st.distance), .reliability = st.reliability, .load = st.load, .couriers = st.couriers },
    });
}

/// A chain's metrics from its carriers' statistics (legs already carry price and SLA).
fn completeChain(a: Allocator, option: Val, stats: *const StatsMap) !Val {
    var sts: std.ArrayList(Stats) = .empty;
    for (option.get("carriers").items()) |c| try sts.append(a, stats.get(try val.toStr(a, c.get("_id"))).?);
    var parts: std.ArrayList([]const u8) = .empty;
    for (option.get("legs").items()) |l| {
        const cid = try val.toStr(a, l.path("carrier._id"));
        const to = l.get("to");
        try parts.append(a, if (to.truthy()) try std.fmt.allocPrint(a, "{s}.{s}", .{ cid, try val.toStr(a, to.get("hubId")) }) else cid);
    }
    try option.set("id", try std.mem.join(a, "-", parts.items));
    var rel: f64 = 1;
    var load: f64 = -std.math.inf(f64);
    var couriers: f64 = std.math.inf(f64);
    for (sts.items) |s| {
        rel *= s.reliability;
        load = val.jsMax(load, s.load);
        couriers = val.jsMin(couriers, s.couriers);
    }
    const m = option.get("metrics");
    try option.set("metrics", try val.spread(a, .{ m, .{ .distanceKm = optNum(sts.items[0].distance), .reliability = val.jsRound(rel * 1000) / 1000, .load = load, .couriers = couriers } }));
    return option;
}

const Norm = struct {
    min: f64,
    max: f64,
    higher_better: bool,

    fn init(values: []const Val, higher_better: bool) Norm {
        var lo = std.math.inf(f64);
        var hi = -std.math.inf(f64);
        for (values) |v| {
            if (v == .null or v == .undef) continue;
            const x = val.toNum(v);
            lo = val.jsMin(lo, x);
            hi = val.jsMax(hi, x);
        }
        return .{ .min = lo, .max = hi, .higher_better = higher_better };
    }

    fn of(n: Norm, v: Val) f64 {
        if (v == .null or v == .undef) return 0;
        if (n.max == n.min) return 1;
        const t = (val.toNum(v) - n.min) / (n.max - n.min);
        return if (n.higher_better) t else 1 - t;
    }
};

fn rank(a: Allocator, options: []Val, strategy: []const u8) ![]Val {
    var lists: [5]std.ArrayList(Val) = @splat(.empty);
    const names = [_][]const u8{ "price", "etaHours", "distanceKm", "reliability", "load" };
    for (options) |m| for (names, 0..) |nm, i| try lists[i].append(a, m.get("metrics").get(nm));
    const n_price = Norm.init(lists[0].items, false);
    const n_eta = Norm.init(lists[1].items, false);
    const n_dist = Norm.init(lists[2].items, false);
    const n_rel = Norm.init(lists[3].items, true);
    const n_load = Norm.init(lists[4].items, false);
    for (options) |m| {
        const x = m.get("metrics");
        const score = w_price * n_price.of(x.get("price")) + w_eta * n_eta.of(x.get("etaHours")) + w_reliability * n_rel.of(x.get("reliability")) + w_distance * n_dist.of(x.get("distanceKm")) + w_load * n_load.of(x.get("load"));
        try m.set("score", val.jsRound(score * 1000) / 1000);
    }
    const Ctx = struct {
        primary: ?u8,
        fn key(c: @This(), m: Val) f64 {
            const x = m.get("metrics");
            return switch (c.primary.?) {
                0 => val.toNum(x.get("price")),
                1 => val.toNum(x.get("etaHours")),
                2 => if (x.get("distanceKm").isNullish()) std.math.inf(f64) else val.toNum(x.get("distanceKm")),
                else => -val.toNum(x.get("reliability")),
            };
        }
        fn legs(m: Val) f64 {
            return if (m.t("chain")) @floatFromInt(m.get("legs").items().len) else 1;
        }
        /// The JavaScript comparator's result (NaN counts as "equal").
        fn cmp(c: @This(), p: Val, q: Val) f64 {
            if (c.primary != null) {
                const d = c.key(p) - c.key(q);
                if (d != 0) return d;
            }
            const s = val.toNum(q.get("score")) - val.toNum(p.get("score"));
            if (s != 0 and !std.math.isNan(s)) return s;
            return legs(p) - legs(q);
        }
        fn lessThan(c: @This(), p: Val, q: Val) bool {
            return c.cmp(p, q) < 0;
        }
    };
    const primary: ?u8 = if (std.mem.eql(u8, strategy, "cheapest")) 0 else if (std.mem.eql(u8, strategy, "fastest")) 1 else if (std.mem.eql(u8, strategy, "nearest")) 2 else if (std.mem.eql(u8, strategy, "reliable")) 3 else null;
    // Array.prototype.sort is stable; so is std.mem.sort.
    std.mem.sort(Val, options, Ctx{ .primary = primary }, Ctx.lessThan);
    return options;
}

/// Drops options nobody would pick: far dearer or far slower than the best one.
fn reasonable(a: Allocator, options: []Val) ![]Val {
    if (options.len < 2) return options;
    var min_price = std.math.inf(f64);
    var min_eta = std.math.inf(f64);
    for (options) |o| {
        min_price = val.jsMin(min_price, val.toNum(o.path("metrics.price")));
        min_eta = val.jsMin(min_eta, val.toNum(o.path("metrics.etaHours")));
    }
    var kept: std.ArrayList(Val) = .empty;
    for (options) |o| {
        if (val.toNum(o.path("metrics.price")) <= min_price * max_price_ratio and val.toNum(o.path("metrics.etaHours")) <= min_eta * max_eta_ratio + eta_slack_hours) try kept.append(a, o);
    }
    return if (kept.items.len > 0) kept.items else options;
}

/// Ranks every single carrier able to take this shipment (no chains).
pub fn rankCarriers(r: *Req, req: Val) ![]Val {
    const a = r.a;
    const carriers = try eligibleCarriers(a, req);
    if (carriers.len == 0) return &.{};
    var stats = try carrierStats(a, carriers, req);
    var opts: std.ArrayList(Val) = .empty;
    for (carriers) |c| try opts.append(a, try singleOption(a, c, req, &stats));
    return rank(a, opts.items, req.s("strategy") orelse "balanced");
}

fn eligibleForLeg(a: Allocator, carrier: Val, leg_req: Val) anyerror!?[]const u8 {
    const lr = try val.spread(a, .{ leg_req, .{ .mode = "auto" } });
    return ineligibilityReason(a, carrier, lr);
}

/// Every reasonable way to ship, singles and chains, ranked: { options, excluded }. Only
/// carriers open to automatic (marketplace) orders take part.
pub fn rankOptions(r: *Req, req: Val) !Val {
    const a = r.a;
    const strategy = req.s("strategy") orelse "balanced";
    const auto = try val.spread(a, .{ req, .{ .mode = "auto" } });
    const express = std.mem.eql(u8, req.s("service") orelse "", "express");
    const candidates = try candidateCarriers(a, auto, express);
    var single_list: std.ArrayList(Val) = .empty;
    for (candidates) |c| if ((try ineligibilityReason(a, c, auto)) == null) try single_list.append(a, c);
    const singles = try withCourierOnDuty(a, single_list.items, auto);
    const chains: []Val = if (candidates.len >= 2 and !express) try relay.findChains(a, auto, candidates, eligibleForLeg, relay.max_legs) else &.{};
    var involved_keys: std.ArrayList([]const u8) = .empty;
    var involved: std.StringHashMapUnmanaged(Val) = .empty;
    const add = struct {
        fn f(al: Allocator, keys: *std.ArrayList([]const u8), map: *std.StringHashMapUnmanaged(Val), c: Val) !void {
            const k = try val.toStr(al, c.get("_id"));
            const gop = try map.getOrPut(al, k);
            if (!gop.found_existing) try keys.append(al, k);
            gop.value_ptr.* = c;
        }
    }.f;
    for (singles) |c| try add(a, &involved_keys, &involved, c);
    for (chains) |o| for (o.get("carriers").items()) |c| try add(a, &involved_keys, &involved, c);
    if (involved_keys.items.len == 0) return val.from(a, .{ .options = .{}, .excluded = 0 });
    var all_carriers: std.ArrayList(Val) = .empty;
    for (involved_keys.items) |k| try all_carriers.append(a, involved.get(k).?);
    var stats = try carrierStats(a, all_carriers.items, req);
    var all: std.ArrayList(Val) = .empty;
    for (singles) |c| try all.append(a, try singleOption(a, c, req, &stats));
    for (chains) |o| try all.append(a, try completeChain(a, o, &stats));
    const kept = try reasonable(a, all.items);
    const ranked = try rank(a, kept, strategy);
    return val.from(a, .{ .options = ranked[0..@min(ranked.len, max_options)], .excluded = all.items.len - kept.len });
}

/// Measures one specific carrier (direct choice); { reason } when it can't take the shipment.
pub fn measureCarrier(r: *Req, carrier: Val, req: Val) !Val {
    const a = r.a;
    try coverage.attachHubs(a, &.{carrier});
    const direct = try val.spread(a, .{ req, .{ .mode = "direct" } });
    var reason = try ineligibilityReason(a, carrier, direct);
    if (reason == null and std.mem.eql(u8, req.s("service") orelse "", "express")) {
        var one = [_]Val{carrier};
        if ((try withCourierOnDuty(a, &one, req)).len == 0) reason = "express_no_courier";
    }
    if (reason) |x| return val.from(a, .{ .reason = x });
    var stats = try carrierStats(a, &.{carrier}, req);
    const m = try singleOption(a, carrier, req, &stats);
    try m.set("score", null);
    return m;
}

/// Public, merchant-facing representation of a ranked option.
pub fn optionView(a: Allocator, m: Val, branding: Val) !Val {
    const c = m.get("carrier");
    const q = m.get("quote");
    const x = m.get("metrics");
    return val.from(a, .{
        .id = m.get("id"),
        .chain = false,
        .carrier = .{ .id = c.get("_id"), .name = c.get("name"), .slug = c.get("slug"), .logoUrl = if (branding.get("logoUrl").truthy()) branding.get("logoUrl") else Val.null },
        .price = .{ .amount = q.get("amount"), .currency = q.get("currency"), .breakdown = q.get("breakdown") },
        .zone = q.get("zone"),
        .service = m.get("service"),
        .etaHours = x.get("etaHours"),
        .distanceKm = x.get("distanceKm"),
        .reliability = x.get("reliability"),
        .load = x.get("load"),
        .score = m.get("score"),
    });
}

/// Merchant-facing view of a chain option.
pub fn chainOptionView(a: Allocator, o: Val) !Val {
    const legs = try val.newArr(a);
    for (o.get("legs").items()) |l| {
        const to = l.get("to");
        try legs.push(.{
            .carrier = .{ .id = l.path("carrier._id"), .name = l.path("carrier.name"), .slug = l.path("carrier.slug") },
            .from = l.path("from.governorate"),
            .to = if (to.truthy()) to.get("governorate") else Val.null,
            .handoverHub = if (to.truthy()) try val.from(a, .{ .name = to.get("hubName"), .city = to.get("city") }) else Val.null,
            .price = .{ .amount = l.path("quote.amount"), .currency = l.path("quote.currency") },
            .etaHours = l.get("slaHours"),
        });
    }
    const c = o.get("carrier");
    const q = o.get("quote");
    const x = o.get("metrics");
    return val.from(a, .{
        .id = o.get("id"),
        .chain = true,
        .carrier = .{ .id = c.get("_id"), .name = c.get("name"), .slug = c.get("slug") },
        .legs = legs,
        .price = .{ .amount = q.get("amount"), .currency = q.get("currency"), .breakdown = q.get("breakdown") },
        .zone = "national",
        .service = "standard",
        .etaHours = x.get("etaHours"),
        .distanceKm = x.get("distanceKm"),
        .reliability = x.get("reliability"),
        .load = x.get("load"),
        .score = if (o.get("score").isNullish()) Val.null else o.get("score"),
    });
}
