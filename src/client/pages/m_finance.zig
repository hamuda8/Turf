//! Store finance (Turf-js views/merchant/finance.js): statements with each carrier (fees, cash
//! collected, payout) and Turf's fees.

const std = @import("std");
const core = @import("../core.zig");
const kit = @import("../kit.zig");
const labels = @import("../labels.zig");
const statements = @import("../widgets/statements.zig");

const Cx = core.Cx;
const Ui = core.Ui;
const L = labels.k;

const A = enum(u16) { csv = 1 };

pub const S = struct {
    st: statements.Statements = .{ .side = .merchant, .d_list = 0, .d_statement = 1, .d_fees = 2, .f_who = 0, .f_from = 1, .f_to = 2, .f_month = 3, .act_csv = @intFromEnum(A.csv) },
};

pub fn title(_: *const S, _: *const Cx) []const u8 {
    return L("statements.title");
}

pub fn enter(s: *S, c: *Cx) void {
    s.st.enter(c);
}

pub fn update(s: *S, c: *Cx, e: core.Ev) void {
    _ = s.st.update(c, e);
}

pub fn view(s: *const S, c: *const Cx, ui: *Ui) void {
    kit.stack(ui);
    s.st.view(c, ui);
    s.st.feesView(c, ui);
    ui.end();
}

// ---- Tests --------------------------------------------------------------------------------

const testing = std.testing;
const app = @import("../app.zig");

test "store finance: no carrier in the period, then a statement the store pays" {
    try app.startSignedIn("/o/acme/finance");
    defer app.D.reset();
    try testing.expect(app.D.respond("/api/app/orgs/o1", 200,
        \\{"id":"o1","type":"merchant","name":"Acme Store","slug":"acme","status":"active","me":{"permissions":["finance.view"]}}
    ));
    try testing.expect(app.D.respond("/merchant/statements?from=", 200, "{\"carriers\":[]}"));
    try testing.expect(app.D.respond("/platform-fees", 200, "{\"lines\":[]}"));
    try testing.expect(app.D.findText("No delivered or returned parcels in this period.") != 0);
    try testing.expect(app.D.findText("No Turf fees for this month.") != 0);
    // Another period.
    try app.D.typeInto("YYYY-MM-DD", "2025-01-01");
    try testing.expect(app.D.respond("/merchant/statements?from=", 200, "{\"carriers\":[{\"id\":\"c1\",\"name\":\"Fast\",\"shipments\":1}]}"));
    try testing.expect(app.D.respond("/merchant/statement?carrierId=c1", 200,
        \\{"currency":"SYP","totals":{"delivered":1,"returned":0,"shippingFees":5000,"codCollected":0,"payout":-5000},"rows":[]}
    ));
    try testing.expect(app.D.findText("You owe the shipping company 5,000 SYP (shipping fees above the cash collected).") != 0);
}
