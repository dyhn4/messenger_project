// "서버 데이터 완전 삭제"(installer/Uninstall-Full.ps1) 전에, 실제 서버 운영자
// (is_server_admin=true) 계정인지 확인한다. PC 앞에 앉을 수 있는 사람이면 누구나
// "DELETE"라고 타이핑해서 지울 수 있던 것을, 실제 운영자 아이디/비밀번호를 아는
// 사람만 지울 수 있도록 한 단계 더 막는다.
//
// 비밀번호는 커맨드라인 인자로 남기지 않기 위해 stdin으로 받는다. 성공하면 exit 0,
// 실패하면 exit 1 — 계정 없음/비밀번호 틀림/운영자 아님/정지·탈퇴 계정을 전부 구분 없이
// 같은 실패로 취급한다(auth.js의 로그인 실패 메시지와 같은 이유 — 어떤 부분이 틀렸는지
// 알려주면 계정 존재 여부 등을 추측하는 단서가 된다).
//
// 사용법: echo <비밀번호> | node verify-admin.mjs <아이디>
import dotenv from 'dotenv';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import pg from 'pg';
import bcrypt from 'bcryptjs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
dotenv.config({ path: path.join(__dirname, '..', '.env'), quiet: true });

const username = process.argv[2];
if (!username || !process.env.DATABASE_URL) {
  console.error('사용법: node verify-admin.mjs <아이디>  (비밀번호는 stdin으로)');
  process.exit(1);
}

function readStdin() {
  return new Promise((resolve) => {
    let data = '';
    process.stdin.setEncoding('utf8');
    process.stdin.on('data', (chunk) => (data += chunk));
    process.stdin.on('end', () => resolve(data.replace(/\r?\n$/, '')));
  });
}

const password = await readStdin();
const client = new pg.Client({ connectionString: process.env.DATABASE_URL });
let ok = false;
try {
  await client.connect();
  const { rows } = await client.query(
    'SELECT password_hash, is_server_admin, deleted_at, suspended_at FROM users WHERE username = $1',
    [username],
  );
  const user = rows[0];
  ok =
    !!user &&
    !user.deleted_at &&
    !user.suspended_at &&
    user.is_server_admin === true &&
    (await bcrypt.compare(password, user.password_hash));
} catch {
  ok = false;
} finally {
  await client.end().catch(() => {});
}
process.exit(ok ? 0 : 1);
