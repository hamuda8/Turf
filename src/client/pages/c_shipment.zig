//! The carrier's shipment page (Turf-js views/carrier/shipment.js): summary with custody and the
//! last failure, the relay route and what this company must do with the parcel, the full
//! history (internal events too), the tasks, proof of delivery, the map with the courier, the
//! addresses, feedback, the parcel and how it was allocated. Actions: label, plan a task, note,
//! change details and day, confirm delivery by hand, return, cancel, lost, damage, and blocking
//! the store. Changes made elsewhere are picked up by polling.

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
const edit = @import("../widgets/shipment_edit.zig");
const app = @import("../app.zig");

const Cx = core.Cx;
const Ui = core.Ui;
const V = json.V;
const L = labels.k;

const d_ship: u8 = 0;

const f_note: u16 = 1;
const f_receiver: u16 = 2;

const A = enum(u16) {
    plan = 1,
    note_open,
    note_send,
    note_public,
    deliver_open,
    deliver_send,
    cod_toggle,
    return_ask,
    return_send,
    cancel_open,
    cancel_send,
    lost_open,
    damage_open,
    problem_send,
    block_ask,
    block_send,
    close,
    edit_details,
    edit_day,
};

const T = enum(u16) { poll = 1 };

const Dialog = enum { none, note, deliver, cancel, lost, damage };

pub const S = struct {
    m: mapw.Map = .{},
    edit: edit.Edit = .{},
    dialog: Dialog = .none,
    note_public: bool = false,
    cod_collected: bool = false,
    fitted: bool = false,
};

fn data(c: *const Cx) ?V {
    return c.data(d_ship);
}

fn ship(c: *const Cx) ?V {
    return json.get(data(c), "shipment");
}

fn id(c: *const Cx) []const u8 {
    return json.str(ship(c), "_id");
}

pub fn title(_: *const S, c: *const Cx) []const u8 {
    return json.str(ship(c), "trackingNumber");
}

fn load(c: *Cx) void {
    c.load(d_ship, c.orgUrl(c.print("/carrier/shipments/{s}", .{core.encode(c.arena(), c.param(1))})));
}

pub fn enter(_: *S, c: *Cx) void {
    load(c);
    c.after(20_000, @intFromEnum(T.poll));
}

fn isIn(x: []const u8, list: []const []const u8) bool {
    for (list) |l| if (std.mem.eql(u8, l, x)) return true;
    return false;
}

/// A relay parcel this company already handed over is history: no actions on it.
fn mine(c: *const Cx) bool {
    const v = json.get(ship(c), "isCurrentCarrier") orelse return true;
    return !(v == .bool and !v.bool);
}

fn blocked(c: *const Cx) bool {
    const m = json.str(ship(c), "merchantId");
    for (json.arr(c.orgV(), "carrier.blockedMerchants")) |x| if (x == .string and std.mem.eql(u8, x.string, m)) return true;
    return false;
}

fn mapSize() [2]f32 {
    const two = kit.width >= 2 * 280 + 16;
    return .{ if (two) (kit.width - 16) / 2 - 40 else kit.width - 40, 360 };
}

fn post(c: *Cx, which: A, path: []const u8, body: []const u8) void {
    c.send(@intFromEnum(which), .POST, c.orgUrl(c.print("/carrier/shipments/{s}/{s}", .{ id(c), path })), body);
}

pub fn update(s: *S, c: *Cx, e: core.Ev) void {
    if (edit.update(&s.edit, c, e)) {
        if (s.edit.saved) {
            s.edit.saved = false;
            load(c);
        }
        return;
    }
    const size = mapSize();
    s.m.setSize(size[0], size[1]);
    if (s.m.event(c, e) != null) return;
    switch (e) {
        .data => |n| if (n == d_ship and c.slot(d_ship).state == .ok and !s.fitted) {
            s.fitted = true;
            var pts: std.ArrayList(mapw.LatLng) = .empty;
            if (mapw.ll(ship(c), "pickup.location")) |p| pts.append(c.arena(), p) catch {};
            if (mapw.ll(ship(c), "dropoff.location")) |p| pts.append(c.arena(), p) catch {};
            if (mapw.ll(data(c), "courier.location")) |p| pts.append(c.arena(), p) catch {};
            s.m.fit(pts.items, .{ .animate = false });
        } else if (n == 255) load(c),
        .timer => |t| if (t == @intFromEnum(T.poll)) {
            // Never under an open dialog: the next round picks the change up.
            if (s.dialog == .none and s.edit.open == .none) load(c);
            c.after(20_000, @intFromEnum(T.poll));
        },
        .act => |a| switch (@as(A, @enumFromInt(a.id))) {
            .plan => c.go(c.print("/dispatch?shipment={s}", .{id(c)})),
            .note_open => {
                s.dialog = .note;
                s.note_public = false;
                c.setVal(f_note, "");
            },
            .note_public => s.note_public = !s.note_public,
            .note_send => {
                var b = json.Obj.init(c.arena());
                b.str("note", c.valTrim(f_note));
                if (s.note_public) b.str("visibleToCustomer", "on");
                post(c, .note_send, "notes", b.done());
            },
            .deliver_open => {
                s.dialog = .deliver;
                s.cod_collected = false;
                c.setVal(f_note, "");
                c.setVal(f_receiver, "");
            },
            .cod_toggle => s.cod_collected = !s.cod_collected,
            .deliver_send => {
                var b = json.Obj.init(c.arena());
                b.strOpt("receiverName", c.valTrim(f_receiver));
                b.str("note", c.valTrim(f_note));
                if (s.cod_collected) b.str("codCollected", "on");
                post(c, .deliver_send, "deliver", b.done());
            },
            .return_ask => c.ask(L("shipment.start_return_confirm"), .{ .act = .{ .id = @intFromEnum(A.return_send) } }),
            .return_send => post(c, .return_send, "return", "{}"),
            .cancel_open => {
                s.dialog = .cancel;
                c.setVal(f_note, "");
            },
            .cancel_send => {
                var b = json.Obj.init(c.arena());
                b.str("note", c.valTrim(f_note));
                post(c, .cancel_send, "cancel", b.done());
            },
            .lost_open, .damage_open => {
                s.dialog = if (a.id == @intFromEnum(A.lost_open)) .lost else .damage;
                c.setVal(f_note, "");
            },
            .problem_send => {
                var b = json.Obj.init(c.arena());
                b.str("note", c.valTrim(f_note));
                post(c, .problem_send, if (s.dialog == .lost) "lost" else "damage", b.done());
            },
            .block_ask => {
                const is = blocked(c);
                const q = labels.tf(c.arena(), if (is) "block.unblock_confirm" else "block.block_confirm", .{ .store = json.str(ship(c), "merchantName") });
                c.ask(q, .{ .danger = !is, .act = .{ .id = @intFromEnum(A.block_send) } });
            },
            .block_send => {
                const m = json.str(ship(c), "merchantId");
                if (blocked(c)) c.send(@intFromEnum(A.block_send), .DELETE, c.orgUrl(c.print("/carrier/blocked/{s}", .{m})), "") else c.send(@intFromEnum(A.block_send), .POST, c.orgUrl("/carrier/blocked"), c.print("{{\"merchantId\":{f}}}", .{std.json.fmt(m, .{})}));
            },
            .edit_details => edit.openDetails(&s.edit, c, c.print("/carrier/shipments/{s}", .{id(c)}), ship(c)),
            .edit_day => edit.openDay(&s.edit, c, c.print("/carrier/shipments/{s}", .{id(c)}), json.str(ship(c), "scheduledFor")),
            .close => s.dialog = .none,
        },
        .done => |d| {
            if (!d.ok) return;
            switch (@as(A, @enumFromInt(d.id))) {
                .note_send, .deliver_send, .cancel_send => {
                    s.dialog = .none;
                    load(c);
                },
                .problem_send, .return_send => {
                    s.dialog = .none;
                    c.toast(L("common.saved"), .ok);
                    load(c);
                },
                .block_send => {
                    c.toast(L("common.saved"), .ok);
                    app.reloadOrg(c);
                },
                else => {},
            }
        },
        else => {},
    }
}

pub fn actions(_: *const S, c: *const Cx, ui: *Ui) void {
    const s = ship(c) orelse return;
    const st = json.str(s, "status");
    kit.button(ui, L("shipment.print_label"), .{ .open = c.asset(ui.arena(), json.str(data(c), "labelUrl")) }, .{ .size = .sm, .icon = icons.print });
    const needs_plan = mine(c) and isIn(st, &.{ "awaiting_pickup", "at_hub", "delivery_failed", "returning" }) and !json.has(s, "currentTaskId");
    if (c.can("dispatch.manage") and needs_plan) kit.button(ui, L("dispatch.plan_task"), kit.act(A.plan, 0), .{ .size = .sm, .variant = .primary, .icon = icons.route });
    if (mine(c) and c.can("shipments.manage")) {
        kit.button(ui, L("shipment.add_note"), kit.act(A.note_open, 0), .{ .size = .sm, .icon = icons.edit });
        if (edit.isEditable(st)) {
            kit.button(ui, L("edit.title"), kit.act(A.edit_details, 0), .{ .size = .sm });
            kit.button(ui, L("edit.reschedule_title"), kit.act(A.edit_day, 0), .{ .size = .sm, .icon = icons.schedule });
        }
        if (std.mem.eql(u8, st, "out_for_delivery")) kit.button(ui, L("shipment.confirm_delivery"), kit.act(A.deliver_open, 0), .{ .size = .sm, .icon = icons.check });
        if (isIn(st, &.{ "picked_up", "at_hub", "in_transit", "delivery_failed" })) kit.button(ui, L("shipment.start_return"), kit.act(A.return_ask, 0), .{ .size = .sm, .busy = @intFromEnum(A.return_send) });
        if (std.mem.eql(u8, st, "awaiting_pickup")) kit.button(ui, L("shipment.cancel"), kit.act(A.cancel_open, 0), .{ .size = .sm, .variant = .danger });
        if (isIn(st, &.{ "picked_up", "at_hub", "in_transit", "out_for_delivery", "delivery_failed", "returning" })) kit.button(ui, L("lost.mark"), kit.act(A.lost_open, 0), .{ .size = .sm, .variant = .danger });
        if (!isIn(st, &.{ "awaiting_pickup", "cancelled", "lost" })) kit.button(ui, L("damage.report"), kit.act(A.damage_open, 0), .{ .size = .sm });
    }
    // Stop taking new shipments from this store (in-progress ones are not affected).
    if (c.can("org.settings") and json.str(s, "merchantId").len > 0) {
        const is = blocked(c);
        kit.button(ui, if (is) L("block.unblock") else L("block.block"), kit.act(A.block_ask, 0), .{ .size = .sm, .variant = if (is) .normal else .ghost, .busy = @intFromEnum(A.block_send) });
    }
}

pub fn view(s: *const S, c: *const Cx, ui: *Ui) void {
    if (!kit.gate(ui, &.{d_ship})) return;
    const sh = ship(c);
    const dv = data(c);
    const a = ui.arena();
    const full_w = kit.width;
    var g = kit.grid(ui, 2, 2);
    g.cell();
    kit.width = if (g.cols == 2) (full_w - 16) / 2 else full_w;
    kit.stack(ui);
    relayNotice(ui, c, sh);
    summary(ui, c, sh);
    routeCard(ui, c, sh);
    kit.card(ui, .{ .gap = 8.8 });
    kit.h2(ui, L("shipment.timeline"));
    parts.timeline(ui, c, json.arr(dv, "events"), .{ .internal = true });
    kit.endCard(ui, .{});
    tasksCard(ui, dv);
    if (json.obj(sh, "pod")) |pod| {
        kit.card(ui, .{ .gap = 8.8 });
        kit.h2(ui, L("shipment.proof_of_delivery"));
        parts.kv(ui, L("shipment.pod_method"), labels.of("pod.", json.str(pod, "method")));
        if (json.str(pod, "receiverName").len > 0) parts.kv(ui, L("shipment.receiver_name"), json.str(pod, "receiverName"));
        parts.kv(ui, L("common.when"), fmt.dateTime(a, json.str(pod, "at")));
        if (json.str(pod, "note").len > 0) parts.kv(ui, L("shipment.note"), json.str(pod, "note"));
        if (json.has(pod, "photoId")) {
            ui.begin(.{ .radius = 16, .background = kit.k.panel_2, .clip = true, .height = .{ .px = 240 } }, .{});
            ui.imageWith(kit.f(ui, "{s}/api/app/orgs/{s}/carrier/shipments/{s}/pod-photo", .{ core.api_base, c.orgId(), json.str(sh, "_id") }), .{ .headers = c.headers(ui.arena()) }, .{ .width = .fill, .height = .{ .px = 240 } }, zui.key("pod"));
            ui.end();
        }
        kit.endCard(ui, .{});
    }
    ui.end();
    g.endCell();
    g.cell();
    kit.stack(ui);
    kit.card(ui, .{ .gap = 8.8 });
    var pins: std.ArrayList(mapw.Pin) = .empty;
    if (mapw.ll(sh, "pickup.location")) |p| pins.append(a, .{ .at = p, .icon = mapw.placeIcon("shop"), .kind = .place, .key = zui.key("pickup") }) catch {};
    if (mapw.ll(sh, "dropoff.location")) |p| pins.append(a, .{ .at = p, .icon = mapw.placeIcon("home"), .kind = .place, .key = zui.key("dropoff") }) catch {};
    if (mapw.ll(dv, "courier.location")) |p| pins.append(a, .{ .at = p, .icon = mapw.vehicleIcon(json.str(dv, "courier.vehicle")), .key = zui.key("courier") }) catch {};
    mapw.draw(ui, &s.m, .{ .width = kit.width - 40, .height = 360, .radius = 16, .pins = pins.items });
    if (json.obj(dv, "courier")) |cr| {
        const k = kit.k;
        ui.begin(.{ .direction = .row, .gap = 8, .align_items = .center }, .{});
        kit.icon(ui, icons.navigation, 18, k.ink_2);
        ui.text(json.str(cr, "name"), .{ .font_size = 13.6, .weight = 700, .color = k.ink });
        kit.small(ui, labels.vehicle(json.str(cr, "vehicle")));
        const at = json.strOr(cr, "at", json.str(cr, "updatedAt"));
        if (at.len > 0) kit.small(ui, fmt.relative(a, at));
        ui.end();
    }
    kit.endCard(ui, .{});
    var g2 = kit.grid(ui, 2, 2);
    g2.cell();
    parts.addressBlock(ui, c, L("shipment.pickup"), json.obj(sh, "pickup"));
    g2.endCell();
    g2.cell();
    parts.addressBlock(ui, c, L("shipment.dropoff"), json.obj(sh, "dropoff"));
    g2.endCell();
    g2.end();
    parts.feedbackBlock(ui, sh);
    parts.parcelBlock(ui, sh);
    allocationBlock(ui, sh);
    ui.end();
    g.endCell();
    g.end();
    kit.width = full_w;
}

fn summary(ui: *Ui, c: *const Cx, sh: ?V) void {
    const a = ui.arena();
    const st = json.str(sh, "status");
    const express = std.mem.eql(u8, json.str(sh, "service"), "express") or json.boolean(sh, "express");
    kit.card(ui, .{ .gap = 8.8 });
    ui.begin(.{ .direction = .row, .justify = .space_between, .align_items = .center }, .{});
    ui.begin(.{ .direction = .row, .gap = 6.4, .align_items = .center }, .{});
    kit.statusBadge(ui, st);
    if (express) kit.expressBadge(ui);
    ui.end();
    kit.small(ui, fmt.relative(a, json.str(sh, "statusAt")));
    ui.end();
    if (express and !isIn(st, &.{ "delivered", "cancelled", "returned", "returning", "lost" })) @import("driver.zig").dueLabel(ui, json.str(sh, "promisedBy"));
    parts.kv(ui, L("shipment.merchant"), json.str(sh, "merchantName"));
    parts.kv(ui, L("shipment.reference"), json.strOr(sh, "externalRef", "—"));
    parts.kv(ui, L("common.created"), fmt.dateTime(a, json.str(sh, "createdAt")));
    parts.kv(ui, L("shipment.promised_by"), fmt.dateTime(a, json.str(sh, "promisedBy")));
    parts.kv(ui, L("shipment.price"), fmt.money(a, json.num(sh, "price.amount"), json.str(sh, "price.currency")));
    parts.kv(ui, L("shipment.cod"), if (json.obj(sh, "cod")) |x| fmt.money(a, json.num(x, "amount"), json.str(x, "currency")) else L("common.none"));
    parts.kv(ui, L("shipment.attempts"), fmt.number(a, json.numOr(sh, "attempts", 0), 0));
    parts.kv(ui, L("shipment.custody"), labels.of("custody.", json.strOr(sh, "custody.type", "merchant")));
    if (json.boolean(sh, "returnRequired")) kit.notice(ui, .warn, L("shipment.return_required"));
    if (json.obj(sh, "lastFailure")) |f| {
        const reason = json.pick(json.get(c.meta.value, "failureReasons"), json.str(f, "reason"), c.lang());
        var text = ui.tf(labels.english("shipment.last_failure") orelse "{reason}", .{ .reason = reason });
        if (json.str(f, "note").len > 0) text = kit.f(ui, "{s} — {s}", .{ text, json.str(f, "note") });
        kit.notice(ui, .err, text);
    }
    kit.endCard(ui, .{});
}

fn legsOf(sh: ?V) []const V {
    const legs = json.arr(sh, "legs");
    return if (legs.len > 1) legs else &.{};
}

/// Relay: what this company has to do with the parcel.
fn relayNotice(ui: *Ui, c: *const Cx, sh: ?V) void {
    const legs = legsOf(sh);
    if (legs.len == 0) return;
    if (!mine(c)) {
        kit.noticeBegin(ui, .info, icons.check);
        kit.text(ui, ui.tf(labels.english("route.handed_over_notice") orelse "{carrier}", .{ .carrier = json.str(sh, "carrierName") }), .{});
        kit.noticeEnd(ui);
        return;
    }
    const i: usize = @intCast(@max(0, json.int(sh, "legIndex")));
    if (i + 1 >= legs.len or json.boolean(sh, "returnRequired")) return;
    kit.noticeBegin(ui, .warn, icons.route);
    kit.text(ui, ui.tf(labels.english("route.bring_to") orelse "{carrier} {hub} {city}", .{ .carrier = json.str(legs[i + 1], "carrierName"), .hub = json.str(legs[i], "to.hubName"), .city = json.str(legs[i], "to.city") }), .{});
    kit.noticeEnd(ui);
}

fn routeCard(ui: *Ui, c: *const Cx, sh: ?V) void {
    const legs = legsOf(sh);
    if (legs.len == 0) return;
    const a = ui.arena();
    var list: std.ArrayList(V) = .empty;
    for (legs) |l| {
        var m: std.json.ObjectMap = .empty;
        m.put(a, "name", .{ .string = json.str(l, "carrierName") }) catch {};
        m.put(a, "from", json.get(l, "from.governorate") orelse .null) catch {};
        m.put(a, "to", json.get(l, "to.governorate") orelse .null) catch {};
        m.put(a, "hub", .{ .string = json.str(l, "to.hubName") }) catch {};
        m.put(a, "city", .{ .string = json.str(l, "to.city") }) catch {};
        m.put(a, "status", json.get(l, "status") orelse .null) catch {};
        m.put(a, "price", json.get(l, "price") orelse .null) catch {};
        list.append(a, .{ .object = m }) catch {};
    }
    parts.routeBlock(ui, c, list.items, .{ .highlight = json.str(c.orgV(), "name") });
}

fn tasksCard(ui: *Ui, dv: ?V) void {
    const k = kit.k;
    kit.card(ui, .{ .gap = 8.8 });
    kit.h2(ui, L("dispatch.tasks"));
    const tasks = json.arr(dv, "tasks");
    if (tasks.len == 0) kit.muted(ui, L("dispatch.no_tasks"));
    for (tasks, 0..) |t, i| {
        const st = json.str(t, "status");
        ui.begin(.{ .direction = .row, .gap = 9.6 }, .{ .key = zui.key(i + 1) });
        ui.begin(.{ .width = .{ .px = 3 }, .background = theme.status(&k, st) }, .{});
        ui.end();
        ui.begin(.{ .grow = 1, .gap = 2 }, .{});
        kit.strong(ui, labels.taskType(json.str(t, "type")));
        kit.small(ui, kit.f(ui, "{s} \u{2192} {s}", .{ json.str(t, "from.label"), json.str(t, "to.label") }));
        ui.end();
        ui.begin(.{ .align_items = .end, .gap = 2 }, .{});
        kit.statusBadgeText(ui, st, labels.taskStatus(st));
        kit.small(ui, json.strOr(t, "courierName", L("dispatch.unassigned")));
        ui.end();
        ui.end();
    }
    kit.endCard(ui, .{});
}

fn allocationBlock(ui: *Ui, sh: ?V) void {
    const al = json.obj(sh, "allocation") orelse return;
    kit.card(ui, .{ .gap = 8.8 });
    kit.h2(ui, L("shipment.allocation"));
    const auto = std.mem.eql(u8, json.str(al, "mode"), "auto");
    parts.kv(ui, L("shipment.allocation_mode"), if (auto) kit.f(ui, "{s} · {s}", .{ L("shipment.allocation_auto"), labels.of("strategy.", json.str(al, "strategy")) }) else L("shipment.allocation_direct"));
    if (json.num(al, "metrics.reliability")) |r| parts.kv(ui, L("shipment.reliability"), kit.f(ui, "{d}%", .{@as(i64, @intFromFloat(@round(r * 100)))}));
    kit.endCard(ui, .{});
}

pub fn overlay(s: *const S, c: *const Cx, ui: *Ui) void {
    edit.overlay(&s.edit, c, ui);
    switch (s.dialog) {
        .none => {},
        .note => {
            shell.modalBegin(ui, .{ .title = L("shipment.add_note"), .close = kit.act(A.close, 0), .key = zui.key("note") });
            kit.field(ui, L("shipment.note"), f_note, .{ .required = true, .input = .{ .kind = .multiline, .name = "note" } });
            kit.check(ui, L("shipment.note_public"), s.note_public, kit.act(A.note_public, 0));
            footer(ui, L("common.cancel"), L("common.save"), A.note_send, .primary);
        },
        .deliver => {
            shell.modalBegin(ui, .{ .title = L("shipment.confirm_delivery"), .close = kit.act(A.close, 0), .key = zui.key("deliver") });
            kit.notice(ui, .warn, L("shipment.manual_delivery_warning"));
            kit.field(ui, L("shipment.receiver_name"), f_receiver, .{ .input = .{ .name = "receiverName" } });
            kit.field(ui, L("shipment.verification_note"), f_note, .{ .required = true, .input = .{ .kind = .multiline, .name = "note" } });
            if (json.obj(ship(c), "cod")) |cod| kit.check(ui, ui.tf(labels.english("shipment.cod_collected") orelse "{amount}", .{ .amount = fmt.money(ui.arena(), json.num(cod, "amount"), json.str(cod, "currency")) }), s.cod_collected, kit.act(A.cod_toggle, 0));
            footer(ui, L("common.cancel"), L("shipment.confirm_delivery"), A.deliver_send, .primary);
        },
        .cancel => {
            shell.modalBegin(ui, .{ .title = L("shipment.cancel"), .close = kit.act(A.close, 0), .key = zui.key("cancel") });
            kit.field(ui, L("shipment.cancel_reason"), f_note, .{ .required = true, .input = .{ .kind = .multiline, .name = "note" } });
            footer(ui, L("common.back"), L("shipment.cancel"), A.cancel_send, .danger);
        },
        .lost, .damage => {
            const lost = s.dialog == .lost;
            shell.modalBegin(ui, .{ .title = if (lost) L("lost.mark") else L("damage.report"), .close = kit.act(A.close, 0), .key = zui.key("problem") });
            kit.small(ui, if (lost) L("lost.explain") else L("damage.explain"));
            kit.field(ui, L("shipment.note"), f_note, .{ .required = true, .input = .{ .kind = .multiline, .name = "note" } });
            footer(ui, L("common.cancel"), L("common.confirm"), A.problem_send, if (lost) .danger else .primary);
        },
    }
}

fn footer(ui: *Ui, cancel: []const u8, ok: []const u8, which: A, variant: kit.Variant) void {
    shell.modalFoot(ui);
    shell.modalButton(ui, cancel, kit.act(A.close, 0), .{});
    shell.modalButton(ui, ok, kit.act(which, 0), .{ .variant = variant, .busy = @intFromEnum(which) });
    shell.modalEnd(ui, true);
}

// ---- Tests --------------------------------------------------------------------------------

const testing = std.testing;

const carrier_org =
    \\{"id":"o2","type":"carrier","name":"Sham Express","slug":"fast","status":"active","branding":{"appName":"Sham Express"},
    \\ "me":{"memberId":"m1","isOwner":true,"permissions":["shipments.view","shipments.manage","dispatch.manage","org.settings"]},
    \\ "carrier":{"blockedMerchants":[]}}
;
const ship_json =
    \\{"shipment":{"_id":"s1","trackingNumber":"TRF9","status":"in_transit","merchantId":"m9","merchantName":"Souq Sham","externalRef":"ORDER-1",
    \\  "createdAt":"2025-10-12T10:00:00.000Z","price":{"amount":15000,"currency":"SYP"},"attempts":0,"custody":{"type":"courier"},
    \\  "lastFailure":{"reason":"recipient_absent","note":"closed"},
    \\  "pickup":{"name":"Souq","city":"Damascus","governorate":"DAM"},"dropoff":{"name":"Rami","city":"Damascus","governorate":"DAM"},"parcel":{"weightKg":2,"pieces":1}},
    \\ "labelUrl":"/o/fast/label/tok","events":[{"at":"2025-10-12T10:00:00.000Z","textEn":"Picked up","textAr":"x"},{"at":"2025-10-12T11:00:00.000Z","textEn":"Moved between hubs","textAr":"y","internal":true}],
    \\ "tasks":[{"type":"pickup","status":"completed","from":{"label":"Souq"},"to":{"label":"Hub"},"courierName":"Dana"}],"courier":null}
;

test "carrier shipment: internal history, tasks, mark lost, block the store" {
    try app.startSignedIn("/o/fast/shipments/s1");
    defer app.D.reset();
    const D = app.D;
    try testing.expect(D.respond("/api/app/orgs/o2", 200, carrier_org));
    try testing.expect(D.respond("/carrier/shipments/s1", 200, ship_json));
    try testing.expect(D.findText("TRF9") != 0);
    try testing.expect(D.findText("Moved between hubs") != 0); // staff see internal events
    try testing.expect(D.findText("Dana") != 0);
    D.R.dispatch(.{ .act = .{ .id = @intFromEnum(A.lost_open) } });
    try D.typeInto("", "Fell off the truck");
    D.R.dispatch(.{ .act = .{ .id = @intFromEnum(A.problem_send) } });
    const f = zui.host.fetches.items[zui.host.fetches.items.len - 1];
    try testing.expect(std.mem.endsWith(u8, f.url, "/carrier/shipments/s1/lost"));
    try testing.expect(std.mem.indexOf(u8, f.body, "Fell off the truck") != null);
    try testing.expect(D.respond("/carrier/shipments/s1/lost", 200, "{}"));
    try testing.expect(D.respond("/carrier/shipments/s1", 200, ship_json));
    D.R.dispatch(.{ .act = .{ .id = @intFromEnum(A.block_ask) } });
    D.R.dispatch(.{ .shell = .confirm_yes });
    try testing.expect(D.respond("/carrier/blocked", 200, "{}"));
    try testing.expect(D.pending("/api/app/orgs/o2") != null);
}
