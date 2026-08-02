#!/usr/bin/env bash
#
# Compila Fenditura e ne assembla il bundle .app.
#
# Non serve un progetto Xcode: Swift Package Manager produce l'eseguibile e
# qui intorno gli si costruisce la cartella che macOS si aspetta. Servono
# soltanto gli strumenti da riga di comando di Xcode.
#
#   ./build.sh              compila in debug, veloce
#   ./build.sh release      compila ottimizzato
#
# Il risultato è ./Fenditura.app, e si apre con un doppio clic. Costruita in
# locale non porta l'attributo di quarantena, quindi Gatekeeper non la blocca:
# quella finestra compare solo su ciò che si scarica dalla rete.

set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-debug}"
APP="Fenditura.app"
BUNDLE_ID="org.fenditura.app"
VERSION="2.0.0"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
ok()  { printf '\033[32m%s\033[0m\n' "$*"; }
bad() { printf '\033[31m%s\033[0m\n' "$*"; }

if ! command -v swift >/dev/null 2>&1; then
  bad "swift non è disponibile. Installa gli strumenti da riga di comando:"
  bad "  xcode-select --install"
  exit 1
fi

# ─────────────────────────── prove ───────────────────────────

say "1. Prove del nucleo"
LOG="$(mktemp)"
if swift test > "$LOG" 2>&1; then
  ok "  $(grep -c "' passed" "$LOG") prove superate"
  rm -f "$LOG"
else
  bad "  prove fallite. Ecco cosa non va:"
  echo
  # Le righe che contano sono le asserzioni cadute e gli errori di
  # compilazione, non il riepilogo: `tail` le tagliava via proprio quando
  # servivano.
  grep -E ": error:|XCTAssert.*failed|' failed \(" "$LOG" | sed 's/^/    /' | head -40
  echo
  echo "    registro completo: $LOG"
  bad "  il bundle non viene costruito"
  exit 1
fi

# ─────────────────────────── compilazione ───────────────────────────

say "2. Compilazione ($CONFIG)"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Fenditura"
if [ ! -x "$BIN" ]; then
  bad "  eseguibile non trovato in $BIN"
  exit 1
fi
ok "  $(du -h "$BIN" | cut -f1) di eseguibile"

# ─────────────────────────── bundle ───────────────────────────

say "3. Bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Fenditura"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Fenditura</string>
  <key>CFBundleDisplayName</key><string>Fenditura</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>Fenditura</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.photography</string>
</dict>
</plist>
PLIST

# ─────────────────────────── icona ───────────────────────────

ICON_SRC="build/icon.png"
if [ -f "$ICON_SRC" ]; then
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z $size $size "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null 2>&1
    sips -z $((size*2)) $((size*2)) "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null 2>&1
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  rm -rf "$(dirname "$ICONSET")"
  ok "  icona incorporata"
else
  bad "  $ICON_SRC non trovata: l'app avrà l'icona generica"
fi

# ─────────────────────────── firma ───────────────────────────

say "4. Firma ad-hoc"
# Su Apple Silicon nulla viene eseguito senza una firma valida, nemmeno
# ad-hoc: senza questa riga l'app viene uccisa all'avvio con SIGKILL e
# nessun messaggio.
codesign --force --sign - --timestamp=none "$APP" 2>/dev/null && ok "  firmata" || bad "  firma non riuscita"

say "Fatto"
ok "  $(du -sh "$APP" | cut -f1)  $PWD/$APP"
echo
echo "  Aprila con:  open $APP"
echo "  Installala:  cp -R $APP /Applications/"
