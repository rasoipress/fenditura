'use strict';

// Scrittore PNG incrementale.
//
// Il motivo per cui esiste: un canvas del browser non può superare circa
// 32.000 px per lato, e una striscia slit-scan da un video lungo li supera
// facilmente. Qui le righe arrivano a blocchi dal processo di rendering e
// vengono compresse e scritte su disco man mano, senza che l'immagine intera
// esista mai in memoria. La lunghezza massima diventa quella del disco.

const fs = require('fs');
const zlib = require('zlib');

const SIGNATURE = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

const CRC_TABLE = (() => {
  const t = new Int32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c;
  }
  return t;
})();

function crc32(buf) {
  let c = -1;
  for (let i = 0; i < buf.length; i++) c = CRC_TABLE[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return (c ^ -1) >>> 0;
}

function chunk(type, data) {
  const body = Buffer.concat([Buffer.from(type, 'latin1'), data]);
  const out = Buffer.allocUnsafe(body.length + 8);
  out.writeUInt32BE(data.length, 0);
  body.copy(out, 4);
  out.writeUInt32BE(crc32(body), body.length + 4);
  return out;
}

class PngWriter {
  constructor(filePath, width, height) {
    if (!Number.isInteger(width) || width < 1) throw new Error('larghezza non valida');
    if (!Number.isInteger(height) || height < 1) throw new Error('altezza non valida');

    this.filePath = filePath;
    this.width = width;
    this.height = height;
    this.bytesPerRow = width * 4;
    this.rowsWritten = 0;
    this.closed = false;
    this.error = null;

    this.out = fs.createWriteStream(filePath);
    this.deflate = zlib.createDeflate({ level: 6, chunkSize: 1 << 18 });

    // Un errore su uno dei due flussi deve svegliare chiunque stia aspettando
    // un evento che non arriverà più: senza questo, un disco pieno o un
    // percorso non scrivibile lasciano il salvataggio appeso per sempre.
    this.waiters = new Set();
    const fail = (e) => {
      this.error = this.error || e;
      for (const w of this.waiters) w();
      this.waiters.clear();
    };
    this.out.on('error', fail);
    this.deflate.on('error', fail);

    // I blocchi compressi vanno sul file rispettando la contropressione: se il
    // disco è più lento della compressione, la coda si ferma invece di
    // gonfiarsi in memoria, che è esattamente ciò che questo scrittore evita.
    this.deflate.on('data', (d) => {
      if (!this.out.write(chunk('IDAT', d))) {
        this.deflate.pause();
        this.out.once('drain', () => this.deflate.resume());
      }
    });
    this.deflateEnded = this.wait(this.deflate, 'end');

    const ihdr = Buffer.allocUnsafe(13);
    ihdr.writeUInt32BE(width, 0);
    ihdr.writeUInt32BE(height, 4);
    ihdr[8] = 8;   // 8 bit per canale
    ihdr[9] = 6;   // RGBA
    ihdr[10] = 0;  // compressione deflate
    ihdr[11] = 0;  // filtro adattivo
    ihdr[12] = 0;  // non interlacciato

    this.out.write(SIGNATURE);
    this.out.write(chunk('IHDR', ihdr));
  }

  // Attesa di un evento che si sblocca anche in caso di errore.
  wait(emitter, event) {
    return new Promise((resolve) => {
      const done = () => { this.waiters.delete(done); emitter.removeListener(event, done); resolve(); };
      this.waiters.add(done);
      emitter.once(event, done);
    });
  }

  // raw: Buffer/Uint8Array con rowCount righe RGBA contigue
  async writeRows(raw, rowCount) {
    if (this.closed) throw new Error('scrittore già chiuso');
    if (this.error) throw this.error;

    const bpr = this.bytesPerRow;
    if (raw.length < rowCount * bpr) throw new Error('blocco di righe più corto del previsto');

    const line = Buffer.allocUnsafe(bpr + 1);
    for (let r = 0; r < rowCount; r++) {
      if (this.rowsWritten >= this.height) break;
      const off = r * bpr;
      // Filtro 1 (Sub): differenza con il pixel a sinistra. Su una striscia
      // fotografica riduce il file di circa un terzo rispetto a nessun filtro,
      // e costa una sottrazione per byte.
      line[0] = 1;
      line[1] = raw[off];
      line[2] = raw[off + 1];
      line[3] = raw[off + 2];
      line[4] = raw[off + 3];
      for (let i = 4; i < bpr; i++) line[i + 1] = (raw[off + i] - raw[off + i - 4]) & 0xff;

      // il buffer viene riusato, quindi la copia la fa deflate: si passa una
      // vista nuova solo quando la scrittura non è immediata
      if (!this.deflate.write(Buffer.from(line))) await this.wait(this.deflate, 'drain');
      if (this.error) throw this.error;
      this.rowsWritten++;
    }
  }

  async end() {
    if (this.closed) return;
    this.closed = true;
    if (this.error) { await this.discard(); throw this.error; }

    // Se il chiamante ha inviato meno righe di quelle dichiarate, riempie il
    // resto di nero: un PNG troncato non è leggibile da nessun programma.
    if (this.rowsWritten < this.height) {
      const line = Buffer.alloc(this.bytesPerRow + 1);
      while (this.rowsWritten < this.height) {
        if (!this.deflate.write(Buffer.from(line))) await this.wait(this.deflate, 'drain');
        if (this.error) break;
        this.rowsWritten++;
      }
    }

    this.deflate.end();
    await this.deflateEnded;
    if (!this.error) this.out.write(chunk('IEND', Buffer.alloc(0)));
    await new Promise((resolve) => this.out.end(resolve));
    if (this.error) { await this.discard(); throw this.error; }
  }

  // Annullamento: il file parziale non deve restare sul disco dell'utente,
  // perché un PNG senza IEND non si apre e sembra soltanto un file rotto.
  async abort() {
    if (this.closed) return;
    this.closed = true;
    this.deflate.destroy();
    await new Promise((resolve) => this.out.close(resolve));
    await this.discard();
  }

  async discard() {
    await new Promise((resolve) => fs.unlink(this.filePath, () => resolve()));
  }
}

module.exports = PngWriter;
