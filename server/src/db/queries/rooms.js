import { randomUUID } from 'node:crypto';
import { and, asc, eq, inArray, isNull, notExists, or, sql } from 'drizzle-orm';
import { db } from '../client.js';
import { dmHistoryFloors, roomMembers, rooms, teamMembers, topicFolderItems, topicFolders, users } from '../schema.js';
import { resyncTodoProgressForMembers } from './todos.js';

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

/** 그 팀에 새로 들어온(또는 준회원에서 올라온) 정회원 이상을 자동으로 넣어줄 토픽 — '정회원 자동
 * 초대'가 켜진 공개 토픽 중 보관되지 않은 것. 예전엔 공개 토픽 전부였지만, 이제 공개 토픽은 "찾아서
 * 참여하는" 곳이고 자동 참여는 토픽마다 켠 곳에만 한다(기존 공개 토픽은 마이그레이션에서 켜 둠). */
export function listAutoInviteTopics(teamId) {
  return db
    .select()
    .from(rooms)
    .where(
      and(
        eq(rooms.teamId, teamId),
        eq(rooms.type, 'topic'),
        isPublicTopic,
        eq(rooms.autoInvite, true),
        isNull(rooms.archivedAt),
      ),
    );
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

/**
 * 토픽 찾아보기 목록에 붙일 방별 요약 — 멤버 수와 토픽 관리자 이름들({roomId: {memberCount,
 * adminNames}}). 방마다 따로 조회하지 않도록 목록 전체를 쿼리 두 번으로 끝낸다.
 */
export async function listTopicSummaries(roomIds) {
  if (roomIds.length === 0) return {};
  const [counts, admins] = await Promise.all([
    db
      .select({ roomId: roomMembers.roomId, n: sql`count(*)::int` })
      .from(roomMembers)
      .where(inArray(roomMembers.roomId, roomIds))
      .groupBy(roomMembers.roomId),
    db
      .select({ roomId: roomMembers.roomId, name: users.name, username: users.username })
      .from(roomMembers)
      .innerJoin(users, eq(users.id, roomMembers.userId))
      .where(and(inArray(roomMembers.roomId, roomIds), eq(roomMembers.role, 'admin')))
      .orderBy(asc(users.name)),
  ]);
  const map = Object.fromEntries(roomIds.map((id) => [id, { memberCount: 0, adminNames: [] }]));
  for (const c of counts) map[c.roomId].memberCount = Number(c.n);
  for (const a of admins) map[a.roomId].adminNames.push(a.name ?? a.username);
  return map;
}

export async function insertRoom(fields) {
  const [row] = await db.insert(rooms).values(fields).returning();
  return row;
}

/**
 * 나와의 대화 — 그 팀에서 이 사람의 것을 찾고, 없으면 만든다. 여러 요청이 동시에 불러도 (team_id, dm_key)
 * 유일 인덱스에 ON CONFLICT로 기대서 하나만 생긴다. 멤버 행도 없으면 넣는다(이미 있으면 그대로).
 * 이번에 새로 만들었거나 멤버로 다시 넣었으면 joined가 true — 호출부가 그 사람의 소켓을 방에 넣는다.
 */
export async function ensureSelfRoom(userId, teamId) {
  const dmKey = `${userId}:${userId}`;
  let room = await findDmRoomByKey(teamId, dmKey);
  let inserted = null;
  if (!room) {
    [inserted] = await db
      .insert(rooms)
      .values({ id: randomUUID(), teamId, type: 'dm', name: null, dmKey, createdBy: userId, isSelf: true })
      .onConflictDoNothing({ target: [rooms.teamId, rooms.dmKey] })
      .returning();
    room = inserted ?? (await findDmRoomByKey(teamId, dmKey));
  }
  // 같은 키를 쓰는 옛 DM이 있었다면(자기 자신과의 DM) 그게 곧 나와의 대화다 — 표시만 맞춘다.
  if (room && !room.isSelf) room = await updateRoom(room.id, { isSelf: true });
  // 팀에서 빠지면 나와의 대화에서도 빠지므로(removeMemberFromTeamRooms) 다시 들어온 사람은 멤버 행부터 되살린다 —
  // 예전 메모는 그대로 돌아오고, 새로 만든 방처럼 joined로 알려야 그 사람의 소켓이 방에 다시 들어간다.
  const joined = !!inserted || !(await isRoomMember(room.id, userId));
  if (joined) await addRoomMembers(room.id, [userId]);
  return { room, joined };
}

/** 토픽 정보·설정 변경/보관(rooms.js) — 넘긴 필드만 바꾸고 바뀐 행을 돌려준다. */
export async function updateRoom(id, fields) {
  const [row] = await db.update(rooms).set(fields).where(eq(rooms.id, id)).returning();
  return row ?? null;
}

/**
 * 그룹채팅 → 토픽 전환(rooms.js POST /rooms/:id/convert-to-topic) — 방 행을 잠근 트랜잭션 안에서 한 번에:
 * 아직 그룹일 때만 type을 'topic'으로 바꾸고(이름·설명·비공개, 그룹 전용 아이콘 칸 비움, 챗 뷰·기본 설정),
 * 전환한 사람을 토픽 관리자로 올리고, 토픽에선 쓰지 않는 나만의 별칭(custom_name)을 모두 지운다.
 * 메시지·멤버·읽음 기록은 그대로다. 이미 다른 요청이 전환했거나 그룹이 아니면 null.
 */
export function convertGroupToTopic(roomId, actorId, { name, description }) {
  return withRoomLock(roomId, async (tx) => {
    const [current] = await tx.select().from(rooms).where(eq(rooms.id, roomId));
    if (!current || current.type !== 'group' || current.isSecret || current.isSelf) return null;
    const [updated] = await tx
      .update(rooms)
      .set({
        type: 'topic',
        name,
        description,
        isPublic: false,
        viewMode: 'chat',
        readOnly: false,
        autoInvite: false,
        quietLeave: false,
        archivedAt: null,
        iconType: null,
        iconEmoji: null,
        iconColor: null,
        iconUrl: null,
      })
      .where(eq(rooms.id, roomId))
      .returning();
    await tx
      .update(roomMembers)
      .set({ role: 'admin' })
      .where(and(eq(roomMembers.roomId, roomId), eq(roomMembers.userId, actorId)));
    await tx.update(roomMembers).set({ customName: null }).where(eq(roomMembers.roomId, roomId));
    return updated;
  });
}

/** 방을 완전히 지운다(멤버/메시지/비밀 대화 세션은 전부 onDelete:'cascade'로 함께 지워짐).
 * 비밀 대화를 거절했을 때처럼, 다시 대화를 걸 수 있도록 dmKey 자체를 비워줘야 하는 경우에 쓴다.
 * [executor]는 트랜잭션 안에서 부를 때(removeMemberFromRoom). */
export async function deleteRoom(id, executor = db) {
  await executor.delete(rooms).where(eq(rooms.id, id));
}

/** 1:1 대화(비밀 대화 혼자 나가기·팀에서 제외)에서 빠진 사람을 남은 멤버 쪽에 보여줄 이름으로 남겨둔다
 * (removeMemberFromRoom 참고). userId·name을 null로 주면 지운다(그 사람이 다시 들어왔을 때). 컬럼 이름은
 * 비밀 대화에만 쓰던 시절 그대로다. [executor]는 트랜잭션 안에서 부를 때. */
export async function setSecretDepartedMember(roomId, { userId, name }, executor = db) {
  const [row] = await executor
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

/** 여러 명을 한 번에 멤버로 추가한다(이미 멤버면 조용히 무시 — 초대/공개토픽 자동가입에서 중복 방지).
 * [role]은 토픽을 만든 사람을 토픽 관리자('admin')로 넣을 때만 쓴다. 새로 들어온 사람에게 이 방 할 일의 담당 행이
 * 남아 있으면(나갔다가 다시 들어옴) 같은 트랜잭션에서 그 할 일들의 전체 진척률을 다시 맞추고, 실제로 바뀐 할 일 행을
 * 돌려준다(호출부가 rooms.js notifyTodosResynced로 알린다 — 새로 만든 방이면 늘 빈 목록). */
export async function addRoomMembers(roomId, userIds, role = 'member') {
  if (userIds.length === 0) return [];
  return db.transaction(async (tx) => {
    const inserted = await tx
      .insert(roomMembers)
      .values(userIds.map((userId) => ({ roomId, userId, role })))
      .onConflictDoNothing()
      .returning({ userId: roomMembers.userId });
    return resyncTodoProgressForMembers(tx, roomId, inserted.map((r) => r.userId));
  });
}

/** 여러 명을 한 번에 멤버에서 뺀다(나가기·토픽 "내보내기"·팀에서 제외) — 그 사람들의 토픽 폴더 배치(topic_folder_items)도
 * 같이 지운다(나갔다가 다시 들어오면 폴더 밖 목록에서 시작). [tx]를 주면 (withRoomLock 안) 그 트랜잭션에서 지운다. 실제로
 * 빠진 사람이 담당자인 이 방 할 일들의 전체 진척률도 같은 트랜잭션에서 다시 맞춘다(방을 나간 담당자는 집계에서 빠진다 —
 * 담당 행은 남겨 두어 다시 들어오면 그대로 이어지고, 담당자가 하나도 남지 않게 된 할 일은 S3 규칙의 값을 이어받는다).
 * 돌려주는 값은 `{ folderItemRemoved, changedTodos, removedUserIds }` — folderItemRemoved는 폴더 배치가 실제로 지워졌는지
 * (호출부가 그 사람의 다른 기기에 폴더 목록을 다시 불러오라고 알릴지 정한다), changedTodos는 전체 진척률이 실제로 바뀐 할 일
 * 행(호출부가 rooms.js notifyTodosResynced로 알린다), removedUserIds는 이번에 실제로 빠진 사람(그새 스스로 나간 사람은 없다). */
export async function removeRoomMembers(roomId, userIds, tx) {
  if (userIds.length === 0) return { folderItemRemoved: false, changedTodos: [], removedUserIds: [] };
  const run = async (t) => {
    const left = await t
      .delete(roomMembers)
      .where(and(eq(roomMembers.roomId, roomId), inArray(roomMembers.userId, userIds)))
      .returning({ userId: roomMembers.userId });
    const removed = await t
      .delete(topicFolderItems)
      .where(and(eq(topicFolderItems.roomId, roomId), inArray(topicFolderItems.userId, userIds)))
      .returning({ userId: topicFolderItems.userId });
    const removedUserIds = left.map((r) => r.userId);
    // 바로 전까지 멤버였던 사람만 — 그래야 "바로 전까지 그 방에 있던 담당자"(S3 규칙의 기준)가 맞다.
    const changedTodos = await resyncTodoProgressForMembers(t, roomId, removedUserIds, { left: true });
    return { folderItemRemoved: removed.length > 0, changedTodos, removedUserIds };
  };
  return tx ? run(tx) : db.transaction(run);
}

/**
 * 토픽 멤버·역할을 바꾸는 일(나가기·내보내기·토픽 관리자 지정)을 방마다 하나씩 차례로 처리한다 — 방 행을
 * 잠근 트랜잭션 안에서 [fn](tx)을 돌린다. 동시에 들어온 요청이 서로 바뀌기 전의 멤버 목록을 보고 판단하면
 * 토픽 관리자가 하나도 안 남을 수 있어서다(관리자 둘이 동시에 나가기 등).
 */
export function withRoomLock(roomId, fn) {
  return db.transaction(async (tx) => {
    await tx.select({ id: rooms.id }).from(rooms).where(eq(rooms.id, roomId)).for('no key update');
    return fn(tx);
  });
}

/**
 * [userId]를 방 하나에서 뺀다 — 방 종류마다 다른 뒷정리를 한곳에 모았다(비밀 대화 혼자 나가기와 팀에서 제외될 때가 같이
 * 쓴다). 토픽·그룹·나와의 대화는 멤버에서만 뺀다(토픽 폴더 배치·할 일 진척률은 removeRoomMembers가 같이 맞춘다). 1:1
 * 대화(평문·비밀)는 멤버가 둘뿐이라 빠진 사람이 남은 쪽 화면에서 "(알 수 없음)"이 되지 않게 이름을 남겨 두고(클라이언트
 * Room.displayName이 "OOO (나갔음)"으로 보여 준다), 비밀 대화에 아무도 안 남으면 방째 지운다(볼 사람이 없다 — 평문 대화는
 * 토픽·그룹처럼 기록을 남겨 둔다). [tx]는 이 방을 잠근 트랜잭션이어야 한다(withRoomLock·removeMemberFromTeamRooms).
 * 돌려주는 값: `{ room(바뀐 행 — 지웠으면 원래 행), removed(이번에 실제로 빠졌는지), deleted, remainingMemberIds,
 * folderItemRemoved, changedTodos }`. 그새 스스로 나가 이미 멤버가 아니었으면 아무것도 바꾸지 않는다(removed false).
 */
export async function removeMemberFromRoom(tx, room, userId, { departedName = null } = {}) {
  const { removedUserIds, folderItemRemoved, changedTodos } = await removeRoomMembers(room.id, [userId], tx);
  const removed = removedUserIds.length > 0;
  const remainingMemberIds = await listRoomMemberIds(room.id, tx);
  let current = room;
  let deleted = false;
  if (removed && room.type === 'dm' && !room.isSelf) {
    if (room.isSecret && remainingMemberIds.length === 0) {
      await deleteRoom(room.id, tx);
      deleted = true;
    } else {
      current = (await setSecretDepartedMember(room.id, { userId, name: departedName }, tx)) ?? room;
    }
  }
  return { room: current, removed, deleted, remainingMemberIds, folderItemRemoved, changedTodos };
}

/**
 * 방이 걸린 팀의 멤버가 아닌데 남아 있는 멤버십(room_members 행) — 팀에서 빠져도 방 멤버십은 남겨 두던 예전 규칙의 흔적이다
 * (지금은 팀에서 빠지면 그 팀 방에서도 함께 빠진다 — removeMemberFromTeamRooms). 비밀 대화는 만든 사람(rooms.created_by)의
 * 멤버십만 따진다 — 만든 사람은 그 팀 멤버여야 만들 수 있었지만, 받은 사람은 다른 팀에서 함께 있는 사람일 수 있어서
 * (secretChats.js) 이 팀에 없다고 팀에서 빠진 사람이라고 할 수 없다. listLeftoverTeamRoomMembers와 잠금 조회가 같은 조건을
 * 쓴다 — 고른 뒤 그새 팀에 다시 들어온 사람은 잠그면서 다시 걸러진다. 서버를 켤 때마다 이 조건에 걸리는 멤버십을 빼므로
 * (teams.js sweepLeftoverTeamRoomMembers), 팀 밖 사람을 팀 방에 넣는 기능을 새로 만들면 여기도 함께 맞춰야 한다. 하위 쿼리를
 * db.select()가 아니라 sql로 쓰는 건 모듈을 불러오기만 해도 db를 건드리지 않게 하려는 것이다(db를 막아 둔 테스트들도 이
 * 파일을 불러온다).
 */
const isLeftoverTeamRoomMembership = and(
  notExists(
    sql`(select 1 from ${teamMembers} where ${teamMembers.teamId} = ${rooms.teamId} and ${teamMembers.userId} = ${roomMembers.userId})`,
  ),
  or(eq(rooms.isSecret, false), sql`${rooms.createdBy} = ${roomMembers.userId}::text`),
);

/**
 * 팀에서 빠지는 사람([userId])을 그 팀([teamId])의 모든 방 — 토픽·그룹·1:1 대화·나와의 대화·비밀 대화 — 에서 한 번에
 * 뺀다(db/queries/teams.js removeTeamMember가 팀 멤버십을 지우는 같은 트랜잭션에서 부른다 — 팀에서 빠진 사람은 옛 대화도
 * 더는 볼 수 없다). 방 종류별 정리는 removeMemberFromRoom이 맡는다. 그 사람이 멤버인 방들을 id 순서로 한꺼번에 잠가서
 * (withRoomLock과 같은 잠금) 같은 때 들어온 나가기·내보내기·토픽 관리자 지정과 엇갈리지 않게 한다. 실제로 빠진 방만
 * removeMemberFromRoom의 결과 모양으로 돌려준다(호출부가 rooms.js notifyRemovedFromTeamRooms로 알린다).
 * [leftoverOnly]면 이미 팀 멤버십이 없는 사람의 남은 멤버십만 뺀다(isLeftoverTeamRoomMembership — 서버를 켤 때의 정리,
 * removeLeftoverTeamRoomMembers).
 */
export async function removeMemberFromTeamRooms(tx, teamId, userId, { departedName = null, leftoverOnly = false } = {}) {
  const memberRooms = await tx
    .select({ room: rooms })
    .from(rooms)
    .innerJoin(roomMembers, and(eq(roomMembers.roomId, rooms.id), eq(roomMembers.userId, userId)))
    .where(and(eq(rooms.teamId, teamId), leftoverOnly ? isLeftoverTeamRoomMembership : undefined))
    .orderBy(asc(rooms.id))
    .for('no key update', { of: rooms });
  const removals = [];
  for (const { room } of memberRooms) {
    const removal = await removeMemberFromRoom(tx, room, userId, { departedName });
    if (removal.removed) removals.push(removal);
  }
  return removals;
}

/** 팀 멤버가 아닌데 그 팀 방에 남아 있는 사람 — `[{ teamId, userId }]`(isLeftoverTeamRoomMembership). 서버를 켤 때의
 * 정리(teams.js sweepLeftoverTeamRoomMembers)가 이 쌍마다 removeLeftoverTeamRoomMembers를 부른다. [executor]는 테스트용. */
export function listLeftoverTeamRoomMembers(executor = db) {
  return executor
    .selectDistinct({ teamId: rooms.teamId, userId: roomMembers.userId })
    .from(roomMembers)
    .innerJoin(rooms, eq(rooms.id, roomMembers.roomId))
    .where(isLeftoverTeamRoomMembership)
    .orderBy(asc(rooms.teamId), asc(roomMembers.userId));
}

/** 이미 팀에서 빠진 사람([userId])을 그 팀([teamId]) 방에 남은 멤버십에서 뺀다 — removeTeamMember의 방 정리와 같은 일을
 * 팀 멤버십 없이 한 트랜잭션에서 한다. 돌려주는 값도 같다(removeMemberFromTeamRooms). */
export function removeLeftoverTeamRoomMembers(teamId, userId, { departedName = null } = {}) {
  return db.transaction((tx) => removeMemberFromTeamRooms(tx, teamId, userId, { departedName, leftoverOnly: true }));
}

/** 이 방에서의 역할 — 멤버가 아니면 null, 멤버면 'admin'(토픽 관리자) 또는 'member'. */
export async function getRoomMemberRole(roomId, userId) {
  const [row] = await db
    .select({ role: roomMembers.role })
    .from(roomMembers)
    .where(and(eq(roomMembers.roomId, roomId), eq(roomMembers.userId, userId)));
  return row?.role ?? null;
}

/** 멤버 id와 역할 목록 — 나가기(마지막 토픽 관리자)·내보내기·관리자 지정 규칙 판단용. [executor]는
 * withRoomLock 안에서 부를 때의 트랜잭션. */
export function listRoomMemberRoles(roomId, executor = db) {
  return executor
    .select({ userId: roomMembers.userId, role: roomMembers.role, accountRole: users.role })
    .from(roomMembers)
    .innerJoin(users, eq(users.id, roomMembers.userId))
    .where(eq(roomMembers.roomId, roomId));
}

/**
 * 토픽을 더 이상 관리할 수 없게 된 사람(준회원으로 내려감·탈퇴)의 토픽 관리자 역할을 거둔다 — 모든 팀의 토픽에서.
 * 역할이 바뀐 방 id들을 돌려준다(호출부가 방 정보를 다시 보낸다). 팀에서 빠진 사람은 그 팀 방에서 아예 빠지므로
 * (removeMemberFromTeamRooms) 여기서 따로 거둘 것이 없다.
 */
export async function clearTopicAdminRoles(userId) {
  const rows = await db
    .update(roomMembers)
    .set({ role: 'member' })
    .where(and(eq(roomMembers.userId, userId), eq(roomMembers.role, 'admin')))
    .returning({ roomId: roomMembers.roomId });
  return rows.map((r) => r.roomId);
}

/** 토픽 관리자를 통째로 다시 정한다 — [userIds]만 'admin', 나머지 멤버는 'member'. */
export async function setRoomAdmins(roomId, userIds, executor = db) {
  await executor
    .update(roomMembers)
    .set({ role: sql`case when ${inArray(roomMembers.userId, userIds)} then 'admin' else 'member' end` })
    .where(eq(roomMembers.roomId, roomId));
}

export async function isRoomMember(roomId, userId) {
  const [row] = await db
    .select({ userId: roomMembers.userId })
    .from(roomMembers)
    .where(and(eq(roomMembers.roomId, roomId), eq(roomMembers.userId, userId)));
  return !!row;
}

/** 방 멤버 id만(소켓 join 등 사용자 정보가 필요 없는 곳에서 가볍게). [executor]는 트랜잭션 안에서 부를 때. */
export function listRoomMemberIds(roomId, executor = db) {
  return executor
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
 * 싣는다(teams.js의 memberListResponse와 같은 방식). LEFT JOIN인 이유는 그 팀 멤버가 아닌 방 멤버도
 * 목록에서 빠지면 안 되어서다 — 비밀 대화는 어느 팀이든 함께 있는 사람과 시작할 수 있어서 상대가 방이 걸린
 * 팀의 멤버가 아닐 수 있다(팀에서 빠져도 방 멤버십을 남겨 두던 예전에 남은 행은 서버를 켤 때 정리된다 —
 * teams.js sweepLeftoverTeamRoomMembers).
 * 같은 조회에서 팀 소유자 여부(isTeamOwner)와 이 방의 역할(roomRole — 토픽 관리자면 'admin')도
 * 얹는다 — 방 DTO의 member.isOwner/adminIds를 멤버마다 따로 조회하지 않고 만들려고. */
export function listRoomMemberUsersWithOrg(roomId, teamId) {
  return db
    .select({
      user: users,
      teamDepartment: teamMembers.department,
      teamPosition: teamMembers.position,
      teamRole: teamMembers.role,
      roomRole: roomMembers.role,
    })
    .from(roomMembers)
    .innerJoin(users, eq(roomMembers.userId, users.id))
    .leftJoin(teamMembers, and(eq(teamMembers.userId, roomMembers.userId), eq(teamMembers.teamId, teamId)))
    .where(eq(roomMembers.roomId, roomId))
    .then((rows) =>
      rows.map((r) => ({
        ...r.user,
        teamDepartment: r.teamDepartment ?? null,
        teamPosition: r.teamPosition ?? null,
        isTeamOwner: r.teamRole === 'owner',
        roomRole: r.roomRole,
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

export async function getMemberCustomName(roomId, userId) {
  const [row] = await db
    .select({ customName: roomMembers.customName })
    .from(roomMembers)
    .where(and(eq(roomMembers.roomId, roomId), eq(roomMembers.userId, userId)));
  return row?.customName ?? null;
}

export async function setMemberCustomName(roomId, userId, customName) {
  await db
    .update(roomMembers)
    .set({ customName })
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

// ── 토픽 폴더(개인 설정) ────────────────────────────────────────────────
// project_folders(db/queries/projects.js)와 같은 방식 — 사람마다(팀마다) 따로 만드는 정리용 폴더.

/**
 * 내 폴더 목록(position, 만든 순) + 폴더마다 들어 있는 토픽 id. 내가 더 이상 멤버가 아닌 토픽은
 * 뺀다(나가기/내보내기 때 배치도 같이 지우지만, 혹시 남은 행이 있어도 안 보이게 한 번 더 거른다).
 */
export async function listTopicFolders(teamId, userId) {
  const folders = await db
    .select()
    .from(topicFolders)
    .where(and(eq(topicFolders.teamId, teamId), eq(topicFolders.userId, userId)))
    .orderBy(asc(topicFolders.position), asc(topicFolders.createdAt));
  if (folders.length === 0) return [];
  const items = await db
    .select({ folderId: topicFolderItems.folderId, roomId: topicFolderItems.roomId })
    .from(topicFolderItems)
    .innerJoin(
      roomMembers,
      and(eq(roomMembers.roomId, topicFolderItems.roomId), eq(roomMembers.userId, userId)),
    )
    .innerJoin(rooms, eq(rooms.id, topicFolderItems.roomId))
    .where(
      and(
        eq(topicFolderItems.userId, userId),
        inArray(
          topicFolderItems.folderId,
          folders.map((f) => f.id),
        ),
      ),
    )
    .orderBy(asc(rooms.name));
  const byFolder = new Map(folders.map((f) => [f.id, []]));
  for (const it of items) byFolder.get(it.folderId)?.push(it.roomId);
  return folders.map((f) => ({ ...f, roomIds: byFolder.get(f.id) ?? [] }));
}

export async function countTopicFolders(teamId, userId) {
  const [row] = await db
    .select({ n: sql`count(*)::int` })
    .from(topicFolders)
    .where(and(eq(topicFolders.teamId, teamId), eq(topicFolders.userId, userId)));
  return row?.n ?? 0;
}

/** 새 폴더는 맨 아래(가장 큰 position + 1)에 붙는다. */
export async function insertTopicFolder({ teamId, userId, name }) {
  const [{ next }] = await db
    .select({ next: sql`coalesce(max(${topicFolders.position}), -1) + 1` })
    .from(topicFolders)
    .where(and(eq(topicFolders.teamId, teamId), eq(topicFolders.userId, userId)));
  const [row] = await db
    .insert(topicFolders)
    .values({ teamId, userId, name, position: Number(next) })
    .returning();
  return row;
}

export function findTopicFolderById(id) {
  return db
    .select()
    .from(topicFolders)
    .where(eq(topicFolders.id, id))
    .then((rows) => rows[0] ?? null);
}

export async function updateTopicFolder(id, fields) {
  const [row] = await db.update(topicFolders).set(fields).where(eq(topicFolders.id, id)).returning();
  return row ?? null;
}

/** 폴더만 지운다 — 안의 토픽 배치(topic_folder_items)는 cascade로 같이 사라져 폴더 밖 목록으로 돌아간다. */
export async function deleteTopicFolder(id) {
  await db.delete(topicFolders).where(eq(topicFolders.id, id));
}

/** 폴더 하나에 들어 있는 (내가 멤버인) 토픽 id들 — 폴더 하나를 돌려줄 때 쓴다. */
export function listTopicFolderRoomIds(folderId, userId) {
  return db
    .select({ roomId: topicFolderItems.roomId })
    .from(topicFolderItems)
    .innerJoin(
      roomMembers,
      and(eq(roomMembers.roomId, topicFolderItems.roomId), eq(roomMembers.userId, userId)),
    )
    .innerJoin(rooms, eq(rooms.id, topicFolderItems.roomId))
    .where(and(eq(topicFolderItems.folderId, folderId), eq(topicFolderItems.userId, userId)))
    .orderBy(asc(rooms.name))
    .then((rows) => rows.map((r) => r.roomId));
}

/**
 * 내 폴더 배치를 바꾼다 — [folderId]가 null이면 어느 폴더에서든 뺀다. 한 토픽은 내 폴더 하나에만
 * 들어가므로(user_id, room_id 유일) 다른 폴더에 있었으면 옮겨진다.
 */
export async function setTopicFolder(userId, roomId, folderId) {
  if (folderId == null) {
    await db
      .delete(topicFolderItems)
      .where(and(eq(topicFolderItems.userId, userId), eq(topicFolderItems.roomId, roomId)));
    return;
  }
  await db
    .insert(topicFolderItems)
    .values({ userId, roomId, folderId })
    .onConflictDoUpdate({
      target: [topicFolderItems.userId, topicFolderItems.roomId],
      set: { folderId },
    });
}

/** 내 폴더 순서를 [folderIds] 순서대로 0..n-1로 다시 매긴다(호출부가 전부 내 폴더인지 확인한 뒤). */
export async function reorderTopicFolders(folderIds) {
  await db.transaction(async (tx) => {
    for (const [position, id] of folderIds.entries()) {
      await tx.update(topicFolders).set({ position }).where(eq(topicFolders.id, id));
    }
  });
}
