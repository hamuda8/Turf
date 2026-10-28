//! "My parcels" (Turf-js views/direct/parcels.js `list`): what a person sent with direct
//! shipping. Only reachable when direct shipping is switched on in Control.

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
const L = labels.k;

const d_list: u8 = 0;

pub const S = struct {};

pub fn title(_: *const S, _: *const Cx) []const u8 {
    return L("direct.my_parcels");
}

pub fn enter(_: *S, c: *Cx) void {
    c.load(d_list, c.appUrl("/direct/shipments"));
}

pub fn update(_: *S, _: *Cx, _: core.Ev) void {}

pub fn actions(_: *const S, _: *const Cx, ui: *Ui) void {
    kit.button(ui, L("direct.send_title"), .{ .go = "/send" }, .{ .variant = .primary, .icon = icons.add });
}

pub fn view(_: *const S, c: *const Cx, ui: *Ui) void {
    if (!kit.gate(ui, &.{d_list})) return;
    const list = json.arr(c.data(d_list), "");
    if (list.len == 0) {
        kit.emptyBegin(ui, L("direct.no_parcels"));
        kit.button(ui, L("direct.send_title"), .{ .go = "/send" }, .{ .variant = .primary });
        kit.emptyEnd(ui);
        return;
    }
    const cols = [_]kit.Table.Col{
        .{ .label = L("shipment.tracking_number") },
        .{ .label = L("shipment.recipient") },
        .{ .label = L("common.status") },
        .{ .label = L("direct.company") },
        .{ .label = L("common.created") },
    };
    var tb = kit.Table.begin(ui, &cols);
    const k = kit.k;
    for (list) |p| {
        const id = json.str(p, "id");
        tb.row(.{ .go = kit.f(ui, "/parcels/{s}", .{id}) }, zui.key(id));
        tb.cell(false);
        ui.text(json.str(p, "trackingNumber"), .{ .font_size = 16, .weight = 500, .color = k.a, .mono = true });
        tb.endCell();
        tb.cell(true);
        const name = json.str(p, "dropoff.name");
        kit.text(ui, if (name.len > 0) name else json.strOr(p, "dropoff.phone", "—"), .{});
        kit.small(ui, json.str(p, "dropoff.city"));
        tb.endCell();
        tb.cell(true);
        kit.statusBadge(ui, json.str(p, "status"));
        tb.endCell();
        tb.cell(true);
        kit.text(ui, json.strOr(p, "carrierName", "—"), .{});
        tb.endCell();
        tb.cell(true);
        kit.text(ui, fmt.relative(ui.arena(), json.str(p, "createdAt")), .{});
        tb.endCell();
        tb.endRow();
    }
    tb.end();
}

// ---- Tests ------------------------------------------------------------------------------------

const app = @import("../app.zig");
const testing = std.testing;

test "my parcels: the list opens a parcel" {
    try @import("direct_send.zig").startDirect("/app/parcels");
    defer app.D.reset();
    try testing.expect(app.D.respond("/direct/shipments", 200,
        \\[{"id":"d1","trackingNumber":"TRF-9","dropoff":{"phone":"0944","city":"Damascus"},"status":"awaiting_carrier","createdAt":"2025-10-12T11:00:00.000Z"}]
    ));
    try testing.expect(app.D.findText("0944") != 0);
    try app.D.press("TRF-9");
    try testing.expect(app.D.pending("/direct/shipments/d1") != null);
}

test "my parcels: none yet" {
    try @import("direct_send.zig").startDirect("/app/parcels");
    defer app.D.reset();
    try testing.expect(app.D.respond("/direct/shipments", 200, "[]"));
    try testing.expect(app.D.findText(L("direct.no_parcels")) != 0);
}
