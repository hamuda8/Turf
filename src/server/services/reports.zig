//! Reports for a period (src/services/reports.js): volumes, delivery and on-time rates, cash on
//! delivery, money, and breakdowns per governorate and per carrier (stores) or courier
//! (carriers). Shipments count in the period they were created; test shipments never count.

const std = @import("std");
const val = @import("mongo").val;
const db = @import("../lib/db.zig");
const web = @import("../web.zig");
const a_ = @import("../app.zig");
const messages = @import("../messages.zig");
const relay = @import("relay.zig");
const Val = val.Val;
const Req = web.Req;
const Allocator = std.mem.Allocator;

const max_days = 366;
/// Syria, UTC+3: days start at local midnight.
const tz_ms = 3 * 3600_000;
const max_export = 20000;

pub const Range = struct { from: i64, to: i64, from_day: []const u8, to_day: []const u8 };

fn isDay(s: []const u8) bool {
    if (s.len != 10 or s[4] != '-' or s[7] != '-') return false;
    for ([_]usize{ 0, 1, 2, 3, 5, 6, 8, 9 }) |i| if (!std.ascii.isDigit(s[i])) return false;
    return true;
}

fn localDay(a: Allocator, ms: i64) ![]const u8 {
    return (try val.isoAlloc(a, ms + tz_ms))[0..10];
}

/// "2026-10-01".."2026-10-31" (local days, both included) -> [from, to).
pub fn parseRange(r: *Req, from_q: ?[]const u8, to_q: ?[]const u8) !Range {
    const a = r.a;
    const now = a_.nowMs();
    const f = if (from_q != null and from_q.?.len > 0) from_q.? else try localDay(a, now - 29 * 86400_000);
    const t = if (to_q != null and to_q.?.len > 0) to_q.? else try localDay(a, now);
    if (!isDay(f)) return r.badRequest("from must be a date like 2026-10-01", "from", "date_format", null);
    if (!isDay(t)) return r.badRequest("to must be a date like 2026-10-31", "to", "date_format", null);
    const fd = val.parseDate(f) orelse return r.badRequest("Invalid date", "from", "date_format", null);
    const td = val.parseDate(t) orelse return r.badRequest("Invalid date", "from", "date_format", null);
    const from = fd - tz_ms;
    const to = td - tz_ms + 86400_000;
    if (to <= from) return r.badRequest("to must be on or after from", "to", "date_order", null);
    if (@divFloor(to - from, 86400_000) > max_days) return r.badRequest(try std.fmt.allocPrint(a, "At most {d} days at a time", .{max_days}), "from", "range_max", .{ .n = max_days });
    return .{ .from = from, .to = to, .from_day = f, .to_day = t };
}

fn pct(n: f64, d: f64) Val {
    return if (d != 0) .{ .num = val.jsRound((n / d) * 1000) / 10 } else .null;
}

fn scope(a: Allocator, side: []const u8, org_id: Val) !Val {
    // A carrier sees every shipment it carried a leg of (relays included).
    if (std.mem.eql(u8, side, "carrier")) return val.from(a, .{ .@"$or" = .{ .{ .carrierId = org_id }, .{ .carrierIds = org_id } }, .@"test" = .{ .@"$ne" = true } });
    return val.from(a, .{ .merchantId = org_id, .@"test" = .{ .@"$ne" = true } });
}

const Group = struct {
    total: f64 = 0,
    delivered: f64 = 0,
    returned: f64 = 0,
    cancelled: f64 = 0,
    lost: f64 = 0,
    open: f64 = 0,
    on_time: f64 = 0,
    late: f64 = 0,
    hours: f64 = 0,
    first_attempt: f64 = 0,
    ratings: f64 = 0,
    rating_sum: f64 = 0,
    problems: f64 = 0,

    fn add(g: *Group, s: Val) void {
        g.total += 1;
        if (s.path("feedback.rating").truthy()) {
            g.ratings += 1;
            g.rating_sum += val.toNum(s.path("feedback.rating"));
        }
        if (s.path("feedback.problem").truthy()) g.problems += 1;
        const st = s.s("status") orelse "";
        if (std.mem.eql(u8, st, "delivered")) {
            g.delivered += 1;
            const d = s.get("deliveredAt").dateMs();
            const p = s.get("promisedBy").dateMs();
            if (p != null and d != null) {
                if (d.? <= p.?) g.on_time += 1 else g.late += 1;
            }
            if (d) |dd| g.hours += @as(f64, @floatFromInt(dd - (s.get("createdAt").dateMs() orelse dd))) / 3600_000;
            if (val.or0(s.get("attempts")) <= 1) g.first_attempt += 1;
        } else if (std.mem.eql(u8, st, "returned")) {
            g.returned += 1;
        } else if (std.mem.eql(u8, st, "cancelled")) {
            g.cancelled += 1;
        } else if (std.mem.eql(u8, st, "lost")) {
            g.lost += 1;
        } else if (!messages.isFinal(st)) g.open += 1;
    }

    fn finish(g: Group, a: Allocator) !Val {
        const finished = g.delivered + g.returned + g.lost;
        return val.from(a, .{
            .total = g.total,
            .delivered = g.delivered,
            .returned = g.returned,
            .cancelled = g.cancelled,
            .lost = g.lost,
            .open = g.open,
            .deliveryRate = pct(g.delivered, finished),
            .onTimeRate = pct(g.on_time, g.on_time + g.late),
            .firstAttemptRate = pct(g.first_attempt, g.delivered),
            .avgHours = if (g.delivered != 0) Val{ .num = val.jsRound((g.hours / g.delivered) * 10) / 10 } else Val.null,
            .avgRating = if (g.ratings != 0) Val{ .num = val.jsRound((g.rating_sum / g.ratings) * 10) / 10 } else Val.null,
            .ratings = g.ratings,
            .problems = g.problems,
        });
    }
};

const GroupMap = std.StringArrayHashMapUnmanaged(Group);

fn groupOf(a: Allocator, m: *GroupMap, key: []const u8) !*Group {
    const gop = try m.getOrPut(a, key);
    if (!gop.found_existing) gop.value_ptr.* = .{};
    return gop.value_ptr;
}

fn byTotalDesc(_: void, x: Val, y: Val) bool {
    return val.toNum(y.get("total")) - val.toNum(x.get("total")) < 0;
}

/// The report for a store ('merchant') or a shipping company ('carrier').
pub fn buildReport(a: Allocator, side: []const u8, org: Val, range: Range) !Val {
    const q = try val.spread(a, .{ try scope(a, side, org.get("_id")), .{ .createdAt = .{ .@"$gte" = val.Date{ .ms = range.from }, .@"$lt" = val.Date{ .ms = range.to } } } });
    const list = try db.col("shipments").find(a, q, .{ .projection = try val.from(a, .{ .status = 1, .createdAt = 1, .deliveredAt = 1, .promisedBy = 1, .attempts = 1, .zone = 1, .carrierId = 1, .carrierIds = 1, .legs = 1, .@"dropoff.governorate" = 1, .price = 1, .cod = 1, .carrierName = 1, .feedback = 1 }) });
    const is_merchant = std.mem.eql(u8, side, "merchant");
    var all: Group = .{};
    var by_day: std.StringArrayHashMapUnmanaged([2]f64) = .empty;
    var by_gov: GroupMap = .empty;
    var by_zone: GroupMap = .empty;
    var by_carrier: GroupMap = .empty;
    var money: std.StringArrayHashMapUnmanaged([2]f64) = .empty;
    var cod: std.StringArrayHashMapUnmanaged([4]f64) = .empty;

    for (list) |s| {
        all.add(s);
        const day = try localDay(a, s.get("createdAt").dateMs() orelse 0);
        const d = try by_day.getOrPut(a, day);
        if (!d.found_existing) d.value_ptr.* = .{ 0, 0 };
        d.value_ptr[0] += 1;
        const st = s.s("status") orelse "";
        if (std.mem.eql(u8, st, "delivered")) d.value_ptr[1] += 1;
        (try groupOf(a, &by_gov, if (s.path("dropoff.governorate").truthy()) try val.toStr(a, s.path("dropoff.governorate")) else "-")).add(s);
        (try groupOf(a, &by_zone, if (s.t("zone")) try val.toStr(a, s.get("zone")) else "-")).add(s);
        if (is_merchant) {
            // Relays: the first company (it took the order).
            const first = s.get("carrierIds").at(0);
            const id = if (first.truthy()) try val.toStr(a, first) else if (s.t("carrierId")) try val.toStr(a, s.get("carrierId")) else "-";
            (try groupOf(a, &by_carrier, id)).add(s);
        }
        const currency = s.path("price.currency");
        if (!std.mem.eql(u8, st, "cancelled") and currency.truthy()) {
            const m = try money.getOrPut(a, try val.toStr(a, currency));
            if (!m.found_existing) m.value_ptr.* = .{ 0, 0 };
            m.value_ptr[0] += if (is_merchant) val.or0(s.path("price.amount")) else try relay.carrierPrice(s, org.get("_id"));
            m.value_ptr[1] += 1;
        }
        // Cash: the store sees all of it; a carrier only what its own couriers handle (last leg).
        const amount = s.path("cod.amount");
        if (amount.truthy() and (is_merchant or s.get("carrierId").sameId(org.get("_id")))) {
            const c = try cod.getOrPut(a, try val.toStr(a, s.path("cod.currency")));
            if (!c.found_existing) c.value_ptr.* = .{ 0, 0, 0, 0 };
            const x = val.toNum(amount);
            if (!std.mem.eql(u8, st, "cancelled")) c.value_ptr[0] += x;
            if (s.path("cod.collectedAt").truthy()) c.value_ptr[1] += x;
            if (s.path("cod.settledAt").truthy()) c.value_ptr[2] += x;
            if (s.path("cod.remittedAt").truthy()) c.value_ptr[3] += x;
        }
    }

    const days = try val.newArr(a);
    var t = range.from;
    while (t < range.to) : (t += 86400_000) {
        const k = try localDay(a, t);
        const v = by_day.get(k) orelse .{ 0, 0 };
        try days.push(.{ .day = k, .created = v[0], .delivered = v[1] });
    }
    var gov_list: std.ArrayList(Val) = .empty;
    for (by_gov.keys(), by_gov.values()) |k, g| try gov_list.append(a, try val.spread(a, .{ .{ .governorate = k }, try g.finish(a) }));
    std.mem.sort(Val, gov_list.items, {}, byTotalDesc);
    const zones = try val.newArr(a);
    for (by_zone.keys(), by_zone.values()) |k, g| try zones.push(try val.spread(a, .{ .{ .zone = k }, try g.finish(a) }));
    const money_out = try val.newArr(a);
    for (money.keys(), money.values()) |k, m| try money_out.push(.{ .currency = k, .amount = m[0], .count = m[1] });
    const cod_out = try val.newArr(a);
    for (cod.keys(), cod.values()) |k, c| try cod_out.push(.{ .currency = k, .expected = c[0], .collected = c[1], .settled = c[2], .remitted = c[3] });

    const report = try val.from(a, .{
        .from = range.from_day,
        .to = range.to_day,
        .totals = try all.finish(a),
        .byDay = days,
        .byGovernorate = gov_list.items,
        .byZone = zones,
        .money = money_out,
        .cod = cod_out,
    });
    if (is_merchant) {
        const ids = try val.newArr(a);
        for (by_carrier.keys()) |k| if (web.oidStr(k)) |id| try ids.push(id);
        const names = try db.col("orgs").find(a, .{ ._id = .{ .@"$in" = ids } }, .{ .projection = try val.from(a, .{ .name = 1 }) });
        var out: std.ArrayList(Val) = .empty;
        for (by_carrier.keys(), by_carrier.values()) |k, g| {
            var name: Val = .{ .str = "—" };
            for (names) |n| if (std.mem.eql(u8, try val.toStr(a, n.get("_id")), k)) {
                if (n.t("name")) name = n.get("name");
            };
            try out.append(a, try val.spread(a, .{ .{ .carrierId = k, .name = name }, try g.finish(a) }));
        }
        std.mem.sort(Val, out.items, {}, byTotalDesc);
        try report.set("byCarrier", out.items);
    } else try report.set("byCourier", try courierReport(a, org.get("_id"), range));
    return report;
}

const CourierRow = struct { id: []const u8, name: Val, tasks: f64 = 0, deliveries: f64 = 0, pickups: f64 = 0, failed: f64 = 0, parcels: f64 = 0, on_time: f64 = 0, late: f64 = 0, pay: f64 = 0, ratings: f64 = 0, rating_sum: f64 = 0, problems: f64 = 0 };

/// Per courier: finished tasks in the period, on time against the shipment's promise, and pay.
fn courierReport(a: Allocator, carrier_id: Val, range: Range) !Val {
    const from_d = val.Date{ .ms = range.from };
    const to_d = val.Date{ .ms = range.to };
    const tasks = try db.col("tasks").find(a, .{
        .carrierId = carrier_id,
        .courierId = .{ .@"$ne" = null },
        .status = .{ .@"$in" = .{ "completed", "failed" } },
        .@"$or" = .{ .{ .completedAt = .{ .@"$gte" = from_d, .@"$lt" = to_d } }, .{ .failedAt = .{ .@"$gte" = from_d, .@"$lt" = to_d } } },
    }, .{ .projection = try val.from(a, .{ .courierId = 1, .type = 1, .status = 1, .completedAt = 1, .shipmentIds = 1, .pay = 1 }) });
    const isDelivery = struct {
        fn f(ty: []const u8) bool {
            return std.mem.eql(u8, ty, "delivery") or std.mem.eql(u8, ty, "direct");
        }
    }.f;
    const delivery_ids = try val.newArr(a);
    for (tasks) |task| if (std.mem.eql(u8, task.s("status") orelse "", "completed") and isDelivery(task.s("type") orelse "")) {
        for (task.get("shipmentIds").items()) |id| try delivery_ids.push(id);
    };
    const delivered = try db.col("shipments").find(a, .{ ._id = .{ .@"$in" = delivery_ids } }, .{ .projection = try val.from(a, .{ .promisedBy = 1, .feedback = 1 }) });
    const courier_ids = try val.newArr(a);
    for (tasks) |task| if (!val.includesId(courier_ids, task.get("courierId"))) try courier_ids.push(task.get("courierId"));
    const members = try db.col("memberships").find(a, .{ ._id = .{ .@"$in" = courier_ids } }, .{ .projection = try val.from(a, .{ .name = 1 }) });

    var by: std.StringArrayHashMapUnmanaged(CourierRow) = .empty;
    for (tasks) |task| {
        const id = try val.toStr(a, task.get("courierId"));
        const gop = try by.getOrPut(a, id);
        if (!gop.found_existing) {
            var name: Val = .{ .str = "—" };
            for (members) |m| if (std.mem.eql(u8, try val.toStr(a, m.get("_id")), id)) {
                if (m.t("name")) name = m.get("name");
            };
            gop.value_ptr.* = .{ .id = id, .name = name };
        }
        const c = gop.value_ptr;
        c.tasks += 1;
        c.pay += val.or0(task.path("pay.amount"));
        if (std.mem.eql(u8, task.s("status") orelse "", "failed")) {
            c.failed += 1;
            continue;
        }
        c.parcels += @floatFromInt(task.get("shipmentIds").items().len);
        const ty = task.s("type") orelse "";
        if (std.mem.eql(u8, ty, "pickup")) c.pickups += 1;
        if (isDelivery(ty)) {
            c.deliveries += 1;
            var s: Val = .undef;
            for (delivered) |x| if (x.get("_id").sameId(task.get("shipmentIds").at(0))) {
                s = x;
                break;
            };
            if (s.get("promisedBy").dateMs()) |p| {
                if ((task.get("completedAt").dateMs() orelse 0) <= p) c.on_time += 1 else c.late += 1;
            }
            // The recipient's rating counts for the courier who delivered.
            const fb = s.get("feedback");
            const mine = std.mem.eql(u8, try val.toStr(a, fb.get("courierId")), id);
            if (fb.get("rating").truthy() and mine) {
                c.ratings += 1;
                c.rating_sum += val.toNum(fb.get("rating"));
            }
            if (fb.get("problem").truthy() and mine) c.problems += 1;
        }
    }
    var out: std.ArrayList(Val) = .empty;
    for (by.values()) |c| try out.append(a, try val.from(a, .{
        .courierId = c.id,
        .name = c.name,
        .tasks = c.tasks,
        .deliveries = c.deliveries,
        .pickups = c.pickups,
        .failed = c.failed,
        .parcels = c.parcels,
        .pay = c.pay,
        .ratings = c.ratings,
        .problems = c.problems,
        .avgRating = if (c.ratings != 0) Val{ .num = val.jsRound((c.rating_sum / c.ratings) * 10) / 10 } else Val.null,
        .successRate = pct(c.deliveries, c.deliveries + c.failed),
        .onTimeRate = pct(c.on_time, c.on_time + c.late),
    }));
    const Cmp = struct {
        fn lt(_: void, x: Val, y: Val) bool {
            return val.toNum(y.get("tasks")) - val.toNum(x.get("tasks")) < 0;
        }
    };
    std.mem.sort(Val, out.items, {}, Cmp.lt);
    return val.arrOf(a, out.items);
}

/// One row per shipment in the period, for spreadsheets.
pub fn exportRows(r: *Req, side: []const u8, org: Val, range: Range) ![]Val {
    const a = r.a;
    const q = try val.spread(a, .{ try scope(a, side, org.get("_id")), .{ .createdAt = .{ .@"$gte" = val.Date{ .ms = range.from }, .@"$lt" = val.Date{ .ms = range.to } } } });
    const list = try db.col("shipments").find(a, q, .{ .sort = try val.from(a, .{ .createdAt = 1 }), .limit = max_export + 1 });
    if (list.len > max_export) return r.badRequest(try std.fmt.allocPrint(a, "More than {d} shipments: choose a shorter period", .{max_export}), "from", "export_too_many", .{ .n = max_export });
    const carrier_side = std.mem.eql(u8, side, "carrier");
    var out: std.ArrayList(Val) = .empty;
    for (list) |s| {
        const d = s.get("deliveredAt").dateMs();
        const p = s.get("promisedBy").dateMs();
        const fb = s.get("feedback");
        try out.append(a, try val.from(a, .{
            .trackingNumber = s.get("trackingNumber"),
            .reference = if (s.t("externalRef")) s.get("externalRef") else Val.null,
            .createdAt = s.get("createdAt"),
            .status = s.get("status"),
            .carrier = if (s.t("carrierName")) s.get("carrierName") else Val.null,
            .zone = s.get("zone"),
            .from = s.path("pickup.governorate"),
            .to = s.path("dropoff.governorate"),
            .city = s.path("dropoff.city"),
            .recipient = s.path("dropoff.name"),
            .weightKg = s.path("parcel.weightKg"),
            .price = if (carrier_side) Val{ .num = try relay.carrierPrice(s, org.get("_id")) } else s.path("price.amount"),
            .currency = s.path("price.currency"),
            .codAmount = if (s.path("cod.amount").truthy()) s.path("cod.amount") else Val{ .num = 0 },
            .codCollectedAt = if (s.path("cod.collectedAt").truthy()) s.path("cod.collectedAt") else Val.null,
            .promisedBy = if (s.t("promisedBy")) s.get("promisedBy") else Val.null,
            .deliveredAt = if (s.t("deliveredAt")) s.get("deliveredAt") else Val.null,
            .onTime = if (d != null and p != null) Val{ .bool = d.? <= p.? } else Val.null,
            .attempts = if (s.t("attempts")) s.get("attempts") else Val{ .num = 0 },
            .rating = if (fb.get("rating").isNullish()) Val.null else fb.get("rating"),
            .problem = if (fb.get("problem").isNullish()) Val.null else fb.get("problem"),
        }));
    }
    return out.items;
}
