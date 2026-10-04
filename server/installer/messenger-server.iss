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
Source: "Get-PairingCode.ps1"; DestDir: "{app}"
Source: "Update-Server.ps1"; DestDir: "{app}"
Source: "Restart-Server.ps1"; DestDir: "{app}"
Source: "Storage-Path.ps1"; DestDir: "{app}"
Source: "External-Address.ps1"; DestDir: "{app}"
Source: "Backup-Data.ps1"; DestDir: "{app}"
Source: "Restore-Data.ps1"; DestDir: "{app}"
Source: "Reset-Data.ps1"; DestDir: "{app}"
Source: "Uninstall-Full.ps1"; DestDir: "{app}"
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
Name: "{group}\서버 콘솔로 실행"; Filename: "{app}\node\node.exe"; Parameters: """{app}\server\src\index.js"""; WorkingDir: "{app}\server"; Tasks: runasconsole
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
; DB를 파일 하나로 백업한다({app}\backups\에 저장) — pg_dump 경로/포트/비밀번호를 몰라도
; 콘솔 명령어 없이 바로 된다. 관리자 권한이 필요해 스스로 승격한다.
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
function GetRunMode(Param: string): string;
begin
  if WizardIsTaskSelected('runasconsole') then
    Result := 'console'
  else
    Result := 'service';
end;

// 재설치(업데이트) 시나리오 대비 — [Files]가 파일을 덮어쓰기 전에, 이전 설치가 남긴 서비스가
// 그대로 떠 있으면 livekit-server.exe/node.exe가 잠겨 있어서 "DeleteFile 실패; 코드 5. 액세스가
// 거부되었습니다"로 설치 자체가 막힌다(2026-09-18 실제 발생). PrepareToInstall은 마법사에서
// 설치 경로가 정해진 뒤, 파일 복사가 시작되기 직전에 실행되므로 딱 맞는 자리다. 최초 설치라서
// {app}\tools\nssm.exe가 아직 없으면 FileExists가 false라 조용히 건너뛴다. 서비스 재시작은
// Setup-TangoTalkServer.ps1(7/7 단계)이 어차피 다시 해주므로 여기서는 멈추기만 한다.
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  NssmPath: String;
  ResultCode: Integer;
begin
  Result := '';
  NssmPath := ExpandConstant('{app}\tools\nssm.exe');
  if FileExists(NssmPath) then
  begin
    Exec(NssmPath, 'stop TangoTalkLiveKit', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
    Exec(NssmPath, 'stop TangoTalkServer', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
    // 서비스가 "정지됨"으로 보고된 뒤에도 OS가 실제로 파일 핸들을 놓는 데 살짝 시간이 걸릴 수
    // 있어서 여유를 둔다.
    Sleep(1000);
  end;
end;
