# TangoTalk 서버 설치 프로그램

새 "서비스 PC"에 Node.js 서버 + PostgreSQL을 한 번에 설치하는 Inno Setup 기반 설치 프로그램.
자세한 배경/설계는 저장소 루트 `README.md`의 관련 섹션과, 이 기능을 설계할 때 정리한 계획을
참고. 이 폴더는 이 설치 프로그램 자체를 유지보수하는 사람을 위한 메모다.

## 기존 서버에는 새 설치 프로그램을 한 번 다시 실행해야 한다(중요)

업데이트 zip(`package_server_update.ps1`)은 `installer/`를 빼고 `server/`만 담고, 이미 설치된 서버의 `Update-Server.ps1`
(옛 버전이든 새 버전이든)은 그 zip을 `{app}\server`에만 복사한다 — **설치 폴더 루트의 스크립트(`{app}\*.ps1`)·
`README-설치후.txt`·시작 메뉴 바로가기·`[Code]` 검사는 zip 업데이트로 절대 바뀌지 않는다.** 게다가 지금 깔려 있는 옛
`Update-Server.ps1`은 설치 폴더를 잠그지도 않는다. 그래서 이번 보안 변경 —

- 설치 폴더 잠금(`Folder-Acl.ps1`의 `Protect-InstallDir`, S6)과 백업 폴더 잠금·보관 개수(`Backup-Data.ps1`),
- 스스로 승격하고 서버 폴더에서 node를 돌리게 고친 관리 스크립트(`Get-PairingCode.ps1`·`Reset-Data.ps1` 등),
  "서버 콘솔로 실행"의 `Start-ServerConsole.ps1`, 운영자 복구 `Grant-ServerAdmin.ps1`,
- 설치 전 폴더 검증(`PrepareToInstall`),
- 서버를 `NODE_ENV=production`으로 돌리기(서비스는 `Setup-TangoTalkServer.ps1` 7단계·`Update-Server.ps1` 5단계, 콘솔 모드는
  `Start-ServerConsole.ps1` — 아래 "설치된 서버는 `NODE_ENV=production`으로 돈다"),
- 한글 등이 든 운영자 비밀번호도 통과하게 고친 `Reset-Data.ps1`·`Restore-Data.ps1`·`Uninstall-Full.ps1`의 운영자 인증(아래
  "완전 삭제/초기화는 확인 문구 하나만으로 되지 않는다" — 함께 고친 `server/scripts/verify-admin.mjs`는 zip으로도 들어가고 옛
  스크립트가 보내는 입력도 예전처럼 받지만, 옛 스크립트는 그런 글자를 이미 '?'로 바꿔 보내므로 설치 프로그램을 다시 실행하기
  전에는 여전히 실패한다)

은 **기존 서버의 관리자가 새 `tangotalk-server-setup.exe`를 같은 설치 경로로 한 번 다시 실행해야** 그 서버에 들어간다
(데이터·`.env`·DB 비밀번호는 그대로 — 제거 키가 맞으므로 `PrepareToInstall`도 통과한다). 그 뒤로는 "서버 업데이트"가 매
업데이트의 1단계에서 잠금을 다시 맞춘다. 운영자용 안내는 `README-설치후.txt` 맨 위 "이미 쓰던 서버에 새 버전을 적용할
때"에 있고(설치 폴더에 `Folder-Acl.ps1`이 없으면 잠금 전 버전), 릴리스 안내와 루트 `README.md`에도 같은
내용이 있어야 한다. 반대로 `server/` 안 파일(예: `server/scripts/grant-server-admin.mjs`)은 zip으로도 들어가므로, 설치
프로그램을 아직 다시 실행하지 않은 서버에서도 관리자 권한 PowerShell에서
`cd <설치 경로>\server; ..\node\node.exe scripts\grant-server-admin.mjs <아이디>`로 직접 돌릴 수 있다.

아이폰 웹 앱용 정식 인증서(아래 "웹 앱 주소(정식 인증서)")도 같다 — 발급·갱신하는 서버 코드(`server/src/webTlsConfig.js`·`acme.js`·
`acmeRenewal.js` 등)는 zip으로 들어가지만, 시작 메뉴 "웹 앱 주소(정식 인증서)"(`Web-Domain.ps1`), 그 방화벽 규칙을 일반 제거가 지우는
`[UninstallRun]` 줄, 재설치 때 규칙을 되살리는 `Setup-TangoTalkServer.ps1` 6단계는 설치 프로그램을 다시 실행해야 들어간다. 그 전에는
관리자가 `.env`(`WEB_DOMAIN` 등)와 방화벽 인바운드 규칙(TCP 443·80)을 손으로 맞춰야 한다.

## 빌드

저장소 루트에서:

```powershell
.\build_server_installer.ps1
```

`installer/bin/`(Node 포터블 런타임 zip, PostgreSQL 설치 프로그램, `nssm.exe`)와 `installer/stage/`
(정리된 `server/` 소스 + `npm install`로 새로 만든 `node_modules`)를 채운 뒤 ISCC.exe로
`messenger-server.iss`를 컴파일한다. 셋 다 git에는 안 올라간다(`server/.gitignore`) — 매 빌드마다 새로 받고 새로 만든다.

## 파일 구성

| 파일 | 역할 |
|---|---|
| `messenger-server.iss` | Inno Setup 스크립트. `PrivilegesRequired=admin`, 설치 경로 선택 가능(기본값 `C:\TangoTalk-Server`) |
| `Setup-TangoTalkServer.ps1` | 설치 마지막 단계에서 실행 — PostgreSQL 무인 설치, 설치 폴더 접근 권한 잠금(2.5단계), DB 계정/생성, `.env` 작성, 마이그레이션, 방화벽(`.env`에 `WEB_DOMAIN`이 있으면 웹 앱 주소용 규칙도 되살림 — 없으면 남은 규칙을 지움, 실패해도 경고만), 서비스 등록(서버 서비스는 `NODE_ENV=production` — 이미 있던 서비스도 재시작 전에 맞춤). 재실행해도 안전(idempotent) |
| `Folder-Acl.ps1` | 폴더 접근 권한 잠금 공용 함수(dot-source 전용, 직접 실행하면 함수만 정의) — `Protect-InstallDir`(설치 폴더 전체), `Set-AdminOnlyAcl`(비밀값·백업·바깥 첨부파일 폴더), `Get-FolderLockKind`(잠가도 되는 폴더인지 판단). 아래 "설치 폴더는 SYSTEM/Administrators 전용" 참고 |
| `Start-ServerConsole.ps1` | 시작 메뉴 "서버 콘솔로 실행"(콘솔 모드 설치 시) — 스스로 관리자 권한으로 승격한 뒤 서버 폴더에서 `node src\index.js`를 이 창에서 실행(설치 폴더가 잠겨 있어 일반 권한으로는 `node.exe`를 못 읽음). 서비스 모드처럼 `NODE_ENV=production`으로 띄운다 |
| `tests/Folder-Acl.Tests.ps1`(개발 PC 전용, 설치 프로그램에 안 들어감) | `Folder-Acl.ps1`의 판단 규칙·정션 처리·잠금 결과를 관리자 권한 없이 `%TEMP%` 안의 가짜 설치 폴더로 확인한다(실제 설치 폴더·서비스는 안 건드림). `Folder-Acl.ps1`을 고쳤으면 돌려볼 것 — 아래 체크리스트 첫 줄 |
| `tests/Install-Guard.Tests.ps1`(개발 PC 전용, 설치 프로그램에 안 들어감) | ISCC 없이 `messenger-server.iss`를 확인한다 — `PrepareToInstall`의 기존 폴더 검사 명령(`AppDirCheckParams`: 소유자 + 그 폴더 자신의 권한)을 그대로 꺼내 Inno의 `Exec`와 같은 명령줄로 실제 실행(작은따옴표·굽은 따옴표가 든 폴더 이름, 다른 계정의 쓰기류 권한·상속 전용 항목·일반 권한 비트·거부 항목을 정해 둔 임시 폴더, 잠금 전 모양의 설치 폴더가 `Protect-InstallDir`로 잠근 뒤 통과하는지, 이 PC의 시스템 폴더·`C:\` 바로 아래 폴더), 결과 코드 상수·쓰기류 권한 마스크가 맞는지, 끊어진 정션을 `GetFileAttributesW`가 링크로 보는지, 루트 `*.ps1`이 전부 `[Files]`에 있는지, 관리 스크립트가 맨 처음 스스로 승격하고 node를 서버 폴더에서 부르는지. `messenger-server.iss`나 루트 스크립트를 고쳤으면 돌려볼 것 |
| `tests/Admin-Verify.Tests.ps1`(개발 PC 전용, 설치 프로그램에 안 들어감) | 운영자 인증 `Test-ServerAdminPassword`(`Reset-Data.ps1`·`Restore-Data.ps1`·`Uninstall-Full.ps1`)가 세 곳에서 같은지, 그 함수로만 `verify-admin.mjs`를 부르는지, Windows PowerShell 5.1 기본 `$OutputEncoding`(ASCII)에서도 한글·이모지·앞뒤 공백·따옴표가 든 비밀번호와 한글 아이디를 글자 그대로 넘기는지 — 진짜 `verify-admin.mjs`를 `%TEMP%`의 가짜 서버 폴더(가짜 pg·dotenv·bcryptjs)에서 돌려 본다(DB·`.env`는 안 건드림, node 필요). 예전 방식(그냥 파이프)이 '?'로 실패하는 것도 재현한다. 세 스크립트나 `verify-admin.mjs`를 고쳤으면 돌려볼 것 — `verify-admin.mjs`의 stdin 규칙(BOM·끝 줄바꿈·잘못된 UTF-8)은 `server/test/verifyAdminStdin.test.js` |
| `tests/Web-Domain.Tests.ps1`(개발 PC 전용, 설치 프로그램에 안 들어감) | `Web-Domain.ps1`의 함수만 꺼내(창·승격은 안 돌림) 도메인·포트·이메일 검증, 서버가 이미 쓰는 포트와의 겹침, `.env` 고치기(BOM 있는/없는 UTF-8·ANSI(CP949)·LF·중복 키·`export`·따옴표·주석 → BOM 없는 UTF-8 + CRLF, 다른 줄은 글자 그대로), **서버의 `dotenv` + `server/src/webTlsConfig.js`가 그 `.env`를 같은 뜻으로 읽는지**(node 필요 — 서버 쪽 규칙이 바뀌면 여기서 걸림), 방화벽 규칙(가짜 netsh — 이름으로 지우고 node.exe 전용으로 다시 만듦), 포트 사용 확인, 127.0.0.1의 임시 TLS 서버(메모리에서 만든 자체 서명·"(STAGING)" 인증서, 인증서 저장소엔 안 넣음)로 [인증서 확인], 안내 문구, 적용 전 경고(DNS·포트는 가짜 함수)를 본다. 구성도 본다 — `Setup-TangoTalkServer.ps1`의 `Set-WebFirewallRules`가 같은지, Setup이 그 함수를 경고만 남기는 try 안에서 부르는지와 `.env`의 `WEB_DOMAIN` 줄을 읽는 규칙, `[UninstallRun]`이 두 규칙을 지우는지, 시작 메뉴 바로가기, 문자열 안 `$이름` 뒤에 한글이 붙어 빈 값이 되는 곳(이 기능의 두 스크립트는 실패, 다른 설치 스크립트는 "메모:"). DNS·실제 방화벽·서비스·`.env`는 안 건드림. `Web-Domain.ps1`·Setup 6단계의 웹 규칙·`[UninstallRun]`이나 서버의 `webTlsConfig.js`를 고쳤으면 돌려볼 것 |
| `tests/Service-Env.Tests.ps1`(개발 PC 전용, 설치 프로그램에 안 들어감) | 설치된 서버가 모든 시작 경로에서 `NODE_ENV=production`인지 — `Setup-TangoTalkServer.ps1`·`Update-Server.ps1`의 `Set-NodeServiceProductionEnv`가 같은지, 서버 서비스를 nssm으로 start/restart하기 전마다 부르는지, `$env:NODE_ENV`는 `Start-ServerConsole.ps1`만 node 실행 전에 넣는지, 레지스트리에 쓰는 목록(REG_MULTI_SZ, 다른 변수 유지)을 가짜 `Get-Item`/`Set-ItemProperty`로 본다(진짜 레지스트리·서비스는 안 건드림). 두 스크립트의 서비스 부분을 고쳤으면 돌려볼 것 |
| `Get-PairingCode.ps1` | 시작 메뉴 "새 기기 페어링 코드 발급"이 호출 — `server/scripts/pair.mjs`와 같은 일을 Node 없이 순수 PowerShell로. `.env`의 `PORT`/`PAIRING_PORT`를 읽어야 해서(설치 폴더가 관리자 전용) 스스로 승격 — 승격을 거절하면 이유를 창으로 알림 |
| `Restart-Server.ps1` | "서버 재시작" — `TangoTalkServer` 서비스만 재시작(코드/DB 안 건드림). 재시작 뒤 Running이 아니면 `server\service-err.log`를 그 자리에서 메모장으로 열지 물어봄(이 창이 관리자 권한이라 메모장도 관리자 권한으로 열림). 스스로 승격 |
| `Update-Server.ps1` | "서버 업데이트" — 업데이트 zip을 파일 선택 창에서 골라 적용(WinForms GUI). 먼저 설치 폴더 접근 권한을 다시 잠그고(1/5), DB는 안 건드림, npm install+마이그레이션+서비스 재시작 자동(재시작 전에 서버 서비스의 `NODE_ENV=production`을 다시 맞춤 — 5/5). 관리자 권한 필요해 스스로 승격 |
| `Storage-Path.ps1` | "첨부파일 저장소" — 첨부파일 저장 위치(`UPLOADS_DIR`)를 보여주고 NAS/다른 PC 공유 폴더 등으로 바꿈(WinForms GUI). 설치 폴더 밖의 로컬 폴더는 관리자 전용으로 잠근 뒤 기존 파일 이동 여부를 물어보고 `.env` 갱신 + 서비스 재시작. 관리자 권한 필요해 스스로 승격 |
| `External-Address.ps1` | "외부 접속 주소" — 사내망 밖(LTE/5G)에서 접속할 DDNS 도메인/공인 IP(`EXTERNAL_ADDRESS`)를 보여주고 바꾸거나 끔(WinForms GUI). 그 주소가 지금 인증서에 없으면(서버가 같은 키로 인증서를 새로 만듦 — 최신 앱은 그대로, 공개키 핀닝 전의 예전 앱만 재페어링 필요) 적용 전에 경고. `.env` 갱신 + 서비스 재시작(화상회의 공인 IP는 서버가 `livekit.yaml`에 넣고 LiveKit 서비스를 재시작 — `server/src/livekitNat.js`). 공유기 포트포워딩(메인 포트, 화상회의 UDP 범위·TCP, 초대 안내 페이지를 밖에서 열려면 페어링 포트)은 직접 해야 함. 관리자 권한 필요해 스스로 승격 |
| `Web-Domain.ps1` | "웹 앱 주소(정식 인증서)" — 아이폰(사파리 웹 앱)용 공인 인증서 설정(WinForms GUI). 도메인(`WEB_DOMAIN`)·웹 HTTPS 포트(`WEB_HTTPS_PORT`, 기본 443)·인증용 HTTP 포트(`ACME_HTTP_PORT`, 기본 80, 0이면 HTTP-01 안 씀)·이메일(`ACME_EMAIL`, 선택)·시험 발급(`ACME_STAGING=1`, 기본 끔)을 `.env`에 쓰고, 방화벽 규칙 `TangoTalk Server (web)`·`(web-acme)`(이 서버의 `node.exe` 전용)을 맞추고 서비스를 재시작. 적용 전에 포트 겹침(서버 포트·LiveKit·PostgreSQL)은 거절하고, 다른 프로그램(IIS/HTTP.sys 등)이 쓰는 포트·DNS에서 못 찾거나 사설 IP만 가리키는 도메인은 경고. 공유기 포트포워딩(외부 443 → 웹 포트, 외부 80 → 인증용 포트, 웹 포트가 443이 아니면 그 번호도)·iptime.org 주간 한도·아이폰 사용법을 복사할 수 있는 글로 안내. [인증서 확인]은 127.0.0.1의 웹 포트에 SNI로 붙어 지금 걸린 인증서(정식/시험용/그 밖)를 보여 줌. "끄기"(또는 도메인을 비우고 적용)는 `WEB_DOMAIN`만 비우고 규칙을 지움. 발급·갱신·상태(관리자 콘솔)는 서버 몫. 관리자 권한 필요해 스스로 승격 |
| `Backup-Data.ps1` | "백업" — 쓰기 전에 `backups\`를 관리자 전용으로 잠근 뒤, 관리자 콘솔에서 백업 암호를 정해 두었으면 `server\scripts\backup-now.mjs`로 **전체 백업**(관리자 콘솔 "지금 백업"과 같음 — `{app}\backups\tangotalk_<날짜>_<시각>\`, 아래 "서버 전체 백업"). 암호를 아직 안 정했거나(종료 코드 3) 전체 백업이 실패하면 예전처럼 DB만 `messenger_<날짜시각>.dump`로 저장(`pg_dump -F c`, 최근 10개 — `$KeepBackups`). 서버는 멈추지 않음. 관리자 권한 필요해 스스로 승격 |
| `Restore-Data.ps1` | "복원" — 파일 선택 창(WinForms)에서 전체 백업 폴더의 `manifest.json`이나 예전 `.dump`를 고름. 전체 백업은 `server\scripts\restore-backup.mjs`(check → 백업 암호 verify → restore)로 DB·설정·인증서·첨부파일을 되돌리고 마이그레이션(`drizzle-kit migrate`), `.dump`는 예전처럼 `pg_restore --clean --if-exists`. `Reset-Data.ps1`과 같은 안전장치(서버 운영자 계정 인증 + `RESTORE` 입력 확인) — 단 회원이 없는 새 설치에 전체 백업을 복원할 때는 확인할 운영자가 없어 백업 암호로만 확인. 복원 중엔 서비스 정지 후 재시작. 관리자 권한 필요해 스스로 승격 |
| `Reset-Data.ps1` | "DB 데이터 초기화" — 서버는 그대로 두고 데이터만 비움. 서버 운영자 계정 인증 + `RESET` 입력 확인 둘 다 필수. 스스로 승격하고 서버 폴더로 이동한 뒤 node 실행(`reset-data.mjs`는 `.env`를 현재 폴더에서 읽음 — 예전엔 승격도 이동도 없어 잠긴 폴더의 `node.exe`를 못 읽었다) |
| `Uninstall-Full.ps1` | "서버 완전 삭제(PostgreSQL·Node 앱·DB 데이터 모두)" — PostgreSQL 자체(`uninstall-postgresql.exe`)와 DB 데이터를 정식 제거한 뒤, 마지막 단계로 일반 제거 프로그램(`unins000.exe /VERYSILENT`)까지 자동 실행해서 Node 앱 프로그램 파일도 지움. 서버 운영자 계정 인증(`server/scripts/verify-admin.mjs`) + `DELETE` 입력 확인 둘 다 필수 |
| `Grant-ServerAdmin.ps1` | 서버 운영자 복구(시작 메뉴 없음 — 설치 폴더에서 오른쪽 클릭 → "PowerShell에서 실행") — 아이디를 물어 `server/scripts/grant-server-admin.mjs <아이디>`를 번들 node로 서버 폴더에서 실행하고 결과를 보여 준 뒤 멈춤. 그 스크립트가 **활성(탈퇴·정지 아닌) 서버 운영자가 한 명도 없을 때만** 기존 계정을 운영자로 지정·정지 해제하고, 운영자가 있으면 거절(종료 코드 1). `.env`가 관리자 전용이라 스스로 승격 |
| `README-설치후.txt` | 설치되는 사람이 보는 안내문(`[Files]`로 설치됨) |
| `../guide/`(server/guide, 설치 시 `{app}\server\guide`) | 앱의 삼선 메뉴 "도움말"(모든 회원)이 여는 초보자용 안내 웹페이지(메신저·프로젝트 이용법 + 스크린샷, 서버 운영자용 "서버 관리" — `server.html`: 설치·시작 메뉴 관리 도구·업데이트·외부 접속 주소·DuckDNS·웹 앱 주소·관리자 콘솔. 누구나 여는 공개 페이지라 실제 도메인·토큰 같은 이 서버 고유 값은 쓰지 않는다). 스테이징에 같이 담기고 서버가 인증 없이 `/guide/`로 서빙한다. 업데이트 zip을 적용할 때 `Update-Server.ps1`이 이 폴더를 통째로 맞춘다(/MIR) |

## 설계상 중요한 결정들 (바꾸기 전에 이유를 먼저 읽을 것)

- **설치 경로는 사용자가 고를 수 있다(`DisableDirPage=no`, 기본값 `C:\TangoTalk-Server`).**
  경로에 공백이 들어갈 수 있다는 뜻이라, PostgreSQL/NSSM/여러 PowerShell 스크립트가 이
  경로를 명령줄 인자로 조합하는 모든 곳이 안전해야 한다. `&`/splat 호출(`& $exe @args`,
  `robocopy @args`)은 배열 원소를 각각 별도 인자로 안전하게 넘겨주지만, **`Start-Process
  -ArgumentList`는 배열을 그냥 공백으로 이어붙이기만 해서 안전하지 않다** — 실제로
  `Setup-TangoTalkServer.ps1`의 PostgreSQL 설치 호출부에 이 버그가 있어서(경로에 공백이 있으면
  `--prefix`/`--datadir` 값이 인자 두 개로 쪼개짐) 값을 이스케이프된 따옴표로 감싸서 고쳤다
  (2026-09-10, 직접 테스트 배치 파일로 재현 후 확인). 새로 `Start-Process -ArgumentList`를
  쓸 일이 있으면 경로가 들어가는 인자는 반드시 `"` + `"` `$value` + `"` + `"` 처럼(PowerShell
  이스케이프로는 `` "`"$value`"" ``) 감쌀 것.
- **PostgreSQL은 전용 설치 경로(`{app}\pgsql`)+전용 포트(`55432`)를 쓴다.** 그 PC에 이미 다른
  PostgreSQL이 있어도(버전이 다르거나 우리가 만든 게 아니라 슈퍼유저 비밀번호를 모르는 경우)
  충돌하지 않게 하려는 의도 — "기존 설치를 어떻게 재사용할지" 문제 자체를 피한다. 포트/경로를
  시스템 기본값으로 바꾸려면 이 회피 전략이 통째로 무효화된다는 점을 감안할 것.
- **DB 계정 비밀번호는 설치하는 사람이 절대 보지 않는다.** `Setup-TangoTalkServer.ps1`이 자동
  생성해서 `{app}\secrets\*.pw`에 저장하고 재사용한다. `server/src/config.js`의 `resolveSecret`
  (JWT_SECRET/DB_ENCRYPTION_KEY 자동 생성)과 같은 철학.
- **설치 폴더는 SYSTEM/Administrators 전용으로 잠근다(`Folder-Acl.ps1`의 `Protect-InstallDir`).**
  기본 경로 `C:\TangoTalk-Server`는 `C:\`의 권한을 물려받아 "Authenticated Users: 수정"이 하위 전체에
  상속되는데, Node 서버·LiveKit은 NSSM 서비스로 **LocalSystem**, PostgreSQL은 **NetworkService**(EDB 설치
  프로그램 기본값)로 실행되므로, 이 PC에 로그인할 수 있는 아무 계정이나 `node.exe`·서버 코드·`nssm.exe`·
  PostgreSQL 실행 파일을 바꿔치기하면 곧바로 SYSTEM 권한 탈취가 됐다(`.env`·비밀값·DB 파일·백업도 아무나
  읽을 수 있었음). 그래서:
  - 루트는 상속을 끊고 SYSTEM(`*S-1-5-18`)·Administrators(`*S-1-5-32-544`)에만 전체 권한(하위 상속)을 준다
    — 나중에 생기는 파일(서버가 첫 실행 때 만드는 `.jwt-secret`·`.db-encryption-key`·`.web-push-vapid.json`·
    `certs\key.pem`, Setup이 만드는 `.env`·`.livekit-secret`·`livekit.yaml`, 첨부파일·로그·백업)도 전부 그대로
    물려받으므로 파일마다 따로 잠그지 않는다. 그룹은 **이름이 아니라 SID로만** 지정한다 — 이름은 Windows
    언어마다 다를 수 있고, icacls는 이름을 못 찾으면(1332) 아무 것도 안 바꾸는데 예전 코드는 출력을 버려서
    실패를 몰랐다.
  - 하위 항목은 전부 소유자를 Administrators로 바꾸고 직접 붙은 권한을 지워 상속만 받게 되돌린다 — 예전
    버전이 `.env`·`.jwt-secret`·`secrets\*.pw`마다 걸던 `Administrators:(R)`(읽기 전용이라 관리자도 "첨부파일
    저장소"/"외부 접속 주소"에서 `.env`를 못 고쳤음)와, 일반 계정이 만들어 둔 파일(소유자라서 권한을 다시
    바꿀 수 있음)까지 정리된다. **정션/폴더 심볼릭 링크는 절대 따라 들어가지 않는다** — `icacls /T`는 `/L`을
    줘도 정션 안으로 들어가는데(직접 확인), 예전엔 아무나 이 폴더에 `C:\Windows`를 가리키는 정션을 심을 수
    있었으므로 링크가 없는 하위 트리만 `/T`로 처리하고, 링크는 링크 자체만 다루고 경고를 남긴다.
  - 예외 1 — PostgreSQL 서비스 계정(레지스트리 서비스 키의 `ObjectName`에서 읽음)에 `pgsql` 읽기·`pgsql-data`
    전체 권한을 **루트를 잠그기 전에** 준다. 지금까지는 C:\에서 물려받은 Users 읽기로 `pgsql\bin`을 읽어
    왔으므로, 순서가 바뀌면 실행 중인 DB가 새 연결마다 띄우는 `postgres.exe`를 못 읽는 순간이 생긴다.
    계정을 SID로 못 바꾸면 두 폴더는 지금 권한 그대로 고정(`/inheritance:d`)하고 경고만 한다(DB를 멈추지 않게).
  - 예외 2 — Users는 루트 폴더 목록과, 시작 메뉴가 **일반 권한으로** 여는 루트 파일(`*.ps1`, `README*`,
    `unins*`)만 읽는다. 관리용 스크립트는(`.env`의 포트를 읽어야 하는 `Get-PairingCode.ps1`, 탐색기에서 여는
    `Grant-ServerAdmin.ps1` 포함) 읽힌 뒤 스스로 승격한다. `install.log` 등 나머지는 관리자 전용.
  - **설치 "전" 폴더 검증(미리 심어둔 폴더/링크로 인한 권한 상승 차단).** 기본 경로 `C:\TangoTalk-Server`는
    일반 사용자도 만들 수 있어(`C:\`가 폴더 생성 허용), 관리자가 설치하기 전에 누군가 그 폴더를 만들어
    `tools\nssm.exe`·`node\` 안 DLL 같은 파일을 심어 두면 설치 과정/서비스가 그 코드를 관리자·SYSTEM 권한으로
    실행해버린다. 그래서 `messenger-server.iss`의 `[Code] PrepareToInstall`이 파일 복사 전에:
    **(a) 설치 경로가 링크(정션/심볼릭 링크)면 중단** — 폴더가 있는지(`DirExists`)보다 **먼저** 본다(대상이 없는
    끊어진 링크도 `GetFileAttributesW`는 링크로 본다 — `tests/Install-Guard.Tests.ps1`). **(b) 폴더가 이미 있으면
    "우리가 예전에 정식 설치한 폴더"(HKLM 제거 키의 `InstallLocation`이 이 경로와 일치 — 일반 사용자는 HKLM에 못
    쓰므로 위조 불가)이거나 "잠긴 폴더"(소유자가 Administrators(`S-1-5-32-544`)/SYSTEM(`S-1-5-18`)이고, 그 폴더 자신의
    DACL에 이 둘 말고는 어떤 계정의 쓰기류 허용 항목도 없음 — `CheckExistingAppDir` 결과 0)일 때만** 그대로 설치한다.
    소유자는 맞는데 다른 계정에도 쓰기류 권한이 있으면(결과 4) **확인 창**으로 묻고(기본 단추 "아니요", `/SUPPRESSMSGBOXES`면
    `SuppressibleMsgBox`가 "아니요"를 돌려줘 거부), 나머지(다른 소유자 2, 못 읽음 3, PowerShell 실행 실패 등)는 중단한다
    (빈 문자열 아닌 `Result`). 제거 키만 보면 안 되는 이유: **일반 제거(unins000 / 설치된 앱)는 제거
    키를 지우면서도 `{app}`의 `pgsql`·`pgsql-data`·`secrets`·`server\.env`·`uploads`·`certs`·`backups`를 일부러
    남기고**(아래 "일반 제거는 데이터를 절대 지우지 않는다"), "서버 완전 삭제"도 `backups`·로그를 남기므로, 제거 키만
    보면 "제거한 뒤 같은 경로에 다시 설치"가 막힌다. 소유자: 일반 사용자는 새 폴더의 소유자를 자기 계정으로만 정할 수 있어
    (Administrators는 승격된 토큰에서만 소유자로 쓸 수 있음) 이런 폴더를 못 만들고, 설치 프로그램이 만든 폴더는 예전
    버전이든(승격된 프로세스가 만든 폴더의 기본 소유자는 Administrators) 잠금 뒤든(`Protect-InstallDir`이 소유자를
    Administrators로 맞춤) 이 조건에 맞는다. **소유자만으로는 부족하다** — 관리자 권한 프로그램이 `C:\` 바로 아래에 만든
    폴더(제조사·드라이버 도구의 설치 파일 폴더, `C:\Temp` 등)도 소유자는 Administrators인데 `C:\`의 "Authenticated Users:
    수정"을 물려받아, 다른 계정이 그런 폴더에 파일을 넣고 이름을 설치 경로로 바꿔 둘 수 있다(예전 소유자 전용 검사는 이런
    폴더를 그냥 받아들였다). 그래서 그 폴더 자신의 권한도 본다 — 쓰기류 = 쓰기·추가(`WriteData`·`AppendData`), 확장 특성·
    특성 쓰기, 하위 항목 삭제, 삭제(이름 바꾸기 포함), 권한 변경, 소유권 가져오기, `GENERIC_WRITE`·`GENERIC_ALL`(마스크
    `0x500D0156` — 상속 전용 항목에는 일반 권한 비트가 그대로 남는다). 물려받은 항목과 상속 전용 항목(안쪽에 생기는 파일에
    그 권한을 줌)도 보고, 거부 항목은 보지 않는다(조심하는 쪽으로 틀린다). 읽기·실행은 괜찮다 — 잠근 설치 폴더
    루트(`Protect-InstallDir`: SYSTEM·Administrators 전체, Users·PostgreSQL 계정은 읽기만)는 일반 제거·완전 삭제 뒤에도
    그대로라 **잠금 뒤의 설치는 묻지 않고 통과**하고, 이름을 바꿔 들여온 폴더는 그 이름 바꾸기에 필요했던 삭제 권한이 그
    폴더 권한에 그대로 보여 통과할 수 없다(`C:\`는 일반 계정에 하위 항목 삭제 권한을 주지 않으므로 폴더 자신의 삭제 권한이
    있어야 이름을 바꿀 수 있다). 확인 창이 필요한 이유: **잠금 전 버전으로 설치했다가 일반 제거한 폴더가 바로 이
    모양**(소유자 Administrators, `C:\` 권한 상속)이라 막을 수만은 없고, 같은 모양의 폴더를 다른 계정이 준비해 둘 수 있어
    자동으로 받지도 않는다 — 창은 "이 PC에서 예전에 설치했다가 제거한 그 폴더가 확실할 때만 예"라고 안내하고, "예"면 설치
    뒤 2.5단계가 잠근다. 검사는 advapi32 포인터 호출 대신 `{sys}\WindowsPowerShell\v1.0\powershell.exe`의 `Get-Acl`로
    한다(Setup이 32/64비트 어느 쪽이든 안전하게, 작업 폴더는 System32 — 검사할 폴더를 작업 폴더로 두면 거기 심어 둔 DLL이
    로드될 수 있다). 명령 전체를 `try`로 감싸 어떤 오류든 3(거부)이 되게 했다(`exit`는 `catch`에 안 잡힌다 — 직접 확인).
    경로는 `PsQuoteLiteral`이 작은따옴표와 PowerShell이 작은따옴표로 치는 U+2018~U+201B를 두 번 써서 감싼다 — 하나라도
    빠뜨리면 그 글자가 든 폴더 이름에서 경로 문자열이 끝나고 뒷부분이 명령으로 읽힌다. 실행하지 못했거나 0·4가 아닌 종료
    코드면 "확인 못 함"으로 보고 막는다. 중단 안내는 **폴더를 지우라고 하지
    않는다** — 그 폴더에 실제 DB·비밀값·백업이 있을 수 있으므로, 내용을 확인·이동한 뒤 다른 경로를 고르라고만 한다.
    또 떠 있는 서비스를 멈출 때 `{app}\tools\nssm.exe`(바꿔치기됐을
    수 있음)가 아니라 **System32의 `net.exe`**로 멈춰, 설치 폴더 안의 실행 파일을 관리자 권한으로 절대 돌리지
    않는다. `Setup-TangoTalkServer.ps1`도 설치 경로/`secrets\`가 링크면(설치 도중 바꿔치기 대비) `Fail`하고,
    `secrets\`를 Local로 못 잠그면(네트워크/FAT 등) 경고를 남긴다(예전엔 조용히 건너뛰어 비밀번호가 노출됐음).
    한계: (1) 설치 폴더 "자신"의 권한만 본다 — 루트가 잠겨 있으면 다른 계정은 그 안에 파일을 넣거나 다른 폴더를 이름 바꿔
    들여올 수 없으므로 안쪽은 믿는다(관리자가 안쪽 폴더 권한을 직접 넓혀 둔 경우는 못 잡는다). 또 다른 계정에 권한 변경
    (`WRITE_DAC`)까지 준 관리자 소유 폴더가 이 PC에 따로 있으면, 그 계정이 권한을 관리자 전용 모양으로 바꿔 둔 뒤 들여온
    폴더는 권한만으로는 구별되지 않는다 — 그런 폴더는 그 자체로 위험한 설정이고, `C:\`에서 물려받는 "수정"에는 권한 변경이
    없다. (2) 확인 창에서 "예"를 누른
    잠금 전 폴더와 제거 키가 맞는 업그레이드는, 잠그기 전에 다른 계정이 그 안에 파일을 넣어 두었을 수 있다(아래 "남은 틈
    (3)"). (3) `C:\Users` 자체처럼 SYSTEM 소유이고 다른 계정이 쓸 수 없는 공용 폴더를 설치 경로로 고르면 통과한다(아무도
    미리 넣어 둘 수 없으니 이 검사의 목적에는 맞고, Setup이 `Unsafe`로 보고 잠그지 않은 채 경고한다 — 전용 폴더에 설치할
    것). `C:\ProgramData`·드라이브 최상위처럼 다른 계정이 쓸 수 있는 곳은 이제 확인 창이 뜬다. 드문 예외: UAC를 끈 PC나 기본 제공
    Administrator 계정(관리자 승인 모드 꺼짐)으로 Windows 10/11에 예전 버전을 설치했다면 폴더 소유자가 Administrators가
    아니라 그 계정일 수 있어, **일반 제거 뒤 같은 경로 재설치가 막힌다**. 그 폴더가 이 서버의 것임을 확인했다면 관리자
    권한으로 `icacls "<설치 경로>" /setowner *S-1-5-32-544`(폴더 자신만 — `/T` 없이)를 한 뒤 다시 설치한다(잠금 전 권한
    그대로라 이번에는 확인 창이 뜬다 — "예"). 다른 경로로
    새로 설치하면 안 된다 — 일반 제거는 PostgreSQL 서비스(`postgresql-tangotalk`, 포트 55432)를 그대로 두므로 새 설치가
    포트 충돌로 실패한다. 이 예외를 없애려고 "소유자가 지금 설치하는 계정이면 받기"를 넣지 말 것 — 같은 계정의 **승격
    안 된** 프로세스(그 계정으로 도는 악성 코드 포함)도 그런 폴더를 만들 수 있어, 막으려던 구멍이 다시 열린다.
    같은 이유로 확인 창을 "자동 예"로 바꾸지 말 것(무인 설치에서도 거부가 맞다).
  - **핵심 데이터 폴더가 링크면 잠그지 않고 멈춘다.** `Protect-InstallDir`은 시작할 때 `secrets`/`backups`/
    `pgsql-data`/`server\uploads`/`server\certs`가 링크면 예외를 던진다 — 정상 설치는 이 폴더들을 링크로 만들지
    않으므로(공간이 필요하면 설치 경로나 `UPLOADS_DIR`로 옮긴다) 손댄 흔적으로 보고, 비밀값·DB·백업·첨부파일이
    링크가 가리키는 다른 폴더로 새는 것을 막는다. (Setup에선 `Fail`, Update에선 경고 후 계속 — Update는 어차피
    매번 다시 맞춘다.)
  - 언제: `Setup-TangoTalkServer.ps1` 2.5단계(PostgreSQL 설치 **직후** — EDB 설치 프로그램은 initdb 등을
    제한된 토큰으로 돌리는데 그 과정이 원래 권한에 기대는지 검증하지 못해서, 설치 도중 환경은 그대로 둔다;
    `secrets\`만은 DB 비밀번호를 쓰기 전에 먼저 잠근다), `Update-Server.ps1` 1단계(매 업데이트마다 다시
    맞춤). 설치 경로가 드라이브 최상위·Program Files/Windows/사용자 폴더 자체·정션이거나 네트워크/FAT
    드라이브면(`Get-FolderLockKind`) 잠그지 않고 경고만 한다 — 그 안의 다른 프로그램·파일까지 막히므로.
  - 그 결과: `.env`를 손으로 고치려면 메모장을 관리자 권한으로 열어야 하고, 탐색기로 파일을 넣을 땐(예:
    `firebase-service-account.json`) "관리자 권한 필요 → 계속"을 거친다. "서버 콘솔로 실행"은
    `Start-ServerConsole.ps1`이 스스로 승격한다. `Get-PairingCode.ps1`도 이제 스스로 승격한다 — 예전엔 일반
    권한이라 `.env`를 못 읽고 기본 포트(3000/3001)로 조용히 넘어가, 포트를 바꾼 서버에서는 코드 발급이 실패했다
    (보안 경계 때문은 아니다 — `/admin/generate`는 이 PC에서 온 요청이면 받는다). "서버 재시작"은 서비스가 다시
    안 뜨면 `service-err.log`를 그 창(관리자 권한)에서 바로 메모장으로 열어 준다.
  - 남은 틈: (1) **새 설치**에서는 Inno가 파일을 복사한 뒤 2.5단계까지(주로 PostgreSQL 설치 시간) 폴더가 아직
    C:\ 권한 그대로다 — 그 몇 분 사이 다른 계정이 로그인해 있다면 "우리가 복사한" 파일을 손댈 수 있다(위
    PrepareToInstall 검증은 "미리 심어둔 폴더"를 막을 뿐, 복사 뒤~잠금 전 구간은 못 막는다). 막으려면
    `[Code]`에서 파일 복사 전에 먼저 잠가야 하는데, 그 상태에서 EDB 설치가 되는지 VM에서 확인한 뒤에 넣을 것.
    (2) 업데이트 zip(`package_server_update.ps1`)에는 `installer/`가 빠져 있어서 이미 설치된 서버의
    `{app}\*.ps1`(이 잠금 코드 포함)은 zip 업데이트로 바뀌지 않는다 — **기존 서버는 새 설치 프로그램을 한 번
    다시 실행해야** 잠긴다(그 뒤로는 "서버 업데이트"가 매번 다시 맞춘다). 맨 위 "기존 서버에는 새 설치 프로그램을
    한 번 다시 실행해야 한다" 참고 — 운영자가 꼭 알아야 하므로 `README-설치후.txt` 맨 위에 넣었고, 릴리스 노트/루트
    `README.md`에도 **"기존 서버는 새 `tangotalk-server-setup.exe`를 한 번 다시 실행"**이 있어야 한다.
    선택적으로 `package_server_update.ps1`이 zip에 `installer/*.ps1`을 담고 "다음" `Update-Server.ps1`이 그걸
    `{app}`에 복사하게 하면 이후 수정은 전파되지만, **지금 깔려 있는 옛 `Update-Server.ps1`은 루트 스크립트를
    복사하지 않으므로 첫 전파는 반드시 설치 프로그램 재실행**이어야 한다. (3) 이미 누가 손대 둔 PC(심어 둔 파일 등)는 권한을 잠가도 원래대로 돌아가지 않는다 —
    권한만 바꿀 뿐 내용(심어 둔 파일)은 그대로이므로, 의심되면 새로 설치할 것.
- **일반 제거는 데이터를 절대 지우지 않는다.** `messenger-server.iss`의 `[UninstallDelete]`는
  프로그램 파일만 나열한다 — `.env`/`certs`/`uploads`/`secrets`/`pgsql-data`를 여기 추가하지
  말 것. 완전 삭제가 필요하면 `Uninstall-Full.ps1`을 쓴다.
- **`Uninstall-Full.ps1`은 PostgreSQL을 서비스만 정지시키지 않고 `uninstall-postgresql.exe
  --mode unattended`로 정식 제거한다.** 서비스만 세워두고 프로그램 파일(`{app}\pgsql`)을
  남겨두면, 나중에 같은 PC에 PostgreSQL을 다시 설치할 때(예: 완전히 다른 이름/경로로 새
  설치를 시도해도) EDB 설치 프로그램이 "이 PC에 이미 설치돼 있다"고 자체적으로 인식해서
  `--prefix`/`--servicename`로 새로 지정한 값을 무시하고 예전 설치를 그대로 재사용해버리는
  문제가 실제로 있었다(2026-09-10 발견). 그래서 데이터 삭제 전에 반드시 PostgreSQL 자체부터
  정식으로 제거한다.
- **PostgreSQL 설치 시 `pgAdmin` 컴포넌트도 `stackbuilder`와 함께 끈다**
  (`--disable-components pgAdmin,stackbuilder`). 헤드리스 서버 운영에 pgAdmin4(GUI 관리
  도구)가 필요 없기도 하고, pgAdmin4가 번들하는 대용량 Python 런타임이 설치 후 "컴퓨터를
  재시작하세요" 프롬프트의 원인 중 하나로 보여서(EDB installer가 Visual C++ 런타임 등
  설치 중인 파일이 잠겨 있으면 재시작을 요청하는 걸로 알려져 있음 — EnterpriseDB/edb-installers
  issue #155 참고) 겸사겸사 줄인다. 다만 이 재시작 자체가 TangoTalk 서버 동작에 필수는
  아니다 — `Setup-TangoTalkServer.ps1`은 설치 마지막 단계에서 실제로 서비스를 띄우고
  끝나므로, 재시작 없이 바로 서버를 쓸 수 있다(재부팅은 나중에 편한 때 해도 됨).
- **완전 삭제/초기화는 확인 문구 하나만으로 되지 않는다.** 이 PC 앞에 앉을 수 있다는 것만으로
  실제 데이터를 지울 수 있으면 안 되므로, `Uninstall-Full.ps1`/`Reset-Data.ps1`/`Restore-Data.ps1` 모두 먼저
  `server/scripts/verify-admin.mjs`로 실제 서버 운영자(`is_server_admin=true`) 계정의
  아이디/비밀번호를 확인하고(비밀번호는 stdin으로만 전달 — 커맨드라인 인자·환경 변수·파일로 안 남김),
  통과해야만 그 다음 `DELETE`/`RESET`/`RESTORE` 입력 확인으로 넘어간다. 세 스크립트에 똑같이 든
  `Test-ServerAdminPassword`가 이 일을 한다. **Windows PowerShell 5.1은 파이프로 외부 프로그램에 넘기는 글자를
  `$OutputEncoding`(기본값 ASCII)으로 바꿔 한글 등을 '?'로 보내므로, 예전에는 그런 글자가 든 운영자 비밀번호로는 맞게 쳐도
  늘 인증에 실패했다.** 그래서 그 파이프 동안만 BOM 없는 UTF-8로 바꾼다 — `[System.Text.UTF8Encoding]::new($false)`로
  만들 것(`New-Object`로 만들면 PSObject로 감싸여, 함수 안 지역 변수에서는 인코딩으로 인식되지 않고 조용히 ASCII로 돌아간다 —
  직접 확인). `verify-admin.mjs`는 stdin을 UTF-8로 읽어 맨 앞 BOM 하나와 끝 줄바꿈 하나만 떼고(앞뒤 공백은 비밀번호 그대로),
  올바르지 않은 UTF-8은 짐작해 맞추지 않고 실패로 본다. node가 아예 실행되지 못하면 예전 `$LASTEXITCODE`가 남아 통과처럼
  보이지 않게 먼저 지워 두고, node가 stdout에 쓴 것이 결과에 섞이지 않게 화면으로만 보낸다. 고치면 셋 다 고치고
  `tests/Admin-Verify.Tests.ps1`·`server/test/verifyAdminStdin.test.js`를 돌릴 것. 이 스크립트는 설치 프로그램의
  `server/node_modules`(pg, bcryptjs)를 그대로 재사용한다 — 별도 의존성을 추가하지 않는다.
- **`Reset-Data.ps1`과 `Uninstall-Full.ps1`은 목적이 다르다.** 전자는 서버는 계속 쓰면서
  데이터만 비우고 싶을 때(`.env`/인증서/설치는 안 건드림, 끝나면 서버 재시작되어 바로 씀),
  후자("서버 완전 삭제")는 서버 자체를 걷어낼 때(PostgreSQL 자체까지 정식 제거 + DB/업로드/
  인증서/`.env`/비밀값까지 다 지운 뒤, 마지막 단계로 `unins000.exe /VERYSILENT`를 자동
  실행해서 Node 앱 프로그램 파일까지 지움 — 더 이상 따로 "TangoTalk 서버 제거"를 실행할
  필요가 없다) 쓴다. `Reset-Data.ps1`은
  `public` 스키마의 테이블을 동적으로 찾아서 `TRUNCATE ... RESTART IDENTITY CASCADE`
  하므로(`server/scripts/reset-data.mjs`) 나중에 테이블이 추가돼도 하드코딩된 목록을 고칠
  필요가 없다 — drizzle의 마이그레이션 기록은 별도 `drizzle` 스키마에 있어서 자동으로 안
  건드려진다(초기화 후 마이그레이션을 다시 실행할 필요 없음).
- **`Uninstall-Full.ps1`이 `unins000.exe`를 부를 때 `-Wait`를 안 쓴다.** 이 스크립트 자신도
  `[Files]`로 설치된 파일이라 일반 제거 대상에 포함된다 — `-Wait`로 기다리면 자기 자신이
  지워지는 걸 기다리는 셈이라 애매해지므로, 제거 프로그램을 독립 프로세스로 띄워두고
  스크립트는 바로 끝낸다(제거 자체는 백그라운드에서 계속 진행됨).
- **Windows "설정 → 앱 → 설치된 앱"에서 TangoTalk 서버를 지우는 것은 시작 메뉴의 "TangoTalk
  서버 제거"와 완전히 같다(둘 다 같은 `unins000.exe`를 실행).** `[UninstallDelete]`가
  나열한 Node 앱 프로그램 파일만 지우고 PostgreSQL·DB 데이터·업로드·인증서·`.env`·비밀값은
  전혀 안 건드린다 — `Uninstall-Full.ps1`("서버 완전 삭제")은 이 동작을 **마지막 단계로
  그대로 포함**하면서 앞에 PostgreSQL·데이터 삭제를 더한 것뿐이다. 사용자가 "Windows에서
  지웠으니 다 지워졌겠지"라고 착각하기 쉬운 지점이라 README에도 명시해뒀다(위 "운영 서버
  업데이트"/설치 섹션 참고) — 새 문서를 쓸 때도 이 구분을 흐리지 않게 주의할 것.
- **설치 폴더 루트의 관리 스크립트는 전부 맨 처음에 스스로 관리자 권한으로 승격한다** — `Update-Server.ps1`/
  `Restart-Server.ps1`/`Storage-Path.ps1`/`External-Address.ps1`/`Web-Domain.ps1`/`Backup-Data.ps1`/`Restore-Data.ps1`/`Reset-Data.ps1`/
  `Uninstall-Full.ps1`/`Start-ServerConsole.ps1`/`Get-PairingCode.ps1`/`Grant-ServerAdmin.ps1`(빠지는 것은 dot-source용
  `Folder-Acl.ps1`과 설치 프로그램이 관리자 권한으로 부르는 `Setup-TangoTalkServer.ps1`뿐). NSSM 서비스 정지/재시작,
  PostgreSQL 제거, 일반 제거 프로그램 실행, 잠긴 설치 폴더 안의 파일(`node.exe`·서버 코드·`.env`·비밀값) 읽기/쓰기 전부
  관리자 권한이 필요한데, 시작 메뉴 바로가기를 그냥 두 번 클릭하면 관리자 권한 없이 실행되기 때문에 —
  `[Security.Principal.WindowsPrincipal]`로 확인해서 아니면 `Start-Process -Verb RunAs`로 자기 자신을 다시 실행하고
  원래 프로세스는 종료한다(그래서 이 스크립트 파일들 자체는 일반 권한으로도 읽을 수 있어야 한다 — 위 "예외 2").
  **node는 항상 서버 폴더에서 실행한다**(`Set-Location`/`Push-Location $ServerDir` 뒤에) — `reset-data.mjs`·
  `drizzle.config.js`·`src/index.js`는 `dotenv/config`로 `.env`를 "현재 폴더"에서 읽는데, 승격된 PowerShell은
  `C:\Windows\System32`에서 시작한다(`verify-admin.mjs`·`grant-server-admin.mjs`는 자기 위치 기준으로 읽지만 규칙
  하나로 맞춘다). 새 스크립트를 추가하면 `[Files]`에 한 줄 넣고(루트 `*.ps1`은 하나씩 적어야 설치된다) 이 규칙대로
  쓴 뒤 `tests/Install-Guard.Tests.ps1`을 돌릴 것 — 셋 다 거기서 확인한다.
- **서버 운영자 복구(`Grant-ServerAdmin.ps1`)는 시작 메뉴에 넣지 않는다.** 활성 서버 운영자가 한 명도 없을 때만
  쓰는 드문 복구 도구라(운영자가 있으면 `grant-server-admin.mjs`가 아무것도 안 바꾸고 관리자 콘솔로 안내), 시작 메뉴를
  어지럽히지 않고 `README-설치후.txt`에서 실행 방법(설치 폴더에서 오른쪽 클릭 → "PowerShell에서 실행")을 안내한다.
  보안 경계는 아니다 — `.env`를 읽을 수 있는 이 PC의 관리자는 어차피 DB를 직접 고칠 수 있다.
- **`Backup-Data.ps1`/`Restore-Data.ps1`은 `.env`를 안 읽는다.** DB 접속 정보(포트 `55432`,
  DB명 `messenger`, 앱 계정 `messenger_app`)는 상수로 박아두고, 비밀번호만
  `{app}\secrets\db-app.pw`에서 그대로 읽는다 — `Setup-TangoTalkServer.ps1`이 이미 저장해둔
  값을 재사용하는 것뿐이라 `.env`의 `DATABASE_URL`을 파싱하는 것보다 안전하고 간단하다.
  백업 파일은 `{app}\backups\`에 쌓인다 — `releases`/`secrets`/`pgsql-data`와 같은 성격의
  실데이터 폴더라 `[UninstallDelete]`에 없다(일반 제거로 안 지워짐).
- **백업은 관리자 전용 폴더에, 최근 10개만 보관한다. 폴더를 안전하게 잠글 수 없으면 백업하지 않는다.**
  백업 파일에는 회원 비밀번호 해시·암호화된 이메일·초대 토큰까지 DB 전체가 들어 있다. `Backup-Data.ps1`은
  쓰기 전에 `backups\`를 `Set-AdminOnlyAcl`로 직접 잠그고, **(a) `Folder-Acl.ps1`이 없거나(잠금 기능 전 설치)
  (b) `backups\`가 링크(정션/심볼릭 링크)이거나 (c) Local이 아니라 못 잠그면(네트워크/FAT 등) 백업을
  진행하지 않고 중단**한다 — 그러지 않으면 DB 전체 덤프가 다른 계정이 읽을 수 있는 곳이나 공격자가 심어둔
  정션 대상 폴더에 그대로 써진다(S40). 핵심 잠금은 됐는데 "정리" 단계에서만 경고가 난 경우(폴더는 이미
  잠김)에는 경고만 남기고 진행한다. 끝나면
  방금 만든 것을 포함해 최근 `$KeepBackups`(10)개만 남기고 오래된 것을 지운다 — 끝없이 쌓아두면 새어 나갈
  거리만 늘어나서. 정렬은 파일 이름의 날짜·시각 기준(복사하면 바뀌는 수정 시각보다 정확)이고, 이 스크립트가
  만든 이름 형식(`messenger_<yyyyMMdd>_<HHmmss>.dump`)의 파일만 지운다 — 사용자가 직접 넣어둔 다른 파일과
  방금 만든 파일은 안 건드린다. 더 오래 보관할 백업은 다른 안전한 곳에 복사해 두는 것이 전제다.
- **서버 전체 백업은 서버(Node)가 하고, 시작 메뉴 "백업"은 그것을 부를 뿐이다.** (`server/src/backup.js`·`backupCrypto.js`·
  `backupService.js`·`backupRestore.js`, 관리자 콘솔 "백업" 탭) 예전 "백업"은 DB만 떠서, PC가 고장 나면 DB 암호화 키
  (`server\.db-encryption-key` — 없으면 암호화된 이메일 등을 못 읽음)·서버 인증서(앱이 핀닝 — 바뀌면 모든 기기 재페어링)·
  첨부파일이 없어 완전히 되살릴 수 없었고, 사람이 눌러야만 돌았고, 같은 디스크에만 쌓였다. 이제:
  - **무엇을**: 백업 하나 = `tangotalk_<날짜>_<시각>\` 폴더(`manifest.json` + `db.dump.enc`(pg_dump -F c를 스트림째 암호화 — 평문
    덤프는 디스크에 안 씀) + `secrets.enc`(`.env`·`.jwt-secret`·`.db-encryption-key`·웹 푸시 키·`firebase-service-account.json`·
    `certs\*`·첨부파일 미러 키)). 다 쓰기 전엔 `.partial`로 두고 마지막에 이름을 바꾼다. 최근 N개(기본 14, 3~60) 보관.
  - **왜 서버 안에서**: 업데이트 zip은 `server\`만 바꾸고 `{app}`의 `.ps1`은 안 바꿔서(위 "남은 틈 (2)"), PowerShell로
    만들면 이미 설치된 서버에 들어가지 않는다. 예약(매일 정한 시각, 놓쳤으면 켠 뒤 10분)·관리자 콘솔 상태도 서버가 해야 자연스럽다.
    시작 메뉴 "백업"은 `scripts\backup-now.mjs`로 같은 함수를 부르고, 둘은 `backups\.backup.lock`(pid·시각 — 죽은 잠금은
    치움)으로 겹치지 않는다. 결과는 `backups\backup-status.json`에 남아 콘솔이 둘 다 보여 준다.
  - **백업 암호로 암호화(AES-256-GCM, 1MiB 조각 + 끝 표시 — `backupCrypto.js`)**: 백업에 DB 키·JWT 비밀값·인증서 개인키가
    들어가서, NAS·외장 드라이브에 두어도 암호 없이는 못 열게. 키는 scrypt(백업마다 새 salt). 파일마다 용도(`db`·`secrets`·
    `upload:<이름>`)를 인증 데이터로 묶어 바꿔치기·잘림·덧붙임이 모두 실패한다. 암호는 예약 백업에 써야 해서 DB에 DB 암호화
    키로 잠가 두고(`server_settings.backup_password`), 콘솔에 다시 내려보내지 않는다. 잃으면 복원 불가 — 콘솔·도움말에 크게 적었다.
  - **외부 위치(NAS·외장 드라이브)**: 고른 폴더 아래 `TangoTalk-Backup\`(표시 파일 `tangotalk-backup-root.json`)에만 쓰고 지운다
    — 남의 파일이 든 폴더는 쓰지 않는다. 고른 폴더가 없으면(드라이브 빠짐) 만들지 않고 실패. 백업 폴더를 복사하고, 첨부파일은
    `uploads\`에 파일마다 미러 키로 암호화해 늘 지금 상태로 맞춘다(크기·수정 시각 색인으로 바뀐 것만 — 한꺼번에 많이(50개 이상이면서
    20% 넘게) 사라졌으면 지우지 않고 경고: 사고로 빈 저장소를 백업까지 따라가지 않게). 외부 위치에서만 실패하면 결과는 "일부 실패".
    외부 위치는 꺼진 NAS일 수 있어 **비동기 fs만** 쓴다(동기 호출은 기다리는 동안 채팅 서버 전체를 멈춘다).
  - **NAS 경로(`\\…`)는 서버 PC에서 연 콘솔에서만 받는다**: 서버(SYSTEM)가 그 주소로 접속하며 컴퓨터 계정 NTLM을 넘기므로, 밖에서
    운영자 계정만 훔친 사람이 자기 주소를 넣어 받아 가지 못하게(`isRequestFromThisPc` — 127.0.0.1·이 PC의 인터페이스 주소). 백업
    암호·외부 위치를 바꿀 때는 운영자 비밀번호를 다시 확인한다(`users.js checkCurrentPassword`). 서버 폴더·첨부파일 폴더·이 PC
    백업 폴더·Windows 폴더 안은 외부 위치로 안 받는다. NAS는 컴퓨터 계정(`DOMAIN\PC$`)에 쓰기 권한이 있어야 해서 워크그룹 NAS는
    안 될 수 있다 — 저장 전에 실제로 써 보고 안 되면 이유를 보여 주고, 외장 드라이브를 권한다.
  - **복원(`scripts\restore-backup.mjs`, 서비스 정지 상태)**: DB는 `DROP OWNED BY current_user`(앱 계정 — PG15+의 public은
    pg_database_owner 것이라 남음) + `pg_restore -f -`의 SQL을 **psql 한 트랜잭션**(`-1`, `ON_ERROR_STOP`)으로 넣는다 — 실패하면
    그대로, 옛 백업이어도 그 뒤 마이그레이션이 만든 표가 남지 않아 이어서 `drizzle-kit migrate`가 깨끗이 올린다(예전 `--clean`은
    둘 다 안 됐다). 복원 전 지금 DB는 `before-restore_<시각>.dump`(최근 3개)·설정 파일은 `before-restore_<시각>-config\`로 남긴다.
    비밀값은 정해 둔 이름만 정해 둔 자리에 쓰고, `.env`는 이 PC 값(`DATABASE_URL`·`UPLOADS_DIR`·LiveKit 등)을 두고 나머지를
    합친다(포트가 바뀌면 방화벽·포워딩 안내). 백업이 더 새 서버의 것(적용된 마이그레이션 수가 코드보다 많음)이면 막는다. 회원이
    없는 새 설치면 운영자 확인 대신 백업 암호로만 확인한다(확인할 운영자가 없다). 백업 암호는 stdin(UTF-8 바이트 직접 —
    `Invoke-RestoreScript`)으로만 넘기고, node에 PowerShell 파이프로 넘기는 곳은 여전히 `Test-ServerAdminPassword` 하나다.
- **`Storage-Path.ps1`은 새 메커니즘을 만들지 않는다.** `server/src/config.js`의
  `UPLOADS_DIR`은 원래부터 환경변수로 바꿀 수 있었다(`process.env.UPLOADS_DIR || 기본값
  server/uploads`) — 이 스크립트는 그 값을 `.env`에 써주고 서비스를 재시작해주는 GUI일
  뿐이다. 경로를 바꿀 때 기존 파일이 있으면 새 위치로 옮길지 물어보고(`robocopy /MOVE`),
  NAS 등 네트워크 경로(`\\서버\공유\폴더`)도 텍스트로 직접 입력하면 그대로 쓸 수 있다.
  설치 폴더 밖의 **로컬** 폴더를 고르면 파일을 옮기기 **전에** 그 폴더를 `Set-AdminOnlyAcl`로 잠근다(옮겨진
  파일도 그 권한을 물려받게 — robocopy는 권한을 복사하지 않음). 이미 다른 파일이 들어 있는 폴더면 먼저
  묻고, 드라이브 최상위·Windows/Program Files/사용자 폴더(또는 그 상위)·설치 폴더 자체·정션은 저장소로 받지
  않는다(잠그면 다른 사람 파일까지 막힘). **네트워크 경로는 잠그지 않는다** — 이 PC의 SID로 잠그면 NAS 쪽
  계정과 맞지 않아 서버(LocalSystem = 이 PC의 컴퓨터 계정으로 접속)까지 못 쓰게 될 수 있어서, NAS 쪽에서
  직접 제한하라고 안내만 한다. FAT32/exFAT 드라이브는 권한을 저장하지 못하므로 경고 후 사용자가 고르게 한다.
  같은 경로로 다시 "적용"하면 권한만 다시 맞출 수 있다(이 잠금이 생기기 전에 옮겨 둔 저장소용).
- **웹 앱 주소(정식 인증서 — `Web-Domain.ps1`)는 메인 포트를 건드리지 않고, 인증서 발급은 서버가 한다.** 아이폰은 앱 대신 사파리 웹
  앱(`server/web`)을 쓰는데, 사파리(경고 없는 접속·"홈 화면에 추가"·웹 푸시)는 공인 인증서가 있어야 한다. PC·안드로이드 앱은 메인
  포트(`PORT`)의 자체 서명 인증서를 핀닝하므로(`server/src/certs.js`, `client/lib/services/pinned_tls.dart`) 그 인증서를 바꾸면 모든
  기기를 재페어링해야 한다 — 그래서 서버가 같은 Express 앱을 별도의 웹 HTTPS 포트(`WEB_HTTPS_PORT`)로 한 번 더 열고 그 포트에만
  Let's Encrypt 인증서를 받아 건다(`server/src/webTlsConfig.js`·`acme.js`·`acmeRenewal.js`). 이 스크립트는 `External-Address.ps1`처럼
  `.env`를 쓰고 방화벽을 맞추고 서비스를 재시작하는 GUI일 뿐이다.
  - Let's Encrypt의 확인은 **밖의 443(TLS-ALPN-01)과 밖의 80(HTTP-01)**으로만 온다. 통신사가 80을 막는 경우가 있어 서버는 둘 다 쓰고,
    `ACME_HTTP_PORT=0`이면 443만 쓴다. 그래서 공유기 포워딩은 외부 443 → 웹 포트, 외부 80 → 인증용 포트다. 웹 포트가 443이 아니면(이
    PC의 443·80을 IIS/HTTP.sys가 쓰는 경우) 서버가 알려 주는 주소(`webAddress.js` — `https://도메인:포트`)에 그 번호가 붙으므로
    외부의 같은 번호도 그 포트로 연다.
  - **iptime.org는 공개 접미사 목록(PSL)에 없다** — Let's Encrypt의 "등록 도메인당 7일에 새 인증서 50개" 한도를 모든 iptime DDNS
    사용자가 함께 써서 첫 발급이 `rateLimited`로 실패할 수 있다(같은 이름의 갱신은 예외). 서버는 실패하면 간격을 두고(1시간부터 최대
    하루, 한도면 `Retry-After`까지) 다시 시도하고 그 일정을 `certs\acme-state.json`에 남겨 **재시작해도 그 전에는 다시 묻지 않는다**
    (도메인이나 시험 발급 설정이 바뀔 때만 새로 시작). 그래서 도구·안내문은 "기다리거나, 회사 도메인의 하위 이름을 CNAME으로 DDNS
    이름에 연결해 그 이름을 쓰라"고 하고, 같은 값으로 다시 적용할 때도 재시작이 곧 재시도는 아니라고 알린다. 시험 발급
    (`ACME_STAGING=1` — 스테이징 디렉터리)은 정식 한도를 쓰지 않고 포트포워딩만 확인하는 용도다.
  - 입력은 서버(`webTlsConfig.js`)보다 좁게 받는다 — 도메인은 점이 있는 공개 이름만(IP·`.local` 같은 사내 전용 이름·포트·와일드카드는
    거절, 주소창에서 복사한 `https://`·경로는 떼고, 한글은 퓨니코드로 바꿔 씀), 포트는 서버가 이미 쓰는 번호(PORT·PAIRING_PORT·
    LiveKit 신호/미디어 TCP·PostgreSQL 55432)와 겹치면 거절 — 서버는 그런 값이면 기능을 끄거나 그 값만 빼고 진행해서 운영자가 놓치기
    쉽다. 이 PC의 다른 프로그램이 그 포트를 쓰는지(PID 4면 HTTP.sys), 도메인이 DNS에서 공인 IP로 풀리는지는 막지 않고 경고만 한다(사내
    DNS가 따로 있는 회사 등 오판할 수 있어서).
  - **방화벽 규칙은 이름(`TangoTalk Server (web)`·`(web-acme)`)으로 지우고 다시 만들고, 이 서버의 `{app}\node\node.exe`로만 좁힌다** —
    메인·페어링 규칙은 포트만 보지만 443·80은 IIS 같은 다른 프로그램도 흔히 쓰는 포트라, 나중에 이 PC에 웹 서버가 깔려도 이 규칙
    때문에 밖에 열리지 않게. 이 함수(`Set-WebFirewallRules`)는 `Setup-TangoTalkServer.ps1`에도 똑같이 들어 있다(테스트가 같은지 본다).
    일반 제거(`[UninstallRun]`)가 두 규칙을 지우고("서버 완전 삭제"도 마지막에 일반 제거를 돌린다), `.env`는 남으므로 같은 경로에 다시
    설치하면 Setup 6단계가 `WEB_DOMAIN`을 보고 되살린다(꺼져 있으면 남은 규칙을 지우고, 실패해도 설치는 경고만). "끄기"는 `WEB_DOMAIN`만
    비운다 — 포트·이메일은 남겨 다시 켤 때 쓰고(서버는 `WEB_DOMAIN`이 비면 나머지를 보지 않는다), 받아 둔 인증서는 서버 몫이라 건드리지
    않는다.
  - `.env`는 BOM 없는 UTF-8로 쓴다(`External-Address.ps1`과 같게 — 지금 서버의 dotenv 17은 첫 줄 앞의 BOM을 건너뛰지만, BOM을 키 이름의
    글자로 읽는 도구도 있어서). 읽을 때는 `Get-Content`를 쓰지 않는다 — Windows PowerShell 5.1은
    BOM이 없으면 ANSI로 읽어서, BOM 없는 UTF-8의 한글 주석을 깨진 채로 다시 쓰게 된다. BOM이 있으면 그 인코딩, 없으면 엄격한 UTF-8,
    그것도 아니면(예전 메모장의 ANSI) 시스템 코드 페이지로 읽으므로 ANSI였던 파일은 한글이 살아 있는 UTF-8이 되고 dotenv도 한글 값을
    바로 읽는다.
  - [인증서 확인]은 공유기·DNS를 거치지 않고 127.0.0.1의 웹 포트에 SNI(도메인)로 붙어, 지금 걸린 인증서를 Windows가 믿는지(정식),
    발급자에 "(STAGING)"이 있는지(시험용), 그 밖(자체 서명 등)인지 보여 준다. 밖에서 열리는지는 공유기에 달려 있어 여기서 알 수 없고,
    실패 이유·다음 시도 시각은 서버가 관리자 콘솔에 보여 준다.
- **문자열 안의 `$이름` 바로 뒤에 한글을 붙이지 말 것.** PowerShell은 한글도 변수 이름 글자로 읽어서 `"$name와"`를 `$name와`라는
  (없는) 변수로 보고 빈 값을 넣는다 — `$($name)와`나 `${name}와`로 쓴다. `tests/Web-Domain.Tests.ps1`이 `Web-Domain.ps1`·
  `Setup-TangoTalkServer.ps1`은 실패로, 다른 설치 스크립트는 "메모:"로 알린다(지금 `External-Address.ps1` 138·139줄의 포워딩 안내에서
  `$MediaUdp와`·`$PairingPort도`가 이 때문에 빈 값으로 보인다).
- **마이그레이션은 번들된 `drizzle-kit`으로 실행한다** (`server/node_modules/drizzle-kit/bin.cjs
  migrate`) — 그래서 빌드 스크립트는 `npm install --omit=dev`가 아니라 devDependencies까지
  포함해서 설치해야 한다(`drizzle-kit`이 `package.json`에서 devDependency이기 때문). 이 부분을
  프로덕션 전용 설치로 "최적화"하면 마이그레이션이 깨진다.
- **설치된 서버는 `NODE_ENV=production`으로 돈다 — 서버 서비스와 "서버 콘솔로 실행" 창에만 넣는다(S38).** Express는
  `NODE_ENV`가 `production`이 아니면, 전용 오류 처리기를 거치지 않고 Express 기본 처리기까지 간 오류의 응답에 스택
  트레이스(서버의 절대 경로)를 그대로 싣는다 — 서버를 인터넷에 열면 누구나 볼 수 있다. `server/src`에는 `NODE_ENV`를 따로
  보는 곳이 없고 의존성 중에서도 Express(`finalhandler`: 오류 응답에 스택 대신 상태 문구, `view cache` 켜짐 — 뷰는 안 씀)만
  달라진다(bluebird는 `development`일 때만, dayjs는 안 쓰는 플러그인만 본다). 오류 자체는 그대로 `service-err.log`에 남는다
  (Express 기본 처리기는 `test`가 아니면 늘 stderr에 찍는다). 서비스는 `Set-NodeServiceProductionEnv`가 NSSM이 서비스를
  시작할 때 읽는 `HKLM\SYSTEM\CurrentControlSet\Services\TangoTalkServer\Parameters\AppEnvironmentExtra`(REG_MULTI_SZ)에
  넣는다 — `Setup-TangoTalkServer.ps1` 7단계(새 서비스는 시작 전, 기존 서비스는 재시작 전)와 `Update-Server.ps1` 5단계(매
  업데이트, 재시작 전). 관리자가 넣어 둔 다른 변수는 그대로 두고 NODE_ENV 줄만 바꾼다. `nssm set`을 안 쓰는 이유: 여러 줄을
  한 번에 넣는 방법이 NSSM 버전마다 달라 번들한 2.24에서 확인하지 못했고(인자를 공백으로 이어 한 줄로 만들면 NODE_ENV가
  조용히 안 들어간다), 지금 목록을 읽으려 해도 `nssm get`은 파이프로 받으면 UTF-16으로 나와 깨진다. 콘솔 모드는
  `Start-ServerConsole.ps1`이 node를 띄우기 직전에 그 창의 `$env:NODE_ENV`를 넣는다. **`Setup`/`Update` 자신의 환경 변수로는
  절대 넣지 말 것** — 같은 창의 `npm install`이 devDependencies를 빼고 설치해(npm 7+) 바로 위 항목의 `drizzle-kit`이 깨진다
  (`tests/Service-Env.Tests.ps1`이 막는다). pm2로 운영하는 서버(`server/ecosystem.config.cjs`)는 원래부터
  `NODE_ENV: 'production'`이고, 개발용 `npm start`는 그대로 둔다. 기존 서버는 새 설치 프로그램을 한 번 다시 실행해야 들어간다
  (맨 위 참고 — 옛 `Update-Server.ps1`은 이 값을 넣지 않는다).
- **`firebase-service-account.json`은 설치 프로그램이 다루지 않는다.** FCM은 선택 기능이라
  설치 후 수동으로 넣게 했다(`README-설치후.txt` 참고) — 자동화하려면 Inno `[Code]`에 파일
  선택 다이얼로그를 추가해야 하는데, 이 설치 프로그램은 커스텀 Pascal 코드를 최소화하는 방향으로
  설계했다.

## 검증 체크리스트

- [ ] 개발 PC에서 `powershell -NoProfile -ExecutionPolicy Bypass -File server\installer\tests\Folder-Acl.Tests.ps1`
      → "실패 0"(관리자 권한 불필요, `%TEMP%` 안에서만 돎)
- [ ] 개발 PC에서 `powershell -NoProfile -ExecutionPolicy Bypass -File server\installer\tests\Install-Guard.Tests.ps1`
      → "실패 0"("메모:" 줄이 있으면 그 PC에서 확인하지 못한 경우가 있다는 뜻 — 관리자 권한 불필요, `%TEMP%` 안에서만 돎)
- [ ] 개발 PC에서 같은 방법으로 `tests\Admin-Verify.Tests.ps1`(node 필요)·`tests\Service-Env.Tests.ps1` → 둘 다 "실패 0"
      (관리자 권한 불필요, 앞의 것은 `%TEMP%` 안에서만 돌고 뒤의 것은 아무것도 바꾸지 않음)
- [ ] 개발 PC에서 같은 방법으로 `tests\Web-Domain.Tests.ps1`(node 필요) → "실패 0"(관리자 권한 불필요, `%TEMP%`와 127.0.0.1의 임시
      포트만 씀 — "메모:" 줄은 다른 설치 스크립트에서 찾은 것)
- [ ] 서비스 모드로 설치한 뒤(기존 서버면 새 설치 프로그램을 다시 실행한 뒤), 그리고 "서버 업데이트" 뒤에 관리자 PowerShell에서
      `& "C:\TangoTalk-Server\tools\nssm.exe" get TangoTalkServer AppEnvironmentExtra` → `NODE_ENV=production`(관리자가 따로
      넣어 둔 줄이 있었다면 그것도 그대로)이고 서버가 정상 동작. `install.log`·업데이트 창에 NODE_ENV 경고가 없음
- [ ] 한글이 든 비밀번호의 서버 운영자 계정으로 "DB 데이터 초기화"·"복원"·"서버 완전 삭제"를 열면 운영자 확인이 통과하고
      (그다음 `RESET`/`RESTORE`/`DELETE` 대신 다른 글자를 치면 아무것도 바뀌지 않고 끝남), 한 글자라도 틀리면 실패. 콘솔의
      비밀번호 입력(`Read-Host -AsSecureString`)에서 한글 입력기가 제대로 들어가는지도 이때 본다(개발 PC에서는 확인하지 못함)
- [ ] `build_server_installer.ps1` 실행 → `installer/output/tangotalk-server-setup.exe` 생성 확인
- [ ] 이전 버전 위에 덮어 설치했을 때 시작 메뉴에 옛 "도움말"·"메신저 설명서" 바로가기와 설치 폴더의 `README.html`이
      남아 있지 않음
- [ ] 브라우저로 `https://<서버>:3000/guide/`를 열면 초보자용 도움말 첫 페이지가 뜸
- [ ] 설치 경로에 공백이 있는 폴더(예: `C:\My Server\TangoTalk`)를 직접 골라서 설치 →
      PostgreSQL 설치까지 정상적으로 끝남(`pg_ctl.exe`가 그 경로에 실제로 생김)
- [ ] 깨끗한 PC/VM에서 서비스 모드로 설치 → `Get-Service TangoTalkServer`, `Get-Service
      postgresql-tangotalk` 둘 다 Running
- [ ] `https://localhost:3000/health` 응답 확인
- [ ] "새 기기 페어링 코드 발급"으로 코드 발급 → 클라이언트 앱에서 페어링+회원가입까지 한 사이클
- [ ] 같은 설치 프로그램을 다시 실행(업그레이드 시나리오) → `.env`/DB 비밀번호/데이터 안 바뀜,
      서비스 재시작됨
- [ ] "서버 업데이트"로 zip 적용 → 코드 갱신, 기존 DB 데이터는 그대로, 서비스 재시작됨
- [ ] "첨부파일 저장소"를 처음 열면 기본값(`{app}\server\uploads`)이 보임; 다른 폴더로
      바꾸면 `.env`의 `UPLOADS_DIR`이 갱신되고 서비스가 재시작되어 새 첨부파일이 그 위치에 저장됨
- [ ] "서버 완전 삭제(PostgreSQL·Node 앱·DB 데이터 모두)"는 서버 운영자 아이디/비밀번호가
      틀리면 `DELETE` 입력 단계까지도 못 감; 운영자 인증 통과 후 `DELETE`를 안 치면 아무 것도
      안 지움; 둘 다 통과하면 PostgreSQL이 `Get-Service postgresql-tangotalk`에서 안 보일
      정도로 정식 제거되고, 잠시 후 일반 제거까지 자동 진행되어 `{app}` 폴더 안 프로그램
      파일도 대부분 사라짐
- [ ] "DB 데이터 초기화"도 같은 방식으로 운영자 인증 + `RESET` 입력이 필요; 통과하면 회원/팀/
      메시지 등은 비워지지만 `.env`/인증서는 남고 서버가 재시작되어 바로 다시 가입 가능(시작 메뉴에서 열면 UAC 확인
      뒤 진행되고, 운영자 인증·초기화가 `.env`를 실제로 읽음 — 예전처럼 "인증에 실패"로만 끝나지 않는지)
- [ ] 백업 암호를 정하기 전 "백업"을 누르면 "백업 암호를 아직 정하지 않았습니다" 뒤 예전처럼 `{app}\backups\`에
      `messenger_<날짜시각>.dump` 파일이 생기고, 서버는 멈추지 않고 계속 쓸 수 있음
- [ ] "복원"은 파일 선택 창이 뜨고, 운영자 인증 + `RESTORE` 입력이 필요; 방금 만든 `.dump`로
      복원하면 회원/팀/메시지가 그 시점 내용으로 돌아오고 서버가 재시작되어 바로 로그인 가능
- [ ] 관리자 콘솔 "백업" 탭: 백업 암호를 정하면(내 비밀번호 재확인) "다음 자동 백업"이 보이고, "지금 백업" → 진행 표시 →
      "정상", `{app}\backups\tangotalk_<날짜>_<시각>\`에 `manifest.json`·`db.dump.enc`·`secrets.enc`(열어 봐도 평문 없음)
- [ ] 외장 드라이브(E:\…)를 외부 위치로 저장 → 다음 백업에 `E:\…\TangoTalk-Backup\`에 백업 폴더와 `uploads\*.enc`가 생김; 두 번째
      백업은 바뀐 첨부파일만 보냄. 드라이브를 뺀 채 백업하면 "일부 실패"(이 PC 백업은 남음). 다른 PC에서 연 콘솔로는 `\\NAS\…`를
      저장할 수 없고, 서버 PC에서 연 콘솔로는 저장됨(NAS가 이 PC 컴퓨터 계정에 쓰기를 허용한 경우)
- [ ] 백업 암호를 정한 뒤 시작 메뉴 "백업" → 전체 백업이 생기고 콘솔 상태에도 보임; 서버의 백업이 도는 중에 누르면 "이미 백업하고 있습니다"
- [ ] 서버 서비스를 하루 넘게 멈췄다가 켜면 10분쯤 뒤 자동 백업 한 번
- [ ] "복원"에서 전체 백업의 `manifest.json` 선택 → 운영자 확인 → 백업 암호(틀리면 3번까지) → 첨부파일 복원 여부 → `RESTORE` →
      DB·설정이 돌아오고 마이그레이션 뒤 서버 재시작. `backups\before-restore_<시각>.dump`·`-config\`가 생김
- [ ] **새 PC 되살리기**: 다른 VM에 새로 설치(가입 안 함) → 외장 드라이브의 `TangoTalk-Backup\…\manifest.json`으로 복원 → 운영자
      확인 없이 백업 암호만 묻고, 끝나면 예전 계정으로 로그인·예전 대화·첨부파일이 보이고, 앱을 다시 페어링하지 않아도 같은
      주소로 붙음(인증서가 같음). 이메일(암호화 저장)도 그대로 보임
- [ ] 일반 "TangoTalk 서버 제거"는 위 데이터를 안 건드림
- [ ] 설치 후 관리자 PowerShell에서 `icacls C:\TangoTalk-Server` → SYSTEM·Administrators `(OI)(CI)(F)`, Users
      `(RX)`(이 폴더만), NETWORK SERVICE `(RX)`만 보이고 상속(`(I)`) 항목이 없음. `pgsql`에는 NETWORK SERVICE
      `(OI)(CI)(RX)`, `pgsql-data`에는 `(OI)(CI)(F)`가 있음. `install.log`의 2.5단계에 경고가 없음
- [ ] 잠금 뒤에도 `Get-Service postgresql-tangotalk`, `TangoTalkServer`, `TangoTalkLiveKit` 모두 Running이고
      로그인·메시지 전송·첨부파일·화상회의가 정상(PostgreSQL이 NetworkService로 실행 파일·데이터를 읽는지)
- [ ] 관리자가 아닌 일반 계정으로 로그인해서 `server\.env`, `secrets\db-app.pw`, `server\certs\key.pem`,
      `backups\*.dump`, `pgsql-data\`를 못 열고, `node\node.exe`·`server\src\index.js`·`tools\nssm.exe`를
      고치거나 지우지 못함. 그래도 시작 메뉴 "설치 후 안내"는 열림. "새 기기 페어링 코드 발급"은
      관리자 자격 증명을 묻고, 거절하면 "관리자 권한이 필요합니다" 창이 뜸
- [ ] 관리자 계정(UAC 일반 권한)으로 시작 메뉴 관리 항목(새 기기 페어링 코드 발급/서버 업데이트/재시작/첨부파일 저장소/
      외부 접속 주소/웹 앱 주소(정식 인증서)/백업/복원/DB 데이터 초기화/완전 삭제)을 누르면 UAC 확인 뒤 정상 동작하고, "첨부파일 저장소"·"외부
      접속 주소"로 `.env`를 실제로 고칠 수 있음(예전 `Administrators:(R)` 읽기 전용 잠금이 풀렸는지)
- [ ] (웹 앱 주소) 시작 메뉴 "웹 앱 주소(정식 인증서)" → UAC 확인 뒤 창이 뜨고 "지금: 꺼짐", "외부 접속 주소"에 DDNS 도메인이 있으면
      도메인 칸에 미리 채워져 있음. 적용 → `.env`에 `WEB_DOMAIN`·`WEB_HTTPS_PORT`·`ACME_HTTP_PORT`·`ACME_EMAIL`이 생기고(다른 줄·한글
      주석 그대로, BOM 없음), 관리자 PowerShell에서 `netsh advfirewall firewall show rule name="TangoTalk Server (web)" verbose` → TCP 443,
      프로그램 `{app}\node\node.exe`(`(web-acme)`는 TCP 80). 서비스가 재시작되고 안내 글에 포워딩·iptime.org 주의·아이폰 사용법이 나옴
- [ ] (웹 앱 주소) IIS를 켜 둔 PC에서 443으로 적용 → "다른 프로그램이 쓰고 있습니다: Windows HTTP 서비스" 경고. 8443/8080으로 바꾸면
      경고 없이 적용되고 안내에 "외부 TCP 8443 → 이 PC TCP 8443"이 더해짐. 도메인 오타(DNS에서 못 찾음)도 적용 전에 경고
- [ ] (웹 앱 주소) 공유기 포워딩 뒤 1~2분 → [인증서 확인]이 "정식 인증서가 걸려 있습니다"(발급자 Let's Encrypt), 관리자 콘솔 상태도
      정상. 아이폰 사파리(LTE)에서 `https://도메인`이 경고 없이 열리고 "홈 화면에 추가" 뒤 알림을 켤 수 있음. PC·안드로이드 앱은
      재페어링 없이 그대로 접속. "시험 발급"으로 적용하면 [인증서 확인]이 "시험용(스테이징)", 끄고 다시 적용하면 정식
- [ ] (웹 앱 주소) "끄기" → `WEB_DOMAIN=`(빈 값)이고 두 방화벽 규칙이 사라지고 서비스 재시작. 켜 둔 채 "TangoTalk 서버 제거" → 두 규칙이
      사라짐; 같은 경로에 다시 설치 → 규칙이 되살아나고 `install.log`에 "웹 앱 주소(...) 방화벽 규칙 적용됨". 콘솔 모드 설치에서 적용하면
      "그 창을 닫았다가 '서버 콘솔로 실행'으로 다시 여세요" 안내
- [ ] `.env`의 `PORT`를 기본값이 아닌 값(예: 3100)으로 바꾸고 "서버 재시작" → "새 기기 페어링 코드 발급"이 UAC 확인 뒤
      코드를 띄움(바뀐 페어링 포트 3101로 요청하는지 — 예전엔 3001로 가서 실패했음)
- [ ] 서비스가 못 뜨게 해 둔 상태(예: `.env`의 `DATABASE_URL`을 일부러 틀리게)에서 "서버 재시작" → 상태 경고 뒤
      `service-err.log`를 메모장으로 열지 묻고, Y면 관리자 권한 메모장으로 열림(확인 뒤 `.env` 원상복구)
- [ ] 콘솔 모드로 설치 → "서버 콘솔로 실행"이 UAC 확인 뒤 콘솔 창에서 서버를 띄우고, 창을 닫으면 서버가 꺼짐
- [ ] 잠금 전 버전이 깔린 PC에 새 설치 프로그램을 덮어 설치 → 위 `icacls` 결과가 똑같이 바뀌고 서비스·데이터 정상
- [ ] "백업"을 11번 넘게 누르면 `backups\`에 최근 10개만 남고, 지운 파일 이름이 창에 출력됨
- [ ] "첨부파일 저장소"를 설치 폴더 밖 로컬 폴더(예: `D:\TangoTalk-Uploads`)로 바꾸면 그 폴더가 관리자 전용으로
      잠기고 업로드/다운로드가 정상. `D:\`나 내 `문서` 폴더는 거부되고, 다른 파일이 든 폴더는 확인 창이 뜸
- [ ] (권한 상승 차단) **일반 계정으로** `C:\TangoTalk-Server`를 만들고 `tools\nssm.exe` 등을 미리 심어 둔 뒤
      관리자로 설치 → "이전 TangoTalk 서버 설치나 이 PC의 관리자 권한으로 만든 폴더인지 확인되지 않았습니다" 메시지로
      설치가 **중단**되고(심어 둔 코드가 실행되지 않음), 안내문이 폴더를 지우라고 하지 않고 "확인·이동 뒤 다른 경로"를
      권함. 테스트용으로 심은 그 폴더를 치우고 다시 설치하면 정상. `C:\TangoTalk-Server`를 정션으로 만들어 두면(대상이
      있든 지워져 끊어졌든) "링크" 메시지로 중단됨. 설치 로그(`/LOG`)에 "설치 폴더 검사 결과 코드: 2"가 남음
- [ ] (관리자 소유지만 다른 계정도 쓸 수 있는 폴더) 관리자 PowerShell에서 `C:\` 바로 아래에 새 폴더를 만들어(소유자
      Administrators, `C:\`의 "Authenticated Users: 수정" 상속) 그 폴더를 설치 경로로 골라 설치 → "다른 Windows 계정도 이
      폴더에 파일을 넣거나 폴더 이름을 바꿀 수 있게" 확인 창이 뜨고 기본 단추가 "아니요"(로그 "결과 코드: 4"). "아니요"면
      폴더를 지우라는 말 없이 중단, 같은 설치를 `/SUPPRESSMSGBOXES`로 돌리면 창 없이 중단(종료 코드 7)
- [ ] 정상 업그레이드(이미 설치된 서버 위에 새 설치 프로그램 덮어쓰기)는 중단되지 않고, 서비스가 멈췄다
      다시 뜨며 `.env`/DB/데이터가 그대로임(PrepareToInstall의 HKLM 제거 키 일치 검사가 막지 않는지)
- [ ] **일반 제거 뒤 같은 경로에 재설치하면 데이터가 이어짐** — "TangoTalk 서버 제거"(또는 설치된 앱에서 제거)로 지운 뒤
      (제거 키는 없어지고 `pgsql`·`pgsql-data`·`secrets`·`server\.env`·`uploads`·`certs`·`backups`는 남음) 같은
      `C:\TangoTalk-Server`로 다시 설치 → 확인 창 없이 중단되지 않고(잠긴 폴더 — 로그에 "설치 폴더 검사 결과 코드: 0"),
      기존 계정으로 로그인·이전 메시지·첨부파일이 그대로. 잠금 전 버전으로 설치했다가 제거한 폴더(소유자 Administrators,
      C:\ 권한 상속)는 위의 확인 창(로그 "결과 코드: 4")이 뜨고, "예"를 누르면 같은 결과로 설치된 뒤 그 폴더가 잠김(그 뒤
      다시 제거·재설치하면 창 없이 "결과 코드: 0")
- [ ] "서버 완전 삭제" 뒤(`backups`·로그·`server\.livekit-secret` 등만 남은 폴더 — 창에 "남는 것"이 보임) 같은 경로에
      재설치 → 중단되지 않고 빈 서버로 시작, 남아 있던 `backups\*.dump`는 그대로
- [ ] (서버 운영자 복구) 활성 서버 운영자가 있는 서버에서 설치 폴더의 `Grant-ServerAdmin.ps1`을 오른쪽 클릭 →
      "PowerShell에서 실행" → UAC 확인 → 아무 아이디 입력 → "이미 서버 운영자가 있어 아무것도 바꾸지 않았습니다"와
      노란 줄, 종료 코드 1. 운영자를 모두 없앤 테스트 DB에서는 탈퇴하지 않은 계정의 아이디를 넣으면 그 계정이 운영자가 되고(정지돼
      있었으면 풀림) 그 계정으로 관리자 콘솔이 열림. 없는 아이디는 거절, 빈 입력은 아무것도 안 바꾸고 취소
- [ ] `{app}\backups`(또는 `secrets`/`pgsql-data`/`server\uploads`/`server\certs`)를 정션으로 바꿔 두고 "백업"/
      설치/업데이트 → 백업은 "링크라 안전하지 않다"며 **덤프를 쓰지 않고 중단**, 설치는 2.5단계에서 `Fail`,
      업데이트는 경고 로그가 뜸. `Folder-Acl.ps1`을 지운 상태로 "백업"하면 "다시 설치하라"며 중단됨
