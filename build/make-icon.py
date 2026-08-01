#!/usr/bin/env python3
"""
Genera build/icon.png, l'icona dell'applicazione.

Forma: la scocca segue la griglia delle icone macOS moderne. Su una tela di
1024 px il corpo occupa 824 px centrati, e il profilo è una superellisse di
esponente 5 — l'approssimazione della curva continua che Apple usa al posto di
un rettangolo con angoli circolari. A esponente 5 il profilo coincide quasi
esattamente con un raggio di 185 px, che è la misura di riferimento.

Disegno: un taglio solo. Attraversa il corpo da parte a parte, quindi l'icona
non contiene una fenditura, è una fenditura. Il bordo sinistro è netto e il
destro si spegne in una scia breve: l'istante esatto e la sua traccia, che è
tutto ciò che uno slit-scan fa. Nessun secondo oggetto.

Le versioni precedenti mettevano il taglio accanto a un blocco che
rappresentava la striscia. Erano due cose vicine invece di una: l'occhio non
sapeva dove posarsi, e sotto i 32 px il blocco collassava in una macchia
grigia senza sagoma riconoscibile. Un'icona si riconosce dalla silhouette, e
la silhouette di una linea sopravvive a qualunque riduzione.

Niente colore: solo valori di grigio, così regge su scrivania chiara e scura.

    python3 build/make-icon.py

Serve soltanto Pillow. Il risultato è già nel repository: rilanciarlo è
necessario solo se si cambia il disegno.
"""

from PIL import Image, ImageDraw
import math
import os

SIZE = 1024
SS = 4                     # sovracampionamento, poi ridotto con Lanczos
N = SIZE * SS

BODY = 824 / 1024          # quota del corpo sulla tela, griglia macOS
EXP = 5.0                  # esponente della superellisse

INK = 32                   # grigio della scocca
LIGHT = 250                # grigio del taglio

CUT_X = 0.300              # bordo sinistro del taglio, in quota del corpo
CUT_W = 0.072              # larghezza del taglio, in quota del corpo
CUT_PAD = 0.10             # margine sopra e sotto, in quota del corpo
TRAIL = 1.45               # lunghezza della scia, in multipli della larghezza
DECAY = 3.6                # rapidità con cui la scia si spegne


def superellipse_mask(n, side, exp):
    """Maschera della scocca: 255 dentro il profilo, sfumata sul bordo."""
    mask = Image.new("L", (n, n), 0)
    px = mask.load()
    a = side / 2.0
    cx = cy = n / 2.0
    for y in range(n):
        dy = abs(y + 0.5 - cy) / a
        if dy >= 1.0:
            continue
        dx = (1.0 - dy ** exp) ** (1.0 / exp)
        x0 = cx - dx * a
        x1 = cx + dx * a
        for x in range(max(0, int(x0)), min(n, int(x1) + 1)):
            cov = max(0.0, min(x1, x + 1) - max(x0, x))
            px[x, y] = int(round(cov * 255))
    return mask


def build():
    side = N * BODY
    left = (N - side) / 2.0

    art = Image.new("L", (N, N), INK)
    d = ImageDraw.Draw(art)

    x = left + side * CUT_X
    w = side * CUT_W

    # Sopra e sotto resta una fascia di scocca. Senza, il taglio arriva ai
    # bordi e sotto i 128 px l'icona si legge come due forme separate invece
    # che come una piastrella incisa: la sagoma si spezza, ed è la cosa che
    # un'icona non può permettersi.
    top = N / 2 - side * (0.5 - CUT_PAD)
    bot = N / 2 + side * (0.5 - CUT_PAD)
    d.rectangle([x, top, x + w, bot], fill=LIGHT)

    # La scia: decadimento esponenziale a destra, disegnato a strisce sottili
    # perché Pillow non ha gradienti. Si ferma dove raggiunge il fondo, per
    # non lasciare una banda appena più chiara che a occhio si nota.
    span = w * TRAIL
    steps = 600
    for i in range(steps):
        u = (i + 0.5) / steps
        v = LIGHT * math.exp(-DECAY * u)
        if v <= INK:
            break
        d.rectangle([x + w + u * span, top, x + w + (i + 1) / steps * span + 1, bot],
                    fill=int(round(v)))

    mask = superellipse_mask(N, side, EXP)
    out = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    out.paste(Image.merge("RGB", (art, art, art)), (0, 0), mask)
    out = out.resize((SIZE, SIZE), Image.LANCZOS)

    here = os.path.dirname(os.path.abspath(__file__))
    path = os.path.join(here, "icon.png")
    out.save(path)
    print("scritto", path, out.size)
    return out


if __name__ == "__main__":
    build()
