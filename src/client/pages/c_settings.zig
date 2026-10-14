//! Carrier settings (Turf-js views/carrier/settings.js): readiness, verification for new
//! carriers, profile, coverage and area limits, rate card with route prices, service levels,
//! express, courier pay, visibility, private clients, blocked senders, order rules, and closing
//! the company. Each section saves on its own (PATCH), then the company is reloaded so the
//! readiness list follows.
//!
//! Verification documents are photos (`Cx.pickPhoto`: the camera or the gallery, shrunk to
//! JPEG like Turf-js's compressImage), on every platform.

const std = @import("std");
const zui = @import("zui");
const core = @import("../core.zig");
const kit = @import("../kit.zig");
const json = @import("../json.zig");
const fmt = @import("../fmt.zig");
const icons = @import("../icons.zig");
const labels = @import("../labels.zig");
const cm = @import("../widgets/common.zig");
const CloseCompany = @import("../widgets/close_company.zig").CloseCompany;

const Cx = core.Cx;
const Ui = core.Ui;
const V = json.V;
const L = labels.k;
const eq = std.mem.eql;

const d_clients: u8 = 0;
const d_blocked: u8 = 1;
const d_close: u8 = 2;

// Form slots.
const f_name: u16 = 0;
const f_phone: u16 = 1;
const f_gov: u16 = 2;
const f_currency: u16 = 3;
const f_local_base: u16 = 4;
const f_national_base: u16 = 5;
const f_included_kg: u16 = 6;
const f_per_kg: u16 = 7;
const f_per_km: u16 = 8;
const f_cod_percent: u16 = 9;
const f_cod_min: u16 = 10;
const f_vol_div: u16 = 11;
const f_fragile_fee: u16 = 12;
const f_extra_piece: u16 = 13;
const f_value_percent: u16 = 14;
const f_local_hours: u16 = 15;
const f_national_hours: u16 = 16;
const f_max_weight: u16 = 17;
const f_max_attempts: u16 = 18;
const f_x_minutes: u16 = 19;
const f_x_max_km: u16 = 20;
const f_x_max_weight: u16 = 21;
const f_x_base: u16 = 22;
const f_x_per_km: u16 = 23;
const f_x_from: u16 = 24;
const f_x_to: u16 = 25;
const f_pay: u16 = 26; // 26..31
const f_visibility: u16 = 32;
const f_store: u16 = 33;
const f_v_legal: u16 = 34;
const f_v_reg: u16 = 35;
const f_v_owner: u16 = 36;
const f_v_owner_id: u16 = 37;
const f_v_phone: u16 = 38;
const f_v_address: u16 = 39;
const f_v_notes: u16 = 40;
const f_close: u16 = 41;
/// Route price rows: from, to, base at 200 + 3·row.
const f_routes: u16 = 200;
const max_routes = 30;
/// Area limits: cities, radius at 300 + 2·(governorate index).
const f_areas: u16 = 300;

const pay_fields = [_][]const u8{ "delivery", "pickup", "transfer", "return", "failed", "perExtraParcel" };

const A = enum(u16) {
    save_profile = 1,
    save_coverage,
    save_pricing,
    save_service,
    save_express,
    save_pay,
    save_visibility,
    save_orders,
    verify,
    cover,
    area_toggle,
    route_add,
    route_remove,
    toggle,
    client_add,
    client_remove,
    blocked_remove,
    photo_pick,
    photo_remove,
    close_base = 100,
};

const Flag = enum(u32) { cod_enabled, express_enabled, accept_marketplace, accept_direct, accept_individuals, auto_dispatch, direct_local };

pub const S = struct {
    touched: bool = false,
    reloaded: bool = false,
    coverage: cm.IdSet = .{},
    /// Area panels open, by governorate index.
    areas_open: u64 = 0,
    /// Route rows on screen (their row numbers).
    routes: std.ArrayList(u16) = .empty,
    next_route: u16 = 0,
    flags: std.EnumSet(Flag) = .empty,
    documents: std.ArrayList([]const u8) = .empty,
    close: CloseCompany = .{ .base = @intFromEnum(A.close_base), .slot = d_close, .field = f_close },
};

pub fn title(_: *const S, _: *const Cx) []const u8 {
    return L("nav.settings");
}

fn govs(c: *const Cx) []const V {
    return json.arr(c.meta.value, "governorates");
}

/// A number from the company for a field, or `fallback` when missing; `zero_empty` shows 0 as
/// empty (optional surcharges).
fn numField(c: *Cx, slot: u16, v: ?V, path: []const u8, fallback: []const u8, zero_empty: bool) void {
    var x = cm.numText(c, v, path);
    if (zero_empty and (json.numOr(v, path, 0) == 0)) x = "";
    c.setVal(slot, if (x.len > 0 or zero_empty) x else fallback);
}

fn prefill(s: *S, c: *Cx) void {
    const org = c.orgV();
    const car = json.get(org, "carrier");
    c.setVal(f_name, json.str(org, "name"));
    c.setVal(f_phone, json.str(org, "contact.phone"));
    c.setVal(f_gov, json.str(org, "contact.governorate"));
    // Coverage and areas.
    s.coverage.clear();
    for (json.arr(car, "coverage")) |g| if (g == .string) s.coverage.add(c, g.string);
    s.areas_open = 0;
    for (govs(c), 0..) |g, i| {
        const rule = json.get(car, c.print("areas.{s}", .{json.str(g, "code")}));
        var cities: std.ArrayList(u8) = .empty;
        for (json.arr(rule, "cities"), 0..) |x, j| {
            if (j > 0) cities.appendSlice(c.arena(), ", ") catch {};
            if (x == .string) cities.appendSlice(c.arena(), x.string) catch {};
        }
        const slot = f_areas + 2 * @as(u16, @intCast(i));
        c.setVal(slot, cities.items);
        c.setVal(slot + 1, cm.numText(c, rule, "radiusKm"));
        if ((cities.items.len > 0 or json.num(rule, "radiusKm") != null) and i < 64) s.areas_open |= @as(u64, 1) << @intCast(i);
    }
    // Pricing.
    const p = json.get(car, "pricing");
    c.setVal(f_currency, json.str(car, "currency"));
    numField(c, f_local_base, p, "localBase", "", false);
    numField(c, f_national_base, p, "nationalBase", "", false);
    numField(c, f_included_kg, p, "includedKg", "2", false);
    numField(c, f_per_kg, p, "perKg", "0", false);
    numField(c, f_per_km, p, "perKm", "0", false);
    numField(c, f_cod_percent, p, "codPercent", "0", false);
    numField(c, f_cod_min, p, "codMin", "0", false);
    numField(c, f_vol_div, p, "volumetricDivisor", "", true);
    numField(c, f_fragile_fee, p, "fragileFee", "", true);
    numField(c, f_extra_piece, p, "extraPieceFee", "", true);
    numField(c, f_value_percent, p, "valuePercent", "", true);
    s.routes.clearRetainingCapacity();
    s.next_route = 0;
    for (json.arr(p, "routes")) |r| addRoute(s, c, r);
    // Service.
    numField(c, f_local_hours, car, "sla.localHours", "24", false);
    numField(c, f_national_hours, car, "sla.nationalHours", "72", false);
    numField(c, f_max_weight, car, "maxWeightKg", "", false);
    numField(c, f_max_attempts, car, "maxAttempts", "", false);
    // Express.
    const x = json.get(car, "express");
    numField(c, f_x_minutes, x, "minutes", "60", false);
    numField(c, f_x_max_km, x, "maxKm", "15", false);
    numField(c, f_x_max_weight, x, "maxWeightKg", "20", false);
    numField(c, f_x_base, x, "base", "", false);
    numField(c, f_x_per_km, x, "perKm", "0", false);
    c.setVal(f_x_from, json.str(x, "hours.from"));
    c.setVal(f_x_to, json.str(x, "hours.to"));
    // Courier pay.
    for (pay_fields, 0..) |k, i| numField(c, f_pay + @as(u16, @intCast(i)), json.get(car, "courierPay"), k, "", true);
    c.setVal(f_visibility, json.strOr(car, "visibility", "network"));
    // Check boxes.
    s.flags = .empty;
    s.flags.setPresent(.cod_enabled, json.boolean(car, "cod.enabled"));
    s.flags.setPresent(.express_enabled, json.boolean(x, "enabled"));
    s.flags.setPresent(.accept_marketplace, json.boolean(car, "acceptMarketplace"));
    s.flags.setPresent(.accept_direct, json.boolean(car, "acceptDirect"));
    s.flags.setPresent(.accept_individuals, json.boolean(car, "acceptIndividuals"));
    s.flags.setPresent(.auto_dispatch, json.boolean(car, "autoDispatch"));
    s.flags.setPresent(.direct_local, json.boolean(car, "directLocal"));
    // Verification.
    const v = json.get(org, "verification");
    c.setVal(f_v_legal, json.str(v, "legalName"));
    c.setVal(f_v_reg, json.str(v, "registrationNumber"));
    c.setVal(f_v_owner, json.str(v, "ownerName"));
    c.setVal(f_v_owner_id, json.str(v, "ownerIdNumber"));
    c.setVal(f_v_phone, json.strOr(v, "phone", json.str(org, "contact.phone")));
    c.setVal(f_v_address, json.str(v, "address"));
    c.setVal(f_v_notes, json.str(v, "notes"));
}

fn addRoute(s: *S, c: *Cx, r: ?V) void {
    if (s.routes.items.len >= max_routes or s.next_route >= max_routes) return;
    const row = s.next_route;
    s.next_route += 1;
    s.routes.append(c.arena(), row) catch return;
    const base = f_routes + 3 * row;
    c.setVal(base, json.str(r, "from"));
    c.setVal(base + 1, json.str(r, "to"));
    c.setVal(base + 2, cm.numText(c, r, "base"));
}

pub fn enter(s: *S, c: *Cx) void {
    prefill(s, c);
    @import("../app.zig").reloadOrg(c);
    c.load(d_clients, c.orgUrl("/carrier/clients"));
    c.load(d_blocked, c.orgUrl("/carrier/blocked"));
}

fn send(c: *Cx, id: A, path: []const u8, body: []const u8) void {
    c.send(@intFromEnum(id), .PATCH, c.orgUrl(path), body);
}

fn splitCities(b: *json.Obj, text: []const u8) void {
    var it = std.mem.tokenizeAny(u8, text, "\n,");
    while (it.next()) |part0| {
        // "،" (the Arabic comma) also separates.
        var it2 = std.mem.splitSequence(u8, part0, "،");
        while (it2.next()) |part| {
            const x = std.mem.trim(u8, part, " \t\r");
            if (x.len > 0) b.str("", x);
        }
    }
}

fn countCities(text: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, text, "\n,");
    while (it.next()) |part0| {
        var it2 = std.mem.splitSequence(u8, part0, "،");
        while (it2.next()) |part| {
            if (std.mem.trim(u8, part, " \t\r").len > 0) n += 1;
        }
    }
    return n;
}

fn save(s: *S, c: *Cx, id: A) void {
    var b = json.Obj.init(c.arena());
    switch (id) {
        .save_profile => {
            b.strOpt("name", c.valTrim(f_name));
            b.strOpt("phone", c.valTrim(f_phone));
            b.strOpt("governorate", c.val(f_gov));
            return c.send(@intFromEnum(id), .PATCH, c.orgUrl("/profile"), b.done());
        },
        .save_coverage => {
            b.beginArray("coverage");
            for (govs(c)) |g| if (s.coverage.has(json.str(g, "code"))) b.str("", json.str(g, "code"));
            b.endArray();
            b.begin("areas");
            for (govs(c), 0..) |g, i| {
                const code = json.str(g, "code");
                if (!s.coverage.has(code)) continue;
                const slot = f_areas + 2 * @as(u16, @intCast(i));
                b.begin(code);
                b.beginArray("cities");
                splitCities(&b, c.val(slot));
                b.endArray();
                const km = c.valNum(slot + 1) orelse 0;
                if (km != 0) b.num("radiusKm", km) else b.nul("radiusKm");
                b.end();
            }
            b.end();
        },
        .save_pricing => {
            b.str("currency", upper(c, c.valTrim(f_currency)));
            b.begin("pricing");
            const fields = [_]struct { []const u8, u16 }{
                .{ "localBase", f_local_base },         .{ "nationalBase", f_national_base }, .{ "includedKg", f_included_kg },
                .{ "perKg", f_per_kg },                 .{ "perKm", f_per_km },               .{ "codPercent", f_cod_percent },
                .{ "codMin", f_cod_min },               .{ "volumetricDivisor", f_vol_div },  .{ "fragileFee", f_fragile_fee },
                .{ "extraPieceFee", f_extra_piece },    .{ "valuePercent", f_value_percent },
            };
            for (fields) |f| cm.numOpt(&b, c, f[0], f[1]);
            b.beginArray("routes");
            for (s.routes.items) |row| {
                const base = f_routes + 3 * row;
                const from = c.valTrim(base);
                const to = c.valTrim(base + 1);
                const price = c.valTrim(base + 2);
                if (from.len == 0 and to.len == 0 and price.len == 0) continue;
                b.begin("");
                b.str("from", from);
                b.str("to", to);
                cm.numOpt(&b, c, "base", base + 2);
                b.end();
            }
            b.endArray();
            b.end();
        },
        .save_service => {
            b.begin("sla");
            cm.numOpt(&b, c, "localHours", f_local_hours);
            cm.numOpt(&b, c, "nationalHours", f_national_hours);
            b.end();
            cm.numOpt(&b, c, "maxWeightKg", f_max_weight);
            cm.numOpt(&b, c, "maxAttempts", f_max_attempts);
            b.boolean("codEnabled", s.flags.contains(.cod_enabled));
        },
        .save_express => {
            b.begin("express");
            b.boolean("enabled", s.flags.contains(.express_enabled));
            cm.numOpt(&b, c, "minutes", f_x_minutes);
            cm.numOpt(&b, c, "maxKm", f_x_max_km);
            cm.numOpt(&b, c, "maxWeightKg", f_x_max_weight);
            cm.numOpt(&b, c, "base", f_x_base);
            cm.numOpt(&b, c, "perKm", f_x_per_km);
            if (c.valTrim(f_x_from).len > 0 or c.valTrim(f_x_to).len > 0) {
                b.begin("hours");
                b.strOpt("from", c.val(f_x_from));
                b.strOpt("to", c.val(f_x_to));
                b.end();
            } else b.nul("hours");
            b.end();
        },
        .save_pay => {
            // All empty: the company does not pay per task (pay is hidden everywhere).
            var any = false;
            for (0..pay_fields.len) |i| if (c.valTrim(f_pay + @as(u16, @intCast(i))).len > 0) {
                any = true;
            };
            if (any) {
                b.begin("courierPay");
                for (pay_fields, 0..) |k, i| cm.numOpt(&b, c, k, f_pay + @as(u16, @intCast(i)));
                b.end();
            } else b.nul("courierPay");
        },
        .save_visibility => b.strOpt("visibility", c.val(f_visibility)),
        .save_orders => {
            b.boolean("acceptMarketplace", s.flags.contains(.accept_marketplace));
            b.boolean("acceptDirect", s.flags.contains(.accept_direct));
            if (c.directOn()) b.boolean("acceptIndividuals", s.flags.contains(.accept_individuals));
            b.boolean("autoDispatch", s.flags.contains(.auto_dispatch));
            b.boolean("directLocal", s.flags.contains(.direct_local));
        },
        else => return,
    }
    send(c, id, "/carrier/settings", b.done());
}

fn upper(c: *Cx, s: []const u8) []const u8 {
    const out = c.arena().dupe(u8, s) catch return s;
    for (out) |*ch| ch.* = std.ascii.toUpper(ch.*);
    return out;
}

fn verify(s: *S, c: *Cx) void {
    var b = json.Obj.init(c.arena());
    b.strOpt("legalName", c.valTrim(f_v_legal));
    b.strOpt("registrationNumber", c.valTrim(f_v_reg));
    b.strOpt("ownerName", c.valTrim(f_v_owner));
    b.strOpt("ownerIdNumber", c.valTrim(f_v_owner_id));
    b.strOpt("phone", c.valTrim(f_v_phone));
    b.strOpt("address", c.valTrim(f_v_address));
    b.strOpt("notes", c.valTrim(f_v_notes));
    if (s.documents.items.len > 0) {
        b.beginArray("documents");
        for (s.documents.items) |d| b.str("", d);
        b.endArray();
    }
    c.send(@intFromEnum(A.verify), .PUT, c.orgUrl("/verification"), b.done());
}

pub fn update(s: *S, c: *Cx, e: core.Ev) void {
    if (s.close.update(c, e)) return;
    switch (e) {
        .data => |n| if (n == 255 and !s.reloaded) {
            s.reloaded = true;
            if (!s.touched) prefill(s, c);
        },
        .text => s.touched = true,
        .photo => |p| if (p.id == @intFromEnum(A.photo_pick)) {
            if (p.data.len == 0) return c.toast(L("task.photo_too_large"), .err);
            if (s.documents.items.len < 4) s.documents.append(c.arena(), c.dupe(p.data)) catch {};
        },
        .act => |a| {
            s.touched = true;
            const id: A = @enumFromInt(a.id);
            switch (id) {
                .save_profile, .save_coverage, .save_pricing, .save_service, .save_express, .save_pay, .save_visibility, .save_orders => save(s, c, id),
                .verify => verify(s, c),
                .cover => {
                    const g = govs(c);
                    if (a.arg < g.len) s.coverage.toggle(c, json.str(g[a.arg], "code"));
                },
                .area_toggle => if (a.arg < 64) {
                    s.areas_open ^= @as(u64, 1) << @intCast(a.arg);
                },
                .route_add => addRoute(s, c, null),
                .route_remove => for (s.routes.items, 0..) |row, i| if (row == a.arg) {
                    _ = s.routes.orderedRemove(i);
                    break;
                },
                .toggle => s.flags.toggle(@enumFromInt(a.arg)),
                .client_add => {
                    var b = json.Obj.init(c.arena());
                    b.str("store", c.valTrim(f_store));
                    c.send(@intFromEnum(A.client_add), .POST, c.orgUrl("/carrier/clients"), b.done());
                },
                .client_remove => {
                    const l = json.arr(c.data(d_clients), "");
                    if (a.arg < l.len) c.sendArg(@intFromEnum(A.client_remove), a.arg, .DELETE, c.orgUrl(c.print("/carrier/clients/{s}", .{cm.docId(l[a.arg])})), "");
                },
                .blocked_remove => {
                    const l = json.arr(c.data(d_blocked), "");
                    if (a.arg < l.len) c.sendArg(@intFromEnum(A.blocked_remove), a.arg, .DELETE, c.orgUrl(c.print("/carrier/blocked/{s}", .{cm.docId(l[a.arg])})), "");
                },
                .photo_pick => c.pickPhoto(@intFromEnum(A.photo_pick)),
                .photo_remove => if (a.arg < s.documents.items.len) {
                    _ = s.documents.orderedRemove(a.arg);
                },
                .close_base => {},
            }
        },
        .done => |d| switch (@as(A, @enumFromInt(d.id))) {
            .save_profile, .save_coverage, .save_pricing, .save_service, .save_express, .save_pay, .save_visibility, .save_orders => if (d.ok) {
                c.toast(L("common.saved"), .ok);
                @import("../app.zig").reloadOrg(c);
            },
            .verify => if (d.ok) {
                c.toast(L("verification.sent"), .ok);
                s.documents.clearRetainingCapacity();
                @import("../app.zig").reloadOrg(c);
            },
            .client_add => if (d.ok) {
                c.setVal(f_store, "");
                c.toast(L("common.saved"), .ok);
                c.load(d_clients, c.orgUrl("/carrier/clients"));
            },
            .client_remove => if (d.ok) c.load(d_clients, c.orgUrl("/carrier/clients")),
            .blocked_remove => if (d.ok) c.load(d_blocked, c.orgUrl("/carrier/blocked")),
            else => {},
        },
        else => {},
    }
}

// ---- View ---------------------------------------------------------------------------------

/// Enter in a one-line field of the section being drawn saves it (each section is a form in
/// Turf-js); set by `sectionBegin`.
var enter_msg: ?core.Msg = null;

fn sectionBegin(ui: *Ui, title_text: []const u8, intro: []const u8, save_id: ?A) void {
    enter_msg = if (save_id) |id| kit.act(id, 0) else null;
    kit.card(ui, .{ .gap = 16 });
    ui.begin(.{ .gap = 4 }, .{});
    kit.h2(ui, title_text);
    if (intro.len > 0) kit.muted(ui, intro);
    ui.end();
}

fn sectionEnd(ui: *Ui, id: A) void {
    kit.rowEnd(ui);
    kit.button(ui, L("common.save"), kit.act(id, 0), .{ .variant = .primary, .busy = @intFromEnum(id) });
    ui.end();
    kit.endCard(ui, .{});
}

fn numInput(ui: *Ui, lbl: []const u8, slot: u16, name: []const u8, o: struct { hint: []const u8 = "", required: bool = false, decimal: bool = false, placeholder: []const u8 = "" }) void {
    kit.field(ui, lbl, slot, .{ .required = o.required, .hint = o.hint, .input = .{ .kind = if (o.decimal) .decimal else .number, .ltr = true, .name = name, .placeholder = o.placeholder, .on_submit = enter_msg } });
}

fn grid(ui: *Ui, n: usize) kit.Grid {
    return kit.formGrid(ui, n);
}

pub fn view(s: *const S, c: *const Cx, ui: *Ui) void {
    const org = c.orgV();
    ui.begin(.{ .gap = 16, .max_width = 920 }, .{});
    // Readiness: the missing steps shrink as they are done.
    const ready = json.arr(org, "readiness");
    if (ready.len > 0) {
        kit.noticeBegin(ui, .warn, icons.warning);
        kit.strong(ui, L("settings.not_ready"));
        for (ready) |r| if (r == .string) cm.bullet(ui, labels.of("readiness.", r.string));
        kit.noticeEnd(ui);
    } else kit.notice(ui, .ok, L("settings.ready"));
    if (eq(u8, json.str(org, "status"), "pending")) verification(s, c, ui);
    profile(c, ui);
    coverage(s, c, ui);
    pricing(s, c, ui);
    service(s, ui);
    express(s, ui);
    courierPay(ui);
    visibility(ui);
    clients(c, ui);
    blocked(c, ui);
    orders(s, c, ui);
    s.close.card(c, ui);
    ui.end();
}

fn verification(s: *const S, c: *const Cx, ui: *Ui) void {
    const v = json.get(c.orgV(), "verification");
    const st = json.strOr(v, "status", "not_submitted");
    enter_msg = kit.act(A.verify, 0);
    kit.card(ui, .{ .gap = 16 });
    kit.h2(ui, L("verification.title"));
    if (eq(u8, st, "not_submitted")) kit.notice(ui, .warn, L("verification.intro")) else if (eq(u8, st, "submitted")) kit.notice(ui, .ok, L("verification.submitted_note")) else if (eq(u8, st, "rejected")) kit.notice(ui, .err, cm.tx(ui, "verification.rejected_note", .{ .note = json.str(v, "reviewNote") }));
    var g = grid(ui, 6);
    inline for (.{
        .{ "verification.legal_name", f_v_legal, "legalName", false, InKind.text },
        .{ "verification.registration_number", f_v_reg, "registrationNumber", true, InKind.text },
        .{ "verification.owner_name", f_v_owner, "ownerName", false, InKind.text },
        .{ "verification.owner_id", f_v_owner_id, "ownerIdNumber", true, InKind.text },
        .{ "common.phone", f_v_phone, "phone", true, InKind.phone },
        .{ "verification.address", f_v_address, "address", false, InKind.text },
    }) |x| {
        g.cell();
        kit.field(ui, L(x[0]), x[1], .{ .required = true, .input = .{ .name = x[2], .ltr = x[3], .kind = if (x[4] == .phone) .phone else .text, .on_submit = enter_msg } });
        g.endCell();
    }
    g.end();
    kit.field(ui, L("verification.notes"), f_v_notes, .{ .input = .{ .kind = .multiline, .name = "notes" } });
    // Documents: up to four photos.
    const kept = json.int(v, "documents");
    kit.fieldBegin(ui, L("verification.documents"), false);
    ui.begin(.{ .direction = .row, .gap = 8, .align_items = .center }, .{});
    for (s.documents.items, 0..) |_, i| {
        kit.badge(ui, kit.f(ui, "{d}", .{i + 1}), .brand);
        kit.iconButton(ui, icons.close, kit.act(A.photo_remove, @intCast(i)), .{ .size = .sm, .variant = .ghost, .label = L("common.delete") });
    }
    if (s.documents.items.len < 4) kit.button(ui, L("verification.documents"), kit.act(A.photo_pick, 0), .{ .size = .sm, .icon = icons.photo_camera });
    ui.end();
    kit.fieldEnd(ui, "documents", if (kept > 0) cm.tx(ui, "verification.documents_kept", .{ .n = kept }) else L("verification.documents_hint"));
    kit.rowEnd(ui);
    kit.button(ui, if (eq(u8, st, "not_submitted")) L("verification.submit") else L("verification.resubmit"), kit.act(A.verify, 0), .{ .variant = .primary, .busy = @intFromEnum(A.verify) });
    ui.end();
    kit.endCard(ui, .{});
}

const InKind = enum { text, phone };

fn profile(c: *const Cx, ui: *Ui) void {
    sectionBegin(ui, L("settings.profile"), "", .save_profile);
    var g = grid(ui, 3);
    g.cell();
    kit.field(ui, L("org.name"), f_name, .{ .input = .{ .name = "name", .on_submit = enter_msg } });
    g.endCell();
    g.cell();
    kit.field(ui, L("common.phone"), f_phone, .{ .hint = L("settings.phone_hint"), .input = .{ .kind = .phone, .ltr = true, .name = "phone", .on_submit = enter_msg } });
    g.endCell();
    g.cell();
    kit.selectField(ui, L("org.governorate"), f_gov, cm.govOptions(c, ui.arena()), .{ .placeholder = L("common.choose"), .name = "governorate" });
    g.endCell();
    g.end();
    sectionEnd(ui, .save_profile);
}

fn coverage(s: *const S, c: *const Cx, ui: *Ui) void {
    const k = kit.k;
    sectionBegin(ui, L("settings.coverage"), L("settings.coverage_intro"), .save_coverage);
    const list = govs(c);
    var g = kit.Grid.begin(ui, list.len, 220, 6.4, kit.width - 40);
    for (list, 0..) |gv, i| {
        g.cell();
        kit.check(ui, json.pick(gv, "", c.lang()), s.coverage.has(json.str(gv, "code")), kit.act(A.cover, @intCast(i)));
        g.endCell();
    }
    g.end();
    kit.stackTight(ui);
    kit.h3(ui, L("settings.areas"));
    kit.small(ui, L("settings.areas_intro"));
    var any = false;
    for (list, 0..) |gv, i| {
        const code = json.str(gv, "code");
        if (!s.coverage.has(code)) continue;
        any = true;
        const slot = f_areas + 2 * @as(u16, @intCast(i));
        const open = i < 64 and (s.areas_open >> @intCast(i)) & 1 == 1;
        ui.begin(.{ .padding = .xy(14.4, 11.2), .radius = 16, .background = k.panel_2, .gap = 12 }, .{ .key = zui.key(code) });
        // <summary>: the governorate and what is limited.
        const n = countCities(c.val(slot));
        const km = c.valNum(slot + 1) orelse 0;
        var summary: []const u8 = L("settings.area_everywhere");
        if (n > 0 and km != 0) summary = kit.f(ui, "{s} · {s}", .{ cm.tx(ui, "settings.area_n_cities", .{ .n = n }), cm.tx(ui, "settings.area_km", .{ .n = km }) }) else if (n > 0) summary = cm.tx(ui, "settings.area_n_cities", .{ .n = n }) else if (km != 0) summary = cm.tx(ui, "settings.area_km", .{ .n = km });
        ui.begin(.{ .direction = .row, .gap = 6.4, .align_items = .center, .pressed_opacity = 0.7 }, .{ .on_press = kit.act(A.area_toggle, @intCast(i)) });
        kit.icon(ui, if (open) icons.expand_less else icons.expand_more, 20.8, k.ink_3);
        ui.text(json.pick(gv, "", c.lang()), .{ .font_size = 15, .weight = 700, .color = k.ink });
        kit.small(ui, summary);
        ui.end();
        if (open) {
            var fg = grid(ui, 2);
            fg.cell();
            kit.field(ui, L("settings.area_cities"), slot, .{ .hint = L("settings.area_cities_hint"), .input = .{ .kind = .multiline, .placeholder = L("settings.area_cities_placeholder"), .name = kit.f(ui, "areas.{s}.cities", .{code}) } });
            fg.endCell();
            fg.cell();
            kit.field(ui, L("settings.area_radius"), slot + 1, .{ .hint = L("settings.area_radius_hint"), .input = .{ .kind = .number, .ltr = true, .placeholder = L("settings.area_radius_placeholder"), .name = kit.f(ui, "areas.{s}.radiusKm", .{code}), .on_submit = enter_msg } });
            fg.endCell();
            fg.end();
        }
        ui.end();
    }
    if (!any) kit.small(ui, L("settings.areas_none"));
    ui.end();
    sectionEnd(ui, .save_coverage);
}

fn pricing(s: *const S, c: *const Cx, ui: *Ui) void {
    sectionBegin(ui, L("settings.pricing"), L("settings.pricing_intro"), .save_pricing);
    var g = grid(ui, 8);
    inline for (.{
        .{ "settings.currency", f_currency, "currency", "", false },
        .{ "settings.local_base", f_local_base, "pricing.localBase", "settings.local_base_hint", false },
        .{ "settings.national_base", f_national_base, "pricing.nationalBase", "settings.national_base_hint", false },
        .{ "settings.included_kg", f_included_kg, "pricing.includedKg", "", true },
        .{ "settings.per_kg", f_per_kg, "pricing.perKg", "", false },
        .{ "settings.per_km", f_per_km, "pricing.perKm", "settings.per_km_hint", true },
        .{ "settings.cod_percent", f_cod_percent, "pricing.codPercent", "", true },
        .{ "settings.cod_min", f_cod_min, "pricing.codMin", "", false },
    }) |x| {
        g.cell();
        if (x[1] == f_currency) {
            kit.field(ui, L(x[0]), x[1], .{ .required = true, .input = .{ .ltr = true, .name = x[2], .on_submit = enter_msg } });
        } else numInput(ui, L(x[0]), x[1], x[2], .{ .required = true, .decimal = x[4], .hint = if (x[3].len > 0) L(x[3]) else "" });
        g.endCell();
    }
    g.end();
    kit.h3(ui, L("settings.extras"));
    var g2 = grid(ui, 4);
    g2.cell();
    numInput(ui, L("settings.volumetric_divisor"), f_vol_div, "pricing.volumetricDivisor", .{ .hint = L("settings.volumetric_divisor_hint"), .placeholder = "5000" });
    g2.endCell();
    g2.cell();
    numInput(ui, L("settings.fragile_fee"), f_fragile_fee, "pricing.fragileFee", .{});
    g2.endCell();
    g2.cell();
    numInput(ui, L("settings.extra_piece_fee"), f_extra_piece, "pricing.extraPieceFee", .{ .hint = L("settings.extra_piece_fee_hint") });
    g2.endCell();
    g2.cell();
    numInput(ui, L("settings.value_percent"), f_value_percent, "pricing.valuePercent", .{ .hint = L("settings.value_percent_hint"), .decimal = true });
    g2.endCell();
    g2.end();
    kit.h3(ui, L("settings.routes"));
    kit.small(ui, L("settings.routes_intro"));
    // Prices for governorate pairs (both directions).
    const opts = cm.govOptions(c, ui.arena());
    kit.fieldBegin(ui, "", false);
    for (s.routes.items) |row| {
        const base = f_routes + 3 * row;
        ui.begin(.{ .direction = .row, .gap = 8, .align_items = .center }, .{ .key = zui.key(@as(u32, row) + 900) });
        kit.select(ui, base, opts, .{ .placeholder = L("common.choose"), .grow = 1 });
        kit.icon(ui, icons.swap_horiz, 20, kit.k.ink_3);
        kit.select(ui, base + 1, opts, .{ .placeholder = L("common.choose"), .grow = 1 });
        kit.input(ui, base + 2, .{ .kind = .number, .ltr = true, .placeholder = L("settings.route_base"), .on_submit = enter_msg, .width = if (kit.phone) 96 else 144 });
        kit.button(ui, L("settings.route_remove"), kit.act(A.route_remove, row), .{ .size = .sm, .variant = .ghost });
        ui.end();
    }
    kit.fieldEnd(ui, "pricing.routes", "");
    ui.begin(.{ .direction = .row }, .{});
    kit.button(ui, L("settings.route_add"), kit.act(A.route_add, 0), .{ .size = .sm, .icon = icons.add });
    ui.end();
    // Live example: a 3 kg parcel, 5 km within the governorate, 100,000 cash on delivery.
    const n = struct {
        fn f(cx: *const Cx, slot: u16) f64 {
            return cx.valNum(slot) orelse 0;
        }
    }.f;
    const price = n(c, f_local_base) + @max(0, @ceil(3 - n(c, f_included_kg))) * n(c, f_per_kg) + @round(5 * n(c, f_per_km)) + @max(n(c, f_cod_min), @round(100000 * n(c, f_cod_percent) / 100));
    const cur = if (c.valTrim(f_currency).len > 0) c.valTrim(f_currency) else json.str(c.orgV(), "carrier.currency");
    kit.notice(ui, .info, cm.tx(ui, "settings.price_example", .{ .price = @import("../fmt.zig").money(ui.arena(), price, cur) }));
    sectionEnd(ui, .save_pricing);
}

fn service(s: *const S, ui: *Ui) void {
    sectionBegin(ui, L("settings.service"), "", .save_service);
    var g = grid(ui, 4);
    g.cell();
    numInput(ui, L("settings.local_hours"), f_local_hours, "sla.localHours", .{ .required = true });
    g.endCell();
    g.cell();
    numInput(ui, L("settings.national_hours"), f_national_hours, "sla.nationalHours", .{ .required = true });
    g.endCell();
    g.cell();
    numInput(ui, L("settings.max_weight"), f_max_weight, "maxWeightKg", .{ .required = true, .decimal = true });
    g.endCell();
    g.cell();
    numInput(ui, L("settings.max_attempts"), f_max_attempts, "maxAttempts", .{ .required = true });
    g.endCell();
    g.end();
    kit.check(ui, L("settings.cod_enabled"), s.flags.contains(.cod_enabled), kit.act(A.toggle, @intFromEnum(Flag.cod_enabled)));
    sectionEnd(ui, .save_service);
}

fn express(s: *const S, ui: *Ui) void {
    sectionBegin(ui, L("express.settings_title"), L("express.settings_intro"), .save_express);
    kit.check(ui, L("express.offer"), s.flags.contains(.express_enabled), kit.act(A.toggle, @intFromEnum(Flag.express_enabled)));
    var g = grid(ui, 5);
    g.cell();
    numInput(ui, L("express.minutes"), f_x_minutes, "express.minutes", .{ .required = true, .hint = L("express.minutes_hint") });
    g.endCell();
    g.cell();
    numInput(ui, L("express.max_km"), f_x_max_km, "express.maxKm", .{ .required = true, .decimal = true, .hint = L("express.max_km_hint") });
    g.endCell();
    g.cell();
    numInput(ui, L("express.max_weight"), f_x_max_weight, "express.maxWeightKg", .{ .required = true, .decimal = true });
    g.endCell();
    g.cell();
    numInput(ui, L("express.base"), f_x_base, "express.base", .{ .required = true, .hint = L("express.base_hint") });
    g.endCell();
    g.cell();
    numInput(ui, L("express.per_km"), f_x_per_km, "express.perKm", .{ .decimal = true });
    g.endCell();
    g.end();
    kit.h3(ui, L("express.hours"));
    kit.small(ui, L("express.hours_hint"));
    // The platform's time picker ("HH:MM").
    var g2 = grid(ui, 2);
    g2.cell();
    kit.dateField(ui, L("express.opens"), f_x_from, .{ .time = true, .placeholder = "09:00", .name = "express.hours.from" });
    g2.endCell();
    g2.cell();
    kit.dateField(ui, L("express.closes"), f_x_to, .{ .time = true, .placeholder = "22:00", .name = "express.hours.to" });
    g2.endCell();
    g2.end();
    kit.noticeBegin(ui, .info, icons.bolt);
    kit.text(ui, L("express.dispatch_note"), .{});
    kit.noticeEnd(ui);
    sectionEnd(ui, .save_express);
}

fn courierPay(ui: *Ui) void {
    sectionBegin(ui, L("settings.courier_pay"), L("settings.courier_pay_intro"), .save_pay);
    var g = grid(ui, pay_fields.len);
    inline for (pay_fields, 0..) |k, i| {
        g.cell();
        numInput(ui, L("settings.pay_" ++ k), f_pay + i, "courierPay." ++ k, .{ .hint = L("settings.pay_" ++ k ++ "_hint") });
        g.endCell();
    }
    g.end();
    sectionEnd(ui, .save_pay);
}

fn visibility(ui: *Ui) void {
    sectionBegin(ui, L("settings.visibility"), L("settings.visibility_intro"), .save_visibility);
    const opts = [_]core.Opt{
        .{ .value = "network", .label = L("settings.visibility_network") },
        .{ .value = "private", .label = L("settings.visibility_private") },
    };
    kit.selectField(ui, L("settings.visibility"), f_visibility, &opts, .{ .name = "visibility" });
    sectionEnd(ui, .save_visibility);
}

/// A small list with a remove button per row; a failed load shows in the card.
fn removable(c: *const Cx, ui: *Ui, n: u8, empty_text: []const u8, remove: A, remove_label: []const u8, blocked_list: bool) void {
    const sl = c.slot(n);
    switch (sl.state) {
        .idle, .loading => return kit.loading(ui),
        .failed => return kit.notice(ui, .err, sl.err),
        .ok => {},
    }
    const list = json.arr(c.data(n), "");
    if (list.len == 0) return kit.muted(ui, empty_text);
    kit.stackTight(ui);
    for (list, 0..) |m, i| {
        kit.rowBetween(ui);
        ui.begin(.{ .grow = 1, .gap = 2 }, .{});
        kit.strong(ui, json.str(m, "name"));
        if (blocked_list and json.boolean(m, "personal")) kit.small(ui, L("block.person")) else {
            ui.begin(.{ .no_mirror = true }, .{});
            kit.small(ui, kit.f(ui, "/o/{s}", .{json.str(m, "slug")}));
            ui.end();
        }
        ui.end();
        const mine = c.isBusy(@intFromEnum(remove)) and (c.act_args.get(@intFromEnum(remove)) orelse 0) == i;
        kit.button(ui, remove_label, kit.act(remove, @intCast(i)), .{ .size = .sm, .variant = .ghost, .busy = if (mine) @intFromEnum(remove) else null });
        ui.end();
    }
    ui.end();
}

fn clients(c: *const Cx, ui: *Ui) void {
    sectionBegin(ui, L("settings.clients"), L("settings.clients_intro"), null);
    removable(c, ui, d_clients, L("settings.clients_empty"), .client_remove, L("settings.client_remove"), false);
    ui.begin(.{ .direction = .row, .gap = 12, .align_items = .end }, .{});
    ui.begin(.{ .grow = 1 }, .{});
    kit.field(ui, L("settings.client_store"), f_store, .{ .required = true, .input = .{ .ltr = true, .placeholder = L("settings.client_placeholder"), .name = "store", .on_submit = kit.act(A.client_add, 0) } });
    ui.end();
    kit.button(ui, L("settings.client_add"), kit.act(A.client_add, 0), .{ .icon = icons.add, .busy = @intFromEnum(A.client_add) });
    ui.end();
    kit.endCard(ui, .{});
}

fn blocked(c: *const Cx, ui: *Ui) void {
    sectionBegin(ui, L("block.title"), L("block.intro"), null);
    removable(c, ui, d_blocked, L("block.none"), .blocked_remove, L("block.unblock"), true);
    kit.endCard(ui, .{});
}

fn orders(s: *const S, c: *const Cx, ui: *Ui) void {
    sectionBegin(ui, L("settings.orders"), "", .save_orders);
    kit.stackTight(ui);
    kit.check(ui, L("settings.accept_marketplace"), s.flags.contains(.accept_marketplace), kit.act(A.toggle, @intFromEnum(Flag.accept_marketplace)));
    kit.check(ui, L("settings.accept_direct"), s.flags.contains(.accept_direct), kit.act(A.toggle, @intFromEnum(Flag.accept_direct)));
    // Direct shipping for individuals: only while Turf has the feature switched on.
    if (c.directOn()) kit.check(ui, L("settings.accept_individuals"), s.flags.contains(.accept_individuals), kit.act(A.toggle, @intFromEnum(Flag.accept_individuals)));
    kit.check(ui, L("settings.auto_dispatch"), s.flags.contains(.auto_dispatch), kit.act(A.toggle, @intFromEnum(Flag.auto_dispatch)));
    kit.check(ui, L("settings.direct_local"), s.flags.contains(.direct_local), kit.act(A.toggle, @intFromEnum(Flag.direct_local)));
    kit.small(ui, L("settings.auto_dispatch_hint"));
    ui.end();
    sectionEnd(ui, .save_orders);
}

pub fn overlay(s: *const S, c: *const Cx, ui: *Ui) void {
    s.close.dialog(c, ui);
}

// ---- Tests --------------------------------------------------------------------------------

const app = @import("../app.zig");
const testing = std.testing;
const dispatch = @import("dispatch.zig");

fn lastBody() []const u8 {
    return zui.host.fetches.items[zui.host.fetches.items.len - 1].body;
}

test "carrier settings: pricing with a route, coverage, orders, closing" {
    try dispatch.openCarrier("/settings");
    defer app.D.reset();
    try testing.expect(app.D.respond("/carrier/clients", 200, "[{\"id\":\"m1\",\"name\":\"Acme\",\"slug\":\"acme\"}]"));
    try testing.expect(app.D.respond("/carrier/blocked", 200, "[]"));
    try testing.expect(app.D.respond("/api/app/orgs/o2", 200, dispatch.carrier_org));
    try testing.expect(app.D.findText(L("settings.ready")) != 0);
    try testing.expect(app.D.findText("Acme") != 0);
    // Pricing: a route between two governorates.
    app.D.R.dispatch(kit.act(A.route_add, 0));
    app.D.R.dispatch(.{ .text = .{ .slot = f_routes, .text = "DAM" } });
    app.D.R.dispatch(.{ .text = .{ .slot = f_routes + 1, .text = "HI" } });
    app.D.R.dispatch(.{ .text = .{ .slot = f_routes + 2, .text = "8000" } });
    app.D.R.dispatch(kit.act(A.save_pricing, 0));
    try testing.expect(std.mem.indexOf(u8, lastBody(), "\"currency\":\"SYP\"") != null);
    try testing.expect(std.mem.indexOf(u8, lastBody(), "\"localBase\":5000") != null);
    try testing.expect(std.mem.indexOf(u8, lastBody(), "\"routes\":[{\"from\":\"DAM\",\"to\":\"HI\",\"base\":8000}]") != null);
    try testing.expect(app.D.respond("/carrier/settings", 200, "{}"));
    try testing.expect(app.D.findText("Saved") != 0);
    try testing.expect(app.D.pending("/api/app/orgs/o2") != null);
    // Coverage: Damascus with a radius.
    app.D.R.dispatch(.{ .text = .{ .slot = f_areas + 1, .text = "12" } });
    app.D.R.dispatch(kit.act(A.save_coverage, 0));
    try testing.expect(std.mem.indexOf(u8, lastBody(), "{\"coverage\":[\"DAM\"],\"areas\":{\"DAM\":{\"cities\":[],\"radiusKm\":12}}}") != null);
    // Orders.
    app.D.R.dispatch(kit.act(A.toggle, @intFromEnum(Flag.auto_dispatch)));
    app.D.R.dispatch(kit.act(A.save_orders, 0));
    try testing.expect(std.mem.indexOf(u8, lastBody(), "\"autoDispatch\":true") != null);
    try testing.expect(std.mem.indexOf(u8, lastBody(), "acceptIndividuals") == null);
    // Closing: the owner sees what has to happen first.
    try app.D.press(L("close.title"));
    try testing.expect(app.D.respond("/close", 200, "{\"openShipments\":2,\"unpaidCash\":0}"));
    try testing.expect(app.D.findText(L("close.first")) != 0);
}

test "carrier settings: Enter in a field saves its section" {
    try dispatch.openCarrier("/settings");
    defer app.D.reset();
    try testing.expect(app.D.respond("/carrier/clients", 200, "[]"));
    try testing.expect(app.D.respond("/carrier/blocked", 200, "[]"));
    try testing.expect(app.D.respond("/api/app/orgs/o2", 200, dispatch.carrier_org));
    try app.D.typeInto("5000", "6000");
    try app.D.inputEvent("5000", .submit);
    const f = zui.host.fetches.items[zui.host.fetches.items.len - 1];
    try testing.expect(std.mem.endsWith(u8, f.url, "/carrier/settings"));
    try testing.expect(std.mem.indexOf(u8, f.body, "\"volumetricDivisor\":6000") != null);
}
