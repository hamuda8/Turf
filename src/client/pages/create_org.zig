//! Company setup "/app/new" and "/app/new/<type>" (Turf-js views/create-org.js): choose shipping
//! company or online store, name it, pick its app address. Full-screen and focused: it is the
//! first thing a new user sees. A live preview shows the company's app and what it gets.

const std = @import("std");
const zui = @import("zui");
const core = @import("../core.zig");
const kit = @import("../kit.zig");
const json = @import("../json.zig");
const icons = @import("../icons.zig");
const labels = @import("../labels.zig");
const landing = @import("landing.zig");
const config = @import("app_config");

const Cx = core.Cx;
const Ui = core.Ui;
const L = labels.k;

const f_name: u16 = 0;
const f_slug: u16 = 1;
const f_phone: u16 = 2;

const A = enum(u16) { pick_carrier = 1, pick_merchant, terms, create, check_slug };
const T_SLUG: u16 = 1;

pub const Kind = enum { carrier, merchant };
const SlugState = enum { none, hint, ok, bad };

const Def = struct { icon: zui.Icon, title: []const u8, hint: []const u8, perks: [4][]const u8 };
fn def(kind: Kind) Def {
    return switch (kind) {
        .carrier => .{ .icon = icons.local_shipping, .title = "home.create_carrier", .hint = "home.create_carrier_hint", .perks = .{ "landing.c1", "landing.c2", "landing.c3", "landing.c4" } },
        .merchant => .{ .icon = icons.package_2, .title = "home.create_merchant", .hint = "home.create_merchant_hint", .perks = .{ "landing.m1", "landing.m2", "landing.m3", "landing.m4" } },
    };
}

pub const S = struct {
    kind: ?Kind = null,
    slug_touched: bool = false,
    slug_state: SlugState = .none,
    /// Typing restarts the wait before the address is checked.
    waits: u32 = 0,
    /// The address whose answer is awaited.
    checking: []const u8 = "",
    accept_terms: bool = false,
    /// The check failed (no connection): the hint, in red.
    fail_hint: bool = false,
};

pub fn title(_: *const S, _: *const Cx) []const u8 {
    return L("onb.title");
}

pub fn enter(s: *S, c: *Cx) void {
    const p = c.param(1);
    if (std.mem.eql(u8, p, "carrier")) s.kind = .carrier;
    if (std.mem.eql(u8, p, "merchant")) s.kind = .merchant;
    if (s.kind != null) c.fx.focus(kit.slotKey(f_name));
}

/// Lowercase letters, digits and dashes, at most 40 (`slugify`).
pub fn slugify(a: std.mem.Allocator, s: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var dash = false;
    for (s) |ch0| {
        const ch = std.ascii.toLower(ch0);
        if ((ch >= 'a' and ch <= 'z') or (ch >= '0' and ch <= '9')) {
            if (dash and out.items.len > 0) out.append(a, '-') catch {};
            dash = false;
            out.append(a, ch) catch {};
        } else dash = true;
    }
    return out.items[0..@min(out.items.len, 40)];
}

/// `maxlength` (zui inputs have none): keeps the first `n` characters.
fn limit(c: *Cx, slot: u16, n: usize) void {
    const v = c.val(slot);
    var it = std.unicode.Utf8View.initUnchecked(v).iterator();
    var count: usize = 0;
    while (it.nextCodepointSlice()) |_| {
        count += 1;
        if (count == n) {
            if (it.i < v.len) c.setVal(slot, c.dupe(v[0..it.i]));
            return;
        }
    }
}

/// The fields this form shows a server error under; others are toasted (showFieldError).
fn formField(name: []const u8) bool {
    for ([_][]const u8{ "name", "slug", "phone", "acceptTerms" }) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

fn checkSlug(s: *S, c: *Cx) void {
    const value = c.valTrim(f_slug);
    if (value.len < 3) {
        s.waits = 0;
        s.checking = "";
        s.slug_state = if (value.len > 0) .hint else .none;
        return;
    }
    s.waits += 1;
    c.after(350, T_SLUG);
}

pub fn update(s: *S, c: *Cx, e: core.Ev) void {
    switch (e) {
        .text => |x| switch (x.slot) {
            f_name => {
                limit(c, f_name, 80); // maxlength
                if (!s.slug_touched) c.setVal(f_slug, slugify(c.arena(), c.val(f_name)));
                checkSlug(s, c);
            },
            f_slug => {
                limit(c, f_slug, 40); // maxlength
                s.slug_touched = true;
                checkSlug(s, c);
            },
            else => {},
        },
        .timer => |id| if (id == T_SLUG and s.waits > 0) {
            s.waits -= 1;
            if (s.waits > 0) return;
            const value = c.valTrim(f_slug);
            if (value.len < 3) return;
            s.checking = c.dupe(value);
            c.quietErrors(@intFromEnum(A.check_slug));
            c.send(@intFromEnum(A.check_slug), .GET, c.appUrl(c.print("/slug-available?slug={s}", .{core.encode(c.arena(), value)})), "");
        },
        .act => |a| switch (@as(A, @enumFromInt(a.id))) {
            .pick_carrier, .pick_merchant => {
                const kind: Kind = if (a.id == @intFromEnum(A.pick_carrier)) .carrier else .merchant;
                s.kind = kind;
                c.fx.setLink(c.print("{s}/new/{s}", .{ c.baseStr(), @tagName(kind) }));
                c.fx.focus(kit.slotKey(f_name));
            },
            .terms => s.accept_terms = !s.accept_terms,
            .create => {
                const kind = s.kind orelse return;
                var b = json.Obj.init(c.arena());
                b.str("type", @tagName(kind));
                b.strOpt("name", c.val(f_name));
                b.strOpt("slug", c.val(f_slug));
                b.strOpt("phone", c.val(f_phone));
                b.boolean("acceptTerms", s.accept_terms);
                // A problem with one field shows under it; others as a toast.
                c.quietErrors(@intFromEnum(A.create));
                c.send(@intFromEnum(A.create), .POST, c.appUrl("/orgs"), b.done());
            },
            .check_slug => {},
        },
        .done => |d| switch (@as(A, @enumFromInt(d.id))) {
            .check_slug => {
                if (!std.mem.eql(u8, c.valTrim(f_slug), s.checking)) return;
                s.slug_state = if (d.ok and json.boolean(d.v, "available")) .ok else .bad;
                s.fail_hint = !d.ok;
            },
            .create => if (d.ok) {
                // The new company is not in the session yet: read the account again.
                c.me.reset();
                c.openLink(c.print("/o/{s}/", .{json.str(d.v, "slug")}));
            } else if (!formField(json.str(d.v, "error.field"))) c.toast(c.errorText(d.status, d.v), .err),
            else => {},
        },
        else => {},
    }
}

/// The host shown before the address ("turf.wreseal.com/o/").
fn host() []const u8 {
    const s = config.server;
    const start = if (std.mem.indexOf(u8, s, "://")) |i| i + 3 else 0;
    return s[start..];
}

pub fn view(s: *const S, c: *const Cx, ui: *Ui) void {
    const k = kit.k;
    const w = ui.env.width;
    const side = landing.clampVw(ui, 16, 4, 40);
    const inner = @min(w, 1080) - 2 * side;
    const has_companies = json.arr(c.me.value, "orgs").len > 0;
    ui.beginScroll(.{ .width = .fill, .height = .fill, .align_items = .center, .padding = .{ .top = 0, .bottom = 0 } }, zui.key("onb"));

    // The top bar.
    ui.begin(.{ .direction = .row, .align_items = .center, .gap = 8, .width = .{ .px = @min(w, 1180) }, .padding = .xy(side, 16) }, .{});
    ui.begin(.{ .direction = .row, .align_items = .center, .gap = 8.8, .pressed_opacity = 0.7 }, .{ .on_press = .{ .link = "/" } });
    ui.begin(.{ .width = .{ .px = 34 }, .height = .{ .px = 34 }, .radius = 10, .clip = true }, .{});
    ui.image(c.asset(ui.arena(), "/img/icon-192.png"), .{ .width = .{ .px = 34 }, .height = .{ .px = 34 } }, 0);
    ui.end();
    ui.text("Turf", .{ .font_size = 18.4, .weight = 800, .color = k.ink });
    ui.end();
    kit.spacer(ui);
    const narrow = w < 520;
    kit.button(ui, if (c.ar()) "English" else "العربية", .{ .shell = .lang }, .{ .variant = .ghost, .size = .sm, .icon = icons.language });
    if (has_companies) kit.button(ui, if (narrow) "" else L("nav.my_companies"), .{ .go = "/" }, .{ .variant = .ghost, .size = .sm, .icon = icons.apps, .label = L("nav.my_companies") });
    kit.button(ui, if (narrow) "" else L("nav.sign_out"), .{ .shell = .sign_out }, .{ .variant = .ghost, .size = .sm, .icon = icons.logout, .flip = true, .label = L("nav.sign_out") });
    ui.end();

    ui.begin(.{ .width = .{ .px = inner + 2 * side }, .gap = 20, .padding = .{ .top = 24, .bottom = 64, .start = side, .end = side } }, .{});
    kit.width = inner;
    ui.begin(.{ .gap = 5.6 }, .{});
    const welcome = if (has_companies) L("onb.title_more") else ui.tf(labels.english("onb.title_welcome") orelse "{name}", .{ .name = json.str(c.me.value, "user.username") });
    ui.text(welcome, .{ .font_size = landing.clampVw(ui, 28.8, 3.8, 41.6), .weight = 800, .line_height = 1.1, .letter_spacing = -0.045 * landing.clampVw(ui, 28.8, 3.8, 41.6), .color = k.ink });
    ui.text(L("onb.subtitle"), .{ .font_size = 16.8, .color = k.ink_2, .max_width = 60 * 16.8 * 0.5 });
    ui.end();

    step(ui, "1", L("onb.step_type"));
    var g = kit.Grid.begin(ui, 2, 280, 16, inner);
    inline for (.{ Kind.carrier, Kind.merchant }) |kind| {
        g.cell();
        typeCard(ui, kind, s.kind == kind);
        g.endCell();
    }
    g.end();

    if (s.kind) |kind| {
        const two = w > 820;
        if (two) {
            const form_w = (inner - 20) * 1.25 / 2.25;
            ui.begin(.{ .direction = .row, .gap = 20, .align_items = .start }, .{});
            ui.begin(.{ .width = .{ .px = form_w } }, .{});
            kit.width = form_w;
            form(s, c, ui, kind);
            ui.end();
            ui.begin(.{ .width = .{ .px = inner - 20 - form_w } }, .{});
            kit.width = inner - 20 - form_w;
            preview(c, ui, kind);
            ui.end();
            ui.end();
            kit.width = inner;
        } else form(s, c, ui, kind); // phones: the form right under the choice
    }
    ui.end();
    ui.end();
}

/// `.onb-step`: a numbered circle and the step's name.
fn step(ui: *Ui, n: []const u8, s: []const u8) void {
    const k = kit.k;
    ui.begin(.{ .direction = .row, .gap = 9.6, .align_items = .center }, .{});
    ui.begin(.{ .width = .{ .px = 26 }, .height = .{ .px = 26 }, .radius = 13, .background = k.a, .gradient = kit.accentGradient(), .align_items = .center, .justify = .center }, .{});
    ui.text(n, .{ .font_size = 12.8, .weight = 800, .color = k.on_accent });
    ui.end();
    ui.text(s, .{ .font_size = 11.2, .weight = 800, .color = k.ink_3, .uppercase = true, .letter_spacing = 1.57 });
    ui.end();
}

fn typeCard(ui: *Ui, kind: Kind, chosen: bool) void {
    const k = kit.k;
    const d = def(kind);
    ui.begin(.{
        .direction = .row,
        .align_items = .center,
        .gap = 16,
        .padding = .all(20),
        .radius = 22,
        .background = k.panel,
        .shadow = if (chosen) kit.shadow2() else kit.shadow1(),
        .hover_background = if (chosen) null else k.panel.mix(0.85, k.panel_3),
        .transition = .{ .duration_ms = 220 },
        .border_width = 2,
        .border_color = if (chosen) k.a else zui.Color.transparent,
        .pressed_background = k.panel_2.mix(0.5, k.panel),
        .height = .fill,
    }, .{ .on_press = kit.act(if (kind == .carrier) A.pick_carrier else A.pick_merchant, 0), .key = zui.key(@tagName(kind)) });
    ui.begin(.{ .width = .{ .px = 58 }, .height = .{ .px = 58 }, .radius = 18, .background = k.accent_soft, .align_items = .center, .justify = .center }, .{});
    kit.icon(ui, d.icon, 32, k.a);
    ui.end();
    ui.begin(.{ .grow = 1, .gap = 4 }, .{});
    ui.text(L(d.title), .{ .font_size = 17.3, .weight = 700, .color = k.ink });
    ui.text(L(d.hint), .{ .font_size = 14.4, .color = k.ink_2, .line_height = 1.45 });
    ui.end();
    ui.begin(.{ .width = .{ .px = 26 }, .height = .{ .px = 26 }, .radius = 13, .background = if (chosen) k.a else null, .border_width = 2, .border_color = if (chosen) k.a else k.line, .align_items = .center, .justify = .center }, .{});
    if (chosen) kit.icon(ui, icons.check, 17.6, k.on_accent);
    ui.end();
    ui.end();
}

fn form(s: *const S, c: *const Cx, ui: *Ui, kind: Kind) void {
    const k = kit.k;
    ui.begin(.{ .gap = 17.6, .padding = .all(24), .radius = 28, .background = k.panel }, .{});
    const saved = kit.width;
    kit.width = saved - 48;
    step(ui, "2", L("onb.step_details"));
    kit.field(ui, L("org.name"), f_name, .{ .required = true, .input = .{ .name = "name", .height = 50, .size = 16, .on_submit = kit.act(A.create, 0) } });

    // The address: the host, then the company's part.
    kit.fieldBegin(ui, L("org.slug"), true);
    ui.begin(.{ .direction = .row, .align_items = .stretch, .no_mirror = true }, .{});
    ui.begin(.{ .direction = .row, .align_items = .center, .padding = .xy(13.6, 0), .background = k.panel_3, .radius = 16, .max_width = (kit.width) * 0.6 }, .{});
    ui.text(kit.f(ui, "{s}/o/", .{host()}), .{ .font_size = 14.4, .color = k.ink_2, .max_lines = if (ui.env.width <= 480) 0 else 1 });
    ui.end();
    kit.input(ui, f_slug, .{ .name = "slug", .placeholder = "my-company", .ltr = true, .grow = 1, .height = 50, .size = 16, .on_submit = kit.act(A.create, 0) });
    ui.end();
    if (s.slug_state != .none) {
        ui.begin(.{ .direction = .row, .gap = 4.8, .align_items = .center }, .{});
        const color = switch (s.slug_state) {
            .ok => k.ok_ink,
            .bad => k.fatal_ink,
            else => k.ink_2,
        };
        switch (s.slug_state) {
            .ok => kit.icon(ui, icons.check, 16, color),
            .bad => if (!s.fail_hint) kit.icon(ui, icons.close, 16, color),
            else => {},
        }
        const msg = switch (s.slug_state) {
            .ok => L("onb.slug_available"),
            .bad => if (s.fail_hint) L("org.slug_hint") else L("org.slug_taken"),
            else => L("org.slug_hint"),
        };
        ui.text(msg, .{ .font_size = 13.1, .color = color });
        ui.end();
    }
    kit.fieldEnd(ui, "slug", "");

    // Companies often work in several governorates: where a carrier operates is set later.
    kit.field(ui, L("common.phone"), f_phone, .{ .input = .{ .name = "phone", .kind = .phone, .ltr = true, .placeholder = "09xx xxx xxx", .height = 50, .size = 16, .on_submit = kit.act(A.create, 0) } });

    ui.begin(.{ .gap = 6.4 }, .{});
    ui.begin(.{ .direction = .row, .gap = 9.6, .align_items = .start }, .{});
    ui.begin(.{ .pressed_opacity = 0.75 }, .{ .on_press = kit.act(A.terms, 0) });
    kit.box(ui, s.accept_terms);
    ui.end();
    ui.begin(.{ .grow = 1, .gap = 2 }, .{});
    ui.begin(.{ .pressed_opacity = 0.75 }, .{ .on_press = kit.act(A.terms, 0) });
    kit.text(ui, L("onb.accept_terms_before"), .{});
    ui.end();
    ui.begin(.{ .direction = .row, .gap = 4, .align_items = .center }, .{});
    kit.link(ui, L("legal.terms"), .{ .open = landing.serverUrl(ui, "/terms") }, .{});
    kit.text(ui, L("onb.and"), .{});
    kit.link(ui, L("legal.privacy"), .{ .open = landing.serverUrl(ui, "/privacy") }, .{});
    ui.end();
    ui.end();
    ui.end();
    if (c.fieldError("acceptTerms")) |e| ui.text(e, .{ .font_size = 12.5, .weight = 650, .color = k.fatal_ink });
    ui.end();

    kit.button(ui, if (kind == .merchant) L("onb.create_merchant") else L("onb.create_carrier"), kit.act(A.create, 0), .{ .variant = .primary, .size = .lg, .block = true, .busy = @intFromEnum(A.create) });
    ui.begin(.{ .direction = .row, .gap = 8, .align_items = .start }, .{});
    kit.icon(ui, icons.shield, 18, k.ink_2);
    ui.text(L("onb.owner_short"), .{ .font_size = 13.6, .color = k.ink_2, .line_height = 1.5, .grow = 1 });
    ui.end();
    kit.width = saved;
    ui.end();
}

/// The live preview: the company's app bar, and what it gets.
fn preview(c: *const Cx, ui: *Ui, kind: Kind) void {
    const k = kit.k;
    const name = std.mem.trim(u8, c.val(f_name), " ");
    const lbl = if (name.len > 0) name else L("onb.your_company");
    const slug = std.mem.trim(u8, c.val(f_slug), " ");
    ui.begin(.{ .gap = 14.4 }, .{});
    ui.begin(.{ .radius = 30, .background = k.panel, .clip = true }, .{});
    ui.begin(.{ .direction = .row, .align_items = .center, .gap = 11.2, .padding = .xy(16, 17.6), .background = k.rail }, .{});
    ui.begin(.{ .width = .{ .px = 38 }, .height = .{ .px = 38 }, .radius = 12, .background = k.panel, .align_items = .center, .justify = .center }, .{});
    ui.text(firstLetter(ui, lbl), .{ .font_size = 16, .weight = 800, .color = k.a });
    ui.end();
    ui.begin(.{ .grow = 1, .gap = 1 }, .{});
    ui.text(lbl, .{ .font_size = 15, .weight = 700, .color = k.rail_ink, .max_lines = 1 });
    ui.begin(.{ .no_mirror = true }, .{});
    ui.text(kit.f(ui, "/o/{s}", .{if (slug.len > 0) slug else "my-company"}), .{ .font_size = 12.5, .color = k.rail_ink.withAlpha(0.8) });
    ui.end();
    ui.end();
    ui.end();
    ui.begin(.{ .padding = .all(17.6), .gap = 11.2 }, .{});
    for ([_]f32{ 0.7, 0.9, 0.55 }) |f| {
        ui.begin(.{ .width = .{ .px = (kit.width - 35.2) * f }, .height = .{ .px = 12 }, .radius = 6, .background = k.panel_3 }, .{});
        ui.end();
    }
    ui.end();
    ui.end();
    kit.h3(ui, L("onb.you_get"));
    ui.begin(.{ .gap = 8.8 }, .{});
    for (def(kind).perks) |p| {
        ui.begin(.{ .direction = .row, .gap = 8.8, .align_items = .start }, .{});
        kit.icon(ui, icons.check, 20, k.ok_ink);
        ui.text(L(p), .{ .font_size = 15, .color = k.ink_2, .line_height = 1.45, .grow = 1 });
        ui.end();
    }
    ui.end();
    ui.end();
}

fn firstLetter(ui: *Ui, s: []const u8) []const u8 {
    if (s.len == 0) return "";
    const n = std.unicode.utf8ByteSequenceLength(s[0]) catch 1;
    const out = ui.arena().dupe(u8, s[0..@min(n, s.len)]) catch return "";
    if (out.len == 1) out[0] = std.ascii.toUpper(out[0]);
    return out;
}

// ---- Tests --------------------------------------------------------------------------------

const testing = std.testing;

test "create org: slugify" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("fast-express-1", slugify(arena.allocator(), "  Fast Express #1! "));
    try testing.expectEqualStrings("", slugify(arena.allocator(), "شركة"));
}

test "create org: choose, name, check the address, create" {
    const app = @import("../app.zig");
    try app.startSignedIn("/app/new");
    defer app.D.reset();
    try testing.expect(app.D.findText("Add another company") != 0);
    try testing.expect(app.D.findText("Company name") == 0);
    try app.D.press("I run a shipping company");
    try testing.expect(app.D.findText("Create my shipping company") != 0);
    try app.D.typeInto("", "Fast Express");
    const c = app.D.R.appState();
    try testing.expectEqualStrings("fast-express", c.val(f_slug));
    app.D.R.dispatch(.{ .timer = .{ .gen = c.gen, .id = T_SLUG } });
    try testing.expect(app.D.respond("/api/app/slug-available?slug=fast-express", 200, "{\"available\":false}"));
    try testing.expect(app.D.findText("This address is already taken.") != 0);
    app.D.R.dispatch(kit.act(A.terms, 0));
    try app.D.press("Create my shipping company");
    const sent = zui.host.fetches.items[zui.host.fetches.items.len - 1];
    try testing.expectEqualStrings("{\"type\":\"carrier\",\"name\":\"Fast Express\",\"slug\":\"fast-express\",\"acceptTerms\":true}", sent.body);
    try testing.expect(app.D.respond("/api/app/orgs", 400, "{\"error\":{\"code\":\"conflict\",\"message\":\"This address is already taken.\",\"field\":\"slug\"}}"));
    try testing.expectEqualStrings("slug", c.field_err.?.field);
    // Shown under the address field, so not toasted as well; a field the form lacks is.
    try testing.expectEqual(@as(usize, 0), c.toasts.items.len);
    // Enter in a field sends the form too (the form's submit).
    try app.D.inputEvent("09xx xxx xxx", .submit);
    try testing.expect(app.D.respond("/api/app/orgs", 201, "{\"slug\":\"fast-express\"}"));
    try testing.expectEqualStrings("/o/fast-express", app.D.R.appState().baseStr());
}
