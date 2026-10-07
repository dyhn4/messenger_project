import { Router } from 'express';
import { and, eq, gte, isNull, or } from 'drizzle-orm';
import { db } from './db/client.js';
import {
  albumItems,
  albums,
  dmHistoryFloors,
  messageAttachments,
  messageComments,
  messages,
  stickers,
  users,
} from './db/schema.js';
import { isRoomMember } from './db/queries/rooms.js';
import { findUpload } from './db/queries/uploads.js';
import { isPublicAvatarFile } from './avatarRules.js';
import { knownUploadPath, signFileUrl, uploadFileNameOf } from './upload.js';

/**
 * 첨부 다운로드 링크 새로 받기 — 메시지에 실려 온 /files/<토큰> 링크는 최대 2시간 뒤에 만료되는데,
 * 앱은 방을 한 번 불러오면 그 메시지를 계속 들고 있어서 오래 켜 둔 채 내려받으면 만료된 링크로
 * 요청하게 된다(401). 이때 앱이 만료된 링크를 여기 보내면, 그 파일이 **내가 들어 있는 방의**
 * 메시지·댓글·앨범 첨부일 때만 새로 서명한 링크를 돌려준다(requireAuth 뒤 — 로그인한 사람 기준).
 * 서명이 위조됐거나 내가 못 보는 방의 파일이면 404.
 *
 * 1:1 대화에서 "진짜 나가기"(dm_history_floors)를 한 사람에게는 그 시각 이전 글의 파일도 못 보는 파일이다 — 방 메시지 목록·메시지
 * 한 건 조회·댓글·앨범 목록이 그 글을 이 사람에게 더는 보여 주지 않는데, 예전엔 여기서 방 멤버인지만 봐서 그 전에 받아 둔 링크로
 * 새 링크를 계속 받아 갈 수 있었다. 기준 시각은 그 글이 화면에 보이는지를 정하는 시각과 같다(db/queries/uploads.js
 * findReachableUploadPaths와 같은 규칙): 메시지·첨부는 메시지, 댓글은 부모 메시지(GET /comments/:id와 같다), 앨범 항목은 앨범을
 * 만든 시각(앨범 목록과 같다). 시작선은 요청한 사람의 것만 본다 — 상대는 그대로 받는다. 비밀 대화는 빼지 않는다(앱이 비밀 대화의
 * 파일 링크도 여기서 새로 받는다 — 그래서 findReachableUploadPaths를 그대로 쓰지 않는다).
 */
export function createFileResignRouter() {
  const router = Router();

  router.post('/files/resign', async (req, res) => {
    const raw = knownUploadPath(req.body?.url);
    if (!raw) return res.status(400).json({ error: '알 수 없는 파일 링크입니다.' });

    const userId = req.user.sub;
    const rows = [
      ...(await db
        .select({ roomId: messages.roomId, fileName: messages.fileName })
        .from(messages)
        .leftJoin(dmHistoryFloors, myHistoryFloor(messages.roomId, userId))
        // 지운 메시지·지운 파일은 다시 받을 수 없다(삭제한 뒤에도 예전 링크로 새 링크를 받던 문제).
        .where(
          and(
            or(eq(messages.fileUrl, raw), eq(messages.thumbnailUrl, raw)),
            isNull(messages.deletedAt),
            isNull(messages.fileDeletedAt),
            notBeforeHistoryFloor(messages.createdAt),
          ),
        )),
      ...(await db
        .select({ roomId: messages.roomId, fileName: messageAttachments.fileName })
        .from(messageAttachments)
        .innerJoin(messages, eq(messages.id, messageAttachments.messageId))
        .leftJoin(dmHistoryFloors, myHistoryFloor(messages.roomId, userId))
        .where(
          and(
            or(eq(messageAttachments.fileUrl, raw), eq(messageAttachments.thumbnailUrl, raw)),
            isNull(messageAttachments.deletedAt),
            isNull(messages.deletedAt),
            notBeforeHistoryFloor(messages.createdAt),
          ),
        )),
      // 댓글 — 시작선은 부모 메시지 시각으로 본다(부모 글이 안 보이면 그 댓글도 안 보인다).
      ...(await db
        .select({ roomId: messageComments.roomId, fileName: messageComments.fileName })
        .from(messageComments)
        .innerJoin(messages, eq(messages.id, messageComments.messageId))
        .leftJoin(dmHistoryFloors, myHistoryFloor(messageComments.roomId, userId))
        .where(
          and(
            or(eq(messageComments.fileUrl, raw), eq(messageComments.thumbnailUrl, raw)),
            isNull(messageComments.deletedAt),
            notBeforeHistoryFloor(messages.createdAt),
          ),
        )),
      // 앨범 항목 — 앨범이 있는 방의 멤버에게만(앨범은 대화방 파일과 별개의 저장소다). 시작선은 앨범을 만든 시각으로 본다.
      ...(await db
        .select({ roomId: albums.roomId, fileName: albumItems.fileName })
        .from(albumItems)
        .innerJoin(albums, eq(albums.id, albumItems.albumId))
        .leftJoin(dmHistoryFloors, myHistoryFloor(albums.roomId, userId))
        .where(
          and(
            or(eq(albumItems.fileUrl, raw), eq(albumItems.thumbnailUrl, raw)),
            notBeforeHistoryFloor(albums.createdAt),
          ),
        )),
    ];
    // 프로필 사진(캐릭터 세트에서 고른 그림 포함)은 같은 서비스를 쓰는 누구에게나 보이는 것이라
    // 방 멤버 여부를 따지지 않는다 — 알림 아이콘이 만료된 사진 링크를 새로 받을 때 쓴다.
    // 다만 "지금 누군가의 프로필 사진"이라는 것만으로는 안 된다: 예전엔 프로필 사진 경로를 보낸 그대로 저장해서, 남이 올린
    // (내가 더는 못 보는·지운) 파일을 프로필 사진으로 걸어 두면 여기서 누구나 새 링크를 받아 갔다. 그래서 uploads 표에 기록이
    // 있는 파일이면 그 파일을 올린 사람 자신의 지금 사진 아바타일 때만 공개로 본다(avatarRules.js isPublicAvatarFile — 기록이
    // 없는 파일은 예전처럼 누군가의 사진 아바타면 된다). 기록이 있으면 올린 사람 한 명만 찾아보면 되고, 올린 계정이 지워졌으면
    // (uploaderId null) 찾을 사람이 없다.
    const fileName = uploadFileNameOf(raw);
    const upload = fileName ? await findUpload(fileName) : null;
    let holderIds = [];
    if (!upload || upload.uploaderId != null) {
      const holders = await db
        .select({ id: users.id })
        .from(users)
        .where(
          and(
            eq(users.avatarUrl, raw),
            eq(users.avatarType, 'photo'),
            upload ? eq(users.id, upload.uploaderId) : undefined,
          ),
        )
        .limit(1);
      holderIds = holders.map((r) => r.id);
    }
    const avatar = isPublicAvatarFile({ holderIds, upload });
    const [sticker] = avatar
      ? []
      : await db.select({ id: stickers.id }).from(stickers).where(or(eq(stickers.fileUrl, raw), eq(stickers.thumbnailUrl, raw))).limit(1);
    if (avatar || sticker) return res.json({ url: signFileUrl(raw) });

    for (const row of rows) {
      if (await isRoomMember(row.roomId, userId)) {
        return res.json({ url: signFileUrl(raw, row.fileName ?? undefined) });
      }
    }
    res.status(404).json({ error: '파일을 찾을 수 없습니다.' });
  });

  return router;
}

/** [userId]의 1:1 "진짜 나가기" 시작선 행만 붙이는 LEFT JOIN 조건 — 그 방([roomIdColumn])의 이 사람 행. 다른 사람의 시작선은 안 본다. */
function myHistoryFloor(roomIdColumn, userId) {
  return and(eq(dmHistoryFloors.roomId, roomIdColumn), eq(dmHistoryFloors.userId, userId));
}

/** 시작선 이후의 글만([createdAtColumn]이 그 글이 보이는지를 정하는 시각) — 시작선이 없는 방(LEFT JOIN이라 null)은 그대로 통과한다. */
function notBeforeHistoryFloor(createdAtColumn) {
  return or(isNull(dmHistoryFloors.hiddenBeforeAt), gte(createdAtColumn, dmHistoryFloors.hiddenBeforeAt));
}
