import { APPROVAL_KINDS } from './approvalRules.js';
import { pickLineRule } from './approvalLineRules.js';
import { MONEY_MAX } from './approvalForms.js';
import { isUuid } from './favoritesRules.js';

/**
 * **전결 규정**(위임 전결 — 순수 규칙) — 결재 종류(와 양식·금액)마다 "어느 직책 이상이 전결하는지"를 정해 두면, 결재를 올릴 때 결재선에서 그
 * 직책 이상인 첫 결재자가 저절로 전결(role 'final' — 승인하면 남은 칸은 생략)이 된다. 예: 지출 100만 원 미만은 팀장 전결, 100만 원 이상은
 * 본부장 전결. 규정이 맞으면 올리는 사람이 직접 고른 전결은 지우고 규정대로 정한다(결재선에 그 직책 이상이 없으면 전결 없이 끝까지).
 * 합의·후결 칸은 전결이 될 수 없다. 고르는 순서는 결재선 규칙과 같다(approvalLineRules.js pickLineRule — 양식 하나 > 종류 > 모든 종류,
 * 그 안에서 문서 금액 이하인 가장 큰 금액 기준). DB는 approval_final_rules(groupware.js). `node --test`로 시험한다
 * (test/approvalFollowup.test.js).
 */

export const FINAL_RULE_KINDS = Object.freeze(['any', ...APPROVAL_KINDS]);
/** 한 범위의 전결 규정 수. */
export const FINAL_RULES_MAX = 100;

/**
 * 규정 입력 `{ kind, templateId?, minAmount?, positionLabel }` 검사 → `{ fields }` | `{ error }`. [positionLabels]는 직책 목록(서열
 * 순) — 그 안의 직책만.
 */
export function parseFinalRule(body, { positionLabels }) {
  const b = body ?? {};
  if (!FINAL_RULE_KINDS.includes(b.kind)) return { error: '결재 종류를 고르세요.' };
  let templateId = null;
  if (b.templateId !== undefined && b.templateId !== null && b.templateId !== '') {
    if (b.kind !== 'form' || !isUuid(b.templateId)) return { error: '양식은 "관리자가 만든 양식" 종류에서만 고릅니다.' };
    templateId = b.templateId;
  }
  let minAmount = null;
  if (b.minAmount !== undefined && b.minAmount !== null && b.minAmount !== '') {
    const n = Number(b.minAmount);
    if (!Number.isInteger(n) || n < 0 || n > MONEY_MAX) return { error: '금액은 0 이상의 원 단위 숫자로 넣으세요.' };
    minAmount = n;
  }
  const positionLabel = typeof b.positionLabel === 'string' ? b.positionLabel.trim() : '';
  if (!positionLabels.includes(positionLabel)) return { error: '전결할 직책을 직책 목록에서 고르세요.' };
  return { fields: { kind: b.kind, templateId, minAmount, positionLabel } };
}

/** 문서에 맞는 전결 규정 하나(없으면 null) — 결재선 규칙과 같은 순서. */
export const pickFinalRule = (rules, { kind, templateId = null, amount = null }) => pickLineRule(rules, { kind, templateId, amount });

/**
 * 결재선에 규정을 입힌다 → `{ roles, finalUserId }`. [approverIds]는 결재선 순서, [roles]는 사람 id → 역할(결재가 아닌 것만 —
 * approvalRules.js validateApprovalLine과 같은 모양). 있던 전결은 지우고, 역할이 결재인 사람 중 서열([rankOf] — 클수록 높다)이 규정
 * 직책([rankOfLabel]) 이상인 첫 사람을 전결로 한다. 그런 사람이 없으면 전결 없음(null).
 */
export function applyFinalRule(rule, { approverIds, roles = {}, rankOf = () => null, rankOfLabel = () => null }) {
  const out = {};
  for (const [id, role] of Object.entries(roles ?? {})) if (role !== 'final') out[id] = role;
  const target = rule ? rankOfLabel(rule.positionLabel) : null;
  if (target == null) return { roles: out, finalUserId: null };
  const finalUserId = approverIds.find((id) => (out[id] ?? 'approve') === 'approve' && (rankOf(id) ?? -1) >= target) ?? null;
  if (finalUserId) out[finalUserId] = 'final';
  return { roles: out, finalUserId };
}

/** 화면에 보낼 규정 모양. */
export const finalRuleDto = (r, { templateName = null } = {}) => ({
  id: r.id,
  kind: r.kind,
  templateId: r.templateId ?? null,
  templateName,
  minAmount: r.minAmount ?? null,
  positionLabel: r.positionLabel,
});
