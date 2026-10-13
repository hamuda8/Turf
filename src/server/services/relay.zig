//! Relay shipments (src/services/relay.js): one order carried by several shipping companies in a
//! row, handing the parcel over at hubs. Chains have up to max_legs legs and are ranked with
//! single carriers in allocation.zig.
//!
//! shipment.legs = [{ carrierId, carrierName, from: { governorate }, to: { governorate, hubId,
//!   hubName, city } | null (last leg), price, slaHours, status: 'active' | 'waiting' | 'done' }]
//! shipment.legIndex is the current leg; shipment.carrierId is always the current leg's carrier;
//! shipment.carrierIds lists every carrier on the route. Returns go back the same way.

const std = @import("std");
const val = @import("mongo").val;
const db = @import("../lib/db.zig");
const web = @import("../web.zig");
const a_ = @import("../app.zig");
const geo = @import("../geo.zig");
const pricing = @import("pricing.zig");
const Val = val.Val;
const Req = web.Req;
const Allocator = std.mem.Allocator;

/// A route may pass through this many carriers.
pub const max_legs = 3;
/// Stop searching once this many raw chains were found.
const max_raw_chains = 200;

pub fn isRelay(s: Val) bool {
    return s.get("legs") == .arr and s.get("legs").items().len > 1;
}

fn legIndex(s: Val) usize {
    const x = s.n("legIndex") orelse 0;
    return if (x < 0) 0 else @intFromFloat(x);
}

pub fn currentLeg(s: Val) Val {
    return if (isRelay(s)) s.get("legs").at(legIndex(s)) else .null;
}

pub fn nextLeg(s: Val) Val {
    if (!isRelay(s)) return .null;
    const i = legIndex(s);
    return if (i < s.get("legs").items().len - 1) s.get("legs").at(i + 1) else .null;
}

pub fn previousLeg(s: Val) Val {
    if (!isRelay(s)) return .null;
    const i = legIndex(s);
    return if (i > 0) s.get("legs").at(i - 1) else .null;
}

/// The current carrier still has to hand the parcel to the next one.
pub fn mustHandOver(s: Val) bool {
    return nextLeg(s).truthy() and !s.t("returnRequired");
}

fn hubPlace(a: Allocator, hub: Val) !Val {
    return val.from(a, .{ .governorate = hub.get("governorate"), .city = hub.get("city"), .location = hub.get("location") });
}

pub const EligibleFn = *const fn (a: Allocator, carrier: Val, leg_req: Val) anyerror!?[]const u8;

const Search = struct {
    a: Allocator,
    req: Val,
    carriers: []const Val,
    hubs: []const Val,
    target: Val,
    to: Val,
    eligible: EligibleFn,
    max_legs: usize,
    options: std.ArrayList(Val) = .empty,

    fn covers(c: Val, g: Val) bool {
        return val.includesId(c.path("carrier.coverage"), g);
    }

    /// Where carrier b receives the parcel in governorate x: its hub there closest to the drop-off.
    fn handoverHub(s: *Search, b: Val, x: Val) ?Val {
        var best: ?Val = null;
        var best_d: f64 = std.math.inf(f64);
        for (s.hubs) |h| {
            if (!h.get("orgId").sameId(b.get("_id")) or !h.get("governorate").eql(x)) continue;
            if (!s.target.truthy()) return h;
            const d = if (h.get("location").truthy()) geo.distanceKmV(h.get("location"), s.target) else std.math.inf(f64);
            if (best == null or d < best_d) {
                best = h;
                best_d = d;
            }
        }
        return best;
    }

    fn walk(s: *Search, carrier: Val, at: Val, legs: []const Val, used_carriers: []const []const u8, used_govs: []const Val) !void {
        const a = s.a;
        if (s.options.items.len >= max_raw_chains) return;
        if (legs.len > 0 and covers(carrier, s.to)) {
            // This carrier can finish the job.
            const leg_req = try val.spread(a, .{ s.req, .{ .pickup = at, .codAmount = s.req.get("codAmount") } });
            if ((try s.eligible(a, carrier, leg_req)) != null) return;
            const quote = try pricing.quotePrice(a, carrier, leg_req);
            var all: std.ArrayList(Val) = .empty;
            try all.appendSlice(a, legs);
            try all.append(a, try val.from(a, .{ .carrier = carrier, .from = .{ .governorate = at.get("governorate") }, .to = null, .quote = quote, .slaHours = pricing.slaHours(carrier, pricing.zoneOf(at, s.req.get("dropoff"))) }));
            // One total for the store: every leg in the same currency.
            for (all.items) |l| if (!l.path("quote.currency").eql(all.items[0].path("quote.currency"))) return;
            try s.options.append(a, try chainOption(a, all.items));
            return;
        }
        if (legs.len >= s.max_legs - 1) return;
        for (carrier.path("carrier.coverage").items()) |x| {
            var used = false;
            for (used_govs) |g| if (g.eql(x)) {
                used = true;
            };
            if (used or x.eql(s.to)) continue;
            for (s.carriers) |next| {
                const nid = try val.toStr(a, next.get("_id"));
                if (val.contains([]const u8, used_carriers, nid) or !covers(next, x)) continue;
                const hub = s.handoverHub(next, x) orelse continue;
                const place = try hubPlace(a, hub);
                const leg_req = try val.spread(a, .{ s.req, .{ .pickup = at, .dropoff = place, .codAmount = 0 } });
                if ((try s.eligible(a, carrier, leg_req)) != null) continue;
                const quote = try pricing.quotePrice(a, carrier, leg_req);
                const leg = try val.from(a, .{
                    .carrier = carrier,
                    .from = .{ .governorate = at.get("governorate") },
                    .to = .{ .governorate = x, .hubId = hub.get("_id"), .hubName = hub.get("name"), .city = hub.get("city") },
                    .quote = quote,
                    .slaHours = pricing.slaHours(carrier, pricing.zoneOf(at, place)),
                });
                var nl: std.ArrayList(Val) = .empty;
                try nl.appendSlice(a, legs);
                try nl.append(a, leg);
                var nc: std.ArrayList([]const u8) = .empty;
                try nc.appendSlice(a, used_carriers);
                try nc.append(a, nid);
                var ng: std.ArrayList(Val) = .empty;
                try ng.appendSlice(a, used_govs);
                try ng.append(a, x);
                try s.walk(next, place, nl.items, nc.items, ng.items);
            }
        }
    }
};

/// Chains of carriers for a route, up to `max` legs. Every leg is checked with `eligible`; cash
/// on delivery rides on the last leg only. A chain never uses the same carrier or governorate
/// twice.
pub fn findChains(a: Allocator, req: Val, carriers: []const Val, eligible: EligibleFn, max: usize) ![]Val {
    const from = req.path("pickup.governorate");
    const to = req.path("dropoff.governorate");
    if (from.eql(to) or carriers.len < 2 or max < 2) return &.{};
    const ids = try val.newArr(a);
    for (carriers) |c| try ids.push(c.get("_id"));
    const hubs = try db.col("hubs").find(a, .{ .orgId = .{ .@"$in" = ids }, .active = true }, .{});
    var s: Search = .{ .a = a, .req = req, .carriers = carriers, .hubs = hubs, .target = try geo.approxPoint(a, req.get("dropoff")), .to = to, .eligible = eligible, .max_legs = max };
    for (carriers) |first| {
        if (!Search.covers(first, from) or Search.covers(first, to)) continue;
        try s.walk(first, req.get("pickup"), &.{}, &.{try val.toStr(a, first.get("_id"))}, &.{from});
    }
    return s.options.items;
}

fn chainOption(a: Allocator, legs: []const Val) !Val {
    var amount: f64 = 0;
    var km: f64 = 0;
    var eta: f64 = 0;
    const amounts = try val.newArr(a);
    const carriers = try val.newArr(a);
    for (legs) |l| {
        amount += val.toNum(l.path("quote.amount"));
        km += val.or0(l.path("quote.roadKm"));
        eta += val.toNum(l.get("slaHours"));
        try amounts.push(l.path("quote.amount"));
        try carriers.push(l.get("carrier"));
    }
    return val.from(a, .{
        .chain = true,
        .carrier = legs[0].get("carrier"),
        .carriers = carriers,
        .legs = legs,
        .quote = .{ .amount = amount, .currency = legs[0].path("quote.currency"), .breakdown = .{ .legs = amounts }, .zone = "national", .roadKm = val.jsRound(km * 10) / 10 },
        .metrics = .{ .price = amount, .etaHours = eta },
    });
}

/// Legs as stored on the shipment.
pub fn legsForShipment(a: Allocator, option: Val) !Val {
    const out = try val.newArr(a);
    for (option.get("legs").items(), 0..) |l, i| {
        const q = l.get("quote");
        try out.push(.{
            .carrierId = l.path("carrier._id"),
            .carrierName = l.path("carrier.name"),
            .from = l.get("from"),
            .to = l.get("to"),
            .price = .{ .amount = q.get("amount"), .currency = q.get("currency"), .breakdown = q.get("breakdown") },
            .slaHours = l.get("slaHours"),
            .status = if (i == 0) "active" else "waiting",
        });
    }
    return out;
}

/// Price a carrier earns on this shipment (its legs on a relay, else the whole price).
pub fn carrierPrice(s: Val, carrier_id: Val) !f64 {
    if (!isRelay(s)) return val.or0(s.path("price.amount"));
    var t: f64 = 0;
    for (s.get("legs").items()) |l| if (l.get("carrierId").sameId(carrier_id)) {
        t += val.or0(l.path("price.amount"));
    };
    return t;
}

/// The handoff place for the current leg, as a task destination.
pub fn handoffPlace(r: *Req, s: Val) !Val {
    const leg = currentLeg(s);
    if (!leg.path("to.hubId").truthy()) return .null;
    const hub = (try db.col("hubs").findOne(r.a, .{ ._id = leg.path("to.hubId") }, .{})) orelse
        return r.conflict("The handover hub of the next company no longer exists. Contact Turf support.", "handover_hub_gone", null);
    // "external": the hub belongs to the next company, not to the carrier doing the run.
    return val.from(r.a, .{
        .kind = "hub",
        .hubId = hub.get("_id"),
        .label = try std.fmt.allocPrint(r.a, "{s} — {s}", .{ try val.toStr(r.a, hub.get("name")), try val.toStr(r.a, nextLeg(s).get("carrierName")) }),
        .location = hub.get("location"),
        .external = true,
        .carrierId = hub.get("orgId"),
    });
}

/// Destination of a return run on a relay: back to the previous leg's handoff hub.
pub fn handbackPlace(r: *Req, s: Val) !Val {
    const prev = previousLeg(s);
    if (!prev.path("to.hubId").truthy()) return .null;
    const hub = (try db.col("hubs").findOne(r.a, .{ ._id = prev.path("to.hubId") }, .{})) orelse
        return r.conflict("The handover hub no longer exists. Contact Turf support.", "handover_hub_gone", null);
    return val.from(r.a, .{
        .kind = "hub",
        .hubId = hub.get("_id"),
        .label = try std.fmt.allocPrint(r.a, "{s} ({s})", .{ try val.toStr(r.a, hub.get("name")), try val.toStr(r.a, hub.get("code")) }),
        .location = hub.get("location"),
    });
}

/// Changes that move a relay shipment to the next carrier ("handed_over").
pub fn handOverSet(a: Allocator, s: Val, hub: Val) !Val {
    const i = legIndex(s);
    const next = s.get("legs").at(i + 1);
    const now = a_.now();
    const set = try val.from(a, .{ .carrierId = next.get("carrierId"), .carrierName = next.get("carrierName"), .legIndex = i + 1 });
    try set.set(try std.fmt.allocPrint(a, "legs.{d}.status", .{i}), "done");
    try set.set(try std.fmt.allocPrint(a, "legs.{d}.doneAt", .{i}), now);
    try set.set(try std.fmt.allocPrint(a, "legs.{d}.status", .{i + 1}), "active");
    try set.set(try std.fmt.allocPrint(a, "legs.{d}.startedAt", .{i + 1}), now);
    try set.set("custody", .{ .type = "hub", .hubId = hub.get("_id") });
    try set.set("currentTaskId", null);
    return set;
}

/// Changes that give a returning relay shipment back to the previous carrier ("handed_back").
pub fn handBackSet(a: Allocator, s: Val, hub: Val) !Val {
    const i = legIndex(s);
    const prev = s.get("legs").at(i - 1);
    const set = try val.from(a, .{ .carrierId = prev.get("carrierId"), .carrierName = prev.get("carrierName"), .legIndex = i - 1 });
    try set.set(try std.fmt.allocPrint(a, "legs.{d}.status", .{i}), "done");
    try set.set(try std.fmt.allocPrint(a, "legs.{d}.status", .{i - 1}), "active");
    try set.set("custody", .{ .type = "hub", .hubId = hub.get("_id") });
    try set.set("currentTaskId", null);
    return set;
}

/// A hub that may hold this carrier's parcel: the relay handoff hub it collects from.
pub fn isHandoffHubFor(s: Val, carrier_id: Val, hub_id: Val) bool {
    if (!isRelay(s)) return false;
    for (s.get("legs").items()) |l| {
        if (l.path("to.hubId").truthy() and l.path("to.hubId").sameId(hub_id) and l.get("carrierId").sameId(carrier_id)) return true;
    }
    return false;
}
