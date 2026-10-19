/**
 * 영수증 읽기(receiptOcr.js)의 순수 규칙 — 서비스마다 다른 응답을 한 모양으로 맞추고(CLOVA OCR 영수증 특화 모델·OpenAI 호환 비전 모델·Claude),
 * 지출 분류를 짐작하고, 읽은 영수증과 법인카드 사용 건을 맞춰 본다. DB 없이 `node --test`로 시험한다(test/receiptOcr.test.js).
 *
 * 맞춘 모양 `{ merchant, bizNo, date('YYYY-MM-DD'), time('HH:MM'), total(원), vat, cardLast4, approvalNo, items: [{ name, qty, amount }] }` —
 * 모르는 값은 null. 영수증 글은 잘못 읽힐 수 있으므로 앱은 늘 "읽은 값 — 확인하세요"로 보여 주고 사람이 고친다.
 */

import { last4Of, normalizeBizNo } from './cardRules.js';

export const RECEIPT_ITEMS_MAX = 30;

/** 비전 모델에게 줄 지시(한국 영수증·카드 매출전표). 응답은 [RECEIPT_SCHEMA] 모양의 JSON 하나. */
export const RECEIPT_PROMPT = [
  '이 이미지는 한국의 영수증(카드 매출전표·간이영수증·세금계산서·온라인 결제 내역 화면 등)입니다. 보이는 글자에서 아래 값을 읽어 JSON 하나로만 답하세요.',
  '- merchant: 가맹점(상호) 이름. 지점명이 있으면 함께.',
  '- bizNo: 가맹점 사업자등록번호(숫자 10자리, 하이픈 포함 가능).',
  '- date: 거래(승인) 날짜 YYYY-MM-DD. 연도가 두 자리면 20xx.',
  '- time: 거래 시각 HH:MM(24시간).',
  '- total: 실제 결제한 합계 금액(원, 숫자만). 할인·포인트를 뺀 최종 금액. 취소 전표면 음수.',
  '- vat: 부가세(원, 숫자만).',
  '- cardLast4: 결제한 카드 번호의 끝 4자리(가려진 자리는 무시).',
  '- approvalNo: 카드 승인번호.',
  '- items: 품목들 [{ name, qty, amount }] (amount는 그 줄의 금액, 원).',
  '읽을 수 없거나 없는 값은 null로 두세요. 짐작으로 채우지 마세요. 영수증이 아니면 모든 값을 null로 두세요.',
].join('\n');

const NULLABLE_STRING = { anyOf: [{ type: 'string' }, { type: 'null' }] };
const NULLABLE_INT = { anyOf: [{ type: 'integer' }, { type: 'null' }] };

/** 구조화 출력용 JSON 스키마(Claude output_config.format — 모든 칸 required, 모르면 null). */
export const RECEIPT_SCHEMA = Object.freeze({
  type: 'object',
  additionalProperties: false,
  required: ['merchant', 'bizNo', 'date', 'time', 'total', 'vat', 'cardLast4', 'approvalNo', 'items'],
  properties: {
    merchant: NULLABLE_STRING,
    bizNo: NULLABLE_STRING,
    date: NULLABLE_STRING,
    time: NULLABLE_STRING,
    total: NULLABLE_INT,
    vat: NULLABLE_INT,
    cardLast4: NULLABLE_STRING,
    approvalNo: NULLABLE_STRING,
    items: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['name', 'qty', 'amount'],
        properties: { name: { type: 'string' }, qty: NULLABLE_INT, amount: NULLABLE_INT },
      },
    },
  },
});

const clean = (v, max = 100) =>
  typeof v === 'string' ? v.replace(/[\u0000-\u001f\u007f‪-‮⁦-⁩]/g, ' ').replace(/\s+/g, ' ').trim().slice(0, max) || null : null;

const toInt = (v) => {
  if (typeof v === 'number') return Number.isFinite(v) ? Math.round(v) : null;
  if (typeof v !== 'string') return null;
  const s = v.replace(/[,\s원₩]/g, '');
  const m = /^-?\d+(\.\d+)?$/.exec(s);
  return m ? Math.round(Number(s)) : null;
};

/** 'YYYY-MM-DD' | null — '2026.10.18', '26/10/18', '2026년 10월 18일'도 받는다. 2000~2100년의 있는 날만. */
export function normalizeDate(v) {
  if (typeof v !== 'string') return null;
  const m = /(\d{2,4})\s*[-./년]\s*(\d{1,2})\s*[-./월]\s*(\d{1,2})/.exec(v) ?? /^(\d{4})(\d{2})(\d{2})$/.exec(v.trim());
  if (!m) return null;
  let y = Number(m[1]);
  if (y < 100) y += 2000;
  const mo = Number(m[2]);
  const d = Number(m[3]);
  const date = new Date(Date.UTC(y, mo - 1, d));
  if (y < 2000 || y > 2100 || date.getUTCMonth() !== mo - 1 || date.getUTCDate() !== d) return null;
  return date.toISOString().slice(0, 10);
}

/** 'HH:MM' | null. */
export function normalizeTime(v) {
  if (typeof v !== 'string') return null;
  const m = /(\d{1,2})\s*[:시]\s*(\d{2})/.exec(v);
  if (!m) return null;
  const h = Number(m[1]);
  const mi = Number(m[2]);
  return h < 24 && mi < 60 ? `${String(h).padStart(2, '0')}:${String(mi).padStart(2, '0')}` : null;
}

/** 어느 서비스든 읽은 값 → 맞춘 모양. 금액은 ±1억 원 안만. */
export function normalizeReceipt(raw) {
  const r = raw && typeof raw === 'object' ? raw : {};
  const total = toInt(r.total);
  const vat = toInt(r.vat);
  const items = (Array.isArray(r.items) ? r.items : [])
    .map((i) => ({ name: clean(i?.name, 60), qty: toInt(i?.qty), amount: toInt(i?.amount) }))
    .filter((i) => i.name)
    .slice(0, RECEIPT_ITEMS_MAX);
  const approval = clean(r.approvalNo, 30)?.replace(/\s/g, '') ?? null;
  return {
    merchant: clean(r.merchant, 100),
    bizNo: normalizeBizNo(r.bizNo),
    date: normalizeDate(r.date),
    time: normalizeTime(r.time),
    total: total !== null && Math.abs(total) <= 100_000_000 && total !== 0 ? total : null,
    vat: vat !== null && vat >= 0 && vat <= 100_000_000 ? vat : null,
    cardLast4: r.cardLast4 ? last4Of(r.cardLast4) : null,
    approvalNo: approval && /\d/.test(approval) ? approval : null,
    items,
  };
}

/** 아무것도 못 읽었는지(영수증이 아니거나 흐림). */
export const isEmptyReceipt = (r) => !r || (!r.merchant && !r.date && r.total === null && !r.approvalNo);

/** 모델이 준 글에서 JSON 하나를 꺼낸다(```json 울타리·앞뒤 말이 붙어도). 못 꺼내면 null. */
export function extractJson(text) {
  if (text && typeof text === 'object') return text;
  if (typeof text !== 'string') return null;
  const fenced = /```(?:json)?\s*([\s\S]*?)```/.exec(text);
  const body = fenced ? fenced[1] : text;
  const start = body.indexOf('{');
  const end = body.lastIndexOf('}');
  if (start < 0 || end <= start) return null;
  try {
    return JSON.parse(body.slice(start, end + 1));
  } catch {
    return null;
  }
}

const textOf = (field) => (field && typeof field === 'object' ? (field.formatted?.value ?? field.text ?? null) : null);

/**
 * CLOVA OCR 영수증 특화 모델(Document OCR > Receipt, V2) 응답 → 맞춘 모양. 값은 `images[0].receipt.result` 아래에 칸마다 `{ text, formatted }`로
 * 온다(formatted가 없는 칸도 있다 — 승인번호). 합계가 없으면 신용카드 결제 금액(totalPrice.creditCardPrice)을 쓴다.
 */
export function normalizeClovaReceipt(json) {
  const image = json?.images?.[0];
  if (image && image.inferResult && image.inferResult !== 'SUCCESS') return normalizeReceipt({});
  const res = image?.receipt?.result ?? {};
  const store = res.storeInfo ?? {};
  const pay = res.paymentInfo ?? {};
  const dateF = pay.date?.formatted;
  const timeF = pay.time?.formatted;
  const date = dateF?.year && dateF?.month && dateF?.day ? `${dateF.year}-${dateF.month}-${dateF.day}` : (pay.date?.text ?? null);
  const time = timeF?.hour && timeF?.minute ? `${timeF.hour}:${timeF.minute}` : (pay.time?.text ?? null);
  const name = [textOf(store.name), textOf(store.subName)].filter(Boolean).join(' ') || null;
  const items = [];
  for (const sub of res.subResults ?? []) {
    for (const it of sub?.items ?? []) {
      items.push({ name: textOf(it.name), qty: textOf(it.count), amount: textOf(it.price?.price) });
    }
  }
  return normalizeReceipt({
    merchant: name,
    bizNo: textOf(store.bizNum),
    date,
    time,
    total: textOf(res.totalPrice?.price) ?? textOf(res.totalPrice?.creditCardPrice),
    vat: textOf(res.totalPrice?.tax) ?? textOf(res.subTotal?.[0]?.taxPrice?.[0]),
    cardLast4: textOf(pay.cardInfo?.number),
    approvalNo: pay.confirmNum?.text ?? null,
    items,
  });
}

// ── 지출 분류 짐작 ──

/** 분류 이름에 담긴 말 → 그 분류로 볼 가맹점·품목 말. 범위의 지출 분류 이름에 왼쪽 말이 들어 있으면 그 분류를 고른다. */
const CATEGORY_HINTS = [
  [['교통', '차량', '유류', '주유'], ['택시', '카카오T', '주유', '오일', '에너지', '셀프', 'SK네트웍스', 'GS칼텍스', 'S-OIL', '현대오일', '코레일', 'KTX', 'SRT', '고속버스', '버스', '지하철', '주차', '하이패스', '톨게이트', '도로공사', '렌터카', '항공', '대한항공', '아시아나', '제주항공', '티머니']],
  [['출장', '숙박'], ['호텔', '모텔', '리조트', '숙박', '에어비앤비', '야놀자', '여기어때']],
  [['식대', '식비', '회식'], ['식당', '음식', '김밥', '분식', '치킨', '피자', '버거', '맥도날드', '롯데리아', '도시락', '한식', '중식', '일식', '국밥', '갈비', '고기', '샤브', '스시', '반점', '배달의민족', '요기요', '쿠팡이츠', '카페', '커피', '스타벅스', '투썸', '이디야', '메가커피', '빽다방', '베이커리', '파리바게뜨', '뚜레쥬르', '편의점', 'CU', 'GS25', '세븐일레븐', '이마트24']],
  [['접대'], ['룸', '주점', '바(bar)', '골프', '한우']],
  [['소모품', '사무', '비품'], ['문구', '오피스', '알파', '다이소', '프린터', '토너', '복사', '용지', '쿠팡', '11번가', 'G마켓', '옥션', '네이버페이', '하이마트', '전자랜드', '이케아', '컴퓨터', '모니터', '키보드', '마우스']],
  [['교육', '도서'], ['교보문고', '영풍문고', 'yes24', '알라딘', '서점', '도서', '교육', '아카데미', '학원', '인프런', '패스트캠퍼스', '클래스101', '세미나']],
  [['통신'], ['KT', 'SKT', 'SK텔레콤', 'LG유플러스', '통신']],
];

/** 영수증(가맹점·품목)으로 범위의 지출 분류 중 하나를 짐작한다 — 못 하면 null. */
export function guessExpenseCategory(receipt, categories) {
  const text = [receipt?.merchant ?? '', ...(receipt?.items ?? []).map((i) => i.name ?? '')].join(' ').toLowerCase();
  if (!text.trim() || !Array.isArray(categories) || categories.length === 0) return null;
  for (const [labels, words] of CATEGORY_HINTS) {
    if (!words.some((w) => text.includes(w.toLowerCase()))) continue;
    // 앞에 적은 말이 먼저(소모품 > 사무 > 비품).
    for (const label of labels) {
      const category = categories.find((c) => c.includes(label));
      if (category) return category;
    }
  }
  return null;
}

// ── 카드 사용 건과 맞춰 보기 ──

const DAY_MS = 86400_000;
const seoulKeyOf = (date) => new Date(new Date(date).getTime() + 9 * 3600_000).toISOString().slice(0, 10);
const normMerchant = (m) => String(m ?? '').replace(/\(주\)|㈜|주식회사|\s/g, '').toLowerCase();

/**
 * 읽은 영수증과 사용 건들([txs] — `{ id, usedAt, merchant, amount, approvalNo, cardLast4 }`)을 맞춰 점수 높은 순으로(10개까지). 승인번호가
 * 같으면 거의 확실, 아니면 금액이 같고 날짜가 하루 안·카드 끝 4자리·가맹점 이름이 맞을수록 높다. 금액이 다르면 후보가 아니다(승인번호가 같은
 * 건은 금액이 달라도 — 부분 취소·팁). `[{ id, score, reasons }]`.
 */
export function matchReceiptToTransactions(receipt, txs) {
  if (!receipt) return [];
  const out = [];
  for (const tx of txs) {
    const reasons = [];
    let score = 0;
    const sameNo = receipt.approvalNo && tx.approvalNo && String(tx.approvalNo).replace(/^0+/, '') === receipt.approvalNo.replace(/^0+/, '');
    const sameAmount = receipt.total !== null && receipt.total === tx.amount;
    if (!sameNo && !sameAmount) continue;
    if (sameNo) {
      score += 100;
      reasons.push('approvalNo');
    }
    if (sameAmount) {
      score += 40;
      reasons.push('amount');
    }
    if (receipt.date) {
      const diff = Math.abs(Date.parse(`${receipt.date}T00:00:00Z`) - Date.parse(`${seoulKeyOf(tx.usedAt)}T00:00:00Z`)) / DAY_MS;
      if (diff === 0) {
        score += 30;
        reasons.push('date');
      } else if (diff <= 1) score += 15;
      else if (!sameNo) continue;
    }
    if (receipt.cardLast4 && tx.cardLast4 && receipt.cardLast4 === tx.cardLast4) {
      score += 20;
      reasons.push('card');
    }
    const a = normMerchant(receipt.merchant);
    const b = normMerchant(tx.merchant);
    if (a && b && (a.includes(b) || b.includes(a) || (a.length >= 2 && b.length >= 2 && a.slice(0, 2) === b.slice(0, 2)))) {
      score += 15;
      reasons.push('merchant');
    }
    out.push({ id: tx.id, score, reasons });
  }
  return out.sort((x, y) => y.score - x.score).slice(0, 10);
}

/** 영수증과 사용 건이 어긋나는 점 — 앱이 "영수증 금액이 다릅니다" 같은 안내로 보여 준다. `['amount' | 'date' | 'card']`. */
export function receiptMismatches(receipt, tx) {
  if (!receipt || !tx) return [];
  const out = [];
  if (receipt.total !== null && receipt.total !== tx.amount) out.push('amount');
  if (receipt.date && receipt.date !== seoulKeyOf(tx.usedAt)) {
    const diff = Math.abs(Date.parse(`${receipt.date}T00:00:00Z`) - Date.parse(`${seoulKeyOf(tx.usedAt)}T00:00:00Z`)) / DAY_MS;
    if (diff > 1) out.push('date');
  }
  if (receipt.cardLast4 && tx.cardLast4 && receipt.cardLast4 !== tx.cardLast4) out.push('card');
  return out;
}

/** 읽을 수 있는 파일 형식 — 이미지(JPEG·PNG·WebP·GIF·TIFF·AVIF — sharp로 줄여 JPEG로)와 PDF(Claude·CLOVA만). */
export function receiptInputKind(mimeType, fileName) {
  const mime = String(mimeType ?? '').toLowerCase();
  const name = String(fileName ?? '').toLowerCase();
  if (mime === 'application/pdf' || name.endsWith('.pdf')) return 'pdf';
  if (/^image\/(jpeg|jpg|png|webp|gif|tiff|avif)$/.test(mime) || /\.(jpe?g|png|webp|gif|tiff?|avif)$/.test(name)) return 'image';
  if (/heic|heif/.test(mime) || /\.(heic|heif)$/.test(name)) return 'heic';
  return null;
}
