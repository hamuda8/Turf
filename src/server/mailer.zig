//! Minimal SMTP client (src/mailer.js): one email over an encrypted connection, with std only.
//! SMTP_PORT 465 = TLS from the start, 587 = STARTTLS. Without SMTP_HOST emails are printed to
//! the log instead; under NODE_ENV=test they are kept in `outbox` for the tests to read.

const std = @import("std");
const Io = std.Io;
const val = @import("lib/val.zig");
const a_ = @import("app.zig");
const auth = @import("auth.zig");
const Allocator = std.mem.Allocator;

pub const Mail = struct { to: []const u8, subject: []const u8, text: []const u8, html: ?[]const u8 = null };

var outbox_lock: Io.Mutex = .init;
/// Emails "sent" in test mode, as typed JSON lines (gpa).
var outbox: std.ArrayList([]u8) = .empty;

pub fn mailConfigured() bool {
    return a_.cfg().smtp.host.len > 0;
}

/// The test outbox as a JSON array ([{ to, subject, text, html }]).
pub fn outboxJson(a: Allocator) ![]const u8 {
    outbox_lock.lockUncancelable(a_.app.io);
    defer outbox_lock.unlock(a_.app.io);
    var out: std.ArrayList(u8) = .empty;
    try out.append(a, '[');
    for (outbox.items, 0..) |m, i| {
        if (i > 0) try out.append(a, ',');
        try out.appendSlice(a, m);
    }
    try out.append(a, ']');
    return out.items;
}

pub fn clearOutbox() void {
    outbox_lock.lockUncancelable(a_.app.io);
    defer outbox_lock.unlock(a_.app.io);
    for (outbox.items) |m| a_.app.gpa.free(m);
    outbox.clearRetainingCapacity();
}

fn oneLine(a: Allocator, v: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var in_break = false;
    for (v) |c| {
        if (c == '\r' or c == '\n') {
            if (!in_break) try out.append(a, ' ');
            in_break = true;
        } else {
            try out.append(a, c);
            in_break = false;
        }
    }
    return val.jsTrim(out.items);
}

fn addressOf(from: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, from, '<')) |i| if (std.mem.indexOfScalarPos(u8, from, i, '>')) |j| return std.mem.trim(u8, from[i + 1 .. j], " ");
    return std.mem.trim(u8, from, " ");
}

fn encodeHeader(a: Allocator, v: []const u8) ![]const u8 {
    for (v) |c| if (c < 0x20 or c > 0x7e) {
        const b = try a.alloc(u8, std.base64.standard.Encoder.calcSize(v.len));
        return std.fmt.allocPrint(a, "=?UTF-8?B?{s}?=", .{std.base64.standard.Encoder.encode(b, v)});
    };
    return v;
}

fn formatFrom(a: Allocator, from: []const u8) ![]const u8 {
    const lt = std.mem.lastIndexOfScalar(u8, from, '<') orelse return from;
    const rest = std.mem.trimEnd(u8, from[lt..], " ");
    if (!std.mem.endsWith(u8, rest, ">")) return from;
    var name = std.mem.trim(u8, from[0..lt], " ");
    if (name.len >= 1 and name[0] == '"') name = name[1..];
    if (name.len >= 1 and name[name.len - 1] == '"') name = name[0 .. name.len - 1];
    return std.fmt.allocPrint(a, "{s} <{s}>", .{ try encodeHeader(a, name), std.mem.trim(u8, rest[1 .. rest.len - 1], " ") });
}

fn base64Lines(a: Allocator, s: []const u8) ![]const u8 {
    const b = try a.alloc(u8, std.base64.standard.Encoder.calcSize(s.len));
    const enc = std.base64.standard.Encoder.encode(b, s);
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < enc.len) : (i += 76) {
        try out.appendSlice(a, enc[i..@min(i + 76, enc.len)]);
        try out.appendSlice(a, "\r\n");
    }
    return out.items;
}

fn randomHex(a: Allocator, comptime n: usize) ![]const u8 {
    var b: [n]u8 = undefined;
    a_.random(&b);
    return a.dupe(u8, &std.fmt.bytesToHex(b, .lower));
}

fn buildMessage(a: Allocator, from: []const u8, m: Mail) ![]const u8 {
    const boundary = try std.fmt.allocPrint(a, "turf-{s}", .{try randomHex(a, 12)});
    const addr = addressOf(from);
    const domain = if (std.mem.indexOfScalar(u8, addr, '@')) |i| addr[i + 1 ..] else "localhost";
    const part = struct {
        fn f(al: Allocator, bnd: []const u8, ty: []const u8, body: []const u8) ![]const u8 {
            return std.fmt.allocPrint(al, "--{s}\r\nContent-Type: {s}; charset=UTF-8\r\nContent-Transfer-Encoding: base64\r\n\r\n{s}", .{ bnd, ty, try base64Lines(al, body) });
        }
    }.f;
    return std.fmt.allocPrint(a, "From: {s}\r\nTo: {s}\r\nSubject: {s}\r\nDate: {s}\r\nMessage-ID: <{s}@{s}>\r\nMIME-Version: 1.0\r\nContent-Type: multipart/alternative; boundary=\"{s}\"\r\n\r\n{s}\r\n{s}\r\n--{s}--\r\n", .{
        try formatFrom(a, from),                                                                   m.to, try encodeHeader(a, m.subject), auth.httpDate(a, a_.nowMs()), try randomHex(a, 16), domain, boundary,
        try part(a, boundary, "text/plain", m.text), try part(a, boundary, "text/html", m.html orelse m.text), boundary,
    });
}

fn validRecipient(to: []const u8) bool {
    const at = std.mem.indexOfScalar(u8, to, '@') orelse return false;
    if (at == 0 or at == to.len - 1) return false;
    if (std.mem.lastIndexOfScalar(u8, to, '@') != at) return false;
    for (to) |c| if (std.ascii.isWhitespace(c) or c == '<' or c == '>') return false;
    return true;
}

/// Sends one email (or logs / keeps it when SMTP is not set up).
pub fn sendMail(a: Allocator, mail: Mail) !void {
    const m: Mail = .{ .to = try oneLine(a, mail.to), .subject = try oneLine(a, mail.subject), .text = mail.text, .html = mail.html };
    if (!validRecipient(m.to)) return error.InvalidRecipient;
    const c = a_.cfg().smtp;
    if (c.host.len == 0) {
        if (a_.cfg().is_test) {
            const j = try val.toJson(a, try val.from(a, .{ .to = m.to, .subject = m.subject, .text = m.text, .html = m.html }));
            outbox_lock.lockUncancelable(a_.app.io);
            defer outbox_lock.unlock(a_.app.io);
            try outbox.append(a_.app.gpa, try a_.app.gpa.dupe(u8, j));
        } else std.log.info("\n[email not sent: SMTP_HOST is not set]\nTo: {s}\nSubject: {s}\n\n{s}\n", .{ m.to, m.subject, m.text });
        return;
    }
    // The whole conversation gets 60 s (Turf-js: 20 s of socket inactivity).
    const U = union(enum) { done: anyerror!void, slept: void };
    var buf: [2]U = undefined;
    var sel = Io.Select(U).init(a_.app.io, &buf);
    const Run = struct {
        fn f(al: Allocator, mm: Mail) anyerror!void {
            return converse(al, mm);
        }
        fn sleep() void {
            a_.app.io.sleep(.fromSeconds(60), .awake) catch {};
        }
    };
    sel.concurrent(.done, Run.f, .{ a, m }) catch return converse(a, m);
    sel.concurrent(.slept, Run.sleep, .{}) catch {};
    const first = sel.await() catch |e| {
        sel.cancelDiscard();
        return e;
    };
    sel.cancelDiscard();
    return switch (first) {
        .done => |r| r,
        .slept => error.SmtpTimeout,
    };
}

const Line = struct {
    in: *Io.Reader,
    out: *Io.Writer,
    /// Flushed after writes (the TLS layer's ciphertext writer under it).
    under: ?*Io.Writer = null,

    const Reply = struct { code: u16, text: []const u8 };

    fn read(l: Line, a: Allocator) !Reply {
        var all: std.ArrayList(u8) = .empty;
        while (true) {
            const line = l.in.takeDelimiterInclusive('\n') catch return error.SmtpConnectionClosed;
            const t = std.mem.trimEnd(u8, line, "\r\n");
            if (all.items.len > 0) try all.appendSlice(a, " | ");
            try all.appendSlice(a, t);
            // The last line of a reply has a space after the code ("250 OK"), others a dash.
            if (t.len == 3 or (t.len > 3 and t[3] == ' ')) {
                const code = std.fmt.parseInt(u16, t[0..3], 10) catch return error.SmtpBadReply;
                return .{ .code = code, .text = all.items };
            }
        }
    }

    fn cmd(l: Line, a: Allocator, line: []const u8, expect: []const u16) !Reply {
        try l.out.writeAll(line);
        try l.out.writeAll("\r\n");
        try l.out.flush();
        if (l.under) |u| try u.flush();
        const r = try l.read(a);
        for (expect) |e| if (e == r.code) return r;
        const verb = line[0 .. std.mem.indexOfScalar(u8, line, ' ') orelse line.len];
        std.log.err("SMTP {s} failed: {s}", .{ if (verb.len > 20) "DATA" else verb, r.text });
        return error.SmtpCommandFailed;
    }
};

fn converse(a: Allocator, m: Mail) !void {
    const io = a_.app.io;
    const c = a_.cfg().smtp;
    const host = try Io.net.HostName.init(c.host);
    var stream = try host.connect(io, c.port, .{ .mode = .stream });
    defer stream.close(io);
    var rbuf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined;
    var wbuf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined;
    var sr = stream.reader(io, &rbuf);
    var sw = stream.writer(io, &wbuf);

    var tls_rbuf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined;
    var tls_wbuf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined;
    var tls_client: std.crypto.tls.Client = undefined;
    var l: Line = .{ .in = &sr.interface, .out = &sw.interface };

    if (c.secure) {
        tls_client = try startTls(&sr.interface, &sw.interface, &tls_rbuf, &tls_wbuf);
        l = .{ .in = &tls_client.reader, .out = &tls_client.writer, .under = &sw.interface };
    }
    const greeting = try l.read(a);
    if (greeting.code != 220) return error.SmtpGreeting;
    const hello = "EHLO localhost";
    var ehlo = try l.cmd(a, hello, &.{250});
    if (!c.secure) {
        if (std.ascii.findIgnoreCase(ehlo.text, "STARTTLS") != null) {
            _ = try l.cmd(a, "STARTTLS", &.{220});
            tls_client = try startTls(&sr.interface, &sw.interface, &tls_rbuf, &tls_wbuf);
            l = .{ .in = &tls_client.reader, .out = &tls_client.writer, .under = &sw.interface };
            ehlo = try l.cmd(a, hello, &.{250});
        } else if (!c.allow_insecure) {
            std.log.err("The mail server does not offer encryption (STARTTLS); refusing to send the password over plain text", .{});
            return error.SmtpNoEncryption;
        }
    }
    if (c.user.len > 0) {
        const auth_line = ehlo.text[(std.ascii.findIgnoreCase(ehlo.text, "AUTH") orelse ehlo.text.len)..];
        const has_plain = std.ascii.findIgnoreCase(auth_line, "PLAIN") != null;
        const has_login = std.ascii.findIgnoreCase(auth_line, "LOGIN") != null;
        const E = std.base64.standard.Encoder;
        if (has_plain or !has_login) {
            const raw = try std.fmt.allocPrint(a, "\x00{s}\x00{s}", .{ c.user, c.pass });
            const b = try a.alloc(u8, E.calcSize(raw.len));
            _ = try l.cmd(a, try std.fmt.allocPrint(a, "AUTH PLAIN {s}", .{E.encode(b, raw)}), &.{235});
        } else {
            _ = try l.cmd(a, "AUTH LOGIN", &.{334});
            const u = try a.alloc(u8, E.calcSize(c.user.len));
            _ = try l.cmd(a, E.encode(u, c.user), &.{334});
            const p = try a.alloc(u8, E.calcSize(c.pass.len));
            _ = try l.cmd(a, E.encode(p, c.pass), &.{235});
        }
    }
    _ = try l.cmd(a, try std.fmt.allocPrint(a, "MAIL FROM:<{s}>", .{addressOf(c.from)}), &.{250});
    _ = try l.cmd(a, try std.fmt.allocPrint(a, "RCPT TO:<{s}>", .{m.to}), &.{ 250, 251 });
    _ = try l.cmd(a, "DATA", &.{354});
    // Dot-stuffing: a line starting with "." gets an extra "." (RFC 5321 4.5.2).
    const msg = try buildMessage(a, c.from, m);
    var stuffed: std.ArrayList(u8) = .empty;
    var it = std.mem.splitSequence(u8, msg, "\r\n");
    var first = true;
    while (it.next()) |line| {
        if (!first) try stuffed.appendSlice(a, "\r\n");
        first = false;
        if (line.len > 0 and line[0] == '.') try stuffed.append(a, '.');
        try stuffed.appendSlice(a, line);
    }
    try stuffed.appendSlice(a, "\r\n.");
    _ = try l.cmd(a, stuffed.items, &.{250});
    _ = l.cmd(a, "QUIT", &.{221}) catch {};
}

fn startTls(in: *Io.Reader, out: *Io.Writer, rbuf: []u8, wbuf: []u8) !std.crypto.tls.Client {
    const io = a_.app.io;
    const client = &a_.app.client;
    // The certificate bundle std.http's client keeps (scanned once from the system).
    {
        client.ca_bundle_lock.lockSharedUncancelable(io);
        const scanned = client.now != null;
        client.ca_bundle_lock.unlockShared(io);
        if (!scanned) {
            var bundle: std.crypto.Certificate.Bundle = .empty;
            defer bundle.deinit(client.allocator);
            const now = Io.Clock.real.now(io);
            try bundle.rescan(client.allocator, io, now);
            client.ca_bundle_lock.lockUncancelable(io);
            defer client.ca_bundle_lock.unlock(io);
            if (client.now == null) {
                client.now = now;
                std.mem.swap(std.crypto.Certificate.Bundle, &client.ca_bundle, &bundle);
            }
        }
    }
    var entropy: [std.crypto.tls.Client.Options.entropy_len]u8 = undefined;
    io.random(&entropy);
    return std.crypto.tls.Client.init(in, out, .{
        .host = .{ .explicit = a_.cfg().smtp.host },
        .ca = .{ .bundle = .{ .gpa = client.allocator, .io = io, .lock = &client.ca_bundle_lock, .bundle = &client.ca_bundle } },
        .read_buffer = rbuf,
        .write_buffer = wbuf,
        .entropy = &entropy,
        .realtime_now = Io.Clock.real.now(io),
    });
}
