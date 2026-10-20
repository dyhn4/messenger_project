/**
 * 급여 부가 기능(payrollReports.js)의 순수 규칙 — 급여 이체 파일(은행 대량 이체), 4대보험 취득·상실 신고 자료, 한 해 급여 집계(연말정산 자료).
 * DB 없이 `node --test`로 시험한다(test/payrollReports.test.js).
 */
import { payslipTotals } from './payrollRules.js';

const cleanText = (v, max) =>
  typeof v === 'string' ? v.replace(/[\u0000-\u001f\u007f‪-‮⁦-⁩]/g, ' ').replace(/\s+/g, ' ').trim().slice(0, max) : '';
const isDateKey = (v) => typeof v === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(v) && !Number.isNaN(Date.parse(`${v}T00:00:00Z`));

// ── 급여 계좌·이체 파일 ──

/**
 * 은행(금융결제원 3자리 표준 코드) — 기업뱅킹 대량 이체 파일의 "은행코드" 열. [aliases]는 엑셀 가져오기·입력에서 알아볼 다른 이름.
 */
export const BANKS = Object.freeze([
  { code: '002', name: 'KDB산업은행', aliases: ['산업'] },
  { code: '003', name: 'IBK기업은행', aliases: ['기업'] },
  { code: '004', name: 'KB국민은행', aliases: ['국민'] },
  { code: '007', name: '수협은행', aliases: ['수협'] },
  { code: '011', name: 'NH농협은행', aliases: ['농협'] },
  { code: '012', name: '지역농·축협', aliases: ['단위농협', '축협'] },
  { code: '020', name: '우리은행', aliases: ['우리'] },
  { code: '023', name: 'SC제일은행', aliases: ['제일', 'SC'] },
  { code: '027', name: '한국씨티은행', aliases: ['씨티'] },
  { code: '031', name: 'iM뱅크(대구)', aliases: ['대구', 'iM'] },
  { code: '032', name: '부산은행', aliases: ['부산'] },
  { code: '034', name: '광주은행', aliases: ['광주'] },
  { code: '035', name: '제주은행', aliases: ['제주'] },
  { code: '037', name: '전북은행', aliases: ['전북'] },
  { code: '039', name: '경남은행', aliases: ['경남'] },
  { code: '045', name: '새마을금고', aliases: ['새마을'] },
  { code: '048', name: '신협', aliases: ['신용협동조합'] },
  { code: '050', name: '저축은행', aliases: ['상호저축'] },
  { code: '071', name: '우체국', aliases: ['우정사업본부'] },
  { code: '081', name: '하나은행', aliases: ['하나', 'KEB하나'] },
  { code: '088', name: '신한은행', aliases: ['신한'] },
  { code: '089', name: '케이뱅크', aliases: ['K뱅크'] },
  { code: '090', name: '카카오뱅크', aliases: ['카카오'] },
  { code: '092', name: '토스뱅크', aliases: ['토스'] },
]);

/** 은행 코드·이름 → 은행 | null. */
export function bankOf(value) {
  const v = String(value ?? '').replace(/\s/g, '');
  if (!v) return null;
  const code = /^\d{1,3}$/.test(v) ? v.padStart(3, '0') : null;
  if (code) return BANKS.find((b) => b.code === code) ?? null;
  const short = v.replace(/은행$/, '');
  return (
    BANKS.find((b) => b.name.replace(/\s/g, '') === v) ??
    BANKS.find((b) => b.aliases.some((n) => n === short || n === v)) ??
    (short.length >= 2 ? BANKS.find((b) => [b.name, ...b.aliases].some((n) => v.includes(n.replace(/\s/g, '')) || n.replace(/\s/g, '').includes(short))) : null) ??
    null
  );
}

/** 급여 계좌 `{ bank, number, holder? }` → `{ account: { bankCode, number, holder } }` | `{ account: null }`(비움) | `{ error }`. */
export function parseBankAccount(input) {
  if (input === null || input === undefined || (typeof input === 'object' && !input.bank && !input.number)) return { account: null };
  if (typeof input !== 'object') return { error: '급여 계좌를 확인하세요.' };
  const bank = bankOf(input.bank);
  if (!bank) return { error: '은행을 고르세요.' };
  const number = String(input.number ?? '').replace(/[\s-]/g, '');
  if (!/^\d{8,16}$/.test(number)) return { error: '계좌번호는 숫자 8~16자리입니다(- 없이).' };
  const holder = cleanText(input.holder ?? '', 31);
  if ([...holder].length > 30) return { error: '예금주는 30자까지입니다.' };
  return { account: { bankCode: bank.code, number, ...(holder && { holder }) } };
}

/** 급여 계좌 표 `{ userId: account }` → 저장할 값 | `{ error }` — [current]에 덮는다(null은 지운다). */
export function parseBankAccounts(input, current = {}) {
  if (input === undefined) return { bankAccounts: undefined };
  if (!input || typeof input !== 'object' || Array.isArray(input)) return { error: '급여 계좌를 확인하세요.' };
  const out = { ...(current ?? {}) };
  for (const [userId, raw] of Object.entries(input)) {
    const parsed = parseBankAccount(raw);
    if (parsed.error) return { error: parsed.error };
    if (parsed.account) out[userId] = parsed.account;
    else delete out[userId];
  }
  return { bankAccounts: out };
}

/**
 * 급여 이체 줄 — [slips]는 `[{ userId, userName, employeeNo, net }]`, [accounts]는 `{ userId: account }`. 실수령액이 0원 이하인 사람·계좌가 없는
 * 사람은 [missing]으로. [senderText]는 받는 분 통장에 보일 글(회사 이름 — 7자 안팎이 흔한 한도라 10자에서 자른다).
 * `{ records: [{ bankCode, bankName, account, holder, amount, receiverText, senderText, name, employeeNo }], total, missing: [{ userName, reason }] }`
 * — 줄 모양(열 순서)은 내보내기 양식(exportTemplateRules.js renderTemplate)이 정한다.
 */
export function transferRecords(slips, accounts, { senderText = '급여', myText = '급여' } = {}) {
  const records = [];
  const missing = [];
  let total = 0;
  for (const s of slips) {
    const account = accounts?.[s.userId];
    if (s.net <= 0) {
      missing.push({ userName: s.userName, reason: '실수령액이 0원 이하' });
      continue;
    }
    if (!account) {
      missing.push({ userName: s.userName, reason: '급여 계좌 없음' });
      continue;
    }
    const bank = BANKS.find((b) => b.code === account.bankCode);
    total += s.net;
    records.push({
      bankCode: account.bankCode,
      bankName: bank?.name ?? '',
      account: account.number,
      holder: account.holder || s.userName,
      amount: s.net,
      receiverText: senderText.slice(0, 10),
      senderText: `${myText} ${s.userName}`.slice(0, 10),
      name: s.userName,
      employeeNo: s.employeeNo ?? '',
    });
  }
  return { records, total, missing };
}

// ── 4대보험 취득·상실 신고 ──

export const INSURANCE_REPORT_KINDS = Object.freeze(['acquire', 'lose']);

/**
 * 상실 사유(고용보험 피보험자격 상실 사유 구분 코드 — 4대사회보험 정보연계센터 상실 신고서의 코드). 국민연금·건강보험의 상실 부호는
 * 신고서에서 이 코드에 맞춰 고른다.
 */
export const LOSS_REASONS = Object.freeze([
  { code: '11', label: '개인 사정으로 인한 자진 퇴사' },
  { code: '12', label: '사업장 이전·근로 조건 변동·임금 체불 등으로 자진 퇴사' },
  { code: '22', label: '폐업·도산' },
  { code: '23', label: '경영상 필요·회사 불황으로 인원 감축 등(해고·권고사직·계약 파기)' },
  { code: '26', label: '근로자의 귀책 사유에 의한 징계 해고·권고사직' },
  { code: '31', label: '정년' },
  { code: '32', label: '계약 기간 만료·공사 종료' },
  { code: '41', label: '고용보험 비적용' },
  { code: '42', label: '이중 고용' },
]);

/** 신고 기한 — 취득일·상실일이 속한 달의 다음 달 15일(국민연금·건강보험·고용보험·산재보험 모두). */
export function reportDeadline(eventDate) {
  const [y, m] = eventDate.split('-').map(Number);
  const ny = m === 12 ? y + 1 : y;
  const nm = m === 12 ? 1 : m + 1;
  return `${ny}-${String(nm).padStart(2, '0')}-15`;
}

const amount = (v) => {
  if (v === undefined || v === null || v === '') return null;
  const n = Number(typeof v === 'string' ? v.replace(/[,\s원]/g, '') : v);
  return Number.isFinite(n) && n >= 0 && n <= 1_000_000_000 ? Math.round(n) : undefined;
};

/** 신고서의 부호 칸(직종 부호·국민연금/건강보험 취득·상실 부호) — 영문·숫자 10자까지. */
const REPORT_CODE_FIELDS = Object.freeze(['jobCode', 'pensionCode', 'healthCode']);

/**
 * 신고 하나 `{ kind, userId, eventDate, reasonCode?, monthlyPay?, weeklyHours?, jobName?, jobCode?, pensionCode?, healthCode?, memo? }` →
 * `{ report }` | `{ error }`. [partial]이면 보낸 칸만. 취득일은 입사일, 상실일은 퇴직일(마지막 근무일의 다음 날)이다. 부호 칸은 EDI 일괄 신고
 * 양식에 그대로 옮긴다(부호표는 신고서 뒤쪽·정보연계센터 안내를 본다 — 여기서 뜻을 따지지 않는다).
 */
export function parseInsuranceReport(body, { partial = false } = {}) {
  const out = {};
  if (!partial || body?.kind !== undefined) {
    if (!INSURANCE_REPORT_KINDS.includes(body?.kind)) return { error: '취득·상실 중 무엇을 신고할지 고르세요.' };
    out.kind = body.kind;
  }
  if (!partial || body?.eventDate !== undefined) {
    if (!isDateKey(body?.eventDate)) return { error: '취득일(입사일)·상실일(퇴직일 — 마지막 근무일 다음 날)을 확인하세요.' };
    out.eventDate = body.eventDate;
  }
  if (body?.reasonCode !== undefined) {
    if (body.reasonCode !== null && body.reasonCode !== '' && !LOSS_REASONS.some((r) => r.code === body.reasonCode)) return { error: '상실 사유를 고르세요.' };
    out.reasonCode = body.reasonCode || null;
  }
  const data = {};
  if (body?.monthlyPay !== undefined) {
    const pay = amount(body.monthlyPay);
    if (pay === undefined) return { error: '월 보수액을 원 단위로 넣으세요.' };
    data.monthlyPay = pay;
  }
  if (body?.weeklyHours !== undefined) {
    const h = body.weeklyHours === null || body.weeklyHours === '' ? null : Number(body.weeklyHours);
    if (h !== null && (!Number.isFinite(h) || h < 0 || h > 68)) return { error: '주 소정근로시간을 확인하세요(0~68시간).' };
    data.weeklyHours = h;
  }
  if (body?.jobName !== undefined) data.jobName = cleanText(body.jobName ?? '', 40) || null;
  for (const key of REPORT_CODE_FIELDS) {
    if (body?.[key] === undefined) continue;
    const code = String(body[key] ?? '').trim();
    if (code && !/^[0-9A-Za-z]{1,10}$/.test(code)) return { error: '부호는 영문·숫자 10자까지입니다.' };
    data[key] = code || null;
  }
  if (body?.memo !== undefined) {
    const memo = cleanText(body.memo ?? '', 301);
    if ([...memo].length > 300) return { error: '메모는 300자까지입니다.' };
    data.memo = memo || null;
  }
  return { report: out, data };
}

/**
 * 신고 자료의 줄(내보내기 양식의 칸 이름 — exportTemplateRules.js FIELDS.acquire·lose). [rows]는 `{ name, employeeNo, rrn?, eventDate, reasonCode,
 * data, yearPay, yearMonths, prevYearPay, prevYearMonths }`(rrn은 내보낼 때만 받은 주민등록번호 — 서버에 두지 않는다).
 */
export function insuranceRecords(kind, rows) {
  return rows.map((r) => ({
    name: r.name,
    rrn: r.rrn ?? null,
    employeeNo: r.employeeNo ?? '',
    eventDate: r.eventDate,
    deadline: reportDeadline(r.eventDate),
    memo: r.data?.memo ?? '',
    pensionCode: r.data?.pensionCode ?? '',
    healthCode: r.data?.healthCode ?? '',
    ...(kind === 'acquire'
      ? { monthlyPay: r.data?.monthlyPay ?? null, weeklyHours: r.data?.weeklyHours ?? null, jobName: r.data?.jobName ?? '', jobCode: r.data?.jobCode ?? '' }
      : {
          reasonCode: r.reasonCode ?? '',
          reasonLabel: LOSS_REASONS.find((x) => x.code === r.reasonCode)?.label ?? '',
          yearPay: r.yearPay ?? 0,
          yearMonths: r.yearMonths ?? 0,
          prevYearPay: r.prevYearPay ?? 0,
          prevYearMonths: r.prevYearMonths ?? 0,
        }),
  }));
}

/**
 * 신고할 만한 사람(제안) — 입사일이 [today] 전 [days]일 안이고 취득 신고가 없는 구성원. [members]는 `[{ id, name, hireDate }]`, [reports]는
 * 지금 있는 신고들. `[{ userId, name, kind: 'acquire', eventDate }]`.
 */
export function suggestInsuranceReports(members, reports, today, days = 62) {
  const cutoff = new Date(Date.parse(`${today}T00:00:00Z`) - days * 86_400_000).toISOString().slice(0, 10);
  const acquired = new Set(reports.filter((r) => r.kind === 'acquire').map((r) => r.userId));
  return members
    .filter((m) => isDateKey(m.hireDate) && m.hireDate >= cutoff && m.hireDate <= today && !acquired.has(m.id))
    .map((m) => ({ userId: m.id, name: m.name, kind: 'acquire', eventDate: m.hireDate }));
}

// ── 한 해 급여 집계 ──

/** 공제 항목 이름 → 집계 칸(4대보험·소득세·지방소득세 — 연말정산 소득세 같은 정산분은 기납부세액에 넣지 않는다). */
export function deductionBucket(name) {
  const n = String(name ?? '').replace(/\s/g, '');
  if (n.includes('연말정산') || n.includes('중도정산') || n.includes('퇴직소득')) return 'settlement';
  if (n.includes('국민연금')) return 'pension';
  if (n.includes('장기요양')) return 'longTermCare';
  if (n.includes('건강보험')) return 'health';
  if (n.includes('고용보험')) return 'employment';
  if (n.includes('지방소득세') || n.includes('주민세')) return 'localTax';
  if (n.includes('소득세')) return 'incomeTax';
  return 'other';
}

/**
 * 한 사람의 한 해 집계 — [slips]는 그해 지급일의 보낸 명세서 `[{ payMonth, data }]`. `{ months, gross, taxFree, taxable, pension, health,
 * longTermCare, employment, incomeTax, localTax, settlement, other, net }`(months는 명세서를 받은 서로 다른 귀속 월 수).
 */
export function yearTotals(slips) {
  const out = { months: 0, gross: 0, taxFree: 0, taxable: 0, pension: 0, health: 0, longTermCare: 0, employment: 0, incomeTax: 0, localTax: 0, settlement: 0, other: 0, net: 0 };
  const months = new Set();
  for (const s of slips) {
    const t = payslipTotals(s.data);
    out.gross += t.gross;
    out.taxFree += t.taxFree;
    out.taxable += t.taxable;
    out.net += t.net;
    if (t.gross > 0 && s.payMonth) months.add(s.payMonth);
    for (const d of s.data?.deductions ?? []) out[deductionBucket(d.name)] += d.amount ?? 0;
  }
  out.months = months.size;
  return out;
}
