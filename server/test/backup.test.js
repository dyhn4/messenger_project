// 서버 전체 백업(backup.js·backupCrypto.js)과 복원 조각(backupRestore.js) — `node --test test/*.test.js`. DB·pg_dump 없이 돈다
// (pg_dump 출력은 가짜 스트림으로, 폴더는 임시 폴더로). backupService.js는 import하면 DB에 붙으므로 여기서는 쓰지 않는다.
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { Readable } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { afterEach, beforeEach, test } from 'node:test';
import {
  acquireBackupLock,
  backupFolderName,
  backupLockHolder,
  BackupBusyError,
  backupWarnings,
  checkBackupDestination,
  copyBackupsTo,
  createBackup,
  createBackupScheduler,
  DB_FILE,
  EXTERNAL_DIR_NAME,
  isBackupOverdue,
  isRequestFromThisPc,
  isSafeRelativePath,
  listBackups,
  mirrorUploads,
  nextRunAt,
  parseBackupFolderName,
  prepareExternalRoot,
  pruneBackups,
  sameDrive,
} from '../src/backup.js';
import {
  BackupDecryptError,
  CHUNK_BYTES,
  createDecryptStream,
  createEncryptStream,
  decryptBuffer,
  deriveBackupKey,
  encryptBuffer,
  isKeyCheckValid,
  isSaneKdfParams,
  makeKeyCheck,
} from '../src/backupCrypto.js';
import {
  BackupPasswordError,
  checkMigrationCompat,
  decryptFileTo,
  findMirrorFor,
  mergeEnv,
  openBackup,
  readSecretsBundle,
  restoreMirror,
  secretTarget,
} from '../src/backupRestore.js';

/** 시험용 가벼운 KDF — 진짜 값(N=2^15)은 시험마다 0.1초씩 든다. */
const FAST_KDF = { N: 1024, r: 8, p: 1 };
const quiet = { log() {}, warn() {}, error() {} };

let tmp;
beforeEach(() => {
  tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'tt-backup-'));
});
afterEach(() => {
  fs.rmSync(tmp, { recursive: true, force: true });
});

async function encryptBytes(key, plain, context, pieces = 1) {
  const out = [];
  const enc = createEncryptStream(key, context);
  enc.on('data', (d) => out.push(d));
  const step = Math.ceil(plain.length / pieces) || 1;
  const parts = [];
  for (let i = 0; i < plain.length; i += step) parts.push(plain.subarray(i, i + step));
  await pipeline(Readable.from(parts), enc);
  return Buffer.concat(out);
}

async function decryptBytes(key, sealed, context) {
  const out = [];
  const dec = createDecryptStream(key, context);
  dec.on('data', (d) => out.push(d));
  await pipeline(Readable.from([sealed]), dec);
  return Buffer.concat(out);
}

// ───────────────────────────── 암호화 ─────────────────────────────

test('암호화: 빈 것·작은 것·조각 경계·여러 조각 모두 그대로 풀리고, 스트림과 한 번에 쓴 것이 같은 형식이다', async () => {
  const key = crypto.randomBytes(32);
  for (const size of [0, 1, 1000, CHUNK_BYTES - 1, CHUNK_BYTES, CHUNK_BYTES + 1, CHUNK_BYTES * 3 + 12345]) {
    const plain = crypto.randomBytes(size);
    const sealed = await encryptBytes(key, plain, 'db', 7);
    assert.deepEqual(await decryptBytes(key, sealed, 'db'), plain, `size ${size}`);
    assert.deepEqual(decryptBuffer(key, sealed, 'db'), plain, `buffer size ${size}`);
    assert.deepEqual(await decryptBytes(key, encryptBuffer(key, plain, 'db'), 'db'), plain, `buffer→stream size ${size}`);
  }
});

test('암호화: 다른 키·다른 파일(context)·바뀐 바이트·잘림·덧붙임·끝 표시 바꿔치기는 모두 실패한다', async () => {
  const key = crypto.randomBytes(32);
  const plain = crypto.randomBytes(CHUNK_BYTES * 2 + 10);
  const sealed = await encryptBytes(key, plain, 'upload:a.png');
  const fails = async (buf, k = key, ctx = 'upload:a.png') =>
    assert.rejects(decryptBytes(k, buf, ctx), BackupDecryptError);

  await fails(sealed, crypto.randomBytes(32));
  await fails(sealed, key, 'upload:b.png');
  const flipped = Buffer.from(sealed);
  flipped[flipped.length - 100] ^= 1;
  await fails(flipped);
  // 마지막 조각(끝 표시)을 통째로 떼면 앞 조각까지는 맞지만 "잘림"이다.
  const lastLen = 5 + 10 + 16;
  await fails(sealed.subarray(0, sealed.length - lastLen));
  await fails(sealed.subarray(0, sealed.length - 1));
  await fails(Buffer.concat([sealed, Buffer.from([0])]));
  // 첫 조각의 끝 표시를 1로 바꾸면(뒤를 버리고 앞만 남기려는 시도) 논스가 달라 풀리지 않는다.
  const forged = Buffer.from(sealed);
  forged[12] = 1;
  await fails(forged);
  await fails(Buffer.from('not a backup'));
  assert.throws(() => decryptBuffer(key, sealed, 'upload:b.png'), BackupDecryptError);
});

test('키: 같은 암호·salt면 같은 키, 확인용 글은 맞는 키에서만 풀린다, KDF 값 범위', async () => {
  const salt = crypto.randomBytes(16);
  const a = await deriveBackupKey('비밀번호123!', salt, FAST_KDF);
  const b = await deriveBackupKey('비밀번호123!', salt, FAST_KDF);
  const c = await deriveBackupKey('비밀번호123?', salt, FAST_KDF);
  assert.deepEqual(a, b);
  assert.notDeepEqual(a, c);
  const check = makeKeyCheck(a);
  assert.equal(isKeyCheckValid(a, check), true);
  assert.equal(isKeyCheckValid(c, check), false);
  assert.equal(isKeyCheckValid(a, 'garbage'), false);
  assert.equal(isSaneKdfParams({ N: 32768, r: 8, p: 1 }), true);
  assert.equal(isSaneKdfParams({ N: 1 << 30, r: 8, p: 1 }), false);
  assert.equal(isSaneKdfParams({ N: 1000, r: 8, p: 1 }), false);
  assert.equal(isSaneKdfParams({ N: 32768, r: 100, p: 1 }), false);
});

// ───────────────────────────── 백업 만들기 ─────────────────────────────

function fakeDump(content) {
  return () => ({ stream: Readable.from([content]), done: Promise.resolve() });
}

function makeSecrets() {
  const dir = path.join(tmp, 'server');
  fs.mkdirSync(path.join(dir, 'certs'), { recursive: true });
  fs.writeFileSync(path.join(dir, '.env'), 'DATABASE_URL=postgres://a\nEXTERNAL_ADDRESS=x.duckdns.org\n');
  fs.writeFileSync(path.join(dir, '.db-encryption-key'), 'ab'.repeat(32));
  fs.writeFileSync(path.join(dir, 'certs', 'key.pem'), 'PRIVATE');
  return [
    { name: 'server/.env', path: path.join(dir, '.env') },
    { name: 'server/.db-encryption-key', path: path.join(dir, '.db-encryption-key') },
    { name: 'server/.jwt-secret', path: path.join(dir, '.jwt-secret') }, // 없음 — 건너뛴다
    { name: 'server/certs/key.pem', path: path.join(dir, 'certs', 'key.pem') },
  ];
}

let clock = new Date(2026, 9, 14, 3, 0, 0).getTime();
const tick = () => new Date((clock += 1000));

async function makeBackup(root, overrides = {}) {
  return createBackup({
    root,
    password: '백업암호-1234',
    kind: 'scheduled',
    dumpDb: fakeDump(Buffer.from('PGDMP fake dump')),
    secretFiles: makeSecrets(),
    mirrorKey: crypto.randomBytes(32),
    info: { host: 'test-pc', migrations: { count: 101, last: '0101_server_backup' } },
    now: tick,
    kdfParams: FAST_KDF,
    ...overrides,
  });
}

test('백업: 폴더 하나에 manifest·암호화된 DB·비밀값 — 맞는 암호로만 열리고 내용이 그대로다', async () => {
  const root = path.join(tmp, 'backups');
  const mirrorKey = crypto.randomBytes(32);
  const dump = crypto.randomBytes(3 * CHUNK_BYTES);
  const created = await makeBackup(root, { dumpDb: fakeDump(dump), mirrorKey });
  assert.match(created.name, /^tangotalk_\d{8}_\d{6}$/);
  assert.deepEqual(fs.readdirSync(created.dir).sort(), ['db.dump.enc', 'manifest.json', 'secrets.enc']);
  assert.ok(!fs.readFileSync(path.join(created.dir, 'secrets.enc')).includes('PRIVATE'), '비밀값은 평문으로 남지 않는다');
  assert.ok(!fs.readFileSync(path.join(created.dir, 'manifest.json'), 'utf8').includes('PRIVATE'));
  assert.deepEqual(created.manifest.contents.secrets.entries, ['server/.db-encryption-key', 'server/.env', 'server/certs/key.pem']);
  assert.equal(created.manifest.migrations.count, 101);

  await assert.rejects(openBackup(created.dir, '틀린암호'), BackupPasswordError);
  const { key } = await openBackup(created.dir, '백업암호-1234');
  const out = path.join(tmp, 'db.dump');
  await decryptFileTo(path.join(created.dir, DB_FILE), out, key, 'db');
  assert.deepEqual(fs.readFileSync(out), dump);
  const bundle = readSecretsBundle(created.dir, key);
  assert.equal(bundle.files['server/certs/key.pem'].toString(), 'PRIVATE');
  assert.deepEqual(bundle.mirrorKey, mirrorKey);
});

test('백업: pg_dump가 실패하면 쓰던 폴더를 지우고 실패한다(반쯤 된 백업이 남지 않는다)', async () => {
  const root = path.join(tmp, 'backups');
  const dumpDb = () => ({ stream: Readable.from([Buffer.from('partial')]), done: Promise.reject(new Error('pg_dump 실패(종료 코드 1)')) });
  await assert.rejects(makeBackup(root, { dumpDb }), /pg_dump 실패/);
  assert.deepEqual(fs.readdirSync(root), []);
});

test('목록·정리: 다 만든 것만 최신순, 보관 개수만 남기고, 하루 지난 .partial은 치우되 방금 것은 둔다', async () => {
  const root = path.join(tmp, 'backups');
  for (let i = 0; i < 4; i++) await makeBackup(root);
  fs.mkdirSync(path.join(root, 'tangotalk_20200101_000000.partial'));
  fs.mkdirSync(path.join(root, `${backupFolderName(new Date())}.partial`));
  fs.mkdirSync(path.join(root, 'tangotalk_20200101_000001')); // manifest 없음 — 백업 아님
  fs.mkdirSync(path.join(root, 'someone-elses-folder'));

  const listed = await listBackups(root);
  assert.equal(listed.length, 4);
  assert.ok(listed[0].name > listed[1].name);
  assert.ok(listed[0].bytes > 0);

  const removed = await pruneBackups(root, 2);
  assert.equal(removed.length, 2);
  const left = fs.readdirSync(root).sort();
  assert.equal((await listBackups(root)).length, 2);
  assert.ok(!left.includes('tangotalk_20200101_000000.partial'));
  assert.ok(left.includes(`${backupFolderName(new Date())}.partial`) || left.some((n) => n.endsWith('.partial')));
  assert.ok(left.includes('someone-elses-folder'));
  assert.ok(left.includes('tangotalk_20200101_000001'), 'manifest 없는 폴더는 백업으로 보지 않아 지우지도 않는다');
});

test('이름: 폴더 이름 ↔ 시각', () => {
  const d = new Date(2026, 0, 2, 3, 4, 5);
  assert.equal(backupFolderName(d), 'tangotalk_20260102_030405');
  assert.equal(parseBackupFolderName('tangotalk_20260102_030405'), d.getTime());
  assert.equal(parseBackupFolderName('tangotalk_2026_0102'), null);
  assert.equal(parseBackupFolderName('../tangotalk_20260102_030405'), null);
});

// ───────────────────────────── 잠금 ─────────────────────────────

test('잠금: 살아 있는 백업이 쥐고 있으면 막고, 죽은 프로세스·오래된 잠금은 치우고 다시 잡는다', () => {
  const root = tmp;
  const release = acquireBackupLock(root, { owner: 'script' });
  assert.throws(() => acquireBackupLock(root), (e) => e instanceof BackupBusyError && /시작 메뉴/.test(e.message));
  assert.equal(backupLockHolder(root), 'script');
  release();
  assert.equal(backupLockHolder(root), null);

  fs.writeFileSync(path.join(root, '.backup.lock'), JSON.stringify({ pid: 999999, owner: 'server', startedAt: Date.now() }));
  const again = acquireBackupLock(root, { isAlive: () => false });
  again();

  fs.writeFileSync(path.join(root, '.backup.lock'), JSON.stringify({ pid: process.pid, startedAt: Date.now() - 13 * 3600 * 1000 }));
  acquireBackupLock(root)();
});

// ───────────────────────────── 외부 위치 ─────────────────────────────

test('외부 위치: 없는 폴더는 만들지 않고 실패, 전용 폴더와 표시 파일을 만들고, 남의 파일이 든 폴더는 쓰지 않는다', async () => {
  await assert.rejects(prepareExternalRoot(path.join(tmp, 'unplugged-drive')), /찾을 수 없습니다/);
  assert.ok(!fs.existsSync(path.join(tmp, 'unplugged-drive')));

  const dest = path.join(tmp, 'nas');
  fs.mkdirSync(dest);
  const extRoot = await prepareExternalRoot(dest);
  assert.equal(extRoot, path.join(dest, EXTERNAL_DIR_NAME));
  assert.ok(fs.existsSync(path.join(extRoot, 'tangotalk-backup-root.json')));
  assert.equal(await prepareExternalRoot(dest), extRoot);

  const other = path.join(tmp, 'other');
  fs.mkdirSync(path.join(other, EXTERNAL_DIR_NAME), { recursive: true });
  fs.writeFileSync(path.join(other, EXTERNAL_DIR_NAME, 'family-photo.jpg'), 'x');
  await assert.rejects(prepareExternalRoot(other), /다른 파일/);
});

test('외부 복사: 외부에 없는 최근 백업만 보내고, 보관 개수만 남긴다', async () => {
  const root = path.join(tmp, 'backups');
  for (let i = 0; i < 3; i++) await makeBackup(root);
  const dest = path.join(tmp, 'usb');
  fs.mkdirSync(dest);
  const extRoot = await prepareExternalRoot(dest);
  assert.equal((await copyBackupsTo(root, extRoot, 2)).length, 2);
  assert.equal((await copyBackupsTo(root, extRoot, 2)).length, 0);
  await makeBackup(root);
  assert.equal((await copyBackupsTo(root, extRoot, 2)).length, 1);
  await pruneBackups(extRoot, 2);
  assert.equal((await listBackups(extRoot)).length, 2);
  const newest = (await listBackups(extRoot))[0].name;
  assert.equal(newest, (await listBackups(root))[0].name);
  // 복사본도 같은 암호로 열린다.
  await openBackup(path.join(extRoot, newest), '백업암호-1234');
});

// ───────────────────────────── 첨부파일 미러 ─────────────────────────────

function writeUpload(dir, rel, content) {
  const full = path.join(dir, ...rel.split('/'));
  fs.mkdirSync(path.dirname(full), { recursive: true });
  fs.writeFileSync(full, content);
}

test('첨부파일 미러: 처음엔 전부, 다음엔 바뀐 것만 보내고, 사라진 것은 지우며, 풀면 그대로다', async () => {
  const uploads = path.join(tmp, 'uploads');
  for (let i = 0; i < 5; i++) writeUpload(uploads, `${i}.png`, `image-${i}`);
  writeUpload(uploads, 'stickers/a.webp', 'sticker');
  const extRoot = path.join(tmp, 'ext');
  fs.mkdirSync(extRoot);
  const key = crypto.randomBytes(32);

  let r = await mirrorUploads({ sourceDir: uploads, extRoot, key, log: quiet });
  assert.deepEqual([r.total, r.copied, r.deleted], [6, 6, 0]);
  assert.ok(!fs.readFileSync(path.join(extRoot, 'uploads', '0.png.enc')).includes('image-0'), '미러는 암호화돼 있다');

  r = await mirrorUploads({ sourceDir: uploads, extRoot, key, log: quiet });
  assert.deepEqual([r.copied, r.deleted], [0, 0]);

  writeUpload(uploads, '1.png', 'changed-longer');
  fs.rmSync(path.join(uploads, '2.png'));
  r = await mirrorUploads({ sourceDir: uploads, extRoot, key, log: quiet });
  assert.deepEqual([r.copied, r.deleted], [1, 1]);
  assert.ok(!fs.existsSync(path.join(extRoot, 'uploads', '2.png.enc')));

  // 새 PC로 복원 — 첨부파일 폴더가 비어 있다.
  const target = path.join(tmp, 'restored');
  const restored = await restoreMirror({ mirrorDir: path.join(extRoot, 'uploads'), key, targetDir: target });
  assert.deepEqual([restored.restored, restored.skipped, restored.failed.length], [5, 0, 0]);
  assert.equal(fs.readFileSync(path.join(target, '1.png'), 'utf8'), 'changed-longer');
  assert.equal(fs.readFileSync(path.join(target, 'stickers', 'a.webp'), 'utf8'), 'sticker');
  // 이미 있는 파일은 그대로 둔다(같은 PC 복원).
  const again = await restoreMirror({ mirrorDir: path.join(extRoot, 'uploads'), key, targetDir: target });
  assert.deepEqual([again.restored, again.skipped], [0, 5]);
  // 다른 키로는 풀지 않는다.
  await assert.rejects(
    restoreMirror({ mirrorDir: path.join(extRoot, 'uploads'), key: crypto.randomBytes(32), targetDir: path.join(tmp, 'x') }),
    /다른 서버/,
  );
});

test('첨부파일 미러: 한꺼번에 많이 사라지면 지우지 않고 알린다, 키가 바뀌면 새로 만든다, 남의 uploads 폴더는 쓰지 않는다', async () => {
  const uploads = path.join(tmp, 'uploads');
  for (let i = 0; i < 100; i++) writeUpload(uploads, `${i}.bin`, `f${i}`);
  const extRoot = path.join(tmp, 'ext');
  fs.mkdirSync(extRoot);
  const key = crypto.randomBytes(32);
  await mirrorUploads({ sourceDir: uploads, extRoot, key, log: quiet });

  for (let i = 0; i < 60; i++) fs.rmSync(path.join(uploads, `${i}.bin`));
  let r = await mirrorUploads({ sourceDir: uploads, extRoot, key, log: quiet });
  assert.deepEqual([r.deleted, r.deletionSkipped], [0, 60]);
  assert.ok(fs.existsSync(path.join(extRoot, 'uploads', '0.bin.enc')));

  const newKey = crypto.randomBytes(32);
  r = await mirrorUploads({ sourceDir: uploads, extRoot, key: newKey, log: quiet });
  assert.equal(r.copied, 40);
  assert.ok(!fs.existsSync(path.join(extRoot, 'uploads', '0.bin.enc')), '새 키로 다시 만들면 옛 파일은 남지 않는다');

  const foreign = path.join(tmp, 'foreign');
  writeUpload(path.join(foreign, 'uploads'), 'their-file.txt', 'x');
  await assert.rejects(mirrorUploads({ sourceDir: uploads, extRoot: foreign, key, log: quiet }), /다른 파일/);
  assert.ok(fs.existsSync(path.join(foreign, 'uploads', 'their-file.txt')));
});

test('첨부파일 복원: 손댄 색인의 경로(../ 등)는 쓰지 않는다', async () => {
  const uploads = path.join(tmp, 'uploads');
  writeUpload(uploads, 'ok.png', 'ok');
  const extRoot = path.join(tmp, 'ext');
  fs.mkdirSync(extRoot);
  const key = crypto.randomBytes(32);
  await mirrorUploads({ sourceDir: uploads, extRoot, key, log: quiet });
  const indexPath = path.join(extRoot, 'uploads', 'index.json');
  const index = JSON.parse(fs.readFileSync(indexPath, 'utf8'));
  index.files['../escaped.txt'] = { size: 1, mtimeMs: 1 };
  index.files['C:\\Windows\\x.dll'] = { size: 1, mtimeMs: 1 };
  fs.writeFileSync(indexPath, JSON.stringify(index));
  const target = path.join(tmp, 'restored', 'uploads');
  const r = await restoreMirror({ mirrorDir: path.join(extRoot, 'uploads'), key, targetDir: target });
  assert.equal(r.restored, 1);
  assert.equal(r.failed.length, 2);
  assert.ok(!fs.existsSync(path.join(tmp, 'restored', 'escaped.txt')));
  assert.equal(isSafeRelativePath('a/b.png'), true);
  assert.equal(isSafeRelativePath('a/../b'), false);
  assert.equal(isSafeRelativePath('a\\b'), false);
  assert.equal(isSafeRelativePath('c:x'), false);
});

test('백업 폴더 옆의 첨부파일 미러를 찾는다', async () => {
  const extRoot = path.join(tmp, EXTERNAL_DIR_NAME);
  fs.mkdirSync(path.join(extRoot, 'tangotalk_20260101_030000'), { recursive: true });
  assert.equal(findMirrorFor(path.join(extRoot, 'tangotalk_20260101_030000')), null);
  writeUpload(path.join(tmp, 'up'), 'a.png', 'a');
  await mirrorUploads({ sourceDir: path.join(tmp, 'up'), extRoot, key: crypto.randomBytes(32), log: quiet });
  assert.equal(findMirrorFor(path.join(extRoot, 'tangotalk_20260101_030000')), path.join(extRoot, 'uploads'));
});

// ───────────────────────────── 외부 위치 검사 ─────────────────────────────

test('외부 위치 검사(Windows): 드라이브·공유 폴더만, 공유 폴더는 서버 PC에서만, 서버 폴더 안은 거절', () => {
  const opts = { platform: 'win32', protectedDirs: ['C:\\TangoTalk-Server', 'D:\\Uploads', 'C:\\TangoTalk-Server\\backups', 'C:\\Windows'] };
  assert.deepEqual(checkBackupDestination('E:\\백업\\', opts), { path: 'E:\\백업' });
  assert.deepEqual(checkBackupDestination('E:/백업', opts), { path: 'E:\\백업' });
  assert.deepEqual(checkBackupDestination('E:\\', opts), { path: 'E:\\' });
  assert.deepEqual(checkBackupDestination('  ', opts), { path: null });
  assert.deepEqual(checkBackupDestination(null, opts), { path: null });
  assert.match(checkBackupDestination('\\\\nas\\share\\tt', opts).error, /서버 PC/);
  assert.deepEqual(checkBackupDestination('\\\\nas\\share\\tt', { ...opts, isLocalRequest: true }), { path: '\\\\nas\\share\\tt' });
  assert.match(checkBackupDestination('backups', opts).error, /드라이브 경로/);
  assert.match(checkBackupDestination('\\\\?\\C:\\x', opts).error, /드라이브 경로/);
  assert.match(checkBackupDestination('E:\\a\\..\\b', opts).error, /\.\./);
  assert.match(checkBackupDestination('E:\\a:b', opts).error, /쓸 수 없는 글자/);
  assert.match(checkBackupDestination('C:\\TangoTalk-Server\\x', opts).error, /서버 폴더/);
  assert.match(checkBackupDestination('c:\\tangotalk-server', opts).error, /서버 폴더/);
  assert.match(checkBackupDestination('D:\\Uploads', opts).error, /서버 폴더/);
  assert.match(checkBackupDestination('C:\\Windows\\Temp', opts).error, /서버 폴더/);
  assert.deepEqual(checkBackupDestination('C:\\', opts), { path: 'C:\\' }, '드라이브 최상위 아래 전용 폴더는 서버 폴더 밖이다');
  assert.match(checkBackupDestination(3, opts).error, /글자/);
});

test('외부 위치 검사(그 밖의 OS): 절대 경로만', () => {
  const opts = { platform: 'linux', protectedDirs: ['/srv/tangotalk'] };
  assert.deepEqual(checkBackupDestination('/mnt/nas/', opts), { path: '/mnt/nas' });
  assert.match(checkBackupDestination('nas', opts).error, /절대 경로/);
  assert.match(checkBackupDestination('/srv/tangotalk', opts).error, /서버 폴더/);
});

test('같은 드라이브인지·이 PC에서 온 요청인지', () => {
  assert.equal(sameDrive('C:\\backup', 'c:\\TangoTalk\\backups', 'win32'), true);
  assert.equal(sameDrive('E:\\backup', 'C:\\TangoTalk\\backups', 'win32'), false);
  assert.equal(sameDrive('\\\\nas\\s', 'C:\\x', 'win32'), false);
  assert.equal(sameDrive('/a', '/b', 'linux'), false);
  const ifaces = { eth0: [{ address: '192.168.0.10', family: 'IPv4' }], lo: [{ address: '127.0.0.1', family: 'IPv4' }] };
  const req = (ip) => ({ socket: { remoteAddress: ip } });
  assert.equal(isRequestFromThisPc(req('127.0.0.1'), ifaces), true);
  assert.equal(isRequestFromThisPc(req('::1'), ifaces), true);
  assert.equal(isRequestFromThisPc(req('::ffff:192.168.0.10'), ifaces), true);
  assert.equal(isRequestFromThisPc(req('192.168.0.11'), ifaces), false);
  assert.equal(isRequestFromThisPc(req('203.0.113.5'), ifaces), false);
});

test('경고: 암호 없음·외부 위치 없음·같은 드라이브·오래된 성공·한꺼번에 사라진 첨부파일', () => {
  const now = Date.now();
  assert.match(backupWarnings({ password: null }, {}).join(), /백업 암호/);
  const base = { password: 'x', enabled: true, destination: null };
  assert.match(backupWarnings(base, { lastSuccessAt: now }, { nowMs: now }).join(), /외부 백업 위치/);
  if (process.platform === 'win32') {
    assert.match(
      backupWarnings({ ...base, destination: 'C:\\b' }, {}, { localRoot: 'C:\\TT\\backups', nowMs: now }).join(),
      /같은 드라이브/,
    );
  }
  const ok = backupWarnings({ ...base, destination: 'E:\\b' }, { lastSuccessAt: now }, { localRoot: 'C:\\x', nowMs: now });
  assert.deepEqual(ok, []);
  assert.match(
    backupWarnings({ ...base, destination: 'E:\\b' }, { lastSuccessAt: now - 4 * 86400000 }, { localRoot: 'C:\\x', nowMs: now }).join(),
    /사흘/,
  );
  assert.match(
    backupWarnings(
      { ...base, destination: 'E:\\b' },
      { lastSuccessAt: now, external: { uploads: { deletionSkipped: 70 } } },
      { localRoot: 'C:\\x', nowMs: now },
    ).join(),
    /70개/,
  );
});

// ───────────────────────────── 예약 ─────────────────────────────

test('예약 시각: 오늘 그 시각이 지났으면 내일', () => {
  const at = (h, m = 0) => new Date(2026, 9, 14, h, m).getTime();
  assert.equal(nextRunAt(at(2, 59), 3), at(3));
  assert.equal(nextRunAt(at(3), 3), new Date(2026, 9, 15, 3).getTime());
  assert.equal(nextRunAt(at(23), 3), new Date(2026, 9, 15, 3).getTime());
  assert.equal(isBackupOverdue(null, at(3)), true);
  assert.equal(isBackupOverdue(at(3) - 25 * 3600000, at(3)), false);
  assert.equal(isBackupOverdue(at(3) - 27 * 3600000, at(3)), true);
});

function fakeTimers(startMs) {
  const t = { now: startMs, timers: [] };
  t.setTimer = (fn, ms) => {
    const handle = { fn, at: t.now + ms };
    t.timers.push(handle);
    return handle;
  };
  t.clearTimer = (h) => {
    t.timers = t.timers.filter((x) => x !== h);
  };
  return t;
}

test('예약기: 암호가 없거나 꺼져 있으면 예약하지 않고, 놓쳤으면 곧, 아니면 정한 시각에 돌리고 다시 예약한다', async () => {
  const start = new Date(2026, 9, 14, 10, 0).getTime();
  const t = fakeTimers(start);
  let settings = { enabled: true, hour: 3, ready: false };
  let lastSuccess = null;
  const runs = [];
  const scheduler = createBackupScheduler({
    loadSettings: async () => settings,
    run: async (kind) => {
      runs.push(kind);
      lastSuccess = t.now;
    },
    lastSuccessAt: () => lastSuccess,
    now: () => t.now,
    setTimer: t.setTimer,
    clearTimer: t.clearTimer,
    catchUpDelayMs: 600000,
    log: quiet,
  });
  await scheduler.start();
  assert.equal(scheduler.nextRunAt(), null);

  settings = { ...settings, ready: true };
  await scheduler.start();
  assert.equal(scheduler.nextRunAt(), start + 600000, '한 번도 성공한 적 없으면 10분 뒤');
  assert.equal(t.timers.length, 1);

  t.now = t.timers[0].at;
  await t.timers[0].fn();
  assert.deepEqual(runs, ['scheduled']);
  assert.equal(scheduler.nextRunAt(), new Date(2026, 9, 15, 3).getTime(), '돌린 뒤엔 다음 날 3시');
  assert.equal(t.timers.length, 2);

  settings = { ...settings, enabled: false };
  await scheduler.reschedule();
  assert.equal(scheduler.nextRunAt(), null);
  assert.equal(t.timers.length, 1, '꺼지면 걸린 예약을 푼다');

  scheduler.stop();
  settings = { ...settings, enabled: true };
  await scheduler.reschedule();
  assert.equal(scheduler.nextRunAt(), null, '멈춘 뒤에는 예약하지 않는다');
});

test('예약기: 백업이 실패해도 다음 날을 예약한다', async () => {
  const t = fakeTimers(new Date(2026, 9, 14, 2, 0).getTime());
  const scheduler = createBackupScheduler({
    loadSettings: async () => ({ enabled: true, hour: 3, ready: true }),
    run: async () => {
      throw new Error('NAS 꺼짐');
    },
    lastSuccessAt: () => t.now,
    now: () => t.now,
    setTimer: t.setTimer,
    clearTimer: t.clearTimer,
    log: quiet,
  });
  await scheduler.start();
  assert.equal(scheduler.nextRunAt(), new Date(2026, 9, 14, 3).getTime());
  const timer = t.timers.at(-1);
  t.now = timer.at;
  await timer.fn();
  assert.equal(scheduler.nextRunAt(), new Date(2026, 9, 15, 3).getTime());
});

// ───────────────────────────── 복원 조각 ─────────────────────────────

test('.env 합치기: 이 PC 값(DB·첨부파일 위치·화상회의)은 두고, 나머지는 백업 값으로, 포트가 바뀌면 알린다', () => {
  const current = '# 설치가 만듦\r\nDATABASE_URL=postgres://new\r\nLIVEKIT_API_SECRET=new-lk\r\nPORT=3000\r\nWEB_DOMAIN=\r\n';
  const backup = [
    'DATABASE_URL=postgres://old',
    'UPLOADS_DIR=D:\\old-uploads',
    'LIVEKIT_API_SECRET=old-lk',
    'EXTERNAL_ADDRESS=tt.duckdns.org:3010',
    'WEB_DOMAIN=tt.duckdns.org',
    'PORT=3010',
    '# comment',
  ].join('\n');
  const { text, carried, portChanges } = mergeEnv(current, backup);
  assert.match(text, /^# 설치가 만듦\r\n/);
  assert.match(text, /DATABASE_URL=postgres:\/\/new/);
  assert.match(text, /LIVEKIT_API_SECRET=new-lk/);
  assert.doesNotMatch(text, /UPLOADS_DIR/);
  assert.match(text, /EXTERNAL_ADDRESS=tt\.duckdns\.org:3010/);
  assert.match(text, /WEB_DOMAIN=tt\.duckdns\.org/);
  assert.match(text, /PORT=3010/);
  assert.equal(text.match(/^PORT=/gm).length, 1);
  assert.deepEqual(carried.sort(), ['EXTERNAL_ADDRESS', 'PORT', 'WEB_DOMAIN']);
  assert.deepEqual(portChanges, [{ key: 'PORT', from: '3000', to: '3010' }]);
  assert.match(mergeEnv('', 'A=1').text, /^A=1\r\n$/);
});

test('비밀값 되돌릴 자리: 정해 둔 파일과 certs 안의 이름만', () => {
  assert.equal(secretTarget('server/.env'), 'env');
  assert.equal(secretTarget('server/.db-encryption-key'), '.db-encryption-key');
  assert.equal(secretTarget('server/certs/key.pem'), 'certs/key.pem');
  assert.equal(secretTarget('server/certs/../../evil'), null);
  assert.equal(secretTarget('server/certs/sub/x.pem'), null);
  assert.equal(secretTarget('server/src/index.js'), null);
  assert.equal(secretTarget('../.env'), null);
});

test('복원 가능 여부: 더 새 서버의 백업은 막는다', () => {
  assert.equal(checkMigrationCompat({ migrations: { count: 99 } }, 101).ok, true);
  assert.equal(checkMigrationCompat({ migrations: { count: 101 } }, 101).ok, true);
  assert.match(checkMigrationCompat({ migrations: { count: 102 } }, 101).error, /업데이트/);
  assert.equal(checkMigrationCompat({}, 101).ok, true);
});
