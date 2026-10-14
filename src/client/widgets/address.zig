//! An address, map first (Turf-js views/shared/address-form.js): search a place or tap the map
//! (or use the phone's location) and the governorate, city, area and street fill themselves
//! from Wufour Maps; everything typed is optional detail. Field names are prefixed
//! ("dropoff.city") so the server's errors land under the right field. Whatever the map filled
//! follows the pin when it moves; text typed by hand is never overwritten.
//!
//! A page keeps an `Address` in its state, calls `setup` in `enter` (each address on a page
//! gets its own form slots, action ids, timers and map tag), passes every event to `update`,
//! draws it with `view` and writes it into a request body with `write`.
//!
//! Two maps on one page: zui's map events do not say which map they come from, so each
//! address draws its map with its own pointer function that marks the finger id with the
//! address's `tag` (the top 4 bits); `update` takes only its own.

const std = @import("std");
const zui = @import("zui");
const map = @import("map");
const core = @import("../core.zig");
const kit = @import("../kit.zig");
const json = @import("../json.zig");
const icons = @import("../icons.zig");
const labels = @import("../labels.zig");
const mapw = @import("map.zig");
const gps = @import("../gps.zig");
const fmt = @import("../fmt.zig");

const Cx = core.Cx;
const Ui = core.Ui;
const V = json.V;
const L = labels.k;
pub const LatLng = mapw.LatLng;

// Form slots, from `Config.slot`.
pub const f_search: u16 = 0;
pub const f_gov: u16 = 1;
pub const f_city: u16 = 2;
pub const f_area: u16 = 3;
pub const f_street: u16 = 4;
pub const f_details: u16 = 5;
pub const f_phone: u16 = 6;
pub const f_name: u16 = 7;
pub const slots_used: u16 = 8;

// Action ids, from `Config.act` (presses and requests).
const a_locate: u16 = 0;
const a_choose: u16 = 1;
const a_more: u16 = 2;
const a_submit: u16 = 3;
const a_reverse: u16 = 4;
const a_search: u16 = 5;
pub const acts_used: u16 = 6;

// Timers, from `Config.timer`.
const t_search: u16 = 0;
const t_locate: u16 = 1;

// The fields the map filled (they follow the pin).
const auto_city: u4 = 1;
const auto_area: u4 = 2;
const auto_street: u4 = 4;
const auto_gov: u4 = 8;

pub const Config = struct {
    prefix: []const u8 = "dropoff",
    slot: u16 = 100,
    act: u16 = 300,
    timer: u16 = 300,
    /// 1..15: marks this map's pointer events.
    tag: u4 = 1,
    /// The pin's look (`placeIcon`): "home", "shop"... Empty: home for the recipient, shop else.
    kind: []const u8 = "",
    /// A recipient must be reachable.
    require_phone: bool = true,
};

/// A search result (Wufour Maps' place).
pub const Found = struct {
    name: []const u8 = "",
    label: []const u8 = "",
    street: []const u8 = "",
    area: []const u8 = "",
    city: []const u8 = "",
    state: []const u8 = "",
    lat: f64 = 0,
    lng: f64 = 0,
};

pub const Address = struct {
    cfg: Config = .{},
    point: ?LatLng = null,
    auto: u4 = 0,
    m: mapw.Map = .{},
    /// Every pin move gets a number; a lookup that comes back for an older pin is dropped.
    lookup_seq: u32 = 0,
    /// What the chosen search result said (wins over the reverse lookup).
    chosen: Found = .{},
    // Search.
    found: []const Found = &.{},
    highlighted: i32 = -1,
    last_query: []const u8 = "",
    search_seq: u32 = 0,
    search_timer: u32 = 0,
    searching: bool = false,
    results_open: bool = false,
    search_failed: bool = false,
    /// Enter was pressed: take the first result when it arrives.
    enter_text: ?[]const u8 = null,
    more_open: bool = false,
    locating: bool = false,
    /// Changes whenever the pin moves (pages compare it to see that prices are stale).
    pin_stamp: u32 = 0,
    pending_query: []const u8 = "",
    search_timer_fired: u32 = 0,

    pub fn setup(a: *Address, c: *Cx, cfg: Config) void {
        a.* = .{ .cfg = cfg };
        a.resetAuto(c, false);
        a.m.setSize(mapWidth(), mapHeight(c));
    }

    pub fn slot(a: *const Address, f: u16) u16 {
        return a.cfg.slot + f;
    }

    fn act(a: *const Address, x: u16) u16 {
        return a.cfg.act + x;
    }

    fn name(a: *const Address, ui: *Ui, field: []const u8) []const u8 {
        return kit.f(ui, "{s}.{s}", .{ a.cfg.prefix, field });
    }

    pub fn location(a: *const Address) ?LatLng {
        return a.point;
    }

    fn kind(a: *const Address) []const u8 {
        if (a.cfg.kind.len > 0) return a.cfg.kind;
        return if (std.mem.eql(u8, a.cfg.prefix, "dropoff")) "home" else "shop";
    }

    /// Fills the fields from a saved address (`setValue`): text that came with a saved pin
    /// describes that pin, so it follows the pin as well.
    pub fn setValue(a: *Address, c: *Cx, v: ?V) void {
        a.lookup_seq +%= 1; // a lookup in flight belongs to the old address
        c.setVal(a.slot(f_gov), json.str(v, "governorate"));
        c.setVal(a.slot(f_city), json.str(v, "city"));
        c.setVal(a.slot(f_area), json.str(v, "area"));
        c.setVal(a.slot(f_street), json.str(v, "street"));
        c.setVal(a.slot(f_details), json.str(v, "details"));
        c.setVal(a.slot(f_name), json.str(v, "name"));
        c.setVal(a.slot(f_phone), json.str(v, "phone"));
        a.point = mapw.ll(v, "location");
        a.resetAuto(c, a.point != null);
        c.setVal(a.slot(f_search), "");
        a.resetSearch();
        a.more_open = json.str(v, "street").len > 0 or json.str(v, "details").len > 0;
        a.pin_stamp +%= 1;
        a.m.setSize(mapWidth(), mapHeight(c));
        if (a.point) |p| {
            a.m.st.camera.center = p;
            a.m.st.camera.zoom = 16;
        } else if (a.govCenter(c)) |g| {
            a.m.st.camera.center = g;
            a.m.st.camera.zoom = 11;
        }
    }

    fn resetAuto(a: *Address, c: *const Cx, with_pin: bool) void {
        a.auto = 0;
        const pairs = [_]struct { u16, u4 }{ .{ f_city, auto_city }, .{ f_area, auto_area }, .{ f_street, auto_street }, .{ f_gov, auto_gov } };
        for (pairs) |p| if (with_pin or c.valTrim(a.slot(p[0])).len == 0) {
            a.auto |= p[1];
        };
    }

    fn resetSearch(a: *Address) void {
        a.search_timer +%= 1;
        a.search_seq +%= 1; // a reply still on its way must not reopen the list
        a.found = &.{};
        a.highlighted = -1;
        a.last_query = "";
        a.searching = false;
        a.results_open = false;
        a.search_failed = false;
        a.enter_text = null;
    }

    fn govCenter(a: *const Address, c: *const Cx) ?LatLng {
        const code = c.val(a.slot(f_gov));
        if (code.len == 0) return null;
        for (json.arr(c.meta.value, "governorates")) |g| {
            if (std.mem.eql(u8, json.str(g, "code"), code)) return mapw.ll(g, "center");
        }
        return null;
    }

    /// Empties what the map filled for the previous pin.
    fn forgetAuto(a: *Address, c: *Cx) void {
        if (a.auto & auto_city != 0) c.setVal(a.slot(f_city), "");
        if (a.auto & auto_area != 0) c.setVal(a.slot(f_area), "");
        if (a.auto & auto_street != 0) c.setVal(a.slot(f_street), "");
        if (a.auto & auto_gov != 0) c.setVal(a.slot(f_gov), "");
    }

    /// Puts a map place into the map-owned (or still empty) fields.
    fn fillFrom(a: *Address, c: *Cx, p: Found) void {
        const pairs = [_]struct { u16, u4, []const u8 }{ .{ f_city, auto_city, p.city }, .{ f_area, auto_area, p.area }, .{ f_street, auto_street, p.street } };
        for (pairs) |x| {
            if (a.auto & x[1] == 0 and c.valTrim(a.slot(x[0])).len > 0) continue;
            if (x[2].len > 0) {
                c.setVal(a.slot(x[0]), x[2]);
                a.auto |= x[1];
            }
        }
        if (a.auto & auto_gov != 0 or c.val(a.slot(f_gov)).len == 0) {
            if (governorateFromState(c, p.state)) |code| {
                c.setVal(a.slot(f_gov), code);
                a.auto |= auto_gov;
            }
        }
    }

    fn setPoint(a: *Address, c: *Cx, p: LatLng, place: ?Found) void {
        a.point = p;
        a.pin_stamp +%= 1;
        a.lookup_seq +%= 1;
        a.forgetAuto(c);
        a.chosen = .{};
        if (place) |x| {
            a.chosen = x;
            a.fillFrom(c, x);
        }
        // The reverse lookup fills what the search result left out (often the street).
        const url = c.print("{s}/api/v1/reverse?lat={d:.6}&lng={d:.6}&lang={s}", .{ core.maps_base, p.lat, p.lng, c.lang() });
        mapsGet(c, a.act(a_reverse), a.lookup_seq, url);
    }

    fn goTo(a: *Address, c: *Cx, p: LatLng, fly: bool, place: ?Found) void {
        a.setPoint(c, p, place);
        a.m.setSize(mapWidth(), mapHeight(c));
        if (fly) a.m.flyTo(p, 16) else {
            a.m.st.camera.center = p;
            a.m.st.camera.zoom = 16;
        }
    }

    fn choose(a: *Address, c: *Cx, i: usize) void {
        if (i >= a.found.len) return;
        const p = a.found[i];
        c.setVal(a.slot(f_search), if (p.label.len > 0) p.label else p.name);
        a.resetSearch();
        a.last_query = c.dupe(c.valTrim(a.slot(f_search)));
        a.goTo(c, .{ .lat = mapw.round6(p.lat), .lng = mapw.round6(p.lng) }, true, p);
    }

    fn runSearch(a: *Address, c: *Cx) void {
        const text = c.valTrim(a.slot(f_search));
        if (text.len < 2) {
            a.results_open = false;
            return;
        }
        if (std.mem.eql(u8, text, a.last_query) and a.found.len > 0) {
            a.results_open = true;
            return;
        }
        a.search_seq +%= 1;
        a.searching = true;
        const near: ?LatLng = a.point orelse a.govCenter(c);
        const url = if (near) |n|
            c.print("{s}/api/v1/search?q={s}&limit=5&lat={d:.5}&lng={d:.5}&lang={s}", .{ core.maps_base, core.encode(c.arena(), text), n.lat, n.lng, c.lang() })
        else
            c.print("{s}/api/v1/search?q={s}&limit=5&lang={s}", .{ core.maps_base, core.encode(c.arena(), text), c.lang() });
        a.pending_query = c.dupe(text);
        mapsGet(c, a.act(a_search), a.search_seq, url);
    }


    /// Handles the address's own events; true when the event was its.
    pub fn update(a: *Address, c: *Cx, e: core.Ev) bool {
        switch (e) {
            .text => |x| {
                if (x.slot < a.cfg.slot or x.slot >= a.cfg.slot + slots_used) return false;
                switch (x.slot - a.cfg.slot) {
                    f_search => {
                        a.search_timer +%= 1;
                        a.found = &.{};
                        a.highlighted = -1;
                        a.enter_text = null;
                        if (c.valTrim(a.slot(f_search)).len < 2) {
                            a.search_seq +%= 1;
                            a.searching = false;
                            a.results_open = false;
                        } else c.after(300, a.cfg.timer + t_search);
                    },
                    f_gov => {
                        a.auto &= ~auto_gov;
                        if (a.point == null) if (a.govCenter(c)) |g| {
                            a.m.setSize(mapWidth(), mapHeight(c));
                            a.m.flyTo(g, 11);
                        };
                    },
                    f_city => a.auto &= ~auto_city,
                    f_area => a.auto &= ~auto_area,
                    f_street => a.auto &= ~auto_street,
                    else => {},
                }
                return true;
            },
            .act => |x| {
                if (x.id < a.cfg.act or x.id >= a.cfg.act + acts_used) return false;
                switch (x.id - a.cfg.act) {
                    a_locate => a.locate(c),
                    a_choose => a.choose(c, x.arg),
                    a_more => a.more_open = !a.more_open,
                    a_submit => {
                        // Enter takes the first (or the highlighted) match, never the whole form.
                        a.search_timer +%= 1;
                        const text = c.valTrim(a.slot(f_search));
                        if (a.found.len > 0 and std.mem.eql(u8, text, a.last_query)) {
                            a.choose(c, if (a.highlighted >= 0) @intCast(a.highlighted) else 0);
                        } else {
                            a.enter_text = c.dupe(text);
                            a.runSearch(c);
                        }
                    },
                    else => {},
                }
                return true;
            },
            .done => |d| {
                if (d.id < a.cfg.act or d.id >= a.cfg.act + acts_used) return false;
                switch (d.id - a.cfg.act) {
                    a_reverse => if (d.ok and d.arg == a.lookup_seq) {
                        if (json.obj(d.v, "place")) |r| {
                            var p = foundOf(c, r);
                            // What the chosen result did say wins.
                            if (a.chosen.city.len > 0) p.city = a.chosen.city;
                            if (a.chosen.area.len > 0) p.area = a.chosen.area;
                            if (a.chosen.street.len > 0) p.street = a.chosen.street;
                            if (a.chosen.state.len > 0) p.state = a.chosen.state;
                            a.fillFrom(c, p);
                        }
                    },
                    a_search => if (d.arg == a.search_seq) {
                        a.searching = false;
                        if (d.ok and json.boolean(d.v, "success")) {
                            var list: std.ArrayList(Found) = .empty;
                            for (json.arr(d.v, "results")) |r| list.append(c.arena(), foundOf(c, r)) catch {};
                            a.found = list.items;
                            a.last_query = a.pending_query;
                            a.highlighted = if (a.found.len > 0) 0 else -1;
                            a.search_failed = false;
                            a.results_open = true;
                            if (a.enter_text) |text| {
                                a.enter_text = null;
                                // Typed on while it searched: not this one.
                                if (std.mem.eql(u8, c.valTrim(a.slot(f_search)), text) and a.found.len > 0) a.choose(c, 0);
                            }
                        } else {
                            a.found = &.{};
                            a.search_failed = true;
                            a.results_open = true;
                            a.enter_text = null;
                        }
                    },
                    else => {},
                }
                return true;
            },
            .timer => |id| {
                if (id == a.cfg.timer + t_search) {
                    // Only the last keystroke's timer searches.
                    if (a.search_timer_fired != a.search_timer) {
                        a.search_timer_fired = a.search_timer;
                        a.runSearch(c);
                    }
                    return true;
                }
                if (id == a.cfg.timer + t_locate) {
                    if (a.locating) a.locateFailed(c);
                    return true;
                }
                return false;
            },
            .map => |p| {
                if ((p.id >> 28) != a.cfg.tag) return false;
                var q = p;
                q.id &= 0x0fffffff;
                a.m.setSize(mapWidth(), mapHeight(c));
                // The pin can be dragged (`draggable: true` in Turf-js); a tap elsewhere moves it.
                const g = a.m.st.handleMarkers(q, a.pinMarker());
                if (g.marker_drop) |drop| {
                    c.setVal(a.slot(f_search), "");
                    a.resetSearch();
                    a.setPoint(c, .{ .lat = mapw.round6(drop.at.lat), .lng = mapw.round6(drop.at.lng) }, null);
                    return true;
                }
                if (g.tap) |at| if (a.m.st.view().toMap(at[0], at[1])) |ll| {
                    c.setVal(a.slot(f_search), "");
                    a.resetSearch();
                    a.setPoint(c, .{ .lat = mapw.round6(ll.lat), .lng = mapw.round6(ll.lng) }, null);
                };
                return true;
            },
            // Every map on the page moves on (not consumed).
            .frame => {
                _ = a.m.st.step(c.env.time_ms);
                return false;
            },
            .located => |l| {
                if (!a.locating) return false;
                switch (l) {
                    .fix => |f| {
                        a.locating = false;
                        _ = c.busy.remove(a.act(a_locate));
                        gps.want(c, false);
                        c.setVal(a.slot(f_search), "");
                        a.resetSearch();
                        a.goTo(c, .{ .lat = mapw.round6(f.lat), .lng = mapw.round6(f.lng) }, true, null);
                    },
                    .denied, .unavailable => a.locateFailed(c),
                }
                return true;
            },
            else => return false,
        }
    }


    /// The phone's own position: the quickest way for a person sending from where they stand.
    fn locate(a: *Address, c: *Cx) void {
        if (a.locating) return;
        // A position from the last minute will do (`maximumAge: 60_000`).
        if (c.gps.last_fix) |f| if (fmt.now() - f.at < 60_000) {
            c.setVal(a.slot(f_search), "");
            a.resetSearch();
            return a.goTo(c, .{ .lat = mapw.round6(f.lat), .lng = mapw.round6(f.lng) }, true, null);
        };
        a.locating = true;
        c.busy.put(core.gpa, a.act(a_locate), {}) catch {};
        gps.want(c, true);
        c.after(10_000, a.cfg.timer + t_locate);
    }

    fn locateFailed(a: *Address, c: *Cx) void {
        a.locating = false;
        _ = c.busy.remove(a.act(a_locate));
        gps.want(c, false);
        c.toast(L("address.locate_failed"), .err);
    }

    /// The one-line summary under the map.
    pub fn summary(a: *const Address, c: *const Cx, al: std.mem.Allocator) []const u8 {
        var out: std.ArrayList(u8) = .empty;
        const sep = if (c.ar()) "، " else ", ";
        for ([_]u16{ f_street, f_area, f_city }) |f| {
            const v = c.valTrim(a.slot(f));
            if (v.len == 0) continue;
            if (out.items.len > 0) out.appendSlice(al, sep) catch {};
            out.appendSlice(al, v) catch {};
        }
        const code = c.val(a.slot(f_gov));
        if (code.len > 0) {
            for (json.arr(c.meta.value, "governorates")) |g| if (std.mem.eql(u8, json.str(g, "code"), code)) {
                if (out.items.len > 0) out.appendSlice(al, sep) catch {};
                out.appendSlice(al, json.pick(g, "", c.lang())) catch {};
            };
        }
        if (out.items.len > 0) return out.items;
        return if (a.point != null) L("address.pin_set") else L("address.summary_hint");
    }

    /// Writes the fields (and the pin) as members of the open object `b`; empty fields are left
    /// out, as the JS form did.
    pub fn write(a: *const Address, c: *const Cx, b: *json.Obj) void {
        b.strOpt("phone", c.val(a.slot(f_phone)));
        b.strOpt("name", c.val(a.slot(f_name)));
        b.strOpt("governorate", c.val(a.slot(f_gov)));
        b.strOpt("city", c.val(a.slot(f_city)));
        b.strOpt("area", c.val(a.slot(f_area)));
        b.strOpt("street", c.val(a.slot(f_street)));
        b.strOpt("details", c.val(a.slot(f_details)));
        if (a.point) |p| writePoint(b, "location", p);
    }

    /// What prices depend on: the pin, the governorate and the city.
    pub fn whereKey(a: *const Address, c: *const Cx, al: std.mem.Allocator) []const u8 {
        const p = a.point orelse LatLng{ .lat = 0, .lng = 0 };
        return std.fmt.allocPrint(al, "{d},{d},{s},{s}", .{ p.lat, p.lng, c.valTrim(a.slot(f_gov)), c.valTrim(a.slot(f_city)) }) catch "";
    }

    // ---- View -------------------------------------------------------------------------------

    /// Draws the address (`fieldset.address`), with `title` as its legend when not empty.
    pub fn view(a: *const Address, c: *const Cx, ui: *Ui, title: []const u8) void {
        const k = kit.k;
        const w = kit.width;
        ui.begin(.{ .gap = 14.4 }, .{});
        if (title.len > 0) kit.h2(ui, title);
        // Search, my location, the map, the summary.
        ui.begin(.{ .gap = 8.8 }, .{});
        ui.begin(.{ .direction = .row, .gap = 9.6, .align_items = .end }, .{});
        ui.begin(.{ .grow = 1, .gap = 6.4 }, .{});
        kit.fieldBegin(ui, L("address.search"), false);
        ui.begin(.{ .direction = .row, .align_items = .center, .gap = 6 }, .{});
        kit.input(ui, a.slot(f_search), .{ .kind = .search, .placeholder = L("address.search_placeholder"), .grow = 1, .on_submit = .{ .act = .{ .id = a.act(a_submit) } } });
        if (a.searching) kit.spinner(ui, 18, k.a);
        ui.end();
        kit.fieldEnd(ui, "", "");
        ui.end();
        const narrow = ui.env.width <= 480;
        kit.button(ui, if (narrow) "" else L("address.locate_me"), .{ .act = .{ .id = a.act(a_locate) } }, .{ .size = .sm, .icon = icons.navigation, .busy = a.act(a_locate) });
        ui.end();
        if (a.results_open) a.results(ui);
        a.drawMap(ui, c, w);
        // The summary.
        ui.begin(.{ .direction = .row, .gap = 8.8, .align_items = .start, .padding = .xy(12.8, 9.6), .radius = 16, .background = if (a.point != null) k.accent_soft else k.panel_2 }, .{});
        kit.icon(ui, if (a.point != null) icons.location_on else icons.info, 20, k.a);
        ui.text(a.summary(c, ui.arena()), .{ .font_size = 14.1, .color = if (a.point != null) k.ink else k.ink_2, .grow = 1 });
        ui.end();
        if (c.fieldError(a.name(ui, "location"))) |err| ui.text(err, .{ .font_size = 12.5, .weight = 650, .color = k.fatal_ink });
        ui.end();

        // Phone and name.
        var g = kit.formGrid(ui, 2);
        g.cell();
        kit.field(ui, L("common.phone"), a.slot(f_phone), .{ .required = a.cfg.require_phone, .hint = if (a.cfg.require_phone) "" else L("address.phone_optional"), .input = .{ .kind = .phone, .ltr = true, .placeholder = "09xx xxx xxx", .name = a.name(ui, "phone") } });
        g.endCell();
        g.cell();
        kit.field(ui, L("address.name_optional"), a.slot(f_name), .{ .input = .{ .name = a.name(ui, "name") } });
        g.endCell();
        g.end();

        // More details (a closed panel unless there is a street or details).
        ui.begin(.{ .padding = .xy(14.4, 11.2), .radius = 16, .background = k.panel_2, .gap = 12 }, .{});
        ui.begin(.{ .direction = .row, .gap = 6.4, .align_items = .center, .pressed_opacity = 0.7 }, .{ .on_press = .{ .act = .{ .id = a.act(a_more) } } });
        kit.icon(ui, if (a.more_open) icons.expand_less else icons.expand_more, 20.8, k.ink_3);
        ui.text(L("address.more_details"), .{ .font_size = 14.1, .weight = 600, .color = k.ink_2 });
        ui.end();
        if (a.more_open) {
            var opts: std.ArrayList(core.Opt) = .empty;
            for (json.arr(c.meta.value, "governorates")) |gv| opts.append(ui.arena(), .{ .value = json.str(gv, "code"), .label = json.pick(gv, "", c.lang()) }) catch {};
            var fg = kit.formGrid(ui, 4);
            fg.cell();
            kit.selectField(ui, L("org.governorate"), a.slot(f_gov), opts.items, .{ .name = a.name(ui, "governorate") });
            fg.endCell();
            fg.cell();
            kit.field(ui, L("address.city"), a.slot(f_city), .{ .input = .{ .name = a.name(ui, "city") } });
            fg.endCell();
            fg.cell();
            kit.field(ui, L("address.area"), a.slot(f_area), .{ .input = .{ .name = a.name(ui, "area") } });
            fg.endCell();
            fg.cell();
            kit.field(ui, L("address.street"), a.slot(f_street), .{ .input = .{ .name = a.name(ui, "street") } });
            fg.endCell();
            fg.end();
            kit.field(ui, L("address.details"), a.slot(f_details), .{ .input = .{ .placeholder = L("address.details_placeholder"), .name = a.name(ui, "details") } });
        }
        ui.end();
        ui.end();
    }

    fn results(a: *const Address, ui: *Ui) void {
        const k = kit.k;
        ui.begin(.{ .padding = .all(5.6), .radius = 16, .background = k.panel, .border_width = 1, .border_color = k.line_soft, .gap = 2 }, .{});
        if (a.search_failed) {
            ui.begin(.{ .padding = .xy(11.2, 9.6) }, .{});
            kit.small(ui, L("address.search_unavailable"));
            ui.end();
        } else if (a.found.len == 0) {
            ui.begin(.{ .padding = .xy(11.2, 9.6) }, .{});
            kit.small(ui, L("address.search_none"));
            ui.end();
        } else for (a.found, 0..) |p, i| {
            const on = a.highlighted == @as(i32, @intCast(i));
            ui.begin(.{ .direction = .row, .gap = 6.4, .align_items = .center, .padding = .xy(11.2, 9.6), .radius = 12, .background = if (on) k.accent_soft else null, .pressed_background = k.accent_soft }, .{ .on_press = .{ .act = .{ .id = a.act(a_choose), .arg = @intCast(i) } }, .key = zui.key(i + 1) });
            kit.icon(ui, icons.location_on, 18, k.ink_3);
            ui.begin(.{ .grow = 1, .gap = 1.6 }, .{});
            ui.text(if (p.name.len > 0) p.name else p.label, .{ .font_size = 15, .color = if (on) k.a else k.ink, .max_lines = 1 });
            if (p.label.len > 0 and !std.mem.eql(u8, p.label, p.name)) ui.text(p.label, .{ .font_size = 13.6, .color = k.ink_2, .max_lines = 1 });
            ui.end();
            ui.end();
        }
        ui.end();
    }

    /// The pin as a draggable map marker (for the gestures; it is drawn below as Turf's marker).
    fn pinMarker(a: *const Address) []const map.Marker {
        const p = a.point orelse return &.{};
        const S2 = struct {
            var one: [1]map.Marker = undefined;
        };
        S2.one[0] = .{ .at = p, .size = 34, .draggable = true, .key = pin_key };
        return &S2.one;
    }

    fn drawMap(a: *const Address, ui: *Ui, c: *const Cx, w: f32) void {
        const k = kit.k;
        const h = mapHeight(c);
        var st = a.m.st;
        st.setViewport(w, h);
        if (st.moving()) ui.requestFrame(.frame);
        ui.begin(.{ .width = .{ .px = w }, .height = .{ .px = h }, .radius = 22, .clip = true, .background = k.panel_3, .no_mirror = true }, .{ .key = zui.key(a.cfg.prefix) +% 11 });
        map.draw(core.Msg, ui, &st, .{ .tile_url = mapw.tile_url, .on_pointer = pointer_fns[a.cfg.tag] });
        // While dragged, the pin follows the finger.
        const shown: ?LatLng = if (st.drag) |d| d.at else a.point;
        if (shown) |p| if (st.view().toScreen(p)) |at| {
            const x: f32 = @floatCast(at[0]);
            const y: f32 = @floatCast(at[1]);
            // `placeIcon(kind)`: the place marker (a rounded square with the icon).
            ui.begin(.{ .position = .absolute, .inset = .{ .start = x - 17, .top = y - 17 }, .width = .{ .px = 34 }, .height = .{ .px = 34 }, .radius = 14, .background = k.panel, .border_width = 3, .border_color = k.p, .align_items = .center, .justify = .center }, .{ .key = zui.key(a.cfg.prefix) +% 12 });
            ui.icon(mapw.placeIcon(a.kind()), 21.6, k.p, .{}, 0);
            ui.end();
        };
        ui.end();
    }
};

const pin_key: u64 = 0x7069_6e;

fn mapWidth() f32 {
    return @max(kit.width - 40, 200);
}

fn mapHeight(c: *const Cx) f32 {
    return if (c.env.width <= 640) 220 else 260;
}

pub fn writePoint(b: *json.Obj, n: []const u8, p: LatLng) void {
    b.begin(n);
    b.num("lat", p.lat);
    b.num("lng", p.lng);
    b.end();
}

fn foundOf(c: *Cx, r: V) Found {
    return .{
        .name = c.dupe(json.str(r, "name")),
        .label = c.dupe(json.str(r, "label")),
        .street = c.dupe(json.str(r, "street")),
        .area = c.dupe(json.str(r, "area")),
        .city = c.dupe(json.str(r, "city")),
        .state = c.dupe(json.str(r, "state")),
        .lat = json.numOr(r, "lat", 0),
        .lng = json.numOr(r, "lng", 0),
    };
}

fn markPointer(comptime tag: u4) *const fn (zui.Pointer) core.Msg {
    return struct {
        fn f(p: zui.Pointer) core.Msg {
            var q = p;
            q.id = (q.id & 0x0fffffff) | (@as(u32, tag) << 28);
            return .{ .map = q };
        }
    }.f;
}

const pointer_fns = blk: {
    var out: [16]*const fn (zui.Pointer) core.Msg = undefined;
    for (0..16) |i| out[i] = markPointer(@intCast(i));
    break :blk out;
};

/// Requests to Wufour Maps go without Turf's headers (no account token for another service);
/// the answer comes back as `.done` like any action.
fn mapsGet(c: *Cx, id: u16, arg: u32, url: []const u8) void {
    c.quietErrors(id);
    c.busy.put(core.gpa, id, {}) catch {};
    c.act_args.put(core.gpa, id, arg) catch {};
    c.fx.fetch(.{ .url = url, .method = .GET, .tag = core.tag(.act, c.gen, id) }, onResp);
}

fn onResp(r: zui.Response) core.Msg {
    return .{ .resp = r };
}

// ---- Governorate from the map's "state" -------------------------------------------------------

/// Lower case, no Arabic diacritics or tatweel, alef forms as plain alef, teh marbuta as heh
/// (`norm`), for comparing names.
pub fn norm(al: std.mem.Allocator, s: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var view = std.unicode.Utf8View.init(s) catch return s;
    var it = view.iterator();
    while (it.nextCodepoint()) |cp0| {
        var cp = cp0;
        if (cp >= 0x064B and cp <= 0x0652) continue;
        if (cp == 0x0640) continue;
        if (cp == 0x0623 or cp == 0x0625 or cp == 0x0622) cp = 0x0627;
        if (cp == 0x0629) cp = 0x0647;
        if (cp < 128) cp = std.ascii.toLower(@intCast(cp));
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch continue;
        out.appendSlice(al, buf[0..n]) catch {};
    }
    return out.items;
}

/// The governorate code a map result's "state" text points at (the server decides for real).
pub fn governorateFromState(c: *Cx, state: []const u8) ?[]const u8 {
    const al = c.arena();
    const s = norm(al, state);
    if (s.len == 0) return null;
    for (json.arr(c.meta.value, "governorates")) |g| {
        const en = norm(al, json.str(g, "en"));
        const ar_ = norm(al, json.str(g, "ar"));
        if ((en.len > 0 and std.mem.indexOf(u8, s, en) != null) or (ar_.len > 0 and std.mem.indexOf(u8, s, ar_) != null)) {
            const code = json.str(g, "code");
            return if (code.len > 0) c.dupe(code) else null;
        }
    }
    return null;
}

// ---- Form helpers shared by the pages ---------------------------------------------------------

/// A number field as the JS form sent it: a number, the raw text when it is not one, nothing
/// when empty.
pub fn numField(b: *json.Obj, n: []const u8, raw_in: []const u8) void {
    const raw = std.mem.trim(u8, raw_in, " \t\r\n");
    if (raw.len == 0) return;
    if (std.fmt.parseFloat(f64, raw)) |x| {
        if (std.math.isFinite(x)) return b.num(n, x);
    } else |_| {}
    b.str(n, raw);
}

test "names compare without diacritics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("محافظه دمشق", norm(arena.allocator(), "مُحافظة دمشق"));
    try std.testing.expectEqualStrings("damascus governorate", norm(arena.allocator(), "Damascus Governorate"));
    try std.testing.expectEqualStrings("اربد", norm(arena.allocator(), "إربد"));
}
