//! The mount order of src/server.js: /healthz, /api/internal, /api/app, /api/v1, /api/public,
//! the /api catch-all, static files from the public folder, the HTML pages, then the 404 page.

const std = @import("std");
const Io = std.Io;
const http = @import("http");
const val = @import("../lib/val.zig");
const db = @import("../lib/db.zig");
const web = @import("../web.zig");
const a_ = @import("../app.zig");
const app_api = @import("app.zig");
const v1 = @import("v1.zig");
const public = @import("public.zig");
const internal = @import("internal.zig");
const pages = @import("pages.zig");
const testhooks = @import("testhooks.zig");
const Req = web.Req;

pub fn dispatch(r: *Req) !void {
    const ctx = r.ctx.?;
    const path = ctx.path;
    if (std.ascii.eqlIgnoreCase(std.mem.trimEnd(u8, path, "/"), "/healthz") and (r.method() == .GET or r.method() == .HEAD)) return healthz(r);
    if (web.under(path, "/api/internal")) |rest| return internal.handle(r, rest);
    if (web.under(path, "/api/app")) |rest| return app_api.handle(r, rest);
    if (web.under(path, "/api/v1")) |rest| return v1.handle(r, rest);
    if (web.under(path, "/api/public")) |rest| return public.handle(r, rest);
    if (web.under(path, "/api") != null) return r.fail(404, "not_found", "No such endpoint", .{});
    if (a_.cfg().is_test) if (web.under(path, "/__test")) |rest| return testhooks.handle(r, rest);
    if (r.method() == .GET or r.method() == .HEAD) if (try staticFile(r)) return;
    if (try pages.handle(r)) return;
    return notFoundPage(r);
}

/// For uptime monitors: 200 when the app and its database answer.
fn healthz(r: *Req) !void {
    _ = db.client.command(r.a, "admin", .{ .ping = 1 }) catch return r.json(503, .{ .ok = false });
    try r.setHeader("cache-control", "no-store");
    return r.json(200, .{ .ok = true });
}

pub fn readPublic(r: *Req, rel: []const u8) ![]const u8 {
    const full = try std.fs.path.join(r.a, &.{ a_.cfg().public_dir, rel });
    return Io.Dir.cwd().readFileAlloc(r.ctx.?.io, full, r.a, .limited(64 << 20));
}

pub fn contentType(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    const extra = [_]struct { []const u8, []const u8 }{
        .{ ".json", "application/json; charset=utf-8" },
        .{ ".map", "application/json; charset=utf-8" },
        .{ ".xml", "application/xml" },
        .{ ".woff", "font/woff" },
        .{ ".ttf", "font/ttf" },
        .{ ".otf", "font/otf" },
        .{ ".csv", "text/csv; charset=utf-8" },
        .{ ".md", "text/markdown; charset=utf-8" },
    };
    for (extra) |t| if (std.ascii.eqlIgnoreCase(ext, t[0])) return t[1];
    return http.contentType(path);
}

/// express.static(public, { index: false }): files only, no dot-files; sw.js and offline.html
/// are always revalidated, so a new version reaches installed apps at once.
fn staticFile(r: *Req) !bool {
    const ctx = r.ctx.?;
    const rel_raw = http.decode(r.a, ctx.path) catch return false;
    const rel = std.mem.trimStart(u8, rel_raw, "/");
    if (rel.len == 0 or std.mem.endsWith(u8, rel, "/")) return false;
    var parts = std.mem.splitAny(u8, rel, "/\\");
    while (parts.next()) |p| {
        if (p.len == 0 or p[0] == '.' or std.mem.indexOfScalar(u8, p, 0) != null or std.mem.indexOfScalar(u8, p, ':') != null) return false;
    }
    const data = readPublic(r, rel) catch return false;
    const name = std.fs.path.basename(rel);
    if (std.mem.eql(u8, rel, "sw.js")) {
        try r.setHeader("service-worker-allowed", "/");
        try r.setHeader("cache-control", "no-cache");
    } else if (std.mem.eql(u8, name, "offline.html")) {
        try r.setHeader("cache-control", "no-cache");
    } else try r.setHeader("cache-control", if (a_.cfg().is_production) "public, max-age=3600" else "public, max-age=0");
    try r.send(200, contentType(rel), data);
    return true;
}

fn notFoundPage(r: *Req) !void {
    const html = readPublic(r, "404.html") catch "<!doctype html><title>Not found</title><h1>Not found</h1>";
    return r.html(404, html);
}
