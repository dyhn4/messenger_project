// 일회성 복구 스크립트 — node scripts/check-migrations.mjs로 아래 증상을 확인한 뒤에 쓴다:
//   0024/0025 마이그레이션 기록의 적용 시각이 실제보다 훨씬 미래(예: 1789200000000,
//   1789200000001)로 잘못 들어가 있어서, 그 뒤에 추가된 0026~0028(직책 목록:
//   position_options 테이블 생성 + 서열(sort_order) + 기본값(is_default)) 마이그레이션이
//   db:migrate에서 "이미 적용된 시각보다 이전"으로 착각되어 조용히 건너뛰어진 상태.
//   (개발 DB에서도 실제로 있었던 문제로, 같은 원인에서 나온 것으로 보인다.)
//
// 하는 일(각 단계마다 먼저 현재 상태를 확인하고, 이미 정상인 부분은 건드리지 않는다 —
// 중간에 실패해도, 다시 실행하면 이미 끝난 단계는 건너뛰고 이어서 하므로 여러 번 실행해도
// 안전하다):
//   1) drizzle.__drizzle_migrations에서 0024/0025 마이그레이션 행을 해시로 찾아 기록된
//      시각을 저장소(drizzle/meta/_journal.json)의 올바른 값으로 고친다. 해시로 찾지 못하면
//      (이미 다른 방식으로 정리됐거나 애초에 없었던 것) 건드리지 않고 건너뛴다.
//   2) 0026/0027/0028 마이그레이션이 아직 적용 기록이 없으면, 그 SQL을 그대로 적용하고
//      (한 마이그레이션당 하나의 트랜잭션 — 중간에 실패하면 그 마이그레이션만 롤백된다)
//      정상적인 적용 기록을 남긴다.
//
// 사용법(server 폴더에서): node scripts/fix-position-options-migration.mjs
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
const readMigration = (tag) => fs.readFileSync(path.join(drizzleDir, `${tag}.sql`), 'utf8');
const hashOf = (content) => crypto.createHash('sha256').update(content).digest('hex');

// drizzle/meta/_journal.json에 기록된 실제 값과 정확히 일치해야 한다.
const FIX_TIMESTAMPS = [
  { tag: '0024_topic_creation_policy', correctWhen: 1789030283078 },
  { tag: '0025_topic_creators', correctWhen: 1789030283079 },
];
const MISSING = [
  { tag: '0026_material_madame_masque', when: 1789030283080 },
  { tag: '0027_right_susan_delgado', when: 1789102926625 },
  { tag: '0028_ordinary_toxin', when: 1789105375293 },
];

const client = new pg.Client({ connectionString: process.env.DATABASE_URL });
await client.connect();

try {
  console.log('[1/2] 0024/0025 마이그레이션 기록 시각 확인...');
  for (const fix of FIX_TIMESTAMPS) {
    const hash = hashOf(readMigration(fix.tag));
    const { rows } = await client.query(
      'SELECT id, created_at FROM drizzle.__drizzle_migrations WHERE hash = $1',
      [hash],
    );
    if (rows.length === 0) {
      console.log(`  ${fix.tag} 기록을 찾을 수 없습니다 — 건너뜁니다.`);
    } else if (Number(rows[0].created_at) === fix.correctWhen) {
      console.log(`  ${fix.tag} — 이미 정상입니다. 건너뜁니다.`);
    } else {
      console.log(
        `  ${fix.tag}: ${rows[0].created_at} → ${fix.correctWhen} 로 고칩니다(id=${rows[0].id}).`,
      );
      await client.query('UPDATE drizzle.__drizzle_migrations SET created_at = $1 WHERE id = $2', [
        fix.correctWhen,
        rows[0].id,
      ]);
      console.log(`  ${fix.tag} 완료.`);
    }
  }

  console.log('\n[2/2] 직책 목록(position_options) 관련 마이그레이션 적용...');
  for (const m of MISSING) {
    const content = readMigration(m.tag);
    const hash = hashOf(content);
    const { rows: existing } = await client.query(
      'SELECT id FROM drizzle.__drizzle_migrations WHERE hash = $1',
      [hash],
    );
    if (existing.length > 0) {
      console.log(`  ${m.tag} — 이미 적용 기록이 있습니다. 건너뜁니다.`);
      continue;
    }
    console.log(`  ${m.tag} 적용 중...`);
    await client.query('BEGIN');
    try {
      for (const stmt of content.split('--> statement-breakpoint')) {
        const trimmed = stmt.trim();
        if (trimmed) await client.query(trimmed);
      }
      await client.query(
        'INSERT INTO drizzle.__drizzle_migrations (hash, created_at) VALUES ($1, $2)',
        [hash, m.when],
      );
      await client.query('COMMIT');
      console.log(`  ${m.tag} 적용 완료.`);
    } catch (e) {
      await client.query('ROLLBACK');
      throw new Error(`${m.tag} 적용 실패(이 마이그레이션만 롤백됨): ${e.message}`);
    }
  }

  console.log('\n완료. node scripts/check-migrations.mjs로 다시 확인해 보세요.');
} finally {
  await client.end();
}
