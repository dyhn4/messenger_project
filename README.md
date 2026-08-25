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
- 업로드 파일은 기본적으로 `server/uploads/`에 저장됩니다. `.gitignore`에 들어있어 git에는 안 올라갑니다.
  다른 PC의 공유 폴더에 저장하려면 `.env`에 `UPLOADS_DIR`을 UNC 경로나 매핑된 네트워크 드라이브로
  지정하세요(`server/.env.example` 참고) — 그 경로가 항상 접근 가능해야 첨부파일을 올리고 받을 수
  있습니다.

### pm2로 서버 운영하기

`node src/index.js`를 터미널에 직접 띄워두는 대신, [pm2](https://pm2.keymetrics.io/)로 관리하면
크래시 시 자동 재시작되고, 업데이트할 때도 재시작 명령 한 줄로 끝납니다.

```
npm install -g pm2        # 최초 1회
npm run pm2:start         # 서버 시작 (= pm2 start ecosystem.config.cjs)
npm run pm2:logs          # 로그 보기
npm run pm2:restart       # 재시작 (업데이트 후)
npm run pm2:stop          # 정지
```

Windows 재부팅 시 자동으로 다시 시작되게 하려면 `pm2-windows-startup` 패키지가 필요합니다
(pm2 공식 `pm2 startup`은 Linux 전용):
```
npm install -g pm2-windows-startup
pm2-startup install
pm2 save                  # 지금 떠있는 프로세스 목록을 저장 — 재부팅 후 이걸 복원함
```

**주의**: pm2로 띄우면 콘솔 입력을 받을 수 없어서, 새 기기 페어링 코드는 `npm start`로 직접 띄웠을 때처럼
콘솔에 "pair"를 입력하는 방식이 안 됩니다. 대신 서버가 떠있는 같은 PC에서 `npm run pair`를 실행하세요
(pairing.js의 `/admin/generate`를 호출 — 이 PC 안에서 온 요청만 허용해서 외부에는 안 열려있습니다).

### 개발 PC → 운영 PC 업데이트 배포

이 저장소를 GitHub 같은 원격에 올려두고, 운영 PC에서는 clone 후 다음을 반복합니다:
```
git pull
npm install          # package.json이 바뀌었을 때만
npm run db:migrate   # schema.js가 바뀌었을 때만
npm run pm2:restart  # 또는 pm2 없이 직접 재시작
```
`.env`, `certs/`, `uploads/`, `releases/`는 `.gitignore`에 있어서 pull해도 안 건드립니다.

### Windows 설치 프로그램 (Inno Setup)

`flutter build windows --release`는 `client.exe`와 dll들이 흩어진 폴더를 만들 뿐이라, 그 자체로
배포하기는 불편합니다. 대신 [Inno Setup](https://jrsoftware.org/isinfo.php)으로 하나의 설치
프로그램(`messenger-setup.exe`)을 만듭니다 — 관리자 권한 없이 현재 계정에 설치되고, 시작 메뉴/바탕화면
바로가기와 제거 프로그램까지 자동으로 생깁니다. 스크립트는 `client/windows/installer/messenger.iss`.

최초 1회, Inno Setup 설치: `winget install JRSoftware.InnoSetup`

### Android 릴리즈 서명 (keystore)

Android는 release 빌드에 서명이 필요합니다 — 서명 없이는 배포는커녕 기존 설치본 위에 업데이트 설치도
안 됩니다. 최초 1회만 만들면 계속 재사용합니다(**꼭 안전하게 보관** — 잃어버리면 이후 업데이트를 기존
설치본에 덮어씌울 수 없고 사용자들이 재설치해야 합니다):

```
& "C:\Program Files\Android Studio\jbr\bin\keytool.exe" -genkey -v -keystore client\android\upload-keystore.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload
```

그다음 `client/android/key.properties`를 만듭니다(`.gitignore`에 있어 git엔 안 올라감):
```
storePassword=<keystore 비밀번호>
keyPassword=<키 비밀번호>
keyAlias=upload
storeFile=../upload-keystore.jks
```
이 파일이 없으면 release 빌드는 디버그 키로 자동 폴백합니다(로컬 테스트용 `flutter run --release`는
문제없이 되지만, 그 apk는 배포하면 안 됩니다 — 서명이 기기마다 달라질 수 있어 업데이트가 깨집니다).

### 클라이언트 버전 체크/배포 (`releases/`)

클라이언트는 앱을 시작할 때마다 서버의 `/version`을 확인해서, 서버에 더 최신 버전이 올라와 있으면
화면에 배너로 알려줍니다. 새 버전을 배포하려면 `client/pubspec.yaml`의 `version:`을 올린 뒤, 저장소
루트에서 한 번에:

```
.\publish_release.ps1 -Version "1.0.1" -Notes "이번 업데이트 내용"
```

Android/Windows 릴리즈 빌드, 설치 프로그램 컴파일, `server/releases/`로 복사, `version.json` 작성까지
전부 자동으로 처리합니다. 서버는 재시작 없이 바로 새 버전을 알려주기 시작합니다.

받는 쪽은: Windows는 `messenger-setup.exe`를 받아 실행하면 설치 마법사가 뜨고, Android는 apk를 받아서
탭하면 설치 화면으로 넘어갑니다(둘 다 "출처를 알 수 없는 앱/파일 실행" 확인 한 번은 필요합니다 — 스토어를
거치지 않는 배포 방식의 한계로, 완전 무터치 자동 설치는 아닙니다).

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
