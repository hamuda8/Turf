//! First-party JSON API /api/app (src/routes/app/index.js), used by the Turf web app and the
//! native apps: the Wufour session cookie or a Bearer token; state-changing cookie requests must
//! come from our own pages.

const std = @import("std");
const val = @import("mongo").val;
const db = @import("../lib/db.zig");
const web = @import("../web.zig");
const a_ = @import("../app.zig");
const auth = @import("../auth.zig");
const geo = @import("../geo.zig");
const messages = @import("../messages.zig");
const permissions = @import("../permissions.zig");
const realtime = @import("../realtime.zig");
const allocation = @import("../services/allocation.zig");
const tasks = @import("../services/tasks.zig");
const orgs = @import("../services/orgs.zig");
const members = @import("../services/members.zig");
const places = @import("../services/places.zig");
const branding = @import("../services/branding.zig");
const push = @import("../services/push.zig");
const carriers = @import("../services/carriers.zig");
const audit = @import("../services/audit.zig");
const statements = @import("../services/statements.zig");
const verification = @import("../services/verification.zig");
const platform = @import("../services/platform.zig");
const emails = @import("../services/emails.zig");
const accounts = @import("../services/accounts.zig");
const carrier_routes = @import("carrier.zig");
const merchant_routes = @import("merchant.zig");
const courier_routes = @import("courier.zig");
const direct_routes = @import("direct.zig");
const Val = val.Val;
const Req = web.Req;
const V = web.V;
const route = web.route;
const routeMw = web.routeMw;
const need = web.need;
const needAny = web.needAny;

/// Express order: JSON body (3 MB), sign-in, CSRF check, the account routes, the org routes
/// (after withOrg), /direct, then the /api 404.
pub fn handle(r: *Req, path: []const u8) !void {
    try web.parseBody(r, 3 * 1024 * 1024);
    try auth.apiAuth(r);
    try auth.sameSiteOnly(r);
    if (try web.runRoutes(r, &account_routes, path)) return;
    if (web.under(path, "/orgs")) |rest| if (orgIdOf(rest)) |org_part| {
        try withOrg(r, org_part.id);
        const sub = org_part.rest;
        if (try web.runRoutes(r, &org_routes, sub)) return;
        if (web.under(sub, "/carrier")) |c| {
            try web.onlyType("carrier")(r);
            if (try web.runRoutes(r, &carrier_routes.routes, c)) return;
        }
        if (web.under(sub, "/merchant")) |m| {
            try web.onlyType("merchant")(r);
            if (try web.runRoutes(r, &merchant_routes.routes, m)) return;
        }
        if (web.under(sub, "/courier")) |c| {
            try courier_routes.guard(r);
            if (try web.runRoutes(r, &courier_routes.routes, c)) return;
        }
        return r.fail(404, "not_found", "No such endpoint", .{});
    };
    if (web.under(path, "/direct")) |rest| {
        try direct_routes.guard(r);
        if (try web.runRoutes(r, &direct_routes.routes, rest)) return;
    }
    return r.fail(404, "not_found", "No such endpoint", .{});
}

const OrgPart = struct { id: []const u8, rest: []const u8 };

/// "/<orgId>/members" -> { "<orgId>", "/members" }.
fn orgIdOf(rest: []const u8) ?OrgPart {
    const s = if (rest.len > 0 and rest[0] == '/') rest[1..] else rest;
    if (s.len == 0) return null;
    const slash = std.mem.indexOfScalar(u8, s, '/') orelse s.len;
    if (slash == 0) return null;
    return .{ .id = s[0..slash], .rest = if (slash < s.len) s[slash..] else "/" };
}

/// withOrg: resolves the org and the acting member into r.oc.
fn withOrg(r: *Req, raw_id: []const u8) !void {
    const a = r.a;
    const id_text = @import("http").decode(a, raw_id) catch raw_id;
    const org_id = web.oidStr(id_text) orelse return r.notFound("Organization");
    const org = (try orgs.getOrg(a, .{ .id = org_id })) orelse return r.notFound("Organization");
    const oc = (try members.loadContext(a, org, r.user.get("id"))) orelse return r.notFound("Organization");
    if (std.mem.eql(u8, oc.member.s("status") orelse "", "suspended")) return r.fail(403, "member_suspended", "Your access to this company is suspended", .{});
    try orgs.assertOrgUsable(r, org);
    r.oc = oc;
}

fn ok(r: *Req) !void {
    return r.json(200, .{ .ok = true });
}

// ---- Account --------------------------------------------------------------------------------------

const account_routes = [_]web.Route{
    route(.GET, "/me", me),
    route(.GET, "/meta", meta),
    route(.GET, "/push/key", pushKey),
    route(.POST, "/push/subscribe", pushSubscribe),
    route(.POST, "/push/unsubscribe", pushUnsubscribe),
    route(.POST, "/orgs", createOrg),
    route(.GET, "/slug-available", slugAvailable),
    route(.GET, "/invitations/:token", getInvitation),
    route(.POST, "/invitations/:token/accept", acceptInvitation),
    route(.GET, "/me/deletion", deletionInfo),
    route(.POST, "/me/delete", deleteMe),
    route(.POST, "/invitations/:token/decline", declineInvitation),
};

fn me(r: *Req) !void {
    const a = r.a;
    const list = try orgs.orgsForUser(a, r.user.get("id"));
    const invitations = try members.invitationsForUser(a, r.user);
    const out_orgs = try val.newArr(a);
    for (list) |x| {
        const role = x.role;
        try out_orgs.push(.{
            .id = x.org.get("_id"),
            .type = x.org.get("type"),
            .name = x.org.get("name"),
            .slug = x.org.get("slug"),
            .status = x.org.get("status"),
            .branding = try branding.publicBranding(a, x.org),
            .isOwner = x.membership.get("isOwner"),
            .memberStatus = x.membership.get("status"),
            .role = if (role.truthy()) role.get("name") else Val.null,
            .isCourier = x.membership.t("courier") and (x.membership.t("isOwner") or val.includesStr(role.get("permissions"), "courier.work")),
        });
    }
    const out_inv = try val.newArr(a);
    for (invitations) |i| try out_inv.push(.{
        .token = i.get("token"),
        .org = .{ .id = i.path("org._id"), .name = i.path("org.name"), .type = i.path("org.type"), .branding = try branding.publicBranding(a, i.get("org")) },
        .role = i.path("role.name"),
        .invitedBy = if (i.path("invitedBy.name").truthy()) i.path("invitedBy.name") else Val.null,
        .expiresAt = i.get("expiresAt"),
    });
    return r.json(200, .{ .user = r.user, .orgs = out_orgs, .invitations = out_inv });
}

fn meta(r: *Req) !void {
    const a = r.a;
    const govs = try val.newArr(a);
    for (geo.governorates) |g| try govs.push(.{ .code = g.code, .en = g.en, .ar = g.ar, .center = .{ .lat = g.center[1], .lng = g.center[0] } });
    return r.json(200, .{
        .governorates = govs,
        .vehicles = try geo.vehiclesJson(a),
        .permissions = try permissions.catalogJson(a),
        .statuses = try messages.textsJson(a, &messages.statuses),
        .failureReasons = try messages.textsJson(a, &messages.failure_reasons),
        .strategies = &allocation.strategies,
        .taskTypes = &tasks.task_types,
        .platform = try platform.publicInfo(a),
    });
}

fn pushKey(r: *Req) !void {
    return r.json(200, .{ .publicKey = try push.publicKey(r.a) });
}

fn pushSubscribe(r: *Req) !void {
    // The phone apps: { token, kind } (FCM, APNs, VoIP).
    if (r.body.s("token")) |token| {
        try push.saveNative(r, r.user, token, r.body.s("kind") orelse "", r.header("user-agent"));
        return ok(r);
    }
    try push.saveSubscription(r, r.user, r.body.get("subscription"), r.header("user-agent"));
    return ok(r);
}

fn pushUnsubscribe(r: *Req) !void {
    try push.removeSubscription(r.a, r.user, (try V.str(r, r.body.get("endpoint"), "endpoint", .{ .max = 2000 })).?);
    return ok(r);
}

fn createOrg(r: *Req) !void {
    const b = r.body;
    const t = (try V.oneOf(r, b.get("type"), "type", &orgs.org_types, .{})).?;
    if (!(b.get("acceptTerms") == .bool and b.get("acceptTerms").bool))
        return r.fail(400, "terms_required", "Accept the Terms of Service and Privacy Policy to continue", .{ .field = "acceptTerms" });
    const org = try orgs.createOrg(r, r.user, .{
        .type = t,
        .name = (try V.str(r, b.get("name"), "name", .{ .min = 2, .max = 80 })).?,
        .slug = (try V.slug(r, b.get("slug"), "slug", .{})).?,
        .phone = try V.phone(r, b.get("phone"), "phone", .{ .optional = true }),
        .governorate = try V.oneOf(r, b.get("governorate"), "governorate", geo.codes, .{ .optional = true }),
        .terms_version = a_.cfg().terms_version,
    });
    return r.json(201, .{ .id = org.get("_id"), .slug = org.get("slug"), .type = org.get("type"), .status = org.get("status") });
}

fn slugAvailable(r: *Req) !void {
    const slug = (try V.slug(r, r.q("slug"), "slug", .{})).?;
    const taken = try db.col("orgs").count(r.a, .{ .slug = slug }, .{ .limit = 1 });
    return r.json(200, .{ .slug = slug, .available = taken == 0 });
}

fn invitationOr404(r: *Req, token: []const u8) !Val {
    if (token.len > 64) return r.notFound("Invitation");
    return (try members.findInvitationByToken(r.a, token)) orelse r.notFound("Invitation");
}

fn getInvitation(r: *Req) !void {
    const a = r.a;
    const inv = try invitationOr404(r, r.param("token"));
    const org = try db.col("orgs").findOne(a, .{ ._id = inv.get("orgId") }, .{});
    const role = try db.col("roles").findOne(a, .{ ._id = inv.get("roleId") }, .{});
    const expired = (inv.get("expiresAt").dateMs() orelse 0) < a_.nowMs() and std.mem.eql(u8, inv.s("status") orelse "", "pending");
    return r.json(200, .{
        .status = if (expired) Val{ .str = "expired" } else inv.get("status"),
        .email = inv.get("email"),
        .emailMatches = inv.get("email").eql(r.user.get("email")),
        .org = if (org) |o| try val.from(a, .{ .id = o.get("_id"), .name = o.get("name"), .type = o.get("type"), .slug = o.get("slug"), .branding = try branding.publicBranding(a, o) }) else Val.null,
        .role = if (role) |rl| (if (rl.t("name")) rl.get("name") else Val.null) else Val.null,
        .courier = inv.get("courier"),
    });
}

fn acceptInvitation(r: *Req) !void {
    const inv = try invitationOr404(r, r.param("token"));
    const m = try members.acceptInvitation(r, r.user, inv);
    const org = (try db.col("orgs").findOne(r.a, .{ ._id = m.get("orgId") }, .{})) orelse return error.OrgVanished;
    return r.json(200, .{ .orgId = org.get("_id"), .slug = org.get("slug"), .type = org.get("type") });
}

fn deletionInfo(r: *Req) !void {
    const b = try accounts.deletionBlockers(r.a, r.user);
    return r.json(200, .{ .ownedCompanies = b.owned, .openParcels = b.open_parcels, .openTasks = b.open_tasks });
}

fn deleteMe(r: *Req) !void {
    if (!std.mem.eql(u8, r.body.s("confirm") orelse "", "DELETE")) return r.badRequest("Type DELETE to confirm", "confirm", "type_delete", null);
    try accounts.deleteAccount(r, r.user);
    return ok(r);
}

fn declineInvitation(r: *Req) !void {
    try members.declineInvitation(r, r.user, try invitationOr404(r, r.param("token")));
    return ok(r);
}

// ---- Organization (member side) ---------------------------------------------------------------------

const org_routes = [_]web.Route{
    route(.GET, "/", orgView),
    route(.POST, "/leave", leave),
    route(.GET, "/close", closeInfo),
    route(.POST, "/close", close),
    routeMw(.PATCH, "/profile", &.{need(&.{"org.settings"})}, profile),
    route(.GET, "/stream", stream),
    routeMw(.GET, "/platform-fees", &.{need(&.{"finance.view"})}, platformFees),
    routeMw(.PUT, "/verification", &.{need(&.{"org.settings"})}, submitVerification),
    routeMw(.PATCH, "/branding", &.{brandingPerm}, updateBranding),
    routeMw(.PUT, "/branding/logo", &.{brandingPerm}, saveLogo),
    routeMw(.DELETE, "/branding/logo", &.{brandingPerm}, removeLogo),
    routeMw(.GET, "/members", &.{need(&.{"members.view"})}, listMembers),
    routeMw(.PATCH, "/members/:memberId", &.{need(&.{"members.manage"})}, patchMember),
    routeMw(.PUT, "/members/:memberId/courier", &.{need(&.{"members.manage"})}, courierProfile),
    routeMw(.DELETE, "/members/:memberId", &.{need(&.{"members.manage"})}, removeMember),
    routeMw(.GET, "/roles", &.{needAny(&.{ "members.view", "roles.manage", "members.invite" })}, listRoles),
    routeMw(.POST, "/roles", &.{need(&.{"roles.manage"})}, createRole),
    routeMw(.PATCH, "/roles/:roleId", &.{need(&.{"roles.manage"})}, updateRole),
    routeMw(.DELETE, "/roles/:roleId", &.{need(&.{"roles.manage"})}, deleteRole),
    routeMw(.GET, "/invitations", &.{need(&.{"members.invite"})}, listInvitations),
    routeMw(.POST, "/invitations", &.{need(&.{"members.invite"})}, createInvitation),
    routeMw(.DELETE, "/invitations/:invitationId", &.{need(&.{"members.invite"})}, revokeInvitation),
    routeMw(.GET, "/audit", &.{need(&.{"audit.view"})}, listAudit),
};

fn orgView(r: *Req) !void {
    const a = r.a;
    const oc = r.orgCtx();
    const o = oc.org;
    const role = oc.role;
    const view = try val.from(a, .{
        .id = o.get("_id"),
        .type = o.get("type"),
        .name = o.get("name"),
        .slug = o.get("slug"),
        .status = o.get("status"),
        .contact = o.get("contact"),
        .branding = try branding.publicBranding(a, o),
        .me = .{
            .memberId = oc.member.get("_id"),
            .isOwner = oc.member.get("isOwner"),
            .role = if (role.truthy()) try val.from(a, .{ .id = role.get("_id"), .name = role.get("name") }) else Val.null,
            .permissions = oc.perms.keys,
            .courier = oc.member.get("courier"),
            .onDuty = oc.member.path("duty.onDuty").truthy(),
        },
    });
    const t = o.s("type") orelse "";
    if (std.mem.eql(u8, t, "carrier") and oc.perms.has("org.settings")) {
        try view.set("carrier", o.get("carrier"));
        try view.set("readiness", try carriers.readinessIssues(a, o));
        try view.set("verification", try verification.publicView(a, o));
    } else if (std.mem.eql(u8, t, "carrier")) {
        try view.set("carrier", .{ .coverage = o.path("carrier.coverage"), .currency = o.path("carrier.currency"), .maxAttempts = o.path("carrier.maxAttempts") });
    }
    if (std.mem.eql(u8, t, "merchant")) {
        const list = try val.newArr(a);
        for (try places.placesOf(a, o)) |p| try list.push(try places.placeView(a, p));
        var default: Val = .null;
        for (list.items()) |p| if (p.t("isDefault")) {
            default = p;
            break;
        };
        if (default == .null and list.items().len > 0) default = list.at(0);
        const m = try val.from(a, .{ .website = o.path("merchant.website"), .places = list, .defaultPickup = default, .defaultStrategy = o.path("merchant.defaultStrategy") });
        if (oc.perms.has("org.settings")) {
            const owner = try db.col("users").findOne(a, .{ ._id = o.get("ownerUserId") }, .{ .projection = try val.from(a, .{ .email = 1 }) });
            const settings = try emails.emailSettings(a, o);
            try settings.set("lastSummaryDay", Val.undef);
            try settings.set("ownerEmail", if (owner) |ow| (if (ow.t("email")) ow.get("email") else Val.null) else Val.null);
            try m.set("emailNotifications", settings);
        }
        try view.set("merchant", m);
    }
    return r.json(200, view);
}

fn leave(r: *Req) !void {
    try accounts.leaveOrg(r, r.orgCtx());
    return ok(r);
}

fn closeInfo(r: *Req) !void {
    if (!r.orgCtx().member.t("isOwner")) return r.fail(403, "forbidden", "Only the owner can close the company", .{});
    return r.json(200, try accounts.closeBlockers(r.a, r.orgCtx().org));
}

fn close(r: *Req) !void {
    try accounts.closeOrg(r, r.orgCtx(), r.body.get("confirmName"));
    return ok(r);
}

fn profile(r: *Req) !void {
    const b = r.body;
    try carriers.updateOrgProfile(r, r.orgCtx(), try V.str(r, b.get("name"), "name", .{ .min = 2, .max = 80, .optional = true }), try V.phone(r, b.get("phone"), "phone", .{ .optional = true }), try V.oneOf(r, b.get("governorate"), "governorate", geo.codes, .{ .optional = true }));
    return ok(r);
}

/// Live stream for the org's consoles. Separate channels, so each event only reaches people
/// allowed to see it (a hub operator gets no couriers' GPS or SOS alerts).
fn stream(r: *Req) !void {
    const a = r.a;
    const oc = r.orgCtx();
    const o = oc.org;
    const id = o.get("_id");
    var list: std.ArrayList([]const u8) = .empty;
    const carrier = std.mem.eql(u8, o.s("type") orelse "", "carrier");
    if (carrier) {
        if (oc.perms.has("shipments.view") or oc.perms.has("dispatch.manage")) try list.append(a, realtime.chan(a, "carrier", id));
        if (oc.perms.has("fleet.view") or oc.perms.has("dispatch.manage")) try list.append(a, realtime.chan(a, "fleet", id));
        if (oc.perms.has("alerts.manage")) try list.append(a, realtime.chan(a, "alerts", id));
    }
    if (std.mem.eql(u8, o.s("type") orelse "", "merchant") and oc.perms.has("shipments.view")) try list.append(a, realtime.chan(a, "merchant", id));
    if (carrier and oc.perms.has("courier.work")) try list.append(a, realtime.chan(a, "courier", oc.member.get("_id")));
    if (list.items.len == 0) return r.badRequest("Nothing to stream for your role", null, null, null);
    return realtime.subscribe(r, list.items, "hello", try val.from(a, .{ .channels = list.items.len }));
}

fn platformFees(r: *Req) !void {
    const month = r.qs("month") orelse ((try val.isoAlloc(r.a, a_.nowMs()))[0..7]);
    return r.json(200, try statements.platformFeesFor(r, r.orgCtx().org.get("_id"), if (month.len > 0) month else (try val.isoAlloc(r.a, a_.nowMs()))[0..7]));
}

fn submitVerification(r: *Req) !void {
    if (!std.mem.eql(u8, r.orgCtx().org.s("type") orelse "", "carrier")) return r.notFound("Route");
    return r.json(200, try verification.submit(r, r.orgCtx(), r.body));
}

fn brandingPerm(r: *Req) anyerror!void {
    const carrier = std.mem.eql(u8, r.orgCtx().org.s("type") orelse "", "carrier");
    return (if (carrier) need(&.{"org.branding"}) else need(&.{"org.settings"}))(r);
}

fn updateBranding(r: *Req) !void {
    const b = r.body;
    try branding.updateBranding(
        r,
        r.orgCtx(),
        try V.str(r, b.get("appName"), "appName", .{ .max = 40, .optional = true }),
        try V.str(r, b.get("shortName"), "shortName", .{ .max = 12, .optional = true }),
        try V.hexColor(r, b.get("primaryColor"), "primaryColor", .{ .optional = true }),
        try V.hexColor(r, b.get("accentColor"), "accentColor", .{ .optional = true }),
    );
    return ok(r);
}

fn saveLogo(r: *Req) !void {
    const version = try branding.saveLogo(r, r.orgCtx(), r.body);
    return r.json(200, .{ .ok = true, .version = version });
}

fn removeLogo(r: *Req) !void {
    try branding.removeLogo(r, r.orgCtx());
    return ok(r);
}

fn listMembers(r: *Req) !void {
    const a = r.a;
    const list = try members.listMembers(a, r.orgCtx().org.get("_id"));
    const show_location = r.orgCtx().perms.has("fleet.view");
    const out = try val.newArr(a);
    for (list) |m| try out.push(.{
        .id = m.get("_id"),
        .userId = m.get("userId"),
        .name = m.get("name"),
        .email = m.get("email"),
        .isOwner = m.get("isOwner"),
        .roleId = m.get("roleId"),
        .status = m.get("status"),
        .courier = m.get("courier"),
        .onDuty = m.path("duty.onDuty").truthy(),
        .lastLocationAt = if (show_location) (if (m.t("lastLocationAt")) m.get("lastLocationAt") else Val.null) else Val.undef,
        .joinedAt = m.get("joinedAt"),
    });
    return r.json(200, out);
}

fn patchMember(r: *Req) !void {
    const member_id: Val = .{ .id = (try V.id(r, .{ .str = r.param("memberId") }, "memberId", .{})).? };
    if (r.body.get("roleId") != .undef) try members.changeRole(r, r.orgCtx(), member_id, .{ .id = (try V.id(r, r.body.get("roleId"), "roleId", .{})).? });
    if (r.body.get("status") != .undef) try members.setMemberStatus(r, r.orgCtx(), member_id, (try V.oneOf(r, r.body.get("status"), "status", &.{ "active", "suspended" }, .{})).?);
    return ok(r);
}

fn courierProfile(r: *Req) !void {
    const member_id: Val = .{ .id = (try V.id(r, .{ .str = r.param("memberId") }, "memberId", .{})).? };
    return r.json(200, try members.updateCourierProfile(r, r.orgCtx(), member_id, (try V.obj(r, r.body, "body", .{})).?));
}

fn removeMember(r: *Req) !void {
    try members.removeMember(r, r.orgCtx(), .{ .id = (try V.id(r, .{ .str = r.param("memberId") }, "memberId", .{})).? });
    return ok(r);
}

fn listRoles(r: *Req) !void {
    return r.json(200, try members.listRoles(r.a, r.orgCtx().org.get("_id")));
}

fn createRole(r: *Req) !void {
    const name = (try V.str(r, r.body.get("name"), "name", .{ .max = 40 })).?;
    const perms = (try V.arr(r, r.body.get("permissions"), "permissions", .{ .max = 50 })).?;
    return r.json(201, try members.createRole(r, r.orgCtx(), name, perms));
}

fn updateRole(r: *Req) !void {
    const role_id: Val = .{ .id = (try V.id(r, .{ .str = r.param("roleId") }, "roleId", .{})).? };
    const name = try V.str(r, r.body.get("name"), "name", .{ .max = 40, .optional = true });
    const perms = try V.arr(r, r.body.get("permissions"), "permissions", .{ .max = 50, .optional = true });
    try members.updateRole(r, r.orgCtx(), role_id, name, perms);
    return ok(r);
}

fn deleteRole(r: *Req) !void {
    try members.deleteRole(r, r.orgCtx(), .{ .id = (try V.id(r, .{ .str = r.param("roleId") }, "roleId", .{})).? });
    return ok(r);
}

fn inviteView(a: std.mem.Allocator, inv: Val) !Val {
    return val.from(a, .{
        .id = inv.get("_id"),
        .email = inv.get("email"),
        .roleId = inv.get("roleId"),
        .courier = inv.get("courier"),
        .invitedBy = if (inv.path("invitedBy.name").truthy()) inv.path("invitedBy.name") else Val.null,
        .createdAt = inv.get("createdAt"),
        .expiresAt = inv.get("expiresAt"),
        .link = try std.fmt.allocPrint(a, "{s}/invite/{s}", .{ a_.cfg().public_url, try val.toStr(a, inv.get("token")) }),
    });
}

fn listInvitations(r: *Req) !void {
    const out = try val.newArr(r.a);
    for (try members.listInvitations(r.a, r.orgCtx().org.get("_id"))) |i| try out.push(try inviteView(r.a, i));
    return r.json(200, out);
}

fn createInvitation(r: *Req) !void {
    const inv = try members.createInvitation(
        r,
        r.orgCtx(),
        (try V.email(r, r.body.get("email"), "email", .{})).?,
        .{ .id = (try V.id(r, r.body.get("roleId"), "roleId", .{})).? },
        try V.obj(r, r.body.get("courier"), "courier", .{ .optional = true }),
    );
    return r.json(201, try inviteView(r.a, inv));
}

fn revokeInvitation(r: *Req) !void {
    try members.revokeInvitation(r, r.orgCtx(), .{ .id = (try V.id(r, .{ .str = r.param("invitationId") }, "invitationId", .{})).? });
    return ok(r);
}

fn listAudit(r: *Req) !void {
    const before: ?i64 = if (r.qs("before")) |b| (if (b.len > 0) val.newDate(.{ .str = b }) else null) else null;
    return r.json(200, try audit.listAudit(r.a, r.orgCtx().org.get("_id"), before));
}
