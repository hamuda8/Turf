//! Track a parcel from inside the app (Turf-js views/shared/track.js): the same search as the
//! home page (any parcel on Turf, by tracking number). Inside a company, parcels the member may
//! open get a link to their page.

const std = @import("std");
const zui = @import("zui");
const core = @import("../core.zig");
const kit = @import("../kit.zig");
const json = @import("../json.zig");
const labels = @import("../labels.zig");
const lookup = @import("../widgets/lookup.zig");

const Cx = core.Cx;
const Ui = core.Ui;
const L = labels.k;

const d_results: u8 = 0;
const f_box: u16 = 0;
/// `open_base + i`: the company's shipment for result i.
const A = enum(u16) { search = 1, history, searching, open_base = 100 };

pub const S = struct {
    search: lookup.Search = .{ .slot = f_box, .act = @intFromEnum(A.search) },
    results: lookup.Results = .{ .slot = d_results, .busy = @intFromEnum(A.searching), .act_history = @intFromEnum(A.history) },
    /// Per result, the page of the shipment in this company ("" when it is not one of ours).
    open: [lookup.max_numbers][]const u8 = @splat(""),
};

pub fn title(_: *const S, _: *const Cx) []const u8 {
    return L("lookup.title");
}

pub fn enter(s: *S, c: *Cx) void {
    var numbers = lookup.splitNumbers(c.arena(), c.query(c.arena(), "n"));
    if (numbers.len > lookup.max_numbers) numbers = numbers[0..lookup.max_numbers];
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
        .act => |a| switch (a.id) {
            @intFromEnum(A.search) => switch (s.search.submit(c)) {
                .none => {},
                .numbers => |n| {
                    // Keep the address shareable without reloading the page.
                    c.fx.setLink(c.print("{s}/track?n={s}", .{ c.baseStr(), core.encode(c.arena(), lookup.join(c.arena(), n, ",")) }));
                    s.open = @splat("");
                    s.results.search(c, n);
                },
            },
            @intFromEnum(A.history) => s.results.toggle(a.arg),
            else => {},
        },
        .data => |n| if (n == d_results) {
            s.results.loaded(c);
            s.open = @splat("");
            addOpenLinks(c);
        },
        .done => |d| if (d.id >= @intFromEnum(A.open_base) and d.id < @intFromEnum(A.open_base) + lookup.max_numbers) {
            if (!d.ok) return; // not this company's parcel
            const sh = json.obj(d.v, "shipment") orelse return;
            const id = json.strOr(sh, "id", json.str(sh, "_id"));
            if (id.len > 0) s.open[d.id - @intFromEnum(A.open_base)] = c.print("/shipments/{s}", .{id});
        },
        else => {},
    }
}

/// Inside a company: "Open shipment" on the parcels this member can see there.
fn addOpenLinks(c: *Cx) void {
    if (c.mode != .org or !c.can("shipments.view")) return;
    const base = if (c.isCarrier()) "/carrier" else "/merchant";
    for (json.arr(c.data(d_results), "results"), 0..) |r, i| {
        if (i >= lookup.max_numbers or !json.boolean(r, "found")) continue;
        const id: u16 = @intFromEnum(A.open_base) + @as(u16, @intCast(i));
        c.quietErrors(id);
        c.send(id, .GET, c.orgUrl(c.print("{s}/shipments/{s}", .{ base, core.encode(c.arena(), json.str(r, "trackingNumber")) })), "");
    }
}

pub fn view(s: *const S, c: *const Cx, ui: *Ui) void {
    const w = @min(kit.width, 760);
    const saved = kit.width;
    kit.width = w;
    ui.begin(.{ .gap = 16, .width = .{ .px = w } }, .{});
    kit.muted(ui, L("lookup.intro"));
    lookup.form(ui, &s.search, .{ .busy = @intFromEnum(A.searching) });
    lookup.results(ui, c, &s.results, .{ .open_links = &s.open });
    ui.end();
    kit.width = saved;
}

// ---- Tests --------------------------------------------------------------------------------

const testing = std.testing;

test "app track: a company member gets Open shipment on its parcels" {
    const app = @import("../app.zig");
    try app.startSignedIn("/o/acme/track?n=TRF1234567890");
    defer app.D.reset();
    try testing.expect(app.D.respond("/api/app/orgs/o1", 200,
        \\{"id":"o1","type":"merchant","name":"Acme Store","slug":"acme","status":"active","me":{"permissions":["shipments.view"]}}
    ));
    try testing.expect(app.D.respond("/api/public/lookup?n=TRF1234567890", 200,
        \\{"results":[{"found":true,"trackingNumber":"TRF1234567890","status":"delivered","statusTextEn":"Delivered","statusTextAr":"تم","deliveredAt":"2025-10-12T09:00:00.000Z","carrier":{"name":"Fast"},"merchant":{"name":"Acme"},"events":[]}]}
    ));
    try testing.expect(app.D.findText("Delivered 12 Oct 2025, 12:00") != 0);
    try testing.expect(app.D.respond("/api/app/orgs/o1/merchant/shipments/TRF1234567890", 200, "{\"shipment\":{\"id\":\"s9\"}}"));
    try app.D.press("Open shipment");
    try testing.expectEqualStrings("/shipments/s9", app.D.R.appState().route());
}
