'use strict';
// 02 — Limpeza: temporários, caches de navegador, miniaturas, despejos, caches de dev, instaladores antigos e Lixeira.
const fs = require('fs');
const path = require('path');
const os = require('os');
const fsx = require('./fsx');
const { psJson, powershell } = require('./win');

const DAY = 86400000;
let last = new Map();        // id → { cat, files:[{path,size}] }

function browserCacheDirs(L) {
  const out = [];
  const chromium = [['Chrome', 'Google\\Chrome\\User Data'], ['Edge', 'Microsoft\\Edge\\User Data'], ['Brave', 'BraveSoftware\\Brave-Browser\\User Data']];
  for (const [name, rel] of chromium) {
    const base = path.join(L, rel);
    let profiles = [];
    try { profiles = fs.readdirSync(base, { withFileTypes: true }).filter((d) => d.isDirectory() && !d.isSymbolicLink()).map((d) => d.name); } catch { continue; }
    for (const top of ['GrShaderCache', 'ShaderCache', 'GraphiteDawnCache']) if (profiles.includes(top)) out.push({ path: path.join(base, top), label: `${name} · ${top}` });
    for (const prof of profiles) {
      if (!(prof === 'Default' || /^Profile \d+$/.test(prof) || prof === 'Guest Profile')) continue;
      for (const c of ['Cache', 'Code Cache', 'GPUCache']) {
        const p = path.join(base, prof, c);
        if (fs.existsSync(p)) out.push({ path: p, label: `${name} · ${prof === 'Default' ? 'Perfil principal' : prof} · ${c}` });
      }
    }
  }
  const ff = path.join(L, 'Mozilla', 'Firefox', 'Profiles');
  try {
    for (const d of fs.readdirSync(ff, { withFileTypes: true })) {
      const p = path.join(ff, d.name, 'cache2');
      if (d.isDirectory() && fs.existsSync(p)) out.push({ path: p, label: `Firefox · ${d.name.replace(/^[^.]+\./, '')} · cache2` });
    }
  } catch { /* sem Firefox */ }
  return out;
}

/** Categorias. Fora do Windows: lista vazia de pastas (nada para limpar). */
function categories() {
  const win = fsx.IS_WIN;
  const L = process.env.LOCALAPPDATA || path.join(os.homedir(), 'AppData', 'Local');
  const R = process.env.APPDATA || path.join(os.homedir(), 'AppData', 'Roaming');
  const dl = (fsx.userFolders().find((f) => f.key === 'downloads') || {}).path;
  const r = (p, label) => ({ path: p, label: label || path.basename(p) });
  return [
    { id: 'temp', title: 'Arquivos temporários', icon: 'clock', pre: true, mode: 'delete', itemsBy: 'child', minAge: DAY,
      desc: 'A pasta %TEMP% do seu usuário. Só o que tem mais de 1 dia.', roots: win ? [r(os.tmpdir(), 'Temp')] : [] },
    { id: 'browsers', title: 'Cache dos navegadores', icon: 'globe', pre: true, mode: 'delete', itemsBy: 'root',
      desc: 'Chrome, Edge, Brave e Firefox. Só o cache: perfis, senhas, cookies e histórico ficam intactos.', roots: win ? browserCacheDirs(L) : [] },
    { id: 'thumbs', title: 'Miniaturas do Explorer', icon: 'image', pre: true, mode: 'delete', itemsBy: 'file', maxDepth: 0, match: /^thumbcache_.*\.db$/i,
      desc: 'O Windows recria as miniaturas quando precisar. Arquivos em uso são pulados.', roots: win ? [r(path.join(L, 'Microsoft', 'Windows', 'Explorer'), 'Explorer')] : [] },
    { id: 'dumps', title: 'Relatórios de falhas', icon: 'alert', pre: true, mode: 'delete', itemsBy: 'file',
      desc: 'Despejos de memória de apps que travaram (CrashDumps).', roots: win ? [r(path.join(L, 'CrashDumps'), 'CrashDumps')] : [] },
    { id: 'dev', title: 'Caches de desenvolvimento', icon: 'code', pre: false, mode: 'delete', itemsBy: 'root',
      desc: 'npm, pip e Yarn. Eles baixam de novo o que faltar.',
      roots: win ? [r(path.join(L, 'npm-cache'), 'npm'), r(path.join(R, 'npm-cache'), 'npm (antigo)'), r(path.join(L, 'pip', 'Cache'), 'pip'), r(path.join(L, 'Yarn', 'Cache'), 'Yarn')] : [] },
    { id: 'installers', title: 'Instaladores antigos em Downloads', icon: 'package', pre: false, mode: 'trash', itemsBy: 'file', maxDepth: 0,
      match: /\.(exe|msi)$/i, minAge: 30 * DAY,
      desc: 'Arquivos .exe e .msi com mais de 30 dias. Vão para a Lixeira, confira antes.', roots: win && dl ? [r(dl, 'Downloads')] : [] },
  ];
}

async function scan(progress = () => {}, opts = {}) {
  const cats = categories();
  const now = Date.now();
  last = new Map();
  const out = [];
  for (let ci = 0; ci < cats.length; ci++) {
    const cat = cats[ci];
    progress(ci / cats.length, `Analisando ${cat.title.toLowerCase()}…`);
    const files = [], items = new Map();
    for (const root of cat.roots) {
      if (fsx.protectedPath(path.join(root.path, 'x'))) continue;
      await fsx.walk(root.path, (p, st) => {
        if (cat.match && !cat.match.test(path.basename(p))) return;
        if (cat.minAge && now - st.mtimeMs < cat.minAge) return;
        files.push({ path: p, size: st.size });
        const k = cat.itemsBy === 'root' ? root.path : cat.itemsBy === 'file' ? p : path.join(root.path, path.relative(root.path, p).split(path.sep)[0]);
        const label = cat.itemsBy === 'root' ? root.label : path.basename(k);
        const it = items.get(k) || { path: k, label, size: 0, count: 0 };
        it.size += st.size; it.count++; items.set(k, it);
      }, { maxDepth: cat.maxDepth, deadline: opts.deadline });
    }
    if (cat.mode === 'trash') fsx.allow(files.map((f) => f.path));
    last.set(cat.id, { cat, files });
    const list = [...items.values()].sort((a, b) => b.size - a.size);
    out.push({ id: cat.id, title: cat.title, desc: cat.desc, icon: cat.icon, pre: cat.pre, mode: cat.mode,
      size: files.reduce((s, f) => s + f.size, 0), count: files.length, items: list.slice(0, 60), more: Math.max(0, list.length - 60) });
  }
  progress(1, 'Pronto');
  return out;
}

async function clean(ids, progress = () => {}) {
  const before = await fsx.diskFree();
  let removed = 0, bytes = 0, skipped = 0;
  const chosen = ids.map((id) => last.get(id)).filter(Boolean);
  const total = chosen.reduce((s, c) => s + c.files.length, 0) || 1;
  let n = 0;
  for (const { cat, files } of chosen) {
    if (cat.mode === 'trash') {
      const r = await fsx.trash(files.map((f) => f.path));
      removed += r.done.length; bytes += r.done.reduce((s, f) => s + f.size, 0); skipped += r.failed.length;
      n += files.length;
    } else {
      for (const f of files) {
        const r = await fsx.removeFile(f.path);
        if (r.ok) { removed++; bytes += r.size; } else skipped++;
        if (++n % 200 === 0) progress(n / total, `Limpando ${cat.title.toLowerCase()}…`);
      }
      for (const root of cat.roots) await fsx.pruneEmpty(root.path);
    }
    last.delete(cat.id);
  }
  const after = await fsx.diskFree();
  progress(1, 'Pronto');
  return { removed, bytes, skipped, real: Math.max(0, after.free - before.free) };
}

// ---------- Lixeira ----------

const RB_SCRIPT = `
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value; [int64]$t=0; $n=0
foreach($d in [IO.DriveInfo]::GetDrives()){ if($d.DriveType -ne 'Fixed' -or -not $d.IsReady){continue}
  $p=Join-Path $d.RootDirectory.FullName ('$Recycle.Bin\\'+$sid)
  if(Test-Path -LiteralPath $p){
    Get-ChildItem -LiteralPath $p -Force -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object { if($_.Name -notlike '$I*'){ $t+=$_.Length } }
    $n+=@(Get-ChildItem -LiteralPath $p -Force -Filter '$R*' -ErrorAction SilentlyContinue).Count } }
[pscustomobject]@{size=$t;count=$n} | ConvertTo-Json -Compress`;

async function recycleInfo() {
  if (!fsx.IS_WIN) return { supported: false, size: 0, count: 0 };
  const [r] = await psJson(RB_SCRIPT);
  return { supported: true, size: Number(r.size) || 0, count: Number(r.count) || 0 };
}

async function emptyRecycle() {
  if (!fsx.IS_WIN) return { real: 0 };
  const before = await fsx.diskFree();
  await powershell('Clear-RecycleBin -Force -ErrorAction SilentlyContinue', null, 120000);
  const after = await fsx.diskFree();
  return { real: Math.max(0, after.free - before.free) };
}

module.exports = { scan, clean, recycleInfo, emptyRecycle, categories };
