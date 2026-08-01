# Fenditura

*[Italiano](README.it.md)*

A desktop app for macOS and Windows that turns a video into a single long
photograph. It reads the same column of pixels out of every frame and stacks
those columns side by side. The long axis of the resulting image is not space.
It is time.

This is the technique behind photo-finish pictures at a racetrack, behind Adam
Magyar's subway platform series, behind the rollout photographs that unwrap a
Maya vase into a flat drawing. Its usual names are **slit-scan**, **strip
photography** or **photo finish**.

---

## What it is for

You have a video: a train going past, a crowd walking, a camera tracking along
a building. You want the one image that shows the whole event at once, laid out
end to end, instead of a sequence of frames.

Fenditura does that, and — this is the part other tools leave out — it tells
you while you work whether the result will have the right proportions.

## The problem it solves

Almost every slit-scan attempt fails for a single reason, and the reason is
geometric.

If the subject moves **d** pixels between one frame and the next, and you take
a slice **s** pixels wide, the output image is scaled by **s / d** along the
long axis. With `s = 1` and `d = 8` your subject comes out squashed eight times
over, and no amount of stretching afterwards brings it back — the information
was never sampled.

Correct proportions need `s ≈ d`.

Fenditura measures **d** live, right under the slit, by comparing the luminance
profile of consecutive frames. A gauge at the bottom of the window reports the
measured displacement, the resulting scale factor, and a plain sentence saying
whether the strip is coming out stretched, squashed or true. **Match width**
sets the slice to the correct value in one click.

If the measured value sits near zero, the camera is tracking the subject: the
subject is motionless relative to the cut, and the strip flattens into vertical
bands. Move the slit to where the background flows, or use **drift** to slide
the slit against the camera's motion.

---

## What it does

- **Live preview while scanning.** The tail of the strip at 1:1, a contact view
  of the whole strip, and a ruler above it converting output pixels back into
  minutes and seconds of the source.
- **Slit dragged directly on the monitor**, vertical or horizontal. The strip
  can accumulate in either direction, and can be doubled into a mirror.
- **Drift**: the slit slides through the frame as the scan proceeds, by a set
  number of pixels per captured slice.
- **Exposure stabilisation**: each slice is pulled back to the average
  luminance of the first few, which removes the vertical banding that a
  camera's auto-exposure leaves in the strip.
- **Two scanning methods.** *Playback* is fast but the browser engine may drop
  frames; *exact seek* seeks once per frame, is slow, and misses nothing.
- **Saving with no length limit.** The PNG is written to disk row by row as
  compression proceeds, so the full image never exists in memory and the
  roughly 32,000 px canvas ceiling does not apply. Disk space is the limit.
- **Wrapped layout**: the strip cut into rows and stacked, the way you would
  print it on a page.
- Settings saved to and reloaded from JSON.

Everything happens on your machine. The app makes no network requests, and the
renderer cannot read the disk — only the files you open yourself are reachable.

---

## Installing

### From a release

Download the package for your platform from the
[releases page](https://github.com/rasoipress/fenditura/releases), and see
[unsigned builds](#the-builds-are-not-signed) below — the first launch needs
one extra step.

### From source

Node 18 or newer.

```bash
git clone https://github.com/rasoipress/fenditura.git
cd fenditura
npm install
npm start
```

If `npm start` fails with *Electron failed to install correctly*, look back at the
`npm install` output for a line like this:

```
npm warn install-scripts 1 package had install scripts blocked
npm warn install-scripts   electron@31.7.7 (postinstall: node install.js)
```

Recent npm versions block install scripts by default, and Electron downloads its
binary from one. The package is there, the executable is not. Run the download
yourself:

```bash
node node_modules/electron/install.js
```

On macOS, if that still is not enough — extraction can stall silently, and on
Apple Silicon a binary whose signature broke is killed at launch with no
message — a script runs the steps in order with checks between them:

```bash
bash tools/ripara-electron.sh
```

The clean answer, if you would rather work than repair, is **Node 22 LTS**:
Electron 31's install chain does not hold up on the newest Node releases, while
on Node 22 `npm install` does the whole thing by itself.

The test suite is unaffected either way: it needs no Electron binary, which is
why `npm test` passes even when `npm start` does not.

### Building the packages

```bash
npm run dist:mac     # .dmg and .zip, x64 and arm64
npm run dist:win     # .exe installer and portable build
```

Output lands in `dist/`. Each platform must be built on itself: a `.dmg` cannot
be produced from Windows. The workflow in `.github/workflows/build.yml` builds
both on every push to `main`; a tag starting with `v` prepares a draft release
with the packages attached.

```bash
git tag v1.0.0 && git push origin v1.0.0
```

### Running the tests

```bash
npm test
```

The suite runs the real renderer code against a synthetic video whose motion is
known exactly, and reads back written PNGs with an independent decoder. It
needs no display and no Electron binary.

---

## How to use it

1. **Open a video**, or drag it onto the window.
2. **Place the slit** by dragging on the monitor, or with the *Position*
   slider. Arrow keys nudge it one source pixel at a time, Shift for ten.
3. **Press Start.** The strip begins to build and the gauge starts reading.
4. **Watch the gauge.** When it says the strip is stretched or squashed, press
   **Match width**, then **Clear** and start again — the slices already
   captured keep the width they were taken with.
5. **Save the strip.** *Single strip* streams a PNG of unlimited length;
   *wrapped* lays it out in rows for printing.

Space starts and stops, and so does ⌘↩ from the menu. ⌘L matches the slice
width to the measured motion, ⌘⌫ clears the strip.

### Notes from practice

- Shoot at a high frame rate (120–240 fps) so **d** stays small and
  controllable.
- Lock exposure, white balance and focus. Every automatic adjustment becomes a
  vertical band in the strip.
- Translate the camera parallel to the subject rather than panning it. A pan
  gives a cylindrical projection; a translation gives the flat elevation that
  makes these images read like architectural drawings.
- Prefer a global shutter. With a rolling shutter a single vertical column
  contains rows read at different instants, and verticals lean.
- If **d** falls below 1 px per frame, no slit width saves the proportions.
  You are sampling below the available resolution, and the fix is upstream, at
  the shoot.

---

## The builds are not signed

There is no Apple certificate and no Authenticode certificate in the workflow.

On macOS, Gatekeeper blocks the first launch. Right-click the app, choose
*Open*, confirm. If the block persists:

```bash
xattr -dr com.apple.quarantine /Applications/Fenditura.app
```

On Windows, SmartScreen shows a warning: *More info*, then *Run anyway*.

Removing both requires paid certificates — an Apple Developer account and an
Authenticode certificate. The environment variables electron-builder expects
are documented at [electron.build/code-signing](https://www.electron.build/code-signing).

---

## How it is built

```
electron/main.js        window, strip:// protocol, IPC channels
electron/preload.js     contextBridge, minimal surface
electron/png-writer.js  incremental PNG writer over Node's zlib
src/index.html          structure
src/styles.css          stylesheet
src/app.js              capture, motion measurement, previews, export
test/harness.js         jsdom plus a software 2D context
test/run.js             the test suite
build/make-icon.py      regenerates build/icon.png
```

Two decisions are worth explaining.

**Why a `strip://` scheme instead of `file://`.** Under `file://` Chromium
treats the video as an opaque origin and taints the canvas: `getImageData`
stops working, and with it the motion measurement dies. The main process serves
the page and the video from the same scheme and the same host, with full Range
request support because exact-seek mode depends on seeking. Only files the user
opened explicitly are reachable; the renderer cannot read the disk.

**Why a hand-written PNG writer.** No native dependency, so building on GitHub
Actions needs no toolchain — and, more to the point, rows can arrive in blocks
and be compressed straight to disk without the full image ever being allocated.
Sub filter and Node's deflate, nothing else.

The interface is in Italian. *Fenditura* means slit.

---

## References

- **Adam Magyar**, *Urban Flow* and *Stainless*: a flatbed scanner sensor
  mounted behind a lens, later a high-speed industrial camera pointed at
  moving subway trains from the platform. His is the most exact statement of
  what the technique does — the horizontal axis is not about space, it is about
  before and after.
- **Ed Ruscha**, *Every Building on the Sunset Strip* (1966): not slit-scan
  technically, but the same conceptual object, and the more useful precedent if
  you are thinking about a publication rather than a print.
- **Justin Kerr**, rollout photography of Maya vases: fixed slit, rotating
  vase, unwrapping a cylindrical surface onto a plane.
- **George Silk** for LIFE in the 1960s: portraits and sports shot with a
  photo-finish camera.
- **Andrew Davidhazy** (RIT) on analogue strip photography.
- **Golan Levin**, [catalogue of slit-scan works](http://www.flong.com/archive/texts/lists/slit_scan/index.html),
  last updated 2015.

## Licence

MIT.
