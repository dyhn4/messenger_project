import { insertAuditLog } from './db/queries/audit.js';

/**
 * 감사 로그에 남기는 행위 종류. 화면(관리자 콘솔)에서 이 값으로 필터하고 한국어 이름을
 * 붙이므로, 클라이언트 admin_console_screen.dart의 목록과 같이 맞춰야 한다.
 */
export const AUDIT = {
  messageDelete: 'message.delete',
  commentDelete: 'comment.delete',
  teamMemberRole: 'team.member.role',
  teamMemberAdd: 'team.member.add',
  teamMemberRemove: 'team.member.remove',
  teamSettings: 'team.settings',
  teamCreate: 'team.create',
  teamDelete: 'team.delete',
  teamTransferOwner: 'team.transferOwner',
  userSuspend: 'user.suspend',
  userUnsuspend: 'user.unsuspend',
  userLogoutAll: 'user.logoutAll',
  userRole: 'user.role',
  userOrg: 'user.org',
  userServerAdmin: 'user.serverAdmin',
  serverSettings: 'server.settings',
  inviteLinkCreate: 'invite.create',
  inviteLinkRevoke: 'invite.revoke',
};

/**
 * 감사 로그 한 줄 기록. **실패해도 절대 원래 동작을 막지 않는다** — 로그를 못 남겼다고
 * 메시지 삭제나 등급 변경이 실패하면 더 나쁘기 때문에, 오류는 콘솔에만 남기고 삼킨다.
 * 그래서 호출부에서 await하지 않아도 된다(불필요하게 응답을 늦추지 않도록).
 *
 * actorName/teamName/targetLabel은 "그 시점의 이름" 스냅샷이다 — 나중에 계정이나 팀이
 * 사라져도 로그만 보고 무슨 일이었는지 알 수 있어야 하기 때문이다.
 */
export function recordAudit({
  actorId = null,
  actorName,
  action,
  teamId = null,
  teamName = null,
  targetType = null,
  targetId = null,
  targetLabel = null,
  detail = null,
}) {
  return insertAuditLog({
    actorId,
    actorName: actorName || '(알 수 없음)',
    action,
    teamId,
    teamName,
    targetType,
    targetId: targetId == null ? null : String(targetId),
    targetLabel,
    detail,
  }).catch((err) => {
    console.error('[audit] 기록 실패:', err?.message ?? err);
  });
}

export function toAuditLogDto(row) {
  return {
    id: row.id,
    actorId: row.actorId ?? null,
    actorName: row.actorName,
    action: row.action,
    teamId: row.teamId ?? null,
    teamName: row.teamName ?? null,
    targetType: row.targetType ?? null,
    targetId: row.targetId ?? null,
    targetLabel: row.targetLabel ?? null,
    detail: row.detail ?? null,
    createdAt: new Date(row.createdAt).getTime(),
  };
}
