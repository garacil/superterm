(*
  Author: German Luis Aracil Boned
  Project: superterm - terminal with autologin, splits and sessions
  Unit: st_dialogs - FreeVision dialogs for the window classes:
  manager (list + create/edit/duplicate/delete) and quick picker to
  open a class in a new pane.
*)

unit st_dialogs;

{$mode objfpc}{$H+}

interface

uses
  Objects, Drivers, Views, Dialogs, MsgBox, App, SysUtils,
  st_config, st_wclass, st_profiles, st_server, st_clipboard;

// class manager: list + New/Edit/Duplicate/Delete/Close. Edits ONLY the
// user-origin ones; system ones show '(system)' and only allow
// Duplicate. Returns True if there were changes (already persisted via
// SaveWindowClasses(ConfigFile, AClasses) inside).
function RunClassManager(var AClasses: TWindowClassArray): boolean;

// simple picker for "open class in new pane": list with
// '1 Local shell' first and the enabled classes afterwards.
// AIndex: -1 = local shell, else index into AClasses. False = canceled.
function RunClassPicker(const AClasses: TWindowClassArray;
  out AIndex: integer): boolean;

type
  // action the profile manager returns to the caller; the dialog does
  // not touch the runtime: activating, capturing the workspace or
  // setting the default profile is executed by the caller
  TProfileAction = (paNone, paActivate, paSaveCurrent, paSetDefault);

// profile manager: list + Activate/Save current/Rename/Set default/
// Delete/Close. Rename and Delete act only on user profiles and persist
// via SaveProfiles(ConfigFile, AProfiles) inside; Activate/Save current/
// Set default return True immediately with AAction/ATarget so that
// the caller acts. AActive = row with the active mark (-1 none),
// ADefault = default profile (-1 none). False = closed with no changes
// or action; True with AAction=paNone = only persisted edits happened.
function RunProfileManager(var AProfiles: TProfileArray;
  AActive, ADefault: integer; out AAction: TProfileAction;
  out ATarget: integer): boolean;

type
  // result of the detached session picker
  TSessionPickAction = (spCancel, spAttach, spStartNew);

// detached session picker. Enumerates and re-enumerates the sessions
// ITSELF (st_server.EnumerateSessions) on each pass of the rebuild
// loop. AllowStartNew=True adds the 'Start new'/'Nueva
// sesion' button (normal start); with False that button is
// 'Cancel'/'Cancelar'. spAttach -> ASocketPath = chosen socket.
// Alt+0 pane list (like the classic IDE's Window|List): returns
// True and the chosen index; the caller focuses or restores
function RunPaneList(const ATitles: TStrArray; ACurrent: integer;
  out ASelected: integer): boolean;

// Pick one of the ten client-local clipboard entries, newest first.
function RunClipboardHistory(AHistory: TClipboardHistory;
  out ASelected: integer): boolean;

// Desktop colour: a visual picker over the sixteen text-mode colours.
// AColor is both the colour to start on and, on True, the one chosen.
function RunDesktopColorPick(var AColor: integer): boolean;

function RunSessionPicker(AllowStartNew: boolean;
  out ASocketPath: string): TSessionPickAction;

implementation

const
  // local commands for the manager buttons (>255: always
  // enabled); each manager uses its own contiguous range
  cmClsNew  = 3300;
  cmClsEdit = 3301;
  cmClsDup  = 3302;
  cmClsDel  = 3303;
  cmPrfActivate = 3310;
  cmPrfSave     = 3311;
  cmPrfRename   = 3312;
  cmPrfDefault  = 3313;
  cmPrfDelete   = 3314;
  cmSesAttach   = 3320;
  cmSesDelete   = 3321;

type
  TNameArray = array of string;
  PNameArray = ^TNameArray;

  // generic manager: the action buttons end the dialog with their
  // command (range CmdLo..CmdHi) and the caller's loop decides; double
  // click or space on the list is equivalent to the SelectCmd command
  PManagerDialog = ^TManagerDialog;
  TManagerDialog = object(TDialog)
    CmdLo, CmdHi: word;
    SelectCmd: word;
    procedure HandleEvent(var Event: TEvent); virtual;
  end;

  // picker: double click on the list is equivalent to the Open button
  PPickerDialog = ^TPickerDialog;
  TPickerDialog = object(TDialog)
    procedure HandleEvent(var Event: TEvent); virtual;
  end;

  // one-class editor; Valid(cmOK) validates and shows the error without
  // closing. OtherNames points to a local variable of the caller (only
  // alive during the modal ExecView): other class names for uniqueness.
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
    ColsLine: PInputLine;
    RowsLine: PInputLine;
    TitleLine: PInputLine;
    TypeRadio: PRadioButtons;
    EnabledBox: PCheckBoxes;
    OtherNames: PNameArray;
    function Valid(Command: Word): Boolean; virtual;
  end;

{ ------------------------------ utilities ------------------------------ }

// direct read of the TInputLine buffer (Data^ is a ShortString)
function LineText(P: PInputLine): string;
begin
  Result := '';
  if (P <> nil) and (P^.Data <> nil) then
    Result := P^.Data^;
end;

// write truncated to MaxLen: the internal buffer is MaxLen+1 bytes and
// the ShortString assignment would copy up to 255 without this cut
procedure SetLineText(P: PInputLine; const S: string);
begin
  if (P <> nil) and (P^.Data <> nil) then
    P^.Data^ := Copy(S, 1, P^.MaxLen);
end;

// MessageBox runs the text through FormatStr, which interprets '%':
// double it so class names with '%' do not break (or hang) formatting
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

// rectangle centered on the desktop, clipped if it does not fit
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

// mirror of st_wclass's private DeriveKind: connect wins over host
function DerivedKind(const C: TWindowClass): TWClassKind;
begin
  if C.Connect <> '' then
    Result := wcCommand
  else if C.Host <> '' then
    Result := wcSSH
  else
    Result := wcLocal;
end;

// type text for the list, fixed in both languages (do not translate)
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

// free name for the duplicate: base-2, base-3, ...
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
  S := Trim(LineText(ColsLine));
  if S <> '' then
  begin
    V := StrToIntDef(S, -1);
    if (V < 0) or (V > MAX_WIN_COLS) then
    begin
      ErrorBox(Format(UiText('Invalid width (0..%d).',
        'Ancho invalido (0..%d).'), [MAX_WIN_COLS]));
      Exit(False);
    end;
  end;
  S := Trim(LineText(RowsLine));
  if S <> '' then
  begin
    V := StrToIntDef(S, -1);
    if (V < 0) or (V > MAX_WIN_ROWS) then
    begin
      ErrorBox(Format(UiText('Invalid height (0..%d).',
        'Alto invalido (0..%d).'), [MAX_WIN_ROWS]));
      Exit(False);
    end;
  end;
end;

// modal editor for one class; SkipIndex = index of C in AllClasses to
// exclude it from uniqueness (-1 if new). True if the user accepted and
// C was updated (with Kind re-derived).
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
    // insertion order = reverse order of initial focus: in this fork
    // the last selectable control inserted gets focus on execution
    // (NEVER call Select before ExecView: it poisons the app's focus
    // chain if the dialog runs during Init). Buttons first and
    // the Name field last so it starts focused.
    NewButton(20, 15, 10, 2, 'OK', cmOK, hcNoContext, bfDefault);
    NewButton(34, 15, 12, 2, UiText('Cancel', 'Cancelar'), cmCancel,
      hcNoContext, bfNormal);
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
    TitleLine := NewInputLine(22, 13, 41, 40, hcNoContext, nil);
    NewLabel(2, 13, UiText('Default title', 'Titulo por defecto'), TitleLine);
    ColsLine := NewInputLine(22, 14, 7, 4, hcNoContext, nil);
    NewLabel(2, 14, UiText('Window size', 'Tamano ventana'), ColsLine);
    R.Assign(30, 14, 32, 15);
    Insert(New(PStaticText, Init(R, 'x')));
    RowsLine := NewInputLine(32, 14, 7, 4, hcNoContext, nil);
    R.Assign(41, 14, 63, 15);
    Insert(New(PStaticText, Init(R,
      UiText('(cells, 0 = automatic)', '(celdas, 0 = automatico)'))));
    // Name last: initial focus (coordinates are absolute, the
    // insertion order does not change the layout)
    NameLine := NewInputLine(22, 1, 25, 40, hcNoContext, nil);
    NewLabel(2, 1, UiText('Name', 'Nombre'), NameLine);

    // initial values
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
    if C.Cols > 0 then
      SetLineText(ColsLine, IntToStr(C.Cols));
    if C.Rows > 0 then
      SetLineText(RowsLine, IntToStr(C.Rows));
    SetLineText(TitleLine, C.Title);
    W := Sw_Word(Ord(C.Kind));   // preselection of the derived type
    TypeRadio^.SetData(W);
    W := 0;
    if C.Enabled then
      W := 1;
    EnabledBox^.SetData(W);
  end;

  if Desktop^.ExecView(D) = cmOK then
  begin
    // read the fields before Dispose (the buffers live in the views)
    C.Name := Trim(LineText(D^.NameLine));
    C.Host := Trim(LineText(D^.HostLine));
    C.Port := StrToIntDef(Trim(LineText(D^.PortLine)), 0);
    C.User := Trim(LineText(D^.UserLine));
    C.Password := LineText(D^.PassLine);   // no Trim: may contain spaces
    C.KeyFile := Trim(LineText(D^.KeyLine));
    C.Connect := Trim(LineText(D^.ConnectLine));
    C.PostConnect := Trim(LineText(D^.PostLine));
    C.Cmd := Trim(LineText(D^.CmdLine));
    C.Cwd := Trim(LineText(D^.CwdLine));
    C.Shell := Trim(LineText(D^.ShellLine));
    C.Title := Trim(LineText(D^.TitleLine));
    S := Trim(LineText(D^.ScrollLine));
    if S = '' then
      C.ScrollBack := DEFAULT_SCROLLBACK
    else
      C.ScrollBack := StrToIntDef(S, DEFAULT_SCROLLBACK);
    C.Cols := StrToIntDef(Trim(LineText(D^.ColsLine)), 0);
    C.Rows := StrToIntDef(Trim(LineText(D^.RowsLine)), 0);
    W := 0;
    D^.EnabledBox^.GetData(W);
    C.Enabled := (W and 1) <> 0;
    W := 0;
    D^.TypeRadio^.GetData(W);
    // consistency with the chosen type: command keeps connect and clears
    // host; ssh clears connect; local clears both (Kind derives from it)
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

{ ------------------------------ manager ------------------------------ }

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
        EndModal(SelectCmd);   // double click / space
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

// builds and runs the manager dialog; returns the final command.
// FocusRow comes in as the row to focus and leaves with the row focused
// at close (-1 if the list is empty), to keep selection across passes.
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
  // the collection is a TSortedCollection: AtInsert at the end keeps the
  // array order (Insert would sort alphabetically and drop duplicates)
  Coll := New(PStringCollection, Init(Length(AClasses) + 1, 8));
  for i := 0 to High(AClasses) do
    Coll^.AtInsert(Coll^.Count, Objects.NewStr(ManagerRow(AClasses[i])));

  R := CenteredRect(70, 18);
  D := New(PManagerDialog, Init(R,
    UiText('Window classes', 'Clases de ventana')));
  with D^ do
  begin
    CmdLo := cmClsNew;
    CmdHi := cmClsDel;
    SelectCmd := cmClsEdit;   // double click = edit
    R.Assign(3, 1, 67, 2);
    Insert(New(PStaticText, Init(R, Format('%-18s %-8s %-24s',
      [UiText('Name', 'Nombre'), UiText('Type', 'Tipo'),
       UiText('Target', 'Destino')]))));
    // buttons BEFORE the listbox: the last selectable control inserted
    // gets the initial focus (fork rule: no Select before ExecView)
    NewButton(3, 14, 10, 2, UiText('New', 'Nuevo'), cmClsNew,
      hcNoContext, bfNormal);
    NewButton(14, 14, 10, 2, UiText('Edit', 'Editar'), cmClsEdit,
      hcNoContext, bfDefault);   // Enter = edit
    NewButton(25, 14, 13, 2, UiText('Duplicate', 'Duplicar'), cmClsDup,
      hcNoContext, bfNormal);
    NewButton(39, 14, 10, 2, UiText('Delete', 'Borrar'), cmClsDel,
      hcNoContext, bfNormal);
    NewButton(50, 14, 10, 2, UiText('Close', 'Cerrar'), cmCancel,
      hcNoContext, bfNormal);
    R.Assign(66, 2, 67, 12);
    SB := New(PScrollBar, Init(R));
    Insert(SB);
    R.Assign(3, 2, 66, 12);
    LB := New(PListBox, Init(R, 1, SB));
    Insert(LB);
    LB^.NewList(Coll);
    if (FocusRow > 0) and (FocusRow < Coll^.Count) then
      LB^.FocusItem(FocusRow);
  end;
  Result := Desktop^.ExecView(D);
  if Coll^.Count > 0 then
    FocusRow := LB^.Focused
  else
    FocusRow := -1;
  Dispose(D, Done);
  // the listbox does NOT free the collection in Done (only NewList frees
  // the previous one): free it here after destroying the dialog
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
    Idx := FocusRow;   // rows map 1:1 to AClasses
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

{ ------------------------------ picker ------------------------------ }

procedure TPickerDialog.HandleEvent(var Event: TEvent);
begin
  inherited HandleEvent(Event);
  if (Event.What = evBroadcast) and
     (Event.Command = cmListItemSelected) then
  begin
    EndModal(cmOK);   // double click / space = open
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
  Coll^.AtInsert(0, Objects.NewStr('1 ' + UiText('Local shell', 'Shell local')));
  for i := 0 to High(AClasses) do
    if AClasses[i].Enabled then
    begin
      n := Coll^.Count + 1;      // visible row number (1..9, then none)
      if n <= 9 then
        Prefix := IntToStr(n) + ' '
      else
        Prefix := '  ';
      Coll^.AtInsert(Coll^.Count, Objects.NewStr(Prefix + Copy(AClasses[i].Name, 1, 36)));
    end;

  R := CenteredRect(46, 14);
  D := New(PPickerDialog, Init(R,
    UiText('Open class in new pane', 'Abrir clase en panel nuevo')));
  with D^ do
  begin
    // buttons BEFORE the listbox: the last selectable control inserted
    // gets the initial focus (fork rule: no Select before ExecView)
    NewButton(8, 10, 12, 2, UiText('Open', 'Abrir'), cmOK,
      hcNoContext, bfDefault);
    NewButton(24, 10, 12, 2, UiText('Cancel', 'Cancelar'), cmCancel,
      hcNoContext, bfNormal);
    R.Assign(42, 1, 43, 9);
    SB := New(PScrollBar, Init(R));
    Insert(SB);
    R.Assign(2, 1, 42, 9);
    LB := New(PListBox, Init(R, 1, SB));
    Insert(LB);
    LB^.NewList(Coll);
  end;

  if Desktop^.ExecView(D) = cmOK then
  begin
    Row := LB^.Focused;
    if Row = 0 then
    begin
      AIndex := -1;              // local shell
      Result := True;
    end
    else
    begin
      // row k -> k-th enabled class (disabled ones are not listed)
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

{ -------------------------- profile manager -------------------------- }

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

// manager row: active mark + name + number of windows +
// default profile tag
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

// builds and runs the profile manager dialog; returns the final
// command. With an empty list it shows an informational row and
// disables every button except Close (creating profiles belongs to
// the 'Save as profile' menu, not to this dialog). FocusRow as in
// ExecClassManager: row to focus in, focused row out (-1 if empty).
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
      Objects.NewStr(ProfileRow(AProfiles[i], i = AActive, i = ADefault)));
  if Coll^.Count = 0 then
    Coll^.AtInsert(0, Objects.NewStr(UiText('(no profiles yet)',
      '(aun no hay perfiles)')));

  R := CenteredRect(60, 16);
  D := New(PManagerDialog, Init(R, UiText('Profiles', 'Perfiles')));
  with D^ do
  begin
    CmdLo := cmPrfActivate;
    CmdHi := cmPrfDelete;
    SelectCmd := cmPrfActivate;   // double click = activate
    // buttons BEFORE the listbox: the last selectable control inserted
    // gets the initial focus (fork rule: no Select before ExecView)
    Btn[0] := NewButton(3, 9, 12, 2, UiText('Activate', 'Activar'),
      cmPrfActivate, hcNoContext, bfDefault);   // Enter = activate
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
    R.Assign(56, 1, 57, 8);
    SB := New(PScrollBar, Init(R));
    Insert(SB);
    R.Assign(3, 1, 56, 8);
    LB := New(PListBox, Init(R, 1, SB));
    Insert(LB);
    LB^.NewList(Coll);
    if (FocusRow > 0) and (FocusRow < Coll^.Count) then
      LB^.FocusItem(FocusRow);
  end;
  Result := Desktop^.ExecView(D);
  if Length(AProfiles) > 0 then
    FocusRow := LB^.Focused
  else
    FocusRow := -1;
  Dispose(D, Done);
  // same ownership as in the class manager: the collection is not the
  // listbox's, free it after destroying the dialog
  Dispose(Coll, Done);
end;

// rename with a prefilled InputBox; validates non-empty and uniqueness
// case-insensitively; persists on accept. False = canceled or no
// effective change.
function RenameProfile(var AProfiles: TProfileArray; Idx: integer): boolean;
var
  Buf: ShortString;   // InputBox requires var ShortString (msgbox unit)
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
    Exit;   // no change: do not persist or count as an edit
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
    FocusRow := AActive;   // start on the active profile
  repeat
    Cmd := ExecProfileManager(AProfiles, AActive, ADefault, FocusRow);
    Idx := FocusRow;   // rows map 1:1 to AProfiles
    if (Idx >= 0) and (Idx <= High(AProfiles)) then
      case Cmd of
        cmPrfActivate:
          begin
            // activation is executed by the caller
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
            // capture and save are executed by the caller
            AAction := paSaveCurrent;
            ATarget := Idx;
            Exit(True);
          end;
        cmPrfDefault:
          begin
            // the default lives in the config, not in the array: the
            // caller updates it (Cfg.DefaultProfile + SaveConfig)
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
            // readjust the active/default marks for the next
            // passes of the dialog (visual effect only)
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
  // closed with no action: Result is True only if there were edits (paNone)
end;

{ ------------------ detached session picker ------------------ }

function SessionRow(const S: TSessionInfo): string;
begin
  // legacy rows: the server sends Name='(sin nombre)' and empty profile
  Result := Format('%-20s %-14s %5d  %s',
    [Copy(S.Name, 1, 20), Copy(S.Profile, 1, 14), S.PaneCount, S.Created]);
end;

// builds and runs one pass of the dialog; returns the final command.
// FocusRow as in the managers: row to focus in, focused row out.
function ExecSessionPicker(const Infos: TSessionInfoArray;
  AllowStartNew: boolean; var FocusRow: integer): word;
var
  D: PManagerDialog;
  LB: PListBox;
  SB: PScrollBar;
  Coll: PStringCollection;
  R: TRect;
  i: integer;
  ThirdCaption: string;
begin
  Coll := New(PStringCollection, Init(Length(Infos) + 1, 8));
  for i := 0 to High(Infos) do
    Coll^.AtInsert(Coll^.Count, Objects.NewStr(SessionRow(Infos[i])));

  R := CenteredRect(66, 16);
  D := New(PManagerDialog, Init(R,
    UiText('Detached sessions', 'Sesiones separadas')));
  with D^ do
  begin
    CmdLo := cmSesAttach;
    CmdHi := cmSesDelete;
    SelectCmd := cmSesAttach;   // double click = attach
    R.Assign(3, 1, 63, 2);
    Insert(New(PStaticText, Init(R, Format('%-20s %-14s %5s  %s',
      [UiText('Name', 'Nombre'), UiText('Profile', 'Perfil'),
       UiText('Panes', 'Paneles'), UiText('Created', 'Creada')]))));
    if AllowStartNew then
      ThirdCaption := UiText('Start new', 'Nueva sesion')
    else
      ThirdCaption := UiText('Cancel', 'Cancelar');
    // buttons BEFORE the listbox: the last selectable control inserted
    // gets the initial focus (fork rule: no Select before ExecView)
    NewButton(3, 12, 12, 2, UiText('Attach', 'Conectar'), cmSesAttach,
      hcNoContext, bfDefault);   // Enter = attach
    NewButton(17, 12, 12, 2, UiText('Delete', 'Eliminar'), cmSesDelete,
      hcNoContext, bfNormal);
    // Esc delivers cmCancel: always equivalent to this third button
    NewButton(31, 12, 16, 2, ThirdCaption, cmCancel, hcNoContext, bfNormal);
    R.Assign(62, 2, 63, 10);
    SB := New(PScrollBar, Init(R));
    Insert(SB);
    R.Assign(3, 2, 62, 10);
    LB := New(PListBox, Init(R, 1, SB));
    Insert(LB);
    LB^.NewList(Coll);
    if (FocusRow > 0) and (FocusRow < Coll^.Count) then
      LB^.FocusItem(FocusRow);
  end;
  Result := Desktop^.ExecView(D);
  if Coll^.Count > 0 then
    FocusRow := LB^.Focused
  else
    FocusRow := -1;
  Dispose(D, Done);
  // the collection is not the listbox's: free after destroying the dialog
  Dispose(Coll, Done);
end;

type
  // Enter/space/double click on the pane list are equivalent to 'Go to'
  PPaneListDialog = ^TPaneListDialog;
  TPaneListDialog = object(TDialog)
    procedure HandleEvent(var Event: TEvent); virtual;
  end;

procedure TPaneListDialog.HandleEvent(var Event: TEvent);
begin
  inherited HandleEvent(Event);
  if (Event.What = evBroadcast) and
     (Event.Command = cmListItemSelected) then
  begin
    EndModal(cmOK);
    ClearEvent(Event);
  end;
end;

// Alt+0 pane list: simple selection over already formatted titles
function RunPaneList(const ATitles: TStrArray; ACurrent: integer;
  out ASelected: integer): boolean;
var
  D: PPaneListDialog;
  R: Objects.TRect;
  LB: PListBox;
  SB: PScrollBar;
  Col: PStringCollection;
  I, C: integer;
begin
  Result := False;
  ASelected := -1;
  if Length(ATitles) < 1 then
    Exit;
  R.Assign(0, 0, 46, 8 + Length(ATitles));
  if R.B.Y > 20 then
    R.B.Y := 20;
  D := New(PPaneListDialog, Init(R, UiText('Pane list', 'Lista de paneles')));
  D^.Options := D^.Options or ofCentered;
  with D^ do
  begin
    // buttons first: the last control inserted (the list) gets focus
    NewButton(8, Size.Y - 3, 12, 2, UiText('~G~o to', '~I~r a'), cmOK,
      hcNoContext, bfDefault);
    NewButton(26, Size.Y - 3, 12, 2, UiText('Cancel', 'Cancelar'), cmCancel,
      hcNoContext, bfNormal);
    R.Assign(Size.X - 3, 2, Size.X - 2, Size.Y - 4);
    SB := New(PScrollBar, Init(R));
    Insert(SB);
    R.Assign(2, 2, Size.X - 3, Size.Y - 4);
    LB := New(PListBox, Init(R, 1, SB));
    Col := New(PStringCollection, Init(Length(ATitles), 4));
    for I := 0 to High(ATitles) do
      Col^.AtInsert(I, Objects.NewStr(ATitles[I]));
    LB^.NewList(Col);
    if (ACurrent >= 0) and (ACurrent < Length(ATitles)) then
      LB^.FocusItem(ACurrent);
    Insert(LB);
  end;
  C := Desktop^.ExecView(D);
  if C = cmOK then
  begin
    ASelected := LB^.Focused;
    Result := (ASelected >= 0) and (ASelected < Length(ATitles));
  end;
  LB^.NewList(nil); // NewList(nil) frees the previous collection
  Dispose(D, Done);
end;

function RunClipboardHistory(AHistory: TClipboardHistory;
  out ASelected: integer): boolean;
var
  D: PPaneListDialog;
  R: Objects.TRect;
  LB: PListBox;
  SB: PScrollBar;
  Col: PStringCollection;
  It: TClipboardItem;
  I, C: integer;
  Source, RowText: string;
begin
  Result := False;
  ASelected := -1;
  if (AHistory = nil) or (AHistory.Count < 1) then
    Exit;
  R.Assign(0, 0, 70, 8 + AHistory.Count);
  if R.B.Y > 20 then R.B.Y := 20;
  D := New(PPaneListDialog, Init(R,
    UiText('Clipboard history', 'Historial del portapapeles')));
  D^.Options := D^.Options or ofCentered;
  with D^ do
  begin
    NewButton(18, Size.Y - 3, 12, 2, UiText('~P~aste', '~P~egar'), cmOK,
      hcNoContext, bfDefault);
    NewButton(38, Size.Y - 3, 12, 2, UiText('Cancel', 'Cancelar'), cmCancel,
      hcNoContext, bfNormal);
    R.Assign(Size.X - 3, 2, Size.X - 2, Size.Y - 4);
    SB := New(PScrollBar, Init(R));
    Insert(SB);
    R.Assign(2, 2, Size.X - 3, Size.Y - 4);
    LB := New(PListBox, Init(R, 1, SB));
    Col := New(PStringCollection, Init(AHistory.Count, 4));
    for I := 0 to AHistory.Count - 1 do
    begin
      It := AHistory.Item(I);
      case It.Origin of
        coPaneSelection: Source := UiText('pane', 'panel');
        coHostPaste: Source := UiText('host', 'host');
        coRemoteOsc52: Source := 'OSC52';
      else
        Source := '';
      end;
      RowText := Format('%2d  %-6s  %s',
        [I + 1, Source, AHistory.Preview(I, 50)]);
      Col^.AtInsert(I, Objects.NewStr(RowText));
    end;
    LB^.NewList(Col);
    LB^.FocusItem(0);
    Insert(LB);
  end;
  C := Desktop^.ExecView(D);
  if C = cmOK then
  begin
    ASelected := LB^.Focused;
    Result := (ASelected >= 0) and (ASelected < AHistory.Count);
  end;
  LB^.NewList(nil);
  Dispose(D, Done);
end;


type
  // The sixteen text-mode colours as swatches, two rows of eight. Drawn with
  // raw attributes rather than through the palette chain: the whole point is
  // to show the colours themselves, not the dialog's idea of them.
  PColorGrid = ^TColorGrid;
  TColorGrid = object(TView)
    Color: integer;
    constructor Init(var Bounds: Objects.TRect; AColor: integer);
    procedure Draw; virtual;
    procedure HandleEvent(var Event: TEvent); virtual;
  end;

const
  CG_COLS = 8;                  // swatches across
  CG_CELL = 5;                  // cells per swatch
  CG_ROWS = 2;                  // swatches down
  CG_HIGH = 2;                  // rows per swatch

constructor TColorGrid.Init(var Bounds: Objects.TRect; AColor: integer);
begin
  inherited Init(Bounds);
  Options := Options or ofSelectable or ofFirstClick;
  EventMask := EventMask or evMouseMove;
  Color := AColor;
  if (Color < 0) or (Color > 15) then
    Color := 0;
end;

procedure TColorGrid.Draw;
var
  B: TDrawBuffer;
  y, x, sw, col, row: integer;
  Attr: byte;
  Mark: char;
begin
  for y := 0 to Size.Y - 1 do
  begin
    row := y div CG_HIGH;
    B := Default(TDrawBuffer);
    MoveChar(B, ' ', 0, Size.X);
    for x := 0 to Size.X - 1 do
    begin
      col := x div CG_CELL;
      if (col >= CG_COLS) or (row >= CG_ROWS) then
        Continue;
      sw := row * CG_COLS + col;
      // the swatch is its own colour as background; the marker on the chosen
      // one is drawn in whatever contrasts with it
      Attr := byte(sw shl 4);
      if sw < 8 then
        Attr := Attr or $0F
      else
        Attr := Attr or $00;
      Mark := ' ';
      if (sw = Color) and (x mod CG_CELL = CG_CELL div 2) and
         (y mod CG_HIGH = 0) then
        Mark := #254;                  { the solid square marker }
      MoveChar(B[x], Mark, Attr, 1);
    end;
    WriteLine(0, y, Size.X, 1, B);
  end;
end;

procedure TColorGrid.HandleEvent(var Event: TEvent);
var
  P: Objects.TPoint;
  sw, col, row: integer;
begin
  inherited HandleEvent(Event);
  case Event.What of
    evMouseDown:
      begin
        P := Default(Objects.TPoint);
        MakeLocal(Event.Where, P);
        col := P.X div CG_CELL;
        row := P.Y div CG_HIGH;
        if (col >= 0) and (col < CG_COLS) and (row >= 0) and (row < CG_ROWS) then
        begin
          sw := row * CG_COLS + col;
          if sw <> Color then
          begin
            Color := sw;
            DrawView;
          end;
          if Event.Double then
          begin
            Event.What := evCommand;
            Event.Command := cmOK;
            PutEvent(Event);
          end;
        end;
        ClearEvent(Event);
      end;
    evKeyDown:
      begin
        sw := Color;
        case Event.KeyCode of
          kbLeft:  if sw > 0 then Dec(sw);
          kbRight: if sw < 15 then Inc(sw);
          kbUp:    if sw >= CG_COLS then Dec(sw, CG_COLS);
          kbDown:  if sw < CG_COLS then Inc(sw, CG_COLS);
        else
          Exit;
        end;
        Color := sw;
        DrawView;
        ClearEvent(Event);
      end;
  end;
end;

// Desktop colour: swatches, a live sample, OK/Cancel.
function RunDesktopColorPick(var AColor: integer): boolean;
var
  D: PDialog;
  R: Objects.TRect;
  G: PColorGrid;
  C: word;
begin
  Result := False;
  R.Assign(0, 0, 48, 13);
  D := New(PDialog, Init(R, UiText('Desktop colour',
    'Color del escritorio')));
  D^.Options := D^.Options or ofCentered;
  with D^ do
  begin
    R.Assign(3, 2, 45, 3);
    Insert(New(PStaticText, Init(R, UiText(
      'The colour behind the windows.',
      'El color tras las ventanas.'))));
    NewButton(10, 10, 12, 2, 'OK', cmOK, hcNoContext, bfDefault);
    NewButton(26, 10, 12, 2, UiText('Cancel', 'Cancelar'), cmCancel,
      hcNoContext, bfNormal);
    R.Assign(4, 4, 4 + CG_COLS * CG_CELL, 4 + CG_ROWS * CG_HIGH);
    G := New(PColorGrid, Init(R, AColor));
    Insert(G);
  end;
  C := Desktop^.ExecView(D);
  if C = cmOK then
  begin
    AColor := G^.Color;
    Result := True;
  end;
  Dispose(D, Done);
end;

function RunSessionPicker(AllowStartNew: boolean;
  out ASocketPath: string): TSessionPickAction;
var
  Infos: TSessionInfoArray;
  Cmd: word;
  Idx, FocusRow, i: integer;
begin
  ASocketPath := '';
  if AllowStartNew then
    Result := spStartNew
  else
    Result := spCancel;
  Infos := Default(TSessionInfoArray);
  FocusRow := 0;
  repeat
    // re-enumerate on each pass: purges orphans and reflects closures;
    // with no sessions no dialog is shown (third button action)
    if not EnumerateSessions(Infos) then
      Exit;
    // inside a pane, the session this pane belongs to (and its ancestors)
    // are not offered: attaching to them is the mirror that never ends
    KeepAllowedSessions(Infos);
    if Length(Infos) = 0 then
      Exit;
    Cmd := ExecSessionPicker(Infos, AllowStartNew, FocusRow);
    Idx := FocusRow;   // rows map 1:1 to Infos
    case Cmd of
      cmSesAttach:
        if (Idx >= 0) and (Idx <= High(Infos)) then
        begin
          ASocketPath := Infos[Idx].SocketPath;
          Exit(spAttach);
        end;
      cmSesDelete:
        if (Idx >= 0) and (Idx <= High(Infos)) then
          if ConfirmYes(Format(UiText(
            'Close session "%s"? Its programs will be terminated.',
            'Cerrar la sesion "%s"? Sus programas terminaran.'),
            [Infos[Idx].Name])) then
          begin
            CloseSessionAt(Infos[Idx].SocketPath);
            // brief wait for the server to die; the re-enumeration of
            // the next pass purges the socket and its sidecar
            for i := 1 to 10 do
            begin
              if not SessionIsLive(Infos[Idx].SocketPath) then
                Break;
              Sleep(100);
            end;
            if FocusRow > 0 then
              Dec(FocusRow);
          end;
    else
      Exit;   // Esc or third button (cmCancel): default action
    end;
  until False;
end;

end.
