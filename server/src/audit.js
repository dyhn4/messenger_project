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
  // 서버 백업 설정 변경·"지금 백업"(admin.js /admin/backup) — 백업 암호는 남기지 않는다.
  serverBackup: 'server.backup',
  inviteLinkCreate: 'invite.create',
  inviteLinkRevoke: 'invite.revoke',
  teamInviteLinkCreate: 'teamInvite.create',
  teamInviteLinkRevoke: 'teamInvite.revoke',
  // 초대 링크를 메일로 보냄(inviteMail.js) — 받는 주소는 남기지 않고 통 수만.
  inviteLinkEmail: 'invite.email',
  teamInviteLinkEmail: 'teamInvite.email',
  // 그룹웨어(groupware.js) — 관리자가 한 일만: 입사일·연차 조정·근무 시간, 승인된 결재 취소.
  groupwareHireDate: 'groupware.hireDate',
  groupwareLeaveAdjust: 'groupware.leaveAdjust',
  groupwareSettings: 'groupware.settings',
  groupwareCancel: 'groupware.cancel',
  // 토픽 삭제(rooms.js DELETE /rooms/:id) — 메시지·파일이 전부 사라지는 되돌릴 수 없는 일이라 남긴다.
  topicDelete: 'topic.delete',
  // 그룹채팅 → 토픽 전환(rooms.js POST /rooms/:id/convert-to-topic) — 되돌릴 수 없는 일이라 남긴다.
  roomConvert: 'room.convert',
  // 비밀번호·보안 질문 답을 계속 틀려 로그인/재설정이 막히기 시작함(authGuard.js) — 행위자는 그 IP.
  authLockout: 'auth.lockout',
  // 로그인 보안 설정(2단계 인증 정책·회사 계정·사내 디렉터리 — admin.js /admin/login-security). 비밀값은 남기지 않는다.
  loginSecurity: 'auth.loginSecurity',
  // 관리자가 회원의 2단계 인증을 해제함(휴대폰을 잃어버렸을 때).
  userOtpReset: 'user.otpReset',
  // 외부 연동(integrations.js) — 들어오는 웹훅·슬래시 명령을 만들고 지움. 바깥에서 대화방에 글을 올리는 통로라 남긴다.
  integrationCreate: 'integration.create',
  integrationDelete: 'integration.delete',
  // 조직도(orgTree.js) — 부서 만들기·바꾸기·지우기, 사람의 부서·상위자 지정. 결재선 추천이 이것을 따르므로 남긴다.
  orgTree: 'org.tree',
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
