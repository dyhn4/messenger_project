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
| `Uninstall-Full.ps1` | "서버 데이터 완전 삭제" — 일반 제거와 완전히 분리, `DELETE` 입력 확인 필수 |
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
  말 것. 완전 삭제가 필요하면 `Uninstall-Full.ps1`(별도 확인 절차 있음)을 쓴다.
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
- [ ] "서버 데이터 완전 삭제"는 `DELETE`를 안 치면 아무 것도 안 지움; 친 뒤엔 실제로 지워짐
- [ ] 일반 "TangoTalk 서버 제거"는 위 데이터를 안 건드림
