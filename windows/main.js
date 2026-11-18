'use strict';
// Limpo e Voando para Windows — processo principal. Todo acesso a disco e processos fica aqui.
const { app, BrowserWindow, ipcMain, shell, dialog, nativeTheme } = require('electron');
const path = require('path');
const fs = require('fs');
const os = require('os');
const fsx = require('./src/main/fsx');
const cleanup = require('./src/main/cleanup');
const clutter = require('./src/main/clutter');
const perf = require('./src/main/perf');
const apps = require('./src/main/apps');
const lens = require('./src/main/lens');
const organize = require('./src/main/organize');
const media = require('./src/main/media');
const { isInside } = require('./src/main/logic');

const SMOKE = process.argv.includes('--smoke');
if (SMOKE) app.disableHardwareAcceleration();
let win = null;

const settingsFile = () => path.join(app.getPath('userData'), 'ajustes.json');
function readSettings() { try { return JSON.parse(fs.readFileSync(settingsFile(), 'utf8')); } catch { return {}; } }
function writeSettings(s) { try { fs.mkdirSync(path.dirname(settingsFile()), { recursive: true }); fs.writeFileSync(settingsFile(), JSON.stringify(s)); } catch { /* */ } }

const send = (channel, data) => { for (const w of BrowserWindow.getAllWindows()) if (!w.isDestroyed()) w.webContents.send(channel, data); };
const prog = (task) => (value, phase) => send('progress', { task, value, phase });
const num = (v, d, min, max) => (Number.isFinite(Number(v)) ? Math.min(max, Math.max(min, Number(v))) : d);

function userPath(p) {
  if (typeof p !== 'string' || !path.isAbsolute(p)) throw new Error('caminho inválido');
  if (!fsx.penv().roots.some((r) => isInside(p, r, process.platform))) throw new Error('Fora das pastas do usuário.');
  return p;
}

/** API exposta ao renderer (cada nome também precisa estar na lista do preload). */
const api = {
  'info': () => ({ platform: process.platform, isWindows: fsx.IS_WIN, home: os.homedir(), version: app.getVersion(),
    folders: fsx.userFolders(), smoke: SMOKE }),
  'disk.free': () => fsx.diskFree(),
  'cleanup.scan': () => cleanup.scan(prog('cleanup')),
  'cleanup.clean': (ids) => cleanup.clean(Array.isArray(ids) ? ids.map(String) : [], prog('cleanup')),
  'recycle.info': () => cleanup.recycleInfo(),
  'recycle.empty': () => cleanup.emptyRecycle(),
  'clutter.large': () => clutter.large(prog('large')),
  'clutter.dups': (o = {}) => clutter.duplicates(prog('dups'), { minSize: num(o.minSize, 1e6, 1, 1e12), deadline: o.seconds ? Date.now() + num(o.seconds, 120, 5, 3600) * 1000 : undefined }),
  'clutter.trashDups': (req) => clutter.trashDuplicates(Array.isArray(req) ? req : []),
  'files.trash': async (paths) => {
    const before = await fsx.diskFree();
    const r = await fsx.trash(Array.isArray(paths) ? paths : []);
    return { ...r, real: Math.max(0, (await fsx.diskFree()).free - before.free) };
  },
  'perf.sample': () => perf.sample(),
  'perf.processes': () => perf.processes(),
  'perf.kill': (name, force) => perf.kill(String(name), !!force),
  'startup.list': () => perf.startupList(),
  'startup.toggle': (id, enable) => perf.startupToggle(String(id), !!enable),
  'lens.list': (dir, fresh) => lens.list(dir || os.homedir(), prog('lens'), { fresh: !!fresh }),
  'lens.trash': (p) => lens.trash(userPath(p)),
  'apps.list': () => apps.list(),
  'apps.uninstall': (id) => apps.uninstall(String(id)),
  'org.preview': (dir, mode) => organize.preview(userPath(dir), mode === 'month' ? 'month' : 'type'),
  'org.apply': () => organize.apply(prog('organize')),
  'org.undo': () => organize.undo(),
  'org.last': () => organize.lastRun(),
  'compress.run': (o = {}) => media.compress({ files: (o.files || []).map(userPath), codec: ['hevc', 'h264', 'mp3'].includes(o.codec) ? o.codec : 'hevc', trashOriginal: !!o.trashOriginal }),
  'compress.cancel': () => media.cancelCompress(),
  'dl.add': (url) => media.addDownload(url),
  'dl.cancel': (id) => media.cancelDownload(Number(id)),
  'dl.list': () => media.downloads(),
  'tools.status': () => media.toolsStatus(),
  'shell.show': (p) => shell.showItemInFolder(userPath(p)),
  'shell.open': (p) => shell.openPath(userPath(p)),
  'dialog.folder': async (def) => {
    const r = await dialog.showOpenDialog(win, { defaultPath: def || app.getPath('downloads'), properties: ['openDirectory'] });
    return r.canceled ? null : r.filePaths[0];
  },
  'dialog.media': async (kind) => {
    const filters = kind === 'audio'
      ? [{ name: 'Áudio e vídeo', extensions: ['wav', 'flac', 'm4a', 'aac', 'ogg', 'wma', 'aiff', 'opus', 'mp4', 'mov', 'mkv', 'webm'] }]
      : [{ name: 'Vídeos', extensions: ['mp4', 'mov', 'mkv', 'avi', 'wmv', 'webm', 'm4v', 'mts', 'm2ts', '3gp'] }];
    const r = await dialog.showOpenDialog(win, { defaultPath: app.getPath('videos'), properties: ['openFile', 'multiSelections'], filters });
    return r.canceled ? [] : r.filePaths;
  },
  'theme.get': () => readSettings().theme || 'system',
  'theme.set': (mode) => {
    const m = ['system', 'light', 'dark'].includes(mode) ? mode : 'system';
    nativeTheme.themeSource = m;
    writeSettings({ ...readSettings(), theme: m });
    if (win) win.setBackgroundColor(nativeTheme.shouldUseDarkColors ? '#0f0f10' : '#f6f6f7');
    return m;
  },
};

for (const [name, fn] of Object.entries(api)) {
  ipcMain.handle(`lv:${name}`, async (_e, ...args) => {
    try { return { ok: true, data: await fn(...args) }; } catch (e) { return { ok: false, error: e && e.message ? e.message : String(e) }; }
  });
}

function createWindow({ show = true } = {}) {
  nativeTheme.themeSource = readSettings().theme || 'system';
  const w = new BrowserWindow({
    width: 1180, height: 780, minWidth: 980, minHeight: 640, show: false, title: 'Limpo e Voando',
    backgroundColor: nativeTheme.shouldUseDarkColors ? '#0f0f10' : '#f6f6f7', autoHideMenuBar: true,
    icon: path.join(__dirname, 'build', 'icon.png'),
    webPreferences: { preload: path.join(__dirname, 'preload.js'), contextIsolation: true, nodeIntegration: false, sandbox: true, spellcheck: false, backgroundThrottling: !SMOKE },
  });
  w.removeMenu();
  w.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  w.webContents.on('will-navigate', (e) => e.preventDefault());
  if (show) w.once('ready-to-show', () => w.show());
  w.loadFile(path.join(__dirname, 'src', 'renderer', 'index.html'));
  return w;
}

if (!SMOKE && !app.requestSingleInstanceLock()) app.quit();
app.on('second-instance', () => { if (win) { if (win.isMinimized()) win.restore(); win.focus(); } });

app.whenReady().then(async () => {
  fsx.init({ app, shell });
  organize.init(app.getPath('userData'));
  media.init(send);
  if (SMOKE) {
    const code = await require('./src/main/smoke').run({ createWindow, api });
    app.exit(code);
    return;
  }
  win = createWindow();
  win.on('closed', () => { win = null; });
});

app.on('window-all-closed', () => { if (!SMOKE) app.quit(); });
