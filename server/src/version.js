import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Router } from 'express';

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

/** 서버 설치 프로그램이 같이 깔아주는 "도움말"(README.html, 저장소 루트 README.md를 정적
 * HTML로 미리 변환해둔 것 — server/certs.js 상단 주석·build_server_installer.ps1 참고)을
 * 클라이언트 앱에서도 볼 수 있게 한다. 앱의 계정 메뉴 "도움말"(서버 운영자 전용)이 이 주소를
 * 기본 브라우저로 연다 — 파일이 서버 PC 로컬 디스크에만 있어서, 앱이 서버와 다른 PC에서
 * 실행 중이어도 보려면 이렇게 서버를 거쳐야 한다. /version과 같은 성격이라 인증 없이 공개한다.
 * 설치된 배포본은 {app}/README.html(server/의 바로 위), 이 저장소를 그대로 켠 개발 환경은
 * server/installer/README.html에 있어서 둘 다 시도한다. */
versionRouter.get('/help', (req, res) => {
  const candidates = [
    path.join(__dirname, '..', '..', 'README.html'),
    path.join(__dirname, '..', 'installer', 'README.html'),
  ];
  const filePath = candidates.find((p) => fs.existsSync(p));
  if (!filePath) return res.status(404).json({ error: '도움말 문서를 찾을 수 없습니다.' });
  res.sendFile(filePath);
});

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
