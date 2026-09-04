; SuperTerm Windows x64 installer.
; Build from the repository root with Inno Setup 6 or 7:
;   ISCC.exe packaging\windows\superterm.iss
;
; Signed build (setup, uninstaller and superterm.exe carry an Authenticode
; signature; see docs/WINDOWS.md, "Code signing and the SmartScreen warning"):
;   ISCC.exe /DSIGN "/Ssuperterm=powershell.exe -NoProfile -ExecutionPolicy Bypass -File packaging\windows\sign.ps1 $f" packaging\windows\superterm.iss
; packaging\windows\release.ps1 -Sign does all of that in one step.

#define AppVersion "5.2.2"
#ifdef SIGN
  #define SignFlag "signonce"
#else
  #define SignFlag ""
#endif

[Setup]
AppId={{A1B7D1D4-9D37-4A5D-9F4C-6D4B8E4B1E42}
AppName=SuperTerm
AppVersion={#AppVersion}
AppVerName=SuperTerm {#AppVersion}
AppPublisher=7kas Servicios Internet, S.L.
AppPublisherURL=https://7ks.ai
AppSupportURL=https://superterm.org
AppUpdatesURL=https://github.com/garacil/superterm/releases
VersionInfoVersion={#AppVersion}
VersionInfoCompany=7kas Servicios Internet, S.L.
VersionInfoDescription=SuperTerm {#AppVersion} setup
VersionInfoCopyright=Copyright (C) 2026 7kas Servicios Internet, S.L. GNU GPL v3.
DefaultDirName={localappdata}\Programs\SuperTerm
DefaultGroupName=SuperTerm
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
OutputDir=..\..\dist
OutputBaseFilename=SuperTerm-{#AppVersion}-windows-x64-setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayIcon={app}\superterm.exe
LicenseFile=..\..\LICENSE
SetupIconFile=alien-hacker.ico
; ConPTY is available from Windows 10 1809 (build 17763).
MinVersion=10.0.17763
; A running SuperTerm loaded from {app} locks superterm.exe. Let the Restart
; Manager offer to close it; the code below also warns about detached sessions
; and force-closes the no-window session server, which the Restart Manager may
; not catch on its own.
CloseApplications=yes
RestartApplications=no
#ifdef SIGN
SignTool=superterm
SignedUninstaller=yes
#endif

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional icons:"

[Files]
Source: "..\..\bin\superterm.exe"; DestDir: "{app}"; Flags: ignoreversion {#SignFlag}
Source: "superterm-launch.cmd"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\LICENSE"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\docs\*.md"; DestDir: "{app}\docs"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\..\backgrounds\*.art"; DestDir: "{app}\backgrounds"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\..\examples\superterm.ini.example"; DestDir: "{app}\examples"; Flags: ignoreversion

[Icons]
Name: "{group}\SuperTerm"; Filename: "{app}\superterm-launch.cmd"; WorkingDir: "{app}"; IconFilename: "{app}\superterm.exe"
Name: "{group}\SuperTerm documentation"; Filename: "{app}\README.md"
Name: "{autodesktop}\SuperTerm"; Filename: "{app}\superterm-launch.cmd"; WorkingDir: "{app}"; IconFilename: "{app}\superterm.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\superterm-launch.cmd"; Description: "Launch SuperTerm"; WorkingDir: "{app}"; Flags: postinstall nowait skipifsilent

[Code]
// A running SuperTerm keeps superterm.exe locked, and the session server is a
// separate superterm.exe --session-daemon with no window that outlives the UI
// and holds its shells. Installing or uninstalling over it must first close
// it, so warn plainly (this ends live sessions), confirm, and only then close.

function SuperTermRunning: Boolean;
var
  Rc: Integer;
begin
  // 'find' returns 0 only when the image appears in the task list.
  Result := Exec(ExpandConstant('{cmd}'),
    '/c tasklist /FI "IMAGENAME eq superterm.exe" /NH | find /I "superterm.exe"',
    '', SW_HIDE, ewWaitUntilTerminated, Rc) and (Rc = 0);
end;

procedure CloseSuperTerm;
var
  Rc: Integer;
begin
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/F /T /IM superterm.exe',
    '', SW_HIDE, ewWaitUntilTerminated, Rc);
  Sleep(700);
end;

// Returns True to proceed, False to abort. Shared by install and uninstall.
// A silent run (the Microsoft Store, and any /SILENT|/VERYSILENT install)
// must never stop on a prompt: there it closes the running instance without
// asking, which is the documented silent-install contract. Only an
// interactive run warns and waits for confirmation.
// ASilent comes from the caller because the two contexts ask different
// functions: WizardSilent belongs to Setup and UninstallSilent to the
// uninstaller, and the Setup one does not report silence while uninstalling.
function ConfirmCloseRunning(const AAction: string; const ASilent: Boolean): Boolean;
begin
  Result := True;
  if not SuperTermRunning then
    Exit;
  if ASilent then
  begin
    CloseSuperTerm;
    Exit;
  end;
  if MsgBox('SuperTerm is running.' + #13#10#13#10 +
       'Any detached sessions and the programs inside them will be closed '
       + 'so Setup can ' + AAction + '.' + #13#10#13#10 +
       'Close SuperTerm and continue?',
       mbConfirmation, MB_YESNO) = IDYES then
    CloseSuperTerm
  else
    Result := False;
end;

function InitializeSetup(): Boolean;
begin
  Result := ConfirmCloseRunning('install this update', WizardSilent);
end;

function InitializeUninstall(): Boolean;
begin
  Result := ConfirmCloseRunning('remove it', UninstallSilent);
end;
