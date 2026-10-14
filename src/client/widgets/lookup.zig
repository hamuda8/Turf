//! The tracking search (Turf-js core/lookup.js): the search box of the home page, the public
//! /track page and the app's Track page, and the result cards (status, progress, route, the
//! carrier, the history). Anyone can look up parcels by tracking number (up to 10 at once); a
//! pasted tracking link (/t/<token>) opens the full tracking page instead.
//!
//! A page keeps a `Search` (the box) and a `Results` (what came back) in its state and gives them
//! a form slot, a data slot and action ids.

const std = @import("std");
const zui = @import("zui");
const core = @import("../core.zig");
const kit = @import("../kit.zig");
const json = @import("../json.zig");
const fmt = @import("../fmt.zig");
const icons = @import("../icons.zig");
const labels = @import("../labels.zig");
const theme = @import("../theme.zig");

const Cx = core.Cx;
const Ui = core.Ui;
const V = json.V;
const L = labels.k;
const Color = zui.Color;

pub const max_numbers = 10;
const steps = [_][]const u8{ "awaiting_pickup", "picked_up", "in_transit", "out_for_delivery", "delivered" };
const stopped = [_][]const u8{ "cancelled", "returned", "returning", "lost" };

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn inList(s: []const u8, list: []const []const u8) bool {
    for (list) |x| if (eq(s, x)) return true;
    return false;
}

/// The step of a status on the 5-step bar (`stepOf`); -1 for none.
pub fn stepOf(status: []const u8) i32 {
    if (eq(status, "awaiting_carrier")) return 0;
    if (eq(status, "at_hub")) return 2;
    if (eq(status, "delivery_failed")) return 3;
    for (steps, 0..) |s, i| if (eq(s, status)) return @intCast(i);
    return -1;
}

/// The `--st` colour of a status (`.st-<status>`), or null (the line colour).
pub fn stColor(status: []const u8) ?Color {
    const known = [_][]const u8{ "awaiting_pickup", "pending", "awaiting_carrier", "picked_up", "assigned", "accepted", "at_hub", "in_transit", "in_progress", "out_for_delivery", "delivered", "completed", "delivery_failed", "failed", "lost", "returning", "returned", "cancelled" };
    if (!inList(status, &known)) return null;
    return theme.status(&kit.k, status);
}

/// The tracking link's token when the text is (or contains) one, else null.
pub fn linkToken(text: []const u8) ?[]const u8 {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, text, from, "/t/")) |at| {
        from = at + 1;
        const start = at + 3;
        var end = start;
        while (end < text.len and (std.ascii.isAlphanumeric(text[end]) or text[end] == '_' or text[end] == '-')) end += 1;
        const n = end - start;
        if (n < 16 or n > 40) continue;
        if (end < text.len and text[end] != '/' and text[end] != '?' and text[end] != '#') continue;
        return text[start..end];
    }
    return null;
}

fn isSep(text: []const u8, i: usize) usize {
    // "\n", ",", ";" and the Arabic comma (U+060C, two bytes).
    if (text[i] == '\n' or text[i] == ',' or text[i] == ';' or text[i] == '\r') return 1;
    if (i + 1 < text.len and text[i] == 0xD8 and text[i + 1] == 0x8C) return 2;
    return 0;
}

fn long(w: []const u8) bool {
    var n: usize = 0;
    for (w) |ch| if (std.ascii.isAlphanumeric(ch)) {
        n += 1;
    };
    return n >= 10;
}

/// Tracking numbers in typed or pasted text, without repeats: commas, semicolons and new lines
/// separate them, spaces only when each part is a whole number (`splitNumbers`).
pub fn splitNumbers(a: std.mem.Allocator, text: []const u8) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    var chunk_start: usize = 0;
    while (i <= text.len) {
        const sep = if (i < text.len) isSep(text, i) else 1;
        if (sep == 0) {
            i += 1;
            continue;
        }
        const chunk = text[chunk_start..@min(i, text.len)];
        i += sep;
        chunk_start = i;
        var words: std.ArrayList([]const u8) = .empty;
        var it = std.mem.tokenizeAny(u8, chunk, " \t");
        while (it.next()) |w| words.append(a, w) catch {};
        var all_long = words.items.len > 1;
        for (words.items) |w| if (!long(w)) {
            all_long = false;
        };
        if (all_long) {
            for (words.items) |w| addUnique(a, &out, w);
        } else {
            var joined: std.ArrayList(u8) = .empty;
            for (words.items) |w| joined.appendSlice(a, w) catch {};
            addUnique(a, &out, joined.items);
        }
    }
    return out.items;
}

fn addUnique(a: std.mem.Allocator, out: *std.ArrayList([]const u8), w: []const u8) void {
    if (w.len == 0) return;
    const up = a.dupe(u8, w) catch return;
    for (up) |*ch| ch.* = std.ascii.toUpper(ch.*);
    for (out.items) |x| if (eq(x, up)) return;
    out.append(a, up) catch {};
}

/// "TRF1,TRF2" for addresses.
pub fn join(a: std.mem.Allocator, list: []const []const u8, sep: []const u8) []const u8 {
    return std.mem.join(a, sep, list) catch "";
}

// ---- The search box -----------------------------------------------------------------------

pub const Search = struct {
    /// The form slot of the box.
    slot: u16,
    /// The page's action for "Track" (and Enter).
    act: u16,
    /// The hint turned into an error ("Enter a tracking number first").
    err: []const u8 = "",

    pub const Outcome = union(enum) { none, numbers: []const []const u8 };

    /// The box was submitted: a tracking link opens its page; otherwise the numbers to look
    /// up (in page memory), or nothing (the hint says why).
    pub fn submit(f: *Search, c: *Cx) Outcome {
        const value = c.val(f.slot);
        if (linkToken(value)) |token| {
            c.openLink(c.print("/t/{s}", .{token}));
            return .none;
        }
        const numbers = splitNumbers(c.arena(), value);
        if (numbers.len == 0) {
            f.err = L("lookup.empty");
            return .none;
        }
        if (numbers.len > max_numbers) {
            f.err = zui.i18n.tf(c.arena(), labels.english("lookup.too_many") orelse "{n}", .{ .n = max_numbers });
            return .none;
        }
        f.err = "";
        return .{ .numbers = numbers };
    }

    /// Fills the box with the numbers of the address.
    pub fn prefill(f: *Search, c: *Cx, numbers: []const []const u8) void {
        c.setVal(f.slot, join(c.arena(), numbers, ", "));
    }
};

pub const FormOpts = struct {
    /// The large version on the home page.
    hero: bool = false,
    /// The button spins while this action runs.
    busy: ?u16 = null,
    /// On the dark tracking panel of the home page.
    on_rail: bool = false,
};

/// `.lookup-form`: the bar (icon, box, Track) and the hint below it.
pub fn form(ui: *Ui, f: *const Search, o: FormOpts) void {
    const k = kit.k;
    const has_err = f.err.len > 0;
    ui.begin(.{ .gap = 7.2, .width = .fill }, .{});
    ui.begin(.{
        .direction = .row,
        .align_items = .center,
        .gap = 8,
        .padding = .{ .top = if (o.hero) 8 else 6.4, .bottom = if (o.hero) 8 else 6.4, .start = if (o.hero) 19.2 else 16, .end = if (o.hero) 8 else 6.4 },
        .background = k.panel,
        .radius = 28,
        .shadow = kit.shadow2(),
        .border_width = if (has_err) 2 else if (k.dark) 1 else 0,
        .border_color = if (has_err) k.f else k.line,
    }, .{});
    kit.icon(ui, icons.package_2, 24, k.a);
    kit.input(ui, f.slot, .{
        .placeholder = L("lookup.placeholder"),
        .ltr = true,
        // The number in the monospace font; the placeholder in the text font, as the CSS has it.
        .mono = kit.cx.val(f.slot).len > 0,
        .grow = 1,
        .size = if (o.hero) 17.6 else 16,
        .height = 44,
        .bare = true,
        .on_submit = .{ .act = .{ .id = f.act } },
    });
    kit.button(ui, L("lookup.track"), .{ .act = .{ .id = f.act } }, .{ .variant = .primary, .icon = icons.search, .size = if (o.hero) .lg else .md, .busy = o.busy });
    ui.end();
    ui.begin(.{ .padding = .xy(17.6, 0) }, .{});
    if (has_err)
        ui.text(f.err, .{ .font_size = 12.8, .weight = 650, .color = if (o.on_rail) k.rail_ink else k.fatal_ink })
    else
        ui.text(ui.tf(labels.english("lookup.hint") orelse "{n}", .{ .n = max_numbers }), .{ .font_size = 12.8, .color = if (o.on_rail) k.rail_ink_2 else k.ink_3 });
    ui.end();
    ui.end();
}

// ---- Results ------------------------------------------------------------------------------

pub const Results = struct {
    /// The data slot the answer is kept in.
    slot: u8,
    /// The action id that marks the search busy (the Track button spins).
    busy: u16,
    /// The page's action for opening/closing a card's history (arg = index).
    act_history: u16,
    /// Cards whose history is open.
    open: u32 = 0,
    searched: bool = false,

    /// Asks for `numbers` (`lookup`); only the newest answer is kept.
    pub fn search(r: *Results, c: *Cx, numbers: []const []const u8) void {
        r.open = 0;
        r.searched = true;
        c.busy.put(core.gpa, r.busy, {}) catch {};
        const n = core.encode(c.arena(), join(c.arena(), numbers, ","));
        c.load(r.slot, c.publicUrl(c.print("/lookup?n={s}&lang={s}", .{ n, c.lang() })));
    }

    /// The page got `.data` for the slot.
    pub fn loaded(r: *Results, c: *Cx) void {
        _ = c.busy.remove(r.busy);
        r.open = 0;
    }

    pub fn toggle(r: *Results, i: u32) void {
        if (i < 32) r.open ^= @as(u32, 1) << @intCast(i);
    }

    pub fn list(r: *const Results, c: *const Cx) []const V {
        return json.arr(c.data(r.slot), "results");
    }
};

pub const ResultsOpts = struct {
    /// Per result, the address of its shipment in the company ("" for none): "Open shipment".
    open_links: []const []const u8 = &.{},
};

/// The results area: a spinner while asking, the cards, or the error.
pub fn results(ui: *Ui, c: *const Cx, r: *const Results, o: ResultsOpts) void {
    if (!r.searched) return;
    const sl = c.slot(r.slot);
    if (sl.state == .loading or sl.reloading) return kit.loading(ui);
    if (sl.state == .failed or sl.err.len > 0) {
        kit.notice(ui, .err, sl.err);
        return;
    }
    if (sl.state != .ok) return;
    ui.begin(.{ .gap = 16 }, .{});
    for (r.list(c), 0..) |x, i| {
        const link = if (i < o.open_links.len) o.open_links[i] else "";
        if (json.boolean(x, "found")) resultCard(ui, c, r, x, @intCast(i), link) else notFoundCard(ui, x, i);
    }
    ui.end();
}

/// A card with a 4-point coloured edge on top (`border-top: 4px solid var(--st)`).
fn topCardBegin(ui: *Ui, edge: Color, key: u64) void {
    ui.begin(.{ .radius = 22, .background = kit.k.panel, .clip = true }, .{ .key = key });
    ui.begin(.{ .height = .{ .px = 4 }, .background = edge }, .{});
    ui.end();
    ui.begin(.{ .padding = .{ .top = 16, .bottom = 20, .start = 20, .end = 20 }, .gap = 13.6 }, .{});
}

fn topCardEnd(ui: *Ui) void {
    ui.end();
    ui.end();
}

/// "Damascus، Rif Dimashq" without repeats.
fn place(ui: *Ui, c: *const Cx, p: ?V) []const u8 {
    const x = p orelse return "";
    if (x != .object) return "";
    const city = json.str(x, "city");
    const g = json.str(x, if (c.ar()) "governorateName.ar" else "governorateName.en");
    if (city.len > 0 and g.len > 0 and !eq(city, g)) return kit.f(ui, "{s}، {s}", .{ city, g });
    return if (city.len > 0) city else g;
}

fn etaText(ui: *Ui, r: V) []const u8 {
    const status = json.str(r, "status");
    if (eq(status, "delivered")) return ui.tf(labels.english("track.delivered_at") orelse "{when}", .{ .when = fmt.dateTime(ui.arena(), json.str(r, "deliveredAt")) });
    if (inList(status, &stopped)) return "";
    if (json.str(r, "scheduledFor").len > 0) return ui.tf(labels.english("lookup.scheduled") orelse "{day}", .{ .day = json.str(r, "scheduledFor") });
    if (json.str(r, "promisedBy").len > 0) return ui.tf(labels.english("track.expected_by") orelse "{when}", .{ .when = fmt.dateTime(ui.arena(), json.str(r, "promisedBy")) });
    return "";
}

/// The 5 bars of the progress (`.progress`).
pub fn progress(ui: *Ui, step: i32, color: Color) void {
    ui.begin(.{ .direction = .row, .gap = 4.8 }, .{});
    for (0..steps.len) |i| {
        ui.begin(.{ .width = .fill, .height = .{ .px = 6 }, .radius = 3, .background = if (@as(i32, @intCast(i)) <= step) color else kit.k.panel_3 }, .{});
        ui.end();
    }
    ui.end();
}

fn resultCard(ui: *Ui, c: *const Cx, r: *const Results, x: V, i: u32, open_link: []const u8) void {
    const k = kit.k;
    const status = json.str(x, "status");
    const st = stColor(status);
    const step = stepOf(status);
    const is_stopped = inList(status, &stopped);
    const eta = etaText(ui, x);
    const events = json.arr(x, "events");
    const tn = json.str(x, "trackingNumber");
    topCardBegin(ui, st orelse k.line, zui.key(i + 300));

    // Head: number, status, copy (and "Open shipment" inside a company).
    ui.begin(.{ .direction = .row, .align_items = .start, .justify = .space_between, .gap = 12 }, .{});
    ui.begin(.{ .grow = 1, .gap = 2.4 }, .{});
    ui.begin(.{ .direction = .row, .gap = 6.4, .align_items = .center }, .{});
    ui.text(tn, .{ .font_size = 14.4, .mono = true, .color = k.ink_2 });
    if (eq(json.str(x, "service"), "express")) kit.expressBadge(ui);
    ui.end();
    ui.text(json.str(x, if (c.ar()) "statusTextAr" else "statusTextEn"), .{ .font_size = if (ui.env.width < 600) 21.6 else 27.2, .weight = 850, .line_height = 1.1, .color = st orelse k.ink });
    ui.end();
    ui.begin(.{ .direction = .row, .gap = 6.4 }, .{});
    kit.copyButton(ui, tn, null);
    if (open_link.len > 0) kit.button(ui, L("lookup.open_shipment"), .{ .go = ui.arena().dupe(u8, open_link) catch open_link }, .{ .size = .sm, .variant = .primary, .icon = icons.open_in_new, .flip = true });
    ui.end();
    ui.end();

    if (eta.len > 0) {
        ui.begin(.{ .direction = .row, .gap = 6.4, .align_items = .center }, .{});
        kit.icon(ui, if (eq(status, "delivered")) icons.check else icons.schedule, 20, st orelse k.a);
        ui.text(eta, .{ .font_size = 15, .weight = 650, .color = k.ink, .grow = 1 });
        ui.end();
    }
    if (!is_stopped) {
        progress(ui, step, st orelse k.a);
        if (ui.env.width > 520) {
            ui.begin(.{ .direction = .row, .gap = 4.8 }, .{});
            for (steps, 0..) |s, j| {
                const on = @as(i32, @intCast(j)) <= step;
                ui.begin(.{ .width = .fill }, .{});
                ui.text(labels.of("lookup.step_", s), .{ .font_size = 11.2, .line_height = 1.25, .weight = if (on) 650 else 400, .color = if (on) k.ink_2 else k.ink_3 });
                ui.end();
            }
            ui.end();
        }
    }

    const from = place(ui, c, json.obj(x, "from"));
    const to = place(ui, c, json.obj(x, "to"));
    if (from.len > 0 or to.len > 0) {
        ui.begin(.{ .padding = .xy(13.6, 9.6), .background = k.panel_2, .radius = 16 }, .{});
        var w = kit.Wrap.begin(ui, kit.width - 40 - 27.2, 9.6);
        const fs = if (from.len > 0) from else "—";
        const ts = if (to.len > 0) to else "—";
        w.item(kit.estimate(fs, 15) + 24);
        placePart(ui, icons.store, fs);
        w.item(20);
        kit.iconFlip(ui, icons.arrow_forward, 18, k.ink_3);
        w.item(kit.estimate(ts, 15) + 24);
        placePart(ui, icons.location_on, ts);
        w.end();
        ui.end();
    }

    // The carrier.
    ui.begin(.{ .direction = .row, .align_items = .center, .gap = 11.2 }, .{});
    kit.logo(ui, json.obj(x, "carrier"), 32, 9);
    ui.begin(.{ .grow = 1, .gap = 1 }, .{});
    kit.strong(ui, json.str(x, "carrier.name"));
    kit.small(ui, ui.tf(labels.english("track.order_from") orelse "{merchant}", .{ .merchant = json.str(x, "merchant.name") }));
    ui.end();
    const phone = json.str(x, "carrier.phone");
    if (phone.len > 0) kit.button(ui, phone, .{ .open = kit.f(ui, "tel:{s}", .{phone}) }, .{ .size = .sm, .icon = icons.call });
    ui.end();

    // The history: the latest update, all of them when opened.
    if (events.len > 0) {
        const latest = events[events.len - 1];
        const is_open = i < 32 and (r.open >> @intCast(i)) & 1 == 1;
        kit.line(ui, k.line_soft);
        ui.begin(.{ .direction = .row, .align_items = .center, .gap = 9.6, .pressed_opacity = 0.7 }, .{ .on_press = .{ .act = .{ .id = r.act_history, .arg = i } } });
        ui.text(json.str(latest, if (c.ar()) "textAr" else "textEn"), .{ .font_size = 15, .weight = 650, .color = k.ink, .grow = 1 });
        ui.text(fmt.relative(ui.arena(), json.str(latest, "at")), .{ .font_size = 13.6, .color = k.ink_2, .max_lines = 1 });
        if (events.len > 1 and !is_open) ui.text(ui.tf(labels.english("lookup.all_updates") orelse "{n}", .{ .n = events.len }), .{ .font_size = 13.6, .weight = 700, .color = k.a, .max_lines = 1 });
        ui.end();
        if (is_open) {
            ui.begin(.{ .padding = .{ .top = 4 } }, .{});
            var j: usize = events.len;
            while (j > 0) {
                j -= 1;
                const e = events[j];
                kit.timelineItem(ui, json.str(e, if (c.ar()) "textAr" else "textEn"), fmt.dateTime(ui.arena(), json.str(e, "at")), .{ .current = j == events.len - 1, .last = j == 0 });
            }
            ui.end();
        }
    }

    ui.begin(.{ .direction = .row, .gap = 5.6, .align_items = .start }, .{});
    kit.icon(ui, icons.lock, 16, k.ink_2);
    ui.text(L("lookup.link_hint"), .{ .font_size = 13.6, .color = k.ink_2, .grow = 1 });
    ui.end();
    topCardEnd(ui);
}

fn placePart(ui: *Ui, ic: zui.Icon, s: []const u8) void {
    ui.begin(.{ .direction = .row, .gap = 4, .align_items = .center }, .{});
    kit.icon(ui, ic, 18, kit.k.ink_3);
    ui.text(s, .{ .font_size = 15, .weight = 600, .color = kit.k.ink });
    ui.end();
}

fn notFoundCard(ui: *Ui, x: V, i: usize) void {
    const k = kit.k;
    topCardBegin(ui, k.line, zui.key(i + 300));
    ui.begin(.{ .direction = .row, .gap = 12, .align_items = .start }, .{});
    kit.avatar(ui, icons.search);
    ui.begin(.{ .grow = 1, .gap = 3.2 }, .{});
    ui.text(json.str(x, "query"), .{ .font_size = 14.4, .weight = 700, .mono = true, .color = k.ink_2 });
    kit.text(ui, L("lookup.not_found"), .{});
    kit.small(ui, L("lookup.not_found_hint"));
    ui.end();
    ui.end();
    topCardEnd(ui);
}

test "tracking numbers and links" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const l = splitNumbers(a, "trf123, TRF123\nTRF9 ;x");
    try std.testing.expectEqual(@as(usize, 3), l.len);
    try std.testing.expectEqualStrings("TRF123", l[0]);
    try std.testing.expectEqualStrings("TRF9", l[1]);
    // Spaces separate only whole numbers.
    try std.testing.expectEqual(@as(usize, 2), splitNumbers(a, "TRF1234567890 TRF0987654321").len);
    try std.testing.expectEqualStrings("TRF12AB", splitNumbers(a, "TRF 12 AB")[0]);
    try std.testing.expectEqual(@as(usize, 2), splitNumbers(a, "A،B").len);
    try std.testing.expectEqualStrings("abcdefghijklmnop1234", linkToken("https://x.com/t/abcdefghijklmnop1234?lang=ar").?);
    try std.testing.expectEqualStrings("abcdefghijklmnop", linkToken("/embed/t/abcdefghijklmnop").?);
    try std.testing.expect(linkToken("/t/short") == null);
    try std.testing.expectEqual(@as(i32, 2), stepOf("at_hub"));
    try std.testing.expectEqual(@as(i32, -1), stepOf("cancelled"));
}
