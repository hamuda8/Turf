//! Statements between a carrier and a store for a period (Turf-js views/shared/statements.js):
//! shipping fees, cash collected and the payout, with a CSV download; and the company's own Turf
//! fees for a month. Used by the carrier's and the store's finance pages.
//!
//! A page keeps a `Statements` in its state (its data slots, form slots and action id), calls
//! `enter`, passes it its events (`update`) and draws `view` and `feesView`.

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

pub const Side = enum { carrier, merchant };

/// Offers a file the app made (web: the page bridge "download"; the phones have no downloads).
pub fn download(c: *Cx, name: []const u8, text: []const u8, mime: []const u8) void {
    if (zui.platform != .web and zui.platform != .headless) return;
    const msg = std.fmt.allocPrint(c.arena(), "{{\"type\":\"download\",\"name\":{f},\"text\":{f},\"mime\":{f}}}", .{ std.json.fmt(name, .{}), std.json.fmt(text, .{}), std.json.fmt(mime, .{}) }) catch return;
    c.fx.post(msg);
}

/// Rows of cells as CSV text, with a BOM so Excel opens Arabic correctly (`toCsv`).
pub fn toCsv(a: std.mem.Allocator, rows: []const []const []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(a, "\u{FEFF}") catch {};
    for (rows, 0..) |r, i| {
        if (i > 0) out.appendSlice(a, "\r\n") catch {};
        for (r, 0..) |cell, j| {
            if (j > 0) out.append(a, ',') catch {};
            if (std.mem.indexOfAny(u8, cell, "\",\n\r") != null) {
                out.append(a, '"') catch {};
                for (cell) |ch| {
                    if (ch == '"') out.append(a, '"') catch {};
                    out.append(a, ch) catch {};
                }
                out.append(a, '"') catch {};
            } else out.appendSlice(a, cell) catch {};
        }
    }
    out.appendSlice(a, "\r\n") catch {};
    return out.items;
}

/// "YYYY-MM-DD" that is a real day.
pub fn validDay(s: []const u8) bool {
    if (s.len != 10 or s[4] != '-' or s[7] != '-') return false;
    const m = std.fmt.parseInt(u8, s[5..7], 10) catch return false;
    const d = std.fmt.parseInt(u8, s[8..10], 10) catch return false;
    _ = std.fmt.parseInt(u16, s[0..4], 10) catch return false;
    return m >= 1 and m <= 12 and d >= 1 and d <= 31;
}

pub fn validMonth(s: []const u8) bool {
    if (s.len != 7 or s[4] != '-') return false;
    const m = std.fmt.parseInt(u8, s[5..7], 10) catch return false;
    _ = std.fmt.parseInt(u16, s[0..4], 10) catch return false;
    return m >= 1 and m <= 12;
}

pub const Statements = struct {
    side: Side,
    // Data slots.
    d_list: u8,
    d_statement: u8,
    d_fees: u8,
    // Form slots.
    f_who: u16,
    f_from: u16,
    f_to: u16,
    f_month: u16,
    /// The action of the CSV download.
    act_csv: u16,
    /// No store/carrier or no period: "No delivered or returned parcels in this period."
    none: bool = false,

    fn base(w: *const Statements) []const u8 {
        return if (w.side == .carrier) "/carrier/finance" else "/merchant";
    }

    fn otherKey(w: *const Statements) []const u8 {
        return if (w.side == .carrier) "merchantId" else "carrierId";
    }

    /// The period starts on the first of this month and ends today; Turf's fees for this month.
    pub fn enter(w: *Statements, c: *Cx) void {
        const today = fmt.isoUtc(c.arena(), fmt.now());
        c.setVal(w.f_from, c.print("{s}-01", .{today[0..7]}));
        c.setVal(w.f_to, today[0..10]);
        c.setVal(w.f_month, today[0..7]);
        w.loadList(c);
        w.loadFees(c);
    }

    fn period(w: *const Statements, c: *const Cx) ?[2][]const u8 {
        const from = c.valTrim(w.f_from);
        const to = c.valTrim(w.f_to);
        if (!validDay(from) or !validDay(to)) return null;
        return .{ from, to };
    }

    fn loadList(w: *Statements, c: *Cx) void {
        const p = w.period(c) orelse return;
        c.load(w.d_list, c.orgUrl(c.print("{s}/statements?from={s}&to={s}", .{ w.base(), p[0], p[1] })));
    }

    fn query(w: *const Statements, c: *Cx) ?[]const u8 {
        const p = w.period(c) orelse return null;
        const who = c.val(w.f_who);
        if (who.len == 0) return null;
        return c.print("{s}={s}&from={s}&to={s}", .{ w.otherKey(), core.encode(c.arena(), who), p[0], p[1] });
    }

    fn loadStatement(w: *Statements, c: *Cx) void {
        const q = w.query(c) orelse {
            w.none = true;
            return;
        };
        w.none = false;
        c.load(w.d_statement, c.orgUrl(c.print("{s}/statement?{s}", .{ w.base(), q })));
    }

    fn loadFees(w: *Statements, c: *Cx) void {
        const m = c.valTrim(w.f_month);
        if (!validMonth(m)) return;
        c.load(w.d_fees, c.orgUrl(c.print("/platform-fees?month={s}", .{m})));
    }

    fn list(w: *const Statements, c: *const Cx) []const V {
        return json.arr(c.data(w.d_list), if (w.side == .carrier) "merchants" else "carriers");
    }

    /// Handles the widget's events; true when it was one of them.
    pub fn update(w: *Statements, c: *Cx, e: core.Ev) bool {
        switch (e) {
            .text => |x| {
                if (x.slot == w.f_from or x.slot == w.f_to) {
                    const v = c.valTrim(x.slot);
                    if (validDay(v)) w.loadList(c);
                    return true;
                }
                if (x.slot == w.f_who) {
                    w.loadStatement(c);
                    return true;
                }
                if (x.slot == w.f_month) {
                    if (validMonth(c.valTrim(w.f_month))) w.loadFees(c);
                    return true;
                }
            },
            .data => |n| {
                if (n == w.d_list) {
                    if (c.slot(n).err.len > 0) return true;
                    // Keep the chosen store when it is still in the period, else the first.
                    const keep = c.val(w.f_who);
                    var found = false;
                    const l = w.list(c);
                    for (l) |x| if (std.mem.eql(u8, json.str(x, "id"), keep)) {
                        found = true;
                    };
                    if (!found) c.setVal(w.f_who, if (l.len > 0) json.str(l[0], "id") else "");
                    w.loadStatement(c);
                    return true;
                }
                if (n == w.d_statement or n == w.d_fees) return true;
            },
            .act => |a| if (a.id == w.act_csv) {
                const q = w.query(c) orelse return true;
                c.send(w.act_csv, .GET, c.orgUrl(c.print("{s}/statement?{s}&format=csv&lang={s}", .{ w.base(), q, c.lang() })), "");
                return true;
            },
            .done => |d| if (d.id == w.act_csv) {
                if (d.ok) {
                    const p = w.period(c) orelse return true;
                    download(c, c.print("statement-{s}-{s}.csv", .{ p[0], p[1] }), d.body, "text/csv;charset=utf-8");
                }
                return true;
            },
            else => {},
        }
        return false;
    }

    /// The statements section.
    pub fn view(w: *const Statements, c: *const Cx, ui: *Ui) void {
        const k = kit.k;
        const a = ui.arena();
        kit.stack(ui);
        kit.h2(ui, L("statements.title"));
        kit.muted(ui, L(if (w.side == .carrier) "statements.intro_carrier" else "statements.intro_store"));

        var opts: std.ArrayList(core.Opt) = .empty;
        opts.append(a, .{ .value = "", .label = L("common.choose") }) catch {};
        for (w.list(c)) |x| opts.append(a, .{ .value = json.str(x, "id"), .label = kit.f(ui, "{s} ({s})", .{ json.str(x, "name"), fmt.number(a, json.numOr(x, "shipments", 0), 0) }) }) catch {};
        var g = kit.formGrid(ui, 3);
        g.cell();
        kit.selectField(ui, L(if (w.side == .carrier) "statements.store" else "statements.carrier"), w.f_who, opts.items, .{ .placeholder = L("common.choose") });
        g.endCell();
        g.cell();
        kit.field(ui, L("statements.from"), w.f_from, .{ .input = .{ .placeholder = "YYYY-MM-DD", .ltr = true } });
        g.endCell();
        g.cell();
        kit.field(ui, L("statements.to"), w.f_to, .{ .input = .{ .placeholder = "YYYY-MM-DD", .ltr = true } });
        g.endCell();
        g.end();

        const ls = c.slot(w.d_list);
        const ss = c.slot(w.d_statement);
        if (ls.state == .failed or ls.err.len > 0) {
            kit.notice(ui, .err, ls.err);
        } else if (ls.state != .ok) {
            kit.loading(ui);
        } else if (w.none) {
            kit.empty(ui, L("statements.none"));
        } else if (ss.state == .failed or ss.err.len > 0) {
            kit.notice(ui, .err, ss.err);
        } else if (ss.state != .ok) {
            kit.loading(ui);
        } else {
            ui.begin(.{ .gap = 16, .opacity = if (ss.reloading or ls.reloading) 0.55 else 1 }, .{});
            w.statement(c, ui, c.data(w.d_statement));
            ui.end();
        }
        _ = k;
        ui.end();
    }

    fn statement(w: *const Statements, c: *const Cx, ui: *Ui, st: ?V) void {
        _ = c;
        const a = ui.arena();
        const cur = json.str(st, "currency");
        const tt = json.obj(st, "totals");
        var g = kit.grid(ui, 4, 4);
        const items = [_][2][]const u8{
            .{ L("statements.delivered"), fmt.number(a, json.numOr(tt, "delivered", 0), 0) },
            .{ L("statements.returned"), fmt.number(a, json.numOr(tt, "returned", 0), 0) },
            .{ L("statements.shipping_fees"), fmt.money(a, json.num(tt, "shippingFees"), cur) },
            .{ L("statements.cod_collected"), fmt.money(a, json.num(tt, "codCollected"), cur) },
        };
        for (items) |x| {
            g.cell();
            kit.stat(ui, x[0], x[1], .{});
            g.endCell();
        }
        g.end();
        const comp = json.numOr(tt, "compensation", 0);
        if (comp != 0) kit.notice(ui, .info, ui.tf(labels.english("statements.compensation") orelse "{amount}", .{ .amount = fmt.money(a, comp, cur) }));
        const payout = json.numOr(tt, "payout", 0);
        const key = if (payout >= 0)
            (if (w.side == .carrier) "statements.payout_carrier_owes" else "statements.payout_store_gets")
        else
            (if (w.side == .carrier) "statements.payout_store_owes" else "statements.payout_store_pays");
        kit.noticeBegin(ui, if (payout >= 0) .ok else .warn, if (payout >= 0) icons.check else icons.warning);
        kit.strong(ui, ui.tf(labels.english(key) orelse "{amount}", .{ .amount = fmt.money(a, @abs(payout), cur) }));
        kit.noticeEnd(ui);
        kit.rowEnd(ui);
        kit.button(ui, L("statements.download_csv"), .{ .act = .{ .id = w.act_csv } }, .{ .icon = icons.download, .busy = w.act_csv });
        ui.end();

        const rows = json.arr(st, "rows");
        if (rows.len == 0) return;
        var tb = kit.Table.begin(ui, &.{
            .{ .label = L("statements.tracking"), .grow = 1.4 },
            .{ .label = L("common.status") },
            .{ .label = L("statements.date") },
            .{ .label = L("statements.shipping_fee") },
            .{ .label = L("statements.cod") },
            .{ .label = L("statements.net") },
        });
        for (rows, 0..) |r, i| {
            tb.row(null, zui.key(i + 1));
            tb.cell(false);
            kit.mono(ui, json.str(r, "trackingNumber"), .{ .weight = 700 });
            if (json.str(r, "reference").len > 0) kit.small(ui, json.str(r, "reference"));
            tb.endCell();
            tb.cell(true);
            kit.statusBadge(ui, json.str(r, "status"));
            tb.endCell();
            tb.cell(true);
            kit.text(ui, fmt.date(a, json.str(r, "date")), .{});
            tb.endCell();
            tb.cell(true);
            kit.text(ui, fmt.money(a, json.num(r, "shippingFee"), cur), .{});
            tb.endCell();
            tb.cell(true);
            const cod = json.numOr(r, "codCollected", 0);
            kit.text(ui, if (cod != 0) fmt.money(a, cod, cur) else "—", .{});
            if (json.boolean(r, "paidOut")) kit.small(ui, L("statements.paid_out"));
            tb.endCell();
            tb.cell(true);
            kit.strong(ui, fmt.money(a, json.num(r, "net"), cur));
            tb.endCell();
            tb.endRow();
        }
        tb.end();
    }

    /// The company's own Turf fees for a month (`platformFeesPanel`).
    pub fn feesView(w: *const Statements, c: *const Cx, ui: *Ui) void {
        const a = ui.arena();
        kit.stackTight(ui);
        kit.h2(ui, L("platform_fees.title"));
        ui.begin(.{ .max_width = 220 }, .{});
        kit.field(ui, L("admin.billing_month"), w.f_month, .{ .input = .{ .placeholder = "YYYY-MM", .ltr = true } });
        ui.end();
        const fs = c.slot(w.d_fees);
        if (fs.state == .failed or fs.err.len > 0) {
            kit.notice(ui, .err, fs.err);
        } else if (fs.state != .ok) {
            kit.loading(ui);
        } else {
            const lines = json.arr(c.data(w.d_fees), "lines");
            if (lines.len == 0) kit.muted(ui, L("platform_fees.none"));
            for (lines, 0..) |l, i| {
                kit.card(ui, .{ .direction = .row, .align_items = .center, .gap = 12, .key = zui.key(i + 1) });
                ui.begin(.{ .grow = 1, .gap = 2 }, .{});
                kit.strong(ui, fmt.money(a, json.num(l, "amount"), json.str(l, "currency")));
                kit.small(ui, ui.tf(labels.english("platform_fees.shipments") orelse "{n}", .{ .n = json.int(l, "shipments") }));
                ui.end();
                const due = json.numOr(l, "due", 0);
                if (due > 0)
                    kit.badge(ui, ui.tf(labels.english("platform_fees.due") orelse "{amount}", .{ .amount = fmt.money(a, due, json.str(l, "currency")) }), .amber)
                else
                    kit.badge(ui, L("platform_fees.paid"), .green);
                kit.endCard(ui, .{});
            }
        }
        ui.end();
    }
};

test "csv" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const rows = [_][]const []const u8{ &.{ "a", "b,c" }, &.{ "say \"hi\"", "" } };
    try std.testing.expectEqualStrings("\u{FEFF}a,\"b,c\"\r\n\"say \"\"hi\"\"\",\r\n", toCsv(arena.allocator(), &rows));
    try std.testing.expect(validDay("2026-10-01"));
    try std.testing.expect(!validDay("2026-1-01"));
    try std.testing.expect(validMonth("2026-10"));
}
