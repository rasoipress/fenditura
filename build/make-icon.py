#!/usr/bin/env python3
"""
Genera build/icon.png, l'icona dell'applicazione.

Forma: la scocca segue la griglia delle icone macOS moderne. Su una tela di
1024 px il corpo occupa 824 px centrati, e il profilo è una superellisse di
esponente 5, che è l'approssimazione ragionevole della curva continua che
Apple usa al posto di un rettangolo con angoli circolari.

Contenuto: il taglio, e la striscia che ne esce. Una colonna chiara a sinistra
del centro è la fenditura; le bande alla sua destra sono le fette accumulate,
di larghezza e densità diverse come in una strisciata vera. Niente colore:
soltanto valori di grigio, così l'icona regge sia su scrivania chiara sia su
scrivania scura e resta leggibile a 16 px.

    python3 build/make-icon.py

Serve solo Pillow. Il risultato è già nel repository: rilanciarlo è necessario
soltanto se si cambia il disegno.
"""

from PIL import Image, ImageDraw
import os

SIZE = 1024
SS = 4                     # sovracampionamento
N = SIZE * SS

BODY = 824 / 1024          # quota del corpo sulla tela, griglia macOS
EXP = 5.0                  # esponente della superellisse

INK = 32                   # grigio della scocca
BAND_MIN, BAND_MAX = 58, 247

# La striscia è un blocco continuo, non una fila di barre separate: le fette
# di uno slit-scan si toccano, e il vuoto fra una barra e l'altra faceva
# leggere l'icona come un codice a barre. Ogni voce è larghezza relativa e
# densità della zona, con un breve raccordo fra una zona e la successiva.
# Poche zone larghe e molto contrastate si leggono come sbarre; troppe e
# ravvicinate tornano a essere un codice a barre. Il compromesso è una
# manciata di eventi forti annegati in variazioni minute, che è poi l'aspetto
# di una strisciata vera.
STRIP = [
    (0.085, 0.97),
    (0.040, 0.82),
    (0.062, 0.99),
    (0.105, 0.16),
    (0.048, 0.34),
    (0.075, 0.72),
    (0.036, 0.58),
    (0.092, 0.86),
    (0.055, 0.66),
    (0.068, 0.24),
    (0.044, 0.44),
    (0.118, 0.93),
    (0.038, 0.74),
    (0.064, 0.88),
]
BLEND = 0.022              # raccordo fra due zone, in quota della striscia


def superellipse_mask(n, side, exp):
    """Maschera della scocca: 255 dentro il profilo, sfumata sul bordo."""
    mask = Image.new("L", (n, n), 0)
    px = mask.load()
    a = side / 2.0
    cx = cy = n / 2.0
    for y in range(n):
        dy = abs(y + 0.5 - cy) / a
        if dy > 1.0:
            continue
        ty = dy ** exp
        if ty >= 1.0:
            continue
        # x massimo per questa riga, dalla equazione della superellisse
        dx = (1.0 - ty) ** (1.0 / exp)
        x0 = cx - dx * a
        x1 = cx + dx * a
        i0, i1 = int(x0), int(x1)
        for x in range(max(0, i0), min(n, i1 + 1)):
            left = max(x0, x)
            right = min(x1, x + 1)
            cov = max(0.0, right - left)
            px[x, y] = int(round(cov * 255))
    return mask


def build():
    body_side = N * BODY
    mask = superellipse_mask(N, body_side, EXP)

    art = Image.new("L", (N, N), INK)
    d = ImageDraw.Draw(art)

    x0 = (N - body_side) / 2.0
    x1 = x0 + body_side

    # margini interni: il contenuto non tocca mai il bordo della scocca
    inset_x = body_side * 0.115
    left = x0 + inset_x
    right = x1 - inset_x
    span = right - left

    # La fenditura è alta e stretta, la striscia bassa e larga: il contrasto
    # fra le due forme è tutto il contenuto dell'icona, e sopravvive fino a
    # 16 px, dove un disegno più descrittivo diventerebbe una macchia.
    top_band = N * 0.5 - body_side * 0.215
    bot_band = N * 0.5 + body_side * 0.215
    top_cut = N * 0.5 - body_side * 0.400
    bot_cut = N * 0.5 + body_side * 0.400

    cut_w = span * 0.068
    cut_x = left + span * 0.075
    d.rectangle([cut_x, top_cut, cut_x + cut_w, bot_cut], fill=252)

    # la striscia: un unico blocco che cambia densità mentre si accumula
    start = cut_x + cut_w + span * 0.105
    width = right - start
    total = sum(w for w, _ in STRIP)

    def value_at(u):
        """Densità nel punto u (0…1) della striscia, con raccordi morbidi."""
        acc = 0.0
        for i, (w, dens) in enumerate(STRIP):
            a = acc / total
            b = (acc + w) / total
            acc += w
            if u < a or u > b:
                continue
            if i > 0 and u < a + BLEND:
                prev = STRIP[i - 1][1]
                f = (u - a) / BLEND
                dens = prev + (dens - prev) * (f * f * (3 - 2 * f))
            return BAND_MIN + (BAND_MAX - BAND_MIN) * dens
        return BAND_MIN + (BAND_MAX - BAND_MIN) * STRIP[-1][1]

    steps = 1400
    for s in range(steps):
        u0 = s / steps
        u1 = (s + 1) / steps
        val = int(round(value_at((u0 + u1) / 2)))
        d.rectangle(
            [start + u0 * width, top_band, start + u1 * width + 1, bot_band],
            fill=val,
        )

    rgb = Image.merge("RGB", (art, art, art))
    out = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    out.paste(rgb, (0, 0), mask)
    out = out.resize((SIZE, SIZE), Image.LANCZOS)

    here = os.path.dirname(os.path.abspath(__file__))
    path = os.path.join(here, "icon.png")
    out.save(path)
    print("scritto", path, out.size)
    return out


if __name__ == "__main__":
    build()
