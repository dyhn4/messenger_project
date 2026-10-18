import fs from 'node:fs';
import { blockImageSources, blocksToText, resolveBlockImages } from './botBlocks.js';
import { findRoomById } from './db/queries/rooms.js';
import { softDeleteMessage } from './db/queries/messages.js';
import { db } from './db/client.js';
import { messages } from './db/schema.js';
import { eq } from 'drizzle-orm';
import { previewWebpOf, sniffImageType, storeRemoteImage, storeUpload } from './linkPreviewImage.js';
import { clipGraphemes, MESSAGE_TEXT_MAX } from './messageLimits.js';
import { toMessageDto } from './messages.js';
import { removeNotificationsForMessage } from './notifications.js';
import { postBotMessage } from './rooms.js';
import { notifyMessageDeleted, notifyMessageUpdated } from './webhookDelivery.js';

/**
 * 외부 연동의 **봇 메시지** 올리기·바꾸기·지우기 — 들어오는 웹훅·슬래시 명령·단추 누름의 답(integrations.js·integrationActions.js)과
 * 봇 토큰 공개 API(publicApi.js)가 같이 쓴다. 블록의 바깥 그림과 본문의 image_url은 서버가 받아 업로드 파일로 두고(linkPreviewImage.js
 * storeRemoteImage — 보는 사람의 앱이 바깥 사이트에 직접 접속하지 않게), 함께 올린 파일(웹훅 multipart)은 그림이면 미리보기를 만든다.
 */

const clipText = (t) => clipGraphemes(t, MESSAGE_TEXT_MAX - 1);

/**
 * 올릴 내용 → postBotMessage에 넘길 { text, botBlocks, attachments }. [blocks]는 botBlocks.js sanitizeBlocks의 결과(그림은 아직 src),
 * [imageUrls]는 그림 첨부로 붙일 바깥 그림 주소, [files]는 이미 업로드 파일로 둔 첨부(attachmentsFromUploads). 글이 비면 블록에서
 * 글을 만든다.
 */
export async function prepareBotContent({ text = '', blocks = null, imageUrls = [], files = [] }) {
  const sources = [...new Set([...blockImageSources(blocks), ...imageUrls])];
  const stored = new Map();
  await Promise.all(
    sources.map(async (src) => {
      const img = await storeRemoteImage(src);
      if (img) stored.set(src, img);
    }),
  );
  const botBlocks = resolveBlockImages(blocks, new Map([...stored].map(([src, img]) => [src, img.fileUrl])));
  const attachments = [...files, ...imageUrls.map((u) => stored.get(u)).filter(Boolean).map((img) => ({ kind: 'image', ...img }))];
  const body = text || blocksToText(botBlocks);
  return { text: body ? clipText(body) : attachments.length ? null : '', botBlocks, attachments };
}

/** 연동([integration] — 이름·아이콘)의 봇 메시지로 올린다. [senderName]이 있으면(Slack username) 그 이름으로. 올린 메시지 DTO. */
export async function postBotContent(io, room, integration, content, { senderName = null } = {}) {
  const prepared = await prepareBotContent(content);
  return postBotMessage(io, room, prepared.text, {
    senderName: senderName ?? integration.name,
    integrationId: integration.id,
    botEmoji: integration.emoji,
    botBlocks: prepared.botBlocks,
    attachments: prepared.attachments,
  });
}

/**
 * 봇 메시지의 글·블록을 바꾼다(단추를 누른 뒤 "승인됨"으로 바꾸기·봇 API의 고치기) — "(수정됨)" 표시가 붙고 방에 message:edited로 알린다.
 * [content]의 text·blocks 중 보낸 것만 바꾼다(blocks: null이면 블록을 없앤다).
 */
export async function updateBotMessage(io, message, content, { room = null, sourceIntegrationId = null } = {}) {
  const patch = { editedAt: new Date() };
  let blocks = message.botBlocks ?? null;
  if (content.blocks !== undefined) {
    const prepared = await prepareBotContent({ blocks: content.blocks });
    blocks = prepared.botBlocks;
    patch.botBlocks = blocks;
  }
  if (content.text !== undefined || content.blocks !== undefined) {
    const text = (content.text ?? '') || blocksToText(blocks) || message.text || '';
    patch.text = clipText(text);
  }
  const [updated] = await db.update(messages).set(patch).where(eq(messages.id, message.id)).returning();
  const dto = toMessageDto(updated);
  io.to(message.roomId).emit('message:edited', dto);
  const r = room ?? (await findRoomById(message.roomId));
  notifyMessageUpdated(r, dto, { sourceIntegrationId });
  return dto;
}

/** 봇 메시지를 지운다(자리만 남는 지움 — 댓글이 달렸을 수 있다). */
export async function removeBotMessage(io, message, { room = null, sourceIntegrationId = null } = {}) {
  await removeNotificationsForMessage(io, message.id);
  await softDeleteMessage(message.id);
  io.to(message.roomId).emit('message:deleted', { id: message.id, roomId: message.roomId });
  const r = room ?? (await findRoomById(message.roomId));
  notifyMessageDeleted(r, message.id, { sourceIntegrationId });
}

/**
 * multer가 업로드 폴더에 받아 둔 파일들(웹훅 multipart) → 봇 메시지 첨부. 그림(내용으로 확인 — png·jpeg·gif·webp)이면 말풍선용 미리보기
 * (800px WEBP)를 만들고, 그 밖은 파일. uploads 표에는 올린 사람 없이(null) 남긴다. 실패하면 받은 파일을 지우고 throw.
 */
export async function attachmentsFromUploads(files) {
  const { insertUpload } = await import('./db/queries/uploads.js');
  const out = [];
  try {
    for (const f of files) {
      await insertUpload({ fileName: f.filename, uploaderId: null });
      const head = Buffer.alloc(16);
      const fd = await fs.promises.open(f.path, 'r');
      try {
        await fd.read(head, 0, 16, 0);
      } finally {
        await fd.close();
      }
      const kind = ['png', 'jpeg', 'gif', 'webp'].includes(sniffImageType(head)) ? 'image' : 'file';
      let thumbnailUrl = null;
      if (kind === 'image' && f.size <= 30 * 1024 * 1024) {
        try {
          thumbnailUrl = await storeUpload(await previewWebpOf(await fs.promises.readFile(f.path)), null);
        } catch {
          thumbnailUrl = null; // 미리보기를 못 만들어도 원본은 그대로 붙인다.
        }
      }
      out.push({
        kind,
        fileUrl: `/uploads/${f.filename}`,
        fileName: f.originalname || f.filename,
        fileSize: f.size,
        mimeType: f.mimetype || null,
        thumbnailUrl,
      });
    }
  } catch (err) {
    await discardUploads(files);
    throw err;
  }
  return out;
}

/** 쓰지 않게 된 받은 파일을 지운다(웹훅 거절 등). */
export async function discardUploads(files) {
  await Promise.all((files ?? []).map((f) => fs.promises.unlink(f.path).catch(() => {})));
}
