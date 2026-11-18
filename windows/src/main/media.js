'use strict';
// 08 — Compressor (ffmpeg) e 09 — Baixar vídeo (yt-dlp). Binários oficiais baixados no primeiro uso.
const fs = require('fs');
const fsp = fs.promises;
const path = require('path');
const os = require('os');
const { spawn, execFile } = require('child_process');
const fsx = require('./fsx');
const L = require('./logic');

const IS_WIN = fsx.IS_WIN;
const BIN = path.join(process.env.LOCALAPPDATA || path.join(os.homedir(), '.local', 'share'), 'LimpoEVoando', 'bin');
const YTDLP_URL = 'https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe';
const FFMPEG_URL = 'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip';
let emit = () => {};
function init(fn) { emit = fn; }

/** Encerra o processo e os filhos (yt-dlp chama o ffmpeg). */
function killTree(p) {
  if (!p || p.exitCode != null) return;
  if (IS_WIN) execFile('taskkill', ['/PID', String(p.pid), '/T', '/F'], { windowsHide: true }, () => {});
  else { try { p.kill(); } catch { /* */ } }
}

// ---------- Ferramentas ----------

function onPath(name) {
  for (const dir of (process.env.PATH || '').split(path.delimiter)) {
    const p = path.join(dir, IS_WIN ? `${name}.exe` : name);
    if (dir && fs.existsSync(p)) return p;
  }
  return null;
}
const ytPath = () => (IS_WIN ? path.join(BIN, 'yt-dlp.exe') : onPath('yt-dlp'));
const ffPath = () => {
  if (!IS_WIN) return onPath('ffmpeg');
  const p = path.join(BIN, 'ffmpeg.exe');
  return fs.existsSync(p) ? p : null;
};

async function download(url, dest, label) {
  const res = await fetch(url, { redirect: 'follow', headers: { 'User-Agent': 'LimpoEVoando' } });
  if (!res.ok || !res.body) throw new Error(`Não consegui baixar ${label} (HTTP ${res.status}).`);
  const total = Number(res.headers.get('content-length')) || 0;
  const tmp = `${dest}.part`;
  const out = fs.createWriteStream(tmp);
  let got = 0;
  for await (const chunk of res.body) {
    got += chunk.length;
    if (!out.write(chunk)) await new Promise((r) => out.once('drain', r));
    if (total) emit('tools', { label, fraction: got / total });
  }
  await new Promise((r, j) => out.end((e) => (e ? j(e) : r())));
  await fsp.rename(tmp, dest);
}

async function ensureYtDlp() {
  if (!IS_WIN) { const p = ytPath(); if (!p) throw new Error('No Windows o app baixa o yt-dlp sozinho. Aqui, instale o yt-dlp no PATH.'); return p; }
  await fsp.mkdir(BIN, { recursive: true });
  const exe = ytPath(), stamp = path.join(BIN, 'yt-dlp.checked');
  if (!fs.existsSync(exe)) {
    await download(YTDLP_URL, exe, 'o motor de download (yt-dlp)');
    await fsp.writeFile(stamp, String(Date.now()));
  } else {
    let checked = 0;
    try { checked = Number(await fsp.readFile(stamp, 'utf8')); } catch { /* */ }
    if (Date.now() - checked > 86400000) {          // no máximo uma vez por dia
      await new Promise((r) => execFile(exe, ['-U'], { windowsHide: true, timeout: 120000 }, () => r()));
      await fsp.writeFile(stamp, String(Date.now()));
    }
  }
  return exe;
}

async function ensureFfmpeg() {
  const have = ffPath();
  if (have) return have;
  if (!IS_WIN) throw new Error('No Windows o app baixa o ffmpeg sozinho. Aqui, instale o ffmpeg no PATH.');
  await fsp.mkdir(BIN, { recursive: true });
  const zip = path.join(BIN, 'ffmpeg.zip'), tmp = path.join(BIN, 'ffmpeg-tmp');
  await download(FFMPEG_URL, zip, 'o ffmpeg');
  await fsp.rm(tmp, { recursive: true, force: true });
  await fsp.mkdir(tmp);
  // tar do Windows 10+ abre .zip
  await new Promise((res, rej) => execFile('tar', ['-xf', zip, '-C', tmp], { windowsHide: true }, (e) => (e ? rej(new Error('Não consegui extrair o ffmpeg.')) : res())));
  let found = null;
  await fsx.walk(tmp, (p) => { const b = path.basename(p).toLowerCase(); if (b === 'ffmpeg.exe' || b === 'ffprobe.exe') { found = found || {}; found[b] = p; } });
  if (!found || !found['ffmpeg.exe']) throw new Error('O pacote do ffmpeg veio sem o ffmpeg.exe.');
  for (const [b, p] of Object.entries(found)) await fsp.copyFile(p, path.join(BIN, b));
  await fsp.rm(tmp, { recursive: true, force: true });
  await fsp.rm(zip, { force: true });
  return path.join(BIN, 'ffmpeg.exe');
}

function toolsStatus() { return { bin: BIN, ytdlp: !!(ytPath() && fs.existsSync(ytPath())), ffmpeg: !!ffPath() }; }

// ---------- Compressor ----------

let compressJob = null;

function uniquePath(p) {
  const dir = path.dirname(p);
  return path.join(dir, L.uniqueName(path.basename(p), (n) => fs.existsSync(path.join(dir, n))));
}

/** opts: { files:[...], codec:'hevc'|'h264'|'mp3', trashOriginal:bool } */
async function compress(opts) {
  if (compressJob) throw new Error('Já tem uma compressão em andamento.');
  const ff = await ensureFfmpeg();
  compressJob = { cancel: false, proc: null };
  const results = [];
  try {
    for (let i = 0; i < opts.files.length; i++) {
      if (compressJob.cancel) break;
      const src = opts.files[i];
      const st = await fsp.stat(src);
      const base = path.join(path.dirname(src), path.parse(src).name);
      const audio = opts.codec === 'mp3';
      const out = uniquePath(audio ? `${base}.mp3` : `${base} (comprimido).mp4`);
      const args = ['-hide_banner', '-y', '-i', src];
      if (audio) args.push('-vn', '-c:a', 'libmp3lame', '-q:a', '2');
      else if (opts.codec === 'h264') args.push('-c:v', 'libx264', '-crf', '23', '-preset', 'medium', '-c:a', 'aac', '-b:a', '160k', '-movflags', '+faststart');
      else args.push('-c:v', 'libx265', '-crf', '26', '-preset', 'medium', '-tag:v', 'hvc1', '-c:a', 'aac', '-b:a', '160k', '-movflags', '+faststart');
      args.push('-progress', 'pipe:1', '-nostats', out);
      emit('compress', { index: i, total: opts.files.length, file: src, fraction: 0, phase: `Comprimindo ${path.basename(src)}…` });
      const code = await new Promise((resolve) => {
        const p = spawn(ff, args, { windowsHide: true });
        compressJob.proc = p;
        let dur = null, err = '';
        p.stderr.on('data', (d) => { err += d; if (err.length > 20000) err = err.slice(-10000); if (dur == null) dur = L.parseFfDuration(err); });
        p.stdout.on('data', (d) => {
          for (const line of String(d).split('\n')) {
            const t = L.parseFfOutTime(line);
            if (t != null && dur) emit('compress', { index: i, total: opts.files.length, file: src, fraction: Math.min(1, t / dur), phase: `Comprimindo ${path.basename(src)}…` });
          }
        });
        p.on('close', (c) => resolve(c));
        p.on('error', () => resolve(-1));
      });
      let outSize = 0;
      try { outSize = (await fsp.stat(out)).size; } catch { /* */ }
      if (code !== 0 || outSize === 0) {
        await fsp.rm(out, { force: true });
        results.push({ file: src, ok: false, error: compressJob.cancel ? 'Cancelado' : 'O ffmpeg não conseguiu converter esse arquivo.' });
        continue;
      }
      let trashed = false;
      if (opts.trashOriginal && !audio && outSize < st.size) {
        fsx.allow([src]);
        trashed = (await fsx.trash([src])).done.length === 1;
      }
      results.push({ file: src, out, ok: true, before: st.size, after: outSize, trashed, bigger: outSize >= st.size });
    }
  } finally { compressJob = null; }
  emit('compress', { done: true });
  return results;
}

function cancelCompress() { if (compressJob) { compressJob.cancel = true; killTree(compressJob.proc); } }

// ---------- Baixar vídeo ----------

const jobs = [];
let running = null, seq = 0;
const outDir = () => path.join(os.homedir(), 'Downloads', 'Limpo e Voando');
const pub = (j) => ({ id: j.id, url: j.url, title: j.title, status: j.status, fraction: j.fraction, detail: j.detail, file: j.file, error: j.error });
const update = (j, patch) => { Object.assign(j, patch); emit('dl', pub(j)); };

function addDownload(url) {
  url = String(url || '').trim();
  if (!/^https?:\/\//i.test(url)) throw new Error('Cole um link que comece com https://');
  const j = { id: ++seq, url, title: L.siteLabel(url), status: 'fila', fraction: 0, detail: 'Na fila', proc: null };
  jobs.push(j);
  emit('dl', pub(j));
  pump();
  return pub(j);
}

function cancelDownload(id) {
  const j = jobs.find((x) => x.id === id);
  if (!j) return;
  if (j.status === 'fila') update(j, { status: 'cancelado', detail: 'Cancelado' });
  else if (j === running) { j.cancelled = true; killTree(j.proc); }
}

async function pump() {
  if (running) return;
  const j = jobs.find((x) => x.status === 'fila');
  if (!j) return;
  running = j;
  try { await runJob(j); } catch (e) { update(j, { status: 'erro', error: e.message, detail: 'Não deu certo' }); }
  running = null;
  pump();
}

function ytArgs(j, ff, browser) {
  const a = ['--no-playlist', '--no-simulate', '--newline', '--progress', '--encoding', 'utf-8',
    '--progress-template', 'download:LV %(progress.downloaded_bytes)s %(progress.total_bytes)s %(progress.total_bytes_estimate)s %(progress.speed)s %(progress.eta)s',
    '--print', 'before_dl:TITLE %(title)s', '--print', 'after_move:FILE %(filepath)s',
    '-o', path.join(outDir(), '%(title).90B [%(id)s].%(ext)s')];
  if (ff) a.push('-f', 'bv*+ba/b', '-S', 'res:2160,fps,hdr:sdr,vcodec:h264', '--merge-output-format', 'mp4', '--ffmpeg-location', path.dirname(ff));
  else a.push('-f', 'b');
  if (browser) a.push('--cookies-from-browser', browser);
  a.push('--', j.url);
  return a;
}

function runYt(j, exe, args) {
  return new Promise((resolve) => {
    const p = spawn(exe, args, { windowsHide: true, env: { ...process.env, PYTHONIOENCODING: 'utf-8', PYTHONUTF8: '1' } });
    j.proc = p;
    let err = '', buf = '', stream = 1, lastF = 0;
    p.stdout.on('data', (d) => {
      buf += d;
      const lines = buf.split(/\r?\n/); buf = lines.pop();
      for (const line of lines) {
        if (line.startsWith('TITLE ')) update(j, { title: line.slice(6).trim() || j.title });
        else if (line.startsWith('FILE ')) j.file = line.slice(5).trim();
        else {
          const pr = L.parseYtProgress(line);
          if (pr && pr.fraction != null) {
            if (pr.fraction < lastF - 0.5) stream++;
            lastF = pr.fraction;
            const speed = pr.speed ? `${L.fmtBytes(pr.speed)}/s` : '';
            const eta = pr.eta != null ? ` · falta ${Math.max(0, Math.round(pr.eta))} s` : '';
            update(j, { fraction: pr.fraction, detail: `${stream > 1 ? 'Baixando áudio' : 'Baixando vídeo'} ${speed}${eta}` });
          }
        }
      }
    });
    p.stderr.on('data', (d) => { err += d; if (err.length > 20000) err = err.slice(-10000); });
    p.on('close', (code) => resolve({ code, err }));
    p.on('error', (e) => resolve({ code: -1, err: e.message }));
  });
}

async function runJob(j) {
  update(j, { status: 'baixando', detail: fs.existsSync(ytPath() || '') ? 'Preparando…' : 'Instalando o motor de download (só na primeira vez)…' });
  const exe = await ensureYtDlp();
  let ff = null;
  try { update(j, { detail: ffPath() ? 'Preparando…' : 'Instalando o ffmpeg (só na primeira vez)…' }); ff = await ensureFfmpeg(); } catch { ff = null; }
  await fsp.mkdir(outDir(), { recursive: true });
  const browsers = [null, 'firefox', 'edge', 'chrome'];
  let last = null, decryptFail = false;
  for (const b of browsers) {
    if (j.cancelled) break;
    if (b) update(j, { detail: `Conectando com o login do ${b[0].toUpperCase() + b.slice(1)}…`, fraction: 0 });
    last = await runYt(j, exe, ytArgs(j, ff, b));
    if (last.code === 0) break;
    if (b && L.cookieDecryptFailed(last.err)) decryptFail = true;
    if (!b && !L.needsLogin(last.err)) break;            // erro que não é de login: não insiste
  }
  if (j.cancelled) { update(j, { status: 'cancelado', detail: 'Cancelado' }); return; }
  if (last.code === 0) { update(j, { status: 'pronto', fraction: 1, detail: ff ? 'Pronto' : 'Pronto (qualidade limitada: sem ffmpeg)' }); return; }
  let msg = (last.err.split('\n').reverse().find((l) => /ERROR/.test(l)) || 'O download falhou.').replace(/^ERROR:\s*/, '').slice(0, 220);
  if (L.needsLogin(last.err)) {
    msg = decryptFail
      ? 'O site pediu login e o Windows bloqueou a leitura dos cookies do Chrome/Edge. Entre no site pelo Firefox neste PC e tente de novo.'
      : 'O site pediu login. Entre no site pelo Firefox (recomendado), Edge ou Chrome neste PC e tente de novo.';
  }
  update(j, { status: 'erro', error: msg, detail: 'Não deu certo' });
}

function downloads() { return { dir: outDir(), jobs: jobs.map(pub) }; }

module.exports = { init, toolsStatus, ensureFfmpeg, ensureYtDlp, compress, cancelCompress, addDownload, cancelDownload, downloads, BIN };
