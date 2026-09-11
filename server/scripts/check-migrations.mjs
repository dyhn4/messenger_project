// 마이그레이션이 실제로 다 적용됐는지 점검(읽기 전용 — 아무것도 고치지 않는다).
//
// "npm run db:migrate가 성공했다고 나오는데 새 테이블/컬럼이 실제로는 없다"는 증상을 확인할
// 때 쓴다. drizzle-kit migrate는 각 마이그레이션 파일의 해시가 drizzle.__drizzle_migrations에
// 이미 기록돼 있는지로 "적용된 것"을 판단하는데, 과거에 그 표의 시각(created_at) 값에 실제
// 보다 훨씬 미래의 값이 잘못 들어간 적이 있으면(개발 DB에서 실제로 있었던 문제), 그 뒤로
// 진짜 새로 추가된 마이그레이션들의 실제 시각이 전부 그 미래 값보다 작아서 "이미 지나간
// 시각"으로 보여 조용히 건너뛰어질 수 있다 — db:migrate는 에러 없이 "성공"이라고 뜨지만
// 실제로는 새 테이블/컬럼을 안 만든 것이다. 이 스크립트는 각 마이그레이션 파일의 해시(=
// drizzle-kit이 쓰는 것과 같은 계산법)를 직접 계산해서 DB 기록과 대조하므로, 과거에 수동으로
// 기록을 고친 적이 있어도(행 번호가 어긋나도) 정확하게 "파일 vs 적용 기록"을 비교한다.
//
// 사용법(server 폴더에서): node scripts/check-migrations.mjs
import crypto from 'node:crypto';
import dotenv from 'dotenv';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import pg from 'pg';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
dotenv.config({ path: path.join(__dirname, '..', '.env'), quiet: true });

if (!process.env.DATABASE_URL) {
  console.error('DATABASE_URL이 설정되어 있지 않습니다(.env 확인).');
  process.exit(1);
}

const drizzleDir = path.join(__dirname, '..', 'drizzle');
const journal = JSON.parse(
  fs.readFileSync(path.join(drizzleDir, 'meta', '_journal.json'), 'utf8'),
);

// drizzle-orm/migrator.js의 readMigrationFiles와 똑같은 계산법(파일 원문 그대로 sha256).
const fileEntries = journal.entries.map((entry) => {
  const content = fs.readFileSync(path.join(drizzleDir, `${entry.tag}.sql`), 'utf8');
  return { ...entry, hash: crypto.createHash('sha256').update(content).digest('hex') };
});

const client = new pg.Client({ connectionString: process.env.DATABASE_URL });
await client.connect();

let applied = [];
try {
  const { rows } = await client.query(
    'SELECT hash, created_at FROM drizzle.__drizzle_migrations ORDER BY id',
  );
  applied = rows;
} catch (e) {
  console.log('drizzle.__drizzle_migrations 테이블을 읽을 수 없습니다 — 마이그레이션이 한 번도 실행된 적이 없을 수 있습니다.');
  console.log('원인:', e.message);
}

const appliedHashes = new Set(applied.map((r) => r.hash));
const maxAppliedAt = applied.length ? Math.max(...applied.map((r) => Number(r.created_at))) : 0;

console.log(`저장소(drizzle/meta/_journal.json) 기준 마이그레이션 파일 수: ${fileEntries.length}`);
console.log(`DB에 "적용됨"으로 기록된 수: ${applied.length}`);
console.log(
  `DB에 기록된 가장 최근 적용 시각: ${maxAppliedAt} (${maxAppliedAt ? new Date(maxAppliedAt).toISOString() : '없음'})`,
);

const notApplied = fileEntries.filter((f) => !appliedHashes.has(f.hash));
console.log('\nDB에 적용 기록이 없는 마이그레이션 파일:');
if (notApplied.length === 0) {
  console.log('  (없음 — 저장소의 모든 마이그레이션 파일이 적용된 것으로 기록되어 있습니다)');
} else {
  for (const entry of notApplied) {
    const suspicious = entry.when <= maxAppliedAt;
    console.log(
      `  - [${entry.idx}] ${entry.tag}  (when=${entry.when}, ${new Date(entry.when).toISOString()})` +
        (suspicious
          ? '  ⚠ 이 시각이 DB에 기록된 가장 최근 적용 시각보다 작거나 같습니다 — drizzle-kit이 "이미 적용됨"으로 착각해 조용히 건너뛰었을 가능성이 높습니다.'
          : '  (아직 적용 전 — 다음 db:migrate에서 정상 적용될 것으로 보입니다)'),
    );
  }
}

const fileHashes = new Set(fileEntries.map((f) => f.hash));
const orphanRows = applied.filter((r) => !fileHashes.has(r.hash));
if (orphanRows.length > 0) {
  console.log('\n⚠ 저장소의 어떤 마이그레이션 파일과도 해시가 안 맞는 DB 기록:');
  for (const row of orphanRows) {
    console.log(
      `  - hash=${row.hash.slice(0, 16)}... created_at=${row.created_at} (${new Date(Number(row.created_at)).toISOString()})`,
    );
  }
  console.log('  (과거에 수동으로 기록을 잘못 넣었을 가능성 — 실제 스키마와 대조해서 확인 필요)');
}

console.log('\n실제 테이블/컬럼 상태 확인(position_options):');
try {
  const { rows } = await client.query(
    `SELECT column_name FROM information_schema.columns WHERE table_name = 'position_options' ORDER BY ordinal_position`,
  );
  console.log(
    rows.length ? `  컬럼: ${rows.map((r) => r.column_name).join(', ')}` : '  ⚠ 테이블이 존재하지 않습니다.',
  );
} catch (e) {
  console.log('  확인 실패:', e.message);
}

await client.end();
