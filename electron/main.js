'use strict';

const { app, BrowserWindow, protocol, ipcMain, dialog, shell, Menu } = require('electron');
const path = require('path');
const fs = require('fs');
const { Readable } = require('stream');
const PngWriter = require('./png-writer');

const SRC = path.join(__dirname, '..', 'src');
const isMac = process.platform === 'darwin';

// Il video viene servito da uno schema personalizzato invece che da file://.
// Sotto file:// Chromium considera il video di origine opaca e contamina il
// canvas: getImageData smette di funzionare e il misuratore del moto muore.
// Servendo dalla stessa origine della pagina il problema non si pone.
protocol.registerSchemesAsPrivileged([
  {
    scheme: 'strip',
    privileges: { standard: true, secure: true, supportFetchAPI: true, stream: true }
  }
]);

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.png': 'image/png',
  '.svg': 'image/svg+xml',
  '.mp4': 'video/mp4',
  '.m4v': 'video/mp4',
  '.mov': 'video/quicktime',
  '.webm': 'video/webm',
  '.mkv': 'video/x-matroska',
  '.ogv': 'video/ogg',
  '.avi': 'video/x-msvideo'
};

const VIDEO_EXT = ['mp4', 'm4v', 'mov', 'webm', 'mkv', 'ogv', 'avi'];

// Solo i file che l'utente ha aperto esplicitamente sono raggiungibili
// attraverso lo schema: il processo di rendering non può leggere il disco.
const allowedMedia = new Set();

// Simmetricamente, il rendering può scrivere solo dove l'utente ha appena
// confermato un percorso in un dialogo di sistema. Un percorso inventato dal
// processo di rendering non è scrivibile.
const allowedWrites = new Set();

let win = null;

// ---------------------------------------------------------------- protocollo

function serveFileWithRange(filePath, request) {
  let stat;
  try {
    stat = fs.statSync(filePath);
  } catch {
    return new Response('file non trovato', { status: 404 });
  }

  const size = stat.size;
  const type = MIME[path.extname(filePath).toLowerCase()] || 'application/octet-stream';
  const rangeHeader = request.headers.get('range');

  let start = 0;
  let end = size - 1;
  let status = 200;

  if (rangeHeader) {
    const m = /bytes=(\d*)-(\d*)/.exec(rangeHeader);
    if (m) {
      if (m[1]) start = parseInt(m[1], 10);
      if (m[2]) end = parseInt(m[2], 10);
      if (!m[1] && m[2]) {
        start = Math.max(0, size - parseInt(m[2], 10));
        end = size - 1;
      }
      // Un client che chiede oltre la fine del file è legittimo: la risposta
      // va troncata, non allungata. Senza questo limite Content-Length
      // prometteva più byte di quelli inviati e la richiesta restava appesa,
      // che è il modo in cui la ricerca esatta si bloccava a fine video.
      if (!Number.isFinite(start) || !Number.isFinite(end)) {
        return new Response(null, { status: 416, headers: { 'Content-Range': `bytes */${size}` } });
      }
      end = Math.min(end, size - 1);
      if (start > end || start >= size) {
        return new Response(null, { status: 416, headers: { 'Content-Range': `bytes */${size}` } });
      }
      status = 206;
    }
  }

  const headers = {
    'Content-Type': type,
    'Content-Length': String(end - start + 1),
    'Accept-Ranges': 'bytes',
    'Cache-Control': 'no-store'
  };
  if (status === 206) headers['Content-Range'] = `bytes ${start}-${end}/${size}`;

  const stream = fs.createReadStream(filePath, { start, end });
  return new Response(Readable.toWeb(stream), { status, headers });
}

function serveAppAsset(pathname) {
  let rel;
  try {
    rel = pathname === '/' || pathname === '' ? 'index.html' : decodeURIComponent(pathname).replace(/^\/+/, '');
  } catch {
    return new Response('percorso non valido', { status: 400 });
  }
  const resolved = path.resolve(SRC, rel);
  // Il confronto deve includere il separatore, altrimenti una cartella
  // sorella chiamata "src-altro" passerebbe il controllo.
  if (resolved !== SRC && !resolved.startsWith(SRC + path.sep)) {
    return new Response('vietato', { status: 403 });
  }
  try {
    const data = fs.readFileSync(resolved);
    const type = MIME[path.extname(resolved).toLowerCase()] || 'application/octet-stream';
    return new Response(data, { status: 200, headers: { 'Content-Type': type } });
  } catch {
    return new Response('non trovato', { status: 404 });
  }
}

// ------------------------------------------------------------------ finestra

function createWindow() {
  win = new BrowserWindow({
    width: 1440,
    height: 940,
    minWidth: 900,
    minHeight: 620,
    backgroundColor: '#16180F',
    show: false,
    titleBarStyle: isMac ? 'hiddenInset' : 'hidden',
    titleBarOverlay: process.platform === 'win32'
      ? { color: '#1E2018', symbolColor: '#EDEAD9', height: 40 }
      : undefined,
    trafficLightPosition: isMac ? { x: 16, y: 13 } : undefined,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
      backgroundThrottling: false
    }
  });

  win.loadURL('strip://local/index.html');
  win.once('ready-to-show', () => win.show());

  // Senza questo, dopo la chiusura della finestra su macOS il riferimento
  // restava valido ma l'oggetto era distrutto, e ogni voce di menu lanciava
  // "Object has been destroyed" invece di non fare niente.
  win.on('closed', () => { win = null; });

  // Un ricaricamento della pagina abbandona i salvataggi in corso: i
  // descrittori vanno chiusi, altrimenti restano aperti fino all'uscita.
  win.webContents.on('did-start-navigation', (_e, _url, isInPlace, isMainFrame) => {
    if (isMainFrame && !isInPlace) closeAllWriters();
  });

  win.webContents.setWindowOpenHandler(({ url }) => {
    if (/^https?:/.test(url)) shell.openExternal(url);
    return { action: 'deny' };
  });

  // Nessuna navigazione fuori dallo schema dell'app.
  win.webContents.on('will-navigate', (e, url) => {
    if (!url.startsWith('strip://local/')) e.preventDefault();
  });
}

const send = (channel) => { if (win && !win.isDestroyed()) win.webContents.send(channel); };

function buildMenu() {
  const template = [
    ...(isMac ? [{ role: 'appMenu' }] : []),
    {
      label: 'File',
      submenu: [
        { label: 'Apri video…', accelerator: 'CmdOrCtrl+O', click: () => send('menu:open') },
        { label: 'Salva striscia…', accelerator: 'CmdOrCtrl+S', click: () => send('menu:save') },
        { type: 'separator' },
        { label: 'Salva impostazioni…', click: () => send('menu:presetSave') },
        { label: 'Carica impostazioni…', click: () => send('menu:presetLoad') },
        { type: 'separator' },
        isMac ? { role: 'close' } : { role: 'quit' }
      ]
    },
    {
      label: 'Scansione',
      submenu: [
        // Niente acceleratore Spazio: un acceleratore di menu ha la
        // precedenza su qualunque campo di testo, e la barra spaziatrice
        // diventava inutilizzabile ovunque nella finestra. L'avvio da
        // tastiera lo gestisce il processo di rendering, che sa se il
        // fuoco è dentro un comando.
        // Non CmdOrCtrl+R: è già l'acceleratore del ricaricamento, e la voce
        // registrata per seconda non avrebbe mai risposto.
        { label: 'Avvia / ferma', accelerator: 'CmdOrCtrl+Return', click: () => send('menu:toggle') },
        { label: 'Svuota striscia', accelerator: 'CmdOrCtrl+Backspace', click: () => send('menu:clear') },
        // Non CmdOrCtrl+M: su macOS è "riduci a icona" e si tocca per riflesso.
        { label: 'Adatta larghezza al moto', accelerator: 'CmdOrCtrl+L', click: () => send('menu:match') }
      ]
    },
    {
      label: 'Finestra',
      submenu: [
        { role: 'reload' },
        { role: 'toggleDevTools' },
        { type: 'separator' },
        { role: 'resetZoom' },
        { role: 'zoomIn' },
        { role: 'zoomOut' },
        { type: 'separator' },
        { role: 'togglefullscreen' },
        { role: 'minimize' }
      ]
    }
  ];
  Menu.setApplicationMenu(Menu.buildFromTemplate(template));
}

// ----------------------------------------------------------------------- IPC

const writers = new Map();
let writerSeq = 0;

function closeAllWriters() {
  for (const [id, w] of writers) {
    w.abort().catch(() => {});
    writers.delete(id);
  }
}

function assertWritable(filePath) {
  const resolved = path.resolve(String(filePath || ''));
  if (!allowedWrites.has(resolved)) throw new Error('percorso non autorizzato');
  return resolved;
}

function registerIpc() {
  ipcMain.handle('media:pick', async () => {
    const r = await dialog.showOpenDialog(win, {
      title: 'Apri un video',
      properties: ['openFile'],
      filters: [
        { name: 'Video', extensions: VIDEO_EXT },
        { name: 'Tutti i file', extensions: ['*'] }
      ]
    });
    if (r.canceled || !r.filePaths.length) return null;
    return registerMedia(r.filePaths[0]);
  });

  ipcMain.handle('media:register', (_e, filePath) => registerMedia(filePath));

  ipcMain.handle('dialog:savePng', async (_e, defaultName) => {
    const r = await dialog.showSaveDialog(win, {
      title: 'Salva la striscia',
      defaultPath: String(defaultName || 'striscia.png'),
      filters: [{ name: 'Immagine PNG', extensions: ['png'] }]
    });
    if (r.canceled || !r.filePath) return null;
    allowedWrites.add(path.resolve(r.filePath));
    return r.filePath;
  });

  ipcMain.handle('dialog:savePreset', async (_e, defaultName) => {
    const r = await dialog.showSaveDialog(win, {
      title: 'Salva le impostazioni',
      defaultPath: String(defaultName || 'fenditura.json'),
      filters: [{ name: 'Impostazioni Fenditura', extensions: ['json'] }]
    });
    if (r.canceled || !r.filePath) return null;
    allowedWrites.add(path.resolve(r.filePath));
    return r.filePath;
  });

  ipcMain.handle('dialog:openPreset', async () => {
    const r = await dialog.showOpenDialog(win, {
      title: 'Carica le impostazioni',
      properties: ['openFile'],
      filters: [{ name: 'Impostazioni Fenditura', extensions: ['json'] }]
    });
    if (r.canceled || !r.filePaths.length) return null;
    try {
      const data = JSON.parse(fs.readFileSync(r.filePaths[0], 'utf8'));
      return data && typeof data === 'object' && !Array.isArray(data) ? data : null;
    } catch {
      // Il rendering distingue "annullato" da "illeggibile" e lo dice.
      return { __error: 'file non leggibile come impostazioni Fenditura' };
    }
  });

  ipcMain.handle('file:writeText', (_e, filePath, text) => {
    fs.writeFileSync(assertWritable(filePath), String(text), 'utf8');
    return true;
  });

  ipcMain.handle('file:writeBuffer', (_e, filePath, buf) => {
    fs.writeFileSync(assertWritable(filePath), Buffer.from(buf));
    return true;
  });

  ipcMain.handle('png:begin', (_e, filePath, width, height) => {
    const id = ++writerSeq;
    writers.set(id, new PngWriter(assertWritable(filePath), width, height));
    return id;
  });

  ipcMain.handle('png:rows', async (_e, id, buf, rowCount) => {
    const w = writers.get(id);
    if (!w) throw new Error('scrittore inesistente');
    try {
      await w.writeRows(Buffer.from(buf), rowCount);
    } catch (err) {
      writers.delete(id);
      await w.abort().catch(() => {});
      throw err;
    }
    return true;
  });

  ipcMain.handle('png:end', async (_e, id) => {
    const w = writers.get(id);
    if (!w) return false;
    writers.delete(id);
    try {
      await w.end();
    } catch (err) {
      // Un errore nella chiusura lascerebbe sul disco un PNG senza IEND, che
      // non si apre da nessuna parte e sembra soltanto un file rotto.
      await w.discard().catch(() => {});
      throw err;
    }
    return true;
  });

  ipcMain.handle('png:abort', async (_e, id) => {
    const w = writers.get(id);
    if (!w) return false;
    writers.delete(id);
    await w.abort();
    return true;
  });

  ipcMain.handle('shell:reveal', (_e, filePath) => {
    const resolved = path.resolve(String(filePath || ''));
    if (!allowedWrites.has(resolved) && !allowedMedia.has(resolved)) return false;
    shell.showItemInFolder(resolved);
    return true;
  });
}

function registerMedia(filePath) {
  if (typeof filePath !== 'string' || !filePath) return null;
  const resolved = path.resolve(filePath);
  let stat;
  try {
    stat = fs.statSync(resolved);
  } catch {
    return null;
  }
  // Una cartella trascinata sulla finestra arrivava fin qui e diventava una
  // sorgente che il tag video non poteva decodificare, senza spiegazioni.
  if (!stat.isFile()) return null;
  allowedMedia.add(resolved);
  return {
    path: resolved,
    name: path.basename(resolved),
    url: 'strip://local/media?p=' + encodeURIComponent(resolved),
    size: stat.size
  };
}

// ------------------------------------------------------------------- avvio

app.whenReady().then(() => {
  protocol.handle('strip', (request) => {
    const url = new URL(request.url);
    if (url.hostname !== 'local') return new Response('non trovato', { status: 404 });

    if (url.pathname === '/media') {
      const p = url.searchParams.get('p');
      if (!p) return new Response('parametro mancante', { status: 400 });
      const resolved = path.resolve(p);
      if (!allowedMedia.has(resolved)) return new Response('vietato', { status: 403 });
      return serveFileWithRange(resolved, request);
    }

    return serveAppAsset(url.pathname);
  });

  registerIpc();
  buildMenu();
  createWindow();

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on('before-quit', closeAllWriters);

app.on('window-all-closed', () => {
  closeAllWriters();
  if (!isMac) app.quit();
});
