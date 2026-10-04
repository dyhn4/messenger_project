import 'dotenv/config';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseExternalAddress } from './externalAddress.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const rootDir = path.join(__dirname, '..');

/**
 * 환경변수(.env 또는 실제 OS 환경변수)에 값이 있으면 그걸 쓰고, 없으면 로컬 파일에 저장된
 * 값을 재사용하고, 그마저 없으면 새로 랜덤하게 만들어서 파일에 저장해둔다(다음 실행부터는
 * 그 값을 계속 씀). 소스 코드에 비밀값을 하드코딩하지 않기 위한 절충안 — 진짜 비밀 저장소
 * (Vault, AWS Secrets Manager 등)를 쓸 상황이 되면 이 함수 내부만 바꾸면 된다.
 */
function resolveSecret(envName, fileName, byteLength) {
  if (process.env[envName]) return process.env[envName];

  const filePath = path.join(rootDir, fileName);
  if (fs.existsSync(filePath)) {
    return fs.readFileSync(filePath, 'utf8').trim();
  }

  const generated = crypto.randomBytes(byteLength).toString('hex');
  fs.writeFileSync(filePath, generated, { mode: 0o600 });
  console.log(`[config] ${envName}이 설정되어 있지 않아 ${fileName}에 새 값을 생성했습니다. 이 파일은 커밋/공유하지 마세요.`);
  return generated;
}

/**
 * resolveSecret과 달리 **없으면 만들지 않고 null을 돌려준다** — 그 값이 있어야만 켜지는
 * 선택 기능(화상회의 등)에 쓴다. 자동 생성해버리면 "설정된 것처럼" 보이지만 짝이 되는
 * 외부 구성요소(LiveKit 서버)는 다른 비밀값을 갖고 있어서 오히려 원인을 찾기 어려워진다.
 */
function optionalSecret(envName, fileName) {
  if (process.env[envName]) return process.env[envName];
  const filePath = path.join(rootDir, fileName);
  if (fs.existsSync(filePath)) return fs.readFileSync(filePath, 'utf8').trim();
  return null;
}

export const PORT = process.env.PORT || 3000;

// 새 기기 페어링용 평문 HTTP 부트스트랩 서버 포트(pairing.js). 기본값은 메인 포트+1.
export const PAIRING_PORT = Number(process.env.PAIRING_PORT) || Number(PORT) + 1;

// 사내망 밖(LTE/5G)에서 접속할 주소(DDNS 도메인 또는 공인 IP, 포트포워딩 필요). 안 정하면
// null — 지금처럼 사내망에서만 쓴다. 형식·쓰임새는 externalAddress.js 참고. 형식이 잘못됐으면
// 서버(서비스)가 통째로 안 뜨는 것보다는 외부 접속만 끈 채로 뜨고 콘솔에 크게 알린다.
export const EXTERNAL_ADDRESS = (() => {
  try {
    return parseExternalAddress(process.env.EXTERNAL_ADDRESS, PORT);
  } catch (e) {
    console.error(`[config] ⚠ ${e.message} — 외부 접속 없이 사내망 전용으로 실행합니다.`);
    return null;
  }
})();

// 첨부파일 저장 위치. 지정 안 하면 서버 폴더 밑 uploads/를 그대로 쓴다. UNC 경로
// (\\다른PC\공유폴더\uploads)나 매핑된 네트워크 드라이브(Z:\uploads)도 그대로 쓸 수 있다 —
// 단 그 경로가 항상 접근 가능해야 첨부파일 업로드/다운로드가 된다(upload.js 참고).
export const UPLOADS_DIR = process.env.UPLOADS_DIR || path.join(rootDir, 'uploads');

// JWT 서명용 비밀키.
export const JWT_SECRET = resolveSecret('JWT_SECRET', '.jwt-secret', 48);

// DB에 저장하는 민감 필드(이메일 등) 암호화용 키. 32바이트(AES-256) 고정 길이가 필요하다.
export const DB_ENCRYPTION_KEY = resolveSecret('DB_ENCRYPTION_KEY', '.db-encryption-key', 32);

/**
 * 화상회의(LiveKit SFU) 연동값 — 설치 프로그램이 LiveKit 서비스를 등록하면서 같은 값을
 * livekit.yaml과 여기(.env/.livekit-secret)에 함께 심는다. **비밀값이 없으면 화상회의 기능만
 * 조용히 꺼진다**(푸시 알림이 서비스 계정 없이도 서버가 정상 기동하는 것과 같은 방식) —
 * 그래야 LiveKit을 아직 안 깐 기존 서버도 업데이트 후 그대로 돌아간다.
 *
 * URL은 보통 설정하지 않는다: 클라이언트가 접속한 바로 그 호스트의 LIVEKIT_PORT로 만들어
 * 보내주면 되기 때문이다(calls.js). LiveKit을 다른 장비에 띄웠을 때만 명시한다.
 */
export const LIVEKIT_API_KEY = process.env.LIVEKIT_API_KEY || 'tangotalk';
export const LIVEKIT_API_SECRET = optionalSecret('LIVEKIT_API_SECRET', '.livekit-secret');
export const LIVEKIT_PORT = Number(process.env.LIVEKIT_PORT) || 7880;
export const LIVEKIT_URL = process.env.LIVEKIT_URL || null;
