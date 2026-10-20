/**
 * 현금영수증·전자세금계산서 조회(financeTools.js)와 CODEF 연동(codef.js)의 순수 규칙 — 홈택스에서 내려받은 목록 엑셀 읽기, 같은 증빙 거르기,
 * CODEF 응답(카드 승인내역·홈택스 목록)을 우리 사용 건·증빙 모양으로 맞추기. DB 없이 `node --test`로 시험한다(test/financeTools.test.js).
 *
 * 홈택스 엑셀은 위에 제목·조회 조건 줄이 몇 줄 있고 그 아래 머리 줄이 있다 — 앞 20줄에서 머리 줄(날짜·금액·거래처 열)을 찾는다(카드 이용내역과
 * 같은 방식 — cardRules.js parseStatementRows). 금액은 원 단위 정수, 취소·마이너스 발급은 음수다.
 */
import { last4Of, normalizeBizNo, parseTxAmount, parseUsedAt, seoulDateKey } from './cardRules.js';

export const TAX_DOC_KINDS = Object.freeze(['cash_receipt', 'tax_invoice']);
export const TAX_DOC_DIRECTIONS = Object.freeze(['purchase', 'sale']);
export const TAX_DOC_IMPORT_MAX = 5000;

const cleanText = (v, max) =>
  typeof v === 'string' ? v.replace(/[\u0000-\u001f\u007f‪-‮⁦-⁩]/g, ' ').replace(/\s+/g, ' ').trim().slice(0, max) : '';
const headerKey = (cell) => String(cell ?? '').replace(/[\s_()]/g, '');

// 앞쪽 이름일수록 먼저 — 정확히 같은 이름을 먼저 보고, 없으면 그 이름을 담은 열.
const SYNONYMS = {
  date: ['작성일자', '매입일시', '매출일시', '거래일시', '거래일자', '발행일자', '사용일자', '승인일자', '일자'],
  approvalNo: ['승인번호', '국세청승인번호'],
  supplierBizNo: ['공급자사업자등록번호', '공급자등록번호', '가맹점사업자등록번호', '가맹점사업자번호', '사업자등록번호', '사업자번호'],
  supplierName: ['공급자상호', '가맹점명', '상호명', '상호', '공급자명', '발행자명'],
  buyerBizNo: ['공급받는자사업자등록번호', '공급받는자등록번호'],
  buyerName: ['공급받는자상호', '공급받는자명'],
  supply: ['공급가액'],
  tax: ['세액', '부가세', '부가가치세'],
  service: ['봉사료'],
  total: ['합계금액', '총금액', '총액', '거래금액', '금액'],
  status: ['거래구분', '승인구분', '발급유형', '구분'],
  item: ['품목명', '대표품목'],
};

/** 머리 줄 → 열 위치(없으면 -1) — 날짜와 (합계 또는 공급가액)이 있어야 머리 줄. 세금계산서인지(공급받는자·작성일자 열)도. */
export function mapTaxDocHeader(row) {
  const keys = (row ?? []).map(headerKey);
  const out = {};
  const used = new Set();
  for (const [field, names] of Object.entries(SYNONYMS)) {
    out[field] = -1;
    for (const name of names) {
      const i = keys.findIndex((k, idx) => k === name && !used.has(idx));
      if (i >= 0) {
        out[field] = i;
        used.add(i);
        break;
      }
    }
  }
  for (const [field, names] of Object.entries(SYNONYMS)) {
    if (out[field] >= 0) continue;
    for (const name of names) {
      if (name.length < 2) continue;
      const i = keys.findIndex((k, idx) => k.includes(name) && !used.has(idx));
      if (i >= 0) {
        out[field] = i;
        used.add(i);
        break;
      }
    }
  }
  if (out.date < 0 || (out.total < 0 && out.supply < 0)) return null;
  out.looksLikeInvoice = keys.some((k) => k.includes('공급받는자') || k === '작성일자');
  return out;
}

const cellValue = (v) => {
  if (v && typeof v === 'object' && !(v instanceof Date)) {
    if (Array.isArray(v.richText)) return v.richText.map((r) => r.text ?? '').join('');
    if ('result' in v) return cellValue(v.result);
    if ('text' in v) return v.text;
  }
  return v;
};
const cellString = (v) => {
  const x = cellValue(v);
  return x === null || x === undefined ? '' : x instanceof Date ? x.toISOString() : String(x).trim();
};

/** 같은 증빙인지 가릴 키 — 승인번호가 있으면 종류·승인번호(취소는 금액 부호까지), 없으면 날짜·공급자 사업자번호·합계. */
export function taxDocDedupeKey({ kind, approvalNo, issuedOn, supplierBizNo, total }) {
  const no = String(approvalNo ?? '').replace(/[\s-]/g, '');
  if (no) return `${kind}:a:${no}:${total < 0 ? '-' : '+'}`;
  return `${kind}:t:${issuedOn}:${String(supplierBizNo ?? '').replace(/\D/g, '')}:${total}`;
}

/**
 * 홈택스 목록 엑셀(현금영수증 매입·매출 내역 / 전자세금계산서 목록) → 증빙들. [kind]를 주지 않으면 머리 줄로 짐작한다(공급받는자·작성일자
 * 열이 있으면 세금계산서). `{ kind, rows: [{ line, kind, direction, issuedOn, approvalNo, supplierName, supplierBizNo, buyerName, buyerBizNo,
 * supplyAmount, taxAmount, totalAmount, itemName }], errors: [{ line, message }] }` | `{ error }`.
 */
export function parseTaxDocRows(rows, { kind = null, direction = 'purchase' } = {}) {
  let header = null;
  let headerIndex = -1;
  for (let i = 0; i < Math.min(20, rows.length); i++) {
    const mapped = mapTaxDocHeader((rows[i] ?? []).map(cellString));
    if (mapped) {
      header = mapped;
      headerIndex = i;
      break;
    }
  }
  if (!header) return { error: '목록의 머리 줄(작성일자·거래일시, 공급가액·합계금액 같은 열 이름)을 찾지 못했습니다. 홈택스에서 내려받은 엑셀을 그대로 올리세요.' };
  const docKind = TAX_DOC_KINDS.includes(kind) ? kind : header.looksLikeInvoice ? 'tax_invoice' : 'cash_receipt';
  const dir = TAX_DOC_DIRECTIONS.includes(direction) ? direction : 'purchase';
  const out = [];
  const errors = [];
  for (let i = headerIndex + 1; i < rows.length; i++) {
    const row = rows[i] ?? [];
    const line = i + 1;
    const get = (idx) => (idx >= 0 ? cellValue(row[idx]) : null);
    const str = (idx) => (idx >= 0 ? cellString(row[idx]) : '');
    const dateRaw = get(header.date);
    if ((dateRaw === null || dateRaw === '') && !str(header.total) && !str(header.supply)) continue;
    if (/합\s*계|소\s*계|총\s*계/.test(str(0) + str(header.date)) && !parseUsedAt(dateRaw)) continue;
    const at = parseUsedAt(dateRaw);
    if (!at) {
      errors.push({ line, message: `날짜를 읽지 못했습니다: ${cellString(dateRaw) || '(빈 칸)'}` });
      continue;
    }
    const num = (idx) => (idx >= 0 && str(idx) !== '' ? parseTxAmount(get(idx)) : null);
    const supply = num(header.supply);
    const tax = num(header.tax);
    const service = num(header.service);
    let total = num(header.total);
    if (total === null && supply !== null) total = supply + (tax ?? 0) + (service ?? 0);
    if (total === null || (supply === null && header.supply >= 0 && str(header.supply) !== '')) {
      errors.push({ line, message: `금액을 읽지 못했습니다: ${str(header.total) || str(header.supply) || '(빈 칸)'}` });
      continue;
    }
    const status = str(header.status);
    const sign = /취소|마이너스|반품/.test(status) && total > 0 ? -1 : 1;
    out.push({
      line,
      kind: docKind,
      direction: dir,
      issuedOn: seoulDateKey(at),
      approvalNo: str(header.approvalNo).replace(/\s/g, '').slice(0, 40) || null,
      supplierName: cleanText(str(header.supplierName), 100) || null,
      supplierBizNo: normalizeBizNo(str(header.supplierBizNo)),
      buyerName: cleanText(str(header.buyerName), 100) || null,
      buyerBizNo: normalizeBizNo(str(header.buyerBizNo)),
      supplyAmount: supply === null ? null : sign * Math.abs(supply),
      taxAmount: tax === null ? null : sign * Math.abs(tax),
      totalAmount: sign * Math.abs(total),
      itemName: cleanText(str(header.item), 100) || null,
    });
    if (out.length > TAX_DOC_IMPORT_MAX) return { error: `한 번에 ${TAX_DOC_IMPORT_MAX}건까지 가져올 수 있습니다. 기간을 나눠 올리세요.` };
  }
  return { kind: docKind, rows: out, errors };
}

// ── CODEF ──

/** 카드사 → CODEF 기관 코드(카드 — 법인 카드 상품). 없는 카드사는 카드마다 직접 넣는다. */
export const CODEF_CARD_ORGS = Object.freeze({
  KB국민: '0301',
  현대: '0302',
  삼성: '0303',
  NH농협: '0304',
  BC: '0305',
  신한: '0306',
  씨티: '0307',
  우리: '0309',
  롯데: '0311',
  하나: '0313',
});

export const codefOrgOf = (card) => (card?.codefOrganization || CODEF_CARD_ORGS[card?.issuer] || null);

/** 응답 줄에서 처음으로 값이 있는 칸. */
const pick = (row, names) => {
  for (const n of names) {
    const v = row?.[n];
    if (v !== undefined && v !== null && String(v).trim() !== '') return v;
  }
  return null;
};

/** 'yyyyMMdd'(와 'HHmmss') → Date(한국 시각) | null. */
function codefDate(date, time) {
  const d = String(date ?? '').replace(/\D/g, '');
  if (d.length !== 8) return null;
  const t = String(time ?? '').replace(/\D/g, '').padEnd(6, '0').slice(0, 6);
  return parseUsedAt(`${d.slice(0, 4)}-${d.slice(4, 6)}-${d.slice(6, 8)} ${t.slice(0, 2)}:${t.slice(2, 4)}:${t.slice(4, 6)}`);
}

/**
 * CODEF 법인 카드 승인내역 한 줄 → 사용 건 `{ last4, usedAt, usedOn, merchant, merchantBizNo, amount, approvalNo }` | `{ error }`. 칸 이름은
 * 상품 판마다 조금씩 달라 흔한 이름을 차례로 본다(resUsedDate·resUsedTime·resMemberStoreName·resUsedAmount·resApprovalNo·resCardNo·
 * resCancelYN — '1'·'Y'·'취소'면 취소 — ·resCancelAmount·resMemberStoreCorpNo).
 */
export function codefCardRow(row) {
  const usedAt = codefDate(pick(row, ['resUsedDate', 'resApprovalDate', 'resUsedDay']), pick(row, ['resUsedTime', 'resApprovalTime']));
  if (!usedAt) return { error: '사용 날짜를 읽지 못했습니다.' };
  let amount = parseTxAmount(String(pick(row, ['resUsedAmount', 'resApprovalAmount', 'resAmount']) ?? ''));
  if (amount === null || amount === 0) return { error: '금액을 읽지 못했습니다.' };
  const cancel = String(pick(row, ['resCancelYN', 'resCancelYn', 'resApprovalStatus']) ?? '');
  if (/^(1|2|y|Y)$|취소/.test(cancel)) {
    const canceled = parseTxAmount(String(pick(row, ['resCancelAmount']) ?? ''));
    amount = -Math.abs(canceled || amount);
  }
  if (/^3$|거절/.test(cancel)) return { error: '승인 거절 건입니다.', skip: true };
  return {
    tx: {
      last4: last4Of(pick(row, ['resCardNo', 'resCardNo1', 'resCardNumber'])),
      usedAt,
      usedOn: seoulDateKey(usedAt),
      merchant: cleanText(String(pick(row, ['resMemberStoreName', 'resStoreName', 'resMerchantName']) ?? ''), 100) || '(가맹점 없음)',
      merchantBizNo: normalizeBizNo(pick(row, ['resMemberStoreCorpNo', 'resMemberStoreBizNo', 'resStoreCorpNo'])),
      amount,
      approvalNo: String(pick(row, ['resApprovalNo', 'resApprovalNum']) ?? '').replace(/\s/g, '').slice(0, 30) || null,
    },
  };
}

/** CODEF 홈택스 목록 한 줄(현금영수증·전자세금계산서) → 증빙 | `{ error }`. 칸 이름은 흔한 것을 차례로 본다. */
export function codefTaxDocRow(row, { kind, direction = 'purchase' }) {
  const at = codefDate(pick(row, ['resIssueDate', 'resWriteDate', 'resUsedDate', 'resTradeDate', 'resDate']), pick(row, ['resUsedTime', 'resTradeTime']));
  if (!at) return { error: '날짜를 읽지 못했습니다.' };
  const num = (names) => {
    const v = pick(row, names);
    return v === null ? null : parseTxAmount(String(v));
  };
  const supply = num(['resSupplyValue', 'resSupplyAmount']);
  const tax = num(['resTaxAmt', 'resTaxAmount', 'resVAT']);
  let total = num(['resTotalAmount', 'resTotalAmt', 'resUsedAmount', 'resAmount']);
  if (total === null && supply !== null) total = supply + (tax ?? 0);
  if (total === null) return { error: '금액을 읽지 못했습니다.' };
  const status = String(pick(row, ['resTradeType', 'resCancelYN', 'resIssueType']) ?? '');
  const sign = /취소|^1$|^Y$/.test(status) && total > 0 ? -1 : 1;
  return {
    doc: {
      kind,
      direction,
      issuedOn: seoulDateKey(at),
      approvalNo: String(pick(row, ['resApprovalNo', 'resIssueId', 'resETaxInvoiceNo']) ?? '').replace(/\s/g, '').slice(0, 40) || null,
      supplierName: cleanText(String(pick(row, ['resSupplierCompanyName', 'resMemberStoreName', 'resCompanyNm', 'resSupplierName']) ?? ''), 100) || null,
      supplierBizNo: normalizeBizNo(pick(row, ['resSupplierRegNumber', 'resMemberStoreCorpNo', 'resSupplierCorpNo'])),
      buyerName: cleanText(String(pick(row, ['resContractorCompanyName', 'resBuyerName']) ?? ''), 100) || null,
      buyerBizNo: normalizeBizNo(pick(row, ['resContractorRegNumber', 'resBuyerCorpNo'])),
      supplyAmount: supply === null ? null : sign * Math.abs(supply),
      taxAmount: tax === null ? null : sign * Math.abs(tax),
      totalAmount: sign * Math.abs(total),
      itemName: cleanText(String(pick(row, ['resItemName', 'resProductName']) ?? ''), 100) || null,
    },
  };
}

/** CODEF 응답의 data → 줄 목록(data가 목록이거나, data 안의 첫 목록 칸 — 예: resList·resApprovalList). */
export function codefList(data) {
  if (Array.isArray(data)) return data;
  if (!data || typeof data !== 'object') return [];
  for (const v of Object.values(data)) if (Array.isArray(v)) return v;
  return [data];
}

/** 날짜 'YYYY-MM-DD' → CODEF 'yyyyMMdd'. */
export const codefDay = (key) => key.replace(/-/g, '');
