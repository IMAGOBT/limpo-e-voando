'use strict';
// Utilitários de disco: varredura segura (lstat, sem links/junções), exclusão tolerante e Lixeira.
const fs = require('fs');
const fsp = fs.promises;
const path = require('path');
const os = require('os');
const { protectionEnv, isProtected } = require('./logic');

const IS_WIN = process.platform === 'win32';
// Só no macOS (desenvolvimento): ~/Library tem montagens de nuvem e pastas protegidas que podem travar a leitura.
const MAC_LIBRARY = process.platform === 'darwin' ? path.join(os.homedir(), 'Library') : null;
const skipAlways = (p) => MAC_LIBRARY !== null && p === MAC_LIBRARY;
const SKIP_CODES = new Set(['EPERM', 'EBUSY', 'EACCES', 'ENOENT', 'ENOTDIR', 'ELOOP', 'EINVAL', 'UNKNOWN', 'EISDIR', 'ENOTEMPTY']);

let electronApp = null, electronShell = null;
let penv = protectionEnv(process.platform, process.env, os.homedir());
const allowed = new Set();                  // caminhos que algum scanner mostrou ao usuário

function init({ app, shell }) {
  electronApp = app; electronShell = shell;
  penv = protectionEnv(process.platform, process.env, os.homedir(), knownFolders());
}

function knownFolders() {
  if (!electronApp) return [];
  const out = [];
  for (const k of ['desktop', 'documents', 'downloads', 'music', 'pictures', 'videos']) {
    try { out.push(electronApp.getPath(k)); } catch { /* pasta ausente */ }
  }
  return [...new Set(out)];
}

/** Pastas do usuário que existem, com rótulo PT-BR. */
function userFolders() {
  const labels = { desktop: 'Área de Trabalho', documents: 'Documentos', downloads: 'Downloads', music: 'Músicas', pictures: 'Imagens', videos: 'Vídeos' };
  const out = [];
  for (const [k, label] of Object.entries(labels)) {
    let p = null;
    try { p = electronApp ? electronApp.getPath(k) : path.join(os.homedir(), k[0].toUpperCase() + k.slice(1)); } catch { /* */ }
    if (p && fs.existsSync(p) && !out.some((x) => x.path === p)) out.push({ key: k, label, path: p });
  }
  return out;
}

const key = (p) => (IS_WIN ? path.resolve(p).toLowerCase() : path.resolve(p));
function allow(paths) { for (const p of paths) allowed.add(key(p)); }
function protectedPath(p) { return isProtected(p, penv); }

/**
 * Percorre `root` sem seguir links simbólicos nem junções. onFile(path, stat) por arquivo.
 * opts: { maxDepth, skipDir(name, full), deadline (ms epoch), signal: {aborted} }
 * Retorna { files, bytes, skipped, partial }.
 */
async function walk(root, onFile, opts = {}) {
  const res = { files: 0, bytes: 0, skipped: 0, partial: false };
  if (skipAlways(root)) return res;
  let rootSt;
  try { rootSt = await fsp.lstat(root); } catch { return res; }
  if (rootSt.isSymbolicLink()) return res;
  if (rootSt.isFile()) { res.files = 1; res.bytes = rootSt.size; if (onFile) await onFile(root, rootSt); return res; }
  if (!rootSt.isDirectory()) return res;
  const stack = [[root, 0]];
  while (stack.length) {
    if ((opts.deadline && Date.now() > opts.deadline) || (opts.signal && opts.signal.aborted)) { res.partial = true; break; }
    const [dir, depth] = stack.pop();
    let entries;
    try { entries = await fsp.readdir(dir, { withFileTypes: true }); } catch { res.skipped++; continue; }
    for (let i = 0; i < entries.length; i += 64) {
      await Promise.all(entries.slice(i, i + 64).map(async (d) => {
        const full = path.join(dir, d.name);
        if (d.isSymbolicLink()) return;                       // links e junções: nunca segue
        if (d.isDirectory()) {
          if (skipAlways(full)) return;
          if (opts.skipDir && opts.skipDir(d.name, full)) return;
          if (opts.maxDepth == null || depth + 1 <= opts.maxDepth) stack.push([full, depth + 1]);
          return;
        }
        let st;
        try { st = await fsp.lstat(full); } catch { res.skipped++; return; }
        if (st.isSymbolicLink() || !st.isFile()) return;
        res.files++; res.bytes += st.size;
        if (onFile) await onFile(full, st);
      }));
    }
  }
  return res;
}

/** Apaga um arquivo de cache/temporário. Em uso, sem permissão ou sumiu → conta como pulado. */
async function removeFile(p) {
  if (protectedPath(p)) return { ok: false, protected: true };
  try {
    const st = await fsp.lstat(p);
    if (!st.isFile()) return { ok: false };
    await fsp.unlink(p);
    return { ok: true, size: st.size };
  } catch (e) {
    if (SKIP_CODES.has(e.code)) return { ok: false, skipped: true };
    return { ok: false, skipped: true, error: e.message };
  }
}

/** Remove pastas vazias abaixo de root (nunca o próprio root). */
async function pruneEmpty(root) {
  async function rec(dir) {
    let entries;
    try { entries = await fsp.readdir(dir, { withFileTypes: true }); } catch { return false; }
    let empty = true;
    for (const d of entries) {
      if (d.isDirectory() && !d.isSymbolicLink()) { if (!(await rec(path.join(dir, d.name)))) empty = false; }
      else empty = false;
    }
    if (empty && dir !== root) { try { await fsp.rmdir(dir); } catch { return false; } }
    return empty;
  }
  await rec(root);
}

/** Envia para a Lixeira. Só caminhos mostrados por um scanner e fora das áreas protegidas. */
async function trash(paths) {
  const done = [], failed = [];
  for (const p of paths) {
    if (typeof p !== 'string' || !allowed.has(key(p)) || protectedPath(p)) { failed.push({ path: p, reason: 'protegido' }); continue; }
    try {
      const st = await fsp.lstat(p);
      await electronShell.trashItem(p);
      done.push({ path: p, size: st.isFile() ? st.size : 0 });
      allowed.delete(key(p));
    } catch (e) { failed.push({ path: p, reason: e.code === 'ENOENT' ? 'não existe mais' : 'em uso ou sem permissão' }); }
  }
  return { done, failed };
}

/** Espaço livre do disco do perfil (bytes). */
async function diskFree(p = os.homedir()) {
  try {
    const s = await fsp.statfs(p);
    return { free: s.bavail * s.bsize, total: s.blocks * s.bsize };
  } catch { return { free: 0, total: 0 }; }
}

/** Roda fn em itens com no máximo `n` ao mesmo tempo. */
async function pool(items, n, fn) {
  const out = new Array(items.length);
  let i = 0;
  await Promise.all(Array.from({ length: Math.min(n, items.length) }, async () => {
    while (i < items.length) { const k = i++; out[k] = await fn(items[k], k); }
  }));
  return out;
}

async function exists(p) { try { await fsp.lstat(p); return true; } catch { return false; } }

module.exports = { IS_WIN, init, userFolders, allow, protectedPath, walk, removeFile, pruneEmpty, trash, diskFree, pool, exists, penv: () => penv };
