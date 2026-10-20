/**
 * 내보내기 양식(급여 이체 파일·4대보험 취득/상실 신고 파일)의 순수 규칙 — 열 고르기·순서·머리 글·고정 값·날짜 모양·파일 종류. 은행 기업뱅킹의
 * 대량 이체 양식과 4대사회보험 정보연계센터(EDI)의 일괄 신고 엑셀은 곳마다·판마다 열이 달라, 담당자가 받은 양식의 열 순서대로 양식을 한 번
 * 만들어 두면 그 모양 그대로 내려준다(payrollReports.js). DB 없이 `node --test`로 시험한다(test/exportTemplates.test.js).
 *
 * 양식 `{ id, kind, name, header, dateFormat, rrnDash, fileType, columns: [{ field, header, value? }] }`:
 *  - kind: 'transfer'(급여 이체) | 'acquire'(자격 취득) | 'lose'(자격 상실).
 *  - header: 첫 줄에 머리 글을 넣는지(은행 양식 중에는 머리 줄 없이 둘째 줄부터 읽는 곳이 있다).
 *  - dateFormat: 'dash'(2026-03-02) | 'compact'(20260302) | 'dot'(2026.03.02). rrnDash: 주민등록번호에 '-'를 넣는지.
 *  - fileType: 'xlsx' | 'csv'(UTF-8 — 엑셀이 알아보게 BOM을 붙인다).
 *  - columns: field는 아래 FIELDS의 하나, 'fixed'면 [value]를 모든 줄에 그대로(예: 취득 부호 "1"), 'blank'는 빈 칸.
 * 담당자가 만든 양식은 급여 설정(payroll_settings.export_templates)에 범위마다 TEMPLATES_MAX개까지 둔다. 기본 양식(BUILTIN_TEMPLATES)은 고칠 수 없다.
 */

export const TEMPLATE_KINDS = Object.freeze(['transfer', 'acquire', 'lose']);
export const DATE_FORMATS = Object.freeze(['dash', 'compact', 'dot']);
export const FILE_TYPES = Object.freeze(['xlsx', 'csv']);
export const TEMPLATES_MAX = 30;
export const TEMPLATE_COLUMNS_MAX = 60;

/** 종류마다 고를 수 있는 칸(앱이 이름을 붙인다 — client models/groupware_finance_tools.dart exportFieldLabel). 금액 칸은 숫자로 쓴다. */
export const FIELDS = Object.freeze({
  transfer: ['bankCode', 'bankName', 'account', 'holder', 'amount', 'receiverText', 'senderText', 'name', 'employeeNo', 'fixed', 'blank'],
  acquire: [
    'name',
    'rrn',
    'employeeNo',
    'eventDate',
    'monthlyPay',
    'weeklyHours',
    'jobName',
    'jobCode',
    'pensionCode',
    'healthCode',
    'deadline',
    'memo',
    'fixed',
    'blank',
  ],
  lose: [
    'name',
    'rrn',
    'employeeNo',
    'eventDate',
    'lastWorkDay',
    'reasonCode',
    'reasonLabel',
    'yearPay',
    'yearMonths',
    'prevYearPay',
    'prevYearMonths',
    'pensionCode',
    'healthCode',
    'deadline',
    'memo',
    'fixed',
    'blank',
  ],
});
const AMOUNT_FIELDS = new Set(['amount', 'monthlyPay', 'yearPay', 'prevYearPay', 'weeklyHours', 'yearMonths', 'prevYearMonths']);
const DATE_FIELDS = new Set(['eventDate', 'lastWorkDay', 'deadline']);
/** 앞의 0이 지워지면 안 되는 칸(엑셀에서 글자로 둔다). */
const TEXT_FIELDS = new Set(['bankCode', 'account', 'rrn', 'employeeNo', 'reasonCode', 'jobCode', 'pensionCode', 'healthCode', 'fixed']);

const col = (field, header, value) => ({ field, header, ...(value !== undefined && { value }) });

/** 기본 양식 — 예전 내려받기와 같은 모양(모든 칸). 은행·EDI 양식은 담당자가 받은 파일의 열 순서대로 만든다. */
export const BUILTIN_TEMPLATES = Object.freeze([
  {
    id: 'builtin-transfer',
    kind: 'transfer',
    name: '기본(모든 칸)',
    builtin: true,
    header: true,
    dateFormat: 'dash',
    rrnDash: true,
    fileType: 'xlsx',
    columns: [
      col('bankCode', '은행코드'),
      col('bankName', '은행명'),
      col('account', '계좌번호'),
      col('holder', '예금주'),
      col('amount', '이체금액'),
      col('receiverText', '받는 분 통장 표시'),
      col('senderText', '내 통장 표시'),
      col('name', '이름'),
      col('employeeNo', '사번'),
    ],
  },
  {
    id: 'builtin-acquire',
    kind: 'acquire',
    name: '기본(모든 칸)',
    builtin: true,
    header: true,
    dateFormat: 'dash',
    rrnDash: true,
    fileType: 'xlsx',
    columns: [
      col('name', '성명'),
      col('employeeNo', '사번'),
      col('rrn', '주민등록번호'),
      col('eventDate', '취득일'),
      col('monthlyPay', '월 소득액(보수월액)'),
      col('weeklyHours', '주 소정근로시간'),
      col('jobName', '직종'),
      col('fixed', '국민연금', 'Y'),
      col('fixed', '건강보험', 'Y'),
      col('fixed', '고용보험', 'Y'),
      col('fixed', '산재보험', 'Y'),
      col('jobCode', '직종 부호'),
      col('pensionCode', '국민연금 취득 부호'),
      col('healthCode', '건강보험 취득 부호'),
      col('deadline', '신고 기한'),
      col('memo', '메모'),
    ],
  },
  {
    id: 'builtin-lose',
    kind: 'lose',
    name: '기본(모든 칸)',
    builtin: true,
    header: true,
    dateFormat: 'dash',
    rrnDash: true,
    fileType: 'xlsx',
    columns: [
      col('name', '성명'),
      col('employeeNo', '사번'),
      col('rrn', '주민등록번호'),
      col('eventDate', '상실일'),
      col('reasonCode', '상실 사유 코드'),
      col('reasonLabel', '상실 사유'),
      col('yearPay', '해당 연도 보수총액'),
      col('yearMonths', '해당 연도 근무 개월 수'),
      col('prevYearPay', '전년도 보수총액'),
      col('prevYearMonths', '전년도 근무 개월 수'),
      col('pensionCode', '국민연금 상실 부호'),
      col('healthCode', '건강보험 상실 부호'),
      col('deadline', '신고 기한'),
      col('memo', '메모'),
    ],
  },
]);

const cleanText = (v, max) =>
  typeof v === 'string' ? v.replace(/[\u0000-\u001f\u007f‪-‮⁦-⁩]/g, ' ').replace(/\s+/g, ' ').trim().slice(0, max + 1) : '';

/** 양식 하나 → `{ template }` | `{ error }`. [id]가 없으면 새로 붙인다. */
export function parseTemplate(input, { newId = () => Math.random().toString(36).slice(2, 10) } = {}) {
  if (!input || typeof input !== 'object' || Array.isArray(input)) return { error: '양식을 확인하세요.' };
  if (!TEMPLATE_KINDS.includes(input.kind)) return { error: '양식 종류(급여 이체·취득·상실)를 고르세요.' };
  const name = cleanText(input.name ?? '', 40);
  if (!name) return { error: '양식 이름을 넣으세요(예: "신한 기업뱅킹 대량이체").' };
  if ([...name].length > 40) return { error: '양식 이름은 40자까지입니다.' };
  const dateFormat = input.dateFormat ?? 'dash';
  if (!DATE_FORMATS.includes(dateFormat)) return { error: '날짜 모양을 고르세요.' };
  const fileType = input.fileType ?? 'xlsx';
  if (!FILE_TYPES.includes(fileType)) return { error: '파일 종류(엑셀·CSV)를 고르세요.' };
  const columns = Array.isArray(input.columns) ? input.columns : [];
  if (!columns.length) return { error: '열을 하나 이상 넣으세요.' };
  if (columns.length > TEMPLATE_COLUMNS_MAX) return { error: `열은 ${TEMPLATE_COLUMNS_MAX}개까지입니다.` };
  const out = [];
  for (const c of columns) {
    if (!FIELDS[input.kind].includes(c?.field)) return { error: '이 양식에 넣을 수 없는 칸이 있습니다.' };
    const header = cleanText(c.header ?? '', 40);
    if ([...header].length > 40) return { error: '열 머리 글은 40자까지입니다.' };
    const entry = { field: c.field, header };
    if (c.field === 'fixed') {
      const value = cleanText(String(c.value ?? ''), 60);
      if ([...value].length > 60) return { error: '고정 값은 60자까지입니다.' };
      entry.value = value;
    }
    out.push(entry);
  }
  const id = typeof input.id === 'string' && /^[a-z0-9]{4,16}$/.test(input.id) ? input.id : newId();
  return {
    template: { id, kind: input.kind, name, header: input.header !== false, dateFormat, rrnDash: input.rrnDash !== false, fileType, columns: out },
  };
}

/** 양식 목록 → `{ templates }` | `{ error }`(이름이 같은 양식은 종류마다 하나). */
export function parseTemplates(input, opts) {
  if (!Array.isArray(input)) return { error: '양식 목록을 확인하세요.' };
  if (input.length > TEMPLATES_MAX) return { error: `양식은 ${TEMPLATES_MAX}개까지입니다.` };
  const out = [];
  const seen = new Set();
  for (const raw of input) {
    const p = parseTemplate(raw, opts);
    if (p.error) return p;
    const key = `${p.template.kind}:${p.template.name}`;
    if (seen.has(key)) return { error: `"${p.template.name}" 양식이 둘 있습니다. 이름을 다르게 하세요.` };
    seen.add(key);
    if (out.some((t) => t.id === p.template.id)) p.template.id = `${p.template.id.slice(0, 12)}${out.length}`;
    out.push(p.template);
  }
  return { templates: out };
}

/** [kind]의 양식 [id] — 담당자 양식 [saved]에서, 없으면 기본 양식. 없는 id면 null. */
export function findTemplate(kind, id, saved = []) {
  const all = [...BUILTIN_TEMPLATES, ...(Array.isArray(saved) ? saved : [])].filter((t) => t.kind === kind);
  if (!id) return all[0] ?? null;
  return all.find((t) => t.id === id) ?? null;
}

/** 'YYYY-MM-DD' → 양식의 날짜 모양. */
export function formatDate(key, format) {
  if (typeof key !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(key)) return key ?? '';
  if (format === 'compact') return key.replace(/-/g, '');
  if (format === 'dot') return key.replace(/-/g, '.');
  return key;
}

/**
 * 주민등록번호(외국인등록번호) → 숫자 13자리 | null(형식이 아님). 앞 6자리가 날짜 모양(월 01~12, 일 01~31)이고 뒤 첫 자리가 0~9.
 * 서버에 두지 않는다 — 내보내기 요청에만 오고 파일에 쓰고 버린다.
 */
export function normalizeRrn(value) {
  const d = String(value ?? '').replace(/[\s-]/g, '');
  if (!/^\d{13}$/.test(d)) return null;
  const m = Number(d.slice(2, 4));
  const day = Number(d.slice(4, 6));
  return m >= 1 && m <= 12 && day >= 1 && day <= 31 ? d : null;
}

/** 하루 전 'YYYY-MM-DD'(상실일 → 마지막 근무일). */
const dayBefore = (key) => new Date(Date.parse(`${key}T00:00:00Z`) - 86_400_000).toISOString().slice(0, 10);

/**
 * 양식대로 표를 만든다 — [records]는 칸 이름 → 값(transfer: bankCode·bankName·account·holder·amount·receiverText·senderText·name·employeeNo /
 * 신고: name·rrn·employeeNo·eventDate·reasonCode·reasonLabel·monthlyPay·…). `{ header: [..] | null, rows: [[..]], numeric: [열 번호(0부터)],
 * text: [열 번호] }`.
 */
export function renderTemplate(template, records) {
  const header = template.header === false ? null : template.columns.map((c) => c.header);
  const value = (c, r) => {
    if (c.field === 'fixed') return c.value ?? '';
    if (c.field === 'blank') return '';
    if (c.field === 'lastWorkDay') return r.eventDate ? formatDate(dayBefore(r.eventDate), template.dateFormat) : '';
    const v = r[c.field];
    if (v === undefined || v === null) return '';
    if (DATE_FIELDS.has(c.field)) return formatDate(v, template.dateFormat);
    if (c.field === 'rrn') return template.rrnDash === false ? v : `${v.slice(0, 6)}-${v.slice(6)}`;
    return v;
  };
  const rows = records.map((r) => template.columns.map((c) => value(c, r)));
  const numeric = [];
  const text = [];
  template.columns.forEach((c, i) => {
    if (AMOUNT_FIELDS.has(c.field)) numeric.push(i);
    if (TEXT_FIELDS.has(c.field)) text.push(i);
  });
  return { header, rows, numeric, text };
}

/** CSV 한 줄 — 쉼표·따옴표·줄바꿈이 있으면 따옴표로 싼다. */
const csvCell = (v) => {
  const s = String(v ?? '');
  return /[",\r\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
};

/** 표 → CSV 글(UTF-8 BOM, CRLF). */
export function toCsv({ header, rows }) {
  const lines = [...(header ? [header] : []), ...rows].map((r) => r.map(csvCell).join(','));
  return `﻿${lines.join('\r\n')}\r\n`;
}
