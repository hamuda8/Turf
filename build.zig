const std = @import("std");
const core = @import("zig_core");

pub fn build(b: *std.Build) void {
    // Where the phone apps reach the Turf server. For development over USB:
    //   adb reverse tcp:<port> tcp:<port>  and  zig build android -Dserver=http://127.0.0.1:<port>
    const options = b.addOptions();
    options.addOption([]const u8, "server", b.option([]const u8, "server", "Turf server for the phone apps") orelse "https://turf.wreseal.com");
    // Wufour, the account service (Turf-js's AUTH_HOST): the phones sign in there
    // (POST /api/auth/login) and the web links to its devices page.
    options.addOption([]const u8, "auth", b.option([]const u8, "auth", "Wufour (accounts) for sign-in") orelse "https://www.wreseal.com");
    // Wufour Maps (Turf-js's MAPS_URL): the map tiles.
    options.addOption([]const u8, "maps", b.option([]const u8, "maps", "Wufour Maps, for map tiles") orelse "https://maps.wreseal.com");

    core.addApp(b, b.dependency("zig_core", .{}), .{
        .client_config = options.createModule(),
        .name = "turf",
        .client = b.path("src/client/app.zig"),
        .server = b.path("src/server/main.zig"),
        .web = b.path("shells/web"),
        .android_manifest = b.path("shells/android/AndroidManifest.xml"),
        .android_res = b.path("shells/android/res"),
        .android_res_files = &.{"mipmap-xxxhdpi/ic_launcher.png"},
        .ios_info_plist = b.path("shells/ios/Info.plist"),
        // FCM: google-services.json stays outside the repository (C:/MProjects/secrets).
        .android_push = .{ .google_services = "../secrets/turf-google-services.json" },
        .optimize = b.standardOptimizeOption(.{}),
    });
    // The npm scripts of the Node version, one command each (tools/run.ps1 does the builds):
    //   zig build local        this machine, with ../Turf-js/.env.local, in this window
    //   zig build staging      turf.wreseal.com, with ../Turf-js/.env.staging, in the background
    //   zig build production   the Linux server and pages for Proxmox, in zig-out/production
    for ([_][2][]const u8{
        .{ "local", "Build and run on this machine (like npm run local)" },
        .{ "staging", "Build and start staging in the background (like npm run staging)" },
        .{ "production", "Build the Linux server and pages for Proxmox into zig-out/production" },
    }) |m| {
        const run = b.addSystemCommand(&.{ "powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File" });
        run.addFileArg(b.path("tools/run.ps1"));
        run.addArgs(&.{ "-Mode", m[0], "-Zig", b.graph.zig_exe });
        run.has_side_effects = true;
        b.step(m[0], m[1]).dependOn(&run.step);
    }
}
