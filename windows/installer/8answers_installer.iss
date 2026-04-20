#define MyAppName "8answers"
#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef SourcePath
  #define SourcePath "..\\build\\windows\\x64\\runner\\Release"
#endif
#ifndef VCRedistPath
  #define VCRedistPath "..\\windows\\installer\\deps\\vc_redist.x64.exe"
#endif
#ifndef OutputDir
  #define OutputDir "."
#endif

[Setup]
AppId={{6D48C16A-BA2F-4DAA-8CF9-E53CC4F4A9A8}
AppName={#MyAppName}
AppVersion={#AppVersion}
AppPublisher=8answers
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir={#OutputDir}
OutputBaseFilename=8answers_v{#AppVersion}-windows-setup
Compression=lzma
SolidCompression=yes
WizardStyle=modern
ArchitecturesInstallIn64BitMode=x64compatible or arm64
ArchitecturesAllowed=x64compatible or arm64
PrivilegesRequired=admin
UninstallDisplayIcon={app}\8answers.exe

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourcePath}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#VCRedistPath}"; DestDir: "{tmp}"; Flags: deleteafterinstall

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\8answers.exe"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\8answers.exe"; Tasks: desktopicon

[Registry]
Root: HKCR; Subkey: "com.example.landmanWebsite"; ValueType: string; ValueName: ""; ValueData: "URL:8answers Protocol"; Flags: uninsdeletekey
Root: HKCR; Subkey: "com.example.landmanWebsite"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""; Flags: uninsdeletevalue
Root: HKCR; Subkey: "com.example.landmanWebsite\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: "{app}\8answers.exe,0"
Root: HKCR; Subkey: "com.example.landmanWebsite\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\8answers.exe"" ""%1"""
Root: HKCR; Subkey: "8answers"; ValueType: string; ValueName: ""; ValueData: "URL:8answers Protocol"; Flags: uninsdeletekey
Root: HKCR; Subkey: "8answers"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""; Flags: uninsdeletevalue
Root: HKCR; Subkey: "8answers\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: "{app}\8answers.exe,0"
Root: HKCR; Subkey: "8answers\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\8answers.exe"" ""%1"""

[Run]
Filename: "{tmp}\vc_redist.x64.exe"; Parameters: "/install /passive /norestart"; \
  StatusMsg: "Installing Microsoft Visual C++ Runtime..."; \
  Flags: waituntilterminated; Check: NeedsVCRuntime
Filename: "{app}\8answers.exe"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; \
  Flags: nowait postinstall skipifsilent

[Code]
function NeedsVCRuntime: Boolean;
var
  InstalledValue: Cardinal;
begin
  Result := True;
  if RegQueryDWordValue(
       HKLM64,
       'SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64',
       'Installed',
       InstalledValue
     ) then
  begin
    Result := InstalledValue <> 1;
  end;
end;
