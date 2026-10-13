//! Owner only: close the company for good (Turf-js views/shared/close-company.js), shown at the
//! bottom of the carrier and merchant settings. The page keeps a `CloseCompany` in its state,
//! gives it three action ids from `base`, a data slot and a form slot, passes it its events
//! (`update` returns true when it used the event), draws `card` and, in `overlay`, `dialog`.

const std = @import("std");
const zui = @import("zui");
const core = @import("../core.zig");
const kit = @import("../kit.zig");
const shell = @import("../shell.zig");
const json = @import("../json.zig");
const icons = @import("../icons.zig");
const labels = @import("../labels.zig");
const cm = @import("common.zig");

const Cx = core.Cx;
const Ui = core.Ui;
const L = labels.k;

pub const CloseCompany = struct {
    /// Action ids: base (open), base + 1 (close the dialog), base + 2 (close the company).
    base: u16,
    slot: u8,
    field: u16,
    open: bool = false,

    pub fn update(cc: *CloseCompany, c: *Cx, e: core.Ev) bool {
        switch (e) {
            .act => |a| {
                if (a.id == cc.base) {
                    c.send(cc.base, .GET, c.orgUrl("/close"), "");
                } else if (a.id == cc.base + 1) {
                    cc.open = false;
                } else if (a.id == cc.base + 2) {
                    var b = json.Obj.init(c.arena());
                    b.str("confirmName", c.val(cc.field));
                    c.send(cc.base + 2, .POST, c.orgUrl("/close"), b.done());
                } else return false;
                return true;
            },
            .done => |d| {
                if (d.id == cc.base) {
                    if (d.ok) {
                        cm.keep(c, cc.slot, d.body);
                        c.setVal(cc.field, "");
                        c.clearFieldError();
                        cc.open = true;
                    }
                } else if (d.id == cc.base + 2) {
                    if (d.ok) {
                        cc.open = false;
                        c.openLink("/app");
                    }
                } else return false;
                return true;
            },
            else => return false,
        }
    }

    /// The danger-zone card (owners only).
    pub fn card(cc: *const CloseCompany, c: *const Cx, ui: *Ui) void {
        if (!json.boolean(c.orgV(), "me.isOwner")) return;
        cm.dangerCard(ui);
        kit.h2(ui, L("close.title"));
        kit.muted(ui, L("close.hint"));
        kit.button(ui, L("close.title"), .{ .act = .{ .id = cc.base } }, .{ .variant = .danger, .size = .sm, .busy = cc.base });
        kit.endCard(ui, .{});
    }

    pub fn dialog(cc: *const CloseCompany, c: *const Cx, ui: *Ui) void {
        if (!cc.open) return;
        const b = c.data(cc.slot);
        const name = json.str(c.orgV(), "name");
        const close: core.Msg = .{ .act = .{ .id = cc.base + 1 } };
        shell.modalBegin(ui, .{ .title = L("close.title"), .close = close, .key = zui.key("close-company") });
        kit.text(ui, L("close.intro"), .{});
        const shipments = json.int(b, "openShipments");
        const cash = json.int(b, "unpaidCash");
        if (shipments != 0 or cash != 0) {
            kit.noticeBegin(ui, .warn, icons.warning);
            kit.strong(ui, L("close.first"));
            if (shipments != 0) cm.bullet(ui, cm.tx(ui, "close.blocker_shipments", .{ .n = shipments }));
            if (cash != 0) cm.bullet(ui, cm.tx(ui, "close.blocker_cash", .{ .n = cash }));
            kit.noticeEnd(ui);
            shell.modalFoot(ui);
            shell.modalButton(ui, L("common.close"), close, .{});
        } else {
            kit.field(ui, cm.tx(ui, "close.type_name", .{ .name = name }), cc.field, .{ .input = .{ .placeholder = name, .name = "confirmName", .on_submit = .{ .act = .{ .id = cc.base + 2 } } } });
            shell.modalFoot(ui);
            shell.modalButton(ui, L("common.cancel"), close, .{});
            shell.modalButton(ui, L("close.button"), .{ .act = .{ .id = cc.base + 2 } }, .{ .variant = .danger, .busy = cc.base + 2 });
        }
        shell.modalEnd(ui, true);
    }
};
