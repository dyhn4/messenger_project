// "DB 데이터 초기화"(installer/Reset-Data.ps1) — 서버 프로그램/설치는 그대로 두고, DB 안의
// 회원/팀/메시지/댓글/첨부파일 메타데이터 등 앱 데이터만 전부 비운다. 서버 운영자 인증과
// "RESET" 입력 확인은 Reset-Data.ps1이 이 스크립트를 부르기 전에 이미 끝낸 뒤다.
//
// public 스키마에 있는 테이블을 전부 동적으로 찾아서 TRUNCATE ... RESTART IDENTITY CASCADE
// 한다(하드코딩된 테이블 목록을 안 쓰므로 나중에 테이블이 추가돼도 이 스크립트를 안 고쳐도
// 됨). drizzle의 마이그레이션 적용 기록은 별도의 "drizzle" 스키마에 있어서 자동으로 안
// 건드려진다 — 그래서 초기화 후에 마이그레이션을 다시 실행할 필요가 없다.
//
// 업로드된 첨부파일(server/uploads/*)은 DB 밖의 실제 파일이라 여기서는 안 지운다 —
// Reset-Data.ps1이 이 스크립트가 끝난 뒤 별도로 지운다.
import 'dotenv/config';
import pg from 'pg';

const client = new pg.Client({ connectionString: process.env.DATABASE_URL });
try {
  await client.connect();
  const { rows } = await client.query(
    `SELECT tablename FROM pg_tables WHERE schemaname = 'public'`,
  );
  if (rows.length === 0) {
    console.log('초기화할 테이블이 없습니다.');
    process.exit(0);
  }
  const tableList = rows.map((r) => `"public"."${r.tablename}"`).join(', ');
  await client.query(`TRUNCATE TABLE ${tableList} RESTART IDENTITY CASCADE`);
  console.log(`DB 초기화 완료: ${rows.length}개 테이블 (${rows.map((r) => r.tablename).join(', ')})`);
  process.exit(0);
} catch (e) {
  console.error('DB 초기화 실패:', e.message);
  process.exit(1);
} finally {
  await client.end().catch(() => {});
}
