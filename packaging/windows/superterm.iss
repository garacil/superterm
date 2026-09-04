; SuperTerm Windows x64 installer.
; Build from the repository root with Inno Setup 6:
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
AppPublisher=German Luis Aracil Boned
AppPublisherURL=https://github.com/garacil/superterm
AppSupportURL=https://github.com/garacil/superterm
AppUpdatesURL=https://github.com/garacil/superterm/releases
VersionInfoVersion={#AppVersion}
VersionInfoCompany=German Luis Aracil Boned
VersionInfoDescription=SuperTerm {#AppVersion} setup
VersionInfoCopyright=Copyright (C) 2026 German Luis Aracil Boned. GNU GPL v3.
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
