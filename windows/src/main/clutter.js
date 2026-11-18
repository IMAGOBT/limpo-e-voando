'use strict';
// 03 — Acúmulos: arquivos grandes e duplicados nas pastas do usuário. Nada é pré-marcado.
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const fsx = require('./fsx');
const { sizeGroups, validateDupRemoval } = require('./logic');

const SKIP = new Set(['node_modules', '$recycle.bin', 'appdata', '.git', '.cache', 'system volume information']);
const skipDir = (name) => name.startsWith('.') || SKIP.has(name.toLowerCase());
let lastGroups = [];

async function large(progress = () => {}, opts = {}) {
  const min = opts.min || 200e6;
  const folders = fsx.userFolders();
  const found = new Map();
  for (let i = 0; i < folders.length; i++) {
    progress(i / folders.length, `Procurando arquivos grandes em ${folders[i].label}…`);
    await fsx.walk(folders[i].path, (p, st) => {
      if (st.size >= min) found.set(p, { path: p, name: path.basename(p), size: st.size, mtimeMs: st.mtimeMs, folder: folders[i].label });
    }, { skipDir, deadline: opts.deadline });
  }
  const list = [...found.values()].sort((a, b) => b.size - a.size).slice(0, opts.limit || 300);
  fsx.allow(list.map((f) => f.path));
  progress(1, 'Pronto');
  return list;
}

async function hashFile(p, bytes, deadline) {
  return new Promise((resolve, reject) => {
    const h = crypto.createHash('sha256');
    const s = fs.createReadStream(p, bytes ? { start: 0, end: bytes - 1 } : {});
    s.on('data', (c) => {
      if (deadline && Date.now() > deadline) { s.destroy(); reject(new Error('tempo esgotado')); return; }
      h.update(c);
    });
    s.on('error', reject);
    s.on('end', () => resolve(h.digest('hex')));
  });
}

/** Divide cada grupo pelo resultado de `fn` (descarta grupos com 1 arquivo e arquivos ilegíveis). */
async function splitBy(groups, fn) {
  const out = [];
  for (const g of groups) {
    const by = new Map();
    for (const f of g) {
      let k;
      try { k = await fn(f); } catch { continue; }
      if (!by.has(k)) by.set(k, []);
      by.get(k).push(f);
    }
    for (const [k, list] of by) if (list.length > 1) out.push(Object.assign(list, { hash: k }));
  }
  return out;
}

async function duplicates(progress = () => {}, opts = {}) {
  const minSize = opts.minSize || 1e6, maxFiles = opts.maxFiles || 200000;
  const files = [];
  // Ler o conteúdo de arquivos "só na nuvem" do OneDrive faria o Windows baixá-los: duplicados ignora o OneDrive.
  const cloud = /[\\/]onedrive/i;
  const folders = fsx.userFolders().filter((f) => !cloud.test(f.path));
  const skipDup = (name, full) => skipDir(name) || /^onedrive/i.test(name) || cloud.test(full);
  for (let i = 0; i < folders.length && files.length < maxFiles; i++) {
    progress(0.3 * i / folders.length, `Listando ${folders[i].label}…`);
    await fsx.walk(folders[i].path, (p, st) => {
      if (st.size >= minSize && files.length < maxFiles) files.push({ path: p, size: st.size, dev: st.dev, ino: st.ino, mtimeMs: st.mtimeMs });
    }, { skipDir: skipDup, deadline: opts.deadline });
  }
  let groups = sizeGroups(files);
  progress(0.35, 'Comparando o começo dos arquivos…');
  groups = await splitBy(groups, (f) => hashFile(f.path, 65536, opts.deadline));
  const total = groups.reduce((s, g) => s + g.reduce((t, f) => t + f.size, 0), 0) || 1;
  let done = 0;
  const full = [];
  for (const g of groups) {
    if (opts.deadline && Date.now() > opts.deadline) break;
    const parts = await splitBy([g], async (f) => {
      const h = await hashFile(f.path, 0, opts.deadline);
      done += f.size;
      progress(0.4 + 0.6 * done / total, 'Conferindo cópias idênticas (SHA-256)…');
      return h;
    });
    full.push(...parts);
  }
  lastGroups = full.map((g, i) => ({
    id: `g${i}`, size: g[0].size, hash: g.hash, wasted: g[0].size * (g.length - 1),
    files: g.map((f) => ({ path: f.path, name: path.basename(f.path), dir: path.dirname(f.path), mtimeMs: f.mtimeMs })),
  })).sort((a, b) => b.wasted - a.wasted).slice(0, opts.limit || 300);
  fsx.allow(lastGroups.flatMap((g) => g.files.map((f) => f.path)));
  progress(1, 'Pronto');
  return lastGroups;
}

/** request: [{id, remove:[paths]}]. Sempre mantém ao menos uma cópia por grupo. */
async function trashDuplicates(request) {
  const before = await fsx.diskFree();
  const paths = validateDupRemoval(lastGroups, request);
  const r = await fsx.trash(paths);
  const after = await fsx.diskFree();
  return { ...r, real: Math.max(0, after.free - before.free) };
}

module.exports = { large, duplicates, trashDuplicates };
