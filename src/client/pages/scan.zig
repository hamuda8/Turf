//! Hub check-in (Turf-js views/carrier/scan.js): scan parcels into a hub with a USB/Bluetooth
//! scanner (it types the code and Enter), by typing/pasting the code, or with the phone's back
//! camera: zui's barcode scanner (fx.scanBarcode) reads Code 128 and QR labels, as Turf-js's
//! BarcodeDetector did, and only Turf tracking numbers (TRF…) are checked in; one label seen again
//! within 4 s is not sent twice.

const std = @import("std");
const zui = @import("zui");
const core = @import("../core.zig");
const kit = @import("../kit.zig");
const json = @import("../json.zig");
const fmt = @import("../fmt.zig");
const icons = @import("../icons.zig");
const labels = @import("../labels.zig");
const parts = @import("../widgets/parts.zig");
const cm = @import("../widgets/common.zig");

const Cx = core.Cx;
const Ui = core.Ui;
const V = json.V;
const L = labels.k;
const eq = std.mem.eql;

const d_hubs: u8 = 0;
const f_hub: u16 = 0;
const f_code: u16 = 1;
const max_log = 200;

const A = enum(u16) { check_in = 1, submit, inside, camera };

/// A label the camera keeps seeing is sent once per this many milliseconds.
const camera_repeat_ms = 4000;

const Entry = struct {
    seq: u32,
    tn: []const u8,
    sending: bool = true,
    ok: bool = false,
    at: []const u8 = "",
    id: []const u8 = "",
    status: []const u8 = "",
    to: []const u8 = "",
    err: []const u8 = "",
};

pub const S = struct {
    log: std.ArrayList(Entry) = .empty,
    seq: u32 = 0,
    /// The camera scanner (fx.scanBarcode), 0 when off.
    scanner: u32 = 0,
    camera: enum { off, starting, on } = .off,
    camera_error: []const u8 = "",
    /// When each code was last read by the camera (ms).
    recent: std.StringHashMapUnmanaged(i64) = .empty,
};

fn onScan(e: zui.ScanEvent) core.Msg {
    return .{ .scan = e };
}

fn stopCamera(s: *S, c: *Cx) void {
    if (s.scanner != 0) c.fx.stopScan(s.scanner);
    s.scanner = 0;
    s.camera = .off;
}

/// Leaving the page turns the camera off.
pub fn leave(s: *S, c: *Cx) void {
    stopCamera(s, c);
}

pub fn title(_: *const S, _: *const Cx) []const u8 {
    return L("nav.scan");
}

pub fn enter(_: *S, c: *Cx) void {
    c.load(d_hubs, c.orgUrl("/carrier/hubs"));
    c.quietErrors(@intFromEnum(A.check_in));
}

fn activeHubs(c: *const Cx, a: std.mem.Allocator) []const V {
    var out: std.ArrayList(V) = .empty;
    for (json.arr(c.data(d_hubs), "")) |h| if (json.boolean(h, "active")) out.append(a, h) catch {};
    return out.items;
}

fn storeKey(c: *Cx) []const u8 {
    return c.print("turf.scanHub.{s}", .{c.orgId()});
}

/// "TRF-12 ab" -> "TRF12AB".
fn clean(a: std.mem.Allocator, raw: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (raw) |ch| {
        const u = std.ascii.toUpper(ch);
        if (std.ascii.isDigit(u) or (u >= 'A' and u <= 'Z')) out.append(a, u) catch {};
    }
    return out.items;
}

fn checkIn(s: *S, c: *Cx, raw: []const u8) void {
    const tn = clean(c.arena(), raw);
    if (tn.len == 0) return;
    // A parcel already on its way to the server.
    for (s.log.items) |x| if (x.sending and eq(u8, x.tn, tn)) return;
    s.seq += 1;
    s.log.insert(c.arena(), 0, .{ .seq = s.seq, .tn = tn }) catch return;
    // A long shift must not slow the page down.
    if (s.log.items.len > max_log) s.log.shrinkRetainingCapacity(max_log);
    var b = json.Obj.init(c.arena());
    b.str("trackingNumber", tn);
    c.sendArg(@intFromEnum(A.check_in), s.seq, .POST, c.orgUrl(c.print("/carrier/hubs/{s}/check-in", .{c.val(f_hub)})), b.done());
}

pub fn update(s: *S, c: *Cx, e: core.Ev) void {
    switch (e) {
        .data => |n| if (n == d_hubs and c.slot(d_hubs).state == .ok) {
            const hubs = activeHubs(c, c.arena());
            if (hubs.len == 0) return;
            // The remembered hub may have been closed or deactivated since.
            var chosen = cm.docId(hubs[0]);
            if (zui.storage.get(c.arena(), storeKey(c), .{})) |saved| {
                for (hubs) |h| if (eq(u8, cm.docId(h), saved)) {
                    chosen = cm.docId(h);
                };
            }
            c.setVal(f_hub, chosen);
            c.fx.focus(kit.slotKey(f_code));
        },
        .text => |x| if (x.slot == f_hub) zui.storage.set(storeKey(c), x.text, .{}),
        .act => |a| switch (@as(A, @enumFromInt(a.id))) {
            .submit => {
                const v = c.dupe(c.val(f_code));
                c.setVal(f_code, "");
                checkIn(s, c, v);
            },
            .inside => c.go(c.print("/hubs/{s}", .{c.val(f_hub)})),
            .camera => if (s.camera != .off) {
                stopCamera(s, c);
                c.fx.focus(kit.slotKey(f_code));
            } else {
                s.camera_error = "";
                s.camera = .starting;
                s.scanner = c.fx.scanBarcode(.{ .formats = .{ .code_128 = true, .qr = true }, .back_camera = true }, onScan);
            },
            .check_in => {},
        },
        .scan => |ev| if (ev.scanner == s.scanner) switch (ev.kind) {
            .started => s.camera = .on,
            .found => {
                // Only Turf tracking numbers; the camera sees the same label many times a second.
                if (ev.text.len < 3 or !std.ascii.eqlIgnoreCase(ev.text[0..3], "TRF")) return;
                const tn = clean(c.arena(), ev.text);
                const now = fmt.now();
                if (s.recent.get(tn)) |last| if (now - last < camera_repeat_ms) return;
                s.recent.put(c.arena(), c.dupe(tn), now) catch {};
                checkIn(s, c, tn);
            },
            .failed => {
                stopCamera(s, c);
                s.camera_error = if (std.mem.eql(u8, ev.data, "unsupported")) L("scan.camera_unsupported") else if (std.mem.eql(u8, ev.data, "denied")) core.t("Camera access was refused. Allow it in the settings to scan labels.") else core.t("The camera is not available right now.");
            },
        },
        .done => |d| if (d.id == @intFromEnum(A.check_in)) {
            for (s.log.items) |*x| if (x.seq == d.arg) {
                x.sending = false;
                x.ok = d.ok;
                x.at = c.dupe(fmt.isoUtc(c.arena(), fmt.now()));
                if (d.ok) {
                    x.id = c.dupe(cm.docId(d.v));
                    x.status = c.dupe(json.str(d.v, "status"));
                    x.to = c.dupe(parts.placeText(c.arena(), c, json.get(d.v, "dropoff"), .{}));
                    c.fx.vibrate(60);
                } else {
                    x.err = c.dupe(core.errorMessage(c.arena(), d.status, d.v, false));
                    c.fx.vibrate(200);
                }
                break;
            };
        },
        else => {},
    }
}

pub fn view(s: *const S, c: *const Cx, ui: *Ui) void {
    if (!kit.gate(ui, &.{d_hubs})) return;
    const hubs = activeHubs(c, ui.arena());
    if (hubs.len == 0) return kit.empty(ui, L("scan.no_hubs"));
    const k = kit.k;
    ui.begin(.{ .gap = 16, .max_width = 720 }, .{});
    kit.card(ui, .{ .gap = 16 });
    var opts: std.ArrayList(core.Opt) = .empty;
    for (hubs) |h| opts.append(ui.arena(), .{ .value = cm.docId(h), .label = kit.f(ui, "{s} ({s}) · {s}", .{ json.str(h, "name"), json.str(h, "code"), parts.gov(c, json.str(h, "governorate")) }) }) catch {};
    kit.selectField(ui, L("scan.hub"), f_hub, opts.items, .{ .required = true, .name = "hub" });
    ui.begin(.{ .direction = .row, .gap = 4.8, .align_items = .center, .pressed_opacity = 0.6, .align_self = .start }, .{ .on_press = kit.act(A.inside, 0) });
    kit.icon(ui, icons.package_2, 18, k.a);
    ui.text(L("hub.whats_inside"), .{ .font_size = 15, .weight = 600, .color = k.a });
    ui.end();
    kit.fieldBegin(ui, L("scan.tracking_number"), true);
    kit.input(ui, f_code, .{ .kind = .code, .placeholder = "TRF…", .ltr = true, .mono = true, .size = 20, .on_submit = kit.act(A.submit, 0), .name = "trackingNumber" });
    kit.fieldEnd(ui, "trackingNumber", L("scan.hint"));
    kit.rowBetween(ui);
    kit.button(ui, if (s.camera == .off) L("scan.camera") else L("scan.stop_camera"), kit.act(A.camera, 0), .{ .icon = icons.photo_camera, .disabled = s.camera == .starting });
    ui.end();
    // `.scan-video`: the camera's picture while it reads labels.
    if (s.camera == .on) ui.video(s.scanner, .{ .cover = true }, .{ .width = .fill, .height = .{ .px = @min(ui.env.height * 0.5, 420) }, .radius = 22, .background = k.c, .clip = true }, zui.key("scan-video"));
    if (s.camera_error.len > 0) kit.notice(ui, .err, s.camera_error);
    kit.endCard(ui, .{});
    kit.h2(ui, L("scan.log"));
    ui.begin(.{ .gap = 6.4 }, .{});
    for (s.log.items) |x| {
        ui.begin(.{ .direction = .row, .gap = 12, .align_items = .center, .padding = .xy(12.8, 8.8), .radius = 22, .background = k.panel, .shadow = kit.shadow1() }, .{ .key = zui.key(x.seq) });
        if (x.sending) {
            kit.mono(ui, x.tn, .{});
            kit.spinner(ui, 16, k.ink_3);
        } else {
            kit.small(ui, fmt.time(ui.arena(), x.at));
            if (x.ok) {
                kit.link(ui, x.tn, .{ .go = kit.f(ui, "/shipments/{s}", .{x.id}) }, .{ .mono = true });
                kit.statusBadge(ui, x.status);
                ui.begin(.{ .direction = .row, .gap = 4.8, .align_items = .center, .grow = 1 }, .{});
                kit.iconFlip(ui, icons.arrow_forward, 15, k.ink_2);
                kit.small(ui, x.to);
                ui.end();
            } else {
                kit.mono(ui, x.tn, .{});
                kit.badge(ui, x.err, .red);
            }
        }
        ui.end();
    }
    ui.end();
    ui.end();
}

// ---- Tests --------------------------------------------------------------------------------

const app = @import("../app.zig");
const testing = std.testing;
const dispatch = @import("dispatch.zig");

test "scan: check parcels in by typing their codes" {
    try dispatch.openCarrier("/scan");
    defer app.D.reset();
    try testing.expect(app.D.respond("/carrier/hubs", 200, "[{\"_id\":\"h1\",\"name\":\"Main\",\"code\":\"DAM1\",\"governorate\":\"DAM\",\"active\":true}]"));
    try app.D.typeInto("TRF…", "trf-100 ");
    try app.D.inputEvent("TRF…", .submit);
    const req = zui.host.fetches.items[zui.host.fetches.items.len - 1];
    try testing.expect(std.mem.endsWith(u8, req.url, "/carrier/hubs/h1/check-in"));
    try testing.expect(std.mem.indexOf(u8, req.body, "\"trackingNumber\":\"TRF100\"") != null);
    try testing.expect(app.D.respond("/check-in", 200, "{\"_id\":\"s1\",\"status\":\"at_hub\",\"dropoff\":{\"city\":\"Homs\",\"governorate\":\"HI\"}}"));
    try testing.expect(app.D.findText("TRF100") != 0);
    try testing.expect(app.D.findText("Homs · HI") != 0);
    try app.D.typeInto("TRF…", "TRF200");
    try app.D.inputEvent("TRF…", .submit);
    try testing.expect(app.D.respond("/check-in", 404, "{\"error\":{\"code\":\"not_found\",\"message\":\"No such parcel\"}}"));
    try testing.expect(app.D.findText("TRF200") != 0);
}

test "scan: no hubs" {
    try dispatch.openCarrier("/scan");
    defer app.D.reset();
    try testing.expect(app.D.respond("/carrier/hubs", 200, "[]"));
    try testing.expect(app.D.findText(L("scan.no_hubs")) != 0);
}

test "scan: the camera checks in Turf labels, once per label, and stops when asked" {
    try dispatch.openCarrier("/scan");
    defer app.D.reset();
    const D = app.D;
    try testing.expect(D.respond("/carrier/hubs", 200, "[{\"_id\":\"h1\",\"name\":\"Damascus Hub\",\"code\":\"dam\",\"governorate\":\"DAM\",\"active\":true}]"));
    try D.press(L("scan.camera"));
    const c = D.R.appState();
    const id = c.page.scan.scanner;
    try testing.expect(id != 0);
    D.R.dispatch(.{ .scan = .{ .kind = .started, .scanner = id } });
    try testing.expect(D.findText(L("scan.stop_camera")) != 0);
    D.R.dispatch(.{ .scan = .{ .kind = .found, .scanner = id, .format = .code_128, .text = "TRF12AB" } });
    try testing.expect(D.pending("/carrier/hubs/h1/check-in") != null);
    // Another kind of code, and the same label again, are not sent.
    D.R.dispatch(.{ .scan = .{ .kind = .found, .scanner = id, .format = .qr, .text = "https://example.com" } });
    D.R.dispatch(.{ .scan = .{ .kind = .found, .scanner = id, .format = .code_128, .text = "TRF12AB" } });
    var n: usize = 0;
    for (zui.host.fetches.items) |f| if (std.mem.indexOf(u8, f.url, "check-in") != null) {
        n += 1;
    };
    try testing.expectEqual(@as(usize, 1), n);
    try D.press(L("scan.stop_camera"));
    try testing.expectEqual(@as(u32, 0), D.R.appState().page.scan.scanner);
}
