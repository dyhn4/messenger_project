; Inno Setup 스크립트 — Windows 클라이언트 설치 프로그램.
; 빌드: "flutter build windows --release"를 먼저 실행해 build\windows\x64\runner\Release\를
; 채운 뒤, ISCC.exe로 이 파일을 컴파일한다(저장소 루트의 publish_release.ps1이 전체 과정을 자동화함).
;
; 관리자 권한 없이 현재 사용자 계정에만 설치되도록 했다(PrivilegesRequired=lowest) — 회사 PC처럼
; 관리자 권한이 없는 환경에서도 그냥 설치할 수 있게 하기 위함.

#define MyAppName "TeamTalk"
#define MyAppVersion "1.0.0"
#define MyAppExeName "client.exe"
#define ReleaseDir "..\..\build\windows\x64\runner\Release"

[Setup]
AppId={{B6E1E9D2-6B77-4B7B-9C1D-6C6B9F6C9A11}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
DefaultDirName={localappdata}\{#MyAppName}
DefaultGroupName={#MyAppName}
PrivilegesRequired=lowest
OutputDir=output
OutputBaseFilename=messenger-setup
Compression=lzma2
SolidCompression=yes
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
WizardStyle=modern

[Languages]
Name: "korean"; MessagesFile: "compiler:Languages\Korean.isl"

[Tasks]
Name: "desktopicon"; Description: "바탕화면에 바로가기 만들기"; GroupDescription: "추가 아이콘:"

[Files]
Source: "{#ReleaseDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\{#MyAppName} 제거"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{#MyAppName} 실행"; Flags: nowait postinstall skipifsilent
