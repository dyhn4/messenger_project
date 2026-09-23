import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { sql } from 'drizzle-orm';
import { db } from './db/client.js';

const migrationsDir = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'drizzle');

/** drizzle이 "이 마이그레이션은 이미 돌렸다"를 기록해두는 원장. 해시는 .sql 파일 원문의 sha256. */
async function appliedHashes() {
  const rows = await db.execute(
    sql`select hash from drizzle.__drizzle_migrations`,
  );
  return new Set((rows.rows ?? rows).map((r) => r.hash));
}

/**
 * 코드가 기대하는 스키마와 실제 DB가 어긋난 채로 서버가 뜨는 걸 막는다.
 *
 * 이게 없으면 증상이 아주 헷갈린다 — 서버는 멀쩡히 뜨고 로그인도 되는데, 새 컬럼을 읽는
 * 화면만 "teams.icon_url 칼럼 없음" 같은 쿼리 오류를 뱉는다(팀 목록이 통째로 비어 보인다).
 * 특히 다른 PC에서 만든 마이그레이션을 git pull로 받아오고 db:migrate를 잊었을 때 그렇다.
 *
 * 원장이 아예 없으면(DB를 처음 만든 직후) 조용히 넘어간다 — 그건 db:migrate가 할 일이다.
 */
export async function checkPendingMigrations() {
  let journal;
  try {
    journal = JSON.parse(fs.readFileSync(path.join(migrationsDir, 'meta', '_journal.json'), 'utf8'));
  } catch {
    return; // 배포본에 drizzle 폴더를 안 넣은 경우 — 확인할 방법이 없으니 넘어간다.
  }

  let applied;
  try {
    applied = await appliedHashes();
  } catch {
    console.warn('[마이그레이션] 원장을 읽지 못했습니다 — "npm run db:migrate"를 한 번 실행하세요.');
    return;
  }

  const pending = journal.entries.filter((e) => {
    const file = path.join(migrationsDir, `${e.tag}.sql`);
    if (!fs.existsSync(file)) return false;
    const hash = crypto.createHash('sha256').update(fs.readFileSync(file, 'utf8')).digest('hex');
    return !applied.has(hash);
  });
  if (pending.length === 0) return;

  console.error('');
  console.error('='.repeat(72));
  console.error(`[마이그레이션] 아직 DB에 적용되지 않은 변경이 ${pending.length}개 있습니다:`);
  for (const e of pending) console.error(`  - ${e.tag}`);
  console.error('');
  console.error('  server 폴더에서 "npm run db:migrate"를 실행하세요.');
  console.error('  (다른 PC에서 만든 마이그레이션을 git pull로 받아온 뒤 흔히 생깁니다.');
  console.error('   이대로 두면 새 컬럼을 읽는 화면이 "... 칼럼 없음" 오류로 비어 보입니다.)');
  console.error('='.repeat(72));
  console.error('');
}
