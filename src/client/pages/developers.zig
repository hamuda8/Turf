//! Developers (Turf-js views/merchant/developers.js): API keys, the webhook with its recent
//! deliveries, and a quick start. The quick start shows the server the app talks to (the
//! build's -Dserver: zui has no `location.origin`).

const std = @import("std");
const zui = @import("zui");
const core = @import("../core.zig");
const kit = @import("../kit.zig");
const shell = @import("../shell.zig");
const json = @import("../json.zig");
const fmt = @import("../fmt.zig");
const icons = @import("../icons.zig");
const labels = @import("../labels.zig");
const cm = @import("../widgets/common.zig");
const config = @import("app_config");

const Cx = core.Cx;
const Ui = core.Ui;
const V = json.V;
const L = labels.k;
const eq = std.mem.eql;

const d_keys: u8 = 0;
const d_hook: u8 = 1;
const d_secret: u8 = 2;

const f_name: u16 = 0;
const f_mode: u16 = 1;
const f_url: u16 = 2;

const A = enum(u16) { create_open = 1, create, close, revoke_ask, revoke, save_hook, reveal, rotate_ask, rotate, test_hook, delete_ask, delete_hook };

const Dialog = enum { none, create, secret };

pub const S = struct {
    dialog: Dialog = .none,
    revealed: bool = false,
};

pub fn title(_: *const S, _: *const Cx) []const u8 {
    return L("nav.developers");
}

pub fn actions(_: *const S, _: *const Cx, ui: *Ui) void {
    kit.button(ui, L("nav.api_docs"), .{ .open = core.api_base ++ "/developers" }, .{ .icon = icons.code });
}

fn loadKeys(c: *Cx) void {
    c.load(d_keys, c.orgUrl("/merchant/api-keys"));
}

fn loadHook(c: *Cx) void {
    c.load(d_hook, c.orgUrl("/merchant/webhook"));
}

pub fn enter(_: *S, c: *Cx) void {
    loadKeys(c);
    loadHook(c);
}

fn origin() []const u8 {
    return if (core.api_base.len > 0) core.api_base else config.server;
}

fn snippet(a: std.mem.Allocator) []const u8 {
    return std.fmt.allocPrint(a,
        \\curl -X POST {s}/api/v1/shipments \
        \\  -H "Authorization: Bearer turf_sk_..." \
        \\  -H "Content-Type: application/json" \
        \\  -d '{{
        \\    "reference": "ORDER-1001",
        \\    "carrier": "auto",
        \\    "strategy": "balanced",
        \\    "dropoff": {{
        \\      "name": "Lina Haddad", "phone": "0944111222",
        \\      "governorate": "DI", "city": "Damascus", "area": "Malki"
        \\    }},
        \\    "parcel": {{ "weightKg": 1.5, "description": "Books" }},
        \\    "cod": {{ "amount": 150000 }}
        \\  }}'
    , .{origin()}) catch "";
}

pub fn update(s: *S, c: *Cx, e: core.Ev) void {
    switch (e) {
        .data => |n| if (n == d_hook and c.slot(d_hook).state == .ok) {
            c.setVal(f_url, json.str(c.data(d_hook), "webhook.url"));
            s.revealed = false;
        },
        .act => |a| switch (@as(A, @enumFromInt(a.id))) {
            .create_open => {
                s.dialog = .create;
                c.setVal(f_name, "");
                c.setVal(f_mode, "live");
                c.clearFieldError();
                c.fx.focus(kit.slotKey(f_name));
            },
            .close => s.dialog = .none,
            .create => {
                var b = json.Obj.init(c.arena());
                b.str("name", c.valTrim(f_name));
                b.str("mode", c.val(f_mode));
                c.send(a.id, .POST, c.orgUrl("/merchant/api-keys"), b.done());
            },
            .revoke_ask => {
                const l = json.arr(c.data(d_keys), "");
                if (a.arg < l.len) c.ask(cm.txc(c, "dev.revoke_confirm", .{ .name = json.str(l[a.arg], "name") }), .{ .danger = true, .act = .{ .id = @intFromEnum(A.revoke), .arg = a.arg } });
            },
            .revoke => {
                const l = json.arr(c.data(d_keys), "");
                if (a.arg < l.len) c.sendArg(a.id, a.arg, .DELETE, c.orgUrl(c.print("/merchant/api-keys/{s}", .{cm.docId(l[a.arg])})), "");
            },
            .save_hook => {
                var b = json.Obj.init(c.arena());
                b.str("url", c.valTrim(f_url));
                c.send(a.id, .PUT, c.orgUrl("/merchant/webhook"), b.done());
            },
            .reveal => s.revealed = true,
            .rotate_ask => c.ask(L("dev.rotate_confirm"), .{ .danger = true, .act = .{ .id = @intFromEnum(A.rotate) } }),
            .rotate => c.send(a.id, .POST, c.orgUrl("/merchant/webhook/rotate"), ""),
            .test_hook => c.send(a.id, .POST, c.orgUrl("/merchant/webhook/test"), ""),
            .delete_ask => c.ask(L("dev.delete_webhook_confirm"), .{ .danger = true, .act = .{ .id = @intFromEnum(A.delete_hook) } }),
            .delete_hook => c.send(a.id, .DELETE, c.orgUrl("/merchant/webhook"), ""),
        },
        .done => |d| {
            if (!d.ok) return;
            switch (@as(A, @enumFromInt(d.id))) {
                .create => {
                    // The secret is shown once.
                    cm.keep(c, d_secret, d.body);
                    s.dialog = .secret;
                    loadKeys(c);
                },
                .revoke => {
                    c.toast(L("common.saved"), .ok);
                    loadKeys(c);
                },
                .save_hook, .rotate, .delete_hook => {
                    c.toast(L("common.saved"), .ok);
                    loadHook(c);
                },
                .test_hook => {
                    const ok = json.boolean(d.v, "ok");
                    const status = json.text(c.arena(), d.v, "status");
                    if (ok) {
                        c.toast(cm.txc(c, "dev.test_ok", .{ .status = status }), .ok);
                    } else {
                        const why = if (status.len > 0) status else json.strOr(d.v, "error", "—");
                        c.toast(cm.txc(c, "dev.test_failed", .{ .status = why }), .err);
                    }
                },
                else => {},
            }
        },
        else => {},
    }
}

pub fn view(s: *const S, c: *const Cx, ui: *Ui) void {
    if (!kit.gate(ui, &.{ d_keys, d_hook })) return;
    const k = kit.k;
    const a = ui.arena();
    ui.begin(.{ .gap = 16, .max_width = 1000 }, .{});
    kit.rowBetween(ui);
    kit.h2(ui, L("dev.api_keys"));
    kit.button(ui, L("dev.create_key"), kit.act(A.create_open, 0), .{ .variant = .primary, .icon = icons.add });
    ui.end();
    kit.muted(ui, L("dev.keys_intro"));
    const keys = json.arr(c.data(d_keys), "");
    if (keys.len == 0) kit.empty(ui, L("dev.no_keys")) else {
        var tb = kit.Table.begin(ui, &.{
            .{ .label = L("common.name"), .grow = 1.4 },
            .{ .label = L("dev.key") },
            .{ .label = L("dev.last_used") },
            .{ .label = L("common.created") },
            .{ .width = 110 },
        });
        for (keys, 0..) |key, i| {
            tb.row(null, zui.key(cm.docId(key)));
            tb.cell(false);
            ui.begin(.{ .direction = .row, .gap = 6.4, .align_items = .center }, .{});
            kit.strong(ui, json.str(key, "name"));
            const testing_key = eq(u8, json.str(key, "mode"), "test");
            kit.badge(ui, if (testing_key) L("dev.mode_test") else L("dev.mode_live"), if (testing_key) .amber else .green);
            ui.end();
            tb.endCell();
            tb.cell(true);
            kit.mono(ui, kit.f(ui, "{s}…", .{json.str(key, "prefix")}), .{});
            tb.endCell();
            tb.cell(true);
            const used = json.str(key, "lastUsedAt");
            kit.text(ui, if (used.len > 0) fmt.relative(a, used) else L("dev.never"), .{});
            tb.endCell();
            tb.cell(true);
            kit.text(ui, fmt.dateTime(a, json.str(key, "createdAt")), .{});
            tb.endCell();
            tb.cell(false);
            const mine = c.isBusy(@intFromEnum(A.revoke)) and (c.act_args.get(@intFromEnum(A.revoke)) orelse 0) == i;
            kit.button(ui, L("dev.revoke"), kit.act(A.revoke_ask, @intCast(i)), .{ .size = .sm, .variant = .ghost, .busy = if (mine) @intFromEnum(A.revoke) else null });
            tb.endCell();
            tb.endRow();
        }
        tb.end();
    }

    kit.h2(ui, L("dev.webhooks"));
    const hook = json.obj(c.data(d_hook), "webhook");
    kit.card(ui, .{ .gap = 16 });
    kit.muted(ui, L("dev.webhook_intro"));
    ui.begin(.{ .direction = .row, .gap = 12, .align_items = .end }, .{});
    ui.begin(.{ .grow = 1 }, .{});
    kit.field(ui, L("dev.webhook_url"), f_url, .{ .required = true, .input = .{ .ltr = true, .placeholder = "https://your-store.com/turf/webhook", .name = "url", .on_submit = kit.act(A.save_hook, 0) } });
    ui.end();
    kit.button(ui, L("common.save"), kit.act(A.save_hook, 0), .{ .variant = .primary, .busy = @intFromEnum(A.save_hook) });
    ui.end();
    if (hook) |h| {
        const secret = json.str(h, "secret");
        kit.stackTight(ui);
        ui.begin(.{ .direction = .row, .gap = 12, .align_items = .center }, .{});
        kit.label(ui, L("dev.signing_secret"));
        ui.begin(.{ .no_mirror = true, .grow = 1 }, .{});
        kit.mono(ui, if (s.revealed) secret else "••••••••••••", .{});
        ui.end();
        kit.button(ui, L("dev.reveal"), kit.act(A.reveal, 0), .{ .size = .sm });
        kit.copyButton(ui, secret, null);
        ui.end();
        ui.begin(.{ .direction = .row, .gap = 12 }, .{});
        kit.button(ui, L("dev.send_test"), kit.act(A.test_hook, 0), .{ .size = .sm, .icon = icons.navigation, .busy = @intFromEnum(A.test_hook) });
        kit.button(ui, L("dev.rotate"), kit.act(A.rotate_ask, 0), .{ .size = .sm, .variant = .ghost, .busy = @intFromEnum(A.rotate) });
        kit.button(ui, L("common.delete"), kit.act(A.delete_ask, 0), .{ .size = .sm, .variant = .ghost, .icon = icons.delete, .busy = @intFromEnum(A.delete_hook) });
        ui.end();
        ui.end();
    }
    kit.endCard(ui, .{});
    if (hook != null) {
        kit.card(ui, .{ .pad = 0 });
        ui.begin(.{ .padding = .xy(17.6, 14.4) }, .{});
        kit.h3(ui, L("dev.recent_deliveries"));
        ui.end();
        const deliveries = json.arr(c.data(d_hook), "deliveries");
        if (deliveries.len == 0) {
            ui.begin(.{ .padding = .{ .start = 17.6, .end = 17.6, .bottom = 16 } }, .{});
            kit.muted(ui, L("dev.no_deliveries"));
            ui.end();
        } else {
            var tb = kit.Table.begin(ui, &.{
                .{ .label = L("dev.event") },
                .{ .label = L("common.status"), .grow = 1.4 },
                .{ .label = L("dev.attempts") },
                .{ .label = L("common.when") },
            });
            for (deliveries, 0..) |d, i| {
                tb.row(null, zui.key(i + 1));
                tb.cell(false);
                kit.mono(ui, json.str(d, "type"), .{});
                tb.endCell();
                tb.cell(true);
                const st = json.str(d, "status");
                ui.begin(.{ .direction = .row, .gap = 6.4, .align_items = .center }, .{});
                kit.badge(ui, labels.of("dev.delivery.", st), if (eq(u8, st, "delivered")) .green else if (eq(u8, st, "failed")) .red else .amber);
                if (json.num(d, "lastStatus")) |code| kit.small(ui, kit.f(ui, "HTTP {d}", .{@as(i64, @intFromFloat(code))}));
                ui.end();
                if (json.str(d, "lastError").len > 0) kit.small(ui, json.str(d, "lastError"));
                tb.endCell();
                tb.cell(true);
                kit.text(ui, json.text(a, d, "attempts"), .{});
                tb.endCell();
                tb.cell(true);
                kit.text(ui, fmt.relative(a, json.str(d, "createdAt")), .{});
                tb.endCell();
                tb.endRow();
            }
            tb.end();
        }
        kit.endCard(ui, .{ .pad = 0 });
    }

    kit.h2(ui, L("dev.quick_start"));
    kit.card(ui, .{ .gap = 8.8 });
    kit.muted(ui, L("dev.quick_start_intro"));
    const snip = snippet(a);
    ui.beginScroll(.{ .direction = .row, .background = k.panel_2, .padding = .all(16), .radius = 8, .no_mirror = true }, zui.key("snippet"));
    ui.text(snip, .{ .font_size = 13.6, .mono = true, .color = k.ink });
    ui.end();
    ui.begin(.{ .direction = .row }, .{});
    kit.copyButton(ui, snip, null);
    ui.end();
    kit.endCard(ui, .{});
    ui.end();
}

pub fn overlay(s: *const S, c: *const Cx, ui: *Ui) void {
    const close = kit.act(A.close, 0);
    switch (s.dialog) {
        .none => {},
        .create => {
            shell.modalBegin(ui, .{ .title = L("dev.create_key"), .close = close, .key = zui.key("create-key") });
            kit.field(ui, L("common.name"), f_name, .{ .required = true, .input = .{ .placeholder = L("dev.key_name_placeholder"), .name = "name", .on_submit = kit.act(A.create, 0) } });
            const opts = [_]core.Opt{
                .{ .value = "live", .label = L("dev.mode_live_option") },
                .{ .value = "test", .label = L("dev.mode_test_option") },
            };
            kit.selectField(ui, L("dev.mode"), f_mode, &opts, .{ .name = "mode", .hint = L("dev.mode_hint") });
            shell.modalFoot(ui);
            shell.modalButton(ui, L("common.cancel"), close, .{});
            shell.modalButton(ui, L("common.create"), kit.act(A.create, 0), .{ .variant = .primary, .busy = @intFromEnum(A.create) });
            shell.modalEnd(ui, true);
        },
        .secret => {
            const secret = json.str(c.data(d_secret), "secret");
            shell.modalBegin(ui, .{ .title = L("dev.key_created"), .close = close, .key = zui.key("key-created") });
            kit.notice(ui, .warn, L("dev.key_once"));
            ui.begin(.{ .padding = .xy(16, 12), .radius = 16, .background = kit.k.panel_3, .no_mirror = true }, .{});
            kit.mono(ui, secret, .{});
            ui.end();
            ui.begin(.{ .direction = .row }, .{});
            kit.copyButton(ui, secret, null);
            ui.end();
            shell.modalFoot(ui);
            shell.modalButton(ui, L("common.done"), close, .{ .variant = .primary });
            shell.modalEnd(ui, true);
        },
    }
}

// ---- Tests --------------------------------------------------------------------------------

const app = @import("../app.zig");
const testing = std.testing;
const msettings = @import("m_settings.zig");

test "developers: create a key, see its secret once, test the webhook" {
    try msettings.openMerchant("/developers");
    defer app.D.reset();
    try testing.expect(app.D.respond("/merchant/api-keys", 200, "[]"));
    try testing.expect(app.D.respond("/merchant/webhook", 200, "{\"webhook\":{\"url\":\"https://shop.example/hook\",\"secret\":\"whsec_1\"},\"deliveries\":[{\"type\":\"shipment.delivered\",\"status\":\"failed\",\"lastStatus\":500,\"attempts\":3,\"createdAt\":\"2025-10-12T11:00:00.000Z\"}]}"));
    try testing.expect(app.D.findText(L("dev.no_keys")) != 0);
    try testing.expect(app.D.findText("HTTP 500") != 0);
    try testing.expect(app.D.findText("whsec_1") == 0);
    try app.D.press(L("dev.reveal"));
    try testing.expect(app.D.findText("whsec_1") != 0);
    try app.D.press(L("dev.create_key"));
    try app.D.typeInto(L("dev.key_name_placeholder"), "Shop");
    try app.D.inputEvent(L("dev.key_name_placeholder"), .submit);
    const req = zui.host.fetches.items[zui.host.fetches.items.len - 1];
    try testing.expectEqualStrings("{\"name\":\"Shop\",\"mode\":\"live\"}", req.body);
    try testing.expect(app.D.respond("/merchant/api-keys", 201, "{\"secret\":\"turf_sk_abc\"}"));
    try testing.expect(app.D.findText("turf_sk_abc") != 0);
    try app.D.press(L("dev.send_test"));
    try testing.expect(app.D.respond("/merchant/webhook/test", 200, "{\"ok\":false,\"status\":502}"));
    try testing.expect(app.D.findText(L("dev.key_created")) != 0);
}
