//! Turf server: the Turf-js API on zig-core (same endpoints, answers, database documents,
//! environment variables and background jobs), so it can replace Turf-js without Control,
//! Wufour or the apps noticing.
//!
//! Configuration: environment variables, else `.env.local` / `.env.production` / `.env` (see
//! app.Config). Under NODE_ENV=test no env file is read, like Turf-js's test harness.

const std = @import("std");
const http = @import("http");
const mongo = @import("mongo");
const env_mod = @import("env");
const val = @import("mongo").val;
const db = @import("lib/db.zig");
const a_ = @import("app.zig");
const web = @import("web.zig");
const bus = @import("bus.zig");
const realtime = @import("realtime.zig");
const routes = @import("routes/routes.zig");
const testhooks = @import("routes/testhooks.zig");
const errors = @import("services/errors.zig");
const live = @import("services/live.zig");
const webhooks = @import("services/webhooks.zig");
const dispatch = @import("services/dispatch.zig");
const push = @import("services/push.zig");
const direct = @import("services/direct.zig");
const emails = @import("services/emails.zig");
const moderation = @import("services/moderation.zig");
const Req = web.Req;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    // `turf-server --call <function> <json args>`: runs one pure function and prints its result
    // (the parity tests call Turf-js's helper functions this way).
    var argv = try init.minimal.args.iterateAllocator(arena);
    _ = argv.next();
    if (argv.next()) |first| if (std.mem.eql(u8, first, "--call")) return testhooks.cliCall(init, &argv);

    const env = try env_mod.Env.loadApp(arena, io, init.environ_map, "turf");
    var config = a_.Config.load(arena, &env) catch std.process.exit(1);
    if (config.public_dir.len == 0) {
        const exe_dir = std.process.executableDirPathAlloc(io, arena) catch ".";
        config.public_dir = try std.fs.path.join(arena, &.{ exe_dir, "..", "web" });
    }

    const client = try mongo.Client.init(io, gpa, config.mongo_uri);
    defer client.deinit();
    db.client = client;
    db.db_name = config.mongo_db;
    // FCM and APNs for the phone apps (off unless their environment variables are set).
    push.initNative(gpa, io, &env);

    var state: a_.App = .{
        .io = io,
        .gpa = gpa,
        .config = config,
        .fetch = .init(io, gpa),
        .wufour = undefined,
        .started_ms = std.Io.Timestamp.now(io, .real).toMilliseconds(),
    };
    defer state.fetch.deinit();
    state.wufour = .{ .fetch = &state.fetch, .host = config.auth_host, .ttl_ms = 0 };
    defer state.wufour.deinit();
    a_.app = &state;
    realtime.init();
    state.legacy_pages = if (std.Io.Dir.cwd().statFile(io, try std.fs.path.join(arena, &.{ config.public_dir, "app.html" }), .{})) |_| true else |_| false;
    std.log.info("Pages from {s} ({s})", .{ config.public_dir, if (state.legacy_pages) "Turf-js public folder" else "zui web build" });
    web.errors_hook = errors.fromRequest;
    bus.bindings = &bindings;
    // TURF_SERVICES=live,dispatch,push starts only those services (the test harness, like
    // Turf-js's helpers); default all.
    if (env.get("TURF_SERVICES")) |list| {
        bus.enabled = @splat(false);
        var it = std.mem.splitScalar(u8, list, ',');
        while (it.next()) |name| if (bus.serviceOf(std.mem.trim(u8, name, " "))) |s| {
            bus.enabled[@backingInt(s)] = true;
        };
    }

    if (config.is_production and !config.trust_proxy)
        std.log.warn("WARNING: TRUST_PROXY is not \"true\". Behind a reverse proxy every visitor shares the proxy's IP, so per-IP rate limits and live-stream caps would apply to everyone together.", .{});
    moderation.logIfOff();

    ensureIndexes(arena) catch |err| {
        std.log.err("MongoDB: {t} {s}", .{ err, db.lastError() });
        return err;
    };

    var router: http.Router = .init(gpa);
    defer router.deinit();
    router.fallback = handle;

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, webhooks.loop, .{});
    try group.concurrent(io, dispatch.loop, .{});
    try group.concurrent(io, direct.loop, .{});
    try group.concurrent(io, emails.loop, .{});

    std.log.info("Turf running on {s} (port {d})", .{ config.public_url, config.port });
    try http.serve(io, gpa, .{
        .address = try .parse(config.listen, config.port),
        .router = &router,
        .trust_proxy = config.trust_proxy,
        // Logo sets and delivery photos arrive as data URLs; each group checks its own limit.
        .max_body = 3 * 1024 * 1024 + 1,
    });
}

/// Every listener, in Turf-js's start order: live, webhooks, dispatch, push, direct, emails.
const bindings = [_]bus.Binding{
    .{ .event = "direct.offer", .name = "live", .listener = live.onDirectOffer },
    .{ .event = "direct.answered", .name = "live", .listener = live.onDirectAnswered },
    .{ .event = "shipment.created", .name = "live", .listener = live.onShipmentCreated },
    .{ .event = "shipment.event", .name = "live", .listener = live.onShipmentEvent },
    .{ .event = "task.changed", .name = "live", .listener = live.onTaskChanged },
    .{ .event = "courier.position", .name = "live", .listener = live.onCourierPosition },
    .{ .event = "courier.duty", .name = "live", .listener = live.onCourierDuty },
    .{ .event = "alert.raised", .name = "live", .listener = live.onAlert },
    .{ .event = "alert.updated", .name = "live", .listener = live.onAlert },
    .{ .event = "shipment.created", .name = "webhooks", .listener = webhooks.onShipmentCreated },
    .{ .event = "shipment.event", .name = "webhooks", .listener = webhooks.onShipmentEvent },
    .{ .event = "shipment.created", .name = "dispatch", .listener = dispatch.autoPlanNewShipment },
    .{ .event = "shipment.event", .name = "dispatch", .listener = dispatch.autoPlanFromHub },
    .{ .event = "task.changed", .name = "push", .listener = pushTask },
    .{ .event = "alert.raised", .name = "push", .listener = pushAlert },
    .{ .event = "shipment.event", .name = "emails", .listener = emails.queueEvent },
};

fn pushTask(r: *Req, e: val.Val) anyerror!void {
    return push.onTaskChanged(r.a, e);
}

fn pushAlert(r: *Req, e: val.Val) anyerror!void {
    return push.onAlertRaised(r.a, e);
}

/// Every request: security headers, the Express mount order, the JSON error handler, and the
/// domain-event listeners once the answer is sent.
fn handle(ctx: *http.Context) anyerror!void {
    var r: Req = .{ .a = ctx.arena, .ctx = ctx };
    try web.securityHeaders(ctx);
    routes.dispatch(&r) catch |err| {
        if (!ctx.responded) r.sendError(err) catch {};
        if (!ctx.responded) return err;
    };
    if (!ctx.responded) try r.json(500, .{ .@"error" = .{ .code = "server_error", .message = "Something went wrong on our side" } });
    bus.flush(&r);
}

// ---- Indexes ------------------------------------------------------------------------------------

const IndexSpec = struct { coll: []const u8, keys: []const u8, options: []const u8 = "{}" };

/// The indexes Turf-js creates (src/db.js ensureIndexes), as JSON. A changed TTL is updated in
/// place; any other conflict stops startup, like Turf-js.
fn ensureIndexes(arena: std.mem.Allocator) !void {
    _ = try db.client.command(arena, "admin", .{ .ping = 1 });
    const retention = a_.cfg().location_retention_days * 24 * 3600;
    const ttl_positions = try std.fmt.allocPrint(arena, "{{\"expireAfterSeconds\":{d}}}", .{retention});
    const specs = [_]IndexSpec{
        .{ .coll = "users", .keys = "{\"email\":1}" },
        .{ .coll = "orgs", .keys = "{\"slug\":1}", .options = "{\"unique\":true}" },
        .{ .coll = "orgs", .keys = "{\"type\":1,\"status\":1}" },
        .{ .coll = "orgs", .keys = "{\"ownerUserId\":1}", .options = "{\"unique\":true,\"partialFilterExpression\":{\"personal\":true}}" },
        .{ .coll = "memberships", .keys = "{\"orgId\":1,\"userId\":1}", .options = "{\"unique\":true}" },
        .{ .coll = "memberships", .keys = "{\"userId\":1}" },
        .{ .coll = "memberships", .keys = "{\"orgId\":1,\"roleId\":1}" },
        .{ .coll = "memberships", .keys = "{\"lastLocation\":\"2dsphere\"}", .options = "{\"sparse\":true}" },
        .{ .coll = "roles", .keys = "{\"orgId\":1,\"name\":1}", .options = "{\"unique\":true}" },
        .{ .coll = "invitations", .keys = "{\"token\":1}", .options = "{\"unique\":true}" },
        .{ .coll = "invitations", .keys = "{\"email\":1,\"status\":1}" },
        .{ .coll = "invitations", .keys = "{\"orgId\":1,\"status\":1}" },
        .{ .coll = "hubs", .keys = "{\"orgId\":1,\"code\":1}", .options = "{\"unique\":true}" },
        .{ .coll = "hubs", .keys = "{\"location\":\"2dsphere\"}" },
        .{ .coll = "shipments", .keys = "{\"trackingNumber\":1}", .options = "{\"unique\":true}" },
        .{ .coll = "shipments", .keys = "{\"publicToken\":1}", .options = "{\"unique\":true}" },
        .{ .coll = "shipments", .keys = "{\"merchantId\":1,\"externalRef\":1}", .options = "{\"unique\":true,\"partialFilterExpression\":{\"externalRef\":{\"$type\":\"string\"}}}" },
        .{ .coll = "shipments", .keys = "{\"merchantId\":1,\"testRef\":1}", .options = "{\"unique\":true,\"partialFilterExpression\":{\"testRef\":{\"$type\":\"string\"}}}" },
        .{ .coll = "shipments", .keys = "{\"merchantId\":1,\"createdAt\":-1}" },
        .{ .coll = "shipments", .keys = "{\"carrierId\":1,\"status\":1,\"createdAt\":-1}" },
        .{ .coll = "shipments", .keys = "{\"carrierId\":1,\"createdAt\":-1}" },
        .{ .coll = "shipments", .keys = "{\"carrierIds\":1,\"createdAt\":-1}" },
        .{ .coll = "shipments", .keys = "{\"deliveredAt\":1}", .options = "{\"sparse\":true}" },
        .{ .coll = "shipments", .keys = "{\"carrierId\":1,\"merchantId\":1,\"statusAt\":-1}" },
        .{ .coll = "shipments", .keys = "{\"status\":1,\"offer.expiresAt\":1}", .options = "{\"partialFilterExpression\":{\"status\":\"awaiting_carrier\"}}" },
        .{ .coll = "shipment_events", .keys = "{\"shipmentId\":1,\"at\":1}" },
        .{ .coll = "shipment_events", .keys = "{\"merchantId\":1,\"code\":1,\"at\":1}" },
        .{ .coll = "email_queue", .keys = "{\"sentAt\":1,\"at\":1}" },
        .{ .coll = "email_queue", .keys = "{\"orgId\":1,\"sentAt\":1}" },
        .{ .coll = "email_queue", .keys = "{\"sentAt\":1}", .options = "{\"name\":\"sent_ttl\",\"expireAfterSeconds\":604800}" },
        .{ .coll = "tasks", .keys = "{\"carrierId\":1,\"status\":1}" },
        .{ .coll = "tasks", .keys = "{\"courierId\":1,\"status\":1}" },
        .{ .coll = "tasks", .keys = "{\"shipmentIds\":1}" },
        .{ .coll = "courier_positions", .keys = "{\"courierId\":1,\"at\":-1}" },
        .{ .coll = "courier_positions", .keys = "{\"at\":1}", .options = ttl_positions },
        .{ .coll = "alerts", .keys = "{\"carrierId\":1,\"status\":1,\"at\":-1}" },
        .{ .coll = "alerts", .keys = "{\"courierId\":1,\"type\":1,\"status\":1}" },
        .{ .coll = "api_keys", .keys = "{\"hash\":1}", .options = "{\"unique\":true}" },
        .{ .coll = "api_keys", .keys = "{\"orgId\":1}" },
        .{ .coll = "webhook_deliveries", .keys = "{\"status\":1,\"nextAttemptAt\":1}" },
        .{ .coll = "webhook_deliveries", .keys = "{\"orgId\":1,\"createdAt\":-1}" },
        .{ .coll = "assets", .keys = "{\"orgId\":1,\"kind\":1}" },
        .{ .coll = "audit_log", .keys = "{\"orgId\":1,\"at\":-1}" },
        .{ .coll = "push_subscriptions", .keys = "{\"endpoint\":1}", .options = "{\"unique\":true}" },
        .{ .coll = "push_subscriptions", .keys = "{\"userId\":1}" },
        .{ .coll = "platform_payments", .keys = "{\"month\":1,\"orgId\":1}" },
        .{ .coll = "platform_payments", .keys = "{\"orgId\":1,\"month\":1}" },
        .{ .coll = "org_documents", .keys = "{\"orgId\":1}" },
        .{ .coll = "claims", .keys = "{\"merchantId\":1,\"createdAt\":-1}" },
        .{ .coll = "claims", .keys = "{\"carrierId\":1,\"status\":1,\"createdAt\":-1}" },
        .{ .coll = "claims", .keys = "{\"shipmentId\":1}" },
        .{ .coll = "error_log", .keys = "{\"fingerprint\":1}", .options = "{\"unique\":true}" },
        .{ .coll = "error_log", .keys = "{\"lastAt\":1}", .options = "{\"expireAfterSeconds\":2592000}" },
    };
    for (specs) |s| {
        const keys = try val.parseJson(arena, s.keys);
        const options = try val.parseJson(arena, s.options);
        db.col(s.coll).createIndex(arena, keys, options) catch |err| {
            // A changed TTL is the common case: update it in place instead of failing startup.
            const msg = db.lastError();
            const conflict = std.mem.indexOf(u8, msg, "different options") != null or std.mem.indexOf(u8, msg, "already exists") != null;
            if (err == error.CommandFailed and conflict and options.get("expireAfterSeconds") != .undef) {
                _ = try db.command(arena, .{ .collMod = s.coll, .index = .{ .keyPattern = keys, .expireAfterSeconds = options.get("expireAfterSeconds") } });
                continue;
            }
            std.log.err("Index {s} {s}: {s}", .{ s.coll, s.keys, msg });
            return err;
        };
    }
}

test {
    std.testing.refAllDecls(@This());
    inline for (.{
        @import("mongo").val,               @import("lib/db.zig"),              @import("web.zig"),                @import("auth.zig"),
        @import("app.zig"),                 @import("permissions.zig"),         @import("messages.zig"),           @import("geo.zig"),
        @import("crypto.zig"),              @import("barcode.zig"),             @import("ratelimit.zig"),          @import("realtime.zig"),
        @import("mailer.zig"),              @import("bus.zig"),                 @import("routes/routes.zig"),      @import("routes/testhooks.zig"),
        @import("services/emails.zig"),     @import("services/bulk.zig"),       @import("services/accounts.zig"),  @import("services/verification.zig"),
        @import("services/reports.zig"),    @import("services/statements.zig"), @import("services/feedback.zig"),  @import("services/claims.zig"),
        @import("services/testmode.zig"),   @import("services/direct.zig"),     @import("services/dispatch.zig"),  @import("services/tracking.zig"),
        @import("services/operations.zig"), @import("services/earnings.zig"),   @import("services/tasks.zig"),     @import("services/errors.zig"),
        @import("services/relay.zig"),      @import("services/allocation.zig"), @import("services/shipments.zig"), @import("services/apikeys.zig"),
        @import("services/live.zig"),       @import("services/webhooks.zig"),   @import("services/push.zig"),      @import("services/routing.zig"),
        @import("services/carriers.zig"),   @import("services/pricing.zig"),    @import("services/places.zig"),    @import("services/coverage.zig"),
        @import("services/branding.zig"),   @import("services/members.zig"),    @import("services/orgs.zig"),      @import("services/moderation.zig"),
        @import("services/platform.zig"),   @import("services/audit.zig"),
    }) |m| std.testing.refAllDecls(m);
}
