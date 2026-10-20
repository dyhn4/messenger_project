import ExcelJS from 'exceljs';
import { Router } from 'express';
import { accountsOf, payrollVoucherLines, voucherSheet, voucherTotals } from './accountingRules.js';
import { AUDIT, recordAudit } from './audit.js';
import { decryptField, encryptField } from './crypto.js';
import { findFinanceSettings } from './db/queries/finance.js';
import { findHireDate, findWorkWage, listGroupwareMembers } from './db/queries/groupware.js';
import {
  deleteInsuranceReport,
  deleteYearEndClaim,
  findInsuranceReport,
  findPayrollRun,
  findPayrollSettings,
  findYearEndClaim,
  insertInsuranceReport,
  insertPayrollRun,
  listInsuranceReports,
  listPayrollRuns,
  listPayslipsOfRun,
  listPublishedPayslips,
  listYearEndClaims,
  submitYearEndClaim,
  updateInsuranceReport,
  updatePayslipsBulk,
  upsertPayrollSettings,
  upsertYearEndClaim,
} from './db/queries/payroll.js';
import { BUILTIN_TEMPLATES, FIELDS, findTemplate, normalizeRrn, parseTemplates, renderTemplate, toCsv } from './exportTemplateRules.js';
import { isUuid } from './favoritesRules.js';
import { fail, groupwareContext } from './groupware.js';
import { yearEndEstimate } from './incomeTaxRules.js';
import { payrollLocked, readBankAccounts, readData, sealData } from './payroll.js';
import {
  BANKS,
  insuranceRecords,
  LOSS_REASONS,
  parseInsuranceReport,
  reportDeadline,
  suggestInsuranceReports,
  transferRecords,
  yearTotals,
} from './payrollReportRules.js';
import { canManagePayroll, parseItems, payslipTotals, setItem } from './payrollRules.js';
import { calculateSeverance, severancePayslipData } from './severanceRules.js';
import { parseYearEndClaim, taxLaw } from './yearEndClaimRules.js';

const ms = (v) => (v ? new Date(v).getTime() : null);
const todayKey = () => new Date(Date.now() + 9 * 3600_000).toISOString().slice(0, 10);
const isYear = (v) => /^\d{4}$/.test(String(v ?? '')) && Number(v) >= 2000 && Number(v) <= 2100;

/** 연말정산 정산분을 넣을 공제 항목 이름(엑셀 가져오기·한 해 집계가 "연말정산"으로 알아본다 — payrollReportRules.js deductionBucket). */
export const YEAR_END_ITEMS = Object.freeze({ incomeTax: '연말정산 소득세', localTax: '연말정산 지방소득세' });

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

/** 시트 하나 — 머리 줄(굵게)·줄들·[amountCols](1부터)는 #,##0. */
function addSheet(wb, title, header, rows, { amountCols = [], widths = null } = {}) {
  const ws = wb.addWorksheet(title);
  ws.addRow(header).font = { bold: true };
  for (const r of rows) ws.addRow(r);
  header.forEach((h, i) => {
    const col = ws.getColumn(i + 1);
    col.width = widths?.[i] ?? Math.min(40, Math.max(10, [...String(h)].length * 1.8));
    if (amountCols.includes(i + 1)) col.numFmt = '#,##0';
  });
  ws.views = [{ state: 'frozen', ySplit: 1 }];
  return ws;
}

/**
 * 내보내기 양식대로 만든 표([table] — exportTemplateRules.js renderTemplate)를 시트 하나로. 머리 줄이 없는 양식이면 첫 줄부터 자료, 금액 칸은 숫자
 * (#,##0), 앞 0이 지워지면 안 되는 칸(은행코드·계좌번호·주민등록번호·부호)은 글자로 둔다.
 */
function addTemplateSheet(wb, title, template, table) {
  const ws = wb.addWorksheet(title);
  if (table.header) ws.addRow(table.header).font = { bold: true };
  const text = new Set(table.text);
  for (const r of table.rows) ws.addRow(r.map((v, i) => (text.has(i) && v !== '' ? String(v) : v)));
  template.columns.forEach((c, i) => {
    const column = ws.getColumn(i + 1);
    column.width = Math.min(40, Math.max(10, [...String(c.header || c.field)].length * 1.8));
    if (table.numeric.includes(i)) column.numFmt = '#,##0';
    if (text.has(i)) column.numFmt = '@';
  });
  if (table.header) ws.views = [{ state: 'frozen', ySplit: 1 }];
  return ws;
}

/** CSV 보내기(UTF-8 BOM). */
function sendCsv(res, csv, name, ascii) {
  res
    .set({
      'content-type': 'text/csv; charset=utf-8',
      'content-disposition': `attachment; filename="${ascii}"; filename*=UTF-8''${encodeURIComponent(name)}`,
      'cache-control': 'no-store',
    })
    .send(Buffer.from(csv, 'utf8'));
}

/** 한 해의 공제 자료 행 → 앱 모양(금액 없이 — 상태만). */
const claimStatusDto = (row) =>
  row
    ? {
        exists: true,
        submittedAt: row.submittedAt ? new Date(row.submittedAt).getTime() : null,
        confirmedAt: row.confirmedAt ? new Date(row.confirmedAt).getTime() : null,
        confirmedByName: row.confirmedByName ?? null,
        updatedByName: row.updatedByName,
        updatedAt: new Date(row.updatedAt).getTime(),
      }
    : { exists: false };

/** 암호화한 공제 자료 → 객체 | null(깨졌으면 null — 다시 넣으면 새로 쓴다). */
export function readClaim(stored) {
  if (!stored) return null;
  try {
    return JSON.parse(decryptField(stored));
  } catch {
    return null;
  }
}

/** 한 해 합계 → 연말정산 어림에 넣을 값. */
const estimateInput = (t) => ({
  taxable: t.taxable,
  pension: t.pension,
  insurance: t.health + t.longTermCare + t.employment,
  withheldIncomeTax: t.incomeTax,
  withheldLocalTax: t.localTax,
});

/**
 * 급여 부가 기능 — 급여 담당자(payroll.js와 같다)만(내 연말정산 공제 자료는 받는 사람). 한 해 급여 집계와 연말정산 어림(참고용 — 사람마다 공제 자료를
 * 반영, 정산분을 작성 중인 대장에 넣기), 연말정산 공제 자료(근로자가 내고 담당자가 확인 — 암호화), 퇴직금 계산(평균임금·퇴직소득세 — 명세서로 만들기),
 * 4대보험 취득·상실 신고 자료(기한·신고함 표시·내보내기 양식으로 파일 — 주민등록번호는 요청에만), 급여 이체 파일(은행 대량 이체 — 내보내기 양식),
 * 급여 대장의 회계 전표. 규칙은 incomeTaxRules.js·yearEndClaimRules.js·severanceRules.js·payrollReportRules.js·exportTemplateRules.js·
 * accountingRules.js. 내려받기·명세서 만들기·공제 자료 확인은 감사 로그에 남긴다(금액·주민등록번호 없이).
 */
export function createPayrollReportsRouter(io) {
  const router = Router();

  const withStaff = (handler) => async (req, res) => {
    const ctx = await groupwareContext(req.user.sub, req.query.teamId ?? req.body?.teamId);
    if (ctx.error) return fail(res, ctx);
    const settings = await findPayrollSettings(ctx.scopeKey);
    if (!canManagePayroll({ isManager: ctx.isManager, userId: ctx.user.id, staffIds: settings?.staffIds ?? [] })) {
      return fail(res, { error: '급여 담당자만 할 수 있습니다.', status: 403 });
    }
    return handler(req, res, { ...ctx, payrollSettings: settings });
  };

  const actorName = (ctx) => ctx.user.name ?? ctx.user.username;
  const audit = (ctx, action, detail, { targetId = null, targetLabel = null } = {}) =>
    recordAudit({
      actorId: ctx.user.id,
      actorName: actorName(ctx),
      action,
      teamId: ctx.teamId,
      teamName: ctx.team?.name ?? null,
      targetType: 'payroll',
      targetId,
      targetLabel,
      detail,
    });
  const emitToStaff = (ctx) => {
    for (const id of new Set([ctx.user.id, ...(ctx.payrollSettings?.staffIds ?? [])])) {
      io.to(`user:${id}`).emit('groupware:changed', { payroll: true, scopeKey: ctx.scopeKey });
    }
  };

  async function loadRun(req, res, ctx) {
    const run = isUuid(req.params.id) ? await findPayrollRun(req.params.id) : null;
    if (!run || run.scopeKey !== ctx.scopeKey) {
      fail(res, { error: '급여 대장을 찾을 수 없습니다.', status: 404 });
      return null;
    }
    return run;
  }

  /** 사람마다 그해 지급일의 보낸 명세서들 → `Map(userId → { name, employeeNo, slips: [{ payMonth, data }] })`. */
  async function yearSlips(ctx, year, userId = null) {
    const rows = await listPublishedPayslips(ctx.scopeKey, { from: `${year}-01-01`, to: `${year}-12-31`, userId });
    const out = new Map();
    for (const { slip, run } of rows) {
      const entry = out.get(slip.userId) ?? { name: slip.userName, employeeNo: slip.employeeNo, slips: [] };
      entry.name = slip.userName;
      entry.employeeNo = slip.employeeNo ?? entry.employeeNo;
      entry.slips.push({ payMonth: run.payMonth, data: readData(slip.data) });
      out.set(slip.userId, entry);
    }
    return out;
  }

  // ── 한 해 집계·연말정산 어림 ──

  /** 한 해 급여 집계 `?year=` — 사람마다 지급·비과세·과세·4대보험·소득세 합계와 연말정산 어림(참고용), 정산분을 넣을 작성 중인 대장들. */
  router.get(
    '/groupware/payroll/year-summary',
    withStaff(async (req, res, ctx) => {
      const year = isYear(req.query.year) ? Number(req.query.year) : Number(todayKey().slice(0, 4)) - 1;
      const [byUser, claims] = await Promise.all([yearSlips(ctx, year), listYearEndClaims(ctx.scopeKey, year)]);
      const claimOf = new Map(claims.map((c) => [c.userId, c]));
      const profiles = ctx.payrollSettings?.taxProfiles ?? {};
      const people = [...byUser.entries()]
        .map(([userId, e]) => {
          const totals = yearTotals(e.slips);
          const profile = profiles[userId] ?? null;
          const row = claimOf.get(userId) ?? null;
          return {
            userId,
            name: e.name,
            employeeNo: e.employeeNo ?? null,
            profile: profile ?? { dependents: 1, children: 0, ratio: 100 },
            totals,
            claim: claimStatusDto(row),
            estimate: yearEndEstimate(estimateInput(totals), profile, { claim: readClaim(row?.data), taxYear: year }),
          };
        })
        .sort((a, b) => a.name.localeCompare(b.name, 'ko'));
      const drafts = (await listPayrollRuns(ctx.scopeKey, { status: 'draft' })).map((r) => ({ id: r.id, title: r.title, payMonth: r.payMonth }));
      res.json({ year, people, draftRuns: drafts });
    }),
  );

  /** 한 해 급여 집계 엑셀(근로소득 원천징수부 모양 — 사람마다 달별 줄 + 합계, 연말정산 어림). */
  router.get(
    '/groupware/payroll/year-summary/export',
    withStaff(async (req, res, ctx) => {
      if (!isYear(req.query.year)) return fail(res, { error: '연도를 고르세요.' });
      const year = Number(req.query.year);
      const [byUser, claims] = await Promise.all([yearSlips(ctx, year), listYearEndClaims(ctx.scopeKey, year)]);
      const claimOf = new Map(claims.map((c) => [c.userId, c]));
      const profiles = ctx.payrollSettings?.taxProfiles ?? {};
      const wb = new ExcelJS.Workbook();
      const summaryHeader = [
        '이름',
        '사번',
        '지급 개월',
        '지급 총액',
        '비과세',
        '총급여(과세)',
        '국민연금',
        '건강보험',
        '장기요양',
        '고용보험',
        '소득세(기납부)',
        '지방소득세(기납부)',
        '정산분',
        '그 밖의 공제',
        '실수령 합계',
        '가족 수',
        '8~20세 자녀',
        '공제 자료',
        '신용카드 등 공제',
        '공제 자료 세액공제',
        '결정세액(어림)',
        '차감 소득세(어림 — +추징 / −환급)',
        '차감 지방소득세(어림)',
      ];
      const summary = [];
      const monthly = [];
      for (const [userId, e] of [...byUser.entries()].sort((a, b) => a[1].name.localeCompare(b[1].name, 'ko'))) {
        const t = yearTotals(e.slips);
        const p = profiles[userId] ?? null;
        const row = claimOf.get(userId) ?? null;
        const est = yearEndEstimate(estimateInput(t), p, { claim: readClaim(row?.data), taxYear: year });
        const claimLabel = !row ? '없음' : row.confirmedAt ? '확인함' : row.submittedAt ? '냄' : '담당자가 넣음';
        summary.push([
          e.name,
          e.employeeNo ?? '',
          t.months,
          t.gross,
          t.taxFree,
          t.taxable,
          t.pension,
          t.health,
          t.longTermCare,
          t.employment,
          t.incomeTax,
          t.localTax,
          t.settlement,
          t.other,
          t.net,
          p?.dependents ?? 1,
          p?.children ?? 0,
          claimLabel,
          est.claim?.deductions.card ?? 0,
          est.claimCredit ?? 0,
          est.decidedTax,
          est.diffIncomeTax,
          est.diffLocalTax,
        ]);
        for (const s of e.slips) {
          const st = yearTotals([s]);
          monthly.push([e.name, e.employeeNo ?? '', s.payMonth, st.gross, st.taxFree, st.taxable, st.pension, st.health, st.longTermCare, st.employment, st.incomeTax, st.localTax, st.net]);
        }
      }
      addSheet(wb, `${year}년 집계`, summaryHeader, summary, { amountCols: [4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 19, 20, 21, 22, 23] });
      addSheet(
        wb,
        '달별',
        ['이름', '사번', '귀속 월', '지급 총액', '비과세', '과세', '국민연금', '건강보험', '장기요양', '고용보험', '소득세', '지방소득세', '실수령'],
        monthly,
        { amountCols: [4, 5, 6, 7, 8, 9, 10, 11, 12, 13] },
      );
      const info = wb.addWorksheet('안내');
      for (const line of [
        [`${year}년 지급일의 보낸 급여명세서를 모은 표입니다(근로소득 원천징수부·연말정산 자료로 씁니다).`],
        ['결정세액·차감세액은 근로소득공제·기본공제(가족 수)·국민연금·보험료(또는 표준세액공제)·근로소득세액공제·자녀세액공제와 연말정산 공제 자료로 계산한 어림입니다.'],
        ['공제 자료(신용카드·의료비·교육비·기부금·주택자금·연금계좌·월세 등)는 근로자나 담당자가 홈택스 간소화 자료의 합계를 넣은 값입니다. 실제 정산은 세무 프로그램·홈택스로 하세요.'],
        [
          taxLaw(year).assumed
            ? `${year}년 귀속 세법이 아직 들어가 있지 않아 어림은 ${taxLaw(year).year}년 귀속 세법으로 셌습니다.`
            : `어림은 ${year}년 귀속 세법(자녀세액공제·신용카드 등 한도·소득공제 종합한도 2,500만 원 등)으로 셌습니다.`,
        ],
      ])
        info.addRow(line);
      info.getColumn(1).width = 110;
      audit(ctx, AUDIT.payrollReport, `${year}년 급여 집계 내려받기`);
      await sendWorkbook(res, wb, `급여집계-${year}.xlsx`, 'payroll-year.xlsx');
    }),
  );

  /**
   * 연말정산 정산분 넣기 `{ year, rows: [{ userId, incomeTax, localTax }] }` — 작성 중인 대장의 명세서에 "연말정산 소득세"·"연말정산 지방소득세"
   * 공제 항목을 넣는다(양수는 추징, 음수는 환급 — 계산 방법 "2025년 귀속 연말정산"). 0원이면 그 항목을 지운다. 대장에 없는 사람은 건너뛴다.
   */
  router.post(
    '/groupware/payroll/runs/:id/year-end',
    withStaff(async (req, res, ctx) => {
      const run = await loadRun(req, res, ctx);
      if (!run) return;
      if (run.status !== 'draft') return fail(res, { error: '작성 중인 대장에만 넣을 수 있습니다.', status: 409 });
      if (!isYear(req.body?.year)) return fail(res, { error: '귀속 연도를 고르세요.' });
      const rows = Array.isArray(req.body?.rows) ? req.body.rows : [];
      const wanted = new Map();
      for (const r of rows) {
        const it = Number(r?.incomeTax);
        const lt = Number(r?.localTax);
        if (!isUuid(r?.userId) || !Number.isInteger(it) || !Number.isInteger(lt) || Math.abs(it) > 1_000_000_000 || Math.abs(lt) > 1_000_000_000) {
          return fail(res, { error: '정산 금액을 원 단위 정수로 넣으세요.' });
        }
        wanted.set(r.userId, { incomeTax: it, localTax: lt });
      }
      const basis = `${req.body.year}년 귀속 연말정산`;
      const updates = [];
      for (const slip of await listPayslipsOfRun(run.id)) {
        const w = wanted.get(slip.userId);
        if (!w) continue;
        const data = readData(slip.data);
        let deductions = data.deductions ?? [];
        for (const [key, name] of Object.entries(YEAR_END_ITEMS)) {
          deductions = w[key] ? setItem(deductions, name, w[key], basis) : deductions.filter((i) => i.name !== name);
        }
        if (parseItems(deductions, { label: '공제' }).error) return fail(res, { error: `${slip.userName}: 공제 항목이 너무 많습니다.` });
        updates.push({ id: slip.id, patch: { data: sealData({ ...data, deductions }) } });
      }
      await updatePayslipsBulk(updates);
      audit(ctx, AUDIT.payrollReport, `연말정산 정산분 넣기 — ${run.title} (${updates.length}명, ${req.body.year}년 귀속)`, { targetId: run.id, targetLabel: run.title });
      emitToStaff(ctx);
      res.json({ updated: updates.length });
    }),
  );

  // ── 연말정산 공제 자료 ──

  /** 공제 자료를 낼 수 있는 귀속 연도 — 지난 2년과 올해. */
  const claimYearOk = (y) => {
    const now = Number(todayKey().slice(0, 4));
    return isYear(y) && Number(y) >= now - 2 && Number(y) <= now;
  };
  const claimDto = (row) => ({ ...claimStatusDto(row), claim: readClaim(row?.data) });

  /** 한 사람의 공제 자료 `?year=` — 담당자. */
  router.get(
    '/groupware/payroll/year-end/claims/:userId',
    withStaff(async (req, res, ctx) => {
      if (!isUuid(req.params.userId) || !isYear(req.query.year)) return fail(res, { error: '사람과 귀속 연도를 고르세요.' });
      res.json(claimDto(await findYearEndClaim(ctx.scopeKey, req.params.userId, Number(req.query.year))));
    }),
  );

  /**
   * 공제 자료 넣기·고치기(담당자) `{ year, claim?, confirmed?: true | false }` — claim이 null이면 지운다. confirmed: true면 확인(근로자가 더
   * 고치지 못함), false면 확인을 푼다. 금액은 감사 로그에 남기지 않는다.
   */
  router.put(
    '/groupware/payroll/year-end/claims/:userId',
    withStaff(async (req, res, ctx) => {
      const body = req.body ?? {};
      if (!isUuid(req.params.userId) || !isYear(body.year)) return fail(res, { error: '사람과 귀속 연도를 고르세요.' });
      const year = Number(body.year);
      const members = await listGroupwareMembers({ scope: ctx.scope, teamId: ctx.teamId });
      const member = members.find((m) => m.id === req.params.userId);
      if (!member) return fail(res, { error: '이 범위의 구성원이 아닙니다.', status: 404 });
      const current = await findYearEndClaim(ctx.scopeKey, member.id, year);
      let claim = readClaim(current?.data);
      if (body.claim !== undefined) {
        const parsed = parseYearEndClaim(body.claim);
        if (parsed.error) return fail(res, parsed);
        claim = parsed.claim;
      }
      if (!claim) {
        // 자료가 없는데 확인만 하려 했으면 지울 것도 없다.
        if (!current) return body.claim === undefined ? fail(res, { error: '확인할 공제 자료가 없습니다.' }) : res.json(claimDto(null));
        await deleteYearEndClaim(current.id);
        audit(ctx, AUDIT.payrollReport, `연말정산 공제 자료 지움 — ${member.name ?? member.username} (${year}년 귀속)`);
        emitToStaff(ctx);
        return res.json(claimDto(null));
      }
      const confirm =
        body.confirmed === true
          ? { confirmedAt: new Date(), confirmedByName: actorName(ctx) }
          : body.confirmed === false
            ? { confirmedAt: null, confirmedByName: null }
            : {};
      const row = await upsertYearEndClaim({
        scopeKey: ctx.scopeKey,
        userId: member.id,
        year,
        data: encryptField(JSON.stringify(claim)),
        updatedByName: actorName(ctx),
        ...confirm,
      });
      const what = body.confirmed === true ? '확인' : body.confirmed === false ? '확인 풀기' : '고침';
      audit(ctx, AUDIT.payrollReport, `연말정산 공제 자료 ${what} — ${member.name ?? member.username} (${year}년 귀속)`);
      emitToStaff(ctx);
      io.to(`user:${member.id}`).emit('groupware:changed', { payroll: true, scopeKey: ctx.scopeKey });
      res.json(claimDto(row));
    }),
  );

  /** 받는 사람 — 범위 구성원 누구나(급여 담당자가 아니어도). 비밀번호 다시 묻기를 켠 범위면 명세서처럼 확인 표(?unlock=)가 있어야 한다. */
  const withMember = (handler) => async (req, res) => {
    const ctx = await groupwareContext(req.user.sub, req.query.teamId ?? req.body?.teamId);
    if (ctx.error) return fail(res, ctx);
    const settings = await findPayrollSettings(ctx.scopeKey);
    if (payrollLocked(req, ctx.user, settings)) {
      return res.status(423).json({ error: '연말정산 자료를 보려면 비밀번호를 다시 확인하세요.', code: 'payroll_locked' });
    }
    return handler(req, res, { ...ctx, payrollSettings: settings });
  };

  /**
   * 내 공제 자료 `?year=`(비우면 지난해) — 내 자료·확인 여부와, 그해 내 명세서로 계산한 연말정산 어림(참고용). 그해 명세서가 없으면 totals는 0.
   */
  router.get(
    '/groupware/payroll/year-end/mine',
    withMember(async (req, res, ctx) => {
      const year = isYear(req.query.year) ? Number(req.query.year) : Number(todayKey().slice(0, 4)) - 1;
      const [row, slips] = await Promise.all([findYearEndClaim(ctx.scopeKey, ctx.user.id, year), yearSlips(ctx, year, ctx.user.id)]);
      const totals = yearTotals(slips.get(ctx.user.id)?.slips ?? []);
      const profile = ctx.payrollSettings?.taxProfiles?.[ctx.user.id] ?? null;
      res.json({
        year,
        ...claimDto(row),
        canEdit: claimYearOk(year) && !row?.confirmedAt,
        profile: profile ?? { dependents: 1, children: 0, ratio: 100 },
        totals,
        estimate: yearEndEstimate(estimateInput(totals), profile, { claim: readClaim(row?.data), taxYear: year }),
      });
    }),
  );

  /** 내 공제 자료 내기 `{ year, claim }` — 담당자가 확인한 뒤에는 409. 담당자들에게 화면을 다시 받게 알린다. */
  router.put(
    '/groupware/payroll/year-end/mine',
    withMember(async (req, res, ctx) => {
      const body = req.body ?? {};
      if (!claimYearOk(body.year)) return fail(res, { error: '지난 2년과 올해의 자료만 낼 수 있습니다.' });
      const year = Number(body.year);
      const parsed = parseYearEndClaim(body.claim);
      if (parsed.error) return fail(res, parsed);
      const current = await findYearEndClaim(ctx.scopeKey, ctx.user.id, year);
      if (current?.confirmedAt) return fail(res, { error: '담당자가 확인한 자료라 고칠 수 없습니다. 급여 담당자에게 확인을 풀어 달라고 하세요.', status: 409 });
      if (!parsed.claim) {
        if (current) await deleteYearEndClaim(current.id);
        emitToStaff(ctx);
        return res.json({ year, ...claimDto(null), canEdit: true });
      }
      const row = await submitYearEndClaim({
        scopeKey: ctx.scopeKey,
        userId: ctx.user.id,
        year,
        data: encryptField(JSON.stringify(parsed.claim)),
        submittedAt: new Date(),
        updatedByName: actorName(ctx),
      });
      if (!row) return fail(res, { error: '담당자가 확인한 자료라 고칠 수 없습니다. 급여 담당자에게 확인을 풀어 달라고 하세요.', status: 409 });
      audit(ctx, AUDIT.payrollReport, `연말정산 공제 자료 냄 (${year}년 귀속)`);
      emitToStaff(ctx);
      res.json({ year, ...claimDto(row), canEdit: true });
    }),
  );

  // ── 퇴직금 ──

  /** 퇴직금 계산에 넣을 값 — 입사일(비우면 관리 탭의 입사일)·통상시급(비우면 관리 탭)·평균임금 기간의 명세서. */
  async function severanceInput(ctx, body) {
    if (!isUuid(body?.userId)) return { error: '사람을 고르세요.' };
    const members = await listGroupwareMembers({ scope: ctx.scope, teamId: ctx.teamId });
    const member = members.find((m) => m.id === body.userId);
    if (!member) return { error: '이 범위의 구성원이 아닙니다.', status: 404 };
    const hireDate = typeof body.hireDate === 'string' && body.hireDate ? body.hireDate : await findHireDate({ scope: ctx.scope, teamId: ctx.teamId, userId: member.id });
    const wage = body.hourlyWage === undefined || body.hourlyWage === null || body.hourlyWage === '' ? (await findWorkWage(ctx.scopeKey, member.id))?.hourlyWage ?? 0 : body.hourlyWage;
    // 평균임금 기간(마지막 근무일 전 3개월) 언저리의 명세서 — 귀속 월 합계(같은 달 대장이 여럿이면 더한다 — 상여 대장 등).
    let wageMonths = [];
    if (typeof body.lastDay === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(body.lastDay)) {
      const y = Number(body.lastDay.slice(0, 4));
      const rows = await listPublishedPayslips(ctx.scopeKey, { from: `${y - 1}-01-01`, to: `${y + 1}-12-31`, userId: member.id });
      const byMonth = new Map();
      for (const { slip, run } of rows) byMonth.set(run.payMonth, (byMonth.get(run.payMonth) ?? 0) + payslipTotals(readData(slip.data)).gross);
      wageMonths = [...byMonth.entries()].map(([payMonth, gross]) => ({ payMonth, gross }));
    }
    const employeeNo = ctx.payrollSettings?.employeeNos?.[member.id] ?? null;
    return { member, employeeNo, input: { ...body, hireDate, hourlyWage: wage, wageMonths } };
  }

  /** 퇴직금 계산 `{ userId, lastDay, hireDate?, annualBonus?, leavePay?, wages?, hourlyWage? }` → 계산 내역(참고용). */
  router.post(
    '/groupware/payroll/severance',
    withStaff(async (req, res, ctx) => {
      const prepared = await severanceInput(ctx, req.body);
      if (prepared.error) return fail(res, prepared);
      const result = calculateSeverance(prepared.input);
      if (result.error) return fail(res, result);
      res.json({ ...result, userId: prepared.member.id, name: prepared.member.name });
    }),
  );

  /** 퇴직금 명세서 만들기 `{ …위와 같음, payDate }` — 그 사람 한 명의 작성 중인 대장("퇴직금 — 이름")을 만든다. */
  router.post(
    '/groupware/payroll/severance/run',
    withStaff(async (req, res, ctx) => {
      const prepared = await severanceInput(ctx, req.body);
      if (prepared.error) return fail(res, prepared);
      const result = calculateSeverance(prepared.input);
      if (result.error) return fail(res, result);
      if (!result.eligible) return fail(res, { error: '계속근로기간이 1년이 되지 않아 퇴직금이 없습니다.' });
      const payDate = typeof req.body?.payDate === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(req.body.payDate) ? req.body.payDate : todayKey();
      const name = prepared.member.name ?? prepared.member.username;
      const run = await insertPayrollRun(
        {
          scopeKey: ctx.scopeKey,
          teamId: ctx.teamId,
          title: `퇴직금 — ${name}`.slice(0, 60),
          payMonth: result.lastDay.slice(0, 7),
          payDate,
          note: null,
          status: 'draft',
          createdBy: ctx.user.id,
          createdByName: actorName(ctx),
        },
        [{ userId: prepared.member.id, userName: name, employeeNo: prepared.employeeNo, department: null, position: null, data: sealData(severancePayslipData(result)) }],
      );
      audit(ctx, AUDIT.payrollReport, `퇴직금 명세서 만들기 — ${name}`, { targetId: run.id, targetLabel: run.title });
      emitToStaff(ctx);
      res.status(201).json({ runId: run.id });
    }),
  );

  // ── 4대보험 취득·상실 신고 ──

  const readReportData = (stored) => {
    if (!stored) return {};
    try {
      return JSON.parse(decryptField(stored)) ?? {};
    } catch {
      return {};
    }
  };
  const reportDto = (r) => ({
    id: r.id,
    userId: r.userId,
    userName: r.userName,
    kind: r.kind,
    eventDate: r.eventDate,
    deadline: reportDeadline(r.eventDate),
    reasonCode: r.reasonCode ?? null,
    ...readReportData(r.data),
    filedAt: ms(r.filedAt),
    filedByName: r.filedByName ?? null,
    createdByName: r.createdByName,
    createdAt: ms(r.createdAt),
  });

  /** 신고 목록 — 신고할 것·한 것, 입사일로 짐작한 신고할 사람(제안), 상실 사유 코드들. */
  router.get(
    '/groupware/payroll/insurance-reports',
    withStaff(async (req, res, ctx) => {
      const [reports, members] = await Promise.all([listInsuranceReports(ctx.scopeKey), listGroupwareMembers({ scope: ctx.scope, teamId: ctx.teamId })]);
      res.json({
        items: reports.map(reportDto),
        suggestions: suggestInsuranceReports(
          members.filter((m) => !m.deletedAt),
          reports,
          todayKey(),
        ),
        lossReasons: LOSS_REASONS,
        today: todayKey(),
      });
    }),
  );

  /** 그해 보수총액·근무 개월(상실 신고 — 보낸 명세서의 과세 급여). */
  async function payTotals(ctx, userId, year) {
    const rows = await listPublishedPayslips(ctx.scopeKey, { from: `${year}-01-01`, to: `${year}-12-31`, userId });
    const t = yearTotals(rows.map(({ slip, run }) => ({ payMonth: run.payMonth, data: readData(slip.data) })));
    return { pay: t.taxable, months: t.months };
  }

  /** 최근 보낸 명세서의 과세 급여(취득 신고의 보수월액 기본값). */
  async function latestMonthlyPay(ctx, userId) {
    const y = Number(todayKey().slice(0, 4));
    const rows = await listPublishedPayslips(ctx.scopeKey, { from: `${y - 1}-01-01`, to: `${y}-12-31`, userId });
    const last = rows.at(-1);
    return last ? payslipTotals(readData(last.slip.data)).taxable : null;
  }

  router.post(
    '/groupware/payroll/insurance-reports',
    withStaff(async (req, res, ctx) => {
      const parsed = parseInsuranceReport(req.body);
      if (parsed.error) return fail(res, parsed);
      const members = await listGroupwareMembers({ scope: ctx.scope, teamId: ctx.teamId });
      const member = isUuid(req.body?.userId) ? members.find((m) => m.id === req.body.userId) : null;
      if (!member) return fail(res, { error: '이 범위의 구성원을 고르세요.', status: 404 });
      const data = { ...parsed.data };
      if (parsed.report.kind === 'acquire' && data.monthlyPay === undefined) data.monthlyPay = await latestMonthlyPay(ctx, member.id);
      if (parsed.report.kind === 'acquire' && data.weeklyHours === undefined) data.weeklyHours = 40;
      const row = await insertInsuranceReport({
        scopeKey: ctx.scopeKey,
        userId: member.id,
        userName: member.name ?? member.username,
        kind: parsed.report.kind,
        eventDate: parsed.report.eventDate,
        reasonCode: parsed.report.reasonCode ?? null,
        data: encryptField(JSON.stringify(data)),
        createdByName: actorName(ctx),
      });
      emitToStaff(ctx);
      res.status(201).json(reportDto(row));
    }),
  );

  /** 신고 고치기 `{ eventDate?, reasonCode?, monthlyPay?, weeklyHours?, jobName?, memo?, filed?: true | false }`. */
  router.patch(
    '/groupware/payroll/insurance-reports/:id',
    withStaff(async (req, res, ctx) => {
      const report = isUuid(req.params.id) ? await findInsuranceReport(req.params.id) : null;
      if (!report || report.scopeKey !== ctx.scopeKey) return fail(res, { error: '신고를 찾을 수 없습니다.', status: 404 });
      const parsed = parseInsuranceReport({ ...req.body, kind: undefined }, { partial: true });
      if (parsed.error) return fail(res, parsed);
      const patch = { ...parsed.report };
      delete patch.kind;
      if (Object.keys(parsed.data).length) patch.data = encryptField(JSON.stringify({ ...readReportData(report.data), ...parsed.data }));
      if (req.body?.filed === true) Object.assign(patch, { filedAt: new Date(), filedByName: actorName(ctx) });
      if (req.body?.filed === false) Object.assign(patch, { filedAt: null, filedByName: null });
      const row = Object.keys(patch).length ? await updateInsuranceReport(report.id, patch) : report;
      emitToStaff(ctx);
      res.json(reportDto(row));
    }),
  );

  router.delete(
    '/groupware/payroll/insurance-reports/:id',
    withStaff(async (req, res, ctx) => {
      const report = isUuid(req.params.id) ? await findInsuranceReport(req.params.id) : null;
      if (!report || report.scopeKey !== ctx.scopeKey) return fail(res, { error: '신고를 찾을 수 없습니다.', status: 404 });
      await deleteInsuranceReport(report.id);
      emitToStaff(ctx);
      res.json({ ok: true });
    }),
  );

  /**
   * 신고 자료 파일 — [kind] 'acquire' | 'lose', [ids](비우면 아직 신고하지 않은 그 종류 모두), [templateId](내보내기 양식 — 비우면 기본 양식),
   * [rrns] `{ 신고 id: 주민등록번호 }`(POST로만 — 내보낼 때만 받고 DB·로그에 남기지 않는다. 양식에 주민등록번호 칸이 없으면 무시). 상실은 그해·
   * 전년도 보수총액과 근무 개월을 보낸 명세서로 채운다. 기본 양식은 엑셀에 "안내" 시트를 덧붙이고, 담당자 양식은 그 모양 그대로만 낸다(EDI 일괄
   * 신고에 바로 올리게).
   */
  async function sendInsuranceExport(req, res, ctx, { kind, ids, templateId, rrns }) {
    const template = findTemplate(kind, templateId, ctx.payrollSettings?.exportTemplates);
    if (!template) return fail(res, { error: '내보내기 양식을 찾을 수 없습니다.', status: 404 });
    const reports = (await listInsuranceReports(ctx.scopeKey)).filter((r) => r.kind === kind && (ids ? ids.has(r.id) : !r.filedAt));
    const employeeNos = ctx.payrollSettings?.employeeNos ?? {};
    const wantsRrn = template.columns.some((c) => c.field === 'rrn');
    const rows = [];
    for (const r of reports.sort((a, b) => (a.eventDate < b.eventDate ? -1 : 1))) {
      let rrn = null;
      if (wantsRrn && rrns?.[r.id] !== undefined && rrns[r.id] !== '') {
        rrn = normalizeRrn(rrns[r.id]);
        if (!rrn) return fail(res, { error: `${r.userName}: 주민등록번호(외국인등록번호) 13자리를 확인하세요.` });
      }
      const row = { name: r.userName, rrn, employeeNo: r.userId ? (employeeNos[r.userId] ?? null) : null, eventDate: r.eventDate, reasonCode: r.reasonCode, data: readReportData(r.data) };
      if (kind === 'lose' && r.userId) {
        const y = Number(r.eventDate.slice(0, 4));
        const [cur, prev] = await Promise.all([payTotals(ctx, r.userId, y), payTotals(ctx, r.userId, y - 1)]);
        Object.assign(row, { yearPay: cur.pay, yearMonths: cur.months, prevYearPay: prev.pay, prevYearMonths: prev.months });
      }
      rows.push(row);
    }
    const table = renderTemplate(template, insuranceRecords(kind, rows));
    const label = kind === 'acquire' ? '취득' : '상실';
    // 감사 로그에는 사람 수와 양식 이름만(주민등록번호를 넣었는지는 남긴다 — 번호는 남기지 않음).
    const withRrn = rows.some((r) => r.rrn);
    audit(ctx, AUDIT.payrollReport, `4대보험 ${label} 신고 자료 내려받기 (${rows.length}명, ${template.name}${withRrn ? ', 주민등록번호 포함' : ''})`);
    const base = `4대보험-${label}-${todayKey()}`;
    if (template.fileType === 'csv') return sendCsv(res, toCsv(table), `${base}.csv`, 'insurance-report.csv');
    const wb = new ExcelJS.Workbook();
    addTemplateSheet(wb, kind === 'acquire' ? '자격 취득' : '자격 상실', template, table);
    if (template.builtin) {
      const info = wb.addWorksheet('안내');
      for (const line of [
        ['4대사회보험 정보연계센터(www.4insure.or.kr)·각 공단 EDI의 취득·상실 신고서에 옮겨 적을 자료입니다.'],
        ['EDI 일괄 신고 파일로 바로 올리려면 내보내기 양식을 정보연계센터에서 받은 양식의 열 순서대로 만들어 그 양식으로 내려받으세요.'],
        ['신고 기한은 취득일·상실일이 속한 달의 다음 달 15일입니다. 상실일은 퇴직일(마지막 근무일의 다음 날)입니다.'],
        ['주민등록번호는 이 서버에 두지 않습니다 — 내려받을 때 넣은 번호만 이 파일에 들어갑니다. 보수총액은 보낸 급여명세서의 과세 급여 합계입니다.'],
      ])
        info.addRow(line);
      info.getColumn(1).width = 110;
    }
    await sendWorkbook(res, wb, `${base}.xlsx`, 'insurance-report.xlsx');
  }

  const exportIds = (v) => {
    if (Array.isArray(v)) return v.length ? new Set(v.filter(isUuid)) : null;
    return typeof v === 'string' && v ? new Set(v.split(',')) : null;
  };

  /** 신고 자료 파일 `?kind=acquire|lose&ids=a,b&template=` — 주민등록번호 없이. */
  router.get(
    '/groupware/payroll/insurance-reports/export',
    withStaff((req, res, ctx) =>
      sendInsuranceExport(req, res, ctx, {
        kind: req.query.kind === 'lose' ? 'lose' : 'acquire',
        ids: exportIds(req.query.ids),
        templateId: typeof req.query.template === 'string' ? req.query.template : null,
        rrns: null,
      }),
    ),
  );

  /** 신고 자료 파일(주민등록번호와 함께) `{ kind, ids?, template?, rrns: { 신고 id: '900101-1234567' } }`. */
  router.post(
    '/groupware/payroll/insurance-reports/export',
    withStaff((req, res, ctx) => {
      const body = req.body ?? {};
      const rrns = body.rrns && typeof body.rrns === 'object' && !Array.isArray(body.rrns) ? body.rrns : null;
      return sendInsuranceExport(req, res, ctx, {
        kind: body.kind === 'lose' ? 'lose' : 'acquire',
        ids: exportIds(body.ids),
        templateId: typeof body.template === 'string' ? body.template : null,
        rrns,
      });
    }),
  );

  // ── 내보내기 양식 ──

  /** 내보내기 양식 — 담당자가 만든 것·기본 양식·종류마다 고를 수 있는 칸. */
  router.get(
    '/groupware/payroll/export-templates',
    withStaff(async (req, res, ctx) => {
      res.json({ templates: ctx.payrollSettings?.exportTemplates ?? [], builtins: BUILTIN_TEMPLATES, fields: FIELDS });
    }),
  );

  /** 내보내기 양식 저장 `{ templates: [...] }`(전부 — 빠진 양식은 지운다). */
  router.put(
    '/groupware/payroll/export-templates',
    withStaff(async (req, res, ctx) => {
      const parsed = parseTemplates(req.body?.templates);
      if (parsed.error) return fail(res, parsed);
      const row = await upsertPayrollSettings(ctx.scopeKey, { exportTemplates: parsed.templates });
      audit(ctx, AUDIT.payrollReport, `내보내기 양식 저장 (${parsed.templates.length}개)`);
      emitToStaff(ctx);
      res.json({ templates: row.exportTemplates ?? [], builtins: BUILTIN_TEMPLATES, fields: FIELDS });
    }),
  );

  // ── 급여 이체 파일·회계 전표 ──

  /** 대장의 이체 줄 — 실수령액·급여 계좌·통장 표시(회사 이름). */
  async function runTransfer(ctx, run) {
    const slips = (await listPayslipsOfRun(run.id)).map((s) => ({ userId: s.userId, userName: s.userName, employeeNo: s.employeeNo, net: payslipTotals(readData(s.data)).net }));
    const company = ctx.payrollSettings?.companyName || ctx.team?.name || '급여';
    return transferRecords(slips, readBankAccounts(ctx.payrollSettings), { senderText: company, myText: '급여' });
  }

  /** 급여 이체 미리 보기 — 이체할 사람 수·합계와 빠진 사람(계좌 없음·실수령 0원 이하). 양식을 고르기 전에 앱이 보인다. */
  router.get(
    '/groupware/payroll/runs/:id/transfer/preview',
    withStaff(async (req, res, ctx) => {
      const run = await loadRun(req, res, ctx);
      if (!run) return;
      const { records, total, missing } = await runTransfer(ctx, run);
      res.json({ count: records.length, total, missing });
    }),
  );

  /**
   * 급여 이체 파일 `?template=`(내보내기 양식 — 비우면 기본 양식) — 대장의 실수령액을 은행 대량 이체 파일로. 기본 양식은 모든 칸과 합계 줄, "빠진
   * 사람"·"은행코드" 시트를 덧붙이고, 담당자 양식(은행 기업뱅킹의 대량 이체 양식에 맞춘 열 순서)은 그 모양 그대로만 낸다(합계 줄 없이 — 은행이 줄로
   * 읽게). 감사 로그에 남긴다.
   */
  router.get(
    '/groupware/payroll/runs/:id/transfer',
    withStaff(async (req, res, ctx) => {
      const run = await loadRun(req, res, ctx);
      if (!run) return;
      const template = findTemplate('transfer', typeof req.query.template === 'string' ? req.query.template : null, ctx.payrollSettings?.exportTemplates);
      if (!template) return fail(res, { error: '내보내기 양식을 찾을 수 없습니다.', status: 404 });
      const { records, total, missing } = await runTransfer(ctx, run);
      const table = renderTemplate(template, records);
      audit(ctx, AUDIT.payrollTransfer, `급여 이체 파일 내려받기 — ${run.title} (${records.length}명, ${template.name})`, { targetId: run.id, targetLabel: run.title });
      const base = `급여이체-${run.payMonth}-${run.title}`;
      if (template.fileType === 'csv') return sendCsv(res, toCsv(table), `${base}.csv`, 'payroll-transfer.csv');
      const wb = new ExcelJS.Workbook();
      const ws = addTemplateSheet(wb, '이체', template, table);
      if (template.builtin) {
        ws.addRow([]);
        ws.addRow(['', '', '', '합계', total]).font = { bold: true };
        addSheet(wb, '빠진 사람', ['이름', '사유'], missing.map((m) => [m.userName, m.reason]), { widths: [16, 24] });
        addSheet(wb, '은행코드', ['코드', '은행'], BANKS.map((b) => [b.code, b.name]), { widths: [8, 20] });
      }
      await sendWorkbook(res, wb, `${base}.xlsx`, 'payroll-transfer.xlsx');
    }),
  );

  /** 급여 대장의 회계 전표(지급일 — 차변 급여, 대변 예수금·보통예금). 계정·모양은 지출 관리 설정(financeTools.js)을 따른다. */
  router.get(
    '/groupware/payroll/runs/:id/vouchers',
    withStaff(async (req, res, ctx) => {
      const run = await loadRun(req, res, ctx);
      if (!run) return;
      const finance = await findFinanceSettings(ctx.scopeKey);
      const slips = (await listPayslipsOfRun(run.id)).map((s) => ({ data: readData(s.data) }));
      const lines = payrollVoucherLines(run, slips, accountsOf(finance?.accountMap));
      const sheet = voucherSheet(lines, finance?.voucherFormat ?? 'generic');
      const wb = new ExcelJS.Workbook();
      addSheet(wb, '전표', sheet.header, sheet.rows, { amountCols: sheet.amountColumns });
      const totals = voucherTotals(lines);
      wb.getWorksheet('전표').addRow([]);
      wb.getWorksheet('전표').addRow([`차변 ${totals.debit.toLocaleString('ko-KR')} / 대변 ${totals.credit.toLocaleString('ko-KR')}`]);
      audit(ctx, AUDIT.payrollReport, `급여 전표 내려받기 — ${run.title}`, { targetId: run.id, targetLabel: run.title });
      await sendWorkbook(res, wb, `급여전표-${run.payMonth}-${run.title}.xlsx`, 'payroll-voucher.xlsx');
    }),
  );

  return router;
}
