# Terminal reference library

Official, provenanced source material for SuperTerm's terminal work. Every
local file records where it came from and under what terms; `SHA256SUMS`
records the exact bytes. Verify from this directory with:

```sh
sha256sum -c SHA256SUMS
```

Do not infer implemented support from the presence of a manual. A capability
may be advertised only after its production implementation and end-to-end
conformance tests pass.

> **Scope note.** This catalogue was imported from the `speedupx` branch, whose
> first four sections described that branch's own unit topology, driver roster
> and milestone status. Those sections describe an architecture this branch
> deliberately does not implement, so they were not carried over; what remains
> is the reference catalogue itself, its retention policy and its conformance
> requirements. The architecture of this branch is `docs/ARCHITECTURE.md`.

> **ECMA-35 and ECMA-48 are deliberately link-only.** Both PDFs were examined:
> neither carries any statement granting redistribution. ECMA-35's closing page
> offers the standard "free of charge", which is a statement about obtaining a
> copy, not about republishing one. Section 4 of this document permits a local
> copy only when redistribution is permitted and the required notices travel
> with it, so the rule is applied to these two rather than excepted for them.
> The practical working reference for control functions is xterm's `ctlseqs`,
> which is present locally and is redistributable.

## 1. Official terminal-profile documentation

The table deliberately says whether an authority is a complete sequence
inventory, an extension-only document, a user manual, or implementation
evidence. A user manual must not be treated as proof that a control sequence is
implemented.

| Terminal or family | Platforms in scope | Adapter/profile | Official authority | Authority boundary |
|---|---|---|---|---|
| SuperTerm core | All pane backends | XTERM TRUECOLOR CORE codec | [xterm control sequences](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html), [ncurses terminfo](https://invisible-island.net/ncurses/man/terminfo.5.html), [upstream terminfo database](https://invisible-island.net/datafiles/current/terminfo.src.gz) | Exact-capable RGB/Unicode canonical semantics with a fixed external `xterm-256color`/true-colour pane environment; the frozen erase/scroll filler approximation is documented separately, and SuperTerm still needs its own normative implemented-capability table |
| xterm | GNU/Linux, macOS/XQuartz, remote | generic VT + xterm profile | [XTerm Control Sequences](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html) | Complete de-facto base authority |
| VTE | GNU/Linux and any VTE frontend | generic VT + VTE profile | [VTE project documentation](https://gnome.pages.gitlab.gnome.org/vte/), [official VTE source](https://gitlab.gnome.org/GNOME/vte) | No consolidated public sequence matrix; source pin and conformance tests are required |
| GNOME Terminal | GNU/Linux | VTE profile | [GNOME Terminal help](https://help.gnome.org/users/gnome-terminal/stable/), [official source](https://gitlab.gnome.org/GNOME/gnome-terminal) | VTE frontend, not an independent parser |
| Ptyxis | GNU/Linux | VTE profile | [official Ptyxis source](https://gitlab.gnome.org/chergert/ptyxis) | VTE frontend, not an independent parser |
| Tilix | GNU/Linux | VTE profile | [official Tilix source](https://github.com/gnunn1/tilix) | VTE frontend, not an independent parser |
| Konsole | GNU/Linux | generic VT + Konsole profile | [official Konsole handbook](https://docs.kde.org/stable_kf6/en/konsole/konsole/konsole.pdf), [official source](https://invent.kde.org/utilities/konsole) | No complete public sequence matrix; source/tests are implementation evidence |
| kitty | GNU/Linux, macOS | generic VT + kitty overlay | [keyboard protocol](https://sw.kovidgoyal.net/kitty/keyboard-protocol/), [graphics protocol](https://sw.kovidgoyal.net/kitty/graphics-protocol/), [protocol extensions](https://sw.kovidgoyal.net/kitty/protocol-extensions/) | Official extensions, not a complete base-terminal manual |
| foot | GNU/Linux | generic VT + foot profile | [official `foot-ctlseqs(7)` source](https://codeberg.org/dnkl/foot/src/branch/master/doc/foot-ctlseqs.7.scd) | Product control-sequence inventory |
| WezTerm | GNU/Linux, macOS, Windows | generic VT + WezTerm profile | [official escape-sequence reference](https://wezterm.org/escape-sequences.html) | Living implementation document; pin a revision for tests |
| Alacritty | GNU/Linux, macOS, Windows | generic VT + Alacritty profile | [official escape reference](https://alacritty.org/misc-alacritty-escapes.html), [official terminfo source](https://github.com/alacritty/alacritty/blob/master/extra/alacritty.info) | Product differences and terminfo |
| Ghostty | GNU/Linux, macOS | generic VT + Ghostty profile | [official VT reference](https://ghostty.org/docs/vt/reference), [official terminfo guidance](https://ghostty.org/docs/help/terminfo) | The publisher labels the sequence list work in progress |
| Contour | GNU/Linux, macOS, Windows | generic VT + Contour profile | [official VT sequence inventory](https://contour-terminal.org/vt-sequence/), [official VT extensions](https://contour-terminal.org/vt-extensions/) | Full product inventory plus cross-terminal overlays |
| rxvt-unicode | GNU/Linux/Unix | conservative generic VT + rxvt profile | [official rxvt-unicode site and manual](http://software.schmorp.de/pkg/rxvt-unicode.html) | Product manual; validate its terminfo entry |
| st | GNU/Linux/Unix | conservative generic VT + st profile | [official st site](https://st.suckless.org/), [official terminfo source](https://git.suckless.org/st/file/st.info.html) | Source and terminfo are the product authority |
| Terminology | GNU/Linux/Unix | generic VT + Terminology profile | [official application documentation](https://www.enlightenment.org/docs/apps/terminology), [official source](https://git.enlightenment.org/enlightenment/terminology) | No complete sequence matrix; terminfo and conformance tests define the safe profile |
| Terminal.app | macOS | generic VT + Terminal.app profile | [Apple Terminal User Guide](https://support.apple.com/guide/terminal/welcome/mac) | Apple publishes no complete control-sequence specification; use the conservative profile and tests |
| iTerm2 | macOS | generic VT + iTerm2 overlay | [official proprietary escape-code reference](https://iterm2.com/documentation-escape-codes.html) | Extension-only authority over an xterm-compatible base |
| XQuartz/xterm | macOS | xterm profile | [official XQuartz documentation](https://www.xquartz.org/), [xterm control sequences](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html) | XQuartz provides X11; xterm defines the terminal dialect |
| Windows Terminal | Windows | Windows Console VT + product profile | [Microsoft Terminal documentation](https://learn.microsoft.com/windows/terminal/), [official source](https://github.com/microsoft/terminal) | Microsoft Console VT is the protocol baseline; version-specific behaviour comes from source/tests |
| modern ConHost | Windows | Windows Console VT profile | [Microsoft Console VT sequences](https://learn.microsoft.com/windows/console/console-virtual-terminal-sequences) | Host implementation of the Microsoft VT subset |
| classic Windows Console | Windows | classic Win32 fallback | [Microsoft Console API](https://learn.microsoft.com/windows/console/console-functions) | Native API, not a VT dialect |
| mintty | Windows/Cygwin/MSYS2 | generic VT + mintty profile | [official mintty control-sequence reference](https://github.com/mintty/mintty/blob/master/wiki/CtrlSeqs.md), [official source](https://github.com/mintty/mintty) | Documents mintty-specific differences over xterm; source contains the complete implementation |
| MSYS2 / Git Bash | Windows | mintty profile when mintty is the viewer | [MSYS2 terminals documentation](https://www.msys2.org/docs/terminals/), [Git for Windows documentation](https://gitforwindows.org/) | Environments/distributions, not new terminal parsers |
| PuTTY | Windows and remote | generic VT + PuTTY profile | [official PuTTY manual](https://www.chiark.greenend.org.uk/~sgtatham/putty/latest.html) | No single complete sequence table; pin version and verify behaviour |
| Tera Term | Windows and remote | generic VT + Tera Term profile | [official control-sequence reference](https://teratermproject.github.io/manual/5/en/about/ctrlseq.html) | Product control-sequence inventory |
| ConEmu / Cmder | Windows | generic VT + ConEmu profile | [official ANSI/VT reference](https://conemu.github.io/en/AnsiEscapeCodes.html), [official source](https://github.com/Maximus5/ConEmu) | ConEmu defines the terminal behaviour; Cmder is a distribution/frontend |
| xterm.js | All three through VS Code, Tabby, browsers, and embedded clients | generic VT + xterm.js profile | [official VT feature matrix](https://xtermjs.org/docs/api/vtfeatures/), [official source](https://github.com/xtermjs/xterm.js) | Engine profile shared by many frontends |
| tmux | All applicable systems | intermediary profile | [official `tmux(1)` source](https://github.com/tmux/tmux/blob/master/tmux.1), [project FAQ](https://github.com/tmux/tmux/wiki/FAQ) | Virtual terminal and passthrough intermediary, not a physical renderer |
| GNU Screen | GNU/Linux, macOS, remote | intermediary profile | [official GNU Screen manual](https://www.gnu.org/software/screen/manual/) | Virtual terminal and passthrough intermediary |

## 2. Required protocol and platform references

### 2.1 Standards and portable terminal data

| Scope | Official authority | Local material |
|---|---|---|
| Control functions | [ECMA-48](https://ecma-international.org/publications-and-standards/standards/ecma-48/) | Official link only -- see the note below |
| C0/C1 and code extension | [ECMA-35](https://ecma-international.org/publications-and-standards/standards/ecma-35/) | Official link only -- see the note below |
| Terminal capability format/API/database | [ncurses manuals](https://invisible-island.net/ncurses/man/) and [official source archive](https://invisible-island.net/archives/ncurses/current/) | [`ncurses-terminfo.5.txt`](ncurses-terminfo.5.txt), [`ncurses-curs_terminfo.3x.roff`](ncurses-curs_terminfo.3x.roff), [`ncurses-terminfo.src`](ncurses-terminfo.src), [`ncurses-COPYING.txt`](ncurses-COPYING.txt) |
| Unicode character width inputs | [UAX #11](https://www.unicode.org/reports/tr11/) and [Unicode 17 data](https://www.unicode.org/Public/17.0.0/ucd/) | [`unicode-17-EastAsianWidth.txt`](unicode-17-EastAsianWidth.txt), [`unicode-LICENSE.txt`](unicode-LICENSE.txt); UAX #11 is not an off-the-shelf terminal-width algorithm |
| Grapheme segmentation | [UAX #29](https://www.unicode.org/reports/tr29/) and [Unicode 17 auxiliary data](https://www.unicode.org/Public/17.0.0/ucd/auxiliary/) | [`unicode-17-GraphemeBreakProperty.txt`](unicode-17-GraphemeBreakProperty.txt), [`unicode-17-GraphemeBreakTest.txt`](unicode-17-GraphemeBreakTest.txt) |
| Emoji sequences | [UTS #51](https://www.unicode.org/reports/tr51/) | [`unicode-17-emoji-data.txt`](unicode-17-emoji-data.txt), [`unicode-17-emoji-zwj-sequences.txt`](unicode-17-emoji-zwj-sequences.txt) |
| POSIX terminal interface | [POSIX.1-2024 General Terminal Interface](https://pubs.opengroup.org/onlinepubs/9799919799/basedefs/V1_chap11.html) | Official link only unless redistribution terms are confirmed |
| SSH PTY transport | [RFC 4254](https://www.rfc-editor.org/rfc/rfc4254.txt), especially sections 6.2 and 6.7 | [`rfc4254-ssh-connection-protocol.txt`](rfc4254-ssh-connection-protocol.txt): PTY request, modes, dimensions, and window-change semantics |

The pinned ncurses source compiles locally without diagnostics into **1,861
terminal definitions** and **2,928 installed names/aliases**. This database,
queried through terminfo, is the scalable compatibility baseline. It does not
turn every entry into a separate SuperTerm driver.

### 2.2 GNU/Linux platform material

The local Linux set contains the upstream roff sources rather than browser
pages saved as text:

- PTY and terminal lifecycle: [`linux-pty.7.roff`](linux-pty.7.roff),
  [`linux-openpty.3.roff`](linux-openpty.3.roff),
  [`linux-termios.7.roff`](linux-termios.7.roff),
  [`linux-termios.3type.roff`](linux-termios.3type.roff),
  [`linux-termios-api.3.roff`](linux-termios-api.3.roff), and
  [`linux-cfmakeraw.3.roff`](linux-cfmakeraw.3.roff).
- Kernel terminal/console interfaces:
  [`linux-tty.4.roff`](linux-tty.4.roff),
  [`linux-ioctl_tty.2.roff`](linux-ioctl_tty.2.roff),
  [`linux-ioctl_kd.2.roff`](linux-ioctl_kd.2.roff),
  [`linux-ioctl_vt.2.roff`](linux-ioctl_vt.2.roff), and
  [`linux-console_codes.4.roff`](linux-console_codes.4.roff).
- GPM protocol and ABI: [`gpm-manual.texi.in`](gpm-manual.texi.in),
  [`gpm.h`](gpm.h), and [`gpm-COPYING.txt`](gpm-COPYING.txt).
- The exact Linux man-pages licence texts used by those files are retained as
  `linux-man-pages-*.txt`; each roff header carries its SPDX identifier.

Official publishers:

- [Linux man-pages project](https://www.kernel.org/doc/man-pages/)
- [GPM maintainer repository](https://github.com/telmich/gpm)

### 2.3 macOS platform material

The Darwin backend references are:

- [`macos-openpty.3.roff`](macos-openpty.3.roff) for `openpty`, `login_tty`,
  and `forkpty`;
- [`macos-tty.4.roff`](macos-tty.4.roff),
  [`macos-xnu-termios.h`](macos-xnu-termios.h), and
  [`macos-xnu-ttycom.h`](macos-xnu-ttycom.h) for tty semantics and ABI;
- [`macos-kqueue.2.roff`](macos-kqueue.2.roff), which documents both `kqueue`
  and `kevent`;
- [`apple-APSL-2.0.txt`](apple-APSL-2.0.txt) for the Apple-covered XNU files.

Terminal.app's user guide is not a replacement for these operating-system
interfaces.

Official publishers:

- [Apple Libc source](https://github.com/apple-oss-distributions/Libc)
- [Apple XNU source](https://github.com/apple-oss-distributions/xnu)

### 2.4 Windows platform material

The complete local ConPTY and console subset is grouped by purpose:

- Design and session lifecycle:
  [`windows-pseudoconsoles.md`](windows-pseudoconsoles.md),
  [`windows-creating-a-pseudoconsole-session.md`](windows-creating-a-pseudoconsole-session.md),
  [`windows-createpseudoconsole.md`](windows-createpseudoconsole.md),
  [`windows-resizepseudoconsole.md`](windows-resizepseudoconsole.md), and
  [`windows-closepseudoconsole.md`](windows-closepseudoconsole.md).
- VT stream and mode setup:
  [`windows-console-virtual-terminal-sequences.md`](windows-console-virtual-terminal-sequences.md),
  [`windows-classic-vs-vt.md`](windows-classic-vs-vt.md),
  [`windows-getconsolemode.md`](windows-getconsolemode.md), and
  [`windows-setconsolemode.md`](windows-setconsolemode.md).
- Native input:
  [`windows-readconsoleinput.md`](windows-readconsoleinput.md),
  [`windows-input-record.md`](windows-input-record.md),
  [`windows-key-event-record.md`](windows-key-event-record.md),
  [`windows-mouse-event-record.md`](windows-mouse-event-record.md),
  [`windows-focus-event-record.md`](windows-focus-event-record.md), and
  [`windows-window-buffer-size-record.md`](windows-window-buffer-size-record.md).
- Optional classic output fallback:
  [`windows-writeconsoleoutput.md`](windows-writeconsoleoutput.md),
  [`windows-char-info.md`](windows-char-info.md), and
  [`windows-getconsolescreenbufferinfo.md`](windows-getconsolescreenbufferinfo.md).
- [`microsoft-console-docs-LICENSE.txt`](microsoft-console-docs-LICENSE.txt)
  and [`microsoft-console-docs-LICENSE-CODE.txt`](microsoft-console-docs-LICENSE-CODE.txt)
  retain Microsoft's documentation and sample-code terms.

Official publisher:

- [Microsoft Console documentation](https://learn.microsoft.com/windows/console/)
- [MicrosoftDocs/Console-Docs source](https://github.com/MicrosoftDocs/Console-Docs)

### 2.5 Local product and intermediary manuals

| Scope | Local reference | Classification |
|---|---|---|
| xterm | [`xterm-ctlseqs.txt`](xterm-ctlseqs.txt), [`xterm-COPYING.txt`](xterm-COPYING.txt) | Canonical pane-dialect and generic-VT authority |
| foot | [`foot-control-sequences.7.scd`](foot-control-sequences.7.scd), [`foot-LICENSE.txt`](foot-LICENSE.txt) | Complete product sequence inventory |
| WezTerm | [`wezterm-escape-sequences.md`](wezterm-escape-sequences.md), [`wezterm-LICENSE.md`](wezterm-LICENSE.md) | Living product implementation reference |
| Alacritty | [`alacritty-escape-sequences.7.scd`](alacritty-escape-sequences.7.scd), [`alacritty-terminfo.src`](alacritty-terminfo.src), Apache/MIT licence files | Product sequence inventory and terminfo |
| kitty | [`kitty-keyboard-protocol.rst`](kitty-keyboard-protocol.rst), [`kitty-graphics-protocol.rst`](kitty-graphics-protocol.rst), [`kitty-protocol-extensions.rst`](kitty-protocol-extensions.rst), [`kitty-LICENSE.txt`](kitty-LICENSE.txt) | Optional overlays, not the generic base |
| mintty | [`mintty-ctrlseqs.md`](mintty-ctrlseqs.md), `mintty-LICENSE*.txt` | Product-specific extensions over xterm |
| Contour/cross-terminal extensions | [`synchronized-output-2026.md`](synchronized-output-2026.md), [`contour-vt-extensions-index.md`](contour-vt-extensions-index.md), [`contour-LICENSE.txt`](contour-LICENSE.txt) | Optional extension specifications; not a Contour base driver manual |
| Konsole | [`konsole-handbook.pdf`](konsole-handbook.pdf) | Official user manual, GFDL (stated in its own Credits and Copyright section, so the required notice travels with the file); protocol claims still require source/tests |
| rxvt-unicode | [`rxvt-unicode.7.pod`](rxvt-unicode.7.pod), [`rxvt-unicode-COPYING.txt`](rxvt-unicode-COPYING.txt) | Official technical reference and licence |
| st | [`st-terminfo.src`](st-terminfo.src), [`st-LICENSE.txt`](st-LICENSE.txt) | Official product terminfo/source authority |
| tmux | [`tmux.1`](tmux.1), [`tmux-COPYING.txt`](tmux-COPYING.txt) | Intermediary virtual-terminal and passthrough authority |
| GNU Screen | [`gnu-screen-manual.txt`](gnu-screen-manual.txt) | Intermediary virtual-terminal manual; copying notice embedded |

Terminal.app, iTerm2, VTE frontends, Ghostty, the complete Contour inventory,
Windows Terminal version-specific behaviour, PuTTY, Tera Term, ConEmu,
Terminology, XQuartz, and xterm.js remain official-link authorities in section
5 when no complete, version-pinned, clearly redistributable standalone manual
is available. This is intentional, not missing provenance.

### 2.6 Pinned upstream revisions

All local source material was retrieved on 2026-08-28. Per-file byte hashes are
in [`SHA256SUMS`](SHA256SUMS).

| Publisher/project | Pinned revision or release |
|---|---|
| ncurses | `ncurses-6.6-20260822` source archive |
| xterm snapshots | `9489b2056ee51fa9dd6a7087483b9b8f85d6a0c4` (control reference identifies patch 411) |
| Linux man-pages | tag `man-pages-6.19`, commit `adb436b2e4471218021d86f188fb58dec3946eb8` |
| GPM | `e82d1a653ca94aa4ed12441424da6ce780b1e530` |
| Apple Libc | `71bbe350ab79eef58113991d817ccc6165061a64` |
| Apple XNU | `f6217f891ac0bb64f3d375211650a4c1ff8ca1ea` |
| MicrosoftDocs/Console-Docs | `50eb4826f13887a146bb0f947cf46b39b5344f77` |
| Unicode data | Unicode 17.0 |
| kitty | `a08218461e4f4aaa577e1beb14b4476ee7e628c8` |
| mintty | `551085e62238a178b11515702df8bf9810861959` |
| Contour | `ee0ef0152260cf3728a374a35f6b1e52baa588ca` |
| foot | `85655c74a4ded119392ea8b632626c3920042807` |
| WezTerm | `08e50ca2cd7d28542b590167dc8e97bd8c1dc025` |
| Alacritty | `ede2ac144da4dec4c075bfa803aacf3b3739bce6` |
| tmux | `267746603a4ff25baad62e3477b126411e49b52f` |
| st | `04ce0d643ed17793803e8516f4c9a5b13b93c400` |
| Konsole handbook | official stable KF6 PDF generated 2026-08-12 |
| GNU Screen | official online manual for Screen 5.0.0 |
| rxvt-unicode | official project CVS snapshot retrieved 2026-08-28 |

## 3. Required baseline versus optional overlays

| Required for broad text-terminal compatibility | Optional, negotiated overlay |
|---|---|
| UTF-8 decoding and explicit legacy degradation | kitty graphics |
| Unicode grapheme and cell-width policy | iTerm2 inline images/file transfer |
| Cursor movement, margins, scrolling, erase and insert/delete | Sixel/ReGIS/image planes |
| SGR, ANSI-16, 256 colours, exact RGB and deterministic degradation | shell integration and semantic prompt zones |
| normal/application cursor and keypad input | vendor notification/progress OSC commands |
| function keys and modifiers supported by the selected profile | enhanced keyboard protocols beyond the stable input baseline |
| bracketed paste, focus, SGR mouse, GPM, and Win32 input records as applicable | DECSET 2026 synchronized output when positively detected |
| resize, reset, alternate screen, OSC 52 policy, DA/DSR/CPR/DECRQM/XTGETTCAP replies | raw passthrough of explicitly approved protocol families |

DECSET 2026 is useful because one operating-system write does not guarantee one
atomic visual presentation. It is a cross-terminal extension specification,
not a Contour terminal driver. Enable it only after capability detection and
always terminate/reset it on errors and teardown.

## 4. Reference retention and provenance policy

Every local reference must have all of the following recorded before it is
treated as implementation authority:

1. Exact canonical publisher URL.
2. Release, tag, patch level, or immutable source commit.
3. Retrieval date.
4. SHA-256 digest of the local bytes.
5. Upstream licence or redistribution status.
6. Classification as normative, implementation evidence, optional overlay, or
   supplemental background.

Use a local copy only when redistribution is permitted and the copy retains its
required notices. Otherwise keep an official link in this index. HTML pages
with navigation chrome, unlicensed gists, informal ANSI summaries, and local
machine snapshots must not be presented as canonical manuals.

The flat filenames in this directory are retained where source code already
links to them. This index is the boundary between manuals: each table row names
exactly one standard, product family, platform interface, or overlay. A future
directory move must update all source-code citations atomically.

## 5. Conformance requirements

Documentation determines candidate behaviour; tests determine what SuperTerm
may safely advertise. Each core feature/profile needs:

- parser tests split at every byte boundary;
- malformed, cancelled, truncated, oversized, and interleaved control strings;
- query/reply tests through a real PTY and through the daemon, not only direct
  parser-unit tests;
- terminfo comparison with `infocmp` and capability-probe fixtures;
- golden semantic-event and render-delta tests;
- colour/Unicode degradation tests for truecolour, 256-colour, ANSI-16, UTF-8,
  and legacy ACS endpoints;
- native Linux VC/GPM, Darwin PTY, Windows Console, and ConPTY integration tests
  on their real operating systems;
- nested tmux/Screen and SSH window-resize/passthrough tests;
- a rule that DA, DECRQM, XTGETTCAP, mouse mode, or another capability is never
  reported as supported until its implementation and end-to-end tests pass.
