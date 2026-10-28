//! Team (Turf-js views/shared/team.js): members, roles and their permissions, invitations.
//! Shared by carriers and merchants.

const std = @import("std");
const zui = @import("zui");
const core = @import("../core.zig");
const kit = @import("../kit.zig");
const shell = @import("../shell.zig");
const json = @import("../json.zig");
const fmt = @import("../fmt.zig");
const icons = @import("../icons.zig");
const labels = @import("../labels.zig");
const cm = @import("../widgets/common.zig");

const Cx = core.Cx;
const Ui = core.Ui;
const V = json.V;
const L = labels.k;
const eq = std.mem.eql;

const d_roles: u8 = 0;
const d_members: u8 = 1;
const d_invs: u8 = 2;
const d_link: u8 = 3;

const f_email: u16 = 0;
const f_role: u16 = 1;
const f_vehicle: u16 = 2;
const f_cphone: u16 = 3;
const f_plate: u16 = 4;
const f_range: u16 = 5;
const f_capacity: u16 = 6;
const f_role_name: u16 = 7;
/// The role drop-down of member row i.
const f_member_role: u16 = 100;

const A = enum(u16) {
    tab = 1,
    invite_open,
    invite,
    close,
    courier_open,
    courier_save,
    toggle_status,
    remove_ask,
    remove,
    member_role,
    role_open,
    role_new,
    role_save,
    role_perm,
    role_delete_ask,
    role_delete,
    revoke,
};

pub const Tab = enum { members, roles, invitations };
const Dialog = enum { none, invite, link, courier, role };

pub const S = struct {
    tab: Tab = .members,
    dialog: Dialog = .none,
    /// The member whose courier details are edited / the role being edited (null: new).
    target: ?[]const u8 = null,
    perms: cm.IdSet = .{},
};

pub fn title(_: *const S, _: *const Cx) []const u8 {
    return L("nav.team");
}

fn tabAllowed(c: *const Cx, t: Tab) bool {
    return switch (t) {
        .members => c.can("members.view"),
        .roles => c.can("roles.manage") or c.can("members.view"),
        .invitations => c.can("members.invite"),
    };
}

fn isOwner(c: *const Cx) bool {
    return json.boolean(c.orgV(), "me.isOwner");
}

/// Roles I may hand out: the owner any; others only subsets of their own (courier.work is
/// neutral).
fn grantable(c: *const Cx, r: V) bool {
    if (isOwner(c)) return true;
    for (json.arr(r, "permissions")) |p| {
        if (p != .string) continue;
        if (!eq(u8, p.string, "courier.work") and !c.can(p.string)) return false;
    }
    return true;
}

fn roleById(c: *const Cx, id: []const u8) ?V {
    for (json.arr(c.data(d_roles), "")) |r| if (eq(u8, cm.docId(r), id)) return r;
    return null;
}

fn isCourierRole(c: *const Cx, id: []const u8) bool {
    return json.contains(roleById(c, id), "permissions", "courier.work");
}

fn myId(c: *const Cx) []const u8 {
    return json.str(c.me.value, "user.id");
}

fn manageable(c: *const Cx, m: V) bool {
    return c.can("members.manage") and !json.boolean(m, "isOwner") and !eq(u8, json.str(m, "userId"), myId(c));
}

pub fn actions(_: *const S, c: *const Cx, ui: *Ui) void {
    if (c.can("members.invite")) kit.button(ui, L("team.invite"), kit.act(A.invite_open, 0), .{ .variant = .primary, .icon = icons.add });
}

fn slotOf(t: Tab) u8 {
    return switch (t) {
        .members => d_members,
        .roles => d_roles,
        .invitations => d_invs,
    };
}

fn urlOf(c: *Cx, t: Tab) []const u8 {
    return c.orgUrl(switch (t) {
        .members => "/members",
        .roles => "/roles",
        .invitations => "/invitations",
    });
}

/// Loads the open tab (`show`); `quiet` keeps what is shown until the answer is there.
fn show(s: *const S, c: *Cx, quiet: bool) void {
    const n = slotOf(s.tab);
    if (!quiet) c.slots[n].reset();
    c.load(n, urlOf(c, s.tab));
}

pub fn enter(s: *S, c: *Cx) void {
    const q = c.query(c.arena(), "tab");
    var first: ?Tab = null;
    for ([_]Tab{ .members, .roles, .invitations }) |t| if (tabAllowed(c, t) and first == null) {
        first = t;
    };
    s.tab = first orelse .members;
    if (std.meta.stringToEnum(Tab, q)) |t| if (tabAllowed(c, t)) {
        s.tab = t;
    };
    c.load(d_roles, c.orgUrl("/roles"));
    if (s.tab != .roles) show(s, c, false);
}

fn memberAt(c: *const Cx, i: u32) ?V {
    const l = json.arr(c.data(d_members), "");
    return if (i < l.len) l[i] else null;
}

fn setCourier(c: *Cx, p: ?V) void {
    c.setVal(f_vehicle, json.strOr(p, "vehicle", "motorbike"));
    c.setVal(f_cphone, json.str(p, "phone"));
    c.setVal(f_plate, json.str(p, "plate"));
    c.setVal(f_range, cm.numText(c, p, "rangeKm"));
    c.setVal(f_capacity, cm.numText(c, p, "capacityKg"));
}

fn courierBody(b: *json.Obj, c: *const Cx) void {
    b.strOpt("vehicle", c.val(f_vehicle));
    b.strOpt("phone", c.val(f_cphone));
    b.strOpt("plate", c.val(f_plate));
    cm.numOpt(b, c, "rangeKm", f_range);
    cm.numOpt(b, c, "capacityKg", f_capacity);
}

fn assignable(c: *const Cx, a: std.mem.Allocator) []const V {
    var out: std.ArrayList(V) = .empty;
    for (json.arr(c.data(d_roles), "")) |r| if (grantable(c, r)) out.append(a, r) catch {};
    return out.items;
}

pub fn update(s: *S, c: *Cx, e: core.Ev) void {
    switch (e) {
        .data => |n| {
            const sl = c.slot(n);
            // A quiet refresh that failed says so.
            if (sl.state == .ok and sl.err.len > 0) c.toast(sl.err, .err);
            if (n == d_members and sl.state == .ok) {
                for (json.arr(c.data(d_members), ""), 0..) |m, i| if (i < 400) c.setVal(f_member_role + @as(u16, @intCast(i)), json.str(m, "roleId"));
            }
        },
        .text => |x| if (x.slot >= f_member_role and x.slot < f_member_role + 400) {
            const i = x.slot - f_member_role;
            const m = memberAt(c, i) orelse return;
            if (eq(u8, x.text, json.str(m, "roleId"))) return;
            var b = json.Obj.init(c.arena());
            b.str("roleId", x.text);
            c.sendArg(@intFromEnum(A.member_role), i, .PATCH, c.orgUrl(c.print("/members/{s}", .{cm.docId(m)})), b.done());
        },
        .act => |a| switch (@as(A, @enumFromInt(a.id))) {
            .tab => {
                const t: Tab = @enumFromInt(@min(a.arg, 2));
                if (t == s.tab) return;
                s.tab = t;
                show(s, c, false);
            },
            .close => s.dialog = .none,
            .invite_open => {
                s.dialog = .invite;
                c.clearFieldError();
                c.setVal(f_email, "");
                const opts = assignable(c, c.arena());
                c.setVal(f_role, if (opts.len > 0) cm.docId(opts[0]) else "");
                setCourier(c, null);
            },
            .invite => {
                var b = json.Obj.init(c.arena());
                b.strOpt("email", c.val(f_email));
                b.strOpt("roleId", c.val(f_role));
                if (isCourierRole(c, c.val(f_role))) {
                    b.begin("courier");
                    courierBody(&b, c);
                    b.end();
                }
                c.send(@intFromEnum(A.invite), .POST, c.orgUrl("/invitations"), b.done());
            },
            .courier_open => if (memberAt(c, a.arg)) |m| {
                s.dialog = .courier;
                s.target = c.dupe(cm.docId(m));
                c.clearFieldError();
                setCourier(c, json.get(m, "courier"));
            },
            .courier_save => if (s.target) |id| {
                var b = json.Obj.init(c.arena());
                courierBody(&b, c);
                c.send(@intFromEnum(A.courier_save), .PUT, c.orgUrl(c.print("/members/{s}/courier", .{id})), b.done());
            },
            .toggle_status => if (memberAt(c, a.arg)) |m| {
                var b = json.Obj.init(c.arena());
                b.str("status", if (eq(u8, json.str(m, "status"), "active")) "suspended" else "active");
                c.sendArg(@intFromEnum(A.toggle_status), a.arg, .PATCH, c.orgUrl(c.print("/members/{s}", .{cm.docId(m)})), b.done());
            },
            .remove_ask => if (memberAt(c, a.arg)) |m| {
                c.ask(cm.txc(c, "team.remove_confirm", .{ .name = json.strOr(m, "name", json.str(m, "email")) }), .{ .danger = true, .label = L("team.remove"), .act = .{ .id = @intFromEnum(A.remove), .arg = a.arg } });
            },
            .remove => if (memberAt(c, a.arg)) |m| c.sendArg(@intFromEnum(A.remove), a.arg, .DELETE, c.orgUrl(c.print("/members/{s}", .{cm.docId(m)})), ""),
            .role_new, .role_open => {
                const r: ?V = if (@as(A, @enumFromInt(a.id)) == .role_open) blk: {
                    const l = json.arr(c.data(d_roles), "");
                    break :blk if (a.arg < l.len) l[a.arg] else return;
                } else null;
                s.dialog = .role;
                s.target = if (r) |x| c.dupe(cm.docId(x)) else null;
                c.clearFieldError();
                c.setVal(f_role_name, json.str(r, "name"));
                s.perms.clear();
                for (json.arr(r, "permissions")) |p| if (p == .string) s.perms.add(c, p.string);
            },
            .role_perm => {
                const cat = catalog(c);
                if (a.arg >= cat.len) return;
                const key = json.str(cat[a.arg], "key");
                if (!canGrant(c, key)) return;
                s.perms.toggle(c, key);
            },
            .role_save => {
                var b = json.Obj.init(c.arena());
                b.str("name", c.valTrim(f_role_name));
                b.beginArray("permissions");
                // In the catalog's order, as the form lists them.
                for (catalog(c)) |p| if (s.perms.has(json.str(p, "key"))) b.str("", json.str(p, "key"));
                b.endArray();
                if (s.target) |id|
                    c.send(@intFromEnum(A.role_save), .PATCH, c.orgUrl(c.print("/roles/{s}", .{id})), b.done())
                else
                    c.send(@intFromEnum(A.role_save), .POST, c.orgUrl("/roles"), b.done());
            },
            .role_delete_ask => {
                const l = json.arr(c.data(d_roles), "");
                if (a.arg >= l.len) return;
                c.ask(cm.txc(c, "team.delete_role_confirm", .{ .name = json.str(l[a.arg], "name") }), .{ .danger = true, .act = .{ .id = @intFromEnum(A.role_delete), .arg = a.arg } });
            },
            .role_delete => {
                const l = json.arr(c.data(d_roles), "");
                if (a.arg >= l.len) return;
                c.sendArg(@intFromEnum(A.role_delete), a.arg, .DELETE, c.orgUrl(c.print("/roles/{s}", .{cm.docId(l[a.arg])})), "");
            },
            .revoke => {
                const l = json.arr(c.data(d_invs), "");
                if (a.arg >= l.len) return;
                c.sendArg(@intFromEnum(A.revoke), a.arg, .DELETE, c.orgUrl(c.print("/invitations/{s}", .{json.strOr(l[a.arg], "id", json.str(l[a.arg], "_id"))})), "");
            },
            .member_role => {},
        },
        .done => |d| switch (@as(A, @enumFromInt(d.id))) {
            .invite => if (d.ok) {
                cm.keep(c, d_link, d.body);
                s.dialog = .link;
                if (s.tab == .invitations) show(s, c, true);
            },
            .courier_save => if (d.ok) {
                s.dialog = .none;
                c.toast(L("common.saved"), .ok);
                show(s, c, true);
            },
            .member_role => if (d.ok) {
                c.toast(L("common.saved"), .ok);
                show(s, c, true);
            } else if (memberAt(c, d.arg)) |m| c.setVal(f_member_role + @as(u16, @intCast(d.arg)), json.str(m, "roleId")),
            .toggle_status, .remove, .role_delete, .revoke => if (d.ok) {
                c.toast(L("common.saved"), .ok);
                show(s, c, true);
            },
            .role_save => if (d.ok) {
                s.dialog = .none;
                c.load(d_roles, c.orgUrl("/roles"));
                c.toast(L("common.saved"), .ok);
                if (s.tab != .roles) show(s, c, true);
            },
            else => {},
        },
        else => {},
    }
}

fn catalog(c: *const Cx) []const V {
    const perms = json.get(c.meta.value, "permissions") orelse return &.{};
    return json.arr(perms, c.orgType());
}

fn canGrant(c: *const Cx, key: []const u8) bool {
    return isOwner(c) or eq(u8, key, "courier.work") or c.can(key);
}

// ---- View ---------------------------------------------------------------------------------

pub fn view(s: *const S, c: *const Cx, ui: *Ui) void {
    kit.stack(ui);
    kit.tabsBegin(ui);
    inline for (.{ .{ Tab.members, "team.members" }, .{ Tab.roles, "team.roles" }, .{ Tab.invitations, "team.invitations" } }) |x| {
        if (tabAllowed(c, x[0])) kit.tab(ui, L(x[1]), s.tab == x[0], kit.act(A.tab, @intFromEnum(x[0])));
    }
    kit.tabsEnd(ui);
    switch (s.tab) {
        .members => if (kit.gate(ui, &.{ d_roles, d_members })) membersTab(c, ui),
        .roles => if (kit.gate(ui, &.{d_roles})) rolesTab(c, ui),
        .invitations => if (kit.gate(ui, &.{ d_roles, d_invs })) invitationsTab(c, ui),
    }
    ui.end();
}

fn membersTab(c: *const Cx, ui: *Ui) void {
    const a = ui.arena();
    var tb = kit.Table.begin(ui, &.{
        .{ .label = L("common.name"), .grow = 1.6 },
        .{ .label = L("team.role"), .grow = 1.3 },
        .{ .label = L("common.status") },
        .{ .label = L("team.joined") },
        .{ .width = 190 },
    });
    for (json.arr(c.data(d_members), ""), 0..) |m, i| {
        tb.row(null, zui.key(cm.docId(m)));
        tb.cell(false);
        ui.begin(.{ .direction = .row, .gap = 6.4, .align_items = .center }, .{});
        kit.strong(ui, json.strOr(m, "name", "—"));
        if (eq(u8, json.str(m, "userId"), myId(c))) kit.badge(ui, L("team.you"), .plain);
        ui.end();
        ui.begin(.{ .no_mirror = true }, .{});
        kit.small(ui, json.str(m, "email"));
        ui.end();
        tb.endCell();
        tb.cell(true);
        if (json.boolean(m, "isOwner")) {
            kit.badgeIcon(ui, L("team.owner"), .brand, icons.shield);
        } else if (manageable(c, m)) {
            var opts: std.ArrayList(core.Opt) = .empty;
            const choices = assignable(c, a);
            const current = roleById(c, json.str(m, "roleId"));
            if (current) |cur| {
                var listed = false;
                for (choices) |r| if (eq(u8, cm.docId(r), cm.docId(cur))) {
                    listed = true;
                };
                if (!listed) opts.append(a, .{ .value = cm.docId(cur), .label = json.str(cur, "name") }) catch {};
            }
            for (choices) |r| opts.append(a, .{ .value = cm.docId(r), .label = json.str(r, "name") }) catch {};
            if (c.isBusy(@intFromEnum(A.member_role)) and (c.act_args.get(@intFromEnum(A.member_role)) orelse 0) == i) {
                kit.spinner(ui, 18, kit.k.ink_3);
            } else if (i < 400) kit.select(ui, f_member_role + @as(u16, @intCast(i)), opts.items, .{ .title = L("team.role") })
            // Past 400 members the form slots run out: the role is shown, changed from row 1..400 only.
            else kit.text(ui, json.strOr(roleById(c, json.str(m, "roleId")), "name", "—"), .{});
        } else kit.text(ui, json.strOr(roleById(c, json.str(m, "roleId")), "name", "—"), .{});
        tb.endCell();
        tb.cell(true);
        const active = eq(u8, json.str(m, "status"), "active");
        kit.badge(ui, labels.of("team.status.", json.str(m, "status")), if (active) .green else .red);
        if (json.obj(m, "courier")) |co| kit.small(ui, if (json.boolean(m, "onDuty")) kit.f(ui, "{s} · {s}", .{ labels.vehicle(json.str(co, "vehicle")), L("driver.on_duty") }) else labels.vehicle(json.str(co, "vehicle")));
        tb.endCell();
        tb.cell(true);
        kit.text(ui, fmt.date(a, json.str(m, "joinedAt")), .{});
        tb.endCell();
        tb.cell(false);
        ui.begin(.{ .direction = .row, .gap = 5.6 }, .{});
        if (json.has(m, "courier") and c.can("members.manage") and !json.boolean(m, "isOwner")) kit.iconButton(ui, icons.edit, kit.act(A.courier_open, @intCast(i)), .{ .size = .sm, .label = L("team.courier_details") });
        if (manageable(c, m)) {
            const mine_s = c.isBusy(@intFromEnum(A.toggle_status)) and (c.act_args.get(@intFromEnum(A.toggle_status)) orelse 0) == i;
            const mine_r = c.isBusy(@intFromEnum(A.remove)) and (c.act_args.get(@intFromEnum(A.remove)) orelse 0) == i;
            kit.button(ui, if (active) L("team.suspend") else L("team.reactivate"), kit.act(A.toggle_status, @intCast(i)), .{ .size = .sm, .busy = if (mine_s) @intFromEnum(A.toggle_status) else null });
            kit.iconButton(ui, icons.delete, kit.act(A.remove_ask, @intCast(i)), .{ .size = .sm, .variant = .ghost, .label = L("team.remove"), .busy = if (mine_r) @intFromEnum(A.remove) else null });
        }
        ui.end();
        tb.endCell();
        tb.endRow();
    }
    tb.end();
}

fn rolesTab(c: *const Cx, ui: *Ui) void {
    const k = kit.k;
    kit.stack(ui);
    if (c.can("roles.manage")) {
        kit.rowEnd(ui);
        kit.button(ui, L("team.new_role"), kit.act(A.role_new, 0), .{ .variant = .primary, .icon = icons.add });
        ui.end();
    }
    const roles = json.arr(c.data(d_roles), "");
    const my_role = json.str(c.orgV(), "me.role.id");
    var g = kit.grid(ui, roles.len, 2);
    for (roles, 0..) |r, i| {
        g.cell();
        kit.card(ui, .{ .gap = 8.8, .key = zui.key(cm.docId(r)) });
        kit.cardHead(ui, json.str(r, "name"));
        const editable = c.can("roles.manage") and grantable(c, r) and !eq(u8, cm.docId(r), my_role);
        if (editable) {
            ui.begin(.{ .direction = .row, .gap = 4 }, .{});
            kit.iconButton(ui, icons.edit, kit.act(A.role_open, @intCast(i)), .{ .size = .sm, .label = L("common.edit") });
            if (json.int(r, "memberCount") == 0) {
                const mine = c.isBusy(@intFromEnum(A.role_delete)) and (c.act_args.get(@intFromEnum(A.role_delete)) orelse 0) == i;
                kit.iconButton(ui, icons.delete, kit.act(A.role_delete_ask, @intCast(i)), .{ .size = .sm, .variant = .ghost, .label = L("common.delete"), .busy = if (mine) @intFromEnum(A.role_delete) else null });
            }
            ui.end();
        }
        ui.end();
        kit.small(ui, cm.tx(ui, "team.role_members", .{ .n = json.int(r, "memberCount") }));
        const perms = json.arr(r, "permissions");
        if (perms.len == 0) kit.small(ui, L("team.no_permissions")) else {
            var w = kit.Wrap.begin(ui, @max(kit.width / 2 - 60, 220), 5.6);
            for (perms) |p| {
                if (p != .string) continue;
                const lbl = labels.of("perm.", p.string);
                w.item(kit.estimate(lbl, 12) + 22);
                kit.badge(ui, lbl, .plain);
            }
            w.end();
        }
        kit.endCard(ui, .{});
        g.endCell();
    }
    g.end();
    ui.end();
    _ = k;
}

fn invitationsTab(c: *const Cx, ui: *Ui) void {
    const a = ui.arena();
    const list = json.arr(c.data(d_invs), "");
    if (list.len == 0) {
        kit.emptyBegin(ui, L("team.no_invitations"));
        kit.button(ui, L("team.invite"), kit.act(A.invite_open, 0), .{ .variant = .primary, .icon = icons.add });
        kit.emptyEnd(ui);
        return;
    }
    var tb = kit.Table.begin(ui, &.{
        .{ .label = L("common.email"), .grow = 1.6 },
        .{ .label = L("team.role") },
        .{ .label = L("team.expires") },
        .{ .width = 230 },
    });
    for (list, 0..) |inv, i| {
        tb.row(null, zui.key(json.strOr(inv, "id", json.str(inv, "_id"))));
        tb.cell(false);
        ui.begin(.{ .no_mirror = true }, .{});
        kit.text(ui, json.str(inv, "email"), .{});
        ui.end();
        tb.endCell();
        tb.cell(true);
        kit.text(ui, json.strOr(roleById(c, json.str(inv, "roleId")), "name", "—"), .{});
        if (json.obj(inv, "courier")) |co| kit.small(ui, labels.vehicle(json.str(co, "vehicle")));
        tb.endCell();
        tb.cell(true);
        kit.text(ui, fmt.relative(a, json.str(inv, "expiresAt")), .{});
        tb.endCell();
        tb.cell(false);
        ui.begin(.{ .direction = .row, .gap = 5.6 }, .{});
        kit.copyButton(ui, json.str(inv, "link"), L("team.copy_link"));
        const mine = c.isBusy(@intFromEnum(A.revoke)) and (c.act_args.get(@intFromEnum(A.revoke)) orelse 0) == i;
        kit.button(ui, L("team.revoke"), kit.act(A.revoke, @intCast(i)), .{ .size = .sm, .variant = .ghost, .busy = if (mine) @intFromEnum(A.revoke) else null });
        ui.end();
        tb.endCell();
        tb.endRow();
    }
    tb.end();
}

// ---- Dialogs ------------------------------------------------------------------------------

/// `submit`: Enter in a field sends the dialog (its form's submit).
fn courierFields(c: *const Cx, ui: *Ui, submit: core.Msg) void {
    const a = ui.arena();
    var opts: std.ArrayList(core.Opt) = .empty;
    for (cm.vehicles(c, a)) |v| opts.append(a, .{ .value = v, .label = labels.vehicle(v) }) catch {};
    var g = kit.formGrid(ui, 5);
    g.cell();
    kit.selectField(ui, L("courier.vehicle"), f_vehicle, opts.items, .{ .required = true, .name = "courier.vehicle" });
    g.endCell();
    g.cell();
    kit.field(ui, L("common.phone"), f_cphone, .{ .input = .{ .kind = .phone, .ltr = true, .name = "courier.phone", .on_submit = submit } });
    g.endCell();
    g.cell();
    kit.field(ui, L("courier.plate"), f_plate, .{ .input = .{ .ltr = true, .name = "courier.plate", .on_submit = submit } });
    g.endCell();
    g.cell();
    kit.field(ui, L("courier.range"), f_range, .{ .hint = L("courier.range_hint"), .input = .{ .kind = .number, .ltr = true, .name = "courier.rangeKm", .on_submit = submit } });
    g.endCell();
    g.cell();
    kit.field(ui, L("courier.capacity"), f_capacity, .{ .hint = L("courier.capacity_hint"), .input = .{ .kind = .number, .ltr = true, .name = "courier.capacityKg", .on_submit = submit } });
    g.endCell();
    g.end();
}

pub fn overlay(s: *const S, c: *const Cx, ui: *Ui) void {
    const close = kit.act(A.close, 0);
    switch (s.dialog) {
        .none => {},
        .invite => {
            shell.modalBegin(ui, .{ .title = L("team.invite"), .close = close, .key = zui.key("invite") });
            kit.muted(ui, L("team.invite_intro"));
            kit.field(ui, L("common.email"), f_email, .{ .required = true, .input = .{ .kind = .email, .ltr = true, .name = "email", .on_submit = kit.act(A.invite, 0) } });
            var opts: std.ArrayList(core.Opt) = .empty;
            for (assignable(c, ui.arena())) |r| opts.append(ui.arena(), .{ .value = cm.docId(r), .label = json.str(r, "name") }) catch {};
            kit.selectField(ui, L("team.role"), f_role, opts.items, .{ .required = true, .name = "roleId" });
            if (isCourierRole(c, c.val(f_role))) {
                ui.begin(.{ .gap = 12, .padding = .all(16), .radius = 18, .border_width = 1, .border_color = kit.k.line }, .{});
                kit.h3(ui, L("team.courier_details"));
                courierFields(c, ui, kit.act(A.invite, 0));
                ui.end();
            }
            shell.modalFoot(ui);
            shell.modalButton(ui, L("common.cancel"), close, .{});
            shell.modalButton(ui, L("team.send_invite"), kit.act(A.invite, 0), .{ .variant = .primary, .busy = @intFromEnum(A.invite) });
            shell.modalEnd(ui, true);
        },
        .link => {
            const inv = c.data(d_link);
            const link = json.str(inv, "link");
            shell.modalBegin(ui, .{ .title = L("team.invite_ready"), .close = close, .key = zui.key("invite-ready") });
            kit.text(ui, cm.tx(ui, "team.invite_share", .{ .email = json.str(inv, "email") }), .{});
            ui.begin(.{ .padding = .xy(16, 12), .radius = 12, .background = kit.k.panel_3, .no_mirror = true }, .{});
            kit.mono(ui, link, .{});
            ui.end();
            ui.begin(.{ .direction = .row, .gap = 12 }, .{});
            kit.copyButton(ui, link, L("team.copy_link"));
            const message = cm.tx(ui, "team.invite_message", .{ .org = json.str(c.orgV(), "name"), .link = link });
            kit.button(ui, "WhatsApp", .{ .open = kit.f(ui, "https://wa.me/?text={s}", .{core.encode(ui.arena(), message)}) }, .{ .size = .sm, .icon = icons.call });
            ui.end();
            kit.small(ui, L("team.invite_note"));
            shell.modalFoot(ui);
            shell.modalButton(ui, L("common.done"), close, .{ .variant = .primary });
            shell.modalEnd(ui, true);
        },
        .courier => {
            shell.modalBegin(ui, .{ .title = L("team.courier_details"), .close = close, .key = zui.key("courier-details") });
            courierFields(c, ui, kit.act(A.courier_save, 0));
            shell.modalFoot(ui);
            shell.modalButton(ui, L("common.cancel"), close, .{});
            shell.modalButton(ui, L("common.save"), kit.act(A.courier_save, 0), .{ .variant = .primary, .busy = @intFromEnum(A.courier_save) });
            shell.modalEnd(ui, true);
        },
        .role => roleDialog(s, c, ui),
    }
}

fn roleDialog(s: *const S, c: *const Cx, ui: *Ui) void {
    const k = kit.k;
    const close = kit.act(A.close, 0);
    shell.modalBegin(ui, .{ .title = if (s.target != null) L("team.edit_role") else L("team.new_role"), .close = close, .key = zui.key("role") });
    kit.field(ui, L("team.role_name"), f_role_name, .{ .required = true, .input = .{ .name = "name", .max_len = 40, .on_submit = kit.act(A.role_save, 0) } });
    kit.notice(ui, .info, L("team.role_rule"));
    const cat = catalog(c);
    var groups: std.ArrayList([]const u8) = .empty;
    for (cat) |p| {
        const g = json.str(p, "group");
        var seen = false;
        for (groups.items) |x| if (eq(u8, x, g)) {
            seen = true;
        };
        if (!seen) groups.append(ui.arena(), g) catch {};
    }
    for (groups.items) |g| {
        ui.begin(.{ .gap = 7.2 }, .{});
        ui.begin(.{ .padding = .{ .top = 8 } }, .{});
        kit.label(ui, labels.of("permgroup.", g));
        ui.end();
        for (cat, 0..) |p, i| {
            if (!eq(u8, json.str(p, "group"), g)) continue;
            const key = json.str(p, "key");
            if (canGrant(c, key)) {
                kit.check(ui, labels.of("perm.", key), s.perms.has(key), kit.act(A.role_perm, @intCast(i)));
            } else {
                // Not one of mine: shown, but it cannot be given.
                ui.begin(.{ .direction = .row, .gap = 9.6, .align_items = .start, .opacity = 0.5 }, .{});
                kit.box(ui, s.perms.has(key));
                ui.begin(.{ .grow = 1 }, .{});
                ui.text(labels.of("perm.", key), .{ .font_size = 16, .color = k.ink_2 });
                ui.text(L("team.cannot_grant"), .{ .font_size = 12, .color = k.ink_3 });
                ui.end();
                ui.end();
            }
        }
        ui.end();
    }
    shell.modalFoot(ui);
    shell.modalButton(ui, L("common.cancel"), close, .{});
    shell.modalButton(ui, L("common.save"), kit.act(A.role_save, 0), .{ .variant = .primary, .busy = @intFromEnum(A.role_save) });
    shell.modalEnd(ui, true);
}

// ---- Tests --------------------------------------------------------------------------------

const app = @import("../app.zig");
const testing = std.testing;
const dispatch = @import("dispatch.zig");

const roles_json =
    \\[{"_id":"r1","name":"Manager","permissions":["members.view","shipments.view"],"memberCount":1},
    \\ {"_id":"r2","name":"Courier","permissions":["courier.work"],"memberCount":0}]
;

test "team: members, changing a role, inviting a courier" {
    try dispatch.openCarrier("/team");
    defer app.D.reset();
    try testing.expect(app.D.respond("/roles", 200, roles_json));
    try testing.expect(app.D.respond("/members", 200,
        \\[{"id":"m1","userId":"u1","name":"Sara","email":"sara@example.com","isOwner":true,"status":"active","joinedAt":"2025-01-01T00:00:00.000Z"},
        \\ {"id":"m2","userId":"u9","name":"Omar","email":"omar@example.com","roleId":"r1","status":"active","joinedAt":"2025-02-01T00:00:00.000Z"}]
    ));
    try testing.expect(app.D.findText("Omar") != 0);
    try testing.expect(app.D.findText("You") != 0);
    // Omar becomes a courier.
    app.D.R.dispatch(.{ .text = .{ .slot = f_member_role + 1, .text = "r2" } });
    const req = zui.host.fetches.items[zui.host.fetches.items.len - 1];
    try testing.expect(std.mem.endsWith(u8, req.url, "/members/m2"));
    try testing.expect(std.mem.indexOf(u8, req.body, "\"roleId\":\"r2\"") != null);
    try testing.expect(app.D.respond("/members/m2", 200, "{}"));
    try testing.expect(app.D.pending("/members") != null);
    // Invite a courier: the courier details are sent.
    app.D.R.dispatch(kit.act(A.invite_open, 0));
    try app.D.typeInto("", "new@example.com");
    app.D.R.dispatch(.{ .open_picker = .{ .slot = f_role, .title = "", .options = &.{ .{ .value = "r1", .label = "Manager" }, .{ .value = "r2", .label = "Courier" } } } });
    app.D.R.dispatch(.{ .shell = .{ .pick = 1 } });
    try testing.expect(app.D.findText(L("team.courier_details")) != 0);
    app.D.R.dispatch(kit.act(A.invite, 0));
    const inv = zui.host.fetches.items[zui.host.fetches.items.len - 1];
    try testing.expect(std.mem.indexOf(u8, inv.body, "\"courier\":{\"vehicle\":\"motorbike\"}") != null);
    try testing.expect(app.D.respond("/invitations", 201, "{\"email\":\"new@example.com\",\"link\":\"https://turf.example/invite/abc\"}"));
    try testing.expect(app.D.findText("https://turf.example/invite/abc") != 0);
}

test "team: a new role with permissions" {
    try dispatch.openCarrier("/team?tab=roles");
    defer app.D.reset();
    try testing.expect(app.D.respond("/roles", 200, roles_json));
    try testing.expect(app.D.findText("Manager") != 0);
    try app.D.press(L("team.new_role"));
    try app.D.typeInto("", "Support");
    app.D.R.dispatch(kit.act(A.role_perm, 0));
    app.D.R.dispatch(kit.act(A.role_save, 0));
    const req = zui.host.fetches.items[zui.host.fetches.items.len - 1];
    try testing.expect(std.mem.endsWith(u8, req.url, "/roles"));
    try testing.expect(std.mem.indexOf(u8, req.body, "\"name\":\"Support\"") != null);
}
