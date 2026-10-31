; MolidoVPN Windows installer. Built in release.yml: ISCC /DMyVersion=<ver> windows/installer/molido.iss
; Upgrades in place: the AppId below must never change (it keys the uninstall entry and the previous
; install folder). Before copying, PrepareToInstall closes the app and every bundled core and removes the
; AmneziaWG tunnel service, which otherwise keep files in {app} locked ("file in use" -> users had to
; uninstall first). User settings live in %APPDATA% (shared_preferences), not in {app}, so they survive.
#ifndef MyVersion
  #define MyVersion "0.0.0"
#endif

[Setup]
AppId={{8F3C2A1E-6B4D-4F7A-9C1E-2D5B7A9E4C10}
AppName=MolidoVPN
AppVersion={#MyVersion}
AppVerName=MolidoVPN {#MyVersion}
AppPublisher=MolidoVPN
SourceDir=..\..
DefaultDirName={localappdata}\Programs\MolidoVPN
UsePreviousAppDir=yes
DisableDirPage=auto
PrivilegesRequired=lowest
DisableProgramGroupPage=yes
OutputDir=dist
OutputBaseFilename=MolidoVPN-windows-setup
SetupIconFile=windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\mobin_vpn.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=force
RestartApplications=no
SetupMutex=MolidoVPNSetupMutex

[Languages]
Name: "en"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Desktop shortcut"; Flags: checkedonce

[Files]
Source: "build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion

[Icons]
Name: "{autoprograms}\MolidoVPN"; Filename: "{app}\mobin_vpn.exe"
Name: "{autodesktop}\MolidoVPN"; Filename: "{app}\mobin_vpn.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\mobin_vpn.exe"; Description: "Start MolidoVPN"; Flags: nowait postinstall skipifsilent
; In-app update: the updater runs setup /VERYSILENT ... /relaunch=1 and the new version starts by itself.
Filename: "{app}\mobin_vpn.exe"; Flags: nowait; Check: WantRelaunch

[UninstallRun]
Filename: "{sys}\taskkill.exe"; Parameters: "/F /T /IM mobin_vpn.exe"; Flags: runhidden; RunOnceId: "KillApp"

[Code]
const
  AwgService = 'AmneziaWGTunnel$MolidoAWG';

function WantRelaunch: Boolean;
begin
  Result := ExpandConstant('{param:relaunch|0}') = '1';
end;

function ProcList: TArrayOfString;
begin
  SetArrayLength(Result, 8);
  Result[0] := 'mobin_vpn.exe';
  Result[1] := 'sing-box.exe';
  Result[2] := 'xray.exe';
  Result[3] := 'tor.exe';
  Result[4] := 'lyrebird.exe';
  Result[5] := 'psiphon-tunnel-core.exe';
  Result[6] := 'psiphon-tunnel-core-i686.exe';
  Result[7] := 'amneziawg.exe';
end;

function IsRunning(const Name: String): Boolean;
var
  rc: Integer;
begin
  Result := Exec(ExpandConstant('{cmd}'), '/C tasklist /NH /FI "IMAGENAME eq ' + Name + '" | find /I "' + Name + '" >NUL',
    '', SW_HIDE, ewWaitUntilTerminated, rc) and (rc = 0);
end;

function AnyRunning: Boolean;
var
  p: TArrayOfString;
  i: Integer;
begin
  Result := False;
  p := ProcList;
  for i := 0 to GetArrayLength(p) - 1 do
    if IsRunning(p[i]) then begin
      Log('still running: ' + p[i]);
      Result := True;
    end;
end;

function ServiceExists: Boolean;
var
  rc: Integer;
begin
  Result := Exec(ExpandConstant('{sys}\sc.exe'), 'query "' + AwgService + '"', '', SW_HIDE, ewWaitUntilTerminated, rc) and (rc = 0);
end;

function KillCommand: String;
var
  p: TArrayOfString;
  i: Integer;
begin
  Result := 'sc stop "' + AwgService + '" & sc delete "' + AwgService + '"';
  p := ProcList;
  for i := 0 to GetArrayLength(p) - 1 do
    Result := Result + ' & taskkill /F /T /IM ' + p[i];
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  rc: Integer;
begin
  Result := '';
  // 1. As the current user: closes a normally started app and its cores.
  Exec(ExpandConstant('{cmd}'), '/C ' + KillCommand + ' >NUL 2>&1', '', SW_HIDE, ewWaitUntilTerminated, rc);
  Sleep(800);
  // 2. The app elevates itself for TUN mode, so its cores and the AmneziaWG service can be
  //    administrator-owned: one UAC prompt to stop them, only when something is left.
  if AnyRunning or ServiceExists then begin
    Log('elevated cleanup');
    ShellExec('runas', ExpandConstant('{cmd}'), '/C ' + KillCommand, '', SW_HIDE, ewWaitUntilTerminated, rc);
    Sleep(1500);
  end;
  if AnyRunning then
    Result := 'MolidoVPN or one of its connection engines is still running. Close MolidoVPN and run setup again.';
end;
