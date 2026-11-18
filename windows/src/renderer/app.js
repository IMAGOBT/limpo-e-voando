'use strict';
/* Casca do app: barra lateral, navegação, tema, eventos do processo principal e atalhos. */
(() => {
  const { SECTIONS: SECS, S: ST, VIEWS: V } = window.Sections;
  const main = document.getElementById('main');
  const side = document.getElementById('sidebar');
  const tip = h('div.tip');
  document.body.appendChild(tip);
  let theme = 'system';
  let perfTimer = null;

  window.addEventListener('error', (e) => console.error('erro:', e.message));
  window.addEventListener('unhandledrejection', (e) => console.error('promessa rejeitada:', e.reason && e.reason.message ? e.reason.message : e.reason));

  // ---------- Tema ----------
  const media = window.matchMedia('(prefers-color-scheme: dark)');
  function applyTheme() {
    const dark = theme === 'dark' || (theme === 'system' && media.matches);
    document.documentElement.dataset.theme = dark ? 'dark' : 'light';
    for (const b of side.querySelectorAll('.theme button')) b.classList.toggle('on', b.dataset.mode === theme);
  }
  media.addEventListener('change', applyTheme);
  async function setTheme(m) {
    theme = await window.lv.call('theme.set', m);
    applyTheme();
    // após trocar themeSource, o prefers-color-scheme muda; reaplica
    setTimeout(applyTheme, 50);
  }

  // ---------- Barra lateral ----------
  function navButton(s, i) {
    const b = h(`button.nav${ST.current === s.id ? '.on' : ''}`, { 'aria-label': s.title, 'data-nav': s.id, onclick: () => go(s.id) }, icon(s.icon));
    if (ST.busy.has(s.id)) b.appendChild(h('span.dot'));
    b.addEventListener('mouseenter', () => {
      const r = b.getBoundingClientRect();
      tip.replaceChildren(s.title, i < 9 ? h('small', `Ctrl+${i + 1}`) : null);
      tip.style.top = `${r.top + r.height / 2 - 14}px`;
      tip.classList.add('show');
    });
    b.addEventListener('mouseleave', () => tip.classList.remove('show'));
    return b;
  }
  function renderSidebar() {
    const idx = (s) => SECS.indexOf(s);
    const themeBtn = (mode, ic, label) => {
      const b = h(`button${theme === mode ? '.on' : ''}`, { 'data-mode': mode, 'aria-label': `Aparência: ${label}`, onclick: () => setTheme(mode) }, icon(ic));
      b.addEventListener('mouseenter', () => { const r = b.getBoundingClientRect(); tip.replaceChildren(`Aparência: ${label}`); tip.style.top = `${r.top + r.height / 2 - 14}px`; tip.classList.add('show'); });
      b.addEventListener('mouseleave', () => tip.classList.remove('show'));
      return b;
    };
    side.replaceChildren(
      ...SECS.filter((s) => s.group === 'main').map((s) => navButton(s, idx(s))),
      h('div.sep'),
      ...SECS.filter((s) => s.group === 'quick').map((s) => navButton(s, idx(s))),
      h('div.grow'),
      ...SECS.filter((s) => s.group === 'bottom').map((s) => navButton(s, idx(s))),
      h('div.theme', themeBtn('system', 'monitor', 'Sistema'), themeBtn('light', 'sun', 'Claro'), themeBtn('dark', 'moon', 'Escuro')));
  }

  const homeParts = {};

  // ---------- Navegação ----------
  let lastView = null;
  function render() {
    const id = ST.current;
    const keep = lastView === id ? main.scrollTop : 0;
    let el;
    try { el = V[id](window.Sections.SEC[id]); } catch (e) { console.error(`falha ao desenhar ${id}:`, e); el = h('section.view', { 'data-view': id }, h('div.empty', 'Algo deu errado nesta tela.')); }
    if (lastView === id) el.style.animation = 'none';
    main.replaceChildren(el);
    main.scrollTop = keep;
    lastView = id;
    if (!ST.busy.size) for (const k of Object.keys(homeParts)) delete homeParts[k];
    renderSidebar();
  }

  async function go(id) {
    if (!V[id]) return;
    ST.current = id;
    tip.classList.remove('show');
    render();
    clearInterval(perfTimer);
    if (id === 'perf') { await tickPerf(); perfTimer = setInterval(tickPerf, 1500); }
    if (id === 'organize' && ST.org.last == null) { ST.org.last = await window.lv.call('org.last').catch(() => null); if (ST.current === 'organize') render(); }
  }

  async function tickPerf() {
    try {
      ST.sample = await window.lv.call('perf.sample');
      const g = document.querySelector('[data-gauges]');
      if (g && ST.current === 'perf') g.replaceWith(window.Sections.gauges());
    } catch (e) { console.warn(e.message); }
  }

  // ---------- Eventos do processo principal ----------
  window.lv.on('progress', ({ task, value, phase }) => {
    const map = { large: 'clutter', dups: 'clutter' };
    UI.setProgress(task, value, phase);
    if (map[task]) { homeParts[`c:${task}`] = value; UI.setProgress('clutter', ((homeParts['c:large'] || 0) + (homeParts['c:dups'] || 0)) / 2, phase); }
    if (ST.busy.has('home') && ['cleanup', 'large', 'dups'].includes(task)) {
      homeParts[task] = value;
      UI.setProgress('home', ((homeParts.cleanup || 0) + (homeParts.large || 0) + (homeParts.dups || 0)) / 3, phase);
    }
  });
  window.lv.on('compress', (d) => {
    if (d.done) return;
    UI.setProgress('compress', (d.index + d.fraction) / d.total, d.phase + (d.total > 1 ? ` (${d.index + 1} de ${d.total})` : ''));
  });
  window.lv.on('tools', (d) => {
    UI.setProgress('compress', d.fraction, `Baixando ${d.label} (só na primeira vez)…`);
    const j = ST.dl.jobs.find((x) => x.status === 'baixando');
    if (j) { j.detail = `Baixando ${d.label} · ${Math.round(d.fraction * 100)}%`; window.Sections.refreshDl(); }
  });
  window.lv.on('dl', (job) => {
    const i = ST.dl.jobs.findIndex((x) => x.id === job.id);
    if (i >= 0) ST.dl.jobs[i] = job; else ST.dl.jobs.push(job);
    if (job.status === 'pronto') UI.toast(`Baixado: ${job.title}`);
    if (ST.current === 'download') window.Sections.refreshDl();
  });

  // ---------- Atalhos ----------
  document.addEventListener('keydown', (e) => {
    if (document.getElementById('modal').classList.contains('show')) return;
    if (e.ctrlKey && /^[1-9]$/.test(e.key)) { e.preventDefault(); go(SECS[Number(e.key) - 1].id); return; }
    const tag = (e.target.tagName || '').toLowerCase();
    if (e.key === 'Enter' && !['input', 'button', 'textarea', 'select'].includes(tag)) {
      const b = main.querySelector('[data-primary]');
      if (b && !b.disabled) { e.preventDefault(); b.click(); }
    }
  });

  // ---------- Início ----------
  window.App = { render, go };
  window.__lv = { go, theme: setTheme };
  (async () => {
    applyTheme();
    try {
      ST.info = await window.lv.call('info');
      theme = await window.lv.call('theme.get');
      const dl = await window.lv.call('dl.list');
      ST.dl.dir = dl.dir; ST.dl.jobs = dl.jobs;
    } catch (e) { console.error('falha ao iniciar:', e.message); }
    applyTheme();
    render();
  })();
})();
