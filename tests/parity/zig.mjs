// Bridge from Turf-js's tests to the Zig server: `cli` runs a pure function through
// `turf-server --call` (synchronous, like the JavaScript function it stands for); `hook` runs a
// function inside the running server (POST /__test/call). Values travel as typed JSON.

import { execFileSync } from 'node:child_process';
import path from 'node:path';
import { createRequire } from 'node:module';

const HERE = import.meta.dirname;
export const TURF_JS = path.resolve(process.env.TURF_JS || path.join(HERE, '../../../Turf-js'));
export const TURF_SERVER = path.resolve(process.env.TURF_SERVER || path.join(HERE, '../../zig-out/bin', process.platform === 'win32' ? 'turf-server.exe' : 'turf-server'));
const { ObjectId, Binary } = createRequire(path.join(TURF_JS, 'package.json'))('mongodb');
export { ObjectId, Binary };

/** The same shape as Turf-js's src/http.js HttpError. */
export class HttpError extends Error {
  constructor(status, code, message, extra = {}) {
    super(message);
    this.status = status;
    this.code = code;
    this.extra = extra;
  }
}

function encode(v) {
  if (v === undefined) return { $undef: 1 };
  if (v === null || typeof v !== 'object') return v;
  if (v instanceof Date) return { $date: v.getTime() };
  if (v instanceof ObjectId) return { $oid: v.toHexString() };
  if (Buffer.isBuffer(v)) return { $bin: v.toString('base64') };
  if (v instanceof Set) return [...v].map(encode);
  if (v instanceof RegExp) return { $undef: 1 };
  if (Array.isArray(v)) return v.map(encode);
  const out = {};
  for (const [k, x] of Object.entries(v)) if (typeof x !== 'function') out[k] = encode(x);
  return out;
}

export function decode(v) {
  if (v === null || typeof v !== 'object') return v;
  if (Array.isArray(v)) return v.map(decode);
  const keys = Object.keys(v);
  if (keys.length === 1) {
    if (keys[0] === '$date') return new Date(v.$date);
    if (keys[0] === '$oid') return new ObjectId(v.$oid);
    if (keys[0] === '$undef') return undefined;
    if (keys[0] === '$bin') return Buffer.from(v.$bin, 'base64');
  }
  const out = {};
  for (const k of keys) out[k] = decode(v[k]);
  return out;
}

function unwrap(answer) {
  const data = decode(answer);
  if (data && typeof data === 'object' && '$error' in data) {
    const e = data.$error;
    throw new HttpError(e.status, e.code, e.message, e.extra || {});
  }
  return data.result;
}

/** A pure function, run by the Zig binary. */
export function cli(fn, ...args) {
  const out = execFileSync(TURF_SERVER, ['--call', fn, JSON.stringify(encode(args))], { env: process.env, encoding: 'utf8' });
  return unwrap(JSON.parse(out));
}

let base = null;
export function setBase(url) { base = url; }

/** A function inside the running Zig server. */
export async function hook(fn, ...args) {
  const res = await fetch(`${base}/__test/call`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ fn, args: encode(args) }) });
  const text = await res.text();
  if (!res.ok) throw new Error(`test hook ${fn}: HTTP ${res.status} ${text}`);
  return unwrap(JSON.parse(text));
}
