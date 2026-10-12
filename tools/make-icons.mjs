// make-icons.mjs: turns Material Symbols glyphs into zui.Icon constants (SVG path data).
//
// Reads the self-hosted Material Symbols Rounded subset (a variable WOFF2 font), finds each
// icon's glyph through the font's ligatures (the icon name typed as text), applies the
// variation the web app renders with (wght 500, GRAD 0, opsz 24, FILL 0 and FILL 1), and writes
// the outlines as SVG path data to src/client/icons.zig. Node built-ins only, no packages.
//
//   node tools/make-icons.mjs [font.woff2] [out.zig] [names.json]
//
// Defaults: ../Turf-js/public/fonts/material-symbols-rounded.woff2, src/client/icons.zig and
// ../Turf-js/public/fonts/material-symbols.json (its "names" array lists the icons to extract).
// Set ICONS_JSON=<file> to also dump the paths as JSON (for comparing against the font in a browser).

import { readFileSync, writeFileSync } from 'node:fs';
import { brotliDecompressSync } from 'node:zlib';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const fontsDir = resolve(root, '../Turf-js/public/fonts');
const fontPath = process.argv[2] ?? join(fontsDir, 'material-symbols-rounded.woff2');
const outPath = process.argv[3] ?? join(root, 'src/client/icons.zig');
const namesPath = process.argv[4] ?? join(dirname(fontPath), 'material-symbols.json');

// The variation the app's CSS renders icons with; FILL is 0 for outlined, 1 for filled.
const AXES = { wght: 500, GRAD: 0, opsz: 24 };

// ---- byte reading ----------------------------------------------------------------------------

class Reader {
  constructor(bytes, pos = 0) {
    this.b = bytes;
    this.v = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    this.pos = pos;
  }
  u8() { return this.v.getUint8(this.pos++); }
  i8() { return this.v.getInt8(this.pos++); }
  u16() { const x = this.v.getUint16(this.pos); this.pos += 2; return x; }
  i16() { const x = this.v.getInt16(this.pos); this.pos += 2; return x; }
  u32() { const x = this.v.getUint32(this.pos); this.pos += 4; return x; }
  i32() { const x = this.v.getInt32(this.pos); this.pos += 4; return x; }
  fixed() { return this.i32() / 65536; }
  f2dot14() { return this.i16() / 16384; }
  tag() { const s = String.fromCharCode(...this.b.subarray(this.pos, this.pos + 4)); this.pos += 4; return s; }
  bytes(n) { const s = this.b.subarray(this.pos, this.pos + n); this.pos += n; return s; }
  // WOFF2 variable-length integers.
  base128() {
    let x = 0;
    for (let i = 0; i < 5; i++) {
      const b = this.u8();
      x = x * 128 + (b & 0x7f);
      if (!(b & 0x80)) return x;
    }
    throw new Error('bad UIntBase128');
  }
  u255() {
    const c = this.u8();
    if (c === 253) return this.u16();
    if (c === 255) return this.u8() + 253;
    if (c === 254) return this.u8() + 506;
    return c;
  }
}

// ---- WOFF2 container ---------------------------------------------------------------------------

const KNOWN_TAGS = ['cmap', 'head', 'hhea', 'hmtx', 'maxp', 'name', 'OS/2', 'post', 'cvt ', 'fpgm', 'glyf', 'loca', 'prep', 'CFF ', 'VORG', 'EBDT', 'EBLC', 'gasp', 'hdmx', 'kern', 'LTSH', 'PCLT', 'VDMX', 'vhea', 'vmtx', 'BASE', 'GDEF', 'GPOS', 'GSUB', 'EBSC', 'JSTF', 'MATH', 'CBDT', 'CBLC', 'COLR', 'CPAL', 'SVG ', 'sbix', 'acnt', 'avar', 'bdat', 'bloc', 'bsln', 'cvar', 'fdsc', 'feat', 'fmtx', 'fvar', 'gvar', 'hsty', 'just', 'lcar', 'mort', 'morx', 'opbd', 'prop', 'trak', 'Zapf', 'Silf', 'Glat', 'Gloc', 'Feat', 'Sill'];

/** Returns { tables: {tag: Uint8Array}, transformed: {tag: version}, info }. */
function readWoff2(file) {
  const r = new Reader(file);
  if (r.tag() !== 'wOF2') throw new Error('not a WOFF2 file');
  const flavor = r.u32();
  r.u32(); // length
  const numTables = r.u16();
  r.u16(); r.u32(); // reserved, totalSfntSize
  const compressedSize = r.u32();
  r.pos += 4 + 4 * 5; // version, meta and private blocks
  if (flavor === 0x74746366) throw new Error('font collections are not supported');
  const dir = [];
  for (let i = 0; i < numTables; i++) {
    const flags = r.u8();
    const tag = (flags & 0x3f) === 63 ? r.tag() : KNOWN_TAGS[flags & 0x3f];
    const version = flags >> 6;
    const origLength = r.base128();
    // glyf/loca are transformed unless version 3; other tables are transformed unless version 0.
    const transformed = tag === 'glyf' || tag === 'loca' ? version !== 3 : version !== 0;
    const length = transformed ? r.base128() : origLength;
    dir.push({ tag, version, transformed, length });
  }
  const data = new Uint8Array(brotliDecompressSync(file.subarray(r.pos, r.pos + compressedSize)));
  const tables = {}, transformed = {};
  let off = 0;
  for (const t of dir) {
    tables[t.tag] = data.subarray(off, off + t.length);
    if (t.transformed) transformed[t.tag] = t.version;
    off += t.length;
  }
  return { tables, transformed, flavor };
}

// ---- glyph outlines ---------------------------------------------------------------------------

// A glyph is null (empty), { contours: [[{x, y, on}]] } or { components: [{glyph, dx, dy, m}] }
// where m is the component's 2x2 transform [a, b, c, d] (x' = a*x + c*y, y' = b*x + d*y).

const ARG_WORDS = 0x1, ARGS_XY = 0x2, SCALE = 0x8, MORE = 0x20, XY_SCALE = 0x40, TWO_BY_TWO = 0x80, INSTRUCTIONS = 0x100;

function readComponents(r) {
  const components = [];
  let flags, instructions = false;
  do {
    flags = r.u16();
    const glyph = r.u16();
    let a1, a2;
    if (flags & ARG_WORDS) { a1 = r.i16(); a2 = r.i16(); } else { a1 = r.i8(); a2 = r.i8(); }
    if (!(flags & ARGS_XY)) throw new Error('point-matched composite components are not supported');
    let m = [1, 0, 0, 1];
    if (flags & SCALE) { const s = r.f2dot14(); m = [s, 0, 0, s]; }
    else if (flags & XY_SCALE) { m = [r.f2dot14(), 0, 0, r.f2dot14()]; }
    else if (flags & TWO_BY_TWO) { m = [r.f2dot14(), r.f2dot14(), r.f2dot14(), r.f2dot14()]; }
    if (flags & INSTRUCTIONS) instructions = true;
    components.push({ glyph, dx: a1, dy: a2, m });
  } while (flags & MORE);
  return { components, instructions };
}

/** Plain glyf + loca tables. */
function readGlyf(glyf, loca, numGlyphs, longLoca) {
  const lr = new Reader(loca);
  const offsets = [];
  for (let i = 0; i <= numGlyphs; i++) offsets.push(longLoca ? lr.u32() : lr.u16() * 2);
  const glyphs = [];
  for (let g = 0; g < numGlyphs; g++) {
    if (offsets[g + 1] === offsets[g]) { glyphs.push(null); continue; }
    const r = new Reader(glyf, offsets[g]);
    const nContours = r.i16();
    r.pos += 8; // bbox
    if (nContours < 0) { glyphs.push({ components: readComponents(r).components }); continue; }
    const ends = [];
    for (let i = 0; i < nContours; i++) ends.push(r.u16());
    r.pos += r.u16(); // instructions
    const n = nContours ? ends[nContours - 1] + 1 : 0;
    const flags = [];
    while (flags.length < n) {
      const f = r.u8();
      flags.push(f);
      if (f & 8) for (let k = r.u8(); k > 0; k--) flags.push(f);
    }
    const xs = [], ys = [];
    for (const [arr, short, same] of [[xs, 2, 16], [ys, 4, 32]]) {
      let v = 0;
      for (const f of flags) {
        if (f & short) v += f & same ? r.u8() : -r.u8();
        else if (!(f & same)) v += r.i16();
        arr.push(v);
      }
    }
    glyphs.push({ contours: splitContours(ends, flags.map((f, i) => ({ x: xs[i], y: ys[i], on: !!(f & 1) }))) });
  }
  return glyphs;
}

function splitContours(ends, points) {
  const contours = [];
  let start = 0;
  for (const e of ends) { contours.push(points.slice(start, e + 1)); start = e + 1; }
  return contours;
}

/** WOFF2 transformed glyf table (transform version 0). */
function readTransformedGlyf(data) {
  const r = new Reader(data);
  r.u16(); // version
  r.u16(); // optionFlags (bit 0: overlap bitmap, not needed here)
  const numGlyphs = r.u16();
  r.u16(); // indexFormat
  const sizes = [];
  for (let i = 0; i < 7; i++) sizes.push(r.u32());
  const streams = [];
  let off = r.pos;
  for (const s of sizes) { streams.push(new Reader(data.subarray(off, off + s))); off += s; }
  const [nContourS, nPointsS, flagS, glyphS, compositeS, , instructionS] = streams;
  // The bbox stream is skipped: outlines are all that is needed.

  const glyphs = [];
  for (let g = 0; g < numGlyphs; g++) {
    const nContours = nContourS.i16();
    if (nContours === 0) { glyphs.push(null); continue; }
    if (nContours < 0) {
      const { components, instructions } = readComponents(compositeS);
      if (instructions) instructionS.pos += glyphS.u255();
      glyphs.push({ components });
      continue;
    }
    const ends = [];
    let n = 0;
    for (let i = 0; i < nContours; i++) { n += nPointsS.u255(); ends.push(n - 1); }
    const points = [];
    let x = 0, y = 0;
    for (let i = 0; i < n; i++) {
      const raw = flagS.u8();
      const on = !(raw & 0x80);
      const f = raw & 0x7f;
      const sign = (bit, v) => (bit & 1 ? v : -v);
      let dx, dy;
      if (f < 10) {
        dx = 0; dy = sign(f, ((f & 14) << 7) + glyphS.u8());
      } else if (f < 20) {
        dx = sign(f, (((f - 10) & 14) << 7) + glyphS.u8()); dy = 0;
      } else if (f < 84) {
        const b0 = f - 20, b1 = glyphS.u8();
        dx = sign(f, 1 + (b0 & 0x30) + (b1 >> 4));
        dy = sign(f >> 1, 1 + ((b0 & 0x0c) << 2) + (b1 & 0x0f));
      } else if (f < 120) {
        const b0 = f - 84;
        dx = sign(f, 1 + (Math.floor(b0 / 12) << 8) + glyphS.u8());
        dy = sign(f >> 1, 1 + (((b0 % 12) >> 2) << 8) + glyphS.u8());
      } else if (f < 124) {
        const b0 = glyphS.u8(), b1 = glyphS.u8(), b2 = glyphS.u8();
        dx = sign(f, (b0 << 4) + (b1 >> 4));
        dy = sign(f >> 1, ((b1 & 0x0f) << 8) + b2);
      } else {
        const b0 = glyphS.u8(), b1 = glyphS.u8(), b2 = glyphS.u8(), b3 = glyphS.u8();
        dx = sign(f, (b0 << 8) + b1);
        dy = sign(f >> 1, (b2 << 8) + b3);
      }
      x += dx; y += dy;
      points.push({ x, y, on });
    }
    instructionS.pos += glyphS.u255();
    glyphs.push({ contours: splitContours(ends, points) });
  }
  return glyphs;
}

// ---- character map and ligatures -----------------------------------------------------------------

function readCmap(data) {
  const r = new Reader(data);
  r.u16();
  const n = r.u16();
  const subtables = [];
  for (let i = 0; i < n; i++) subtables.push({ platform: r.u16(), encoding: r.u16(), offset: r.u32() });
  const map = new Map();
  // Prefer format 12 (full Unicode), then format 4.
  const ordered = subtables
    .map((s) => ({ ...s, format: new Reader(data, s.offset).u16() }))
    .filter((s) => s.format === 4 || s.format === 12)
    .sort((a, b) => b.format - a.format);
  const s = ordered[0];
  if (!s) throw new Error('no cmap format 4 or 12 subtable');
  const t = new Reader(data, s.offset);
  if (s.format === 12) {
    t.pos += 12;
    const groups = t.u32();
    for (let i = 0; i < groups; i++) {
      const start = t.u32(), end = t.u32(), gid = t.u32();
      for (let c = start; c <= end; c++) map.set(c, gid + c - start);
    }
  } else {
    t.pos += 6;
    const segX2 = t.u16();
    const seg = segX2 / 2;
    t.pos += 6;
    const base = t.pos;
    const at = (k, i) => new Reader(data, base + k * segX2 + (k > 0 ? 2 : 0) + i * 2);
    for (let i = 0; i < seg; i++) {
      const end = at(0, i).u16(), start = at(1, i).u16(), delta = at(2, i).i16();
      const roPos = base + 3 * segX2 + 2 + i * 2;
      const ro = new Reader(data, roPos).u16();
      for (let c = start; c <= end && c !== 0xffff; c++) {
        let gid;
        if (ro === 0) gid = (c + delta) & 0xffff;
        else {
          gid = new Reader(data, roPos + ro + (c - start) * 2).u16();
          if (gid) gid = (gid + delta) & 0xffff;
        }
        if (gid) map.set(c, gid);
      }
    }
  }
  return map;
}

function readCoverage(data, off) {
  const r = new Reader(data, off);
  const format = r.u16();
  const cov = new Map(); // glyph -> coverage index
  if (format === 1) {
    const n = r.u16();
    for (let i = 0; i < n; i++) cov.set(r.u16(), i);
  } else if (format === 2) {
    const n = r.u16();
    for (let i = 0; i < n; i++) {
      const start = r.u16(), end = r.u16(), idx = r.u16();
      for (let g = start; g <= end; g++) cov.set(g, idx + g - start);
    }
  } else throw new Error(`coverage format ${format}`);
  return cov;
}

/** All ligature-substitution lookups in the GSUB, in lookup order: [Map(firstGlyph -> [{rest, glyph}])]. */
function readLigatureLookups(data) {
  const r = new Reader(data);
  r.u32(); // version
  r.u16(); r.u16(); // script and feature lists
  const lookupList = r.u16();
  const lr = new Reader(data, lookupList);
  const count = lr.u16();
  const lookups = [];
  for (let i = 0; i < count; i++) {
    const lookupOff = lookupList + lr.u16();
    const l = new Reader(data, lookupOff);
    let type = l.u16();
    l.u16(); // flags
    const n = l.u16();
    const subs = [];
    for (let k = 0; k < n; k++) subs.push(lookupOff + l.u16());
    const ligs = new Map();
    for (let sub of subs) {
      let st = type;
      if (type === 7) { // extension: the real subtable sits behind a 32-bit offset
        const e = new Reader(data, sub);
        e.u16();
        st = e.u16();
        sub += e.u32();
      }
      if (st !== 4) continue;
      const s = new Reader(data, sub);
      s.u16(); // format 1
      const cov = readCoverage(data, sub + s.u16());
      const setCount = s.u16();
      const sets = [];
      for (let k = 0; k < setCount; k++) sets.push(sub + s.u16());
      for (const [glyph, idx] of cov) {
        const setOff = sets[idx];
        const ls = new Reader(data, setOff);
        const lc = ls.u16();
        const list = ligs.get(glyph) ?? [];
        for (let k = 0; k < lc; k++) {
          const lg = new Reader(data, setOff + ls.u16());
          const out = lg.u16();
          const cc = lg.u16();
          const rest = [];
          for (let c = 1; c < cc; c++) rest.push(lg.u16());
          list.push({ rest, glyph: out });
        }
        ligs.set(glyph, list);
      }
    }
    if (ligs.size) lookups.push(ligs);
  }
  return lookups;
}

/** Applies the ligature lookups to a glyph run, like a shaper would (first match wins). */
function applyLigatures(lookups, run) {
  for (const ligs of lookups) {
    const out = [];
    for (let i = 0; i < run.length;) {
      const cands = ligs.get(run[i]);
      const hit = cands?.find((c) => c.rest.every((g, k) => run[i + 1 + k] === g));
      if (hit) { out.push(hit.glyph); i += 1 + hit.rest.length; }
      else out.push(run[i++]);
    }
    run = out;
  }
  return run;
}

// ---- variations ----------------------------------------------------------------------------------

function readFvar(data) {
  const r = new Reader(data);
  r.u32();
  const axesOff = r.u16();
  r.u16();
  const n = r.u16(), size = r.u16();
  const axes = [];
  for (let i = 0; i < n; i++) {
    const a = new Reader(data, axesOff + i * size);
    axes.push({ tag: a.tag(), min: a.fixed(), def: a.fixed(), max: a.fixed() });
  }
  return axes;
}

function readAvar(data) {
  if (!data) return null;
  const r = new Reader(data);
  r.u32(); r.u16();
  const n = r.u16();
  const maps = [];
  for (let i = 0; i < n; i++) {
    const c = r.u16();
    const m = [];
    for (let k = 0; k < c; k++) m.push([r.f2dot14(), r.f2dot14()]);
    maps.push(m);
  }
  return maps;
}

const toF2Dot14 = (v) => Math.round(v * 16384) / 16384;

function normalize(axes, avar, user) {
  return axes.map((a, i) => {
    let v = Math.min(a.max, Math.max(a.min, user[a.tag] ?? a.def));
    v = v < a.def ? (v - a.def) / (a.def - a.min) : v > a.def ? (v - a.def) / (a.max - a.def) : 0;
    v = toF2Dot14(v);
    const m = avar?.[i];
    if (m && m.length) {
      for (let k = 1; k < m.length; k++) {
        if (v <= m[k][0]) {
          const [x0, y0] = m[k - 1], [x1, y1] = m[k];
          v = x1 === x0 ? y0 : y0 + ((v - x0) * (y1 - y0)) / (x1 - x0);
          break;
        }
      }
      v = toF2Dot14(v);
    }
    return v;
  });
}

function readGvar(data) {
  const r = new Reader(data);
  r.u32();
  const axisCount = r.u16();
  const sharedCount = r.u16();
  const sharedOff = r.u32();
  const glyphCount = r.u16();
  const flags = r.u16();
  const arrayOff = r.u32();
  const offsets = [];
  for (let i = 0; i <= glyphCount; i++) offsets.push(flags & 1 ? r.u32() : r.u16() * 2);
  const shared = [];
  const s = new Reader(data, sharedOff);
  for (let i = 0; i < sharedCount; i++) {
    const t = [];
    for (let k = 0; k < axisCount; k++) t.push(s.f2dot14());
    shared.push(t);
  }
  return { data, axisCount, shared, offsets, arrayOff };
}

function readPackedPoints(r) {
  let count = r.u8();
  if (count & 0x80) count = ((count & 0x7f) << 8) | r.u8();
  if (count === 0) return null; // all points
  const pts = [];
  let p = 0;
  while (pts.length < count) {
    const c = r.u8();
    const words = c & 0x80;
    for (let k = (c & 0x7f) + 1; k > 0; k--) { p += words ? r.u16() : r.u8(); pts.push(p); }
  }
  return pts;
}

function readPackedDeltas(r, count) {
  const out = [];
  while (out.length < count) {
    const c = r.u8();
    const n = (c & 0x3f) + 1;
    const kind = c & 0xc0;
    for (let k = 0; k < n; k++) {
      out.push(kind === 0x80 ? 0 : kind === 0x40 ? r.i16() : kind === 0xc0 ? r.i32() : r.i8());
    }
  }
  return out;
}

function tupleScalar(coords, peak, start, end) {
  let s = 1;
  for (let i = 0; i < coords.length; i++) {
    const p = peak[i], c = coords[i];
    if (p === 0) continue;
    if (c === p) continue;
    if (c === 0) return 0;
    const lo = start ? start[i] : Math.min(0, p), hi = end ? end[i] : Math.max(0, p);
    if (start && (lo > p || p > hi || (lo < 0 && hi > 0))) continue; // invalid region: ignore axis
    if (c < lo || c > hi) return 0;
    s *= c < p ? (c - lo) / (p - lo) : (hi - c) / (hi - p);
  }
  return s;
}

/** Infers deltas for untouched points from their touched neighbours (gvar IUP), one coordinate. */
function iupContour(orig, delta, touched, axis) {
  const n = orig.length;
  const idx = [];
  for (let i = 0; i < n; i++) if (touched[i]) idx.push(i);
  if (idx.length === 0 || idx.length === n) return;
  for (let t = 0; t < idx.length; t++) {
    const a = idx[t], b = idx[(t + 1) % idx.length];
    const x1 = orig[a][axis], x2 = orig[b][axis], d1 = delta[a][axis], d2 = delta[b][axis];
    for (let i = (a + 1) % n; i !== b; i = (i + 1) % n) {
      const x = orig[i][axis];
      let d;
      if (x1 === x2) d = d1 === d2 ? d1 : 0;
      else {
        const [lx, ld, hx, hd] = x1 < x2 ? [x1, d1, x2, d2] : [x2, d2, x1, d1];
        d = x <= lx ? ld : x >= hx ? hd : ld + ((x - lx) * (hd - ld)) / (hx - lx);
      }
      delta[i][axis] = d;
    }
  }
}

/**
 * Deltas for one glyph at normalized coords. `orig` is its point list (outline points, or one
 * point per component offset), `ends` its contour ends (null for composites: no inference).
 * Returns [[dx, dy]] for orig.length points (+4 phantom points, dropped).
 */
function glyphDeltas(gvar, gid, coords, orig, ends) {
  const total = orig.length + 4;
  const sum = orig.map(() => [0, 0]);
  const start = gvar.offsets[gid], end = gvar.offsets[gid + 1];
  if (start === end) return sum;
  const base = gvar.arrayOff + start;
  const h = new Reader(gvar.data, base);
  const countFlags = h.u16();
  const dataOff = h.u16();
  const ser = new Reader(gvar.data, base + dataOff);
  const sharedPts = countFlags & 0x8000 ? readPackedPoints(ser) : undefined;
  for (let t = 0; t < (countFlags & 0x0fff); t++) {
    const size = h.u16();
    const index = h.u16();
    const readTuple = () => Array.from({ length: gvar.axisCount }, () => h.f2dot14());
    const peak = index & 0x8000 ? readTuple() : gvar.shared[index & 0x0fff];
    let lo = null, hi = null;
    if (index & 0x4000) { lo = readTuple(); hi = readTuple(); }
    const next = ser.pos + size;
    const scalar = tupleScalar(coords, peak, lo, hi);
    if (scalar !== 0) {
      const pts = index & 0x2000 ? readPackedPoints(ser) : sharedPts;
      const n = pts ? pts.length : total;
      const dx = readPackedDeltas(ser, n), dy = readPackedDeltas(ser, n);
      const d = orig.map(() => [0, 0]);
      const touched = new Array(orig.length).fill(false);
      for (let k = 0; k < n; k++) {
        const p = pts ? pts[k] : k;
        if (p >= orig.length) continue; // phantom points
        d[p] = [dx[k], dy[k]];
        touched[p] = true;
      }
      if (ends && pts) {
        let s = 0;
        for (const e of ends) {
          const sl = (a) => a.slice(s, e + 1);
          const od = sl(d);
          iupContour(sl(orig).map((p) => [p.x, p.y]), od, sl(touched), 0);
          iupContour(sl(orig).map((p) => [p.x, p.y]), od, sl(touched), 1);
          for (let i = s; i <= e; i++) d[i] = od[i - s];
          s = e + 1;
        }
      }
      for (let i = 0; i < orig.length; i++) { sum[i][0] += d[i][0] * scalar; sum[i][1] += d[i][1] * scalar; }
    }
    ser.pos = next;
  }
  return sum;
}

/** The glyph's contours at the given variation, components resolved, as [[{x, y, on}]]. */
function outline(font, gid, coords, depth = 0) {
  const g = font.glyphs[gid];
  if (!g || depth > 8) return [];
  if (g.contours) {
    const flat = g.contours.flat();
    const ends = [];
    let n = 0;
    for (const c of g.contours) { n += c.length; ends.push(n - 1); }
    const d = font.gvar ? glyphDeltas(font.gvar, gid, coords, flat, ends) : flat.map(() => [0, 0]);
    let i = 0;
    return g.contours.map((c) => c.map((p) => { const q = { x: p.x + d[i][0], y: p.y + d[i][1], on: p.on }; i++; return q; }));
  }
  const offs = g.components.map((c) => ({ x: c.dx, y: c.dy }));
  const d = font.gvar ? glyphDeltas(font.gvar, gid, coords, offs, null) : offs.map(() => [0, 0]);
  const out = [];
  g.components.forEach((c, i) => {
    const [a, b, cc, dd] = c.m;
    const ox = c.dx + d[i][0], oy = c.dy + d[i][1];
    for (const contour of outline(font, c.glyph, coords, depth + 1)) {
      out.push(contour.map((p) => ({ x: a * p.x + cc * p.y + ox, y: b * p.x + dd * p.y + oy, on: p.on })));
    }
  });
  return out;
}

// ---- SVG path data ---------------------------------------------------------------------------------

const num = (v) => {
  const s = (Math.round(v * 10) / 10).toFixed(1).replace(/\.0$/, '');
  return s === '-0' ? '0' : s;
};

/** TrueType quadratic contours to SVG path data, y flipped (font y-up to SVG y-down). */
function toPath(contours) {
  const pt = (p) => `${num(p.x)} ${num(-p.y)}`;
  const mid = (a, b) => ({ x: (a.x + b.x) / 2, y: (a.y + b.y) / 2, on: true });
  let d = '';
  for (const c of contours) {
    if (c.length < 2) continue;
    // Start on an on-curve point; with none, at the midpoint of the last and first.
    let s = c.findIndex((p) => p.on);
    let pts, first;
    if (s < 0) { first = mid(c[c.length - 1], c[0]); pts = c; }
    else { first = c[s]; pts = [...c.slice(s + 1), ...c.slice(0, s)]; }
    d += `M${pt(first)}`;
    let ctrl = null;
    for (const p of [...pts, first]) {
      if (p.on) {
        d += ctrl ? `Q${pt(ctrl)} ${pt(p)}` : `L${pt(p)}`;
        ctrl = null;
      } else {
        if (ctrl) d += `Q${pt(ctrl)} ${pt(mid(ctrl, p))}`;
        ctrl = p;
      }
    }
    d += 'Z';
  }
  return d;
}

/** Signed area of a contour polygon (on and off points), positive when counter-clockwise in y-up. */
function area(c) {
  let a = 0;
  for (let i = 0; i < c.length; i++) {
    const p = c[i], q = c[(i + 1) % c.length];
    a += p.x * q.y - q.x * p.y;
  }
  return a / 2;
}

// ---- main ----------------------------------------------------------------------------------------------

const { tables, transformed } = readWoff2(new Uint8Array(readFileSync(fontPath)));
const head = new Reader(tables.head);
head.pos = 18;
const upem = head.u16();
head.pos = 50;
const longLoca = head.i16() === 1;
const numGlyphs = new Reader(tables.maxp, 4).u16();
const glyphs = transformed.glyf !== undefined
  ? readTransformedGlyf(tables.glyf)
  : readGlyf(tables.glyf, tables.loca, numGlyphs, longLoca);
const axes = tables.fvar ? readFvar(tables.fvar) : [];
const avar = readAvar(tables.avar);
const font = { glyphs, gvar: tables.gvar ? readGvar(tables.gvar) : null };
const cmap = readCmap(tables.cmap);
const ligatures = readLigatureLookups(tables.GSUB);
const hhea = new Reader(tables.hhea, 4);
const ascender = hhea.i16(), descender = hhea.i16();

const names = JSON.parse(readFileSync(namesPath, 'utf8')).names;
const icons = [], missing = [];
let cw = 0, ccw = 0;
let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
for (const name of names) {
  const run = applyLigatures(ligatures, [...name].map((ch) => cmap.get(ch.codePointAt(0)) ?? 0));
  if (run.length !== 1) { missing.push(name); continue; }
  const variants = [0, 1].map((fill) => {
    const coords = normalize(axes, avar, { ...AXES, FILL: fill });
    const contours = outline(font, run[0], coords);
    for (const c of contours) {
      // Outer contours dominate the area; counting by sign shows the winding convention.
      if (area(c) < 0) cw++; else ccw++;
      for (const p of c) {
        minX = Math.min(minX, p.x); maxX = Math.max(maxX, p.x);
        minY = Math.min(minY, p.y); maxY = Math.max(maxY, p.y);
      }
    }
    return toPath(contours);
  });
  icons.push({ name, glyph: run[0], paths: variants });
}

// Material Symbols draw in a upem square sitting on the baseline: x 0..upem, y 0..upem up,
// so with y flipped the box is "0 -upem upem upem", the same viewBox Google's SVG downloads use.
const origin = [0, -upem];

const ZIG_KEYWORDS = new Set('addrspace align allowzero and anyframe anytype asm async await break callconv catch comptime const continue defer else enum errdefer error export extern fn for if inline linksection noalias noinline nosuspend opaque or orelse packed pub resume return struct suspend switch test threadlocal try union unreachable usingnamespace var volatile while'.split(' '));
const ident = (n) => (/^[A-Za-z_][A-Za-z0-9_]*$/.test(n) && !ZIG_KEYWORDS.has(n) ? n : `@"${n}"`);
const iconLit = (d) => `.{ .paths = &.{"${d}"}, .fill = true, .box = ${upem}, .origin = .{ ${origin[0]}, ${origin[1]} } }`;

let zig = `//! Material Symbols Rounded icons (wght 500, GRAD 0, opsz 24) as zui.Icon outlines.
//! GENERATED by tools/make-icons.mjs from the Material Symbols subset font; do not edit by hand.
//! Each icon has an outlined form (\`name\`) and a filled one (\`name_fill\`, FILL 1).

const std = @import("std");
const zui = @import("zui");

`;
for (const ic of icons) {
  zig += `pub const ${ident(ic.name)}: zui.Icon = ${iconLit(ic.paths[0])};\n`;
  zig += `pub const ${ident(ic.name + '_fill')}: zui.Icon = ${iconLit(ic.paths[1])};\n`;
}
const map = (suffix) => icons.map((ic) => `    .{ "${ic.name}", ${ident(ic.name + suffix)} },\n`).join('');
zig += `
const outlined = std.StaticStringMap(zui.Icon).initComptime(.{
${map('')}});

const filled = std.StaticStringMap(zui.Icon).initComptime(.{
${map('_fill')}});

/// The outlined icon with this Material Symbols name ("local_shipping"), if it was extracted.
pub fn byName(name: []const u8) ?zui.Icon {
    return outlined.get(name);
}

/// The filled icon with this Material Symbols name, if it was extracted.
pub fn byNameFill(name: []const u8) ?zui.Icon {
    return filled.get(name);
}
`;
writeFileSync(outPath, zig);

// Also a JSON dump for checking the paths against the font in a browser.
if (process.env.ICONS_JSON) {
  writeFileSync(process.env.ICONS_JSON, JSON.stringify({ upem, origin, icons }, null, 1));
}

const fmt = (v) => Math.round(v * 10) / 10;
console.log(`tables: ${Object.keys(tables).join(' ')}${transformed.glyf !== undefined ? ' (glyf/loca transformed)' : ''}`);
console.log(`axes: ${axes.map((a) => `${a.tag} ${a.min}..${a.def}..${a.max}`).join(', ')}${avar ? ' (avar)' : ''}`);
console.log(`unitsPerEm ${upem}, hhea ascender ${ascender} descender ${descender}, glyphs ${numGlyphs}`);
console.log(`outline extent: x ${fmt(minX)}..${fmt(maxX)}, y ${fmt(minY)}..${fmt(maxY)}`);
console.log(`contours: ${cw} clockwise, ${ccw} counter-clockwise (y up)`);
console.log(`wrote ${icons.length} icons (+ filled) to ${outPath}`);
if (missing.length) console.log(`missing (no ligature): ${missing.join(', ')}`);
