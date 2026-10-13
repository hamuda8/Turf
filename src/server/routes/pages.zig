//! HTML pages, per-organization PWA manifests and icons, and shipping labels
//! (src/routes/pages.js). Templates come from the public folder (Turf-js's `public/` until the
//! Zig client replaces it).

const std = @import("std");
const val = @import("../lib/val.zig");
const db = @import("../lib/db.zig");
const web = @import("../web.zig");
const a_ = @import("../app.zig");
const auth = @import("../auth.zig");
const geo = @import("../geo.zig");
const barcode = @import("../barcode.zig");
const orgs = @import("../services/orgs.zig");
const branding = @import("../services/branding.zig");
const emails = @import("../services/emails.zig");
const routes_mod = @import("routes.zig");
const Val = val.Val;
const Req = web.Req;
const Allocator = std.mem.Allocator;

fn escapeHtml(a: Allocator, s: []const u8) ![]const u8 {
    return emails.esc(a, .{ .str = s });
}

/// JSON safe to embed inside <script type="application/json">.
fn embedJson(a: Allocator, v: Val) ![]const u8 {
    return std.mem.replaceOwned(u8, a, try val.toJson(a, v), "<", "\\u003c");
}

fn turfBrand(a: Allocator) !Val {
    return val.from(a, .{
        .name = "Turf",
        .slug = null,
        .appName = "Turf",
        .shortName = "Turf",
        .primaryColor = orgs.default_primary,
        .accentColor = orgs.default_accent,
        .onPrimary = branding.readableOn(orgs.default_primary),
        .logoUrl = null,
        .icon192 = "/img/icon-192.png",
        .icon512 = "/img/icon-512.png",
        .maskable192 = "/img/maskable-192.png",
        .maskable512 = "/img/maskable-512.png",
    });
}

fn template(r: *Req, name: []const u8) ![]const u8 {
    return routes_mod.readPublic(r, name);
}

fn replaceAll(a: Allocator, s: []const u8, key: []const u8, value: []const u8) ![]const u8 {
    return std.mem.replaceOwned(u8, a, s, key, value);
}

fn renderShell(r: *Req, brand: Val, base: []const u8) !void {
    const a = r.a;
    var html = try template(r, "app.html");
    const theme = if (brand.get("accentColor").truthy()) brand.get("accentColor") else brand.get("primaryColor");
    const manifest_url = if (brand.get("slug").truthy()) try std.fmt.allocPrint(a, "/o/{s}/manifest.webmanifest", .{try val.toStr(a, brand.get("slug"))}) else "/manifest.webmanifest";
    // Values are inserted literally (Turf-js uses replacer functions so "$&" stays as typed).
    html = try replaceAll(a, html, "{{TITLE}}", try escapeHtml(a, try val.toStr(a, brand.get("appName"))));
    html = try replaceAll(a, html, "{{THEME_COLOR}}", try escapeHtml(a, try val.toStr(a, theme)));
    html = try replaceAll(a, html, "{{MANIFEST}}", try escapeHtml(a, manifest_url));
    html = try replaceAll(a, html, "{{APPLE_ICON}}", try escapeHtml(a, try val.toStr(a, brand.get("icon192"))));
    html = try replaceAll(a, html, "{{MAPS_URL}}", try escapeHtml(a, a_.cfg().maps_url));
    html = try replaceAll(a, html, "{{BOOT_JSON}}", try embedJson(a, try val.from(a, .{ .brand = brand, .base = base, .devicesUrl = try std.fmt.allocPrint(a, "{s}/auth/devices", .{a_.cfg().auth_host}) })));
    try r.setHeader("cache-control", "no-store");
    return r.html(200, html);
}

fn manifest(a: Allocator, brand: Val, base: []const u8) !Val {
    const start = try std.fmt.allocPrint(a, "{s}/", .{base});
    return val.from(a, .{
        .id = start,
        .name = brand.get("appName"),
        .short_name = brand.get("shortName"),
        .start_url = start,
        .scope = start,
        .display = "standalone",
        .orientation = "portrait",
        .background_color = "#D3DDE3",
        .theme_color = if (brand.get("accentColor").truthy()) brand.get("accentColor") else brand.get("primaryColor"),
        .icons = .{
            .{ .src = brand.get("icon192"), .sizes = "192x192", .type = "image/png", .purpose = "any" },
            .{ .src = brand.get("icon512"), .sizes = "512x512", .type = "image/png", .purpose = "any" },
            .{ .src = brand.get("maskable192"), .sizes = "192x192", .type = "image/png", .purpose = "maskable" },
            .{ .src = brand.get("maskable512"), .sizes = "512x512", .type = "image/png", .purpose = "maskable" },
        },
    });
}

fn sendManifest(r: *Req, m: Val) !void {
    return r.send(200, "application/manifest+json; charset=utf-8", try val.toJson(r.a, m));
}

/// Returns false when no page route matched (the 404 page follows).
pub fn handle(r: *Req) !bool {
    const path = r.ctx.?.path;
    const m = r.method();
    const get = m == .GET or m == .HEAD;
    const post = m == .POST;
    r.params.clearRetainingCapacity();
    // Auth
    if (get and try web.match(r, "/auth/login", path)) return done(auth.loginRedirect(r));
    if (get and try web.match(r, "/auth/callback", path)) return done(auth.authCallback(r));
    if ((get or post) and try web.match(r, "/auth/logout", path)) return done(auth.logout(r));
    if (!get) return false;
    // Static pages
    if (try web.match(r, "/", path)) return done(sendPage(r, "index.html"));
    if (try web.match(r, "/developers", path)) return done(sendPage(r, "developers.html"));
    if (try web.match(r, "/track", path)) {
        try r.setHeader("referrer-policy", "no-referrer");
        return done(sendPage(r, "lookup.html"));
    }
    if (try web.match(r, "/terms", path)) return done(legal(r, "terms"));
    if (try web.match(r, "/privacy", path)) return done(legal(r, "privacy"));
    if (try web.match(r, "/favicon.ico", path)) return done(r.redirect(301, "/img/icon-192.png"));
    if (try web.match(r, "/sw.js", path)) {
        try r.setHeader("service-worker-allowed", "/");
        try r.setHeader("cache-control", "no-cache");
        return done(sendFile(r, "sw.js", "text/javascript; charset=utf-8"));
    }
    // Turf-branded app
    if (try web.match(r, "/manifest.webmanifest", path)) return done(sendManifest(r, try manifest(r.a, try turfBrand(r.a), "/app")));
    if (try web.match(r, "/app", path) or try web.match(r, "/app/*rest", path) or try web.match(r, "/invite/:token", path)) {
        if (!try auth.pageAuth(r)) return true;
        return done(renderShell(r, try turfBrand(r.a), "/app"));
    }
    // Organization-branded app
    if (try web.match(r, "/o/:slug/manifest.webmanifest", path)) return done(orgManifest(r));
    if (try web.match(r, "/o/:slug/asset/:file", path)) return done(orgAsset(r));
    if (try web.match(r, "/o/:slug", path) or try web.match(r, "/o/:slug/*rest", path)) {
        if (!try auth.pageAuth(r)) return true;
        const found = try brandOf(r) orelse return done(r.redirect(302, "/app"));
        return done(renderShell(r, found.brand, try std.fmt.allocPrint(r.a, "/o/{s}", .{try val.toStr(r.a, found.org.get("slug"))})));
    }
    // Tracking pages
    if (try web.match(r, "/t/:token", path)) return done(renderTrack(r));
    if (try web.match(r, "/embed/t/:token", path)) {
        // The embed page is meant to be framed by merchants' sites.
        r.allow_framing = true;
        return done(renderTrack(r));
    }
    // Shipping labels
    if (try web.match(r, "/label/:token", path)) return done(label(r));
    if (try web.match(r, "/labels", path)) return done(labels(r));
    return false;
}

fn done(result: anyerror!void) anyerror!bool {
    try result;
    return true;
}

fn sendFile(r: *Req, name: []const u8, content_type: []const u8) !void {
    const data = routes_mod.readPublic(r, name) catch return r.notFound("File");
    return r.send(200, content_type, data);
}

fn sendPage(r: *Req, name: []const u8) !void {
    return sendFile(r, name, "text/html; charset=utf-8");
}

/// Terms of Service and Privacy Policy, with the operator's details.
fn legal(r: *Req, page: []const u8) !void {
    const a = r.a;
    var html = try template(r, try std.fmt.allocPrint(a, "legal/{s}.html", .{page}));
    const c = a_.cfg();
    html = try replaceAll(a, html, "{{LEGAL_NAME}}", try escapeHtml(a, c.legal_entity_name));
    html = try replaceAll(a, html, "{{CONTACT_EMAIL}}", try escapeHtml(a, c.contact_email));
    html = try replaceAll(a, html, "{{UPDATED}}", c.terms_version);
    html = try replaceAll(a, html, "{{LOCATION_DAYS}}", try std.fmt.allocPrint(a, "{d}", .{c.location_retention_days}));
    return r.html(200, html);
}

const Found = struct { org: Val, brand: Val };

fn brandOf(r: *Req) !?Found {
    const slug = try val.lower(r.a, r.param("slug"));
    if (slug.len < 3 or slug.len > 40) return null;
    for (slug) |c| if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '-')) return null;
    const org = (try orgs.getOrgBySlug(r.a, slug)) orelse return null;
    return .{ .org = org, .brand = try branding.publicBranding(r.a, org) };
}

fn orgManifest(r: *Req) !void {
    const found = (try brandOf(r)) orelse return r.end(404);
    try r.setHeader("cache-control", "no-cache");
    return sendManifest(r, try manifest(r.a, found.brand, try std.fmt.allocPrint(r.a, "/o/{s}", .{try val.toStr(r.a, found.org.get("slug"))})));
}

fn orgAsset(r: *Req) !void {
    const found = try brandOf(r);
    const file = r.param("file");
    const kind = if (std.mem.endsWith(u8, file, ".png")) file[0 .. file.len - 4] else file;
    const asset = if (found) |f| try branding.getAsset(r.a, f.org.get("_id"), kind) else null;
    const as = asset orelse return r.end(404);
    try r.setHeader("cache-control", if (r.qs("v") != null and r.qs("v").?.len > 0) "public, max-age=31536000, immutable" else "public, max-age=300");
    return r.send(200, "image/png", as.get("data").bin);
}

fn renderTrack(r: *Req) !void {
    const a = r.a;
    const html = try replaceAll(a, try template(r, "track.html"), "{{MAPS_URL}}", try escapeHtml(a, a_.cfg().maps_url));
    try r.setHeader("referrer-policy", "no-referrer");
    return r.html(200, html);
}

// ---- Shipping labels ----------------------------------------------------------------------------

fn govAr(code: Val) []const u8 {
    const c = code.asStr() orelse "";
    return if (geo.governorate(c)) |g| g.ar else c;
}

fn addressLine(a: Allocator, addr: Val) ![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    for ([_][]const u8{ "street", "area", "city" }) |k| if (addr.t(k)) try parts.append(a, try escapeHtml(a, try val.toStr(a, addr.get(k))));
    const g = govAr(addr.get("governorate"));
    if (g.len > 0) try parts.append(a, try escapeHtml(a, g));
    return std.mem.join(a, "، ", parts.items);
}

fn e(a: Allocator, v: Val) ![]const u8 {
    return emails.esc(a, v);
}

/// One 100x150 mm label (Arabic + English).
fn labelHtml(a: Allocator, s: Val) ![]const u8 {
    const cod = s.get("cod");
    const cod_html = if (cod.truthy()) try std.fmt.allocPrint(a, "<div class=\"cod\">الدفع عند الاستلام / COD: <b>{s} {s}</b></div>", .{ try escapeHtml(a, try emails.localeNumber(a, val.toNum(cod.get("amount")))), try e(a, cod.get("currency")) }) else "";
    const ref = if (s.t("externalRef")) s.get("externalRef") else s.get("testRef");
    const d = s.get("dropoff");
    const p = s.get("pickup");
    const parcel = s.get("parcel");
    return std.fmt.allocPrint(a,
        \\<main class="label">
        \\  <header><strong>{s}</strong><span>{s}</span></header>
        \\  <div class="barcode">{s}<div class="tn">{s}</div></div>
        \\  <section class="to"><h2>إلى / To</h2>
        \\    <div class="name">{s}</div><div class="phone" dir="ltr">{s}</div>
        \\    <div>{s}</div>{s}
        \\    <div class="gov">{s}</div></section>
        \\  <section class="from"><h2>من / From</h2><div>{s} — <span dir="ltr">{s}</span></div><div>{s}</div></section>
        \\  <footer><span dir="ltr">{s} kg · {s} pcs{s}</span>{s}
        \\  {s}{s}</footer>
        \\</main>
    , .{
        if (s.t("carrierName")) try e(a, s.get("carrierName")) else "", try e(a, s.get("merchantName")),
        try barcode.code128Svg(a, s.s("trackingNumber") orelse "", .{}),                                  try e(a, s.get("trackingNumber")),
        try e(a, d.get("name")),                                                                           try e(a, d.get("phone")),
        try addressLine(a, d),                                                                             if (d.t("details")) try std.fmt.allocPrint(a, "<div class=\"details\">{s}</div>", .{try e(a, d.get("details"))}) else "",
        try escapeHtml(a, govAr(d.get("governorate"))),                                                    try e(a, p.get("name")),
        try e(a, p.get("phone")),                                                                          try addressLine(a, p),
        try e(a, parcel.get("weightKg")),                                                                  try e(a, parcel.get("pieces")),
        if (parcel.t("fragile")) " · قابل للكسر FRAGILE" else "",                                       cod_html,
        if (ref.truthy()) try std.fmt.allocPrint(a, "<span>Ref: {s}</span>", .{try e(a, ref)}) else "", if (s.t("test")) "<span>TEST</span>" else "",
    });
}

fn labelsPage(a: Allocator, title: []const u8, items: []const []const u8) ![]const u8 {
    return std.fmt.allocPrint(a,
        \\<!doctype html>
        \\<html lang="ar" dir="rtl"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        \\<title>{s}</title><link rel="stylesheet" href="/css/label.css"></head>
        \\<body>{s}<button class="print" type="button" id="print">طباعة / Print</button><script src="/js/label.js"></script></body></html>
    , .{ try escapeHtml(a, title), try std.mem.join(a, "\n", items) });
}

fn validLabelToken(t: []const u8) bool {
    if (t.len < 16 or t.len > 40) return false;
    for (t) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) return false;
    return true;
}

fn sendLabels(r: *Req, title: []const u8, items: []const []const u8) !void {
    try r.setHeader("cache-control", "private, no-store");
    try r.setHeader("referrer-policy", "no-referrer");
    return r.html(200, try labelsPage(r.a, title, items));
}

fn label(r: *Req) !void {
    const token = r.param("token");
    if (!validLabelToken(token)) return r.send(404, "text/html; charset=utf-8", "Not found");
    const s = (try db.col("shipments").findOne(r.a, .{ .labelToken = token }, .{})) orelse return r.send(404, "text/html; charset=utf-8", "Not found");
    return sendLabels(r, s.s("trackingNumber") orelse "", &.{try labelHtml(r.a, s)});
}

/// Several labels at once, one per printed page: /labels?t=<token>,<token>,... (up to 100).
fn labels(r: *Req) !void {
    const a = r.a;
    const raw = if (r.q("t").isNullish()) "" else try val.toStr(a, r.q("t"));
    const tokens = try val.newArr(a);
    var it = std.mem.splitScalar(u8, raw, ',');
    while (it.next()) |x| {
        const t = std.mem.trim(u8, x, " \t");
        if (validLabelToken(t) and tokens.items().len < 100) try tokens.push(t);
    }
    if (tokens.items().len == 0) return r.send(404, "text/html; charset=utf-8", "Not found");
    const found = try db.col("shipments").find(a, .{ .labelToken = .{ .@"$in" = tokens } }, .{});
    var items: std.ArrayList([]const u8) = .empty;
    // Keep the order they were asked in.
    for (tokens.items()) |t| for (found) |s| if (s.get("labelToken").eql(t)) {
        try items.append(a, try labelHtml(a, s));
        break;
    };
    if (items.items.len == 0) return r.send(404, "text/html; charset=utf-8", "Not found");
    return sendLabels(r, try std.fmt.allocPrint(a, "{d} labels", .{items.items.len}), items.items);
}
