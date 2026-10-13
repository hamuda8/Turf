//! Courier pay per task (src/services/earnings.js). The carrier sets the rates
//! (carrier.courierPay = { pickup, delivery, transfer, return, failed, perExtraParcel }); each
//! finished task stores what it paid (task.pay), so later rate changes don't rewrite history.

const std = @import("std");
const val = @import("mongo").val;
const db = @import("../lib/db.zig");
const web = @import("../web.zig");
const Val = val.Val;
const Req = web.Req;

pub const pay_fields = [_][]const u8{ "pickup", "delivery", "transfer", "return", "failed", "perExtraParcel" };

fn kind(task_type: []const u8) ?[]const u8 {
    const map = [_][2][]const u8{ .{ "pickup", "pickup" }, .{ "direct", "delivery" }, .{ "delivery", "delivery" }, .{ "transfer", "transfer" }, .{ "handover", "transfer" }, .{ "return", "return" } };
    for (map) |m| if (std.mem.eql(u8, m[0], task_type)) return m[1];
    return null;
}

pub fn parseCourierPay(r: *Req, value: Val) !Val {
    if (value == .null) return .null;
    const p = (try web.V.obj(r, value, "courierPay", .{})).?;
    const out = try val.newObj(r.a);
    for (pay_fields) |k| {
        const v = p.get(k);
        const n: f64 = if (v.isNullish() or (v == .str and v.str.len == 0)) 0 else (try web.V.num(r, v, try std.fmt.allocPrint(r.a, "courierPay.{s}", .{k}), .{ .min = 0, .max = 1e9 })).?;
        try out.obj.put(k, .{ .num = n });
    }
    return out;
}

/// What this task pays the courier, or null when the carrier set no rates.
pub fn payFor(a: std.mem.Allocator, carrier: Val, task: Val, outcome: []const u8) !Val {
    const rates = carrier.path("carrier.courierPay");
    if (!rates.truthy()) return .null;
    var amount: f64 = 0;
    const k = kind(task.s("type") orelse "");
    if (std.mem.eql(u8, outcome, "completed")) {
        const base = if (k) |kk| val.or0(rates.get(kk)) else 0;
        const extra: f64 = @floatFromInt(task.get("shipmentIds").items().len);
        amount = base + val.jsMax(0, extra - 1) * val.or0(rates.get("perExtraParcel"));
    } else if (std.mem.eql(u8, outcome, "failed") and k != null and std.mem.eql(u8, k.?, "delivery") and std.mem.eql(u8, task.s("status") orelse "", "in_progress")) {
        // Only when the courier actually went.
        amount = val.or0(rates.get("failed"));
    }
    return if (amount > 0) val.from(a, .{ .amount = amount, .currency = carrier.path("carrier.currency") }) else .null;
}

/// Finished tasks and pay for one courier between two dates.
pub fn courierSummary(a: std.mem.Allocator, carrier_id: Val, courier_id: Val, from: i64, to: i64) !Val {
    const f = val.Date{ .ms = from };
    const t = val.Date{ .ms = to };
    const rows = try db.col("tasks").aggregate(a, .{
        .{ .@"$match" = .{
            .carrierId = carrier_id,
            .courierId = courier_id,
            .status = .{ .@"$in" = .{ "completed", "failed" } },
            .@"$or" = .{ .{ .completedAt = .{ .@"$gte" = f, .@"$lt" = t } }, .{ .failedAt = .{ .@"$gte" = f, .@"$lt" = t } } },
        } },
        .{ .@"$group" = .{ ._id = .{ .type = "$type", .status = "$status" }, .n = .{ .@"$sum" = 1 }, .parcels = .{ .@"$sum" = .{ .@"$size" = "$shipmentIds" } }, .pay = .{ .@"$sum" = .{ .@"$ifNull" = .{ "$pay.amount", 0 } } } } },
    });
    var completed: f64 = 0;
    var failed: f64 = 0;
    var deliveries: f64 = 0;
    var pickups: f64 = 0;
    var parcels: f64 = 0;
    var pay: f64 = 0;
    for (rows) |row| {
        const st = row.path("_id.status").asStr() orelse "";
        const ty = row.path("_id.type").asStr() orelse "";
        const n = val.toNum(row.get("n"));
        if (std.mem.eql(u8, st, "completed")) completed += n else failed += n;
        pay += val.toNum(row.get("pay"));
        if (std.mem.eql(u8, st, "completed")) {
            parcels += val.toNum(row.get("parcels"));
            if (kind(ty)) |k| if (std.mem.eql(u8, k, "delivery")) {
                deliveries += n;
            };
            if (std.mem.eql(u8, ty, "pickup")) pickups += n;
        }
    }
    return val.from(a, .{ .completed = completed, .failed = failed, .deliveries = deliveries, .pickups = pickups, .parcels = parcels, .pay = pay });
}
