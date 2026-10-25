; Hibiki for Windows: per-user install (no admin), REAPER first, then `hibiki setup` for this user.
; Built by packaging/windows/build_exe.py, which passes AppVersion, NumVersion, Stage and OutDir.

[Setup]
AppId={{5E3C3B9A-6C2B-4F5B-9D1A-7B6E2F1C9A41}
AppName=Hibiki
AppVersion={#AppVersion}
AppVerName=Hibiki {#AppVersion}
AppPublisher=yiw190
AppPublisherURL=https://github.com/yiw190/hibiki
AppSupportURL=https://github.com/yiw190/hibiki/issues
DefaultDirName={localappdata}\Programs\Hibiki
DisableDirPage=yes
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#OutDir}
OutputBaseFilename=Hibiki-{#AppVersion}-setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
LicenseFile={#Stage}\app\LICENSE
ChangesEnvironment=yes
CloseApplications=no
UninstallDisplayName=Hibiki
VersionInfoVersion={#NumVersion}
SetupLogging=yes

[Messages]
WelcomeLabel2=Hibiki puts AI agents inside REAPER: an MCP server that drives REAPER, the Hibiki panel docked in REAPER, and a gateway for Gamut, Codex, Claude Code and Kimi.%n%nStep 1 - REAPER. It must already be installed (reaper.fm). This installer won't continue without it.%n%nStep 2 - Hibiki. Installs for this Windows user only, no administrator rights needed. Everything listens on 127.0.0.1 only.
FinishedHeadingLabel=Step 3 - restart REAPER
FinishedLabel=Quit REAPER and open it again. From now on the bridge starts with it and the Hibiki panel opens docked on the right. Click the agent name at the top of the panel to pick a provider and model.%n%nStep 4 - connect an agent. Gamut (desktop app): download it from updates.gamutagents.com/download/win, add your Anthropic API key and enable the REAPER MCP for your agent (needs Docker Desktop or Podman). Or a CLI agent: run  hibiki agents add claude kimi  in a terminal, then click Connect in the panel.%n%nCheck everything in a new terminal with: hibiki doctor

[Files]
Source: "{#Stage}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Registry]
Root: HKCU; Subkey: "Environment"; ValueType: expandsz; ValueName: "Path"; ValueData: "{olddata};{app}\bin"; Check: NeedsAddPath(ExpandConstant('{app}\bin'))

[UninstallRun]
Filename: "{app}\python\HibikiConsole.exe"; Parameters: "-s -E ""{app}\app\reaper_mcp\cli.py"" uninstall"; Flags: runhidden waituntilterminated; RunOnceId: "HibikiUninstall"

[UninstallDelete]
Type: filesandordirs; Name: "{app}"

[Code]
function ReaperIn(const Dir: String): Boolean;
begin
  Result := (Dir <> '') and FileExists(AddBackslash(Dir) + 'reaper.exe');
end;

function ReaperInstalled: Boolean;
var
  Dir: String;
begin
  Result := ReaperIn(ExpandConstant('{commonpf64}\REAPER (x64)')) or ReaperIn(ExpandConstant('{commonpf64}\REAPER'))
    or ReaperIn(ExpandConstant('{commonpf32}\REAPER')) or ReaperIn(ExpandConstant('{localappdata}\Programs\REAPER (x64)'));
  if not Result and RegQueryStringValue(HKCU, 'SOFTWARE\REAPER', '', Dir) then Result := ReaperIn(Dir);
  if not Result and RegQueryStringValue(HKLM64, 'SOFTWARE\REAPER', '', Dir) then Result := ReaperIn(Dir);
  if not Result and RegQueryStringValue(HKLM32, 'SOFTWARE\REAPER', '', Dir) then Result := ReaperIn(Dir);
end;

{ onboarding order: REAPER first, then Hibiki; `hibiki setup` refuses the same way }
function InitializeSetup(): Boolean;
begin
  Result := ReaperInstalled;
  if not Result then
    SuppressibleMsgBox('Install REAPER first.' + #13#10 + #13#10 +
      'Hibiki runs inside REAPER, and REAPER is not on this PC yet. Download it from reaper.fm, run its installer, ' +
      'open REAPER once, then run this installer again.', mbCriticalError, MB_OK, IDOK);
end;

{ an upgrade replaces the Hibiki*.exe and python*.exe files: stop the running supervisor (and its children) first }
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  Pid: AnsiString;
  Rc: Integer;
begin
  Result := '';
  if LoadStringFromFile(ExpandConstant('{localappdata}\Hibiki\logs\supervisor.pid'), Pid) and (Trim(String(Pid)) <> '') then
    Exec(ExpandConstant('{sys}\taskkill.exe'), '/PID ' + Trim(String(Pid)) + ' /T /F', '', SW_HIDE, ewWaitUntilTerminated, Rc);
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  Rc: Integer;
  Log: String;
begin
  if CurStep = ssPostInstall then
  begin
    Log := ExpandConstant('{localappdata}\Hibiki\logs\install.log');
    ForceDirectories(ExtractFileDir(Log));
    { HIBIKI_USE_RELEASE: a fresh install leaves `hibiki use dev` and sets everything up from the package }
    if not Exec(ExpandConstant('{cmd}'), '/C "set HIBIKI_USE_RELEASE=1&& "' + ExpandConstant('{app}\python\HibikiConsole.exe') + '" -s -E "' +
        ExpandConstant('{app}\app\reaper_mcp\cli.py') + '" setup > "' + Log + '" 2>&1"', '', SW_HIDE,
        ewWaitUntilTerminated, Rc) or (Rc <> 0) then
      SuppressibleMsgBox('Hibiki setup did not finish (exit code ' + IntToStr(Rc) + '). Details: ' + Log, mbError, MB_OK, IDOK);
  end;
end;

function NeedsAddPath(Param: String): Boolean;
var
  Path: String;
begin
  if not RegQueryStringValue(HKCU, 'Environment', 'Path', Path) then
    Result := True
  else
    Result := Pos(';' + Uppercase(Param) + ';', ';' + Uppercase(Path) + ';') = 0;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  Path, Entry: String;
  P: Integer;
begin
  if CurUninstallStep = usPostUninstall then
    if RegQueryStringValue(HKCU, 'Environment', 'Path', Path) then
    begin
      Entry := ';' + ExpandConstant('{app}\bin');
      P := Pos(Uppercase(Entry), Uppercase(Path));
      if P > 0 then
      begin
        Delete(Path, P, Length(Entry));
        RegWriteExpandStringValue(HKCU, 'Environment', 'Path', Path);
      end;
    end;
end;
