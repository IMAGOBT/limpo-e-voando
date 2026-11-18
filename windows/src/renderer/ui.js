'use strict';
/* Peças de interface: DOM, ícones, formatos, gráficos, toast e confirmação. Sem estilos inline em HTML (CSP). */
(() => {

const ICONS = {
  sparkles: 'M12 3l1.8 4.7 4.7 1.8-4.7 1.8L12 16l-1.8-4.7-4.7-1.8 4.7-1.8z M19 15l.8 2.2 2.2.8-2.2.8L19 21l-.8-2.2-2.2-.8 2.2-.8z',
  broom: 'M20 3l-8 8 M9.5 9.5l5 5 M4 20c0-4 2-7 5.5-10.5l5 5C11 18 8 20 4 20z M7.5 20l1.5-3 M11 18.8l1-2.3',
  folder: 'M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z',
  'folder-open': 'M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z M3 11h18',
  bolt: 'M13 2L4 14h7l-1 8 9-12h-7z',
  lens: 'M10.5 3.5a7 7 0 1 1 0 14 7 7 0 0 1 0-14z M20.5 20.5l-5-5',
  grid: 'M4 4h6v6H4z M14 4h6v6h-6z M4 14h6v6H4z M14 14h6v6h-6z',
  tray: 'M3 13h5l1.5 2.5h5L16 13h5 M3 13l2.5-8h13l2.5 8v6H3z',
  compress: 'M4 14h6v6 M20 10h-6V4 M14 10l7-7 M3 21l7-7',
  download: 'M12 3v12 M7 10l5 5 5-5 M5 20h14',
  stack: 'M12 3l9 5-9 5-9-5z M3 12.5l9 5 9-5 M3 16.5l9 5 9-5',
  sun: 'M12 8a4 4 0 1 1 0 8 4 4 0 0 1 0-8z M12 2v2 M12 20v2 M4.9 4.9l1.4 1.4 M17.7 17.7l1.4 1.4 M2 12h2 M20 12h2 M4.9 19.1l1.4-1.4 M17.7 6.3l1.4-1.4',
  moon: 'M20 14.5A8 8 0 1 1 9.5 4a6.5 6.5 0 0 0 10.5 10.5z',
  monitor: 'M3 4h18v12H3z M8 20h8 M12 16v4',
  clock: 'M12 3a9 9 0 1 1 0 18 9 9 0 0 1 0-18z M12 7v5l3 2',
  globe: 'M12 3a9 9 0 1 1 0 18 9 9 0 0 1 0-18z M3 12h18 M12 3c3 3.5 3 14.5 0 18 M12 3c-3 3.5-3 14.5 0 18',
  image: 'M4 5h16v14H4z M4 16l5-5 4 4 2-2 5 5 M15.5 8.5h.01',
  alert: 'M12 3l10 18H2z M12 10v4 M12 17.5v.01',
  code: 'M8 7l-5 5 5 5 M16 7l5 5-5 5',
  package: 'M3 7.5l9-4.5 9 4.5v9l-9 4.5-9-4.5z M3 7.5l9 4.5 9-4.5 M12 12v9',
  trash: 'M4 7h16 M9 7V4h6v3 M6 7l1 13h10l1-13 M10 11v5 M14 11v5',
  chev: 'M9 6l6 6-6 6',
  back: 'M15 6l-6 6 6 6',
  check: 'M5 12l5 5 9-10',
  x: 'M6 6l12 12 M18 6L6 18',
  copy: 'M8 8h12v12H8z M4 16V4h12',
  hdd: 'M3 13l3-8h12l3 8v6H3z M3 13h18 M17 16h.01',
  power: 'M12 3v9 M6.3 6.3a8 8 0 1 0 11.4 0',
  cpu: 'M7 7h10v10H7z M10 3v4 M14 3v4 M10 17v4 M14 17v4 M3 10h4 M3 14h4 M17 10h4 M17 14h4',
  memory: 'M3 8h18v8H3z M7 8v8 M11 8v8 M15 8v8 M5 16v3 M19 16v3',
  film: 'M4 4h16v16H4z M8 4v16 M16 4v16 M4 8h4 M4 12h4 M4 16h4 M16 8h4 M16 12h4 M16 16h4',
  music: 'M9 18V5l11-2v13 M9 18a3 3 0 1 1-3-3 3 3 0 0 1 3 3z M20 16a3 3 0 1 1-3-3 3 3 0 0 1 3 3z',
  shield: 'M12 3l8 3v6c0 5-3.5 8-8 9-4.5-1-8-4-8-9V6z M9 12l2 2 4-4',
  undo: 'M9 14L4 9l5-5 M4 9h10a6 6 0 0 1 0 12h-3',
  link: 'M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1 M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1',
  refresh: 'M20 11a8 8 0 1 0-2.3 5.7 M20 4v7h-7',
  chart: 'M12 3a9 9 0 1 1-9 9 M12 3v9h9 M12 3a9 9 0 0 1 9 9',
  file: 'M6 3h8l4 4v14H6z M14 3v4h4',
  calendar: 'M4 6h16v14H4z M4 10h16 M8 3v5 M16 3v5',
  play: 'M7 4l13 8-13 8z',
};

function icon(name, cls = '') {
  const s = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  s.setAttribute('viewBox', '0 0 24 24');
  s.setAttribute('class', `i ${cls}`);
  s.setAttribute('aria-hidden', 'true');
  const p = document.createElementNS('http://www.w3.org/2000/svg', 'path');
  p.setAttribute('d', ICONS[name] || ICONS.file);
  s.appendChild(p);
  return s;
}

/** h('div.card.x', {onclick, style:{}, attrs}, ...filhos) */
function h(sel, props, ...kids) {
  const [tag, ...cls] = sel.split('.');
  const el = document.createElement(tag || 'div');
  if (cls.length) el.className = cls.join(' ');
  if (props && (typeof props !== 'object' || props instanceof Node || Array.isArray(props))) { kids.unshift(props); props = null; }
  for (const [k, v] of Object.entries(props || {})) {
    if (v == null || v === false) continue;
    if (k === 'style') Object.assign(el.style, v);
    else if (k.startsWith('on')) el.addEventListener(k.slice(2), v);
    else if (k === 'class') el.className += ` ${v}`;
    else if (k in el && k !== 'list') el[k] = v;
    else el.setAttribute(k, v === true ? '' : v);
  }
  append(el, kids);
  return el;
}
function append(el, kids) {
  for (const k of kids.flat(Infinity)) {
    if (k == null || k === false) continue;
    el.appendChild(k instanceof Node ? k : document.createTextNode(String(k)));
  }
  return el;
}

const nf1 = new Intl.NumberFormat('pt-BR', { maximumFractionDigits: 1 });
const nf0 = new Intl.NumberFormat('pt-BR');
function fmtBytes(n) {
  n = Number(n) || 0;
  if (n < 1000) return `${n} B`;
  const u = ['KB', 'MB', 'GB', 'TB'];
  let v = n / 1000, i = 0;
  while (v >= 1000 && i < u.length - 1) { v /= 1000; i++; }
  return `${nf1.format(v)} ${u[i]}`;
}
const fmtNum = (n) => nf0.format(n || 0);
const fmtDate = (ms) => (ms ? new Date(ms).toLocaleDateString('pt-BR', { day: '2-digit', month: 'short', year: 'numeric' }) : '');
const plural = (n, one, many) => `${fmtNum(n)} ${n === 1 ? one : many}`;
const PALETTE = ['--c1', '--c2', '--c3', '--c4', '--c5', '--c6', '--c7', '--c8'];
const color = (i) => `var(${PALETTE[i % PALETTE.length]})`;

/** Rosca colorida. segs: [{value, color}] */
function donut(segs, size = 200, top = '', bottom = '', stroke = 22) {
  const NS = 'http://www.w3.org/2000/svg';
  const svg = document.createElementNS(NS, 'svg');
  svg.setAttribute('width', size); svg.setAttribute('height', size); svg.setAttribute('viewBox', `0 0 ${size} ${size}`);
  const r = (size - stroke) / 2, c = 2 * Math.PI * r, cx = size / 2;
  const mk = (stroke2, col, dash, off) => {
    const e = document.createElementNS(NS, 'circle');
    e.setAttribute('cx', cx); e.setAttribute('cy', cx); e.setAttribute('r', r); e.setAttribute('fill', 'none');
    e.setAttribute('stroke-width', stroke2); e.style.stroke = col;
    if (dash) { e.setAttribute('stroke-dasharray', dash); e.setAttribute('stroke-dashoffset', off); }
    e.setAttribute('transform', `rotate(-90 ${cx} ${cx})`);
    return e;
  };
  svg.appendChild(mk(stroke, 'var(--line)'));
  const total = segs.reduce((s, x) => s + Math.max(0, x.value), 0);
  let acc = 0;
  const gap = segs.filter((s) => s.value > 0).length > 1 ? 2 : 0;
  if (total > 0) for (const s of segs) {
    if (s.value <= 0) continue;
    const len = (s.value / total) * c * (s.fraction != null ? s.fraction : 1);
    if (len - gap > 0.5) svg.appendChild(mk(stroke, s.color, `${len - gap} ${c - len + gap}`, -acc));
    acc += len;
  }
  return h('div.donut', svg, h('div.c', h('b', top), h('span', bottom)));
}

/** Medidor circular (0–1). */
function ring(value, tint, size = 96) {
  const v = Math.max(0, Math.min(1, value || 0));
  return donut([{ value: Math.max(v, 0.0001), color: tint }, { value: Math.max(0, 1 - v), color: 'transparent' }], size, `${Math.round(v * 100)}%`, '', 9);
}

function progressBar(task) {
  return h('div.progress', { 'data-progress': task }, h('div.row', h('span.ph', 'Preparando…'), h('b.pct', '0%')), h('div.track', h('i')));
}
function setProgress(task, value, phase) {
  for (const el of document.querySelectorAll(`[data-progress="${task}"]`)) {
    const v = Math.max(0, Math.min(1, value || 0));
    el.querySelector('.pct').textContent = `${Math.round(v * 100)}%`;
    el.querySelector('i').style.width = `${v * 100}%`;
    if (phase) el.querySelector('.ph').textContent = phase;
  }
}

let toastTimer = null;
function toast(msg, tone = 'green') {
  const t = document.getElementById('toast');
  t.replaceChildren(h('div.box', { class: tone }, icon(tone === 'red' ? 'alert' : tone === 'orange' ? 'alert' : 'check'), h('span', msg)));
  t.classList.add('show');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => t.classList.remove('show'), 6500);
}

function confirmBox({ title, text, ok = 'Continuar', danger = false, step = '' }) {
  return new Promise((resolve) => {
    const m = document.getElementById('modal');
    const close = (v) => { m.classList.remove('show'); m.replaceChildren(); document.removeEventListener('keydown', key); resolve(v); };
    const key = (e) => { if (e.key === 'Escape') close(false); };
    const okBtn = h(`button.btn.${danger ? 'danger.fill' : 'primary'}`, { onclick: () => close(true) }, ok);
    m.replaceChildren(h('div.dialog', { role: 'dialog', 'aria-modal': 'true' },
      step ? h('div.step', step) : null, h('h2', title), h('p', text),
      h('div.btns', h('button.btn', { onclick: () => close(false) }, 'Cancelar'), okBtn)));
    m.classList.add('show');
    document.addEventListener('keydown', key);
    okBtn.focus();
  });
}

/** Confirmação dupla para exclusões em massa. */
async function confirmTwice(first, second) {
  if (!(await confirmBox({ ...first, step: 'Passo 1 de 2' }))) return false;
  return confirmBox({ title: 'Tem certeza?', ok: first.ok, danger: true, step: 'Passo 2 de 2 · última confirmação', ...second });
}

window.UI = { h, append, icon, fmtBytes, fmtNum, fmtDate, plural, color, donut, ring, progressBar, setProgress, toast, confirmBox, confirmTwice };
})();
