//! Cash on delivery for a carrier (Turf-js views/carrier/finance.js): cash held by couriers ->
//! received by the company -> paid to the stores; then the statements with each store and
//! Turf's fees.

const std = @import("std");
const zui = @import("zui");
const core = @import("../core.zig");
const kit = @import("../kit.zig");
const json = @import("../json.zig");
const fmt = @import("../fmt.zig");
const labels = @import("../labels.zig");
const statements = @import("../widgets/statements.zig");

const Cx = core.Cx;
const Ui = core.Ui;
const V = json.V;
const L = labels.k;

const d_cod: u8 = 0;
const d_list: u8 = 1;
const d_statement: u8 = 2;
const d_fees: u8 = 3;

/// `settle_ask + i` asks about courier i, `settle + i` sends it (the same for remit).
const A = enum(u16) { csv = 1, settle_ask, remit_ask, settle, remit };

pub const S = struct {
    st: statements.Statements = .{ .side = .carrier, .d_list = d_list, .d_statement = d_statement, .d_fees = d_fees, .f_who = 0, .f_from = 1, .f_to = 2, .f_month = 3, .act_csv = @intFromEnum(A.csv) },
};

pub fn title(_: *const S, _: *const Cx) []const u8 {
    return L("nav.finance");
}

pub fn enter(s: *S, c: *Cx) void {
    c.load(d_cod, c.orgUrl("/carrier/finance/cod"));
    s.st.enter(c);
}

fn currency(c: *const Cx) []const u8 {
    return json.strOr(c.orgV(), "carrier.currency", "SYP");
}

fn entry(c: *const Cx, list: []const u8, i: u32) ?V {
    const l = json.arr(c.data(d_cod), list);
    return if (i < l.len) l[i] else null;
}

pub fn update(s: *S, c: *Cx, e: core.Ev) void {
    if (s.st.update(c, e)) return;
    switch (e) {
        .act => |a| switch (@as(A, @enumFromInt(a.id))) {
            .settle_ask, .remit_ask => {
                const settle = a.id == @intFromEnum(A.settle_ask);
                const x = entry(c, if (settle) "toSettle" else "toRemit", a.arg) orelse return;
                const q = zui.i18n.tf(c.arena(), labels.english(if (settle) "finance.settle_confirm" else "finance.remit_confirm") orelse "{name} {amount}", .{
                    .name = json.str(x, if (settle) "courierName" else "merchantName"),
                    .amount = fmt.money(c.arena(), json.num(x, "amount"), currency(c)),
                });
                c.ask(q, .{ .act = .{ .id = @intFromEnum(if (settle) A.settle else A.remit), .arg = a.arg } });
            },
            .settle, .remit => {
                const settle = a.id == @intFromEnum(A.settle);
                const x = entry(c, if (settle) "toSettle" else "toRemit", a.arg) orelse return;
                var b = json.Obj.init(c.arena());
                if (json.get(x, "ids")) |ids| b.value("shipmentIds", ids) else b.raw("shipmentIds", "[]");
                c.sendArg(a.id, a.arg, .POST, c.orgUrl(if (settle) "/carrier/finance/cod/settle" else "/carrier/finance/cod/remit"), b.done());
            },
            .csv => {},
        },
        .done => |d| if (d.ok and (d.id == @intFromEnum(A.settle) or d.id == @intFromEnum(A.remit))) {
            c.toast(L("common.saved"), .ok);
            c.load(d_cod, c.orgUrl("/carrier/finance/cod"));
        },
        else => {},
    }
}

fn table(c: *const Cx, ui: *Ui, rows: []const V, first: []const u8, name_key: []const u8, action: []const u8, ask: A, busy: A) void {
    const a = ui.arena();
    const manage = c.can("finance.manage");
    var tb = kit.Table.begin(ui, &.{
        .{ .label = first, .grow = 1.4 },
        .{ .label = L("finance.parcels") },
        .{ .label = L("finance.amount") },
        .{ .label = "", .width = 150 },
    });
    for (rows, 0..) |r, i| {
        tb.row(null, zui.key(i + 1));
        tb.cell(false);
        kit.strong(ui, json.str(r, name_key));
        tb.endCell();
        tb.cell(true);
        kit.text(ui, fmt.number(a, json.numOr(r, "count", 0), 0), .{});
        tb.endCell();
        tb.cell(true);
        kit.strong(ui, fmt.money(a, json.num(r, "amount"), currency(c)));
        tb.endCell();
        tb.cell(false);
        if (manage) kit.button(ui, action, kit.act(ask, @intCast(i)), .{ .size = .sm, .variant = .primary, .busy = @intFromEnum(busy) });
        tb.endCell();
        tb.endRow();
    }
    tb.end();
}

pub fn view(s: *const S, c: *const Cx, ui: *Ui) void {
    if (!kit.gate(ui, &.{d_cod})) return;
    const v = c.data(d_cod);
    kit.stack(ui);
    kit.muted(ui, L("finance.intro"));
    kit.h2(ui, L("finance.held_by_couriers"));
    const settle = json.arr(v, "toSettle");
    if (settle.len > 0) table(c, ui, settle, L("finance.courier"), "courierName", L("finance.mark_received"), .settle_ask, .settle) else kit.empty(ui, L("finance.nothing_to_settle"));
    kit.h2(ui, L("finance.owed_to_merchants"));
    const remit = json.arr(v, "toRemit");
    if (remit.len > 0) table(c, ui, remit, L("finance.merchant"), "merchantName", L("finance.mark_paid"), .remit_ask, .remit) else kit.empty(ui, L("finance.nothing_to_remit"));
    s.st.view(c, ui);
    s.st.feesView(c, ui);
    ui.end();
}

// ---- Tests --------------------------------------------------------------------------------

const testing = std.testing;
const app = @import("../app.zig");

test {
    _ = statements;
}

test "carrier finance: settle a courier's cash, statements, CSV" {
    app.D.startWith(1280, 900, "/o/fast/finance");
    defer app.D.reset();
    try testing.expect(app.D.respond("/api/app/me", 200, @import("c_dashboard.zig").carrier_me));
    try testing.expect(app.D.respond("/api/app/meta", 200, app.meta_json));
    try testing.expect(app.D.respond("/api/app/orgs/o2", 200,
        \\{"id":"o2","type":"carrier","name":"Fast Express","slug":"fast","status":"active","carrier":{"currency":"SYP"},
        \\ "me":{"permissions":["finance.view","finance.manage"]}}
    ));
    try testing.expect(app.D.respond("/carrier/finance/cod", 200,
        \\{"toSettle":[{"courierName":"Omar","count":2,"amount":30000,"ids":["s1","s2"]}],"toRemit":[]}
    ));
    try testing.expect(app.D.respond("/carrier/finance/statements?from=", 200, "{\"merchants\":[{\"id\":\"m1\",\"name\":\"Acme\",\"shipments\":4}]}"));
    try testing.expect(app.D.respond("/platform-fees?month=", 200, "{\"lines\":[{\"amount\":500,\"currency\":\"SYP\",\"shipments\":5,\"due\":500}]}"));
    try testing.expect(app.D.respond("/carrier/finance/statement?merchantId=m1", 200,
        \\{"currency":"SYP","totals":{"delivered":4,"returned":0,"shippingFees":20000,"codCollected":50000,"payout":30000},
        \\ "rows":[{"trackingNumber":"TRF1","status":"delivered","date":"2025-10-10T10:00:00.000Z","shippingFee":5000,"codCollected":12500,"net":7500,"paidOut":true}]}
    ));
    try testing.expect(app.D.findText("Omar") != 0);
    try testing.expect(app.D.findText("Nothing owed to stores.") != 0);
    try testing.expect(app.D.findText("You owe this store 30,000 SYP (cash collected minus shipping fees).") != 0);
    try testing.expect(app.D.findText("Due: 500 SYP") != 0);
    try testing.expect(app.D.findText("Paid out") != 0);
    try app.D.press("Mark received");
    try testing.expect(app.D.findText("Confirm you received 30,000 SYP from Omar?") != 0);
    try app.D.press("Confirm");
    const sent = zui.host.fetches.items[zui.host.fetches.items.len - 1];
    try testing.expectEqualStrings("{\"shipmentIds\":[\"s1\",\"s2\"]}", sent.body);
    try testing.expect(app.D.respond("/carrier/finance/cod/settle", 200, "{}"));
    try testing.expect(app.D.pending("/carrier/finance/cod") != null);
    // The CSV comes through the page bridge.
    try app.D.press("Download CSV");
    try testing.expect(app.D.respond("format=csv&lang=en", 200, "a,b\r\n"));
    try testing.expect(zui.host.saved_name.items.len > 0);
}
