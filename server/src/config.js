import 'dotenv/config';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseExternalAddress } from './externalAddress.js';
import { readWebTlsConfig } from './webTlsConfig.js';

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

// 자체 메일 서버(회사 도메인으로 직접 받기 — localMailServer.js)가 받은 메일의 원문(.eml)을 두는 곳. 계정마다 하위 폴더.
export const MAIL_STORE_DIR = process.env.MAIL_STORE_DIR || path.join(rootDir, 'mailstore');

// 웹 앱(아이폰 등 앱이 없는 기기용) 빌드 결과물 폴더 — client에서 `flutter build web`으로 만든
// build/web의 내용을 여기에 넣으면 서버 주소(https://서버:3000/)로 바로 열린다. 폴더가 없으면 웹
// 앱만 꺼진다. 웹 앱은 브라우저가 TLS를 검증하므로 공인 인증서가 있어야 제대로 쓸 수 있다 — 아래
// WEB_DOMAIN을 정하면 그 도메인으로 공인 인증서(Let's Encrypt)가 걸린 웹 전용 포트가 따로 열린다.
export const WEB_DIR = process.env.WEB_DIR || path.join(rootDir, 'web');

// 웹 앱 전용 HTTPS 포트(webTls.js) — WEB_DOMAIN(예: xxx.iptime.org)을 정하면 같은 앱을 WEB_HTTPS_PORT(기본 443)에서 Let's
// Encrypt 인증서로 한 번 더 열고, 인증서를 자동으로 받고 갱신한다(확인용 HTTP 포트 ACME_HTTP_PORT, 기본 80 — 0이면 끔). 비워 두면
// 이 기능 전체가 꺼지고 아무것도 달라지지 않는다. 메인 포트(PORT — 앱이 핀닝한 자체 서명 인증서)는 그대로다. 값이 잘못됐으면
// 서버를 못 뜨게 하는 대신 이 기능만 끄거나(도메인·웹 포트) 그 값만 빼고(나머지) 콘솔에 크게 알린다.
const webTlsConfig = readWebTlsConfig(process.env, { port: PORT, pairingPort: PAIRING_PORT });
for (const warning of webTlsConfig.warnings) console.warn(`[config] ⚠ ${warning}`);
if (webTlsConfig.error) console.error(`[config] ⚠ ${webTlsConfig.error} — 웹 앱 전용 포트(WEB_DOMAIN) 없이 실행합니다.`);
export const WEB_DOMAIN = webTlsConfig.domain;
export const WEB_HTTPS_PORT = webTlsConfig.httpsPort;
export const ACME_HTTP_PORT = webTlsConfig.httpPort;
export const ACME_EMAIL = webTlsConfig.email;
// 1이면 Let's Encrypt 시험용(staging) 디렉터리 — 브라우저가 신뢰하지 않는 인증서지만 발급 한도 걱정 없이 포트포워딩을 확인할 수 있다.
export const ACME_STAGING = webTlsConfig.staging;
// WEB_DOMAIN을 적었는데 잘못돼서 꺼졌을 때의 이유(관리자 콘솔 상태에 보여 준다). 정상이거나 안 적었으면 null.
export const WEB_TLS_CONFIG_ERROR = webTlsConfig.error;

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

/**
 * 화상회의 녹화(LiveKit Egress — callRecording.js). Egress는 Docker 전용이라(Windows 설치 프로그램에 넣을 수 없다) 관리자가 따로
 * 띄우고(README "화상회의 녹화·회의록") 녹화 파일이 떨어지는 폴더를 이 서버와 함께 쓴다:
 *  - CALL_RECORDING_DIR: 이 서버에서 본 그 폴더(예: D:\tangotalk\recordings). **이 값이 있어야 녹화가 켜진다**(없으면 단추도 안 보인다).
 *  - CALL_RECORDING_EGRESS_DIR: Egress 컨테이너 안에서 본 같은 폴더(docker의 -v ...:/out — 기본 /out).
 *  - CALL_RECORDING_MAX_MINUTES: 한 번 녹화의 최대 길이(분, 기본 240 — 넘으면 저절로 멈춘다).
 */
export const CALL_RECORDING_DIR = process.env.CALL_RECORDING_DIR || null;
export const CALL_RECORDING_EGRESS_DIR = (process.env.CALL_RECORDING_EGRESS_DIR || '/out').replace(/[\\/]+$/, '');
export const CALL_RECORDING_MAX_MINUTES = Math.max(1, Number(process.env.CALL_RECORDING_MAX_MINUTES) || 240);

/**
 * 자동 회의록(callMinutes.js) — 녹음을 받아쓰고(음성 인식) 요약한다. 둘 다 바깥 서비스라 관리자가 정했을 때만 켜진다.
 *  - 받아쓰기: OpenAI 호환 `/audio/transcriptions` API. CALL_TRANSCRIBE_URL은 그 앞까지의 주소(예: https://api.openai.com/v1, 사내에
 *    띄운 faster-whisper·whisper.cpp 서버의 http://10.0.0.5:8000/v1). 키·모델·언어는 그 서비스에 맞게. **URL이 있어야 회의록이 켜진다.**
 *  - 요약: CALL_SUMMARY_URL(OpenAI 호환 `/chat/completions` — 사내 LLM 서버 등)이 있으면 그것을, 없고 ANTHROPIC_API_KEY가 있으면 Claude를
 *    쓴다. 둘 다 없으면 받아쓰기만 남긴다. 모델은 CALL_SUMMARY_MODEL(Claude 기본 claude-opus-5-5).
 */
export const CALL_TRANSCRIBE_URL = (process.env.CALL_TRANSCRIBE_URL || '').replace(/\/+$/, '') || null;
export const CALL_TRANSCRIBE_API_KEY = process.env.CALL_TRANSCRIBE_API_KEY || null;
export const CALL_TRANSCRIBE_MODEL = process.env.CALL_TRANSCRIBE_MODEL || 'whisper-1';
export const CALL_TRANSCRIBE_LANGUAGE = process.env.CALL_TRANSCRIBE_LANGUAGE ?? 'ko';
export const CALL_SUMMARY_URL = (process.env.CALL_SUMMARY_URL || '').replace(/\/+$/, '') || null;
export const CALL_SUMMARY_API_KEY = process.env.CALL_SUMMARY_API_KEY || null;
export const ANTHROPIC_API_KEY = process.env.ANTHROPIC_API_KEY || null;
export const CALL_SUMMARY_MODEL = process.env.CALL_SUMMARY_MODEL || null;

/**
 * 영수증 읽기(receiptOcr.js — 지출 결재·법인카드의 영수증 사진에서 가맹점·날짜·금액·승인번호를 읽는다). 영수증 사진을 바깥 서비스로 보내므로
 * **관리자가 RECEIPT_OCR_ENGINE을 정했을 때만** 켜진다(ANTHROPIC_API_KEY가 회의록용으로 있어도 저절로 켜지지 않는다).
 *  - 'claude': Claude(비전 + 구조화 출력). 키는 RECEIPT_OCR_API_KEY, 없으면 ANTHROPIC_API_KEY. 모델은 RECEIPT_OCR_MODEL(기본 claude-opus-5-5).
 *  - 'openai': OpenAI 호환 `/chat/completions`의 비전 모델(사내에 띄운 vLLM·Ollama의 Qwen2.5-VL 등 — 영수증을 회사 밖으로 내보내지 않으려면).
 *    RECEIPT_OCR_URL은 그 앞까지의 주소(예: http://10.0.0.5:8000/v1), RECEIPT_OCR_MODEL은 꼭, 키는 필요하면.
 *  - 'clova': 네이버 클라우드 CLOVA OCR의 영수증 특화 모델. RECEIPT_OCR_URL은 도메인의 영수증 호출 주소(APIGW Invoke URL — …/document/receipt),
 *    RECEIPT_OCR_API_KEY는 Secret Key(X-OCR-SECRET).
 */
export const RECEIPT_OCR_ENGINE = ['claude', 'openai', 'clova'].includes(String(process.env.RECEIPT_OCR_ENGINE ?? '').trim().toLowerCase())
  ? String(process.env.RECEIPT_OCR_ENGINE).trim().toLowerCase()
  : null;
export const RECEIPT_OCR_URL = (process.env.RECEIPT_OCR_URL || '').replace(/\/+$/, '') || null;
export const RECEIPT_OCR_API_KEY = process.env.RECEIPT_OCR_API_KEY || null;
export const RECEIPT_OCR_MODEL = process.env.RECEIPT_OCR_MODEL || null;
