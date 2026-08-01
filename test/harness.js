'use strict';

/* ───────────────────────────────────────────────────────────────────────────
   Banco di prova per il processo di rendering.

   Electron non si avvia in una macchina senza schermo, e il codice che conta
   (misura del moto, accumulo delle fette, streaming del PNG) non ha bisogno
   di uno schermo per essere verificato. Qui il DOM viene da jsdom e il
   contesto 2D è una implementazione software minima ma pixel-esatta del
   sottoinsieme che l'app usa davvero: drawImage con rettangoli sorgente e
   destinazione, getImageData, le trasformazioni di traslazione e scala, il
   filtro brightness e il ritaglio rettangolare.

   Il video sorgente è sintetico: una scena che trasla di un numero noto di
   pixel per fotogramma. Se il misuratore del moto legge quel numero, funziona.
   ─────────────────────────────────────────────────────────────────────────── */

const { JSDOM } = require('jsdom');
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');

/* ─────────────── contesto 2D software ─────────────── */

function makeSurface(w, h) {
  return { width: w, height: h, px: new Uint8ClampedArray(w * h * 4) };
}

class Ctx2D {
  constructor(surface) {
    this.s = surface;
    this.filter = 'none';
    this.fillStyle = '#000';
    this.strokeStyle = '#000';
    this.lineWidth = 1;
    this.font = '';
    this.textBaseline = '';
    this.t = { a: 1, d: 1, e: 0, f: 0 };
    this.clipRect = null;
    this.stack = [];
  }

  save() { this.stack.push({ t: { ...this.t }, clipRect: this.clipRect, filter: this.filter }); }
  restore() {
    const s = this.stack.pop();
    if (s) { this.t = s.t; this.clipRect = s.clipRect; this.filter = s.filter; }
  }
  translate(x, y) { this.t.e += this.t.a * x; this.t.f += this.t.d * y; }
  scale(x, y) { this.t.a *= x; this.t.d *= y; }

  beginPath() { this._path = null; }
  rect(x, y, w, h) { this._path = { x, y, w, h }; }
  clip() {
    if (!this._path) return;
    const p = this._path;
    const x0 = this.t.a * p.x + this.t.e;
    const y0 = this.t.d * p.y + this.t.f;
    const x1 = this.t.a * (p.x + p.w) + this.t.e;
    const y1 = this.t.d * (p.y + p.h) + this.t.f;
    const r = {
      x0: Math.min(x0, x1), x1: Math.max(x0, x1),
      y0: Math.min(y0, y1), y1: Math.max(y0, y1)
    };
    this.clipRect = this.clipRect ? {
      x0: Math.max(this.clipRect.x0, r.x0), x1: Math.min(this.clipRect.x1, r.x1),
      y0: Math.max(this.clipRect.y0, r.y0), y1: Math.min(this.clipRect.y1, r.y1)
    } : r;
  }
  moveTo() {} lineTo() {} stroke() {} fill() {} fillText() {} strokeRect() {}

  _gain() {
    const m = /brightness\(([0-9.]+)\)/.exec(this.filter || '');
    return m ? parseFloat(m[1]) : 1;
  }

  clearRect(x, y, w, h) { this._paint(x, y, w, h, () => [0, 0, 0, 0]); }

  fillRect(x, y, w, h) {
    const c = parseColor(this.fillStyle);
    this._paint(x, y, w, h, () => c);
  }

  _paint(x, y, w, h, sample) {
    const { a, d, e, f } = this.t;
    let X0 = a * x + e, X1 = a * (x + w) + e;
    let Y0 = d * y + f, Y1 = d * (y + h) + f;
    if (X0 > X1) [X0, X1] = [X1, X0];
    if (Y0 > Y1) [Y0, Y1] = [Y1, Y0];
    const px0 = Math.max(0, Math.round(X0));
    const px1 = Math.min(this.s.width, Math.round(X1));
    const py0 = Math.max(0, Math.round(Y0));
    const py1 = Math.min(this.s.height, Math.round(Y1));
    for (let py = py0; py < py1; py++) {
      if (this.clipRect && (py < this.clipRect.y0 || py >= this.clipRect.y1)) continue;
      for (let px = px0; px < px1; px++) {
        if (this.clipRect && (px < this.clipRect.x0 || px >= this.clipRect.x1)) continue;
        const c = sample(px, py);
        const o = (py * this.s.width + px) * 4;
        this.s.px[o] = c[0]; this.s.px[o + 1] = c[1];
        this.s.px[o + 2] = c[2]; this.s.px[o + 3] = c[3];
      }
    }
  }

  drawImage(src, ...args) {
    const surf = src._surface || (src._frame && src._frame());
    if (!surf) throw new Error('sorgente disegnabile sconosciuta');
    let sx = 0, sy = 0, sw = surf.width, sh = surf.height, dx, dy, dw, dh;
    if (args.length === 2) { [dx, dy] = args; dw = sw; dh = sh; }
    else if (args.length === 4) { [dx, dy, dw, dh] = args; }
    else { [sx, sy, sw, sh, dx, dy, dw, dh] = args; }

    const gain = this._gain();
    this._paint(dx, dy, dw, dh, (px, py) => {
      const { a, d, e, f } = this.t;
      // ritorno alle coordinate utente, poi alla sorgente
      const ux = (px + 0.5 - e) / a;
      const uy = (py + 0.5 - f) / d;
      const fx = (ux - dx) / dw;
      const fy = (uy - dy) / dh;
      const cx = Math.min(surf.width - 1, Math.max(0, Math.floor(sx + fx * sw)));
      const cy = Math.min(surf.height - 1, Math.max(0, Math.floor(sy + fy * sh)));
      const o = (cy * surf.width + cx) * 4;
      return [
        surf.px[o] * gain, surf.px[o + 1] * gain, surf.px[o + 2] * gain, surf.px[o + 3]
      ];
    });
  }

  getImageData(x, y, w, h) {
    const out = new Uint8ClampedArray(w * h * 4);
    for (let r = 0; r < h; r++) {
      const sy = y + r;
      if (sy < 0 || sy >= this.s.height) continue;
      for (let c = 0; c < w; c++) {
        const sxp = x + c;
        if (sxp < 0 || sxp >= this.s.width) continue;
        const so = (sy * this.s.width + sxp) * 4;
        const dof = (r * w + c) * 4;
        out[dof] = this.s.px[so]; out[dof + 1] = this.s.px[so + 1];
        out[dof + 2] = this.s.px[so + 2]; out[dof + 3] = this.s.px[so + 3];
      }
    }
    return { width: w, height: h, data: out };
  }
}

function parseColor(v) {
  if (typeof v !== 'string') return [0, 0, 0, 255];
  let m = /^#([0-9a-f]{6})$/i.exec(v.trim());
  if (m) {
    const n = parseInt(m[1], 16);
    return [(n >> 16) & 255, (n >> 8) & 255, n & 255, 255];
  }
  m = /^rgba?\(([^)]+)\)$/i.exec(v.trim());
  if (m) {
    const p = m[1].split(',').map((s) => parseFloat(s));
    return [p[0] | 0, p[1] | 0, p[2] | 0, Math.round((p.length > 3 ? p[3] : 1) * 255)];
  }
  return [0, 0, 0, 255];
}

/* ─────────────── video sintetico ─────────────── */

// Una scena larga `sceneW` con barre verticali, osservata da una finestra che
// scorre di `shift` pixel per fotogramma. Il moto reale è quindi noto e vale
// esattamente `shift`.
function makeVideo(dom, { w = 320, h = 90, shift = 6, frames = 200, fps = 30 } = {}) {
  const sceneW = w + shift * frames + 8;
  const scene = makeSurface(sceneW, h);
  for (let x = 0; x < sceneW; x++) {
    // motivo non periodico, così la correlazione ha un minimo solo
    const v = 40 + 200 * (0.5 + 0.5 * Math.sin(x * 0.11) * Math.cos(x * 0.023));
    for (let y = 0; y < h; y++) {
      const o = (y * sceneW + x) * 4;
      const k = Math.max(0, Math.min(255, v * (0.55 + 0.45 * (y / h))));
      scene.px[o] = k; scene.px[o + 1] = k; scene.px[o + 2] = k; scene.px[o + 3] = 255;
    }
  }

  const el = dom.window.document.getElementById('video');
  const view = makeSurface(w, h);
  let frameIndex = 0;

  const render = () => {
    const off = Math.round(frameIndex * shift);
    for (let y = 0; y < h; y++) {
      for (let x = 0; x < w; x++) {
        const sxp = Math.min(sceneW - 1, x + off);
        const so = (y * sceneW + sxp) * 4;
        const dof = (y * w + x) * 4;
        view.px[dof] = scene.px[so]; view.px[dof + 1] = scene.px[so + 1];
        view.px[dof + 2] = scene.px[so + 2]; view.px[dof + 3] = 255;
      }
    }
    return view;
  };

  Object.defineProperty(el, 'videoWidth', { get: () => w, configurable: true });
  Object.defineProperty(el, 'videoHeight', { get: () => h, configurable: true });
  Object.defineProperty(el, 'duration', { get: () => frames / fps, configurable: true });
  Object.defineProperty(el, 'ended', { get: () => frameIndex >= frames - 1, configurable: true });
  Object.defineProperty(el, 'paused', { get: () => true, configurable: true });
  let ct = 0;
  Object.defineProperty(el, 'currentTime', {
    get: () => ct,
    set: (v) => { ct = v; frameIndex = Math.min(frames - 1, Math.round(v * fps)); },
    configurable: true
  });
  el._frame = render;
  el.play = () => Promise.resolve();
  el.pause = () => {};
  el.load = () => {};

  return {
    el,
    fps,
    frames,
    shift,
    advance(n = 1) { frameIndex = Math.min(frames - 1, frameIndex + n); ct = frameIndex / fps; }
  };
}

/* ─────────────── avvio dell'ambiente ─────────────── */

function boot(opts = {}) {
  const html = fs.readFileSync(path.join(ROOT, 'src', 'index.html'), 'utf8');
  const dom = new JSDOM(html, { pretendToBeVisual: true, runScripts: 'outside-only' });
  const { window } = dom;

  window.devicePixelRatio = 1;

  // ogni canvas riceve una superficie software
  const proto = window.HTMLCanvasElement.prototype;
  Object.defineProperty(proto, 'width', {
    get() { return this._surface ? this._surface.width : 300; },
    set(v) { this._resize(v | 0, this._surface ? this._surface.height : 150); },
    configurable: true
  });
  Object.defineProperty(proto, 'height', {
    get() { return this._surface ? this._surface.height : 150; },
    set(v) { this._resize(this._surface ? this._surface.width : 300, v | 0); },
    configurable: true
  });
  proto._resize = function (w, h) {
    w = Math.max(1, w); h = Math.max(1, h);
    this._surface = makeSurface(w, h);
    if (this._ctx) this._ctx.s = this._surface;
  };
  proto.getContext = function () {
    if (!this._surface) this._resize(300, 150);
    if (!this._ctx) this._ctx = new Ctx2D(this._surface);
    return this._ctx;
  };
  // toBlob deve restituire un PNG vero, non pixel grezzi: altrimenti la prova
  // dell'impaginazione verificherebbe qualcosa che nessun programma apre.
  proto.toBlob = function (cb) {
    const { PNG } = require('pngjs');
    const png = new PNG({ width: this._surface.width, height: this._surface.height });
    png.data = Buffer.from(this._surface.px);
    const buf = PNG.sync.write(png);
    cb({ arrayBuffer: async () => buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength) });
  };

  // dimensioni di layout: jsdom non fa layout, quindi le dichiariamo noi
  const box = (w, h) => () => ({ width: w, height: h, left: 0, top: 0, right: w, bottom: h });
  window.Element.prototype.getBoundingClientRect = box(600, 200);

  window.requestAnimationFrame = (cb) => setTimeout(() => cb(Date.now()), 0);
  window.cancelAnimationFrame = (id) => clearTimeout(id);

  const video = makeVideo(dom, opts.video);

  // il ponte verso il processo principale, in versione di prova
  const saved = [];
  const PngWriter = require(path.join(ROOT, 'electron', 'png-writer.js'));
  const writers = new Map();
  let seq = 0;
  window.bench = {
    platform: 'darwin',
    pickVideo: async () => null,
    registerVideo: async () => null,
    pathForFile: () => null,
    askPngPath: async (n) => path.join(opts.outDir || '/tmp', n),
    askPresetPath: async (n) => path.join(opts.outDir || '/tmp', n),
    openPreset: async () => null,
    writeText: async () => true,
    writeBuffer: async (p, b) => { fs.writeFileSync(p, Buffer.from(b)); saved.push(p); return true; },
    reveal: async () => true,
    png: {
      begin: async (p, w, h) => { const id = ++seq; writers.set(id, new PngWriter(p, w, h)); saved.push(p); return id; },
      rows: async (id, buf, n) => { await writers.get(id).writeRows(Buffer.from(buf), n); return true; },
      end: async (id) => { await writers.get(id).end(); writers.delete(id); return true; },
      abort: async (id) => { await writers.get(id).abort(); writers.delete(id); return true; }
    },
    onMenu: () => {}
  };

  const errors = [];
  window.addEventListener('error', (e) => errors.push(e.error || e.message));

  const code = fs.readFileSync(path.join(ROOT, 'src', 'app.js'), 'utf8');
  window.eval(code);

  return { dom, window, video, errors, saved };
}

module.exports = { boot, makeSurface, Ctx2D };
