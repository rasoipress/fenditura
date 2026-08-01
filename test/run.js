'use strict';

/* Prove automatiche. Nessun assunto sull'ambiente grafico: si eseguono con
   `npm test` su qualunque macchina con Node 18 o successivo. */

const fs = require('fs');
const os = require('os');
const path = require('path');
const { PNG } = require('pngjs');
const PngWriter = require('../electron/png-writer.js');
const { boot } = require('./harness.js');

const OUT = fs.mkdtempSync(path.join(os.tmpdir(), 'fenditura-'));
let pass = 0;
let fail = 0;

function check(name, cond, extra) {
  if (cond) { pass++; console.log(`  ok   ${name}`); }
  else { fail++; console.log(`  FALLITA  ${name}${extra ? `\n         ${extra}` : ''}`); }
}
function near(a, b, tol) { return Math.abs(a - b) <= tol; }

/* ══════════════════ 1. scrittore PNG ══════════════════ */

async function testPngWriter() {
  console.log('\nscrittore PNG incrementale');

  const W = 4000;
  const H = 61;
  const file = path.join(OUT, 'writer.png');
  const w = new PngWriter(file, W, H);

  const expect = Buffer.alloc(W * H * 4);
  let y = 0;
  while (y < H) {
    const n = Math.min(7, H - y);
    const block = Buffer.alloc(W * 4 * n);
    for (let r = 0; r < n; r++) {
      for (let x = 0; x < W; x++) {
        const o = (r * W + x) * 4;
        const v = [(x * 7 + (y + r) * 13) & 255, (x ^ (y + r)) & 255, (x * 3) & 255, 255];
        block[o] = v[0]; block[o + 1] = v[1]; block[o + 2] = v[2]; block[o + 3] = v[3];
        const e = ((y + r) * W + x) * 4;
        expect[e] = v[0]; expect[e + 1] = v[1]; expect[e + 2] = v[2]; expect[e + 3] = v[3];
      }
    }
    await w.writeRows(block, n);
    y += n;
  }
  await w.end();

  const png = PNG.sync.read(fs.readFileSync(file));
  check('dimensioni rilette', png.width === W && png.height === H, `${png.width}×${png.height}`);
  let bad = 0;
  for (let i = 0; i < 4000; i++) {
    const px = (Math.random() * W) | 0;
    const py = (Math.random() * H) | 0;
    const o = (py * W + px) * 4;
    for (let c = 0; c < 4; c++) if (png.data[o + c] !== expect[o + c]) bad++;
  }
  check('4000 pixel a caso identici all_originale', bad === 0, `${bad} byte diversi`);

  // righe mancanti: il file deve restare leggibile
  const short = path.join(OUT, 'short.png');
  const w2 = new PngWriter(short, 32, 10);
  await w2.writeRows(Buffer.alloc(32 * 4 * 3, 200), 3);
  await w2.end();
  const p2 = PNG.sync.read(fs.readFileSync(short));
  check('PNG completato con righe mancanti', p2.height === 10 && p2.data[0] === 200);

  // annullamento: nessun file parziale lasciato in giro
  const aborted = path.join(OUT, 'aborted.png');
  const w3 = new PngWriter(aborted, 32, 1000);
  await w3.writeRows(Buffer.alloc(32 * 4 * 2, 9), 2);
  await w3.abort();
  check('il file annullato viene rimosso', !fs.existsSync(aborted));

  // percorso impossibile: errore chiaro, non blocco
  let threw = false;
  try {
    const w4 = new PngWriter(path.join(OUT, 'non-esiste', 'x.png'), 8, 8);
    await w4.writeRows(Buffer.alloc(8 * 4, 1), 1);
    await w4.end();
  } catch { threw = true; }
  check('percorso non scrivibile solleva un errore', threw);
}

/* ══════════════════ 2. misura del moto ══════════════════ */

function testMotion(shift, step) {
  const env = boot({ outDir: OUT, video: { shift, frames: 400, w: 320, h: 90 } });
  const { window, video } = env;
  const S = window.__fenditura;

  S.set({ step, width: 4, scale: 1, method: 'play' });
  video.el.dispatchEvent(new window.Event('loadedmetadata'));

  // un giro per fotogramma sorgente: consume() cattura uno ogni `step`
  for (let i = 0; i < 40 * step; i++) {
    S.captureOnce();
    video.advance(1);
  }
  return { env, measured: S.measured() };
}

function testMotionAll() {
  console.log('\nmisura del moto');
  for (const [shift, step] of [[6, 1], [6, 2], [12, 1], [3, 4]]) {
    const { measured } = testMotion(shift, step);
    // ciò che conta è lo spostamento fra due fette consecutive della
    // striscia, cioè fra due fotogrammi catturati
    const want = shift * step;
    check(
      `sorgente ${shift} px/fot., un fotogramma ogni ${step} → atteso ${want} px per fetta`,
      measured !== null && near(measured, want, Math.max(1.5, want * 0.2)),
      `misurato ${measured === null ? 'niente' : measured.toFixed(2)}`
    );
  }
}

/* ══════════════════ 3. accumulo e salvataggio ══════════════════ */

async function testExport() {
  console.log('\naccumulo e salvataggio');

  for (const axis of ['x', 'y']) {
    for (const dir of [1, -1]) {
      for (const mirror of [false, true]) {
        const env = boot({ outDir: OUT, video: { shift: 5, frames: 80, w: 64, h: 40 } });
        const { window, video } = env;
        const S = window.__fenditura;
        S.set({ axis, dir, mirror, width: 3, scale: 1, method: 'play' });
        video.el.dispatchEvent(new window.Event('loadedmetadata'));
        for (let i = 0; i < 40; i++) { S.captureOnce(); video.advance(1); }

        const spec = S.stripSize();
        const file = await S.saveTo(path.join(OUT, `strip-${axis}-${dir}-${mirror}.png`));
        const png = PNG.sync.read(fs.readFileSync(file));
        check(
          `striscia asse ${axis} verso ${dir}${mirror ? ' specchiata' : ''}: ${spec.w}×${spec.h}`,
          png.width === spec.w && png.height === spec.h,
          `il PNG è ${png.width}×${png.height}`
        );
        let opaque = true;
        for (let i = 3; i < png.data.length; i += 4 * 997) if (png.data[i] !== 255) { opaque = false; break; }
        check(`  nessun buco trasparente (${axis}/${dir}/${mirror})`, opaque);
      }
    }
  }

  // la specchiatura deve essere davvero un ribaltamento
  const env = boot({ outDir: OUT, video: { shift: 5, frames: 60, w: 64, h: 24 } });
  const S = env.window.__fenditura;
  S.set({ axis: 'x', dir: 1, mirror: true, width: 4, scale: 1 });
  env.video.el.dispatchEvent(new env.window.Event('loadedmetadata'));
  for (let i = 0; i < 20; i++) { S.captureOnce(); env.video.advance(1); }
  const f = await S.saveTo(path.join(OUT, 'mirror.png'));
  const p = PNG.sync.read(fs.readFileSync(f));
  const row = 5;
  let sym = 0;
  for (let x = 0; x < p.width / 2; x++) {
    const a = (row * p.width + x) * 4;
    const b = (row * p.width + (p.width - 1 - x)) * 4;
    if (p.data[a] !== p.data[b]) sym++;
  }
  check('la meta specchiata e il riflesso esatto della prima', sym === 0, `${sym} colonne diverse`);
}

/* ══════════════════ 3b. la striscia oltre una piastrella ══════════════════

   La striscia vive in piastrelle da 4096 px. Finché una prova resta dentro la
   prima, il codice che le ricuce non viene mai eseguito. Qui la striscia ne
   attraversa più d'una, e con una fetta che 4096 non divide: è il caso in cui
   ogni piastrella si chiude con una frangia mai disegnata. */

async function testTiles() {
  console.log('\nstriscia su più piastrelle');

  for (const [axis, dir, mirror, w] of [
    ['x', 1, false, 24], ['x', -1, false, 24], ['x', 1, true, 24],
    ['y', 1, false, 24], ['y', -1, true, 24], ['x', 1, false, 5]
  ]) {
    const env = boot({ outDir: OUT, video: { shift: 4, frames: 5000, w: 96, h: 32 } });
    const S = env.window.__fenditura;
    S.set({ axis, dir, mirror, width: w, scale: 1, method: 'play', maxLen: 2000000 });
    env.video.el.dispatchEvent(new env.window.Event('loadedmetadata'));

    const captures = Math.ceil(4600 / w) + 40;   // oltre 4096 px, con avanzo
    for (let i = 0; i < captures; i++) { S.captureOnce(); env.video.advance(1); }

    check(`${axis}/${dir}/${mirror} fetta ${w} px: supera una piastrella`, S.stripLen() > 4096, `${S.stripLen()} px`);

    const spec = S.stripSize();
    const file = await S.saveTo(path.join(OUT, `tile-${axis}${dir}${mirror}-${w}.png`));
    check(`  salvataggio riuscito (${axis}/${dir}/${mirror}/${w})`, !!file, 'nessun file scritto');
    if (!file) continue;

    const png = PNG.sync.read(fs.readFileSync(file));
    check(`  dimensioni ${spec.w}×${spec.h} rispettate`,
      png.width === spec.w && png.height === spec.h, `ottenuto ${png.width}×${png.height}`);

    // Una fascia interamente nera lungo l'asse del tempo è tela mai disegnata:
    // byte promessi allo scrittore e riempiti da lui, non fotogrammi.
    let empty = 0;
    const long = axis === 'x' ? png.width : png.height;
    for (let i = 0; i < long; i++) {
      let sum = 0;
      if (axis === 'x') for (let y = 0; y < png.height; y++) sum += png.data[(y * png.width + i) * 4];
      else for (let x = 0; x < png.width; x++) sum += png.data[(i * png.width + x) * 4];
      if (sum === 0) empty++;
    }
    check(`  nessuna fascia di tela vuota (${axis}/${dir}/${mirror}/${w})`, empty === 0, `${empty} fasce nere`);
  }
}

/* ══════════════════ 3c. impaginazione a righe ══════════════════ */

async function testWrapped() {
  console.log('\nimpaginazione a righe');
  const gap = 10;

  for (const [axis, dir, mirror] of [['x', 1, false], ['x', -1, false], ['x', 1, true], ['y', 1, false]]) {
    const env = boot({ outDir: OUT, video: { shift: 4, frames: 900, w: 96, h: 30 } });
    const S = env.window.__fenditura;
    S.set({ axis, dir, mirror, width: 6, scale: 1, outMode: 'wrapped', seg: 900, maxLen: 2000000 });
    env.video.el.dispatchEvent(new env.window.Event('loadedmetadata'));
    for (let i = 0; i < 400; i++) { S.captureOnce(); env.video.advance(1); }

    const total = S.stripLen() * (mirror ? 2 : 1);
    const seg = Math.min(900, total);
    const rows = Math.max(1, Math.ceil(total / seg));
    const cross = axis === 'x' ? 30 : 96;
    const wantW = axis === 'x' ? seg : rows * cross + (rows - 1) * gap;
    const wantH = axis === 'x' ? rows * cross + (rows - 1) * gap : seg;

    const file = await S.saveTo(path.join(OUT, `wrap-${axis}${dir}${mirror}.png`));
    check(`${axis}/${dir}/${mirror}: ${rows} righe da ${seg} px`, !!file, 'nessun file scritto');
    if (!file) continue;

    const png = PNG.sync.read(fs.readFileSync(file));
    check(`  foglio ${wantW}×${wantH}`, png.width === wantW && png.height === wantH,
      `ottenuto ${png.width}×${png.height}`);

    // ogni riga impaginata deve contenere immagine, non solo il fondo nero
    let blank = 0;
    for (let r = 0; r < rows; r++) {
      let sum = 0;
      const x0 = axis === 'x' ? 0 : r * (cross + gap);
      const y0 = axis === 'x' ? r * (cross + gap) : 0;
      const w = axis === 'x' ? Math.min(seg, png.width) : cross;
      const h = axis === 'x' ? cross : Math.min(seg, png.height);
      for (let y = y0; y < y0 + h; y += 3) {
        for (let x = x0; x < x0 + w; x += 3) sum += png.data[(y * png.width + x) * 4];
      }
      if (sum === 0) blank++;
    }
    check(`  nessuna riga impaginata vuota (${axis}/${dir}/${mirror})`, blank === 0, `${blank} righe nere`);
  }

  // Il limite di superficie deve fermare l'impaginazione con un messaggio,
  // non farla fallire a metà. Qui il foglio supererebbe i 16.000 px di lato:
  // 18 righe alte 1000 px ciascuna.
  const env = boot({ outDir: OUT, video: { shift: 4, frames: 900, w: 1000, h: 40 } });
  const S = env.window.__fenditura;
  S.set({ axis: 'y', width: 96, scale: 1, outMode: 'wrapped', seg: 800, maxLen: 2000000 });
  env.video.el.dispatchEvent(new env.window.Event('loadedmetadata'));
  for (let i = 0; i < 350; i++) { S.captureOnce(); env.video.advance(1); }

  const sheetSide = Math.ceil(S.stripLen() / 800) * 1000;
  check(`il foglio richiesto sarebbe ${sheetSide} px di lato`, sheetSide > 16000, String(sheetSide));

  const target = path.join(OUT, 'wrap-troppo-grande.png');
  const res = await S.saveTo(target);
  check('impaginazione fuori misura rifiutata', res === null, `ha restituito ${res}`);
  check('  nessun file lasciato sul disco', !fs.existsSync(target));
  check('  nessun errore non gestito dopo il rifiuto', env.errors.length === 0, env.errors.join('; '));
}

/* ══════════════════ 4. stato e comandi ══════════════════ */

async function testState() {
  console.log('\nstato e comandi');

  const env = boot({ outDir: OUT, video: { shift: 5, frames: 60 } });
  const { window, video } = env;
  const S = window.__fenditura;
  video.el.dispatchEvent(new window.Event('loadedmetadata'));

  for (let i = 0; i < 12; i++) { S.captureOnce(); video.advance(1); }
  check('la striscia si e accumulata', S.stripLen() > 0);

  S.attach({ path: '/tmp/altro.mp4', name: 'altro.mp4', url: 'strip://local/media?p=x' });
  check('caricare un altro video svuota la striscia', S.stripLen() === 0);

  // preset con valori assurdi: non devono passare
  S.applyPreset({ axis: 'diagonale', width: 1e9, scale: -4, step: 0, maxLen: 'molti', dir: 7, pos: 40 });
  const st = S.state();
  check('asse non valido rifiutato', st.axis === 'x' || st.axis === 'y', st.axis);
  check('larghezza riportata nei limiti', st.width >= 1 && st.width <= 96, String(st.width));
  check('scala riportata nei limiti', st.scale > 0 && st.scale <= 1, String(st.scale));
  check('passo riportato nei limiti', st.step >= 1 && st.step <= 16, String(st.step));
  check('lunghezza massima numerica', Number.isFinite(st.maxLen) && st.maxLen > 0, String(st.maxLen));
  check('verso solo 1 o -1', st.dir === 1 || st.dir === -1, String(st.dir));
  check('posizione fra 0 e 1', st.pos >= 0 && st.pos <= 1, String(st.pos));

  check('nessun errore non gestito', env.errors.length === 0, env.errors.join('; '));
}

/* ══════════════════ 5. stabilizzazione esposizione ══════════════════ */

async function testExposure() {
  console.log('\nstabilizzazione esposizione');
  const env = boot({ outDir: OUT, video: { shift: 5, frames: 60 } });
  const S = env.window.__fenditura;
  S.set({ expStab: true });
  env.video.el.dispatchEvent(new env.window.Event('loadedmetadata'));
  for (let i = 0; i < 20; i++) { S.captureOnce(); env.video.advance(1); }
  const n = S.lumSamples();
  check('il riferimento e la media dei primi fotogrammi, non del primo', n >= 8, `${n} campioni`);
}

/* ══════════════════ esecuzione ══════════════════ */

(async () => {
  await testPngWriter();
  testMotionAll();
  await testExport();
  await testTiles();
  await testWrapped();
  await testState();
  await testExposure();
  console.log(`\n${pass} superate, ${fail} fallite`);
  fs.rmSync(OUT, { recursive: true, force: true });
  process.exit(fail ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(1); });
