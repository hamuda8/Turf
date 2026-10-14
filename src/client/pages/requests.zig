//! Delivery requests from individuals (direct shipping), offered to this company (Turf-js
//! views/carrier/requests.js): accept within the time limit, or the request goes to the next
//! company. The countdown ticks every second; the list reloads when a request's time is up, every
//! 20 s, and on live "direct.request" events (Server-Sent Events).

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

const d_list: u8 = 0;
const t_tick: u16 = 1;
const t_refresh: u16 = 2;
const t_every: u16 = 3;

const A = enum(u16) { accept = 1, decline_ask, decline };

pub const S = struct {
    expired_at: i64 = 0,
};

pub fn title(_: *const S, _: *const Cx) []const u8 {
    return L("nav.requests");
}

pub fn enter(_: *S, c: *Cx) void {
    c.load(d_list, c.orgUrl("/carrier/requests"));
    c.after(1000, t_tick);
    c.after(20_000, t_every);
    c.orgLive(t_refresh, &.{"direct.request"});
}

/// While a request is being answered the list is not reloaded (that would bring back buttons
/// for a request already on its way).
fn acting(c: *const Cx) bool {
    return c.isBusy(@intFromEnum(A.accept)) or c.isBusy(@intFromEnum(A.decline));
}

fn load(c: *Cx) void {
    if (acting(c)) return;
    c.load(d_list, c.orgUrl("/carrier/requests"));
}

fn at(c: *const Cx, i: u32) ?V {
    const list = json.arr(c.data(d_list), "");
    return if (i < list.len) list[i] else null;
}

/// "4:05" left.
fn left(a: std.mem.Allocator, expires: []const u8) []const u8 {
    const ms = fmt.parseIso(expires) orelse 0;
    const s: i64 = @max(0, @divFloor(ms - fmt.now() + 500, 1000));
    return std.fmt.allocPrint(a, "{d}:{d:0>2}", .{ @as(u64, @intCast(@divFloor(s, 60))), @as(u64, @intCast(@mod(s, 60))) }) catch "";
}

pub fn update(s: *S, c: *Cx, e: core.Ev) void {
    switch (e) {
        .timer => |id| switch (id) {
            t_tick => {
                // A request whose time is up has gone to the next company.
                var expired = false;
                for (json.arr(c.data(d_list), "")) |r| if ((fmt.parseIso(json.str(r, "expiresAt")) orelse 0) <= fmt.now()) {
                    expired = true;
                };
                if (expired and !acting(c) and fmt.now() - s.expired_at > 5000) {
                    s.expired_at = fmt.now();
                    load(c);
                }
                c.after(1000, t_tick);
            },
            t_refresh => {
                c.liveDone();
                load(c);
            },
            t_every => {
                load(c);
                c.after(20_000, t_every);
            },
            else => {},
        },
        .act => |a| switch (@as(A, @enumFromInt(a.id))) {
            .accept => if (at(c, a.arg)) |r| {
                if (acting(c)) return;
                c.sendArg(@intFromEnum(A.accept), a.arg, .POST, c.orgUrl(c.print("/carrier/requests/{s}/accept", .{cm.docId(r)})), "");
            },
            .decline_ask => c.ask(L("requests.decline_confirm"), .{ .act = .{ .id = @intFromEnum(A.decline), .arg = a.arg } }),
            .decline => if (at(c, a.arg)) |r| {
                if (acting(c)) return;
                c.sendArg(@intFromEnum(A.decline), a.arg, .POST, c.orgUrl(c.print("/carrier/requests/{s}/decline", .{cm.docId(r)})), "{}");
            },
        },
        .done => |d| switch (@as(A, @enumFromInt(d.id))) {
            .accept => if (d.ok) {
                c.toast(cm.txc(c, "requests.accepted", .{ .tn = json.str(d.v, "trackingNumber") }), .ok);
                c.go(c.print("/shipments/{s}", .{json.strOr(d.v, "_id", json.str(d.v, "id"))}));
            } else load(c), // refused (taken, expired): show the list as it is now
            .decline => load(c),
            else => {},
        },
        else => {},
    }
}

pub fn view(_: *const S, c: *const Cx, ui: *Ui) void {
    if (!kit.gate(ui, &.{d_list})) return;
    const k = kit.k;
    const a = ui.arena();
    ui.begin(.{ .gap = 16, .max_width = 820 }, .{});
    kit.muted(ui, L("requests.intro"));
    const list = json.arr(c.data(d_list), "");
    if (list.len == 0) kit.empty(ui, L("requests.none"));
    kit.stackTight(ui);
    for (list, 0..) |r, i| {
        kit.card(ui, .{ .gap = 8.8, .key = zui.key(cm.docId(r)) });
        kit.rowBetween(ui);
        ui.begin(.{ .direction = .row, .gap = 4.8, .align_items = .center, .grow = 1 }, .{});
        kit.strong(ui, parts.placeText(a, c, json.get(r, "pickup"), .{}));
        kit.iconFlip(ui, icons.arrow_forward, 16, k.ink_2);
        kit.strong(ui, parts.placeText(a, c, json.get(r, "dropoff"), .{}));
        ui.end();
        kit.badgeIcon(ui, left(a, json.str(r, "expiresAt")), .amber, icons.schedule);
        ui.end();
        var line: std.ArrayList(u8) = .empty;
        const pa = json.str(r, "pickup.area");
        const da = json.str(r, "dropoff.area");
        if (pa.len > 0) line.appendSlice(a, pa) catch {};
        if (pa.len > 0 and da.len > 0) line.appendSlice(a, " → ") catch {};
        if (da.len > 0) line.appendSlice(a, da) catch {};
        line.print(a, " · {s} {s}", .{ json.text(a, r, "parcel.weightKg"), L("unit.kg") }) catch {};
        if (json.boolean(r, "parcel.fragile")) line.print(a, " · {s}", .{L("shipment.fragile")}) catch {};
        if (json.str(r, "parcel.description").len > 0) line.print(a, " · {s}", .{json.str(r, "parcel.description")}) catch {};
        kit.small(ui, line.items);
        if (json.obj(r, "cod")) |cod| ui.text(cm.tx(ui, "requests.cod", .{ .amount = fmt.money(a, json.num(cod, "amount"), json.str(cod, "currency")) }), .{ .font_size = 13.6, .color = k.ink });
        if (json.str(r, "notes").len > 0) kit.notice(ui, .info, json.str(r, "notes"));
        kit.rowBetween(ui);
        kit.strong(ui, fmt.money(a, json.num(r, "price.amount"), json.str(r, "price.currency")));
        ui.begin(.{ .direction = .row, .gap = 8 }, .{});
        const mine_d = c.isBusy(@intFromEnum(A.decline)) and (c.act_args.get(@intFromEnum(A.decline)) orelse 0) == i;
        const mine_a = c.isBusy(@intFromEnum(A.accept)) and (c.act_args.get(@intFromEnum(A.accept)) orelse 0) == i;
        kit.button(ui, L("requests.decline"), kit.act(A.decline_ask, @intCast(i)), .{ .variant = .ghost, .busy = if (mine_d) @intFromEnum(A.decline) else null, .disabled = acting(c) and !mine_d });
        kit.button(ui, L("requests.accept"), kit.act(A.accept, @intCast(i)), .{ .variant = .primary, .icon = icons.check, .busy = if (mine_a) @intFromEnum(A.accept) else null, .disabled = acting(c) and !mine_a });
        ui.end();
        ui.end();
        kit.endCard(ui, .{});
    }
    ui.end();
    ui.end();
}

// ---- Tests --------------------------------------------------------------------------------

const app = @import("../app.zig");
const testing = std.testing;
const dispatch = @import("dispatch.zig");

test "requests: accept one and open its shipment" {
    // Direct shipping has to be on for this page.
    app.D.startWith(1200, 800, "/o/fast/requests");
    defer app.D.reset();
    try testing.expect(app.D.respond("/api/app/me", 200, app.me_json));
    const meta = try std.mem.replaceOwned(u8, testing.allocator, app.meta_json, "\"features\":{}", "\"features\":{\"directShipping\":true}");
    defer testing.allocator.free(meta);
    try testing.expect(app.D.respond("/api/app/meta", 200, meta));
    try testing.expect(app.D.respond("/api/app/orgs/o2", 200, dispatch.carrier_org));
    try testing.expect(app.D.respond("/carrier/requests", 200,
        \\[{"id":"r1","expiresAt":"2099-01-01T00:00:00.000Z","pickup":{"city":"Mazzeh","area":"West"},"dropoff":{"city":"Homs"},
        \\  "parcel":{"weightKg":3,"fragile":true},"price":{"amount":7000,"currency":"SYP"},"notes":"Call first"}]
    ));
    try testing.expect(app.D.findText("Call first") != 0);
    try testing.expect(app.D.findText("7,000 SYP") != 0);
    try app.D.press("Accept");
    try testing.expect(app.D.respond("/carrier/requests/r1/accept", 200, "{\"_id\":\"s5\",\"trackingNumber\":\"TRF5\"}"));
    try testing.expect(std.mem.endsWith(u8, app.D.R.appState().pathStr(), "/shipments/s5"));
}

test "requests: the countdown" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    fmt.fixed_now_ms = fmt.parseIso("2026-10-12T11:00:00.000Z").?;
    defer fmt.fixed_now_ms = null;
    try testing.expectEqualStrings("4:05", left(arena.allocator(), "2026-10-12T11:04:05.000Z"));
    try testing.expectEqualStrings("0:00", left(arena.allocator(), "2026-10-12T10:00:00.000Z"));
}
