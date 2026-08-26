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
  Classes, SysUtils, IniFiles, ctypes, st_config, st_wclass,
  st_templates, st_layout;

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
    IconSlot: integer;       // stable minimized slot; -1 otherwise
    Zoomed: boolean;
  end;
  TProfilePaneArray = array of TProfilePaneSpec;

  TProfileWindowSpec = record
    Name: string;
    Enabled: boolean;
    Layout: string;         // same grammar as session.ini (L, V:500;L;L)
    FocusedPane: integer;
    DeskW, DeskH: integer;  // canonical desktop work area (character cells)
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

// Atomically reloads, checks and adds one empty user profile while holding the
// same inter-process lock used by SaveProfiles. False means the name appeared
// concurrently; AProfiles is refreshed in either case.
function CreateEmptyProfileAtomic(const UserFile, SystemFile, AName: string;
  var AProfiles: TProfileArray): boolean;

// Conflict-safe profile mutations for independent attached clients. AProfiles
// is both the caller's expected snapshot and the authoritative refreshed
// result. They reload and compare the complete target object under the common
// config lock before an atomic file replacement.
// Rename/delete also remap an on-disk default which still names their target
// inside that same replacement, so a crash cannot publish half a generation.
function RenameUserProfileAtomic(const UserFile, SystemFile, OldName,
  NewName: string; var AProfiles: TProfileArray): boolean;
function DeleteUserProfileAtomic(const UserFile, SystemFile, AName: string;
  var AProfiles: TProfileArray): boolean;
function UpsertUserProfileAtomic(const UserFile, SystemFile: string;
  const AProfile: TProfileSpec; var AProfiles: TProfileArray): boolean;

// Select a default by stable name while holding the same lock as profile
// rename/delete. The preferred window is accepted only if it still exists
// and is enabled in that exact generation; otherwise the fresh profile's
// focused/first enabled window is used. AProfiles is refreshed either way.
function SetDefaultProfileAtomic(const UserFile, SystemFile, AName,
  PreferredWindow: string; var AProfiles: TProfileArray;
  out SelectedWindow: string): boolean;

// A profile name is embedded in an INI section. Keep it round-trippable and
// reject section delimiters/control bytes instead of appearing to save a
// profile that the next process cannot load.
function ValidProfileName(const AName: string): boolean;

// searches by name (case-insensitive); -1 if not found
function FindProfileByName(const A: TProfileArray; const AName: string): integer;

implementation

function ValidProfileName(const AName: string): boolean;
var
  I: integer;
begin
  Result := (AName <> '') and (AName = Trim(AName));
  if not Result then
    Exit;
  for I := 1 to Length(AName) do
    if (byte(AName[I]) < 32) or (byte(AName[I]) = 127) or
       (AName[I] in ['.', '[', ']']) then
      Exit(False);
end;

function FindProfileByName(const A: TProfileArray; const AName: string): integer;
var
  i: integer;
begin
  Result := -1;
  for i := 0 to High(A) do
    if SameText(A[i].Name, AName) then
      Exit(i);
end;

function SameStoredProfilePane(const A, B: TProfilePaneSpec): boolean;
begin
  Result := (A.Name = B.Name) and
    (A.Enabled = B.Enabled) and
    (A.WClass = B.WClass) and
    (A.Title = B.Title) and
    (A.Cmd = B.Cmd) and
    (A.Cwd = B.Cwd) and
    (A.Connect = B.Connect) and
    (A.PostConnect = B.PostConnect) and
    (A.ScrollBack = B.ScrollBack) and
    (A.BX = B.BX) and (A.BY = B.BY) and
    (A.BW = B.BW) and (A.BH = B.BH) and
    (A.Minimized = B.Minimized) and (A.IconSlot = B.IconSlot) and
    (A.Zoomed = B.Zoomed);
end;

function SameStoredProfileWindow(const A, B: TProfileWindowSpec): boolean;
var
  I: integer;
begin
  Result := (A.Name = B.Name) and
    (A.Enabled = B.Enabled) and
    (A.Layout = B.Layout) and
    (A.FocusedPane = B.FocusedPane) and
    (A.DeskW = B.DeskW) and (A.DeskH = B.DeskH) and
    (Length(A.Panes) = Length(B.Panes));
  if not Result then
    Exit;
  for I := 0 to High(A.Panes) do
    if not SameStoredProfilePane(A.Panes[I], B.Panes[I]) then
      Exit(False);
end;

// A complete canonical snapshot is the profile's optimistic revision. This
// avoids an extra revision file/key while still detecting every persisted
// same-object edit made after a client opened its editor.
function SameStoredProfile(const A, B: TProfileSpec): boolean;
var
  I: integer;
begin
  Result := (A.Name = B.Name) and
    (A.Enabled = B.Enabled) and
    (A.FocusedWindow = B.FocusedWindow) and
    (Length(A.Windows) = Length(B.Windows));
  if not Result then
    Exit;
  for I := 0 to High(A.Windows) do
    if not SameStoredProfileWindow(A.Windows[I], B.Windows[I]) then
      Exit(False);
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
      if not ValidProfileName(Prof.Name) then
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
          PSpec.IconSlot := -1;
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
          PSpec.IconSlot := Ini.ReadInteger(PSec, 'icon_slot', -1);
          if (not PSpec.Minimized) or (PSpec.IconSlot < 0) or
             (PSpec.IconSlot >= MAX_PANES) then
            PSpec.IconSlot := -1;
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
      if not ValidProfileName(Prof.Name) then
        continue;
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
          PSpec.IconSlot := -1;
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

procedure SaveProfilesUnlocked(const FileName: string;
  const AProfiles: TProfileArray; const DefaultOld, DefaultNew: string;
  ClearDefaultWindow: boolean);
var
  Ini: TIniFile;
  SL, Names: TStringList;
  i, w, p: integer;
  Sec, WSec, PSec, TempName, CurrentDefault: string;
begin
  TempName := BeginConfigRewriteLocked(FileName, 'profiles');
  try
    Ini := TIniFile.Create(TempName);
    SL := TStringList.Create;
    Names := TStringList.Create;
    try
    Ini.CacheUpdates := True;
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
      if not ValidProfileName(AProfiles[i].Name) then
        raise EConfigWriteError.CreateFmt('Invalid profile name: %s',
          [AProfiles[i].Name]);
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
          begin
            Ini.WriteInteger(PSec, 'min', 1);
            if (AProfiles[i].Windows[w].Panes[p].IconSlot >= 0) and
               (AProfiles[i].Windows[w].Panes[p].IconSlot < MAX_PANES) then
              Ini.WriteInteger(PSec, 'icon_slot',
                AProfiles[i].Windows[w].Panes[p].IconSlot);
          end;
          if AProfiles[i].Windows[w].Panes[p].Zoomed then
            Ini.WriteInteger(PSec, 'zoom', 1);
        end;
      end;
    end;
      if DefaultOld <> '' then
      begin
        CurrentDefault := Ini.ReadString('session', 'default_profile', '');
        if SameText(CurrentDefault, DefaultOld) then
        begin
          Ini.WriteString('session', 'default_profile', DefaultNew);
          if ClearDefaultWindow then
            Ini.WriteString('session', 'default_window', '');
        end;
      end;
      Ini.UpdateFile;
    finally
      Names.Free;
      SL.Free;
      Ini.Free;
    end;
    CommitConfigRewriteLocked(TempName, FileName);
  finally
    if TempName <> '' then
      DeleteFile(TempName);
  end;
end;

procedure SaveProfiles(const FileName: string; const AProfiles: TProfileArray);
var
  LockFd: cint;
begin
  LockFd := AcquireConfigFileLock(FileName);
  try
    SaveProfilesUnlocked(FileName, AProfiles, '', '', False);
  finally
    ReleaseConfigFileLock(LockFd);
  end;
end;

function CreateEmptyProfileAtomic(const UserFile, SystemFile, AName: string;
  var AProfiles: TProfileArray): boolean;
var
  LockFd: cint;
  Fresh: TProfileArray;
  P: TProfileSpec;
begin
  Result := False;
  if not ValidProfileName(AName) then
    Exit;
  LockFd := AcquireConfigFileLock(UserFile);
  try
    Fresh := nil;
    LoadProfiles(UserFile, SystemFile, Fresh);
    if FindProfileByName(Fresh, AName) < 0 then
    begin
      P := Default(TProfileSpec);
      P.Name := AName;
      P.Enabled := True;
      P.Origin := coUser;
      P.FocusedWindow := -1;
      SetLength(Fresh, Length(Fresh) + 1);
      Fresh[High(Fresh)] := P;
      SaveProfilesUnlocked(UserFile, Fresh, '', '', False);
      Result := True;
    end;
    AProfiles := Fresh;
  finally
    ReleaseConfigFileLock(LockFd);
  end;
end;

function RenameUserProfileAtomic(const UserFile, SystemFile, OldName,
  NewName: string; var AProfiles: TProfileArray): boolean;
var
  LockFd: cint;
  Fresh: TProfileArray;
  OldIdx, NewIdx, ExpectedIdx: integer;
  Expected: TProfileSpec;
  HaveExpected: boolean;
begin
  Result := False;
  if not ValidProfileName(NewName) then
    Exit;
  Expected := Default(TProfileSpec);
  ExpectedIdx := FindProfileByName(AProfiles, OldName);
  HaveExpected := ExpectedIdx >= 0;
  if HaveExpected then
  begin
    Expected := AProfiles[ExpectedIdx];
    HaveExpected := Expected.Origin = coUser;
  end;
  LockFd := AcquireConfigFileLock(UserFile);
  try
    Fresh := nil;
    LoadProfiles(UserFile, SystemFile, Fresh);
    OldIdx := FindProfileByName(Fresh, OldName);
    NewIdx := FindProfileByName(Fresh, NewName);
    if HaveExpected and (OldIdx >= 0) and
       (Fresh[OldIdx].Origin = coUser) and
       SameStoredProfile(Fresh[OldIdx], Expected) and
       ((NewIdx < 0) or (NewIdx = OldIdx)) then
    begin
      Fresh[OldIdx].Name := NewName;
      SaveProfilesUnlocked(UserFile, Fresh, OldName, NewName, False);
      Result := True;
    end;
    AProfiles := Fresh;
  finally
    ReleaseConfigFileLock(LockFd);
  end;
end;

function DeleteUserProfileAtomic(const UserFile, SystemFile, AName: string;
  var AProfiles: TProfileArray): boolean;
var
  LockFd: cint;
  Fresh: TProfileArray;
  Idx, ExpectedIdx: integer;
  Expected: TProfileSpec;
  HaveExpected: boolean;
begin
  Result := False;
  Expected := Default(TProfileSpec);
  ExpectedIdx := FindProfileByName(AProfiles, AName);
  HaveExpected := ExpectedIdx >= 0;
  if HaveExpected then
  begin
    Expected := AProfiles[ExpectedIdx];
    HaveExpected := Expected.Origin = coUser;
  end;
  LockFd := AcquireConfigFileLock(UserFile);
  try
    Fresh := nil;
    LoadProfiles(UserFile, SystemFile, Fresh);
    Idx := FindProfileByName(Fresh, AName);
    if HaveExpected and (Idx >= 0) and (Fresh[Idx].Origin = coUser) and
       SameStoredProfile(Fresh[Idx], Expected) then
    begin
      Delete(Fresh, Idx, 1);
      SaveProfilesUnlocked(UserFile, Fresh, AName, '', True);
      Result := True;
    end;
    AProfiles := Fresh;
  finally
    ReleaseConfigFileLock(LockFd);
  end;
end;

function UpsertUserProfileAtomic(const UserFile, SystemFile: string;
  const AProfile: TProfileSpec; var AProfiles: TProfileArray): boolean;
var
  LockFd: cint;
  Fresh: TProfileArray;
  P, Expected: TProfileSpec;
  Idx, ExpectedIdx: integer;
  HaveExpected: boolean;
begin
  Result := False;
  if not ValidProfileName(AProfile.Name) then
    Exit;
  Expected := Default(TProfileSpec);
  ExpectedIdx := FindProfileByName(AProfiles, AProfile.Name);
  HaveExpected := ExpectedIdx >= 0;
  if HaveExpected then
    Expected := AProfiles[ExpectedIdx];
  LockFd := AcquireConfigFileLock(UserFile);
  try
    Fresh := nil;
    LoadProfiles(UserFile, SystemFile, Fresh);
    P := AProfile;
    P.Origin := coUser;
    Idx := FindProfileByName(Fresh, P.Name);
    if HaveExpected then
    begin
      if (Expected.Origin <> coUser) or (Idx < 0) or
         (Fresh[Idx].Origin <> coUser) or
         (not SameStoredProfile(Fresh[Idx], Expected)) then
      begin
        AProfiles := Fresh;
        Exit;
      end;
      Fresh[Idx] := P
    end
    else if Idx < 0 then
    begin
      SetLength(Fresh, Length(Fresh) + 1);
      Fresh[High(Fresh)] := P;
    end
    else
    begin
      // It appeared after this client's catalogue snapshot.
      AProfiles := Fresh;
      Exit;
    end;
    SaveProfilesUnlocked(UserFile, Fresh, '', '', False);
    AProfiles := Fresh;
    Result := True;
  finally
    ReleaseConfigFileLock(LockFd);
  end;
end;

function SetDefaultProfileAtomic(const UserFile, SystemFile, AName,
  PreferredWindow: string; var AProfiles: TProfileArray;
  out SelectedWindow: string): boolean;
var
  LockFd: cint;
  Fresh: TProfileArray;
  Ini: TIniFile;
  TempName: string;
  Idx, WindowIdx, I: integer;
begin
  Result := False;
  SelectedWindow := '';
  LockFd := AcquireConfigFileLock(UserFile);
  try
    Fresh := nil;
    LoadProfiles(UserFile, SystemFile, Fresh);
    Idx := FindProfileByName(Fresh, AName);
    if (Idx < 0) or (not Fresh[Idx].Enabled) then
    begin
      AProfiles := Fresh;
      Exit;
    end;
    WindowIdx := -1;
    if PreferredWindow <> '' then
      for I := 0 to High(Fresh[Idx].Windows) do
        if Fresh[Idx].Windows[I].Enabled and
           SameText(Fresh[Idx].Windows[I].Name, PreferredWindow) then
        begin
          WindowIdx := I;
          Break;
        end;
    if WindowIdx < 0 then
    begin
      I := Fresh[Idx].FocusedWindow;
      if (I >= 0) and (I < Length(Fresh[Idx].Windows)) and
         Fresh[Idx].Windows[I].Enabled then
        WindowIdx := I
      else
        for I := 0 to High(Fresh[Idx].Windows) do
          if Fresh[Idx].Windows[I].Enabled then
          begin
            WindowIdx := I;
            Break;
          end;
    end;
    if WindowIdx >= 0 then
      SelectedWindow := Fresh[Idx].Windows[WindowIdx].Name;

    TempName := BeginConfigRewriteLocked(UserFile, 'default-profile');
    try
      Ini := TIniFile.Create(TempName);
      try
        Ini.CacheUpdates := True;
        Ini.WriteString('session', 'default_profile', Fresh[Idx].Name);
        Ini.WriteString('session', 'default_window', SelectedWindow);
        Ini.UpdateFile;
      finally
        Ini.Free;
      end;
      CommitConfigRewriteLocked(TempName, UserFile);
    finally
      if TempName <> '' then
        DeleteFile(TempName);
    end;
    AProfiles := Fresh;
    Result := True;
  finally
    ReleaseConfigFileLock(LockFd);
  end;
end;

end.
