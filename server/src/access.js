import { getTeamRole, isOwnerOfAnyTeam } from './db/queries/teams.js';
import { findUserById } from './db/queries/users.js';
import { accountRole } from './permissions.js';

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
