//! The store's shipment page (Turf-js views/merchant/shipment.js): status and summary, the
//! relay route, the history, proof of delivery, the tracking link to share, the live map with
//! the courier, the addresses, feedback and the parcel; label, tracking page, cancel, change
//! details, delivery day, return and claim in the top bar. Live updates (the public tracking
//! stream in Turf-js) are polled.

const std = @import("std");
const zui = @import("zui");
const core = @import("../core.zig");
const kit = @import("../kit.zig");
const json = @import("../json.zig");
const fmt = @import("../fmt.zig");
const icons = @import("../icons.zig");
const labels = @import("../labels.zig");
const parts = @import("../widgets/parts.zig");
const mapw = @import("../widgets/map.zig");
const edit = @import("../widgets/shipment_edit.zig");
const claim = @import("../widgets/claim_dialog.zig");

const Cx = core.Cx;
const Ui = core.Ui;
const V = json.V;
const L = labels.k;

const d_ship: u8 = 0;

const A = enum(u16) { cancel_ask = 1, cancel, edit_details, edit_day, return_ask, return_req, claim_open };
const T = enum(u16) { poll = 1 };

pub const S = struct {
    m: mapw.Map = .{},
    edit: edit.Edit = .{},
    claim: claim.Dialog = .{ .cfg = .{ .slot = 420, .act = 420 } },
    fitted: bool = false,
};

fn ship(c: *const Cx) ?V {
    return json.get(c.data(d_ship), "shipment");
}

fn tracking(c: *const Cx) ?V {
    return json.get(c.data(d_ship), "tracking");
}

pub fn title(_: *const S, c: *const Cx) []const u8 {
    return json.str(ship(c), "trackingNumber");
}

fn path(c: *Cx) []const u8 {
    return c.print("/merchant/shipments/{s}", .{core.encode(c.arena(), c.param(1))});
}

pub fn enter(_: *S, c: *Cx) void {
    c.load(d_ship, c.orgUrl(path(c)));
    c.after(15_000, @intFromEnum(T.poll));
}

/// Events of the claim dialog (ids 420 and 421).
fn claim_ids(e: core.Ev) bool {
    return switch (e) {
        .act => |a| a.id == 420 or a.id == 421,
        .done => |d| d.id == 420 or d.id == 421,
        else => false,
    };
}

fn mapSize(c: *const Cx) [2]f32 {
    _ = c;
    const two = kit.width >= 2 * 280 + 16;
    return .{ if (two) (kit.width - 16) / 2 - 40 else kit.width - 40, 360 };
}

pub fn update(s: *S, c: *Cx, e: core.Ev) void {
    if (edit.update(&s.edit, c, e)) {
        if (s.edit.saved) {
            s.edit.saved = false;
            c.load(d_ship, c.orgUrl(path(c)));
        }
        return;
    }
    if (claim_ids(e)) {
        if (s.claim.update(c, e)) c.go("/claims");
        return;
    }
    const size = mapSize(c);
    s.m.setSize(size[0], size[1]);
    if (s.m.event(c, e) != null) return;
    switch (e) {
        .data => |n| if (n == d_ship and c.slot(d_ship).state == .ok and !s.fitted) {
            s.fitted = true;
            var pts: std.ArrayList(mapw.LatLng) = .empty;
            if (mapw.ll(ship(c), "pickup.location")) |p| pts.append(c.arena(), p) catch {};
            if (mapw.ll(ship(c), "dropoff.location")) |p| pts.append(c.arena(), p) catch {};
            if (mapw.ll(tracking(c), "courier.location")) |p| pts.append(c.arena(), p) catch {};
            s.m.fit(pts.items, .{ .animate = false });
        },
        .timer => |id| if (id == @intFromEnum(T.poll)) {
            c.load(d_ship, c.orgUrl(path(c)));
            c.after(15_000, @intFromEnum(T.poll));
        },
        .act => |a| switch (@as(A, @enumFromInt(a.id))) {
            .cancel_ask => c.ask(L("shipment.cancel_confirm"), .{ .danger = true, .act = .{ .id = @intFromEnum(A.cancel) } }),
            .cancel => c.send(@intFromEnum(A.cancel), .POST, c.orgUrl(c.print("/merchant/shipments/{s}/cancel", .{json.str(ship(c), "id")})), "{}"),
            .edit_details => edit.openDetails(&s.edit, c, c.print("/merchant/shipments/{s}", .{json.str(ship(c), "id")}), ship(c)),
            .edit_day => edit.openDay(&s.edit, c, c.print("/merchant/shipments/{s}", .{json.str(ship(c), "id")}), json.str(ship(c), "scheduledFor")),
            .return_ask => c.ask(L("returns.request_confirm"), .{ .act = .{ .id = @intFromEnum(A.return_req) } }),
            .return_req => c.send(@intFromEnum(A.return_req), .POST, c.orgUrl(c.print("/merchant/shipments/{s}/return-request", .{json.str(ship(c), "id")})), "{}"),
            .claim_open => s.claim.open(c, ship(c)),
        },
        .done => |d| switch (@as(A, @enumFromInt(d.id))) {
            .cancel => if (d.ok) {
                c.toast(L("common.saved"), .ok);
                c.load(d_ship, c.orgUrl(path(c)));
            },
            .return_req => if (d.ok) {
                c.toast(labels.tf(c.arena(), "returns.created", .{ .tn = json.str(d.v, "trackingNumber") }), .ok);
                c.go(c.print("/shipments/{s}", .{json.str(d.v, "id")}));
            },
            else => {},
        },
        else => {},
    }
}

fn isIn(x: []const u8, list: []const []const u8) bool {
    for (list) |l| if (std.mem.eql(u8, l, x)) return true;
    return false;
}

pub fn actions(_: *const S, c: *const Cx, ui: *Ui) void {
    const s = ship(c) orelse return;
    const st = json.str(s, "status");
    kit.button(ui, L("shipment.print_label"), .{ .open = c.asset(ui.arena(), json.str(s, "labelUrl")) }, .{ .size = .sm, .icon = icons.print });
    kit.button(ui, L("shipment.tracking_page"), .{ .open = json.str(s, "trackingUrl") }, .{ .size = .sm, .icon = icons.open_in_new, .flip = true });
    if (c.can("shipments.cancel") and std.mem.eql(u8, st, "awaiting_pickup"))
        kit.button(ui, L("shipment.cancel"), kit.act(A.cancel_ask, 0), .{ .size = .sm, .variant = .danger, .busy = @intFromEnum(A.cancel) });
    if (c.can("shipments.create") and edit.isEditable(st)) {
        kit.button(ui, L("edit.title"), kit.act(A.edit_details, 0), .{ .size = .sm, .icon = icons.edit });
        kit.button(ui, L("edit.reschedule_title"), kit.act(A.edit_day, 0), .{ .size = .sm, .icon = icons.schedule });
    }
    const delivered_ms = fmt.parseIso(json.str(s, "deliveredAt"));
    const within = if (delivered_ms) |ms| fmt.now() - ms < 30 * 86_400_000 else false;
    if (c.can("shipments.create") and std.mem.eql(u8, st, "delivered") and !json.has(s, "returnShipmentId") and !json.boolean(s, "test") and within)
        kit.button(ui, L("returns.request"), kit.act(A.return_ask, 0), .{ .size = .sm, .icon = icons.arrow_back, .flip = true, .busy = @intFromEnum(A.return_req) });
    if (c.can("shipments.create") and !json.boolean(s, "test") and !isIn(st, &.{ "awaiting_pickup", "awaiting_carrier", "cancelled" }))
        kit.button(ui, L("claims.open"), kit.act(A.claim_open, 0), .{ .size = .sm, .icon = icons.shield });
}

pub fn view(s: *const S, c: *const Cx, ui: *Ui) void {
    if (!kit.gate(ui, &.{d_ship})) return;
    const sh = ship(c);
    const tr = tracking(c);
    const a = ui.arena();
    const full_w = kit.width;
    var g = kit.grid(ui, 2, 2);
    // ---- First column.
    g.cell();
    kit.width = if (g.cols == 2) (full_w - 16) / 2 else full_w;
    kit.stack(ui);
    if (json.str(sh, "returnShipmentId").len > 0) {
        kit.noticeBegin(ui, .info, icons.info);
        kit.text(ui, L("returns.has_return"), .{});
        kit.link(ui, L("returns.open_return"), .{ .go = kit.f(ui, "/shipments/{s}", .{json.str(sh, "returnShipmentId")}) }, .{});
        kit.noticeEnd(ui);
    } else if (json.str(sh, "returnOf").len > 0) {
        kit.noticeBegin(ui, .info, icons.info);
        kit.text(ui, L("returns.is_return"), .{});
        kit.link(ui, L("returns.open_original"), .{ .go = kit.f(ui, "/shipments/{s}", .{json.str(sh, "returnOf")}) }, .{});
        kit.noticeEnd(ui);
    }
    summary(ui, c, sh, tr);
    if (json.arr(sh, "route").len > 0) routeCard(ui, c, sh);
    kit.card(ui, .{ .gap = 8.8 });
    kit.h2(ui, L("shipment.timeline"));
    parts.timeline(ui, c, json.arr(tr, "events"), .{});
    kit.endCard(ui, .{});
    if (json.obj(sh, "pod")) |pod| {
        kit.card(ui, .{ .gap = 8.8 });
        kit.h2(ui, L("shipment.proof_of_delivery"));
        if (json.str(pod, "receiverName").len > 0) parts.kv(ui, L("shipment.receiver_name"), json.str(pod, "receiverName"));
        parts.kv(ui, L("common.when"), fmt.dateTime(a, json.str(pod, "at")));
        if (json.boolean(pod, "hasPhoto")) {
            ui.begin(.{ .radius = 16, .background = kit.k.panel_2, .clip = true, .height = .{ .px = 240 } }, .{});
            ui.imageWith(kit.f(ui, "{s}/api/app/orgs/{s}/merchant/shipments/{s}/pod-photo", .{ core.api_base, c.orgId(), json.str(sh, "id") }), .{ .headers = c.headers(ui.arena()) }, .{ .width = .fill, .height = .{ .px = 240 } }, zui.key("pod"));
            ui.end();
        }
        kit.endCard(ui, .{});
    }
    share(ui, sh);
    ui.end();
    g.endCell();
    // ---- Second column.
    g.cell();
    kit.stack(ui);
    kit.card(ui, .{ .gap = 8.8 });
    var pins: std.ArrayList(mapw.Pin) = .empty;
    if (mapw.ll(sh, "pickup.location")) |p| pins.append(a, .{ .at = p, .icon = mapw.placeIcon("shop"), .kind = .place, .key = zui.key("pickup") }) catch {};
    if (mapw.ll(sh, "dropoff.location")) |p| pins.append(a, .{ .at = p, .icon = mapw.placeIcon("home"), .kind = .place, .key = zui.key("dropoff") }) catch {};
    if (mapw.ll(tr, "courier.location")) |p| pins.append(a, .{ .at = p, .icon = mapw.vehicleIcon(json.str(tr, "courier.vehicle")), .key = zui.key("courier") }) catch {};
    mapw.draw(ui, &s.m, .{ .width = kit.width - 40, .height = 360, .radius = 16, .pins = pins.items });
    courierLine(ui, json.obj(tr, "courier"));
    kit.endCard(ui, .{});
    var g2 = kit.grid(ui, 2, 2);
    g2.cell();
    parts.addressBlock(ui, c, L("shipment.pickup"), json.obj(sh, "pickup"));
    g2.endCell();
    g2.cell();
    parts.addressBlock(ui, c, L("shipment.recipient"), json.obj(sh, "dropoff"));
    g2.endCell();
    g2.end();
    parts.feedbackBlock(ui, sh);
    parts.parcelBlock(ui, sh);
    ui.end();
    g.endCell();
    g.end();
    kit.width = full_w;
}

fn courierLine(ui: *Ui, cr: ?V) void {
    const k = kit.k;
    const a = ui.arena();
    const x = cr orelse return kit.small(ui, L("track.no_live_courier"));
    ui.begin(.{ .direction = .row, .gap = 8, .align_items = .center }, .{});
    kit.icon(ui, icons.navigation, 18, k.ink_2);
    ui.text(json.str(x, "name"), .{ .font_size = 13.6, .weight = 700, .color = k.ink });
    kit.small(ui, labels.vehicle(json.str(x, "vehicle")));
    if (json.num(x, "etaMinutes")) |m| if (m > 0) kit.badge(ui, ui.tf(labels.english("track.eta") orelse "{time}", .{ .time = fmt.duration(a, m) }), .brand);
    if (json.str(x, "updatedAt").len > 0) kit.small(ui, fmt.relative(a, json.str(x, "updatedAt")));
    ui.end();
}

fn summary(ui: *Ui, c: *const Cx, sh: ?V, tr: ?V) void {
    const a = ui.arena();
    kit.card(ui, .{ .gap = 8.8 });
    ui.begin(.{ .direction = .row, .justify = .space_between, .align_items = .center }, .{});
    ui.begin(.{ .direction = .row, .gap = 6.4, .align_items = .center }, .{});
    kit.statusBadge(ui, json.str(tr, "status"));
    if (std.mem.eql(u8, json.str(sh, "service"), "express") or json.boolean(sh, "express")) kit.expressBadge(ui);
    ui.end();
    kit.small(ui, fmt.relative(a, json.str(tr, "updatedAt")));
    ui.end();
    const cod = json.obj(sh, "cod");
    const code = json.str(sh, "deliveryCode");
    parts.kv(ui, L("shipment.carrier"), json.str(sh, "carrier.name"));
    parts.kv(ui, L("shipment.reference"), json.strOr(sh, "reference", "—"));
    parts.kv(ui, L("common.created"), fmt.dateTime(a, json.str(sh, "createdAt")));
    parts.kv(ui, L("shipment.promised_by"), fmt.dateTime(a, json.str(sh, "promisedBy")));
    parts.kv(ui, L("shipment.price"), fmt.money(a, json.num(sh, "price.amount"), json.str(sh, "price.currency")));
    parts.kv(ui, L("shipment.cod"), if (cod) |x| fmt.money(a, json.num(x, "amount"), json.str(x, "currency")) else L("common.none"));
    if (cod) |x| parts.kv(ui, L("shipment.cod_status"), if (json.has(x, "remittedAt")) L("cod.remitted") else if (json.has(x, "settledAt")) L("cod.settled") else if (json.has(x, "collectedAt")) L("cod.collected") else L("cod.pending"));
    if (code.len > 0) {
        kit.kvBegin(ui, L("shipment.delivery_code"), true);
        kit.mono(ui, code, .{ .size = 19.2, .weight = 700 });
        kit.kvEnd(ui, true);
        kit.small(ui, L("shipment.delivery_code_hint"));
    }
    kit.endCard(ui, .{});
    _ = c;
}

fn routeCard(ui: *Ui, c: *const Cx, sh: ?V) void {
    const a = ui.arena();
    var legs: std.ArrayList(V) = .empty;
    for (json.arr(sh, "route")) |l| {
        var m: std.json.ObjectMap = .empty;
        m.put(a, "name", .{ .string = json.str(l, "carrier.name") }) catch {};
        m.put(a, "from", json.get(l, "from") orelse .null) catch {};
        m.put(a, "to", json.get(l, "to") orelse .null) catch {};
        m.put(a, "hub", .{ .string = json.str(l, "handoverHub.name") }) catch {};
        m.put(a, "city", .{ .string = json.str(l, "handoverHub.city") }) catch {};
        m.put(a, "status", json.get(l, "status") orelse .null) catch {};
        m.put(a, "price", json.get(l, "price") orelse .null) catch {};
        legs.append(a, .{ .object = m }) catch {};
    }
    parts.routeBlock(ui, c, legs.items, .{});
}

fn share(ui: *Ui, sh: ?V) void {
    const k = kit.k;
    const url = json.str(sh, "trackingUrl");
    kit.card(ui, .{ .gap = 8.8 });
    kit.h2(ui, L("shipment.share_tracking"));
    ui.begin(.{ .padding = .xy(16, 12), .radius = 16, .background = k.panel_3, .no_mirror = true }, .{});
    kit.mono(ui, url, .{ .size = 13.6 });
    ui.end();
    ui.begin(.{ .direction = .row, .gap = 12 }, .{});
    kit.copyButton(ui, url, L("team.copy_link"));
    const phone = json.str(sh, "dropoff.phone");
    if (phone.len > 0) {
        const a = ui.arena();
        var p = phone;
        if (p.len > 0 and p[0] == '+') p = p[1..];
        const intl = if (p.len > 0 and p[0] == '0') kit.f(ui, "963{s}", .{p[1..]}) else p;
        const msg = ui.tf(labels.english("shipment.share_message") orelse "{link}", .{ .link = url });
        kit.button(ui, L("shipment.send_whatsapp"), .{ .open = kit.f(ui, "https://wa.me/{s}?text={s}", .{ intl, core.encode(a, msg) }) }, .{ .size = .sm, .icon = icons.call });
    }
    ui.end();
    kit.endCard(ui, .{});
}

pub fn overlay(s: *const S, c: *const Cx, ui: *Ui) void {
    edit.overlay(&s.edit, c, ui);
    s.claim.overlay(ui);
}

// ---- Tests --------------------------------------------------------------------------------

const app = @import("../app.zig");
const testing = std.testing;

pub const merchant_org =
    \\{"id":"o1","type":"merchant","name":"Acme Store","slug":"acme","status":"active","branding":{"appName":"Acme Store"},
    \\ "me":{"memberId":"m1","isOwner":true,"permissions":["shipments.view","shipments.create","shipments.cancel","api.manage","org.settings","finance.view"]},
    \\ "merchant":{"places":[]}}
;
const ship_json =
    \\{"shipment":{"id":"s1","trackingNumber":"TRF123","status":"awaiting_pickup","reference":"ORDER-1","carrier":{"name":"Sham Express"},
    \\  "createdAt":"2025-10-12T10:00:00.000Z","price":{"amount":15000,"currency":"SYP"},"cod":{"amount":450000,"currency":"SYP"},
    \\  "deliveryCode":"1661","labelUrl":"/o/acme/label/tok","trackingUrl":"http://x/t/tok",
    \\  "pickup":{"name":"Main warehouse","city":"Damascus","governorate":"DAM","location":{"lat":33.51,"lng":36.27}},
    \\  "dropoff":{"name":"Rami","phone":"0944000001","city":"Damascus","area":"Mazzeh","governorate":"DAM","location":{"lat":33.52,"lng":36.28}},
    \\  "parcel":{"weightKg":1.2,"pieces":1}},
    \\ "tracking":{"status":"awaiting_pickup","updatedAt":"2025-10-12T10:00:00.000Z","events":[{"code":"created","at":"2025-10-12T10:00:00.000Z","textEn":"Order received","textAr":"تم استلام الطلب"}],"courier":null}}
;

test "store shipment: details, cancel, change the recipient" {
    try app.startSignedIn("/o/acme/shipments/s1");
    defer app.D.reset();
    const D = app.D;
    try testing.expect(D.respond("/api/app/orgs/o1", 200, merchant_org));
    try testing.expect(D.respond("/merchant/shipments/s1", 200, ship_json));
    try testing.expect(D.findText("TRF123") != 0);
    try testing.expect(D.findText("Order received") != 0);
    try testing.expect(D.findText("1661") != 0);
    try testing.expect(D.findText("450,000 SYP") != 0);
    try D.press("Cancel shipment");
    try D.press("Confirm");
    try testing.expect(D.respond("/merchant/shipments/s1/cancel", 200, "{}"));
    try testing.expect(D.pending("/merchant/shipments/s1") != null);
    try testing.expect(D.respond("/merchant/shipments/s1", 200, ship_json));
    D.R.dispatch(.{ .act = .{ .id = @intFromEnum(A.edit_details) } });
    try D.typeInto("", "x");
    D.R.dispatch(.{ .act = .{ .id = @intFromEnum(edit.A.save_details) } });
    const f = zui.host.fetches.items[zui.host.fetches.items.len - 1];
    try testing.expectEqualStrings("PATCH", f.method);
    try testing.expect(std.mem.indexOf(u8, f.body, "\"phone\":\"0944000001\"") != null);
    try testing.expect(D.respond("/merchant/shipments/s1", 200, "{}"));
    try testing.expect(D.findText("Saved") != 0);
}
