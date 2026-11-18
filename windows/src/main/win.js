'use strict';
// Ponte com o Windows: PowerShell com saída UTF-8 e entrada por variável de ambiente (sem problemas de aspas).
const { execFile } = require('child_process');

function powershell(script, input, timeout = 60000) {
  if (process.platform !== 'win32') return Promise.reject(new Error('somente Windows'));
  const full = "$ProgressPreference='SilentlyContinue';[Console]::OutputEncoding=[Text.Encoding]::UTF8;" +
    "$in=$null; if($env:LV_INPUT){$in=$env:LV_INPUT | ConvertFrom-Json};\n" + script;
  const encoded = Buffer.from(full, 'utf16le').toString('base64');
  return new Promise((resolve, reject) => {
    execFile('powershell.exe', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', encoded],
      { env: { ...process.env, LV_INPUT: input == null ? '' : JSON.stringify(input) }, windowsHide: true, timeout, maxBuffer: 64 * 1024 * 1024 },
      (err, stdout, stderr) => (err ? reject(new Error((stderr || err.message).trim().slice(0, 500))) : resolve(stdout)));
  });
}

/** Roda um script que termina em ConvertTo-Json e devolve sempre um array. */
async function psJson(script, input, timeout) {
  const out = (await powershell(script, input, timeout)).trim();
  if (!out) return [];
  const v = JSON.parse(out);
  return Array.isArray(v) ? v : [v];
}

/** Abre um programa com ShellExecute (permite o pedido de administrador do Windows). */
function shellStart(file, args) {
  const ps = `Start-Process -FilePath $in.file ${args ? '-ArgumentList $in.args' : ''}`;
  return powershell(ps, { file, args }, 30000);
}

module.exports = { powershell, psJson, shellStart };
