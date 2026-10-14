//! Live fleet map (Turf-js views/carrier/fleet.js): every courier's position, the hubs, and a
//! courier's route over the last hours. The fleet reloads on live events (Server-Sent
//! Events: positions, duty); the "no signal" badges are looked at again every minute.

const std = @import("std");
const zui = @import("zui");
const core = @import("../core.zig");
const kit = @import("../kit.zig");
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

const d_fleet: u8 = 0;
const d_hubs: u8 = 1;
const d_trail: u8 = 2;

const t_poll: u16 = 1;
const t_tick: u16 = 2;
const stale_ms: i64 = 10 * 60_000;
const panel_w: f32 = 360;

const A = enum(u16) { filter = 1, select, replay };

pub const S = struct {
    m: mapw.Map = .{},
    all: bool = false,
    selected: ?[]const u8 = null,
    fitted: bool = false,
    replay_for: []const u8 = "",
};

pub fn title(_: *const S, _: *const Cx) []const u8 {
    return L("nav.fleet");
}

pub fn enter(_: *S, c: *Cx) void {
    c.load(d_fleet, c.orgUrl("/carrier/fleet"));
    c.load(d_hubs, c.orgUrl("/carrier/hubs"));
    c.orgLive(t_poll, &.{ "courier.position", "courier.duty" });
    c.after(60_000, t_tick);
}

fn isStale(x: V) bool {
    const at = fmt.parseIso(json.str(x, "at")) orelse return true;
    return fmt.now() - at > stale_ms;
}

fn byId(c: *const Cx, id: []const u8) ?V {
    for (json.arr(c.data(d_fleet), "")) |x| if (eq(u8, json.str(x, "courierId"), id)) return x;
    return null;
}

/// The map's size as the view draws it.
fn mapSize(c: *const Cx) [2]f32 {
    const h = c.env.height;
    if (kit.phone) return .{ c.env.width, @round(h * 0.45) };
    return .{ @max(kit.width - panel_w, 200), @max(h - 112, 420) };
}

pub fn update(s: *S, c: *Cx, e: core.Ev) void {
    switch (e) {
        .map, .frame => _ = s.m.event(c, e),
        .data => |n| {
            if (!s.fitted and c.ready(&.{ d_fleet, d_hubs })) {
                s.fitted = true;
                // Focus on couriers at work; fall back to the hubs when nobody is on duty.
                var pts: std.ArrayList(mapw.LatLng) = .empty;
                for (json.arr(c.data(d_fleet), "")) |x| if (json.boolean(x, "onDuty")) if (mapw.ll(x, "location")) |p| pts.append(c.arena(), p) catch {};
                if (pts.items.len == 0) for (json.arr(c.data(d_hubs), "")) |h| if (mapw.ll(h, "location")) |p| pts.append(c.arena(), p) catch {};
                const size = mapSize(c);
                s.m.setSize(size[0], size[1]);
                s.m.fit(pts.items, .{ .max_zoom = 14, .animate = false });
            }
            _ = n;
        },
        .timer => |id| if (id == t_poll) {
            c.liveDone();
            c.load(d_fleet, c.orgUrl("/carrier/fleet"));
        } else if (id == t_tick) {
            // Nothing to load: the draw that follows re-evaluates "no signal".
            c.after(60_000, t_tick);
        },
        .act => |a| switch (@as(A, @enumFromInt(a.id))) {
            .filter => s.all = a.arg == 1,
            .select => {
                const list = json.arr(c.data(d_fleet), "");
                if (a.arg >= list.len) return;
                const id = json.str(list[a.arg], "courierId");
                // The replay belongs to the previous courier.
                if (s.selected == null or !eq(u8, s.selected.?, id)) c.slots[d_trail].reset();
                s.selected = c.dupe(id);
                if (mapw.ll(list[a.arg], "location")) |p| s.m.flyTo(p, @max(s.m.st.camera.zoom, 14));
            },
            .replay => if (s.selected) |id| {
                s.replay_for = id;
                c.send(@intFromEnum(A.replay), .GET, c.orgUrl(c.print("/carrier/fleet/{s}/history", .{id})), "");
            },
        },
        .done => |d| if (d.id == @intFromEnum(A.replay) and d.ok) {
            // Another courier was chosen meanwhile.
            const id = s.selected orelse return;
            if (!eq(u8, id, s.replay_for)) return;
            const pts = json.arr(d.v, "");
            c.slots[d_trail].reset();
            if (pts.len == 0) {
                c.toast(L("fleet.no_history"), .info);
                return;
            }
            cm.keep(c, d_trail, d.body);
            var line: std.ArrayList(mapw.LatLng) = .empty;
            for (pts) |p| line.append(c.arena(), .{ .lat = json.numOr(p, "lat", 0), .lng = json.numOr(p, "lng", 0) }) catch {};
            const size = mapSize(c);
            s.m.setSize(size[0], size[1]);
            s.m.fit(line.items, .{ .padding = 30, .max_zoom = 18 });
        },
        else => {},
    }
}

fn badgeOf(x: V) struct { []const u8, kit.Tone } {
    const on = json.boolean(x, "onDuty");
    const bg = eq(u8, json.str(x, "appState"), "background");
    const stale = isStale(x);
    if (!on) return .{ L("driver.off_duty"), .plain };
    if (bg) return .{ L("fleet.app_background"), .amber };
    if (stale) return .{ L("fleet.no_signal"), .amber };
    return .{ L("driver.on_duty"), .green };
}

/// On duty first, then the busiest, then by name.
fn order(a: std.mem.Allocator, list: []const V, all: bool) []const usize {
    var out: std.ArrayList(usize) = .empty;
    for (list, 0..) |x, i| if (all or json.boolean(x, "onDuty")) out.append(a, i) catch {};
    const Ctx = struct {
        l: []const V,
        fn less(ctx: @This(), ia: usize, ib: usize) bool {
            const x = ctx.l[ia];
            const y = ctx.l[ib];
            const dx: i64 = @intFromBool(json.boolean(x, "onDuty"));
            const dy: i64 = @intFromBool(json.boolean(y, "onDuty"));
            if (dx != dy) return dx > dy;
            const tx = json.int(x, "activeTasks");
            const ty = json.int(y, "activeTasks");
            if (tx != ty) return tx > ty;
            return std.mem.order(u8, json.str(x, "name"), json.str(y, "name")) == .lt;
        }
    };
    std.mem.sort(usize, out.items, Ctx{ .l = list }, Ctx.less);
    return out.items;
}

pub fn view(s: *const S, c: *const Cx, ui: *Ui) void {
    const k = kit.k;
    if (!c.ready(&.{ d_fleet, d_hubs })) {
        ui.begin(.{ .padding = .all(16) }, .{});
        _ = kit.gate(ui, &.{ d_fleet, d_hubs });
        ui.end();
        return;
    }
    const size = mapSize(c);
    ui.begin(.{ .direction = if (kit.phone) .column else .row, .grow = 1, .width = .fill, .height = .fill }, .{});
    // The map.
    ui.begin(.{ .grow = if (kit.phone) 0 else 1, .height = if (kit.phone) .{ .px = size[1] } else .fill }, .{});
    mapw.draw(ui, &s.m, .{ .width = size[0], .height = size[1], .radius = 0, .fill = !kit.phone, .pins = pins(s, c, ui), .lines = trail(c, ui), .key = zui.key("fleet-map") });
    ui.end();
    // The panel: filter, couriers, the chosen one.
    ui.begin(.{ .direction = .row, .width = if (kit.phone) .fill else .{ .px = panel_w }, .grow = if (kit.phone) 1 else 0, .height = if (kit.phone) .auto else .fill, .background = @import("../theme.zig").surface, .borders = .{ .start = .{ .width = 1, .color = k.line } } }, .{});
    if (!kit.phone) {
        ui.begin(.{ .width = .{ .px = 1 }, .height = .fill, .background = k.line }, .{});
        ui.end();
    }
    ui.begin(.{ .grow = 1, .height = if (kit.phone) .auto else .fill }, .{});
    ui.begin(.{ .direction = .row, .gap = 6.4, .padding = .all(12) }, .{});
    kit.chip(ui, L("fleet.on_duty_only"), !s.all, kit.act(A.filter, 0));
    kit.chip(ui, L("common.all"), s.all, kit.act(A.filter, 1));
    ui.end();
    kit.line(ui, k.line);
    if (kit.phone) {
        ui.begin(.{ .padding = .all(12), .gap = 8.8 }, .{});
        courierList(s, c, ui);
        ui.end();
    } else {
        ui.beginScroll(.{ .grow = 1, .padding = .all(12), .gap = 8.8 }, zui.key("fleet-list"));
        courierList(s, c, ui);
        ui.end();
    }
    detail(s, c, ui);
    ui.end();
    ui.end();
    ui.end();
}

fn pins(s: *const S, c: *const Cx, ui: *Ui) []const mapw.Pin {
    const a = ui.arena();
    var out: std.ArrayList(mapw.Pin) = .empty;
    for (json.arr(c.data(d_hubs), "")) |h| if (mapw.ll(h, "location")) |p| out.append(a, .{ .at = p, .kind = .place, .icon = mapw.placeIcon(json.str(h, "type")), .key = zui.key(cm.docId(h)) }) catch {};
    for (json.arr(c.data(d_fleet), ""), 0..) |x, i| {
        if (!s.all and !json.boolean(x, "onDuty")) continue;
        const p = mapw.ll(x, "location") orelse continue;
        const id = json.str(x, "courierId");
        const chosen = s.selected != null and eq(u8, s.selected.?, id);
        out.append(a, .{
            .at = p,
            .kind = if (!json.boolean(x, "onDuty")) .off else if (isStale(x)) .stale else .vehicle,
            .icon = mapw.vehicleIcon(json.str(x, "vehicle")),
            .key = zui.key(id),
            .on_press = kit.act(A.select, @intCast(i)),
            .label = if (chosen) kit.f(ui, "{s} · {s}", .{ json.str(x, "name"), fmt.relative(a, json.str(x, "at")) }) else "",
        }) catch {};
    }
    return out.items;
}

fn trail(c: *const Cx, ui: *Ui) []const mapw.Line {
    const pts = json.arr(c.data(d_trail), "");
    if (pts.len == 0) return &.{};
    const a = ui.arena();
    var line: std.ArrayList(mapw.LatLng) = .empty;
    for (pts) |p| line.append(a, .{ .lat = json.numOr(p, "lat", 0), .lng = json.numOr(p, "lng", 0) }) catch {};
    const out = a.alloc(mapw.Line, 1) catch return &.{};
    out[0] = .{ .points = line.items, .width = 4, .opacity = 0.8 };
    return out;
}

fn courierList(s: *const S, c: *const Cx, ui: *Ui) void {
    const k = kit.k;
    const all = json.arr(c.data(d_fleet), "");
    const idx = order(ui.arena(), all, s.all);
    if (idx.len == 0) {
        kit.muted(ui, L("fleet.nobody"));
        return;
    }
    for (idx) |i| {
        const x = all[i];
        const id = json.str(x, "courierId");
        const chosen = s.selected != null and eq(u8, s.selected.?, id);
        ui.begin(.{ .padding = .xy(12, 9.6), .gap = 3.2, .radius = 22, .background = k.panel, .shadow = kit.shadow1(), .border_width = if (chosen) 2 else 0, .border_color = k.a, .pressed_background = k.press, .hover_background = k.panel.mix(0.85, k.panel_3) }, .{ .on_press = kit.act(A.select, @intCast(i)), .key = zui.key(id) });
        kit.rowBetween(ui);
        ui.begin(.{ .direction = .row, .gap = 4.8, .align_items = .center, .grow = 1 }, .{});
        kit.icon(ui, mapw.vehicleIcon(json.str(x, "vehicle")), 20, k.ink);
        kit.strong(ui, json.str(x, "name"));
        ui.end();
        const b = badgeOf(x);
        kit.badge(ui, b[0], b[1]);
        ui.end();
        ui.begin(.{ .direction = .row, .gap = 3.2, .align_items = .center }, .{});
        var line: std.ArrayList(u8) = .empty;
        const at = json.str(x, "at");
        line.appendSlice(ui.arena(), if (at.len > 0) cm.tx(ui, "fleet.seen", .{ .when = fmt.relative(ui.arena(), at) }) else L("fleet.never_seen")) catch {};
        if (json.num(x, "speedKmh")) |v| line.print(ui.arena(), " · {s} {s}", .{ fmt.number(ui.arena(), v, 0), L("unit.kmh") }) catch {};
        kit.small(ui, line.items);
        if (json.num(x, "battery")) |v| {
            kit.small(ui, "·");
            kit.icon(ui, icons.battery_full, 16, k.ink_2);
            kit.small(ui, kit.f(ui, "{d}%", .{@as(i64, @intFromFloat(@round(v * 100)))}));
        }
        ui.end();
        ui.text(cm.tx(ui, "fleet.tasks", .{ .active = json.int(x, "activeTasks"), .open = json.int(x, "openTasks") }), .{ .font_size = 13.6, .color = k.ink });
        ui.end();
    }
}

fn detail(s: *const S, c: *const Cx, ui: *Ui) void {
    const id = s.selected orelse return;
    const x = byId(c, id) orelse return;
    kit.line(ui, kit.k.line);
    ui.begin(.{ .padding = .all(12), .gap = 8.8 }, .{});
    kit.strong(ui, json.str(x, "name"));
    ui.begin(.{ .direction = .row, .gap = 8 }, .{});
    const phone = json.str(x, "phone");
    if (phone.len > 0) kit.button(ui, L("fleet.call"), .{ .open = kit.f(ui, "tel:{s}", .{phone}) }, .{ .size = .sm, .icon = icons.call });
    kit.button(ui, L("fleet.replay"), kit.act(A.replay, 0), .{ .size = .sm, .icon = icons.history, .busy = @intFromEnum(A.replay) });
    ui.end();
    ui.end();
}

// ---- Tests --------------------------------------------------------------------------------

const app = @import("../app.zig");
const testing = std.testing;
const dispatch = @import("dispatch.zig");

test "fleet: couriers on duty, choosing one, replaying the route" {
    try dispatch.openCarrier("/fleet");
    defer app.D.reset();
    try testing.expect(app.D.respond("/carrier/fleet", 200,
        \\[{"courierId":"c1","name":"Omar","vehicle":"car","onDuty":true,"at":"2025-10-12T11:59:00.000Z","location":{"lat":33.5,"lng":36.3},"activeTasks":2,"openTasks":3,"speedKmh":40,"battery":0.8,"phone":"0933"},
        \\ {"courierId":"c2","name":"Rami","vehicle":"motorbike","onDuty":false}]
    ));
    try testing.expect(app.D.respond("/carrier/hubs", 200, "[{\"_id\":\"h1\",\"name\":\"Main\",\"type\":\"hub\",\"location\":{\"lat\":33.5,\"lng\":36.2}}]"));
    try testing.expect(app.D.findText("Omar") != 0);
    try testing.expect(app.D.findText("Rami") == 0);
    try testing.expect(app.D.findText("Active: 2 · Open: 3") != 0);
    try app.D.press("All");
    try testing.expect(app.D.findText("Rami") != 0);
    try app.D.press("Omar");
    try app.D.press("Show route (last 8 hours)");
    try testing.expect(app.D.respond("/carrier/fleet/c1/history", 200, "[]"));
    try testing.expect(app.D.findText("No route recorded in that time.") != 0);
}
