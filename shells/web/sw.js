// Turf service worker (installable app and offline use), as Turf-js's public/sw.js:
// - The app's files (zui.js, app.wasm, icons): network first so deploys show at once, the cached
//   copy when offline.
// - Pages: every address of the app is the same page (index.html), so any address opens offline
//   from the cached copy; the branded offline page if it was never loaded.
// - Data: only what a screen needs to open offline on this person's own device, network first:
//   the public tracking status and the driver app (account, platform data, company, the
//   courier's own tasks). Nothing else under /api, no POSTs, nothing from other sites. Signing
//   in or out removes the account's part.
// - Push notifications.

const VERSION = 'turf-zig-v2';
const SHELL = `${VERSION}-shell`;
const DATA = 'turf-data'; // kept across versions: the last loaded status must survive an update
const DATA_LIMIT = 80;
const OFFLINE_PAGE = '/offline.html';
const PRECACHE = ['/', '/index.html', '/zui.js', '/app.wasm', '/manifest.json', OFFLINE_PAGE, '/img/icon-192.png', '/img/icon-512.png',
  '/fonts/WufourSansGolden-Regular.woff2', '/fonts/WufourSansGolden-Medium.woff2', '/fonts/WufourSansGolden-Bold.woff2', '/fonts/WufourArabicGolden-Regular.woff2', '/fonts/WufourArabicGolden-Medium.woff2', '/fonts/WufourArabicGolden-Bold.woff2'];

self.addEventListener('install', (event) => {
  self.skipWaiting();
  // One by one, so a single missing file doesn't leave the whole shell uncached.
  event.waitUntil(caches.open(SHELL).then((cache) => Promise.all(PRECACHE.map((url) => cache.add(url).catch(() => {})))));
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((k) => k.startsWith('turf-') && k !== SHELL && k !== DATA).map((k) => caches.delete(k))))
      .then(() => self.clients.claim()),
  );
});

const DATA_PATHS = [
  /^\/api\/public\/track\/[A-Za-z0-9_-]+$/,
  /^\/api\/app\/(me|meta)$/,
  /^\/api\/app\/orgs\/[a-f0-9]{24}$/,
  /^\/api\/app\/orgs\/[a-f0-9]{24}\/courier\/(me|tasks)(\/[a-f0-9]{24})?$/,
];

async function forgetAccountData() {
  const cache = await caches.open(DATA);
  for (const key of await cache.keys()) if (new URL(key.url).pathname.startsWith('/api/app/')) await cache.delete(key);
}

async function trimData(cache) {
  const keys = await cache.keys();
  for (const key of keys.slice(0, Math.max(0, keys.length - DATA_LIMIT))) await cache.delete(key);
}

async function networkFirstData(event) {
  const req = event.request;
  const cache = await caches.open(DATA);
  try {
    const res = await fetch(req);
    if (res.ok && (res.headers.get('content-type') || '').includes('application/json')) {
      const copy = res.clone();
      event.waitUntil(cache.delete(req).then(() => cache.put(req, copy)).then(() => trimData(cache)));
    } else if ([401, 403, 404].includes(res.status)) {
      event.waitUntil(cache.delete(req)); // signed out, removed, or no longer theirs
    }
    return res;
  } catch {
    const cached = await cache.match(req) || await cache.match(req, { ignoreSearch: true });
    if (!cached) return Response.error();
    const headers = new Headers(cached.headers);
    headers.set('X-Turf-Offline', '1');
    return new Response(cached.body, { status: cached.status, statusText: cached.statusText, headers });
  }
}

async function networkFirst(event, cacheKey) {
  const cache = await caches.open(SHELL);
  try {
    const res = await fetch(event.request);
    if (res.ok && res.type === 'basic' && !res.redirected) {
      const copy = res.clone();
      event.waitUntil(cache.put(cacheKey || event.request, copy));
    }
    return res;
  } catch {
    return (await cache.match(cacheKey || event.request)) || Response.error();
  }
}

self.addEventListener('fetch', (event) => {
  const req = event.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.origin !== location.origin) return; // map tiles, Wufour: straight to the network

  if (url.pathname === '/auth/logout' || url.pathname === '/auth/callback') {
    event.waitUntil(forgetAccountData());
    return;
  }
  if (DATA_PATHS.some((re) => re.test(url.pathname))) {
    event.respondWith(networkFirstData(event));
    return;
  }
  if (/^\/(api|auth)\//.test(url.pathname) || url.pathname.startsWith('/label') || url.pathname === '/sw.js') return;

  if (req.mode === 'navigate') {
    // Every page is the app: the cached page serves any address offline.
    event.respondWith(fetch(req).then((res) => {
      if (res.ok && res.type === 'basic' && !res.redirected) {
        const copy = res.clone();
        event.waitUntil(caches.open(SHELL).then((c) => c.put('/', copy)));
      }
      return res;
    }).catch(async () => (await caches.match('/', { cacheName: SHELL })) || (await caches.match(OFFLINE_PAGE)) || new Response(
      '<!doctype html><meta charset="utf-8"><title>Offline</title><p>لا يوجد اتصال بالإنترنت · You are offline</p>',
      { status: 503, headers: { 'Content-Type': 'text/html; charset=utf-8' } },
    )));
    return;
  }
  if (PRECACHE.includes(url.pathname) || url.pathname.startsWith('/img/') || url.pathname.includes('/asset/')) {
    event.respondWith(networkFirst(event));
  }
});

// ---------- Notifications ----------

async function openUrl(url) {
  const target = new URL(url || '/app', self.location.origin);
  if (target.origin !== self.location.origin) return self.clients.openWindow(target.href);
  const list = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
  const open = list.find((c) => c.url === target.href) || list.find((c) => new URL(c.url).pathname.startsWith('/o/'));
  if (open) {
    await open.focus();
    if (open.url !== target.href && 'navigate' in open) await open.navigate(target.href).catch(() => {});
    return;
  }
  await self.clients.openWindow(target.href);
}

self.addEventListener('push', (event) => {
  let data = {};
  try { data = event.data ? event.data.json() : {}; } catch { data = { title: 'Turf', body: event.data?.text() }; }
  event.waitUntil(self.registration.showNotification(data.title || 'Turf', {
    body: data.body || '',
    tag: data.tag,
    renotify: Boolean(data.tag),
    requireInteraction: Boolean(data.requireInteraction),
    vibrate: data.urgent ? [300, 100, 300, 100, 300] : [200],
    icon: '/img/icon-192.png',
    badge: '/img/icon-192.png',
    data: { url: data.url },
  }));
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  event.waitUntil(openUrl(event.notification.data?.url));
});
