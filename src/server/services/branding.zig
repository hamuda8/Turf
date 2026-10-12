//! White-label branding (src/services/branding.js): names, colors, logo and app icons. The
//! browser rasterizes the logo into PNGs; the server only accepts real PNG bytes, so
//! user-supplied SVG or HTML is never served from our origin.

const std = @import("std");
const val = @import("../lib/val.zig");
const db = @import("../lib/db.zig");
const web = @import("../web.zig");
const a_ = @import("../app.zig");
const audit = @import("audit.zig");
const moderation = @import("moderation.zig");
const Val = val.Val;
const Req = web.Req;

pub const AssetKind = struct { name: []const u8, max_bytes: usize, size: ?u32 };

pub const asset_kinds = [_]AssetKind{
    .{ .name = "logo", .max_bytes = 400_000, .size = null },
    .{ .name = "icon192", .max_bytes = 150_000, .size = 192 },
    .{ .name = "icon512", .max_bytes = 400_000, .size = 512 },
    .{ .name = "maskable192", .max_bytes = 150_000, .size = 192 },
    .{ .name = "maskable512", .max_bytes = 400_000, .size = 512 },
};

const asset_names = blk: {
    var out: []const []const u8 = &.{};
    for (asset_kinds) |k| out = out ++ &[_][]const u8{k.name};
    break :blk out;
};

const png_signature = "\x89PNG\r\n\x1a\n";
const prefix = "data:image/png;base64,";

fn decodePng(r: *Req, data_url: Val, kind: AssetKind) ![]const u8 {
    const s = data_url.asStr() orelse "";
    if (!std.mem.startsWith(u8, s, prefix)) return r.badRequest(try std.fmt.allocPrint(r.a, "{s} must be a PNG data URL", .{kind.name}), kind.name, "png_invalid", null);
    const buf = base64Loose(r.a, s[prefix.len..]) catch return r.badRequest(try std.fmt.allocPrint(r.a, "{s} is not a valid PNG", .{kind.name}), kind.name, "png_invalid", null);
    if (buf.len < 8 or !std.mem.eql(u8, buf[0..8], png_signature)) return r.badRequest(try std.fmt.allocPrint(r.a, "{s} is not a valid PNG", .{kind.name}), kind.name, "png_invalid", null);
    if (buf.len > kind.max_bytes) return r.badRequest(try std.fmt.allocPrint(r.a, "{s} is too large", .{kind.name}), kind.name, "file_too_large", null);
    // The IHDR chunk follows the signature: length(4) "IHDR"(4) width(4) height(4)
    if (buf.len < 24 or !std.mem.eql(u8, buf[12..16], "IHDR")) return r.badRequest(try std.fmt.allocPrint(r.a, "{s} is not a valid PNG", .{kind.name}), kind.name, "png_invalid", null);
    const w = std.mem.readInt(u32, buf[16..20], .big);
    const h = std.mem.readInt(u32, buf[20..24], .big);
    if (kind.size) |size| {
        if (w != size or h != size) return r.badRequest(try std.fmt.allocPrint(r.a, "{s} must be {d}x{d}", .{ kind.name, size, size }), kind.name, "png_size", .{ .size = size });
    } else if (w > 1024 or h > 1024) return r.badRequest("logo must be at most 1024px", kind.name, "png_max", .{ .size = 1024 });
    return buf;
}

/// Buffer.from(s, 'base64'): ignores characters outside the alphabet and missing padding.
pub fn base64Loose(a: std.mem.Allocator, s: []const u8) ![]u8 {
    var clean: std.ArrayList(u8) = .empty;
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '+' or c == '/') try clean.append(a, c) else if (c == '-') try clean.append(a, '+') else if (c == '_') try clean.append(a, '/') else if (c == '=') break;
    }
    // A single dangling character carries no whole byte.
    if (clean.items.len % 4 == 1) clean.items.len -= 1;
    const D = std.base64.standard_no_pad.Decoder;
    const out = try a.alloc(u8, try D.calcSizeForSlice(clean.items));
    try D.decode(out, clean.items);
    return out;
}

pub fn updateBranding(r: *Req, ctx: *const web.OrgCtx, app_name: ?[]const u8, short_name: ?[]const u8, primary: ?[]const u8, accent: ?[]const u8) !void {
    const a = r.a;
    const set = try val.newObj(a);
    if (app_name) |x| try set.set("branding.appName", x);
    if (short_name) |x| try set.set("branding.shortName", x);
    if (primary) |x| try set.set("branding.primaryColor", x);
    if (accent) |x| try set.set("branding.accentColor", x);
    if (set.obj.count() == 0) return;
    if (app_name != null or short_name != null) {
        // Names people see on labels, tracking pages and the white-label app.
        const texts = try val.from(a, .{ .appName = app_name, .shortName = short_name });
        const outcome = try moderation.check(r, try val.from(a, .{ .userId = ctx.member.get("userId"), .name = ctx.member.get("name") }), .{ .type = "company", .id = try val.toStr(a, ctx.org.get("_id")), .field = "branding" }, texts, &.{});
        _ = try moderation.applyOrgModeration(a, ctx.org.get("_id"), "branding", outcome);
    }
    try set.set("updatedAt", a_.now());
    _ = try db.col("orgs").updateOne(a, .{ ._id = ctx.org.get("_id") }, .{ .@"$set" = set }, .{});
    audit.audit(a, ctx.org.get("_id"), ctx.member, "branding.updated", .{ .appName = app_name, .shortName = short_name, .primaryColor = primary, .accentColor = accent });
}

/// Stores a full logo set. All five images are required so icons always match the logo.
pub fn saveLogo(r: *Req, ctx: *const web.OrgCtx, images: Val) ![]const u8 {
    const a = r.a;
    var decoded: [asset_kinds.len][]const u8 = undefined;
    for (asset_kinds, 0..) |k, i| decoded[i] = try decodePng(r, images.get(k.name), k);

    const outcome = try moderation.check(r, try val.from(a, .{ .userId = ctx.member.get("userId"), .name = ctx.member.get("name") }), .{ .type = "company", .id = try val.toStr(a, ctx.org.get("_id")), .field = "logo" }, .undef, &.{.{ .id = "logo", .bytes = decoded[0] }});

    const now_ms = a_.nowMs();
    const now: Val = .{ .date = now_ms };
    for (asset_kinds, 0..) |k, i| {
        _ = try db.col("assets").updateOne(a, .{ .orgId = ctx.org.get("_id"), .kind = k.name }, .{
            .@"$set" = .{ .contentType = "image/png", .data = Val{ .bin = decoded[i] }, .size = decoded[i].len, .updatedAt = now },
        }, .{ .upsert = true });
    }
    const version = try base36(a, @intCast(now_ms));
    _ = try db.col("orgs").updateOne(a, .{ ._id = ctx.org.get("_id") }, .{ .@"$set" = .{ .@"branding.assetsVersion" = version, .updatedAt = now } }, .{});
    _ = try moderation.applyOrgModeration(a, ctx.org.get("_id"), "logo", outcome);
    audit.audit(a, ctx.org.get("_id"), ctx.member, "branding.logo_updated", .{});
    return version;
}

/// Number.prototype.toString(36)
pub fn base36(a: std.mem.Allocator, n_: u64) ![]const u8 {
    const digits = "0123456789abcdefghijklmnopqrstuvwxyz";
    var buf: [16]u8 = undefined;
    var i: usize = buf.len;
    var n = n_;
    if (n == 0) return "0";
    while (n > 0) : (n /= 36) {
        i -= 1;
        buf[i] = digits[n % 36];
    }
    return a.dupe(u8, buf[i..]);
}

pub fn removeLogo(r: *Req, ctx: *const web.OrgCtx) !void {
    const a = r.a;
    _ = try db.col("assets").deleteMany(a, .{ .orgId = ctx.org.get("_id"), .kind = .{ .@"$in" = asset_names } });
    _ = try db.col("orgs").updateOne(a, .{ ._id = ctx.org.get("_id") }, .{ .@"$set" = .{ .@"branding.assetsVersion" = null, .updatedAt = a_.now() } }, .{});
    _ = try moderation.applyOrgModeration(a, ctx.org.get("_id"), "logo", try val.from(a, .{ .layer = 3, .reasons = .{} }));
    audit.audit(a, ctx.org.get("_id"), ctx.member, "branding.logo_removed", .{});
}

pub fn getAsset(a: std.mem.Allocator, org_id: Val, kind: []const u8) !?Val {
    if (!val.contains([]const u8, asset_names, kind)) return null;
    return db.col("assets").findOne(a, .{ .orgId = org_id, .kind = kind }, .{});
}

/// Text color (black or white) readable on top of the given hex background.
pub fn readableOn(hex: []const u8) []const u8 {
    const n: u32 = if (hex.len > 1) parseHexPrefix(hex[1..]) else 0;
    const channel = struct {
        fn f(c: u32) f64 {
            const s = @as(f64, @floatFromInt(c)) / 255.0;
            return if (s <= 0.03928) s / 12.92 else std.math.pow(f64, (s + 0.055) / 1.055, 2.4);
        }
    }.f;
    const l = 0.2126 * channel((n >> 16) & 255) + 0.7152 * channel((n >> 8) & 255) + 0.0722 * channel(n & 255);
    return if ((1.05 / (l + 0.05)) >= ((l + 0.05) / 0.05)) "#ffffff" else "#111827";
}

/// parseInt(s, 16): leading hex digits.
fn parseHexPrefix(s: []const u8) u32 {
    var n: u32 = 0;
    for (s) |c| {
        const d = std.fmt.charToDigit(c, 16) catch break;
        n = n *% 16 +% d;
    }
    return n;
}

/// Public, safe-to-expose branding for an org (pages, manifests and tracking).
pub fn publicBranding(a: std.mem.Allocator, org: Val) !Val {
    const b = org.get("branding");
    const slug = try val.toStr(a, org.get("slug"));
    const v = b.get("assetsVersion");
    const name = org.s("name") orelse "";
    const has = v.truthy();
    const vs = if (has) try val.toStr(a, v) else "";
    const asset = struct {
        fn f(al: std.mem.Allocator, s: []const u8, kind: []const u8, ver: []const u8) ![]const u8 {
            return std.fmt.allocPrint(al, "/o/{s}/asset/{s}.png?v={s}", .{ s, kind, ver });
        }
    }.f;
    const primary = b.get("primaryColor");
    return val.from(a, .{
        .name = org.get("name"),
        .slug = org.get("slug"),
        .appName = if (b.get("appName").truthy()) b.get("appName") else org.get("name"),
        .shortName = if (b.get("shortName").truthy()) b.get("shortName") else Val{ .str = val.jsSlice(name, 12) },
        .primaryColor = primary,
        .accentColor = b.get("accentColor"),
        .onPrimary = readableOn(primary.asStr() orelse ""),
        .logoUrl = if (has) Val{ .str = try asset(a, slug, "logo", vs) } else Val.null,
        .icon192 = if (has) try asset(a, slug, "icon192", vs) else "/img/icon-192.png",
        .icon512 = if (has) try asset(a, slug, "icon512", vs) else "/img/icon-512.png",
        .maskable192 = if (has) try asset(a, slug, "maskable192", vs) else "/img/maskable-192.png",
        .maskable512 = if (has) try asset(a, slug, "maskable512", vs) else "/img/maskable-512.png",
    });
}
