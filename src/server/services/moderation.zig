//! Content checks through Wufour Moderation (src/services/moderation.js and its client copy).
//! Every place where a person's text or image enters Turf calls one of these before saving:
//!
//!   layer 1  nothing is saved; the request fails with 422 moderation_blocked and the warning
//!   layer 2  saved with moderation.layer = 2; companies marked 2 are left out of the carrier
//!            list and the automatic ranking (see `browsable`)
//!   layer 3  saved as usual
//!
//! When Moderation cannot answer, the request fails closed with 503 moderation_unavailable.
//! Without MODERATION_HOST / MODERATION_API_KEY checks are off and everything is allowed.

const std = @import("std");
const val = @import("mongo").val;
const db = @import("../lib/db.zig");
const web = @import("../web.zig");
const a_ = @import("../app.zig");
const Val = val.Val;
const Req = web.Req;

pub const block = 1;
pub const restrict = 2;
pub const allow = 3;

const unavailable = "Content checks are unavailable right now. Please try again in a moment.";

/// Query piece that keeps restricted (layer 2) companies out of listings and rankings.
pub fn browsable(a: std.mem.Allocator) !Val {
    return val.from(a, .{ .@"moderation.layer" = .{ .@"$ne" = restrict } });
}

fn base(a: std.mem.Allocator) []const u8 {
    const h = val.jsTrim(a_.cfg().moderation_host);
    return std.mem.replaceOwned(u8, a, std.mem.trimEnd(u8, h, "/"), "://localhost", "://127.0.0.1") catch h;
}

pub fn enabled() bool {
    return a_.cfg().moderation_host.len > 0 and a_.cfg().moderation_api_key.len > 0;
}

pub fn logIfOff() void {
    if (!enabled()) std.log.warn("[moderation] MODERATION_HOST or MODERATION_API_KEY is not set: content checks are OFF for turf. Every submission is treated as allowed.", .{});
}

/// The moderation sub-document saved on a record.
pub fn stamp(a: std.mem.Allocator, outcome: Val) !Val {
    const reasons = outcome.get("reasons");
    return val.from(a, .{ .layer = outcome.get("layer"), .reasons = if (reasons.isNullish()) try val.newArr(a) else reasons, .checkedAt = a_.now() });
}

pub const Image = struct { id: []const u8, bytes: []const u8 };

/// A text item, or null when the value is empty.
fn textItem(a: std.mem.Allocator, id: []const u8, value: Val) !?Val {
    const s = value.asStr() orelse return null;
    if (val.jsTrim(s).len == 0) return null;
    return try val.from(a, .{ .id = id, .kind = "text", .text = s, .field = id });
}

/// Checks texts ({ field: value }; empty values skipped) and images in one go. `subject` is
/// { userId, name } of the person responsible, or null. Returns { layer, reasons, warning } for
/// layers 2 and 3; fails with 422 for layer 1 and 503 when Moderation is down.
pub fn check(r: *Req, subject: Val, context: anytype, texts: Val, images: []const Image) !Val {
    const a = r.a;
    const items = try val.newArr(a);
    if (texts.asObj()) |o| for (o.keys.items, o.vals.items) |k, v| {
        if (try textItem(a, k, v)) |item| try items.push(item);
    };
    for (images) |img| if (img.bytes.len > 0) {
        const b64 = try a.alloc(u8, std.base64.standard.Encoder.calcSize(img.bytes.len));
        try items.push(.{ .id = img.id, .kind = "image", .data = std.base64.standard.Encoder.encode(b64, img.bytes), .field = img.id });
    };
    if (items.items().len == 0) return val.from(a, .{ .layer = allow, .reasons = .{}, .warning = null, .skipped = true });
    if (!enabled()) {
        // allowed(list): every item layer 3, no reasons.
        return val.from(a, .{ .layer = allow, .reasons = .{}, .warning = null, .result = .{ .success = true, .layer = allow, .verdict = "allow", .skipped = true } });
    }
    const body = try val.toJson(a, try val.from(a, .{
        .app = "turf",
        .subject = .{ .userId = if (subject.get("userId").truthy()) subject.get("userId") else Val.null, .name = if (subject.get("name").truthy()) subject.get("name") else Val.null },
        .context = try val.from(a, context),
        .items = items,
    }));
    const url = try std.fmt.allocPrint(a, "{s}/api/v1/check", .{base(a)});
    const res = a_.upstreamTimeout(a, url, .{ .method = .POST, .body = body, .headers = &.{.{ .name = "x-moderation-key", .value = a_.cfg().moderation_api_key }}, .retry = false }, 25_000) catch {
        return r.fail(503, "moderation_unavailable", unavailable, .{ .retryable = true });
    };
    const json = val.parseJson(a, res.body) catch Val.null;
    const status = @backingInt(res.status);
    if (!(status >= 200 and status < 300 and json.get("success").truthy())) {
        if (status == 400 or status == 413) {
            return r.fail(400, json.s("code") orelse "invalid_content", json.s("message") orelse "The content could not be checked", .{});
        }
        return r.fail(503, "moderation_unavailable", unavailable, .{ .retryable = true });
    }
    const layer = json.n("layer") orelse allow;
    if (layer == block) {
        const w = json.get("warning");
        return r.fail(422, "moderation_blocked", w.s("en") orelse "This content is not allowed on Turf", .{
            .messageAr = w.s("ar") orelse "",
            .warning = w,
            .layer = 1,
        });
    }
    const reasons = try val.newArr(a);
    for (json.get("items").items()) |item| {
        if ((item.n("layer") orelse allow) >= allow) continue;
        for (item.get("reasons").items()) |reason| if (!val.includesId(reasons, reason)) try reasons.push(reason);
    }
    return val.from(a, .{ .layer = layer, .reasons = reasons, .warning = json.get("warning"), .result = json });
}

/// Checks one text from a route handler and returns it unchanged.
pub fn checkedText(r: *Req, field: []const u8, value: ?[]const u8, context: anytype) !?[]const u8 {
    if (value) |v| if (val.jsTrim(v).len > 0) {
        const texts = try val.newObj(r.a);
        try texts.set(field, v);
        _ = try check(r, subjectOf(r), context, texts, &.{});
    };
    return value;
}

/// The account behind a request: a signed-in person, a courier, or the owner of the merchant
/// behind an API key.
pub fn subjectOf(r: *Req) Val {
    const a = r.a;
    if (r.user.truthy()) return val.from(a, .{ .userId = r.user.get("id"), .name = if (r.user.get("username").truthy()) r.user.get("username") else Val.null }) catch .null;
    if (r.courier.truthy()) return val.from(a, .{ .userId = r.courier.get("userId"), .name = if (r.courier.get("name").truthy()) r.courier.get("name") else Val.null }) catch .null;
    if (r.merchant.truthy()) return val.from(a, .{ .userId = r.merchant.get("ownerUserId"), .name = if (r.merchant.get("name").truthy()) r.merchant.get("name") else Val.null }) catch .null;
    return .null;
}

/// The account that answers for a company (its owner).
pub fn subjectOfOrg(a: std.mem.Allocator, org: Val) Val {
    if (!org.get("ownerUserId").truthy()) return .null;
    return val.from(a, .{ .userId = org.get("ownerUserId"), .name = if (org.get("name").truthy()) org.get("name") else Val.null }) catch .null;
}

/// A company's standing is the worst of its parts (name, branding, logo), each checked when it
/// changes. Writes orgs.moderation = { layer, reasons, checkedAt, parts }.
pub fn applyOrgModeration(a: std.mem.Allocator, org_id: Val, part: []const u8, outcome: Val) !Val {
    const org = try db.col("orgs").findOne(a, .{ ._id = org_id }, .{ .projection = try val.from(a, .{ .moderation = 1 }) });
    const old_parts = if (org) |o| o.path("moderation.parts") else Val.undef;
    const parts = try val.spread(a, .{old_parts});
    const reasons_in = outcome.get("reasons");
    try parts.set(part, .{ .layer = outcome.get("layer"), .reasons = if (reasons_in.isNullish()) try val.newArr(a) else reasons_in });
    var layer: f64 = allow;
    const reasons = try val.newArr(a);
    for (parts.obj.vals.items) |p| {
        const l = p.n("layer") orelse allow;
        if (l < layer) layer = l;
    }
    for (parts.obj.vals.items) |p| if ((p.n("layer") orelse allow) < allow) {
        for (p.get("reasons").items()) |x| if (!val.includesId(reasons, x)) try reasons.push(x);
    };
    _ = try db.col("orgs").updateOne(a, .{ ._id = org_id }, .{ .@"$set" = .{ .moderation = .{ .layer = layer, .reasons = reasons, .checkedAt = a_.now(), .parts = parts } } }, .{});
    return val.from(a, .{ .layer = layer, .reasons = reasons });
}

/// A data URL's bytes (moderation.imageFromDataUrl), or null when it is not one.
pub fn dataUrlBytes(a: std.mem.Allocator, data_url: []const u8) !?[]const u8 {
    if (!std.mem.startsWith(u8, data_url, "data:")) return null;
    const comma = std.mem.indexOfScalar(u8, data_url, ',') orelse return null;
    const meta = data_url[5..comma];
    const payload = data_url[comma + 1 ..];
    if (std.mem.endsWith(u8, meta, ";base64")) {
        const clean = std.mem.trimEnd(u8, payload, "=");
        const D = std.base64.standard_no_pad.Decoder;
        const out = try a.alloc(u8, D.calcSizeForSlice(clean) catch return null);
        D.decode(out, clean) catch return null;
        return out;
    }
    return @import("http").decode(a, payload) catch null;
}
