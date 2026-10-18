import { APPROVAL_KINDS } from './approvalRules.js';

/**
 * 결재선 규칙(approval_line_rules)의 **순수 규칙** — 결재 종류(와 금액)마다 조직도 상위자 사슬을 어디까지 채울지. 예:
 *  - 휴가: 상위자 1명(팀장까지)
 *  - 지출: 100만 원 미만 상위자 2명, 100만 원 이상은 직책 '본부장' 이상인 상위자가 나올 때까지 + 늘 재무팀장(뒤에 붙는 결재자)
 * 규칙이 없으면 예전처럼 사슬을 5명까지 채운다(approvalRules.js suggestApprovalLine). 규칙은 결재선을 **미리 채울 때만** 쓰고, 올리는
 * 사람이 고칠 수 있다. DB는 groupware.js. DB 없이 시험한다(test/approvalLineRules.test.js).
 */

export const RULE_KINDS = Object.freeze(['any', ...APPROVAL_KINDS]);
export const RULE_MODES = Object.freeze(['levels', 'position']);
export const LINE_RULES_MAX = 100;
export const RULE_LEVELS_MAX = 10;
/** 규칙이 있을 때 상위자 사슬을 읽어 올 최대 길이(직책 기준은 높은 사람까지 올라가야 해서 기본 5명보다 길게). */
export const RULE_CHAIN_MAX = 10;
const EXTRA_MAX = 5;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const AMOUNT_MAX = 1_000_000_000_000;

/**
 * 규칙 입력 `{ kind, templateId?, minAmount?, mode, levels?, positionLabel?, extraApproverIds?, ccIds? }` → `{ fields }` | `{ error }`.
 * [positionLabels]는 직책 목록(position_options)의 이름들, [isCandidate]는 결재자로 고를 수 있는 사람인지.
 */
export function parseLineRule(body, { positionLabels = [], isCandidate = () => true } = {}) {
  const b = body ?? {};
  if (!RULE_KINDS.includes(b.kind)) return { error: '결재 종류를 고르세요.' };
  let templateId = null;
  if (b.templateId !== undefined && b.templateId !== null && b.templateId !== '') {
    if (b.kind !== 'form' || typeof b.templateId !== 'string' || !UUID_RE.test(b.templateId)) {
      return { error: '양식은 "관리자가 만든 양식" 종류에서만 고릅니다.' };
    }
    templateId = b.templateId;
  }
  let minAmount = null;
  if (b.minAmount !== undefined && b.minAmount !== null && b.minAmount !== '') {
    const n = Number(b.minAmount);
    if (!Number.isInteger(n) || n < 0 || n > AMOUNT_MAX) return { error: '금액은 0 이상의 원 단위 숫자로 넣으세요.' };
    minAmount = n;
  }
  if (!RULE_MODES.includes(b.mode)) return { error: '어디까지 채울지 고르세요.' };
  let levels = null;
  let positionLabel = null;
  if (b.mode === 'levels') {
    const n = Number(b.levels);
    if (!Number.isInteger(n) || n < 0 || n > RULE_LEVELS_MAX) return { error: `상위자 수는 0~${RULE_LEVELS_MAX}명으로 정하세요.` };
    levels = n;
  } else {
    positionLabel = typeof b.positionLabel === 'string' ? b.positionLabel.trim() : '';
    if (!positionLabels.includes(positionLabel)) return { error: '직책 목록에 있는 직책을 고르세요.' };
  }
  // [tooMany]·[invalid]는 칸마다의 오류 문구(문장 전체 — 앱이 통째로 번역한다).
  const people = (value, tooMany, invalid) => {
    const list = Array.isArray(value) ? [...new Set(value)] : [];
    if (list.length > EXTRA_MAX) return { error: tooMany };
    if (list.some((id) => typeof id !== 'string' || !UUID_RE.test(id) || !isCandidate(id))) {
      return { error: invalid };
    }
    return { ids: list };
  };
  const extra = people(
    b.extraApproverIds,
    `늘 붙일 결재자는 ${EXTRA_MAX}명까지입니다.`,
    '늘 붙일 결재자에 결재자로 고를 수 없는 사람이 있습니다.',
  );
  if (extra.error) return extra;
  const cc = people(b.ccIds, `참조자는 ${EXTRA_MAX}명까지입니다.`, '참조자에 결재자로 고를 수 없는 사람이 있습니다.');
  if (cc.error) return cc;
  if (cc.ids.some((id) => extra.ids.includes(id))) return { error: '같은 사람을 결재자와 참조자로 함께 넣을 수 없습니다.' };
  return { fields: { kind: b.kind, templateId, minAmount, mode: b.mode, levels, positionLabel, extraApproverIds: extra.ids, ccIds: cc.ids } };
}

/**
 * 문서에 맞는 규칙 하나 — 종류가 같은 것(양식이면 그 양식만 정한 것이 더 먼저) → 'any', 그 안에서 금액 기준([minAmount])이 문서 금액
 * 이하인 것 중 가장 큰 것. 금액 기준이 있는 규칙은 금액을 모르면 고르지 않는다. 없으면 null.
 */
export function pickLineRule(rules, { kind, templateId = null, amount = null }) {
  const specificity = (r) => (r.kind === kind ? (r.templateId ? (r.templateId === templateId ? 3 : -1) : 2) : r.kind === 'any' ? 1 : -1);
  const usable = (rules ?? []).filter(
    (r) => specificity(r) > 0 && (r.minAmount == null || (typeof amount === 'number' && amount >= r.minAmount)),
  );
  usable.sort((a, b) => specificity(b) - specificity(a) || (b.minAmount ?? -1) - (a.minAmount ?? -1));
  return usable[0] ?? null;
}

/**
 * 규칙대로 결재선 채우기 → `{ approverIds, ccIds }`. [chain]은 상위자 사슬(가까운 사람부터, 결재자로 고를 수 있는 사람만), [rankOf]는 사람
 * id → 직책 서열(직책 목록의 순서 — 클수록 높다, 모르면 null), [rankOfLabel]은 직책 이름 → 서열.
 *  - 'levels': 사슬의 앞 [levels]명
 *  - 'position': 서열이 [positionLabel] 이상인 사람이 나올 때까지(그 사람 포함) — 끝내 없으면 사슬 전부
 * 그 뒤에 늘 붙일 결재자(이미 들어 있거나 올리는 사람 자신이면 뺀다), 참조자는 결재자와 겹치지 않게.
 */
export function applyLineRule(rule, { chain, authorId, rankOf = () => null, rankOfLabel = () => null }) {
  let approverIds;
  if (rule.mode === 'levels') {
    approverIds = chain.slice(0, rule.levels ?? 0);
  } else {
    const target = rankOfLabel(rule.positionLabel);
    const stop = target == null ? -1 : chain.findIndex((id) => (rankOf(id) ?? -1) >= target);
    approverIds = stop >= 0 ? chain.slice(0, stop + 1) : [...chain];
  }
  for (const id of rule.extraApproverIds ?? []) {
    if (id !== authorId && !approverIds.includes(id)) approverIds.push(id);
  }
  const ccIds = (rule.ccIds ?? []).filter((id) => id !== authorId && !approverIds.includes(id));
  return { approverIds, ccIds };
}

/**
 * 문서의 금액(원) — 지출은 금액, 기안은 예산, 출장은 예상 경비, 구매는 품목 합계, 관리자가 만든 양식은 금액 칸·품목 칸의 합. 금액이 없는
 * 종류(휴가·근태·연장근무)나 비어 있으면 null.
 */
export function documentAmountOf(kind, payload) {
  const p = payload ?? {};
  if (kind === 'expense') return Number.isFinite(p.amount) ? p.amount : null;
  const values = p.values ?? {};
  if (kind === 'draft') return Number.isFinite(values.budget) ? values.budget : null;
  if (kind === 'trip') return Number.isFinite(values.cost) ? values.cost : null;
  if (kind === 'purchase') return Number.isFinite(values.items?.total) ? values.items.total : null;
  if (kind === 'form') {
    let sum = 0;
    let any = false;
    for (const f of Array.isArray(p.fields) ? p.fields : []) {
      const v = values[f.key];
      if (f.type === 'money' && Number.isFinite(v)) [sum, any] = [sum + v, true];
      if (f.type === 'items' && Number.isFinite(v?.total)) [sum, any] = [sum + v.total, true];
      // 표 칸 — 금액 열의 합계.
      if (f.type === 'table' && Array.isArray(v?.totals)) {
        for (const [j, c] of (Array.isArray(f.columns) ? f.columns : []).entries()) {
          if (c.type === 'money' && Number.isFinite(v.totals[j])) [sum, any] = [sum + v.totals[j], true];
        }
      }
    }
    return any ? sum : null;
  }
  return null;
}

/** 화면에 보낼 규칙 모양. */
export const lineRuleDto = (r, { templateName = null } = {}) => ({
  id: r.id,
  kind: r.kind,
  templateId: r.templateId ?? null,
  templateName,
  minAmount: r.minAmount ?? null,
  mode: r.mode,
  levels: r.levels ?? null,
  positionLabel: r.positionLabel ?? null,
  extraApproverIds: Array.isArray(r.extraApproverIds) ? r.extraApproverIds : [],
  ccIds: Array.isArray(r.ccIds) ? r.ccIds : [],
});
