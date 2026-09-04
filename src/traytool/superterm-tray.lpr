program supertermtray;

(*
  Author: German Luis Aracil Boned
  Project: superterm - terminal with autologin, splits and sessions
  Program: superterm-tray - Windows notification-area helper

  A detached SuperTerm session keeps running after its window is closed: the
  session server (superterm.exe --session-daemon) owns the shells and outlives
  the client. But the console client has no window of its own to leave in the
  taskbar -- the window belongs to the terminal emulator -- so once it is gone
  there is nothing on screen to show that sessions are still alive or to bring
  one back.

  This tiny GUI program fills that gap. It sits in the notification area and,
  from its icon, lets the user see the live sessions, reopen one in a new
  terminal window, or close one. It shares nothing with the console
  application except the session directory and the superterm.exe next to it;
  it is deliberately a separate executable so the console client stays a pure
  console program.

  It is Windows-only by nature (Shell_NotifyIcon, the notification area). The
  source lives in the shared tree and the Makefile only builds it on Windows,
  the same way src/st_conpty.pas is compiled only there: a GNU/Linux or macOS
  build never sees it.

  Left double-click: attach the one live session, or, with several, open the
  menu. Right-click: a menu with one submenu per session -- Attach, Close --
  plus Exit. Sessions are read straight from the session directory
  (%LOCALAPPDATA%\superterm\sessions\*.sock), the same names the CLI lists.
  Attaching launches Windows Terminal (or a plain console) running
  "superterm attach NAME"; closing runs "superterm kill NAME" with no window.
*)

{$mode objfpc}{$H+}
{$apptype gui}

uses
  Windows, ShellApi, SysUtils, Classes;

const
  WM_TRAYICON = WM_APP + 1;
  TRAY_UID    = 1;
  CMD_EXIT    = 1;
  CMD_ATTACH_BASE = 1000;   // + session index
  CMD_CLOSE_BASE  = 2000;   // + session index
  MAX_SESSIONS = 64;
  NIF_MESSAGE_ = $00000001;
  NIF_ICON_    = $00000002;
  NIF_TIP_     = $00000004;
  NIM_ADD_     = $00000000;
  NIM_DELETE_  = $00000002;
  HWND_MESSAGE_ = HWND(-3);

type
  TSessionNames = array[0..MAX_SESSIONS - 1] of UnicodeString;

var
  GInstance: HINST;
  GWindow: HWND;
  GIcon: HICON;
  GExeDir: UnicodeString;       // directory holding superterm.exe and this tool
  GSessions: TSessionNames;
  GSessionCount: integer;
  GMutex: THandle;

// ---- session discovery ---------------------------------------------------

function SessionsDir: UnicodeString;
var
  Base: UnicodeString;
begin
  Base := UnicodeString(SysUtils.GetEnvironmentVariable('LOCALAPPDATA'));
  if Base = '' then
    Base := UnicodeString(SysUtils.GetEnvironmentVariable('APPDATA'));
  Result := IncludeTrailingPathDelimiter(Base) + 'superterm\sessions';
end;

procedure RefreshSessions;
var
  Find: TWin32FindDataW;
  H: THandle;
  Name: UnicodeString;
begin
  GSessionCount := 0;
  Find := Default(TWin32FindDataW);
  H := FindFirstFileW(PWideChar(SessionsDir + '\*.sock'), Find);
  if H = INVALID_HANDLE_VALUE then
    Exit;
  try
    repeat
      if (Find.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY) = 0 then
      begin
        Name := Find.cFileName;
        if (Length(Name) > 5) and
           (LowerCase(Copy(Name, Length(Name) - 4, 5)) = '.sock') then
        begin
          SetLength(Name, Length(Name) - 5);
          if (Name <> '') and (GSessionCount < MAX_SESSIONS) then
          begin
            GSessions[GSessionCount] := Name;
            Inc(GSessionCount);
          end;
        end;
      end;
    until not FindNextFileW(H, Find);
  finally
    Windows.FindClose(H);
  end;
end;

// ---- launching -----------------------------------------------------------

function SuperTermExe: UnicodeString;
begin
  Result := GExeDir + 'superterm.exe';
end;

// ---- restoring the terminal window's last size, centred ------------------

const
  MONITOR_DEFAULTTONEAREST_ = $00000002;
  SWP_NOSIZE_ = $0001;
  SWP_NOZORDER_ = $0004;
  SWP_NOACTIVATE_ = $0010;

type
  TMonInfo = record
    cbSize: DWORD;
    rcMonitor: TRect;
    rcWork: TRect;
    dwFlags: DWORD;
  end;

function MonitorFromWindow(hWnd: HWND; dwFlags: DWORD): THandle; stdcall;
  external 'user32' name 'MonitorFromWindow';
function GetMonitorInfoW(hMonitor: THandle; var lpmi: TMonInfo): LongBool;
  stdcall; external 'user32' name 'GetMonitorInfoW';

var
  GFindTitle: UnicodeString;
  GFindResult: HWND;

{$push}{$hints off}
// AParam is unused; EnumWindows fixes the signature. GFindTitle/GFindResult
// carry the query and answer.
function FindWindowEnum(AWnd: HWND; AParam: LPARAM): LongBool; stdcall;
var
  Buf: array[0..511] of WideChar;
  I: integer;
begin
  Result := True;
  if not IsWindowVisible(AWnd) then
    Exit;
  for I := 0 to High(Buf) do
    Buf[I] := #0;
  GetWindowTextW(AWnd, @Buf[0], Length(Buf));
  if Pos(GFindTitle, UnicodeString(PWideChar(@Buf[0]))) > 0 then
  begin
    GFindResult := AWnd;
    Result := False;   // stop enumeration
  end;
end;
{$pop}

function FindSessionWindow(const ATitle: UnicodeString): HWND;
begin
  GFindTitle := ATitle;
  GFindResult := 0;
  EnumWindows(@FindWindowEnum, 0);
  Result := GFindResult;
end;

// Read the whole (small) sidecar as bytes through a Unicode path, so no
// AnsiString/UnicodeString conversion of the path is needed.
function ReadFileBytes(const APath: UnicodeString): AnsiString;
var
  H: THandle;
  Sz, Got: DWORD;
begin
  Result := '';
  H := CreateFileW(PWideChar(APath), GENERIC_READ,
    FILE_SHARE_READ or FILE_SHARE_WRITE, nil, OPEN_EXISTING,
    FILE_ATTRIBUTE_NORMAL, 0);
  if H = INVALID_HANDLE_VALUE then
    Exit;
  try
    Sz := GetFileSize(H, nil);
    if (Sz = 0) or (Sz = DWORD($FFFFFFFF)) or (Sz > 1 shl 20) then
      Exit;
    SetLength(Result, Sz);
    Got := 0;
    if ReadFile(H, Result[1], Sz, Got, nil) then
      SetLength(Result, Got)
    else
      Result := '';
  finally
    CloseHandle(H);
  end;
end;

// Read the size hint the daemon wrote to <name>.ini ([terminal] cols/rows).
function ReadTermSize(const AName: UnicodeString; out ACols, ARows: integer): boolean;
var
  Data, Line, Trimmed, Section, Key, Val: AnsiString;
  P, LineEnd, Eq: integer;
begin
  Result := False;
  ACols := 0;
  ARows := 0;
  Data := ReadFileBytes(SessionsDir + '\' + AName + '.ini');
  if Data = '' then
    Exit;
  Section := '';
  P := 1;
  while P <= Length(Data) do
  begin
    LineEnd := P;
    while (LineEnd <= Length(Data)) and (Data[LineEnd] <> #10) do
      Inc(LineEnd);
    Line := Copy(Data, P, LineEnd - P);
    P := LineEnd + 1;
    Trimmed := Trim(Line);   // Trim also drops the trailing #13
    if Trimmed = '' then
      Continue;
    if Trimmed[1] = '[' then
    begin
      Section := LowerCase(Copy(Trimmed, 2, Length(Trimmed) - 2));
      Continue;
    end;
    if Section <> 'terminal' then
      Continue;
    Eq := Pos('=', Trimmed);
    if Eq < 2 then
      Continue;
    Key := LowerCase(Trim(Copy(Trimmed, 1, Eq - 1)));
    Val := Trim(Copy(Trimmed, Eq + 1, Length(Trimmed)));
    if Key = 'cols' then
      ACols := StrToIntDef(Val, 0)
    else if Key = 'rows' then
      ARows := StrToIntDef(Val, 0);
  end;
  Result := (ACols >= 1) and (ARows >= 3);
end;

// Give the freshly opened window a comfortable home: centre it on its monitor,
// or, if it fills almost the whole work area (it was closed maximised), leave
// it maximised. Minimising never shrinks the reported size, so a session
// closed minimised reopens at its normal size, centred.
procedure PlaceWindowNicely(const ATitle: UnicodeString);
var
  H: HWND;
  I, WinW, WinH, WorkW, WorkH, X, Y: integer;
  R: TRect;
  Mon: THandle;
  Mi: TMonInfo;
begin
  H := 0;
  for I := 1 to 12 do
  begin
    H := FindSessionWindow(ATitle);
    if H <> 0 then
      Break;
    Sleep(150);
  end;
  if H = 0 then
    Exit;
  // let wt finish sizing to --size before measuring
  Sleep(250);
  R := Default(TRect);
  if not GetWindowRect(H, R) then
    Exit;
  WinW := R.Right - R.Left;
  WinH := R.Bottom - R.Top;
  Mon := MonitorFromWindow(H, MONITOR_DEFAULTTONEAREST_);
  Mi := Default(TMonInfo);
  Mi.cbSize := SizeOf(Mi);
  if not GetMonitorInfoW(Mon, Mi) then
    Exit;
  WorkW := Mi.rcWork.Right - Mi.rcWork.Left;
  WorkH := Mi.rcWork.Bottom - Mi.rcWork.Top;
  if (WorkW <= 0) or (WorkH <= 0) then
    Exit;
  // Closed maximised: the size hint is near the whole work area. Reopen maximised.
  if (WinW >= (WorkW * 9) div 10) and (WinH >= (WorkH * 9) div 10) then
  begin
    ShowWindow(H, SW_MAXIMIZE);
    Exit;
  end;
  X := Mi.rcWork.Left + (WorkW - WinW) div 2;
  Y := Mi.rcWork.Top + (WorkH - WinH) div 2;
  if X < Mi.rcWork.Left then X := Mi.rcWork.Left;
  if Y < Mi.rcWork.Top then Y := Mi.rcWork.Top;
  SetWindowPos(H, 0, X, Y, 0, 0,
    SWP_NOSIZE_ or SWP_NOZORDER_ or SWP_NOACTIVATE_);
end;

// Open a session in a new terminal window. Windows Terminal when present,
// otherwise superterm in its own console; both run "superterm attach NAME".
procedure AttachSession(const AName: UnicodeString);
var
  WtArgs, Title, SizeOpt: UnicodeString;
  Rc: HINST;
  Cols, Rows: integer;
begin
  Title := 'superterm: ' + AName;
  // Restore the last window size the daemon recorded; a fresh window (not
  // -w -1) is required or wt ignores --size. The window is then centred by
  // PlaceWindowNicely below.
  SizeOpt := '';
  if ReadTermSize(AName, Cols, Rows) then
    SizeOpt := '--size ' + UnicodeString(IntToStr(Cols)) + ',' +
      UnicodeString(IntToStr(Rows)) + ' ';
  WtArgs := SizeOpt + 'new-tab --title "' + Title +
    '" --suppressApplicationTitle -- "' + SuperTermExe + '" attach "' +
    AName + '"';
  Rc := ShellExecuteW(0, 'open', 'wt.exe', PWideChar(WtArgs),
    PWideChar(GExeDir), SW_SHOWNORMAL);
  if Rc <= 32 then
  begin
    // no Windows Terminal: a GUI-launched console app gets its own console
    ShellExecuteW(0, 'open', PWideChar(SuperTermExe),
      PWideChar(UnicodeString('attach "') + AName + '"'),
      PWideChar(GExeDir), SW_SHOWNORMAL);
    Exit;
  end;
  PlaceWindowNicely(Title);
end;

// Close a session with no flashing console: superterm kill NAME, hidden.
procedure CloseSession(const AName: UnicodeString);
var
  Si: Windows.STARTUPINFOW;
  Pi: Windows.PROCESS_INFORMATION;
  Cmd: UnicodeString;
begin
  Cmd := '"' + SuperTermExe + '" kill "' + AName + '"';
  UniqueString(Cmd);
  Si := Default(Windows.STARTUPINFOW);
  Si.cb := SizeOf(Si);
  Pi := Default(Windows.PROCESS_INFORMATION);
  if CreateProcessW(nil, PWideChar(Cmd), nil, nil, False,
       CREATE_NO_WINDOW, nil, PWideChar(GExeDir), Si, Pi) then
  begin
    CloseHandle(Pi.hThread);
    CloseHandle(Pi.hProcess);
  end;
end;

// ---- menu ----------------------------------------------------------------

procedure ShowMenu;
var
  Menu, Sub: HMENU;
  I: integer;
  Pt: TPoint;
begin
  RefreshSessions;
  Menu := CreatePopupMenu;
  if GSessionCount = 0 then
    AppendMenuW(Menu, MF_STRING or MF_GRAYED, 0, '(no sessions)')
  else
    for I := 0 to GSessionCount - 1 do
    begin
      Sub := CreatePopupMenu;
      AppendMenuW(Sub, MF_STRING, CMD_ATTACH_BASE + I, 'Attach');
      AppendMenuW(Sub, MF_STRING, CMD_CLOSE_BASE + I, 'Close');
      AppendMenuW(Menu, MF_STRING or MF_POPUP, UINT_PTR(Sub),
        PWideChar(GSessions[I]));
    end;
  AppendMenuW(Menu, MF_SEPARATOR, 0, nil);
  AppendMenuW(Menu, MF_STRING, CMD_EXIT, 'Exit');
  GetCursorPos(Pt);
  // MSDN: the window must be foreground for the menu to dismiss on click-away.
  SetForegroundWindow(GWindow);
  TrackPopupMenu(Menu, TPM_RIGHTBUTTON, Pt.X, Pt.Y, 0, GWindow, nil);
  PostMessageW(GWindow, WM_NULL, 0, 0);
  DestroyMenu(Menu);
end;

procedure OnCommand(ACmd: integer);
var
  Idx: integer;
begin
  if ACmd = CMD_EXIT then
  begin
    DestroyWindow(GWindow);
    Exit;
  end;
  if (ACmd >= CMD_ATTACH_BASE) and (ACmd < CMD_ATTACH_BASE + MAX_SESSIONS) then
  begin
    Idx := ACmd - CMD_ATTACH_BASE;
    if (Idx >= 0) and (Idx < GSessionCount) then
      AttachSession(GSessions[Idx]);
    Exit;
  end;
  if (ACmd >= CMD_CLOSE_BASE) and (ACmd < CMD_CLOSE_BASE + MAX_SESSIONS) then
  begin
    Idx := ACmd - CMD_CLOSE_BASE;
    if (Idx >= 0) and (Idx < GSessionCount) then
      CloseSession(GSessions[Idx]);
    Exit;
  end;
end;

// A left double-click attaches the only session, or opens the menu when
// there is a choice to make.
procedure OnLeftActivate;
begin
  RefreshSessions;
  if GSessionCount = 1 then
    AttachSession(GSessions[0])
  else
    ShowMenu;
end;

// ---- window --------------------------------------------------------------

function WndProc(AWnd: HWND; AMsg: UINT; AWParam: WPARAM;
  ALParam: LPARAM): LRESULT; stdcall;
begin
  case AMsg of
    WM_TRAYICON:
      begin
        case LOWORD(ALParam) of
          WM_RBUTTONUP: ShowMenu;
          WM_LBUTTONDBLCLK: OnLeftActivate;
        end;
        Result := 0;
      end;
    WM_COMMAND:
      begin
        OnCommand(LOWORD(AWParam));
        Result := 0;
      end;
    WM_DESTROY:
      begin
        PostQuitMessage(0);
        Result := 0;
      end;
  else
    Result := DefWindowProcW(AWnd, AMsg, AWParam, ALParam);
  end;
end;

function LoadTrayIcon: HICON;
begin
  // Reuse the icon embedded in superterm.exe so both binaries look the same.
  Result := ExtractIconW(GInstance, PWideChar(SuperTermExe), 0);
  if (Result = 0) or (Result = 1) then
    Result := LoadIconW(0, PWideChar(PtrUInt(32512)));  // IDI_APPLICATION
end;

procedure AddTrayIcon;
var
  Nid: TNotifyIconDataW;
  Tip: UnicodeString;
  I: integer;
begin
  Nid := Default(TNotifyIconDataW);
  Nid.cbSize := SizeOf(Nid);
  Nid.hWnd := GWindow;
  Nid.uID := TRAY_UID;
  Nid.uFlags := NIF_MESSAGE_ or NIF_ICON_ or NIF_TIP_;
  Nid.uCallbackMessage := WM_TRAYICON;
  Nid.hIcon := GIcon;
  Tip := 'SuperTerm sessions';
  for I := 0 to Length(Tip) - 1 do
    Nid.szTip[I] := WideChar(Tip[I + 1]);
  Shell_NotifyIconW(NIM_ADD_, @Nid);
end;

procedure RemoveTrayIcon;
var
  Nid: TNotifyIconDataW;
begin
  Nid := Default(TNotifyIconDataW);
  Nid.cbSize := SizeOf(Nid);
  Nid.hWnd := GWindow;
  Nid.uID := TRAY_UID;
  Shell_NotifyIconW(NIM_DELETE_, @Nid);
end;

const
  TRAY_CLASS = 'SuperTermTrayWindow';
  TRAY_MUTEX = 'Local\SuperTermTraySingleton';

var
  Wc: TWndClassW;
  Msg: TMsg;
  ExePath: array[0..MAX_PATH] of WideChar;
  I: integer;

begin
  GInstance := GetModuleHandleW(nil);
  for I := 0 to High(ExePath) do ExePath[I] := #0;
  GetModuleFileNameW(0, @ExePath[0], MAX_PATH);
  GExeDir := IncludeTrailingPathDelimiter(ExtractFilePath(UnicodeString(ExePath)));

  // "superterm-tray --attach NAME" reopens one session in a sized, centred
  // window and exits, without touching the tray icon. A shortcut or another
  // launcher can use it; it is also how the behaviour is exercised in tests.
  if (ParamCount >= 2) and (ParamStr(1) = '--attach') then
  begin
    AttachSession(UnicodeString(ParamStr(2)));
    Halt(0);
  end;

  // One tray icon is enough; a second launch just exits.
  GMutex := CreateMutexW(nil, True, TRAY_MUTEX);
  if (GMutex <> 0) and (GetLastError = ERROR_ALREADY_EXISTS) then
  begin
    CloseHandle(GMutex);
    Halt(0);
  end;

  GIcon := LoadTrayIcon;
  GSessionCount := 0;

  Wc := Default(TWndClassW);
  Wc.lpfnWndProc := @WndProc;
  Wc.hInstance := GInstance;
  Wc.lpszClassName := TRAY_CLASS;
  RegisterClassW(@Wc);

  // A message-only window: no taskbar entry, only the tray icon is visible.
  GWindow := CreateWindowExW(0, TRAY_CLASS, 'SuperTerm', 0,
    0, 0, 0, 0, HWND_MESSAGE_, 0, GInstance, nil);
  if GWindow = 0 then
  begin
    if GMutex <> 0 then CloseHandle(GMutex);
    Halt(1);
  end;

  AddTrayIcon;
  Msg := Default(TMsg);
  while GetMessageW(@Msg, 0, 0, 0) do
  begin
    TranslateMessage(Msg);
    DispatchMessageW(Msg);
  end;
  RemoveTrayIcon;
  if GMutex <> 0 then
    CloseHandle(GMutex);
end.
