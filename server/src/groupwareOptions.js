import { LEAVE_TYPES } from './annualLeave.js';

/**
 * 그룹웨어 범위마다의 설정 — 휴가 종류와 지출 분류(관리자가 바꾼다), 출근·퇴근 알림. DB 없이 시험할 수 있게 규칙만 모았다
 * (groupwareWork.js가 읽고 쓴다, test/groupwareWork.test.js).
 *
 * 휴가 종류: 기본 종류(annualLeave.js LEAVE_TYPES — 연차·반차·병가·경조사·공가·기타)는 이름을 바꾸고 끌 수 있고(연차는 끌 수 없다),
 * 관리자가 종류를 더할 수 있다(하루 단위 — 연차에서 뺄지 고른다). 지운 종류도 목록에 꺼진 채 남겨 예전 신청의 이름이 그대로 보이게 한다.
 * 신청할 때 그 종류의 이름·연차 차감 여부를 휴가 문서에 같이 적어 둔다(groupware.js — 나중에 바뀌어도 그 신청은 그대로).
 */

export const DEFAULT_EXPENSE_CATEGORIES = Object.freeze(['교통비', '식대', '비품·소모품', '출장비', '교육비', '접대비', '기타']);
export const LEAVE_TYPE_LABEL_MAX = 20;
export const CUSTOM_LEAVE_TYPES_MAX = 20;
export const EXPENSE_CATEGORY_MAX = 20;
export const EXPENSE_CATEGORIES_MAX = 30;
/** 출근 알림을 근무 시작 몇 분 뒤에 — 0~120분. */
export const REMINDER_DELAY_MAX = 120;

const clean = (v) => (typeof v === 'string' ? v.replace(/[\u0000-\u001f\u007f]/g, '').replace(/\s+/g, ' ').trim() : '');

/**
 * 저장해 둔 값([stored] — 없으면 null)으로 이 범위의 휴가 종류 전부 — `[{ key, label, deducts, half, enabled, builtin }]`. 기본 종류가
 * 먼저(정해진 순서), 관리자가 더한 종류가 뒤에.
 */
export function mergeLeaveTypes(stored) {
  const rows = Array.isArray(stored) ? stored : [];
  const overrides = new Map(rows.filter((r) => r && !r.custom).map((r) => [r.key, r]));
  const builtins = LEAVE_TYPES.map((t) => {
    const o = overrides.get(t.key);
    return {
      key: t.key,
      label: clean(o?.label) || t.label,
      deducts: t.deducts,
      half: t.half,
      enabled: t.key === 'annual' ? true : o?.enabled !== false,
      builtin: true,
    };
  });
  const customs = rows
    .filter((r) => r?.custom && typeof r.key === 'string' && /^c_[a-z0-9]{1,16}$/.test(r.key))
    .map((r) => ({ key: r.key, label: clean(r.label) || '휴가', deducts: r.deducts === true, half: false, enabled: r.enabled !== false, builtin: false }));
  return [...builtins, ...customs];
}

/** 쓸 수 있는(켜진) 휴가 종류에서 [key] — 꺼졌거나 없으면 null. */
export const enabledLeaveType = (types, key) => types.find((t) => t.key === key && t.enabled) ?? null;

/**
 * 관리자가 보낸 휴가 종류 목록 `[{ key?, label, enabled?, deducts? }]` 검사 → 저장할 모양 `{ stored }` | `{ error }`. 기본 종류는 key로
 * 알아보고(이름·켜고 끄기만), key가 없거나 'c_'로 시작하면 관리자가 더한 종류(새것이면 key를 [newKey]로 만든다). 이전에 있던 종류가
 * 빠져 있으면 꺼진 채 남긴다([previous] — 예전 신청의 이름을 지키려고).
 */
export function parseLeaveTypesInput(input, { previous = null, newKey = () => `c_${Math.random().toString(36).slice(2, 10)}` } = {}) {
  if (!Array.isArray(input)) return { error: '휴가 종류 목록을 보내세요.' };
  const before = mergeLeaveTypes(previous);
  const builtinKeys = new Set(LEAVE_TYPES.map((t) => t.key));
  const stored = [];
  const seenKeys = new Set();
  const labels = new Set();
  let customs = 0;
  for (const item of input) {
    const label = clean(item?.label);
    if (!label) return { error: '휴가 종류 이름을 넣으세요.' };
    if ([...label].length > LEAVE_TYPE_LABEL_MAX) return { error: `휴가 종류 이름은 ${LEAVE_TYPE_LABEL_MAX}자 이내로 넣으세요.` };
    const key = typeof item?.key === 'string' && item.key ? item.key : null;
    const enabled = item?.enabled !== false;
    if (key && builtinKeys.has(key)) {
      if (key === 'annual' && !enabled) return { error: '연차는 끌 수 없습니다.' };
      if (seenKeys.has(key)) return { error: '같은 종류가 두 번 있습니다.' };
      seenKeys.add(key);
      if (enabled) {
        if (labels.has(label)) return { error: `같은 이름의 휴가 종류가 있습니다: ${label}` };
        labels.add(label);
      }
      stored.push({ key, label, enabled });
      continue;
    }
    const customKey = key && /^c_[a-z0-9]{1,16}$/.test(key) ? key : newKey();
    if (seenKeys.has(customKey)) return { error: '같은 종류가 두 번 있습니다.' };
    seenKeys.add(customKey);
    if (enabled) {
      if (labels.has(label)) return { error: `같은 이름의 휴가 종류가 있습니다: ${label}` };
      labels.add(label);
    }
    customs += 1;
    if (customs > CUSTOM_LEAVE_TYPES_MAX) return { error: `휴가 종류는 ${CUSTOM_LEAVE_TYPES_MAX}개까지 더할 수 있습니다.` };
    stored.push({ key: customKey, label, enabled, deducts: item?.deducts === true, custom: true });
  }
  // 빠진 종류는 꺼진 채 남긴다.
  for (const t of before) {
    if (seenKeys.has(t.key)) continue;
    if (t.key === 'annual') return { error: '연차는 지울 수 없습니다.' };
    stored.push(t.builtin ? { key: t.key, label: t.label, enabled: false } : { key: t.key, label: t.label, enabled: false, deducts: t.deducts, custom: true });
  }
  return { stored };
}

/** 저장해 둔 지출 분류(없으면 기본). */
export const expenseCategoriesOf = (stored) =>
  Array.isArray(stored) && stored.length > 0 ? stored.filter((c) => typeof c === 'string' && c) : [...DEFAULT_EXPENSE_CATEGORIES];

/** 지출 분류 목록 검사 — 1~30개, 각 1~20자, 같은 이름 없이. `{ categories }` | `{ error }`. */
export function parseExpenseCategories(input) {
  if (!Array.isArray(input)) return { error: '지출 분류 목록을 보내세요.' };
  const categories = [];
  for (const raw of input) {
    const c = clean(raw);
    if (!c) continue;
    if ([...c].length > EXPENSE_CATEGORY_MAX) return { error: `지출 분류는 ${EXPENSE_CATEGORY_MAX}자 이내로 넣으세요.` };
    if (categories.includes(c)) return { error: `같은 지출 분류가 있습니다: ${c}` };
    categories.push(c);
  }
  if (categories.length === 0) return { error: '지출 분류를 하나 이상 넣으세요.' };
  if (categories.length > EXPENSE_CATEGORIES_MAX) return { error: `지출 분류는 ${EXPENSE_CATEGORIES_MAX}개까지입니다.` };
  return { categories };
}

/** 이 범위의 설정 모양(앱·관리 탭) — [row]는 groupware_options 줄(없으면 null). */
export function optionsView(row) {
  return {
    leaveTypes: mergeLeaveTypes(row?.leaveTypes ?? null),
    expenseCategories: expenseCategoriesOf(row?.expenseCategories ?? null),
    clockInReminder: !!row?.clockInReminder,
    clockOutReminder: !!row?.clockOutReminder,
    reminderDelayMinutes: row?.reminderDelayMinutes ?? 10,
  };
}
