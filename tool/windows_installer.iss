#define MyAppName "Cwhale"
#ifndef AppVersion
  #define AppVersion "0.1.34"
#endif
#ifndef AppSourceDir
  #define AppSourceDir "..\build\windows\x64\runner\Release"
#endif
#ifndef OutputDir
  #define OutputDir "..\release"
#endif

[Setup]
AppId={{B173BB11-9D92-4DAC-AB24-35EA947C9D8C}
AppName={#MyAppName}
AppVersion={#AppVersion}
AppPublisher=Cwhale
DefaultDirName={localappdata}\Programs\Cwhale
DefaultGroupName=Cwhale
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#OutputDir}
OutputBaseFilename=Cwhale-Setup-{#AppVersion}-x64
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\Cwhale.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
Source: "{#AppSourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Cwhale"; Filename: "{app}\Cwhale.exe"
Name: "{autodesktop}\Cwhale"; Filename: "{app}\Cwhale.exe"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional shortcuts:"; Flags: unchecked

[Run]
Filename: "{app}\Cwhale.exe"; Description: "Launch Cwhale"; Flags: postinstall nowait skipifsilent
