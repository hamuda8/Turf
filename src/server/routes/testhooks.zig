//! Test hooks for the parity suite (Turf-js's tests call some server functions directly). Only
//! under NODE_ENV=test:
//!   POST /__test/call { fn, args }  runs a function inside the server (state, database, timers)
//!   turf-server --call <fn> <args>  runs a pure function and prints its result
//! Values travel as typed JSON ({"$date": ms}, {"$oid": hex}, {"$bin": base64}, {"$undef": 1});
//! failures as {"$error": { status, code, message, extra }}.

const std = @import("std");
const val = @import("../lib/val.zig");
const web = @import("../web.zig");
const a_ = @import("../app.zig");
const env_mod = @import("env");
const bus = @import("../bus.zig");
const geo = @import("../geo.zig");
const barcode = @import("../barcode.zig");
const messages = @import("../messages.zig");
const permissions = @import("../permissions.zig");
const mailer = @import("../mailer.zig");
const coverage = @import("../services/coverage.zig");
const shipments = @import("../services/shipments.zig");
const webhooks = @import("../services/webhooks.zig");
const pricing = @import("../services/pricing.zig");
const bulk = @import("../services/bulk.zig");
const reports = @import("../services/reports.zig");
const push = @import("../services/push.zig");
const platform = @import("../services/platform.zig");
const direct = @import("../services/direct.zig");
const dispatch = @import("../services/dispatch.zig");
const emails = @import("../services/emails.zig");
const verification = @import("../services/verification.zig");
const Val = val.Val;
const Req = web.Req;
const V = web.V;

pub fn handle(r: *Req, path: []const u8) !void {
    if (r.method() != .POST or !std.mem.eql(u8, std.mem.trim(u8, path, "/"), "call")) return r.fail(404, "not_found", "No such test hook", .{});
    const raw = try r.ctx.?.body();
    const body = try val.parseJsonDates(r.a, raw);
    const result = call(r, body.s("fn") orelse "", body.get("args")) catch |err| {
        if (err != error.Http) return err;
        return r.send(200, "application/json", try errorJson(r));
    };
    bus.flush(r);
    return r.send(200, "application/json", try val.toJsonTyped(r.a, try val.from(r.a, .{ .result = result })));
}

fn errorJson(r: *Req) ![]const u8 {
    const e = r.err.?;
    return val.toJsonTyped(r.a, try val.from(r.a, .{ .@"$error" = .{ .status = e.status, .code = e.code, .message = e.message, .extra = if (e.extra == .undef) try val.newObj(r.a) else e.extra } }));
}

/// `turf-server --call <fn> <typed JSON array of args>`
pub fn cliCall(init: std.process.Init, argv: anytype) !void {
    const arena = init.arena.allocator();
    const name = argv.next() orelse return error.MissingFunction;
    const args_text = argv.next() orelse "[]";
    // Pure functions need no database: the required settings get harmless defaults.
    var env: env_mod.Env = .{ .environ = init.environ_map };
    try env.file.put(arena, "MONGO_URI", "mongodb://127.0.0.1:27017");
    try env.file.put(arena, "MONGO_DB", "Turf_cli");
    try env.file.put(arena, "APP_SECRET", "cli");
    const config = a_.Config.load(arena, &env) catch std.process.exit(2);
    var state: a_.App = .{ .io = init.io, .gpa = init.gpa, .config = config, .client = .{ .allocator = init.gpa, .io = init.io }, .started_ms = 0 };
    a_.app = &state;
    var r = Req.background(arena);
    const args = try val.parseJsonDates(arena, args_text);
    const text = if (call(&r, name, args)) |result|
        try val.toJsonTyped(arena, try val.from(arena, .{ .result = result }))
    else |err| if (err == error.Http) try errorJson(&r) else return err;
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(init.io, &buf);
    try w.interface.writeAll(text);
    try w.interface.flush();
}

fn arg(args: Val, i: usize) Val {
    return args.at(i);
}

fn str(v: Val) []const u8 {
    return v.asStr() orelse "";
}

fn ms(v: Val) ?i64 {
    return switch (v) {
        .date => |d| d,
        .num => |n| @intFromFloat(n),
        else => null,
    };
}

/// Validator options as the JS code passes them.
fn strOpts(o: Val) web.StrOpts {
    var s: web.StrOpts = .{};
    if (o.n("min")) |x| s.min = @intFromFloat(x);
    if (o.n("max")) |x| s.max = @intFromFloat(x);
    if (o.get("optional").truthy()) s.optional = true;
    if (o.get("trim") == .bool) s.trim = o.get("trim").bool;
    return s;
}

fn numOpts(o: Val) web.NumOpts {
    var s: web.NumOpts = .{};
    if (o.n("min")) |x| s.min = x;
    if (o.n("max")) |x| s.max = x;
    if (o.get("optional").truthy()) s.optional = true;
    if (o.get("integer").truthy()) s.integer = true;
    return s;
}

fn optStr(a: std.mem.Allocator, s: ?[]const u8) !Val {
    _ = a;
    return if (s) |x| Val{ .str = x } else .undef;
}

fn call(r: *Req, name: []const u8, args: Val) !Val {
    const a = r.a;
    const eq = struct {
        fn f(x: []const u8, y: []const u8) bool {
            return std.mem.eql(u8, x, y);
        }
    }.f;
    // ---- src/http.js
    if (eq(name, "V.str")) return optStr(a, try V.str(r, arg(args, 0), str(arg(args, 1)), strOpts(arg(args, 2))));
    if (eq(name, "V.num")) return if (try V.num(r, arg(args, 0), str(arg(args, 1)), numOpts(arg(args, 2)))) |x| Val{ .num = x } else .undef;
    if (eq(name, "V.phone")) return optStr(a, try V.phone(r, arg(args, 0), str(arg(args, 1)), strOpts(arg(args, 2))));
    if (eq(name, "V.email")) return optStr(a, try V.email(r, arg(args, 0), str(arg(args, 1)), strOpts(arg(args, 2))));
    if (eq(name, "V.bool")) return if (try V.boolean(r, arg(args, 0), str(arg(args, 1)), .{ .optional = arg(args, 2).get("optional").truthy() })) |x| Val{ .bool = x } else .undef;
    if (eq(name, "V.slug")) return optStr(a, try V.slug(r, arg(args, 0), str(arg(args, 1)), .{ .optional = arg(args, 2).get("optional").truthy() }));
    if (eq(name, "V.hexColor")) return optStr(a, try V.hexColor(r, arg(args, 0), str(arg(args, 1)), strOpts(arg(args, 2))));
    // ---- pure helpers
    if (eq(name, "normCity")) return .{ .str = try coverage.normCity(a, if (arg(args, 0).isNullish()) "" else try val.toStr(a, arg(args, 0))) };
    if (eq(name, "coversAddress")) return .{ .bool = try coverage.coversAddress(a, arg(args, 0), arg(args, 1)) };
    if (eq(name, "normalizeTrackingNumber")) {
        const v = arg(args, 0);
        return if (try shipments.normalizeTrackingNumber(a, if (v.isNullish()) "" else try val.toStr(a, v))) |n| Val{ .str = n } else .null;
    }
    if (eq(name, "splitTrackingNumbers")) {
        const v = arg(args, 0);
        return val.from(a, try shipments.splitTrackingNumbers(a, if (v.isNullish()) "" else try val.toStr(a, v)));
    }
    if (eq(name, "localToday")) return .{ .str = try shipments.localToday(a) };
    if (eq(name, "isPrivateIp")) return .{ .bool = webhooks.isPrivateIp(str(arg(args, 0))) };
    if (eq(name, "quotePrice")) return pricing.quotePrice(a, arg(args, 0), arg(args, 1));
    if (eq(name, "chargeableKg")) return .{ .num = pricing.chargeableKg(arg(args, 0), val.toNum(arg(args, 1)), arg(args, 2)) };
    if (eq(name, "zoneOf")) return .{ .str = pricing.zoneOf(arg(args, 0), arg(args, 1)) };
    if (eq(name, "promiseHours")) return .{ .num = pricing.promiseHours(arg(args, 0), str(arg(args, 1)), arg(args, 2).asStr()) };
    if (eq(name, "expressReason")) return if (try pricing.expressReason(a, arg(args, 0), arg(args, 1), ms(arg(args, 2)) orelse a_.nowMs())) |x| Val{ .str = x } else .null;
    if (eq(name, "openAt")) return .{ .bool = pricing.openAt(arg(args, 0), ms(arg(args, 1)) orelse a_.nowMs()) };
    if (eq(name, "rowToBody")) return bulk.rowToBody(a, try arg(args, 0).deepCopy(a), arg(args, 1));
    if (eq(name, "parseRange")) {
        const rg = try reports.parseRange(r, arg(args, 0).asStr(), arg(args, 1).asStr());
        return val.from(a, .{ .from = val.Date{ .ms = rg.from }, .to = val.Date{ .ms = rg.to }, .fromDay = rg.from_day, .toDay = rg.to_day });
    }
    if (eq(name, "encryptPayload")) {
        const keys = arg(args, 1);
        const testing = arg(args, 2);
        const out = try push.encryptPayload(a, str(arg(args, 0)), str(keys.get("p256dh")), str(keys.get("auth")), testing.s("asPrivate"), testing.s("salt"));
        return .{ .bin = out };
    }
    if (eq(name, "code128Svg")) return .{ .str = try barcode.code128Svg(a, str(arg(args, 0)), .{}) };
    if (eq(name, "eventText")) return .{ .str = try messages.eventText(a, arg(args, 0), arg(args, 1).asStr() orelse "en") };
    if (eq(name, "statusText")) return .{ .str = messages.statusText(str(arg(args, 0)), arg(args, 1).asStr() orelse "en") };
    if (eq(name, "distanceKm")) return .{ .num = geo.distanceKmV(arg(args, 0), arg(args, 1)) };
    if (eq(name, "isSubset")) {
        var keys: std.ArrayList([]const u8) = .empty;
        for (arg(args, 1).items()) |k| try keys.append(a, str(k));
        return .{ .bool = permissions.isSubset(arg(args, 0), .{ .keys = keys.items }) };
    }
    // ---- server state (HTTP hook only)
    if (r.ctx == null) return r.fail(400, "not_pure", "This function needs the running server", .{});
    if (eq(name, "updatePlatformSettings")) return platform.update(r, arg(args, 0));
    if (eq(name, "expireOffers")) return .{ .num = @floatFromInt(try direct.expireOffers(r)) };
    if (eq(name, "planScheduledDeliveries")) {
        try dispatch.planScheduledDeliveries(r);
        return .undef;
    }
    if (eq(name, "watchdog")) {
        try dispatch.watchdog(r);
        return .undef;
    }
    if (eq(name, "startWebhooks")) {
        bus.enabled[@intFromEnum(bus.Service.webhooks)] = true;
        return .undef;
    }
    if (eq(name, "startEmails")) {
        bus.enabled[@intFromEnum(bus.Service.emails)] = true;
        return .undef;
    }
    if (eq(name, "processEmailQueue")) {
        const o = arg(args, 0);
        try emails.processEmailQueue(a, ms(o.get("now")) orelse a_.nowMs(), o.get("force").truthy());
        return .undef;
    }
    if (eq(name, "sendDailySummaries")) {
        try emails.sendDailySummaries(a, ms(arg(args, 0)) orelse a_.nowMs());
        return .undef;
    }
    if (eq(name, "outbox")) return val.parseJson(a, try mailer.outboxJson(a));
    if (eq(name, "verification.adminView")) return verification.adminView(r, arg(args, 0));
    if (eq(name, "verification.getDocument")) return verification.getDocument(r, arg(args, 0), arg(args, 1));
    if (eq(name, "verification.review")) {
        const o = arg(args, 2);
        try verification.review(r, arg(args, 0), arg(args, 1), str(o.get("decision")), o.get("note").asStr());
        return .undef;
    }
    return r.fail(404, "unknown_function", name, .{});
}
