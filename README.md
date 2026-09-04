# TeamTalk

Flutter(PC + Android) 클라이언트와 Node.js(Express + Socket.io + PostgreSQL) 서버로 이루어진
개인/소규모 그룹용 실시간 메신저입니다. 텍스트/이미지/파일/이모티콘 채팅, 토픽·그룹·1:1 채팅방,
댓글(스레드), 종단간 암호화(E2EE) 비밀 대화, FCM 푸시 알림, 자체 배포/업데이트 체계를 갖추고 있습니다.

> 이 문서는 실제 소스 코드(스키마, 라우터, 클라이언트 화면, 빌드/배포 스크립트)를 기준으로
> 작성되었습니다. 코드와 다른 내용을 발견하면 이 문서보다 코드를 신뢰하세요.

## 목차

- [소개](#소개)
- [주요 기능](#주요-기능)
- [향후 계획 / 미구현 기능](#향후-계획--미구현-기능)
- [구성도](#구성도)
- [기술 스택](#기술-스택)
- [프로젝트 구조](#프로젝트-구조)
- [개발 환경 준비](#개발-환경-준비)
- [환경 변수 설정](#환경-변수-설정)
- [PostgreSQL 설정 및 마이그레이션](#postgresql-설정-및-마이그레이션)
- [서버 실행 방법](#서버-실행-방법)
- [PC 앱 실행 방법](#pc-앱-실행-방법)
- [Android 앱 실행 방법](#android-앱-실행-방법)
- [API 목록](#api-목록)
- [DB 구조](#db-구조)
- [FCM 푸시 알림 설정](#fcm-푸시-알림-설정)
- [Android 릴리즈 서명](#android-릴리즈-서명)
- [서버 배포 및 업데이트](#서버-배포-및-업데이트)
- [서버/DB 백업 · 이전 · 초기화](#서버db-백업--이전--초기화)
- [보안 및 암호화](#보안-및-암호화)
- [Git 관리 규칙](#git-관리-규칙)
- [문제 해결](#문제-해결)

## 소개

Firebase는 Windows 데스크톱을 공식 지원하지 않아서(Android/iOS/macOS/Web만 지원), 인증·채팅·파일
전송을 전부 자체 Node.js 서버 하나로 통합했습니다. FCM(푸시 알림)만 Android 클라이언트에서
선택적으로 사용합니다.

| | 역할 |
|---|---|
| `client/` | Flutter 앱 — Windows 데스크톱 + Android. PC는 넓은 화면에서 사이드바+채팅 분할 레이아웃, 좁은 화면(모바일)은 목록→채팅 전환 레이아웃(`client/lib/screens/home_screen.dart`의 `wideBreakpoint = 700`) |
| `server/` | Node.js(Express + Socket.io) 백엔드 — 인증(JWT), 실시간 메시지/이벤트, 파일 업로드, PostgreSQL 저장, FCM 발송 |

## 주요 기능

아래는 실제 라우터(`server/src/*.js`)와 클라이언트 화면(`client/lib/screens`, `client/lib/widgets`)
코드를 기준으로 확인된, **현재 동작하는** 기능만 정리한 목록입니다.

**계정**
- 회원가입/로그인, JWT AccessToken(1시간)+RefreshToken(30일) 발급/재발급
- 회원가입 시 보안 질문(프리셋 5종 중 선택 또는 직접 작성)+답변 **필수** 등록
- 아이디 찾기(이메일로 조회) → 그 자리에서 바로 비밀번호 찾기로 이어가기
- 비밀번호 찾기: 아이디+이메일 확인 → 보안 질문 답변 확인(계정에 질문이 없으면 생략) → 새 비밀번호 설정, 단계별 플로팅 다이얼로그
- 프로필: 이름/아바타(초기값·이모지 캐릭터·사진 업로드) 변경, 이메일 변경(현재 비밀번호 재확인 필요), 비밀번호 변경
- 회원 탈퇴(비밀번호 확인) — 로그인 차단 + 이름/이메일/아바타 익명화, 과거 메시지 발신자 표시도 "탈퇴한 사용자"로 갱신, 1년 뒤 메시지 자동 파기(첨부파일 제외)
- 아이디 중복 확인, "아이디 기억하기"/"로그인 상태 유지"

**채팅방**
- 토픽(공개/비공개), 그룹, 1:1 DM 세 종류
- 공개 토픽은 가입 회원 전원 자동 참여(신규 가입자도 자동 포함), 비공개 토픽/그룹은 초대제
- 채팅방 목록 탐색(`/rooms/browse`), 멤버 초대, 나가기(DM은 "숨기기"), 즐겨찾기, 알림 끄기(뮤트)
- DM은 한쪽이 나갔다가 다시 말을 걸면 자동으로 되살아남(같은 방 재사용)

**메시징**
- 텍스트/이미지/파일/이모티콘(스티커) 전송, 이미지는 업로드 시 썸네일 별도 생성
- 작성 후 5분 이내 본인 메시지 수정/삭제(소프트 삭제) — 댓글도 동일 정책
- 메시지별 댓글(스레드) — PC는 옆 패널, 모바일은 전체화면
- 메시지 인용 공유(다른 방으로), 메시지 전달
- 방별 안읽음 개수, 읽음 시각 동기화(`room:read`)
- 메시지 페이지네이션(기본 50개, 최대 200개, `before` 커서로 과거 메시지 추가 로드)
- 전체 채팅방 통합 검색(`/search` — 내가 속한 방으로 결과 범위 강제, 비밀 대화는 제외)

**비밀 대화 (종단간 암호화 E2EE, 1:1 전용)**
- 기기별 신원키(X25519 교환용 + Ed25519 서명용) 생성/등록, 개인키는 기기 밖으로 나가지 않음(`flutter_secure_storage`)
- 요청 → 수락/거절 다이얼로그(오프라인이었어도 다시 로그인 시 놓친 초대 복구), 임시 공개키 서명 검증(중간자 공격 방지)
- 서버는 암호문·공개키·서명만 보관 — 평문/공유비밀/체인키는 절대 서버에 오지 않음
- 재키잉(rekey) 제안/수신
- 메시지별 자동 삭제 타이머(1초~1주, 상대가 읽은 시점부터 카운트, 만료 시 첨부파일까지 완전 삭제)
- 대화 생명주기 시스템 메시지("요청 보냄"/"시작됨"/"상대방이 종료함") + 토스트(거절/양쪽 나가기)
- 채팅 목록·채팅방 제목에 초록 자물쇠 아이콘 + 초록 이름, 알림 미리보기는 항상 고정 문구, 통합 검색에서 제외

**알림**
- FCM 푸시(Android 전용 — Windows는 미지원, 코드에서 `Platform.isAndroid`로 분기): 소켓이 붙어 있지 않은(=완전히 종료된) 기기에만 발송, data-only 페이로드를 클라이언트가 직접 렌더링
- 안드로이드 "대화" 스타일 알림(발신자 아바타 아이콘 포함), 뮤트한 방은 발송 안 함
- 방을 이미 보고 있으면 로컬 알림 억제, 알림 탭 시 해당 방으로 이동

**서버 연결 / 배포**
- 자체 서명 TLS 인증서 + 클라이언트 인증서 핀닝(공인 CA 미사용)
- 페어링 코드(4자리, 5분 유효, 1회용)로 앱 재빌드 없이 새 인증서 발급/서버 이전
- 서버 버전 배너(`/version`) + 앱 안에서 바로 다운로드/설치
- Windows 설치 프로그램(Inno Setup), Android APK 배포 스크립트(`publish_release.ps1`)

**클라이언트 UX**
- 다크/라이트/시스템 테마, Windows 시스템 시작 시 자동 실행, 다운로드 위치 지정
- 이미지 뷰어(확대/축소), 스티커 선택기, 날짜 구분선, 안읽음 뱃지, 즐겨찾기 별표

## 향후 계획 / 미구현 기능

코드베이스를 확인한 결과, 아래 기능은 **아직 구현되어 있지 않습니다**(추측 없이, 실제로 코드/이벤트가
없는 것만 적었습니다):

- **타이핑 표시**(상대가 입력 중임을 보여주는 기능) — 관련 소켓 이벤트 없음
- **서버 주소 변경 시 사용자 계정 유지** — 지금은 페어링/서버 주소 변경 흐름 자체는 있지만, 서버가
  완전히 다른 인스턴스로 바뀌면(DB가 다르면) 계정은 그 서버 기준으로 다시 로그인해야 합니다
- **채팅방 비밀번호/초대 링크** 등 별도 접근 제어 수단 — 지금은 서버에서 직접 멤버로 추가하는 방식뿐
- **관리자 콘솔/대시보드** — 웹 기반 운영 화면 없음. 운영 작업은 서버 콘솔/SQL로 직접 수행

## 구성도

```
                          (LAN, HTTPS+WSS, TLS 핀닝)
 ┌───────────────┐  ────────────────────────────────▶  ┌─────────────────────────┐
 │ Flutter 클라이언트│                                     │ Node.js 서버 (server/)   │
 │  · Windows      │  ◀────────────────────────────────  │  Express + Socket.io    │
 │  · Android      │       평문 HTTP(PORT+1, 페어링 전용)   │  PORT=3000(기본)         │
 └───────┬─────────┘                                     └──────────┬──────────────┘
         │  FCM data-only push                                       │ drizzle-orm
         │  (Android, 앱 완전 종료 시만)                                │
         ▼                                                            ▼
 ┌───────────────┐                                     ┌─────────────────────────┐
 │ Firebase Cloud  │ ◀── firebase-service-account.json ──│      PostgreSQL          │
 │ Messaging       │      (서버가 발송 시 사용)             │  users/rooms/messages... │
 └───────────────┘                                     └─────────────────────────┘
```

- 클라이언트는 서버가 스스로 발급한 자체 서명 TLS 인증서만 신뢰합니다(공인 CA 미사용).
- 첨부파일은 고정 공개 URL이 아니라 짧게 만료되는 서명 링크(`/files/<token>`)로만 내려갑니다.
- FCM은 Android 클라이언트 → Firebase → 서버(발송) → 다시 FCM → Android 기기 순으로만 쓰이고,
  Windows 클라이언트는 관여하지 않습니다.

## 기술 스택

**서버** (`server/package.json`)

| 분류 | 사용 라이브러리 |
|---|---|
| 런타임 | Node.js (ESM, `"type": "module"`) |
| 웹 프레임워크 | express ^4 |
| 실시간 | socket.io ^4 |
| DB | PostgreSQL + drizzle-orm ^0.45 / drizzle-kit ^0.31 (스키마·마이그레이션) / pg ^8 |
| 인증 | jsonwebtoken, bcryptjs |
| 파일 업로드 | multer |
| 푸시 | firebase-admin ^14 (FCM 발송) |
| TLS | selfsigned(자체 서명 인증서 생성) + Node 내장 `https` |
| 기타 | dotenv, cors |
| 운영 | pm2(선택), ecosystem.config.cjs |

**클라이언트** (`client/pubspec.yaml`)

| 분류 | 사용 라이브러리 |
|---|---|
| 프레임워크 | Flutter (Dart SDK `^3.12.2`, Windows + Android 타깃) |
| 실시간 통신 | socket_io_client, web_socket(웹소켓 커넥터 커스터마이징용) |
| HTTP | http |
| 로컬 저장 | shared_preferences(+ android 전용 백엔드), flutter_secure_storage(E2EE 키) |
| 미디어 | image_picker, file_picker, photo_view, cached_network_image, image(썸네일 가공) |
| 암호화 | cryptography(X25519/Ed25519/AES-GCM, 비밀 대화용) |
| 알림 | firebase_core, firebase_messaging(Android 전용), flutter_local_notifications |
| 데스크톱 통합 | win32, ffi, pasteboard(클립보드 이미지 붙여넣기) |
| UI 보조 | scrollable_positioned_list, intl, package_info_plus, url_launcher, open_file |
| 사내 전용 패키지 | `packages/conversation_shortcuts`(Android "대화" 알림 단축키 등록) |

## 프로젝트 구조

```
messenger_project/
├─ client/                      Flutter 앱
│  ├─ lib/
│  │  ├─ screens/                화면 단위(로그인, 방 목록, 채팅, 검색, 설정 등)
│  │  ├─ widgets/                재사용 위젯(메시지 버블, 아바타, 다이얼로그 등)
│  │  ├─ services/                Session(전역 상태) · ApiClient · ChatSocket · 비밀대화 암복호화 등
│  │  ├─ models/                  Room/Message/Comment/AppUser
│  │  └─ data/                    스티커 등 정적 데이터
│  ├─ packages/conversation_shortcuts/  사내 전용 Flutter 플러그인
│  ├─ android/                   Android 프로젝트(keystore/key.properties/google-services.json 위치)
│  ├─ windows/installer/         Inno Setup 스크립트(messenger.iss)
│  └─ assets/                     아이콘, 서버 인증서(server_cert.pem) 등 빌드 내장 자산
│
├─ server/                      Node.js 백엔드
│  ├─ src/
│  │  ├─ index.js                 앱 진입점 — 라우터 마운트, HTTPS 서버, 소켓/백그라운드 잡 시작
│  │  ├─ auth.js                  회원가입/로그인/토큰 재발급/아이디·비밀번호 찾기
│  │  ├─ users.js                 프로필 조회/수정/비밀번호 변경/탈퇴
│  │  ├─ rooms.js                 채팅방 생성/조회/멤버 관리/메시지 목록
│  │  ├─ messages.js / comments.js  메시지·댓글 수정/삭제
│  │  ├─ secretChats.js / secretExpiry.js  비밀 대화 성립/자동 삭제
│  │  ├─ devices.js               E2EE 기기 신원 등록/조회/폐기
│  │  ├─ search.js                통합 검색
│  │  ├─ upload.js                파일 업로드 + 서명 다운로드 링크
│  │  ├─ push.js                  FCM 발송
│  │  ├─ socket.js                Socket.io 인증 미들웨어 + 실시간 이벤트
│  │  ├─ pairing.js               새 기기 인증서 페어링 부트스트랩 서버
│  │  ├─ certs.js                 자체 서명 TLS 인증서 생성/재사용
│  │  ├─ crypto.js                DB 저장용 필드 암호화(AES-256-GCM) + 조회용 해시
│  │  ├─ retention.js             탈퇴 계정 메시지 1년 보존 후 파기 잡
│  │  ├─ config.js                환경변수/자동 생성 비밀값 로딩
│  │  └─ db/
│  │     ├─ schema.js              drizzle 스키마(스키마의 원본 — 여기를 고치면 db:generate부터)
│  │     ├─ client.js              DB 커넥션
│  │     └─ queries/                테이블별 쿼리 함수
│  ├─ drizzle/                   drizzle-kit이 생성한 SQL 마이그레이션 파일들
│  ├─ scripts/pair.mjs           pm2 등으로 띄웠을 때 콘솔 입력 없이 페어링 코드 발급
│  ├─ certs/                     자체 서명 TLS 인증서(gitignore, 자동 생성)
│  ├─ uploads/                   업로드된 첨부파일(gitignore)
│  ├─ releases/                  배포용 빌드 산출물 + version.json(gitignore)
│  ├─ ecosystem.config.cjs       pm2 설정
│  └─ .env.example               환경변수 예시(값은 비어 있음)
│
├─ docs/                        (현재 비어 있음)
├─ publish_release.ps1          클라이언트 릴리즈 빌드 → server/releases/ 배포 스크립트
└─ README.md
```

## 개발 환경 준비

Windows 기준입니다.

| 도구 | 용도 | 확인 명령 |
|---|---|---|
| Node.js (LTS) | 서버 실행 | `node --version` |
| PostgreSQL | 채팅 데이터 저장소 | `psql --version` |
| Flutter SDK (stable) | 클라이언트 빌드 | `flutter --version` |
| Android Studio | Android SDK, keytool, (선택)Android 빌드 | — |
| Visual Studio (Desktop development with C++ workload) | `flutter build windows` 컴파일에 필요 | — |
| Windows 개발자 모드 | Windows 데스크톱 첫 빌드 시 심볼릭 링크 지원에 필요 | `start ms-settings:developers` |
| Inno Setup | Windows 설치 프로그램(.exe) 컴파일 | `winget install JRSoftware.InnoSetup` |

```powershell
git clone <이 저장소 주소>
cd messenger_project
```

## 환경 변수 설정

서버는 `server/.env`를 읽습니다(`dotenv`). 저장소에는 값이 비어 있는 `server/.env.example`만
있으므로, 이를 복사해서 채웁니다:

```powershell
cd server
copy .env.example .env
notepad .env
```

| 변수 | 필수 | 설명 |
|---|---|---|
| `DATABASE_URL` | ✅ | PostgreSQL 접속 문자열. 자동 생성 안 됨 — 반드시 직접 채워야 합니다. 예: `postgres://messenger_app:비밀번호@localhost:5432/messenger` |
| `JWT_SECRET` | 선택 | AccessToken/RefreshToken 서명키. 비워두면 서버가 최초 실행 시 안전한 무작위 값을 만들어 `server/.jwt-secret` 파일에 저장하고 계속 재사용합니다. |
| `DB_ENCRYPTION_KEY` | 선택 | 이메일 등 민감 필드 암호화 키(32바이트/64자리 hex 고정). 비워두면 `server/.db-encryption-key`에 자동 생성/재사용. 직접 만들려면: `node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"` |
| `PORT` | 선택 | 서버 HTTPS 포트. 기본 `3000`. |
| `PAIRING_PORT` | 선택 | 새 기기 페어링용 평문 HTTP 부트스트랩 포트. 기본 `PORT+1`. |
| `UPLOADS_DIR` | 선택 | 첨부파일 저장 위치. 기본은 `server/uploads/`. UNC 경로나 매핑된 네트워크 드라이브도 가능(예: `\\192.168.0.10\share\messenger_uploads`, `Z:\messenger_uploads`) — 항상 접근 가능해야 업로드/다운로드가 됩니다. |

**여러 서버 인스턴스를 두거나 DB를 옮길 계획이 있다면** `JWT_SECRET`/`DB_ENCRYPTION_KEY`를 반드시
`.env`에 직접 고정하세요. 자동 생성 값에 의존하면 서버 재설치 시 값이 달라져 기존 로그인 세션과
DB에 암호화 저장된 이메일을 읽을 수 없게 됩니다.

**서버 IP/도메인은 환경 변수가 아니라 클라이언트 쪽에서 관리합니다** — 서버는 자기 자신의 LAN IP를
자동으로 찾아 콘솔에 출력할 뿐, 특정 도메인/`API_BASE_URL`을 설정 파일에 못박아두지 않습니다.
클라이언트가 로그인 화면의 "서버 주소 변경"에서 주소(IP 또는 도메인 모두 가능)를 직접 입력해
`shared_preferences`에 저장하고, 이후 모든 요청이 그 주소를 씁니다. 공유기에 포트포워딩 + 고정
도메인(DDNS 등)을 연결해두면 클라이언트에는 IP 대신 그 도메인을 입력하면 됩니다.

## PostgreSQL 설정 및 마이그레이션

PostgreSQL이 설치되어 있어야 하고, 이 앱 전용 데이터베이스/계정을 하나 만들어둬야 합니다(슈퍼유저로
한 번만):

```powershell
psql -U postgres -c "CREATE USER messenger_app WITH PASSWORD '원하는_비밀번호';"
psql -U postgres -c "CREATE DATABASE messenger OWNER messenger_app;"
```

그 다음 `server/.env`의 `DATABASE_URL`을 위 계정으로 채우고(환경 변수 설정 참고), 마이그레이션을
적용합니다:

```powershell
cd server
npm install
npm run db:generate   # schema.js 기준으로 마이그레이션 SQL 생성 — 스키마(server/src/db/schema.js)를 고칠 때마다
npm run db:migrate    # 실제 DB에 적용 — 처음 실행 전 필수
```

- 스키마의 원본(source of truth)은 `server/src/db/schema.js`이고, `server/drizzle/*.sql`은
  `db:generate`가 그 변경 이력으로부터 자동 생성한 파일입니다. **SQL을 손으로 직접 고치지 않습니다.**
- 테이블 구조는 [DB 구조](#db-구조) 참고.

## 서버 실행 방법

```powershell
cd server
npm start          # 운영/일반 실행
npm run dev         # 개발용 — 파일 변경 시 자동 재시작(node --watch)
```

실행하면 콘솔에 접속 주소가 찍힙니다. 이 주소를 클라이언트 앱의 "서버 연결" 화면에 그대로
입력하세요.

```
메신저 서버 실행 중 (HTTPS, 포트 3000)
같은 와이파이의 다른 기기에서 접속할 주소:
  https://192.168.0.10:3000
```

- PC 방화벽이 처음 실행 시 "네트워크 접근 허용" 팝업을 띄우면 허용해야 다른 기기에서 접속됩니다.
- 클라이언트와 서버가 **같은 LAN(와이파이/유선망)**에 있어야 합니다. 외부망(LTE 등)에서 쓰려면
  공유기 포트포워딩 + 고정 IP(또는 DDNS)가 추가로 필요합니다.
- 첨부파일 저장 위치/용량 제한은 [환경 변수 설정](#환경-변수-설정)과 아래 [보안 및 암호화](#보안-및-암호화)를 참고하세요. 파일 업로드 용량 제한은 **200MB**입니다(`server/src/upload.js`의 `limits.fileSize`).
- 새 기기를 페어링하려면(인증서 발급) 서버 콘솔에 `pair`를 입력하고 Enter — 4자리 코드(5분간
  유효, 1회용)가 나오면 클라이언트의 "서버 주소 변경" 화면에 같이 입력합니다.

### pm2로 서버 운영하기

`node src/index.js`를 터미널에 직접 띄워두는 대신 [pm2](https://pm2.keymetrics.io/)로 관리하면
크래시 시 자동 재시작되고, 업데이트 시 재시작 명령 한 줄로 끝납니다.

```powershell
npm install -g pm2        # 최초 1회
npm run pm2:start         # 서버 시작 (= pm2 start ecosystem.config.cjs)
npm run pm2:logs          # 로그 보기
npm run pm2:restart       # 재시작 (업데이트 후)
npm run pm2:stop          # 정지
```

Windows 재부팅 시 자동으로 다시 시작되게 하려면(pm2 공식 `pm2 startup`은 Linux 전용):

```powershell
npm install -g pm2-windows-startup
pm2-startup install
pm2 save                  # 지금 떠있는 프로세스 목록을 저장 — 재부팅 후 이걸 복원함
```

**주의**: pm2로 띄우면 콘솔 입력을 받을 수 없어 `pair` 입력 방식이 안 됩니다. 대신 서버가 떠있는
같은 PC에서 다음을 실행하세요:

```powershell
npm run pair
```

(`scripts/pair.mjs`가 `pairing.js`의 `/admin/generate`를 호출 — 이 PC 안에서 온 요청만 허용되어
외부에는 열려있지 않습니다.)

## PC 앱 실행 방법

Windows 데스크톱으로 처음 빌드하려면 개발자 모드가 필요합니다(심볼릭 링크 지원):

```powershell
start ms-settings:developers
```

**개발 실행**

```powershell
cd client
flutter run -d windows
```

**릴리즈 빌드**

```powershell
flutter build windows --release
```

`flutter build windows --release`는 `client.exe`와 dll이 흩어진 폴더를 만들 뿐이라 그대로
배포하기는 불편합니다. [Inno Setup](https://jrsoftware.org/isinfo.php)으로 하나의 설치
프로그램(`messenger-setup.exe`)을 만듭니다 — 관리자 권한 없이 현재 계정에 설치되고, 시작
메뉴/바탕화면 바로가기와 제거 프로그램까지 자동으로 생깁니다. 스크립트는
`client/windows/installer/messenger.iss`이며, 보통은 아래 [서버 배포 및 업데이트](#서버-배포-및-업데이트)의
`publish_release.ps1`이 컴파일까지 대신 해줍니다.

## Android 앱 실행 방법

**개발 실행** (기기를 USB로 연결하거나 에뮬레이터 실행 후)

```powershell
cd client
flutter run
```

**릴리즈 빌드**

```powershell
flutter build apk --release
```

release 빌드에는 서명이 필요합니다 — 자세한 절차는 [Android 릴리즈 서명](#android-릴리즈-서명) 참고.
서명(`client/android/key.properties`)이 없으면 release 빌드는 디버그 키로 자동 폴백합니다(로컬
테스트용 `flutter run --release`는 문제없이 되지만, 그 apk는 배포하면 안 됩니다).

## API 목록

모든 `/api/*`, `/auth/refresh` 이후 요청은 `Authorization: Bearer <AccessToken>` 헤더가
필요합니다(`server/src/auth.js`의 `requireAuth`). `/auth/*`(회원가입/로그인/찾기류), `/health`,
`/version`, `/downloads/*`, `/files/:token`은 인증 없이 호출 가능합니다.

**인증** (`/auth`, 인증 불필요)

| Method | Path | 설명 |
|---|---|---|
| GET | `/auth/username-available` | 아이디 중복 확인 |
| POST | `/auth/register` | 회원가입(보안 질문/답변 필수) |
| POST | `/auth/find-id` | 이메일로 아이디 찾기 |
| POST | `/auth/security-question` | 아이디+이메일 일치 확인 후 보안 질문 반환 |
| POST | `/auth/verify-security-answer` | 보안 질문 답변만 검증(비밀번호는 안 바꿈) |
| POST | `/auth/reset-password` | 비밀번호 재설정(이메일+보안 질문 답변 확인) |
| POST | `/auth/login` | 로그인 |
| POST | `/auth/refresh` | AccessToken 재발급 |

**사용자/프로필** (`/api`, 인증 필요)

| Method | Path | 설명 |
|---|---|---|
| GET | `/api/users` | 활성 가입자 전체 목록(방 생성용) |
| GET | `/api/users/me` | 내 프로필 조회 |
| PATCH | `/api/users/me` | 이름/이메일/아바타 수정(이메일 변경은 `currentPassword` 필요) |
| POST | `/api/users/me/change-password` | 비밀번호 변경 |
| POST | `/api/users/me/withdraw` | 회원 탈퇴 |

**채팅방** (`/api`)

| Method | Path | 설명 |
|---|---|---|
| GET | `/api/rooms` | 내 채팅방 목록 |
| GET | `/api/rooms/browse` | 가입 가능한 공개/비공개 토픽 탐색 |
| POST | `/api/rooms/dm` | 1:1 DM 방 생성/재사용 |
| POST | `/api/rooms` | 토픽/그룹 방 생성 |
| POST | `/api/rooms/:id/join` | 공개 토픽 참여 |
| POST | `/api/rooms/:id/invite` | 멤버 초대 |
| POST | `/api/rooms/:id/leave` | 나가기(숨기기) |
| POST | `/api/rooms/:id/favorite` | 즐겨찾기 토글 |
| POST | `/api/rooms/:id/muted` | 알림 끄기 토글 |
| GET | `/api/rooms/:id` | 방 정보 조회 |
| GET | `/api/rooms/:id/messages` | 메시지 목록(`limit`, `before` 커서 페이지네이션) |

**메시지/댓글** (`/api`)

| Method | Path | 설명 |
|---|---|---|
| PATCH | `/api/messages/:id` | 메시지 수정(작성 후 5분 이내, 본인만) |
| DELETE | `/api/messages/:id` | 메시지 삭제(소프트 삭제) |
| POST | `/api/messages/:messageId/comments` | 댓글 작성 |
| PATCH | `/api/comments/:id` | 댓글 수정 |
| DELETE | `/api/comments/:id` | 댓글 삭제 |

**기기 / 비밀 대화(E2EE)** (`/api`)

| Method | Path | 설명 |
|---|---|---|
| POST | `/api/devices` | 기기 신원(공개키) 등록 |
| GET | `/api/devices` | 내 기기 목록 |
| GET | `/api/devices/:deviceId/public-key` | 상대 기기 공개키 조회(핸드셰이크용) |
| PATCH | `/api/devices/:deviceId/fcm-token` | FCM 토큰 등록/해제 |
| DELETE | `/api/devices/:deviceId` | 기기 폐기 |
| POST | `/api/secret-chats` | 비밀 대화 요청 |
| GET | `/api/secret-chats/:roomId/invite` | 놓친 초대 다시 조회 |
| POST | `/api/secret-chats/:roomId/accept` | 수락 |
| POST | `/api/secret-chats/:roomId/reject` | 거절 |
| PATCH | `/api/secret-chats/:roomId/settings` | 자동 삭제 타이머 설정 |

**검색 / 업로드 / 기타**

| Method | Path | 인증 | 설명 |
|---|---|---|---|
| GET | `/api/search` | 필요 | 내가 속한 방 통합 검색(`q`, `roomId`, `senderId`, `since`, `until`, `limit`) |
| POST | `/api/upload` | 필요 | 파일 업로드(최대 200MB) |
| GET | `/files/:token` | 불필요(토큰 자체가 자격증명) | 서명된 다운로드 링크 |
| GET | `/health` | 불필요 | 헬스체크 |
| GET | `/version` | 불필요 | 최신 클라이언트 버전 조회 |
| GET | `/downloads/windows`, `/downloads/android` | 불필요 | 최신 설치 파일 다운로드 |

**Socket.io 이벤트** (`server/src/socket.js`, 연결 시 `auth: { token, deviceId? }`)

| 방향 | 이벤트 | 설명 |
|---|---|---|
| 클라이언트→서버 | `message:send` | 메시지 전송 |
| 클라이언트→서버 | `room:read` | 읽음 처리 |
| 클라이언트→서버 | `secret:message-read` | 비밀 대화 메시지 읽음(자동 삭제 타이머 시작) |
| 클라이언트→서버 | `secret:rekey-propose` / `secret:rekey-ack` | 비밀 대화 재키잉 |
| 서버→클라이언트 | `message:new` / `message:edited` / `message:deleted` / `message:expired` | 메시지 변경 브로드캐스트 |
| 서버→클라이언트 | `comment:new` / `comment:edited` / `comment:deleted` | 댓글 변경 브로드캐스트 |
| 서버→클라이언트 | `room:created` | 방 생성/멤버 변경 시 최신 방 정보 |
| 서버→클라이언트 | `presence:update` | 온라인/오프라인 |
| 서버→클라이언트 | `secret:invite` / `secret:accepted` / `secret:rejected` / `secret:left` | 비밀 대화 생명주기 |

## DB 구조

PostgreSQL, `drizzle-orm`으로 접근(원본 스키마: `server/src/db/schema.js`). 쿼리 함수는
`server/src/db/queries/*.js`에 테이블별로 나뉘어 있고, 라우터는 이 함수들을 통해서만 DB에
접근합니다(SQL을 라우터에 직접 쓰지 않음).

| 테이블 | 요약 |
|---|---|
| `users` | 계정. `email_enc`(암호화)+`email_lookup`(조회용 해시)로 이메일 분리 저장, `security_question`/`security_answer_hash`(비밀번호 찾기용, bcrypt), `token_version`(전체 로그아웃/탈퇴 시 증가), `deleted_at`(탈퇴), `avatar_*`(아바타 종류/이모지/색/사진 URL) |
| `rooms` | 채팅방. `type`은 `topic`\|`group`\|`dm`, `dm_key`(DM 중복 생성 방지 unique), `is_secret`(비밀 대화 플래그), `secret_departed_member_*`(비밀 대화 상대 혼자 나갔을 때 표시용) |
| `room_members` | 방 멤버십(복합 PK). `last_read_at`, `favorite`, `muted`를 멤버별로 보관 |
| `messages` | 메시지. `type`은 `text`\|`image`\|`file`\|`system`, 소프트 삭제(`deleted_at`), 5분 수정 윈도우, `thumbnail_url`(이미지 축소본), `read_at`/`expires_at`(비밀 대화 자동 삭제), `quoted_*`(인용 공유 스냅샷), `forwarded_from_*`(전달 스냅샷) |
| `message_comments` | 메시지별 댓글. `messages`와 거의 동일한 구조(첨부/소프트삭제/5분 수정 윈도우) |
| `devices` | 비밀 대화용 기기 신원(X25519/Ed25519 공개키), `fcm_token`(Android 전용), `revoked_at` |
| `secret_sessions` | 비밀 대화 방 1개당 1행 — 상태(`pending`\|`active`\|`rejected`\|`terminated`), 양측 임시 공개키+서명, `key_epoch`, `self_destruct_seconds` |
| `secret_rekeys` | 재키잉 제안/수락 이력(append-only) |

## FCM 푸시 알림 설정

FCM은 **Android 전용**입니다(Windows는 Firebase가 공식 지원하지 않아, 코드에서
`Platform.isAndroid`로 완전히 분기 — `client/lib/main.dart`, `server/src/push.js` 참고).
서비스 계정 키가 없어도 서버는 정상 기동하며, 그 경우 푸시 발송만 조용히 비활성화됩니다.

필요한 파일 2개:

| 파일 | 위치 | 용도 | Git |
|---|---|---|---|
| `google-services.json` | `client/android/app/google-services.json` | 클라이언트가 Firebase 프로젝트에 연결(패키지명 `com.teamtalk.messenger` 필요) | ⚠️ 현재 저장소에 커밋되어 있음 — [Git 관리 규칙](#git-관리-규칙) 참고 |
| `firebase-service-account.json` | `server/firebase-service-account.json` | 서버가 FCM 메시지를 실제로 발송할 때 쓰는 관리자 키 | 커밋 금지(`.gitignore`에 있음) |

**새 Firebase 프로젝트로 설정(또는 다른 계정으로 교체)하는 절차**

1. [Firebase 콘솔](https://console.firebase.google.com/)에서 새 프로젝트 생성
2. Android 앱 추가 — 패키지 이름에 정확히 `com.teamtalk.messenger` 입력(다르면 알림이 안 옵니다)
3. 다운로드한 `google-services.json`을 `client/android/app/google-services.json`에 덮어쓰기
4. Firebase 콘솔 → 프로젝트 설정 → 서비스 계정 → "새 비공개 키 생성" → 다운로드한 JSON을
   `server/firebase-service-account.json`으로 저장
5. 서버 재시작(시작 시점에 이 파일 존재 여부를 한 번만 확인합니다)
6. 클라이언트를 다시 빌드(`google-services.json`이 빌드에 반영되도록)

**설계 메모**: 알림은 `notification` 페이로드가 아니라 `data`(data-only)로만 보냅니다 — 그래야
앱이 완전히 꺼져 있을 때도 OS가 자체 렌더링하지 않고 `onBackgroundMessage` 핸들러가 호출되어,
실시간 소켓으로 받는 알림과 똑같은 모양(발신자 아바타, 자물쇠 배지 등)으로 그릴 수 있습니다. 이미
소켓이 연결된(=앱이 떠있는) 기기에는 중복 발송하지 않습니다.

## Android 릴리즈 서명

release 빌드에는 서명이 필요합니다 — 서명 없이는 배포는커녕 기존 설치본 위에 업데이트 설치도
안 됩니다. 최초 1회만 만들면 계속 재사용합니다(**꼭 안전하게 보관** — 잃어버리면 이후 업데이트를
기존 설치본에 덮어씌울 수 없고 사용자들이 재설치해야 합니다):

```powershell
& "C:\Program Files\Android\Android Studio\jbr\bin\keytool.exe" -genkey -v -keystore client\android\upload-keystore.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload
```

(Android Studio 설치 경로는 설치 방식에 따라 `C:\Program Files\Android Studio\` 인 경우도 있습니다 —
`keytool.exe`가 안 보이면 `Get-ChildItem "C:\Program Files" -Recurse -Filter keytool.exe`로 찾으세요.)

그다음 `client/android/key.properties`를 만듭니다(`.gitignore`에 있어 git엔 안 올라감):

```
storePassword=<keystore 비밀번호>
keyPassword=<키 비밀번호>
keyAlias=upload
storeFile=../upload-keystore.jks
```

이 파일이 없으면 release 빌드는 디버그 키로 자동 폴백합니다. `client/android/app/build.gradle.kts`는
debug 빌드도 release와 같은 키로 서명하도록 되어 있습니다 — 실기기에 이미 release 서명으로 설치된
앱 위에 debug 빌드를 덮어씌울 때 "signatures do not match"로 설치가 거부되는 걸 막기 위함입니다
(`key.properties`가 없으면 표준 디버그 키로 자동 폴백해서 빌드는 그냥 됩니다).

### SHA-1/SHA-256 지문 확인

Firebase 콘솔 등록이나 Google Cloud Console의 API 키 제한(패키지명+서명 지문)에 필요합니다.
가장 정확한 방법은 Gradle이 실제 빌드에 쓰는 서명 설정을 그대로 보여주는 `signingReport`입니다
(`key.properties` 유무에 따라 어떤 키가 어떤 variant에 쓰이는지까지 한 번에 나옵니다):

```powershell
$env:JAVA_HOME = "C:\Program Files\Android\Android Studio\jbr"   # PowerShell엔 JAVA_HOME이 기본으로 없어서 gradlew가 "JAVA_HOME is not set" 오류로 실패한다 — 이 창에서만 적용, 영구 적용하려면 setx 사용
cd client\android
.\gradlew signingReport
```

`:app:signingReport` 항목에서 `Variant: release`(배포용 apk가 실제로 서명되는 키)의 SHA1 값을
씁니다. `key.properties`가 있는 이 프로젝트는 `debug` variant도 같은(release) 키로 서명되므로,
로컬에서 `flutter run`으로 테스트할 때도 이 SHA1이 적용됩니다 — 등록은 이거 하나로 충분합니다.
(keytool로 직접 확인하는 방법도 있지만 `-list -v`가 일부 Windows/한국어 로케일 JDK 조합에서
포맷 오류로 깨지는 경우가 있어, gradlew 방식을 권장합니다.)

## 서버 배포 및 업데이트

### 클라이언트 버전 배포

클라이언트는 앱을 시작할 때마다 서버의 `/version`을 확인해서, 서버에 더 최신 버전이 올라와 있으면
화면에 배너로 알려줍니다. 새 버전을 배포하려면 `client/pubspec.yaml`의 `version:`을 올린 뒤,
저장소 루트에서 한 번에:

```powershell
.\publish_release.ps1 -Version "1.0.7" -Notes "이번 업데이트 내용"
```

Android/Windows 릴리즈 빌드, 설치 프로그램 컴파일, `server/releases/`로 복사, `version.json` 작성까지
전부 자동으로 처리합니다. 서버는 재시작 없이 바로 새 버전을 알려주기 시작합니다.

받는 쪽은: Windows는 `messenger-setup.exe`를 받아 실행하면 설치 마법사가 뜨고, Android는 apk를
받아서 탭하면 설치 화면으로 넘어갑니다(둘 다 "출처를 알 수 없는 앱/파일 실행" 확인이 한 번은
필요합니다 — 스토어를 거치지 않는 배포 방식의 한계).

### 개발 PC → 운영(서버) PC 코드 업데이트

이 저장소를 Git 원격(GitHub 등)에 올려두고, 서버 PC에서는 clone 후 아래를 반복합니다. **순서가
중요합니다** — 새 코드가 새 스키마를 기대하는 상태로 먼저 뜨면 오류가 납니다:

```powershell
cd server
git pull
npm install          # package.json이 바뀌었을 때만
npm run db:migrate   # server/src/db/schema.js가 바뀌었을 때만(=drizzle/에 새 마이그레이션 파일이 추가됐을 때)
npm run pm2:restart  # 또는 pm2 없이 직접 재시작
```

`.env`, `certs/`, `uploads/`, `releases/`, `firebase-service-account.json`은 모두 `.gitignore`에
있어 `git pull`이 건드리지 않습니다 — 서버를 처음 새 PC에 놓을 때는 이 파일들을 별도로(USB, 압축
파일 등으로) 옮겨야 합니다.

## 서버/DB 백업 · 이전 · 초기화

### 백업

```powershell
"C:\Program Files\PostgreSQL\<버전>\bin\pg_dump.exe" -U messenger_app -d messenger -F c -f messenger_backup.dump
```

`server/certs/`, `server/uploads/`, `server/.env`, `server/firebase-service-account.json`,
`server/releases/`도 Git에 없는 실데이터이므로 함께 백업하세요(예: 압축해서 통째로).

### 다른 PC로 이전

1. 새 PC에 [개발 환경 준비](#개발-환경-준비)대로 Node.js/PostgreSQL 설치, 저장소 clone
2. [PostgreSQL 설정 및 마이그레이션](#postgresql-설정-및-마이그레이션)대로 계정/DB 생성
3. 덤프 복원:
   ```powershell
   "C:\Program Files\PostgreSQL\<버전>\bin\pg_restore.exe" -U messenger_app -d messenger --clean --if-exists messenger_backup.dump
   ```
4. 백업해둔 `.env`, `certs/`, `uploads/`, `firebase-service-account.json`, `releases/`를 그대로
   복사해 넣기 — **특히 `certs/`를 그대로 옮기면 클라이언트를 재빌드하지 않아도 됩니다**(인증서가
   바뀌지 않으므로). 새로 생성하게 두면(=옮기지 않으면) 클라이언트가 페어링을 다시 받아야 합니다.
5. `npm install` → `npm run db:migrate`(복원한 덤프가 이미 최신 스키마라면 변경 없음으로 끝남) →
   서버 시작

### DB 데이터 전부 삭제(테이블 구조는 유지)

```powershell
psql -U messenger_app -d messenger -c "TRUNCATE TABLE secret_rekeys, secret_sessions, message_comments, messages, room_members, devices, rooms, users RESTART IDENTITY CASCADE;"
```

첨부파일 실물(`server/uploads/`)은 이 명령으로 지워지지 않습니다 — 필요하면 폴더도 따로 비우세요.

## 보안 및 암호화

- **전송 구간**: 서버가 스스로 만든 자체 서명 TLS 인증서(RSA 2048, 유효기간 10년)를 쓰고,
  클라이언트는 공인 CA 목록이 아니라 **그 인증서 하나만** 신뢰하도록 고정(핀닝)합니다
  (`client/lib/services/pinned_tls.dart`). 인증서는 앱 빌드에 내장되거나(`assets/server_cert.pem`),
  페어링 코드로 나중에 동적으로 받아 로컬에 저장됩니다.
- **비밀번호**: bcrypt로 해시 저장(원문 저장 안 함).
- **인증 토큰**: JWT AccessToken(1시간)/RefreshToken(30일). 비밀번호 변경/탈퇴/로그아웃 시
  `tokenVersion`을 올려 기존에 발급된 모든 토큰을 무효화합니다.
- **DB 저장 민감 필드**: 이메일은 AES-256-GCM으로 암호화 저장(`emailEnc`)하고, "정확히 일치하는지"
  조회할 때는 별도의 HMAC-SHA256 해시(`emailLookup`)를 씁니다 — 이 해시만으로는 원문을 복원할 수
  없습니다(`server/src/crypto.js`).
- **보안 질문 답변**: 이메일과 별개로 bcrypt 해시 저장.
- **첨부파일 다운로드**: 고정 공개 경로가 없고, 요청마다 짧게 만료(최대 2시간)되는 서명 링크
  (`/files/<token>`)만 발급됩니다(`server/src/upload.js`).
- **비밀 대화(E2EE)**: 기기별 X25519(키 교환)/Ed25519(서명) 키쌍을 클라이언트에서 생성하고 개인키는
  `flutter_secure_storage`에만 저장 — 서버에는 절대 오지 않습니다. 임시 공개키는 기기 장기 신원키로
  서명해서 서버가 키를 바꿔치기하는 중간자 공격을 막습니다. 서버 DB(`secret_sessions`/`secret_rekeys`)에는
  공개키·서명·상태값만 저장되고, 실제 대화 내용/공유비밀/체인키는 전혀 저장되지 않습니다.
- **비밀 대화 자동 삭제**: 만료된 메시지는 DB 행뿐 아니라 첨부파일 실물까지 완전히 삭제합니다
  (`server/src/secretExpiry.js`, 5초 간격 스윕).
- **탈퇴 계정 보존기간**: 탈퇴 후 1년이 지나면 그 계정이 보낸 메시지를 자동 파기합니다(첨부파일은
  유지 — `server/src/retention.js`).

## Git 관리 규칙

`.gitignore`(루트/`server/`/`client/`/`client/android/`)에 의해 아래 항목은 커밋되지 않습니다 —
**절대 GitHub 등 원격에 올리면 안 되는 파일들**입니다:

- `server/.env`, `server/.jwt-secret`, `server/.db-encryption-key`
- `server/certs/`(TLS 개인키 포함)
- `server/firebase-service-account.json`(FCM 발송용 Firebase 관리자 키)
- `server/uploads/`, `server/releases/`, `server/db.json`
- `client/android/key.properties`, `client/android/**/*.jks`, `client/android/**/*.keystore`
- 그 외 각 플랫폼의 표준 빌드 산출물(`build/`, `.dart_tool/` 등)

⚠️ **현재 상태 점검 결과**: `client/android/app/google-services.json`이 `.gitignore`에 없어서
**현재 저장소에 커밋되어 있습니다**. Firebase Android 클라이언트 설정 파일은 앱 배포물(APK) 안에도
어차피 포함되는 값이라 서비스 계정 키만큼 치명적인 비밀은 아니지만, 프로젝트 식별자/API 키가
그대로 노출되므로 보통은 커밋하지 않는 편을 권장합니다. 저장소를 공개(public)로 전환하거나 다른
사람과 공유할 계획이 있다면, `client/android/.gitignore`에 `google-services.json`을 추가하고
`git rm --cached client/android/app/google-services.json`으로 추적을 해제하는 것을 고려하세요.

## 문제 해결

| 증상 | 원인 / 조치 |
|---|---|
| 클라이언트에서 서버 연결이 안 됨(TLS 오류) | 서버 PC의 LAN IP가 바뀌었거나 인증서가 재생성됨 → 서버 콘솔에 `pair` 입력 후 클라이언트에서 새 코드로 다시 페어링 |
| `flutter build windows`가 심볼릭 링크 오류로 실패 | Windows 개발자 모드가 꺼져 있음 → `start ms-settings:developers`로 켜기 |
| Android 기기에 apk 설치 시 "signatures do not match" | 기존 설치본과 서명이 다름(예: keystore 없이 디버그로 빌드) → [Android 릴리즈 서명](#android-릴리즈-서명)대로 `key.properties` 설정 후 재빌드, 또는 기존 앱 삭제 후 재설치 |
| FCM 알림이 전혀 안 옴 | ① `server/firebase-service-account.json` 존재 확인(서버 시작 로그에 경고가 찍힘) ② `client/android/app/google-services.json`이 실제 빌드에 포함됐는지 확인 ③ Windows 클라이언트는 애초에 FCM 미지원(정상) |
| `npm run db:migrate` 실패 | `DATABASE_URL`이 올바른지, PostgreSQL 서비스가 떠있는지 확인. 스키마 충돌이면 `server/drizzle/meta/`의 마이그레이션 이력과 실제 DB 상태가 어긋난 것 — 백업 후 [DB 데이터 전부 삭제](#db-데이터-전부-삭제테이블-구조는-유지) 후 재적용을 고려 |
| pm2로 띄운 뒤 페어링 코드를 못 받음 | pm2는 콘솔 입력을 못 받음 → 서버가 떠있는 같은 PC에서 `npm run pair` 실행 |
| 첨부파일이 업로드/다운로드 안 됨(네트워크 드라이브 사용 시) | `UPLOADS_DIR`로 지정한 UNC 경로/네트워크 드라이브가 서버 PC에서 항상 접근 가능한지 확인 |
