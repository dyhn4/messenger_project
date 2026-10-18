/**
 * 지출성 결재의 **정산 연결**(순수 규칙) — 승인된 구매 요청·출장 신청(쓸 돈을 미리 허락받은 결재)을 올린 사람이 실제로 쓴 뒤 그 결재에서
 * "정산하기"로 지출 결재를 올리면, 지출 결재가 그 결재를 가리킨다(approval_documents.settles_id, payload.settles — 그때의 제목·번호·
 * 예산). 원래 결재에는 정산 상태(결재 중·정산됨)가 붙고, 지출 결재에는 예산과의 차이가 보인다. 한 결재에 진행 중이거나 승인된 정산은
 * 하나만(반려·회수·취소되면 다시 올릴 수 있다). DB는 groupware.js. `node --test`로 시험한다(test/approvalFormFollowup.test.js).
 */

/** 정산할 수 있는 결재 종류 — 구매 요청(품목 합계)·출장 신청(예상 경비). */
export const SETTLE_KINDS = Object.freeze(['purchase', 'trip']);

/** 정산이 "살아 있는" 상태 — 이런 정산이 있으면 새로 올리지 못한다. */
const ACTIVE = new Set(['pending', 'approved']);

/** 원래 결재의 예산(원) — 구매는 품목 합계, 출장은 예상 경비(비웠으면 null). */
export function settleBudgetOf(doc) {
  const p = doc?.payload ?? {};
  if (doc?.kind === 'purchase') return Number.isFinite(p.total) ? p.total : Number.isFinite(p.values?.items?.total) ? p.values.items.total : null;
  if (doc?.kind === 'trip') return Number.isFinite(p.values?.cost) ? p.values.cost : null;
  return null;
}

/**
 * [source] 결재를 [userId]가 지금 정산할 수 있는지 — [settlements]는 그 결재를 가리키는 지출 결재들(`{ status, title }`).
 * `{ settles: { id, kind, title, docNumber, budget } }`(지출 payload에 적을 것) | `{ error, status }`.
 */
export function checkSettlement({ source, userId, scopeKey, settlements = [] }) {
  if (!source || source.scopeKey !== scopeKey || source.authorId !== userId) {
    return { error: '정산할 결재를 찾을 수 없습니다(내가 올린 결재만 정산합니다).', status: 404 };
  }
  if (!SETTLE_KINDS.includes(source.kind)) return { error: '구매 요청·출장 신청 결재만 정산할 수 있습니다.' };
  if (source.status !== 'approved') return { error: '승인된 결재만 정산할 수 있습니다.', status: 409 };
  const active = settlements.find((s) => ACTIVE.has(s.status));
  if (active) return { error: `이미 정산을 올린 결재입니다: ${active.title}`, status: 409 };
  return {
    settles: {
      id: source.id,
      kind: source.kind,
      title: source.title,
      docNumber: source.docNumber ?? null,
      budget: settleBudgetOf(source),
    },
  };
}

/**
 * 원래 결재에 보일 정산 — 승인된 것, 없으면 결재 중인 것, 없으면 가장 최근 것(반려 등 — 다시 올릴 수 있음). 없으면 null.
 * [settlements]는 `{ id, docNumber, title, status, amount, createdAt }`.
 */
export function settlementOf(settlements = []) {
  if (!settlements.length) return null;
  const latest = (status) =>
    settlements.filter((s) => !status || s.status === status).sort((a, b) => new Date(b.createdAt) - new Date(a.createdAt))[0];
  const s = latest('approved') ?? latest('pending') ?? latest(null);
  return { id: s.id, docNumber: s.docNumber ?? null, title: s.title, status: s.status, amount: Number.isFinite(s.amount) ? s.amount : null };
}

/** [viewerId]가 이 결재에서 "정산하기"를 누를 수 있는지(올린 사람, 승인됨, 살아 있는 정산 없음). */
export const canSettle = (doc, viewerId, settlements = []) =>
  SETTLE_KINDS.includes(doc.kind) &&
  doc.status === 'approved' &&
  doc.authorId === viewerId &&
  !settlements.some((s) => ACTIVE.has(s.status));

/** 정산 금액과 예산의 차이(원 — +면 예산보다 많이 씀). 예산이 없으면 null. */
export const settlementDiff = (budget, amount) => (Number.isFinite(budget) && Number.isFinite(amount) ? amount - budget : null);
