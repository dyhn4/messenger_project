import 'dotenv/config';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

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

export const PORT = process.env.PORT || 3000;

// JWT 서명용 비밀키.
export const JWT_SECRET = resolveSecret('JWT_SECRET', '.jwt-secret', 48);

// DB에 저장하는 민감 필드(이메일 등) 암호화용 키. 32바이트(AES-256) 고정 길이가 필요하다.
export const DB_ENCRYPTION_KEY = resolveSecret('DB_ENCRYPTION_KEY', '.db-encryption-key', 32);
