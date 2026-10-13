//! The store's shipments list (Turf-js views/merchant/shipments.js): status filter, search (350 ms
//! after typing stops), practice (test) shipments, picking labels to print, "Load more", and
//! quiet refreshes that keep every row already loaded (polled; Turf-js listened to live events).

const std = @import("std");
const zui = @import("zui");
const core = @import("../core.zig");
const kit = @import("../kit.zig");
const json = @import("../json.zig");
const fmt = @import("../fmt.zig");
const icons = @import("../icons.zig");
const labels = @import("../labels.zig");
const parts = @import("../widgets/parts.zig");
const paged = @import("../widgets/paged.zig");

const Cx = core.Cx;
const Ui = core.Ui;
const V = json.V;
const L = labels.k;

const d_list: u8 = 0;
const f_status: u16 = 1;
const f_q: u16 = 2;

const A = enum(u16) { open = 1, pick, more, test_toggle, refresh, new };
const T = enum(u16) { search = 1, poll };

pub const S = struct {
    pick: parts.LabelPick = .{},
    pages: paged.Paged = .{},
    next_before: []const u8 = "",
    has_more: bool = false,
    test_only: bool = false,
    q: []const u8 = "",
    shown: usize = 0,
    changed: bool = false,
};

pub fn title(_: *const S, _: *const Cx) []const u8 {
    return L("nav.shipments");
}

fn query(s: *const S, c: *Cx, limit: usize, before: []const u8) []const u8 {
    var q: std.ArrayList(u8) = .empty;
    const a = c.arena();
    q.print(a, "/merchant/shipments?limit={d}", .{limit}) catch {};
    if (c.val(f_status).len > 0) q.print(a, "&status={s}", .{core.encode(a, c.val(f_status))}) catch {};
    if (s.q.len > 0) q.print(a, "&q={s}", .{core.encode(a, s.q)}) catch {};
    if (s.test_only) q.appendSlice(a, "&test=1") catch {};
    if (before.len > 0) q.print(a, "&before={s}", .{core.encode(a, before)}) catch {};
    return q.items;
}

fn load(s: *S, c: *Cx, limit: usize) void {
    c.load(d_list, c.orgUrl(query(s, c, limit, "")));
}

pub fn enter(s: *S, c: *Cx) void {
    c.setVal(f_status, c.query(c.arena(), "status"));
    s.test_only = std.mem.eql(u8, c.query(c.arena(), "test"), "1");
    load(s, c, 50);
    c.after(20_000, @intFromEnum(T.poll));
}

pub fn leave(s: *S, _: *Cx) void {
    s.pages.deinit();
}

fn rows(s: *const S, c: *const Cx, a: std.mem.Allocator) []const V {
    return s.pages.rows(a, c.data(d_list), "data");
}

pub fn update(s: *S, c: *Cx, e: core.Ev) void {
    switch (e) {
        .data => |n| if (n == d_list and c.slot(d_list).state == .ok) {
            s.pages.reset();
            s.changed = false;
            const v = c.data(d_list);
            s.shown = json.arr(v, "data").len;
            s.next_before = c.dupe(json.str(v, "nextBefore"));
            s.has_more = json.boolean(v, "hasMore");
        },
        .text => |t| switch (t.slot) {
            f_status => load(s, c, 50),
            f_q => c.after(350, @intFromEnum(T.search)),
            else => {},
        },
        .timer => |id| switch (@as(T, @enumFromInt(id))) {
            .search => {
                const q = c.valTrim(f_q);
                if (std.mem.eql(u8, q, s.q)) return;
                s.q = c.dupe(q);
                load(s, c, 50);
            },
            .poll => {
                // A refresh keeps the rows already loaded; past the server's cap it is offered.
                if (s.shown > 100) s.changed = true else if (!c.isBusy(@intFromEnum(A.more))) load(s, c, @max(50, s.shown));
                c.after(20_000, @intFromEnum(T.poll));
            },
        },
        .act => |a| switch (@as(A, @enumFromInt(a.id))) {
            .open => {
                const list = rows(s, c, c.arena());
                if (a.arg < list.len) c.go(c.print("/shipments/{s}", .{json.str(list[a.arg], "id")}));
            },
            .pick => {
                const list = rows(s, c, c.arena());
                if (a.arg < list.len) if (parts.LabelPick.tokenOf(json.str(list[a.arg], "labelUrl"))) |tok| s.pick.toggle(c, tok);
            },
            .more => c.send(@intFromEnum(A.more), .GET, c.orgUrl(query(s, c, 50, s.next_before)), ""),
            .test_toggle => {
                s.test_only = !s.test_only;
                load(s, c, 50);
            },
            .refresh => {
                s.changed = false;
                load(s, c, 50);
            },
            .new => c.go("/shipments/new"),
        },
        .done => |d| if (d.id == @intFromEnum(A.more) and d.ok) {
            s.pages.add(d.body, "data");
            s.shown += json.arr(d.v, "data").len;
            s.next_before = c.dupe(json.str(d.v, "nextBefore"));
            s.has_more = json.boolean(d.v, "hasMore");
        },
        else => {},
    }
}

pub fn actions(_: *const S, c: *const Cx, ui: *Ui) void {
    if (c.can("shipments.create")) kit.button(ui, L("nav.new_shipment"), kit.act(A.new, 0), .{ .variant = .primary, .icon = icons.add });
}

/// "Any status" and every status the server knows.
pub fn statusOptions(ui: *Ui, c: *const Cx) []const core.Opt {
    var out: std.ArrayList(core.Opt) = .empty;
    out.append(ui.arena(), .{ .value = "", .label = L("shipment.any_status") }) catch {};
    if (json.obj(c.meta.value, "statuses")) |st| {
        var it = st.object.iterator();
        while (it.next()) |kv| out.append(ui.arena(), .{ .value = kv.key_ptr.*, .label = labels.status(kv.key_ptr.*) }) catch {};
    }
    return out.items;
}

/// "The list changed" with a refresh button.
pub fn changedNotice(ui: *Ui, msg: core.Msg) void {
    kit.noticeBegin(ui, .info, icons.info);
    ui.begin(.{ .direction = .row, .justify = .space_between, .align_items = .center, .gap = 8 }, .{});
    kit.text(ui, L("shipment.list_changed"), .{ .grow = 1 });
    kit.button(ui, L("shipment.list_refresh"), msg, .{ .size = .sm });
    ui.end();
    kit.noticeEnd(ui);
}

/// A row's check box for label picking.
pub fn pickBox(ui: *Ui, pick: *const parts.LabelPick, label_url: []const u8, msg: core.Msg) void {
    const tok = parts.LabelPick.tokenOf(label_url) orelse return;
    ui.begin(.{ .padding = .all(4), .align_self = .start }, .{ .on_press = msg });
    kit.box(ui, pick.has(tok));
    ui.end();
}

pub fn view(s: *const S, c: *const Cx, ui: *Ui) void {
    const a = ui.arena();
    kit.stack(ui);
    const narrow = kit.width < 760;
    ui.begin(.{ .direction = if (narrow) .column else .row, .gap = 12, .align_items = if (narrow) .stretch else .center, .justify = .end }, .{});
    s.pick.button(ui);
    kit.check(ui, L("shipment.show_test"), s.test_only, kit.act(A.test_toggle, 0));
    kit.select(ui, f_status, statusOptions(ui, c), .{ .placeholder = L("shipment.any_status"), .width = if (narrow) null else 220 });
    kit.input(ui, f_q, .{ .kind = .search, .placeholder = L("shipment.search_placeholder_merchant"), .width = if (narrow) null else 320 });
    ui.end();
    if (s.changed) changedNotice(ui, kit.act(A.refresh, 0));
    if (kit.gate(ui, &.{d_list})) {
        const list = rows(s, c, a);
        const cols = [_]kit.Table.Col{
            .{ .width = 44 },
            .{ .label = L("shipment.tracking_number"), .grow = 1.4 },
            .{ .label = L("shipment.recipient"), .grow = 1.4 },
            .{ .label = L("shipment.carrier") },
            .{ .label = L("common.status") },
            .{ .label = L("common.created") },
        };
        ui.begin(.{ .opacity = if (c.slot(d_list).reloading) 0.55 else 1 }, .{});
        var tb = kit.Table.begin(ui, &cols);
        if (list.len == 0) kit.empty(ui, L("shipment.none"));
        for (list, 0..) |x, i| {
            const idx: u32 = @intCast(i);
            tb.row(kit.act(A.open, idx), zui.key(json.str(x, "id")));
            tb.cell(false);
            pickBox(ui, &s.pick, json.str(x, "labelUrl"), kit.act(A.pick, idx));
            tb.endCell();
            tb.cell(false);
            ui.begin(.{ .direction = .row, .gap = 5.6, .align_items = .center }, .{});
            kit.mono(ui, json.str(x, "trackingNumber"), .{ .weight = 700 });
            if (std.mem.eql(u8, json.str(x, "service"), "express") or json.boolean(x, "express")) kit.expressBadge(ui);
            if (json.boolean(x, "test")) kit.badge(ui, L("dev.mode_test"), .amber);
            ui.end();
            if (json.str(x, "reference").len > 0) kit.small(ui, json.str(x, "reference"));
            tb.endCell();
            tb.cell(true);
            kit.text(ui, json.strOr(x, "dropoff.name", json.str(x, "dropoff.phone")), .{});
            kit.small(ui, parts.placeText(a, c, json.obj(x, "dropoff"), .{ .area = true }));
            tb.endCell();
            tb.cell(true);
            kit.text(ui, json.str(x, "carrier.name"), .{});
            tb.endCell();
            tb.cell(true);
            kit.statusBadge(ui, json.str(x, "status"));
            tb.endCell();
            tb.cell(true);
            kit.text(ui, fmt.relative(a, json.str(x, "createdAt")), .{ .lines = 1 });
            if (json.obj(x, "cod")) |cod| kit.small(ui, fmt.money(a, json.num(cod, "amount"), json.str(cod, "currency")));
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

const page1 =
    \\{"data":[{"id":"s1","trackingNumber":"TRF1","status":"awaiting_pickup","labelUrl":"/o/acme/label/t1","carrier":{"name":"Sham Express"},
    \\  "dropoff":{"name":"Rami","city":"Damascus","area":"Mazzeh","governorate":"DAM"},"createdAt":"2025-10-12T11:00:00.000Z","cod":{"amount":450000,"currency":"SYP"}}],
    \\ "nextBefore":"c1","hasMore":true}
;
const page2 =
    \\{"data":[{"id":"s2","trackingNumber":"TRF2","status":"delivered","carrier":{"name":"Sham Express"},"dropoff":{"phone":"0944"},"createdAt":"2025-10-11T11:00:00.000Z"}],"nextBefore":null,"hasMore":false}
;

test "store shipments: filter, search, load more, pick labels" {
    try app.startSignedIn("/o/acme/shipments?status=awaiting_pickup");
    defer app.D.reset();
    const D = app.D;
    try testing.expect(D.respond("/api/app/orgs/o1", 200, @import("m_shipment.zig").merchant_org));
    try testing.expect(D.pending("/merchant/shipments?limit=50&status=awaiting_pickup") != null);
    try testing.expect(D.respond("/merchant/shipments", 200, page1));
    try testing.expect(D.findText("TRF1") != 0);
    try testing.expect(D.findText("Mazzeh · Damascus") != 0);
    try D.press("Load more");
    try testing.expect(D.pending("before=c1") != null);
    try testing.expect(D.respond("before=c1", 200, page2));
    try testing.expect(D.findText("TRF2") != 0);
    try testing.expect(D.findText("Load more") == 0);
    D.R.dispatch(.{ .act = .{ .id = @intFromEnum(A.pick), .arg = 0 } });
    try testing.expectEqual(@as(usize, 1), D.R.appState().page.m_shipments.pick.tokens.items.len);
    try D.typeInto(L("shipment.search_placeholder_merchant"), "rami");
    D.R.dispatch(.{ .timer = .{ .gen = D.R.appState().gen, .id = @intFromEnum(T.search) } });
    try testing.expect(D.pending("q=rami") != null);
}
