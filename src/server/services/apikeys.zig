//! Merchant API keys (src/services/apikeys.js). Only a SHA-256 hash is stored; the secret is
//! shown once.

const std = @import("std");
const val = @import("mongo").val;
const db = @import("../lib/db.zig");
const web = @import("../web.zig");
const a_ = @import("../app.zig");
const crypto = @import("../crypto.zig");
const audit = @import("audit.zig");
const Val = val.Val;
const Req = web.Req;

const max_keys = 20;

pub fn createApiKey(r: *Req, ctx: *const web.OrgCtx, name: []const u8, mode: []const u8) !Val {
    const a = r.a;
    const n = try db.col("api_keys").count(a, .{ .orgId = ctx.org.get("_id"), .revokedAt = null }, .{});
    if (n >= max_keys) return r.failf(409, "too_many_keys", "At most {d} active keys", .{max_keys}, .{});
    const key = try crypto.newApiKey(a, mode);
    const doc = try val.from(a, .{ .orgId = ctx.org.get("_id"), .name = name, .mode = mode, .hash = key.hash, .prefix = key.prefix, .createdAt = a_.now(), .createdBy = ctx.member.get("userId"), .lastUsedAt = null, .revokedAt = null });
    const id = try db.col("api_keys").insertOne(a, doc);
    audit.audit(a, ctx.org.get("_id"), ctx.member, "api_key.created", .{ .name = name, .prefix = key.prefix, .mode = mode });
    return val.from(a, .{ .id = id, .name = name, .mode = mode, .prefix = key.prefix, .secret = key.secret, .createdAt = doc.get("createdAt") });
}

pub fn listApiKeys(a: std.mem.Allocator, org_id: Val) ![]Val {
    return db.col("api_keys").find(a, .{ .orgId = org_id, .revokedAt = null }, .{ .projection = try val.from(a, .{ .hash = 0 }), .sort = try val.from(a, .{ .createdAt = -1 }) });
}

pub fn revokeApiKey(r: *Req, ctx: *const web.OrgCtx, key_id: Val) !void {
    const res = try db.col("api_keys").updateOne(r.a, .{ ._id = key_id, .orgId = ctx.org.get("_id"), .revokedAt = null }, .{ .@"$set" = .{ .revokedAt = a_.now() } }, .{});
    if (res.matched == 0) return r.notFound("API key");
    audit.audit(r.a, ctx.org.get("_id"), ctx.member, "api_key.revoked", .{ .keyId = key_id });
}

/// /^Bearer\s+(turf_(?:sk|test)_[A-Za-z0-9_-]+)$/
fn bearerKey(header: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, header, "Bearer")) return null;
    var i: usize = 6;
    const ws_start = i;
    while (i < header.len and std.ascii.isWhitespace(header[i])) i += 1;
    if (i == ws_start) return null;
    const key = header[i..];
    const rest = if (std.mem.startsWith(u8, key, "turf_sk_")) key[8..] else if (std.mem.startsWith(u8, key, "turf_test_")) key[10..] else return null;
    if (rest.len == 0) return null;
    for (rest) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) return null;
    return key;
}

/// Middleware for /api/v1: authenticates "Authorization: Bearer turf_sk_..." and sets r.merchant.
pub fn apiKeyAuth(r: *Req) !void {
    const a = r.a;
    const secret = bearerKey(r.header("authorization") orelse "") orelse
        return r.fail(401, "unauthenticated", "Send your secret key as \"Authorization: Bearer turf_sk_...\" (or a turf_test_ key)", .{});
    const key = (try db.col("api_keys").findOne(a, .{ .hash = try crypto.sha256(a, secret), .revokedAt = null }, .{})) orelse
        return r.fail(401, "invalid_api_key", "This API key is invalid or has been revoked", .{});
    const merchant = (try db.col("orgs").findOne(a, .{ ._id = key.get("orgId"), .type = "merchant" }, .{})) orelse
        return r.fail(401, "invalid_api_key", "This API key is invalid or has been revoked", .{});
    const test_mode = std.mem.eql(u8, key.s("mode") orelse "", "test");
    const status = merchant.s("status") orelse "";
    // A store waiting for approval can already integrate with test keys.
    if (std.mem.eql(u8, status, "pending") and !test_mode) return r.fail(403, "org_pending", "This store account is waiting for approval by Turf (test keys work meanwhile)", .{});
    if (std.mem.eql(u8, status, "suspended")) return r.fail(403, "org_suspended", "This merchant account is suspended", .{});
    // Usage is recorded at most once a minute per key.
    const last = key.get("lastUsedAt").dateMs();
    if (last == null or a_.nowMs() - last.? > 60_000)
        _ = db.col("api_keys").updateOne(a, .{ ._id = key.get("_id") }, .{ .@"$set" = .{ .lastUsedAt = a_.now() } }, .{}) catch {};
    r.merchant = merchant;
    r.api_key = key;
    r.test_mode = test_mode;
}
