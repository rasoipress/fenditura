'use strict';

/* ═══════════════════════════════════════════════════════════════════════════
   Fenditura — processo di rendering

   Il principio: da ogni fotogramma si preleva sempre la stessa fetta di
   pixel e la si accoda alla precedente. L'asse lungo dell'immagine che
   ne esce non è spazio, è tempo.

   Due vincoli governano tutto il resto del file:
   · un canvas non può superare circa 32.000 px per lato, quindi la
     striscia vive in piastrelle affiancate da 4096 px e il salvataggio
     passa da uno scrittore PNG incrementale nel processo principale;
   · la proporzione dell'immagine finale dipende dal rapporto fra la
     larghezza della fetta e lo spostamento reale dell'immagine per
     fotogramma catturato, quindi quello spostamento va misurato, non
     indovinato.
   ═══════════════════════════════════════════════════════════════════════════ */

const bench = window.bench || null;
const $ = (id) => document.getElementById(id);
const clamp = (v, a, b) => (v < a ? a : v > b ? b : v);

// requestAnimationFrame si ferma quando la finestra è coperta o ridotta a
// icona. Il salvataggio non deve dipendere dal fatto che qualcuno guardi:
// se il fotogramma non arriva entro un attimo, si prosegue lo stesso.
const nextFrame = () => new Promise((resolve) => {
  let done = false;
  const go = () => { if (!done) { done = true; resolve(); } };
  requestAnimationFrame(go);
  setTimeout(go, 60);
});

/* ───────────────────────────── stato ───────────────────────────── */

const LIMITS = {
  pos: [0, 1],
  width: [1, 96],
  drift: [-12, 12],
  scale: [0.1, 1],
  step: [1, 16],
  rate: [0.25, 6],
  fps: [1, 480],
  maxLen: [1000, 2000000],
  seg: [800, 12000]
};

const S = {
  pos: 0.5,        // posizione della fenditura, 0…1 sull'asse trasversale
  width: 4,        // larghezza della fetta in pixel della sorgente
  drift: 0,        // spostamento della fenditura per fotogramma catturato
  axis: 'x',       // 'x' fenditura verticale, 'y' fenditura orizzontale
  dir: 1,          // verso di accumulo
  scale: 0.5,      // scala dell'immagine in uscita
  mirror: false,
  step: 1,         // un fotogramma ogni N
  method: 'play',
  rate: 1,
  fps: 30,
  expStab: false,
  maxLen: 120000,
  outMode: 'single',
  seg: 4000
};

const TILE = 4096;
const LUM_FRAMES = 8;   // fotogrammi su cui si media il riferimento di esposizione

// Ogni piastrella porta con sé quanto è stata riempita davvero. Dedurlo,
// dando per scontato che tutte tranne l'ultima siano piene fino a TILE, vale
// solo se la fetta in uscita divide 4096 — cioè per le potenze di due e per
// nient'altro. Con una fetta da 3 o da 24 px ogni piastrella chiudeva con
// una frangia mai disegnata, che finiva nera dentro l'immagine salvata e
// faceva sforare i byte oltre la larghezza dichiarata allo scrittore PNG.
let tiles = [];        // { c, ctx, fill }
let outCross = 0;      // dimensione trasversale dell'uscita
let stripLen = 0;      // lunghezza accumulata
let captured = 0;
let driftAcc = 0;
let marks = [];        // { p, t } per il righello temporale
let running = false;
let exporting = false;
let mediaPath = null;

let lumRef = null;
let lumCount = 0;

/* ─────────────────────────── elementi ─────────────────────────── */

const video = $('video');
const overlay = $('overlay');
const detail = $('detail');
const map = $('map');
const ruler = $('ruler');
const trace = $('trace');

const dCtx = detail.getContext('2d');
const mCtx = map.getContext('2d');
const rCtx = ruler.getContext('2d');
const tCtx = trace.getContext('2d');
const oCtx = overlay.getContext('2d');

const css = getComputedStyle(document.documentElement);
const COLOR = {
  cut: css.getPropertyValue('--cut').trim() || '#D23B22',
  data: css.getPropertyValue('--data').trim() || '#EFB230',
  dim: css.getPropertyValue('--dim').trim() || '#8D9379',
  dimmer: css.getPropertyValue('--dimmer').trim() || '#5E6551',
  rule: css.getPropertyValue('--rule').trim() || '#333A26',
  paper: css.getPropertyValue('--paper').trim() || '#EFEBDA'
};

if (bench) document.body.classList.add(bench.platform === 'darwin' ? 'mac' : bench.platform === 'win32' ? 'win' : 'linux');

// Ridimensionare un canvas lo azzera e ne rialloca il buffer. Farlo a ogni
// fotogramma, come accadeva prima, costava più del disegno stesso: qui si
// tocca solo quando la misura è davvero cambiata.
function fitCanvas(el) {
  const dpr = Math.min(devicePixelRatio || 1, 2);
  const r = el.getBoundingClientRect();
  if (!r.width || !r.height) return false;
  const w = Math.max(1, Math.round(r.width * dpr));
  const h = Math.max(1, Math.round(r.height * dpr));
  if (el.width !== w) el.width = w;
  if (el.height !== h) el.height = h;
  return true;
}

/* ───────────────────── caricamento sorgente ───────────────────── */

async function pickVideo() {
  if (!bench) return;
  const info = await bench.pickVideo();
  if (info) attach(info);
}

async function attachFromFile(file) {
  if (!bench) return;
  const p = bench.pathForFile(file);
  if (!p) { note('non riesco a leggere il percorso di questo file'); return; }
  const info = await bench.registerVideo(p);
  if (info) attach(info);
  else note('questo non è un file video leggibile');
}

function attach(info) {
  // Cambiare sorgente senza svuotare la striscia accodava i fotogrammi del
  // video nuovo a quelli del vecchio, con il righello temporale che leggeva
  // i tempi sbagliati e nessun segnale di quel che era successo.
  halt('');
  resetStrip();
  mediaPath = info.path;
  video.src = info.url;
  $('sourceName').textContent = info.name;
  $('lamp').dataset.state = 'ready';
  video.load();
}

video.addEventListener('loadedmetadata', () => {
  $('frame').hidden = false;
  $('invite').style.display = 'none';
  $('sourceSpec').textContent =
    `${video.videoWidth} × ${video.videoHeight} · ${fmtTime(video.duration)}`;

  ana.width = ANA_W;
  ana.height = Math.max(2, Math.round(ANA_W * video.videoHeight / video.videoWidth));

  ['btnRun', 'btnClear', 'scrub', 'btnMatch'].forEach((id) => ($(id).disabled = false));
  resetStrip();
  fitOverlay();
  paintOverlay();
  refreshTime();
});

video.addEventListener('error', () => {
  halt('');
  $('frame').hidden = true;
  $('invite').style.display = '';
  $('sourceName').textContent = 'il video non può essere decodificato in questo formato';
  $('sourceSpec').textContent = '—';
  $('lamp').dataset.state = 'idle';
  ['btnRun', 'btnClear', 'scrub', 'btnMatch', 'btnSave'].forEach((id) => ($(id).disabled = true));
});

const viewer = $('viewer');
['dragenter', 'dragover'].forEach((t) =>
  window.addEventListener(t, (e) => { e.preventDefault(); viewer.classList.add('hot'); }));
['dragleave', 'drop'].forEach((t) =>
  window.addEventListener(t, (e) => { e.preventDefault(); viewer.classList.remove('hot'); }));
window.addEventListener('drop', (e) => {
  e.preventDefault();
  const f = e.dataTransfer && e.dataTransfer.files[0];
  if (f) attachFromFile(f);
});

function note(text) { $('counter').textContent = text; }

/* ─────────────────────────── tempo ─────────────────────────── */

function fmtTime(t) {
  if (!isFinite(t)) return '00:00.00';
  const m = Math.floor(t / 60);
  const s = t % 60;
  return `${String(m).padStart(2, '0')}:${s.toFixed(2).padStart(5, '0')}`;
}

let scrubbing = false;

function refreshTime() {
  $('timecode').innerHTML = `${fmtTime(video.currentTime)}<i>/</i>${fmtTime(video.duration)}`;
  if (video.duration && !scrubbing) {
    $('scrub').value = Math.round((video.currentTime / video.duration) * 10000);
  }
}
video.addEventListener('timeupdate', refreshTime);
$('scrub').addEventListener('pointerdown', () => { scrubbing = true; });
['pointerup', 'pointercancel', 'blur'].forEach((t) =>
  $('scrub').addEventListener(t, () => { scrubbing = false; }));
$('scrub').addEventListener('input', (e) => {
  // Spostarsi nel video durante la scansione produceva un salto nel tempo in
  // mezzo alla striscia, senza che niente lo segnalasse.
  if (running) { halt('scansione fermata: hai spostato la testina'); }
  if (video.duration) video.currentTime = (e.target.value / 10000) * video.duration;
});

/* ───────────────────── sovrapposizione fenditura ───────────────────── */

function fitOverlay() { fitCanvas(overlay); }

function crossSize() {
  return S.axis === 'x' ? video.videoWidth : video.videoHeight;
}

function slitCentre() {
  const cross = crossSize();
  if (!cross) return 0;
  return clamp(S.pos * cross + driftAcc, 0, cross);
}

function paintOverlay() {
  const w = overlay.width;
  const h = overlay.height;
  if (!w || !h || !video.videoWidth) return;
  oCtx.clearRect(0, 0, w, h);

  const vertical = S.axis === 'x';
  const frac = clamp(slitCentre() / crossSize(), 0, 1);
  const span = vertical ? w : h;
  const p = frac * span;
  const thick = Math.max(2, (S.width / crossSize()) * span);

  oCtx.fillStyle = 'rgba(210,59,34,.26)';
  oCtx.strokeStyle = COLOR.cut;
  oCtx.lineWidth = 1;

  if (vertical) {
    oCtx.fillRect(p - thick / 2, 0, thick, h);
    oCtx.beginPath(); oCtx.moveTo(p + 0.5, 0); oCtx.lineTo(p + 0.5, h); oCtx.stroke();
    oCtx.fillStyle = COLOR.cut;
    oCtx.beginPath(); oCtx.moveTo(p - 6, 0); oCtx.lineTo(p + 6, 0); oCtx.lineTo(p, 10); oCtx.fill();
    oCtx.beginPath(); oCtx.moveTo(p - 6, h); oCtx.lineTo(p + 6, h); oCtx.lineTo(p, h - 10); oCtx.fill();
  } else {
    oCtx.fillRect(0, p - thick / 2, w, thick);
    oCtx.beginPath(); oCtx.moveTo(0, p + 0.5); oCtx.lineTo(w, p + 0.5); oCtx.stroke();
    oCtx.fillStyle = COLOR.cut;
    oCtx.beginPath(); oCtx.moveTo(0, p - 6); oCtx.lineTo(0, p + 6); oCtx.lineTo(10, p); oCtx.fill();
    oCtx.beginPath(); oCtx.moveTo(w, p - 6); oCtx.lineTo(w, p + 6); oCtx.lineTo(w - 10, p); oCtx.fill();
  }
}

let dragging = false;
function pointToPos(e) {
  const r = overlay.getBoundingClientRect();
  if (!r.width || !r.height) return;
  const v = S.axis === 'x' ? (e.clientX - r.left) / r.width : (e.clientY - r.top) / r.height;
  S.pos = clamp(v, 0, 1);
  $('ctlPos').value = Math.round(S.pos * 10000);
  $('ctlPosV').textContent = `${(S.pos * 100).toFixed(1)} %`;
  paintOverlay();
}
overlay.addEventListener('pointerdown', (e) => { dragging = true; overlay.setPointerCapture(e.pointerId); pointToPos(e); });
overlay.addEventListener('pointermove', (e) => { if (dragging) pointToPos(e); });
overlay.addEventListener('pointerup', () => { dragging = false; });
overlay.addEventListener('pointercancel', () => { dragging = false; });

let resizeTimer = null;
window.addEventListener('resize', () => {
  clearTimeout(resizeTimer);
  resizeTimer = setTimeout(() => { fitOverlay(); paintOverlay(); repaintAll(); }, 80);
});

/* ─────────────────────── striscia a piastrelle ─────────────────────── */

function resetStrip() {
  tiles = [];
  stripLen = 0;
  captured = 0;
  driftAcc = 0;
  marks = [];
  lumRef = null;
  lumCount = 0;
  prevProfile = null;
  prevAt = 0;
  measured = null;
  smoothed = null;
  if (video.videoWidth) {
    outCross = S.axis === 'x'
      ? Math.max(1, Math.round(video.videoHeight * S.scale))
      : Math.max(1, Math.round(video.videoWidth * S.scale));
  } else {
    outCross = 0;
  }
  $('theatreEmpty').style.display = '';
  $('btnSave').disabled = true;
  repaintAll();
  refreshDials();
  refreshStats();
}

function addTile() {
  const c = document.createElement('canvas');
  if (S.axis === 'x') { c.width = TILE; c.height = outCross; }
  else { c.width = outCross; c.height = TILE; }
  const ctx = c.getContext('2d', { willReadFrequently: true });
  tiles.push({ c, ctx, fill: 0 });
}

function appendSlit() {
  const vertical = S.axis === 'x';
  const cross = crossSize();
  if (!cross || !outCross) return;
  const sw = Math.max(1, Math.min(Math.round(S.width), cross));
  const s0 = Math.round(clamp(slitCentre() - sw / 2, 0, cross - sw));
  const outStep = Math.max(1, Math.round(sw * S.scale));

  if (!tiles.length || tiles[tiles.length - 1].fill + outStep > TILE) addTile();
  const tile = tiles[tiles.length - 1];
  const at = tile.fill;

  let gain = 1;
  if (S.expStab && lumRef !== null) {
    const l = sampleLuma();
    if (l > 4) gain = clamp(lumRef / l, 0.35, 2.8);
  }
  tile.ctx.filter = gain === 1 ? 'none' : `brightness(${gain.toFixed(3)})`;

  if (vertical) tile.ctx.drawImage(video, s0, 0, sw, video.videoHeight, at, 0, outStep, outCross);
  else tile.ctx.drawImage(video, 0, s0, video.videoWidth, sw, 0, at, outCross, outStep);

  tile.ctx.filter = 'none';

  if (captured % 24 === 0) marks.push({ p: stripLen, t: video.currentTime });

  tile.fill = at + outStep;
  stripLen += outStep;
  captured++;
  // La deriva è dichiarata per fotogramma catturato, come la misura del moto:
  // moltiplicarla anche per il passo di campionamento la rendeva incoerente
  // con il numero che il quadrante mostra sopra.
  driftAcc += S.drift;

  if (stripLen >= S.maxLen) halt('lunghezza massima raggiunta');
}

/* elenco dei tratti lungo l'asse lungo, già ordinati secondo il verso
   di accumulo e con l'eventuale raddoppio specchiato in coda */
function buildRuns() {
  const base = [];
  for (const tile of tiles) {
    if (tile.fill > 0) base.push({ tile, count: tile.fill, rev: false });
  }
  let seq = base;
  if (S.dir === -1) seq = base.slice().reverse().map((r) => ({ ...r, rev: true }));
  if (!S.mirror) return seq;
  const back = seq.slice().reverse().map((r) => ({ ...r, rev: !r.rev }));
  return seq.concat(back);
}

function stripSize(withMirror) {
  const mul = withMirror && S.mirror ? 2 : 1;
  return S.axis === 'x'
    ? { w: stripLen * mul, h: outCross }
    : { w: outCross, h: stripLen * mul };
}

/* ───────────────────── misura del moto ───────────────────── */

const ANA_W = 208;
const ana = document.createElement('canvas');
const aCtx = ana.getContext('2d', { willReadFrequently: true });
let prevProfile = null;
let prevAt = 0;      // valore di `captured` quando è stato preso prevProfile
let measured = null;
let smoothed = null;

function sampleLuma() {
  if (!video.videoWidth) return 0;
  aCtx.drawImage(video, 0, 0, ana.width, ana.height);
  const vertical = S.axis === 'x';
  const span = vertical ? ana.width : ana.height;
  const c0 = clamp(Math.round((slitCentre() / crossSize()) * span), 0, span - 1);
  const d = vertical
    ? aCtx.getImageData(c0, 0, 1, ana.height).data
    : aCtx.getImageData(0, c0, ana.width, 1).data;
  let sum = 0;
  for (let i = 0; i < d.length; i += 4) sum += 0.299 * d[i] + 0.587 * d[i + 1] + 0.114 * d[i + 2];
  return sum / (d.length / 4);
}

function measureMotion() {
  if (!video.videoWidth) return;
  aCtx.drawImage(video, 0, 0, ana.width, ana.height);
  const img = aCtx.getImageData(0, 0, ana.width, ana.height).data;
  const vertical = S.axis === 'x';
  const n = vertical ? ana.width : ana.height;
  const prof = new Float32Array(n);

  if (vertical) {
    for (let x = 0; x < ana.width; x++) {
      let s = 0;
      for (let y = 0; y < ana.height; y++) {
        const i = (y * ana.width + x) * 4;
        s += 0.299 * img[i] + 0.587 * img[i + 1] + 0.114 * img[i + 2];
      }
      prof[x] = s / ana.height;
    }
  } else {
    for (let y = 0; y < ana.height; y++) {
      let s = 0;
      for (let x = 0; x < ana.width; x++) {
        const i = (y * ana.width + x) * 4;
        s += 0.299 * img[i] + 0.587 * img[i + 1] + 0.114 * img[i + 2];
      }
      prof[y] = s / ana.width;
    }
  }

  // Il confronto avviene fra due profili distanti un numero noto di
  // fotogrammi catturati, e il risultato va riportato a uno solo. Prima si
  // divideva per il passo di campionamento, che è un'altra grandezza: con la
  // misura presa ogni due catture e un passo diverso da uno, il numero
  // mostrato e la larghezza suggerita erano sbagliati di un fattore intero,
  // ed era esattamente il caso in cui l'utente si fida del quadrante.
  if (prevProfile && prevProfile.length === n) {
    const elapsed = Math.max(1, captured - prevAt);
    const R = Math.min(30, Math.floor(n / 4));
    let best = 0;
    let bestErr = Infinity;
    for (let sh = -R; sh <= R; sh++) {
      let err = 0;
      let cnt = 0;
      for (let i = R; i < n - R; i++) {
        const j = i + sh;
        if (j < 0 || j >= n) continue;
        const d = prof[i] - prevProfile[j];
        err += d * d;
        cnt++;
      }
      if (cnt) {
        err /= cnt;
        if (err < bestErr) { bestErr = err; best = sh; }
      }
    }
    const d = (Math.abs(best) * (crossSize() / n)) / elapsed;
    smoothed = smoothed === null ? d : smoothed * 0.72 + d * 0.28;
    measured = smoothed;
  }
  prevProfile = prof;
  prevAt = captured;
  paintTrace(prof);
}

function paintTrace(prof) {
  if (!fitCanvas(trace)) return;
  const dpr = Math.min(devicePixelRatio || 1, 2);
  const w = trace.width;
  const h = trace.height;
  tCtx.clearRect(0, 0, w, h);
  tCtx.strokeStyle = COLOR.dim;
  tCtx.lineWidth = dpr;
  tCtx.beginPath();
  for (let i = 0; i < prof.length; i++) {
    const x = (i / Math.max(1, prof.length - 1)) * w;
    const y = h - (prof[i] / 255) * h * 0.86 - h * 0.07;
    i ? tCtx.lineTo(x, y) : tCtx.moveTo(x, y);
  }
  tCtx.stroke();
  const cross = crossSize();
  if (!cross) return;
  const frac = clamp(slitCentre() / cross, 0, 1);
  tCtx.strokeStyle = COLOR.cut;
  tCtx.beginPath();
  tCtx.moveTo(frac * w, 0);
  tCtx.lineTo(frac * w, h);
  tCtx.stroke();
}

const IDLE_VERDICT = 'Carica un video e avvia la scansione. Qui compare lo spostamento reale ' +
  'dell’immagine da un fotogramma al successivo, e se la larghezza della fenditura restituisce ' +
  'proporzioni corrette o deformate.';

function refreshDials() {
  const dEl = $('readD');
  const sEl = $('readScale');
  const vEl = $('verdict');

  if (measured === null) {
    dEl.innerHTML = '—';
    sEl.textContent = '—';
    dEl.className = 'dial-num';
    sEl.className = 'dial-num';
    vEl.innerHTML = IDLE_VERDICT;
    return;
  }

  dEl.innerHTML = `${measured.toFixed(2)}<small>px/fot.</small>`;
  const ratio = S.width / Math.max(measured, 0.001);
  sEl.textContent = ratio >= 1 ? `${ratio.toFixed(2)} ×` : `÷ ${(1 / ratio).toFixed(2)}`;
  const suggest = clamp(Math.round(measured), LIMITS.width[0], LIMITS.width[1]);

  if (measured < 0.35) {
    dEl.className = 'dial-num bad';
    sEl.className = 'dial-num bad';
    vEl.innerHTML = "<b>L'immagine è ferma sotto la fenditura.</b> Se la camera insegue il soggetto è " +
      'previsto: la striscia diventa una banda piatta. Sposta il taglio dove scorre lo sfondo, oppure alza la deriva.';
  } else if (measured > LIMITS.width[1]) {
    dEl.className = 'dial-num warn';
    sEl.className = 'dial-num warn';
    vEl.innerHTML = `Lo spostamento supera i ${LIMITS.width[1]} px per fotogramma, oltre la fenditura più larga ` +
      'possibile: la striscia uscirà schiacciata comunque. Alza il passo di campionamento, oppure la sorgente ' +
      'va ripresa a fotogrammi al secondo più alti.';
  } else if (ratio > 1.6) {
    dEl.className = 'dial-num ok';
    sEl.className = 'dial-num warn';
    vEl.innerHTML = `Fenditura più larga del moto: il soggetto esce <b>stirato</b> di circa ${ratio.toFixed(1)} volte. ` +
      `Porta la larghezza a ${suggest} px per proporzioni corrette.`;
  } else if (ratio < 0.62) {
    dEl.className = 'dial-num ok';
    sEl.className = 'dial-num warn';
    vEl.innerHTML = `Fenditura più stretta del moto: il soggetto esce <b>schiacciato</b> di circa ${(1 / ratio).toFixed(1)} volte. ` +
      `Porta la larghezza a ${suggest} px, oppure riprendi a fotogrammi al secondo più alti.`;
  } else {
    dEl.className = 'dial-num ok';
    sEl.className = 'dial-num ok';
    vEl.innerHTML = '<b>Proporzioni corrette.</b> La larghezza della fetta corrisponde allo spostamento per ' +
      'fotogramma: le forme nella striscia sono quelle del soggetto reale.';
  }
}

/* ───────────────────── disegno delle anteprime ───────────────────── */

function blit(ctx, ox, oy, k) {
  const vertical = S.axis === 'x';
  let off = 0;
  for (const tile of tiles) {
    const len = tile.fill;
    if (!len) continue;
    if (vertical) ctx.drawImage(tile.c, 0, 0, len, outCross, ox + off * k, oy, len * k, outCross * k);
    else ctx.drawImage(tile.c, 0, 0, outCross, len, ox, oy + off * k, outCross * k, len * k);
    off += len;
  }
}

function paintStrip(ctx, ox, oy, k, withMirror) {
  const vertical = S.axis === 'x';
  const L = stripLen * k;
  const flip = () => {
    if (vertical) { ctx.translate(L, 0); ctx.scale(-1, 1); }
    else { ctx.translate(0, L); ctx.scale(1, -1); }
  };

  ctx.save();
  ctx.translate(ox, oy);
  if (S.dir === -1) flip();
  blit(ctx, 0, 0, k);
  ctx.restore();

  if (withMirror && S.mirror) {
    ctx.save();
    ctx.translate(ox, oy);
    if (vertical) { ctx.translate(2 * L, 0); ctx.scale(-1, 1); }
    else { ctx.translate(0, 2 * L); ctx.scale(1, -1); }
    if (S.dir === -1) flip();
    blit(ctx, 0, 0, k);
    ctx.restore();
  }
}

function detailWindow() {
  const vertical = S.axis === 'x';
  const k = vertical
    ? Math.min(1, detail.height / Math.max(1, outCross))
    : Math.min(1, detail.width / Math.max(1, outCross));
  const visible = (vertical ? detail.width : detail.height) / Math.max(k, 1e-6);
  const start = Math.max(0, stripLen - visible);
  return { k, visible, start };
}

function paintDetail() {
  if (!fitCanvas(detail)) return;
  dCtx.clearRect(0, 0, detail.width, detail.height);
  if (!stripLen) return;

  const vertical = S.axis === 'x';
  const { k, start } = detailWindow();

  dCtx.save();
  if (S.dir === -1) {
    if (vertical) { dCtx.translate(detail.width, 0); dCtx.scale(-1, 1); }
    else { dCtx.translate(0, detail.height); dCtx.scale(1, -1); }
  }
  if (vertical) blit(dCtx, -start * k, (detail.height - outCross * k) / 2, k);
  else blit(dCtx, (detail.width - outCross * k) / 2, -start * k, k);
  dCtx.restore();
}

function paintMap() {
  if (!fitCanvas(map)) return;
  mCtx.clearRect(0, 0, map.width, map.height);
  if (!stripLen) return;

  const sz = stripSize(true);
  const k = Math.min(map.width / sz.w, map.height / sz.h);
  const dw = sz.w * k;
  const dh = sz.h * k;
  const ox = (map.width - dw) / 2;
  const oy = (map.height - dh) / 2;

  paintStrip(mCtx, ox, oy, k, true);

  // finestra corrispondente a ciò che il teatro mostra a grandezza naturale
  if (S.axis === 'x') {
    const { visible, start } = detailWindow();
    const x0 = ox + (S.dir === -1 ? (stripLen - start - visible) : start) * k;
    const wRect = Math.min(visible * k, dw);
    mCtx.strokeStyle = COLOR.data;
    mCtx.lineWidth = 1;
    mCtx.strokeRect(clamp(x0, ox, ox + dw) + 0.5, oy + 0.5, Math.max(1, wRect - 1), Math.max(1, dh - 1));
  }
}

/* il righello: converte i pixel dell'uscita in minuti e secondi della sorgente */
function paintRuler() {
  if (!fitCanvas(ruler)) return;
  const dpr = Math.min(devicePixelRatio || 1, 2);
  const w = ruler.width;
  const h = ruler.height;
  rCtx.clearRect(0, 0, w, h);
  rCtx.font = `${Math.round(9 * dpr)}px "Cascadia Mono", Menlo, Consolas, monospace`;
  rCtx.textBaseline = 'alphabetic';

  if (!stripLen) return;

  if (S.axis !== 'x') {
    rCtx.fillStyle = COLOR.dimmer;
    rCtx.fillText('asse temporale verticale — il righello vale per la striscia orizzontale', 10 * dpr, h * 0.62);
    return;
  }

  const { k, visible, start } = detailWindow();
  const timeAt = (p) => {
    if (!marks.length) return 0;
    if (p <= marks[0].p) return marks[0].t;
    for (let i = 1; i < marks.length; i++) {
      if (p <= marks[i].p) {
        const a = marks[i - 1];
        const b = marks[i];
        const f = (p - a.p) / Math.max(1, b.p - a.p);
        return a.t + f * (b.t - a.t);
      }
    }
    return marks[marks.length - 1].t;
  };

  const tStart = timeAt(start);
  const tEnd = timeAt(Math.min(stripLen, start + visible));
  const span = Math.max(0.001, tEnd - tStart);

  // passo dei segni: il primo della scala che dà almeno 90 px fra due tacche
  const steps = [0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600];
  const pxPerSec = (visible * k) / span;
  const stepSec = steps.find((s) => s * pxPerSec >= 90 * dpr) || steps[steps.length - 1];

  rCtx.strokeStyle = COLOR.rule;
  rCtx.lineWidth = 1;
  rCtx.beginPath();
  rCtx.moveTo(0, h - 0.5);
  rCtx.lineTo(w, h - 0.5);
  rCtx.stroke();

  const first = Math.ceil(tStart / stepSec) * stepSec;
  // La scala non può produrre più tacche di quante ne stiano nel righello:
  // con una striscia lunghissima il ciclo poteva girare a vuoto migliaia di
  // volte a ogni ridisegno.
  for (let t = first, guard = 0; t <= tEnd && guard < 512; t += stepSec, guard++) {
    const f = (t - tStart) / span;
    const x = (S.dir === -1 ? 1 - f : f) * w;
    rCtx.strokeStyle = COLOR.dimmer;
    rCtx.beginPath();
    rCtx.moveTo(Math.round(x) + 0.5, h * 0.42);
    rCtx.lineTo(Math.round(x) + 0.5, h);
    rCtx.stroke();
    rCtx.fillStyle = COLOR.dim;
    rCtx.fillText(fmtTime(t), Math.round(x) + 4 * dpr, h * 0.4);
  }

  // testa della scansione
  const headX = S.dir === -1 ? 0 : w;
  rCtx.strokeStyle = COLOR.cut;
  rCtx.lineWidth = 2 * dpr;
  rCtx.beginPath();
  rCtx.moveTo(headX + (S.dir === -1 ? 1 : -1) * dpr, 0);
  rCtx.lineTo(headX + (S.dir === -1 ? 1 : -1) * dpr, h);
  rCtx.stroke();
}

function repaintAll() {
  paintDetail();
  paintMap();
  paintRuler();
}

function refreshStats() {
  $('counter').textContent = `${captured.toLocaleString('it-IT')} fotogrammi`;
  const sz = stripSize(true);
  $('stripSpec').textContent =
    `${sz.w.toLocaleString('it-IT')} × ${sz.h.toLocaleString('it-IT')} px${S.mirror ? ' · specchiata' : ''}`;
  const mb = (stripLen * outCross * 4) / 1048576;
  const el = $('budget');
  el.innerHTML = `memoria in uso <b>${mb.toFixed(0)} MB</b>`;
  el.classList.toggle('over', mb > 1200);
}

/* ───────────────────── ciclo di cattura ───────────────────── */

const hasRVFC = 'requestVideoFrameCallback' in HTMLVideoElement.prototype;
let rvfc = null;
let raf = null;
let tick = 0;
let lastMedia = -1;
let fpsSamples = [];
let seekStop = false;
let fpsFocused = false;
$('ctlFps').addEventListener('focus', () => { fpsFocused = true; });
$('ctlFps').addEventListener('blur', () => { fpsFocused = false; });

function onVideoFrame(_now, meta) {
  if (!running) return;
  if (meta && typeof meta.mediaTime === 'number') {
    if (lastMedia >= 0) {
      const dt = meta.mediaTime - lastMedia;
      if (dt > 0.0005 && dt < 0.25) {
        fpsSamples.push(1 / dt);
        if (fpsSamples.length > 40) fpsSamples.shift();
        if (fpsSamples.length >= 12 && !fpsFocused) {
          const avg = fpsSamples.reduce((a, b) => a + b, 0) / fpsSamples.length;
          $('ctlFps').value = avg.toFixed(3);
          S.fps = avg;
        }
      }
    }
    lastMedia = meta.mediaTime;
  }
  consume();
  if (running) rvfc = video.requestVideoFrameCallback(onVideoFrame);
}

function onAnimFrame() {
  if (!running) return;
  if (video.currentTime !== lastMedia) { lastMedia = video.currentTime; consume(); }
  raf = requestAnimationFrame(onAnimFrame);
}

function consume() {
  if (tick % S.step === 0) {
    // Il riferimento di esposizione è la media dei primi fotogrammi, non il
    // primo: con la condizione precedente il contatore si fermava a uno e il
    // riferimento era un solo campione, quindi sensibile a un lampo qualsiasi.
    if (S.expStab && lumCount < LUM_FRAMES) {
      const l = sampleLuma();
      lumRef = lumRef === null ? l : (lumRef * lumCount + l) / (lumCount + 1);
      lumCount++;
    }
    appendSlit();
    if (captured % 2 === 0) measureMotion();
    if (captured % 4 === 0) { paintDetail(); paintRuler(); refreshDials(); refreshStats(); paintOverlay(); }
    if (captured % 24 === 0) paintMap();
  }
  tick++;
  if (video.ended) halt('fine del video');
}

// Un seek che non arriva mai lasciava la scansione appesa in eterno, senza
// pulsante che rispondesse: qui si aspetta al massimo mezzo secondo e si
// verifica che il tempo sia davvero cambiato.
function seekTo(t) {
  return new Promise((resolve) => {
    let done = false;
    const finish = () => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      video.removeEventListener('seeked', finish);
      resolve();
    };
    const timer = setTimeout(finish, 500);
    video.addEventListener('seeked', finish);
    if (Math.abs(video.currentTime - t) < 1e-6) finish();
    else video.currentTime = t;
  });
}

async function seekScan() {
  const fps = clamp(parseFloat($('ctlFps').value) || 30, LIMITS.fps[0], LIMITS.fps[1]);
  const dt = S.step / fps;
  seekStop = false;
  if (S.expStab && lumRef === null) { lumRef = sampleLuma(); lumCount = LUM_FRAMES; }

  let t = video.currentTime;
  let stalled = 0;
  while (running && !seekStop && t < video.duration) {
    const before = video.currentTime;
    await seekTo(t);
    if (!running || seekStop) break;
    // Se il decodificatore non si muove più, fermarsi con una spiegazione è
    // meglio che riempire la striscia di copie dello stesso fotogramma.
    if (Math.abs(video.currentTime - before) < 1e-4 && t > 0) {
      if (++stalled > 8) { halt('il video non avanza: prova il metodo a riproduzione'); return; }
    } else stalled = 0;

    appendSlit();
    measureMotion();
    if (captured % 3 === 0) {
      paintDetail(); paintRuler(); refreshDials(); refreshStats(); paintOverlay(); refreshTime();
    }
    if (captured % 20 === 0) paintMap();
    t += dt;
  }
  if (running) halt('fine del video');
}

function begin() {
  if (!video.src || exporting || running) return;
  if (!video.videoWidth) { note('nessun video pronto'); return; }
  // Riavviare a video finito partiva dalla fine e si fermava subito, con la
  // sola traccia di un contatore fermo a zero.
  if (video.ended || video.currentTime >= video.duration - 1e-3) video.currentTime = 0;

  running = true;
  $('lamp').dataset.state = 'run';
  $('btnRun').textContent = 'Ferma';
  $('btnSave').disabled = true;
  $('theatreEmpty').style.display = 'none';
  if (!outCross) resetStrip();

  if (S.method === 'seek') {
    video.pause();
    seekScan();
  } else {
    video.playbackRate = S.rate;
    tick = 0;
    lastMedia = -1;
    fpsSamples = [];
    video.play().then(() => {
      if (!running) return;
      if (hasRVFC) rvfc = video.requestVideoFrameCallback(onVideoFrame);
      else raf = requestAnimationFrame(onAnimFrame);
    }).catch(() => halt('riproduzione rifiutata'));
  }
}

function halt(reason) {
  const wasRunning = running;
  running = false;
  seekStop = true;
  try { video.pause(); } catch { /* sorgente non pronta */ }
  if (rvfc && video.cancelVideoFrameCallback) video.cancelVideoFrameCallback(rvfc);
  if (raf) cancelAnimationFrame(raf);
  rvfc = null;
  raf = null;
  $('lamp').dataset.state = video.src ? 'ready' : 'idle';
  $('btnRun').textContent = 'Avvia';
  $('btnSave').disabled = stripLen === 0 || exporting;
  if (wasRunning || stripLen) { repaintAll(); refreshDials(); refreshStats(); }
  if (reason) $('counter').textContent = `${captured.toLocaleString('it-IT')} fotogrammi · ${reason}`;
}

/* ───────────────────── salvataggio ───────────────────── */

function baseName() {
  const stem = mediaPath ? mediaPath.replace(/^.*[\\/]/, '').replace(/\.[^.]+$/, '') : 'striscia';
  return `${stem}-fenditura.png`;
}

function showCurtain(title, detailText) {
  $('curtainTitle').textContent = title;
  $('curtainDetail').textContent = detailText;
  $('barFill').style.width = '0%';
  $('curtain').hidden = false;
  $('lamp').dataset.state = 'busy';
}
function setProgress(f, text) {
  $('barFill').style.width = `${Math.round(clamp(f, 0, 1) * 100)}%`;
  if (text) $('curtainDetail').textContent = text;
}
function hideCurtain() {
  $('curtain').hidden = true;
  $('lamp').dataset.state = video.src ? 'ready' : 'idle';
}

let abortRequested = false;
$('btnAbort').addEventListener('click', () => { abortRequested = true; $('curtainDetail').textContent = 'annullamento…'; });

async function saveStrip(explicitPath) {
  if (!stripLen || exporting || !bench) return null;
  halt('');
  exporting = true;
  abortRequested = false;
  try {
    return S.outMode === 'wrapped' ? await saveWrapped(explicitPath) : await saveSingle(explicitPath);
  } catch (err) {
    $('curtainDetail').textContent = `interrotto: ${err && err.message ? err.message : err}`;
    await new Promise((r) => setTimeout(r, 2200));
    return null;
  } finally {
    exporting = false;
    $('btnSave').disabled = stripLen === 0;
    hideCurtain();
  }
}

async function saveSingle(explicitPath) {
  const sz = stripSize(true);
  const path = explicitPath || await bench.askPngPath(baseName());
  if (!path) return null;

  showCurtain('Scrittura della striscia', `${sz.w.toLocaleString('it-IT')} × ${sz.h.toLocaleString('it-IT')} px`);
  const id = await bench.png.begin(path, sz.w, sz.h);

  try {
    if (S.axis === 'x') await streamAcross(id, sz);
    else await streamAlong(id, sz);
    if (abortRequested) throw new Error('annullato');
    await bench.png.end(id);
    setProgress(1, 'salvata');
    await bench.reveal(path);
    await new Promise((r) => setTimeout(r, 500));
    return path;
  } catch (err) {
    await bench.png.abort(id).catch(() => {});
    throw err;
  }
}

/* striscia orizzontale: le righe del PNG attraversano tutti i tratti */
async function streamAcross(id, sz) {
  const runs = buildRuns();
  const W = sz.w;
  const rowBytes = W * 4;
  const band = clamp(Math.floor(24e6 / rowBytes), 1, 256);

  for (let y0 = 0; y0 < outCross; y0 += band) {
    if (abortRequested) throw new Error('annullato');
    const h = Math.min(band, outCross - y0);
    const out = new Uint8Array(rowBytes * h);

    let x = 0;
    for (const run of runs) {
      const img = run.tile.ctx.getImageData(0, y0, run.count, h).data;
      const runBytes = run.count * 4;
      for (let r = 0; r < h; r++) {
        const src = r * runBytes;
        const dst = r * rowBytes + x * 4;
        if (!run.rev) {
          out.set(img.subarray(src, src + runBytes), dst);
        } else {
          for (let c = 0; c < run.count; c++) {
            const s = src + (run.count - 1 - c) * 4;
            const d = dst + c * 4;
            out[d] = img[s]; out[d + 1] = img[s + 1]; out[d + 2] = img[s + 2]; out[d + 3] = img[s + 3];
          }
        }
      }
      x += run.count;
    }

    await bench.png.rows(id, out, h);
    setProgress((y0 + h) / outCross,
      `riga ${(y0 + h).toLocaleString('it-IT')} di ${outCross.toLocaleString('it-IT')}`);
    await nextFrame();
  }
}

/* striscia verticale: le righe del PNG scorrono lungo l'asse del tempo */
async function streamAlong(id, sz) {
  const runs = buildRuns();
  const rowBytes = outCross * 4;
  const chunk = clamp(Math.floor(24e6 / rowBytes), 1, 2048);
  let done = 0;

  for (const run of runs) {
    if (!run.rev) {
      for (let off = 0; off < run.count; off += chunk) {
        if (abortRequested) throw new Error('annullato');
        const n = Math.min(chunk, run.count - off);
        const img = run.tile.ctx.getImageData(0, off, outCross, n).data;
        await bench.png.rows(id, img, n);
        done += n;
        setProgress(done / sz.h, `riga ${done.toLocaleString('it-IT')} di ${sz.h.toLocaleString('it-IT')}`);
        await nextFrame();
      }
    } else {
      for (let off = run.count; off > 0; off -= chunk) {
        if (abortRequested) throw new Error('annullato');
        const n = Math.min(chunk, off);
        const img = run.tile.ctx.getImageData(0, off - n, outCross, n).data;
        const out = new Uint8Array(rowBytes * n);
        for (let r = 0; r < n; r++) {
          const s = (n - 1 - r) * rowBytes;
          out.set(img.subarray(s, s + rowBytes), r * rowBytes);
        }
        await bench.png.rows(id, out, n);
        done += n;
        setProgress(done / sz.h, `riga ${done.toLocaleString('it-IT')} di ${sz.h.toLocaleString('it-IT')}`);
        await nextFrame();
      }
    }
  }
}

/* impaginazione a righe: la striscia tagliata e impilata, come si stamperebbe */
async function saveWrapped(explicitPath) {
  const vertical = S.axis === 'x';
  const total = stripLen * (S.mirror ? 2 : 1);
  const seg = Math.min(S.seg, total);
  const count = Math.max(1, Math.ceil(total / seg));
  const gap = 10;

  const cw = vertical ? seg : count * outCross + (count - 1) * gap;
  const ch = vertical ? count * outCross + (count - 1) * gap : seg;

  if (cw > 16000 || ch > 16000 || cw * ch > 200e6) {
    throw new Error('impaginazione troppo grande: allunga la riga o riduci la scala di uscita');
  }

  const path = explicitPath || await bench.askPngPath(baseName().replace('.png', '-impaginata.png'));
  if (!path) return null;

  showCurtain('Impaginazione', `${count} righe da ${seg.toLocaleString('it-IT')} px`);

  const cv = document.createElement('canvas');
  cv.width = cw;
  cv.height = ch;
  const ctx = cv.getContext('2d');
  ctx.fillStyle = '#000';
  ctx.fillRect(0, 0, cw, ch);

  for (let i = 0; i < count; i++) {
    if (abortRequested) throw new Error('annullato');
    ctx.save();
    if (vertical) {
      ctx.beginPath();
      ctx.rect(0, i * (outCross + gap), seg, outCross);
      ctx.clip();
      ctx.translate(0, i * (outCross + gap));
      paintStrip(ctx, -i * seg, 0, 1, true);
    } else {
      ctx.beginPath();
      ctx.rect(i * (outCross + gap), 0, outCross, seg);
      ctx.clip();
      ctx.translate(i * (outCross + gap), 0);
      paintStrip(ctx, 0, -i * seg, 1, true);
    }
    ctx.restore();
    setProgress((i + 1) / count, `riga ${i + 1} di ${count}`);
    await nextFrame();
  }

  const blob = await new Promise((res) => cv.toBlob(res, 'image/png'));
  if (!blob) throw new Error('il browser non è riuscito a codificare questa immagine');
  const buf = new Uint8Array(await blob.arrayBuffer());
  await bench.writeBuffer(path, buf);
  setProgress(1, 'salvata');
  await bench.reveal(path);
  await new Promise((r) => setTimeout(r, 500));
  return path;
}

/* ───────────────────── impostazioni salvabili ───────────────────── */

async function savePreset() {
  if (!bench) return;
  const p = await bench.askPresetPath('fenditura.json');
  if (!p) return;
  await bench.writeText(p, JSON.stringify(S, null, 2));
  note('impostazioni salvate');
}

// Un file di impostazioni scritto a mano, o rimasto da una versione diversa,
// non deve poter mettere l'app in uno stato impossibile: ogni valore viene
// riportato dentro i limiti dei comandi che lo rappresentano.
function sanitise(data) {
  const num = (v, [lo, hi], fallback) => {
    const n = typeof v === 'number' ? v : parseFloat(v);
    return Number.isFinite(n) ? clamp(n, lo, hi) : fallback;
  };
  const out = { ...S };
  if (data.axis === 'x' || data.axis === 'y') out.axis = data.axis;
  if (data.dir === 1 || data.dir === -1) out.dir = data.dir;
  if (data.method === 'play' || data.method === 'seek') out.method = data.method;
  if (data.outMode === 'single' || data.outMode === 'wrapped') out.outMode = data.outMode;
  out.mirror = !!data.mirror;
  out.expStab = !!data.expStab;
  out.pos = num(data.pos, LIMITS.pos, S.pos);
  out.width = Math.round(num(data.width, LIMITS.width, S.width));
  out.drift = num(data.drift, LIMITS.drift, S.drift);
  out.scale = num(data.scale, LIMITS.scale, S.scale);
  out.step = Math.round(num(data.step, LIMITS.step, S.step));
  out.rate = num(data.rate, LIMITS.rate, S.rate);
  out.fps = num(data.fps, LIMITS.fps, S.fps);
  out.maxLen = Math.round(num(data.maxLen, LIMITS.maxLen, S.maxLen));
  out.seg = Math.round(num(data.seg, LIMITS.seg, S.seg));
  return out;
}

function applyPreset(data) {
  if (!data || typeof data !== 'object') return false;
  Object.assign(S, sanitise(data));
  syncControls();
  halt('');
  resetStrip();
  return true;
}

async function loadPreset() {
  if (!bench) return;
  const data = await bench.openPreset();
  if (!data) return;
  if (data.__error) { note(data.__error); return; }
  applyPreset(data);
  note('impostazioni caricate');
}

function syncControls() {
  $('ctlPos').value = Math.round(S.pos * 10000);
  $('ctlPosV').textContent = `${(S.pos * 100).toFixed(1)} %`;
  $('ctlWidth').value = S.width;
  $('ctlWidthV').textContent = `${S.width} px`;
  $('ctlDrift').value = Math.round(S.drift * 100);
  $('ctlDriftV').textContent = `${S.drift.toFixed(2)} px/fot.`;
  $('ctlAxis').value = S.axis;
  $('ctlScale').value = Math.round(S.scale * 100);
  $('ctlScaleV').textContent = `${Math.round(S.scale * 100)} %`;
  $('ctlMirror').checked = S.mirror;
  $('ctlStep').value = S.step;
  $('ctlStepV').textContent = String(S.step);
  $('ctlMethod').value = S.method;
  $('ctlRate').value = Math.round(S.rate * 100);
  $('ctlRateV').textContent = `${S.rate.toFixed(1)} ×`;
  $('ctlFps').value = S.fps;
  $('ctlExp').checked = S.expStab;
  $('ctlMax').value = S.maxLen;
  $('ctlOut').value = S.outMode;
  $('ctlSeg').value = S.seg;
  $('ctlSegV').textContent = `${S.seg} px`;
  $('wrapRow').hidden = S.outMode !== 'wrapped';
  overlay.style.cursor = S.axis === 'x' ? 'ew-resize' : 'ns-resize';
  [...$('ctlDir').children].forEach((b) => b.setAttribute('aria-pressed', String(parseInt(b.dataset.v, 10) === S.dir)));
  paintOverlay();
}

/* ───────────────────── collegamento comandi ───────────────────── */

function bindRange(id, apply, format) {
  const el = $(id);
  const out = $(`${id}V`);
  el.addEventListener('input', () => {
    const v = parseFloat(el.value);
    if (!Number.isFinite(v)) return;
    apply(v);
    if (out) out.textContent = format(v);
    paintOverlay();
    refreshDials();
  });
}

bindRange('ctlPos', (v) => { S.pos = v / 10000; }, (v) => `${(v / 100).toFixed(1)} %`);
bindRange('ctlWidth', (v) => { S.width = v; }, (v) => `${v} px`);
bindRange('ctlDrift', (v) => { S.drift = v / 100; }, (v) => `${(v / 100).toFixed(2)} px/fot.`);
bindRange('ctlStep', (v) => { S.step = v; }, (v) => String(v));
bindRange('ctlRate', (v) => {
  S.rate = v / 100;
  if (!video.paused) video.playbackRate = S.rate;
}, (v) => `${(v / 100).toFixed(1)} ×`);
bindRange('ctlSeg', (v) => { S.seg = v; }, (v) => `${v} px`);

// La scala cambia le dimensioni delle piastrelle, quindi svuota la striscia.
// Farlo a ogni movimento del cursore la azzerava decine di volte durante un
// solo trascinamento: ora si applica quando il cursore viene rilasciato.
$('ctlScale').addEventListener('input', () => {
  $('ctlScaleV').textContent = `${$('ctlScale').value} %`;
});
$('ctlScale').addEventListener('change', () => {
  const v = parseFloat($('ctlScale').value);
  if (!Number.isFinite(v)) return;
  S.scale = clamp(v / 100, LIMITS.scale[0], LIMITS.scale[1]);
  if (!video.videoWidth) return;
  const had = stripLen > 0;
  halt('');
  resetStrip();
  if (had) note('striscia svuotata: la scala cambia le dimensioni della tela');
});

$('ctlAxis').addEventListener('change', (e) => {
  S.axis = e.target.value === 'y' ? 'y' : 'x';
  overlay.style.cursor = S.axis === 'x' ? 'ew-resize' : 'ns-resize';
  halt('');
  resetStrip();
  paintOverlay();
});
$('ctlMethod').addEventListener('change', (e) => { S.method = e.target.value === 'seek' ? 'seek' : 'play'; halt(''); });
$('ctlFps').addEventListener('change', (e) => {
  S.fps = clamp(parseFloat(e.target.value) || 30, LIMITS.fps[0], LIMITS.fps[1]);
  e.target.value = S.fps;
});
$('ctlMax').addEventListener('change', (e) => {
  S.maxLen = Math.round(clamp(parseInt(e.target.value, 10) || 120000, LIMITS.maxLen[0], LIMITS.maxLen[1]));
  e.target.value = S.maxLen;
});
$('ctlMirror').addEventListener('change', (e) => { S.mirror = e.target.checked; repaintAll(); refreshStats(); });
$('ctlExp').addEventListener('change', (e) => {
  S.expStab = e.target.checked;
  if (!S.expStab) { lumRef = null; lumCount = 0; }
});
$('ctlOut').addEventListener('change', (e) => {
  S.outMode = e.target.value === 'wrapped' ? 'wrapped' : 'single';
  $('wrapRow').hidden = S.outMode !== 'wrapped';
});
$('ctlDir').addEventListener('click', (e) => {
  const b = e.target.closest('button');
  if (!b) return;
  [...$('ctlDir').children].forEach((x) => x.setAttribute('aria-pressed', String(x === b)));
  S.dir = parseInt(b.dataset.v, 10) === -1 ? -1 : 1;
  repaintAll();
});

function matchWidth() {
  if (measured === null) return;
  S.width = clamp(Math.round(measured), LIMITS.width[0], LIMITS.width[1]);
  $('ctlWidth').value = S.width;
  $('ctlWidthV').textContent = `${S.width} px`;
  paintOverlay();
  refreshDials();
}

function clearStrip() {
  halt('');
  resetStrip();
  note('0 fotogrammi');
}

$('btnOpen').addEventListener('click', pickVideo);
$('btnRun').addEventListener('click', () => (running ? halt('') : begin()));
$('btnClear').addEventListener('click', clearStrip);
$('btnSave').addEventListener('click', () => saveStrip());
$('btnMatch').addEventListener('click', matchWidth);
$('btnPresetSave').addEventListener('click', savePreset);
$('btnPresetLoad').addEventListener('click', loadPreset);

if (bench) {
  bench.onMenu((what) => {
    if (what === 'open') pickVideo();
    if (what === 'save') saveStrip();
    if (what === 'toggle') (running ? halt('') : begin());
    if (what === 'clear') clearStrip();
    if (what === 'match') matchWidth();
    if (what === 'presetSave') savePreset();
    if (what === 'presetLoad') loadPreset();
  });
}

window.addEventListener('keydown', (e) => {
  const t = e.target;
  // Un evento di tastiera può arrivare con document come bersaglio, che non
  // ha matches: senza questo controllo la scorciatoia lanciava un errore.
  if (t && typeof t.matches === 'function' && t.matches('input,select,button,textarea')) return;
  if (!video.videoWidth) return;

  // La barra spaziatrice avvia e ferma, ma solo qui: come acceleratore di
  // menu avrebbe la precedenza su qualunque campo della finestra.
  if (e.key === ' ' || e.code === 'Space') {
    running ? halt('') : begin();
    e.preventDefault();
    return;
  }

  const cross = crossSize();
  if (!cross) return;
  const fine = e.shiftKey ? 10 : 1;
  if (e.key === 'ArrowLeft' || e.key === 'ArrowRight') {
    S.pos = clamp(S.pos + (e.key === 'ArrowRight' ? fine : -fine) / cross, 0, 1);
    $('ctlPos').value = Math.round(S.pos * 10000);
    $('ctlPosV').textContent = `${(S.pos * 100).toFixed(1)} %`;
    paintOverlay();
    e.preventDefault();
  }
});

syncControls();
repaintAll();

/* ───────────────────── superficie per le prove ─────────────────────

   Il banco di prova in test/ esegue proprio questo file, così le prove
   verificano il codice spedito e non una copia che gli somiglia. */

window.__fenditura = {
  state: () => ({ ...S }),
  set: (patch) => { Object.assign(S, patch); syncControls(); },
  applyPreset,
  attach,
  captureOnce: () => consume(),
  measured: () => measured,
  stripLen: () => stripLen,
  stripSize: () => stripSize(true),
  lumSamples: () => lumCount,
  saveTo: (p) => saveStrip(p),
  reset: resetStrip
};
