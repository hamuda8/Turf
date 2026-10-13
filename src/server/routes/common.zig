//! Small pieces several route files share: report routes, query helpers, photo and CSV answers.

const std = @import("std");
const val = @import("../lib/val.zig");
const db = @import("../lib/db.zig");
const web = @import("../web.zig");
const reports = @import("../services/reports.zig");
const Val = val.Val;
const Req = web.Req;

/// GET /reports for a store ('merchant') or a carrier. Money needs finance access.
pub fn reportFor(comptime side: []const u8) web.Handler {
    return struct {
        fn f(r: *Req) anyerror!void {
            const oc = r.orgCtx();
            const report = try reports.buildReport(r.a, side, oc.org, try reports.parseRange(r, r.qs("from"), r.qs("to")));
            if (!oc.perms.has("finance.view")) {
                try report.set("money", null);
                try report.set("cod", null);
                for (report.get("byCourier").items()) |c| c.del("pay");
            }
            return r.json(200, report);
        }
    }.f;
}

/// GET /reports/shipments: one row per shipment, for spreadsheets.
pub fn reportRowsFor(comptime side: []const u8) web.Handler {
    return struct {
        fn f(r: *Req) anyerror!void {
            const oc = r.orgCtx();
            const rows = try reports.exportRows(r, side, oc.org, try reports.parseRange(r, r.qs("from"), r.qs("to")));
            if (!oc.perms.has("finance.view")) for (rows) |row| {
                row.del("price");
                row.del("currency");
            };
            return r.json(200, rows);
        }
    }.f;
}

/// `req.query[name] ? new Date(...)` when it is a valid date, else null.
pub fn dateQuery(r: *Req, name: []const u8) ?i64 {
    const s = r.qs(name) orelse return null;
    if (s.len == 0) return null;
    return val.newDate(.{ .str = s });
}

/// `Number(v) || d`
pub fn numberOr(v: Val, d: f64) f64 {
    const s = if (v == .arr) v.at(0) else v;
    if (s.isNullish()) return d;
    const x = val.toNum(s);
    return if (std.math.isNan(x) or x == 0) d else x;
}

/// A proof-of-delivery photo.
pub fn sendPhoto(r: *Req, photo_id: Val) !void {
    const photo = (try db.col("pod_photos").findOne(r.a, .{ ._id = photo_id }, .{})) orelse return r.notFound("Photo");
    try r.setHeader("cache-control", "private, max-age=3600");
    return r.send(200, "image/jpeg", photo.get("data").bin);
}

/// res.type('text/csv').attachment(name).send(csv); the name keeps letters, digits, '.', '_', '-'.
pub fn sendCsv(r: *Req, name: []const u8, csv: []const u8) !void {
    var clean: std.ArrayList(u8) = .empty;
    var dash = false;
    for (name) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '-') {
            try clean.append(r.a, c);
            dash = false;
        } else if (!dash) {
            try clean.append(r.a, '-');
            dash = true;
        }
    }
    try r.setHeader("content-disposition", try std.fmt.allocPrint(r.a, "attachment; filename=\"{s}\"", .{clean.items}));
    return r.send(200, "text/csv; charset=utf-8", csv);
}
