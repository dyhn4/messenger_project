import { drizzle } from 'drizzle-orm/node-postgres';
import { Pool } from 'pg';

// DB 접속정보는 JWT_SECRET 같은 값들과 달리 추측해서 자동 생성할 수 없다 — 없으면 바로 종료한다.
const connectionString = process.env.DATABASE_URL;
if (!connectionString) {
  console.error(
    '[db] DATABASE_URL이 설정되어 있지 않습니다. server/.env에 ' +
      'postgres://사용자:비밀번호@localhost:5432/데이터베이스명 형태로 설정하세요.',
  );
  process.exit(1);
}

const pool = new Pool({ connectionString });
export const db = drizzle(pool);

export const GENERAL_ROOM_ID = 'general';
