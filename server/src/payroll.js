import ExcelJS from 'exceljs';
import express, { Router } from 'express';
import jwt from 'jsonwebtoken';
import { AUDIT, recordAudit } from './audit.js';
import { JWT_SECRET } from './config.js';
import { decryptField, encryptField } from './crypto.js';
import {
  countPayslipsByRun,
  deletePayrollRun,
  deletePayslip,
  findPayrollRun,
  findPayrollSettings,
  findPayslip,
  insertPayrollRun,
  insertPayslips,
  listMyPayslips,
  listPayrollRuns,
  listPayslipsOfRun,
  markPayslipViewed,
  transitionPayrollRun,
  updatePayrollRun,
  updatePayslip,
  updatePayslipsBulk,
  upsertPayrollSettings,
} from './db/queries/payroll.js';
import { listGroupwareMembers } from './db/queries/groupware.js';
import { isUuid } from './favoritesRules.js';
import { approverCandidates, fail, groupwareContext, monthSummaries } from './groupware.js';
import { parseTaxProfiles, WITHHOLDING_RATIOS } from './incomeTaxRules.js';
import { loadOrgTree } from './orgTree.js';
import { orgScopeKey } from './orgTreeRules.js';
import {
  applyAttendance,
  applyInsurance,
  blankPayslipData,
  canManagePayroll,
  carriedPayslipData,
  DEFAULT_DEDUCTION_ITEMS,
  DEFAULT_EARNING_ITEMS,
  insuranceOf,
  mergePayslipData,
  parseCompanyName,
  parseCorrectionReason,
  parseEmployeeNos,
  parseInsurance,
  parseItems,
  parseItemTemplate,
  parsePayslipData,
  parseRunInput,
  parseStaffIds,
  PAYROLL_ITEMS_MAX,
  PAYROLL_SLIPS_MAX,
  payrollSheetColumns,
  payslipNotice,
  payslipTotals,
  planPayrollImport,
} from './payrollRules.js';
import { BANKS, parseBankAccounts } from './payrollReportRules.js';
import { notifyGroupwarePush } from './push.js';
import { readSheetRows } from './sheetRows.js';
import { checkCurrentPassword } from './users.js';
import { payRatesOf } from './workPolicy.js';

const ms = (v) => (v ? new Date(v).getTime() : null);
export const readData = (stored) => {
  try {
    return JSON.parse(decryptField(stored));
  } catch {
    // 키가 바뀌었거나 깨진 값 — 빈 명세서로 보이고 고쳐 저장하면 새로 쓴다.
    return { earnings: [], deductions: [], work: null, memo: null, unreadable: true };
  }
};
export const sealData = (data) =>
  encryptField(JSON.stringify({ earnings: data.earnings, deductions: data.deductions, work: data.work ?? null, memo: data.memo ?? null }));

/** 급여 계좌(급여 설정 — 암호화) → `{ userId: { bankCode, number, holder? } }`. */
export function readBankAccounts(settings) {
  if (!settings?.bankAccounts) return {};
  try {
    const v = JSON.parse(decryptField(settings.bankAccounts));
    return v && typeof v === 'object' ? v : {};
  } catch {
    return {};
  }
}

/** 받는 사람이 비밀번호를 다시 확인한 뒤 명세서를 여는 표 — 10분, 그 기기에서만(did). */
const UNLOCK_TTL_SEC = 10 * 60;
const UNLOCK_TYPE = 'payroll-unlock';
const unlockOk = (req) => {
  const raw = typeof req.query.unlock === 'string' ? req.query.unlock : null;
  if (!raw) return false;
  try {
    const p = jwt.verify(raw, JWT_SECRET);
    return p.type === UNLOCK_TYPE && p.sub === req.user.sub && (p.did ?? null) === (req.user.did ?? null);
  } catch {
    return false;
  }
};

const readHistory = (stored) => {
  if (!stored) return [];
  try {
    const list = JSON.parse(decryptField(stored));
    return Array.isArray(list) ? list : [];
  } catch {
    return [];
  }
};

/**
 * 급여명세서 — 급여 담당자(그룹웨어 관리자 + 급여 설정의 담당자)가 달마다 **급여 대장**을 만들어(구성원마다 명세서 — 지난 대장의 항목을 이어받거나
 * 항목 틀로) 금액을 넣고(직접·엑셀 급여대장 가져오기·근태에서 연장·야간·휴일 시간과 수당 채우기·4대보험 공제 어림) **보내면** 받는 사람마다 그룹웨어
 * 푸시가 가고 그룹웨어 → 급여 탭에서 자기 명세서만 본다(처음 연 시각이 "확인"으로 남는다). 보낸 뒤 고치면 사유와 함께 정정으로 남고 다시 알린다.
 * 규칙은 payrollRules.js. 명세서 내용은 DB에 암호화해 둔다(crypto.js — `.env`의 DB_ENCRYPTION_KEY).
 *
 * 범위는 그룹웨어 범위(groupware.js groupwareContext — 팀마다 / 회사 전체). 화면이 바뀌어야 하면 groupware:changed `{ payroll: true }`.
 */
export function createPayrollRouter(io) {
  const router = Router();

  const withPayroll =
    (handler, { manage = false } = {}) =>
    async (req, res) => {
      const ctx = await groupwareContext(req.user.sub, req.query.teamId ?? req.body?.teamId);
      if (ctx.error) return fail(res, ctx);
      const settings = await findPayrollSettings(ctx.scopeKey);
      const canManage = canManagePayroll({ isManager: ctx.isManager, userId: ctx.user.id, staffIds: settings?.staffIds ?? [] });
      if (manage && !canManage) return fail(res, { error: '급여 담당자만 할 수 있습니다.', status: 403 });
      return handler(req, res, { ...ctx, payrollSettings: settings, canManagePayroll: canManage });
    };

  const actorName = (ctx) => ctx.user.name ?? ctx.user.username;

  function audit(ctx, action, { targetId = null, targetLabel = null, detail = null } = {}) {
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
  }

  /** 급여 담당자들(관리자 포함 — 화면을 다시 받게) — 이 범위의 관리자는 groupwareContext마다 다르므로 담당자 + 대장을 만든 사람에게만. */
  function emitToStaff(ctx, extra = []) {
    for (const id of new Set([ctx.user.id, ...(ctx.payrollSettings?.staffIds ?? []), ...extra].filter(Boolean))) {
      io.to(`user:${id}`).emit('groupware:changed', { payroll: true, scopeKey: ctx.scopeKey });
    }
  }

  function notifyOwners(ctx, run, userIds, { corrected = false } = {}) {
    const text = payslipNotice(run, { corrected });
    for (const userId of new Set(userIds)) {
      io.to(`user:${userId}`).emit('groupware:changed', { payroll: true, scopeKey: ctx.scopeKey });
      notifyGroupwarePush({ userId, title: text.title, body: text.body, documentId: '', teamId: ctx.teamId }).catch((e) =>
        console.error('[payroll] 푸시 실패:', e?.message ?? e),
      );
    }
  }

  /** 이 범위의 대장 — 아니면 응답하고 null. */
  async function loadRun(req, res, ctx, { draftOnly = false } = {}) {
    const run = isUuid(req.params.id) ? await findPayrollRun(req.params.id) : null;
    if (!run || run.scopeKey !== ctx.scopeKey) {
      fail(res, { error: '급여 대장을 찾을 수 없습니다.', status: 404 });
      return null;
    }
    if (draftOnly && run.status !== 'draft') {
      fail(res, { error: '이미 보낸 대장입니다. 보내기를 취소하거나 명세서마다 정정하세요.', status: 409 });
      return null;
    }
    return run;
  }

  /** 명세서에 적을 사람 정보 — 이름·사번(급여 설정)·부서·직책(조직도). */
  async function identities(ctx) {
    const orgKey = orgScopeKey(ctx.settings, ctx.teamId);
    const tree = orgKey ? await loadOrgTree(orgKey).catch(() => null) : null;
    const employeeNos = ctx.payrollSettings?.employeeNos ?? {};
    return (member) => {
      const org = tree?.members.get(member.id);
      return {
        userId: member.id,
        userName: member.name ?? member.username,
        employeeNo: employeeNos[member.id] ?? null,
        department: org?.department ?? null,
        position: org?.position ?? null,
      };
    };
  }

  const runDto = (run, counts = null) => ({
    id: run.id,
    title: run.title,
    payMonth: run.payMonth,
    payDate: run.payDate,
    note: run.note ?? null,
    status: run.status,
    createdByName: run.createdByName,
    createdAt: ms(run.createdAt),
    updatedAt: ms(run.updatedAt),
    publishedAt: ms(run.publishedAt),
    publishedByName: run.publishedByName ?? null,
    ...(counts && { slipCount: counts.count ?? 0, viewedCount: counts.viewed ?? 0 }),
  });

  /** 명세서 → 앱 모양. [full]이면 항목까지, [manager]면 정정 전 내용까지. */
  function slipDto(slip, { full = true, manager = false, username = null } = {}) {
    const data = readData(slip.data);
    const totals = payslipTotals(data);
    const history = readHistory(slip.history);
    return {
      id: slip.id,
      runId: slip.runId,
      userId: slip.userId,
      userName: slip.userName,
      ...(username !== null && { username }),
      employeeNo: slip.employeeNo ?? null,
      department: slip.department ?? null,
      position: slip.position ?? null,
      revision: slip.revision,
      correctedAt: ms(slip.correctedAt),
      viewedAt: ms(slip.viewedAt),
      updatedAt: ms(slip.updatedAt),
      ...totals,
      ...(data.unreadable && { unreadable: true }),
      ...(full && {
        earnings: data.earnings ?? [],
        deductions: data.deductions ?? [],
        work: data.work ?? null,
        memo: data.memo ?? null,
        // 정정 기록 — 언제·누가·왜, 그때(정정 전)의 합계. 담당자에게는 그때의 항목까지.
        corrections: history.map((h) => ({
          revision: h.revision,
          correctedAt: h.correctedAt ?? null,
          correctedByName: h.correctedByName ?? null,
          reason: h.reason ?? null,
          ...payslipTotals(h.data),
          ...(manager && { earnings: h.data?.earnings ?? [], deductions: h.data?.deductions ?? [] }),
        })),
      }),
    };
  }

  const companyOf = (ctx) => ctx.payrollSettings?.companyName || ctx.team?.name || null;

  /** 비밀번호로 다시 확인할 수 있는 계정인지 — 회사 계정(Google·Microsoft) 전용 계정은 비밀번호가 없어 묻지 않는다. */
  const reauthApplies = (ctx) => ctx.payrollSettings?.requireReauth === true && ctx.user.authSource !== 'sso';
  /** 받는 사람이 지금 비밀번호를 다시 확인해야 하는지(설정을 켰고, 지난 10분 안의 확인 표 ?unlock=이 없으면). */
  const needsUnlock = (req, ctx) => reauthApplies(ctx) && !unlockOk(req);

  // ── 받는 사람 ──

  /**
   * 내 명세서들(보낸 대장의 것만) — 합계만. 담당자인지(canManage)도 함께. 비밀번호를 다시 물어야 하면 금액을 빼고 `locked: true`(앱이
   * 비밀번호를 받아 POST /payroll/unlock 뒤 ?unlock=으로 다시 부른다).
   */
  router.get(
    '/groupware/payroll/mine',
    withPayroll(async (req, res, ctx) => {
      const rows = await listMyPayslips(ctx.scopeKey, ctx.user.id);
      const locked = needsUnlock(req, ctx);
      const hide = (d) => (locked ? { ...d, gross: null, taxable: null, taxFree: null, deductionTotal: null, net: null } : d);
      res.json({
        canManage: ctx.canManagePayroll,
        reauthRequired: reauthApplies(ctx),
        locked,
        items: rows.map(({ slip, run }) => ({ ...hide(slipDto(slip, { full: false })), run: runDto(run) })),
      });
    }),
  );

  /**
   * 비밀번호 다시 확인 `{ password }` → `{ token, expiresAt }`(10분 — 이 기기에서만). 틀리면 403, 여러 번 틀리면 잠깐 막는다(users.js
   * checkCurrentPassword — 화면 잠금 해제와 같은 횟수 제한). 다시 묻지 않는 범위·계정이면 `{ token: null }`.
   */
  router.post(
    '/groupware/payroll/unlock',
    withPayroll(async (req, res, ctx) => {
      if (!reauthApplies(ctx)) return res.json({ token: null, expiresAt: null });
      if (!(await checkCurrentPassword(res, ctx.user, req.body?.password, '비밀번호가 올바르지 않습니다.'))) return;
      const token = jwt.sign({ sub: ctx.user.id, ...(req.user.did && { did: req.user.did }), type: UNLOCK_TYPE }, JWT_SECRET, { expiresIn: UNLOCK_TTL_SEC });
      res.json({ token, expiresAt: Date.now() + UNLOCK_TTL_SEC * 1000 });
    }),
  );

  /** 명세서 하나 — 받는 사람(보낸 대장)이나 담당자. 받는 사람이 처음 열면 "확인" 시각을 남긴다. */
  router.get(
    '/groupware/payroll/payslips/:id',
    withPayroll(async (req, res, ctx) => {
      const found = isUuid(req.params.id) ? await findPayslip(req.params.id) : null;
      const own = found && found.slip.userId === ctx.user.id && found.run.status === 'published';
      if (!found || found.run.scopeKey !== ctx.scopeKey || (!own && !ctx.canManagePayroll)) {
        return fail(res, { error: '급여명세서를 찾을 수 없습니다.', status: 404 });
      }
      // 내 명세서를 여는데 비밀번호를 다시 물어야 하면 423(앱이 비밀번호를 받아 다시 연다). 담당자가 남의 명세서를 보는 것은 묻지 않는다.
      if (own && needsUnlock(req, ctx)) return res.status(423).json({ error: '명세서를 보려면 비밀번호를 다시 확인하세요.', code: 'payroll_locked' });
      let slip = found.slip;
      if (own && !slip.viewedAt && (await markPayslipViewed(slip.id))) {
        slip = { ...slip, viewedAt: new Date() };
        emitToStaff(ctx, [found.run.createdBy]);
      }
      res.json({ ...slipDto(slip, { manager: ctx.canManagePayroll && !own }), run: runDto(found.run), companyName: companyOf(ctx) });
    }),
  );

  // ── 급여 설정 ──

  const settingsDto = (ctx, s, people) => ({
    staffIds: s?.staffIds ?? [],
    companyName: s?.companyName ?? null,
    template: s?.itemTemplate ?? { earnings: DEFAULT_EARNING_ITEMS, deductions: DEFAULT_DEDUCTION_ITEMS },
    insurance: insuranceOf(s?.insurance),
    employeeNos: s?.employeeNos ?? {},
    // 원천징수 정보(가족 수·8~20세 자녀·비율 — 없는 사람은 본인 1명·100%)와 급여 계좌(급여 이체 파일).
    taxProfiles: s?.taxProfiles ?? {},
    withholdingRatios: WITHHOLDING_RATIOS,
    bankAccounts: readBankAccounts(s),
    banks: BANKS.map(({ code, name }) => ({ code, name })),
    requireReauth: s?.requireReauth === true,
    // 담당자는 관리자가 정한다 — 담당자 스스로는 바꾸지 못한다.
    canEditStaff: ctx.isManager,
    people: people.map((p) => ({ id: p.id, name: p.name, username: p.username })),
  });

  router.get(
    '/groupware/payroll/settings',
    withPayroll(
      async (req, res, ctx) => {
        const people = await approverCandidates(ctx);
        res.json(settingsDto(ctx, ctx.payrollSettings, [...people.values()]));
      },
      { manage: true },
    ),
  );

  /** 급여 설정 `{ staffIds?(관리자만), companyName?, template?, insurance?, employeeNos? }`. */
  router.put(
    '/groupware/payroll/settings',
    withPayroll(
      async (req, res, ctx) => {
        const body = req.body ?? {};
        const people = await approverCandidates(ctx);
        const patch = {};
        if (body.staffIds !== undefined) {
          if (!ctx.isManager) return fail(res, { error: '급여 담당자는 그룹웨어 관리자만 정할 수 있습니다.', status: 403 });
          const staff = parseStaffIds(body.staffIds, (id) => people.has(id));
          if (staff.error) return fail(res, staff);
          patch.staffIds = staff.staffIds;
        }
        const company = parseCompanyName(body.companyName);
        if (company.error) return fail(res, company);
        if (company.companyName !== undefined) patch.companyName = company.companyName;
        if (body.template !== undefined) {
          const t = parseItemTemplate(body.template);
          if (t.error) return fail(res, t);
          patch.itemTemplate = t.template;
        }
        if (body.insurance !== undefined) {
          const ins = parseInsurance(body.insurance);
          if (ins.error) return fail(res, ins);
          patch.insurance = ins.insurance;
        }
        const nos = parseEmployeeNos(body.employeeNos, ctx.payrollSettings?.employeeNos ?? {});
        if (nos.error) return fail(res, nos);
        if (nos.employeeNos !== undefined) patch.employeeNos = nos.employeeNos;
        const profiles = parseTaxProfiles(body.taxProfiles, ctx.payrollSettings?.taxProfiles ?? {});
        if (profiles.error) return fail(res, profiles);
        if (profiles.taxProfiles !== undefined) patch.taxProfiles = profiles.taxProfiles;
        const accounts = parseBankAccounts(body.bankAccounts, readBankAccounts(ctx.payrollSettings));
        if (accounts.error) return fail(res, accounts);
        // 앱은 늘 전부 보낸다 — 바뀐 것이 있을 때만 다시 쓴다(감사 로그에 "급여 계좌"가 남지 않게).
        if (accounts.bankAccounts !== undefined && JSON.stringify(accounts.bankAccounts) !== JSON.stringify(readBankAccounts(ctx.payrollSettings))) {
          patch.bankAccounts = encryptField(JSON.stringify(accounts.bankAccounts));
        }
        if (body.requireReauth !== undefined) patch.requireReauth = body.requireReauth === true;
        const row = await upsertPayrollSettings(ctx.scopeKey, patch);
        const labels = {
          staffIds: '급여 담당자',
          companyName: '회사 이름',
          itemTemplate: '항목 틀',
          insurance: '4대보험 요율',
          employeeNos: '사번',
          taxProfiles: '원천징수 정보',
          bankAccounts: '급여 계좌',
          requireReauth: '명세서 비밀번호 확인',
        };
        const changed = Object.keys(patch)
          .map((k) => labels[k])
          .filter(Boolean);
        if (changed.length) audit(ctx, AUDIT.payrollSettings, { detail: `급여 설정 — ${changed.join('·')}` });
        emitToStaff({ ...ctx, payrollSettings: row }, ctx.payrollSettings?.staffIds ?? []);
        res.json(settingsDto(ctx, row, [...people.values()]));
      },
      { manage: true },
    ),
  );

  // ── 급여 대장 ──

  router.get(
    '/groupware/payroll/runs',
    withPayroll(
      async (req, res, ctx) => {
        const runs = await listPayrollRuns(ctx.scopeKey);
        const counts = await countPayslipsByRun(runs.map((r) => r.id));
        res.json(runs.map((r) => runDto(r, counts.get(r.id) ?? { count: 0, viewed: 0 })));
      },
      { manage: true },
    ),
  );

  /**
   * 대장 만들기 `{ payMonth, payDate, title?, note?, copyFromRunId?, userIds? }` — 사람은 [userIds](범위 구성원) 또는 이 범위의 정회원 이상 모두.
   * [copyFromRunId]를 주면 그 대장의 사람마다 항목·금액을 이어받고(그 대장에 없던 사람은 항목 틀), 아니면 항목 틀(금액 0)로.
   */
  router.post(
    '/groupware/payroll/runs',
    withPayroll(
      async (req, res, ctx) => {
        const parsed = parseRunInput(req.body);
        if (parsed.error) return fail(res, parsed);
        const members = (await listGroupwareMembers({ scope: ctx.scope, teamId: ctx.teamId })).filter((m) => !m.suspendedAt && !m.deletedAt);
        let targets;
        if (Array.isArray(req.body?.userIds)) {
          const ids = new Set(req.body.userIds.filter(isUuid));
          targets = members.filter((m) => ids.has(m.id));
        } else {
          const people = await approverCandidates(ctx);
          targets = members.filter((m) => people.has(m.id));
        }
        if (targets.length > PAYROLL_SLIPS_MAX) return fail(res, { error: `한 대장에 ${PAYROLL_SLIPS_MAX}명까지 넣을 수 있습니다.` });
        let carried = new Map();
        if (req.body?.copyFromRunId) {
          const source = isUuid(req.body.copyFromRunId) ? await findPayrollRun(req.body.copyFromRunId) : null;
          if (!source || source.scopeKey !== ctx.scopeKey) return fail(res, { error: '이어받을 급여 대장을 찾을 수 없습니다.', status: 404 });
          carried = new Map((await listPayslipsOfRun(source.id)).map((s) => [s.userId, readData(s.data)]));
        }
        const who = await identities(ctx);
        const template = ctx.payrollSettings?.itemTemplate ?? null;
        const run = await insertPayrollRun(
          {
            scopeKey: ctx.scopeKey,
            teamId: ctx.teamId,
            title: parsed.run.title,
            payMonth: parsed.run.payMonth,
            payDate: parsed.run.payDate,
            note: parsed.run.note,
            status: 'draft',
            createdBy: ctx.user.id,
            createdByName: actorName(ctx),
          },
          targets.map((m) => ({
            ...who(m),
            data: sealData(carried.has(m.id) ? carriedPayslipData(carried.get(m.id)) : blankPayslipData(template)),
          })),
        );
        emitToStaff(ctx);
        res.status(201).json(runDto(run, { count: targets.length, viewed: 0 }));
      },
      { manage: true },
    ),
  );

  /** 대장 하나와 명세서들(항목까지 — 담당자가 표로 고친다). */
  router.get(
    '/groupware/payroll/runs/:id',
    withPayroll(
      async (req, res, ctx) => {
        const run = await loadRun(req, res, ctx);
        if (!run) return;
        const [slips, members] = await Promise.all([listPayslipsOfRun(run.id), listGroupwareMembers({ scope: ctx.scope, teamId: ctx.teamId })]);
        const usernameOf = new Map(members.map((m) => [m.id, m.username]));
        const dtos = slips.map((s) => slipDto(s, { manager: true, username: usernameOf.get(s.userId) ?? '' }));
        res.json({
          ...runDto(run, { count: slips.length, viewed: slips.filter((s) => s.viewedAt).length }),
          payslips: dtos,
          totals: {
            gross: dtos.reduce((s, d) => s + d.gross, 0),
            deductionTotal: dtos.reduce((s, d) => s + d.deductionTotal, 0),
            net: dtos.reduce((s, d) => s + d.net, 0),
          },
          // 아직 이 대장에 없는 구성원(더하기 고르기).
          addable: members
            .filter((m) => !m.suspendedAt && !m.deletedAt && !slips.some((s) => s.userId === m.id))
            .map((m) => ({ id: m.id, name: m.name, username: m.username })),
          companyName: companyOf(ctx),
        });
      },
      { manage: true },
    ),
  );

  /** 대장 머리 고치기 `{ title?, payDate?, note? }` — 보낸 뒤에도(받는 사람 화면에 바로 보인다). 달은 바꾸지 않는다. */
  router.patch(
    '/groupware/payroll/runs/:id',
    withPayroll(
      async (req, res, ctx) => {
        const run = await loadRun(req, res, ctx);
        if (!run) return;
        const parsed = parseRunInput({ ...req.body, payMonth: undefined }, { partial: true });
        if (parsed.error) return fail(res, parsed);
        if (!Object.keys(parsed.run).length) return res.json(runDto(run));
        const row = await updatePayrollRun(run.id, parsed.run);
        emitToStaff(ctx, [run.createdBy]);
        if (run.status === 'published') {
          for (const s of await listPayslipsOfRun(run.id)) io.to(`user:${s.userId}`).emit('groupware:changed', { payroll: true, scopeKey: ctx.scopeKey });
        }
        res.json(runDto(row));
      },
      { manage: true },
    ),
  );

  /** 작성 중인 대장 지우기(보낸 대장은 먼저 보내기 취소). */
  router.delete(
    '/groupware/payroll/runs/:id',
    withPayroll(
      async (req, res, ctx) => {
        const run = await loadRun(req, res, ctx, { draftOnly: true });
        if (!run) return;
        await deletePayrollRun(run.id);
        audit(ctx, AUDIT.payrollDelete, { targetId: run.id, targetLabel: run.title, detail: `급여 대장 삭제 — ${run.title}` });
        emitToStaff(ctx, [run.createdBy]);
        res.json({ ok: true });
      },
      { manage: true },
    ),
  );

  /** 보내기 — 받는 사람마다 그룹웨어 푸시(금액은 넣지 않는다). 동시에 두 번 눌러도 한 번만. */
  router.post(
    '/groupware/payroll/runs/:id/publish',
    withPayroll(
      async (req, res, ctx) => {
        const run = await loadRun(req, res, ctx, { draftOnly: true });
        if (!run) return;
        const slips = await listPayslipsOfRun(run.id);
        if (!slips.length) return fail(res, { error: '명세서가 없습니다. 사람을 먼저 더하세요.' });
        const row = await transitionPayrollRun(run.id, 'draft', { status: 'published', publishedAt: new Date(), publishedByName: actorName(ctx) });
        if (!row) return fail(res, { error: '이미 보낸 대장입니다.', status: 409 });
        audit(ctx, AUDIT.payrollPublish, { targetId: run.id, targetLabel: run.title, detail: `급여명세서 보냄 — ${run.title} (${slips.length}명)` });
        notifyOwners(ctx, row, slips.map((s) => s.userId));
        emitToStaff(ctx, [run.createdBy]);
        res.json(runDto(row, { count: slips.length, viewed: slips.filter((s) => s.viewedAt).length }));
      },
      { manage: true },
    ),
  );

  /** 보내기 취소 `{ reason }` — 받는 사람 화면에서 사라지고 다시 작성 중이 된다(감사 로그). */
  router.post(
    '/groupware/payroll/runs/:id/unpublish',
    withPayroll(
      async (req, res, ctx) => {
        const run = await loadRun(req, res, ctx);
        if (!run) return;
        if (run.status !== 'published') return fail(res, { error: '보내지 않은 대장입니다.', status: 409 });
        const reason = parseCorrectionReason(req.body?.reason);
        if (reason.error) return fail(res, { error: '보내기를 취소하는 사유를 쓰세요.' });
        const row = await transitionPayrollRun(run.id, 'published', { status: 'draft' });
        if (!row) return fail(res, { error: '이미 보내기를 취소한 대장입니다.', status: 409 });
        audit(ctx, AUDIT.payrollUnpublish, { targetId: run.id, targetLabel: run.title, detail: `급여명세서 보내기 취소 — ${run.title}: ${reason.reason}` });
        for (const s of await listPayslipsOfRun(run.id)) io.to(`user:${s.userId}`).emit('groupware:changed', { payroll: true, scopeKey: ctx.scopeKey });
        emitToStaff(ctx, [run.createdBy]);
        res.json(runDto(row));
      },
      { manage: true },
    ),
  );

  /** 사람 더하기 `{ userIds }` — 작성 중인 대장에만, 항목 틀로. */
  router.post(
    '/groupware/payroll/runs/:id/payslips',
    withPayroll(
      async (req, res, ctx) => {
        const run = await loadRun(req, res, ctx, { draftOnly: true });
        if (!run) return;
        const ids = new Set(Array.isArray(req.body?.userIds) ? req.body.userIds.filter(isUuid) : []);
        if (!ids.size) return fail(res, { error: '더할 사람을 고르세요.' });
        const members = (await listGroupwareMembers({ scope: ctx.scope, teamId: ctx.teamId })).filter((m) => ids.has(m.id) && !m.deletedAt);
        if (!members.length) return fail(res, { error: '이 범위의 구성원이 아닙니다.', status: 404 });
        const existing = await listPayslipsOfRun(run.id);
        if (existing.length + members.length > PAYROLL_SLIPS_MAX) return fail(res, { error: `한 대장에 ${PAYROLL_SLIPS_MAX}명까지 넣을 수 있습니다.` });
        const who = await identities(ctx);
        const template = ctx.payrollSettings?.itemTemplate ?? null;
        const rows = await insertPayslips(
          run.id,
          ctx.scopeKey,
          members.map((m) => ({ ...who(m), data: sealData(blankPayslipData(template)) })),
        );
        emitToStaff(ctx, [run.createdBy]);
        res.status(201).json(rows.map((s) => slipDto(s, { manager: true })));
      },
      { manage: true },
    ),
  );

  /** 명세서 빼기 — 작성 중인 대장에서만. */
  router.delete(
    '/groupware/payroll/payslips/:id',
    withPayroll(
      async (req, res, ctx) => {
        const found = isUuid(req.params.id) ? await findPayslip(req.params.id) : null;
        if (!found || found.run.scopeKey !== ctx.scopeKey) return fail(res, { error: '급여명세서를 찾을 수 없습니다.', status: 404 });
        if (found.run.status !== 'draft') return fail(res, { error: '보낸 대장의 명세서는 뺄 수 없습니다. 먼저 보내기를 취소하세요.', status: 409 });
        await deletePayslip(found.slip.id);
        emitToStaff(ctx, [found.run.createdBy]);
        res.json({ ok: true });
      },
      { manage: true },
    ),
  );

  /**
   * 명세서 고치기 `{ earnings, deductions, work?, memo?, employeeNo?, reason? }` — 작성 중이면 그대로, 보낸 뒤면 사유(reason)가 꼭 있어야 하고 이전
   * 내용을 정정 기록에 남긴 뒤(판 번호 +1, 확인 시각을 비운다) 받는 사람에게 "정정" 알림을 보낸다.
   */
  router.put(
    '/groupware/payroll/payslips/:id',
    withPayroll(
      async (req, res, ctx) => {
        const found = isUuid(req.params.id) ? await findPayslip(req.params.id) : null;
        if (!found || found.run.scopeKey !== ctx.scopeKey) return fail(res, { error: '급여명세서를 찾을 수 없습니다.', status: 404 });
        const parsed = parsePayslipData(req.body);
        if (parsed.error) return fail(res, parsed);
        const patch = { data: sealData(parsed.data) };
        if (req.body?.employeeNo !== undefined) {
          const no = typeof req.body.employeeNo === 'string' ? req.body.employeeNo.trim().slice(0, 30) : '';
          patch.employeeNo = no || null;
        }
        const published = found.run.status === 'published';
        if (published) {
          const reason = parseCorrectionReason(req.body?.reason);
          if (reason.error) return fail(res, reason);
          const before = readData(found.slip.data);
          const history = [
            ...readHistory(found.slip.history),
            { revision: found.slip.revision, data: before, correctedAt: Date.now(), correctedByName: actorName(ctx), reason: reason.reason },
          ];
          Object.assign(patch, {
            history: encryptField(JSON.stringify(history)),
            revision: found.slip.revision + 1,
            correctedAt: new Date(),
            viewedAt: null,
          });
          audit(ctx, AUDIT.payrollCorrect, {
            targetId: found.slip.id,
            targetLabel: `${found.run.title} · ${found.slip.userName}`,
            detail: `급여명세서 정정 — ${found.run.title} ${found.slip.userName}: ${reason.reason}`,
          });
        }
        const row = await updatePayslip(found.slip.id, patch);
        if (published) notifyOwners(ctx, found.run, [row.userId], { corrected: true });
        emitToStaff(ctx, [found.run.createdBy]);
        res.json(slipDto(row, { manager: true }));
      },
      { manage: true },
    ),
  );

  /** 작성 중인 대장의 명세서들에 [transform](data, slip)을 적용해 저장한다. 바꾼 수. */
  async function transformRun(run, transform) {
    const slips = await listPayslipsOfRun(run.id);
    const updates = [];
    for (const slip of slips) {
      const next = await transform(readData(slip.data), slip);
      if (next) updates.push({ id: slip.id, patch: { data: sealData(next) } });
    }
    await updatePayslipsBulk(updates);
    return updates.length;
  }

  /**
   * 근태에서 채우기 — 대장의 달(payMonth)의 근태 요약(근무일·실근로·연장·야간·휴일 시간)을 명세서마다 넣고, 통상시급을 정한 사람은
   * 연장·야간·휴일근로수당 금액과 계산 방법(통상시급 × 시간 × 배율)을 넣는다(groupware.js monthSummaries — 가산 수당 참고 계산과 같다).
   */
  router.post(
    '/groupware/payroll/runs/:id/fill-attendance',
    withPayroll(
      async (req, res, ctx) => {
        const run = await loadRun(req, res, ctx, { draftOnly: true });
        if (!run) return;
        const rows = await monthSummaries(ctx, run.payMonth);
        const byUser = new Map(rows.map((r) => [r.userId, r]));
        const rates = payRatesOf(ctx.options?.payRates);
        let withPay = 0;
        const changed = await transformRun(run, (data, slip) => {
          const row = byUser.get(slip.userId);
          if (!row) return null;
          if (row.allowance) withPay += 1;
          return applyAttendance(data, { summary: row.summary, allowance: row.allowance, rates });
        });
        emitToStaff(ctx, [run.createdBy]);
        res.json({ updated: changed, withAllowance: withPay });
      },
      { manage: true },
    ),
  );

  /**
   * 공제 계산 `{ userIds?, incomeTax? }` — 명세서마다 과세 대상 급여로 국민연금·건강·장기요양·고용보험(요율 어림)을, incomeTax가 false가 아니면
   * 소득세(간이세액표 — 급여 설정의 가족 수·8~20세 자녀·비율, 대장의 지급일)와 지방소득세를 채운다.
   */
  router.post(
    '/groupware/payroll/runs/:id/calc-deductions',
    withPayroll(
      async (req, res, ctx) => {
        const run = await loadRun(req, res, ctx, { draftOnly: true });
        if (!run) return;
        const only = Array.isArray(req.body?.userIds) ? new Set(req.body.userIds) : null;
        const insurance = ctx.payrollSettings?.insurance ?? null;
        const profiles = ctx.payrollSettings?.taxProfiles ?? {};
        const withTax = req.body?.incomeTax !== false;
        const changed = await transformRun(run, (data, slip) => {
          if (only && !only.has(slip.userId)) return null;
          if (payslipTotals(data).taxable <= 0) return null;
          const next = applyInsurance(data, insurance, withTax ? { withholding: { profile: profiles[slip.userId] ?? null, payDate: run.payDate } } : {});
          return parseItems(next.deductions, { label: '공제' }).error ? null : next;
        });
        emitToStaff(ctx, [run.createdBy]);
        res.json({ updated: changed });
      },
      { manage: true },
    ),
  );

  /** 급여대장 엑셀 — 사람마다 한 줄(사번·이름·부서·근무 시간·항목·합계·확인). 같은 모양으로 고쳐서 다시 가져올 수 있다. */
  router.get(
    '/groupware/payroll/runs/:id/export',
    withPayroll(
      async (req, res, ctx) => {
        const run = await loadRun(req, res, ctx);
        if (!run) return;
        const [slips, members] = await Promise.all([listPayslipsOfRun(run.id), listGroupwareMembers({ scope: ctx.scope, teamId: ctx.teamId })]);
        const usernameOf = new Map(members.map((m) => [m.id, m.username]));
        const rows = slips.map((s) => ({
          username: usernameOf.get(s.userId) ?? '',
          employeeNo: s.employeeNo,
          name: s.userName,
          department: s.department,
          position: s.position,
          data: readData(s.data),
          viewedAt: s.viewedAt,
        }));
        const columns = payrollSheetColumns(rows);
        const wb = new ExcelJS.Workbook();
        const ws = wb.addWorksheet('급여대장');
        ws.addRow(columns.map((c) => c.header)).font = { bold: true };
        for (const r of rows) ws.addRow(columns.map((c) => c.value(r)));
        columns.forEach((c, i) => {
          const col = ws.getColumn(i + 1);
          col.width = Math.min(40, Math.max(10, [...c.header].length * 1.8));
          if (c.amount) col.numFmt = '#,##0';
        });
        ws.views = [{ state: 'frozen', xSplit: 3, ySplit: 1 }];
        const info = wb.addWorksheet('안내');
        for (const line of [
          [`${run.title} — 지급일 ${run.payDate}`],
          ['같은 모양으로 고쳐서 "엑셀 가져오기"로 다시 올릴 수 있습니다(작성 중인 대장만).'],
          ["'[공제] 이름' 열은 공제 항목, '(비과세)'가 붙은 열은 비과세 지급 항목, '[계산] 이름' 열은 그 항목의 계산 방법입니다."],
          ['빈 칸은 그 항목을 바꾸지 않습니다. 사람은 아이디 → 사번 → 이름(같은 이름이 없을 때) 순서로 찾습니다.'],
        ])
          info.addRow(line);
        info.getColumn(1).width = 100;
        audit(ctx, AUDIT.payrollExport, { targetId: run.id, targetLabel: run.title, detail: `급여대장 내려받기 — ${run.title}` });
        const buffer = await wb.xlsx.writeBuffer();
        const name = `급여대장-${run.payMonth}-${run.title}.xlsx`;
        res
          .set({
            'content-type': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
            'content-disposition': `attachment; filename="payroll.xlsx"; filename*=UTF-8''${encodeURIComponent(name)}`,
            'cache-control': 'no-store',
          })
          .send(Buffer.from(buffer));
      },
      { manage: true },
    ),
  );

  /**
   * 급여대장 엑셀 가져오기 `?dryRun=1`(본문은 xlsx·CSV 그대로, 5MB까지) — 작성 중인 대장만. 줄마다 사람을 찾아(아이디 → 사번 → 이름) 파일에 값이 있는
   * 항목만 덧쓰고(payrollRules.js mergePayslipData), 대장에 없던 구성원은 더한다. 미리 보기면 바꿀 수·못 찾은 줄·오류만, 오류가 있으면 바꾸지 않는다.
   */
  router.post(
    '/groupware/payroll/runs/:id/import',
    express.raw({ type: () => true, limit: '5mb' }),
    withPayroll(
      async (req, res, ctx) => {
        const run = await loadRun(req, res, ctx, { draftOnly: true });
        if (!run) return;
        const sheet = await readSheetRows(req.body, { sheetName: '급여대장' });
        if (sheet.error) return fail(res, sheet);
        const [slips, members] = await Promise.all([listPayslipsOfRun(run.id), listGroupwareMembers({ scope: ctx.scope, teamId: ctx.teamId })]);
        const employeeNos = ctx.payrollSettings?.employeeNos ?? {};
        const slipOf = new Map(slips.map((s) => [s.userId, s]));
        const people = members
          .filter((m) => !m.deletedAt)
          .map((m) => ({ id: m.id, username: m.username, name: slipOf.get(m.id)?.userName ?? m.name, employeeNo: slipOf.get(m.id)?.employeeNo ?? employeeNos[m.id] ?? null }));
        const { plan, unmatched, errors, columns } = planPayrollImport(sheet.rows, people);
        // 덧쓴 결과가 항목 상한을 넘지 않는지까지 본다.
        const template = ctx.payrollSettings?.itemTemplate ?? null;
        const updates = [];
        const additions = [];
        for (const p of plan) {
          const slip = slipOf.get(p.userId);
          const merged = mergePayslipData(slip ? readData(slip.data) : blankPayslipData(template), p.data);
          if (merged.earnings.length > PAYROLL_ITEMS_MAX || merged.deductions.length > PAYROLL_ITEMS_MAX) {
            errors.push({ row: 0, message: `${people.find((x) => x.id === p.userId)?.name ?? ''}: 항목이 ${PAYROLL_ITEMS_MAX}개를 넘습니다.` });
            continue;
          }
          if (slip) updates.push({ id: slip.id, patch: { data: sealData(merged), ...(p.employeeNo && { employeeNo: p.employeeNo }) } });
          else additions.push({ userId: p.userId, data: merged, employeeNo: p.employeeNo });
        }
        const summary = { updated: updates.length, added: additions.length, unmatched, columns };
        if (req.query.dryRun === '1' || errors.length > 0) {
          return res.status(errors.length > 0 && req.query.dryRun !== '1' ? 400 : 200).json({ ...summary, errors: errors.slice(0, 200), applied: false });
        }
        if (slips.length + additions.length > PAYROLL_SLIPS_MAX) return fail(res, { error: `한 대장에 ${PAYROLL_SLIPS_MAX}명까지 넣을 수 있습니다.` });
        await updatePayslipsBulk(updates);
        if (additions.length) {
          const who = await identities(ctx);
          const memberOf = new Map(members.map((m) => [m.id, m]));
          await insertPayslips(
            run.id,
            ctx.scopeKey,
            additions.map((a) => ({ ...who(memberOf.get(a.userId)), ...(a.employeeNo && { employeeNo: a.employeeNo }), data: sealData(a.data) })),
          );
        }
        emitToStaff(ctx, [run.createdBy]);
        res.json({ ...summary, errors: [], applied: true });
      },
      { manage: true },
    ),
  );

  return router;
}
