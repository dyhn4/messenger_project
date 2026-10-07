import fs from 'node:fs';
import path from 'node:path';
import { listCommentsForMessages } from './db/queries/comments.js';
import { findExpiredSecretMessages, hardDeleteMessage, listAttachmentsForMessages } from './db/queries/messages.js';
import { findReferencedUploadPaths, findUploaders } from './db/queries/uploads.js';
import { ownedUploadClaims, uploadFileNameOf, uploadsDir } from './upload.js';

const SWEEP_INTERVAL_MS = 5_000; // 타이머 최소값(1초)에 맞추려고 5초마다 자주 훑는다.

/**
 * 만료된 메시지들과 함께 없앨 업로드 파일을 고른다 — Map(메시지 id → 저장 경로 Set). 자동 삭제의 취지가 소프트 삭제(내용만 가림)와
 * 다르게 "진짜로 없애는 것"이라 첨부도 지우는데, 서버에서 파일을 실제로 지우는 곳은 여기뿐이라 남의 파일은 절대 지우지 않게 둘 다
 * 맞아야 한다(예전엔 메시지에 적힌 아무 파일이나 지워서, 남의 파일 링크를 비밀 대화로 보내면 그 파일이 지워졌다):
 *   (가) uploads 표가 그 파일을 실은 사람(메시지·첨부는 보낸 사람, 댓글은 단 사람)이 직접 올렸다고 말한다(ownedUploadClaims) —
 *        기록이 없는 파일(이 표가 생기기 전에 올린 것)은 누가 올렸는지 몰라 지우지 않는다.
 *   (나) 지워질 메시지들(과 함께 지워지는 첨부·댓글·파일 즐겨찾기) 밖에서는 아무 데서도 그 경로를 쓰지 않는다.
 * 메시지의 파일·미리보기 칸, 첨부 목록(원본·미리보기), 그 메시지에 달린 댓글의 파일까지 본다 — 메시지 행을 지우면 첨부·댓글 행도
 * FK cascade로 사라져서, 예전엔 파일 칸 하나만 지우고 나머지 파일은 주인 없이 남았다. 참조 확인(나)은 무거워서 (가)를 통과한
 * 후보가 있을 때만, 이번에 만료된 메시지 전부를 묶어 한 번 한다.
 */
async function filesToRemove(expired) {
  const ids = expired.map((m) => m.id);
  const [attachmentsByMessage, comments] = await Promise.all([
    listAttachmentsForMessages(ids),
    listCommentsForMessages(ids),
  ]);
  const claims = [];
  const claim = (messageId, ownerId, url) => {
    if (uploadFileNameOf(url)) claims.push({ messageId, ownerId, path: url });
  };
  for (const m of expired) {
    claim(m.id, m.senderId, m.fileUrl);
    claim(m.id, m.senderId, m.thumbnailUrl);
    for (const a of attachmentsByMessage[m.id] ?? []) {
      claim(m.id, m.senderId, a.fileUrl);
      claim(m.id, m.senderId, a.thumbnailUrl);
    }
  }
  for (const c of comments) {
    claim(c.messageId, c.senderId, c.fileUrl);
    claim(c.messageId, c.senderId, c.thumbnailUrl);
  }
  if (claims.length === 0) return new Map();

  const owned = ownedUploadClaims(claims, await findUploaders(claims.map((c) => uploadFileNameOf(c.path))));
  if (owned.length === 0) return new Map();
  const referenced = await findReferencedUploadPaths(
    owned.map((c) => c.path),
    { excludeMessageIds: ids },
  );
  const byMessage = new Map();
  for (const c of owned) {
    if (referenced.has(c.path)) continue;
    if (!byMessage.has(c.messageId)) byMessage.set(c.messageId, new Set());
    byMessage.get(c.messageId).add(c.path);
  }
  return byMessage;
}

/** 업로드 폴더의 그 파일을 지운다. 실패해도(이미 지워졌거나 경로 문제) 넘어간다 — 메시지 행은 이미 지웠다. */
async function unlinkUpload(storedPath) {
  const name = uploadFileNameOf(storedPath);
  if (!name) return;
  try {
    await fs.promises.unlink(path.join(uploadsDir, name));
  } catch {
    // 이미 없거나 접근 실패 — 다른 메시지 처리를 막을 이유는 아니다.
  }
}

async function sweepExpiredSecretMessages(io) {
  const expired = await findExpiredSecretMessages();
  if (expired.length === 0) return;
  // 지울 파일은 메시지 행을 지우기 전에 고른다(지우면 첨부·댓글 행이 같이 사라진다). 고르다 실패하면(DB 오류 등) 파일은 남기고
  // 메시지만 지운다 — 파일을 잘못 지우는 것보다 남는 쪽이 낫고, 자동 삭제 자체가 멈추면 안 된다(남는 파일은 암호문이라 복호화
  // 키를 담은 메시지가 없으면 읽을 수 없다).
  let files = new Map();
  try {
    files = await filesToRemove(expired);
  } catch (e) {
    console.error('[secretExpiry] 첨부 정리 대상 확인 실패(이번 파일은 남김):', e);
  }
  for (const m of expired) {
    await hardDeleteMessage(m.id);
    io.to(m.roomId).emit('message:expired', { roomId: m.roomId, messageId: m.id });
    for (const storedPath of files.get(m.id) ?? []) await unlinkUpload(storedPath);
  }
}

// 앞 차례가 아직 도는 중이면 건너뛴다 — 참조 확인이 길어지면 5초 간격이 겹쳐 같은 메시지를 두 번 처리하게 된다.
let sweeping = false;

function runSweep(io) {
  if (sweeping) return;
  sweeping = true;
  sweepExpiredSecretMessages(io)
    .catch((e) => console.error('[secretExpiry] 만료 처리 실패:', e))
    .finally(() => {
      sweeping = false;
    });
}

/** 서버 시작 시 한 번, 이후 짧은 간격으로 계속 — 비밀 대화 자동 삭제 타이머(1초~1주)를 처리한다. */
export function startSecretExpiryJob(io) {
  runSweep(io);
  setInterval(() => runSweep(io), SWEEP_INTERVAL_MS);
}
