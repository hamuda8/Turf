//! Bridges domain events to live browser streams (src/services/live.js).

const std = @import("std");
const val = @import("mongo").val;
const db = @import("../lib/db.zig");
const web = @import("../web.zig");
const realtime = @import("../realtime.zig");
const messages = @import("../messages.zig");
const shipments = @import("shipments.zig");
const push = @import("push.zig");
const Val = val.Val;
const Req = web.Req;

fn shipmentSummary(a: std.mem.Allocator, s: Val) !Val {
    return val.from(a, .{
        .id = s.get("_id"),
        .trackingNumber = s.get("trackingNumber"),
        .status = s.get("status"),
        .merchantName = s.get("merchantName"),
        .carrierName = s.get("carrierName"),
        .dropoffGovernorate = s.path("dropoff.governorate"),
        .updatedAt = s.get("updatedAt"),
    });
}

fn orNull(v: Val) Val {
    return if (v.isNullish()) .null else v;
}

pub fn courierSummary(a: std.mem.Allocator, c: Val) !Val {
    return val.from(a, .{
        .courierId = c.get("_id"),
        .name = c.get("name"),
        .vehicle = if (c.path("courier.vehicle").truthy()) c.path("courier.vehicle") else Val.null,
        .onDuty = c.path("duty.onDuty").truthy(),
        .location = try web.toLatLng(a, c.get("lastLocation")),
        .at = if (c.get("lastLocationAt").truthy()) c.get("lastLocationAt") else Val.null,
        .heading = orNull(c.get("lastHeading")),
        .speedKmh = orNull(c.get("lastSpeedKmh")),
        .battery = orNull(c.get("lastBattery")),
        .appState = if (c.path("appState.state").truthy()) c.path("appState.state") else Val.null,
        .appStateAt = if (c.path("appState.at").truthy()) c.path("appState.at") else Val.null,
    });
}

fn chan(a: std.mem.Allocator, p: []const u8, id: Val) []const u8 {
    return realtime.chan(a, p, id);
}

/// Direct requests: tell the offered company.
pub fn onDirectOffer(r: *Req, e: Val) !void {
    const a = r.a;
    const s = e.get("shipment");
    const carrier_id = e.get("carrierId");
    realtime.publish(chan(a, "carrier", carrier_id), "direct.request", try val.from(a, .{ .id = s.get("_id"), .trackingNumber = s.get("trackingNumber") }));
    push.sendToMembersWith(a, carrier_id, "carrier", "dispatch.manage", try val.from(a, .{
        .title = "Turf",
        .body = try std.fmt.allocPrint(a, "New delivery request: {s} → {s}", .{ try val.toStr(a, s.path("pickup.city")), try val.toStr(a, s.path("dropoff.city")) }),
        .url = "/",
        .tag = try std.fmt.allocPrint(a, "req-{s}", .{try val.toStr(a, s.get("_id"))}),
        .urgent = true,
    }), .{}) catch {};
}

/// ... and the sender when it is answered.
pub fn onDirectAnswered(r: *Req, e: Val) !void {
    const a = r.a;
    const s = e.get("shipment");
    realtime.publish(chan(a, "merchant", s.get("merchantId")), "shipment.updated", try val.from(a, .{ .id = s.get("_id"), .status = s.get("status") }));
    if (!s.t("senderUserId")) return;
    const tn = try val.toStr(a, s.get("trackingNumber"));
    push.sendToUser(a, s.get("senderUserId"), try val.from(a, .{
        .title = "Turf",
        .body = if (e.t("accepted")) try std.fmt.allocPrint(a, "{s} accepted your parcel {s}", .{ try val.toStr(a, s.get("carrierName")), tn }) else try std.fmt.allocPrint(a, "No shipping company was available for {s}", .{tn}),
        .url = try std.fmt.allocPrint(a, "/app/parcels/{s}", .{try val.toStr(a, s.get("_id"))}),
        .tag = try std.fmt.allocPrint(a, "parcel-{s}", .{try val.toStr(a, s.get("_id"))}),
    }));
}

pub fn onShipmentCreated(r: *Req, e: Val) !void {
    const a = r.a;
    const s = e.get("shipment");
    const summary = try shipmentSummary(a, s);
    realtime.publish(chan(a, "carrier", s.get("carrierId")), "shipment.created", summary);
    realtime.publish(chan(a, "merchant", s.get("merchantId")), "shipment.created", summary);
}

pub fn onShipmentEvent(r: *Req, e: Val) !void {
    const a = r.a;
    const s = e.get("shipment");
    const event = e.get("event");
    const summary = try val.spread(a, .{ try shipmentSummary(a, s), .{ .code = event.get("code") } });
    realtime.publish(chan(a, "carrier", s.get("carrierId")), "shipment.updated", summary);
    if (event.t("internal")) return;
    realtime.publish(chan(a, "merchant", s.get("merchantId")), "shipment.updated", summary);
    const status = s.s("status") orelse "";
    realtime.publish(chan(a, "shipment", s.get("_id")), "tracking.event", try val.from(a, .{
        .status = s.get("status"),
        .statusTextAr = messages.statusText(status, "ar"),
        .statusTextEn = messages.statusText(status, "en"),
        .event = .{
            .code = event.get("code"),
            .at = event.get("at"),
            .textAr = try messages.eventText(a, event, "ar"),
            .textEn = try messages.eventText(a, event, "en"),
            .location = try web.toLatLng(a, event.get("location")),
        },
    }));
}

pub fn onTaskChanged(r: *Req, e: Val) !void {
    const a = r.a;
    const payload = try val.from(a, .{ .taskId = e.get("taskId") });
    realtime.publish(chan(a, "carrier", e.get("carrierId")), "task.changed", payload);
    const courier_id = e.get("courierId");
    if (courier_id.truthy()) realtime.publish(chan(a, "courier", courier_id), "task.changed", payload);
    const prev = e.get("previousCourierId");
    if (prev.truthy() and !prev.sameId(courier_id)) realtime.publish(chan(a, "courier", prev), "task.changed", payload);
}

pub fn onCourierPosition(r: *Req, e: Val) !void {
    const a = r.a;
    const courier = e.get("courier");
    realtime.publish(chan(a, "fleet", courier.get("orgId")), "courier.position", try courierSummary(a, courier));
    const tasks = try db.col("tasks").find(a, .{ .courierId = courier.get("_id"), .status = "in_progress" }, .{});
    for (tasks) |task| {
        const list = try db.col("shipments").find(a, .{ ._id = .{ .@"$in" = task.get("shipmentIds") } }, .{ .projection = try val.from(a, .{ .dropoff = 1 }) });
        for (list) |s| realtime.publish(chan(a, "shipment", s.get("_id")), "courier.position", try shipments.courierLiveView(a, courier, task, s));
    }
}

pub fn onCourierDuty(r: *Req, e: Val) !void {
    const courier = e.get("courier");
    realtime.publish(chan(r.a, "fleet", courier.get("orgId")), "courier.duty", try courierSummary(r.a, courier));
}

pub fn onAlert(r: *Req, e: Val) !void {
    const alert = e.get("alert");
    realtime.publish(chan(r.a, "alerts", alert.get("carrierId")), "alert", try val.spread(r.a, .{ alert, .{ .location = try web.toLatLng(r.a, alert.get("location")) } }));
}
