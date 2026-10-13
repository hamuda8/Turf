//! Carrier dashboard (Turf-js views/carrier/dashboard.js): the setup checklist, today's numbers,
//! live activity.
//!
//! Turf-js refreshed the numbers on the company's live events (Server-Sent Events) and listed
//! those events in a feed; zui has no event stream, so the numbers are read again every 20
//! seconds and the feed stays with its hint.

const std = @import("std");
const zui = @import("zui");
const core = @import("../core.zig");
const kit = @import("../kit.zig");
const json = @import("../json.zig");
const fmt = @import("../fmt.zig");
const icons = @import("../icons.zig");
const labels = @import("../labels.zig");

const Cx = core.Cx;
const Ui = core.Ui;
const V = json.V;
const L = labels.k;

const d_stats: u8 = 0;
const d_hubs: u8 = 1;
const d_members: u8 = 2;
const T_STATS: u16 = 1;
const refresh_ms = 20_000;

pub const S = struct {};

pub fn title(_: *const S, _: *const Cx) []const u8 {
    return L("nav.dashboard");
}

pub fn enter(_: *S, c: *Cx) void {
    @import("../app.zig").reloadOrg(c);
    c.load(d_stats, c.orgUrl("/carrier/stats"));
    if (c.can("org.settings")) {
        c.load(d_hubs, c.orgUrl("/carrier/hubs"));
        if (c.can("members.view")) c.load(d_members, c.orgUrl("/members"));
    }
    c.after(refresh_ms, T_STATS);
}

pub fn update(_: *S, c: *Cx, e: core.Ev) void {
    switch (e) {
        .timer => |id| if (id == T_STATS) {
            // A failed refresh keeps the last numbers.
            if (!c.slot(d_stats).reloading) c.load(d_stats, c.orgUrl("/carrier/stats"));
            c.after(refresh_ms, T_STATS);
        },
        else => {},
    }
}

fn readiness(c: *const Cx, what: []const u8) bool {
    return json.contains(c.orgV(), "readiness", what);
}

pub const Step = struct { done: bool, label: []const u8, path: ?[]const u8 };

/// The setup checklist (only for those who can change the settings; others see whether the
/// company awaits approval).
fn checklist(c: *const Cx, ui: *Ui) void {
    const org = c.orgV();
    const pending = std.mem.eql(u8, json.str(org, "status"), "pending");
    if (!c.can("org.settings")) {
        if (pending) {
            kit.noticeBegin(ui, .warn, icons.schedule);
            kit.text(ui, L("dash.awaiting_approval"), .{});
            kit.noticeEnd(ui);
        }
        return;
    }
    var steps: std.ArrayList(Step) = .empty;
    const a = ui.arena();
    steps.append(a, .{ .done = !pending, .label = L("dash.step_approval"), .path = null }) catch {};
    steps.append(a, .{ .done = !readiness(c, "no_coverage"), .label = L("dash.step_coverage"), .path = "/settings" }) catch {};
    steps.append(a, .{ .done = !readiness(c, "no_pricing"), .label = L("dash.step_pricing"), .path = "/settings" }) catch {};
    steps.append(a, .{ .done = json.arr(c.data(d_hubs), "").len > 0, .label = L("dash.step_hubs"), .path = "/hubs" }) catch {};
    if (c.can("members.view")) {
        var any = false;
        for (json.arr(c.data(d_members), "")) |m| if (json.has(m, "courier")) {
            any = true;
        };
        steps.append(a, .{ .done = any, .label = L("dash.step_couriers"), .path = "/team" }) catch {};
    }
    steps.append(a, .{ .done = json.str(org, "branding.logoUrl").len > 0, .label = L("dash.step_branding"), .path = "/branding" }) catch {};
    var all = true;
    for (steps.items) |x| if (!x.done) {
        all = false;
    };
    if (all) return;
    kit.card(ui, .{ .gap = 8.8 });
    kit.h2(ui, L("dash.setup_title"));
    kit.muted(ui, L("dash.setup_intro"));
    for (steps.items) |x| stepRow(ui, x);
    kit.endCard(ui, .{});
}

/// A checklist line: a badge (a tick or a clock), the step (a link while not done).
pub fn stepRow(ui: *Ui, x: Step) void {
    ui.begin(.{ .direction = .row, .gap = 9.6, .align_items = .center }, .{});
    kit.badgeIcon(ui, "", if (x.done) .green else .plain, if (x.done) icons.check else icons.schedule);
    if (x.path != null and !x.done)
        kit.link(ui, x.label, .{ .go = x.path.? }, .{})
    else if (x.done) kit.muted(ui, x.label) else kit.text(ui, x.label, .{});
    ui.end();
}

const Stat = struct { label: []const u8, value: []const u8, alert: bool = false, go: ?[]const u8 = null };

pub fn view(_: *const S, c: *const Cx, ui: *Ui) void {
    const k = kit.k;
    var need: std.ArrayList(u8) = .empty;
    need.append(ui.arena(), d_stats) catch {};
    if (c.can("org.settings")) {
        need.append(ui.arena(), d_hubs) catch {};
        if (c.can("members.view")) need.append(ui.arena(), d_members) catch {};
    }
    if (!kit.gate(ui, need.items)) return;
    const st = c.data(d_stats);
    const a = ui.arena();
    kit.stack(ui);
    checklist(c, ui);

    var stats: std.ArrayList(Stat) = .empty;
    const num = struct {
        fn f(al: std.mem.Allocator, v: ?V, path: []const u8) []const u8 {
            return fmt.number(al, json.numOr(v, path, 0), 0);
        }
    }.f;
    const needs = json.numOr(st, "needsAction", 0);
    stats.append(a, .{ .label = L("dash.needs_action"), .value = num(a, st, "needsAction"), .alert = needs > 0, .go = "/shipments?view=needs_action" }) catch {};
    if (c.can("dispatch.manage")) stats.append(a, .{ .label = L("dash.pending_tasks"), .value = num(a, st, "pendingTasks"), .alert = json.numOr(st, "pendingTasks", 0) > 0, .go = "/dispatch" }) catch {};
    inline for (.{ "awaiting_pickup", "at_hub", "in_transit", "out_for_delivery" }) |s| stats.append(a, .{ .label = labels.status(s), .value = num(a, st, "open." ++ s) }) catch {};
    stats.append(a, .{ .label = L("dash.created_today"), .value = num(a, st, "createdToday") }) catch {};
    stats.append(a, .{ .label = L("dash.delivered_today"), .value = num(a, st, "deliveredToday") }) catch {};
    if (c.can("fleet.view")) stats.append(a, .{ .label = L("dash.on_duty"), .value = num(a, st, "onDuty"), .go = "/fleet" }) catch {};
    if (c.can("alerts.manage")) stats.append(a, .{ .label = L("dash.open_alerts"), .value = num(a, st, "openAlerts"), .alert = json.numOr(st, "openAlerts", 0) > 0, .go = "/alerts" }) catch {};
    var g = kit.grid(ui, stats.items.len, 4);
    for (stats.items) |x| {
        g.cell();
        kit.stat(ui, x.label, x.value, .{ .alert = x.alert, .on_press = if (x.go) |p| Msg{ .go = p } else null });
        g.endCell();
    }
    g.end();

    // Live activity.
    kit.card(ui, .{ .gap = 8.8 });
    kit.cardHead(ui, L("dash.live_activity"));
    ui.begin(.{ .direction = .row, .align_items = .center, .gap = 4.8, .padding = .xy(10.4, 2.4), .radius = 999, .background = k.ok_bg }, .{});
    ui.begin(.{ .width = .{ .px = 7 }, .height = .{ .px = 7 }, .radius = 3.5, .background = k.ok_ink }, .{});
    ui.end();
    ui.text(L("common.live"), .{ .font_size = 12, .weight = 700, .color = k.ok_ink });
    ui.end();
    ui.end();
    kit.small(ui, L("dash.feed_hint"));
    kit.endCard(ui, .{});
    ui.end();
}

const Msg = core.Msg;

// ---- Tests --------------------------------------------------------------------------------

const testing = std.testing;
const app = @import("../app.zig");

pub const carrier_me =
    \\{"user":{"id":"u1","email":"sara@example.com","username":"Sara"},
    \\ "orgs":[{"id":"o2","type":"carrier","name":"Fast Express","slug":"fast","status":"active","branding":{},"isOwner":true,"memberStatus":"active","isCourier":false}],"invitations":[]}
;

test "carrier dashboard: checklist, numbers, links" {
    app.D.startWith(1280, 900, "/o/fast/");
    defer app.D.reset();
    try testing.expect(app.D.respond("/api/app/me", 200, carrier_me));
    try testing.expect(app.D.respond("/api/app/meta", 200, app.meta_json));
    try testing.expect(app.D.respond("/api/app/orgs/o2", 200,
        \\{"id":"o2","type":"carrier","name":"Fast Express","slug":"fast","status":"pending","readiness":["no_pricing"],"branding":{},
        \\ "me":{"isOwner":true,"permissions":["org.settings","members.view","shipments.view","dispatch.manage","fleet.view","alerts.manage"]}}
    ));
    try testing.expect(app.D.respond("/api/app/orgs/o2/carrier/stats", 200,
        \\{"needsAction":3,"pendingTasks":0,"open":{"awaiting_pickup":5,"at_hub":2},"createdToday":7,"deliveredToday":4,"onDuty":2,"openAlerts":1}
    ));
    try testing.expect(app.D.respond("/api/app/orgs/o2/carrier/hubs", 200, "[]"));
    try testing.expect(app.D.respond("/api/app/orgs/o2/members", 200, "[{\"courier\":{\"vehicle\":\"car\"}}]"));
    try testing.expect(app.D.findText("Get ready to receive orders") != 0);
    try testing.expect(app.D.findText("Set your prices") != 0);
    try testing.expect(app.D.findText("Need planning") != 0);
    try testing.expect(app.D.findText("Couriers on duty") != 0);
    try testing.expect(app.D.findText("7") != 0);
    try app.D.press("Add your hubs and branches");
    try testing.expectEqualStrings("/hubs", app.D.R.appState().route());
}
