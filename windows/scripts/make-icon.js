'use strict';
// Gera build/icon.ico e build/icon.png a partir do ícone do app de Mac (../AppIcon.icns). Roda no macOS (usa sips).
const { execFileSync } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

(async () => {
  const pngToIco = (await import('png-to-ico')).default;
  const src = path.join(__dirname, '..', '..', 'AppIcon.icns');
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'lv-icon-'));
  const big = path.join(tmp, 'icon-1024.png');
  execFileSync('sips', ['-s', 'format', 'png', src, '--out', big], { stdio: 'ignore' });
  const sizes = [256, 128, 64, 48, 32, 24, 16];
  const files = sizes.map((s) => {
    const out = path.join(tmp, `icon-${s}.png`);
    execFileSync('sips', ['-z', String(s), String(s), big, '--out', out], { stdio: 'ignore' });
    return out;
  });
  const build = path.join(__dirname, '..', 'build');
  fs.mkdirSync(build, { recursive: true });
  fs.writeFileSync(path.join(build, 'icon.ico'), await pngToIco(files));
  execFileSync('sips', ['-z', '512', '512', big, '--out', path.join(build, 'icon.png')], { stdio: 'ignore' });
  fs.rmSync(tmp, { recursive: true, force: true });
  console.log('build/icon.ico e build/icon.png gerados');
})().catch((e) => { console.error(e); process.exit(1); });
