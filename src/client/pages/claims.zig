//! Claims for lost, damaged or late parcels (Turf-js views/shared/claims.js `claimsPage`).
//! Stores open them (from a shipment: widgets/claim_dialog.zig) and may withdraw them; shipping
//! companies accept or reject them. Accepted compensation is added to the store's payout.
//! One page for both sides: `c.isCarrier()` decides.

const std = @import("std");
const zui = @import("zui");
const core = @import("../core.zig");
const kit = @import("../kit.zig");
const shell = @import("../shell.zig");
const json = @import("../json.zig");
const fmt = @import("../fmt.zig");
const icons = @import("../icons.zig");
const labels = @import("../labels.zig");
const address = @import("../widgets/address.zig");

const Cx = core.Cx;
const Ui = core.Ui;
const V = json.V;
const L = labels.k;

const d_claims: u8 = 0;
const f_amount: u16 = 1;
const f_response: u16 = 2;

const A = enum(u16) { filter = 1, accept, reject, decide_close, decide, withdraw_ask, withdraw };

const views = [_][]const u8{ "open", "accepted", "rejected", "all" };

pub const S = struct {
    view: u8 = 0,
    /// The claim being decided (index in the shown list) and how.
    deciding: ?u32 = null,
    accept: bool = false,
};

pub fn title(_: *const S, _: *const Cx) []const u8 {
    return L("claims.title");
}

fn base(c: *const Cx) []const u8 {
    return if (c.isCarrier()) "/carrier" else "/merchant";
}

pub fn enter(_: *S, c: *Cx) void {
    c.load(d_claims, c.orgUrl(c.print("{s}/claims", .{base(c)})));
}

/// The claims of the chosen view.
fn shown(s: *const S, c: *const Cx, a: std.mem.Allocator) []const V {
    const all = json.arr(c.data(d_claims), "");
    if (s.view == 3) return all;
    var out: std.ArrayList(V) = .empty;
    for (all) |x| if (std.mem.eql(u8, json.str(x, "status"), views[s.view])) out.append(a, x) catch {};
    return out.items;
}

pub fn update(s: *S, c: *Cx, e: core.Ev) void {
    const list = shown(s, c, c.arena());
    switch (e) {
        .act => |x| switch (@as(A, @enumFromInt(x.id))) {
            .filter => if (x.arg != s.view and x.arg < views.len) {
                s.view = @intCast(x.arg);
                c.load(d_claims, c.orgUrl(c.print("{s}/claims", .{base(c)})));
            },
            .accept, .reject => if (x.arg < list.len) {
                s.deciding = x.arg;
                s.accept = @as(A, @enumFromInt(x.id)) == .accept;
                c.setVal(f_amount, json.text(c.arena(), list[x.arg], "amount"));
                c.setVal(f_response, "");
                c.clearFieldError();
            },
            .decide_close => s.deciding = null,
            .decide => if (s.deciding) |i| if (i < list.len) {
                var b = json.Obj.init(c.arena());
                b.str("decision", if (s.accept) "accepted" else "rejected");
                if (s.accept) address.numField(&b, "amount", c.val(f_amount));
                b.strOpt("response", c.val(f_response));
                c.send(@intFromEnum(A.decide), .POST, c.orgUrl(c.print("{s}/claims/{s}/decide", .{ base(c), json.str(list[i], "id") })), b.done());
            },
            .withdraw_ask => if (x.arg < list.len) c.ask(L("claims.withdraw_confirm"), .{ .act = .{ .id = @intFromEnum(A.withdraw), .arg = x.arg } }),
            .withdraw => if (x.arg < list.len) c.sendArg(@intFromEnum(A.withdraw), x.arg, .POST, c.orgUrl(c.print("{s}/claims/{s}/withdraw", .{ base(c), json.str(list[x.arg], "id") })), ""),
        },
        .done => |d| if (d.ok) switch (@as(A, @enumFromInt(d.id))) {
            .decide, .withdraw => {
                s.deciding = null;
                c.toast(L("common.saved"), .ok);
                c.load(d_claims, c.orgUrl(c.print("{s}/claims", .{base(c)})));
            },
            else => {},
        },
        else => {},
    }
}

fn statusTone(st: []const u8) kit.Tone {
    if (std.mem.eql(u8, st, "open")) return .amber;
    if (std.mem.eql(u8, st, "accepted")) return .green;
    if (std.mem.eql(u8, st, "rejected")) return .red;
    return .plain;
}

pub fn view(s: *const S, c: *const Cx, ui: *Ui) void {
    const k = kit.k;
    const carrier = c.isCarrier();
    const outer = kit.width;
    kit.width = @min(outer, 900);
    defer kit.width = outer;
    ui.begin(.{ .gap = 16, .width = .{ .px = kit.width } }, .{});
    kit.muted(ui, L(if (carrier) "claims.intro_carrier" else "claims.intro_store"));
    var w = kit.Wrap.begin(ui, kit.width, 6.4);
    for (views, 0..) |v, i| {
        const lbl = if (i == 3) L("common.all") else labels.of("claims.status.", v);
        w.item(kit.estimate(lbl, 13.4) + 31);
        kit.chip(ui, lbl, s.view == i, kit.act(A.filter, @intCast(i)));
    }
    w.end();
    if (kit.gate(ui, &.{d_claims})) {
        const list = shown(s, c, ui.arena());
        if (list.len == 0) kit.empty(ui, L(if (s.view == 0) "claims.none_open" else "claims.none")) else {
            ui.begin(.{ .gap = 8.8 }, .{});
            const a = ui.arena();
            for (list, 0..) |x, i| {
                const st = json.str(x, "status");
                const cur = json.str(x, "currency");
                kit.card(ui, .{ .gap = 8.8, .key = zui.key(json.str(x, "id")) });
                ui.begin(.{ .direction = .row, .gap = 8, .align_items = .start, .justify = .space_between }, .{});
                ui.begin(.{ .direction = .row, .gap = 4.8, .align_items = .center, .grow = 1 }, .{});
                kit.link(ui, json.str(x, "trackingNumber"), .{ .go = kit.f(ui, "/shipments/{s}", .{json.str(x, "shipmentId")}) }, .{ .mono = true });
                ui.text("·", .{ .font_size = 15, .color = k.ink_3 });
                kit.strong(ui, labels.of("claims.type.", json.str(x, "type")));
                ui.text("·", .{ .font_size = 15, .color = k.ink_3 });
                ui.text(json.str(x, if (carrier) "merchantName" else "carrierName"), .{ .font_size = 15, .color = k.ink, .grow = 1 });
                ui.end();
                kit.badge(ui, labels.of("claims.status.", st), statusTone(st));
                ui.end();
                kit.text(ui, json.str(x, "description"), .{});
                var line: std.ArrayList(u8) = .empty;
                line.appendSlice(a, ui.tf(labels.english("claims.asked") orelse "{amount}", .{ .amount = fmt.money(a, json.num(x, "amount"), cur) })) catch {};
                if (json.has(x, "compensation")) {
                    line.appendSlice(a, " · ") catch {};
                    line.appendSlice(a, ui.tf(labels.english("claims.agreed") orelse "{amount}", .{ .amount = fmt.money(a, json.num(x, "compensation"), cur) })) catch {};
                }
                line.appendSlice(a, " · ") catch {};
                line.appendSlice(a, fmt.date(a, json.str(x, "createdAt"))) catch {};
                kit.small(ui, line.items);
                if (json.str(x, "response").len > 0) kit.notice(ui, .info, json.str(x, "response"));
                const open = std.mem.eql(u8, st, "open");
                if (open and carrier and c.can("shipments.manage")) {
                    kit.rowEnd(ui);
                    kit.button(ui, L("claims.reject"), kit.act(A.reject, @intCast(i)), .{ .size = .sm, .variant = .ghost });
                    kit.button(ui, L("claims.accept"), kit.act(A.accept, @intCast(i)), .{ .size = .sm, .variant = .primary });
                    ui.end();
                }
                if (open and !carrier and c.can("shipments.create")) {
                    kit.rowEnd(ui);
                    kit.button(ui, L("claims.withdraw"), kit.act(A.withdraw_ask, @intCast(i)), .{ .size = .sm, .variant = .ghost, .busy = @intFromEnum(A.withdraw) });
                    ui.end();
                }
                kit.endCard(ui, .{});
            }
            ui.end();
        }
    }
    ui.end();
}

/// Accept or reject a claim.
pub fn overlay(s: *const S, c: *const Cx, ui: *Ui) void {
    const i = s.deciding orelse return;
    const list = shown(s, c, ui.arena());
    if (i >= list.len) return;
    const x = list[i];
    const close = kit.act(A.decide_close, 0);
    const submit = kit.act(A.decide, 0);
    shell.modalBegin(ui, .{ .title = L(if (s.accept) "claims.accept_title" else "claims.reject_title"), .close = close, .key = zui.key("decide") });
    if (s.accept) kit.field(ui, kit.f(ui, "{s} ({s})", .{ L("claims.compensation"), json.str(x, "currency") }), f_amount, .{ .hint = L("claims.compensation_hint"), .input = .{ .kind = .number, .ltr = true, .name = "amount", .on_submit = submit } });
    kit.field(ui, L(if (s.accept) "claims.note" else "claims.reason"), f_response, .{ .required = !s.accept, .input = .{ .kind = .multiline, .placeholder = L(if (s.accept) "claims.accept_note" else "claims.reject_reason"), .name = "response" } });
    shell.modalFoot(ui);
    shell.modalButton(ui, L("common.cancel"), close, .{});
    shell.modalButton(ui, L(if (s.accept) "claims.accept" else "claims.reject"), submit, .{ .variant = if (s.accept) .primary else .danger, .busy = @intFromEnum(A.decide) });
    shell.modalEnd(ui, true);
}

// ---- Tests ------------------------------------------------------------------------------------

const app = @import("../app.zig");
const testing = std.testing;
const m_new = @import("m_new.zig");
const claim_dialog = @import("../widgets/claim_dialog.zig");

const claims_json =
    \\[{"id":"k1","shipmentId":"s1","trackingNumber":"TRF-1","type":"lost","status":"open","amount":5000,"currency":"SYP","description":"Never came","merchantName":"Acme Store","carrierName":"Fast Express","createdAt":"2025-10-12T11:00:00.000Z"},
    \\ {"id":"k2","shipmentId":"s2","trackingNumber":"TRF-2","type":"late","status":"rejected","amount":100,"currency":"SYP","description":"Slow","response":"On time","createdAt":"2025-10-12T11:00:00.000Z"}]
;

const carrier_org =
    \\{"id":"o2","type":"carrier","name":"Fast Express","slug":"fast","status":"active","branding":{},
    \\ "me":{"permissions":["shipments.view","shipments.manage"],"isOwner":false}}
;

test "claims: a store withdraws an open claim" {
    try app.startSignedIn("/o/acme/claims");
    defer app.D.reset();
    try testing.expect(app.D.respond("/api/app/orgs/o1", 200, m_new.merchant_org));
    try testing.expect(app.D.respond("/merchant/claims", 200, claims_json));
    try testing.expect(app.D.findText("Never came") != 0);
    try testing.expect(app.D.findText("Slow") == 0);
    try app.D.press(L("claims.withdraw"));
    try app.D.press(L("common.confirm"));
    try testing.expect(app.D.respond("/merchant/claims/k1/withdraw", 200, "{}"));
    try testing.expect(app.D.pending("/merchant/claims") != null);
    try app.D.press(L("common.all"));
}

test "claims: a carrier accepts with an amount" {
    try app.startSignedIn("/o/fast/claims");
    defer app.D.reset();
    try testing.expect(app.D.respond("/api/app/orgs/o2", 200, carrier_org));
    try testing.expect(app.D.respond("/carrier/claims", 200, claims_json));
    try testing.expect(app.D.findText("Acme Store") != 0);
    try app.D.press(L("claims.accept"));
    try app.D.typeInto(L("claims.accept_note"), "Sorry");
    // The dialog's button (the card behind has the same label).
    app.D.R.dispatch(kit.act(A.decide, 0));
    const b = m_new.lastFetch("/carrier/claims/k1/decide").?;
    try testing.expect(m_new.has(b.body, "{\"decision\":\"accepted\",\"amount\":5000,\"response\":\"Sorry\"}"));
}

test "the claim dialog opens a claim for a delivered shipment" {
    try app.startSignedIn("/o/acme/claims");
    defer app.D.reset();
    try testing.expect(app.D.respond("/api/app/orgs/o1", 200, m_new.merchant_org));
    var d: claim_dialog.Dialog = .{};
    d.setup(.{});
    const c: *Cx = @constCast(app.D.R.appState());
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    d.open(c, json.parse(arena.allocator(), "{\"id\":\"s1\",\"status\":\"delivered\",\"price\":{\"currency\":\"SYP\"},\"parcel\":{\"value\":700}}"));
    try testing.expectEqualStrings("damaged", c.val(400));
    try testing.expectEqualStrings("700", c.val(401));
    _ = d.update(c, .{ .act = .{ .id = 401 } });
    const b = m_new.lastFetch("/merchant/shipments/s1/claims").?;
    try testing.expect(m_new.has(b.body, "\"type\":\"damaged\",\"amount\":700"));
}
