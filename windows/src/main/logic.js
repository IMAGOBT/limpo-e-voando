'use strict';
// Lógica pura (sem Electron): testável com `node --test`.
const path = require('path');

const nf1 = new Intl.NumberFormat('pt-BR', { maximumFractionDigits: 1 });

/** Bytes em formato legível (base 1000, como o Finder/Explorer em GB "de marketing"). */
function fmtBytes(n) {
  n = Number(n) || 0;
  if (n < 1000) return `${n} B`;
  const units = ['KB', 'MB', 'GB', 'TB'];
  let v = n / 1000, i = 0;
  while (v >= 1000 && i < units.length - 1) { v /= 1000; i++; }
  return `${nf1.format(v)} ${units[i]}`;
}

// ---------- Caminhos protegidos ----------

/** Monta o ambiente de proteção a partir das variáveis do sistema. */
function protectionEnv(platform, env, home, known = []) {
  const P = platform === 'win32' ? path.win32 : path.posix;
  const e = env || {};
  if (platform === 'win32') {
    const sys = e.SystemRoot || e.windir || 'C:\\Windows';
    const drive = P.parse(sys).root || 'C:\\';
    const local = e.LOCALAPPDATA || P.join(home, 'AppData', 'Local');
    const roaming = e.APPDATA || P.join(home, 'AppData', 'Roaming');
    return {
      platform, home,
      subtrees: [sys, e.ProgramFiles || P.join(drive, 'Program Files'), e['ProgramFiles(x86)'] || P.join(drive, 'Program Files (x86)'),
        e.ProgramData || P.join(drive, 'ProgramData'), P.join(drive, '$Recycle.Bin'), P.join(drive, 'System Volume Information'),
        P.join(drive, 'Recovery'), P.join(drive, 'Boot')],
      exact: [home, P.dirname(home), P.join(home, 'AppData'), local, roaming, P.join(home, 'AppData', 'LocalLow'),
        e.OneDrive || P.join(home, 'OneDrive'), ...known],
      roots: [home, ...known],
    };
  }
  return {
    platform, home,
    subtrees: ['/System', '/Library', '/Applications', '/usr', '/bin', '/sbin', '/etc', '/private', '/var', '/opt', '/cores'],
    exact: [home, P.dirname(home), P.join(home, 'Library'), ...known],
    roots: [home, ...known],
  };
}

function norm(p, platform) {
  const P = platform === 'win32' ? path.win32 : path.posix;
  let n = P.resolve(p);
  if (n.length > 1 && n.endsWith(P.sep) && P.parse(n).root !== n) n = n.slice(0, -1);
  return platform === 'win32' ? n.toLowerCase() : n;
}

function isInside(child, parent, platform) {
  const P = platform === 'win32' ? path.win32 : path.posix;
  const c = norm(child, platform), p = norm(parent, platform);
  if (c === p) return true;
  return c.startsWith(p.endsWith(P.sep) ? p : p + P.sep);
}

/** Verdadeiro quando o caminho NÃO pode ir para a Lixeira / ser apagado. */
function isProtected(p, penv) {
  if (!p || typeof p !== 'string') return true;
  const { platform } = penv;
  const P = platform === 'win32' ? path.win32 : path.posix;
  if (!P.isAbsolute(p)) return true;
  const n = norm(p, platform);
  if (P.parse(n).root.toLowerCase() === n) return true;           // raiz do disco
  if (penv.exact.some((x) => x && norm(x, platform) === n)) return true;
  if (penv.subtrees.some((x) => x && isInside(n, x, platform))) return true;
  if (!penv.roots.some((x) => x && isInside(n, x, platform))) return true; // fora do perfil/pastas do usuário
  return false;
}

// ---------- Organizar ----------

const TYPE_GROUPS = [
  ['Imagens', ['jpg', 'jpeg', 'png', 'gif', 'webp', 'heic', 'heif', 'bmp', 'tif', 'tiff', 'svg', 'ico', 'raw', 'cr2', 'nef', 'arw', 'dng', 'psd', 'ai', 'avif']],
  ['Vídeos', ['mp4', 'mov', 'mkv', 'avi', 'wmv', 'webm', 'm4v', 'flv', 'mts', 'm2ts', '3gp', 'mpg', 'mpeg']],
  ['Músicas', ['mp3', 'wav', 'm4a', 'aac', 'flac', 'ogg', 'wma', 'aiff', 'opus']],
  ['PDFs', ['pdf']],
  ['Documentos', ['doc', 'docx', 'txt', 'rtf', 'odt', 'md', 'pages', 'epub']],
  ['Planilhas', ['xls', 'xlsx', 'csv', 'ods', 'numbers']],
  ['Apresentações', ['ppt', 'pptx', 'odp', 'key']],
  ['Compactados', ['zip', 'rar', '7z', 'tar', 'gz', 'bz2', 'xz', 'iso']],
  ['Instaladores', ['exe', 'msi', 'msix', 'appx', 'dmg', 'pkg']],
  ['Código', ['js', 'ts', 'py', 'json', 'html', 'css', 'java', 'c', 'cpp', 'cs', 'go', 'rs', 'php', 'rb', 'sh', 'ps1', 'bat', 'xml', 'yml', 'yaml']],
];
const MONTHS = ['Janeiro', 'Fevereiro', 'Março', 'Abril', 'Maio', 'Junho', 'Julho', 'Agosto', 'Setembro', 'Outubro', 'Novembro', 'Dezembro'];
const IN_PROGRESS = ['crdownload', 'part', 'partial', 'download', 'tmp', 'ytdl', 'opdownload'];

function typeFolder(name) {
  const ext = path.extname(name).slice(1).toLowerCase();
  for (const [folder, exts] of TYPE_GROUPS) if (exts.includes(ext)) return folder;
  return 'Outros';
}

function monthFolder(date) {
  const d = new Date(date);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')} ${MONTHS[d.getMonth()]}`;
}

/** Nome livre: "foto.jpg" → "foto (2).jpg" enquanto `taken(nome)` for verdadeiro. */
function uniqueName(name, taken) {
  if (!taken(name)) return name;
  const ext = path.extname(name), base = name.slice(0, name.length - ext.length);
  for (let i = 2; i < 100000; i++) {
    const n = `${base} (${i})${ext}`;
    if (!taken(n)) return n;
  }
  throw new Error('sem nome livre');
}

/**
 * Plano de organização. files: [{name, mtimeMs}] (só arquivos do topo da pasta).
 * existing: Map pasta → Set de nomes já presentes (em minúsculas).
 */
function planOrganize(files, mode, existing = new Map()) {
  const reserved = new Map();
  const plan = [];
  for (const f of files) {
    if (f.name.startsWith('.') || /^desktop\.ini$/i.test(f.name) || /^thumbs\.db$/i.test(f.name)) continue;
    if (IN_PROGRESS.includes(path.extname(f.name).slice(1).toLowerCase())) continue;
    const folder = mode === 'month' ? monthFolder(f.mtimeMs) : typeFolder(f.name);
    if (!reserved.has(folder)) reserved.set(folder, new Set(existing.get(folder) || []));
    const set = reserved.get(folder);
    const name = uniqueName(f.name, (n) => set.has(n.toLowerCase()));
    set.add(name.toLowerCase());
    plan.push({ name: f.name, folder, target: name, size: f.size || 0 });
  }
  return plan;
}

// ---------- Duplicados ----------

/** Agrupa por tamanho; ignora hard links (mesmo dev+ino). files: [{path,size,dev,ino}] */
function sizeGroups(files) {
  const by = new Map();
  for (const f of files) {
    if (!by.has(f.size)) by.set(f.size, new Map());
    const key = f.ino ? `${f.dev}:${f.ino}` : f.path;
    const m = by.get(f.size);
    if (!m.has(key)) m.set(key, f);
  }
  return [...by.values()].map((m) => [...m.values()]).filter((g) => g.length > 1);
}

/** Confere se o pedido de remoção deixa pelo menos uma cópia em cada grupo. */
function validateDupRemoval(groups, request) {
  const out = [];
  for (const r of request) {
    const g = groups.find((x) => x.id === r.id);
    if (!g) throw new Error('grupo desconhecido');
    const all = new Set(g.files.map((f) => f.path));
    const remove = [...new Set(r.remove)].filter((p) => all.has(p));
    if (remove.length >= all.size) throw new Error('Cada grupo precisa manter pelo menos uma cópia.');
    out.push(...remove);
  }
  return out;
}

// ---------- Aplicativos ----------

/** Separa "C:\x\uninst.exe" /S  ou  C:\Program Files\x\u.exe /S  ou  MsiExec.exe /X{...}. */
function splitCommand(cmd) {
  const s = String(cmd || '').trim();
  if (!s) return null;
  if (s.startsWith('"')) {
    const end = s.indexOf('"', 1);
    if (end < 0) return { file: s.slice(1), args: '' };
    return { file: s.slice(1, end), args: s.slice(end + 1).trim() };
  }
  const m = s.match(/^(.+?\.(?:exe|cmd|bat|com))(?:\s+(.*))?$/i);
  if (m) return { file: m[1], args: (m[2] || '').trim() };
  const sp = s.indexOf(' ');
  return sp < 0 ? { file: s, args: '' } : { file: s.slice(0, sp), args: s.slice(sp + 1).trim() };
}

function normalizeApps(raw) {
  const seen = new Map();
  for (const r of raw || []) {
    const name = (r.DisplayName || '').trim();
    if (!name || Number(r.SystemComponent) === 1 || r.ParentKeyName || /^(Update|Hotfix|Security Update)$/i.test(r.ReleaseType || '')) continue;
    if (/^KB\d{6,}/.test(name)) continue;
    const un = r.QuietUninstallString && !r.UninstallString ? r.QuietUninstallString : r.UninstallString;
    const app = {
      id: `${r.hive}|${r.key}`,
      name, publisher: (r.Publisher || '').trim(), version: (r.DisplayVersion || '').trim(),
      size: Number(r.EstimatedSize) > 0 ? Number(r.EstimatedSize) * 1024 : 0,
      location: r.InstallLocation || '', uninstall: un || '', hive: r.hive,
    };
    const k = `${name.toLowerCase()}|${app.version}`;
    if (!seen.has(k) || (!seen.get(k).uninstall && app.uninstall)) seen.set(k, app);
  }
  return [...seen.values()].sort((a, b) => b.size - a.size || a.name.localeCompare(b.name, 'pt-BR'));
}

// ---------- Processos ----------

const SYSTEM_PROCS = ['system', 'idle', 'registry', 'smss', 'csrss', 'wininit', 'winlogon', 'services', 'lsass', 'lsaiso', 'svchost',
  'dwm', 'fontdrvhost', 'memory compression', 'secure system', 'sihost', 'ctfmon', 'explorer', 'spoolsv', 'msmpeng', 'searchindexer',
  'audiodg', 'conhost', 'runtimebroker', 'taskhostw', 'startmenuexperiencehost', 'shellexperiencehost', 'securityhealthservice',
  'wudfhost', 'dllhost', 'lsm', 'nissrv', 'smartscreen', 'launchd', 'kernel_task', 'windowserver', 'loginwindow'];

/** Agrupa processos pelo nome. procs: [{id,name,mem,cpu}] com cpu em % da máquina. */
function groupProcesses(procs, selfNames = []) {
  const by = new Map();
  for (const p of procs) {
    if (!p || !p.name || p.id <= 4) continue;
    const k = p.name.toLowerCase();
    if (!by.has(k)) by.set(k, { name: p.name, pids: [], mem: 0, cpu: 0 });
    const g = by.get(k);
    g.pids.push(p.id); g.mem += p.mem || 0; g.cpu += p.cpu || 0;
  }
  const self = selfNames.map((s) => s.toLowerCase());
  return [...by.values()].map((g) => ({ ...g, cpu: Math.round(g.cpu * 10) / 10,
    protected: SYSTEM_PROCS.includes(g.name.toLowerCase()) || self.includes(g.name.toLowerCase()) }))
    .sort((a, b) => (b.cpu * 4e8 + b.mem) - (a.cpu * 4e8 + a.mem));
}

// ---------- yt-dlp / ffmpeg ----------

/** Linha "LV <baixados> <total> <estimado> <velocidade> <eta>" do --progress-template. */
function parseYtProgress(line) {
  const m = String(line).trim().match(/^LV\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)/);
  if (!m) return null;
  const num = (x) => (x === 'NA' || x === 'None' ? null : Number(x));
  const done = num(m[1]), total = num(m[2]) || num(m[3]);
  return { done, total, fraction: done != null && total ? Math.min(1, done / total) : null, speed: num(m[4]), eta: num(m[5]) };
}

function needsLogin(text) {
  return /login|log in|sign in|logged|cookies|private|authenticat|rate.?limit|age.?restrict|confirm you.re not a bot|empty media response/i.test(text);
}
function cookieDecryptFailed(text) {
  return /decrypt|dpapi|app.?bound|could not copy .*cookie|permission denied.*cookies|failed to (load|read) cookies/i.test(text);
}

function parseFfDuration(text) {
  const m = String(text).match(/Duration:\s*(\d+):(\d+):(\d+(?:\.\d+)?)/);
  return m ? Number(m[1]) * 3600 + Number(m[2]) * 60 + Number(m[3]) : null;
}
/** Linha "out_time_us=123" ou "out_time_ms=123" (ambos em microssegundos no ffmpeg). */
function parseFfOutTime(line) {
  const m = String(line).match(/^out_time_(?:us|ms)=(\d+)/);
  return m ? Number(m[1]) / 1e6 : null;
}

function siteLabel(url) {
  let h = '';
  try { h = new URL(url).hostname.toLowerCase(); } catch { return 'Vídeo'; }
  if (h.includes('youtu')) return 'Vídeo do YouTube';
  if (h.includes('instagram')) return 'Vídeo do Instagram';
  if (h.includes('pinterest') || h.includes('pin.it')) return 'Vídeo do Pinterest';
  if (h.includes('tiktok')) return 'Vídeo do TikTok';
  return 'Vídeo';
}

module.exports = {
  fmtBytes, protectionEnv, isProtected, isInside, typeFolder, monthFolder, uniqueName, planOrganize,
  sizeGroups, validateDupRemoval, splitCommand, normalizeApps, groupProcesses, SYSTEM_PROCS,
  parseYtProgress, needsLogin, cookieDecryptFailed, parseFfDuration, parseFfOutTime, siteLabel,
};
