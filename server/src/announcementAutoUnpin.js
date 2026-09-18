import { findAnnouncementsPastAutoUnpin, unpinAnnouncement } from './db/queries/announcements.js';

// secretExpiry.js의 SWEEP_INTERVAL_MS(5초)보다 훨씬 길게 잡는다 — 가장 짧은 빠른 선택지가
// 1시간이라 초 단위 정밀도가 필요 없다.
const SWEEP_INTERVAL_MS = 30_000;

async function sweepExpiredAnnouncementPins(io) {
  const expired = await findAnnouncementsPastAutoUnpin();
  for (const a of expired) {
    await unpinAnnouncement(a.id);
    // 수동 "공지 내리기"와 완전히 같은 이벤트 — 클라이언트는 누가/어떻게 내렸는지 구분할
    // 필요가 없다(announcement_list_screen.dart/session.dart의 announcement:unpinned 처리).
    io.to(a.roomId).emit('announcement:unpinned', { id: a.id, roomId: a.roomId });
  }
}

/** 서버 시작 시 한 번, 이후 주기적으로 — "공지 자동 내리기" 시각이 지난 공지를 내린다
 * (secretExpiry.js의 startSecretExpiryJob과 같은 패턴). */
export function startAnnouncementAutoUnpinJob(io) {
  sweepExpiredAnnouncementPins(io).catch((e) => console.error('[announcementAutoUnpin] 처리 실패:', e));
  setInterval(() => {
    sweepExpiredAnnouncementPins(io).catch((e) => console.error('[announcementAutoUnpin] 처리 실패:', e));
  }, SWEEP_INTERVAL_MS);
}
