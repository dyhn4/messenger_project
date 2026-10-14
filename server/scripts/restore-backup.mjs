// 시작 메뉴 "복원"(installer/Restore-Data.ps1)이 부르는 전체 백업 복원 — 관리자 콘솔·시작 메뉴 "백업"이 만든 백업 폴더
// (tangotalk_<날짜>_<시각>, src/backup.js)를 이 서버로 되돌린다. 같은 PC로 되돌리는 것과, PC가 고장 나 새 PC에 서버를 새로 설치한
// 뒤 되살리는 것 둘 다 이것으로 한다. **서버 서비스를 멈춘 채로** 부른다(Restore-Data.ps1이 멈추고 다시 켠다).
//
//   node scripts/restore-backup.mjs check <백업 폴더>
//       암호 없이 볼 수 있는 것만 — 백업 정보, 이 서버로 복원할 수 있는지, 첨부파일 백업이 옆에 있는지, 지금 DB에 회원이 있는지를
//       JSON 한 줄로. (회원이 없는 새 설치면 Restore-Data.ps1이 운영자 확인을 건너뛴다 — 확인할 운영자가 없다.)
//   node scripts/restore-backup.mjs verify <백업 폴더>          ← stdin: 백업 암호
//       암호만 맞춰 본다(0 맞음, 2 틀림).
//   node scripts/restore-backup.mjs restore <백업 폴더> [--no-uploads]   ← stdin: 백업 암호
//       1) 지금 DB에 회원이 있으면 먼저 지금 DB를 backups\before-restore_<시각>.dump로 떠 둔다(복원이 잘못됐을 때 예전 "복원"으로
//          되돌릴 수 있게 — 최근 3개만 남긴다).
//       2) DB: 지금 DB의 객체를 모두 지우고 백업을 넣는 것을 **트랜잭션 하나로** 한다(psql -1) — 중간에 실패하면 DB는 그대로다.
//          예전 "복원"(pg_restore --clean)은 실패하면 일부만 반영된 채로 남았고, 옛 백업에 없는 표(그 뒤 마이그레이션이 만든 것)가
//          남아 마이그레이션이 다시 돌며 부딪혔다.
//       3) 비밀값·인증서: DB 암호화 키·JWT 비밀값·웹 푸시 키·서버 인증서(certs)를 백업 것으로 되돌리고, .env는 이 PC 값(DB 접속·
//          첨부파일 위치·화상회의)을 둔 채 나머지(외부 접속 주소·웹 앱 도메인 등)를 백업 값으로 합친다. 바꾸기 전 파일은
//          backups\before-restore_<시각>-config\에 남긴다.
//       4) 첨부파일: 백업 폴더 옆(TangoTalk-Backup\uploads)에 첨부파일 백업이 있으면 첨부파일 폴더로 풀어 놓는다(이미 있는 파일은
//          그대로 둔다).
//       마이그레이션은 Restore-Data.ps1이 이어서 돌린다(옛 백업이면 지금 코드에 맞게 올린다).
//
// 종료 코드: 0 성공 · 2 백업 암호가 틀림 · 3 이 서버로 복원할 수 없는 백업(더 새 서버의 것 등) · 1 그 밖의 실패.
// 암호는 명령줄 인자가 아니라 stdin(UTF-8)으로만 받는다 — verify-admin.mjs와 같은 규칙(맨 앞 BOM 하나·맨 끝 줄바꿈 하나만 뗀다).
import 'dotenv/config';
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { pipeline } from 'node:stream/promises';
import pg from 'pg';
import { assertNotLink, DB_FILE } from '../src/backup.js';
import {
  BackupPasswordError,
  checkMigrationCompat,
  decryptFileTo,
  findMirrorFor,
  mergeEnv,
  openBackup,
  readManifest,
  readSecretsBundle,
  RESTORE_PRELUDE_SQL,
  restoreMirror,
  secretTarget,
} from '../src/backupRestore.js';
import { backupPaths, migrationInfo, pgConnection, pgTool, waitForProcess } from '../src/backupService.js';

const [command, backupDirArg, ...flags] = process.argv.slice(2);
const serverDir = backupPaths.serverDir;

function exit(code, message) {
  if (message) (code === 0 ? console.log : console.error)(message);
  process.exit(code);
}

function readStdinBytes() {
  return new Promise((resolve, reject) => {
    const chunks = [];
    process.stdin.on('data', (chunk) => chunks.push(chunk));
    process.stdin.on('end', () => resolve(Buffer.concat(chunks)));
    process.stdin.on('error', reject);
  });
}

async function readPassword() {
  try {
    return new TextDecoder('utf-8', { fatal: true }).decode(await readStdinBytes()).replace(/\r?\n$/, '');
  } catch {
    return null;
  }
}

/** 지금 DB의 회원 수 — users 표가 없으면(마이그레이션 전) 0. */
async function countUsers() {
  const client = new pg.Client({ connectionString: process.env.DATABASE_URL });
  try {
    await client.connect();
    const { rows } = await client.query("SELECT to_regclass('public.users') IS NOT NULL AS has");
    if (!rows[0]?.has) return 0;
    const result = await client.query('SELECT count(*)::int AS n FROM users');
    return result.rows[0].n;
  } finally {
    await client.end().catch(() => {});
  }
}

const stamp = () => {
  const d = new Date();
  const p = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}_${p(d.getHours())}${p(d.getMinutes())}${p(d.getSeconds())}`;
};

/** 복원 전 지금 DB를 평문 덤프로(예전 "백업"과 같은 형식 — 예전 "복원"으로 되돌릴 수 있다). 최근 3개만 남긴다. */
async function dumpCurrentDb(root, name) {
  const target = path.join(root, `before-restore_${name}.dump`);
  const { args, env } = pgConnection();
  const child = spawn(pgTool('pg_dump'), ['--format=custom', '--no-password', '-f', target, ...args], {
    env,
    windowsHide: true,
    stdio: ['ignore', 'ignore', 'pipe'],
  });
  await waitForProcess(child, 'pg_dump');
  const old = fs
    .readdirSync(root)
    .filter((f) => /^before-restore_\d{8}_\d{6}\.dump$/.test(f))
    .sort()
    .reverse()
    .slice(3);
  for (const f of old) fs.rmSync(path.join(root, f), { force: true });
  return target;
}

/** 지금 DB의 객체를 모두 지우고(RESTORE_PRELUDE_SQL) 백업을 넣는다 — 한 트랜잭션(psql -1, 오류에서 멈춤). */
async function restoreDatabase(dumpFile) {
  const { args, env } = pgConnection();
  const prelude = RESTORE_PRELUDE_SQL;
  const restore = spawn(pgTool('pg_restore'), ['--no-owner', '--no-privileges', '-f', '-', dumpFile], {
    windowsHide: true,
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  const psql = spawn(pgTool('psql'), ['-X', '-q', '--no-password', '-v', 'ON_ERROR_STOP=1', '-1', '-f', '-', ...args], {
    env,
    windowsHide: true,
    stdio: ['pipe', 'ignore', 'pipe'],
  });
  const restoreDone = waitForProcess(restore, 'pg_restore');
  const psqlDone = waitForProcess(psql, 'psql');
  psql.stdin.write(prelude);
  const piped = pipeline(restore.stdout, psql.stdin);
  const results = await Promise.allSettled([restoreDone, psqlDone, piped]);
  // psql이 먼저 실패해 멈추면 파이프가 끊긴다(EPIPE) — 그보다 psql·pg_restore가 알려 준 이유를 먼저 보인다.
  for (const r of results) if (r.status === 'rejected') throw r.reason;
}

/** 비밀값·인증서·.env를 되돌린다 — 바꾸기 전 파일은 [saveDir]에 남긴다. 되돌린 이름들과 .env 안내를 돌려준다. */
function restoreSecrets(bundle, saveDir) {
  fs.mkdirSync(path.join(saveDir, 'certs'), { recursive: true });
  const restored = [];
  let env = null;
  const certsInBackup = Object.keys(bundle.files).some((name) => secretTarget(name)?.startsWith('certs/'));
  for (const [name, content] of Object.entries(bundle.files)) {
    const target = secretTarget(name);
    if (!target) continue;
    if (target === 'env') {
      const envPath = path.join(serverDir, '.env');
      const current = fs.existsSync(envPath) ? fs.readFileSync(envPath, 'utf8') : '';
      if (current) fs.writeFileSync(path.join(saveDir, '.env'), current);
      env = mergeEnv(current, content.toString('utf8'));
      fs.writeFileSync(envPath, env.text);
      restored.push('.env');
      continue;
    }
    const full = path.join(serverDir, ...target.split('/'));
    if (fs.existsSync(full)) fs.copyFileSync(full, path.join(saveDir, ...target.split('/')));
    fs.mkdirSync(path.dirname(full), { recursive: true });
    fs.writeFileSync(full, content);
    restored.push(target);
  }
  // 백업에 인증서가 있으면, 백업에 없던 웹 인증서 등(새 PC가 받은 것)은 치운다 — 섞이면 다른 도메인의 인증서가 남는다.
  if (certsInBackup && fs.existsSync(backupPaths.certsDir)) {
    const keep = new Set(restored.filter((t) => t.startsWith('certs/')).map((t) => t.slice('certs/'.length)));
    for (const entry of fs.readdirSync(backupPaths.certsDir, { withFileTypes: true })) {
      if (entry.isFile() && !keep.has(entry.name)) {
        fs.renameSync(path.join(backupPaths.certsDir, entry.name), path.join(saveDir, 'certs', entry.name));
      }
    }
  }
  return { restored, env };
}

async function main() {
  if (!['check', 'verify', 'restore'].includes(command) || !backupDirArg) {
    exit(1, '사용법: node scripts/restore-backup.mjs check|verify|restore <백업 폴더> [--no-uploads]');
  }
  const backupDir = path.resolve(backupDirArg);
  let manifest;
  try {
    manifest = readManifest(backupDir);
  } catch (e) {
    exit(3, e.message);
  }
  const compat = checkMigrationCompat(manifest, migrationInfo().count);

  if (command === 'check') {
    let users = null;
    try {
      users = await countUsers();
    } catch {
      users = null;
    }
    console.log(
      JSON.stringify({
        name: manifest.name,
        createdAt: manifest.createdAt,
        host: manifest.host ?? null,
        kind: manifest.kind ?? null,
        compatible: compat.ok,
        compatError: compat.error ?? null,
        mirror: findMirrorFor(backupDir),
        users,
      }),
    );
    exit(0);
  }

  const password = await readPassword();
  if (password === null) exit(2, '백업 암호를 읽지 못했습니다.');
  let key;
  try {
    ({ key } = await openBackup(backupDir, password));
  } catch (e) {
    exit(e instanceof BackupPasswordError ? 2 : 1, e.message);
  }
  if (command === 'verify') exit(0, '백업 암호가 맞습니다.');
  if (!compat.ok) exit(3, compat.error);

  const root = backupPaths.localRoot;
  assertNotLink(root);
  fs.mkdirSync(root, { recursive: true });
  assertNotLink(root);
  const name = stamp();

  // 비밀값 묶음을 먼저 풀어 본다 — 못 풀면 DB를 건드리기 전에 멈춘다.
  const bundle = readSecretsBundle(backupDir, key);

  if ((await countUsers().catch(() => 0)) > 0) {
    console.log('- 지금 DB를 먼저 떠 두는 중...');
    const saved = await dumpCurrentDb(root, name);
    console.log(`  ${saved}`);
  }

  console.log('- DB 복원 중...');
  const tmpDir = path.join(root, `.restore-${name}`);
  fs.mkdirSync(tmpDir);
  try {
    const dumpFile = path.join(tmpDir, 'db.dump');
    await decryptFileTo(path.join(backupDir, DB_FILE), dumpFile, key, 'db');
    await restoreDatabase(dumpFile);
  } finally {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }

  console.log('- 설정·인증서 복원 중...');
  const saveDir = path.join(root, `before-restore_${name}-config`);
  const { restored, env } = restoreSecrets(bundle, saveDir);
  console.log(`  ${restored.join(', ') || '(없음)'}`);
  console.log(`  바꾸기 전 파일: ${saveDir}`);

  const warnings = [];
  for (const change of env?.portChanges ?? []) {
    warnings.push(
      `${change.key}가 ${change.from ?? '(기본값)'} → ${change.to}(으)로 바뀌었습니다 — 방화벽과 공유기 포트포워딩도 이 번호로 맞추세요.`,
    );
  }

  if (!flags.includes('--no-uploads')) {
    const mirrorDir = findMirrorFor(backupDir);
    if (!mirrorDir) {
      warnings.push('백업 폴더 옆에 첨부파일 백업(uploads)이 없어 첨부파일은 복원하지 않았습니다 — 같은 PC라면 첨부파일은 그대로 있습니다.');
    } else if (!bundle.mirrorKey) {
      warnings.push('이 백업에는 첨부파일 키가 없어 첨부파일은 복원하지 않았습니다.');
    } else {
      const uploadsDir = process.env.UPLOADS_DIR || path.join(serverDir, 'uploads');
      console.log(`- 첨부파일 복원 중... (${uploadsDir})`);
      let last = 0;
      const result = await restoreMirror({
        mirrorDir,
        key: bundle.mirrorKey,
        targetDir: uploadsDir,
        onProgress: (done, total) => {
          if (done === total || Date.now() - last > 2000) {
            last = Date.now();
            console.log(`  ${done}/${total}`);
          }
        },
      }).catch((e) => {
        warnings.push(e.message);
        return null;
      });
      if (result) {
        console.log(`  새로 풀어 놓음 ${result.restored}개, 이미 있음 ${result.skipped}개`);
        if (result.failed.length) warnings.push(`첨부파일 ${result.failed.length}개는 복원하지 못했습니다(손상되었거나 이름이 잘못됨).`);
      }
    }
  }

  console.log('');
  console.log(`복원 완료: ${manifest.name} (${manifest.createdAt}${manifest.host ? `, ${manifest.host}` : ''})`);
  for (const w of warnings) console.log(`주의: ${w}`);
  exit(0);
}

main().catch((e) => exit(1, `복원 실패: ${e?.message ?? e}`));
