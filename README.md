# Turf

Delivery platform for stores, carriers, couriers and recipients, written in Zig. It replaces
Turf-js (Node) with the same HTTP API, live streams and MongoDB data, so Control, Taazur and the
other Wufour apps keep working unchanged.

- **Client** (`src/client`): one zui codebase for the web (PWA), Android and iOS.
  - Stores: shipments, new shipment with map address picking, bulk CSV, finance, claims,
    reports, developers, branding, team, audit.
  - Carriers: dispatch, live map, hub scan (camera barcode + QR), fleet, coverage, pricing,
    finance, claims, team, branding.
  - Couriers: shift with background GPS, task list, navigation with voice, proof of delivery
    photos, offline action queue, dispatch alarm over the lock screen.
  - Recipients: public tracking `/t/<token>`, embed `/embed/t/<token>`, `/track`, landing page.
  - Arabic (right-to-left) and English; home-screen widget on Android and iOS; push notifications.
- **Server** (`src/server`): every Turf-js route, SSE stream, background job (webhooks, watchdog,
  auto-dispatch, e-mail queue) and Mongo index, plus Bearer-token sign-in for the phone apps and
  FCM/APNs push.

Shared code lives in [zig-core](https://github.com/hamuda8/zig-core), pinned in `build.zig.zon`.

## Build

Zig 0.17.0.

| Command | Output |
|---|---|
| `zig build web -Doptimize=small` | `zig-out/web` |
| `zig build android -Doptimize=safe` | `zig-out/android/turf.apk` |
| `zig build ios` | iOS static libraries |
| `zig build server -Doptimize=safe` | `zig-out/bin/turf-server` |
| `zig build server-linux -Doptimize=safe` | `zig-out/linux/turf-server` |
| `zig build test` | client and server tests |

Build options (defaults are staging): `-Dserver=https://turf.wreseal.com`,
`-Dauth=https://www.wreseal.com` (Wufour sign-in; keep the `www`), `-Dmaps=https://maps.wreseal.com`.

Push on Android needs the Firebase app file: the build reads
`..\secrets\turf-google-services.json` (outside the repo, never committed; override with
`-Dgoogle-services=<path>`). Google's `firebase-messaging` client is the one third-party library
allowed; zig-core's APK builder downloads it from Google's Maven once and caches it.

## Server configuration

Same variable names as Turf-js. Environment variables win; otherwise `TURF_ENV_FILE`, or the first
of `.env.local`, `.env.production`, `.env`.

- Required: `MONGO_URI`, `MONGO_DB`, `APP_SECRET`.
- Usual: `PORT`, `LISTEN`, `PUBLIC_URL`, `TRUST_PROXY`, `AUTH_HOST`, `MAPS_URL`,
  `MAPS_INTERNAL_URL`, `MAPS_API_KEY`, `MAP_TILE_URL`, `INTERNAL_API_KEY`, `CONTROL_URL`,
  `MODERATION_HOST`, `MODERATION_API_KEY`, `PLATFORM_ADMIN_USER_IDS`, `MERCHANT_SIGNUP`,
  `AUTO_APPROVE_CARRIERS`, `CONTACT_EMAIL`, `LEGAL_ENTITY_NAME`, `ALERT_WEBHOOK_URL`.
- E-mail: `SMTP_HOST`, `SMTP_USER`, `SMTP_PASS`, `SMTP_SECURE`, `SMTP_ALLOW_INSECURE`, `MAIL_FROM`.
- Push to phones (each unset = off): `FCM_SERVICE_ACCOUNT_FILE` (path to the Firebase service
  account JSON), `APNS_KEY_FILE`, `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_BUNDLE_ID`, `APNS_SANDBOX`.
- Pages: `TURF_PUBLIC_DIR` (default `zig-out/web`; pointing it at Turf-js's `public` serves the old pages).

## Running it (like the npm scripts)

| Command | Like | What it does |
|---|---|---|
|  |  | builds, then runs on this machine in the window, with  (Ctrl+C stops it) |
|  |  | builds, then (re)starts turf.wreseal.com in the background with ; logs in  |
|  | Unknown command: "start"


Did you mean one of these?
  npm star # Mark your favorite packages
  npm stars # View packages marked as favorites
  npm start # Start a package
To see a list of supported npm commands, run:
  npm help | builds the Linux server and pages into  and prints how to run them on Proxmox with  |

All three run  ( does the same).
Staging runs behind Cloudflare Tunnel on this laptop; it does not survive a restart, so run
 again after one. Roll back to Node: stop  and run
 in Turf-js.
## Tests

- `zig build test`: server units and headless client flows.
- Parity with Turf-js (local MongoDB, throwaway `TurfTest_zig*` databases):
  - `node tests/parity/run.mjs` runs Turf-js's own test suite (unchanged assertions) plus extra
    tests against this server;
  - `node tests/parity/run.mjs --node` runs the same against Turf-js.
