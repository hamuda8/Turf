//! "Send a parcel" (Turf-js views/direct/send.js): a person (not a company) asks shipping
//! companies to carry a parcel. Only reachable when direct shipping is switched on in Control.

const std = @import("std");
const zui = @import("zui");
const core = @import("../core.zig");
const kit = @import("../kit.zig");
const json = @import("../json.zig");
const fmt = @import("../fmt.zig");
const icons = @import("../icons.zig");
const labels = @import("../labels.zig");
const address = @import("../widgets/address.zig");
const m_new = @import("m_new.zig");

const Cx = core.Cx;
const Ui = core.Ui;
const V = json.V;
const L = labels.k;

/// The sender's own address, remembered for next time (on this device only).
const last_pickup = "turf.direct.pickup";

const d_quotes: u8 = 0;

const f_weight: u16 = 1;
const f_desc: u16 = 2;
const f_len: u16 = 3;
const f_wid: u16 = 4;
const f_hei: u16 = 5;
const f_cod: u16 = 6;
const f_notes: u16 = 7;

const A = enum(u16) { toggle_fragile = 1, compare, send, pick };

const Prices = enum { none, list, stale };

pub const S = struct {
    pickup: address.Address = .{},
    dropoff: address.Address = .{},
    fragile: bool = false,
    /// "auto" or a company id.
    chosen: []const u8 = "auto",
    prices: Prices = .none,
    quoted_key: ?[]const u8 = null,
    asking_key: []const u8 = "",
};

pub fn title(_: *const S, _: *const Cx) []const u8 {
    return L("direct.send_title");
}

pub fn enter(s: *S, c: *Cx) void {
    s.pickup.setup(c, .{ .prefix = "pickup", .slot = 100, .act = 300, .timer = 300, .tag = 1, .require_phone = true, .kind = "home" });
    s.dropoff.setup(c, .{ .prefix = "dropoff", .slot = 120, .act = 320, .timer = 320, .tag = 2, .require_phone = true });
    if (zui.storage.get(core.gpa, last_pickup, .{})) |saved| {
        defer core.gpa.free(saved);
        if (json.parse(c.arena(), c.dupe(saved))) |v| if (v == .object) s.pickup.setValue(c, v);
    }
    c.setVal(f_weight, "1");
}

fn body(s: *const S, c: *Cx, carrier: []const u8) []const u8 {
    var b = json.Obj.init(c.arena());
    b.begin("pickup");
    s.pickup.write(c, &b);
    b.end();
    b.begin("dropoff");
    s.dropoff.write(c, &b);
    b.end();
    b.begin("parcel");
    address.numField(&b, "weightKg", c.val(f_weight));
    b.strOpt("description", c.val(f_desc));
    b.begin("dimensionsCm");
    address.numField(&b, "length", c.val(f_len));
    address.numField(&b, "width", c.val(f_wid));
    address.numField(&b, "height", c.val(f_hei));
    b.end();
    b.boolean("fragile", s.fragile);
    b.end();
    const cod = c.valTrim(f_cod);
    if (cod.len > 0 and (std.fmt.parseFloat(f64, cod) catch 1) != 0) {
        b.begin("cod");
        address.numField(&b, "amount", cod);
        b.end();
    }
    b.strOpt("notes", c.val(f_notes));
    b.str("carrier", carrier);
    b.boolean("requireDeliveryCode", true);
    return b.done();
}

/// Prices are for the addresses and the parcel they were asked for.
fn quoteKey(s: *const S, c: *Cx) []const u8 {
    const a = c.arena();
    return c.print("{s}|{s}|{s}|{s}|{s},{s},{s}|{d}|{s}", .{
        s.pickup.whereKey(c, a), s.dropoff.whereKey(c, a), c.valTrim(f_weight), c.valTrim(f_desc),
        c.valTrim(f_len),        c.valTrim(f_wid),         c.valTrim(f_hei),    @intFromBool(s.fragile),
        c.valTrim(f_cod),
    });
}

fn markStale(s: *S, c: *Cx) void {
    const q = s.quoted_key orelse return;
    if (std.mem.eql(u8, quoteKey(s, c), q)) return;
    s.quoted_key = null;
    s.chosen = "auto";
    s.prices = .stale;
}

fn options(c: *const Cx) []const V {
    return json.arr(c.data(d_quotes), "options");
}

pub fn update(s: *S, c: *Cx, e: core.Ev) void {
    handle(s, c, e);
    if (e != .frame) markStale(s, c);
}

fn handle(s: *S, c: *Cx, e: core.Ev) void {
    if (s.pickup.update(c, e)) return;
    if (s.dropoff.update(c, e)) return;
    switch (e) {
        .act => |a| switch (@as(A, @enumFromInt(a.id))) {
            .toggle_fragile => s.fragile = !s.fragile,
            .compare => {
                s.chosen = "auto";
                s.asking_key = quoteKey(s, c);
                c.send(@intFromEnum(A.compare), .POST, c.appUrl("/direct/quotes"), body(s, c, "auto"));
            },
            .pick => {
                const opts = options(c);
                s.chosen = if (a.arg == 0 or a.arg > opts.len) "auto" else c.dupe(json.str(opts[a.arg - 1], "carrier.id"));
            },
            .send => c.send(@intFromEnum(A.send), .POST, c.appUrl("/direct/shipments"), body(s, c, s.chosen)),
        },
        .done => |d| switch (@as(A, @enumFromInt(d.id))) {
            .compare => if (d.ok) {
                const slot = &c.slots[d_quotes];
                slot.reset();
                slot.value = json.parse(slot.arena.allocator(), d.body);
                slot.state = .ok;
                s.prices = .list;
                s.quoted_key = c.dupe(s.asking_key);
            },
            .send => if (d.ok) {
                var b = json.Obj.init(c.arena());
                s.pickup.write(c, &b);
                if (s.pickup.location() == null) b.nul("location");
                zui.storage.set(last_pickup, b.done(), .{});
                c.toast(L("direct.sent"), .ok);
                c.go(c.print("/parcels/{s}", .{json.str(d.v, "id")}));
            },
            else => {},
        },
        else => {},
    }
}

pub fn view(s: *const S, c: *const Cx, ui: *Ui) void {
    const outer = kit.width;
    kit.width = @min(outer, 960);
    defer kit.width = outer;
    ui.begin(.{ .gap = 16, .width = .{ .px = kit.width } }, .{});
    kit.notice(ui, .info, L("direct.intro"));
    var w = m_new.cardBegin(ui, 16);
    s.pickup.view(c, ui, L("direct.from"));
    m_new.cardEnd(ui, w);
    w = m_new.cardBegin(ui, 16);
    s.dropoff.view(c, ui, L("direct.to"));
    m_new.cardEnd(ui, w);

    w = m_new.cardBegin(ui, 16);
    kit.h2(ui, L("shipment.parcel"));
    var g = kit.formGrid(ui, 2);
    g.cell();
    kit.field(ui, L("new.weight"), f_weight, .{ .required = true, .input = .{ .kind = .decimal, .ltr = true, .name = "parcel.weightKg" } });
    g.endCell();
    g.cell();
    kit.field(ui, L("new.description"), f_desc, .{ .input = .{ .placeholder = L("direct.description_placeholder"), .name = "parcel.description" } });
    g.endCell();
    g.end();
    m_new.dims(ui, f_len, f_wid, f_hei);
    var g2 = kit.formGrid(ui, 2);
    g2.cell();
    kit.field(ui, L("direct.cod"), f_cod, .{ .hint = L("direct.cod_hint"), .input = .{ .kind = .number, .ltr = true, .name = "cod.amount" } });
    g2.endCell();
    g2.cell();
    kit.field(ui, L("new.notes"), f_notes, .{ .hint = L("direct.notes_hint"), .input = .{ .name = "notes" } });
    g2.endCell();
    g2.end();
    kit.check(ui, L("shipment.fragile"), s.fragile, kit.act(A.toggle_fragile, 0));
    m_new.cardEnd(ui, w);

    w = m_new.cardBegin(ui, 16);
    kit.h2(ui, L("direct.companies"));
    kit.row(ui);
    kit.button(ui, L("direct.see_prices"), kit.act(A.compare, 0), .{ .variant = .primary, .icon = icons.list, .busy = @intFromEnum(A.compare) });
    ui.end();
    const ready = priceList(s, c, ui);
    m_new.cardEnd(ui, w);

    if (ready) {
        kit.rowEnd(ui);
        kit.button(ui, L("direct.send"), kit.act(A.send, 0), .{ .variant = .primary, .size = .lg, .icon = icons.check, .busy = @intFromEnum(A.send) });
        ui.end();
    }
    ui.end();
}

/// The companies and their prices; true when one can be sent to.
fn priceList(s: *const S, c: *const Cx, ui: *Ui) bool {
    switch (s.prices) {
        .none => return false,
        .stale => {
            kit.notice(ui, .info, L("direct.prices_stale"));
            return false;
        },
        .list => {},
    }
    const opts = options(c);
    if (opts.len == 0) {
        kit.empty(ui, L("direct.no_companies"));
        return false;
    }
    const a = ui.arena();
    var lo: f64 = std.math.inf(f64);
    var hi: f64 = -std.math.inf(f64);
    for (opts) |o| {
        const p = json.numOr(o, "price.amount", 0);
        lo = @min(lo, p);
        hi = @max(hi, p);
    }
    const currency = json.str(opts[0], "price.currency");
    const range = if (lo == hi) fmt.money(a, lo, currency) else kit.f(ui, "{s} – {s}", .{ fmt.money(a, lo, currency), fmt.money(a, hi, currency) });
    ui.begin(.{ .gap = 8.8 }, .{});
    optionRow(ui, 0, std.mem.eql(u8, s.chosen, "auto"), L("direct.first_available"), ui.tf(labels.english("direct.first_available_hint") orelse "{n}", .{ .n = opts.len }), range);
    for (opts, 0..) |o, i| {
        const on = std.mem.eql(u8, s.chosen, json.str(o, "carrier.id"));
        optionRow(ui, @intCast(i + 1), on, json.str(o, "carrier.name"), ui.tf(labels.english("new.eta") orelse "{time}", .{ .time = fmt.duration(a, json.numOr(o, "etaHours", 0) * 60) }), fmt.money(a, json.num(o, "price.amount"), json.str(o, "price.currency")));
    }
    kit.small(ui, L("direct.pay_note"));
    ui.end();
    return true;
}

fn optionRow(ui: *Ui, i: u32, on: bool, name: []const u8, sub: []const u8, price: []const u8) void {
    const k = kit.k;
    kit.card(ui, .{ .pad = 12, .inner = true, .ring = if (on) k.a else null, .on_press = kit.act(A.pick, i), .key = zui.key(i + 1), .direction = .row, .align_items = .center, .gap = 12 });
    // A radio button.
    ui.begin(.{ .width = .{ .px = 20 }, .height = .{ .px = 20 }, .radius = 10, .border_width = if (on) 6 else 1.5, .border_color = if (on) k.a else k.ink_3, .background = k.panel }, .{});
    ui.end();
    ui.begin(.{ .grow = 1, .gap = 2 }, .{});
    kit.strong(ui, name);
    kit.small(ui, sub);
    ui.end();
    ui.text(price, .{ .font_size = 18.4, .weight = 850, .color = k.ink, .max_lines = 1 });
    kit.endCard(ui, .{});
}

// ---- Tests ------------------------------------------------------------------------------------

const app = @import("../app.zig");
const testing = std.testing;

const meta_direct =
    \\{"governorates":[{"code":"DAM","en":"Damascus","ar":"دمشق","center":{"lat":33.51,"lng":36.29}}],
    \\ "vehicles":["motorbike","car"],"permissions":{},"statuses":{"awaiting_pickup":{},"delivered":{}},
    \\ "failureReasons":[],"strategies":["balanced"],"taskTypes":["pickup","delivery"],"platform":{"features":{"directShipping":true}}}
;

pub fn startDirect(link: []const u8) !void {
    app.D.startWith(390, 800, link);
    try testing.expect(app.D.respond("/api/app/me", 200, app.me_json));
    try testing.expect(app.D.respond("/api/app/meta", 200, meta_direct));
}

test "send a parcel: prices, a company, send; the pickup is remembered" {
    zui.storage.remove(last_pickup, .{});
    try startDirect("/app/send");
    defer app.D.reset();
    try app.D.press(L("direct.see_prices"));
    try testing.expect(app.D.respond("/direct/quotes", 200,
        \\{"options":[{"carrier":{"id":"c1","name":"Fast Express"},"etaHours":5,"price":{"amount":3000,"currency":"SYP"}},{"carrier":{"id":"c2","name":"Slow Co"},"etaHours":24,"price":{"amount":2000,"currency":"SYP"}}]}
    ));
    try testing.expect(app.D.findText("2,000 SYP – 3,000 SYP") != 0);
    try app.D.press("Slow Co");
    try app.D.press(L("direct.send"));
    const b = m_new.lastFetch("/direct/shipments").?;
    try testing.expect(m_new.has(b.body, "\"carrier\":\"c2\""));
    try testing.expect(m_new.has(b.body, "\"requireDeliveryCode\":true"));
    try testing.expect(app.D.respond("/direct/shipments", 201, "{\"id\":\"d1\"}"));
    try testing.expect(m_new.has(zui.host.link.items, "/app/parcels/d1"));
    try testing.expect(zui.host.stored.get(last_pickup) != null);
}

test "send a parcel: a changed weight makes the prices stale" {
    zui.storage.remove(last_pickup, .{});
    try startDirect("/app/send");
    defer app.D.reset();
    try app.D.press(L("direct.see_prices"));
    try testing.expect(app.D.respond("/direct/quotes", 200, "{\"options\":[]}"));
    try testing.expect(app.D.findText(L("direct.no_companies")) != 0);
    try app.D.typeInto(L("new.length"), "30");
    try testing.expect(app.D.findText(L("direct.prices_stale")) != 0);
}
