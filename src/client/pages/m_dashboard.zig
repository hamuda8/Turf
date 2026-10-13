//! Merchant dashboard (Turf-js views/merchant/dashboard.js): shipment numbers, cash awaiting
//! payout, getting started.

const std = @import("std");
const zui = @import("zui");
const core = @import("../core.zig");
const kit = @import("../kit.zig");
const json = @import("../json.zig");
const fmt = @import("../fmt.zig");
const icons = @import("../icons.zig");
const labels = @import("../labels.zig");
const landing = @import("landing.zig");
const c_dashboard = @import("c_dashboard.zig");

const Cx = core.Cx;
const Ui = core.Ui;
const V = json.V;
const L = labels.k;

const d_stats: u8 = 0;
const d_keys: u8 = 1;

const in_progress = [_][]const u8{ "awaiting_pickup", "picked_up", "at_hub", "in_transit", "out_for_delivery", "delivery_failed", "returning" };

pub const S = struct {};

pub fn title(_: *const S, _: *const Cx) []const u8 {
    return L("nav.dashboard");
}

pub fn enter(_: *S, c: *Cx) void {
    c.load(d_stats, c.orgUrl("/merchant/stats"));
    @import("../app.zig").reloadOrg(c);
    if (c.can("api.manage")) c.load(d_keys, c.orgUrl("/merchant/api-keys"));
}

pub fn update(_: *S, _: *Cx, _: core.Ev) void {}

pub fn actions(_: *const S, c: *const Cx, ui: *Ui) void {
    if (c.can("shipments.create")) kit.button(ui, L("nav.new_shipment"), .{ .go = "/shipments/new" }, .{ .variant = .primary, .icon = icons.add });
}

fn anyNonZero(v: ?V) bool {
    const o = v orelse return false;
    if (o != .object) return false;
    var it = o.object.iterator();
    while (it.next()) |e| if (json.boolean(e.value_ptr.*, "") or (json.num(e.value_ptr.*, "") orelse 0) != 0) return true;
    return false;
}

pub fn view(_: *const S, c: *const Cx, ui: *Ui) void {
    const need: []const u8 = if (c.can("api.manage")) &.{ d_stats, d_keys } else &.{d_stats};
    if (!kit.gate(ui, need)) return;
    const st = c.data(d_stats);
    const org = c.orgV();
    const a = ui.arena();
    kit.stack(ui);
    if (std.mem.eql(u8, json.str(org, "status"), "pending")) kit.notice(ui, .warn, L("mdash.pending_approval"));

    // Getting started.
    const Step = c_dashboard.Step;
    var steps: std.ArrayList(Step) = .empty;
    steps.append(a, .{ .done = json.arr(org, "merchant.places").len > 0, .label = L("mdash.step_pickup"), .path = "/settings" }) catch {};
    if (c.can("api.manage")) steps.append(a, .{ .done = json.arr(c.data(d_keys), "").len > 0, .label = L("mdash.step_key"), .path = "/developers" }) catch {};
    steps.append(a, .{ .done = anyNonZero(json.get(st, "last30Days")), .label = L("mdash.step_first"), .path = "/shipments/new" }) catch {};
    var open_steps = false;
    for (steps.items) |x| if (!x.done) {
        open_steps = true;
    };
    if (open_steps) {
        kit.card(ui, .{ .gap = 8.8 });
        kit.h2(ui, L("mdash.getting_started"));
        for (steps.items) |x| c_dashboard.stepRow(ui, x);
        ui.begin(.{ .direction = .row, .gap = 4, .align_items = .center }, .{});
        kit.small(ui, L("mdash.docs_hint"));
        kit.link(ui, L("nav.api_docs"), .{ .open = landing.serverUrl(ui, "/developers") }, .{ .size = 13.6 });
        ui.end();
        kit.endCard(ui, .{});
    }

    kit.h2(ui, L("mdash.in_progress"));
    var g = kit.grid(ui, in_progress.len, 4);
    for (in_progress) |s| {
        g.cell();
        const n = json.numOr(st, kit.f(ui, "open.{s}", .{s}), 0);
        kit.stat(ui, labels.status(s), fmt.number(a, n, 0), .{ .alert = std.mem.eql(u8, s, "delivery_failed") and n > 0, .on_press = .{ .go = kit.f(ui, "/shipments?status={s}", .{s}) } });
        g.endCell();
    }
    g.end();

    kit.h2(ui, L("mdash.last_30_days"));
    const cod = json.arr(st, "codAwaitingPayout");
    var g2 = kit.grid(ui, 3 + cod.len, 4);
    inline for (.{ "delivered", "returned", "cancelled" }) |s| {
        g2.cell();
        kit.stat(ui, labels.status(s), fmt.number(a, json.numOr(st, "last30Days." ++ s, 0), 0), .{});
        g2.endCell();
    }
    for (cod) |x| {
        g2.cell();
        kit.stat(ui, ui.tf(labels.english("mdash.cod_awaiting") orelse "{n}", .{ .n = json.int(x, "count") }), fmt.money(a, json.num(x, "amount"), json.str(x, "currency")), .{});
        g2.endCell();
    }
    g2.end();
    ui.end();
}

// ---- Tests --------------------------------------------------------------------------------

const testing = std.testing;
const app = @import("../app.zig");

test "merchant dashboard: getting started and the numbers" {
    try app.startSignedIn("/o/acme/");
    defer app.D.reset();
    try testing.expect(app.D.respond("/api/app/orgs/o1", 200,
        \\{"id":"o1","type":"merchant","name":"Acme Store","slug":"acme","status":"pending","merchant":{"places":[]},
        \\ "me":{"isOwner":true,"permissions":["org.settings","shipments.view","shipments.create","api.manage"]}}
    ));
    try testing.expect(app.D.respond("/api/app/orgs/o1/merchant/stats", 200,
        \\{"open":{"awaiting_pickup":2,"delivery_failed":1},"last30Days":{"delivered":0,"returned":0},"codAwaitingPayout":[{"count":3,"amount":150000,"currency":"SYP"}]}
    ));
    try testing.expect(app.D.respond("/api/app/orgs/o1/merchant/api-keys", 200, "[]"));
    try testing.expect(app.D.findText("Getting started") != 0);
    try testing.expect(app.D.findText("Save a pickup place") != 0);
    try testing.expect(app.D.findText("Cash awaiting payout (3)") != 0);
    try testing.expect(app.D.findText("150,000 SYP") != 0);
    try testing.expect(app.D.findText("New shipment") != 0);
    try app.D.press("Delivery failed");
    try testing.expectEqualStrings("/shipments?status=delivery_failed", app.D.R.appState().pathStr());
}
