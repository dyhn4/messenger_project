/**
 * 디렉터리 그룹으로 팀·계정 등급 저절로 정하기의 **순수 규칙** — 규칙 입력 검사, 그룹 이름 맞추기(LDAP DN·CN, SAML 속성 값,
 * Microsoft 그룹 개체 ID), 로그인한 사람에게 무엇을 바꿀지(넣을 팀·뺄 팀·등급) 정하기. 실제로 바꾸는 것은 groupSync.js.
 * DB 없이 시험한다(test/groupSyncRules.test.js).
 */

export const GROUP_SOURCES = Object.freeze(['any', 'ldap', 'saml', 'microsoft']);
export const GROUP_SOURCE_LABEL = Object.freeze({ any: '어디서든', ldap: '사내 디렉터리(LDAP)', saml: 'SAML', microsoft: 'Microsoft' });
const ROLE_RANK = { guest: 0, member: 1, admin: 2 };
export const MAPPING_ROLES = Object.freeze(['guest', 'member', 'admin']);
export const GROUP_MAPPINGS_MAX = 200;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** 규칙 하나 입력 `{ source?, group, teamId?, accountRole? }` → `{ fields }` | `{ error }`. 팀이나 등급 중 하나는 있어야 한다. */
export function parseGroupMapping(body) {
  const b = body ?? {};
  const source = b.source ?? 'any';
  if (!GROUP_SOURCES.includes(source)) return { error: `그룹 출처는 ${GROUP_SOURCES.join('·')} 중 하나여야 합니다.` };
  const group = typeof b.group === 'string' ? b.group.trim() : '';
  if (!group || group.length > 500) return { error: '그룹 이름(또는 DN·개체 ID)을 500자 안으로 넣으세요.' };
  const teamId = b.teamId === null || b.teamId === undefined || b.teamId === '' ? null : b.teamId;
  if (teamId !== null && (typeof teamId !== 'string' || !UUID_RE.test(teamId))) return { error: '팀을 다시 고르세요.' };
  const accountRole = b.accountRole === null || b.accountRole === undefined || b.accountRole === '' ? null : b.accountRole;
  if (accountRole !== null && !MAPPING_ROLES.includes(accountRole)) return { error: '등급은 준회원·정회원·관리자 중 하나여야 합니다.' };
  if (!teamId && !accountRole) return { error: '넣을 팀이나 정할 등급 중 하나는 고르세요.' };
  return { fields: { source, group, teamId, accountRole } };
}

/** DN 비교용 — 소문자, 쉼표 앞뒤 공백 제거. */
const normDn = (s) =>
  String(s ?? '')
    .trim()
    .toLowerCase()
    .replace(/\s*,\s*/g, ',')
    .replace(/\s*=\s*/g, '=');

/** DN의 첫 CN 값(CN=영업팀,OU=… → 영업팀). DN이 아니면 null. */
export function cnOf(dn) {
  const m = /^\s*cn\s*=\s*((?:\\,|[^,])+)/i.exec(String(dn ?? ''));
  return m ? m[1].replace(/\\,/g, ',').trim() : null;
}

/**
 * 규칙의 [pattern]이 받은 그룹 [value]와 맞는지 — 대소문자 무시. LDAP 그룹은 DN이라 DN 전체가 같거나, 규칙이 DN이 아니면 CN 값이
 * 같아도 맞는다(관리자가 "영업팀"만 적어도 되게).
 */
export function groupMatches(pattern, value, source) {
  const p = String(pattern ?? '').trim();
  const v = String(value ?? '').trim();
  if (!p || !v) return false;
  if (p.toLowerCase() === v.toLowerCase()) return true;
  if (source === 'ldap' || /=/.test(v)) {
    if (/=/.test(p)) return normDn(p) === normDn(v);
    const cn = cnOf(v);
    return !!cn && cn.toLowerCase() === p.toLowerCase();
  }
  return false;
}

/** [source]에서 온 [groups]에 맞는 규칙들. */
export function matchingMappings(mappings, source, groups) {
  const list = Array.isArray(groups) ? groups : [];
  return (mappings ?? []).filter((m) => (m.source === 'any' || m.source === source) && list.some((g) => groupMatches(m.group, g, source)));
}

/** 더 높은 등급. */
export const higherRole = (a, b) => ((ROLE_RANK[b] ?? -1) > (ROLE_RANK[a] ?? -1) ? b : a);

/**
 * 이 사람에게 할 일 — `{ addTeamIds, removeTeamIds, role, roleReason }`([role]은 바꿀 새 등급, 바꾸지 않으면 null. [roleReason]은
 * 'grant'(규칙이 정해 줌 — 기억해 둔다) | 'revert'(그룹에서 빠져 기본 등급으로 — 기록을 지운다) | null).
 *  - 맞는 규칙의 팀 중 아직 아닌 팀에 넣는다.
 *  - [removeUnmatched]면 규칙으로 넣었던 팀([grantedTeamIds]) 중 이제 맞는 규칙이 없는 팀에서 뺀다(사람이 직접 넣은 팀·소유자인 팀은
 *    부르는 쪽이 빼지 않는다).
 *  - 등급: 맞는 규칙의 가장 높은 등급으로. 맞는 등급 규칙이 없고 [removeUnmatched]면, 지금 등급이 규칙이 정해 준 등급([syncedRole])
 *    그대로일 때만 기본 등급([defaultRole])으로 되돌린다(관리자가 손으로 바꾼 등급은 둔다).
 * [source]의 규칙이 하나도 없으면 아무것도 바꾸지 않는다(다른 출처로 정한 것을 이 로그인이 지우지 않게).
 */
export function planGroupSync({
  mappings,
  source,
  groups,
  currentTeamIds = [],
  grantedTeamIds = [],
  currentRole,
  syncedRole = null,
  defaultRole = 'member',
  removeUnmatched = false,
}) {
  const relevant = (mappings ?? []).filter((m) => m.source === 'any' || m.source === source);
  if (relevant.length === 0) return { addTeamIds: [], removeTeamIds: [], role: null, roleReason: null };
  const matched = matchingMappings(relevant, source, groups);
  const current = new Set(currentTeamIds);
  const desired = new Set(matched.map((m) => m.teamId).filter(Boolean));
  const addTeamIds = [...desired].filter((id) => !current.has(id));
  const removeTeamIds = removeUnmatched ? grantedTeamIds.filter((id) => current.has(id) && !desired.has(id)) : [];
  let wanted = null;
  for (const m of matched) if (m.accountRole) wanted = wanted ? higherRole(wanted, m.accountRole) : m.accountRole;
  let role = null;
  let roleReason = null;
  if (wanted) {
    if (wanted !== currentRole) [role, roleReason] = [wanted, 'grant'];
  } else if (removeUnmatched && syncedRole && syncedRole === currentRole && currentRole !== defaultRole) {
    [role, roleReason] = [defaultRole, 'revert'];
  }
  return { addTeamIds, removeTeamIds, role, roleReason };
}
