//! The driver app's frame (Turf-js courier/chrome.js): the branded top bar with the GPS status
//! and the menu, the banners (offline with the saved positions, actions waiting to be sent,
//! session expired, location blocked), the platform announcement, the body, and the SOS button
//! with its dialog. Also the shift notification texts and the home-screen widget.
//!
//! A driver page keeps a `Chrome` in its state, forwards its events (`update` returns true when
//! it handled one) and draws `begin(...)`, its body, then `end(...)`; `overlay` draws the
//! frame's dialogs.

const std = @import("std");
const zui = @import("zui");
const core = @import("../core.zig");
const kit = @import("../kit.zig");
const shell = @import("../shell.zig");
const json = @import("../json.zig");
const icons = @import("../icons.zig");
const labels = @import("../labels.zig");
const gps = @import("../gps.zig");
const fmt = @import("../fmt.zig");
const app = @import("../app.zig");

const Cx = core.Cx;
const Ui = core.Ui;
const L = labels.k;

/// Action ids of the frame (pages use ids below 900).
pub const A = enum(u16) {
    menu = 900,
    menu_close,
    lang,
    console,
    all_companies,
    sign_out,
    sos_open,
    sos_close,
    sos_send,
    refused_close,
    back,
};

const f_sos_note: u16 = 480;

pub const Chrome = struct {
    menu: bool = false,
    sos: bool = false,
};

fn isMine(id: u16) bool {
    return id >= 900 and id <= @intFromEnum(A.back);
}

/// Handles the frame's events; true when it was one of them.
pub fn update(ch: *Chrome, c: *Cx, e: core.Ev) bool {
    switch (e) {
        .act => |a| {
            if (!isMine(a.id)) return false;
            switch (@as(A, @enumFromInt(a.id))) {
                .menu => ch.menu = !ch.menu,
                .menu_close => ch.menu = false,
                .lang => {
                    ch.menu = false;
                    const next = if (c.ar()) "en" else "ar";
                    zui.i18n.setLanguage(next);
                    zui.storage.set("lang", next, .{});
                },
                .console => if (consolePath(c)) |p| c.go(p),
                .all_companies => c.openLink("/app"),
                .sign_out => app.signOut(c),
                .sos_open => {
                    ch.sos = true;
                    c.setVal(f_sos_note, "");
                },
                .sos_close => ch.sos = false,
                .sos_send => {
                    var b = json.Obj.init(c.arena());
                    if (c.gps.current()) |f| {
                        b.begin("location");
                        b.num("lat", f.lat);
                        b.num("lng", f.lng);
                        b.end();
                    }
                    b.strOpt("note", c.valTrim(f_sos_note));
                    c.send(@intFromEnum(A.sos_send), .POST, c.orgUrl("/courier/sos"), b.done());
                },
                .refused_close => {
                    for (c.gps.refused.items) |x| core.gpa.free(x);
                    c.gps.refused.clearRetainingCapacity();
                },
                .back => c.go("/driver"),
            }
            return true;
        },
        .done => |d| {
            if (d.id != @intFromEnum(A.sos_send)) return false;
            if (d.ok) {
                ch.sos = false;
                c.toast(L("sos.sent"), .ok);
                c.fx.vibrate(200);
            }
            return true;
        },
        else => return false,
    }
}

/// The first console page this driver may open (the dashboard needs shipments or fleet).
fn consolePath(c: *const Cx) ?[]const u8 {
    const list = [_][2][]const u8{ .{ "shipments.view", "/" }, .{ "fleet.view", "/" }, .{ "dispatch.manage", "/dispatch" }, .{ "hub.scan", "/scan" }, .{ "alerts.manage", "/alerts" }, .{ "finance.view", "/finance" }, .{ "members.view", "/team" }, .{ "org.settings", "/settings" } };
    for (list) |x| if (c.can(x[0])) return x[1];
    return null;
}

/// Texts of the shift notification, in the courier's language.
pub fn shiftTitle(c: *Cx) []const u8 {
    return labels.tf(c.arena(), "shift.active_title", .{ .app = c.appName() });
}

pub fn shiftBody() []const u8 {
    return L("shift.active_body");
}

fn gpsBadge(ui: *Ui, c: *const Cx) void {
    const k = kit.k;
    const st = c.gps.status;
    const key: []const u8, const color: zui.Color = switch (st) {
        .off => .{ "gps.off", k.rail_ink_2 },
        .waiting => .{ "gps.waiting", k.r },
        .good => .{ "gps.good", k.o },
        .weak => .{ "gps.weak", k.r },
        .denied => .{ "gps.denied", k.f },
        .unavailable => .{ "gps.unavailable", k.f },
    };
    ui.begin(.{ .direction = .row, .gap = 4.8, .align_items = .center }, .{});
    kit.icon(ui, icons.navigation, 16, color);
    ui.text(L(key), .{ .font_size = 12.8, .weight = 600, .color = k.rail_ink_2, .max_lines = 1 });
    ui.end();
}

fn banner(ui: *Ui, text: []const u8, err: bool, link: ?core.Msg, link_text: []const u8) void {
    const k = kit.k;
    ui.begin(.{ .direction = .row, .justify = .center, .gap = 6, .padding = .xy(16, 10.4), .background = if (err) k.fatal_bg else k.warn_bg }, .{});
    ui.text(text, .{ .font_size = 14, .weight = 700, .color = if (err) k.fatal_ink else k.warn_ink, .text_align = .center });
    if (link) |m| kit.link(ui, link_text, m, .{ .size = 14 });
    ui.end();
}

pub const FrameOpts = struct {
    title: []const u8,
    /// A back button to the task list (task screen) instead of the logo.
    back: bool = false,
};

/// Opens the frame; draw the body, then call `end`.
pub fn begin(ui: *Ui, c: *const Cx, ch: *const Chrome, o: FrameOpts) void {
    const k = kit.k;
    const w = ui.env.width;
    ui.begin(.{ .width = .fill, .height = .fill }, .{});
    // The top bar.
    ui.begin(.{ .direction = .row, .align_items = .center, .gap = 11.2, .padding = .{ .top = 13.6, .bottom = 16, .start = 17.6, .end = 17.6 }, .background = k.rail, .radius = 28 }, .{});
    if (o.back) {
        kit.iconButton(ui, icons.arrow_back, kit.act(A.back, 0), .{ .variant = .ghost, .on_rail = true, .flip = true });
    } else kit.logoPanel(ui, c.brand(), 38, 12);
    ui.begin(.{ .grow = 1, .gap = 1 }, .{});
    ui.text(o.title, .{ .font_size = 16.8, .weight = 700, .color = k.rail_ink, .max_lines = 1 });
    gpsBadge(ui, c);
    ui.end();
    kit.iconButton(ui, if (ch.menu) icons.close else icons.menu, kit.act(A.menu, 0), .{ .variant = .ghost, .on_rail = true });
    ui.end();
    // The banners.
    const tr = &c.gps;
    if (!c.online) banner(ui, ui.tf(labels.english("driver.offline") orelse "{n}", .{ .n = tr.pending() }), false, null, "");
    if (tr.session_expired) banner(ui, L("driver.session_expired"), true, .{ .shell = .sign_out }, L("driver.sign_in_again"));
    if (tr.status == .denied) banner(ui, L("driver.gps_denied_help"), true, null, "");
    if (tr.outboxCount() > 0) banner(ui, ui.tf(labels.english("outbox.waiting") orelse "{n}", .{ .n = tr.outboxCount() }), false, null, "");
    if (json.obj(c.meta.value, "platform.announcement")) |a| {
        const text = if (c.ar()) json.strOr(a, "ar", json.str(a, "en")) else json.strOr(a, "en", json.str(a, "ar"));
        if (text.len > 0) {
            ui.begin(.{ .padding = .{ .top = 12, .start = 16, .end = 16 } }, .{});
            kit.notice(ui, if (std.mem.eql(u8, json.str(a, "level"), "warn")) .warn else .info, text);
            ui.end();
        }
    }
    // The body: one column, at most 720 wide, room at the bottom for SOS.
    kit.width = @min(w, 720) - 32;
    ui.beginScroll(.{ .grow = 1, .width = .fill, .height = .fill, .align_items = .center, .padding = .{ .top = 16, .bottom = 104 + ui.env.safe.bottom, .start = 16, .end = 16 } }, zui.key(c.pathStr()));
    ui.begin(.{ .width = .{ .px = kit.width }, .gap = 16 }, .{});
}

/// Closes the body and draws the SOS button.
pub fn end(ui: *Ui, c: *const Cx, ch: *const Chrome) void {
    _ = c;
    _ = ch;
    const k = kit.k;
    ui.end();
    ui.end();
    // SOS, fixed at the inline-end bottom corner.
    ui.begin(.{
        .position = .absolute,
        .inset = .{ .end = 16, .bottom = 16 + ui.env.safe.bottom },
        .width = .{ .px = 68 },
        .height = .{ .px = 68 },
        .radius = 34,
        .background = k.f,
        .border_width = 4,
        .border_color = k.panel,
        .align_items = .center,
        .justify = .center,
        .pressed_opacity = 0.85,
    }, .{ .on_press = kit.act(A.sos_open, 0), .key = zui.key("sos") });
    ui.text("SOS", .{ .font_size = 16, .weight = 900, .color = k.c });
    ui.end();
    ui.end();
}

/// The frame's dialogs: the menu, SOS, and actions the server refused.
pub fn overlay(ui: *Ui, c: *const Cx, ch: *const Chrome) void {
    const k = kit.k;
    if (ch.menu) {
        const phone = ui.env.width <= 900;
        if (phone) {
            // Fills the screen under the top bar; the menu button closes it.
            ui.beginScroll(.{ .position = .absolute, .inset = .{ .top = 80, .bottom = 0, .start = 0, .end = 0 }, .background = k.canvas, .padding = .all(16), .align_items = .center }, zui.key("driver-menu"));
            ui.begin(.{ .width = .{ .px = @min(ui.env.width - 32, 640) }, .gap = 8.8 }, .{});
            kit.h2(ui, L("nav.menu"));
        } else {
            shell.modalBegin(ui, .{ .title = L("nav.menu"), .close = kit.act(A.menu_close, 0), .dismissible = true, .key = zui.key("driver-menu") });
        }
        kit.button(ui, if (c.ar()) "English" else "العربية", kit.act(A.lang, 0), .{ .icon = icons.language, .block = true });
        if (consolePath(c) != null) kit.button(ui, L("driver.open_console"), kit.act(A.console, 0), .{ .icon = icons.dashboard, .block = true });
        kit.button(ui, L("nav.all_companies"), kit.act(A.all_companies, 0), .{ .icon = icons.apps, .block = true });
        kit.button(ui, L("nav.sign_out"), kit.act(A.sign_out, 0), .{ .icon = icons.logout, .block = true });
        if (phone) {
            ui.end();
            ui.end();
        } else shell.modalEnd(ui, false);
    }
    if (ch.sos) {
        shell.modalBegin(ui, .{ .title = L("sos.title"), .close = kit.act(A.sos_close, 0), .key = zui.key("sos-dialog") });
        kit.text(ui, L("sos.explain"), .{});
        kit.field(ui, L("sos.note"), f_sos_note, .{ .input = .{ .kind = .multiline, .placeholder = L("sos.note_placeholder") } });
        const phone = json.str(c.orgV(), "contact.phone");
        if (phone.len > 0) kit.button(ui, ui.tf(labels.english("sos.call_company") orelse "{phone}", .{ .phone = phone }), .{ .open = kit.f(ui, "tel:{s}", .{phone}) }, .{ .icon = icons.call, .block = true });
        shell.modalFoot(ui);
        shell.modalButton(ui, L("common.cancel"), kit.act(A.sos_close, 0), .{});
        shell.modalButton(ui, L("sos.send"), kit.act(A.sos_send, 0), .{ .variant = .danger, .busy = @intFromEnum(A.sos_send) });
        shell.modalEnd(ui, true);
    }
    if (c.gps.refused.items.len > 0) {
        shell.modalBegin(ui, .{ .title = L("outbox.refused_title"), .close = kit.act(A.refused_close, 0), .key = zui.key("refused") });
        kit.text(ui, L("outbox.refused_intro"), .{});
        for (c.gps.refused.items) |x| kit.text(ui, kit.f(ui, "\u{2022} {s}", .{x}), .{});
        shell.modalFoot(ui);
        shell.modalButton(ui, L("common.done"), kit.act(A.refused_close, 0), .{ .variant = .primary });
        shell.modalEnd(ui, true);
    }
}

/// The home-screen widget (Android): the shift and the next task.
pub fn widget(c: *Cx, on_duty: bool, next: ?json.V, open: usize) void {
    const a = c.arena();
    const title = c.appName();
    const first = if (on_duty) L("driver.on_duty") else L("driver.off_duty");
    const second = if (next) |t| std.fmt.allocPrint(a, "{s}: {s} \u{2192} {s}", .{ labels.taskType(json.str(t, "type")), json.str(t, "from.label"), json.str(t, "to.label") }) catch "" else if (on_duty) L("driver.no_tasks_on_duty") else L("driver.no_tasks_off_duty");
    const third = if (open > 1) zui.i18n.tf(a, "{n} open tasks", .{ .n = open }) else "";
    zui.widget.update(title, &.{ first, second, third });
    _ = fmt;
    _ = gps;
}
