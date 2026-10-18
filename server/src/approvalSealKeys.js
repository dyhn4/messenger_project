import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';
import { decryptField, encryptField } from './crypto.js';
import { getServerSettings, updateServerSettings } from './db/queries/serverSettings.js';
import { keyFingerprint } from './approvalSeal.js';
import { uploadFileNameOf, uploadsDir } from './upload.js';

/**
 * 결재 전자서명의 서버 키(approvalSeal.js) — Ed25519 키 한 쌍을 처음 서명할 때 만들어 서버 설정에 둔다(비밀 키는 DB 암호화 키로 암호화 —
 * crypto.js encryptField, 공개 키는 그대로). 그래서 DB만 고쳐서는 서명을 다시 만들 수 없다(.env의 DB_ENCRYPTION_KEY가 있어야 함). DB 백업에
 * 같이 들어가 복원해도 예전 서명을 검증할 수 있다. 키를 바꾸는 기능은 없다(바꾸면 예전 서명은 검증하지 못한다).
 */

let cached = null;
let creating = null;

/** `{ privateKey, publicKey, fingerprint, publicKeyPem }` — 없으면 만든다(한 프로세스에서 한 번만). */
export async function sealKeys() {
  if (cached) return cached;
  if (!creating) {
    creating = (async () => {
      let settings = await getServerSettings();
      if (!settings.approvalSealPrivateKeyEnc || !settings.approvalSealPublicKey) {
        const pair = crypto.generateKeyPairSync('ed25519');
        await updateServerSettings({
          approvalSealPrivateKeyEnc: encryptField(pair.privateKey.export({ type: 'pkcs8', format: 'pem' })),
          approvalSealPublicKey: pair.publicKey.export({ type: 'spki', format: 'pem' }),
        });
        settings = await getServerSettings();
      }
      const privateKey = crypto.createPrivateKey(decryptField(settings.approvalSealPrivateKeyEnc));
      const publicKey = crypto.createPublicKey(settings.approvalSealPublicKey);
      cached = {
        privateKey,
        publicKey,
        publicKeyPem: settings.approvalSealPublicKey,
        fingerprint: keyFingerprint(publicKey.export({ type: 'spki', format: 'der' })),
      };
      return cached;
    })().finally(() => {
      creating = null;
    });
  }
  return creating;
}

/** 글 → base64 서명. */
export const signWith = (keys) => (text) => crypto.sign(null, Buffer.from(text, 'utf8'), keys.privateKey).toString('base64');

/** (글, 서명) → 맞는지. */
export const verifyWith = (keys) => (text, seal) => {
  try {
    return crypto.verify(null, Buffer.from(text, 'utf8'), keys.publicKey, Buffer.from(seal, 'base64'));
  } catch {
    return false;
  }
};

/** 올린 파일(/uploads/<이름>)의 SHA-256 — 없거나 읽지 못하면 null. */
export async function uploadSha256(stored) {
  const name = uploadFileNameOf(stored);
  if (!name) return null;
  try {
    return crypto.createHash('sha256').update(await fs.readFile(path.join(uploadsDir, name))).digest('hex');
  } catch {
    return null;
  }
}
