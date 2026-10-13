//! The public tracking page "/t/<token>" and the embeddable widget "/embed/t/<token>" (Turf-js
//! track.js, track.html, css/track.css): no sign-in, the API under /api/public. The status and
//! its progress, the delivery code, the courier on a live map, the recipient pinning their door,
//! choosing another delivery day, rating the delivery, the history, the carrier's phone.
//!
//! Turf-js followed the parcel over Server-Sent Events; zui has none, so the page polls (every
//! 10 seconds: the courier's position and the status). The map follows the courier until the
//! visitor moves it. The page wears the carrier's colour.

const std = @import("std");
const zui = @import("zui");
const core = @import("../core.zig");
const kit = @import("../kit.zig");
const json = @import("../json.zig");
const fmt = @import("../fmt.zig");
const icons = @import("../icons.zig");
const labels = @import("../labels.zig");
const theme = @import("../theme.zig");
const gps = @import("../gps.zig");
const mapw = @import("../widgets/map.zig");
const lookup = @import("../widgets/lookup.zig");

const Cx = core.Cx;
const Ui = core.Ui;
const V = json.V;
const L = labels.k;
const LatLng = mapw.LatLng;

const d_track: u8 = 0;
const d_feedback: u8 = 1;

const f_day: u16 = 0;
const f_problem: u16 = 1;
const f_comment: u16 = 2;

const A = enum(u16) { lang = 1, locate, pin_save, pin_cancel, choose_day, star, send_feedback };
const T_POLL: u16 = 1;
const T_LOCATE: u16 = 2;
const poll_ms = 10_000;

const code_statuses = [_][]const u8{ "out_for_delivery", "delivery_failed", "at_hub", "in_transit", "picked_up", "awaiting_pickup" };
const problems = [_][]const u8{ "not_received", "damaged", "missing_items", "courier_behaviour", "cod_wrong", "other" };

const PinMode = enum { idle, locating, adjusting };

pub const S = struct {
    m: mapw.Map = .{},
    embed: bool = false,
    token: []const u8 = "",
    /// The view was set on the courier once; the visitor moved the map since.
    centered: bool = false,
    user_moved: bool = false,
    pin_mode: PinMode = .idle,
    pin: ?LatLng = null,
    accuracy: f32 = 0,
    /// Each "Share my location" has a number: a position for an older one is ignored.
    pin_seq: u32 = 0,
    /// What the visitor changed since the last load.
    location_shared: bool = false,
    scheduled: []const u8 = "",
    day_filled: bool = false,
    rating: u8 = 0,
};

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn inList(s: []const u8, list: []const []const u8) bool {
    for (list) |x| if (eq(s, x)) return true;
    return false;
}

pub fn title(_: *const S, c: *const Cx) []const u8 {
    return json.strOr(c.data(d_track), "statusText", L("lookup.title"));
}

fn trackUrl(c: *Cx, s: *const S, rest: []const u8) []const u8 {
    return c.publicUrl(c.print("/track/{s}{s}", .{ core.encode(c.arena(), s.token), rest }));
}

fn load(s: *const S, c: *Cx) void {
    c.load(d_track, trackUrl(c, s, c.print("?lang={s}", .{c.lang()})));
}

pub fn enter(s: *S, c: *Cx) void {
    s.embed = std.mem.startsWith(u8, c.pathStr(), "/embed/");
    const route = c.route();
    s.token = c.dupe(route[(std.mem.lastIndexOfScalar(u8, route, '/') orelse 0) + 1 ..]);
    const lang = c.query(c.arena(), "lang");
    if (eq(lang, "ar") or eq(lang, "en")) zui.i18n.setLanguage(lang);
    load(s, c);
    c.after(poll_ms, T_POLL);
}

/// The map's width: the page is at most 760 wide, a card has 20 of padding each side.
fn mapWidth(c: *const Cx, embed: bool) f32 {
    const pad: f32 = if (embed) 8 else 16;
    return @min(c.env.width, 760) - 2 * pad - 40;
}

fn mapHeight(embed: bool) f32 {
    return if (embed) 260 else 360;
}

fn courierAt(v: ?V) ?LatLng {
    return mapw.ll(v, "courier.location");
}

fn cancelPin(s: *S, c: *Cx) void {
    s.pin_seq +%= 1;
    if (s.pin_mode == .locating) gps.want(c, false);
    _ = c.busy.remove(@intFromEnum(A.locate));
    s.pin_mode = .idle;
    s.pin = null;
}

fn startPin(s: *S, c: *Cx, p: ?LatLng, accuracy: f32) void {
    _ = c.busy.remove(@intFromEnum(A.locate));
    s.pin_mode = .adjusting;
    s.pin = p;
    s.accuracy = accuracy;
    s.m.setSize(mapWidth(c, s.embed), mapHeight(s.embed));
    if (p) |at| {
        s.m.flyTo(at, 17);
    } else if (courierAt(c.data(d_track)) == null) {
        s.m.st.camera.center = mapw.syria;
        s.m.st.camera.zoom = 7;
    }
}

/// Follows the courier: set once, then only until the visitor moves the map.
fn follow(s: *S, c: *Cx) void {
    const at = courierAt(c.data(d_track)) orelse return;
    if (s.pin_mode == .adjusting) return;
    if (!s.centered) {
        s.centered = true;
        s.m.st.camera.center = at;
        s.m.st.camera.zoom = 15;
    } else if (!s.user_moved) s.m.st.camera.center = at;
}

pub fn update(s: *S, c: *Cx, e: core.Ev) void {
    switch (e) {
        .data => |n| if (n == d_track) {
            const v = c.data(d_track) orelse return;
            if (c.slot(d_track).err.len > 0) return; // a failed reload keeps the current view
            s.location_shared = false;
            s.scheduled = "";
            if (!s.day_filled) {
                s.day_filled = true;
                c.setVal(f_day, json.strOr(v, "scheduledFor", fmt.isoDay(c.arena(), fmt.now())));
            }
            if (!json.boolean(v, "canSetLocation") or s.embed) cancelPin(s, c);
            follow(s, c);
            c.post("{{\"type\":\"title\",\"title\":{f}}}", .{std.json.fmt(c.print("{s} · {s}", .{ json.str(v, "statusText"), json.str(v, "trackingNumber") }), .{})});
        },
        .timer => |id| switch (id) {
            T_POLL => {
                if (c.slot(d_track).state != .loading and !c.slot(d_track).reloading) load(s, c);
                c.after(poll_ms, T_POLL);
            },
            T_LOCATE => if (s.pin_mode == .locating) {
                // No position in time: the map can still be tapped.
                gps.want(c, false);
                startPin(s, c, null, 0);
            },
            else => {},
        },
        .located => |l| if (s.pin_mode == .locating) {
            gps.want(c, false);
            switch (l) {
                .fix => |f| startPin(s, c, .{ .lat = mapw.round6(f.lat), .lng = mapw.round6(f.lng) }, f.accuracy),
                .denied, .unavailable => startPin(s, c, null, 0),
            }
        },
        .map, .frame => {
            if (e == .map and (e.map.kind == .move or e.map.kind == .wheel)) s.user_moved = true;
            if (s.m.event(c, e)) |at| if (s.pin_mode == .adjusting) {
                s.pin = .{ .lat = mapw.round6(at.lat), .lng = mapw.round6(at.lng) };
            };
        },
        .act => |a| switch (@as(A, @enumFromInt(a.id))) {
            .lang => {
                const next = if (c.ar()) "en" else "ar";
                zui.i18n.setLanguage(next);
                zui.storage.set("lang", next, .{});
                cancelPin(s, c);
                load(s, c);
            },
            .locate => {
                cancelPin(s, c);
                s.pin_mode = .locating;
                c.busy.put(core.gpa, @intFromEnum(A.locate), {}) catch {};
                gps.want(c, true);
                c.after(20_000, T_LOCATE);
            },
            .pin_cancel => cancelPin(s, c),
            .pin_save => {
                const p = s.pin orelse return c.toast(L("track.pin_tap"), .err);
                var b = json.Obj.init(c.arena());
                b.num("lat", p.lat);
                b.num("lng", p.lng);
                c.send(@intFromEnum(A.pin_save), .POST, trackUrl(c, s, "/location"), b.done());
            },
            .choose_day => {
                var b = json.Obj.init(c.arena());
                b.str("date", c.valTrim(f_day));
                c.send(@intFromEnum(A.choose_day), .POST, trackUrl(c, s, "/reschedule"), b.done());
            },
            .star => s.rating = @intCast(@min(a.arg, 5)),
            .send_feedback => {
                const problem = c.val(f_problem);
                if (s.rating == 0 and problem.len == 0) return c.toast(L("track.feedback_choose"), .err);
                var b = json.Obj.init(c.arena());
                if (s.rating > 0) b.int("rating", s.rating);
                if (problem.len > 0) b.str("problem", problem);
                b.strOpt("comment", c.val(f_comment));
                c.send(@intFromEnum(A.send_feedback), .POST, trackUrl(c, s, "/feedback"), b.done());
            },
        },
        .done => |d| if (d.ok) switch (@as(A, @enumFromInt(d.id))) {
            .pin_save => {
                s.location_shared = true;
                c.toast(L("track.location_saved"), .ok);
                cancelPin(s, c);
            },
            .choose_day => {
                s.scheduled = c.dupe(json.strOr(d.v, "scheduledFor", c.valTrim(f_day)));
                c.toast(L("track.day_saved"), .ok);
            },
            .send_feedback => {
                // Kept in a data slot: the thanks show what was sent.
                const slot = &c.slots[d_feedback];
                slot.reset();
                slot.value = json.parse(slot.arena.allocator(), d.body);
                slot.state = .ok;
            },
            else => {},
        },
        else => {},
    }
}

fn sentFeedback(c: *const Cx) ?V {
    if (json.obj(c.data(d_feedback), "feedback")) |f| return f;
    return json.obj(c.data(d_track), "feedback");
}

pub fn view(s: *const S, c: *const Cx, ui: *Ui) void {
    const v = c.data(d_track);
    // The carrier's colour.
    if (v != null) {
        var b: theme.Brand = .{};
        if (zui.Color.parseHex(json.str(v, "carrier.primaryColor"))) |x| b.primary = x else |_| {}
        kit.k = theme.colors(ui.env.dark, b);
        ui.setBackground(kit.k.canvas);
    }
    const k = kit.k;
    const pad: f32 = if (s.embed) 8 else 16;
    const w = @min(ui.env.width, 760);
    kit.width = w - 2 * pad;
    ui.beginScroll(.{ .width = .fill, .height = .fill, .align_items = .center, .background = k.canvas, .padding = .{ .top = ui.env.safe.top, .bottom = ui.env.safe.bottom } }, zui.key("track"));
    ui.begin(.{ .width = .{ .px = w }, .padding = .all(pad), .gap = if (s.embed) 9.6 else 16 }, .{});
    const sl = c.slot(d_track);
    if (sl.state == .idle or sl.state == .loading) {
        kit.loading(ui);
    } else if (sl.state == .failed or v == null) {
        kit.card(ui, .{});
        ui.begin(.{ .align_items = .center, .padding = .xy(16, 48), .gap = 13.6 }, .{});
        ui.begin(.{ .width = .{ .px = 64 }, .height = .{ .px = 64 }, .radius = 20, .background = k.accent_soft, .align_items = .center, .justify = .center }, .{});
        kit.icon(ui, icons.search, 32, k.a);
        ui.end();
        ui.text(if (sl.status == 404) L("track.not_found") else L("error.generic"), .{ .font_size = 15, .color = k.ink_2, .text_align = .center });
        ui.end();
        kit.endCard(ui, .{});
    } else page(s, c, ui, v.?);
    ui.end();
    ui.end();
}

fn page(s: *const S, c: *const Cx, ui: *Ui, v: V) void {
    const k = kit.k;
    const status = json.str(v, "status");
    const failed = inList(status, &.{ "cancelled", "returned", "returning" });

    // The head: the carrier on the chrome colour, the language.
    ui.begin(.{ .direction = .row, .align_items = .center, .gap = 12, .background = k.rail, .radius = if (s.embed) 16 else 22, .padding = if (s.embed) .xy(12.8, 9.6) else .xy(17.6, 16) }, .{});
    kit.logo(ui, json.obj(v, "carrier"), 44, 12);
    ui.begin(.{ .grow = 1, .gap = 1 }, .{});
    ui.text(json.str(v, "carrier.name"), .{ .font_size = 16.8, .weight = 700, .color = k.rail_ink });
    ui.text(ui.tf(labels.english("track.order_from") orelse "{merchant}", .{ .merchant = json.str(v, "merchant.name") }), .{ .font_size = 13.6, .color = k.rail_ink_2 });
    ui.end();
    kit.button(ui, if (c.ar()) "EN" else "ع", kit.act(A.lang, 0), .{ .size = .sm, .on_rail = true });
    ui.end();

    // The status.
    kit.card(ui, .{ .gap = 5.6 });
    ui.begin(.{ .direction = .row, .gap = 8, .align_items = .center }, .{});
    ui.text(json.str(v, "trackingNumber"), .{ .font_size = 13.6, .mono = true, .color = k.ink_2 });
    if (eq(json.str(v, "service"), "express")) kit.expressBadge(ui);
    ui.end();
    ui.text(json.str(v, if (c.ar()) "statusTextAr" else "statusTextEn"), .{ .font_size = 27.2, .weight = 850, .line_height = 1.1, .color = k.ink });
    const eta = etaLine(ui, v);
    if (eta.len > 0) ui.text(eta, .{ .font_size = 16.8, .color = k.ink });
    if (!failed) {
        ui.begin(.{ .padding = .{ .top = 8 } }, .{});
        lookup.progress(ui, trackStep(status), k.a);
        ui.end();
    }
    if (json.obj(v, "dropoff")) |d| {
        ui.begin(.{ .direction = .row, .gap = 4, .align_items = .center }, .{});
        kit.icon(ui, icons.location_on, 16, k.ink_2);
        kit.small(ui, kit.f(ui, "{s} {s}", .{ L("track.to"), dropoffText(ui, c, d) }));
        ui.end();
    }
    kit.endCard(ui, .{});

    if ((json.boolean(v, "canGiveFeedback") or sentFeedback(c) != null) and !s.embed) feedbackCard(s, c, ui, v);

    // The delivery code.
    const code = json.str(v, "deliveryCode");
    if (code.len > 0 and inList(status, &code_statuses)) {
        kit.card(ui, .{ .gap = 4.8, .ring = k.a, .align_items = .center });
        kit.text(ui, L("track.your_code"), .{ .@"align" = .center });
        ui.begin(.{ .no_mirror = true }, .{});
        ui.text(code, .{ .font_size = 38.4, .weight = 850, .mono = true, .color = k.ink, .text_align = .center });
        ui.end();
        ui.text(L("track.code_hint"), .{ .font_size = 13.6, .color = k.ink_2, .text_align = .center });
        kit.endCard(ui, .{});
    }

    // The map (while a courier carries the parcel, or while pinning) and the courier.
    kit.card(ui, .{ .gap = 8.8 });
    const courier = courierAt(v);
    if (courier != null or s.pin_mode == .adjusting) {
        var pins: std.ArrayList(mapw.Pin) = .empty;
        if (courier) |at| pins.append(ui.arena(), .{ .at = at, .icon = mapw.vehicleIcon(json.str(v, "courier.vehicle")), .key = zui.key("courier") }) catch {};
        if (s.pin_mode == .adjusting) if (s.pin) |p| pins.append(ui.arena(), .{ .at = p, .icon = mapw.placeIcon("home"), .kind = .place, .key = zui.key("pin") }) catch {};
        mapw.draw(ui, &s.m, .{ .height = mapHeight(s.embed), .width = kit.width - 40, .pins = pins.items, .key = zui.key("track-map") });
    }
    if (json.obj(v, "courier")) |cr| {
        ui.begin(.{ .direction = .row, .gap = 8, .align_items = .center }, .{});
        kit.icon(ui, icons.navigation, 18, k.ink);
        ui.text(json.strOr(cr, "name", L("track.courier")), .{ .font_size = 13.6, .weight = 700, .color = k.ink });
        ui.text(labels.vehicle(json.str(cr, "vehicle")), .{ .font_size = 13.6, .color = k.ink_2 });
        if (json.str(cr, "updatedAt").len > 0) ui.text(fmt.relative(ui.arena(), json.str(cr, "updatedAt")), .{ .font_size = 13.6, .color = k.ink_2 });
        ui.end();
    } else ui.text(L("track.no_live_courier"), .{ .font_size = 13.6, .color = k.ink_2 });
    kit.endCard(ui, .{});

    if (json.boolean(v, "canSetLocation") and !s.embed) locationCard(s, ui, v);
    if (json.boolean(v, "canReschedule") and !s.embed) dayCard(s, ui, v);

    // The history, newest first.
    kit.card(ui, .{ .gap = 8.8 });
    kit.h2(ui, L("shipment.timeline"));
    const events = json.arr(v, "events");
    ui.begin(.{}, .{});
    var i: usize = events.len;
    while (i > 0) {
        i -= 1;
        const e = events[i];
        kit.timelineItem(ui, json.str(e, if (c.ar()) "textAr" else "textEn"), fmt.dateTime(ui.arena(), json.str(e, "at")), .{ .current = i == events.len - 1, .last = i == 0 });
    }
    ui.end();
    kit.endCard(ui, .{});

    // The carrier's phone.
    const phone = json.str(v, "carrier.phone");
    if (phone.len > 0 and !s.embed) {
        kit.card(ui, .{ .direction = .row, .align_items = .center, .gap = 12 });
        ui.text(ui.tf(labels.english("track.questions") orelse "{carrier}", .{ .carrier = json.str(v, "carrier.name") }), .{ .font_size = 15, .color = k.ink, .grow = 1 });
        kit.button(ui, phone, .{ .open = kit.f(ui, "tel:{s}", .{phone}) }, .{ .size = .sm, .icon = icons.call });
        kit.endCard(ui, .{});
    }

    ui.begin(.{ .direction = .row, .justify = .center, .gap = 4 }, .{});
    ui.text(L("track.powered"), .{ .font_size = 12.5, .color = k.ink_3 });
    kit.link(ui, "Turf", .{ .open = kit.f(ui, "{s}/", .{core.api_base}) }, .{ .size = 12.5, .color = k.ink_3, .weight = 500 });
    ui.end();
}

/// The step on the 5-step bar (`stepOf` of track.js).
fn trackStep(status: []const u8) i32 {
    if (eq(status, "at_hub") or eq(status, "in_transit")) return 2;
    if (eq(status, "delivery_failed")) return 3;
    return lookup.stepOf(status);
}

fn etaLine(ui: *Ui, v: V) []const u8 {
    const status = json.str(v, "status");
    const a = ui.arena();
    if (eq(status, "delivered")) return ui.tf(labels.english("track.delivered_at") orelse "{when}", .{ .when = fmt.dateTime(a, json.str(v, "deliveredAt")) });
    if (json.num(v, "courier.etaMinutes")) |m| if (m != 0 and eq(status, "out_for_delivery"))
        return ui.tf(labels.english("track.arriving_in") orelse "{time}", .{ .time = fmt.duration(a, m) });
    if (inList(status, &.{ "cancelled", "returned", "returning" })) return "";
    if (json.str(v, "promisedBy").len > 0) return ui.tf(labels.english("track.expected_by") orelse "{when}", .{ .when = fmt.dateTime(a, json.str(v, "promisedBy")) });
    return "";
}

/// Area، city، governorate without repeats.
fn dropoffText(ui: *Ui, c: *const Cx, d: V) []const u8 {
    const parts = [_][]const u8{ json.str(d, "area"), json.str(d, "city"), json.str(d, if (c.ar()) "governorateName.ar" else "governorateName.en") };
    var out: std.ArrayList(u8) = .empty;
    for (parts, 0..) |p, i| {
        if (p.len == 0) continue;
        var dup = false;
        for (parts[0..i]) |q| if (eq(p, q)) {
            dup = true;
        };
        if (dup) continue;
        if (out.items.len > 0) out.appendSlice(ui.arena(), "، ") catch {};
        out.appendSlice(ui.arena(), p) catch {};
    }
    return out.items;
}

/// "Help the courier find you": share the phone's position, adjust the pin on the map, save.
fn locationCard(s: *const S, ui: *Ui, v: V) void {
    const k = kit.k;
    kit.card(ui, .{ .gap = 8.8 });
    const shared = s.location_shared or json.boolean(v, "locationShared");
    switch (s.pin_mode) {
        .idle, .locating => {
            kit.strong(ui, if (shared) L("track.location_shared") else L("track.help_courier"));
            kit.small(ui, L("track.location_hint"));
            kit.button(ui, if (shared) L("track.update_location") else L("track.share_location"), kit.act(A.locate, 0), .{ .variant = if (shared) .normal else .primary, .icon = icons.location_on, .busy = @intFromEnum(A.locate) });
        },
        .adjusting => {
            kit.strong(ui, L("track.help_courier"));
            if (s.accuracy > 200) {
                kit.noticeBegin(ui, .warn, icons.warning);
                ui.text(ui.tf(labels.english("track.pin_accuracy") orelse "{m}", .{ .m = @as(i64, @intFromFloat(@round(s.accuracy))) }), .{ .font_size = 13.6, .color = k.ink });
                kit.noticeEnd(ui);
            }
            // zui maps have no draggable markers: a tap moves the pin.
            kit.small(ui, if (s.pin != null) L("track.pin_adjust") else L("track.pin_tap"));
            kit.row(ui);
            kit.button(ui, L("track.pin_save"), kit.act(A.pin_save, 0), .{ .variant = .primary, .icon = icons.check, .busy = @intFromEnum(A.pin_save) });
            kit.button(ui, L("common.cancel"), kit.act(A.pin_cancel, 0), .{ .variant = .ghost });
            ui.end();
        },
    }
    kit.endCard(ui, .{});
}

/// The recipient picks the day they can receive the parcel (up to 14 days ahead).
fn dayCard(s: *const S, ui: *Ui, v: V) void {
    kit.card(ui, .{ .gap = 8.8 });
    const day = if (s.scheduled.len > 0) s.scheduled else json.str(v, "scheduledFor");
    kit.strong(ui, if (day.len > 0) ui.tf(labels.english("track.day_chosen") orelse "{date}", .{ .date = fmt.date(ui.arena(), day) }) else L("track.not_home"));
    kit.small(ui, L("track.day_hint"));
    kit.row(ui);
    kit.input(ui, f_day, .{ .placeholder = "YYYY-MM-DD", .ltr = true, .width = 200, .on_submit = kit.act(A.choose_day, 0) });
    kit.button(ui, L("track.choose_day"), kit.act(A.choose_day, 0), .{ .icon = icons.schedule, .busy = @intFromEnum(A.choose_day) });
    ui.end();
    kit.endCard(ui, .{});
}

fn stars(ui: *Ui, n: i64, size: f32, pressable: bool) void {
    const k = kit.k;
    ui.begin(.{ .direction = .row, .gap = 2.4 }, .{});
    var i: i64 = 1;
    while (i <= 5) : (i += 1) {
        const on = i <= n;
        ui.begin(.{ .padding = .all(1.6), .pressed_opacity = if (pressable) 0.6 else null }, .{ .on_press = if (pressable) kit.act(A.star, @intCast(i)) else null, .key = zui.key(@as(u64, @intCast(i)) + 40) });
        kit.icon(ui, if (on) icons.star_fill else icons.star, size, if (on) k.warn_ink else k.ink_4);
        ui.end();
    }
    ui.end();
}

/// After delivery: rate it (1-5) and/or report a problem; sent once.
fn feedbackCard(s: *const S, c: *const Cx, ui: *Ui, v: V) void {
    kit.card(ui, .{ .gap = 8.8 });
    if (sentFeedback(c)) |f| {
        kit.strong(ui, L("track.feedback_thanks"));
        const r = json.int(f, "rating");
        if (r > 0) stars(ui, r, 22.4, false);
        if (json.str(f, "problem").len > 0) kit.small(ui, ui.tf(labels.english("track.problem_sent") orelse "{carrier}", .{ .carrier = json.str(v, "carrier.name") }));
        kit.endCard(ui, .{});
        return;
    }
    kit.strong(ui, L("track.how_was_it"));
    stars(ui, s.rating, 33.6, true);
    kit.small(ui, L("track.any_problem"));
    var opts: std.ArrayList(core.Opt) = .empty;
    opts.append(ui.arena(), .{ .value = "", .label = L("track.no_problem") }) catch {};
    for (problems) |p| opts.append(ui.arena(), .{ .value = p, .label = labels.of("track.problem_", p) }) catch {};
    kit.select(ui, f_problem, opts.items, .{ .placeholder = L("track.no_problem"), .title = L("track.any_problem") });
    kit.input(ui, f_comment, .{ .kind = .multiline, .placeholder = L("track.feedback_comment") });
    ui.begin(.{ .direction = .row }, .{});
    kit.button(ui, L("track.feedback_send"), kit.act(A.send_feedback, 0), .{ .variant = .primary, .icon = icons.send, .flip = true, .busy = @intFromEnum(A.send_feedback) });
    ui.end();
    kit.endCard(ui, .{});
}

// ---- Tests --------------------------------------------------------------------------------

const testing = std.testing;
const track_json =
    \\{"trackingNumber":"TRF1234567890","status":"out_for_delivery","statusText":"Out for delivery","statusTextEn":"Out for delivery","statusTextAr":"خرجت للتوصيل",
    \\ "carrier":{"name":"Fast Express","phone":"0999123456","primaryColor":"#1d4ed8"},"merchant":{"name":"Acme Store"},
    \\ "deliveryCode":"4821","canSetLocation":true,"canReschedule":true,"canGiveFeedback":false,
    \\ "dropoff":{"area":"Mazzeh","city":"Damascus","governorateName":{"en":"Damascus","ar":"دمشق"}},
    \\ "courier":{"name":"Omar","vehicle":"motorbike","etaMinutes":12,"location":{"lat":33.5,"lng":36.28},"updatedAt":"2025-10-12T11:58:00.000Z"},
    \\ "events":[{"at":"2025-10-12T09:00:00.000Z","textEn":"Order placed","textAr":"x"},{"at":"2025-10-12T11:00:00.000Z","textEn":"With the courier","textAr":"y"}]}
;

test "public track: status, code, courier, pin and day; polling" {
    const app = @import("../app.zig");
    app.D.startWith(390, 800, "/t/abcdefghijklmnop1234");
    defer app.D.reset();
    try testing.expect(app.D.respond("/api/public/track/abcdefghijklmnop1234?lang=en", 200, track_json));
    try testing.expect(app.D.findText("Out for delivery") != 0);
    try testing.expect(app.D.findText("Arriving in about 12 min") != 0);
    try testing.expect(app.D.findText("4821") != 0);
    try testing.expect(app.D.findText("Omar") != 0);
    try testing.expect(app.D.findText("To Mazzeh، Damascus") != 0);
    try testing.expect(app.D.findText("Questions about delivery? Contact Fast Express") != 0);
    // The map follows the courier.
    const c = app.D.R.appState();
    try testing.expectEqual(@as(f64, 33.5), c.page.public_track.m.st.camera.center.lat);
    // Share my location: the phone's position becomes the pin; save sends it.
    try app.D.press("Share my location");
    app.D.locate(33.51234567, 36.29);
    try testing.expect(app.D.findText("Save this location") != 0);
    try app.D.press("Save this location");
    const sent = zui.host.fetches.items[zui.host.fetches.items.len - 1];
    try testing.expect(std.mem.endsWith(u8, sent.url, "/api/public/track/abcdefghijklmnop1234/location"));
    try testing.expect(std.mem.indexOf(u8, sent.body, "\"lat\":33.512346") != null);
    try testing.expect(app.D.respond("/location", 200, "{}"));
    try testing.expect(app.D.findText("You shared your exact location") != 0);
    // Another day.
    try app.D.typeInto("YYYY-MM-DD", "2025-10-15");
    try app.D.press("Save day");
    try testing.expect(app.D.respond("/reschedule", 200, "{\"scheduledFor\":\"2025-10-15\"}"));
    try testing.expect(app.D.findText("Delivery day: 15 Oct 2025") != 0);
    // Polling reloads.
    app.D.R.dispatch(.{ .timer = .{ .gen = c.gen, .id = T_POLL } });
    try testing.expect(app.D.pending("/api/public/track/abcdefghijklmnop1234?lang=en") != null);
}

test "public track: feedback after delivery; the embed hides the forms" {
    const app = @import("../app.zig");
    app.D.startWith(390, 800, "/t/abcdefghijklmnop1234");
    defer app.D.reset();
    try testing.expect(app.D.respond("/api/public/track/", 200,
        \\{"trackingNumber":"TRF1","status":"delivered","statusTextEn":"Delivered","statusTextAr":"تم","deliveredAt":"2025-10-12T09:00:00.000Z",
        \\ "carrier":{"name":"Fast Express"},"merchant":{"name":"Acme"},"canGiveFeedback":true,"events":[]}
    ));
    try testing.expect(app.D.findText("How was the delivery?") != 0);
    try app.D.press("Send");
    try testing.expect(app.D.findText("Choose a rating or a problem.") != 0);
    app.D.R.dispatch(kit.act(A.star, 4));
    try app.D.press("Send");
    const sent = zui.host.fetches.items[zui.host.fetches.items.len - 1];
    try testing.expectEqualStrings("{\"rating\":4}", sent.body);
    try testing.expect(app.D.respond("/feedback", 200, "{\"feedback\":{\"rating\":4}}"));
    try testing.expect(app.D.findText("Thank you for your feedback.") != 0);

    app.D.startWith(390, 800, "/embed/t/abcdefghijklmnop1234");
    try testing.expect(app.D.respond("/api/public/track/", 200,
        \\{"trackingNumber":"TRF1","status":"delivered","statusTextEn":"Delivered","carrier":{"name":"Fast"},"merchant":{"name":"Acme"},"canGiveFeedback":true,"canSetLocation":true,"events":[]}
    ));
    try testing.expect(app.D.findText("Delivered") != 0);
    try testing.expect(app.D.findText("How was the delivery?") == 0);
    try testing.expect(app.D.findText("Share my location") == 0);
}

test "public track: an unknown link" {
    const app = @import("../app.zig");
    app.D.startWith(390, 800, "/t/abcdefghijklmnop1234");
    defer app.D.reset();
    try testing.expect(app.D.respond("/api/public/track/", 404, "{}"));
    try testing.expect(app.D.findText("We could not find this shipment. Check the link.") != 0);
}
