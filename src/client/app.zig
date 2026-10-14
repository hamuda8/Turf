//! Turf client: the same code for the web, Android and iOS. A port of Turf-js's installable web
//! app (public/js): the account area, the carrier and merchant consoles, the courier's driver
//! app, the public tracking pages and, on the phones, an in-app sign-in.
//!
//! This file is the root: start-up (account, platform data, company), the address of each
//! screen and the route tables (Turf-js app.js), the message loop, and the tests.

const std = @import("std");
const zui = @import("zui");
const core = @import("core.zig");
const json = @import("json.zig");
const fmt = @import("fmt.zig");
const kit = @import("kit.zig");
const shell = @import("shell.zig");
const gps = @import("gps.zig");
const pages = @import("pages.zig");
const labels = @import("labels.zig");

pub const panic = zui.panic;
pub const boot: Msg = .boot;

pub const global_locale = @embedFile("locales/global.json");
pub const locales: []const zui.i18n.Locale = &.{
    .{ .lang = "ar", .json = @embedFile("locales/ar.json") },
};

comptime {
    zui.exportApp(@This());
}

pub const Msg = core.Msg;
pub const State = core.Cx;
const Cx = core.Cx;
const gpa = core.gpa;
const t = core.t;
const tag = core.tag;

pub fn init() State {
    return .{};
}

// ---- Route tables (Turf-js app.js) --------------------------------------------------------

pub const Route = struct {
    pattern: []const u8,
    page: pages.Id,
    /// Any of these permissions opens it.
    any: []const []const u8 = &.{},
    /// Couriers only (`isDriver`).
    driver: bool = false,
    /// Direct shipping must be on.
    direct: bool = false,
    /// Without the console frame (driver app, onboarding).
    bare: bool = false,
    /// Edge to edge (the live map).
    full: bool = false,
};

const view_perm = &.{"shipments.view"};

const account_routes = [_]Route{
    .{ .pattern = "/", .page = .home },
    .{ .pattern = "/new", .page = .create_org, .bare = true },
    .{ .pattern = "/new/:type", .page = .create_org, .bare = true },
    .{ .pattern = "/track", .page = .app_track },
    .{ .pattern = "/send", .page = .direct_send, .direct = true },
    .{ .pattern = "/parcels", .page = .direct_parcels, .direct = true },
    .{ .pattern = "/parcels/:id", .page = .direct_parcel, .direct = true },
};

const carrier_routes = [_]Route{
    .{ .pattern = "/", .page = .c_dashboard, .any = &.{ "shipments.view", "fleet.view" } },
    .{ .pattern = "/shipments", .page = .c_shipments, .any = view_perm },
    .{ .pattern = "/shipments/:id", .page = .c_shipment, .any = view_perm },
    .{ .pattern = "/dispatch", .page = .dispatch, .any = &.{"dispatch.manage"} },
    .{ .pattern = "/fleet", .page = .fleet, .any = &.{"fleet.view"}, .full = true },
    .{ .pattern = "/scan", .page = .scan, .any = &.{"hub.scan"} },
    .{ .pattern = "/alerts", .page = .alerts, .any = &.{"alerts.manage"} },
    .{ .pattern = "/finance", .page = .c_finance, .any = &.{"finance.view"} },
    .{ .pattern = "/requests", .page = .requests, .any = &.{"dispatch.manage"}, .direct = true },
    .{ .pattern = "/claims", .page = .claims, .any = view_perm },
    .{ .pattern = "/reports", .page = .reports, .any = &.{ "shipments.view", "finance.view" } },
    .{ .pattern = "/hubs", .page = .hubs, .any = &.{"hubs.manage"} },
    .{ .pattern = "/hubs/:id", .page = .hub, .any = &.{ "shipments.view", "hub.scan" } },
    .{ .pattern = "/settings", .page = .c_settings, .any = &.{"org.settings"} },
    .{ .pattern = "/team", .page = .team, .any = &.{ "members.view", "members.invite", "roles.manage" } },
    .{ .pattern = "/branding", .page = .branding, .any = &.{"org.branding"} },
    .{ .pattern = "/audit", .page = .audit, .any = &.{"audit.view"} },
    .{ .pattern = "/driver", .page = .driver, .driver = true, .bare = true },
    .{ .pattern = "/driver/task/:id", .page = .task, .driver = true, .bare = true },
    .{ .pattern = "/track", .page = .app_track },
};

const merchant_routes = [_]Route{
    .{ .pattern = "/", .page = .m_dashboard, .any = view_perm },
    .{ .pattern = "/shipments", .page = .m_shipments, .any = view_perm },
    .{ .pattern = "/shipments/new", .page = .m_new, .any = &.{"shipments.create"} },
    .{ .pattern = "/shipments/bulk", .page = .m_bulk, .any = &.{"shipments.create"} },
    .{ .pattern = "/shipments/:id", .page = .m_shipment, .any = view_perm },
    .{ .pattern = "/developers", .page = .developers, .any = &.{"api.manage"} },
    .{ .pattern = "/finance", .page = .m_finance, .any = &.{"finance.view"} },
    .{ .pattern = "/claims", .page = .claims, .any = view_perm },
    .{ .pattern = "/reports", .page = .reports, .any = &.{ "shipments.view", "finance.view" } },
    .{ .pattern = "/settings", .page = .m_settings, .any = &.{"org.settings"} },
    .{ .pattern = "/team", .page = .team, .any = &.{ "members.view", "members.invite", "roles.manage" } },
    .{ .pattern = "/branding", .page = .branding, .any = &.{"org.settings"} },
    .{ .pattern = "/audit", .page = .audit, .any = &.{"audit.view"} },
    .{ .pattern = "/track", .page = .app_track },
};

fn matches(pattern: []const u8, path: []const u8) bool {
    var pi = std.mem.tokenizeScalar(u8, pattern, '/');
    var xi = std.mem.tokenizeScalar(u8, path, '/');
    while (true) {
        const p = pi.next();
        const x = xi.next();
        if (p == null and x == null) return true;
        if (p == null or x == null) return false;
        if (p.?[0] == ':') continue;
        if (!std.mem.eql(u8, p.?, x.?)) return false;
    }
}

pub fn routes(c: *const Cx) []const Route {
    return switch (c.mode) {
        .account => &account_routes,
        .org => if (c.isCarrier()) &carrier_routes else &merchant_routes,
        else => &.{},
    };
}

pub fn currentRoute(c: *const Cx) ?Route {
    for (routes(c)) |r| if (matches(r.pattern, c.route())) return r;
    return null;
}

pub fn allowed(c: *const Cx, r: Route) bool {
    if (r.driver) return c.isDriver();
    if (r.direct and !c.directOn()) return false;
    if (r.any.len == 0) return true;
    return c.canAny(r.any);
}

/// The page a member opens on: their main task (`homePath`).
pub fn homePath(c: *const Cx) []const u8 {
    if (c.isDriver()) return "/driver";
    if (c.can("org.settings")) return "/";
    if (c.isCarrier()) {
        if (c.can("dispatch.manage")) return "/dispatch";
        if (c.can("finance.view")) return "/finance";
        if (c.can("hub.scan") and !c.can("shipments.manage")) return "/scan";
        if (c.can("shipments.view")) return "/shipments";
        if (c.can("fleet.view")) return "/fleet";
    } else {
        if (c.can("api.manage") and !c.can("shipments.cancel")) return "/developers";
        if (c.can("shipments.create")) return "/shipments";
        if (c.can("shipments.view")) return "/shipments";
    }
    return "/";
}

// ---- Addresses ----------------------------------------------------------------------------

fn setBase(c: *Cx, base: []const u8) void {
    c.base_len = @min(base.len, c.base.len);
    @memcpy(c.base[0..c.base_len], base[0..c.base_len]);
}

fn setPath(c: *Cx, path: []const u8) void {
    const p = if (path.len == 0) "/" else path;
    c.path_len = @min(p.len, c.path.len);
    @memcpy(c.path[0..c.path_len], p[0..c.path_len]);
}

/// The full address of the current page ("/o/acme/shipments?x=1").
pub fn fullLink(c: *const Cx, a: std.mem.Allocator) []const u8 {
    const p = c.pathStr();
    if (c.base_len == 0) return a.dupe(u8, p) catch p;
    if (std.mem.eql(u8, p, "/")) return std.fmt.allocPrint(a, "{s}/", .{c.baseStr()}) catch p;
    return std.fmt.allocPrint(a, "{s}{s}", .{ c.baseStr(), p }) catch p;
}

fn pushHistory(c: *Cx) void {
    var a = std.heap.ArenaAllocator.init(gpa);
    defer a.deinit();
    const link = fullLink(c, a.allocator());
    if (c.history.items.len > 0 and std.mem.eql(u8, c.history.items[c.history.items.len - 1], link)) return;
    c.history.append(gpa, gpa.dupe(u8, link) catch return) catch {};
    if (c.history.items.len > 40) gpa.free(c.history.orderedRemove(0));
}

/// Opens an address of the app: sets the mode and base, loads what the session needs, then the
/// page. `push` adds a history entry (and a browser history entry on the web).
pub fn openLink(c: *Cx, link_in: []const u8, push: bool) void {
    var buf: [600]u8 = undefined;
    const link = buf[0..@min(link_in.len, buf.len)];
    @memcpy(link, link_in[0..link.len]);
    const path = link[0 .. std.mem.indexOfAny(u8, link, "?#") orelse link.len];
    var org_changed = false;
    if (std.mem.startsWith(u8, path, "/t/") or std.mem.startsWith(u8, path, "/embed/t/")) {
        c.mode = .public_track;
        setBase(c, "");
        setPath(c, link);
    } else if (std.mem.eql(u8, path, "/track")) {
        c.mode = .lookup;
        setBase(c, "");
        setPath(c, link);
    } else if (std.mem.startsWith(u8, path, "/invite/")) {
        c.mode = .invite;
        setBase(c, "/invite");
        setPath(c, link["/invite".len..]);
    } else if (std.mem.startsWith(u8, path, "/o/")) {
        const rest = link[3..];
        const slash = std.mem.indexOfAny(u8, rest, "/?") orelse rest.len;
        var bb: [96]u8 = undefined;
        const base = std.fmt.bufPrint(&bb, "/o/{s}", .{rest[0..slash]}) catch return;
        org_changed = c.mode != .org or !std.mem.eql(u8, base, c.baseStr());
        c.mode = .org;
        setBase(c, base);
        setPath(c, rest[slash..]);
    } else if (std.mem.startsWith(u8, path, "/app") and (path.len == 4 or path[4] == '/')) {
        c.mode = .account;
        setBase(c, "/app");
        setPath(c, link[4..]);
    } else if (zui.platform == .web and (path.len == 0 or std.mem.eql(u8, path, "/"))) {
        c.mode = .landing;
        setBase(c, "");
        setPath(c, "/");
    } else {
        c.mode = .account;
        setBase(c, "/app");
        setPath(c, "/");
    }
    if (push) pushHistory(c);
    syncAddress(c, push);
    if (org_changed) {
        c.org.reset();
        c.alerts_open = 0;
    }
    resumeStart(c);
}

/// Opens a page in `base` (a page of the same area); `push` false replaces the current one.
pub fn navigate(c: *Cx, base: []const u8, path: []const u8, push: bool) void {
    var a = std.heap.ArenaAllocator.init(gpa);
    defer a.deinit();
    const link = if (std.mem.eql(u8, path, "/") and base.len > 0)
        std.fmt.allocPrint(a.allocator(), "{s}/", .{base}) catch return
    else
        std.fmt.allocPrint(a.allocator(), "{s}{s}", .{ base, path }) catch return;
    if (!push and c.history.items.len > 0) gpa.free(c.history.pop().?);
    openLink(c, link, true);
}

/// The address follows: a history entry (the browser's on the web, zui's on the phones, so
/// Back returns here) or in place of the current one.
fn syncAddress(c: *Cx, push: bool) void {
    var a = std.heap.ArenaAllocator.init(gpa);
    defer a.deinit();
    const link = fullLink(c, a.allocator());
    if (push) c.fx.pushLink(link) else c.fx.setLink(link);
}

/// Continues start-up or opens the page, depending on what the session has.
fn resumeStart(c: *Cx) void {
    switch (c.mode) {
        .public_track, .lookup, .landing => return enterPage(c),
        else => {},
    }
    if (core.nativeAuth() and c.token == null) {
        c.mode_before_boot = c.mode;
        c.mode = .signin;
        return enterPage(c);
    }
    if (c.me.state != .ok or c.meta.state != .ok) {
        c.mode_before_boot = c.mode;
        if (c.me.state != .loading) {
            c.me.state = .loading;
            c.meta.state = .loading;
            c.request(.GET, c.staticUrl("/api/app/me"), "", tag(.global, 0, g_me));
            c.request(.GET, c.staticUrl("/api/app/meta"), "", tag(.global, 0, g_meta));
        }
        c.mode = .starting;
        clearPage(c);
        return;
    }
    if (c.mode == .org) {
        if (c.org.state == .ok) return enterPage(c);
        const slug = c.baseStr()[3..];
        var entry: ?json.V = null;
        for (json.arr(c.me.value, "orgs")) |o| if (std.mem.eql(u8, json.str(o, "slug"), slug)) {
            entry = o;
        };
        const e = entry orelse {
            c.mode = .not_member;
            c.not_member_suspended = false;
            return clearPage(c);
        };
        if (!std.mem.eql(u8, json.str(e, "memberStatus"), "active")) {
            c.mode = .not_member;
            c.not_member_suspended = true;
            return clearPage(c);
        }
        if (c.org.state != .loading) {
            c.org.state = .loading;
            var b: [96]u8 = undefined;
            c.request(.GET, c.staticUrl(std.fmt.bufPrint(&b, "/api/app/orgs/{s}", .{json.str(e, "id")}) catch return), "", tag(.global, 0, g_org));
        }
        clearPage(c);
        return;
    }
    enterPage(c);
}

fn clearPage(c: *Cx) void {
    leavePage(c);
    c.page = .{ .none = {} };
}

fn leavePage(c: *Cx) void {
    c.gen +%= 1;
    for (&c.slots) |*s| s.reset();
    c.clearForm();
    c.clearFieldError();
    c.closeConfirm();
    c.picker = null;
    c.closeLive();
    c.menu_open = false;
    c.focused = null;
    c.busy.clearRetainingCapacity();
    c.quiet.clearRetainingCapacity();
    _ = c.page_arena.reset(.retain_capacity);
    gps.want(c, false);
}

/// Enters the page for the current mode and path.
pub fn enterPage(c: *Cx) void {
    leavePage(c);
    c.no_permission = false;
    const id: pages.Id = switch (c.mode) {
        .signin => .signin,
        .landing => .landing,
        .lookup => .lookup,
        .public_track => .public_track,
        .invite => .invite,
        .starting, .failed, .not_member => .none,
        .account, .org => blk: {
            const r = currentRoute(c) orelse break :blk .not_found;
            if (c.mode == .org and std.mem.eql(u8, c.route(), "/")) {
                const home = homePath(c);
                if (!std.mem.eql(u8, home, "/") and (c.first_page or !allowed(c, r))) {
                    c.first_page = false;
                    // Opens on the member's main task, in place of "/".
                    if (c.history.items.len > 0) gpa.free(c.history.pop().?);
                    setPath(c, home);
                    pushHistory(c);
                    syncAddress(c, false);
                    return enterPage(c);
                }
            }
            c.first_page = false;
            if (!allowed(c, r)) {
                c.no_permission = true;
                break :blk .not_found;
            }
            break :blk r.page;
        },
    };
    switch (id) {
        inline else => |tg| {
            if (tg == .none) {
                c.page = .{ .none = {} };
            } else {
                c.page = @unionInit(pages.Page, @tagName(tg), .{});
                const m = @field(pages.mods, @tagName(tg));
                m.enter(&@field(c.page, @tagName(tg)), c);
            }
        },
    }
}

/// Sends an event to the open page.
pub fn pageEvent(c: *Cx, e: core.Ev) void {
    switch (c.page) {
        .none => {},
        inline else => |*s, tg| @field(pages.mods, @tagName(tg)).update(s, c, e),
    }
}

// Global requests.
pub const g_me: u16 = 1;
pub const g_meta: u16 = 2;
pub const g_org: u16 = 3;
pub const g_alerts: u16 = 4;
pub const g_logout: u16 = 5;
pub const g_reload_org: u16 = 6;
// Global timers.
const gt_alerts: u16 = 10;

// ---- Update -------------------------------------------------------------------------------

pub fn update(c: *State, msg: Msg, env: zui.Env, fx: zui.Fx(Msg)) void {
    c.fx = fx;
    c.env = env;
    switch (msg) {
        .boot => start(c),
        .frame => pageEvent(c, .frame),
        .go => |p| c.go(p),
        .link => |l| openLink(c, l, true),
        .back => back(c),
        .act => |a| pageEvent(c, .{ .act = a }),
        .text => |x| {
            const slot = kit.textSlot(x.slot);
            const kind = kit.textKind(x.slot);
            var arena = std.heap.ArenaAllocator.init(gpa);
            defer arena.deinit();
            const a = arena.allocator();
            const value = switch (kind) {
                .number => core.normalizeNumber(a, x.text, false, false),
                .decimal => core.normalizeNumber(a, x.text, true, false),
                .signed => core.normalizeNumber(a, x.text, true, true),
                else => x.text,
            };
            c.setVal(slot, value);
            if (c.field_err != null) c.clearFieldError();
            pageEvent(c, .{ .text = .{ .slot = slot, .text = value } });
        },
        .focus => |s| c.focused = s,
        .blur => |s| if (c.focused == s) {
            c.focused = null;
        },
        .resp => |r| response(c, r),
        .timer => |tm| {
            if (tm.global) return globalTimer(c, tm.id);
            if (tm.gen == c.gen) pageEvent(c, .{ .timer = tm.id });
        },
        .located => |l| {
            gps.located(c, l);
            pageEvent(c, .{ .located = l });
        },
        .map => |p| pageEvent(c, .{ .map = p }),
        .shell => |s| shell.update(c, s),
        .open_picker => |p| {
            _ = c.picker_arena.reset(.retain_capacity);
            const a = c.picker_arena.allocator();
            const opts = a.alloc(core.Opt, p.options.len) catch return;
            for (p.options, 0..) |o, i| opts[i] = .{ .value = a.dupe(u8, o.value) catch "", .label = a.dupe(u8, o.label) catch "" };
            c.picker = .{ .slot = p.slot, .title = a.dupe(u8, p.title) catch "", .options = opts };
            // The platform's own list (a <select>, an Android dialog, an iOS action sheet).
            const names = a.alloc([]const u8, opts.len) catch return;
            var selected: ?u32 = null;
            for (opts, 0..) |o, i| {
                names[i] = o.label;
                if (std.mem.eql(u8, o.value, c.val(p.slot))) selected = @intCast(i);
            }
            fx.pickOption(.{ .title = c.picker.?.title, .options = names, .selected = selected }, onPicked);
        },
        .open_date => |d| {
            c.date_slot = d.slot;
            if (d.time) fx.pickTime(.{ .value = c.val(d.slot) }, onDatePicked) else fx.pickDate(.{ .value = c.val(d.slot), .min = d.min, .max = d.max }, onDatePicked);
        },
        .date_picked => |v| {
            c.setVal(c.date_slot, v);
            if (c.field_err != null) c.clearFieldError();
            pageEvent(c, .{ .text = .{ .slot = c.date_slot, .text = v } });
        },
        .host => |h| host(c, h),
        .socket => |e| pageEvent(c, .{ .socket = e }),
        .scan => |e| pageEvent(c, .{ .scan = e }),
        .copy => |s| c.copy(s),
        .open => |u| c.external(u, true),
        .photo_picked => |f| {
            // The page gets a data: URL, as Turf-js uploaded it.
            var arena = std.heap.ArenaAllocator.init(gpa);
            defer arena.deinit();
            const enc = std.base64.standard.Encoder;
            const prefix = "data:image/jpeg;base64,";
            const data = arena.allocator().alloc(u8, prefix.len + enc.calcSize(f.data.len)) catch return;
            @memcpy(data[0..prefix.len], prefix);
            _ = enc.encode(data[prefix.len..], f.data);
            pageEvent(c, .{ .photo = .{ .id = c.photo_id, .data = data } });
        },
        .file_picked => |f| pageEvent(c, .{ .file = .{ .id = c.file_id, .name = f.name, .data = f.data } }),
        .live => |e| if (e.stream == c.live_stream) {
            c.liveEvent(e);
            pageEvent(c, .{ .live = e });
        },
    }
}

fn start(c: *Cx) void {
    // The saved language, else the device's (the runtime picked it).
    if (zui.storage.get(gpa, "lang", .{})) |l| {
        defer gpa.free(l);
        if (std.mem.eql(u8, l, "ar") or std.mem.eql(u8, l, "en")) zui.i18n.setLanguage(l);
    }
    if (core.nativeAuth()) {
        if (zui.storage.get(gpa, "token", .{ .secure = true })) |tok| c.token = tok;
    }
    const link = if (c.env.link.len > 0) c.env.link else "/app";
    openLink(c, link, true);
}

/// Back: the previous page of this session (the phones' and the in-app back buttons).
pub fn back(c: *Cx) void {
    if (c.history.items.len < 2) return;
    gpa.free(c.history.pop().?);
    const prev = c.history.pop().?;
    defer gpa.free(prev);
    openLink(c, prev, true);
}

fn host(c: *Cx, h: core.Host) void {
    switch (h) {
        .popstate => |link| {
            // The browser's Back: that page, without a new browser history entry.
            if (c.history.items.len > 0) gpa.free(c.history.pop().?);
            openLink(c, link, false);
            pushHistory(c);
        },
        .online => |on| {
            c.online = on;
            if (on) {
                gps.flush(c);
                if (c.mode == .org and c.isDriver()) gps.startOutbox(c);
            }
        },
        .visible => |v| {
            c.visible = v;
            if (c.gps.on) gps.presence(c, if (v) "foreground" else "background");
            if (v) gps.flush(c);
        },
    }
}

fn onDatePicked(v: []const u8) Msg {
    return .{ .date_picked = v };
}

fn onPicked(i: u32) Msg {
    return .{ .shell = .{ .pick = @intCast(i) } };
}

/// Back or forward to an address: the browser's buttons, Android's Back, the iOS swipe.
pub fn linkEvent(link: []const u8) ?Msg {
    return .{ .host = .{ .popstate = link } };
}

/// The connection and the app coming and going (GPS upload, presence).
pub fn deviceEvent(e: zui.DeviceEvent) ?Msg {
    return .{ .host = switch (e) {
        .online => .{ .online = true },
        .offline => .{ .online = false },
        .visible => .{ .visible = true },
        .hidden => .{ .visible = false },
    } };
}

fn globalTimer(c: *Cx, id: u16) void {
    switch (id) {
        gps.timer_flush, gps.timer_outbox => gps.timer(c, id),
        gt_alerts => if (c.mode == .org and c.isCarrier() and c.can("alerts.manage")) {
            pollAlerts(c);
        } else {
            c.alerts_polling = false;
        },
        else => {},
    }
}

fn pollAlerts(c: *Cx) void {
    var b: [128]u8 = undefined;
    c.request(.GET, c.staticUrl(std.fmt.bufPrint(&b, "/api/app/orgs/{s}/carrier/alerts?status=open", .{c.orgId()}) catch return), "", tag(.global, 0, g_alerts));
    c.fx.after(30_000, .{ .timer = .{ .gen = 0, .id = gt_alerts, .global = true } });
}

// ---- Answers ------------------------------------------------------------------------------

fn response(c: *Cx, r: zui.Response) void {
    const kind = core.tagKind(r.tag);
    // Signed out meanwhile: sign in again.
    if (r.status == 401 and c.mode != .signin and kind != .gps and c.mode != .public_track and c.mode != .lookup) return signInAgain(c);
    switch (kind) {
        .gps => gps.response(c, r),
        .global => globalResponse(c, r),
        .slot => {
            if (core.tagGen(r.tag) != (c.gen & 0x3fff)) return;
            const code = core.tagCode(r.tag);
            const n: u8 = @intCast(code >> 11);
            const s = &c.slots[n];
            if ((code & 0x7ff) != s.seq) return; // an older request's answer
            s.reloading = false;
            s.status = r.status;
            if (r.ok()) {
                s.arena.deinit();
                s.arena = .init(gpa);
                s.value = json.parse(s.arena.allocator(), r.body);
                s.state = .ok;
                s.err = "";
            } else {
                var tmp = std.heap.ArenaAllocator.init(gpa);
                defer tmp.deinit();
                const msg = core.errorMessage(tmp.allocator(), r.status, json.parse(tmp.allocator(), r.body), false);
                s.err = c.page_arena.allocator().dupe(u8, msg) catch "";
                if (s.state != .ok) s.state = .failed;
            }
            pageEvent(c, .{ .data = n });
        },
        .act => {
            if (core.tagGen(r.tag) != (c.gen & 0x3fff)) return;
            const id = core.tagCode(r.tag);
            _ = c.busy.remove(id);
            const arg = c.act_args.get(id) orelse 0;
            var tmp = std.heap.ArenaAllocator.init(gpa);
            defer tmp.deinit();
            const v = json.parse(tmp.allocator(), r.body);
            if (!r.ok()) {
                // The field the server named shows the message under it; the toast always.
                if (json.str(v, "error.field").len > 0) {
                    c.clearFieldError();
                    c.field_err = .{ .field = gpa.dupe(u8, json.str(v, "error.field")) catch "", .text = gpa.dupe(u8, core.errorMessage(tmp.allocator(), r.status, v, true)) catch "" };
                }
                if (!c.quiet.contains(id)) c.toast(core.errorMessage(tmp.allocator(), r.status, v, false), .err);
            }
            pageEvent(c, .{ .done = .{ .id = id, .ok = r.ok(), .status = r.status, .v = v, .body = r.body, .arg = arg } });
        },
    }
}

fn globalResponse(c: *Cx, r: zui.Response) void {
    // Signed out meanwhile (the phones' sign-in is showing): the old session's answers are dropped.
    if (c.mode == .signin) switch (core.tagCode(r.tag)) {
        g_me, g_meta, g_org, g_reload_org, g_alerts => return,
        else => {},
    };
    switch (core.tagCode(r.tag)) {
        g_me => fillSession(c, &c.me, r, true),
        g_meta => fillSession(c, &c.meta, r, true),
        g_org => {
            fillSession(c, &c.org, r, false);
            if (c.org.state == .ok) {
                c.mode = .org;
                c.first_page = true;
                startOrgServices(c);
                enterPage(c);
            } else failStart(c, r);
        },
        g_reload_org => if (r.ok()) {
            fillSession(c, &c.org, r, false);
            pageEvent(c, .{ .data = 255 });
        },
        g_alerts => if (r.ok()) alertsAnswer(c, r),
        else => {},
    }
}

/// The open alerts: the badge, and for a new SOS an error toast, the beep and an urgent
/// notification (`wireOrgBadges`).
fn alertsAnswer(c: *Cx, r: zui.Response) void {
    var tmp = std.heap.ArenaAllocator.init(gpa);
    defer tmp.deinit();
    const v = json.parse(tmp.allocator(), r.body);
    var open: u32 = 0;
    for (json.arr(v, "")) |x| {
        if (!std.mem.eql(u8, json.str(x, "status"), "open")) continue;
        open += 1;
        if (!std.mem.eql(u8, json.str(x, "type"), "sos")) continue;
        const h = std.hash.Wyhash.hash(0, json.strOr(x, "id", json.str(x, "_id")));
        if (c.seen_sos.contains(h)) continue;
        c.seen_sos.put(gpa, h, {}) catch {};
        if (!c.alerts_seeded) continue;
        const text = zui.i18n.tf(tmp.allocator(), labels.english("alerts.sos_toast") orelse "SOS: {name}", .{ .name = json.str(x, "courierName") });
        c.toast(text, .err);
        c.fx.beep();
        c.fx.vibrate(300);
        c.fx.notify(.{ .id = 900, .title = labels.k("alerts.type.sos"), .body = text, .urgent = true });
    }
    c.alerts_seeded = true;
    c.alerts_open = open;
}

/// Stores a session answer; once both the account and the platform data are in, continues.
fn fillSession(c: *Cx, s: *core.Slot, r: zui.Response, continue_after: bool) void {
    if (!r.ok()) {
        s.state = .failed;
        if (continue_after) failStart(c, r);
        return;
    }
    s.arena.deinit();
    s.arena = .init(gpa);
    s.value = json.parse(s.arena.allocator(), r.body);
    s.state = if (s.value != null) .ok else .failed;
    if (continue_after and c.me.state == .ok and c.meta.state == .ok and c.mode == .starting) {
        c.mode = c.mode_before_boot;
        resumeStart(c);
    }
}

fn failStart(c: *Cx, r: zui.Response) void {
    if (c.mode == .failed) return;
    var tmp = std.heap.ArenaAllocator.init(gpa);
    defer tmp.deinit();
    const msg = core.errorMessage(tmp.allocator(), r.status, json.parse(tmp.allocator(), r.body), false);
    if (c.fail_text.len > 0) gpa.free(@constCast(c.fail_text));
    c.fail_text = gpa.dupe(u8, msg) catch "";
    if (c.mode != .starting) c.mode_before_boot = c.mode;
    c.mode = .failed;
    c.me.state = .idle;
    c.meta.state = .idle;
    c.org.state = .idle;
    clearPage(c);
}

/// Try again after a failed start.
pub fn retryStart(c: *Cx) void {
    c.mode = c.mode_before_boot;
    resumeStart(c);
}

/// A 401: the web goes to Wufour's sign-in; the phones forget the token and show sign-in.
pub fn signInAgain(c: *Cx) void {
    if (!core.nativeAuth()) {
        var a = std.heap.ArenaAllocator.init(gpa);
        defer a.deinit();
        const next = core.encode(a.allocator(), fullLink(c, a.allocator()));
        const url = std.fmt.allocPrint(a.allocator(), "/auth/login?next={s}", .{next}) catch return;
        c.fx.openUrl(url, false);
        return;
    }
    signOutLocal(c);
}

/// Sign out: the web through the server (`/auth/logout`), the phones here and at Wufour.
pub fn signOut(c: *Cx) void {
    if (!core.nativeAuth()) return c.fx.openUrl("/auth/logout", false);
    if (c.token) |tok| {
        var a = std.heap.ArenaAllocator.init(gpa);
        defer a.deinit();
        var b = json.Obj.init(a.allocator());
        b.str("token", tok);
        const url = std.fmt.allocPrint(a.allocator(), "{s}/api/auth/logout", .{core.auth_base}) catch "";
        c.fx.fetch(.{ .url = url, .method = .POST, .body = b.done(), .tag = tag(.global, 0, g_logout) }, onResp);
    }
    signOutLocal(c);
}

fn onResp(r: zui.Response) Msg {
    return .{ .resp = r };
}

/// The phones: forget the token and the session, show sign-in.
pub fn signOutLocal(c: *Cx) void {
    if (c.token) |tok| gpa.free(tok);
    c.token = null;
    zui.storage.remove("token", .{ .secure = true });
    c.me.reset();
    c.meta.reset();
    c.org.reset();
    gps.stop(c, true);
    c.mode_before_boot = .account;
    setBase(c, "/app");
    setPath(c, "/");
    c.mode = .signin;
    enterPage(c);
}

/// After the in-app sign-in.
pub fn signedIn(c: *Cx, token: []const u8) void {
    zui.storage.set("token", token, .{ .secure = true });
    if (c.token) |old| gpa.free(old);
    c.token = gpa.dupe(u8, token) catch null;
    c.mode = .account;
    openLink(c, "/app", true);
}

/// Company-wide services: the alerts badge (and SOS alarm) for safety staff, the driver's
/// waiting offline actions.
fn startOrgServices(c: *Cx) void {
    if (c.isCarrier() and c.can("alerts.manage") and !c.alerts_polling) {
        c.alerts_polling = true;
        c.alerts_seeded = false;
        pollAlerts(c);
    }
    if (c.isDriver()) gps.startOutbox(c);
}

/// Reloads the company (`ctx.reloadOrg`); the page gets `.data = 255` when it is in.
pub fn reloadOrg(c: *Cx) void {
    var b: [96]u8 = undefined;
    c.request(.GET, c.staticUrl(std.fmt.bufPrint(&b, "/api/app/orgs/{s}", .{c.orgId()}) catch return), "", tag(.global, 0, g_reload_org));
}

// ---- View ---------------------------------------------------------------------------------

pub fn view(c: *const State, ui: *zui.Ui(Msg)) void {
    shell.view(c, ui);
}

// ---- Tests --------------------------------------------------------------------------------

pub const D = zui.host.Driver(@This());
const testing = std.testing;

pub const me_json =
    \\{"user":{"id":"u1","email":"sara@example.com","username":"Sara"},
    \\ "orgs":[{"id":"o1","type":"merchant","name":"Acme Store","slug":"acme","status":"active","branding":{"appName":"Acme Store","primaryColor":"#1d4ed8"},"isOwner":true,"memberStatus":"active","role":null,"isCourier":false},
    \\  {"id":"o2","type":"carrier","name":"Fast Express","slug":"fast","status":"active","branding":{"appName":"Fast Express"},"isOwner":false,"memberStatus":"active","role":"Driver","isCourier":false}],
    \\ "invitations":[]}
;
pub const meta_json =
    \\{"governorates":[{"code":"DAM","en":"Damascus","ar":"دمشق","center":{"lat":33.51,"lng":36.29}}],
    \\ "vehicles":["motorbike","car"],"permissions":{},"statuses":{"awaiting_pickup":{},"delivered":{}},
    \\ "failureReasons":[],"strategies":["balanced"],"taskTypes":["pickup","delivery"],"platform":{"features":{}}}
;

/// Starts the app at `link` and answers the account and platform requests.
pub fn startSignedIn(link: []const u8) !void {
    D.startWith(390, 800, link);
    try testing.expect(D.respond("/api/app/me", 200, me_json));
    try testing.expect(D.respond("/api/app/meta", 200, meta_json));
}

test "the account home lists my companies" {
    try startSignedIn("/app");
    defer D.reset();
    try testing.expect(D.respond("/api/app/me", 200, me_json));
    try testing.expect(D.findText("Acme Store") != 0);
    try testing.expect(D.findText("Fast Express") != 0);
}

test "a 401 on the web sends the user to sign in" {
    D.startWith(390, 800, "/app/track");
    defer D.reset();
    try testing.expect(D.respond("/api/app/me", 401, "{\"error\":{\"code\":\"unauthorized\"}}"));
    try testing.expect(std.mem.startsWith(u8, zui.host.opened.items, "/auth/login?next=%2Fapp%2Ftrack"));
}

test "phones: sign in, keep the token, send it, sign out" {
    core.force_native_auth_runtime = true;
    defer core.force_native_auth_runtime = false;
    zui.storage.remove("token", .{ .secure = true });
    D.startWith(390, 800, "");
    defer D.reset();
    try testing.expect(D.findText("Sign in") != 0);
    try D.typeInto("you@example.com", "sara@example.com");
    // A secure field: the platform hides what is typed.
    try testing.expect(D.inputView("Password").?.input_type.secure);
    try D.typeInto("Password", "pass");
    try D.inputEvent("Password", .submit);
    const login = zui.host.fetches.items[zui.host.fetches.items.len - 1];
    try testing.expect(std.mem.endsWith(u8, login.url, "/api/auth/login"));
    try testing.expect(std.mem.indexOf(u8, login.body, "\"password\":\"pass\"") != null);
    try testing.expect(D.respond("/api/auth/login", 200, "{\"success\":true,\"token\":\"TOK\"}"));
    try testing.expectEqualStrings("TOK", zui.host.stored.get("token").?);
    const me = zui.host.fetches.items[0];
    try testing.expect(std.mem.indexOf(u8, me.headers, "Authorization: Bearer TOK") != null);
    try testing.expect(D.respond("/api/app/me", 200, me_json));
    try testing.expect(D.respond("/api/app/meta", 200, meta_json));
    try testing.expect(D.respond("/api/app/me", 200, me_json));
    try testing.expect(D.findText("Acme Store") != 0);
    D.R.dispatch(.{ .shell = .sign_out });
    try testing.expect(zui.host.stored.get("token") == null);
    try testing.expect(D.findText("Sign in") != 0);
}

test {
    _ = json;
    _ = fmt;
    _ = core;
    _ = labels;
    _ = @import("theme.zig");
    _ = @import("widgets/map.zig");
}

/// Prints every text on screen (debugging tests).
pub fn dump() void {
    var it = zui.host.views.iterator();
    while (it.next()) |e| if (e.value_ptr.kind == .text or e.value_ptr.kind == .input) std.debug.print("[{s}|{s}] ", .{ e.value_ptr.text.items, e.value_ptr.placeholder.items });
    std.debug.print("\n", .{});
}

test "a company opens on the member's main task, and pages need their permission" {
    try startSignedIn("/o/acme/");
    defer D.reset();
    // A store member who may only manage the API opens on Developers.
    try testing.expect(D.respond("/api/app/orgs/o1", 200,
        \\{"id":"o1","type":"merchant","name":"Acme Store","slug":"acme","status":"active","branding":{"appName":"Acme Store"},
        \\ "me":{"memberId":"m1","isOwner":false,"role":{"id":"r","name":"Developer"},"permissions":["api.manage"]}}
    ));
    try testing.expectEqualStrings("/developers", D.R.appState().route());
    try testing.expect(std.mem.endsWith(u8, zui.host.link.items, "/o/acme/developers"));
    // A page without its permission says so instead of failing.
    D.R.dispatch(.{ .go = "/finance" });
    try testing.expect(D.R.appState().no_permission);
    try testing.expect(D.findText("You do not have permission to open this page.") != 0);
}

test "not a member of the company in the address" {
    try startSignedIn("/o/nope/");
    defer D.reset();
    try testing.expect(D.R.appState().mode == .not_member);
    try D.press("All my companies");
    try testing.expect(D.R.appState().mode == .account);
}

test "the language switch turns the layout right to left" {
    try startSignedIn("/app");
    defer D.reset();
    try testing.expect(D.respond("/api/app/me", 200, me_json));
    D.R.dispatch(.{ .shell = .lang });
    try testing.expect(zui.i18n.isRtl());
    try testing.expect(D.findText("شركاتي") != 0);
    D.R.dispatch(.{ .shell = .lang });
    try testing.expect(!zui.i18n.isRtl());
}
