#!/usr/bin/env python3
"""Draw superterm's desktop backgrounds.

The pictures are plain text (see src/st_artbg.pas): a row of glyphs and a row
of palette indexes, one index per cell.

Only two glyphs are ever used -- the full block and the space. Half blocks,
shades and line-drawing characters split apart the moment the terminal font
is stretched, so nothing here draws with them: a cell is either painted
whole, in one colour, or left alone.

Everything is drawn into a PIXEL canvas that may be finer than the character
grid, and the emitter averages each cell's pixels into its single colour --
which is also what softens the edges of a drawn scene.

Nothing is ever painted in a colour that only means "background": a cell with
no picture in it is left empty, so a light desktop stays light behind the
art instead of getting a black rectangle around it.

Geometry: at 1024x768 with the classic 8x16 console cell the terminal is
128x48 characters, and superterm's desktop is that less the menu row and the
status row -- so a full-desktop picture is 128x46, which is what this writes.

    python3 tools/mkbackgrounds.py [outdir]
"""
import math
import os
import sys

W, H = 128, 46          # cells
# artwork that is not drawn here but converted from an image
GOODY_SRC = os.environ.get('GOODY_SRC', '/home/german/Imagenes/goody.png')
PHOENIX_SVG = os.environ.get('PHOENIX_SVG', 'assets/7kas-bird.svg')
PH = H * 2              # pixel rows

TRANSPARENT = None


# --------------------------------------------------------------- canvas

class Canvas:
    def __init__(self, w=W, h=PH):
        self.w, self.h = w, h
        self.px = [[TRANSPARENT] * w for _ in range(h)]

    def put(self, x, y, rgb):
        if 0 <= x < self.w and 0 <= y < self.h and rgb is not None:
            self.px[y][x] = rgb

    def hline(self, x0, x1, y, rgb):
        for x in range(int(x0), int(x1) + 1):
            self.put(x, int(y), rgb)

    def vline(self, x, y0, y1, rgb):
        for y in range(int(y0), int(y1) + 1):
            self.put(int(x), y, rgb)

    def rect(self, x0, y0, x1, y1, rgb):
        for y in range(int(y0), int(y1) + 1):
            self.hline(x0, x1, y, rgb)

    def get(self, x, y):
        if 0 <= x < self.w and 0 <= y < self.h:
            return self.px[y][x]
        return TRANSPARENT

    def blend(self, x, y, rgb, t):
        """paint rgb over what is already there, t = how much of it"""
        cur = self.get(x, y)
        if cur is None or rgb is None or t <= 0.0:
            return
        self.put(x, y, mix(cur, rgb, t))

    def blur(self, y0=0, y1=None, passes=1):
        """Soften a band of the canvas: a 3x3 average, centre weighted.

        Meant for the layers that should read as continuous -- sky, water,
        distant ground -- and applied BEFORE the things with edges are drawn
        on top of them, so a mast or a spire stays crisp.
        """
        if y1 is None:
            y1 = self.h - 1
        y0, y1 = max(0, int(y0)), min(self.h - 1, int(y1))
        for _ in range(passes):
            src = [row[:] for row in self.px]
            for y in range(y0, y1 + 1):
                for x in range(self.w):
                    if src[y][x] is None:
                        continue
                    r = g = b = wt = 0.0
                    for dy in (-1, 0, 1):
                        yy = y + dy
                        if yy < y0 or yy > y1:
                            continue
                        for dx in (-1, 0, 1):
                            xx = x + dx
                            if xx < 0 or xx >= self.w:
                                continue
                            p = src[yy][xx]
                            if p is None:
                                continue
                            k = 4.0 if (dx == 0 and dy == 0) else 1.0
                            r += ((p >> 16) & 255) * k
                            g += ((p >> 8) & 255) * k
                            b += (p & 255) * k
                            wt += k
                    if wt:
                        self.px[y][x] = ((int(r / wt) << 16)
                                         | (int(g / wt) << 8) | int(b / wt))


def nearer(c, a, b):
    """is c closer to a than to b?"""
    def d(p, q):
        return ((((p >> 16) & 255) - ((q >> 16) & 255)) ** 2
                + (((p >> 8) & 255) - ((q >> 8) & 255)) ** 2
                + ((p & 255) - (q & 255)) ** 2)
    return d(c, a) <= d(c, b)


def lerp(a, b, t):
    return a + (b - a) * t


def mix(c1, c2, t):
    """blend two #rrggbb ints"""
    t = max(0.0, min(1.0, t))
    return (
        (int(lerp((c1 >> 16) & 255, (c2 >> 16) & 255, t)) << 16)
        | (int(lerp((c1 >> 8) & 255, (c2 >> 8) & 255, t)) << 8)
        | int(lerp(c1 & 255, c2 & 255, t))
    )


def shade(c, f):
    """scale a colour's brightness"""
    r = min(255, max(0, int(((c >> 16) & 255) * f)))
    g = min(255, max(0, int(((c >> 8) & 255) * f)))
    b = min(255, max(0, int((c & 255) * f)))
    return (r << 16) | (g << 8) | b


# deterministic value noise: no dependency, same picture every run
def noise(x, y, seed=0):
    n = (x * 374761393 + y * 668265263 + seed * 1274126177) & 0xFFFFFFFF
    n = (n ^ (n >> 13)) * 1274126177 & 0xFFFFFFFF
    return ((n ^ (n >> 16)) & 0xFFFF) / 65535.0


# --------------------------------------------------------------- emitter

ALPHABET = ('0123456789abcdefghijklmnopqrstuvwxyz'
            'ABCDEFGHIJKLMNOPQRSTUVWXYZ')


QUAD_CHARS = '0123456789abcdef'


# Bayer 4x4: the classic ordered-dither threshold matrix, as fractions of 1
BAYER = [[(v + 0.5) / 16.0 for v in row] for row in
         ((0, 8, 2, 10), (12, 4, 14, 6), (3, 11, 1, 9), (15, 7, 13, 5))]


class Picture:
    def __init__(self, canvas, name_en, name_es, mode=None, dither=False):
        self.c = canvas
        self.name_en, self.name_es, self.mode = name_en, name_es, mode
        # dither: 62 colours cannot hold a long gradient, and snapping each
        # pixel to the nearest one leaves visible bands across a sky. With
        # this on, a colour that falls between two palette entries alternates
        # between them on an ordered pattern, which reads as smooth.
        self.dither = dither
        self._grid = None

    def cells(self):
        """The picture is one solid block per character cell."""
        return (W, H)

    def grid(self):
        """Collapse the drawing canvas onto the character grid.

        Only two glyphs are ever used: the full block and the space. Half
        blocks, shades and line-drawing characters come apart the moment the
        terminal font is stretched, which is what a maximised window does to
        them, so a cell is either painted whole or left alone. Everything a
        cell covers is averaged into its one colour, which is also what makes
        the edges of a drawn scene come out soft rather than stepped.
        """
        if self._grid is not None:
            return self._grid
        cw, ch = self.cells()
        gx = self.c.w / float(cw)
        gy = self.c.h / float(ch)
        g = []
        for cy in range(ch):
            y0, y1 = int(cy * gy), max(int(cy * gy) + 1, int((cy + 1) * gy))
            row = []
            for cx in range(cw):
                x0, x1 = int(cx * gx), max(int(cx * gx) + 1, int((cx + 1) * gx))
                r = gg = b = n = 0
                for y in range(y0, min(y1, self.c.h)):
                    for x in range(x0, min(x1, self.c.w)):
                        p = self.c.px[y][x]
                        if p is None:
                            continue
                        r += (p >> 16) & 255
                        gg += (p >> 8) & 255
                        b += p & 255
                        n += 1
                if n == 0:
                    row.append(None)
                else:
                    row.append(((r // n) << 16) | ((gg // n) << 8) | (b // n))
            g.append(row)
        self._grid = g
        return g

    def build_palette(self):
        """Choose the colours the picture will be drawn in.

        The format holds 62 of them. Taking the first 62 met spends them all
        on the top of the sky and then snaps everything below to whatever
        happens to be nearest, which bands a gradient badly. Instead: count
        every colour, seed the palette with the most used ones, and then keep
        adding whichever remaining colour is furthest from everything chosen
        so far, so the range is covered rather than the first corner of it.
        """
        from collections import Counter
        counts = Counter()
        for row in self.grid():
            for p in row:
                if p is not None:
                    counts[p] += 1
        colours = [c for c, _ in counts.most_common()]
        if len(colours) <= len(ALPHABET):
            return colours

        def dist(a, b):
            return ((((a >> 16) & 255) - ((b >> 16) & 255)) ** 2
                    + (((a >> 8) & 255) - ((b >> 8) & 255)) ** 2
                    + ((a & 255) - (b & 255)) ** 2)

        seed = max(1, len(ALPHABET) // 3)
        pal = colours[:seed]
        rest = colours[seed:]
        near = [min(dist(c, p) for p in pal) for c in rest]
        while len(pal) < len(ALPHABET) and rest:
            k = max(range(len(rest)),
                    key=lambda i: near[i] * (1 + counts[rest[i]] ** 0.25))
            pal.append(rest[k])
            chosen = rest.pop(k)
            near.pop(k)
            for i, c in enumerate(rest):
                d = dist(c, chosen)
                if d < near[i]:
                    near[i] = d
        return pal

    def emit(self):
        pal = self.build_palette()
        index = {c: i for i, c in enumerate(pal)}
        cache = {}
        pair = {}

        def two_nearest(rgb):
            """The two closest palette entries, and where rgb sits between."""
            got = pair.get(rgb)
            if got is not None:
                return got
            r, g, b = (rgb >> 16) & 255, (rgb >> 8) & 255, rgb & 255
            best = sorted(
                range(len(pal)),
                key=lambda k: ((((pal[k] >> 16) & 255) - r) ** 2
                               + ((((pal[k] >> 8) & 255) - g) ** 2)
                               + ((pal[k] & 255) - b) ** 2))[:2]
            if len(best) < 2:
                got = (best[0], best[0], 0.0)
            else:
                p, q = pal[best[0]], pal[best[1]]
                vx = ((q >> 16) & 255) - ((p >> 16) & 255)
                vy = ((q >> 8) & 255) - ((p >> 8) & 255)
                vz = (q & 255) - (p & 255)
                ln = float(vx * vx + vy * vy + vz * vz)
                if ln < 1.0 or ln > 26.0 ** 2:
                    # identical, or so far apart that alternating between the
                    # two would speckle instead of blend
                    got = (best[0], best[0], 0.0)
                else:
                    t = ((r - ((p >> 16) & 255)) * vx
                         + (g - ((p >> 8) & 255)) * vy
                         + (b - (p & 255)) * vz) / ln
                    got = (best[0], best[1], min(1.0, max(0.0, t)))
            pair[rgb] = got
            return got

        def idx(rgb, x=0, y=0):
            i = index.get(rgb)
            if i is not None and not self.dither:
                return i
            if self.dither:
                a, b, t = two_nearest(rgb)
                return b if BAYER[y & 3][x & 3] < t else a
            i = cache.get(rgb)
            if i is None:
                best, bd = 0, 1 << 30
                for k, p in enumerate(pal):
                    d = (((p >> 16) & 255) - ((rgb >> 16) & 255)) ** 2 \
                        + (((p >> 8) & 255) - ((rgb >> 8) & 255)) ** 2 \
                        + ((p & 255) - (rgb & 255)) ** 2
                    if d < bd:
                        best, bd = k, d
                i = best
                cache[rgb] = i
            return i

        rows = []
        for cy, row in enumerate(self.grid()):
            g, f = [], []
            for cx, p in enumerate(row):
                if p is None:
                    g.append(' '); f.append(' ')
                else:
                    g.append('3')          # full block: the only glyph used
                    f.append(ALPHABET[idx(p, cx, cy)])
            rows.append((''.join(g).rstrip(), ''.join(f).rstrip()))

        out = ['# superterm background picture.',
               '#   >  glyph row   \' \'=empty  3=full block',
               '#      Nothing else is used: a half block or a shade character',
               '#      falls apart when the terminal font is stretched.',
               '#   :  foreground palette index per cell (\'0\'-\'9\',\'a\'-\'z\',\'A\'-\'Z\')',
               '# Drawn by tools/mkbackgrounds.py for a 128x46 desktop',
               '# (1024x768 with an 8x16 console cell, less the menu and status rows).',
               'name: ' + self.name_en,
               'name.es: ' + self.name_es]
        if self.mode:
            out.append('mode: ' + self.mode)
        out.append('palette: ' + ' '.join('%06X' % c for c in pal))
        for g, f in rows:
            # the space after the marker is part of the format: the reader
            # takes the row from the third character (st_artbg.pas:188)
            out.append('> ' + g)
            out.append(': ' + f)
        return '\n'.join(out) + '\n'


# --------------------------------------------------------------- scenes

def london():
    """Westminster from across the Thames: the Palace, Big Ben, the Eye.

    Half blocks, so a pixel here is square on screen and a circle needs the
    same radius both ways -- what used to squash the Eye into an ellipse.
    """
    c = Canvas()
    water = int(PH * 0.80)

    # --- sky
    for y in range(PH):
        t = y / float(PH - 1)
        band = mix(0x0B1026, 0x3B2A5A, min(1.0, t * 1.7))
        band = mix(band, 0x8A4A62, max(0.0, (t - 0.48) / 0.28) ** 1.4)
        band = mix(band, 0xE8734A, max(0.0, (t - 0.66) / 0.14) ** 1.6)
        c.hline(0, W - 1, y, band)
    sun_x, sun_y, sun_r = 100, water - 6, 5
    for y in range(sun_y - sun_r, sun_y + sun_r + 1):
        for x in range(sun_x - sun_r, sun_x + sun_r + 1):
            d = math.hypot(x - sun_x, y - sun_y) / sun_r
            if d <= 1.4:
                c.blend(x, y, mix(0xFFE6A8, 0xFF9A4A, min(1.0, d)),
                        max(0.0, 1.0 - d) ** 0.7)
    c.blur(0, water - 1)
    for i in range(90):
        sx, sy = int(noise(i, 3) * W), int(noise(i, 9) * PH * 0.44)
        c.blend(sx, sy, 0xFFFFFF, 0.30 + 0.45 * noise(i, 4))

    dark, mid = 0x0A0E1C, 0x141A2C
    stone = 0x1A2038          # the Palace, catching a little of the sunset

    def block(x0, x1, top, colour=dark):
        c.rect(x0, top, x1, water - 1, colour)

    # --- the far bank behind everything
    for x in range(0, W, 3):
        block(x, x + 2, water - 3 - int(noise(x // 3, 31) * 3), mid)

    # --- Victoria Tower: square, battlemented, with the flag
    block(6, 16, water - 40, stone)
    for x in range(6, 17, 2):                       # battlements
        c.rect(x, water - 43, x + 1, water - 41, stone)
    c.rect(6, water - 41, 16, water - 40, stone)
    c.vline(11, water - 48, water - 44, 0x2E3A5C)   # flagpole
    c.rect(12, water - 48, 14, water - 47, 0x9E3B3B)

    # --- the Palace: a long facade with a pinnacled roofline
    block(16, 52, water - 18, stone)
    for x in range(17, 52, 4):                      # pinnacles along the roof
        c.rect(x, water - 22, x + 1, water - 19, stone)
        c.put(x, water - 23, stone)
        c.put(x + 1, water - 23, stone)
    c.rect(20, water - 26, 23, water - 22, stone)   # the central spire
    c.vline(21, water - 30, water - 27, stone)
    c.vline(22, water - 29, water - 27, stone)
    # the roofline catches the last of the light
    for x in range(16, 53):
        c.blend(x, water - 18, 0xC98A6A, 0.35)
    for x in range(17, 52, 2):                      # lit windows, in rows
        for y in (water - 14, water - 10, water - 6):
            if noise(x, y, 43) > 0.34:
                c.put(x, y, mix(0xFFD98A, 0xE8913C, noise(x, y, 44)))

    # --- Elizabeth Tower (Big Ben): shaft, clock stage, roof, spire
    bx0, bx1, cx = 54, 59, 56
    block(bx0, bx1, water - 42, stone)
    for y in range(water - 42, water - 20, 3):      # the shaft is banded
        c.blend(bx0, y, 0xC98A6A, 0.25)
    c.rect(bx0 - 1, water - 48, bx1 + 1, water - 42, stone)       # clock stage
    for y in range(water - 47, water - 43):                       # the face
        for x in range(cx - 2, cx + 3):
            if abs(x - cx) + abs(y - (water - 45)) <= 3:
                c.put(x, y, 0xF7DC9A)
    c.put(cx, water - 45, 0x6B4A18)
    for k in range(5):                                            # the roof
        c.rect(bx0 - 1 + k, water - 53 + k, bx1 + 1 - k,
               water - 53 + k, stone)
    c.vline(cx, water - 57, water - 54, stone)                    # the spire
    c.put(cx, water - 58, 0xF7DC9A)

    # --- Westminster Bridge, running off toward the Eye
    c.rect(61, water - 6, 76, water - 5, mid)
    for x in range(62, 77, 4):
        c.vline(x, water - 4, water - 1, mid)
        c.put(x, water - 7, 0xFFD98A)

    # --- the Eye: a circle, its spokes, its cabins, its A-frame
    ex, ey, er = 90, water - 24, 17
    for a in range(0, 1440):
        r = math.radians(a * 0.25)
        c.put(int(round(ex + math.cos(r) * er)),
              int(round(ey + math.sin(r) * er)), 0xCFEAFA)
        c.blend(int(round(ex + math.cos(r) * (er - 1))),
                int(round(ey + math.sin(r) * (er - 1))), 0x7FB6D8, 0.8)
    for k in range(16):
        r = math.radians(k * 22.5)
        for t in range(1, er):
            c.blend(int(round(ex + math.cos(r) * t)),
                    int(round(ey + math.sin(r) * t)),
                    mix(0x3E6A88, 0xAFDCF2, t / float(er)), 0.85)
        c.put(int(round(ex + math.cos(r + 0.19) * er)),
              int(round(ey + math.sin(r + 0.19) * er)), 0xFFF2C8)
    c.rect(ex - 1, ey - 1, ex + 1, ey + 1, 0x6E90AA)
    for k in range(water - ey):                                  # legs
        c.put(ex - 1 - k // 2, ey + k, mid)
        c.put(ex + 1 + k // 2, ey + k, mid)

    # --- the City, small and far off on the right
    block(108, 112, water - 14); block(114, 117, water - 20)
    for y in range(water - 30, water - 20):                      # the Shard
        w = int(3 * (y - (water - 31)) / 10.0)
        c.hline(116 - w, 116 + w, y, dark)
    block(119, 123, water - 12); block(124, 127, water - 17)
    for x in range(108, W):
        for y in range(water - 20, water):
            if c.get(x, y) in (dark,) and noise(x, y, 45) > 0.86:
                c.put(x, y, mix(0xFFD08A, 0xE8913C, noise(x, y, 46)))

    # --- the river: bands, then what stands above it, rippled and fading
    for y in range(water, PH):
        t = (y - water) / float(max(1, PH - water))
        c.hline(0, W - 1, y, mix(0x22304F, 0x0A0F1E, t))
    for x in range(W):
        for y in range(water, PH):
            d = y - water
            sx = x + int(round(1.6 * math.sin(y / 2.4 + x / 7.0)))
            src = c.get(sx, water - 1 - d * 2)
            if src is not None:
                c.blend(x, y, src, max(0.0, 0.40 - d * 0.022))
    c.blur(water, PH - 1)
    return Picture(c, 'London skyline', 'Horizonte de Londres', dither=True)


def alaska():
    """A range under an aurora, with a lake below."""
    c = Canvas()
    for y in range(PH):
        c.hline(0, W - 1, y, mix(0x050A1E, 0x122448, y / (PH - 1) * 0.8))
    for i in range(150):
        x = int(noise(i, 5) * W); y = int(noise(i, 6) * PH * 0.5)
        c.put(x, y, mix(0x8FA8D8, 0xFFFFFF, noise(i, 7)))

    # aurora: two ribbons of green fading up into violet
    for band, (amp, off, hue) in enumerate(
            ((4.0, 10, 0x39FFA0), (3.0, 17, 0x66E8FF))):
        for x in range(W):
            base = off + amp * math.sin(x / 11.0 + band) \
                 + amp * 0.5 * math.sin(x / 4.3 + band * 2)
            for k in range(9):
                y = int(base + k)
                t = k / 8.0
                col = mix(hue, 0x6A3FA0, t)
                cur = c.get(x, y)
                if cur is not None:
                    c.put(x, y, mix(cur, col, (1 - t) * 0.75))

    c.blur(0, int(PH * 0.78) - 1)   # sky and aurora: no hard steps

    lake = int(PH * 0.78)
    ridge_far = [lake - 14 - 9 * math.sin(x / 17.0) - 5 * noise(x // 3, 11)
                 for x in range(W)]
    # the smooth shape of the range, and then the same with a small crumble on
    # top. The lighting is taken from the SMOOTH one: a per-column wobble makes
    # the slope flip sign at every step, and shading off that draws the whole
    # range as vertical stripes.
    ridge_base = [lake - 8 - 16 * math.exp(-((x - 40) / 22.0) ** 2)
                  - 20 * math.exp(-((x - 86) / 17.0) ** 2) for x in range(W)]
    ridge_near = [ridge_base[x] + 1.2 * math.sin(x / 3.3)
                  + 1.6 * noise(x // 6, 13) for x in range(W)]
    peak = min(ridge_near)
    span = max(1.0, lake - peak)
    for x in range(W):
        for y in range(int(ridge_far[x]), lake):
            c.put(x, y, mix(0x33436B, 0x1B2440, (y - ridge_far[x]) / 14.0))
        top = ridge_near[x]
        # the slope of the ridge here decides which way this face turns, and
        # the light comes from the left: a face falling away to the right is
        # lit, one rising to the right is in shadow. That is what gives the
        # range its volume instead of a flat wash.
        slope = ridge_base[min(W - 1, x + 2)] - ridge_base[max(0, x - 2)]
        face = 0.70 + 0.55 * max(-1.0, min(1.0, slope / 3.0))
        for y in range(int(top), lake):
            t = (y - top) / 18.0
            rock = mix(shade(0x3E4C6E, face), 0x0E1424, min(1.0, t))
            # snow settles by ALTITUDE on the range, not by a threshold per
            # column -- that is what used to draw it as vertical streaks --
            # and the line it stops at wobbles in two dimensions so it reads
            # as a ragged edge rather than a barcode
            alt = (lake - y) / span
            wob = 0.045 * math.sin(x / 9.0 + y / 3.5) \
                + 0.030 * math.sin(x / 2.7 + 1.7) \
                + 0.020 * math.sin(y / 1.9 + x / 1.3)
            k = max(0.0, min(1.0, (alt - (0.46 + wob)) / 0.09))
            snow = mix(0xC6D6EC, 0xFFFFFF, min(1.0, alt))
            c.put(x, y, mix(rock, snow, k))

    for y in range(lake, PH):
        c.hline(0, W - 1, y, mix(0x16233F, 0x080D1A, (y - lake) / (PH - lake)))
    # the lake mirrors what stands above it, dimmer with distance and rippled
    # sideways -- a strength, not a coin toss, or it comes out as confetti
    for x in range(W):
        for y in range(lake, min(PH, lake + 12)):
            d = y - lake
            sx = x + int(round(1.5 * math.sin(y / 2.6 + x / 9.0)))
            src = c.get(sx, lake - 1 - d * 2)
            if src is not None:
                c.blend(x, y, src, max(0.0, 0.34 - d * 0.028))
    c.blur(lake, PH - 1)
    return Picture(c, 'Alaska range', 'Cordillera de Alaska', dither=True)


def field():
    """An open field at golden hour: sky, hills, crop rows, a lone tree."""
    c = Canvas()
    horizon = int(PH * 0.46)
    for y in range(horizon):
        c.hline(0, W - 1, y, mix(0x2A4C8C, 0xF2B25C, (y / horizon) ** 1.4))
    sx, sy = 30, horizon - 7
    for y in range(sy - 5, sy + 6):
        for x in range(sx - 10, sx + 11):
            d = ((x - sx) / 2.0) ** 2 + (y - sy) ** 2
            if d <= 25:
                c.put(x, y, mix(0xFFF3C4, 0xFFC64A, math.sqrt(d) / 5.0))
    # clouds: soft lenticular puffs rather than dashes
    for i in range(14):
        cx = int(noise(i, 61) * W)
        cy = int(4 + noise(i, 62) * horizon * 0.62)
        rw = 7 + noise(i, 63) * 16
        rh = 1.2 + noise(i, 69) * 1.8
        for y in range(int(cy - rh) - 1, int(cy + rh) + 2):
            for x in range(int(cx - rw), int(cx + rw) + 1):
                d = ((x - cx) / rw) ** 2 + ((y - cy) / rh) ** 2
                if d <= 1.0 and c.get(x, y) is not None:
                    c.put(x, y, mix(c.get(x, y), 0xFFF0D2,
                                    0.75 * (1 - d) ** 0.6))

    c.blur(0, horizon - 1)          # the sky is one continuous thing

    # rolling hills behind the field
    for x in range(W):
        hy = horizon - 3 - 4 * math.sin(x / 21.0) - 2 * noise(x // 4, 65)
        for y in range(int(hy), horizon):
            c.put(x, y, mix(0x6E7A3A, 0x4A5A22, (y - hy) / 6.0))

    # the field itself: rows converging toward the sun
    # the crop, in perspective: the furrows are straight lines on the ground
    # that meet at the vanishing point, so they spread apart as they come
    # forward instead of standing as vertical stripes
    vanish = sx
    for y in range(horizon, PH):
        t = (y - horizon) / max(1, PH - horizon)
        base = mix(0xC8A05A, 0x5E4E1E, t ** 0.8)
        c.hline(0, W - 1, y, base)
        depth = max(0.04, t)
        for k in range(-40, 41):
            fx = vanish + k * 3.0 * depth * 2.2
            # a furrow rarely falls on a whole pixel: split it between the two
            # it straddles, which is what stops the rows reading as a grid
            x0 = int(math.floor(fx))
            fr = fx - x0
            a = 0.14 + 0.20 * t
            c.blend(x0, y, 0xF2D089, a * (1.0 - fr))
            c.blend(x0 + 1, y, 0xF2D089, a * fr)
        for x in range(W):
            n = noise(x, y, 66)
            if n > 0.80:
                c.blend(x, y, 0x8C7A3A, 0.22 * (n - 0.80) / 0.20)

    c.blur(horizon, PH - 1)         # corduroy, not a grid of dots

    # a lone tree on the right
    tx, ty = 96, horizon + 10
    c.rect(tx - 1, ty, tx + 1, PH - 6, 0x3A2A18)
    for y in range(ty - 12, ty + 2):
        r = 9 - abs(y - (ty - 5)) * 0.7
        for x in range(int(tx - r), int(tx + r) + 1):
            if noise(x, y, 67) > 0.22:
                c.put(x, y, mix(0x35521F, 0x6E8A32, noise(x, y, 68)))
    return Picture(c, 'Open field', 'Campo abierto', dither=True)


def sea():
    """A boat on the water at sunset."""
    c = Canvas()
    horizon = int(PH * 0.52)
    for y in range(horizon):
        t = y / horizon
        c.hline(0, W - 1, y, mix(0x1B2A6B, 0xFF9B4A, t ** 1.25))
    sx, sy, sr = 88, horizon - 4, 5
    for y in range(sy - sr, sy + sr + 1):
        for x in range(sx - sr * 2, sx + sr * 2 + 1):
            d = ((x - sx) / 2.0) ** 2 + (y - sy) ** 2
            if d <= sr * sr:
                c.put(x, y, mix(0xFFF0B0, 0xFF7A3C, math.sqrt(d) / sr))
    # long, low clouds: soft ellipses rather than one-pixel dashes
    for i in range(22):
        cx = int(noise(i, 71) * W)
        cy = int(1 + noise(i, 72) * horizon * 0.72)
        rw = 6 + noise(i, 73) * 15
        rh = 0.9 + noise(i, 74) * 1.4
        for y in range(int(cy - rh) - 1, int(cy + rh) + 2):
            for x in range(int(cx - rw), int(cx + rw) + 1):
                d = ((x - cx) / rw) ** 2 + ((y - cy) / rh) ** 2
                if d <= 1.0:
                    c.blend(x, y, 0xFFD9A0, 0.55 * (1 - d) ** 0.7)
    c.blur(0, horizon - 1)

    for y in range(horizon, PH):
        t = (y - horizon) / (PH - horizon)
        c.hline(0, W - 1, y, mix(0x1E3560, 0x081226, t))
    # the sun's path on the water: widens as it comes forward, and breaks up
    # into separate glints instead of a solid wedge
    for y in range(horizon, PH):
        t = (y - horizon) / max(1, PH - horizon)
        spread = 1 + int(t * 26)
        for x in range(max(0, sx - spread), min(W, sx + spread + 1)):
            cur = c.get(x, y)
            if cur is None:
                continue
            across = abs(x - sx) / float(spread + 1)
            # brightness, not presence: the path is continuous down the middle
            # and frays at its edges, instead of being a scatter of dots
            k = (1.0 - across ** 1.7) * (1.0 - t * 0.45)
            k *= 0.45 + 0.55 * noise(x, y + 31)
            c.blend(x, y, 0xFFCE86, 0.62 * max(0.0, k))
    c.blur(horizon, PH - 1)
    hull = 0x14202E
    by = horizon + 6
    c.rect(44, by, 60, by + 1, hull)
    c.hline(46, 58, by + 2, hull)
    c.vline(52, by - 12, by - 1, 0xE8E2D0)                # mast
    for k in range(10):                                   # sail
        c.hline(53, 53 + int(k * 0.9), by - 12 + k, mix(0xFFF6E0, 0xE0C9A0,
                                                        k / 9.0))
    for y in range(by + 3, min(PH, by + 8)):
        c.put(52, y, mix(c.get(52, y), 0xE8E2D0, 0.25))
    return Picture(c, 'Boat at sunset', 'Barca al atardecer',
                   dither=True)


def phoenix(src='backgrounds/phoenix.art'):
    """The 7kas phoenix, resampled from the original artwork.

    The bird is redrawn at the new size from the picture that shipped before,
    so it stays the same bird. What changes is what happens around it: the old
    file painted a colour on the background half of every cell it touched, so
    on a light desktop the bird sat inside dark rectangles. Here a pixel is
    either the bird or nothing at all, and the desktop shows through.
    """
    pal, g, f, b = [], [], [], []
    with open(src, encoding='utf-8') as fh:
        for line in fh:
            line = line.rstrip('\n')
            if line.startswith('palette:'):
                pal = [int(v, 16) for v in line.split(':', 1)[1].split()]
            elif line.startswith('>'):
                g.append(line[1:])
            elif line.startswith(':'):
                f.append(line[1:])
            elif line.startswith('.'):
                b.append(line[1:])

    def col(row, x):
        if x < len(row) and row[x] != ' ':
            i = ALPHABET.find(row[x])
            if 0 <= i < len(pal):
                return pal[i]
        return None

    sw = max(len(r) for r in g)
    sh = len(g) * 2
    src_px = [[None] * sw for _ in range(sh)]
    for r in range(len(g)):
        fr = f[r] if r < len(f) else ''
        br = b[r] if r < len(b) else ''
        for x in range(len(g[r])):
            ch = g[r][x]
            if ch == ' ':
                continue
            if ch == '1':
                top, bot = col(fr, x), col(br, x)
            elif ch == '2':
                bot, top = col(fr, x), col(br, x)
            else:
                top = bot = col(fr, x)
            src_px[r * 2][x] = top
            src_px[r * 2 + 1][x] = bot

    c = Canvas()
    scale = min(W / float(sw), PH / float(sh))
    dw, dh = int(sw * scale), int(sh * scale)
    ox, oy = (W - dw) // 2, (PH - dh) // 2
    for y in range(dh):
        for x in range(dw):
            p = src_px[min(sh - 1, int(y / scale))][min(sw - 1, int(x / scale))]
            if p is None:
                continue
            # the brand's own violets and blues are the bird; anything that is
            # essentially black was filler around it, and is dropped so the
            # desktop shows through instead
            lum = (((p >> 16) & 255) * 0.3 + ((p >> 8) & 255) * 0.6
                   + (p & 255) * 0.1)
            if lum < 26:
                continue
            c.put(ox + x, oy + y, p)
    return Picture(c, '7kas phoenix', 'Ave fenix de 7kas')


def from_image(path, name_en, name_es, drop_black=True, fill=True):
    """Convert a real picture into the half-block format.

    Pixel art needs care on the way down. A smooth filter (Lanczos, bicubic)
    rings and blurs hard edges, which is exactly what this kind of artwork is
    made of, so the picture arrives soft. Instead:

      1. the source is quantised to a small palette first, which throws away
         the halo of near-duplicate colours a scaled or recompressed
         screenshot carries and leaves flat areas genuinely flat;
      2. it is reduced by BOX -- a plain average of the pixels that fall in
         each destination cell -- which neither rings nor invents colour;
      3. the result is snapped back onto that palette, so an edge stays one
         colour against another instead of fading through three.

    fill stretches the picture over the whole desktop the way the drawn
    scenes cover it. The artwork this is used for was made for a screen whose
    pixels were not square anyway, so filling looks more like the original
    than letterboxing does.
    """
    from PIL import Image
    src = Image.open(path)
    # artwork with an alpha channel says for itself what is picture and what
    # is nothing: those pixels are left empty and the desktop shows through,
    # which is what keeps a logo from sitting inside a slab of its own
    alpha = None
    if src.mode in ('RGBA', 'LA') or 'transparency' in src.info:
        src = src.convert('RGBA')
        alpha = src.getchannel('A')
        # take the colour as it is, NOT composited over anything. Laying the
        # artwork on black first turns every antialiased edge pixel into a
        # dark one, and those became a black fringe around the picture that
        # looks wrong on any desktop that is not black.
        im = src.convert('RGB')
    else:
        im = src.convert('RGB')

    # 1. flatten to the artwork's own palette
    q = im.quantize(colors=48, method=Image.MEDIANCUT, dither=Image.NONE)
    im = q.convert('RGB')

    # the picture is drawn with one full block per character cell, so the
    # destination grid IS the desktop: 128 x 46. Reducing straight onto it
    # keeps the conversion as sharp as it can be -- every cell is decided by
    # the source pixels that actually fall in it, with nothing resampled twice.
    sw, sh = im.size
    if fill:
        dw, dh = W, H
    else:
        # A cell is 8 wide by 16 tall, so it counts double vertically: to keep
        # the artwork's real proportions the grid needs dw / dh = 2 * sw / sh.
        want = 2.0 * sw / float(sh)
        dh = min(H, int(W / want))
        dw = min(W, max(1, int(dh * want)))
        dh = max(1, dh)

    # 2. average down, then 3. snap back to the flat palette
    im = im.resize((dw, dh), Image.BOX)
    im = im.quantize(palette=q, dither=Image.NONE).convert('RGB')
    ap = None
    if alpha is not None:
        ap = alpha.resize((dw, dh), Image.BOX).load()

    px = im.load()
    c = Canvas(W, H)
    ox, oy = (W - dw) // 2, (H - dh) // 2
    for y in range(dh):
        for x in range(dw):
            # an edge cell is either in or out: keeping the half-covered
            # ones is what draws an outline in a colour that belongs to
            # neither the picture nor the desktop
            if ap is not None and ap[x, y] < 160:
                continue
            r, g, b = px[x, y]
            if drop_black and ap is None \
                    and (r * 0.3 + g * 0.6 + b * 0.1) < 22:
                continue
            c.put(ox + x, oy + y, (r << 16) | (g << 8) | b)
    return Picture(c, name_en, name_es)


def goody():
    """The Goody loading screen (Opera Soft), as a desktop picture."""
    return from_image(GOODY_SRC, 'Goody', 'Goody')


def phoenix():
    """The 7kas bird, from the brand's own vector artwork.

    assets/7kas-bird.svg is the drawing the site uses; it is rasterised well
    above the target and averaged down, so the flat facets stay flat and the
    edges between them stay sharp. Its transparency is carried through: the
    bird is the picture and everything around it is nothing at all, so it
    sits on a desktop of any colour without a box around it. Proportions are
    kept -- it is a logo, not a landscape.
    """
    import subprocess
    png = '/tmp/superterm-7kas-bird.png'
    subprocess.run(['rsvg-convert', '-w', '1536', '-b', 'none',
                    PHOENIX_SVG, '-o', png], check=True)
    return from_image(png, '7kas phoenix', 'Ave fenix de 7kas', fill=False)


# The three seamless patterns -- wall, weave, circuit -- are deliberately not
# here. They are meant for the tiled layout: a small unit that joins to itself
# on all four sides and repeats across a desktop of any size. Redrawing them
# at 128x46 would make them one big picture and destroy the only thing they
# are for.
SCENES = {
    'phoenix': phoenix,
    'field': field,
    'london': london,
    'alaska': alaska,
    'sea': sea,
    'goody': goody,
}


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else 'backgrounds'
    os.makedirs(out, exist_ok=True)
    for name, fn in SCENES.items():
        pic = fn()
        path = os.path.join(out, name + '.art')
        with open(path, 'w', encoding='utf-8') as f:
            f.write(pic.emit())
            cw, ch = pic.cells()
        print("%-12s %dx%d cells" % (name, cw, ch))


if __name__ == '__main__':
    main()
