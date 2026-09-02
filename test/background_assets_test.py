#!/usr/bin/env python3
"""Validate reproducible, edge-safe built-in desktop artwork."""

import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'assets' / 'alien-hacker.png'
ART = ROOT / 'backgrounds' / 'goody.art'
GENERATOR = ROOT / 'tools' / 'mkbackgrounds.py'
PROBE = ROOT / 'test' / 'background_size_probe.pas'
DESKTOP_SHOT = ROOT / 'screenshots' / 'desktop-goody.png'
BACKGROUND_SHOT = ROOT / 'screenshots' / 'bg-goody.png'
MENU_SHOT = ROOT / 'screenshots' / 'backgrounds-menu.png'
OPTIONS_SHOT = ROOT / 'screenshots' / 'options.png'
BACKGROUND_GIF = ROOT / 'screenshots' / 'backgrounds.gif'
ALPHABET = ('0123456789abcdefghijklmnopqrstuvwxyz'
            'ABCDEFGHIJKLMNOPQRSTUVWXYZ')
failed = False


def pixels(image):
    """Return flat pixels without warning on either old or new Pillow."""
    getter = getattr(image, 'get_flattened_data', None)
    return list(getter() if getter is not None else image.getdata())


def check(label, condition):
    global failed
    print(f'{label:42s}: {"OK" if condition else "FAIL"}')
    if not condition:
        failed = True


def loaded_art_size():
    """Ask the real Pascal loader for the installed artwork geometry."""
    fpc = os.environ.get('FPC') or shutil.which('fpc')
    if not fpc:
        return None, 'Free Pascal compiler not found'
    with tempfile.TemporaryDirectory(prefix='superterm-art-probe-') as temp:
        build = Path(temp)
        binary = build / 'background-size-probe'
        compile_result = subprocess.run(
            [fpc, '-Mobjfpc', '-Sh', f'-Fu{ROOT / "src"}',
             f'-FU{build}', f'-FE{build}', f'-o{binary}', os.fspath(PROBE)],
            cwd=ROOT, text=True, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, check=False)
        if compile_result.returncode != 0:
            return None, compile_result.stdout.strip()
        probe_home = build / 'home'
        probe_home.mkdir()
        environment = os.environ.copy()
        environment['HOME'] = os.fspath(probe_home)
        environment['SUPERTERM_BACKGROUNDS'] = os.fspath(ROOT / 'backgrounds')
        probe_result = subprocess.run(
            [os.fspath(binary)], cwd=ROOT, env=environment, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=False)
        if probe_result.returncode != 0:
            return None, probe_result.stdout.strip()
        return probe_result.stdout.strip(), ''


with Image.open(SOURCE) as source:
    rgba = source.convert('RGBA')
    alpha = rgba.getchannel('A')
    width, height = rgba.size
    extrema = alpha.getextrema()
    border = []
    border.extend(pixels(alpha.crop((0, 0, width, 1))))
    border.extend(pixels(alpha.crop((0, height - 1, width, height))))
    border.extend(pixels(alpha.crop((0, 0, 1, height))))
    border.extend(pixels(alpha.crop((width - 1, 0, width, height))))
    center = alpha.crop((width // 3, height // 3,
                         width * 2 // 3, height * 2 // 3))
    center_mean = sum(pixels(center)) / float(center.width * center.height)

check('alien source is the optimized RGBA asset',
      (width, height) == (768, 512) and rgba.mode == 'RGBA')
check('alien source contains real transparency',
      extrema[0] == 0 and extrema[1] >= 250)
check('all four outer edges fade to transparent',
      max(border) <= 3 and center_mean >= 240)

spec = importlib.util.spec_from_file_location('mkbackgrounds', GENERATOR)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
module.GOODY_SRC = os.fspath(SOURCE)
module.PHOENIX_SVG = os.fspath(ROOT / 'assets' / '7kas-bird.svg')
generated_assets = {name: factory().emit()
                    for name, factory in module.SCENES.items()}
picture = module.goody()
generated = generated_assets['goody']
checked_in = ART.read_text(encoding='utf-8')

check('legacy goody identifier regenerates exactly', generated == checked_in)
check('every generated background is reproducible',
      all(text == (ROOT / 'backgrounds' / f'{name}.art').read_text(
          encoding='utf-8') for name, text in generated_assets.items()))
check('visible names identify the original artwork',
      picture.name_en == 'Alien hacker' and
      picture.name_es == 'Hacker alienigena')
check('generator targets an exact 128x46 grid', picture.cells() == (128, 46))

parser_size, parser_error = loaded_art_size()
if parser_error:
    print(f'Pascal loader probe: {parser_error}')
check('real Pascal loader sees exact 128x46 canvas', parser_size == '128x46')

lines = checked_in.splitlines()
declared_width = next((line.removeprefix('width: ').strip()
                       for line in lines if line.startswith('width: ')), '')
palette_line = next((line for line in lines if line.startswith('palette: ')), '')
palette = palette_line.removeprefix('palette: ').split()
glyph_rows = [line[2:] if line.startswith('> ') else ''
              for line in lines if line == '>' or line.startswith('> ')]
color_rows = [line[2:] if line.startswith(': ') else ''
              for line in lines if line == ':' or line.startswith(': ')]

check('terminal palette fits the 62-index format',
      1 <= len(palette) <= len(ALPHABET) and
      all(len(value) == 6 and
          all(ch in '0123456789ABCDEF' for ch in value)
          for value in palette))
check('terminal artwork emits exactly 46 row pairs',
      len(glyph_rows) == 46 and len(color_rows) == 46)
check('transparent edge has an explicit logical width', declared_width == '128')
check('terminal glyph grid uses only filled cell or empty',
      all(len(row) <= 128 and set(row) <= {' ', '3'} for row in glyph_rows))

indices_valid = True
for glyphs, colors in zip(glyph_rows, color_rows):
    colors = colors.ljust(len(glyphs))
    for position, glyph in enumerate(glyphs):
        if glyph == ' ':
            continue
        palette_index = ALPHABET.find(colors[position])
        if palette_index < 0 or palette_index >= len(palette):
            indices_valid = False
            break
check('every occupied cell has a valid palette index', indices_valid)

padded = [row.ljust(128) for row in glyph_rows]
occupied = sum(cell == '3' for row in padded for cell in row)
check('cell fade leaves every outer boundary empty',
      all(cell == ' ' for cell in padded[0]) and
      all(cell == ' ' for cell in padded[-1]) and
      all(row[0] == ' ' and row[-1] == ' ' for row in padded))
check('cell fade keeps a substantial central subject',
      2500 <= occupied < 128 * 46)

rendered_palette = {tuple(bytes.fromhex(value)) for value in palette}


def art_palette(text):
    """Return the exact RGB colours declared by one generated .art file."""
    line = next((item for item in text.splitlines()
                 if item.startswith('palette: ')), '')
    return {tuple(bytes.fromhex(value))
            for value in line.removeprefix('palette: ').split()}


london_palette = art_palette(generated_assets['london'])


def screenshot_signature(path):
    with Image.open(path) as screenshot:
        rgb = screenshot.convert('RGB')
        return screenshot.size, len(set(pixels(rgb)) & rendered_palette)


def standalone_matches_art(path):
    """The documented 8x16-cell render must contain no font-made seams."""
    with Image.open(path) as screenshot:
        rgb = screenshot.convert('RGB')
        if rgb.size != (128 * 8, 46 * 16):
            return False
        source = rgb.load()
        for cy, glyphs in enumerate(glyph_rows):
            glyphs = glyphs.ljust(128)
            colors = color_rows[cy].ljust(128)
            for cx, glyph in enumerate(glyphs):
                expected = (0, 0, 0)
                if glyph != ' ':
                    palette_index = ALPHABET.find(colors[cx])
                    if palette_index < 0 or palette_index >= len(palette):
                        return False
                    expected = tuple(bytes.fromhex(palette[palette_index]))
                for py in range(cy * 16, (cy + 1) * 16):
                    for px in range(cx * 8, (cx + 1) * 8):
                        if source[px, py] != expected:
                            return False
        return True


desktop_size, desktop_matches = screenshot_signature(DESKTOP_SHOT)
background_size, background_matches = screenshot_signature(BACKGROUND_SHOT)
menu_size, menu_matches = screenshot_signature(MENU_SHOT)
options_size, options_matches = screenshot_signature(OPTIONS_SHOT)
with Image.open(BACKGROUND_GIF) as animation:
    gif_size = animation.size
    gif_frames = animation.n_frames
    gif_goody_matches = []
    gif_london_matches = []
    for frame in range(animation.n_frames):
        animation.seek(frame)
        frame_colours = set(pixels(animation.convert('RGB')))
        gif_goody_matches.append(len(frame_colours & rendered_palette))
        gif_london_matches.append(len(frame_colours & london_palette))

check('desktop is a real 128x48 Konsole capture',
      desktop_size == (1290, 912))
check('standalone art is an exact 128x46 cell grid',
      background_size == (1024, 736))
check('standalone art is exact filled cells without seams',
      standalone_matches_art(BACKGROUND_SHOT))
check('background menu is a real 128x48 capture',
      menu_size == (1290, 912))
check('options menu is a real 128x48 capture',
      options_size == (1290, 912))
check('background animation keeps its real capture geometry',
      gif_size == (1290, 912) and gif_frames == 15)
# Filled cells are emitted as spaces on exact RGB backgrounds. Requiring most
# palette colours ties every screenshot to this exact .art palette; a capture
# with old shade glyphs or unrelated colours cannot pass by dimensions alone.
check('static documentation renders this exact artwork',
      min(desktop_matches, background_matches, menu_matches,
          options_matches) >= 40)
check('animation starts with the empty desktop',
      len(gif_goody_matches) == 15 and
      all(max(goody, london) < 40 for goody, london in
          zip(gif_goody_matches[:2], gif_london_matches[:2])))
check('every Goody animation frame is exact',
      len(gif_goody_matches) == 15 and
      min(gif_goody_matches[2:10]) >= 40)
check('every London animation frame is exact',
      len(gif_london_matches) == 15 and
      min(gif_london_matches[10:15]) >= 40)

print('\nRESULT:', 'FAIL' if failed else 'PASS')
sys.exit(1 if failed else 0)
