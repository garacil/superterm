program console_resize_probe;

// Minimal reproducer for "the console window was resized but what we paint
// does not show until the host receives input".
//
// It does only this: watch the console window geometry, and when it has held
// still for 120 ms, erase the screen and paint every cell of the new size
// with a serial number at the start of each row. No Free Vision, no ConPTY, no
// keyboard driver, and it never reads input -- so whatever it shows is the
// host's behaviour, not SuperTerm's.
//
// Flags reproduce pieces of SuperTerm's console setup, to bisect:
//   alt    enter the alternate screen buffer (ESC[?1049h)
//   vtin   put the input handle in VT input mode and clear ENABLE_WINDOW_INPUT
//   utf8   switch the output code page to UTF-8
// Run with none of them first; add them one at a time.
//
// Build from the repository root:
//   fpc -Mobjfpc -Sh -FUbuild/units/win-release -FEbin test/windows/console_resize_probe.pas

{$mode objfpc}{$H+}

uses
  SysUtils, Windows;

const
  ENABLE_VIRTUAL_TERMINAL_PROCESSING_ = $0004;
  DISABLE_NEWLINE_AUTO_RETURN_        = $0008;
  ENABLE_VIRTUAL_TERMINAL_INPUT_      = $0200;
  SETTLE_MS = 120;
  RUN_MS    = 40000;

var
  HOut, HIn: THandle;
  SavedOut, SavedIn, SavedCP: DWORD;
  UseAlt, UseVtIn, UseUtf8: boolean;

procedure Emit(const S: AnsiString);
var
  Written: DWORD;
begin
  if S = '' then
    Exit;
  Written := 0;
  WriteFile(HOut, S[1], Length(S), Written, nil);
end;

function WindowSize(out ACols, ARows: integer): boolean;
var
  Info: TConsoleScreenBufferInfo;
begin
  Info := Default(TConsoleScreenBufferInfo);
  Result := GetConsoleScreenBufferInfo(HOut, Info);
  if not Result then
    Exit;
  ACols := Info.srWindow.Right - Info.srWindow.Left + 1;
  ARows := Info.srWindow.Bottom - Info.srWindow.Top + 1;
  Result := (ACols > 0) and (ARows > 0);
end;

// One full-screen paint: every cell written, addressed absolutely, the shape
// of frame SuperTerm emits after a resize.
procedure PaintAll(ACols, ARows, ASerial: integer);
var
  Frame, Row: AnsiString;
  Y, X: integer;
begin
  Frame := #27'[H'#27'[2J';
  for Y := 1 to ARows do
  begin
    Row := '';
    for X := 1 to ACols do
      if ((X + Y) mod 2) = 0 then
        Row := Row + '#'
      else
        Row := Row + '.';
    Row := Format('%d:%dx%d ', [ASerial, ACols, ARows]) + Row;
    SetLength(Row, ACols);
    Frame := Frame + #27'[' + IntToStr(Y) + ';1H' + Row;
  end;
  Emit(Frame);
end;

var
  Cols, Rows, SeenCols, SeenRows, Serial: integer;
  StillSince, Started: QWord;
  Moving: boolean;
  I: integer;

begin
  UseAlt := False; UseVtIn := False; UseUtf8 := False;
  for I := 1 to ParamCount do
  begin
    if ParamStr(I) = 'alt' then UseAlt := True;
    if ParamStr(I) = 'vtin' then UseVtIn := True;
    if ParamStr(I) = 'utf8' then UseUtf8 := True;
  end;

  HOut := GetStdHandle(STD_OUTPUT_HANDLE);
  HIn := GetStdHandle(STD_INPUT_HANDLE);
  SavedOut := 0; SavedIn := 0;
  if GetConsoleMode(HOut, SavedOut) then
    SetConsoleMode(HOut, SavedOut or ENABLE_VIRTUAL_TERMINAL_PROCESSING_
      or DISABLE_NEWLINE_AUTO_RETURN_);
  SavedCP := GetConsoleOutputCP;
  if UseUtf8 then
    SetConsoleOutputCP(CP_UTF8);
  if UseVtIn and GetConsoleMode(HIn, SavedIn) then
    SetConsoleMode(HIn,
      (SavedIn or ENABLE_VIRTUAL_TERMINAL_INPUT_ or ENABLE_EXTENDED_FLAGS)
      and not (ENABLE_LINE_INPUT or ENABLE_ECHO_INPUT or ENABLE_PROCESSED_INPUT
               or ENABLE_QUICK_EDIT_MODE or ENABLE_MOUSE_INPUT
               or ENABLE_WINDOW_INPUT));
  if UseAlt then
    Emit(#27'[?1049h');

  SeenCols := 0; SeenRows := 0; Serial := 0;
  Moving := False; StillSince := 0;
  Started := GetTickCount64;
  if WindowSize(Cols, Rows) then
  begin
    SeenCols := Cols; SeenRows := Rows;
    Inc(Serial);
    PaintAll(Cols, Rows, Serial);
  end;

  // Poll only. Nothing here ever reads the keyboard, so if the picture changes
  // when a key or the mouse is used, that change came from the host.
  while GetTickCount64 - Started < RUN_MS do
  begin
    if WindowSize(Cols, Rows) then
    begin
      if (Cols <> SeenCols) or (Rows <> SeenRows) then
      begin
        SeenCols := Cols; SeenRows := Rows;
        StillSince := GetTickCount64;
        Moving := True;
      end
      else if Moving and (GetTickCount64 - StillSince >= SETTLE_MS) then
      begin
        Moving := False;
        Inc(Serial);
        PaintAll(Cols, Rows, Serial);
      end;
    end;
    Sleep(10);
  end;

  if UseAlt then
    Emit(#27'[?1049l');
  Emit(#27'[0m');
  if SavedCP <> 0 then
    SetConsoleOutputCP(SavedCP);
  if UseVtIn and (SavedIn <> 0) then
    SetConsoleMode(HIn, SavedIn);
  if SavedOut <> 0 then
    SetConsoleMode(HOut, SavedOut);
  WriteLn;
  WriteLn('probe done, painted ', Serial, ' frames');
end.
