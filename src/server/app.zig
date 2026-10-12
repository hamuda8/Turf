//! Shared state of the Turf server and small helpers every module uses. Configuration comes from
//! the same environment variables (and env file) as Turf-js's src/config.js, so either server can
//! run on the same machine and database without changes.

const std = @import("std");
const Io = std.Io;
const env_mod = @import("env");
const val = @import("lib/val.zig");

pub const Config = struct {
    port: u16,
    listen: []const u8,
    public_url: []const u8,
    is_production: bool,
    is_test: bool,
    mongo_uri: []const u8,
    mongo_db: []const u8,
    app_secret: []const u8,
    auth_host: []const u8,
    internal_api_key: []const u8,
    platform_admin_user_ids: []const []const u8,
    control_url: []const u8,
    alert_webhook_url: ?[]const u8,
    legal_entity_name: []const u8,
    contact_email: []const u8,
    /// Date of the current terms; companies record the version they accepted.
    terms_version: []const u8 = "2026-10-05",
    auto_approve_carriers: bool,
    direct_offer_minutes: i64,
    merchant_signup: []const u8,
    maps_url: []const u8,
    maps_internal_url: []const u8,
    maps_api_key: []const u8,
    map_tile_url: []const u8,
    moderation_host: []const u8,
    moderation_api_key: []const u8,
    location_retention_days: i64,
    stale_location_minutes: i64,
    long_stop_minutes: i64,
    paused_alert_minutes: i64,
    trust_proxy: bool,
    /// Static files of the web app (Turf-js's `public/` until the Zig client replaces it).
    public_dir: []const u8,
    smtp: Smtp,

    pub const Smtp = struct {
        host: []const u8,
        port: u16,
        secure: bool,
        user: []const u8,
        pass: []const u8,
        from: []const u8,
        allow_insecure: bool,
    };

    pub const Missing = error{MissingEnv};

    pub fn load(arena: std.mem.Allocator, e: *const env_mod.Env) !Config {
        const trim = struct {
            fn slash(s: []const u8) []const u8 {
                return std.mem.trimEnd(u8, s, "/");
            }
        }.slash;
        var admins: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, e.str("PLATFORM_ADMIN_USER_IDS", ""), ',');
        while (it.next()) |raw| {
            const s = std.mem.trim(u8, raw, " \t");
            if (s.len > 0) try admins.append(arena, s);
        }
        const signup = e.str("MERCHANT_SIGNUP", "");
        const smtp_port = intOr(e, "SMTP_PORT", 587);
        const maps_url = trim(e.str("MAPS_URL", "http://localhost:5005"));
        const node_env = e.str("NODE_ENV", "");
        return .{
            .port = @intCast(intOr(e, "PORT", 5000)),
            .listen = e.str("LISTEN", "0.0.0.0"),
            .public_url = trim(e.str("PUBLIC_URL", "http://localhost:5000")),
            .is_production = std.mem.eql(u8, node_env, "production"),
            .is_test = std.mem.eql(u8, node_env, "test"),
            .mongo_uri = try required(e, "MONGO_URI"),
            .mongo_db = try required(e, "MONGO_DB"),
            .app_secret = try required(e, "APP_SECRET"),
            .auth_host = trim(e.str("AUTH_HOST", "http://localhost:4000")),
            .internal_api_key = e.str("INTERNAL_API_KEY", ""),
            .platform_admin_user_ids = admins.items,
            .control_url = trim(e.str("CONTROL_URL", "http://localhost:4500")),
            .alert_webhook_url = if (e.str("ALERT_WEBHOOK_URL", "").len > 0) e.str("ALERT_WEBHOOK_URL", "") else null,
            .legal_entity_name = e.str("LEGAL_ENTITY_NAME", "Turf"),
            .contact_email = e.str("CONTACT_EMAIL", "support@example.com"),
            .auto_approve_carriers = std.mem.eql(u8, e.str("AUTO_APPROVE_CARRIERS", ""), "true"),
            .direct_offer_minutes = intOr(e, "DIRECT_OFFER_MINUTES", 10),
            .merchant_signup = if (std.mem.eql(u8, signup, "open") or std.mem.eql(u8, signup, "approval") or std.mem.eql(u8, signup, "closed")) signup else "approval",
            .maps_url = maps_url,
            .maps_internal_url = trim(e.str("MAPS_INTERNAL_URL", e.str("MAPS_URL", "http://localhost:5005"))),
            .maps_api_key = e.str("MAPS_API_KEY", ""),
            .map_tile_url = e.str("MAP_TILE_URL", "https://tile.openstreetmap.org/{z}/{x}/{y}.png"),
            .moderation_host = trim(e.str("MODERATION_HOST", "")),
            .moderation_api_key = e.str("MODERATION_API_KEY", ""),
            .location_retention_days = intOr(e, "LOCATION_RETENTION_DAYS", 30),
            .stale_location_minutes = intOr(e, "STALE_LOCATION_MINUTES", 10),
            .long_stop_minutes = intOr(e, "LONG_STOP_MINUTES", 25),
            .paused_alert_minutes = intOr(e, "PAUSED_ALERT_MINUTES", 3),
            .trust_proxy = std.mem.eql(u8, e.str("TRUST_PROXY", ""), "true"),
            .public_dir = e.str("TURF_PUBLIC_DIR", "public"),
            .smtp = .{
                .host = e.str("SMTP_HOST", ""),
                .port = @intCast(smtp_port),
                .secure = if (e.get("SMTP_SECURE")) |v| (if (v.len > 0) std.mem.eql(u8, v, "true") else smtp_port == 465) else smtp_port == 465,
                .user = e.str("SMTP_USER", ""),
                .pass = e.str("SMTP_PASS", ""),
                .from = e.str("MAIL_FROM", e.str("SMTP_USER", "no-reply@localhost")),
                .allow_insecure = std.mem.eql(u8, e.str("SMTP_ALLOW_INSECURE", ""), "true"),
            },
        };
    }

    fn required(e: *const env_mod.Env, name: []const u8) ![]const u8 {
        const v = e.str(name, "");
        if (v.len == 0) {
            std.log.err("Missing required environment variable: {s}", .{name});
            return error.MissingEnv;
        }
        return v;
    }

    /// parseInt(value, 10), or the default when it is not a number.
    fn intOr(e: *const env_mod.Env, name: []const u8, default: i64) i64 {
        const v = e.get(name) orelse return default;
        const x = val.parseIntJs(v);
        return if (std.math.isNan(x)) default else @intFromFloat(x);
    }
};

pub const App = struct {
    io: Io,
    gpa: std.mem.Allocator,
    config: Config,
    /// Outgoing requests: Wufour, Maps, Moderation, webhooks, push services.
    client: std.http.Client,
    started_ms: i64,
};

/// The one instance; set in main before serving.
pub var app: *App = undefined;

pub fn cfg() *const Config {
    return &app.config;
}

pub fn nowMs() i64 {
    return Io.Timestamp.now(app.io, .real).toMilliseconds();
}

pub fn now() val.Val {
    return .{ .date = nowMs() };
}

/// `n` random bytes.
pub fn random(buf: []u8) void {
    app.io.random(buf);
}

pub const Upstream = struct {
    status: std.http.Status,
    content_type: []const u8,
    body: []const u8,
};

pub const UpstreamOptions = struct {
    method: std.http.Method = .GET,
    body: ?[]const u8 = null,
    content_type: []const u8 = "application/json",
    headers: []const std.http.Header = &.{},
    /// Repeat once on a broken pooled connection; only for requests that are safe to repeat.
    retry: bool = true,
    max_body: usize = 16 << 20,
};

/// One request to another service. Errors when it cannot be reached.
pub fn upstream(arena: std.mem.Allocator, url: []const u8, o: UpstreamOptions) !Upstream {
    // A pooled connection the other side closed while idle fails at once: try again on a new one.
    return upstreamOnce(arena, url, o) catch |e| switch (e) {
        error.OutOfMemory => e,
        else => if (o.retry) upstreamOnce(arena, url, o) else e,
    };
}

fn upstreamOnce(arena: std.mem.Allocator, url: []const u8, o: UpstreamOptions) !Upstream {
    var req = try app.client.request(o.method, try std.Uri.parse(url), .{
        .extra_headers = o.headers,
        .redirect_behavior = .unhandled,
        .keep_alive = true,
        .headers = .{ .accept_encoding = .omit },
    });
    defer req.deinit();
    if (o.body) |b| {
        req.transfer_encoding = .{ .content_length = b.len };
        req.headers.content_type = .{ .override = o.content_type };
        var w = try req.sendBodyUnflushed(&.{});
        try w.writer.writeAll(b);
        try w.end();
        try req.connection.?.flush();
    } else try req.sendBodiless();
    var res = try req.receiveHead(&.{});
    const content_type = try arena.dupe(u8, res.head.content_type orelse "");
    const status = res.head.status;
    var transfer: [64]u8 = undefined;
    const body = try res.reader(&transfer).allocRemaining(arena, .limited(o.max_body));
    return .{ .status = status, .content_type = content_type, .body = body };
}

/// Runs `upstream` with a deadline, like fetch with AbortSignal.timeout: error.Timeout when the
/// other side is too slow.
pub fn upstreamTimeout(arena: std.mem.Allocator, url: []const u8, o: UpstreamOptions, timeout_ms: i64) !Upstream {
    const Call = struct {
        fn run(a: std.mem.Allocator, u: []const u8, opts: UpstreamOptions) anyerror!Upstream {
            return upstream(a, u, opts);
        }
    };
    const U = union(enum) { done: anyerror!Upstream, slept: void };
    var buf: [2]U = undefined;
    var sel = Io.Select(U).init(app.io, &buf);
    sel.concurrent(.done, Call.run, .{ arena, url, o }) catch return upstream(arena, url, o);
    sel.concurrent(.slept, sleepMs, .{timeout_ms}) catch {
        const r = sel.await() catch |e| {
            sel.cancelDiscard();
            return e;
        };
        sel.cancelDiscard();
        return r.done;
    };
    const first = sel.await() catch |e| {
        sel.cancelDiscard();
        return e;
    };
    sel.cancelDiscard();
    return switch (first) {
        .done => |r| r,
        .slept => error.Timeout,
    };
}

fn sleepMs(ms: i64) void {
    app.io.sleep(.fromMilliseconds(ms), .awake) catch {};
}
