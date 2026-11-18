'use strict';
const test = require('node:test');
const assert = require('node:assert');
const L = require('../src/main/logic');

test('fmtBytes', () => {
  assert.strictEqual(L.fmtBytes(512), '512 B');
  assert.strictEqual(L.fmtBytes(1500), '1,5 KB');
  assert.strictEqual(L.fmtBytes(2.25e9), '2,3 GB');
});

test('caminhos protegidos no Windows', () => {
  const home = 'C:\\Users\\ana';
  const env = { SystemRoot: 'C:\\Windows', ProgramFiles: 'C:\\Program Files', 'ProgramFiles(x86)': 'C:\\Program Files (x86)', ProgramData: 'C:\\ProgramData',
    LOCALAPPDATA: `${home}\\AppData\\Local`, APPDATA: `${home}\\AppData\\Roaming` };
  const p = L.protectionEnv('win32', env, home, [`${home}\\Downloads`, 'D:\\Docs']);
  const prot = (x) => L.isProtected(x, p);
  for (const x of ['C:\\', 'C:\\Windows\\Temp\\a.tmp', 'c:\\program files\\App\\x.exe', 'C:\\ProgramData\\x', home, `${home}\\`, `${home}\\AppData`,
    `${home}\\AppData\\Local`, `${home}\\appdata\\roaming`, `${home}\\Downloads`, 'D:\\Docs', 'D:\\Outra\\x.txt', 'C:\\Users', 'relativo\\x', '', null]) {
    assert.ok(prot(x), `deveria proteger ${x}`);
  }
  for (const x of [`${home}\\Downloads\\video.mp4`, `${home}\\AppData\\Local\\Temp\\a.tmp`, 'D:\\Docs\\x.pdf', `${home}\\Videos\\Pasta`]) {
    assert.ok(!prot(x), `não deveria proteger ${x}`);
  }
});

test('caminhos protegidos fora do Windows', () => {
  const p = L.protectionEnv('darwin', {}, '/Users/ana');
  assert.ok(L.isProtected('/Users/ana', p));
  assert.ok(L.isProtected('/System/Library/x', p));
  assert.ok(L.isProtected('/Users/ana/Library', p));
  assert.ok(!L.isProtected('/Users/ana/Downloads/a.zip', p));
});

test('organizar por tipo: nomes únicos, sem sobrescrever', () => {
  const files = [{ name: 'a.JPG', mtimeMs: 0 }, { name: 'b.pdf', mtimeMs: 0 }, { name: 'x.crdownload', mtimeMs: 0 }, { name: 'desktop.ini', mtimeMs: 0 }, { name: 'z.unknown', mtimeMs: 0 }];
  const plan = L.planOrganize(files, 'type', new Map([['Imagens', new Set(['a.jpg'])]]));
  assert.deepStrictEqual(plan.map((p) => [p.name, p.folder, p.target]), [['a.JPG', 'Imagens', 'a (2).JPG'], ['b.pdf', 'PDFs', 'b.pdf'], ['z.unknown', 'Outros', 'z.unknown']]);
});

test('organizar por mês', () => {
  const plan = L.planOrganize([{ name: 'a.txt', mtimeMs: new Date(2026, 10, 3).getTime() }], 'month');
  assert.strictEqual(plan[0].folder, '2026-11 Novembro');
});

test('duplicados: agrupa por tamanho e ignora hard links', () => {
  const g = L.sizeGroups([{ path: 'a', size: 10, dev: 1, ino: 5 }, { path: 'b', size: 10, dev: 1, ino: 5 }, { path: 'c', size: 10, dev: 1, ino: 6 }, { path: 'd', size: 11, dev: 1, ino: 7 }]);
  assert.strictEqual(g.length, 1);
  assert.deepStrictEqual(g[0].map((f) => f.path), ['a', 'c']);
});

test('duplicados: sempre mantém uma cópia', () => {
  const groups = [{ id: 'g0', files: [{ path: 'a' }, { path: 'b' }, { path: 'c' }] }];
  assert.deepStrictEqual(L.validateDupRemoval(groups, [{ id: 'g0', remove: ['b', 'c', 'x'] }]), ['b', 'c']);
  assert.throws(() => L.validateDupRemoval(groups, [{ id: 'g0', remove: ['a', 'b', 'c'] }]));
  assert.throws(() => L.validateDupRemoval(groups, [{ id: 'g9', remove: ['a'] }]));
});

test('desinstalador: separa programa e argumentos', () => {
  assert.deepStrictEqual(L.splitCommand('"C:\\Program Files\\App\\unins000.exe" /SILENT'), { file: 'C:\\Program Files\\App\\unins000.exe', args: '/SILENT' });
  assert.deepStrictEqual(L.splitCommand('MsiExec.exe /X{1234-ABCD}'), { file: 'MsiExec.exe', args: '/X{1234-ABCD}' });
  assert.deepStrictEqual(L.splitCommand('C:\\Program Files\\App\\uninstall.exe --remove'), { file: 'C:\\Program Files\\App\\uninstall.exe', args: '--remove' });
  assert.strictEqual(L.splitCommand(''), null);
});

test('apps: filtra componentes de sistema e atualizações', () => {
  const apps = L.normalizeApps([
    { hive: 'HKLM', key: 'a', DisplayName: 'App A', EstimatedSize: 2048, UninstallString: 'x.exe' },
    { hive: 'HKLM', key: 'b', DisplayName: 'Runtime', SystemComponent: 1 },
    { hive: 'HKLM', key: 'c', DisplayName: 'Update for X', ParentKeyName: 'X' },
    { hive: 'HKCU', key: 'd', DisplayName: 'App B' },
  ]);
  assert.deepStrictEqual(apps.map((a) => [a.name, a.size]), [['App A', 2048 * 1024], ['App B', 0]]);
});

test('processos: agrupa por nome e marca os do sistema', () => {
  const g = L.groupProcesses([{ id: 10, name: 'chrome', mem: 100, cpu: 5 }, { id: 11, name: 'chrome', mem: 50, cpu: 1 }, { id: 12, name: 'svchost', mem: 10, cpu: 0 }, { id: 4, name: 'System', mem: 1, cpu: 0 }]);
  assert.deepStrictEqual(g.map((x) => [x.name, x.pids.length, x.mem, x.protected]), [['chrome', 2, 150, false], ['svchost', 1, 10, true]]);
});

test('yt-dlp: progresso e mensagens de login', () => {
  assert.deepStrictEqual(L.parseYtProgress('LV 500 1000 NA 2048.5 3'), { done: 500, total: 1000, fraction: 0.5, speed: 2048.5, eta: 3 });
  assert.strictEqual(L.parseYtProgress('LV 500 NA 2000 NA NA').fraction, 0.25);
  assert.strictEqual(L.parseYtProgress('[download] nada'), null);
  assert.ok(L.needsLogin('ERROR: [Instagram] abc: Requested content is not available, rate-limit reached or login required'));
  assert.ok(L.cookieDecryptFailed('ERROR: Failed to decrypt with DPAPI'));
  assert.strictEqual(L.siteLabel('https://pin.it/abc'), 'Vídeo do Pinterest');
});

test('ffmpeg: duração e tempo', () => {
  assert.strictEqual(L.parseFfDuration('  Duration: 00:01:02.50, start: 0'), 62.5);
  assert.strictEqual(L.parseFfOutTime('out_time_us=1500000'), 1.5);
});
