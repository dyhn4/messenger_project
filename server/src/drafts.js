import { Router } from 'express';
import { RateLimiter, tooMany } from './authGuard.js';
import { deleteDraftsBefore, listMyDrafts, upsertDraft } from './db/queries/drafts.js';
import { findRoomById, isRoomMember } from './db/queries/rooms.js';
import { DEVICE_ID_RE, DRAFT_MAX_AGE_MS, draftDto, parseDraftInput } from './draftRules.js';

/**
 * 대화방 임시 저장 동기화 — 입력칸에 쓰다 만 글을 내 다른 기기와 맞춘다(앱 chat_draft_store.dart). 마지막에 고친 것이 이긴다(서버가 받은
 * 순서). 바뀌면 내 다른 기기에 소켓 `draft:changed { roomId, text, format, mentions, updatedAt, deviceId }`(지우면 text가 null) — 보낸 기기는
 * [deviceId]로 자기 것을 알아보고 무시한다. 비밀 대화의 글은 받지 않는다(서버에 평문이 남으면 안 된다). 30일 지난 글은 지운다.
 * 입력 검사·모양은 draftRules.js.
 */

const draftLimiter = new RateLimiter({ max: 240, windowMs: 60 * 1000 });
setInterval(() => draftLimiter.prune(), 60 * 1000).unref();

export function createDraftsRouter(io) {
  const router = Router();

  router.get('/drafts', async (req, res) => {
    const rows = await listMyDrafts(req.user.sub, new Date(Date.now() - DRAFT_MAX_AGE_MS));
    res.json(rows.map(draftDto));
  });

  /** 넣기·바꾸기 `{ text, format?, mentions?, deviceId? }` — text가 비면 지운다(빈 글로 남김). → `{ updatedAt }`. */
  router.put('/rooms/:roomId/draft', async (req, res) => {
    const wait = draftLimiter.hit(req.user.sub);
    if (wait) return tooMany(res, wait, '임시 저장');
    const roomId = req.params.roomId;
    const room = typeof roomId === 'string' && roomId.length <= 100 ? await findRoomById(roomId) : null;
    if (!room || !(await isRoomMember(room.id, req.user.sub))) return res.status(404).json({ error: '대화방을 찾을 수 없습니다.' });
    if (room.isSecret) return res.status(400).json({ error: '비밀 대화의 글은 서버에 저장하지 않습니다.' });
    const parsed = parseDraftInput(req.body);
    if (parsed.error) return res.status(400).json({ error: parsed.error });
    const deviceId = typeof req.body?.deviceId === 'string' && DEVICE_ID_RE.test(req.body.deviceId) ? req.body.deviceId : null;
    if (!parsed.values) {
      // 지운 것도 시각과 함께 남긴다(빈 글 — 꺼져 있던 기기가 다시 붙을 때 지워졌다는 것을 알게). 30일 뒤 정리 작업이 지운다.
      const clearedAt = await upsertDraft(req.user.sub, room.id, { text: '', textFormat: null, mentions: null });
      const at = new Date(clearedAt).getTime();
      io.to(`user:${req.user.sub}`).emit('draft:changed', { roomId: room.id, text: null, updatedAt: at, deviceId });
      return res.json({ updatedAt: at });
    }
    const updatedAt = await upsertDraft(req.user.sub, room.id, parsed.values);
    io.to(`user:${req.user.sub}`).emit('draft:changed', {
      ...draftDto({ roomId: room.id, ...parsed.values, updatedAt }),
      deviceId,
    });
    res.json({ updatedAt: new Date(updatedAt).getTime() });
  });

  return router;
}

/** 오래된 임시 저장 정리 — 하루 한 번. */
export function startDraftCleanupJob() {
  const run = () =>
    deleteDraftsBefore(new Date(Date.now() - DRAFT_MAX_AGE_MS)).catch((err) => console.error('[drafts] 정리 실패:', err?.message ?? err));
  setTimeout(run, 60 * 1000).unref();
  setInterval(run, 24 * 60 * 60 * 1000).unref();
}
