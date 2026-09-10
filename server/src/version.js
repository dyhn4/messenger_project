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
