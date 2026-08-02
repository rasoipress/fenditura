# Fenditura

Un banco di scansione slit-scan per macOS. Prende un video e ne ricava una sola
immagine in cui uno degli assi non è più spazio: è tempo.

È la tecnica del photo-finish, delle strisciate di Adam Magyar, delle rollout
photography che srotolano un vaso in un disegno piatto. Qui la si vede formarsi
mentre succede, e si corregge guardando.

Applicazione nativa, circa 3 MB, avvio immediato.

---

## Le quattro modalità

Non sono quattro algoritmi. Per ogni colonna dell'immagine servono le stesse due
risposte — da quale istante, da quale posizione nel fotogramma — e cambia solo
chi le fornisce.

**Strisciata.** Le fette si accodano e l'immagine cresce senza limite sull'asse
del tempo. Treni, folle, facciate. È la modalità che produce le immagini lunghe
decine di migliaia di pixel.

**Time displacement.** L'immagine ha le dimensioni di un fotogramma e ogni
colonna resta al proprio posto: cambia solo l'istante da cui viene. Il soggetto
non scorre via, si deforma. È l'effetto dei ritratti smaterializzati, ed è
l'unica modalità in cui il risultato è piccolo, sta in memoria e si vede tutto
insieme mentre si riempie.

**Srotolamento.** Per soggetti che ruotano su sé stessi: fenditura ferma,
superficie cilindrica distesa in un piano.

**Strisce multiple.** Più fenditure a posizioni diverse nella stessa passata,
salvate impilate. Serve a decidere dove mettere il taglio senza riscansionare il
video una volta per ipotesi.

---

## Il problema che risolve

Quasi tutti i tentativi di slit-scan falliscono per un motivo solo, ed è
geometrico. Se il soggetto si sposta di **d** pixel fra una fetta e la
successiva e la fetta è larga **s**, l'immagine finale è scalata di **s / d**
sull'asse lungo. Con `s = 1` e `d = 8` esce schiacciata otto volte, e nessuno
stiramento in post la recupera: quell'informazione non è mai stata campionata.

Fenditura misura **d** dal vivo, confrontando il profilo di luminanza fra
fotogrammi consecutivi, e dice in una riga se la striscia sta uscendo stirata,
schiacciata o proporzionata. Il pulsante *Adatta* imposta la larghezza giusta.

Se il valore resta vicino a zero, la camera sta inseguendo il soggetto: il
soggetto è fermo rispetto al taglio e la striscia si appiattisce in bande. Sposta
la fenditura dove scorre lo sfondo, o dalle una traiettoria.

---

## Da cosa nasce la morbidezza

Non da un filtro applicato dopo, ma dal modo in cui si legge la sorgente. Tre
meccanismi distinti, cumulabili, tutti nel campionatore:

**Sub-pixel.** La fenditura vive a coordinate frazionarie e i pixel si leggono
per interpolazione bilineare. Senza, una deriva di 0,3 px per fetta produce
colonne ripetute a scatti invece di uno scorrimento.

**Sfumatura.** I pixel della finestra si mediano con pesi a campana invece di
essere copiati a peso pieno. È ciò che trasforma un taglio netto in uno
strisciato da lunga esposizione. Il cursore va da zero, che è un taglio, a cento.

**Fusione temporale.** Due fotogrammi consecutivi si fondono quando l'uscita
chiede una colonna a metà strada fra l'uno e l'altro. Spenta, la stessa colonna
viene ripetuta e nella striscia compaiono bande dure: è la causa principale
dell'aspetto meccanico.

La fenditura può anche essere **inclinata**, e la sua posizione può seguire una
**traiettoria**: ferma, deriva lineare, o fotogrammi chiave interpolati con
raccordo morbido, per accompagnare un soggetto che cambia velocità.

---

## Compilare

Servono gli strumenti da riga di comando di Xcode. Non serve aprire Xcode.

```bash
git clone https://github.com/rasoipress/fenditura.git
cd fenditura
./build.sh release
open Fenditura.app
```

Lo script esegue prima le prove e, se falliscono, non costruisce niente. Poi
compila, assembla il bundle, incorpora l'icona e applica una firma ad-hoc —
necessaria su Apple Silicon, dove un binario non firmato viene ucciso all'avvio
senza messaggi.

Per installarla:

```bash
cp -R Fenditura.app /Applications/
```

**Costruita in locale non incontra Gatekeeper.** L'avviso con la parola malware
lo mette il programma che scarica un file, non il file: un'applicazione
compilata sulla propria macchina si apre con un doppio clic. Per far sparire
quell'avviso anche sui pacchetti scaricati serve un account Apple Developer,
qualunque sia il linguaggio in cui l'app è scritta.

---

## Prove

```bash
swift test
```

Il pacchetto è diviso in due bersagli, e la divisione non è cosmetica.
`FenditturaCore` non importa niente di grafico: è la matematica della scansione,
e si verifica in pochi secondi.

Le prove sono numeriche, non qualitative. Su una rampa lineare, leggere a metà
fra il pixel 10 e l'11 deve dare esattamente 84: se il sub-pixel non funziona, la
prova lo dice con un numero. Due fotogrammi uniformi da 40 e 200 devono dare 120
a metà fusione. Una striscia che attraversa più piastrelle con una fetta che non
divide 4096 non deve contenere nemmeno una colonna nera.

Quest'ultima non è un'ipotesi di scuola: era un difetto reale della versione
precedente, invisibile finché la striscia restava sotto i 4096 pixel, e avrebbe
messo una banda nera ogni 4096 px in ogni stampa.

---

## Com'è fatta

```
Sources/FenditturaCore/
  SlitSampler.swift       campionamento continuo: sub-pixel, sfumatura, fusione temporale
  Trajectory.swift        dove sta la fenditura fetta per fetta, e le modalità
  StripBuffer.swift       accumulo a piastrelle, riempimento registrato per piastrella
  TimeDisplacement.swift  tela a dimensione di fotogramma, riempita in una passata
  MotionMeter.swift       profilo di luminanza, correlazione, verdetto
  PNGStreamWriter.swift   PNG incrementale: righe a blocchi, compressione a flusso
  StripExporter.swift     dalla striscia al PNG, per righe
  ScanSettings.swift      impostazioni con limiti e salvataggio JSON

Sources/Fenditura/
  FenditturaApp.swift     scena, menu, dialoghi
  ContentView.swift       monitor, risultato, quadrante, pannello
  ScanEngine.swift        stato osservabile e coordinamento
  ScanSession.swift       la passata di lettura, sulla propria coda
```

Due scelte meritano una spiegazione.

**Perché AVAssetReader.** Consegna ogni fotogramma, in ordine, decodificato dal
sistema. Non ne scarta e non ha bisogno di cercare. Nella versione a browser i
fotogrammi arrivavano dal motore di riproduzione, che ne perde quando è in
ritardo, e per non perderne nulla bisognava passare a un seek per fotogramma,
così lento da rendere inutilizzabile un video lungo. Quella scelta fra veloce e
completo qui non esiste.

**Perché uno scrittore PNG fatto a mano.** Una striscia da 100.000 × 1080 pixel
sono 432 MB di soli dati grezzi. Le righe arrivano a blocchi e finiscono
compresse su disco man mano, quindi l'immagine intera non esiste mai e il limite
diventa lo spazio libero.

---

## Riferimenti

- **Adam Magyar**, *Urban Flow* e *Stainless*: sensore di scanner piano dietro un
  obiettivo, poi camera industriale ad alta velocità puntata dalla banchina sui
  treni in corsa. Sua è la formulazione più esatta della tecnica: l'asse
  orizzontale non riguarda lo spazio, riguarda il prima e il dopo.
- **Ed Ruscha**, *Every Building on the Sunset Strip* (1966): non è slit-scan, è
  lo stesso oggetto concettuale.
- **Justin Kerr**, rollout photography dei vasi maya.
- **George Silk** per LIFE, anni Sessanta: ritratti e sport con camera da photo
  finish.
- **Golan Levin**, [catalogo delle opere slit-scan](http://www.flong.com/archive/texts/lists/slit_scan/index.html).
- **Andrew Ringler**,
  [video-2-slit-scan](https://github.com/andrewringler/video-2-slit-scan): un
  altro strumento libero per la stessa tecnica.

## Licenza

MIT.
