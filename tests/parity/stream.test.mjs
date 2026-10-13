// Live updates over Server-Sent Events reach an open stream (Turf-js's tests open none).
// Not part of Turf-js: a store's API stream follows a practice shipment moved with /simulate.

import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { as, baseUrl, makeUser, withKey, shutdown } from './helpers.mjs';

after(shutdown);

test('a shipment stream gets the tracking snapshot, then every status change', async () => {
  const owner = makeUser('Streamer');
  const org = (await as(owner).post('/api/app/orgs', { acceptTerms: true, type: 'merchant', name: 'Stream Shop', slug: 'stream-shop' })).data;
  const key = (await as(owner).post(`/api/app/orgs/${org.id}/merchant/api-keys`, { name: 'test', mode: 'test' })).data.secret;
  const created = await withKey(key).post('/shipments', {
    pickup: { name: 'Shop', phone: '0944000001', governorate: 'DI', city: 'Damascus' },
    dropoff: { name: 'Rana', phone: '0944000002', governorate: 'DI', city: 'Damascus' },
    parcel: { weightKg: 1 },
  });
  assert.equal(created.status, 201);

  const ctrl = new AbortController();
  const res = await fetch(`${baseUrl}/api/v1/shipments/${created.data.id}/stream`, { headers: { Authorization: `Bearer ${key}` }, signal: ctrl.signal });
  assert.equal(res.status, 200);
  const reader = res.body.getReader();
  let text = '';
  const until = async needle => {
    const deadline = Date.now() + 5000;
    while (!text.includes(needle)) {
      if (Date.now() > deadline) throw new Error(`no "${needle}" in:\n${text}`);
      text += new TextDecoder().decode((await reader.read()).value);
    }
  };
  await until('event: tracking');
  assert.equal((await withKey(key).post(`/shipments/${created.data.id}/simulate`, { to: 'picked_up' })).status, 200);
  await until('event: tracking.event');
  assert.match(text, /"status":"picked_up"/);
  ctrl.abort();
});

test('at most 30 live streams per address; a closed stream frees its place at once', async () => {
  const owner = makeUser('Watcher');
  const org = (await as(owner).post('/api/app/orgs', { acceptTerms: true, type: 'merchant', name: 'Watch Shop', slug: 'watch-shop' })).data;
  const key = (await as(owner).post(`/api/app/orgs/${org.id}/merchant/api-keys`, { name: 'test', mode: 'test' })).data.secret;
  const ship = (await withKey(key).post('/shipments', {
    pickup: { name: 'Shop', phone: '0944000001', governorate: 'DI', city: 'Damascus' },
    dropoff: { name: 'Rana', phone: '0944000002', governorate: 'DI', city: 'Damascus' },
    parcel: { weightKg: 1 },
  })).data;
  const url = `${baseUrl}/api/public/track/${ship.trackingToken}/stream`;
  const open = async () => {
    const ctrl = new AbortController();
    const res = await fetch(url, { signal: ctrl.signal });
    return { res, ctrl };
  };
  const streams = [];
  for (let i = 0; i < 30; i++) streams.push(await open());
  assert.ok(streams.every(s => s.res.status === 200));
  const extra = await open();
  assert.equal(extra.res.status, 429);
  assert.equal((await extra.res.json()).error.code, 'too_many_streams');
  for (const s of streams) s.ctrl.abort();
  await new Promise(r => setTimeout(r, 300));
  const again = await open();
  assert.equal(again.res.status, 200);
  again.ctrl.abort();
});
