import crypto from 'node:crypto';
import { DB_ENCRYPTION_KEY } from './config.js';

const ALGO = 'aes-256-gcm';
const key = Buffer.from(DB_ENCRYPTION_KEY, 'hex');

/** DB에 저장할 값으로 암호화한다(매번 다른 결과 — IV가 랜덤). 조회에는 쓸 수 없다. */
export function encryptField(plaintext) {
  if (plaintext == null) return null;
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv(ALGO, key, iv);
  const ciphertext = Buffer.concat([cipher.update(String(plaintext), 'utf8'), cipher.final()]);
  const authTag = cipher.getAuthTag();
  return Buffer.concat([iv, authTag, ciphertext]).toString('base64');
}

/** encryptField로 암호화된 값을 원래 문자열로 되돌린다. */
export function decryptField(stored) {
  if (stored == null) return null;
  const raw = Buffer.from(stored, 'base64');
  const iv = raw.subarray(0, 12);
  const authTag = raw.subarray(12, 28);
  const ciphertext = raw.subarray(28);
  const decipher = crypto.createDecipheriv(ALGO, key, iv);
  decipher.setAuthTag(authTag);
  return Buffer.concat([decipher.update(ciphertext), decipher.final()]).toString('utf8');
}

/**
 * 암호화된 필드를 "정확히 일치하는지"로 조회하는 데 쓰는 해시(HMAC-SHA256, 결정적).
 * 같은 입력이면 항상 같은 값이 나오지만, 이 값만으로 원문을 복원할 수는 없다.
 * 대소문자/앞뒤 공백 차이로 조회가 실패하지 않도록 정규화한 뒤 해시한다.
 */
export function lookupHash(plaintext) {
  if (plaintext == null) return null;
  return crypto.createHmac('sha256', key).update(String(plaintext).trim().toLowerCase()).digest('hex');
}
