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
(정리된 `server/` 소스 + `npm install`로 새로 만든 `node_modules`)를 채운 뒤 ISCC.exe로
`messenger-server.iss`를 컴파일한다. 둘 다 git에는 안 올라간다(`server/.gitignore`) — 매 빌드마다
새로 받고 새로 만든다.

## 파일 구성

| 파일 | 역할 |
|---|---|
| `messenger-server.iss` | Inno Setup 스크립트. `PrivilegesRequired=admin`, 설치 경로 고정(`C:\TangoTalk-Server`) |
| `Setup-TangoTalkServer.ps1` | 설치 마지막 단계에서 실행 — PostgreSQL 무인 설치, DB 계정/생성, `.env` 작성, 마이그레이션, 방화벽, 서비스 등록. 재실행해도 안전(idempotent) |
| `Get-PairingCode.ps1` | 시작 메뉴 "새 기기 페어링 코드 발급"이 호출 — `server/scripts/pair.mjs`와 같은 일을 Node 없이 순수 PowerShell로 |
| `Reset-Data.ps1` | "DB 데이터 초기화" — 서버는 그대로 두고 데이터만 비움. 서버 운영자 계정 인증 + `RESET` 입력 확인 둘 다 필수 |
| `Uninstall-Full.ps1` | "서버 삭제(PostgreSQL과 DB 데이터 포함)" — PostgreSQL 자체(`uninstall-postgresql.exe`)와 DB 데이터까지 정식 제거, 일반 제거와 완전히 분리. 서버 운영자 계정 인증(`server/scripts/verify-admin.mjs`) + `DELETE` 입력 확인 둘 다 필수 |
| `README-설치후.txt` | 설치되는 사람이 보는 안내문(`[Files]`로 설치됨) |

## 설계상 중요한 결정들 (바꾸기 전에 이유를 먼저 읽을 것)

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
- **완전 삭제/초기화는 확인 문구 하나만으로 되지 않는다.** 이 PC 앞에 앉을 수 있다는 것만으로
  실제 데이터를 지울 수 있으면 안 되므로, `Uninstall-Full.ps1`/`Reset-Data.ps1` 둘 다 먼저
  `server/scripts/verify-admin.mjs`로 실제 서버 운영자(`is_server_admin=true`) 계정의
  아이디/비밀번호를 확인하고(비밀번호는 stdin으로만 전달 — 커맨드라인 인자로 안 남김),
  통과해야만 그 다음 `DELETE`/`RESET` 입력 확인으로 넘어간다. 이 스크립트는 설치 프로그램의
  `server/node_modules`(pg, bcryptjs)를 그대로 재사용한다 — 별도 의존성을 추가하지 않는다.
- **`Reset-Data.ps1`과 `Uninstall-Full.ps1`은 목적이 다르다.** 전자는 서버는 계속 쓰면서
  데이터만 비우고 싶을 때(`.env`/인증서/설치는 안 건드림, 끝나면 서버 재시작되어 바로 씀),
  후자("서버 삭제")는 서버 자체를 걷어낼 때(PostgreSQL 자체까지 정식 제거 + DB/업로드/
  인증서/`.env`/비밀값까지 다 지움, 이후 "TangoTalk 서버 제거"까지 해야 Node 앱 프로그램
  파일도 없어짐) 쓴다. `Reset-Data.ps1`은
  `public` 스키마의 테이블을 동적으로 찾아서 `TRUNCATE ... RESTART IDENTITY CASCADE`
  하므로(`server/scripts/reset-data.mjs`) 나중에 테이블이 추가돼도 하드코딩된 목록을 고칠
  필요가 없다 — drizzle의 마이그레이션 기록은 별도 `drizzle` 스키마에 있어서 자동으로 안
  건드려진다(초기화 후 마이그레이션을 다시 실행할 필요 없음).
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
- [ ] 깨끗한 PC/VM에서 서비스 모드로 설치 → `Get-Service TangoTalkServer`, `Get-Service
      postgresql-tangotalk` 둘 다 Running
- [ ] `https://localhost:3000/health` 응답 확인
- [ ] "새 기기 페어링 코드 발급"으로 코드 발급 → 클라이언트 앱에서 페어링+회원가입까지 한 사이클
- [ ] 같은 설치 프로그램을 다시 실행(업그레이드 시나리오) → `.env`/DB 비밀번호/데이터 안 바뀜,
      서비스 재시작됨
- [ ] "서버 삭제(PostgreSQL과 DB 데이터 포함)"는 서버 운영자 아이디/비밀번호가 틀리면 `DELETE`
      입력 단계까지도 못 감; 운영자 인증 통과 후 `DELETE`를 안 치면 아무 것도 안 지움; 둘 다
      통과하면 PostgreSQL이 `Get-Service postgresql-tangotalk`에서 안 보일 정도로 정식 제거됨
- [ ] "DB 데이터 초기화"도 같은 방식으로 운영자 인증 + `RESET` 입력이 필요; 통과하면 회원/팀/
      메시지 등은 비워지지만 `.env`/인증서는 남고 서버가 재시작되어 바로 다시 가입 가능
- [ ] 일반 "TangoTalk 서버 제거"는 위 데이터를 안 건드림
