// Webhook delivery, the background job Turf-js's tests never start: a store's endpoint gets
// signed POSTs ("Turf-Signature: t=<s>,v1=<hex hmac of '<t>.<body>'>") for its shipments.

import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import crypto from 'node:crypto';
import { as, makeUser, withKey, shutdown } from './helpers.mjs';
import { hook } from './zig.mjs';

const received = [];
const receiver = http.createServer((req, res) => {
  let body = '';
  req.on('data', c => { body += c; });
  req.on('end', () => {
    received.push({ headers: req.headers, body });
    res.end('ok');
  });
});
await new Promise(r => receiver.listen(0, '127.0.0.1', r));

after(async () => {
  receiver.close();
  await shutdown();
});

test('shipment events reach the store signed, in order', async () => {
  await hook('startWebhooks');
  const shop = makeUser('Hooky');
  const org = (await as(shop).post('/api/app/orgs', { acceptTerms: true, type: 'merchant', name: 'Hook Shop', slug: 'hook-shop' })).data;
  const B = `/api/app/orgs/${org.id}/merchant`;
  const { secret } = (await as(shop).put(`${B}/webhook`, { url: `http://127.0.0.1:${receiver.address().port}/turf` })).data;
  const key = (await as(shop).post(`${B}/api-keys`, { name: 'test', mode: 'test' })).data.secret;
  const ship = await withKey(key).post('/shipments', {
    pickup: { name: 'Shop', phone: '0944000001', governorate: 'DI', city: 'Damascus' },
    dropoff: { name: 'Rana', phone: '0944000002', governorate: 'DI', city: 'Damascus' },
    parcel: { weightKg: 1 },
  });
  assert.equal(ship.status, 201);
  assert.equal((await withKey(key).post(`/shipments/${ship.data.id}/simulate`, { to: 'at_hub' })).status, 200);

  for (let i = 0; i < 100 && received.length < 3; i++) await new Promise(r => setTimeout(r, 200));
  assert.equal(received.length, 3, 'created, picked up, arrived at hub');
  const types = received.map(r => JSON.parse(r.body).type);
  assert.deepEqual(types, ['shipment.created', 'shipment.updated', 'shipment.updated']);
  for (const r of received) {
    const [t, v1] = r.headers['turf-signature'].split(',').map(p => p.split('=')[1]);
    assert.equal(v1, crypto.createHmac('sha256', secret).update(`${t}.${r.body}`).digest('hex'));
    assert.equal(r.headers['user-agent'], 'Turf-Webhooks/1');
    assert.equal(r.headers['turf-delivery'], JSON.parse(r.body).id);
  }
  const updated = JSON.parse(received[2].body);
  assert.equal(updated.data.event.code, 'arrived_at_hub');
  assert.equal(updated.data.shipment.status, 'at_hub');

  const log = (await as(shop).get(`${B}/webhook`)).data.deliveries;
  assert.equal(log.length, 3);
  assert.ok(log.every(d => d.status === 'delivered' && d.attempts === 1 && d.lastStatus === 200));
});
