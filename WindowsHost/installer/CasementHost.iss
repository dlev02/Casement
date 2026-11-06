; Casement Host's Windows installer: one Setup file, one Install button, no administrator prompt.
; Build with scripts\make-installer.ps1 (Inno Setup 6.6 or later).
;
; It installs for the current user into %LOCALAPPDATA%\Programs\Casement Host, a folder the host can
; replace by itself, which is what its updater needs (under Program Files it could only tell you to
; download). The updater swaps that whole folder, so the uninstaller lives outside it, and the host
; keeps "Installed apps" showing the right version (InstallRegistration).
;
; TestInstall builds a copy with its own name, Start menu entry and startup value, so the script can
; be tried on a PC that has the real host. It never touches the real one's.

#ifndef Version
  #error Pass /DVersion=x.y
#endif
#ifndef Arch
  #error Pass /DArch=x64 or /DArch=arm64
#endif
#ifndef SourceDir
  #error Pass /DSourceDir=<the published Casement Host folder>
#endif
#ifndef OutputDir
  #define OutputDir "."
#endif

#ifdef TestInstall
  #define AppName "Casement Host Setup Test"
  #define AppGuid "{{5B0E7C53-6A7C-4C0B-9E55-0D2F5C8A1F11}"
  #define RunValue "Casement Host Setup Test"
  #define TaskName "Casement Host Setup Test"
  #define ProcessName "CasementSetupTestProcess.exe"
#else
  #define AppName "Casement Host"
  ; Never change this: it is how a new Setup finds the copy it updates.
  #define AppGuid "{{8E1F7C0A-3B52-4E7D-A6C4-2D9B1F60C7E4}"
  #define RunValue "Vantage Host"
  #define TaskName "Casement Host"
  #define ProcessName "VantageHost.exe"
#endif
#define ExeName "VantageHost.exe"
#define RunKey "Software\Microsoft\Windows\CurrentVersion\Run"

[Setup]
AppId={#AppGuid}
AppName={#AppName}
AppVersion={#Version}
AppVerName={#AppName}
AppPublisher=Drew Levinson
AppPublisherURL=https://github.com/dlev02/Casement
AppSupportURL=https://github.com/dlev02/Casement/issues
UninstallDisplayName={#AppName}
UninstallDisplayIcon={app}\{#ExeName}
UninstallFilesDir={localappdata}\Programs\{#AppName} Uninstall
VersionInfoVersion={#Version}
VersionInfoDescription={#AppName} Setup
OutputDir={#OutputDir}
OutputBaseFilename=Casement-Host-Setup-{#Arch}
SetupIconFile=..\src\Vantage.Host.Windows\Assets\Vantage.ico
PrivilegesRequired=lowest
DefaultDirName={localappdata}\Programs\{#AppName}
DefaultGroupName={#AppName}
UsePreviousAppDir=yes
DisableDirPage=yes
DisableProgramGroupPage=yes
DisableWelcomePage=yes
DisableReadyMemo=yes
ShowLanguageDialog=no
CloseApplications=no
RestartApplications=no
MinVersion=10.0.19041
#if Arch == "arm64"
ArchitecturesAllowed=arm64
ArchitecturesInstallIn64BitMode=arm64
#else
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
#endif
WizardStyle=modern dynamic windows11
WizardSizePercent=100,100
WizardSmallImageFile=..\src\Vantage.Host.Windows\Assets\CasementHost.png
WizardSmallImageFileDynamicDark=..\src\Vantage.Host.Windows\Assets\CasementHost.png
Compression=lzma2/ultra64
SolidCompression=yes
SetupLogging=yes

[Messages]
WizardReady=Ready to install
ReadyLabel1=Casement Host lets you see and control this PC from your iPhone, iPad, Mac or Apple Vision Pro.
ReadyLabel2a=It installs just for you, starts when you sign in, and keeps itself up to date.
ReadyLabel2b=It installs just for you, starts when you sign in, and keeps itself up to date.
FinishedHeadingLabel=Casement Host is installed
FinishedLabelNoIcons=To connect to this PC:%n%n1. Install Tailscale on this PC and on your device, and sign in to the same account on both.%n2. In Casement on your device, add this PC.%n3. Type in the pairing code Casement Host shows you.%n%nIf Windows asks about the firewall, choose Allow.
FinishedLabel=To connect to this PC:%n%n1. Install Tailscale on this PC and on your device, and sign in to the same account on both.%n2. In Casement on your device, add this PC.%n3. Type in the pairing code Casement Host shows you.%n%nIf Windows asks about the firewall, choose Allow.
ClickFinish=
SetupWindowTitle=Install %1

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
; The host writes this same shortcut itself and leaves it alone while it points at the right exe.
Name: "{userprograms}\{#AppName}"; Filename: "{app}\{#ExeName}"; Comment: "Control this PC from your iPhone, iPad, Mac or Vision Pro"

[Registry]
; A copy unzipped somewhere else may have started at sign-in from there: this one takes over. A person
; who turned it off keeps it off, and on a new install the host turns it on at its first launch.
Root: HKCU; Subkey: "{#RunKey}"; ValueType: string; ValueName: "{#RunValue}"; ValueData: """{app}\{#ExeName}"" --background"; Check: AlreadyStartsAtSignIn

[Run]
Filename: "{app}\{#ExeName}"; Description: "Open Casement Host"; Flags: nowait postinstall skipifsilent
Filename: "https://tailscale.com/download"; Description: "Get Tailscale, which Casement needs to connect"; Flags: shellexec nowait postinstall skipifsilent; Check: TailscaleIsMissing

[UninstallDelete]
; The updater replaces the folder, so it can hold files Setup never recorded.
Type: filesandordirs; Name: "{app}"
Type: filesandordirs; Name: "{app}.update"
Type: filesandordirs; Name: "{app}.update.tmp"
Type: filesandordirs; Name: "{app}.old"

[Code]
const
  TaskkillNotFound = 128;

// Inno Setup indents a page's text under its heading and puts a tall picture on the last page. One
// left edge reads better, and the last page needs the room for its steps.
procedure InitializeWizard;
var
  Margin, Shift: Integer;
begin
  Margin := WizardForm.PageNameLabel.Left;
  Shift := WizardForm.PageDescriptionLabel.Left - Margin;
  WizardForm.PageDescriptionLabel.Left := Margin;
  WizardForm.PageDescriptionLabel.Width := WizardForm.PageDescriptionLabel.Width + Shift;
  Shift := WizardForm.InnerNotebook.Left - Margin;
  WizardForm.InnerNotebook.Left := Margin;
  WizardForm.InnerNotebook.Width := WizardForm.InnerNotebook.Width + Shift;
  WizardForm.WizardSmallBitmapImage.SetBounds(WizardForm.MainPanel.ClientWidth - Margin - ScaleX(40), ScaleY(12), ScaleX(40), ScaleY(40));
end;

procedure CurPageChanged(CurPageID: Integer);
var
  Margin, Width: Integer;
begin
  if CurPageID = wpFinished then
  begin
    Margin := WizardForm.PageNameLabel.Left;
    Width := WizardForm.FinishedPage.ClientWidth - 2 * Margin;
    WizardForm.WizardBitmapImage2.Visible := False;
    WizardForm.FinishedHeadingLabel.SetBounds(Margin, ScaleY(16), Width, ScaleY(32));
    WizardForm.FinishedLabel.SetBounds(Margin, ScaleY(58), Width, WizardForm.FinishedLabel.Height);
    WizardForm.AdjustLabelHeight(WizardForm.FinishedLabel);
    WizardForm.RunList.SetBounds(Margin, WizardForm.FinishedLabel.Top + WizardForm.FinishedLabel.Height + ScaleY(12), Width, WizardForm.RunList.Height);
  end;
end;

function AlreadyStartsAtSignIn: Boolean;
begin
  Result := RegValueExists(HKCU, '{#RunKey}', '{#RunValue}');
end;

function TailscaleIsMissing: Boolean;
begin
  Result := not FileExists(ExpandConstant('{commonpf64}\Tailscale\tailscale.exe'))
    and not FileExists(ExpandConstant('{commonpf32}\Tailscale\tailscale.exe'));
end;

// Stops a running copy, wherever it was started from: its files are in use, and it would hold the
// port and answer the new copy's launch. Windows puts the PC's display back by itself. False when it
// couldn't be stopped, which means it runs as administrator.
function StopRunningHost: Boolean;
var
  ResultCode: Integer;
begin
  Result := True;
  if Exec(ExpandConstant('{sys}\taskkill.exe'), '/F /IM {#ProcessName}', '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
  begin
    Result := (ResultCode = 0) or (ResultCode = TaskkillNotFound);
    if ResultCode = 0 then Sleep(800);
  end;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  if not StopRunningHost then
    Result := 'Casement Host is running as administrator, so Setup can''t close it. Choose Quit from its icon next to the clock, then run Setup again.';
end;

function InitializeUninstall: Boolean;
begin
  Result := StopRunningHost;
  if not Result then
    SuppressibleMsgBox('Casement Host is running as administrator, so it can''t be closed from here. Choose Quit from its icon next to the clock, then try again.', mbError, MB_OK, IDOK);
end;

// "Control apps running as administrator" leaves a Task Scheduler task behind. Deleting it takes the
// same permission as making it, so Windows only asks when there is one.
procedure RemoveAdministratorTask;
var
  ResultCode: Integer;
begin
  if Exec(ExpandConstant('{sys}\schtasks.exe'), '/Query /TN "{#TaskName}"', '', SW_HIDE, ewWaitUntilTerminated, ResultCode) and (ResultCode = 0) then
    ShellExec('runas', ExpandConstant('{sys}\schtasks.exe'), '/Delete /TN "{#TaskName}" /F', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
  begin
    RegDeleteValue(HKCU, '{#RunKey}', '{#RunValue}');
    RemoveAdministratorTask;
#ifndef TestInstall
    if SuppressibleMsgBox('Also remove Casement Host''s settings and the list of paired devices?' + #13#10 + #13#10 + 'Keep them if you plan to install it again: your devices will connect without a new pairing code.', mbConfirmation, MB_YESNO or MB_DEFBUTTON2, IDNO) = IDYES then
      DelTree(ExpandConstant('{localappdata}\Vantage Host'), True, True, True);
#endif
  end;
end;
