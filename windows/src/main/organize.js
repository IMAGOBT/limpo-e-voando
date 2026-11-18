'use strict';
// 07 — Organizar: separa os arquivos de uma pasta em subpastas por tipo ou por mês. Prévia, nunca sobrescreve, desfaz.
const fs = require('fs');
const fsp = fs.promises;
const path = require('path');
const fsx = require('./fsx');
const { planOrganize, uniqueName, isInside } = require('./logic');

let logFile = null;
let pending = null;      // última prévia: { dir, mode, plan }

function init(userData) { logFile = path.join(userData, 'organizar-ultimo.json'); }

function checkDir(dir) {
  dir = path.resolve(dir);
  if (!fsx.penv().roots.some((r) => isInside(dir, r, process.platform))) throw new Error('Escolha uma pasta dentro do seu usuário.');
  if (fsx.protectedPath(dir) && !fsx.userFolders().some((f) => path.resolve(f.path) === dir)) throw new Error('Essa pasta é protegida.');
  return dir;
}

async function preview(dir, mode) {
  dir = checkDir(dir);
  const entries = await fsp.readdir(dir, { withFileTypes: true });
  const files = [];
  const existing = new Map();
  for (const d of entries) {
    if (d.isDirectory() && !d.isSymbolicLink()) {
      try { existing.set(d.name, new Set((await fsp.readdir(path.join(dir, d.name))).map((n) => n.toLowerCase()))); } catch { /* */ }
      continue;
    }
    if (!d.isFile()) continue;
    try {
      const st = await fsp.lstat(path.join(dir, d.name));
      files.push({ name: d.name, mtimeMs: st.mtimeMs, size: st.size });
    } catch { /* sumiu */ }
  }
  const plan = planOrganize(files, mode, existing);
  pending = { dir, mode, plan };
  const folders = {};
  for (const p of plan) { folders[p.folder] = folders[p.folder] || { count: 0, size: 0 }; folders[p.folder].count++; folders[p.folder].size += p.size; }
  return { dir, mode, count: plan.length, folders, plan: plan.slice(0, 400) };
}

async function apply(progress = () => {}) {
  if (!pending) throw new Error('Gere a prévia primeiro.');
  const { dir, plan } = pending;
  pending = null;
  const moves = [], created = [];
  let skipped = 0;
  for (let i = 0; i < plan.length; i++) {
    const p = plan[i];
    const folder = path.join(dir, p.folder);
    if (!fs.existsSync(folder)) { await fsp.mkdir(folder); created.push(folder); }
    const from = path.join(dir, p.name);
    let to = path.join(folder, p.target);
    if (await fsx.exists(to)) to = path.join(folder, uniqueName(p.target, (n) => fs.existsSync(path.join(folder, n))));
    try { await fsp.rename(from, to); moves.push({ from, to }); } catch { skipped++; }
    if (i % 25 === 0) progress(i / plan.length, `Movendo ${p.name}…`);
  }
  const run = { dir, at: Date.now(), moves, created };
  await fsp.writeFile(logFile, JSON.stringify(run));
  progress(1, 'Pronto');
  return { moved: moves.length, skipped };
}

async function lastRun() {
  try { const r = JSON.parse(await fsp.readFile(logFile, 'utf8')); return { dir: r.dir, at: r.at, count: r.moves.length }; } catch { return null; }
}

async function undo() {
  let run;
  try { run = JSON.parse(await fsp.readFile(logFile, 'utf8')); } catch { throw new Error('Nada para desfazer.'); }
  let back = 0, skipped = 0;
  for (const m of run.moves.reverse()) {
    if (!(await fsx.exists(m.to))) { skipped++; continue; }
    let dest = m.from;
    if (await fsx.exists(dest)) dest = path.join(path.dirname(dest), uniqueName(path.basename(dest), (n) => fs.existsSync(path.join(path.dirname(m.from), n))));
    try { await fsp.rename(m.to, dest); back++; } catch { skipped++; }
  }
  for (const d of run.created) { try { await fsp.rmdir(d); } catch { /* não está vazia: fica */ } }
  await fsp.unlink(logFile).catch(() => {});
  return { back, skipped };
}

module.exports = { init, preview, apply, undo, lastRun };
