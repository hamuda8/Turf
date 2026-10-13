//! The recipient's feedback after delivery (src/services/feedback.js): a 1-5 rating with an
//! optional comment, and/or a problem report, sent once within FEEDBACK_DAYS of delivery.

const std = @import("std");
const val = @import("mongo").val;
const web = @import("../web.zig");
const a_ = @import("../app.zig");
const shipments_ = @import("shipments.zig");
const moderation = @import("moderation.zig");
const Val = val.Val;
const Req = web.Req;
const V = web.V;

pub const feedback_days = 14;
pub const problems = [_][]const u8{ "not_received", "damaged", "missing_items", "courier_behaviour", "cod_wrong", "other" };

pub fn canGiveFeedback(s: Val) bool {
    if (!std.mem.eql(u8, s.s("status") orelse "", "delivered") or s.t("feedback") or s.t("test")) return false;
    const at = s.get("deliveredAt").dateMs() orelse return false;
    return a_.nowMs() - at <= feedback_days * 86400_000;
}

/// Public view: what the recipient already sent, and whether they still can.
pub fn feedbackView(a: std.mem.Allocator, s: Val) !Val {
    const f = s.get("feedback");
    return val.from(a, .{
        .canGiveFeedback = canGiveFeedback(s),
        .feedback = if (f.truthy()) try val.from(a, .{ .rating = f.get("rating"), .problem = f.get("problem"), .at = f.get("at") }) else Val.null,
    });
}

pub fn submitFeedback(r: *Req, s: Val, body: Val) !Val {
    const a = r.a;
    _ = try V.obj(r, body, "body", .{});
    if (s.t("feedback")) return r.conflict("Feedback was already sent for this shipment", "feedback_sent", null);
    if (!canGiveFeedback(s)) return r.conflict("Feedback can be sent only after delivery, for 14 days", "feedback_closed", null);
    const rating = try V.num(r, body.get("rating"), "rating", .{ .min = 1, .max = 5, .integer = true, .optional = true });
    const problem = try V.oneOf(r, body.get("problem"), "problem", &problems, .{ .optional = true });
    const comment_raw = try V.str(r, body.get("comment"), "comment", .{ .max = 1000, .optional = true });
    const comment: Val = if (comment_raw) |c| (if (c.len > 0) Val{ .str = c } else .null) else .null;
    if (rating == null and problem == null) return r.conflict("Choose a rating or a problem", "feedback_empty", null);
    // The store and the carrier read the comment. The recipient is anonymous (no strikes).
    const outcome = try moderation.check(r, .null, .{ .type = "feedback", .id = try val.toStr(a, s.get("_id")), .field = "comment" }, try val.from(a, .{ .comment = comment }), &.{});
    const feedback = try val.from(a, .{
        .rating = if (rating) |x| Val{ .num = x } else Val.null,
        .problem = if (problem) |p| Val{ .str = p } else Val.null,
        .comment = comment,
        .at = a_.now(),
        .courierId = if (s.path("pod.courierId").truthy()) s.path("pod.courierId") else Val.null,
    });
    if (comment.truthy()) try feedback.set("moderation", try moderation.stamp(a, outcome));
    return shipments_.applyEvent(r, s, if (problem != null) "recipient_problem" else "recipient_rated", .{
        .actor = try val.from(a, .{ .type = "recipient" }),
        .params = try val.from(a, .{ .rating = if (rating) |x| Val{ .num = x } else Val{ .str = "-" }, .problem = problem orelse "" }),
        .set = try val.from(a, .{ .feedback = feedback }),
    });
}
