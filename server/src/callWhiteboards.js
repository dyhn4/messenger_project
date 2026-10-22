import { Router } from 'express';
import { desc, eq } from 'drizzle-orm';
import { topicAccess } from './access.js';
import { isRestrictedTopic } from './callAccess.js';
import { db } from './db/client.js';
import { findRoomById, isRoomMember } from './db/queries/rooms.js';
import { findUserById } from './db/queries/users.js';
import { callWhiteboards } from './db/schema.js';
import { parseWhiteboardData, whiteboardTitle } from './callWhiteboardRules.js';
import { topicWriteDenial } from './permissions.js';

/**
 * 저장한 화상회의 화이트보드 — 판은 참가자 기기에만 있어서(LiveKit 데이터 채널), 앱이 [저장]할 때 그림(PNG)을 대화방에 올리는 것과
 * 함께 획 자체를 여기 둔다. 다음 통화의 화이트보드 [불러오기]가 목록에서 골라 모두의 판에 펴고 이어 그리며, 다시 저장하면 같은 판을
 * 고친다(앱 call_whiteboard.dart — 데이터 모양 `{ v: 1, pages: [{ id, strokes: [{ id, a, c, w, p }] }] }`). 서버는 크기·모양만 본다.
 *
 *  - GET  /rooms/:id/whiteboards — 그 방에 저장한 판(새로 고친 순, 데이터 없이).
 *  - POST /rooms/:id/whiteboards `{ title?, data }` — 새로 저장 → 201 `{ whiteboard }`.
 *  - GET  /call-whiteboards/:id — 판 하나(데이터 포함).
 *  - PUT  /call-whiteboards/:id `{ data, title? }` — 다시 저장(이어 그린 판).
 *  - DELETE /call-whiteboards/:id — 처음 저장한 사람이나 토픽 관리자.
 * 방 멤버만(비밀 대화·나와의 대화는 통화가 없다). 읽기 전용·보관된 토픽은 토픽 관리자만 저장한다(그림을 올리는 것과 같다).
 */

function toDto(row, { withData = false } = {}) {
  return {
    id: row.id,
    roomId: row.roomId,
    title: row.title,
    pageCount: row.pageCount,
    createdBy: row.createdBy,
    createdByName: row.createdByName,
    updatedByName: row.updatedByName,
    createdAt: new Date(row.createdAt).getTime(),
    updatedAt: new Date(row.updatedAt).getTime(),
    ...(withData && { data: row.data }),
  };
}

const LIST_LIMIT = 50;

export function createCallWhiteboardsRouter() {
  const router = Router();

  /** 방과 멤버인지 — 아니면 응답하고 null. */
  async function roomFor(req, res, roomId) {
    const room = await findRoomById(roomId);
    if (!room || !(await isRoomMember(room.id, req.user.sub))) {
      res.status(404).json({ error: '방을 찾을 수 없습니다.' });
      return null;
    }
    if (room.isSecret) {
      res.status(400).json({ error: '비밀 대화에는 화상회의가 없습니다.' });
      return null;
    }
    return room;
  }

  async function writeDenied(res, room, userId) {
    if (!isRestrictedTopic(room)) return false;
    const denial = topicWriteDenial({ room, canManage: (await topicAccess(room, userId)).canManage });
    if (!denial) return false;
    res.status(403).json({ error: '읽기 전용 토픽에서는 토픽 관리자만 화이트보드를 저장할 수 있습니다.' });
    return true;
  }

  async function boardFor(req, res) {
    const id = req.params.id;
    const [row] = /^[0-9a-f-]{36}$/i.test(id)
      ? await db.select().from(callWhiteboards).where(eq(callWhiteboards.id, id))
      : [];
    const room = row ? await roomFor(req, res, row.roomId) : null;
    if (!row) res.status(404).json({ error: '화이트보드를 찾을 수 없습니다.' });
    return row && room ? { row, room } : null;
  }

  async function nameOf(userId) {
    const user = await findUserById(userId);
    return user?.name ?? user?.username ?? '알 수 없음';
  }

  router.get('/rooms/:id/whiteboards', async (req, res) => {
    const room = await roomFor(req, res, req.params.id);
    if (!room) return;
    const rows = await db
      .select()
      .from(callWhiteboards)
      .where(eq(callWhiteboards.roomId, room.id))
      .orderBy(desc(callWhiteboards.updatedAt))
      .limit(LIST_LIMIT);
    res.json({ whiteboards: rows.map((r) => toDto(r)) });
  });

  router.post('/rooms/:id/whiteboards', async (req, res) => {
    const room = await roomFor(req, res, req.params.id);
    if (!room || (await writeDenied(res, room, req.user.sub))) return;
    const parsed = parseWhiteboardData(req.body?.data);
    if (parsed.error) return res.status(400).json({ error: parsed.error });
    const name = await nameOf(req.user.sub);
    const [row] = await db
      .insert(callWhiteboards)
      .values({
        roomId: room.id,
        title: whiteboardTitle(req.body?.title),
        data: parsed.data,
        pageCount: parsed.pageCount,
        createdBy: req.user.sub,
        createdByName: name,
        updatedByName: name,
      })
      .returning();
    res.status(201).json({ whiteboard: toDto(row) });
  });

  router.get('/call-whiteboards/:id', async (req, res) => {
    const found = await boardFor(req, res);
    if (found) res.json({ whiteboard: toDto(found.row, { withData: true }) });
  });

  router.put('/call-whiteboards/:id', async (req, res) => {
    const found = await boardFor(req, res);
    if (!found || (await writeDenied(res, found.room, req.user.sub))) return;
    const parsed = parseWhiteboardData(req.body?.data);
    if (parsed.error) return res.status(400).json({ error: parsed.error });
    const [row] = await db
      .update(callWhiteboards)
      .set({
        data: parsed.data,
        pageCount: parsed.pageCount,
        ...(typeof req.body?.title === 'string' && { title: whiteboardTitle(req.body.title) }),
        updatedByName: await nameOf(req.user.sub),
        updatedAt: new Date(),
      })
      .where(eq(callWhiteboards.id, found.row.id))
      .returning();
    res.json({ whiteboard: toDto(row) });
  });

  router.delete('/call-whiteboards/:id', async (req, res) => {
    const found = await boardFor(req, res);
    if (!found) return;
    const mine = found.row.createdBy === req.user.sub;
    if (!mine && !(await topicAccess(found.room, req.user.sub)).canManage) {
      return res.status(403).json({ error: '화이트보드는 처음 저장한 사람이나 토픽 관리자만 지울 수 있습니다.' });
    }
    await db.delete(callWhiteboards).where(eq(callWhiteboards.id, found.row.id));
    res.json({ ok: true });
  });

  return router;
}
