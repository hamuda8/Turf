//! Email (src/mailer.js) over zig-core's smtp: one email per encrypted connection.
//! SMTP_PORT 465 = TLS from the start, 587 = STARTTLS. Without SMTP_HOST emails are printed to
//! the log instead; under NODE_ENV=test they are kept in `outbox` for the tests to read.

const std = @import("std");
const Io = std.Io;
const smtp = @import("smtp");
const val = @import("mongo").val;
const a_ = @import("app.zig");
const Allocator = std.mem.Allocator;

pub const Mail = smtp.Mail;

var outbox_lock: Io.Mutex = .init;
/// Emails "sent" in test mode, as JSON (gpa).
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

/// Sends one email (or logs / keeps it when SMTP is not set up).
pub fn sendMail(a: Allocator, mail: Mail) !void {
    const m: Mail = .{ .to = val.jsTrim(try smtp.oneLine(a, mail.to)), .subject = val.jsTrim(try smtp.oneLine(a, mail.subject)), .text = mail.text, .html = mail.html };
    if (!smtp.validRecipient(m.to)) return error.InvalidRecipient;
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
    return smtp.send(a_.app.io, a, &a_.app.fetch.http, .{
        .host = c.host,
        .port = c.port,
        .secure = c.secure,
        .user = c.user,
        .pass = c.pass,
        .from = c.from,
        .allow_insecure = c.allow_insecure,
        .timeout_ms = 60_000,
    }, m, a_.nowMs());
}
