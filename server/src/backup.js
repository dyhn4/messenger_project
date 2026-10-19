import crypto from 'node:crypto';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { pipeline } from 'node:stream/promises';
import {
  createEncryptStream,
  deriveBackupKey,
  encryptBuffer,
  KDF_PARAMS,
  makeKeyCheck,
  mirrorKeyId,
} from './backupCrypto.js';

/**
 * 서버 전체 백업(DB + 비밀값·인증서 + 첨부파일) — 서버가 예약 시각에 스스로 돌리고(backupService.js), 관리자 콘솔 "백업"
 * 탭의 "지금 백업"과 시작 메뉴 "백업"(scripts/backup-now.mjs)도 이 파일로 한다. 이 파일은 DB를 모르게 둬서(pg_dump는
 * [dumpDb]로 받는다) 시험하기 쉽게 했다. 복원은 backupRestore.js.
 *
 * 한 번 백업하면 백업 폴더(예: {app}\backups)에 폴더 하나가 생긴다:
 *   tangotalk_20261014_030000\
 *     manifest.json   무엇이 들었는지·언제·어떤 서버에서(평문 — 비밀은 없다), 암호 확인용 글, 키를 만드는 값(salt)
 *     db.dump.enc     pg_dump -F c 출력을 그대로 암호화(평문 덤프는 디스크에 쓰지 않는다)
 *     secrets.enc     .env·.jwt-secret·.db-encryption-key·웹 푸시 키·certs\*(서버 인증서와 개인키)·첨부파일 미러 키
 * 다 쓰기 전에는 이름 끝에 ".partial"을 달아 두고 마지막에 이름을 바꾼다 — 중간에 끊긴 백업은 백업으로 보이지 않는다.
 *
 * 외부 위치(NAS·외장 드라이브)를 정하면 그 아래 "TangoTalk-Backup" 폴더에 같은 백업 폴더를 복사하고, 첨부파일은
 * "uploads" 폴더에 파일마다 암호화해서 늘 지금 상태로 맞춰 둔다(바뀐 파일만 다시 보낸다). 첨부파일은 서버에 이미 있으니
 * 같은 PC 안에는 따로 복사하지 않는다 — 디스크가 고장 나면 둘 다 잃기 때문에, 첨부파일 백업은 외부 위치에만 의미가 있다.
 *
 * 우리가 지우는 것은 우리가 만든 이름(tangotalk_<날짜>_<시각>)과 표시 파일이 있는 폴더 안의 것뿐이다 — 관리자가 외부
 * 위치로 아무 폴더나 골라도 그 안의 남의 파일을 건드리지 않게.
 */

export const BACKUP_FORMAT = 1;
const NAME_RE = /^tangotalk_(\d{4})(\d{2})(\d{2})_(\d{2})(\d{2})(\d{2})$/;
const PARTIAL_SUFFIX = '.partial';
export const MANIFEST_FILE = 'manifest.json';
export const DB_FILE = 'db.dump.enc';
export const SECRETS_FILE = 'secrets.enc';
/** 외부 위치 안에 만드는 전용 폴더 — 고른 폴더 자체가 아니라 그 아래에만 쓴다. */
export const EXTERNAL_DIR_NAME = 'TangoTalk-Backup';
const ROOT_MARKER = 'tangotalk-backup-root.json';
export const MIRROR_DIR = 'uploads';
export const MIRROR_MARKER = 'tangotalk-uploads-mirror.json';
export const MIRROR_INDEX = 'index.json';
/**
 * 외부 위치에 파일마다 맞춰 두는 미러 — 첨부파일(uploads)과 회사 메일함(mailstore — 자체 메일 서버가 받은 메일 원문, 목록·플래그는 DB에
 * 있다). [context]는 파일마다 암호화할 때 섞는 이름의 앞부분(첨부파일은 예전 백업과 같은 'upload').
 */
export const MIRRORS = Object.freeze({
  uploads: Object.freeze({ dir: MIRROR_DIR, marker: MIRROR_MARKER, context: 'upload', label: '첨부파일' }),
  mailstore: Object.freeze({ dir: 'mailstore', marker: 'tangotalk-mailstore-mirror.json', context: 'mail', label: '회사 메일함' }),
});
const LOCK_FILE = '.backup.lock';
const STATUS_FILE = 'backup-status.json';
const DAY_MS = 24 * 60 * 60 * 1000;
/** 백업 하나가 이보다 오래 잠금을 쥐고 있으면 그 백업은 죽은 것으로 본다(첨부파일이 아주 많아도 넉넉하게). */
const LOCK_STALE_MS = 12 * 60 * 60 * 1000;

/** 보관 개수 범위(관리자 콘솔에서 고른다). */
export const KEEP_MIN = 3;
export const KEEP_MAX = 60;
export const KEEP_DEFAULT = 14;
export const HOUR_DEFAULT = 3;
/** 백업 암호 길이. 잃어버리면 백업을 못 여니 너무 길게 강요하지는 않되, 짧은 암호는 받지 않는다. */
export const PASSWORD_MIN = 8;
export const PASSWORD_MAX = 256;

/** 이미 다른 백업이 돌고 있을 때. */
export class BackupBusyError extends Error {}

const pad = (n, w = 2) => String(n).padStart(w, '0');

/** 백업 폴더 이름 — 이 PC 시각 기준(관리자가 보는 시각과 같게). */
export function backupFolderName(date) {
  return (
    `tangotalk_${date.getFullYear()}${pad(date.getMonth() + 1)}${pad(date.getDate())}_` +
    `${pad(date.getHours())}${pad(date.getMinutes())}${pad(date.getSeconds())}`
  );
}

/** 백업 폴더 이름의 시각(ms) — 우리 이름이 아니면 null. */
export function parseBackupFolderName(name) {
  const m = NAME_RE.exec(name);
  if (!m) return null;
  const [, y, mo, d, h, mi, s] = m.map(Number);
  const date = new Date(y, mo - 1, d, h, mi, s);
  return Number.isNaN(date.getTime()) ? null : date.getTime();
}

/** [dir]가 링크(심볼릭 링크·정션)면 던진다 — 공격자가 심어 둔 링크를 따라 엉뚱한 곳에 쓰거나 지우지 않게. */
export function assertNotLink(dir) {
  let st;
  try {
    st = fs.lstatSync(dir);
  } catch (e) {
    if (e.code === 'ENOENT') return;
    throw e;
  }
  if (st.isSymbolicLink()) {
    throw new Error(`${dir}가 링크(정션/심볼릭 링크)라 안전을 위해 백업하지 않습니다 — 링크를 지우고 다시 시도하세요.`);
  }
  if (!st.isDirectory()) throw new Error(`${dir}가 폴더가 아닙니다.`);
}

function ensureOwnDir(dir) {
  assertNotLink(dir);
  fs.mkdirSync(dir, { recursive: true });
  assertNotLink(dir);
}

function isPidAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (e) {
    return e.code === 'EPERM';
  }
}

/**
 * 백업 폴더에 잠금 파일을 만든다 — 서버의 예약 백업과 시작 메뉴 "백업"(따로 뜨는 node)이 겹치지 않게. 이미 있으면
 * 그 백업이 아직 살아 있는지(프로세스·시간) 보고, 죽었으면 치우고 다시 잡는다. 돌려주는 함수로 놓는다.
 */
export function acquireBackupLock(root, { owner = 'server', now = Date.now, isAlive = isPidAlive } = {}) {
  const file = path.join(root, LOCK_FILE);
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      const fd = fs.openSync(file, 'wx');
      try {
        fs.writeSync(fd, JSON.stringify({ pid: process.pid, owner, startedAt: now() }));
      } finally {
        fs.closeSync(fd);
      }
      return () => fs.rmSync(file, { force: true });
    } catch (e) {
      if (e.code !== 'EEXIST') throw e;
    }
    let held = null;
    try {
      held = JSON.parse(fs.readFileSync(file, 'utf8'));
    } catch {
      // 쓰다 만 잠금 파일 — 아래에서 시간으로만 판단한다.
    }
    const startedAt = Number(held?.startedAt) || fs.statSync(file).mtimeMs;
    const stale = now() - startedAt > LOCK_STALE_MS || (held && !isAlive(held.pid));
    if (!stale) {
      throw new BackupBusyError(
        held?.owner === 'script'
          ? '시작 메뉴 "백업"이 이미 백업하고 있습니다. 끝난 뒤 다시 시도하세요.'
          : '이미 백업하고 있습니다. 끝난 뒤 다시 시도하세요.',
      );
    }
    fs.rmSync(file, { force: true });
  }
  throw new BackupBusyError('백업 잠금을 잡지 못했습니다. 잠시 뒤 다시 시도하세요.');
}

/** 지금 누군가 살아 있는 백업이 잠금을 쥐고 있으면 그 주인('server' | 'script'), 아니면 null. */
export function backupLockHolder(root, { now = Date.now, isAlive = isPidAlive } = {}) {
  const file = path.join(root, LOCK_FILE);
  let held;
  try {
    held = JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch {
    return null;
  }
  if (now() - Number(held?.startedAt) > LOCK_STALE_MS || !isAlive(held?.pid)) return null;
  return held.owner === 'script' ? 'script' : 'server';
}

/**
 * 백업 하나를 만든다. [dumpDb]()는 { stream: pg_dump -F c 출력, done: 끝나면 풀리고 실패면 거절되는 약속 }을 준다.
 * [secretFiles]는 [{ name: 'server/.env', path }] — 없는 파일은 건너뛴다. [mirrorKey]는 첨부파일 미러 키(32바이트)로,
 * 복원할 때 첨부파일 백업을 풀 수 있게 비밀값 묶음에 같이 넣는다. 실패하면 쓰던 폴더를 지우고 던진다.
 */
export async function createBackup({
  root,
  password,
  kind,
  dumpDb,
  secretFiles,
  mirrorKey,
  info = {},
  now = () => new Date(),
  kdfParams = KDF_PARAMS,
  onPhase = () => {},
}) {
  ensureOwnDir(root);
  let name = backupFolderName(now());
  // 같은 초에 두 번 돌면(직전 백업이 아주 빨리 끝난 경우) 이름이 겹친다 — 다음 초까지 기다린다.
  for (let i = 0; i < 3 && fs.existsSync(path.join(root, name)); i++) {
    await new Promise((r) => setTimeout(r, 1000));
    name = backupFolderName(now());
  }
  const finalDir = path.join(root, name);
  const partialDir = finalDir + PARTIAL_SUFFIX;
  fs.mkdirSync(partialDir);
  try {
    const salt = crypto.randomBytes(16);
    const key = await deriveBackupKey(password, salt, kdfParams);

    onPhase('DB 백업 중');
    const dbPath = path.join(partialDir, DB_FILE);
    const dump = dumpDb();
    const [written, finished] = await Promise.allSettled([
      pipeline(dump.stream, createEncryptStream(key, 'db'), fs.createWriteStream(dbPath, { flags: 'wx' })),
      dump.done,
    ]);
    if (finished.status === 'rejected') throw finished.reason;
    if (written.status === 'rejected') throw written.reason;

    onPhase('설정·인증서 백업 중');
    const files = {};
    for (const { name: entry, path: filePath } of secretFiles) {
      try {
        files[entry] = fs.readFileSync(filePath).toString('base64');
      } catch (e) {
        if (e.code !== 'ENOENT') throw e;
      }
    }
    const bundle = { format: BACKUP_FORMAT, files, mirrorKey: mirrorKey ? mirrorKey.toString('base64') : null };
    fs.writeFileSync(
      path.join(partialDir, SECRETS_FILE),
      encryptBuffer(key, Buffer.from(JSON.stringify(bundle)), 'secrets'),
      { flag: 'wx' },
    );

    const createdAt = now();
    const manifest = {
      format: BACKUP_FORMAT,
      app: 'TangoTalk',
      name,
      kind,
      createdAt: createdAt.toISOString(),
      ...info,
      kdf: { alg: 'scrypt', salt: salt.toString('base64'), ...kdfParams },
      check: makeKeyCheck(key),
      mirrorKeyId: mirrorKey ? mirrorKeyId(mirrorKey) : null,
      contents: {
        db: { file: DB_FILE, bytes: fs.statSync(dbPath).size },
        secrets: { file: SECRETS_FILE, entries: Object.keys(files).sort() },
      },
    };
    fs.writeFileSync(path.join(partialDir, MANIFEST_FILE), JSON.stringify(manifest, null, 2), { flag: 'wx' });
    fs.renameSync(partialDir, finalDir);
    return { name, dir: finalDir, manifest, bytes: await folderBytes(finalDir) };
  } catch (e) {
    await removeQuietly(partialDir);
    throw e;
  }
}

async function removeQuietly(target) {
  try {
    await fsp.rm(target, { recursive: true, force: true, maxRetries: 3 });
  } catch {
    // 다음 정리(pruneBackups — 하루 지난 .partial)에서 다시 지운다.
  }
}

async function exists(target) {
  try {
    await fsp.access(target);
    return true;
  } catch {
    return false;
  }
}

/** 링크가 아닌지 — 외부 위치처럼 느릴 수 있는 곳은 이것으로(동기 호출은 꺼진 NAS를 기다리며 서버 전체를 멈춘다). */
async function assertNotLinkAsync(dir) {
  let st;
  try {
    st = await fsp.lstat(dir);
  } catch (e) {
    if (e.code === 'ENOENT') return;
    throw e;
  }
  if (st.isSymbolicLink()) {
    throw new Error(`${dir}가 링크(정션/심볼릭 링크)라 안전을 위해 백업하지 않습니다 — 링크를 지우고 다시 시도하세요.`);
  }
  if (!st.isDirectory()) throw new Error(`${dir}가 폴더가 아닙니다.`);
}

async function folderBytes(dir) {
  let total = 0;
  for (const entry of await fsp.readdir(dir, { withFileTypes: true })) {
    if (entry.isFile()) total += (await fsp.stat(path.join(dir, entry.name))).size;
  }
  return total;
}

async function readJsonAsync(file, fallback) {
  try {
    return JSON.parse(await fsp.readFile(file, 'utf8'));
  } catch {
    return fallback;
  }
}

async function writeJsonAtomicAsync(file, value) {
  const tmp = `${file}.tmp`;
  await fsp.writeFile(tmp, JSON.stringify(value));
  await fsp.rename(tmp, file);
}

/** [root] 안의 다 만든 백업들 — 최신 것부터. manifest.json을 못 읽는 폴더는 백업으로 치지 않는다. */
export async function listBackups(root) {
  let entries;
  try {
    entries = await fsp.readdir(root, { withFileTypes: true });
  } catch (e) {
    if (e.code === 'ENOENT') return [];
    throw e;
  }
  const out = [];
  for (const entry of entries) {
    if (!entry.isDirectory() || parseBackupFolderName(entry.name) === null) continue;
    const dir = path.join(root, entry.name);
    const manifest = await readJsonAsync(path.join(dir, MANIFEST_FILE), null);
    if (manifest?.format !== BACKUP_FORMAT || manifest.name !== entry.name) continue;
    out.push({
      name: entry.name,
      createdAt: Date.parse(manifest.createdAt) || parseBackupFolderName(entry.name),
      kind: manifest.kind ?? null,
      bytes: await folderBytes(dir),
    });
  }
  return out.sort((a, b) => (a.name < b.name ? 1 : -1));
}

/**
 * 최근 [keep]개만 남기고 오래된 백업을 지운다. 하루 넘게 남은 ".partial"(끊긴 백업)도 치운다. 잠금을 쥔 채로만 부른다
 * (다른 백업이 쓰고 있는 .partial을 지우지 않게). 지운 이름들을 돌려준다.
 */
export async function pruneBackups(root, keep, { now = Date.now } = {}) {
  const removed = [];
  for (const backup of (await listBackups(root)).slice(Math.max(keep, 1))) {
    await removeQuietly(path.join(root, backup.name));
    removed.push(backup.name);
  }
  for (const entry of await fsp.readdir(root, { withFileTypes: true })) {
    if (!entry.isDirectory() || !entry.name.endsWith(PARTIAL_SUFFIX)) continue;
    const at = parseBackupFolderName(entry.name.slice(0, -PARTIAL_SUFFIX.length));
    if (at !== null && now() - at > DAY_MS) await removeQuietly(path.join(root, entry.name));
  }
  return removed;
}

/**
 * 외부 위치에 쓸 전용 폴더(<dest>\TangoTalk-Backup)를 준비하고 그 경로를 돌려준다. 고른 폴더가 없으면(외장 드라이브가
 * 빠졌거나 NAS가 꺼짐) 만들지 않고 실패한다 — 엉뚱한 드라이브에 폴더를 새로 만들어 쓰지 않게. 전용 폴더가 이미 있는데
 * 우리 표시 파일이 없고 비어 있지도 않으면 남의 폴더로 보고 쓰지 않는다. 외부 위치는 네트워크일 수 있어 비동기 호출만
 * 쓴다 — 동기 호출은 꺼진 NAS를 기다리는 동안 서버 전체(채팅)를 멈춘다.
 */
export async function prepareExternalRoot(dest, { now = Date.now } = {}) {
  let st;
  try {
    st = await fsp.stat(dest);
  } catch {
    throw new Error(`외부 백업 위치(${dest})를 찾을 수 없습니다 — 외장 드라이브가 연결돼 있는지, NAS가 켜져 있는지 확인하세요.`);
  }
  if (!st.isDirectory()) throw new Error(`외부 백업 위치(${dest})가 폴더가 아닙니다.`);
  const extRoot = path.join(dest, EXTERNAL_DIR_NAME);
  await assertNotLinkAsync(extRoot);
  const marker = path.join(extRoot, ROOT_MARKER);
  if (!(await exists(extRoot))) {
    await fsp.mkdir(extRoot);
  } else if (!(await exists(marker)) && (await fsp.readdir(extRoot)).length > 0) {
    throw new Error(`${extRoot} 폴더에 다른 파일이 들어 있어 쓰지 않습니다 — 비우거나 다른 위치를 고르세요.`);
  }
  if (!(await exists(marker))) {
    await fsp.writeFile(marker, JSON.stringify({ app: 'TangoTalk', createdAt: new Date(now()).toISOString() }));
  }
  return extRoot;
}

/** 외부 위치에 없는 최근 백업들을 복사한다(어제 NAS가 꺼져 있었으면 오늘 같이 보낸다). 복사한 이름들을 돌려준다. */
export async function copyBackupsTo(localRoot, extRoot, keep) {
  const copied = [];
  for (const backup of (await listBackups(localRoot)).slice(0, Math.max(keep, 1))) {
    const target = path.join(extRoot, backup.name);
    if (await exists(target)) continue;
    const partial = target + PARTIAL_SUFFIX;
    await removeQuietly(partial);
    await fsp.mkdir(partial);
    try {
      const source = path.join(localRoot, backup.name);
      for (const entry of await fsp.readdir(source, { withFileTypes: true })) {
        if (entry.isFile()) await fsp.copyFile(path.join(source, entry.name), path.join(partial, entry.name));
      }
      await fsp.rename(partial, target);
    } catch (e) {
      await removeQuietly(partial);
      throw e;
    }
    copied.push(backup.name);
  }
  return copied;
}

/** 미러 안의 파일 이름 한 칸으로 써도 되는지 — 색인은 평문이라, 손댄 색인으로 미러 밖 경로를 가리키지 못하게. */
const SAFE_SEGMENT = /^(?!\.{1,2}$)[^\\/:*?"<>|\x00-\x1f]{1,255}$/;

/** 미러 색인의 상대 경로(a/b.png)가 안전한지. */
export function isSafeRelativePath(rel) {
  return typeof rel === 'string' && rel.length <= 1024 && rel.split('/').every((s) => SAFE_SEGMENT.test(s));
}

async function walkFiles(dir, prefix = '') {
  const out = [];
  for (const entry of await fsp.readdir(dir, { withFileTypes: true })) {
    if (entry.isSymbolicLink()) continue;
    const rel = prefix ? `${prefix}/${entry.name}` : entry.name;
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) out.push(...(await walkFiles(full, rel)));
    else if (entry.isFile() && isSafeRelativePath(rel)) out.push({ rel, full });
  }
  return out;
}

function readJson(file, fallback) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch {
    return fallback;
  }
}

function writeJsonAtomic(file, value) {
  const tmp = `${file}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(value));
  fs.renameSync(tmp, file);
}

/** 미러에서 한꺼번에 지울 수 있는 양 — 이보다 많이 사라졌으면(저장소가 잠깐 비어 보임·랜섬웨어·실수) 지우지 않는다. */
export const MASS_DELETE_MIN = 50;
export const MASS_DELETE_RATIO = 0.2;

/**
 * [kind]의 폴더([sourceDir] — 'uploads'는 첨부파일, 'mailstore'는 회사 메일함 원문)를 외부 위치의 미러(<extRoot>\uploads·mailstore)에
 * 맞춘다(MIRRORS) — 파일마다 [key](미러 키)로 암호화해서
 * "이름.enc"로 둔다. 크기·수정 시각이 색인과 같으면 다시 보내지 않고, 원본에서 사라진 파일은 미러에서도 지운다. 단 한꺼번에
 * 너무 많이 사라졌으면(MASS_DELETE_*) 지우지 않고 경고만 남긴다 — 미러는 지금 상태를 따라가지만, 사고로 첨부파일이 통째로
 * 사라졌을 때 그 빈 상태를 백업까지 따라가게 하면 안 된다. 미러 키가 바뀌었으면(다른 서버의 DB로 복원한 경우 등) 미러를
 * 비우고 새로 만든다. 첨부파일 폴더와 외부 위치 둘 다 네트워크일 수 있어 비동기 호출만 쓴다.
 */
export async function mirrorFolder({ kind = 'uploads', sourceDir, extRoot, key, onProgress = () => {}, log = console }) {
  const m = MIRRORS[kind];
  if (!(await exists(sourceDir))) throw new Error(`${m.label} 폴더(${sourceDir})를 찾을 수 없습니다.`);
  const mirrorDir = path.join(extRoot, m.dir);
  await assertNotLinkAsync(mirrorDir);
  const keyId = mirrorKeyId(key);
  const markerPath = path.join(mirrorDir, m.marker);
  const marker = await readJsonAsync(markerPath, null);
  if ((await exists(mirrorDir)) && marker?.keyId !== keyId) {
    if (!marker && (await fsp.readdir(mirrorDir)).length > 0) {
      throw new Error(`${mirrorDir} 폴더에 다른 파일이 들어 있어 ${m.label}을(를) 백업하지 않습니다.`);
    }
    if (marker) log.warn?.(`[backup] ${m.label} 미러 키가 바뀌어 ${m.label} 백업을 새로 만듭니다.`);
    await fsp.rm(mirrorDir, { recursive: true, force: true, maxRetries: 3 });
  }
  await fsp.mkdir(mirrorDir, { recursive: true });
  if (!(await exists(markerPath))) await writeJsonAtomicAsync(markerPath, { app: 'TangoTalk', keyId });

  const indexPath = path.join(mirrorDir, MIRROR_INDEX);
  const index = (await readJsonAsync(indexPath, null))?.files ?? {};
  const sources = await walkFiles(sourceDir);
  const seen = new Set();
  let copied = 0;
  let bytes = 0;
  let sinceSave = 0;
  onProgress(0, sources.length);
  for (let i = 0; i < sources.length; i++) {
    const { rel, full } = sources[i];
    seen.add(rel);
    let st;
    try {
      st = await fsp.stat(full);
    } catch {
      continue; // 훑은 뒤 지워진 파일 — 다음 백업에서 정리된다.
    }
    bytes += st.size;
    const target = path.join(mirrorDir, ...`${rel}.enc`.split('/'));
    const known = index[rel];
    if (known && known.size === st.size && known.mtimeMs === Math.trunc(st.mtimeMs) && (await exists(target))) {
      if (i % 200 === 0) onProgress(i, sources.length);
      continue;
    }
    await fsp.mkdir(path.dirname(target), { recursive: true });
    const tmp = `${target}.tmp`;
    await pipeline(fs.createReadStream(full), createEncryptStream(key, `${m.context}:${rel}`), fs.createWriteStream(tmp));
    await fsp.rename(tmp, target);
    index[rel] = { size: st.size, mtimeMs: Math.trunc(st.mtimeMs) };
    copied++;
    // 첨부파일이 많으면 오래 걸린다 — 중간에 끊겨도 다음 백업이 처음부터 다시 보내지 않게 색인을 자주 저장한다.
    if (++sinceSave >= 200) {
      await writeJsonAtomicAsync(indexPath, { files: index });
      sinceSave = 0;
    }
    onProgress(i + 1, sources.length);
  }

  const gone = Object.keys(index).filter((rel) => !seen.has(rel));
  let deleted = 0;
  let deletionSkipped = 0;
  const indexed = Object.keys(index).length;
  if (gone.length >= MASS_DELETE_MIN && gone.length > indexed * MASS_DELETE_RATIO) {
    deletionSkipped = gone.length;
  } else {
    for (const rel of gone) {
      if (isSafeRelativePath(rel)) {
        await fsp.rm(path.join(mirrorDir, ...`${rel}.enc`.split('/')), { force: true });
      }
      delete index[rel];
      deleted++;
    }
  }
  await writeJsonAtomicAsync(indexPath, { files: index });
  onProgress(sources.length, sources.length);
  return { total: sources.length, copied, deleted, deletionSkipped, bytes };
}

/** 첨부파일 미러(예전 이름 — mirrorFolder의 'uploads'). */
export const mirrorUploads = (opts) => mirrorFolder({ ...opts, kind: 'uploads' });

/** 백업 폴더의 상태 파일(마지막 결과) — 서버와 시작 메뉴 "백업"이 함께 쓰고, 관리자 콘솔이 읽는다. */
export function readBackupStatus(root) {
  return readJson(path.join(root, STATUS_FILE), {});
}

export function writeBackupStatus(root, status) {
  writeJsonAtomic(path.join(root, STATUS_FILE), status);
}

/** [hour]시 정각 중 [nowMs] 다음으로 오는 시각(이 PC 시각 기준). */
export function nextRunAt(nowMs, hour) {
  const next = new Date(nowMs);
  next.setHours(hour, 0, 0, 0);
  if (next.getTime() <= nowMs) next.setDate(next.getDate() + 1);
  return next.getTime();
}

/** 마지막 성공이 이보다 오래됐으면 서버를 켤 때 놓친 백업을 바로(조금 뒤) 한다. */
export const OVERDUE_MS = 26 * 60 * 60 * 1000;

export function isBackupOverdue(lastSuccessAt, nowMs) {
  return !lastSuccessAt || nowMs - lastSuccessAt > OVERDUE_MS;
}

function isInside(child, parent, win) {
  const norm = (p) => {
    const r = path.resolve(p);
    return win ? r.toLowerCase() : r;
  };
  const rel = path.relative(norm(parent), norm(child));
  return rel === '' || (!rel.startsWith('..') && !path.isAbsolute(rel));
}

/**
 * 관리자가 넣은 외부 백업 위치를 검사한다 — 빈 글이면 { path: null }(끄기). Windows는 드라이브 경로(E:\백업)나 NAS 공유
 * 폴더(\\NAS\공유\폴더)만 받는다. NAS 경로는 [isLocalRequest](이 서버 PC에서 연 관리자 콘솔)일 때만 받는다 — 서버(SYSTEM)가
 * 그 주소로 접속하면서 이 PC의 컴퓨터 계정 로그인 정보(NTLM)를 넘기므로, 밖에서 운영자 계정만 훔친 사람이 자기 서버 주소를
 * 넣어 그 정보를 받아 가지 못하게. 서버 폴더·첨부파일 폴더·이 PC 백업 폴더·Windows 폴더 안은 받지 않는다.
 */
export function checkBackupDestination(raw, { platform = process.platform, isLocalRequest = false, protectedDirs = [] } = {}) {
  if (raw == null) return { path: null };
  if (typeof raw !== 'string') return { error: '외부 백업 위치는 글자로 넣어야 합니다.' };
  let value = raw.trim();
  if (!value) return { path: null };
  if (value.length > 240) return { error: '외부 백업 위치가 너무 깁니다.' };
  const win = platform === 'win32';
  const p = win ? path.win32 : path.posix;
  if (win) {
    value = value.replace(/\//g, '\\');
    const unc = /^\\\\[^\\]+\\[^\\]+/.test(value);
    const drive = /^[A-Za-z]:\\/.test(value);
    if (value.startsWith('\\\\?\\') || value.startsWith('\\\\.\\') || (!unc && !drive)) {
      return { error: '외부 백업 위치는 E:\\TangoTalk백업 같은 드라이브 경로나 \\\\NAS\\공유\\폴더 같은 공유 폴더 경로로 넣으세요.' };
    }
    if (/[<>"|?*\x00-\x1f]/.test(value) || value.indexOf(':', 2) !== -1) {
      return { error: '외부 백업 위치에 쓸 수 없는 글자가 있습니다.' };
    }
    if (value.split('\\').some((s) => s === '..' || s === '.')) return { error: '외부 백업 위치에 . 이나 .. 은 쓸 수 없습니다.' };
    if (unc && !isLocalRequest) {
      return {
        error: 'NAS 같은 공유 폴더(\\\\…) 경로는 보안상 서버 PC에서 연 관리자 콘솔에서만 정할 수 있습니다. 외장 드라이브(E:\\…)는 어디서든 정할 수 있습니다.',
      };
    }
    value = p.normalize(value);
    if (value.length > 3) value = value.replace(/\\+$/, '');
  } else {
    if (!p.isAbsolute(value)) return { error: '외부 백업 위치는 절대 경로로 넣으세요.' };
    if (value.split('/').some((s) => s === '..')) return { error: '외부 백업 위치에 .. 은 쓸 수 없습니다.' };
    value = p.normalize(value);
    if (value.length > 1) value = value.replace(/\/+$/, '');
  }
  const target = p.join(value, EXTERNAL_DIR_NAME);
  for (const dir of protectedDirs.filter(Boolean)) {
    if (isInside(target, dir, win)) {
      return { error: '서버 폴더·첨부파일 폴더·이 PC의 백업 폴더 안은 외부 백업 위치로 쓸 수 없습니다 — 다른 드라이브나 NAS를 고르세요.' };
    }
  }
  return { path: value };
}

/** Windows에서 두 경로가 같은 드라이브(문자)인지 — 같으면 디스크 고장에 대비되지 않는다고 알린다. */
export function sameDrive(a, b, platform = process.platform) {
  if (platform !== 'win32' || !a || !b) return false;
  const letter = (p) => (/^[A-Za-z]:/.test(p) ? p[0].toLowerCase() : null);
  return letter(a) !== null && letter(a) === letter(b);
}

/**
 * 매일 [hour]시 예약 백업. [loadSettings]는 { enabled, hour, ready(암호가 있어 돌릴 수 있는지) }를, [lastSuccessAt]은 마지막
 * 성공 시각을 준다. 서버를 켤 때 [start] — 마지막 성공이 하루 넘게 지났으면(서버가 꺼져 있어 놓쳤으면) 조금 뒤에 한 번
 * 돌린다. 설정이 바뀌면 [reschedule]. [run]이 실패해도(외부 위치가 꺼져 있었거나, 시작 메뉴 "백업"이 돌던 중) 다음 날 다시
 * 한다. [setTimer]·[clearTimer]·[now]는 시험용.
 */
export function createBackupScheduler({
  loadSettings,
  run,
  lastSuccessAt = () => null,
  now = () => Date.now(),
  catchUpDelayMs = 10 * 60 * 1000,
  setTimer = (fn, ms) => {
    const handle = setTimeout(fn, ms);
    handle.unref?.();
    return handle;
  },
  clearTimer = (handle) => clearTimeout(handle),
  log = console,
}) {
  let timer = null;
  let nextAt = null;
  let stopped = true;
  let generation = 0;

  function clear() {
    if (timer) clearTimer(timer);
    timer = null;
    nextAt = null;
  }

  async function reschedule({ catchUp = false } = {}) {
    const mine = ++generation;
    clear();
    let settings;
    try {
      settings = await loadSettings();
    } catch (e) {
      log.error?.('[backup] 설정을 읽지 못해 예약하지 않았습니다:', e?.message ?? e);
      return;
    }
    // 설정을 읽는 사이 다시 예약됐으면(설정을 연달아 바꿈) 늦게 끝난 이쪽은 손대지 않는다.
    if (mine !== generation || stopped || !settings.enabled || !settings.ready) return;
    let at = nextRunAt(now(), settings.hour);
    if (catchUp && isBackupOverdue(lastSuccessAt(), now())) at = Math.min(at, now() + catchUpDelayMs);
    nextAt = at;
    timer = setTimer(fire, Math.max(at - now(), 1000));
  }

  async function fire() {
    timer = null;
    nextAt = null;
    try {
      await run('scheduled');
    } catch (e) {
      log.warn?.(`[backup] 예약 백업 실패: ${e?.message ?? e}`);
    }
    if (!stopped) await reschedule();
  }

  return {
    start: () => {
      stopped = false;
      return reschedule({ catchUp: true });
    },
    reschedule: () => (stopped ? Promise.resolve() : reschedule()),
    stop: () => {
      stopped = true;
      generation++;
      clear();
    },
    nextRunAt: () => nextAt,
  };
}

/** 관리자 콘솔에 보일 경고들 — 지금 상태와 설정에서 계산한다(외부 위치에 직접 묻지 않는다 — 꺼진 NAS는 오래 기다리게 한다). */
export function backupWarnings(settings, status, { localRoot, nowMs = Date.now() } = {}) {
  const warnings = [];
  if (!settings.password) {
    warnings.push(settings.passwordError ?? '백업 암호를 정하지 않아 백업하지 않고 있습니다.');
    return warnings;
  }
  if (!settings.enabled) warnings.push('자동 백업이 꺼져 있습니다.');
  if (!settings.destination) {
    warnings.push('외부 백업 위치(NAS·외장 드라이브)를 정하지 않았습니다 — 이 PC의 디스크가 고장 나면 백업도 함께 사라지고, 첨부파일은 백업되지 않습니다.');
  } else if (sameDrive(settings.destination, localRoot)) {
    warnings.push('외부 백업 위치가 서버와 같은 드라이브에 있습니다 — 디스크 고장에 대비하려면 다른 드라이브나 NAS를 고르세요.');
  }
  if (status.lastSuccessAt && nowMs - status.lastSuccessAt > 3 * 24 * 60 * 60 * 1000) {
    warnings.push('마지막으로 성공한 백업이 사흘 넘게 지났습니다.');
  }
  const skipped = status.external?.uploads?.deletionSkipped;
  if (skipped) {
    warnings.push(`첨부파일 ${skipped}개가 한꺼번에 사라져 외부 백업에서는 지우지 않았습니다 — 첨부파일 저장소를 확인하세요.`);
  }
  return warnings;
}

/**
 * 이 서버 PC에서 온 요청인지 — 외부 백업 위치를 NAS 경로로 정하는 것을 이때만 받는다(backup.js checkBackupDestination).
 * 서버 PC의 앱은 보통 127.0.0.1이 아니라 이 PC의 사내망 주소로 붙으므로, 그 주소들도 이 PC로 친다(사내망의 다른 PC는
 * 같은 주소를 쓸 수 없다). 공유기 포트포워딩으로 밖에서 온 요청은 밖의 주소다.
 */
export function isRequestFromThisPc(req, interfaces = os.networkInterfaces()) {
  const ip = String(req.socket?.remoteAddress ?? '').replace(/^::ffff:/, '');
  if (ip === '127.0.0.1' || ip === '::1') return true;
  return Object.values(interfaces)
    .flat()
    .some((i) => i && i.address.replace(/%.*$/, '') === ip.replace(/%.*$/, ''));
}
