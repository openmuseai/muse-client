[Setup]
AppName=DSH Office
AppVersion={#AppVersion}
AppPublisher=OpenMuseAI
WizardStyle=modern
Compression=lzma2
SolidCompression=yes
PrivilegesRequired=lowest
DefaultDirName={localappdata}\Programs\DSH Office
DefaultGroupName=DSH Office
UninstallDisplayIcon={app}\dsh-office.exe
UninstallDisplayName=DSH Office
VersionInfoVersion={#AppVersion}
UsePreviousAppDir=no
#ifexist "flowy_logo.ico"
SetupIconFile=flowy_logo.ico
#endif

[Files]
Source: "DSH Office\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{userdesktop}\DSH Office"; Filename: "{app}\dsh-office.exe"
Name: "{group}\DSH Office"; Filename: "{app}\dsh-office.exe"

[Run]
Filename: "{app}\dsh-office.exe"; Description: "Launch DSH Office"; Flags: nowait postinstall skipifsilent

[Registry]
Root: HKCU; Subkey: "Software\Classes\dsh-office"; ValueType: "string"; ValueData: "URL:Custom Protocol"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\dsh-office"; ValueType: "string"; ValueName: "URL Protocol"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\dsh-office\DefaultIcon"; ValueType: "string"; ValueData: "{app}\dsh-office.exe,0"
Root: HKCU; Subkey: "Software\Classes\dsh-office\shell\open\command"; ValueType: "string"; ValueData: """{app}\dsh-office.exe"" ""%1"""
