import { Router } from 'express';
import {
  claimSurveyReminder,
  countResponses,
  deleteSurvey,
  findResponse,
  findSurvey,
  insertSurvey,
  listResponses,
  listScopeSurveys,
  respondedSurveyIds,
  updateSurvey,
  upsertResponse,
} from './db/queries/surveys.js';
import { isUuid } from './favoritesRules.js';
import { approverCandidates, fail, groupwareContext } from './groupware.js';
import { notifyGroupwarePush } from './push.js';
import {
  SURVEY_REMIND_INTERVAL_MS,
  canViewSurveyResults,
  isSurveyClosed,
  isSurveyTarget,
  parseAnswers,
  parseSurveyInput,
  summarizeSurvey,
  surveyTargetIds,
} from './surveyRules.js';

const ms = (d) => (d ? new Date(d).getTime() : null);

/**
 * 그룹웨어 설문 — 여러 문항을 범위 사람 모두나 고른 사람에게 묻고 결과를 모아 본다(규칙은 surveyRules.js). 만들기·응답은 정회원 이상
 * (준회원은 그룹웨어 사람 목록 approverCandidates에 없다). 만든 사람과 그룹웨어 관리자는 결과·안 한 사람을 보고 마감·독촉·삭제한다.
 * 새 설문·독촉은 대상에게 그룹웨어 푸시(문서 id 없음 — 눌러서 그룹웨어 화면)와 groupware:changed `{ surveys: true }`.
 */
export function createGroupwareSurveysRouter(io) {
  const router = Router();

  const withContext = (handler) => async (req, res) => {
    const ctx = await groupwareContext(req.user.sub, req.query.teamId ?? req.body?.teamId);
    if (ctx.error) return fail(res, ctx);
    const people = await approverCandidates(ctx);
    if (!people.has(ctx.user.id)) return fail(res, { error: '정회원 이상만 설문을 쓸 수 있습니다.', status: 403 });
    return handler(req, res, { ...ctx, people, eligibleIds: new Set(people.keys()) });
  };

  /** 이 범위의 설문을 볼 수 있는지 — 만든 사람·관리자·대상. 볼 수 없으면 응답하고 null. */
  async function loadSurvey(req, res, ctx) {
    const survey = isUuid(req.params.id) ? await findSurvey(req.params.id) : null;
    if (!survey || survey.scopeKey !== ctx.scopeKey) {
      fail(res, { error: '설문을 찾을 수 없습니다.', status: 404 });
      return null;
    }
    const isOwner = survey.createdBy === ctx.user.id;
    const isTarget = isSurveyTarget(survey, ctx.user.id, ctx.eligibleIds);
    if (!isOwner && !ctx.isManager && !isTarget) {
      fail(res, { error: '이 설문의 대상이 아닙니다.', status: 403 });
      return null;
    }
    return { survey, isOwner, isTarget, canManage: isOwner || ctx.isManager };
  }

  function emitChanged(userIds) {
    for (const id of new Set(userIds)) io.to(`user:${id}`).emit('groupware:changed', { surveys: true });
  }

  function surveyDto(s, { responseCount = 0, targetCount = 0, responded = false, now = new Date() } = {}) {
    return {
      id: s.id,
      title: s.title,
      description: s.description ?? null,
      creatorId: s.createdBy ?? null,
      creatorName: s.creatorName,
      anonymous: s.anonymous,
      resultVisibility: s.resultVisibility,
      audience: s.audience,
      targetIds: s.audience === 'users' ? (s.targetIds ?? []) : [],
      questionCount: (s.questions ?? []).length,
      closesAt: ms(s.closesAt),
      closed: isSurveyClosed(s, now),
      createdAt: ms(s.createdAt),
      responseCount,
      targetCount,
      responded,
    };
  }

  /** 내가 볼 수 있는 설문 — 응답할 것(열려 있고 안 한 것)이 앞, 그다음 최근 것. */
  router.get(
    '/groupware/surveys',
    withContext(async (req, res, ctx) => {
      const all = await listScopeSurveys(ctx.scopeKey);
      const visible = all.filter(
        (s) => s.createdBy === ctx.user.id || ctx.isManager || isSurveyTarget(s, ctx.user.id, ctx.eligibleIds),
      );
      const ids = visible.map((s) => s.id);
      const [counts, mine] = await Promise.all([countResponses(ids), respondedSurveyIds(ctx.user.id, ids)]);
      const now = new Date();
      const items = visible.map((s) => {
        const dto = surveyDto(s, {
          responseCount: counts[s.id] ?? 0,
          targetCount: surveyTargetIds(s, ctx.eligibleIds).length,
          responded: mine.has(s.id),
          now,
        });
        // 내가 아직 응답할 설문 — 대상이고 열려 있고 안 했다.
        return { ...dto, pending: !dto.closed && !dto.responded && isSurveyTarget(s, ctx.user.id, ctx.eligibleIds) };
      });
      items.sort((a, b) => Number(b.pending) - Number(a.pending) || b.createdAt - a.createdAt);
      res.json({ items, pendingCount: items.filter((s) => s.pending).length });
    }),
  );

  router.post(
    '/groupware/surveys',
    withContext(async (req, res, ctx) => {
      const parsed = parseSurveyInput(req.body, { eligibleIds: ctx.eligibleIds });
      if (parsed.error) return fail(res, parsed);
      const survey = await insertSurvey({
        ...parsed.values,
        scopeKey: ctx.scopeKey,
        teamId: ctx.teamId,
        createdBy: ctx.user.id,
        creatorName: ctx.user.name ?? ctx.user.username,
      });
      const targets = surveyTargetIds(survey, ctx.eligibleIds).filter((id) => id !== ctx.user.id);
      emitChanged([ctx.user.id, ...targets]);
      const creator = ctx.user.name ?? ctx.user.username;
      for (const userId of targets) {
        notifyGroupwarePush({
          userId,
          title: '설문',
          body: `${creator}님이 설문을 보냈습니다: ${survey.title}`,
          documentId: '',
          teamId: ctx.teamId,
        }).catch((e) => console.error('[survey] 푸시 실패:', e?.message ?? e));
      }
      res.status(201).json(surveyDto(survey, { targetCount: surveyTargetIds(survey, ctx.eligibleIds).length }));
    }),
  );

  /** 설문 하나 — 문항과 내 응답, 결과를 볼 수 있는지. */
  router.get(
    '/groupware/surveys/:id',
    withContext(async (req, res, ctx) => {
      const found = await loadSurvey(req, res, ctx);
      if (!found) return;
      const { survey, isTarget, canManage } = found;
      const [mine, counts] = await Promise.all([findResponse(survey.id, ctx.user.id), countResponses([survey.id])]);
      res.json({
        ...surveyDto(survey, {
          responseCount: counts[survey.id] ?? 0,
          targetCount: surveyTargetIds(survey, ctx.eligibleIds).length,
          responded: !!mine,
        }),
        questions: survey.questions,
        myAnswers: mine?.answers ?? null,
        canRespond: isTarget && !isSurveyClosed(survey),
        canManage,
        canViewResults: canViewSurveyResults({
          survey,
          userId: ctx.user.id,
          isManager: ctx.isManager,
          isTarget,
          responded: !!mine,
        }),
      });
    }),
  );

  /** 응답하기·고치기 `{ answers }` — 대상이고 열려 있을 때. */
  router.put(
    '/groupware/surveys/:id/response',
    withContext(async (req, res, ctx) => {
      const found = await loadSurvey(req, res, ctx);
      if (!found) return;
      const { survey, isTarget } = found;
      if (!isTarget) return fail(res, { error: '이 설문의 대상이 아닙니다.', status: 403 });
      if (isSurveyClosed(survey)) return fail(res, { error: '마감된 설문입니다.', status: 409 });
      const parsed = parseAnswers(survey, req.body?.answers);
      if (parsed.error) return fail(res, parsed);
      const first = await upsertResponse(survey.id, ctx.user.id, parsed.answers);
      // 만든 사람의 화면(응답 수)과 내 다른 기기가 다시 받게.
      emitChanged([ctx.user.id, ...(survey.createdBy ? [survey.createdBy] : [])]);
      res.json({ ok: true, first });
    }),
  );

  /** 결과 — 문항별 집계, 응답한 사람(익명이 아니면)과 안 한 사람(관리할 수 있는 사람에게만). */
  router.get(
    '/groupware/surveys/:id/results',
    withContext(async (req, res, ctx) => {
      const found = await loadSurvey(req, res, ctx);
      if (!found) return;
      const { survey, isTarget, canManage } = found;
      const responses = await listResponses(survey.id);
      const responded = responses.some((r) => r.userId === ctx.user.id);
      if (!canViewSurveyResults({ survey, userId: ctx.user.id, isManager: ctx.isManager, isTarget, responded })) {
        return fail(res, { error: '이 설문의 결과는 볼 수 없습니다.', status: 403 });
      }
      const names = new Map(responses.map((r) => [r.userId, r.name ?? r.username ?? '']));
      const respondedIds = new Set(responses.map((r) => r.userId));
      const targets = surveyTargetIds(survey, ctx.eligibleIds);
      res.json({
        responseCount: responses.length,
        targetCount: targets.length,
        questions: summarizeSurvey(survey, responses, { names }),
        // 익명 설문은 누가 응답했는지도 보이지 않는다(안 한 사람 목록은 독촉하려고 관리하는 사람에게만).
        respondents: survey.anonymous
          ? null
          : responses.map((r) => ({ userId: r.userId, name: names.get(r.userId), submittedAt: ms(r.submittedAt) })),
        nonRespondents: canManage
          ? targets
              .filter((id) => !respondedIds.has(id))
              .map((id) => ({ userId: id, name: ctx.people.get(id)?.name ?? '' }))
              .sort((a, b) => a.name.localeCompare(b.name, 'ko'))
          : null,
      });
    }),
  );

  /** 마감 — 만든 사람·관리자. */
  router.post(
    '/groupware/surveys/:id/close',
    withContext(async (req, res, ctx) => {
      const found = await loadSurvey(req, res, ctx);
      if (!found) return;
      if (!found.canManage) return fail(res, { error: '만든 사람만 마감할 수 있습니다.', status: 403 });
      const updated = found.survey.closedAt ? found.survey : await updateSurvey(found.survey.id, { closedAt: new Date() });
      emitChanged([ctx.user.id, ...surveyTargetIds(updated, ctx.eligibleIds)]);
      res.json(surveyDto(updated));
    }),
  );

  /** 안 한 사람에게 독촉 — 만든 사람·관리자, 열려 있을 때, 1시간에 한 번. → `{ notified }`. */
  router.post(
    '/groupware/surveys/:id/remind',
    withContext(async (req, res, ctx) => {
      const found = await loadSurvey(req, res, ctx);
      if (!found) return;
      const { survey } = found;
      if (!found.canManage) return fail(res, { error: '만든 사람만 독촉할 수 있습니다.', status: 403 });
      if (isSurveyClosed(survey)) return fail(res, { error: '마감된 설문입니다.', status: 409 });
      if (!(await claimSurveyReminder(survey.id, new Date(Date.now() - SURVEY_REMIND_INTERVAL_MS)))) {
        return fail(res, { error: '독촉은 1시간에 한 번 보낼 수 있습니다.', status: 429 });
      }
      const responded = new Set((await listResponses(survey.id)).map((r) => r.userId));
      const targets = surveyTargetIds(survey, ctx.eligibleIds).filter((id) => !responded.has(id) && id !== ctx.user.id);
      for (const userId of targets) {
        notifyGroupwarePush({
          userId,
          title: '설문 응답 요청',
          body: `아직 응답하지 않은 설문이 있습니다: ${survey.title}`,
          documentId: '',
          teamId: ctx.teamId,
        }).catch((e) => console.error('[survey] 푸시 실패:', e?.message ?? e));
      }
      res.json({ notified: targets.length });
    }),
  );

  router.delete(
    '/groupware/surveys/:id',
    withContext(async (req, res, ctx) => {
      const found = await loadSurvey(req, res, ctx);
      if (!found) return;
      if (!found.canManage) return fail(res, { error: '만든 사람만 지울 수 있습니다.', status: 403 });
      await deleteSurvey(found.survey.id);
      emitChanged([ctx.user.id, ...surveyTargetIds(found.survey, ctx.eligibleIds)]);
      res.json({ ok: true });
    }),
  );

  return router;
}
