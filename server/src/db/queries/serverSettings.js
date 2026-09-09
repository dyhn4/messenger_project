import { eq } from 'drizzle-orm';
import { db } from '../client.js';
import { serverSettings } from '../schema.js';

/** 서버 설정은 항상 이 한 행만 쓴다. */
const SINGLETON_ID = 1;

export const DEFAULT_SERVER_SETTINGS = { teamCreation: 'anyone' };

/** 설정 행이 아직 없으면(설치 직후) 기본값을 돌려준다 — 호출부는 늘 값이 있다고 봐도 된다. */
export async function getServerSettings() {
  const [row] = await db.select().from(serverSettings).where(eq(serverSettings.id, SINGLETON_ID));
  return { ...DEFAULT_SERVER_SETTINGS, ...(row ?? {}) };
}

/** 넘긴 항목만 바꾼다(행이 없으면 만들면서). */
export async function updateServerSettings(fields) {
  const [row] = await db
    .insert(serverSettings)
    .values({ ...DEFAULT_SERVER_SETTINGS, ...fields, id: SINGLETON_ID, updatedAt: new Date() })
    .onConflictDoUpdate({
      target: serverSettings.id,
      set: { ...fields, updatedAt: new Date() },
    })
    .returning();
  return { ...DEFAULT_SERVER_SETTINGS, ...row };
}
