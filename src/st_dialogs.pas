(*
  Autor: Germán Luis Aracil Boned
  Proyecto: superterm - terminal con autologin, splits y sesiones
  Unidad: st_dialogs - dialogos FreeVision para las clases de ventana:
  gestor (lista + alta/edicion/duplicado/borrado) y selector rapido para
  abrir una clase en un panel nuevo.
*)

unit st_dialogs;

{$mode objfpc}{$H+}

interface

uses
  Objects, Drivers, Views, Dialogs, MsgBox, App, SysUtils,
  st_config, st_wclass, st_profiles;

// gestor de clases: lista + New/Edit/Duplicate/Delete/Close. Edita SOLO las
// de origen usuario; las de sistema se muestran '(sistema)' y solo permiten
// Duplicate. Devuelve True si hubo cambios (ya persistidos con
// SaveWindowClasses(ConfigFile, AClasses) dentro).
function RunClassManager(var AClasses: TWindowClassArray): boolean;

// selector simple para "abrir clase en panel nuevo": lista con
// '1 Local shell' primero y las clases habilitadas despues.
// AIndex: -1 = shell local, si no indice en AClasses. False = cancelado.
function RunClassPicker(const AClasses: TWindowClassArray;
  out AIndex: integer): boolean;

type
  // accion que el gestor de perfiles devuelve al llamador; el dialogo no
  // toca el runtime: activar, capturar el area de trabajo o fijar el
  // perfil por defecto las ejecuta quien llama
  TProfileAction = (paNone, paActivate, paSaveCurrent, paSetDefault);

// gestor de perfiles: lista + Activate/Save current/Rename/Set default/
// Delete/Close. Rename y Delete solo sobre perfiles de usuario y persisten
// con SaveProfiles(ConfigFile, AProfiles) dentro; Activate/Save current/
// Set default devuelven True inmediatamente con AAction/ATarget para que
// el llamador actue. AActive = fila con marca de activo (-1 ninguna),
// ADefault = perfil por defecto (-1 ninguno). False = cerrado sin cambios
// ni accion; True con AAction=paNone = solo hubo ediciones persistidas.
function RunProfileManager(var AProfiles: TProfileArray;
  AActive, ADefault: integer; out AAction: TProfileAction;
  out ATarget: integer): boolean;

implementation

const
  // comandos locales de los botones de los gestores (>255: siempre
  // habilitados); cada gestor usa un rango contiguo propio
  cmClsNew  = 3300;
  cmClsEdit = 3301;
  cmClsDup  = 3302;
  cmClsDel  = 3303;
  cmPrfActivate = 3310;
  cmPrfSave     = 3311;
  cmPrfRename   = 3312;
  cmPrfDefault  = 3313;
  cmPrfDelete   = 3314;

type
  TNameArray = array of string;
  PNameArray = ^TNameArray;

  // gestor generico: los botones de accion terminan el dialogo con su
  // comando (rango CmdLo..CmdHi) y el bucle del llamador decide; doble
  // click o espacio en la lista equivale al comando SelectCmd
  PManagerDialog = ^TManagerDialog;
  TManagerDialog = object(TDialog)
    CmdLo, CmdHi: word;
    SelectCmd: word;
    procedure HandleEvent(var Event: TEvent); virtual;
  end;

  // selector: doble click en la lista equivale al boton Abrir
  PPickerDialog = ^TPickerDialog;
  TPickerDialog = object(TDialog)
    procedure HandleEvent(var Event: TEvent); virtual;
  end;

  // editor de una clase; Valid(cmOK) valida y muestra el error sin cerrar.
  // OtherNames apunta a una variable local del llamador (solo vive durante
  // el ExecView modal): nombres del resto de clases para la unicidad.
  PClassEditDialog = ^TClassEditDialog;
  TClassEditDialog = object(TDialog)
    NameLine: PInputLine;
    HostLine: PInputLine;
    PortLine: PInputLine;
    UserLine: PInputLine;
    PassLine: PInputLine;
    KeyLine: PInputLine;
    ConnectLine: PInputLine;
    PostLine: PInputLine;
    CmdLine: PInputLine;
    CwdLine: PInputLine;
    ShellLine: PInputLine;
    ScrollLine: PInputLine;
    TypeRadio: PRadioButtons;
    EnabledBox: PCheckBoxes;
    OtherNames: PNameArray;
    function Valid(Command: Word): Boolean; virtual;
  end;

{ ------------------------------ utilidades ------------------------------ }

// lectura directa del buffer del TInputLine (Data^ es ShortString)
function LineText(P: PInputLine): string;
begin
  Result := '';
  if (P <> nil) and (P^.Data <> nil) then
    Result := P^.Data^;
end;

// escritura truncada a MaxLen: el buffer interno mide MaxLen+1 bytes y la
// asignacion de ShortString copiaria hasta 255 sin este recorte
procedure SetLineText(P: PInputLine; const S: string);
begin
  if (P <> nil) and (P^.Data <> nil) then
    P^.Data^ := Copy(S, 1, P^.MaxLen);
end;

// MessageBox pasa el texto por FormatStr, que interpreta '%': doblarlo para
// que los nombres de clase con '%' no descuadren (o cuelguen) el formateo
function EscPercent(const S: string): string;
var
  i: integer;
begin
  Result := '';
  for i := 1 to Length(S) do
    if S[i] = '%' then
      Result := Result + '%%'
    else
      Result := Result + S[i];
end;

procedure ErrorBox(const Msg: string);
begin
  MessageBox(EscPercent(Msg), nil, mfError or mfOKButton);
end;

procedure InfoReadOnly;
begin
  MessageBox(UiText('System classes are read-only; use Duplicate.',
    'Las clases de sistema son de solo lectura; use Duplicar.'), nil,
    mfInformation or mfOKButton);
end;

function ConfirmYes(const Msg: string): boolean;
begin
  Result := MessageBox(EscPercent(Msg), nil,
    mfConfirmation or mfYesButton or mfNoButton) = cmYes;
end;

// rectangulo centrado en el escritorio, recortado si no cabe
function CenteredRect(W, H: integer): TRect;
var
  D: TRect;
begin
  D := Default(TRect);
  Desktop^.GetExtent(D);
  if W > D.B.X then
    W := D.B.X;
  if H > D.B.Y then
    H := D.B.Y;
  Result.Assign(0, 0, W, H);
  Result.Move((D.B.X - W) div 2, (D.B.Y - H) div 2);
end;

// espejo del DeriveKind privado de st_wclass: connect gana a host
function DerivedKind(const C: TWindowClass): TWClassKind;
begin
  if C.Connect <> '' then
    Result := wcCommand
  else if C.Host <> '' then
    Result := wcSSH
  else
    Result := wcLocal;
end;

// texto de tipo de la lista, fijo en ambos idiomas (no traducir)
function KindText(AKind: TWClassKind): string;
begin
  case AKind of
    wcSSH: Result := 'ssh';
    wcCommand: Result := 'command';
  else
    Result := 'local';
  end;
end;

function TargetText(const C: TWindowClass): string;
begin
  case C.Kind of
    wcSSH:
      begin
        Result := C.Host;
        if C.User <> '' then
          Result := C.User + '@' + Result;
        if C.Port > 0 then
          Result := Result + ':' + IntToStr(C.Port);
      end;
    wcCommand: Result := Copy(C.Connect, 1, 24);
  else
    if C.Cmd <> '' then
      Result := C.Cmd
    else
      Result := '(shell)';
  end;
end;

function NameExists(const A: TWindowClassArray; const AName: string;
  SkipIndex: integer): boolean;
var
  i: integer;
begin
  Result := False;
  for i := 0 to High(A) do
    if (i <> SkipIndex) and SameText(A[i].Name, AName) then
      Exit(True);
end;

// nombre libre para el duplicado: base-2, base-3, ...
function UniqueCopyName(const A: TWindowClassArray; const Base: string): string;
var
  n: integer;
begin
  n := 2;
  Result := Base + '-' + IntToStr(n);
  while NameExists(A, Result, -1) do
  begin
    Inc(n);
    Result := Base + '-' + IntToStr(n);
  end;
end;

{ ------------------------------ editor ------------------------------ }

function TClassEditDialog.Valid(Command: Word): Boolean;
var
  N, S: string;
  W: Sw_Word;
  V, i: longint;
begin
  Result := inherited Valid(Command);
  if (not Result) or (Command <> cmOK) then
    Exit;
  N := Trim(LineText(NameLine));
  if N = '' then
  begin
    ErrorBox(UiText('The name cannot be empty.',
      'El nombre no puede estar vacio.'));
    Exit(False);
  end;
  if OtherNames <> nil then
    for i := 0 to High(OtherNames^) do
      if SameText(OtherNames^[i], N) then
      begin
        ErrorBox(Format(UiText('A class named "%s" already exists.',
          'Ya existe una clase llamada "%s".'), [N]));
        Exit(False);
      end;
  W := 0;
  TypeRadio^.GetData(W);
  if (W = 1) and (Trim(LineText(HostLine)) = '') then
  begin
    ErrorBox(UiText('The SSH type requires a host.',
      'El tipo SSH requiere un host.'));
    Exit(False);
  end;
  if (W = 2) and (Trim(LineText(ConnectLine)) = '') then
  begin
    ErrorBox(UiText('The command type requires a connect command.',
      'El tipo comando requiere un comando de conexion.'));
    Exit(False);
  end;
  S := Trim(LineText(PortLine));
  if S <> '' then
  begin
    V := StrToIntDef(S, -1);
    if (V < 0) or (V > 65535) then
    begin
      ErrorBox(UiText('Invalid port (0..65535).',
        'Puerto invalido (0..65535).'));
      Exit(False);
    end;
  end;
  S := Trim(LineText(ScrollLine));
  if S <> '' then
  begin
    V := StrToIntDef(S, -1);
    if (V < 0) or (V > MAX_SCROLLBACK) then
    begin
      ErrorBox(Format(UiText('Invalid scrollback (0..%d).',
        'Scrollback invalido (0..%d).'), [MAX_SCROLLBACK]));
      Exit(False);
    end;
  end;
end;

// editor modal de una clase; SkipIndex = indice de C en AllClasses para
// excluirlo de la unicidad (-1 si es nueva). True si el usuario acepto y
// C quedo actualizada (con Kind rederivado).
function EditWindowClass(var C: TWindowClass;
  const AllClasses: TWindowClassArray; SkipIndex: integer): boolean;
var
  D: PClassEditDialog;
  R: TRect;
  Names: TNameArray;
  i, n: integer;
  W: Sw_Word;
  S: string;
begin
  Result := False;
  Names := nil;
  SetLength(Names, Length(AllClasses));
  n := 0;
  for i := 0 to High(AllClasses) do
    if i <> SkipIndex then
    begin
      Names[n] := AllClasses[i].Name;
      Inc(n);
    end;
  SetLength(Names, n);

  R := CenteredRect(66, 20);
  D := New(PClassEditDialog, Init(R,
    UiText('Window class', 'Clase de ventana')));
  with D^ do
  begin
    OtherNames := @Names;
    NameLine := NewInputLine(22, 1, 25, 40, hcNoContext, nil);
    NewLabel(2, 1, UiText('Name', 'Nombre'), NameLine);
    R.Assign(49, 1, 63, 2);
    EnabledBox := New(PCheckBoxes, Init(R,
      NewSItem(UiText('Enabled', 'Habilitada'), nil)));
    Insert(EnabledBox);
    R.Assign(22, 2, 63, 3);
    TypeRadio := New(PRadioButtons, Init(R,
      NewSItem('Local',
      NewSItem('SSH',
      NewSItem(UiText('Command', 'Comando'), nil)))));
    Insert(TypeRadio);
    NewLabel(2, 2, UiText('Type', 'Tipo'), TypeRadio);
    HostLine := NewInputLine(22, 3, 21, 128, hcNoContext, nil);
    NewLabel(2, 3, 'Host', HostLine);
    PortLine := NewInputLine(53, 3, 8, 5, hcNoContext, nil);
    NewLabel(45, 3, UiText('Port', 'Puerto'), PortLine);
    UserLine := NewInputLine(22, 4, 21, 64, hcNoContext, nil);
    NewLabel(2, 4, UiText('User', 'Usuario'), UserLine);
    PassLine := NewInputLine(22, 5, 25, 128, hcNoContext, nil);
    NewLabel(2, 5, UiText('Password', 'Contrasena'), PassLine);
    KeyLine := NewInputLine(22, 6, 41, 200, hcNoContext, nil);
    NewLabel(2, 6, UiText('SSH key', 'Clave SSH'), KeyLine);
    ConnectLine := NewInputLine(22, 7, 41, 255, hcNoContext, nil);
    NewLabel(2, 7, UiText('Connect command', 'Comando de conexion'),
      ConnectLine);
    PostLine := NewInputLine(22, 8, 41, 255, hcNoContext, nil);
    NewLabel(2, 8, UiText('Post-connect', 'Post-conexion'), PostLine);
    CmdLine := NewInputLine(22, 9, 41, 255, hcNoContext, nil);
    NewLabel(2, 9, UiText('Open command', 'Comando al abrir'), CmdLine);
    CwdLine := NewInputLine(22, 10, 41, 200, hcNoContext, nil);
    NewLabel(2, 10, UiText('Directory', 'Directorio'), CwdLine);
    ShellLine := NewInputLine(22, 11, 41, 128, hcNoContext, nil);
    NewLabel(2, 11, 'Shell', ShellLine);
    ScrollLine := NewInputLine(22, 12, 9, 6, hcNoContext, nil);
    NewLabel(2, 12, 'Scrollback', ScrollLine);
    R.Assign(33, 12, 53, 13);
    Insert(New(PStaticText, Init(R, Format('(0..%d)', [MAX_SCROLLBACK]))));
    NewButton(20, 15, 10, 2, 'OK', cmOK, hcNoContext, bfDefault);
    NewButton(34, 15, 12, 2, UiText('Cancel', 'Cancelar'), cmCancel,
      hcNoContext, bfNormal);

    // valores iniciales
    SetLineText(NameLine, C.Name);
    SetLineText(HostLine, C.Host);
    if C.Port > 0 then
      SetLineText(PortLine, IntToStr(C.Port));
    SetLineText(UserLine, C.User);
    SetLineText(PassLine, C.Password);
    SetLineText(KeyLine, C.KeyFile);
    SetLineText(ConnectLine, C.Connect);
    SetLineText(PostLine, C.PostConnect);
    SetLineText(CmdLine, C.Cmd);
    SetLineText(CwdLine, C.Cwd);
    SetLineText(ShellLine, C.Shell);
    SetLineText(ScrollLine, IntToStr(C.ScrollBack));
    W := Sw_Word(Ord(C.Kind));   // preseleccion del tipo derivado
    TypeRadio^.SetData(W);
    W := 0;
    if C.Enabled then
      W := 1;
    EnabledBox^.SetData(W);
  end;

  if Desktop^.ExecView(D) = cmOK then
  begin
    // leer los campos antes del Dispose (los buffers viven en las vistas)
    C.Name := Trim(LineText(D^.NameLine));
    C.Host := Trim(LineText(D^.HostLine));
    C.Port := StrToIntDef(Trim(LineText(D^.PortLine)), 0);
    C.User := Trim(LineText(D^.UserLine));
    C.Password := LineText(D^.PassLine);   // sin Trim: puede llevar espacios
    C.KeyFile := Trim(LineText(D^.KeyLine));
    C.Connect := Trim(LineText(D^.ConnectLine));
    C.PostConnect := Trim(LineText(D^.PostLine));
    C.Cmd := Trim(LineText(D^.CmdLine));
    C.Cwd := Trim(LineText(D^.CwdLine));
    C.Shell := Trim(LineText(D^.ShellLine));
    S := Trim(LineText(D^.ScrollLine));
    if S = '' then
      C.ScrollBack := DEFAULT_SCROLLBACK
    else
      C.ScrollBack := StrToIntDef(S, DEFAULT_SCROLLBACK);
    W := 0;
    D^.EnabledBox^.GetData(W);
    C.Enabled := (W and 1) <> 0;
    W := 0;
    D^.TypeRadio^.GetData(W);
    // coherencia con el tipo elegido: comando conserva connect y limpia
    // host; ssh limpia connect; local limpia ambos (Kind se deriva de ahi)
    case W of
      1: C.Connect := '';
      2: C.Host := '';
    else
      begin
        C.Host := '';
        C.Connect := '';
      end;
    end;
    C.Kind := DerivedKind(C);
    Result := True;
  end;
  Dispose(D, Done);
end;

{ ------------------------------ gestor ------------------------------ }

procedure TManagerDialog.HandleEvent(var Event: TEvent);
begin
  inherited HandleEvent(Event);
  case Event.What of
    evCommand:
      if (Event.Command >= CmdLo) and (Event.Command <= CmdHi) then
      begin
        EndModal(Event.Command);
        ClearEvent(Event);
      end;
    evBroadcast:
      if Event.Command = cmListItemSelected then
      begin
        EndModal(SelectCmd);   // doble click / espacio
        ClearEvent(Event);
      end;
  end;
end;

function ManagerRow(const C: TWindowClass): string;
var
  Tag: string;
begin
  if C.Origin = coSystem then
    Tag := UiText(' (system)', ' (sistema)')
  else
    Tag := '';
  Result := Format('%-18s %-8s %-24s%s',
    [Copy(C.Name, 1, 18), KindText(C.Kind), Copy(TargetText(C), 1, 24), Tag]);
end;

// construye y ejecuta el dialogo del gestor; devuelve el comando final.
// FocusRow entra como fila a enfocar y sale con la fila enfocada al cerrar
// (-1 si la lista esta vacia), para conservar la seleccion entre pasadas.
function ExecClassManager(const AClasses: TWindowClassArray;
  var FocusRow: integer): word;
var
  D: PManagerDialog;
  LB: PListBox;
  SB: PScrollBar;
  Coll: PStringCollection;
  R: TRect;
  i: integer;
begin
  // la coleccion es TSortedCollection: AtInsert al final respeta el orden
  // del array (Insert ordenaria alfabeticamente y descartaria duplicados)
  Coll := New(PStringCollection, Init(Length(AClasses) + 1, 8));
  for i := 0 to High(AClasses) do
    Coll^.AtInsert(Coll^.Count, NewStr(ManagerRow(AClasses[i])));

  R := CenteredRect(70, 18);
  D := New(PManagerDialog, Init(R,
    UiText('Window classes', 'Clases de ventana')));
  with D^ do
  begin
    CmdLo := cmClsNew;
    CmdHi := cmClsDel;
    SelectCmd := cmClsEdit;   // doble click = editar
    R.Assign(3, 1, 67, 2);
    Insert(New(PStaticText, Init(R, Format('%-18s %-8s %-24s',
      [UiText('Name', 'Nombre'), UiText('Type', 'Tipo'),
       UiText('Target', 'Destino')]))));
    R.Assign(66, 2, 67, 12);
    SB := New(PScrollBar, Init(R));
    Insert(SB);
    R.Assign(3, 2, 66, 12);
    LB := New(PListBox, Init(R, 1, SB));
    Insert(LB);
    LB^.NewList(Coll);
    if (FocusRow > 0) and (FocusRow < Coll^.Count) then
      LB^.FocusItem(FocusRow);
    NewButton(3, 14, 10, 2, UiText('New', 'Nuevo'), cmClsNew,
      hcNoContext, bfNormal);
    NewButton(14, 14, 10, 2, UiText('Edit', 'Editar'), cmClsEdit,
      hcNoContext, bfDefault);   // Enter = editar
    NewButton(25, 14, 13, 2, UiText('Duplicate', 'Duplicar'), cmClsDup,
      hcNoContext, bfNormal);
    NewButton(39, 14, 10, 2, UiText('Delete', 'Borrar'), cmClsDel,
      hcNoContext, bfNormal);
    NewButton(50, 14, 10, 2, UiText('Close', 'Cerrar'), cmCancel,
      hcNoContext, bfNormal);
  end;
  Result := Desktop^.ExecView(D);
  if Coll^.Count > 0 then
    FocusRow := LB^.Focused
  else
    FocusRow := -1;
  Dispose(D, Done);
  // el listbox NO libera la coleccion en Done (solo NewList libera la
  // anterior): liberarla aqui tras destruir el dialogo
  Dispose(Coll, Done);
end;

function RunClassManager(var AClasses: TWindowClassArray): boolean;
var
  Cmd: word;
  Idx, FocusRow: integer;
  C: TWindowClass;
begin
  Result := False;
  FocusRow := 0;
  repeat
    Cmd := ExecClassManager(AClasses, FocusRow);
    Idx := FocusRow;   // las filas van 1:1 con AClasses
    case Cmd of
      cmClsNew:
        begin
          C := DefaultWindowClass;
          if EditWindowClass(C, AClasses, -1) then
          begin
            SetLength(AClasses, Length(AClasses) + 1);
            AClasses[High(AClasses)] := C;
            SaveWindowClasses(ConfigFile, AClasses);
            Result := True;
            FocusRow := High(AClasses);
          end;
        end;
      cmClsEdit:
        if (Idx >= 0) and (Idx <= High(AClasses)) then
        begin
          if AClasses[Idx].Origin = coSystem then
            InfoReadOnly
          else
          begin
            C := AClasses[Idx];
            if EditWindowClass(C, AClasses, Idx) then
            begin
              AClasses[Idx] := C;
              SaveWindowClasses(ConfigFile, AClasses);
              Result := True;
            end;
          end;
        end;
      cmClsDup:
        if (Idx >= 0) and (Idx <= High(AClasses)) then
        begin
          C := AClasses[Idx];
          C.Origin := coUser;
          C.Name := UniqueCopyName(AClasses, C.Name);
          if EditWindowClass(C, AClasses, -1) then
          begin
            SetLength(AClasses, Length(AClasses) + 1);
            AClasses[High(AClasses)] := C;
            SaveWindowClasses(ConfigFile, AClasses);
            Result := True;
            FocusRow := High(AClasses);
          end;
        end;
      cmClsDel:
        if (Idx >= 0) and (Idx <= High(AClasses)) then
        begin
          if AClasses[Idx].Origin = coSystem then
            InfoReadOnly
          else if ConfirmYes(Format(UiText('Delete class "%s"?',
            'Eliminar la clase "%s"?'), [AClasses[Idx].Name])) then
          begin
            Delete(AClasses, Idx, 1);
            SaveWindowClasses(ConfigFile, AClasses);
            Result := True;
            if FocusRow > High(AClasses) then
              FocusRow := High(AClasses);
            if FocusRow < 0 then
              FocusRow := 0;
          end;
        end;
    end;
  until (Cmd = cmCancel) or (Cmd = cmOK);
end;

{ ------------------------------ selector ------------------------------ }

procedure TPickerDialog.HandleEvent(var Event: TEvent);
begin
  inherited HandleEvent(Event);
  if (Event.What = evBroadcast) and
     (Event.Command = cmListItemSelected) then
  begin
    EndModal(cmOK);   // doble click / espacio = abrir
    ClearEvent(Event);
  end;
end;

function RunClassPicker(const AClasses: TWindowClassArray;
  out AIndex: integer): boolean;
var
  D: PPickerDialog;
  LB: PListBox;
  SB: PScrollBar;
  Coll: PStringCollection;
  R: TRect;
  i, n, Row: integer;
  Prefix: string;
begin
  AIndex := -1;
  Result := False;
  Coll := New(PStringCollection, Init(Length(AClasses) + 1, 8));
  Coll^.AtInsert(0, NewStr('1 ' + UiText('Local shell', 'Shell local')));
  for i := 0 to High(AClasses) do
    if AClasses[i].Enabled then
    begin
      n := Coll^.Count + 1;      // numero visible de la fila (1..9, luego nada)
      if n <= 9 then
        Prefix := IntToStr(n) + ' '
      else
        Prefix := '  ';
      Coll^.AtInsert(Coll^.Count, NewStr(Prefix + Copy(AClasses[i].Name, 1, 36)));
    end;

  R := CenteredRect(46, 14);
  D := New(PPickerDialog, Init(R,
    UiText('Open class in new pane', 'Abrir clase en panel nuevo')));
  with D^ do
  begin
    R.Assign(42, 1, 43, 9);
    SB := New(PScrollBar, Init(R));
    Insert(SB);
    R.Assign(2, 1, 42, 9);
    LB := New(PListBox, Init(R, 1, SB));
    Insert(LB);
    LB^.NewList(Coll);
    NewButton(8, 10, 12, 2, UiText('Open', 'Abrir'), cmOK,
      hcNoContext, bfDefault);
    NewButton(24, 10, 12, 2, UiText('Cancel', 'Cancelar'), cmCancel,
      hcNoContext, bfNormal);
  end;

  if Desktop^.ExecView(D) = cmOK then
  begin
    Row := LB^.Focused;
    if Row = 0 then
    begin
      AIndex := -1;              // shell local
      Result := True;
    end
    else
    begin
      // fila k -> k-esima clase habilitada (las deshabilitadas no listan)
      n := 0;
      for i := 0 to High(AClasses) do
        if AClasses[i].Enabled then
        begin
          Inc(n);
          if n = Row then
          begin
            AIndex := i;
            Result := True;
            Break;
          end;
        end;
    end;
  end;
  Dispose(D, Done);
  Dispose(Coll, Done);
end;

{ -------------------------- gestor de perfiles -------------------------- }

procedure InfoProfileReadOnly;
begin
  MessageBox(UiText('System profiles are read-only.',
    'Los perfiles de sistema son de solo lectura.'), nil,
    mfInformation or mfOKButton);
end;

function ProfileNameExists(const A: TProfileArray; const AName: string;
  SkipIndex: integer): boolean;
var
  i: integer;
begin
  Result := False;
  for i := 0 to High(A) do
    if (i <> SkipIndex) and SameText(A[i].Name, AName) then
      Exit(True);
end;

// fila del gestor: marca de activo + nombre + numero de ventanas +
// etiqueta del perfil por defecto
function ProfileRow(const P: TProfileSpec;
  IsActive, IsDefault: boolean): string;
var
  Tag: string;
begin
  if IsDefault then
    Tag := UiText(' (default)', ' (defecto)')
  else
    Tag := '';
  Result := ActiveMark(IsActive) + Format('%-24s %8d   %s',
    [Copy(P.Name, 1, 24), Length(P.Windows), Tag]);
end;

// construye y ejecuta el dialogo del gestor de perfiles; devuelve el
// comando final. Con la lista vacia muestra una fila informativa y
// deshabilita todos los botones salvo Cerrar (crear perfiles corresponde
// al menu 'Guardar como perfil', no a este dialogo). FocusRow como en
// ExecClassManager: entra fila a enfocar, sale fila enfocada (-1 si vacia).
function ExecProfileManager(const AProfiles: TProfileArray;
  AActive, ADefault: integer; var FocusRow: integer): word;
var
  D: PManagerDialog;
  LB: PListBox;
  SB: PScrollBar;
  Coll: PStringCollection;
  R: TRect;
  i: integer;
  Btn: array[0..4] of PButton;
begin
  Coll := New(PStringCollection, Init(Length(AProfiles) + 1, 8));
  for i := 0 to High(AProfiles) do
    Coll^.AtInsert(Coll^.Count,
      NewStr(ProfileRow(AProfiles[i], i = AActive, i = ADefault)));
  if Coll^.Count = 0 then
    Coll^.AtInsert(0, NewStr(UiText('(no profiles yet)',
      '(aun no hay perfiles)')));

  R := CenteredRect(60, 16);
  D := New(PManagerDialog, Init(R, UiText('Profiles', 'Perfiles')));
  with D^ do
  begin
    CmdLo := cmPrfActivate;
    CmdHi := cmPrfDelete;
    SelectCmd := cmPrfActivate;   // doble click = activar
    R.Assign(56, 1, 57, 8);
    SB := New(PScrollBar, Init(R));
    Insert(SB);
    R.Assign(3, 1, 56, 8);
    LB := New(PListBox, Init(R, 1, SB));
    Insert(LB);
    LB^.NewList(Coll);
    if (FocusRow > 0) and (FocusRow < Coll^.Count) then
      LB^.FocusItem(FocusRow);
    Btn[0] := NewButton(3, 9, 12, 2, UiText('Activate', 'Activar'),
      cmPrfActivate, hcNoContext, bfDefault);   // Enter = activar
    Btn[1] := NewButton(16, 9, 18, 2,
      UiText('Save current', 'Guardar actual'), cmPrfSave,
      hcNoContext, bfNormal);
    Btn[2] := NewButton(35, 9, 13, 2, UiText('Rename', 'Renombrar'),
      cmPrfRename, hcNoContext, bfNormal);
    Btn[3] := NewButton(3, 11, 15, 2, UiText('Set default', 'Por defecto'),
      cmPrfDefault, hcNoContext, bfNormal);
    Btn[4] := NewButton(19, 11, 12, 2, UiText('Delete', 'Eliminar'),
      cmPrfDelete, hcNoContext, bfNormal);
    NewButton(32, 11, 10, 2, UiText('Close', 'Cerrar'), cmCancel,
      hcNoContext, bfNormal);
    if Length(AProfiles) = 0 then
      for i := 0 to High(Btn) do
        if Btn[i] <> nil then
          Btn[i]^.SetState(sfDisabled, True);
  end;
  Result := Desktop^.ExecView(D);
  if Length(AProfiles) > 0 then
    FocusRow := LB^.Focused
  else
    FocusRow := -1;
  Dispose(D, Done);
  // misma propiedad que en el gestor de clases: la coleccion no es del
  // listbox, liberarla tras destruir el dialogo
  Dispose(Coll, Done);
end;

// renombrar con InputBox prellenado; valida no-vacio y unicidad sin
// distinguir mayusculas; persiste al aceptar. False = cancelado o sin
// cambio efectivo.
function RenameProfile(var AProfiles: TProfileArray; Idx: integer): boolean;
var
  Buf: ShortString;   // InputBox exige var ShortString (unidad msgbox)
  N: string;
begin
  Result := False;
  Buf := Copy(AProfiles[Idx].Name, 1, 40);
  repeat
    if InputBox(UiText('Rename profile', 'Renombrar perfil'),
      UiText('Name', 'Nombre'), Buf, 40) <> cmOK then
      Exit;
    N := Trim(Buf);
    if N = '' then
      ErrorBox(UiText('The name cannot be empty.',
        'El nombre no puede estar vacio.'))
    else if ProfileNameExists(AProfiles, N, Idx) then
    begin
      ErrorBox(Format(UiText('A profile named "%s" already exists.',
        'Ya existe un perfil llamado "%s".'), [N]));
      N := '';
    end;
  until N <> '';
  if N = AProfiles[Idx].Name then
    Exit;   // sin cambio: no persistir ni contar como edicion
  AProfiles[Idx].Name := N;
  SaveProfiles(ConfigFile, AProfiles);
  Result := True;
end;

function RunProfileManager(var AProfiles: TProfileArray;
  AActive, ADefault: integer; out AAction: TProfileAction;
  out ATarget: integer): boolean;
var
  Cmd: word;
  Idx, FocusRow: integer;
begin
  AAction := paNone;
  ATarget := -1;
  Result := False;
  FocusRow := 0;
  if (AActive >= 0) and (AActive <= High(AProfiles)) then
    FocusRow := AActive;   // arrancar sobre el perfil activo
  repeat
    Cmd := ExecProfileManager(AProfiles, AActive, ADefault, FocusRow);
    Idx := FocusRow;   // las filas van 1:1 con AProfiles
    if (Idx >= 0) and (Idx <= High(AProfiles)) then
      case Cmd of
        cmPrfActivate:
          begin
            // la activacion la ejecuta el llamador
            AAction := paActivate;
            ATarget := Idx;
            Exit(True);
          end;
        cmPrfSave:
          if ConfirmYes(Format(UiText(
            'Overwrite profile "%s" with the current workspace?',
            'Sobrescribir el perfil "%s" con el area de trabajo actual?'),
            [AProfiles[Idx].Name])) then
          begin
            // la captura y el guardado los ejecuta el llamador
            AAction := paSaveCurrent;
            ATarget := Idx;
            Exit(True);
          end;
        cmPrfDefault:
          begin
            // el por-defecto vive en la config, no en el array: lo
            // actualiza el llamador (Cfg.DefaultProfile + SaveConfig)
            AAction := paSetDefault;
            ATarget := Idx;
            Exit(True);
          end;
        cmPrfRename:
          if AProfiles[Idx].Origin = coSystem then
            InfoProfileReadOnly
          else if RenameProfile(AProfiles, Idx) then
            Result := True;
        cmPrfDelete:
          if AProfiles[Idx].Origin = coSystem then
            InfoProfileReadOnly
          else if ConfirmYes(Format(UiText('Delete profile "%s"?',
            'Eliminar el perfil "%s"?'), [AProfiles[Idx].Name])) then
          begin
            Delete(AProfiles, Idx, 1);
            SaveProfiles(ConfigFile, AProfiles);
            Result := True;
            // reajustar las marcas de activo/por-defecto para las
            // siguientes pasadas del dialogo (solo efecto visual)
            if AActive = Idx then
              AActive := -1
            else if AActive > Idx then
              Dec(AActive);
            if ADefault = Idx then
              ADefault := -1
            else if ADefault > Idx then
              Dec(ADefault);
            if FocusRow > High(AProfiles) then
              FocusRow := High(AProfiles);
            if FocusRow < 0 then
              FocusRow := 0;
          end;
      end;
  until (Cmd = cmCancel) or (Cmd = cmOK);
  // cerrado sin accion: Result queda True solo si hubo ediciones (paNone)
end;

end.
