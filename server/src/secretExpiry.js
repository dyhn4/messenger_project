import fs from 'node:fs';
import path from 'node:path';
import { findExpiredSecretMessages, hardDeleteMessage } from './db/queries/messages.js';
import { uploadsDir } from './upload.js';

const SWEEP_INTERVAL_MS = 5_000; // 타이머 최소값(1초)에 맞추려고 5초마다 자주 훑는다.

/** 첨부파일도 흔적 없이 지운다 — 자동 삭제의 취지가 소프트 삭제(내용만 가림)와 다르게
 * "진짜로 없애는 것"이기 때문. 실패해도(이미 지워졌거나 경로 문제) 메시지 행 삭제는 계속한다. */
function unlinkAttachmentIfAny(fileUrl) {
  if (!fileUrl) return;
  try {
    fs.unlinkSync(path.join(uploadsDir, path.basename(fileUrl)));
  } catch {
    // 이미 없거나 접근 실패 — 메시지 행 삭제를 막을 이유는 아니다.
  }
}

async function sweepExpiredSecretMessages(io) {
  const expired = await findExpiredSecretMessages();
  for (const m of expired) {
    unlinkAttachmentIfAny(m.fileUrl);
    await hardDeleteMessage(m.id);
    io.to(m.roomId).emit('message:expired', { roomId: m.roomId, messageId: m.id });
  }
}

/** 서버 시작 시 한 번, 이후 짧은 간격으로 계속 — 비밀 대화 자동 삭제 타이머(1초~1주)를 처리한다. */
export function startSecretExpiryJob(io) {
  sweepExpiredSecretMessages(io).catch((e) => console.error('[secretExpiry] 만료 처리 실패:', e));
  setInterval(() => {
    sweepExpiredSecretMessages(io).catch((e) => console.error('[secretExpiry] 만료 처리 실패:', e));
  }, SWEEP_INTERVAL_MS);
}
