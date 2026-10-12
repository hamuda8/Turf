//! Members, roles and invitations (src/services/members.js), with the rules that protect the
//! owner and prevent privilege escalation:
//!   - the owner can never be changed, suspended or removed;
//!   - nobody can act on their own membership;
//!   - you can only manage members, edit roles and assign roles whose permissions you hold.

const std = @import("std");
const val = @import("../lib/val.zig");
const db = @import("../lib/db.zig");
const web = @import("../web.zig");
const a_ = @import("../app.zig");
const permissions = @import("../permissions.zig");
const crypto = @import("../crypto.zig");
const geo = @import("../geo.zig");
const audit = @import("audit.zig");
const orgs = @import("orgs.zig");
const Val = val.Val;
const Req = web.Req;
const OrgCtx = web.OrgCtx;

const invite_ttl_days = 14;

/// The acting user's membership and permissions in an org, or null.
pub fn loadContext(a: std.mem.Allocator, org: Val, user_id: Val) !?OrgCtx {
    const member = (try db.col("memberships").findOne(a, .{ .orgId = org.get("_id"), .userId = user_id }, .{})) orelse return null;
    if (std.mem.eql(u8, member.s("status") orelse "", "removed")) return null;
    const role: Val = if (member.get("roleId").truthy()) ((try db.col("roles").findOne(a, .{ ._id = member.get("roleId") }, .{})) orelse .null) else .null;
    return .{ .org = org, .member = member, .role = role, .perms = try permissions.effectivePermissions(a, org.s("type") orelse "", member, role) };
}

fn roleOrThrow(r: *Req, org_id: Val, role_id: Val) !Val {
    return (try db.col("roles").findOne(r.a, .{ ._id = role_id, .orgId = org_id }, .{})) orelse r.notFound("Role");
}

fn targetOrThrow(r: *Req, ctx: *const OrgCtx, member_id: Val) !Val {
    return (try db.col("memberships").findOne(r.a, .{ ._id = member_id, .orgId = ctx.org.get("_id"), .status = .{ .@"$ne" = "removed" } }, .{})) orelse r.notFound("Member");
}

fn assertCanManage(r: *Req, ctx: *const OrgCtx, target: Val) !void {
    if (target.t("isOwner")) return r.forbidden("The owner of the company cannot be changed or removed");
    if (target.get("userId").sameId(ctx.member.get("userId"))) return r.forbidden("You cannot change your own membership");
    const target_role = if (target.get("roleId").truthy()) try db.col("roles").findOne(r.a, .{ ._id = target.get("roleId") }, .{}) else null;
    if (target_role) |tr| if (!ctx.member.t("isOwner") and !permissions.isSubset(tr.get("permissions"), ctx.perms))
        return r.forbidden("This member has permissions that you do not have");
}

fn assertCanAssign(r: *Req, ctx: *const OrgCtx, role: Val) !void {
    if (!ctx.member.t("isOwner") and !permissions.isSubset(role.get("permissions"), ctx.perms))
        return r.forbidden("You can only assign roles whose permissions you also have");
}

pub fn normalizeCourierProfile(r: *Req, input: Val) !Val {
    const a = r.a;
    const vehicle = input.get("vehicle");
    const vname = vehicle.asStr() orelse "";
    if (geo.vehicle(vname) == null) {
        const list = try std.mem.join(a, ", ", geo.vehicle_types);
        return r.badRequest(try std.fmt.allocPrint(a, "courier.vehicle must be one of: {s}", .{list}), "courier.vehicle", null, null);
    }
    const Num = struct {
        fn f(rq: *Req, v: Val, field: []const u8, max: f64) !Val {
            if (v.isMissing()) return .null;
            const x = val.toNum(v);
            if (!std.math.isFinite(x) or x <= 0 or x > max)
                return rq.badRequest(try std.fmt.allocPrint(rq.a, "{s} must be a positive number up to {d}", .{ field, @as(i64, @intFromFloat(max)) }), field, "between", .{ .min = 0, .max = max });
            return .{ .num = x };
        }
    };
    const Str = struct {
        fn f(rq: *Req, v: Val, field: []const u8, max: usize) !Val {
            if (v.isMissing()) return .null;
            const s = v.asStr() orelse return rq.badRequest(try std.fmt.allocPrint(rq.a, "{s} is invalid", .{field}), field, "format", null);
            const t = val.jsTrim(s);
            if (val.jsLength(t) > max) return rq.badRequest(try std.fmt.allocPrint(rq.a, "{s} is invalid", .{field}), field, "format", null);
            return .{ .str = t };
        }
    };
    return val.from(a, .{
        .vehicle = vname,
        .plate = try Str.f(r, input.get("plate"), "courier.plate", 20),
        .phone = try Str.f(r, input.get("phone"), "courier.phone", 30),
        .rangeKm = try Num.f(r, input.get("rangeKm"), "courier.rangeKm", 2000),
        .capacityKg = try Num.f(r, input.get("capacityKg"), "courier.capacityKg", 50000),
    });
}

// ---- Members ------------------------------------------------------------------------------------

pub fn listMembers(a: std.mem.Allocator, org_id: Val) ![]Val {
    const list = try db.col("memberships").find(a, .{ .orgId = org_id, .status = .{ .@"$ne" = "removed" } }, .{
        .projection = try val.from(a, .{ .lastLocation = 0 }),
        .sort = try val.from(a, .{ .isOwner = -1, .joinedAt = 1 }),
    });
    const ids = try val.newArr(a);
    for (list) |m| try ids.push(m.get("userId"));
    const users = try db.col("users").find(a, .{ ._id = .{ .@"$in" = ids } }, .{});
    var out: std.ArrayList(Val) = .empty;
    for (list) |m| {
        var u: Val = .undef;
        for (users) |x| if (x.get("_id").eql(m.get("userId"))) {
            u = x;
            break;
        };
        const copy = try m.copy(a);
        try copy.set("name", if (u.get("username").truthy()) u.get("username") else m.get("name"));
        try copy.set("email", if (u.get("email").truthy()) u.get("email") else m.get("email"));
        try out.append(a, copy);
    }
    return out.items;
}

pub fn changeRole(r: *Req, ctx: *const OrgCtx, member_id: Val, role_id: Val) !void {
    const target = try targetOrThrow(r, ctx, member_id);
    try assertCanManage(r, ctx, target);
    const role = try roleOrThrow(r, ctx.org.get("_id"), role_id);
    try assertCanAssign(r, ctx, role);
    const update = try val.from(r.a, .{ .roleId = role.get("_id") });
    // A courier role needs a courier profile; keep an existing one or start with a default.
    if (val.includesStr(role.get("permissions"), "courier.work") and !target.t("courier"))
        try update.set("courier", try normalizeCourierProfile(r, try val.from(r.a, .{ .vehicle = "motorbike" })));
    _ = try db.col("memberships").updateOne(r.a, .{ ._id = target.get("_id") }, .{ .@"$set" = update }, .{});
    audit.audit(r.a, ctx.org.get("_id"), ctx.member, "member.role_changed", .{ .memberId = target.get("_id"), .email = target.get("email"), .role = role.get("name") });
}

pub fn setMemberStatus(r: *Req, ctx: *const OrgCtx, member_id: Val, status: []const u8) !void {
    const target = try targetOrThrow(r, ctx, member_id);
    try assertCanManage(r, ctx, target);
    const update = try val.from(r.a, .{ .status = status });
    const suspended = std.mem.eql(u8, status, "suspended");
    if (suspended) try update.set("duty.onDuty", false);
    _ = try db.col("memberships").updateOne(r.a, .{ ._id = target.get("_id") }, .{ .@"$set" = update }, .{});
    audit.audit(r.a, ctx.org.get("_id"), ctx.member, if (suspended) "member.suspended" else "member.reactivated", .{ .memberId = target.get("_id"), .email = target.get("email") });
}

pub fn removeMember(r: *Req, ctx: *const OrgCtx, member_id: Val) !void {
    const target = try targetOrThrow(r, ctx, member_id);
    try assertCanManage(r, ctx, target);
    const open = try db.col("tasks").count(r.a, .{ .courierId = target.get("_id"), .status = .{ .@"$in" = .{ "assigned", "accepted", "in_progress" } } }, .{});
    if (open > 0) return r.conflict("This courier still has open tasks. Reassign or cancel them first.", "courier_open_tasks", null);
    // Keep the record (status "removed") so historical tasks still show who did them.
    _ = try db.col("memberships").updateOne(r.a, .{ ._id = target.get("_id") }, .{ .@"$set" = .{ .status = "removed", .removedAt = a_.now(), .@"duty.onDuty" = false } }, .{});
    audit.audit(r.a, ctx.org.get("_id"), ctx.member, "member.removed", .{ .memberId = target.get("_id"), .email = target.get("email") });
}

pub fn updateCourierProfile(r: *Req, ctx: *const OrgCtx, member_id: Val, input: Val) !Val {
    const target = try targetOrThrow(r, ctx, member_id);
    if (!target.get("userId").sameId(ctx.member.get("userId"))) {
        try assertCanManage(r, ctx, target);
    } else if (!ctx.perms.has("members.manage")) return r.forbidden(null);
    const profile = try normalizeCourierProfile(r, input);
    _ = try db.col("memberships").updateOne(r.a, .{ ._id = target.get("_id") }, .{ .@"$set" = .{ .courier = profile } }, .{});
    audit.audit(r.a, ctx.org.get("_id"), ctx.member, "member.courier_profile_updated", .{ .memberId = target.get("_id"), .vehicle = profile.get("vehicle") });
    return profile;
}

// ---- Roles --------------------------------------------------------------------------------------

pub fn listRoles(a: std.mem.Allocator, org_id: Val) ![]Val {
    const roles = try db.col("roles").find(a, .{ .orgId = org_id }, .{ .sort = try val.from(a, .{ .createdAt = 1 }) });
    const counts = try db.col("memberships").aggregate(a, .{
        .{ .@"$match" = .{ .orgId = org_id, .status = .{ .@"$ne" = "removed" }, .roleId = .{ .@"$ne" = null } } },
        .{ .@"$group" = .{ ._id = "$roleId", .n = .{ .@"$sum" = 1 } } },
    });
    var out: std.ArrayList(Val) = .empty;
    for (roles) |role| {
        var n: f64 = 0;
        for (counts) |c| if (c.get("_id").sameId(role.get("_id"))) {
            n = c.n("n") orelse 0;
        };
        const copy = try role.copy(a);
        try copy.set("memberCount", n);
        try out.append(a, copy);
    }
    return out.items;
}

fn cleanPermissions(r: *Req, ctx: *const OrgCtx, list: []const Val) !Val {
    const unique = try val.newArr(r.a);
    for (list) |p| {
        const dup = for (unique.items()) |u| {
            if (u.eql(p)) break true;
        } else false;
        if (!dup) try unique.push(p);
    }
    for (unique.items()) |p| {
        const ok = if (p.asStr()) |s| permissions.isValidPermission(ctx.org.s("type") orelse "", s) else false;
        if (!ok) return r.badRequest(try std.fmt.allocPrint(r.a, "Unknown permission: {s}", .{try val.toStr(r.a, p)}), "permissions", null, null);
    }
    if (!ctx.member.t("isOwner") and !permissions.isSubset(unique, ctx.perms))
        return r.forbidden("You can only give a role permissions that you have yourself");
    return unique;
}

pub fn createRole(r: *Req, ctx: *const OrgCtx, name: []const u8, perms_in: []const Val) !Val {
    const perms = try cleanPermissions(r, ctx, perms_in);
    const now = a_.now();
    const role = try val.from(r.a, .{ .orgId = ctx.org.get("_id"), .key = null, .name = name, .permissions = perms, .createdAt = now, .updatedAt = now });
    _ = db.col("roles").insertOne(r.a, role) catch |e| switch (e) {
        error.DuplicateKey => return r.conflict("A role with this name already exists", "role_name_taken", null),
        else => return e,
    };
    audit.audit(r.a, ctx.org.get("_id"), ctx.member, "role.created", .{ .name = name, .permissions = perms });
    return role;
}

pub fn updateRole(r: *Req, ctx: *const OrgCtx, role_id: Val, name: ?[]const u8, perms_in: ?[]const Val) !void {
    const role = try roleOrThrow(r, ctx.org.get("_id"), role_id);
    if (!ctx.member.t("isOwner") and !permissions.isSubset(role.get("permissions"), ctx.perms))
        return r.forbidden("This role has permissions that you do not have");
    if (ctx.member.get("roleId").sameId(role.get("_id")) and !ctx.member.t("isOwner"))
        return r.forbidden("You cannot edit your own role");
    const update = try val.from(r.a, .{ .updatedAt = a_.now() });
    if (name) |n| try update.set("name", n);
    if (perms_in) |p| try update.set("permissions", try cleanPermissions(r, ctx, p));
    _ = db.col("roles").updateOne(r.a, .{ ._id = role.get("_id") }, .{ .@"$set" = update }, .{}) catch |e| switch (e) {
        error.DuplicateKey => return r.conflict("A role with this name already exists", "role_name_taken", null),
        else => return e,
    };
    audit.audit(r.a, ctx.org.get("_id"), ctx.member, "role.updated", .{
        .roleId = role.get("_id"),
        .name = if (update.get("name").truthy()) update.get("name") else role.get("name"),
        .permissions = update.get("permissions"),
    });
}

pub fn deleteRole(r: *Req, ctx: *const OrgCtx, role_id: Val) !void {
    const role = try roleOrThrow(r, ctx.org.get("_id"), role_id);
    if (!ctx.member.t("isOwner") and !permissions.isSubset(role.get("permissions"), ctx.perms))
        return r.forbidden("This role has permissions that you do not have");
    if (try db.col("memberships").count(r.a, .{ .roleId = role.get("_id"), .status = .{ .@"$ne" = "removed" } }, .{}) > 0)
        return r.conflict("Move the members of this role to another role before deleting it", "role_in_use", null);
    if (try db.col("invitations").count(r.a, .{ .roleId = role.get("_id"), .status = "pending" }, .{}) > 0)
        return r.conflict("Revoke pending invitations for this role before deleting it", "role_has_invitations", null);
    _ = try db.col("roles").deleteOne(r.a, .{ ._id = role.get("_id") });
    audit.audit(r.a, ctx.org.get("_id"), ctx.member, "role.deleted", .{ .name = role.get("name") });
}

// ---- Invitations --------------------------------------------------------------------------------

pub fn createInvitation(r: *Req, ctx: *const OrgCtx, email: []const u8, role_id: Val, courier: ?Val) !Val {
    const a = r.a;
    const role = try roleOrThrow(r, ctx.org.get("_id"), role_id);
    try assertCanAssign(r, ctx, role);
    if (try db.col("memberships").findOne(a, .{ .orgId = ctx.org.get("_id"), .email = email, .status = .{ .@"$ne" = "removed" } }, .{}) != null)
        return r.conflict("This person is already a member", "already_member", null);
    var profile: Val = .null;
    if (val.includesStr(role.get("permissions"), "courier.work"))
        profile = try normalizeCourierProfile(r, if (courier) |c| (if (c.truthy()) c else try val.from(a, .{ .vehicle = "motorbike" })) else try val.from(a, .{ .vehicle = "motorbike" }));
    // Replace any earlier pending invite to the same email.
    _ = try db.col("invitations").updateMany(a, .{ .orgId = ctx.org.get("_id"), .email = email, .status = "pending" }, .{ .@"$set" = .{ .status = "revoked", .revokedAt = a_.now() } }, .{});
    const inv = try val.from(a, .{
        .orgId = ctx.org.get("_id"),
        .orgType = ctx.org.get("type"),
        .email = email,
        .roleId = role.get("_id"),
        .courier = profile,
        .token = try crypto.randomToken(a, 24),
        .status = "pending",
        .invitedBy = .{ .userId = ctx.member.get("userId"), .name = ctx.member.get("name") },
        .createdAt = a_.now(),
        .expiresAt = val.Date{ .ms = a_.nowMs() + invite_ttl_days * 86400_000 },
    });
    _ = try db.col("invitations").insertOne(a, inv);
    audit.audit(a, ctx.org.get("_id"), ctx.member, "invitation.created", .{ .email = email, .role = role.get("name") });
    return inv;
}

pub fn listInvitations(a: std.mem.Allocator, org_id: Val) ![]Val {
    return db.col("invitations").find(a, .{ .orgId = org_id, .status = "pending", .expiresAt = .{ .@"$gt" = a_.now() } }, .{ .sort = try val.from(a, .{ .createdAt = -1 }) });
}

pub fn revokeInvitation(r: *Req, ctx: *const OrgCtx, invitation_id: Val) !void {
    const res = try db.col("invitations").updateOne(r.a, .{ ._id = invitation_id, .orgId = ctx.org.get("_id"), .status = "pending" }, .{ .@"$set" = .{ .status = "revoked", .revokedAt = a_.now() } }, .{});
    if (res.matched == 0) return r.notFound("Invitation");
    audit.audit(r.a, ctx.org.get("_id"), ctx.member, "invitation.revoked", .{ .invitationId = invitation_id });
}

/// Pending invitations addressed to this user's email, with org and role.
pub fn invitationsForUser(a: std.mem.Allocator, user: Val) ![]Val {
    const invites = try db.col("invitations").find(a, .{ .email = user.get("email"), .status = "pending", .expiresAt = .{ .@"$gt" = a_.now() } }, .{});
    if (invites.len == 0) return &.{};
    const org_ids = try val.newArr(a);
    const role_ids = try val.newArr(a);
    for (invites) |i| {
        try org_ids.push(i.get("orgId"));
        try role_ids.push(i.get("roleId"));
    }
    const os = try db.col("orgs").find(a, .{ ._id = .{ .@"$in" = org_ids } }, .{});
    const rs = try db.col("roles").find(a, .{ ._id = .{ .@"$in" = role_ids } }, .{});
    var out: std.ArrayList(Val) = .empty;
    for (invites) |i| {
        const org = orgs.findById(os, i.get("orgId")) orelse continue;
        const role = orgs.findById(rs, i.get("roleId")) orelse continue;
        const copy = try i.copy(a);
        try copy.set("org", org);
        try copy.set("role", role);
        try out.append(a, copy);
    }
    return out.items;
}

pub fn findInvitationByToken(a: std.mem.Allocator, token: []const u8) !?Val {
    return db.col("invitations").findOne(a, .{ .token = token }, .{});
}

pub fn acceptInvitation(r: *Req, user: Val, inv: Val) !Val {
    const a = r.a;
    if (!std.mem.eql(u8, inv.s("status") orelse "", "pending") or (inv.get("expiresAt").dateMs() orelse 0) < a_.nowMs())
        return r.fail(410, "invitation_expired", "This invitation is no longer valid", .{});
    if (!inv.get("email").eql(user.get("email")))
        return r.forbidden(try std.fmt.allocPrint(a, "This invitation was sent to {s}. Sign in with that account to accept it.", .{inv.s("email") orelse ""}));
    const role = (try db.col("roles").findOne(a, .{ ._id = inv.get("roleId") }, .{})) orelse
        return r.fail(410, "invitation_expired", "The role in this invitation no longer exists", .{});
    const existing = try db.col("memberships").findOne(a, .{ .orgId = inv.get("orgId"), .userId = user.get("id") }, .{});
    if (existing) |e| {
        if (e.t("isOwner")) return r.conflict("You already own this company", "already_owner", null);
        if (!std.mem.eql(u8, e.s("status") orelse "", "removed")) return r.conflict("You are already a member of this company", "already_member", null);
    }
    const membership = try val.from(a, .{
        .orgId = inv.get("orgId"),
        .orgType = inv.get("orgType"),
        .userId = user.get("id"),
        .email = user.get("email"),
        .name = user.get("username"),
        .isOwner = false,
        .roleId = role.get("_id"),
        .status = "active",
        .courier = if (inv.t("courier")) inv.get("courier") else Val.null,
        .duty = .{ .onDuty = false, .since = null },
        .joinedAt = a_.now(),
    });
    if (existing) |e| {
        _ = try db.col("memberships").updateOne(a, .{ ._id = e.get("_id") }, .{ .@"$set" = membership, .@"$unset" = .{ .removedAt = "" } }, .{});
        try membership.set("_id", e.get("_id"));
    } else _ = try db.col("memberships").insertOne(a, membership);
    _ = try db.col("invitations").updateOne(a, .{ ._id = inv.get("_id") }, .{ .@"$set" = .{ .status = "accepted", .acceptedAt = a_.now(), .acceptedBy = user.get("id") } }, .{});
    audit.audit(a, inv.get("orgId"), user, "invitation.accepted", .{ .email = user.get("email"), .role = role.get("name") });
    return membership;
}

pub fn declineInvitation(r: *Req, user: Val, inv: Val) !void {
    if (!inv.get("email").eql(user.get("email")) or !std.mem.eql(u8, inv.s("status") orelse "", "pending")) return r.notFound("Invitation");
    _ = try db.col("invitations").updateOne(r.a, .{ ._id = inv.get("_id") }, .{ .@"$set" = .{ .status = "declined", .declinedAt = a_.now() } }, .{});
}
