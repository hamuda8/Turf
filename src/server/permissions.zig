//! Permission catalog per organization type, and the default roles each new organization starts
//! with (src/permissions.js). Ownership is not a permission: it is a flag on the owner's
//! membership that can never be granted, transferred or removed.

const std = @import("std");
const val = @import("lib/val.zig");
const web = @import("web.zig");
const Val = val.Val;

pub const Perm = struct { key: []const u8, group: []const u8 };

pub const carrier = [_]Perm{
    .{ .key = "org.settings", .group = "company" },
    .{ .key = "org.branding", .group = "company" },
    .{ .key = "audit.view", .group = "company" },
    .{ .key = "members.view", .group = "team" },
    .{ .key = "members.invite", .group = "team" },
    .{ .key = "members.manage", .group = "team" },
    .{ .key = "roles.manage", .group = "team" },
    .{ .key = "hubs.manage", .group = "operations" },
    .{ .key = "shipments.view", .group = "operations" },
    .{ .key = "shipments.manage", .group = "operations" },
    .{ .key = "dispatch.manage", .group = "operations" },
    .{ .key = "hub.scan", .group = "operations" },
    .{ .key = "fleet.view", .group = "operations" },
    .{ .key = "alerts.manage", .group = "safety" },
    .{ .key = "finance.view", .group = "finance" },
    .{ .key = "finance.manage", .group = "finance" },
    .{ .key = "courier.work", .group = "courier" },
};

pub const merchant = [_]Perm{
    .{ .key = "org.settings", .group = "company" },
    .{ .key = "audit.view", .group = "company" },
    .{ .key = "members.view", .group = "team" },
    .{ .key = "members.invite", .group = "team" },
    .{ .key = "members.manage", .group = "team" },
    .{ .key = "roles.manage", .group = "team" },
    .{ .key = "shipments.view", .group = "shipping" },
    .{ .key = "shipments.create", .group = "shipping" },
    .{ .key = "shipments.cancel", .group = "shipping" },
    .{ .key = "api.manage", .group = "developers" },
    .{ .key = "finance.view", .group = "finance" },
};

pub fn catalog(org_type: []const u8) []const Perm {
    return if (std.mem.eql(u8, org_type, "carrier")) &carrier else &merchant;
}

fn keysOf(comptime list: []const Perm, comptime skip: ?[]const u8) []const []const u8 {
    comptime {
        var out: []const []const u8 = &.{};
        for (list) |p| {
            if (skip) |s| if (std.mem.eql(u8, p.key, s)) continue;
            out = out ++ &[_][]const u8{p.key};
        }
        return out;
    }
}

pub const carrier_keys = keysOf(&carrier, null);
pub const merchant_keys = keysOf(&merchant, null);

pub fn allKeys(org_type: []const u8) []const []const u8 {
    return if (std.mem.eql(u8, org_type, "carrier")) carrier_keys else merchant_keys;
}

pub const DefaultRole = struct { key: []const u8, name: []const u8, permissions: []const []const u8 };

pub const default_carrier_roles = [_]DefaultRole{
    .{ .key = "manager", .name = "Manager", .permissions = keysOf(&carrier, "courier.work") },
    .{ .key = "dispatcher", .name = "Dispatcher", .permissions = &.{ "members.view", "shipments.view", "shipments.manage", "dispatch.manage", "hub.scan", "fleet.view", "alerts.manage" } },
    .{ .key = "hub_operator", .name = "Hub operator", .permissions = &.{ "shipments.view", "hub.scan" } },
    .{ .key = "support", .name = "Customer support", .permissions = &.{ "shipments.view", "shipments.manage", "fleet.view" } },
    .{ .key = "accountant", .name = "Accountant", .permissions = &.{ "shipments.view", "finance.view", "finance.manage" } },
    .{ .key = "courier", .name = "Courier", .permissions = &.{"courier.work"} },
};

pub const default_merchant_roles = [_]DefaultRole{
    .{ .key = "manager", .name = "Manager", .permissions = merchant_keys },
    .{ .key = "developer", .name = "Developer", .permissions = &.{ "shipments.view", "shipments.create", "api.manage" } },
    .{ .key = "operations", .name = "Operations", .permissions = &.{ "shipments.view", "shipments.create", "shipments.cancel" } },
    .{ .key = "viewer", .name = "Viewer", .permissions = &.{"shipments.view"} },
};

pub fn defaultRoles(org_type: []const u8) []const DefaultRole {
    return if (std.mem.eql(u8, org_type, "carrier")) &default_carrier_roles else &default_merchant_roles;
}

pub fn isValidPermission(org_type: []const u8, key: []const u8) bool {
    for (catalog(org_type)) |p| if (std.mem.eql(u8, p.key, key)) return true;
    return false;
}

/// Effective permissions of a membership. Owners hold every permission of their org type.
pub fn effectivePermissions(a: std.mem.Allocator, org_type: []const u8, membership: Val, role: Val) !web.Perms {
    if (membership.t("isOwner")) return .{ .keys = allKeys(org_type) };
    if (!std.mem.eql(u8, membership.s("status") orelse "", "active") or role.isNullish()) return .{};
    var out: std.ArrayList([]const u8) = .empty;
    for (role.get("permissions").items()) |p| {
        const k = p.asStr() orelse continue;
        if (!isValidPermission(org_type, k)) continue;
        if (val.contains([]const u8, out.items, k)) continue;
        try out.append(a, k);
    }
    return .{ .keys = out.items };
}

/// Permissions that grant no power over other people or company data; escalation checks ignore
/// them (a Manager can hire couriers without being a courier).
fn privilegeNeutral(k: []const u8) bool {
    return std.mem.eql(u8, k, "courier.work");
}

/// Every privileged permission in `candidate` (an array of strings) is also in `of`.
pub fn isSubset(candidate: Val, of: web.Perms) bool {
    for (candidate.items()) |p| {
        const k = p.asStr() orelse return false;
        if (!privilegeNeutral(k) and !of.has(k)) return false;
    }
    return true;
}

pub fn isSubsetKeys(candidate: []const []const u8, of: web.Perms) bool {
    for (candidate) |k| if (!privilegeNeutral(k) and !of.has(k)) return false;
    return true;
}

/// PERMISSIONS as the API sends it ({ carrier: [{key, group}], merchant: [...] }).
pub fn catalogJson(a: std.mem.Allocator) !Val {
    return val.from(a, .{ .carrier = &carrier, .merchant = &merchant });
}
