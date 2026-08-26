; SuperTerm Windows x64 installer.
; Build from the repository root with Inno Setup 6:
;   ISCC.exe packaging\windows\superterm.iss

#define AppVersion "4.2.1"

[Setup]
AppId={{A1B7D1D4-9D37-4A5D-9F4C-6D4B8E4B1E42}
AppName=SuperTerm
AppVersion={#AppVersion}
AppVerName=SuperTerm {#AppVersion}
AppPublisher=SuperTerm
AppPublisherURL=https://github.com/garacil/superterm
AppSupportURL=https://github.com/garacil/superterm
AppUpdatesURL=https://github.com/garacil/superterm/releases
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

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional icons:"

[Files]
Source: "..\..\bin\superterm.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\LICENSE"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\docs\*.md"; DestDir: "{app}\docs"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\..\backgrounds\*.art"; DestDir: "{app}\backgrounds"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\..\examples\superterm.ini.example"; DestDir: "{app}\examples"; Flags: ignoreversion

[Icons]
Name: "{group}\SuperTerm"; Filename: "{app}\superterm.exe"; WorkingDir: "{app}"
Name: "{group}\SuperTerm documentation"; Filename: "{app}\README.md"
Name: "{autodesktop}\SuperTerm"; Filename: "{app}\superterm.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\superterm.exe"; Description: "Launch SuperTerm"; WorkingDir: "{app}"; Flags: postinstall nowait skipifsilent
