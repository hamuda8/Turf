//! The driver's task screen (Turf-js views/courier/task.js): turn-by-turn navigation to the
//! next stop (routes from Turf's /courier/route, spoken when the voice is on), the map, the
//! parcels with their contacts, and the step actions: accept, start (with the pickup
//! checklist), delivered (code, receiver, photo, cash collected), failed (reason, new day),
//! complete. Without a connection an action is kept on the phone and sent later (gps.zig).

const std = @import("std");
const zui = @import("zui");
const core = @import("../core.zig");
const kit = @import("../kit.zig");
const shell = @import("../shell.zig");
const json = @import("../json.zig");
const fmt = @import("../fmt.zig");
const icons = @import("../icons.zig");
const labels = @import("../labels.zig");
const gps = @import("../gps.zig");
const courier = @import("../widgets/courier.zig");
const mapw = @import("../widgets/map.zig");
const driver = @import("driver.zig");

const Cx = core.Cx;
const Ui = core.Ui;
const V = json.V;
const L = labels.k;
const LatLng = mapw.LatLng;

const d_task: u8 = 0;
const d_me: u8 = 1;
const d_route: u8 = 2;

const f_code: u16 = 1;
const f_receiver: u16 = 2;
const f_reason: u16 = 3;
const f_day: u16 = 4;
const f_note: u16 = 5;

const A = enum(u16) {
    voice = 1,
    recalc,
    accept,
    decline_ask,
    decline,
    start_ask,
    start_confirmed,
    start,
    checklist_toggle,
    checklist_send,
    deliver_open,
    deliver_send,
    complete,
    fail_open,
    fail_send,
    other_ask,
    other_confirmed,
    close_dialog,
    photo,
    cod_toggle,
};

const T = enum(u16) { poll = 1 };

const Dialog = enum { none, checklist, deliver, fail };

pub const S = struct {
    chrome: courier.Chrome = .{},
    m: mapw.Map = .{ .st = .{ .camera = .{ .center = mapw.syria, .zoom = 13 } } },
    step: usize = 0,
    voice: bool = false,
    last_spoken: u64 = 0,
    last_route_at: i64 = 0,
    manual_route: bool = false,
    fit_route: bool = true,
    fitted_places: bool = false,
    /// The destination the current route leads to (a new one needs a new route).
    route_to: ?LatLng = null,
    dialog: Dialog = .none,
    /// Pickup checklist: shipments NOT collected (indexes).
    missing: std.StaticBitSet(64) = .empty,
    photo: []const u8 = "",
    cod_collected: bool = false,
    /// A queued (offline) action moved the task on.
    status_override: []const u8 = "",
    /// The action whose answer is awaited, for the outbox (path and body kept for a retry).
    pending_path: []const u8 = "",
    pending_body: []const u8 = "",
    pending_kind: A = .accept,
};

pub fn title(_: *const S, c: *const Cx) []const u8 {
    return labels.taskType(json.str(c.data(d_task), "type"));
}

pub fn enter(_: *S, c: *Cx) void {
    c.load(d_task, c.orgUrl(c.print("/courier/tasks/{s}", .{core.encode(c.arena(), c.param(2))})));
    c.load(d_me, c.orgUrl("/courier/me"));
    // The page follows the position for navigation, on shift or not.
    gps.want(c, true);
    c.fx.cancelNotify(driver.alarm_id);
    // `task.changed` of this task only (see `liveEvent`); connecting again reloads too.
    c.orgLive(@intFromEnum(T.poll), &.{});
}

fn liveEvent(c: *Cx, ev: zui.ServerEvent) void {
    if (ev.kind != .message or !std.mem.eql(u8, ev.event, "task.changed")) return;
    var arena = std.heap.ArenaAllocator.init(core.gpa);
    defer arena.deinit();
    const v = json.parse(arena.allocator(), ev.data) orelse return;
    if (!std.mem.eql(u8, json.str(v, "taskId"), json.str(task(c), "_id"))) return;
    reload(c);
}

fn task(c: *const Cx) ?V {
    return c.data(d_task);
}

fn status(s: *const S, c: *const Cx) []const u8 {
    if (s.status_override.len > 0) return s.status_override;
    return json.str(task(c), "status");
}

fn isDelivery(c: *const Cx) bool {
    const ty = json.str(task(c), "type");
    return std.mem.eql(u8, ty, "delivery") or std.mem.eql(u8, ty, "direct");
}

fn goingToStart(s: *const S, c: *const Cx) bool {
    const st = status(s, c);
    return (std.mem.eql(u8, st, "assigned") or std.mem.eql(u8, st, "accepted")) and !std.mem.eql(u8, json.str(task(c), "from.kind"), "courier");
}

fn target(s: *const S, c: *const Cx) ?LatLng {
    const t = task(c);
    if (goingToStart(s, c)) return mapw.ll(t, "from.location");
    if (isDelivery(c)) return mapw.ll(t, "shipments.0.dropoff.location") orelse mapw.ll(t, "to.location");
    return mapw.ll(t, "to.location");
}

fn targetLabel(s: *const S, c: *const Cx) []const u8 {
    return if (goingToStart(s, c)) json.str(task(c), "from.label") else json.str(task(c), "to.label");
}

fn meters(a: LatLng, b: LatLng) f64 {
    const r = 6371000.0;
    const rad = std.math.pi / 180.0;
    const dlat = (b.lat - a.lat) * rad;
    const dlng = (b.lng - a.lng) * rad;
    const x = std.math.pow(f64, @sin(dlat / 2), 2) + @cos(a.lat * rad) * @cos(b.lat * rad) * std.math.pow(f64, @sin(dlng / 2), 2);
    return 2 * r * std.math.asin(@sqrt(x));
}

fn here(c: *const Cx) ?LatLng {
    const f = c.gps.last_fix orelse return null;
    return .{ .lat = f.lat, .lng = f.lng };
}

fn pt(v: V) ?LatLng {
    const a = json.arr(v, "");
    if (a.len < 2) return null;
    return .{ .lat = json.numOr(a[0], "", 0), .lng = json.numOr(a[1], "", 0) };
}

/// One route request at a time; automatic ones wait 30 s and stay quiet.
fn fetchRoute(s: *S, c: *Cx, manual: bool) void {
    const dest = target(s, c) orelse return;
    const from = here(c) orelse return;
    const now = fmt.now();
    const loading = c.slot(d_route).state == .loading or c.slot(d_route).reloading;
    if (loading and !manual) return;
    if (!manual and now - s.last_route_at < 30_000) return;
    s.last_route_at = now;
    s.manual_route = manual;
    if (manual) s.fit_route = true;
    s.route_to = dest;
    c.load(d_route, c.orgUrl(c.print("/courier/route?from={d},{d}&to={d},{d}", .{ from.lat, from.lng, dest.lat, dest.lng })));
}

fn routeSteps(c: *const Cx) []const V {
    return json.arr(c.data(d_route), "steps");
}

fn routePoints(a: std.mem.Allocator, c: *const Cx) []const LatLng {
    var out: std.ArrayList(LatLng) = .empty;
    for (json.arr(c.data(d_route), "geometry")) |p| if (pt(p)) |x| out.append(a, x) catch {};
    return out.items;
}

/// A new position: advance past reached manoeuvres, reroute when off the route (~80 m).
fn onFix(s: *S, c: *Cx) void {
    const pos = here(c) orelse return;
    if (c.slot(d_route).state != .ok) {
        fetchRoute(s, c, false);
        return;
    }
    const steps = routeSteps(c);
    while (s.step + 1 < steps.len) {
        const at = pt(json.get(steps[s.step], "location") orelse break) orelse break;
        if (meters(pos, at) >= 25) break;
        s.step += 1;
    }
    var nearest = std.math.inf(f64);
    for (json.arr(c.data(d_route), "geometry")) |p| if (pt(p)) |x| {
        nearest = @min(nearest, meters(pos, x));
    };
    if (nearest > 80) fetchRoute(s, c, false);
    speakStep(s, c);
}

/// The instruction for a step (OSRM-style manoeuvres).
fn instruction(a: std.mem.Allocator, step: V) []const u8 {
    const ty = json.str(step, "type");
    const name = json.str(step, "name");
    if (std.mem.eql(u8, ty, "arrive")) return L("nav.arrive");
    if (std.mem.eql(u8, ty, "depart")) return if (name.len > 0) labels.tf(a, "nav.depart_onto", .{ .name = name }) else L("nav.depart");
    if (std.mem.eql(u8, ty, "roundabout") or std.mem.eql(u8, ty, "rotary")) return labels.tf(a, "nav.roundabout", .{ .n = @max(1, json.int(step, "exit")) });
    const modifier = json.strOr(step, "modifier", "straight");
    const action = labels.of("nav.mod.", modifier);
    return if (name.len > 0) labels.tf(a, "nav.onto", .{ .action = action, .name = name }) else action;
}

/// `TURN_ICON`.
fn turnIcon(step: ?V) zui.Icon {
    const st = step orelse return icons.location_on;
    if (std.mem.eql(u8, json.str(st, "type"), "arrive")) return icons.sports_score;
    const m = json.strOr(st, "modifier", "straight");
    const eq = std.mem.eql;
    if (eq(u8, m, "uturn")) return icons.u_turn_left;
    if (eq(u8, m, "sharp right")) return icons.turn_sharp_right;
    if (eq(u8, m, "right")) return icons.turn_right;
    if (eq(u8, m, "slight right")) return icons.turn_slight_right;
    if (eq(u8, m, "slight left")) return icons.turn_slight_left;
    if (eq(u8, m, "left")) return icons.turn_left;
    if (eq(u8, m, "sharp left")) return icons.turn_sharp_left;
    return icons.straight;
}

fn speakStep(s: *S, c: *Cx) void {
    if (!s.voice) return;
    const steps = routeSteps(c);
    if (steps.len == 0) return;
    const text = instruction(c.arena(), steps[@min(s.step, steps.len - 1)]);
    const h = std.hash.Wyhash.hash(0, text);
    if (h == s.last_spoken) return;
    s.last_spoken = h;
    c.fx.speak(text);
}

/// Sends a step action, or keeps it on the phone when there is no connection (`sendOrQueue`).
fn post(s: *S, c: *Cx, kind: A, path: []const u8, extra: []const u8) void {
    var b = json.Obj.init(c.arena());
    if (c.gps.current()) |f| {
        b.begin("location");
        b.num("lat", f.lat);
        b.num("lng", f.lng);
        b.end();
    }
    var body: []const u8 = b.done();
    // Extra fields (already JSON members) go in the same object.
    if (extra.len > 0) body = if (body.len <= 2) c.print("{{{s}}}", .{extra}) else c.print("{s},{s}}}", .{ body[0 .. body.len - 1], extra });
    const full = c.print("/courier/tasks/{s}/{s}", .{ json.str(task(c), "_id"), path });
    s.pending_path = full;
    s.pending_body = body;
    s.pending_kind = kind;
    // Earlier actions must reach the server first: this one waits behind them, and they are
    // sent now when there is a connection.
    if (gps.hasWaiting(c)) {
        queued(s, c, !c.online);
        if (c.online) gps.startOutbox(c);
        return;
    }
    c.quietErrors(@intFromEnum(kind));
    c.send(@intFromEnum(kind), .POST, c.orgUrl(full), body);
}

/// The action was kept on the phone: the screen moves on as if it was accepted (`offline`:
/// say so).
fn queued(s: *S, c: *Cx, offline: bool) void {
    gps.queue(c, s.pending_path, s.pending_body);
    c.fx.vibrate(80);
    const next: []const u8 = switch (s.pending_kind) {
        .accept => "accepted",
        .start => "in_progress",
        .deliver_send, .complete => "completed",
        .fail_send => "failed",
        else => "",
    };
    if (next.len > 0) s.status_override = next;
    if (offline) c.toast(L("outbox.saved_offline"), .ok);
    s.dialog = .none;
    switch (s.pending_kind) {
        .deliver_send, .complete, .fail_send => c.go("/driver"),
        else => {},
    }
}

fn reload(c: *Cx) void {
    c.load(d_task, c.orgUrl(c.print("/courier/tasks/{s}", .{core.encode(c.arena(), c.param(2))})));
}

pub fn update(s: *S, c: *Cx, e: core.Ev) void {
    if (courier.update(&s.chrome, c, e)) return;
    s.m.setSize(kit.width - 16, mapHeight(c.env.height));
    if (s.m.event(c, e) != null) return;
    switch (e) {
        .data => |n| switch (n) {
            d_task => {
                if (c.slot(d_task).state == .failed and (c.slot(d_task).status == 403 or c.slot(d_task).status == 404) and c.data(d_task) != null) return c.go("/driver");
                if (c.slot(d_task).state != .ok) return;
                s.status_override = "";
                // A new destination (picked up, now delivering) needs a new route straight away.
                if (s.route_to) |was| if (target(s, c)) |now| if (was.lat != now.lat or was.lng != now.lng) {
                    s.last_route_at = 0;
                    s.fit_route = true;
                    s.step = 0;
                    fetchRoute(s, c, false);
                };
                if (!s.fitted_places) {
                    s.fitted_places = true;
                    var pts: std.ArrayList(LatLng) = .empty;
                    if (mapw.ll(task(c), "from.location")) |p| pts.append(c.arena(), p) catch {};
                    if (target(s, c)) |p| pts.append(c.arena(), p) catch {};
                    if (here(c)) |p| pts.append(c.arena(), p) catch {};
                    s.m.fit(pts.items, .{ .animate = false });
                }
                onFix(s, c);
            },
            d_me => if (json.boolean(c.data(d_me), "onDuty") and !gps.isTracking(c)) {
                gps.start(c, courier.shiftTitle(c), courier.shiftBody());
            },
            d_route => {
                const sl = c.slot(d_route);
                if (sl.state == .failed or (sl.state == .ok and sl.err.len > 0 and sl.status >= 400)) {
                    if (s.manual_route) c.toast(sl.err, .err);
                    return;
                }
                s.step = 0;
                if (s.fit_route) {
                    s.fit_route = false;
                    s.m.fit(routePoints(c.arena(), c), .{ .padding = 30, .max_zoom = 17 });
                }
                speakStep(s, c);
            },
            else => {},
        },
        .located => onFix(s, c),
        .live => |ev| liveEvent(c, ev),
        .timer => |id| if (id == @intFromEnum(T.poll)) {
            c.liveDone();
            reload(c);
        },
        .photo => |p| if (p.id == 1) {
            if (p.data.len == 0) c.toast(L("task.photo_too_large"), .err) else s.photo = c.dupe(p.data);
        },
        .act => |a| switch (@as(A, @enumFromInt(a.id))) {
            .voice => {
                s.voice = !s.voice;
                s.last_spoken = 0;
                speakStep(s, c);
            },
            .recalc => fetchRoute(s, c, true),
            .accept => post(s, c, .accept, "accept", ""),
            .decline_ask => c.ask(L("task.decline_confirm"), .{ .act = .{ .id = @intFromEnum(A.decline) } }),
            .decline => c.send(@intFromEnum(A.decline), .POST, c.orgUrl(c.print("/courier/tasks/{s}/decline", .{json.str(task(c), "_id")})), "{}"),
            .start_ask => {
                const ty = json.str(task(c), "type");
                if (!std.mem.eql(u8, ty, "pickup") or json.arr(task(c), "shipments").len < 2) {
                    c.ask(labels.of("task.start_confirm.", ty), .{ .act = .{ .id = @intFromEnum(A.start_confirmed) } });
                } else {
                    s.missing = .empty;
                    s.dialog = .checklist;
                }
            },
            .start_confirmed => post(s, c, .start, "start", ""),
            .checklist_toggle => if (a.arg < 64) s.missing.toggle(a.arg),
            .checklist_send => {
                var ids: std.ArrayList(u8) = .empty;
                ids.append(c.arena(), '[') catch {};
                var first = true;
                for (json.arr(task(c), "shipments"), 0..) |x, i| {
                    if (i >= 64 or !s.missing.isSet(i)) continue;
                    if (!first) ids.append(c.arena(), ',') catch {};
                    first = false;
                    ids.print(c.arena(), "{f}", .{std.json.fmt(json.str(x, "_id"), .{})}) catch {};
                }
                ids.append(c.arena(), ']') catch {};
                post(s, c, .start, "start", c.print("\"missingShipmentIds\":{s}", .{ids.items}));
            },
            .deliver_open => {
                s.dialog = .deliver;
                s.photo = "";
                s.cod_collected = false;
                c.setVal(f_code, "");
                c.setVal(f_receiver, "");
                c.fx.focus(kit.slotKey(f_code));
            },
            .deliver_send => {
                var b = json.Obj.init(c.arena());
                // As Turf-js's formValues: empty fields left out, the cash box only when there
                // is cash to collect.
                b.begin("pod");
                b.strOpt("code", c.valTrim(f_code));
                b.strOpt("receiverName", c.valTrim(f_receiver));
                if (json.has(task(c), "shipments.0.cod")) b.boolean("codCollected", s.cod_collected);
                if (s.photo.len > 0) b.str("photo", s.photo);
                b.end();
                const obj = b.done();
                post(s, c, .deliver_send, "complete", obj[1 .. obj.len - 1]);
            },
            .photo => c.pickPhoto(1),
            .cod_toggle => s.cod_collected = !s.cod_collected,
            .fail_open => {
                s.dialog = .fail;
                c.setVal(f_reason, "recipient_unreachable");
                c.setVal(f_day, "");
                c.setVal(f_note, "");
            },
            .fail_send => {
                var b = json.Obj.init(c.arena());
                b.str("reason", c.val(f_reason));
                if (std.mem.eql(u8, c.val(f_reason), "reschedule_requested")) b.strOpt("rescheduleFor", c.valTrim(f_day));
                b.strOpt("note", c.valTrim(f_note));
                const obj = b.done();
                post(s, c, .fail_send, "fail", obj[1 .. obj.len - 1]);
            },
            .other_ask => c.ask(labels.of("task.complete_confirm.", json.str(task(c), "type")), .{ .act = .{ .id = @intFromEnum(A.other_confirmed) } }),
            .other_confirmed => post(s, c, .complete, "complete", ""),
            .close_dialog => s.dialog = .none,
            else => {},
        },
        .done => |d| {
            const kind: A = @enumFromInt(d.id);
            if (kind == .decline) {
                if (d.ok) c.go("/driver");
                return;
            }
            // No connection: kept on the phone.
            if (d.status == 0) return queued(s, c, true);
            if (!d.ok) {
                // A wrong delivery code shows under its field (the core did); others as a toast.
                if (c.field_err == null) c.toast(core.errorMessage(c.arena(), d.status, d.v, false), .err);
                return;
            }
            c.fx.vibrate(80);
            switch (kind) {
                .accept, .start => {
                    s.dialog = .none;
                    reload(c);
                },
                .deliver_send => {
                    s.dialog = .none;
                    c.toast(L("task.delivered_toast"), .ok);
                    c.go("/driver");
                },
                .fail_send, .complete => {
                    s.dialog = .none;
                    c.toast(L("common.saved"), .ok);
                    c.go("/driver");
                },
                else => {},
            }
        },
        else => {},
    }
}

fn mapHeight(screen_h: f32) f32 {
    return @max(260, screen_h * 0.42);
}

pub fn view(s: *const S, c: *const Cx, ui: *Ui) void {
    courier.begin(ui, c, &s.chrome, .{ .title = if (c.data(d_task) != null) labels.taskType(json.str(task(c), "type")) else c.appName(), .back = true });
    if (kit.gate(ui, &.{d_task})) bodyView(s, c, ui);
    courier.end(ui, c, &s.chrome);
}

fn bodyView(s: *const S, c: *const Cx, ui: *Ui) void {
    _ = kit.k;
    const t = task(c);
    const st = status(s, c);
    const a = ui.arena();
    ui.begin(.{ .direction = .row, .justify = .space_between, .align_items = .center }, .{});
    ui.begin(.{ .direction = .row, .gap = 6.4, .align_items = .center }, .{});
    kit.strong(ui, labels.taskType(json.str(t, "type")));
    if (json.boolean(t, "express")) kit.expressBadge(ui);
    ui.end();
    kit.statusBadgeText(ui, st, labels.taskStatus(st));
    ui.end();
    if (json.boolean(t, "express") and (std.mem.eql(u8, st, "assigned") or std.mem.eql(u8, st, "accepted") or std.mem.eql(u8, st, "in_progress"))) driver.dueLabel(ui, json.str(t, "dueBy"));

    // Navigation and the map.
    kit.card(ui, .{ .pad = 8, .gap = 8.8 });
    navPanel(s, c, ui);
    var pins: std.ArrayList(mapw.Pin) = .empty;
    if (mapw.ll(t, "from.location")) |p| if (!std.mem.eql(u8, json.str(t, "from.kind"), "courier")) pins.append(a, .{ .at = p, .icon = mapw.placeIcon(if (std.mem.eql(u8, json.str(t, "from.kind"), "hub")) "hub" else "shop"), .kind = .place, .key = zui.key("from"), .tip = json.str(t, "from.label") }) catch {};
    const dest = if (isDelivery(c)) mapw.ll(t, "shipments.0.dropoff.location") orelse mapw.ll(t, "to.location") else mapw.ll(t, "to.location");
    if (dest) |p| pins.append(a, .{ .at = p, .icon = mapw.placeIcon(if (std.mem.eql(u8, json.str(t, "to.kind"), "hub")) "hub" else if (isDelivery(c)) "home" else "shop"), .kind = .place, .key = zui.key("to"), .tip = json.str(t, "to.label") }) catch {};
    if (here(c)) |p| pins.append(a, .{ .at = p, .kind = .me, .key = zui.key("me") }) catch {};
    var lines: std.ArrayList(mapw.Line) = .empty;
    const route_pts = routePoints(a, c);
    if (route_pts.len > 1) lines.append(a, .{ .points = route_pts, .width = 6, .opacity = 0.75 }) catch {};
    mapw.draw(ui, &s.m, .{ .width = kit.width - 16, .height = mapHeight(ui.env.height), .radius = 18, .pins = pins.items, .lines = lines.items });
    ui.begin(.{ .direction = .row, .gap = 12, .align_items = .center }, .{});
    // Turf-js `busy()`: it spins while the route it asked for loads.
    const sl = c.slot(d_route);
    kit.button(ui, L("nav.recalculate"), kit.act(A.recalc, 0), .{ .size = .sm, .icon = icons.refresh, .working = s.manual_route and (sl.state == .loading or sl.reloading) });
    kit.small(ui, if (goingToStart(s, c)) L("nav.heading_to_start") else L("nav.heading_to_destination"));
    ui.end();
    kit.endCard(ui, .{});

    // The step actions.
    kit.stackTight(ui);
    const eq = std.mem.eql;
    const ty = json.str(t, "type");
    if (eq(u8, st, "assigned")) {
        kit.button(ui, L("task.accept"), kit.act(A.accept, 0), .{ .variant = .primary, .size = .lg, .block = true, .icon = icons.check, .busy = @intFromEnum(A.accept) });
        kit.button(ui, L("task.decline"), kit.act(A.decline_ask, 0), .{ .block = true, .busy = @intFromEnum(A.decline) });
    } else if (eq(u8, st, "accepted")) {
        kit.button(ui, labels.of("task.start.", ty), kit.act(A.start_ask, 0), .{ .variant = .primary, .size = .lg, .block = true, .icon = icons.check, .busy = @intFromEnum(A.start) });
        if (eq(u8, ty, "pickup") or eq(u8, ty, "direct")) kit.button(ui, L("task.pickup_failed"), kit.act(A.fail_open, 0), .{ .block = true });
    } else if (eq(u8, st, "in_progress")) {
        if (isDelivery(c)) {
            kit.button(ui, L("task.delivered"), kit.act(A.deliver_open, 0), .{ .variant = .primary, .size = .lg, .block = true, .icon = icons.check });
            kit.button(ui, L("task.failed_attempt"), kit.act(A.fail_open, 0), .{ .block = true });
        } else {
            kit.button(ui, labels.of("task.complete.", ty), kit.act(A.other_ask, 0), .{ .variant = .primary, .size = .lg, .block = true, .icon = icons.check, .busy = @intFromEnum(A.complete) });
        }
    } else kit.notice(ui, .info, labels.taskStatus(st));
    ui.end();

    parcelsCard(c, ui);
}

fn navPanel(s: *const S, c: *const Cx, ui: *Ui) void {
    const k = kit.k;
    const a = ui.arena();
    const dest = target(s, c) orelse {
        kit.notice(ui, .warn, L("nav.no_destination"));
        return;
    };
    const fix = here(c);
    const steps = routeSteps(c);
    const has_route = c.slot(d_route).state == .ok and steps.len > 0;
    ui.begin(.{ .direction = .row, .gap = 12.8, .align_items = .center, .padding = .xy(16, 14.4), .radius = 18, .background = k.panel }, .{});
    const step: ?V = if (has_route and fix != null) steps[@min(s.step, steps.len - 1)] else null;
    ui.begin(.{ .width = .{ .px = 51.2 }, .height = .{ .px = 51.2 }, .radius = 12, .background = k.a, .align_items = .center, .justify = .center }, .{});
    kit.icon(ui, turnIcon(step), 32, k.on_accent);
    ui.end();
    ui.begin(.{ .grow = 1, .gap = 2 }, .{});
    if (step) |stp| {
        ui.text(instruction(a, stp), .{ .font_size = 20, .weight = 700, .color = k.ink });
        const to_step = if (pt(json.get(stp, "location") orelse .null)) |loc| meters(fix.?, loc) else 0;
        const remaining = ui.tf(labels.english("nav.remaining") orelse "{d} {time}", .{ .d = fmt.distance(a, json.num(c.data(d_route), "distanceM")), .time = fmt.duration(a, (json.num(c.data(d_route), "durationS") orelse 0) / 60) });
        ui.text(kit.f(ui, "{s} · {s}", .{ fmt.distance(a, to_step), remaining }), .{ .font_size = 14, .weight = 500, .color = k.ink_2 });
    } else {
        ui.text(targetLabel(s, c), .{ .font_size = 20, .weight = 700, .color = k.ink });
        // Says so when the route could not be fetched (Maps' routing down, no road found),
        // instead of "Calculating route…" for ever; Recalculate and the Maps app stay there.
        const sl = c.slot(d_route);
        const route_failed = fix != null and (sl.state == .failed or (sl.state == .ok and sl.err.len > 0 and sl.status >= 400));
        const hint = if (fix == null) L("nav.waiting_gps") else if (!route_failed) L("nav.calculating") else if (sl.status == 422) L("error.no_route") else L("error.routing_unavailable");
        ui.text(hint, .{ .font_size = 14, .weight = 500, .color = if (route_failed) k.fatal_ink else k.ink_2 });
    }
    ui.end();
    ui.begin(.{ .gap = 6 }, .{});
    if (step != null) {
        // Dimmed while the voice is off.
        ui.begin(.{ .opacity = if (s.voice) 1 else 0.5, .align_self = .center }, .{});
        kit.iconButton(ui, icons.notifications, kit.act(A.voice, 0), .{ .size = .sm, .variant = .ghost, .label = L("nav.voice") });
        ui.end();
    }
    kit.button(ui, L("nav.open_maps"), .{ .open = mapw.externalNavUrl(a, dest) }, .{ .size = .sm, .icon = icons.open_in_new, .flip = true });
    ui.end();
    ui.end();
}

fn parcelsCard(c: *const Cx, ui: *Ui) void {
    const k = kit.k;
    const a = ui.arena();
    const t = task(c);
    const ships = json.arr(t, "shipments");
    kit.card(ui, .{ .gap = 8.8 });
    kit.h2(ui, ui.tf(labels.english("dispatch.parcels_n") orelse "{n}", .{ .n = ships.len }));
    for (ships, 0..) |x, i| {
        const contact = json.obj(x, if (isDelivery(c)) "dropoff" else "pickup");
        kit.line(ui, k.line);
        ui.begin(.{ .gap = 8.8, .padding = .{ .top = 8 } }, .{ .key = zui.key(i + 1) });
        ui.begin(.{ .direction = .row, .justify = .space_between, .align_items = .center }, .{});
        kit.mono(ui, json.str(x, "trackingNumber"), .{ .weight = 700 });
        kit.statusBadge(ui, json.str(x, "status"));
        ui.end();
        ui.begin(.{ .gap = 2 }, .{});
        kit.strong(ui, json.strOr(contact, "name", "—"));
        var addr: std.ArrayList(u8) = .empty;
        for ([_][]const u8{ json.str(contact, "street"), json.str(contact, "area"), json.str(contact, "city") }) |p| {
            if (p.len == 0) continue;
            if (addr.items.len > 0) addr.appendSlice(a, "، ") catch {};
            addr.appendSlice(a, p) catch {};
        }
        if (addr.items.len > 0) kit.text(ui, addr.items, .{ .size = 13.6 });
        ui.end();
        if (json.str(contact, "details").len > 0) kit.small(ui, json.str(contact, "details"));
        if (isDelivery(c) and std.mem.eql(u8, json.str(x, "dropoff.locationSource"), "recipient")) {
            ui.begin(.{ .direction = .row, .gap = 4, .align_items = .center }, .{});
            kit.icon(ui, icons.location_on, 16, k.ok_ink);
            ui.text(L("task.recipient_pinned"), .{ .font_size = 14, .color = k.ok_ink });
            ui.end();
        }
        ui.begin(.{ .direction = .row, .gap = 8 }, .{});
        kit.badge(ui, kit.f(ui, "{s} {s}", .{ fmt.number(a, json.numOr(x, "parcel.weightKg", 0), 2), L("unit.kg") }), .plain);
        if (json.boolean(x, "parcel.fragile")) kit.badge(ui, L("shipment.fragile"), .amber);
        if (json.obj(x, "cod")) |cod| kit.badgeIcon(ui, fmt.money(a, json.num(cod, "amount"), json.str(cod, "currency")), .amber, icons.payments);
        if (json.int(x, "attempts") > 0) kit.badge(ui, ui.tf(labels.english("shipment.attempts_n") orelse "{n}", .{ .n = json.int(x, "attempts") }), .red);
        ui.end();
        if (json.str(x, "notes").len > 0) kit.notice(ui, .info, json.str(x, "notes"));
        const phone = json.str(contact, "phone");
        if (phone.len > 0) {
            ui.begin(.{ .direction = .row, .gap = 12 }, .{});
            kit.button(ui, if (isDelivery(c)) L("task.call_recipient") else L("task.call_sender"), .{ .open = kit.f(ui, "tel:{s}", .{phone}) }, .{ .size = .sm, .icon = icons.call });
            kit.button(ui, "WhatsApp", .{ .open = whatsapp(a, phone) }, .{ .size = .sm });
            ui.end();
        }
        ui.end();
    }
    kit.endCard(ui, .{});
}

/// wa.me with the Syrian number in international form.
fn whatsapp(a: std.mem.Allocator, phone: []const u8) []const u8 {
    var p = phone;
    if (p.len > 0 and p[0] == '+') p = p[1..];
    if (p.len > 0 and p[0] == '0') return std.fmt.allocPrint(a, "https://wa.me/963{s}", .{p[1..]}) catch "";
    return std.fmt.allocPrint(a, "https://wa.me/{s}", .{p}) catch "";
}

pub fn overlay(s: *const S, c: *const Cx, ui: *Ui) void {
    courier.overlay(ui, c, &s.chrome);
    switch (s.dialog) {
        .none => {},
        .checklist => checklist(s, c, ui),
        .deliver => deliverDialog(s, c, ui),
        .fail => failDialog(s, c, ui),
    }
}

fn checklist(s: *const S, c: *const Cx, ui: *Ui) void {
    shell.modalBegin(ui, .{ .title = L("task.pickup_checklist"), .close = kit.act(A.close_dialog, 0), .key = zui.key("checklist") });
    kit.muted(ui, L("task.pickup_checklist_hint"));
    for (json.arr(task(c), "shipments"), 0..) |x, i| {
        const label = kit.f(ui, "{s}  {s} {s}", .{ json.str(x, "trackingNumber"), fmt.number(ui.arena(), json.numOr(x, "parcel.weightKg", 0), 2), L("unit.kg") });
        kit.check(ui, label, i >= 64 or !s.missing.isSet(i), kit.act(A.checklist_toggle, @intCast(i)));
    }
    shell.modalFoot(ui);
    shell.modalButton(ui, L("common.cancel"), kit.act(A.close_dialog, 0), .{});
    shell.modalButton(ui, L("task.picked_up_selected"), kit.act(A.checklist_send, 0), .{ .variant = .primary, .busy = @intFromEnum(A.start) });
    shell.modalEnd(ui, true);
}

fn deliverDialog(s: *const S, c: *const Cx, ui: *Ui) void {
    const k = kit.k;
    const x = json.get(task(c), "shipments.0");
    const require_code = json.boolean(x, "requireCode");
    shell.modalBegin(ui, .{ .title = L("task.confirm_delivery"), .close = kit.act(A.close_dialog, 0), .key = zui.key("deliver") });
    // Enter in a one-line field confirms the delivery (the dialog's primary action).
    const submit = kit.act(A.deliver_send, 0);
    if (require_code) kit.field(ui, L("task.delivery_code"), f_code, .{ .required = true, .hint = L("task.delivery_code_hint"), .input = .{ .kind = .code, .name = "code", .ltr = true, .size = 33.6, .height = 64, .@"align" = .center, .weight = 700, .on_submit = submit } });
    kit.field(ui, L("shipment.receiver_name"), f_receiver, .{ .input = .{ .name = "pod.receiverName", .on_submit = submit } });
    kit.fieldBegin(ui, L("task.photo"), false);
    // The camera on every platform (Cx.pickPhoto); the photo shows below once taken.
    kit.button(ui, L("task.photo"), kit.act(A.photo, 0), .{ .icon = icons.photo_camera, .block = true });
    kit.fieldEnd(ui, "pod.photo", if (require_code) L("task.photo_optional") else L("task.photo_recommended"));
    if (s.photo.len > 0) {
        ui.begin(.{ .radius = 18, .background = k.panel_2, .clip = true, .height = .{ .px = 240 } }, .{});
        ui.image(s.photo, .{ .width = .fill, .height = .{ .px = 240 } }, zui.key("photo"));
        ui.end();
    }
    if (json.obj(x, "cod")) |cod| {
        kit.noticeBegin(ui, .warn, icons.payments);
        kit.check(ui, ui.tf(labels.english("shipment.cod_collected") orelse "{amount}", .{ .amount = fmt.money(ui.arena(), json.num(cod, "amount"), json.str(cod, "currency")) }), s.cod_collected, kit.act(A.cod_toggle, 0));
        kit.noticeEnd(ui);
    }
    shell.modalFoot(ui);
    shell.modalButton(ui, L("common.cancel"), kit.act(A.close_dialog, 0), .{});
    shell.modalButton(ui, L("task.delivered"), kit.act(A.deliver_send, 0), .{ .variant = .primary, .busy = @intFromEnum(A.deliver_send) });
    shell.modalEnd(ui, true);
}

fn failDialog(s: *const S, c: *const Cx, ui: *Ui) void {
    _ = s;
    var opts: std.ArrayList(core.Opt) = .empty;
    if (json.obj(c.meta.value, "failureReasons")) |r| {
        var it = r.object.iterator();
        while (it.next()) |kv| opts.append(ui.arena(), .{ .value = kv.key_ptr.*, .label = json.pick(kv.value_ptr.*, "", c.lang()) }) catch {};
    }
    shell.modalBegin(ui, .{ .title = if (isDelivery(c)) L("task.failed_attempt") else L("task.pickup_failed"), .close = kit.act(A.close_dialog, 0), .key = zui.key("fail") });
    kit.selectField(ui, L("task.fail_reason"), f_reason, opts.items, .{ .required = true, .name = "reason" });
    if (std.mem.eql(u8, c.val(f_reason), "reschedule_requested")) {
        // The platform's date picker: today to 14 days ahead.
        kit.dateField(ui, L("task.new_day"), f_day, .{ .hint = L("task.new_day_hint"), .min = fmt.isoDay(ui.arena(), fmt.now()), .max = fmt.isoDay(ui.arena(), fmt.now() + 14 * 86_400_000), .placeholder = L("common.choose"), .name = "rescheduleFor" });
    }
    kit.field(ui, L("task.fail_note"), f_note, .{ .input = .{ .name = "note" } });
    shell.modalFoot(ui);
    shell.modalButton(ui, L("common.cancel"), kit.act(A.close_dialog, 0), .{});
    shell.modalButton(ui, L("task.report"), kit.act(A.fail_send, 0), .{ .variant = .danger, .busy = @intFromEnum(A.fail_send) });
    shell.modalEnd(ui, true);
}

// ---- Tests --------------------------------------------------------------------------------

const app = @import("../app.zig");
const testing = std.testing;

const delivery_task =
    \\{"_id":"t9","type":"delivery","status":"in_progress","from":{"label":"Hub","kind":"hub","location":{"lat":33.5,"lng":36.27}},
    \\ "to":{"label":"Mazzeh","kind":"address","location":{"lat":33.51,"lng":36.25}},
    \\ "shipments":[{"_id":"s1","trackingNumber":"TRF1","status":"out_for_delivery","requireCode":true,"parcel":{"weightKg":1},
    \\   "cod":{"amount":450000,"currency":"SYP"},"dropoff":{"name":"Rami","phone":"0944000001","city":"Damascus","location":{"lat":33.51,"lng":36.25}}}]}
;
const route_json =
    \\{"distanceM":2400,"durationS":420,"geometry":[[33.5138,36.2765],[33.512,36.26],[33.51,36.25]],
    \\ "steps":[{"type":"depart","name":"Baghdad St","location":[33.5138,36.2765]},{"type":"turn","modifier":"left","name":"Mazzeh Hwy","location":[33.512,36.26]},{"type":"arrive","location":[33.51,36.25]}]}
;

fn openTask() !void {
    try app.startSignedIn("/o/fast/driver/task/t9");
    try testing.expect(app.D.respond("/api/app/orgs/o2", 200, driver.org_json));
    try testing.expect(app.D.respond("/courier/tasks/t9", 200, delivery_task));
    try testing.expect(app.D.respond("/courier/me", 200, "{\"onDuty\":false}"));
}

test "task: navigation from the route, spoken turns" {
    try openTask();
    defer app.D.reset();
    const D = app.D;
    try testing.expect(D.findText("Rami") != 0);
    try testing.expect(D.findText("Waiting for GPS…") != 0 or D.findText(L("nav.waiting_gps")) != 0);
    D.locate(33.5138, 36.2765);
    try testing.expect(D.respond("/courier/route?from=33.5138,36.2765&to=33.51,36.25", 200, route_json));
    try testing.expect(D.findText("Head out on Baghdad St") != 0);
    try D.press("WhatsApp");
    try testing.expectEqualStrings("https://wa.me/963944000001", zui.host.opened.items);
}

test "task: delivered with the code; a wrong code shows under the field" {
    try openTask();
    defer app.D.reset();
    const D = app.D;
    try D.press("Delivered");
    try D.typeInto("", "1234");
    D.R.dispatch(.{ .act = .{ .id = @intFromEnum(A.cod_toggle) } });
    // Enter in the code field confirms.
    try D.inputEvent("", .submit);
    const f = zui.host.fetches.items[zui.host.fetches.items.len - 1];
    try testing.expect(std.mem.endsWith(u8, f.url, "/courier/tasks/t9/complete"));
    try testing.expect(std.mem.indexOf(u8, f.body, "\"codCollected\":true") != null);
    try testing.expect(std.mem.indexOf(u8, f.body, "receiverName") == null);
    try testing.expect(D.respond("/tasks/t9/complete", 400, "{\"error\":{\"code\":\"invalid_request\",\"message\":\"The delivery code is not correct\",\"field\":\"code\",\"rule\":\"wrong_code\"}}"));
    try testing.expect(D.R.appState().fieldError("code") != null);
    D.R.dispatch(.{ .act = .{ .id = @intFromEnum(A.deliver_send) } });
    try testing.expect(D.respond("/tasks/t9/complete", 200, "{\"ok\":true}"));
    try testing.expectEqualStrings("/driver", D.R.appState().route());
}

test "task: without a connection the action waits on the phone, in order" {
    try openTask();
    defer app.D.reset();
    const D = app.D;
    try D.press("Could not deliver");
    D.R.dispatch(.{ .act = .{ .id = @intFromEnum(A.fail_send) } });
    try testing.expect(D.respond("/tasks/t9/fail", 0, ""));
    try testing.expectEqual(@as(usize, 1), D.R.appState().gps.outboxCount());
    try testing.expectEqualStrings("/driver", D.R.appState().route());
    const kept = zui.host.stored.get("turf.outbox.o2").?;
    try testing.expect(std.mem.indexOf(u8, kept, "\"clientAt\":") != null);
    try testing.expect(std.mem.indexOf(u8, kept, "\"reason\":\"recipient_unreachable\"") != null);
    // Back online: sent, then removed.
    D.R.dispatch(.{ .host = .{ .online = true } });
    try testing.expect(D.respond("/courier/tasks/t9/fail", 200, "{}"));
    try testing.expectEqual(@as(usize, 0), D.R.appState().gps.outboxCount());
}

test "task: only this task's live changes reload it" {
    try openTask();
    defer app.D.reset();
    const D = app.D;
    D.serverStatus(200);
    D.serverSend("event: task.changed\ndata: {\"taskId\":\"t1\"}\n\n");
    try testing.expect(D.pending("/courier/tasks/t9") == null);
    D.serverSend("event: task.changed\ndata: {\"taskId\":\"t9\"}\n\n");
    try testing.expect(D.pending("/courier/tasks/t9") != null);
}
