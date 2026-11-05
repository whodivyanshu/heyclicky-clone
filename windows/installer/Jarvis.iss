; The Windows installer. It installs for the current user only and never asks for administrator rights,
; because Jarvis is built to run without them.
[Setup]
AppId={{6F1E2A3B-7C4D-4E5F-8A9B-0C1D2E3F4A5B}
AppName=Jarvis
AppVersion=1.0.0
DefaultDirName={localappdata}\Programs\Jarvis
DefaultGroupName=Jarvis
DisableProgramGroupPage=yes
DisableDirPage=yes
PrivilegesRequired=lowest
OutputDir=..\dist
OutputBaseFilename=Jarvis-Setup
SetupIconFile=..\Jarvis\Assets\Jarvis.ico
UninstallDisplayIcon={app}\Jarvis.exe
Compression=lzma2
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.19041
CloseApplications=yes

[Files]
Source: "..\dist\Jarvis\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion

[Icons]
Name: "{userprograms}\Jarvis"; Filename: "{app}\Jarvis.exe"

[Run]
Filename: "{app}\Jarvis.exe"; Description: "Open Jarvis"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{sys}\taskkill.exe"; Parameters: "/IM Jarvis.exe /F"; Flags: runhidden; RunOnceId: "StopJarvis"

; Removing the app leaves what's in %LOCALAPPDATA%\Jarvis, such as history and settings, since those are the user's.
; Sign-in startup is removed, because it would otherwise point at a missing program.
[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueName: "Jarvis"; ValueType: none; Flags: dontcreatekey uninsdeletevalue
