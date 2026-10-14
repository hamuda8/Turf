//! The app frame (Turf-js core/layout.js and the dialogs of ui.js): on wide screens a floating
//! navigation rail and a rounded workspace sheet with a top bar; on phones (<= 900 points) a
//! glass top bar, a floating bottom bar with the first four pages and "More", which opens a
//! full-screen menu. Also the dialogs, the drop-down lists, the confirmations and the toasts.

const std = @import("std");
const zui = @import("zui");
const core = @import("core.zig");
const json = @import("json.zig");
const kit = @import("kit.zig");
const icons = @import("icons.zig");
const labels = @import("labels.zig");
const pages = @import("pages.zig");
const app = @import("app.zig");

const Cx = core.Cx;
const Ui = core.Ui;
const Msg = core.Msg;
const Color = zui.Color;
const L = labels.k;
const gpa = core.gpa;

pub const NavItem = struct { path: []const u8 = "", label: []const u8 = "", icon: zui.Icon = icons.home, fill: zui.Icon = icons.home_fill, section: bool = false };

/// The pages in the menu, from the member's permissions (`carrierNav` / `merchantNav`).
pub fn navItems(c: *const Cx, a: std.mem.Allocator) []const NavItem {
    var out: std.ArrayList(NavItem) = .empty;
    const add = struct {
        fn f(list: *std.ArrayList(NavItem), al: std.mem.Allocator, on: bool, path: []const u8, key: []const u8, name: []const u8) void {
            if (on) list.append(al, .{ .path = path, .label = L(key), .icon = icons.byName(name) orelse icons.home, .fill = icons.byNameFill(name) orelse icons.home }) catch {};
        }
    }.f;
    const section = struct {
        fn f(list: *std.ArrayList(NavItem), al: std.mem.Allocator, key: []const u8) void {
            list.append(al, .{ .label = L(key), .section = true }) catch {};
        }
    }.f;
    if (c.mode == .org and c.isCarrier()) {
        add(&out, a, c.isDriver(), "/driver", "nav.driver", "navigation");
        add(&out, a, c.can("shipments.view") or c.can("fleet.view"), "/", "nav.dashboard", "dashboard");
        add(&out, a, c.can("shipments.view"), "/shipments", "nav.shipments", "package_2");
        add(&out, a, c.can("dispatch.manage"), "/dispatch", "nav.dispatch", "route");
        add(&out, a, c.can("dispatch.manage") and c.directOn(), "/requests", "nav.requests", "notifications");
        add(&out, a, c.can("fleet.view"), "/fleet", "nav.fleet", "map");
        add(&out, a, c.can("hub.scan"), "/scan", "nav.scan", "barcode_scanner");
        add(&out, a, c.can("alerts.manage"), "/alerts", "nav.alerts", "notifications");
        add(&out, a, c.can("shipments.view"), "/claims", "claims.title", "shield");
        add(&out, a, c.can("finance.view"), "/finance", "statements.title", "payments");
        add(&out, a, c.can("shipments.view") or c.can("finance.view"), "/reports", "reports.title", "bar_chart");
        add(&out, a, true, "/track", "nav.track", "search");
        section(&out, a, "nav.company");
        add(&out, a, c.can("hubs.manage"), "/hubs", "nav.hubs", "warehouse");
        add(&out, a, c.can("members.view") or c.can("members.invite") or c.can("roles.manage"), "/team", "nav.team", "group");
        add(&out, a, c.can("org.settings"), "/settings", "nav.settings", "settings");
        add(&out, a, c.can("org.branding"), "/branding", "nav.branding", "palette");
        add(&out, a, c.can("audit.view"), "/audit", "nav.audit", "history");
    } else if (c.mode == .org) {
        add(&out, a, c.can("shipments.view"), "/", "nav.dashboard", "dashboard");
        add(&out, a, c.can("shipments.view"), "/shipments", "nav.shipments", "package_2");
        add(&out, a, c.can("shipments.create"), "/shipments/new", "nav.new_shipment", "add");
        add(&out, a, c.can("shipments.create"), "/shipments/bulk", "bulk.title", "list");
        add(&out, a, c.can("finance.view"), "/finance", "statements.title", "payments");
        add(&out, a, c.can("shipments.view"), "/claims", "claims.title", "shield");
        add(&out, a, c.can("shipments.view") or c.can("finance.view"), "/reports", "reports.title", "bar_chart");
        add(&out, a, c.can("api.manage"), "/developers", "nav.developers", "code");
        add(&out, a, true, "/track", "nav.track", "search");
        section(&out, a, "nav.company");
        add(&out, a, c.can("members.view") or c.can("members.invite") or c.can("roles.manage"), "/team", "nav.team", "group");
        add(&out, a, c.can("org.settings"), "/settings", "nav.settings", "settings");
        add(&out, a, c.can("org.settings"), "/branding", "nav.branding", "palette");
        add(&out, a, c.can("audit.view"), "/audit", "nav.audit", "history");
    } else {
        add(&out, a, true, "/", "nav.my_companies", "apps");
        add(&out, a, true, "/track", "nav.track", "search");
        add(&out, a, c.directOn(), "/send", "direct.send_title", "add");
        add(&out, a, c.directOn(), "/parcels", "direct.my_parcels", "package_2");
    }
    return out.items;
}

/// The menu entry for the current page: the most specific match ("/shipments/new" over
/// "/shipments").
fn activePath(c: *const Cx, items: []const NavItem) []const u8 {
    const here = c.route();
    var best: []const u8 = "";
    var found = false;
    for (items) |it| {
        if (it.section) continue;
        const m = if (std.mem.eql(u8, it.path, "/")) std.mem.eql(u8, here, "/") else std.mem.eql(u8, here, it.path) or (std.mem.startsWith(u8, here, it.path) and here.len > it.path.len and here[it.path.len] == '/');
        if (m and (!found or it.path.len > best.len)) {
            best = it.path;
            found = true;
        }
    }
    return if (found) best else "\x00";
}

// ---- Update -------------------------------------------------------------------------------

pub fn update(c: *Cx, s: core.Shell) void {
    switch (s) {
        .menu => c.menu_open = !c.menu_open,
        .menu_close => c.menu_open = false,
        .lang => {
            c.menu_open = false;
            const next = if (c.ar()) "en" else "ar";
            zui.i18n.setLanguage(next);
            zui.storage.set("lang", next, .{});
        },
        .sign_out => app.signOut(c),
        .toast_tap, .toast_expire => |id| for (c.toasts.items, 0..) |x, i| if (x.id == id) {
            gpa.free(x.text);
            _ = c.toasts.orderedRemove(i);
            break;
        },
        .confirm_yes => if (c.confirm) |x| {
            const a = x.act;
            c.closeConfirm();
            app.pageEvent(c, .{ .act = a });
        },
        .confirm_no => c.closeConfirm(),
        .pick => |i| if (c.picker) |p| {
            c.picker = null;
            if (i < p.options.len) {
                c.setVal(p.slot, p.options[i].value);
                app.pageEvent(c, .{ .text = .{ .slot = p.slot, .text = p.options[i].value } });
            }
        },
        .pick_close => c.picker = null,
        .retry => if (c.mode == .failed) app.retryStart(c) else app.enterPage(c),
        .to_all_companies => app.openLink(c, "/app", true),
        .devices => {
            var buf: [256]u8 = undefined;
            c.external(std.fmt.bufPrint(&buf, "{s}/auth/devices", .{core.auth_base}) catch return, false);
        },
        .sos => {},
    }
}

// ---- View ---------------------------------------------------------------------------------

fn pageMod(comptime tg: pages.Id) type {
    return @field(pages.mods, @tagName(tg));
}

/// The page's title (top bar), if it has one.
fn pageTitle(c: *const Cx) []const u8 {
    return switch (c.page) {
        .none => "",
        inline else => |*s, tg| if (@hasDecl(pageMod(tg), "title")) pageMod(tg).title(s, c) else "",
    };
}

fn pageView(c: *const Cx, ui: *Ui) void {
    switch (c.page) {
        .none => {},
        inline else => |*s, tg| pageMod(tg).view(s, c, ui),
    }
}

fn pageActions(c: *const Cx, ui: *Ui) void {
    switch (c.page) {
        .none => {},
        inline else => |*s, tg| if (@hasDecl(pageMod(tg), "actions")) pageMod(tg).actions(s, c, ui),
    }
}

fn pageOverlay(c: *const Cx, ui: *Ui) void {
    switch (c.page) {
        .none => {},
        inline else => |*s, tg| if (@hasDecl(pageMod(tg), "overlay")) pageMod(tg).overlay(s, c, ui),
    }
}

fn isBare(c: *const Cx) bool {
    return switch (c.mode) {
        .account, .org => if (app.currentRoute(c)) |r| r.bare and app.allowed(c, r) else false,
        .signin, .landing, .lookup, .public_track, .invite => true,
        .starting, .failed, .not_member => false,
    };
}

fn isFull(c: *const Cx) bool {
    return if (app.currentRoute(c)) |r| r.full and app.allowed(c, r) else false;
}

/// Gutter, rail and content padding of the console on a wide screen (CSS clamp(1.1rem, 3vw, 2rem)).
fn sidePad(w: f32) f32 {
    return std.math.clamp(w * 0.03, 17.6, 32);
}

pub fn view(c: *const Cx, ui: *Ui) void {
    kit.cx = c;
    kit.k = c.colors(ui.env.dark);
    const k = kit.k;
    const w = ui.env.width;
    kit.phone = w <= 900;
    ui.setBackground(k.canvas);
    // The body's faint glows of the action and variant colours at the top (radial in the CSS).
    ui.begin(.{ .width = .fill, .height = .fill, .background = k.canvas, .gradient = zui.Gradient.linear(180, &.{ .{ .color = k.a.mix(0.10, k.canvas), .at = 0 }, .{ .color = k.canvas, .at = 0.45 } }) }, .{});

    switch (c.mode) {
        .starting => {
            kit.width = w;
            ui.begin(.{ .width = .fill, .height = .fill, .align_items = .center, .justify = .center }, .{});
            kit.spinner(ui, 26, k.ink_3);
            ui.end();
        },
        .failed => {
            kit.width = @min(w - 32, 560);
            ui.begin(.{ .width = .fill, .height = .fill, .align_items = .center, .justify = .center, .padding = .all(16) }, .{});
            ui.begin(.{ .width = .{ .px = kit.width } }, .{});
            kit.failed(ui, c.fail_text);
            ui.end();
            ui.end();
        },
        .not_member => {
            kit.width = @min(w - 32, 560);
            ui.begin(.{ .width = .fill, .height = .fill, .align_items = .center, .justify = .center, .padding = .all(16) }, .{});
            kit.emptyBegin(ui, if (c.not_member_suspended) L("org.suspended_member") else L("org.not_member"));
            kit.button(ui, L("nav.all_companies"), .{ .shell = .to_all_companies }, .{ .variant = .primary });
            kit.emptyEnd(ui);
            ui.end();
        },
        else => if (isBare(c)) {
            kit.width = @min(w, 1080);
            pageView(c, ui);
        } else console(c, ui),
    }

    pageOverlay(c, ui);
    if (c.menu_open and kit.phone and !isBare(c)) {
        ui.onBack(.{ .shell = .menu_close });
        menuPanel(c, ui);
    }
    if (c.confirm) |x| confirmDialog(ui, x);
    toasts(c, ui);
    ui.end();
}

fn console(c: *const Cx, ui: *Ui) void {
    const k = kit.k;
    const w = ui.env.width;
    const items = navItems(c, ui.arena());
    const full = isFull(c);
    if (!kit.phone) {
        ui.begin(.{ .direction = .row, .width = .fill, .height = .fill, .padding = .all(12), .gap = 12 }, .{});
        rail(c, ui, items);
        // The workspace sheet.
        ui.begin(.{ .grow = 1, .height = .fill, .radius = 28, .background = k.sheet, .shadow = kit.shadow1(), .clip = true }, .{});
        topBar(c, ui, false);
        banner(c, ui);
        const pad = sidePad(w);
        const inner = w - 24 - 264 - 12;
        kit.width = if (full) inner else @min(inner - 2 * pad, 1280);
        content(c, ui, full, pad, false);
        ui.end();
        ui.end();
        return;
    }
    // Phones: the bar on top, the page, the floating bottom bar.
    ui.begin(.{ .width = .fill, .height = .fill }, .{});
    topBar(c, ui, true);
    banner(c, ui);
    kit.width = if (full) w else w - 32;
    content(c, ui, full, 16, true);
    ui.end();
    bottomBar(c, ui, items);
}

/// The page itself, scrolling; a new page opens at the top (its own key).
fn content(c: *const Cx, ui: *Ui, full: bool, pad: f32, phone: bool) void {
    const bottom: f32 = if (phone) 68 + 32 else 32;
    var a = std.heap.ArenaAllocator.init(gpa);
    defer a.deinit();
    const key = zui.key(app.fullLink(c, a.allocator()));
    if (full) {
        ui.begin(.{ .grow = 1, .width = .fill, .height = .fill, .padding = .{ .bottom = if (phone) 68 + 12 else 0 } }, .{ .key = key });
        pageBody(c, ui);
        ui.end();
        return;
    }
    ui.beginScroll(.{ .grow = 1, .width = .fill, .height = .fill, .padding = .{ .top = 8, .bottom = bottom, .start = pad, .end = pad }, .align_items = .center }, key);
    ui.begin(.{ .width = .{ .px = kit.width } }, .{});
    pageBody(c, ui);
    ui.end();
    ui.end();
}

fn pageBody(c: *const Cx, ui: *Ui) void {
    if (c.page == .not_found or c.page == .none) {
        kit.empty(ui, if (c.no_permission) L("common.no_permission") else L("common.not_found"));
        return;
    }
    pageView(c, ui);
}

/// The platform announcement (set in Control), in the user's language.
fn banner(c: *const Cx, ui: *Ui) void {
    const a = json.obj(c.meta.value, "platform.announcement") orelse return;
    const text = if (c.ar()) json.strOr(a, "ar", json.str(a, "en")) else json.strOr(a, "en", json.str(a, "ar"));
    if (text.len == 0) return;
    ui.begin(.{ .padding = .{ .top = 12, .start = 16, .end = 16 } }, .{});
    kit.noticeBegin(ui, if (std.mem.eql(u8, json.str(a, "level"), "warn")) .warn else .info, icons.notifications);
    ui.text(text, .{ .font_size = 15, .color = kit.k.ink });
    kit.noticeEnd(ui);
    ui.end();
}

fn topBar(c: *const Cx, ui: *Ui, phone: bool) void {
    const k = kit.k;
    const w = ui.env.width;
    ui.begin(.{
        .direction = .row,
        .align_items = .center,
        .gap = 12,
        .min_height = if (phone) 64 else 76,
        .padding = if (phone) .{ .top = 12, .bottom = 8, .start = 16, .end = 16 } else .{ .top = 14.4, .bottom = 9.6, .start = sidePad(w), .end = sidePad(w) },
        .background = if (phone) k.canvas.withAlpha(0.8) else null,
    }, .{});
    if (phone) {
        ui.begin(.{}, .{ .on_press = .{ .go = "/" } });
        kit.logo(ui, c.brand(), 34, 10);
        ui.end();
    }
    ui.text(pageTitle(c), .{ .letter_spacing = if (phone) -0.7 else -0.84, .font_size = if (phone) 20 else 24, .weight = 800, .color = k.ink, .max_lines = 1, .grow = 1, .line_height = 1.15 });
    ui.begin(.{ .direction = .row, .gap = 6.4, .align_items = .center }, .{});
    pageActions(c, ui);
    ui.end();
    ui.end();
}

fn rail(c: *const Cx, ui: *Ui, items: []const NavItem) void {
    const k = kit.k;
    // The rail: the chrome colour with a glow of the action colour in its top corner (the CSS has
    // two radial glows; zui draws one linear gradient).
    ui.begin(.{ .width = .{ .px = 264 }, .height = .fill, .radius = 28, .background = k.rail, .gradient = zui.Gradient.linear(160, &.{ .{ .color = k.a.mix(0.30, k.rail), .at = 0 }, .{ .color = k.rail, .at = 0.45 } }), .shadow = kit.shadow2(), .clip = true }, .{});
    // The brand.
    ui.begin(.{ .direction = .row, .align_items = .center, .gap = 12, .padding = .{ .top = 20, .bottom = 16, .start = 19.2, .end = 19.2 }, .pressed_opacity = 0.8 }, .{ .on_press = .{ .go = "/" } });
    kit.logoPanel(ui, c.brand(), 44, 14);
    ui.begin(.{ .grow = 1, .gap = 1 }, .{});
    ui.text(c.appName(), .{ .font_size = 16.8, .weight = 700, .color = k.rail_ink, .max_lines = 1, .line_height = 1.2 });
    const sub = subtitle(c);
    if (sub.len > 0) ui.text(sub, .{ .font_size = 11.8, .color = k.rail_ink_2, .max_lines = 1 });
    ui.end();
    ui.end();
    // The pages.
    ui.beginScroll(.{ .grow = 1, .height = .fill, .padding = .xy(12.8, 6.4), .gap = 3.2 }, zui.key("rail-nav"));
    const active = activePath(c, items);
    for (items) |it| {
        if (it.section) {
            ui.begin(.{ .padding = .{ .top = 17.6, .bottom = 5.6, .start = 14.4, .end = 14.4 } }, .{});
            ui.text(it.label, .{ .font_size = 10.2, .weight = 800, .color = k.rail_ink_2, .uppercase = true, .letter_spacing = 1.43 });
            ui.end();
            continue;
        }
        navLink(c, ui, it, std.mem.eql(u8, it.path, active), .rail);
    }
    ui.end();
    // Language, all companies, devices, sign out.
    kit.line(ui, k.rail_ink.withAlpha(0.1));
    ui.begin(.{ .padding = .{ .top = 9.6, .bottom = 14.4, .start = 12.8, .end = 12.8 }, .gap = 1.6 }, .{});
    accountLinks(c, ui, .rail);
    ui.end();
    ui.end();
}

fn subtitle(c: *const Cx) []const u8 {
    if (c.mode == .org) {
        if (json.boolean(c.org.value, "me.isOwner")) return L("team.owner");
        return json.str(c.org.value, "me.role.name");
    }
    return json.str(c.me.value, "user.email");
}

const Where = enum { rail, sheet };

fn navLink(c: *const Cx, ui: *Ui, it: NavItem, active: bool, where: Where) void {
    const k = kit.k;
    const ink = if (where == .rail) (if (active) k.on_accent else k.rail_ink_2) else (if (active) k.a else k.ink);
    const bg: ?Color = if (active) (if (where == .rail) k.a else k.accent_soft) else null;
    ui.begin(.{
        .direction = .row,
        .align_items = .center,
        .gap = 12,
        .padding = .xy(14.4, 10.6),
        .radius = 14,
        .background = bg,
        // The active rail item: linear-gradient(135deg, a 92% + b, a 70%, v) and its glow.
        .gradient = if (active and where == .rail) zui.Gradient.linear(135, &.{ .{ .color = k.a.mix(0.92, k.b), .at = 0 }, .{ .color = k.a, .at = 0.7 }, .{ .color = k.v, .at = 1 } }) else null,
        .shadow = if (active and where == .rail) kit.glow() else null,
        .pressed_background = if (where == .rail) k.rail_hover else k.panel_2,
        .hover_background = if (active) null else if (where == .rail) k.rail_hover else k.panel_2,
        .transition = .{ .duration_ms = 220 },
    }, .{ .on_press = .{ .go = it.path }, .key = zui.key(it.path) });
    const filled = if (active) it.fill else it.icon;
    kit.icon(ui, filled, 22.4, ink);
    ui.text(it.label, .{ .font_size = 14.7, .weight = if (active) 700 else 600, .color = ink, .grow = 1, .max_lines = 1 });
    if (std.mem.eql(u8, it.path, "/alerts") and c.alerts_open > 0) count(ui, c.alerts_open, active and where == .rail);
    ui.end();
}

fn count(ui: *Ui, n: u32, on_accent: bool) void {
    const k = kit.k;
    var buf: [8]u8 = undefined;
    const s = if (n > 99) "99+" else std.fmt.bufPrint(&buf, "{d}", .{n}) catch "";
    ui.begin(.{ .min_width = 20.8, .padding = .xy(7.2, 0), .radius = 999, .background = if (on_accent) k.on_accent else k.f, .align_items = .center }, .{});
    ui.text(ui.arena().dupe(u8, s) catch "", .{ .font_size = 10.9, .weight = 800, .color = if (on_accent) k.a else k.c, .line_height = 1.9 });
    ui.end();
}

fn accountLinks(c: *const Cx, ui: *Ui, where: Where) void {
    const k = kit.k;
    const ink = if (where == .rail) k.rail_ink_2 else k.ink;
    const entry = struct {
        fn f(u: *Ui, lbl: []const u8, ic: zui.Icon, msg: Msg, color: Color, rail_: bool) void {
            const kk = kit.k;
            u.begin(.{ .direction = .row, .align_items = .center, .gap = 7.2, .min_height = if (rail_) 38 else 44, .padding = .xy(18.4, 6), .radius = if (rail_) 12 else 999, .pressed_background = if (rail_) kk.rail_hover else kk.panel_3 }, .{ .on_press = msg });
            kit.icon(u, ic, 20.8, color);
            u.text(lbl, .{ .font_size = if (rail_) 13.8 else 14.4, .weight = if (rail_) 600 else 700, .color = color });
            u.end();
        }
    }.f;
    entry(ui, if (c.ar()) "English" else "العربية", icons.language, .{ .shell = .lang }, ink, where == .rail);
    if (c.mode == .org) entry(ui, L("nav.all_companies"), icons.apps, .{ .shell = .to_all_companies }, ink, where == .rail);
    entry(ui, L("nav.devices"), icons.shield, .{ .shell = .devices }, ink, where == .rail);
    entry(ui, L("nav.sign_out"), icons.logout, .{ .shell = .sign_out }, ink, where == .rail);
}

fn bottomBar(c: *const Cx, ui: *Ui, items: []const NavItem) void {
    const k = kit.k;
    const active = activePath(c, items);
    ui.begin(.{
        .position = .absolute,
        .inset = .{ .start = 12, .end = 12, .bottom = 12 },
        .height = .{ .px = 68 },
        .direction = .row,
        .padding = .xy(6.4, 5.6),
        .radius = 24,
        .background = k.panel.withAlpha(0.94),
        .border_width = 1,
        .border_color = k.line_soft,
        .shadow = kit.shadow3(),
    }, .{});
    var shown: usize = 0;
    for (items) |it| {
        if (it.section or shown == 4) continue;
        shown += 1;
        const on = std.mem.eql(u8, it.path, active);
        ui.begin(.{ .width = .fill, .align_items = .center, .justify = .center, .gap = 2.4, .radius = 18, .background = if (on) k.a else null, .gradient = if (on) kit.accentGradient() else null, .shadow = if (on) kit.glow() else null, .pressed_opacity = 0.7, .transition = .{ .duration_ms = 220 } }, .{ .on_press = .{ .go = it.path }, .key = zui.key(it.path) });
        const ink = if (on) k.on_accent else k.ink_3;
        kit.icon(ui, if (on) it.fill else it.icon, 24, ink);
        ui.text(it.label, .{ .font_size = 10.2, .weight = 700, .color = ink, .max_lines = 1 });
        if (std.mem.eql(u8, it.path, "/alerts") and c.alerts_open > 0) {
            ui.begin(.{ .position = .absolute, .inset = .{ .top = 2.4, .end = 12 } }, .{});
            count(ui, c.alerts_open, false);
            ui.end();
        }
        ui.end();
    }
    // More / Close.
    ui.begin(.{ .width = .fill, .align_items = .center, .justify = .center, .gap = 2.4, .radius = 18, .pressed_opacity = 0.7 }, .{ .on_press = .{ .shell = .menu } });
    const ink = if (c.menu_open) k.ink else k.ink_3;
    kit.icon(ui, if (c.menu_open) icons.close else icons.menu, 24, ink);
    ui.text(if (c.menu_open) L("common.close") else L("nav.more"), .{ .font_size = 10.2, .weight = 700, .color = ink, .max_lines = 1 });
    ui.end();
    ui.end();
}

/// Phones: the menu fills the screen above the bottom bar; the same button closes it.
fn menuPanel(c: *const Cx, ui: *Ui) void {
    const k = kit.k;
    const items = navItems(c, ui.arena());
    const active = activePath(c, items);
    ui.beginScroll(.{
        .position = .absolute,
        .inset = .{ .top = 0, .bottom = 0, .start = 0, .end = 0 },
        .background = k.canvas,
        .padding = .{ .top = 16, .bottom = 68 + 12 + 16, .start = 16, .end = 16 },
        .align_items = .center,
    }, zui.key("menu-panel"));
    ui.begin(.{ .width = .{ .px = @min(ui.env.width - 32, 640) }, .gap = 3.2 }, .{});
    ui.begin(.{ .padding = .{ .start = 14.4, .end = 14.4, .bottom = 8 } }, .{});
    ui.text(c.appName(), .{ .font_size = 18.4, .weight = 800, .color = k.ink });
    ui.end();
    for (items) |it| {
        if (it.section) {
            sheetSection(ui, it.label);
            continue;
        }
        navLink(c, ui, it, std.mem.eql(u8, it.path, active), .sheet);
    }
    sheetSection(ui, L("nav.account"));
    accountLinks(c, ui, .sheet);
    ui.end();
    ui.end();
    // The bottom bar stays above it.
    bottomBar(c, ui, items);
}

fn sheetSection(ui: *Ui, s: []const u8) void {
    ui.begin(.{ .padding = .{ .top = 14.4, .bottom = 4.8, .start = 14.4, .end = 14.4 } }, .{});
    ui.text(s, .{ .font_size = 10.2, .weight = 800, .color = kit.k.ink_3, .uppercase = true, .letter_spacing = 1.43 });
    ui.end();
}

// ---- Dialogs ------------------------------------------------------------------------------

pub const ModalOpts = struct {
    title: []const u8,
    /// Sent by the close button (and a tap on the backdrop when `dismissible`).
    close: Msg,
    wide: bool = false,
    dismissible: bool = false,
    key: u64 = 0,
};

/// Opens a dialog (`modal()`): a scrim, the panel (a bottom sheet under 640 points), its head
/// with the close button. Draw the body, then `modalFoot` and the buttons, then `modalEnd`.
pub fn modalBegin(ui: *Ui, o: ModalOpts) void {
    const k = kit.k;
    // Back (Android's, the browser's, the iOS swipe) closes the dialog.
    ui.onBack(o.close);
    const w = ui.env.width;
    const sheet = w <= 640;
    ui.begin(.{
        .position = .absolute,
        .inset = .{ .top = 0, .bottom = 0, .start = 0, .end = 0 },
        .background = k.scrim,
        .align_items = .center,
        .justify = if (sheet) .end else .center,
        .padding = if (sheet) .{ .top = 48 } else .all(16),
    }, .{ .on_press = if (o.dismissible) o.close else null, .key = o.key +% 77 });
    const width: f32 = if (sheet) w else @min(if (o.wide) @as(f32, 820) else 560, w - 32);
    kit.width = width - 40;
    ui.begin(.{
        .width = .{ .px = width },
        .max_height = ui.env.height - (if (sheet) @as(f32, 48) else 32),
        .radius = if (sheet) 0 else 28,
        .corners = if (sheet) .{ .top_start = 26, .top_end = 26 } else null,
        .background = k.panel,
        .shadow = kit.shadow3(),
        .clip = true,
    }, .{ .on_press = .frame, .key = o.key });
    if (sheet) {
        ui.begin(.{ .align_items = .center, .padding = .{ .top = 8 } }, .{});
        ui.begin(.{ .width = .{ .px = 44 }, .height = .{ .px = 5 }, .radius = 3, .background = k.ink_4 }, .{});
        ui.end();
        ui.end();
    }
    ui.begin(.{ .direction = .row, .align_items = .center, .justify = .space_between, .gap = 8, .padding = .{ .top = if (sheet) 10 else 17.6, .bottom = 9.6, .start = 20, .end = 12 } }, .{});
    ui.text(o.title, .{ .font_size = 18.4, .weight = 800, .color = k.ink, .grow = 1 });
    kit.iconButton(ui, icons.close, o.close, .{ .variant = .ghost });
    ui.end();
    ui.beginScroll(.{ .height = .fill, .padding = .{ .top = 5.6, .bottom = 20, .start = 20, .end = 20 }, .gap = 16, .max_height = ui.env.height - 180 }, o.key +% 3);
}

/// The dialog's buttons row.
pub fn modalFoot(ui: *Ui) void {
    ui.end(); // body
    ui.begin(.{ .direction = .row, .gap = 8, .justify = .end, .padding = .{ .top = 14.4, .bottom = 14.4, .start = 20, .end = 20 }, .background = kit.k.panel_2 }, .{});
}

/// Closes the dialog; `foot` says whether `modalFoot` was used.
pub fn modalEnd(ui: *Ui, foot: bool) void {
    ui.end(); // body or foot
    ui.end(); // panel
    ui.end(); // scrim
    _ = foot;
    kit.width = @min(ui.env.width - 32, 1280);
}

/// A dialog button: on phones every button fills its share of the row.
pub fn modalButton(ui: *Ui, lbl: []const u8, msg: Msg, o: kit.ButtonOpts) void {
    var x = o;
    if (ui.env.width <= 640) x.grow = 1;
    kit.button(ui, lbl, msg, x);
}

fn confirmDialog(ui: *Ui, x: core.Confirm) void {
    modalBegin(ui, .{ .title = x.title, .close = .{ .shell = .confirm_no }, .key = zui.key("confirm") });
    ui.text(x.text, .{ .font_size = 15, .color = kit.k.ink });
    modalFoot(ui);
    modalButton(ui, L("common.cancel"), .{ .shell = .confirm_no }, .{});
    modalButton(ui, x.label, .{ .shell = .confirm_yes }, .{ .variant = if (x.danger) .danger else .primary });
    modalEnd(ui, true);
}

fn toasts(c: *const Cx, ui: *Ui) void {
    if (c.toasts.items.len == 0) return;
    const k = kit.k;
    // Above the bottom bar on phones, above the SOS button in the driver app.
    const driver = c.page == .driver or c.page == .task;
    const lift: f32 = if (driver) 88 else if (kit.phone and !isBare(c)) 68 + 24 else 16;
    ui.begin(.{ .position = .absolute, .inset = .{ .start = 16, .end = 16, .bottom = lift }, .align_items = .center, .gap = 8 }, .{});
    for (c.toasts.items) |x| {
        ui.begin(.{ .direction = .row, .align_items = .center, .gap = 8.8, .padding = .xy(18.4, 12), .radius = 999, .background = k.c, .shadow = kit.shadow3(), .max_width = @min(520, ui.env.width - 32) }, .{ .on_press = .{ .shell = .{ .toast_tap = x.id } }, .key = zui.key(x.id) });
        ui.begin(.{ .width = .{ .px = 8 }, .height = .{ .px = 8 }, .radius = 4, .background = switch (x.kind) {
            .info => k.a,
            .ok => k.o,
            .err => k.f,
        } }, .{});
        ui.end();
        ui.text(x.text, .{ .font_size = 14.4, .weight = 600, .color = k.b });
        ui.end();
    }
    ui.end();
}
