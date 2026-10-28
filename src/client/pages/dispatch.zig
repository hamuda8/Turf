//! Dispatch console (Turf-js views/carrier/dispatch.js): plan tasks for shipments that need a
//! next step, and assign couriers using ranked suggestions. The queue and the board reload
//! quietly on live events (Server-Sent Events), as in Turf-js.

const std = @import("std");
const zui = @import("zui");
const core = @import("../core.zig");
const kit = @import("../kit.zig");
const shell = @import("../shell.zig");
const json = @import("../json.zig");
const fmt = @import("../fmt.zig");
const icons = @import("../icons.zig");
const labels = @import("../labels.zig");
const theme = @import("../theme.zig");
const parts = @import("../widgets/parts.zig");
const mapw = @import("../widgets/map.zig");
const cm = @import("../widgets/common.zig");

const Cx = core.Cx;
const Ui = core.Ui;
const V = json.V;
const L = labels.k;
const eq = std.mem.eql;

const d_hubs: u8 = 0;
const d_queue: u8 = 1;
const d_board: u8 = 2;
const d_sugg: u8 = 3;
const d_assign: u8 = 4;

const f_type: u16 = 0;
const f_hub: u16 = 1;

const t_poll: u16 = 1;

const A = enum(u16) { toggle = 1, plan_selected, plan_one, view, assign_open, cancel_ask, cancel, plan_close, assign_close, pick_plan, pick_assign, create_unassigned, sugg };

pub const TaskView = enum { open, pending, done };

pub const S = struct {
    selected: cm.IdSet = .{},
    task_view: TaskView = .open,
    started: bool = false,
    /// The plan dialog: copies of the shipments being planned.
    plan: ?[]V = null,
    sugg_seq: u32 = 0,
    need_hub: bool = false,
    picking: ?u32 = null,
    /// The assign dialog: the task's id.
    assign_task: ?[]const u8 = null,
};

const default_type = [_][2][]const u8{
    .{ "awaiting_pickup", "pickup" },
    .{ "at_hub", "delivery" },
    .{ "delivery_failed", "delivery" },
    .{ "returning", "return" },
};

fn defaultType(status: []const u8) ?[]const u8 {
    for (default_type) |x| if (eq(u8, x[0], status)) return x[1];
    return null;
}

/// Relay parcels that continue with another company: hand over instead of delivering.
fn mustHandOver(s: V) bool {
    const legs = json.get(s, "legs") orelse return false;
    if (legs != .array) return false;
    return json.int(s, "legIndex") < @as(i64, @intCast(legs.array.items.len)) - 1 and !json.boolean(s, "returnRequired");
}

fn typesFor(s: V) []const []const u8 {
    const st = json.str(s, "status");
    if (mustHandOver(s)) {
        if (eq(u8, st, "awaiting_pickup")) return &.{ "handover", "pickup" };
        if (eq(u8, st, "at_hub")) return &.{ "handover", "transfer", "return" };
        return &.{};
    }
    if (eq(u8, st, "awaiting_pickup")) return &.{ "pickup", "direct" };
    if (eq(u8, st, "at_hub")) return &.{ "delivery", "transfer", "return" };
    if (eq(u8, st, "delivery_failed")) return &.{ "delivery", "return" };
    if (eq(u8, st, "returning")) return &.{"return"};
    return &.{};
}

fn contains(list: []const []const u8, x: []const u8) bool {
    for (list) |y| if (eq(u8, x, y)) return true;
    return false;
}

/// The task types every shipment in the list allows, in the first one's order.
fn allowedTypes(a: std.mem.Allocator, list: []const V) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (list.len == 0) return &.{};
    outer: for (typesFor(list[0])) |x| {
        for (list[1..]) |s| if (!contains(typesFor(s), x)) continue :outer;
        out.append(a, x) catch {};
    }
    return out.items;
}

fn activeHubs(c: *const Cx, a: std.mem.Allocator) []const V {
    var out: std.ArrayList(V) = .empty;
    for (json.arr(c.data(d_hubs), "")) |h| if (json.boolean(h, "active")) out.append(a, h) catch {};
    return out.items;
}

pub fn title(_: *const S, _: *const Cx) []const u8 {
    return L("nav.dispatch");
}

fn boardUrl(s: *const S, c: *Cx) []const u8 {
    return c.orgUrl(c.print("/carrier/tasks?view={s}", .{@tagName(s.task_view)}));
}

pub fn enter(s: *S, c: *Cx) void {
    const q = c.query(c.arena(), "shipment");
    if (q.len > 0) s.selected.add(c, q);
    c.load(d_hubs, c.orgUrl("/carrier/hubs"));
    c.load(d_queue, c.orgUrl("/carrier/shipments?view=needs_action&limit=200"));
    c.load(d_board, boardUrl(s, c));
    c.quietErrors(@intFromEnum(A.sugg));
    c.orgLive(t_poll, &.{ "task.changed", "shipment.created", "shipment.updated" });
}

fn refresh(s: *S, c: *Cx) void {
    c.load(d_queue, c.orgUrl("/carrier/shipments?view=needs_action&limit=200"));
    c.load(d_board, boardUrl(s, c));
}

fn queueAt(c: *const Cx, i: u32) ?V {
    const list = json.arr(c.data(d_queue), "");
    return if (i < list.len) list[i] else null;
}

fn taskAt(c: *const Cx, i: u32) ?V {
    const list = json.arr(c.data(d_board), "");
    return if (i < list.len) list[i] else null;
}

fn copyOf(c: *Cx, v: V) V {
    return json.parse(c.arena(), json.stringify(c.arena(), v)) orelse v;
}

fn openPlan(s: *S, c: *Cx, list: []const V) void {
    if (list.len == 0) return;
    const allowed = allowedTypes(c.arena(), list);
    if (allowed.len == 0) {
        c.toast(L("dispatch.mixed_selection"), .err);
        return;
    }
    const copies = c.arena().alloc(V, list.len) catch return;
    for (list, 0..) |x, i| copies[i] = copyOf(c, x);
    s.plan = copies;
    s.picking = null;
    const preferred = if (mustHandOver(list[0])) "handover" else defaultType(json.str(list[0], "status")) orelse "";
    c.setVal(f_type, if (contains(allowed, preferred)) preferred else allowed[0]);
    // A <select> without a placeholder starts on its first option.
    const hubs = activeHubs(c, c.arena());
    c.setVal(f_hub, if (hubs.len > 0) cm.docId(hubs[0]) else "");
    preferHub(s, c);
    loadSuggestions(s, c);
}

/// Default hub: the one in the drop-off governorate for transfers, the pickup's for pickups.
fn preferHub(s: *S, c: *Cx) void {
    const list = s.plan orelse return;
    const target = if (eq(u8, c.val(f_type), "transfer")) json.str(list[0], "dropoff.governorate") else json.str(list[0], "pickup.governorate");
    for (activeHubs(c, c.arena())) |h| if (eq(u8, json.str(h, "governorate"), target)) {
        c.setVal(f_hub, cm.docId(h));
        return;
    };
}

fn needsHub(c: *const Cx) bool {
    const ty = c.val(f_type);
    return eq(u8, ty, "pickup") or eq(u8, ty, "transfer");
}

fn planBody(s: *const S, c: *Cx, courier: ?[]const u8) []const u8 {
    var b = json.Obj.init(c.arena());
    b.str("type", c.val(f_type));
    b.beginArray("shipmentIds");
    for (s.plan orelse &.{}) |x| b.str("", cm.docId(x));
    b.endArray();
    if (needsHub(c)) b.str("toHubId", c.val(f_hub));
    if (courier) |id| b.str("courierId", id);
    return b.done();
}

fn loadSuggestions(s: *S, c: *Cx) void {
    s.sugg_seq += 1;
    s.need_hub = false;
    if (needsHub(c) and activeHubs(c, c.arena()).len == 0) {
        s.need_hub = true;
        return;
    }
    cm.pending(c, d_sugg);
    c.sendArg(@intFromEnum(A.sugg), s.sugg_seq, .POST, c.orgUrl("/carrier/tasks/suggestions"), planBody(s, c, null));
}

fn closePlan(s: *S, c: *Cx, done: bool) void {
    if (done) for (s.plan orelse &.{}) |x| s.selected.remove(cm.docId(x));
    s.plan = null;
    s.picking = null;
    s.sugg_seq += 1;
    c.slots[d_sugg].reset();
}

pub fn update(s: *S, c: *Cx, e: core.Ev) void {
    switch (e) {
        .data => |n| {
            const sl = c.slot(n);
            // Background refreshes report their failure, never throw it away.
            if (sl.state == .ok and sl.err.len > 0 and (n == d_queue or n == d_board)) c.toast(sl.err, .err);
            if (n == d_queue and sl.state == .ok) {
                // Selected parcels that left the queue are no longer selected.
                var i: usize = 0;
                while (i < s.selected.items.items.len) {
                    const id = s.selected.items.items[i];
                    var found = false;
                    for (json.arr(c.data(d_queue), "")) |x| if (eq(u8, cm.docId(x), id)) {
                        found = true;
                    };
                    if (found) i += 1 else _ = s.selected.items.orderedRemove(i);
                }
            }
            if (!s.started and c.ready(&.{ d_hubs, d_queue, d_board })) {
                s.started = true;
                const q = c.query(c.arena(), "shipment");
                if (q.len > 0) for (json.arr(c.data(d_queue), "")) |x| if (eq(u8, cm.docId(x), q)) {
                    openPlan(s, c, &.{x});
                    break;
                };
            }
        },
        .timer => |id| if (id == t_poll) {
            c.liveDone();
            refresh(s, c);
        },
        .text => |x| {
            if (s.plan == null) return;
            if (x.slot == f_type) {
                preferHub(s, c);
                loadSuggestions(s, c);
            } else if (x.slot == f_hub) loadSuggestions(s, c);
        },
        .act => |a| switch (@as(A, @enumFromInt(a.id))) {
            .toggle => if (queueAt(c, a.arg)) |x| s.selected.toggle(c, cm.docId(x)),
            .plan_selected => {
                var list: std.ArrayList(V) = .empty;
                for (json.arr(c.data(d_queue), "")) |x| if (s.selected.has(cm.docId(x))) list.append(c.arena(), x) catch {};
                openPlan(s, c, list.items);
            },
            .plan_one => if (queueAt(c, a.arg)) |x| openPlan(s, c, &.{x}),
            .view => {
                s.task_view = @enumFromInt(@min(a.arg, 2));
                c.load(d_board, boardUrl(s, c));
            },
            .assign_open => if (taskAt(c, a.arg)) |task| {
                s.assign_task = c.dupe(cm.docId(task));
                s.picking = null;
                c.slots[d_assign].reset();
                c.load(d_assign, c.orgUrl(c.print("/carrier/tasks/{s}/suggestions", .{cm.docId(task)})));
            },
            .assign_close => s.assign_task = null,
            .cancel_ask => c.ask(L("dispatch.cancel_task_confirm"), .{ .act = .{ .id = @intFromEnum(A.cancel), .arg = a.arg } }),
            .cancel => if (taskAt(c, a.arg)) |task| c.sendArg(@intFromEnum(A.cancel), a.arg, .POST, c.orgUrl(c.print("/carrier/tasks/{s}/cancel", .{cm.docId(task)})), ""),
            .plan_close => closePlan(s, c, false),
            .pick_plan => {
                if (c.isBusy(@intFromEnum(A.pick_plan)) or c.isBusy(@intFromEnum(A.create_unassigned))) return;
                const list = json.arr(c.data(d_sugg), "");
                if (a.arg >= list.len or s.plan == null) return;
                s.picking = a.arg;
                c.sendArg(@intFromEnum(A.pick_plan), a.arg, .POST, c.orgUrl("/carrier/tasks"), planBody(s, c, json.str(list[a.arg], "courierId")));
            },
            .pick_assign => {
                if (c.isBusy(@intFromEnum(A.pick_assign))) return;
                const list = json.arr(c.data(d_assign), "");
                const task = s.assign_task orelse return;
                if (a.arg >= list.len) return;
                s.picking = a.arg;
                var b = json.Obj.init(c.arena());
                b.str("courierId", json.str(list[a.arg], "courierId"));
                c.sendArg(@intFromEnum(A.pick_assign), a.arg, .POST, c.orgUrl(c.print("/carrier/tasks/{s}/assign", .{task})), b.done());
            },
            .create_unassigned => {
                if (c.isBusy(@intFromEnum(A.pick_plan)) or s.plan == null) return;
                c.send(@intFromEnum(A.create_unassigned), .POST, c.orgUrl("/carrier/tasks"), planBody(s, c, null));
            },
            .sugg => {},
        },
        .done => |d| switch (@as(A, @enumFromInt(d.id))) {
            .sugg => {
                if (d.arg != s.sugg_seq or s.plan == null) return;
                if (d.ok) cm.keep(c, d_sugg, d.body) else cm.fail(c, d_sugg, d);
            },
            .pick_plan => {
                s.picking = null;
                if (!d.ok) return;
                const list = json.arr(c.data(d_sugg), "");
                if (d.arg < list.len) c.toast(cm.txc(c, "dispatch.assigned_to", .{ .name = json.str(list[d.arg], "name") }), .ok);
                closePlan(s, c, true);
                refresh(s, c);
            },
            .pick_assign => {
                s.picking = null;
                if (!d.ok) return;
                const list = json.arr(c.data(d_assign), "");
                if (d.arg < list.len) c.toast(cm.txc(c, "dispatch.assigned_to", .{ .name = json.str(list[d.arg], "name") }), .ok);
                s.assign_task = null;
                refresh(s, c);
            },
            .create_unassigned => if (d.ok) {
                closePlan(s, c, true);
                refresh(s, c);
            },
            .cancel => if (d.ok) refresh(s, c),
            else => {},
        },
        else => {},
    }
}

// ---- View ---------------------------------------------------------------------------------

pub fn view(s: *const S, c: *const Cx, ui: *Ui) void {
    if (!kit.gate(ui, &.{ d_hubs, d_queue, d_board })) return;
    var g = kit.grid(ui, 2, 2);
    g.cell();
    queueSection(s, c, ui);
    g.endCell();
    g.cell();
    boardSection(s, c, ui);
    g.endCell();
    g.end();
}

fn queueSection(s: *const S, c: *const Cx, ui: *Ui) void {
    const k = kit.k;
    kit.stackTight(ui);
    kit.rowBetween(ui);
    kit.h2(ui, L("dispatch.needs_planning"));
    kit.button(ui, L("dispatch.plan_selected"), kit.act(A.plan_selected, 0), .{ .variant = .primary, .icon = icons.route, .disabled = s.selected.count() == 0 });
    ui.end();
    const list = json.arr(c.data(d_queue), "");
    if (list.len == 0) {
        kit.empty(ui, L("dispatch.queue_empty"));
        ui.end();
        return;
    }
    const hubs = json.arr(c.data(d_hubs), "");
    for (default_type) |dt| {
        var n: usize = 0;
        for (list) |x| if (eq(u8, json.str(x, "status"), dt[0])) {
            n += 1;
        };
        if (n == 0) continue;
        kit.stackTight(ui);
        kit.rowBetween(ui);
        kit.statusBadge(ui, dt[0]);
        kit.small(ui, fmt.number(ui.arena(), @floatFromInt(n), 0));
        ui.end();
        for (list, 0..) |x, i| {
            if (!eq(u8, json.str(x, "status"), dt[0])) continue;
            const id = cm.docId(x);
            ui.begin(.{ .direction = .row, .align_items = .center, .gap = 9.6, .padding = .xy(12.8, 9.6), .radius = 18, .background = k.panel, .pressed_background = k.panel_2, .hover_background = k.panel_2 }, .{ .on_press = kit.act(A.toggle, @intCast(i)), .key = zui.key(id) });
            kit.box(ui, s.selected.has(id));
            ui.begin(.{ .grow = 1, .gap = 2 }, .{});
            kit.rowBetween(ui);
            ui.begin(.{ .direction = .row, .gap = 6.4, .align_items = .center }, .{});
            kit.mono(ui, json.str(x, "trackingNumber"), .{ .weight = 700 });
            if (cm.isExpress(x)) kit.expressBadge(ui);
            ui.end();
            kit.small(ui, fmt.relative(ui.arena(), json.str(x, "statusAt")));
            ui.end();
            // Where the parcel is now, and where it goes.
            const custody = json.str(x, "custody.type");
            var where: []const u8 = "";
            if (eq(u8, custody, "hub")) {
                for (hubs) |h| if (eq(u8, cm.docId(h), json.str(x, "custody.hubId"))) {
                    where = json.str(h, "name");
                };
            } else if (eq(u8, custody, "merchant")) {
                where = parts.placeText(ui.arena(), c, json.get(x, "pickup"), .{});
            } else if (custody.len > 0) where = labels.of("custody.", custody);
            ui.begin(.{ .direction = .row, .gap = 4.8, .align_items = .center }, .{});
            kit.small(ui, if (where.len > 0) where else "—");
            kit.iconFlip(ui, icons.arrow_forward, 15, k.ink_2);
            kit.small(ui, parts.placeText(ui.arena(), c, json.get(x, "dropoff"), .{}));
            ui.end();
            var line: std.ArrayList(u8) = .empty;
            line.print(ui.arena(), "{s} {s}", .{ json.text(ui.arena(), x, "parcel.weightKg"), L("unit.kg") }) catch {};
            if (json.boolean(x, "cod")) line.print(ui.arena(), " · {s}", .{L("shipment.cod")}) catch {};
            if (json.boolean(x, "returnRequired")) line.print(ui.arena(), " · {s}", .{L("shipment.return_required_short")}) catch {};
            ui.text(line.items, .{ .font_size = 14, .color = k.ink });
            ui.end();
            kit.iconButton(ui, icons.route, kit.act(A.plan_one, @intCast(i)), .{ .size = .sm, .variant = .ghost, .label = L("dispatch.plan_task") });
            ui.end();
        }
        ui.end();
    }
    ui.end();
}

const active_states = [_][]const u8{ "pending", "assigned", "accepted", "in_progress" };

fn boardSection(s: *const S, c: *const Cx, ui: *Ui) void {
    const k = kit.k;
    kit.stackTight(ui);
    kit.rowBetween(ui);
    kit.h2(ui, L("dispatch.tasks"));
    ui.begin(.{ .direction = .row, .gap = 6.4 }, .{});
    kit.chip(ui, L("dispatch.view.open"), s.task_view == .open, kit.act(A.view, 0));
    kit.chip(ui, L("dispatch.view.pending"), s.task_view == .pending, kit.act(A.view, 1));
    kit.chip(ui, L("dispatch.view.done"), s.task_view == .done, kit.act(A.view, 2));
    ui.end();
    ui.end();
    const tasks = json.arr(c.data(d_board), "");
    if (tasks.len == 0) kit.empty(ui, L("dispatch.no_tasks"));
    for (tasks, 0..) |task, i| {
        const st = json.str(task, "status");
        const express = json.boolean(task, "express");
        // `.task-card.express`: a ring of the action colour.
        const co: kit.CardOpts = .{ .gap = 9.6, .edge = theme.status(&k, st), .ring = if (express) k.a else null, .key = zui.key(cm.docId(task)) };
        kit.card(ui, co);
        kit.rowBetween(ui);
        ui.begin(.{ .direction = .row, .gap = 6.4, .align_items = .center, .grow = 1 }, .{});
        kit.strong(ui, labels.taskType(json.str(task, "type")));
        if (express) kit.expressBadge(ui);
        if (json.boolean(task, "auto")) kit.badge(ui, L("dispatch.auto"), .plain);
        ui.end();
        kit.statusBadgeText(ui, st, labels.taskStatus(st));
        ui.end();
        if (express and contains(&active_states, st)) cm.dueLabel(ui, json.str(task, "dueBy"));
        ui.begin(.{ .gap = 4.8 }, .{});
        routeLine(ui, icons.location_on, json.str(task, "from.label"), false);
        routeLine(ui, icons.arrow_forward, json.str(task, "to.label"), true);
        ui.end();
        ui.begin(.{ .direction = .row, .gap = 12, .align_items = .center }, .{});
        const courier = json.str(task, "courierName");
        if (courier.len > 0) {
            ui.begin(.{ .direction = .row, .gap = 4.8, .align_items = .center }, .{});
            kit.icon(ui, if (json.str(task, "courierVehicle").len > 0) mapw.vehicleIcon(json.str(task, "courierVehicle")) else icons.person, 18, k.ink);
            ui.text(courier, .{ .font_size = 14, .color = k.ink, .max_lines = 1 });
            ui.end();
        } else kit.badge(ui, L("dispatch.unassigned"), .amber);
        kit.small(ui, cm.tx(ui, "dispatch.parcels_n", .{ .n = json.arr(task, "shipmentIds").len }));
        kit.small(ui, fmt.relative(ui.arena(), json.str(task, "updatedAt")));
        ui.end();
        if (json.has(task, "lastDeclined") and eq(u8, st, "pending")) {
            kit.notice(ui, .warn, cm.tx(ui, "dispatch.declined", .{ .reason = json.strOr(task, "lastDeclined.reason", "—") }));
        }
        const ships = json.arr(task, "shipments");
        if (ships.len > 0) {
            var w = kit.Wrap.begin(ui, @max(kit.width / 2 - 60, 200), 5.6);
            for (ships) |sh| {
                const tn = json.str(sh, "trackingNumber");
                w.item(kit.estimate(tn, 12) + 22);
                ui.begin(.{ .padding = .xy(10.4, 2.4), .radius = 999, .background = k.panel_3, .pressed_opacity = 0.7 }, .{ .on_press = .{ .go = kit.f(ui, "/shipments/{s}", .{cm.docId(sh)}) } });
                ui.text(tn, .{ .font_size = 12, .weight = 700, .color = k.ink_2, .max_lines = 1 });
                ui.end();
            }
            w.end();
        }
        ui.begin(.{ .direction = .row, .gap = 5.6 }, .{});
        if (contains(&active_states, st)) {
            const has_courier = json.str(task, "courierId").len > 0;
            kit.button(ui, if (has_courier) L("dispatch.reassign") else L("dispatch.assign"), kit.act(A.assign_open, @intCast(i)), .{ .size = .sm, .variant = if (has_courier) .normal else .primary, .icon = icons.person });
        }
        if (contains(active_states[0..3], st)) {
            const mine = c.isBusy(@intFromEnum(A.cancel)) and (c.act_args.get(@intFromEnum(A.cancel)) orelse 0) == i;
            kit.iconButton(ui, icons.close, kit.act(A.cancel_ask, @intCast(i)), .{ .size = .sm, .variant = .ghost, .label = L("dispatch.cancel_task"), .busy = if (mine) @intFromEnum(A.cancel) else null });
        }
        ui.end();
        kit.endCard(ui, co);
    }
    ui.end();
}

fn routeLine(ui: *Ui, ic: zui.Icon, s: []const u8, flip: bool) void {
    ui.begin(.{ .direction = .row, .gap = 8, .align_items = .start }, .{});
    if (flip) kit.iconFlip(ui, ic, 18, kit.k.ink_3) else kit.icon(ui, ic, 18, kit.k.ink_3);
    ui.text(s, .{ .font_size = 14, .color = kit.k.ink, .grow = 1 });
    ui.end();
}

// ---- Dialogs ------------------------------------------------------------------------------

pub fn overlay(s: *const S, c: *const Cx, ui: *Ui) void {
    if (s.plan) |list| planDialog(s, c, ui, list);
    if (s.assign_task != null) assignDialog(s, c, ui);
}

fn planDialog(s: *const S, c: *const Cx, ui: *Ui, list: []const V) void {
    shell.modalBegin(ui, .{ .title = L("dispatch.plan_task"), .close = kit.act(A.plan_close, 0), .wide = true, .dismissible = true, .key = zui.key("plan-task") });
    var w = kit.Wrap.begin(ui, kit.width, 5.6);
    for (list) |x| {
        const tn = json.str(x, "trackingNumber");
        w.item(kit.estimate(tn, 12) + 22);
        ui.begin(.{ .padding = .xy(10.4, 2.4), .radius = 999, .background = kit.k.panel_3 }, .{});
        kit.mono(ui, tn, .{ .size = 12, .weight = 700, .color = kit.k.ink_2 });
        ui.end();
    }
    w.end();
    const a = ui.arena();
    const allowed = allowedTypes(a, list);
    var type_opts: std.ArrayList(core.Opt) = .empty;
    for (allowed) |x| type_opts.append(a, .{ .value = x, .label = labels.taskType(x) }) catch {};
    var hub_opts: std.ArrayList(core.Opt) = .empty;
    for (activeHubs(c, a)) |h| hub_opts.append(a, .{ .value = cm.docId(h), .label = kit.f(ui, "{s} ({s})", .{ json.str(h, "name"), parts.gov(c, json.str(h, "governorate")) }) }) catch {};
    const hub = needsHub(c);
    var g = kit.formGrid(ui, if (hub) 2 else 1);
    g.cell();
    kit.selectField(ui, L("dispatch.task_type"), f_type, type_opts.items, .{ .required = true, .name = "type" });
    g.endCell();
    if (hub) {
        g.cell();
        kit.selectField(ui, L("dispatch.destination_hub"), f_hub, hub_opts.items, .{ .required = true, .name = "toHubId" });
        g.endCell();
    }
    g.end();
    kit.h3(ui, L("dispatch.suggested_couriers"));
    if (s.need_hub) {
        kit.notice(ui, .warn, L("dispatch.need_hub"));
    } else courierPicker(s, c, ui, d_sugg, A.pick_plan, c.isBusy(@intFromEnum(A.create_unassigned)));
    kit.rowEnd(ui);
    kit.button(ui, L("dispatch.create_unassigned"), kit.act(A.create_unassigned, 0), .{ .variant = .ghost, .busy = @intFromEnum(A.create_unassigned), .disabled = c.isBusy(@intFromEnum(A.pick_plan)) });
    ui.end();
    shell.modalEnd(ui, false);
}

fn assignDialog(s: *const S, c: *const Cx, ui: *Ui) void {
    shell.modalBegin(ui, .{ .title = L("dispatch.assign"), .close = kit.act(A.assign_close, 0), .wide = true, .dismissible = true, .key = zui.key("assign-task") });
    courierPicker(s, c, ui, d_assign, A.pick_assign, false);
    shell.modalEnd(ui, false);
}

/// The ranked couriers; one choice at a time (a second tap would create a second task).
fn courierPicker(s: *const S, c: *const Cx, ui: *Ui, n: u8, pick: A, locked: bool) void {
    const k = kit.k;
    const sl = c.slot(n);
    switch (sl.state) {
        .idle, .loading => return kit.loading(ui),
        .failed => {
            kit.notice(ui, .err, sl.err);
            return;
        },
        .ok => {},
    }
    const list = json.arr(c.data(n), "");
    if (list.len == 0) {
        kit.notice(ui, .warn, L("dispatch.no_couriers_on_duty"));
        return;
    }
    const busy = c.isBusy(@intFromEnum(pick)) or locked;
    kit.stackTight(ui);
    for (list, 0..) |sg, i| {
        const eligible = json.boolean(sg, "eligible");
        ui.begin(.{ .direction = .row, .align_items = .center, .gap = 12, .padding = .xy(12.8, 9.6), .radius = 18, .background = k.panel_2, .opacity = if (eligible) 1 else 0.6 }, .{ .key = zui.key(json.str(sg, "courierId")) });
        kit.avatar(ui, if (json.str(sg, "vehicle").len > 0) mapw.vehicleIcon(json.str(sg, "vehicle")) else icons.package_2);
        ui.begin(.{ .grow = 1, .gap = 2 }, .{});
        kit.strong(ui, json.str(sg, "name"));
        var line: std.ArrayList(u8) = .empty;
        line.appendSlice(ui.arena(), labels.vehicle(json.str(sg, "vehicle"))) catch {};
        if (json.num(sg, "distanceToStartKm")) |km| {
            line.print(ui.arena(), " · {s}", .{cm.tx(ui, "dispatch.km_away", .{ .km = fmt.number(ui.arena(), km, 1) })}) catch {};
        } else line.print(ui.arena(), " · {s}", .{L("dispatch.location_unknown")}) catch {};
        line.print(ui.arena(), " · {s}", .{cm.tx(ui, "dispatch.open_tasks_n", .{ .n = json.int(sg, "openTasks") })}) catch {};
        if (json.boolean(sg, "locationStale")) line.print(ui.arena(), " · {s}", .{L("dispatch.stale")}) catch {};
        kit.small(ui, line.items);
        const reason = json.str(sg, "reason");
        if (reason.len > 0) ui.text(labels.of("dispatch.reason.", reason), .{ .font_size = 14, .color = k.fatal_ink });
        ui.end();
        const mine = s.picking != null and s.picking.? == i;
        kit.button(ui, L("dispatch.choose"), kit.act(pick, @intCast(i)), .{ .size = .sm, .variant = .primary, .disabled = !eligible or (busy and !mine), .busy = if (mine) @intFromEnum(pick) else null });
        ui.end();
    }
    ui.end();
}

// ---- Tests --------------------------------------------------------------------------------

const app = @import("../app.zig");
const testing = std.testing;

pub const carrier_org =
    \\{"id":"o2","type":"carrier","name":"Fast Express","slug":"fast","status":"active","branding":{"appName":"Fast Express"},
    \\ "contact":{"phone":"0911","governorate":"DAM"},
    \\ "carrier":{"currency":"SYP","coverage":["DAM"],"pricing":{"localBase":5000,"nationalBase":9000},"sla":{"localHours":24},"maxWeightKg":30,"maxAttempts":3},"readiness":[],
    \\ "me":{"isOwner":true,"permissions":["org.settings","org.branding","audit.view","members.view","members.invite","members.manage","roles.manage","hubs.manage","shipments.view","shipments.manage","dispatch.manage","hub.scan","fleet.view","alerts.manage","finance.view"]}}
;

/// Opens a carrier page as its owner (answers the company and the alerts badge).
pub fn openCarrier(path: []const u8) !void {
    var buf: [128]u8 = undefined;
    try app.startSignedIn(try std.fmt.bufPrint(&buf, "/o/fast{s}", .{path}));
    try testing.expect(app.D.respond("/api/app/orgs/o2", 200, carrier_org));
    _ = app.D.respond("/carrier/alerts?status=open", 200, "[]");
}

test "dispatch: plan a parcel and assign the suggested courier" {
    try openCarrier("/dispatch");
    defer app.D.reset();
    try testing.expect(app.D.respond("/carrier/hubs", 200, "[{\"_id\":\"h1\",\"name\":\"Main hub\",\"governorate\":\"DAM\",\"active\":true}]"));
    try testing.expect(app.D.respond("/carrier/shipments?view=needs_action", 200,
        \\[{"_id":"s1","trackingNumber":"TRF100","status":"awaiting_pickup","statusAt":"2025-10-12T11:00:00.000Z","custody":{"type":"merchant"},
        \\  "pickup":{"city":"Mazzeh","governorate":"DAM"},"dropoff":{"city":"Homs","governorate":"HI"},"parcel":{"weightKg":2},"cod":{"amount":5}}]
    ));
    try testing.expect(app.D.respond("/carrier/tasks?view=open", 200, "[]"));
    try testing.expect(app.D.findText("TRF100") != 0);
    try testing.expect(app.D.findText("No tasks.") != 0);
    // Select it and plan.
    try app.D.press("TRF100");
    try app.D.press("Plan selected");
    try testing.expect(app.D.findText("Plan task") != 0);
    const req = zui.host.fetches.items[zui.host.fetches.items.len - 1];
    try testing.expect(std.mem.endsWith(u8, req.url, "/carrier/tasks/suggestions"));
    try testing.expect(std.mem.indexOf(u8, req.body, "\"type\":\"pickup\"") != null);
    try testing.expect(std.mem.indexOf(u8, req.body, "\"toHubId\":\"h1\"") != null);
    try testing.expect(app.D.respond("/carrier/tasks/suggestions", 200, "[{\"courierId\":\"c1\",\"name\":\"Omar\",\"vehicle\":\"motorbike\",\"eligible\":true,\"distanceToStartKm\":2.5,\"openTasks\":1}]"));
    try testing.expect(app.D.findText("Omar") != 0);
    try app.D.press("Choose");
    const create = zui.host.fetches.items[zui.host.fetches.items.len - 1];
    try testing.expect(std.mem.endsWith(u8, create.url, "/carrier/tasks"));
    try testing.expect(std.mem.indexOf(u8, create.body, "\"courierId\":\"c1\"") != null);
    try testing.expect(app.D.respond("/carrier/tasks", 201, "{}"));
    try testing.expect(app.D.findText("Assigned to Omar") != 0);
    try testing.expect(app.D.findText("Plan task") == 0);
    try testing.expect(app.D.pending("/carrier/shipments?view=needs_action") != null);
}

test "dispatch: mixed selections are refused, assigning shows the suggestions" {
    try openCarrier("/dispatch");
    defer app.D.reset();
    try testing.expect(app.D.respond("/carrier/hubs", 200, "[]"));
    try testing.expect(app.D.respond("/carrier/shipments?view=needs_action", 200,
        \\[{"_id":"s1","trackingNumber":"TRF1","status":"returning","parcel":{"weightKg":1},"custody":{"type":"courier"}},
        \\ {"_id":"s2","trackingNumber":"TRF2","status":"awaiting_pickup","parcel":{"weightKg":1},"custody":{"type":"merchant"}}]
    ));
    try testing.expect(app.D.respond("/carrier/tasks?view=open", 200,
        \\[{"_id":"t1","type":"delivery","status":"pending","from":{"label":"Hub"},"to":{"label":"Door"},"shipmentIds":["s9"],
        \\  "shipments":[{"_id":"s9","trackingNumber":"TRF9"}],"lastDeclined":{"reason":"Too far"}}]
    ));
    try app.D.press("TRF1");
    try app.D.press("TRF2");
    try app.D.press("Plan selected");
    try testing.expect(app.D.findText("These parcels need different kinds of tasks. Select parcels with the same status.") != 0);
    try testing.expect(app.D.findText("Declined by the courier: Too far") != 0);
    try testing.expect(app.D.findText("Parcels: 1") != 0);
    try app.D.press("Assign courier");
    try testing.expect(app.D.respond("/carrier/tasks/t1/suggestions", 200, "[]"));
    try testing.expect(app.D.findText("No couriers are on duty right now. You can create the task and assign it later.") != 0);
}

test "live events reload the queue (once per burst); Back returns to the page before" {
    try openCarrier("/dispatch");
    defer app.D.reset();
    try testing.expect(app.D.respond("/carrier/hubs", 200, "[]"));
    try testing.expect(app.D.respond("/carrier/shipments?view=needs_action", 200,
        \\[{"_id":"s1","trackingNumber":"TRF100","status":"awaiting_pickup","custody":{"type":"merchant"},"parcel":{"weightKg":2}}]
    ));
    try testing.expect(app.D.respond("/carrier/tasks?view=open", 200, "[]"));
    // The company's live events: a changed task reloads the queue (once per burst).
    try testing.expect(std.mem.endsWith(u8, zui.host.stream_url.items, "/api/app/orgs/o2/stream"));
    app.D.serverStatus(200);
    app.D.serverSend("event: task.changed\ndata: {}\n\nevent: task.changed\ndata: {}\n\n");
    var live_timers: usize = 0;
    for (zui.host.timers.items) |tm| live_timers += @intFromBool(tm.ms == 400);
    try testing.expectEqual(@as(usize, 1), live_timers);
    const tm = zui.host.timers.items[zui.host.timers.items.len - 1];
    app.D.R.timerDone(tm.id);
    try testing.expect(app.D.respond("/carrier/shipments?view=needs_action", 200, "[]"));
    try testing.expect(app.D.pending("/carrier/shipments?view=needs_action") == null);
    // Another page, then Back: the page before.
    app.D.R.dispatch(.{ .go = "/fleet" });
    try testing.expectEqualStrings("/o/fast/fleet", zui.host.link.items);
    try testing.expect(app.D.back());
    try testing.expectEqualStrings("/o/fast/dispatch", zui.host.link.items);
    try testing.expect(app.D.R.appState().page == .dispatch);
}
