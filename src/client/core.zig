//! The app's core: messages, the session (account, platform data, company), the router, the
//! API client, page data, forms, toasts, dialogs and timers. Turf-js's app.js, core/api.js,
//! core/router.js and the `ctx` object its views receive, in one place.
//!
//! Every page module (src/client/pages/*.zig) has:
//!   pub const S = struct { ... };                       // its own state, with defaults
//!   pub fn enter(s: *S, c: *Cx) void                    // opened: start loading
//!   pub fn update(s: *S, c: *Cx, e: Ev) void            // presses, typing, answers, timers
//!   pub fn view(s: *const S, c: *const Cx, ui: *Ui) void
//! and optionally `title`, `actions` (top bar buttons), `overlay` (its dialogs), `bare`/`full`.
//! Pages talk to the core only through `Cx`, so the message type stays small: a press is an
//! `Act` (a page-chosen id and argument), typing is a `Text` (a form slot), answers come back
//! by data slot or action id.

const std = @import("std");
const zui = @import("zui");
const json = @import("json.zig");
const fmt = @import("fmt.zig");
const theme = @import("theme.zig");

pub const V = json.V;
pub const t = zui.i18n.t;
pub const gpa = zui.allocator;

const config = @import("app_config");

/// Where the API is: the page's own origin on the web, the build's -Dserver on phones.
pub const api_base: []const u8 = if (zui.platform == .web or zui.platform == .headless) "" else config.server;
/// Wufour (accounts): -Dauth.
pub const auth_base: []const u8 = config.auth;
/// Where Wufour sends the phones' in-app sign-in (Turf's /auth/callback on -Dserver, a host
/// Wufour accepts); the app takes the token from that address without loading it.
pub const callback_url: []const u8 = config.server ++ "/auth/callback?next=%2F";
/// Wufour Maps (map tiles): -Dmaps.
pub const maps_base: []const u8 = config.maps;
/// The phones sign in inside the app and send a bearer token; the web uses Wufour's cookies.
pub const native_auth = zui.platform == .android or zui.platform == .ios;
/// Tests of the phone sign-in flow on the build machine.
pub var force_native_auth_runtime = false;

pub fn nativeAuth() bool {
    return native_auth or force_native_auth_runtime;
}

// ---- Messages -----------------------------------------------------------------------------

pub const Act = struct { id: u16, arg: u32 = 0 };
pub const Text = struct { slot: u16, text: []const u8 };
pub const Timer = struct { gen: u32, id: u16, global: bool = false };
pub const Opt = struct { value: []const u8, label: []const u8 };

pub const Shell = union(enum) {
    menu,
    menu_close,
    lang,
    sign_out,
    toast_tap: u32,
    toast_expire: u32,
    confirm_yes,
    confirm_no,
    pick: u16,
    pick_close,
    retry,
    to_all_companies,
    devices,
    sos,
};

pub const Picker = struct { slot: u16, title: []const u8, options: []const Opt };
pub const DateAsk = struct { slot: u16, time: bool = false, min: []const u8 = "", max: []const u8 = "" };

pub const Msg = union(enum) {
    boot,
    frame,
    /// A page inside the current base ("/shipments/abc"); the string lives until dispatch.
    go: []const u8,
    /// Any address of the app ("/o/acme/", "/app", "/t/<token>").
    link: []const u8,
    back,
    act: Act,
    text: Text,
    resp: zui.Response,
    timer: Timer,
    located: zui.Location,
    map: zui.Pointer,
    shell: Shell,
    open_picker: Picker,
    /// Opens the platform's date or time picker for a form slot; the choice comes back as
    /// `date_picked` ("YYYY-MM-DD" or "HH:MM").
    open_date: DateAsk,
    date_picked: []const u8,
    host: Host,
    socket: zui.SocketEvent,
    /// A barcode scanner's event (fx.scanBarcode).
    scan: zui.ScanEvent,
    /// An input got or lost the keyboard (its form slot).
    focus: u16,
    blur: u16,
    /// Copies the text (and says so).
    copy: []const u8,
    /// Opens an address outside the app (tel:, a map app, a document).
    open: []const u8,
    /// A photo (fx.pickPhoto) or a file (fx.pickFile) the user chose, for `photo_id`/`file_id`.
    photo_picked: zui.File,
    file_picked: zui.File,
    /// The page's live events (Server-Sent Events, `Cx.liveEvents`).
    live: zui.ServerEvent,
    /// Push notifications: the token, a push's data (push.zig).
    push: @import("push.zig").Event,
    /// The phones' in-app Wufour sign-in ended (pages/signin.zig).
    web_auth: zui.WebAuthResult,
};

/// What the platform tells the app (zui's linkEvent and deviceEvent).
pub const Host = union(enum) {
    /// Back or forward to an address (the browser's buttons, Android's Back, the iOS swipe).
    popstate: []const u8,
    online: bool,
    visible: bool,
};

pub const Ev = union(enum) {
    act: Act,
    text: Text,
    /// Data slot `n` finished loading (ok or failed: see `Cx.slot`).
    data: u8,
    /// Action `id` finished: `ok`, the parsed answer, and the status (0: no connection).
    done: Done,
    timer: u16,
    located: zui.Location,
    map: zui.Pointer,
    frame,
    photo: struct { id: u16, data: []const u8 },
    file: struct { id: u16, name: []const u8, data: []const u8 },
    socket: zui.SocketEvent,
    /// A barcode scanner's event (fx.scanBarcode).
    scan: zui.ScanEvent,
    /// An event of the page's stream (`Cx.liveEvents`).
    live: zui.ServerEvent,
    /// A field (form slot) got or lost the keyboard.
    focus: u16,
    blur: u16,
    /// The language changed (texts from the server are in the old one).
    lang,
    /// The app came back on screen (true) or went to the background; the network came or went.
    visible: bool,
    online: bool,
};

/// The keys the screen takes now, set while it is drawn (`App.keyEvent` reads them): Escape
/// closes the dialog on top or a list of suggestions, the arrows move in that list. Later
/// views win (a list inside a dialog closes before the dialog).
pub const KeyMap = struct { escape: ?Msg = null, up: ?Msg = null, down: ?Msg = null };
pub var keys: KeyMap = .{};

pub const Done = struct {
    id: u16,
    ok: bool,
    status: u16,
    v: ?V,
    body: []const u8,
    arg: u32 = 0,
};

pub const Ui = zui.Ui(Msg);

// ---- Routes -------------------------------------------------------------------------------

pub const Mode = enum {
    /// Reading the account (spinner).
    starting,
    /// Phones without a token.
    signin,
    /// "/" on the web.
    landing,
    /// "/track": the public tracking search.
    lookup,
    /// "/t/<token>" and "/embed/t/<token>".
    public_track,
    /// "/app/...": my companies, create a company, direct shipping.
    account,
    /// "/o/<slug>/...": a company's console or driver app.
    org,
    /// "/invite/<token>".
    invite,
    /// Could not start (no connection, server error): a retry screen.
    failed,
    /// Not a member of the company in the address, or suspended.
    not_member,
};

// ---- Data slots ---------------------------------------------------------------------------

pub const SlotState = enum { idle, loading, ok, failed };

pub const Slot = struct {
    arena: std.heap.ArenaAllocator = .init(gpa),
    value: ?V = null,
    state: SlotState = .idle,
    /// Loading again while an older value is shown.
    reloading: bool = false,
    status: u16 = 0,
    err: []const u8 = "",
    seq: u16 = 0,
    /// The answer is the service worker's saved copy (offline; `X-Turf-Offline: 1`).
    offline: bool = false,

    pub fn reset(s: *Slot) void {
        s.arena.deinit();
        s.* = .{};
    }
};

pub const max_slots = 16;

pub const Toast = struct {
    id: u32,
    text: []u8,
    kind: Kind,
    pub const Kind = enum { info, ok, err };
};

pub const Confirm = struct {
    text: []u8,
    title: []u8,
    label: []u8,
    danger: bool,
    act: Act,
};

pub const FieldError = struct { field: []u8, text: []u8 };

// ---- The context --------------------------------------------------------------------------

/// The whole app state. Pages receive it as `c`.
pub const Cx = struct {
    fx: zui.Fx(Msg) = undefined,
    env: zui.Env = .{},
    mode: Mode = .starting,
    /// "/app", "/o/<slug>", "/invite", "" (public pages).
    base: [96]u8 = undefined,
    base_len: usize = 0,
    /// The page inside the base, with its query ("/shipments?status=delivered").
    path: [512]u8 = undefined,
    path_len: usize = 0,
    /// Changes at every navigation: answers and timers of a page that was left are dropped.
    gen: u32 = 1,
    history: std.ArrayList([]u8) = .empty,

    // Session.
    token: ?[]u8 = null,
    me: Slot = .{},
    meta: Slot = .{},
    org: Slot = .{},
    boot_pending: u8 = 0,
    alerts_open: u32 = 0,
    online: bool = true,
    visible: bool = true,
    fail_text: []const u8 = "",
    /// The mode to go back to once the session is loaded.
    mode_before_boot: Mode = .account,
    not_member_suspended: bool = false,
    /// The first page of a company opens on the member's main task.
    first_page: bool = false,
    /// The current address is a page the member may not open.
    no_permission: bool = false,
    alerts_polling: bool = false,
    alerts_seeded: bool = false,
    seen_sos: std.AutoHashMapUnmanaged(u64, void) = .empty,
    /// Actions whose failures the page reports itself (no toast).
    quiet: std.AutoHashMapUnmanaged(u16, void) = .empty,
    url_buf: [768]u8 = undefined,

    // The page.
    page: @import("pages.zig").Page = .{ .none = {} },
    page_arena: std.heap.ArenaAllocator = .init(gpa),
    slots: [max_slots]Slot = @splat(.{}),
    form: std.AutoHashMapUnmanaged(u16, std.ArrayList(u8)) = .empty,
    busy: std.AutoHashMapUnmanaged(u16, void) = .empty,
    field_err: ?FieldError = null,
    /// Request data: action id -> argument (rows).
    act_args: std.AutoHashMapUnmanaged(u16, u32) = .empty,

    /// The form slot of the date or time being chosen.
    date_slot: u16 = 0,
    /// Who asked for the photo or file being chosen (the page's id for it).
    photo_id: u16 = 0,
    file_id: u16 = 0,
    /// The page's event stream (0: none), the page timer its events fire (once per burst), the
    /// event names that do, and whether it has connected before (a reconnect reloads too).
    live_stream: u32 = 0,
    live_timer: u16 = 0,
    live_names: []const []const u8 = &.{},
    live_pending: bool = false,
    live_opened: bool = false,

    // Shell.
    menu_open: bool = false,
    toasts: std.ArrayList(Toast) = .empty,
    toast_seq: u32 = 0,
    confirm: ?Confirm = null,
    picker: ?Picker = null,
    picker_arena: std.heap.ArenaAllocator = .init(gpa),
    /// The form slot whose input has the keyboard.
    focused: ?u16 = null,

    // The courier's tracker and outbox (gps.zig); lives across pages.
    gps: @import("gps.zig").Tracker = .{},

    // ---- Address ------------------------------------------------------------------------

    pub fn baseStr(c: *const Cx) []const u8 {
        return c.base[0..c.base_len];
    }

    pub fn pathStr(c: *const Cx) []const u8 {
        return c.path[0..c.path_len];
    }

    /// The path without its query.
    pub fn route(c: *const Cx) []const u8 {
        const p = c.pathStr();
        return p[0 .. std.mem.indexOfScalar(u8, p, '?') orelse p.len];
    }

    /// A query parameter of the current page ("" when missing), decoded into `a`.
    pub fn query(c: *const Cx, a: std.mem.Allocator, name: []const u8) []const u8 {
        return queryOf(a, c.pathStr(), name);
    }

    /// The n-th segment of the route ("/shipments/abc" -> 1 = "abc").
    pub fn param(c: *const Cx, n: usize) []const u8 {
        var it = std.mem.tokenizeScalar(u8, c.route(), '/');
        var i: usize = 0;
        while (it.next()) |seg| : (i += 1) if (i == n) return seg;
        return "";
    }

    // ---- Session --------------------------------------------------------------------------

    pub fn orgV(c: *const Cx) ?V {
        return c.org.value;
    }

    pub fn orgId(c: *const Cx) []const u8 {
        return json.str(c.org.value, "id");
    }

    pub fn orgType(c: *const Cx) []const u8 {
        return json.str(c.org.value, "type");
    }

    pub fn isCarrier(c: *const Cx) bool {
        return std.mem.eql(u8, c.orgType(), "carrier");
    }

    pub fn can(c: *const Cx, perm: []const u8) bool {
        return json.contains(c.org.value, "me.permissions", perm);
    }

    pub fn canAny(c: *const Cx, perms: []const []const u8) bool {
        for (perms) |p| if (c.can(p)) return true;
        return false;
    }

    /// A courier of this carrier who may work (the permission alone is not enough).
    pub fn isDriver(c: *const Cx) bool {
        return c.mode == .org and c.isCarrier() and json.has(c.org.value, "me.courier") and c.can("courier.work");
    }

    pub fn directOn(c: *const Cx) bool {
        return json.boolean(c.meta.value, "platform.features.directShipping");
    }

    pub fn lang(_: *const Cx) []const u8 {
        return zui.i18n.language();
    }

    pub fn ar(_: *const Cx) bool {
        return std.mem.eql(u8, zui.i18n.language(), "ar");
    }

    /// The company's brand (or Turf's), for the colours, the logo and the app name.
    pub fn brand(c: *const Cx) ?V {
        if (c.mode == .org) return json.obj(c.org.value, "branding");
        return null;
    }

    pub fn appName(c: *const Cx) []const u8 {
        return json.strOr(c.brand(), "appName", "Turf");
    }

    pub fn colors(c: *const Cx, dark: bool) theme.Colors {
        var b: theme.Brand = .{};
        if (c.brand()) |br| {
            if (zui.Color.parseHex(json.str(br, "primaryColor"))) |x| b.primary = x else |_| {}
            if (zui.Color.parseHex(json.str(br, "accentColor"))) |x| b.header = x else |_| {}
        }
        return theme.colors(dark, b);
    }

    /// An address from the server ("/o/acme/asset/logo.png") made absolute for the phones.
    pub fn asset(c: *const Cx, a: std.mem.Allocator, url: []const u8) []const u8 {
        _ = c;
        if (url.len == 0 or !std.mem.startsWith(u8, url, "/")) return url;
        if (api_base.len == 0) return url;
        return std.fmt.allocPrint(a, "{s}{s}", .{ api_base, url }) catch url;
    }

    // ---- Requests -----------------------------------------------------------------------

    /// api_base ++ path, in a buffer that lives until the next call (for an immediate request).
    pub fn staticUrl(c: *Cx, path: []const u8) []const u8 {
        return std.fmt.bufPrint(&c.url_buf, "{s}{s}", .{ api_base, path }) catch "";
    }

    /// Failures of action uid=197609(tarek) gid=197609 groups=197609 are not toasted (the page shows them its own way).
    pub fn quietErrors(c: *Cx, id: u16) void {
        c.quiet.put(gpa, id, {}) catch {};
    }

    /// "/api/app<path>".
    pub fn appUrl(c: *Cx, path: []const u8) []const u8 {
        return c.print("{s}/api/app{s}", .{ api_base, path });
    }

    /// "/api/app/orgs/<id><path>".
    pub fn orgUrl(c: *Cx, path: []const u8) []const u8 {
        return c.print("{s}/api/app/orgs/{s}{s}", .{ api_base, c.orgId(), path });
    }

    pub fn publicUrl(c: *Cx, path: []const u8) []const u8 {
        return c.print("{s}/api/public{s}", .{ api_base, path });
    }

    /// Text in the page's memory (lives until the page is left).
    pub fn print(c: *Cx, comptime f: []const u8, args: anytype) []const u8 {
        return std.fmt.allocPrint(c.page_arena.allocator(), f, args) catch "";
    }

    pub fn dupe(c: *Cx, s: []const u8) []const u8 {
        return c.page_arena.allocator().dupe(u8, s) catch "";
    }

    pub fn arena(c: *Cx) std.mem.Allocator {
        return c.page_arena.allocator();
    }

    /// The session's headers (the phones' Bearer token), for requests, event streams and
    /// pictures only the member may see (`ui.imageWith`).
    pub fn headers(c: *const Cx, a: std.mem.Allocator) []const [2][]const u8 {
        if (c.token) |tok| {
            const h = a.alloc([2][]const u8, 2) catch return &.{};
            h[0] = .{ "X-Requested-With", "turf" };
            h[1] = .{ "Authorization", std.fmt.allocPrint(a, "Bearer {s}", .{tok}) catch "" };
            return h;
        }
        const h = a.alloc([2][]const u8, 1) catch return &.{};
        h[0] = .{ "X-Requested-With", "turf" };
        return h;
    }

    pub fn request(c: *Cx, method: zui.Method, url: []const u8, body: []const u8, tg: u32) void {
        var a = std.heap.ArenaAllocator.init(gpa);
        defer a.deinit();
        c.fx.fetch(.{ .url = url, .method = method, .body = body, .headers = c.headers(a.allocator()), .tag = tg }, onResp);
    }

    /// Loads `url` (GET) into data slot `n`; the page gets `.data = n` when it is there.
    pub fn load(c: *Cx, n: u8, url: []const u8) void {
        const s = &c.slots[n];
        s.seq +%= 1;
        s.seq &= 0x7ff;
        if (s.state == .ok) s.reloading = true else s.state = .loading;
        c.request(.GET, url, "", tag(.slot, c.gen, (@as(u16, n) << 11) | s.seq));
    }

    pub fn slot(c: *const Cx, n: u8) *const Slot {
        return &c.slots[n];
    }

    pub fn data(c: *const Cx, n: u8) ?V {
        return c.slots[n].value;
    }

    /// All of the given slots are loaded.
    pub fn ready(c: *const Cx, ns: []const u8) bool {
        for (ns) |n| if (c.slots[n].state != .ok) return false;
        return true;
    }

    /// A write (or a GET whose answer the page handles itself): the page gets `.done` with `id`.
    pub fn send(c: *Cx, id: u16, method: zui.Method, url: []const u8, body: []const u8) void {
        c.sendArg(id, 0, method, url, body);
    }

    pub fn sendArg(c: *Cx, id: u16, arg: u32, method: zui.Method, url: []const u8, body: []const u8) void {
        c.busy.put(gpa, id, {}) catch {};
        c.act_args.put(gpa, id, arg) catch {};
        if (method != .GET) c.clearFieldError();
        c.request(method, url, if (method == .GET) "" else if (body.len == 0) "{}" else body, tag(.act, c.gen, id));
    }

    pub fn isBusy(c: *const Cx, id: u16) bool {
        return c.busy.contains(id);
    }

    pub fn anyBusy(c: *const Cx) bool {
        return c.busy.count() > 0;
    }

    // ---- Form values ----------------------------------------------------------------------

    pub fn val(c: *const Cx, s: u16) []const u8 {
        const v = c.form.get(s) orelse return "";
        return v.items;
    }

    pub fn valTrim(c: *const Cx, s: u16) []const u8 {
        return std.mem.trim(u8, c.val(s), " \t\r\n");
    }

    pub fn setVal(c: *Cx, s: u16, v: []const u8) void {
        const gop = c.form.getOrPut(gpa, s) catch return;
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        gop.value_ptr.clearRetainingCapacity();
        gop.value_ptr.appendSlice(gpa, v) catch {};
    }

    pub fn clearForm(c: *Cx) void {
        var it = c.form.valueIterator();
        while (it.next()) |v| v.deinit(gpa);
        c.form.clearRetainingCapacity();
    }

    /// A number typed in a field (Arabic digits accepted), or null.
    pub fn valNum(c: *const Cx, s: u16) ?f64 {
        const v = c.valTrim(s);
        if (v.len == 0) return null;
        return std.fmt.parseFloat(f64, v) catch null;
    }

    /// Whether the last frame drew a field that shows an error on `field` (Turf-js
    /// `showFieldError` toasts only when no field takes it).
    pub fn fieldShown(field: []const u8) bool {
        for (shown[0..shown_n]) |h| {
            var b: [128]u8 = undefined;
            var cand = fieldPath(field, &b);
            while (true) {
                if (std.hash.Wyhash.hash(0, cand) == h) return true;
                const dot = std.mem.lastIndexOfScalar(u8, cand, '.') orelse break;
                cand = cand[0..dot];
            }
        }
        return false;
    }

    pub fn clearFieldError(c: *Cx) void {
        if (c.field_err) |e| {
            gpa.free(e.field);
            gpa.free(e.text);
        }
        c.field_err = null;
    }

    /// The error to show under the field named `name` (server field paths, as `showFieldError`).
    pub fn fieldError(c: *const Cx, name: []const u8) ?[]const u8 {
        if (name.len == 0) return null;
        // Every field that can show an error asks here while drawn: remembered for `fieldShown`.
        if (shown_n < shown.len) {
            shown[shown_n] = std.hash.Wyhash.hash(0, name);
            shown_n += 1;
        }
        const e = c.field_err orelse return null;
        return if (fieldMatches(e.field, name)) e.text else null;
    }

    // ---- Navigation -----------------------------------------------------------------------

    /// Opens a page of the current base.
    pub fn go(c: *Cx, path: []const u8) void {
        c.navigate(c.baseStr(), path, true);
    }

    /// Replaces the current page (redirects).
    pub fn replace(c: *Cx, path: []const u8) void {
        c.navigate(c.baseStr(), path, false);
    }

    /// Opens any address of the app; a different base (another company, the account) reloads
    /// the session part it needs.
    pub fn openLink(c: *Cx, link: []const u8) void {
        @import("app.zig").openLink(c, link, true);
    }

    pub fn navigate(c: *Cx, base: []const u8, path: []const u8, push: bool) void {
        @import("app.zig").navigate(c, base, path, push);
    }

    /// An address outside the app (sign-out, Wufour, a phone call, a map app).
    pub fn external(c: *Cx, url: []const u8, new_window: bool) void {
        c.fx.openUrl(url, new_window);
    }

    // ---- Feedback -------------------------------------------------------------------------

    pub fn toast(c: *Cx, text: []const u8, kind: Toast.Kind) void {
        // The same message again restarts its timer instead of stacking a copy.
        for (c.toasts.items) |*x| if (x.kind == kind and std.mem.eql(u8, x.text, text)) {
            c.toast_seq +%= 1;
            x.id = c.toast_seq;
            c.fx.after(if (kind == .err) 6000 else 3500, .{ .shell = .{ .toast_expire = x.id } });
            return;
        };
        const owned = gpa.dupe(u8, text) catch return;
        c.toast_seq +%= 1;
        c.toasts.append(gpa, .{ .id = c.toast_seq, .text = owned, .kind = kind }) catch return gpa.free(owned);
        while (c.toasts.items.len > 3) {
            const old = c.toasts.orderedRemove(0);
            gpa.free(old.text);
        }
        c.fx.after(if (kind == .err) 6000 else 3500, .{ .shell = .{ .toast_expire = c.toast_seq } });
    }

    /// Asks "Are you sure?"; Confirm sends the page `act`.
    pub fn ask(c: *Cx, text: []const u8, o: struct { title: ?[]const u8 = null, label: ?[]const u8 = null, danger: bool = false, act: Act }) void {
        c.closeConfirm();
        c.confirm = .{
            .text = gpa.dupe(u8, text) catch return,
            .title = gpa.dupe(u8, o.title orelse t("Are you sure?")) catch return,
            .label = gpa.dupe(u8, o.label orelse t("Confirm")) catch return,
            .danger = o.danger,
            .act = o.act,
        };
    }

    pub fn closeConfirm(c: *Cx) void {
        if (c.confirm) |x| {
            gpa.free(x.text);
            gpa.free(x.title);
            gpa.free(x.label);
        }
        c.confirm = null;
    }

    /// The page gets `.timer = id` after `ms`, unless it was left meanwhile.
    pub fn after(c: *Cx, ms: u32, id: u16) void {
        c.fx.after(ms, .{ .timer = .{ .gen = c.gen, .id = id } });
    }

    /// The error text of a failed answer, in the user's language (`errorMessage` in ui.js).
    pub fn errorText(c: *Cx, status: u16, v: ?V) []const u8 {
        return errorMessage(c.page_arena.allocator(), status, v, false);
    }

    /// Copies `text` and says so.
    pub fn copy(c: *Cx, text: []const u8) void {
        c.fx.copy(text);
        c.toast(t("Copied"), .ok);
    }

    /// A photo from the camera (or the gallery), shrunk to a JPEG of at most 1280 points a
    /// side; it arrives as the page's `.photo` event (a data: URL) with `id`.
    pub fn pickPhoto(c: *Cx, id: u16) void {
        c.photo_id = id;
        c.fx.pickPhoto(.{ .camera = true, .max_size = 1280, .quality = 70 }, onPhoto);
    }

    /// A picture from the gallery as PNG (transparency kept), at most `max_size` a side; it
    /// arrives as the page's `.file` event with `id` (a logo).
    pub fn pickPng(c: *Cx, id: u16, max_size: u32) void {
        c.file_id = id;
        c.fx.pickPhoto(.{ .max_size = max_size, .format = .png }, onFile);
    }

    /// A file (`accept`: MIME types and extensions); it arrives as the page's `.file` event.
    pub fn pickFile(c: *Cx, id: u16, accept: []const u8) void {
        c.file_id = id;
        c.fx.pickFile(.{ .accept = accept }, onFile);
    }

    /// Offers a file the app made: a download on the web, Downloads and the share sheet on the
    /// phones.
    pub fn saveFile(c: *Cx, name: []const u8, mime: []const u8, bytes: []const u8) void {
        c.fx.saveFile(.{ .name = name, .mime = mime, .data = bytes, .share = zui.platform != .web });
    }

    /// The page follows the company's live events (Turf-js core/live.js): one of `names`
    /// fires the page's timer `timer` (its reload) once per burst, as does connecting again.
    pub fn orgLive(c: *Cx, timer: u16, names: []const []const u8) void {
        c.liveAt(c.print("/api/app/orgs/{s}/stream", .{c.orgId()}), timer, names);
    }

    /// `orgLive` for another stream (the public tracking page's).
    pub fn liveAt(c: *Cx, path: []const u8, timer: u16, names: []const []const u8) void {
        c.liveEvents(path);
        c.live_timer = timer;
        c.live_names = names;
    }

    /// The page's timer fired by live events has run: the next event may fire it again.
    pub fn liveDone(c: *Cx) void {
        c.live_pending = false;
    }

    /// A live event: fires the page's timer when it is one the page wants.
    pub fn liveEvent(c: *Cx, e: zui.ServerEvent) void {
        const hit = switch (e.kind) {
            .open => blk: {
                const again = c.live_opened;
                c.live_opened = true;
                break :blk again;
            },
            .message => for (c.live_names) |n| {
                if (std.mem.eql(u8, n, e.event)) break true;
            } else false,
            .failed, .closed => false,
        };
        if (!hit or c.live_pending or c.live_timer == 0) return;
        c.live_pending = true;
        c.after(400, c.live_timer);
    }

    /// Follows the page's Server-Sent Events at `path` (with the session); they arrive as the
    /// page's `.live` event. One stream at a time; leaving the page closes it.
    pub fn liveEvents(c: *Cx, path: []const u8) void {
        c.closeLive();
        var a = std.heap.ArenaAllocator.init(gpa);
        defer a.deinit();
        c.live_stream = c.fx.openEvents(.{ .url = c.staticUrl(path), .headers = c.headers(a.allocator()) }, onLive);
    }

    pub fn closeLive(c: *Cx) void {
        if (c.live_stream != 0) c.fx.closeEvents(c.live_stream);
        c.live_stream = 0;
        c.live_timer = 0;
        c.live_names = &.{};
        c.live_pending = false;
        c.live_opened = false;
    }

    /// Web: a request to the page around the app (shells/web/index.html): printing, the title.
    pub fn post(c: *Cx, comptime f: []const u8, args: anytype) void {
        if (zui.platform != .web and zui.platform != .headless) return;
        var buf: [4096]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, f, args) catch return;
        c.fx.post(s);
    }
};

fn onPhoto(f: zui.File) Msg {
    return .{ .photo_picked = f };
}

fn onFile(f: zui.File) Msg {
    return .{ .file_picked = f };
}

fn onLive(e: zui.ServerEvent) Msg {
    return .{ .live = e };
}

/// Request tags: kind (2 bits), page generation (14 bits), code (16 bits).
pub const TagKind = enum(u2) { slot = 0, act = 1, global = 2, gps = 3 };

pub fn tag(kind: TagKind, gen: u32, code: u16) u32 {
    return (@as(u32, @intFromEnum(kind)) << 30) | ((gen & 0x3fff) << 16) | code;
}

pub fn tagKind(tg: u32) TagKind {
    return @enumFromInt(tg >> 30);
}
pub fn tagGen(tg: u32) u32 {
    return (tg >> 16) & 0x3fff;
}
pub fn tagCode(tg: u32) u16 {
    return @truncate(tg);
}

fn onResp(r: zui.Response) Msg {
    return .{ .resp = r };
}

// ---- Errors -------------------------------------------------------------------------------

/// The server's `{ error: { code, message, field, rule, params } }` in the user's language:
/// known validation rules and error codes are translated (by their English text), others show
/// the server's sentence; no connection says so.
pub fn errorMessage(a: std.mem.Allocator, status: u16, v: ?V, under_field: bool) []const u8 {
    if (status == 0) return t("No connection. Check your internet and try again.");
    const e = json.obj(v, "error") orelse {
        if (status == 429) return t("Too many requests. Please wait a moment.");
        return t("Something went wrong on our side. Please try again.");
    };
    const code = json.str(e, "code");
    const message = json.str(e, "message");
    const rule = json.str(e, "rule");
    const field = json.str(e, "field");
    const errors = @import("labels.zig");
    if (std.mem.eql(u8, code, "invalid_request") and rule.len > 0) {
        if (errors.rule(rule)) |english| {
            const msg = fill(a, t(english), json.get(e, "params"));
            if (under_field or field.len == 0) return msg;
            return std.fmt.allocPrint(a, "{s} ({s})", .{ msg, field }) catch msg;
        }
    }
    if (errors.code(code)) |english| {
        if (std.mem.eql(u8, code, "conflict") and !std.mem.eql(u8, zui.i18n.language(), "ar") and message.len > 0) return message;
        return fill(a, t(english), json.get(e, "params"));
    }
    if (message.len > 0) return message;
    return t("Something went wrong. Please try again.");
}

/// Fills `{name}` placeholders from a JSON object (statuses are translated).
pub fn fill(a: std.mem.Allocator, template: []const u8, params: ?V) []const u8 {
    const p = params orelse return template;
    if (p != .object) return template;
    var s: []const u8 = template;
    var it = p.object.iterator();
    while (it.next()) |kv| {
        var value = json.text(a, kv.value_ptr.*, "");
        if (std.mem.eql(u8, kv.key_ptr.*, "status")) value = @import("labels.zig").status(value);
        const needle = std.fmt.allocPrint(a, "{{{s}}}", .{kv.key_ptr.*}) catch continue;
        s = std.mem.replaceOwned(u8, a, s, needle, value) catch s;
    }
    return s;
}

// ---- Small helpers ------------------------------------------------------------------------

pub fn queryOf(a: std.mem.Allocator, link: []const u8, name: []const u8) []const u8 {
    const q = link[(std.mem.indexOfScalar(u8, link, '?') orelse return "") + 1 ..];
    var it = std.mem.tokenizeScalar(u8, q, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        if (!std.mem.eql(u8, pair[0..eq], name)) continue;
        return decode(a, if (eq < pair.len) pair[eq + 1 ..] else "");
    }
    return "";
}

pub fn decode(a: std.mem.Allocator, s: []const u8) []const u8 {
    var out = a.alloc(u8, s.len) catch return s;
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (n += 1) {
        if (s[i] == '%' and i + 2 < s.len + 0 and i + 2 <= s.len - 1) {
            if (std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16)) |b| {
                out[n] = b;
                i += 3;
                continue;
            } else |_| {}
        }
        out[n] = if (s[i] == '+') ' ' else s[i];
        i += 1;
    }
    return out[0..n];
}

/// Percent-encoding for query values.
pub fn encode(a: std.mem.Allocator, s: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '~') {
            out.append(a, ch) catch {};
        } else {
            out.print(a, "%{X:0>2}", .{ch}) catch {};
        }
    }
    return out.items;
}

/// Arabic-Indic and Persian digits and the Arabic decimal mark as ASCII (`normalizeNumber`).
pub fn normalizeNumber(a: std.mem.Allocator, s: []const u8, decimals: bool, negative: bool) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var view = std.unicode.Utf8View.init(s) catch return s;
    var it = view.iterator();
    var dot = false;
    while (it.nextCodepoint()) |cp| {
        var ch: ?u8 = null;
        if (cp >= '0' and cp <= '9') ch = @intCast(cp) else if (cp >= 0x660 and cp <= 0x669) ch = @intCast('0' + (cp - 0x660)) else if (cp >= 0x6f0 and cp <= 0x6f9) ch = @intCast('0' + (cp - 0x6f0)) else if (cp == '.' or cp == ',' or cp == 0x66b) ch = '.' else if (cp == '-' and negative and out.items.len == 0) ch = '-';
        const x = ch orelse continue;
        if (x == '.') {
            if (!decimals or dot) continue;
            dot = true;
        }
        out.append(a, x) catch {};
    }
    return out.items;
}

test "query and number helpers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("a b/c", queryOf(a, "/x?q=a+b%2Fc&n=1", "q"));
    try std.testing.expectEqualStrings("", queryOf(a, "/x?q=1", "z"));
    try std.testing.expectEqualStrings("12.5", normalizeNumber(a, "١٢٫٥", true, false));
    try std.testing.expectEqualStrings("125", normalizeNumber(a, "1.2.5", false, false));
}

/// Fields drawn in the last frame that can show a server error (hashes of their names).
pub var shown: [160]u64 = undefined;
pub var shown_n: usize = 0;

/// "dropoff.phone" or "positions[0].x" as a path without indexes ("positions.x").
fn fieldPath(field: []const u8, buf: *[128]u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < field.len and n < buf.len) : (i += 1) {
        if (field[i] == '[') {
            while (i < field.len and field[i] != ']') i += 1;
            continue;
        }
        buf[n] = field[i];
        n += 1;
    }
    return buf[0..n];
}

/// The server's field path matches the field `name`, or one of its shorter prefixes does.
fn fieldMatches(field: []const u8, name: []const u8) bool {
    var b: [128]u8 = undefined;
    var cand = fieldPath(field, &b);
    while (true) {
        if (std.mem.eql(u8, cand, name)) return true;
        const dot = std.mem.lastIndexOfScalar(u8, cand, '.') orelse return false;
        cand = cand[0..dot];
    }
}
