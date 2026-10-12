//! Driver app (not ported yet).

const std = @import("std");
const zui = @import("zui");
const core = @import("../core.zig");
const kit = @import("../kit.zig");

const Cx = core.Cx;
const Ui = core.Ui;
const t = core.t;

pub const S = struct {};

pub fn title(_: *const S, _: *const Cx) []const u8 {
    return t("Driver app");
}

pub fn enter(_: *S, _: *Cx) void {}

pub fn update(_: *S, _: *Cx, _: core.Ev) void {}

pub fn view(_: *const S, _: *const Cx, ui: *Ui) void {
    kit.notice(ui, .info, "This page is not ported yet.");
}
