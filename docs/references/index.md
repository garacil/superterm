# Primary implementation references

Last reviewed: 2026-09-01

SuperTerm changes must be based on the matching implementation source or a
primary specification. This catalogue records provenance separately from
implementation status. Link-only entries are deliberately not vendored when
the publisher supplies no clear redistribution grant.

| Subject | Primary authority | Local status | Redistribution evidence | Stable artifact SHA-256 |
| --- | --- | --- | --- | --- |
| ECMA-48 control functions | [ECMA International, fifth edition](https://ecma-international.org/wp-content/uploads/ECMA-48_5th_edition_june_1991.pdf) | link-only | Publisher copyright; no redistribution grant recorded | `9577ad2514c411584b274ef7a4b3238c80aa93defbb349b18b8c78f78873f450` |
| ECMA-35 code extension | [ECMA International, sixth edition](https://ecma-international.org/wp-content/uploads/ECMA-35_6th_edition_december_1994.pdf) | link-only | Publisher copyright; no redistribution grant recorded | `cd812a506f93bf44e0e6058fe423144c4dea8a64fbc96589cf99bcbe32fc1bf4` |
| Xterm control sequences | [Thomas E. Dickey's xterm control-sequence reference](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html) | link-only | Upstream xterm licence permits redistribution with notices; link retained to avoid stale copies | changing HTML |
| SSH connection protocol | [RFC Editor RFC 4254](https://www.rfc-editor.org/rfc/rfc4254.txt) | link-only | RFC status states distribution is unlimited | RFC Editor publication |
| POSIX terminal interface | [The Open Group Base Specifications, termios](https://pubs.opengroup.org/onlinepubs/9799919799/basedefs/termios.h.html) | link-only | Publisher terms; no local copy required | changing HTML |
| Free Pascal 3.2.2 compiler | [Free Pascal source release 3.2.2](https://gitlab.com/freepascal.org/fpc/source/-/tree/release_3_2_2) | installed source, not copied | GPL-2.0 terms in `/usr/lib/fpc/src/compiler/COPYING.txt` on the audited host | installed licence `18642186b4e8c3ad411729cef6febb1f7793f644518df1d90c218ef48e1ffa06` |
| Free Pascal 3.2.2 RTL | [Free Pascal source release 3.2.2](https://gitlab.com/freepascal.org/fpc/source/-/tree/release_3_2_2/rtl) | installed source, not copied | LGPL-2.1 terms with FPC linking exception in the matching source tree | installed licence `3cf7652df6cd6736097af4eca6a8c35ef2fb2d103c647d817c152baa5c8dd9da` |
| Free Vision fork | [Free Pascal source commit 0d122c49534b480be9284c21bd60b53d99904346](https://gitlab.com/freepascal.org/fpc/source/-/commit/0d122c49534b480be9284c21bd60b53d99904346) | vendored in `vendor/fv322/` | Per-file upstream notices permit redistribution and modification; local modifications are recorded in `vendor/fv322/README.md` | local README `474f780d37d63fb13d6bf45bb8a07ae1b372418ad77493e67ee6c7bab5817bc4` |
| pyte 0.8.2 emulator | [selectel/pyte 0.8.2](https://github.com/selectel/pyte/tree/0.8.2) | installed dependency, not copied | LGPL-3.0 upstream; only its installed behavior is audited | version recorded by baseline |
| Microsoft console VT | [Microsoft Console virtual-terminal sequences](https://learn.microsoft.com/windows/console/console-virtual-terminal-sequences) | link-only | Microsoft documentation terms; no local copy required | changing HTML |
| Apple terminal APIs | [Apple termios manual](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man3/termios.3.html) | link-only | Apple documentation terms; no local copy required | archived HTML |

For Free Pascal behavior, use the source matching the active compiler. The
audited GNU/Linux host has FPC 3.2.2 sources under `/usr/lib/fpc/src`; another
platform must locate its own matching official source rather than assume this
path. For Free Vision behavior, use the exact fork in `vendor/fv322`, not an
installed package copy.
