'use strict';

const { contextBridge, ipcRenderer, webUtils } = require('electron');

const CHANNELS = {
  'menu:open': 'open',
  'menu:save': 'save',
  'menu:toggle': 'toggle',
  'menu:clear': 'clear',
  'menu:match': 'match',
  'menu:presetSave': 'presetSave',
  'menu:presetLoad': 'presetLoad'
};

// Un solo insieme di ascoltatori, registrato una volta sola: chiamare onMenu
// due volte accumulava ascoltatori e ogni voce di menu partiva due volte.
let menuHandler = null;
Object.keys(CHANNELS).forEach((ch) => {
  ipcRenderer.on(ch, () => { if (menuHandler) menuHandler(CHANNELS[ch]); });
});

// Il processo di rendering non vede né Node né il filesystem: passa da qui,
// e ogni funzione esposta fa una cosa sola e dichiarata.
contextBridge.exposeInMainWorld('bench', {
  platform: process.platform,

  pickVideo: () => ipcRenderer.invoke('media:pick'),
  registerVideo: (filePath) => ipcRenderer.invoke('media:register', filePath),

  // In Electron recente File.path non esiste più: si passa da webUtils.
  pathForFile: (file) => {
    try {
      if (webUtils && typeof webUtils.getPathForFile === 'function') {
        return webUtils.getPathForFile(file) || null;
      }
    } catch { /* ricade sotto */ }
    return file && file.path ? file.path : null;
  },

  askPngPath: (name) => ipcRenderer.invoke('dialog:savePng', name),
  askPresetPath: (name) => ipcRenderer.invoke('dialog:savePreset', name),
  openPreset: () => ipcRenderer.invoke('dialog:openPreset'),
  writeText: (p, t) => ipcRenderer.invoke('file:writeText', p, t),
  writeBuffer: (p, b) => ipcRenderer.invoke('file:writeBuffer', p, b),
  reveal: (p) => ipcRenderer.invoke('shell:reveal', p),

  png: {
    begin: (p, w, h) => ipcRenderer.invoke('png:begin', p, w, h),
    rows: (id, buf, n) => ipcRenderer.invoke('png:rows', id, buf, n),
    end: (id) => ipcRenderer.invoke('png:end', id),
    abort: (id) => ipcRenderer.invoke('png:abort', id)
  },

  onMenu: (handler) => { menuHandler = typeof handler === 'function' ? handler : null; }
});
