// Runs Turf-js's own test suite (Turf-js/tests/*.test.js, unchanged assertions) against the Zig
// server, plus the extra tests in this folder.
//
//   zig build server && node tests/parity/run.mjs [name-filter]
//
// The test files are copied into tests/parity/gen/ with three kinds of import rewritten:
//   './helpers.js'         -> this folder's helpers.mjs (starts zig-out/bin/turf-server)
//   '../src/...'           -> this folder's src/ (the same functions, run by the Zig binary)
//   '../public/...', '../scripts/...' and the source file one test reads -> Turf-js itself
// Env: TURF_JS (default ../Turf-js), TURF_SERVER, TEST_MONGO_URI, TURF_TEST_DB, TURF_ZIG_LOG=1.

import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';
import { TURF_JS } from './zig.mjs';

const HERE = import.meta.dirname;
const GEN = path.join(HERE, 'gen');
const SRC_TESTS = path.join(TURF_JS, 'tests');
// --node: the same copies against Turf-js itself (its real modules instead of src/), for comparisons.
const NODE = process.argv.includes('--node');
if (NODE) process.env.TURF_TARGET = 'node';
const filter = process.argv.slice(2).find(a => !a.startsWith('--')) || '';

fs.rmSync(GEN, { recursive: true, force: true });
fs.mkdirSync(GEN, { recursive: true });
fs.writeFileSync(path.join(GEN, 'helpers.js'), "export * from '../helpers.mjs';\n");

const turfUrl = rel => pathToFileURL(path.join(TURF_JS, rel)).href;
const files = [];
for (const name of fs.readdirSync(SRC_TESTS).filter(n => n.endsWith('.test.js')).sort()) {
  if (filter && !name.includes(filter)) continue;
  let src = fs.readFileSync(path.join(SRC_TESTS, name), 'utf8');
  // Module specifiers outside tests/ and src/ point at Turf-js itself.
  src = src.replace(/(from\s+|import\()'\.\.\/(public|scripts)\/([^']+)'/g, (_, p, dir, rest) => `${p}'${turfUrl(`${dir}/${rest}`)}'`);
  // Plain paths (path.resolve(..., '../public/js')) and the source file unit.test.js reads.
  src = src.replace(/'\.\.\/public\/([^']*)'/g, (_, rest) => JSON.stringify(path.join(TURF_JS, 'public', rest)));
  src = src.replace(/new URL\('\.\.\/src\/([^']+)', import\.meta\.url\)/g, (_, rest) => `new URL('${turfUrl(`src/${rest}`)}')`);
  if (NODE) src = src.replace(/(from\s+|import\()'\.\.\/src\/([^']+)'/g, (_, p, rest) => `${p}'${turfUrl(`src/${rest}`)}'`);
  fs.writeFileSync(path.join(GEN, name), src);
  files.push(path.join(GEN, name));
}
// The extra tests cover what only the Zig server adds (Bearer tokens) or Turf-js's tests leave out.
for (const name of NODE ? [] : fs.readdirSync(HERE).filter(n => n.endsWith('.test.mjs')).sort()) {
  if (filter && !name.includes(filter)) continue;
  files.push(path.join(HERE, name));
}

// Tests that hold for both servers (and can be compared with --node).
for (const name of fs.readdirSync(path.join(HERE, 'both')).filter(n => n.endsWith('.test.mjs')).sort()) {
  if (filter && !name.includes(filter)) continue;
  files.push(path.join(HERE, 'both', name));
}

const res = spawnSync(process.execPath, ['--test', '--test-concurrency=1', ...files], { stdio: 'inherit', env: process.env });
process.exit(res.status ?? 1);
