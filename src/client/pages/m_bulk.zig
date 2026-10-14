//! Upload many shipments from a CSV file, then print all their labels at once (Turf-js
//! views/merchant/bulk.js). The file comes from the web page around the app ("pick-file"); the
//! template and the report are offered as downloads ("download"). Phones cannot pick files.

const std = @import("std");
const zui = @import("zui");
const core = @import("../core.zig");
const kit = @import("../kit.zig");
const json = @import("../json.zig");
const icons = @import("../icons.zig");
const labels = @import("../labels.zig");
const csv = @import("../widgets/csv.zig");

const Cx = core.Cx;
const Ui = core.Ui;
const V = json.V;
const L = labels.k;
const t = core.t;

const d_result: u8 = 0;
const file_id: u16 = 1;

const A = enum(u16) { template = 1, pick, upload, report };

/// The same columns the server reads (CSV_COLUMNS in the server's bulk service).
const columns = [_][]const u8{
    "reference",   "recipient_name", "recipient_phone", "governorate", "city",  "area",   "street",    "details",  "lat", "lng",
    "weight_kg",   "pieces",         "description",     "value",       "cod_amount", "fragile", "notes", "carrier", "strategy",
    "length_cm",   "width_cm",       "height_cm",       "pickup",      "service",
};
const example = [_][]const u8{ "ORD-1001", "لينا حداد", "0944111222", "دمشق", "دمشق", "المالكي", "شارع أبو رمانة", "الطابق الثالث", "", "", "1.5", "1", "كتب", "", "25000", "no", "", "auto", "", "", "", "", "", "standard" };
const max_rows = 500;

const Preview = enum { none, ready, empty, missing, too_many };

pub const S = struct {
    file_name: []const u8 = "",
    rows: csv.Table = .{},
    preview: Preview = .none,
    missing: []const u8 = "",
    /// The rows of the last upload (the report reads them even after another file is picked).
    sent: csv.Table = .{},
    has_result: bool = false,
};

pub fn title(_: *const S, _: *const Cx) []const u8 {
    return L("bulk.title");
}

pub fn enter(_: *S, c: *Cx) void {
    @import("../app.zig").reloadOrg(c);
}

/// Columns the file lacks: a phone and a weight, and a pin (lat + lng) or a governorate + city.
fn missingColumns(c: *Cx, tb: csv.Table) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    const a = c.arena();
    const add = struct {
        fn f(o: *std.ArrayList(u8), al: std.mem.Allocator, name: []const u8) void {
            if (o.items.len > 0) o.appendSlice(al, ", ") catch {};
            o.appendSlice(al, name) catch {};
        }
    }.f;
    for ([_][]const u8{ "recipient_phone", "weight_kg" }) |x| if (!tb.has(x)) add(&out, a, x);
    if (!(tb.has("lat") and tb.has("lng"))) for ([_][]const u8{ "governorate", "city" }) |x| if (!tb.has(x)) add(&out, a, x);
    return out.items;
}

/// Offers a file to save (a download on the web, the share sheet on the phones).
fn repeatedLater(headers: []const []const u8, j: usize) bool {
    for (headers[j + 1 ..]) |h| if (std.mem.eql(u8, h, headers[j])) return true;
    return false;
}

fn download(c: *Cx, name: []const u8, text: []const u8) void {
    c.saveFile(name, "text/csv", text);
}

/// A failed row's error in the user's language (the server's English text when there is no
/// translation).
fn rowError(a: std.mem.Allocator, e: ?V) []const u8 {
    var m: std.json.ObjectMap = .empty;
    m.put(a, "error", e orelse .null) catch {};
    return core.errorMessage(a, 400, .{ .object = m }, true);
}

fn results(c: *const Cx) []const V {
    return json.arr(c.data(d_result), "results");
}

pub fn update(s: *S, c: *Cx, e: core.Ev) void {
    switch (e) {
        .act => |x| switch (@as(A, @enumFromInt(x.id))) {
            .template => download(c, "turf-shipments-template.csv", csv.write(c.arena(), &.{ &columns, &example })),
            .pick => c.pickFile(file_id, ".csv,text/csv"),
            .upload => {
                var b = json.Obj.init(c.arena());
                b.beginArray("rows");
                for (s.rows.rows, 0..) |_, i| {
                    b.begin("");
                    // One key per header name (a repeated header: the last one, as Object.fromEntries).
                    for (s.rows.headers, 0..) |h, j| if (!repeatedLater(s.rows.headers, j)) b.str(h, s.rows.get(i, h));
                    b.end();
                }
                b.endArray();
                s.sent = s.rows;
                c.send(@intFromEnum(A.upload), .POST, c.orgUrl("/merchant/shipments/bulk"), b.done());
            },
            .report => {
                const a = c.arena();
                var rows: std.ArrayList([]const []const u8) = .empty;
                rows.append(a, &.{ "row", "result", "tracking_number", "reference", "error_field", "error" }) catch {};
                for (results(c)) |r| {
                    const row = json.int(r, "row");
                    const n = c.print("{d}", .{row});
                    if (json.boolean(r, "ok")) {
                        rows.append(a, a.dupe([]const u8, &.{ n, "ok", json.str(r, "shipment.trackingNumber"), json.str(r, "shipment.reference"), "", "" }) catch &.{}) catch {};
                    } else {
                        const ref = if (row >= 1 and row <= s.sent.rows.len) s.sent.get(@intCast(row - 1), "reference") else "";
                        rows.append(a, a.dupe([]const u8, &.{ n, "error", "", ref, json.str(r, "error.field"), rowError(a, json.get(r, "error")) }) catch &.{}) catch {};
                    }
                }
                download(c, "turf-upload-report.csv", csv.write(a, rows.items));
            },
        },
        .file => |f| if (f.id == file_id) {
            s.has_result = false;
            s.file_name = c.dupe(f.name);
            s.rows = csv.parse(c.arena(), f.data);
            s.missing = if (s.rows.rows.len > 0) missingColumns(c, s.rows) else "";
            s.preview = if (s.rows.rows.len == 0) .empty else if (s.missing.len > 0) .missing else if (s.rows.rows.len > max_rows) .too_many else .ready;
        },
        .done => |d| if (d.id == @intFromEnum(A.upload) and d.ok) {
            s.preview = .none;
            s.file_name = "";
            s.rows = .{};
            const slot = &c.slots[d_result];
            slot.reset();
            slot.value = json.parse(slot.arena.allocator(), d.body);
            slot.state = .ok;
            s.has_result = true;
            const failed = json.int(d.v, "failed");
            c.toast(zui.i18n.tf(c.arena(), labels.english("bulk.done") orelse "{created} {failed}", .{ .created = json.int(d.v, "created"), .failed = failed }), if (failed > 0) .err else .ok);
        },
        else => {},
    }
}

pub fn view(s: *const S, c: *const Cx, ui: *Ui) void {
    const k = kit.k;
    const outer = kit.width;
    kit.width = @min(outer, 960);
    defer kit.width = outer;
    ui.begin(.{ .gap = 16, .width = .{ .px = kit.width } }, .{});
    if (json.arr(c.orgV(), "merchant.places").len == 0) {
        kit.noticeBegin(ui, .warn, icons.warning);
        kit.text(ui, L("bulk.need_pickup"), .{});
        kit.link(ui, L("nav.settings"), .{ .go = "/settings" }, .{});
        kit.noticeEnd(ui);
    }
    const web = zui.platform == .web or zui.platform == .headless;

    kit.card(ui, .{ .gap = 16 });
    kit.h2(ui, L("bulk.step1"));
    kit.muted(ui, L("bulk.step1_text"));
    ui.begin(.{ .direction = .row }, .{});
    // Phones save it through the share sheet.
    kit.button(ui, L("bulk.template"), kit.act(A.template, 0), .{ .icon = icons.download });
    ui.end();
    kit.small(ui, L("bulk.columns_help"));
    kit.endCard(ui, .{});

    kit.card(ui, .{ .gap = 16 });
    kit.h2(ui, L("bulk.step2"));
    if (!web) kit.notice(ui, .warn, t("Choosing a file works in the web app only."));
    kit.row(ui);
    kit.button(ui, t("Choose a CSV file"), kit.act(A.pick, 0), .{ .icon = icons.add, .disabled = !web });
    if (s.file_name.len > 0) ui.text(s.file_name, .{ .font_size = 13.6, .color = k.ink_2, .grow = 1, .max_lines = 1 });
    ui.end();
    switch (s.preview) {
        .none => {},
        .empty => kit.notice(ui, .err, L("bulk.empty")),
        .missing => kit.notice(ui, .err, ui.tf(labels.english("bulk.missing_columns") orelse "{columns}", .{ .columns = s.missing })),
        .too_many => kit.notice(ui, .err, ui.tf(labels.english("bulk.too_many") orelse "{n}", .{ .n = s.rows.rows.len, .max = max_rows })),
        .ready => kit.notice(ui, .info, ui.tf(labels.english("bulk.ready") orelse "{n}", .{ .n = s.rows.rows.len })),
    }
    if (s.preview == .ready) {
        ui.begin(.{ .direction = .row }, .{});
        kit.button(ui, L("bulk.upload"), kit.act(A.upload, 0), .{ .variant = .primary, .icon = icons.check, .busy = @intFromEnum(A.upload) });
        ui.end();
    }
    kit.endCard(ui, .{});

    if (s.has_result) report(c, ui);
    ui.end();
}

fn report(c: *const Cx, ui: *Ui) void {
    const k = kit.k;
    const a = ui.arena();
    const list = results(c);
    // Every created shipment's label, one per page (at most 100).
    var tokens: std.ArrayList(u8) = .empty;
    var n: usize = 0;
    for (list) |r| {
        if (!json.boolean(r, "ok")) continue;
        const url = json.str(r, "shipment.labelUrl");
        const at = std.mem.indexOf(u8, url, "/label/") orelse continue;
        const tok = url[at + 7 ..];
        if (tok.len == 0 or n == 100) continue;
        if (n > 0) tokens.append(a, ',') catch {};
        tokens.appendSlice(a, tok) catch {};
        n += 1;
    }
    kit.row(ui);
    if (n > 0) kit.button(ui, ui.tf(labels.english("bulk.print_labels") orelse "{n}", .{ .n = n }), .{ .open = kit.f(ui, "{s}/labels?t={s}", .{ core.api_base, tokens.items }) }, .{ .variant = .primary, .icon = icons.print });
    kit.button(ui, L("bulk.download_report"), kit.act(A.report, 0), .{ .icon = icons.download });
    ui.end();
    const cols = [_]kit.Table.Col{
        .{ .label = L("bulk.row"), .grow = 0.5 },
        .{ .label = L("common.status") },
        .{ .label = L("shipment.tracking_number") },
        .{ .label = L("bulk.problem"), .grow = 2 },
    };
    var tb = kit.Table.begin(ui, &cols);
    for (list, 0..) |r, i| {
        const ok = json.boolean(r, "ok");
        tb.row(null, zui.key(i + 1));
        tb.cell(false);
        kit.text(ui, kit.f(ui, "{d}", .{json.int(r, "row")}), .{});
        tb.endCell();
        tb.cell(true);
        kit.badge(ui, if (ok) L("bulk.ok") else L("bulk.failed"), if (ok) .green else .red);
        tb.endCell();
        tb.cell(true);
        if (ok) {
            kit.link(ui, json.str(r, "shipment.trackingNumber"), .{ .go = kit.f(ui, "/shipments/{s}", .{json.str(r, "shipment.id")}) }, .{ .mono = true });
        } else kit.text(ui, "—", .{});
        tb.endCell();
        tb.cell(true);
        if (!ok) {
            const field = json.str(r, "error.field");
            ui.begin(.{ .direction = .row, .gap = 6, .align_items = .start }, .{});
            if (field.len > 0) ui.text(field, .{ .font_size = 13.6, .mono = true, .color = k.ink_2 });
            ui.text(rowError(a, json.get(r, "error")), .{ .font_size = 15, .color = k.ink, .grow = 1 });
            ui.end();
        }
        tb.endCell();
        tb.endRow();
    }
    tb.end();
}

// ---- Tests ------------------------------------------------------------------------------------

const app = @import("../app.zig");
const testing = std.testing;
const m_new = @import("m_new.zig");

test {
    _ = csv;
}

test "bulk upload: a file, the upload, the report" {
    try app.startSignedIn("/o/acme/shipments/bulk");
    defer app.D.reset();
    try testing.expect(app.D.respond("/api/app/orgs/o1", 200, m_new.merchant_org));
    try testing.expect(app.D.respond("/api/app/orgs/o1", 200, m_new.merchant_org));
    try app.D.press(L("bulk.template"));
    try testing.expectEqualStrings("turf-shipments-template.csv", zui.host.saved_name.items);
    try app.D.press(t("Choose a CSV file"));
    try testing.expectEqualStrings(".csv,text/csv", zui.host.file_accept.?);
    app.D.R.dispatch(.{ .file_picked = .{ .name = "x.csv", .data = "recipient_phone,city\n0944,Damascus\n" } });
    try testing.expect(app.D.findText(app.D.R.appState().page.m_bulk.missing) == 0);
    try testing.expect(app.D.findText(L("bulk.upload")) == 0);
    app.D.R.dispatch(.{ .file_picked = .{ .name = "x.csv", .data = "reference,recipient_phone,weight_kg,lat,lng\nA1,0944,1,33.5,36.3\nA2,0955,2,33.5,36.3\n" } });
    try app.D.press(L("bulk.upload"));
    const b = m_new.lastFetch("/merchant/shipments/bulk").?;
    try testing.expect(m_new.has(b.body, "{\"rows\":[{\"reference\":\"A1\",\"recipient_phone\":\"0944\""));
    try testing.expect(app.D.respond("/merchant/shipments/bulk", 200,
        \\{"created":1,"failed":1,"results":[{"row":1,"ok":true,"shipment":{"id":"s1","trackingNumber":"TRF-1","labelUrl":"/o/acme/label/tok1"}},{"row":2,"ok":false,"error":{"code":"x_test","field":"recipient_phone","message":"Bad phone"}}]}
    ));
    try testing.expect(app.D.findText("TRF-1") != 0);
    try testing.expect(app.D.findText("Bad phone") != 0);
    try app.D.press(L("bulk.download_report"));
    try testing.expect(m_new.has(zui.host.saved_data.items, "2,error,,A2,recipient_phone,Bad phone"));
}
