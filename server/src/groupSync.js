import { applyAccountRole } from './admin.js';
import { AUDIT, recordAudit } from './audit.js';
import { addGroupSyncGrant, listGrantedTeamIds, listGroupMappings } from './db/queries/loginSecurityExtras.js';
import { getServerSettings } from './db/queries/serverSettings.js';
import { addTeamMembers, findTeamById, getTeamRole, listTeamIdsForUser } from './db/queries/teams.js';
import { findUserById } from './db/queries/users.js';
import { GROUP_SOURCE_LABEL, planGroupSync } from './groupSyncRules.js';
import { accountRole } from './permissions.js';
import { announceTeamJoin, announceTeamRemoval } from './selfRoomNotices.js';
import { afterTeamMembersAdded, removeUserFromTeam } from './teams.js';

/**
 * 디렉터리 그룹으로 팀·계정 등급 저절로 정하기 — 회사 계정·디렉터리로 들어온 사람의 그룹(LDAP memberOf, SAML 그룹 속성, Microsoft
 * groups 클레임)을 관리자 콘솔의 규칙(directory_group_mappings)과 맞춰 팀에 넣고(일반 멤버) 계정 등급을 정한다. "그룹에서 빠지면
 * 빼기"를 켜면 규칙으로 넣었던 팀에서 빼고(사람이 직접 넣은 팀·소유자인 팀은 그대로) 규칙이 올려 준 등급을 기본 등급으로 되돌린다.
 * 무엇을 바꿀지는 groupSyncRules.js planGroupSync가 정한다.
 *
 * 언제: 디렉터리(LDAP) 로그인·회사 계정(Microsoft·SAML) 로그인 때마다, 그리고 디렉터리 계정을 10분마다 다시 볼 때(토큰 갱신 —
 * loginSecurity.js directoryAccountActive). 실패해도 로그인은 막지 않는다(기록만). 바꾼 것은 감사 로그에 "디렉터리 그룹 규칙"으로 남는다.
 */

const ACTOR = '디렉터리 그룹 규칙';

/** [user]의 그룹([source]에서 온 [groups])으로 팀·등급을 맞춘다. 바꾼 것 `{ added, removed, role }` | null(꺼짐·할 일 없음·실패). */
export async function syncDirectoryGroups(io, user, { source, groups }) {
  try {
    const settings = await getServerSettings();
    if (!settings.groupSyncEnabled || !user || user.deletedAt || user.suspendedAt) return null;
    const mappings = (await listGroupMappings()).map((r) => r.mapping);
    if (mappings.length === 0) return null;
    const [currentTeamIds, grantedTeamIds] = await Promise.all([listTeamIdsForUser(user.id), listGrantedTeamIds(user.id)]);
    const plan = planGroupSync({
      mappings,
      source,
      groups,
      currentTeamIds,
      grantedTeamIds,
      currentRole: accountRole(user),
      syncedRole: user.groupSyncRole ?? null,
      defaultRole: (source === 'ldap' ? settings.ldapDefaultRole : settings.ssoDefaultRole) ?? 'member',
      removeUnmatched: !!settings.groupSyncRemove,
    });
    const why = `${GROUP_SOURCE_LABEL[source] ?? source} 그룹`;
    let current = user;

    // 등급을 먼저 — 새로 들어갈 팀의 자동 참여 토픽이 바뀐 등급(준회원이면 빠짐)을 따르게.
    if (plan.role) {
      const before = accountRole(current);
      // 규칙이 정해 준 등급은 기억하고(그룹에서 빠지면 되돌릴 수 있게), 기본 등급으로 되돌렸으면 기록을 지운다.
      current = await applyAccountRole(io, current, plan.role, {
        extra: { groupSyncRole: plan.roleReason === 'grant' ? plan.role : null },
      });
      recordAudit({
        actorId: null,
        actorName: ACTOR,
        action: AUDIT.userRole,
        targetType: 'user',
        targetId: user.id,
        targetLabel: user.name ?? user.username,
        detail: `등급 ${before} → ${plan.role}(${why})`,
      });
    }

    const added = [];
    for (const teamId of plan.addTeamIds) {
      const team = await findTeamById(teamId);
      if (!team) continue;
      const joined = await addTeamMembers(team.id, [user.id], 'member');
      await addGroupSyncGrant(user.id, team.id);
      if (joined.length === 0) continue;
      await afterTeamMembersAdded(io, team, { userIds: [user.id], accountRoles: new Map([[user.id, accountRole(current)]]) });
      await announceTeamJoin(io, { teamId: team.id, joinerIds: joined });
      added.push(team.id);
      recordAudit({
        actorId: null,
        actorName: ACTOR,
        action: AUDIT.teamMemberAdd,
        teamId: team.id,
        teamName: team.name,
        targetType: 'user',
        targetId: user.id,
        targetLabel: user.name ?? user.username,
        detail: `팀에 추가(${why})`,
      });
    }

    const removed = [];
    for (const teamId of plan.removeTeamIds) {
      const team = await findTeamById(teamId);
      if (!team || (await getTeamRole(team.id, user.id)) === 'owner') continue;
      const rooms = await removeUserFromTeam(io, team, user.id, { userName: user.name ?? user.username });
      await announceTeamRemoval(io, { teamId: team.id, userId: user.id });
      removed.push(team.id);
      recordAudit({
        actorId: null,
        actorName: ACTOR,
        action: AUDIT.teamMemberRemove,
        teamId: team.id,
        teamName: team.name,
        targetType: 'user',
        targetId: user.id,
        targetLabel: user.name ?? user.username,
        detail: `팀에서 제외(${why}에서 빠짐, 대화방 ${rooms.length}개에서도 나감)`,
      });
    }
    if (!plan.role && added.length === 0 && removed.length === 0) return null;
    return { added, removed, role: plan.role };
  } catch (err) {
    console.error('[groupSync] 그룹 규칙을 맞추지 못했습니다:', user?.id, err?.message ?? err);
    return null;
  }
}

/** 로그인 직후 — 바뀐 등급이 토큰·응답에 맞게 계정을 다시 읽어 돌려준다(안 바뀌었으면 그대로). */
export async function syncDirectoryGroupsOnLogin(io, user, groupsInput) {
  const changed = await syncDirectoryGroups(io, user, groupsInput);
  return changed?.role ? ((await findUserById(user.id)) ?? user) : user;
}
