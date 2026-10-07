; TangoTalk 서버 설치 프로그램 — Node.js 서버 + PostgreSQL을 새 "서비스 PC"에 통째로 설치한다.
;
; 빌드: 저장소 루트의 build_server_installer.ps1이 (1) Node 포터블 런타임/PostgreSQL 공식 설치
; 프로그램/nssm.exe를 installer/bin/에 받아두고 (2) server/를 정리해서(.env·certs·uploads·로그·
; firebase-service-account.json 등 실데이터/비밀값 전부 제외) npm install까지 미리 돌린 결과를
; installer/stage/에 만든 뒤, ISCC.exe로 이 스크립트를 컴파일해서 installer/output/에 exe를
; 만든다 — client/windows/installer/messenger.iss + publish_release.ps1과 같은 구조.
;
; 클라이언트 설치 프로그램과의 핵심 차이: PostgreSQL 무인 설치 + Windows 서비스 등록(NSSM) +
; 방화벽 규칙 추가가 필요해서 관리자 권한으로 설치한다(클라이언트는 PrivilegesRequired=lowest).
; PostgreSQL은 그 PC의 다른 설치와 충돌하지 않도록 전용 설치 경로+전용 포트를 쓴다(자세한 이유는
; Setup-TangoTalkServer.ps1 상단 주석 참고).

#define MyAppName "TangoTalk Server"
#define MyAppVersion "1.0.0"
#define StageDir "stage"
#define BinDir "bin"

[Setup]
AppId={{A2F1C9E4-7B22-4C55-9E9C-2F6C4B8A5D31}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
DefaultDirName=C:\TangoTalk-Server
; 설치 경로를 고를 수 있게 한다(예: 용량이 큰 드라이브로). PostgreSQL/NSSM/여러 PowerShell
; 스크립트가 이 경로를 문자열로 조합해서 명령을 만들기 때문에, 공백이 포함된 경로(예: "C:\My
; Server\...")를 고르면 인용 부호를 빠뜨린 곳에서 인자가 쪼개지는 버그가 날 수 있다 —
; Setup-TangoTalkServer.ps1의 Start-Process -ArgumentList 호출부(PostgreSQL 설치)에서 실제로
; 이 문제가 있어서 고쳤다(2026-09-10). 새로 이런 호출을 추가할 때는 경로가 들어가는 인자를
; 반드시 이스케이프된 따옴표로 감쌀 것 — `&`/splat 호출(`& $exe @args`)은 배열 원소를 각각
; 별도 인자로 안전하게 넘겨주지만, `Start-Process -ArgumentList`는 배열을 그냥 공백으로
; 이어붙이기만 해서 안전하지 않다.
;
; 설치 폴더 권한: 기본 경로는 C:\의 권한("Authenticated Users: 수정")을 물려받아, 이 PC의 아무 계정이나
; LocalSystem으로 도는 서비스(Node 서버·LiveKit)와 NetworkService로 도는 PostgreSQL의 실행 파일·코드를
; 바꿔치기할 수 있었다. 그래서 Setup-TangoTalkServer.ps1이 PostgreSQL 설치 직후, Update-Server.ps1이 매
; 업데이트마다 폴더 전체를 SYSTEM/Administrators 전용으로 잠근다(Folder-Acl.ps1). 일반 권한으로 열리는
; 시작 메뉴 항목은 루트의 *.ps1·README*·제거 프로그램만 읽을 수 있으므로, node.exe를 직접 실행하던
; "서버 콘솔로 실행"은 스스로 승격하는 Start-ServerConsole.ps1을 거친다. 드라이브 최상위·Program Files
; 자체 같은 공용 폴더를 설치 경로로 고르면 잠그지 않고 경고만 한다(다른 프로그램까지 막히므로).
; 또한 설치 "전"에도, 일반 사용자가 관리자 설치 전에 설치 폴더를 미리 만들어(C:\는 폴더 생성 허용) 코드를
; 심어 두면 SYSTEM 권한으로 실행될 수 있으므로, [Code]의 PrepareToInstall이 설치 경로가 링크(정션/심볼릭 링크)면
; 막고, 폴더가 이미 있으면 "우리가 예전에 정식 설치한 폴더(HKLM 제거 키의 InstallLocation 일치)"이거나 "잠긴 폴더(소유자가
; Administrators/SYSTEM이고 그 밖의 계정에는 그 폴더의 쓰기·삭제·권한 변경류 권한이 없음)"인지 확인해서 아니면 설치를
; 중단한다. 관리자 소유지만 다른 계정도 쓸 수 있는 폴더(잠금 전 버전으로 설치했다가 제거한 폴더가 이렇다)는 확인 창(기본
; "아니요", 무인 설치면 거부)으로 묻는다 — 소유자만 보면 안 되는 이유는 [Code]의 CheckExistingAppDir 주석 참고. 제거 키만
; 보면 안 된다 — 일반 제거는 제거 키를 지우면서도 DB·비밀값이 든 {app}은 일부러 남기므로(아래 [UninstallDelete])
; "제거한 뒤 같은 경로에 다시 설치"가 막혀 버린다. 서비스 정지도 {app}\tools\nssm.exe가 아니라 System32의
; net.exe로 한다(바꿔치기 대비).
DisableDirPage=no
DefaultGroupName={#MyAppName}
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=output
OutputBaseFilename=tangotalk-server-setup
Compression=lzma2
SolidCompression=yes
SetupIconFile=..\..\client\windows\runner\resources\app_icon.ico
WizardStyle=modern

[Languages]
Name: "korean"; MessagesFile: "compiler:Languages\Korean.isl"

[Tasks]
Name: "runasservice"; Description: "백그라운드 Windows 서비스로 등록(컴퓨터를 켤 때 자동 시작, 창 없음) — 권장"; GroupDescription: "서버 실행 방식:"; Flags: exclusive
Name: "runasconsole"; Description: "콘솔 창으로 실행(창을 닫으면 서버도 함께 종료됨)"; GroupDescription: "서버 실행 방식:"; Flags: exclusive unchecked

[Files]
Source: "{#BinDir}\node\*"; DestDir: "{app}\node"; Flags: recursesubdirs createallsubdirs
Source: "{#BinDir}\nssm.exe"; DestDir: "{app}\tools"
; 화상회의(LiveKit SFU) — Go 단일 실행 파일. 설정 파일(livekit.yaml)과 API 비밀값은
; Setup-TangoTalkServer.ps1이 설치 시점에 만들어 넣는다(server/.livekit-secret과 같은 값).
Source: "{#BinDir}\livekit\*"; DestDir: "{app}\livekit"; Flags: recursesubdirs createallsubdirs
Source: "{#BinDir}\pgsql-installer.exe"; DestDir: "{tmp}"; Flags: deleteafterinstall
; StageDir는 build_server_installer.ps1이 이미 필요한 것만(certs/uploads/.env/로그/개발용
; node_modules 등을 뺀) 정리해둔 결과라 여기서 별도 Excludes가 필요 없다.
Source: "{#StageDir}\*"; DestDir: "{app}\server"; Flags: recursesubdirs createallsubdirs ignoreversion
Source: "Setup-TangoTalkServer.ps1"; DestDir: "{app}"
; 폴더 접근 권한 잠금 공용 함수 — Setup/Update-Server/Storage-Path/Backup-Data가 dot-source한다.
Source: "Folder-Acl.ps1"; DestDir: "{app}"
Source: "Start-ServerConsole.ps1"; DestDir: "{app}"
Source: "Get-PairingCode.ps1"; DestDir: "{app}"
Source: "Update-Server.ps1"; DestDir: "{app}"
Source: "Restart-Server.ps1"; DestDir: "{app}"
Source: "Storage-Path.ps1"; DestDir: "{app}"
Source: "External-Address.ps1"; DestDir: "{app}"
Source: "Backup-Data.ps1"; DestDir: "{app}"
Source: "Restore-Data.ps1"; DestDir: "{app}"
Source: "Reset-Data.ps1"; DestDir: "{app}"
Source: "Uninstall-Full.ps1"; DestDir: "{app}"
; 서버 운영자 복구(활성 서버 운영자가 한 명도 없을 때만 동작 — server\scripts\grant-server-admin.mjs를 부른다).
; 거의 쓸 일이 없어 시작 메뉴에는 넣지 않고 README-설치후.txt에서 실행 방법을 안내한다. 루트의 *.ps1은 여기에
; 하나씩 적어야 설치된다(tests\Install-Guard.Tests.ps1이 빠진 것이 없는지 확인한다).
Source: "Grant-ServerAdmin.ps1"; DestDir: "{app}"
Source: "README-설치후.txt"; DestDir: "{app}"
; 저장소 루트 README.md(전체 프로젝트 문서, 목차 포함)를 build_server_installer.ps1이 정적
; HTML로 미리 변환해둔 결과 — "메신저 설명서" 바로가기가 기본 브라우저로 그대로 보여준다.
; (초보자용 "도움말" 웹페이지 server/guide/는 위 StageDir에 같이 들어 있어 {app}\server\guide로
; 깔리고, 서버가 /guide/로 서빙한다 — server/src/version.js 참고.)
Source: "README.html"; DestDir: "{app}"

[InstallDelete]
; 예전 버전이 만든 "도움말" 바로가기(지금은 "메신저 설명서") — 새 버전을 덮어 설치해도 옛 이름의
; 바로가기가 시작 메뉴에 같이 남지 않게 지운다([Icons]에서 빠진 항목은 Inno가 스스로 안 지운다).
Type: files; Name: "{group}\도움말.lnk"

[Icons]
Name: "{group}\새 기기 페어링 코드 발급"; Filename: "powershell.exe"; Parameters: "-NoLogo -ExecutionPolicy Bypass -File ""{app}\Get-PairingCode.ps1"""
; 설치 폴더가 관리자 전용으로 잠겨 있어 node.exe를 일반 권한으로 바로 실행할 수 없다 — 이 스크립트가
; 스스로 관리자 권한으로 승격한 뒤 서버 폴더에서 node를 띄운다(창을 닫으면 서버도 꺼짐).
Name: "{group}\서버 콘솔로 실행"; Filename: "powershell.exe"; Parameters: "-NoLogo -ExecutionPolicy Bypass -File ""{app}\Start-ServerConsole.ps1"""; Tasks: runasconsole
Name: "{group}\설치 후 안내"; Filename: "{app}\README-설치후.txt"
; .html은 이 PC의 기본 브라우저로 바로 열린다(.md와 달리 연결 프로그램이 없어서 뜨는
; "여는 방법을 선택하세요" 창 걱정이 없음) — Filename을 파일 자체로 지정하면 된다. 예전 이름은
; "도움말"이었는데, 앱의 "도움말"이 모든 회원용 초보자 안내(server/guide/)가 되면서 이 문서는
; 앱과 같은 "메신저 설명서"로 이름을 맞췄다.
Name: "{group}\메신저 설명서"; Filename: "{app}\README.html"
; 개발 PC에서 package_server_update.ps1로 만든 zip을 골라서 적용하는 창을 띄운다(DB는
; 안 건드리고 코드/패키지/스키마만 갱신) — 관리자 권한이 필요해 스스로 승격한다.
Name: "{group}\서버 업데이트"; Filename: "powershell.exe"; Parameters: "-NoLogo -ExecutionPolicy Bypass -File ""{app}\Update-Server.ps1"""
; 코드/DB는 그대로 두고 TangoTalkServer 서비스만 재시작한다(예: .env를 수동으로 고친 뒤) —
; 관리자 권한이 필요해 스스로 승격한다.
Name: "{group}\서버 재시작"; Filename: "powershell.exe"; Parameters: "-NoLogo -ExecutionPolicy Bypass -File ""{app}\Restart-Server.ps1"""
; 첨부파일 저장 위치 확인/변경(NAS·다른 PC 공유 폴더 등) — 관리자 권한이 필요해 스스로 승격한다.
Name: "{group}\첨부파일 저장소"; Filename: "powershell.exe"; Parameters: "-NoLogo -ExecutionPolicy Bypass -File ""{app}\Storage-Path.ps1"""
; 사내망 밖(LTE/5G) 접속 주소(DDNS·공인 IP) 확인/변경 — .env의 EXTERNAL_ADDRESS. 관리자 권한이 필요해 스스로 승격한다.
Name: "{group}\외부 접속 주소"; Filename: "powershell.exe"; Parameters: "-NoLogo -ExecutionPolicy Bypass -File ""{app}\External-Address.ps1"""
; DB를 파일 하나로 백업한다({app}\backups\에 저장, 관리자 전용 폴더, 최근 10개만 보관) — pg_dump
; 경로/포트/비밀번호를 몰라도 콘솔 명령어 없이 바로 된다. 관리자 권한이 필요해 스스로 승격한다.
Name: "{group}\백업"; Filename: "powershell.exe"; Parameters: "-NoLogo -ExecutionPolicy Bypass -File ""{app}\Backup-Data.ps1"""
; "백업"이 만든 .dump 파일을 골라 DB를 그 시점으로 되돌린다 — DB 데이터 초기화와 같은 수준의
; 안전장치(운영자 본인 확인 + 문구 입력)를 둔다. 관리자 권한이 필요해 스스로 승격한다.
Name: "{group}\복원"; Filename: "powershell.exe"; Parameters: "-NoLogo -ExecutionPolicy Bypass -File ""{app}\Restore-Data.ps1"""
; 서버는 그대로 두고 회원/팀/메시지 등 데이터만 비우고 싶을 때(Uninstall-Full과 달리
; .env/인증서/설치는 안 건드리고, 끝나면 서버가 바로 다시 쓸 수 있는 빈 상태로 돌아옴).
Name: "{group}\DB 데이터 초기화"; Filename: "powershell.exe"; Parameters: "-NoLogo -ExecutionPolicy Bypass -File ""{app}\Reset-Data.ps1"""
; PostgreSQL·Node 앱·DB 데이터를 전부 지운다(마지막 단계에서 일반 제거 프로그램까지 자동
; 실행) — 아래 "TangoTalk 서버 제거"는 Node 앱 프로그램 파일만 지우고 싶을 때(PostgreSQL과
; 데이터는 그대로 둠) 따로 쓰는 것.
Name: "{group}\서버 완전 삭제(PostgreSQL·Node 앱·DB 데이터 모두)"; Filename: "powershell.exe"; Parameters: "-NoLogo -ExecutionPolicy Bypass -File ""{app}\Uninstall-Full.ps1"""
Name: "{group}\TangoTalk 서버 제거"; Filename: "{uninstallexe}"

[Run]
Filename: "powershell.exe"; Parameters: "-NoLogo -ExecutionPolicy Bypass -File ""{app}\Setup-TangoTalkServer.ps1"" -RunMode {code:GetRunMode} -AppDir ""{app}"" -PgInstallerPath ""{tmp}\pgsql-installer.exe"""; StatusMsg: "서버 구성 중입니다(PostgreSQL 설치, 데이터베이스 생성, 마이그레이션 적용) — 몇 분 걸릴 수 있습니다..."; Flags: runhidden waituntilterminated

[UninstallRun]
; 일반 제거는 서비스 등록/방화벽 규칙만 정리한다 — DB/업로드/설정 등 실데이터는 절대 건드리지
; 않는다(완전 삭제는 Uninstall-Full.ps1로 완전히 분리돼 있고, 여기서 자동 호출되지 않는다).
Filename: "{app}\tools\nssm.exe"; Parameters: "stop TangoTalkLiveKit"; Flags: runhidden waituntilterminated skipifdoesntexist; RunOnceId: "StopLiveKit"
Filename: "{app}\tools\nssm.exe"; Parameters: "remove TangoTalkLiveKit confirm"; Flags: runhidden waituntilterminated skipifdoesntexist; RunOnceId: "RemoveLiveKit"
Filename: "netsh.exe"; Parameters: "advfirewall firewall delete rule name=""TangoTalk LiveKit (signal)"""; Flags: runhidden waituntilterminated; RunOnceId: "DelFwLk1"
Filename: "netsh.exe"; Parameters: "advfirewall firewall delete rule name=""TangoTalk LiveKit (media)"""; Flags: runhidden waituntilterminated; RunOnceId: "DelFwLk2"
Filename: "netsh.exe"; Parameters: "advfirewall firewall delete rule name=""TangoTalk LiveKit (turn)"""; Flags: runhidden waituntilterminated; RunOnceId: "DelFwLk3"
Filename: "{app}\tools\nssm.exe"; Parameters: "stop TangoTalkServer"; Flags: runhidden waituntilterminated skipifdoesntexist; RunOnceId: "StopSvc"
Filename: "{app}\tools\nssm.exe"; Parameters: "remove TangoTalkServer confirm"; Flags: runhidden waituntilterminated skipifdoesntexist; RunOnceId: "RemoveSvc"
Filename: "netsh.exe"; Parameters: "advfirewall firewall delete rule name=""TangoTalk Server (main)"""; Flags: runhidden waituntilterminated; RunOnceId: "DelFw1"
Filename: "netsh.exe"; Parameters: "advfirewall firewall delete rule name=""TangoTalk Server (pairing)"""; Flags: runhidden waituntilterminated; RunOnceId: "DelFw2"

[UninstallDelete]
; 프로그램 파일만 지정한다 — .env / certs / uploads / secrets / pgsql / pgsql-data / releases는
; 절대 여기 추가하지 않는다(일반 제거로 실데이터가 지워지면 안 된다는 게 이 섹션의 핵심 불변식).
Type: filesandordirs; Name: "{app}\node"
Type: filesandordirs; Name: "{app}\tools"
; livekit 폴더는 실행 파일과 생성된 설정(livekit.yaml)뿐이라 지워도 된다 — API 비밀값은
; server/.livekit-secret 쪽에 있고, 그건 실데이터와 같이 보존된다.
Type: filesandordirs; Name: "{app}\livekit"
Type: filesandordirs; Name: "{app}\server\node_modules"
Type: filesandordirs; Name: "{app}\server\src"
Type: filesandordirs; Name: "{app}\server\scripts"
Type: filesandordirs; Name: "{app}\server\drizzle"
Type: filesandordirs; Name: "{app}\server\guide"
Type: files; Name: "{app}\server\package.json"
Type: files; Name: "{app}\server\package-lock.json"
Type: files; Name: "{app}\server\drizzle.config.js"
Type: files; Name: "{app}\server\.env.example"

[Code]
const
  // Inno Setup이 이미 같은 이름(FILE_ATTRIBUTE_REPARSE_POINT 등)을 정의해 두어 겹치지 않게 TT_를 붙인다.
  TT_FILE_ATTRIBUTE_REPARSE_POINT = $00000400;
  TT_INVALID_FILE_ATTRIBUTES      = $FFFFFFFF;
  // 이 설치 프로그램의 AppId(위 [Setup] AppId와 같아야 함). 제거(Uninstall) 레지스트리 키 이름에 쓴다.
  TangoTalkAppId = '{A2F1C9E4-7B22-4C55-9E9C-2F6C4B8A5D31}';
  // CheckExistingAppDir 결과 코드 — AppDirCheckParams의 exit 코드와 같아야 한다(그 밖의 값은 전부 "확인 못 함"으로 거부).
  AppDirLocked      = 0;   // 소유자가 Administrators/SYSTEM이고, 그 밖의 계정에는 이 폴더의 쓰기류 권한이 없다(잠긴 설치 폴더).
  AppDirOtherOwner  = 2;
  AppDirUnreadable  = 3;
  AppDirAdminShared = 4;   // 소유자는 Administrators/SYSTEM인데 다른 계정에도 쓰기류 권한이 있다(잠금 전 버전이 남긴 폴더 등).
  // 기존 설치 폴더 검사(CheckExistingAppDir)에서 powershell.exe에 넘기는 인자 — @DIR@ 자리에 PsQuoteLiteral로 감싼 경로가
  // 들어간다. 종료 코드는 위 AppDir* 상수(잘못돼도 열리지 않게 전체를 try로 감싸고 오류는 전부 3 — exit는 catch에 안 잡힌다).
  // 받아들이는 계정($ok): Administrators(S-1-5-32-544), SYSTEM(S-1-5-18). 쓰기류 권한 0x500D0156 = 파일 쓰기·추가
  // (WriteData·AppendData), 확장 특성·특성 쓰기, 하위 항목 삭제, 삭제(이름 바꾸기 포함), 권한 변경, 소유권 가져오기, 그리고
  // GENERIC_WRITE·GENERIC_ALL(상속 전용 항목에는 일반 권한 비트가 그대로 남는다). 읽기·실행(Users·PostgreSQL 계정의 RX)은 괜찮다.
  // 상속받은 항목과 상속 전용 항목도 본다 — 상속 전용 항목은 안쪽에 생기는 파일·폴더에 그 권한을 주므로 역시 "다른 계정이 쓸
  // 수 있는 폴더"다. 거부(Deny) 항목은 권한을 줄이기만 하므로 보지 않는다(조심하는 쪽으로 틀린다).
  // 이 PC에서 ISCC 없이도 검증할 수 있게 tests\Install-Guard.Tests.ps1이 이 줄을 그대로 꺼내 실제로 실행해 본다(권한 판정만
  // 따로 보려고 $ok 목록에 테스트 계정을 더해서도 돌린다) — 한 줄로 두고, 이름이나 $ok 부분을 바꾸면 그 테스트도 고칠 것.
  AppDirCheckParams = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "$ErrorActionPreference = ''Stop''; try { $a = Get-Acl -LiteralPath @DIR@; $ok = @(''S-1-5-32-544'', ''S-1-5-18''); if ($ok -notcontains $a.GetOwner([System.Security.Principal.SecurityIdentifier]).Value) { exit 2 }; foreach ($r in $a.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])) { if (($r.AccessControlType -eq ''Allow'') -and ($ok -notcontains $r.IdentityReference.Value) -and ((([int]($r.FileSystemRights)) -band 0x500D0156) -ne 0)) { exit 4 } }; exit 0 } catch { exit 3 }"';

function TTGetFileAttributes(lpFileName: String): Cardinal;
  external 'GetFileAttributesW@kernel32.dll stdcall';

function GetRunMode(Param: string): string;
begin
  if WizardIsTaskSelected('runasconsole') then
    Result := 'console'
  else
    Result := 'service';
end;

function TrimTrailingBackslash(const S: String): String;
begin
  Result := S;
  while (Length(Result) > 0) and (Result[Length(Result)] = '\') do
    Delete(Result, Length(Result), 1);
end;

function DirIsReparsePoint(const Dir: String): Boolean;
var
  Attrs: Cardinal;
begin
  Attrs := TTGetFileAttributes(Dir);
  Result := (Attrs <> TT_INVALID_FILE_ATTRIBUTES) and ((Attrs and TT_FILE_ATTRIBUTE_REPARSE_POINT) <> 0);
end;

// HKLM 제거(Uninstall) 레지스트리 키는 관리자 권한 설치만 만들 수 있다(일반 사용자는 HKLM에 못 씀).
// 그 키의 InstallLocation이 지금 설치 경로와 같으면, 이 폴더는 우리가 예전에 정식으로 설치한 것이 확실하다.
// 64/32비트 뷰 둘 다 본다(설치 모드에 따라 쓰이는 뷰가 달라서) — 일반 사용자가 위조할 수 없으므로 둘 다 봐도 안전하다.
function RegInstallLocationMatches(const RootView: Integer; const AppDir: String): Boolean;
var
  SubKey, Loc: String;
begin
  Result := False;
  SubKey := 'Software\Microsoft\Windows\CurrentVersion\Uninstall\' + TangoTalkAppId + '_is1';
  if RegQueryStringValue(RootView, SubKey, 'InstallLocation', Loc) then
    Result := (CompareText(TrimTrailingBackslash(Loc), TrimTrailingBackslash(AppDir)) = 0);
end;

function IsPriorTangoTalkInstall(const AppDir: String): Boolean;
begin
  Result := RegInstallLocationMatches(HKLM64, AppDir) or RegInstallLocationMatches(HKLM32, AppDir);
end;

// S를 PowerShell 작은따옴표 문자열(글자 그대로인 리터럴)로 감싼다 — 안의 작은따옴표는 두 번 써서 글자로 남긴다.
// PowerShell은 '(U+0027) 말고도 U+2018~U+201B(굽은 작은따옴표 등)를 작은따옴표로 취급하므로 이것들도 두 번 쓴다 —
// 하나라도 빠뜨리면 경로에 그 글자가 있을 때 거기서 문자열이 끝나고 뒷부분이 명령으로 실행된다(따옴표가 든 폴더 이름이
// 기존 폴더 검사를 그냥 통과할 수 있음 — tests\Install-Guard.Tests.ps1). 큰따옴표(")는 Windows 경로에 못 쓰므로 바깥
// -Command "..."가 깨질 일은 없다.
function PsQuoteLiteral(const S: String): String;
var
  I, Code: Integer;
begin
  Result := '''';
  for I := 1 to Length(S) do
  begin
    Code := Ord(S[I]);
    if (Code = 39) or ((Code >= $2018) and (Code <= $201B)) then
      Result := Result + S[I];
    Result := Result + S[I];
  end;
  Result := Result + '''';
end;

// 이미 있는 설치 폴더가 "관리자 쪽만 만들고 고칠 수 있는 폴더"인지 본다 — 결과는 위 AppDir* 코드, PowerShell을 실행하지
// 못하면 -1(0·4가 아닌 다른 코드와 마찬가지로 거부).
//  - 소유자: 일반 사용자는 새 파일·폴더의 소유자를 자기 계정으로만 정할 수 있어서(Administrators는 승격된 관리자 토큰에서만
//    소유자로 쓸 수 있고, 임의의 소유자를 넣는 복원 권한도 관리자 전용) Administrators/SYSTEM 소유 폴더를 만들 수 없다. 이 설치
//    프로그램이 만든 폴더는 예전 버전이든(승격된 프로세스가 만든 폴더의 기본 소유자는 Administrators) 잠금이 생긴 뒤든
//    (Folder-Acl.ps1이 소유자를 Administrators로 맞춤) 여기에 해당한다 — 일반 제거로 제거 키가 지워진 폴더를 알아보는 데 쓴다.
//  - 그 폴더 자신의 권한: 소유자만으로는 부족하다. 관리자 권한 프로그램이 C:\ 바로 아래에 만든 폴더(드라이버·제조사 도구의
//    설치 파일 폴더, C:\Temp 등)도 소유자는 Administrators인데, C:\에서 "Authenticated Users: 수정"(삭제 = 이름 바꾸기 포함)을
//    물려받는다 — 다른 계정이 그런 폴더에 파일을 넣고 이름을 설치 경로로 바꿔 둘 수 있다. 그래서 SYSTEM/Administrators 말고
//    다른 계정에 쓰기류 허용 항목이 없을 때만 0(잠긴 폴더)으로 본다. 잠근 설치 폴더 루트(Protect-InstallDir: SYSTEM·
//    Administrators 전체, Users·PostgreSQL 계정은 읽기만)는 일반 제거·완전 삭제 뒤에도 그대로라 0이 나오고, 이름을 바꿔 들여온
//    폴더는 그 이름 바꾸기에 필요했던 삭제 권한이 그 폴더 권한에 그대로 보여서 0이 나올 수 없다.
// 포인터를 다루는 advapi32 호출(GetNamedSecurityInfo) 대신 PowerShell의 Get-Acl로 읽는다 — Setup이 32/64비트 어느 쪽으로
// 돌아도 포인터 크기를 신경 쓸 필요가 없게.
function CheckExistingAppDir(const Dir: String): Integer;
var
  SysDir, Params: String;
  ResultCode: Integer;
begin
  Result := -1;
  Params := AppDirCheckParams;
  StringChangeEx(Params, '@DIR@', PsQuoteLiteral(Dir), True);
  // PATH에 끼워 넣은 가짜 powershell.exe가 관리자 권한으로 실행되지 않게 전체 경로로 부른다. 작업 폴더도 System32로
  // 고정한다 — 확인하려는 폴더(누가 미리 만들어 DLL을 심어 뒀을 수 있음)를 작업 폴더로 두면 안 된다.
  SysDir := ExpandConstant('{sys}');
  if Exec(SysDir + '\WindowsPowerShell\v1.0\powershell.exe', Params, SysDir, SW_HIDE, ewWaitUntilTerminated, ResultCode) then
  begin
    Log('설치 폴더 검사 결과 코드: ' + IntToStr(ResultCode) + ' (0 = 잠긴 폴더, 2 = 다른 소유자, 3 = 읽지 못함, 4 = 관리자 소유지만 다른 계정도 쓸 수 있음)');
    Result := ResultCode;
  end
  else
    Log('설치 폴더 검사용 PowerShell을 실행하지 못했습니다: ' + SysErrorMessage(ResultCode));
end;

// 재설치(업데이트) 시나리오 대비 — [Files]가 파일을 덮어쓰기 전에, 이전 설치가 남긴 서비스가
// 그대로 떠 있으면 livekit-server.exe/node.exe가 잠겨 있어서 "DeleteFile 실패; 코드 5. 액세스가
// 거부되었습니다"로 설치 자체가 막힌다(2026-09-18 실제 발생). PrepareToInstall은 마법사에서
// 설치 경로가 정해진 뒤, 파일 복사가 시작되기 직전에 실행되므로 딱 맞는 자리다.
//
// 보안(권한 상승 방지): 기본 설치 경로 C:\TangoTalk-Server는 일반 사용자도 만들 수 있어서(C:\가 폴더
// 생성을 허용), 관리자가 설치하기 "전에" 누군가 그 폴더를 미리 만들어 파일을 심어 둘 수 있다 — 그 파일은
// 설치 뒤 SYSTEM/NetworkService 서비스로 실행되므로 곧바로 권한 상승이 된다. 그래서:
//   (1) 설치 경로가 링크(정션/심볼릭 링크)면 설치를 멈춘다 — "폴더가 있는지"(DirExists)보다 먼저 본다. 가리키는 대상이
//       없는(끊어진) 링크처럼 "있는 폴더"인지 애매한 경우에도, 최초 설치로 보고 통과시켜 Inno가 링크 너머에 설치하는
//       일이 없게 링크면 무조건 막는다(GetFileAttributes는 링크를 따라가지 않고 링크 자신의 속성을 돌려준다).
//   (2) 폴더가 이미 있으면 "우리가 예전에 정식으로 설치한 폴더"(HKLM 제거 키 일치)이거나 "잠긴 폴더"(CheckExistingAppDir =
//       0: 소유자가 Administrators/SYSTEM이고 다른 계정에는 쓰기류 권한이 없음)일 때만 그대로 설치한다. 제거 키만 보면 안 되는
//       이유: 일반 제거(unins000 / 설치된 앱)는 제거 키를 지우지만 {app}의 pgsql·pgsql-data·secrets·server\.env·uploads·
//       certs·backups는 일부러 남기고([UninstallDelete] 참고), "서버 완전 삭제"(Uninstall-Full.ps1) 뒤에도 backups·로그가
//       남는다 — 제거한 뒤 같은 경로에 다시 설치해서 데이터를 이어 쓰는 정상적인 경우가 막혀 버린다. 잠금이 생긴 뒤의 설치는
//       제거해도 루트 권한이 잠긴 그대로라 묻지 않고 통과한다.
//       관리자 소유지만 다른 계정도 쓸 수 있는 폴더(4)는 확인 창으로 묻는다 — 잠금 전 버전으로 설치했다가 일반 제거한 폴더가
//       바로 이 모양(소유자 Administrators, 권한은 C:\에서 물려받은 "Authenticated Users: 수정")이라 막을 수만은 없고, 같은
//       모양의 폴더를 다른 계정이 준비해 둘 수도 있어 자동으로 받지도 않는다. 기본 단추는 "아니요"이고, /SUPPRESSMSGBOXES
//       (무인 설치)면 SuppressibleMsgBox가 "아니요"를 돌려줘 거부된다. "예"면 설치 뒤 Setup-TangoTalkServer.ps1이 잠근다.
//       (빈 문자열이 아닌 Result를 돌려주면 Inno가 설치를 중단한다.) 중단 안내에서 폴더를 지우라고 하지 않는다 — 그
//       폴더에 실제 DB·비밀값·백업이 들어 있을 수 있다.
//   (3) 서비스를 멈출 때 {app}\tools\nssm.exe(바꿔치기됐을 수 있음) 대신 System32의 net.exe로 멈춘다 —
//       절대 설치 폴더 안의 실행 파일을 관리자 권한으로 실행하지 않는다.
// 최초 설치면 이 시점엔 {app}가 아직 없으므로(Inno는 파일 복사 단계에서 만든다) (1)만 보고 통과한다.
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  AppDir, NetPath: String;
  ResultCode, DirCheck: Integer;
  Trusted: Boolean;
begin
  Result := '';
  AppDir := ExpandConstant('{app}');

  if DirIsReparsePoint(AppDir) then
  begin
    Result := '설치 폴더(' + AppDir + ')가 링크(정션/심볼릭 링크)입니다. 링크가 가리키는 다른 폴더에 서버 프로그램과 비밀값이 깔리게 되므로, 보안을 위해 이 위치에는 설치하지 않습니다.'
      + #13#10#13#10 + '링크가 가리키는 폴더에 예전 서버의 데이터가 들어 있을 수 있으니, 링크나 그 폴더를 지우기 전에 먼저 내용을 확인하세요.'
      + #13#10 + '설치 프로그램을 다시 실행해 링크가 아닌 다른 설치 경로(새 폴더)를 고르세요.';
    exit;
  end;
  if not DirExists(AppDir) then
    exit;

  // 제거 키가 맞으면 PowerShell을 띄울 필요가 없으므로 폴더 검사는 그다음에만 한다.
  Trusted := IsPriorTangoTalkInstall(AppDir);
  if not Trusted then
  begin
    DirCheck := CheckExistingAppDir(AppDir);
    if DirCheck = AppDirLocked then
      Trusted := True
    else if DirCheck = AppDirAdminShared then
    begin
      if SuppressibleMsgBox('설치 폴더(' + AppDir + ')가 이미 있습니다. 이 PC의 관리자 권한으로 만든 폴더이지만, 다른 Windows 계정도 이 폴더에 파일을 넣거나 폴더 이름을 바꿀 수 있게 권한이 열려 있습니다.'
          + #13#10#13#10 + '설치 폴더 잠금 기능이 생기기 전 버전의 TangoTalk 서버를 이 경로에 설치했다가 제거한 폴더가 이렇게 보입니다. 바로 그 폴더가 확실할 때만 "예"를 누르세요 — 설치가 끝나면 이 폴더는 관리자 전용으로 잠깁니다.'
          + #13#10#13#10 + '확실하지 않으면 "아니요"를 누르세요. 다른 계정이 준비해 둔 폴더라면 그 안에 넣어 둔 프로그램이 서버(SYSTEM 권한)로 실행될 수 있습니다.'
          + #13#10#13#10 + '이 폴더에 설치를 계속할까요?',
          mbConfirmation, MB_YESNO or MB_DEFBUTTON2, IDNO) <> IDYES then
      begin
        Result := '설치 폴더(' + AppDir + ')는 다른 계정도 파일을 넣거나 이름을 바꿀 수 있는 폴더라서, 보안을 위해 이 폴더에는 설치하지 않았습니다(무인 설치 /SUPPRESSMSGBOXES에서는 확인 창 없이 이렇게 멈춥니다).'
          + #13#10#13#10 + '이 폴더에는 예전 서버의 데이터(pgsql-data의 DB, secrets의 비밀값, backups의 백업, server\.env 등)가 들어 있을 수 있습니다. 지우지 말고 먼저 내용을 확인한 뒤, 필요한 것은 안전한 곳으로 옮겨 두세요.'
          + #13#10 + '이 PC에서 예전에 설치했던 TangoTalk 서버 폴더가 확실하면 설치 프로그램을 다시 실행해 확인 창에서 "예"를 누르고, 아니면 다른 설치 경로(새 폴더)를 고르세요.';
        exit;
      end;
      Log('설치 폴더 검사: 다른 계정도 쓸 수 있는 폴더 — 관리자가 확인 창에서 "예"를 눌러 계속합니다(설치 뒤 잠금).');
      Trusted := True;
    end;
  end;
  if not Trusted then
  begin
    Result := '설치 폴더(' + AppDir + ')가 이미 있는데, 이전 TangoTalk 서버 설치나 이 PC의 관리자 권한으로 만든 폴더인지 확인되지 않았습니다. 관리자 권한 없이 미리 만들어 둔 폴더라면 그 안에 심어 둔 프로그램이 서버(SYSTEM 권한)로 실행될 수 있어, 보안을 위해 이 폴더에는 설치하지 않습니다.'
      + #13#10#13#10 + '이 폴더에는 예전 서버의 데이터(pgsql-data의 DB, secrets의 비밀값, backups의 백업, server\.env 등)가 들어 있을 수 있습니다. 지우지 말고 먼저 내용을 확인한 뒤, 필요한 것은 안전한 곳으로 옮겨 두세요.'
      + #13#10 + '설치 프로그램을 다시 실행해 다른 설치 경로(새 폴더)를 고르세요.';
    exit;
  end;

  // 여기까지 왔으면 우리가 예전에 설치한 폴더다(재설치/업그레이드/제거 후 재설치 — 또는 관리자가 확인 창에서 그렇다고 답한
  // 폴더). 떠 있는 서비스를 System32 net.exe로 멈춘다.
  // net stop은 서비스가 실제로 멈출 때까지 기다린다(의존 서비스가 없어 확인 프롬프트도 안 뜬다). 이미 멈췄거나
  // 없는 서비스면 오류 코드만 돌려주므로 무시한다. 서비스 재시작은 Setup-TangoTalkServer.ps1(7/7)이 다시 한다.
  NetPath := ExpandConstant('{sys}\net.exe');
  Exec(NetPath, 'stop "TangoTalkLiveKit"', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Exec(NetPath, 'stop "TangoTalkServer"', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  // 서비스가 "정지됨"으로 보고된 뒤에도 OS가 실제로 파일 핸들을 놓는 데 살짝 시간이 걸릴 수 있어서 여유를 둔다.
  Sleep(1000);
end;
