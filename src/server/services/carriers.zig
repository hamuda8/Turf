//! Carrier-side configuration: hubs, settings and readiness (src/services/carriers.js).

const std = @import("std");
const val = @import("mongo").val;
const db = @import("../lib/db.zig");
const web = @import("../web.zig");
const a_ = @import("../app.zig");
const audit = @import("audit.zig");
const moderation = @import("moderation.zig");
const Val = val.Val;
const Req = web.Req;
const OrgCtx = web.OrgCtx;

pub fn listHubs(a: std.mem.Allocator, org_id: Val, active_only: bool) ![]Val {
    const q = try val.from(a, .{ .orgId = org_id });
    if (active_only) try q.set("active", true);
    return db.col("hubs").find(a, q, .{ .sort = try val.from(a, .{ .governorate = 1, .name = 1 }) });
}

pub fn getHub(r: *Req, org_id: Val, hub_id: Val) !Val {
    return (try db.col("hubs").findOne(r.a, .{ ._id = hub_id, .orgId = org_id }, .{})) orelse r.notFound("Hub");
}

pub fn createHub(r: *Req, ctx: *const OrgCtx, data: Val) !Val {
    const hub = try val.spread(r.a, .{ .{ .orgId = ctx.org.get("_id") }, data, .{ .active = true, .createdAt = a_.now() } });
    _ = db.col("hubs").insertOne(r.a, hub) catch |e| switch (e) {
        error.DuplicateKey => return r.conflict("A hub with this code already exists", "hub_code_taken", null),
        else => return e,
    };
    audit.audit(r.a, ctx.org.get("_id"), ctx.member, "hub.created", .{ .name = hub.get("name"), .code = hub.get("code") });
    return hub;
}

pub fn updateHub(r: *Req, ctx: *const OrgCtx, hub_id: Val, data: Val) !void {
    const hub = try getHub(r, ctx.org.get("_id"), hub_id);
    _ = db.col("hubs").updateOne(r.a, .{ ._id = hub.get("_id") }, .{ .@"$set" = try val.spread(r.a, .{ data, .{ .updatedAt = a_.now() } }) }, .{}) catch |e| switch (e) {
        error.DuplicateKey => return r.conflict("A hub with this code already exists", "hub_code_taken", null),
        else => return e,
    };
    audit.audit(r.a, ctx.org.get("_id"), ctx.member, "hub.updated", try val.spread(r.a, .{ .{ .hubId = hub_id }, data }));
}

/// `changes` is already validated; keys are dotted paths under `carrier.`.
pub fn updateCarrierSettings(r: *Req, ctx: *const OrgCtx, changes: Val) !void {
    const set = try val.from(r.a, .{ .updatedAt = a_.now() });
    if (changes.asObj()) |o| for (o.keys.items, o.vals.items) |k, v| try set.obj.put(try std.fmt.allocPrint(r.a, "carrier.{s}", .{k}), v);
    _ = try db.col("orgs").updateOne(r.a, .{ ._id = ctx.org.get("_id") }, .{ .@"$set" = set }, .{});
    audit.audit(r.a, ctx.org.get("_id"), ctx.member, "carrier.settings_updated", changes);
}

pub fn updateOrgProfile(r: *Req, ctx: *const OrgCtx, name: ?[]const u8, phone: ?[]const u8, governorate: ?[]const u8) !void {
    const a = r.a;
    if (name) |n| {
        // A layer 1 name is refused before anything changes.
        const outcome = try moderation.check(r, try val.from(a, .{ .userId = ctx.member.get("userId"), .name = ctx.member.get("name") }), .{ .type = "company", .id = try val.toStr(a, ctx.org.get("_id")), .field = "name" }, try val.from(a, .{ .name = n }), &.{});
        _ = try moderation.applyOrgModeration(a, ctx.org.get("_id"), "name", outcome);
    }
    const set = try val.from(a, .{ .updatedAt = a_.now() });
    if (name) |n| try set.set("name", n);
    if (phone) |p| try set.set("contact.phone", p);
    if (governorate) |g| try set.set("contact.governorate", g);
    _ = try db.col("orgs").updateOne(a, .{ ._id = ctx.org.get("_id") }, .{ .@"$set" = set }, .{});
    audit.audit(a, ctx.org.get("_id"), ctx.member, "org.profile_updated", .{ .name = name, .phone = phone, .governorate = governorate });
}

/// Problems that prevent a carrier from receiving orders (empty = ready).
pub fn readinessIssues(a: std.mem.Allocator, org: Val) !Val {
    const c = org.get("carrier");
    const issues = try val.newArr(a);
    const status = org.s("status") orelse "";
    if (std.mem.eql(u8, status, "pending")) {
        const v = org.path("verification.status").asStr() orelse "";
        try issues.push(if (std.mem.eql(u8, v, "submitted")) "awaiting_approval" else if (std.mem.eql(u8, v, "rejected")) "verification_rejected" else "verification_needed");
    }
    if (std.mem.eql(u8, status, "suspended")) try issues.push("suspended");
    if (c.get("coverage").items().len == 0) try issues.push("no_coverage");
    if (!c.get("pricing").truthy()) try issues.push("no_pricing");
    if (!c.get("acceptMarketplace").truthy() and !c.get("acceptDirect").truthy()) try issues.push("not_accepting_orders");
    return issues;
}
