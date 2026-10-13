//! Merchant settings (Turf-js views/merchant/settings.js): company profile, pickup places,
//! preferences (website, default strategy), email updates about shipments, and closing the
//! company. The pickup places panel (Turf-js merchant/places.js) is widgets/places.zig, written
//! separately; its place is marked below.

const std = @import("std");
const zui = @import("zui");
const core = @import("../core.zig");
const kit = @import("../kit.zig");
const json = @import("../json.zig");
const labels = @import("../labels.zig");
const cm = @import("../widgets/common.zig");
const CloseCompany = @import("../widgets/close_company.zig").CloseCompany;
const places = @import("../widgets/places.zig");

const Cx = core.Cx;
const Ui = core.Ui;
const V = json.V;
const L = labels.k;

const d_close: u8 = 0;

const f_name: u16 = 0;
const f_phone: u16 = 1;
const f_gov: u16 = 2;
const f_website: u16 = 3;
const f_strategy: u16 = 4;
const f_to: u16 = 5;
const f_close: u16 = 6;

const events = [_][]const u8{ "delivery_failed", "return_started", "returned", "lost", "damage_reported", "recipient_problem", "delivered" };

const A = enum(u16) { save_profile = 1, save_prefs, save_emails, toggle_enabled, toggle_daily, toggle_event, close_base = 100 };

pub const S = struct {
    touched: bool = false,
    reloaded: bool = false,
    enabled: bool = false,
    daily: bool = false,
    events: cm.IdSet = .{},
    close: CloseCompany = .{ .base = @intFromEnum(A.close_base), .slot = d_close, .field = f_close },
};

pub fn title(_: *const S, _: *const Cx) []const u8 {
    return L("nav.settings");
}

fn prefill(s: *S, c: *Cx) void {
    const org = c.orgV();
    const m = json.get(org, "merchant");
    c.setVal(f_name, json.str(org, "name"));
    c.setVal(f_phone, json.str(org, "contact.phone"));
    c.setVal(f_gov, json.str(org, "contact.governorate"));
    c.setVal(f_website, json.str(m, "website"));
    // A <select> without a placeholder starts on its first option.
    const strategies = json.arr(c.meta.value, "strategies");
    c.setVal(f_strategy, json.strOr(m, "defaultStrategy", if (strategies.len > 0) json.str(strategies[0], "") else ""));
    const e = json.get(m, "emailNotifications");
    c.setVal(f_to, json.str(e, "to"));
    s.enabled = json.boolean(e, "enabled");
    s.daily = json.boolean(e, "dailySummary");
    s.events.clear();
    for (json.arr(e, "events")) |x| if (x == .string) s.events.add(c, x.string);
}

pub fn enter(s: *S, c: *Cx) void {
    prefill(s, c);
    @import("../app.zig").reloadOrg(c);
}

pub fn update(s: *S, c: *Cx, e: core.Ev) void {
    if (s.close.update(c, e)) return;
    switch (e) {
        .data => |n| if (n == 255 and !s.reloaded) {
            s.reloaded = true;
            if (!s.touched) prefill(s, c);
        },
        .text => s.touched = true,
        .act => |a| {
            s.touched = true;
            switch (@as(A, @enumFromInt(a.id))) {
                .save_profile => {
                    var b = json.Obj.init(c.arena());
                    b.strOpt("name", c.val(f_name));
                    b.strOpt("phone", c.val(f_phone));
                    b.strOpt("governorate", c.val(f_gov));
                    c.send(a.id, .PATCH, c.orgUrl("/profile"), b.done());
                },
                .save_prefs => {
                    var b = json.Obj.init(c.arena());
                    if (c.valTrim(f_website).len > 0) b.str("website", c.valTrim(f_website)) else b.nul("website");
                    b.strOpt("defaultStrategy", c.val(f_strategy));
                    c.send(a.id, .PATCH, c.orgUrl("/merchant/settings"), b.done());
                },
                .save_emails => {
                    var b = json.Obj.init(c.arena());
                    b.begin("emailNotifications");
                    b.boolean("enabled", s.enabled);
                    if (c.valTrim(f_to).len > 0) b.str("to", c.valTrim(f_to)) else b.nul("to");
                    b.beginArray("events");
                    for (events) |x| if (s.events.has(x)) b.str("", x);
                    b.endArray();
                    b.boolean("dailySummary", s.daily);
                    b.end();
                    c.send(a.id, .PATCH, c.orgUrl("/merchant/settings"), b.done());
                },
                .toggle_enabled => s.enabled = !s.enabled,
                .toggle_daily => s.daily = !s.daily,
                .toggle_event => if (a.arg < events.len) s.events.toggle(c, events[a.arg]),
                .close_base => {},
            }
        },
        .done => |d| switch (@as(A, @enumFromInt(d.id))) {
            .save_profile, .save_prefs, .save_emails => if (d.ok) {
                c.toast(L("common.saved"), .ok);
                @import("../app.zig").reloadOrg(c);
            },
            else => {},
        },
        else => {},
    }
}

fn sectionBegin(ui: *Ui, t: []const u8) void {
    kit.card(ui, .{ .gap = 16 });
    kit.h2(ui, t);
}

fn sectionEnd(ui: *Ui, id: A) void {
    kit.rowEnd(ui);
    kit.button(ui, L("common.save"), kit.act(id, 0), .{ .variant = .primary, .busy = @intFromEnum(id) });
    ui.end();
    kit.endCard(ui, .{});
}

pub fn view(s: *const S, c: *const Cx, ui: *Ui) void {
    const a = ui.arena();
    const m = json.get(c.orgV(), "merchant");
    ui.begin(.{ .gap = 16, .max_width = 920 }, .{});

    sectionBegin(ui, L("settings.profile"));
    var g = kit.formGrid(ui, 3);
    g.cell();
    kit.field(ui, L("org.name"), f_name, .{ .input = .{ .name = "name" } });
    g.endCell();
    g.cell();
    kit.field(ui, L("common.phone"), f_phone, .{ .input = .{ .kind = .phone, .ltr = true, .name = "phone" } });
    g.endCell();
    g.cell();
    kit.selectField(ui, L("org.governorate"), f_gov, cm.govOptions(c, a), .{ .placeholder = L("common.choose"), .name = "governorate" });
    g.endCell();
    g.end();
    sectionEnd(ui, .save_profile);

    // PLACES: widgets/places.zig (Turf-js merchant/places.js, the pickup places card) goes here.

    sectionBegin(ui, L("msettings.preferences"));
    var opts: std.ArrayList(core.Opt) = .empty;
    for (json.arr(c.meta.value, "strategies")) |x| if (x == .string) opts.append(a, .{ .value = x.string, .label = labels.of("strategy.", x.string) }) catch {};
    var g2 = kit.formGrid(ui, 2);
    g2.cell();
    kit.field(ui, L("msettings.website"), f_website, .{ .input = .{ .ltr = true, .name = "website" } });
    g2.endCell();
    g2.cell();
    kit.selectField(ui, L("msettings.default_strategy"), f_strategy, opts.items, .{ .required = true, .name = "defaultStrategy", .hint = L("new.strategy_hint") });
    g2.endCell();
    g2.end();
    sectionEnd(ui, .save_prefs);

    // Email updates about shipments (sent together every few minutes), and a daily summary.
    const e = json.get(m, "emailNotifications");
    if (json.get(e, "ownerEmail") != null) {
        const owner = json.str(e, "ownerEmail");
        sectionBegin(ui, L("msettings.emails"));
        kit.muted(ui, L("msettings.emails_intro"));
        kit.check(ui, L("msettings.emails_enabled"), s.enabled, kit.act(A.toggle_enabled, 0));
        kit.field(ui, L("msettings.emails_to"), f_to, .{ .hint = cm.tx(ui, "msettings.emails_to_hint", .{ .email = if (owner.len > 0) owner else "—" }), .input = .{ .kind = .email, .ltr = true, .placeholder = owner, .name = "emailNotifications.to" } });
        kit.stackTight(ui);
        kit.strong(ui, L("msettings.emails_events"));
        var g3 = kit.Grid.begin(ui, events.len, 280, 6.4, kit.width - 40);
        inline for (events, 0..) |x, i| {
            g3.cell();
            kit.check(ui, L("msettings.email_" ++ x), s.events.has(x), kit.act(A.toggle_event, i));
            g3.endCell();
        }
        g3.end();
        ui.end();
        kit.check(ui, L("msettings.emails_daily"), s.daily, kit.act(A.toggle_daily, 0));
        sectionEnd(ui, .save_emails);
    }
    s.close.card(c, ui);
    ui.end();
}

pub fn overlay(s: *const S, c: *const Cx, ui: *Ui) void {
    s.close.dialog(c, ui);
}

// ---- Tests --------------------------------------------------------------------------------

const app = @import("../app.zig");
const testing = std.testing;

pub const merchant_org =
    \\{"id":"o1","type":"merchant","name":"Acme Store","slug":"acme","status":"active","branding":{"appName":"Acme Store","primaryColor":"#1d4ed8","shortName":"Acme"},
    \\ "contact":{"phone":"0944","governorate":"DAM"},
    \\ "merchant":{"website":"https://acme.example","defaultStrategy":"balanced","emailNotifications":{"ownerEmail":"sara@example.com","enabled":true,"events":["lost"]}},
    \\ "me":{"isOwner":true,"permissions":["org.settings","audit.view","members.view","members.invite","members.manage","roles.manage","shipments.view","shipments.create","shipments.cancel","api.manage","finance.view"]}}
;

/// Opens a merchant page as its owner.
pub fn openMerchant(path: []const u8) !void {
    var buf: [128]u8 = undefined;
    try app.startSignedIn(try std.fmt.bufPrint(&buf, "/o/acme{s}", .{path}));
    try testing.expect(app.D.respond("/api/app/orgs/o1", 200, merchant_org));
}

test "merchant settings: preferences and email updates" {
    try openMerchant("/settings");
    defer app.D.reset();
    try testing.expect(app.D.respond("/api/app/orgs/o1", 200, merchant_org));
    try testing.expect(app.D.findText(L("msettings.emails")) != 0);
    app.D.R.dispatch(kit.act(A.toggle_event, 6));
    app.D.R.dispatch(kit.act(A.toggle_daily, 0));
    app.D.R.dispatch(kit.act(A.save_emails, 0));
    const req = zui.host.fetches.items[zui.host.fetches.items.len - 1];
    try testing.expect(std.mem.endsWith(u8, req.url, "/merchant/settings"));
    try testing.expectEqualStrings("{\"emailNotifications\":{\"enabled\":true,\"to\":null,\"events\":[\"lost\",\"delivered\"],\"dailySummary\":true}}", req.body);
    try testing.expect(app.D.respond("/merchant/settings", 200, "{}"));
    try testing.expect(app.D.findText("Saved") != 0);
    app.D.R.dispatch(.{ .text = .{ .slot = f_website, .text = "" } });
    app.D.R.dispatch(kit.act(A.save_prefs, 0));
    const p = zui.host.fetches.items[zui.host.fetches.items.len - 1];
    try testing.expectEqualStrings("{\"website\":null,\"defaultStrategy\":\"balanced\"}", p.body);
}
