import { deleteMessagesBySender } from './db/queries/messages.js';
import { listUsersEligibleForMessagePurge, updateUser } from './db/queries/users.js';

const RETENTION_MS = 365 * 24 * 60 * 60 * 1000; // 탈퇴 후 메시지를 보존하는 기간(1년).
const CHECK_INTERVAL_MS = 24 * 60 * 60 * 1000; // 하루에 한 번 검사.

/**
 * 탈퇴 후 보존 기간(1년)이 지난 계정의 메시지를 파기한다.
 * 첨부 파일은 보존 정책에 따라 지우지 않는다 — 메시지 행만 지운다.
 * user.messagesPurgedAt으로 이미 처리한 계정을 표시해서 매번 다시 스캔하지 않는다.
 */
async function purgeExpiredMessages() {
  const eligible = await listUsersEligibleForMessagePurge(RETENTION_MS);

  for (const user of eligible) {
    const purged = await deleteMessagesBySender(user.id);
    await updateUser(user.id, { messagesPurgedAt: new Date() });
    console.log(`[retention] 탈퇴 계정 ${user.id}: 보존 기간(1년) 만료로 메시지 ${purged}건 파기(첨부 파일은 유지)`);
  }
}

/** 서버 시작 시 한 번(그동안 꺼져있던 사이 놓친 것들도 처리), 이후 하루 간격으로 검사한다. */
export function startRetentionJob() {
  purgeExpiredMessages().catch((e) => console.error('[retention] 파기 작업 실패:', e));
  setInterval(() => {
    purgeExpiredMessages().catch((e) => console.error('[retention] 파기 작업 실패:', e));
  }, CHECK_INTERVAL_MS);
}
