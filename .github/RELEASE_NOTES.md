> **Read this before you download.** Both macOS and Windows will call these
> packages unsafe. They are not signed, and the warning wording is alarming on
> purpose. Instructions for getting past it are below.
>
> **Leggi prima di scaricare.** Sia macOS sia Windows diranno che questi
> pacchetti non sono sicuri. Non sono firmati, e il testo dell'avviso è
> allarmante per costruzione. Sotto c'è come aggirarlo.

**Fenditura** turns a video into one continuous strip photograph. It reads the
same column of pixels out of every frame and stacks those columns side by side,
so the long axis of the result is not space — it is time. Photo finish, strip
photography, slit-scan.

While it scans, it measures how far the image actually moves under the slit and
tells you whether the strip is coming out stretched, squashed or true. That
measurement is the point: without it, almost every slit-scan attempt comes out
deformed and nothing in post recovers it.

*Fenditura trasforma un video in una sola fotografia lunga: da ogni fotogramma
preleva la stessa colonna di pixel e la accoda alla precedente, così l'asse
lungo dell'immagine non è spazio ma tempo. Mentre scansiona misura di quanto si
sposta davvero l'immagine sotto la fenditura e dice se la striscia sta uscendo
stirata, schiacciata o proporzionata.*

---

## Which file

| File | |
|---|---|
| `Fenditura-*-arm64.dmg` | macOS, Apple Silicon |
| `Fenditura-*.dmg` | macOS, Intel |
| `Fenditura Setup *.exe` | Windows, installer |
| `Fenditura *.exe` | Windows, portable, no installation |

---

## First launch — macOS

The warning says **"Apple could not verify Fenditura is free of malware."**
This is not a detection. It is what macOS says about any application nobody has
paid to have notarised. The default button is *Move to Trash*, so read the
dialog before clicking.

1. Press **Done**, not the other button.
2. Open **System Settings → Privacy & Security**, scroll down to *Security*.
3. Next to "Fenditura was blocked to protect your Mac", click **Open Anyway**
   and confirm with your password.

The button is only there for about an hour after the block. If it is missing,
try opening the app again, then go back to Settings.

Right-clicking the app and choosing *Open* no longer works — Apple removed that
route in macOS 15. If the app is already in the Trash, use *Put Back* first.

From Terminal instead:

```bash
xattr -dr com.apple.quarantine /Applications/Fenditura.app
```

**In italiano.** L'avviso dice che *Apple non ha potuto verificare che
Fenditura sia priva di malware*: non è un rilevamento, è la formula per
qualunque app non notarizzata. Premi **Fine**, poi **Impostazioni di Sistema →
Privacy e sicurezza → Sicurezza → Apri comunque**. Il tasto destro seguito da
*Apri* non funziona più da macOS 15. Se l'app è finita nel Cestino, *Rimetti a
posto*.

---

## First launch — Windows

SmartScreen shows **"Windows protected your PC"**. Click *More info*, then
**Run anyway**.

If that button is missing, the file was blocked at download: right-click the
`.exe` → **Properties** → tick **Unblock** at the bottom of the *General* tab →
*Apply*.

If Windows refuses with no *Run anyway* anywhere, **Smart App Control** is
enabled. It blocks unsigned programs with no exceptions and no allow-list, and
the only way past it is switching it off in **Windows Security → App & browser
control**. That is a system-wide protection — decide whether it is worth it.
The **portable** build often gets through where the installer does not.

**In italiano.** SmartScreen mostra *Windows ha protetto il PC*: clicca
*Ulteriori informazioni*, poi *Esegui comunque*. Se il pulsante non c'è, fai
clic destro sul file, **Proprietà**, e spunta **Annulla blocco**. Se manca del
tutto è attivo **Smart App Control**, che non ammette eccezioni: va disattivato
da *Sicurezza di Windows → Controllo app e browser*. La versione **portable**
spesso passa dove l'installatore viene fermato.

---

## Why the warnings exist

Signing and notarising requires an Apple Developer account and an Authenticode
certificate, both paid, yearly. This project has neither. The alternative with
no warnings at all is running it from source:

```bash
git clone https://github.com/rasoipress/fenditura.git
cd fenditura
npm install
npm start
```

Full documentation, including how to use the motion gauge:
[README](https://github.com/rasoipress/fenditura#readme) ·
[README in italiano](https://github.com/rasoipress/fenditura/blob/main/README.it.md)
