//! The courier's GPS tracker and offline outbox (Turf-js courier/tracker.js and outbox.js), in
//! one place so the native background service can grow from here.
//!
//! Tracker: while a shift runs it follows the position (fx.watchLocation, and on the phones
//! fx.backgroundLocation so it keeps going with the screen off), samples it every 20 s or 15 m,
//! keeps the samples on the device (zui.storage) so nothing is lost without signal, and uploads
//! them in batches of 200 every 15 s, one upload at a time.
//!
//! Outbox: driver actions done without a connection (accept, start, delivered, failed) are kept
//! in order with the time of the tap (clientAt) and sent when the connection is back; ones the
//! server refuses are reported.

const std = @import("std");
const zui = @import("zui");
const core = @import("core.zig");
const json = @import("json.zig");
const fmt = @import("fmt.zig");

const Cx = core.Cx;
const gpa = core.gpa;

pub const sample_ms = 20_000;
pub const sample_meters = 15;
pub const flush_ms = 15_000;
pub const outbox_ms = 30_000;
pub const max_buffer = 2000;
pub const batch = 200;

pub const Status = enum { off, waiting, good, weak, denied, unavailable };

pub const Fix = struct {
    lat: f64,
    lng: f64,
    accuracy: f32 = 0,
    speed: ?f32 = null,
    heading: ?f32 = null,
    at: i64,
};

pub const Item = struct { id: []u8, path: []u8, body: []u8 };

// Request codes (TagKind.gps).
pub const code_positions: u16 = 1;
pub const code_outbox: u16 = 2;
pub const code_presence: u16 = 3;
// Global timers.
pub const timer_flush: u16 = 1;
pub const timer_outbox: u16 = 2;

pub const Tracker = struct {
    org: [40]u8 = undefined,
    org_len: usize = 0,
    on: bool = false,
    status: Status = .off,
    last_fix: ?Fix = null,
    last_sampled: ?Fix = null,
    buffer: std.ArrayList(Fix) = .empty,
    /// Positions in the upload on its way.
    uploading: usize = 0,
    session_expired: bool = false,
    /// Someone (a page) wants positions without a shift (my location on a map).
    page_wants: bool = false,
    watching: bool = false,
    outbox: std.ArrayList(Item) = .empty,
    outbox_loaded_for: [40]u8 = undefined,
    outbox_loaded_len: usize = 0,
    sending: bool = false,
    /// Actions the server refused, to explain (texts owned by gpa).
    refused: std.ArrayList([]u8) = .empty,
    timers_running: bool = false,

    pub fn orgId(tr: *const Tracker) []const u8 {
        return tr.org[0..tr.org_len];
    }

    pub fn pending(tr: *const Tracker) usize {
        return tr.buffer.items.len;
    }

    pub fn outboxCount(tr: *const Tracker) usize {
        return tr.outbox.items.len;
    }

    /// A fix younger than two minutes, for task actions.
    pub fn current(tr: *const Tracker) ?Fix {
        const f = tr.last_fix orelse return null;
        if (fmt.now() - f.at > 120_000) return null;
        return f;
    }
};

fn storageKey(buf: []u8, kind: []const u8, org: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "turf.{s}.{s}", .{ kind, org }) catch kind;
}

fn onLocated(l: zui.Location) core.Msg {
    return .{ .located = l };
}

/// Follow the position (for the tracker or a page).
fn updateWatch(c: *Cx) void {
    const on = c.gps.on or c.gps.page_wants;
    if (on == c.gps.watching) return;
    c.gps.watching = on;
    c.fx.watchLocation(if (on) onLocated else null);
}

/// A page wants the position (a map's "my location", the address form, a task screen).
pub fn want(c: *Cx, on: bool) void {
    c.gps.page_wants = on;
    updateWatch(c);
}

/// Starts the shift's tracking for company `org` (`startTracking`).
pub fn start(c: *Cx, title: []const u8, text: []const u8) void {
    const tr = &c.gps;
    const org = c.orgId();
    if (tr.on and std.mem.eql(u8, tr.orgId(), org)) return;
    stop(c, false);
    tr.org_len = @min(org.len, tr.org.len);
    @memcpy(tr.org[0..tr.org_len], org[0..tr.org_len]);
    loadBuffer(c);
    tr.on = true;
    tr.status = .waiting;
    // A fix the page already had (the task screen follows the position before the shift is known).
    if (tr.last_fix) |f| if (fmt.now() - f.at < 120_000) {
        tr.status = if (f.accuracy <= 50) .good else .weak;
    };
    updateWatch(c);
    // Phones: the location keeps coming with the screen off, with Turf's notification.
    c.fx.backgroundLocation(true, title, text);
    if (!tr.timers_running) {
        tr.timers_running = true;
        c.fx.after(flush_ms, .{ .timer = .{ .gen = 0, .id = timer_flush, .global = true } });
    }
    presence(c, "foreground");
}

/// Ends tracking (`stopTracking`).
pub fn stop(c: *Cx, end_notice: bool) void {
    const tr = &c.gps;
    if (!tr.on) return;
    tr.on = false;
    tr.status = .off;
    updateWatch(c);
    if (end_notice) c.fx.backgroundLocation(false, "", "");
}

pub fn isTracking(c: *const Cx) bool {
    return c.gps.on;
}

fn metersBetween(a: Fix, b: Fix) f64 {
    const r = 6371000.0;
    const rad = std.math.pi / 180.0;
    const dlat = (b.lat - a.lat) * rad;
    const dlng = (b.lng - a.lng) * rad;
    const x = std.math.pow(f64, @sin(dlat / 2), 2) + @cos(a.lat * rad) * @cos(b.lat * rad) * std.math.pow(f64, @sin(dlng / 2), 2);
    return 2 * r * std.math.asin(@sqrt(x));
}

/// A position from the device.
pub fn located(c: *Cx, l: zui.Location) void {
    const tr = &c.gps;
    switch (l) {
        .fix => |f| {
            const fix: Fix = .{ .lat = f.lat, .lng = f.lng, .accuracy = f.accuracy, .speed = f.speed, .heading = f.heading, .at = fmt.now() };
            tr.last_fix = fix;
            if (!tr.on) return;
            tr.status = if (f.accuracy <= 50) .good else .weak;
            const take = if (tr.last_sampled) |last| fix.at - last.at >= sample_ms or metersBetween(last, fix) >= sample_meters else true;
            if (take) {
                tr.last_sampled = fix;
                tr.buffer.append(gpa, fix) catch {};
                if (tr.buffer.items.len > max_buffer) _ = tr.buffer.orderedRemove(0);
                saveBuffer(c);
                if (tr.buffer.items.len >= 20) flush(c);
            }
        },
        .denied => tr.status = if (tr.on) .denied else tr.status,
        .unavailable => tr.status = if (tr.on) .unavailable else tr.status,
    }
}

fn loadBuffer(c: *Cx) void {
    const tr = &c.gps;
    tr.buffer.clearRetainingCapacity();
    var kb: [96]u8 = undefined;
    const raw = zui.storage.get(gpa, storageKey(&kb, "positions", tr.orgId()), .{}) orelse return;
    defer gpa.free(raw);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const v = json.parse(arena.allocator(), raw) orelse return;
    for (json.arr(v, "")) |p| {
        tr.buffer.append(gpa, .{
            .lat = json.numOr(p, "lat", 0),
            .lng = json.numOr(p, "lng", 0),
            .accuracy = @floatCast(json.numOr(p, "accuracy", 0)),
            .speed = if (json.num(p, "speed")) |x| @floatCast(x) else null,
            .heading = if (json.num(p, "heading")) |x| @floatCast(x) else null,
            .at = fmt.parseIso(json.str(p, "at")) orelse 0,
        }) catch {};
    }
}


/// The positions as a JSON array (the stored buffer, and an upload batch).
fn positionsJson(a: std.mem.Allocator, list: []const Fix) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    out.append(a, '[') catch {};
    for (list, 0..) |f, i| {
        if (i > 0) out.append(a, ',') catch {};
        var b = json.Obj.init(a);
        b.num("lat", f.lat);
        b.num("lng", f.lng);
        b.num("accuracy", f.accuracy);
        if (f.speed) |s| b.num("speed", s) else b.nul("speed");
        if (f.heading) |h| b.num("heading", h) else b.nul("heading");
        b.str("at", fmt.isoUtc(a, f.at));
        out.appendSlice(a, b.done()) catch {};
    }
    out.append(a, ']') catch {};
    return out.items;
}

fn saveBuffer(c: *Cx) void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var kb: [96]u8 = undefined;
    zui.storage.set(storageKey(&kb, "positions", c.gps.orgId()), positionsJson(arena.allocator(), c.gps.buffer.items), .{});
}

/// Uploads the oldest batch, if none is on its way (`flush`).
pub fn flush(c: *Cx) void {
    const tr = &c.gps;
    if (tr.uploading > 0 or tr.buffer.items.len == 0 or tr.org_len == 0 or !c.online) return;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const n = @min(batch, tr.buffer.items.len);
    tr.uploading = n;
    const body = std.fmt.allocPrint(a, "{{\"positions\":{s}}}", .{positionsJson(a, tr.buffer.items[0..n])}) catch return;
    const url = std.fmt.allocPrint(a, "{s}/api/app/orgs/{s}/courier/positions", .{ core.api_base, tr.orgId() }) catch return;
    c.request(.POST, url, body, core.tag(.gps, 0, code_positions));
}

/// "The app is on screen / in the background" for the safety watchdog.
pub fn presence(c: *Cx, state: []const u8) void {
    const tr = &c.gps;
    if (tr.org_len == 0) return;
    var buf: [256]u8 = undefined;
    const url = std.fmt.bufPrint(&buf, "{s}/api/app/orgs/{s}/courier/presence", .{ core.api_base, tr.orgId() }) catch return;
    var bb: [64]u8 = undefined;
    const body = std.fmt.bufPrint(&bb, "{{\"state\":\"{s}\"}}", .{state}) catch return;
    c.request(.POST, url, body, core.tag(.gps, 0, code_presence));
}

/// The answer to an upload or an outbox item.
pub fn response(c: *Cx, r: zui.Response) void {
    const tr = &c.gps;
    switch (core.tagCode(r.tag)) {
        code_positions => {
            const n = tr.uploading;
            tr.uploading = 0;
            if (r.status == 401) {
                tr.session_expired = true;
                return;
            }
            // Offline, rate limited or server trouble: keep them for the next try.
            if (r.status == 0 or r.status == 429 or r.status >= 500) return;
            // 2xx, or a 4xx for data that can never be fixed: drop the batch either way.
            tr.session_expired = false;
            const drop = @min(n, tr.buffer.items.len);
            std.mem.copyForwards(Fix, tr.buffer.items[0 .. tr.buffer.items.len - drop], tr.buffer.items[drop..]);
            tr.buffer.shrinkRetainingCapacity(tr.buffer.items.len - drop);
            saveBuffer(c);
            if (tr.buffer.items.len > 0) flush(c);
        },
        code_outbox => outboxAnswer(c, r),
        else => {},
    }
}

/// The global timers (flush every 15 s while tracking, outbox every 30 s).
pub fn timer(c: *Cx, id: u16) void {
    switch (id) {
        timer_flush => {
            flush(c);
            if (c.gps.on) c.fx.after(flush_ms, .{ .timer = .{ .gen = 0, .id = timer_flush, .global = true } }) else c.gps.timers_running = false;
        },
        timer_outbox => {
            sendNext(c);
            if (c.gps.outbox.items.len > 0) c.fx.after(outbox_ms, .{ .timer = .{ .gen = 0, .id = timer_outbox, .global = true } });
        },
        else => {},
    }
}

// ---- Outbox -------------------------------------------------------------------------------

fn loadOutbox(c: *Cx) void {
    const tr = &c.gps;
    const org = c.orgId();
    if (std.mem.eql(u8, tr.outbox_loaded_for[0..tr.outbox_loaded_len], org)) return;
    for (tr.outbox.items) |it| freeItem(it);
    tr.outbox.clearRetainingCapacity();
    tr.outbox_loaded_len = @min(org.len, tr.outbox_loaded_for.len);
    @memcpy(tr.outbox_loaded_for[0..tr.outbox_loaded_len], org[0..tr.outbox_loaded_len]);
    var kb: [96]u8 = undefined;
    const raw = zui.storage.get(gpa, storageKey(&kb, "outbox", org), .{}) orelse return;
    defer gpa.free(raw);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const v = json.parse(arena.allocator(), raw) orelse return;
    for (json.arr(v, "")) |x| {
        const body = json.get(x, "body") orelse continue;
        tr.outbox.append(gpa, .{
            .id = gpa.dupe(u8, json.str(x, "id")) catch continue,
            .path = gpa.dupe(u8, json.str(x, "path")) catch continue,
            .body = gpa.dupe(u8, json.stringify(arena.allocator(), body)) catch continue,
        }) catch {};
    }
}

fn freeItem(it: Item) void {
    gpa.free(it.id);
    gpa.free(it.path);
    gpa.free(it.body);
}

fn saveOutbox(c: *Cx) void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.ArrayList(u8) = .empty;
    out.append(a, '[') catch {};
    for (c.gps.outbox.items, 0..) |it, i| {
        if (i > 0) out.append(a, ',') catch {};
        var b = json.Obj.init(a);
        b.str("id", it.id);
        b.str("path", it.path);
        b.raw("body", it.body);
        out.appendSlice(a, b.done()) catch {};
    }
    out.append(a, ']') catch {};
    var kb: [96]u8 = undefined;
    zui.storage.set(storageKey(&kb, "outbox", c.orgId()), out.items, .{});
}

/// Called when the driver app opens: loads the waiting actions and starts sending them.
pub fn startOutbox(c: *Cx) void {
    loadOutbox(c);
    sendNext(c);
    if (c.gps.outbox.items.len > 0) c.fx.after(outbox_ms, .{ .timer = .{ .gen = 0, .id = timer_outbox, .global = true } });
}

/// Keeps a driver action for later (the page sent it and got no connection). `body` is the
/// JSON object sent; the time of the tap is added as clientAt.
pub fn queue(c: *Cx, path: []const u8, body: []const u8) void {
    loadOutbox(c);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const now = fmt.now();
    const at = fmt.isoUtc(a, now);
    const trimmed = std.mem.trim(u8, body, " \r\n\t");
    const with_at = if (trimmed.len <= 2)
        std.fmt.allocPrint(a, "{{\"clientAt\":\"{s}\"}}", .{at}) catch return
    else
        std.fmt.allocPrint(a, "{s},\"clientAt\":\"{s}\"}}", .{ trimmed[0 .. trimmed.len - 1], at }) catch return;
    const id = std.fmt.allocPrint(gpa, "{d}-{d}", .{ now, c.gps.outbox.items.len }) catch return;
    c.gps.outbox.append(gpa, .{ .id = id, .path = gpa.dupe(u8, path) catch return, .body = gpa.dupe(u8, with_at) catch return }) catch return;
    saveOutbox(c);
    if (c.gps.outbox.items.len == 1) c.fx.after(outbox_ms, .{ .timer = .{ .gen = 0, .id = timer_outbox, .global = true } });
}

/// Earlier actions must reach the server first: a page sends directly only when none wait.
pub fn hasWaiting(c: *Cx) bool {
    loadOutbox(c);
    return c.gps.outbox.items.len > 0;
}

fn sendNext(c: *Cx) void {
    const tr = &c.gps;
    if (tr.sending or tr.outbox.items.len == 0 or !c.online) return;
    const it = tr.outbox.items[0];
    tr.sending = true;
    var buf: [512]u8 = undefined;
    const url = std.fmt.bufPrint(&buf, "{s}/api/app/orgs/{s}{s}", .{ core.api_base, tr.outbox_loaded_for[0..tr.outbox_loaded_len], it.path }) catch return;
    c.request(.POST, url, it.body, core.tag(.gps, 0, code_outbox));
}

fn outboxAnswer(c: *Cx, r: zui.Response) void {
    const tr = &c.gps;
    tr.sending = false;
    if (tr.outbox.items.len == 0) return;
    // Still offline, or server trouble: keep it and try later.
    if (r.status == 0 or r.status >= 500) return;
    if (!r.ok()) {
        // Already done, or no longer possible: drop it and explain.
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const msg = core.errorMessage(arena.allocator(), r.status, json.parse(arena.allocator(), r.body), false);
        tr.refused.append(gpa, gpa.dupe(u8, msg) catch return) catch {};
    }
    freeItem(tr.outbox.orderedRemove(0));
    saveOutbox(c);
    sendNext(c);
}

test "the outbox keeps actions in order with the time of the tap" {
    // Exercised through the driver page tests in app.zig.
}
