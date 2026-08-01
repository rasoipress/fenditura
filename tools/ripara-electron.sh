#!/usr/bin/env bash
#
# Ripara l'installazione di Electron su macOS quando npm non ci riesce.
#
# Serve su Node molto recenti, dove tre cose vanno storte in fila e nessuna
# delle tre lo dice chiaramente:
#
#   1. npm blocca gli script di installazione, quindi il postinstall di
#      Electron non parte e il binario non viene mai scaricato;
#   2. eseguito a mano, quel postinstall scarica l'archivio ma si ferma
#      durante l'estrazione, esce con codice 0 e non stampa niente;
#   3. estraendo a mano, su Apple Silicon la firma del codice non regge e il
#      processo viene ucciso all'avvio con SIGKILL, senza spiegazioni.
#
# Questo script fa i tre passaggi con le verifiche in mezzo. Non tocca il
# codice dell'applicazione: lavora solo dentro node_modules.
#
#   bash tools/ripara-electron.sh
#
# Se fallisce, la soluzione pulita non è insistere ma usare Node 22 LTS, dove
# `npm install` fa tutto da solo. Lo script te lo ricorda alla fine.

set -u

cd "$(dirname "$0")/.." || exit 1
ROOT="$(pwd)"

rosso()  { printf '\033[31m%s\033[0m\n' "$*"; }
verde()  { printf '\033[32m%s\033[0m\n' "$*"; }
passo()  { printf '\n\033[1m%s\033[0m\n' "$*"; }

if [ "$(uname -s)" != "Darwin" ]; then
  rosso "Questo script serve solo su macOS. Su Linux e Windows npm install basta."
  exit 1
fi

# ─────────────────────────── 0. cosa abbiamo ───────────────────────────

passo "0. Stato attuale"

if [ ! -d "$ROOT/node_modules/electron" ]; then
  rosso "node_modules/electron non esiste. Lancia prima:  npm install"
  exit 1
fi

VER="$(node -p "require('$ROOT/node_modules/electron/package.json').version")"
case "$(uname -m)" in
  arm64)  ARCH=arm64 ;;
  x86_64) ARCH=x64 ;;
  *)      rosso "architettura non riconosciuta: $(uname -m)"; exit 1 ;;
esac
APP="$ROOT/node_modules/electron/dist/Electron.app"
BIN="$APP/Contents/MacOS/Electron"

echo "  Electron $VER, architettura $ARCH"

if [ -f "$ROOT/node_modules/electron/path.txt" ] && [ -x "$BIN" ]; then
  # La prova va isolata in una sottoshell: un binario con la firma rotta viene
  # ucciso con SIGKILL, e senza questo la shell stampa un "Killed: 9" che
  # sembra un errore dello script invece della diagnosi che è.
  if ( "$BIN" --version ) >/dev/null 2>&1; then
    verde "  Electron funziona già. Niente da riparare."
    exit 0
  fi
  echo "  il binario c'è ma non parte: si prosegue"
fi

# ─────────────────────────── 1. l'archivio ───────────────────────────

passo "1. Archivio di Electron"

ZIP="$(find "$HOME/Library/Caches/electron" -name "electron-v$VER-darwin-$ARCH.zip" 2>/dev/null | head -1)"

if [ -z "$ZIP" ]; then
  echo "  non è nella cache, lo scarico…"
  # Questa è la sola parte del postinstall che funziona anche su Node nuovi,
  # quindi la si usa da sola invece di ripassare da install.js.
  ZIP="$(node -e "
    require('@electron/get').downloadArtifact({
      version: '$VER', artifactName: 'electron',
      platform: 'darwin', arch: '$ARCH'
    }).then(p => console.log(p)).catch(e => { console.error(e.message); process.exit(1); });
  ")" || { rosso "  download fallito"; exit 1; }
fi

if [ ! -f "$ZIP" ]; then
  rosso "  archivio non trovato: $ZIP"
  exit 1
fi
echo "  $ZIP"

# ─────────────────────────── 2. estrazione ───────────────────────────

passo "2. Estrazione"

# ditto e non unzip: Electron.app contiene collegamenti simbolici e una
# struttura di firma che unzip appiattisce, producendo un'app che non parte.
rm -rf "$ROOT/node_modules/electron/dist"
mkdir -p "$ROOT/node_modules/electron/dist"
if ! ditto -x -k "$ZIP" "$ROOT/node_modules/electron/dist"; then
  rosso "  ditto ha fallito"
  exit 1
fi

if [ ! -x "$BIN" ]; then
  rosso "  estratto, ma l'eseguibile non c'è: $BIN"
  exit 1
fi

# printf e non echo: index.js legge path.txt grezzo e lo concatena al
# percorso, quindi un a capo finirebbe dentro il nome del file.
printf 'Electron.app/Contents/MacOS/Electron' > "$ROOT/node_modules/electron/path.txt"
echo "  estratto, path.txt scritto"

# ─────────────────────────── 3. firma ───────────────────────────

passo "3. Quarantena e firma"

xattr -cr "$APP" 2>/dev/null
echo "  quarantena rimossa"

# Su Apple Silicon nulla viene eseguito senza una firma valida, nemmeno
# ad-hoc, e un binario non firmato viene ucciso con SIGKILL senza avvisi.
if codesign --force --deep --sign - "$APP" 2>/dev/null; then
  echo "  firma ad-hoc applicata"
else
  echo "  firma ad-hoc non riuscita, si prova comunque ad avviare"
fi

# ─────────────────────────── 4. verifica ───────────────────────────

passo "4. Verifica"

if OUT="$("$BIN" --version 2>&1)"; then
  verde "  Electron risponde: $OUT"
  verde ""
  verde "  Fatto. Ora:  npm start"
  exit 0
fi

rosso "  Electron non parte ancora. Ha risposto:"
rosso "  $OUT"
cat <<'FINE'

A questo punto conviene smettere di rattoppare e togliere la causa: la catena
di installazione di Electron 31 non regge sulle versioni più recenti di Node.
Con Node 22 LTS `npm install` fa tutto da solo, firma compresa.

  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
  exec zsh
  nvm install 22
  nvm use 22
  rm -rf node_modules
  npm install
  npm start

Non cancellare package-lock.json: è corretto e fa parte del repository.
FINE
exit 1
