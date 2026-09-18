# TangoTalk 서버 설치 프로그램

새 "서비스 PC"에 Node.js 서버 + PostgreSQL을 한 번에 설치하는 Inno Setup 기반 설치 프로그램.
자세한 배경/설계는 저장소 루트 `README.md`의 관련 섹션과, 이 기능을 설계할 때 정리한 계획을
참고. 이 폴더는 이 설치 프로그램 자체를 유지보수하는 사람을 위한 메모다.

## 빌드

저장소 루트에서:

```powershell
.\build_server_installer.ps1
```

`installer/bin/`(Node 포터블 런타임 zip, PostgreSQL 설치 프로그램, `nssm.exe`)와 `installer/stage/`
(정리된 `server/` 소스 + `npm install`로 새로 만든 `node_modules`)를 채우고, 저장소 루트
`README.md`를 `installer/README.html`로 변환한 뒤 ISCC.exe로 `messenger-server.iss`를
컴파일한다. 셋 다 git에는 안 올라간다(`server/.gitignore`) — 매 빌드마다 새로 받고 새로 만든다.

## 파일 구성

| 파일 | 역할 |
|---|---|
| `messenger-server.iss` | Inno Setup 스크립트. `PrivilegesRequired=admin`, 설치 경로 선택 가능(기본값 `C:\TangoTalk-Server`) |
| `Setup-TangoTalkServer.ps1` | 설치 마지막 단계에서 실행 — PostgreSQL 무인 설치, DB 계정/생성, `.env` 작성, 마이그레이션, 방화벽, 서비스 등록. 재실행해도 안전(idempotent) |
| `Get-PairingCode.ps1` | 시작 메뉴 "새 기기 페어링 코드 발급"이 호출 — `server/scripts/pair.mjs`와 같은 일을 Node 없이 순수 PowerShell로 |
| `Update-Server.ps1` | "서버 업데이트" — 업데이트 zip을 파일 선택 창에서 골라 적용(WinForms GUI). DB는 안 건드림, npm install+마이그레이션+서비스 재시작 자동. 관리자 권한 필요해 스스로 승격 |
| `Storage-Path.ps1` | "첨부파일 저장소" — 첨부파일 저장 위치(`UPLOADS_DIR`)를 보여주고 NAS/다른 PC 공유 폴더 등으로 바꿈(WinForms GUI). 기존 파일 이동 여부를 물어보고 `.env` 갱신 + 서비스 재시작. 관리자 권한 필요해 스스로 승격 |
| `Backup-Data.ps1` | "백업" — DB를 `{app}\backups\messenger_<날짜시각>.dump`로 저장(`pg_dump -F c`). 서버는 멈추지 않음. 관리자 권한 필요해 스스로 승격 |
| `Restore-Data.ps1` | "복원" — 파일 선택 창(WinForms)에서 `.dump`를 골라 `pg_restore --clean --if-exists`로 되돌림. `Reset-Data.ps1`과 같은 안전장치(서버 운영자 계정 인증 + `RESTORE` 입력 확인) 필수, 복원 중엔 서비스 정지 후 재시작. 관리자 권한 필요해 스스로 승격 |
| `Reset-Data.ps1` | "DB 데이터 초기화" — 서버는 그대로 두고 데이터만 비움. 서버 운영자 계정 인증 + `RESET` 입력 확인 둘 다 필수 |
| `Uninstall-Full.ps1` | "서버 완전 삭제(PostgreSQL·Node 앱·DB 데이터 모두)" — PostgreSQL 자체(`uninstall-postgresql.exe`)와 DB 데이터를 정식 제거한 뒤, 마지막 단계로 일반 제거 프로그램(`unins000.exe /VERYSILENT`)까지 자동 실행해서 Node 앱 프로그램 파일도 지움. 서버 운영자 계정 인증(`server/scripts/verify-admin.mjs`) + `DELETE` 입력 확인 둘 다 필수 |
| `README-설치후.txt` | 설치되는 사람이 보는 안내문(`[Files]`로 설치됨) |
| `build-readme-html.mjs` | 빌드 시에만 쓰는 변환기 — 저장소 루트 `README.md`를 `installer/README.html`로 만든다(설치 프로그램에는 포함 안 됨, 결과물인 README.html만 포함됨). 이 프로젝트 README들이 실제 쓰는 마크다운 구성(제목·굵게·인라인 코드·링크·코드펜스·표·순서/비순서 목록(중첩 포함)·체크박스·인용문)만 처리하는 자체 변환기 — 범용 마크다운 라이브러리(marked 등)를 새 의존성으로 추가하지 않으려고 직접 짰다 |
| `README.html`(빌드 산출물, git 미포함) | 시작 메뉴 "도움말"이 그대로 여는 파일 — 저장소 루트 `README.md` 전체를 목차 링크가 실제로 동작하는 정적 웹페이지로 변환한 것. 기본 브라우저로 열림 |

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
  실제 데이터를 지울 수 있으면 안 되므로, `Uninstall-Full.ps1`/`Reset-Data.ps1` 둘 다 먼저
  `server/scripts/verify-admin.mjs`로 실제 서버 운영자(`is_server_admin=true`) 계정의
  아이디/비밀번호를 확인하고(비밀번호는 stdin으로만 전달 — 커맨드라인 인자로 안 남김),
  통과해야만 그 다음 `DELETE`/`RESET` 입력 확인으로 넘어간다. 이 스크립트는 설치 프로그램의
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
- **`Update-Server.ps1`/`Storage-Path.ps1`/`Backup-Data.ps1`/`Restore-Data.ps1`/`Reset-Data.ps1`/
  `Uninstall-Full.ps1` 전부 스스로 관리자 권한으로 승격한다.** NSSM 서비스 정지/재시작,
  PostgreSQL 제거, 일반 제거 프로그램 실행 전부 관리자 권한이 필요한데, 시작 메뉴 바로가기를
  그냥 두 번 클릭하면 관리자 권한 없이 실행되기 때문에 — `[Security.Principal.WindowsPrincipal]`로
  확인해서 아니면 `Start-Process -Verb RunAs`로 자기 자신을 다시 실행하고 원래 프로세스는 종료한다.
- **`Backup-Data.ps1`/`Restore-Data.ps1`은 `.env`를 안 읽는다.** DB 접속 정보(포트 `55432`,
  DB명 `messenger`, 앱 계정 `messenger_app`)는 상수로 박아두고, 비밀번호만
  `{app}\secrets\db-app.pw`에서 그대로 읽는다 — `Setup-TangoTalkServer.ps1`이 이미 저장해둔
  값을 재사용하는 것뿐이라 `.env`의 `DATABASE_URL`을 파싱하는 것보다 안전하고 간단하다.
  백업 파일은 `{app}\backups\`에 쌓인다 — `releases`/`secrets`/`pgsql-data`와 같은 성격의
  실데이터 폴더라 `[UninstallDelete]`에 없다(일반 제거로 안 지워짐).
- **`Storage-Path.ps1`은 새 메커니즘을 만들지 않는다.** `server/src/config.js`의
  `UPLOADS_DIR`은 원래부터 환경변수로 바꿀 수 있었다(`process.env.UPLOADS_DIR || 기본값
  server/uploads`) — 이 스크립트는 그 값을 `.env`에 써주고 서비스를 재시작해주는 GUI일
  뿐이다. 경로를 바꿀 때 기존 파일이 있으면 새 위치로 옮길지 물어보고(`robocopy /MOVE`),
  NAS 등 네트워크 경로(`\\서버\공유\폴더`)도 텍스트로 직접 입력하면 그대로 쓸 수 있다.
- **마이그레이션은 번들된 `drizzle-kit`으로 실행한다** (`server/node_modules/drizzle-kit/bin.cjs
  migrate`) — 그래서 빌드 스크립트는 `npm install --omit=dev`가 아니라 devDependencies까지
  포함해서 설치해야 한다(`drizzle-kit`이 `package.json`에서 devDependency이기 때문). 이 부분을
  프로덕션 전용 설치로 "최적화"하면 마이그레이션이 깨진다.
- **`firebase-service-account.json`은 설치 프로그램이 다루지 않는다.** FCM은 선택 기능이라
  설치 후 수동으로 넣게 했다(`README-설치후.txt` 참고) — 자동화하려면 Inno `[Code]`에 파일
  선택 다이얼로그를 추가해야 하는데, 이 설치 프로그램은 커스텀 Pascal 코드를 최소화하는 방향으로
  설계했다.

## 검증 체크리스트

- [ ] `build_server_installer.ps1` 실행 → `installer/output/tangotalk-server-setup.exe` 생성 확인
- [ ] "도움말"을 열면 기본 브라우저로 `README.html`이 뜨고, 목차의 아무 링크나 눌러보면 해당
      섹션으로 실제로 이동함(표/코드블록/중첩 목록/인용문이 깨지지 않고 보이는지도 확인)
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
      메시지 등은 비워지지만 `.env`/인증서는 남고 서버가 재시작되어 바로 다시 가입 가능
- [ ] "백업"을 누르면 `{app}\backups\`에 `messenger_<날짜시각>.dump` 파일이 생기고, 서버는
      멈추지 않고 계속 쓸 수 있음
- [ ] "복원"은 파일 선택 창이 뜨고, 운영자 인증 + `RESTORE` 입력이 필요; 방금 만든 백업 파일로
      복원하면 회원/팀/메시지가 그 시점 내용으로 돌아오고 서버가 재시작되어 바로 로그인 가능
- [ ] 일반 "TangoTalk 서버 제거"는 위 데이터를 안 건드림
