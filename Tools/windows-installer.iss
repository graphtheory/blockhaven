; The Windows installer, built by CI with Inno Setup from the packaged
; dist/Blockhaven folder:
;
;   iscc /DAppVersion=1.1.232 Tools\windows-installer.iss
;
; The version (VERSION plus the commit count, see GameVersion.swift) is
; what the wizard and Windows' list of installed apps show.
;
; It installs for the current user only, into %LOCALAPPDATA%\Programs, so
; it never asks for an administrator password — a child can run it, and
; run it again to update. Worlds and settings live elsewhere (the worlds
; folder chosen in the game, or the default one under AppData), so
; neither updating nor uninstalling ever touches a save.

#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
; CI also builds an older-numbered installer from a copy of the folder,
; to test the game updating itself.
#ifndef SourceDir
  #define SourceDir "..\dist\Blockhaven"
#endif
#ifndef OutputName
  #define OutputName "Blockhaven-Setup"
#endif

[Setup]
AppId={{6C1E3B8A-4F0D-4E7A-9B52-6A3F1D2C8E41}
AppName=Blockhaven
AppVersion={#AppVersion}
VersionInfoVersion={#AppVersion}
AppPublisher=John Zetterström
DefaultDirName={localappdata}\Programs\Blockhaven
DefaultGroupName=Blockhaven
DisableProgramGroupPage=yes
DisableDirPage=yes
; Installs from before the rename used another folder and Start-menu
; group; the same AppId makes this an upgrade of them, and these keep it
; from reusing either.
UsePreviousAppDir=no
UsePreviousGroup=no
PrivilegesRequired=lowest
OutputDir=..\dist
OutputBaseFilename={#OutputName}
SetupIconFile=..\Assets\Blockhaven.ico
UninstallDisplayIcon={app}\Assets\Blockhaven.ico
UninstallDisplayName=Blockhaven
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; Updating while the game is open would fail to replace the exe.
CloseApplications=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "swedish"; MessagesFile: "compiler:Languages\Swedish.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
; An update replaces everything that was installed, so a file a newer
; build no longer ships does not linger and get loaded by mistake.
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[InstallDelete]
Type: filesandordirs; Name: "{app}\*"
; What the game's earlier name left behind: its program folder and
; shortcuts. Saves live elsewhere and are copied across by the game itself.
Type: filesandordirs; Name: "{localappdata}\Programs\Minecraft Clone"
Type: files; Name: "{userprograms}\Minecraft Clone.lnk"
Type: files; Name: "{userprograms}\Minecraft Clone\Minecraft Clone.lnk"
Type: dirifempty; Name: "{userprograms}\Minecraft Clone"
Type: files; Name: "{userdesktop}\Minecraft Clone.lnk"

[Icons]
Name: "{group}\Blockhaven"; Filename: "{app}\Blockhaven.exe"; IconFilename: "{app}\Assets\Blockhaven.ico"
Name: "{autodesktop}\Blockhaven"; Filename: "{app}\Blockhaven.exe"; IconFilename: "{app}\Assets\Blockhaven.ico"; Tasks: desktopicon

[Run]
Filename: "{app}\Blockhaven.exe"; Description: "{cm:LaunchProgram,Blockhaven}"; Flags: nowait postinstall skipifsilent
; The game updates itself by running this silently and quitting; this
; starts the new version when it is done.
Filename: "{app}\Blockhaven.exe"; Flags: nowait skipifnotsilent
