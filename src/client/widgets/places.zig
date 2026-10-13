//! A store's pickup places (Turf-js views/merchant/places.js `placesCard`): the warehouses,
//! branches and shops couriers collect from. One is the default; the new-shipment page offers
//! them as chips. A panel for the merchant settings page: keep a `Places` in the page state,
//! call `setup` in `enter`, pass every event to `update`, draw `view` in the page and `overlay`
//! in the page's overlay (the add/edit dialog, with the map-first address).

const std = @import("std");
const zui = @import("zui");
const core = @import("../core.zig");
const kit = @import("../kit.zig");
const shell = @import("../shell.zig");
const json = @import("../json.zig");
const icons = @import("../icons.zig");
const labels = @import("../labels.zig");
const address = @import("address.zig");
const parts = @import("parts.zig");

const Cx = core.Cx;
const Ui = core.Ui;
const V = json.V;
const L = labels.k;

pub const Config = struct {
    /// The data slot the list loads into.
    data: u8 = 8,
    /// Action ids from here (8 of them; the address takes the next `address.acts_used`).
    act: u16 = 440,
    /// The place name field; the address takes the next `address.slots_used` slots.
    slot: u16 = 440,
    timer: u16 = 440,
    /// The address map's pointer tag (1..15, unique on the page).
    tag: u4 = 3,
};

const a_add: u16 = 0;
const a_edit: u16 = 1;
const a_close: u16 = 2;
const a_save: u16 = 3;
const a_default: u16 = 4;
const a_delete_ask: u16 = 5;
const a_delete: u16 = 6;
const acts_used: u16 = 8;

pub const Places = struct {
    cfg: Config = .{},
    editing: bool = false,
    /// The place being edited; null: a new one.
    existing: ?[]const u8 = null,
    addr: address.Address = .{},

    pub fn setup(p: *Places, c: *Cx, cfg: Config) void {
        p.* = .{ .cfg = cfg };
        p.load(c);
    }

    fn load(p: *const Places, c: *Cx) void {
        c.load(p.cfg.data, c.orgUrl("/merchant/places"));
    }

    fn list(p: *const Places, c: *const Cx) []const V {
        return json.arr(c.data(p.cfg.data), "");
    }

    fn id(p: *const Places, x: u16) u16 {
        return p.cfg.act + x;
    }

    fn openEditor(p: *Places, c: *Cx, existing: ?V) void {
        p.addr.setup(c, .{ .prefix = "place", .slot = p.cfg.slot + 1, .act = p.cfg.act + acts_used, .timer = p.cfg.timer, .tag = p.cfg.tag, .require_phone = false, .kind = "shop" });
        if (existing) |e| {
            p.addr.setValue(c, e);
            p.existing = c.dupe(json.str(e, "id"));
            c.setVal(p.cfg.slot, json.str(e, "label"));
        } else {
            p.existing = null;
            c.setVal(p.cfg.slot, "");
        }
        c.clearFieldError();
        p.editing = true;
    }

    /// Handles the panel's events (the list, the dialog and its address).
    pub fn update(p: *Places, c: *Cx, e: core.Ev) void {
        if (p.editing and p.addr.update(c, e)) return;
        const items = p.list(c);
        switch (e) {
            .act => |x| {
                if (x.id < p.cfg.act or x.id >= p.cfg.act + acts_used) return;
                switch (x.id - p.cfg.act) {
                    a_add => p.openEditor(c, null),
                    a_edit => if (x.arg < items.len) p.openEditor(c, items[x.arg]),
                    a_close => p.editing = false,
                    a_save => {
                        var b = json.Obj.init(c.arena());
                        b.strOpt("label", c.val(p.cfg.slot));
                        p.addr.write(c, &b);
                        if (p.existing) |pid|
                            c.send(p.id(a_save), .PATCH, c.orgUrl(c.print("/merchant/places/{s}", .{pid})), b.done())
                        else
                            c.send(p.id(a_save), .POST, c.orgUrl("/merchant/places"), b.done());
                    },
                    a_default => if (x.arg < items.len) c.send(p.id(a_default), .POST, c.orgUrl(c.print("/merchant/places/{s}/default", .{json.str(items[x.arg], "id")})), ""),
                    a_delete_ask => if (x.arg < items.len) {
                        c.ask(zui.i18n.tf(c.arena(), labels.english("places.delete_confirm") orelse "{label}", .{ .label = json.str(items[x.arg], "label") }), .{ .danger = true, .act = .{ .id = p.id(a_delete), .arg = x.arg } });
                    },
                    a_delete => if (x.arg < items.len) c.sendArg(p.id(a_delete), x.arg, .DELETE, c.orgUrl(c.print("/merchant/places/{s}", .{json.str(items[x.arg], "id")})), ""),
                    else => {},
                }
            },
            .done => |d| {
                if (d.id < p.cfg.act or d.id >= p.cfg.act + acts_used or !d.ok) return;
                switch (d.id - p.cfg.act) {
                    a_save => {
                        c.toast(L("places.saved"), .ok);
                        p.editing = false;
                    },
                    a_delete => c.toast(L("places.removed"), .ok),
                    else => {},
                }
                p.load(c);
                @import("../app.zig").reloadOrg(c);
            },
            else => {},
        }
    }

    /// The card that lists the places.
    pub fn view(p: *const Places, c: *const Cx, ui: *Ui) void {
        const k = kit.k;
        kit.card(ui, .{ .gap = 16 });
        const w = kit.width;
        kit.width = w - 40;
        defer kit.width = w;
        kit.cardHead(ui, L("places.title"));
        kit.button(ui, L("places.add"), .{ .act = .{ .id = p.id(a_add) } }, .{ .size = .sm, .variant = .primary, .icon = icons.add });
        ui.end();
        kit.small(ui, L("places.intro"));
        if (kit.gate(ui, &.{p.cfg.data})) {
            const items = p.list(c);
            ui.begin(.{ .gap = 8.8 }, .{});
            if (items.len == 0) kit.empty(ui, L("places.none"));
            for (items, 0..) |x, i| {
                const def = json.boolean(x, "isDefault");
                const arg: u32 = @intCast(i);
                kit.card(ui, .{ .pad = 12, .inner = true, .direction = .row, .align_items = .center, .gap = 12, .key = zui.key(json.str(x, "id")) });
                kit.avatar(ui, if (json.has(x, "location")) icons.store else icons.location_on);
                ui.begin(.{ .grow = 1, .gap = 2 }, .{});
                ui.begin(.{ .direction = .row, .gap = 6.4, .align_items = .center }, .{});
                kit.strong(ui, json.str(x, "label"));
                if (def) kit.badge(ui, L("places.default"), .brand);
                ui.end();
                const phone = json.str(x, "phone");
                const line = placeLine(ui.arena(), c, x);
                kit.small(ui, if (phone.len > 0) kit.f(ui, "{s} · {s}", .{ line, phone }) else line);
                ui.end();
                ui.begin(.{ .direction = .row, .gap = 3.2 }, .{});
                if (!def) kit.iconButton(ui, icons.star, .{ .act = .{ .id = p.id(a_default), .arg = arg } }, .{ .size = .sm, .variant = .ghost, .busy = p.id(a_default) });
                kit.iconButton(ui, icons.edit, .{ .act = .{ .id = p.id(a_edit), .arg = arg } }, .{ .size = .sm, .variant = .ghost });
                kit.iconButton(ui, icons.delete, .{ .act = .{ .id = p.id(a_delete_ask), .arg = arg } }, .{ .size = .sm, .variant = .ghost, .busy = p.id(a_delete) });
                ui.end();
                kit.endCard(ui, .{});
            }
            ui.end();
        }
        _ = k;
        kit.endCard(ui, .{});
    }

    /// The add / edit dialog.
    pub fn overlay(p: *const Places, c: *const Cx, ui: *Ui) void {
        if (!p.editing) return;
        const close: core.Msg = .{ .act = .{ .id = p.id(a_close) } };
        const save: core.Msg = .{ .act = .{ .id = p.id(a_save) } };
        shell.modalBegin(ui, .{ .title = L(if (p.existing != null) "places.edit" else "places.add"), .close = close, .wide = true, .key = zui.key("place-editor") });
        kit.field(ui, L("places.label"), p.cfg.slot, .{ .hint = L("places.label_hint"), .input = .{ .placeholder = L("places.label_placeholder"), .name = "place.label", .on_submit = save } });
        p.addr.view(c, ui, "");
        shell.modalFoot(ui);
        shell.modalButton(ui, L("common.cancel"), close, .{});
        shell.modalButton(ui, L("common.save"), save, .{ .variant = .primary, .busy = p.id(a_save) });
        shell.modalEnd(ui, true);
    }
};

/// "street، area، city، governorate" (`placeLine`).
pub fn placeLine(a: std.mem.Allocator, c: *const Cx, x: ?V) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    const gov = json.str(x, "governorate");
    for ([_][]const u8{ json.str(x, "street"), json.str(x, "area"), json.str(x, "city"), if (gov.len > 0) parts.gov(c, gov) else "" }) |s| {
        if (s.len == 0) continue;
        if (out.items.len > 0) out.appendSlice(a, "، ") catch {};
        out.appendSlice(a, s) catch {};
    }
    return out.items;
}

// ---- Tests ------------------------------------------------------------------------------------

test "places: add, edit, make default, delete" {
    const app = @import("../app.zig");
    const m_new = @import("../pages/m_new.zig");
    const testing = std.testing;
    try app.startSignedIn("/o/acme/claims");
    defer app.D.reset();
    try testing.expect(app.D.respond("/api/app/orgs/o1", 200, m_new.merchant_org));
    const c: *Cx = @constCast(app.D.R.appState());
    var p: Places = .{};
    p.setup(c, .{});
    try testing.expect(app.D.respond("/merchant/places", 200,
        \\[{"id":"p1","label":"Main shop","isDefault":true,"city":"Damascus","governorate":"DAM","location":{"lat":33.5,"lng":36.3}},{"id":"p2","label":"Depot","isDefault":false}]
    ));
    p.update(c, .{ .act = .{ .id = 440 + a_edit, .arg = 0 } });
    try testing.expect(p.editing);
    try testing.expectEqualStrings("Main shop", c.val(440));
    try testing.expectEqualStrings("Damascus", c.val(441 + address.f_city));
    p.update(c, .{ .act = .{ .id = 440 + a_save } });
    const b = m_new.lastFetch("/merchant/places/p1").?;
    try testing.expectEqualStrings("PATCH", b.method);
    try testing.expect(m_new.has(b.body, "\"label\":\"Main shop\""));
    try testing.expect(m_new.has(b.body, "\"location\":{\"lat\":33.5,\"lng\":36.3}"));
    p.update(c, .{ .act = .{ .id = 440 + a_default, .arg = 1 } });
    try testing.expect(app.D.pending("/merchant/places/p2/default") != null);
    try testing.expectEqualStrings("Main shop، Damascus، Damascus", placeLine(c.arena(), c, json.parse(c.arena(), "{\"street\":\"Main shop\",\"city\":\"Damascus\",\"governorate\":\"DAM\"}")));
}
