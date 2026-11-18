'use strict';
// 06 — Aplicativos: lista das chaves Uninstall (HKLM 64/32 bits e HKCU) e desinstalador do próprio app.
const fsx = require('./fsx');
const { psJson, shellStart } = require('./win');
const { normalizeApps, splitCommand } = require('./logic');

const SCRIPT = `
$keys=@(
 @('HKLM','HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall'),
 @('HKLM32','HKLM:\\SOFTWARE\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall'),
 @('HKCU','HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall'),
 @('HKCU32','HKCU:\\Software\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall'))
$out=@()
foreach($k in $keys){ if(-not (Test-Path -LiteralPath $k[1])){continue}
  foreach($s in Get-ChildItem -LiteralPath $k[1] -ErrorAction SilentlyContinue){
    $p=$s.GetValue('DisplayName'); if(-not $p){continue}
    $out+=[pscustomobject]@{ hive=$k[0]; key=$s.PSChildName; DisplayName=[string]$p; Publisher=[string]$s.GetValue('Publisher');
      DisplayVersion=[string]$s.GetValue('DisplayVersion'); EstimatedSize=$s.GetValue('EstimatedSize'); InstallLocation=[string]$s.GetValue('InstallLocation');
      UninstallString=[string]$s.GetValue('UninstallString'); QuietUninstallString=[string]$s.GetValue('QuietUninstallString');
      SystemComponent=$s.GetValue('SystemComponent'); ParentKeyName=[string]$s.GetValue('ParentKeyName'); ReleaseType=[string]$s.GetValue('ReleaseType') } } }
ConvertTo-Json -InputObject @($out) -Compress -Depth 2`;

let last = [];

async function list() {
  if (!fsx.IS_WIN) return [];
  last = normalizeApps((await psJson(SCRIPT, null, 60000)).flat());
  return last.map(({ uninstall, ...a }) => ({ ...a, canUninstall: !!uninstall }));
}

/** Abre o desinstalador oficial do app (o Windows pode pedir permissão de administrador). */
async function uninstall(id) {
  const app = last.find((a) => a.id === id);
  if (!app || !app.uninstall) throw new Error('Esse app não informa um desinstalador.');
  const cmd = splitCommand(app.uninstall);
  await shellStart(cmd.file, cmd.args);
  return { started: true, name: app.name };
}

module.exports = { list, uninstall };
