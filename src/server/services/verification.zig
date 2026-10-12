//! Carrier verification (src/services/verification.js): before Turf approves a new shipping
//! company it submits legal details and document photos; a platform admin reviews them in
//! Control and approves (the company goes live) or rejects with a reason.

const std = @import("std");
const val = @import("../lib/val.zig");
const db = @import("../lib/db.zig");
const web = @import("../web.zig");
const a_ = @import("../app.zig");
const tasks = @import("tasks.zig");
const audit = @import("audit.zig");
const moderation = @import("moderation.zig");
const Val = val.Val;
const Req = web.Req;
const V = web.V;
const Allocator = std.mem.Allocator;

const max_documents = 4;

/// What the carrier itself sees about its verification (no document bytes).
pub fn publicView(a: Allocator, org: Val) !Val {
    const v = org.get("verification");
    if (!v.truthy()) return val.from(a, .{ .status = "not_submitted" });
    return val.from(a, .{
        .status = v.get("status"),
        .legalName = v.get("legalName"),
        .registrationNumber = v.get("registrationNumber"),
        .ownerName = v.get("ownerName"),
        .ownerIdNumber = v.get("ownerIdNumber"),
        .address = v.get("address"),
        .phone = v.get("phone"),
        .notes = v.get("notes"),
        .documents = v.get("documentIds").items().len,
        .submittedAt = v.get("submittedAt"),
        .reviewNote = if (std.mem.eql(u8, v.s("status") orelse "", "rejected")) v.get("reviewNote") else Val.null,
    });
}

pub fn submit(r: *Req, ctx: *const web.OrgCtx, body: Val) !Val {
    const a = r.a;
    const org = ctx.org;
    if (!std.mem.eql(u8, org.s("status") orelse "", "pending")) return r.conflict("Your company is already reviewed", "already_reviewed", null);
    const b = (try V.obj(r, body, "body", .{})).?;
    const notes = try V.str(r, b.get("notes"), "notes", .{ .max = 1000, .optional = true });
    const fields = try val.from(a, .{
        .legalName = (try V.str(r, b.get("legalName"), "legalName", .{ .min = 2, .max = 120 })).?,
        .registrationNumber = (try V.str(r, b.get("registrationNumber"), "registrationNumber", .{ .min = 2, .max = 60 })).?,
        .ownerName = (try V.str(r, b.get("ownerName"), "ownerName", .{ .min = 2, .max = 120 })).?,
        .ownerIdNumber = (try V.str(r, b.get("ownerIdNumber"), "ownerIdNumber", .{ .min = 4, .max = 40 })).?,
        .address = (try V.str(r, b.get("address"), "address", .{ .min = 4, .max = 300 })).?,
        .phone = (try V.phone(r, b.get("phone"), "phone", .{})).?,
        .notes = if (notes) |n| (if (n.len > 0) Val{ .str = n } else Val.null) else Val.null,
    });

    // New photos replace the old ones; sending none keeps what was uploaded before.
    var document_ids = org.path("verification.documentIds");
    if (document_ids != .arr) document_ids = try val.newArr(a);
    if (b.get("documents") != .undef) {
        const docs = (try V.arr(r, b.get("documents"), "documents", .{ .max = max_documents })).?;
        if (docs.len > 0) {
            var buffers: std.ArrayList([]const u8) = .empty;
            for (docs, 0..) |d, i| {
                const buf = tasks.decodeJpeg(r, d) catch return r.badRequest("Each document must be a photo (JPEG, up to 400 KB)", try std.fmt.allocPrint(a, "documents[{d}]", .{i}), "photo_invalid", null);
                try buffers.append(a, buf);
            }
            // Photos and texts are checked before anything is stored.
            var images: std.ArrayList(moderation.Image) = .empty;
            for (buffers.items, 0..) |buf, i| try images.append(a, .{ .id = try std.fmt.allocPrint(a, "document{d}", .{i}), .bytes = buf });
            _ = try moderation.check(r, try val.from(a, .{ .userId = ctx.member.get("userId"), .name = ctx.member.get("name") }), .{ .type = "company", .id = try val.toStr(a, org.get("_id")), .field = "verification" }, try val.from(a, .{
                .legalName = fields.get("legalName"),
                .ownerName = fields.get("ownerName"),
                .address = fields.get("address"),
                .notes = fields.get("notes"),
            }), images.items);
            _ = try db.col("org_documents").deleteMany(a, .{ .orgId = org.get("_id") });
            const now = a_.now();
            var to_insert: std.ArrayList(Val) = .empty;
            for (buffers.items) |buf| try to_insert.append(a, try val.from(a, .{ .orgId = org.get("_id"), .contentType = "image/jpeg", .data = Val{ .bin = buf }, .size = buf.len, .createdAt = now }));
            document_ids = try val.arrOf(a, try db.col("org_documents").insertMany(a, to_insert.items));
        }
    }
    if (document_ids.items().len == 0) return r.badRequest("Add at least one photo of your documents", "documents", "documents_required", null);

    const verification = try val.spread(a, .{ fields, .{ .documentIds = document_ids, .status = "submitted", .submittedAt = a_.now(), .reviewNote = null } });
    _ = try db.col("orgs").updateOne(a, .{ ._id = org.get("_id") }, .{ .@"$set" = .{ .verification = verification, .updatedAt = a_.now() } }, .{});
    audit.audit(a, org.get("_id"), ctx.member, "org.verification_submitted", .{ .legalName = fields.get("legalName") });
    return publicView(a, try val.from(a, .{ .verification = verification }));
}

/// Full details for the platform admin.
pub fn adminView(r: *Req, org_id: Val) !Val {
    const a = r.a;
    const org = (try db.col("orgs").findOne(a, .{ ._id = org_id }, .{})) orelse return r.notFound("Organization");
    const v = org.get("verification");
    if (!v.truthy()) return val.from(a, .{ .status = "not_submitted", .documentIds = .{} });
    return val.spread(a, .{ try publicView(a, org), .{ .reviewNote = v.get("reviewNote"), .documentIds = if (v.get("documentIds").truthy()) v.get("documentIds") else try val.newArr(a), .reviewedAt = if (v.t("reviewedAt")) v.get("reviewedAt") else Val.null } });
}

pub fn getDocument(r: *Req, org_id: Val, document_id: Val) !Val {
    return (try db.col("org_documents").findOne(r.a, .{ ._id = document_id, .orgId = org_id }, .{})) orelse r.notFound("Document");
}

/// Approve (the company goes live) or reject with a reason the carrier will see.
pub fn review(r: *Req, org_id: Val, admin: Val, decision: []const u8, note: ?[]const u8) !void {
    const a = r.a;
    _ = (try db.col("orgs").findOne(a, .{ ._id = org_id, .type = "carrier" }, .{})) orelse return r.notFound("Organization");
    const now = a_.now();
    const n: Val = if (note) |x| (if (x.len > 0) Val{ .str = x } else .null) else .null;
    if (std.mem.eql(u8, decision, "approved")) {
        _ = try db.col("orgs").updateOne(a, .{ ._id = org_id }, .{ .@"$set" = .{ .status = "active", .@"verification.status" = "approved", .@"verification.reviewedAt" = now, .@"verification.reviewedBy" = admin.get("id"), .@"verification.reviewNote" = n, .updatedAt = now } }, .{});
    } else {
        if (n == .null) return r.badRequest("Tell the company why, so it can fix it", "note", "explain", null);
        _ = try db.col("orgs").updateOne(a, .{ ._id = org_id }, .{ .@"$set" = .{ .@"verification.status" = "rejected", .@"verification.reviewedAt" = now, .@"verification.reviewedBy" = admin.get("id"), .@"verification.reviewNote" = n, .updatedAt = now } }, .{});
    }
    audit.audit(a, org_id, admin, try std.fmt.allocPrint(a, "platform.verification_{s}", .{decision}), .{ .note = n });
}
