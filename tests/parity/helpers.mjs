// Turf-js's tests/helpers.js for the Zig server: the same fake Wufour verify endpoint, a
// throwaway database (TurfTest_zig unless TURF_TEST_DB says otherwise) and the same client
// helpers, but the server is zig-out/bin/turf-server instead of the Node app. The Turf-js
// database module is still used by tests that read or write documents directly.

import http from 'node:http';
import { spawn } from 'node:child_process';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { TURF_JS, TURF_SERVER, setBase } from './zig.mjs';

const users = new Map(); // token -> user

const fakeWufour = http.createServer((req, res) => {
  let body = '';
  req.on('data', c => { body += c; });
  req.on('end', () => {
    res.setHeader('Content-Type', 'application/json');
    if (req.url === '/api/auth/verify') {
      const { token } = JSON.parse(body || '{}');
      const user = users.get(token);
      return res.end(JSON.stringify(user ? { success: true, user } : { success: false, message: 'Invalid token' }));
    }
    if (req.url === '/api/auth/logout') return res.end('{"success":true}');
    res.statusCode = 404;
    res.end('{}');
  });
});
await new Promise(r => fakeWufour.listen(0, '127.0.0.1', r));

process.env.AUTH_HOST = `http://127.0.0.1:${fakeWufour.address().port}`;
process.env.MONGO_URI = process.env.TEST_MONGO_URI || 'mongodb://127.0.0.1:27017';
const NODE = process.env.TURF_TARGET === 'node';
process.env.MONGO_DB = process.env.TURF_TEST_DB || (NODE ? 'Turf_test' : 'TurfTest_zig');
process.env.APP_SECRET = 'test-secret-test-secret-test-secret';
process.env.AUTO_APPROVE_CARRIERS = 'true';
process.env.MERCHANT_SIGNUP = 'open';
process.env.NODE_ENV = 'test';
process.env.PLATFORM_ADMIN_USER_IDS = 'admin0000000000000000001';
// Never read an env file (the Zig server would otherwise look for .env.production).
process.env.TURF_ENV_FILE = '';
process.env.TURF_PUBLIC_DIR = path.join(TURF_JS, 'public');
// Turf-js's helpers start live updates, dispatch and push only (emails start in their test).
process.env.TURF_SERVICES = 'live,dispatch,push';

const { connect, getDb, client } = await import(pathToFileURL(path.join(TURF_JS, 'src/db.js')).href);
await connect();
await getDb().dropDatabase();

// TURF_TARGET=node runs the same tests against Turf-js itself (as its own helpers do), so the
// two servers can be compared answer by answer (TURF_SHAPES).
let server = null;
let stopNode = null;
export let baseUrl = '';
if (NODE) {
  const src = rel => import(pathToFileURL(path.join(TURF_JS, 'src', rel)).href);
  const { createApp } = await src('server.js');
  const { startLive } = await src('services/live.js');
  const { startDispatch, stopDispatch } = await src('services/dispatch.js');
  const { startPush } = await src('services/push.js');
  await connect(); // recreate indexes
  startLive();
  startDispatch();
  startPush();
  const app = createApp().listen(0, '127.0.0.1');
  await new Promise(r => app.once('listening', r));
  baseUrl = `http://127.0.0.1:${app.address().port}`;
  stopNode = async () => { stopDispatch(); app.closeAllConnections(); await new Promise(r => app.close(r)); };
} else {
  const port = 5200 + Math.floor(Math.random() * 700);
  server = spawn(TURF_SERVER, [], {
    cwd: mkdtempSync(path.join(tmpdir(), 'turf-zig-')),
    env: { ...process.env, PORT: String(port), LISTEN: '127.0.0.1' },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let log = '';
  server.stdout.on('data', d => { log += d; });
  server.stderr.on('data', d => { log += d; if (process.env.TURF_ZIG_LOG) process.stderr.write(d); });
  baseUrl = `http://127.0.0.1:${port}`;
  for (let i = 0; ; i++) {
    try {
      const r = await fetch(`${baseUrl}/healthz`);
      if (r.ok) break;
    } catch { /* not up yet */ }
    if (i > 100 || server.exitCode !== null) throw new Error(`turf-server did not start:\n${log}`);
    await new Promise(r => setTimeout(r, 100));
  }
}
setBase(baseUrl);
if (process.env.TURF_SHAPES) (await import('./shapes.mjs')).record(() => baseUrl, process.env.TURF_SHAPES);

let counter = 0;
export function makeUser(name) {
  counter++;
  const userId = (counter.toString(16).padStart(24, 'a')).slice(-24);
  const user = { userId, email: `${name.toLowerCase()}@example.com`, username: name, role: 'user' };
  users.set(`tok_${userId}`, user);
  return { ...user, token: `tok_${userId}` };
}

export function adminUser() {
  const user = { userId: 'admin0000000000000000001', email: 'admin@turf.test', username: 'Admin', role: 'user' };
  users.set('tok_admin', user);
  return { ...user, token: 'tok_admin' };
}

/** JSON client acting as a signed-in user. */
export function as(user) {
  const call = async (method, p, body) => {
    const res = await fetch(`${baseUrl}${p}`, {
      method,
      headers: {
        Cookie: `wufour_token=${user.token}`,
        'X-Requested-With': 'turf',
        ...(body !== undefined ? { 'Content-Type': 'application/json' } : {}),
      },
      body: body !== undefined ? JSON.stringify(body) : undefined,
    });
    const text = await res.text();
    let data;
    try { data = JSON.parse(text); } catch { data = text; }
    return { status: res.status, data, headers: res.headers };
  };
  return {
    get: p => call('GET', p),
    post: (p, b = {}) => call('POST', p, b),
    patch: (p, b = {}) => call('PATCH', p, b),
    put: (p, b = {}) => call('PUT', p, b),
    del: p => call('DELETE', p),
  };
}

/** JSON client using a merchant API key. */
export function withKey(secret) {
  const call = async (method, p, body) => {
    const res = await fetch(`${baseUrl}/api/v1${p}`, {
      method,
      headers: { Authorization: `Bearer ${secret}`, ...(body ? { 'Content-Type': 'application/json' } : {}) },
      body: body ? JSON.stringify(body) : undefined,
    });
    return { status: res.status, data: await res.json(), headers: res.headers };
  };
  return { get: p => call('GET', p), post: (p, b = {}) => call('POST', p, b), patch: (p, b = {}) => call('PATCH', p, b) };
}

export async function publicGet(p) {
  const res = await fetch(`${baseUrl}${p}`);
  return { status: res.status, data: await res.json().catch(() => null) };
}

export async function publicPost(p, body) {
  const res = await fetch(`${baseUrl}${p}`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
  return { status: res.status, data: await res.json().catch(() => null) };
}

export async function shutdown() {
  if (server) server.kill();
  if (stopNode) await stopNode();
  fakeWufour.close();
  await client.close();
}

export const sleep = ms => new Promise(r => setTimeout(r, ms));
