#!/usr/bin/env python3
"""Draw superterm's desktop backgrounds.

The pictures are plain text (see src/st_artbg.pas): one row of glyphs, one of
foreground palette indexes and one of background indexes. Two of the glyphs
are the half blocks, so a cell holds two independently coloured pixels and a
picture has twice the vertical resolution of the text grid it lives in.

Everything here therefore draws into a PIXEL canvas of W x (2*H) and the
emitter folds pairs of pixel rows into cells:

    both pixels transparent  -> ' '      the desktop shows through
    only the top one         -> upper half block, fg = top
    only the bottom one      -> lower half block, fg = bottom
    both, same colour        -> full block
    both, different          -> upper half block, fg = top, bg = bottom

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


class Picture:
    def __init__(self, canvas, name_en, name_es, mode=None, quad=False):
        self.c = canvas
        self.name_en, self.name_es, self.mode = name_en, name_es, mode
        # quad: the canvas is 2W x 2H pixels and each cell carries a 2x2
        # block in two colours, which is twice the horizontal detail the
        # half blocks can hold. See 'charset: quad' in src/st_artbg.pas.
        self.quad = quad

    def cells(self):
        return (self.c.w // 2, self.c.h // 2) if self.quad \
            else (self.c.w, self.c.h // 2)

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
        for row in self.c.px:
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
            k = max(range(len(rest)), key=lambda i: near[i] * (1 + counts[rest[i]] ** 0.25))
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

        def idx(rgb):
            i = index.get(rgb)
            if i is not None:
                return i
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
        if self.quad:
            cw, ch = self.cells()
            for cy in range(ch):
                g, f, b = [], [], []
                for cx in range(cw):
                    quarters = [self.c.get(cx * 2, cy * 2),
                                self.c.get(cx * 2 + 1, cy * 2),
                                self.c.get(cx * 2, cy * 2 + 1),
                                self.c.get(cx * 2 + 1, cy * 2 + 1)]
                    present = [q for q in quarters if q is not None]
                    if not present:
                        g.append('0'); f.append(' '); b.append(' ')
                        continue
                    # a cell holds two colours, so pick the two that cover
                    # the block best and put every quarter on the nearer one
                    order = sorted(set(present),
                                   key=lambda q: -present.count(q))
                    fg = order[0]
                    bg = order[1] if len(order) > 1 else None
                    if bg is not None and len(order) > 2:
                        # more than two: keep the two furthest apart of the
                        # three most common, so an edge stays an edge
                        def far(a, b_):
                            return ((((a >> 16) & 255) - ((b_ >> 16) & 255)) ** 2
                                    + (((a >> 8) & 255) - ((b_ >> 8) & 255)) ** 2
                                    + ((a & 255) - (b_ & 255)) ** 2)
                        cand = order[:3]
                        fg, bg = max(((p, q) for i, p in enumerate(cand)
                                      for q in cand[i + 1:]),
                                     key=lambda pr: far(pr[0], pr[1]))
                        if present.count(bg) > present.count(fg):
                            fg, bg = bg, fg
                    mask = 0
                    for k, q in enumerate(quarters):
                        if q is None:
                            continue
                        if bg is None or nearer(q, fg, bg):
                            mask |= 1 << k
                    # quarters that are transparent stay off; if that leaves
                    # the cell empty there is nothing to draw
                    if mask == 0 and bg is None:
                        g.append('0'); f.append(' '); b.append(' ')
                        continue
                    g.append(QUAD_CHARS[mask])
                    f.append(ALPHABET[idx(fg)])
                    # the off quarters only need a colour when some of them
                    # are actually part of the picture
                    if bg is not None and any(
                            quarters[k] is not None and not (mask & (1 << k))
                            for k in range(4)):
                        b.append(ALPHABET[idx(bg)])
                    else:
                        b.append(' ')
                rows.append((''.join(g).rstrip(),
                             ''.join(f).rstrip(),
                             ''.join(b).rstrip()))
        else:
            for cy in range(self.c.h // 2):
                g, f, b = [], [], []
                for x in range(self.c.w):
                    top = self.c.get(x, cy * 2)
                    bot = self.c.get(x, cy * 2 + 1)
                    if top is None and bot is None:
                        g.append(' '); f.append(' '); b.append(' ')
                    elif bot is None:
                        g.append('1'); f.append(ALPHABET[idx(top)]); b.append(' ')
                    elif top is None:
                        g.append('2'); f.append(ALPHABET[idx(bot)]); b.append(' ')
                    elif top == bot:
                        g.append('3'); f.append(ALPHABET[idx(top)]); b.append(' ')
                    else:
                        g.append('1')
                        f.append(ALPHABET[idx(top)])
                        b.append(ALPHABET[idx(bot)])
                rows.append((''.join(g).rstrip(),
                             ''.join(f).rstrip(),
                             ''.join(b).rstrip()))

        out = ['# superterm background picture.',
               '#   >  glyph row   \' \'=empty  1=upper half  2=lower half  3=full block',
               '#                  4=light 5=medium 6=dark shade, anything else literal',
               '#   :  foreground palette index per cell (\'0\'-\'9\',\'a\'-\'z\',\'A\'-\'Z\')',
               '#   .  background palette index (optional line)',
               '# Drawn by tools/mkbackgrounds.py for a 128x46 desktop',
               '# (1024x768 with an 8x16 console cell, less the menu and status rows).',
               'name: ' + self.name_en,
               'name.es: ' + self.name_es]
        if self.mode:
            out.append('mode: ' + self.mode)
        if self.quad:
            out.append('charset: quad')
        out.append('palette: ' + ' '.join('%06X' % c for c in pal))
        for g, f, b in rows:
            out.append('>' + g)
            out.append(':' + f)
            out.append('.' + b)
        return '\n'.join(out) + '\n'


# --------------------------------------------------------------- scenes

def london():
    """The Thames skyline: Big Ben, the Eye, St Paul's, the towers."""
    c = Canvas()
    sky_top, sky_bot = 0x0B1026, 0xE8734A
    for y in range(PH):
        t = y / (PH - 1)
        band = mix(sky_top, 0x3B2A5A, min(1.0, t * 1.7))
        band = mix(band, sky_bot, max(0.0, (t - 0.55) / 0.45) ** 1.5)
        c.hline(0, W - 1, y, band)

    sun_y, sun_x, sun_r = int(PH * 0.62), 96, 6
    for y in range(sun_y - sun_r, sun_y + sun_r + 1):
        for x in range(sun_x - sun_r * 2, sun_x + sun_r * 2 + 1):
            d = ((x - sun_x) / 2.0) ** 2 + (y - sun_y) ** 2
            if d <= sun_r * sun_r:
                c.put(x, y, mix(0xFFD98A, 0xFF9A4A, math.sqrt(d) / sun_r))

    for i in range(70):
        sx = int(noise(i, 3) * W)
        sy = int(noise(i, 9) * PH * 0.45)
        if c.get(sx, sy) is not None:
            c.put(sx, sy, mix(c.get(sx, sy), 0xFFFFFF, 0.55))

    water = int(PH * 0.80)
    for y in range(water, PH):
        t = (y - water) / max(1, PH - water)
        c.hline(0, W - 1, y, mix(0x24304F, 0x0E1428, t))
    for i in range(260):
        x = int(noise(i, 21) * W)
        y = water + int(noise(i, 22) * (PH - water))
        c.put(x, y, mix(c.get(x, y), 0xE8A06A, 0.30 + 0.4 * noise(i, 23)))

    dark = 0x0A0E1C

    def block(x0, x1, top, colour=dark):
        c.rect(x0, top, x1, water - 1, colour)

    # far bank, then the landmarks left to right
    for i in range(0, W, 3):
        block(i, i + 2, water - 3 - int(noise(i, 31) * 4), shade(dark, 1.6))

    block(4, 10, water - 16); block(6, 8, water - 20)          # tower
    block(14, 17, water - 12)
    # Big Ben
    block(21, 26, water - 34)
    c.rect(22, water - 40, 25, water - 35, dark)
    c.rect(23, water - 37, 24, water - 36, 0xF2C86B)           # clock face
    for y in range(water - 44, water - 40):
        c.hline(23, 24, y, dark)
    # Parliament
    block(28, 44, water - 18)
    for x in range(29, 44, 3):
        block(x, x + 1, water - 22)
    # the Eye
    ex, ey, er = 58, water - 20, 15
    for a in range(0, 360, 3):
        r = math.radians(a)
        c.put(int(ex + math.cos(r) * er * 0.5), int(ey + math.sin(r) * er),
              0x9FD8F2)
    for a in range(0, 360, 30):
        r = math.radians(a)
        for k in range(0, er):
            c.put(int(ex + math.cos(r) * k * 0.5), int(ey + math.sin(r) * k),
                  mix(0x4E7FA8, 0x9FD8F2, k / er))
    block(ex - 1, ex + 1, water - 5)
    # St Paul's
    block(74, 84, water - 14)
    for y in range(water - 22, water - 14):
        w = int(5 * math.sin(math.pi * (y - (water - 23)) / 9.0))
        c.hline(79 - w, 79 + w, y, dark)
    c.vline(79, water - 26, water - 23, dark)
    # the towers of the City
    block(88, 93, water - 26); block(95, 99, water - 33)
    block(101, 104, water - 21)
    block(108, 116, water - 30)
    for y in range(water - 38, water - 30):                     # the Shard
        w = int(4 * (y - (water - 39)) / 8.0)
        c.hline(112 - w, 112 + w, y, dark)
    block(119, 126, water - 17)

    # lit windows
    for i in range(700):
        x = int(noise(i, 41) * W)
        y = int(noise(i, 42) * (water - 1))
        if c.get(x, y) in (dark,) and noise(i, 43) > 0.55:
            c.put(x, y, mix(0xFFD98A, 0xFF8C42, noise(i, 44)))
    # reflections
    for x in range(W):
        for y in range(water, min(PH, water + 8)):
            src = c.get(x, water - 1 - (y - water) * 2)
            if src is not None and src != dark and noise(x, y) > 0.55:
                c.put(x, y, mix(c.get(x, y), src, 0.35))
    return Picture(c, 'London skyline', 'Horizonte de Londres')


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

    lake = int(PH * 0.78)
    ridge_far = [lake - 14 - 9 * math.sin(x / 17.0) - 5 * noise(x // 3, 11)
                 for x in range(W)]
    ridge_near = [lake - 6 - 16 * math.exp(-((x - 40) / 22.0) ** 2)
                  - 20 * math.exp(-((x - 86) / 17.0) ** 2)
                  - 4 * noise(x // 2, 13) for x in range(W)]
    for x in range(W):
        for y in range(int(ridge_far[x]), lake):
            c.put(x, y, mix(0x33436B, 0x1B2440, (y - ridge_far[x]) / 14.0))
        top = ridge_near[x]
        for y in range(int(top), lake):
            t = (y - top) / 20.0
            # light comes from the left, so the western face is brighter
            face = 0.85 + 0.30 * math.sin(x / 9.0)
            rock = mix(shade(0x4A5878, face), 0x141C30, min(1.0, t))
            # snow lies above a line that wanders, with a soft ragged edge --
            # judged by height on the mountain, not by a per-column toss,
            # which is what made it look like a barcode
            depth = y - top
            edge = 5.0 + 3.5 * math.sin(x / 13.0) + 2.5 * noise(x // 3, 17)
            if depth < edge:
                snow = mix(0xFFFFFF, 0xC6D6EC, min(1.0, depth / max(1.0, edge)))
                c.put(x, y, mix(snow, rock, 0.15 * noise(x, y, 18)))
            elif depth < edge + 3 and noise(x, y, 19) > 0.55:
                c.put(x, y, mix(0xC6D6EC, rock, 0.5))     # patchy transition
            else:
                c.put(x, y, rock)

    for y in range(lake, PH):
        c.hline(0, W - 1, y, mix(0x16233F, 0x080D1A, (y - lake) / (PH - lake)))
    for x in range(W):
        for y in range(lake, min(PH, lake + 10)):
            src = c.get(x, lake - 1 - (y - lake) * 2)
            if src is not None and noise(x, y + 5) > 0.45:
                c.put(x, y, mix(c.get(x, y), src, 0.30))
    return Picture(c, 'Alaska range', 'Cordillera de Alaska')


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
            x = int(round(fx))
            if 0 <= x < W:
                c.put(x, y, mix(base, 0xF2D089, 0.20 + 0.30 * t))
        for x in range(W):
            if noise(x, y, 66) > 0.90:
                c.put(x, y, mix(base, 0x8C7A3A, 0.45))

    # a lone tree on the right
    tx, ty = 96, horizon + 10
    c.rect(tx - 1, ty, tx + 1, PH - 6, 0x3A2A18)
    for y in range(ty - 12, ty + 2):
        r = 9 - abs(y - (ty - 5)) * 0.7
        for x in range(int(tx - r), int(tx + r) + 1):
            if noise(x, y, 67) > 0.22:
                c.put(x, y, mix(0x35521F, 0x6E8A32, noise(x, y, 68)))
    return Picture(c, 'Open field', 'Campo abierto')


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
    for i in range(30):
        cx = int(noise(i, 71) * W); cy = int(noise(i, 72) * horizon * 0.6)
        for x in range(cx, cx + 6 + int(noise(i, 73) * 14)):
            if c.get(x, cy) is not None:
                c.put(x, cy, mix(c.get(x, cy), 0xFFD9A0, 0.5))

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
            chance = (1.0 - across ** 1.6) * (1.0 - t * 0.55)
            if noise(x, y + 31) < chance * 0.85:
                c.put(x, y, mix(cur, 0xFFCE86, 0.30 + 0.45 * (1 - across)))
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
    return Picture(c, 'Boat at sunset', 'Barca al atardecer')


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

    # a converted picture is drawn with quadrants, so its canvas is twice as
    # wide in pixels as the desktop is in cells: 256 x 92 for a 128 x 46
    # desktop, which is where the extra sharpness comes from
    QW, QH = W * 2, PH
    sw, sh = im.size
    if fill:
        dw, dh = QW, QH
    else:
        # A quadrant subpixel is NOT square on screen: in an 8x16 cell it is
        # 4 wide by 8 tall, so it counts double vertically. Fitting as though
        # they were square is what left the bird squashed to half its width.
        # Keep the source's real proportions: dw / dh = 2 * sw / sh.
        want = 2.0 * sw / float(sh)
        dh = min(QH, int(QW / want))
        dw = min(QW, max(1, int(dh * want)))
        dh = max(1, dh)

    # 2. average down, then 3. snap back to the flat palette
    im = im.resize((dw, dh), Image.BOX)
    im = im.quantize(palette=q, dither=Image.NONE).convert('RGB')
    ap = None
    if alpha is not None:
        ap = alpha.resize((dw, dh), Image.BOX).load()

    px = im.load()
    c = Canvas(QW, QH)
    ox, oy = ((QW - dw) // 2) & ~1, ((QH - dh) // 2) & ~1
    for y in range(dh):
        for x in range(dw):
            # an edge pixel is either in or out: keeping the half-covered
            # ones is what draws an outline in a colour that belongs to
            # neither the picture nor the desktop
            if ap is not None and ap[x, y] < 160:
                continue
            r, g, b = px[x, y]
            if drop_black and ap is None \
                    and (r * 0.3 + g * 0.6 + b * 0.1) < 22:
                continue
            c.put(ox + x, oy + y, (r << 16) | (g << 8) | b)
    return Picture(c, name_en, name_es, quad=True)


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
        print("%-12s %dx%d cells%s" % (name, cw, ch, "  (quadrants)" if pic.quad else ""))


if __name__ == '__main__':
    main()
