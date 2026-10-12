//! Wufour sign-in, as src/auth.js and the wufour-auth library do it: the session token lives in
//! the `wufour_token` / `auth_token` cookies and is checked with Wufour's /api/auth/verify
//! (results cached for 30 s, so GPS pings and polling do not each ask Wufour).
//!
//! The native apps cannot use cookies: they send the same token as `Authorization: Bearer`,
//! verified the same way. Such requests never get a redirect to the login page (401 JSON
//! instead), get no cookies, and skip the CSRF header check, which only protects cookies.

const std = @import("std");
const Io = std.Io;
const val = @import("lib/val.zig");
const db = @import("lib/db.zig");
const web = @import("web.zig");
const a_ = @import("app.zig");
const http = @import("http");
const Val = val.Val;
const Req = web.Req;

const verify_cache_ms = 30_000;
const max_cache_entries = 20_000;
const cookie_max_age_s = 30 * 24 * 3600;

const CachedUser = struct { id: []const u8, email: []const u8, username: []const u8, is_admin: bool, until: i64 };

var cache_lock: Io.Mutex = .init;
/// token (owned) -> user (owned strings)
var cache: std.StringHashMapUnmanaged(CachedUser) = .empty;

/// Cookie values are URI-decoded (wufour-auth's parseCookies).
fn cookie(r: *Req, name: []const u8) ?[]const u8 {
    const c = r.ctx orelse return null;
    const raw = c.cookie(name) orelse return null;
    return http.decode(r.a, raw) catch raw;
}

fn cookieToken(r: *Req) ?[]const u8 {
    const t = cookie(r, "wufour_token") orelse cookie(r, "auth_token") orelse return null;
    return if (t.len > 0) t else null;
}

fn bearerToken(r: *Req) ?[]const u8 {
    const h = r.header("authorization") orelse return null;
    const t = std.mem.trim(u8, h, " ");
    if (t.len < 7 or !std.ascii.eqlIgnoreCase(t[0..7], "bearer ")) return null;
    const tok = std.mem.trim(u8, t[7..], " ");
    return if (tok.len > 0) tok else null;
}

/// The session token: the cookie (web) first, else a Bearer header (native apps).
fn readToken(r: *Req) ?[]const u8 {
    if (cookieToken(r)) |t| return t;
    if (bearerToken(r)) |t| {
        r.bearer = true;
        return t;
    }
    return null;
}

/// wufour-auth swaps "localhost" for 127.0.0.1 in server-to-server calls.
pub fn backendHost(a: std.mem.Allocator) []const u8 {
    const h = a_.cfg().auth_host;
    if (std.mem.indexOf(u8, h, "localhost") == null) return h;
    return std.mem.replaceOwned(u8, a, h, "localhost", "127.0.0.1") catch h;
}

/// Wufour's answer for `token`: the raw user object, or null (invalid, or Wufour unreachable).
pub fn verifyToken(a: std.mem.Allocator, token: []const u8) ?Val {
    const body = val.toJson(a, val.from(a, .{ .token = token }) catch return null) catch return null;
    const url = std.fmt.allocPrint(a, "{s}/api/auth/verify", .{backendHost(a)}) catch return null;
    const res = a_.upstream(a, url, .{ .method = .POST, .body = body }) catch return null;
    const data = val.parseJson(a, res.body) catch return null;
    if (!data.get("success").truthy()) return null;
    return data.get("user");
}

fn isAdmin(user: Val) bool {
    if (std.mem.eql(u8, user.s("role") orelse "", "admin")) return true;
    const uid = idText(user.get("userId")) orelse return false;
    for (a_.cfg().platform_admin_user_ids) |x| if (std.mem.eql(u8, x, uid)) return true;
    return false;
}

fn idText(v: Val) ?[]const u8 {
    return v.asStr();
}

/// The user object Turf works with: { id, email, username, isPlatformAdmin }.
pub fn decorate(a: std.mem.Allocator, user: Val) !Val {
    const email = user.s("email") orelse "";
    return val.from(a, .{
        .id = user.get("userId"),
        .email = try val.lower(a, email),
        .username = user.s("username") orelse "",
        .isPlatformAdmin = isAdmin(user),
    });
}

/// Keep a local copy of the profile so names and emails show without asking Wufour.
pub fn rememberUser(a: std.mem.Allocator, user: Val) !void {
    _ = try db.col("users").updateOne(a, .{ ._id = user.get("id") }, .{
        .@"$set" = .{ .email = user.get("email"), .username = user.get("username"), .lastSeenAt = a_.now() },
        .@"$setOnInsert" = .{ .createdAt = a_.now() },
    }, .{ .upsert = true });
}

fn verifyCached(r: *Req, token: []const u8) !?Val {
    const io = a_.app.io;
    const now = a_.nowMs();
    {
        cache_lock.lockUncancelable(io);
        defer cache_lock.unlock(io);
        if (cache.get(token)) |hit| if (hit.until > now) {
            return try val.from(r.a, .{ .id = hit.id, .email = hit.email, .username = hit.username, .isPlatformAdmin = hit.is_admin });
        };
    }
    const raw = verifyToken(r.a, token) orelse {
        forget(token);
        return null;
    };
    const user = try decorate(r.a, raw);
    store(token, user, now);
    try rememberUser(r.a, user);
    return user;
}

fn store(token: []const u8, user: Val, now: i64) void {
    const gpa = a_.app.gpa;
    const io = a_.app.io;
    const id_text = switch (user.get("id")) {
        .str => |s| s,
        else => return, // ids are strings; anything else is not cached
    };
    cache_lock.lockUncancelable(io);
    defer cache_lock.unlock(io);
    if (cache.count() >= max_cache_entries) {
        var dead: std.ArrayList([]const u8) = .empty;
        defer dead.deinit(gpa);
        var it = cache.iterator();
        while (it.next()) |e| if (e.value_ptr.until <= now) dead.append(gpa, e.key_ptr.*) catch {};
        for (dead.items) |k| removeLocked(k);
        if (cache.count() >= max_cache_entries) clearLocked();
    }
    removeLocked(token);
    const key = gpa.dupe(u8, token) catch return;
    const entry: CachedUser = .{
        .id = gpa.dupe(u8, id_text) catch return gpa.free(key),
        .email = gpa.dupe(u8, user.s("email") orelse "") catch return gpa.free(key),
        .username = gpa.dupe(u8, user.s("username") orelse "") catch return gpa.free(key),
        .is_admin = user.t("isPlatformAdmin"),
        .until = now + verify_cache_ms,
    };
    cache.put(gpa, key, entry) catch {
        gpa.free(key);
        freeEntry(entry);
    };
}

fn freeEntry(e: CachedUser) void {
    const gpa = a_.app.gpa;
    gpa.free(e.id);
    gpa.free(e.email);
    gpa.free(e.username);
}

fn removeLocked(token: []const u8) void {
    if (cache.fetchRemove(token)) |kv| {
        a_.app.gpa.free(kv.key);
        freeEntry(kv.value);
    }
}

fn clearLocked() void {
    var it = cache.iterator();
    while (it.next()) |e| {
        a_.app.gpa.free(e.key_ptr.*);
        freeEntry(e.value_ptr.*);
    }
    cache.clearRetainingCapacity();
}

pub fn forget(token: []const u8) void {
    cache_lock.lockUncancelable(a_.app.io);
    defer cache_lock.unlock(a_.app.io);
    removeLocked(token);
}

/// Express's res.cookie(name, value, { httpOnly, sameSite: 'lax', path: '/', maxAge, secure }).
fn setCookie(r: *Req, name: []const u8, value: []const u8, max_age_s: i64) !void {
    const expires = httpDate(r.a, a_.nowMs() + max_age_s * 1000);
    const enc = try http.encode(r.a, value);
    const secure = if (isSecure(r)) "; Secure" else "";
    try r.addHeader("set-cookie", try std.fmt.allocPrint(r.a, "{s}={s}; Max-Age={d}; Path=/; Expires={s}; HttpOnly{s}; SameSite=Lax", .{ name, enc, max_age_s, expires, secure }));
}

fn isSecure(r: *Req) bool {
    if (!a_.cfg().trust_proxy) return false;
    const proto = r.header("x-forwarded-proto") orelse return false;
    const first = std.mem.trim(u8, proto[0 .. std.mem.indexOfScalar(u8, proto, ',') orelse proto.len], " ");
    return std.mem.eql(u8, first, "https");
}

/// req.protocol
pub fn protocol(r: *Req) []const u8 {
    return if (isSecure(r)) "https" else "http";
}

/// "Wed, 11 Nov 2026 12:00:00 GMT"
pub fn httpDate(a: std.mem.Allocator, ms: i64) []const u8 {
    const c = val.civil(ms);
    const days = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
    const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    return std.fmt.allocPrint(a, "{s}, {d:0>2} {s} {d} {d:0>2}:{d:0>2}:{d:0>2} GMT", .{
        days[@intCast(c.weekday)], @as(u64, @intCast(c.day)), months[@intCast(c.month - 1)], @as(u64, @intCast(c.year)), @as(u64, @intCast(c.hour)), @as(u64, @intCast(c.minute)), @as(u64, @intCast(c.second)),
    }) catch "";
}

/// Wufour sessions slide for 30 days while used, so the cookies are renewed on each
/// authenticated request (couriers mid-shift stay signed in).
fn renewCookies(r: *Req, token: []const u8) !void {
    if (r.bearer) return;
    try setCookie(r, "wufour_token", token, cookie_max_age_s);
    try setCookie(r, "auth_token", token, cookie_max_age_s);
}

/// JSON middleware: 401 when not signed in. Sets r.user.
pub fn apiAuth(r: *Req) !void {
    const token = readToken(r) orelse return r.fail(401, "unauthenticated", "Please sign in", .{});
    const user = (try verifyCached(r, token)) orelse return r.fail(401, "unauthenticated", "Your session has expired. Please sign in again", .{});
    r.user = user;
    r.token = token;
    try renewCookies(r, token);
}

/// Same as apiAuth but lets anonymous requests through.
pub fn optionalAuth(r: *Req) !void {
    const token = readToken(r) orelse return;
    if (try verifyCached(r, token)) |user| r.user = user;
}

/// Blocks cross-site state-changing requests to the cookie-authenticated API: our pages always
/// send X-Requested-With, which a cross-site page cannot add without a preflight we never approve.
/// Bearer requests are not affected: browsers never attach that header on their own.
pub fn sameSiteOnly(r: *Req) !void {
    switch (r.method()) {
        .GET, .HEAD, .OPTIONS => return,
        else => {},
    }
    if (r.bearer) return;
    const xrw = r.header("x-requested-with") orelse "";
    if (!std.mem.eql(u8, xrw, "turf")) return r.fail(403, "csrf", "Missing X-Requested-With header", .{});
    if (r.header("origin")) |origin| {
        const host = originHost(origin);
        if (host == null or !std.mem.eql(u8, host.?, r.header("host") orelse "")) return r.fail(403, "csrf", "Cross-site request blocked", .{});
    }
}

/// new URL(origin).host (lower-case, default port dropped).
fn originHost(origin: []const u8) ?[]const u8 {
    const i = std.mem.indexOf(u8, origin, "://") orelse return null;
    const rest = origin[i + 3 ..];
    const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    if (end == 0) return null;
    return rest[0..end];
}

fn clearCookies(r: *Req) !void {
    for ([_][]const u8{ "auth_token", "wufour_token", "wufour_session" }) |n|
        try r.addHeader("set-cookie", try std.fmt.allocPrint(r.a, "{s}=; Path=/; Max-Age=0; HttpOnly; SameSite=Lax", .{n}));
}

fn wantsJson(r: *Req) bool {
    if (r.bearer or bearerToken(r) != null) return true;
    const acc = r.header("accept") orelse return false;
    return std.mem.indexOf(u8, acc, "json") != null;
}

/// Page middleware (wufour-auth's requireAuth): redirects to the Wufour login page when not
/// signed in; Bearer or JSON requests get 401 JSON instead. Returns false when it answered.
pub fn pageAuth(r: *Req) !bool {
    const c = r.ctx.?;
    const token = readToken(r);
    const redirectToLogin = struct {
        fn go(rq: *Req, ctx: *http.Context) !void {
            if (wantsJson(rq)) return rq.json(401, .{ .@"error" = .{ .code = "unauthenticated", .message = "Please sign in" } });
            const dest = if (ctx.query.len > 0) try std.fmt.allocPrint(rq.a, "{s}?{s}", .{ ctx.path, ctx.query }) else ctx.path;
            const callback = try std.fmt.allocPrint(rq.a, "{s}://{s}/auth/callback?next={s}", .{ protocol(rq), rq.header("host") orelse "localhost", try encodeUriComponent(rq.a, dest) });
            return rq.redirect(302, try std.fmt.allocPrint(rq.a, "{s}/auth?returnTo={s}", .{ a_.cfg().auth_host, try encodeUriComponent(rq.a, callback) }));
        }
    }.go;
    const t = token orelse {
        try redirectToLogin(r, c);
        return false;
    };
    const raw = verifyToken(r.a, t) orelse {
        if (!r.bearer) try clearCookies(r);
        try redirectToLogin(r, c);
        return false;
    };
    r.token = t;
    try renewCookies(r, t);
    r.user = try decorate(r.a, raw);
    try rememberUser(r.a, r.user);
    return true;
}

/// encodeURIComponent
pub fn encodeUriComponent(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "-_.!~*'()", c) != null) try out.append(a, c) else try out.print(a, "%{X:0>2}", .{c});
    }
    return out.items;
}

/// Only same-site relative paths as post-login destinations (no open redirects).
fn safeNext(v: ?[]const u8) []const u8 {
    const s = v orelse return "/app";
    if (s.len == 0 or s[0] != '/' or std.mem.startsWith(u8, s, "//") or std.mem.startsWith(u8, s, "/\\")) return "/app";
    return s;
}

/// GET /auth/login
pub fn loginRedirect(r: *Req) !void {
    const next = safeNext(r.qs("next"));
    const callback = try std.fmt.allocPrint(r.a, "{s}://{s}/auth/callback?next={s}", .{ protocol(r), r.header("host") orelse "localhost", try encodeUriComponent(r.a, next) });
    return r.redirect(302, try std.fmt.allocPrint(r.a, "{s}/auth?returnTo={s}", .{ a_.cfg().auth_host, try encodeUriComponent(r.a, callback) }));
}

/// GET /auth/callback?token=&next=
pub fn authCallback(r: *Req) !void {
    const next = safeNext(r.qs("next"));
    const token = r.qs("token") orelse "";
    if (token.len == 0) return r.redirect(302, "/");
    const user = verifyToken(r.a, token) orelse {
        try clearCookies(r);
        return r.redirect(302, "/?auth=failed");
    };
    rememberUser(r.a, try decorate(r.a, user)) catch |e| std.log.err("Custom Auth Hook Failed: {t}", .{e});
    try setCookie(r, "auth_token", token, 24 * 3600);
    try setCookie(r, "wufour_token", token, 24 * 3600);
    return r.redirect(302, next);
}

/// GET|POST /auth/logout
pub fn logout(r: *Req) !void {
    const token = cookie(r, "wufour_token") orelse cookie(r, "auth_token");
    if (token) |t| forget(t);
    const lt = cookie(r, "auth_token") orelse cookie(r, "wufour_token");
    if (lt) |t| {
        const body = try val.toJson(r.a, try val.from(r.a, .{ .token = t }));
        const url = try std.fmt.allocPrint(r.a, "{s}/api/auth/logout", .{backendHost(r.a)});
        _ = a_.upstream(r.a, url, .{ .method = .POST, .body = body, .retry = false }) catch |e| std.log.warn("Logout API Warning: {t}", .{e});
    }
    try clearCookies(r);
    const xhr = if (r.header("x-requested-with")) |x| std.ascii.eqlIgnoreCase(x, "xmlhttprequest") else false;
    if (xhr or (if (r.header("accept")) |acc| std.mem.indexOf(u8, acc, "json") != null else false)) return r.json(200, .{ .ok = true });
    return r.redirect(302, "/");
}

test encodeUriComponent {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("%2Fapp%3Fx%3D1", try encodeUriComponent(arena.allocator(), "/app?x=1"));
}
