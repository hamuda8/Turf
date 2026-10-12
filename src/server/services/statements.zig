//! Statements between a store and a carrier for a period (src/services/statements.js): every
//! billed shipment with its fee and collected cash, and the payout; plus each company's own
//! Turf fees per month.

const std = @import("std");
const val = @import("../lib/val.zig");
const db = @import("../lib/db.zig");
const web = @import("../web.zig");
const a_ = @import("../app.zig");
const relay = @import("relay.zig");
const Val = val.Val;
const Req = web.Req;
const Allocator = std.mem.Allocator;

/// Delivered and returned parcels are billed; cancelled ones are not.
const billed = [_][]const u8{ "delivered", "returned" };

pub const Period = struct { from: i64, to: i64, from_text: []const u8, to_text: []const u8 };

fn isDay(s: []const u8) bool {
    if (s.len != 10 or s[4] != '-' or s[7] != '-') return false;
    for ([_]usize{ 0, 1, 2, 3, 5, 6, 8, 9 }) |i| if (!std.ascii.isDigit(s[i])) return false;
    return true;
}

/// ?from=2026-10-01&to=2026-10-31 (inclusive UTC dates); the current month by default.
pub fn periodOf(r: *Req, from_q: ?[]const u8, to_q: ?[]const u8) !Period {
    const a = r.a;
    const parse = struct {
        fn f(rq: *Req, v: []const u8, field: []const u8) !i64 {
            if (!isDay(v)) return rq.badRequest("Dates must look like 2026-10-01", field, "date_format", null);
            return val.parseDate(v) orelse rq.badRequest("Invalid date", field, "date_format", null);
        }
    }.f;
    const now = val.civil(a_.nowMs());
    const from: i64 = if (from_q != null and from_q.?.len > 0) try parse(r, from_q.?, "from") else val.daysFromCivil(now.year, now.month, 1) * 86400_000;
    const to_day: i64 = if (to_q != null and to_q.?.len > 0) try parse(r, to_q.?, "to") else (val.daysFromCivil(now.year, now.month, 1) + val.daysInMonth(now.year, now.month) - 1) * 86400_000;
    const to = to_day + 86400_000;
    if (to <= from) return r.badRequest("The end date must be after the start date", "to", "date_order", null);
    if (to - from > 366 * 86400_000) return r.badRequest("A statement covers at most one year", "to", "range_max", .{ .n = 366 });
    return .{ .from = from, .to = to, .from_text = (try val.isoAlloc(a, from))[0..10], .to_text = (try val.isoAlloc(a, to_day))[0..10] };
}

pub fn statement(a: Allocator, carrier_id: Val, merchant_id: Val, from: i64, to: i64) !Val {
    // Relay shipments count for every carrier on the route, each with the price of its own leg;
    // the cash belongs to the carrier that collected it (the last one).
    const list = try db.col("shipments").find(a, .{
        .merchantId = merchant_id,
        .status = .{ .@"$in" = &billed },
        .statusAt = .{ .@"$gte" = val.Date{ .ms = from }, .@"$lt" = val.Date{ .ms = to } },
        .@"test" = .{ .@"$ne" = true },
        .@"$or" = .{ .{ .carrierId = carrier_id }, .{ .carrierIds = carrier_id } },
    }, .{
        .sort = try val.from(a, .{ .statusAt = 1 }),
        .projection = try val.from(a, .{ .trackingNumber = 1, .externalRef = 1, .status = 1, .statusAt = 1, .price = 1, .cod = 1, .legs = 1, .carrierId = 1, .@"dropoff.name" = 1, .@"dropoff.city" = 1, .merchantName = 1, .carrierName = 1 }),
        .limit = 20000,
    });
    const rows = try val.newArr(a);
    var fees: f64 = 0;
    var cod_total: f64 = 0;
    var delivered: usize = 0;
    var returned: usize = 0;
    for (list) |s| {
        const fee = try relay.carrierPrice(s, carrier_id);
        const cod: f64 = if (s.path("cod.collectedAt").truthy() and s.get("carrierId").sameId(carrier_id)) val.toNum(s.path("cod.amount")) else 0;
        fees += fee;
        cod_total += cod;
        const st = s.s("status") orelse "";
        if (std.mem.eql(u8, st, "delivered")) delivered += 1;
        if (std.mem.eql(u8, st, "returned")) returned += 1;
        try rows.push(.{
            .trackingNumber = s.get("trackingNumber"),
            .reference = if (s.t("externalRef")) s.get("externalRef") else Val{ .str = "" },
            .status = s.get("status"),
            .date = s.get("statusAt"),
            .recipient = if (s.path("dropoff.name").truthy()) s.path("dropoff.name") else Val{ .str = "" },
            .city = if (s.path("dropoff.city").truthy()) s.path("dropoff.city") else Val{ .str = "" },
            .shippingFee = fee,
            .codCollected = cod,
            .net = cod - fee,
            .paidOut = s.path("cod.remittedAt").truthy(),
        });
    }
    // Compensation the carrier agreed to pay (claims accepted in the period).
    const accepted = try db.col("claims").find(a, .{ .carrierId = carrier_id, .merchantId = merchant_id, .status = "accepted", .decidedAt = .{ .@"$gte" = val.Date{ .ms = from }, .@"$lt" = val.Date{ .ms = to } } }, .{});
    var compensation: f64 = 0;
    const claims_out = try val.newArr(a);
    for (accepted) |c| {
        compensation += val.or0(c.get("compensation"));
        try claims_out.push(.{ .trackingNumber = c.get("trackingNumber"), .type = c.get("type"), .compensation = c.get("compensation"), .decidedAt = c.get("decidedAt") });
    }
    var carrier_name: Val = .null;
    outer: for (list) |s| for (s.get("legs").items()) |l| if (l.get("carrierId").sameId(carrier_id)) {
        carrier_name = l.get("carrierName");
        break :outer;
    };
    if (carrier_name == .null) for (list) |s| if (s.get("carrierId").sameId(carrier_id)) {
        carrier_name = s.get("carrierName");
        break;
    };
    return val.from(a, .{
        .carrierName = carrier_name,
        .merchantName = if (list.len > 0) list[0].get("merchantName") else Val.null,
        .currency = if (list.len > 0 and list[0].path("price.currency").truthy()) list[0].path("price.currency") else Val.null,
        .totals = .{
            .delivered = delivered,
            .returned = returned,
            .shippingFees = fees,
            .codCollected = cod_total,
            .compensation = compensation,
            // Positive: the carrier owes the store. Negative: the store owes the carrier.
            .payout = cod_total - fees + compensation,
        },
        .rows = rows,
        .claims = claims_out,
    });
}

/// Companies one side has a statement with (shipments in the period).
pub fn counterparties(a: Allocator, side: []const u8, org_id: Val, from: i64, to: i64) !Val {
    const range = try val.from(a, .{ .@"$gte" = val.Date{ .ms = from }, .@"$lt" = val.Date{ .ms = to } });
    const list = if (std.mem.eql(u8, side, "carrier"))
        try db.col("shipments").aggregate(a, .{
            .{ .@"$match" = .{ .status = .{ .@"$in" = &billed }, .statusAt = range, .@"test" = .{ .@"$ne" = true }, .@"$or" = .{ .{ .carrierId = org_id }, .{ .carrierIds = org_id } } } },
            .{ .@"$group" = .{ ._id = "$merchantId", .name = .{ .@"$first" = "$merchantName" }, .shipments = .{ .@"$sum" = 1 } } },
            .{ .@"$sort" = .{ .name = 1 } },
        })
    else
        // A store has a statement with every carrier on each route (relay legs included).
        try db.col("shipments").aggregate(a, .{
            .{ .@"$match" = .{ .status = .{ .@"$in" = &billed }, .statusAt = range, .@"test" = .{ .@"$ne" = true }, .merchantId = org_id } },
            .{ .@"$project" = .{ .route = .{ .@"$ifNull" = .{ "$legs", .{.{ .carrierId = "$carrierId", .carrierName = "$carrierName" }} } } } },
            .{ .@"$unwind" = "$route" },
            .{ .@"$group" = .{ ._id = "$route.carrierId", .name = .{ .@"$first" = "$route.carrierName" }, .shipments = .{ .@"$sum" = 1 } } },
            .{ .@"$sort" = .{ .name = 1 } },
        });
    const out = try val.newArr(a);
    for (list) |x| try out.push(.{ .id = x.get("_id"), .name = x.get("name"), .shipments = x.get("shipments") });
    return out;
}

fn csvCell(a: Allocator, v: Val) ![]const u8 {
    const s: []const u8 = switch (v) {
        .date => |ms| blk: {
            const iso = try val.isoAlloc(a, ms);
            break :blk try std.fmt.allocPrint(a, "{s} {s}", .{ iso[0..10], iso[11..16] });
        },
        .null, .undef => "",
        else => try val.toStr(a, v),
    };
    // Quote everything; neutralize spreadsheet formulas in user-entered text.
    const risky = s.len > 0 and std.mem.indexOfScalar(u8, "=+-@\t\r", s[0]) != null;
    const numeric = s.len > 0 and (std.ascii.isDigit(s[0]) or (s[0] == '-' and s.len > 1 and std.ascii.isDigit(s[1])));
    const safe = if (risky and !numeric) try std.fmt.allocPrint(a, "'{s}", .{s}) else s;
    return std.fmt.allocPrint(a, "\"{s}\"", .{try std.mem.replaceOwned(u8, a, safe, "\"", "\"\"")});
}

fn csvLine(a: Allocator, cells: []const Val) ![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    for (cells) |c| try parts.append(a, try csvCell(a, c));
    return std.mem.join(a, ",", parts.items);
}

/// CSV with a UTF-8 BOM so Excel shows Arabic names correctly.
pub fn statementCsv(a: Allocator, st: Val, lang: []const u8) ![]const u8 {
    const ar = std.mem.eql(u8, lang, "ar");
    const head = if (ar)
        [_][]const u8{ "رقم التتبع", "المرجع", "الحالة", "التاريخ", "المستلم", "المدينة", "أجور الشحن", "المبلغ المحصل", "الصافي", "تم الدفع" }
    else
        [_][]const u8{ "Tracking number", "Reference", "Status", "Date", "Recipient", "City", "Shipping fee", "Cash collected", "Net", "Paid out" };
    var lines: std.ArrayList([]const u8) = .empty;
    var hv: [head.len]Val = undefined;
    for (head, 0..) |h, i| hv[i] = .{ .str = h };
    try lines.append(a, try csvLine(a, &hv));
    const yes: []const u8 = if (ar) "نعم" else "yes";
    for (st.get("rows").items()) |row| {
        const status = row.s("status") orelse "";
        const status_text: []const u8 = if (std.mem.eql(u8, status, "delivered")) (if (ar) "تم التسليم" else "Delivered") else if (std.mem.eql(u8, status, "returned")) (if (ar) "مرتجع" else "Returned") else status;
        try lines.append(a, try csvLine(a, &.{ row.get("trackingNumber"), row.get("reference"), .{ .str = status_text }, row.get("date"), row.get("recipient"), row.get("city"), row.get("shippingFee"), row.get("codCollected"), row.get("net"), .{ .str = if (row.t("paidOut")) yes else "" } }));
    }
    const t = st.get("totals");
    try lines.append(a, "");
    const e: Val = .{ .str = "" };
    if (t.get("compensation").truthy()) try lines.append(a, try csvLine(a, &.{ .{ .str = if (ar) "تعويضات" else "Compensation" }, e, e, e, e, e, e, e, t.get("compensation"), e }));
    try lines.append(a, try csvLine(a, &.{ .{ .str = if (ar) "المجموع" else "Total" }, e, e, e, e, e, t.get("shippingFees"), t.get("codCollected"), t.get("payout"), e }));
    return std.fmt.allocPrint(a, "\u{FEFF}{s}\r\n", .{try std.mem.join(a, "\r\n", lines.items)});
}

/// A company's Turf fees for one month, and what it has paid.
pub fn platformFeesFor(r: *Req, org_id: Val, month: []const u8) !Val {
    const a = r.a;
    const ok = month.len == 7 and month[4] == '-' and for ([_]usize{ 0, 1, 2, 3, 5, 6 }) |i| {
        if (!std.ascii.isDigit(month[i])) break false;
    } else true;
    if (!ok) return r.badRequest("month must look like 2026-10", "month", null, null);
    const y = try std.fmt.parseInt(i64, month[0..4], 10);
    const m = try std.fmt.parseInt(i64, month[5..7], 10);
    // Date.UTC rolls months over (month 13 is January of the next year).
    const from = (val.daysFromCivil(y + @divFloor(m - 1, 12), @mod(m - 1, 12) + 1, 1)) * 86400_000;
    const to = (val.daysFromCivil(y + @divFloor(m, 12), @mod(m, 12) + 1, 1)) * 86400_000;
    const owed = try db.col("shipments").aggregate(a, .{
        .{ .@"$match" = .{ .deliveredAt = .{ .@"$gte" = val.Date{ .ms = from }, .@"$lt" = val.Date{ .ms = to } }, .@"platformFees.orgId" = org_id } },
        .{ .@"$unwind" = "$platformFees" },
        .{ .@"$match" = .{ .@"platformFees.orgId" = org_id } },
        .{ .@"$group" = .{ ._id = "$platformFees.currency", .amount = .{ .@"$sum" = "$platformFees.amount" }, .shipments = .{ .@"$sum" = 1 } } },
    });
    const payments = try db.col("platform_payments").find(a, .{ .orgId = org_id, .month = month }, .{ .projection = try val.from(a, .{ .currency = 1, .amount = 1, .at = 1, .note = 1 }) });
    const lines = try val.newArr(a);
    for (owed) |o| {
        var paid: f64 = 0;
        for (payments) |p| if (p.get("currency").eql(o.get("_id"))) {
            paid += val.toNum(p.get("amount"));
        };
        const amount = val.toNum(o.get("amount"));
        try lines.push(.{ .currency = o.get("_id"), .amount = amount, .shipments = o.get("shipments"), .paid = paid, .due = val.jsMax(0, amount - paid) });
    }
    return val.from(a, .{ .month = month, .lines = lines, .payments = payments });
}
