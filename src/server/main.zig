//! Turf server (port of Turf-js in progress).

const std = @import("std");
const http = @import("http");

fn healthz(ctx: *http.Context) !void {
    return ctx.sendJson(.ok, .{ .ok = true });
}

pub fn main(init: std.process.Init) !void {
    var router: http.Router = .init(init.gpa);
    defer router.deinit();
    try router.get("/healthz", healthz);
    try http.serve(init.io, init.gpa, .{ .address = try .parse("127.0.0.1", 0), .router = &router });
}

test {
    std.testing.refAllDecls(@import("lib/val.zig"));
    std.testing.refAllDecls(@import("lib/db.zig"));
    std.testing.refAllDecls(@import("web.zig"));
    std.testing.refAllDecls(@import("auth.zig"));
    std.testing.refAllDecls(@import("app.zig"));
}
