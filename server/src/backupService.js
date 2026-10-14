import { spawn } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  acquireBackupLock,
  assertNotLink,
  BackupBusyError,
  copyBackupsTo,
  createBackup,
  createBackupScheduler,
  listBackups,
  mirrorUploads,
  prepareExternalRoot,
  pruneBackups,
  readBackupStatus,
  writeBackupStatus,
} from './backup.js';
import { UPLOADS_DIR } from './config.js';
import { decryptField, encryptField } from './crypto.js';
import { sql } from 'drizzle-orm';
import { db } from './db/client.js';
import { getServerSettings, updateServerSettings } from './db/queries/serverSettings.js';

/**
 * 서버 전체 백업을 이 서버에 잇는다(backup.js는 DB를 모른다) — 설정은 DB(server_settings)에, 결과는 백업 폴더의
 * backup-status.json에 둔다. 서버(index.js)는 [backupScheduler]로 매일 예약 백업을 돌리고, 관리자 콘솔(admin.js)은
 * [startBackup]·[backupRunState]로 "지금 백업"과 진행 상황을 본다. 시작 메뉴 "백업"(scripts/backup-now.mjs)은 따로 뜬
 * node에서 [performBackup]을 부른다 — 둘이 겹치지 않게 백업 폴더의 잠금 파일로 막는다(backup.js acquireBackupLock).
 */

const serverDir = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const appDir = path.dirname(serverDir);
/** 설치 프로그램으로 깐 서버인지 — {app}\pgsql\bin(번들 PostgreSQL)이 있으면. 개발 PC는 server 폴더 그대로 쓴다. */
const installed = fs.existsSync(path.join(appDir, 'pgsql', 'bin'));

export const backupPaths = Object.freeze({
  serverDir,
  /** 지우면 안 되는 서버 폴더(외부 위치로 고를 수 없다) — 설치본은 설치 폴더 전체. */
  installDir: installed ? appDir : serverDir,
  /**
   * 이 PC의 백업 폴더 — 설치본은 {app}\backups(설치 폴더째 관리자 전용으로 잠겨 있다 — Folder-Acl.ps1, 시작 메뉴 "백업"이
   * 쓰던 곳과 같다). BACKUP_DIR로 바꿀 수 있다.
   */
  localRoot: process.env.BACKUP_DIR || (installed ? path.join(appDir, 'backups') : path.join(serverDir, 'backups')),
  /** pg_dump·pg_restore·psql이 있는 폴더 — 설치본은 번들 PostgreSQL, 아니면 PATH(PG_BIN으로 정할 수 있다). */
  pgBin: process.env.PG_BIN || (installed ? path.join(appDir, 'pgsql', 'bin') : null),
  certsDir: path.join(serverDir, 'certs'),
  uploadsDir: UPLOADS_DIR,
  migrationsJournal: path.join(serverDir, 'drizzle', 'meta', '_journal.json'),
});

/** PostgreSQL 도구의 실행 경로. */
export function pgTool(name) {
  const exe = process.platform === 'win32' ? `${name}.exe` : name;
  return backupPaths.pgBin ? path.join(backupPaths.pgBin, exe) : exe;
}

/**
 * DATABASE_URL을 pg 도구의 인자와 환경 변수로 — 비밀번호는 명령줄(이 PC의 다른 계정도 프로세스 목록에서 볼 수 있다)이 아니라
 * PGPASSWORD로만 넘긴다.
 */
export function pgConnection(databaseUrl = process.env.DATABASE_URL) {
  if (!databaseUrl) throw new Error('DATABASE_URL이 없습니다.');
  const url = new URL(databaseUrl);
  const host = url.hostname.replace(/^\[(.*)\]$/, '$1') || 'localhost';
  const args = ['-h', host, '-p', url.port || '5432', '-U', decodeURIComponent(url.username), '-d', decodeURIComponent(url.pathname.slice(1))];
  const env = { ...process.env, PGPASSWORD: decodeURIComponent(url.password) };
  const sslmode = url.searchParams.get('sslmode');
  if (sslmode) env.PGSSLMODE = sslmode;
  return { args, env };
}

/** 자식 프로세스가 끝나기를 기다린다 — 실패면 stderr 끝부분을 담아 거절. */
export function waitForProcess(child, label) {
  let stderr = '';
  child.stderr?.on('data', (d) => {
    stderr = (stderr + d.toString()).slice(-4000);
  });
  return new Promise((resolve, reject) => {
    child.on('error', (e) =>
      reject(new Error(`${label}을(를) 실행하지 못했습니다 — ${e.code === 'ENOENT' ? '프로그램을 찾을 수 없습니다' : e.message}`)),
    );
    child.on('close', (code) =>
      code === 0 ? resolve() : reject(new Error(`${label} 실패(종료 코드 ${code})${stderr.trim() ? `: ${stderr.trim()}` : ''}`)),
    );
  });
}

/** pg_dump -F c를 띄워 그 출력을 준다(backup.js createBackup의 dumpDb). */
function dumpDatabase() {
  const { args, env } = pgConnection();
  const child = spawn(pgTool('pg_dump'), ['--format=custom', '--no-password', ...args], {
    env,
    windowsHide: true,
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  return { stream: child.stdout, done: waitForProcess(child, 'pg_dump') };
}

/** 백업에 넣는 비밀값 파일들 — 복원할 때 정해 둔 자리에만 되돌린다(backupRestore.js secretTarget). */
function secretFiles() {
  const files = ['.env', '.jwt-secret', '.db-encryption-key', '.web-push-vapid.json', 'firebase-service-account.json'].map((name) => ({
    name: `server/${name}`,
    path: path.join(serverDir, name),
  }));
  try {
    for (const entry of fs.readdirSync(backupPaths.certsDir, { withFileTypes: true })) {
      if (entry.isFile()) files.push({ name: `server/certs/${entry.name}`, path: path.join(backupPaths.certsDir, entry.name) });
    }
  } catch {
    // 인증서 폴더가 아직 없다(서버를 한 번도 안 띄움) — 없는 대로 백업한다.
  }
  return files;
}

/** 코드가 아는 마이그레이션 — 복원할 때 "더 새 서버의 백업"을 막는 데 쓴다(backupRestore.js checkMigrationCompat). */
export function migrationInfo() {
  try {
    const entries = JSON.parse(fs.readFileSync(backupPaths.migrationsJournal, 'utf8')).entries ?? [];
    return { count: entries.length, last: entries.at(-1)?.tag ?? null };
  } catch {
    return { count: null, last: null };
  }
}

/**
 * 백업하는 DB에 실제로 적용된 마이그레이션 — 코드가 아는 수(migrationInfo)와 다를 수 있다(코드만 먼저 받고 db:migrate를 안 한
 * 개발 PC). 복원할 때는 이 수와 받는 서버 코드의 수를 견준다. 못 읽으면 코드 기준으로.
 */
async function appliedMigrationInfo() {
  try {
    const rows = await db.execute(sql`select count(*)::int as n from drizzle.__drizzle_migrations`);
    const n = (rows.rows ?? rows)[0]?.n;
    if (Number.isInteger(n)) return { count: n, last: null, code: migrationInfo().count };
  } catch {
    // 원장이 없다 — 아래.
  }
  return migrationInfo();
}

/** DB의 백업 설정 — 암호와 미러 키는 여기서만 풀어 쓴다. */
export async function loadBackupSettings() {
  const s = await getServerSettings();
  let password = null;
  let passwordError = null;
  if (s.backupPassword) {
    try {
      password = decryptField(s.backupPassword);
    } catch {
      // DB 암호화 키(server/.db-encryption-key)가 바뀐 채 DB만 복원한 경우 등 — 암호를 다시 정하면 된다.
      passwordError = '저장된 백업 암호를 읽지 못했습니다 — 관리자 콘솔에서 백업 암호를 다시 정하세요.';
    }
  }
  let mirrorKey = null;
  if (s.backupMirrorKey) {
    try {
      const key = Buffer.from(decryptField(s.backupMirrorKey), 'base64');
      if (key.length === 32) mirrorKey = key;
    } catch {
      // 못 읽으면 새로 만든다 — 외부 위치의 첨부파일 백업은 새 키로 다시 만들어진다(backup.js mirrorUploads).
    }
  }
  return {
    enabled: s.backupEnabled !== false,
    hour: Number.isInteger(s.backupHour) ? s.backupHour : 3,
    keep: Number.isInteger(s.backupKeep) ? s.backupKeep : 14,
    destination: s.backupDestination || null,
    password,
    passwordError,
    mirrorKey,
    ready: !!password,
  };
}

async function ensureMirrorKey(settings) {
  if (settings.mirrorKey) return settings.mirrorKey;
  const key = crypto.randomBytes(32);
  await updateServerSettings({ backupMirrorKey: encryptField(key.toString('base64')) });
  return key;
}

function ensureLocalRoot() {
  assertNotLink(backupPaths.localRoot);
  fs.mkdirSync(backupPaths.localRoot, { recursive: true });
  assertNotLink(backupPaths.localRoot);
}

/**
 * 백업 한 번 — 이 PC의 백업 폴더에 만들고 오래된 것을 정리한 뒤, 외부 위치를 정했으면 그곳에 복사하고 첨부파일을 맞춘다.
 * 외부 위치에서만 실패하면 이 PC의 백업은 남기고 결과를 'partial'로 적는다. 결과는 backup-status.json에 남긴다.
 * [owner]는 잠금 파일에 적는 이름('server' | 'script'), [onPhase]·[onProgress]는 진행 상황.
 */
export async function performBackup({ kind, owner = 'server', onPhase = () => {}, onProgress = () => {} }) {
  const settings = await loadBackupSettings();
  if (settings.passwordError) throw new Error(settings.passwordError);
  if (!settings.password) throw new Error('백업 암호를 먼저 정하세요 — 관리자 콘솔 "백업" 탭.');
  ensureLocalRoot();
  const root = backupPaths.localRoot;
  const release = acquireBackupLock(root, { owner });
  const previous = readBackupStatus(root);
  const startedAt = Date.now();
  try {
    const mirrorKey = await ensureMirrorKey(settings);
    const created = await createBackup({
      root,
      password: settings.password,
      kind,
      dumpDb: dumpDatabase,
      secretFiles: secretFiles(),
      mirrorKey,
      info: { host: os.hostname(), migrations: await appliedMigrationInfo() },
      onPhase,
    });
    await pruneBackups(root, settings.keep);

    let external = null;
    if (settings.destination) {
      external = { path: settings.destination, ok: false, error: null, uploads: null, at: null };
      try {
        const extRoot = await prepareExternalRoot(settings.destination);
        onPhase('외부 위치로 복사 중');
        await copyBackupsTo(root, extRoot, settings.keep);
        onPhase('첨부파일 복사 중');
        external.uploads = await mirrorUploads({
          sourceDir: backupPaths.uploadsDir,
          extRoot,
          key: mirrorKey,
          onProgress,
        });
        await pruneBackups(extRoot, settings.keep);
        Object.assign(external, { ok: true, at: Date.now() });
      } catch (e) {
        external.error = e?.message ?? String(e);
      }
    }
    const status = {
      lastAttemptAt: startedAt,
      lastFinishedAt: Date.now(),
      lastSuccessAt: Date.now(),
      result: external && !external.ok ? 'partial' : 'ok',
      error: external?.error ?? null,
      lastBackup: { name: created.name, kind, bytes: created.bytes },
      // 외부 위치에 마지막으로 성공한 때는 실패해도 남겨 둔다("마지막 외부 복사: 사흘 전" 경고에 쓴다).
      external: external ? { ...external, lastOkAt: external.ok ? external.at : (previous.external?.lastOkAt ?? null) } : null,
    };
    writeBackupStatus(root, status);
    return status;
  } catch (e) {
    try {
      writeBackupStatus(root, {
        ...previous,
        lastAttemptAt: startedAt,
        lastFinishedAt: Date.now(),
        result: 'failed',
        error: e?.message ?? String(e),
      });
    } catch {
      // 상태를 못 남겨도 원래 오류를 알린다.
    }
    throw e;
  } finally {
    release();
  }
}

/** 지금 이 서버에서 돌고 있는 백업(관리자 콘솔의 진행 표시). 시작 메뉴 "백업"은 잠금 파일로만 보인다. */
const run = { promise: null, kind: null, phase: null, progress: null, startedAt: null };

export function backupRunState() {
  return {
    running: !!run.promise,
    kind: run.kind,
    phase: run.phase,
    progress: run.progress,
    startedAt: run.startedAt,
  };
}

/** 백업을 시작한다 — 이미 이 서버에서 돌고 있으면 그것을 돌려준다. 끝까지 기다리지 않아도 된다(실패는 상태 파일에 남는다). */
export function startBackup(kind) {
  if (run.promise) return run.promise;
  Object.assign(run, { kind, phase: '준비 중', progress: null, startedAt: Date.now() });
  run.promise = performBackup({
    kind,
    onPhase: (phase) => {
      run.phase = phase;
      run.progress = null;
    },
    onProgress: (done, total) => {
      run.progress = { done, total };
    },
  })
    .then((status) => {
      if (status.result === 'partial') console.warn(`[backup] 백업은 했지만 외부 위치 복사에 실패했습니다: ${status.error}`);
      else console.log(`[backup] 백업 완료: ${status.lastBackup.name}`);
      return status;
    })
    .catch((e) => {
      if (!(e instanceof BackupBusyError)) console.error(`[backup] 백업 실패: ${e?.message ?? e}`);
      throw e;
    })
    .finally(() => {
      Object.assign(run, { promise: null, kind: null, phase: null, progress: null, startedAt: null });
      backupScheduler.reschedule().catch(() => {});
    });
  return run.promise;
}

/** 서버 전체에서 하나 — index.js가 시작하고, 관리자 콘솔(admin.js)이 설정을 바꾸면 다시 예약한다. */
export const backupScheduler = createBackupScheduler({
  loadSettings: loadBackupSettings,
  run: (kind) => startBackup(kind),
  lastSuccessAt: () => readBackupStatus(backupPaths.localRoot).lastSuccessAt ?? null,
});

/** 관리자 콘솔 "백업" 탭의 목록 — 이 PC의 백업 폴더 것만(외부 위치는 꺼져 있을 수 있어 열지 않는다). */
export async function localBackupList() {
  try {
    return await listBackups(backupPaths.localRoot);
  } catch {
    return [];
  }
}

/**
 * 외부 위치에 실제로 쓸 수 있는지 미리 확인한다 — 설정을 저장하기 전에. 실패하면 사람이 읽을 이유로 던진다. 꺼진 NAS는
 * 한참 기다리게 하므로 비동기로만 본다(그동안 채팅은 그대로 돈다).
 */
export async function probeDestination(dest) {
  const hint =
    'NAS 공유 폴더라면 서버 PC(컴퓨터 계정)에 쓰기 권한이 있어야 합니다 — 안 되면 외장 드라이브를 쓰거나 도움말의 "외부 백업 위치"를 참고하세요.';
  let extRoot;
  try {
    extRoot = await prepareExternalRoot(dest);
  } catch (e) {
    throw new Error(e.code ? `외부 백업 위치에 폴더를 만들지 못했습니다(${e.code}). ${hint}` : e.message);
  }
  const probe = path.join(extRoot, `.write-test-${process.pid}-${Date.now()}`);
  try {
    await fsp.writeFile(probe, 'ok');
  } catch (e) {
    throw new Error(`외부 백업 위치에 쓰지 못했습니다(${e.code ?? e.message}). ${hint}`);
  } finally {
    await fsp.rm(probe, { force: true }).catch(() => {});
  }
  return extRoot;
}

export { BackupBusyError };
