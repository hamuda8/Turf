//! The carrier's shipments list (Turf-js views/carrier/shipments.js): views (active, needs
//! action, scheduled, problems, all, handed over), status filter, search, label picking, "Load
//! more" by creation time, and quiet refreshes (polled).

const std = @import("std");
const zui = @import("zui");
const core = @import("../core.zig");
const kit = @import("../kit.zig");
const json = @import("../json.zig");
const fmt = @import("../fmt.zig");
const labels = @import("../labels.zig");
const parts = @import("../widgets/parts.zig");
const paged = @import("../widgets/paged.zig");
const ml = @import("m_shipments.zig");

const Cx = core.Cx;
const Ui = core.Ui;
const V = json.V;
const L = labels.k;

const d_list: u8 = 0;
const f_status: u16 = 1;
const f_q: u16 = 2;

const A = enum(u16) { open = 1, pick, more, view, refresh };
const T = enum(u16) { search = 1, poll };

const views = [_][]const u8{ "active", "needs_action", "scheduled", "problems", "all", "handed_over" };

pub const S = struct {
    pick: parts.LabelPick = .{},
    pages: paged.Paged = .{},
    view: u8 = 0,
    last: []const u8 = "",
    has_more: bool = false,
    q: []const u8 = "",
    shown: usize = 0,
    changed: bool = false,
    limit_asked: usize = 50,
};

pub fn title(_: *const S, _: *const Cx) []const u8 {
    return L("nav.shipments");
}

fn query(s: *const S, c: *Cx, limit: usize, before: []const u8) []const u8 {
    var q: std.ArrayList(u8) = .empty;
    const a = c.arena();
    q.print(a, "/carrier/shipments?limit={d}", .{limit}) catch {};
    if (!std.mem.eql(u8, views[s.view], "all")) q.print(a, "&view={s}", .{views[s.view]}) catch {};
    if (c.val(f_status).len > 0) q.print(a, "&status={s}", .{core.encode(a, c.val(f_status))}) catch {};
    if (s.q.len > 0) q.print(a, "&q={s}", .{core.encode(a, s.q)}) catch {};
    if (before.len > 0) q.print(a, "&before={s}", .{core.encode(a, before)}) catch {};
    return q.items;
}

fn load(s: *S, c: *Cx, limit: usize) void {
    s.limit_asked = limit;
    c.load(d_list, c.orgUrl(query(s, c, limit, "")));
}

pub fn enter(s: *S, c: *Cx) void {
    const v = c.query(c.arena(), "view");
    for (views, 0..) |x, i| if (std.mem.eql(u8, x, v)) {
        s.view = @intCast(i);
    };
    load(s, c, 50);
    c.orgLive(@intFromEnum(T.poll), &.{ "shipment.created", "shipment.updated" });
}

pub fn leave(s: *S, _: *Cx) void {
    s.pages.deinit();
}

fn rows(s: *const S, c: *const Cx, a: std.mem.Allocator) []const V {
    return s.pages.rows(a, c.data(d_list), "");
}

fn lastCreated(list: []const V) []const u8 {
    return if (list.len > 0) json.str(list[list.len - 1], "createdAt") else "";
}

pub fn update(s: *S, c: *Cx, e: core.Ev) void {
    switch (e) {
        .data => |n| if (n == d_list and c.slot(d_list).state == .ok) {
            s.pages.reset();
            s.changed = false;
            const list = json.arr(c.data(d_list), "");
            s.shown = list.len;
            s.last = c.dupe(lastCreated(list));
            s.has_more = list.len >= s.limit_asked;
        },
        .text => |t| switch (t.slot) {
            f_status => load(s, c, 50),
            f_q => c.after(350, @intFromEnum(T.search)),
            else => {},
        },
        .timer => |id| switch (@as(T, @enumFromInt(id))) {
            .search => {
                s.q = c.dupe(c.valTrim(f_q));
                load(s, c, 50);
            },
            .poll => {
                c.liveDone();
                if (s.shown > 200) s.changed = true else if (!c.isBusy(@intFromEnum(A.more))) load(s, c, @max(50, s.shown));
            },
        },
        .act => |a| switch (@as(A, @enumFromInt(a.id))) {
            .open => {
                const list = rows(s, c, c.arena());
                if (a.arg < list.len) c.go(c.print("/shipments/{s}", .{json.str(list[a.arg], "_id")}));
            },
            .pick => {
                const list = rows(s, c, c.arena());
                if (a.arg < list.len) if (parts.LabelPick.tokenOf(json.str(list[a.arg], "labelPath"))) |tok| s.pick.toggle(c, tok);
            },
            .more => c.send(@intFromEnum(A.more), .GET, c.orgUrl(query(s, c, 50, s.last)), ""),
            .view => {
                s.view = @intCast(a.arg);
                load(s, c, 50);
            },
            .refresh => {
                s.changed = false;
                load(s, c, 50);
            },
        },
        .done => |d| if (d.id == @intFromEnum(A.more) and d.ok) {
            const list = json.arr(d.v, "");
            s.pages.add(d.body, "");
            s.shown += list.len;
            if (list.len > 0) s.last = c.dupe(lastCreated(list));
            s.has_more = list.len >= 50;
        },
        else => {},
    }
}

pub fn view(s: *const S, c: *const Cx, ui: *Ui) void {
    const a = ui.arena();
    kit.stack(ui);
    // Views on one side, picking, status and search on the other (stacked when narrow).
    const narrow = kit.width < 900;
    ui.begin(.{ .direction = if (narrow) .column else .row, .gap = 12, .align_items = if (narrow) .stretch else .center, .justify = .space_between }, .{});
    const view_keys = [_][]const u8{ "shipment.view.active", "shipment.view.needs_action", "shipment.view.scheduled", "shipment.view.problems", "common.all", "shipment.view.handed_over" };
    var w = kit.Wrap.begin(ui, if (narrow) kit.width else kit.width * 0.55, 6.4);
    for (view_keys, 0..) |key, i| {
        w.item(kit.estimate(L(key), 13.4) + 31);
        kit.chip(ui, L(key), s.view == i, kit.act(A.view, @intCast(i)));
    }
    w.end();
    ui.begin(.{ .direction = if (narrow) .column else .row, .gap = 12, .align_items = if (narrow) .stretch else .center }, .{});
    s.pick.button(ui);
    kit.select(ui, f_status, ml.statusOptions(ui, c), .{ .placeholder = L("shipment.any_status"), .width = if (narrow) null else 200 });
    kit.input(ui, f_q, .{ .kind = .search, .placeholder = L("shipment.search_placeholder"), .width = if (narrow) null else 260 });
    ui.end();
    ui.end();
    if (s.changed) ml.changedNotice(ui, kit.act(A.refresh, 0));
    if (kit.gate(ui, &.{d_list})) {
        const list = rows(s, c, a);
        const cols = [_]kit.Table.Col{
            .{ .width = 44 },
            .{ .label = L("shipment.tracking_number"), .grow = 1.4 },
            .{ .label = L("shipment.destination"), .grow = 1.3 },
            .{ .label = L("common.status") },
            .{ .label = L("shipment.cod") },
            .{ .label = L("common.created") },
        };
        ui.begin(.{ .opacity = if (c.slot(d_list).reloading) 0.55 else 1 }, .{});
        var tb = kit.Table.begin(ui, &cols);
        if (list.len == 0) kit.empty(ui, L("shipment.none"));
        for (list, 0..) |x, i| {
            const idx: u32 = @intCast(i);
            tb.row(kit.act(A.open, idx), zui.key(json.str(x, "_id")));
            tb.cell(false);
            ml.pickBox(ui, &s.pick, json.str(x, "labelPath"), kit.act(A.pick, idx));
            tb.endCell();
            tb.cell(false);
            ui.begin(.{ .direction = .row, .gap = 5.6, .align_items = .center }, .{});
            kit.mono(ui, json.str(x, "trackingNumber"), .{ .weight = 700 });
            if (std.mem.eql(u8, json.str(x, "service"), "express") or json.boolean(x, "express")) kit.expressBadge(ui);
            ui.end();
            kit.small(ui, json.str(x, "merchantName"));
            tb.endCell();
            tb.cell(true);
            kit.text(ui, parts.placeText(a, c, json.obj(x, "dropoff"), .{ .area = true }), .{});
            tb.endCell();
            tb.cell(true);
            kit.statusBadge(ui, json.str(x, "status"));
            if (json.int(x, "attempts") > 0) kit.small(ui, ui.tf(labels.english("shipment.attempts_n") orelse "{n}", .{ .n = json.int(x, "attempts") }));
            tb.endCell();
            tb.cell(true);
            kit.text(ui, if (json.obj(x, "cod")) |cod| fmt.money(a, json.num(cod, "amount"), json.str(cod, "currency")) else "—", .{});
            tb.endCell();
            tb.cell(true);
            kit.text(ui, fmt.relative(a, json.str(x, "createdAt")), .{ .lines = 1 });
            tb.endCell();
            tb.endRow();
        }
        tb.end();
        ui.end();
        if (s.has_more) {
            ui.begin(.{ .align_items = .center }, .{});
            kit.button(ui, L("common.load_more"), kit.act(A.more, 0), .{ .variant = .ghost, .busy = @intFromEnum(A.more) });
            ui.end();
        }
    }
    ui.end();
}

// ---- Tests --------------------------------------------------------------------------------

const app = @import("../app.zig");
const testing = std.testing;

const carrier_org =
    \\{"id":"o2","type":"carrier","name":"Sham Express","slug":"fast","status":"active","branding":{"appName":"Sham Express"},
    \\ "me":{"memberId":"m1","isOwner":true,"permissions":["shipments.view","shipments.manage","org.settings"]}}
;

test "carrier shipments: views, rows, load more by creation time" {
    try app.startSignedIn("/o/fast/shipments?view=problems");
    defer app.D.reset();
    const D = app.D;
    try testing.expect(D.respond("/api/app/orgs/o2", 200, carrier_org));
    try testing.expect(D.pending("view=problems") != null);
    try testing.expect(D.respond("/carrier/shipments", 200,
        \\[{"_id":"s1","trackingNumber":"TRF7","merchantName":"Souq Sham","status":"delivery_failed","attempts":1,"labelPath":"/o/fast/label/t7",
        \\  "dropoff":{"city":"Damascus","area":"Malki","governorate":"DAM"},"createdAt":"2025-10-12T11:00:00.000Z"}]
    ));
    try testing.expect(D.findText("TRF7") != 0);
    try testing.expect(D.findText("Souq Sham") != 0);
    try testing.expect(D.findText("Load more") == 0); // fewer than a page
    try D.press("All");
    try testing.expect(D.pending("/carrier/shipments?limit=50") != null);
}
