// Native apps (Android, iOS) sign in through Wufour and send the session token as
// "Authorization: Bearer <token>" instead of a cookie. Not part of Turf-js: this checks the Zig
// server's addition, and that the cookie behaviour of the web app is unchanged.

import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { baseUrl, makeUser, shutdown } from './helpers.mjs';

after(shutdown);

const bearer = (user, extra = {}) => ({ Authorization: `Bearer ${user.token}`, ...extra });

test('Bearer tokens work on the app API, without cookies or the CSRF header', async () => {
  const u = makeUser('Native');
  const me = await fetch(`${baseUrl}/api/app/me`, { headers: bearer(u) });
  assert.equal(me.status, 200);
  assert.equal((await me.json()).user.id, u.userId);
  assert.equal(me.headers.get('set-cookie'), null, 'no cookies for native apps');

  // State changes need no X-Requested-With: a browser never adds an Authorization header by itself.
  const created = await fetch(`${baseUrl}/api/app/orgs`, {
    method: 'POST',
    headers: bearer(u, { 'Content-Type': 'application/json' }),
    body: JSON.stringify({ acceptTerms: true, type: 'merchant', name: 'Native Shop', slug: 'native-shop' }),
  });
  assert.equal(created.status, 201);
  const org = await created.json();
  const view = await fetch(`${baseUrl}/api/app/orgs/${org.id}`, { headers: bearer(u) });
  assert.equal(view.status, 200);
  assert.equal((await view.json()).me.isOwner, true);
});

test('a bad Bearer token gets 401 JSON, never a redirect', async () => {
  const api = await fetch(`${baseUrl}/api/app/me`, { headers: { Authorization: 'Bearer nope' } });
  assert.equal(api.status, 401);
  assert.equal((await api.json()).error.code, 'unauthenticated');

  const page = await fetch(`${baseUrl}/app`, { headers: { Authorization: 'Bearer nope' }, redirect: 'manual' });
  assert.equal(page.status, 401);
  assert.equal((await page.json()).error.code, 'unauthenticated');

  const json = await fetch(`${baseUrl}/app/shipments`, { headers: { Accept: 'application/json' }, redirect: 'manual' });
  assert.equal(json.status, 401);
});

test('pages accept a Bearer token; browsers without one are still sent to Wufour', async () => {
  const u = makeUser('NativePage');
  const page = await fetch(`${baseUrl}/app`, { headers: bearer(u), redirect: 'manual' });
  assert.equal(page.status, 200);
  assert.match(page.headers.get('content-type'), /text\/html/);

  const browser = await fetch(`${baseUrl}/app`, { redirect: 'manual' });
  assert.equal(browser.status, 302);
  assert.match(browser.headers.get('location'), /\/auth\?returnTo=/);
});

test('cookies keep working as before (renewed, CSRF header required)', async () => {
  const u = makeUser('Web');
  const me = await fetch(`${baseUrl}/api/app/me`, { headers: { Cookie: `wufour_token=${u.token}` } });
  assert.equal(me.status, 200);
  assert.match(me.headers.get('set-cookie') || '', /wufour_token=/);
  const post = await fetch(`${baseUrl}/api/app/orgs`, {
    method: 'POST',
    headers: { Cookie: `wufour_token=${u.token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ acceptTerms: true, type: 'merchant', name: 'Web Shop', slug: 'web-shop' }),
  });
  assert.equal(post.status, 403);
  assert.equal((await post.json()).error.code, 'csrf');
});

test('the live stream accepts a Bearer token', async () => {
  const u = makeUser('NativeLive');
  const created = await fetch(`${baseUrl}/api/app/orgs`, {
    method: 'POST',
    headers: bearer(u, { 'Content-Type': 'application/json' }),
    body: JSON.stringify({ acceptTerms: true, type: 'merchant', name: 'Live Shop', slug: 'live-shop' }),
  });
  const org = await created.json();
  const ctrl = new AbortController();
  const res = await fetch(`${baseUrl}/api/app/orgs/${org.id}/stream`, { headers: bearer(u), signal: ctrl.signal });
  assert.equal(res.status, 200);
  assert.match(res.headers.get('content-type'), /text\/event-stream/);
  const reader = res.body.getReader();
  let text = '';
  while (!text.includes('event: hello')) text += new TextDecoder().decode((await reader.read()).value);
  assert.match(text, /retry: 5000/);
  ctrl.abort();
});
