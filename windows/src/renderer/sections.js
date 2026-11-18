'use strict';
/* As 10 seções. Cada uma é uma função que devolve o elemento da tela a partir do estado S. */
const { h, icon, fmtBytes, fmtNum, fmtDate, plural, color, donut, ring, progressBar, toast, confirmBox, confirmTwice } = UI;
const call = (name, ...a) => window.lv.call(name, ...a);

const SECTIONS = [
  { id: 'home', title: 'Cuidado inteligente', icon: 'sparkles', group: 'main', pitch: 'Uma passada rápida para cuidar do essencial do seu PC.',
    features: [['Análise de limpeza', 'broom'], ['Acúmulos e duplicados', 'folder'], ['Itens de inicialização', 'power']] },
  { id: 'cleanup', title: 'Limpeza', icon: 'broom', group: 'main', round: true, pitch: 'Tire do caminho o que só ocupa espaço e recupere gigas.',
    features: [['Temporários do Windows', 'clock'], ['Cache dos navegadores', 'globe'], ['Miniaturas e relatórios de falhas', 'image'], ['Caches de desenvolvimento', 'code']] },
  { id: 'clutter', title: 'Acúmulos', icon: 'folder', group: 'main', pitch: 'Encontre arquivos pesados e cópias esquecidas.',
    features: [['Arquivos grandes (mais de 200 MB)', 'hdd'], ['Duplicados idênticos (SHA-256)', 'copy'], ['Nada vem marcado: você escolhe', 'shield']] },
  { id: 'perf', title: 'Desempenho', icon: 'bolt', group: 'main', pitch: 'Deixe o PC leve: veja quem pesa e o que abre junto com o Windows.',
    features: [['CPU e memória ao vivo', 'cpu'], ['Processos pesados', 'bolt'], ['Itens de inicialização reversíveis', 'power']] },
  { id: 'lens', title: 'Lupa de espaço', icon: 'lens', group: 'main', round: true, pitch: 'Veja o que ocupa mais espaço e decida o que fica.',
    features: [['Mapa visual do armazenamento', 'chart'], ['Navegação por pastas', 'folder'], ['Mostrar no Explorer', 'folder-open']] },
  { id: 'apps', title: 'Aplicativos', icon: 'grid', group: 'main', pitch: 'Veja tudo que está instalado e remova o que você não usa.',
    features: [['Tamanho de cada app', 'hdd'], ['Desinstalador oficial de cada app', 'trash']] },
  { id: 'organize', title: 'Organizar', icon: 'tray', group: 'main', pitch: 'Cada arquivo no seu lugar, por tipo ou por data.' },
  { id: 'compress', title: 'Compressor', icon: 'compress', group: 'quick', pitch: 'Deixe vídeos e áudios mais leves sem perder qualidade visível.' },
  { id: 'download', title: 'Baixar vídeo', icon: 'download', group: 'quick', pitch: 'Cole o link e baixe o vídeo na maior qualidade, até 4K.' },
  { id: 'tools', title: 'Ferramentas', icon: 'stack', group: 'bottom', pitch: 'Todas as ferramentas do Limpo e Voando num só lugar.' },
];
SECTIONS.forEach((s, i) => { s.num = String(i + 1).padStart(2, '0'); });
const SEC = Object.fromEntries(SECTIONS.map((s) => [s.id, s]));

const S = {
  info: { isWindows: false, folders: [] }, current: 'home', busy: new Set(),
  home: null, cleanup: null, cleanupSel: new Set(), cleanupOpen: new Set(), recycle: null,
  large: null, dups: null, largeSel: new Set(), dupSel: new Set(), clutterTab: 'large',
  procs: null, startup: null, sample: null, lens: null,
  apps: null, appsQuery: '', org: { dir: null, mode: 'type', preview: null, last: null },
  comp: { files: [], codec: 'hevc', trash: false, results: null }, dl: { jobs: [], dir: '' },
};

// ---------- Peças comuns ----------

const rerender = () => window.App.render();
const eyebrow = (sec) => h('div.eyebrow', h('span.n', sec.num), h('span.bar'), h('span', sec.title));
const view = (id, ...kids) => h('section.view', { 'data-view': id }, ...kids);
const head = (sec, ...actions) => h('div.head', h('div', eyebrow(sec), h('h1.small', sec.title)), h('div.actions', ...actions));
const btn = (label, onclick, kind = '', ic = null, extra = {}) => h(`button.btn${kind ? `.${kind}` : ''}`, { onclick, ...extra }, ic ? icon(ic) : null, label);
const iconBtn = (ic, title, onclick, kind = 'ghost') => h(`button.btn.icon.${kind}`, { title, 'aria-label': title, onclick }, icon(ic));
const winOnly = () => (S.info.isWindows ? null : h('div.note.orange', icon('alert'), h('span', 'Você está fora do Windows: esta parte só encontra itens no Windows. A interface continua funcionando para conferência.')));
const showInExplorer = (p) => call('shell.show', p).catch((e) => toast(e.message, 'red'));
const freedMsg = (r, extra = '') => `Liberado de verdade: ${fmtBytes(r.real)}${extra}`;

async function run(task, fn) {
  if (S.busy.has(task)) return;
  S.busy.add(task); rerender();
  try { await fn(); } catch (e) { toast(e.message || String(e), 'red'); }
  finally { S.busy.delete(task); rerender(); }
}

function goArea(task, label, onGo, enabled = true) {
  const busy = S.busy.has(task);
  return h('div.go', busy ? progressBar(task) : null,
    h('button.round', { disabled: busy || !enabled, onclick: onGo, 'data-primary': '1' }, busy ? '…' : label),
    h('div.hint', busy ? 'Analisando…' : 'ou aperte Enter'));
}

function intro(sec, task, onGo, label = 'Analisar') {
  return view(sec.id,
    h('div.intro',
      h(`div.hero${sec.round ? '.round' : ''}`, icon(sec.icon)),
      h('div', eyebrow(sec), h('h1', sec.title), h('p.pitch', sec.pitch),
        sec.features ? h('ul.features', sec.features.map(([t, ic]) => h('li', h('div.tile', icon(ic)), t))) : null)),
    goArea(task, label, onGo));
}

function legend(items) {
  return h('div.legend', items.map((it) => h('div', h('span.dotc', { style: { background: it.color } }), h('span.grow', it.label), h('span.num.muted', fmtBytes(it.value)))));
}

// ---------- 01 Cuidado inteligente ----------

async function smartScan() {
  await run('home', async () => {
    const [c, l, d, st, rb, disk] = await Promise.all([
      call('cleanup.scan'), call('clutter.large'), call('clutter.dups', { minSize: 5e6, seconds: 150 }),
      call('startup.list'), call('recycle.info').catch(() => null), call('disk.free')]);
    setCleanup(c); S.large = l; S.dups = d; S.largeSel.clear(); S.dupSel.clear(); S.startup = st; S.recycle = rb;
    S.home = { disk, at: Date.now() };
  });
}

function homeView(sec) {
  if (!S.home) return intro(sec, 'home', smartScan);
  const recommended = (S.cleanup || []).filter((c) => c.pre && c.size > 0);
  const junk = recommended.reduce((s, c) => s + c.size, 0);
  const largeSize = (S.large || []).reduce((s, f) => s + f.size, 0);
  const wasted = (S.dups || []).reduce((s, g) => s + g.wasted, 0);
  const enabled = (S.startup || []).filter((x) => x.enabled).length;
  const { free, total } = S.home.disk;
  const card = (title, ic, big, tone, text, ...foot) => h('div.card', h('h3', icon(ic), title), h(`div.big.${tone}`, big), h('p', text), h('div.foot', ...foot));
  return view('home',
    head(sec, btn('Analisar de novo', smartScan, '', 'refresh', { disabled: S.busy.has('home') })),
    S.busy.has('home') ? h('div.go', progressBar('home')) : null,
    winOnly(),
    h('div.split',
      h('div.card', h('h3', icon('hdd'), 'Disco'),
        h('div', { style: { display: 'grid', placeItems: 'center', marginTop: '14px' } },
          donut([{ value: total - free, color: 'var(--c1)' }, { value: free, color: 'var(--c6)' }], 190, fmtBytes(free), 'livres')),
        legend([{ label: 'Em uso', value: total - free, color: 'var(--c1)' }, { label: 'Livre', value: free, color: 'var(--c6)' }])),
      h('div.grid',
        card('Limpeza', 'broom', fmtBytes(junk), junk ? 'pos' : '', `${plural(recommended.length, 'categoria segura', 'categorias seguras')} para limpar`,
          btn('Limpar o recomendado', () => cleanSelected(recommended.map((c) => c.id)), 'primary', null, { disabled: !junk }), btn('Ver', () => App.go('cleanup'), 'ghost')),
        card('Arquivos grandes', 'hdd', fmtBytes(largeSize), largeSize ? 'warn' : '', `${plural((S.large || []).length, 'arquivo', 'arquivos')} com mais de 200 MB`,
          btn('Revisar', () => { S.clutterTab = 'large'; App.go('clutter'); }, 'ghost')),
        card('Duplicados', 'copy', fmtBytes(wasted), wasted ? 'warn' : '', `${plural((S.dups || []).length, 'grupo', 'grupos')} de cópias idênticas`,
          btn('Revisar', () => { S.clutterTab = 'dups'; App.go('clutter'); }, 'ghost')),
        card('Inicialização', 'power', fmtNum(enabled), enabled > 8 ? 'warn' : '', 'itens abrem junto com o Windows', btn('Ajustar', () => App.go('perf'), 'ghost')),
        S.recycle && S.recycle.supported ? card('Lixeira', 'trash', fmtBytes(S.recycle.size), '', plural(S.recycle.count, 'item na Lixeira', 'itens na Lixeira'),
          btn('Esvaziar Lixeira', emptyRecycle, 'danger', null, { disabled: !S.recycle.count })) : null)));
}

// ---------- 02 Limpeza ----------

function setCleanup(c) {
  S.cleanup = c;
  S.cleanupSel = new Set(c.filter((x) => x.pre && x.size > 0).map((x) => x.id));
}
const scanCleanup = () => run('cleanup', async () => {
  const [c, rb] = await Promise.all([call('cleanup.scan'), call('recycle.info').catch(() => null)]);
  setCleanup(c); S.recycle = rb;
});

async function cleanSelected(ids) {
  const cats = (S.cleanup || []).filter((c) => ids.includes(c.id) && c.size > 0);
  if (!cats.length) return;
  const size = cats.reduce((s, c) => s + c.size, 0), count = cats.reduce((s, c) => s + c.count, 0);
  const trash = cats.some((c) => c.mode === 'trash');
  const ok = await confirmTwice(
    { title: `Limpar ${fmtBytes(size)}?`, ok: 'Limpar',
      text: `${cats.map((c) => `• ${c.title}`).join('\n')}\n\nTemporários e caches são apagados direto (os apps recriam).${trash ? ' Instaladores vão para a Lixeira.' : ''} Arquivos em uso são pulados.` },
    { text: `${plural(count, 'arquivo', 'arquivos')} serão removidos. Essa ação não tem como desfazer para caches e temporários.` });
  if (!ok) return;
  let res = null;
  await run('cleanup', async () => { res = await call('cleanup.clean', cats.map((c) => c.id)); });
  if (!res) return;
  toast(freedMsg(res, ` · ${plural(res.removed, 'arquivo removido', 'arquivos removidos')}${res.skipped ? ` · ${fmtNum(res.skipped)} em uso foram pulados` : ''}`));
  S.home = null;
  await scanCleanup();
}

async function emptyRecycle() {
  const ok = await confirmTwice({ title: 'Esvaziar a Lixeira?', ok: 'Esvaziar Lixeira', text: `${plural(S.recycle.count, 'item', 'itens')} (${fmtBytes(S.recycle.size)}) serão apagados de vez.` },
    { text: 'Depois de esvaziar não dá para recuperar esses arquivos.' });
  if (!ok) return;
  await run('recycle', async () => {
    const r = await call('recycle.empty');
    S.recycle = await call('recycle.info');
    toast(freedMsg(r));
  });
}

function cleanupView(sec) {
  if (!S.cleanup) return intro(sec, 'cleanup', scanCleanup);
  const cats = S.cleanup;
  const selCats = cats.filter((c) => S.cleanupSel.has(c.id));
  const selSize = selCats.reduce((s, c) => s + c.size, 0), selCount = selCats.reduce((s, c) => s + c.count, 0);
  const segs = cats.map((c, i) => ({ label: c.title, value: c.size, color: color(i) }));
  const rows = [];
  cats.forEach((c, i) => {
    const open = S.cleanupOpen.has(c.id);
    rows.push(h('div.row-i.click', { onclick: () => { open ? S.cleanupOpen.delete(c.id) : S.cleanupOpen.add(c.id); rerender(); } },
      h('input', { type: 'checkbox', checked: S.cleanupSel.has(c.id), disabled: !c.size, 'aria-label': c.title, onclick: (e) => e.stopPropagation(),
        onchange: (e) => { e.target.checked ? S.cleanupSel.add(c.id) : S.cleanupSel.delete(c.id); rerender(); } }),
      icon('chev', `chev${open ? ' open' : ''}`),
      h('span.dotc', { style: { background: color(i) } }),
      h('div.grow', h('div.t', c.title, ' ', c.mode === 'trash' ? h('span.pill.orange', 'vai para a Lixeira') : null), h('div.s', c.desc)),
      h('span.s.faint.num', plural(c.count, 'arquivo', 'arquivos')), h('span.sz', fmtBytes(c.size))));
    if (open) {
      if (!c.items.length) rows.push(h('div.row-i.sub', h('span.s', 'Nada aqui.')));
      for (const it of c.items) {
        rows.push(h('div.row-i.sub', h('div.grow', h('div.t', it.label), h('div.s.sel', it.path)), h('span.s.num', plural(it.count, 'arquivo', 'arquivos')), h('span.sz', fmtBytes(it.size)),
          iconBtn('folder-open', 'Mostrar no Explorer', () => showInExplorer(it.path))));
      }
      if (c.more) rows.push(h('div.row-i.sub', h('span.s', `e mais ${fmtNum(c.more)} itens`)));
    }
  });
  const rb = S.recycle;
  return view('cleanup',
    head(sec, btn('Analisar de novo', scanCleanup, '', 'refresh', { disabled: S.busy.has('cleanup') })),
    S.busy.has('cleanup') ? h('div.go', progressBar('cleanup')) : null,
    winOnly(),
    h('div.split',
      h('div.card', h('h3', icon('chart'), 'Encontrado'),
        h('div', { style: { display: 'grid', placeItems: 'center', marginTop: '14px' } }, donut(segs, 200, fmtBytes(selSize), 'selecionado')),
        legend(segs.filter((s) => s.value > 0))),
      h('div',
        h('div.panel', h('div.ph', h('h3', 'Categorias'), h('span.s.faint', 'Clique para ver os itens')), h('div.rows', rows)),
        rb && rb.supported ? h('div.panel', { style: { marginTop: '14px' } },
          h('div.row-i', h('div.tile', icon('trash')), h('div.grow', h('div.t', 'Lixeira'), h('div.s', `${plural(rb.count, 'item', 'itens')}. Tudo que o app remove passa por ela.`)),
            h('span.sz', fmtBytes(rb.size)), btn('Esvaziar Lixeira', emptyRecycle, 'danger', null, { disabled: !rb.count || S.busy.has('recycle') }))) : null)),
    h('div.grow'),
    h('div.bottombar', h('div', h('div.t', `Selecionado: ${fmtBytes(selSize)}`), h('div.s.faint', plural(selCount, 'arquivo', 'arquivos'))),
      btn(`Limpar ${fmtBytes(selSize)}`, () => cleanSelected([...S.cleanupSel]), 'primary', 'broom', { disabled: !selSize || S.busy.has('cleanup') })));
}

// ---------- 03 Acúmulos ----------

const scanClutter = () => run('clutter', async () => {
  const [l, d] = await Promise.all([call('clutter.large'), call('clutter.dups', { minSize: 1e6 })]);
  S.large = l; S.dups = d; S.largeSel.clear(); S.dupSel.clear();
});

async function trashLarge() {
  const paths = [...S.largeSel];
  const size = S.large.filter((f) => S.largeSel.has(f.path)).reduce((s, f) => s + f.size, 0);
  const first = { title: `Mover ${plural(paths.length, 'arquivo', 'arquivos')} para a Lixeira?`, ok: 'Mover para a Lixeira', text: `${fmtBytes(size)} no total. Dá para recuperar pela Lixeira.` };
  if (!(paths.length > 1 ? await confirmTwice(first, { text: `São ${plural(paths.length, 'arquivo', 'arquivos')} de uma vez. Confira se não são arquivos que você ainda usa.` }) : await confirmBox(first))) return;
  await run('clutter', async () => {
    const r = await call('files.trash', paths);
    const gone = new Set(r.done.map((d) => d.path));
    S.large = S.large.filter((f) => !gone.has(f.path)); S.largeSel.clear();
    toast(`${plural(r.done.length, 'arquivo foi', 'arquivos foram')} para a Lixeira. Esvazie a Lixeira para liberar de verdade.${r.failed.length ? ` ${r.failed.length} não puderam ser movidos.` : ''}`, r.failed.length ? 'orange' : 'green');
  });
}

async function trashDups() {
  const req = S.dups.map((g) => ({ id: g.id, remove: g.files.filter((f) => S.dupSel.has(f.path)).map((f) => f.path) })).filter((r) => r.remove.length);
  const n = req.reduce((s, r) => s + r.remove.length, 0);
  const ok = await confirmTwice({ title: `Mover ${plural(n, 'cópia', 'cópias')} para a Lixeira?`, ok: 'Mover para a Lixeira', text: 'Uma cópia de cada grupo sempre fica no lugar.' },
    { text: 'Confira se as cópias marcadas não são as que você usa no dia a dia.' });
  if (!ok) return;
  await run('clutter', async () => {
    const r = await call('clutter.trashDups', req);
    const gone = new Set(r.done.map((d) => d.path));
    S.dups = S.dups.map((g) => ({ ...g, files: g.files.filter((f) => !gone.has(f.path)) })).filter((g) => g.files.length > 1)
      .map((g) => ({ ...g, wasted: g.size * (g.files.length - 1) }));
    S.dupSel.clear();
    toast(`${plural(r.done.length, 'cópia foi', 'cópias foram')} para a Lixeira. Esvazie a Lixeira para liberar de verdade.`);
  });
}

function markExtras() {
  S.dupSel.clear();
  for (const g of S.dups) [...g.files].sort((a, b) => a.mtimeMs - b.mtimeMs).slice(1).forEach((f) => S.dupSel.add(f.path));
  rerender();
}

function clutterView(sec) {
  if (!S.large || !S.dups) return intro(sec, 'clutter', scanClutter);
  const tab = S.clutterTab;
  const tabs = h('div.tabs',
    h(`button${tab === 'large' ? '.on' : ''}`, { onclick: () => { S.clutterTab = 'large'; rerender(); } }, `Arquivos grandes (${S.large.length})`),
    h(`button${tab === 'dups' ? '.on' : ''}`, { onclick: () => { S.clutterTab = 'dups'; rerender(); } }, `Duplicados (${S.dups.length})`));
  let body, selSize = 0, selN = 0, action;
  if (tab === 'large') {
    body = S.large.length ? h('div.panel', S.large.map((f) => h('div.row-i',
      h('input', { type: 'checkbox', checked: S.largeSel.has(f.path), 'aria-label': f.name, onchange: (e) => { e.target.checked ? S.largeSel.add(f.path) : S.largeSel.delete(f.path); rerender(); } }),
      h('div.tile', icon(/\.(mp4|mov|mkv|avi|wmv|webm|m4v)$/i.test(f.name) ? 'film' : 'file')),
      h('div.grow', h('div.t', f.name), h('div.s', `${f.folder} · ${fmtDate(f.mtimeMs)}`)),
      h('span.sz', fmtBytes(f.size)), iconBtn('folder-open', 'Mostrar no Explorer', () => showInExplorer(f.path)))))
      : h('div.panel', h('div.empty', 'Nenhum arquivo com mais de 200 MB nas suas pastas.'));
    const sel = S.large.filter((f) => S.largeSel.has(f.path));
    selN = sel.length; selSize = sel.reduce((s, f) => s + f.size, 0); action = trashLarge;
  } else {
    body = S.dups.length ? h('div', S.dups.map((g) => {
      const unchecked = g.files.filter((f) => !S.dupSel.has(f.path)).length;
      return h('div.panel', { style: { marginBottom: '12px' } },
        h('div.ph', h('h3', `${g.files.length} cópias · ${fmtBytes(g.size)} cada`), h('span.pill.orange', `${fmtBytes(g.wasted)} repetidos`)),
        g.files.map((f) => {
          const on = S.dupSel.has(f.path);
          return h('div.row-i',
            h('input', { type: 'checkbox', checked: on, disabled: !on && unchecked <= 1, title: !on && unchecked <= 1 ? 'Uma cópia sempre fica' : '', 'aria-label': f.name,
              onchange: (e) => { e.target.checked ? S.dupSel.add(f.path) : S.dupSel.delete(f.path); rerender(); } }),
            h('div.grow', h('div.t', f.name), h('div.s.sel', `${f.dir} · ${fmtDate(f.mtimeMs)}`)),
            !on && unchecked <= 1 ? h('span.pill.green', 'fica') : null,
            iconBtn('folder-open', 'Mostrar no Explorer', () => showInExplorer(f.path)));
        }));
    })) : h('div.panel', h('div.empty', 'Nenhuma cópia idêntica encontrada.'));
    for (const g of S.dups) for (const f of g.files) if (S.dupSel.has(f.path)) { selN++; selSize += g.size; }
    action = trashDups;
  }
  return view('clutter',
    head(sec, tab === 'dups' && S.dups.length ? btn('Marcar cópias extras (mantém a mais antiga)', markExtras, 'ghost', 'check') : null,
      btn('Analisar de novo', scanClutter, '', 'refresh', { disabled: S.busy.has('clutter') })),
    S.busy.has('clutter') ? h('div.go', progressBar('clutter')) : null,
    tabs, body, h('div.grow'),
    h('div.bottombar', h('div', h('div.t', `Selecionado: ${fmtBytes(selSize)}`), h('div.s.faint', plural(selN, 'arquivo', 'arquivos'))),
      btn('Mover para a Lixeira', action, 'danger', 'trash', { disabled: !selN || S.busy.has('clutter') })));
}

// ---------- 04 Desempenho ----------

const level = (v) => (v >= 0.85 ? 'var(--red)' : v >= 0.6 ? 'var(--orange)' : 'var(--blue)');
function gauges() {
  const s = S.sample;
  const g = (lbl, ic, v, det) => h('div.card.gauge', ring(v, level(v), 92), h('div', h('div.lbl', lbl), h('div.det', det)));
  if (!s) return h('div.gauges', { 'data-gauges': '1' }, h('div.card.gauge', h('div.det', 'Lendo CPU e memória…')));
  const disk = s.disk.total ? 1 - s.disk.free / s.disk.total : 0;
  return h('div.gauges', { 'data-gauges': '1' },
    g('CPU', 'cpu', s.cpu, `${s.cores} núcleos · ${s.model.replace(/\s+/g, ' ').slice(0, 40)}`),
    g('MEMÓRIA', 'memory', s.memUsed / s.memTotal, `${fmtBytes(s.memUsed)} de ${fmtBytes(s.memTotal)}`),
    g('DISCO', 'hdd', disk, `${fmtBytes(s.disk.free)} livres`));
}

const scanPerf = () => run('perf', async () => {
  const [p, st] = await Promise.all([call('perf.processes'), call('startup.list')]);
  S.procs = p; S.startup = st;
});

async function killProc(g) {
  if (!(await confirmBox({ title: `Encerrar ${g.name}?`, ok: 'Encerrar', danger: true, text: `${plural(g.pids.length, 'processo', 'processos')}. Trabalho não salvo nesse app pode ser perdido.` }))) return;
  await run('perf', async () => {
    let r = await call('perf.kill', g.name, false);
    if (r.left && await confirmBox({ title: 'Ainda aberto', ok: 'Forçar', danger: true, text: `${plural(r.left, 'processo não fechou', 'processos não fecharam')}. Forçar o encerramento?` })) r = await call('perf.kill', g.name, true);
    toast(r.left ? `${g.name}: ${r.left} ainda em execução` : `${g.name} encerrado`, r.left ? 'orange' : 'green');
    S.procs = await call('perf.processes');
  });
}

async function toggleStartup(item) {
  await run('startup', async () => {
    S.startup = await call('startup.toggle', item.id, !item.enabled);
    toast(item.enabled ? `${item.name} não abre mais com o Windows (dá para reativar aqui)` : `${item.name} volta a abrir com o Windows`);
  });
}

function perfView(sec) {
  const parts = [head(sec, S.procs ? btn('Atualizar', scanPerf, '', 'refresh', { disabled: S.busy.has('perf') }) : null), gauges()];
  if (!S.procs) {
    parts.push(h('div.intro', h('div', h('p.pitch', sec.pitch), h('ul.features', sec.features.map(([t, ic]) => h('li', h('div.tile', icon(ic)), t))))));
    parts.push(goArea('perf', 'Analisar', scanPerf));
    return view('perf', ...parts);
  }
  const maxMem = Math.max(1, ...S.procs.map((p) => p.mem));
  parts.push(winOnly(),
    h('div.split', { style: { gridTemplateColumns: '1.15fr 1fr' } },
      h('div.panel', h('div.ph', h('h3', 'Processos pesados'), h('span.s.faint', 'CPU · memória')),
        S.procs.slice(0, 18).map((p) => h('div.row-i',
          h('div.grow', h('div.t', p.name), h('div.s', plural(p.pids.length, 'processo', 'processos'))),
          h(`span.num.${p.cpu >= 50 ? 'neg' : p.cpu >= 20 ? 'warn' : 'muted'}`, `${p.cpu.toLocaleString('pt-BR')}%`),
          h('div.minibar', h('i', { style: { width: `${(p.mem / maxMem) * 100}%`, background: 'var(--c2)' } })),
          h('span.sz', fmtBytes(p.mem)),
          h('div', { style: { width: '96px', display: 'flex', justifyContent: 'flex-end' } }, p.protected ? h('span.pill', 'sistema') : btn('Encerrar', () => killProc(p), 'danger'))))),
      h('div.panel', h('div.ph', h('h3', 'Inicialização'), h('span.s.faint', `${(S.startup || []).filter((x) => x.enabled).length} ativos`)),
        (S.startup || []).length ? S.startup.map((it) => h(`div.row-i${it.enabled ? '' : '.dis'}`,
          h('div.tile', icon('power')),
          h('div.grow', h('div.t', it.name), h('div.s', { title: it.command }, `${it.kind} · ${it.command}`)),
          h(`span.pill.${it.enabled ? 'green' : ''}`, it.enabled ? 'Ativo' : 'Desativado'),
          btn(it.enabled ? 'Desativar' : 'Ativar', () => toggleStartup(it), 'ghost', null, { disabled: S.busy.has('startup') })))
          : h('div.empty', 'Nenhum item de inicialização do seu usuário.'))));
  return view('perf', ...parts);
}

// ---------- 05 Lupa de espaço ----------

const openLens = (dir, fresh = false) => run('lens', async () => { S.lens = await call('lens.list', dir || null, fresh); });

async function trashLens(it) {
  const first = { title: `Mover "${it.name}" para a Lixeira?`, ok: 'Mover para a Lixeira', text: `${fmtBytes(it.size)}${it.dir ? ` em ${plural(it.files, 'arquivo', 'arquivos')}` : ''}. Dá para recuperar pela Lixeira.` };
  const ok = it.dir && it.files > 1 ? await confirmTwice(first, { text: `É uma pasta inteira com ${plural(it.files, 'arquivo', 'arquivos')}.` }) : await confirmBox(first);
  if (!ok) return;
  await run('lens', async () => {
    await call('lens.trash', it.path);
    toast(`"${it.name}" foi para a Lixeira`);
    S.lens = await call('lens.list', S.lens.dir, true);
  });
}

function lensView(sec) {
  if (!S.lens) return intro(sec, 'lens', () => openLens(null));
  const L = S.lens;
  const top = L.items.filter((i) => i.size > 0).slice(0, 7);
  const rest = L.total - top.reduce((s, i) => s + i.size, 0);
  const segs = top.map((it, i) => ({ label: it.name, value: it.size, color: color(i) }));
  if (rest > 0) segs.push({ label: 'Outros', value: rest, color: 'var(--c9)' });
  const parts = L.dir.split(/[\\/]/).filter(Boolean);
  return view('lens',
    head(sec, btn('Atualizar', () => openLens(L.dir, true), '', 'refresh', { disabled: S.busy.has('lens') })),
    h('div.crumbs', { style: { marginBottom: '14px' } },
      L.parent ? btn('Voltar', () => openLens(L.parent), 'ghost', 'back', { disabled: S.busy.has('lens') }) : null,
      h('span.sel', parts.slice(0, -1).join(' › ')), parts.length > 1 ? ' › ' : '', h('b', L.name)),
    S.busy.has('lens') ? h('div.go', progressBar('lens')) : null,
    h('div.split',
      h('div.card', h('h3', icon('chart'), 'Nesta pasta'),
        h('div', { style: { display: 'grid', placeItems: 'center', marginTop: '14px' } }, donut(segs, 210, fmtBytes(L.total), 'no total')),
        legend(segs)),
      h('div.panel', h('div.ph', h('h3', plural(L.items.length, 'item', 'itens')), h('span.s.faint', 'Clique numa pasta para entrar')),
        L.items.length ? L.items.slice(0, 200).map((it, i) => h(`div.row-i${it.dir ? '.click' : ''}`, { onclick: it.dir ? () => openLens(it.path) : null },
          h('span.dotc', { style: { background: i < 7 && it.size > 0 ? color(i) : 'var(--c9)' } }),
          icon(it.dir ? 'folder' : 'file'),
          h('div.grow', h('div.t', it.name), it.partial ? h('div.s.warn', 'medição parcial') : null),
          h('div.minibar', h('i', { style: { width: `${L.total ? (it.size / L.total) * 100 : 0}%`, background: i < 7 ? color(i) : 'var(--c9)' } })),
          h('span.sz', fmtBytes(it.size)),
          iconBtn('folder-open', 'Mostrar no Explorer', (e) => { e.stopPropagation(); showInExplorer(it.path); }),
          h('div', { style: { width: '84px', display: 'flex', justifyContent: 'center' } }, it.protected ? h('span.pill', { title: 'Pasta protegida' }, 'protegida')
            : iconBtn('trash', 'Mover para a Lixeira', (e) => { e.stopPropagation(); trashLens(it); }))))
          : h('div.empty', 'Pasta vazia.'))));
}

// ---------- 06 Aplicativos ----------

const scanApps = () => run('apps', async () => { S.apps = await call('apps.list'); });

async function uninstallApp(a) {
  if (!(await confirmBox({ title: `Desinstalar ${a.name}?`, ok: 'Abrir desinstalador', danger: true,
    text: 'O desinstalador oficial do app vai abrir. Siga os passos dele; o Windows pode pedir permissão de administrador.' }))) return;
  try { await call('apps.uninstall', a.id); toast(`Desinstalador de ${a.name} aberto. Depois clique em Analisar de novo.`); } catch (e) { toast(e.message, 'red'); }
}

function filterApps(q) {
  S.appsQuery = q;
  const n = q.trim().toLowerCase();
  for (const el of document.querySelectorAll('[data-app]')) el.style.display = !n || el.dataset.app.includes(n) ? '' : 'none';
}

function appsView(sec) {
  if (!S.apps) return intro(sec, 'apps', scanApps);
  const total = S.apps.reduce((s, a) => s + a.size, 0);
  const v = view('apps',
    head(sec, h('input', { type: 'search', placeholder: 'Buscar app', value: S.appsQuery, oninput: (e) => filterApps(e.target.value), 'aria-label': 'Buscar app' }),
      btn('Analisar de novo', scanApps, '', 'refresh', { disabled: S.busy.has('apps') })),
    S.busy.has('apps') ? h('div.go', progressBar('apps')) : null,
    winOnly(),
    h('div.panel', h('div.ph', h('h3', plural(S.apps.length, 'aplicativo', 'aplicativos')), h('span.s.faint', `${fmtBytes(total)} informados pelos instaladores`)),
      S.apps.length ? S.apps.map((a) => h('div.row-i', { 'data-app': `${a.name} ${a.publisher}`.toLowerCase() },
        h('div.tile', icon('grid')),
        h('div.grow', h('div.t', a.name), h('div.s', [a.publisher, a.version].filter(Boolean).join(' · ') || ' ')),
        h('span.sz', a.size ? fmtBytes(a.size) : '—'),
        a.canUninstall ? btn('Desinstalar', () => uninstallApp(a), 'danger') : h('span.pill', 'sem desinstalador')))
        : h('div.empty', 'Nenhum aplicativo encontrado.')));
  if (S.appsQuery) setTimeout(() => filterApps(S.appsQuery));
  return v;
}

// ---------- 07 Organizar ----------

const orgDir = () => S.org.dir || (S.info.folders.find((f) => f.key === 'downloads') || {}).path || S.info.home;

async function orgPreview() {
  await run('organize', async () => { S.org.preview = await call('org.preview', orgDir(), S.org.mode); });
}
async function orgApply() {
  const p = S.org.preview;
  if (!(await confirmBox({ title: `Organizar ${plural(p.count, 'arquivo', 'arquivos')}?`, ok: 'Organizar',
    text: `Eles vão para subpastas ${S.org.mode === 'month' ? 'por mês' : 'por tipo'} dentro de ${p.dir}. Nada é sobrescrito e dá para desfazer.` }))) return;
  await run('organize', async () => {
    const r = await call('org.apply');
    S.org.preview = null; S.org.last = await call('org.last');
    toast(`${plural(r.moved, 'arquivo organizado', 'arquivos organizados')}${r.skipped ? ` · ${r.skipped} em uso ficaram onde estavam` : ''}`);
  });
}
async function orgUndo() {
  if (!(await confirmBox({ title: 'Desfazer a última organização?', ok: 'Desfazer', text: 'Os arquivos voltam para onde estavam.' }))) return;
  await run('organize', async () => {
    const r = await call('org.undo');
    S.org.last = null;
    toast(`${plural(r.back, 'arquivo voltou', 'arquivos voltaram')} para o lugar`);
  });
}

function organizeView(sec) {
  const p = S.org.preview;
  const mode = (m, label, ic) => h(`button${S.org.mode === m ? '.on' : ''}`, { onclick: () => { S.org.mode = m; S.org.preview = null; rerender(); } }, label);
  const folders = p ? Object.entries(p.folders).sort((a, b) => b[1].count - a[1].count) : [];
  return view('organize',
    head(sec),
    h('p.pitch', { style: { marginTop: '-6px', marginBottom: '18px' } }, sec.pitch),
    h('div.card', h('div', { style: { display: 'flex', gap: '12px', alignItems: 'center', flexWrap: 'wrap' } },
      h('div.tile', icon('folder')), h('div.grow', { style: { flex: '1', minWidth: '200px' } }, h('div.t', 'Pasta'), h('div.s.sel.muted', orgDir())),
      btn('Escolher pasta', async () => { const d = await call('dialog.folder', orgDir()); if (d) { S.org.dir = d; S.org.preview = null; rerender(); } }),
      h('div.seg', mode('type', 'Por tipo'), mode('month', 'Por mês')),
      btn('Ver prévia', orgPreview, 'primary', null, { disabled: S.busy.has('organize') }))),
    S.org.last ? h('div.note', icon('undo'), h('span.grow', { style: { flex: '1' } }, `Última organização: ${plural(S.org.last.count, 'arquivo', 'arquivos')} em ${S.org.last.dir} (${fmtDate(S.org.last.at)}).`),
      btn('Desfazer', orgUndo, 'ghost')) : null,
    S.busy.has('organize') ? h('div.go', progressBar('organize')) : null,
    p ? [
      h('div.grid', { style: { margin: '18px 0' } }, folders.map(([name, f], i) => h('div.card', h('h3', h('span.dotc', { style: { background: color(i) } }), name),
        h('div.big', fmtNum(f.count)), h('p', fmtBytes(f.size))))),
      p.count ? h('div.panel', h('div.ph', h('h3', 'Prévia'), h('span.s.faint', p.count > p.plan.length ? `mostrando ${p.plan.length} de ${p.count}` : plural(p.count, 'arquivo', 'arquivos'))),
        p.plan.map((x) => h('div.row-i', icon('file'), h('div.grow', h('div.t', x.name), h('div.s', `→ ${x.folder}\\${x.target}`)), x.target !== x.name ? h('span.pill.orange', 'renomeado') : null)))
        : h('div.panel', h('div.empty', 'Nada para organizar nessa pasta.')),
      h('div.grow'),
      h('div.bottombar', h('span.muted', 'Pastas e arquivos em download ficam onde estão.'),
        btn(`Organizar ${plural(p.count, 'arquivo', 'arquivos')}`, orgApply, 'primary', 'tray', { disabled: !p.count || S.busy.has('organize') })),
    ] : h('div.empty', 'Escolha a pasta e o jeito de organizar, depois veja a prévia. Nada muda antes de você confirmar.'));
}

// ---------- 08 Compressor ----------

async function compressRun() {
  const c = S.comp;
  await run('compress', async () => {
    c.results = await call('compress.run', { files: c.files, codec: c.codec, trashOriginal: c.trash });
    const saved = c.results.filter((r) => r.ok).reduce((s, r) => s + Math.max(0, r.before - r.after), 0);
    c.files = [];
    toast(`Pronto: ${fmtBytes(saved)} a menos`);
  });
}

function compressView(sec) {
  const c = S.comp;
  const codec = (k, label) => h(`button${c.codec === k ? '.on' : ''}`, { onclick: () => { c.codec = k; rerender(); } }, label);
  const busy = S.busy.has('compress');
  return view('compress',
    head(sec),
    h('p.pitch', { style: { marginTop: '-6px', marginBottom: '18px' } }, sec.pitch),
    h('div.card', h('div', { style: { display: 'flex', gap: '12px', alignItems: 'center', flexWrap: 'wrap' } },
      h('div.seg', codec('hevc', 'HEVC (H.265)'), codec('h264', 'H.264 (compatível)'), codec('mp3', 'MP3 (áudio)')),
      h('div', { style: { flex: '1' } }),
      btn('Escolher arquivos', async () => { const f = await call('dialog.media', c.codec === 'mp3' ? 'audio' : 'video'); if (f.length) { c.files = [...new Set([...c.files, ...f])]; rerender(); } }, '', 'file', { disabled: busy })),
      h('label', { style: { display: 'flex', gap: '10px', alignItems: 'center', marginTop: '14px', cursor: 'pointer' } },
        h('input', { type: 'checkbox', checked: c.trash, disabled: c.codec === 'mp3', onchange: (e) => { c.trash = e.target.checked; } }),
        h('span', 'Enviar o original para a Lixeira depois que der certo (só se ficar menor)'))),
    h('div.note', icon('shield'), h('span', 'O original fica intacto por padrão. Na primeira vez o app baixa o ffmpeg oficial (gyan.dev).')),
    c.files.length ? h('div.panel', h('div.ph', h('h3', plural(c.files.length, 'arquivo', 'arquivos'))),
      c.files.map((f) => h('div.row-i', icon(c.codec === 'mp3' ? 'music' : 'film'), h('div.grow', h('div.t', f.split(/[\\/]/).pop()), h('div.s.sel', f)),
        busy ? null : iconBtn('x', 'Tirar da lista', () => { c.files = c.files.filter((x) => x !== f); rerender(); })))) : null,
    c.results ? h('div.panel', { style: { marginTop: '14px' } }, h('div.ph', h('h3', 'Resultado')),
      c.results.map((r) => h('div.row-i', icon(r.ok ? 'check' : 'alert', r.ok ? 'pos' : 'neg'),
        h('div.grow', h('div.t', r.file.split(/[\\/]/).pop()),
          h('div.s', r.ok ? `${fmtBytes(r.before)} → ${fmtBytes(r.after)}${r.trashed ? ' · original na Lixeira' : ''}` : r.error)),
        r.ok ? (r.bigger ? h('span.pill.orange', 'não ficou menor') : h('span.pill.green', `−${Math.round((1 - r.after / r.before) * 100)}%`)) : null,
        r.ok ? iconBtn('folder-open', 'Mostrar no Explorer', () => showInExplorer(r.out)) : null))) : null,
    h('div.grow'),
    h('div.go', busy ? progressBar('compress') : null,
      h('button.round', { disabled: busy || !c.files.length, onclick: compressRun, 'data-primary': '1' }, busy ? '…' : 'Comprimir'),
      busy ? btn('Cancelar', () => call('compress.cancel'), 'ghost') : h('div.hint', c.files.length ? 'ou aperte Enter' : 'Escolha os arquivos primeiro')));
}

// ---------- 09 Baixar vídeo ----------

function dlRows() {
  const jobs = [...S.dl.jobs].reverse();
  if (!jobs.length) return [h('div.empty', 'Cole um link do Instagram, Pinterest, YouTube ou TikTok.')];
  return jobs.map((j) => {
    const tone = j.status === 'pronto' ? 'var(--green)' : j.status === 'erro' ? 'var(--red)' : 'var(--blue)';
    const bar = h('div.track.thick', h('i', { style: { width: `${(j.status === 'pronto' ? 1 : j.fraction || 0) * 100}%`, background: tone } }));
    return h('div.row-i',
      h('div.tile', icon(j.status === 'pronto' ? 'check' : j.status === 'erro' ? 'alert' : 'download', j.status === 'pronto' ? 'pos' : j.status === 'erro' ? 'neg' : '')),
      h('div.grow', h('div.t', j.title), h(`div.s${j.status === 'erro' ? '.neg' : ''}`, j.error || j.detail), h('div', { style: { marginTop: '6px' } }, bar)),
      ['fila', 'baixando'].includes(j.status) ? btn('Cancelar', () => call('dl.cancel', j.id), 'ghost') : null,
      j.status === 'pronto' && j.file ? [btn('Abrir', () => call('shell.open', j.file).catch((e) => toast(e.message, 'red')), 'ghost', 'play'),
        iconBtn('folder-open', 'Mostrar na pasta', () => showInExplorer(j.file))] : null);
  });
}
function refreshDl() {
  const q = document.getElementById('dlq');
  if (q) q.replaceChildren(...dlRows());
}

async function addLink(input) {
  const links = input.value.split(/\s+/).filter(Boolean);
  if (!links.length) return toast('Cole um link que comece com https://', 'orange');
  for (const l of links) { try { await call('dl.add', l); } catch (e) { toast(e.message, 'orange'); } }
  input.value = '';
}

function downloadView(sec) {
  const input = h('input', { type: 'text', placeholder: 'https://www.instagram.com/reel/…', 'aria-label': 'Link do vídeo', style: { flex: '1', minWidth: '260px', height: '44px', fontSize: '15px' },
    onkeydown: (e) => { if (e.key === 'Enter') { e.preventDefault(); addLink(input); } } });
  return view('download',
    head(sec, btn('Abrir pasta', () => call('shell.open', S.dl.dir).catch(() => toast('A pasta aparece depois do primeiro download.', 'orange')), '', 'folder-open')),
    h('p.pitch', { style: { marginTop: '-6px', marginBottom: '18px' } }, sec.pitch),
    h('div.card', h('div', { style: { display: 'flex', gap: '10px', alignItems: 'center' } }, input, btn('Baixar', () => addLink(input), 'primary', 'download', { style: { height: '44px' } })),
      h('p', { style: { marginTop: '10px' } }, `Instagram, Pinterest, YouTube e TikTok. Salva em ${S.dl.dir || 'Downloads\\Limpo e Voando'}. Um de cada vez, na fila.`)),
    h('div.note', icon('shield'), h('span', 'Na primeira vez o app baixa o yt-dlp oficial (GitHub) e o ffmpeg (gyan.dev). Se o site pedir login, entre nele pelo Firefox neste PC: o app tenta usar esse login sozinho.')),
    h('div.panel', h('div.ph', h('h3', 'Fila')), h('div', { id: 'dlq' }, dlRows())));
}

// ---------- 10 Ferramentas ----------

function toolsView(sec) {
  return view('tools',
    head(sec),
    h('p.pitch', { style: { marginTop: '-6px', marginBottom: '22px' } }, sec.pitch),
    h('div.grid', SECTIONS.filter((s) => s.id !== 'tools').map((s) => h('div.card.click', { onclick: () => App.go(s.id), tabindex: '0', onkeydown: (e) => { if (e.key === 'Enter') App.go(s.id); } },
      h('div.tile', icon(s.icon)), h('div.eyebrow', { style: { marginTop: '16px' } }, h('span.n', s.num), h('span.bar'), h('span', s.title)),
      h('p', { style: { marginTop: '8px' } }, s.pitch)))));
}

const VIEWS = { home: homeView, cleanup: cleanupView, clutter: clutterView, perf: perfView, lens: lensView, apps: appsView,
  organize: organizeView, compress: compressView, download: downloadView, tools: toolsView };

window.Sections = { SECTIONS, SEC, S, VIEWS, gauges, refreshDl };
