//! Hubs, branches and pickup points, placed on the map (Turf-js views/carrier/hubs.js). The
//! dialog places the point by a tap on the map or by searching a place (Wufour Maps' HTTP API,
//! which Turf-js reached through its maps library).

const std = @import("std");
const zui = @import("zui");
const core = @import("../core.zig");
const kit = @import("../kit.zig");
const shell = @import("../shell.zig");
const json = @import("../json.zig");
const icons = @import("../icons.zig");
const labels = @import("../labels.zig");
const parts = @import("../widgets/parts.zig");
const mapw = @import("../widgets/map.zig");
const cm = @import("../widgets/common.zig");

const Cx = core.Cx;
const Ui = core.Ui;
const V = json.V;
const L = labels.k;
const eq = std.mem.eql;

const d_hubs: u8 = 0;
const d_found: u8 = 1;

const f_name: u16 = 0;
const f_code: u16 = 1;
const f_type: u16 = 2;
const f_gov: u16 = 3;
const f_city: u16 = 4;
const f_phone: u16 = 5;
const f_address: u16 = 6;
const f_search: u16 = 7;

const t_search: u16 = 1;
const dialog_map_h: f32 = 300;

const A = enum(u16) { add = 1, edit, open, close, save, active, search, choose, search_submit };

const types = [_][]const u8{ "hub", "branch", "pickup_point" };

pub const S = struct {
    m: mapw.Map = .{},
    fitted: bool = false,
    // The dialog.
    open: bool = false,
    editing: ?[]const u8 = null,
    active: bool = true,
    point: ?mapw.LatLng = null,
    dm: mapw.Map = .{},
    search_seq: u32 = 0,
    searching: bool = false,
    search_failed: bool = false,
    /// Enter was pressed before the answer: take its first place.
    choose_first: bool = false,
};

pub fn title(_: *const S, _: *const Cx) []const u8 {
    return L("nav.hubs");
}

pub fn actions(_: *const S, _: *const Cx, ui: *Ui) void {
    kit.button(ui, L("hubs.add"), kit.act(A.add, 0), .{ .variant = .primary, .icon = icons.add });
}

pub fn enter(_: *S, c: *Cx) void {
    c.load(d_hubs, c.orgUrl("/carrier/hubs"));
    c.quietErrors(@intFromEnum(A.search));
}

fn hubAt(c: *const Cx, i: u32) ?V {
    const list = json.arr(c.data(d_hubs), "");
    return if (i < list.len) list[i] else null;
}

fn openDialog(s: *S, c: *Cx, hub: ?V) void {
    s.open = true;
    s.editing = if (hub) |h| c.dupe(cm.docId(h)) else null;
    s.active = if (hub) |h| json.boolean(h, "active") else true;
    s.point = if (hub) |h| mapw.ll(h, "location") else null;
    s.dm = .{};
    resetSearch(s, c);
    c.setVal(f_search, "");
    c.setVal(f_name, json.str(hub, "name"));
    c.setVal(f_code, json.str(hub, "code"));
    c.setVal(f_type, json.strOr(hub, "type", "hub"));
    c.setVal(f_gov, json.strOr(hub, "governorate", json.str(c.orgV(), "contact.governorate")));
    c.setVal(f_city, json.str(hub, "city"));
    c.setVal(f_phone, json.str(hub, "phone"));
    c.setVal(f_address, json.str(hub, "address"));
    c.clearFieldError();
    if (s.point) |p| {
        s.dm.st.camera.center = p;
        s.dm.st.camera.zoom = 15;
    } else centerOnGov(s, c);
}

fn centerOnGov(s: *S, c: *Cx) void {
    const g = cm.govEntry(c, c.val(f_gov)) orelse return;
    const p = mapw.ll(g, "center") orelse return;
    s.dm.st.camera.center = p;
    s.dm.st.camera.zoom = 11;
}

fn resetSearch(s: *S, c: *Cx) void {
    s.search_seq += 1;
    s.searching = false;
    s.search_failed = false;
    s.choose_first = false;
    c.slots[d_found].reset();
}

fn runSearch(s: *S, c: *Cx) void {
    const text = c.valTrim(f_search);
    if (text.len < 2) return resetSearch(s, c);
    s.search_seq += 1;
    s.searching = true;
    s.search_failed = false;
    const near: ?mapw.LatLng = s.point orelse if (cm.govEntry(c, c.val(f_gov))) |g| mapw.ll(g, "center") else null;
    const url = if (near) |p|
        c.print("{s}/api/v1/search?q={s}&limit=5&lat={d:.5}&lng={d:.5}&lang={s}", .{ core.maps_base, core.encode(c.arena(), text), p.lat, p.lng, c.lang() })
    else
        c.print("{s}/api/v1/search?q={s}&limit=5&lang={s}", .{ core.maps_base, core.encode(c.arena(), text), c.lang() });
    c.sendArg(@intFromEnum(A.search), s.search_seq, .GET, url, "");
}

fn choose(s: *S, c: *Cx, i: u32) void {
    const list = json.arr(c.data(d_found), "results");
    if (i >= list.len) return;
    const p = list[i];
    c.setVal(f_search, json.strOr(p, "label", json.str(p, "name")));
    const at: mapw.LatLng = .{ .lat = mapw.round6(json.numOr(p, "lat", 0)), .lng = mapw.round6(json.numOr(p, "lng", 0)) };
    resetSearch(s, c);
    s.point = at;
    s.dm.flyTo(at, 16);
}

fn save(s: *S, c: *Cx) void {
    var b = json.Obj.init(c.arena());
    b.strOpt("name", c.val(f_name));
    b.strOpt("code", c.val(f_code));
    b.strOpt("type", c.val(f_type));
    b.strOpt("governorate", c.val(f_gov));
    b.strOpt("city", c.val(f_city));
    b.strOpt("phone", c.val(f_phone));
    b.strOpt("address", c.val(f_address));
    if (s.editing != null) b.boolean("active", s.active);
    if (s.point) |p| {
        b.begin("location");
        b.num("lat", p.lat);
        b.num("lng", p.lng);
        b.end();
    } else b.nul("location");
    if (s.editing) |id|
        c.send(@intFromEnum(A.save), .PATCH, c.orgUrl(c.print("/carrier/hubs/{s}", .{id})), b.done())
    else
        c.send(@intFromEnum(A.save), .POST, c.orgUrl("/carrier/hubs"), b.done());
}

pub fn update(s: *S, c: *Cx, e: core.Ev) void {
    switch (e) {
        .map, .frame => {
            if (s.open) {
                if (s.dm.eventDrag(c, e, s.point)) |p| {
                    // A pin dropped by hand wins over the search.
                    resetSearch(s, c);
                    c.setVal(f_search, "");
                    s.point = .{ .lat = mapw.round6(p.lat), .lng = mapw.round6(p.lng) };
                }
            } else _ = s.m.event(c, e);
        },
        .data => |n| if (n == d_hubs and !s.fitted and c.slot(d_hubs).state == .ok) {
            s.fitted = true;
            var pts: std.ArrayList(mapw.LatLng) = .empty;
            for (json.arr(c.data(d_hubs), "")) |h| if (mapw.ll(h, "location")) |p| pts.append(c.arena(), p) catch {};
            s.m.setSize(kit.width - 40, 360);
            s.m.fit(pts.items, .{ .max_zoom = 13, .animate = false });
        },
        .text => |x| {
            if (!s.open) return;
            if (x.slot == f_gov and s.point == null) centerOnGov(s, c);
            if (x.slot == f_search) {
                s.search_seq += 1;
                s.choose_first = false;
                c.slots[d_found].reset();
                if (c.valTrim(f_search).len < 2) return resetSearch(s, c);
                c.after(300, t_search);
            }
        },
        .timer => |id| if (id == t_search and s.open and !s.searching and c.slot(d_found).state == .idle) runSearch(s, c),
        .act => |a| switch (@as(A, @enumFromInt(a.id))) {
            .add => openDialog(s, c, null),
            .edit => if (hubAt(c, a.arg)) |h| openDialog(s, c, h),
            .open => if (hubAt(c, a.arg)) |h| c.go(c.print("/hubs/{s}", .{cm.docId(h)})),
            .close => {
                s.open = false;
                resetSearch(s, c);
            },
            .active => s.active = !s.active,
            .save => save(s, c),
            .choose => choose(s, c, a.arg),
            .search_submit => {
                // Never submits the dialog from the search box.
                if (json.arr(c.data(d_found), "results").len > 0) return choose(s, c, 0);
                s.choose_first = true;
                if (!s.searching) {
                    runSearch(s, c);
                    s.choose_first = true;
                }
            },
            .search => {},
        },
        .done => |d| switch (@as(A, @enumFromInt(d.id))) {
            .search => {
                if (d.arg != s.search_seq or !s.open) return;
                s.searching = false;
                if (!d.ok or !json.boolean(d.v, "success")) {
                    s.search_failed = true;
                    cm.keep(c, d_found, "{\"results\":[]}");
                    return;
                }
                cm.keep(c, d_found, d.body);
                if (s.choose_first) {
                    s.choose_first = false;
                    if (json.arr(c.data(d_found), "results").len > 0) choose(s, c, 0);
                }
            },
            .save => if (d.ok) {
                s.open = false;
                c.toast(L("common.saved"), .ok);
                c.load(d_hubs, c.orgUrl("/carrier/hubs"));
            },
            else => {},
        },
        else => {},
    }
}

pub fn view(s: *const S, c: *const Cx, ui: *Ui) void {
    if (!kit.gate(ui, &.{d_hubs})) return;
    const list = json.arr(c.data(d_hubs), "");
    kit.stack(ui);
    kit.card(ui, .{});
    var pins: std.ArrayList(mapw.Pin) = .empty;
    for (list, 0..) |h, i| if (mapw.ll(h, "location")) |p| pins.append(ui.arena(), .{ .at = p, .kind = if (json.boolean(h, "active")) .place else .off, .icon = mapw.placeIcon(json.str(h, "type")), .key = zui.key(cm.docId(h)), .on_press = kit.act(A.edit, @intCast(i)) }) catch {};
    mapw.draw(ui, &s.m, .{ .width = kit.width - 40, .pins = pins.items, .key = zui.key("hubs-map") });
    kit.endCard(ui, .{});
    if (list.len == 0) {
        kit.emptyBegin(ui, L("hubs.none"));
        kit.button(ui, L("hubs.add"), kit.act(A.add, 0), .{ .variant = .primary, .icon = icons.add });
        kit.emptyEnd(ui);
    } else {
        var tb = kit.Table.begin(ui, &.{
            .{ .label = L("common.name"), .grow = 2 },
            .{ .label = L("hubs.type") },
            .{ .label = L("org.governorate") },
            .{ .label = L("common.status") },
            .{ .width = 120 },
        });
        for (list, 0..) |h, i| {
            tb.row(kit.act(A.open, @intCast(i)), zui.key(cm.docId(h)));
            tb.cell(false);
            kit.strong(ui, json.str(h, "name"));
            kit.mono(ui, json.str(h, "code"), .{ .size = 13.6, .color = kit.k.ink_2 });
            tb.endCell();
            tb.cell(true);
            kit.text(ui, labels.of("hubs.type.", json.str(h, "type")), .{});
            tb.endCell();
            tb.cell(true);
            kit.text(ui, parts.placeText(ui.arena(), c, h, .{}), .{});
            tb.endCell();
            tb.cell(true);
            const on = json.boolean(h, "active");
            kit.badge(ui, if (on) L("hubs.active") else L("hubs.inactive"), if (on) .green else .plain);
            tb.endCell();
            tb.cell(false);
            kit.button(ui, L("hubs.edit"), kit.act(A.edit, @intCast(i)), .{ .size = .sm, .variant = .ghost, .icon = icons.edit });
            tb.endCell();
            tb.endRow();
        }
        tb.end();
    }
    ui.end();
}

pub fn overlay(s: *const S, c: *const Cx, ui: *Ui) void {
    if (!s.open) return;
    const k = kit.k;
    const a = ui.arena();
    shell.modalBegin(ui, .{ .title = if (s.editing != null) L("hubs.edit") else L("hubs.add"), .close = kit.act(A.close, 0), .wide = true, .key = zui.key("hub-dialog") });
    var type_opts: [types.len]core.Opt = undefined;
    for (types, 0..) |x, i| type_opts[i] = .{ .value = x, .label = labels.of("hubs.type.", x) };
    var g = kit.formGrid(ui, 7);
    g.cell();
    kit.field(ui, L("common.name"), f_name, .{ .required = true, .input = .{ .name = "name" } });
    g.endCell();
    g.cell();
    kit.field(ui, L("hubs.code"), f_code, .{ .required = true, .hint = L("hubs.code_hint"), .input = .{ .name = "code", .ltr = true, .placeholder = "DAM1" } });
    g.endCell();
    g.cell();
    kit.selectField(ui, L("hubs.type"), f_type, &type_opts, .{ .required = true, .name = "type" });
    g.endCell();
    g.cell();
    kit.selectField(ui, L("org.governorate"), f_gov, cm.govOptions(c, a), .{ .required = true, .name = "governorate" });
    g.endCell();
    g.cell();
    kit.field(ui, L("hubs.city"), f_city, .{ .required = true, .input = .{ .name = "city" } });
    g.endCell();
    g.cell();
    kit.field(ui, L("common.phone"), f_phone, .{ .input = .{ .kind = .phone, .ltr = true, .name = "phone" } });
    g.endCell();
    g.cell();
    kit.field(ui, L("hubs.address"), f_address, .{ .input = .{ .name = "address" } });
    g.endCell();
    g.end();
    // The location: search, the map, the coordinates.
    kit.fieldBegin(ui, L("hubs.location"), true);
    ui.begin(.{ .direction = .row, .gap = 8, .align_items = .center }, .{});
    kit.input(ui, f_search, .{ .kind = .search, .placeholder = L("address.search_placeholder"), .on_submit = kit.act(A.search_submit, 0), .grow = 1 });
    if (s.searching) kit.spinner(ui, 18, k.ink_3);
    ui.end();
    searchResults(s, c, ui);
    var pin: [1]mapw.Pin = undefined;
    const pins: []const mapw.Pin = if (s.point) |p| blk: {
        pin[0] = .{ .at = p, .kind = .place, .icon = mapw.placeIcon(c.val(f_type)), .key = zui.key("hub-point"), .draggable = true };
        break :blk &pin;
    } else &.{};
    mapw.draw(ui, &s.dm, .{ .height = dialog_map_h, .pins = pins, .key = zui.key("hub-dialog-map") });
    ui.begin(.{ .no_mirror = true }, .{});
    kit.small(ui, if (s.point) |p| kit.f(ui, "{d}, {d}", .{ p.lat, p.lng }) else L("hubs.click_map"));
    ui.end();
    kit.fieldEnd(ui, "location", "");
    if (s.editing != null) kit.check(ui, L("hubs.active"), s.active, kit.act(A.active, 0));
    shell.modalFoot(ui);
    shell.modalButton(ui, L("common.cancel"), kit.act(A.close, 0), .{});
    shell.modalButton(ui, L("common.save"), kit.act(A.save, 0), .{ .variant = .primary, .busy = @intFromEnum(A.save) });
    shell.modalEnd(ui, true);
}

fn searchResults(s: *const S, c: *const Cx, ui: *Ui) void {
    const k = kit.k;
    if (c.slot(d_found).state != .ok) return;
    const list = json.arr(c.data(d_found), "results");
    ui.begin(.{ .padding = .all(5.6), .radius = 16, .background = k.panel_2, .gap = 2 }, .{});
    if (s.search_failed) {
        ui.begin(.{ .padding = .xy(11.2, 9.6) }, .{});
        kit.small(ui, L("address.search_unavailable"));
        ui.end();
    } else if (list.len == 0) {
        ui.begin(.{ .padding = .xy(11.2, 9.6) }, .{});
        kit.small(ui, L("address.search_none"));
        ui.end();
    }
    for (list, 0..) |p, i| {
        const name = json.strOr(p, "name", json.str(p, "label"));
        const label = json.str(p, "label");
        ui.begin(.{ .direction = .row, .gap = 6.4, .align_items = .center, .padding = .xy(11.2, 9.6), .radius = 12, .pressed_background = k.accent_soft }, .{ .on_press = kit.act(A.choose, @intCast(i)), .key = zui.key(i + 300) });
        kit.icon(ui, icons.location_on, 18, k.ink_3);
        ui.begin(.{ .grow = 1, .gap = 1.6 }, .{});
        ui.text(name, .{ .font_size = 15, .color = k.ink, .max_lines = 1 });
        if (label.len > 0 and !eq(u8, label, name)) ui.text(label, .{ .font_size = 13.6, .color = k.ink_2, .max_lines = 1 });
        ui.end();
        ui.end();
    }
    ui.end();
}

// ---- Tests --------------------------------------------------------------------------------

const app = @import("../app.zig");
const testing = std.testing;
const dispatch = @import("dispatch.zig");

test "hubs: add a hub placed by searching" {
    try dispatch.openCarrier("/hubs");
    defer app.D.reset();
    try testing.expect(app.D.respond("/carrier/hubs", 200, "[]"));
    try testing.expect(app.D.findText(L("hubs.none")) != 0);
    app.D.R.dispatch(kit.act(A.add, 0));
    try testing.expect(app.D.findText(L("hubs.click_map")) != 0);
    try app.D.typeInto("DAM1", "DAM2");
    try app.D.typeInto(L("address.search_placeholder"), "Mazzeh");
    try app.D.inputEvent(L("address.search_placeholder"), .submit);
    try testing.expect(app.D.respond("/api/v1/search?q=Mazzeh", 200, "{\"success\":true,\"results\":[{\"name\":\"Mazzeh\",\"label\":\"Mazzeh, Damascus\",\"lat\":33.5012345678,\"lng\":36.25}]}"));
    try testing.expect(app.D.findText("33.501235, 36.25") != 0);
    app.D.R.dispatch(kit.act(A.save, 0));
    const req = zui.host.fetches.items[zui.host.fetches.items.len - 1];
    try testing.expect(std.mem.endsWith(u8, req.url, "/carrier/hubs"));
    try testing.expect(std.mem.indexOf(u8, req.body, "\"code\":\"DAM2\"") != null);
    try testing.expect(std.mem.indexOf(u8, req.body, "\"location\":{\"lat\":33.501235,\"lng\":36.25}") != null);
    try testing.expect(std.mem.indexOf(u8, req.body, "\"governorate\":\"DAM\"") != null);
    try testing.expect(app.D.respond("/carrier/hubs", 400, "{\"error\":{\"code\":\"invalid_request\",\"message\":\"Name is required\",\"field\":\"name\"}}"));
    try testing.expect(app.D.findText("Name is required") != 0);
    app.D.R.dispatch(kit.act(A.save, 0));
    try testing.expect(app.D.respond("/carrier/hubs", 201, "{}"));
    try testing.expect(app.D.findText("Saved") != 0);
}
