import { Router } from 'express';
import { and, eq, isNull, or } from 'drizzle-orm';
import { db } from './db/client.js';
import { albumItems, albums, messageAttachments, messageComments, messages, stickers, users } from './db/schema.js';
import { isRoomMember } from './db/queries/rooms.js';
import { knownUploadPath, signFileUrl } from './upload.js';

/**
 * 첨부 다운로드 링크 새로 받기 — 메시지에 실려 온 /files/<토큰> 링크는 최대 2시간 뒤에 만료되는데,
 * 앱은 방을 한 번 불러오면 그 메시지를 계속 들고 있어서 오래 켜 둔 채 내려받으면 만료된 링크로
 * 요청하게 된다(401). 이때 앱이 만료된 링크를 여기 보내면, 그 파일이 **내가 들어 있는 방의**
 * 메시지·댓글·앨범 첨부일 때만 새로 서명한 링크를 돌려준다(requireAuth 뒤 — 로그인한 사람 기준).
 * 서명이 위조됐거나 내가 못 보는 방의 파일이면 404.
 */
export function createFileResignRouter() {
  const router = Router();

  router.post('/files/resign', async (req, res) => {
    const raw = knownUploadPath(req.body?.url);
    if (!raw) return res.status(400).json({ error: '알 수 없는 파일 링크입니다.' });

    const rows = [
      ...(await db
        .select({ roomId: messages.roomId, fileName: messages.fileName })
        .from(messages)
        // 지운 메시지·지운 파일은 다시 받을 수 없다(삭제한 뒤에도 예전 링크로 새 링크를 받던 문제).
        .where(
          and(
            or(eq(messages.fileUrl, raw), eq(messages.thumbnailUrl, raw)),
            isNull(messages.deletedAt),
            isNull(messages.fileDeletedAt),
          ),
        )),
      ...(await db
        .select({ roomId: messages.roomId, fileName: messageAttachments.fileName })
        .from(messageAttachments)
        .innerJoin(messages, eq(messages.id, messageAttachments.messageId))
        .where(
          and(
            or(eq(messageAttachments.fileUrl, raw), eq(messageAttachments.thumbnailUrl, raw)),
            isNull(messageAttachments.deletedAt),
            isNull(messages.deletedAt),
          ),
        )),
      ...(await db
        .select({ roomId: messageComments.roomId, fileName: messageComments.fileName })
        .from(messageComments)
        .where(
          and(
            or(eq(messageComments.fileUrl, raw), eq(messageComments.thumbnailUrl, raw)),
            isNull(messageComments.deletedAt),
          ),
        )),
      // 앨범 항목 — 앨범이 있는 방의 멤버에게만(앨범은 대화방 파일과 별개의 저장소다).
      ...(await db
        .select({ roomId: albums.roomId, fileName: albumItems.fileName })
        .from(albumItems)
        .innerJoin(albums, eq(albums.id, albumItems.albumId))
        .where(or(eq(albumItems.fileUrl, raw), eq(albumItems.thumbnailUrl, raw)))),
    ];
    // 프로필 사진(캐릭터 세트에서 고른 그림 포함)은 같은 서비스를 쓰는 누구에게나 보이는 것이라
    // 방 멤버 여부를 따지지 않는다 — 알림 아이콘이 만료된 사진 링크를 새로 받을 때 쓴다.
    const [avatar] = await db
      .select({ id: users.id })
      .from(users)
      .where(eq(users.avatarUrl, raw))
      .limit(1);
    const [sticker] = avatar
      ? []
      : await db.select({ id: stickers.id }).from(stickers).where(or(eq(stickers.fileUrl, raw), eq(stickers.thumbnailUrl, raw))).limit(1);
    if (avatar || sticker) return res.json({ url: signFileUrl(raw) });

    for (const row of rows) {
      if (await isRoomMember(row.roomId, req.user.sub)) {
        return res.json({ url: signFileUrl(raw, row.fileName ?? undefined) });
      }
    }
    res.status(404).json({ error: '파일을 찾을 수 없습니다.' });
  });

  return router;
}
