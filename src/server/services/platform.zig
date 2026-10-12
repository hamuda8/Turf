//! Platform-wide settings managed in Control (src/services/platform.js): store sign-up mode,
//! Turf's fees, feature switches and the announcement, in settings { _id: 'platform' }.

const std = @import("std");
const Io = std.Io;
const val = @import("../lib/val.zig");
const db = @import("../lib/db.zig");
const web = @import("../web.zig");
const a_ = @import("../app.zig");
const Val = val.Val;
const Req = web.Req;

pub const merchant_signup_modes = [_][]const u8{ "open", "approval", "closed" };
pub const fee_parties = [_][]const u8{ "carrier", "merchant" };
pub const fee_events = [_][]const u8{"delivered"};
pub const fee_types = [_][]const u8{ "percent", "fixed" };
pub const features = [_][]const u8{"directShipping"};

var lock: Io.Mutex = .init;
/// The merged settings as JSON (gpa), and when they were read.
var cache_json: ?[]u8 = null;
var cache_at: i64 = 0;

fn defaults(a: std.mem.Allocator) !Val {
    return val.from(a, .{
        .merchantSignup = a_.cfg().merchant_signup,
        .fees = .{},
        .features = .{ .directShipping = false },
        .announcement = null,
    });
}

/// The settings (cached for 30 s).
pub fn get(a: std.mem.Allocator) !Val {
    const io = a_.app.io;
    {
        lock.lockUncancelable(io);
        defer lock.unlock(io);
        if (cache_json) |j| if (a_.nowMs() - cache_at < 30_000) return val.parseJsonDates(a, j);
    }
    const doc = try db.col("settings").findOne(a, .{ ._id = "platform" }, .{});
    const d = try defaults(a);
    const merged = try val.spread(a, .{ d, doc orelse Val.undef });
    try merged.set("features", try val.spread(a, .{ d.get("features"), if (doc) |x| x.get("features") else Val.undef }));
    merged.del("_id");
    const text = try val.toJsonTyped(a, merged);
    lock.lockUncancelable(io);
    defer lock.unlock(io);
    if (cache_json) |old| a_.app.gpa.free(old);
    cache_json = a_.app.gpa.dupe(u8, text) catch null;
    cache_at = a_.nowMs();
    return merged;
}

pub fn clearCache() void {
    lock.lockUncancelable(a_.app.io);
    defer lock.unlock(a_.app.io);
    if (cache_json) |old| a_.app.gpa.free(old);
    cache_json = null;
}

/// Validates a list of fee rules (the admin screen or an org override).
pub fn validateFees(r: *Req, value: Val, field: []const u8) ![]Val {
    if (value != .arr or value.items().len > 20) return r.badRequest("Fees must be a list of up to 20 rules", field, null, null);
    var out: std.ArrayList(Val) = .empty;
    for (value.items(), 0..) |rule, i| {
        const f = try std.fmt.allocPrint(r.a, "{s}[{d}]", .{ field, i });
        if (rule != .obj) return r.badRequest("Invalid fee rule", f, null, null);
        const party = rule.s("party") orelse "";
        if (!val.contains([]const u8, &fee_parties, party)) return r.badRequest("Fee party must be carrier or merchant", try std.fmt.allocPrint(r.a, "{s}.party", .{f}), null, null);
        const event = rule.s("event") orelse "";
        if (!val.contains([]const u8, &fee_events, event)) return r.badRequest("Unknown fee event", try std.fmt.allocPrint(r.a, "{s}.event", .{f}), null, null);
        const t = rule.s("type") orelse "";
        if (!val.contains([]const u8, &fee_types, t)) return r.badRequest("Fee type must be percent or fixed", try std.fmt.allocPrint(r.a, "{s}.type", .{f}), null, null);
        const v = val.toNum(rule.get("value"));
        if (!std.math.isFinite(v) or v < 0 or (std.mem.eql(u8, t, "percent") and v > 100)) return r.badRequest("Invalid fee value", try std.fmt.allocPrint(r.a, "{s}.value", .{f}), null, null);
        const clean = try val.from(r.a, .{ .party = party, .event = event, .type = t, .value = v });
        if (std.mem.eql(u8, t, "fixed")) {
            const cur = rule.s("currency") orelse "";
            const ok = cur.len == 3 and for (cur) |c| {
                if (!std.ascii.isUpper(c)) break false;
            } else true;
            if (!ok) return r.badRequest("Fixed fees need a currency like SYP", try std.fmt.allocPrint(r.a, "{s}.currency", .{f}), null, null);
            try clean.set("currency", cur);
        }
        try out.append(r.a, clean);
    }
    return out.items;
}

pub fn update(r: *Req, patch: Val) !Val {
    const set = try val.newObj(r.a);
    const ms = patch.get("merchantSignup");
    if (ms != .undef) {
        const s = ms.asStr() orelse "";
        if (!val.contains([]const u8, &merchant_signup_modes, s)) return r.badRequest("Invalid sign-up mode", "merchantSignup", null, null);
        try set.set("merchantSignup", s);
    }
    if (patch.get("fees") != .undef) try set.set("fees", try validateFees(r, patch.get("fees"), "fees"));
    const fs = patch.get("features");
    if (fs != .undef) {
        const o = fs.asObj() orelse return r.badRequest("features must be an object", "features", null, null);
        for (o.keys.items, o.vals.items) |k, v| {
            if (!val.contains([]const u8, &features, k)) return r.badRequest(try std.fmt.allocPrint(r.a, "Unknown feature: {s}", .{k}), "features", null, null);
            const b = v.boolean() orelse return r.badRequest("Features are switched with true or false", try std.fmt.allocPrint(r.a, "features.{s}", .{k}), null, null);
            try set.set(try std.fmt.allocPrint(r.a, "features.{s}", .{k}), b);
        }
    }
    const an = patch.get("announcement");
    if (an != .undef) {
        const ar_t = an.get("ar");
        const en_t = an.get("en");
        const blank = struct {
            fn f(v: Val) bool {
                const s = v.asStr() orelse return true;
                return val.jsTrim(s).len == 0;
            }
        }.f;
        if (an == .null or (blank(ar_t) and blank(en_t))) {
            try set.set("announcement", null);
        } else {
            const text = struct {
                fn f(rq: *Req, v: Val, field: []const u8) ![]const u8 {
                    if (!v.isNullish() and v != .str) return rq.badRequest("Text expected", field, null, null);
                    return val.jsSlice(val.jsTrim(v.asStr() orelse ""), 300);
                }
            }.f;
            try set.set("announcement", .{
                .ar = try text(r, ar_t, "announcement.ar"),
                .en = try text(r, en_t, "announcement.en"),
                .level = if (std.mem.eql(u8, an.s("level") orelse "", "warn")) "warn" else "info",
            });
        }
    }
    if (set.obj.count() > 0) {
        try set.set("updatedAt", a_.now());
        _ = try db.col("settings").updateOne(r.a, .{ ._id = "platform" }, .{ .@"$set" = set }, .{ .upsert = true });
    }
    clearCache();
    return get(r.a);
}

/// Turf's fees for one shipment event. A company may be exempt or have its own rules
/// (org.platformFees = { exempt, rules }), which replace the platform rules for that party.
/// `carrier` (one) or `carriers` (relay) pay; the merchant pays on the whole price.
pub fn feesFor(a: std.mem.Allocator, event: []const u8, shipment: Val, carriers: []const Val, carrier: Val, merchant: Val) ![]Val {
    const settings = try get(a);
    const currency = shipment.path("price.currency");
    var out: std.ArrayList(Val) = .empty;
    const legs = shipment.get("legs");
    const Party = struct { party: []const u8, org: Val, basis: f64 };
    var parties: std.ArrayList(Party) = .empty;
    const payers: []const Val = if (carrier.truthy()) &.{carrier} else carriers;
    for (payers) |org| {
        var basis: f64 = 0;
        if (legs == .arr and legs.items().len > 1) {
            for (legs.items()) |l| if (l.get("carrierId").sameId(org.get("_id"))) {
                basis += l.path("price.amount").asNum() orelse 0;
            };
        } else basis = shipment.path("price.amount").asNum() orelse 0;
        try parties.append(a, .{ .party = "carrier", .org = org, .basis = basis });
    }
    try parties.append(a, .{ .party = "merchant", .org = merchant, .basis = shipment.path("price.amount").asNum() orelse 0 });
    for (parties.items) |p| {
        if (!p.org.truthy() or p.org.path("platformFees.exempt").truthy()) continue;
        const own = p.org.path("platformFees.rules");
        const rules = if (!own.isNullish()) own else settings.get("fees");
        for (rules.items()) |rule| {
            if (!std.mem.eql(u8, rule.s("party") orelse "", p.party) or !std.mem.eql(u8, rule.s("event") orelse "", event)) continue;
            var amount: f64 = 0;
            const value = rule.n("value") orelse 0;
            if (std.mem.eql(u8, rule.s("type") orelse "", "percent")) {
                amount = val.jsRound((p.basis * value) / 100);
            } else if (rule.get("currency").eql(currency) or (rule.get("currency") == .str and currency == .str and std.mem.eql(u8, rule.s("currency").?, currency.str))) {
                amount = val.jsRound(value);
            }
            if (amount > 0) try out.append(a, try val.from(a, .{ .party = p.party, .orgId = p.org.get("_id"), .orgName = p.org.get("name"), .amount = amount, .currency = currency, .rule = rule, .at = a_.now() }));
        }
    }
    return out.items;
}

/// Whether a feature is switched on (cached for 30 s).
pub fn featureOn(a: std.mem.Allocator, name: []const u8) !bool {
    return (try get(a)).get("features").get(name).truthy();
}

/// What every page may know: switched-on features and the announcement.
pub fn publicInfo(a: std.mem.Allocator) !Val {
    const s = try get(a);
    return val.from(a, .{ .features = s.get("features"), .announcement = s.get("announcement") });
}
