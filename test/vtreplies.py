#!/usr/bin/env python3
"""The exact bytes superterm's virtual terminal answers a pane with.

A pane is launched with a fixed contract -- TERM=xterm-256color and
COLORTERM=truecolor (src/st_pty.pas, BuildEnv) -- so the PTY-owning core must
behave like that terminal when a program interrogates it. This module is the
specification of those answers, written once, so the Pascal responder and
every test assert against the same bytes.

It is also the seed of the per-dialect tables the client drivers will need:
the core answers as ONE terminal, and a driver that ever has to speak for a
different one starts from this shape.

Every entry cites `docs/references/xterm-ctlseqs.txt`, which is xterm's own
control-sequence reference from its maintainer's site. Line numbers refer to
the copy committed in this repository.

Replies use 7-bit controls throughout (ESC [ ... , ESC P ... ESC \\): the
client asserts S7C1T on the host, and a pane which received 8-bit C1 bytes
would have to guess an encoding for them.

The guiding rule for every value here is that superterm must claim only what
it actually implements. A terminal that overstates its capabilities makes
applications emit sequences it will then mis-parse, which is worse than
saying nothing -- the situation this table replaces.
"""

CSI = b'\x1b['
DCS = b'\x1bP'
ST = b'\x1b\\'


# --- Primary Device Attributes -------------------------------------------
#
# ctlseqs:769-801. "CSI ? 6 2 ; Ps c" is the VT220-class response, and the
# parameters after it are a feature list which, for VT220 and up, genuinely
# means something.
#
# 22 (ANSI color) is the only feature superterm's screen model implements of
# that list. It deliberately does NOT claim:
#   1  132-column switching   -- DECCOLM is not implemented
#   2  printer                -- no printer controls
#   3  ReGIS  / 4 Sixel       -- no graphics
#   6  selective erase        -- DECSCA/DECSED/DECSEL are not implemented
#   8  user-defined keys      -- no DECUDK
#   9  national replacement character sets
#   15 technical characters
#   16 locator port / 29 DEC locator -- the locator is reset, never enabled
#   17 terminal state interrogation
#   18 user windows
#   21 horizontal scrolling   -- DECSLRM is not implemented
#   28 rectangular editing    -- DECERA/DECFRA/DECCRA are not implemented
DA1 = CSI + b'?62;22c'

# --- Secondary Device Attributes -----------------------------------------
#
# ctlseqs:816-839. "CSI > Pp ; Pv ; Pc c": Pp is the terminal type, Pv the
# firmware version, Pc the ROM cartridge number (always zero).
#
# Pp = 1 is "VT220", matching DA1's class. Pv is 0 on purpose. Applications
# read Pv as xterm's patch level and unlock xterm extensions above known
# thresholds; superterm implements none of those extensions, so any non-zero
# value here would invite sequences its parser would mishandle. Zero asks for
# nothing.
DA2 = CSI + b'>1;0;0c'

# --- Device Status Report ------------------------------------------------
#
# ctlseqs: "CSI 5 n" -> "CSI 0 n" ("OK"), and "CSI 6 n" -> "CSI r ; c R".
DSR_OK = CSI + b'0n'


def cpr(row, col):
    """Cursor Position Report for a 1-based row and column.

    ctlseqs: the reply to "CSI 6 n" is "CSI r ; c R". TScreen keeps a 0-based
    cursor, so the responder adds one to each; this helper takes the values
    already in the reported form to keep the test's intent visible.
    """
    return CSI + f'{row};{col}R'.encode('ascii')


# --- DECRQM --------------------------------------------------------------
#
# ctlseqs:1503-1518. "CSI Ps $ p" (ANSI) is answered with "CSI Ps ; Pm $ y",
# and "CSI ? Ps $ p" (DEC private) with "CSI ? Ps ; Pm $ y".
MODE_NOT_RECOGNIZED = 0
MODE_SET = 1
MODE_RESET = 2
MODE_PERMANENTLY_SET = 3
MODE_PERMANENTLY_RESET = 4


def decrpm(mode, value, private=True):
    """The DECRPM reply for one mode."""
    lead = CSI + (b'?' if private else b'')
    return lead + f'{mode};{value}$y'.encode('ascii')


# DEC private modes TScreen really implements (st_screen.pas, the DECSET /
# DECRST handler). Anything not in this set answers MODE_NOT_RECOGNIZED,
# including modes superterm's CLIENT uses toward its own host -- 2026
# synchronized output is a rendering hint of the viewer, and the canonical
# model neither buffers nor needs it.
PRIVATE_MODES_IMPLEMENTED = (
    1,      # DECCKM, cursor keys send SS3
    7,      # DECAWM, autowrap
    9,      # X10 mouse press reporting
    25,     # DECTCEM, cursor visible
    47,     # alternate screen buffer
    1000,   # mouse press and release
    1002,   # plus motion while a button is held
    1003,   # plus every motion
    1005,   # UTF-8 mouse coordinates
    1006,   # SGR mouse coordinates
    1015,   # urxvt mouse coordinates
    1016,   # SGR-pixel mouse coordinates (reported in cells)
    1047,   # alternate screen buffer
    1049,   # alternate screen buffer with its own saved cursor
    2004,   # bracketed paste
)

# ANSI modes. Neither is implemented yet (see milestone F4-04), but both are
# answered "recognized, reset" rather than "not recognized", because that is
# what the terminal's OBSERVABLE behaviour already is: insert mode is off, so
# writes replace; LNM is off, so a line feed does not also return the
# carriage. The answer stops being a placeholder and starts being tracked
# state when F4-04 implements the modes.
ANSI_MODES_ANSWERED_RESET = (
    4,      # IRM, insert/replace
    20,     # LNM, line feed / new line
)


# --- XTGETTCAP -----------------------------------------------------------
#
# ctlseqs:545-582. "DCS + q <hex names separated by ;> ST".
# A valid request is answered with "DCS 1 + r <hexname>=<hexvalue> ST", an
# invalid one with "DCS 0 + r ST", and an unknown name ends processing of the
# rest of the list.
#
# Only the three capabilities the interface documents outside the special-key
# names are answered, and only two of them are valid:
#
#   TN / name  -- the terminal description superterm gives the pane. It must
#                 be exactly the pane's TERM (st_pty.pas BuildEnv), because an
#                 application uses this name to look up the STATIC capability
#                 set it will then rely on.
#   Co / colors -- 256, which is what xterm-256color's description says.
#   RGB        -- deliberately INVALID. In ncurses, a terminal that publishes
#                 RGB is declaring direct color, and setaf/setab then carry a
#                 packed RGB value instead of a palette index. superterm's
#                 parser reads those parameters as xterm-256color does, so
#                 claiming RGB would make ncurses emit colour numbers the
#                 parser would read as palette indexes. Truecolor is offered
#                 the way every other terminal offers it alongside a
#                 256-colour description: through COLORTERM=truecolor, which
#                 the pane contract already sets.
XTGETTCAP_VALID = {
    'TN': 'xterm-256color',
    'name': 'xterm-256color',
    'Co': '256',
    'colors': '256',
}
XTGETTCAP_INVALID = ('RGB', 'Tc', 'Smulx', 'Setulc', 'Ms')


def _hex(text):
    return text.encode('ascii').hex().upper()


def xtgettcap_request(*names):
    """The DCS a program sends to ask for these capability names."""
    return DCS + b'+q' + b';'.join(_hex(n).encode('ascii')
                                   for n in names) + ST


def xtgettcap_reply(*names):
    """The expected answer for a request for these names.

    An unknown name ends processing of the list, so a request whose first
    unknown name is in the middle is answered only up to that point -- as one
    invalid reply, since that is the form ctlseqs specifies.
    """
    pairs = []
    for name in names:
        if name not in XTGETTCAP_VALID:
            return DCS + b'0+r' + ST
        pairs.append(f'{_hex(name)}={_hex(XTGETTCAP_VALID[name])}')
    if not pairs:
        return DCS + b'0+r' + ST
    return DCS + b'1+r' + ';'.join(pairs).encode('ascii') + ST


# --- the queries themselves ----------------------------------------------
#
# What a program sends, paired with what it must get back. Kept together so a
# test cannot drift into asserting a reply for a query nobody sends.
QUERIES = (
    ('DA1', CSI + b'c', DA1),
    ('DA1 explicit zero', CSI + b'0c', DA1),
    ('DA2', CSI + b'>c', DA2),
    ('DA2 explicit zero', CSI + b'>0c', DA2),
    ('DSR status', CSI + b'5n', DSR_OK),
)
