//! A small CSV reader and writer (Turf-js core/csv.js): quotes, escaped quotes, CRLF, Excel's
//! BOM, and Excel's ";" or tab separators (used with some regional settings).

const std = @import("std");

pub const Table = struct {
    /// Lower-cased and trimmed.
    headers: []const []const u8 = &.{},
    /// One value per header (trimmed; "" when the line was short).
    rows: []const []const []const u8 = &.{},

    /// The value of `header` in row `i` ("" when there is no such column).
    pub fn get(t: Table, i: usize, header: []const u8) []const u8 {
        var found: []const u8 = "";
        // A repeated header: the last one wins, as Object.fromEntries.
        for (t.headers, 0..) |h, j| if (std.mem.eql(u8, h, header)) {
            found = t.rows[i][j];
        };
        return found;
    }

    pub fn has(t: Table, header: []const u8) bool {
        for (t.headers) |h| if (std.mem.eql(u8, h, header)) return true;
        return false;
    }
};

const bom = "\u{FEFF}";

/// Text -> a header row and the rows under it. Lines with only blanks are skipped.
pub fn parse(a: std.mem.Allocator, text: []const u8) Table {
    const src = if (std.mem.startsWith(u8, text, bom)) text[bom.len..] else text;
    const first_end = std.mem.indexOfScalar(u8, src, '\n') orelse src.len;
    var first = src[0..first_end];
    if (first.len > 0 and first[first.len - 1] == '\r') first = first[0 .. first.len - 1];
    // The separator the first line uses most (ties: comma, then semicolon, then tab).
    var sep: u8 = ',';
    var best: usize = 0;
    for ([_]u8{ ',', ';', '\t' }) |ch| {
        const n = std.mem.count(u8, first, &.{ch}) + 1;
        if (n > best) {
            best = n;
            sep = ch;
        }
    }

    var rows: std.ArrayList([]const []const u8) = .empty;
    var row: std.ArrayList([]const u8) = .empty;
    var field: std.ArrayList(u8) = .empty;
    var quoted = false;
    var i: usize = 0;
    while (i < src.len) : (i += 1) {
        const ch = src[i];
        if (quoted) {
            if (ch == '"' and i + 1 < src.len and src[i + 1] == '"') {
                field.append(a, '"') catch {};
                i += 1;
            } else if (ch == '"') quoted = false else field.append(a, ch) catch {};
        } else if (ch == '"' and field.items.len == 0) {
            quoted = true;
        } else if (ch == sep) {
            row.append(a, field.toOwnedSlice(a) catch "") catch {};
        } else if (ch == '\n' or ch == '\r') {
            if (ch == '\r' and i + 1 < src.len and src[i + 1] == '\n') i += 1;
            row.append(a, field.toOwnedSlice(a) catch "") catch {};
            if (anyText(row.items)) rows.append(a, row.toOwnedSlice(a) catch &.{}) catch {} else row.clearRetainingCapacity();
        } else field.append(a, ch) catch {};
    }
    row.append(a, field.toOwnedSlice(a) catch "") catch {};
    if (anyText(row.items)) rows.append(a, row.toOwnedSlice(a) catch &.{}) catch {};
    if (rows.items.len == 0) return .{};

    const head = rows.items[0];
    const headers = a.alloc([]const u8, head.len) catch return .{};
    for (head, 0..) |h, j| {
        const tr = std.mem.trim(u8, h, " \t\r\n");
        const low = a.alloc(u8, tr.len) catch return .{};
        for (tr, 0..) |x, n| low[n] = std.ascii.toLower(x);
        headers[j] = low;
    }
    const out = a.alloc([]const []const u8, rows.items.len - 1) catch return .{};
    for (rows.items[1..], 0..) |cells, r| {
        const vals = a.alloc([]const u8, headers.len) catch return .{};
        for (vals, 0..) |*v, j| v.* = if (j < cells.len) std.mem.trim(u8, cells[j], " \t\r\n") else "";
        out[r] = vals;
    }
    return .{ .headers = headers, .rows = out };
}

fn anyText(cells: []const []const u8) bool {
    for (cells) |x| if (std.mem.trim(u8, x, " \t\r\n").len > 0) return true;
    return false;
}

/// Rows -> CSV text with a BOM so Excel opens Arabic correctly.
pub fn write(a: std.mem.Allocator, rows: []const []const []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(a, bom) catch {};
    for (rows, 0..) |r, i| {
        if (i > 0) out.appendSlice(a, "\r\n") catch {};
        for (r, 0..) |x, j| {
            if (j > 0) out.append(a, ',') catch {};
            if (std.mem.indexOfAny(u8, x, "\",\n\r") != null) {
                out.append(a, '"') catch {};
                for (x) |ch| {
                    if (ch == '"') out.append(a, '"') catch {};
                    out.append(a, ch) catch {};
                }
                out.append(a, '"') catch {};
            } else out.appendSlice(a, x) catch {};
        }
    }
    out.appendSlice(a, "\r\n") catch {};
    return out.items;
}

test "csv reads and writes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t = parse(a, bom ++ "Name;Phone\r\n\"Lina \"\"H\"\"\";0944\r\n;\r\nSami\n");
    try std.testing.expectEqual(@as(usize, 2), t.rows.len);
    try std.testing.expectEqualStrings("name", t.headers[0]);
    try std.testing.expectEqualStrings("Lina \"H\"", t.get(0, "name"));
    try std.testing.expectEqualStrings("", t.get(1, "phone"));
    try std.testing.expectEqualStrings(bom ++ "a,\"b,c\"\r\n\"q\"\"\",x\r\n", write(a, &.{ &.{ "a", "b,c" }, &.{ "q\"", "x" } }));
}
