//! New shipment (Turf-js views/merchant/new-shipment.js): pin the recipient on the map, a phone
//! number, the weight, and go. The pickup is one of the store's saved places (or a new pin).
//! Everything else is optional detail. Compare lists every route (single companies and chains)
//! and the store can pick one. Express (same-hour) lists only companies that offer it.

const std = @import("std");
const zui = @import("zui");
const core = @import("../core.zig");
const kit = @import("../kit.zig");
const json = @import("../json.zig");
const fmt = @import("../fmt.zig");
const icons = @import("../icons.zig");
const labels = @import("../labels.zig");
const address = @import("../widgets/address.zig");
const parts = @import("../widgets/parts.zig");

const Cx = core.Cx;
const Ui = core.Ui;
const V = json.V;
const L = labels.k;

const d_carriers: u8 = 0;
const d_quotes: u8 = 1;

const f_weight: u16 = 1;
const f_cod: u16 = 2;
const f_desc: u16 = 3;
const f_pieces: u16 = 4;
const f_value: u16 = 5;
const f_ref: u16 = 6;
const f_len: u16 = 7;
const f_wid: u16 = 8;
const f_hei: u16 = 9;
const f_notes: u16 = 10;
const f_label: u16 = 11;
const f_carrier: u16 = 12;
const f_strategy: u16 = 13;

const A = enum(u16) { choose_place = 1, toggle_save, service_standard, service_express, toggle_more, toggle_fragile, toggle_code, compare, create, choose_option, save_place };

const QuoteView = enum { none, list, stale, unavailable };

const Place = struct { id: []const u8, label: []const u8, is_default: bool };

pub const S = struct {
    dropoff: address.Address = .{},
    pickup: address.Address = .{},
    /// The saved place to collect from; null: another pin (the pickup form).
    pickup_place: ?[]const u8 = null,
    pickup_touched: bool = false,
    /// Places saved from this page (until the company is reloaded).
    extra: std.ArrayList(Place) = .empty,
    save_place: bool = false,
    express: bool = false,
    more: bool = false,
    fragile: bool = false,
    require_code: bool = true,
    /// A chained route chosen from the quotes.
    chosen_option: ?[]const u8 = null,
    chosen_note: []const u8 = "",
    quotes: QuoteView = .none,
    quoted_key: ?[]const u8 = null,
    /// The key the open quote request was made for.
    asking_key: []const u8 = "",
};

pub fn title(_: *const S, _: *const Cx) []const u8 {
    return L("nav.new_shipment");
}

pub fn enter(s: *S, c: *Cx) void {
    s.dropoff.setup(c, .{ .prefix = "dropoff", .slot = 100, .act = 300, .timer = 300, .tag = 1, .require_phone = true });
    s.pickup.setup(c, .{ .prefix = "pickup", .slot = 120, .act = 320, .timer = 320, .tag = 2, .require_phone = false, .kind = "shop" });
    c.setVal(f_weight, "1");
    c.setVal(f_pieces, "1");
    c.setVal(f_carrier, "auto");
    c.setVal(f_strategy, json.strOr(c.orgV(), "merchant.defaultStrategy", "balanced"));
    pickDefaultPlace(s, c);
    s.save_place = places(s, c, c.arena()).len == 0;
    @import("../app.zig").reloadOrg(c);
    c.load(d_carriers, c.orgUrl("/merchant/carriers"));
}

fn pickDefaultPlace(s: *S, c: *Cx) void {
    const list = places(s, c, c.arena());
    s.pickup_place = null;
    for (list) |p| if (p.is_default) {
        s.pickup_place = c.dupe(p.id);
        return;
    };
    if (list.len > 0) s.pickup_place = c.dupe(list[0].id);
}

/// The company's pickup places, and those saved here since.
fn places(s: *const S, c: *const Cx, al: std.mem.Allocator) []const Place {
    var out: std.ArrayList(Place) = .empty;
    for (json.arr(c.orgV(), "merchant.places")) |p| out.append(al, .{ .id = json.str(p, "id"), .label = json.str(p, "label"), .is_default = json.boolean(p, "isDefault") }) catch {};
    for (s.extra.items) |x| {
        const dup = for (out.items) |o| {
            if (std.mem.eql(u8, o.id, x.id)) break true;
        } else false;
        if (!dup) out.append(al, x) catch {};
    }
    return out.items;
}

fn carriers(c: *const Cx) []const V {
    return json.arr(c.data(d_carriers), "");
}

fn anyExpress(c: *const Cx) bool {
    for (carriers(c)) |x| if (json.has(x, "express")) return true;
    return false;
}

/// Express lists only the companies that offer it; a company chosen before stays if it can.
fn fillCarriers(s: *S, c: *Cx) void {
    const keep = c.val(f_carrier);
    var ok = std.mem.eql(u8, keep, "auto");
    for (carriers(c)) |x| if ((!s.express or json.has(x, "express")) and std.mem.eql(u8, json.str(x, "id"), keep)) {
        ok = true;
    };
    if (!ok) c.setVal(f_carrier, "auto");
}

fn clearChoice(s: *S) void {
    s.chosen_option = null;
    s.chosen_note = "";
}

fn isAuto(c: *const Cx) bool {
    return std.mem.eql(u8, c.val(f_carrier), "auto");
}

/// What the prices depend on: the pins, the places and the parcel (not names or notes).
fn quoteKey(s: *const S, c: *Cx) []const u8 {
    const a = c.arena();
    const pick = if (s.pickup_place) |id| id else s.pickup.whereKey(c, a);
    return c.print("{s}|{s}|{s}|{s}|{s}|{s}|{s},{s},{s}|{d}|{d}|{d}", .{
        s.dropoff.whereKey(c, a),  pick,              c.valTrim(f_weight), c.valTrim(f_pieces),       c.valTrim(f_value),            c.valTrim(f_cod),
        c.valTrim(f_len),          c.valTrim(f_wid),  c.valTrim(f_hei),    @intFromBool(s.fragile), @intFromBool(s.require_code), @intFromBool(s.express),
    });
}

fn markStale(s: *S, c: *Cx) void {
    const q = s.quoted_key orelse return;
    if (std.mem.eql(u8, quoteKey(s, c), q)) return;
    s.quoted_key = null;
    clearChoice(s);
    s.quotes = .stale;
}

/// The request body (the pickup is a place id, or the pickup form).
fn body(s: *const S, c: *Cx) []const u8 {
    var b = json.Obj.init(c.arena());
    b.begin("dropoff");
    s.dropoff.write(c, &b);
    b.end();
    if (s.pickup_place) |id| b.str("pickup", id) else {
        b.begin("pickup");
        s.pickup.write(c, &b);
        b.end();
    }
    b.begin("parcel");
    address.numField(&b, "weightKg", c.val(f_weight));
    b.strOpt("description", c.val(f_desc));
    address.numField(&b, "pieces", c.val(f_pieces));
    address.numField(&b, "value", c.val(f_value));
    b.begin("dimensionsCm");
    address.numField(&b, "length", c.val(f_len));
    address.numField(&b, "width", c.val(f_wid));
    address.numField(&b, "height", c.val(f_hei));
    b.end();
    b.boolean("fragile", s.fragile);
    b.end();
    // No amount (or 0): no cash on delivery.
    const cod = c.valTrim(f_cod);
    if (cod.len > 0 and (std.fmt.parseFloat(f64, cod) catch 1) != 0) {
        b.begin("cod");
        address.numField(&b, "amount", cod);
        b.end();
    }
    b.strOpt("reference", c.val(f_ref));
    b.strOpt("notes", c.val(f_notes));
    b.boolean("requireDeliveryCode", s.require_code);
    b.str("service", if (s.express) "express" else "standard");
    b.str("carrier", c.val(f_carrier));
    if (isAuto(c)) b.strOpt("strategy", c.val(f_strategy));
    if (s.chosen_option) |o| if (isAuto(c)) b.str("option", o);
    return b.done();
}

fn quoteOptions(c: *const Cx) []const V {
    return json.arr(c.data(d_quotes), "options");
}

fn create(s: *S, c: *Cx) void {
    c.quietErrors(@intFromEnum(A.create));
    c.send(@intFromEnum(A.create), .POST, c.orgUrl("/merchant/shipments"), body(s, c));
}

pub fn update(s: *S, c: *Cx, e: core.Ev) void {
    if (e != .frame and e != .map) {
        defer markStale(s, c);
        return handle(s, c, e);
    }
    handle(s, c, e);
    // A pin moved on a map changes the prices too.
    if (e == .map) markStale(s, c);
}

fn handle(s: *S, c: *Cx, e: core.Ev) void {
    if (s.dropoff.update(c, e)) return;
    if (s.pickup.update(c, e)) return;
    switch (e) {
        .data => |n| if (n == 255 and !s.pickup_touched) pickDefaultPlace(s, c),
        .text => |x| switch (x.slot) {
            f_carrier, f_strategy => clearChoice(s),
            else => {},
        },
        .act => |a| switch (@as(A, @enumFromInt(a.id))) {
            .choose_place => {
                const list = places(s, c, c.arena());
                s.pickup_touched = true;
                s.pickup_place = if (a.arg < list.len) c.dupe(list[a.arg].id) else null;
            },
            .toggle_save => s.save_place = !s.save_place,
            .service_standard, .service_express => {
                s.express = @as(A, @enumFromInt(a.id)) == .service_express;
                fillCarriers(s, c);
                clearChoice(s);
            },
            .toggle_more => s.more = !s.more,
            .toggle_fragile => s.fragile = !s.fragile,
            .toggle_code => s.require_code = !s.require_code,
            .compare => {
                s.asking_key = quoteKey(s, c);
                c.send(@intFromEnum(A.compare), .POST, c.orgUrl("/merchant/quotes"), body(s, c));
            },
            .choose_option => {
                const opts = quoteOptions(c);
                if (a.arg >= opts.len) return;
                const o = opts[a.arg];
                if (json.boolean(o, "chain")) {
                    c.setVal(f_carrier, "auto");
                    s.chosen_option = c.dupe(json.str(o, "id"));
                    var names: std.ArrayList(u8) = .empty;
                    for (json.arr(o, "legs"), 0..) |l, i| {
                        if (i > 0) names.appendSlice(c.arena(), " / ") catch {};
                        names.appendSlice(c.arena(), json.str(l, "carrier.name")) catch {};
                    }
                    s.chosen_note = zui.i18n.tf(c.arena(), labels.english("new.route_chosen") orelse "{route}", .{ .route = names.items });
                } else {
                    c.setVal(f_carrier, json.str(o, "carrier.id"));
                    clearChoice(s);
                }
                c.toast(zui.i18n.tf(c.arena(), labels.english("new.carrier_chosen") orelse "{name}", .{ .name = json.str(o, "carrier.name") }), .ok);
            },
            .create => {
                if (c.isBusy(@intFromEnum(A.create))) return;
                if (s.pickup_place == null and s.save_place) {
                    // Saves the pickup as a place first.
                    var b = json.Obj.init(c.arena());
                    s.pickup.write(c, &b);
                    b.strOpt("label", c.val(f_label));
                    c.busy.put(core.gpa, @intFromEnum(A.create), {}) catch {};
                    c.send(@intFromEnum(A.save_place), .POST, c.orgUrl("/merchant/places"), b.done());
                } else create(s, c);
            },
            .save_place => {},
        },
        .done => |d| switch (@as(A, @enumFromInt(d.id))) {
            .save_place => {
                if (!d.ok) {
                    _ = c.busy.remove(@intFromEnum(A.create));
                    // The place is checked as "place.*"; the error belongs to the pickup form.
                    if (c.field_err) |*fe| if (std.mem.startsWith(u8, fe.field, "place.")) {
                        const moved = std.fmt.allocPrint(core.gpa, "pickup.{s}", .{fe.field[6..]}) catch return;
                        core.gpa.free(fe.field);
                        fe.field = moved;
                    };
                    return;
                }
                const id = c.dupe(json.str(d.v, "id"));
                s.extra.append(c.arena(), .{ .id = id, .label = c.dupe(json.str(d.v, "label")), .is_default = json.boolean(d.v, "isDefault") }) catch {};
                s.pickup_place = id;
                s.pickup_touched = true;
                create(s, c);
            },
            .compare => if (d.ok) {
                clearChoice(s);
                const slot = &c.slots[d_quotes];
                slot.reset();
                slot.value = json.parse(slot.arena.allocator(), d.body);
                slot.state = .ok;
                s.quotes = .list;
                s.quoted_key = c.dupe(s.asking_key);
            },
            .create => {
                if (d.ok) {
                    c.toast(zui.i18n.tf(c.arena(), labels.english("new.created") orelse "{tn}", .{ .tn = json.str(d.v, "trackingNumber"), .carrier = json.str(d.v, "carrier.name") }), .ok);
                    c.go(c.print("/shipments/{s}", .{json.str(d.v, "id")}));
                    return;
                }
                if (std.mem.eql(u8, json.str(d.v, "error.code"), "option_unavailable")) {
                    // The chosen route went away: ask for fresh prices.
                    s.quoted_key = null;
                    clearChoice(s);
                    s.quotes = .unavailable;
                    return;
                }
                c.toast(c.errorText(d.status, d.v), .err);
            },
            else => {},
        },
        else => {},
    }
}

// ---- View -------------------------------------------------------------------------------------

/// A card whose content is narrower by its padding (grids and maps inside size to it).
pub fn cardBegin(ui: *Ui, gap: f32) f32 {
    kit.card(ui, .{ .gap = gap });
    const w = kit.width;
    kit.width = w - 40;
    return w;
}

pub fn cardEnd(ui: *Ui, w: f32) void {
    kit.width = w;
    kit.endCard(ui, .{});
}

pub fn view(s: *const S, c: *const Cx, ui: *Ui) void {
    if (!kit.gate(ui, &.{d_carriers})) return;
    const outer = kit.width;
    kit.width = @min(outer, 960);
    defer kit.width = outer;
    ui.begin(.{ .gap = 16, .width = .{ .px = kit.width } }, .{});
    if (carriers(c).len == 0) kit.notice(ui, .warn, L("new.no_carriers_at_all"));

    // Recipient.
    var w = cardBegin(ui, 16);
    s.dropoff.view(c, ui, L("new.deliver_to"));
    cardEnd(ui, w);

    // Pickup: a saved place, or another pin.
    w = cardBegin(ui, 8.8);
    kit.h2(ui, L("new.pickup_from"));
    const list = places(s, c, ui.arena());
    if (list.len > 0) {
        var wr = kit.Wrap.begin(ui, kit.width, 6.4);
        for (list, 0..) |p, i| {
            wr.item(kit.estimate(p.label, 13.4) + 30 + @as(f32, if (p.is_default) 20 else 0));
            const on = if (s.pickup_place) |id| std.mem.eql(u8, id, p.id) else false;
            kit.chipIcon(ui, p.label, on, kit.act(A.choose_place, @intCast(i)), if (p.is_default) icons.star_fill else null);
        }
        wr.item(kit.estimate(L("new.another_place"), 13.4) + 50);
        kit.chipIcon(ui, L("new.another_place"), s.pickup_place == null, kit.act(A.choose_place, @intCast(list.len)), icons.add);
        wr.end();
    } else kit.small(ui, L("new.first_place_hint"));
    if (s.pickup_place == null) {
        ui.begin(.{ .gap = 8.8 }, .{});
        s.pickup.view(c, ui, "");
        ui.begin(.{ .direction = .row, .gap = 12, .align_items = .center }, .{});
        kit.check(ui, L("new.save_place"), s.save_place, kit.act(A.toggle_save, 0));
        kit.input(ui, f_label, .{ .placeholder = L("places.label_placeholder"), .grow = 1 });
        ui.end();
        ui.end();
    }
    cardEnd(ui, w);

    // The parcel.
    w = cardBegin(ui, 16);
    kit.h2(ui, L("shipment.parcel"));
    var g = kit.formGrid(ui, 3);
    g.cell();
    kit.field(ui, L("new.weight"), f_weight, .{ .required = true, .input = .{ .kind = .decimal, .ltr = true, .name = "parcel.weightKg" } });
    g.endCell();
    g.cell();
    kit.field(ui, L("new.cod"), f_cod, .{ .hint = L("new.cod_hint"), .input = .{ .kind = .number, .ltr = true, .name = "cod.amount" } });
    g.endCell();
    g.cell();
    kit.field(ui, L("new.description"), f_desc, .{ .input = .{ .name = "parcel.description" } });
    g.endCell();
    g.end();
    morePanel(s, ui);
    cardEnd(ui, w);

    // Speed: standard or express.
    w = cardBegin(ui, 8.8);
    kit.h2(ui, L("express.speed"));
    var sg = kit.formGrid(ui, 2);
    sg.cell();
    kit.option(ui, icons.local_shipping, L("express.standard"), L("express.standard_sub"), !s.express, kit.act(A.service_standard, 0));
    sg.endCell();
    sg.cell();
    kit.option(ui, icons.bolt, L("express.express"), if (anyExpress(c)) L("express.express_sub") else L("express.none_yet"), s.express, kit.act(A.service_express, 0));
    sg.endCell();
    sg.end();
    if (s.express) {
        kit.noticeBegin(ui, .info, icons.bolt);
        kit.text(ui, L("express.note"), .{});
        kit.noticeEnd(ui);
    }
    cardEnd(ui, w);

    // Carrier / route.
    w = cardBegin(ui, 16);
    kit.h2(ui, L("shipment.carrier"));
    var opts: std.ArrayList(core.Opt) = .empty;
    opts.append(ui.arena(), .{ .value = "auto", .label = L("new.carrier_auto") }) catch {};
    for (carriers(c)) |x| {
        if (s.express and !json.has(x, "express")) continue;
        const lbl = if (s.express)
            kit.f(ui, "{s} · {s}", .{ json.str(x, "name"), ui.tf(labels.english("express.within") orelse "{time}", .{ .time = fmt.duration(ui.arena(), json.num(x, "express.minutes")) }) })
        else
            json.str(x, "name");
        opts.append(ui.arena(), .{ .value = json.str(x, "id"), .label = lbl }) catch {};
    }
    const auto = isAuto(c);
    var cg = kit.formGrid(ui, if (auto) 2 else 1);
    cg.cell();
    kit.selectField(ui, L("new.carrier"), f_carrier, opts.items, .{ .name = "carrier" });
    cg.endCell();
    if (auto) {
        cg.cell();
        var sopts: std.ArrayList(core.Opt) = .empty;
        for (json.arr(c.meta.value, "strategies")) |x| if (x == .string) sopts.append(ui.arena(), .{ .value = x.string, .label = labels.of("strategy.", x.string) }) catch {};
        kit.selectField(ui, L("new.strategy"), f_strategy, sopts.items, .{ .name = "strategy" });
        cg.endCell();
    }
    cg.end();
    ui.begin(.{ .direction = .row, .gap = 12, .align_items = .center }, .{});
    kit.button(ui, L("new.compare"), kit.act(A.compare, 0), .{ .icon = icons.list, .busy = @intFromEnum(A.compare) });
    ui.begin(.{ .grow = 1 }, .{});
    kit.small(ui, L("new.compare_hint"));
    ui.end();
    ui.end();
    if (s.chosen_option != null) {
        kit.noticeBegin(ui, .info, icons.route);
        kit.text(ui, s.chosen_note, .{});
        kit.noticeEnd(ui);
    }
    quotesBox(s, c, ui);
    cardEnd(ui, w);

    kit.rowEnd(ui);
    kit.button(ui, L("new.create"), kit.act(A.create, 0), .{ .variant = .primary, .size = .lg, .icon = icons.send, .flip = true, .busy = @intFromEnum(A.create) });
    ui.end();
    ui.end();
}

fn morePanel(s: *const S, ui: *Ui) void {
    const k = kit.k;
    ui.begin(.{ .padding = .xy(14.4, 11.2), .radius = 16, .background = k.panel_2, .gap = 12 }, .{});
    ui.begin(.{ .direction = .row, .gap = 6.4, .align_items = .center, .pressed_opacity = 0.7 }, .{ .on_press = kit.act(A.toggle_more, 0) });
    kit.icon(ui, if (s.more) icons.expand_less else icons.expand_more, 20.8, k.ink_3);
    ui.text(L("new.more_options"), .{ .font_size = 15, .weight = 600, .color = k.ink });
    ui.end();
    if (s.more) {
        const w = kit.width;
        kit.width = w - 28.8;
        defer kit.width = w;
        var g = kit.formGrid(ui, 3);
        g.cell();
        kit.field(ui, L("new.pieces"), f_pieces, .{ .input = .{ .kind = .number, .ltr = true, .name = "parcel.pieces" } });
        g.endCell();
        g.cell();
        kit.field(ui, L("new.value"), f_value, .{ .input = .{ .kind = .number, .ltr = true, .name = "parcel.value" } });
        g.endCell();
        g.cell();
        kit.field(ui, L("shipment.reference"), f_ref, .{ .hint = L("new.reference_hint"), .input = .{ .ltr = true, .name = "reference" } });
        g.endCell();
        g.end();
        dims(ui, f_len, f_wid, f_hei);
        kit.field(ui, L("new.notes"), f_notes, .{ .hint = L("new.notes_hint"), .input = .{ .name = "notes" } });
        ui.begin(.{ .direction = .row, .gap = 16 }, .{});
        kit.check(ui, L("shipment.fragile"), s.fragile, kit.act(A.toggle_fragile, 0));
        kit.check(ui, L("new.require_code"), s.require_code, kit.act(A.toggle_code, 0));
        ui.end();
    }
    ui.end();
}

/// Length, width and height in one row (`.dims`).
pub fn dims(ui: *Ui, l: u16, w: u16, h: u16) void {
    kit.fieldBegin(ui, L("new.dimensions"), false);
    ui.begin(.{ .direction = .row, .gap = 8 }, .{});
    kit.input(ui, l, .{ .kind = .number, .ltr = true, .placeholder = L("new.length"), .grow = 1, .width = 0 });
    kit.input(ui, w, .{ .kind = .number, .ltr = true, .placeholder = L("new.width"), .grow = 1, .width = 0 });
    kit.input(ui, h, .{ .kind = .number, .ltr = true, .placeholder = L("new.height"), .grow = 1, .width = 0 });
    ui.end();
    kit.fieldEnd(ui, "parcel.dimensionsCm", L("new.dimensions_hint"));
}

fn quotesBox(s: *const S, c: *const Cx, ui: *Ui) void {
    switch (s.quotes) {
        .none => {},
        .stale => kit.notice(ui, .info, L("new.quotes_stale")),
        .unavailable => kit.notice(ui, .warn, L("error.option_unavailable")),
        .list => {
            const opts = quoteOptions(c);
            if (opts.len == 0) {
                kit.empty(ui, if (s.express) L("express.no_options") else L("new.no_carriers"));
                return;
            }
            ui.begin(.{ .gap = 8.8 }, .{});
            for (opts, 0..) |o, i| optionCard(s, c, ui, o, i);
            const excluded = json.int(c.data(d_quotes), "excluded");
            if (excluded > 0) kit.small(ui, ui.tf(labels.english("new.excluded_n") orelse "{n}", .{ .n = excluded }));
            ui.end();
        },
    }
}

/// One route: a company, or a chain of companies with handovers at hubs.
fn optionCard(s: *const S, c: *const Cx, ui: *Ui, o: V, i: usize) void {
    const k = kit.k;
    const chain = json.boolean(o, "chain");
    const chosen = if (s.chosen_option) |id| std.mem.eql(u8, id, json.str(o, "id")) else false;
    const legs = json.arr(o, "legs");
    const a = ui.arena();
    kit.card(ui, .{ .pad = 15, .gap = 8, .inner = true, .ring = if (chosen) k.a else null, .key = zui.key(i + 1) });
    ui.begin(.{ .direction = .row, .gap = 12, .align_items = .center }, .{});
    if (chain) kit.avatar(ui, icons.route) else kit.logo(ui, json.obj(o, "carrier"), 40, 12);
    ui.begin(.{ .grow = 1, .gap = 3 }, .{});
    ui.begin(.{ .direction = .row, .gap = 6.4, .align_items = .center }, .{});
    if (chain) {
        for (legs, 0..) |l, j| {
            if (j > 0) kit.iconFlip(ui, icons.arrow_forward, 17.6, k.ink_3);
            ui.text(json.str(l, "carrier.name"), .{ .font_size = 13.6, .weight = 700, .color = k.ink });
        }
    } else kit.strong(ui, json.str(o, "carrier.name"));
    if (std.mem.eql(u8, json.str(o, "service"), "express")) kit.expressBadge(ui);
    if (i == 0) kit.badge(ui, L("new.best_match"), .green);
    ui.end();
    var line: std.ArrayList(u8) = .empty;
    line.appendSlice(a, ui.tf(labels.english("new.eta") orelse "{time}", .{ .time = fmt.duration(a, json.numOr(o, "etaHours", 0) * 60) })) catch {};
    line.appendSlice(a, " · ") catch {};
    line.appendSlice(a, ui.tf(labels.english("new.reliability") orelse "{p}", .{ .p = @as(i64, @intFromFloat(@round(json.numOr(o, "reliability", 0) * 100))) })) catch {};
    if (json.num(o, "distanceKm")) |km| {
        line.appendSlice(a, " · ") catch {};
        line.appendSlice(a, ui.tf(labels.english("new.hub_distance") orelse "{km}", .{ .km = fmt.number(a, km, 1) })) catch {};
    }
    if (chain) {
        line.appendSlice(a, " · ") catch {};
        line.appendSlice(a, ui.tf(labels.english("new.handovers_n") orelse "{n}", .{ .n = @as(i64, @intCast(legs.len)) - 1 })) catch {};
    }
    kit.small(ui, line.items);
    ui.end();
    ui.text(fmt.money(a, json.num(o, "price.amount"), json.str(o, "price.currency")), .{ .font_size = 18.4, .weight = 850, .color = k.ink, .max_lines = 1 });
    kit.button(ui, L("dispatch.choose"), kit.act(A.choose_option, @intCast(i)), .{ .size = .sm, .variant = if (i == 0) .primary else .normal });
    ui.end();
    if (chain) {
        ui.begin(.{ .gap = 2, .padding = .{ .start = 19.2 } }, .{});
        for (legs, 0..) |l, j| {
            var t: std.ArrayList(u8) = .empty;
            t.appendSlice(a, kit.f(ui, "{d}. ", .{j + 1})) catch {};
            t.appendSlice(a, ui.tf(labels.english("new.chain_leg") orelse "{carrier}", .{ .carrier = json.str(l, "carrier.name"), .from = parts.gov(c, json.str(l, "from")), .to = if (json.str(l, "to").len > 0) parts.gov(c, json.str(l, "to")) else L("new.chain_recipient") })) catch {};
            if (json.has(l, "handoverHub")) {
                t.appendSlice(a, " · ") catch {};
                t.appendSlice(a, ui.tf(labels.english("new.chain_handover") orelse "{hub}", .{ .hub = json.str(l, "handoverHub.name"), .city = json.str(l, "handoverHub.city") })) catch {};
            }
            t.appendSlice(a, " · ") catch {};
            t.appendSlice(a, fmt.money(a, json.num(l, "price.amount"), json.str(l, "price.currency"))) catch {};
            kit.small(ui, t.items);
        }
        ui.end();
    }
    kit.endCard(ui, .{});
}

// ---- Tests ------------------------------------------------------------------------------------

const app = @import("../app.zig");
const testing = std.testing;

pub const merchant_org =
    \\{"id":"o1","type":"merchant","name":"Acme Store","slug":"acme","status":"active","branding":{"appName":"Acme Store"},
    \\ "merchant":{"places":[{"id":"p1","label":"Main shop","isDefault":true}],"defaultStrategy":"balanced"},
    \\ "me":{"permissions":["shipments.view","shipments.create","shipments.cancel","finance.view"],"isOwner":true}}
;

fn openNew() !void {
    try app.startSignedIn("/o/acme/shipments/new");
    try testing.expect(app.D.respond("/api/app/orgs/o1", 200, merchant_org));
    try testing.expect(app.D.respond("/api/app/orgs/o1", 200, merchant_org));
    try testing.expect(app.D.respond("/merchant/carriers", 200, "[{\"id\":\"c1\",\"name\":\"Fast Express\",\"express\":{\"minutes\":45}},{\"id\":\"c2\",\"name\":\"Slow Co\"}]"));
}

/// The newest request whose address contains `part`.
pub fn lastFetch(part: []const u8) ?zui.host.PendingFetch {
    var i = zui.host.fetches.items.len;
    while (i > 0) {
        i -= 1;
        const f = zui.host.fetches.items[i];
        if (std.mem.indexOf(u8, f.url, part) != null) return f;
    }
    return null;
}

pub fn has(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

test "new shipment: compare, choose and create" {
    try openNew();
    defer app.D.reset();
    try testing.expect(app.D.findText("Main shop") != 0);
    try app.D.typeInto("09xx xxx xxx", "0944111222");
    try app.D.press(L("new.compare"));
    const q = lastFetch("/merchant/quotes").?;
    try testing.expect(has(q.body, "\"pickup\":\"p1\""));
    try testing.expect(has(q.body, "\"weightKg\":1"));
    try testing.expect(has(q.body, "\"phone\":\"0944111222\""));
    try testing.expect(app.D.respond("/merchant/quotes", 200,
        \\{"options":[{"id":"x1","carrier":{"id":"c2","name":"Slow Co"},"etaHours":24,"reliability":0.9,"price":{"amount":5000,"currency":"SYP"}}],"excluded":1}
    ));
    try testing.expect(app.D.findText(L("new.best_match")) != 0);
    try app.D.press(L("dispatch.choose"));
    // The phone is not part of the price: the list stays.
    try app.D.typeInto("09xx xxx xxx", "0944111223");
    try testing.expect(app.D.findText(L("new.best_match")) != 0);
    try app.D.press(L("new.create"));
    const b = lastFetch("/merchant/shipments").?;
    try testing.expect(has(b.body, "\"carrier\":\"c2\""));
    try testing.expect(!has(b.body, "\"strategy\""));
    try testing.expect(app.D.respond("/merchant/shipments", 201, "{\"id\":\"s9\",\"trackingNumber\":\"TRF-1\",\"carrier\":{\"name\":\"Slow Co\"}}"));
    try testing.expect(has(zui.host.link.items, "/o/acme/shipments/s9"));
}

test "new shipment: quotes go stale; another place is saved first" {
    try openNew();
    defer app.D.reset();
    try app.D.press(L("new.compare"));
    try testing.expect(app.D.respond("/merchant/quotes", 200, "{\"options\":[],\"excluded\":0}"));
    try testing.expect(app.D.findText(L("new.no_carriers")) != 0);
    try app.D.press(L("new.more_options"));
    try app.D.typeInto(L("new.length"), "20");
    try testing.expect(app.D.findText(L("new.quotes_stale")) != 0);
    try app.D.press(L("new.another_place"));
    try app.D.press(L("new.save_place"));
    try app.D.typeInto(L("places.label_placeholder"), "Depot");
    try app.D.press(L("new.create"));
    const p = lastFetch("/merchant/places").?;
    try testing.expect(has(p.body, "\"label\":\"Depot\""));
    try testing.expect(app.D.respond("/merchant/places", 400, "{\"error\":{\"code\":\"x_test\",\"field\":\"place.phone\",\"message\":\"Bad phone\"}}"));
    try testing.expect(app.D.findText("Bad phone") != 0);
}

test "address: a search result fills the address and the pin" {
    try openNew();
    defer app.D.reset();
    try app.D.typeInto(L("address.search_placeholder"), "mazzeh");
    app.D.runTimers();
    try testing.expect(app.D.respond("/api/v1/search?q=mazzeh", 200,
        \\{"success":true,"results":[{"name":"Mazzeh","label":"Mazzeh, Damascus","area":"Mazzeh","city":"Damascus","state":"Damascus Governorate","lat":33.5,"lng":36.25}]}
    ));
    try app.D.press("Mazzeh");
    try testing.expect(app.D.findText("Mazzeh, Damascus, Damascus") != 0);
    try testing.expect(app.D.respond("/api/v1/reverse?lat=33.5", 200, "{\"success\":true,\"place\":{\"street\":\"Main st\",\"city\":\"Other\"}}"));
    try testing.expect(app.D.findText("Main st, Mazzeh, Damascus, Damascus") != 0);
}

test {
    _ = address;
    _ = @import("../widgets/places.zig");
}
