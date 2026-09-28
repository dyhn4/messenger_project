import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import express, { Router } from 'express';
import jwt from 'jsonwebtoken';
import { JWT_SECRET } from './config.js';
import { findUserById } from './db/queries/users.js';
import { accountRole } from './permissions.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

/** 새 클라이언트 빌드를 배포할 때 이 폴더에 파일을 채워넣는다(루트의 publish_release.ps1이
 * 자동으로 해줌 — README 참고):
 * releases/version.json         { "version": "1.0.1", "notes": "..." }
 * releases/client-windows-setup.exe  (Inno Setup으로 만든 설치 프로그램)
 * releases/client-android.apk
 * git에는 안 올라간다(.gitignore) — 배포 파일은 각 서버 PC에 직접 둔다. */
export const releasesDir = path.join(__dirname, '..', 'releases');

function readVersionInfo() {
  const infoPath = path.join(releasesDir, 'version.json');
  if (!fs.existsSync(infoPath)) return null;
  try {
    // publish_release.ps1이 Windows PowerShell로 저장하면 UTF-8 BOM이 붙을 수 있어서
    // (-Encoding utf8이 5.1에서는 BOM 포함) JSON.parse 전에 제거해준다.
    const raw = fs.readFileSync(infoPath, 'utf8');
    return JSON.parse(raw.charCodeAt(0) === 0xfeff ? raw.slice(1) : raw);
  } catch {
    return null;
  }
}

/** 로그인 여부와 무관하게 확인할 수 있어야 하므로(앱 시작 직후에도 체크) 인증 없이 공개한다 —
 * /health와 같은 성격. 실제 설치 파일도 별도 인증 없이 받게 해서(presigned URL 방식과 달리
 * 만료 개념이 필요 없는 정적 배포 파일이므로) 앱을 처음 설치할 때도 받을 수 있게 한다. */
export const versionRouter = Router();

versionRouter.get('/version', (req, res) => {
  const info = readVersionInfo();
  res.json({ version: info?.version ?? null, notes: info?.notes ?? null });
});

versionRouter.get('/downloads/windows', (req, res) => {
  const filePath = path.join(releasesDir, 'client-windows-setup.exe');
  if (!fs.existsSync(filePath)) return res.status(404).json({ error: '아직 배포된 Windows 빌드가 없습니다.' });
  res.download(filePath, 'TangoTalk-Setup.exe');
});

versionRouter.get('/downloads/android', (req, res) => {
  const filePath = path.join(releasesDir, 'client-android.apk');
  if (!fs.existsSync(filePath)) return res.status(404).json({ error: '아직 배포된 Android 빌드가 없습니다.' });
  res.download(filePath, 'TangoTalk.apk');
});

/** "메신저 설명서"(README.html, 저장소 루트 README.md를 정적 HTML로 미리 변환해둔 것 —
 * server/certs.js 상단 주석·build_server_installer.ps1 참고)는 서버 설치·운영 내용까지 담고
 * 있어서 관리자 이상(서버 운영자 또는 계정 등급 관리자)만 본다. 앱이 기본 브라우저로 여는
 * 주소라 Authorization 헤더를 실을 수 없으므로, 앱이 먼저 POST /api/help/manual-link(인증)로
 * 5분짜리 서명 토큰이 붙은 주소를 받아서 연다. 토큰을 확인한 뒤에는 같은 내용을 담은 쿠키를
 * /help 경로에만 심어서, 열어둔 탭을 나중에 새로고침해도 다시 막히지 않게 한다 — 쿠키든
 * 토큰이든 열 때마다 DB에서 등급을 다시 확인하므로 관리자에서 내려간 사람은 바로 못 본다.
 * 설치된 배포본은 {app}/README.html(server/의 바로 위), 이 저장소를 그대로 켠 개발 환경은
 * server/installer/README.html에 있어서 둘 다 시도한다. README.html은 스타일까지 한 파일에
 * 들어 있어(build-readme-html.mjs) 따로 서빙할 상대 경로 자산이 없다. */
const MANUAL_LINK_TTL_SECONDS = 5 * 60;
const MANUAL_COOKIE = 'tt_manual';
const MANUAL_COOKIE_TTL_SECONDS = 8 * 60 * 60; // 하루 근무 시간 정도 — 새로고침용

function canViewMessengerManual(user) {
  if (!user || user.deletedAt || user.suspendedAt) return false;
  return user.isServerAdmin === true || accountRole(user) === 'admin';
}

function signManualToken(userId, ttlSeconds) {
  return jwt.sign({ sub: userId, type: 'help-manual' }, JWT_SECRET, { expiresIn: ttlSeconds });
}

/** 서명·만료·용도를 확인하고 사용자 id를 돌려준다(아니면 null). */
function verifyManualToken(token) {
  if (!token) return null;
  try {
    const payload = jwt.verify(token, JWT_SECRET);
    return payload.type === 'help-manual' && typeof payload.sub === 'string' ? payload.sub : null;
  } catch {
    return null;
  }
}

function readCookie(req, name) {
  for (const part of (req.headers.cookie ?? '').split(';')) {
    const eq = part.indexOf('=');
    if (eq > 0 && part.slice(0, eq).trim() === name) {
      // 깨진 쿠키(같은 호스트의 다른 서비스가 심은 값 등)는 500 대신 "토큰 없음"으로 본다.
      try {
        return decodeURIComponent(part.slice(eq + 1).trim());
      } catch {
        return null;
      }
    }
  }
  return null;
}

/** 브라우저로 여는 주소라 JSON 대신 짧은 안내 페이지로 답한다. */
function sendHelpNotice(res, status, title, message) {
  res.status(status).type('html').send(`<!doctype html>
<html lang="ko"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>메신저 설명서</title>
<style>
:root{color-scheme:light dark;--bg:#f6f7fb;--card:#fff;--text:#1f2330;--muted:#5c6475;--line:#dfe3ec;--primary:#3f51b5}
@media (prefers-color-scheme:dark){:root{--bg:#14161c;--card:#1d2029;--text:#e7e9ef;--muted:#a3a9b8;--line:#2d313d;--primary:#9fa8ff}}
body{margin:0;background:var(--bg);color:var(--text);font-family:"Malgun Gothic","맑은 고딕","Apple SD Gothic Neo","Noto Sans KR",system-ui,sans-serif;line-height:1.7}
main{max-width:520px;margin:12vh auto;padding:28px 24px;background:var(--card);border:1px solid var(--line);border-radius:14px}
h1{font-size:1.25rem;margin:0 0 8px}p{margin:8px 0;color:var(--muted)}a{color:var(--primary);font-weight:600}
@media (max-width:600px){main{margin:16px;padding:22px 18px}}
</style></head>
<body><main><h1>${title}</h1><p>${message}</p><p><a href="/guide/">초보자용 도움말 보기</a></p></main></body></html>`);
}

versionRouter.get('/help', async (req, res) => {
  res.set('Cache-Control', 'no-store');
  const queryUserId = verifyManualToken(typeof req.query.t === 'string' ? req.query.t : null);
  const userId = queryUserId ?? verifyManualToken(readCookie(req, MANUAL_COOKIE));
  const user = userId ? await findUserById(userId) : null;
  if (!canViewMessengerManual(user)) {
    return sendHelpNotice(
      res,
      403,
      '메신저 설명서는 관리자만 볼 수 있습니다',
      '관리자라면 앱 오른쪽 위 ☰ 메뉴에서 <b>메신저 설명서</b>를 다시 눌러 주세요. 앱이 여는 주소는 5분 동안만 쓸 수 있습니다.',
    );
  }
  const candidates = [
    path.join(__dirname, '..', '..', 'README.html'),
    path.join(__dirname, '..', 'installer', 'README.html'),
  ];
  const filePath = candidates.find((p) => fs.existsSync(p));
  if (!filePath) {
    return sendHelpNotice(res, 404, '메신저 설명서를 찾을 수 없습니다', '서버 설치 폴더에 README.html이 없습니다. 서버를 다시 설치하거나 build_server_installer.ps1로 만들어 주세요.');
  }
  if (queryUserId) {
    // 주소의 토큰은 5분이면 끝나므로, 열어둔 탭을 새로고침해도 되게 /help에만 쓰이는 쿠키로 이어준다.
    res.cookie(MANUAL_COOKIE, signManualToken(userId, MANUAL_COOKIE_TTL_SECONDS), {
      path: '/help',
      httpOnly: true,
      secure: true,
      sameSite: 'strict',
      maxAge: MANUAL_COOKIE_TTL_SECONDS * 1000,
    });
  }
  res.sendFile(filePath);
});

/** 앱의 "메신저 설명서" 메뉴가 부르는 인증 API(index.js가 /api + requireAuth 뒤에 붙인다) —
 * 관리자 이상에게만 5분짜리 서명 토큰이 붙은 /help 주소(상대 경로)를 준다. 앱의 메뉴 표시
 * 조건(Session.canViewMessengerManual)과 같은 규칙을 서버가 다시 확인한다. */
export const helpApiRouter = Router();

helpApiRouter.post('/help/manual-link', async (req, res) => {
  const me = await findUserById(req.user.sub);
  if (!canViewMessengerManual(me)) {
    return res.status(403).json({ error: '메신저 설명서는 관리자만 볼 수 있습니다.' });
  }
  const token = signManualToken(me.id, MANUAL_LINK_TTL_SECONDS);
  res.json({ url: `/help?t=${encodeURIComponent(token)}`, expiresInSeconds: MANUAL_LINK_TTL_SECONDS });
});

/** 초보자용 "도움말"(server/guide/ — 메신저/프로젝트 이용법 정적 웹페이지와 스크린샷). 계정
 * 메뉴의 "도움말"이 누구에게나 보이므로 인증 없이 공개한다(비밀값 없는 정적 파일뿐). 설치
 * 프로그램·업데이트 zip이 server/ 통째로 담으므로 {app}/server/guide에 그대로 깔린다.
 * express.static은 /guide(끝 슬래시 없음)를 /guide/로 돌려보내서 상대 경로(guide.css,
 * images/...)가 제대로 풀리게 해준다. 같은 미들웨어를 평문 페어링 서버에도 붙일 수 있게
 * 따로 내보낸다(자체 서명 인증서 경고 없이 브라우저로 열도록 — pairing.js 주석 참고). */
export const guideDir = path.join(__dirname, '..', 'guide');
export const guideStatic = express.static(guideDir, { index: 'index.html', redirect: true });

/** 서버가 켜져 있는 동안 releases/version.json이 바뀌면(publish_release.ps1이 새 버전을
 * 배포할 때) 클라이언트가 앱을 재시작하지 않아도 곧바로 알 수 있도록, 인증 없는 소켓
 * 네임스페이스(/updates)로 새 버전을 즉시 알린다. 기본 네임스페이스는 socket.js의 io.use가
 * JWT를 요구해서 로그인 전(로그인 화면)엔 연결할 수 없는데, 로그인 화면에서도 이 알림이
 * 와야 해서 일부러 그 인증과 분리된 별도 네임스페이스로 둔다 — GET /version이 인증 없이
 * 공개된 것과 같은 성격.
 *
 * fs.watch는 한 번의 쓰기에도 이벤트가 여러 번 오거나 filename이 비어 올 수 있어(플랫폼마다
 * 다름) 디바운스하고, 실제로 버전 값이 바뀐 경우에만 내보낸다 — 그래야 같은 버전을 두 번
 * 브로드캐스트하거나, 파일이 쓰이는 도중(잠깐 비거나 깨진 JSON) 값을 잘못 읽는 걸 피한다. */
export function watchForVersionChanges(io) {
  const ns = io.of('/updates');
  let lastVersion = readVersionInfo()?.version ?? null;
  let timer = null;

  // 붙는 즉시 지금 배포돼 있는 버전을 그 소켓에만 알려준다. 아래 emit은 "바뀌는 그 순간"
  // 붙어 있던 앱에만 가기 때문에, 배포 시점에 PC가 절전이었거나 네트워크가 끊겨 있었거나,
  // 배포 뒤 서버가 재시작돼서(그러면 lastVersion이 새 버전으로 시작해 다시는 안 알린다)
  // 놓친 앱은 재시작 전까지 영영 모른다. 연결/재연결 때마다 현재 값을 다시 알려주면 그런
  // 경우가 저절로 복구된다 — 앱은 자기 버전보다 높을 때만 알약을 띄우므로 그냥 보내도 된다.
  ns.on('connection', (socket) => {
    const info = readVersionInfo();
    if (info?.version) {
      socket.emit('update:available', { version: info.version, notes: info.notes ?? null });
    }
  });

  fs.watch(releasesDir, (eventType, filename) => {
    if (filename && filename !== 'version.json') return;
    clearTimeout(timer);
    timer = setTimeout(() => {
      const info = readVersionInfo();
      if (info?.version && info.version !== lastVersion) {
        lastVersion = info.version;
        ns.emit('update:available', { version: info.version, notes: info.notes ?? null });
      }
    }, 300);
  });
}
