'use strict';
// 05 — Lupa de espaço: tamanho de cada item de uma pasta, 4 de cada vez, com navegação.
const fsp = require('fs').promises;
const path = require('path');
const os = require('os');
const fsx = require('./fsx');
const { isInside } = require('./logic');

const cache = new Map();

async function list(dir, progress = () => {}, opts = {}) {
  dir = path.resolve(dir || os.homedir());
  const roots = fsx.penv().roots;
  if (!roots.some((r) => isInside(dir, r, process.platform))) throw new Error('A lupa só abre pastas do seu usuário.');
  if (!opts.fresh && cache.has(dir)) return cache.get(dir);
  let entries = [];
  try { entries = await fsp.readdir(dir, { withFileTypes: true }); } catch (e) { throw new Error(`Não consegui abrir a pasta (${e.code || e.message}).`); }
  entries = entries.filter((d) => !d.isSymbolicLink() && (d.isDirectory() || d.isFile()));
  let done = 0;
  const items = await fsx.pool(entries, 4, async (d) => {
    const full = path.join(dir, d.name);
    const r = await fsx.walk(full, null, { deadline: opts.deadline });
    progress(++done / Math.max(1, entries.length), `Medindo ${d.name}…`);
    return { path: full, name: d.name, dir: d.isDirectory(), size: r.bytes, files: r.files, partial: r.partial,
      protected: fsx.protectedPath(full) };
  });
  items.sort((a, b) => b.size - a.size);
  fsx.allow(items.filter((i) => !i.protected).map((i) => i.path));
  const parent = path.dirname(dir);
  const atRoot = parent === dir || !roots.some((r) => isInside(parent, r, process.platform));
  const res = { dir, name: path.basename(dir) || dir, parent: atRoot ? null : parent, items, total: items.reduce((s, i) => s + i.size, 0) };
  cache.set(dir, res);
  return res;
}

async function trash(p) {
  if (fsx.protectedPath(p)) throw new Error('Essa pasta é protegida e não pode ir para a Lixeira.');
  const r = await fsx.trash([p]);
  if (!r.done.length) throw new Error(`Não foi possível: ${(r.failed[0] || {}).reason || 'erro'}.`);
  for (const k of [...cache.keys()]) if (p.startsWith(k) || k.startsWith(p)) cache.delete(k);
  return r;
}

module.exports = { list, trash };
