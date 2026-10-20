/**
 * 회계 전표 내보내기·영수증 보관 기간(financeTools.js·payrollReports.js)의 순수 규칙 — 지출 분류 → 계정과목, 법인카드 사용·지출 결재·급여 대장 →
 * 분개 줄(차변·대변), 회계 프로그램에 올릴 엑셀 모양(일반·더존 일반전표), 영수증 원본의 보관 기한. DB 없이 `node --test`로 시험한다
 * (test/financeTools.test.js).
 *
 * 계정 코드는 더존(Smart A·iCUBE) 기본 계정과목표에 흔히 쓰는 번호를 기본으로 두고 관리자가 바꾼다(회사마다 계정과목표가 다르다). 부가세
 * 매입세액(부가세대급금) 나누기·거래처 코드는 넣지 않는다 — 회계 프로그램에서 거래처를 맞추고 필요하면 나눈다.
 */

/** 기본 계정 — 지출 분류(groupwareOptions.js 기본 분류)마다, 그리고 대변·급여 계정. */
export const DEFAULT_ACCOUNTS = Object.freeze({
  categories: Object.freeze({
    교통비: { code: '812', name: '여비교통비' },
    식대: { code: '811', name: '복리후생비' },
    '비품·소모품': { code: '830', name: '소모품비' },
    // 관리자가 분류를 나눴을 때 흔한 이름.
    비품: { code: '212', name: '비품' },
    소모품: { code: '830', name: '소모품비' },
    출장비: { code: '812', name: '여비교통비' },
    교육비: { code: '825', name: '교육훈련비' },
    접대비: { code: '813', name: '기업업무추진비' },
    기타: { code: '848', name: '잡비' },
  }),
  // 분류가 없거나 표에 없는 분류.
  fallback: Object.freeze({ code: '848', name: '잡비' }),
  // 법인카드 사용의 대변(카드 대금 — 거래처는 카드사).
  cardPayable: Object.freeze({ code: '253', name: '미지급금' }),
  // 직원이 먼저 쓴 지출의 대변(돌려줄 돈 — 거래처는 쓴 사람).
  expensePayable: Object.freeze({ code: '253', name: '미지급금' }),
  // 급여: 차변 급여, 대변 예수금(공제)·보통예금(실수령 지급).
  salary: Object.freeze({ code: '802', name: '직원급여' }),
  withholding: Object.freeze({ code: '254', name: '예수금' }),
  payment: Object.freeze({ code: '103', name: '보통예금' }),
});

const CARD_WORD = '카드';
const ACCOUNT_KEYS = ['fallback', 'cardPayable', 'expensePayable', 'salary', 'withholding', 'payment'];

const cleanText = (v, max) =>
  typeof v === 'string' ? v.replace(/[\u0000-\u001f\u007f‪-‮⁦-⁩]/g, ' ').replace(/\s+/g, ' ').trim().slice(0, max) : '';

function parseAccount(raw) {
  if (!raw || typeof raw !== 'object') return null;
  const code = cleanText(String(raw.code ?? ''), 11);
  const name = cleanText(String(raw.name ?? ''), 31);
  if (!code && !name) return null;
  if (!/^[0-9A-Za-z-]{1,10}$/.test(code)) return { error: '계정 코드는 숫자·영문 10자까지입니다.' };
  if (!name || [...name].length > 30) return { error: '계정과목 이름을 30자까지 쓰세요.' };
  return { code, name };
}

/** 계정 설정 `{ categories: { 분류: { code, name } }, fallback?, cardPayable?, … }` → 저장할 값(기본과 다른 것만) | `{ error }`. */
export function parseAccountMap(input) {
  if (input === undefined) return { accountMap: undefined };
  if (input === null) return { accountMap: null };
  if (typeof input !== 'object') return { error: '계정 설정을 확인하세요.' };
  const out = {};
  if (input.categories && typeof input.categories === 'object') {
    const cats = {};
    for (const [category, raw] of Object.entries(input.categories)) {
      const a = parseAccount(raw);
      if (a?.error) return a;
      if (a) cats[cleanText(category, 30)] = a;
    }
    if (Object.keys(cats).length) out.categories = cats;
  }
  for (const key of ACCOUNT_KEYS) {
    const a = parseAccount(input[key]);
    if (a?.error) return a;
    if (a) out[key] = a;
  }
  return { accountMap: out };
}

/** 저장한 계정 설정을 기본에 덮은 것. */
export function accountsOf(stored) {
  const s = stored ?? {};
  const out = { categories: { ...DEFAULT_ACCOUNTS.categories, ...(s.categories ?? {}) } };
  for (const key of ACCOUNT_KEYS) out[key] = s[key] ?? DEFAULT_ACCOUNTS[key];
  return out;
}

const accountForCategory = (accounts, category) => accounts.categories[category] ?? accounts.fallback;

/**
 * 법인카드 사용 건 → 분개 — 차변 분류의 계정 / 대변 미지급금(거래처: 카드사 카드). 승인 취소(음수)는 차·대변을 바꿔 넣는다. 제외한 건(승인 취소
 * 짝·개인 사용)은 넣지 않는다. [txs]는 `{ usedOn, merchant, merchantBizNo, amount, category, memo, userName, cardName, issuer, last4, approvalNo }`.
 * 줄 `{ date, side('debit'|'credit'), account, partner, bizNo, memo, amount, source, entry }` — 한 거래(전표)의 줄들은 [entry]가 같다.
 */
export function cardVoucherLines(txs, accounts) {
  const lines = [];
  for (const [i, t] of [...txs].sort((a, b) => (a.usedOn < b.usedOn ? -1 : a.usedOn > b.usedOn ? 1 : 0)).entries()) {
    if (!t.amount) continue;
    const debitAccount = accountForCategory(accounts, t.category);
    const memo = [t.merchant, t.memo, t.userName].filter(Boolean).join(' / ').slice(0, 100);
    // 거래처 "신한카드 1234" — 템플릿 글로 두면 앱의 서버 글 번역(trServer)이 "…카드 …" 모양의 모든 글에 걸리므로 이어 붙인다.
    const partner = [t.issuer ? t.issuer + CARD_WORD : CARD_WORD, t.last4].filter(Boolean).join(' ');
    const value = Math.abs(t.amount);
    const cancel = t.amount < 0;
    const group = { date: t.usedOn, source: 'card', entry: `card:${t.id ?? i}` };
    lines.push(
      { ...group, side: cancel ? 'credit' : 'debit', account: debitAccount, partner: t.merchant ?? '', bizNo: t.merchantBizNo ?? '', memo, amount: value },
      { ...group, side: cancel ? 'debit' : 'credit', account: accounts.cardPayable, partner, bizNo: '', memo, amount: value },
    );
  }
  return lines;
}

/**
 * 매입 증빙(현금영수증·전자세금계산서) → 분개 — 차변 분류의 계정(합계), 대변 미지급금(거래처: 공급자). 취소(음수)는 반대로.
 * [docs]는 `{ id, issuedOn, kind, supplierName, supplierBizNo, totalAmount, category, itemName, memo }`.
 */
export function taxDocVoucherLines(docs, accounts) {
  const lines = [];
  for (const [i, d] of [...docs].sort((a, b) => (a.issuedOn < b.issuedOn ? -1 : a.issuedOn > b.issuedOn ? 1 : 0)).entries()) {
    if (!d.totalAmount) continue;
    const memo = [d.kind === 'tax_invoice' ? '세금계산서' : '현금영수증', d.itemName, d.memo].filter(Boolean).join(' / ').slice(0, 100);
    const value = Math.abs(d.totalAmount);
    const cancel = d.totalAmount < 0;
    const group = { date: d.issuedOn, source: 'taxdoc', entry: `taxdoc:${d.id ?? i}` };
    const partner = d.supplierName ?? '';
    const bizNo = d.supplierBizNo ?? '';
    lines.push(
      { ...group, side: cancel ? 'credit' : 'debit', account: accountForCategory(accounts, d.category), partner, bizNo, memo, amount: value },
      { ...group, side: cancel ? 'debit' : 'credit', account: accounts.expensePayable, partner, bizNo, memo, amount: value },
    );
  }
  return lines;
}

/**
 * 승인된 지출 결재(법인카드 청구가 아닌 것 — 직원이 먼저 쓴 돈) → 분개 — 차변 분류의 계정 / 대변 미지급금(거래처: 쓴 사람).
 * [docs]는 `{ docNumber, title, authorName, payload: { amount, category, spentOn } }`.
 */
export function expenseVoucherLines(docs, accounts) {
  const lines = [];
  for (const [i, d] of docs.entries()) {
    const p = d.payload ?? {};
    if (!p.amount || Array.isArray(p.cardTransactions)) continue;
    const memo = [d.title, d.docNumber].filter(Boolean).join(' / ').slice(0, 100);
    const group = { date: p.spentOn, source: 'expense', entry: `expense:${d.id ?? i}` };
    lines.push(
      { ...group, side: 'debit', account: accountForCategory(accounts, p.category), partner: d.authorName ?? '', bizNo: '', memo, amount: p.amount },
      { ...group, side: 'credit', account: accounts.expensePayable, partner: d.authorName ?? '', bizNo: '', memo, amount: p.amount },
    );
  }
  return lines.sort((a, b) => (a.date < b.date ? -1 : a.date > b.date ? 1 : 0));
}

/**
 * 급여 대장 → 분개 하나(지급일) — 차변 급여(지급 총액), 대변 예수금(공제 항목마다 — 적요에 항목 이름), 대변 보통예금(실수령 합계). 지급·공제가
 * 음수인 항목도 그대로 더한다. [slips]는 `{ data: { earnings, deductions } }`.
 */
export function payrollVoucherLines(run, slips, accounts) {
  let gross = 0;
  const deductions = new Map();
  for (const s of slips) {
    for (const e of s.data?.earnings ?? []) gross += e.amount ?? 0;
    for (const d of s.data?.deductions ?? []) deductions.set(d.name, (deductions.get(d.name) ?? 0) + (d.amount ?? 0));
  }
  const deductionTotal = [...deductions.values()].reduce((a, b) => a + b, 0);
  const group = { date: run.payDate, source: 'payroll', entry: `payroll:${run.id ?? ''}` };
  const title = run.title ?? '';
  const lines = [{ ...group, side: 'debit', account: accounts.salary, partner: '', bizNo: '', memo: `${title} · 인원 ${slips.length}명`, amount: gross }];
  for (const [name, value] of deductions) {
    if (value) lines.push({ ...group, side: 'credit', account: accounts.withholding, partner: '', bizNo: '', memo: `${title} ${name}`, amount: value });
  }
  lines.push({ ...group, side: 'credit', account: accounts.payment, partner: '', bizNo: '', memo: `${title} 실지급`, amount: gross - deductionTotal });
  return lines;
}

/** 줄들에 전표 번호를 매긴다 — 날짜마다 1부터, 거래([entry])가 바뀌면 새 전표. 새 목록. */
export function numberVouchers(lines) {
  const out = [];
  const seqByDate = new Map();
  let prev = null;
  let no = 0;
  for (const l of lines) {
    const startsNew = !prev || prev.date !== l.date || prev.entry !== l.entry;
    if (startsNew) {
      no = (seqByDate.get(l.date) ?? 0) + 1;
      seqByDate.set(l.date, no);
    }
    out.push({ ...l, voucherNo: no });
    prev = l;
  }
  return out;
}

export const VOUCHER_FORMATS = Object.freeze(['generic', 'douzone']);

/**
 * 엑셀 시트 모양 — 'generic'(일자·전표번호·차대 구분·계정·거래처·적요·차변·대변 금액 — 어느 회계 프로그램이든 붙여 넣기 쉬운 모양),
 * 'douzone'(더존 일반전표 엑셀 올리기에 흔한 모양 — 월·일·구분(3 차변/4 대변)·계정코드·계정과목·거래처코드·거래처명·적요·금액). 프로그램 판마다
 * 열 이름·순서가 조금씩 달라 올리기 전에 회계 프로그램의 엑셀 양식과 맞춰 본다. `{ header, rows, amountColumns }`.
 */
export function voucherSheet(lines, format = 'generic') {
  const numbered = numberVouchers(lines);
  if (format === 'douzone') {
    return {
      header: ['월', '일', '번호', '구분', '계정코드', '계정과목', '거래처코드', '거래처명', '사업자번호', '적요', '금액'],
      rows: numbered.map((l) => [
        Number(l.date.slice(5, 7)),
        Number(l.date.slice(8, 10)),
        l.voucherNo,
        l.side === 'debit' ? 3 : 4,
        l.account.code,
        l.account.name,
        '',
        l.partner,
        l.bizNo,
        l.memo,
        l.amount,
      ]),
      amountColumns: [11],
    };
  }
  return {
    header: ['일자', '전표번호', '구분', '계정코드', '계정과목', '거래처', '사업자번호', '적요', '차변', '대변'],
    rows: numbered.map((l) => [
      l.date,
      l.voucherNo,
      l.side === 'debit' ? '차변' : '대변',
      l.account.code,
      l.account.name,
      l.partner,
      l.bizNo,
      l.memo,
      l.side === 'debit' ? l.amount : null,
      l.side === 'credit' ? l.amount : null,
    ]),
    amountColumns: [9, 10],
  };
}

/** 차변·대변 합계(맞는지 확인). */
export function voucherTotals(lines) {
  const debit = lines.filter((l) => l.side === 'debit').reduce((s, l) => s + l.amount, 0);
  const credit = lines.filter((l) => l.side === 'credit').reduce((s, l) => s + l.amount, 0);
  return { debit, credit, balanced: debit === credit };
}

// ── 영수증 원본 보관 기간 ──

/** 보관 연수 고르기(0 = 기한 없이 둠). 국세기본법 제85조의3 — 장부·증빙은 법정신고기한이 지난 날부터 5년. */
export const RETENTION_YEARS = Object.freeze([0, 5, 7, 10]);
/** 법정신고기한 — 법인(12월 결산 — 다음 해 3월 31일) | 개인사업자(다음 해 5월 31일). */
export const FILING_TYPES = Object.freeze({ corporate: '03-31', individual: '05-31' });

/**
 * 영수증의 보관 기한 — 쓴 날 [usedOn](YYYY-MM-DD)이 든 해의 법정신고기한(다음 해 3월 31일 또는 5월 31일)부터 [years]년. 0이면 null(기한 없음).
 */
export function receiptKeepUntil(usedOn, { years = 5, filing = 'corporate' } = {}) {
  if (!years || typeof usedOn !== 'string' || !/^\d{4}-\d{2}-\d{2}/.test(usedOn)) return null;
  const year = Number(usedOn.slice(0, 4));
  return `${year + 1 + years}-${FILING_TYPES[filing] ?? FILING_TYPES.corporate}`;
}

/** 보관 설정 `{ retentionYears?, filing?, purge? }` → 바꿀 값 | `{ error }`. */
export function parseRetention(input) {
  const out = {};
  if (input?.retentionYears !== undefined) {
    const y = Number(input.retentionYears);
    if (!RETENTION_YEARS.includes(y)) return { error: '보관 기간은 5·7·10년이나 기한 없음 중에서 고르세요.' };
    out.receiptRetentionYears = y;
  }
  if (input?.filing !== undefined) {
    if (!Object.hasOwn(FILING_TYPES, input.filing)) return { error: '사업자 종류를 고르세요.' };
    out.receiptFiling = input.filing;
  }
  if (input?.purge !== undefined) out.receiptPurge = input.purge === true;
  return { patch: out };
}
