import { and, asc, eq, inArray, ne } from 'drizzle-orm';
import { db } from '../client.js';
import { teamMembers, teams, topicCreators, users } from '../schema.js';

export async function insertTeam(fields) {
  const [row] = await db.insert(teams).values(fields).returning();
  return row;
}

export function findTeamById(id) {
  return db
    .select()
    .from(teams)
    .where(eq(teams.id, id))
    .then((rows) => rows[0] ?? null);
}

/** 이 사람이 속한 팀 목록 — 팀 정보에 "그 팀에서 내 등급"까지 같이 준다(팀 목록 화면에서
 * 소유자에게만 설정 버튼을 보여주는 등에 쓴다). 만든 순서(오래된 것부터)로 정렬한다. */
export function listTeamsForUser(userId) {
  return db
    .select({ team: teams, role: teamMembers.role })
    .from(teamMembers)
    .innerJoin(teams, eq(teams.id, teamMembers.teamId))
    .where(eq(teamMembers.userId, userId))
    .orderBy(asc(teams.createdAt));
}

export async function updateTeam(id, fields) {
  const [row] = await db.update(teams).set(fields).where(eq(teams.id, id)).returning();
  return row;
}

export async function deleteTeam(id) {
  await db.delete(teams).where(eq(teams.id, id));
}

/** 여러 명을 한 번에 팀에 넣는다(이미 멤버면 조용히 무시). role은 'owner'|'member'만 쓴다. */
export async function addTeamMembers(teamId, userIds, role = 'member') {
  if (userIds.length === 0) return;
  await db
    .insert(teamMembers)
    .values(userIds.map((userId) => ({ teamId, userId, role })))
    .onConflictDoNothing();
}

export async function removeTeamMember(teamId, userId) {
  await db.delete(teamMembers).where(and(eq(teamMembers.teamId, teamId), eq(teamMembers.userId, userId)));
}

export async function isTeamMember(teamId, userId) {
  const [row] = await db
    .select({ userId: teamMembers.userId })
    .from(teamMembers)
    .where(and(eq(teamMembers.teamId, teamId), eq(teamMembers.userId, userId)));
  return !!row;
}

/** 이 사람이 어느 팀이든 하나라도 소유자인지 — 초대 링크 생성 권한 판정에 쓴다(permissions.js). */
export async function isOwnerOfAnyTeam(userId) {
  const [row] = await db
    .select({ teamId: teamMembers.teamId })
    .from(teamMembers)
    .where(and(eq(teamMembers.userId, userId), eq(teamMembers.role, 'owner')))
    .limit(1);
  return !!row;
}

/** 이 사람이 그 팀의 소유자인지 — 멤버가 아니면 null, 멤버면 'owner' 또는 'member'. */
export async function getTeamRole(teamId, userId) {
  const [row] = await db
    .select({ role: teamMembers.role })
    .from(teamMembers)
    .where(and(eq(teamMembers.teamId, teamId), eq(teamMembers.userId, userId)));
  return row?.role ?? null;
}

export async function setTeamRole(teamId, userId, role) {
  await db
    .update(teamMembers)
    .set({ role })
    .where(and(eq(teamMembers.teamId, teamId), eq(teamMembers.userId, userId)));
}

/** 부서/직책 변경(소유자·관리자만 — 검사는 teams.js 라우터에서). 넘긴 필드만 바꾼다. */
export async function updateTeamMember(teamId, userId, fields) {
  await db
    .update(teamMembers)
    .set(fields)
    .where(and(eq(teamMembers.teamId, teamId), eq(teamMembers.userId, userId)));
}

/** 그 팀의 특정 등급인 사람 id들 — 팀 전체 공지나 관리자 목록에 쓴다. */
export function listTeamMemberIdsByRole(teamId, role) {
  return db
    .select({ userId: teamMembers.userId })
    .from(teamMembers)
    .where(and(eq(teamMembers.teamId, teamId), eq(teamMembers.role, role)))
    .then((rows) => rows.map((r) => r.userId));
}


/** 팀 멤버 id만(가볍게 필요할 때). */
export function listTeamMemberIds(teamId) {
  return db
    .select({ userId: teamMembers.userId })
    .from(teamMembers)
    .where(eq(teamMembers.teamId, teamId))
    .then((rows) => rows.map((r) => r.userId));
}

/** 팀 멤버를 실제 사용자 정보로 — 조직도(멤버 패널)와 "새 대화" 상대 선택에 쓴다.
 * 탈퇴한 사용자도 포함하는 이유는 listRoomMemberUsers와 동일하다(이름/아바타가 이미
 * 익명화돼 있고, 빼버리면 예전 대화에서 그 사람이 "(알 수 없음)"이 된다). */
export function listTeamMemberUsers(teamId) {
  return db
    .select({
      user: users,
      role: teamMembers.role,
      department: teamMembers.department,
      position: teamMembers.position,
    })
    .from(teamMembers)
    .innerJoin(users, eq(teamMembers.userId, users.id))
    .where(eq(teamMembers.teamId, teamId))
    .then((rows) =>
      rows.map((r) => ({
        ...r.user,
        // 계정 등급(users.role)은 r.user에 그대로 들어있고, 여기서는 팀 단위 정보만 덧붙인다.
        isOwner: r.role === 'owner',
        teamDepartment: r.department ?? null,
        teamPosition: r.position ?? null,
      })),
    );
}

/**
 * 공개 토픽에 자동으로 넣어야 할 팀원 id들 = 준회원을 뺀 전원.
 * 등급이 계정 단위로 올라갔으므로 users.role을 기준으로 판단한다.
 */
export function listAutoJoinTeamMemberIds(teamId) {
  return db
    .select({ userId: teamMembers.userId })
    .from(teamMembers)
    .innerJoin(users, eq(teamMembers.userId, users.id))
    .where(and(eq(teamMembers.teamId, teamId), ne(users.role, 'guest')))
    .then((rows) => rows.map((r) => r.userId));
}

/** 한 사람의 팀 멤버십 한 행(등급+부서/직책). 멤버가 아니면 null. */
export function findTeamMember(teamId, userId) {
  return db
    .select()
    .from(teamMembers)
    .where(and(eq(teamMembers.teamId, teamId), eq(teamMembers.userId, userId)))
    .then((rows) => rows[0] ?? null);
}

/** 여러 팀에 대해 "내가 그 팀 멤버인지"를 한 번에 — 소켓/알림에서 팀 범위를 확인할 때. */
export function listTeamIdsForUser(userId) {
  return db
    .select({ teamId: teamMembers.teamId })
    .from(teamMembers)
    .where(eq(teamMembers.userId, userId))
    .then((rows) => rows.map((r) => r.teamId));
}

export function listTeamsByIds(ids) {
  if (ids.length === 0) return Promise.resolve([]);
  return db.select().from(teams).where(inArray(teams.id, ids));
}

/** topicCreationPolicy가 'designated'일 때, 이 사람이 지정된 토픽 생성자인지(permissions.js
 * canCreateTopic에 넘길 값 — DB 조회가 필요해서 그 순수 함수 대신 여기서 미리 확인한다). */
export async function isTopicCreator(teamId, userId) {
  const [row] = await db
    .select({ userId: topicCreators.userId })
    .from(topicCreators)
    .where(and(eq(topicCreators.teamId, teamId), eq(topicCreators.userId, userId)));
  return !!row;
}

/** 지정된 토픽 생성자 id만(가볍게, 값 비교용). */
export function listTopicCreatorIds(teamId) {
  return db
    .select({ userId: topicCreators.userId })
    .from(topicCreators)
    .where(eq(topicCreators.teamId, teamId))
    .then((rows) => rows.map((r) => r.userId));
}

/** 지정된 토픽 생성자를 실제 사용자 정보로 — 팀 설정 화면에 이름/아바타를 보여줄 때. */
export function listTopicCreatorUsers(teamId) {
  return db
    .select({ user: users })
    .from(topicCreators)
    .innerJoin(users, eq(topicCreators.userId, users.id))
    .where(eq(topicCreators.teamId, teamId))
    .then((rows) => rows.map((r) => r.user));
}

/** 지정된 토픽 생성자 목록을 통째로 교체한다("확인" 한 번에 전체를 다시 정한다 — 팀 설정
 * 화면의 멤버 선택 다이얼로그가 매번 "지금 지정된 사람 전체"를 다시 보내온다). */
export async function setTopicCreators(teamId, userIds) {
  await db.transaction(async (tx) => {
    await tx.delete(topicCreators).where(eq(topicCreators.teamId, teamId));
    if (userIds.length > 0) {
      await tx.insert(topicCreators).values(userIds.map((userId) => ({ teamId, userId })));
    }
  });
}
