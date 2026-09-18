import { and, eq, isNull, or, sql } from 'drizzle-orm';
import { db } from '../client.js';
import { dmHistoryFloors, roomMembers, rooms, teamMembers, users } from '../schema.js';

export function findRoomById(id) {
  return db
    .select()
    .from(rooms)
    .where(eq(rooms.id, id))
    .then((rows) => rows[0] ?? null);
}

/** DM은 팀 안에서만 유일하다(같은 두 사람이 팀마다 각각 1:1 대화를 가질 수 있다). */
export function findDmRoomByKey(teamId, dmKey) {
  return db
    .select()
    .from(rooms)
    .where(and(eq(rooms.teamId, teamId), eq(rooms.type, 'dm'), eq(rooms.dmKey, dmKey)))
    .then((rows) => rows[0] ?? null);
}

/** 비밀 대화 전용 — team_id와 무관하게 dmKey만으로 찾는다. 평문 DM과 달리 비밀 대화는 팀
 * 소속과 무관한 한 쌍의 개인 채널이라 한 쌍에 하나만 있어야 한다(team_id는 DB의 NOT NULL
 * 제약을 만족시키기 위한 부가 정보일 뿐, 이걸로 나뉘면 같은 두 사람이 보는 팀에 따라 서로
 * 다른 비밀 대화방을 갖게 되는 버그가 된다). */
export function findSecretRoomByDmKey(dmKey) {
  return db
    .select()
    .from(rooms)
    .where(and(eq(rooms.isSecret, true), eq(rooms.dmKey, dmKey)))
    .then((rows) => rows[0] ?? null);
}

/** 이 사람이 멤버인 방. [teamId]를 주면 그 팀의 방만, 안 주면 팀과 상관없이 전부 —
 * 팀을 안 주는 쪽은 소켓 join처럼 "내가 속한 모든 방"이 필요한 경우에 쓴다(다른 팀에서 온
 * 메시지도 받아야 하므로 소켓은 항상 전체 팀의 방에 join한다, socket.js 참고). */
export function listRoomsForUser(userId, teamId) {
  const conditions = [eq(roomMembers.userId, userId)];
  if (teamId) conditions.push(eq(rooms.teamId, teamId));
  return db
    .select({ room: rooms })
    .from(roomMembers)
    .innerJoin(rooms, eq(roomMembers.roomId, rooms.id))
    .where(and(...conditions))
    .then((rows) => rows.map((r) => r.room));
}

/** isPublic이 명시적으로 false가 아니면 공개로 친다(기존 `r.isPublic !== false`와 동일한 규칙). */
const isPublicTopic = or(isNull(rooms.isPublic), eq(rooms.isPublic, true));

/** 그 팀에 새로 들어온 사람을 자동으로 넣어줄 공개 토픽 전체(팀 단위). */
export function listPublicTopics(teamId) {
  return db
    .select()
    .from(rooms)
    .where(and(eq(rooms.teamId, teamId), eq(rooms.type, 'topic'), isPublicTopic));
}

/** 토픽 찾아보기: 그 팀의 공개 토픽 전부 + 비공개 토픽 중 내가 이미 멤버인 것. */
export function listBrowsableTopics(userId, teamId) {
  return db
    .select({ room: rooms, joined: sql`(${roomMembers.userId} is not null)`.as('joined') })
    .from(rooms)
    .leftJoin(roomMembers, and(eq(roomMembers.roomId, rooms.id), eq(roomMembers.userId, userId)))
    .where(
      and(
        eq(rooms.teamId, teamId),
        eq(rooms.type, 'topic'),
        or(isPublicTopic, sql`${roomMembers.userId} is not null`),
      ),
    );
}

export async function insertRoom(fields) {
  const [row] = await db.insert(rooms).values(fields).returning();
  return row;
}

/** 방을 완전히 지운다(멤버/메시지/비밀 대화 세션은 전부 onDelete:'cascade'로 함께 지워짐).
 * 비밀 대화를 거절했을 때처럼, 다시 대화를 걸 수 있도록 dmKey 자체를 비워줘야 하는 경우에 쓴다. */
export async function deleteRoom(id) {
  await db.delete(rooms).where(eq(rooms.id, id));
}

/** 비밀 대화에서 "상대방도 나가기" 없이 혼자 나갔을 때, 남은 멤버 쪽에 보여줄 이름을 남겨둔다
 * (rooms.js의 /rooms/:id/leave 참고). */
export async function setSecretDepartedMember(roomId, { userId, name }) {
  const [row] = await db
    .update(rooms)
    .set({ secretDepartedMemberId: userId, secretDepartedMemberName: name })
    .where(eq(rooms.id, roomId))
    .returning();
  return row;
}

/** DM "나가기"(진짜 나가기 — dm_history_floors 참고): 지금 시각을 이 사람의 기록 시작선으로
 * 남긴다(upsert — 이미 있으면 최신 시각으로 덮어씀). */
export async function setDmHistoryFloor(roomId, userId) {
  await db
    .insert(dmHistoryFloors)
    .values({ roomId, userId, hiddenBeforeAt: new Date() })
    .onConflictDoUpdate({
      target: [dmHistoryFloors.roomId, dmHistoryFloors.userId],
      set: { hiddenBeforeAt: new Date() },
    });
}

/** 이 사람이 이 방에서 "진짜 나가기"를 한 적이 있으면 그 시각을, 없으면(=한 번도 없거나
 * "숨기기"만 했으면) null을 돌려준다 — 메시지/파일/검색 조회에서 이 시각 이전 내용을 가린다. */
export async function getDmHistoryFloor(roomId, userId) {
  const [row] = await db
    .select({ hiddenBeforeAt: dmHistoryFloors.hiddenBeforeAt })
    .from(dmHistoryFloors)
    .where(and(eq(dmHistoryFloors.roomId, roomId), eq(dmHistoryFloors.userId, userId)));
  return row?.hiddenBeforeAt ?? null;
}

/** 여러 명을 한 번에 멤버로 추가한다(이미 멤버면 조용히 무시 — 초대/공개토픽 자동가입에서 중복 방지). */
export async function addRoomMembers(roomId, userIds) {
  if (userIds.length === 0) return;
  await db
    .insert(roomMembers)
    .values(userIds.map((userId) => ({ roomId, userId })))
    .onConflictDoNothing();
}

export async function removeRoomMember(roomId, userId) {
  await db.delete(roomMembers).where(and(eq(roomMembers.roomId, roomId), eq(roomMembers.userId, userId)));
}

export async function isRoomMember(roomId, userId) {
  const [row] = await db
    .select({ userId: roomMembers.userId })
    .from(roomMembers)
    .where(and(eq(roomMembers.roomId, roomId), eq(roomMembers.userId, userId)));
  return !!row;
}

/** 방 멤버 id만(소켓 join 등 사용자 정보가 필요 없는 곳에서 가볍게). */
export function listRoomMemberIds(roomId) {
  return db
    .select({ userId: roomMembers.userId })
    .from(roomMembers)
    .where(eq(roomMembers.roomId, roomId))
    .then((rows) => rows.map((r) => r.userId));
}

/** 방 멤버 목록을 실제 사용자 정보(publicUser로 감쌀 원본 행)로. 탈퇴한 사용자도 그대로
 * 포함한다 — users.withdraw가 이미 이름/아바타를 "탈퇴한 사용자"+기본 아바타로 익명화해두므로,
 * 여기서 빼면 클라이언트가 그 멤버를 못 찾아 "(알 수 없음)"으로 표시하고(room.dart
 * displayName), 메시지 말풍선도 라이브 멤버 조회 대신 메시지에 박제된(탈퇴 전) senderName/
 * 아바타로 되돌아가 버린다(message_bubble.dart의 sender?.name ?? message.senderName 우선순위
 * 참고) — 계속 포함시켜야 방 제목/아바타/메시지 발신자 표시가 전부 "탈퇴한 사용자"로 일관되게
 * 보인다. 새 대화 상대 선택 목록에서 빼는 것은 별도인 listActiveUsers가 담당한다. */
export function listRoomMemberUsers(roomId) {
  return db
    .select({ user: users })
    .from(roomMembers)
    .innerJoin(users, eq(roomMembers.userId, users.id))
    .where(eq(roomMembers.roomId, roomId))
    .then((rows) => rows.map((r) => r.user));
}

/** listRoomMemberUsers와 같지만, [teamId]의 team_members.department/position(teamDepartment/
 * teamPosition으로)도 같이 얹는다 — rooms.js의 resolveMembers가 서버 설정(orgScope)에 따라
 * 계정 값(users.department/position)과 이 팀 값 중 하나를 골라 방 DTO의 member.position에
 * 싣는다(teams.js의 memberListResponse와 같은 방식). LEFT JOIN인 이유는
 * listRoomMemberUsers와 동일 — 팀에서 나간 사람의 옛 대화도 계속 보여야 하므로 팀 멤버십이
 * 없어도(teamMembers 행이 없어도) 방 멤버 자체는 빠지면 안 된다. */
export function listRoomMemberUsersWithOrg(roomId, teamId) {
  return db
    .select({ user: users, teamDepartment: teamMembers.department, teamPosition: teamMembers.position })
    .from(roomMembers)
    .innerJoin(users, eq(roomMembers.userId, users.id))
    .leftJoin(teamMembers, and(eq(teamMembers.userId, roomMembers.userId), eq(teamMembers.teamId, teamId)))
    .where(eq(roomMembers.roomId, roomId))
    .then((rows) =>
      rows.map((r) => ({
        ...r.user,
        teamDepartment: r.teamDepartment ?? null,
        teamPosition: r.teamPosition ?? null,
      })),
    );
}

/** 방 멤버들의 마지막 읽은 시각 맵({userId: epochMillis}) — 클라이언트의 "안읽음 N" 계산용. */
export async function getRoomLastReadMap(roomId) {
  const rows = await db
    .select({ userId: roomMembers.userId, lastReadAt: roomMembers.lastReadAt })
    .from(roomMembers)
    .where(eq(roomMembers.roomId, roomId));
  const map = {};
  for (const r of rows) {
    map[r.userId] = r.lastReadAt ? new Date(r.lastReadAt).getTime() : 0;
  }
  return map;
}

export async function getMemberLastRead(roomId, userId) {
  const [row] = await db
    .select({ lastReadAt: roomMembers.lastReadAt })
    .from(roomMembers)
    .where(and(eq(roomMembers.roomId, roomId), eq(roomMembers.userId, userId)));
  return row?.lastReadAt ? new Date(row.lastReadAt).getTime() : 0;
}

export async function setMemberLastRead(roomId, userId, whenMs) {
  await db
    .update(roomMembers)
    .set({ lastReadAt: new Date(whenMs) })
    .where(and(eq(roomMembers.roomId, roomId), eq(roomMembers.userId, userId)));
}

/** 알림 센터의 "안 읽은 공지" 판정용 — getMemberLastRead와 같은 모양이지만 별도 컬럼(schema.js
 * 참고). 공지 목록/상세를 실제로 연 시각만 여기 찍힌다. */
export async function getMemberLastReadAnnouncementAt(roomId, userId) {
  const [row] = await db
    .select({ lastReadAnnouncementAt: roomMembers.lastReadAnnouncementAt })
    .from(roomMembers)
    .where(and(eq(roomMembers.roomId, roomId), eq(roomMembers.userId, userId)));
  return row?.lastReadAnnouncementAt ? new Date(row.lastReadAnnouncementAt).getTime() : 0;
}

export async function setMemberLastReadAnnouncementAt(roomId, userId, whenMs) {
  await db
    .update(roomMembers)
    .set({ lastReadAnnouncementAt: new Date(whenMs) })
    .where(and(eq(roomMembers.roomId, roomId), eq(roomMembers.userId, userId)));
}

export async function getMemberFavorite(roomId, userId) {
  const [row] = await db
    .select({ favorite: roomMembers.favorite })
    .from(roomMembers)
    .where(and(eq(roomMembers.roomId, roomId), eq(roomMembers.userId, userId)));
  return row?.favorite ?? false;
}

export async function setMemberFavorite(roomId, userId, favorite) {
  await db
    .update(roomMembers)
    .set({ favorite })
    .where(and(eq(roomMembers.roomId, roomId), eq(roomMembers.userId, userId)));
}

export async function getMemberMuted(roomId, userId) {
  const [row] = await db
    .select({ muted: roomMembers.muted })
    .from(roomMembers)
    .where(and(eq(roomMembers.roomId, roomId), eq(roomMembers.userId, userId)));
  return row?.muted ?? false;
}

export async function setMemberMuted(roomId, userId, muted) {
  await db
    .update(roomMembers)
    .set({ muted })
    .where(and(eq(roomMembers.roomId, roomId), eq(roomMembers.userId, userId)));
}

/** 평문 DM "숨기기"/"나가기" — 즐겨찾기/뮤트와 동일한 개인 설정 방식(schema.js 참고). */
export async function getMemberHidden(roomId, userId) {
  const [row] = await db
    .select({ hidden: roomMembers.hidden })
    .from(roomMembers)
    .where(and(eq(roomMembers.roomId, roomId), eq(roomMembers.userId, userId)));
  return row?.hidden ?? false;
}

export async function setMemberHidden(roomId, userId, hidden) {
  await db
    .update(roomMembers)
    .set({ hidden })
    .where(and(eq(roomMembers.roomId, roomId), eq(roomMembers.userId, userId)));
}

/** push.js가 FCM 발송 대상에서 이 방을 뮤트한 멤버를 걸러내는 데 쓴다. */
export async function listMutedUserIdsForRoom(roomId) {
  const rows = await db
    .select({ userId: roomMembers.userId })
    .from(roomMembers)
    .where(and(eq(roomMembers.roomId, roomId), eq(roomMembers.muted, true)));
  return rows.map((r) => r.userId);
}
