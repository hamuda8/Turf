//! An organization's audit log (src/services/audit.js).

const std = @import("std");
const val = @import("../lib/val.zig");
const db = @import("../lib/db.zig");
const a_ = @import("../app.zig");
const Val = val.Val;

/// Appends an entry. Never fails into the caller. `actor` is a user ({ id, email }), a
/// membership ({ userId, email }) or null for the system.
pub fn audit(a: std.mem.Allocator, org_id: Val, actor: Val, action: []const u8, details: anytype) void {
    const raw = val.from(a, details) catch return;
    // Details are always an object (an empty `.{}` literal arrives as an empty list).
    const d = if (raw == .arr and raw.items().len == 0) (val.newObj(a) catch return) else raw;
    const actor_doc: Val = if (actor.isNullish())
        (val.from(a, .{ .system = true }) catch return)
    else blk: {
        const id = actor.get("id");
        const uid = if (id.truthy()) id else if (actor.get("userId").truthy()) actor.get("userId") else Val.null;
        const email = if (actor.get("email").truthy()) actor.get("email") else Val.null;
        break :blk val.from(a, .{ .userId = uid, .email = email }) catch return;
    };
    _ = db.col("audit_log").insertOne(a, .{
        .orgId = org_id,
        .at = a_.now(),
        .actor = actor_doc,
        .action = action,
        .details = d,
    }) catch |e| std.log.err("Audit write failed: {t}", .{e});
}

pub fn listAudit(a: std.mem.Allocator, org_id: Val, before: ?i64) ![]Val {
    const q = try val.from(a, .{ .orgId = org_id });
    if (before) |b| try q.set("at", .{ .@"$lt" = val.Date{ .ms = b } });
    return db.col("audit_log").find(a, q, .{ .sort = try val.from(a, .{ .at = -1 }), .limit = 50 });
}
