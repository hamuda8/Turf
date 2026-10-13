//! Small pieces shared by the console pages ported from Turf-js's carrier, merchant and shared
//! views: translated templates, the express badge and due time, bullets, keeping an action's
//! answer in a data slot, and lists of names from the platform data.

const std = @import("std");
const zui = @import("zui");
const core = @import("../core.zig");
const kit = @import("../kit.zig");
const json = @import("../json.zig");
const fmt = @import("../fmt.zig");
const icons = @import("../icons.zig");
const labels = @import("../labels.zig");

const Cx = core.Cx;
const Ui = core.Ui;
const V = json.V;

/// `t(key, params)` while drawing: the key's English template, translated and filled.
pub fn tx(ui: *Ui, comptime key: []const u8, args: anytype) []const u8 {
    return ui.tf(labels.english(key) orelse key, args);
}

/// `t(key, params)` in `update` (page memory).
pub fn txc(c: *Cx, comptime key: []const u8, args: anytype) []const u8 {
    return zui.i18n.tf(c.arena(), labels.english(key) orelse key, args);
}

/// Keeps an action's answer (`d.body`) in data slot `n`, as if it had been loaded there.
pub fn keep(c: *Cx, n: u8, body: []const u8) void {
    const slot = &c.slots[n];
    slot.reset();
    slot.value = json.parse(slot.arena.allocator(), body);
    slot.state = .ok;
}

/// Marks slot `n` as loading (an answer that comes back through `.done`).
pub fn pending(c: *Cx, n: u8) void {
    const slot = &c.slots[n];
    slot.reset();
    slot.state = .loading;
}

/// Marks slot `n` as failed with the error of a `.done`.
pub fn fail(c: *Cx, n: u8, d: core.Done) void {
    const slot = &c.slots[n];
    slot.reset();
    slot.state = .failed;
    slot.err = c.dupe(core.errorMessage(c.arena(), d.status, d.v, false));
}

/// A parcel or task sent express (`isExpress`).
pub fn isExpress(x: ?V) bool {
    if (std.mem.eql(u8, json.str(x, "service"), "express")) return true;
    const e = json.get(x, "express") orelse return false;
    return e == .bool and e.bool;
}

/// "Due by 14:05" / "Late: was due by 14:05" (`dueLabel`), in the action colour or red.
pub fn dueLabel(ui: *Ui, due_by: []const u8) void {
    if (due_by.len == 0) return;
    const ms = fmt.parseIso(due_by) orelse return;
    const late = ms < fmt.now();
    const color = if (late) kit.k.fatal_ink else kit.k.a;
    ui.begin(.{ .direction = .row, .gap = 4, .align_items = .center }, .{});
    kit.icon(ui, icons.timer, 16, color);
    const time = fmt.time(ui.arena(), due_by);
    ui.text(if (late) tx(ui, "express.late", .{ .time = time }) else tx(ui, "express.due", .{ .time = time }), .{ .font_size = 15, .weight = 750, .color = color, .max_lines = 1 });
    ui.end();
}

/// A bullet line (`<li>`).
pub fn bullet(ui: *Ui, s: []const u8) void {
    ui.begin(.{ .direction = .row, .gap = 8, .align_items = .start }, .{});
    ui.text("\u{2022}", .{ .font_size = 15, .color = kit.k.ink_2 });
    ui.text(s, .{ .font_size = 15, .color = kit.k.ink, .grow = 1 });
    ui.end();
}

/// A muted paragraph without margins (`p.muted`).
pub fn intro(ui: *Ui, s: []const u8) void {
    kit.muted(ui, s);
}

/// The vehicle types of the platform (`Object.keys(meta.vehicles)`; a list is accepted too).
pub fn vehicles(c: *const Cx, a: std.mem.Allocator) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const v = json.get(c.meta.value, "vehicles") orelse return &.{};
    switch (v) {
        .object => |o| for (o.keys()) |key| out.append(a, key) catch {},
        .array => |l| for (l.items) |x| if (x == .string) out.append(a, x.string) catch {},
        else => {},
    }
    return out.items;
}

/// The governorates as drop-down options (code -> name in the user's language).
pub fn govOptions(c: *const Cx, a: std.mem.Allocator) []const core.Opt {
    var out: std.ArrayList(core.Opt) = .empty;
    for (json.arr(c.meta.value, "governorates")) |g| out.append(a, .{ .value = json.str(g, "code"), .label = json.pick(g, "", c.lang()) }) catch {};
    return out.items;
}

/// The governorate's entry in the platform data.
pub fn govEntry(c: *const Cx, code: []const u8) ?V {
    for (json.arr(c.meta.value, "governorates")) |g| if (std.mem.eql(u8, json.str(g, "code"), code)) return g;
    return null;
}

/// A list of ids kept in page memory (selections).
pub const IdSet = struct {
    items: std.ArrayList([]const u8) = .empty,

    pub fn has(s: *const IdSet, id: []const u8) bool {
        for (s.items.items) |x| if (std.mem.eql(u8, x, id)) return true;
        return false;
    }

    pub fn add(s: *IdSet, c: *Cx, id: []const u8) void {
        if (id.len == 0 or s.has(id)) return;
        s.items.append(c.arena(), c.dupe(id)) catch {};
    }

    pub fn remove(s: *IdSet, id: []const u8) void {
        for (s.items.items, 0..) |x, i| if (std.mem.eql(u8, x, id)) {
            _ = s.items.orderedRemove(i);
            return;
        };
    }

    pub fn toggle(s: *IdSet, c: *Cx, id: []const u8) void {
        if (s.has(id)) s.remove(id) else s.add(c, id);
    }

    pub fn count(s: *const IdSet) usize {
        return s.items.items.len;
    }

    pub fn clear(s: *IdSet) void {
        s.items.clearRetainingCapacity();
    }
};

/// The id of an API document (`_id`, or `id`).
pub fn docId(v: ?V) []const u8 {
    return json.strOr(v, "_id", json.str(v, "id"));
}

/// A `{ "<name>": value }` object, for `core.fill`.
pub fn params1(c: *Cx, name: []const u8, value: []const u8) ?V {
    var m: std.json.ObjectMap = .empty;
    m.put(c.arena(), name, .{ .string = value }) catch {};
    return .{ .object = m };
}

/// The `.danger-zone` card: a red ring.
pub fn dangerCard(ui: *Ui) void {
    kit.card(ui, .{ .gap = 8.8, .ring = kit.k.f.withAlpha(0.45) });
}

test "ids and express" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = json.parse(arena.allocator(), "{\"_id\":\"a\",\"service\":\"express\"}");
    try std.testing.expectEqualStrings("a", docId(v));
    try std.testing.expect(isExpress(v));
    const w = json.parse(arena.allocator(), "{\"id\":\"b\",\"express\":true}");
    try std.testing.expectEqualStrings("b", docId(w));
    try std.testing.expect(isExpress(w));
}
