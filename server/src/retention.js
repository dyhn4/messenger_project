import { deleteExpiredEmailCodes } from './db/queries/emailCodes.js';
import { deleteApprovalNotificationsOlderThan } from './db/queries/groupware.js';
import { deleteMessagesBySender } from './db/queries/messages.js';
import { deleteNotificationsOlderThan } from './db/queries/notifications.js';
import { listUsersEligibleForMessagePurge, updateUser } from './db/queries/users.js';

const RETENTION_MS = 365 * 24 * 60 * 60 * 1000; // 탈퇴 후 메시지를 보존하는 기간(1년).
const CHECK_INTERVAL_MS = 24 * 60 * 60 * 1000; // 하루에 한 번 검사.
const NOTIFICATION_RETENTION_MS = 90 * 24 * 60 * 60 * 1000; // 알림 기록(멘션·보드 알림)은 90일 보존.

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

/** 90일 지난 알림 기록을 지운다 — 알림 센터는 최근 것만 보여주면 되고, 표가 끝없이 커지지 않게 한다. */
async function purgeOldNotifications() {
  const cutoff = new Date(Date.now() - NOTIFICATION_RETENTION_MS);
  const deleted = await deleteNotificationsOlderThan(cutoff);
  if (deleted > 0) console.log(`[retention] 90일 지난 알림 기록 ${deleted}건 삭제`);
  // 결재 알림함(알림 센터 "결재" 탭)도 같은 기간 — 결재 문서 자체는 지우지 않는다.
  const approvals = await deleteApprovalNotificationsOlderThan(cutoff);
  if (approvals > 0) console.log(`[retention] 90일 지난 결재 알림 ${approvals}건 삭제`);
}

/** 서버 시작 시 한 번(그동안 꺼져있던 사이 놓친 것들도 처리), 이후 하루 간격으로 검사한다. */
export function startRetentionJob() {
  const run = () => {
    purgeExpiredMessages().catch((e) => console.error('[retention] 파기 작업 실패:', e));
    purgeOldNotifications().catch((e) => console.error('[retention] 알림 정리 실패:', e));
    // 만료된 메일 확인 코드(10분짜리)는 쓸 일이 없다 — 표가 쌓이지 않게 지운다.
    deleteExpiredEmailCodes().catch((e) => console.error('[retention] 확인 코드 정리 실패:', e));
  };
  run();
  setInterval(run, CHECK_INTERVAL_MS);
}
