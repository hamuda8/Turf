//! One parcel sent with direct shipping (Turf-js views/direct/parcels.js `detail`): who carries
//! it, the price, the delivery code, links to share, cancel, and its history. Refreshes every
//! 20 seconds while companies are being asked or the parcel is moving.

const std = @import("std");
const zui = @import("zui");
const core = @import("../core.zig");
const kit = @import("../kit.zig");
const json = @import("../json.zig");
const fmt = @import("../fmt.zig");
const icons = @import("../icons.zig");
const labels = @import("../labels.zig");
const parts = @import("../widgets/parts.zig");

const Cx = core.Cx;
const Ui = core.Ui;
const V = json.V;
const L = labels.k;

const d_parcel: u8 = 0;
const t_refresh: u16 = 1;

const A = enum(u16) { cancel_ask = 1, cancel };

pub const S = struct {};

pub fn title(_: *const S, c: *const Cx) []const u8 {
    return json.str(c.data(d_parcel), "trackingNumber");
}

pub fn enter(_: *S, c: *Cx) void {
    c.load(d_parcel, c.appUrl(c.print("/direct/shipments/{s}", .{core.encode(c.arena(), c.param(1))})));
    c.after(20_000, t_refresh);
}

fn finished(status: []const u8) bool {
    for ([_][]const u8{ "delivered", "returned", "cancelled" }) |x| if (std.mem.eql(u8, status, x)) return true;
    return false;
}

pub fn update(_: *S, c: *Cx, e: core.Ev) void {
    const p = c.data(d_parcel);
    switch (e) {
        .timer => |id| if (id == t_refresh) {
            // A finished parcel does not change any more: the refreshing stops.
            if (p != null and finished(json.str(p, "status"))) return;
            c.after(20_000, t_refresh);
            if (p != null) c.load(d_parcel, c.appUrl(c.print("/direct/shipments/{s}", .{json.str(p, "id")})));
        },
        .act => |a| switch (@as(A, @enumFromInt(a.id))) {
            .cancel_ask => c.ask(L("direct.cancel_confirm"), .{ .danger = true, .act = .{ .id = @intFromEnum(A.cancel) } }),
            .cancel => c.send(@intFromEnum(A.cancel), .POST, c.appUrl(c.print("/direct/shipments/{s}/cancel", .{json.str(p, "id")})), ""),
        },
        .done => |d| if (d.id == @intFromEnum(A.cancel) and d.ok) {
            // The answer is the parcel as it is now.
            const slot = &c.slots[d_parcel];
            slot.reset();
            slot.value = json.parse(slot.arena.allocator(), d.body);
            slot.state = .ok;
            c.toast(L("common.saved"), .ok);
        },
        else => {},
    }
}

pub fn view(_: *const S, c: *const Cx, ui: *Ui) void {
    if (!kit.gate(ui, &.{d_parcel})) return;
    const s = c.data(d_parcel);
    const k = kit.k;
    const a = ui.arena();
    const outer = kit.width;
    kit.width = @min(outer, 760);
    defer kit.width = outer;
    const status = json.str(s, "status");
    const waiting = std.mem.eql(u8, status, "awaiting_carrier");
    const cancellable = waiting or std.mem.eql(u8, status, "awaiting_pickup");

    ui.begin(.{ .gap = 16, .width = .{ .px = kit.width } }, .{});
    kit.card(ui, .{ .gap = 8.8 });
    kit.rowBetween(ui);
    ui.text(json.str(s, "trackingNumber"), .{ .font_size = 15, .weight = 700, .color = k.ink, .mono = true });
    kit.statusBadge(ui, status);
    ui.end();
    if (waiting and json.has(s, "offer")) {
        kit.noticeBegin(ui, .info, icons.schedule);
        kit.text(ui, ui.tf(labels.english("direct.waiting") orelse "{company}", .{ .company = json.str(s, "offer.carrierName"), .n = json.int(s, "offer.position"), .of = json.int(s, "offer.of"), .until = fmt.dateTime(a, json.str(s, "offer.expiresAt")) }), .{});
        kit.noticeEnd(ui);
    }
    if (std.mem.eql(u8, status, "awaiting_pickup")) {
        kit.noticeBegin(ui, .ok, icons.check);
        kit.text(ui, ui.tf(labels.english("direct.accepted_note") orelse "{company}", .{ .company = json.str(s, "carrier.name"), .price = fmt.money(a, json.num(s, "price.amount"), json.str(s, "price.currency")) }), .{});
        kit.noticeEnd(ui);
    }
    parts.kv(ui, L("direct.company"), json.strOr(s, "carrier.name", "—"));
    if (json.has(s, "price")) parts.kv(ui, L("direct.price"), fmt.money(a, json.num(s, "price.amount"), json.str(s, "price.currency")));
    if (json.has(s, "cod")) parts.kv(ui, L("direct.cod"), fmt.money(a, json.num(s, "cod.amount"), json.str(s, "cod.currency")));
    const code = json.str(s, "deliveryCode");
    if (code.len > 0) {
        kit.kvBegin(ui, L("shipment.delivery_code"), false);
        ui.text(code, .{ .font_size = 15, .weight = 700, .color = k.ink, .mono = true });
        kit.kvEnd(ui, false);
    }
    // The sender tells the recipient themselves (Turf never messages people).
    var row = kit.Wrap.begin(ui, kit.width - 40, 6.4);
    row.item(kit.estimate(L("team.copy_link"), 12.8) + 50);
    kit.copyButton(ui, json.str(s, "trackingUrl"), L("team.copy_link"));
    const phone = json.str(s, "dropoff.phone");
    if (phone.len > 0) {
        var digits: std.ArrayList(u8) = .empty;
        for (phone) |ch| if (std.ascii.isDigit(ch)) digits.append(a, ch) catch {};
        const num = if (digits.items.len > 0 and digits.items[0] == '0') kit.f(ui, "963{s}", .{digits.items[1..]}) else digits.items;
        const message = ui.tf(labels.english("direct.share_text") orelse "{url}", .{ .tn = json.str(s, "trackingNumber"), .url = json.str(s, "trackingUrl"), .code = code });
        row.item(90);
        kit.button(ui, "WhatsApp", .{ .open = kit.f(ui, "https://wa.me/{s}?text={s}", .{ num, core.encode(a, message) }) }, .{ .size = .sm });
    }
    if (cancellable) {
        row.item(kit.estimate(L("direct.cancel"), 12.8) + 30);
        kit.button(ui, L("direct.cancel"), kit.act(A.cancel_ask, 0), .{ .size = .sm, .variant = .danger, .busy = @intFromEnum(A.cancel) });
    }
    row.end();
    kit.small(ui, L("direct.share_hint"));
    kit.endCard(ui, .{});

    kit.card(ui, .{ .gap = 8.8 });
    kit.h2(ui, L("shipment.timeline"));
    parts.timeline(ui, c, json.arr(s, "events"), .{});
    kit.endCard(ui, .{});
    ui.end();
}

// ---- Tests ------------------------------------------------------------------------------------

const app = @import("../app.zig");
const testing = std.testing;

const parcel_json =
    \\{"id":"d1","trackingNumber":"TRF-9","status":"awaiting_carrier","trackingUrl":"https://x/t/abc","deliveryCode":"4321",
    \\ "dropoff":{"phone":"0944 111"},"offer":{"carrierName":"Fast Express","position":1,"of":3,"expiresAt":"2025-10-12T12:30:00.000Z"},
    \\ "events":[{"at":"2025-10-12T11:00:00.000Z","textEn":"Created","textAr":"أنشئت"}]}
;

test "a parcel: share, cancel, refresh" {
    try @import("direct_send.zig").startDirect("/app/parcels/d1");
    defer app.D.reset();
    try testing.expect(app.D.respond("/direct/shipments/d1", 200, parcel_json));
    try testing.expect(app.D.findText("4321") != 0);
    try testing.expect(app.D.findText("Created") != 0);
    try app.D.press("WhatsApp");
    try testing.expect(std.mem.startsWith(u8, zui.host.opened.items, "https://wa.me/963944111?text="));
    try app.D.press(L("direct.cancel"));
    try app.D.press(L("common.confirm"));
    try testing.expect(app.D.respond("/direct/shipments/d1/cancel", 200,
        \\{"id":"d1","trackingNumber":"TRF-9","status":"cancelled","events":[]}
    ));
    try testing.expect(app.D.findText(L("direct.cancel")) == 0);
    app.D.runTimers();
    // Finished: no more refreshing.
    try testing.expect(app.D.pending("/direct/shipments/d1") == null);
}
