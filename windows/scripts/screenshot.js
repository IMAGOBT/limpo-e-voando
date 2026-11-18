'use strict';
// Dev: abre o app, passa por todas as seções nos temas claro e escuro e salva PNGs (capturePage).
// Uso: npm run screenshot  (pasta de saída: LV_SHOTS ou <tmp>/lv-shots)
const { app } = require('electron');
const fs = require('fs');
const os = require('os');
const path = require('path');

const out = process.env.LV_SHOTS || path.join(os.tmpdir(), 'lv-shots');
// LV_SCAN=lens,clutter → nessas seções aperta "Analisar" e espera o resultado antes de capturar (só leitura)
const scan = (process.env.LV_SCAN || '').split(',').filter(Boolean);
const only = (process.env.LV_SECTIONS || 'home,cleanup,clutter,perf,lens,apps,organize,compress,download,tools').split(',');
fs.mkdirSync(out, { recursive: true });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

app.on('browser-window-created', (_e, w) => {
  w.webContents.once('did-finish-load', async () => {
    await sleep(1200);
    for (const theme of ['light', 'dark']) {
      await w.webContents.executeJavaScript(`window.__lv.theme('${theme}')`);
      for (const s of only) {
        await w.webContents.executeJavaScript(`window.__lv.go('${s}')`);
        await sleep(s === 'perf' ? 1800 : 600);
        if (scan.includes(s) && theme === 'light') {
          await w.webContents.executeJavaScript(`(async () => { const b = document.querySelector('[data-primary]'); if (b) b.click();
            for (let i = 0; i < 240 && document.querySelector('.go .progress, .round[disabled]'); i++) await new Promise(r => setTimeout(r, 500)); })()`);
          await sleep(800);
        }
        const img = await w.webContents.capturePage();
        fs.writeFileSync(path.join(out, `${theme}-${s}.png`), img.toPNG());
      }
    }
    await w.webContents.executeJavaScript(`window.__lv.theme('system')`);
    console.log(`capturas em ${out}`);
    app.quit();
  });
});
require('../main.js');
