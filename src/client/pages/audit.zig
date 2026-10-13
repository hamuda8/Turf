//! Activity log (Turf-js views/shared/audit.js): who changed what in the company, 50 entries at
//! a time ("Load more" asks for the ones before the last shown).

const std = @import("std");
const zui = @import("zui");
const core = @import("../core.zig");
const kit = @import("../kit.zig");
const json = @import("../json.zig");
const fmt = @import("../fmt.zig");
const labels = @import("../labels.zig");

const Cx = core.Cx;
const Ui = core.Ui;
const V = json.V;
const L = labels.k;

const d_first: u8 = 0;

const A = enum(u16) { more = 1 };

pub const S = struct {
    entries: std.ArrayList(V) = .empty,
    more: bool = false,
};

pub fn title(_: *const S, _: *const Cx) []const u8 {
    return L("nav.audit");
}

pub fn enter(_: *S, c: *Cx) void {
    c.load(d_first, c.orgUrl("/audit"));
}

fn add(s: *S, c: *Cx, list: []const V) void {
    for (list) |e| s.entries.append(c.arena(), e) catch {};
    s.more = list.len >= 50;
}

pub fn update(s: *S, c: *Cx, e: core.Ev) void {
    switch (e) {
        .data => |n| if (n == d_first and c.slot(d_first).state == .ok) {
            s.entries.clearRetainingCapacity();
            add(s, c, json.arr(c.data(d_first), ""));
        },
        .act => |a| if (a.id == @intFromEnum(A.more)) {
            const last = json.str(s.entries.items[s.entries.items.len - 1], "at");
            c.send(a.id, .GET, c.orgUrl(c.print("/audit?before={s}", .{core.encode(c.arena(), last)})), "");
        },
        .done => |d| if (d.id == @intFromEnum(A.more) and d.ok) {
            // Kept in the page's memory with the rest.
            const v = json.parse(c.arena(), d.body);
            add(s, c, json.arr(v, ""));
        },
        else => {},
    }
}

/// The entry in words (`describe`): its `audit.<action>` text with the details filled in, or
/// the action itself.
fn describe(ui: *Ui, e: V) []const u8 {
    const a = ui.arena();
    const action = json.str(e, "action");
    const key = std.fmt.allocPrint(a, "audit.{s}", .{action}) catch return action;
    const english = labels.english(key) orelse return action;
    var m: std.json.ObjectMap = .empty;
    if (json.obj(e, "details")) |d| {
        var it = d.object.iterator();
        while (it.next()) |kv| m.put(a, kv.key_ptr.*, kv.value_ptr.*) catch {};
    }
    const d = json.get(e, "details");
    m.put(a, "name", .{ .string = json.strOr(d, "name", json.str(d, "email")) }) catch {};
    m.put(a, "role", .{ .string = json.str(d, "role") }) catch {};
    return core.fill(a, core.t(english), .{ .object = m });
}

pub fn view(s: *const S, c: *const Cx, ui: *Ui) void {
    if (!kit.gate(ui, &.{d_first})) return;
    if (s.entries.items.len == 0) return kit.empty(ui, L("audit.empty"));
    kit.stack(ui);
    var tb = kit.Table.begin(ui, &.{
        .{ .label = L("common.when"), .width = 190 },
        .{ .label = L("audit.who") },
        .{ .label = L("audit.what"), .grow = 2 },
    });
    for (s.entries.items, 0..) |e, i| {
        tb.row(null, zui.key(i + 1));
        tb.cell(true);
        kit.text(ui, fmt.dateTime(ui.arena(), json.str(e, "at")), .{ .lines = 1 });
        tb.endCell();
        tb.cell(true);
        const email = json.str(e, "actor.email");
        kit.text(ui, if (email.len > 0) email else if (json.boolean(e, "actor.system")) L("audit.system") else "—", .{});
        tb.endCell();
        tb.cell(false);
        kit.text(ui, describe(ui, e), .{});
        tb.endCell();
        tb.endRow();
    }
    tb.end();
    if (s.more) {
        ui.begin(.{ .direction = .row, .justify = .center }, .{});
        kit.button(ui, L("common.load_more"), kit.act(A.more, 0), .{ .variant = .ghost, .busy = @intFromEnum(A.more) });
        ui.end();
    }
    ui.end();
    _ = c;
}

// ---- Tests --------------------------------------------------------------------------------

const app = @import("../app.zig");
const testing = std.testing;
const msettings = @import("m_settings.zig");

test "audit: entries in words, and more" {
    try msettings.openMerchant("/audit");
    defer app.D.reset();
    var page: std.ArrayList(u8) = .empty;
    defer page.deinit(testing.allocator);
    try page.appendSlice(testing.allocator, "[");
    for (0..50) |i| {
        if (i > 0) try page.appendSlice(testing.allocator, ",");
        try page.appendSlice(testing.allocator, "{\"at\":\"2025-10-12T10:00:00.000Z\",\"action\":\"odd.action\",\"actor\":{\"system\":true}}");
    }
    try page.appendSlice(testing.allocator, "]");
    try testing.expect(app.D.respond("/audit", 200, page.items));
    try testing.expect(app.D.findText("odd.action") != 0);
    try testing.expect(app.D.findText("Turf (automatic)") != 0);
    try app.D.press("Load more");
    try testing.expect(app.D.pending("/audit?before=2025-10-12T10%3A00%3A00.000Z") != null);
    try testing.expect(app.D.respond("/audit?before", 200, "[{\"at\":\"2025-10-11T10:00:00.000Z\",\"action\":\"member.removed\",\"actor\":{\"email\":\"sara@example.com\"},\"details\":{\"email\":\"omar@example.com\"}}]"));
    try testing.expect(app.D.findText("sara@example.com") != 0);
    try testing.expect(app.D.findText("Load more") == 0);
}

test "audit: nothing yet" {
    try msettings.openMerchant("/audit");
    defer app.D.reset();
    try testing.expect(app.D.respond("/audit", 200, "[]"));
    try testing.expect(app.D.findText(L("audit.empty")) != 0);
}
