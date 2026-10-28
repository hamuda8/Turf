//! Safety alerts (Turf-js views/carrier/alerts.js): SOS, lost signal, long stops, speeding,
//! tracking paused; acknowledge, resolve with a note, show on the map. The list reloads on live
//! "alert" events (Server-Sent Events), as Turf-js did. The "SOS alerts on
//! this device" box (browser Web Push) is not drawn: zui has no push subscription, and Turf-js
//! itself hides it where push cannot work. (While the app is open, app.zig already beeps and
//! notifies on a new SOS.)

const std = @import("std");
const zui = @import("zui");
const core = @import("../core.zig");
const kit = @import("../kit.zig");
const shell = @import("../shell.zig");
const json = @import("../json.zig");
const fmt = @import("../fmt.zig");
const icons = @import("../icons.zig");
const labels = @import("../labels.zig");
const mapw = @import("../widgets/map.zig");
const cm = @import("../widgets/common.zig");

const Cx = core.Cx;
const Ui = core.Ui;
const V = json.V;
const L = labels.k;
const eq = std.mem.eql;

const d_list: u8 = 0;
const f_note: u16 = 0;
const t_poll: u16 = 1;
const map_h: f32 = 360;

const A = enum(u16) { view = 1, ack, resolve_open, resolve_close, resolve, show };

pub const S = struct {
    m: mapw.Map = .{},
    resolved: bool = false,
    /// Fit the map on the first draw and when the view changes, not on refreshes.
    fit_next: bool = true,
    resolving: ?[]const u8 = null,
};

pub fn title(_: *const S, _: *const Cx) []const u8 {
    return L("nav.alerts");
}

fn load(s: *const S, c: *Cx) void {
    c.load(d_list, c.orgUrl(if (s.resolved) "/carrier/alerts?status=resolved" else "/carrier/alerts?status=open"));
}

pub fn enter(s: *S, c: *Cx) void {
    load(s, c);
    c.orgLive(t_poll, &.{"alert"});
}

fn at(c: *const Cx, i: u32) ?V {
    const list = json.arr(c.data(d_list), "");
    return if (i < list.len) list[i] else null;
}

fn mapWidth() f32 {
    // The map sits in a card in the second column (or below the list on narrow screens).
    const cols: f32 = if (kit.width >= 2 * 280 + 16) 2 else 1;
    return (kit.width - (cols - 1) * 16) / cols - 40;
}

pub fn update(s: *S, c: *Cx, e: core.Ev) void {
    switch (e) {
        .map, .frame => _ = s.m.event(c, e),
        .data => |n| if (n == d_list and c.slot(d_list).state == .ok) {
            if (!s.fit_next) return;
            var pts: std.ArrayList(mapw.LatLng) = .empty;
            for (json.arr(c.data(d_list), "")) |a| if (mapw.ll(a, "location")) |p| pts.append(c.arena(), p) catch {};
            if (pts.items.len == 0) return;
            s.fit_next = false;
            s.m.setSize(mapWidth(), map_h);
            s.m.fit(pts.items, .{ .padding = 40, .max_zoom = 15 });
        },
        .timer => |id| if (id == t_poll) {
            c.liveDone();
            load(s, c);
        },
        .act => |a| switch (@as(A, @enumFromInt(a.id))) {
            .view => {
                s.resolved = a.arg == 1;
                s.fit_next = true;
                c.slots[d_list].reset();
                load(s, c);
            },
            .ack => if (at(c, a.arg)) |x| {
                var b = json.Obj.init(c.arena());
                b.str("status", "acknowledged");
                c.sendArg(@intFromEnum(A.ack), a.arg, .PATCH, c.orgUrl(c.print("/carrier/alerts/{s}", .{cm.docId(x)})), b.done());
            },
            .resolve_open => if (at(c, a.arg)) |x| {
                s.resolving = c.dupe(cm.docId(x));
                c.setVal(f_note, "");
            },
            .resolve_close => s.resolving = null,
            .resolve => if (s.resolving) |id| {
                var b = json.Obj.init(c.arena());
                b.str("status", "resolved");
                b.strOpt("note", c.valTrim(f_note));
                c.send(@intFromEnum(A.resolve), .PATCH, c.orgUrl(c.print("/carrier/alerts/{s}", .{id})), b.done());
            },
            .show => if (at(c, a.arg)) |x| if (mapw.ll(x, "location")) |p| s.m.flyTo(p, 16),
        },
        .done => |d| switch (@as(A, @enumFromInt(d.id))) {
            .ack => if (d.ok) load(s, c),
            .resolve => if (d.ok) {
                s.resolving = null;
                load(s, c);
            },
            else => {},
        },
        else => {},
    }
}

fn details(ui: *Ui, a: V) []const u8 {
    const ty = json.str(a, "type");
    const ar = ui.arena();
    if (eq(u8, ty, "speeding")) return cm.tx(ui, "alerts.speeding_detail", .{ .speed = fmt.number(ar, json.numOr(a, "details.speedKmh", 0), 0), .limit = fmt.number(ar, json.numOr(a, "details.limitKmh", 0), 0) });
    if (eq(u8, ty, "long_stop")) return cm.tx(ui, "alerts.long_stop_detail", .{ .since = fmt.relative(ar, json.str(a, "details.stoppedSince")) });
    if (eq(u8, ty, "signal_lost")) {
        const last = json.str(a, "details.lastSeenAt");
        const seen = if (last.len > 0) cm.tx(ui, "alerts.signal_detail", .{ .when = fmt.relative(ar, last) }) else L("fleet.never_seen");
        return if (json.boolean(a, "details.appInBackground")) kit.f(ui, "{s} · {s}", .{ seen, L("alerts.app_in_background") }) else seen;
    }
    if (eq(u8, ty, "tracking_paused")) return cm.tx(ui, "alerts.paused_detail", .{ .since = fmt.relative(ar, json.str(a, "details.since")) });
    return json.str(a, "note");
}

fn tone(ty: []const u8) kit.Tone {
    if (eq(u8, ty, "sos") or eq(u8, ty, "speeding")) return .red;
    if (eq(u8, ty, "signal_lost") or eq(u8, ty, "long_stop") or eq(u8, ty, "tracking_paused")) return .amber;
    return .plain;
}

pub fn view(s: *const S, c: *const Cx, ui: *Ui) void {
    var g = kit.grid(ui, 2, 2);
    g.cell();
    kit.stackTight(ui);
    ui.begin(.{ .direction = .row, .gap = 6.4 }, .{});
    kit.chip(ui, L("alerts.view.open"), !s.resolved, kit.act(A.view, 0));
    kit.chip(ui, L("alerts.view.resolved"), s.resolved, kit.act(A.view, 1));
    ui.end();
    alertList(c, ui);
    ui.end();
    g.endCell();
    g.cell();
    kit.card(ui, .{});
    mapw.draw(ui, &s.m, .{ .height = map_h, .width = mapWidth(), .pins = pins(c, ui), .key = zui.key("alerts-map") });
    kit.endCard(ui, .{});
    g.endCell();
    g.end();
}

fn pins(c: *const Cx, ui: *Ui) []const mapw.Pin {
    var out: std.ArrayList(mapw.Pin) = .empty;
    for (json.arr(c.data(d_list), "")) |a| if (mapw.ll(a, "location")) |p| out.append(ui.arena(), .{
        .at = p,
        .icon = mapw.vehicleIcon(json.str(a, "vehicle")),
        .kind = if (eq(u8, json.str(a, "status"), "open")) .alert else .vehicle,
        .key = zui.key(cm.docId(a)),
        .tip = kit.f(ui, "{s}: {s}", .{ json.str(a, "courierName"), labels.of("alert.type.", json.str(a, "type")) }),
    }) catch {};
    return out.items;
}

fn alertList(c: *const Cx, ui: *Ui) void {
    const k = kit.k;
    const sl = c.slot(d_list);
    switch (sl.state) {
        .idle, .loading => return kit.loading(ui),
        .failed => {
            kit.notice(ui, .err, sl.err);
            return;
        },
        .ok => {},
    }
    const list = json.arr(c.data(d_list), "");
    if (list.len == 0) return kit.empty(ui, L("alerts.none"));
    for (list, 0..) |a, i| {
        const ty = json.str(a, "type");
        const st = json.str(a, "status");
        const co: kit.CardOpts = .{ .gap = 8.8, .ring = if (eq(u8, ty, "sos") and eq(u8, st, "open")) k.f else null, .key = zui.key(cm.docId(a)) };
        kit.card(ui, co);
        kit.rowBetween(ui);
        kit.badgeIcon(ui, labels.of("alert.type.", ty), tone(ty), if (eq(u8, ty, "sos")) icons.warning else icons.notifications);
        kit.small(ui, fmt.dateTime(ui.arena(), json.str(a, "at")));
        ui.end();
        ui.begin(.{ .direction = .row, .gap = 4.8, .align_items = .center }, .{});
        kit.icon(ui, if (json.str(a, "vehicle").len > 0) mapw.vehicleIcon(json.str(a, "vehicle")) else icons.person, 20, k.ink);
        kit.strong(ui, json.str(a, "courierName"));
        ui.end();
        ui.text(details(ui, a), .{ .font_size = 14, .color = k.ink });
        if (!eq(u8, st, "open")) {
            const note = json.str(a, "resolutionNote");
            kit.small(ui, if (note.len > 0) kit.f(ui, "{s} — {s}", .{ labels.of("alerts.status.", st), note }) else labels.of("alerts.status.", st));
        }
        ui.begin(.{ .direction = .row, .gap = 5.6 }, .{});
        if (json.has(a, "location")) kit.button(ui, L("alerts.show_on_map"), kit.act(A.show, @intCast(i)), .{ .size = .sm, .icon = icons.location_on });
        if (eq(u8, st, "open")) {
            const mine = c.isBusy(@intFromEnum(A.ack)) and (c.act_args.get(@intFromEnum(A.ack)) orelse 0) == i;
            kit.button(ui, L("alerts.acknowledge"), kit.act(A.ack, @intCast(i)), .{ .size = .sm, .busy = if (mine) @intFromEnum(A.ack) else null });
        }
        if (!eq(u8, st, "resolved")) kit.button(ui, L("alerts.resolve"), kit.act(A.resolve_open, @intCast(i)), .{ .size = .sm, .variant = .primary });
        ui.end();
        kit.endCard(ui, co);
    }
}

pub fn overlay(s: *const S, _: *const Cx, ui: *Ui) void {
    if (s.resolving == null) return;
    shell.modalBegin(ui, .{ .title = L("alerts.resolve"), .close = kit.act(A.resolve_close, 0), .key = zui.key("resolve-alert") });
    kit.field(ui, L("alerts.resolution_note"), f_note, .{ .input = .{ .kind = .multiline, .name = "note" } });
    shell.modalFoot(ui);
    shell.modalButton(ui, L("common.cancel"), kit.act(A.resolve_close, 0), .{});
    shell.modalButton(ui, L("alerts.resolve"), kit.act(A.resolve, 0), .{ .variant = .primary, .busy = @intFromEnum(A.resolve) });
    shell.modalEnd(ui, true);
}

// ---- Tests --------------------------------------------------------------------------------

const app = @import("../app.zig");
const testing = std.testing;
const dispatch = @import("dispatch.zig");

test "alerts: acknowledge and resolve with a note" {
    try dispatch.openCarrier("/alerts");
    defer app.D.reset();
    try testing.expect(app.D.respond("/carrier/alerts?status=open", 200,
        \\[{"_id":"a1","type":"speeding","status":"open","courierName":"Omar","vehicle":"car","at":"2025-10-12T11:00:00.000Z",
        \\  "details":{"speedKmh":120,"limitKmh":80},"location":{"lat":33.5,"lng":36.3}}]
    ));
    try testing.expect(app.D.findText("120 km/h (limit 80 km/h)") != 0);
    try app.D.press("Acknowledge");
    const ack = zui.host.fetches.items[zui.host.fetches.items.len - 1];
    try testing.expect(std.mem.indexOf(u8, ack.body, "\"status\":\"acknowledged\"") != null);
    try testing.expect(app.D.respond("/carrier/alerts/a1", 200, "{}"));
    try testing.expect(app.D.respond("/carrier/alerts?status=open", 200, "[{\"_id\":\"a1\",\"type\":\"sos\",\"status\":\"acknowledged\",\"courierName\":\"Omar\"}]"));
    try testing.expect(app.D.findText("Acknowledged") != 0);
    try app.D.press("Resolve");
    try app.D.typeInto("", "Called him, all fine");
    app.D.R.dispatch(kit.act(A.resolve, 0));
    const res = zui.host.fetches.items[zui.host.fetches.items.len - 1];
    try testing.expect(std.mem.indexOf(u8, res.body, "\"note\":\"Called him, all fine\"") != null);
    try testing.expect(app.D.respond("/carrier/alerts/a1", 200, "{}"));
    try testing.expect(app.D.findText("What happened?") == 0);
}
