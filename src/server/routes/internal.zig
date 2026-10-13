//! Server-to-server endpoints for Wufour (src/routes/internal.js). Callers send the shared
//! secret INTERNAL_API_KEY in "X-Internal-Key"; without that variable the endpoints are off.
//!
//! POST /api/internal/search { userId, query, limit }: shipments of the person's companies.
//! POST /api/internal/track { query, lang }: one tracking number, for the Wufour start page.

const std = @import("std");
const val = @import("mongo").val;
const db = @import("../lib/db.zig");
const web = @import("../web.zig");
const a_ = @import("../app.zig");
const crypto = @import("../crypto.zig");
const shipments = @import("../services/shipments.zig");
const Val = val.Val;
const Req = web.Req;
const route = web.route;
const routeMw = web.routeMw;

pub fn handle(r: *Req, path: []const u8) !void {
    try web.parseBody(r, 64 * 1024);
    if (try web.runRoutes(r, &routes, path)) return;
    return r.fail(404, "not_found", "No such endpoint", .{});
}

const routes = [_]web.Route{
    routeMw(.POST, "/search", &.{requireInternalKey}, search),
    routeMw(.POST, "/track", &.{requireInternalKey}, track),
};

fn requireInternalKey(r: *Req) anyerror!void {
    const expected = a_.cfg().internal_api_key;
    const given = r.header("x-internal-key") orelse "";
    if (!(expected.len >= 32 and crypto.safeEqual(given, expected))) return r.fail(401, "unauthenticated", "Unauthorized", .{});
}

fn bodyStr(r: *Req, key: []const u8) ![]const u8 {
    const v = r.body.get(key);
    if (!v.truthy()) return "";
    return val.toStr(r.a, v);
}

fn search(r: *Req) !void {
    const a = r.a;
    const query = val.jsSlice(val.jsTrim(try bodyStr(r, "query")), 60);
    const parsed = val.parseIntJs(try bodyStr(r, "limit"));
    const limit = @min(@max(if (std.math.isNan(parsed) or parsed == 0) 8 else parsed, 1), 20);
    const user_id = try bodyStr(r, "userId");
    const empty = .{ .results = .{} };
    if (val.jsLength(query) < 2 or user_id.len == 0) return r.json(200, empty);

    const memberships = try db.col("memberships").find(a, .{ .userId = user_id, .status = .{ .@"$ne" = "removed" } }, .{ .projection = try val.from(a, .{ .orgId = 1 }) });
    if (memberships.len == 0) return r.json(200, empty);
    const mids = try val.newArr(a);
    for (memberships) |m| try mids.push(m.get("orgId"));
    const orgs = try db.col("orgs").find(a, .{ ._id = .{ .@"$in" = mids }, .status = .{ .@"$ne" = "closed" } }, .{ .projection = try val.from(a, .{ .name = 1, .slug = 1, .type = 1, .personal = 1 }) });
    const ids = try val.newArr(a);
    for (orgs) |o| try ids.push(o.get("_id"));
    if (ids.items().len == 0) return r.json(200, empty);

    const list = try shipments.listShipments(a, try val.from(a, .{ .@"$or" = .{ .{ .merchantId = .{ .@"$in" = ids } }, .{ .carrierId = .{ .@"$in" = ids } }, .{ .carrierIds = .{ .@"$in" = ids } } } }), .{ .q = query, .limit = @intFromFloat(limit) });
    const results = try val.newArr(a);
    for (list) |s| {
        var org: Val = .undef;
        for (orgs) |o| if (o.get("_id").sameId(s.get("merchantId"))) {
            org = o;
            break;
        };
        if (org == .undef) for (orgs) |o| if (o.get("_id").sameId(s.get("carrierId"))) {
            org = o;
            break;
        };
        if (org == .undef) outer: for (orgs) |o| for (s.get("carrierIds").items()) |cid| if (cid.sameId(o.get("_id"))) {
            org = o;
            break :outer;
        };
        const url = if (org != .undef and !org.t("personal"))
            try std.fmt.allocPrint(a, "/o/{s}/shipments/{s}", .{ try val.toStr(a, org.get("slug")), try val.toStr(a, s.get("_id")) })
        else if (s.t("publicToken")) try std.fmt.allocPrint(a, "/t/{s}", .{try val.toStr(a, s.get("publicToken"))}) else "/app";
        const name = s.path("dropoff.name");
        const title = if (name.truthy()) try std.fmt.allocPrint(a, "{s} · {s}", .{ try val.toStr(a, s.get("trackingNumber")), try val.toStr(a, name) }) else try val.toStr(a, s.get("trackingNumber"));
        var parts: std.ArrayList([]const u8) = .empty;
        const status = try std.mem.replaceOwned(u8, a, s.s("status") orelse "", "_", " ");
        if (status.len > 0) try parts.append(a, status);
        if (s.path("dropoff.city").truthy()) try parts.append(a, try val.toStr(a, s.path("dropoff.city")));
        if (org.t("name")) try parts.append(a, try val.toStr(a, org.get("name")));
        const created = s.get("createdAt").dateMs();
        try results.push(.{
            .kind = "shipment",
            .title = title,
            .subtitle = try std.mem.join(a, " · ", parts.items),
            .meta = if (created) |c| (try val.isoAlloc(a, c))[0..10] else "",
            .url = url,
        });
    }
    return r.json(200, .{ .results = results });
}

fn tone(status: []const u8) []const u8 {
    const map = [_][2][]const u8{ .{ "delivered", "ok" }, .{ "returned", "bad" }, .{ "cancelled", "bad" }, .{ "lost", "bad" }, .{ "delivery_failed", "warn" }, .{ "no_carrier_found", "bad" } };
    for (map) |m| if (std.mem.eql(u8, m[0], status)) return m[1];
    return "active";
}

fn track(r: *Req) !void {
    const a = r.a;
    const raw = val.jsSlice(try bodyStr(r, "query"), 40);
    const number = (try shipments.normalizeTrackingNumber(a, raw)) orelse return r.json(200, .{ .results = .{} });
    const ar = std.mem.eql(u8, r.body.s("lang") orelse "", "ar");
    const s = try db.col("shipments").findOne(a, .{ .trackingNumber = number }, .{ .projection = try val.from(a, .{
        .trackingNumber = 1,
        .status = 1,
        .statusAt = 1,
        .service = 1,
        .promisedBy = 1,
        .scheduledFor = 1,
        .deliveredAt = 1,
        .carrierName = 1,
        .merchantName = 1,
        .@"pickup.governorate" = 1,
        .@"pickup.city" = 1,
        .@"dropoff.governorate" = 1,
        .@"dropoff.city" = 1,
    }) });
    const more_url = try std.fmt.allocPrint(a, "/track?n={s}", .{try @import("../auth.zig").encodeUriComponent(a, number)});
    const more = try val.from(a, .{ .label = if (ar) "افتح في طرف" else "Open in Turf", .url = more_url });
    const sh = s orelse return r.json(200, .{
        .results = .{.{ .kind = "shipment", .title = number, .subtitle = if (ar) "لم يُعثر على شحنة بهذا الرقم" else "No shipment with this number", .meta = "", .status = "not_found", .tone = "muted", .steps = .{}, .url = more_url }},
        .more = more,
    });
    const view = try shipments.lookupView(a, sh, try shipments.eventsFor(a, sh.get("_id"), false));
    const place = struct {
        fn f(al: std.mem.Allocator, p: Val, arabic: bool) ![]const u8 {
            if (!p.truthy()) return "";
            if (p.t("city")) return val.toStr(al, p.get("city"));
            const n = p.path(if (arabic) "governorateName.ar" else "governorateName.en");
            return if (n.truthy()) val.toStr(al, n) else "";
        }
    }.f;
    var route_parts: std.ArrayList([]const u8) = .empty;
    for ([_][]const u8{ try place(a, view.get("from"), ar), try place(a, view.get("to"), ar) }) |p| if (p.len > 0) try route_parts.append(a, p);
    var meta_parts: std.ArrayList([]const u8) = .empty;
    const route_text = try std.mem.join(a, " → ", route_parts.items);
    if (route_text.len > 0) try meta_parts.append(a, route_text);
    if (view.path("carrier.name").truthy()) try meta_parts.append(a, try val.toStr(a, view.path("carrier.name")));
    // The last few milestones, newest first.
    const evs = view.get("events").items();
    const steps = try val.newArr(a);
    var i = evs.len;
    while (i > 0 and evs.len - i < 3) {
        i -= 1;
        try steps.push(.{ .text = evs[i].get(if (ar) "textAr" else "textEn"), .at = evs[i].get("at") });
    }
    return r.json(200, .{
        .results = .{.{
            .kind = "shipment",
            .title = view.get("trackingNumber"),
            .subtitle = view.get(if (ar) "statusTextAr" else "statusTextEn"),
            .meta = try std.mem.join(a, " · ", meta_parts.items),
            .status = view.get("status"),
            .tone = tone(view.s("status") orelse ""),
            .updatedAt = if (view.get("updatedAt").truthy()) view.get("updatedAt") else Val.null,
            .steps = steps,
            .url = more_url,
        }},
        .more = more,
    });
}
