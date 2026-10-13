//! The store opens a claim for one shipment (Turf-js views/shared/claims.js
//! `openClaimDialog`): the kind (lost, damaged, late), the amount asked, what happened.
//!
//! A page keeps a `Dialog` in its state, calls `setup` once (its form slots and action ids),
//! `open` with the shipment, passes every event to `update` (true when the claim was opened:
//! the page then goes on, e.g. to "/claims") and draws `overlay` in its own overlay.

const std = @import("std");
const zui = @import("zui");
const core = @import("../core.zig");
const kit = @import("../kit.zig");
const shell = @import("../shell.zig");
const json = @import("../json.zig");
const labels = @import("../labels.zig");
const address = @import("address.zig");

const Cx = core.Cx;
const Ui = core.Ui;
const V = json.V;
const L = labels.k;

const f_type: u16 = 0;
const f_amount: u16 = 1;
const f_description: u16 = 2;

const a_close: u16 = 0;
const a_submit: u16 = 1;

pub const Config = struct {
    /// Three form slots from here.
    slot: u16 = 400,
    /// Two action ids from here.
    act: u16 = 400,
};

pub const Dialog = struct {
    cfg: Config = .{},
    shown: bool = false,
    shipment_id: []const u8 = "",
    currency: []const u8 = "SYP",

    pub fn setup(d: *Dialog, cfg: Config) void {
        d.* = .{ .cfg = cfg };
    }

    /// Opens it for shipment `s` (`{ id, status, price, parcel }`).
    pub fn open(d: *Dialog, c: *Cx, s: ?V) void {
        d.shipment_id = c.dupe(json.str(s, "id"));
        d.currency = c.dupe(json.strOr(s, "price.currency", "SYP"));
        c.setVal(d.cfg.slot + f_type, if (std.mem.eql(u8, json.str(s, "status"), "delivered")) "damaged" else "lost");
        c.setVal(d.cfg.slot + f_amount, if (json.has(s, "parcel.value")) json.text(c.arena(), s, "parcel.value") else "");
        c.setVal(d.cfg.slot + f_description, "");
        c.clearFieldError();
        d.shown = true;
    }

    /// True when the claim was opened.
    pub fn update(d: *Dialog, c: *Cx, e: core.Ev) bool {
        switch (e) {
            .act => |x| {
                if (x.id == d.cfg.act + a_close) d.shown = false;
                if (x.id == d.cfg.act + a_submit and d.shown) {
                    var b = json.Obj.init(c.arena());
                    b.strOpt("type", c.val(d.cfg.slot + f_type));
                    address.numField(&b, "amount", c.val(d.cfg.slot + f_amount));
                    b.strOpt("description", c.val(d.cfg.slot + f_description));
                    c.send(d.cfg.act + a_submit, .POST, c.orgUrl(c.print("/merchant/shipments/{s}/claims", .{d.shipment_id})), b.done());
                }
            },
            .done => |x| if (x.id == d.cfg.act + a_submit and x.ok) {
                d.shown = false;
                c.toast(L("claims.opened"), .ok);
                return true;
            },
            else => {},
        }
        return false;
    }

    pub fn overlay(d: *const Dialog, ui: *Ui) void {
        if (!d.shown) return;
        const close: core.Msg = .{ .act = .{ .id = d.cfg.act + a_close } };
        const submit: core.Msg = .{ .act = .{ .id = d.cfg.act + a_submit } };
        shell.modalBegin(ui, .{ .title = L("claims.open_title"), .close = close, .key = zui.key("claim-dialog") });
        var types: [3]core.Opt = undefined;
        for ([_][]const u8{ "lost", "damaged", "late" }, 0..) |v, i| types[i] = .{ .value = v, .label = labels.of("claims.type.", v) };
        kit.selectField(ui, L("claims.kind"), d.cfg.slot + f_type, &types, .{ .required = true, .name = "type" });
        kit.field(ui, kit.f(ui, "{s} ({s})", .{ L("claims.amount"), d.currency }), d.cfg.slot + f_amount, .{ .required = true, .hint = L("claims.amount_hint"), .input = .{ .kind = .number, .ltr = true, .name = "amount", .on_submit = submit } });
        kit.field(ui, L("claims.description"), d.cfg.slot + f_description, .{ .required = true, .input = .{ .kind = .multiline, .name = "description" } });
        shell.modalFoot(ui);
        shell.modalButton(ui, L("common.cancel"), close, .{});
        shell.modalButton(ui, L("claims.open"), submit, .{ .variant = .primary, .busy = d.cfg.act + a_submit });
        shell.modalEnd(ui, true);
    }
};
