//! Dates, times, numbers, money, distances and durations as Turf-js's core/format.js shows them
//! (Intl with "en-GB", or "ar-SY-u-nu-latn": Latin digits, Arabic words), written out by hand
//! because zui has no Intl. Also the wall clock: zui only has a monotonic frame clock, so the
//! web shell sends the time and the time zone (shells/web/index.html), and the phones read
//! the system clock.

const std = @import("std");
const zui = @import("zui");
const builtin = @import("builtin");

// ---- Clock --------------------------------------------------------------------------------

/// Wall time in ms (Unix epoch), as last told by the web shell, and the local offset in minutes
/// east of UTC (Damascus: +180).
var web_now_ms: i64 = 0;
var web_told_at: f64 = 0;
var tz_minutes: i32 = 180;
/// Tests set the time.
pub var fixed_now_ms: ?i64 = null;

/// The web shell's clock message (every few seconds): `now` ms and `tz` minutes east of UTC.
pub fn setClock(now_ms: i64, tz: i32) void {
    web_now_ms = now_ms;
    tz_minutes = tz;
    web_told_at = 0;
}

pub fn now() i64 {
    if (fixed_now_ms) |n| return n;
    switch (zui.platform) {
        .web => return web_now_ms,
        .headless => return 1_760_270_400_000, // 2025-10-12T12:00:00Z
        else => {
            var ts: std.c.timespec = undefined;
            if (std.c.clock_gettime(.REALTIME, &ts) != 0) return 0;
            return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
        },
    }
}

pub fn offsetMinutes() i32 {
    if (zui.platform == .android or zui.platform == .ios) {
        var t: std.c.time_t = @intCast(@divTrunc(now(), 1000));
        var tm: Tm = undefined;
        if (localtime_r(&t, &tm) != null) return @intCast(@divTrunc(tm.tm_gmtoff, 60));
    }
    return tz_minutes;
}

const Tm = extern struct {
    tm_sec: c_int,
    tm_min: c_int,
    tm_hour: c_int,
    tm_mday: c_int,
    tm_mon: c_int,
    tm_year: c_int,
    tm_wday: c_int,
    tm_yday: c_int,
    tm_isdst: c_int,
    tm_gmtoff: c_long,
    tm_zone: ?[*:0]const u8,
};
extern "c" fn localtime_r(t: *std.c.time_t, out: *Tm) ?*Tm;

// ---- Parsing ------------------------------------------------------------------------------

/// "2026-10-12T11:05:00.000Z" (or with +hh:mm) as ms since the epoch.
pub fn parseIso(s: []const u8) ?i64 {
    if (s.len < 10) return null;
    const y = std.fmt.parseInt(i32, s[0..4], 10) catch return null;
    const mo = std.fmt.parseInt(u8, s[5..7], 10) catch return null;
    const d = std.fmt.parseInt(u8, s[8..10], 10) catch return null;
    var h: i64 = 0;
    var mi: i64 = 0;
    var sec: i64 = 0;
    var ms: i64 = 0;
    var off: i64 = 0;
    if (s.len >= 16 and (s[10] == 'T' or s[10] == ' ')) {
        h = std.fmt.parseInt(i64, s[11..13], 10) catch return null;
        mi = std.fmt.parseInt(i64, s[14..16], 10) catch return null;
        var i: usize = 16;
        if (s.len >= 19 and s[16] == ':') {
            sec = std.fmt.parseInt(i64, s[17..19], 10) catch return null;
            i = 19;
            if (i < s.len and s[i] == '.') {
                i += 1;
                var digits: usize = 0;
                while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {
                    if (digits < 3) ms = ms * 10 + (s[i] - '0');
                    digits += 1;
                }
                while (digits < 3) : (digits += 1) ms *= 10;
            }
        }
        if (i < s.len and (s[i] == '+' or s[i] == '-') and s.len >= i + 6) {
            const oh = std.fmt.parseInt(i64, s[i + 1 .. i + 3], 10) catch 0;
            const om = std.fmt.parseInt(i64, s[i + 4 .. i + 6], 10) catch 0;
            off = (oh * 60 + om) * (if (s[i] == '-') @as(i64, -1) else 1);
        }
    }
    const days = daysFromCivil(y, mo, d);
    return ((days * 86400 + h * 3600 + mi * 60 + sec) - off * 60) * 1000 + ms;
}

fn daysFromCivil(y0: i32, m: u8, d: u8) i64 {
    const y: i64 = if (m <= 2) y0 - 1 else y0;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp: i64 = @rem(@as(i64, m) + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

pub const Civil = struct { y: i64, m: u8, d: u8, h: u8, mi: u8, wday: u8 };

pub fn civil(ms: i64) Civil {
    const local = @divFloor(ms, 1000) + @as(i64, offsetMinutes()) * 60;
    const days = @divFloor(local, 86400);
    const secs = local - days * 86400;
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d: u8 = @intCast(doy - @divFloor(153 * mp + 2, 5) + 1);
    const m: u8 = @intCast(if (mp < 10) mp + 3 else mp - 9);
    const y = yoe + era * 400 + @as(i64, if (m <= 2) 1 else 0);
    return .{ .y = y, .m = m, .d = d, .h = @intCast(@divFloor(secs, 3600)), .mi = @intCast(@divFloor(@mod(secs, 3600), 60)), .wday = @intCast(@mod(days + 4, 7)) };
}

fn ar() bool {
    return std.mem.eql(u8, zui.i18n.language(), "ar");
}

const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
const rlm = "\u{200F}";

fn datePart(a: std.mem.Allocator, c: Civil) []const u8 {
    if (ar()) return std.fmt.allocPrint(a, "{d}" ++ rlm ++ "/{d}" ++ rlm ++ "/{d}", .{ c.d, c.m, c.y }) catch "";
    return std.fmt.allocPrint(a, "{d} {s} {d}", .{ c.d, months[c.m - 1], c.y }) catch "";
}

fn timePart(a: std.mem.Allocator, c: Civil) []const u8 {
    if (ar()) {
        const h12 = if (c.h % 12 == 0) 12 else c.h % 12;
        return std.fmt.allocPrint(a, "{d}:{d:0>2} {s}", .{ h12, c.mi, if (c.h < 12) "ص" else "م" }) catch "";
    }
    return std.fmt.allocPrint(a, "{d:0>2}:{d:0>2}", .{ c.h, c.mi }) catch "";
}

fn msOf(v: []const u8) ?i64 {
    if (v.len == 0) return null;
    return parseIso(v);
}

/// "12 Oct 2026, 14:05" / "12/10/2026، 2:05 م"; "—" when empty.
pub fn dateTime(a: std.mem.Allocator, iso: []const u8) []const u8 {
    const ms = msOf(iso) orelse return "—";
    const c = civil(ms);
    return std.fmt.allocPrint(a, "{s}{s} {s}", .{ datePart(a, c), if (ar()) "،" else ",", timePart(a, c) }) catch "";
}

pub fn date(a: std.mem.Allocator, iso: []const u8) []const u8 {
    const ms = msOf(iso) orelse return "—";
    return datePart(a, civil(ms));
}

pub fn time(a: std.mem.Allocator, iso: []const u8) []const u8 {
    const ms = msOf(iso) orelse return "—";
    return timePart(a, civil(ms));
}

/// "YYYY-MM-DD" of a moment in local time (date inputs, report ranges).
pub fn isoDay(a: std.mem.Allocator, ms: i64) []const u8 {
    const c = civil(ms);
    return std.fmt.allocPrint(a, "{d}-{d:0>2}-{d:0>2}", .{ c.y, c.m, c.d }) catch "";
}

/// "5 minutes ago", "in 2 hours", "yesterday" (Intl.RelativeTimeFormat, numeric: "auto").
pub fn relative(a: std.mem.Allocator, iso: []const u8) []const u8 {
    const ms = msOf(iso) orelse return "—";
    const diff = @as(f64, @floatFromInt(ms - now())) / 1000;
    const abs = @abs(diff);
    if (abs < 45) return zui.i18n.t("just now");
    const Unit = enum { minute, hour, day };
    const unit: Unit, const n_f: f64 = if (abs < 3600) .{ .minute, diff / 60 } else if (abs < 86400) .{ .hour, diff / 3600 } else .{ .day, diff / 86400 };
    const n: i64 = @intFromFloat(@round(n_f));
    const past = n < 0;
    const k: u64 = @abs(n);
    if (ar()) {
        const words: [5][]const u8 = switch (unit) {
            .minute => .{ "دقيقة واحدة", "دقيقتين", "دقائق", "دقيقة", "" },
            .hour => .{ "ساعة واحدة", "ساعتين", "ساعات", "ساعة", "" },
            .day => .{ "", "", "أيام", "يومًا", "" },
        };
        if (unit == .day) {
            if (k == 1) return if (past) "أمس" else "غدًا";
            if (k == 2) return if (past) "أول أمس" else "بعد الغد";
        }
        const phrase = if (k == 1) words[0] else if (k == 2) words[1] else if (k <= 10)
            std.fmt.allocPrint(a, "{d} {s}", .{ k, words[2] }) catch ""
        else
            std.fmt.allocPrint(a, "{d} {s}", .{ k, words[3] }) catch "";
        return std.fmt.allocPrint(a, "{s} {s}", .{ if (past) "قبل" else "خلال", phrase }) catch "";
    }
    if (unit == .day and k == 1) return if (past) "yesterday" else "tomorrow";
    const name = switch (unit) {
        .minute => "minute",
        .hour => "hour",
        .day => "day",
    };
    const plural = if (k == 1) "" else "s";
    return if (past)
        std.fmt.allocPrint(a, "{d} {s}{s} ago", .{ k, name, plural }) catch ""
    else
        std.fmt.allocPrint(a, "in {d} {s}{s}", .{ k, name, plural }) catch "";
}

/// 1,234,567.89 with at most `digits` decimals.
pub fn number(a: std.mem.Allocator, n: f64, digits: u8) []const u8 {
    if (!std.math.isFinite(n)) return "—";
    const scale = std.math.pow(f64, 10, @floatFromInt(digits));
    const r = @round(@abs(n) * scale) / scale;
    const whole: u64 = @intFromFloat(@floor(r));
    var frac = r - @floor(r);
    var out: std.ArrayList(u8) = .empty;
    if (n < 0 and r > 0) out.append(a, '-') catch {};
    var buf: [32]u8 = undefined;
    const ws = std.fmt.bufPrint(&buf, "{d}", .{whole}) catch "";
    for (ws, 0..) |ch, i| {
        if (i > 0 and (ws.len - i) % 3 == 0) out.append(a, ',') catch {};
        out.append(a, ch) catch {};
    }
    if (digits > 0 and frac > 1e-9) {
        out.append(a, '.') catch {};
        var d: u8 = 0;
        var digits_buf: [8]u8 = undefined;
        var len: usize = 0;
        while (d < digits) : (d += 1) {
            frac *= 10;
            var dig: u8 = @intFromFloat(@floor(frac + 1e-7));
            if (dig > 9) dig = 9;
            digits_buf[len] = '0' + dig;
            len += 1;
            frac -= @floatFromInt(dig);
        }
        while (len > 0 and digits_buf[len - 1] == '0') len -= 1;
        out.appendSlice(a, digits_buf[0..len]) catch {};
    }
    return out.items;
}

pub fn money(a: std.mem.Allocator, amount: ?f64, currency: []const u8) []const u8 {
    const v = amount orelse return "—";
    const n = number(a, v, 2);
    if (currency.len == 0) return n;
    return std.fmt.allocPrint(a, "{s} {s}", .{ n, currency }) catch n;
}

/// "850 m" / "3.4 km".
pub fn distance(a: std.mem.Allocator, meters: ?f64) []const u8 {
    const m = meters orelse return "—";
    if (m < 1000) return std.fmt.allocPrint(a, "{d} {s}", .{ @as(i64, @intFromFloat(@round(m / 10) * 10)), zui.i18n.t("m") }) catch "";
    return std.fmt.allocPrint(a, "{s} {s}", .{ number(a, m / 1000, if (m < 10_000) 1 else 0), zui.i18n.t("km") }) catch "";
}

/// "12 min", "1 h 5 min", "2 h".
pub fn duration(a: std.mem.Allocator, minutes: ?f64) []const u8 {
    const mins = minutes orelse return "—";
    if (mins < 60) return zui.i18n.tf(a, "{n} min", .{ .n = @max(1, @as(i64, @intFromFloat(@round(mins)))) });
    const h: i64 = @intFromFloat(@floor(mins / 60));
    const m: i64 = @intFromFloat(@round(@mod(mins, 60)));
    if (m != 0) return zui.i18n.tf(a, "{h} h {m} min", .{ .h = h, .m = m });
    return zui.i18n.tf(a, "{n} h", .{ .n = h });
}

test "iso dates and numbers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ms = parseIso("2026-10-12T11:05:00.000Z").?;
    try std.testing.expectEqual(@as(i64, 1_791_803_100_000), ms);
    tz_minutes = 180;
    try std.testing.expectEqualStrings("12 Oct 2026, 14:05", dateTime(a, "2026-10-12T11:05:00.000Z"));
    try std.testing.expectEqualStrings("1,234,567.89", number(a, 1234567.891, 2));
    try std.testing.expectEqualStrings("12", number(a, 12, 2));
    try std.testing.expectEqualStrings("0.5", number(a, 0.5, 2));
    fixed_now_ms = ms + 5 * 60_000;
    defer fixed_now_ms = null;
    try std.testing.expectEqualStrings("5 minutes ago", relative(a, "2026-10-12T11:05:00.000Z"));
}

/// "2026-10-12T11:05:00.000Z" for a moment (UTC).
pub fn isoUtc(a: std.mem.Allocator, ms: i64) []const u8 {
    const secs = @divFloor(ms, 1000);
    const days = @divFloor(secs, 86400);
    const rem_s = secs - days * 86400;
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    const y = yoe + era * 400 + @as(i64, if (m <= 2) 1 else 0);
    return std.fmt.allocPrint(a, "{d}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        @as(u64, @intCast(y)), @as(u64, @intCast(m)), @as(u64, @intCast(d)),
        @as(u64, @intCast(@divFloor(rem_s, 3600))), @as(u64, @intCast(@divFloor(@mod(rem_s, 3600), 60))), @as(u64, @intCast(@mod(rem_s, 60))),
        @as(u64, @intCast(@mod(ms, 1000))),
    }) catch "";
}

test "iso round trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("2026-10-12T11:05:00.000Z", isoUtc(arena.allocator(), parseIso("2026-10-12T11:05:00.000Z").?));
}
