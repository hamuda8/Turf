//! Leaving a company, closing a company, and deleting your Turf data (src/services/accounts.js).
//! A closed company disappears for its members and takes no new orders; its records stay. A
//! user deleting their data leaves every company (owners close theirs first); the sign-in
//! account itself belongs to Wufour.

const std = @import("std");
const val = @import("../lib/val.zig");
const db = @import("../lib/db.zig");
const web = @import("../web.zig");
const a_ = @import("../app.zig");
const messages = @import("../messages.zig");
const audit = @import("audit.zig");
const Val = val.Val;
const Req = web.Req;
const Allocator = std.mem.Allocator;

const open_tasks = [_][]const u8{ "assigned", "accepted", "in_progress" };

pub fn leaveOrg(r: *Req, ctx: *const web.OrgCtx) !void {
    const a = r.a;
    if (ctx.member.t("isOwner")) return r.conflict("The owner cannot leave the company. Close the company instead.", "owner_cannot_leave", null);
    if (try db.col("tasks").count(a, .{ .courierId = .{ .@"$in" = .{ctx.member.get("_id")} }, .status = .{ .@"$in" = &open_tasks } }, .{}) > 0)
        return r.conflict("You still have open tasks. Finish them or ask your dispatcher to reassign them first.", "leave_open_tasks", null);
    _ = try db.col("memberships").updateOne(a, .{ ._id = ctx.member.get("_id") }, .{ .@"$set" = .{ .status = "removed", .removedAt = a_.now(), .leftAt = a_.now(), .@"duty.onDuty" = false } }, .{});
    audit.audit(a, ctx.org.get("_id"), ctx.member, "member.left", .{ .email = ctx.member.get("email") });
}

/// What still blocks closing: open shipments and unpaid cash on delivery.
pub fn closeBlockers(a: Allocator, org: Val) !Val {
    const carrier = std.mem.eql(u8, org.s("type") orelse "", "carrier");
    const id = org.get("_id");
    const mine = if (carrier) try val.from(a, .{ .@"$or" = .{ .{ .carrierId = id }, .{ .carrierIds = id } } }) else try val.from(a, .{ .merchantId = id });
    const open = try db.col("shipments").count(a, try val.spread(a, .{ mine, .{ .@"test" = .{ .@"$ne" = true }, .status = .{ .@"$nin" = &messages.final_statuses } } }), .{});
    const own = if (carrier) try val.from(a, .{ .carrierId = id }) else try val.from(a, .{ .merchantId = id });
    const unpaid = try db.col("shipments").count(a, try val.spread(a, .{ own, .{ .@"test" = .{ .@"$ne" = true }, .@"cod.collectedAt" = .{ .@"$ne" = null }, .@"cod.remittedAt" = null } }), .{});
    return val.from(a, .{ .openShipments = open, .unpaidCash = unpaid });
}

pub fn closeOrg(r: *Req, ctx: *const web.OrgCtx, confirm_name: Val) !void {
    const a = r.a;
    if (!ctx.member.t("isOwner")) return r.conflict("Only the owner can close the company", "owner_only", null);
    const typed = val.jsTrim(if (confirm_name.isNullish()) "" else try val.toStr(a, confirm_name));
    if (!std.mem.eql(u8, typed, ctx.org.s("name") orelse "")) return r.badRequest("Type the company name exactly to confirm", "confirmName", "type_name", null);
    const b = try closeBlockers(a, ctx.org);
    const open = b.n("openShipments") orelse 0;
    const unpaid = b.n("unpaidCash") orelse 0;
    if (open > 0) return r.conflict(try std.fmt.allocPrint(a, "{d} shipments are still in progress. Finish, cancel or return them first.", .{@as(i64, @intFromFloat(open))}), "close_open_shipments", .{ .n = open });
    if (unpaid > 0) return r.conflict(try std.fmt.allocPrint(a, "Cash on delivery for {d} shipments has not been paid out yet. Settle it first.", .{@as(i64, @intFromFloat(unpaid))}), "close_unpaid_cash", .{ .n = unpaid });
    const now = a_.now();
    const set = try val.from(a, .{ .status = "closed", .closedAt = now, .updatedAt = now });
    const carrier = std.mem.eql(u8, ctx.org.s("type") orelse "", "carrier");
    if (carrier) {
        try set.set("carrier.acceptMarketplace", false);
        try set.set("carrier.acceptDirect", false);
        try set.set("carrier.acceptIndividuals", false);
    }
    const update = try val.from(a, .{ .@"$set" = set });
    if (std.mem.eql(u8, ctx.org.s("type") orelse "", "merchant")) try update.set("$unset", .{ .@"merchant.webhook" = "" });
    _ = try db.col("orgs").updateOne(a, .{ ._id = ctx.org.get("_id") }, update, .{});
    _ = try db.col("api_keys").updateMany(a, .{ .orgId = ctx.org.get("_id"), .revokedAt = null }, .{ .@"$set" = .{ .revokedAt = now } }, .{});
    _ = try db.col("invitations").updateMany(a, .{ .orgId = ctx.org.get("_id"), .status = "pending" }, .{ .@"$set" = .{ .status = "revoked" } }, .{});
    _ = try db.col("memberships").updateMany(a, .{ .orgId = ctx.org.get("_id") }, .{ .@"$set" = .{ .@"duty.onDuty" = false } }, .{});
    audit.audit(a, ctx.org.get("_id"), ctx.member, "org.closed", .{ .name = ctx.org.get("name") });
}

pub const Blockers = struct { owned: []const []const u8, open_parcels: i64, open_tasks: i64, memberships: []Val, personal: ?Val };

/// Everything that stops this user from deleting their data (empty = they can).
pub fn deletionBlockers(a: Allocator, user: Val) !Blockers {
    const memberships = try db.col("memberships").find(a, .{ .userId = user.get("id"), .status = .{ .@"$ne" = "removed" } }, .{});
    const ids = try val.newArr(a);
    const mids = try val.newArr(a);
    for (memberships) |m| {
        try ids.push(m.get("orgId"));
        try mids.push(m.get("_id"));
    }
    const orgs = try db.col("orgs").find(a, .{ ._id = .{ .@"$in" = ids } }, .{ .projection = try val.from(a, .{ .name = 1, .status = 1, .personal = 1 }) });
    var owned: std.ArrayList([]const u8) = .empty;
    for (memberships) |m| {
        if (!m.t("isOwner")) continue;
        for (orgs) |o| if (o.get("_id").sameId(m.get("orgId"))) {
            if (!o.t("personal") and !std.mem.eql(u8, o.s("status") orelse "", "closed")) try owned.append(a, try val.toStr(a, o.get("name")));
            break;
        };
    }
    var personal: ?Val = null;
    for (orgs) |o| if (o.t("personal")) {
        personal = o;
        break;
    };
    const open_parcels = if (personal) |p| try db.col("shipments").count(a, .{ .merchantId = p.get("_id"), .status = .{ .@"$nin" = &messages.final_statuses } }, .{}) else 0;
    const open = try db.col("tasks").count(a, .{ .courierId = .{ .@"$in" = mids }, .status = .{ .@"$in" = &open_tasks } }, .{});
    return .{ .owned = owned.items, .open_parcels = open_parcels, .open_tasks = open, .memberships = memberships, .personal = personal };
}

pub fn deleteAccount(r: *Req, user: Val) !void {
    const a = r.a;
    const b = try deletionBlockers(a, user);
    if (b.owned.len > 0) return r.conflict(try std.fmt.allocPrint(a, "Close the companies you own first: {s}", .{try std.mem.join(a, ", ", b.owned)}), "delete_owned_companies", .{ .names = try std.mem.join(a, "، ", b.owned) });
    if (b.open_tasks > 0) return r.conflict("You still have open delivery tasks. Finish them or ask your dispatcher to reassign them first.", "delete_open_tasks", null);
    if (b.open_parcels > 0) return r.conflict("You have parcels on the way. Wait until they are delivered or cancel them first.", "delete_open_parcels", null);
    const now = a_.now();
    const mids = try val.newArr(a);
    for (b.memberships) |m| try mids.push(m.get("_id"));
    // History keeps "who did this task" without personal details.
    _ = try db.col("memberships").updateMany(a, .{ ._id = .{ .@"$in" = mids } }, .{
        .@"$set" = .{ .status = "removed", .removedAt = now, .name = "Former member", .email = null, .@"duty.onDuty" = false },
        .@"$unset" = .{ .consent = "", .lastLocation = "", .lastLocationAt = "", .@"courier.phone" = "" },
    }, .{});
    _ = try db.col("courier_positions").deleteMany(a, .{ .courierId = .{ .@"$in" = mids } });
    if (b.personal) |p| _ = try db.col("orgs").updateOne(a, .{ ._id = p.get("_id") }, .{ .@"$set" = .{ .status = "closed", .closedAt = now, .name = "Former sender" } }, .{});
    _ = try db.col("push_subscriptions").deleteMany(a, .{ .userId = user.get("id") });
    _ = try db.col("invitations").updateMany(a, .{ .email = try val.lower(a, user.s("email") orelse ""), .status = "pending" }, .{ .@"$set" = .{ .status = "revoked" } }, .{});
    _ = try db.col("users").updateOne(a, .{ ._id = user.get("id") }, .{ .@"$set" = .{ .deletedAt = now, .email = null, .username = null } }, .{});
    for (b.memberships) |m| audit.audit(a, m.get("orgId"), try val.from(a, .{ .userId = user.get("id"), .name = "Former member" }), "member.account_deleted", .{});
}
