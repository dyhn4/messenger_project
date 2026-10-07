// 서버 운영자 확인 스크립트(scripts/verify-admin.mjs)의 stdin 규칙 테스트 — `node --test test/*.test.js`.
// DB·.env를 건드리지 않는다: 진짜 verify-admin.mjs를 임시 폴더에 복사하고, 그 옆 node_modules에 가짜 pg(정해 둔 운영자 한 명만
// 돌려줌)·dotenv(아무것도 안 읽음)·bcryptjs(받은 비밀번호를 파일에 적고, 정해 둔 비밀번호와 글자 그대로 같은지만 봄)를 둔 채
// 실행한다. Node는 bare import를 그 파일에서 가까운 node_modules부터 찾으므로 server/node_modules의 진짜 모듈은 쓰이지 않는다
// (혹시 쓰이더라도 닿지 않는 주소로 접속하다 실패하게 DATABASE_URL을 둔다). verify-admin.mjs를 import하지 않는 까닭은 그 파일
// 머리 주석 참고. PowerShell 쪽(파이프 인코딩)은 installer/tests/Admin-Verify.Tests.ps1이 본다.
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { after, test } from 'node:test';
import { fileURLToPath } from 'node:url';

const SOURCE = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'scripts', 'verify-admin.mjs');
const ADMIN = '운영자kim';
// 한글·악센트·BMP 밖 글자(이모지)·앞뒤 공백 — 앞뒤 공백까지 비밀번호다.
const PASSWORD = ' 한글비번 Pässwörd 🔑 끝 ';

const root = fs.mkdtempSync(path.join(os.tmpdir(), 'tt-verify-admin-'));
after(() => fs.rmSync(root, { recursive: true, force: true }));

const SCRIPT = path.join(root, 'scripts', 'verify-admin.mjs');
const RECEIVED = path.join(root, 'received.json');
fs.mkdirSync(path.dirname(SCRIPT));
fs.copyFileSync(SOURCE, SCRIPT);

function writeFakePackage(name, source) {
  const dir = path.join(root, 'node_modules', name);
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, 'package.json'), JSON.stringify({ name, type: 'module', exports: './index.js' }));
  fs.writeFileSync(path.join(dir, 'index.js'), source);
}
writeFakePackage('dotenv', 'export default { config: () => ({ parsed: {} }) };\n');
writeFakePackage(
  'pg',
  `class Client {
  async connect() {}
  async query(_sql, params) {
    if (params[0] !== process.env.TT_TEST_ADMIN_USER) return { rows: [] };
    return { rows: [{ password_hash: 'fake-hash', is_server_admin: true, deleted_at: null, suspended_at: null }] };
  }
  async end() {}
}
export default { Client };
`,
);
writeFakePackage(
  'bcryptjs',
  `import fs from 'node:fs';
export default {
  async compare(password, hash) {
    fs.writeFileSync(process.env.TT_TEST_RECEIVED_FILE, JSON.stringify(password));
    return hash === 'fake-hash' && password === process.env.TT_TEST_ADMIN_PASSWORD;
  },
};
`,
);

function childEnv(over = {}) {
  return {
    ...process.env,
    DATABASE_URL: 'postgres://test:test@127.0.0.1:1/unused',
    TT_TEST_ADMIN_USER: ADMIN,
    TT_TEST_ADMIN_PASSWORD: PASSWORD,
    TT_TEST_RECEIVED_FILE: RECEIVED,
    ...over,
  };
}

function readReceived() {
  return fs.existsSync(RECEIVED) ? JSON.parse(fs.readFileSync(RECEIVED, 'utf8')) : null;
}

/** stdin에 bytes를 그대로 넣고 실행 — { status, received(bcrypt에 넘어간 비밀번호, 비교까지 안 갔으면 null), stderr }. */
function run(bytes, { user = ADMIN, env = {} } = {}) {
  fs.rmSync(RECEIVED, { force: true });
  const r = spawnSync(process.execPath, [SCRIPT, user], { input: bytes, env: childEnv(env), timeout: 30_000 });
  return { status: r.status, received: readReceived(), stderr: r.stderr.toString('utf8') };
}

const utf8 = (s) => Buffer.from(s, 'utf8');

test('PowerShell 파이프 모양(BOM 없는 UTF-8 + CRLF)이면 한글·이모지·앞뒤 공백까지 그대로 비교한다', () => {
  const r = run(utf8(`${PASSWORD}\r\n`));
  assert.equal(r.received, PASSWORD); // 가짜 모듈로 실제로 비교까지 갔다는 뜻이기도 하다
  assert.equal(r.status, 0);
});

test('끝 줄바꿈이 LF 하나이거나 아예 없어도 같다', () => {
  for (const tail of ['\n', '']) {
    const r = run(utf8(PASSWORD + tail));
    assert.equal(r.received, PASSWORD, JSON.stringify(tail));
    assert.equal(r.status, 0, JSON.stringify(tail));
  }
});

test('맨 앞 BOM은 하나만 떼어 낸다', () => {
  const one = run(utf8(`﻿${PASSWORD}\r\n`));
  assert.equal(one.received, PASSWORD);
  assert.equal(one.status, 0);
  const two = run(utf8(`﻿﻿${PASSWORD}\r\n`));
  assert.equal(two.received, `﻿${PASSWORD}`);
  assert.equal(two.status, 1);
});

test('줄바꿈은 맨 끝 하나만 뗀다 — 나머지는 비밀번호의 일부다', () => {
  const r = run(utf8(`${PASSWORD}\r\n\r\n`));
  assert.equal(r.received, `${PASSWORD}\r\n`);
  assert.equal(r.status, 1);
});

test("예전 Windows PowerShell 기본값(ASCII)으로 와서 '?'가 된 비밀번호는 통과하지 않는다", () => {
  const mangled = [...PASSWORD].map((c) => (c.codePointAt(0) < 0x80 ? c : '?')).join('');
  const r = run(Buffer.from(`${mangled}\r\n`, 'latin1'));
  assert.equal(r.received, mangled);
  assert.equal(r.status, 1);
});

test('올바른 UTF-8이 아니면(예: CP949로 보낸 한글) 짐작해 맞추지 않고 비교 전에 실패한다', () => {
  // CP949(EUC-KR)의 "한글" = C7 D1 B1 DB — UTF-8로는 올바르지 않은 바이트열이다.
  const cp949 = run(Buffer.from([0xc7, 0xd1, 0xb1, 0xdb, 0x0d, 0x0a]), { env: { TT_TEST_ADMIN_PASSWORD: '한글' } });
  assert.equal(cp949.received, null);
  assert.equal(cp949.status, 1);
  const stray = run(Buffer.concat([utf8(PASSWORD), Buffer.from([0xff, 0x0a])]));
  assert.equal(stray.received, null);
  assert.equal(stray.status, 1);
});

test('한 글자의 바이트가 stdin 조각 경계에서 나뉘어 와도 같다', async () => {
  fs.rmSync(RECEIVED, { force: true });
  const bytes = utf8(`${PASSWORD}\r\n`);
  const cut = bytes.indexOf(utf8('한')) + 1; // "한"(3바이트)의 첫 바이트 뒤에서 자른다
  const child = spawn(process.execPath, [SCRIPT, ADMIN], { env: childEnv(), stdio: ['pipe', 'ignore', 'pipe'] });
  const exited = new Promise((resolve, reject) => {
    child.on('error', reject);
    child.on('exit', (code) => resolve(code));
  });
  child.stdin.write(bytes.subarray(0, cut));
  await new Promise((resolve) => setTimeout(resolve, 200));
  child.stdin.end(bytes.subarray(cut));
  assert.equal(await exited, 0);
  assert.equal(readReceived(), PASSWORD);
});

test('아이디는 명령줄 인자로 받는다 — 없는 아이디는 비교 없이 실패, 빈 비밀번호도 실패', () => {
  const unknown = run(utf8(`${PASSWORD}\r\n`), { user: '운영자lee' });
  assert.equal(unknown.received, null);
  assert.equal(unknown.status, 1);
  const empty = run(Buffer.alloc(0));
  assert.equal(empty.received, '');
  assert.equal(empty.status, 1);
});

test('DATABASE_URL이 없으면 stdin을 보기 전에 사용법과 함께 실패한다', () => {
  const r = run(utf8(`${PASSWORD}\r\n`), { env: { DATABASE_URL: '' } });
  assert.equal(r.status, 1);
  assert.equal(r.received, null);
  assert.match(r.stderr, /사용법: node verify-admin\.mjs <아이디>/);
});
