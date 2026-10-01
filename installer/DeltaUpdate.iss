#ifndef DeltaDir
  #define DeltaDir "..\delta"
#endif

#ifndef OutputDir
  #define OutputDir ".."
#endif

#ifndef BaseTag
  #define BaseTag "unknown"
#endif

#ifndef TargetTag
  #define TargetTag "unknown"
#endif

#ifndef UpdateVersion
  #define UpdateVersion "1.0.0.0"
#endif

#define MyAppName "ChatGPT Desktop Local Bridge Update"
#define MyAppPublisher "lvlaksim1"

[Setup]
AppName={#MyAppName}
AppVersion={#UpdateVersion}
AppPublisher={#MyAppPublisher}
CreateAppDir=no
Uninstallable=no
PrivilegesRequired=lowest
OutputDir={#OutputDir}
OutputBaseFilename=ChatGptDesktopLocalBridge-Update-from-{#BaseTag}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
DisableProgramGroupPage=yes
DisableDirPage=yes
CloseApplications=no
RestartApplications=no
SetupLogging=yes
VersionInfoVersion={#UpdateVersion}
VersionInfoCompany={#MyAppPublisher}
VersionInfoDescription=Incremental update {#BaseTag} to {#TargetTag}
VersionInfoProductName={#MyAppName}

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
Source: "{#DeltaDir}\*"; DestDir: "{tmp}\ChatGptDesktopLocalBridgeDelta"; Flags: ignoreversion recursesubdirs createallsubdirs deleteafterinstall

[Code]
procedure CurStepChanged(CurStep: TSetupStep);
var
  ResultCode: Integer;
  PowerShellPath: String;
  ScriptPath: String;
  Params: String;
begin
  if CurStep = ssPostInstall then
  begin
    PowerShellPath := ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe');
    ScriptPath := ExpandConstant('{tmp}\ChatGptDesktopLocalBridgeDelta\Apply-Update.ps1');
    Params := '-NoProfile -ExecutionPolicy Bypass -File "' + ScriptPath + '"';

    if not Exec(PowerShellPath, Params, '', SW_SHOW, ewWaitUntilTerminated, ResultCode) then
      RaiseException('Unable to launch the incremental updater.');

    if ResultCode <> 0 then
      RaiseException(Format('Incremental update failed with exit code %d. No partial update should remain.', [ResultCode]));
  end;
end;
