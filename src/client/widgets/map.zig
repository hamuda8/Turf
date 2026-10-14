//! Turf's maps (Turf-js core/map.js) on zig-core's map engine, the one the Maps app uses: map
//! tiles from Wufour Maps (-Dmaps), Turf's own markers (`.marker`: an icon in a circle with an
//! action-coloured ring; `.off`, `.stale`, `.alert`, `.place`, `.me`), lines for routes, fitting to
//! points once, and tapping to pick a point. Coordinates are lat/lng.
//!
//! A page keeps a `Map` in its state, passes it `.map` and `.frame` events (`event`), and draws
//! it with `draw`. The size must be known to fit points: the page gives it (`setSize`), usually
//! `kit.width` and the height it draws.

const std = @import("std");
const zui = @import("zui");
const map = @import("map");
const core = @import("../core.zig");
const kit = @import("../kit.zig");
const icons = @import("../icons.zig");
const json = @import("../json.zig");

pub const LatLng = map.LatLng;
const Ui = core.Ui;
const Color = zui.Color;

/// Syria (`SYRIA_CENTER`, zoom 7).
pub const syria: LatLng = .{ .lat = 34.8, .lng = 38.6 };

pub const tile_url = core.maps_base ++ "/tiles/{z}/{x}/{y}.png";

pub const Map = struct {
    st: map.State = .{ .camera = .{ .center = syria, .zoom = 7 } },
    /// The content was fitted once; later the user's pan and zoom are left alone.
    fitted: bool = false,

    pub fn setSize(m: *Map, w: f32, h: f32) void {
        m.st.setViewport(w, h);
    }

    /// Handles the page's `.map` and `.frame` events; returns a tapped point.
    pub fn event(m: *Map, c: *core.Cx, e: core.Ev) ?LatLng {
        switch (e) {
            .map => |p| {
                const g = m.st.handle(p);
                if (g.tap) |at| return m.st.view().toMap(at[0], at[1]);
            },
            .frame => _ = m.st.step(c.env.time_ms),
            else => {},
        }
        return null;
    }

    /// Like `event`, with one pin the user can drag (`pickPoint` in core/map.js: drag the pin or
    /// tap the map): returns the new point after a drop or a tap.
    pub fn eventDrag(m: *Map, c: *core.Cx, e: core.Ev, pin: ?LatLng) ?LatLng {
        switch (e) {
            .map => |p| {
                var one: [1]map.Marker = undefined;
                var markers: []const map.Marker = &.{};
                if (pin) |at| {
                    one[0] = .{ .at = at, .size = 40, .draggable = true, .key = drag_key };
                    markers = &one;
                }
                const g = m.st.handleMarkers(p, markers);
                if (g.marker_drop) |d| return d.at;
                if (g.tap) |at| return m.st.view().toMap(at[0], at[1]);
            },
            .frame => _ = m.st.step(c.env.time_ms),
            else => {},
        }
        return null;
    }

    pub fn moving(m: *const Map) bool {
        return m.st.moving();
    }

    /// Shows all the points (`fitTo`): one point at zoom 15, several fitted with `padding`.
    pub fn fit(m: *Map, points: []const LatLng, o: struct { max_zoom: f64 = 15, padding: f32 = 40, animate: bool = true }) void {
        if (points.len == 0) return;
        m.fitted = true;
        if (points.len == 1 or m.st.width <= 0) {
            const z = @min(o.max_zoom, 15);
            if (o.animate and m.st.width > 0) m.st.flyTo(.{ .center = points[0], .zoom = z }, 800) else {
                m.st.camera.center = points[0];
                m.st.camera.zoom = z;
            }
            return;
        }
        const p = o.padding;
        m.st.fitBounds(points, .{ .top = p, .bottom = p, .left = p, .right = p }, if (o.animate) 800 else 1);
        if (m.st.animation) |*a| a.to.zoom = @min(a.to.zoom, o.max_zoom);
    }

    /// Fits once (lists that reload keep the user's view).
    pub fn fitOnce(m: *Map, points: []const LatLng) void {
        if (m.fitted) return;
        m.fit(points, .{});
    }

    pub fn flyTo(m: *Map, at: LatLng, zoom: ?f64) void {
        m.st.flyTo(.{ .center = at, .zoom = zoom }, 900);
    }

    pub fn center(m: *const Map) LatLng {
        return m.st.camera.center;
    }
};

/// A marker's look (`.marker` and its variants in app.css).
pub const Kind = enum { vehicle, off, stale, alert, place, me, pin, dot };

pub const Pin = struct {
    at: LatLng,
    icon: ?zui.Icon = null,
    kind: Kind = .vehicle,
    key: u64 = 0,
    /// Pressing it sends this (a courier on the fleet map).
    on_press: ?core.Msg = null,
    /// A small label under it.
    label: []const u8 = "",
    /// What it is, as Leaflet's `bindTooltip`: the web's tooltip, screen readers, a long
    /// press on the phones (when it can be pressed).
    tip: []const u8 = "",
    /// The pin `eventDrag` moves: drawn under the finger while it is dragged.
    draggable: bool = false,
};

const drag_key: u64 = 0x6472_6167;

pub const Line = struct {
    points: []const LatLng,
    color: ?Color = null,
    width: f32 = 5,
    dash: bool = false,
    opacity: f32 = 0.85,
};

pub const DrawOpts = struct {
    height: f32 = 360,
    /// null: the content width.
    width: ?f32 = null,
    radius: f32 = 22,
    pins: []const Pin = &.{},
    lines: []const Line = &.{},
    key: u64 = 0,
    /// Fills the parent (the live map) instead of a fixed height.
    fill: bool = false,
};

fn onMap(p: zui.Pointer) core.Msg {
    return .{ .map = p };
}

/// Draws the map (`.map`: 360 high, rounded) with its markers and lines.
pub fn draw(ui: *Ui, m: *const Map, o: DrawOpts) void {
    const k = kit.k;
    const w = o.width orelse kit.width;
    const h = o.height;
    var st = m.st;
    st.setViewport(w, h);
    if (st.moving()) ui.requestFrame(.frame);

    var routes: std.ArrayList(map.Route) = .empty;
    for (o.lines) |l| routes.append(ui.arena(), .{ .points = l.points, .color = l.color orelse k.a, .width = l.width, .dash = if (l.dash) .{ 8, 8 } else .{ 0, 0 }, .opacity = l.opacity }) catch {};

    ui.begin(.{ .width = if (o.fill) .fill else .{ .px = w }, .height = if (o.fill) .fill else .{ .px = h }, .radius = o.radius, .clip = true, .background = k.panel_3, .no_mirror = true }, .{ .key = o.key +% 11 });
    map.draw(core.Msg, ui, &st, .{ .tile_url = tile_url, .on_pointer = onMap, .routes = routes.items });
    // Turf's markers, over the map.
    const v = st.view();
    for (o.pins, 0..) |p, i| {
        const where = if (p.draggable) (if (st.drag) |d| d.at else p.at) else p.at;
        const at = v.toScreen(where) orelse continue;
        if (at[0] < -40 or at[1] < -40 or at[0] > w + 40 or at[1] > h + 40) continue;
        marker(ui, p, @floatCast(at[0]), @floatCast(at[1]), if (p.key != 0) p.key else zui.key(i + 7000));
    }
    ui.end();
}

fn marker(ui: *Ui, p: Pin, x: f32, y: f32, key: u64) void {
    const k = kit.k;
    switch (p.kind) {
        .me => {
            // A filled dot with a soft halo.
            ui.begin(.{ .position = .absolute, .inset = .{ .start = x - 18, .top = y - 18 }, .width = .{ .px = 36 }, .height = .{ .px = 36 }, .radius = 18, .background = k.accent_soft, .align_items = .center, .justify = .center }, .{ .key = key });
            ui.begin(.{ .width = .{ .px = 22 }, .height = .{ .px = 22 }, .radius = 11, .background = k.a, .border_width = 3, .border_color = k.panel }, .{});
            ui.end();
            ui.end();
        },
        .dot => {
            ui.begin(.{ .position = .absolute, .inset = .{ .start = x - 8, .top = y - 8 }, .width = .{ .px = 16 }, .height = .{ .px = 16 }, .radius = 8, .background = k.a, .border_width = 3, .border_color = k.panel }, .{ .key = key });
            ui.end();
        },
        .pin => {
            // The picked point: a pin whose tip is the point.
            ui.iconOutlined(p.icon orelse icons.location_on_fill, 40, k.a, k.panel, 1.5, .{ .position = .absolute, .inset = .{ .start = x - 20, .top = y - 36 } }, key);
        },
        else => {
            const size: f32 = if (p.kind == .place) 34 else 40;
            const ring: Color = switch (p.kind) {
                .off => k.ink_4,
                .stale => k.warn_ink,
                .alert => k.f,
                .place => k.p,
                else => k.a,
            };
            const ink: Color = switch (p.kind) {
                .off => k.ink_3,
                .stale => k.warn_ink,
                .alert => k.fatal_ink,
                .place => k.p,
                else => k.a,
            };
            ui.begin(.{
                .position = .absolute,
                .inset = .{ .start = x - size / 2, .top = y - size / 2 },
                .width = .{ .px = size },
                .height = .{ .px = size },
                .radius = if (p.kind == .place) 14 else size / 2,
                .background = k.panel,
                .border_width = 3,
                .border_color = ring,
                .align_items = .center,
                .justify = .center,
                .opacity = if (p.kind == .off) 0.85 else 1,
                .pressed_opacity = if (p.on_press != null) 0.7 else null,
            }, .{ .key = key, .on_press = p.on_press, .label = p.tip });
            if (p.icon) |ic| ui.icon(ic, 21.6, ink, .{}, 0);
            ui.end();
            if (p.label.len > 0) {
                ui.text(p.label, .{ .position = .absolute, .inset = .{ .start = x - 60, .top = y + size / 2 + 2 }, .width = .{ .px = 120 }, .text_align = .center, .font_size = 11, .weight = 700, .color = k.ink, .max_lines = 1 });
            }
        },
    }
}

/// `VEHICLE_ICON`: one symbol per vehicle type.
pub fn vehicleIcon(vehicle: []const u8) zui.Icon {
    const eq = std.mem.eql;
    if (eq(u8, vehicle, "foot")) return icons.directions_walk;
    if (eq(u8, vehicle, "bicycle")) return icons.pedal_bike;
    if (eq(u8, vehicle, "ebike")) return icons.electric_bike;
    if (eq(u8, vehicle, "motorbike")) return icons.two_wheeler;
    if (eq(u8, vehicle, "car")) return icons.directions_car;
    if (eq(u8, vehicle, "van")) return icons.airport_shuttle;
    if (eq(u8, vehicle, "truck")) return icons.local_shipping;
    return icons.package_2;
}

/// `PLACE_ICON`: markers for places.
pub fn placeIcon(kind: []const u8) zui.Icon {
    const eq = std.mem.eql;
    if (eq(u8, kind, "hub")) return icons.warehouse;
    if (eq(u8, kind, "branch")) return icons.storefront;
    if (eq(u8, kind, "pickup_point")) return icons.markunread_mailbox;
    if (eq(u8, kind, "shop")) return icons.store;
    if (eq(u8, kind, "home")) return icons.home;
    if (eq(u8, kind, "flag")) return icons.flag;
    if (eq(u8, kind, "parcel")) return icons.package_2;
    return icons.location_on;
}

/// A `{ lat, lng }` from the API.
pub fn ll(v: ?json.V, path: []const u8) ?LatLng {
    const o = json.get(v, path) orelse return null;
    const lat = json.num(o, "lat") orelse return null;
    const lng = json.num(o, "lng") orelse return null;
    return .{ .lat = lat, .lng = lng };
}

/// An external navigation link (Google Maps directions to a point).
pub fn externalNavUrl(a: std.mem.Allocator, to: LatLng) []const u8 {
    return std.fmt.allocPrint(a, "https://www.google.com/maps/dir/?api=1&destination={d},{d}", .{ to.lat, to.lng }) catch "";
}

/// Rounded to 6 decimals, as the JS client sends picked points.
pub fn round6(x: f64) f64 {
    return @round(x * 1e6) / 1e6;
}
