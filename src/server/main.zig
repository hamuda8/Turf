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
    std.testing.refAllDecls(@import("permissions.zig"));
    std.testing.refAllDecls(@import("messages.zig"));
    std.testing.refAllDecls(@import("geo.zig"));
    std.testing.refAllDecls(@import("crypto.zig"));
    std.testing.refAllDecls(@import("barcode.zig"));
    std.testing.refAllDecls(@import("ratelimit.zig"));
    std.testing.refAllDecls(@import("realtime.zig"));
    std.testing.refAllDecls(@import("services/bulk.zig"));
    std.testing.refAllDecls(@import("services/accounts.zig"));
    std.testing.refAllDecls(@import("services/verification.zig"));
    std.testing.refAllDecls(@import("services/reports.zig"));
    std.testing.refAllDecls(@import("services/statements.zig"));
    std.testing.refAllDecls(@import("services/feedback.zig"));
    std.testing.refAllDecls(@import("services/claims.zig"));
    std.testing.refAllDecls(@import("services/testmode.zig"));
    std.testing.refAllDecls(@import("services/direct.zig"));
    std.testing.refAllDecls(@import("services/dispatch.zig"));
    std.testing.refAllDecls(@import("services/tracking.zig"));
    std.testing.refAllDecls(@import("services/operations.zig"));
    std.testing.refAllDecls(@import("services/earnings.zig"));
    std.testing.refAllDecls(@import("services/tasks.zig"));
    std.testing.refAllDecls(@import("bus.zig"));
    std.testing.refAllDecls(@import("services/errors.zig"));
    std.testing.refAllDecls(@import("services/relay.zig"));
    std.testing.refAllDecls(@import("services/allocation.zig"));
    std.testing.refAllDecls(@import("services/shipments.zig"));
    std.testing.refAllDecls(@import("services/apikeys.zig"));
    std.testing.refAllDecls(@import("services/live.zig"));
    std.testing.refAllDecls(@import("services/webhooks.zig"));
    std.testing.refAllDecls(@import("services/push.zig"));
    std.testing.refAllDecls(@import("services/routing.zig"));
    std.testing.refAllDecls(@import("services/carriers.zig"));
    std.testing.refAllDecls(@import("services/pricing.zig"));
    std.testing.refAllDecls(@import("services/places.zig"));
    std.testing.refAllDecls(@import("services/coverage.zig"));
    std.testing.refAllDecls(@import("services/branding.zig"));
    std.testing.refAllDecls(@import("services/members.zig"));
    std.testing.refAllDecls(@import("services/orgs.zig"));
    std.testing.refAllDecls(@import("services/moderation.zig"));
    std.testing.refAllDecls(@import("services/platform.zig"));
    std.testing.refAllDecls(@import("services/audit.zig"));
}
