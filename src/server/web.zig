//! The request side of the port, mirroring Turf-js's Express setup: `Req` (what Express keeps on
//! `req`/`res`: the arena, the signed-in user, the org context, the parsed body), `HttpError`
//! with the same `{ error: { code, message, ...extra } }` answers, the `V` validators of
//! src/http.js with the same messages, and a small router with Express's matching rules.
//!
//! Service functions return `error.Http` after `r.fail(...)` stored the details, the way the
//! JavaScript code throws an HttpError; the dispatcher turns it into the JSON answer.

const std = @import("std");
const http = @import("http");
const val = @import("lib/val.zig");
const Val = val.Val;
const Allocator = std.mem.Allocator;
const a_ = @import("app.zig");

pub const HttpError = struct {
    status: u16,
    code: []const u8,
    message: []const u8,
    /// Extra fields of the error object (field, rule, params, ...), or undefined.
    extra: Val = .undef,
};

pub const Error = error{Http};

/// Permissions of the acting member in an org (small list; owners hold every key).
pub const Perms = struct {
    keys: []const []const u8 = &.{},

    pub fn has(p: Perms, key: []const u8) bool {
        for (p.keys) |k| if (std.mem.eql(u8, k, key)) return true;
        return false;
    }
};

/// What withOrg puts on req.ctx: the org, the acting membership, its role and permissions.
pub const OrgCtx = struct {
    org: Val,
    member: Val,
    role: Val,
    perms: Perms,
};

pub const Event = struct { name: []const u8, payload: Val };

pub const Req = struct {
    a: Allocator,
    ctx: ?*http.Context = null,
    err: ?HttpError = null,
    /// The signed-in Wufour user ({ id, email, username, isPlatformAdmin }) or undefined.
    user: Val = .undef,
    token: ?[]const u8 = null,
    /// The token came from `Authorization: Bearer` (native apps), not from a cookie.
    bearer: bool = false,
    body: Val = .undef,
    oc: ?OrgCtx = null,
    /// /api/v1: the API key document, its merchant and whether it is a test key.
    api_key: Val = .undef,
    merchant: Val = .undef,
    /// Driver app routes: the courier's membership.
    courier: Val = .undef,
    test_mode: bool = false,
    /// Domain events emitted while handling the request; listeners run after the response.
    events: std.ArrayList(Event) = .empty,
    /// The embed page may be framed by other sites.
    allow_framing: bool = false,
    /// More script-src sources for this answer (zui pages: inline script hashes, WebAssembly).
    script_extra: []const u8 = "",
    params: std.ArrayList(http.Param) = .empty,
    query_cache: ?Val = null,

    /// A request-less context for background jobs.
    pub fn background(a: Allocator) Req {
        return .{ .a = a };
    }

    // ---- Errors --------------------------------------------------------------------------

    /// Stores the error and returns error.Http (the `throw new HttpError(...)` of the JS code).
    pub fn fail(r: *Req, status: u16, code: []const u8, message: []const u8, extra: anytype) Error {
        r.err = .{ .status = status, .code = code, .message = message, .extra = val.from(r.a, extra) catch .undef };
        return error.Http;
    }

    pub fn failf(r: *Req, status: u16, code: []const u8, comptime fmt: []const u8, args: anytype, extra: anytype) Error {
        const text = std.fmt.allocPrint(r.a, fmt, args) catch "Error";
        return r.fail(status, code, text, extra);
    }

    /// badRequest(message, field, rule, params)
    pub fn badRequest(r: *Req, message: []const u8, field: ?[]const u8, rule: ?[]const u8, params: anytype) Error {
        const extra = val.newObj(r.a) catch return r.fail(400, "invalid_request", message, .{});
        if (field) |f| extra.set("field", f) catch {};
        if (rule) |x| extra.set("rule", x) catch {};
        const p = val.from(r.a, params) catch Val.undef;
        if (p != .undef and p != .null) extra.set("params", p) catch {};
        return r.fail(400, "invalid_request", message, extra);
    }

    pub fn notFound(r: *Req, what: []const u8) Error {
        return r.fail(404, "not_found", std.fmt.allocPrint(r.a, "{s} not found", .{what}) catch "Not found", .{});
    }

    pub fn forbidden(r: *Req, message: ?[]const u8) Error {
        return r.fail(403, "forbidden", message orelse "You do not have permission to do this", .{});
    }

    /// conflict(message, code = 'conflict', params)
    pub fn conflict(r: *Req, message: []const u8, code: ?[]const u8, params: anytype) Error {
        const p = val.from(r.a, params) catch Val.undef;
        if (p == .undef or p == .null) return r.fail(409, code orelse "conflict", message, .{});
        return r.fail(409, code orelse "conflict", message, .{ .params = p });
    }

    // ---- Request -------------------------------------------------------------------------

    pub fn param(r: *const Req, name: []const u8) []const u8 {
        for (r.params.items) |p| if (std.mem.eql(u8, p.name, name)) return p.value;
        return "";
    }

    pub fn header(r: *const Req, name: []const u8) ?[]const u8 {
        const c = r.ctx orelse return null;
        return c.header(name);
    }

    /// req.query as Express 5's simple parser builds it: strings, arrays for repeated keys.
    pub fn query(r: *Req) Val {
        if (r.query_cache) |cached| return cached;
        const parsed = parseQuery(r.a, if (r.ctx) |c| c.query else "") catch Val.undef;
        r.query_cache = parsed;
        return parsed;
    }

    pub fn q(r: *Req, name: []const u8) Val {
        return r.query().get(name);
    }

    /// The query value as a string (first one when repeated), or null when absent.
    pub fn qs(r: *Req, name: []const u8) ?[]const u8 {
        const v = r.q(name);
        return switch (v) {
            .str => |x| x,
            .arr => |x| if (x.items.items.len > 0) x.items.items[0].asStr() else null,
            else => null,
        };
    }

    pub fn method(r: *const Req) http.Method {
        return if (r.ctx) |c| c.method else .GET;
    }

    pub fn ip(r: *const Req) []const u8 {
        const c = r.ctx orelse return "";
        return c.clientIp();
    }

    pub fn orgCtx(r: *Req) *OrgCtx {
        return &r.oc.?;
    }

    // ---- Response ------------------------------------------------------------------------

    pub fn setHeader(r: *Req, name: []const u8, value: []const u8) !void {
        if (r.ctx) |c| try c.setHeader(name, value);
    }

    pub fn removeHeader(r: *Req, name: []const u8) void {
        const c = r.ctx orelse return;
        var i: usize = 0;
        while (i < c.response_headers.items.len) {
            if (std.ascii.eqlIgnoreCase(c.response_headers.items[i].name, name)) {
                _ = c.response_headers.orderedRemove(i);
            } else i += 1;
        }
    }

    pub fn addHeader(r: *Req, name: []const u8, value: []const u8) !void {
        if (r.ctx) |c| try c.response_headers.append(c.arena, .{ .name = name, .value = value });
    }

    /// res.status(status).json(value)
    pub fn json(r: *Req, status: u16, value: anytype) !void {
        const v = try val.from(r.a, value);
        const text = try val.toJson(r.a, v);
        return r.send(status, "application/json; charset=utf-8", text);
    }

    pub fn send(r: *Req, status: u16, content_type: []const u8, body: []const u8) !void {
        const c = r.ctx orelse return;
        if (c.responded) return;
        if (r.allow_framing) r.removeHeader("x-frame-options");
        if (r.allow_framing or r.script_extra.len > 0) try c.setHeader("content-security-policy", try csp(r.a, r.allow_framing, r.script_extra));
        return c.send(@enumFromInt(status), content_type, body);
    }

    pub fn html(r: *Req, status: u16, body: []const u8) !void {
        return r.send(status, "text/html; charset=utf-8", body);
    }

    /// res.status(status).end()
    pub fn end(r: *Req, status: u16) !void {
        const c = r.ctx orelse return;
        if (c.responded) return;
        c.responded = true;
        try c.request.respond("", .{ .status = @enumFromInt(status), .extra_headers = c.response_headers.items });
    }

    pub fn redirect(r: *Req, status: u16, location: []const u8) !void {
        try r.setHeader("location", location);
        const body = try std.fmt.allocPrint(r.a, "{s}. Redirecting to {s}", .{ if (status == 301) "Moved Permanently" else "Found", location });
        return r.send(status, "text/plain; charset=utf-8", body);
    }

    pub fn responded(r: *const Req) bool {
        return if (r.ctx) |c| c.responded else false;
    }

    /// Sends the stored error, or a 500 for anything else (the Express error handler).
    pub fn sendError(r: *Req, err: anyerror) !void {
        if (err == error.Http) {
            const e = r.err orelse HttpError{ .status = 500, .code = "server_error", .message = "Something went wrong on our side" };
            const body = try val.newObj(r.a);
            try body.set("code", e.code);
            try body.set("message", e.message);
            if (e.extra.asObj()) |o| for (o.keys.items, o.vals.items) |k, x| try body.obj.put(k, x);
            return r.json(e.status, .{ .@"error" = body });
        }
        if (err == error.DuplicateKey) return r.json(409, .{ .@"error" = .{ .code = "conflict", .message = "A record with the same unique value already exists" } });
        if (err == error.InvalidJson) return r.json(400, .{ .@"error" = .{ .code = "invalid_json", .message = "Request body is not valid JSON" } });
        if (err == error.PayloadTooLarge) return r.json(413, .{ .@"error" = .{ .code = "payload_too_large", .message = "Request body is too large" } });
        std.log.err("Unhandled error: {t} {s} {s}", .{ err, if (r.ctx) |c| @tagName(c.method) else "", if (r.ctx) |c| c.path else "" });
        if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
        errors_hook(r, err);
        return r.json(500, .{ .@"error" = .{ .code = "server_error", .message = "Something went wrong on our side" } });
    }
};

/// Records unexpected errors for Control's error log (set by main to services/errors.zig).
pub var errors_hook: *const fn (r: *Req, err: anyerror) void = noHook;
fn noHook(_: *Req, _: anyerror) void {}

// ---- Query and body ---------------------------------------------------------------------------

pub fn parseQuery(a: Allocator, raw: []const u8) !Val {
    const out = try val.newObj(a);
    var it = std.mem.splitScalar(u8, raw, '&');
    while (it.next()) |pair| {
        if (pair.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        const k = http.decode(a, pair[0..eq]) catch pair[0..eq];
        const v: []const u8 = if (eq < pair.len) (http.decode(a, pair[eq + 1 ..]) catch pair[eq + 1 ..]) else "";
        if (out.obj.get(k)) |existing| {
            if (existing == .arr) {
                try existing.push(v);
            } else {
                try out.obj.put(k, try val.arrOf(a, &.{ existing, .{ .str = v } }));
            }
        } else try out.obj.put(k, .{ .str = v });
    }
    return out;
}

/// express.json({ limit }): parses a JSON body (objects and arrays only) when the request says
/// it is JSON; anything else leaves an empty object.
pub fn parseBody(r: *Req, limit: usize) !void {
    const c = r.ctx orelse return;
    r.body = try val.newObj(r.a);
    const ct = c.header("content-type") orelse return;
    if (!isJsonType(ct)) return;
    if (c.header("content-length")) |cl| {
        const n = std.fmt.parseInt(usize, std.mem.trim(u8, cl, " "), 10) catch 0;
        if (n > limit) return error.PayloadTooLarge;
    }
    const raw = c.body() catch |e| switch (e) {
        error.PayloadTooLarge => return error.PayloadTooLarge,
        else => return error.InvalidJson,
    };
    if (raw.len > limit) return error.PayloadTooLarge;
    const text = std.mem.trim(u8, raw, " \t\r\n");
    if (text.len == 0) return;
    if (text[0] != '{' and text[0] != '[') return error.InvalidJson;
    r.body = val.parseJson(r.a, text) catch return error.InvalidJson;
}

fn isJsonType(ct: []const u8) bool {
    const base = std.mem.trim(u8, ct[0 .. std.mem.indexOfScalar(u8, ct, ';') orelse ct.len], " ");
    if (std.ascii.eqlIgnoreCase(base, "application/json")) return true;
    if (std.ascii.startsWithIgnoreCase(base, "application/") and std.ascii.endsWithIgnoreCase(base, "+json")) return true;
    return false;
}

// ---- Security headers -------------------------------------------------------------------------

fn originOf(url: []const u8) []const u8 {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return "";
    const rest = url[scheme_end + 3 ..];
    const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    return url[0 .. scheme_end + 3 + end];
}

/// "https://{s}.tile.example.org/{z}/{x}/{y}.png" -> "https://*.tile.example.org"
fn tileOrigin(a: Allocator) ![]const u8 {
    const t = a_.cfg().map_tile_url;
    const o = originOf(t);
    if (o.len == 0) return "";
    if (std.mem.indexOf(u8, t, "{s}") != null) return std.mem.replaceOwned(u8, a, o, "://{s}.", "://*.");
    return o;
}

/// The Content-Security-Policy of src/server.js. Embed pages may be framed by any site.
pub fn csp(a: Allocator, allow_framing: bool, script_extra: []const u8) ![]const u8 {
    const maps = originOf(a_.cfg().maps_url);
    const tiles = try tileOrigin(a);
    return std.fmt.allocPrint(a, "default-src 'self'; script-src 'self'{s} {s}; style-src 'self' 'unsafe-inline' {s}; font-src 'self'; img-src 'self' data: blob: {s} {s}; connect-src 'self' {s} {s}; worker-src 'self' blob:; child-src blob:; manifest-src 'self'; object-src 'none'; base-uri 'self'; form-action 'self'; frame-ancestors {s}", .{
        script_extra, maps, maps, tiles, maps, maps, tiles, if (allow_framing) "*" else "'none'",
    });
}

pub fn securityHeaders(c: *http.Context) !void {
    try c.setHeader("x-content-type-options", "nosniff");
    try c.setHeader("referrer-policy", "strict-origin-when-cross-origin");
    try c.setHeader("permissions-policy", "geolocation=(self), camera=(self), microphone=()");
    try c.setHeader("cross-origin-opener-policy", "same-origin");
    try c.setHeader("content-security-policy", try csp(c.arena, false, ""));
    try c.setHeader("x-frame-options", "DENY");
}

// ---- Routing ----------------------------------------------------------------------------------

pub const Handler = *const fn (r: *Req) anyerror!void;

pub const Route = struct {
    method: ?http.Method,
    pattern: []const u8,
    handler: Handler,
    /// Run before the handler, in order (need(...), rate limits, ...).
    mw: []const Handler = &.{},
};

pub fn route(method: ?http.Method, pattern: []const u8, handler: Handler) Route {
    return .{ .method = method, .pattern = pattern, .handler = handler };
}

pub fn routeMw(method: ?http.Method, pattern: []const u8, mw: []const Handler, handler: Handler) Route {
    return .{ .method = method, .pattern = pattern, .handler = handler, .mw = mw };
}

/// Express path matching (case-insensitive, optional trailing slash). `:name` is one segment,
/// a final `*name` the rest (possibly empty).
pub fn match(r: *Req, pattern: []const u8, path: []const u8) !bool {
    const mark = r.params.items.len;
    var pi = std.mem.splitScalar(u8, std.mem.trim(u8, pattern, "/"), '/');
    var si = std.mem.splitScalar(u8, std.mem.trim(u8, path, "/"), '/');
    if (std.mem.trim(u8, pattern, "/").len == 0) return std.mem.trim(u8, path, "/").len == 0;
    while (pi.next()) |p| {
        if (p.len > 0 and p[0] == '*') {
            try r.params.append(r.a, .{ .name = p[1..], .value = uriDecode(r.a, si.rest()) });
            return true;
        }
        const s = si.next() orelse {
            r.params.shrinkRetainingCapacity(mark);
            return false;
        };
        if (p.len > 0 and p[0] == ':') {
            if (s.len == 0) {
                r.params.shrinkRetainingCapacity(mark);
                return false;
            }
            try r.params.append(r.a, .{ .name = p[1..], .value = uriDecode(r.a, s) });
        } else if (!std.ascii.eqlIgnoreCase(p, s)) {
            r.params.shrinkRetainingCapacity(mark);
            return false;
        }
    }
    if (si.next() != null) {
        r.params.shrinkRetainingCapacity(mark);
        return false;
    }
    return true;
}

/// Runs the first route of `routes` matching method and path (relative to the group's mount
/// point). Returns false when none matched (Express would fall through to the next handler).
pub fn runRoutes(r: *Req, routes: []const Route, path: []const u8) !bool {
    const m = r.method();
    for (routes) |rt| {
        if (rt.method) |want| {
            if (want != m and !(want == .GET and m == .HEAD)) continue;
        }
        const mark = r.params.items.len;
        if (!try match(r, rt.pattern, path)) continue;
        for (rt.mw) |mw| {
            try mw(r);
            if (r.responded()) return true;
        }
        try rt.handler(r);
        _ = mark;
        return true;
    }
    return false;
}

/// The part of `path` under mount point `prefix` ("/api/app/me" under "/api/app" is "/me"), or
/// null when it is not under it.
pub fn under(path: []const u8, prefix: []const u8) ?[]const u8 {
    if (path.len < prefix.len) return null;
    if (!std.ascii.eqlIgnoreCase(path[0..prefix.len], prefix)) return null;
    const rest = path[prefix.len..];
    if (rest.len == 0) return "/";
    if (rest[0] != '/') return null;
    return rest;
}

// ---- Middleware builders ----------------------------------------------------------------------

/// Require every listed permission.
pub fn need(comptime perms: []const []const u8) Handler {
    return struct {
        fn f(r: *Req) anyerror!void {
            const oc = r.oc orelse return r.forbidden(null);
            inline for (perms) |p| if (!oc.perms.has(p)) return r.forbidden(null);
        }
    }.f;
}

/// Require at least one of the listed permissions.
pub fn needAny(comptime perms: []const []const u8) Handler {
    return struct {
        fn f(r: *Req) anyerror!void {
            const oc = r.oc orelse return r.forbidden(null);
            inline for (perms) |p| if (oc.perms.has(p)) return;
            return r.forbidden(null);
        }
    }.f;
}

pub fn onlyType(comptime t: []const u8) Handler {
    return struct {
        fn f(r: *Req) anyerror!void {
            const oc = r.oc orelse return r.notFound("Route");
            if (!std.mem.eql(u8, oc.org.s("type") orelse "", t)) return r.notFound("Route");
        }
    }.f;
}

// ---- Validators (src/http.js V.*) -------------------------------------------------------------

fn invalid(r: *Req, field: []const u8, rule: []const u8, message: []const u8, params: anytype) Error {
    const extra = val.newObj(r.a) catch return error.Http;
    extra.set("field", field) catch {};
    extra.set("rule", rule) catch {};
    const p = val.from(r.a, params) catch Val.undef;
    if (p != .undef and p != .null) extra.set("params", p) catch {};
    return r.fail(400, "invalid_request", message, extra);
}

fn msg(r: *Req, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(r.a, fmt, args) catch "invalid";
}

fn fmtNum(r: *Req, x: f64) []const u8 {
    if (std.math.isInf(x)) return if (x > 0) "Infinity" else "-Infinity";
    return val.numStr(r.a, x) catch "?";
}

pub const StrOpts = struct {
    min: usize = 1,
    max: usize = 200,
    optional: bool = false,
    pattern: ?*const fn ([]const u8) bool = null,
    trim: bool = true,
};

pub const NumOpts = struct {
    min: f64 = -std.math.inf(f64),
    max: f64 = std.math.inf(f64),
    optional: bool = false,
    integer: bool = false,
};

pub const V = struct {
    pub fn str(r: *Req, value: Val, field: []const u8, o: StrOpts) Error!?[]const u8 {
        if (value.isMissing()) {
            if (o.optional) return null;
            return invalid(r, field, "required", msg(r, "{s} is required", .{field}), null);
        }
        const raw = value.asStr() orelse return invalid(r, field, "string", msg(r, "{s} must be a string", .{field}), null);
        const s = if (o.trim) val.jsTrim(raw) else raw;
        const l = val.jsLength(s);
        if (l < o.min) return invalid(r, field, "min_length", msg(r, "{s} must be at least {d} characters", .{ field, o.min }), .{ .min = o.min });
        if (l > o.max) return invalid(r, field, "max_length", msg(r, "{s} must be at most {d} characters", .{ field, o.max }), .{ .max = o.max });
        if (o.pattern) |p| if (!p(s)) return invalid(r, field, "format", msg(r, "{s} has an invalid format", .{field}), null);
        return s;
    }

    pub fn num(r: *Req, value: Val, field: []const u8, o: NumOpts) Error!?f64 {
        if (value.isMissing()) {
            if (o.optional) return null;
            return invalid(r, field, "required", msg(r, "{s} is required", .{field}), null);
        }
        const x: f64 = switch (value) {
            .num => |v| v,
            .str => |s| if (val.jsTrim(s).len > 0) val.strToNum(s) else return invalid(r, field, "number", msg(r, "{s} must be a number", .{field}), null),
            else => return invalid(r, field, "number", msg(r, "{s} must be a number", .{field}), null),
        };
        if (!std.math.isFinite(x)) return invalid(r, field, "number", msg(r, "{s} must be a number", .{field}), null);
        if (o.integer and x != @trunc(x)) return invalid(r, field, "integer", msg(r, "{s} must be a whole number", .{field}), null);
        if (x < o.min or x > o.max) {
            const rule = if (o.min == -std.math.inf(f64)) "max" else if (o.max == std.math.inf(f64)) "min" else "between";
            return invalid(r, field, rule, msg(r, "{s} must be between {s} and {s}", .{ field, fmtNum(r, o.min), fmtNum(r, o.max) }), .{
                .min = if (std.math.isFinite(o.min)) Val{ .num = o.min } else Val.null,
                .max = if (std.math.isFinite(o.max)) Val{ .num = o.max } else Val.null,
            });
        }
        return x;
    }

    pub fn boolean(r: *Req, value: Val, field: []const u8, o: struct { optional: bool = false }) Error!?bool {
        if (value.isMissing()) {
            if (o.optional) return null;
            return invalid(r, field, "required", msg(r, "{s} is required", .{field}), null);
        }
        return value.boolean() orelse invalid(r, field, "boolean", msg(r, "{s} must be true or false", .{field}), null);
    }

    pub fn oneOf(r: *Req, value: Val, field: []const u8, allowed: []const []const u8, o: struct { optional: bool = false }) Error!?[]const u8 {
        if (value.isMissing()) {
            if (o.optional) return null;
            return invalid(r, field, "required", msg(r, "{s} is required", .{field}), null);
        }
        if (value.asStr()) |s| for (allowed) |x| if (std.mem.eql(u8, x, s)) return x;
        const list = std.mem.join(r.a, ", ", allowed) catch "";
        return invalid(r, field, "one_of", msg(r, "{s} must be one of: {s}", .{ field, list }), null);
    }

    pub fn arr(r: *Req, value: Val, field: []const u8, o: struct { max: usize = 100, optional: bool = false }) Error!?[]Val {
        if (value.isMissing()) {
            if (o.optional) return null;
            return invalid(r, field, "required", msg(r, "{s} is required", .{field}), null);
        }
        if (value != .arr) return invalid(r, field, "array", msg(r, "{s} must be an array", .{field}), null);
        if (value.items().len > o.max) return invalid(r, field, "max_items", msg(r, "{s} can have at most {d} items", .{ field, o.max }), .{ .max = o.max });
        return value.items();
    }

    pub fn obj(r: *Req, value: Val, field: []const u8, o: struct { optional: bool = false }) Error!?Val {
        if (value.isMissing()) {
            if (o.optional) return null;
            return invalid(r, field, "required", msg(r, "{s} is required", .{field}), null);
        }
        if (value != .obj) return invalid(r, field, "object", msg(r, "{s} must be an object", .{field}), null);
        return value;
    }

    pub fn id(r: *Req, value: Val, field: []const u8, o: struct { optional: bool = false }) Error!?val.ObjectId {
        if (value.isMissing()) {
            if (o.optional) return null;
            return invalid(r, field, "required", msg(r, "{s} is required", .{field}), null);
        }
        return oid(value) orelse invalid(r, field, "id", msg(r, "{s} is not a valid id", .{field}), null);
    }

    pub fn email(r: *Req, value: Val, field: []const u8, o: StrOpts) Error!?[]const u8 {
        var opts = o;
        opts.max = 254;
        const s = (try str(r, value, field, opts)) orelse return null;
        if (!isEmail(s)) return invalid(r, field, "email", msg(r, "{s} must be a valid email", .{field}), null);
        return val.lower(r.a, s) catch s;
    }

    /// Local (09xxxxxxxx) and international numbers, stored without spaces.
    pub fn phone(r: *Req, value: Val, field: []const u8, o: StrOpts) Error!?[]const u8 {
        var opts = o;
        opts.max = 30;
        const s = (try str(r, value, field, opts)) orelse return null;
        var out: std.ArrayList(u8) = .empty;
        for (s) |c| switch (c) {
            ' ', '\t', '\n', '\r', 0x0b, 0x0c, '-', '(', ')' => {},
            else => out.append(r.a, c) catch {},
        };
        // \s also covers Unicode spaces; strip the common ones too.
        const normalized = std.mem.replaceOwned(u8, r.a, out.items, "\u{00A0}", "") catch out.items;
        if (!isPhone(normalized)) return invalid(r, field, "phone", msg(r, "{s} must be a valid phone number", .{field}), null);
        return normalized;
    }

    pub fn hexColor(r: *Req, value: Val, field: []const u8, o: StrOpts) Error!?[]const u8 {
        var opts = o;
        opts.max = 7;
        const s = (try str(r, value, field, opts)) orelse return null;
        const ok = s.len == 7 and s[0] == '#' and for (s[1..]) |c| {
            if (!std.ascii.isHex(c)) break false;
        } else true;
        if (!ok) return invalid(r, field, "color", msg(r, "{s} must be a color like #1a7f5a", .{field}), null);
        return val.lower(r.a, s) catch s;
    }

    pub fn url(r: *Req, value: Val, field: []const u8, o: struct { optional: bool = false, https_only: bool = false }) Error!?[]const u8 {
        const s = (try str(r, value, field, .{ .max = 500, .optional = o.optional })) orelse return null;
        const parsed = std.Uri.parse(s) catch return invalid(r, field, "url", msg(r, "{s} must be a valid URL", .{field}), null);
        const scheme = parsed.scheme;
        const ok = std.ascii.eqlIgnoreCase(scheme, "https") or (!o.https_only and std.ascii.eqlIgnoreCase(scheme, "http"));
        if (!ok) return invalid(r, field, "url", msg(r, "{s} must use {s}", .{ field, if (o.https_only) "https:" else "https: or http:" }), null);
        if (parsed.host == null) return invalid(r, field, "url", msg(r, "{s} must be a valid URL", .{field}), null);
        return normalizeUrl(r.a, s, parsed) catch s;
    }

    /// {lat, lng} as a GeoJSON Point.
    pub fn point(r: *Req, value: Val, field: []const u8, o: struct { optional: bool = false }) Error!?Val {
        if (value.isMissing()) {
            if (o.optional) return null;
            return invalid(r, field, "required", msg(r, "{s} is required", .{field}), null);
        }
        if (value != .obj and value != .arr) return invalid(r, field, "point", msg(r, "{s} must be an object with lat and lng", .{field}), null);
        const lat = (try num(r, value.get("lat"), msg(r, "{s}.lat", .{field}), .{ .min = -90, .max = 90 })).?;
        const lng = (try num(r, value.get("lng"), msg(r, "{s}.lng", .{field}), .{ .min = -180, .max = 180 })).?;
        return pointOf(r.a, lng, lat) catch return error.Http;
    }

    pub fn slug(r: *Req, value: Val, field: []const u8, o: struct { optional: bool = false }) Error!?[]const u8 {
        return str(r, value, field, .{ .min = 3, .max = 40, .pattern = isSlug, .optional = o.optional });
    }
};

pub fn pointOf(a: Allocator, lng: f64, lat: f64) !Val {
    return val.from(a, .{ .type = "Point", .coordinates = .{ lng, lat } });
}

/// /^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/
pub fn isSlug(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '-')) return false;
    return s[0] != '-' and s[s.len - 1] != '-';
}

/// /^[^\s@]+@[^\s@]+\.[^\s@]+$/
pub fn isEmail(s: []const u8) bool {
    const at = std.mem.indexOfScalar(u8, s, '@') orelse return false;
    if (std.mem.lastIndexOfScalar(u8, s, '@') != at) return false;
    for (s) |c| if (std.ascii.isWhitespace(c)) return false;
    const local = s[0..at];
    const domain = s[at + 1 ..];
    if (local.len == 0) return false;
    const dot = std.mem.lastIndexOfScalar(u8, domain, '.') orelse return false;
    return dot > 0 and dot < domain.len - 1;
}

/// /^\+?[0-9]{7,15}$/
pub fn isPhone(s: []const u8) bool {
    const digits = if (s.len > 0 and s[0] == '+') s[1..] else s;
    if (digits.len < 7 or digits.len > 15) return false;
    for (digits) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

/// new URL(s).toString(): lower-case scheme and host, "/" path when empty.
fn normalizeUrl(a: Allocator, s: []const u8, u: std.Uri) ![]const u8 {
    const scheme_end = std.mem.indexOf(u8, s, "://") orelse return s;
    const rest = s[scheme_end + 3 ..];
    const host_end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    const host_part = rest[0..host_end];
    const after = rest[host_end..];
    var host_l = try val.lower(a, host_part);
    // Default ports are dropped.
    if (std.ascii.eqlIgnoreCase(u.scheme, "https") and std.mem.endsWith(u8, host_l, ":443")) host_l = host_l[0 .. host_l.len - 4];
    if (std.ascii.eqlIgnoreCase(u.scheme, "http") and std.mem.endsWith(u8, host_l, ":80")) host_l = host_l[0 .. host_l.len - 3];
    const path_ = if (after.len == 0 or after[0] != '/') try std.mem.concat(a, u8, &.{ "/", after }) else after;
    return std.mem.concat(a, u8, &.{ try val.lower(a, u.scheme), "://", host_l, path_ });
}

/// oid(): an ObjectId from a 24-character hex string (or an ObjectId), else null.
pub fn oid(v: Val) ?val.ObjectId {
    return switch (v) {
        .oid => |x| x,
        .str => |s| if (s.len == 24) val.ObjectId.parse(s) catch null else null,
        else => null,
    };
}

pub fn oidStr(s: []const u8) ?val.ObjectId {
    return oid(.{ .str = s });
}

/// toLatLng(point): GeoJSON Point back to {lat, lng}, or null.
pub fn toLatLng(a: Allocator, point: Val) !Val {
    const c = point.get("coordinates");
    if (c.isNullish()) return .null;
    return val.from(a, .{ .lat = c.at(1), .lng = c.at(0) });
}

test "validators and matching" {
    try std.testing.expect(isSlug("sham-express"));
    try std.testing.expect(!isSlug("-x"));
    try std.testing.expect(isEmail("a@b.co"));
    try std.testing.expect(!isEmail("a@b"));
    try std.testing.expect(isPhone("+963944000000"));
    try std.testing.expect(!isPhone("12"));
    try std.testing.expectEqualStrings("/me", under("/api/app/me", "/api/app").?);
    try std.testing.expect(under("/api/apple", "/api/app") == null);
}

/// decodeURIComponent: percent escapes only ('+' stays '+'); the text as it is when malformed.
pub fn uriDecode(a: Allocator, s: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, s, '%') == null) return s;
    const out = a.alloc(u8, s.len) catch return s;
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (n += 1) {
        if (s[i] == '%') {
            if (i + 3 > s.len) return s;
            out[n] = std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16) catch return s;
            i += 3;
        } else {
            out[n] = s[i];
            i += 1;
        }
    }
    return out[0..n];
}

/// script-src additions for a zui page: the hash of each inline <script> and WebAssembly
/// compilation (Turf-js's own pages needed neither).
pub fn zuiScriptSources(a: Allocator, html: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, " 'wasm-unsafe-eval'");
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, html, i, "<script")) |start| {
        const tag_end = std.mem.indexOfScalarPos(u8, html, start, '>') orelse break;
        const close = std.mem.indexOfPos(u8, html, tag_end, "</script>") orelse break;
        i = close + 9;
        if (std.mem.indexOf(u8, html[start..tag_end], "src=") != null) continue;
        // Browsers hash the text after HTML newline normalization (CR LF and CR become LF).
        const body = try std.mem.replaceOwned(u8, a, html[tag_end + 1 .. close], "\r\n", "\n");
        std.mem.replaceScalar(u8, body, '\r', '\n');
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(body, &digest, .{});
        var b64: [44]u8 = undefined;
        try out.print(a, " 'sha256-{s}'", .{std.base64.standard.Encoder.encode(&b64, &digest)});
    }
    return out.items;
}
