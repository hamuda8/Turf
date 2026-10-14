//! White-label branding (Turf-js views/shared/branding.js): app name, short name, the two
//! colours (typed as #rrggbb with a swatch; zui has no colour picker), a live preview, and the
//! logo. Turf-js turned an uploaded logo into a set of PNGs in the browser (canvas) and the
//! server only accepts those PNGs; zui cannot rasterize images, so uploading a logo is not
//! offered here (removing it is).

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

const A = enum(u16) { save = 1, remove_ask, remove };

pub const S = struct {};

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

pub fn update(_: *S, c: *Cx, e: core.Ev) void {
    switch (e) {
        .act => |a| switch (@as(A, @enumFromInt(a.id))) {
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
            if (d.id == @intFromEnum(A.save)) c.toast(L("common.saved"), .ok);
            // The new colours and logo everywhere (Turf-js reloaded the page).
            @import("../app.zig").reloadOrg(c);
        },
        else => {},
    }
}

fn colorField(c: *const Cx, ui: *Ui, lbl: []const u8, slot: u16, name: []const u8, saved: []const u8) void {
    kit.fieldBegin(ui, lbl, false);
    ui.begin(.{ .direction = .row, .gap = 8, .align_items = .center }, .{});
    ui.begin(.{ .width = .{ .px = 54 }, .height = .{ .px = 48 }, .radius = 16, .background = kit.k.panel_3, .padding = .all(4) }, .{});
    ui.begin(.{ .grow = 1, .width = .fill, .radius = 12, .background = colorOf(c, slot, saved) orelse kit.k.panel_3 }, .{});
    ui.end();
    ui.end();
    kit.input(ui, slot, .{ .ltr = true, .placeholder = "#000000", .name = name, .max_len = 7, .grow = 1, .mono = true, .on_submit = kit.act(A.save, 0) });
    ui.end();
    kit.fieldEnd(ui, name, "");
}

pub fn view(_: *const S, c: *const Cx, ui: *Ui) void {
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
    colorField(c, ui, L("branding.primary"), f_primary, "primaryColor", json.str(b, "primaryColor"));
    fg.endCell();
    fg.cell();
    colorField(c, ui, L("branding.accent"), f_accent, "accentColor", json.str(b, "accentColor"));
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
    kit.small(ui, L("branding.logo_hint"));
    kit.notice(ui, .info, core.t("Uploading a new logo is not available in this app yet."));
    if (logo.len > 0) {
        ui.begin(.{ .direction = .row }, .{});
        kit.button(ui, L("branding.remove_logo"), kit.act(A.remove_ask, 0), .{ .variant = .ghost, .icon = icons.delete, .busy = @intFromEnum(A.remove) });
        ui.end();
    }
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
    if (icon.len > 0) ui.image(c.asset(ui.arena(), icon), .{ .width = .{ .px = 72 }, .height = .{ .px = 72 } }, 0);
    ui.end();
    ui.text(short, .{ .font_size = 13.6, .color = k.ink, .text_align = .center, .max_lines = 1 });
    ui.end();
    ui.begin(.{ .grow = 1, .radius = 12, .clip = true, .border_width = 1, .border_color = k.line }, .{});
    ui.begin(.{ .background = primary, .padding = .xy(16, 12) }, .{});
    ui.text(app_name, .{ .font_size = 15, .weight = 700, .color = on });
    ui.end();
    ui.begin(.{ .padding = .all(16), .align_items = .start }, .{});
    ui.begin(.{ .height = .{ .px = 44 }, .padding = .xy(18.4, 0), .radius = 22, .background = primary, .justify = .center }, .{});
    ui.text(L("branding.sample_button"), .{ .font_size = 14.4, .weight = 700, .color = on });
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
