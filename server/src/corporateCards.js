import crypto from 'node:crypto';
import ExcelJS from 'exceljs';
import express, { Router } from 'express';
import { AUDIT, recordAudit } from './audit.js';
import { limits, retryLater, waitText } from './authGuard.js';
import {
  CARD_FEED_PREFIX,
  CARDS_MAX,
  canClaimTx,
  cardMonthUsage,
  duplicateCard,
  EXCLUDE_REASON_MAX,
  isCardFeedToken,
  pairCancellations,
  parseCardInput,
  parseFeedTransaction,
  parseStatementRows,
  parseTxAmount,
  parseTxPatch,
  parseUsedAt,
  seoulDateKey,
  TX_IMPORT_MAX,
  TX_MERCHANT_MAX,
  txDedupeKey,
  txStatus,
} from './cardRules.js';
import { lookupHash } from './crypto.js';
import {
  deleteCard,
  deleteFeedKey,
  deleteTransaction,
  excludeTransactions,
  findCard,
  findFeedKey,
  findFeedKeyByHash,
  findTransaction,
  insertCard,
  insertTransactions,
  listCards,
  listTransactions,
  touchFeedKey,
  updateCard,
  updateTransaction,
  upsertFeedKey,
} from './db/queries/corporateCards.js';
import { listGroupwareMembers } from './db/queries/groupware.js';
import { isUuid } from './favoritesRules.js';
import { checkFileRefs } from './fileRefs.js';
import { approverCandidates, fail, groupwareContext, parseAttachments } from './groupware.js';
import { notifyGroupwarePush } from './push.js';
import { readReceipt, ReceiptOcrError, receiptOcrEnabled } from './receiptOcr.js';
import { guessExpenseCategory, isEmptyReceipt, matchReceiptToTransactions, receiptMismatches } from './receiptOcrRules.js';
import { readSheetRows } from './sheetRows.js';
import { knownUploadPath, signFileUrl } from './upload.js';

const ms = (v) => (v ? new Date(v).getTime() : null);
const thisMonth = () => seoulDateKey(new Date()).slice(0, 7);
const isMonth = (v) => typeof v === 'string' && /^\d{4}-(0[1-9]|1[0-2])$/.test(v);
const monthRange = (month) => {
  const [y, m] = month.split('-').map(Number);
  const last = new Date(Date.UTC(y, m, 0)).getUTCDate();
  return { from: `${month}-01`, to: `${month}-${String(last).padStart(2, '0')}` };
};

/** 미정산 알림을 마지막으로 보낸 때(범위마다 — 한 시간에 한 번). */
const lastReminder = new Map();

/**
 * 법인카드 — 그룹웨어 관리자가 카드(이름·카드사·끝 4자리·사용자·월 한도)를 등록하고, 카드사 이용내역(엑셀·CSV — 카드사 홈페이지에서 받은 그대로)을
 * 가져오거나 연동 키로 바깥 서비스가 사용 건을 밀어 넣는다(createCardFeedRouter). 사용자는 그룹웨어 → 지출 탭의 "내 법인카드"에서 자기 사용 건에
 * 영수증(읽기 — receiptOcr.js)·용도를 붙여 여러 건을 한 번에 지출 결재로 청구한다(groupware.js 지출 결재의 cardTransactionIds — 금액은 합계와 같아야).
 * 상태(미정산·결재 중·정산됨·제외)는 연결된 결재의 상태로 정해진다(반려·회수되면 다시 청구). 규칙은 cardRules.js.
 *
 * 화면 갱신은 groupware:changed `{ cards: true }`.
 */
export function createCorporateCardsRouter(io) {
  const router = Router();

  const withCards =
    (handler, { managerOnly = false } = {}) =>
    async (req, res) => {
      const ctx = await groupwareContext(req.user.sub, req.query.teamId ?? (Buffer.isBuffer(req.body) ? null : req.body?.teamId));
      if (ctx.error) return fail(res, ctx);
      if (managerOnly && !ctx.isManager) return fail(res, { error: '결재·근태 관리자만 할 수 있습니다.', status: 403 });
      const cards = await listCards(ctx.scopeKey);
      const cardsById = new Map(cards.map((c) => [c.id, c]));
      const myCardIds = cards.filter((c) => (c.holderIds ?? []).includes(ctx.user.id)).map((c) => c.id);
      return handler(req, res, { ...ctx, cards, cardsById, myCardIds });
    };

  const actorName = (ctx) => ctx.user.name ?? ctx.user.username;

  function audit(ctx, action, { targetId = null, targetLabel = null, detail }) {
    recordAudit({
      actorId: ctx.user.id,
      actorName: actorName(ctx),
      action,
      teamId: ctx.teamId,
      teamName: ctx.team?.name ?? null,
      targetType: 'card',
      targetId,
      targetLabel,
      detail,
    });
  }

  /** 화면을 다시 받게 — 그 카드 사용자들과(주면) 사람들, 나. */
  function emitChanged(ctx, { cards = [], userIds = [] } = {}) {
    const ids = new Set([ctx.user.id, ...userIds, ...cards.flatMap((c) => c?.holderIds ?? [])].filter(Boolean));
    for (const id of ids) io.to(`user:${id}`).emit('groupware:changed', { cards: true, scopeKey: ctx.scopeKey });
  }

  async function namesOf(ctx) {
    const members = await listGroupwareMembers({ scope: ctx.scope, teamId: ctx.teamId });
    const map = new Map(members.map((m) => [m.id, m.name]));
    return (id) => (id ? (map.get(id) ?? '(알 수 없음)') : null);
  }

  const cardDto = (card, nameOf, usage = null) => ({
    id: card.id,
    name: card.name,
    issuer: card.issuer,
    last4: card.last4,
    holderIds: card.holderIds ?? [],
    holders: (card.holderIds ?? []).map((id) => ({ id, name: nameOf(id) })),
    monthlyLimit: card.monthlyLimit ?? null,
    memo: card.memo ?? null,
    enabled: card.enabled,
    ...(usage && { used: usage.used }),
  });

  /** [viewer]가 이 사용 건을 볼 수 있는지 — 관리자, 사용자로 정해진 사람, (정해지지 않았으면) 그 카드의 사용자. */
  const canView = (ctx, tx) => ctx.isManager || tx.userId === ctx.user.id || (!tx.userId && ctx.myCardIds.includes(tx.cardId));

  /** 영수증·용도·분류를 고칠 수 있는지 — 미정산이고 (내 것 | 관리자). */
  const canEdit = (ctx, tx) => txStatus(tx) === 'open' && (ctx.isManager || canClaimTx(tx, ctx.cardsById.get(tx.cardId), ctx.user.id));

  function txDto(ctx, tx, nameOf) {
    const card = ctx.cardsById.get(tx.cardId);
    const status = txStatus(tx);
    return {
      id: tx.id,
      cardId: tx.cardId,
      cardName: card?.name ?? '',
      issuer: card?.issuer ?? '',
      last4: card?.last4 ?? '',
      usedAt: ms(tx.usedAt),
      usedOn: tx.usedOn,
      merchant: tx.merchant,
      merchantBizNo: tx.merchantBizNo ?? null,
      amount: tx.amount,
      approvalNo: tx.approvalNo ?? null,
      source: tx.source,
      userId: tx.userId ?? null,
      userName: nameOf(tx.userId),
      memo: tx.memo ?? null,
      category: tx.category ?? null,
      receipts: (Array.isArray(tx.receipts) ? tx.receipts : []).map((a) => ({
        fileUrl: signFileUrl(a.fileUrl, a.fileName ?? undefined) ?? null,
        fileName: a.fileName ?? null,
        fileSize: a.fileSize ?? null,
        mimeType: a.mimeType ?? null,
      })),
      receiptScan: tx.receiptScan ?? null,
      // 읽은 영수증과 어긋나는 점('amount' | 'date' | 'card').
      mismatches: receiptMismatches(tx.receiptScan, { ...tx, cardLast4: card?.last4 }),
      status,
      expense: tx.expenseDocId && tx.expenseStatus
        ? { id: tx.expenseDocId, docNumber: tx.expenseDocNumber ?? null, title: tx.expenseTitle ?? null, status: tx.expenseStatus }
        : null,
      excludedAt: ms(tx.excludedAt),
      excludedReason: tx.excludedReason ?? null,
      excludedByName: tx.excludedByName ?? null,
      canEdit: canEdit(ctx, tx),
      canClaim: status === 'open' && tx.amount > 0 && canClaimTx(tx, card, ctx.user.id),
      // 여럿이 쓰는 카드의 정해지지 않은 건 — "내가 씀"으로 가져갈 수 있다.
      unassigned: !tx.userId,
    };
  }

  async function loadTx(req, res, ctx) {
    const tx = isUuid(req.params.id) ? await findTransaction(req.params.id) : null;
    if (!tx || tx.scopeKey !== ctx.scopeKey || !canView(ctx, tx)) {
      fail(res, { error: '카드 사용 건을 찾을 수 없습니다.', status: 404 });
      return null;
    }
    return tx;
  }

  /** 승인 취소 짝짓기 — 이 카드들의 최근 사용 건에서 짝을 찾아 둘 다 "승인 취소"로 뺀다. 짝지은 수. */
  async function pairCancels(ctx, cardIds, from) {
    if (!cardIds.length) return 0;
    const txs = await listTransactions({ scopeKey: ctx.scopeKey, from, cardIds });
    const pairs = pairCancellations(txs);
    if (pairs.length) await excludeTransactions(pairs.flat(), { reason: '승인 취소', byName: '자동' });
    return pairs.length;
  }

  // ── 카드 ──

  /** 카드들 — 관리자는 모두(이번 달 사용 합계와 함께, ?month=), 사용자는 내가 쓰는 카드. */
  router.get(
    '/groupware/cards',
    withCards(async (req, res, ctx) => {
      const month = isMonth(req.query.month) ? req.query.month : thisMonth();
      const visible = ctx.isManager ? ctx.cards : ctx.cards.filter((c) => ctx.myCardIds.includes(c.id));
      const { from, to } = monthRange(month);
      const txs = visible.length ? await listTransactions({ scopeKey: ctx.scopeKey, from, to, cardIds: visible.map((c) => c.id) }) : [];
      const nameOf = await namesOf(ctx);
      res.json({ month, cards: visible.map((c) => cardDto(c, nameOf, cardMonthUsage(c, txs))), isManager: ctx.isManager });
    }),
  );

  router.post(
    '/groupware/cards',
    withCards(
      async (req, res, ctx) => {
        const people = await approverCandidates(ctx);
        const parsed = parseCardInput(req.body, { isCandidate: (id) => people.has(id) });
        if (parsed.error) return fail(res, parsed);
        if (ctx.cards.length >= CARDS_MAX) return fail(res, { error: `카드는 ${CARDS_MAX}장까지 등록할 수 있습니다.` });
        const dup = duplicateCard(ctx.cards, parsed.card);
        if (dup) return fail(res, { error: `끝 4자리가 같은 카드가 이미 있습니다: ${dup.name}`, status: 409 });
        const card = await insertCard({ ...parsed.card, scopeKey: ctx.scopeKey, teamId: ctx.teamId });
        audit(ctx, AUDIT.cardManage, { targetId: card.id, targetLabel: card.name, detail: `법인카드 등록 — ${card.name} (${card.issuer} ${card.last4})` });
        emitChanged(ctx, { cards: [card] });
        res.status(201).json(cardDto(card, await namesOf(ctx)));
      },
      { managerOnly: true },
    ),
  );

  router.patch(
    '/groupware/cards/:id',
    withCards(
      async (req, res, ctx) => {
        const card = isUuid(req.params.id) ? ctx.cardsById.get(req.params.id) : null;
        if (!card) return fail(res, { error: '카드를 찾을 수 없습니다.', status: 404 });
        const people = await approverCandidates(ctx);
        const parsed = parseCardInput(req.body, { partial: true, isCandidate: (id) => people.has(id) || (card.holderIds ?? []).includes(id) });
        if (parsed.error) return fail(res, parsed);
        const next = { ...card, ...parsed.card };
        const dup = duplicateCard(ctx.cards, next, card.id);
        if (dup) return fail(res, { error: `끝 4자리가 같은 카드가 이미 있습니다: ${dup.name}`, status: 409 });
        const row = await updateCard(card.id, parsed.card);
        audit(ctx, AUDIT.cardManage, { targetId: card.id, targetLabel: row.name, detail: `법인카드 변경 — ${row.name}` });
        emitChanged(ctx, { cards: [card, row] });
        res.json(cardDto(row, await namesOf(ctx)));
      },
      { managerOnly: true },
    ),
  );

  /** 카드 지우기 — 사용 건도 지워진다(이미 올린 지출 결재에는 그때의 사용 건이 적혀 있어 그대로 보인다). */
  router.delete(
    '/groupware/cards/:id',
    withCards(
      async (req, res, ctx) => {
        const card = isUuid(req.params.id) ? ctx.cardsById.get(req.params.id) : null;
        if (!card) return fail(res, { error: '카드를 찾을 수 없습니다.', status: 404 });
        await deleteCard(card.id);
        audit(ctx, AUDIT.cardManage, { targetId: card.id, targetLabel: card.name, detail: `법인카드 삭제 — ${card.name} (${card.issuer} ${card.last4})` });
        emitChanged(ctx, { cards: [card] });
        res.json({ ok: true });
      },
      { managerOnly: true },
    ),
  );

  // ── 사용 건 ──

  /**
   * 사용 건 `?month=YYYY-MM&cardId=&status=&mine=1` — 사용자는 늘 내 것(내 이름이거나, 정해지지 않은 내 카드의 것), 관리자는 ?mine=1이 아니면 모두.
   * 합계(전체·미정산·결재 중·정산됨)와 함께.
   */
  router.get(
    '/groupware/card-transactions',
    withCards(async (req, res, ctx) => {
      const month = isMonth(req.query.month) ? req.query.month : req.query.month === 'open' ? null : thisMonth();
      const range = month ? monthRange(month) : { from: null, to: null };
      const mine = !ctx.isManager || req.query.mine === '1';
      const cardIds = isUuid(req.query.cardId) ? [req.query.cardId] : null;
      let txs = await listTransactions({
        scopeKey: ctx.scopeKey,
        ...range,
        cardIds,
        ...(mine && { userId: ctx.user.id, holderCardIds: ctx.myCardIds }),
      });
      // ?month=open — 기간과 상관없이 아직 청구하지 않은 내 것(지출 탭의 "청구할 사용 건").
      if (!month) txs = txs.filter((t) => txStatus(t) === 'open' && t.amount > 0);
      const nameOf = await namesOf(ctx);
      let items = txs.map((t) => txDto(ctx, t, nameOf));
      const status = typeof req.query.status === 'string' ? req.query.status : null;
      const sum = (list) => list.reduce((s, t) => s + t.amount, 0);
      const totals = {
        all: sum(items),
        open: sum(items.filter((t) => t.status === 'open')),
        claiming: sum(items.filter((t) => t.status === 'claiming')),
        settled: sum(items.filter((t) => t.status === 'settled')),
        excluded: sum(items.filter((t) => t.status === 'excluded')),
        openCount: items.filter((t) => t.status === 'open' && t.amount > 0).length,
      };
      if (status) items = items.filter((t) => t.status === status);
      res.json({ month, mine, items, totals });
    }),
  );

  /** 사용 건 직접 넣기(관리자) `{ cardId, usedAt | date+time, merchant, amount, approvalNo?, userId? }`. */
  router.post(
    '/groupware/card-transactions',
    withCards(
      async (req, res, ctx) => {
        const body = req.body ?? {};
        const card = isUuid(body.cardId) ? ctx.cardsById.get(body.cardId) : null;
        if (!card) return fail(res, { error: '카드를 고르세요.' });
        const usedAt = typeof body.usedAt === 'number' ? new Date(body.usedAt) : parseUsedAt(body.date ?? body.usedAt, body.time ?? null);
        if (!usedAt || Number.isNaN(usedAt.getTime())) return fail(res, { error: '사용 날짜를 확인하세요.' });
        const amount = parseTxAmount(typeof body.amount === 'number' ? body.amount : String(body.amount ?? ''));
        if (!amount) return fail(res, { error: '금액을 원 단위로 넣으세요(취소는 음수).' });
        const merchant = typeof body.merchant === 'string' ? body.merchant.trim().slice(0, TX_MERCHANT_MAX) : '';
        if (!merchant) return fail(res, { error: '가맹점을 쓰세요.' });
        const approvalNo = typeof body.approvalNo === 'string' ? body.approvalNo.replace(/\s/g, '').slice(0, 30) || null : null;
        const holders = card.holderIds ?? [];
        const userId = isUuid(body.userId) && holders.includes(body.userId) ? body.userId : holders.length === 1 ? holders[0] : null;
        const [row] = await insertTransactions([
          {
            scopeKey: ctx.scopeKey,
            cardId: card.id,
            usedAt,
            usedOn: seoulDateKey(usedAt),
            merchant,
            amount,
            approvalNo,
            source: 'manual',
            dedupeKey: txDedupeKey({ approvalNo, usedAt, amount, merchant }),
            userId,
          },
        ]);
        if (!row) return fail(res, { error: '같은 사용 건이 이미 있습니다.', status: 409 });
        await pairCancels(ctx, [card.id], seoulDateKey(new Date(usedAt.getTime() - 40 * 86400_000)));
        emitChanged(ctx, { cards: [card] });
        res.status(201).json(txDto(ctx, (await findTransaction(row.id)) ?? row, await namesOf(ctx)));
      },
      { managerOnly: true },
    ),
  );

  /**
   * 카드사 이용내역 가져오기 `?cardId=&dryRun=1`(본문은 카드사에서 받은 엑셀·CSV·HTML 엑셀 그대로, 10MB까지) — 머리 줄(이용일자·가맹점·이용금액 등)을
   * 찾아 줄마다 사용 건으로(cardRules.js parseStatementRows). 카드는 [cardId]로 정하거나 카드 번호 열의 끝 4자리로 찾는다. 같은 건은 건너뛰고
   * (다시 올려도 된다), 사용자가 한 명인 카드는 그 사람 것으로, 승인 취소는 짝을 지어 뺀다. 미리 보기면 읽은 수·새 건 수·오류만.
   */
  router.post(
    '/groupware/card-transactions/import',
    express.raw({ type: () => true, limit: '10mb' }),
    withCards(
      async (req, res, ctx) => {
        const fixedCard = isUuid(req.query.cardId) ? ctx.cardsById.get(req.query.cardId) : null;
        if (req.query.cardId && !fixedCard) return fail(res, { error: '카드를 찾을 수 없습니다.', status: 404 });
        if (!ctx.cards.length) return fail(res, { error: '먼저 카드를 등록하세요.' });
        const sheet = await readSheetRows(req.body);
        if (sheet.error) return fail(res, sheet);
        const byLast4 = (last4) => {
          const found = ctx.cards.filter((c) => c.last4 === last4);
          return found.length === 1 ? found[0] : null;
        };
        const parsed = parseStatementRows(sheet.rows, { fixedCard, cardOf: byLast4 });
        if (parsed.error) return fail(res, parsed);
        if (parsed.rows.length > TX_IMPORT_MAX) return fail(res, { error: `한 번에 ${TX_IMPORT_MAX}건까지 가져올 수 있습니다.` });
        const values = parsed.rows.map((r) => {
          const card = ctx.cardsById.get(r.cardId);
          const holders = card.holderIds ?? [];
          return {
            scopeKey: ctx.scopeKey,
            cardId: r.cardId,
            usedAt: r.usedAt,
            usedOn: r.usedOn,
            merchant: r.merchant,
            merchantBizNo: r.merchantBizNo,
            amount: r.amount,
            approvalNo: r.approvalNo,
            source: 'excel',
            dedupeKey: txDedupeKey(r),
            userId: holders.length === 1 ? holders[0] : null,
          };
        });
        // 같은 파일 안의 중복도 하나로(키가 같으면 처음 것).
        const unique = [...new Map(values.map((v) => [`${v.cardId}|${v.dedupeKey}`, v])).values()];
        const cardIds = [...new Set(unique.map((v) => v.cardId))];
        const range = unique.length
          ? { from: unique.reduce((m, v) => (v.usedOn < m ? v.usedOn : m), unique[0].usedOn), to: unique.reduce((m, v) => (v.usedOn > m ? v.usedOn : m), unique[0].usedOn) }
          : null;
        const existing = range ? await listTransactions({ scopeKey: ctx.scopeKey, ...range, cardIds }) : [];
        const known = new Set(existing.map((t) => `${t.cardId}|${t.dedupeKey}`));
        const fresh = unique.filter((v) => !known.has(`${v.cardId}|${v.dedupeKey}`));
        const summary = {
          read: parsed.rows.length,
          fresh: fresh.length,
          duplicates: parsed.rows.length - fresh.length,
          errors: parsed.errors.slice(0, 200),
          from: range?.from ?? null,
          to: range?.to ?? null,
          total: fresh.reduce((s, v) => s + v.amount, 0),
        };
        if (req.query.dryRun === '1') return res.json({ ...summary, applied: false });
        const inserted = await insertTransactions(fresh);
        const paired = range ? await pairCancels(ctx, cardIds, seoulDateKey(new Date(Date.parse(`${range.from}T00:00:00Z`) - 40 * 86400_000))) : 0;
        const names = cardIds.map((id) => ctx.cardsById.get(id)?.name).filter(Boolean).join(', ');
        audit(ctx, AUDIT.cardImport, { detail: `법인카드 이용내역 가져오기 — ${names}: ${inserted.length}건(${summary.from ?? ''}~${summary.to ?? ''})` });
        emitChanged(ctx, { cards: cardIds.map((id) => ctx.cardsById.get(id)) });
        res.json({ ...summary, inserted: inserted.length, paired, applied: true });
      },
      { managerOnly: true },
    ),
  );

  /**
   * 사용 건 고치기 `{ memo?, category?, receipts?, mine?: true | false, userId?(관리자) }` — 영수증·용도·분류는 미정산일 때 내 것(또는 관리자).
   * mine: true는 여럿이 쓰는 카드의 정해지지 않은 건을 내 것으로, false는 내 것을 다시 정해지지 않은 것으로(사용자가 여럿인 카드만).
   */
  router.patch(
    '/groupware/card-transactions/:id',
    withCards(async (req, res, ctx) => {
      const tx = await loadTx(req, res, ctx);
      if (!tx) return;
      const body = req.body ?? {};
      const card = ctx.cardsById.get(tx.cardId);
      const patch = {};
      if (body.mine !== undefined || body.userId !== undefined) {
        if (txStatus(tx) !== 'open') return fail(res, { error: '청구한 사용 건은 사용자를 바꿀 수 없습니다.', status: 409 });
        if (body.userId !== undefined) {
          if (!ctx.isManager) return fail(res, { error: '관리자만 사용자를 정할 수 있습니다.', status: 403 });
          if (body.userId !== null && !(card?.holderIds ?? []).includes(body.userId)) return fail(res, { error: '그 카드의 사용자만 고를 수 있습니다.' });
          patch.userId = body.userId;
        } else if (body.mine === true) {
          if (tx.userId && tx.userId !== ctx.user.id) return fail(res, { error: '다른 사람의 사용 건입니다.', status: 409 });
          if (!(card?.holderIds ?? []).includes(ctx.user.id)) return fail(res, { error: '내가 쓰는 카드가 아닙니다.', status: 403 });
          patch.userId = ctx.user.id;
        } else {
          if (tx.userId !== ctx.user.id) return fail(res, { error: '내 사용 건이 아닙니다.', status: 403 });
          if ((card?.holderIds ?? []).length < 2) return fail(res, { error: '혼자 쓰는 카드의 사용 건입니다.' });
          patch.userId = null;
        }
      }
      if (body.memo !== undefined || body.category !== undefined || body.receipts !== undefined) {
        if (!canEdit(ctx, tx)) return fail(res, { error: '청구했거나 내 것이 아닌 사용 건은 고칠 수 없습니다.', status: 409 });
        const p = parseTxPatch(body, ctx.options.expenseCategories);
        if (p.error) return fail(res, p);
        Object.assign(patch, p.patch);
        if (body.receipts !== undefined) {
          // 이미 붙어 있던 영수증(서명 링크로 돌아온다)은 그대로, 새 영수증은 내가 올린 파일만.
          const kept = [];
          const incoming = [];
          const current = Array.isArray(tx.receipts) ? tx.receipts : [];
          for (const r of Array.isArray(body.receipts) ? body.receipts : []) {
            const same = current.find((c) => knownUploadPath(r?.fileUrl) === c.fileUrl);
            if (same) kept.push(same);
            else incoming.push(r);
          }
          const files = await parseAttachments(incoming, ctx.user.id);
          if (files.error) return fail(res, files);
          const receipts = [...kept, ...files.attachments];
          if (receipts.length > 5) return fail(res, { error: '영수증은 5개까지입니다.' });
          patch.receipts = receipts;
          if (!receipts.length) patch.receiptScan = null;
        }
      }
      if (!Object.keys(patch).length) return res.json(txDto(ctx, tx, await namesOf(ctx)));
      await updateTransaction(tx.id, patch);
      emitChanged(ctx, { cards: [card], userIds: [tx.userId] });
      res.json(txDto(ctx, await findTransaction(tx.id), await namesOf(ctx)));
    }),
  );

  /** 제외(관리자) `{ reason }` — 개인 사용(반납)·중복·카드사 오류 등. 청구하지 않은 건만. */
  router.post(
    '/groupware/card-transactions/:id/exclude',
    withCards(
      async (req, res, ctx) => {
        const tx = await loadTx(req, res, ctx);
        if (!tx) return;
        if (txStatus(tx) !== 'open') return fail(res, { error: '청구한 사용 건은 제외할 수 없습니다.', status: 409 });
        const reason = typeof req.body?.reason === 'string' ? req.body.reason.trim().slice(0, EXCLUDE_REASON_MAX) : '';
        if (!reason) return fail(res, { error: '제외하는 사유를 쓰세요.' });
        await updateTransaction(tx.id, { excludedAt: new Date(), excludedReason: reason, excludedByName: actorName(ctx) });
        audit(ctx, AUDIT.cardExclude, { targetId: tx.id, targetLabel: tx.merchant, detail: `법인카드 사용 건 제외 — ${tx.merchant} ${tx.amount.toLocaleString('ko-KR')}원: ${reason}` });
        emitChanged(ctx, { cards: [ctx.cardsById.get(tx.cardId)], userIds: [tx.userId] });
        res.json(txDto(ctx, await findTransaction(tx.id), await namesOf(ctx)));
      },
      { managerOnly: true },
    ),
  );

  router.delete(
    '/groupware/card-transactions/:id/exclude',
    withCards(
      async (req, res, ctx) => {
        const tx = await loadTx(req, res, ctx);
        if (!tx) return;
        if (!tx.excludedAt) return res.json(txDto(ctx, tx, await namesOf(ctx)));
        await updateTransaction(tx.id, { excludedAt: null, excludedReason: null, excludedByName: null });
        audit(ctx, AUDIT.cardExclude, { targetId: tx.id, targetLabel: tx.merchant, detail: `법인카드 사용 건 제외 풀기 — ${tx.merchant}` });
        emitChanged(ctx, { cards: [ctx.cardsById.get(tx.cardId)], userIds: [tx.userId] });
        res.json(txDto(ctx, await findTransaction(tx.id), await namesOf(ctx)));
      },
      { managerOnly: true },
    ),
  );

  /** 사용 건 지우기(관리자 — 잘못 넣은 건). 지출 결재에 묶인 적 없는 미정산·제외 건만. */
  router.delete(
    '/groupware/card-transactions/:id',
    withCards(
      async (req, res, ctx) => {
        const tx = await loadTx(req, res, ctx);
        if (!tx) return;
        if (['claiming', 'settled'].includes(txStatus(tx))) return fail(res, { error: '청구한 사용 건은 지울 수 없습니다.', status: 409 });
        await deleteTransaction(tx.id);
        emitChanged(ctx, { cards: [ctx.cardsById.get(tx.cardId)], userIds: [tx.userId] });
        res.json({ ok: true });
      },
      { managerOnly: true },
    ),
  );

  /** 미정산 알림(관리자) `{ month? }` — 그 달(없으면 모든 달)에 청구하지 않은 사용 건이 있는 사람에게 그룹웨어 푸시. 범위마다 한 시간에 한 번. */
  router.post(
    '/groupware/card-transactions/remind',
    withCards(
      async (req, res, ctx) => {
        const last = lastReminder.get(ctx.scopeKey) ?? 0;
        if (Date.now() - last < 60 * 60_000) {
          return retryLater(res, 60 * 60_000 - (Date.now() - last), `방금 알렸습니다. ${waitText(60 * 60_000 - (Date.now() - last))} 뒤에 다시 보낼 수 있습니다.`);
        }
        const month = isMonth(req.body?.month) ? req.body.month : null;
        const txs = (await listTransactions({ scopeKey: ctx.scopeKey, ...(month ? monthRange(month) : {}) })).filter(
          (t) => txStatus(t) === 'open' && t.amount > 0,
        );
        const counts = new Map();
        for (const t of txs) {
          const targets = t.userId ? [t.userId] : (ctx.cardsById.get(t.cardId)?.holderIds ?? []);
          for (const id of targets) counts.set(id, (counts.get(id) ?? 0) + 1);
        }
        lastReminder.set(ctx.scopeKey, Date.now());
        for (const [userId, n] of counts) {
          notifyGroupwarePush({
            userId,
            title: '법인카드 정산',
            body: `청구하지 않은 법인카드 사용 건이 ${n}건 있습니다. 그룹웨어 → 지출에서 영수증을 붙여 청구하세요.`,
            documentId: '',
            teamId: ctx.teamId,
          }).catch((e) => console.error('[cards] 푸시 실패:', e?.message ?? e));
          io.to(`user:${userId}`).emit('groupware:changed', { cards: true, scopeKey: ctx.scopeKey });
        }
        res.json({ notified: counts.size, transactions: txs.length });
      },
      { managerOnly: true },
    ),
  );

  /** 한 달 사용 건 엑셀(관리자) — 카드·사용 시각·가맹점·사업자번호·금액·승인번호·사용자·용도·분류·상태·지출 결재·영수증 수. */
  router.get(
    '/groupware/card-transactions/export',
    withCards(
      async (req, res, ctx) => {
        const month = isMonth(req.query.month) ? req.query.month : thisMonth();
        const txs = await listTransactions({ scopeKey: ctx.scopeKey, ...monthRange(month) });
        const nameOf = await namesOf(ctx);
        const label = { open: '미정산', claiming: '결재 중', settled: '정산됨', excluded: '제외' };
        const wb = new ExcelJS.Workbook();
        const ws = wb.addWorksheet('법인카드 사용 내역');
        const header = ['카드', '카드사', '끝 4자리', '사용 일시', '가맹점', '사업자번호', '금액', '승인번호', '사용자', '용도', '분류', '상태', '지출 결재', '영수증', '제외 사유'];
        ws.addRow(header).font = { bold: true };
        for (const t of [...txs].sort((a, b) => new Date(a.usedAt) - new Date(b.usedAt))) {
          const dto = txDto(ctx, t, nameOf);
          ws.addRow([
            dto.cardName,
            dto.issuer,
            dto.last4,
            new Date(t.usedAt.getTime() + 9 * 3600_000).toISOString().slice(0, 16).replace('T', ' '),
            dto.merchant,
            dto.merchantBizNo ?? '',
            dto.amount,
            dto.approvalNo ?? '',
            dto.userName ?? '',
            dto.memo ?? '',
            dto.category ?? '',
            label[dto.status],
            dto.expense ? `${dto.expense.docNumber ?? ''} ${dto.expense.title ?? ''}`.trim() : '',
            dto.receipts.length,
            dto.excludedReason ?? '',
          ]);
        }
        [16, 8, 8, 17, 30, 14, 12, 12, 10, 30, 10, 8, 30, 6, 20].forEach((w, i) => (ws.getColumn(i + 1).width = w));
        ws.getColumn(7).numFmt = '#,##0';
        ws.views = [{ state: 'frozen', ySplit: 1 }];
        const buffer = await wb.xlsx.writeBuffer();
        const name = `법인카드-${month}.xlsx`;
        res
          .set({
            'content-type': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
            'content-disposition': `attachment; filename="cards.xlsx"; filename*=UTF-8''${encodeURIComponent(name)}`,
          })
          .send(Buffer.from(buffer));
      },
      { managerOnly: true },
    ),
  );

  // ── 연동 키 ──

  const feedDto = (row) =>
    row ? { exists: true, hint: row.tokenHint, createdByName: row.createdByName, createdAt: ms(row.createdAt), lastUsedAt: ms(row.lastUsedAt) } : { exists: false };

  router.get(
    '/groupware/card-feed',
    withCards(async (req, res, ctx) => res.json(feedDto(await findFeedKey(ctx.scopeKey))), { managerOnly: true }),
  );

  /** 연동 키 새로 만들기 — 예전 키는 바로 못 쓴다. 키는 이 응답에서 한 번만 보인다. */
  router.post(
    '/groupware/card-feed',
    withCards(
      async (req, res, ctx) => {
        const token = `${CARD_FEED_PREFIX}${crypto.randomBytes(32).toString('base64url')}`;
        const row = await upsertFeedKey({
          scopeKey: ctx.scopeKey,
          teamId: ctx.teamId,
          tokenHash: lookupHash(token),
          tokenHint: token.slice(-4),
          createdByName: actorName(ctx),
        });
        audit(ctx, AUDIT.cardFeedKey, { detail: '법인카드 연동 키 새로 만듦' });
        res.status(201).json({ ...feedDto(row), token });
      },
      { managerOnly: true },
    ),
  );

  router.delete(
    '/groupware/card-feed',
    withCards(
      async (req, res, ctx) => {
        await deleteFeedKey(ctx.scopeKey);
        audit(ctx, AUDIT.cardFeedKey, { detail: '법인카드 연동 키 지움' });
        res.json({ exists: false });
      },
      { managerOnly: true },
    ),
  );

  // ── 영수증 읽기 ──

  /**
   * 영수증 읽기 `{ fileUrl, fileName?, mimeType? }`(내가 올린 파일) 또는 `{ transactionId, receiptIndex }`(사용 건에 붙은 영수증) — 읽은 값,
   * 짐작한 지출 분류, 맞을 법한 내 미정산 사용 건들(점수 순). [transactionId]가 있고 고칠 수 있는 건이면 읽은 값을 그 건에 남긴다(어긋남 표시).
   */
  router.post(
    '/groupware/receipts/scan',
    withCards(async (req, res, ctx) => {
      if (!receiptOcrEnabled()) return fail(res, { error: '영수증 읽기가 꺼져 있습니다. 관리자에게 문의하세요.', status: 503 });
      const body = req.body ?? {};
      let file = null;
      let tx = null;
      if (body.transactionId !== undefined) {
        tx = isUuid(body.transactionId) ? await findTransaction(body.transactionId) : null;
        if (!tx || tx.scopeKey !== ctx.scopeKey || !canView(ctx, tx)) return fail(res, { error: '카드 사용 건을 찾을 수 없습니다.', status: 404 });
      }
      if (typeof body.fileUrl === 'string' && body.fileUrl) {
        const current = tx && Array.isArray(tx.receipts) ? tx.receipts : [];
        const attached = current.find((c) => knownUploadPath(body.fileUrl) === c.fileUrl);
        if (attached) file = attached;
        else {
          const checked = await checkFileRefs([body.fileUrl], { senderId: ctx.user.id, ownedOnly: true });
          if (!checked.ok) return fail(res, { error: '내가 올린 영수증만 읽을 수 있습니다.', status: 403 });
          file = { fileUrl: checked.paths.get(body.fileUrl), fileName: body.fileName ?? null, mimeType: body.mimeType ?? null };
        }
      } else if (tx && Number.isInteger(body.receiptIndex)) {
        file = (Array.isArray(tx.receipts) ? tx.receipts : [])[body.receiptIndex] ?? null;
      }
      if (!file?.fileUrl) return fail(res, { error: '읽을 영수증을 고르세요.' });
      const wait = limits.receiptOcrUser.hit(ctx.user.id);
      if (wait > 0) return retryLater(res, wait, `영수증을 너무 많이 읽었습니다. ${waitText(wait)} 뒤에 다시 하세요.`);
      let result;
      try {
        result = await readReceipt({ fileUrl: file.fileUrl, mimeType: file.mimeType, fileName: file.fileName, userId: ctx.user.id });
      } catch (err) {
        if (err instanceof ReceiptOcrError) return fail(res, { error: err.message, status: err.status });
        console.error('[receipt-ocr] 실패:', err?.message ?? err);
        return fail(res, { error: '영수증을 읽지 못했습니다. 잠시 뒤 다시 하세요.', status: 502 });
      }
      const receipt = result.receipt;
      const empty = isEmptyReceipt(receipt);
      // 맞춰 볼 사용 건 — 내 미정산 건(영수증 날짜 앞뒤 7일, 날짜를 못 읽었으면 지난 60일).
      let matches = [];
      if (!empty) {
        const day = receipt.date ?? seoulDateKey(new Date());
        const shift = (key, days) => seoulDateKey(new Date(Date.parse(`${key}T00:00:00+09:00`) + days * 86400_000));
        const candidates = (
          await listTransactions({
            scopeKey: ctx.scopeKey,
            from: shift(day, receipt.date ? -7 : -60),
            to: shift(day, 7),
            userId: ctx.user.id,
            holderCardIds: ctx.myCardIds,
          })
        ).filter((t) => txStatus(t) === 'open' && t.amount > 0);
        const ranked = matchReceiptToTransactions(
          receipt,
          candidates.map((t) => ({ ...t, cardLast4: ctx.cardsById.get(t.cardId)?.last4 ?? null })),
        );
        const nameOf = await namesOf(ctx);
        matches = ranked.map((m) => ({ ...m, transaction: txDto(ctx, candidates.find((t) => t.id === m.id), nameOf) }));
      }
      let transaction = null;
      if (tx && canEdit(ctx, tx) && !empty) {
        await updateTransaction(tx.id, { receiptScan: receipt });
        transaction = txDto(ctx, await findTransaction(tx.id), await namesOf(ctx));
        emitChanged(ctx, { userIds: [tx.userId] });
      }
      res.json({
        receipt,
        empty,
        engine: result.engine,
        category: guessExpenseCategory(receipt, ctx.options.expenseCategories),
        matches,
        ...(transaction && { transaction }),
      });
    }),
  );

  return router;
}

/**
 * 법인카드 연동(공개 API) — `POST /api/v1/corporate-cards/transactions`, `Authorization: Bearer ttc_…`(그룹웨어 → 지출 → 법인카드 관리 → 연동 키).
 * 카드사 이용내역 연동 서비스(스크래핑·오픈뱅킹 중계)·회계 프로그램·스크립트가 사용 건을 밀어 넣는다. 본문 `{ transactions: [{ cardLast4 | cardId,
 * usedAt(ISO 8601 — 시간대가 없으면 한국 시각), merchant, amount(원 — 취소는 음수 또는 canceled: true), approvalNo?, merchantBizNo?, issuer? }] }`(300건까지 — 로그인하지 않은 요청이라 본문은 100KB까지).
 * 같은 건은 건너뛴다(다시 보내도 된다). `{ inserted, duplicates, errors: [{ index, error }] }`. 키마다 1분에 30번.
 */
export function createCardFeedRouter(io) {
  const router = Router();

  router.post('/transactions', async (req, res) => {
    const header = req.get('authorization') ?? '';
    const token = header.startsWith('Bearer ') ? header.slice(7).trim() : '';
    if (!isCardFeedToken(token)) return res.status(401).json({ error: '유효하지 않은 연동 키입니다.' });
    const key = await findFeedKeyByHash(lookupHash(token));
    if (!key) return res.status(401).json({ error: '유효하지 않은 연동 키입니다.' });
    const wait = limits.cardFeed.hit(key.scopeKey);
    if (wait > 0) return retryLater(res, wait, `요청이 너무 많습니다. ${waitText(wait)} 뒤에 다시 하세요.`);
    const list = req.body?.transactions;
    if (!Array.isArray(list) || list.length === 0) return res.status(400).json({ error: 'transactions(사용 건 목록)를 보내세요.' });
    if (list.length > 300) return res.status(400).json({ error: '한 번에 300건까지 보낼 수 있습니다.' });
    touchFeedKey(key.scopeKey).catch(() => {});
    const cards = (await listCards(key.scopeKey)).filter((c) => c.enabled);
    const errors = [];
    const values = [];
    list.forEach((input, index) => {
      const parsed = parseFeedTransaction(input);
      if (parsed.error) return errors.push({ index, error: parsed.error });
      const t = parsed.tx;
      const matches = t.cardId
        ? cards.filter((c) => c.id === t.cardId)
        : cards.filter((c) => c.last4 === t.last4 && (!t.issuer || c.issuer === t.issuer || c.issuer === '기타'));
      if (matches.length !== 1) {
        return errors.push({ index, error: matches.length ? '끝 4자리가 같은 카드가 여럿입니다 — issuer나 cardId를 보내세요.' : '등록된(켜진) 카드가 아닙니다.' });
      }
      const card = matches[0];
      const holders = card.holderIds ?? [];
      values.push({
        scopeKey: key.scopeKey,
        cardId: card.id,
        usedAt: t.usedAt,
        usedOn: t.usedOn,
        merchant: t.merchant,
        merchantBizNo: t.merchantBizNo,
        amount: t.amount,
        approvalNo: t.approvalNo,
        source: 'api',
        dedupeKey: txDedupeKey(t),
        userId: holders.length === 1 ? holders[0] : null,
      });
    });
    const unique = [...new Map(values.map((v) => [`${v.cardId}|${v.dedupeKey}`, v])).values()];
    const inserted = await insertTransactions(unique);
    // 승인 취소 짝짓기 — 들어온 카드들의 지난 40일.
    const cardIds = [...new Set(inserted.map((r) => r.cardId))];
    if (cardIds.length) {
      const txs = await listTransactions({ scopeKey: key.scopeKey, from: seoulDateKey(new Date(Date.now() - 40 * 86400_000)), cardIds });
      const pairs = pairCancellations(txs);
      if (pairs.length) await excludeTransactions(pairs.flat(), { reason: '승인 취소', byName: '자동' });
      for (const id of new Set(cards.filter((c) => cardIds.includes(c.id)).flatMap((c) => c.holderIds ?? []))) {
        io.to(`user:${id}`).emit('groupware:changed', { cards: true, scopeKey: key.scopeKey });
      }
    }
    res.json({ inserted: inserted.length, duplicates: values.length - inserted.length, errors });
  });

  return router;
}
