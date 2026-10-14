//! Push notifications: once the account is loaded the device registers (zui fx.registerPush:
//! FCM on Android, APNs on iOS, a Web Push subscription in the browser) and its token goes to
//! POST /api/app/push/subscribe. The server pushes dispatch alarms, SOS and "tracking paused"
//! as urgent data messages: they reach `message` even when the app is closed (zui starts it
//! without a screen) and ring like the live alarm does (pages/driver.zig `announce`).
//! Tapping the notification opens the app; the address the push carried is opened then.

const std = @import("std");
const zui = @import("zui");
const core = @import("core.zig");
const json = @import("json.zig");

const Cx = core.Cx;
const gpa = core.gpa;

pub const Event = union(enum) {
    token: struct { token: []const u8, kind: zui.PushKind },
    message: []const u8,
    /// The web: GET /push/key answered (the VAPID public key).
    key: zui.Response,
    sent: zui.Response,
};

/// The alarm ids the app already uses for these (a push replaces the live one, not doubles it).
const task_alarm: u32 = 901; // pages/driver.zig alarm_id
const sos_alarm: u32 = 900;
const shift_alarm: u32 = 902;

/// The address of the last push the user has not opened yet ("/o/<slug>/driver/task/<id>").
var pending: ?[]u8 = null;

/// After sign-in, when the account is there.
pub fn register(c: *Cx) void {
    if (zui.platform == .web) {
        var a = std.heap.ArenaAllocator.init(gpa);
        defer a.deinit();
        c.fx.fetch(.{ .url = c.appUrl("/push/key"), .headers = c.headers(a.allocator()) }, onKey);
    } else c.fx.registerPush(.{});
}

fn onKey(r: zui.Response) core.Msg {
    return .{ .push = .{ .key = r } };
}

fn onSent(r: zui.Response) core.Msg {
    return .{ .push = .{ .sent = r } };
}

pub fn update(c: *Cx, e: Event) void {
    switch (e) {
        .key => |r| {
            if (!r.ok()) return;
            var a = std.heap.ArenaAllocator.init(gpa);
            defer a.deinit();
            const key = json.str(json.parse(a.allocator(), r.body), "publicKey");
            if (key.len > 0) c.fx.registerPush(.{ .web_key = key });
        },
        .token => |tk| send(c, tk.token, tk.kind),
        .message => |body| message(c, body),
        .sent => |r| if (!r.ok()) zui.log("push: subscribe answered {d}", .{r.status}),
    }
}

fn send(c: *Cx, token: []const u8, kind: zui.PushKind) void {
    zui.log("push token ({t}): {s}", .{ kind, token });
    if (c.token == null and zui.platform != .web) return; // signed out meanwhile
    var a = std.heap.ArenaAllocator.init(gpa);
    defer a.deinit();
    var b = json.Obj.init(a.allocator());
    if (kind == .web) {
        b.raw("subscription", token);
    } else {
        b.str("token", token);
        b.str("kind", @tagName(kind));
    }
    c.fx.fetch(.{ .url = c.appUrl("/push/subscribe"), .method = .POST, .body = b.done(), .content_type = "application/json", .headers = c.headers(a.allocator()) }, onSent);
}

/// A push's data: { kind, title, body, url, tag, urgent }.
fn message(c: *Cx, body: []const u8) void {
    var a = std.heap.ArenaAllocator.init(gpa);
    defer a.deinit();
    const v = json.parse(a.allocator(), body) orelse return;
    const kind = json.str(v, "kind");
    const title = json.str(v, "title");
    if (title.len == 0) return;
    const id: u32 = if (std.mem.eql(u8, kind, "task")) task_alarm else if (std.mem.eql(u8, kind, "sos")) sos_alarm else if (std.mem.eql(u8, kind, "resume")) shift_alarm else 903;
    const urgent = std.mem.eql(u8, json.str(v, "urgent"), "1") or std.mem.eql(u8, json.str(v, "urgent"), "true");
    c.fx.notify(.{ .id = id, .title = title, .body = json.str(v, "body"), .urgent = urgent });
    if (urgent) c.fx.vibrate(800);
    const url = json.str(v, "url");
    if (url.len > 0 and url[0] == '/') {
        if (pending) |p| gpa.free(p);
        pending = gpa.dupe(u8, url) catch null;
    }
}

/// The address a push carried, once: the app opens it when the user comes back to it.
pub fn takePending() ?[]u8 {
    const p = pending orelse return null;
    pending = null;
    return p;
}

pub fn pushToken(token: []const u8, kind: zui.PushKind) ?core.Msg {
    return .{ .push = .{ .token = .{ .token = token, .kind = kind } } };
}

pub fn pushMessage(body: []const u8) ?core.Msg {
    return .{ .push = .{ .message = body } };
}
