'use strict';
// --smoke: roda todos os scanners sem interface (só leitura), abre a janela escondida,
// passa por todas as seções e falha se algo lançar erro ou o renderer registrar erro no console.
const fs = require('fs');
const path = require('path');
const os = require('os');
const cleanup = require('./cleanup');
const clutter = require('./clutter');
const perf = require('./perf');
const apps = require('./apps');
const lens = require('./lens');
const organize = require('./organize');
const media = require('./media');
const fsx = require('./fsx');

const SECTIONS = ['home', 'cleanup', 'clutter', 'perf', 'lens', 'apps', 'organize', 'compress', 'download', 'tools'];
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const noop = () => {};

function summarize(v) {
  if (Array.isArray(v)) return { count: v.length, sample: v.slice(0, 3).map((x) => x.title || x.name || x.path || x.id) };
  if (v && typeof v === 'object') {
    const o = {};
    for (const [k, x] of Object.entries(v)) o[k] = Array.isArray(x) ? `${x.length} itens` : (typeof x === 'object' && x ? '{…}' : x);
    return o;
  }
  return v;
}

async function run({ createWindow }) {
  const outArg = process.argv.find((a) => a.startsWith('--smoke-out='));
  const outFile = outArg ? outArg.slice(12) : path.join(os.tmpdir(), 'limpo-e-voando-smoke.json');
  const report = { platform: process.platform, startedAt: new Date().toISOString(), scanners: {}, renderer: { sections: {}, errors: [] }, ok: false };
  let failures = 0;
  const step = async (name, fn) => {
    const t = Date.now();
    try {
      const v = await Promise.race([fn(), sleep(240000).then(() => { throw new Error('tempo esgotado (240 s)'); })]);
      report.scanners[name] = { ok: true, ms: Date.now() - t, result: summarize(v) };
    } catch (e) {
      failures++;
      report.scanners[name] = { ok: false, ms: Date.now() - t, error: String(e && e.stack ? e.stack : e) };
    }
    process.stdout.write(`[smoke] ${name}: ${report.scanners[name].ok ? 'ok' : 'FALHOU'} (${Date.now() - t} ms)\n`);
  };
  const deadline = () => Date.now() + 60000;

  await step('limpeza', () => cleanup.scan(noop, { deadline: deadline() }));
  await step('lixeira', () => cleanup.recycleInfo());
  await step('grandes', () => clutter.large(noop, { deadline: deadline() }));
  await step('duplicados', () => clutter.duplicates(noop, { minSize: 2e6, maxFiles: 3000, limit: 50, deadline: deadline() }));
  await step('inicializacao', () => perf.startupList());
  await step('apps', () => apps.list());
  await step('lupa', () => lens.list(os.homedir(), noop, { deadline: deadline() }));
  await step('desempenho', async () => {
    await perf.sample(); await sleep(400);
    const s = await perf.sample();
    const p = await perf.processes();
    return { cpu: s.cpu, memUsed: s.memUsed, diskFree: s.disk.free, processos: p.length };
  });
  await step('organizar_previa', async () => {
    const dir = (fsx.userFolders().find((f) => f.key === 'downloads') || fsx.userFolders()[0] || {}).path;
    return dir ? organize.preview(dir, 'type') : 'sem pasta';
  });
  await step('ferramentas', async () => media.toolsStatus());

  // Renderer: janela escondida, navega por todas as seções.
  const t = Date.now();
  try {
    const w = createWindow({ show: false });
    const errs = report.renderer.errors;
    w.webContents.on('console-message', function onConsole(e) {
      // Electron novo: tudo no objeto do evento; antigo: argumentos posicionais (level 3 = erro)
      const lv = e && e.level !== undefined ? e.level : arguments[1];
      const msg = e && e.message !== undefined ? e.message : arguments[2];
      if (lv === 3 || lv === 'error') errs.push(`${msg} (${(e && e.sourceId) || arguments[4] || ''}:${(e && e.lineNumber) || arguments[3] || ''})`);
    });
    w.webContents.on('preload-error', (_e, p, err) => errs.push(`preload: ${err && err.message}`));
    w.webContents.on('render-process-gone', (_e, d) => errs.push(`renderer caiu: ${d.reason}`));
    w.webContents.on('did-fail-load', (_e, code, desc) => errs.push(`falha ao carregar: ${code} ${desc}`));
    await new Promise((res) => { w.webContents.once('did-finish-load', res); setTimeout(res, 20000); });
    await sleep(800);
    for (const s of SECTIONS) {
      const ok = await w.webContents.executeJavaScript(
        `(async () => { await window.__lv.go(${JSON.stringify(s)}); await new Promise(r => setTimeout(r, 500));
          const el = document.querySelector('[data-view="${s}"]'); return !!el && el.textContent.trim().length > 0; })()`);
      report.renderer.sections[s] = ok;
      if (!ok) errs.push(`seção ${s} não renderizou`);
    }
    for (const theme of ['dark', 'light', 'system']) await w.webContents.executeJavaScript(`window.__lv.theme(${JSON.stringify(theme)})`);
    await sleep(300);
    report.renderer.ms = Date.now() - t;
    if (errs.length) failures++;
    w.destroy();
  } catch (e) {
    failures++;
    report.renderer.errors.push(String(e && e.stack ? e.stack : e));
  }
  process.stdout.write(`[smoke] renderer: ${report.renderer.errors.length ? 'FALHOU' : 'ok'}\n`);

  report.ok = failures === 0;
  report.finishedAt = new Date().toISOString();
  const json = JSON.stringify(report, null, 2);
  try { fs.writeFileSync(outFile, json); } catch (e) { process.stdout.write(`[smoke] não gravou ${outFile}: ${e.message}\n`); }
  await new Promise((r) => process.stdout.write(`${json}\n[smoke] resultado: ${report.ok ? 'OK' : 'FALHOU'} → ${outFile}\n`, r));
  return report.ok ? 0 : 1;
}

module.exports = { run };
