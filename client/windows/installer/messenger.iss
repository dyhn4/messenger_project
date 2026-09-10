; Inno Setup 스크립트 — Windows 클라이언트 설치 프로그램.
; 빌드: "flutter build windows --release"를 먼저 실행해 build\windows\x64\runner\Release\를
; 채운 뒤, ISCC.exe로 이 파일을 컴파일한다(저장소 루트의 publish_release.ps1이 전체 과정을 자동화함).
;
; 관리자 권한 없이 현재 사용자 계정에만 설치되도록 했다(PrivilegesRequired=lowest) — 회사 PC처럼
; 관리자 권한이 없는 환경에서도 그냥 설치할 수 있게 하기 위함.

#define MyAppName "TangoTalk"
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

; 초대 링크(tangotalk://pair?...)를 클릭하면 이 앱이 열리도록 커스텀 URL 프로토콜을 등록한다.
; PrivilegesRequired=lowest와 맞춰 HKCU에만 쓴다(관리자 권한 불필요, 현재 사용자에게만 적용).
; uninsdeletekey라 제거 시 이 키도 같이 지워진다.
[Registry]
Root: HKCU; Subkey: "Software\Classes\tangotalk"; ValueType: string; ValueName: ""; ValueData: "URL:TangoTalk Protocol"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\tangotalk"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\tangotalk\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#MyAppExeName}"" ""%1"""

; [Run]에 "{#MyAppName} 실행" 항목을 두지 않는다 — 초대 링크(설치→가입)로 들어온 사람이
; 설치 직후 여기서 바로 앱을 켜버리면 tangotalk:// 딥링크를 거치지 않아 서버 미설정 상태로
; 열리고 만다(README "초대 링크(설치→가입)" 참고 — 서버 주소/코드 자동입력은 초대 페이지가
; 딥링크를 다시 시도해야만 일어난다). 그래서 실행 체크박스 대신 마침 화면에 안내 문구를 넣어
; 원래 열어뒀던 초대 링크 페이지로 돌아가 새로고침하도록 유도한다.
[Messages]
FinishedLabel=설치가 완료되었습니다.%n%n초대 링크 페이지로 다시 가서 새로고침하세요.
FinishedLabelNoIcons=설치가 완료되었습니다.%n%n초대 링크 페이지로 다시 가서 새로고침하세요.
