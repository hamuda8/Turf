//! Turf's colours: the Wufour scheme of Turf-js `public/css/app.css` (palette D3DDE3, 030200,
//! 8A3324, 6E2B0A, AEA098 plus the signal colours), its dark-mode OKLCH transforms and its
//! semantic tokens (--ink, --panel, --line, --on-accent, ...), computed in Zig so they are the
//! same on every platform. A company's colours replace --accent and --prime at run time.
//!
//! `color-mix(in oklab, X N%, transparent)` is X at N% opacity: zui draws with alpha, so the
//! tints come out the same as in the browser.

const std = @import("std");
const zui = @import("zui");
const Color = zui.Color;
const Oklch = zui.Oklch;

pub const base = Color.hex("#D3DDE3");
pub const core = Color.hex("#030200");
pub const accent = Color.hex("#8A3324");
pub const variant = Color.hex("#6E2B0A");
pub const surface = Color.hex("#AEA098");
pub const depth = Color.hex("#AEA098");
pub const optimal = Color.hex("#54F054");
pub const risky = Color.hex("#F0F054");
pub const fatal = Color.hex("#F05454");
pub const prime = Color.hex("#030200");

/// A company's branding: the action colour (--accent) and the chrome colour (--prime).
pub const Brand = struct {
    primary: ?Color = null,
    header: ?Color = null,
    /// Text on the primary colour as the server worked it out (`carrier.onPrimary`); else
    /// the same rule here.
    on_primary: ?Color = null,
};

pub const Colors = struct {
    // The scheme's colours after the light/dark transform (--color-b, -s, -c, -d, -p, -a, -v, -o, -r, -f).
    b: Color,
    s: Color,
    c: Color,
    d: Color,
    p: Color,
    a: Color,
    v: Color,
    o: Color,
    r: Color,
    f: Color,

    ink: Color,
    ink_2: Color,
    ink_3: Color,
    ink_4: Color,
    canvas: Color,
    sheet: Color,
    panel: Color,
    panel_2: Color,
    panel_3: Color,
    /// Hover/pressed well (color-mix(--color-s 42%)).
    press: Color,
    line: Color,
    line_soft: Color,
    accent_soft: Color,
    on_accent: Color,
    rail: Color,
    rail_ink: Color,
    rail_ink_2: Color,
    rail_hover: Color,
    ok_ink: Color,
    ok_bg: Color,
    warn_ink: Color,
    warn_bg: Color,
    fatal_ink: Color,
    fatal_bg: Color,
    /// Dark mode gives recessed wells a hairline (light mode none).
    well_line: Color,
    /// The dialog backdrop.
    scrim: Color,
    dark: bool,
};

fn lch(c: Color) Oklch {
    return c.toOklch();
}

fn mk(l: f32, c: f32, h: f32) Color {
    return (Oklch{ .l = l, .c = c, .h = h }).toColor();
}

fn clamp(lo: f32, v: f32, hi: f32) f32 {
    return std.math.clamp(v, lo, hi);
}

// The dark-mode formulas from the top of app.css.
fn darkCanvas(x: Color) Color {
    const o = lch(x);
    return mk(clamp(0.10, 1 - o.l * o.l, 0.25), o.c * 0.5, o.h);
}
fn darkText(x: Color) Color {
    const o = lch(x);
    return mk(clamp(0.85, 1 - o.l * o.l, 0.95), o.c * 0.6, o.h);
}
fn darkBorder(x: Color) Color {
    const o = lch(x);
    return mk(clamp(0.25, 1 - o.l * o.l, 0.40), o.c * 0.4, o.h);
}
fn darkBrand(x: Color) Color {
    const o = lch(x);
    return mk(clamp(0.25, 1 - o.l * o.l, 0.55), o.c * @max(0.60, 1 - o.l * 0.40), o.h);
}
fn darkAction(x: Color) Color {
    const o = lch(x);
    return mk(clamp(0.45, 1 - o.l * o.l, 0.75), o.c * @max(0.70, 1 - o.l * 0.30), o.h);
}
fn darkSignal(x: Color) Color {
    const o = lch(x);
    return mk(clamp(0.45, 1 - o.l * o.l, 0.80), o.c * @max(0.75, 1 - o.l * 0.25), o.h);
}

fn lighter(x: Color, dl: f32) Color {
    const o = lch(x);
    return mk(clamp(0, o.l + dl, 1), o.c, o.h);
}

/// Near-white text on dark colours and near-black on light ones (`--on-accent`, `--rail-ink`).
pub fn readableOn(x: Color) Color {
    const o = lch(x);
    return mk(clamp(0.12, (0.62 - o.l) * 100, 0.98), 0.01, o.h);
}

/// The variant (hover/pressed) shade of a company's action colour.
pub fn darker(x: Color) Color {
    return lighter(x, -0.08);
}

pub fn colors(dark: bool, brand: Brand) Colors {
    const acc = brand.primary orelse accent;
    const vari = if (brand.primary) |p| darker(p) else variant;
    const pri = brand.header orelse prime;
    const b = if (dark) darkCanvas(base) else base;
    const s = if (dark) darkCanvas(surface) else surface;
    const c = if (dark) darkText(core) else core;
    const d = if (dark) darkBorder(depth) else depth;
    const p = if (dark) darkBrand(pri) else pri;
    const a = if (dark) darkAction(acc) else acc;
    const v = if (dark) darkAction(vari) else vari;
    const o = if (dark) darkSignal(optimal) else optimal;
    const r = if (dark) darkSignal(risky) else risky;
    const f = if (dark) darkSignal(fatal) else fatal;
    const rail = if (dark) blk: {
        const bo = lch(base);
        break :blk mk(0.14, bo.c * 0.5, bo.h);
    } else pri;
    const rail_ink = readableOn(rail);
    const sig = struct {
        fn ink(x: Color, l: f32) Color {
            const q = lch(x);
            return mk(l, q.c, q.h);
        }
    };
    return .{
        .b = b,
        .s = s,
        .c = c,
        .d = d,
        .p = p,
        .a = a,
        .v = v,
        .o = o,
        .r = r,
        .f = f,
        .ink = c,
        .ink_2 = c.withAlpha(0.64),
        .ink_3 = c.withAlpha(0.44),
        .ink_4 = c.withAlpha(0.26),
        .canvas = lighter(b, -0.025),
        .sheet = b,
        .panel = lighter(b, 0.045),
        .panel_2 = s.withAlpha(0.16),
        .panel_3 = s.withAlpha(0.30),
        .press = s.withAlpha(0.42),
        .line = d.withAlpha(0.40),
        .line_soft = d.withAlpha(0.22),
        .accent_soft = a.withAlpha(0.16),
        .on_accent = if (brand.on_primary != null and !dark) brand.on_primary.? else readableOn(a),
        .rail = rail,
        .rail_ink = rail_ink,
        .rail_ink_2 = rail_ink.withAlpha(0.62),
        .rail_hover = rail_ink.withAlpha(0.09),
        .ok_ink = if (dark) o else sig.ink(optimal, 0.42),
        .ok_bg = o.withAlpha(0.22),
        .warn_ink = if (dark) r else sig.ink(risky, 0.46),
        .warn_bg = r.withAlpha(0.28),
        .fatal_ink = if (dark) f else sig.ink(fatal, 0.50),
        .fatal_bg = f.withAlpha(0.14),
        .well_line = if (dark) d.withAlpha(0.22) else Color.transparent,
        .scrim = c.withAlpha(0.5),
        .dark = dark,
    };
}

/// A status's colour (`.st-<status>` in app.css).
pub fn status(k: *const Colors, s: []const u8) Color {
    const eq = std.mem.eql;
    const in = struct {
        fn any(x: []const u8, list: []const []const u8) bool {
            for (list) |l| if (eq(u8, x, l)) return true;
            return false;
        }
    }.any;
    if (in(s, &.{ "picked_up", "assigned", "accepted" })) return k.a;
    if (eq(u8, s, "at_hub")) return k.p;
    if (in(s, &.{ "in_transit", "in_progress", "returning", "returned" })) return k.v;
    if (eq(u8, s, "out_for_delivery")) return k.warn_ink;
    if (in(s, &.{ "delivered", "completed" })) return k.ok_ink;
    if (in(s, &.{ "delivery_failed", "failed", "lost" })) return k.fatal_ink;
    if (eq(u8, s, "cancelled")) return k.ink_3;
    return k.ink_2;
}

test "the palette in light mode is the palette" {
    const k = colors(false, .{});
    try std.testing.expect(k.sheet.eql(base));
    try std.testing.expect(k.a.eql(accent));
    // White-ish text on the dark red action colour, black-ish on the light base.
    try std.testing.expect(lch(k.on_accent).l > 0.9);
    try std.testing.expect(lch(readableOn(base)).l < 0.2);
    const d = colors(true, .{});
    try std.testing.expect(lch(d.sheet).l <= 0.26);
    try std.testing.expect(lch(d.ink).l >= 0.84);
}
