import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import { pipeline } from 'node:stream/promises';
import {
  BACKUP_FORMAT,
  DB_FILE,
  isSafeRelativePath,
  MANIFEST_FILE,
  MIRROR_DIR,
  MIRROR_INDEX,
  MIRROR_MARKER,
  SECRETS_FILE,
} from './backup.js';
import {
  createDecryptStream,
  decryptBuffer,
  deriveBackupKey,
  isKeyCheckValid,
  isSaneKdfParams,
  mirrorKeyId,
} from './backupCrypto.js';

/**
 * 백업 복원에 쓰는 조각들(backup.js가 만든 백업 폴더 → 이 서버) — 실제 복원 순서는 scripts/restore-backup.mjs가 맡고
 * (서비스를 멈춘 채 시작 메뉴 "복원"이 부른다), 여기는 DB를 모르는 부분만 둬서 시험하기 쉽게 했다.
 *
 * 백업 폴더는 사람이 USB 등으로 옮기면서 손댈 수 있다고 본다: manifest.json은 평문이라 믿지 않고(KDF 값 범위를 보고,
 * 암호는 암호화된 확인용 글로 맞춰 본다), 비밀값 묶음에서는 정해 둔 파일만 정해 둔 자리에 쓰고, 첨부파일 색인은 경로를
 * 검사한다. 내용 자체는 암호화와 함께 인증되므로(backupCrypto.js) 암호 없이 바꿔치기할 수 없다.
 */

export class BackupPasswordError extends Error {}

/** 백업 폴더의 manifest.json — 이 형식이 아니면 사람이 읽을 이유로 던진다. */
export function readManifest(dir) {
  let manifest;
  try {
    manifest = JSON.parse(fs.readFileSync(path.join(dir, MANIFEST_FILE), 'utf8'));
  } catch {
    throw new Error(`${dir}에서 백업 정보(manifest.json)를 읽지 못했습니다 — TangoTalk 백업 폴더를 고르세요.`);
  }
  if (manifest?.app !== 'TangoTalk' || manifest.format !== BACKUP_FORMAT) {
    throw new Error('이 서버 버전이 모르는 백업 형식입니다 — 서버를 먼저 업데이트하세요.');
  }
  if (manifest.kdf?.alg !== 'scrypt' || !isSaneKdfParams(manifest.kdf) || typeof manifest.kdf.salt !== 'string') {
    throw new Error('백업 정보(manifest.json)가 손상되었습니다.');
  }
  for (const file of [DB_FILE, SECRETS_FILE]) {
    if (!fs.existsSync(path.join(dir, file))) throw new Error(`백업 폴더에 ${file}이(가) 없습니다 — 복사가 덜 됐을 수 있습니다.`);
  }
  return manifest;
}

/** 암호로 키를 만들고 맞는지 확인한다 — 틀리면 BackupPasswordError. */
export async function openBackup(dir, password) {
  const manifest = readManifest(dir);
  const key = await deriveBackupKey(password, Buffer.from(manifest.kdf.salt, 'base64'), manifest.kdf);
  if (!isKeyCheckValid(key, manifest.check)) throw new BackupPasswordError('백업 암호가 틀렸습니다.');
  return { manifest, key };
}

/** 암호화된 파일 하나를 풀어 [dest]에 쓴다(없는 파일로만 — 덮어쓰지 않는다). */
export async function decryptFileTo(src, dest, key, context) {
  try {
    await pipeline(fs.createReadStream(src), createDecryptStream(key, context), fs.createWriteStream(dest, { flags: 'wx' }));
  } catch (e) {
    fs.rmSync(dest, { force: true });
    throw e;
  }
}

/** 비밀값 묶음 — { files: { 'server/.env': Buffer, … }, mirrorKey: Buffer | null }. */
export function readSecretsBundle(dir, key) {
  const bundle = JSON.parse(decryptBuffer(key, fs.readFileSync(path.join(dir, SECRETS_FILE)), 'secrets').toString('utf8'));
  const files = {};
  for (const [name, b64] of Object.entries(bundle.files ?? {})) files[name] = Buffer.from(String(b64), 'base64');
  const mirrorKey = bundle.mirrorKey ? Buffer.from(bundle.mirrorKey, 'base64') : null;
  return { files, mirrorKey: mirrorKey?.length === 32 ? mirrorKey : null };
}

/** 서버 폴더에 되돌려 놓는 비밀값 파일 — 이 이름들만 쓴다(.env는 따로 합친다 — [mergeEnv]). */
const SECRET_FILES = ['.jwt-secret', '.db-encryption-key', '.web-push-vapid.json', 'firebase-service-account.json'];
const CERT_NAME = /^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$/;

/**
 * 묶음 안의 이름 → 서버 폴더 기준 상대 경로. 정해 둔 것이 아니면 null(쓰지 않는다). .env는 'env'로 따로 표시한다.
 */
export function secretTarget(entry) {
  if (entry === 'server/.env') return 'env';
  if (entry.startsWith('server/')) {
    const rest = entry.slice('server/'.length);
    if (SECRET_FILES.includes(rest)) return rest;
    if (rest.startsWith('certs/') && CERT_NAME.test(rest.slice('certs/'.length))) return rest;
  }
  return null;
}

/**
 * 새 PC의 .env에서 그대로 두는 값 — DB 접속 정보(새 설치가 만든 DB 비밀번호), 첨부파일 위치(이 PC의 경로), 화상회의
 * 설정(이 PC의 LiveKit 서비스·livekit.yaml과 짝), 이 PC의 폴더들.
 */
export const ENV_KEEP_LOCAL = new Set([
  'DATABASE_URL',
  'UPLOADS_DIR',
  'WEB_DIR',
  'LIVEKIT_API_KEY',
  'LIVEKIT_API_SECRET',
  'LIVEKIT_PORT',
  'LIVEKIT_URL',
  'LIVEKIT_CONFIG_PATH',
  'NODE_ENV',
  'BACKUP_DIR',
  'PG_BIN',
]);
/** 바뀌면 방화벽·공유기 포트포워딩도 맞춰야 하는 값 — 복원 뒤 안내한다. */
const ENV_PORT_KEYS = ['PORT', 'PAIRING_PORT', 'WEB_HTTPS_PORT', 'ACME_HTTP_PORT'];

const ENV_LINE = /^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=(.*)$/;

function parseEnv(text) {
  const values = new Map();
  for (const line of String(text ?? '').replace(/^﻿/, '').split(/\r?\n/)) {
    const m = ENV_LINE.exec(line);
    if (m) values.set(m[1], m[2].trim());
  }
  return values;
}

/**
 * 지금 .env([currentText])에 백업의 .env([backupText]) 값을 합친다 — [ENV_KEEP_LOCAL]은 지금 값 그대로, 나머지(외부 접속
 * 주소·웹 앱 도메인·포트·비밀값 등)는 백업 값으로. 지금 .env에만 있는 값은 둔다. 포트가 바뀐 것들을 같이 돌려준다.
 */
export function mergeEnv(currentText, backupText) {
  const backup = parseEnv(backupText);
  const current = parseEnv(currentText);
  const lines = String(currentText ?? '').replace(/^﻿/, '').split(/\r?\n/);
  const carried = [];
  const portChanges = [];
  const handled = new Set();
  for (let i = 0; i < lines.length; i++) {
    const m = ENV_LINE.exec(lines[i]);
    if (!m || ENV_KEEP_LOCAL.has(m[1]) || !backup.has(m[1])) continue;
    if (handled.has(m[1])) {
      lines[i] = `# ${lines[i]}`;
      continue;
    }
    lines[i] = `${m[1]}=${backup.get(m[1])}`;
    handled.add(m[1]);
  }
  while (lines.length && lines[lines.length - 1] === '') lines.pop();
  for (const [key, value] of backup) {
    if (ENV_KEEP_LOCAL.has(key)) continue;
    if (!handled.has(key)) lines.push(`${key}=${value}`);
    if (current.get(key) !== value) carried.push(key);
    if (ENV_PORT_KEYS.includes(key) && current.get(key) !== value) {
      portChanges.push({ key, from: current.get(key) ?? null, to: value });
    }
  }
  return { text: `${lines.join('\r\n')}\r\n`, carried, portChanges };
}

/** 백업 폴더 옆(같은 TangoTalk-Backup 안)에 첨부파일 미러가 있으면 그 경로, 없으면 null. */
export function findMirrorFor(backupDir) {
  const mirrorDir = path.join(path.dirname(path.resolve(backupDir)), MIRROR_DIR);
  return fs.existsSync(path.join(mirrorDir, MIRROR_MARKER)) ? mirrorDir : null;
}

/**
 * 첨부파일 미러를 [targetDir](이 서버의 첨부파일 폴더)로 풀어 놓는다. 이미 있는 파일은 건드리지 않는다(같은 PC에 복원하면
 * 대부분 그대로 있다 — 첨부파일 이름은 무작위라 이름이 같으면 같은 파일이다). 미러 키가 다르면 던진다.
 */
export async function restoreMirror({ mirrorDir, key, targetDir, onProgress = () => {} }) {
  let marker;
  try {
    marker = JSON.parse(fs.readFileSync(path.join(mirrorDir, MIRROR_MARKER), 'utf8'));
  } catch {
    throw new Error('첨부파일 백업 정보를 읽지 못했습니다.');
  }
  if (marker?.keyId !== mirrorKeyId(key)) {
    throw new Error('첨부파일 백업이 이 백업과 다른 서버(또는 다른 키)의 것입니다 — 첨부파일은 복원하지 않았습니다.');
  }
  let index;
  try {
    index = JSON.parse(fs.readFileSync(path.join(mirrorDir, MIRROR_INDEX), 'utf8')).files ?? {};
  } catch {
    throw new Error('첨부파일 백업 목록(index.json)을 읽지 못했습니다.');
  }
  fs.mkdirSync(targetDir, { recursive: true });
  const entries = Object.keys(index);
  let restored = 0;
  let skipped = 0;
  const failed = [];
  onProgress(0, entries.length);
  for (let i = 0; i < entries.length; i++) {
    const rel = entries[i];
    if (!isSafeRelativePath(rel)) {
      failed.push(rel);
      continue;
    }
    const target = path.join(targetDir, ...rel.split('/'));
    if (fs.existsSync(target)) {
      skipped++;
    } else {
      try {
        fs.mkdirSync(path.dirname(target), { recursive: true });
        const tmp = `${target}.restoring`;
        fs.rmSync(tmp, { force: true });
        await decryptFileTo(path.join(mirrorDir, ...`${rel}.enc`.split('/')), tmp, key, `upload:${rel}`);
        await fsp.rename(tmp, target);
        restored++;
      } catch {
        failed.push(rel);
      }
    }
    if (i % 100 === 0) onProgress(i, entries.length);
  }
  onProgress(entries.length, entries.length);
  return { total: entries.length, restored, skipped, failed };
}

/**
 * DB 복원 앞머리 — 지금 DB의 객체를 모두 지운다. 백업(pg_restore -f -가 만든 SQL)과 함께 한 트랜잭션으로 돌린다(restore-backup.mjs
 * — 실패하면 아무것도 지워지지 않는다). 앱 계정(DB 소유자 — 설치본)이면 그 계정이 가진 것을 모두 지우고(DROP OWNED — public
 * 스키마는 PostgreSQL 15부터 pg_database_owner 것이라 남는다), 슈퍼유저로 붙는 개발 PC는 public·drizzle 스키마를 지운다.
 */
export const RESTORE_PRELUDE_SQL = [
  'DO $$ BEGIN',
  '  IF (SELECT rolsuper FROM pg_roles WHERE rolname = current_user) THEN',
  "    EXECUTE 'DROP SCHEMA IF EXISTS drizzle CASCADE';",
  "    EXECUTE 'DROP SCHEMA IF EXISTS public CASCADE';",
  '  ELSE',
  "    EXECUTE 'DROP OWNED BY ' || quote_ident(current_user);",
  '  END IF;',
  'END $$;',
  'CREATE SCHEMA IF NOT EXISTS public;',
  '',
].join('\n');

/**
 * 백업이 이 서버 코드보다 새 스키마로 만든 것인지 — 백업의 마이그레이션 수가 코드보다 많으면 지금 코드로는 그 DB를 쓸 수
 * 없으니(모르는 칼럼·표) 서버를 먼저 업데이트하라고 막는다. 적거나 같으면 복원 뒤 마이그레이션으로 맞춘다.
 */
export function checkMigrationCompat(manifest, codeMigrationCount) {
  const backupCount = Number(manifest?.migrations?.count);
  if (!Number.isInteger(backupCount) || !Number.isInteger(codeMigrationCount)) return { ok: true };
  if (backupCount > codeMigrationCount) {
    return {
      ok: false,
      error: `이 백업은 더 새 버전의 서버에서 만든 것입니다(마이그레이션 ${backupCount}개, 이 서버 ${codeMigrationCount}개) — 서버를 먼저 업데이트한 뒤 복원하세요.`,
    };
  }
  return { ok: true };
}
