(*
  Author: German Luis Aracil Boned
  Project: superterm - terminal with autologin, splits and sessions
  Unit: st_screen - virtual screen + VT100/ANSI parser
*)

unit st_screen;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Math, Classes;

const
  MAX_SCREEN_SCROLLBACK = 100000;
  // Geometry the snapshot validator accepts. It must not be narrower than the
  // geometry the application itself can build: a pane on an 8192-column
  // terminal is a legal screen, and capping the loader at 4096 meant such a
  // screen could be saved but never loaded back -- the attach failed and the
  // pane came up as garbage. Kept in one place so producer and consumer agree.
  MAX_SCREEN_COLS = 8192;   // >= the vendor's MaxViewWidth
  MAX_SCREEN_ROWS = 4096;
  // attribute bits
  A_BOLD = $0100;
  A_UNDER = $0200;
  A_REVERSE = $0400;
  A_FGDEF = $0800;
  A_BGDEF = $1000;
  // Bright foreground. Kept SEPARATE from A_BOLD: A_BOLD is the WEIGHT
  // (SGR 1 / 22) while this is the high bit of the 16-color foreground (SGR
  // 90-97 and the bright half of an approximated 256-color). Overloading
  // A_BOLD meant SGR 22 ("normal intensity") also demoted the COLOR, which
  // turned Claude Code's grey text pure black. Bit 3 of the fg nibble is free
  // (it only ever holds 0..7), so every "Attr and $FFF0" that changes the
  // foreground clears the bright bit automatically.
  A_FGBRIGHT = $0008;
  // SGR 2: faint / dim. Claude Code marks all its secondary text with it
  // (hints, shortcuts, placeholders); ignoring it painted that text at exactly
  // the same weight as the primary text and flattened the UI's hierarchy.
  // Mutually exclusive with A_BOLD, and SGR 22 clears both.
  A_FAINT = $2000;
  // SGR 8: conceal. The application asked for this text NOT to be shown --
  // TUI password fields and form widgets use it -- so rendering it in clear
  // leaks the secret onto the screen, into the scrollback and into `capture`.
  A_CONCEAL = $4000;

type
  TCell = record
    Txt: array[0..7] of AnsiChar;
    Len: byte;
    Attr: word;
    Cont: boolean; // continuation cell of a wide character
    // truecolor kept alongside the 16-color Attr fallback: 0 = use Attr,
    // else $01RRGGBB. The rich renderer emits these directly; the CP437
    // FreeVision path keeps using Attr.
    FgRGB, BgRGB: LongWord;
  end;

  TRow = array of TCell;
  TGridArray = array of TRow;
  // psDcs/psDcsEsc consume string sequences (DCS ESC P, SOS ESC X, PM ESC ^,
  // APC ESC _) up to their ST/BEL terminator and DISCARD them, so an app's
  // capability query (e.g. XTGETTCAP "ESC P + q ... ESC \") never leaks its
  // payload onto the grid as stray characters. Appended to keep existing
  // ordinals stable for the serialized parser state.
  TParserState = (psGround, psEsc, psCsi, psOsc, psCharset, psOscEsc,
    psDcs, psDcsEsc);
  TCharBuf = array[0..7] of AnsiChar; // buffer for one UTF-8 codepoint
  // what the application asked the terminal to report about the mouse.
  // ?9 X10 presses | ?1000 presses and releases | ?1002 plus motion while a
  // button is held | ?1003 plus every motion. Kept as a bitmask, so that
  // "?1002h ?1003h ?1003l" falls back to ?1002 the way xterm does.
  TMouseTrack = (mtOff, mtX10, mtNormal, mtButton, mtAny);
  // and in which encoding: X10 bytes (the default), UTF-8 (?1005), SGR
  // (?1006), urxvt (?1015) or pixels (?1016, reported in cells here)
  TMouseProto = (mpX10, mpUtf8, mpSGR, mpUrxvt, mpPixel);

  TOsc52Event = record
    Selection: RawByteString;
    Payload: RawByteString;
  end;
  TOsc52EventArray = array of TOsc52Event;

  // Answers this terminal owes the program in the pane. A pane is launched
  // with a fixed TERM=xterm-256color contract, so it may interrogate the
  // terminal (DA, DSR, DECRQM, XTGETTCAP) and wait for a reply; the exact
  // bytes are specified in test/vtreplies.py.
  //
  // Only the process that OWNS the PTY may drain this queue. Every viewer
  // parses the same byte stream into its own mirror and therefore queues the
  // same answers, so a viewer that sent them would reply once per attached
  // client to a query that was asked once. A mirror simply leaves them here;
  // the bound below is what makes that safe.
  TReplyArray = array of RawByteString;
  // Identifies one borrowed reply. Zero means "nothing on loan"; a real token
  // is never reused, so a stale acknowledgement cannot retire a later reply.
  TScreenReplyToken = type QWord;

  TScreen = class
  private
    FGrid: TGridArray;
    FAltGrid: TGridArray;   // alt screen buffer
    FUsingAlt: boolean;
    FPendingWrap: boolean;
    // scrollback
    FSBRing: array of TRow;
    FSBCount: integer;
    FSBHead: integer;
    FViewTop: integer;         // 0 = live; >0 = lines back
    // parser
    FPState: TParserState;
    FPParams: array[0..15] of integer;
    FPCount: integer;
    // which CSI parameters were introduced by ':' rather than ';'. The colon
    // form of truecolor is "38:2:<colour-space>:R:G:B" -- it carries an extra
    // field the semicolon form does not -- so the separator has to be known
    // or the channels come out shifted by one.
    FPColon: array[0..15] of boolean;
    FPPriv: boolean;
    FPrivOther: boolean;    // CSI private intro < = > (consumed but NOT acted on)
    // Which of '<' '=' '>' introduced the current private CSI. Almost all of
    // them stay ignored; the exception is "CSI > c" (Secondary DA), which is
    // a query the terminal owes an answer to.
    FPrivIntro: AnsiChar;
    FUtfBuf: array[0..7] of byte;
    FUtfLen: byte;
    FUtfNeed: byte;
    FOscBuf: RawByteString;
    FOscLen: integer;
    FSaveX, FSaveY: integer;
    // DECSC (ESC 7) saves cursor AND graphic rendition; DECRC (ESC 8) restores
    // both. Keeping only the position left attributes leaking across a restore.
    FSaveAttr: word;
    FSaveFgRGB, FSaveBgRGB: LongWord;
    // The alternate screen (?1049) has its OWN save slot in xterm, independent
    // of DECSC, and it too saves the graphic rendition. Without this an app
    // that exits the alt screen without an explicit SGR reset (Claude Code
    // does exactly that) left its last attributes -- typically bold -- applied
    // to every byte the shell printed afterwards.
    FAltSaveX, FAltSaveY: integer;
    FAltSaveAttr: word;
    FAltSaveFgRGB, FAltSaveBgRGB: LongWord;
    FInterm: AnsiChar;      // CSI intermediate byte (e.g. ' ' of DECSCUSR)
    FAutoWrap: boolean;     // DECAWM ?7 (default on)
    // DECCKM ?1: the cursor keys send SS3 (ESC O A) instead of CSI (ESC [ A).
    // Every curses program sets it (keypad(TRUE)), and then IGNORES the CSI
    // form -- which is why the arrows did nothing in top and htop.
    FAppCursor: boolean;
    // DECKPAM (ESC =) / DECKPNM (ESC >): numeric keypad in application mode.
    // Parsed and kept so it does not leak as text; FreeVision cannot tell a
    // keypad arrow from a cursor arrow, so there is nothing to translate.
    FAppKeypad: boolean;
    FBracketedPaste: boolean;
    FMouseBits: word;          // bit0 ?9, bit1 ?1000, bit2 ?1002, bit3 ?1003
    FMouseProto: TMouseProto;
    FOscOverflow: boolean;
    // DCS payload. SOS, PM and APC strings are still discarded unread; only
    // a real DCS (ESC P) is captured, because XTGETTCAP arrives that way and
    // is a query the terminal owes an answer to.
    FDcsBuf: RawByteString;
    FDcsLen: integer;
    FDcsOverflow: boolean;
    FDcsCapture: boolean;
    FOsc52Queue: TOsc52EventArray;
    FReplyQueue: TReplyArray;
    // Loan state for PeekReply/AcknowledgeReply. Only one reply is on loan at
    // a time, and only the exact token that borrowed it may retire it.
    FReplyLoanToken: TScreenReplyToken;
    FLastReplyToken: QWord;
    function GetMouseTrack: TMouseTrack;
    procedure ClearCell(var C: TCell);
    procedure ResizeGrid(var AGrid: TGridArray; OldWidth, OldHeight,
      NewWidth, NewHeight: integer);
    procedure CopyGrid(const Source: TGridArray; out Target: TGridArray);
    procedure BlankRow(y: integer; AAttr: word);
    procedure AppendZeroWidth(const S: RawByteString);
    procedure PutAsciiChar(b: byte; AAttr: word);
    procedure PutRawChar(const b: TCharBuf; alen: byte; AAttr: word);
    procedure ScrollUp(n: integer);
    procedure ScrollDown(n: integer);
    procedure LineFeed;
    procedure PutCharByte(b: byte);
    procedure DoCSI(final: AnsiChar);
    procedure DoPrivateCSI(final: AnsiChar);
    function ModeState(APrivate: boolean; AMode: integer): integer;
    procedure DispatchEsc(c: AnsiChar);
    procedure FinishOsc;
    procedure FinishDcs;
    procedure AnswerXtGetTcap(const ARequest: RawByteString);
    procedure QueueOsc52(const ASelection, APayload: RawByteString);
    function GetParam(i, def: integer): integer;
    procedure SetCellStr(x, y: integer; const S: RawByteString; AAttr: word);
    // One ASCII byte into one cell, without building a string for it. Same
    // result as SetCellStr with a one-character narrow string.
    procedure SetCellByte(x, y: integer; AByte: byte; AAttr: word);
    function CellWidth(const S: RawByteString): integer;
    procedure EraseRange(x1, y1, x2, y2: integer; AAttr: word);
    procedure PushScrollRow(const R: TRow);
  protected
    // Owe the pane one answer. Protected rather than private so the queue's
    // contract -- FIFO order, the per-answer size limit, and dropping the
    // OLDEST entry on overflow -- can be exercised on its own, independently
    // of whichever handler happens to produce an answer.
    procedure QueueReply(const AReply: RawByteString);
  public
    Width, Height: integer;
    CursorX, CursorY: integer;
    ScrollTop, ScrollBot: integer;
    CursorVisible: boolean;
    CursorStyle: integer;   // DECSCUSR: 0 def | 1/2 block | 3/4 under | 5/6 bar
    Attr: word; // current attr of the stream (16-color fallback)
    AttrFgRGB, AttrBgRGB: LongWord; // current truecolor of the stream (0=none)
    Dirty: boolean;
    MaxScrollBack: integer;    // history capacity (0 = no history)
    constructor Create(AWidth, AHeight: integer; AMaxScrollBack: integer = 10000);
    destructor Destroy; override;
    procedure Resize(AWidth, AHeight: integer);
    procedure WriteBytes(const Buf; Count: integer);
    procedure ClampCursor;
    procedure ResetSoft;
    // RIS (ESC c): full reset -- what `reset` sends (terminfo rs1). Unlike the
    // soft reset it also ERASES the screen, leaves the alternate buffer and
    // drops the scrollback.
    procedure ResetHard;
    // what the application asked the keyboard to send (see the fields)
    property AppCursorKeys: boolean read FAppCursor;
    property AppKeypad: boolean read FAppKeypad;
    property BracketedPaste: boolean read FBracketedPaste;
    // mouse reporting the application asked for (mtOff = it wants none)
    property MouseTrack: TMouseTrack read GetMouseTrack;
    property MouseProto: TMouseProto read FMouseProto;
    function ViewOffset: integer;
    // absolute viewport position: 0 = live screen, N = N lines back
    procedure SetViewOffset(AOffset: integer);
    procedure ScrollViewport(ADelta: integer);  // + back, - forward
    // the application is on the alternate screen (?1049): there is no
    // history there, and the scrollbar and the wheel behave accordingly
    property UsingAlt: boolean read FUsingAlt;
    function DisplayRow(y: integer): TRow;
    procedure SaveToStream(Stream: TStream);
    function LoadFromStream(Stream: TStream): boolean;
    // text capture: absolute rows 0..HistoryRows-1 = history (the oldest
    // first) and HistoryRows..HistoryRows+Height-1 = live screen
    function HistoryRows: integer;
    function AbsRow(AIndex: integer): TRow;
    procedure RenderTextRange(AFrom, ACount: integer; AOut: TStream);
    function RenderSelection(AStartRow, AStartCol, AEndRow,
      AEndCol: integer): RawByteString;
    function TakeOsc52(out ASelection, APayload: RawByteString): boolean;
    // Oldest pending answer to a query the pane made, removed from the queue.
    // False when there is nothing owed. See TReplyArray: only the process
    // holding the PTY may call this.
    function TakeReply(out AReply: RawByteString): boolean;
    // Borrow the oldest owed answer WITHOUT removing it, together with a token.
    // A drain writes the bytes to the PTY and only then acknowledges: if the
    // write fails, is partial, or the process dies mid-way, the reply is still
    // queued and the next drain retries it. TakeReply cannot offer that,
    // because it has already destroyed the reply by the time the write fails.
    function PeekReply(var AToken: TScreenReplyToken;
      var AReply: RawByteString): boolean;
    // Retire the borrowed reply. Only the exact outstanding token works, so a
    // late acknowledgement from an abandoned drain cannot drop a reply that a
    // later drain has since borrowed.
    function AcknowledgeReply(AToken: TScreenReplyToken): boolean;
    // Answers still owed. A mirror never drains, so this is also how a test
    // observes what the terminal WOULD have replied.
    function PendingReplies: integer;
    property Grid: TGridArray read FGrid;
  end;

implementation

const
  MAX_OSC_BYTES = 2 * 1024 * 1024;
  MAX_OSC52_EVENTS = 16;
  // A well-formed answer is a few dozen bytes; the largest is an XTGETTCAP
  // reply carrying several hex-encoded name/value pairs. Anything past this
  // is malformed and is not queued at all.
  MAX_REPLY_BYTES = 4096;
  // A capability request is a short list of two-to-six letter names in hex.
  // Anything longer is not a request this terminal can answer, and capturing
  // it would only cost memory for a payload that ends up discarded.
  MAX_DCS_BYTES = 4096;
  // Deep enough that a program interrogating the terminal at startup -- the
  // realistic burst -- is answered in full, and bounded because a mirror
  // never drains and a pane could otherwise queue answers without limit.
  //
  // On overflow the OLDEST answer is dropped, not the newest: the query a
  // program is currently blocked on is the most recent one, so discarding
  // the front keeps the reply it is actually waiting for.
  MAX_REPLY_EVENTS = 32;

  // What this terminal says when a pane interrogates it. The full table, with
  // a citation into docs/references/xterm-ctlseqs.txt for every value and the
  // reasoning for each capability deliberately NOT claimed, is
  // test/vtreplies.py; keep the two in step.
  //
  // Replies use 7-bit controls: the client asserts S7C1T on its host, and a
  // pane handed 8-bit C1 bytes would have to guess an encoding for them.
  //
  // Primary DA: VT220-class, and of the VT220 feature list only 22 (ANSI
  // colour), because that is all the screen model implements. Claiming more
  // would invite sequences this parser would then mis-handle.
  REPLY_DA1 = #27'[?62;22c';
  // Secondary DA: VT220, firmware version 0, cartridge 0. Programs read the
  // version field as xterm's patch level and unlock xterm extensions above
  // known thresholds; superterm implements none of them, so zero asks for
  // nothing.
  REPLY_DA2 = #27'[>1;0;0c';
  // DSR 5: "ready, no malfunctions".
  REPLY_DSR_OK = #27'[0n';
  MAX_SELECTION_BYTES = 1024 * 1024 - 16;

// history rows are stored without their trailing blanks (see below)
function TrimRow(const R: TRow): TRow; forward;

constructor TScreen.Create(AWidth, AHeight: integer; AMaxScrollBack: integer);
begin
  inherited Create;
  Width := AWidth;
  Height := AHeight;
  CursorX := 0;
  CursorY := 0;
  ScrollTop := 0;
  ScrollBot := Height - 1;
  CursorVisible := True;
  CursorStyle := 0;
  Attr := A_FGDEF or A_BGDEF;
  AttrFgRGB := 0;
  AttrBgRGB := 0;
  // saved-cursor slots start at the default rendition: restoring one that was
  // never saved must not paint black on black
  FSaveAttr := A_FGDEF or A_BGDEF;
  FSaveFgRGB := 0;
  FSaveBgRGB := 0;
  FAltSaveAttr := A_FGDEF or A_BGDEF;
  FAltSaveFgRGB := 0;
  FAltSaveBgRGB := 0;
  Dirty := True;
  FUsingAlt := False;
  FAutoWrap := True;
  FAppCursor := False;
  FAppKeypad := False;
  FBracketedPaste := False;
  FMouseBits := 0;
  FMouseProto := mpX10;
  FOscOverflow := False;
  FOscLen := 0;
  FDcsBuf := '';
  FDcsLen := 0;
  FDcsOverflow := False;
  FDcsCapture := False;
  FOsc52Queue := nil;
  FReplyQueue := nil;
  FReplyLoanToken := TScreenReplyToken(0);
  FPrivIntro := #0;
  FInterm := #0;
  MaxScrollBack := AMaxScrollBack;
  if MaxScrollBack < 0 then
    MaxScrollBack := 0;
  if MaxScrollBack > MAX_SCREEN_SCROLLBACK then
    MaxScrollBack := MAX_SCREEN_SCROLLBACK;
  FSBCount := 0;
  FSBHead := 0;
  FViewTop := 0;
  if MaxScrollBack > 0 then
    SetLength(FSBRing, MaxScrollBack);
  Resize(AWidth, AHeight);
end;

destructor TScreen.Destroy;
begin
  inherited;
end;

procedure TScreen.ClearCell(var C: TCell);
begin
  FillChar(C, SizeOf(C), 0);
  C.Attr := A_FGDEF or A_BGDEF;
end;

procedure TScreen.ResizeGrid(var AGrid: TGridArray; OldWidth, OldHeight,
  NewWidth, NewHeight: integer);
var
  NewGrid: TGridArray;
  x, y, CopyWidth, CopyHeight: integer;
begin
  if AGrid = nil then
    Exit;
  NewGrid := Default(TGridArray);
  SetLength(NewGrid, NewHeight);
  for y := 0 to NewHeight - 1 do
  begin
    SetLength(NewGrid[y], NewWidth);
    for x := 0 to NewWidth - 1 do
      ClearCell(NewGrid[y][x]);
  end;
  CopyWidth := Min(OldWidth, NewWidth);
  CopyHeight := Min(OldHeight, NewHeight);
  for y := 0 to CopyHeight - 1 do
    for x := 0 to CopyWidth - 1 do
      NewGrid[y][x] := AGrid[y][x];
  AGrid := NewGrid;
end;

procedure TScreen.CopyGrid(const Source: TGridArray; out Target: TGridArray);
var
  y: integer;
begin
  Target := Default(TGridArray);
  SetLength(Target, Length(Source));
  for y := 0 to High(Source) do
    Target[y] := Copy(Source[y], 0, Length(Source[y]));
end;

procedure TScreen.BlankRow(y: integer; AAttr: word);
var
  x: integer;
begin
  if (y < 0) or (y >= Height) then
    Exit;
  for x := 0 to Width - 1 do
  begin
    ClearCell(FGrid[y][x]);
    FGrid[y][x].Attr := AAttr;
  end;
end;

procedure TScreen.Resize(AWidth, AHeight: integer);
var
  NewGrid: TGridArray;
  x, y, cw, ch, Lost, Spare, SrcY, OldWidth, OldHeight: integer;
begin
  cw := AWidth;
  ch := AHeight;
  if cw < 1 then cw := 1;
  if ch < 1 then ch := 1;
  // clamp here so no caller can build a screen the serializer cannot round
  // trip (a resize request arrives from the network and is not trusted)
  if cw > MAX_SCREEN_COLS then cw := MAX_SCREEN_COLS;
  if ch > MAX_SCREEN_ROWS then ch := MAX_SCREEN_ROWS;
  Lost := 0;
  if (cw = Width) and (ch = Height) and (FGrid <> nil) then
    Exit;
  OldWidth := Width;
  OldHeight := Height;
  NewGrid := Default(TGridArray);
  SetLength(NewGrid, ch);
  for y := 0 to ch - 1 do
  begin
    SetLength(NewGrid[y], cw);
    for x := 0 to cw - 1 do
      ClearCell(NewGrid[y][x]);
  end;
  if FGrid <> nil then
  begin
    // when shrinking: the top lines that are lost go to the history
    Lost := OldHeight - ch;
    if Lost < 0 then
      Lost := 0;
    // ...but give up the BOTTOM rows first, while they are blank and below the
    // cursor. A pane is created at one size and laid out to its final, slightly
    // smaller one a moment later (108x31 -> 106x30 here). If the program in it
    // has already written its first line by then, scrolling the top away puts
    // that line in the scrollback and off the visible screen -- for a shrink
    // that had empty rows going spare. That is how a window class whose command
    // starts `echo SOMETHING` lost its first line on macOS, where openpty lets
    // the child write before the layout settles; GNU/Linux normally resized
    // first and so never showed it. Sleeping before the echo "fixed" it for the
    // same reason, which is what gave the ordering away.
    // Real terminals shrink this way: empty space below the cursor goes before
    // any content does.
    Spare := 0;
    y := OldHeight - 1;
    while (Spare < Lost) and (y > CursorY) and
          (Length(TrimRow(FGrid[y])) = 0) do
    begin
      Inc(Spare);
      Dec(y);
    end;
    Dec(Lost, Spare);
    // blank rows are not worth keeping: a fresh pane shrunk by the tiler
    // would otherwise start life with "history" and grow a scrollbar for it
    if Lost > 0 then
      for y := 0 to Lost - 1 do
        if Length(TrimRow(FGrid[y])) > 0 then
          PushScrollRow(Copy(FGrid[y], 0, OldWidth));
    for y := 0 to ch - 1 do
    begin
      if ch < OldHeight then
        SrcY := y + Lost
      else
        SrcY := y;
      if SrcY < OldHeight then
        for x := 0 to Min(cw, OldWidth) - 1 do
          NewGrid[y][x] := FGrid[SrcY][x];
    end;
  end;
  if FAltGrid <> nil then
    ResizeGrid(FAltGrid, OldWidth, OldHeight, cw, ch);
  FGrid := NewGrid;
  Width := cw;
  Height := ch;
  if CursorX >= Width then CursorX := Width - 1;
  Dec(CursorY, Lost);
  if CursorY >= Height then CursorY := Height - 1;
  if CursorY < 0 then CursorY := 0;
  ScrollTop := 0;
  ScrollBot := Height - 1;
  FPendingWrap := False;
  if FViewTop > FSBCount then
    FViewTop := FSBCount;
  Dirty := True;
end;

function TScreen.GetMouseTrack: TMouseTrack;
begin
  if (FMouseBits and 8) <> 0 then Result := mtAny
  else if (FMouseBits and 4) <> 0 then Result := mtButton
  else if (FMouseBits and 2) <> 0 then Result := mtNormal
  else if (FMouseBits and 1) <> 0 then Result := mtX10
  else Result := mtOff;
end;

function TScreen.ViewOffset: integer;
begin
  Result := FViewTop;
end;

procedure TScreen.SetViewOffset(AOffset: integer);
begin
  if (FSBCount <= 0) or (AOffset < 0) then
    AOffset := 0;
  if AOffset > FSBCount then
    AOffset := FSBCount;
  if AOffset = FViewTop then
    Exit;
  FViewTop := AOffset;
  Dirty := True;
end;

procedure TScreen.ScrollViewport(ADelta: integer);
var
  T: Int64;
begin
  // Int64: ScrollViewport(MaxInt) is the "go to the top" idiom, and
  // FViewTop + MaxInt overflowed, wrapped negative, and landed on 0 --
  // the bottom -- whenever the view was already scrolled
  T := Int64(FViewTop) + ADelta;
  if T < 0 then T := 0;
  if T > FSBCount then T := FSBCount;
  SetViewOffset(T);
end;

function TScreen.DisplayRow(y: integer): TRow;
var
  k, a, slot: integer;
begin
  Result := nil;
  if (y < 0) or (y >= Height) then
    Exit;
  if FViewTop > FSBCount then
    k := FSBCount
  else
    k := FViewTop;
  a := FSBCount - k + y;
  if a < FSBCount then
  begin
    slot := (FSBHead - FSBCount + a + MaxScrollBack) mod MaxScrollBack;
    Result := Copy(FSBRing[slot], 0, MaxInt);
  end
  else
    Result := Copy(FGrid[a - FSBCount], 0, MaxInt);
end;

procedure WriteScreenString(Stream: TStream; const S: RawByteString);
var
  L: Longint;
begin
  L := Length(S);
  Stream.WriteBuffer(L, SizeOf(L));
  if L > 0 then
    Stream.WriteBuffer(S[1], L);
end;

function ReadScreenString(Stream: TStream; out S: RawByteString): boolean;
var
  L: Longint;
begin
  Result := False;
  S := '';
  L := Default(Longint);
  Stream.ReadBuffer(L, SizeOf(L));
  if (L < 0) or (L > MAX_OSC_BYTES) then
    Exit;
  SetLength(S, L);
  if L > 0 then
    Stream.ReadBuffer(S[1], L);
  Result := True;
end;

procedure SaveScreenGrid(Stream: TStream; const G: TGridArray);
var
  Y, X, N: Longint;
begin
  N := Length(G);
  Stream.WriteBuffer(N, SizeOf(N));
  for Y := 0 to N - 1 do
  begin
    N := Length(G[Y]);
    Stream.WriteBuffer(N, SizeOf(N));
    for X := 0 to N - 1 do
      Stream.WriteBuffer(G[Y][X], SizeOf(TCell));
  end;
end;

function LoadScreenGrid(Stream: TStream; out G: TGridArray): boolean;
var
  Y, X, Rows, Cols: Longint;
begin
  Result := False;
  G := nil;
  Rows := Default(Longint);
  Cols := Default(Longint);
  Stream.ReadBuffer(Rows, SizeOf(Rows));
  if (Rows < 0) or (Rows > MAX_SCREEN_ROWS) then
    Exit;
  SetLength(G, Rows);
  for Y := 0 to Rows - 1 do
  begin
    Stream.ReadBuffer(Cols, SizeOf(Cols));
    if (Cols < 0) or (Cols > MAX_SCREEN_COLS) then
      Exit;
    SetLength(G[Y], Cols);
    for X := 0 to Cols - 1 do
      Stream.ReadBuffer(G[Y][X], SizeOf(TCell));
  end;
  Result := True;
end;

function TScreen.HistoryRows: integer;
begin
  Result := FSBCount;
end;

function TScreen.AbsRow(AIndex: integer): TRow;
var
  Slot: integer;
begin
  Result := nil;
  if AIndex < 0 then
    Exit;
  if AIndex < FSBCount then
  begin
    // same ring formula as SaveToStream/DisplayRow
    Slot := (FSBHead - FSBCount + AIndex + MaxScrollBack) mod MaxScrollBack;
    Result := FSBRing[Slot];
  end
  else if AIndex - FSBCount < Height then
    Result := FGrid[AIndex - FSBCount];
end;

// one row of cells to plain UTF-8 text: the raw bytes of each cell
// (Txt[0..Len-1]), a space for empty cells, wide-character continuations
// are skipped, and trailing blanks are trimmed
function RowToUtf8(const R: TRow): RawByteString;
var
  x, i, LastNonBlank: integer;
  S: RawByteString;
begin
  Result := '';
  if R = nil then
    Exit;
  LastNonBlank := -1;
  for x := 0 to High(R) do
    if (not R[x].Cont) and (R[x].Len > 0) and
       ((R[x].Len <> 1) or (R[x].Txt[0] <> ' ')) then
      LastNonBlank := x;
  S := '';
  for x := 0 to LastNonBlank do
  begin
    if R[x].Cont then
      continue;
    if R[x].Len = 0 then
      S := S + ' '
    else
      for i := 0 to R[x].Len - 1 do
        S := S + R[x].Txt[i];
  end;
  Result := S;
end;

procedure TScreen.RenderTextRange(AFrom, ACount: integer; AOut: TStream);
var
  Total, i: integer;
  S: RawByteString;
const
  NL: AnsiChar = #10;
begin
  Total := FSBCount + Height;
  if AFrom < 0 then
    AFrom := 0;
  if AFrom + ACount > Total then
    ACount := Total - AFrom;
  for i := AFrom to AFrom + ACount - 1 do
  begin
    S := RowToUtf8(AbsRow(i));
    if Length(S) > 0 then
      AOut.WriteBuffer(S[1], Length(S));
    AOut.WriteBuffer(NL, 1);
  end;
end;

function TScreen.RenderSelection(AStartRow, AStartCol, AEndRow,
  AEndCol: integer): RawByteString;
var
  R: TRow;
  Row, X, I, C1, C2, T: integer;
  Line: RawByteString;
begin
  Result := '';
  if (AEndRow < AStartRow) or
     ((AEndRow = AStartRow) and (AEndCol < AStartCol)) then
  begin
    T := AStartRow; AStartRow := AEndRow; AEndRow := T;
    T := AStartCol; AStartCol := AEndCol; AEndCol := T;
  end;
  if AStartRow < 0 then AStartRow := 0;
  if AEndRow >= FSBCount + Height then AEndRow := FSBCount + Height - 1;
  if (AStartRow > AEndRow) or (AStartRow >= FSBCount + Height) then
    Exit;

  for Row := AStartRow to AEndRow do
  begin
    R := AbsRow(Row);
    if Row = AStartRow then C1 := AStartCol else C1 := 0;
    if Row = AEndRow then C2 := AEndCol else C2 := Width - 1;
    if C1 < 0 then C1 := 0;
    if C2 >= Width then C2 := Width - 1;
    if (C1 < Length(R)) and R[C1].Cont then
      while (C1 > 0) and R[C1].Cont do Dec(C1);
    Line := '';
    if C1 <= C2 then
      for X := C1 to C2 do
      begin
        if (X >= Length(R)) or (R[X].Len = 0) then
          Line := Line + ' '
        else if not R[X].Cont then
          for I := 0 to R[X].Len - 1 do
            Line := Line + R[X].Txt[I];
      end;
    while (Line <> '') and (Line[Length(Line)] = ' ') do
      SetLength(Line, Length(Line) - 1);
    if Length(Result) + Length(Line) + Ord(Row < AEndRow) >
       MAX_SELECTION_BYTES then
      Exit('');
    Result := Result + Line;
    if Row < AEndRow then
      Result := Result + #10;
  end;
end;

procedure TScreen.QueueOsc52(const ASelection, APayload: RawByteString);
var
  I, N: integer;
begin
  N := Length(FOsc52Queue);
  if N >= MAX_OSC52_EVENTS then
  begin
    for I := 1 to N - 1 do
      FOsc52Queue[I - 1] := FOsc52Queue[I];
    SetLength(FOsc52Queue, N - 1);
    N := N - 1;
  end;
  SetLength(FOsc52Queue, N + 1);
  FOsc52Queue[N].Selection := ASelection;
  FOsc52Queue[N].Payload := APayload;
end;

procedure TScreen.QueueReply(const AReply: RawByteString);
var
  I, N: integer;
begin
  if (AReply = '') or (Length(AReply) > MAX_REPLY_BYTES) then
    Exit;
  N := Length(FReplyQueue);
  if N >= MAX_REPLY_EVENTS then
  begin
    for I := 1 to N - 1 do
      FReplyQueue[I - 1] := FReplyQueue[I];
    SetLength(FReplyQueue, N - 1);
    N := N - 1;
    // Overflow dropped the entry a drain may be holding, so its token must
    // stop working: acknowledging it now would retire an unrelated reply.
    FReplyLoanToken := TScreenReplyToken(0);
  end;
  SetLength(FReplyQueue, N + 1);
  FReplyQueue[N] := AReply;
end;

function TScreen.TakeReply(out AReply: RawByteString): boolean;
var
  I, N: integer;
begin
  N := Length(FReplyQueue);
  Result := N > 0;
  if not Result then
  begin
    AReply := '';
    Exit;
  end;
  AReply := FReplyQueue[0];
  for I := 1 to N - 1 do
    FReplyQueue[I - 1] := FReplyQueue[I];
  SetLength(FReplyQueue, N - 1);
  // The borrowed entry is gone; the loan cannot survive it.
  FReplyLoanToken := TScreenReplyToken(0);
end;

function TScreen.PeekReply(var AToken: TScreenReplyToken;
  var AReply: RawByteString): boolean;
var
  ReplyCopy: RawByteString;
begin
  Result := Length(FReplyQueue) > 0;
  if not Result then
    Exit;
  // The only allocating step happens BEFORE a token is issued, so a failure
  // here can never leave a token outstanding with no bytes behind it.
  ReplyCopy := Copy(FReplyQueue[0], 1, Length(FReplyQueue[0]));
  if QWord(FReplyLoanToken) = 0 then
  begin
    if FLastReplyToken = High(QWord) then
      // Unreachable in practice (one reply per nanosecond would take
      // centuries), but refusing beats silently reusing a token.
      Exit(False);
    Inc(FLastReplyToken);
    FReplyLoanToken := TScreenReplyToken(FLastReplyToken);
  end;
  AReply := ReplyCopy;
  AToken := FReplyLoanToken;
end;

function TScreen.AcknowledgeReply(AToken: TScreenReplyToken): boolean;
var
  I, N: integer;
begin
  N := Length(FReplyQueue);
  Result := (N > 0) and (QWord(FReplyLoanToken) <> 0) and
    (AToken = FReplyLoanToken);
  if not Result then
    Exit;
  for I := 1 to N - 1 do
    FReplyQueue[I - 1] := FReplyQueue[I];
  SetLength(FReplyQueue, N - 1);
  FReplyLoanToken := TScreenReplyToken(0);
end;

function TScreen.PendingReplies: integer;
begin
  Result := Length(FReplyQueue);
end;

function TScreen.TakeOsc52(out ASelection, APayload: RawByteString): boolean;
var
  I, N: integer;
begin
  N := Length(FOsc52Queue);
  Result := N > 0;
  if not Result then
  begin
    ASelection := '';
    APayload := '';
    Exit;
  end;
  ASelection := FOsc52Queue[0].Selection;
  APayload := FOsc52Queue[0].Payload;
  for I := 1 to N - 1 do
    FOsc52Queue[I - 1] := FOsc52Queue[I];
  SetLength(FOsc52Queue, N - 1);
end;

// XTGETTCAP: "ESC P + q <name>[;<name>...] ESC \", every name hex-encoded
// with two digits per character. The answer is
// "ESC P 1 + r <name>=<value>[;...] ESC \" when every name is known, and
// "ESC P 0 + r ESC \" otherwise -- an unknown name ends processing of the
// list, so one bad name makes the whole request fail.
//
// Only the capabilities that are not names of special keys are answered, and
// the full table with its reasoning lives in test/vtreplies.py. The important
// one is what is deliberately NOT answered: RGB. Publishing RGB tells ncurses
// this is a direct-colour terminal, after which setaf carries a packed RGB
// value that this parser would read as a palette index. Truecolor is offered
// through COLORTERM, exactly as it is alongside any 256-colour description.
procedure TScreen.AnswerXtGetTcap(const ARequest: RawByteString);
const
  HEX: array[0..15] of AnsiChar = '0123456789ABCDEF';

  function HexToName(const S: RawByteString; out AName: string): boolean;
  var
    I, Hi, Lo: integer;

    function Digit(C: AnsiChar; out AValue: integer): boolean;
    begin
      Result := True;
      case C of
        '0'..'9': AValue := Ord(C) - Ord('0');
        'a'..'f': AValue := Ord(C) - Ord('a') + 10;
        'A'..'F': AValue := Ord(C) - Ord('A') + 10;
      else
        AValue := 0;
        Result := False;
      end;
    end;

  begin
    AName := '';
    Result := (S <> '') and (Length(S) mod 2 = 0);
    if not Result then
      Exit;
    I := 1;
    while I < Length(S) do
    begin
      if not Digit(S[I], Hi) or not Digit(S[I + 1], Lo) then
        Exit(False);
      AName := AName + AnsiChar((Hi shl 4) or Lo);
      Inc(I, 2);
    end;
  end;

  function NameToHex(const S: string): RawByteString;
  var
    I: integer;
  begin
    Result := '';
    for I := 1 to Length(S) do
      Result := Result + HEX[Ord(S[I]) shr 4] + HEX[Ord(S[I]) and $0F];
  end;

  // The capabilities superterm answers, all of them dynamic values a
  // terminal description cannot be trusted for. The name MUST be the pane's
  // own TERM (st_pty.pas BuildEnv): a program uses it to look up the static
  // capability set it will then rely on.
  function Capability(const AName: string; out AValue: string): boolean;
  begin
    AValue := '';
    Result := True;
    if (AName = 'TN') or (AName = 'name') then
      AValue := 'xterm-256color'
    else if (AName = 'Co') or (AName = 'colors') then
      AValue := '256'
    else
      Result := False;
  end;

var
  Body, Item, Pairs: RawByteString;
  Name, Value: string;
  P: integer;
begin
  // The nested helpers assign these before use, but the compiler's data-flow
  // analysis does not follow an `out` parameter across a nested call.
  Name := '';
  Value := '';
  Body := Copy(ARequest, 3, MaxInt);   // past the "+q"
  Pairs := '';
  // An empty request names nothing, which is not a valid request.
  if Body = '' then
  begin
    QueueReply(#27'P0+r'#27'\');
    Exit;
  end;
  while Body <> '' do
  begin
    P := Pos(';', Body);
    if P > 0 then
    begin
      Item := Copy(Body, 1, P - 1);
      Body := Copy(Body, P + 1, MaxInt);
    end
    else
    begin
      Item := Body;
      Body := '';
    end;
    if not HexToName(Item, Name) or not Capability(Name, Value) then
    begin
      QueueReply(#27'P0+r'#27'\');
      Exit;
    end;
    if Pairs <> '' then
      Pairs := Pairs + ';';
    Pairs := Pairs + NameToHex(Name) + '=' + NameToHex(Value);
  end;
  QueueReply(#27'P1+r' + Pairs + #27'\');
end;

procedure TScreen.FinishDcs;
var
  Payload: RawByteString;
begin
  SetLength(FDcsBuf, FDcsLen);
  Payload := FDcsBuf;
  FDcsBuf := '';
  FDcsLen := 0;
  FPState := psGround;
  // A truncated request cannot be answered correctly, and answering it
  // wrongly is worse than the program's own timeout.
  if FDcsCapture and (not FDcsOverflow) and (Copy(Payload, 1, 2) = '+q') then
    AnswerXtGetTcap(Payload);
  FDcsOverflow := False;
  FDcsCapture := False;
end;

procedure TScreen.FinishOsc;
var
  Rest, Selection, Payload: RawByteString;
  P: integer;
begin
  SetLength(FOscBuf, FOscLen);
  if (not FOscOverflow) and (Copy(FOscBuf, 1, 3) = '52;') then
  begin
    Rest := Copy(FOscBuf, 4, MaxInt);
    P := Pos(';', Rest);
    if P > 0 then
    begin
      Selection := Copy(Rest, 1, P - 1);
      if Selection = '' then Selection := 'c';
      Payload := Copy(Rest, P + 1, MaxInt);
      QueueOsc52(Selection, Payload);
    end;
  end;
  FOscBuf := '';
  FOscLen := 0;
  FOscOverflow := False;
  FPState := psGround;
end;

procedure TScreen.SaveToStream(Stream: TStream);
var
  I, Slot, X, N: Longint;
  B: byte;
begin
  Stream.WriteBuffer(Width, SizeOf(Width));
  Stream.WriteBuffer(Height, SizeOf(Height));
  Stream.WriteBuffer(CursorX, SizeOf(CursorX));
  Stream.WriteBuffer(CursorY, SizeOf(CursorY));
  Stream.WriteBuffer(ScrollTop, SizeOf(ScrollTop));
  Stream.WriteBuffer(ScrollBot, SizeOf(ScrollBot));
  B := Ord(CursorVisible); Stream.WriteBuffer(B, SizeOf(B));
  Stream.WriteBuffer(CursorStyle, SizeOf(CursorStyle));
  Stream.WriteBuffer(Attr, SizeOf(Attr));
  B := Ord(Dirty); Stream.WriteBuffer(B, SizeOf(B));
  Stream.WriteBuffer(MaxScrollBack, SizeOf(MaxScrollBack));
  B := Ord(FUsingAlt); Stream.WriteBuffer(B, SizeOf(B));
  B := Ord(FPendingWrap); Stream.WriteBuffer(B, SizeOf(B));
  N := Ord(FPState); Stream.WriteBuffer(N, SizeOf(N));
  Stream.WriteBuffer(FPParams, SizeOf(FPParams));
  Stream.WriteBuffer(FPCount, SizeOf(FPCount));
  B := Ord(FPPriv); Stream.WriteBuffer(B, SizeOf(B));
  Stream.WriteBuffer(FUtfBuf, SizeOf(FUtfBuf));
  Stream.WriteBuffer(FUtfLen, SizeOf(FUtfLen));
  Stream.WriteBuffer(FUtfNeed, SizeOf(FUtfNeed));
  WriteScreenString(Stream, Copy(FOscBuf, 1, FOscLen));
  Stream.WriteBuffer(FSaveX, SizeOf(FSaveX));
  Stream.WriteBuffer(FSaveY, SizeOf(FSaveY));
  Stream.WriteBuffer(FInterm, SizeOf(FInterm));
  B := Ord(FAutoWrap); Stream.WriteBuffer(B, SizeOf(B));
  SaveScreenGrid(Stream, FGrid);
  SaveScreenGrid(Stream, FAltGrid);

  N := FSBCount;
  Stream.WriteBuffer(N, SizeOf(N));
  Stream.WriteBuffer(FViewTop, SizeOf(FViewTop));
  if (MaxScrollBack > 0) and (FSBCount > 0) then
    for I := 0 to FSBCount - 1 do
    begin
      Slot := (FSBHead - FSBCount + I + MaxScrollBack) mod MaxScrollBack;
      N := Length(FSBRing[Slot]);
      Stream.WriteBuffer(N, SizeOf(N));
      if N > 0 then
        for X := 0 to N - 1 do
          Stream.WriteBuffer(FSBRing[(FSBHead - FSBCount + I + MaxScrollBack) mod MaxScrollBack][X],
            SizeOf(TCell));
    end;
  // tolerant tail: keyboard modes. An old reader stops after the ring and
  // never sees this; a new reader checks there is something left to read.
  N := 0;
  if FAppCursor then N := N or 1;
  if FAppKeypad then N := N or 2;
  if FBracketedPaste then N := N or 4;
  N := N or (Longint(FMouseBits and $F) shl 4) or (Longint(Ord(FMouseProto)) shl 8);
  Stream.WriteBuffer(N, SizeOf(N));
end;

function TScreen.LoadFromStream(Stream: TStream): boolean;
var
  I, X, N, Cols, MaxSB, StateValue: Longint;
  B: byte;
  Row: TRow;
begin
  Result := False;
  B := Default(byte);
  N := Default(Longint);
  Cols := Default(Longint);
  MaxSB := Default(Longint);
  StateValue := Default(Longint);
  Row := Default(TRow);
  try
    Stream.ReadBuffer(Width, SizeOf(Width));
    Stream.ReadBuffer(Height, SizeOf(Height));
    if (Width < 1) or (Width > MAX_SCREEN_COLS) or
       (Height < 1) or (Height > MAX_SCREEN_ROWS) then
      Exit;
    Stream.ReadBuffer(CursorX, SizeOf(CursorX));
    Stream.ReadBuffer(CursorY, SizeOf(CursorY));
    Stream.ReadBuffer(ScrollTop, SizeOf(ScrollTop));
    Stream.ReadBuffer(ScrollBot, SizeOf(ScrollBot));
    Stream.ReadBuffer(B, SizeOf(B)); CursorVisible := B <> 0;
    Stream.ReadBuffer(CursorStyle, SizeOf(CursorStyle));
    Stream.ReadBuffer(Attr, SizeOf(Attr));
    Stream.ReadBuffer(B, SizeOf(B)); Dirty := B <> 0;
    Stream.ReadBuffer(MaxSB, SizeOf(MaxSB));
    if (MaxSB < 0) or (MaxSB > MAX_SCREEN_SCROLLBACK) then
      Exit;
    MaxScrollBack := MaxSB;
    Stream.ReadBuffer(B, SizeOf(B)); FUsingAlt := B <> 0;
    Stream.ReadBuffer(B, SizeOf(B)); FPendingWrap := B <> 0;
    Stream.ReadBuffer(StateValue, SizeOf(StateValue));
    if (StateValue < Ord(Low(FPState))) or
       (StateValue > Ord(High(FPState))) then
      Exit;
    FPState := TParserState(StateValue);
    Stream.ReadBuffer(FPParams, SizeOf(FPParams));
    Stream.ReadBuffer(FPCount, SizeOf(FPCount));
    Stream.ReadBuffer(B, SizeOf(B)); FPPriv := B <> 0;
    Stream.ReadBuffer(FUtfBuf, SizeOf(FUtfBuf));
    Stream.ReadBuffer(FUtfLen, SizeOf(FUtfLen));
    Stream.ReadBuffer(FUtfNeed, SizeOf(FUtfNeed));
    if not ReadScreenString(Stream, FOscBuf) then
      Exit;
    FOscLen := Length(FOscBuf);
    Stream.ReadBuffer(FSaveX, SizeOf(FSaveX));
    Stream.ReadBuffer(FSaveY, SizeOf(FSaveY));
    Stream.ReadBuffer(FInterm, SizeOf(FInterm));
    Stream.ReadBuffer(B, SizeOf(B)); FAutoWrap := B <> 0;
    if not LoadScreenGrid(Stream, FGrid) then
      Exit;
    if (Length(FGrid) <> Height) then
      Exit;
    for I := 0 to Height - 1 do
      if Length(FGrid[I]) <> Width then
        Exit;
    if not LoadScreenGrid(Stream, FAltGrid) then
      Exit;
    if (Length(FAltGrid) <> 0) and (Length(FAltGrid) <> Height) then
      Exit;
    if Length(FAltGrid) = Height then
      for I := 0 to Height - 1 do
        if Length(FAltGrid[I]) <> Width then
          Exit;

    Stream.ReadBuffer(N, SizeOf(N));
    if (N < 0) or (N > MaxScrollBack) then
      Exit;
    FSBCount := N;
    Stream.ReadBuffer(FViewTop, SizeOf(FViewTop));
    if FViewTop < 0 then FViewTop := 0;
    if FViewTop > FSBCount then FViewTop := FSBCount;
    FSBHead := 0;
    SetLength(FSBRing, MaxScrollBack);
    for I := 0 to FSBCount - 1 do
    begin
      Stream.ReadBuffer(Cols, SizeOf(Cols));
      if (Cols < 0) or (Cols > MAX_SCREEN_COLS) then
        Exit;
      SetLength(Row, Cols);
      for X := 0 to Cols - 1 do
        Stream.ReadBuffer(Row[X], SizeOf(TCell));
      FSBRing[I] := Row;
    end;
    if MaxScrollBack > 0 then
      FSBHead := FSBCount mod MaxScrollBack;
    // Answers owed belong to the process that owns the PTY, never to a
    // snapshot: they are not serialized, and loading one over a mirror that
    // has already been parsing must not leave that mirror's own queue behind.
    FReplyQueue := nil;
  FReplyLoanToken := TScreenReplyToken(0);
    // tolerant tail (see SaveToStream): absent in a snapshot from an older
    // daemon, in which case the modes are learned from the live stream
    FAppCursor := False;
    FAppKeypad := False;
    FBracketedPaste := False;
    FMouseBits := 0;
    FMouseProto := mpX10;
    if Stream.Position + SizeOf(Cols) <= Stream.Size then
    begin
      Stream.ReadBuffer(Cols, SizeOf(Cols));
      FAppCursor := (Cols and 1) <> 0;
      FAppKeypad := (Cols and 2) <> 0;
      FBracketedPaste := (Cols and 4) <> 0;
      FMouseBits := (Cols shr 4) and $F;
      if ((Cols shr 8) and 7) <= Ord(High(TMouseProto)) then
        FMouseProto := TMouseProto((Cols shr 8) and 7);
    end;
    Result := True;
  except
    Result := False;
  end;
end;

function TScreen.CellWidth(const S: RawByteString): integer;
var
  b: byte;
  cp: cardinal;
begin
  Result := 1;
  if Length(S) = 0 then
    Exit;
  b := byte(S[1]);
  if b < $80 then
    Exit;
  if b < $C0 then
    Exit;
  if b < $E0 then
  begin
    if Length(S) < 2 then Exit;
    cp := ((b and $1F) shl 6) or (byte(S[2]) and $3F);
  end
  else if b < $F0 then
  begin
    if Length(S) < 3 then Exit;
    cp := ((b and $0F) shl 12) or ((byte(S[2]) and $3F) shl 6) or (byte(S[3]) and $3F);
  end
  else
  begin
    if Length(S) < 4 then Exit;
    cp := ((b and $07) shl 18) or ((byte(S[2]) and $3F) shl 12) or
      ((byte(S[3]) and $3F) shl 6) or (byte(S[4]) and $3F);
  end;
  // ZERO width: combining marks, variation selectors and the zero-width
  // joiner/spaces. A terminal does not advance for these, and neither must we
  // -- treating them as one column shifted the rest of the line by one for
  // every emoji written as base+VS16 (the routine form of the warning, check
  // and arrow symbols).
  if ((cp >= $0300) and (cp <= $036F)) or
     ((cp >= $1AB0) and (cp <= $1AFF)) or
     ((cp >= $1DC0) and (cp <= $1DFF)) or
     ((cp >= $20D0) and (cp <= $20FF)) or
     ((cp >= $FE00) and (cp <= $FE0F)) or
     ((cp >= $FE20) and (cp <= $FE2F)) or
     ((cp >= $200B) and (cp <= $200F)) then
    Exit(0);
  // TWO columns: CJK/fullwidth, plus the emoji-presentation blocks
  if ((cp >= $1100) and (cp <= $115F)) or
     ((cp >= $2E80) and (cp <= $A4CF)) or
     ((cp >= $AC00) and (cp <= $D7A3)) or
     ((cp >= $F900) and (cp <= $FAFF)) or
     ((cp >= $FE30) and (cp <= $FE6F)) or
     ((cp >= $FF00) and (cp <= $FF60)) or
     ((cp >= $FFE0) and (cp <= $FFE6)) or
     ((cp >= $20000) and (cp <= $3FFFD)) or
     ((cp >= $1F300) and (cp <= $1F64F)) or
     ((cp >= $1F680) and (cp <= $1F6FF)) or
     ((cp >= $1F900) and (cp <= $1FAFF)) or
     (cp = $1F004) or (cp = $1F0CF) or
     ((cp >= $1F18E) and (cp <= $1F19A)) or
     (cp = $231A) or (cp = $231B) or (cp = $23E9) or (cp = $23EA) or
     (cp = $23EB) or (cp = $23EC) or (cp = $23F0) or (cp = $23F3) or
     (cp = $25FD) or (cp = $25FE) or (cp = $2614) or (cp = $2615) or
     ((cp >= $2648) and (cp <= $2653)) or (cp = $267F) or (cp = $2693) or
     (cp = $26A1) or (cp = $26AA) or (cp = $26AB) or (cp = $26BD) or
     (cp = $26BE) or (cp = $26C4) or (cp = $26C5) or (cp = $26CE) or
     (cp = $26D4) or (cp = $26EA) or (cp = $26F2) or (cp = $26F3) or
     (cp = $26F5) or (cp = $26FA) or (cp = $26FD) or (cp = $2705) or
     (cp = $270A) or (cp = $270B) or (cp = $2728) or (cp = $274C) or
     (cp = $274E) or ((cp >= $2753) and (cp <= $2755)) or (cp = $2757) or
     ((cp >= $2795) and (cp <= $2797)) or (cp = $27B0) or (cp = $27BF) or
     (cp = $2B1B) or (cp = $2B1C) or (cp = $2B50) or (cp = $2B55) then
    Result := 2;
end;

procedure TScreen.SetCellByte(x, y: integer; AByte: byte; AAttr: word);
begin
  if (x < 0) or (x >= Width) or (y < 0) or (y >= Height) then
    Exit;
  ClearCell(FGrid[y][x]);
  FGrid[y][x].Len := 1;
  FGrid[y][x].Txt[0] := AnsiChar(AByte);
  FGrid[y][x].Attr := AAttr;
  FGrid[y][x].FgRGB := AttrFgRGB;
  FGrid[y][x].BgRGB := AttrBgRGB;
end;

procedure TScreen.SetCellStr(x, y: integer; const S: RawByteString; AAttr: word);
var
  i: integer;
begin
  if (x < 0) or (x >= Width) or (y < 0) or (y >= Height) then
    Exit;
  ClearCell(FGrid[y][x]);
  FGrid[y][x].Len := Min(Length(S), 7);
  for i := 1 to FGrid[y][x].Len do
    FGrid[y][x].Txt[i - 1] := S[i];
  FGrid[y][x].Attr := AAttr;
  FGrid[y][x].FgRGB := AttrFgRGB;
  FGrid[y][x].BgRGB := AttrBgRGB;
  if CellWidth(S) = 2 then
  begin
    FGrid[y][x].Cont := False;
    if x + 1 < Width then
    begin
      ClearCell(FGrid[y][x + 1]);
      FGrid[y][x + 1].Cont := True;
      FGrid[y][x + 1].Attr := AAttr;
      FGrid[y][x + 1].FgRGB := AttrFgRGB;
      FGrid[y][x + 1].BgRGB := AttrBgRGB;
    end;
  end;
end;

// A history row without its trailing default blanks. A cell is 24 bytes and
// a typical shell line uses a fraction of the width, so keeping whole rows
// made a 10000-line history cost tens of megabytes per pane -- twice, daemon
// and client -- and the attach snapshot shipped all of it. The readers are
// already length-agnostic (DisplayRow pads, the serialiser writes a length
// per row), so this changes nothing on the wire.
function TrimRow(const R: TRow): TRow;
var
  Last, x: integer;
begin
  Last := -1;
  for x := 0 to High(R) do
    if R[x].Cont or (R[x].FgRGB <> 0) or (R[x].BgRGB <> 0) or
       (R[x].Attr <> (A_FGDEF or A_BGDEF)) or
       ((R[x].Len > 0) and ((R[x].Len <> 1) or (R[x].Txt[0] <> ' '))) then
      Last := x;
  Result := Copy(R, 0, Last + 1);
end;

procedure TScreen.PushScrollRow(const R: TRow);
begin
  if MaxScrollBack <= 0 then
    Exit;
  FSBRing[FSBHead] := TrimRow(R);
  FSBHead := (FSBHead + 1) mod MaxScrollBack;
  if FSBCount < MaxScrollBack then
    Inc(FSBCount);
  // A reader scrolled back stays on what they are reading, like xterm and
  // tmux: new output must not drag the view. While the ring still grows the
  // count and the offset rise together and the view is unchanged; once it is
  // full, the oldest row is destroyed and everything shifts one slot, so the
  // offset rises to follow the same content. The clamp is the natural stop.
  if FViewTop > 0 then
  begin
    Inc(FViewTop);
    if FViewTop > FSBCount then
      FViewTop := FSBCount;
  end;
end;

procedure TScreen.ScrollUp(n: integer);
var
  y: integer;
begin
  if n > Height then
    n := Height;
  if n < 1 then
    Exit;
  while n > 0 do
  begin
    Dec(n);
    // The ALTERNATE screen has no scrollback: xterm never pushes its lines to
    // the history. A full-screen app that scrolls (Claude Code repainting, an
    // editor, less) would otherwise flood the pane's history with its own
    // transient frames and bury the real shell output.
    if (ScrollTop = 0) and (not FUsingAlt) then
      PushScrollRow(Copy(FGrid[0], 0, Width));
    for y := ScrollTop to ScrollBot - 1 do
      FGrid[y] := Copy(FGrid[y + 1], 0, Width);
    BlankRow(ScrollBot, Attr);
  end;
  Dirty := True;
end;

procedure TScreen.ScrollDown(n: integer);
var
  y: integer;
begin
  if n > Height then
    n := Height;
  if n < 1 then
    Exit;
  while n > 0 do
  begin
    Dec(n);
    for y := ScrollBot downto ScrollTop + 1 do
      FGrid[y] := Copy(FGrid[y - 1], 0, Width);
    BlankRow(ScrollTop, Attr);
  end;
  Dirty := True;
end;

procedure TScreen.LineFeed;
begin
  if CursorY = ScrollBot then
    ScrollUp(1)
  else if CursorY < Height - 1 then
    Inc(CursorY);
  FPendingWrap := False;
  Dirty := True;
end;

// Attach a zero-width sequence to the cell just written. Emoji are routinely
// sent as base + U+FE0F, and that selector turns a 1-column base into a
// 2-column emoji, so the promotion has to happen here too or the rest of the
// line drifts by one.
procedure TScreen.AppendZeroWidth(const S: RawByteString);
var
  px, i, room: integer;
  IsVS16: boolean;
begin
  px := CursorX - 1;
  while (px >= 0) and (px < Width) and FGrid[CursorY][px].Cont do
    Dec(px);
  if (px < 0) or (px >= Width) then
    Exit;
  if FGrid[CursorY][px].Len = 0 then
    Exit;
  room := 8 - FGrid[CursorY][px].Len;
  if Length(S) <= room then
  begin
    for i := 1 to Length(S) do
    begin
      FGrid[CursorY][px].Txt[FGrid[CursorY][px].Len] := S[i];
      Inc(FGrid[CursorY][px].Len);
    end;
  end;
  IsVS16 := (Length(S) = 3) and (byte(S[1]) = $EF) and (byte(S[2]) = $B8) and
            (byte(S[3]) = $8F);
  if IsVS16 and (px + 1 < Width) and (not FGrid[CursorY][px + 1].Cont) and
     (CursorX = px + 1) then
  begin
    // base + VS16 now occupies two columns
    ClearCell(FGrid[CursorY][px + 1]);
    FGrid[CursorY][px + 1].Cont := True;
    FGrid[CursorY][px + 1].Attr := FGrid[CursorY][px].Attr;
    FGrid[CursorY][px + 1].FgRGB := FGrid[CursorY][px].FgRGB;
    FGrid[CursorY][px + 1].BgRGB := FGrid[CursorY][px].BgRGB;
    Inc(CursorX);
    if CursorX >= Width then
    begin
      CursorX := Width - 1;
      FPendingWrap := FAutoWrap;
    end;
  end;
  Dirty := True;
end;

procedure TScreen.PutRawChar(const b: TCharBuf; alen: byte; AAttr: word);
var
  S: RawByteString;
  i: integer;
  w: integer;
begin
  if FPendingWrap then
  begin
    CursorX := 0;
    LineFeed;
  end;
  // Fast path for a single-byte ASCII glyph, which is what ordinary program
  // output is almost entirely made of. The general path below allocates a
  // RawByteString for EVERY printable character: a 64 KB batch of `ls -R` cost
  // ~65000 heap allocations, and measurement put pane parsing at 1166 us per
  // batch -- eight times the cost of drawing the frame it produced. Nothing
  // here decides anything the general path would decide differently: a byte
  // below $80 is always exactly one column wide, is never a combining mark or
  // a variation selector and never forms a wide pair, so CellWidth would
  // return 1 and SetCellStr would take its narrow branch.
  {$IFNDEF SUPERTERM_NO_ASCII_FAST}
  // Ordinary output no longer arrives here at all: PutCharByte sends printable
  // ASCII straight to PutAsciiChar. What is left of this path is the recovery
  // from a broken UTF-8 sequence, which re-emits its bytes one at a time. Route
  // it to the same routine rather than keeping a second copy of identical
  // semantics -- the pending wrap was already consumed above, so PutAsciiChar's
  // own check is a no-op here.
  if (alen = 1) and (byte(b[0]) < $80) then
  begin
    PutAsciiChar(byte(b[0]), AAttr);
    Dirty := True;
    Exit;
  end;
  {$ENDIF}
  S := Default(RawByteString);
  SetLength(S, alen);
  for i := 0 to alen - 1 do
    S[i + 1] := b[i];
  w := CellWidth(S);
  if w = 0 then
  begin
    // combining mark / variation selector: it belongs to the glyph already
    // written, so append it there (if it fits) and do NOT advance. A VS16
    // additionally promotes its base to emoji presentation, i.e. two columns.
    AppendZeroWidth(S);
    Exit;
  end;
  if CursorX + w > Width then
  begin
    if not FAutoWrap then
    begin
      CursorX := Width - w;
      if CursorX < 0 then CursorX := 0;
    end
    else
    begin
      CursorX := 0;
      LineFeed;
    end;
  end;
  SetCellStr(CursorX, CursorY, S, AAttr);
  Inc(CursorX, w);
  if CursorX >= Width then
  begin
    CursorX := Width - 1;
    if FAutoWrap then
      FPendingWrap := True
    else
      FPendingWrap := False;
  end
  else
    FPendingWrap := False;
  Dirty := True;
end;

// Printable ASCII is the overwhelmingly common terminal-output path. Going
// through PutRawChar used to allocate a managed RawByteString for every byte,
// only for CellWidth to return 1 immediately and SetCellStr to copy that byte
// back into the fixed-size cell. Keep the exact one-column semantics in-place:
// pending wrap, no-wrap overwrite, rendition, cursor and dirty state all match
// the general path, while ordinary output performs no managed allocation.
procedure TScreen.PutAsciiChar(b: byte; AAttr: word);
begin
  if FPendingWrap then
  begin
    CursorX := 0;
    LineFeed;
  end;
  if CursorX + 1 > Width then
  begin
    if not FAutoWrap then
    begin
      CursorX := Width - 1;
      if CursorX < 0 then CursorX := 0;
    end
    else
    begin
      CursorX := 0;
      LineFeed;
    end;
  end;
  ClearCell(FGrid[CursorY][CursorX]);
  FGrid[CursorY][CursorX].Txt[0] := AnsiChar(b);
  FGrid[CursorY][CursorX].Len := 1;
  FGrid[CursorY][CursorX].Attr := AAttr;
  FGrid[CursorY][CursorX].FgRGB := AttrFgRGB;
  FGrid[CursorY][CursorX].BgRGB := AttrBgRGB;
  Inc(CursorX);
  if CursorX >= Width then
  begin
    CursorX := Width - 1;
    if FAutoWrap then
      FPendingWrap := True
    else
      FPendingWrap := False;
  end
  else
    FPendingWrap := False;
  Dirty := True;
end;

procedure TScreen.PutCharByte(b: byte);
var
  arr: TCharBuf;
  i: integer;
begin
  if (FUtfLen = 0) and (b < $80) then
  begin
    PutAsciiChar(b, Attr);
    Exit;
  end;
  arr := Default(TCharBuf);
  if FUtfLen = 0 then
  begin
    FUtfBuf[0] := b;
    FUtfLen := 1;
    if b < $C0 then FUtfNeed := 1
    else if b < $E0 then FUtfNeed := 2
    else if b < $F0 then FUtfNeed := 3
    else FUtfNeed := 4;
    Exit;
  end;
  if (b and $C0) = $80 then
  begin
    if FUtfLen < 8 then
    begin
      FUtfBuf[FUtfLen] := b;
      Inc(FUtfLen);
    end;
  end
  else
  begin
    // broken sequence: emit as-is and reprocess
    for i := 0 to FUtfLen - 1 do
    begin
      arr[0] := AnsiChar(FUtfBuf[i]);
      PutRawChar(arr, 1, Attr);
    end;
    FUtfLen := 0;
    PutCharByte(b);
    Exit;
  end;
  if FUtfLen >= FUtfNeed then
  begin
    for i := 0 to FUtfLen - 1 do
      arr[i] := AnsiChar(FUtfBuf[i]);
    PutRawChar(arr, FUtfLen, Attr);
    FUtfLen := 0;
  end;
end;

procedure TScreen.EraseRange(x1, y1, x2, y2: integer; AAttr: word);
var
  x, y: integer;
begin
  for y := y1 to y2 do
  begin
    if (y < 0) or (y >= Height) then
      continue;
    for x := x1 to x2 do
    begin
      if (x < 0) or (x >= Width) then
        continue;
      ClearCell(FGrid[y][x]);
      FGrid[y][x].Attr := AAttr;
    end;
  end;
  Dirty := True;
end;

// minimum squared distance against the 16-color xterm palette; the
// returned index uses ANSI order (0 black, 1 red, ... 7 white, +8 bright)
function Ansi16FromRgb(R, G, B: integer): integer;
const
  PAL: array[0..15, 0..2] of integer = (
    (0, 0, 0), (205, 0, 0), (0, 205, 0), (205, 205, 0),
    (0, 0, 238), (205, 0, 205), (0, 205, 205), (229, 229, 229),
    (127, 127, 127), (255, 0, 0), (0, 255, 0), (255, 255, 0),
    (92, 92, 255), (255, 0, 255), (0, 255, 255), (255, 255, 255));
var
  i, d, bestd, dr, dg, db: integer;
begin
  // CSI parameters arrive unbounded: clamp to a valid channel
  if R < 0 then R := 0;
  if R > 255 then R := 255;
  if G < 0 then G := 0;
  if G > 255 then G := 255;
  if B < 0 then B := 0;
  if B > 255 then B := 255;
  Result := 7;
  bestd := High(integer);
  for i := 0 to 15 do
  begin
    dr := R - PAL[i][0];
    dg := G - PAL[i][1];
    db := B - PAL[i][2];
    d := dr * dr + dg * dg + db * db;
    if d < bestd then
    begin
      bestd := d;
      Result := i;
    end;
  end;
end;

// xterm-256 index -> ANSI 16 (approximated 6x6x6 cube and gray ramp);
// -1 = invalid index, the caller uses the default color
function Ansi16From256(N: integer): integer;
const
  CUBE: array[0..5] of integer = (0, 95, 135, 175, 215, 255);
var
  c, L: integer;
begin
  if (N >= 0) and (N < 16) then
    Exit(N);
  if (N >= 16) and (N <= 231) then
  begin
    c := N - 16;
    Exit(Ansi16FromRgb(CUBE[c div 36], CUBE[(c div 6) mod 6], CUBE[c mod 6]));
  end;
  if (N >= 232) and (N <= 255) then
  begin
    L := 8 + 10 * (N - 232);
    Exit(Ansi16FromRgb(L, L, L));
  end;
  Result := -1;
end;

function TScreen.GetParam(i, def: integer): integer;
begin
  if (i <= FPCount) and (FPParams[i] <> -1) then
    Result := FPParams[i]
  else
    Result := def;
end;

procedure TScreen.DoCSI(final: AnsiChar);
var
  p1, p2, i, n: integer;
  rr, gg, bb, idx, base: integer;
  RGBVal: LongWord;
begin
  case final of
    'A':
      begin
        n := GetParam(0, 1);
        if n < 1 then n := 1;
        if n > Height then n := Height;
        Dec(CursorY, n);
        if CursorY < ScrollTop then CursorY := ScrollTop;
        FPendingWrap := False;
      end;
    'B', 'e':
      begin
        n := GetParam(0, 1);
        if n < 1 then n := 1;
        if n > Height then n := Height;
        Inc(CursorY, n);
        if CursorY > ScrollBot then CursorY := ScrollBot;
        FPendingWrap := False;
      end;
    'C', 'a':
      begin
        n := GetParam(0, 1);
        if n < 1 then n := 1;
        if n > Width then n := Width;
        Inc(CursorX, n);
        if CursorX >= Width then CursorX := Width - 1;
        FPendingWrap := False;
      end;
    'D':
      begin
        n := GetParam(0, 1);
        if n < 1 then n := 1;
        if n > Width then n := Width;
        Dec(CursorX, n);
        if CursorX < 0 then CursorX := 0;
        FPendingWrap := False;
      end;
    'E':
      begin
        n := GetParam(0, 1);
        if n < 1 then n := 1;
        if n > Height then n := Height;
        Inc(CursorY, n);
        if CursorY > ScrollBot then CursorY := ScrollBot;
        CursorX := 0;
        FPendingWrap := False;
      end;
    'F':
      begin
        n := GetParam(0, 1);
        if n < 1 then n := 1;
        if n > Height then n := Height;
        Dec(CursorY, n);
        if CursorY < ScrollTop then CursorY := ScrollTop;
        CursorX := 0;
        FPendingWrap := False;
      end;
    'G', '`':
      begin
        CursorX := GetParam(0, 1) - 1;
        if CursorX >= Width then CursorX := Width - 1;
        if CursorX < 0 then CursorX := 0;
        FPendingWrap := False;
      end;
    'd':
      begin
        CursorY := GetParam(0, 1) - 1;
        if CursorY >= Height then CursorY := Height - 1;
        if CursorY < 0 then CursorY := 0;
        FPendingWrap := False;
      end;
    'H', 'f':
      begin
        CursorY := GetParam(0, 1) - 1;
        CursorX := GetParam(1, 1) - 1;
        if CursorX >= Width then CursorX := Width - 1;
        if CursorY >= Height then CursorY := Height - 1;
        if CursorX < 0 then CursorX := 0;
        if CursorY < 0 then CursorY := 0;
        FPendingWrap := False;
      end;
    'J':
      begin
        n := GetParam(0, 0);
        case n of
          0: EraseRange(CursorX, CursorY, Width - 1, Height - 1, Attr);
          1: EraseRange(0, 0, CursorX, CursorY, Attr);
          2:
            for i := 0 to Height - 1 do
              BlankRow(i, Attr);
          3:
            begin
              // xterm/tmux: 3J = clear screen + history
              for i := 0 to Height - 1 do
                BlankRow(i, Attr);
              FSBCount := 0;
              FSBHead := 0;
              FViewTop := 0;
            end;
        end;
        Dirty := True;
      end;
    'K':
      begin
        n := GetParam(0, 0);
        case n of
          0: EraseRange(CursorX, CursorY, Width - 1, CursorY, Attr);
          1: EraseRange(0, CursorY, CursorX, CursorY, Attr);
          2: EraseRange(0, CursorY, Width - 1, CursorY, Attr);
        end;
      end;
    'L':
      begin
        if (CursorY >= ScrollTop) and (CursorY <= ScrollBot) then
        begin
          n := GetParam(0, 1);
          if n < 1 then n := 1;
          if n > Height then n := Height;
          for i := ScrollBot downto CursorY + n do
            FGrid[i] := Copy(FGrid[i - n], 0, Width);
          for i := CursorY to Min(CursorY + n - 1, ScrollBot) do
            BlankRow(i, Attr);
          Dirty := True;
        end;
      end;
    'M':
      begin
        if (CursorY >= ScrollTop) and (CursorY <= ScrollBot) then
        begin
          n := GetParam(0, 1);
          if n < 1 then n := 1;
          if n > Height then n := Height;
          for i := CursorY to ScrollBot - n do
            FGrid[i] := Copy(FGrid[i + n], 0, Width);
          for i := Max(ScrollBot - n + 1, CursorY) to ScrollBot do
            BlankRow(i, Attr);
          Dirty := True;
        end;
      end;
    '@':
      begin
        n := GetParam(0, 1);
        if n < 1 then n := 1;
        if n > Width then n := Width;
        for i := Width - 1 downto CursorX + n do
          FGrid[CursorY][i] := FGrid[CursorY][i - n];
        for i := CursorX to Min(CursorX + n - 1, Width - 1) do
        begin
          ClearCell(FGrid[CursorY][i]);
          FGrid[CursorY][i].Attr := Attr;
        end;
        Dirty := True;
      end;
    'P':
      begin
        n := GetParam(0, 1);
        if n < 1 then n := 1;
        if n > Width then n := Width;
        for i := CursorX to Width - 1 - n do
          FGrid[CursorY][i] := FGrid[CursorY][i + n];
        for i := Max(Width - n, 0) to Width - 1 do
        begin
          ClearCell(FGrid[CursorY][i]);
          FGrid[CursorY][i].Attr := Attr;
        end;
        Dirty := True;
      end;
    'X':
      begin
        n := GetParam(0, 1);
        if n < 1 then n := 1;
        if n > Width then n := Width;
        EraseRange(CursorX, CursorY, Min(CursorX + n - 1, Width - 1), CursorY, Attr);
      end;
    'm':
      begin
        if (FPCount = 0) and (FPParams[0] = -1) then
        begin
          Attr := A_FGDEF or A_BGDEF;
          AttrFgRGB := 0;
          AttrBgRGB := 0;
          Exit;
        end;
        i := 0;
        while i <= FPCount do
        begin
          n := GetParam(i, 0);
          case n of
            0: begin Attr := A_FGDEF or A_BGDEF; AttrFgRGB := 0; AttrBgRGB := 0; end;
            1: Attr := (Attr or A_BOLD) and (not A_FAINT);
            2: Attr := (Attr or A_FAINT) and (not A_BOLD);
            3, 5, 6, 9, 23, 29: ;
            8: Attr := Attr or A_CONCEAL;
            28: Attr := Attr and (not A_CONCEAL);
            4: Attr := Attr or A_UNDER;
            7: Attr := Attr or A_REVERSE;
            21, 22: Attr := Attr and (not (A_BOLD or A_FAINT));
            24: Attr := Attr and (not A_UNDER);
            27: Attr := Attr and (not A_REVERSE);
            30..37: begin Attr := ((Attr and $FFF0) and (not A_FGDEF)) or word(n - 30); AttrFgRGB := 0; end;
            39: begin Attr := (Attr and $FFF0) or A_FGDEF; AttrFgRGB := 0; end;
            40..47: begin Attr := ((Attr and $FF0F) and (not A_BGDEF)) or (word(n - 40) shl 4); AttrBgRGB := 0; end;
            49: begin Attr := (Attr and $FF0F) or A_BGDEF; AttrBgRGB := 0; end;
            90..97: begin Attr := ((Attr and $FFF0) and (not A_FGDEF)) or word(n - 90) or A_FGBRIGHT; AttrFgRGB := 0; end;
            100..107: begin Attr := ((Attr and $FF0F) and (not A_BGDEF)) or
              (word(n - 92) shl 4); AttrBgRGB := 0; end;
            38, 48:
              begin
                // 38/48;5;N (indexed) consumes 2 extra; 38/48;2;r;g;b
                // (truecolor) consumes 4; both approximate to ANSI 16
                p2 := GetParam(i + 1, -1);
                RGBVal := 0;   // 0 = no truecolor; keep the 16-color fallback
                if p2 = 5 then
                begin
                  idx := GetParam(i + 2, -1);
                  p1 := Ansi16From256(idx);
                  // Keep the EXACT palette index for the rich renderer
                  // ($030000NN). Claude Code paints nearly everything with
                  // 38;5;N, and flattening that to 16 colors collapsed four
                  // distinct shades into the same grey. Indexes 0..15 stay
                  // untagged so they keep honouring the user's terminal theme.
                  if (idx >= 16) and (idx <= 255) then
                    RGBVal := $03000000 or LongWord(idx);
                  Inc(i, 2);
                end
                else if p2 = 2 then
                begin
                  // colon form carries a colour-space id between the 2 and the
                  // red channel (usually empty): "38:2::R:G:B"
                  base := i + 2;
                  if (base <= 15) and FPColon[base] then
                    Inc(base);
                  rr := GetParam(base, 0);
                  gg := GetParam(base + 1, 0);
                  bb := GetParam(base + 2, 0);
                  // preserve the exact RGB for the rich renderer ($01RRGGBB)
                  RGBVal := $01000000 or (LongWord(rr and $FF) shl 16) or
                    (LongWord(gg and $FF) shl 8) or LongWord(bb and $FF);
                  p1 := Ansi16FromRgb(rr, gg, bb);
                  Inc(i, (base - i) + 2);
                end
                else
                  p1 := -1; // unknown form: default color
                if n = 38 then
                begin
                  AttrFgRGB := RGBVal;
                  // SGR 38 selects a COLOR and must never touch the weight:
                  // a dark 256-color used to cancel a preceding SGR 1, and a
                  // bright one used to fake bold. "and $FFF0" clears the old
                  // bright bit for us.
                  if p1 < 0 then
                    Attr := (Attr and $FFF0) or A_FGDEF
                  else if p1 < 8 then
                    Attr := ((Attr and $FFF0) and (not A_FGDEF)) or word(p1)
                  else
                    Attr := ((Attr and $FFF0) and (not A_FGDEF)) or
                      word(p1 and 7) or A_FGBRIGHT;
                end
                else
                begin
                  AttrBgRGB := RGBVal;
                  if p1 < 0 then
                    Attr := (Attr and $FF0F) or A_BGDEF
                  else
                    Attr := ((Attr and $FF0F) and (not A_BGDEF)) or
                      (word(p1) shl 4);
                end;
              end;
          end;
          Inc(i);
        end;
      end;
    'r':
      begin
        p1 := GetParam(0, 1);
        p2 := GetParam(1, Height);
        if (p1 < 1) then p1 := 1;
        if (p2 > Height) then p2 := Height;
        if p2 > p1 then
        begin
          ScrollTop := p1 - 1;
          ScrollBot := p2 - 1;
          CursorX := 0;
          CursorY := ScrollTop;
        end;
      end;
    'c':
      begin
        // Primary Device Attributes. Only the DEC private form "CSI ? ... c"
        // is a REPLY; "CSI Ps c" from the application is the request, and
        // only Ps = 0 (or omitted) asks for attributes.
        if (not FPPriv) and (GetParam(0, 0) = 0) then
          QueueReply(REPLY_DA1);
      end;
    'p':
      begin
        // DECRQM: "CSI Ps $ p" and "CSI ? Ps $ p". The '$' is an intermediate
        // byte, so the final 'p' alone is ambiguous -- without this guard,
        // XTPUSHSGR's "CSI # p" would be answered as a mode request.
        if FInterm = '$' then
        begin
          n := GetParam(0, 0);
          if FPPriv then
            QueueReply(#27'[?' + IntToStr(n) + ';' +
              IntToStr(ModeState(True, n)) + '$y')
          else
            QueueReply(#27'[' + IntToStr(n) + ';' +
              IntToStr(ModeState(False, n)) + '$y');
        end;
      end;
    'n':
      begin
        // Device Status Report. The DEC private form "CSI ? Ps n" asks about
        // printer/UDK/keyboard status this terminal does not have, so it is
        // deliberately left unanswered rather than answered wrongly.
        if not FPPriv then
          case GetParam(0, 0) of
            5: QueueReply(REPLY_DSR_OK);
            // Cursor Position Report. The grid cursor is 0-based and the
            // report is 1-based. Origin mode is not implemented, so there is
            // no margin-relative form to account for.
            6: QueueReply(#27'[' + IntToStr(CursorY + 1) + ';' +
                 IntToStr(CursorX + 1) + 'R');
          end;
      end;
    's':
      begin
        // CSI s (SCP) is xterm's save-cursor: same slot and same payload as
        // DECSC, so it carries the graphic rendition too. Saving only the
        // position let a prompt or TUI that brackets its colouring with
        // CSI s ... CSI u leak its last attribute into the stream.
        FSaveX := CursorX;
        FSaveY := CursorY;
        FSaveAttr := Attr;
        FSaveFgRGB := AttrFgRGB;
        FSaveBgRGB := AttrBgRGB;
      end;
    'u':
      begin
        CursorX := FSaveX;
        CursorY := FSaveY;
        ClampCursor;
        Attr := FSaveAttr;
        AttrFgRGB := FSaveFgRGB;
        AttrBgRGB := FSaveBgRGB;
      end;
    'q':
      begin
        // DECSCUSR: CSI Ps SP q  (cursor style)
        if FInterm = ' ' then
          CursorStyle := GetParam(0, 0);
      end;
    'S': ScrollUp(GetParam(0, 1));
    'T': ScrollDown(GetParam(0, 1));
    'h', 'l':
      begin
        if FPPriv then
        begin
            for i := 0 to FPCount do
            begin
              n := GetParam(i, 0);
              case n of
                25: CursorVisible := (final = 'h');
                7: FAutoWrap := (final = 'h');
                1: FAppCursor := (final = 'h');
                2004: FBracketedPaste := (final = 'h');
                9: if final = 'h' then FMouseBits := FMouseBits or 1
                   else FMouseBits := FMouseBits and not 1;
                1000: if final = 'h' then FMouseBits := FMouseBits or 2
                      else FMouseBits := FMouseBits and not 2;
                1002: if final = 'h' then FMouseBits := FMouseBits or 4
                      else FMouseBits := FMouseBits and not 4;
                1003: if final = 'h' then FMouseBits := FMouseBits or 8
                      else FMouseBits := FMouseBits and not 8;
                1005: if final = 'h' then FMouseProto := mpUtf8
                      else FMouseProto := mpX10;
                1006: if final = 'h' then FMouseProto := mpSGR
                      else FMouseProto := mpX10;
                1015: if final = 'h' then FMouseProto := mpUrxvt
                      else FMouseProto := mpX10;
                1016: if final = 'h' then FMouseProto := mpPixel
                      else FMouseProto := mpX10;
                47, 1047, 1049:
                begin
                  if final = 'h' then
                  begin
                    if not FUsingAlt then
                    begin
                       CopyGrid(FGrid, FAltGrid);
                      FUsingAlt := True;
                      FViewTop := 0;   // a scrolled-back view would paint history over the app
                      if n = 1049 then
                      begin
                        // xterm: ?1049h saves the cursor AND the graphic
                        // rendition into its own slot (independent of DECSC)
                        FAltSaveX := CursorX;
                        FAltSaveY := CursorY;
                        FAltSaveAttr := Attr;
                        FAltSaveFgRGB := AttrFgRGB;
                        FAltSaveBgRGB := AttrBgRGB;
                        EraseRange(0, 0, Width - 1, Height - 1, Attr);
                      end;
                      CursorX := 0;
                      CursorY := 0;
                    end;
                  end
                  else
                  begin
                    if FUsingAlt then
                    begin
                      FUsingAlt := False;
                      FViewTop := 0;
                      if FAltGrid <> nil then
                        FGrid := Copy(FAltGrid, 0, Height);
                      FAltGrid := nil;
                      if n = 1049 then
                      begin
                        // ?1049l restores cursor AND graphic rendition. This is
                        // what a real terminal does, and why an app may exit the
                        // alt screen without an explicit SGR reset; restoring
                        // only the cursor left its last attributes (bold) stuck
                        // on every byte the shell printed afterwards.
                        CursorX := FAltSaveX;
                        CursorY := FAltSaveY;
                        ClampCursor;
                        Attr := FAltSaveAttr;
                        AttrFgRGB := FAltSaveFgRGB;
                        AttrBgRGB := FAltSaveBgRGB;
                      end;
                    end;
                  end;
                  Dirty := True;
                end;
            end;
          end;
        end;
      end;
  end;
  Dirty := True;
end;

// The DECRQM answer for one mode: 0 not recognized, 1 set, 2 reset. This
// terminal has no permanently-set or permanently-reset mode, so 3 and 4 are
// never used.
//
// "Recognized" means this screen model really implements the mode. Reporting
// a mode it does not implement is worse than reporting 0: the program stops
// working around a missing feature and starts relying on one.
function TScreen.ModeState(APrivate: boolean; AMode: integer): integer;

  function OnOff(AValue: boolean): integer;
  begin
    if AValue then Result := 1 else Result := 2;
  end;

begin
  Result := 0;
  if APrivate then
    case AMode of
      1: Result := OnOff(FAppCursor);
      7: Result := OnOff(FAutoWrap);
      9: Result := OnOff((FMouseBits and 1) <> 0);
      25: Result := OnOff(CursorVisible);
      // 47, 1047 and 1049 differ in xterm only in what they do to the cursor
      // and to the screen on the way in and out; there is one alternate
      // buffer and this reports whether the terminal is on it.
      47, 1047, 1049: Result := OnOff(FUsingAlt);
      1000: Result := OnOff((FMouseBits and 2) <> 0);
      1002: Result := OnOff((FMouseBits and 4) <> 0);
      1003: Result := OnOff((FMouseBits and 8) <> 0);
      1005: Result := OnOff(FMouseProto = mpUtf8);
      1006: Result := OnOff(FMouseProto = mpSGR);
      1015: Result := OnOff(FMouseProto = mpUrxvt);
      1016: Result := OnOff(FMouseProto = mpPixel);
      2004: Result := OnOff(FBracketedPaste);
    end
  else
    case AMode of
      // IRM and LNM are not implemented yet, and both are answered
      // "recognized, reset" because that is what the terminal's observable
      // behaviour already is: writes replace rather than insert, and a line
      // feed does not also return the carriage. This stops being a fixed
      // answer and starts being tracked state when the modes land.
      4, 20: Result := 2;
    end;
end;

// A CSI introduced by '<', '=' or '>'. These are private sequences and stay
// deliberately unhandled -- acting on "CSI > 4 ; 2 m" as an SGR would set
// underline, and on the kitty "CSI > 1 u" would set nothing useful. The one
// exception is a QUERY: a program that asks and is not answered blocks until
// its own timeout, which is indistinguishable from a hung terminal.
procedure TScreen.DoPrivateCSI(final: AnsiChar);
begin
  // Secondary Device Attributes: "CSI > Ps c", Ps = 0 or omitted.
  if (final = 'c') and (FPrivIntro = '>') and (GetParam(0, 0) = 0) then
    QueueReply(REPLY_DA2);
  // "CSI = Ps c" (Tertiary DA) would have to answer DECRPTUI with a unit ID
  // this terminal does not have, so it is left unanswered on purpose.
  Dirty := True;
end;

procedure TScreen.DispatchEsc(c: AnsiChar);
var
  i: integer;
begin
  case c of
    '[':
      begin
        FPState := psCsi;
        FPCount := 0;
        for i := 0 to High(FPParams) do
        begin
          FPParams[i] := -1;
          FPColon[i] := False;
        end;
        FPPriv := False;
        FPrivOther := False;
        FPrivIntro := #0;
        FInterm := #0;
        Exit;
      end;
    ']':
      begin
        // Keep OSC payloads out of the visible grid until BEL or ST ends them.
        FOscBuf := '';
        FOscLen := 0;
        FOscOverflow := False;
        FPState := psOsc;
        Exit;
      end;
    '(', ')', '*', '+':
      begin
        FPState := psCharset;
        Exit;
      end;
    'P', 'X', '^', '_':
      begin
        // DCS/SOS/PM/APC: consume the whole string until ST (ESC \) or BEL,
        // so no payload leaks onto the grid. Only a real DCS is CAPTURED --
        // XTGETTCAP arrives as "ESC P + q ... ST" and is a query the terminal
        // owes an answer to. SOS, PM and APC carry nothing this terminal
        // implements and are still read past without being kept.
        FDcsBuf := '';
        FDcsLen := 0;
        FDcsOverflow := False;
        FDcsCapture := c = 'P';
        FPState := psDcs;
        Exit;
      end;
    '7':
      begin
        // DECSC saves cursor position AND graphic rendition (SGR)
        FSaveX := CursorX;
        FSaveY := CursorY;
        FSaveAttr := Attr;
        FSaveFgRGB := AttrFgRGB;
        FSaveBgRGB := AttrBgRGB;
        FPState := psGround;
      end;
    '8':
      begin
        // DECRC restores both, so attributes do not leak past a restore
        CursorX := FSaveX;
        CursorY := FSaveY;
        ClampCursor;
        Attr := FSaveAttr;
        AttrFgRGB := FSaveFgRGB;
        AttrBgRGB := FSaveBgRGB;
        FPState := psGround;
      end;
    'D': LineFeed;
    'M':
      begin
        if CursorY = ScrollTop then
          ScrollDown(1)
        else if CursorY > 0 then
          Dec(CursorY);
        FPendingWrap := False;
      end;
    'E':
      begin
        CursorX := 0;
        LineFeed;
      end;
    '=': FAppKeypad := True;    // DECKPAM
    '>': FAppKeypad := False;   // DECKPNM
    'c': ResetHard;   // RIS: `reset` expects the screen cleared, not just homed
  else
    ; // =, >, etc: ignore
  end;
  if FPState <> psCsi then
    FPState := psGround;
end;

// A saved cursor can outlive a Resize, so every restore path must clamp:
// an out-of-range CursorY silently swallows all further output (writes land
// outside the grid), which looks like the pane going dead.
procedure TScreen.ClampCursor;
begin
  if CursorX < 0 then CursorX := 0;
  if CursorY < 0 then CursorY := 0;
  if CursorX > Width - 1 then CursorX := Width - 1;
  if CursorY > Height - 1 then CursorY := Height - 1;
end;

procedure TScreen.ResetSoft;
begin
  Attr := A_FGDEF or A_BGDEF;
  AttrFgRGB := 0;
  AttrBgRGB := 0;
  CursorX := 0;
  CursorY := 0;
  ScrollTop := 0;
  ScrollBot := Height - 1;
  CursorVisible := True;
  CursorStyle := 0;
  FAutoWrap := True;
  FAppCursor := False;
  FAppKeypad := False;
  FBracketedPaste := False;
  FMouseBits := 0;
  FMouseProto := mpX10;
  FPendingWrap := False;
end;

procedure TScreen.ResetHard;
var
  y: integer;
begin
  FMouseBits := 0;
  FMouseProto := mpX10;
  // back to the normal screen buffer (discard the alternate one)
  FUsingAlt := False;
  FAltGrid := nil;
  ResetSoft;
  // RIS erases the screen -- this is what `reset` expects and what was
  // missing: the cursor homed but the old contents stayed on screen
  for y := 0 to Height - 1 do
    BlankRow(y, Attr);
  // ...and drops the scrollback
  FSBCount := 0;
  FSBHead := 0;
  FViewTop := 0;
  // parser and saved-state slots back to a clean slate
  FPState := psGround;
  FPCount := 0;
  FPPriv := False;
  FPrivOther := False;
  FPrivIntro := #0;
  FInterm := #0;
  FUtfLen := 0;
  FUtfNeed := 0;
  FOscBuf := '';
  FOscLen := 0;
  FOscOverflow := False;
  FDcsBuf := '';
  FDcsLen := 0;
  FDcsOverflow := False;
  FDcsCapture := False;
  FOsc52Queue := nil;
  { RIS is a full reset: an answer queued for a query the program made before
    it reset the terminal is no longer owed to anyone. }
  FReplyQueue := nil;
  FReplyLoanToken := TScreenReplyToken(0);
  FSaveX := 0;
  FSaveY := 0;
  FSaveAttr := A_FGDEF or A_BGDEF;
  FSaveFgRGB := 0;
  FSaveBgRGB := 0;
  FAltSaveX := 0;
  FAltSaveY := 0;
  FAltSaveAttr := A_FGDEF or A_BGDEF;
  FAltSaveFgRGB := 0;
  FAltSaveBgRGB := 0;
  Dirty := True;
end;

procedure TScreen.WriteBytes(const Buf; Count: integer);
var
  P: ^byte;
  b: byte;
  i, NewCap: integer;
begin
  P := @Buf;
  for i := 0 to Count - 1 do
  begin
    b := P^;
    Inc(P);
    case FPState of
      psGround:
        begin
          case b of
            27: FPState := psEsc;
            13:
              begin
                CursorX := 0;
                FPendingWrap := False;
              end;
            10, 11, 12: LineFeed;
            8:
              begin
                if CursorX > 0 then
                  Dec(CursorX);
                FPendingWrap := False;
              end;
            9:
              begin
                CursorX := ((CursorX div 8) + 1) * 8;
                if CursorX >= Width then
                  CursorX := Width - 1;
                FPendingWrap := False;
              end;
            7: ; // bell
            14, 15: ; // charset shift
          else
            if b >= 32 then
              PutCharByte(b);
          end;
        end;
      psEsc:
        DispatchEsc(AnsiChar(b));
      psCsi:
        begin
          if (b >= $30) and (b <= $39) then
          begin
            if FPCount > 15 then FPCount := 15;
            if FPParams[FPCount] = -1 then
              FPParams[FPCount] := b - $30
            else if FPParams[FPCount] >= (MaxInt div 10) then
              FPParams[FPCount] := MaxInt
            else
              FPParams[FPCount] := FPParams[FPCount] * 10 + (b - $30);
          end
          else if (b = Ord(';')) or (b = Ord(':')) then
          begin
            // ':' separates subparameters (38:5:196m from modern emitters);
            // treating it as ';' avoids printing the rest as text, but the
            // distinction is remembered for the truecolor case below
            Inc(FPCount);
            if FPCount > 15 then FPCount := 15;
            FPColon[FPCount] := (b = Ord(':'));
          end
          else if b = Ord('?') then
            // '?' = DEC private: DECSET/DECRST (?1049h, ?25h...) ARE handled
            FPPriv := True
          else if (b >= $3C) and (b <= $3E) then
          begin
            // '<' '=' '>' introduce OTHER private CSIs -- modifyOtherKeys
            // "ESC[>4;2m", the kitty keyboard "ESC[>1u"/"ESC[<u" Claude emits.
            // Consume them so the params/final byte do NOT leak as "4m"/"u",
            // but do NOT act on them (applying "m" would wrongly set underline).
            // The intro byte itself is remembered because a few of these are
            // QUERIES the terminal owes an answer to -- "CSI > c" is Secondary
            // Device Attributes -- and those must be told apart from the rest,
            // which stay ignored.
            FPrivOther := True;
            FPrivIntro := AnsiChar(b);
          end
          else if (b >= $20) and (b <= $2F) then
          begin
            FInterm := AnsiChar(b);   // intermediate: ' ' of DECSCUSR etc.
          end
          else if (b >= $40) and (b <= $7E) then
          begin
            if FPrivOther then
              DoPrivateCSI(AnsiChar(b))   // answers queries, ignores the rest
            else
              DoCSI(AnsiChar(b));
            FPState := psGround;
            FPPriv := False;
            FPrivOther := False;
            FPrivIntro := #0;
            FInterm := #0;
          end
          else
          begin
            FPState := psGround;
            FPPriv := False;
            FPrivOther := False;
            FPrivIntro := #0;
            FInterm := #0;
          end;
        end;
      psOsc:
        begin
          if b = 7 then
            FinishOsc            // BEL ends OSC
          else if b = 27 then
            FPState := psOscEsc
          else
          begin
            if FOscLen < MAX_OSC_BYTES then
            begin
              if FOscLen = Length(FOscBuf) then
              begin
                NewCap := Length(FOscBuf);
                if NewCap = 0 then NewCap := 1024
                else NewCap := NewCap * 2;
                if NewCap > MAX_OSC_BYTES then NewCap := MAX_OSC_BYTES;
                SetLength(FOscBuf, NewCap);
              end;
              Inc(FOscLen);
              FOscBuf[FOscLen] := AnsiChar(b);
            end
            else
              FOscOverflow := True;
          end;
        end;
      psOscEsc:
        begin
          if b = Ord('\') then
            FinishOsc
          else
          begin
            FOscBuf := '';
            FOscLen := 0;
            FOscOverflow := False;
            FPState := psGround;
          end;
        end;
      psCharset:
        FPState := psGround;
      psDcs:
        begin
          if b = 7 then
            FinishDcs               // BEL ends the string
          else if b = 27 then
            FPState := psDcsEsc     // maybe ST (ESC \)
          else if FDcsCapture then
          begin
            if FDcsLen < MAX_DCS_BYTES then
            begin
              if FDcsLen = Length(FDcsBuf) then
              begin
                NewCap := Length(FDcsBuf);
                if NewCap = 0 then NewCap := 256
                else NewCap := NewCap * 2;
                if NewCap > MAX_DCS_BYTES then NewCap := MAX_DCS_BYTES;
                SetLength(FDcsBuf, NewCap);
              end;
              Inc(FDcsLen);
              FDcsBuf[FDcsLen] := AnsiChar(b);
            end
            else
              FDcsOverflow := True;
          end;
          // an uncaptured string's bytes are read past without being kept
        end;
      psDcsEsc:
        begin
          // ESC \ = ST, the proper end. A bare ESC is not legal inside a
          // control string; the string ends either way, and a captured one
          // is only acted on when it ended properly.
          if b <> Ord('\') then
          begin
            FDcsBuf := '';
            FDcsLen := 0;
            FDcsOverflow := False;
            FDcsCapture := False;
            FPState := psGround;
          end
          else
            FinishDcs;
        end;
    end;
  end;
  Dirty := True;
end;

end.
