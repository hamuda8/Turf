//! The web home "/" (Turf-js landing.js, index.html, css/landing.css). Tracking comes first:
//! most visitors hold a tracking number from a store, so the search box sits in the hero and
//! opens /track with the numbers (a tracking link opens its page). Below: what Turf does, for
//! shipping companies and for stores. The navigation bar and the footer are shared with /track.

const std = @import("std");
const zui = @import("zui");
const core = @import("../core.zig");
const kit = @import("../kit.zig");
const json = @import("../json.zig");
const fmt = @import("../fmt.zig");
const icons = @import("../icons.zig");
const labels = @import("../labels.zig");
const lookup = @import("../widgets/lookup.zig");

const Cx = core.Cx;
const Ui = core.Ui;
const L = labels.k;

const d_platform: u8 = 0;
const f_box: u16 = 0;
const A = enum(u16) { search = 1 };

pub const S = struct {
    search: lookup.Search = .{ .slot = f_box, .act = @intFromEnum(A.search) },
};

pub fn title(_: *const S, _: *const Cx) []const u8 {
    return "Turf";
}

pub fn enter(_: *S, c: *Cx) void {
    // Switched-on features (set in Control): direct shipping shows its button only when on.
    c.load(d_platform, c.publicUrl("/platform"));
    c.post("{{\"type\":\"title\",\"title\":{f}}}", .{std.json.fmt(c.print("Turf · {s}", .{L("landing.tagline")}), .{})});
}

pub fn update(s: *S, c: *Cx, e: core.Ev) void {
    switch (e) {
        .act => |a| if (a.id == @intFromEnum(A.search)) switch (s.search.submit(c)) {
            .none => {},
            .numbers => |n| c.openLink(c.print("/track?n={s}", .{core.encode(c.arena(), lookup.join(c.arena(), n, ","))})),
        },
        else => {},
    }
}

/// An address of the Turf server (pages the app does not draw: /terms, /privacy, /developers).
pub fn serverUrl(ui: *Ui, path: []const u8) []const u8 {
    return kit.f(ui, "{s}{s}", .{ core.api_base, path });
}

/// clamp(lo, vw% of the width, hi).
pub fn clampVw(ui: *Ui, lo: f32, vw: f32, hi: f32) f32 {
    return std.math.clamp(ui.env.width * vw / 100, lo, hi);
}

/// `.landing-nav`: Turf, the language, the API docs (the home page only), Sign in.
pub fn nav(ui: *Ui, c: *const Cx, docs: bool) void {
    const k = kit.k;
    const w = ui.env.width;
    ui.begin(.{ .width = .fill, .align_items = .center }, .{});
    ui.begin(.{ .direction = .row, .align_items = .center, .gap = 12, .width = .{ .px = @min(w, 1120) }, .padding = .xy(clampVw(ui, 16, 3, 24), 16) }, .{});
    ui.begin(.{ .direction = .row, .align_items = .center, .gap = 8.8, .pressed_opacity = 0.7 }, .{ .on_press = .{ .link = "/" } });
    ui.begin(.{ .width = .{ .px = 36 }, .height = .{ .px = 36 }, .radius = 10, .clip = true }, .{});
    ui.image(c.asset(ui.arena(), "/img/icon-192.png"), .{ .width = .{ .px = 36 }, .height = .{ .px = 36 } }, 0);
    ui.end();
    ui.text("Turf", .{ .font_size = 19.2, .weight = 800, .color = k.ink });
    ui.end();
    kit.spacer(ui);
    kit.button(ui, if (c.ar()) "English" else "العربية", .{ .shell = .lang }, .{ .variant = .ghost, .icon = icons.language, .size = if (w <= 420) .sm else .md });
    // The API documentation hides on phones (max-width: 560px).
    if (docs and w > 560) kit.button(ui, L("nav.api_docs"), .{ .open = serverUrl(ui, "/developers") }, .{ .variant = .ghost });
    kit.button(ui, L("landing.sign_in"), .{ .link = "/app" }, .{ .variant = .primary, .size = if (w <= 420) .sm else .md });
    ui.end();
    ui.end();
}

/// `.landing-foot`: the year, the terms and the privacy policy.
pub fn footer(ui: *Ui) void {
    const k = kit.k;
    kit.line(ui, k.line_soft);
    ui.begin(.{ .direction = .row, .justify = .center, .align_items = .center, .gap = 4, .padding = .xy(16, 32) }, .{});
    const year = fmt.civil(fmt.now()).y;
    ui.text(kit.f(ui, "© {d} Turf · ", .{year}), .{ .font_size = 13.6, .color = k.ink_3 });
    kit.link(ui, L("legal.terms"), .{ .open = serverUrl(ui, "/terms") }, .{ .size = 13.6, .color = k.ink_3, .weight = 500 });
    ui.text(" · ", .{ .font_size = 13.6, .color = k.ink_3 });
    kit.link(ui, L("legal.privacy"), .{ .open = serverUrl(ui, "/privacy") }, .{ .size = 13.6, .color = k.ink_3, .weight = 500 });
    ui.end();
}

pub fn view(s: *const S, c: *const Cx, ui: *Ui) void {
    const k = kit.k;
    const w = ui.env.width;
    const side = clampVw(ui, 16, 3, 24);
    const inner = @min(w, 1120) - 2 * side;
    ui.beginScroll(.{ .width = .fill, .height = .fill, .padding = .{ .top = 0, .bottom = 0 } }, zui.key("landing"));
    nav(ui, c, true);

    // The hero: the pitch and the tracking panel (first on narrow screens).
    ui.begin(.{ .width = .fill, .align_items = .center }, .{});
    const two = w > 900;
    const gap = clampVw(ui, 24, 4, 48);
    ui.begin(.{ .direction = if (two) .row else .column, .gap = gap, .align_items = .center, .width = .{ .px = inner + 2 * side }, .padding = .{ .top = clampVw(ui, 24, 5, 64), .bottom = 32, .start = side, .end = side } }, .{});
    if (two) {
        const left = (inner - gap) * 1.1 / 2.1;
        ui.begin(.{ .width = .{ .px = left } }, .{});
        kit.width = left;
        heroText(ui, c);
        ui.end();
        ui.begin(.{ .width = .{ .px = inner - gap - left } }, .{});
        kit.width = inner - gap - left;
        trackPanel(ui, s);
        ui.end();
    } else {
        kit.width = inner;
        ui.begin(.{ .width = .fill }, .{});
        trackPanel(ui, s);
        ui.end();
        ui.begin(.{ .width = .fill }, .{});
        heroText(ui, c);
        ui.end();
    }
    ui.end();
    ui.end();

    // What Turf does.
    kit.width = inner;
    ui.begin(.{ .width = .fill, .align_items = .center }, .{});
    ui.begin(.{ .width = .{ .px = inner + 2 * side }, .padding = .{ .top = 16, .bottom = 48, .start = side, .end = side } }, .{});
    const features = [_]struct { zui.Icon, []const u8, []const u8 }{
        .{ icons.bolt, "landing.f_express", "landing.f_express_text" },
        .{ icons.route, "landing.f_allocation", "landing.f_allocation_text" },
        .{ icons.map, "landing.f_tracking", "landing.f_tracking_text" },
        .{ icons.navigation, "landing.f_drivers", "landing.f_drivers_text" },
        .{ icons.shield, "landing.f_safety", "landing.f_safety_text" },
        .{ icons.palette, "landing.f_brand", "landing.f_brand_text" },
        .{ icons.code, "landing.f_api", "landing.f_api_text" },
    };
    var g = kit.Grid.begin(ui, features.len, 240, 16, inner);
    for (features) |x| {
        g.cell();
        kit.card(ui, .{ .gap = 8 });
        ui.begin(.{ .width = .{ .px = 46 }, .height = .{ .px = 46 }, .radius = 14, .background = k.accent_soft, .align_items = .center, .justify = .center }, .{});
        kit.icon(ui, x[0], 25.6, k.a);
        ui.end();
        kit.h3(ui, L(x[1]));
        kit.muted(ui, L(x[2]));
        kit.endCard(ui, .{});
        g.endCell();
    }
    g.end();
    ui.end();
    ui.end();

    // For shipping companies, for stores.
    ui.begin(.{ .width = .fill, .align_items = .center }, .{});
    ui.begin(.{ .width = .{ .px = inner + 2 * side }, .padding = .{ .bottom = 48, .start = side, .end = side } }, .{});
    var ga = kit.Grid.begin(ui, 2, 300, 16, inner);
    inline for (.{ .{ "landing.for_carriers", "landing.c" }, .{ "landing.for_merchants", "landing.m" } }) |x| {
        ga.cell();
        kit.card(ui, .{ .gap = 9.6 });
        kit.h2(ui, L(x[0]));
        ui.begin(.{ .gap = 4.8 }, .{});
        inline for (.{ "1", "2", "3", "4" }) |n| bullet(ui, L(x[1] ++ n));
        ui.end();
        kit.endCard(ui, .{});
        ga.endCell();
    }
    ga.end();
    ui.end();
    ui.end();

    footer(ui);
    ui.end();
}

fn bullet(ui: *Ui, s: []const u8) void {
    ui.begin(.{ .direction = .row, .gap = 8, .align_items = .start, .padding = .{ .start = 4 } }, .{});
    ui.text("\u{2022}", .{ .font_size = 15, .color = kit.k.ink_2 });
    ui.text(s, .{ .font_size = 15, .color = kit.k.ink_2, .grow = 1 });
    ui.end();
}

fn heroText(ui: *Ui, c: *const Cx) void {
    const k = kit.k;
    const h1 = clampVw(ui, 32, 5, 54.4);
    ui.begin(.{ .gap = 20 }, .{});
    ui.text(L("landing.title"), .{ .font_size = h1, .weight = 850, .line_height = 1.05, .letter_spacing = -0.045 * h1, .color = k.ink, .max_width = h1 * 18 * 0.6 });
    ui.text(L("landing.subtitle"), .{ .font_size = 18.4, .color = k.ink_2, .line_height = 1.5 });
    var w = kit.Wrap.begin(ui, kit.width, 9.6);
    const ctas = [_]struct { []const u8, zui.Icon, []const u8, bool }{
        .{ L("landing.cta_carrier"), icons.local_shipping, "/app?start=carrier", true },
        .{ L("landing.cta_merchant"), icons.package_2, "/app?start=merchant", false },
        .{ L("direct.send_title"), icons.send, "/app/send", false },
    };
    for (ctas, 0..) |x, i| {
        if (i == 2 and !json.boolean(c.data(d_platform), "features.directShipping")) continue;
        w.item(kit.estimate(x[0], 16.3) + 21 + 7.2 + 48);
        kit.button(ui, x[0], .{ .link = x[2] }, .{ .variant = if (x[3]) .primary else .normal, .size = .lg, .icon = x[1] });
    }
    w.end();
    ui.end();
}

/// `.hero-track`: the tracking search on the chrome colour.
fn trackPanel(ui: *Ui, s: *const S) void {
    const k = kit.k;
    const pad = clampVw(ui, 20, 3, 28);
    ui.begin(.{ .gap = 13.6, .padding = .all(pad), .radius = 28, .background = k.rail, .gradient = zui.Gradient.linear(225, &.{ .{ .color = k.a.mix(0.28, k.rail), .at = 0 }, .{ .color = k.rail, .at = 0.55 } }), .shadow = kit.shadow3() }, .{});
    const saved = kit.width;
    kit.width = saved - 2 * pad;
    ui.begin(.{ .direction = .row, .gap = 9.6, .align_items = .center }, .{});
    ui.begin(.{ .width = .{ .px = 40 }, .height = .{ .px = 40 }, .radius = 12, .background = k.rail_ink.withAlpha(0.12), .align_items = .center, .justify = .center }, .{});
    kit.icon(ui, icons.search, 22.4, k.rail_ink);
    ui.end();
    ui.text(L("lookup.title"), .{ .font_size = clampVw(ui, 20.8, 2.6, 25.6), .weight = 850, .color = k.rail_ink, .grow = 1, .line_height = 1.15 });
    ui.end();
    ui.text(L("lookup.intro"), .{ .font_size = 15.7, .color = k.rail_ink_2 });
    lookup.form(ui, &s.search, .{ .hero = true, .on_rail = true });
    ui.begin(.{ .direction = .row, .wrap = true, .gap = 16, .align_items = .center, .justify = .space_between }, .{});
    ui.begin(.{ .direction = .row, .gap = 4.8, .align_items = .center }, .{});
    kit.icon(ui, icons.qr_code_2, 17, k.rail_ink_2);
    ui.text(L("lookup.where_number"), .{ .font_size = 13.1, .color = k.rail_ink_2 });
    ui.end();
    ui.begin(.{ .direction = .row, .gap = 3.2, .align_items = .center, .pressed_opacity = 0.6 }, .{ .on_press = .{ .link = "/track" } });
    ui.text(L("lookup.open_page"), .{ .font_size = 13.1, .weight = 700, .color = k.rail_ink });
    kit.iconFlip(ui, icons.arrow_forward, 17, k.rail_ink);
    ui.end();
    ui.end();
    kit.width = saved;
    ui.end();
}

// ---- Tests --------------------------------------------------------------------------------

const testing = std.testing;

/// Opens the landing page in the headless driver (only the web has one: it is entered by hand).
pub fn openForTest(width: f32) *Cx {
    const app = @import("../app.zig");
    app.D.startWith(width, 900, "/track");
    const c: *Cx = @constCast(app.D.R.appState());
    c.mode = .landing;
    c.base_len = 0;
    c.path_len = 1;
    c.path[0] = '/';
    app.enterPage(c);
    app.D.R.dispatch(.frame);
    return c;
}

test "landing: draws, and the hero search opens /track with the numbers" {
    const app = @import("../app.zig");
    _ = openForTest(1280);
    defer app.D.reset();
    try testing.expect(app.D.respond("/api/public/platform", 200, "{\"features\":{\"directShipping\":true}}"));
    try testing.expect(app.D.findText("Shipping across Syria, tracked every step of the way") != 0);
    try testing.expect(app.D.findText("Send a parcel") != 0);
    try testing.expect(app.D.findText("Instant allocation") != 0);
    try app.D.press("Track");
    try testing.expect(app.D.findText("Enter a tracking number first.") != 0);
    try app.D.typeInto("Enter tracking number", "trf1234567890");
    try app.D.press("Track");
    try testing.expectEqual(core.Mode.lookup, app.D.R.appState().mode);
    try testing.expect(app.D.pending("/api/public/lookup?n=TRF1234567890") != null);
}
