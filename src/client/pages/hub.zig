//! What is in one hub right now (Turf-js views/carrier/hub.js): parcels grouped by what they
//! need next, label printing for picked parcels, and a stock check (scan or type every parcel on
//! the shelves to find what is missing or does not belong).

const std = @import("std");
const zui = @import("zui");
const core = @import("../core.zig");
const kit = @import("../kit.zig");
const shell = @import("../shell.zig");
const json = @import("../json.zig");
const fmt = @import("../fmt.zig");
const icons = @import("../icons.zig");
const labels = @import("../labels.zig");
const parts = @import("../widgets/parts.zig");
const cm = @import("../widgets/common.zig");

const Cx = core.Cx;
const Ui = core.Ui;
const V = json.V;
const L = labels.k;
const eq = std.mem.eql;

const d_data: u8 = 0;
const f_check: u16 = 0;

const groups = [_][]const u8{ "delivery", "transfer", "handover", "return", "scheduled" };
const old_ms: i64 = 2 * 86_400_000;

const A = enum(u16) { group = 1, open, pick, check_open, check_close, check_scan, missing_toggle };

pub const S = struct {
    /// 0 = all, else 1 + index in `groups`.
    group: u32 = 0,
    picks: parts.LabelPick = .{},
    checking: bool = false,
    seen: cm.IdSet = .{},
    strangers: cm.IdSet = .{},
    show_missing: bool = false,
};

pub fn title(_: *const S, c: *const Cx) []const u8 {
    return json.str(c.data(d_data), "hub.name");
}

pub fn enter(_: *S, c: *Cx) void {
    c.load(d_data, c.orgUrl(c.print("/carrier/hubs/{s}/contents", .{c.param(1)})));
}

fn list(c: *const Cx) []const V {
    return json.arr(c.data(d_data), "shipments");
}

fn count(c: *const Cx, g: []const u8) usize {
    var n: usize = 0;
    for (list(c)) |s| if (eq(u8, json.str(s, "next"), g)) {
        n += 1;
    };
    return n;
}

/// More than two days in the hub.
fn old(s: V) bool {
    const since = fmt.parseIso(json.str(s, "since")) orelse return false;
    return fmt.now() - since > old_ms;
}

pub fn actions(s: *const S, c: *const Cx, ui: *Ui) void {
    if (c.slot(d_data).state != .ok) return;
    s.picks.button(ui);
    if (c.can("hub.scan")) kit.button(ui, L("nav.scan"), .{ .go = "/scan" }, .{ .icon = icons.barcode_scanner });
    kit.button(ui, L("hub.stock_check"), kit.act(A.check_open, 0), .{ .icon = icons.list });
}

pub fn update(s: *S, c: *Cx, e: core.Ev) void {
    switch (e) {
        .act => |a| switch (@as(A, @enumFromInt(a.id))) {
            .group => s.group = a.arg,
            .open => {
                const l = list(c);
                if (a.arg < l.len and c.can("shipments.view")) c.go(c.print("/shipments/{s}", .{json.str(l[a.arg], "id")}));
            },
            .pick => {
                const l = list(c);
                if (a.arg >= l.len) return;
                if (parts.LabelPick.tokenOf(json.str(l[a.arg], "labelPath"))) |tk| s.picks.toggle(c, tk);
            },
            .check_open => {
                s.checking = true;
                s.seen.clear();
                s.strangers.clear();
                s.show_missing = false;
                c.setVal(f_check, "");
                c.fx.focus(kit.slotKey(f_check));
            },
            .check_close => s.checking = false,
            .missing_toggle => s.show_missing = !s.show_missing,
            .check_scan => {
                const raw = c.valTrim(f_check);
                var code: std.ArrayList(u8) = .empty;
                for (raw) |ch| {
                    const u = std.ascii.toUpper(ch);
                    if (std.ascii.isDigit(u) or (u >= 'A' and u <= 'Z')) code.append(c.arena(), u) catch {};
                }
                c.setVal(f_check, "");
                if (code.items.len == 0) return;
                var expected = false;
                for (list(c)) |x| if (eq(u8, json.str(x, "trackingNumber"), code.items)) {
                    expected = true;
                };
                if (expected) {
                    if (s.seen.has(code.items)) c.toast(cm.txc(c, "hub.check_twice", .{ .code = code.items }), .info);
                    s.seen.add(c, code.items);
                    c.post("{{\"type\":\"vibrate\",\"pattern\":40}}", .{});
                } else {
                    s.strangers.add(c, code.items);
                    c.post("{{\"type\":\"vibrate\",\"pattern\":[80,60,80]}}", .{});
                }
            },
        },
        else => {},
    }
}

pub fn view(s: *const S, c: *const Cx, ui: *Ui) void {
    if (!kit.gate(ui, &.{d_data})) return;
    const a = ui.arena();
    const place = json.get(c.data(d_data), "hub");
    const l = list(c);
    kit.stack(ui);
    kit.muted(ui, kit.f(ui, "{s} · {s}", .{ labels.of("hubs.type.", json.str(place, "type")), parts.placeText(a, c, place, .{}) }));
    var not_planned: usize = 0;
    var not_planned_alert = false;
    var n_old: usize = 0;
    var n_cod: usize = 0;
    for (l) |x| {
        if (!json.boolean(x, "planned")) {
            not_planned += 1;
            if (!eq(u8, json.str(x, "next"), "scheduled")) not_planned_alert = true;
        }
        if (old(x)) n_old += 1;
        if (json.has(x, "cod")) n_cod += 1;
    }
    var g = kit.grid(ui, 4, 4);
    g.cell();
    kit.stat(ui, L("hub.total"), fmt.number(a, @floatFromInt(l.len), 0), .{});
    g.endCell();
    g.cell();
    kit.stat(ui, L("hub.not_planned_n"), fmt.number(a, @floatFromInt(not_planned), 0), .{ .alert = not_planned_alert });
    g.endCell();
    g.cell();
    kit.stat(ui, L("hub.waiting_long"), fmt.number(a, @floatFromInt(n_old), 0), .{ .alert = n_old > 0 });
    g.endCell();
    g.cell();
    kit.stat(ui, L("hub.cod_inside"), fmt.number(a, @floatFromInt(n_cod), 0), .{});
    g.endCell();
    g.end();

    kit.card(ui, .{ .gap = 16 });
    var w = kit.Wrap.begin(ui, kit.width - 40, 6.4);
    const all_label = kit.f(ui, "{s} ({d})", .{ L("common.all"), l.len });
    w.item(kit.estimate(all_label, 13.4) + 32);
    kit.chip(ui, all_label, s.group == 0, kit.act(A.group, 0));
    for (groups, 0..) |gr, i| {
        const n = count(c, gr);
        if (n == 0) continue;
        const lbl = kit.f(ui, "{s} ({d})", .{ labels.of("hub.next.", gr), n });
        w.item(kit.estimate(lbl, 13.4) + 32);
        kit.chip(ui, lbl, s.group == i + 1, kit.act(A.group, @intCast(i + 1)));
    }
    w.end();
    var rows: usize = 0;
    for (l) |x| {
        if (s.group == 0 or eq(u8, json.str(x, "next"), groups[s.group - 1])) rows += 1;
    }
    if (rows == 0) kit.empty(ui, L("hub.empty")) else {
        var tb = kit.Table.begin(ui, &.{
            .{ .width = 44 },
            .{ .label = L("shipment.tracking_number") },
            .{ .label = L("hub.next_step") },
            .{ .label = L("shipment.recipient") },
            .{ .label = L("hub.in_hub_since") },
            .{ .label = L("shipment.cod") },
        });
        for (l, 0..) |x, i| {
            if (!(s.group == 0 or eq(u8, json.str(x, "next"), groups[s.group - 1]))) continue;
            tb.row(if (c.can("shipments.view")) kit.act(A.open, @intCast(i)) else null, zui.key(json.str(x, "id")));
            tb.cell(false);
            if (parts.LabelPick.tokenOf(json.str(x, "labelPath"))) |tk| {
                ui.begin(.{ .padding = .all(4), .align_self = .start }, .{ .on_press = kit.act(A.pick, @intCast(i)) });
                kit.box(ui, s.picks.has(tk));
                ui.end();
            }
            tb.endCell();
            tb.cell(false);
            kit.mono(ui, json.str(x, "trackingNumber"), .{ .weight = 700 });
            kit.statusBadge(ui, json.str(x, "status"));
            tb.endCell();
            tb.cell(true);
            kit.text(ui, labels.of("hub.next.", json.str(x, "next")), .{});
            if (json.boolean(x, "planned")) kit.badge(ui, L("hub.planned"), .green) else kit.badge(ui, L("hub.not_planned"), .plain);
            if (json.str(x, "scheduledFor").len > 0) kit.small(ui, fmt.date(a, json.str(x, "scheduledFor")));
            tb.endCell();
            tb.cell(true);
            kit.text(ui, json.str(x, "dropoff.name"), .{});
            kit.small(ui, parts.placeText(a, c, json.get(x, "dropoff"), .{ .area = true }));
            tb.endCell();
            tb.cell(true);
            const since = fmt.relative(a, json.str(x, "since"));
            if (old(x)) kit.badge(ui, since, .amber) else kit.text(ui, since, .{});
            tb.endCell();
            tb.cell(true);
            kit.text(ui, if (json.obj(x, "cod")) |cod| fmt.money(a, json.num(cod, "amount"), json.str(cod, "currency")) else "—", .{});
            tb.endCell();
            tb.endRow();
        }
        tb.end();
    }
    kit.endCard(ui, .{});
    ui.end();
}

pub fn overlay(s: *const S, c: *const Cx, ui: *Ui) void {
    if (!s.checking) return;
    const a = ui.arena();
    const l = list(c);
    var missing: std.ArrayList([]const u8) = .empty;
    for (l) |x| {
        const tn = json.str(x, "trackingNumber");
        if (!s.seen.has(tn)) missing.append(a, tn) catch {};
    }
    shell.modalBegin(ui, .{ .title = L("hub.stock_check"), .close = kit.act(A.check_close, 0), .wide = true, .key = zui.key("stock-check") });
    kit.muted(ui, L("hub.check_intro"));
    kit.input(ui, f_check, .{ .kind = .code, .mono = true, .ltr = true, .placeholder = L("hub.scan_placeholder"), .on_submit = kit.act(A.check_scan, 0) });
    var g = kit.grid(ui, 3, 3);
    g.cell();
    kit.stat(ui, L("hub.check_found"), kit.f(ui, "{s} / {s}", .{ fmt.number(a, @floatFromInt(s.seen.count()), 0), fmt.number(a, @floatFromInt(l.len), 0) }), .{});
    g.endCell();
    g.cell();
    kit.stat(ui, L("hub.check_missing"), fmt.number(a, @floatFromInt(missing.items.len), 0), .{});
    g.endCell();
    g.cell();
    kit.stat(ui, L("hub.check_unexpected"), fmt.number(a, @floatFromInt(s.strangers.count()), 0), .{ .alert = s.strangers.count() > 0 });
    g.endCell();
    g.end();
    if (s.strangers.count() > 0) {
        kit.noticeBegin(ui, .warn, icons.warning);
        kit.strong(ui, L("hub.check_unexpected_list"));
        kit.mono(ui, std.mem.join(a, "  ", s.strangers.items.items) catch "", .{ .size = 13.6 });
        kit.noticeEnd(ui);
    }
    if (missing.items.len > 0) {
        // <details>: the summary opens the list.
        ui.begin(.{ .direction = .row, .gap = 4.8, .align_items = .center, .pressed_opacity = 0.7, .align_self = .start }, .{ .on_press = kit.act(A.missing_toggle, 0) });
        kit.icon(ui, if (s.show_missing) icons.expand_less else icons.expand_more, 20, kit.k.ink_3);
        kit.strong(ui, cm.tx(ui, "hub.check_missing_list", .{ .n = missing.items.len }));
        ui.end();
        if (s.show_missing) kit.mono(ui, std.mem.join(a, "  ", missing.items) catch "", .{ .size = 13.6 });
    } else kit.notice(ui, .ok, L("hub.check_all_found"));
    shell.modalFoot(ui);
    shell.modalButton(ui, L("common.done"), kit.act(A.check_close, 0), .{ .variant = .primary });
    shell.modalEnd(ui, true);
}

// ---- Tests --------------------------------------------------------------------------------

const app = @import("../app.zig");
const testing = std.testing;
const dispatch = @import("dispatch.zig");

test "hub: contents, groups and a stock check" {
    try dispatch.openCarrier("/hubs/h1");
    defer app.D.reset();
    try testing.expect(app.D.respond("/carrier/hubs/h1/contents", 200,
        \\{"hub":{"name":"Main hub","type":"hub","city":"Damascus","governorate":"DAM"},
        \\ "shipments":[{"id":"s1","trackingNumber":"TRF1","status":"at_hub","next":"delivery","planned":false,"since":"2025-10-01T10:00:00.000Z","dropoff":{"name":"Lina"},"labelPath":"/o/fast/label/tok1"},
        \\  {"id":"s2","trackingNumber":"TRF2","status":"at_hub","next":"transfer","planned":true,"since":"2025-10-12T10:00:00.000Z","dropoff":{"name":"Sami"},"cod":{"amount":1000,"currency":"SYP"}}]}
    ));
    try testing.expect(app.D.findText("Main hub") != 0);
    try testing.expect(app.D.findText("All (2)") != 0);
    app.D.R.dispatch(kit.act(A.group, 2));
    try testing.expect(app.D.findText("Sami") != 0);
    try testing.expect(app.D.findText("Lina") == 0);
    app.D.R.dispatch(kit.act(A.check_open, 0));
    try app.D.typeInto(L("hub.scan_placeholder"), "trf1");
    try app.D.inputEvent(L("hub.scan_placeholder"), .submit);
    try app.D.typeInto(L("hub.scan_placeholder"), "TRF9");
    try app.D.inputEvent(L("hub.scan_placeholder"), .submit);
    try testing.expect(app.D.findText("1 / 2") != 0);
    try testing.expect(app.D.findText("TRF9") != 0);
}
