import { findTeamMember } from './db/queries/teams.js';
import { findUserById } from './db/queries/users.js';
import { getServerSettings } from './db/queries/serverSettings.js';

/** 서버 설정(orgScope)에 따라 팀 값(team_members.position) 또는 계정 값(users.position) 중
 * 하나를 고른다 — rooms.js의 resolveMembers/teams.js의 memberListResponse와 같은 규칙을
 * 한 사람 단위로 다시 쓸 수 있게 뺐다(inquiries.js의 "팀장에게만 문의 가능" 권한 확인용). */
export async function resolvePosition(userId, teamId) {
  const [settings, teamMember, user] = await Promise.all([
    getServerSettings(),
    findTeamMember(teamId, userId),
    findUserById(userId),
  ]);
  const byTeam = settings.orgScope !== 'account';
  return (byTeam ? teamMember?.position : user?.position) ?? null;
}
