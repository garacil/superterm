(*
  Autor: Germán Luis Aracil Boned
  Proyecto: superterm - terminal con autologin, splits y sesiones
  Unidad: st_wclass - clases de ventana: definicion reutilizable con nombre
  (comando al abrir, destino de conexion ssh o comando libre, comando
  post-conexion). Absorben las definiciones de terminal [t-*] antiguas.
*)

unit st_wclass;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, IniFiles, BaseUnix, st_config;

type
  // el tipo se deriva al cargar y nunca se persiste:
  // connect presente -> wcCommand; host presente -> wcSSH; si no -> wcLocal
  TWClassKind = (wcLocal, wcSSH, wcCommand);
  TWClassOrigin = (coUser, coSystem);

  TWindowClass = record
    Name: string;          // nombre canonico (sufijo de la seccion)
    Enabled: boolean;
    Kind: TWClassKind;     // derivado, no persistido
    Origin: TWClassOrigin; // solo en memoria: user = editable
    Shell: string;         // local: shell a lanzar ('' = shell de la config)
    Cmd: string;           // comando al abrir (local o remoto ssh)
    Cwd: string;           // directorio de trabajo
    Host: string;          // ssh estructurado
    User: string;
    Port: integer;
    KeyFile: string;
    Password: string;      // en INI va en base64
    Connect: string;       // conexion por comando libre (gana a host)
    PostConnect: string;   // comando tras conectar
    ScrollBack: integer;
  end;
  TWindowClassArray = array of TWindowClass;

function DefaultWindowClass: TWindowClass;

// predicado UNICO de secciones legadas [t-*]: lo comparten el lector y el
// escritor; si divergieran, el escritor podria borrar secciones ajenas
function IsLegacyTermSection(const Sec: string): boolean;

// carga [class.*] y las legadas [t-*] de un fichero; deriva Kind
procedure LoadWindowClasses(const FileName: string; AOrigin: TWClassOrigin;
  out AClasses: TWindowClassArray);

// mezcla por nombre (insensible a mayusculas); Target gana en colision
procedure MergeWindowClasses(var Target: TWindowClassArray;
  const Extra: TWindowClassArray);

// escribe las clases de origen usuario en FileName de forma atomica,
// preservando las secciones ajenas; absorbe [t-*] legadas al guardar
procedure SaveWindowClasses(const FileName: string;
  const AClasses: TWindowClassArray);

// argv estructurado para ssh (wcSSH); con sshpass si hay contrasena
procedure BuildWindowClassExec(const C: TWindowClass; out ProgramName: string;
  Args: TStringList; out Secret: string; const CommandOverride: string = '');

// comando efectivo para wcLocal/wcCommand combinando clase y overrides de
// panel segun la semantica unificada:
//   wcCommand -> conexion + post por stdin (pipe)
//   wcLocal   -> cmd (+post por stdin); solo post -> post; exec shell
function ComposePaneCommand(const C: TWindowClass;
  const PaneCmd, PanePost, PaneConnect, AShell: string;
  ALoginShell: boolean): string;

// entrega el comando post-conexion por la entrada estandar de la conexion
function WizardCommand(const AConnect, APostConnect: string): string;

// ejecuta un comando y deja despues una shell interactiva en el mismo PTY
function CommandWithInteractiveShell(const Command, AShell: string;
  LoginShell: boolean): string;

implementation

uses
  base64;

function DefaultWindowClass: TWindowClass;
begin
  Result := Default(TWindowClass);
  Result.Enabled := True;
  Result.Kind := wcLocal;
  Result.Origin := coUser;
  Result.ScrollBack := DEFAULT_SCROLLBACK;
end;

function IsLegacyTermSection(const Sec: string): boolean;
begin
  // historico: cualquier seccion que empiece por 't' salvo [template.*];
  // las nuevas [class.*]/[profile.*] y las de config no empiezan por 't'
  Result := (Sec <> '') and (Sec[1] = 't') and
    (LowerCase(Copy(Sec, 1, Length('template.'))) <> 'template.');
end;

// TIniFile recorta un par de comillas exteriores al leer: envolver con
// otra capa igual cuando el valor empieza y termina con la misma comilla
function IniQuoteGuard(const S: string): string;
begin
  Result := S;
  if (Length(S) >= 2) and (S[1] in ['''', '"']) and
     (S[Length(S)] = S[1]) then
    Result := S[1] + S + S[1];
end;

function DeriveKind(const C: TWindowClass): TWClassKind;
begin
  if C.Connect <> '' then
    Result := wcCommand
  else if C.Host <> '' then
    Result := wcSSH
  else
    Result := wcLocal;
end;

function ParseBoolStr(const V: string; Def: boolean): boolean;
begin
  if V = '' then
    Result := Def
  else
    Result := SameText(V, '1') or SameText(V, 'true') or
      SameText(V, 'yes') or SameText(V, 'on');
end;

procedure LoadWindowClasses(const FileName: string; AOrigin: TWClassOrigin;
  out AClasses: TWindowClassArray);
var
  Ini: TIniFile;
  SL: TStringList;
  i: integer;
  Sec, S: string;
  C: TWindowClass;
  IsClass: boolean;
begin
  AClasses := nil;
  if not FileExists(FileName) then
    Exit;
  Ini := TIniFile.Create(FileName);
  SL := TStringList.Create;
  try
    Ini.ReadSections(SL);
    for i := 0 to SL.Count - 1 do
    begin
      Sec := SL[i];
      IsClass := LowerCase(Copy(Sec, 1, Length('class.'))) = 'class.';
      if not (IsClass or IsLegacyTermSection(Sec)) then
        continue;
      C := DefaultWindowClass;
      C.Origin := AOrigin;
      if IsClass then
        C.Name := Ini.ReadString(Sec, 'name', Copy(Sec, Length('class.') + 1,
          MaxInt))
      else
        C.Name := Ini.ReadString(Sec, 'name', Copy(Sec, 2, MaxInt));
      if Trim(C.Name) = '' then
        continue;
      C.Enabled := ParseBoolStr(Ini.ReadString(Sec, 'enabled', '1'), True);
      C.Shell := Ini.ReadString(Sec, 'shell', '');
      C.Cmd := Ini.ReadString(Sec, 'cmd', '');
      C.Cwd := Ini.ReadString(Sec, 'cwd', '');
      C.Host := Ini.ReadString(Sec, 'host', '');
      C.User := Ini.ReadString(Sec, 'user', '');
      C.Port := Ini.ReadInteger(Sec, 'port', 0);
      C.KeyFile := Ini.ReadString(Sec, 'key', '');
      C.Connect := Ini.ReadString(Sec, 'connect', '');
      C.PostConnect := Ini.ReadString(Sec, 'postconnect', '');
      C.ScrollBack := Ini.ReadInteger(Sec, 'scrollback', DEFAULT_SCROLLBACK);
      if C.ScrollBack < 0 then
        C.ScrollBack := 0;
      if C.ScrollBack > MAX_SCROLLBACK then
        C.ScrollBack := MAX_SCROLLBACK;
      S := Ini.ReadString(Sec, 'password', '');
      if S <> '' then
      begin
        try
          C.Password := DecodeStringBase64(S);
        except
          C.Password := S;   // sin codificar
        end;
      end;
      C.Kind := DeriveKind(C);
      SetLength(AClasses, Length(AClasses) + 1);
      AClasses[High(AClasses)] := C;
    end;
  finally
    SL.Free;
    Ini.Free;
  end;
end;

function FindClassByName(const A: TWindowClassArray; const AName: string): integer;
var
  i: integer;
begin
  Result := -1;
  for i := 0 to High(A) do
    if SameText(A[i].Name, AName) then
      Exit(i);
end;

procedure MergeWindowClasses(var Target: TWindowClassArray;
  const Extra: TWindowClassArray);
var
  i: integer;
begin
  for i := 0 to High(Extra) do
    if FindClassByName(Target, Extra[i].Name) < 0 then
    begin
      SetLength(Target, Length(Target) + 1);
      Target[High(Target)] := Extra[i];
    end;
end;

procedure SaveWindowClasses(const FileName: string;
  const AClasses: TWindowClassArray);
var
  Ini: TIniFile;
  SL: TStringList;
  i: integer;
  Sec, TempName: string;
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
  try
    // borrar todo lo que es nuestro: [class.*] y las legadas [t-*]
    // (asi el primer guardado absorbe y migra las [t-*] del usuario)
    Ini.ReadSections(SL);
    for i := 0 to SL.Count - 1 do
      if IsLegacyTermSection(SL[i]) or
         (LowerCase(Copy(SL[i], 1, Length('class.'))) = 'class.') then
        Ini.EraseSection(SL[i]);
    for i := 0 to High(AClasses) do
    begin
      if AClasses[i].Origin <> coUser then
        continue;
      Sec := 'class.' + AClasses[i].Name;
      Ini.WriteString(Sec, 'name', AClasses[i].Name);
      Ini.WriteInteger(Sec, 'enabled', Ord(AClasses[i].Enabled));
      if AClasses[i].Shell <> '' then
        Ini.WriteString(Sec, 'shell', AClasses[i].Shell);
      if AClasses[i].Cmd <> '' then
        Ini.WriteString(Sec, 'cmd', IniQuoteGuard(AClasses[i].Cmd));
      if AClasses[i].Cwd <> '' then
        Ini.WriteString(Sec, 'cwd', IniQuoteGuard(AClasses[i].Cwd));
      if AClasses[i].Host <> '' then
        Ini.WriteString(Sec, 'host', AClasses[i].Host);
      if AClasses[i].User <> '' then
        Ini.WriteString(Sec, 'user', AClasses[i].User);
      if AClasses[i].Port > 0 then
        Ini.WriteInteger(Sec, 'port', AClasses[i].Port);
      if AClasses[i].KeyFile <> '' then
        Ini.WriteString(Sec, 'key', AClasses[i].KeyFile);
      if AClasses[i].Password <> '' then
        Ini.WriteString(Sec, 'password',
          EncodeStringBase64(AClasses[i].Password));
      if AClasses[i].Connect <> '' then
        Ini.WriteString(Sec, 'connect', IniQuoteGuard(AClasses[i].Connect));
      if AClasses[i].PostConnect <> '' then
        Ini.WriteString(Sec, 'postconnect',
          IniQuoteGuard(AClasses[i].PostConnect));
      if (AClasses[i].ScrollBack > 0) and
         (AClasses[i].ScrollBack <> DEFAULT_SCROLLBACK) then
        Ini.WriteInteger(Sec, 'scrollback', AClasses[i].ScrollBack);
    end;
    Ini.UpdateFile;
    // el fichero puede contener contrasenas
    FpChmod(PAnsiChar(TempName), &600);
  finally
    SL.Free;
    Ini.Free;
  end;
  if not RenameFile(TempName, FileName) then
    DeleteFile(TempName);
end;

procedure BuildWindowClassExec(const C: TWindowClass; out ProgramName: string;
  Args: TStringList; out Secret: string; const CommandOverride: string);
var
  Target, Path, Item: string;
  Start, Sep: integer;
  HaveSshPass: boolean;
begin
  ProgramName := '';
  Secret := '';
  Args.Clear;
  if (not C.Enabled) or (C.Kind <> wcSSH) then
    Exit;
  // Los argumentos ssh van estructurados. El comando remoto es un unico
  // argumento porque el servidor SSH lo pasa a su shell de login.
  HaveSshPass := False;
  if C.Password <> '' then
  begin
    Secret := C.Password;
    Path := GetEnvironmentVariable('PATH');
    Start := 1;
    while Start <= Length(Path) + 1 do
    begin
      Sep := Pos(':', Path, Start);
      if Sep = 0 then
        Sep := Length(Path) + 1;
      Item := Copy(Path, Start, Sep - Start);
      if Item = '' then
        Item := '.';
      if FileExists(IncludeTrailingPathDelimiter(Item) + 'sshpass') then
      begin
        HaveSshPass := True;
        Break;
      end;
      Start := Sep + 1;
    end;
  end;
  if HaveSshPass then
  begin
    ProgramName := 'sshpass';
    Args.Add('sshpass');
    Args.Add('-d');
    Args.Add('3');
  end
  else
  begin
    ProgramName := 'ssh';
    Args.Add('ssh');
  end;
  Args.Add('-tt');
  if C.Port > 0 then
  begin
    Args.Add('-p');
    Args.Add(IntToStr(C.Port));
  end;
  if C.KeyFile <> '' then
  begin
    Args.Add('-i');
    Args.Add(ExpandUserPath(C.KeyFile));
  end;
  Args.Add('-o');
  Args.Add('StrictHostKeyChecking=accept-new');
  if C.User <> '' then
    Target := C.User + '@' + C.Host
  else
    Target := C.Host;
  Args.Add(Target);
  if CommandOverride <> '' then
    Args.Add(CommandOverride)
  else if C.PostConnect <> '' then
    Args.Add(C.PostConnect)
  else if C.Cmd <> '' then
    Args.Add(C.Cmd);
end;

function WizardCommand(const AConnect, APostConnect: string): string;
begin
  Result := Trim(AConnect);
  if Result = '' then
    Exit;
  if Trim(APostConnect) <> '' then
    Result := 'printf ''%s\n'' ' + ShellQuote(Trim(APostConnect)) +
      ' | (' + Result + ')';
end;

function CommandWithInteractiveShell(const Command, AShell: string;
  LoginShell: boolean): string;
begin
  Result := Trim(Command);
  if Result = '' then
    Exit;
  Result := Result + '; exec ' + ShellQuote(AShell);
  if LoginShell then
    Result := Result + ' -l'
  else
    Result := Result + ' -i';
end;

function ComposePaneCommand(const C: TWindowClass;
  const PaneCmd, PanePost, PaneConnect, AShell: string;
  ALoginShell: boolean): string;
var
  EffCmd, EffPost, EffConnect: string;
begin
  // los campos del panel pisan a los de la clase
  EffCmd := PaneCmd;
  if EffCmd = '' then
    EffCmd := C.Cmd;
  EffPost := PanePost;
  if EffPost = '' then
    EffPost := C.PostConnect;
  EffConnect := PaneConnect;
  if EffConnect = '' then
    EffConnect := C.Connect;
  if EffConnect <> '' then
  begin
    // conexion por comando libre: el post va por stdin de la conexion
    Result := WizardCommand(EffConnect, EffPost);
    Exit;
  end;
  // local
  if EffCmd <> '' then
  begin
    if EffPost <> '' then
      Result := WizardCommand(EffCmd, EffPost)
    else
      Result := EffCmd;
    Exit;
  end;
  if EffPost <> '' then
  begin
    // solo post-conexion: ejecutarlo y quedarse en una shell interactiva
    // (un pipe a la shell moriria al cerrarse stdin)
    Result := CommandWithInteractiveShell(EffPost, AShell, ALoginShell);
    Exit;
  end;
  Result := '';
end;

end.
