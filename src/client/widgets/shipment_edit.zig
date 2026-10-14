//! Changing a shipment after creation (Turf-js views/shared/shipment-edit.js): the recipient's
//! details and the notes, and the delivery day. Used by the store's and the carrier's shipment
//! pages: keep an `Edit` in the page state, forward events to `update` (true when it handled
//! one) and draw `overlay`.

const std = @import("std");
const zui = @import("zui");
const core = @import("../core.zig");
const kit = @import("../kit.zig");
const shell = @import("../shell.zig");
const json = @import("../json.zig");
const fmt = @import("../fmt.zig");
const labels = @import("../labels.zig");

const Cx = core.Cx;
const Ui = core.Ui;
const V = json.V;
const L = labels.k;

/// The statuses in which a shipment can still be changed.
pub const editable = [_][]const u8{ "awaiting_carrier", "awaiting_pickup", "picked_up", "at_hub", "in_transit", "delivery_failed" };

pub fn isEditable(status: []const u8) bool {
    for (editable) |e| if (std.mem.eql(u8, e, status)) return true;
    return false;
}

/// Action ids (pages use ids below 800).
pub const A = enum(u16) { open_details = 800, open_day, close, save_details, save_day, clear_day };

/// Form slots (pages use slots below 400).
const f_name: u16 = 400;
const f_phone: u16 = 401;
const f_city: u16 = 402;
const f_area: u16 = 403;
const f_street: u16 = 404;
const f_details: u16 = 405;
const f_notes: u16 = 406;
const f_day: u16 = 407;

pub const Edit = struct {
    open: enum { none, details, day } = .none,
    /// The shipment's API path ("/merchant/shipments/<id>"), in page memory.
    path: []const u8 = "",
    /// The current delivery day (for "currently" and Clear), in page memory.
    current_day: []const u8 = "",
    /// Set when a save went through: the page reloads the shipment.
    saved: bool = false,
};

fn isMine(id: u16) bool {
    return id >= 800 and id <= @intFromEnum(A.clear_day);
}

/// Opens the details dialog filled from `s`.
pub fn openDetails(e: *Edit, c: *Cx, path: []const u8, s: ?V) void {
    e.open = .details;
    e.path = c.dupe(path);
    c.setVal(f_name, json.str(s, "dropoff.name"));
    c.setVal(f_phone, json.str(s, "dropoff.phone"));
    c.setVal(f_city, json.str(s, "dropoff.city"));
    c.setVal(f_area, json.str(s, "dropoff.area"));
    c.setVal(f_street, json.str(s, "dropoff.street"));
    c.setVal(f_details, json.str(s, "dropoff.details"));
    c.setVal(f_notes, json.str(s, "notes"));
}

/// Opens the delivery-day dialog.
pub fn openDay(e: *Edit, c: *Cx, path: []const u8, current: []const u8) void {
    e.open = .day;
    e.path = c.dupe(path);
    e.current_day = c.dupe(current);
    // Today in Syria (UTC+3), as the JS did.
    c.setVal(f_day, if (current.len > 0) current else syriaDay(c.arena(), 0));
}

/// "YYYY-MM-DD" in Syria (UTC+3), `days` from today.
fn syriaDay(a: std.mem.Allocator, days: i64) []const u8 {
    return fmt.isoDay(a, fmt.now() + (180 - @as(i64, fmt.offsetMinutes())) * 60_000 + days * 86_400_000);
}

fn optStr(b: *json.Obj, name: []const u8, v: []const u8) void {
    if (v.len == 0) b.nul(name) else b.str(name, v);
}

pub fn update(e: *Edit, c: *Cx, ev: core.Ev) bool {
    switch (ev) {
        .act => |a| {
            if (!isMine(a.id)) return false;
            switch (@as(A, @enumFromInt(a.id))) {
                .close => e.open = .none,
                .save_details => {
                    var b = json.Obj.init(c.arena());
                    b.begin("dropoff");
                    // Empty required fields are left out (formValues); the server says what is missing.
                    b.strOpt("name", c.valTrim(f_name));
                    b.strOpt("phone", c.valTrim(f_phone));
                    b.strOpt("city", c.valTrim(f_city));
                    // Empty optional fields are cleared on purpose.
                    optStr(&b, "area", c.valTrim(f_area));
                    optStr(&b, "street", c.valTrim(f_street));
                    optStr(&b, "details", c.valTrim(f_details));
                    b.end();
                    optStr(&b, "notes", c.valTrim(f_notes));
                    c.send(@intFromEnum(A.save_details), .PATCH, c.orgUrl(e.path), b.done());
                },
                .save_day => {
                    var b = json.Obj.init(c.arena());
                    b.str("date", c.valTrim(f_day));
                    c.send(@intFromEnum(A.save_day), .POST, c.orgUrl(c.print("{s}/reschedule", .{e.path})), b.done());
                },
                .clear_day => c.send(@intFromEnum(A.save_day), .POST, c.orgUrl(c.print("{s}/reschedule", .{e.path})), "{\"date\":null}"),
                .open_details, .open_day => {},
            }
            return true;
        },
        .done => |d| {
            if (!isMine(d.id)) return false;
            if (d.ok) {
                e.open = .none;
                e.saved = true;
                c.toast(L("common.saved"), .ok);
            }
            return true;
        },
        .text => |x| {
            // Turf-js maxlength limits.
            const n: usize = switch (x.slot) {
                f_name, f_area => 120,
                f_city => 80,
                f_street => 200,
                f_details, f_notes => 500,
                else => return false,
            };
            @import("address.zig").limitText(c, x.slot, n);
            return false;
        },
        else => return false,
    }
}

pub fn overlay(e: *const Edit, c: *const Cx, ui: *Ui) void {
    switch (e.open) {
        .none => {},
        .details => {
            shell.modalBegin(ui, .{ .title = L("edit.title"), .close = kit.act(A.close, 0), .wide = true, .key = zui.key("edit-details") });
            kit.small(ui, L("edit.intro"));
            const submit = kit.act(A.save_details, 0);
            var g = kit.formGrid(ui, 6);
            const fields = [_]struct { []const u8, u16, []const u8, bool, kit.InputKind }{
                .{ "common.name", f_name, "dropoff.name", true, .text },
                .{ "common.phone", f_phone, "dropoff.phone", true, .phone },
                .{ "address.city", f_city, "dropoff.city", true, .text },
                .{ "address.area", f_area, "dropoff.area", false, .text },
                .{ "address.street", f_street, "dropoff.street", false, .text },
                .{ "address.details", f_details, "dropoff.details", false, .text },
            };
            for (fields) |x| {
                g.cell();
                kit.field(ui, L(x[0]), x[1], .{ .required = x[3], .input = .{ .name = x[2], .kind = x[4], .ltr = x[4] == .phone, .on_submit = submit } });
                g.endCell();
            }
            g.end();
            kit.field(ui, L("new.notes"), f_notes, .{ .input = .{ .name = "notes", .on_submit = submit } });
            shell.modalFoot(ui);
            shell.modalButton(ui, L("common.cancel"), kit.act(A.close, 0), .{});
            shell.modalButton(ui, L("common.save"), submit, .{ .variant = .primary, .busy = @intFromEnum(A.save_details) });
            shell.modalEnd(ui, true);
        },
        .day => {
            shell.modalBegin(ui, .{ .title = L("edit.reschedule_title"), .close = kit.act(A.close, 0), .key = zui.key("edit-day") });
            kit.small(ui, L("edit.reschedule_intro"));
            // The platform's date picker: today to 14 days ahead.
            kit.dateField(ui, L("edit.delivery_day"), f_day, .{ .required = true, .name = "date", .min = syriaDay(ui.arena(), 0), .max = syriaDay(ui.arena(), 14), .placeholder = L("common.choose") });
            if (e.current_day.len > 0) kit.text(ui, ui.tf(labels.english("edit.currently") orelse "{date}", .{ .date = fmt.date(ui.arena(), e.current_day) }), .{ .size = 13.6 });
            shell.modalFoot(ui);
            shell.modalButton(ui, L("common.cancel"), kit.act(A.close, 0), .{});
            if (e.current_day.len > 0) shell.modalButton(ui, L("edit.clear_day"), kit.act(A.clear_day, 0), .{});
            shell.modalButton(ui, L("common.save"), kit.act(A.save_day, 0), .{ .variant = .primary, .busy = @intFromEnum(A.save_day) });
            shell.modalEnd(ui, true);
        },
    }
    _ = c;
}
