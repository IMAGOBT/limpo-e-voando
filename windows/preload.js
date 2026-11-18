'use strict';
// Ponte mínima: o renderer só chama nomes desta lista e só ouve estes eventos.
const { contextBridge, ipcRenderer } = require('electron');

const METHODS = ['info', 'disk.free', 'cleanup.scan', 'cleanup.clean', 'recycle.info', 'recycle.empty', 'clutter.large', 'clutter.dups',
  'clutter.trashDups', 'files.trash', 'perf.sample', 'perf.processes', 'perf.kill', 'startup.list', 'startup.toggle', 'lens.list',
  'lens.trash', 'apps.list', 'apps.uninstall', 'org.preview', 'org.apply', 'org.undo', 'org.last', 'compress.run', 'compress.cancel',
  'dl.add', 'dl.cancel', 'dl.list', 'tools.status', 'shell.show', 'shell.open', 'dialog.folder', 'dialog.media', 'theme.get', 'theme.set'];
const EVENTS = ['progress', 'dl', 'compress', 'tools'];

contextBridge.exposeInMainWorld('lv', {
  async call(name, ...args) {
    if (!METHODS.includes(name)) throw new Error(`método desconhecido: ${name}`);
    const r = await ipcRenderer.invoke(`lv:${name}`, ...args);
    if (!r.ok) throw new Error(r.error);
    return r.data;
  },
  on(evt, cb) {
    if (!EVENTS.includes(evt)) return () => {};
    const h = (_e, d) => cb(d);
    ipcRenderer.on(evt, h);
    return () => ipcRenderer.removeListener(evt, h);
  },
});
