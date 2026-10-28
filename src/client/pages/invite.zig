//! Accept an invitation link "/invite/<token>" (Turf-js views/invite.js): who invites me, as
//! what, and Accept / Decline; a link for another account says so.

const std = @import("std");
const zui = @import("zui");
const core = @import("../core.zig");
const kit = @import("../kit.zig");
const json = @import("../json.zig");
const icons = @import("../icons.zig");
const labels = @import("../labels.zig");
const landing = @import("landing.zig");

const Cx = core.Cx;
const Ui = core.Ui;
const L = labels.k;

const d_inv: u8 = 0;
const A = enum(u16) { accept = 1, decline };

pub const S = struct {};

pub fn title(_: *const S, _: *const Cx) []const u8 {
    return L("invite.title");
}

fn tokenUrl(c: *Cx, rest: []const u8) []const u8 {
    return c.appUrl(c.print("/invitations/{s}{s}", .{ core.encode(c.arena(), c.param(0)), rest }));
}

pub fn enter(_: *S, c: *Cx) void {
    c.load(d_inv, tokenUrl(c, ""));
}

pub fn update(_: *S, c: *Cx, e: core.Ev) void {
    switch (e) {
        .act => |a| switch (@as(A, @enumFromInt(a.id))) {
            .accept => c.send(@intFromEnum(A.accept), .POST, tokenUrl(c, "/accept"), ""),
            .decline => c.send(@intFromEnum(A.decline), .POST, tokenUrl(c, "/decline"), ""),
        },
        .done => |d| if (d.ok) switch (@as(A, @enumFromInt(d.id))) {
            .accept => {
                c.toast(zui.i18n.tf(c.arena(), labels.english("invite.joined") orelse "{name}", .{ .name = json.str(c.data(d_inv), "org.name") }), .ok);
                // The new company is not in the session yet: read the account again.
                c.me.reset();
                c.openLink(c.print("/o/{s}/", .{json.str(d.v, "slug")}));
            },
            .decline => {
                c.me.reset();
                c.openLink("/app");
            },
        },
        else => {},
    }
}

pub fn view(_: *const S, c: *const Cx, ui: *Ui) void {
    const k = kit.k;
    const w = @min(ui.env.width - 32, 560);
    kit.width = w;
    ui.beginScroll(.{ .width = .fill, .height = .fill, .align_items = .center, .padding = .{ .top = 32, .bottom = 32, .start = 16, .end = 16 } }, zui.key("invite"));
    ui.begin(.{ .width = .{ .px = w } }, .{});
    if (!kit.gate(ui, &.{d_inv})) {
        ui.end();
        ui.end();
        return;
    }
    const inv = c.data(d_inv);
    kit.card(ui, .{ .gap = 16, .align_items = .center });
    if (json.obj(inv, "org")) |o| kit.logo(ui, json.obj(o, "branding"), 72, 22);
    const status = json.str(inv, "status");
    if (!std.mem.eql(u8, status, "pending")) {
        center(ui, labels.of("invite.status.", status), true);
        kit.button(ui, L("nav.all_companies"), .{ .link = "/app" }, .{});
        kit.endCard(ui, .{});
        ui.end();
        ui.end();
        return;
    }
    center(ui, ui.tf(labels.english("invite.heading") orelse "{org}", .{ .org = json.str(inv, "org.name") }), true);
    center(ui, ui.tf(labels.english("invite.role") orelse "{role}", .{ .role = json.str(inv, "role") }), false);
    if (json.obj(inv, "courier")) |cr| ui.text(ui.tf(labels.english("invite.courier") orelse "{vehicle}", .{ .vehicle = labels.vehicle(json.str(cr, "vehicle")) }), .{ .font_size = 16, .color = k.ink_2, .text_align = .center });

    if (!json.boolean(inv, "emailMatches")) {
        ui.begin(.{ .width = .fill }, .{});
        kit.noticeBegin(ui, .warn, icons.warning);
        kit.text(ui, ui.tf(labels.english("invite.wrong_account") orelse "{email} {me}", .{ .email = json.str(inv, "email"), .me = json.str(c.me.value, "user.email") }), .{});
        kit.noticeEnd(ui);
        ui.end();
        kit.button(ui, L("invite.switch_account"), .{ .shell = .sign_out }, .{});
        kit.endCard(ui, .{});
        ui.end();
        ui.end();
        return;
    }

    ui.begin(.{ .direction = .row, .gap = 12, .align_items = .center, .justify = .center }, .{});
    kit.button(ui, L("invite.decline"), kit.act(A.decline, 0), .{ .variant = .ghost, .busy = @intFromEnum(A.decline) });
    kit.button(ui, L("invite.accept"), kit.act(A.accept, 0), .{ .variant = .primary, .size = .lg, .icon = icons.check, .busy = @intFromEnum(A.accept) });
    ui.end();
    ui.begin(.{ .direction = .row, .gap = 4, .align_items = .center, .justify = .center }, .{});
    kit.small(ui, L("invite.agree_terms"));
    kit.link(ui, L("legal.terms"), .{ .open = landing.serverUrl(ui, "/terms") }, .{ .size = 13.6 });
    kit.small(ui, "·");
    kit.link(ui, L("legal.privacy"), .{ .open = landing.serverUrl(ui, "/privacy") }, .{ .size = 13.6 });
    ui.end();
    kit.endCard(ui, .{});
    ui.end();
    ui.end();
}

fn center(ui: *Ui, s: []const u8, heading: bool) void {
    if (heading)
        ui.text(s, .{ .font_size = 18, .weight = 700, .color = kit.k.ink, .text_align = .center, .line_height = 1.15 })
    else
        ui.text(s, .{ .font_size = 16, .color = kit.k.ink, .text_align = .center });
}

// ---- Tests --------------------------------------------------------------------------------

const testing = std.testing;

test "invite: accept opens the company" {
    const app = @import("../app.zig");
    try app.startSignedIn("/invite/tok123");
    defer app.D.reset();
    try testing.expect(app.D.respond("/api/app/invitations/tok123", 200,
        \\{"status":"pending","org":{"name":"Fast Express","branding":{}},"role":"Driver","courier":{"vehicle":"motorbike"},"emailMatches":true,"email":"sara@example.com"}
    ));
    try testing.expect(app.D.findText("Join Fast Express") != 0);
    try testing.expect(app.D.findText("You have been invited as Driver.") != 0);
    try app.D.press("Accept");
    try testing.expect(app.D.respond("/api/app/invitations/tok123/accept", 200, "{\"slug\":\"fast\"}"));
    // The account is read again, then the company opens.
    try testing.expect(app.D.pending("/api/app/me") != null);
    try testing.expectEqualStrings("/o/fast", app.D.R.appState().baseStr());
}

test "invite: another account, or an old invitation" {
    const app = @import("../app.zig");
    try app.startSignedIn("/invite/tok123");
    defer app.D.reset();
    try testing.expect(app.D.respond("/api/app/invitations/tok123", 200,
        \\{"status":"pending","org":{"name":"Fast Express"},"role":"Driver","emailMatches":false,"email":"omar@example.com"}
    ));
    try testing.expect(app.D.findText("This invitation was sent to omar@example.com, but you are signed in as sara@example.com.") != 0);
    try testing.expect(app.D.findText("Accept") == 0);

    try app.startSignedIn("/invite/tok9");
    try testing.expect(app.D.respond("/api/app/invitations/tok9", 200, "{\"status\":\"expired\",\"org\":{\"name\":\"X\"}}"));
    try testing.expect(app.D.findText("This invitation has expired. Ask for a new one.") != 0);
}
