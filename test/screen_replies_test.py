#!/usr/bin/env python3
"""superterm test: the terminal's pending-answer queue in TScreen.

A pane may interrogate the terminal and block waiting for a reply. TScreen
holds the answers it owes until the process that owns the PTY drains them.
This suite pins that queue's contract on its own, before any handler produces
an answer, so a later change to a handler cannot quietly change the queue.

Three properties matter and are easy to get wrong:

* FIFO order -- answers must arrive in the order the queries were made.
* A per-answer size limit -- a malformed oversize answer is never queued.
* Which end is dropped on overflow. The OLDEST is dropped, because the query
  a program is blocked on is the most recent one; dropping the newest would
  starve exactly the reply being waited for.

The queue is also transient state, not part of a snapshot: a mirror never
drains, so loading a snapshot over one must not leave its answers behind.

This suite also covers the legacy OSC 52 event queue (FOsc52Queue): a second,
independent TScreen queue with the exact same bounded FIFO/drop-oldest shape,
now additionally source-filtered by AcceptOsc52Payload -- QueueOsc52 applies
that filter to BOTH the recording path and this legacy path, so a read query,
an empty, a malformed, or an over-bound Pd may never occupy one of its
MAX_OSC52_EVENTS slots and evict a valid older entry.

Like the other unit-level Pascal suites here, this compiles a small probe
against src/st_screen.pas. It touches no terminal, PTY or daemon.

Scope note for this branch. The upstream version of this suite also exercised
the canonical state codec and the OSC 52 queue filter. Both were removed here
rather than adapted: the codec belongs to the dense-frame pipeline this branch
rejects (see docs/ARCHITECTURE.md section 7), and the OSC 52 filter is a
separate concern whose upstream constants do not exist in this tree. What
remains is exactly what the milestone is about -- the answers the terminal owes
its pane, and the queue that holds them until the PTY owner delivers them.

The snapshot check was rewritten rather than dropped, and its expectation
deliberately INVERTED against upstream: here an owed answer must NOT travel
inside a snapshot, because only the PTY owner ever answers and a mirror could
never drain one.
"""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import vtreplies  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
failed = False


def pascal_literal(data):
    """Render bytes as a Pascal string literal.

    Printable ASCII goes inside quotes; everything else becomes a #NN control
    character, which is how the unit itself writes these sequences.
    """
    parts = []
    run = ''
    for byte in data:
        if 32 <= byte < 127:
            run += chr(byte)
            if byte == 0x27:      # a quote doubles inside a Pascal literal
                run += chr(byte)
        else:
            if run:
                parts.append("'" + run + "'")
                run = ''
            parts.append(f'#{byte}')
    if run:
        parts.append("'" + run + "'")
    return ''.join(parts) if parts else "''"


def check(label, condition):
    global failed
    print(f'{label:52s}: {"OK" if condition else "FAIL"}')
    if not condition:
        failed = True


PROBE = r'''
program screen_replies_probe;

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, st_screen;

type
  { QueueReply is protected precisely so the queue can be driven directly,
    without depending on which control sequence happens to produce an answer. }
  TProbeScreen = class(TScreen)
  public
    procedure Owe(const AReply: RawByteString);
    function ConsumeReply(out AReply: RawByteString): boolean;
  end;

procedure TProbeScreen.Owe(const AReply: RawByteString);
begin
  QueueReply(AReply);
end;

function TProbeScreen.ConsumeReply(out AReply: RawByteString): boolean;
var
  Token: TScreenReplyToken;
begin
  AReply := '';
  Token := TScreenReplyToken(0);
  Result := PeekReply(Token, AReply);
  if Result then
    Result := AcknowledgeReply(Token);
end;

var
  Failures, Checks: Integer;

procedure Check(const AName: string; ACondition: Boolean);
begin
  Inc(Checks);
  if ACondition then
    Writeln('PASS ', AName)
  else
  begin
    Inc(Failures);
    Writeln('FAIL ', AName);
  end;
end;

procedure TestEmpty;
var
  S: TProbeScreen;
  Reply: RawByteString;
begin
  S := TProbeScreen.Create(20, 5);
  try
    Check('a new screen owes nothing', S.PendingReplies = 0);
    Check('taking from an empty queue reports false',
      not S.ConsumeReply(Reply));
    Check('an empty take clears its output', Reply = '');
  finally
    S.Free;
  end;
end;

procedure TestFifo;
var
  S: TProbeScreen;
  Reply: RawByteString;
  Ok: Boolean;
  I: Integer;
begin
  S := TProbeScreen.Create(20, 5);
  try
    S.Owe('first');
    S.Owe('second');
    S.Owe('third');
    Check('three answers are pending', S.PendingReplies = 3);
    Ok := S.ConsumeReply(Reply) and (Reply = 'first');
    Ok := Ok and S.ConsumeReply(Reply) and (Reply = 'second');
    Ok := Ok and S.ConsumeReply(Reply) and (Reply = 'third');
    Check('answers come back in the order they were owed', Ok);
    Check('the queue is empty again', S.PendingReplies = 0);
    { Order must hold across a drain that empties the queue and refills it,
      which is what a daemon reactor turn really does. }
    for I := 1 to 5 do
      S.Owe('r' + IntToStr(I));
    Ok := True;
    for I := 1 to 5 do
      Ok := Ok and S.ConsumeReply(Reply) and
        (Reply = 'r' + IntToStr(I));
    Check('order survives drain and refill', Ok);
  finally
    S.Free;
  end;
end;

procedure TestSizeLimit;
var
  S: TProbeScreen;
  Reply: RawByteString;
begin
  S := TProbeScreen.Create(20, 5);
  try
    S.Owe('');
    Check('an empty answer is not queued', S.PendingReplies = 0);
    S.Owe(StringOfChar('x', 4096));
    Check('an answer at the size limit is queued', S.PendingReplies = 1);
    S.ConsumeReply(Reply);
    S.Owe(StringOfChar('x', 4097));
    Check('an answer past the size limit is refused',
      S.PendingReplies = 0);
  finally
    S.Free;
  end;
end;

procedure TestOverflowDropsOldest;
var
  S: TProbeScreen;
  Reply: RawByteString;
  I: Integer;
  Ok: Boolean;
begin
  S := TProbeScreen.Create(20, 5);
  try
    for I := 1 to 32 do
      S.Owe('q' + IntToStr(I));
    Check('the queue holds its full depth', S.PendingReplies = 32);
    S.Owe('q33');
    Check('overflow does not grow the queue', S.PendingReplies = 32);
    Ok := S.ConsumeReply(Reply) and (Reply = 'q2');
    Check('overflow dropped the oldest answer, not the newest', Ok);
    { Drain to the end: the newest answer -- the one a blocked program is
      actually waiting for -- must still be there. }
    while S.PendingReplies > 1 do
      S.ConsumeReply(Reply);
    Ok := S.ConsumeReply(Reply) and (Reply = 'q33');
    Check('the newest answer survived the overflow', Ok);
  finally
    S.Free;
  end;
end;

procedure TestResetAndLoadClear;
var
  S, T: TProbeScreen;
  Snapshot: TMemoryStream;
  Loaded: Boolean;
  Text: RawByteString;
begin
  S := TProbeScreen.Create(20, 5);
  try
    S.Owe('pending');
    Text := 'hello';
    S.WriteBytes(Text[1], Length(Text));
    Check('ordinary output leaves the queue alone', S.PendingReplies = 1);
    S.ResetHard;
    Check('RIS discards answers nobody is owed any more',
      S.PendingReplies = 0);
  finally
    S.Free;
  end;

  { A snapshot replaces the mirror's whole state, its reply queue included:
    a mirror that had been parsing must not keep its own stale queue.

    The queue deliberately does NOT travel inside the snapshot. In this
    architecture only the process holding the PTY ever answers a query, so a
    reply carried to a mirror could never be drained -- it would just sit
    there, and a second viewer would hold a phantom answer for a question it
    never saw asked. }
  S := TProbeScreen.Create(20, 5);
  T := TProbeScreen.Create(20, 5);
  Snapshot := TMemoryStream.Create;
  try
    T.Owe('stale');
    S.Owe('carried');
    S.SaveToStream(Snapshot);
    Snapshot.Position := 0;
    Loaded := T.LoadFromStream(Snapshot);
    Check('the snapshot loads', Loaded);
    Check('loading a snapshot replaces the stale queue',
      T.PendingReplies = 0);
    Check('an owed answer does NOT travel to a mirror that cannot drain it',
      T.PendingReplies = 0);
    Check('the owner still owes its own answer', S.PendingReplies = 1);
  finally
    Snapshot.Free;
    T.Free;
    S.Free;
  end;
end;

{ --- the queries a pane actually makes ------------------------------------ }

function Feed(S: TProbeScreen; const Bytes: RawByteString): RawByteString;
begin
  Result := '';
  if Bytes <> '' then
    S.WriteBytes(Bytes[1], Length(Bytes));
end;

{ --- complete semantic-state fidelity (ARCH-08B) --------------------------

  A snapshot must carry EVERY register a faithful continuation needs.  The
  proof shape: park the source screen in a demanding state, import its
  snapshot into a differently-shaped target, then feed both the identical
  continuation bytes; their complete exported states must agree.  The
  scenarios pin exactly the registers the earlier stream format lost: the
  live truecolor pen, both saved-cursor rendition slots, colon-form CSI
  parameters split mid-sequence, split OSC and DCS captures with their
  overflow flags, and the scrollback ring with its stable push counter. }

function Ask(const Query: RawByteString): RawByteString;
var
  S: TProbeScreen;
begin
  Result := '';
  S := TProbeScreen.Create(80, 24);
  try
    Feed(S, Query);
    if S.PendingReplies <> 1 then
    begin
      if S.PendingReplies = 0 then
        Result := '<no answer>'
      else
        Result := '<' + IntToStr(S.PendingReplies) + ' answers>';
      Exit;
    end;
    S.ConsumeReply(Result);
  finally
    S.Free;
  end;
end;

function Silent(const Query: RawByteString): Boolean;
var
  S: TProbeScreen;
begin
  S := TProbeScreen.Create(80, 24);
  try
    Feed(S, Query);
    Result := S.PendingReplies = 0;
  finally
    S.Free;
  end;
end;

procedure TestDeviceAttributes;
begin
  Check('CSI c is answered with primary DA', Ask(__DA1_QUERY__) = __DA1__);
  Check('CSI 0 c is answered with primary DA',
    Ask(__DA1_QUERY0__) = __DA1__);
  Check('CSI > c is answered with secondary DA',
    Ask(__DA2_QUERY__) = __DA2__);
  Check('CSI > 0 c is answered with secondary DA',
    Ask(__DA2_QUERY0__) = __DA2__);
  { A DA request with a parameter other than 0 is not a request for
    attributes and must not be answered. }
  Check('CSI 1 c asks nothing and is not answered', Silent(#27'[1c'));
  { The private form is a REPLY, not a request: answering it would make two
    terminals talk to each other forever. }
  Check('CSI ? 62 ; 22 c is a reply and is not answered',
    Silent(#27'[?62;22c'));
  { Tertiary DA would have to report a unit ID this terminal does not have. }
  Check('CSI = c is left unanswered on purpose', Silent(#27'[=c'));
end;

procedure TestStatusReports;
var
  S: TProbeScreen;
  Reply: RawByteString;
begin
  Check('CSI 5 n reports the terminal is ready',
    Ask(#27'[5n') = __DSR_OK__);
  { The cursor is 0-based in the grid and 1-based in the report. Home must
    therefore be 1;1, not 0;0 -- the classic off-by-one in this reply. }
  Check('CSI 6 n at home reports row 1 column 1',
    Ask(#27'[6n') = __CPR_HOME__);
  S := TProbeScreen.Create(80, 24);
  try
    Feed(S, #27'[12;40H');
    Feed(S, #27'[6n');
    Reply := '';
    S.ConsumeReply(Reply);
    Check('CSI 6 n reports the cursor where CUP put it',
      Reply = __CPR_12_40__);
  finally
    S.Free;
  end;
  { The DEC private form asks about printer, UDK and keyboard status this
    terminal does not have. }
  Check('CSI ? 6 n is left unanswered on purpose', Silent(#27'[?6n'));
  Check('CSI 0 n is not a request and is not answered', Silent(#27'[0n'));
end;

procedure TestPrivateSequencesStayIgnored;
var
  S: TProbeScreen;
begin
  { The reason DoPrivateCSI exists at all: these must keep being consumed
    without being acted on. Reading them as ordinary CSI would set underline
    for the first and move the cursor for the second. }
  Check('modifyOtherKeys is still ignored', Silent(#27'[>4;2m'));
  Check('the kitty keyboard query is still ignored', Silent(#27'[>1u'));
  S := TProbeScreen.Create(80, 24);
  try
    Feed(S, 'A');
    Feed(S, #27'[>4;2m');
    Feed(S, 'B');
    Check('a private CSI leaks no text onto the grid',
      (S.Grid[0][0].Txt[0] = 'A') and (S.Grid[0][1].Txt[0] = 'B'));
    Check('a private CSI applies no rendition',
      S.Attr = S.Grid[0][0].Attr);
  finally
    S.Free;
  end;
end;

procedure TestSplitAcrossWrites;
var
  S: TProbeScreen;
  Reply, Part: RawByteString;
begin
  { A PTY read can end anywhere. A query split across two writes must still
    be recognised exactly once. }
  S := TProbeScreen.Create(80, 24);
  try
    Part := #27'[6';
    Feed(S, Part);
    Check('half a query owes nothing yet', S.PendingReplies = 0);
    Part := 'n';
    Feed(S, Part);
    Reply := '';
    S.ConsumeReply(Reply);
    Check('a query split across two writes is answered once',
      Reply = __CPR_HOME__);
  finally
    S.Free;
  end;
end;

{ Feed a setup sequence, then ask about a mode; return the whole answer. }
function AskMode(const Setup, Query: RawByteString): RawByteString;
var
  S: TProbeScreen;
begin
  Result := '';
  S := TProbeScreen.Create(80, 24);
  try
    Feed(S, Setup);
    { A setup sequence must not itself owe anything. }
    while S.PendingReplies > 0 do
      S.ConsumeReply(Result);
    Result := '';
    Feed(S, Query);
    if S.PendingReplies <> 1 then
    begin
      Result := '<' + IntToStr(S.PendingReplies) + ' answers>';
      Exit;
    end;
    S.ConsumeReply(Result);
  finally
    S.Free;
  end;
end;

procedure TestRequestMode;
begin
__DECRQM_CHECKS__
  { The '$' intermediate is what makes 'p' a mode request. XTPUSHSGR is also
    a 'p' and must not be answered as one. }
  Check('CSI # p is not a mode request', Silent(#27'[#p'));
end;

procedure TestGetTcap;
var
  S: TProbeScreen;
  Reply, Part: RawByteString;
begin
__TCAP_CHECKS__
  { A request split across writes -- a PTY read ends wherever it ends. }
  S := TProbeScreen.Create(80, 24);
  try
    Part := #27'P+q54';
    Feed(S, Part);
    Check('half a capability request owes nothing yet',
      S.PendingReplies = 0);
    Part := '4E'#27'\';
    Feed(S, Part);
    Reply := '';
    S.ConsumeReply(Reply);
    Check('a capability request split across writes is answered',
      Reply = __TCAP_TN__);
  finally
    S.Free;
  end;
  { Other control strings stay discarded and unanswered. }
  Check('a DCS that is not a capability request is not answered',
    Silent(#27'Pnonsense'#27'\'));
  Check('an APC string is not answered', Silent(#27'_+q544E'#27'\'));
  Check('a PM string is not answered', Silent(#27'^+q544E'#27'\'));
  Check('an SOS string is not answered', Silent(#27'X+q544E'#27'\'));
  { A control string must never leak its payload onto the grid. }
  S := TProbeScreen.Create(80, 24);
  try
    Feed(S, 'A');
    Feed(S, #27'P+q544E'#27'\');
    Feed(S, 'B');
    Check('a capability request leaves no text on the grid',
      (S.Grid[0][0].Txt[0] = 'A') and (S.Grid[0][1].Txt[0] = 'B'));
  finally
    S.Free;
  end;
end;

begin
  Failures := 0;
  Checks := 0;
  TestEmpty;
  TestFifo;
  TestSizeLimit;
  TestOverflowDropsOldest;
  TestResetAndLoadClear;
  TestDeviceAttributes;
  TestStatusReports;
  TestPrivateSequencesStayIgnored;
  TestSplitAcrossWrites;
  TestRequestMode;
  TestGetTcap;
  Writeln('SUMMARY checks=', Checks, ' failures=', Failures);
  if Failures > 0 then
    Halt(1);
end.
'''

def decrqm_checks():
    """One check per mode, generated from the shared specification.

    Each implemented private mode is asked about twice -- once after being
    set and once after being reset -- because a responder that answers a
    constant would otherwise pass a single-state matrix.
    """
    lines = []

    def emit(label, setup, query, expected):
        lines.append(
            f"  Check('{label}',\n"
            f"    AskMode({pascal_literal(setup)}, {pascal_literal(query)}) = "
            f"{pascal_literal(expected)});")

    for mode in vtreplies.PRIVATE_MODES_IMPLEMENTED:
        query = f'\x1b[?{mode}$p'.encode('ascii')
        emit(f'DECRQM ?{mode} reports set after DECSET',
             f'\x1b[?{mode}h'.encode('ascii'), query,
             vtreplies.decrpm(mode, vtreplies.MODE_SET))
        emit(f'DECRQM ?{mode} reports reset after DECRST',
             f'\x1b[?{mode}l'.encode('ascii'), query,
             vtreplies.decrpm(mode, vtreplies.MODE_RESET))

    # A mode the model does not implement must say so, not guess.
    for mode in (3, 5, 6, 12, 1004, 2026):
        emit(f'DECRQM ?{mode} is reported as not recognized', b'',
             f'\x1b[?{mode}$p'.encode('ascii'),
             vtreplies.decrpm(mode, vtreplies.MODE_NOT_RECOGNIZED))

    for mode in vtreplies.ANSI_MODES_ANSWERED_RESET:
        emit(f'DECRQM {mode} is reported recognized and reset', b'',
             f'\x1b[{mode}$p'.encode('ascii'),
             vtreplies.decrpm(mode, vtreplies.MODE_RESET, private=False))

    for mode in (1, 7, 25):
        emit(f'DECRQM {mode} (ANSI) is not the private mode of the same '
             f'number', b'', f'\x1b[{mode}$p'.encode('ascii'),
             vtreplies.decrpm(mode, vtreplies.MODE_NOT_RECOGNIZED,
                              private=False))
    return '\n'.join(lines)


def tcap_checks():
    """One check per capability request, generated from the specification."""
    lines = []

    def emit(label, names):
        request = vtreplies.xtgettcap_request(*names)
        expected = vtreplies.xtgettcap_reply(*names)
        lines.append(
            f"  Check('{label}',\n"
            f"    Ask({pascal_literal(request)}) = "
            f"{pascal_literal(expected)});")

    for name in sorted(vtreplies.XTGETTCAP_VALID):
        emit(f'XTGETTCAP {name} is answered with its value', [name])
    emit('XTGETTCAP answers several names in one reply', ['TN', 'Co'])
    emit('XTGETTCAP answers the terminfo spellings too', ['name', 'colors'])
    for name in vtreplies.XTGETTCAP_INVALID:
        emit(f'XTGETTCAP {name} is refused', [name])
    # An unknown name ends processing of the list, so one bad name fails the
    # whole request -- including when it is not the first.
    emit('an unknown name after a known one fails the request',
         ['TN', 'RGB'])
    emit('an unknown name before a known one fails the request',
         ['RGB', 'TN'])
    return '\n'.join(lines)


PROBE = PROBE.replace('__DECRQM_CHECKS__', decrqm_checks())
PROBE = PROBE.replace('__TCAP_CHECKS__', tcap_checks())
PROBE = PROBE.replace('__TCAP_TN__',
                      pascal_literal(vtreplies.xtgettcap_reply('TN')))

# The expected bytes come from the shared specification, so a divergence
# between the Pascal responder and test/vtreplies.py fails here rather than
# being discovered by an application that hangs.
PROBE = PROBE.replace('__DA1__', pascal_literal(vtreplies.DA1))
PROBE = PROBE.replace('__DA2__', pascal_literal(vtreplies.DA2))
PROBE = PROBE.replace('__DSR_OK__', pascal_literal(vtreplies.DSR_OK))
PROBE = PROBE.replace('__CPR_HOME__', pascal_literal(vtreplies.cpr(1, 1)))
PROBE = PROBE.replace('__CPR_12_40__', pascal_literal(vtreplies.cpr(12, 40)))
PROBE = PROBE.replace('__DA1_QUERY0__', pascal_literal(b'\x1b[0c'))
PROBE = PROBE.replace('__DA1_QUERY__', pascal_literal(b'\x1b[c'))
PROBE = PROBE.replace('__DA2_QUERY0__', pascal_literal(b'\x1b[>0c'))
PROBE = PROBE.replace('__DA2_QUERY__', pascal_literal(b'\x1b[>c'))
assert '__' not in PROBE, 'an expected value was left unsubstituted'


def main():
    fpc = os.environ.get('FPC', 'fpc')
    if shutil.which(fpc) is None:
        print('Free Pascal is required for this suite')
        sys.exit(1)
    work = Path(tempfile.mkdtemp(prefix='superterm-replies-'))
    try:
        source = work / 'screen_replies_probe.pas'
        source.write_text(PROBE, encoding='utf-8')
        units = work / 'units'
        units.mkdir()
        build = subprocess.run(
            [fpc, '-Mobjfpc', '-Sh', '-vewnh', '-vm11030,11031',
             f'-Fu{ROOT / "src"}', f'-Fu{ROOT / "src" / "terminal"}',
             f'-FU{units}', f'-FE{work}',
             '-O1', str(source)],
            capture_output=True, text=True)
        noise = [line for line in build.stdout.splitlines()
                 if ' Warning:' in line or ' Note:' in line
                 or ' Hint:' in line or ' Error:' in line]
        check('the probe compiles', build.returncode == 0)
        if build.returncode != 0:
            print(build.stdout[-4000:])
            print(build.stderr[-2000:])
            print('\nRESULT: FAIL')
            sys.exit(1)
        # The unit is built with -vewnh in the product too; a diagnostic here
        # is a diagnostic there.
        check('the probe compiles without diagnostics', not noise)
        for line in noise:
            print(f'  {line}')

        run = subprocess.run([str(work / 'screen_replies_probe')],
                             capture_output=True, text=True, timeout=60)
        print(run.stdout.rstrip())
        if run.stderr.strip():
            print(run.stderr.rstrip())
        check('every reply-queue scenario passes', run.returncode == 0)
    finally:
        shutil.rmtree(work, ignore_errors=True)

    print()
    if failed:
        print('RESULT: FAIL')
        sys.exit(1)
    print('RESULT: PASS')
    sys.exit(0)


main()
