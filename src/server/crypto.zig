//! Tokens, hashes, readable codes and secret encryption (src/crypto.js). Encrypted secrets use
//! the same key derivation and text format, so values written by Turf-js stay readable.

const std = @import("std");
const a_ = @import("app.zig");
const Allocator = std.mem.Allocator;
const b64url = std.base64.url_safe_no_pad;

/// `bytes` random bytes as base64url text.
pub fn randomToken(a: Allocator, comptime bytes: usize) ![]const u8 {
    var raw: [bytes]u8 = undefined;
    a_.random(&raw);
    const out = try a.alloc(u8, b64url.Encoder.calcSize(bytes));
    return b64url.Encoder.encode(out, &raw);
}

pub fn sha256(a: Allocator, value: []const u8) ![]const u8 {
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(value, &d, .{});
    return a.dupe(u8, &std.fmt.bytesToHex(d, .lower));
}

/// Crockford base32: no I, L, O, U, so numbers are easy to read aloud over the phone.
const readable = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

pub fn readableCode(a: Allocator, length: usize) ![]const u8 {
    const bytes = try a.alloc(u8, length);
    a_.random(bytes);
    for (bytes) |*b| b.* = readable[b.* % 32];
    return bytes;
}

/// Shipment tracking number, e.g. TRF4K7M9Q2XAB
pub fn newTrackingNumber(a: Allocator) ![]const u8 {
    return std.fmt.allocPrint(a, "TRF{s}", .{try readableCode(a, 10)});
}

/// Uniform integer in [0, n).
pub fn randomInt(n: u64) u64 {
    var b: [8]u8 = undefined;
    while (true) {
        a_.random(&b);
        const x = std.mem.readInt(u64, &b, .little);
        const limit = std.math.maxInt(u64) - (std.math.maxInt(u64) % n);
        if (x < limit) return x % n;
    }
}

/// The 4-digit code the recipient gives the courier at handover.
pub fn newDeliveryCode(a: Allocator) ![]const u8 {
    return std.fmt.allocPrint(a, "{d:0>4}", .{randomInt(10000)});
}

pub const ApiKey = struct { secret: []const u8, hash: []const u8, prefix: []const u8 };

/// Test keys (turf_test_...) only create practice shipments.
pub fn newApiKey(a: Allocator, mode: []const u8) !ApiKey {
    const secret = try std.fmt.allocPrint(a, "{s}{s}", .{ if (std.mem.eql(u8, mode, "test")) "turf_test_" else "turf_sk_", try randomToken(a, 32) });
    return .{ .secret = secret, .hash = try sha256(a, secret), .prefix = secret[0..14] };
}

const Aes = std.crypto.aead.aes_gcm.Aes256Gcm;

fn aesKey() [32]u8 {
    var k: [32]u8 = undefined;
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update("turf-at-rest:");
    h.update(a_.cfg().app_secret);
    h.final(&k);
    return k;
}

/// AES-256-GCM: "iv.tag.data", each base64url.
pub fn encrypt(a: Allocator, plain: []const u8) ![]const u8 {
    var iv: [12]u8 = undefined;
    a_.random(&iv);
    var tag: [16]u8 = undefined;
    const data = try a.alloc(u8, plain.len);
    Aes.encrypt(data, &tag, plain, "", iv, aesKey());
    return std.fmt.allocPrint(a, "{s}.{s}.{s}", .{ try enc(a, &iv), try enc(a, &tag), try enc(a, data) });
}

pub fn decrypt(a: Allocator, sealed: []const u8) ![]const u8 {
    var it = std.mem.splitScalar(u8, sealed, '.');
    const iv_s = it.next() orelse return error.BadSecret;
    const tag_s = it.next() orelse return error.BadSecret;
    const data_s = it.next() orelse return error.BadSecret;
    const iv = try dec(a, iv_s);
    const tag = try dec(a, tag_s);
    const data = try dec(a, data_s);
    if (iv.len != 12 or tag.len != 16) return error.BadSecret;
    const out = try a.alloc(u8, data.len);
    Aes.decrypt(out, data, tag[0..16].*, "", iv[0..12].*, aesKey()) catch return error.BadSecret;
    return out;
}

fn enc(a: Allocator, b: []const u8) ![]const u8 {
    const out = try a.alloc(u8, b64url.Encoder.calcSize(b.len));
    return b64url.Encoder.encode(out, b);
}

/// Buffer.from(s, 'base64url'): tolerant of padding.
pub fn dec(a: Allocator, s_: []const u8) ![]u8 {
    const s = std.mem.trimEnd(u8, s_, "=");
    const out = try a.alloc(u8, b64url.Decoder.calcSizeForSlice(s) catch return error.BadSecret);
    b64url.Decoder.decode(out, s) catch return error.BadSecret;
    return out;
}

pub fn hmacHex(a: Allocator, secret: []const u8, payload: []const u8) ![]const u8 {
    const H = std.crypto.auth.hmac.sha2.HmacSha256;
    var mac: [32]u8 = undefined;
    H.create(&mac, payload, secret);
    return a.dupe(u8, &std.fmt.bytesToHex(mac, .lower));
}

pub fn safeEqual(x: []const u8, y: []const u8) bool {
    if (x.len != y.len) return false;
    var diff: u8 = 0;
    for (x, y) |p, q| diff |= p ^ q;
    return diff == 0;
}
