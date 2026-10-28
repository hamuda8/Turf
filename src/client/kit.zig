//! The UI kit: Turf-js's core/ui.js and the components of app.css (pill buttons, filled
//! fields, cards, stats, badges, notices, tabs, chips, tables, timeline, key/value rows,
//! spinners), with the same sizes (1rem = 16 points), radii and colours.
//!
//! The root view sets `k` (colours), `cx` (the context) and `width` (the content width) before
//! any page draws, so components only need the `ui` builder.

const std = @import("std");
const zui = @import("zui");
const core = @import("core.zig");
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const json = @import("json.zig");
const labels = @import("labels.zig");
const fmt = @import("fmt.zig");

const Ui = core.Ui;
const Msg = core.Msg;
const Color = zui.Color;
const Style = zui.Style;
pub const Icon = zui.Icon;
const t = core.t;

/// Set by the root view each frame.
pub var k: theme.Colors = undefined;
pub var cx: *const core.Cx = undefined;
/// Width of the page's content column.
pub var width: f32 = 400;
/// The screen is a phone (the bottom bar layout, <= 900 points).
pub var phone: bool = false;
/// Set by the shell while a page draws its top-bar actions on a phone: buttons with an icon
/// draw the icon alone (the label becomes their accessible name), so the bar fits 360 points.
pub var bar_compact: bool = false;

pub const rem: f32 = 16;

// ---- Elevation (app.css --shadow-1/2/3) ----------------------------------------------------
// CSS draws two shadows with a negative spread; zui draws one, so each is the visible part:
// a soft drop tinted with --ink.

pub fn shadow1() zui.Shadow {
    return .{ .y = 8, .blur = 22, .color = k.ink.withAlpha(0.10) };
}

pub fn shadow2() zui.Shadow {
    return .{ .y = 14, .blur = 30, .color = k.ink.withAlpha(0.15) };
}

pub fn shadow3() zui.Shadow {
    return .{ .y = 24, .blur = 48, .color = k.ink.withAlpha(0.22) };
}

/// The action colour's glow under primary buttons, active chips and nav items.
pub fn glow() zui.Shadow {
    return .{ .y = 10, .blur = 22, .color = k.a.withAlpha(0.32) };
}

pub fn ar() bool {
    return cx.ar();
}

pub fn act(id: anytype, arg: u32) Msg {
    return .{ .act = .{ .id = @intFromEnum(id), .arg = arg } };
}

pub fn actId(id: anytype) u16 {
    return @intFromEnum(id);
}

// ---- Text ---------------------------------------------------------------------------------

pub const TextOpts = struct {
    size: f32 = 16,
    weight: u16 = 400,
    color: ?Color = null,
    mono: bool = false,
    lines: u16 = 0,
    @"align": @FieldType(zui.Style, "text_align") = .start,
    grow: f32 = 0,
    line_height: f32 = 1.5,
};

pub fn text(ui: *Ui, s: []const u8, o: TextOpts) void {
    ui.text(s, .{ .font_size = o.size, .weight = o.weight, .color = o.color orelse k.ink, .mono = o.mono, .max_lines = o.lines, .text_align = o.@"align", .grow = o.grow, .line_height = o.line_height });
}

/// Page heading (app scale: 26 / 700).
pub fn h1(ui: *Ui, s: []const u8) void {
    ui.text(s, .{ .font_size = 26, .weight = 700, .color = k.ink, .line_height = 1.25, .padding = .{ .bottom = 8 } });
}

/// Section heading (h2: 1.12rem / 800).
pub fn h2(ui: *Ui, s: []const u8) void {
    ui.text(s, .{ .font_size = 20, .weight = 700, .color = k.ink, .line_height = 1.3, .padding = .{ .bottom = 8 } });
}

pub fn h3(ui: *Ui, s: []const u8) void {
    ui.text(s, .{ .font_size = 16, .weight = 700, .color = k.ink, .line_height = 1.3 });
}

pub fn muted(ui: *Ui, s: []const u8) void {
    ui.text(s, .{ .font_size = 16, .color = k.ink_2, .line_height = 1.5 });
}

/// `.muted.small`.
pub fn small(ui: *Ui, s: []const u8) void {
    ui.text(s, .{ .font_size = 14, .color = k.ink_2, .line_height = 1.45 });
}

pub fn strong(ui: *Ui, s: []const u8) void {
    ui.text(s, .{ .font_size = 16, .weight = 700, .color = k.ink, .line_height = 1.5 });
}

pub fn mono(ui: *Ui, s: []const u8, o: TextOpts) void {
    var x = o;
    x.mono = true;
    text(ui, s, x);
}

/// Section labels (table heads, nav sections): small, uppercase, spaced.
pub fn label(ui: *Ui, s: []const u8) void {
    ui.text(s, .{ .font_size = 12, .weight = 500, .color = k.ink_3, .uppercase = true, .letter_spacing = 0.72 });
}

pub fn upper(ui: *Ui, s: []const u8) []const u8 {
    const out = ui.arena().dupe(u8, s) catch return s;
    for (out) |*ch| ch.* = std.ascii.toUpper(ch.*);
    return out;
}

/// A link inside text (`<a>`): the action colour, pressable.
pub fn link(ui: *Ui, s: []const u8, msg: Msg, o: TextOpts) void {
    ui.begin(.{ .pressed_opacity = 0.6, .align_self = .start }, .{ .on_press = msg });
    var x = o;
    x.color = o.color orelse k.a;
    if (x.weight == 400) x.weight = 500;
    text(ui, s, x);
    ui.end();
}

/// Text in the page's memory for this frame.
pub fn f(ui: *Ui, comptime template: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(ui.arena(), template, args) catch "";
}

/// Translates `english` and fills its `{name}` placeholders.
pub fn tf(ui: *Ui, english: []const u8, args: anytype) []const u8 {
    return ui.tf(english, args);
}

// ---- Icons --------------------------------------------------------------------------------

/// The direction icons (back, forward, logout, send, open in new) mirror in right-to-left.
pub fn icon(ui: *Ui, ic: Icon, size: f32, color: Color) void {
    ui.icon(ic, size, color, .{}, 0);
}

/// An icon that points a way (`FLIP` in icons.js: back, forward, logout, send, open in new):
/// mirrored in right-to-left languages.
pub fn iconFlip(ui: *Ui, ic: Icon, size: f32, color: Color) void {
    var x = ic;
    x.rtl_mirror = true;
    ui.icon(x, size, color, .{}, 0);
}

// ---- Buttons ------------------------------------------------------------------------------

pub const Variant = enum { normal, primary, danger, ghost };
pub const Size = enum { sm, md, lg };

pub const ButtonOpts = struct {
    variant: Variant = .normal,
    size: Size = .md,
    icon: ?Icon = null,
    /// Mirror the icon in right-to-left (back, forward, send, logout, open in new).
    flip: bool = false,
    block: bool = false,
    /// Shows a spinner and ignores presses while this action runs.
    busy: ?u16 = null,
    /// The same, for work the page tracks itself (a data load).
    working: bool = false,
    disabled: bool = false,
    key: u64 = 0,
    /// On the dark chrome (driver top bar, tracking header).
    on_rail: bool = false,
    grow: f32 = 0,
    /// What an icon-only button does (Turf-js's title): the tooltip, screen readers, and a
    /// long press on the phones.
    label: []const u8 = "",
};

pub fn button(ui: *Ui, lbl_in: []const u8, msg: ?Msg, o_in: ButtonOpts) void {
    var o = o_in;
    var lbl = lbl_in;
    if (bar_compact and o.icon != null and lbl.len > 0) {
        o.label = lbl;
        lbl = "";
    }
    const working = o.working or (if (o.busy) |id| cx.isBusy(id) else false);
    const h: f32 = switch (o.size) {
        .sm => 36,
        .md => 44,
        .lg => 56,
    };
    const icon_only = lbl.len == 0;
    const pad_x: f32 = if (icon_only) 0 else switch (o.size) {
        .sm => 13.6,
        .md => 18.4,
        .lg => 24,
    };
    const fs: f32 = switch (o.size) {
        .sm => 13,
        .md => 15,
        .lg => 16,
    };
    const bg: ?Color, const fg: Color = switch (o.variant) {
        .normal => .{ if (o.on_rail) k.rail_hover else k.panel_3, if (o.on_rail) k.rail_ink else k.ink },
        .primary => .{ k.a, k.on_accent },
        .danger => .{ k.f, k.c },
        .ghost => .{ null, if (o.on_rail) k.rail_ink else k.ink },
    };
    const off = o.disabled or working;
    ui.begin(.{
        .direction = .row,
        .align_items = .center,
        .justify = .center,
        .gap = 7.2,
        .height = .{ .px = h },
        // Buttons never shrink below their label (CSS: white-space: nowrap).
        .min_width = if (icon_only) h else estimate(lbl, fs) * 1.12 + 2 * pad_x + (if (o.icon != null) @as(f32, 28) else 0),
        .width = if (o.block) .fill else .auto,
        .grow = o.grow,
        .align_self = if (o.block) .stretch else null,
        .padding = .xy(pad_x, 0),
        .radius = 12,
        .background = bg,
        .border_width = if (o.variant == .normal and k.dark and !o.on_rail) 1 else 0,
        .border_color = k.well_line,
        .opacity = if (o.disabled) 0.5 else if (working) 0.85 else 1,
        .pressed_background = switch (o.variant) {
            .primary => k.v,
            .danger => k.fatal_ink,
            .normal, .ghost => if (o.on_rail) k.rail_hover else k.press,
        },
        .hover_background = if (off) null else switch (o.variant) {
            .primary => k.v,
            .danger => k.fatal_ink,
            .normal => if (o.on_rail) k.rail_hover else k.press,
            .ghost => if (o.on_rail) k.rail_hover else k.panel_3,
        },
        .transition = .{ .duration_ms = 220 },
    }, .{ .on_press = if (off) null else msg, .key = o.key, .label = if (icon_only) o.label else "" });
    if (working) {
        spinner(ui, if (o.size == .lg) 20 else 16, fg);
    } else {
        if (o.icon) |ic| {
            const isz: f32 = if (o.size == .sm) 18.4 else 20.8;
            if (o.flip) iconFlip(ui, ic, isz, fg) else icon(ui, ic, isz, fg);
        }
        if (!icon_only) ui.text(lbl, .{ .font_size = fs, .weight = 700, .color = fg, .max_lines = 1 });
    }
    ui.end();
}

/// An icon-only button (`.btn.icon`, with a `title` for screen readers on the web).
pub fn iconButton(ui: *Ui, ic: Icon, msg: ?Msg, o: ButtonOpts) void {
    button(ui, "", msg, blk: {
        var x = o;
        x.icon = ic;
        if (x.variant == .normal and o.on_rail) x.variant = .ghost;
        break :blk x;
    });
}

/// A turning ring (`.spin`), drawn with the frame clock.
pub fn spinner(ui: *Ui, size: f32, color: Color) void {
    // The platform turns the bright quarter (spin_ms): no frames from Zig.
    ui.begin(.{ .width = .{ .px = size }, .height = .{ .px = size } }, .{});
    const r = size / 2 - 1.25;
    var pts: [40][2]f32 = undefined;
    // The track (22% of the colour), then the moving quarter.
    for (0..40) |i| {
        const a = @as(f32, @floatFromInt(i)) / 39 * std.math.tau;
        pts[i] = .{ size / 2 + r * @cos(a), size / 2 + r * @sin(a) };
    }
    ui.path(&pts, .{ .color = color.withAlpha(color.a * 0.22), .width = 2.5 }, .{ .position = .absolute, .width = .{ .px = size }, .height = .{ .px = size } }, 0);
    var arc: [12][2]f32 = undefined;
    for (0..12) |i| {
        const a = -std.math.pi / 2.0 + @as(f32, @floatFromInt(i)) / 11 * (std.math.pi / 2.0);
        arc[i] = .{ size / 2 + r * @cos(a), size / 2 + r * @sin(a) };
    }
    ui.path(&arc, .{ .color = color, .width = 2.5 }, .{ .position = .absolute, .width = .{ .px = size }, .height = .{ .px = size }, .spin_ms = 700 }, 0);
    ui.end();
}

/// The page is loading (`loading()`): a spinner in the middle.
pub fn loading(ui: *Ui) void {
    ui.begin(.{ .align_items = .center, .padding = .all(48) }, .{});
    spinner(ui, 22, k.ink_3);
    ui.end();
}

// ---- Layout -------------------------------------------------------------------------------

/// `.stack` (column, 1rem gap) / `.stack.tight` (.55rem).
pub fn stack(ui: *Ui) void {
    ui.begin(.{ .gap = 16 }, .{});
}

pub fn stackTight(ui: *Ui) void {
    ui.begin(.{ .gap = 8.8 }, .{});
}

/// `.row` (.75rem gap, centred); it does not wrap (zui has no flex-wrap): use `rowWrap`.
pub fn row(ui: *Ui) void {
    ui.begin(.{ .direction = .row, .gap = 12, .align_items = .center }, .{});
}

pub fn rowBetween(ui: *Ui) void {
    ui.begin(.{ .direction = .row, .gap = 12, .align_items = .center, .justify = .space_between }, .{});
}

pub fn rowEnd(ui: *Ui) void {
    ui.begin(.{ .direction = .row, .gap = 12, .align_items = .center, .justify = .end }, .{});
}

pub fn spacer(ui: *Ui) void {
    ui.begin(.{ .grow = 1 }, .{});
    ui.end();
}

pub fn end(ui: *Ui) void {
    ui.end();
}

/// A grid of `count` cells, as many columns of at least `min` points as fit `avail`
/// (`grid-template-columns: repeat(auto-fit, minmax(min, 1fr))`). Open each cell with
/// `cell()` and close it with `endCell()`.
pub const Grid = struct {
    ui: *Ui,
    cols: usize,
    i: usize = 0,
    count: usize,
    gap: f32,
    /// While a cell is drawn, `width` is the room inside a card in it (form grids inside
    /// lay out by it, as CSS grids do by their container).
    cell_w: ?f32 = null,
    saved_w: f32 = 0,

    pub fn begin(ui: *Ui, count: usize, min: f32, gap: f32, avail: f32) Grid {
        // auto-fit: tracks without an item collapse, so a few items share the whole width.
        const spec: zui.Grid = .{ .min_width = @min(min, avail) };
        const cols = @min(spec.count(avail, gap), @max(count, 1));
        ui.begin(.{ .gap = gap, .grid = .{ .columns = @intCast(cols) } }, .{});
        return .{ .ui = ui, .cols = cols, .count = count, .gap = gap };
    }

    /// A fixed number of columns.
    pub fn fixed(ui: *Ui, count: usize, cols: usize, gap: f32) Grid {
        ui.begin(.{ .gap = gap, .grid = .{ .columns = @intCast(@max(cols, 1)) } }, .{});
        return .{ .ui = ui, .cols = @max(cols, 1), .count = count, .gap = gap };
    }

    pub fn cell(g: *Grid) void {
        g.ui.begin(.{}, .{});
        if (g.cell_w) |w| {
            g.saved_w = width;
            width = w;
        }
    }

    pub fn endCell(g: *Grid) void {
        g.ui.end();
        if (g.cell_w != null) width = g.saved_w;
        g.i += 1;
    }

    pub fn end(g: *Grid) void {
        g.ui.end();
    }
};

/// `.grid.cols-2` (min 280), `cols-3` (220), `cols-4` (160; two per row on phones).
pub fn grid(ui: *Ui, count: usize, comptime cols: u8) Grid {
    const min: f32 = switch (cols) {
        2 => 280,
        3 => 220,
        else => 160,
    };
    if (cols == 4 and width <= 640) return Grid.fixed(ui, count, 2, 11.2);
    var g = Grid.begin(ui, count, min, 16, width);
    // Two page columns of cards: what is inside a card has a column less its padding.
    if (cols == 2 and g.cols > 1) g.cell_w = (width - 16) / 2 - 40;
    return g;
}

// ---- Cards --------------------------------------------------------------------------------

pub const CardOpts = struct {
    pad: f32 = 20,
    gap: f32 = 0,
    on_press: ?Msg = null,
    key: u64 = 0,
    /// A card inside a card (`.card .card`).
    inner: bool = false,
    /// A coloured edge (status cards): start side, 5 points.
    edge: ?Color = null,
    /// A ring around it (chosen options, express tasks, danger zones).
    ring: ?Color = null,
    /// The ring in dashes.
    dashed: bool = false,
    background: ?Color = null,
    direction: @FieldType(zui.Style, "direction") = .column,
    align_items: @FieldType(zui.Style, "align_items") = .stretch,
};

pub fn card(ui: *Ui, o: CardOpts) void {
    const bg = o.background orelse if (o.inner) k.panel_2 else k.panel;
    ui.begin(.{
        .padding = .all(o.pad),
        .gap = o.gap,
        .radius = 18,
        .background = bg,
        // `border-inline-start: 5px solid var(--st)` (task cards), or a ring (chosen options).
        .borders = if (o.edge) |e| (if (o.ring) |r| .{ .start = .{ .width = 5, .color = e }, .end = .{ .width = 2, .color = r }, .top = .{ .width = 2, .color = r }, .bottom = .{ .width = 2, .color = r } } else .{ .start = .{ .width = 5, .color = e } }) else null,
        .border_width = if (o.ring != null) 2 else 0,
        .border_dashed = o.dashed,
        .border_color = o.ring orelse Color.transparent,
        .pressed_background = if (o.on_press != null) k.panel_3 else null,
        .hover_background = if (o.on_press != null) k.panel_2 else null,
        .transition = if (o.on_press != null) .{ .duration_ms = 220 } else null,
        .direction = o.direction,
        .align_items = o.align_items,
    }, .{ .on_press = o.on_press, .key = o.key });
}

pub fn endCard(ui: *Ui, o: CardOpts) void {
    _ = o;
    ui.end();
}

/// `.card-head`: a title with something at the end.
pub fn cardHead(ui: *Ui, title: []const u8) void {
    ui.begin(.{ .direction = .row, .align_items = .center, .justify = .space_between, .gap = 8, .padding = .{ .bottom = 13.6 } }, .{});
    ui.text(title, .{ .font_size = 20, .weight = 700, .color = k.ink, .line_height = 1.3 });
}

/// A stat tile: the accent bar, the value, the label (`stat()`).
pub fn stat(ui: *Ui, lbl: []const u8, value: []const u8, o: struct { alert: bool = false, on_press: ?Msg = null }) void {
    const compact = width <= 640;
    ui.begin(.{ .padding = if (compact) .xy(16, 14.4) else .all(20), .gap = 5.6, .radius = 18, .background = k.panel, .pressed_background = if (o.on_press != null) k.panel_3 else null, .hover_background = if (o.on_press != null) k.panel_2 else null, .height = .fill }, .{ .on_press = o.on_press });
    ui.begin(.{ .width = .{ .px = 28 }, .height = .{ .px = 8 }, .padding = .{ .bottom = 4 }, .radius = 0 }, .{});
    ui.begin(.{ .width = .{ .px = 28 }, .height = .{ .px = 4 }, .radius = 2, .background = if (o.alert) k.f else k.a }, .{});
    ui.end();
    ui.end();
    ui.text(value, .{ .font_size = if (compact) 24 else 28, .weight = 700, .line_height = 1.25, .color = if (o.alert) k.fatal_ink else k.ink });
    ui.text(lbl, .{ .font_size = 13, .weight = 500, .color = k.ink_2 });
    ui.end();
}

/// `.avatar-icon`: an icon in a soft square.
pub fn avatar(ui: *Ui, ic: Icon) void {
    ui.begin(.{ .width = .{ .px = 42 }, .height = .{ .px = 42 }, .radius = 12, .background = k.accent_soft, .align_items = .center, .justify = .center }, .{});
    icon(ui, ic, 24, k.a);
    ui.end();
}

/// A company's logo, or a tile with its first letter on the action colour (`logoBox`).
pub fn logo(ui: *Ui, brand: ?json.V, size: f32, radius: f32) void {
    // No company (the account area, sign-in): Turf's own icon, as the server's default brand.
    const url = if (brand == null) "/img/icon-192.png" else json.str(brand, "logoUrl");
    if (url.len > 0) {
        ui.begin(.{ .width = .{ .px = size }, .height = .{ .px = size }, .radius = radius, .background = k.panel, .clip = true }, .{});
        ui.image(cx.asset(ui.arena(), url), .{ .width = .{ .px = size }, .height = .{ .px = size } }, 0);
        ui.end();
        return;
    }
    const name = std.mem.trim(u8, json.strOr(brand, "appName", json.strOr(brand, "name", "T")), " ");
    ui.begin(.{ .width = .{ .px = size }, .height = .{ .px = size }, .radius = radius, .background = k.a, .align_items = .center, .justify = .center }, .{});
    ui.text(firstLetter(ui, name), .{ .font_size = size * 0.42, .weight = 700, .color = k.on_accent });
    ui.end();
}

/// The logo on the chrome (the rail, the driver and tracking headers: `.brand .logo-fallback`):
/// the letter sits on a tint of the chrome text colour there, with a soft shadow.
pub fn logoPanel(ui: *Ui, brand: ?json.V, size: f32, radius: f32) void {
    const url = if (brand == null) "/img/icon-192.png" else json.str(brand, "logoUrl");
    ui.begin(.{ .width = .{ .px = size }, .height = .{ .px = size }, .radius = radius, .background = k.rail_ink.withAlpha(0.12), .shadow = .{ .y = 6, .blur = 18, .color = k.c.withAlpha(0.35) }, .align_items = .center, .justify = .center }, .{});
    if (url.len > 0) {
        ui.image(cx.asset(ui.arena(), url), .{ .width = .{ .px = size }, .height = .{ .px = size }, .radius = radius, .fit = .contain }, 0);
    } else {
        const name = std.mem.trim(u8, json.strOr(brand, "appName", json.strOr(brand, "name", "T")), " ");
        ui.text(firstLetter(ui, name), .{ .font_size = size * 0.42, .weight = 700, .color = k.rail_ink });
    }
    ui.end();
}

/// A fallback tile with an icon (create-company cards).
pub fn iconTile(ui: *Ui, ic: Icon, size: f32) void {
    ui.begin(.{ .width = .{ .px = size }, .height = .{ .px = size }, .radius = size * 0.3, .background = k.a, .align_items = .center, .justify = .center }, .{});
    icon(ui, ic, size * 0.5, k.on_accent);
    ui.end();
}

fn firstLetter(ui: *Ui, s: []const u8) []const u8 {
    if (s.len == 0) return "T";
    const n = std.unicode.utf8ByteSequenceLength(s[0]) catch 1;
    const out = ui.arena().dupe(u8, s[0..@min(n, s.len)]) catch return "T";
    if (out.len == 1) out[0] = std.ascii.toUpper(out[0]);
    return out;
}

// ---- Badges and notices -------------------------------------------------------------------

pub const Tone = enum { plain, green, red, amber, brand };

pub fn badge(ui: *Ui, s: []const u8, tone: Tone) void {
    badgeIcon(ui, s, tone, null);
}

pub fn badgeIcon(ui: *Ui, s: []const u8, tone: Tone, ic: ?Icon) void {
    const bg: Color, const fg: Color = switch (tone) {
        .plain => .{ k.panel_3, k.ink_2 },
        .green => .{ k.ok_bg, k.ok_ink },
        .red => .{ k.fatal_bg, k.fatal_ink },
        .amber => .{ k.warn_bg, k.warn_ink },
        .brand => .{ k.accent_soft, k.a },
    };
    // The state colour marks the icon; the words stay in ink (optimal and risky are too light
    // for text on their own tints).
    ui.begin(.{ .direction = .row, .align_items = .center, .gap = 4.8, .padding = .xy(10.4, 2.4), .radius = 999, .background = bg, .align_self = .start }, .{});
    if (ic) |i| icon(ui, i, 17.6, fg);
    if (s.len > 0) ui.text(s, .{ .font_size = 12, .weight = 700, .color = if (tone == .plain or tone == .brand) fg else k.ink });
    ui.end();
}

/// A shipment or task status: a dot and the status in its colour.
pub fn statusBadge(ui: *Ui, status: []const u8) void {
    statusBadgeText(ui, status, labels.status(status));
}

pub fn statusBadgeText(ui: *Ui, status: []const u8, s: []const u8) void {
    const st = theme.status(&k, status);
    ui.begin(.{ .direction = .row, .align_items = .center, .gap = 4.8, .padding = .xy(10.4, 2.4), .radius = 999, .background = st.withAlpha(st.a * 0.14), .align_self = .start }, .{});
    ui.begin(.{ .width = .{ .px = 7 }, .height = .{ .px = 7 }, .radius = 3.5, .background = st }, .{});
    ui.end();
    ui.text(s, .{ .font_size = 12, .weight = 700, .color = k.ink });
    ui.end();
}

/// The express (same-hour) badge.
pub fn expressBadge(ui: *Ui) void {
    ui.begin(.{ .direction = .row, .align_items = .center, .gap = 4.8, .padding = .xy(10.4, 2.4), .radius = 999, .background = k.a, .align_self = .start }, .{});
    icon(ui, icons.bolt, 16, k.on_accent);
    ui.text(labels.k("express.badge"), .{ .font_size = 12, .weight = 700, .color = k.on_accent });
    ui.end();
}

pub const NoticeTone = enum { info, warn, err, ok };

/// `.notice`: an icon and a message on a tint. Close it with `endNotice` after adding more.
pub fn noticeBegin(ui: *Ui, tone: NoticeTone, ic: Icon) void {
    const bg: Color, const ic_color: Color = switch (tone) {
        .info => .{ k.accent_soft, k.a },
        .warn => .{ k.warn_bg, k.warn_ink },
        .err => .{ k.fatal_bg, k.fatal_ink },
        .ok => .{ k.ok_bg, k.ok_ink },
    };
    ui.begin(.{ .direction = .row, .gap = 9.6, .align_items = .start, .padding = .xy(16, 13.6), .radius = 12, .background = bg }, .{});
    icon(ui, ic, 20.25, ic_color);
    ui.begin(.{ .grow = 1, .gap = 6 }, .{});
}

pub fn noticeEnd(ui: *Ui) void {
    ui.end();
    ui.end();
}

pub fn notice(ui: *Ui, tone: NoticeTone, s: []const u8) void {
    noticeBegin(ui, tone, switch (tone) {
        .info => icons.info,
        .warn, .err => icons.warning,
        .ok => icons.check,
    });
    ui.text(s, .{ .font_size = 16, .color = k.ink, .line_height = 1.5 });
    noticeEnd(ui);
}

/// `empty(message, action)`: a muted icon and text. Close with `endEmpty` after an action.
pub fn emptyBegin(ui: *Ui, s: []const u8) void {
    ui.begin(.{ .align_items = .center, .padding = .xy(16, 48), .gap = 13.6 }, .{});
    ui.begin(.{ .width = .{ .px = 64 }, .height = .{ .px = 64 }, .radius = 20, .background = k.accent_soft, .align_items = .center, .justify = .center }, .{});
    icon(ui, icons.package_2, 32, k.a);
    ui.end();
    ui.text(s, .{ .font_size = 16, .color = k.ink_2, .text_align = .center, .line_height = 1.5 });
}

pub fn emptyEnd(ui: *Ui) void {
    ui.end();
}

pub fn empty(ui: *Ui, s: []const u8) void {
    emptyBegin(ui, s);
    emptyEnd(ui);
}

/// A failed load: the error and Try again (re-enters the page).
pub fn failed(ui: *Ui, s: []const u8) void {
    noticeBegin(ui, .err, icons.warning);
    ui.text(s, .{ .font_size = 16, .color = k.fatal_ink, .line_height = 1.5 });
    button(ui, labels.k("common.retry"), .{ .shell = .retry }, .{ .icon = icons.refresh });
    noticeEnd(ui);
}

/// Shows the loading spinner or the error of the page's first data slots; true when the
/// caller can draw the page.
pub fn gate(ui: *Ui, slots: []const u8) bool {
    for (slots) |n| {
        const s = cx.slot(n);
        switch (s.state) {
            .ok => {},
            .failed => {
                failed(ui, s.err);
                return false;
            },
            .idle, .loading => {
                loading(ui);
                return false;
            },
        }
    }
    return true;
}

// ---- Tabs and chips -----------------------------------------------------------------------

pub fn tabsBegin(ui: *Ui) void {
    // Phones: the tabs wrap onto more lines instead of scrolling sideways (a bar that does not
    // fit 360 points wraps; nothing is clipped).
    if (phone)
        ui.begin(.{ .direction = .row, .wrap = true, .align_self = .start, .max_width = width, .radius = 18, .background = k.panel_3, .padding = .all(4), .gap = 3.2, .line_gap = 3.2, .border_width = if (k.dark) 1 else 0, .border_color = k.well_line }, .{ .key = zui.key("tabs") })
    else
        ui.beginScroll(.{ .direction = .row, .align_self = .start, .max_width = width, .radius = 18, .background = k.panel_3, .padding = .all(4), .gap = 3.2, .border_width = if (k.dark) 1 else 0, .border_color = k.well_line }, zui.key("tabs"));
}

pub fn tab(ui: *Ui, s: []const u8, active: bool, msg: Msg) void {
    ui.begin(.{ .padding = .xy(16, 8), .radius = 12, .background = if (active) k.sheet else null, .pressed_opacity = 0.7, .hover_opacity = if (active) null else 0.8, .transition = .{ .duration_ms = 220 } }, .{ .on_press = msg });
    ui.text(s, .{ .font_size = 14, .weight = 700, .color = if (active) k.ink else k.ink_2, .max_lines = 1 });
    ui.end();
}

pub fn tabsEnd(ui: *Ui) void {
    ui.end();
    // `.tabs { margin-block-end: 1rem }`: one more gap before what follows.
    ui.begin(.{}, .{});
    ui.end();
}

pub fn chip(ui: *Ui, s: []const u8, active: bool, msg: Msg) void {
    chipIcon(ui, s, active, msg, null);
}

pub fn chipIcon(ui: *Ui, s: []const u8, active: bool, msg: Msg, ic: ?Icon) void {
    ui.begin(.{ .direction = .row, .align_items = .center, .gap = 3.2, .padding = .xy(15.2, 7.2), .radius = 999, .background = if (active) k.a else k.panel_3, .pressed_background = if (active) k.v else k.press, .hover_background = if (active) null else k.press, .border_width = if (k.dark and !active) 1 else 0, .border_color = k.well_line, .transition = .{ .duration_ms = 220 } }, .{ .on_press = msg });
    if (ic) |i| icon(ui, i, 16, if (active) k.on_accent else k.ink);
    ui.text(s, .{ .font_size = 13, .weight = 500, .color = if (active) k.on_accent else k.ink, .max_lines = 1 });
    ui.end();
}

/// Items that flow onto more lines (`.row` with flex-wrap, `.chips`): zui wraps them itself.
/// `item` is kept for the callers that still size their items; it does nothing.
pub const Wrap = struct {
    ui: *Ui,

    pub fn begin(ui: *Ui, avail: f32, gap: f32) Wrap {
        _ = avail;
        ui.begin(.{ .direction = .row, .wrap = true, .gap = gap, .align_items = .center }, .{});
        return .{ .ui = ui };
    }

    pub fn item(w: *Wrap, est: f32) void {
        _ = w;
        _ = est;
    }

    pub fn end(w: *Wrap) void {
        w.ui.end();
    }
};

/// A rough width of a label in points (wrap decisions only).
pub fn estimate(s: []const u8, size: f32) f32 {
    const n: f32 = @floatFromInt(std.unicode.utf8CountCodepoints(s) catch s.len);
    return n * size * 0.56;
}

// ---- Form fields --------------------------------------------------------------------------

pub const InputKind = enum { text, number, decimal, signed, password, search, email, phone, multiline, code };

pub const InputOpts = struct {
    kind: InputKind = .text,
    placeholder: []const u8 = "",
    /// Left to right whatever the language (phone numbers, codes, addresses on the web).
    ltr: bool = false,
    mono: bool = false,
    on_submit: ?Msg = null,
    /// The server's field path, to show its validation error.
    name: []const u8 = "",
    grow: f32 = 0,
    width: ?f32 = null,
    size: f32 = 15.2,
    height: f32 = 48,
    @"align": @FieldType(zui.Style, "text_align") = .start,
    weight: u16 = 400,
    disabled: bool = false,
    /// On the dark chrome or on a card of its own colour.
    background: ?Color = null,
    /// No box of its own (the lookup bar draws it).
    bare: bool = false,
    /// At most this many characters (Turf-js maxlength); 0: no limit.
    max_len: u32 = 0,
};

/// A text field bound to form slot `slot` (`c.val(slot)`).
pub fn input(ui: *Ui, slot: u16, o: InputOpts) void {
    const value = cx.val(slot);
    const focused = cx.focused == slot;
    const has_err = o.name.len > 0 and cx.fieldError(o.name) != null;
    const h: f32 = if (o.kind == .multiline) @max(o.height, 96) else o.height;
    ui.begin(.{
        .direction = .row,
        .align_items = if (o.kind == .multiline) .start else .center,
        .height = .{ .px = h },
        .width = if (o.width) |w| .{ .px = w } else .fill,
        .grow = o.grow,
        .padding = .{ .start = 16, .end = 16, .top = if (o.kind == .multiline) 10 else 0 },
        .radius = 12,
        .background = if (o.bare) null else o.background orelse if (has_err) k.f.withAlpha(0.07) else if (focused) k.panel else k.panel_3,
        .border_width = if (o.bare) 0 else 1,
        .border_color = if (has_err) k.f else if (focused) k.a.withAlpha(0.55) else k.well_line,
        // --focus-ring: 4px of the action colour at 28%.
        .shadow = if (o.bare) null else if (focused and !has_err) .{ .y = 0, .blur = 6, .color = k.a.withAlpha(0.28) } else null,
        .hover_background = if (o.bare or focused or has_err or o.background != null) null else k.s.withAlpha(0.36),
        .transition = .{ .duration_ms = 220 },
        .opacity = if (o.disabled) 0.6 else 1,
        .no_mirror = o.ltr,
    }, .{ .key = zui.key(slot) +% 7 });
    ui.input(.{
        .key = slotKey(slot),
        .value = value,
        .placeholder = o.placeholder,
        .secure = o.kind == .password,
        .keyboard = switch (o.kind) {
            .number => .number,
            .decimal, .signed => .decimal,
            .email => .email,
            .phone => .phone,
            else => .text,
        },
        .return_key = if (o.kind == .search) .search else if (o.on_submit != null) .go else .default,
        .multiline = o.kind == .multiline,
        .max_length = o.max_len,
        .on_change = if (o.disabled) null else changer(slot, o.kind),
        .on_focus = .{ .focus = slot },
        .on_blur = .{ .blur = slot },
        .on_submit = o.on_submit,
        .style = .{
            .grow = 1,
            .height = .{ .px = if (o.kind == .multiline) h - 20 else h - 2 },
            .font_size = o.size,
            .weight = o.weight,
            .color = k.ink,
            .mono = o.mono or o.kind == .code,
            .text_align = if (o.ltr and ar()) .end else o.@"align",
        },
    });
    ui.end();
}

/// The input key of a slot (for `fx.focus`).
pub fn slotKey(slot: u16) u64 {
    return zui.key(@as(u32, slot) + 50_000);
}

/// `field(label, control, { hint, required })`: the label, the control (drawn by the caller
/// between `fieldBegin` and `fieldEnd`), the hint and the server's error for `name`.
pub fn fieldBegin(ui: *Ui, lbl: []const u8, required: bool) void {
    ui.begin(.{ .gap = 6.4 }, .{});
    if (lbl.len > 0) {
        ui.begin(.{ .direction = .row, .gap = 3.2, .align_items = .center }, .{});
        ui.text(lbl, .{ .font_size = 13, .weight = 700, .color = k.ink_2 });
        if (required) ui.text("*", .{ .font_size = 13, .weight = 700, .color = k.fatal_ink });
        ui.end();
    }
}

pub fn fieldEnd(ui: *Ui, name: []const u8, hint: []const u8) void {
    if (hint.len > 0) ui.text(hint, .{ .font_size = 12, .color = k.ink_3, .line_height = 1.4 });
    if (cx.fieldError(name)) |e| ui.text(e, .{ .font_size = 13, .weight = 500, .color = k.fatal_ink });
    ui.end();
}

pub const FieldOpts = struct {
    required: bool = false,
    hint: []const u8 = "",
    input: InputOpts = .{},
};

/// A labelled text field.
pub fn field(ui: *Ui, lbl: []const u8, slot: u16, o: FieldOpts) void {
    fieldBegin(ui, lbl, o.required);
    input(ui, slot, o.input);
    fieldEnd(ui, o.input.name, o.hint);
}

/// A drop-down (`select`): shows the chosen option's label, opens a list to choose from.
pub fn select(ui: *Ui, slot: u16, options: []const core.Opt, o: struct { placeholder: []const u8 = "", title: []const u8 = "", name: []const u8 = "", width: ?f32 = null, grow: f32 = 0 }) void {
    const value = cx.val(slot);
    var shown: []const u8 = o.placeholder;
    var chosen = false;
    for (options) |opt| if (std.mem.eql(u8, opt.value, value)) {
        shown = opt.label;
        chosen = true;
    };
    const has_err = o.name.len > 0 and cx.fieldError(o.name) != null;
    // The options travel in the message (this frame's memory); the core copies them.
    const opts = ui.arena().dupe(core.Opt, options) catch options;
    ui.begin(.{
        .direction = .row,
        .align_items = .center,
        .gap = 8,
        .height = .{ .px = 48 },
        .width = if (o.width) |w| .{ .px = w } else .fill,
        .grow = o.grow,
        .padding = .xy(16, 0),
        .radius = 12,
        .background = if (has_err) k.f.withAlpha(0.07) else k.panel_3,
        .border_width = 1,
        .border_color = if (has_err) k.f else k.well_line,
        .pressed_background = k.press,
    }, .{ .on_press = .{ .open_picker = .{ .slot = slot, .title = if (o.title.len > 0) o.title else o.placeholder, .options = opts } } });
    ui.text(shown, .{ .font_size = 16, .color = if (chosen) k.ink else k.ink_3, .max_lines = 1, .grow = 1 });
    icon(ui, icons.expand_more, 20, k.ink_3);
    ui.end();
}

/// A day ("YYYY-MM-DD" in the slot) or a time ("HH:MM") chosen with the platform's picker;
/// `min`/`max` bound the days.
pub fn dateField(ui: *Ui, lbl: []const u8, slot: u16, o: struct { time: bool = false, min: []const u8 = "", max: []const u8 = "", required: bool = false, placeholder: []const u8 = "", name: []const u8 = "", hint: []const u8 = "" }) void {
    fieldBegin(ui, lbl, o.required);
    const value = cx.val(slot);
    const has_err = o.name.len > 0 and cx.fieldError(o.name) != null;
    ui.begin(.{
        .direction = .row,
        .align_items = .center,
        .gap = 8,
        .height = .{ .px = 48 },
        .width = .fill,
        .padding = .xy(16, 0),
        .radius = 12,
        .background = if (has_err) k.f.withAlpha(0.07) else k.panel_3,
        .border_width = 1,
        .border_color = if (has_err) k.f else k.well_line,
        .pressed_background = k.press,
    }, .{ .on_press = .{ .open_date = .{ .slot = slot, .time = o.time, .min = ui.arena().dupe(u8, o.min) catch "", .max = ui.arena().dupe(u8, o.max) catch "" } } });
    const shown = if (value.len == 0) o.placeholder else if (o.time) value else fmt.date(ui.arena(), value);
    ui.text(shown, .{ .font_size = 16, .color = if (value.len > 0) k.ink else k.ink_3, .max_lines = 1, .grow = 1 });
    icon(ui, if (o.time) icons.schedule else icons.calendar_today, 20, k.ink_3);
    ui.end();
    fieldEnd(ui, o.name, o.hint);
}

pub fn selectField(ui: *Ui, lbl: []const u8, slot: u16, options: []const core.Opt, o: struct { required: bool = false, placeholder: []const u8 = "", name: []const u8 = "", hint: []const u8 = "" }) void {
    fieldBegin(ui, lbl, o.required);
    select(ui, slot, options, .{ .placeholder = if (o.placeholder.len > 0) o.placeholder else labels.k("common.choose"), .title = lbl, .name = o.name });
    fieldEnd(ui, o.name, o.hint);
}

/// A check box with its label (`.check`).
pub fn check(ui: *Ui, lbl: []const u8, checked: bool, msg: Msg) void {
    ui.begin(.{ .direction = .row, .gap = 9.6, .align_items = .start, .pressed_opacity = 0.75 }, .{ .on_press = msg });
    box(ui, checked);
    ui.text(lbl, .{ .font_size = 16, .color = k.ink });
    ui.end();
}

/// Just the box.
pub fn box(ui: *Ui, checked: bool) void {
    ui.begin(.{ .width = .{ .px = 20 }, .height = .{ .px = 20 }, .radius = 5, .background = if (checked) k.a else k.panel, .border_width = if (checked) 0 else 1.5, .border_color = k.ink_3, .align_items = .center, .justify = .center }, .{});
    if (checked) icon(ui, icons.check, 16, k.on_accent);
    ui.end();
}

/// A radio button with its label (`label.check` with a radio).
pub fn radio(ui: *Ui, lbl: []const u8, chosen: bool, msg: Msg) void {
    ui.begin(.{ .direction = .row, .gap = 9.6, .align_items = .center, .pressed_opacity = 0.75 }, .{ .on_press = msg });
    ui.begin(.{ .width = .{ .px = 20 }, .height = .{ .px = 20 }, .radius = 10, .background = k.panel, .border_width = if (chosen) 2 else 1.5, .border_color = if (chosen) k.a else k.ink_3, .align_items = .center, .justify = .center }, .{});
    if (chosen) {
        ui.begin(.{ .width = .{ .px = 10 }, .height = .{ .px = 10 }, .radius = 5, .background = k.a }, .{});
        ui.end();
    }
    ui.end();
    ui.text(lbl, .{ .font_size = 16, .color = k.ink });
    ui.end();
}

/// A radio choice card (`.service-option`).
pub fn option(ui: *Ui, ic: Icon, title: []const u8, sub: []const u8, chosen: bool, msg: Msg) void {
    ui.begin(.{ .direction = .row, .gap = 12, .align_items = .center, .padding = .xy(16, 14.4), .radius = 12, .background = if (chosen) k.panel else k.panel_2, .border_width = if (chosen) 2 else 1, .border_color = if (chosen) k.a else k.line_soft, .pressed_background = k.press, .hover_background = if (chosen) null else k.s.withAlpha(0.30), .grow = 1 }, .{ .on_press = msg });
    ui.begin(.{ .width = .{ .px = 42 }, .height = .{ .px = 42 }, .radius = 12, .background = if (chosen) k.a else k.panel_3, .align_items = .center, .justify = .center }, .{});
    icon(ui, ic, 23.2, if (chosen) k.on_accent else k.ink_2);
    ui.end();
    ui.begin(.{ .grow = 1, .gap = 2.4 }, .{});
    ui.text(title, .{ .font_size = 16, .weight = 700, .color = k.ink });
    if (sub.len > 0) ui.text(sub, .{ .font_size = 13, .color = k.ink_3 });
    ui.end();
    ui.end();
}

// ---- Typing -------------------------------------------------------------------------------

/// One `on_change` function per form slot and input kind (zui calls them without context).
const max_form_slots = 512;
const kinds = std.enums.values(InputKind);

fn makeChangers(comptime kind: InputKind) [max_form_slots]*const fn ([]const u8) Msg {
    @setEvalBranchQuota(200_000);
    var out: [max_form_slots]*const fn ([]const u8) Msg = undefined;
    for (0..max_form_slots) |i| {
        out[i] = struct {
            fn f(s: []const u8) Msg {
                return .{ .text = .{ .slot = @intCast(i | (@as(usize, @intFromEnum(kind)) << 12)), .text = s } };
            }
        }.f;
    }
    return out;
}

const changers = blk: {
    var all: [kinds.len][max_form_slots]*const fn ([]const u8) Msg = undefined;
    for (kinds, 0..) |kind, i| all[i] = makeChangers(kind);
    break :blk all;
};

fn changer(slot: u16, kind: InputKind) *const fn ([]const u8) Msg {
    return changers[@intFromEnum(kind)][slot % max_form_slots];
}

/// The slot and kind packed in a text message.
pub fn textSlot(packed_slot: u16) u16 {
    return packed_slot & 0xfff;
}

pub fn textKind(packed_slot: u16) InputKind {
    return @enumFromInt(packed_slot >> 12);
}

// ---- Tables -------------------------------------------------------------------------------

/// `.table.responsive`: a header and rows of cells on wide screens; on phones (<= 700) each
/// row is a stacked card with "Label: value" lines.
pub const Table = struct {
    ui: *Ui,
    cols: []const Col,
    stacked: bool,
    cell_i: usize = 0,
    rows: usize = 0,

    pub const Col = struct { label: []const u8 = "", grow: f32 = 1, width: ?f32 = null };

    pub fn begin(ui: *Ui, cols: []const Col) Table {
        const stacked = width <= 700;
        ui.begin(.{ .radius = 22, .background = k.panel, .shadow = shadow1() }, .{});
        if (!stacked) {
            ui.begin(.{ .direction = .row, .padding = .xy(0, 0), .align_items = .center }, .{});
            for (cols) |c| {
                ui.begin(.{ .width = if (c.width) |w| .{ .px = w } else .fill, .grow = if (c.width == null) c.grow else 0, .padding = .xy(15.2, 12.8) }, .{});
                if (c.label.len > 0) label(ui, c.label);
                ui.end();
            }
            ui.end();
            line(ui, k.line);
        }
        return .{ .ui = ui, .cols = cols, .stacked = stacked };
    }

    pub fn row(tb: *Table, on_press: ?Msg, key: u64) void {
        if (tb.rows > 0) line(tb.ui, k.line_soft);
        tb.rows += 1;
        tb.cell_i = 0;
        if (tb.stacked) {
            tb.ui.begin(.{ .padding = .xy(15.2, 12.8), .gap = 3.2, .pressed_background = if (on_press != null) k.panel_2 else null, .hover_background = if (on_press != null) k.panel_2 else null }, .{ .on_press = on_press, .key = key });
        } else {
            tb.ui.begin(.{ .direction = .row, .align_items = .center, .pressed_background = if (on_press != null) k.panel_2 else null, .hover_background = if (on_press != null) k.panel_2 else null }, .{ .on_press = on_press, .key = key });
        }
    }

    /// Opens the next cell; `captioned` cells get "Label:" on phones.
    pub fn cell(tb: *Table, captioned: bool) void {
        const c = tb.cols[@min(tb.cell_i, tb.cols.len - 1)];
        tb.cell_i += 1;
        if (tb.stacked) {
            tb.ui.begin(.{ .direction = .row, .gap = 4, .align_items = .start }, .{});
            if (captioned and c.label.len > 0) tb.ui.text(f(tb.ui, "{s}:", .{c.label}), .{ .font_size = 12, .color = k.ink_3, .line_height = 1.9 });
            tb.ui.begin(.{ .grow = 1, .gap = 2 }, .{});
        } else {
            tb.ui.begin(.{ .width = if (c.width) |w| .{ .px = w } else .fill, .grow = if (c.width == null) c.grow else 0, .padding = .xy(15.2, 12.8), .gap = 2 }, .{});
        }
    }

    pub fn endCell(tb: *Table) void {
        if (tb.stacked) tb.ui.end();
        tb.ui.end();
    }

    pub fn endRow(tb: *Table) void {
        tb.ui.end();
    }

    pub fn end(tb: *Table) void {
        tb.ui.end();
    }
};

/// A 1-point line across.
pub fn line(ui: *Ui, color: Color) void {
    ui.begin(.{ .height = .{ .px = 1 }, .background = color }, .{});
    ui.end();
}

// ---- Key/value rows, timeline -------------------------------------------------------------

/// `.kv`: a label column (38%, at least 7rem) and the value. Draw the value between
/// `kvBegin` and `kvEnd`, or use `kv`.
pub fn kvBegin(ui: *Ui, lbl: []const u8, last: bool) void {
    ui.begin(.{ .direction = .row, .gap = 12, .padding = .xy(0, 7.2), .align_items = .start, .borders = if (last) null else .{ .bottom = .{ .width = 1, .color = k.line_soft } } }, .{});
    ui.begin(.{ .width = .{ .px = @max(112, width * 0.38 - 40) } }, .{});
    ui.text(lbl, .{ .font_size = 14, .weight = 500, .color = k.ink_2 });
    ui.end();
    ui.begin(.{ .grow = 1, .width = .fill, .gap = 2 }, .{});
}

pub fn kvEnd(ui: *Ui, last: bool) void {
    _ = last;
    ui.end();
    ui.end();
}

pub fn kv(ui: *Ui, lbl: []const u8, value: []const u8, last: bool) void {
    kvBegin(ui, lbl, last);
    ui.text(if (value.len > 0) value else "—", .{ .font_size = 16, .color = k.ink });
    kvEnd(ui, last);
}

/// One entry of `ul.timeline`: a dot (filled for the current one), the text and the time.
pub fn timelineItem(ui: *Ui, s: []const u8, when: []const u8, o: struct { current: bool = false, internal: bool = false, last: bool = false, extra: []const u8 = "" }) void {
    ui.begin(.{ .direction = .row, .gap = 16, .opacity = if (o.internal) 0.75 else 1 }, .{});
    ui.begin(.{ .width = .{ .px = 14 }, .align_items = .center }, .{});
    ui.begin(.{ .width = .{ .px = 14 }, .height = .{ .px = 14 }, .radius = 7, .background = if (o.current) k.a else k.panel, .border_width = 2, .border_color = if (o.current) k.a else k.ink_4 }, .{});
    ui.end();
    if (!o.last) {
        ui.begin(.{ .width = .{ .px = 2 }, .grow = 1, .min_height = 12, .background = k.line }, .{});
        ui.end();
    }
    ui.end();
    ui.begin(.{ .grow = 1, .padding = .{ .bottom = 16.8 }, .gap = 1 }, .{});
    ui.text(s, .{ .font_size = 16, .color = k.ink });
    if (o.extra.len > 0) ui.text(o.extra, .{ .font_size = 14, .color = k.ink_2 });
    ui.text(when, .{ .font_size = 13, .color = k.ink_3 });
    ui.end();
    ui.end();
}

// ---- Copy ---------------------------------------------------------------------------------

/// `copyButton(text)`.
pub fn copyButton(ui: *Ui, value: []const u8, lbl: ?[]const u8) void {
    const v = ui.arena().dupe(u8, value) catch value;
    button(ui, lbl orelse labels.k("common.copy"), .{ .copy = v }, .{ .size = .sm, .icon = icons.content_copy });
}

/// `.dims`, `.form-grid` and friends: a row of equal fields that becomes a column under
/// `min` points each.
pub fn formGrid(ui: *Ui, count: usize) Grid {
    return Grid.begin(ui, count, 220, 16, width);
}

test "grid columns" {
    try std.testing.expectEqual(@as(f32, 15.2), (InputOpts{}).size);
}
