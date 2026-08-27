(*
  Author: German Luis Aracil Boned
  Project: superterm - terminal with autologin, splits and sessions
  Unit: st_session - save/restore session (layout + command + cwd per pane)
*)

unit st_session;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, IniFiles, BaseUnix, st_layout, st_pty;

type
  TPaneInfo = record
    Cmd: string;
    Cwd: string;
    Term: string;   // terminal name from /etc/superterm ('' = ad-hoc)
    Title: string;  // window's own title ('' = derived from cwd/cmd)
    Args: TStringArray; // observed arguments, for safe restoration
    // geometry/state of the pane window (BW<=0 = no data, tiling):
    // windows moved or resized by hand with Ctrl-F5 must return
    // exactly where they were when the session is restored
    BX, BY, BW, BH: integer;
    Minimized: boolean;
    IconSlot: integer; // stable minimized slot; -1 when restored/legacy
    Zoomed: boolean;
    FullScreen: boolean;
  end;

  TPaneArray = array of TPaneInfo;

procedure SaveSession(const FileName: string; Lay: TLayout;
  const Panes: array of TPaneInfo; ADeskW: integer = 0; ADeskH: integer = 0);
function LoadSession(const FileName: string; var Lay: TLayout;
  out Panes: TPaneArray; out ADeskW, ADeskH: integer): boolean;
function SaveLayoutString(Lay: TLayout): string;
function LoadLayoutString(const Nodes: string; out Lay: TLayout;
  AAllowEmpty: boolean = False): boolean;

implementation

procedure SerializeNode(N: TNode; SL: TStringList);
var
  T: string;
begin
  if N = nil then
    Exit;
  if not N.IsSplit then
    SL.Add('L')
  else
  begin
    if N.Dir = sdV then T := 'V' else T := 'H';
    SL.Add(T + ':' + IntToStr(Round(N.Ratio * 1000)));
    SerializeNode(N.A, SL);
    SerializeNode(N.B, SL);
  end;
end;

function ParseNodes(SL: TStringList; var Idx: integer): TNode;
var
  T: string;
  N: TNode;
  RA, RB: TNode;
begin
  Result := nil;
  if Idx >= SL.Count then
    Exit;
  T := Trim(SL[Idx]);
  Inc(Idx);
  if T = '' then
    Exit;
  if T = 'L' then
    Exit(TNode.CreateLeaf(0));
  if (T[1] = 'V') or (T[1] = 'H') then
  begin
    N := TNode.CreateSplit(sdV, nil, nil);
    if T[1] = 'H' then
      N.Dir := sdH;
    if Pos(':', T) > 0 then
      N.Ratio := StrToIntDef(Copy(T, Pos(':', T) + 1, MaxInt), 500) / 1000.0
    else
      N.Ratio := 0.5;
    if N.Ratio < 0.15 then N.Ratio := 0.15;
    if N.Ratio > 0.85 then N.Ratio := 0.85;
    RA := ParseNodes(SL, Idx);
    RB := ParseNodes(SL, Idx);
    if (RA = nil) or (RB = nil) then
    begin
      RA.Free;
      RB.Free;
      N.Free;
      Exit(nil);
    end;
    N.A := RA;
    N.B := RB;
    RA.Parent := N;
    RB.Parent := N;
    Exit(N);
  end;
  Result := nil;
end;

procedure SaveSession(const FileName: string; Lay: TLayout;
  const Panes: array of TPaneInfo; ADeskW: integer; ADeskH: integer);
var
  Ini: TIniFile;
  SL: TStringList;
  i, j: integer;
  TempName, Sec: string;
begin
  TempName := FileName + '.tmp.' + IntToStr(fpGetPid);
  if FileExists(TempName) then
    DeleteFile(TempName);
  Ini := TIniFile.Create(TempName);
  SL := TStringList.Create;
  try
    SerializeNode(Lay.Root, SL);
    SL.Delimiter := ';';
    SL.StrictDelimiter := True;
    Ini.WriteString('layout', 'nodes', SL.DelimitedText);
    Ini.WriteInteger('layout', 'count', Length(Panes));
    Ini.WriteInteger('layout', 'focused', Lay.Focused);
    // One canonical desktop. A later physical terminal is merely a viewport.
    if (ADeskW > 0) and (ADeskH > 0) then
    begin
      Ini.WriteInteger('layout', 'deskw', ADeskW);
      Ini.WriteInteger('layout', 'deskh', ADeskH);
    end;
    for i := 0 to High(Panes) do
    begin
      Sec := 'pane' + IntToStr(i);
      Ini.WriteString(Sec, 'cmd', Panes[i].Cmd);
      Ini.WriteString(Sec, 'cwd', Panes[i].Cwd);
      Ini.WriteString(Sec, 'term', Panes[i].Term);
      if Panes[i].Title <> '' then
        Ini.WriteString(Sec, 'title', Panes[i].Title);
      if (Panes[i].BW > 0) and (Panes[i].BH > 0) then
      begin
        Ini.WriteInteger(Sec, 'bx', Panes[i].BX);
        Ini.WriteInteger(Sec, 'by', Panes[i].BY);
        Ini.WriteInteger(Sec, 'bw', Panes[i].BW);
        Ini.WriteInteger(Sec, 'bh', Panes[i].BH);
      end;
      if Panes[i].Minimized then
      begin
        Ini.WriteInteger(Sec, 'min', 1);
        if (Panes[i].IconSlot >= 0) and
           (Panes[i].IconSlot < MAX_PANES) then
          Ini.WriteInteger(Sec, 'icon_slot', Panes[i].IconSlot);
      end;
      if Panes[i].Zoomed then
        Ini.WriteInteger(Sec, 'zoom', 1);
      if Panes[i].FullScreen then
        Ini.WriteInteger(Sec, 'fullscreen', 1);
      Ini.WriteInteger(Sec, 'argc', Length(Panes[i].Args));
      for j := 0 to High(Panes[i].Args) do
        Ini.WriteString(Sec, 'arg' + IntToStr(j), Panes[i].Args[j]);
    end;
    Ini.UpdateFile;
    // Session data may contain commands, paths, and terminal identities.
    FpChmod(PAnsiChar(TempName), &600);
  finally
    SL.Free;
    Ini.Free;
  end;
  if not RenameFile(TempName, FileName) then
    DeleteFile(TempName);
end;

function LoadSession(const FileName: string; var Lay: TLayout;
  out Panes: TPaneArray; out ADeskW, ADeskH: integer): boolean;
var
  Ini: TIniFile;
  SL: TStringList;
  Idx, i, j, n, ArgCount: integer;
  Root: TNode;
  Sec: string;
begin
  Result := False;
  if Lay <> nil then
    Lay.Free;
  Lay := nil;
  Panes := nil;
  ADeskW := 0;
  ADeskH := 0;
  if not FileExists(FileName) then
    Exit;
  Ini := TIniFile.Create(FileName);
  SL := TStringList.Create;
  try
    n := Ini.ReadInteger('layout', 'count', 0);
    if (n < 1) or (n > MAX_PANES) then
      Exit;
    SL.Delimiter := ';';
    SL.StrictDelimiter := True;
    SL.DelimitedText := Ini.ReadString('layout', 'nodes', '');
    if SL.Count = 0 then
      Exit;
    Idx := 0;
    Root := ParseNodes(SL, Idx);
    if Root = nil then
      Exit;
    if Idx <> SL.Count then
    begin
      Root.Free;
      Exit;
    end;
    Lay := TLayout.Create;
    Lay.Root.Free;
    Lay.Root := Root;
    Lay.Reindex;
    if Lay.PaneCount <> n then
    begin
      Lay.Free;
      Lay := nil;
      Exit;
    end;
    Lay.Focused := Ini.ReadInteger('layout', 'focused', 0);
    if (Lay.Focused < 0) or (Lay.Focused >= n) then
      Lay.Focused := 0;
    ADeskW := Ini.ReadInteger('layout', 'deskw', 0);
    ADeskH := Ini.ReadInteger('layout', 'deskh', 0);
    SetLength(Panes, n);
    for i := 0 to n - 1 do
    begin
      Sec := 'pane' + IntToStr(i);
      Panes[i].Cmd := Ini.ReadString(Sec, 'cmd', '');
      Panes[i].Cwd := Ini.ReadString(Sec, 'cwd', '');
      Panes[i].Term := Ini.ReadString(Sec, 'term', '');
      Panes[i].Title := Ini.ReadString(Sec, 'title', '');
      Panes[i].BX := Ini.ReadInteger(Sec, 'bx', 0);
      Panes[i].BY := Ini.ReadInteger(Sec, 'by', 0);
      Panes[i].BW := Ini.ReadInteger(Sec, 'bw', 0);
      Panes[i].BH := Ini.ReadInteger(Sec, 'bh', 0);
      Panes[i].Minimized := Ini.ReadInteger(Sec, 'min', 0) <> 0;
      Panes[i].IconSlot := Ini.ReadInteger(Sec, 'icon_slot', -1);
      if (not Panes[i].Minimized) or (Panes[i].IconSlot < 0) or
         (Panes[i].IconSlot >= MAX_PANES) then
        Panes[i].IconSlot := -1;
      Panes[i].Zoomed := Ini.ReadInteger(Sec, 'zoom', 0) <> 0;
      Panes[i].FullScreen := Ini.ReadInteger(Sec, 'fullscreen', 0) <> 0;
      ArgCount := Ini.ReadInteger(Sec, 'argc', 0);
      if ArgCount < 0 then ArgCount := 0;
      if ArgCount > 128 then ArgCount := 128;
      SetLength(Panes[i].Args, ArgCount);
      for j := 0 to ArgCount - 1 do
        Panes[i].Args[j] := Ini.ReadString(Sec, 'arg' + IntToStr(j), '');
    end;
    Result := True;
  finally
    SL.Free;
    Ini.Free;
  end;
end;

function LoadLayoutString(const Nodes: string; out Lay: TLayout;
  AAllowEmpty: boolean): boolean;
var
  SL: TStringList;
  Idx: integer;
  Root: TNode;
begin
  Result := False;
  Lay := nil;
  // An empty node string is the canonical representation of an empty
  // desktop.  It is not a malformed split tree: closing the last pane leaves
  // the session alive so that any attached client can create the first pane
  // again.  Callers that require at least one pane (profiles and saved startup
  // layouts) still validate PaneCount themselves.
  if (Nodes = '') and AAllowEmpty then
  begin
    Lay := TLayout.Create;
    FreeAndNil(Lay.Root);
    Lay.Focused := -1;
    Lay.LastInsertedIndex := -1;
    Exit(True);
  end;
  SL := TStringList.Create;
  try
    SL.Delimiter := ';';
    SL.StrictDelimiter := True;
    SL.DelimitedText := Nodes;
    if SL.Count = 0 then
      Exit;
    Idx := 0;
    Root := ParseNodes(SL, Idx);
    if Root = nil then
      Exit;
    if Idx <> SL.Count then
    begin
      Root.Free;
      Exit;
    end;
    Lay := TLayout.Create;
    Lay.Root.Free;
    Lay.Root := Root;
    Lay.Reindex;
    if (Lay.PaneCount < 1) or (Lay.PaneCount > MAX_PANES) then
    begin
      Lay.Free;
      Lay := nil;
      Exit;
    end;
    Result := True;
  finally
    SL.Free;
  end;
end;

function SaveLayoutString(Lay: TLayout): string;
var
  SL: TStringList;
begin
  Result := '';
  if (Lay = nil) or (Lay.Root = nil) then
    Exit;
  SL := TStringList.Create;
  try
    SerializeNode(Lay.Root, SL);
    SL.Delimiter := ';';
    SL.StrictDelimiter := True;
    Result := SL.DelimitedText;
  finally
    SL.Free;
  end;
end;

end.
