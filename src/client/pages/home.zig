//! Account home (Turf-js views/home.js): the companies I belong to, pending invitations,
//! create a company, leave a company, delete my Turf data.

const std = @import("std");
const zui = @import("zui");
const core = @import("../core.zig");
const kit = @import("../kit.zig");
const shell = @import("../shell.zig");
const json = @import("../json.zig");
const icons = @import("../icons.zig");
const labels = @import("../labels.zig");

const Cx = core.Cx;
const Ui = core.Ui;
const L = labels.k;
const V = json.V;

const d_me: u8 = 0;
const d_deletion: u8 = 1;
const f_confirm: u16 = 0;

const A = enum(u16) { accept = 1, decline, leave_ask, leave, delete_open, delete_close, delete_send, open_org, new_carrier, new_merchant, send };

pub const S = struct {
    deleting: bool = false,
    leave_index: u32 = 0,
};

pub fn title(_: *const S, _: *const Cx) []const u8 {
    return L("nav.my_companies");
}

pub fn enter(_: *S, c: *Cx) void {
    c.load(d_me, c.appUrl("/me"));
}

fn org(c: *const Cx, i: u32) ?V {
    const list = json.arr(c.data(d_me), "orgs");
    return if (i < list.len) list[i] else null;
}

fn invitation(c: *const Cx, i: u32) ?V {
    const list = json.arr(c.data(d_me), "invitations");
    return if (i < list.len) list[i] else null;
}

pub fn update(s: *S, c: *Cx, e: core.Ev) void {
    switch (e) {
        .data => |n| if (n == d_me) {
            const me = c.data(d_me) orelse return;
            syncSession(c);
            const orgs = json.arr(me, "orgs");
            const invs = json.arr(me, "invitations");
            // Brand-new users (no company, no invitation) go straight to setting one up.
            if (orgs.len == 0 and invs.len == 0 and !c.directOn()) {
                const start = c.query(c.arena(), "start");
                if (std.mem.eql(u8, start, "carrier") or std.mem.eql(u8, start, "merchant"))
                    c.replace(c.print("/new/{s}", .{start}))
                else
                    c.replace("/new");
                return;
            }
            // Someone whose only company is a carrier they drive for opens the driver app.
            if (orgs.len == 1 and json.boolean(orgs[0], "isCourier") and std.mem.eql(u8, json.str(orgs[0], "memberStatus"), "active") and invs.len == 0) {
                c.openLink(c.print("/o/{s}/", .{json.str(orgs[0], "slug")}));
            }
        },
        .act => |a| switch (@as(A, @enumFromInt(a.id))) {
            .open_org => if (org(c, a.arg)) |o| c.openLink(c.print("/o/{s}/", .{json.str(o, "slug")})),
            .accept => if (invitation(c, a.arg)) |inv| c.sendArg(@intFromEnum(A.accept), a.arg, .POST, c.appUrl(c.print("/invitations/{s}/accept", .{json.str(inv, "token")})), ""),
            .decline => if (invitation(c, a.arg)) |inv| c.sendArg(@intFromEnum(A.decline), a.arg, .POST, c.appUrl(c.print("/invitations/{s}/decline", .{json.str(inv, "token")})), ""),
            .leave_ask => if (org(c, a.arg)) |o| {
                s.leave_index = a.arg;
                c.ask(core.fill(c.arena(), L("account.leave_confirm"), objName(c, json.str(o, "name"))), .{ .danger = true, .label = L("account.leave"), .act = .{ .id = @intFromEnum(A.leave), .arg = a.arg } });
            },
            .leave => if (org(c, a.arg)) |o| c.sendArg(@intFromEnum(A.leave), a.arg, .POST, c.appUrl(c.print("/orgs/{s}/leave", .{json.str(o, "id")})), ""),
            .delete_open => {
                // A new, empty confirmation each time (JS makes a new input).
                c.setVal(f_confirm, "");
                c.send(@intFromEnum(A.delete_open), .GET, c.appUrl("/me/deletion"), "");
            },
            .delete_close => s.deleting = false,
            .delete_send => {
                var b = json.Obj.init(c.arena());
                b.str("confirm", c.valTrim(f_confirm));
                c.send(@intFromEnum(A.delete_send), .POST, c.appUrl("/me/delete"), b.done());
            },
            .new_carrier => c.go("/new/carrier"),
            .new_merchant => c.go("/new/merchant"),
            .send => c.go("/send"),
        },
        .done => |d| switch (@as(A, @enumFromInt(d.id))) {
            .accept => if (d.ok) {
                const inv = invitation(c, d.arg);
                c.toast(core.fill(c.arena(), L("invite.joined"), objName(c, json.str(inv, "org.name"))), .ok);
                // The new company is not in the session yet: read the account again (JS reloads).
                c.me.reset();
                c.openLink(c.print("/o/{s}/", .{json.str(d.v, "slug")}));
            },
            .decline => if (d.ok) c.load(d_me, c.appUrl("/me")),
            .leave => if (d.ok) {
                c.toast(core.fill(c.arena(), L("account.left"), objName(c, json.str(org(c, d.arg), "name"))), .ok);
                c.load(d_me, c.appUrl("/me"));
            },
            .delete_open => if (d.ok) {
                // Kept in a data slot so the dialog can list what has to happen first.
                const slot = &c.slots[d_deletion];
                slot.reset();
                slot.value = json.parse(slot.arena.allocator(), d.body);
                slot.state = .ok;
                s.deleting = true;
            },
            .delete_send => if (d.ok) {
                s.deleting = false;
                @import("../app.zig").signOut(c);
            },
            else => {},
        },
        else => {},
    }
}

/// The busy action of row `i` only (JS: busy() on the pressed button).
fn rowBusy(c: *const Cx, id: A, i: usize) ?u16 {
    const n = @intFromEnum(id);
    return if (c.isBusy(n) and (c.act_args.get(n) orelse 0) == i) n else null;
}

/// The session's account follows the page's (a company left or declined leaves the menu too).
fn syncSession(c: *Cx) void {
    const v = c.data(d_me) orelse return;
    if (c.me.state != .ok) return;
    const body = json.stringify(c.arena(), v);
    c.me.arena.deinit();
    c.me.arena = .init(core.gpa);
    c.me.value = json.parse(c.me.arena.allocator(), body);
}

/// `{ name }` for the message templates.
fn objName(c: *Cx, name: []const u8) ?V {
    var m: std.json.ObjectMap = .empty;
    m.put(c.arena(), "name", .{ .string = name }) catch {};
    return .{ .object = m };
}

pub fn view(_: *const S, c: *const Cx, ui: *Ui) void {
    if (!kit.gate(ui, &.{d_me})) return;
    const me = c.data(d_me);
    const k = kit.k;
    kit.stack(ui);
    ui.begin(.{ .gap = 4, .padding = .{ .bottom = 0 } }, .{});
    kit.h1(ui, ui.tf(labels.english("home.welcome") orelse "Welcome, {name}", .{ .name = json.strOr(me, "user.username", json.str(me, "user.email")) }));
    kit.muted(ui, L("home.subtitle"));
    ui.end();

    const invs = json.arr(me, "invitations");
    if (invs.len > 0) {
        kit.stackTight(ui);
        kit.h2(ui, L("home.invitations"));
        for (invs, 0..) |inv, i| {
            kit.card(ui, .{ .direction = .row, .align_items = .center, .gap = 16, .key = zui.key(i + 100) });
            kit.logo(ui, json.obj(inv, "org.branding"), 52, 18);
            ui.begin(.{ .grow = 1, .gap = 2 }, .{});
            kit.strong(ui, json.str(inv, "org.name"));
            kit.small(ui, ui.tf(labels.english("home.invited_as") orelse "{role} {by}", .{ .role = json.str(inv, "role"), .by = json.strOr(inv, "invitedBy", "—") }));
            ui.end();
            ui.begin(.{ .direction = .row, .gap = 8 }, .{});
            kit.button(ui, L("invite.decline"), kit.act(A.decline, @intCast(i)), .{ .variant = .ghost, .busy = rowBusy(c, A.decline, i) });
            kit.button(ui, L("invite.accept"), kit.act(A.accept, @intCast(i)), .{ .variant = .primary, .icon = icons.check, .busy = rowBusy(c, A.accept, i) });
            ui.end();
            kit.endCard(ui, .{});
        }
        ui.end();
    }

    // Direct shipping (when Turf has it on): send a parcel without having a company.
    if (c.directOn()) {
        kit.card(ui, .{ .direction = .row, .align_items = .center, .gap = 16, .on_press = kit.act(A.send, 0) });
        kit.iconTile(ui, icons.send, 52);
        ui.begin(.{ .grow = 1, .gap = 2 }, .{});
        kit.strong(ui, L("direct.send_title"));
        kit.small(ui, L("direct.home_hint"));
        ui.end();
        kit.iconFlip(ui, icons.arrow_forward, 20.25, k.ink_2);
        kit.endCard(ui, .{});
    }

    const orgs = json.arr(me, "orgs");
    if (orgs.len > 0) {
        kit.stackTight(ui);
        kit.h2(ui, L("nav.my_companies"));
        var g = kit.grid(ui, orgs.len, 2);
        for (orgs, 0..) |o, i| {
            g.cell();
            kit.card(ui, .{ .direction = .row, .align_items = .center, .gap = 16, .on_press = kit.act(A.open_org, @intCast(i)), .key = zui.key(json.str(o, "id")) });
            kit.logo(ui, json.obj(o, "branding"), 58, 18);
            ui.begin(.{ .grow = 1, .gap = 4 }, .{});
            kit.strong(ui, json.str(o, "name"));
            ui.begin(.{ .direction = .row, .gap = 6.4 }, .{});
            kit.badge(ui, labels.of("org.type.", json.str(o, "type")), .brand);
            kit.badge(ui, if (json.boolean(o, "isOwner")) L("team.owner") else json.strOr(o, "role", "—"), .plain);
            if (std.mem.eql(u8, json.str(o, "status"), "pending")) kit.badge(ui, L("org.status.pending"), .amber);
            if (std.mem.eql(u8, json.str(o, "status"), "suspended")) kit.badge(ui, L("org.status.suspended"), .red);
            if (std.mem.eql(u8, json.str(o, "memberStatus"), "suspended")) kit.badge(ui, L("team.status.suspended"), .red);
            ui.end();
            ui.end();
            // Members (not the owner) can leave; owners close the company from its settings.
            if (!json.boolean(o, "isOwner")) kit.button(ui, L("account.leave"), kit.act(A.leave_ask, @intCast(i)), .{ .size = .sm, .variant = .ghost, .busy = rowBusy(c, A.leave, i) });
            kit.iconFlip(ui, icons.arrow_forward, 20.25, k.ink_2);
            kit.endCard(ui, .{});
            g.endCell();
        }
        g.end();
        ui.end();
    } else kit.notice(ui, .info, L("home.no_companies"));

    kit.stackTight(ui);
    kit.h2(ui, L("home.create_title"));
    var g = kit.grid(ui, 2, 2);
    inline for (.{ .{ A.new_carrier, icons.local_shipping, "home.create_carrier", "home.create_carrier_hint" }, .{ A.new_merchant, icons.package_2, "home.create_merchant", "home.create_merchant_hint" } }) |x| {
        g.cell();
        kit.card(ui, .{ .direction = .row, .align_items = .center, .gap = 16, .on_press = kit.act(x[0], 0) });
        kit.iconTile(ui, x[1], 52);
        ui.begin(.{ .grow = 1, .gap = 2 }, .{});
        kit.strong(ui, L(x[2]));
        kit.small(ui, L(x[3]));
        ui.end();
        kit.endCard(ui, .{});
        g.endCell();
    }
    g.end();
    ui.end();

    kit.rowEnd(ui);
    kit.button(ui, L("account.delete_title"), kit.act(A.delete_open, 0), .{ .size = .sm, .variant = .ghost, .icon = icons.delete, .busy = @intFromEnum(A.delete_open) });
    ui.end();
    ui.end();
}

/// Delete my Turf data: what has to happen first, then type DELETE.
pub fn overlay(s: *const S, c: *const Cx, ui: *Ui) void {
    if (!s.deleting) return;
    const b = c.data(d_deletion);
    var blockers: std.ArrayList([]const u8) = .empty;
    const a = ui.arena();
    for (json.arr(b, "ownedCompanies")) |n| blockers.append(a, ui.tf(labels.english("account.blocker_owner") orelse "{name}", .{ .name = if (n == .string) n.string else "" })) catch {};
    if (json.boolean(b, "openTasks")) blockers.append(a, L("account.blocker_tasks")) catch {};
    if (json.boolean(b, "openParcels")) blockers.append(a, L("account.blocker_parcels")) catch {};

    shell.modalBegin(ui, .{ .title = L("account.delete_title"), .close = kit.act(A.delete_close, 0), .key = zui.key("delete-data") });
    kit.text(ui, L("account.delete_intro"), .{});
    ui.begin(.{ .gap = 4 }, .{});
    inline for (.{ "account.delete_what_1", "account.delete_what_2", "account.delete_what_3" }) |key| bullet(ui, L(key));
    ui.end();
    kit.small(ui, L("account.delete_wufour"));
    if (blockers.items.len > 0) {
        kit.noticeBegin(ui, .warn, icons.warning);
        kit.strong(ui, L("account.delete_first"));
        for (blockers.items) |x| bullet(ui, x);
        kit.noticeEnd(ui);
        shell.modalFoot(ui);
        shell.modalButton(ui, L("common.close"), kit.act(A.delete_close, 0), .{});
    } else {
        kit.field(ui, L("account.type_delete"), f_confirm, .{ .input = .{ .placeholder = "DELETE", .ltr = true, .on_submit = kit.act(A.delete_send, 0) } });
        shell.modalFoot(ui);
        shell.modalButton(ui, L("common.cancel"), kit.act(A.delete_close, 0), .{});
        shell.modalButton(ui, L("account.delete_button"), kit.act(A.delete_send, 0), .{ .variant = .danger, .busy = @intFromEnum(A.delete_send) });
    }
    shell.modalEnd(ui, true);
}

fn bullet(ui: *Ui, s: []const u8) void {
    ui.begin(.{ .direction = .row, .gap = 8, .align_items = .start }, .{});
    ui.text("\u{2022}", .{ .font_size = 16, .color = kit.k.ink_2 });
    ui.text(s, .{ .font_size = 16, .color = kit.k.ink, .grow = 1 });
    ui.end();
}

// ---- Tests --------------------------------------------------------------------------------

const testing = std.testing;

test "home: accepting an invitation reads the account again; the delete dialog starts empty" {
    const app = @import("../app.zig");
    try app.startSignedIn("/app");
    defer app.D.reset();
    try testing.expect(app.D.respond("/api/app/me", 200,
        \\{"user":{"id":"u1","email":"sara@example.com","username":"Sara"},"orgs":[],
        \\ "invitations":[{"token":"tok1","role":"Driver","invitedBy":"Omar","org":{"name":"Fast Express"}}]}
    ));
    try testing.expect(app.D.findText("Fast Express") != 0);
    try app.D.press("Accept");
    try testing.expect(app.D.respond("/api/app/invitations/tok1/accept", 200, "{\"slug\":\"fast\"}"));
    try testing.expect(app.D.pending("/api/app/me") != null);
    try testing.expectEqualStrings("/o/fast", app.D.R.appState().baseStr());

    try app.startSignedIn("/app");
    try testing.expect(app.D.respond("/api/app/me", 200, app.me_json));
    const c: *Cx = @constCast(app.D.R.appState());
    c.setVal(f_confirm, "DEL");
    try app.D.press("Delete my Turf data");
    try testing.expectEqualStrings("", c.val(f_confirm));
}
