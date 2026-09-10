import { eq } from 'drizzle-orm';
import { db } from '../client.js';
import { serverSettings } from '../schema.js';

/** 서버 설정은 항상 이 한 행만 쓴다. */
const SINGLETON_ID = 1;

// teamInviteLinkCreation은 스키마 기본값(schema.js)과 맞춰 'admin'을 명시한다 — 설정 행이
// 아직 한 번도 안 만들어졌을 때(관리자가 설정을 한 번도 안 건드린 설치 직후) 이 값이 그대로
// canCreateTeamInviteLink에 쓰이므로, 등급/팀 합류를 동시에 주는 기능답게 기본을 보수적으로 둔다.
export const DEFAULT_SERVER_SETTINGS = { teamCreation: 'anyone', teamInviteLinkCreation: 'admin' };

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
