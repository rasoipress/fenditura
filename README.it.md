# Fenditura

*[English](README.md)*

Un'applicazione per macOS e Windows che trasforma un video in una sola
fotografia lunga. Da ogni fotogramma preleva sempre la stessa colonna di pixel
e la accoda alla precedente. L'asse lungo dell'immagine che ne esce non è
spazio: è tempo.

È la tecnica delle fotografie di photo-finish, delle strisciate che Adam Magyar
riprende dalle banchine della metropolitana, delle rollout photography che
srotolano un vaso maya in un disegno piatto. I suoi nomi correnti sono
**slit-scan**, **strip photography**, **photo finish**.

---

## A cosa serve

Hai un video: un treno che passa, una folla che cammina, una camera che scorre
lungo una facciata. Vuoi l'unica immagine che mostra tutto l'evento insieme,
disteso da un capo all'altro, invece di una sequenza di fotogrammi.

Fenditura fa questo, e — è la parte che gli altri strumenti lasciano fuori — ti
dice mentre lavori se il risultato avrà le proporzioni giuste.

## Il problema che risolve

Quasi tutti i tentativi di slit-scan falliscono per un motivo solo, ed è
geometrico.

Se il soggetto si sposta di **d** pixel da un fotogramma al successivo e tu
prelevi una fetta larga **s** pixel, l'immagine finale è scalata di **s / d**
sull'asse lungo. Con `s = 1` e `d = 8` il soggetto esce schiacciato otto volte,
e nessuno stiramento in post lo recupera: quell'informazione non è mai stata
campionata.

Per proporzioni corrette serve `s ≈ d`.

Fenditura misura **d** dal vivo, proprio sotto la fenditura, confrontando il
profilo di luminanza fra fotogrammi consecutivi. Il quadrante in basso riporta
lo spostamento misurato, il fattore di scala che ne risulta e una frase che
dice se la striscia sta uscendo stirata, schiacciata o proporzionata. *Adatta
larghezza* imposta il valore corretto con un clic.

Se il valore misurato resta vicino a zero, la camera sta inseguendo il
soggetto: il soggetto è fermo rispetto al taglio e la striscia si appiattisce
in bande verticali. Sposta la fenditura dove scorre lo sfondo, oppure usa la
**deriva** per farla scorrere contro il moto della camera.

---

## Cosa fa

- **Anteprima dal vivo mentre la scansione avanza.** La coda della striscia a
  grandezza naturale, un provino dell'intera striscia, e sopra un righello che
  converte i pixel dell'uscita in minuti e secondi della sorgente.
- **Fenditura trascinabile direttamente sul monitor**, verticale o
  orizzontale. La striscia può accumularsi nei due versi e raddoppiarsi
  specchiata.
- **Deriva**: la fenditura scorre nel fotogramma mentre la scansione procede,
  di tanti pixel per fetta catturata quanti ne indichi.
- **Stabilizzazione dell'esposizione**: ogni fetta viene riportata alla
  luminanza media delle prime, e le bande verticali che l'esposizione
  automatica lascia nella striscia spariscono.
- **Due metodi di scansione.** *Riproduzione* è veloce ma il motore del browser
  può scartare fotogrammi; *ricerca esatta* fa un seek per fotogramma, è lenta
  e non perde nulla.
- **Salvataggio senza limiti di lunghezza.** Il PNG viene scritto su disco riga
  per riga mentre la compressione avanza, quindi l'immagine intera non esiste
  mai in memoria e il limite di circa 32.000 px per lato di un canvas non si
  applica. Il limite è lo spazio libero sul disco.
- **Impaginazione a righe**: la striscia tagliata e impilata, come la
  stamperesti su una pagina.
- Impostazioni salvabili e ricaricabili in JSON.

Tutto avviene sulla tua macchina. L'applicazione non fa richieste di rete, e il
processo di rendering non può leggere il disco: sono raggiungibili solo i file
che apri esplicitamente.

---

## Installazione

### Da una release

Scarica il pacchetto per la tua piattaforma dalla
[pagina delle release](https://github.com/rasoipress/fenditura/releases), e
leggi [le build non sono firmate](#le-build-non-sono-firmate) qui sotto: il
primo avvio richiede un passaggio in più.

### Da sorgente

Serve Node 18 o successivo.

```bash
git clone https://github.com/rasoipress/fenditura.git
cd fenditura
npm install
npm start
```

Se `npm start` risponde *Electron failed to install correctly*, cerca
nell'output di `npm install` una riga come questa:

```
npm warn install-scripts 1 package had install scripts blocked
npm warn install-scripts   electron@31.7.7 (postinstall: node install.js)
```

Le versioni recenti di npm bloccano per impostazione predefinita gli script di
installazione, ed Electron scarica il proprio binario proprio da uno di quelli.
Il pacchetto c'è, l'eseguibile no. Lancia il download a mano:

```bash
node node_modules/electron/install.js
```

Su macOS, se anche questo non basta — l'estrazione può fermarsi in silenzio, e
su Apple Silicon un binario con la firma saltata viene ucciso all'avvio senza
un messaggio — c'è uno script che fa i passaggi in ordine con le verifiche in
mezzo:

```bash
bash tools/ripara-electron.sh
```

La soluzione pulita, se hai fretta di lavorare invece di riparare, è usare
**Node 22 LTS**: la catena di installazione di Electron 31 non regge sulle
versioni di Node più recenti, mentre su Node 22 `npm install` fa tutto da solo.

Le prove non ne risentono in nessun caso: non hanno bisogno del binario di
Electron, ed è il motivo per cui `npm test` passa anche quando `npm start` no.

### Compilazione dei pacchetti

```bash
npm run dist:mac     # .dmg e .zip, x64 e arm64
npm run dist:win     # installatore .exe e versione portatile
```

I file finiscono in `dist/`. Ogni piattaforma va compilata sulla propria: un
`.dmg` non si costruisce da Windows. Il flusso in
`.github/workflows/build.yml` compila entrambe a ogni push su `main`, e su un
tag che comincia per `v` prepara una release in bozza con i pacchetti
allegati.

```bash
git tag v1.0.0 && git push origin v1.0.0
```

### Prove

```bash
npm test
```

Le prove eseguono il codice vero del processo di rendering su un video
sintetico di cui si conosce esattamente il moto, e rileggono i PNG scritti con
un decoder indipendente. Non servono uno schermo né il binario di Electron.

---

## Come si usa

1. **Apri un video**, o trascinalo sulla finestra.
2. **Posiziona la fenditura** trascinando sul monitor, o con il cursore
   *Posizione*. Le frecce la spostano di un pixel della sorgente per volta,
   con Maiuscolo di dieci.
3. **Premi Avvia.** La striscia comincia a formarsi e il quadrante a leggere.
4. **Guarda il quadrante.** Quando dice che la striscia esce stirata o
   schiacciata, premi *Adatta larghezza*, poi *Svuota* e ricomincia: le fette
   già catturate conservano la larghezza con cui sono state prese.
5. **Salva.** *Striscia unica* scrive un PNG di lunghezza illimitata,
   *impaginata a righe* la dispone in righe per la stampa.

La barra spaziatrice avvia e ferma, e ⌘↩ fa lo stesso dal menu. ⌘L adatta la
larghezza della fetta al moto misurato, ⌘⌫ svuota la striscia.

### Note di ripresa

- Gira a frame rate alto (120–240 fps), così **d** resta piccolo e
  controllabile.
- Blocca esposizione, bilanciamento del bianco e messa a fuoco. Ogni
  automatismo diventa una banda verticale nella striscia.
- Trasla la camera parallelamente al soggetto invece di ruotarla. Una
  panoramica produce una proiezione cilindrica; una traslazione produce la
  strisciata piatta che si legge come un prospetto architettonico.
- Preferisci il global shutter. Col rolling shutter una colonna verticale
  contiene righe lette in istanti diversi, e le verticali si inclinano.
- Se **d** scende sotto 1 px per fotogramma non esiste larghezza di fenditura
  che salvi le proporzioni: stai campionando sotto la risoluzione disponibile,
  e la soluzione sta a monte, nella ripresa.

---

## Le build non sono firmate

Nel flusso di compilazione non c'è nessun certificato, né Apple né
Authenticode. Chi scarica un pacchetto se ne accorge subito, perché entrambi i
sistemi operativi lo dicono con parole che sembrano un'accusa.

**Non è un rilevamento di malware.** È la formulazione che macOS e Windows
usano per qualunque programma che nessuno abbia firmato e sottoposto a
revisione. Non significa che il codice sia stato esaminato e trovato
pericoloso: significa che non è stato esaminato affatto.

### macOS

Al primo avvio compare un avviso che dice che **Apple non ha potuto verificare
che l'app sia priva di malware**. Il pulsante predefinito è *Sposta nel
cestino*: leggi la finestra prima di cliccare.

1. Premi **Fine**, non l'altro pulsante.
2. Apri **Impostazioni di Sistema → Privacy e sicurezza** e scorri fino a
   *Sicurezza*.
3. Accanto alla riga «"Fenditura" è stata bloccata per proteggere il Mac»
   clicca **Apri comunque**, e conferma con la password.

Il pulsante resta disponibile per circa un'ora dopo il blocco. Se non lo trovi,
prova ad aprire l'app di nuovo e ripeti il passaggio.

Il vecchio metodo — tasto destro sull'app, poi *Apri* — **non funziona più**
per le applicazioni non notarizzate, da macOS 15 in poi. Se l'app è già finita
nel Cestino, recuperala con *Rimetti a posto* prima di procedere.

Dal terminale, in alternativa:

```bash
xattr -dr com.apple.quarantine /Applications/Fenditura.app
```

### Windows

SmartScreen mostra **"Windows ha protetto il PC"**. Clicca su *Ulteriori
informazioni*, poi sul pulsante **Esegui comunque** che compare sotto.

Se il file è stato bloccato al momento del download, il pulsante potrebbe non
comparire: fai clic destro sul `.exe`, scegli **Proprietà**, e in fondo alla
scheda *Generale* spunta **Annulla blocco**, poi *Applica*.

Se non c'è nessun *Esegui comunque* e Windows rifiuta e basta, è attivo **Smart
App Control**, che blocca i programmi non firmati senza offrire eccezioni né
elenchi di consentiti. L'unica via è disattivarlo da **Sicurezza di Windows →
Controllo app e browser → Impostazioni di Smart App Control**. Da
Windows 11 KB5083769 (aprile 2026) si può disattivare senza reinstallare il
sistema; sulle versioni precedenti la disattivazione era irreversibile senza
una reinstallazione. Valuta se ne vale la pena: è una protezione che vale per
tutto il sistema, non solo per questa applicazione.

In alternativa, su qualunque versione di Windows, il pacchetto *portable* non
richiede installazione ed è spesso meno problematico dell'installatore.

### Farli sparire

Servono certificati a pagamento: un account Apple Developer per firmare e
notarizzare su macOS, un certificato Authenticode per Windows. Le variabili
d'ambiente che electron-builder si aspetta sono documentate su
[electron.build/code-signing](https://www.electron.build/code-signing), e il
flusso in `.github/workflows/build.yml` non va riscritto: bastano i segreti.

Se preferisci non pagare, la strada senza avvisi resta eseguire l'app dal
sorgente con `npm start`, che non passa da Gatekeeper né da SmartScreen.

---

## Come è fatta

```
electron/main.js        finestra, protocollo strip://, canali IPC
electron/preload.js     ponte con contextBridge, superficie minima
electron/png-writer.js  scrittore PNG incrementale su zlib di Node
src/index.html          struttura
src/styles.css          foglio di stile
src/app.js              cattura, misura del moto, anteprime, esportazione
test/harness.js         jsdom più un contesto 2D scritto a mano
test/run.js             le prove
build/make-icon.py      rigenera build/icon.png
```

Due scelte meritano una spiegazione.

**Perché uno schema `strip://` invece di `file://`.** Sotto `file://` Chromium
considera il video di origine opaca e contamina il canvas: `getImageData`
smette di funzionare e con esso muore la misura del moto. Il processo
principale serve la pagina e il video dallo stesso schema e dallo stesso host,
con supporto completo delle richieste Range perché la modalità a ricerca esatta
dipende dal seek. Solo i file che l'utente ha aperto esplicitamente sono
raggiungibili: il processo di rendering non può leggere il disco.

**Perché uno scrittore PNG fatto a mano.** Nessuna dipendenza nativa, quindi la
compilazione su GitHub Actions non ha bisogno di toolchain, e soprattutto le
righe possono arrivare a blocchi e finire compresse su disco senza che
l'immagine completa venga mai allocata. Filtro Sub e deflate di Node, niente
altro.

---

## Riferimenti

- **Adam Magyar**, serie *Urban Flow* e *Stainless*: il sensore di uno scanner
  piano montato dietro un obiettivo, poi una camera industriale ad alta
  velocità puntata dalla banchina sui treni in corsa. Sua è la formulazione più
  esatta della tecnica: l'asse orizzontale non riguarda lo spazio, riguarda il
  prima e il dopo.
- **Ed Ruscha**, *Every Building on the Sunset Strip* (1966): non è slit-scan
  tecnicamente, ma è lo stesso oggetto concettuale, e il precedente più utile
  se si pensa a una pubblicazione più che a una stampa.
- **Justin Kerr**, rollout photography dei vasi maya: fenditura fissa e vaso
  che ruota, per srotolare una superficie cilindrica in un piano.
- **George Silk** per LIFE, anni Sessanta: ritratti e sport con camera da photo
  finish.
- **Andrew Davidhazy** (RIT) sulla strip photography analogica.
- **Golan Levin**, [catalogo delle opere slit-scan](http://www.flong.com/archive/texts/lists/slit_scan/index.html),
  ultimo aggiornamento 2015.

## Licenza

MIT.
