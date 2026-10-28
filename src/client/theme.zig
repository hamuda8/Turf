//! Turf's colours: the ten TwOP roles of `Wufour/private/site/apps.js` (Turf: D3DDE3, 030200,
//! 8A3324, 6E2B0A, AEA098 x2, 030200 plus the shared signal colours), the dark theme derived
//! from them with the OKLCH formulas of Wufour's `style.css`, and the semantic tokens the kit
//! draws with (ink, panel, line, on_accent, ...), computed in Zig so they are the same on every
//! platform.
//!
//! Rules (the owner's, October 2026): only the ten roles, exactly as defined; the dark theme is
//! never hand-picked; a role may be drawn with transparency, but two roles are never blended.
//! Every token below is therefore a role or a role with alpha, and "text on X" is whichever of
//! base and core is further from X in lightness. A company's branding replaces --accent and
//! --prime at run time; those two are the only colours from outside the scheme.

const std = @import("std");
const zui = @import("zui");
const Color = zui.Color;
const Oklch = zui.Oklch;

// ---- The ten roles -------------------------------------------------------------------------

pub const base = Color.hex("#D3DDE3");
pub const core = Color.hex("#030200");
pub const accent = Color.hex("#8A3324");
pub const variant = Color.hex("#6E2B0A");
pub const surface = Color.hex("#AEA098");
pub const depth = Color.hex("#AEA098");
/// Turf defines no signal colours of its own: the shared Wufour ones.
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
    // The roles after the light/dark transform (--color-b, -s, -c, -d, -p, -a, -v, -o, -r, -f).
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
    /// The page behind the workspace sheet: a tint of the surface on the base (light), the base
    /// itself (dark). Drawn over `sheet`, which is the opaque window colour.
    canvas: Color,
    /// The workspace sheet and the window colour (opaque).
    sheet: Color,
    /// Cards: a tint of the surface on the sheet (light), a lift of the core (dark).
    panel: Color,
    panel_2: Color,
    panel_3: Color,
    /// Hover/pressed well.
    press: Color,
    line: Color,
    line_soft: Color,
    accent_soft: Color,
    on_accent: Color,
    /// The chrome (the rail, the courier and tracking headers): the prime colour as the one
    /// brand band of a screen (light), the surface as a sidebar (dark).
    rail: Color,
    rail_ink: Color,
    rail_ink_2: Color,
    rail_hover: Color,
    /// The signal colours as they are (`--ok`, `--warn`, `--bad`); text on their tints is `ink`.
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

fn clamp(lo: f32, v: f32, hi: f32) f32 {
    return std.math.clamp(v, lo, hi);
}

// ---- The dark theme: style.css's transforms ------------------------------------------------
// `oklch(from C clamp(lo, 1 - l*l, hi) c*max(floor, 1 - l*slope) h)`.

fn darkOf(x: Color, lo: f32, hi: f32, floor: f32, slope: f32) Color {
    var o = lch(x);
    const k = @max(floor, 1 - o.l * slope);
    o.l = clamp(lo, 1 - o.l * o.l, hi);
    o.c *= k;
    return o.toColor();
}

/// Base and surface.
pub fn darkCanvas(x: Color) Color {
    return darkOf(x, 0.10, 0.25, 0.5, 0);
}
/// Core.
pub fn darkText(x: Color) Color {
    return darkOf(x, 0.85, 0.95, 0.6, 0);
}
/// Depth.
pub fn darkBorder(x: Color) Color {
    return darkOf(x, 0.25, 0.40, 0.4, 0);
}
/// Prime.
pub fn darkBrand(x: Color) Color {
    return darkOf(x, 0.25, 0.55, 0.60, 0.40);
}
/// Accent and variant.
pub fn darkAction(x: Color) Color {
    return darkOf(x, 0.45, 0.75, 0.70, 0.30);
}
/// Optimal, risky and fatal.
pub fn darkSignal(x: Color) Color {
    return darkOf(x, 0.45, 0.80, 0.75, 0.25);
}

/// Text on `x`: base or core, whichever is further from it in lightness (`--on-brand`,
/// `--on-accent`). `b` and `c` are the roles of the current theme.
fn onOf(x: Color, b: Color, c: Color) Color {
    const l = lch(x).l;
    return if (@abs(lch(b).l - l) >= @abs(lch(c).l - l)) b else c;
}

/// Text on a company's colour (branding preview): base or core of the light theme.
pub fn readableOn(x: Color) Color {
    return onOf(x, base, core);
}

/// The variant (hover/pressed) shade of a company's action colour. Company colours come from
/// outside the scheme, so their variant is the same colour a step darker.
pub fn darker(x: Color) Color {
    var o = lch(x);
    o.l = clamp(0, o.l - 0.08, 1);
    return o.toColor();
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
    const rail = if (dark) s else p;
    const rail_ink = onOf(rail, b, c);
    // Light: the surface tints the base, deeper with each level. Dark: the core lifts the base.
    const tint = if (dark) c else s;
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
        .canvas = if (dark) b else s.withAlpha(0.30),
        .sheet = if (dark) s else b,
        .panel = tint.withAlpha(if (dark) 0.06 else 0.12),
        .panel_2 = tint.withAlpha(if (dark) 0.10 else 0.22),
        .panel_3 = tint.withAlpha(if (dark) 0.16 else 0.34),
        .press = tint.withAlpha(if (dark) 0.22 else 0.46),
        .line = d.withAlpha(0.40),
        .line_soft = d.withAlpha(0.22),
        .accent_soft = a.withAlpha(0.16),
        .on_accent = if (brand.on_primary != null and !dark) brand.on_primary.? else onOf(a, b, c),
        .rail = rail,
        .rail_ink = rail_ink,
        .rail_ink_2 = rail_ink.withAlpha(0.62),
        .rail_hover = rail_ink.withAlpha(0.09),
        .ok_ink = o,
        .ok_bg = o.withAlpha(0.22),
        .warn_ink = r,
        .warn_bg = r.withAlpha(0.28),
        .fatal_ink = f,
        .fatal_bg = f.withAlpha(0.14),
        .well_line = if (dark) d.withAlpha(0.22) else Color.transparent,
        .scrim = (if (dark) b else c).withAlpha(0.5),
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
    try std.testing.expect(k.rail.eql(prime));
    try std.testing.expect(k.ok_ink.eql(optimal));
    // Base-coloured text on the dark red action colour and on the prime chrome.
    try std.testing.expect(k.on_accent.eql(base));
    try std.testing.expect(k.rail_ink.eql(base));
    try std.testing.expect(readableOn(base).eql(core));
}

test "the dark theme is derived by the style.css formulas" {
    const d = colors(true, .{});
    try std.testing.expect(lch(d.sheet).l <= 0.26);
    try std.testing.expect(lch(d.ink).l >= 0.84);
    try std.testing.expect(d.b.eql(darkCanvas(base)));
    try std.testing.expect(d.a.eql(darkAction(accent)));
    try std.testing.expect(d.f.eql(darkSignal(fatal)));
    // The rail is the surface in the dark, with core text.
    try std.testing.expect(d.rail.eql(d.s));
    try std.testing.expect(d.rail_ink.eql(d.c));
    const l = lch(d.b).l;
    try std.testing.expect(l >= 0.10 and l <= 0.25);
}
