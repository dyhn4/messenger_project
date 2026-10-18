import { listConcurrent } from './db/queries/orgTree.js';
import { isUuid } from './favoritesRules.js';
import { loadOrgTree } from './orgTree.js';
import { departmentMemberIds, departmentOptions, orgScopeKey } from './orgTreeRules.js';

/**
 * 휴가 달력의 부서 거르기 — 그룹웨어 범위의 조직도(부서·직책 설정을 따른다 — 회사 전체면 계정 조직도, 팀마다면 지금 팀)에서 부서 목록과,
 * `?departmentId=`(uuid 또는 'none' — 부서 없음)로 고른 부서(아래 부서·겸직 포함)에 든 사람들. 고르지 않았거나 그 부서가 없으면 거르지 않는다.
 * `{ departments: [{ id, name, parentId, depth }], departmentId(적용한 것 — 없으면 null), userIds(Set | null) }`.
 */
export async function leaveDepartmentFilter(ctx, rawDepartmentId, teamIdInput = null) {
  const scopeKey = orgScopeKey(ctx.settings, ctx.teamId ?? (isUuid(teamIdInput) ? teamIdInput : null));
  if (!scopeKey) return { departments: [], departmentId: null, userIds: null };
  const [{ departments, members }, concurrent] = await Promise.all([loadOrgTree(scopeKey), listConcurrent(scopeKey)]);
  const options = departmentOptions(departments);
  const wanted = rawDepartmentId === 'none' ? 'none' : isUuid(rawDepartmentId) && departments.some((d) => d.id === rawDepartmentId) ? rawDepartmentId : null;
  if (!wanted) return { departments: options, departmentId: null, userIds: null };
  return { departments: options, departmentId: wanted, userIds: departmentMemberIds({ departmentId: wanted, departments, members, concurrent }) };
}
