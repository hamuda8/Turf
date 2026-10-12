//! Organizations (carriers and merchants), their owner and default roles (src/services/orgs.js).

const std = @import("std");
const val = @import("../lib/val.zig");
const db = @import("../lib/db.zig");
const web = @import("../web.zig");
const a_ = @import("../app.zig");
const permissions = @import("../permissions.zig");
const audit = @import("audit.zig");
const platform = @import("platform.zig");
const moderation = @import("moderation.zig");
const Val = val.Val;
const Req = web.Req;

pub const org_types = [_][]const u8{ "carrier", "merchant" };

const reserved_slugs = [_][]const u8{ "app", "api", "admin", "auth", "www", "turf", "static", "embed", "developers", "new" };

pub const default_primary = "#8A3324";
pub const default_accent = "#030200";

pub fn defaultCarrierSettings(a: std.mem.Allocator) !Val {
    return val.from(a, .{
        .coverage = .{},
        .areas = .{},
        .visibility = "network",
        .clientMerchants = .{},
        .acceptMarketplace = true,
        .acceptDirect = true,
        .acceptIndividuals = false,
        .autoDispatch = false,
        .directLocal = false,
        .maxWeightKg = 30,
        .maxAttempts = 3,
        .currency = "SYP",
        .pricing = null,
        .sla = .{ .localHours = 24, .nationalHours = 72 },
        .express = .{ .enabled = false, .minutes = 60, .maxKm = 15, .maxWeightKg = 20, .base = 0, .perKm = 0, .hours = null },
        .cod = .{ .enabled = true },
        .blockedMerchants = .{},
    });
}

pub fn defaultMerchantSettings(a: std.mem.Allocator) !Val {
    return val.from(a, .{ .website = null, .defaultPickup = null, .webhook = null, .defaultStrategy = "balanced" });
}

pub const NewOrg = struct {
    type: []const u8,
    name: []const u8,
    slug: []const u8,
    phone: ?[]const u8 = null,
    governorate: ?[]const u8 = null,
    terms_version: ?[]const u8 = null,
};

pub fn createOrg(r: *Req, user: Val, in: NewOrg) !Val {
    const a = r.a;
    if (val.contains([]const u8, &reserved_slugs, in.slug)) return r.conflict("This address is reserved, please choose another", "slug_reserved", null);

    // Carriers are verified before going live; stores follow the platform's sign-up mode.
    // Platform admins' own companies are active at once.
    var status: []const u8 = "active";
    if (!user.t("isPlatformAdmin")) {
        if (std.mem.eql(u8, in.type, "carrier") and !a_.cfg().auto_approve_carriers) status = "pending";
        if (std.mem.eql(u8, in.type, "merchant")) {
            const mode = (try platform.get(a)).s("merchantSignup") orelse "approval";
            if (std.mem.eql(u8, mode, "closed")) return r.fail(403, "signups_closed", "New store accounts are not open yet", .{});
            if (std.mem.eql(u8, mode, "approval")) status = "pending";
        }
    }

    const texts = try val.from(a, .{ .name = in.name });
    const outcome = try moderation.check(r, try val.from(a, .{ .userId = user.get("id"), .name = if (user.t("username")) user.get("username") else Val.null }), .{ .type = "company", .field = "name" }, texts, &.{});

    const now = a_.now();
    const org = try val.from(a, .{
        .type = in.type,
        .name = in.name,
        .slug = in.slug,
        .status = status,
        .ownerUserId = user.get("id"),
        .moderation = .{ .layer = outcome.get("layer"), .reasons = outcome.get("reasons"), .checkedAt = now, .parts = .{ .name = .{ .layer = outcome.get("layer"), .reasons = outcome.get("reasons") } } },
        .termsAccepted = if (in.terms_version) |tv| try val.from(a, .{ .version = tv, .at = a_.now(), .userId = user.get("id") }) else Val.null,
        .contact = .{ .phone = if (in.phone) |p| Val{ .str = p } else Val.null, .email = user.get("email"), .governorate = if (in.governorate) |g| Val{ .str = g } else Val.null },
        .branding = .{ .appName = in.name, .shortName = val.jsSlice(in.name, 12), .primaryColor = default_primary, .accentColor = default_accent, .assetsVersion = null },
        .createdAt = now,
        .updatedAt = now,
    });
    try org.set(in.type, if (std.mem.eql(u8, in.type, "carrier")) try defaultCarrierSettings(a) else try defaultMerchantSettings(a));

    // Turf-js uses a transaction on a replica set; zig-core speaks to one server, so the writes
    // run in order (Turf-js's own fallback on a standalone server).
    _ = db.col("orgs").insertOne(a, org) catch |e| switch (e) {
        error.DuplicateKey => return r.conflict("This address is already taken", "slug_taken", null),
        else => return e,
    };
    var roles: std.ArrayList(Val) = .empty;
    for (permissions.defaultRoles(in.type)) |dr| try roles.append(a, try val.from(a, .{
        .orgId = org.get("_id"),
        .key = dr.key,
        .name = dr.name,
        .permissions = dr.permissions,
        .createdAt = now,
        .updatedAt = now,
    }));
    _ = try db.col("roles").insertMany(a, roles.items);
    _ = try db.col("memberships").insertOne(a, .{
        .orgId = org.get("_id"),
        .orgType = in.type,
        .userId = user.get("id"),
        .email = user.get("email"),
        .name = user.get("username"),
        .isOwner = true,
        .roleId = null,
        .status = "active",
        .courier = null,
        .joinedAt = now,
    });
    audit.audit(a, org.get("_id"), user, "org.created", .{ .name = in.name, .slug = in.slug, .type = in.type });
    return org;
}

pub fn getOrgBySlug(a: std.mem.Allocator, slug: []const u8) !?Val {
    return db.col("orgs").findOne(a, .{ .slug = slug }, .{});
}

pub fn getOrg(a: std.mem.Allocator, id: Val) !?Val {
    return db.col("orgs").findOne(a, .{ ._id = id }, .{});
}

pub const OrgOfUser = struct { org: Val, membership: Val, role: Val };

/// All organizations a user belongs to, with their membership. Personal stores and closed
/// companies are left out.
pub fn orgsForUser(a: std.mem.Allocator, user_id: Val) ![]OrgOfUser {
    const memberships = try db.col("memberships").find(a, .{ .userId = user_id, .status = .{ .@"$ne" = "removed" } }, .{});
    if (memberships.len == 0) return &.{};
    const org_ids = try val.newArr(a);
    const role_ids = try val.newArr(a);
    for (memberships) |m| {
        try org_ids.push(m.get("orgId"));
        if (m.get("roleId").truthy()) try role_ids.push(m.get("roleId"));
    }
    const orgs = try db.col("orgs").find(a, .{ ._id = .{ .@"$in" = org_ids }, .personal = .{ .@"$ne" = true }, .status = .{ .@"$ne" = "closed" } }, .{});
    const roles = try db.col("roles").find(a, .{ ._id = .{ .@"$in" = role_ids } }, .{});
    var out: std.ArrayList(OrgOfUser) = .empty;
    for (memberships) |m| {
        const org = findById(orgs, m.get("orgId")) orelse continue;
        const role: Val = if (m.get("roleId").truthy()) (findById(roles, m.get("roleId")) orelse .undef) else .null;
        try out.append(a, .{ .org = org, .membership = m, .role = role });
    }
    return out.items;
}

/// list.find(x => x._id.equals(id))
pub fn findById(list: []const Val, id: Val) ?Val {
    for (list) |x| if (x.get("_id").sameId(id)) return x;
    return null;
}

pub fn assertOrgUsable(r: *Req, org: Val) !void {
    const status = org.s("status") orelse "";
    if (std.mem.eql(u8, status, "suspended")) return r.fail(403, "org_suspended", "This organization is suspended. Contact Turf support.", .{});
    if (std.mem.eql(u8, status, "closed")) return r.fail(410, "org_closed", "This company was closed", .{});
}
