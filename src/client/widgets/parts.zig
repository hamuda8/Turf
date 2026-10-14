//! Building blocks shared by the carrier and merchant shipment pages (Turf-js
//! views/shared/shipment-parts.js): address, parcel, timeline, relay route and feedback cards,
//! key/value rows and the short place text.

const std = @import("std");
const zui = @import("zui");
const core = @import("../core.zig");
const kit = @import("../kit.zig");
const json = @import("../json.zig");
const fmt = @import("../fmt.zig");
const icons = @import("../icons.zig");
const labels = @import("../labels.zig");

const Ui = core.Ui;
const V = json.V;
const L = labels.k;

/// The governorate's name in the user's language (from meta.governorates), or the code.
pub fn gov(c: *const core.Cx, code: []const u8) []const u8 {
    for (json.arr(c.meta.value, "governorates")) |g| {
        if (std.mem.eql(u8, json.str(g, "code"), code)) return json.pick(g, "", c.lang());
    }
    return code;
}

fn sameName(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, a, " "), std.mem.trim(u8, b, " "));
}

/// "Mazzeh · Damascus" without repeating the governorate when the city has the same name.
pub fn placeText(a: std.mem.Allocator, c: *const core.Cx, addr: ?V, o: struct { area: bool = false }) []const u8 {
    const x = addr orelse return "";
    if (x != .object) return "";
    const g = gov(c, json.str(x, "governorate"));
    const city = json.str(x, "city");
    var out: std.ArrayList(u8) = .empty;
    const parts = [_][]const u8{ if (o.area) json.str(x, "area") else "", city, if (city.len > 0 and g.len > 0 and sameName(city, g)) "" else g };
    for (parts) |p| {
        if (p.len == 0) continue;
        if (out.items.len > 0) out.appendSlice(a, " · ") catch {};
        out.appendSlice(a, p) catch {};
    }
    return out.items;
}

/// The street, area, city and governorate joined with "، ".
pub fn addressLine(a: std.mem.Allocator, c: *const core.Cx, x: ?V) []const u8 {
    const g = gov(c, json.str(x, "governorate"));
    const city = json.str(x, "city");
    var out: std.ArrayList(u8) = .empty;
    const parts = [_][]const u8{ json.str(x, "street"), json.str(x, "area"), city, if (city.len > 0 and sameName(city, g)) "" else g };
    for (parts) |p| {
        if (p.len == 0) continue;
        if (out.items.len > 0) out.appendSlice(a, "، ") catch {};
        out.appendSlice(a, p) catch {};
    }
    return out.items;
}

/// An address card: name, phone (tap to call), address, details, whether it has a pin.
pub fn addressBlock(ui: *Ui, c: *const core.Cx, title: []const u8, a: ?V) void {
    const x = a orelse return;
    if (x != .object) return;
    const k = kit.k;
    kit.card(ui, .{ .gap = 8.8 });
    kit.h2(ui, title);
    if (json.str(x, "name").len > 0) kit.strong(ui, json.str(x, "name"));
    const phone = json.str(x, "phone");
    if (phone.len > 0) {
        ui.begin(.{ .direction = .row, .gap = 5.6, .align_items = .center, .align_self = .start, .pressed_opacity = 0.6, .no_mirror = true }, .{ .on_press = .{ .open = kit.f(ui, "tel:{s}", .{phone}) } });
        kit.icon(ui, icons.call, 20, k.a);
        ui.text(phone, .{ .font_size = 15, .weight = 600, .color = k.a });
        ui.end();
    }
    kit.text(ui, addressLine(ui.arena(), c, x), .{});
    if (json.str(x, "details").len > 0) kit.small(ui, json.str(x, "details"));
    ui.begin(.{ .direction = .row, .gap = 4, .align_items = .center }, .{});
    if (json.has(x, "location")) {
        kit.icon(ui, icons.location_on, 16, k.ink_2);
        kit.small(ui, L("shipment.has_location"));
    } else kit.small(ui, L("shipment.no_location"));
    ui.end();
    kit.endCard(ui, .{});
}

/// The history, newest first (events are oldest first; internal ones only for staff).
pub fn timeline(ui: *Ui, c: *const core.Cx, events: []const V, o: struct { internal: bool = false }) void {
    var shown: std.ArrayList(V) = .empty;
    for (events) |e| if (o.internal or !json.boolean(e, "internal")) shown.append(ui.arena(), e) catch {};
    ui.begin(.{}, .{});
    var i: usize = shown.items.len;
    var first = true;
    while (i > 0) {
        i -= 1;
        const e = shown.items[i];
        const internal = json.boolean(e, "internal");
        const text = if (c.ar()) json.str(e, "textAr") else json.str(e, "textEn");
        timelineEntry(ui, text, fmt.dateTime(ui.arena(), json.str(e, "at")), first, internal, i == 0);
        first = false;
    }
    ui.end();
}

fn timelineEntry(ui: *Ui, text: []const u8, when: []const u8, current: bool, internal: bool, last: bool) void {
    const k = kit.k;
    ui.begin(.{ .direction = .row, .gap = 16, .opacity = if (internal) 0.75 else 1 }, .{});
    ui.begin(.{ .width = .{ .px = 14 }, .align_items = .center }, .{});
    ui.begin(.{ .width = .{ .px = 14 }, .height = .{ .px = 14 }, .radius = 7, .background = if (current) k.a else k.panel, .border_width = 2, .border_color = if (current) k.a else k.ink_4, .shadow = if (current) .{ .y = 0, .blur = 10, .color = k.a.withAlpha(0.45) } else null }, .{});
    ui.end();
    if (!last) {
        ui.begin(.{ .width = .{ .px = 2 }, .grow = 1, .min_height = 12, .background = k.line }, .{});
        ui.end();
    }
    ui.end();
    ui.begin(.{ .grow = 1, .padding = .{ .bottom = 16.8 }, .gap = 1 }, .{});
    ui.begin(.{ .direction = .row, .gap = 6.4, .align_items = .center }, .{});
    ui.text(text, .{ .font_size = 15, .color = k.ink, .grow = 1 });
    if (internal) kit.badge(ui, L("shipment.internal"), .plain);
    ui.end();
    ui.text(when, .{ .font_size = 12.5, .color = k.ink_3 });
    ui.end();
    ui.end();
}

/// The parcel: weight, pieces, size, fragile, value, description and the notes.
pub fn parcelBlock(ui: *Ui, s: ?V) void {
    const p = json.obj(s, "parcel");
    kit.card(ui, .{ .gap = 8.8 });
    kit.h2(ui, L("shipment.parcel"));
    var w = kit.Wrap.begin(ui, kit.width - 40, 12);
    const a = ui.arena();
    const weight = kit.f(ui, "{s} {s}", .{ fmt.number(a, json.numOr(p, "weightKg", 0), 2), L("unit.kg") });
    w.item(kit.estimate(weight, 12) + 21);
    kit.badge(ui, weight, .plain);
    const pieces = ui.tf(labels.english("shipment.pieces_n") orelse "{n} pieces", .{ .n = json.int(p, "pieces") });
    w.item(kit.estimate(pieces, 12) + 21);
    kit.badge(ui, pieces, .plain);
    if (json.obj(p, "dimensionsCm")) |d| {
        const dims = kit.f(ui, "{s} × {s} × {s} {s}", .{ fmt.number(a, json.numOr(d, "length", 0), 1), fmt.number(a, json.numOr(d, "width", 0), 1), fmt.number(a, json.numOr(d, "height", 0), 1), L("unit.cm") });
        w.item(kit.estimate(dims, 12) + 21);
        kit.badge(ui, dims, .plain);
    }
    if (json.boolean(p, "fragile")) {
        w.item(kit.estimate(L("shipment.fragile"), 12) + 21);
        kit.badge(ui, L("shipment.fragile"), .amber);
    }
    if (json.num(p, "value")) |v| if (v != 0) {
        const value = kit.f(ui, "{s}: {s}", .{ L("shipment.value"), fmt.money(a, v, json.str(s, "price.currency")) });
        w.item(kit.estimate(value, 12) + 21);
        kit.badge(ui, value, .plain);
    };
    w.end();
    if (json.str(p, "description").len > 0) kit.text(ui, json.str(p, "description"), .{});
    if (json.str(s, "notes").len > 0) {
        kit.noticeBegin(ui, .info, icons.edit);
        kit.text(ui, json.str(s, "notes"), .{});
        kit.noticeEnd(ui);
    }
    kit.endCard(ui, .{});
}

/// A key/value row (`kv`).
pub fn kv(ui: *Ui, label: []const u8, value: []const u8) void {
    kit.kv(ui, label, value, false);
}

/// The relay route: the companies carrying the parcel in turn, with the handover points.
pub fn routeBlock(ui: *Ui, c: *const core.Cx, legs: []const V, o: struct { highlight: []const u8 = "" }) void {
    const k = kit.k;
    kit.card(ui, .{ .gap = 8.8 });
    kit.h2(ui, L("route.title"));
    kit.small(ui, L("route.intro"));
    for (legs, 0..) |l, i| {
        const name = json.str(l, "name");
        const bold = o.highlight.len > 0 and std.mem.eql(u8, o.highlight, name);
        ui.begin(.{ .direction = .row, .gap = 8, .align_items = .start }, .{ .key = zui.key(i + 1) });
        ui.text(kit.f(ui, "{d}.", .{i + 1}), .{ .font_size = 15, .color = k.ink_2 });
        ui.begin(.{ .grow = 1, .gap = 2 }, .{});
        ui.begin(.{ .direction = .row, .justify = .space_between, .align_items = .center, .gap = 8 }, .{});
        ui.begin(.{ .direction = .row, .gap = 4.8, .align_items = .center, .grow = 1 }, .{});
        ui.text(kit.f(ui, "{s}: {s}", .{ name, gov(c, json.str(l, "from")) }), .{ .font_size = 15, .weight = if (bold) 600 else 400, .color = k.ink });
        kit.iconFlip(ui, icons.arrow_forward, 16.5, k.ink_2);
        ui.text(if (json.str(l, "to").len > 0) gov(c, json.str(l, "to")) else L("route.recipient"), .{ .font_size = 15, .weight = if (bold) 600 else 400, .color = k.ink });
        ui.end();
        const st = json.str(l, "status");
        kit.badge(ui, labels.of("route.status.", st), if (std.mem.eql(u8, st, "done")) .green else if (std.mem.eql(u8, st, "active")) .brand else .plain);
        ui.end();
        if (json.str(l, "hub").len > 0) kit.small(ui, ui.tf(labels.english("route.handover_at") orelse "{hub} {city}", .{ .hub = json.str(l, "hub"), .city = json.str(l, "city") }));
        if (json.obj(l, "price")) |p| kit.small(ui, fmt.money(ui.arena(), json.num(p, "amount"), json.str(p, "currency")));
        ui.end();
        ui.end();
    }
    kit.endCard(ui, .{});
}

/// The recipient's rating or problem report after delivery (nothing when there is none).
pub fn feedbackBlock(ui: *Ui, s: ?V) void {
    const f = json.obj(s, "feedback") orelse return;
    const k = kit.k;
    const problem = json.str(f, "problem");
    kit.card(ui, .{ .gap = 8.8, .ring = if (problem.len > 0) k.warn_ink else null });
    kit.h2(ui, L("feedback.title"));
    const rating = json.int(f, "rating");
    if (rating > 0) {
        ui.begin(.{ .direction = .row, .gap = 1.6 }, .{});
        var i: i64 = 1;
        while (i <= 5) : (i += 1) kit.icon(ui, if (i <= rating) icons.star_fill else icons.star, 22.4, k.warn_ink);
        ui.end();
    }
    if (problem.len > 0) kit.notice(ui, .warn, labels.of("track.problem_", problem));
    const comment = json.str(f, "comment");
    if (comment.len > 0) {
        ui.begin(.{ .direction = .row, .radius = 12, .background = k.panel_2, .clip = true }, .{});
        ui.begin(.{ .width = .{ .px = 3 }, .background = k.a }, .{});
        ui.end();
        ui.begin(.{ .padding = .xy(12.8, 9.6), .grow = 1 }, .{});
        kit.text(ui, comment, .{});
        ui.end();
        ui.end();
    }
    kit.small(ui, fmt.dateTime(ui.arena(), json.str(f, "at")));
    kit.endCard(ui, .{});
}

/// Picking shipments in a list to print their labels at once (`labelSelection`): keep one in
/// the page state; `cell` draws the box for a row, `button` the "Print N labels" button.
pub const LabelPick = struct {
    tokens: std.ArrayList([]const u8) = .empty,

    pub const max = 100;

    /// The token of a label link (".../label/<token>"), or null.
    pub fn tokenOf(path: []const u8) ?[]const u8 {
        const at = std.mem.indexOf(u8, path, "/label/") orelse return null;
        const t = path[at + 7 ..];
        return if (t.len > 0) t else null;
    }

    pub fn has(p: *const LabelPick, token: []const u8) bool {
        for (p.tokens.items) |x| if (std.mem.eql(u8, x, token)) return true;
        return false;
    }

    /// Toggles a token (copied into the page's memory).
    pub fn toggle(p: *LabelPick, c: *core.Cx, token: []const u8) void {
        for (p.tokens.items, 0..) |x, i| if (std.mem.eql(u8, x, token)) {
            _ = p.tokens.orderedRemove(i);
            return;
        };
        if (p.tokens.items.len >= max) return;
        p.tokens.append(c.arena(), c.dupe(token)) catch {};
    }

    pub fn clear(p: *LabelPick) void {
        p.tokens.clearRetainingCapacity();
    }

    /// The address that prints them all, one per page.
    pub fn url(p: *const LabelPick, a: std.mem.Allocator) []const u8 {
        var out: std.ArrayList(u8) = .empty;
        out.appendSlice(a, core.api_base) catch {};
        out.appendSlice(a, "/labels?t=") catch {};
        for (p.tokens.items, 0..) |x, i| {
            if (i > 0) out.append(a, ',') catch {};
            out.appendSlice(a, x) catch {};
        }
        return out.items;
    }

    /// "Print N labels", only while some are picked.
    pub fn button(p: *const LabelPick, ui: *Ui) void {
        if (p.tokens.items.len == 0) return;
        kit.button(ui, ui.tf(labels.english("labels.print_selected") orelse "Print {n} labels", .{ .n = p.tokens.items.len }), .{ .open = p.url(ui.arena()) }, .{ .icon = icons.print });
    }
};

test "the parts draw" {
    const app = @import("../app.zig");
    try app.startSignedIn("/app");
    defer app.D.reset();
    // Exercised through the shipment pages; here only that they compile against a frame.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const c = app.D.R.appState();
    const v = json.parse(arena.allocator(), "{\"city\":\"Damascus\",\"area\":\"Mazzeh\",\"governorate\":\"DAM\"}");
    try std.testing.expectEqualStrings("Mazzeh · Damascus", placeText(arena.allocator(), c, v, .{ .area = true }));
    try std.testing.expectEqualStrings("abc", LabelPick.tokenOf("/o/x/label/abc").?);
    _ = &addressBlock;
    _ = &timeline;
    _ = &parcelBlock;
    _ = &routeBlock;
    _ = &feedbackBlock;
    _ = &LabelPick.button;
}
