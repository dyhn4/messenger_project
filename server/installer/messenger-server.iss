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
; 경로를 고정한다 — PostgreSQL/NSSM/여러 PowerShell 스크립트가 이 경로를 문자열로 조합해서
; 쓰기 때문에, 사용자가 임의 경로(특히 공백 포함 경로)를 고르게 두면 인용 버그 위험이 커진다.
DisableDirPage=yes
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
Source: "{#BinDir}\pgsql-installer.exe"; DestDir: "{tmp}"; Flags: deleteafterinstall
; StageDir는 build_server_installer.ps1이 이미 필요한 것만(certs/uploads/.env/로그/개발용
; node_modules 등을 뺀) 정리해둔 결과라 여기서 별도 Excludes가 필요 없다.
Source: "{#StageDir}\*"; DestDir: "{app}\server"; Flags: recursesubdirs createallsubdirs ignoreversion
Source: "Setup-TangoTalkServer.ps1"; DestDir: "{app}"
Source: "Get-PairingCode.ps1"; DestDir: "{app}"
Source: "Update-Server.ps1"; DestDir: "{app}"
Source: "Storage-Path.ps1"; DestDir: "{app}"
Source: "Reset-Data.ps1"; DestDir: "{app}"
Source: "Uninstall-Full.ps1"; DestDir: "{app}"
Source: "README-설치후.txt"; DestDir: "{app}"

[Icons]
Name: "{group}\새 기기 페어링 코드 발급"; Filename: "powershell.exe"; Parameters: "-NoLogo -ExecutionPolicy Bypass -File ""{app}\Get-PairingCode.ps1"""
Name: "{group}\서버 콘솔로 실행"; Filename: "{app}\node\node.exe"; Parameters: """{app}\server\src\index.js"""; WorkingDir: "{app}\server"; Tasks: runasconsole
Name: "{group}\설치 후 안내"; Filename: "{app}\README-설치후.txt"
; 개발 PC에서 package_server_update.ps1로 만든 zip을 골라서 적용하는 창을 띄운다(DB는
; 안 건드리고 코드/패키지/스키마만 갱신) — 관리자 권한이 필요해 스스로 승격한다.
Name: "{group}\서버 업데이트"; Filename: "powershell.exe"; Parameters: "-NoLogo -ExecutionPolicy Bypass -File ""{app}\Update-Server.ps1"""
; 첨부파일 저장 위치 확인/변경(NAS·다른 PC 공유 폴더 등) — 관리자 권한이 필요해 스스로 승격한다.
Name: "{group}\첨부파일 저장소"; Filename: "powershell.exe"; Parameters: "-NoLogo -ExecutionPolicy Bypass -File ""{app}\Storage-Path.ps1"""
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
Filename: "{app}\tools\nssm.exe"; Parameters: "stop TangoTalkServer"; Flags: runhidden waituntilterminated skipifdoesntexist; RunOnceId: "StopSvc"
Filename: "{app}\tools\nssm.exe"; Parameters: "remove TangoTalkServer confirm"; Flags: runhidden waituntilterminated skipifdoesntexist; RunOnceId: "RemoveSvc"
Filename: "netsh.exe"; Parameters: "advfirewall firewall delete rule name=""TangoTalk Server (main)"""; Flags: runhidden waituntilterminated; RunOnceId: "DelFw1"
Filename: "netsh.exe"; Parameters: "advfirewall firewall delete rule name=""TangoTalk Server (pairing)"""; Flags: runhidden waituntilterminated; RunOnceId: "DelFw2"

[UninstallDelete]
; 프로그램 파일만 지정한다 — .env / certs / uploads / secrets / pgsql / pgsql-data / releases는
; 절대 여기 추가하지 않는다(일반 제거로 실데이터가 지워지면 안 된다는 게 이 섹션의 핵심 불변식).
Type: filesandordirs; Name: "{app}\node"
Type: filesandordirs; Name: "{app}\tools"
Type: filesandordirs; Name: "{app}\server\node_modules"
Type: filesandordirs; Name: "{app}\server\src"
Type: filesandordirs; Name: "{app}\server\scripts"
Type: filesandordirs; Name: "{app}\server\drizzle"
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
