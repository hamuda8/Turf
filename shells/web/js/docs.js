// Fills the docs with live reference data and this server's real address.

import { h } from './core/dom.js';

const base = `${location.origin}/api/v1`;
for (const el of document.querySelectorAll('pre code, code.base-url')) {
  el.textContent = el.textContent.replaceAll('https://YOUR-TURF-HOST', location.origin);
}
document.querySelector('code.base-url').textContent = base;

const [statuses, governorates] = await Promise.all([
  fetch(`${base}/statuses`).then(r => r.json()),
  fetch(`${base}/governorates`).then(r => r.json()),
]);

document.getElementById('status-table').append(...statuses.statuses.map(s =>
  h('tr', null, h('td', null, h('code', null, s.code)), h('td', null, s.en), h('td', { dir: 'rtl' }, s.ar))));
const reasons = document.getElementById('reasons');
statuses.failureReasons.forEach((r, i) => reasons.append(i ? ', ' : '', h('code', { title: r.en }, r.code)));
document.getElementById('gov-table').append(...governorates.map(g =>
  h('tr', null, h('td', null, h('code', null, g.code)), h('td', null, g.en), h('td', { dir: 'rtl' }, g.ar))));
