//! Sign-in on the phones: email and password sent to Wufour (`POST /api/auth/login` ->
//! `{ success, token }`); the token is kept in the device's secure storage and sent to Turf as
//! `Authorization: Bearer`. (The web signs in through Wufour's own pages and cookies.)

const std = @import("std");
const zui = @import("zui");
const core = @import("../core.zig");
const kit = @import("../kit.zig");
const json = @import("../json.zig");
const icons = @import("../icons.zig");

const Cx = core.Cx;
const Ui = core.Ui;
const t = core.t;

const f_email: u16 = 0;
const f_password: u16 = 1;

const A = enum(u16) { submit = 1, login = 2 };

pub const S = struct {
    err: []const u8 = "",
};

pub fn title(_: *const S, _: *const Cx) []const u8 {
    return t("Sign in");
}

pub fn enter(_: *S, _: *Cx) void {}

pub fn update(s: *S, c: *Cx, e: core.Ev) void {
    switch (e) {
        .act => |a| if (a.id == @intFromEnum(A.submit)) {
            s.err = "";
            if (c.valTrim(f_email).len == 0 or c.val(f_password).len == 0) {
                s.err = t("Enter your email and password.");
                return;
            }
            var b = json.Obj.init(c.arena());
            b.str("email", c.valTrim(f_email));
            b.str("password", c.val(f_password));
            c.quietErrors(@intFromEnum(A.login));
            c.send(@intFromEnum(A.login), .POST, c.print("{s}/api/auth/login", .{core.auth_base}), b.done());
        },
        .done => |d| if (d.id == @intFromEnum(A.login)) {
            const token = json.str(d.v, "token");
            if (d.ok and json.boolean(d.v, "success") and token.len > 0) {
                return @import("../app.zig").signedIn(c, token);
            }
            s.err = if (d.status == 0)
                t("No connection. Check your internet and try again.")
            else if (d.status == 401 or d.status == 400 or d.status == 403)
                t("The email or password is not right.")
            else
                c.dupe(json.strOr(d.v, "message", core.errorMessage(c.arena(), d.status, d.v, false)));
        },
        else => {},
    }
}

pub fn view(s: *const S, c: *const Cx, ui: *Ui) void {
    const k = kit.k;
    const w = ui.env.width;
    ui.beginScroll(.{ .width = .fill, .height = .fill, .align_items = .center, .padding = .{ .top = 48, .bottom = 32, .start = 16, .end = 16 } }, zui.key("signin"));
    ui.begin(.{ .width = .{ .px = @min(w - 32, 420) }, .gap = 20 }, .{});
    kit.width = @min(w - 32, 420);
    ui.begin(.{ .direction = .row, .align_items = .center, .gap = 10 }, .{});
    kit.iconTile(ui, icons.local_shipping, 44);
    ui.text("Turf", .{ .font_size = 22, .weight = 800, .color = k.ink });
    ui.end();
    ui.begin(.{ .gap = 6 }, .{});
    kit.h1(ui, t("Sign in"));
    kit.muted(ui, t("Use your Wufour account."));
    ui.end();
    kit.card(ui, .{ .gap = 16, .pad = 24 });
    kit.field(ui, t("Email"), f_email, .{ .input = .{ .kind = .email, .placeholder = "you@example.com", .ltr = true } });
    kit.field(ui, t("Password"), f_password, .{ .input = .{ .kind = .password, .placeholder = t("Password"), .ltr = true, .on_submit = kit.act(A.submit, 0) } });
    if (s.err.len > 0) kit.notice(ui, .err, s.err);
    kit.button(ui, t("Sign in"), kit.act(A.submit, 0), .{ .variant = .primary, .size = .lg, .block = true, .busy = @intFromEnum(A.login) });
    kit.endCard(ui, .{});
    ui.begin(.{ .direction = .row, .justify = .center }, .{});
    kit.link(ui, if (c.ar()) "English" else "العربية", .{ .shell = .lang }, .{ .size = 14 });
    ui.end();
    ui.end();
    ui.end();
}
