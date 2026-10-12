//! Human-readable shipment statuses and tracking event texts (Arabic + English), returned by the
//! API next to machine-readable codes (src/messages.js).

const std = @import("std");
const val = @import("lib/val.zig");
const Val = val.Val;

pub const Text = struct { code: []const u8, en: []const u8, ar: []const u8 };

pub const statuses = [_]Text{
    .{ .code = "awaiting_carrier", .en = "Waiting for a shipping company", .ar = "بانتظار قبول شركة شحن" },
    .{ .code = "awaiting_pickup", .en = "Awaiting pickup", .ar = "بانتظار الاستلام من المتجر" },
    .{ .code = "picked_up", .en = "Picked up", .ar = "تم الاستلام من المتجر" },
    .{ .code = "at_hub", .en = "At shipping facility", .ar = "في مركز الشحن" },
    .{ .code = "in_transit", .en = "In transit", .ar = "قيد النقل" },
    .{ .code = "out_for_delivery", .en = "Out for delivery", .ar = "خرجت للتوصيل" },
    .{ .code = "delivered", .en = "Delivered", .ar = "تم التسليم" },
    .{ .code = "delivery_failed", .en = "Delivery attempt failed", .ar = "تعذّر التسليم" },
    .{ .code = "returning", .en = "Returning to sender", .ar = "قيد الإرجاع إلى المرسل" },
    .{ .code = "returned", .en = "Returned to sender", .ar = "أُعيدت إلى المرسل" },
    .{ .code = "cancelled", .en = "Cancelled", .ar = "ملغاة" },
    .{ .code = "lost", .en = "Lost", .ar = "مفقودة" },
};

pub const final_statuses = [_][]const u8{ "delivered", "returned", "cancelled", "lost" };

pub fn isFinal(status: []const u8) bool {
    return val.contains([]const u8, &final_statuses, status);
}

pub const vehicle_names = [_]Text{
    .{ .code = "foot", .en = "on foot", .ar = "سيراً على الأقدام" },
    .{ .code = "bicycle", .en = "by bicycle", .ar = "بالدراجة الهوائية" },
    .{ .code = "ebike", .en = "by e-bike", .ar = "بالدراجة الكهربائية" },
    .{ .code = "motorbike", .en = "by motorbike", .ar = "بالدراجة النارية" },
    .{ .code = "car", .en = "by car", .ar = "بالسيارة" },
    .{ .code = "van", .en = "by van", .ar = "بالشاحنة الصغيرة" },
    .{ .code = "truck", .en = "by truck", .ar = "بالشاحنة" },
};

pub const failure_reasons = [_]Text{
    .{ .code = "recipient_unreachable", .en = "the recipient could not be reached", .ar = "تعذّر التواصل مع المستلم" },
    .{ .code = "recipient_absent", .en = "nobody was available at the address", .ar = "لم يكن أحد متواجداً في العنوان" },
    .{ .code = "address_wrong", .en = "the address could not be found", .ar = "تعذّر العثور على العنوان" },
    .{ .code = "refused", .en = "the recipient refused the parcel", .ar = "رفض المستلم الطرد" },
    .{ .code = "reschedule_requested", .en = "the recipient asked to reschedule", .ar = "طلب المستلم تأجيل موعد التسليم" },
    .{ .code = "cod_unavailable", .en = "the cash payment was not ready", .ar = "لم يكن مبلغ الدفع عند الاستلام جاهزاً" },
    .{ .code = "unsafe_area", .en = "the area was not safe to access", .ar = "تعذّر الوصول إلى المنطقة بأمان" },
    .{ .code = "other", .en = "another reason", .ar = "سبب آخر" },
};

pub const failure_reason_codes = blk: {
    var out: []const []const u8 = &.{};
    for (failure_reasons) |f| out = out ++ &[_][]const u8{f.code};
    break :blk out;
};

const events = [_]Text{
    .{ .code = "created", .en = "Shipment information received from {merchant}", .ar = "تم استلام معلومات الشحنة من {merchant}" },
    .{ .code = "carrier_assigned", .en = "Assigned to {carrier}", .ar = "تم إسنادها إلى {carrier}" },
    .{ .code = "pickup_assigned", .en = "A courier is on the way to collect your parcel", .ar = "مندوب في طريقه لاستلام الطرد" },
    .{ .code = "picked_up", .en = "Picked up from the sender", .ar = "تم استلام الطرد من المرسل" },
    .{ .code = "arrived_at_hub", .en = "Arrived at {hub} facility, {city}", .ar = "وصلت إلى مركز {hub}، {city}" },
    .{ .code = "departed_hub", .en = "Departed {hub} facility, {city}", .ar = "غادرت مركز {hub}، {city}" },
    .{ .code = "out_for_delivery", .en = "Out for delivery with {courier} {vehicle}", .ar = "خرجت للتوصيل مع {courier} {vehicle}" },
    .{ .code = "delivered", .en = "Delivered", .ar = "تم التسليم" },
    .{ .code = "delivery_failed", .en = "Delivery attempt failed: {reason}", .ar = "تعذّر التسليم: {reason}" },
    .{ .code = "return_started", .en = "Returning to sender", .ar = "جارٍ إرجاع الطرد إلى المرسل" },
    .{ .code = "returned", .en = "Returned to sender", .ar = "أُعيد الطرد إلى المرسل" },
    .{ .code = "cancelled", .en = "Shipment cancelled", .ar = "تم إلغاء الشحنة" },
    .{ .code = "request_sent", .en = "Request sent to shipping companies", .ar = "تم إرسال الطلب إلى شركات الشحن" },
    .{ .code = "carrier_accepted", .en = "Accepted by {carrier}", .ar = "قبلت {carrier} الطلب" },
    .{ .code = "no_carrier_found", .en = "No shipping company was available. The request was cancelled.", .ar = "لم تتوفر شركة شحن، فأُلغي الطلب." },
    .{ .code = "details_updated", .en = "Delivery details updated ({fields})", .ar = "تم تحديث معلومات التسليم ({fields})" },
    .{ .code = "rescheduled", .en = "Delivery scheduled for {date}", .ar = "تم تحديد موعد التسليم في {date}" },
    .{ .code = "lost", .en = "Reported lost by the shipping company", .ar = "أبلغت شركة الشحن عن فقدان الطرد" },
    .{ .code = "damage_reported", .en = "Damage reported: {note}", .ar = "تم الإبلاغ عن ضرر: {note}" },
    .{ .code = "customer_return_requested", .en = "Return requested (return shipment {tracking})", .ar = "طُلب إرجاع الطرد (شحنة الإرجاع {tracking})" },
    .{ .code = "handed_over", .en = "Handed over from {from} to {to} at {hub}, {city}", .ar = "سُلّمت من {from} إلى {to} في مركز {hub}، {city}" },
    .{ .code = "handed_back", .en = "Handed back to {to} to return to the sender", .ar = "أُعيدت إلى {to} لإرجاعها إلى المرسل" },
    .{ .code = "recipient_location_set", .en = "The recipient shared an exact delivery location", .ar = "حدّد المستلم موقع التسليم بدقة" },
    .{ .code = "recipient_rated", .en = "The recipient rated the delivery {rating}/5", .ar = "قيّم المستلم التسليم {rating}/5" },
    .{ .code = "recipient_problem", .en = "The recipient reported a problem: {problem}", .ar = "أبلغ المستلم عن مشكلة: {problem}" },
    .{ .code = "note", .en = "{note}", .ar = "{note}" },
};

pub const problem_texts = [_]Text{
    .{ .code = "not_received", .en = "the parcel was not received", .ar = "لم يتم استلام الطرد" },
    .{ .code = "damaged", .en = "the parcel arrived damaged", .ar = "وصل الطرد تالفاً" },
    .{ .code = "missing_items", .en = "items are missing", .ar = "توجد أغراض ناقصة" },
    .{ .code = "courier_behaviour", .en = "the courier's behaviour", .ar = "سلوك المندوب" },
    .{ .code = "cod_wrong", .en = "the wrong amount was collected", .ar = "تم تحصيل مبلغ خاطئ" },
    .{ .code = "other", .en = "another problem", .ar = "مشكلة أخرى" },
};

pub fn find(list: []const Text, code: []const u8) ?Text {
    for (list) |t| if (std.mem.eql(u8, t.code, code)) return t;
    return null;
}

fn pick(t: Text, lang: []const u8) []const u8 {
    return if (std.mem.eql(u8, lang, "ar")) t.ar else t.en;
}

pub fn statusText(status: []const u8, lang: []const u8) []const u8 {
    const t = find(&statuses, status) orelse return status;
    return pick(t, lang);
}

pub fn isStatus(s: []const u8) bool {
    return find(&statuses, s) != null;
}

pub const status_list = blk: {
    var out: []const []const u8 = &.{};
    for (statuses) |s| out = out ++ &[_][]const u8{s.code};
    break :blk out;
};

/// The text of an event ({ code, params }) in `lang`.
pub fn eventText(a: std.mem.Allocator, event: Val, lang: []const u8) ![]const u8 {
    const code = event.s("code") orelse "";
    const tpl = if (find(&events, code)) |t| pick(t, lang) else code;
    const p = event.get("params");
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < tpl.len) {
        if (tpl[i] == '{') if (std.mem.indexOfScalarPos(u8, tpl, i, '}')) |close| {
            const name = tpl[i + 1 .. close];
            const word = for (name) |c| {
                if (!(std.ascii.isAlphanumeric(c) or c == '_')) break false;
            } else name.len > 0;
            if (word) {
                try out.appendSlice(a, try param(a, p, name, lang));
                i = close + 1;
                continue;
            }
        };
        try out.append(a, tpl[i]);
        i += 1;
    }
    // .replace(/\s+/g, ' ').replace(/[،,]\s*$/, '').trim()
    var collapsed: std.ArrayList(u8) = .empty;
    var in_space = false;
    for (out.items) |c| {
        if (std.ascii.isWhitespace(c)) {
            if (!in_space) try collapsed.append(a, ' ');
            in_space = true;
        } else {
            try collapsed.append(a, c);
            in_space = false;
        }
    }
    var s: []const u8 = collapsed.items;
    var trimmed = std.mem.trimEnd(u8, s, " ");
    if (std.mem.endsWith(u8, trimmed, ",")) {
        s = trimmed[0 .. trimmed.len - 1];
    } else if (std.mem.endsWith(u8, trimmed, "،")) {
        s = trimmed[0 .. trimmed.len - "،".len];
    }
    trimmed = val.jsTrim(s);
    return trimmed;
}

fn param(a: std.mem.Allocator, p: Val, name: []const u8, lang: []const u8) ![]const u8 {
    const v = p.get(name);
    if (std.mem.eql(u8, name, "vehicle")) {
        if (!v.truthy()) return "";
        const code = v.asStr() orelse return "";
        return if (find(&vehicle_names, code)) |t| pick(t, lang) else "";
    }
    if (std.mem.eql(u8, name, "reason") or std.mem.eql(u8, name, "problem")) {
        if (!v.truthy()) return "";
        const code = try val.toStr(a, v);
        const list: []const Text = if (name[0] == 'r') &failure_reasons else &problem_texts;
        return if (find(list, code)) |t| pick(t, lang) else code;
    }
    if (v.isNullish()) return "";
    return val.toStr(a, v);
}

/// STATUSES as the API sends it ({ code: { en, ar } }).
pub fn textsJson(a: std.mem.Allocator, list: []const Text) !Val {
    const out = try val.newObj(a);
    for (list) |t| try out.obj.put(t.code, try val.from(a, .{ .en = t.en, .ar = t.ar }));
    return out;
}

test eventText {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const e = try val.from(a, .{ .code = "out_for_delivery", .params = .{ .courier = "Sami", .vehicle = "car" } });
    try std.testing.expectEqualStrings("Out for delivery with Sami by car", try eventText(a, e, "en"));
    const h = try val.from(a, .{ .code = "arrived_at_hub", .params = .{ .hub = "Mazzeh" } });
    try std.testing.expectEqualStrings("Arrived at Mazzeh facility", try eventText(a, h, "en"));
}
