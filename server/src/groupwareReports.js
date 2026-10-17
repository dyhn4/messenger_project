import { Router } from 'express';
import { loadOrgTree } from './orgTree.js';
import { managerChain, orgScopeKey } from './orgTreeRules.js';
import {
  countReportComments,
  deleteReport,
  findReport,
  findReportFor,
  insertReportComment,
  listMyReports,
  listPeriodReports,
  listReportComments,
  listReportReads,
  markReportRead,
  upsertReport,
} from './db/queries/surveys.js';
import { isUuid } from './favoritesRules.js';
import { approverCandidates, fail, groupwareContext } from './groupware.js';
import { notifyGroupwarePush } from './push.js';
import {
  REPORT_COMMENT_MAX,
  REPORT_KIND_LABEL,
  REPORT_REVIEWER_DEPTH,
  adjacentPeriod,
  canViewReport,
  currentPeriodStart,
  parseReportBody,
  parseReportPeriod,
  periodEndOf,
  reportRoster,
} from './workReportRules.js';

const ms = (d) => (d ? new Date(d).getTime() : null);

/**
 * 그룹웨어 업무일지 — 일일·주간 업무보고를 쓰고(한 일·할 일·이슈), 조직도 상위자(가까운 두 명)와 그룹웨어 관리자가 팀 현황에서 읽고
 * 댓글을 단다(규칙은 workReportRules.js). 처음 내면 상위자에게, 댓글이 달리면 쓴 사람에게 그룹웨어 푸시와 groupware:changed
 * `{ reports: true }`. 읽은 검토자는 쓴 사람에게 "확인함"으로 보인다.
 */
export function createGroupwareReportsRouter(io) {
  const router = Router();

  const withContext = (handler) => async (req, res) => {
    const ctx = await groupwareContext(req.user.sub, req.query.teamId ?? req.body?.teamId);
    if (ctx.error) return fail(res, ctx);
    const people = await approverCandidates(ctx);
    if (!people.has(ctx.user.id)) return fail(res, { error: '정회원 이상만 업무일지를 쓸 수 있습니다.', status: 403 });
    // 조직도는 부서·직책 설정을 따른다 — 그룹웨어가 회사 전체여도 팀 단위 조직도면 지금 고른 팀의 조직도(결재선 추천과 같다).
    const teamInput = req.query.teamId ?? req.body?.teamId;
    const orgKey = orgScopeKey(ctx.settings, ctx.teamId ?? (isUuid(teamInput) ? teamInput : null));
    const tree = orgKey ? await loadOrgTree(orgKey).catch(() => null) : null;
    const reviewersOf = (userId) =>
      tree
        ? managerChain(userId, {
            members: tree.members,
            departments: tree.departments,
            isEligible: (id) => people.has(id),
            max: REPORT_REVIEWER_DEPTH,
          })
        : [];
    return handler(req, res, { ...ctx, people, reviewersOf });
  };

  const nameOf = (ctx, id) => ctx.people.get(id)?.name ?? '';

  function emitChanged(userIds) {
    for (const id of new Set(userIds)) io.to(`user:${id}`).emit('groupware:changed', { reports: true });
  }

  function push(ctx, userIds, title, body) {
    for (const userId of new Set(userIds)) {
      if (userId === ctx.user.id) continue;
      notifyGroupwarePush({ userId, title, body, documentId: '', teamId: ctx.teamId }).catch((e) =>
        console.error('[work-report] 푸시 실패:', e?.message ?? e),
      );
    }
  }

  function reportDto(r, { commentCount = 0, reads = [] } = {}) {
    return {
      id: r.id,
      userId: r.userId,
      userName: r.userName,
      kind: r.kind,
      periodStart: r.periodStart,
      periodEnd: periodEndOf(r.kind, r.periodStart),
      done: r.done ?? null,
      plan: r.plan ?? null,
      issues: r.issues ?? null,
      createdAt: ms(r.createdAt),
      updatedAt: ms(r.updatedAt),
      commentCount,
      // 검토자가 읽은 기록(쓴 사람에게 "확인함").
      reads: reads.map((x) => ({ userId: x.userId, name: x.name ?? '', readAt: ms(x.readAt) })),
    };
  }

  async function decorate(reports) {
    const ids = reports.map((r) => r.id);
    const [comments, reads] = await Promise.all([countReportComments(ids), listReportReads(ids)]);
    return reports.map((r) =>
      reportDto(r, { commentCount: comments[r.id] ?? 0, reads: reads.filter((x) => x.reportId === r.id) }),
    );
  }

  /** 이 보고를 볼 수 있는지 — 아니면 응답하고 null. */
  async function loadReport(req, res, ctx) {
    const report = isUuid(req.params.id) ? await findReport(req.params.id) : null;
    if (!report || report.scopeKey !== ctx.scopeKey) {
      fail(res, { error: '업무일지를 찾을 수 없습니다.', status: 404 });
      return null;
    }
    const reviewerIds = ctx.reviewersOf(report.userId);
    if (!canViewReport({ writerId: report.userId, viewerId: ctx.user.id, reviewerIds, isManager: ctx.isManager })) {
      fail(res, { error: '이 업무일지를 볼 수 없습니다.', status: 403 });
      return null;
    }
    return { report, reviewerIds };
  }

  /** 내 보고 — 고른 기간(`?kind&periodStart`, 기본 오늘·이번 주)의 내 보고, 받는 사람(상위자), 최근 보고. */
  router.get(
    '/groupware/work-reports',
    withContext(async (req, res, ctx) => {
      const period = parseReportPeriod(req.query.kind ?? 'daily', req.query.periodStart ?? undefined);
      if (period.error) return fail(res, period);
      const { kind, periodStart } = period;
      const [mine, recent] = await Promise.all([
        findReportFor({ scopeKey: ctx.scopeKey, userId: ctx.user.id, kind, periodStart }),
        listMyReports({ scopeKey: ctx.scopeKey, userId: ctx.user.id, kind, limit: 10 }),
      ]);
      const [mineDto] = mine ? await decorate([mine]) : [null];
      res.json({
        kind,
        periodStart,
        periodEnd: periodEndOf(kind, periodStart),
        currentPeriodStart: currentPeriodStart(kind),
        previousPeriodStart: adjacentPeriod(kind, periodStart, -1),
        report: mineDto,
        reviewers: ctx.reviewersOf(ctx.user.id).map((id) => ({ userId: id, name: nameOf(ctx, id) })),
        recent: (await decorate(recent)).map(({ id, periodStart: p, periodEnd, commentCount, reads }) => ({
          id,
          periodStart: p,
          periodEnd,
          commentCount,
          readCount: reads.length,
        })),
      });
    }),
  );

  /** 내 일일 보고(`?from&to`) — 주간 보고를 쓸 때 그 주의 일일 보고를 불러오는 용도. */
  router.get(
    '/groupware/work-reports/mine',
    withContext(async (req, res, ctx) => {
      const from = typeof req.query.from === 'string' ? req.query.from : null;
      const to = typeof req.query.to === 'string' ? req.query.to : null;
      const kind = req.query.kind === 'weekly' ? 'weekly' : 'daily';
      const rows = await listMyReports({ scopeKey: ctx.scopeKey, userId: ctx.user.id, kind, from, to, limit: 31 });
      res.json((await decorate(rows)).sort((a, b) => a.periodStart.localeCompare(b.periodStart)));
    }),
  );

  /** 보고 쓰기·고치기 `{ kind, periodStart, done, plan, issues }` — 처음 내면 상위자에게 알린다. */
  router.put(
    '/groupware/work-reports',
    withContext(async (req, res, ctx) => {
      const period = parseReportPeriod(req.body?.kind, req.body?.periodStart);
      if (period.error) return fail(res, period);
      const body = parseReportBody(req.body);
      if (body.error) return fail(res, body);
      const { row, created } = await upsertReport(
        { scopeKey: ctx.scopeKey, userId: ctx.user.id, kind: period.kind, periodStart: period.periodStart },
        { ...body.values, teamId: ctx.teamId, userName: ctx.user.name ?? ctx.user.username },
      );
      const reviewers = ctx.reviewersOf(ctx.user.id);
      emitChanged([ctx.user.id, ...reviewers]);
      if (created) {
        const label = REPORT_KIND_LABEL[period.kind];
        push(ctx, reviewers, label, `${ctx.user.name ?? ctx.user.username}님이 ${label}를 올렸습니다 (${period.periodStart}).`);
      }
      const [dto] = await decorate([row]);
      res.status(created ? 201 : 200).json(dto);
    }),
  );

  /**
   * 팀 현황 — 내가 검토하는 사람들(조직도에서 내가 상위자인 사람, 관리자는 범위 모두)의 이 기간 보고. 안 쓴 사람이 위로.
   * 검토할 사람이 없으면 빈 목록(canReview: false).
   */
  router.get(
    '/groupware/work-reports/team',
    withContext(async (req, res, ctx) => {
      const period = parseReportPeriod(req.query.kind ?? 'daily', req.query.periodStart ?? undefined);
      if (period.error) return fail(res, period);
      const people = [...ctx.people.values()].filter(
        (p) => p.id !== ctx.user.id && (ctx.isManager || ctx.reviewersOf(p.id).includes(ctx.user.id)),
      );
      const reports = await listPeriodReports({
        scopeKey: ctx.scopeKey,
        kind: period.kind,
        periodStart: period.periodStart,
        userIds: people.map((p) => p.id),
      });
      const dtos = await decorate(reports);
      const roster = reportRoster(people, dtos).map((r) => ({
        userId: r.userId,
        name: r.name,
        report: r.report
          ? { ...r.report, readByMe: r.report.reads.some((x) => x.userId === ctx.user.id) }
          : null,
      }));
      res.json({
        kind: period.kind,
        periodStart: period.periodStart,
        periodEnd: periodEndOf(period.kind, period.periodStart),
        currentPeriodStart: currentPeriodStart(period.kind),
        canReview: people.length > 0,
        submittedCount: roster.filter((r) => r.report).length,
        roster,
      });
    }),
  );

  /** 보고 하나 — 본문·댓글·읽은 사람. 검토자가 열면 읽음을 남기고 쓴 사람에게 알린다(화면 갱신만). */
  router.get(
    '/groupware/work-reports/:id',
    withContext(async (req, res, ctx) => {
      const found = await loadReport(req, res, ctx);
      if (!found) return;
      const { report } = found;
      if (report.userId !== ctx.user.id && (await markReportRead(report.id, ctx.user.id))) emitChanged([report.userId]);
      const [[dto], comments] = await Promise.all([decorate([report]), listReportComments(report.id)]);
      res.json({
        ...dto,
        comments: comments.map((c) => ({
          id: c.id,
          userId: c.userId ?? null,
          userName: c.userName,
          text: c.text,
          createdAt: ms(c.createdAt),
        })),
        canEdit: report.userId === ctx.user.id,
      });
    }),
  );

  /** 댓글 `{ text }` — 볼 수 있는 사람 누구나. 쓴 사람(과 다른 검토자)에게 알린다. */
  router.post(
    '/groupware/work-reports/:id/comments',
    withContext(async (req, res, ctx) => {
      const found = await loadReport(req, res, ctx);
      if (!found) return;
      const text = typeof req.body?.text === 'string' ? req.body.text.trim() : '';
      if (!text) return fail(res, { error: '댓글을 쓰세요.' });
      if ([...text].length > REPORT_COMMENT_MAX) return fail(res, { error: `댓글은 ${REPORT_COMMENT_MAX}자까지 쓸 수 있습니다.` });
      const c = await insertReportComment({
        reportId: found.report.id,
        userId: ctx.user.id,
        userName: ctx.user.name ?? ctx.user.username,
        text,
      });
      const watchers = [found.report.userId, ...found.reviewerIds];
      emitChanged(watchers);
      push(
        ctx,
        watchers,
        `${REPORT_KIND_LABEL[found.report.kind]} 댓글`,
        `${ctx.user.name ?? ctx.user.username}: ${text.slice(0, 80)}`,
      );
      res.status(201).json({ id: c.id, userId: c.userId, userName: c.userName, text: c.text, createdAt: ms(c.createdAt) });
    }),
  );

  router.delete(
    '/groupware/work-reports/:id',
    withContext(async (req, res, ctx) => {
      const found = await loadReport(req, res, ctx);
      if (!found) return;
      if (found.report.userId !== ctx.user.id) return fail(res, { error: '내가 쓴 업무일지만 지울 수 있습니다.', status: 403 });
      await deleteReport(found.report.id);
      emitChanged([ctx.user.id, ...found.reviewerIds]);
      res.json({ ok: true });
    }),
  );

  return router;
}
