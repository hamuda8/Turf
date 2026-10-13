// Pages from the zui web build (zig-out/web, the default public folder): the single page for the
// app, tracking and lookup paths, developers.html, the build's files, and a Content-Security-Policy
// that lets its inline scripts and WebAssembly run. Skipped until `zig build web` has run.

import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { existsSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { shutdown } from './helpers.mjs';
import { TURF_SERVER } from './zig.mjs';

const WEB = path.join(path.dirname(TURF_SERVER), '..', 'web');
const built = existsSync(path.join(WEB, 'index.html')) && existsSync(path.join(WEB, 'app.wasm'));
const port = 5900 + Math.floor(Math.random() * 90);
const base = `http://127.0.0.1:${port}`;
let server = null;

after(async () => {
  server?.kill();
  await shutdown();
});

test('the zui web build is served as one page', { skip: !built && 'run zig build web first' }, async () => {
  const env = { ...process.env, PORT: String(port), LISTEN: '127.0.0.1', MONGO_DB: `${process.env.MONGO_DB}_zui` };
  delete env.TURF_PUBLIC_DIR;
  server = spawn(TURF_SERVER, [], { cwd: mkdtempSync(path.join(tmpdir(), 'turf-zui-')), env, stdio: 'ignore' });
  for (let i = 0; ; i++) {
    try { if ((await fetch(`${base}/healthz`)).ok) break; } catch { /* starting */ }
    if (i > 100) throw new Error('turf-server did not start');
    await new Promise(r => setTimeout(r, 100));
  }
  const index = await (await fetch(`${base}/index.html`)).text();
  for (const p of ['/', '/app', '/app/shipments/1', '/o/some-shop/settings', '/invite/abc', '/t/abcdefghijklmnop', '/embed/t/abcdefghijklmnop', '/track', '/terms']) {
    const res = await fetch(`${base}${p}`, { redirect: 'manual' });
    assert.equal(res.status, 200, p);
    assert.equal(await res.text(), index, p);
  }
  const page = await fetch(`${base}/app`);
  const policy = page.headers.get('content-security-policy');
  assert.match(policy, /'wasm-unsafe-eval'/);
  // Every inline script is allowed by its hash (computed after HTML newline normalization).
  for (const [, body] of index.matchAll(/<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/g)) {
    const hash = crypto.createHash('sha256').update(body.replace(/\r\n?/g, '\n')).digest('base64');
    assert.ok(policy.includes(`'sha256-${hash}'`), 'inline script hash in the policy');
  }
  assert.match((await fetch(`${base}/embed/t/abcdefghijklmnop`)).headers.get('content-security-policy'), /frame-ancestors \*/);
  assert.match(await (await fetch(`${base}/developers`)).text(), /<html/);
  assert.equal((await fetch(`${base}/app.wasm`)).headers.get('content-type'), 'application/wasm');
  for (const f of ['/zui.js', '/manifest.json', '/sw.js', '/offline.html']) assert.equal((await fetch(`${base}${f}`)).status, 200, f);
  assert.equal((await fetch(`${base}/api/public/platform`)).status, 200);
});
