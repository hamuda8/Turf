//! Reports for stores and shipping companies (Turf-js views/shared/reports.js): a period's
//! volumes, delivery and on-time rates, cash on delivery and money, per day, per governorate and
//! per carrier (stores) or courier (companies). Everything can be downloaded as CSV (the summary
//! tables, or one row per shipment; web only: the page bridge "download").

const std = @import("std");
const zui = @import("zui");
const core = @import("../core.zig");
const kit = @import("../kit.zig");
const json = @import("../json.zig");
const fmt = @import("../fmt.zig");
const icons = @import("../icons.zig");
const labels = @import("../labels.zig");
const parts = @import("../widgets/parts.zig");
const statements = @import("../widgets/statements.zig");

const Cx = core.Cx;
const Ui = core.Ui;
const V = json.V;
const L = labels.k;

const d_report: u8 = 0;
const f_from: u16 = 0;
const f_to: u16 = 1;

const A = enum(u16) { preset = 1, summary, shipments };

pub const Preset = enum { d7, d30, month, last_month, year };

pub const S = struct {
    preset: ?Preset = .d30,
    from: []const u8 = "",
    to: []const u8 = "",
};

pub fn title(_: *const S, _: *const Cx) []const u8 {
    return L("reports.title");
}

fn base(c: *const Cx) []const u8 {
    return if (c.isCarrier()) "/carrier" else "/merchant";
}

// Days count in Damascus time (UTC+3), as the server does.
const tz_ms: i64 = 3 * 3600_000;

fn dayStr(a: std.mem.Allocator, ms: i64) []const u8 {
    return fmt.isoUtc(a, ms + tz_ms)[0..10];
}

fn shift(a: std.mem.Allocator, day: []const u8, n: i64) []const u8 {
    const noon = fmt.parseIso(std.fmt.allocPrint(a, "{s}T12:00:00Z", .{day}) catch return day) orelse return day;
    return dayStr(a, noon - tz_ms + n * 86400_000);
}

/// The period of a preset, ending today.
pub fn range(a: std.mem.Allocator, p: Preset, now_ms: i64) [2][]const u8 {
    const today = dayStr(a, now_ms);
    const first = std.fmt.allocPrint(a, "{s}-01", .{today[0..7]}) catch today;
    return switch (p) {
        .d7 => .{ shift(a, today, -6), today },
        .d30 => .{ shift(a, today, -29), today },
        .month => .{ first, today },
        .last_month => blk: {
            const end = shift(a, first, -1);
            break :blk .{ std.fmt.allocPrint(a, "{s}-01", .{end[0..7]}) catch end, end };
        },
        .year => .{ std.fmt.allocPrint(a, "{s}-01-01", .{today[0..4]}) catch today, today },
    };
}

fn load(s: *const S, c: *Cx) void {
    c.load(d_report, c.orgUrl(c.print("{s}/reports?from={s}&to={s}", .{ base(c), s.from, s.to })));
}

fn applyPreset(s: *S, c: *Cx, p: Preset) void {
    s.preset = p;
    const r = range(c.arena(), p, fmt.now());
    s.from = r[0];
    s.to = r[1];
    c.setVal(f_from, s.from);
    c.setVal(f_to, s.to);
}

pub fn enter(s: *S, c: *Cx) void {
    applyPreset(s, c, .d30);
    load(s, c);
}

pub fn update(s: *S, c: *Cx, e: core.Ev) void {
    switch (e) {
        .act => |a| switch (@as(A, @enumFromInt(a.id))) {
            .preset => {
                const p: Preset = @enumFromInt(@min(a.arg, 4));
                if (s.preset == p) return;
                applyPreset(s, c, p);
                load(s, c);
            },
            .summary => {
                if (c.slot(d_report).state != .ok or c.slot(d_report).reloading) return;
                const rows = summaryRows(c, c.data(d_report));
                statements.download(c, c.print("turf-report-{s}-{s}.csv", .{ s.from, s.to }), statements.toCsv(c.arena(), rows), "text/csv;charset=utf-8");
            },
            .shipments => c.send(@intFromEnum(A.shipments), .GET, c.orgUrl(c.print("{s}/reports/shipments?from={s}&to={s}", .{ base(c), s.from, s.to })), ""),
        },
        .done => |d| if (d.id == @intFromEnum(A.shipments) and d.ok) {
            const list = json.arr(d.v, "");
            if (list.len == 0) return c.toast(L("reports.nothing"), .info);
            const a = c.arena();
            var rows: std.ArrayList([]const []const u8) = .empty;
            var cols: std.ArrayList([]const u8) = .empty;
            if (list[0] == .object) {
                var it = list[0].object.iterator();
                while (it.next()) |kv| cols.append(a, a.dupe(u8, kv.key_ptr.*) catch "") catch {};
            }
            rows.append(a, cols.items) catch {};
            for (list) |r| {
                var cells: std.ArrayList([]const u8) = .empty;
                for (cols.items) |col| cells.append(a, cellText(a, json.get(r, col))) catch {};
                rows.append(a, cells.items) catch {};
            }
            statements.download(c, c.print("turf-shipments-{s}-{s}.csv", .{ s.from, s.to }), statements.toCsv(a, rows.items), "text/csv;charset=utf-8");
        },
        .text => |x| if (x.slot == f_from or x.slot == f_to) {
            var from = c.valTrim(f_from);
            var to = c.valTrim(f_to);
            if (!statements.validDay(from) or !statements.validDay(to)) return;
            // A period picked backwards is turned round rather than refused.
            if (std.mem.order(u8, from, to) == .gt) {
                const t = from;
                from = to;
                to = t;
                const fd = c.dupe(from);
                const td = c.dupe(to);
                c.setVal(f_from, fd);
                c.setVal(f_to, td);
                from = fd;
                to = td;
            }
            s.preset = null;
            s.from = c.dupe(from);
            s.to = c.dupe(to);
            load(s, c);
        },
        else => {},
    }
}

/// A value as JS `String(v ?? '')` writes it.
fn cellText(a: std.mem.Allocator, v: ?V) []const u8 {
    const x = v orelse return "";
    return switch (x) {
        .null => "",
        .string, .number_string => |t| t,
        .integer => |i| std.fmt.allocPrint(a, "{d}", .{i}) catch "",
        .float => |f| std.fmt.allocPrint(a, "{d}", .{f}) catch "",
        .bool => |b| if (b) "true" else "false",
        else => json.stringify(a, x),
    };
}

pub fn actions(_: *const S, _: *const Cx, ui: *Ui) void {
    const compact = kit.phone;
    kit.button(ui, if (compact) "" else L("reports.download_summary"), kit.act(A.summary, 0), .{ .icon = icons.download, .size = if (compact) .sm else .md });
    kit.button(ui, if (compact) "" else L("reports.download_shipments"), kit.act(A.shipments, 0), .{ .icon = icons.download, .size = if (compact) .sm else .md, .busy = @intFromEnum(A.shipments) });
}

// ---- Formatting ---------------------------------------------------------------------------

fn pct(a: std.mem.Allocator, v: ?f64) []const u8 {
    const x = v orelse return "—";
    return std.fmt.allocPrint(a, "{s}%", .{fmt.number(a, x, 1)}) catch "";
}

fn hours(ui: *Ui, v: ?f64) []const u8 {
    const x = v orelse return "—";
    return ui.tf(labels.english("unit.hours") orelse "{n} h", .{ .n = fmt.number(ui.arena(), x, 1) });
}

/// "4.6 / 5 (12)" plus problems reported by recipients.
fn rating(ui: *Ui, r: V) []const u8 {
    const avg = json.num(r, "avgRating");
    const problems = json.numOr(r, "problems", 0);
    if (avg == null and problems == 0) return "—";
    var out: std.ArrayList(u8) = .empty;
    const a = ui.arena();
    if (avg) |x| out.print(a, "{s} / 5 ({d})", .{ fmt.number(a, x, 1), json.int(r, "ratings") }) catch {};
    if (problems != 0) {
        if (out.items.len > 0) out.appendSlice(a, " · ") catch {};
        out.appendSlice(a, ui.tf(labels.english("reports.problems_n") orelse "{n}", .{ .n = @as(i64, @intFromFloat(problems)) })) catch {};
    }
    return out.items;
}

fn num(a: std.mem.Allocator, v: ?V, path: []const u8) []const u8 {
    return fmt.number(a, json.numOr(v, path, 0), 0);
}

// ---- View ---------------------------------------------------------------------------------

pub fn view(s: *const S, c: *const Cx, ui: *Ui) void {
    kit.stack(ui);
    period(s, ui);
    const sl = c.slot(d_report);
    if (sl.state == .idle or sl.state == .loading or sl.reloading) {
        kit.loading(ui);
    } else if (sl.state == .failed or sl.err.len > 0) {
        kit.noticeBegin(ui, .warn, icons.warning);
        kit.text(ui, sl.err, .{});
        kit.noticeEnd(ui);
    } else render(c, ui, c.data(d_report));
    ui.end();
}

/// The period: presets, from and to, the hint.
fn period(s: *const S, ui: *Ui) void {
    const presets = [_]Preset{ .d7, .d30, .month, .last_month, .year };
    kit.card(ui, .{ .gap = 12 });
    var w = kit.Wrap.begin(ui, kit.width - 40, 6.4);
    for (presets) |p| {
        const lbl = labels.of("reports.", @tagName(p));
        w.item(kit.estimate(lbl, 13.4) + 30.4);
        kit.chip(ui, lbl, s.preset == p, kit.act(A.preset, @intFromEnum(p)));
    }
    w.end();
    const wide = kit.width > 640;
    ui.begin(.{ .direction = if (wide) .row else .column, .gap = 12, .align_items = if (wide) .end else .stretch }, .{});
    ui.begin(.{ .width = if (wide) .{ .px = 190 } else .fill }, .{});
    kit.field(ui, L("reports.from"), f_from, .{ .input = .{ .placeholder = "YYYY-MM-DD", .ltr = true } });
    ui.end();
    ui.begin(.{ .width = if (wide) .{ .px = 190 } else .fill }, .{});
    kit.field(ui, L("reports.to"), f_to, .{ .input = .{ .placeholder = "YYYY-MM-DD", .ltr = true } });
    ui.end();
    ui.begin(.{ .direction = .row, .gap = 4.8, .align_items = .center, .grow = 1, .padding = .{ .bottom = if (wide) 13 else 0 } }, .{});
    kit.icon(ui, icons.info, 16, kit.k.ink_2);
    ui.text(L("reports.period_hint"), .{ .font_size = 13.6, .color = kit.k.ink_2, .grow = 1 });
    ui.end();
    ui.end();
    kit.endCard(ui, .{});
}

const StatItem = struct { label: []const u8, value: []const u8, alert: bool = false };

fn render(c: *const Cx, ui: *Ui, r: ?V) void {
    const a = ui.arena();
    const tt = json.obj(r, "totals");
    const by_courier = json.arr(r, "byCourier");
    if (json.numOr(tt, "total", 0) == 0 and by_courier.len == 0) return kit.empty(ui, L("reports.nothing"));

    var stats: std.ArrayList(StatItem) = .empty;
    const rate = json.num(tt, "deliveryRate");
    stats.append(a, .{ .label = L("reports.total"), .value = num(a, tt, "total") }) catch {};
    stats.append(a, .{ .label = L("reports.delivered"), .value = num(a, tt, "delivered") }) catch {};
    stats.append(a, .{ .label = L("reports.delivery_rate"), .value = pct(a, rate) }) catch {};
    stats.append(a, .{ .label = L("reports.on_time"), .value = pct(a, json.num(tt, "onTimeRate")) }) catch {};
    stats.append(a, .{ .label = L("reports.first_attempt"), .value = pct(a, json.num(tt, "firstAttemptRate")) }) catch {};
    stats.append(a, .{ .label = L("reports.avg_time"), .value = hours(ui, json.num(tt, "avgHours")) }) catch {};
    stats.append(a, .{ .label = L("reports.returned"), .value = num(a, tt, "returned"), .alert = json.numOr(tt, "returned", 0) > 0 and rate != null and rate.? < 85 }) catch {};
    stats.append(a, .{ .label = L("reports.open"), .value = num(a, tt, "open") }) catch {};
    const ratings = json.int(tt, "ratings");
    if (ratings != 0) stats.append(a, .{ .label = ui.tf(labels.english("reports.rating_n") orelse "{n}", .{ .n = ratings }), .value = kit.f(ui, "{s} / 5", .{fmt.number(a, json.numOr(tt, "avgRating", 0), 1)}) }) catch {};
    if (json.numOr(tt, "problems", 0) != 0) stats.append(a, .{ .label = L("reports.problems"), .value = num(a, tt, "problems"), .alert = true }) catch {};
    for (json.arr(r, "money")) |m| stats.append(a, .{
        .label = ui.tf(labels.english(if (c.isCarrier()) "reports.revenue" else "reports.spend") orelse "{n}", .{ .n = json.int(m, "count") }),
        .value = fmt.money(a, json.num(m, "amount"), json.str(m, "currency")),
    }) catch {};
    var g = kit.grid(ui, stats.items.len, 4);
    for (stats.items) |x| {
        g.cell();
        kit.stat(ui, x.label, x.value, .{ .alert = x.alert });
        g.endCell();
    }
    g.end();

    const days = json.arr(r, "byDay");
    if (days.len > 1) dayChart(ui, days);

    const cod = json.arr(r, "cod");
    if (cod.len > 0) {
        kit.card(ui, .{ .gap = 8.8 });
        kit.h2(ui, L("reports.cod"));
        var tb = kit.Table.begin(ui, &.{ .{ .label = L("reports.currency") }, .{ .label = L("reports.cod_expected") }, .{ .label = L("reports.cod_collected") }, .{ .label = L("reports.cod_settled") }, .{ .label = L("reports.cod_remitted") } });
        for (cod, 0..) |x, i| {
            tb.row(null, zui.key(i + 1));
            tb.cell(false);
            kit.text(ui, json.str(x, "currency"), .{});
            tb.endCell();
            inline for (.{ "expected", "collected", "settled", "remitted" }) |key| {
                tb.cell(true);
                kit.text(ui, fmt.money(a, json.num(x, key), json.str(x, "currency")), .{});
                tb.endCell();
            }
            tb.endRow();
        }
        tb.end();
        kit.endCard(ui, .{});
    }
    const by_carrier = json.arr(r, "byCarrier");
    if (by_carrier.len > 0) section(c, ui, L("reports.by_carrier"), by_carrier, L("reports.carrier"), .name);
    if (by_courier.len > 0) {
        kit.card(ui, .{ .gap = 8.8 });
        kit.h2(ui, L("reports.by_courier"));
        courierTable(c, ui, by_courier);
        kit.endCard(ui, .{});
    }
    const by_gov = json.arr(r, "byGovernorate");
    if (by_gov.len > 0) section(c, ui, L("reports.by_governorate"), by_gov, L("reports.governorate"), .governorate);
    const by_zone = json.arr(r, "byZone");
    if (by_zone.len > 1) section(c, ui, L("reports.by_zone"), by_zone, L("reports.zone"), .zone);
}

const First = enum { name, governorate, zone };

fn firstValue(c: *const Cx, x: V, first: First) []const u8 {
    return switch (first) {
        .name => json.str(x, "name"),
        .governorate => parts.gov(c, json.str(x, "governorate")),
        .zone => labels.of("reports.zone_", json.str(x, "zone")),
    };
}

fn section(c: *const Cx, ui: *Ui, heading: []const u8, rows: []const V, first_label: []const u8, first: First) void {
    kit.card(ui, .{ .gap = 8.8 });
    kit.h2(ui, heading);
    rateTable(c, ui, rows, first_label, first);
    kit.endCard(ui, .{});
}

fn rateTable(c: *const Cx, ui: *Ui, rows: []const V, first_label: []const u8, first: First) void {
    const a = ui.arena();
    var tb = kit.Table.begin(ui, &.{
        .{ .label = first_label, .grow = 1.4 },
        .{ .label = L("reports.total") },
        .{ .label = L("reports.delivered") },
        .{ .label = L("reports.returned") },
        .{ .label = L("reports.delivery_rate") },
        .{ .label = L("reports.on_time") },
        .{ .label = L("reports.avg_time") },
        .{ .label = L("reports.rating"), .grow = 1.3 },
    });
    for (rows, 0..) |x, i| {
        tb.row(null, zui.key(i + 1));
        tb.cell(false);
        kit.strong(ui, firstValue(c, x, first));
        tb.endCell();
        const cells = [_][]const u8{ num(a, x, "total"), num(a, x, "delivered"), num(a, x, "returned"), pct(a, json.num(x, "deliveryRate")), pct(a, json.num(x, "onTimeRate")), hours(ui, json.num(x, "avgHours")), rating(ui, x) };
        for (cells) |v| {
            tb.cell(true);
            kit.text(ui, v, .{});
            tb.endCell();
        }
        tb.endRow();
    }
    tb.end();
}

fn courierTable(c: *const Cx, ui: *Ui, rows: []const V) void {
    const a = ui.arena();
    var paid = false;
    for (rows) |r| if (json.numOr(r, "pay", 0) > 0) {
        paid = true;
    };
    const currency = json.str(c.orgV(), "carrier.currency");
    var cols: std.ArrayList(kit.Table.Col) = .empty;
    cols.append(a, .{ .label = L("reports.courier"), .grow = 1.4 }) catch {};
    inline for (.{ "deliveries", "pickups", "failed", "success_rate", "on_time" }) |key| cols.append(a, .{ .label = L("reports." ++ key) }) catch {};
    cols.append(a, .{ .label = L("reports.rating"), .grow = 1.3 }) catch {};
    if (paid) cols.append(a, .{ .label = L("reports.pay") }) catch {};
    var tb = kit.Table.begin(ui, cols.items);
    for (rows, 0..) |x, i| {
        tb.row(null, zui.key(i + 1));
        tb.cell(false);
        kit.strong(ui, json.str(x, "name"));
        tb.endCell();
        const cells = [_][]const u8{ num(a, x, "deliveries"), num(a, x, "pickups"), num(a, x, "failed"), pct(a, json.num(x, "successRate")), pct(a, json.num(x, "onTimeRate")), rating(ui, x) };
        for (cells) |v| {
            tb.cell(true);
            kit.text(ui, v, .{});
            tb.endCell();
        }
        if (paid) {
            tb.cell(true);
            kit.text(ui, fmt.money(a, json.numOr(x, "pay", 0), currency), .{});
            tb.endCell();
        }
        tb.endRow();
    }
    tb.end();
}

/// Daily bars: created (light) and delivered (solid), drawn with views.
fn dayChart(ui: *Ui, days: []const V) void {
    const k = kit.k;
    var max: f64 = 1;
    for (days) |d| max = @max(max, json.numOr(d, "created", 0));
    kit.card(ui, .{ .gap = 8.8 });
    ui.begin(.{ .direction = .row, .align_items = .center, .justify = .space_between, .gap = 8 }, .{});
    kit.h2(ui, L("reports.per_day"));
    ui.begin(.{ .direction = .row, .align_items = .center, .gap = 6.4 }, .{});
    legend(ui, k.accent_soft);
    kit.small(ui, L("reports.created"));
    legend(ui, k.a);
    kit.small(ui, L("reports.delivered"));
    ui.end();
    ui.end();

    const n: f32 = @floatFromInt(days.len);
    const avail = kit.width - 40;
    const colw = @max(2, (avail - 2 * (n - 1)) / n);
    const h: f32 = 160 - 17.6;
    const ticks = days.len <= 62;
    ui.begin(.{ .clip = true }, .{});
    ui.begin(.{ .direction = .row, .gap = 2, .align_items = .end, .height = .{ .px = 160 }, .padding = .{ .bottom = 17.6 } }, .{});
    for (days, 0..) |d, i| {
        const created: f32 = @floatCast(json.numOr(d, "created", 0) / max);
        const delivered: f32 = @floatCast(json.numOr(d, "delivered", 0) / max);
        ui.begin(.{ .width = .{ .px = colw }, .height = .{ .px = h } }, .{ .key = zui.key(i + 1) });
        ui.begin(.{ .position = .absolute, .inset = .{ .bottom = 0, .start = 0 }, .width = .{ .px = colw }, .height = .{ .px = @max(1, created * h) }, .radius = @min(4, colw / 2), .background = k.accent_soft }, .{});
        ui.end();
        ui.begin(.{ .position = .absolute, .inset = .{ .bottom = 0, .start = colw * 0.2 }, .width = .{ .px = colw * 0.6 }, .height = .{ .px = @max(1, delivered * h) }, .radius = @min(4, colw * 0.3), .background = k.a }, .{});
        ui.end();
        const day = json.str(d, "day");
        if (ticks and day.len >= 10) {
            ui.text(day[8..10], .{ .position = .absolute, .inset = .{ .bottom = -17.6, .start = colw / 2 - 10 }, .width = .{ .px = 20 }, .text_align = .center, .font_size = 10.4, .color = k.ink_3 });
        }
        ui.end();
    }
    ui.end();
    ui.end();
    kit.endCard(ui, .{});
}

fn legend(ui: *Ui, color: zui.Color) void {
    ui.begin(.{ .width = .{ .px = 11.2 }, .height = .{ .px = 11.2 }, .radius = 3, .background = color }, .{});
    ui.end();
}

/// The summary as one CSV: a block per table, separated by an empty line.
fn summaryRows(c: *Cx, r: ?V) []const []const []const u8 {
    const a = c.arena();
    var rows: std.ArrayList([]const []const u8) = .empty;
    const rate_cols = [_][]const u8{ "total", "delivered", "returned", "cancelled", "lost", "open", "deliveryRate", "onTimeRate", "firstAttemptRate", "avgHours", "avgRating", "ratings", "problems" };
    const Row = struct {
        fn of(al: std.mem.Allocator, first: []const u8, v: ?V, cols: []const []const u8) []const []const u8 {
            var out: std.ArrayList([]const u8) = .empty;
            out.append(al, first) catch {};
            for (cols) |col| out.append(al, cellText(al, json.get(v, col))) catch {};
            return out.items;
        }
        fn head(al: std.mem.Allocator, first: []const u8, cols: []const []const u8) []const []const u8 {
            var out: std.ArrayList([]const u8) = .empty;
            out.append(al, first) catch {};
            out.appendSlice(al, cols) catch {};
            return out.items;
        }
    };
    const empty: []const []const u8 = &.{};
    rows.append(a, a.dupe([]const u8, &.{ L("reports.title"), json.str(r, "from"), json.str(r, "to") }) catch empty) catch {};
    rows.append(a, empty) catch {};
    rows.append(a, Row.head(a, L("reports.totals"), &rate_cols)) catch {};
    rows.append(a, Row.of(a, "", json.get(r, "totals"), &rate_cols)) catch {};
    rows.append(a, empty) catch {};
    const by_carrier = json.arr(r, "byCarrier");
    if (by_carrier.len > 0) {
        rows.append(a, Row.head(a, L("reports.carrier"), &rate_cols)) catch {};
        for (by_carrier) |x| rows.append(a, Row.of(a, json.str(x, "name"), x, &rate_cols)) catch {};
        rows.append(a, empty) catch {};
    }
    const by_courier = json.arr(r, "byCourier");
    if (by_courier.len > 0) {
        var cols: std.ArrayList([]const u8) = .empty;
        cols.appendSlice(a, &.{ "tasks", "deliveries", "pickups", "failed", "parcels", "successRate", "onTimeRate", "avgRating", "ratings", "problems" }) catch {};
        if (json.has(r, "money")) cols.append(a, "pay") catch {};
        rows.append(a, Row.head(a, L("reports.courier"), cols.items)) catch {};
        for (by_courier) |x| rows.append(a, Row.of(a, json.str(x, "name"), x, cols.items)) catch {};
        rows.append(a, empty) catch {};
    }
    rows.append(a, Row.head(a, L("reports.governorate"), &rate_cols)) catch {};
    for (json.arr(r, "byGovernorate")) |x| rows.append(a, Row.of(a, parts.gov(c, json.str(x, "governorate")), x, &rate_cols)) catch {};
    rows.append(a, empty) catch {};
    const cod = json.arr(r, "cod");
    if (cod.len > 0) {
        const cols = [_][]const u8{ "expected", "collected", "settled", "remitted" };
        rows.append(a, Row.head(a, L("reports.cod"), &cols)) catch {};
        for (cod) |x| rows.append(a, Row.of(a, json.str(x, "currency"), x, &cols)) catch {};
        rows.append(a, empty) catch {};
    }
    const money = json.arr(r, "money");
    if (money.len > 0) {
        rows.append(a, Row.head(a, L(if (c.isCarrier()) "reports.revenue_plain" else "reports.spend_plain"), &.{ "amount", "shipments" })) catch {};
        for (money) |m| rows.append(a, a.dupe([]const u8, &.{ json.str(m, "currency"), cellText(a, json.get(m, "amount")), cellText(a, json.get(m, "count")) }) catch empty) catch {};
        rows.append(a, empty) catch {};
    }
    rows.append(a, a.dupe([]const u8, &.{ "day", "created", "delivered" }) catch empty) catch {};
    for (json.arr(r, "byDay")) |d| rows.append(a, a.dupe([]const u8, &.{ json.str(d, "day"), cellText(a, json.get(d, "created")), cellText(a, json.get(d, "delivered")) }) catch empty) catch {};
    return rows.items;
}

// ---- Tests --------------------------------------------------------------------------------

const testing = std.testing;
const app = @import("../app.zig");

test "reports: presets" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 2026-03-02 22:30 UTC is already 3 March in Damascus.
    const now = fmt.parseIso("2026-03-02T22:30:00Z").?;
    try testing.expectEqualStrings("2026-03-03", range(a, .month, now)[1]);
    try testing.expectEqualStrings("2026-03-01", range(a, .month, now)[0]);
    try testing.expectEqualStrings("2026-02-01", range(a, .last_month, now)[0]);
    try testing.expectEqualStrings("2026-02-28", range(a, .last_month, now)[1]);
    try testing.expectEqualStrings("2026-02-25", range(a, .d7, now)[0]);
    try testing.expectEqualStrings("2026-01-01", range(a, .year, now)[0]);
}

const report_json =
    \\{"from":"2025-09-13","to":"2025-10-12","totals":{"total":12,"delivered":9,"returned":1,"open":2,"deliveryRate":75,"onTimeRate":88.9,"firstAttemptRate":80,"avgHours":20.5,"avgRating":4.5,"ratings":2,"problems":1},
    \\ "money":[{"currency":"SYP","amount":60000,"count":9}],"byDay":[{"day":"2025-10-11","created":5,"delivered":3},{"day":"2025-10-12","created":7,"delivered":6}],
    \\ "cod":[{"currency":"SYP","expected":10000,"collected":8000,"settled":5000,"remitted":0}],
    \\ "byCourier":[{"name":"Omar","deliveries":9,"pickups":3,"failed":1,"successRate":90,"onTimeRate":88.9,"pay":1500}],
    \\ "byGovernorate":[{"governorate":"DAM","total":12,"delivered":9,"returned":1,"deliveryRate":75}],"byZone":[{"zone":"local","total":12}]}
;

test "reports: the period, numbers, tables and the summary CSV" {
    app.D.startWith(1280, 900, "/o/fast/reports");
    defer app.D.reset();
    try testing.expect(app.D.respond("/api/app/me", 200, @import("c_dashboard.zig").carrier_me));
    try testing.expect(app.D.respond("/api/app/meta", 200, app.meta_json));
    try testing.expect(app.D.respond("/api/app/orgs/o2", 200,
        \\{"id":"o2","type":"carrier","name":"Fast Express","slug":"fast","status":"active","carrier":{"currency":"SYP"},"me":{"permissions":["finance.view"]}}
    ));
    try testing.expect(app.D.respond("/api/app/orgs/o2/carrier/reports?from=2025-09-13&to=2025-10-12", 200, report_json));
    try testing.expect(app.D.findText("75%") != 0);
    try testing.expect(app.D.findText("20.5 h") != 0);
    try testing.expect(app.D.findText("Revenue (9 shipments)") != 0);
    try testing.expect(app.D.findText("4.5 / 5") != 0);
    try testing.expect(app.D.findText("Omar") != 0);
    try testing.expect(app.D.findText("1,500 SYP") != 0);
    try testing.expect(app.D.findText("Damascus") != 0);
    try testing.expect(app.D.findText("12") != 0);
    try app.D.press("Download summary (CSV)");
    try testing.expect(std.mem.eql(u8, zui.host.saved_name.items, "turf-report-2025-09-13-2025-10-12.csv"));
    // Another preset loads that period.
    try app.D.press("Last 7 days");
    try testing.expect(app.D.pending("/carrier/reports?from=2025-10-06&to=2025-10-12") != null);
    // A period typed backwards is turned round.
    try app.D.typeInto("YYYY-MM-DD", "2025-12-01");
    try testing.expect(app.D.pending("/carrier/reports?from=2025-10-12&to=2025-12-01") != null or app.D.pending("/carrier/reports?from=2025-10-06&to=2025-12-01") != null);
    // One row per shipment.
    try app.D.press("Download shipments (CSV)");
    try testing.expect(app.D.respond("/carrier/reports/shipments", 200, "[{\"trackingNumber\":\"TRF1\",\"cod\":null,\"fee\":2.5}]"));
    try testing.expect(std.mem.indexOf(u8, zui.host.saved_data.items, "trackingNumber,cod,fee\r\nTRF1,,2.5") != null);
}
