import fs from 'node:fs/promises';
import path from 'node:path';
import ExcelJS from 'exceljs';
import express, { Router } from 'express';
import {
  accountsOf,
  cardVoucherLines,
  DEFAULT_ACCOUNTS,
  expenseVoucherLines,
  parseAccountMap,
  parseRetention,
  receiptKeepUntil,
  taxDocVoucherLines,
  VOUCHER_FORMATS,
  voucherSheet,
  voucherTotals,
} from './accountingRules.js';
import { AUDIT, recordAudit } from './audit.js';
import { pairCancellations, seoulDateKey, txDedupeKey, txStatus } from './cardRules.js';
import { codefCardFields, CodefError, codefStatus, codefTaxDocFields, connectCodefAccount, fetchCardApprovals, fetchHometaxDocs } from './codef.js';
import { decryptField, encryptField } from './crypto.js';
import { excludeTransactions, insertTransactions, listCards, listTransactions } from './db/queries/corporateCards.js';
import {
  countReceiptPurges,
  deleteTaxDocument,
  existingTaxDocKeys,
  findFinanceSettings,
  findTaxDocument,
  insertReceiptPurge,
  insertTaxDocuments,
  listApprovedExpenses,
  listCardTxsWithReceipts,
  listExpenseDocsWithReceipts,
  listFinanceSettings,
  listReceiptPurges,
  listTaxDocuments,
  setCardTxReceipts,
  updateTaxDocument,
  upsertFinanceSettings,
} from './db/queries/finance.js';
import { listGroupwareMembers } from './db/queries/groupware.js';
import { findReferencedUploadPaths } from './db/queries/uploads.js';
import { isUuid } from './favoritesRules.js';
import { fail, groupwareContext } from './groupware.js';
import { readSheetRows } from './sheetRows.js';
import {
  codefCardRow,
  codefFieldReport,
  codefOrgOf,
  codefTaxDocRow,
  CODEF_CARD_ORGS,
  parseTaxDocRows,
  TAX_DOC_DIRECTIONS,
  TAX_DOC_KINDS,
  taxDocDedupeKey,
} from './taxDocRules.js';
import { uploadFileNameOf, uploadsDir } from './upload.js';

const ms = (v) => (v ? new Date(v).getTime() : null);
const todayKey = () => seoulDateKey(new Date());
const isMonth = (v) => typeof v === 'string' && /^\d{4}-(0[1-9]|1[0-2])$/.test(v);
const isDateKey = (v) => typeof v === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(v) && !Number.isNaN(Date.parse(`${v}T00:00:00Z`));
const monthRange = (month) => {
  const [y, m] = month.split('-').map(Number);
  const last = new Date(Date.UTC(y, m, 0)).getUTCDate();
  return { from: `${month}-01`, to: `${month}-${String(last).padStart(2, '0')}` };
};
const shiftDays = (key, days) => seoulDateKey(new Date(Date.parse(`${key}T00:00:00+09:00`) + days * 86_400_000));
const readSecret = (v) => {
  if (!v) return null;
  try {
    return decryptField(v);
  } catch {
    return null;
  }
};

async function sendWorkbook(res, wb, name, ascii) {
  const buffer = await wb.xlsx.writeBuffer();
  res
    .set({
      'content-type': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'content-disposition': `attachment; filename="${ascii}"; filename*=UTF-8''${encodeURIComponent(name)}`,
      'cache-control': 'no-store',
    })
    .send(Buffer.from(buffer));
}

function addSheet(wb, title, header, rows, amountCols = []) {
  const ws = wb.addWorksheet(title);
  ws.addRow(header).font = { bold: true };
  for (const r of rows) ws.addRow(r);
  header.forEach((h, i) => {
    const col = ws.getColumn(i + 1);
    col.width = Math.min(40, Math.max(9, [...String(h)].length * 1.8));
    if (amountCols.includes(i + 1)) col.numFmt = '#,##0';
  });
  ws.views = [{ state: 'frozen', ySplit: 1 }];
  return ws;
}

// ── 사용 건·증빙 넣기(라우터와 자동 가져오기가 함께 쓴다) ──

/**
 * CODEF 법인카드 승인내역 가져오기 — 범위의 켜진 카드를 카드사(기관 코드)마다 묶어 [from]~[to]를 부르고, 끝 4자리로 카드를 찾아 넣는다(같은 건은
 * 건너뛰고, 승인 취소는 짝을 지어 뺀다 — 엑셀 가져오기와 같다). `{ inserted, duplicates, errors: [{ organization?, error }], paired, cardIds }`.
 */
export async function syncCodefCards({ scopeKey, connectedId, from, to }) {
  const cards = (await listCards(scopeKey)).filter((c) => c.enabled);
  const byOrg = new Map();
  for (const c of cards) {
    const org = codefOrgOf(c);
    if (!org) continue;
    byOrg.set(org, [...(byOrg.get(org) ?? []), c]);
  }
  const errors = [];
  const values = [];
  let read = 0;
  const fields = codefCardFields();
  for (const [organization, orgCards] of byOrg) {
    let rows;
    try {
      rows = await fetchCardApprovals({ connectedId, organization, from, to });
    } catch (err) {
      errors.push({ organization, error: err instanceof CodefError ? err.message : '가져오지 못했습니다.' });
      continue;
    }
    for (const raw of rows) {
      const parsed = codefCardRow(raw, fields);
      if (parsed.error) {
        if (!parsed.skip) errors.push({ organization, error: parsed.error });
        continue;
      }
      read += 1;
      const t = parsed.tx;
      const matches = orgCards.filter((c) => c.last4 === t.last4);
      // 끝 4자리를 못 읽었는데 그 카드사 카드가 하나뿐이면 그 카드.
      const card = matches.length === 1 ? matches[0] : !t.last4 && orgCards.length === 1 ? orgCards[0] : null;
      if (!card) continue;
      const holders = card.holderIds ?? [];
      values.push({
        scopeKey,
        cardId: card.id,
        usedAt: t.usedAt,
        usedOn: t.usedOn,
        merchant: t.merchant,
        merchantBizNo: t.merchantBizNo,
        amount: t.amount,
        approvalNo: t.approvalNo,
        source: 'codef',
        dedupeKey: txDedupeKey(t),
        userId: holders.length === 1 ? holders[0] : null,
      });
    }
  }
  const unique = [...new Map(values.map((v) => [`${v.cardId}|${v.dedupeKey}`, v])).values()];
  const inserted = await insertTransactions(unique);
  const cardIds = [...new Set(inserted.map((r) => r.cardId))];
  let paired = 0;
  if (cardIds.length) {
    const txs = await listTransactions({ scopeKey, from: shiftDays(from, -40), cardIds });
    const pairs = pairCancellations(txs);
    if (pairs.length) await excludeTransactions(pairs.flat(), { reason: '승인 취소', byName: '자동' });
    paired = pairs.length;
  }
  return { read, inserted: inserted.length, duplicates: unique.length - inserted.length, errors: errors.slice(0, 50), paired, cardIds, cards };
}

/** CODEF 홈택스 목록 가져오기 — 계약한 종류(현금영수증·전자세금계산서 매입)마다. `{ inserted, duplicates, errors }`. */
export async function syncCodefHometax({ scopeKey, connectedId, from, to, kinds }) {
  const errors = [];
  const values = [];
  const fields = codefTaxDocFields();
  for (const kind of kinds) {
    let rows;
    try {
      rows = await fetchHometaxDocs({ connectedId, kind, from, to });
    } catch (err) {
      errors.push({ kind, error: err instanceof CodefError ? err.message : '가져오지 못했습니다.' });
      continue;
    }
    for (const raw of rows) {
      const parsed = codefTaxDocRow(raw, { kind, fields });
      if (parsed.error) {
        errors.push({ kind, error: parsed.error });
        continue;
      }
      values.push({ ...parsed.doc, scopeKey, source: 'codef', dedupeKey: taxDocDedupeKey({ ...parsed.doc, total: parsed.doc.totalAmount }) });
    }
  }
  const unique = [...new Map(values.map((v) => [v.dedupeKey, v])).values()];
  const inserted = await insertTaxDocuments(unique);
  return { inserted: inserted.length, duplicates: unique.length - inserted.length, errors: errors.slice(0, 50) };
}

// ── 영수증 보관 ──

/**
 * 범위의 영수증 파일들 — 카드 사용 건의 영수증과 지출 결재의 첨부, 각각 쓴 날과 보관 기한. 같은 파일이 여러 곳(사용 건과 그 건을 청구한 결재)에
 * 붙으면 가장 늦은 기한으로 하나만. `[{ path, fileName, size, usedOn, keepUntil, txIds }]`.
 */
async function receiptFiles(scopeKey, settings) {
  const opts = { years: settings?.receiptRetentionYears ?? 5, filing: settings?.receiptFiling ?? 'corporate' };
  const files = new Map();
  const add = (att, usedOn, txId = null) => {
    const stored = att?.fileUrl;
    if (typeof stored !== 'string' || !stored.startsWith('/uploads/') || att.purgedAt) return;
    const keepUntil = receiptKeepUntil(usedOn, opts);
    const prev = files.get(stored);
    if (prev) {
      if (usedOn > prev.usedOn) Object.assign(prev, { usedOn, keepUntil });
      if (txId) prev.txIds.push(txId);
      return;
    }
    files.set(stored, { path: stored, fileName: uploadFileNameOf(stored), size: Number(att.fileSize) || 0, usedOn, keepUntil, txIds: txId ? [txId] : [] });
  };
  const [txs, docs] = await Promise.all([listCardTxsWithReceipts(scopeKey), listExpenseDocsWithReceipts(scopeKey)]);
  for (const t of txs) for (const r of Array.isArray(t.receipts) ? t.receipts : []) add(r, t.usedOn, t.id);
  for (const d of docs) {
    const spentOn = d.payload?.spentOn;
    if (typeof spentOn !== 'string') continue;
    for (const a of Array.isArray(d.attachments) ? d.attachments : []) add(a, spentOn);
    for (const ct of Array.isArray(d.payload?.cardTransactions) ? d.payload.cardTransactions : []) {
      for (const r of Array.isArray(ct.receipts) ? ct.receipts : []) add(r, seoulDateKey(new Date(ct.usedAt ?? Date.parse(`${spentOn}T00:00:00Z`))));
    }
  }
  return [...files.values()];
}

/**
 * 보관 기한이 지난 영수증 파일을 지운다 — 대화·노트 등 다른 곳에서도 쓰는 파일은 두고, 결재 문서의 첨부 목록(전자서명 지문)은 그대로 둔 채
 * receipt_purges에 남긴다(앱은 "보관 기한이 지나 지움"으로 보인다). 카드 사용 건의 영수증 목록에는 지운 때를 적는다. 지운 수.
 */
export async function purgeExpiredReceipts(scopeKey, settings) {
  if (!settings?.receiptRetentionYears) return 0;
  const today = todayKey();
  const expired = (await receiptFiles(scopeKey, settings)).filter((f) => f.keepUntil && f.keepUntil < today && f.fileName);
  if (!expired.length) return 0;
  const already = new Set((await listReceiptPurges(expired.map((f) => f.fileName))).map((r) => r.fileName));
  const candidates = expired.filter((f) => !already.has(f.fileName));
  const elsewhere = await findReferencedUploadPaths(candidates.map((f) => f.path));
  let purged = 0;
  const purgedPaths = new Set();
  for (const f of candidates) {
    if (elsewhere.has(f.path)) continue;
    try {
      await fs.unlink(path.join(uploadsDir, f.fileName));
    } catch (err) {
      if (err?.code !== 'ENOENT') continue;
    }
    await insertReceiptPurge({ fileName: f.fileName, scopeKey, usedOn: f.usedOn, keepUntil: f.keepUntil });
    purgedPaths.add(f.path);
    purged += 1;
  }
  if (purgedPaths.size) {
    const now = Date.now();
    for (const t of await listCardTxsWithReceipts(scopeKey)) {
      const list = Array.isArray(t.receipts) ? t.receipts : [];
      if (!list.some((r) => purgedPaths.has(r.fileUrl))) continue;
      await setCardTxReceipts(
        t.id,
        list.map((r) => (purgedPaths.has(r.fileUrl) ? { ...r, purgedAt: now } : r)),
      );
    }
  }
  return purged;
}

/**
 * 지출 관리 도구 — 결재·근태 관리자(그룹웨어 관리자)만. 회계 전표 내보내기(법인카드·지출 결재·증빙 — 계정은 설정), 현금영수증·전자세금계산서 조회
 * (홈택스 목록 엑셀 가져오기·CODEF), 카드사·홈택스 직접 연동(CODEF 계정 연결·지금 가져오기·매일 자동), 영수증 원본 보관 기간(기한 보기·지나면
 * 지우기). 규칙은 accountingRules.js·taxDocRules.js, CODEF 호출은 codef.js.
 */
export function createFinanceToolsRouter(io) {
  const router = Router();

  const withManager = (handler) => async (req, res) => {
    const ctx = await groupwareContext(req.user.sub, req.query.teamId ?? (Buffer.isBuffer(req.body) ? null : req.body?.teamId));
    if (ctx.error) return fail(res, ctx);
    if (!ctx.isManager) return fail(res, { error: '결재·근태 관리자만 할 수 있습니다.', status: 403 });
    return handler(req, res, { ...ctx, finance: await findFinanceSettings(ctx.scopeKey) });
  };
  const actorName = (ctx) => ctx.user.name ?? ctx.user.username;
  const audit = (ctx, action, detail) =>
    recordAudit({ actorId: ctx.user.id, actorName: actorName(ctx), action, teamId: ctx.teamId, teamName: ctx.team?.name ?? null, targetType: 'finance', detail });

  const settingsDto = (ctx, s) => ({
    accounts: accountsOf(s?.accountMap),
    defaultAccounts: DEFAULT_ACCOUNTS,
    categories: ctx.options.expenseCategories,
    voucherFormat: s?.voucherFormat ?? 'generic',
    receiptRetentionYears: s?.receiptRetentionYears ?? 5,
    receiptFiling: s?.receiptFiling ?? 'corporate',
    receiptPurge: s?.receiptPurge === true,
    codef: {
      ...codefStatus(),
      cardConnected: Boolean(s?.codefCardConnectedId),
      hometaxConnected: Boolean(s?.codefHometaxConnectedId),
      autoSync: s?.codefAutoSync === true,
      lastSyncAt: ms(s?.codefLastSyncAt),
      lastResult: s?.codefLastResult ?? null,
      organizations: CODEF_CARD_ORGS,
    },
  });

  router.get(
    '/groupware/finance/settings',
    withManager(async (req, res, ctx) => res.json(settingsDto(ctx, ctx.finance))),
  );

  /** 설정 `{ accounts?, voucherFormat?, receiptRetentionYears?, receiptFiling?, receiptPurge?, codefAutoSync? }`. */
  router.put(
    '/groupware/finance/settings',
    withManager(async (req, res, ctx) => {
      const body = req.body ?? {};
      const patch = {};
      const map = parseAccountMap(body.accounts);
      if (map.error) return fail(res, map);
      if (map.accountMap !== undefined) patch.accountMap = map.accountMap;
      if (body.voucherFormat !== undefined) {
        if (!VOUCHER_FORMATS.includes(body.voucherFormat)) return fail(res, { error: '전표 모양을 고르세요.' });
        patch.voucherFormat = body.voucherFormat;
      }
      const retention = parseRetention({ retentionYears: body.receiptRetentionYears, filing: body.receiptFiling, purge: body.receiptPurge });
      if (retention.error) return fail(res, retention);
      Object.assign(patch, retention.patch);
      if (body.codefAutoSync !== undefined) patch.codefAutoSync = body.codefAutoSync === true;
      const row = await upsertFinanceSettings(ctx.scopeKey, patch, ctx.teamId);
      if (Object.keys(patch).length) audit(ctx, AUDIT.financeSettings, `지출 관리 설정 — ${Object.keys(patch).join(', ')}`);
      res.json(settingsDto(ctx, row));
    }),
  );

  // ── 회계 전표 ──

  /**
   * 회계 전표 엑셀 `?month=YYYY-MM&sources=cards,expenses,taxdocs` — 그 달의 법인카드 사용(제외 건 빼고 — 취소는 반대 분개), 승인된 지출 결재(법인카드
   * 청구가 아닌 것), 매입 증빙(현금영수증·세금계산서 — 법인카드·지출 결재와 겹칠 수 있어 기본은 빠짐)을 분개 줄로. 차변·대변 합계를 끝에 적는다.
   */
  router.get(
    '/groupware/finance/vouchers',
    withManager(async (req, res, ctx) => {
      const month = isMonth(req.query.month) ? req.query.month : todayKey().slice(0, 7);
      const sources = new Set(String(req.query.sources ?? 'cards,expenses').split(','));
      const range = monthRange(month);
      const accounts = accountsOf(ctx.finance?.accountMap);
      const lines = [];
      if (sources.has('cards')) {
        const [txs, cards, members] = await Promise.all([listTransactions({ scopeKey: ctx.scopeKey, ...range }), listCards(ctx.scopeKey), listGroupwareMembers({ scope: ctx.scope, teamId: ctx.teamId })]);
        const cardOf = new Map(cards.map((c) => [c.id, c]));
        const nameOf = new Map(members.map((m) => [m.id, m.name]));
        lines.push(
          ...cardVoucherLines(
            txs
              .filter((t) => txStatus(t) !== 'excluded')
              .map((t) => ({ ...t, issuer: cardOf.get(t.cardId)?.issuer, last4: cardOf.get(t.cardId)?.last4, userName: nameOf.get(t.userId) ?? null })),
            accounts,
          ),
        );
      }
      if (sources.has('expenses')) lines.push(...expenseVoucherLines(await listApprovedExpenses(ctx.scopeKey, range), accounts));
      if (sources.has('taxdocs')) lines.push(...taxDocVoucherLines(await listTaxDocuments(ctx.scopeKey, { ...range, direction: 'purchase' }), accounts));
      const sheet = voucherSheet(lines, ctx.finance?.voucherFormat ?? 'generic');
      const wb = new ExcelJS.Workbook();
      const ws = addSheet(wb, '전표', sheet.header, sheet.rows, sheet.amountColumns);
      const totals = voucherTotals(lines);
      ws.addRow([]);
      ws.addRow([`차변 합계 ${totals.debit.toLocaleString('ko-KR')} / 대변 합계 ${totals.credit.toLocaleString('ko-KR')}`]);
      const info = wb.addWorksheet('안내');
      for (const line of [
        [`${month} 회계 전표 — 법인카드는 사용일, 지출 결재는 쓴 날, 증빙은 작성일 기준입니다.`],
        ['계정은 그룹웨어 → 지출 → 법인카드 관리 → 지출 관리 설정에서 바꿉니다. 부가세 매입세액(부가세대급금)은 나누지 않았습니다.'],
        ['더존 모양은 일반전표 엑셀 올리기에 흔한 열 순서입니다 — 프로그램 판마다 다를 수 있으니 올리기 전에 회계 프로그램의 양식과 맞춰 보세요.'],
      ])
        info.addRow(line);
      info.getColumn(1).width = 110;
      audit(ctx, AUDIT.financeExport, `회계 전표 내려받기 — ${month} (${[...sources].join(',')})`);
      await sendWorkbook(res, wb, `회계전표-${month}.xlsx`, 'vouchers.xlsx');
    }),
  );

  // ── 현금영수증·전자세금계산서 ──

  const docDto = (d) => ({
    id: d.id,
    kind: d.kind,
    direction: d.direction,
    issuedOn: d.issuedOn,
    approvalNo: d.approvalNo ?? null,
    supplierName: d.supplierName ?? null,
    supplierBizNo: d.supplierBizNo ?? null,
    buyerName: d.buyerName ?? null,
    buyerBizNo: d.buyerBizNo ?? null,
    supplyAmount: d.supplyAmount ?? null,
    taxAmount: d.taxAmount ?? null,
    totalAmount: d.totalAmount,
    itemName: d.itemName ?? null,
    category: d.category ?? null,
    memo: d.memo ?? null,
    source: d.source,
  });

  /** 증빙 `?month=&kind=&direction=` → `{ items, totals: { count, supply, tax, total } }`. */
  router.get(
    '/groupware/tax-documents',
    withManager(async (req, res, ctx) => {
      const month = isMonth(req.query.month) ? req.query.month : todayKey().slice(0, 7);
      const kind = TAX_DOC_KINDS.includes(req.query.kind) ? req.query.kind : null;
      const direction = TAX_DOC_DIRECTIONS.includes(req.query.direction) ? req.query.direction : null;
      const items = (await listTaxDocuments(ctx.scopeKey, { ...monthRange(month), kind, direction })).map(docDto);
      const sum = (key) => items.reduce((s, d) => s + (d[key] ?? 0), 0);
      res.json({ month, items, totals: { count: items.length, supply: sum('supplyAmount'), tax: sum('taxAmount'), total: sum('totalAmount') } });
    }),
  );

  /**
   * 홈택스 목록 엑셀 가져오기 `?kind=&direction=purchase|sale&dryRun=1`(본문은 엑셀·CSV 그대로, 10MB) — 머리 줄을 찾아 읽고(종류는 비우면 짐작),
   * 같은 증빙은 건너뛴다. 미리 보기면 읽은·새·이미 있는 수와 못 읽은 줄만.
   */
  router.post(
    '/groupware/tax-documents/import',
    express.raw({ type: () => true, limit: '10mb' }),
    withManager(async (req, res, ctx) => {
      const sheet = await readSheetRows(req.body);
      if (sheet.error) return fail(res, sheet);
      const parsed = parseTaxDocRows(sheet.rows, { kind: req.query.kind ?? null, direction: req.query.direction ?? 'purchase' });
      if (parsed.error) return fail(res, parsed);
      const values = parsed.rows.map((r) => ({
        scopeKey: ctx.scopeKey,
        kind: r.kind,
        direction: r.direction,
        issuedOn: r.issuedOn,
        approvalNo: r.approvalNo,
        supplierName: r.supplierName,
        supplierBizNo: r.supplierBizNo,
        buyerName: r.buyerName,
        buyerBizNo: r.buyerBizNo,
        supplyAmount: r.supplyAmount,
        taxAmount: r.taxAmount,
        totalAmount: r.totalAmount,
        itemName: r.itemName,
        source: 'excel',
        dedupeKey: taxDocDedupeKey({ ...r, total: r.totalAmount }),
      }));
      const unique = [...new Map(values.map((v) => [v.dedupeKey, v])).values()];
      const known = await existingTaxDocKeys(ctx.scopeKey, unique.map((v) => v.dedupeKey));
      const fresh = unique.filter((v) => !known.has(v.dedupeKey));
      const dates = fresh.map((v) => v.issuedOn).sort();
      const summary = {
        kind: parsed.kind,
        read: parsed.rows.length,
        fresh: fresh.length,
        duplicates: parsed.rows.length - fresh.length,
        errors: parsed.errors.slice(0, 200),
        from: dates[0] ?? null,
        to: dates.at(-1) ?? null,
        total: fresh.reduce((s, v) => s + v.totalAmount, 0),
      };
      if (req.query.dryRun === '1') return res.json({ ...summary, applied: false });
      const inserted = await insertTaxDocuments(fresh);
      audit(ctx, AUDIT.financeImport, `${parsed.kind === 'tax_invoice' ? '전자세금계산서' : '현금영수증'} 가져오기 — ${inserted.length}건`);
      res.json({ ...summary, inserted: inserted.length, applied: true });
    }),
  );

  /** 증빙 고치기 `{ category?, memo? }`(전표 계정·메모). */
  router.patch(
    '/groupware/tax-documents/:id',
    withManager(async (req, res, ctx) => {
      const doc = isUuid(req.params.id) ? await findTaxDocument(req.params.id) : null;
      if (!doc || doc.scopeKey !== ctx.scopeKey) return fail(res, { error: '증빙을 찾을 수 없습니다.', status: 404 });
      const patch = {};
      if (req.body?.category !== undefined) {
        const c = req.body.category;
        if (c !== null && c !== '' && !ctx.options.expenseCategories.includes(c)) return fail(res, { error: '지출 분류를 고르세요.' });
        patch.category = c || null;
      }
      if (req.body?.memo !== undefined) patch.memo = typeof req.body.memo === 'string' ? req.body.memo.trim().slice(0, 300) || null : null;
      const row = Object.keys(patch).length ? await updateTaxDocument(doc.id, patch) : doc;
      res.json(docDto(row));
    }),
  );

  router.delete(
    '/groupware/tax-documents/:id',
    withManager(async (req, res, ctx) => {
      const doc = isUuid(req.params.id) ? await findTaxDocument(req.params.id) : null;
      if (!doc || doc.scopeKey !== ctx.scopeKey) return fail(res, { error: '증빙을 찾을 수 없습니다.', status: 404 });
      await deleteTaxDocument(doc.id);
      res.json({ ok: true });
    }),
  );

  /** 한 달 증빙 엑셀. */
  router.get(
    '/groupware/tax-documents/export',
    withManager(async (req, res, ctx) => {
      const month = isMonth(req.query.month) ? req.query.month : todayKey().slice(0, 7);
      const items = await listTaxDocuments(ctx.scopeKey, monthRange(month));
      const wb = new ExcelJS.Workbook();
      addSheet(
        wb,
        '증빙',
        ['종류', '매입/매출', '작성일', '승인번호', '공급자', '공급자 사업자번호', '공급받는 자', '공급받는 자 사업자번호', '공급가액', '세액', '합계', '품목', '분류', '메모'],
        [...items].reverse().map((d) => [
          d.kind === 'tax_invoice' ? '전자세금계산서' : '현금영수증',
          d.direction === 'sale' ? '매출' : '매입',
          d.issuedOn,
          d.approvalNo ?? '',
          d.supplierName ?? '',
          d.supplierBizNo ?? '',
          d.buyerName ?? '',
          d.buyerBizNo ?? '',
          d.supplyAmount,
          d.taxAmount,
          d.totalAmount,
          d.itemName ?? '',
          d.category ?? '',
          d.memo ?? '',
        ]),
        [9, 10, 11],
      );
      audit(ctx, AUDIT.financeExport, `증빙 내려받기 — ${month}`);
      await sendWorkbook(res, wb, `증빙-${month}.xlsx`, 'tax-documents.xlsx');
    }),
  );

  // ── CODEF 연동 ──

  /**
   * 계정 연결 `{ target: 'card' | 'hometax', organization?, loginId?, password?, connectedId? }` — 카드사 기업 회원 아이디·비밀번호를 CODEF에
   * 보내 connectedId를 받거나(카드 — 카드사마다 한 번씩, 같은 connectedId에 더한다), CODEF에서 따로 만든 connectedId를 그대로 넣는다(홈택스는
   * 인증서 로그인이 흔해 connectedId만 받는다). 아이디·비밀번호는 이 서버에 남기지 않는다.
   */
  router.post(
    '/groupware/codef/connect',
    withManager(async (req, res, ctx) => {
      const body = req.body ?? {};
      const target = body.target === 'hometax' ? 'hometax' : 'card';
      const column = target === 'hometax' ? 'codefHometaxConnectedId' : 'codefCardConnectedId';
      let connectedId = typeof body.connectedId === 'string' ? body.connectedId.trim() : '';
      if (connectedId && !/^[A-Za-z0-9._-]{8,100}$/.test(connectedId)) return fail(res, { error: 'connectedId 모양이 아닙니다.' });
      if (!connectedId) {
        if (target !== 'card') return fail(res, { error: 'CODEF에서 만든 홈택스 connectedId를 넣으세요.' });
        if (!/^\d{4}$/.test(String(body.organization ?? ''))) return fail(res, { error: '카드사(기관 코드)를 고르세요.' });
        if (!body.loginId || !body.password) return fail(res, { error: '카드사 기업 회원 아이디와 비밀번호를 넣으세요.' });
        try {
          connectedId = await connectCodefAccount({
            organization: String(body.organization),
            loginId: String(body.loginId).slice(0, 100),
            password: String(body.password).slice(0, 200),
            connectedId: readSecret(ctx.finance?.codefCardConnectedId),
          });
        } catch (err) {
          if (err instanceof CodefError) return fail(res, { error: err.message, status: err.status });
          console.error('[codef] 계정 연결 실패:', err?.message ?? err);
          return fail(res, { error: '카드사 계정을 연결하지 못했습니다.', status: 502 });
        }
      }
      const row = await upsertFinanceSettings(ctx.scopeKey, { [column]: encryptField(connectedId) }, ctx.teamId);
      audit(ctx, AUDIT.financeCodef, `${target === 'card' ? '카드사' : '홈택스'} 연동 계정 연결${body.organization ? ` (${body.organization})` : ''}`);
      res.json(settingsDto(ctx, row));
    }),
  );

  router.delete(
    '/groupware/codef/connect',
    withManager(async (req, res, ctx) => {
      const target = req.query.target === 'hometax' ? 'hometax' : 'card';
      const row = await upsertFinanceSettings(ctx.scopeKey, target === 'hometax' ? { codefHometaxConnectedId: null } : { codefCardConnectedId: null, codefAutoSync: false }, ctx.teamId);
      audit(ctx, AUDIT.financeCodef, `${target === 'card' ? '카드사' : '홈택스'} 연동 끊음`);
      res.json(settingsDto(ctx, row));
    }),
  );

  /** 지금 가져오기 `{ from?, to?, target?: 'card' | 'hometax' | 'all' }`(기본 지난 7일 — 한 번에 93일까지). */
  router.post(
    '/groupware/codef/sync',
    withManager(async (req, res, ctx) => {
      const status = codefStatus();
      if (!status.enabled) return fail(res, { error: '카드사·홈택스 연동이 꺼져 있습니다(server/.env의 CODEF_*).', status: 503 });
      const to = isDateKey(req.body?.to) ? req.body.to : todayKey();
      const from = isDateKey(req.body?.from) ? req.body.from : shiftDays(to, -7);
      if (from > to || Date.parse(to) - Date.parse(from) > 93 * 86_400_000) return fail(res, { error: '기간은 93일까지입니다.' });
      const target = ['card', 'hometax'].includes(req.body?.target) ? req.body.target : 'all';
      const result = { at: Date.now(), from, to };
      const cardId = readSecret(ctx.finance?.codefCardConnectedId);
      const hometaxId = readSecret(ctx.finance?.codefHometaxConnectedId);
      if (target !== 'hometax' && cardId) {
        const r = await syncCodefCards({ scopeKey: ctx.scopeKey, connectedId: cardId, from, to });
        result.cards = { read: r.read, inserted: r.inserted, duplicates: r.duplicates, paired: r.paired, errors: r.errors };
        for (const id of new Set(r.cards.filter((c) => r.cardIds.includes(c.id)).flatMap((c) => c.holderIds ?? [])).add(ctx.user.id)) {
          io.to(`user:${id}`).emit('groupware:changed', { cards: true, scopeKey: ctx.scopeKey });
        }
      }
      if (target !== 'card' && hometaxId && status.hometaxKinds.length) {
        result.hometax = await syncCodefHometax({ scopeKey: ctx.scopeKey, connectedId: hometaxId, from, to, kinds: status.hometaxKinds });
      }
      if (!result.cards && !result.hometax) return fail(res, { error: '연결한 카드사·홈택스 계정이 없습니다.' });
      const row = await upsertFinanceSettings(ctx.scopeKey, { codefLastSyncAt: new Date(), codefLastResult: result }, ctx.teamId);
      audit(ctx, AUDIT.financeCodef, `연동으로 가져오기 — ${from}~${to}: 카드 ${result.cards?.inserted ?? 0}건, 증빙 ${result.hometax?.inserted ?? 0}건`);
      res.json({ ...result, settings: settingsDto(ctx, row) });
    }),
  );

  /**
   * 연동 점검 `{ target: 'card' | 'cash_receipt' | 'tax_invoice', organization?, from?, to? }`(기본 지난 7일) — 계약한 상품 주소로 한 번 불러
   * 응답 코드·줄 수·응답 칸 이름(값 없이)과 칸마다 어느 이름으로 읽었는지, 읽어 넣을 수 있는 줄 수를 돌려준다. 아무것도 넣지 않는다. 실제 계약
   * 계정으로 상품 주소·응답 칸을 맞춰 보는 데 쓴다(칸 이름이 다르면 .env의 CODEF_FIELD_MAP). 카드는 [organization](비우면 켜진 카드의 첫 카드사).
   */
  router.post(
    '/groupware/codef/probe',
    withManager(async (req, res, ctx) => {
      const status = codefStatus();
      if (!status.enabled) return fail(res, { error: '카드사·홈택스 연동이 꺼져 있습니다(server/.env의 CODEF_*).', status: 503 });
      const target = ['card', 'cash_receipt', 'tax_invoice'].includes(req.body?.target) ? req.body.target : 'card';
      const to = isDateKey(req.body?.to) ? req.body.to : todayKey();
      const from = isDateKey(req.body?.from) ? req.body.from : shiftDays(to, -7);
      if (from > to || Date.parse(to) - Date.parse(from) > 93 * 86_400_000) return fail(res, { error: '기간은 93일까지입니다.' });
      const isCard = target === 'card';
      const connectedId = readSecret(isCard ? ctx.finance?.codefCardConnectedId : ctx.finance?.codefHometaxConnectedId);
      if (!connectedId) return fail(res, { error: isCard ? '카드사 계정을 먼저 연결하세요.' : '홈택스 connectedId를 먼저 넣으세요.' });
      let organization = null;
      if (isCard) {
        organization = typeof req.body?.organization === 'string' && /^\d{4}$/.test(req.body.organization) ? req.body.organization : null;
        if (!organization) organization = (await listCards(ctx.scopeKey)).filter((c) => c.enabled).map(codefOrgOf).find(Boolean) ?? null;
        if (!organization) return fail(res, { error: '기관 코드가 있는 켜진 카드가 없습니다. 기관 코드를 넣으세요.' });
      }
      const path = isCard ? status.paths.card : target === 'cash_receipt' ? status.paths.cashReceipt : status.paths.taxInvoice;
      const base = { target, organization, path: path ?? null, from, to, at: Date.now() };
      audit(ctx, AUDIT.financeCodef, `연동 점검 — ${target}${organization ? ` (${organization})` : ''}`);
      if (!path) return res.json({ ...base, ok: false, code: null, message: '이 종류의 상품 주소가 server/.env에 없습니다.' });
      let rows;
      try {
        rows = isCard ? await fetchCardApprovals({ connectedId, organization, from, to }) : await fetchHometaxDocs({ connectedId, kind: target, from, to });
      } catch (err) {
        if (!(err instanceof CodefError)) console.error('[codef] 연동 점검 실패:', err?.message ?? err);
        return res.json({
          ...base,
          ok: false,
          code: err instanceof CodefError ? err.code : null,
          message: err instanceof CodefError ? err.message : '부르지 못했습니다.',
        });
      }
      const fields = isCard ? codefCardFields() : codefTaxDocFields();
      let parsed = 0;
      let skipped = 0;
      const errors = new Map();
      for (const raw of rows) {
        const r = isCard ? codefCardRow(raw, fields) : codefTaxDocRow(raw, { kind: target, fields });
        if (!r.error) parsed += 1;
        else if (r.skip) skipped += 1;
        else errors.set(r.error, (errors.get(r.error) ?? 0) + 1);
      }
      res.json({
        ...base,
        ok: true,
        code: 'CF-00000',
        count: rows.length,
        parsed,
        skipped,
        errors: [...errors.entries()].map(([error, count]) => ({ error, count })),
        ...codefFieldReport(rows, isCard ? 'card' : 'taxDoc', fields),
      });
    }),
  );

  // ── 영수증 보관 ──

  /** 영수증 보관 현황 — 해마다 파일 수·크기·보관 기한, 기한이 지난 수, 지운 수. */
  router.get(
    '/groupware/finance/receipts',
    withManager(async (req, res, ctx) => {
      const files = await receiptFiles(ctx.scopeKey, ctx.finance);
      const today = todayKey();
      const byYear = new Map();
      for (const f of files) {
        const y = f.usedOn.slice(0, 4);
        const e = byYear.get(y) ?? { year: Number(y), count: 0, bytes: 0, keepUntil: f.keepUntil, expired: 0 };
        e.count += 1;
        e.bytes += f.size;
        if (f.keepUntil && f.keepUntil < today) e.expired += 1;
        byYear.set(y, e);
      }
      res.json({
        retentionYears: ctx.finance?.receiptRetentionYears ?? 5,
        filing: ctx.finance?.receiptFiling ?? 'corporate',
        purge: ctx.finance?.receiptPurge === true,
        count: files.length,
        bytes: files.reduce((s, f) => s + f.size, 0),
        expired: files.filter((f) => f.keepUntil && f.keepUntil < today).length,
        purged: await countReceiptPurges(ctx.scopeKey),
        years: [...byYear.values()].sort((a, b) => b.year - a.year),
      });
    }),
  );

  /** 보관 기한이 지난 영수증을 지금 지우기(되돌릴 수 없다 — 감사 로그). */
  router.post(
    '/groupware/finance/receipts/purge',
    withManager(async (req, res, ctx) => {
      if (!ctx.finance?.receiptRetentionYears) return fail(res, { error: '보관 기간을 "기한 없음"으로 두었습니다.' });
      const purged = await purgeExpiredReceipts(ctx.scopeKey, ctx.finance);
      audit(ctx, AUDIT.financePurge, `보관 기한 지난 영수증 지움 — ${purged}개`);
      res.json({ purged });
    }),
  );

  return router;
}

/**
 * 매일 도는 일 — CODEF 자동 가져오기를 켠 범위는 지난 3일의 카드 승인내역(·홈택스 증빙)을, 영수증 지우기를 켠 범위는 보관 기한이 지난 영수증을
 * 지운다. 서버를 켤 때 한 번(10분 뒤), 그 뒤 하루에 한 번. 실패해도 다른 범위는 계속한다.
 */
export function startFinanceJobs(io) {
  const run = async () => {
    if (codefStatus().enabled) {
      for (const s of await listFinanceSettings('autoSync').catch(() => [])) {
        const connectedId = readSecret(s.codefCardConnectedId);
        if (!connectedId) continue;
        const to = todayKey();
        const from = shiftDays(to, -3);
        try {
          const cards = await syncCodefCards({ scopeKey: s.scopeKey, connectedId, from, to });
          const hometaxId = readSecret(s.codefHometaxConnectedId);
          const kinds = codefStatus().hometaxKinds;
          const hometax = hometaxId && kinds.length ? await syncCodefHometax({ scopeKey: s.scopeKey, connectedId: hometaxId, from, to, kinds }) : null;
          await upsertFinanceSettings(s.scopeKey, {
            codefLastSyncAt: new Date(),
            codefLastResult: { at: Date.now(), from, to, auto: true, cards: { read: cards.read, inserted: cards.inserted, duplicates: cards.duplicates, paired: cards.paired, errors: cards.errors }, ...(hometax && { hometax }) },
          });
          for (const id of new Set(cards.cards.filter((c) => cards.cardIds.includes(c.id)).flatMap((c) => c.holderIds ?? []))) {
            io.to(`user:${id}`).emit('groupware:changed', { cards: true, scopeKey: s.scopeKey });
          }
        } catch (err) {
          console.error('[codef] 자동 가져오기 실패:', s.scopeKey, err?.message ?? err);
        }
      }
    }
    for (const s of await listFinanceSettings('purge').catch(() => [])) {
      try {
        const n = await purgeExpiredReceipts(s.scopeKey, s);
        if (n > 0) console.log(`[finance] ${s.scopeKey}: 보관 기한 지난 영수증 ${n}개 지움`);
      } catch (err) {
        console.error('[finance] 영수증 정리 실패:', s.scopeKey, err?.message ?? err);
      }
    }
  };
  setTimeout(() => run().catch(() => {}), 10 * 60_000).unref?.();
  setInterval(() => run().catch(() => {}), 24 * 3600_000).unref?.();
}
