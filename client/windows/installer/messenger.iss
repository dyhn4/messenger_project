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
; Inno Setup 기본 기능(Restart Manager로 실행 중인 앱을 감지해 정상 종료 신호를 보내는 것)이
; 이 앱에는 안 먹힌다 — 창을 닫아도 트레이로 숨을 뿐 그 신호를 무시하도록 만들어져 있어서
; (main.dart의 windowManager.setPreventClose), "모든 응용 프로그램을 자동으로 닫지
; 못했습니다" 오류로 이어졌다. 그 자동 감지는 끄고, 아래 [Code]에서 taskkill로 직접 끈다.
CloseApplications=no

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

; 마침 화면에 "TangoTalk 실행" 체크박스를 두되, 기본은 체크 해제(unchecked)다 — 초대
; 링크(설치→가입)로 들어온 사람이 여기서 바로 앱을 켜버리면 tangotalk:// 딥링크를 거치지
; 않아 서버 미설정 상태로 열리기 때문에(README "초대 링크(설치→가입)" 참고 — 서버 주소/
; 코드 자동입력은 초대 페이지가 딥링크를 다시 시도해야만 일어난다), 아래 안내 문구로 그
; 경우엔 체크하지 말고 페이지로 돌아가라고 알려준다. 반대로 업데이트 설치처럼 바로 실행해도
; 무방한 경우엔 체크해서 바로 켤 수 있다.
[Messages]
FinishedLabel=설치가 완료되었습니다.%n%n초대 링크로 설치했다면 아래를 체크하지 말고, 그 페이지로 다시 가서 새로고침하세요.
FinishedLabelNoIcons=설치가 완료되었습니다.%n%n초대 링크로 설치했다면 그 페이지로 다시 가서 새로고침하세요.

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{#MyAppName} 실행"; Flags: nowait postinstall skipifsilent unchecked
; 앱 안 "지금 설치"로 받은 업데이트는 /SILENT로 진행률 창만 띄우며 돌아간다(session.dart의
; installUpdate 참고) — 그 경로에서는 위 체크박스 화면 자체가 안 뜨니(skipifsilent) 앱이
; 다시 켜지지 않고 조용히 사라진 것처럼 보인다. 조용히 설치할 때만 이 항목으로 대신
; 자동 재실행한다(일반 더블클릭 설치는 그대로 체크박스로 사용자가 고른다).
Filename: "{app}\{#MyAppExeName}"; Flags: nowait; Check: IsSilentMode

[Code]
/// tasklist로 이 앱이 지금 실행 중인지 확인한다 — 트레이로 숨어있어도 프로세스는 살아있다
/// (main.dart의 windowManager.setPreventClose 때문에 창을 닫아도 진짜로는 안 끝난다).
function IsAppRunning(): Boolean;
var
  TmpFile: String;
  Output: AnsiString;
  ResultCode: Integer;
begin
  Result := False;
  TmpFile := ExpandConstant('{tmp}\tangotalk_tasklist.txt');
  if Exec(ExpandConstant('{cmd}'), '/C tasklist /FI "IMAGENAME eq {#MyAppExeName}" /NH > "' + TmpFile + '"',
    '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
  begin
    if LoadStringFromFile(TmpFile, Output) then
      Result := Pos('{#MyAppExeName}', Output) > 0;
  end;
  DeleteFile(TmpFile);
end;

/// [Run]의 자동 재실행 항목이 조용한 설치(아래 IsSilentMode)에서만 켜지게 하는 Check: 용
/// 래퍼 — Inno 내장 WizardSilent()를 [Run]의 Check:에 직접 못 넣어서(사용자 정의 함수만
/// 받음) 하나 감싼다.
function IsSilentMode(): Boolean;
begin
  Result := WizardSilent();
end;

/// 설치를 시작하기 전에 실행 중인 {#MyAppName}을 확실하게 끈다(위 [Setup]의
/// CloseApplications=no 설명 참고 — Windows의 자동 닫기 기능이 이 앱에는 안 먹혀서 직접
/// 처리한다). 트레이 상주도 별도 자식 프로세스가 아니라 같은 프로세스가 창만 숨긴 것이라
/// /IM(이미지 이름) 하나로 충분히 끝난다 — /T(자식 프로세스까지 종료)는 일부러 안 쓴다.
/// 이 설치 프로그램 자신이 어떤 경로로 실행됐는지에 따라 프로세스 트리 관계가 달라질 수
/// 있는데, /T를 쓰면 그 트리 관계에 따라 의도와 달리 설치 마법사 자신까지 함께 죽는 사고가
/// 실제로 있었다(taskkill이 대상 프로세스의 자식 트리 전체를 종료하기 때문).
///
/// 앱 안 "지금 설치"로 받은 업데이트(session.dart의 installUpdate, /SILENT로 실행됨)는
/// 이미 그 버튼을 누른 시점에 "종료하고 설치"에 동의한 것과 같으므로 이 확인창을 또 안
/// 띄운다 — 안 그러면 사용자 눈에 안 보이는 곳에서(포커스를 못 받거나 다른 창 뒤에 가려)
/// 조용히 "아니오"로 취소된 것처럼 끝나버려서, 설치가 통째로 조용히 취소되는데도 앱에는
/// "완료됨"으로만 보이는 문제가 있었다(파일이 실제로는 하나도 안 바뀜 → 재실행해도 예전
/// 버전 그대로).
function InitializeSetup(): Boolean;
var
  ResultCode: Integer;
begin
  Result := True;
  if IsAppRunning() then
  begin
    if IsSilentMode() or (MsgBox('{#MyAppName}이(가) 실행 중입니다(트레이에 있는 경우 포함).' + #13#10 +
      '종료하고 설치를 계속할까요?', mbConfirmation, MB_YESNO) = IDYES) then
    begin
      Exec('taskkill.exe', '/IM {#MyAppExeName} /F', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
    end
    else
      Result := False;
  end;
end;
