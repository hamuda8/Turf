// Records the shape of every JSON answer the tests receive: one line per field, as
// "METHOD /route/:id status field.path type". Run the suite against Turf-js and against the Zig
// server with TURF_SHAPES pointing at two files and compare them (node compare-shapes.mjs).

import fs from 'node:fs';

const typeOf = v => (v === null ? 'null' : Array.isArray(v) ? 'array' : typeof v);

function walk(lines, prefix, v) {
  const t = typeOf(v);
  lines.push(`${prefix || '.'} ${t}`);
  if (t === 'array') for (const x of v) walk(lines, `${prefix}[]`, x);
  else if (t === 'object') for (const [k, x] of Object.entries(v)) walk(lines, prefix ? `${prefix}.${k}` : k, x);
}

/** "/api/app/orgs/6a.../members/6b..." -> "/api/app/orgs/:id/members/:id" (ids, tokens, numbers). */
function template(url) {
  const u = new URL(url);
  return u.pathname.split('/').map(p => {
    if (/^[0-9a-f]{24}$/i.test(p)) return ':id';
    if (/^TRF[0-9A-Z]{10}$/.test(p)) return ':tracking';
    if (/^[A-Za-z0-9_-]{16,}$/.test(p) && /\d/.test(p)) return ':token';
    return p;
  }).join('/');
}

export function record(getBase, file) {
  const original = globalThis.fetch;
  globalThis.fetch = async (input, init = {}) => {
    const res = await original(input, init);
    const url = typeof input === 'string' ? input : input.url;
    if (!url.startsWith(getBase()) || url.includes('/__test/')) return res;
    if (!(res.headers.get('content-type') || '').includes('application/json')) return res;
    try {
      const data = await res.clone().json();
      const lines = [];
      walk(lines, '', data);
      const head = `${(init.method || 'GET').toUpperCase()} ${template(url)} ${res.status}`;
      fs.appendFileSync(file, lines.map(l => `${head} ${l}\n`).join(''));
    } catch { /* not JSON after all */ }
    return res;
  };
}
