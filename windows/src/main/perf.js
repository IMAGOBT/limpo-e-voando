'use strict';
// 04 — Desempenho: CPU/RAM ao vivo, processos pesados e itens de inicialização (reversíveis).
const fs = require('fs');
const fsp = fs.promises;
const path = require('path');
const os = require('os');
const { execFile } = require('child_process');
const fsx = require('./fsx');
const { psJson, powershell } = require('./win');
const { groupProcesses, uniqueName } = require('./logic');

let prevCpu = null;
function cpuTimes() {
  return os.cpus().reduce((a, c) => {
    const t = c.times;
    a.idle += t.idle; a.total += t.user + t.nice + t.sys + t.idle + t.irq;
    return a;
  }, { idle: 0, total: 0 });
}

async function sample() {
  const now = cpuTimes();
  let cpu = 0;
  if (prevCpu) {
    const dt = now.total - prevCpu.total, di = now.idle - prevCpu.idle;
    cpu = dt > 0 ? Math.max(0, Math.min(1, 1 - di / dt)) : 0;
  }
  prevCpu = now;
  const total = os.totalmem(), free = os.freemem();
  const disk = await fsx.diskFree();
  return { cpu, memUsed: total - free, memTotal: total, cores: os.cpus().length, model: (os.cpus()[0] || {}).model || '', disk, uptime: os.uptime() };
}

// ---------- Processos ----------

const PROC_SCRIPT = `
$a=@{}; Get-Process | ForEach-Object { try { $a[$_.Id]=$_.TotalProcessorTime.TotalMilliseconds } catch {} }
Start-Sleep -Milliseconds 1000
Get-Process | ForEach-Object { $c=0; try { if($a.ContainsKey($_.Id)){ $c=$_.TotalProcessorTime.TotalMilliseconds-$a[$_.Id] } } catch {}
  [pscustomobject]@{ id=$_.Id; name=$_.ProcessName; mem=[int64]$_.WorkingSet64; cpu=$c } } | ConvertTo-Json -Compress`;

let lastGroups = [];
const selfNames = () => [path.parse(process.execPath).name, 'electron', 'Limpo e Voando'];

async function processes() {
  let raw = [];
  const cores = os.cpus().length || 1;
  if (fsx.IS_WIN) {
    raw = (await psJson(PROC_SCRIPT, null, 30000)).map((p) => ({ id: p.id, name: p.name, mem: Number(p.mem) || 0, cpu: (Number(p.cpu) || 0) / 10 / cores }));
  } else {
    const out = await new Promise((res) => execFile('ps', ['-axo', 'pid=,pcpu=,rss=,comm='], { maxBuffer: 1 << 24 }, (e, o) => res(e ? '' : o)));
    raw = out.split('\n').map((l) => l.trim().match(/^(\d+)\s+([\d.]+)\s+(\d+)\s+(.+)$/)).filter(Boolean)
      .map((m) => ({ id: Number(m[1]), cpu: Number(m[2]) / cores, mem: Number(m[3]) * 1024, name: path.basename(m[4]) }));
  }
  const mine = new Set([process.pid, process.ppid]);
  lastGroups = groupProcesses(raw.filter((p) => !mine.has(p.id)), selfNames()).slice(0, 40);
  return lastGroups;
}

function alive(pid) { try { process.kill(pid, 0); return true; } catch { return false; } }

/** Encerra um app pelo nome (pids vêm da última leitura no processo principal, nunca da tela). */
async function kill(name, force = false) {
  const g = lastGroups.find((x) => x.name === name);
  if (!g || g.protected) throw new Error('Esse processo é do sistema e não pode ser encerrado.');
  if (fsx.IS_WIN && !force) {
    await new Promise((res) => execFile('taskkill', g.pids.flatMap((p) => ['/PID', String(p)]), { windowsHide: true }, () => res()));
    await new Promise((r) => setTimeout(r, 2500));
  } else {
    for (const pid of g.pids) { try { process.kill(pid, force ? 'SIGKILL' : 'SIGTERM'); } catch { /* já saiu */ } }
    await new Promise((r) => setTimeout(r, 800));
  }
  const left = g.pids.filter(alive);
  return { closed: g.pids.length - left.length, left: left.length };
}

// ---------- Inicialização ----------

const RUN = 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Run';
const BACKUP = 'HKCU:\\Software\\LimpoEVoando\\DisabledRun';
const startupDir = () => path.join(process.env.APPDATA || '', 'Microsoft', 'Windows', 'Start Menu', 'Programs', 'Startup');
const disabledDir = () => path.join(process.env.LOCALAPPDATA || os.tmpdir(), 'LimpoEVoando', 'DisabledStartup');

const LIST_SCRIPT = `
$out=@()
foreach($pair in @(@($in.run,$true),@($in.backup,$false))){
  $k=Get-Item -LiteralPath $pair[0] -ErrorAction SilentlyContinue
  if($k){ foreach($n in $k.GetValueNames()){ if($n -eq ''){continue}
    $out+=[pscustomobject]@{ name=$n; command=[string]$k.GetValue($n,$null,'DoNotExpandEnvironmentNames'); enabled=$pair[1] } } } }
ConvertTo-Json -InputObject @($out) -Compress`;

const MOVE_SCRIPT = `
$src=Get-Item -LiteralPath $in.from -ErrorAction Stop
$kind=$src.GetValueKind($in.name); $val=$src.GetValue($in.name,$null,'DoNotExpandEnvironmentNames')
if(-not (Test-Path -LiteralPath $in.to)){ New-Item -Path $in.to -Force | Out-Null }
New-ItemProperty -LiteralPath $in.to -Name $in.name -Value $val -PropertyType $kind -Force | Out-Null
Remove-ItemProperty -LiteralPath $in.from -Name $in.name -ErrorAction Stop`;

async function startupList() {
  if (!fsx.IS_WIN) return [];
  const reg = (await psJson(LIST_SCRIPT, { run: RUN, backup: BACKUP })).flat().filter(Boolean)
    .map((r) => ({ id: `reg:${r.name}`, name: r.name, command: r.command, enabled: !!r.enabled, kind: 'Registro (Run)' }));
  const files = [];
  for (const [dir, enabled] of [[startupDir(), true], [disabledDir(), false]]) {
    let list = [];
    try { list = await fsp.readdir(dir, { withFileTypes: true }); } catch { continue; }
    for (const d of list) {
      if (!d.isFile() || /^desktop\.ini$/i.test(d.name)) continue;
      files.push({ id: `file:${d.name}`, name: d.name.replace(/\.lnk$/i, ''), command: path.join(dir, d.name), enabled, kind: 'Pasta Inicializar' });
    }
  }
  return [...reg, ...files].sort((a, b) => a.name.localeCompare(b.name, 'pt-BR'));
}

async function startupToggle(id, enable) {
  if (!fsx.IS_WIN) throw new Error('Disponível só no Windows.');
  if (id.startsWith('reg:')) {
    const name = id.slice(4);
    await powershell(MOVE_SCRIPT, { name, from: enable ? BACKUP : RUN, to: enable ? RUN : BACKUP });
  } else if (id.startsWith('file:')) {
    const name = path.basename(id.slice(5));
    const [from, to] = enable ? [disabledDir(), startupDir()] : [startupDir(), disabledDir()];
    await fsp.mkdir(to, { recursive: true });
    const taken = new Set((await fsp.readdir(to)).map((n) => n.toLowerCase()));
    await fsp.rename(path.join(from, name), path.join(to, uniqueName(name, (n) => taken.has(n.toLowerCase()))));
  } else throw new Error('item desconhecido');
  return startupList();
}

module.exports = { sample, processes, kill, startupList, startupToggle };
