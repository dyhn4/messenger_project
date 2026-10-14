import crypto from 'node:crypto';
import { Transform } from 'node:stream';

/**
 * 백업 파일 암호화(backup.js) — 백업에는 DB 전체와 DB 암호화 키·JWT 비밀값·서버 인증서 개인키까지 들어가서, 백업 폴더를
 * NAS·외장 드라이브로 옮겨 두어도 백업 암호 없이는 열 수 없게 전부 암호화한다.
 *
 * 형식(TTBK v1) — 큰 파일(DB 덤프·첨부파일)도 메모리에 다 올리지 않게 조각(최대 1MiB)마다 AES-256-GCM으로 잠근다:
 *   머리: "TTBK"(4) + 판(1, =1) + 논스 앞부분(7, 무작위)                                      = 12바이트
 *   조각: 끝 표시(1, 0|1) + 암호문 길이(4, 빅엔디언) + 암호문 + 인증 태그(16)
 * 조각의 논스는 논스 앞부분(7) + 조각 번호(4) + 끝 표시(1)이고, 머리 12바이트와 [context](이 파일이 무엇인지 — 'db',
 * 'upload:<이름>' …)를 추가 인증 데이터로 묶는다. 그래서 조각을 바꾸거나 순서를 섞거나 빼면(번호가 어긋남), 끝 조각을 잘라
 * 내거나 끝 표시를 바꾸면(논스가 달라짐), 같은 키로 잠근 다른 파일과 바꿔치기하면(context가 다름) 풀 때 실패한다. 끝 조각
 * 뒤에 더 붙은 것도, 끝 조각 없이 끝난 것도(잘린 파일) 실패로 본다. 키 하나로 파일마다 새 논스 앞부분(56비트 무작위)을
 * 쓴다 — 첨부파일 수십만 개를 같은 키로 잠가도 겹칠 확률은 무시할 만하다.
 */

const MAGIC = Buffer.from('TTBK');
const VERSION = 1;
const HEADER_BYTES = 12;
const PREFIX_BYTES = 7;
const TAG_BYTES = 16;
const RECORD_HEAD_BYTES = 5;
/** 조각 하나의 평문 크기(마지막 조각은 이보다 작거나 0). */
export const CHUNK_BYTES = 1024 * 1024;

/** 백업 암호 → 키(scrypt). N=2^15·r=8은 한 번에 32MiB·0.1초 남짓 — 백업·복원 때 한 번씩만 돈다. */
export const KDF_PARAMS = Object.freeze({ N: 32768, r: 8, p: 1 });

/** manifest.json에 적힌 KDF 값이 쓸 만한지 — 손댄 manifest로 메모리·시간을 터무니없이 쓰게 하지 못하게. */
export function isSaneKdfParams(p) {
  return (
    p != null &&
    Number.isInteger(p.N) &&
    p.N >= 1024 &&
    p.N <= 1 << 20 &&
    (p.N & (p.N - 1)) === 0 &&
    Number.isInteger(p.r) &&
    p.r >= 1 &&
    p.r <= 32 &&
    Number.isInteger(p.p) &&
    p.p >= 1 &&
    p.p <= 4
  );
}

/** 암호에서 32바이트 키를 만든다. [salt]는 백업마다 새로 뽑아 manifest.json에 적는다. */
export function deriveBackupKey(password, salt, params = KDF_PARAMS) {
  return new Promise((resolve, reject) => {
    crypto.scrypt(
      Buffer.from(String(password).normalize('NFC'), 'utf8'),
      salt,
      32,
      { N: params.N, r: params.r, p: params.p, maxmem: 256 * params.N * params.r * params.p },
      (err, key) => (err ? reject(err) : resolve(key)),
    );
  });
}

/** 파일 내용이 이 형식이 아니거나 키가 틀렸거나 바뀌었을 때 던진다. */
export class BackupDecryptError extends Error {}

function nonceFor(prefix, index, final) {
  const nonce = Buffer.alloc(12);
  prefix.copy(nonce, 0);
  nonce.writeUInt32BE(index, PREFIX_BYTES);
  nonce[11] = final ? 1 : 0;
  return nonce;
}

function aadFor(header, context) {
  return Buffer.concat([header, Buffer.from(String(context), 'utf8')]);
}

function sealChunk(key, aad, prefix, index, final, plain) {
  if (index > 0xffffffff) throw new Error('파일이 너무 커서 암호화할 수 없습니다.');
  const cipher = crypto.createCipheriv('aes-256-gcm', key, nonceFor(prefix, index, final));
  cipher.setAAD(aad);
  const body = Buffer.concat([cipher.update(plain), cipher.final()]);
  const head = Buffer.alloc(RECORD_HEAD_BYTES);
  head[0] = final ? 1 : 0;
  head.writeUInt32BE(body.length, 1);
  return Buffer.concat([head, body, cipher.getAuthTag()]);
}

function openChunk(key, aad, prefix, index, final, body, tag) {
  try {
    const decipher = crypto.createDecipheriv('aes-256-gcm', key, nonceFor(prefix, index, final));
    decipher.setAAD(aad);
    decipher.setAuthTag(tag);
    return Buffer.concat([decipher.update(body), decipher.final()]);
  } catch {
    throw new BackupDecryptError('백업 암호가 틀렸거나 파일이 손상되었습니다.');
  }
}

function newHeader() {
  const prefix = crypto.randomBytes(PREFIX_BYTES);
  return { header: Buffer.concat([MAGIC, Buffer.from([VERSION]), prefix]), prefix };
}

function readHeader(buf) {
  if (buf.length < HEADER_BYTES || !buf.subarray(0, 4).equals(MAGIC)) {
    throw new BackupDecryptError('TangoTalk 백업 파일이 아닙니다.');
  }
  if (buf[4] !== VERSION) throw new BackupDecryptError(`지원하지 않는 백업 파일 형식입니다(판 ${buf[4]}).`);
  return { header: Buffer.from(buf.subarray(0, HEADER_BYTES)), prefix: Buffer.from(buf.subarray(5, HEADER_BYTES)) };
}

/** 평문을 받아 암호문을 내보내는 스트림 — 파일·pg_dump 출력을 그대로 흘려 넣는다. */
export function createEncryptStream(key, context) {
  const { header, prefix } = newHeader();
  const aad = aadFor(header, context);
  let pending = [];
  let pendingBytes = 0;
  let index = 0;
  let headerSent = false;

  function take(n) {
    const all = Buffer.concat(pending, pendingBytes);
    pending = [all.subarray(n)];
    pendingBytes = all.length - n;
    return all.subarray(0, n);
  }

  return new Transform({
    transform(chunk, _enc, done) {
      try {
        if (!headerSent) {
          this.push(header);
          headerSent = true;
        }
        pending.push(chunk);
        pendingBytes += chunk.length;
        // 끝 조각은 flush에서 끝 표시를 달아 내보내야 하므로, 1MiB를 "넘을" 때만 꽉 찬 조각을 미리 내보낸다.
        while (pendingBytes > CHUNK_BYTES) {
          this.push(sealChunk(key, aad, prefix, index++, false, take(CHUNK_BYTES)));
        }
        done();
      } catch (e) {
        done(e);
      }
    },
    flush(done) {
      try {
        if (!headerSent) this.push(header);
        this.push(sealChunk(key, aad, prefix, index++, true, take(pendingBytes)));
        done();
      } catch (e) {
        done(e);
      }
    },
  });
}

/** 암호문을 받아 평문을 내보내는 스트림 — 틀린 키·손상·잘림·다른 파일이면 BackupDecryptError로 끝난다. */
export function createDecryptStream(key, context) {
  let buf = Buffer.alloc(0);
  let head = null;
  let aad = null;
  let index = 0;
  let finished = false;

  return new Transform({
    transform(chunk, _enc, done) {
      try {
        buf = buf.length ? Buffer.concat([buf, chunk]) : chunk;
        if (!head) {
          if (buf.length < HEADER_BYTES) return done();
          head = readHeader(buf);
          aad = aadFor(head.header, context);
          buf = buf.subarray(HEADER_BYTES);
        }
        while (buf.length >= RECORD_HEAD_BYTES) {
          if (finished) throw new BackupDecryptError('백업 파일 끝에 알 수 없는 내용이 붙어 있습니다.');
          const final = buf[0];
          const len = buf.readUInt32BE(1);
          if (final > 1 || len > CHUNK_BYTES) throw new BackupDecryptError('백업 파일이 손상되었습니다.');
          const total = RECORD_HEAD_BYTES + len + TAG_BYTES;
          if (buf.length < total) break;
          const body = buf.subarray(RECORD_HEAD_BYTES, RECORD_HEAD_BYTES + len);
          const tag = buf.subarray(RECORD_HEAD_BYTES + len, total);
          this.push(openChunk(key, aad, head.prefix, index++, final === 1, body, tag));
          buf = buf.subarray(total);
          if (final === 1) finished = true;
        }
        done();
      } catch (e) {
        done(e);
      }
    },
    flush(done) {
      if (!head) return done(new BackupDecryptError('TangoTalk 백업 파일이 아닙니다.'));
      if (!finished || buf.length) return done(new BackupDecryptError('백업 파일이 중간에 잘렸습니다.'));
      done();
    },
  });
}

/** 작은 내용(비밀값 묶음·암호 확인용 글) 한 번에 — 스트림과 같은 형식. */
export function encryptBuffer(key, plain, context) {
  const { header, prefix } = newHeader();
  const aad = aadFor(header, context);
  const parts = [header];
  let index = 0;
  let offset = 0;
  while (plain.length - offset > CHUNK_BYTES) {
    parts.push(sealChunk(key, aad, prefix, index++, false, plain.subarray(offset, offset + CHUNK_BYTES)));
    offset += CHUNK_BYTES;
  }
  parts.push(sealChunk(key, aad, prefix, index, true, plain.subarray(offset)));
  return Buffer.concat(parts);
}

export function decryptBuffer(key, sealed, context) {
  const head = readHeader(sealed);
  const aad = aadFor(head.header, context);
  const out = [];
  let pos = HEADER_BYTES;
  let index = 0;
  while (pos < sealed.length) {
    if (sealed.length - pos < RECORD_HEAD_BYTES) throw new BackupDecryptError('백업 파일이 중간에 잘렸습니다.');
    const final = sealed[pos];
    const len = sealed.readUInt32BE(pos + 1);
    if (final > 1 || len > CHUNK_BYTES) throw new BackupDecryptError('백업 파일이 손상되었습니다.');
    const end = pos + RECORD_HEAD_BYTES + len + TAG_BYTES;
    if (end > sealed.length) throw new BackupDecryptError('백업 파일이 중간에 잘렸습니다.');
    const body = sealed.subarray(pos + RECORD_HEAD_BYTES, pos + RECORD_HEAD_BYTES + len);
    out.push(openChunk(key, aad, head.prefix, index++, final === 1, body, sealed.subarray(end - TAG_BYTES, end)));
    pos = end;
    if (final === 1) {
      if (pos !== sealed.length) throw new BackupDecryptError('백업 파일 끝에 알 수 없는 내용이 붙어 있습니다.');
      return Buffer.concat(out);
    }
  }
  throw new BackupDecryptError('백업 파일이 중간에 잘렸습니다.');
}

/** 암호 확인용 글 — manifest.json의 check를 풀어 이 글이 나오면 암호가 맞다. */
const CHECK_TEXT = 'TANGOTALK-BACKUP-KEY-CHECK';

export function makeKeyCheck(key) {
  return encryptBuffer(key, Buffer.from(CHECK_TEXT), 'check').toString('base64');
}

export function isKeyCheckValid(key, check) {
  try {
    return decryptBuffer(key, Buffer.from(String(check), 'base64'), 'check').toString() === CHECK_TEXT;
  } catch {
    return false;
  }
}

/** 첨부파일 미러 키의 이름표 — 키 자체를 드러내지 않고 "같은 키인지"만 비교한다. */
export function mirrorKeyId(key) {
  return crypto.createHash('sha256').update('tangotalk-mirror-key-id').update(key).digest('hex').slice(0, 16);
}
