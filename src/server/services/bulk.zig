//! Bulk shipments (src/services/bulk.js): many shipments in one request (the store's CSV upload,
//! or POST /api/v1/shipments/bulk). Rows are shipment objects or flat CSV rows; each row is
//! validated and created on its own, and its result names the field that was wrong.

const std = @import("std");
const val = @import("mongo").val;
const web = @import("../web.zig");
const geo = @import("../geo.zig");
const shipments_ = @import("shipments.zig");
const testmode = @import("testmode.zig");
const places = @import("places.zig");
const Val = val.Val;
const Req = web.Req;
const Allocator = std.mem.Allocator;

pub const max_rows = 500;

pub const csv_columns = [_][]const u8{
    "reference", "recipient_name", "recipient_phone", "governorate", "city",       "area",    "street", "details", "lat",      "lng",
    "weight_kg", "pieces",         "description",     "value",       "cod_amount", "fragile", "notes",  "carrier", "strategy", "length_cm",
    "width_cm",  "height_cm",      "pickup",          "service",
};

fn norm(a: Allocator, v: Val) ![]const u8 {
    if (v.isNullish()) return "";
    return val.jsTrim(try val.toStr(a, v));
}

fn yes(a: Allocator, v: Val) !bool {
    const s = try val.lower(a, try norm(a, v));
    for ([_][]const u8{ "1", "true", "yes", "y", "نعم" }) |x| if (std.mem.eql(u8, s, x)) return true;
    return false;
}

/// Number(text without commas), or undefined for an empty cell.
fn num(a: Allocator, v: Val) !Val {
    const s = try norm(a, v);
    if (s.len == 0) return .undef;
    return .{ .num = val.strToNum(try std.mem.replaceOwned(u8, a, s, ",", "")) };
}

fn orUndef(s: []const u8) Val {
    return if (s.len > 0) .{ .str = s } else .undef;
}

/// A flat CSV row -> the normal shipment body.
pub fn rowToBody(a: Allocator, row: Val, merchant: Val) !Val {
    if (row.isObj() and row.get("dropoff").truthy()) return row;
    const r = if (row.isObj()) row else try val.newObj(a);
    // A pickup place may be named by its label in a spreadsheet.
    const pick = try norm(a, r.get("pickup"));
    if (pick.len > 0 and merchant.truthy()) {
        const want = try val.lower(a, pick);
        for (try places.placesOf(a, merchant)) |p| {
            const label = try val.lower(a, val.jsTrim(p.s("label") orelse ""));
            if (std.mem.eql(u8, label, want)) {
                try r.set("pickup", try val.toStr(a, p.get("_id")));
                break;
            }
        }
    }
    const lat = try num(a, r.get("lat"));
    const lng = try num(a, r.get("lng"));
    const lc = try num(a, r.get("length_cm"));
    const wc = try num(a, r.get("width_cm"));
    const hc = try num(a, r.get("height_cm"));
    const cod = try num(a, r.get("cod_amount"));
    const gov = try norm(a, r.get("governorate"));
    return val.from(a, .{
        .reference = orUndef(try norm(a, r.get("reference"))),
        .dropoff = .{
            .name = try norm(a, r.get("recipient_name")),
            .phone = try norm(a, r.get("recipient_phone")),
            .governorate = if (gov.len > 0) (if (try geo.governorateCode(a, r.get("governorate"), false)) |c| Val{ .str = c } else Val.undef) else Val.undef,
            .city = orUndef(try norm(a, r.get("city"))),
            .area = orUndef(try norm(a, r.get("area"))),
            .street = orUndef(try norm(a, r.get("street"))),
            .details = orUndef(try norm(a, r.get("details"))),
            .location = if (lat != .undef and lng != .undef) try val.from(a, .{ .lat = lat, .lng = lng }) else Val.undef,
        },
        .pickup = orUndef(try norm(a, r.get("pickup"))),
        .parcel = .{
            .weightKg = try num(a, r.get("weight_kg")),
            .pieces = try num(a, r.get("pieces")),
            .description = orUndef(try norm(a, r.get("description"))),
            .value = try num(a, r.get("value")),
            .fragile = try yes(a, r.get("fragile")),
            .dimensionsCm = if (lc.truthy() or wc.truthy() or hc.truthy()) try val.from(a, .{ .length = lc, .width = wc, .height = hc }) else Val.undef,
        },
        .cod = if (cod.truthy()) try val.from(a, .{ .amount = cod }) else Val.undef,
        .notes = orUndef(try norm(a, r.get("notes"))),
        .carrier = if ((try norm(a, r.get("carrier"))).len > 0) Val{ .str = try norm(a, r.get("carrier")) } else Val{ .str = "auto" },
        .strategy = orUndef(try norm(a, r.get("strategy"))),
        .service = orUndef(try val.lower(a, try norm(a, r.get("service")))),
    });
}

pub fn createBulk(r: *Req, merchant: Val, rows: Val, actor: Val, test_mode: bool) ![]Val {
    const a = r.a;
    if (rows != .arr or rows.items().len == 0) return r.badRequest("rows must be a non-empty list", "rows", "rows_empty", null);
    if (rows.items().len > max_rows) return r.badRequest(try std.fmt.allocPrint(a, "At most {d} shipments per upload", .{max_rows}), "rows", "rows_max", .{ .n = max_rows });
    var results: std.ArrayList(Val) = .empty;
    for (rows.items(), 0..) |row, i| {
        const one = struct {
            fn f(rq: *Req, m: Val, rw: Val, act: Val, t: bool) !Val {
                const input = try shipments_.prepareShipmentInput(rq, try rowToBody(rq.a, rw, m), m, false);
                return if (t) testmode.createTestShipment(rq, m, input, act) else shipments_.createShipment(rq, m, input, act);
            }
        }.f;
        const res = one(r, merchant, row, actor, test_mode) catch |err| {
            if (err != error.Http) return err;
            const e = r.err.?;
            r.err = null;
            // rule/params (when known) let apps show the message in the user's language.
            const out = try val.from(a, .{ .code = e.code, .message = e.message, .field = if (e.extra.get("field").truthy()) e.extra.get("field") else Val.null });
            if (e.extra.get("rule").truthy()) try out.set("rule", e.extra.get("rule"));
            if (e.extra.get("params").truthy()) try out.set("params", e.extra.get("params"));
            try results.append(a, try val.from(a, .{ .row = i + 1, .ok = false, .@"error" = out }));
            continue;
        };
        try results.append(a, try val.from(a, .{ .row = i + 1, .ok = true, .created = res.get("created"), .shipment = res.get("shipment") }));
    }
    return results.items;
}
