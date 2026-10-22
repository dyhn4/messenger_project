import fs from 'node:fs/promises';
import path from 'node:path';
import { refreshCallCardRecordings } from './callCards.js';
import { planRecordingPurge } from './callRecordingRules.js';
import {
  countPurgedRecordings,
  listKeptRecordingFiles,
  listMessagesWithFile,
  updateCallRecording,
} from './db/queries/callRecordings.js';
import { applyFileDelete } from './db/queries/fileDelete.js';
import { findMessageById, listAttachmentsForMessages } from './db/queries/messages.js';
import { getServerSettings } from './db/queries/serverSettings.js';
import { planFileDelete } from './fileDeletePlan.js';
import { toMessageDto } from './messages.js';
import { uploadFileNameOf, uploadsDir } from './upload.js';

/**
 * 화상회의 녹화 파일 보관 — 관리자 콘솔("운영 현황")에서 정한 보관 기간(일)·전체 용량(GB)을 넘으면 오래된 녹화 파일부터 지운다.
 * 녹화 파일은 크고(영상 한 시간에 수백 MB) 업로드 폴더를 금방 채워서, 다른 파일과 달리 디스크에서도 지운다(파일 삭제
 * messageFiles.js는 디스크 파일을 남기는 소프트 삭제). 대화방의 파일 메시지(와 그것을 전달한 메시지)는 "삭제된 파일"로 바뀌고,
 * 회의록(받아쓰기·요약)과 화상회의 카드의 녹화 줄은 남는다(카드에 "보관 기간이 지나 파일을 지움").
 *
 * 하루에 한 번, 그리고 녹화 파일을 새로 올릴 때마다(용량을 넘었을 수 있다) 본다. 설정이 없으면 아무것도 지우지 않는다.
 */

const CHECK_INTERVAL_MS = 24 * 60 * 60 * 1000;
const GB = 1024 * 1024 * 1024;

/** 녹화 줄의 파일 크기 — 예전 줄(크기를 적기 전)은 디스크에서 재고 적어 둔다. 파일이 없으면 0. */
async function sizeOf(row) {
  if (row.fileSize != null) return Number(row.fileSize);
  const name = uploadFileNameOf(row.filePath);
  let size = 0;
  try {
    if (name) size = (await fs.stat(path.join(uploadsDir, name))).size;
  } catch {
    size = 0;
  }
  await updateCallRecording(row.id, { fileSize: size }).catch(() => {});
  return size;
}

/** 녹화 파일 하나를 지운다 — 그 파일을 가리키는 메시지는 모두 "삭제된 파일"로, 디스크 파일도, 녹화 줄에 지운 시각·까닭을. */
export async function purgeRecordingFile(io, row, reason) {
  const fileUrl = row.filePath;
  for (const message of await listMessagesWithFile(fileUrl)) {
    const rows = (await listAttachmentsForMessages([message.id]))[message.id] ?? [];
    const target = rows.find((a) => a.fileUrl === fileUrl && !a.deletedAt);
    const plan = planFileDelete({ message, rows, attachmentId: target?.id ?? null });
    if (!plan.ok) continue;
    await applyFileDelete(message.id, { plan, message, userId: null });
    const after = await findMessageById(message.id);
    const attachments = (await listAttachmentsForMessages([message.id]))[message.id];
    io?.to(message.roomId).emit('message:edited', toMessageDto({ ...after, attachments }));
  }
  const name = uploadFileNameOf(fileUrl);
  if (name) await fs.unlink(path.join(uploadsDir, name)).catch(() => {});
  await updateCallRecording(row.id, { purgedAt: new Date(), purgeReason: reason });
  await refreshCallCardRecordings(io, row.roomId, row.callMessageId).catch(() => {});
}

let running = null;

/** 보관 기간·용량을 넘은 녹화 파일을 지운다 → 지운 수. 한 번에 하나만 돈다. */
export function purgeCallRecordings(io, { now = Date.now() } = {}) {
  running ??= (async () => {
    try {
      const settings = await getServerSettings();
      const retentionDays = settings.callRecordingRetentionDays ?? null;
      const maxBytes = settings.callRecordingMaxGb != null ? settings.callRecordingMaxGb * GB : null;
      if (retentionDays == null && maxBytes == null) return 0;
      const rows = await listKeptRecordingFiles();
      const sized = [];
      for (const row of rows) sized.push({ ...row, fileSize: await sizeOf(row) });
      const plan = planRecordingPurge(sized, { now, retentionDays, maxBytes });
      const byId = new Map(sized.map((r) => [r.id, r]));
      for (const { id, reason } of plan) {
        await purgeRecordingFile(io, byId.get(id), reason).catch((err) =>
          console.error('[call] 녹화 파일을 지우지 못했습니다:', id, err?.message ?? err),
        );
      }
      if (plan.length > 0) console.log(`[call] 보관 기간·용량을 넘은 녹화 파일 ${plan.length}개를 지웠습니다.`);
      return plan.length;
    } finally {
      running = null;
    }
  })();
  return running;
}

/** 관리자 콘솔에 보여 줄 것 — 설정과 지금 남은 녹화 파일 수·용량, 지운 수. */
export async function recordingRetentionView() {
  const settings = await getServerSettings();
  const rows = await listKeptRecordingFiles();
  let totalBytes = 0;
  for (const row of rows) totalBytes += await sizeOf(row);
  return {
    retentionDays: settings.callRecordingRetentionDays ?? null,
    maxGb: settings.callRecordingMaxGb ?? null,
    count: rows.length,
    totalBytes,
    purgedCount: await countPurgedRecordings(),
  };
}

/** 서버가 켜지고 조금 뒤 한 번, 그 뒤 하루에 한 번. */
export function startCallRecordingRetentionJob(io) {
  const run = () => purgeCallRecordings(io).catch((err) => console.error('[call] 녹화 보관 정리 실패:', err?.message ?? err));
  setTimeout(run, 60 * 1000).unref?.();
  setInterval(run, CHECK_INTERVAL_MS).unref?.();
}
