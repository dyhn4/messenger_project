import { addDaysKey, isDateKey } from './annualLeave.js';
import { parseHm } from './attendanceRules.js';

/**
 * 결재 양식의 **순수 규칙** — 칸 종류와 값 검사, 코드에 정해 둔 기본 양식(일반 기안서·출장 신청·구매 요청·연장근무 신청), 관리자가 만드는
 * 양식의 칸 정의 검사, 올릴 때 문서에 적을 내용(payload) 만들기. DB는 groupware.js·db/queries/groupware.js. `node --test`로 시험한다
 * (test/approvalForms.test.js).
 *
 * 양식으로 올린 문서의 payload는 `{ templateId, templateName, fields(그때의 칸 정의), values(칸 key → 값), …종류별로 뽑아 둔 값 }`이다 —
 * 칸 정의를 같이 적어 두므로 양식을 고치거나 지워도 이미 올린 문서는 그대로 보인다. 출장(startDate·endDate)·연장근무(workDate·minutes)는
 * 근태가 읽는 값을 따로 뽑아 둔다(groupware.js 월 근태).
 */

export const FORM_FIELD_TYPES = Object.freeze(['text', 'textarea', 'number', 'money', 'date', 'dateRange', 'timeRange', 'select', 'items']);
export const FORM_FIELD_TYPE_LABEL = Object.freeze({
  text: '한 줄 글',
  textarea: '여러 줄 글',
  number: '숫자',
  money: '금액(원)',
  date: '날짜',
  dateRange: '기간',
  timeRange: '시간대',
  select: '고르기',
  items: '품목 표',
});
export const FORM_NAME_MAX = 30;
export const FORM_DESCRIPTION_MAX = 200;
export const FORM_FIELDS_MAX = 20;
export const FORM_FIELD_LABEL_MAX = 30;
export const FORM_OPTIONS_MAX = 20;
export const FORM_OPTION_MAX = 30;
export const FORM_TEXT_MAX = 200;
export const FORM_TEXTAREA_MAX = 2000;
export const FORM_ITEMS_MAX = 50;
export const FORM_ITEM_NAME_MAX = 100;
/** 한 범위에 관리자가 만들 수 있는 양식 수. */
export const CUSTOM_FORMS_MAX = 50;
export const MONEY_MAX = 10_000_000_000;
export const NUMBER_MAX = 1_000_000_000_000;
export const DATE_RANGE_MAX_DAYS = 366;
/** 연장근무는 지난 30일 ~ 앞으로 60일 안의 날만(미리 받는 게 원칙, 늦게 올리는 것도 한 달까지). */
export const OVERTIME_PAST_DAYS = 30;
export const OVERTIME_FUTURE_DAYS = 60;

export const TRANSPORT_OPTIONS = Object.freeze(['대중교통', '자가용', '법인 차량', '항공', '기타']);
export const OVERTIME_TYPES = Object.freeze(['연장근무', '야간근무', '휴일근무']);

/** 코드에 정해 둔 기본 양식 — 종류(kind) → 정의. 관리자가 범위마다 켜고 끈다(approval_templates의 builtin_key 줄). */
export const BUILTIN_FORMS = Object.freeze({
  draft: {
    name: '일반 기안서',
    description: '품의·보고·협조 요청처럼 정해진 양식이 없는 결재(품의서).',
    allowAttachments: true,
    fields: [
      { key: 'content', label: '기안 내용', type: 'textarea', required: true },
      { key: 'budget', label: '예산(원)', type: 'money', required: false },
      { key: 'effectiveDate', label: '시행일', type: 'date', required: false },
    ],
  },
  trip: {
    name: '출장 신청',
    description: '승인되면 출장 기간은 근태에서 결근으로 세지 않습니다.',
    allowAttachments: true,
    fields: [
      { key: 'destination', label: '출장지', type: 'text', required: true },
      { key: 'period', label: '출장 기간', type: 'dateRange', required: true },
      { key: 'purpose', label: '출장 목적', type: 'textarea', required: true },
      { key: 'companions', label: '동행자', type: 'text', required: false },
      { key: 'transport', label: '교통편', type: 'select', required: false, options: [...TRANSPORT_OPTIONS] },
      { key: 'cost', label: '예상 경비(원)', type: 'money', required: false },
    ],
  },
  purchase: {
    name: '구매 요청',
    description: '물품·서비스 구매. 품목마다 수량·단가를 넣으면 합계를 계산합니다.',
    allowAttachments: true,
    fields: [
      { key: 'items', label: '구매 품목', type: 'items', required: true },
      { key: 'reason', label: '구매 사유', type: 'textarea', required: true },
      { key: 'vendor', label: '구매처', type: 'text', required: false },
      { key: 'neededBy', label: '납품 희망일', type: 'date', required: false },
    ],
  },
  overtime: {
    name: '연장근무 신청',
    description: '연장·야간·휴일근무를 미리(늦어도 한 달 안에) 신청합니다. 승인된 시간은 월 근태에 합쳐 보입니다.',
    allowAttachments: false,
    fields: [
      { key: 'workDate', label: '근무일', type: 'date', required: true },
      { key: 'time', label: '근무 시간', type: 'timeRange', required: true },
      { key: 'overtimeType', label: '종류', type: 'select', required: true, options: [...OVERTIME_TYPES] },
      { key: 'reason', label: '사유', type: 'textarea', required: true },
    ],
  },
});
export const BUILTIN_FORM_KINDS = Object.freeze(Object.keys(BUILTIN_FORMS));
/** 양식으로 올리는 결재 종류 — 기본 양식들 + 관리자가 만든 양식('form'). */
export const FORM_KINDS = Object.freeze([...BUILTIN_FORM_KINDS, 'form']);

const clean = (v) => (typeof v === 'string' ? v.replace(/[\u0000-\u0008\u000b-\u001f\u007f]/g, '').trim() : '');
const toInt = (v) => {
  const n = typeof v === 'string' ? Number(v.replace(/,/g, '').trim()) : Number(v);
  return Number.isInteger(n) ? n : NaN;
};
const daysBetween = (start, end) => Math.round((Date.parse(`${end}T00:00:00Z`) - Date.parse(`${start}T00:00:00Z`)) / 86_400_000);

/** 칸 하나의 값 → `{ value }`(비었으면 null) | `{ error }`. */
export function parseFieldValue(field, raw) {
  const label = field.label;
  const blank = (v) => v === undefined || v === null || (typeof v === 'string' && v.trim() === '');
  const isRange = field.type === 'dateRange' || field.type === 'timeRange';
  const empty = blank(raw) || (isRange && typeof raw === 'object' && blank(raw.start) && blank(raw.end));
  if (empty) return field.required ? { error: `"${label}"을(를) 넣으세요.` } : { value: null };
  switch (field.type) {
    case 'text':
    case 'textarea': {
      const max = field.type === 'text' ? FORM_TEXT_MAX : FORM_TEXTAREA_MAX;
      const text = field.type === 'text' ? clean(raw).replace(/\s+/g, ' ') : clean(raw);
      if (!text) return field.required ? { error: `"${label}"을(를) 넣으세요.` } : { value: null };
      if ([...text].length > max) return { error: `"${label}"은(는) ${max}자 이내로 넣으세요.` };
      return { value: text };
    }
    case 'number': {
      const n = typeof raw === 'string' ? Number(raw.replace(/,/g, '').trim()) : Number(raw);
      if (!Number.isFinite(n) || Math.abs(n) > NUMBER_MAX) return { error: `"${label}"에 숫자를 넣으세요.` };
      return { value: Math.round(n * 100) / 100 };
    }
    case 'money': {
      const n = toInt(raw);
      if (!Number.isInteger(n) || n < 0) return { error: `"${label}"을(를) 원 단위 숫자로 넣으세요.` };
      if (n > MONEY_MAX) return { error: `"${label}"이(가) 너무 큽니다.` };
      return { value: n };
    }
    case 'date':
      return isDateKey(raw) ? { value: raw } : { error: `"${label}" 날짜를 확인하세요.` };
    case 'dateRange': {
      const start = raw?.start;
      const end = raw?.end ?? start;
      if (!isDateKey(start) || !isDateKey(end)) return { error: `"${label}" 날짜를 확인하세요.` };
      if (end < start) return { error: `"${label}"의 끝 날짜가 시작보다 빠릅니다.` };
      if (daysBetween(start, end) + 1 > DATE_RANGE_MAX_DAYS) return { error: `"${label}"은(는) ${DATE_RANGE_MAX_DAYS}일 안으로 고르세요.` };
      return { value: { start, end } };
    }
    case 'timeRange': {
      const start = parseHm(raw?.start);
      const end = parseHm(raw?.end);
      if (start === null || end === null) return { error: `"${label}"을(를) HH:MM으로 넣으세요.` };
      if (start === end) return { error: `"${label}"의 시작과 끝이 같습니다.` };
      // 끝이 시작보다 이르면 다음 날로 넘어간 시간(예: 22:00~02:00).
      const minutes = end > start ? end - start : end + 1440 - start;
      return { value: { start: raw.start, end: raw.end, minutes, overnight: end < start } };
    }
    case 'select':
      return Array.isArray(field.options) && field.options.includes(raw) ? { value: raw } : { error: `"${label}"에서 하나를 고르세요.` };
    case 'items': {
      const list = Array.isArray(raw) ? raw : Array.isArray(raw?.rows) ? raw.rows : null;
      if (!list) return { error: `"${label}"이(가) 올바르지 않습니다.` };
      const rows = [];
      for (const [i, r] of list.entries()) {
        const name = clean(r?.name).replace(/\s+/g, ' ');
        if (!name && (r?.qty === undefined || r?.qty === '' || r?.qty === null)) continue; // 빈 줄은 건너뜀
        if (!name) return { error: `"${label}" ${i + 1}번째 줄의 품명을 넣으세요.` };
        if ([...name].length > FORM_ITEM_NAME_MAX) return { error: `품명은 ${FORM_ITEM_NAME_MAX}자 이내로 넣으세요.` };
        const qty = toInt(r?.qty);
        if (!Number.isInteger(qty) || qty <= 0 || qty > 1_000_000) return { error: `"${name}"의 수량을 1 이상 정수로 넣으세요.` };
        const unitPrice = toInt(r?.unitPrice);
        if (!Number.isInteger(unitPrice) || unitPrice < 0) return { error: `"${name}"의 단가를 원 단위 숫자로 넣으세요.` };
        const amount = qty * unitPrice;
        if (amount > MONEY_MAX) return { error: `"${name}"의 금액이 너무 큽니다.` };
        rows.push({ name, qty, unitPrice, amount });
      }
      if (rows.length === 0) return field.required ? { error: `"${label}"에 품목을 하나 이상 넣으세요.` } : { value: null };
      if (rows.length > FORM_ITEMS_MAX) return { error: `품목은 ${FORM_ITEMS_MAX}줄까지 넣을 수 있습니다.` };
      const total = rows.reduce((s, r) => s + r.amount, 0);
      if (total > MONEY_MAX) return { error: '합계가 너무 큽니다.' };
      return { value: { rows, total } };
    }
    default:
      return { error: `알 수 없는 칸 종류입니다: ${field.type}` };
  }
}

/** 칸 정의 목록대로 값들을 검사 → `{ values }`(key → 값, 빈 칸은 null) | `{ error }`. */
export function parseFormValues(fields, input) {
  const values = {};
  const raw = input && typeof input === 'object' && !Array.isArray(input) ? input : {};
  for (const field of fields) {
    const parsed = parseFieldValue(field, raw[field.key]);
    if (parsed.error) return { error: parsed.error };
    values[field.key] = parsed.value;
  }
  return { values };
}

/**
 * 관리자가 만드는 양식 정의 `{ name, description?, fields: [{ label, type, required?, options? }], allowAttachments? }` 검사 →
 * `{ form: { name, description, fields(key는 f1, f2 … 로 새로 매김), allowAttachments } }` | `{ error }`.
 */
export function parseFormDefinition(input) {
  const name = clean(input?.name).replace(/\s+/g, ' ');
  if (!name) return { error: '양식 이름을 넣으세요.' };
  if ([...name].length > FORM_NAME_MAX) return { error: `양식 이름은 ${FORM_NAME_MAX}자 이내로 넣으세요.` };
  const description = clean(input?.description) || null;
  if (description && [...description].length > FORM_DESCRIPTION_MAX) return { error: `설명은 ${FORM_DESCRIPTION_MAX}자 이내로 넣으세요.` };
  const list = Array.isArray(input?.fields) ? input.fields : null;
  if (!list || list.length === 0) return { error: '칸을 하나 이상 만드세요.' };
  if (list.length > FORM_FIELDS_MAX) return { error: `칸은 ${FORM_FIELDS_MAX}개까지 만들 수 있습니다.` };
  const fields = [];
  const labels = new Set();
  for (const [i, f] of list.entries()) {
    const label = clean(f?.label).replace(/\s+/g, ' ');
    if (!label) return { error: `${i + 1}번째 칸의 이름을 넣으세요.` };
    if ([...label].length > FORM_FIELD_LABEL_MAX) return { error: `칸 이름은 ${FORM_FIELD_LABEL_MAX}자 이내로 넣으세요.` };
    if (labels.has(label)) return { error: `같은 이름의 칸이 두 개 있습니다: ${label}` };
    labels.add(label);
    if (!FORM_FIELD_TYPES.includes(f?.type)) return { error: `"${label}" 칸의 종류를 고르세요.` };
    const field = { key: `f${i + 1}`, label, type: f.type, required: f?.required === true };
    if (f.type === 'select') {
      const options = [...new Set((Array.isArray(f.options) ? f.options : []).map((o) => clean(o).replace(/\s+/g, ' ')).filter(Boolean))];
      if (options.length < 2) return { error: `"${label}"의 고를 거리를 둘 이상 넣으세요.` };
      if (options.length > FORM_OPTIONS_MAX) return { error: `고를 거리는 ${FORM_OPTIONS_MAX}개까지입니다.` };
      if (options.some((o) => [...o].length > FORM_OPTION_MAX)) return { error: `고를 거리는 ${FORM_OPTION_MAX}자 이내로 넣으세요.` };
      field.options = options;
    }
    fields.push(field);
  }
  return { form: { name, description, fields, allowAttachments: input?.allowAttachments === true } };
}

/** 문서에 적어 둘 칸 정의(필요한 것만). */
const snapshotFields = (fields) =>
  fields.map((f) => ({ key: f.key, label: f.label, type: f.type, ...(f.options ? { options: [...f.options] } : {}) }));

/**
 * 양식으로 올리는 결재의 payload — [kind]는 기본 양식 종류 또는 'form', [template]은 `{ id?, name, fields }`. 종류별로 근태·목록이
 * 쓸 값을 뽑아 두고 규칙을 더 본다(연장근무 날짜 범위). `{ payload }` | `{ error }`.
 */
export function buildFormPayload({ kind, template, values: input, today }) {
  const parsed = parseFormValues(template.fields, input);
  if (parsed.error) return parsed;
  const values = parsed.values;
  const payload = {
    templateId: template.id ?? null,
    templateName: template.name,
    fields: snapshotFields(template.fields),
    values,
  };
  if (kind === 'trip') {
    payload.destination = values.destination;
    payload.startDate = values.period.start;
    payload.endDate = values.period.end;
    payload.days = daysBetween(values.period.start, values.period.end) + 1;
  } else if (kind === 'purchase') {
    payload.total = values.items.total;
    payload.itemCount = values.items.rows.length;
  } else if (kind === 'overtime') {
    if (values.workDate < addDaysKey(today, -OVERTIME_PAST_DAYS)) return { error: `연장근무는 지난 ${OVERTIME_PAST_DAYS}일 안의 날만 신청할 수 있습니다.` };
    if (values.workDate > addDaysKey(today, OVERTIME_FUTURE_DAYS)) return { error: `연장근무는 앞으로 ${OVERTIME_FUTURE_DAYS}일 안의 날만 신청할 수 있습니다.` };
    payload.workDate = values.workDate;
    payload.startTime = values.time.start;
    payload.endTime = values.time.end;
    payload.minutes = values.time.minutes;
    payload.overtimeType = values.overtimeType;
  }
  return { payload };
}

const shortDate = (key) => `${Number(key.slice(5, 7))}/${Number(key.slice(8, 10))}`;
const clip = (text, max) => ([...text].length > max ? `${[...text].slice(0, max).join('')}…` : text);
const firstLine = (text) => String(text ?? '').split('\n')[0].trim();

/** 양식 결재의 제목을 비워 두면 쓸 이름. */
export function defaultFormTitle(kind, payload) {
  switch (kind) {
    case 'draft':
      return `기안 — ${clip(firstLine(payload.values?.content) || '내용 없음', 40)}`;
    case 'trip': {
      const range = payload.startDate === payload.endDate ? shortDate(payload.startDate) : `${shortDate(payload.startDate)}~${shortDate(payload.endDate)}`;
      return `출장 신청 — ${clip(payload.destination ?? '', 30)} (${range})`;
    }
    case 'purchase': {
      const rows = payload.values?.items?.rows ?? [];
      const head = rows[0]?.name ?? '품목';
      return `구매 요청 — ${clip(head, 30)}${rows.length > 1 ? ` 외 ${rows.length - 1}건` : ''} (${(payload.total ?? 0).toLocaleString('ko-KR')}원)`;
    }
    case 'overtime':
      return `${payload.overtimeType} 신청 (${shortDate(payload.workDate)} ${payload.startTime}~${payload.endTime})`;
    default:
      return payload.templateName ?? '결재';
  }
}

/**
 * 범위의 양식 목록 — 기본 양식(코드)에 이 범위의 켜고 끈 기록([rows] 중 builtin_key 줄)을 입히고, 관리자가 만든 양식을 붙인다.
 * `[{ id, kind, builtin, name, description, fields, allowAttachments, enabled, sortOrder }]` — 기본 양식의 id는 'builtin:종류'. 순서는
 * sortOrder, 같으면 기본 양식 먼저.
 */
export function mergeForms(rows) {
  const overrides = new Map(rows.filter((r) => r.builtinKey).map((r) => [r.builtinKey, r]));
  const builtins = BUILTIN_FORM_KINDS.map((kind, i) => {
    const def = BUILTIN_FORMS[kind];
    const o = overrides.get(kind);
    return {
      id: `builtin:${kind}`,
      kind,
      builtin: true,
      name: def.name,
      description: def.description,
      fields: def.fields,
      allowAttachments: def.allowAttachments,
      enabled: o ? o.enabled : true,
      sortOrder: o ? o.sortOrder : i,
    };
  });
  const custom = rows
    .filter((r) => !r.builtinKey)
    .map((r) => ({
      id: r.id,
      kind: 'form',
      builtin: false,
      name: r.name,
      description: r.description ?? null,
      fields: r.fields,
      allowAttachments: !!r.allowAttachments,
      enabled: !!r.enabled,
      sortOrder: r.sortOrder ?? 100,
    }));
  return [...builtins, ...custom].sort((a, b) => a.sortOrder - b.sortOrder || Number(b.builtin) - Number(a.builtin));
}

/** 양식 id → 기본 양식 종류(아니면 null). */
export const builtinKindOfId = (id) => (typeof id === 'string' && id.startsWith('builtin:') && BUILTIN_FORMS[id.slice(8)] ? id.slice(8) : null);
