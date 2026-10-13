//! Turn-by-turn routes from Wufour Maps (src/services/routing.js), proxied so the API key stays on
//! the server and answers can be cached.

const std = @import("std");
const Io = std.Io;
const val = @import("mongo").val;
const web = @import("../web.zig");
const a_ = @import("../app.zig");
const Val = val.Val;
const Req = web.Req;

const cache_ms = 10 * 60_000;
const max_cache = 500;
const vehicles = [_][]const u8{ "car", "motorcycle", "truck", "bicycle", "walk" };

var lock: Io.Mutex = .init;
var cache: std.StringArrayHashMapUnmanaged(struct { json: []u8, until: i64 }) = .empty;

/// About 11 m: nearby requests share a cache entry.
fn round4(x: f64) f64 {
    return val.jsRound(x * 1e4) / 1e4;
}

pub fn route(r: *Req, vehicle: []const u8, from_lat: f64, from_lng: f64, to_lat: f64, to_lng: f64) !Val {
    const a = r.a;
    if (!val.contains([]const u8, &vehicles, vehicle)) return r.fail(400, "invalid_request", "Unknown routing vehicle", .{});
    const coords = try std.fmt.allocPrint(a, "from={s},{s}&to={s},{s}", .{
        try val.numStr(a, round4(from_lat)), try val.numStr(a, round4(from_lng)), try val.numStr(a, round4(to_lat)), try val.numStr(a, round4(to_lng)),
    });
    const key = try std.fmt.allocPrint(a, "{s}:{s}", .{ vehicle, coords });
    const io = a_.app.io;
    {
        lock.lockUncancelable(io);
        defer lock.unlock(io);
        if (cache.get(key)) |hit| if (hit.until > a_.nowMs()) return val.parseJsonDates(a, hit.json);
    }
    const url = try std.fmt.allocPrint(a, "{s}/api/v1/route?{s}&vehicle={s}", .{ a_.cfg().maps_internal_url, coords, vehicle });
    const res = a_.upstreamTimeout(a, url, .{ .headers = &.{.{ .name = "x-maps-api-key", .value = a_.cfg().maps_api_key }} }, 12_000) catch
        return r.fail(502, "routing_unavailable", "The routing service is not reachable right now", .{});
    const data = val.parseJson(a, res.body) catch return r.fail(502, "routing_unavailable", "The routing service is not reachable right now", .{});
    const status = @backingInt(res.status);
    if (status == 422) return r.fail(422, "no_route", "No route was found between these points", .{});
    if (status < 200 or status >= 300 or !data.get("success").truthy()) {
        if (status == 401) std.log.err("Wufour Maps rejected the API key: check MAPS_API_KEY", .{});
        return r.fail(502, "routing_unavailable", "The routing service is not reachable right now", .{});
    }
    const rt = data.get("route");
    const value = try val.from(a, .{ .profile = vehicle, .distanceM = rt.get("distanceM"), .durationS = rt.get("durationS"), .geometry = rt.get("geometry"), .steps = rt.get("steps") });
    const text = try val.toJsonTyped(a, value);
    const gpa = a_.app.gpa;
    lock.lockUncancelable(io);
    defer lock.unlock(io);
    if (cache.count() >= max_cache) {
        const k0 = cache.keys()[0];
        const v0 = cache.values()[0];
        cache.orderedRemoveAt(0);
        gpa.free(k0);
        gpa.free(v0.json);
    }
    if (cache.fetchOrderedRemove(key)) |old| {
        gpa.free(old.key);
        gpa.free(old.value.json);
    }
    const k = gpa.dupe(u8, key) catch return value;
    const j = gpa.dupe(u8, text) catch {
        gpa.free(k);
        return value;
    };
    cache.put(gpa, k, .{ .json = j, .until = a_.nowMs() + cache_ms }) catch {
        gpa.free(k);
        gpa.free(j);
    };
    return value;
}
