// Routes Turf-js's own tests never call. Runs against both servers (node tests/parity/run.mjs
// --node, and without it); with TURF_SHAPES set the two runs' answers can be compared field by
// field. Expectations are Turf-js's behaviour.

import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { as, baseUrl, makeUser, withKey, shutdown } from '../helpers.mjs';

after(shutdown);

const owner = makeUser('Rafi');
const driver = makeUser('Bassel');
const shop = makeUser('Lama');
const other = makeUser('Ziad');
const s = {};
const ok = (res, status = 200) => {
  assert.equal(res.status, status, `expected ${status}, got ${res.status}: ${JSON.stringify(res.data)}`);
  return res.data;
};
const HUB = { lat: 33.5, lng: 36.25 };
const order = extra => ({
  pickup: { name: 'Lama shop', phone: '0944000011', governorate: 'DI', city: 'Damascus', location: HUB },
  dropoff: { name: 'Huda', phone: '0944000012', governorate: 'DI', city: 'Damascus', area: 'Malki' },
  parcel: { weightKg: 1 },
  ...extra,
});
const raw = (p, init) => fetch(`${baseUrl}${p}`, { redirect: 'manual', ...init });

test('setup: a carrier with a courier, a store with a key', async () => {
  s.c = ok(await as(owner).post('/api/app/orgs', { acceptTerms: true, type: 'carrier', name: 'Route Co', slug: 'route-co' }), 201).id;
  ok(await as(owner).patch(`/api/app/orgs/${s.c}/carrier/settings`, { coverage: ['DI', 'HL'], pricing: { localBase: 1000, nationalBase: 2000, includedKg: 5, perKg: 0, perKm: 0, codPercent: 0, codMin: 0 } }));
  s.hub = ok(await as(owner).post(`/api/app/orgs/${s.c}/carrier/hubs`, { name: 'Main', code: 'rt1', type: 'hub', governorate: 'DI', city: 'Damascus', location: HUB }), 201);
  const roles = ok(await as(owner).get(`/api/app/orgs/${s.c}/roles`));
  s.roles = roles;
  const inv = ok(await as(owner).post(`/api/app/orgs/${s.c}/invitations`, { email: driver.email, roleId: roles.find(r => r.key === 'courier')._id, courier: { vehicle: 'motorbike' } }), 201);
  s.invToken = inv.link.split('/invite/')[1];
  const seen = ok(await as(driver).get(`/api/app/invitations/${s.invToken}`));
  assert.equal(seen.status, 'pending');
  assert.equal(seen.emailMatches, true);
  assert.equal(seen.role, 'Courier');
  ok(await as(driver).post(`/api/app/invitations/${s.invToken}/accept`));
  ok(await as(driver).post(`/api/app/orgs/${s.c}/courier/consent`, { version: 1 }));
  ok(await as(driver).post(`/api/app/orgs/${s.c}/courier/duty`, { onDuty: true }));
  s.courier = ok(await as(driver).get(`/api/app/orgs/${s.c}/courier/me`)).memberId;
  s.m = ok(await as(shop).post('/api/app/orgs', { acceptTerms: true, type: 'merchant', name: 'Lama Store', slug: 'lama-store' }), 201).id;
  s.key = ok(await as(shop).post(`/api/app/orgs/${s.m}/merchant/api-keys`, { name: 'k' }), 201);
  s.api = withKey(s.key.secret);
});

test('account: slugs, invitations, push, profile, branding, roles', async () => {
  assert.deepEqual(ok(await as(owner).get('/api/app/slug-available?slug=route-co')), { slug: 'route-co', available: false });
  assert.deepEqual(ok(await as(owner).get('/api/app/slug-available?slug=free-name')), { slug: 'free-name', available: true });
  assert.equal((await as(owner).get('/api/app/slug-available?slug=X')).status, 400);
  assert.equal((await as(owner).get('/api/app/invitations/nope')).status, 404);

  const list1 = ok(await as(owner).post(`/api/app/orgs/${s.c}/invitations`, { email: other.email, roleId: s.roles.find(r => r.key === 'support')._id }), 201);
  const pending = ok(await as(owner).get(`/api/app/orgs/${s.c}/invitations`));
  assert.equal(pending.length, 1);
  ok(await as(owner).del(`/api/app/orgs/${s.c}/invitations/${list1.id}`));
  assert.equal((await as(owner).del(`/api/app/orgs/${s.c}/invitations/${list1.id}`)).status, 404);
  const list2 = ok(await as(owner).post(`/api/app/orgs/${s.c}/invitations`, { email: other.email, roleId: s.roles.find(r => r.key === 'support')._id }), 201);
  ok(await as(other).post(`/api/app/invitations/${list2.link.split('/invite/')[1]}/decline`));
  assert.equal((await as(other).post(`/api/app/invitations/${list2.link.split('/invite/')[1]}/decline`)).status, 404);

  ok(await as(owner).post('/api/app/push/unsubscribe', { endpoint: 'https://fcm.googleapis.com/x' }));
  assert.equal((await as(owner).post('/api/app/push/unsubscribe', {})).status, 400);
  ok(await as(owner).patch(`/api/app/orgs/${s.c}/profile`, { name: 'Route Company', phone: '0911 222 333' }));
  const org = ok(await as(owner).get(`/api/app/orgs/${s.c}`));
  assert.equal(org.name, 'Route Company');
  assert.equal(org.contact.phone, '0911222333');
  ok(await as(owner).del(`/api/app/orgs/${s.c}/branding/logo`));

  const profile = ok(await as(owner).put(`/api/app/orgs/${s.c}/members/${s.courier}/courier`, { vehicle: 'car', plate: ' 123 ', capacityKg: '50' }));
  assert.deepEqual(profile, { vehicle: 'car', plate: '123', phone: null, rangeKm: null, capacityKg: 50 });
  assert.equal((await as(owner).put(`/api/app/orgs/${s.c}/members/${s.courier}/courier`, { vehicle: 'rocket' })).status, 400);
  const role = ok(await as(owner).post(`/api/app/orgs/${s.c}/roles`, { name: 'Night shift', permissions: ['shipments.view', 'shipments.view'] }), 201);
  assert.deepEqual(role.permissions, ['shipments.view']);
  ok(await as(owner).del(`/api/app/orgs/${s.c}/roles/${role._id}`));
  assert.equal((await as(owner).del(`/api/app/orgs/${s.c}/roles/${role._id}`)).status, 404);
  assert.equal((await as(owner).get(`/api/app/orgs/${s.c}/audit?before=nonsense`)).status, 200);
});

test('store: carriers, quotes, shipments, edits, cancel, stats, claims, keys, webhooks', async () => {
  const B = `/api/app/orgs/${s.m}/merchant`;
  const carriers = ok(await as(shop).get(`${B}/carriers?pickup=DI&dropoff=DI`));
  assert.equal(carriers.length, 1);
  assert.equal((await as(shop).get(`${B}/carriers?pickup=XX`)).status, 400);
  const quote = ok(await as(shop).post(`${B}/quotes`, order()));
  assert.equal(quote.options.length, 1);
  assert.equal(quote.strategy, 'balanced');
  const ship = ok(await as(shop).post(`${B}/shipments`, order({ reference: 'R-1' })), 201);
  s.ship = ship;
  assert.equal(ok(await as(shop).post(`${B}/shipments`, order({ reference: 'R-1' }))).id, ship.id, 'same reference: the same shipment');
  const detail = ok(await as(shop).get(`${B}/shipments/${ship.id}`));
  assert.equal(detail.shipment.reference, 'R-1');
  assert.equal(detail.tracking.reference, 'R-1');
  assert.equal((await as(shop).get(`${B}/shipments/${ship.id}/pod-photo`)).status, 404);
  const patched = ok(await as(shop).patch(`${B}/shipments/${ship.id}`, { notes: 'Ring twice' }));
  assert.equal(patched.notes, 'Ring twice');
  const day = new Date(Date.now() + 3 * 3600_000 + 2 * 86400_000).toISOString().slice(0, 10);
  assert.equal(ok(await as(shop).post(`${B}/shipments/${ship.id}/reschedule`, { date: day })).scheduledFor, day);
  assert.equal((await as(shop).post(`${B}/shipments/${ship.id}/reschedule`, { date: '2020-01-01' })).status, 400);
  const second = ok(await as(shop).post(`${B}/shipments`, order()), 201);
  const cancelled = ok(await as(shop).post(`${B}/shipments/${second.id}/cancel`, { reason: 'Customer changed their mind' }));
  assert.equal(cancelled.status, 'cancelled');
  assert.equal((await as(shop).post(`${B}/shipments/${second.id}/cancel`, {})).status, 409);
  const stats = ok(await as(shop).get(`${B}/stats`));
  assert.equal(stats.open.awaiting_pickup, 1);
  assert.equal(stats.last30Days.cancelled, 1);
  assert.deepEqual(ok(await as(shop).get(`${B}/claims`)), []);
  assert.equal((await as(shop).post(`${B}/shipments/${ship.id}/return-request`, {})).status, 409);

  ok(await as(shop).del(`${B}/api-keys/${s.key.id}`));
  assert.equal((await s.api.get('/shipments')).status, 401);
  const key2 = ok(await as(shop).post(`${B}/api-keys`, { name: 'k2', mode: 'test' }), 201);
  assert.equal(key2.mode, 'test');
  assert.ok(key2.prefix.startsWith('turf_test_'));
  s.api = withKey(ok(await as(shop).post(`${B}/api-keys`, { name: 'k3' }), 201).secret);

  assert.deepEqual(ok(await as(shop).get(`${B}/webhook`)), { webhook: null, deliveries: [] });
  const hook = ok(await as(shop).put(`${B}/webhook`, { url: 'http://127.0.0.1:9/hook' }));
  assert.equal(hook.url, 'http://127.0.0.1:9/hook');
  assert.ok(hook.secret.startsWith('whsec_'));
  const rotated = ok(await as(shop).post(`${B}/webhook/rotate`));
  assert.notEqual(rotated.secret, hook.secret);
  assert.equal(ok(await as(shop).get(`${B}/webhook`)).webhook.secret, rotated.secret);
  ok(await as(shop).del(`${B}/webhook`));
  assert.equal((await as(shop).post(`${B}/webhook/rotate`)).status, 400);
  assert.equal((await as(shop).put(`${B}/webhook`, { url: 'ftp://x' })).status, 400);
});

test('carrier: hubs, tasks, assignment, notes, fleet, clients, stats', async () => {
  const C = `/api/app/orgs/${s.c}/carrier`;
  const hubs = ok(await as(owner).get(`${C}/hubs`));
  assert.equal(hubs.length, 1);
  assert.deepEqual(hubs[0].location, HUB);
  ok(await as(owner).patch(`${C}/hubs/${s.hub._id}`, { name: 'Main hub', active: true }));
  assert.equal((await as(owner).patch(`${C}/hubs/${s.hub._id}`, { code: '!' })).status, 400);

  const task = ok(await as(owner).post(`${C}/tasks`, { type: 'pickup', shipmentIds: [s.ship.id], toHubId: s.hub._id }), 201);
  assert.equal(task.status, 'pending');
  const sugg = ok(await as(owner).get(`${C}/tasks/${task._id}/suggestions`));
  assert.equal(sugg.length, 1);
  const assigned = ok(await as(owner).post(`${C}/tasks/${task._id}/assign`, { courierId: s.courier }));
  assert.equal(assigned.status, 'assigned');
  assert.equal(assigned.courierName, 'Bassel');
  const mine = ok(await as(driver).get(`/api/app/orgs/${s.c}/courier/tasks/${task._id}`));
  assert.equal(mine.shipments.length, 1);
  assert.equal(mine.shipments[0].deliveryCode, undefined);
  ok(await as(driver).post(`/api/app/orgs/${s.c}/courier/tasks/${task._id}/decline`, { reason: 'Flat tyre' }));
  const cancelled = ok(await as(owner).post(`${C}/tasks/${task._id}/cancel`));
  assert.equal(cancelled.status, 'cancelled');
  assert.equal((await as(owner).post(`${C}/tasks/${task._id}/cancel`)).status, 409);

  ok(await as(owner).post(`${C}/shipments/${s.ship.id}/notes`, { note: 'Call before coming', visibleToCustomer: true }));
  const day = new Date(Date.now() + 3 * 3600_000 + 3 * 86400_000).toISOString().slice(0, 10);
  assert.equal(ok(await as(owner).post(`${C}/shipments/${s.ship.id}/reschedule`, { date: day })).scheduledFor, day);
  assert.equal((await as(owner).post(`${C}/shipments/${s.ship.id}/damage`, { note: 'Box wet' })).status, 409);
  const hist = ok(await as(owner).get(`${C}/fleet/${s.courier}/history`));
  assert.deepEqual(hist, []);
  assert.equal((await as(owner).get(`${C}/fleet/${s.courier}/history?from=2026-01-01&to=2026-03-01`)).status, 400);
  ok(await as(owner).post(`${C}/clients`, { store: 'https://turf.example/o/lama-store/app' }), 201);
  assert.equal(ok(await as(owner).get(`${C}/clients`)).length, 1);
  ok(await as(owner).del(`${C}/clients/${s.m}`));
  assert.equal(ok(await as(owner).get(`${C}/clients`)).length, 0);
  const stats = ok(await as(owner).get(`${C}/stats`));
  assert.equal(stats.onDuty, 1);
  assert.equal(stats.open.awaiting_pickup, 1);
  const third = ok(await s.api.post('/shipments', order()), 201);
  const gone = ok(await as(owner).post(`${C}/shipments/${third.id}/cancel`, { note: 'No van today' }));
  assert.equal(gone.status, 'cancelled');
});

test('driver navigation without Wufour Maps answers 502', async () => {
  const res = await as(driver).get(`/api/app/orgs/${s.c}/courier/route?from=33.5,36.25&to=33.51,36.27`);
  assert.equal(res.status, 502);
  assert.equal(res.data.error.code, 'routing_unavailable');
  assert.equal((await as(driver).get(`/api/app/orgs/${s.c}/courier/route?from=xx&to=33.51,36.27`)).status, 400);
});

test('api v1 reference data and unknown endpoints', async () => {
  const govs = await (await raw('/api/v1/governorates')).json();
  assert.equal(govs.length, 14);
  const st = await (await raw('/api/v1/statuses')).json();
  assert.equal(st.statuses.length, 12);
  assert.equal((await raw('/api/v1/nope')).status, 401);
  const nope = await s.api.get('/nope?x=1');
  assert.equal(nope.status, 404);
  assert.equal(nope.data.error.message, 'No such endpoint: GET /api/v1/nope?x=1');
  const api404 = await raw('/api/what');
  assert.equal(api404.status, 404);
  assert.deepEqual(await api404.json(), { error: { code: 'not_found', message: 'No such endpoint' } });
  const pub404 = await raw('/api/public/what');
  assert.equal(pub404.status, 404);
  assert.equal(pub404.headers.get('access-control-allow-origin'), '*');
  assert.equal((await raw('/api/public/track/x', { method: 'OPTIONS' })).status, 204);
  assert.equal((await raw('/api/public/client-errors', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ message: 'Boom', stack: 'at x', page: '/app' }) })).status, 204);
  const badJson = await raw('/api/v1/shipments', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{oops' });
  assert.equal(badJson.status, 400);
  assert.deepEqual(await badJson.json(), { error: { code: 'invalid_json', message: 'Request body is not valid JSON' } });
});

test('internal search and track need the shared key', async () => {
  const post = (p, body, key) => raw(`/api/internal${p}`, { method: 'POST', headers: { 'Content-Type': 'application/json', ...(key ? { 'X-Internal-Key': key } : {}) }, body: JSON.stringify(body) });
  assert.equal((await post('/search', { userId: shop.userId, query: 'Huda' })).status, 401);
  const found = await (await post('/search', { userId: shop.userId, query: 'Huda' }, process.env.INTERNAL_API_KEY)).json();
  assert.ok(found.results.length >= 1);
  assert.match(found.results[0].title, /Huda/);
  const tracked = await (await post('/track', { query: s.ship.trackingNumber.toLowerCase(), lang: 'ar' }, process.env.INTERNAL_API_KEY)).json();
  assert.equal(tracked.results[0].status, 'awaiting_pickup');
  assert.equal(tracked.more.label, 'افتح في طرف');
  const none = await (await post('/track', { query: 'TRF0000000000' }, process.env.INTERNAL_API_KEY)).json();
  assert.equal(none.results[0].status, 'not_found');
});

test('pages: labels, manifests, tracking, legal, sign-in', async () => {
  const token = s.ship.labelUrl.split('/label/')[1];
  const label = await raw(`/label/${token}`);
  assert.equal(label.status, 200);
  assert.match(label.headers.get('content-type'), /text\/html/);
  assert.match(await label.text(), /<svg xmlns/);
  assert.equal((await raw('/label/short')).status, 404);
  const labels = await raw(`/labels?t=${token},${token}`);
  assert.match(await labels.text(), /<title>2 labels<\/title>/);
  const manifest = await (await raw('/manifest.webmanifest')).json();
  assert.equal(manifest.start_url, '/app/');
  const orgManifest = await raw('/o/route-co/manifest.webmanifest');
  assert.equal(orgManifest.status, 200);
  assert.equal((await orgManifest.json()).name, 'Route Co');
  assert.equal((await raw('/o/nobody-here/manifest.webmanifest')).status, 404);
  assert.equal((await raw('/o/route-co/asset/logo.png')).status, 404);
  const fav = await raw('/favicon.ico');
  assert.equal(fav.status, 301);
  assert.equal(fav.headers.get('location'), '/img/icon-192.png');
  const terms = await raw('/terms');
  assert.equal(terms.status, 200);
  assert.doesNotMatch(await terms.text(), /\{\{LEGAL_NAME\}\}/);
  const t = await raw(`/t/${s.ship.trackingToken}`);
  assert.match(t.headers.get('content-security-policy'), /frame-ancestors 'none'/);
  assert.equal(t.headers.get('referrer-policy'), 'no-referrer');
  const embed = await raw(`/embed/t/${s.ship.trackingToken}`);
  assert.match(embed.headers.get('content-security-policy'), /frame-ancestors \*/);
  assert.equal(embed.headers.get('x-frame-options'), null);
  const login = await raw('/auth/login?next=//evil.example');
  assert.equal(login.status, 302);
  assert.match(login.headers.get('location'), /returnTo=.*next%3D%252Fapp/);
  const out = await raw('/auth/logout', { headers: { Accept: 'application/json', Cookie: `wufour_token=${shop.token}` } });
  assert.deepEqual(await out.json(), { ok: true });
  assert.match(out.headers.get('set-cookie'), /wufour_token=; Path=\/; Max-Age=0/);
  const cb = await raw(`/auth/callback?token=${shop.token}&next=/o/lama-store`);
  assert.equal(cb.status, 302);
  assert.equal(cb.headers.get('location'), '/o/lama-store');
  const page = await raw('/o/lama-store/shipments', { headers: { Cookie: `wufour_token=${shop.token}` } });
  assert.equal(page.status, 200);
  assert.match(await page.text(), /Lama Store/);
  assert.equal((await raw('/not-a-page')).status, 404);
  assert.equal((await raw('/sw.js')).headers.get('service-worker-allowed'), '/');
});
