# messenger_project — Flutter(PC+Android) 메신저

실시간 채팅, 파일 전송, 이미지 전송/뷰어를 목표로 한 개인용 메신저입니다.

## 구조

```
messenger_project/
  client/   Flutter 앱 (Android + Windows)
  server/   Node.js 백엔드 (Express + Socket.io)
```

| | 역할 |
|---|---|
| `client/` | 화면, 이미지/파일 선택, 채팅 UI, 이미지 뷰어 |
| `server/` | 로그인(JWT), 실시간 메시지 브로드캐스트(Socket.io), 파일 업로드/다운로드(Multer) |

애초 계획은 인증/채팅에 Firebase를 쓰는 것이었지만, **Firebase는 Windows 데스크톱을 지원하지 않아서**
(Android/iOS/macOS/Web만 지원) 인증·채팅·파일을 전부 이 Node.js 서버 하나로 통합했습니다.
백엔드가 하나뿐이라 관리가 오히려 더 간단합니다.

## 1. 서버 실행 (PC)

Node.js가 설치되어 있지 않다면 먼저 설치하세요: https://nodejs.org (LTS 버전)
설치 후 새 터미널을 열어 `node --version`이 뜨는지 확인합니다.

채팅 데이터는 PostgreSQL에 저장합니다. PostgreSQL이 설치되어 있어야 하고, 이 앱 전용 데이터베이스/
계정을 하나 만들어둬야 합니다(슈퍼유저로 한 번만):

```
psql -U postgres -c "CREATE USER messenger_app WITH PASSWORD '원하는_비밀번호';"
psql -U postgres -c "CREATE DATABASE messenger OWNER messenger_app;"
```

그다음 `server/.env`를 만들고(`server/.env.example` 참고) `DATABASE_URL`을 채웁니다:

```
DATABASE_URL=postgres://messenger_app:원하는_비밀번호@localhost:5432/messenger
```

```
cd server
npm install
npm run db:generate   # 스키마(src/db/schema.js) 기준으로 마이그레이션 SQL 생성 — 스키마가 바뀔 때마다
npm run db:migrate    # 실제 데이터베이스에 적용 — 처음 실행 전 필수
npm start
```

실행하면 콘솔에 이렇게 접속 주소가 찍힙니다. 이 주소를 클라이언트 앱의 "서버 연결" 화면에 그대로 입력하세요.

```
메신저 서버 실행 중 (HTTPS, 포트 3000)
같은 와이파이의 다른 기기에서 접속할 주소:
  https://192.168.0.62:3000
```

- PC 방화벽이 처음 실행 시 "네트워크 접근 허용" 팝업을 띄우면 허용해야 안드로이드 기기에서 접속됩니다.
- 안드로이드 기기와 PC가 **같은 와이파이망**에 있어야 합니다. 다른 네트워크(LTE 등)에서 쓰려면 공유기 포트포워딩 + 고정 IP(또는 DDNS)가 추가로 필요합니다.
- 업로드 파일은 `server/uploads/`에 저장됩니다. `.gitignore`에 들어있어 git에는 안 올라갑니다.

## 2. 클라이언트 실행

**Windows 데스크톱**으로 처음 빌드하려면 개발자 모드가 필요합니다 (심볼릭 링크 지원):
```
start ms-settings:developers
```
켠 뒤 아래 명령 실행:

```
cd client
flutter run -d windows
```

**Android**는 기기를 USB로 연결하고:
```
cd client
flutter run
```

앱을 처음 켜면:
1. **서버 연결** — 1번에서 확인한 주소 입력 (예: `http://192.168.0.62:3000`)
2. **회원가입/로그인** — 아이디/비밀번호는 이 서버에만 저장됩니다 (다른 서비스와 연동 없음)
3. **채팅** — 텍스트, 이미지(📷), 파일(📎) 전송. 이미지를 탭하면 확대/축소 뷰어가 열립니다.

## 지금 구조로 미리 알아둘 것

**단일 채팅방입니다.** 1:1 DM이나 여러 채팅방이 필요하면 `server/src/socket.js`에서
메시지를 room 단위로 나누고, `client/lib/services/session.dart`에 현재 room 개념을 추가해야 합니다.

**비밀번호는 이 서버 안에서만 의미가 있습니다.** JWT 서명 키(`server/src/config.js`의
`JWT_SECRET`)는 개발용 기본값이 박혀있습니다. 집 안에서만 쓸 거면 문제없지만, 외부에 노출할
계획이면 환경변수로 반드시 바꾸세요.

**메시지 저장소가 JSON 파일입니다.** `lowdb`로 `server/db.json`에 통째로 읽고 씁니다. 개인용
소규모 트래픽엔 충분하지만, 메시지가 아주 많아지면 SQLite 정도로 옮기는 걸 고려하세요.

**파일 업로드 용량 제한은 200MB**입니다 (`server/src/upload.js`의 `limits.fileSize`). 필요하면 조절하세요.

**서버 주소가 바뀌면** (공유기 재시작 등으로 PC의 로컬 IP가 바뀌는 경우) 앱에서 재로그인 없이
다시 넣을 방법이 아직 없습니다. 지금은 앱 데이터를 지우고 서버 주소 입력부터 다시 해야 합니다.
IP가 자주 바뀌어 불편하면 공유기에서 그 PC에 고정 IP를 할당해두는 걸 추천합니다.

## 다음에 붙이면 좋을 것

- 채팅방 목록 / 1:1 대화
- 읽음 표시, 타이핑 표시
- 메시지 페이지네이션(지금은 최근 50개만 불러옵니다)
- 이미지 업로드 시 썸네일 미리 압축(현재는 원본 그대로 전송)
- 서버 주소를 앱 설정 화면에서 재입력할 수 있게 하기
