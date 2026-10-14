//! The public tracking search "/track?n=TRF…,TRF…" (Turf-js lookup-page.js, lookup.html): find
//! parcels by tracking number. The address can be shared or bookmarked, and the page keeps it
//! up to date as the visitor searches again.

const std = @import("std");
const zui = @import("zui");
const core = @import("../core.zig");
const kit = @import("../kit.zig");
const icons = @import("../icons.zig");
const labels = @import("../labels.zig");
const lookup = @import("../widgets/lookup.zig");
const landing = @import("landing.zig");

const Cx = core.Cx;
const Ui = core.Ui;
const L = labels.k;

const d_results: u8 = 0;
const f_box: u16 = 0;
const A = enum(u16) { search = 1, history, searching };

pub const S = struct {
    search: lookup.Search = .{ .slot = f_box, .act = @intFromEnum(A.search) },
    results: lookup.Results = .{ .slot = d_results, .busy = @intFromEnum(A.searching), .act_history = @intFromEnum(A.history) },
};

pub fn title(_: *const S, _: *const Cx) []const u8 {
    return L("lookup.title");
}

pub fn enter(s: *S, c: *Cx) void {
    var numbers = lookup.splitNumbers(c.arena(), c.query(c.arena(), "n"));
    if (numbers.len > lookup.max_numbers) numbers = numbers[0..lookup.max_numbers];
    c.post("{{\"type\":\"title\",\"title\":{f}}}", .{std.json.fmt(c.print("{s} · Turf", .{L("lookup.title")}), .{})});
    if (numbers.len == 0) {
        // The box takes the keyboard on wide screens (Turf-js: only with a mouse).
        if (c.env.width > 900) c.fx.focus(kit.slotKey(f_box));
        return;
    }
    s.search.prefill(c, numbers);
    s.results.search(c, numbers);
}

pub fn update(s: *S, c: *Cx, e: core.Ev) void {
    switch (e) {
        .act => |a| switch (@as(A, @enumFromInt(a.id))) {
            .search => switch (s.search.submit(c)) {
                .none => {},
                .numbers => |n| {
                    // The address follows the search (shareable, bookmarkable).
                    c.fx.setLink(c.print("/track?n={s}", .{core.encode(c.arena(), lookup.join(c.arena(), n, ","))}));
                    s.results.search(c, n);
                },
            },
            .history => s.results.toggle(a.arg),
            .searching => {},
        },
        .data => |n| if (n == d_results) s.results.loaded(c),
        // The title, the hint and the results again in the new language.
        .lang => {
            s.search.err = "";
            enter(s, c);
        },
        else => {},
    }
}

pub fn view(s: *const S, c: *const Cx, ui: *Ui) void {
    const w = ui.env.width;
    const side = landing.clampVw(ui, 16, 3, 24);
    const inner = @min(w, 760) - 2 * side;
    ui.beginScroll(.{ .width = .fill, .height = .fill, .padding = .{ .top = 0, .bottom = 0 } }, zui.key("lookup-page"));
    landing.nav(ui, c, false); // no API docs link on /track (lookup-page.js)
    ui.begin(.{ .width = .fill, .align_items = .center }, .{});
    ui.begin(.{ .width = .{ .px = inner + 2 * side }, .gap = 20, .padding = .{ .top = landing.clampVw(ui, 16, 4, 40), .bottom = 48, .start = side, .end = side } }, .{});
    kit.width = inner;
    ui.begin(.{ .gap = 10.4 }, .{});
    ui.text(L("lookup.title"), .{ .font_size = landing.clampVw(ui, 28.8, 4.5, 41.6), .weight = 850, .line_height = 1.1, .color = kit.k.ink });
    kit.muted(ui, L("lookup.intro"));
    ui.end();
    lookup.form(ui, &s.search, .{ .busy = @intFromEnum(A.searching) });
    lookup.results(ui, c, &s.results, .{});
    kit.noticeBegin(ui, .info, icons.info);
    kit.text(ui, L("lookup.where_number_long"), .{});
    kit.noticeEnd(ui);
    ui.end();
    ui.end();
    landing.footer(ui);
    ui.end();
}

// ---- Tests --------------------------------------------------------------------------------

const testing = std.testing;
const found_json =
    \\{"results":[{"found":true,"query":"TRF1234567890","trackingNumber":"TRF1234567890","status":"in_transit",
    \\ "statusTextEn":"On the way","statusTextAr":"في الطريق","service":"express","promisedBy":"2025-10-13T12:00:00.000Z",
    \\ "from":{"city":"Damascus","governorateName":{"en":"Damascus","ar":"دمشق"}},"to":{"city":"Homs","governorateName":{"en":"Homs","ar":"حمص"}},
    \\ "carrier":{"name":"Fast Express","phone":"0999"},"merchant":{"name":"Acme Store"},
    \\ "events":[{"at":"2025-10-12T09:00:00.000Z","textEn":"Handed to courier","textAr":"x"},{"at":"2025-10-12T11:00:00.000Z","textEn":"Left the hub","textAr":"y"}]},
    \\ {"found":false,"query":"TRF0000000000"}]}
;

test "lookup: the address's numbers are looked up, cards and history" {
    const app = @import("../app.zig");
    app.D.startWith(1024, 900, "/track?n=trf1234567890,TRF0000000000");
    defer app.D.reset();
    try testing.expect(app.D.respond("/api/public/lookup?n=TRF1234567890%2CTRF0000000000", 200, found_json));
    try testing.expect(app.D.findText("On the way") != 0);
    try testing.expect(app.D.findText("Order from Acme Store") != 0);
    try testing.expect(app.D.findText("We could not find this tracking number.") != 0);
    try testing.expect(app.D.findText("Damascus") != 0);
    // The latest update; all of them once opened.
    try testing.expect(app.D.findText("Left the hub") != 0);
    try testing.expect(app.D.findText("Handed to courier") == 0);
    try app.D.press("All updates (2)");
    try testing.expect(app.D.findText("Handed to courier") != 0);
    // Too many numbers.
    try app.D.typeInto("Enter tracking number", "A,B,C,D,E,F,G,H,I,J,K");
    try app.D.press("Track");
    try testing.expect(app.D.findText("At most 10 tracking numbers at once.") != 0);
    // A tracking link opens its page.
    try app.D.typeInto("Enter tracking number", "https://turf.example/t/abcdefghijklmnop1234");
    try app.D.press("Track");
    try testing.expectEqual(core.Mode.public_track, app.D.R.appState().mode);
}

test "lookup: a failed search says why" {
    const app = @import("../app.zig");
    app.D.startWith(390, 800, "/track");
    defer app.D.reset();
    try app.D.typeInto("Enter tracking number", "TRF1");
    try app.D.press("Track");
    try testing.expect(app.D.respond("/api/public/lookup", 429, "{}"));
    try testing.expect(app.D.findText("Too many requests. Please wait a moment.") != 0);
}

test {
    _ = lookup;
}
