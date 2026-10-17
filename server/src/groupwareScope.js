/**
 * 그룹웨어(전자결재·연차·출퇴근)를 어떤 범위로 둘지 — DB 없이 시험할 수 있게 계산만 모았다(groupware.js가 쓴다).
 *
 * 서버 설정 groupwareScope:
 *  - 'org'(기본) — 부서·직책 설정(orgScope)을 따른다. 계정 단위면 회사 전체 하나, 팀 단위면 팀마다.
 *  - 'team' — 팀마다 따로(결재선·연차·출퇴근·근무 시간·관리자가 모두 팀 안).
 *  - 'server' — 서버(회사) 전체 하나.
 *
 * 실제 범위는 'team' | 'server' 둘 중 하나고, 행마다 범위 키(scope_key)로 저장한다 — 팀 범위면 팀 id, 회사 전체면 'server'.
 */

export const GROUPWARE_SCOPES = Object.freeze(['org', 'team', 'server']);

/** 범위 설정 값으로 받을 수 있는지(admin.js /admin/settings). */
export const isGroupwareScopeSetting = (value) => GROUPWARE_SCOPES.includes(value);

/** 지금 적용되는 범위 — 'team' | 'server'. */
export function effectiveGroupwareScope(settings) {
  const setting = settings?.groupwareScope ?? 'org';
  if (setting === 'team' || setting === 'server') return setting;
  return settings?.orgScope === 'account' ? 'server' : 'team';
}

/** 행에 적을 범위 키 — 팀 범위면 팀 id, 회사 전체면 'server'. */
export function groupwareScopeKey(scope, teamId) {
  return scope === 'server' ? 'server' : teamId;
}

/**
 * 결재·연차·근태를 관리할 수 있는지(입사일·연차 조정·근무 시간·전체 문서·근태 집계). 회사 전체 범위는 서버 운영자와 계정 등급
 * 관리자, 팀 범위는 그 팀을 관리하는 사람(소유자·계정 등급 관리자 — permissions.js canManageTeam)과 서버 운영자.
 */
export function canManageGroupware({ scope, role, isOwner = false, isServerAdmin = false }) {
  if (isServerAdmin || role === 'admin') return true;
  return scope === 'team' && isOwner === true;
}

/** 결재자·참조자로 고를 수 있는 사람인지 — 탈퇴·정지되지 않은 정회원 이상. 준회원은 결재선에 넣지 않는다. */
export function canBeApprover(user) {
  return !!user && !user.deletedAt && !user.suspendedAt && (user.role ?? 'guest') !== 'guest';
}

/** 범위 설정 이름(감사 로그·화면). */
export function groupwareScopeLabel(setting) {
  return setting === 'team' ? '팀마다' : setting === 'server' ? '회사 전체' : '부서·직책 설정을 따름';
}
