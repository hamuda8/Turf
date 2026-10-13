// Tiny DOM builder. Strings always become text nodes, so user data can never
// inject HTML. Example: h('button', { class: 'btn', onclick: save }, 'Save')

export function h(tag, props, ...children) {
  const el = document.createElement(tag);
  if (props) {
    for (const [key, value] of Object.entries(props)) {
      if (value === undefined || value === null || value === false) continue;
      if (key === 'class') el.className = Array.isArray(value) ? value.filter(Boolean).join(' ') : value;
      else if (key === 'style' && typeof value === 'object') Object.assign(el.style, value);
      else if (key === 'dataset') Object.assign(el.dataset, value);
      else if (key.startsWith('on') && typeof value === 'function') el.addEventListener(key.slice(2), value);
      else if (key === 'value' && 'value' in el) el.value = value;
      else if (key === 'checked' || key === 'selected' || key === 'disabled' || key === 'hidden' || key === 'required') el[key] = Boolean(value);
      else if (key === 'ref' && typeof value === 'function') value(el);
      else el.setAttribute(key, value === true ? '' : value);
    }
  }
  append(el, children);
  return el;
}

export function append(el, children) {
  for (const child of children.flat(Infinity)) {
    if (child === null || child === undefined || child === false || child === true) continue;
    el.append(child instanceof Node ? child : document.createTextNode(String(child)));
  }
  return el;
}

export function clear(el) {
  while (el.firstChild) el.firstChild.remove();
  return el;
}

export function replace(el, ...children) {
  clear(el);
  return append(el, children);
}

export const $ = (selector, root = document) => root.querySelector(selector);
export const $$ = (selector, root = document) => [...root.querySelectorAll(selector)];

/** Collect a form's named fields into an object. Dotted names build nested objects. */
export function formValues(form) {
  const out = {};
  for (const el of form.elements) {
    if (!el.name || el.disabled) continue;
    let value;
    if (el.type === 'checkbox') value = el.checked;
    else if (el.type === 'number' || el.dataset.number !== undefined) {
      // Number fields (see ui.js numberInput): send a number, or the raw text so the
      // server can say exactly what's wrong with it.
      const raw = el.value.trim();
      value = raw === '' ? undefined : (Number.isFinite(Number(raw)) ? Number(raw) : raw);
    }
    else if (el.type === 'radio') { if (!el.checked) continue; value = el.value; }
    else value = el.value.trim() === '' ? undefined : el.value.trim();
    const path = el.name.split('.');
    let target = out;
    for (const part of path.slice(0, -1)) target = target[part] ??= {};
    target[path[path.length - 1]] = value;
  }
  return out;
}
