program console_replay_probe;

// Replays bytes captured from SuperTerm (SUPERTERM_TEE) from a program that
// does nothing else, to tell "the bytes are wrong" from "the process is
// doing something else wrong".
//
//   console_replay_probe prelude.bin small.bin big.bin nudge.bin small2.bin [readinput]
//
// Writes prelude+small at start, nudge+big when the window settles at more
// than 60 rows, nudge+small2 when it settles at fewer. With 'readinput' it
// also reads its console input the way SuperTerm's keyboard driver did before
// CharRecordPending: WaitForSingleObject on the input handle, then ReadFile.
// That variant reproduced the "repaints only when clicked" defect exactly,
// because ReadFile blocks on the window-size record a resize queues.
//
// Cut the .bin files out of a tee capture with the offsets in its .idx file,
// for example with tail -c +OFFSET+1 | head -c LENGTH.
//
// Build from the repository root:
//   fpc -Mobjfpc -Sh -FUbuild/units/win-release -FEbin test/windows/console_replay_probe.pas

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, Windows;

const
  ENABLE_VIRTUAL_TERMINAL_PROCESSING_ = $0004;
  DISABLE_NEWLINE_AUTO_RETURN_        = $0008;
  ENABLE_VIRTUAL_TERMINAL_INPUT_      = $0200;
  SETTLE_MS = 120;
  RUN_MS    = 40000;

var
  HOut, HIn: THandle;
  SavedOut, SavedIn: DWORD;
  Prelude, Small, Big, Nudge, Small2: AnsiString;
  ReadInput: boolean;

function LoadFile(const FN: string): AnsiString;
var
  S: TFileStream;
begin
  Result := '';
  if FN = '' then
    Exit;
  S := TFileStream.Create(FN, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, S.Size);
    if S.Size > 0 then
      S.ReadBuffer(Result[1], S.Size);
  finally
    S.Free;
  end;
end;

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

var
  Cols, Rows, SeenCols, SeenRows, I: integer;
  StillSince, Started: QWord;
  Moving: boolean;
  Buf: array[0..255] of byte;
  Got: DWORD;

begin
  Prelude := LoadFile(ParamStr(1));
  Small := LoadFile(ParamStr(2));
  Big := LoadFile(ParamStr(3));
  Nudge := LoadFile(ParamStr(4));
  Small2 := LoadFile(ParamStr(5));
  ReadInput := False;
  for I := 6 to ParamCount do
    if ParamStr(I) = 'readinput' then
      ReadInput := True;

  HOut := GetStdHandle(STD_OUTPUT_HANDLE);
  HIn := GetStdHandle(STD_INPUT_HANDLE);
  SavedOut := 0; SavedIn := 0;
  if GetConsoleMode(HOut, SavedOut) then
    SetConsoleMode(HOut, SavedOut or ENABLE_VIRTUAL_TERMINAL_PROCESSING_
      or DISABLE_NEWLINE_AUTO_RETURN_);
  SetConsoleOutputCP(CP_UTF8);
  if GetConsoleMode(HIn, SavedIn) then
    SetConsoleMode(HIn,
      (SavedIn or ENABLE_VIRTUAL_TERMINAL_INPUT_ or ENABLE_EXTENDED_FLAGS)
      and not (ENABLE_LINE_INPUT or ENABLE_ECHO_INPUT or ENABLE_PROCESSED_INPUT
               or ENABLE_QUICK_EDIT_MODE or ENABLE_MOUSE_INPUT
               or ENABLE_WINDOW_INPUT));
  Emit(Prelude);
  Emit(Small);

  SeenCols := 0; SeenRows := 0; Moving := False; StillSince := 0;
  if WindowSize(Cols, Rows) then
  begin
    SeenCols := Cols; SeenRows := Rows;
  end;
  Started := GetTickCount64;
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
        Emit(Nudge);
        if Rows > 60 then
          Emit(Big)
        else
          Emit(Small2);
      end;
    end;
    if ReadInput then
    begin
      // The pre-fix input path. ReadFile only returns on characters, so a
      // window-size or focus record parks the program here until a key.
      if WaitForSingleObject(HIn, 10) = WAIT_OBJECT_0 then
      begin
        Got := 0;
        if ReadFile(HIn, Buf[0], SizeOf(Buf), Got, nil) then
          Emit(#27'[' + IntToStr(Rows) + ';1H' + 'READ ' + IntToStr(Got) +
            ' bytes at ' + IntToStr(GetTickCount64 - Started) + ' ms   ');
      end;
    end
    else
      Sleep(10);
  end;

  Emit(#27'[?1049l'#27'[0m'#27'[?25h');
  if SavedIn <> 0 then
    SetConsoleMode(HIn, SavedIn);
  if SavedOut <> 0 then
    SetConsoleMode(HOut, SavedOut);
end.
