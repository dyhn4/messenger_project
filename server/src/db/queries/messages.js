import { and, asc, desc, eq, gt, gte, inArray, isNotNull, isNull, lt, lte, ne, or, sql } from 'drizzle-orm';
import { db } from '../client.js';
import {
  dmHistoryFloors,
  favoriteFiles,
  messageAttachments,
  notifications,
  roomMembers,
  rooms,
  messages,
} from '../schema.js';
import { fileKindSql } from '../../fileKinds.js';

export async function insertMessage(fields) {
  const [row] = await db.insert(messages).values(fields).returning();
  return row;
}

/** 한 메시지에 딸린 첨부들을 한꺼번에 넣는다(사진 여러 장을 한 말풍선으로 보낼 때). */
export async function insertMessageAttachments(messageId, items) {
  if (items.length === 0) return [];
  return db
    .insert(messageAttachments)
    .values(items.map((a, i) => ({ ...a, messageId, position: i })))
    .returning();
}

/** 메시지 id별 첨부 목록 {messageId: [...]} — 목록 조회가 한 번에 붙여 내려준다. */
export async function listAttachmentsForMessages(messageIds) {
  if (messageIds.length === 0) return {};
  const rows = await db
    .select()
    .from(messageAttachments)
    .where(inArray(messageAttachments.messageId, messageIds))
    .orderBy(asc(messageAttachments.position));
  const map = {};
  for (const r of rows) (map[r.messageId] ??= []).push(r);
  return map;
}

export function findMessageById(id) {
  return db
    .select()
    .from(messages)
    .where(eq(messages.id, id))
    .then((rows) => rows[0] ?? null);
}

/** 방 목록 정렬용 "최근 활동" 계산에 쓴다(rooms.js의 toRoomDto 참고) — 이 방의 가장 최근
 * 메시지 시각. 메시지가 하나도 없으면 null(그러면 room.createdAt으로 대체됨). */
export async function getLastMessageAt(roomId) {
  const [row] = await db
    .select({ createdAt: messages.createdAt })
    .from(messages)
    .where(eq(messages.roomId, roomId))
    .orderBy(desc(messages.createdAt))
    .limit(1);
  return row?.createdAt ?? null;
}

/** 방 목록 미리보기(이름 아래 줄)용 — 가장 최근의 지워지지 않은 메시지 한 건. 소프트 삭제된
 * 메시지는 건너뛰고 그 이전 걸 찾는다(rooms.js의 toRoomDto, push.js의 previewFor 참고). */
export async function getLastMessageForPreview(roomId) {
  const [row] = await db
    .select({
      type: messages.type,
      title: messages.title, // 게시글 미리보기("게시글: 제목")용
      text: messages.text,
      fileName: messages.fileName,
      senderName: messages.senderName, // 알림 센터 "메시지" 탭의 "보낸 사람: 미리보기"용
      createdAt: messages.createdAt,
    })
    .from(messages)
    .where(and(eq(messages.roomId, roomId), isNull(messages.deletedAt)))
    .orderBy(desc(messages.createdAt))
    .limit(1);
  return row ?? null;
}

export async function updateMessageText(id, text, textFormat = null, mentions = null) {
  const [row] = await db
    .update(messages)
    .set({ text, textFormat, mentions, editedAt: new Date() })
    .where(eq(messages.id, id))
    .returning();
  return row;
}

/** 링크 미리보기 결과를 채운다 — updateMessageText와 달리 editedAt을 안 건드린다(사용자가
 * 고친 게 아니라 서버가 나중에 긁어온 값이라 "(수정됨)" 표시가 붙으면 안 된다). */
export async function updateMessageLinkPreview(id, preview) {
  const [row] = await db
    .update(messages)
    .set({
      linkPreviewUrl: preview.url,
      linkPreviewTitle: preview.title,
      linkPreviewDescription: preview.description,
      linkPreviewImageUrl: preview.imageUrl,
      linkPreviewSiteName: preview.siteName,
    })
    .where(eq(messages.id, id))
    .returning();
  return row;
}

/** 소프트 삭제 — 행은 남기고(댓글 스레드가 계속 참조) 내용만 비운다. 게시글이면 제목과 고정도 푼다. */
export async function softDeleteMessage(id) {
  const [row] = await db
    .update(messages)
    .set({
      deletedAt: new Date(),
      text: null,
      textFormat: null,
      mentions: null,
      fileUrl: null,
      fileName: null,
      fileSize: null,
      mimeType: null,
      title: null,
      pinnedAt: null,
    })
    .where(eq(messages.id, id))
    .returning();
  return row;
}

/** 게시글 수정(messages.js) — 제목·본문·서식을 한 번에 바꾸고 "(수정됨)" 시각을 찍는다. */
export async function updatePost(id, { title, text, textFormat = null, mentions = null }) {
  const [row] = await db
    .update(messages)
    .set({ title, text, textFormat, mentions, editedAt: new Date() })
    .where(eq(messages.id, id))
    .returning();
  return row;
}

/** 게시글 고정/해제 — 내용을 고친 게 아니라서 editedAt은 안 건드린다("(수정됨)"이 붙으면 안 됨). */
export async function setMessagePinned(id, pinned) {
  const [row] = await db
    .update(messages)
    .set({ pinnedAt: pinned ? new Date() : null })
    .where(eq(messages.id, id))
    .returning();
  return row;
}

/** 보드 뷰 상단 "고정된 게시글" — 지워지지 않은 고정 게시글을 작성 시각 최신순으로. */
export function listPinnedPosts(roomId) {
  return db
    .select()
    .from(messages)
    .where(
      and(
        eq(messages.roomId, roomId),
        eq(messages.type, 'post'),
        isNotNull(messages.pinnedAt),
        isNull(messages.deletedAt),
      ),
    )
    .orderBy(desc(messages.createdAt));
}


/**
 * "대화 내보내기"(rooms.js의 GET /rooms/:id/export)용 — 방의 메시지를 시간순으로 전부
 * 훑는다. 한 번에 메모리에 다 올리지 않도록 BATCH개씩 끊어서 async generator로 돌려주고,
 * 호출부가 각 배치를 곧바로 엑셀 스트림에 흘려보낸다. [since]/[until]로 기간을 좁힐 수
 * 있고, [floor]는 listMessagesByRoom과 같은 DM "진짜 나가기" 이력 컷오프다.
 */
export async function* iterateMessagesForExport({ roomId, since, until, floor }) {
  const BATCH = 2000;
  let cursor = null;
  while (true) {
    const conditions = [eq(messages.roomId, roomId)];
    if (cursor) conditions.push(gt(messages.createdAt, cursor));
    else if (since) conditions.push(gte(messages.createdAt, since));
    if (until) conditions.push(lte(messages.createdAt, until));
    if (floor) conditions.push(gte(messages.createdAt, floor));
    const rows = await db
      .select()
      .from(messages)
      .where(and(...conditions))
      .orderBy(asc(messages.createdAt))
      .limit(BATCH);
    if (rows.length === 0) return;
    yield rows;
    if (rows.length < BATCH) return;
    cursor = rows[rows.length - 1].createdAt;
  }
}

/** id 목록으로 메시지를 시간순(오래된 것부터) 가져온다 — 창 밖에 있는 댓글의 부모 메시지를
 * 따로 끌어올 때 쓴다(comments.js의 listCommentsInRoomBetween 참고). */
export function listMessagesByIds(ids) {
  if (ids.length === 0) return Promise.resolve([]);
  return db
    .select()
    .from(messages)
    .where(inArray(messages.id, ids))
    .orderBy(asc(messages.createdAt));
}

/** 방의 메시지 limit개를 시간순(오래된 것부터)으로. beforeCreatedAt을 주면 그 시각보다
 * 먼저 온 메시지 중 최근 limit개를 돌려준다(과거 방향 페이지네이션 — "위로 스크롤해서
 * 더 불러오기"/검색으로 아주 오래된 메시지를 찾을 때 씀). 없으면 지금까지처럼 방에서
 * 가장 최근 limit개. [floor]를 주면(DM "진짜 나가기" 이력, rooms.js의 getDmHistoryFloor
 * 참고) 그 시각 이전 메시지는 이 요청자에게 아예 없는 것처럼 뺀다. */
export async function listMessagesByRoom(roomId, limit, beforeCreatedAt, floor) {
  const conditions = [eq(messages.roomId, roomId)];
  if (beforeCreatedAt) conditions.push(lt(messages.createdAt, beforeCreatedAt));
  if (floor) conditions.push(gte(messages.createdAt, floor));
  const rows = await db
    .select()
    .from(messages)
    .where(and(...conditions))
    .orderBy(desc(messages.createdAt))
    .limit(limit);
  return rows.reverse();
}

/** toRoomDto의 unreadCount: 이 방에서 나(requesterId)를 뺀 사람이 보낸, 시스템 메시지가 아닌,
 * 내가 마지막으로 읽은 시각(sinceMs) 이후의 메시지 수. [floor]를 주면(DM "진짜 나가기" 이력)
 * 그 시각 이전 메시지는 안읽음 개수에도 안 세운다 — 어차피 목록에 안 보이는 메시지다. */
export async function countUnreadForUser(roomId, requesterId, sinceMs, floor) {
  const conditions = [
    eq(messages.roomId, roomId),
    // SQL에서 NULL <> x는 참이 아니라 NULL이라, 보낸 사람이 없는 글(자동화 메시지, 탈퇴한 사람의
    // 글)도 "남이 보낸 글"로 세려면 null을 따로 넣어야 한다.
    or(isNull(messages.senderId), ne(messages.senderId, requesterId)),
    ne(messages.type, 'system'),
    gt(messages.createdAt, new Date(sinceMs)),
  ];
  if (floor) conditions.push(gte(messages.createdAt, floor));
  const [row] = await db
    .select({ count: sql`count(*)`.mapWith(Number) })
    .from(messages)
    .where(and(...conditions));
  return row?.count ?? 0;
}

/** 이 방에 사람이 아닌 발신자([senderName])가 같은 글([text])을 이미 올렸는지 — 나와의 대화 환영 안내를
 * 팀마다 한 번만 보내는 데 쓴다(selfRoomNotices.js). [executor]는 방 잠금 안에서 부를 때의 트랜잭션. */
export async function hasBotMessage(roomId, senderName, text, executor = db) {
  const [row] = await executor
    .select({ id: messages.id })
    .from(messages)
    .where(
      and(
        eq(messages.roomId, roomId),
        isNull(messages.senderId),
        eq(messages.senderName, senderName),
        eq(messages.text, text),
      ),
    )
    .limit(1);
  return !!row;
}

/** 보존기간 만료 파기(retention.js) — 그 사람이 보낸 메시지를 전부 지우고 지운 개수를 돌려준다. */
export async function deleteMessagesBySender(userId) {
  const deleted = await db.delete(messages).where(eq(messages.senderId, userId)).returning({ id: messages.id });
  return deleted.length;
}

/** 회원 탈퇴 시 과거 메시지의 작성자 표시도 다시 쓴다. */
export async function renameSenderMessages(userId, newName) {
  await db.update(messages).set({ senderName: newName }).where(eq(messages.senderId, userId));
  // 알림 기록에 박제된 행위자 이름(멘션한 사람 등)도 같이 — 탈퇴 전 이름이 알림 센터에 남지 않게.
  await db.update(notifications).set({ actorName: newName }).where(eq(notifications.actorId, userId));
}

// searchMessages/listAttachments가 공유하는 조건 — DM "진짜 나가기" 이력이 있으면(dm_history_floors)
// 그 시각 이전 메시지는 검색/파일 목록에서도 이 요청자에게 안 보이게 뺀다. LEFT JOIN이라
// 이력이 없는(=한 번도 진짜 나가기를 안 했거나 다른 방인) 경우 floor 쪽 컬럼은 전부 null이고,
// 그때는 조건 자체가 무조건 참이 되어(뒤 or) 기존과 동일하게 전부 통과한다.
const notBeforeDmHistoryFloor = or(isNull(dmHistoryFloors.hiddenBeforeAt), gte(messages.createdAt, dmHistoryFloors.hiddenBeforeAt));

/**
 * 통합 검색. requesterId가 속한 방으로만 좁히는 건 room_members와의 join으로 강제한다(클라이언트가
 * roomId를 임의로 보내도 내 방이 아니면 절대 안 걸림 — 예전 myRoomIds.has(...) 필터와 동일한 보장).
 */
export async function searchMessages({
  requesterId,
  teamId,
  roomId,
  senderId,
  since,
  until,
  q,
  limit,
  type = 'all', // 'all' | 'message' | 'poll' | 'file' — 검색 패널의 탭.
  fileKind = null, // type이 'file'일 때 파일 형식(fileKinds.js) — null이면 전체 파일.
  order = 'desc', // 'desc'(최신 순) | 'asc'(과거 순)
  withTotal = false, // true면 limit와 상관없는 전체 건수도 같이 센다({ rows, total }로 돌려준다).
}) {
  // 검색어의 %·_·\는 LIKE 와일드카드가 아니라 글자 그대로 찾는다 — 안 그러면 "_" 하나로 모든 글이
  // 걸린다(Postgres LIKE의 기본 이스케이프 문자가 \라 ESCAPE 절 없이 앞에 \만 붙이면 된다).
  const pattern = `%${q.replace(/[\\%_]/g, '\\$&')}%`;
  const conditions = [
    eq(roomMembers.userId, requesterId),
    or(
      sql`lower(${messages.text}) like ${pattern}`,
      sql`lower(${messages.fileName}) like ${pattern}`,
      // 보드 뷰 게시글은 제목으로도 찾는다(다른 메시지는 title이 null이라 영향 없음).
      sql`lower(${messages.title}) like ${pattern}`,
    ),
    notBeforeDmHistoryFloor,
  ];
  if (teamId) conditions.push(eq(rooms.teamId, teamId));
  if (roomId) conditions.push(eq(messages.roomId, roomId));
  if (senderId) conditions.push(eq(messages.senderId, senderId));
  if (since) conditions.push(gte(messages.createdAt, new Date(since)));
  if (until) conditions.push(lte(messages.createdAt, new Date(until)));
  if (type === 'poll') conditions.push(eq(messages.type, 'poll'));
  else if (type === 'message') conditions.push(inArray(messages.type, ['text', 'post']));
  else if (type === 'file') {
    conditions.push(inArray(messages.type, ['image', 'file']));
    if (fileKind) conditions.push(fileKindSql(fileKind, messages.mimeType, messages.fileName));
  }

  const where = and(eq(rooms.isSecret, false), ...conditions);
  const joined = (selection) =>
    db
      .select(selection)
      .from(messages)
      .innerJoin(roomMembers, eq(roomMembers.roomId, messages.roomId))
      .innerJoin(rooms, eq(rooms.id, messages.roomId))
      .leftJoin(
        dmHistoryFloors,
        and(eq(dmHistoryFloors.roomId, messages.roomId), eq(dmHistoryFloors.userId, requesterId)),
      )
      .where(where);

  const rows = (
    await joined({ message: messages })
      .orderBy(order === 'asc' ? asc(messages.createdAt) : desc(messages.createdAt))
      .limit(limit)
  ).map((r) => r.message);
  if (!withTotal) return rows;
  const [{ total }] = await joined({ total: sql`count(*)::int` });
  return { rows, total };
}

/**
 * 방에 첨부된 이미지/파일 목록(files.js). searchMessages와 동일하게 requesterId가 속한
 * 방(비밀 대화 제외)으로만 좁힌다. roomId/senderId는 둘 다 선택적 — 없으면 내가 속한 모든
 * 방을 가로지른다. 파일 형식(이미지/PDF/문서 등) 세분화는 mimeType 문자열 매칭이 SQL보다
 * JS가 다루기 쉬워서 여기서는 안 하고 호출부(files.js)에서 이 결과를 받은 뒤에 거른다.
 */
export async function listAttachments({
  requesterId,
  teamId,
  roomId,
  senderId,
  limit,
  since = null,
  until = null,
  q = '', // 파일 이름 검색(소문자로 들어온다) — 여러 첨부 중 하나라도 이름이 맞으면 그 메시지가 남는다.
  order = 'desc',
}) {
  const conditions = [
    eq(roomMembers.userId, requesterId),
    // 보드 뷰 게시글과 첨부를 붙인 투표의 첨부도 파일 모아보기에 나온다(첨부 없는 글은 fileUrl이
    // 비어 빠진다 — 호출부 attachments.js가 첨부 한 줄씩 펼친다).
    inArray(messages.type, ['image', 'file', 'post', 'poll']),
    isNotNull(messages.fileUrl),
    isNull(messages.deletedAt),
    notBeforeDmHistoryFloor,
  ];
  if (teamId) conditions.push(eq(rooms.teamId, teamId));
  if (roomId) conditions.push(eq(messages.roomId, roomId));
  if (senderId) conditions.push(eq(messages.senderId, senderId));
  if (since) conditions.push(gte(messages.createdAt, new Date(since)));
  if (until) conditions.push(lte(messages.createdAt, new Date(until)));
  if (q) {
    const pattern = `%${q.replace(/[\\%_]/g, '\\$&')}%`;
    conditions.push(
      or(
        sql`lower(${messages.fileName}) like ${pattern}`,
        sql`exists (select 1 from ${messageAttachments} where ${messageAttachments.messageId} = ${messages.id} and lower(${messageAttachments.fileName}) like ${pattern})`,
      ),
    );
  }

  const rows = await db
    .select({ message: messages })
    .from(messages)
    .innerJoin(roomMembers, eq(roomMembers.roomId, messages.roomId))
    .innerJoin(rooms, eq(rooms.id, messages.roomId))
    .leftJoin(
      dmHistoryFloors,
      and(eq(dmHistoryFloors.roomId, messages.roomId), eq(dmHistoryFloors.userId, requesterId)),
    )
    .where(and(eq(rooms.isSecret, false), ...conditions))
    .orderBy(order === 'asc' ? asc(messages.createdAt) : desc(messages.createdAt))
    .limit(limit);
  return rows.map((r) => r.message);
}

/**
 * "링크" 모아보기 — 내가 속한 방(비밀 대화 제외)에서 본문이나 글자 서식(링크 걸린 글자)에 http(s)
 * 주소가 들어 있는 메시지. listAttachments와 같은 범위(팀·방·보낸 사람·DM 기록 하한)로 좁히고,
 * 실제 주소를 뽑아 한 줄씩 펼치는 건 호출부(links.js)가 한다.
 */
export async function listLinkMessages({
  requesterId,
  teamId,
  roomId,
  senderId,
  limit,
  since = null,
  until = null,
  q = '', // 링크 검색(소문자) — 본문·글자 서식·링크 미리보기 제목/사이트 이름에서 찾는다.
  order = 'desc',
}) {
  const conditions = [
    eq(roomMembers.userId, requesterId),
    isNull(messages.deletedAt),
    notBeforeDmHistoryFloor,
    or(
      sql`${messages.text} ilike '%http%'`,
      sql`${messages.textFormat}::text ilike '%http%'`,
    ),
  ];
  if (teamId) conditions.push(eq(rooms.teamId, teamId));
  if (roomId) conditions.push(eq(messages.roomId, roomId));
  if (senderId) conditions.push(eq(messages.senderId, senderId));
  if (since) conditions.push(gte(messages.createdAt, new Date(since)));
  if (until) conditions.push(lte(messages.createdAt, new Date(until)));
  if (q) {
    const pattern = `%${q.replace(/[\\%_]/g, '\\$&')}%`;
    conditions.push(
      or(
        sql`lower(${messages.text}) like ${pattern}`,
        sql`lower(${messages.textFormat}::text) like ${pattern}`,
        sql`lower(${messages.linkPreviewTitle}) like ${pattern}`,
        sql`lower(${messages.linkPreviewSiteName}) like ${pattern}`,
      ),
    );
  }

  const rows = await db
    .select({ message: messages })
    .from(messages)
    .innerJoin(roomMembers, eq(roomMembers.roomId, messages.roomId))
    .innerJoin(rooms, eq(rooms.id, messages.roomId))
    .leftJoin(
      dmHistoryFloors,
      and(eq(dmHistoryFloors.roomId, messages.roomId), eq(dmHistoryFloors.userId, requesterId)),
    )
    .where(and(eq(rooms.isSecret, false), ...conditions))
    .orderBy(order === 'asc' ? asc(messages.createdAt) : desc(messages.createdAt))
    .limit(limit);
  return rows.map((r) => r.message);
}

/** 비밀 대화 자동 삭제(secretExpiry.js): 상대방이 읽어서 expiresAt이 잡힌 뒤 그 시각이
 * 지난 메시지. 최초 1회만 읽음 처리되도록 readAt이 아직 없을 때만 세팅한다. */
export async function markMessageRead(id, expiresAt) {
  const [row] = await db
    .update(messages)
    .set({ readAt: new Date(), expiresAt: expiresAt ? new Date(expiresAt) : null })
    .where(and(eq(messages.id, id), sql`${messages.readAt} is null`))
    .returning();
  return row ?? null;
}

export function findExpiredSecretMessages() {
  return db
    .select()
    .from(messages)
    .where(and(isNotNull(messages.expiresAt), lte(messages.expiresAt, new Date())));
}

/** 행 자체를 완전히 없앤다(댓글도 FK cascade로 함께 삭제됨 — 부모 없는 댓글 스레드가 남는
 * 것보다 자연스러운 선택). 비밀 대화 자동 삭제 타이머 만료 때뿐 아니라, messages.js의
 * DELETE /messages/:id에서 아직 아무도 안 읽은 메시지를 지울 때도 쓴다(그때는 "삭제된
 * 메시지입니다" 흔적도 남기지 않아야 하므로 softDeleteMessage 대신 이걸 쓴다). */
export async function hardDeleteMessage(id) {
  const [row] = await db.delete(messages).where(eq(messages.id, id)).returning();
  return row ?? null;
}

// ── 즐겨찾기한 파일 ──────────────────────────────────────────────────────

/** 이미 있으면 빼고 없으면 넣는다(토글) — 넣었으면 true. */
export async function toggleFavoriteFile({ userId, messageId, fileUrl, fileName }) {
  const existing = await db
    .select()
    .from(favoriteFiles)
    .where(
      and(
        eq(favoriteFiles.userId, userId),
        eq(favoriteFiles.messageId, messageId),
        eq(favoriteFiles.fileUrl, fileUrl),
      ),
    );
  if (existing.length > 0) {
    await db.delete(favoriteFiles).where(eq(favoriteFiles.id, existing[0].id));
    return false;
  }
  await db.insert(favoriteFiles).values({ userId, messageId, fileUrl, fileName });
  return true;
}

export function listFavoriteFiles(userId) {
  return db
    .select()
    .from(favoriteFiles)
    .where(eq(favoriteFiles.userId, userId))
    .orderBy(desc(favoriteFiles.createdAt));
}

/** 이 사람이 즐겨찾기한 파일 경로 집합 — 메시지 목록에 별 표시를 붙일 때 쓴다. */
export async function favoriteFileUrls(userId, messageIds) {
  if (messageIds.length === 0) return new Set();
  const rows = await db
    .select({ fileUrl: favoriteFiles.fileUrl })
    .from(favoriteFiles)
    .where(and(eq(favoriteFiles.userId, userId), inArray(favoriteFiles.messageId, messageIds)));
  return new Set(rows.map((r) => r.fileUrl));
}
