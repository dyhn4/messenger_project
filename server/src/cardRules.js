/**
 * 법인카드(corporateCards.js)의 순수 규칙 — 카드 등록 검사, 카드사 이용내역(엑셀·CSV) 읽기, 같은 사용 건 거르기(중복 키), 승인 취소 짝짓기,
 * 사용 건의 상태(미정산·결재 중·정산됨·제외)와 지출 결재로 청구할 수 있는지. DB 없이 `node --test`로 시험한다(test/corporateCards.test.js).
 *
 * 카드 번호는 끝 4자리만 둔다(전체 번호·유효기간·CVC는 받지 않는다 — 카드사 이용내역도 대부분 가려져 나온다).
 * 금액은 원 단위 정수, 승인 취소는 음수다. 사용 시각은 카드사가 준 한국 시각(Asia/Seoul)으로 읽는다.
 */

export const CARD_NAME_MAX = 30;
export const CARD_MEMO_MAX = 200;
export const CARDS_MAX = 200;
export const CARD_HOLDERS_MAX = 50;
export const TX_MERCHANT_MAX = 100;
export const TX_MEMO_MAX = 300;
export const TX_RECEIPTS_MAX = 5;
export const TX_AMOUNT_MAX = 100_000_000;
/** 한 번에 가져오는 사용 건 수 상한(엑셀 한 장·연동 요청 하나). */
export const TX_IMPORT_MAX = 3000;
/** 지출 결재 하나로 청구하는 사용 건 수 상한. */
export const CLAIM_TX_MAX = 50;
export const EXCLUDE_REASON_MAX = 200;

/** 카드사(고르기 — 없으면 '기타'). */
export const CARD_ISSUERS = Object.freeze(['신한', '삼성', 'KB국민', '현대', '롯데', '하나', '우리', 'BC', 'NH농협', 'IBK기업', '씨티', '기타']);

/** 사용 건 상태 — 'open'(청구 전) | 'claiming'(지출 결재 중) | 'settled'(지출 결재 승인) | 'excluded'(제외 — 취소 짝·개인 사용 등). */
export const TX_STATUSES = Object.freeze(['open', 'claiming', 'settled', 'excluded']);

const cleanText = (v, max) =>
  typeof v === 'string' ? v.replace(/[\u0000-\u001f\u007f‪-‮⁦-⁩]/g, ' ').replace(/\s+/g, ' ').trim().slice(0, max) : '';

/** 카드 입력 `{ name, issuer, last4, holderIds, monthlyLimit, memo, enabled }` → `{ card }` | `{ error }`. [partial]이면 보낸 칸만. */
export function parseCardInput(body, { partial = false, isCandidate = () => true } = {}) {
  const out = {};
  if (!partial || body?.name !== undefined) {
    const name = cleanText(body?.name ?? '', CARD_NAME_MAX + 1);
    if (!name) return { error: '카드 이름을 쓰세요(예: 영업팀 법인카드).' };
    if ([...name].length > CARD_NAME_MAX) return { error: `카드 이름은 ${CARD_NAME_MAX}자까지입니다.` };
    out.name = name;
  }
  if (!partial || body?.issuer !== undefined) {
    out.issuer = CARD_ISSUERS.includes(body?.issuer) ? body.issuer : '기타';
  }
  if (!partial || body?.last4 !== undefined) {
    const last4 = typeof body?.last4 === 'string' ? body.last4.replace(/\D/g, '') : '';
    if (last4.length !== 4) return { error: '카드 번호 끝 4자리를 넣으세요.' };
    out.last4 = last4;
  }
  if (!partial || body?.holderIds !== undefined) {
    const raw = body?.holderIds ?? [];
    if (!Array.isArray(raw)) return { error: '사용자를 확인하세요.' };
    const ids = [...new Set(raw.filter((id) => typeof id === 'string'))];
    if (ids.length > CARD_HOLDERS_MAX) return { error: `한 카드의 사용자는 ${CARD_HOLDERS_MAX}명까지입니다.` };
    if (ids.some((id) => !isCandidate(id))) return { error: '사용자는 이 범위의 정회원 이상만 정할 수 있습니다.' };
    out.holderIds = ids;
  }
  if (!partial || body?.monthlyLimit !== undefined) {
    const v = body?.monthlyLimit;
    if (v === null || v === undefined || v === '') out.monthlyLimit = null;
    else {
      const n = Number(typeof v === 'string' ? v.replace(/,/g, '') : v);
      if (!Number.isInteger(n) || n <= 0 || n > 10_000_000_000) return { error: '월 한도를 원 단위로 넣으세요(없으면 비움).' };
      out.monthlyLimit = n;
    }
  }
  if (!partial || body?.memo !== undefined) {
    const memo = cleanText(body?.memo ?? '', CARD_MEMO_MAX + 1);
    if ([...memo].length > CARD_MEMO_MAX) return { error: `메모는 ${CARD_MEMO_MAX}자까지입니다.` };
    out.memo = memo || null;
  }
  if (body?.enabled !== undefined) out.enabled = body.enabled !== false;
  return { card: out };
}

/** 같은 카드에서 끝 4자리가 겹치는지 — 이용내역을 끝 4자리로 이어 붙이므로 범위 안에서 겹치면 안 된다(카드사가 다르면 된다). */
export function duplicateCard(cards, { issuer, last4 }, exceptId = null) {
  return cards.find((c) => c.id !== exceptId && c.last4 === last4 && (c.issuer === issuer || c.issuer === '기타' || issuer === '기타')) ?? null;
}

// ── 날짜·금액 읽기 ──

/** 한국 시각(Asia/Seoul — UTC+9, 서머타임 없음) 날짜·시각 → Date. */
export function seoulDate(y, mo, d, h = 0, mi = 0, s = 0) {
  const date = new Date(Date.UTC(y, mo - 1, d, h - 9, mi, s));
  // 2월 30일 같은 날은 거절.
  const check = new Date(date.getTime() + 9 * 3600_000);
  if (check.getUTCFullYear() !== y || check.getUTCMonth() !== mo - 1 || check.getUTCDate() !== d) return null;
  return date;
}

/** Date → 한국 날짜 'YYYY-MM-DD'. */
export const seoulDateKey = (date) => new Date(date.getTime() + 9 * 3600_000).toISOString().slice(0, 10);

/** 엑셀 날짜 일련번호(1900 날짜 체계) → { y, mo, d, h, mi, s }. */
function excelSerialParts(n) {
  const ms = Math.round((n - 25569) * 86400_000);
  const d = new Date(ms);
  return { y: d.getUTCFullYear(), mo: d.getUTCMonth() + 1, d: d.getUTCDate(), h: d.getUTCHours(), mi: d.getUTCMinutes(), s: d.getUTCSeconds() };
}

/**
 * 날짜(와 시각) 글자 하나 → Date(한국 시각) | null. '2026-10-18', '2026.10.18', '2026/10/18', '20261018', '26.10.18', 엑셀 날짜(Date —
 * exceljs는 셀의 날짜를 UTC 그대로 준다)·일련번호, 뒤에 'HH:MM(:SS)'가 붙어도 된다. [timeText]는 따로 있는 시각 열.
 */
export function parseUsedAt(value, timeText = null) {
  let parts = null;
  if (value instanceof Date && !Number.isNaN(value.getTime())) {
    parts = { y: value.getUTCFullYear(), mo: value.getUTCMonth() + 1, d: value.getUTCDate(), h: value.getUTCHours(), mi: value.getUTCMinutes(), s: value.getUTCSeconds() };
  } else if (typeof value === 'number' && value > 20000 && value < 80000) {
    parts = excelSerialParts(value);
  } else {
    const text = typeof value === 'string' ? value.trim() : value === null || value === undefined ? '' : String(value);
    const m =
      /^(\d{4})[-./년\s]+(\d{1,2})[-./월\s]+(\d{1,2})일?(?:[T\s]+(\d{1,2}):(\d{2})(?::(\d{2}))?)?/.exec(text) ??
      /^(\d{4})(\d{2})(\d{2})(?:\s*(\d{2}):?(\d{2})(?::?(\d{2}))?)?$/.exec(text) ??
      /^(\d{2})[-./](\d{1,2})[-./](\d{1,2})(?:\s+(\d{1,2}):(\d{2})(?::(\d{2}))?)?$/.exec(text);
    if (!m) return null;
    let y = Number(m[1]);
    if (y < 100) y += 2000;
    parts = { y, mo: Number(m[2]), d: Number(m[3]), h: Number(m[4] ?? 0), mi: Number(m[5] ?? 0), s: Number(m[6] ?? 0) };
  }
  if (timeText !== null && timeText !== undefined && timeText !== '') {
    let t = null;
    if (timeText instanceof Date) t = { h: timeText.getUTCHours(), mi: timeText.getUTCMinutes(), s: timeText.getUTCSeconds() };
    else if (typeof timeText === 'number' && timeText >= 0 && timeText < 1) {
      const secs = Math.round(timeText * 86400);
      t = { h: Math.floor(secs / 3600), mi: Math.floor((secs % 3600) / 60), s: secs % 60 };
    } else {
      const tm = /(\d{1,2}):?(\d{2})(?::?(\d{2}))?/.exec(String(timeText));
      if (tm) t = { h: Number(tm[1]), mi: Number(tm[2]), s: Number(tm[3] ?? 0) };
    }
    if (t && t.h < 24 && t.mi < 60 && t.s < 60) parts = { ...parts, ...t };
  }
  if (!parts || parts.y < 2000 || parts.y > 2100 || parts.h > 23 || parts.mi > 59 || parts.s > 59) return null;
  return seoulDate(parts.y, parts.mo, parts.d, parts.h, parts.mi, parts.s);
}

/** 금액 → 정수 원 | null. '12,300', '-12,300', '(12,300)', '12,300원', 숫자. */
export function parseTxAmount(value) {
  if (typeof value === 'number') return Number.isFinite(value) ? Math.round(value) : null;
  if (typeof value !== 'string') return null;
  let s = value.replace(/[,\s원₩]/g, '');
  let negative = false;
  if (/^\(.*\)$/.test(s)) {
    negative = true;
    s = s.slice(1, -1);
  }
  if (s.startsWith('△') || s.startsWith('▲')) {
    negative = true;
    s = s.slice(1);
  }
  if (!/^[-+]?\d+(\.\d+)?$/.test(s)) return null;
  const n = Math.round(Number(s));
  return negative ? -Math.abs(n) : n;
}

/** 가려진 카드 번호에서 끝 4자리 — '1234-****-****-5678', '****5678', '5678'. 숫자가 4개 미만이면 null. */
export function last4Of(text) {
  if (text === null || text === undefined) return null;
  const digits = String(text).match(/\d/g);
  if (!digits || digits.length < 4) return null;
  // 가린 번호 뒤쪽에 숫자 4개가 연달아 있으면 그것.
  const tail = /(\d{4})\D*$/.exec(String(text));
  return tail ? tail[1] : digits.slice(-4).join('');
}

/** 사업자등록번호 → '123-45-67890' | null(10자리가 아니면). */
export function normalizeBizNo(text) {
  const digits = String(text ?? '').replace(/\D/g, '');
  return digits.length === 10 ? `${digits.slice(0, 3)}-${digits.slice(3, 5)}-${digits.slice(5)}` : null;
}

const normalizeMerchant = (m) => String(m ?? '').replace(/\s+/g, '').toLowerCase();

/**
 * 같은 사용 건인지 가릴 키(카드마다 unique) — 승인번호가 있으면 승인번호·금액(취소는 같은 승인번호에 음수), 없으면 사용 시각(분)·금액·가맹점.
 * 엑셀을 두 번 가져와도, 연동이 같은 건을 다시 보내도 한 번만 들어간다.
 */
export function txDedupeKey({ approvalNo, usedAt, amount, merchant }) {
  const no = String(approvalNo ?? '').replace(/\s/g, '');
  if (no) return `a:${no}:${amount}`;
  const minute = new Date(usedAt).toISOString().slice(0, 16);
  return `t:${minute}:${amount}:${normalizeMerchant(merchant).slice(0, 40)}`;
}

// ── 이용내역 읽기 ──

const HEADER_SYNONYMS = {
  date: ['이용일시', '승인일시', '거래일시', '사용일시', '이용일자', '승인일자', '거래일자', '사용일자', '매출일자', '이용일', '승인일', '거래일', '사용일', '일자', '날짜'],
  time: ['이용시간', '승인시간', '거래시간', '사용시간', '승인시각', '이용시각', '시간', '시각'],
  merchant: ['이용가맹점명', '가맹점명', '이용가맹점', '이용하신가맹점', '가맹점', '이용처', '사용처', '상호명', '상호', '거래처'],
  // 앞쪽일수록 먼저 — 할부의 "청구금액"보다 승인·이용 금액.
  amount: ['승인금액', '이용금액', '결제금액', '거래금액', '사용금액', '매출금액', '원화금액', '금액(원)', '금액', '청구금액'],
  approvalNo: ['승인번호', '승인No', '승인no'],
  card: ['카드번호', '이용카드', '카드명', '카드'],
  status: ['취소여부', '승인구분', '매출구분', '거래구분', '구분', '상태', '취소구분'],
  bizNo: ['가맹점사업자번호', '사업자등록번호', '사업자번호'],
};

const headerKey = (cell) => String(cell ?? '').replace(/[\s_]/g, '');

/** 머리 줄의 열 위치 `{ date, time, merchant, amount, approvalNo, card, status, bizNo }`(없으면 -1) — 날짜·금액·가맹점이 있어야 머리 줄. */
export function mapStatementHeader(row) {
  const keys = (row ?? []).map(headerKey);
  const out = {};
  for (const [field, names] of Object.entries(HEADER_SYNONYMS)) {
    out[field] = -1;
    for (const name of names) {
      const i = keys.findIndex((k, idx) => k === name && !Object.values(out).includes(idx));
      if (i >= 0) {
        out[field] = i;
        break;
      }
    }
  }
  // 정확히 같은 이름이 없으면 그 이름을 담은 열(예: "이용금액(원)").
  for (const [field, names] of Object.entries(HEADER_SYNONYMS)) {
    if (out[field] >= 0) continue;
    for (const name of names) {
      if (name.length < 2) continue;
      const i = keys.findIndex((k, idx) => k.includes(name) && !Object.values(out).includes(idx));
      if (i >= 0) {
        out[field] = i;
        break;
      }
    }
  }
  return out.date >= 0 && out.amount >= 0 && out.merchant >= 0 ? out : null;
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

/**
 * 카드사 이용내역(시트·CSV의 줄들 — 줄마다 열 값) → 사용 건들. 앞 20줄 안에서 머리 줄(날짜·금액·가맹점 열)을 찾고, 합계·빈 줄은 건너뛴다.
 * 카드는 [cardOf](끝4자리) → 카드 | null 로 고르고, [fixedCard]를 주면 모든 줄을 그 카드로(카드 번호 열이 없어도). "취소"가 적힌 줄은 음수.
 * `{ rows: [{ line, cardId, usedAt, usedOn, merchant, merchantBizNo, amount, approvalNo }], errors: [{ line, message }], header }` |
 * `{ error }`(머리 줄이 없음).
 */
export function parseStatementRows(rows, { fixedCard = null, cardOf = () => null } = {}) {
  let headerIndex = -1;
  let header = null;
  for (let i = 0; i < Math.min(20, rows.length); i++) {
    const mapped = mapStatementHeader((rows[i] ?? []).map(cellString));
    if (mapped) {
      headerIndex = i;
      header = mapped;
      break;
    }
  }
  if (!header) return { error: "이용내역의 머리 줄(이용일자·가맹점·이용금액 같은 열 이름)을 찾지 못했습니다. 카드사에서 받은 엑셀·CSV를 그대로 올리세요." };
  if (!fixedCard && header.card < 0) return { error: '카드 번호 열이 없습니다. 어느 카드의 이용내역인지 고르고 다시 올리세요.' };
  const out = [];
  const errors = [];
  for (let i = headerIndex + 1; i < rows.length; i++) {
    const row = rows[i] ?? [];
    const line = i + 1;
    const raw = (idx) => (idx >= 0 ? cellValue(row[idx]) : null);
    const dateRaw = raw(header.date);
    const merchant = cleanText(cellString(row[header.merchant]), TX_MERCHANT_MAX);
    const amountRaw = raw(header.amount);
    if ((dateRaw === null || dateRaw === '') && !merchant && (amountRaw === null || amountRaw === '')) continue;
    const firstText = cellString(row[0]) + cellString(row[header.date]) + merchant;
    if (/합\s*계|소\s*계|총\s*계|건수/.test(firstText) && !parseUsedAt(dateRaw)) continue;
    const usedAt = parseUsedAt(dateRaw, header.time >= 0 ? raw(header.time) : null);
    if (!usedAt) {
      errors.push({ line, message: `날짜를 읽지 못했습니다: ${cellString(dateRaw) || '(빈 칸)'}` });
      continue;
    }
    let amount = parseTxAmount(amountRaw);
    if (amount === null || amount === 0 || Math.abs(amount) > TX_AMOUNT_MAX) {
      errors.push({ line, message: `금액을 읽지 못했습니다: ${cellString(amountRaw) || '(빈 칸)'}` });
      continue;
    }
    const status = header.status >= 0 ? cellString(row[header.status]) : '';
    if (/취소|반품|환불/.test(status) && amount > 0) amount = -amount;
    let card = fixedCard;
    if (!card) {
      const last4 = last4Of(cellString(row[header.card]));
      card = last4 ? cardOf(last4) : null;
      if (!card) {
        errors.push({ line, message: `등록된 카드가 아닙니다: ${cellString(row[header.card]) || '(빈 칸)'}` });
        continue;
      }
    }
    const approvalNo = header.approvalNo >= 0 ? cellString(row[header.approvalNo]).replace(/\s/g, '').slice(0, 30) || null : null;
    out.push({
      line,
      cardId: card.id,
      usedAt,
      usedOn: seoulDateKey(usedAt),
      merchant: merchant || '(가맹점 없음)',
      merchantBizNo: header.bizNo >= 0 ? normalizeBizNo(cellString(row[header.bizNo])) : null,
      amount,
      approvalNo,
    });
    if (out.length > TX_IMPORT_MAX) return { error: `한 번에 ${TX_IMPORT_MAX}건까지 가져올 수 있습니다. 기간을 나눠 올리세요.` };
  }
  return { rows: out, errors, header };
}

/** CSV 글 → 줄들(따옴표·따옴표 안 줄바꿈·"" 이스케이프). 쉼표 대신 탭으로 나뉜 글도 받는다. */
export function parseCsv(text) {
  const src = String(text ?? '').replace(/^﻿/, '');
  const firstLine = src.split(/\r?\n/, 1)[0] ?? '';
  const sep = (firstLine.match(/\t/g)?.length ?? 0) > (firstLine.match(/,/g)?.length ?? 0) ? '\t' : ',';
  const rows = [];
  let row = [];
  let cell = '';
  let quoted = false;
  for (let i = 0; i < src.length; i++) {
    const ch = src[i];
    if (quoted) {
      if (ch === '"') {
        if (src[i + 1] === '"') {
          cell += '"';
          i++;
        } else quoted = false;
      } else cell += ch;
      continue;
    }
    if (ch === '"' && cell === '') quoted = true;
    else if (ch === sep) {
      row.push(cell.trim());
      cell = '';
    } else if (ch === '\n' || ch === '\r') {
      if (ch === '\r' && src[i + 1] === '\n') i++;
      row.push(cell.trim());
      rows.push(row);
      row = [];
      cell = '';
    } else cell += ch;
  }
  if (cell !== '' || row.length) {
    row.push(cell.trim());
    rows.push(row);
  }
  return rows.filter((r) => r.some((c) => c !== ''));
}

/** 바이트 → 글(UTF-8이 아니면 EUC-KR/CP949 — 국내 카드사 CSV·HTML 엑셀은 EUC-KR이 흔하다). */
export function decodeText(buffer) {
  try {
    return new TextDecoder('utf-8', { fatal: true }).decode(buffer);
  } catch {
    return new TextDecoder('euc-kr').decode(buffer);
  }
}

/** 올린 파일의 종류 — 'xlsx'(zip) | 'xls'(옛 이진 엑셀 — 읽지 못함) | 'html'(엑셀로 이름만 바꾼 HTML 표) | 'csv'. */
export function statementFileKind(buffer) {
  if (buffer.length >= 4 && buffer[0] === 0x50 && buffer[1] === 0x4b) return 'xlsx';
  if (buffer.length >= 8 && buffer[0] === 0xd0 && buffer[1] === 0xcf && buffer[2] === 0x11 && buffer[3] === 0xe0) return 'xls';
  const head = decodeText(buffer.subarray(0, 2048)).replace(/^﻿/, '').trimStart().slice(0, 300).toLowerCase();
  if (head.startsWith('<') && /<(html|table|meta|\?xml)/.test(head)) return 'html';
  return 'csv';
}

// ── 취소 짝짓기·상태 ──

/**
 * 승인 취소 짝짓기 — 음수(취소) 건마다 같은 카드에서 금액이 같고(부호만 반대) 승인번호가 같거나(없으면 가맹점이 같고 30일 안) 아직 짝이 없는
 * 승인 건을 찾는다. 둘 다 "승인 취소"로 제외하면 사용자가 따로 청구하지 않아도 된다. 이미 청구(결재 중·정산)한 승인 건은 짝짓지 않는다
 * (취소 건만 남겨 관리자가 본다). `[[cancelId, approvalId]]`.
 */
export function pairCancellations(txs) {
  const pairs = [];
  const used = new Set();
  const cancels = txs.filter((t) => t.amount < 0 && !t.excludedAt).sort((a, b) => new Date(a.usedAt) - new Date(b.usedAt));
  for (const c of cancels) {
    const candidates = txs.filter(
      (t) =>
        t.amount === -c.amount &&
        t.cardId === c.cardId &&
        !t.excludedAt &&
        !used.has(t.id) &&
        txStatus(t) === 'open' &&
        new Date(t.usedAt) <= new Date(new Date(c.usedAt).getTime() + 60_000),
    );
    const byNo = c.approvalNo ? candidates.find((t) => t.approvalNo === c.approvalNo) : null;
    const byMerchant =
      byNo ??
      candidates
        .filter(
          (t) =>
            normalizeMerchant(t.merchant) === normalizeMerchant(c.merchant) &&
            new Date(c.usedAt) - new Date(t.usedAt) <= 30 * 86400_000,
        )
        .sort((a, b) => new Date(b.usedAt) - new Date(a.usedAt))[0];
    const match = byNo ?? byMerchant;
    if (!match) continue;
    used.add(match.id);
    used.add(c.id);
    pairs.push([c.id, match.id]);
  }
  return pairs;
}

/** 사용 건의 상태 — 제외 표시, 연결된 지출 결재의 상태([expenseStatus] — 결재 중·승인), 그 밖은 미정산. */
export function txStatus(tx) {
  if (tx.excludedAt) return 'excluded';
  if (tx.expenseDocId && tx.expenseStatus === 'pending') return 'claiming';
  if (tx.expenseDocId && tx.expenseStatus === 'approved') return 'settled';
  return 'open';
}

/** [userId]가 이 사용 건을 청구할 수 있는 사람인지 — 사용자로 정해진 사람, 정해지지 않았으면 그 카드의 사용자 누구나. */
export const canClaimTx = (tx, card, userId) => (tx.userId ? tx.userId === userId : (card?.holderIds ?? []).includes(userId));

/**
 * 지출 결재로 청구할 사용 건들 확인 — [txs]는 잠근(FOR UPDATE) 행에 expenseStatus를 붙인 것, [cardsById]는 카드. 모두 이 범위·내가 청구할 수
 * 있는 것·미정산·승인(양수) 건이어야 하고, 합계가 [amount]와 같아야 한다. `{ total, snapshot }` | `{ error, status }`.
 */
export function checkClaim({ ids, txs, cardsById, userId, scopeKey, amount }) {
  if (!Array.isArray(ids) || ids.length === 0) return { error: '청구할 카드 사용 건을 고르세요.' };
  if (ids.length > CLAIM_TX_MAX) return { error: `지출 결재 하나로 ${CLAIM_TX_MAX}건까지 청구할 수 있습니다.` };
  if (new Set(ids).size !== ids.length) return { error: '같은 카드 사용 건이 두 번 있습니다.' };
  const byId = new Map(txs.map((t) => [t.id, t]));
  const picked = [];
  for (const id of ids) {
    const tx = byId.get(id);
    const card = tx ? cardsById.get(tx.cardId) : null;
    if (!tx || tx.scopeKey !== scopeKey || !card) return { error: '카드 사용 건을 찾을 수 없습니다.', status: 404 };
    // 남의 사용 건은 있는지도 알리지 않는다(가맹점 이름이 새지 않게) — 같은 카드를 함께 쓰는 사람에게만 먼저 가져갔다고 알린다.
    if (!canClaimTx(tx, card, userId)) {
      return (card.holderIds ?? []).includes(userId)
        ? { error: '같은 카드를 쓰는 다른 사람이 먼저 가져간 사용 건입니다.', status: 409 }
        : { error: '카드 사용 건을 찾을 수 없습니다.', status: 404 };
    }
    const status = txStatus(tx);
    if (status === 'excluded') return { error: `제외된 사용 건입니다: ${tx.merchant}`, status: 409 };
    if (status !== 'open') return { error: `이미 지출 결재에 올린 사용 건입니다: ${tx.merchant}`, status: 409 };
    if (tx.amount <= 0) return { error: `승인 취소 건은 청구할 수 없습니다: ${tx.merchant}` };
    picked.push({ tx, card });
  }
  const total = picked.reduce((s, p) => s + p.tx.amount, 0);
  if (Number.isInteger(amount) && amount !== total) {
    return { error: `금액이 카드 사용 합계(${total.toLocaleString('ko-KR')}원)와 다릅니다.` };
  }
  return {
    total,
    snapshot: picked
      .sort((a, b) => new Date(a.tx.usedAt) - new Date(b.tx.usedAt))
      .map(({ tx, card }) => ({
        id: tx.id,
        cardId: card.id,
        cardName: card.name,
        issuer: card.issuer,
        last4: card.last4,
        usedAt: new Date(tx.usedAt).getTime(),
        merchant: tx.merchant,
        merchantBizNo: tx.merchantBizNo ?? null,
        amount: tx.amount,
        approvalNo: tx.approvalNo ?? null,
        memo: tx.memo ?? null,
        receipts: Array.isArray(tx.receipts) ? tx.receipts : [],
      })),
  };
}

/** 사용 건의 메모·분류 입력 → 바꿀 값 | `{ error }`. */
export function parseTxPatch(body, categories) {
  const out = {};
  if (body?.memo !== undefined) {
    const memo = cleanText(body.memo ?? '', TX_MEMO_MAX + 1);
    if ([...memo].length > TX_MEMO_MAX) return { error: `용도는 ${TX_MEMO_MAX}자까지입니다.` };
    out.memo = memo || null;
  }
  if (body?.category !== undefined) {
    if (body.category !== null && body.category !== '' && !categories.includes(body.category)) return { error: '지출 분류를 고르세요.' };
    out.category = body.category || null;
  }
  return { patch: out };
}

/** 연동(API)으로 받은 사용 건 하나 → `{ tx: { last4?, cardId?, usedAt, merchant, merchantBizNo, amount, approvalNo } }` | `{ error }`. */
export function parseFeedTransaction(input) {
  if (!input || typeof input !== 'object') return { error: '사용 건 모양이 아닙니다.' };
  const usedAt = typeof input.usedAt === 'string' && /T/.test(input.usedAt) ? new Date(input.usedAt) : parseUsedAt(input.usedAt ?? input.date, input.time ?? null);
  if (!usedAt || Number.isNaN(usedAt.getTime())) return { error: 'usedAt(사용 시각 — ISO 8601, 예: 2026-10-18T12:30:00+09:00)을 확인하세요.' };
  let amount = parseTxAmount(typeof input.amount === 'number' ? input.amount : String(input.amount ?? ''));
  if (amount === null || amount === 0 || Math.abs(amount) > TX_AMOUNT_MAX) return { error: 'amount(원)를 확인하세요.' };
  if (input.canceled === true && amount > 0) amount = -amount;
  const merchant = cleanText(String(input.merchant ?? ''), TX_MERCHANT_MAX) || '(가맹점 없음)';
  const last4 = input.cardLast4 !== undefined ? last4Of(input.cardLast4) : null;
  const cardId = typeof input.cardId === 'string' ? input.cardId : null;
  if (!last4 && !cardId) return { error: 'cardLast4(카드 끝 4자리) 또는 cardId가 있어야 합니다.' };
  return {
    tx: {
      last4,
      cardId,
      issuer: typeof input.issuer === 'string' ? input.issuer : null,
      usedAt,
      usedOn: seoulDateKey(usedAt),
      merchant,
      merchantBizNo: normalizeBizNo(input.merchantBizNo),
      amount,
      approvalNo: input.approvalNo ? String(input.approvalNo).replace(/\s/g, '').slice(0, 30) || null : null,
    },
  };
}

/** 카드의 한 달 사용 합계(취소 포함 — 제외한 건도 카드 사용이므로 센다)와 한도 대비 비율. */
export function cardMonthUsage(card, txs) {
  const used = txs.filter((t) => t.cardId === card.id).reduce((s, t) => s + t.amount, 0);
  return { used, limit: card.monthlyLimit ?? null, ratio: card.monthlyLimit ? used / card.monthlyLimit : null };
}

/** 범위의 연동 키 모양(ttc_ + 43자). */
export const CARD_FEED_PREFIX = 'ttc_';
export const isCardFeedToken = (t) => typeof t === 'string' && t.startsWith(CARD_FEED_PREFIX) && /^[A-Za-z0-9_-]{40,64}$/.test(t.slice(CARD_FEED_PREFIX.length));
