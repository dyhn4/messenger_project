// "서버 데이터 완전 삭제"(installer/Uninstall-Full.ps1) 전에, 실제 서버 운영자
// (is_server_admin=true) 계정인지 확인한다. PC 앞에 앉을 수 있는 사람이면 누구나
// "DELETE"라고 타이핑해서 지울 수 있던 것을, 실제 운영자 아이디/비밀번호를 아는
// 사람만 지울 수 있도록 한 단계 더 막는다. (DB 데이터 초기화·복원도 같은 확인을 쓴다.)
//
// 비밀번호는 커맨드라인 인자로 남기지 않기 위해 stdin으로 받는다. 성공하면 exit 0,
// 실패하면 exit 1 — 계정 없음/비밀번호 틀림/운영자 아님/정지·탈퇴 계정을 전부 구분 없이
// 같은 실패로 취급한다(auth.js의 로그인 실패 메시지와 같은 이유 — 어떤 부분이 틀렸는지
// 알려주면 계정 존재 여부 등을 추측하는 단서가 된다).
//
// 사용법: <비밀번호> | node verify-admin.mjs <아이디>
// stdin은 UTF-8로 읽는다. 맨 앞 BOM 하나와 맨 끝 줄바꿈 하나(\n 또는 \r\n — PowerShell 파이프가 붙인다)만
// 떼어 내고, 나머지는 앞뒤 공백까지 비밀번호 그대로 쓴다. Windows PowerShell 5.1은 파이프로 넘기는 글자를
// 기본값 ASCII로 바꿔 한글 등을 '?'로 보내므로, 부르는 쪽이 그 파이프 동안 BOM 없는 UTF-8로 바꿔야 한다
// (installer의 Test-ServerAdminPassword — Reset-Data.ps1·Restore-Data.ps1·Uninstall-Full.ps1).
//
// 테스트(test/verifyAdminStdin.test.js)는 이 파일을 import하지 않고, 임시 폴더에 복사해 가짜 pg·dotenv·bcryptjs와
// 함께 실행한다. 그래서 grant-server-admin.mjs처럼 "직접 실행됐는지" 판단하는 코드를 두지 않는다 — 그 판단이 틀리면
// 아무것도 하지 않고 exit 0, 즉 "운영자 확인 통과"로 끝나 버리기 때문이다.
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

// 바이트를 끝까지 모은 뒤 한 번에 푼다 — 조각마다 풀면 한글처럼 여러 바이트인 글자가 조각 경계에서 잘릴 수 있다.
function readStdinBytes() {
  return new Promise((resolve, reject) => {
    const chunks = [];
    process.stdin.on('data', (chunk) => chunks.push(chunk));
    process.stdin.on('end', () => resolve(Buffer.concat(chunks)));
    process.stdin.on('error', reject);
  });
}

// 올바른 UTF-8이 아니면(다른 인코딩으로 보낸 경우) 글자를 짐작해 맞추지 않고 실패로 본다(fatal). 맨 앞 BOM 하나는
// TextDecoder가 떼어 낸다(ignoreBOM 기본값 false).
function decodePassword(bytes) {
  return new TextDecoder('utf-8', { fatal: true }).decode(bytes).replace(/\r?\n$/, '');
}

let password = null;
try {
  password = decodePassword(await readStdinBytes());
} catch {
  password = null;
}

let ok = false;
if (password !== null) {
  const client = new pg.Client({ connectionString: process.env.DATABASE_URL });
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
}
process.exit(ok ? 0 : 1);
