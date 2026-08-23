(*
  Author: German Luis Aracil Boned
  Project: superterm - terminal with autologin, splits and sessions
  Unit: st_profiles - profiles: named collections of windows, each
  window with its pane layout referencing window classes.
  They absorb the old [template.*] templates (flattening their
  "session" level: a multi-session template becomes several profiles).
*)

unit st_profiles;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, IniFiles, BaseUnix, st_config, st_wclass, st_templates;

type
  TProfilePaneSpec = record
    Name: string;
    Enabled: boolean;
    WClass: string;         // window class reference ('' = ad-hoc)
    Title: string;          // window's own title ('' = uses class/cwd)
    Cmd: string;            // per-pane overrides (override the class)
    Cwd: string;
    Connect: string;        // free ad-hoc connection (wizard panes)
    PostConnect: string;
    ScrollBack: integer;
    // exact geometry of the pane window (BW<=0 = no data, gets tiled):
    // manual position/size, minimized and maximized, to restore the
    // profile leaving EVERYTHING as it was when saved
    BX, BY, BW, BH: integer;
    Minimized: boolean;
    Zoomed: boolean;
  end;
  TProfilePaneArray = array of TProfilePaneSpec;

  TProfileWindowSpec = record
    Name: string;
    Enabled: boolean;
    Layout: string;         // same grammar as session.ini (L, V:500;L;L)
    FocusedPane: integer;
    DeskW, DeskH: integer;  // desktop size at save time (absolute bounds)
    Panes: TProfilePaneArray;
  end;
  TProfileWindowArray = array of TProfileWindowSpec;

  TProfileSpec = record
    Name: string;
    Enabled: boolean;
    Origin: TWClassOrigin;  // user = editable/persistable
    FocusedWindow: integer;
    Windows: TProfileWindowArray;
  end;
  TProfileArray = array of TProfileSpec;

// loads [profile.*] from the user file and the system file (user wins) and
// flattens the legacy [template.*] templates (including the SQLite backend)
function LoadProfiles(const UserFile, SystemFile: string;
  out Profiles: TProfileArray): boolean;

// writes the user-origin profiles to FileName atomically, preserving
// unrelated sections; absorbs the user's [template.*] on save
procedure SaveProfiles(const FileName: string; const AProfiles: TProfileArray);

// searches by name (case-insensitive); -1 if not found
function FindProfileByName(const A: TProfileArray; const AName: string): integer;

implementation

function FindProfileByName(const A: TProfileArray; const AName: string): integer;
var
  i: integer;
begin
  Result := -1;
  for i := 0 to High(A) do
    if SameText(A[i].Name, AName) then
      Exit(i);
end;

// TIniFile strips one pair of outer quotes when reading: if the value
// starts and ends with the same quote, it is wrapped in one more equal
// layer so that re-reading returns the exact value
function IniQuoteGuard(const S: string): string;
begin
  Result := S;
  if (Length(S) >= 2) and (S[1] in ['''', '"']) and
     (S[Length(S)] = S[1]) then
    Result := S[1] + S + S[1];
end;

function ParseBoolStr(const V: string; Def: boolean): boolean;
begin
  if V = '' then
    Result := Def
  else
    Result := SameText(V, '1') or SameText(V, 'true') or
      SameText(V, 'yes') or SameText(V, 'on');
end;

// splits a comma-separated list into clean non-empty names
procedure SplitNames(const S: string; SL: TStringList);
var
  i, Start: integer;
  Item: string;
begin
  SL.Clear;
  Start := 1;
  for i := 1 to Length(S) + 1 do
    if (i > Length(S)) or (S[i] = ',') then
    begin
      Item := Trim(Copy(S, Start, i - Start));
      if Item <> '' then
        SL.Add(Item);
      Start := i + 1;
    end;
end;

function IsProfileSection(const Sec: string): boolean;
begin
  // only the [profile.NAME] header, no more dots after the name
  Result := (LowerCase(Copy(Sec, 1, Length('profile.'))) = 'profile.') and
    (Pos('.', Copy(Sec, Length('profile.') + 1, MaxInt)) = 0);
end;

procedure LoadProfilesFromFile(const FileName: string; AOrigin: TWClassOrigin;
  var Profiles: TProfileArray);
var
  Ini: TIniFile;
  Sections, WinNames, PaneNames: TStringList;
  s, w, p: integer;
  Sec, WSec, PSec, PName: string;
  Prof: TProfileSpec;
  WSpec: TProfileWindowSpec;
  PSpec: TProfilePaneSpec;
begin
  if not FileExists(FileName) then
    Exit;
  Ini := TIniFile.Create(FileName);
  Sections := TStringList.Create;
  WinNames := TStringList.Create;
  PaneNames := TStringList.Create;
  try
    Ini.ReadSections(Sections);
    for s := 0 to Sections.Count - 1 do
    begin
      Sec := Sections[s];
      if not IsProfileSection(Sec) then
        continue;
      Prof := Default(TProfileSpec);
      Prof.Origin := AOrigin;
      Prof.Name := Ini.ReadString(Sec, 'name',
        Copy(Sec, Length('profile.') + 1, MaxInt));
      if Trim(Prof.Name) = '' then
        continue;
      // the first one wins within the combined load (user before system)
      if FindProfileByName(Profiles, Prof.Name) >= 0 then
        continue;
      Prof.Enabled := ParseBoolStr(Ini.ReadString(Sec, 'enabled', '1'), True);
      Prof.FocusedWindow := Ini.ReadInteger(Sec, 'focused_window', 0);
      SplitNames(Ini.ReadString(Sec, 'windows', ''), WinNames);
      for w := 0 to WinNames.Count - 1 do
      begin
        WSec := Sec + '.window.' + WinNames[w];
        WSpec := Default(TProfileWindowSpec);
        WSpec.Name := WinNames[w];
        WSpec.Enabled := ParseBoolStr(Ini.ReadString(WSec, 'enabled', '1'),
          True);
        WSpec.Layout := Ini.ReadString(WSec, 'layout', 'L');
        WSpec.FocusedPane := Ini.ReadInteger(WSec, 'focused_pane', 0);
        WSpec.DeskW := Ini.ReadInteger(WSec, 'deskw', 0);
        WSpec.DeskH := Ini.ReadInteger(WSec, 'deskh', 0);
        SplitNames(Ini.ReadString(WSec, 'panes', ''), PaneNames);
        for p := 0 to PaneNames.Count - 1 do
        begin
          PName := PaneNames[p];
          PSec := WSec + '.pane.' + PName;
          PSpec := Default(TProfilePaneSpec);
          PSpec.Name := PName;
          PSpec.Enabled := ParseBoolStr(Ini.ReadString(PSec, 'enabled', '1'),
            True);
          // canonical 'class'; 'terminal' accepted as a legacy synonym
          PSpec.WClass := Ini.ReadString(PSec, 'class',
            Ini.ReadString(PSec, 'terminal', ''));
          PSpec.Title := Ini.ReadString(PSec, 'title', '');
          PSpec.Cmd := Ini.ReadString(PSec, 'cmd', '');
          PSpec.Cwd := Ini.ReadString(PSec, 'cwd', '');
          PSpec.Connect := Ini.ReadString(PSec, 'connect', '');
          PSpec.PostConnect := Ini.ReadString(PSec, 'postconnect', '');
          // absent means "not stated", not "no history": the writer below
          // only stores the key when it is greater than zero, so a missing
          // key cannot mean a deliberate zero. Panes opened from a profile
          // were getting no scrollback ring at all, so nothing was ever kept
          // and the history was empty however much scrolled past.
          PSpec.ScrollBack := Ini.ReadInteger(PSec, 'scrollback',
            DEFAULT_SCROLLBACK);
          if PSpec.ScrollBack < 0 then
            PSpec.ScrollBack := 0;
          if PSpec.ScrollBack > MAX_SCROLLBACK then
            PSpec.ScrollBack := MAX_SCROLLBACK;
          // exact geometry of the pane window
          PSpec.BX := Ini.ReadInteger(PSec, 'bx', 0);
          PSpec.BY := Ini.ReadInteger(PSec, 'by', 0);
          PSpec.BW := Ini.ReadInteger(PSec, 'bw', 0);
          PSpec.BH := Ini.ReadInteger(PSec, 'bh', 0);
          PSpec.Minimized := Ini.ReadInteger(PSec, 'min', 0) <> 0;
          PSpec.Zoomed := Ini.ReadInteger(PSec, 'zoom', 0) <> 0;
          SetLength(WSpec.Panes, Length(WSpec.Panes) + 1);
          WSpec.Panes[High(WSpec.Panes)] := PSpec;
        end;
        SetLength(Prof.Windows, Length(Prof.Windows) + 1);
        Prof.Windows[High(Prof.Windows)] := WSpec;
      end;
      SetLength(Profiles, Length(Profiles) + 1);
      Profiles[High(Profiles)] := Prof;
    end;
  finally
    PaneNames.Free;
    WinNames.Free;
    Sections.Free;
    Ini.Free;
  end;
end;

// a legacy template is flattened: 1 session -> profile with its name;
// N sessions -> one 'template/session' profile for each one
procedure FlattenTemplates(const Templates: TTemplateArray;
  AOrigin: TWClassOrigin; var Profiles: TProfileArray);
var
  t, s, w, p: integer;
  Prof: TProfileSpec;
  WSpec: TProfileWindowSpec;
  PSpec: TProfilePaneSpec;
begin
  for t := 0 to High(Templates) do
  begin
    if not Templates[t].Enabled then
      continue;
    for s := 0 to High(Templates[t].Sessions) do
    begin
      if not Templates[t].Sessions[s].Enabled then
        continue;
      Prof := Default(TProfileSpec);
      Prof.Origin := AOrigin;
      if Length(Templates[t].Sessions) = 1 then
        Prof.Name := Templates[t].Name
      else
        Prof.Name := Templates[t].Name + '/' + Templates[t].Sessions[s].Name;
      if FindProfileByName(Profiles, Prof.Name) >= 0 then
        continue;   // an explicit [profile.*] beats the flattened template
      Prof.Enabled := True;
      Prof.FocusedWindow := Templates[t].Sessions[s].FocusedWindow;
      for w := 0 to High(Templates[t].Sessions[s].Windows) do
      begin
        WSpec := Default(TProfileWindowSpec);
        WSpec.Name := Templates[t].Sessions[s].Windows[w].Name;
        WSpec.Enabled := Templates[t].Sessions[s].Windows[w].Enabled;
        WSpec.Layout := Templates[t].Sessions[s].Windows[w].Layout;
        WSpec.FocusedPane := Templates[t].Sessions[s].Windows[w].FocusedPane;
        for p := 0 to High(Templates[t].Sessions[s].Windows[w].Panes) do
        begin
          PSpec := Default(TProfilePaneSpec);
          PSpec.Name := Templates[t].Sessions[s].Windows[w].Panes[p].Name;
          PSpec.Enabled := Templates[t].Sessions[s].Windows[w].Panes[p].Enabled;
          PSpec.WClass := Templates[t].Sessions[s].Windows[w].Panes[p].Terminal;
          PSpec.Cmd := Templates[t].Sessions[s].Windows[w].Panes[p].Cmd;
          PSpec.Cwd := Templates[t].Sessions[s].Windows[w].Panes[p].Cwd;
          PSpec.PostConnect :=
            Templates[t].Sessions[s].Windows[w].Panes[p].PostConnect;
          PSpec.ScrollBack :=
            Templates[t].Sessions[s].Windows[w].Panes[p].ScrollBack;
          SetLength(WSpec.Panes, Length(WSpec.Panes) + 1);
          WSpec.Panes[High(WSpec.Panes)] := PSpec;
        end;
        SetLength(Prof.Windows, Length(Prof.Windows) + 1);
        Prof.Windows[High(Prof.Windows)] := WSpec;
      end;
      SetLength(Profiles, Length(Profiles) + 1);
      Profiles[High(Profiles)] := Prof;
    end;
  end;
end;

function LoadProfiles(const UserFile, SystemFile: string;
  out Profiles: TProfileArray): boolean;
var
  Templates: TTemplateArray;
begin
  Profiles := nil;
  // [profile.*]: user first, then system (the first one per name wins)
  LoadProfilesFromFile(UserFile, coUser, Profiles);
  if not SameFileName(UserFile, SystemFile) then
    LoadProfilesFromFile(SystemFile, coSystem, Profiles);
  // legacy templates (INI or SQLite per [storage]) flattened afterwards
  Templates := nil;
  LoadTemplates(UserFile, Templates);
  FlattenTemplates(Templates, coUser, Profiles);
  if not SameFileName(UserFile, SystemFile) then
  begin
    Templates := nil;
    LoadTemplates(SystemFile, Templates);
    FlattenTemplates(Templates, coSystem, Profiles);
  end;
  Result := Length(Profiles) > 0;
end;

procedure SaveProfiles(const FileName: string; const AProfiles: TProfileArray);
var
  Ini: TIniFile;
  SL, Names: TStringList;
  i, w, p: integer;
  Sec, WSec, PSec, TempName: string;
begin
  TempName := FileName + '.tmp.' + IntToStr(fpGetPid);
  if FileExists(TempName) then
    DeleteFile(TempName);
  // copy of the current content to preserve unrelated sections
  SL := TStringList.Create;
  try
    if FileExists(FileName) then
      SL.LoadFromFile(FileName);
    SL.SaveToFile(TempName);
  finally
    SL.Free;
  end;
  Ini := TIniFile.Create(TempName);
  SL := TStringList.Create;
  Names := TStringList.Create;
  try
    // delete what is ours: [profile.*] (all subsections) and the
    // legacy [template.*] (absorbed at the first save)
    Ini.ReadSections(SL);
    for i := 0 to SL.Count - 1 do
      if (LowerCase(Copy(SL[i], 1, Length('profile.'))) = 'profile.') or
         (LowerCase(Copy(SL[i], 1, Length('template.'))) = 'template.') then
        Ini.EraseSection(SL[i]);
    for i := 0 to High(AProfiles) do
    begin
      if AProfiles[i].Origin <> coUser then
        continue;
      Sec := 'profile.' + AProfiles[i].Name;
      Ini.WriteString(Sec, 'name', AProfiles[i].Name);
      Ini.WriteInteger(Sec, 'enabled', Ord(AProfiles[i].Enabled));
      Ini.WriteInteger(Sec, 'focused_window', AProfiles[i].FocusedWindow);
      Names.Clear;
      for w := 0 to High(AProfiles[i].Windows) do
        Names.Add(AProfiles[i].Windows[w].Name);
      Names.Delimiter := ',';
      Names.StrictDelimiter := True;
      Ini.WriteString(Sec, 'windows', Names.DelimitedText);
      for w := 0 to High(AProfiles[i].Windows) do
      begin
        WSec := Sec + '.window.' + AProfiles[i].Windows[w].Name;
        Ini.WriteInteger(WSec, 'enabled',
          Ord(AProfiles[i].Windows[w].Enabled));
        Ini.WriteString(WSec, 'layout', AProfiles[i].Windows[w].Layout);
        Ini.WriteInteger(WSec, 'focused_pane',
          AProfiles[i].Windows[w].FocusedPane);
        if AProfiles[i].Windows[w].DeskW > 0 then
          Ini.WriteInteger(WSec, 'deskw', AProfiles[i].Windows[w].DeskW);
        if AProfiles[i].Windows[w].DeskH > 0 then
          Ini.WriteInteger(WSec, 'deskh', AProfiles[i].Windows[w].DeskH);
        Names.Clear;
        for p := 0 to High(AProfiles[i].Windows[w].Panes) do
          Names.Add(AProfiles[i].Windows[w].Panes[p].Name);
        Ini.WriteString(WSec, 'panes', Names.DelimitedText);
        for p := 0 to High(AProfiles[i].Windows[w].Panes) do
        begin
          PSec := WSec + '.pane.' + AProfiles[i].Windows[w].Panes[p].Name;
          Ini.WriteInteger(PSec, 'enabled',
            Ord(AProfiles[i].Windows[w].Panes[p].Enabled));
          if AProfiles[i].Windows[w].Panes[p].WClass <> '' then
            Ini.WriteString(PSec, 'class',
              AProfiles[i].Windows[w].Panes[p].WClass);
          if AProfiles[i].Windows[w].Panes[p].Title <> '' then
            Ini.WriteString(PSec, 'title',
              IniQuoteGuard(AProfiles[i].Windows[w].Panes[p].Title));
          if AProfiles[i].Windows[w].Panes[p].Cmd <> '' then
            Ini.WriteString(PSec, 'cmd',
              IniQuoteGuard(AProfiles[i].Windows[w].Panes[p].Cmd));
          if AProfiles[i].Windows[w].Panes[p].Cwd <> '' then
            Ini.WriteString(PSec, 'cwd',
              IniQuoteGuard(AProfiles[i].Windows[w].Panes[p].Cwd));
          if AProfiles[i].Windows[w].Panes[p].Connect <> '' then
            Ini.WriteString(PSec, 'connect',
              IniQuoteGuard(AProfiles[i].Windows[w].Panes[p].Connect));
          if AProfiles[i].Windows[w].Panes[p].PostConnect <> '' then
            Ini.WriteString(PSec, 'postconnect',
              IniQuoteGuard(AProfiles[i].Windows[w].Panes[p].PostConnect));
          if AProfiles[i].Windows[w].Panes[p].ScrollBack > 0 then
            Ini.WriteInteger(PSec, 'scrollback',
              AProfiles[i].Windows[w].Panes[p].ScrollBack);
          // exact geometry of the pane window
          if AProfiles[i].Windows[w].Panes[p].BW > 0 then
          begin
            Ini.WriteInteger(PSec, 'bx', AProfiles[i].Windows[w].Panes[p].BX);
            Ini.WriteInteger(PSec, 'by', AProfiles[i].Windows[w].Panes[p].BY);
            Ini.WriteInteger(PSec, 'bw', AProfiles[i].Windows[w].Panes[p].BW);
            Ini.WriteInteger(PSec, 'bh', AProfiles[i].Windows[w].Panes[p].BH);
          end;
          if AProfiles[i].Windows[w].Panes[p].Minimized then
            Ini.WriteInteger(PSec, 'min', 1);
          if AProfiles[i].Windows[w].Panes[p].Zoomed then
            Ini.WriteInteger(PSec, 'zoom', 1);
        end;
      end;
    end;
    Ini.UpdateFile;
    FpChmod(PAnsiChar(TempName), &600);
  finally
    Names.Free;
    SL.Free;
    Ini.Free;
  end;
  if not RenameFile(TempName, FileName) then
    DeleteFile(TempName);
end;

end.
