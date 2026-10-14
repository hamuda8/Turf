//! Signed out on the phones: Turf's welcome with one button that opens Wufour's own sign-in
//! inside the app (`fx.webAuth`, zui.wufour). Wufour sends the page to Turf's /auth/callback
//! with `?token=`; the app takes the token from that address without loading it, keeps it in
//! the device's secure storage and sends it to Turf as `Authorization: Bearer`.
//! (The web signs in through Wufour's pages and the server's cookies, as before.)

const std = @import("std");
const zui = @import("zui");
const core = @import("../core.zig");
const kit = @import("../kit.zig");
const icons = @import("../icons.zig");
const labels = @import("../labels.zig");

const Cx = core.Cx;
const Ui = core.Ui;
const t = core.t;

const A = enum(u16) { sign_in = 1 };

pub const S = struct {};

pub fn title(_: *const S, _: *const Cx) []const u8 {
    return t("Sign in");
}

pub fn enter(_: *S, _: *Cx) void {}

pub fn update(_: *S, c: *Cx, e: core.Ev) void {
    switch (e) {
        .act => |a| if (a.id == @intFromEnum(A.sign_in)) signIn(c),
        else => {},
    }
}

/// Wufour's sign-in page, in the app; the answer comes back as `Msg.web_auth`.
pub fn signIn(c: *Cx) void {
    zui.wufour.signIn(core.Msg, c.fx, .{ .auth_host = core.auth_base, .callback = core.callback_url }, onWebAuth);
}

fn onWebAuth(r: zui.WebAuthResult) core.Msg {
    return .{ .web_auth = r };
}

pub fn view(_: *const S, c: *const Cx, ui: *Ui) void {
    const k = kit.k;
    const w = ui.env.width;
    ui.beginScroll(.{ .width = .fill, .height = .fill, .align_items = .center, .justify = .center, .padding = .{ .top = 48, .bottom = 32, .start = 16, .end = 16 } }, zui.key("signin"));
    ui.begin(.{ .width = .{ .px = @min(w - 32, 420) }, .gap = 24, .align_items = .center }, .{});
    kit.width = @min(w - 32, 420);
    kit.iconTile(ui, icons.local_shipping, 72);
    ui.begin(.{ .gap = 8, .align_items = .center }, .{});
    ui.text("Turf", .{ .font_size = 32, .weight = 800, .color = k.ink });
    kit.muted(ui, labels.k("landing.tagline"));
    ui.end();
    ui.begin(.{ .width = .fill, .gap = 12, .padding = .{ .top = 16 } }, .{});
    kit.button(ui, t("Sign in with Wufour"), kit.act(A.sign_in, 0), .{ .variant = .primary, .size = .lg, .block = true });
    ui.begin(.{ .direction = .row, .justify = .center }, .{});
    kit.muted(ui, t("Use your Wufour account."));
    ui.end();
    ui.end();
    ui.begin(.{ .direction = .row, .justify = .center }, .{});
    kit.link(ui, if (c.ar()) "English" else "العربية", .{ .shell = .lang }, .{ .size = 14 });
    ui.end();
    ui.end();
    ui.end();
}
