# Artwork sources

`alien-hacker.png` is original artwork generated specifically for SuperTerm.
It does not derive from the former Goody loading screen or from another named
character, game, film, logo or brand. To the extent that copyright or related
rights apply to the generated artwork, it is distributed under the same GNU
General Public License version 3 as this repository; see [`../LICENSE`](../LICENSE).

It was created with OpenAI's built-in image generator from this final brief:

> Create an original hooded alien hacker at a terminal, centred in a wide
> landscape composition, in neon cyan, green and violet; keep it high-contrast
> and readable after reduction to a coarse terminal grid; include no text,
> logo, brand, named or copyrighted character; use a transparent background
> and fade the artwork smoothly to full transparency on all four outer edges.

The source has a real alpha channel and fades to transparency on all four
edges. `tools/mkbackgrounds.py` converts that fade to deterministic ordered
cell dithering because the terminal background format has binary occupancy,
not per-cell alpha. The installed file remains `goody.art` as a compatibility
identifier so existing profiles do not break; its visible menu name is
`Alien hacker` / `Hacker alienigena`.

Regenerate the checked-in terminal asset from the repository root with:

```sh
python3 tools/mkbackgrounds.py backgrounds
```

Regeneration needs Pillow and `rsvg-convert` because the same command also
rebuilds the checked-in phoenix from its SVG source. These are development/test
dependencies only; SuperTerm loads the resulting `.art` files without them.

The optional `GOODY_SRC=/path/to/source.png` override is retained for artwork
experiments, but release regeneration uses `assets/alien-hacker.png`.

## SSH hero illustration

`../screenshots/ssh-anywhere.png` is likewise original AI-generated artwork
created specifically for SuperTerm and distributed under this repository's
GNU General Public License version 3. It is a promotional illustration of one
encrypted workspace reaching several kinds of SSH-capable screen, not a claim
that those pictured interfaces or devices are third-party products. It contains
no text, logo, brand, or named character.
