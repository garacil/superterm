(*
  Autor: Germán Luis Aracil Boned
  Proyecto: superterm - terminal con autologin, splits y sesiones
  Unidad: st_profiles - perfiles: colecciones nombradas de ventanas, cada
  ventana con su layout de paneles que referencian clases de ventana.
  Absorben las plantillas [template.*] antiguas (aplanando su nivel de
  "sesion": una plantilla multi-sesion se convierte en varios perfiles).
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
    WClass: string;         // referencia a clase de ventana ('' = ad-hoc)
    Title: string;          // titulo propio de la ventana ('' = usa clase/cwd)
    Cmd: string;            // overrides por panel (pisan a la clase)
    Cwd: string;
    Connect: string;        // conexion libre ad-hoc (paneles del asistente)
    PostConnect: string;
    ScrollBack: integer;
    // geometria exacta de la ventana del panel (BW<=0 = sin datos, se tila):
    // posicion/tamano manuales, minimizada y maximizada, para restaurar el
    // perfil dejando TODO como estaba al guardarlo
    BX, BY, BW, BH: integer;
    Minimized: boolean;
    Zoomed: boolean;
  end;
  TProfilePaneArray = array of TProfilePaneSpec;

  TProfileWindowSpec = record
    Name: string;
    Enabled: boolean;
    Layout: string;         // misma gramatica que session.ini (L, V:500;L;L)
    FocusedPane: integer;
    DeskW, DeskH: integer;  // tamano del escritorio al guardar (bounds absolutos)
    Panes: TProfilePaneArray;
  end;
  TProfileWindowArray = array of TProfileWindowSpec;

  TProfileSpec = record
    Name: string;
    Enabled: boolean;
    Origin: TWClassOrigin;  // user = editable/persistible
    FocusedWindow: integer;
    Windows: TProfileWindowArray;
  end;
  TProfileArray = array of TProfileSpec;

// carga [profile.*] del fichero de usuario y del de sistema (gana user) y
// aplana las plantillas [template.*] legadas (incluido el backend SQLite)
function LoadProfiles(const UserFile, SystemFile: string;
  out Profiles: TProfileArray): boolean;

// escribe los perfiles de origen usuario en FileName de forma atomica,
// preservando secciones ajenas; absorbe [template.*] del usuario al guardar
procedure SaveProfiles(const FileName: string; const AProfiles: TProfileArray);

// busca por nombre (insensible a mayusculas); -1 si no esta
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

// TIniFile recorta un par de comillas exteriores al leer: si el valor
// empieza y termina con la misma comilla, se envuelve con otra capa igual
// para que la relectura devuelva el valor exacto
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

// divide una lista separada por comas en nombres limpios no vacios
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
  // solo la cabecera [profile.NOMBRE], sin mas puntos tras el nombre
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
      // el primero gana dentro de la carga combinada (user antes que system)
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
          // 'class' canonico; 'terminal' aceptado como sinonimo legado
          PSpec.WClass := Ini.ReadString(PSec, 'class',
            Ini.ReadString(PSec, 'terminal', ''));
          PSpec.Title := Ini.ReadString(PSec, 'title', '');
          PSpec.Cmd := Ini.ReadString(PSec, 'cmd', '');
          PSpec.Cwd := Ini.ReadString(PSec, 'cwd', '');
          PSpec.Connect := Ini.ReadString(PSec, 'connect', '');
          PSpec.PostConnect := Ini.ReadString(PSec, 'postconnect', '');
          PSpec.ScrollBack := Ini.ReadInteger(PSec, 'scrollback', 0);
          if PSpec.ScrollBack < 0 then
            PSpec.ScrollBack := 0;
          if PSpec.ScrollBack > MAX_SCROLLBACK then
            PSpec.ScrollBack := MAX_SCROLLBACK;
          // geometria exacta de la ventana del panel
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

// una plantilla legada se aplana: 1 sesion -> perfil con su nombre;
// N sesiones -> un perfil 'plantilla/sesion' por cada una
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
        continue;   // un [profile.*] explicito gana a la plantilla aplanada
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
  // [profile.*]: primero usuario, luego sistema (el primero por nombre gana)
  LoadProfilesFromFile(UserFile, coUser, Profiles);
  if not SameFileName(UserFile, SystemFile) then
    LoadProfilesFromFile(SystemFile, coSystem, Profiles);
  // plantillas legadas (INI o SQLite segun [storage]) aplanadas detras
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
  // copia del contenido actual para preservar las secciones ajenas
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
    // borrar lo nuestro: [profile.*] (todas las subsecciones) y las
    // [template.*] legadas (absorcion al primer guardado)
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
          // geometria exacta de la ventana del panel
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
