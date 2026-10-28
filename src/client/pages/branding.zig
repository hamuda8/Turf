//! White-label branding (Turf-js views/shared/branding.js): app name, short name, the two
//! colours (typed as #rrggbb, or chosen from a palette under the swatch), a live preview, and
//! the logo. As Turf-js (core/brand.js `buildLogoSet`), a chosen logo becomes the PNG set the
//! server stores: the logo (at most 512 a side) and 192/512 home-screen icons on white or the
//! main colour (8% padding), and maskable ones (20%), drawn here with zui.png.

const std = @import("std");
const zui = @import("zui");
const core = @import("../core.zig");
const kit = @import("../kit.zig");
const json = @import("../json.zig");
const icons = @import("../icons.zig");
const labels = @import("../labels.zig");
const theme = @import("../theme.zig");

const Cx = core.Cx;
const Ui = core.Ui;
const V = json.V;
const L = labels.k;
const Color = zui.Color;

const f_app_name: u16 = 0;
const f_short_name: u16 = 1;
const f_primary: u16 = 2;
const f_accent: u16 = 3;

const A = enum(u16) { save = 1, remove_ask, remove, choose_logo, upload, bg_white, bg_brand, palette, pick_color };

/// The logo file's id (`Cx.pickPng`).
const file_logo: u16 = 1;

/// The palette under a colour's swatch (Turf-js used the browser's colour picker).
const palette = [_][]const u8{
    "#b3261e", "#d32f2f", "#c2185b", "#7b1fa2", "#512da8", "#303f9f", "#1976d2", "#0288d1", "#0097a7", "#00796b",
    "#388e3c", "#689f38", "#afb42b", "#fbc02d", "#ffa000", "#f57c00", "#e64a19", "#8a2a1c", "#5d4037", "#616161",
    "#455a64", "#263238", "#111111", "#ffffff",
};

pub const S = struct {
    /// The picked logo (PNG), and the set built from it: the request's JSON and the maskable
    /// icon for the preview (page memory).
    logo: ?[]const u8 = null,
    set: ?[]const u8 = null,
    preview: ?[]const u8 = null,
    preview_n: u32 = 0,
    /// The home-screen icons on the main colour (else white).
    bg_brand: bool = false,
    /// The colour field whose palette is open.
    palette_for: ?u16 = null,
};

pub fn title(_: *const S, _: *const Cx) []const u8 {
    return L("nav.branding");
}

fn brand(c: *const Cx) ?V {
    return json.obj(c.orgV(), "branding");
}

pub fn enter(_: *S, c: *Cx) void {
    const b = brand(c);
    c.setVal(f_app_name, json.str(b, "appName"));
    c.setVal(f_short_name, json.str(b, "shortName"));
    c.setVal(f_primary, json.str(b, "primaryColor"));
    c.setVal(f_accent, json.str(b, "accentColor"));
}

/// The preview's picture key: a new one for each set built.
fn previewKey(ui: *Ui, s: *const S) []const u8 {
    return std.fmt.allocPrint(ui.arena(), "logo-{d}", .{s.preview_n}) catch "logo";
}

fn isHex(s: []const u8) bool {
    if (s.len != 7 or s[0] != '#') return false;
    for (s[1..]) |ch| if (!std.ascii.isHex(ch)) return false;
    return true;
}

/// The typed colour when it is a full #rrggbb, else the saved one.
fn colorOf(c: *const Cx, slot: u16, saved: []const u8) ?Color {
    const typed = c.valTrim(slot);
    const text = if (isHex(typed)) typed else saved;
    return Color.parseHex(text) catch null;
}

/// The PNG set from the picked logo (Turf-js `prepare`), again when the icons' background
/// changes.
fn prepare(s: *S, c: *Cx) void {
    const bytes = s.logo orelse return;
    const main = colorOf(c, f_primary, json.str(brand(c), "primaryColor")) orelse kit.k.a;
    const bg: u32 = if (s.bg_brand) main.argb() | 0xff000000 else 0xffffffff;
    const set = buildSet(c.page_arena.allocator(), bytes, bg) catch {
        s.set = null;
        s.preview = null;
        return c.toast(core.t("This file is not an image the browser can read"), .err);
    };
    s.set = set.body;
    s.preview = set.maskable192;
    s.preview_n += 1;
}

const Set = struct { body: []const u8, maskable192: []const u8 };

fn buildSet(a: std.mem.Allocator, bytes: []const u8, bg: u32) !Set {
    const png = zui.png;
    const gpa = zui.allocator;
    const img = try png.decode(gpa, bytes);
    defer img.deinit(gpa);
    const logo = try png.fit(gpa, img, 512);
    defer logo.deinit(gpa);
    var obj = json.Obj.init(a);
    obj.str("logo", try dataUrl(a, logo));
    var m192: []const u8 = "";
    const parts = [_]struct { []const u8, u32, f32 }{
        .{ "icon192", 192, 0.08 }, .{ "icon512", 512, 0.08 }, .{ "maskable192", 192, 0.2 }, .{ "maskable512", 512, 0.2 },
    };
    for (parts) |p| {
        const sq = try png.square(gpa, img, p[1], bg, p[2]);
        defer sq.deinit(gpa);
        obj.str(p[0], try dataUrl(a, sq));
        if (std.mem.eql(u8, p[0], "maskable192")) m192 = try png.encode(a, sq);
    }
    return .{ .body = obj.done(), .maskable192 = m192 };
}

/// A picture as a PNG data: URL.
fn dataUrl(a: std.mem.Allocator, img: zui.png.Image) ![]const u8 {
    const bytes = try zui.png.encode(zui.allocator, img);
    defer zui.allocator.free(bytes);
    const enc = std.base64.standard.Encoder;
    const prefix = "data:image/png;base64,";
    const out = try a.alloc(u8, prefix.len + enc.calcSize(bytes.len));
    @memcpy(out[0..prefix.len], prefix);
    _ = enc.encode(out[prefix.len..], bytes);
    return out;
}

pub fn update(s: *S, c: *Cx, e: core.Ev) void {
    switch (e) {
        .file => |f| if (f.id == file_logo) {
            s.logo = c.page_arena.allocator().dupe(u8, f.data) catch return;
            prepare(s, c);
        },
        .act => |a| switch (@as(A, @enumFromInt(a.id))) {
            .choose_logo => c.pickPng(file_logo, 512),
            .bg_white, .bg_brand => {
                s.bg_brand = a.id == @intFromEnum(A.bg_brand);
                prepare(s, c);
            },
            .upload => if (s.set) |body| {
                c.send(a.id, .PUT, c.orgUrl("/branding/logo"), body);
            } else c.toast(L("branding.choose_file"), .err),
            .palette => s.palette_for = if (s.palette_for == @as(u16, @intCast(a.arg))) null else @intCast(a.arg),
            .pick_color => if (s.palette_for) |slot| {
                c.setVal(slot, palette[a.arg]);
                s.palette_for = null;
            },
            .save => {
                var b = json.Obj.init(c.arena());
                b.strOpt("appName", c.val(f_app_name));
                b.strOpt("shortName", c.val(f_short_name));
                b.strOpt("primaryColor", c.val(f_primary));
                b.strOpt("accentColor", c.val(f_accent));
                c.send(a.id, .PATCH, c.orgUrl("/branding"), b.done());
            },
            .remove_ask => c.ask(L("branding.remove_logo_confirm"), .{ .danger = true, .act = .{ .id = @intFromEnum(A.remove) } }),
            .remove => c.send(a.id, .DELETE, c.orgUrl("/branding/logo"), ""),
        },
        .done => |d| if (d.ok) {
            if (d.id == @intFromEnum(A.save) or d.id == @intFromEnum(A.upload)) c.toast(L("common.saved"), .ok);
            if (d.id == @intFromEnum(A.upload)) {
                s.logo = null;
                s.set = null;
                s.preview = null;
            }
            // The new colours and logo everywhere (Turf-js reloaded the page).
            @import("../app.zig").reloadOrg(c);
        },
        else => {},
    }
}

fn colorField(s: *const S, c: *const Cx, ui: *Ui, lbl: []const u8, slot: u16, name: []const u8, saved: []const u8) void {
    const k = kit.k;
    kit.fieldBegin(ui, lbl, false);
    ui.begin(.{ .direction = .row, .gap = 8, .align_items = .center }, .{});
    // The swatch opens the palette.
    ui.begin(.{ .width = .{ .px = 54 }, .height = .{ .px = 48 }, .radius = 12, .background = k.panel_3, .padding = .all(4), .pressed_opacity = 0.75 }, .{ .on_press = kit.act(A.palette, slot), .label = lbl });
    ui.begin(.{ .grow = 1, .width = .fill, .radius = 12, .background = colorOf(c, slot, saved) orelse k.panel_3 }, .{});
    ui.end();
    ui.end();
    kit.input(ui, slot, .{ .ltr = true, .placeholder = "#000000", .name = name, .max_len = 7, .grow = 1, .mono = true, .on_submit = kit.act(A.save, 0) });
    ui.end();
    if (s.palette_for == slot) {
        ui.begin(.{ .wrap = true, .gap = 8, .padding = .all(10), .radius = 12, .background = k.panel_2, .no_mirror = true }, .{});
        for (palette, 0..) |hex, i| {
            const col = Color.parseHex(hex) catch continue;
            const chosen = std.ascii.eqlIgnoreCase(c.valTrim(slot), hex);
            ui.begin(.{ .width = .{ .px = 30 }, .height = .{ .px = 30 }, .radius = 15, .background = col, .border_width = if (chosen) 3 else 1, .border_color = if (chosen) k.ink else k.line, .pressed_opacity = 0.7 }, .{ .on_press = kit.act(A.pick_color, @intCast(i)), .label = hex, .key = zui.key(i + 1) });
            ui.end();
        }
        ui.end();
        core.keys.escape = kit.act(A.palette, slot);
    }
    kit.fieldEnd(ui, name, "");
}

pub fn view(s: *const S, c: *const Cx, ui: *Ui) void {
    const k = kit.k;
    const b = brand(c);
    var g = kit.grid(ui, 2, 2);
    g.cell();
    kit.stack(ui);
    // Identity.
    kit.card(ui, .{ .gap = 16 });
    kit.h2(ui, L("branding.identity"));
    var fg = kit.formGrid(ui, 4);
    fg.cell();
    kit.field(ui, L("branding.app_name"), f_app_name, .{ .hint = L("branding.app_name_hint"), .input = .{ .name = "appName", .max_len = 40, .on_submit = kit.act(A.save, 0) } });
    fg.endCell();
    fg.cell();
    kit.field(ui, L("branding.short_name"), f_short_name, .{ .hint = L("branding.short_name_hint"), .input = .{ .name = "shortName", .max_len = 12, .on_submit = kit.act(A.save, 0) } });
    fg.endCell();
    fg.cell();
    colorField(s, c, ui, L("branding.primary"), f_primary, "primaryColor", json.str(b, "primaryColor"));
    fg.endCell();
    fg.cell();
    colorField(s, c, ui, L("branding.accent"), f_accent, "accentColor", json.str(b, "accentColor"));
    fg.endCell();
    fg.end();
    kit.rowEnd(ui);
    kit.button(ui, L("common.save"), kit.act(A.save, 0), .{ .variant = .primary, .busy = @intFromEnum(A.save) });
    ui.end();
    kit.endCard(ui, .{});
    // The logo.
    kit.card(ui, .{ .gap = 16 });
    kit.h2(ui, L("branding.logo"));
    const logo = json.str(b, "logoUrl");
    if (logo.len > 0) {
        ui.begin(.{ .width = .{ .px = 96 }, .height = .{ .px = 96 } }, .{});
        ui.image(c.asset(ui.arena(), logo), .{ .width = .{ .px = 96 }, .height = .{ .px = 96 } }, 0);
        ui.end();
    } else kit.muted(ui, L("branding.no_logo"));
    // The file, then the icons' background (Turf-js's radios).
    kit.fieldBegin(ui, L("branding.logo_file"), false);
    ui.begin(.{ .direction = .row, .gap = 10, .align_items = .center }, .{});
    kit.button(ui, L("common.choose"), kit.act(A.choose_logo, 0), .{ .size = .sm, .icon = icons.add });
    if (s.preview) |p| ui.imageBytes(p, previewKey(ui, s), .{ .width = .{ .px = 40 }, .height = .{ .px = 40 }, .radius = 20 }, 0);
    ui.end();
    kit.fieldEnd(ui, "", L("branding.logo_hint"));
    kit.fieldBegin(ui, L("branding.icon_background"), false);
    ui.begin(.{ .gap = 6.4 }, .{});
    kit.radio(ui, L("branding.bg_white"), !s.bg_brand, kit.act(A.bg_white, 0));
    kit.radio(ui, L("branding.bg_brand"), s.bg_brand, kit.act(A.bg_brand, 0));
    ui.end();
    kit.fieldEnd(ui, "", "");
    ui.begin(.{ .direction = .row, .gap = 8, .wrap = true }, .{});
    kit.button(ui, L("branding.upload_logo"), kit.act(A.upload, 0), .{ .variant = .primary, .icon = icons.photo_camera, .busy = @intFromEnum(A.upload) });
    if (logo.len > 0) kit.button(ui, L("branding.remove_logo"), kit.act(A.remove_ask, 0), .{ .variant = .ghost, .icon = icons.delete, .busy = @intFromEnum(A.remove) });
    ui.end();
    kit.endCard(ui, .{});
    ui.end();
    g.endCell();
    // The preview, as typed.
    g.cell();
    kit.card(ui, .{ .gap = 16 });
    kit.h2(ui, L("branding.preview"));
    const primary = colorOf(c, f_primary, json.str(b, "primaryColor")) orelse k.a;
    const on = theme.readableOn(primary);
    const app_name = if (c.valTrim(f_app_name).len > 0) c.valTrim(f_app_name) else json.str(b, "appName");
    const short = if (c.valTrim(f_short_name).len > 0) c.valTrim(f_short_name) else json.str(b, "shortName");
    ui.begin(.{ .direction = .row, .gap = 24, .align_items = .start }, .{});
    ui.begin(.{ .width = .{ .px = 96 }, .align_items = .center, .gap = 5.6 }, .{});
    const icon = json.str(b, "maskable192");
    ui.begin(.{ .width = .{ .px = 72 }, .height = .{ .px = 72 }, .radius = 36, .clip = true, .background = k.panel_3 }, .{});
    // The icon being prepared, else the saved one.
    if (s.preview) |p| {
        ui.imageBytes(p, previewKey(ui, s), .{ .width = .{ .px = 72 }, .height = .{ .px = 72 } }, 0);
    } else if (icon.len > 0) ui.image(c.asset(ui.arena(), icon), .{ .width = .{ .px = 72 }, .height = .{ .px = 72 } }, 0);
    ui.end();
    ui.text(short, .{ .font_size = 14, .color = k.ink, .text_align = .center, .max_lines = 1 });
    ui.end();
    ui.begin(.{ .grow = 1, .radius = 12, .clip = true, .border_width = 1, .border_color = k.line }, .{});
    ui.begin(.{ .background = primary, .padding = .xy(16, 12) }, .{});
    ui.text(app_name, .{ .font_size = 16, .weight = 700, .color = on });
    ui.end();
    ui.begin(.{ .padding = .all(16), .align_items = .start }, .{});
    ui.begin(.{ .height = .{ .px = 44 }, .padding = .xy(18.4, 0), .radius = 12, .background = primary, .justify = .center }, .{});
    ui.text(L("branding.sample_button"), .{ .font_size = 14, .weight = 700, .color = on });
    ui.end();
    ui.end();
    ui.end();
    ui.end();
    kit.small(ui, L("branding.install_hint"));
    kit.endCard(ui, .{});
    g.endCell();
    g.end();
}

// ---- Tests --------------------------------------------------------------------------------

const app = @import("../app.zig");
const testing = std.testing;
const msettings = @import("m_settings.zig");

test "branding: names and colours are saved, the preview follows" {
    try msettings.openMerchant("/branding");
    defer app.D.reset();
    try testing.expect(app.D.findText("Acme Store") != 0);
    try app.D.typeInto("#000000", "#ff0000");
    app.D.R.dispatch(kit.act(A.save, 0));
    const req = zui.host.fetches.items[zui.host.fetches.items.len - 1];
    try testing.expect(std.mem.endsWith(u8, req.url, "/branding"));
    try testing.expect(std.mem.indexOf(u8, req.body, "\"appName\":\"Acme Store\"") != null);
    try testing.expect(std.mem.indexOf(u8, req.body, "\"#ff0000\"") != null);
    try testing.expect(app.D.respond("/branding", 200, "{}"));
    try testing.expect(app.D.findText("Saved") != 0);
    try testing.expect(app.D.pending("/api/app/orgs/o1") != null);
}

test "branding: a chosen logo becomes Turf-js's PNG set and is uploaded" {
    try msettings.openMerchant("/branding");
    defer app.D.reset();
    // A 4x2 red logo with a transparent half.
    var px: [4 * 2 * 4]u8 = undefined;
    for (0..8) |i| px[i * 4 ..][0..4].* = if (i % 4 < 2) .{ 200, 0, 0, 255 } else .{ 0, 0, 0, 0 };
    const bytes = try zui.png.encode(testing.allocator, .{ .width = 4, .height = 2, .rgba = &px });
    defer testing.allocator.free(bytes);
    // Nothing chosen yet.
    try app.D.press(L("branding.upload_logo"));
    try testing.expect(app.D.findText(L("branding.choose_file")) != 0);
    try app.D.press(L("common.choose"));
    try testing.expect(zui.host.photo_asked != null);
    app.D.giveFile(.{ .data = bytes, .name = "logo.png", .mime = "image/png", .width = 4, .height = 2 });
    try app.D.press(L("branding.upload_logo"));
    const req = zui.host.fetches.items[zui.host.fetches.items.len - 1];
    try testing.expect(std.mem.endsWith(u8, req.url, "/branding/logo"));
    try testing.expectEqualStrings("PUT", req.method);
    inline for (.{ "logo", "icon192", "icon512", "maskable192", "maskable512" }) |name|
        try testing.expect(std.mem.indexOf(u8, req.body, "\"" ++ name ++ "\":\"data:image/png;base64,") != null);
    try testing.expect(app.D.respond("/branding/logo", 200, "{}"));
    try testing.expect(app.D.findText("Saved") != 0);
}
