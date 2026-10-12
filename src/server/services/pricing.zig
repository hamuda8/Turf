//! Price and ETA quotes from a carrier's rate card (src/services/pricing.js).
//!
//! Rate card (money in the carrier's currency, whole units): localBase, nationalBase, routes
//! ([{ from, to, base }], both directions), includedKg, perKg, volumetricDivisor (0 = off),
//! perKm, codPercent, codMin, fragileFee, extraPieceFee, valuePercent. The express card
//! (carrier.express: base, perKm) replaces the base, weight and distance prices; the
//! cash-on-delivery fee and surcharges stay the same.
//!
//! Arithmetic follows JavaScript: a missing number is NaN and makes the total NaN (null in JSON).

const std = @import("std");
const val = @import("../lib/val.zig");
const geo = @import("../geo.zig");
const Val = val.Val;

pub fn zoneOf(pickup: Val, dropoff: Val) []const u8 {
    return if (pickup.get("governorate").eql(dropoff.get("governorate"))) "local" else "national";
}

/// Rough road km between two addresses, or null when one has no point.
pub fn estimateRoadKm(a: std.mem.Allocator, pickup: Val, dropoff: Val) !?f64 {
    const p1 = try geo.approxPoint(a, pickup);
    const p2 = try geo.approxPoint(a, dropoff);
    if (p1.isNullish() or p2.isNullish()) return null;
    return val.jsRound(geo.roadKm(geo.distanceKmV(p1, p2)) * 10) / 10;
}

/// Base price from a route rule for this governorate pair, if the carrier set one.
pub fn routeBase(p: Val, from: Val, to: Val) ?Val {
    for (p.get("routes").items()) |x| {
        if ((x.get("from").eql(from) and x.get("to").eql(to)) or (x.get("from").eql(to) and x.get("to").eql(from))) return x.get("base");
    }
    return null;
}

/// Weight the parcel is charged at: the actual weight, or its volume when that is more.
pub fn chargeableKg(p: Val, weight_kg: f64, dims: Val) f64 {
    const divisor = val.or0(p.get("volumetricDivisor"));
    if (divisor == 0 or !dims.truthy()) return weight_kg;
    const volumetric = (val.toNum(dims.get("length")) * val.toNum(dims.get("width")) * val.toNum(dims.get("height"))) / divisor;
    return val.jsMax(weight_kg, val.jsRound(volumetric * 100) / 100);
}

/// `req`: { pickup, dropoff, weightKg, codAmount, parcel?: { dimensionsCm, pieces, fragile, value }, service? }
pub fn quotePrice(a: std.mem.Allocator, carrier: Val, req: Val) !Val {
    const p = carrier.path("carrier.pricing");
    const pickup = req.get("pickup");
    const dropoff = req.get("dropoff");
    const parcel = req.get("parcel");
    const zone = zoneOf(pickup, dropoff);
    const km = (try estimateRoadKm(a, pickup, dropoff)) orelse 0;
    const kg = chargeableKg(p, val.toNum(req.get("weightKg")), parcel.get("dimensionsCm"));
    const is_express = std.mem.eql(u8, req.s("service") orelse "", "express");
    const express = if (is_express) carrier.path("carrier.express") else Val.null;

    const base: f64 = if (is_express)
        val.toNum(express.get("base"))
    else if (routeBase(p, pickup.get("governorate"), dropoff.get("governorate"))) |rb|
        (if (rb.isNullish()) val.toNum(p.get(if (std.mem.eql(u8, zone, "local")) "localBase" else "nationalBase")) else val.toNum(rb))
    else
        val.toNum(p.get(if (std.mem.eql(u8, zone, "local")) "localBase" else "nationalBase"));
    const weight: f64 = if (is_express) 0 else val.jsMax(0, @ceil(kg - val.toNum(p.get("includedKg")))) * val.toNum(p.get("perKg"));
    const per_km = val.or0(if (is_express) express.get("perKm") else p.get("perKm"));
    const distance = val.jsRound(km * per_km);
    const cod_amount = val.toNum(req.get("codAmount"));
    const cod: f64 = if (cod_amount > 0) val.jsMax(val.or0(p.get("codMin")), val.jsRound((cod_amount * val.or0(p.get("codPercent"))) / 100)) else 0;
    const pieces = val.or0(parcel.get("pieces"));
    const value = val.toNum(parcel.get("value"));
    const surcharges = (if (parcel.get("fragile").truthy()) val.or0(p.get("fragileFee")) else 0) +
        val.jsMax(0, (if (pieces == 0) 1 else pieces) - 1) * val.or0(p.get("extraPieceFee")) +
        (if (value > 0) val.jsRound((value * val.or0(p.get("valuePercent"))) / 100) else 0);

    return val.from(a, .{
        .amount = base + weight + distance + cod + surcharges,
        .currency = carrier.path("carrier.currency"),
        .breakdown = .{ .base = base, .weight = weight, .distance = distance, .cod = cod, .surcharges = surcharges, .chargeableKg = kg },
        .zone = zone,
        .roadKm = km,
    });
}

/// Hours promised to the store: the express trip time, or the service level for the zone.
pub fn promiseHours(carrier: Val, zone: []const u8, service: ?[]const u8) f64 {
    if (service != null and std.mem.eql(u8, service.?, "express")) {
        const minutes = val.numOr(carrier.path("carrier.express.minutes"), 60);
        return val.jsRound((minutes / 60) * 100) / 100;
    }
    return slaHours(carrier, zone);
}

/// Why this carrier can't take an express order now (null = it can). Express is a direct trip
/// with its own limits: distance, weight and opening hours (Syrian time, UTC+3; `to` earlier
/// than `from` runs past midnight).
pub fn expressReason(a: std.mem.Allocator, carrier: Val, req: Val, now_ms: i64) !?[]const u8 {
    const e = carrier.path("carrier.express");
    if (!e.get("enabled").truthy()) return "express_not_offered";
    const km = try estimateRoadKm(a, req.get("pickup"), req.get("dropoff"));
    if (km == null or km.? > val.toNum(e.get("maxKm"))) return "express_too_far";
    if (val.toNum(req.get("weightKg")) > val.toNum(e.get("maxWeightKg"))) return "express_too_heavy";
    if (e.get("hours").truthy() and !openAt(e.get("hours"), now_ms)) return "express_closed";
    return null;
}

fn minutesOf(hhmm: []const u8) f64 {
    if (hhmm.len < 5) return std.math.nan(f64);
    return val.strToNum(hhmm[0..2]) * 60 + val.strToNum(hhmm[3..5]);
}

pub fn openAt(hours: Val, now_ms: i64) bool {
    const local = val.civil(now_ms + 3 * 3600_000);
    const m: f64 = @floatFromInt(local.hour * 60 + local.minute);
    const from = minutesOf(hours.s("from") orelse "");
    const to = minutesOf(hours.s("to") orelse "");
    return if (from <= to) m >= from and m < to else m >= from or m < to;
}

pub fn slaHours(carrier: Val, zone: []const u8) f64 {
    const sla = carrier.path("carrier.sla");
    return if (std.mem.eql(u8, zone, "local")) val.numOr(sla.get("localHours"), 24) else val.numOr(sla.get("nationalHours"), 72);
}
