//! Driver home (Turf-js views/courier/driver.js): the shift on/off (with the location consent
//! before the first one), today's tasks, cash in hand and the work summary. A new assigned task
//! rings (an urgent notification over the lock screen on the phones, a toast, sound and
//! vibration on the web). While on shift the GPS tracker runs (gps.zig), with the screen off too.

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

const Cx = core.Cx;
const Ui = core.Ui;
const V = json.V;
const L = labels.k;

const d_me: u8 = 0;
const d_tasks: u8 = 1;

const A = enum(u16) {
    toggle = 1,
    duty,
    consent_open,
    consent_agree,
    consent_close,
    open_task,
    accept,
    decline_ask,
    decline,
    show_done,
    end_confirmed,
};

const T = enum(u16) { poll = 1, after_duty, fallback };

/// Fallback reload in case the live connection drops on a weak network.
const fallback_ms = 60_000;

/// Id of the new-task alarm notification.
pub const alarm_id: u32 = 901;

pub const S = struct {
    chrome: courier.Chrome = .{},
    /// A shift change is on its way: the button does not take a second tap, and reloads keep
    /// showing the state being switched to.
    switching: bool = false,
    going_on: bool = false,
    consent: bool = false,
    show_done: bool = false,
    /// On duty as last known (the screen follows a change at once).
    on_duty: bool = false,
    /// Assigned task ids already seen (a new one rings).
    known: std.ArrayList(u64) = .empty,
    seeded: bool = false,
};

pub fn title(_: *const S, c: *const Cx) []const u8 {
    return c.appName();
}

pub fn enter(_: *S, c: *Cx) void {
    reload(c);
    // New and changed tasks arrive as live events (Server-Sent Events).
    c.orgLive(@intFromEnum(T.poll), &.{"task.changed"});
    c.after(fallback_ms, @intFromEnum(T.fallback));
    c.fx.cancelNotify(alarm_id);
}

fn reload(c: *Cx) void {
    c.load(d_me, c.orgUrl("/courier/me"));
    c.load(d_tasks, c.orgUrl("/courier/tasks"));
}

fn taskAt(c: *const Cx, i: u32) ?V {
    const list = json.arr(c.data(d_tasks), "");
    return if (i < list.len) list[i] else null;
}

fn isOpen(t: V) bool {
    const st = json.str(t, "status");
    return std.mem.eql(u8, st, "assigned") or std.mem.eql(u8, st, "accepted") or std.mem.eql(u8, st, "in_progress");
}

fn order(st: []const u8) u8 {
    const names = [_][]const u8{ "in_progress", "accepted", "assigned", "completed", "failed" };
    for (names, 0..) |n, i| if (std.mem.eql(u8, n, st)) return @intCast(i);
    return 9;
}

/// Express trips first (promised within the hour), then by progress.
fn openTasks(a: std.mem.Allocator, c: *const Cx) []const usize {
    var out: std.ArrayList(usize) = .empty;
    for (json.arr(c.data(d_tasks), ""), 0..) |t, i| if (isOpen(t)) out.append(a, i) catch {};
    const list = json.arr(c.data(d_tasks), "");
    std.mem.sort(usize, out.items, list, struct {
        fn less(l: []const V, x: usize, y: usize) bool {
            const ex = json.boolean(l[x], "express");
            const ey = json.boolean(l[y], "express");
            if (ex != ey) return ex;
            return order(json.str(l[x], "status")) < order(json.str(l[y], "status"));
        }
    }.less);
    return out.items;
}

fn startShift(s: *S, c: *Cx) void {
    s.switching = true;
    s.going_on = true;
    gps.start(c, courier.shiftTitle(c), courier.shiftBody());
    c.fx.keepAwake(true);
    c.send(@intFromEnum(A.duty), .POST, c.orgUrl("/courier/duty"), "{\"onDuty\":true}");
}

fn endShift(s: *S, c: *Cx) void {
    s.switching = true;
    s.going_on = false;
    gps.flush(c);
    c.send(@intFromEnum(A.duty), .POST, c.orgUrl("/courier/duty"), "{\"onDuty\":false}");
}

pub fn update(s: *S, c: *Cx, e: core.Ev) void {
    if (courier.update(&s.chrome, c, e)) return;
    switch (e) {
        .data => |n| switch (n) {
            d_me => {
                if (s.switching) return;
                s.on_duty = json.boolean(c.data(d_me), "onDuty");
                if (s.on_duty and !gps.isTracking(c)) {
                    gps.start(c, courier.shiftTitle(c), courier.shiftBody());
                    c.fx.keepAwake(true);
                }
                widget(s, c);
            },
            d_tasks => {
                // A newly assigned task rings.
                var fresh: ?V = null;
                var ids: std.ArrayList(u64) = .empty;
                for (json.arr(c.data(d_tasks), "")) |t| {
                    if (!std.mem.eql(u8, json.str(t, "status"), "assigned")) continue;
                    const h = std.hash.Wyhash.hash(0, json.str(t, "_id"));
                    ids.append(c.arena(), h) catch {};
                    if (std.mem.indexOfScalar(u64, s.known.items, h) == null and fresh == null) fresh = t;
                }
                if (s.seeded) if (fresh) |t| announce(c, t);
                s.known = ids;
                s.seeded = true;
                widget(s, c);
            },
            else => {},
        },
        .timer => |id| if (id == @intFromEnum(T.poll)) {
            c.liveDone();
            reload(c);
        } else if (id == @intFromEnum(T.fallback)) {
            reload(c);
            c.after(fallback_ms, @intFromEnum(T.fallback));
        },
        .act => |a| switch (@as(A, @enumFromInt(a.id))) {
            .toggle => {
                if (s.switching) return;
                if (s.on_duty) {
                    c.ask(L("driver.end_shift_confirm"), .{ .act = .{ .id = @intFromEnum(A.end_confirmed) } });
                } else if (json.boolean(c.data(d_me), "needsLocationConsent")) {
                    s.consent = true;
                } else startShift(s, c);
            },
            .end_confirmed => endShift(s, c),
            .consent_close => s.consent = false,
            .consent_agree => c.send(@intFromEnum(A.consent_agree), .POST, c.orgUrl("/courier/consent"), "{\"version\":1}"),
            .open_task => if (taskAt(c, a.arg)) |t| {
                c.fx.cancelNotify(alarm_id);
                c.go(c.print("/driver/task/{s}", .{json.str(t, "_id")}));
            },
            .accept => if (taskAt(c, a.arg)) |t| {
                c.fx.cancelNotify(alarm_id);
                c.sendArg(@intFromEnum(A.accept), a.arg, .POST, c.orgUrl(c.print("/courier/tasks/{s}/accept", .{json.str(t, "_id")})), "{}");
            },
            .decline_ask => c.ask(L("task.decline_confirm"), .{ .act = .{ .id = @intFromEnum(A.decline), .arg = a.arg } }),
            .decline => if (taskAt(c, a.arg)) |t| {
                c.fx.cancelNotify(alarm_id);
                c.sendArg(@intFromEnum(A.decline), a.arg, .POST, c.orgUrl(c.print("/courier/tasks/{s}/decline", .{json.str(t, "_id")})), "{}");
            },
            .show_done => s.show_done = !s.show_done,
            else => {},
        },
        .done => |d| switch (@as(A, @enumFromInt(d.id))) {
            .consent_agree => if (d.ok) {
                s.consent = false;
                startShift(s, c);
            },
            .duty => {
                s.switching = false;
                if (!d.ok) {
                    if (s.going_on) gps.stop(c, true);
                } else {
                    if (!s.going_on) {
                        gps.stop(c, true);
                        c.fx.keepAwake(false);
                    }
                    // The screen follows at once, even if the refresh below fails.
                    s.on_duty = s.going_on;
                }
                reload(c);
            },
            .accept, .decline => if (d.ok) reload(c),
            else => {},
        },
        else => {},
    }
}

/// A new task: toast, sound, vibration, and the urgent notification (phones: over the lock
/// screen with an insistent alarm until the courier opens or answers it).
fn announce(c: *Cx, t: V) void {
    const kind = labels.taskType(json.str(t, "type"));
    c.toast(labels.tf(c.arena(), "driver.new_task", .{ .type = kind }), .ok);
    c.fx.beep();
    c.fx.vibrate(800);
    c.fx.notify(.{
        .id = alarm_id,
        .title = L("driver.new_task_title"),
        .body = c.print("{s}: {s} \u{2192} {s}", .{ kind, json.str(t, "from.label"), json.str(t, "to.label") }),
        .urgent = true,
    });
}

fn widget(s: *S, c: *Cx) void {
    var arena = std.heap.ArenaAllocator.init(core.gpa);
    defer arena.deinit();
    const open = openTasks(arena.allocator(), c);
    const list = json.arr(c.data(d_tasks), "");
    courier.widget(c, s.on_duty, if (open.len > 0) list[open[0]] else null, open.len);
}

pub fn view(s: *const S, c: *const Cx, ui: *Ui) void {
    courier.begin(ui, c, &s.chrome, .{ .title = c.appName() });
    if (kit.gate(ui, &.{ d_me, d_tasks })) bodyView(s, c, ui);
    courier.end(ui, c, &s.chrome);
}

fn bodyView(s: *const S, c: *const Cx, ui: *Ui) void {
    const k = kit.k;
    const me = c.data(d_me);
    const a = ui.arena();
    const on = if (s.switching) s.going_on else s.on_duty;

    // The shift card.
    kit.card(ui, .{ .gap = 12.8, .align_items = .center });
    ui.text(if (on) L("driver.on_duty") else L("driver.off_duty"), .{ .font_size = 21.6, .weight = 850, .color = k.ink, .text_align = .center });
    if (on and json.str(me, "dutySince").len > 0)
        kit.small(ui, ui.tf(labels.english("driver.since") orelse "{when}", .{ .when = fmt.time(a, json.str(me, "dutySince")) }))
    else
        ui.text(L("driver.off_duty_hint"), .{ .font_size = 13.6, .color = k.ink_2, .text_align = .center });
    kit.button(ui, if (on) L("driver.end_shift") else L("driver.start_shift"), kit.act(A.toggle, 0), .{ .variant = if (on) .normal else .primary, .size = .lg, .block = true, .icon = icons.power_settings_new, .busy = if (s.switching) @intFromEnum(A.duty) else null });
    var w = kit.Wrap.begin(ui, kit.width - 40, 8);
    const vehicle = labels.vehicle(json.str(me, "courier.vehicle"));
    w.item(kit.estimate(vehicle, 12) + 21);
    kit.badge(ui, vehicle, .plain);
    const done = ui.tf(labels.english("driver.done_today") orelse "{n}", .{ .n = json.int(me, "doneToday") });
    w.item(kit.estimate(done, 12) + 21);
    kit.badge(ui, done, .green);
    for (json.arr(me, "cashInHand")) |cash| {
        const m = fmt.money(a, json.num(cash, "amount"), json.str(cash, "currency"));
        w.item(kit.estimate(m, 12) + 40);
        kit.badgeIcon(ui, m, .amber, icons.payments);
    }
    w.end();
    if (json.obj(me, "summary")) |sum| workSummary(ui, sum);
    kit.endCard(ui, .{});

    // The tasks.
    kit.stackTight(ui);
    kit.h2(ui, L("driver.my_tasks"));
    const open = openTasks(a, c);
    const list = json.arr(c.data(d_tasks), "");
    if (open.len == 0) kit.empty(ui, if (on) L("driver.no_tasks_on_duty") else L("driver.no_tasks_off_duty"));
    for (open) |i| taskCard(ui, c, list[i], @intCast(i));
    var done_n: usize = 0;
    for (list) |t| {
        const st = json.str(t, "status");
        if (std.mem.eql(u8, st, "completed") or std.mem.eql(u8, st, "failed")) done_n += 1;
    }
    if (done_n > 0) {
        ui.begin(.{ .direction = .row, .gap = 6, .align_items = .center, .pressed_opacity = 0.6, .align_self = .start }, .{ .on_press = kit.act(A.show_done, 0) });
        kit.icon(ui, if (s.show_done) icons.expand_less else icons.expand_more, 20, k.ink_2);
        kit.muted(ui, ui.tf(labels.english("driver.done_today") orelse "{n}", .{ .n = done_n }));
        ui.end();
        if (s.show_done) for (list, 0..) |t, i| {
            const st = json.str(t, "status");
            if (std.mem.eql(u8, st, "completed") or std.mem.eql(u8, st, "failed")) taskCard(ui, c, t, @intCast(i));
        };
    }
    ui.end();
}

/// Today's and this week's finished work (and pay, when the company set courier rates).
fn workSummary(ui: *Ui, sum: V) void {
    const k = kit.k;
    // `.work-summary`: a line above, the rows left-aligned.
    ui.begin(.{ .gap = 5.6, .width = .fill, .padding = .{ .top = 9.6 }, .borders = .{ .top = .{ .width = 1, .color = k.line_soft } } }, .{});
    inline for (.{ .{ "driver.today", "today" }, .{ "driver.last_7_days", "week" } }) |x| {
        const p = json.obj(sum, x[1]);
        ui.begin(.{ .direction = .row, .gap = 8, .align_items = .center }, .{});
        ui.text(L(x[0]), .{ .font_size = 14.4, .weight = 700, .color = k.ink });
        ui.text(ui.tf(labels.english("driver.work_counts") orelse "{d} {p} {f}", .{ .d = json.int(p, "deliveries"), .p = json.int(p, "pickups"), .f = json.int(p, "failed") }), .{ .font_size = 14.4, .color = k.ink_2, .grow = 1 });
        if (json.boolean(sum, "paid")) kit.badge(ui, fmt.money(ui.arena(), json.num(p, "pay"), json.str(sum, "currency")), .green);
        ui.end();
    }
    ui.end();
}

/// The express trip's due time (red once late).
pub fn dueLabel(ui: *Ui, due_by: []const u8) void {
    const ms = fmt.parseIso(due_by) orelse return;
    const k = kit.k;
    const late = ms < fmt.now();
    const color = if (late) k.fatal_ink else k.a;
    ui.begin(.{ .direction = .row, .gap = 4, .align_items = .center }, .{});
    kit.icon(ui, icons.timer, 16.5, color);
    ui.text(ui.tf(labels.english(if (late) "express.late" else "express.due") orelse "{time}", .{ .time = fmt.time(ui.arena(), due_by) }), .{ .font_size = 15, .weight = 750, .color = color });
    ui.end();
}

fn taskCard(ui: *Ui, c: *const Cx, t: V, i: u32) void {
    const k = kit.k;
    const a = ui.arena();
    const st = json.str(t, "status");
    const express = json.boolean(t, "express");
    const ships = json.arr(t, "shipments");
    var cod: f64 = 0;
    var currency: []const u8 = "";
    var fragile = false;
    for (ships) |x| {
        if (json.num(x, "cod.amount")) |n| {
            cod += n;
            currency = json.str(x, "cod.currency");
        }
        if (json.boolean(x, "parcel.fragile")) fragile = true;
    }
    const o: kit.CardOpts = .{ .gap = 9.6, .edge = @import("../theme.zig").status(&k, st), .on_press = kit.act(A.open_task, i), .key = zui.key(json.str(t, "_id")), .ring = if (express) k.a else null };
    kit.card(ui, o);
    ui.begin(.{ .direction = .row, .justify = .space_between, .align_items = .center, .gap = 8 }, .{});
    ui.begin(.{ .direction = .row, .gap = 6.4, .align_items = .center }, .{});
    kit.strong(ui, labels.taskType(json.str(t, "type")));
    if (express) kit.expressBadge(ui);
    ui.end();
    kit.statusBadgeText(ui, st, labels.taskStatus(st));
    ui.end();
    if (express and isOpen(t)) dueLabel(ui, json.str(t, "dueBy"));
    ui.begin(.{ .gap = 4.8 }, .{});
    routeLine(ui, icons.location_on, json.str(t, "from.label"), false);
    routeLine(ui, icons.arrow_forward, json.str(t, "to.label"), true);
    ui.end();
    var w = kit.Wrap.begin(ui, kit.width - 45, 12);
    const n = ui.tf(labels.english("dispatch.parcels_n") orelse "{n}", .{ .n = ships.len });
    w.item(kit.estimate(n, 13.6));
    kit.small(ui, n);
    if (cod > 0) {
        const m = fmt.money(a, cod, currency);
        w.item(kit.estimate(m, 12) + 40);
        kit.badgeIcon(ui, m, .amber, icons.payments);
    }
    if (fragile) {
        w.item(kit.estimate(L("shipment.fragile"), 12) + 21);
        kit.badge(ui, L("shipment.fragile"), .amber);
    }
    const rel = fmt.relative(a, json.str(t, "updatedAt"));
    w.item(kit.estimate(rel, 13.6));
    kit.small(ui, rel);
    w.end();
    if (std.mem.eql(u8, st, "assigned")) {
        // Only this card's button shows the spinner.
        const busy_on = struct {
            fn f(cx: *const Cx, id: A, row: u32) ?u16 {
                const code = @intFromEnum(id);
                return if (cx.isBusy(code) and (cx.act_args.get(code) orelse 0) == row) code else null;
            }
        }.f;
        ui.begin(.{ .direction = .row, .gap = 12 }, .{});
        kit.button(ui, L("task.accept"), kit.act(A.accept, i), .{ .variant = .primary, .icon = icons.check, .busy = busy_on(c, .accept, i) });
        kit.button(ui, L("task.decline"), kit.act(A.decline_ask, i), .{ .variant = .ghost, .busy = busy_on(c, .decline, i) });
        ui.end();
    } else if (std.mem.eql(u8, st, "accepted") or std.mem.eql(u8, st, "in_progress")) {
        ui.begin(.{ .direction = .row }, .{});
        kit.button(ui, if (std.mem.eql(u8, st, "accepted")) L("task.open_and_start") else L("task.continue"), kit.act(A.open_task, i), .{ .variant = .primary, .icon = icons.navigation });
        ui.end();
    }
    kit.endCard(ui, o);
}

fn routeLine(ui: *Ui, ic: zui.Icon, s: []const u8, flip: bool) void {
    const k = kit.k;
    ui.begin(.{ .direction = .row, .gap = 8, .align_items = .start }, .{});
    if (flip) kit.iconFlip(ui, ic, 20, k.ink_3) else kit.icon(ui, ic, 20, k.ink_3);
    ui.text(s, .{ .font_size = 15, .color = k.ink, .grow = 1 });
    ui.end();
}

/// Location consent before the first shift.
pub fn overlay(s: *const S, c: *const Cx, ui: *Ui) void {
    courier.overlay(ui, c, &s.chrome);
    if (!s.consent) return;
    const k = kit.k;
    shell.modalBegin(ui, .{ .title = L("consent.title"), .close = kit.act(A.consent_close, 0), .key = zui.key("consent") });
    kit.text(ui, ui.tf(labels.english("consent.intro") orelse "{company}", .{ .company = c.appName() }), .{});
    const days = json.int(c.data(d_me), "locationRetentionDays");
    const points = [_]struct { zui.Icon, []const u8 }{
        .{ icons.navigation, L("consent.what") },
        .{ icons.power_settings_new, L("consent.when") },
        .{ icons.group, L("consent.who") },
        .{ icons.warning, L("consent.why") },
        .{ icons.history, ui.tf(labels.english("consent.keep") orelse "{days}", .{ .days = days }) },
    };
    for (points) |p| {
        ui.begin(.{ .direction = .row, .gap = 9.6, .align_items = .start }, .{});
        kit.icon(ui, p[0], 20.25, k.ink);
        kit.text(ui, p[1], .{ .grow = 1 });
        ui.end();
    }
    shell.modalFoot(ui);
    shell.modalButton(ui, L("consent.decline"), kit.act(A.consent_close, 0), .{});
    shell.modalButton(ui, L("consent.agree"), kit.act(A.consent_agree, 0), .{ .variant = .primary, .busy = @intFromEnum(A.consent_agree) });
    shell.modalEnd(ui, true);
}

// ---- Tests --------------------------------------------------------------------------------

const app = @import("../app.zig");
const testing = std.testing;

pub const org_json =
    \\{"id":"o2","type":"carrier","name":"Fast Express","slug":"fast","status":"active","contact":{"phone":"0944000000"},
    \\ "branding":{"appName":"Fast Express"},
    \\ "me":{"memberId":"m1","isOwner":false,"role":{"id":"r1","name":"Courier"},"permissions":["courier.work"],"courier":{"vehicle":"motorbike"},"onDuty":false}}
;
const me_off =
    \\{"memberId":"m1","name":"Dana","courier":{"vehicle":"motorbike"},"onDuty":false,"dutySince":null,"needsLocationConsent":true,
    \\ "locationRetentionDays":30,"doneToday":2,"cashInHand":[{"currency":"SYP","amount":450000,"count":1}],
    \\ "summary":{"today":{"deliveries":2,"pickups":1,"failed":0,"pay":0},"week":{"deliveries":9,"pickups":4,"failed":1,"pay":0},"currency":"SYP","paid":false}}
;
const me_on =
    \\{"memberId":"m1","name":"Dana","courier":{"vehicle":"motorbike"},"onDuty":true,"dutySince":"2025-10-12T09:00:00.000Z","needsLocationConsent":false,
    \\ "locationRetentionDays":30,"doneToday":2,"cashInHand":[],"summary":null}
;
pub const tasks_json =
    \\[{"_id":"t1","type":"pickup","status":"accepted","express":false,"from":{"label":"Souq Sham","kind":"merchant","location":{"lat":33.51,"lng":36.27}},
    \\  "to":{"label":"Damascus Hub","kind":"hub","location":{"lat":33.52,"lng":36.28}},"updatedAt":"2025-10-12T11:50:00.000Z",
    \\  "shipments":[{"_id":"s1","trackingNumber":"TRF1","status":"awaiting_pickup","parcel":{"weightKg":1.2},"cod":{"amount":450000,"currency":"SYP"},"pickup":{"name":"Souq","phone":"0944000100"},"dropoff":{"name":"Rami","phone":"0944000000"}}]}]
;
const tasks_new =
    \\[{"_id":"t2","type":"delivery","status":"assigned","express":true,"dueBy":"2025-10-12T12:30:00.000Z","from":{"label":"Hub"},"to":{"label":"Mazzeh"},"updatedAt":"2025-10-12T11:59:00.000Z","shipments":[]}]
;

pub fn openDriver() !void {
    try app.startSignedIn("/o/fast/driver");
    try testing.expect(app.D.respond("/api/app/orgs/o2", 200, org_json));
}

test "driver: consent, start the shift, track, ring for a new task, end the shift" {
    try openDriver();
    defer app.D.reset();
    const D = app.D;
    try testing.expect(D.respond("/courier/me", 200, me_off));
    try testing.expect(D.respond("/courier/tasks", 200, tasks_json));
    try testing.expect(D.findText("Off duty") != 0);
    try testing.expect(D.findText("Souq Sham") != 0);
    try testing.expect(D.findText("450,000 SYP") != 0);
    // First shift: the consent first.
    try D.press("Start shift");
    try testing.expect(D.findText("Location sharing") != 0);
    try D.press("I agree, start my shift");
    try testing.expect(D.respond("/courier/consent", 200, "{\"ok\":true}"));
    // Tracking started with the notification texts, then the server is told.
    try testing.expect(zui.host.location_on);
    try testing.expect(zui.host.background_location);
    try testing.expect(D.respond("/courier/duty", 200, "{\"ok\":true}"));
    try testing.expect(D.respond("/courier/me", 200, me_on));
    try testing.expect(D.respond("/courier/tasks", 200, tasks_json));
    try testing.expect(D.findText("On duty") != 0);
    // Positions are sampled and kept on the device until uploaded.
    D.locate(33.5138, 36.2765);
    try testing.expectEqual(@as(usize, 1), D.R.appState().gps.pending());
    // A new assigned task rings.
    D.R.dispatch(.{ .timer = .{ .gen = D.R.appState().gen, .id = @intFromEnum(T.poll) } });
    try testing.expect(D.respond("/courier/me", 200, me_on));
    try testing.expect(D.respond("/courier/tasks", 200, tasks_new));
    try testing.expect(D.findText("Accept") != 0);
    // End the shift (after a confirmation): tracking stops.
    try D.press("End shift");
    try D.press("Confirm");
    try testing.expect(D.respond("/courier/duty", 200, "{\"ok\":true}"));
    try testing.expect(!zui.host.location_on);
    try testing.expect(!zui.host.background_location);
}

test "driver: SOS without a recent position waits for one, then sends it" {
    try openDriver();
    defer app.D.reset();
    const D = app.D;
    try testing.expect(D.respond("/courier/me", 200, me_off));
    try testing.expect(D.respond("/courier/tasks", 200, "[]"));
    try D.press("SOS");
    D.R.dispatch(kit.act(courier.A.sos_send, 0));
    try testing.expect(D.pending("/courier/sos") == null);
    try testing.expect(zui.host.location_on);
    D.locate(33.5, 36.3);
    const f = zui.host.fetches.items[zui.host.fetches.items.len - 1];
    try testing.expect(std.mem.endsWith(u8, f.url, "/courier/sos"));
    try testing.expect(std.mem.indexOf(u8, f.body, "\"location\":{\"lat\":33.5,\"lng\":36.3}") != null);
    try testing.expect(!zui.host.location_on);
    try testing.expect(D.respond("/courier/sos", 200, "{}"));
    // A list refresh every minute, live connection or not.
    D.R.dispatch(.{ .timer = .{ .gen = D.R.appState().gen, .id = @intFromEnum(T.fallback) } });
    try testing.expect(D.pending("/courier/tasks") != null);
}
