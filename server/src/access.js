import { getRoomMemberRole } from './db/queries/rooms.js';
import { getTeamRole, isOwnerOfAnyTeam } from './db/queries/teams.js';
import { findUserById } from './db/queries/users.js';
import { accountRole, canManageTopic } from './permissions.js';

/**
 * "이 사람이 이 팀에서 무엇을 할 수 있는지"를 판단하는 데 필요한 값을 한 번에 모아온다.
 * 권한이 계정 등급(users.role)과 팀 소유자 여부(team_members.role) 두 축으로 나뉘어서,
 * 라우터마다 두 번씩 조회하지 않도록 여기서 묶는다.
 *
 * 반환값을 그대로 permissions.js의 canManageTeam/canCreateTopic 등에 넘길 수 있다.
 */
export async function teamAccess(teamId, userId) {
  const [user, teamRole] = await Promise.all([findUserById(userId), getTeamRole(teamId, userId)]);
  return {
    user,
    role: accountRole(user), // 계정 등급: 'guest' | 'member' | 'admin'
    isMember: teamRole !== null,
    isOwner: teamRole === 'owner',
    isServerAdmin: !!user?.isServerAdmin,
  };
}

/**
 * teamAccess에 "이 방에서의 나"를 더한 것 — 방 멤버인지(isRoomMember), 토픽 관리자인지
 * (isTopicAdmin), 그래서 이 토픽을 관리할 수 있는지(canManage: 토픽이고, 멤버이고,
 * permissions.js의 canManageTopic을 만족). 토픽 관리 라우트(rooms.js)와 글쓰기 제한(socket.js,
 * messages.js)이 같은 판단을 쓰도록 여기 모았다.
 */
export async function topicAccess(room, userId) {
  const [access, memberRole] = await Promise.all([teamAccess(room.teamId, userId), getRoomMemberRole(room.id, userId)]);
  const isRoomMember = memberRole !== null;
  const isTopicAdmin = memberRole === 'admin';
  return {
    ...access,
    isRoomMember,
    isTopicAdmin,
    // 그 팀 멤버만 토픽을 관리할 수 있다 — 팀에서 빠지면 그 팀 방에서도 함께 빠지고 예전 규칙 때 남은 멤버십도 서버를
    // 켤 때 정리되지만(db/queries/rooms.js removeMemberFromTeamRooms, teams.js sweepLeftoverTeamRoomMembers), 그 전이나
    // 엇갈려 남은 행이 있어도 관리는 못 하게 한 번 더 막는다(토픽 관리자였어도, 다른 팀의 관리자 등급이어도 마찬가지).
    canManage: room.type === 'topic' && isRoomMember && access.isMember && canManageTopic({ ...access, isTopicAdmin }),
  };
}

/** 팀과 무관하게 계정 등급만 필요할 때(팀 생성 등). */
export async function userAccess(userId) {
  const user = await findUserById(userId);
  return {
    user,
    role: accountRole(user),
    isServerAdmin: !!user?.isServerAdmin,
  };
}

/** userAccess에 "어느 팀이든 소유자인지"를 더한 것 — 초대 링크 생성 권한 판정 전용
 * (permissions.js의 canCreateInviteLink). 팀 소유자 조회가 추가로 필요해서 따로 뺐다. */
export async function inviteLinkAccess(userId) {
  const [base, ownsTeam] = await Promise.all([userAccess(userId), isOwnerOfAnyTeam(userId)]);
  return { ...base, isOwnerOfAnyTeam: ownsTeam };
}
