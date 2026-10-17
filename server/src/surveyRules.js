import { randomBytes } from 'node:crypto';

/**
 * 그룹웨어 설문의 규칙 — 설문 만들기 입력(문항·보기·대상·마감), 응답 검사, 결과 집계를 DB 없이 시험할 수 있게 모았다
 * (groupwareSurveys.js가 쓴다, test/surveyRules.test.js). 채팅방 투표(한 문항)와 달리 여러 문항·여러 종류를 한 번에 묻는다.
 *
 * 문항 모양: { id: 'q…', kind: 'single'|'multiple'|'text'|'rating', title, required, options?: [{ id: 'o…', text }] }
 *  - single(하나 고르기)·multiple(여러 개 고르기)는 보기 2~20개, text(글)는 2000자까지, rating(별점)은 1~5.
 * 응답 모양: { [문항 id]: 보기 id | [보기 id…] | 글 | 1~5 } — 안 한 문항은 빼거나 null.
 */

export const SURVEY_TITLE_MAX = 100;
export const SURVEY_DESCRIPTION_MAX = 2000;
export const SURVEY_QUESTIONS_MAX = 30;
export const SURVEY_QUESTION_TITLE_MAX = 200;
export const SURVEY_OPTIONS_MIN = 2;
export const SURVEY_OPTIONS_MAX = 20;
export const SURVEY_OPTION_MAX = 100;
export const SURVEY_TEXT_ANSWER_MAX = 2000;
export const SURVEY_RATING_MAX = 5;
/** 대상으로 고를 수 있는 사람 수. */
export const SURVEY_TARGETS_MAX = 500;
/** 마감은 1년 안. */
export const SURVEY_CLOSE_MAX_MS = 366 * 86400000;
/** 응답 독촉은 1시간에 한 번. */
export const SURVEY_REMIND_INTERVAL_MS = 3600 * 1000;

export const SURVEY_KINDS = ['single', 'multiple', 'text', 'rating'];
export const SURVEY_KIND_LABEL = { single: '하나 고르기', multiple: '여러 개 고르기', text: '글', rating: '별점' };
/** 결과를 누가 보나 — 'creator'(만든 사람·관리자만) | 'respondents'(응답한 사람도) | 'all'(대상 모두). */
export const SURVEY_RESULT_VISIBILITY = ['creator', 'respondents', 'all'];

const ID_RE = /^[qo][a-z0-9]{6,16}$/;
const newId = (prefix) => `${prefix}${randomBytes(6).toString('hex')}`;
const clean = (v) => (typeof v === 'string' ? v.replace(/[\u0000-\u0008\u000b-\u001f\u007f]/g, '').trim() : '');
const len = (s) => [...s].length;

/**
 * 설문 만들기 입력 → `{ values }` | `{ error }`. values: { title, description, questions, anonymous, resultVisibility,
 * audience('all'|'users'), targetIds, closesAt(Date|null) }. 대상(users)은 [eligibleIds](범위의 정회원 이상)에서만.
 */
export function parseSurveyInput(body, { now = new Date(), eligibleIds = new Set() } = {}) {
  const title = clean(body?.title);
  if (!title) return { error: '설문 제목을 넣으세요.' };
  if (len(title) > SURVEY_TITLE_MAX) return { error: `제목은 ${SURVEY_TITLE_MAX}자까지 쓸 수 있습니다.` };
  const description = clean(body?.description);
  if (len(description) > SURVEY_DESCRIPTION_MAX) return { error: `설명은 ${SURVEY_DESCRIPTION_MAX}자까지 쓸 수 있습니다.` };

  const raw = body?.questions;
  if (!Array.isArray(raw) || raw.length === 0) return { error: '문항을 하나 이상 넣으세요.' };
  if (raw.length > SURVEY_QUESTIONS_MAX) return { error: `문항은 ${SURVEY_QUESTIONS_MAX}개까지 넣을 수 있습니다.` };
  const questions = [];
  const seenIds = new Set();
  for (const [index, q] of raw.entries()) {
    const no = index + 1;
    if (!SURVEY_KINDS.includes(q?.kind)) return { error: `${no}번 문항의 종류를 고르세요.` };
    const qTitle = clean(q.title);
    if (!qTitle) return { error: `${no}번 문항의 질문을 넣으세요.` };
    if (len(qTitle) > SURVEY_QUESTION_TITLE_MAX) return { error: `${no}번 문항은 ${SURVEY_QUESTION_TITLE_MAX}자까지 쓸 수 있습니다.` };
    const id = typeof q.id === 'string' && ID_RE.test(q.id) && q.id.startsWith('q') && !seenIds.has(q.id) ? q.id : newId('q');
    seenIds.add(id);
    const question = { id, kind: q.kind, title: qTitle, required: q.required !== false };
    if (q.kind === 'single' || q.kind === 'multiple') {
      const opts = Array.isArray(q.options) ? q.options : [];
      const options = [];
      const texts = new Set();
      for (const o of opts) {
        const text = clean(typeof o === 'string' ? o : o?.text);
        if (!text) continue;
        if (len(text) > SURVEY_OPTION_MAX) return { error: `${no}번 문항의 보기는 ${SURVEY_OPTION_MAX}자까지 쓸 수 있습니다.` };
        if (texts.has(text)) return { error: `${no}번 문항에 같은 보기가 있습니다: '${text}'` };
        texts.add(text);
        const oid = typeof o?.id === 'string' && ID_RE.test(o.id) && o.id.startsWith('o') && !seenIds.has(o.id) ? o.id : newId('o');
        seenIds.add(oid);
        options.push({ id: oid, text });
      }
      if (options.length < SURVEY_OPTIONS_MIN) return { error: `${no}번 문항에 보기를 ${SURVEY_OPTIONS_MIN}개 이상 넣으세요.` };
      if (options.length > SURVEY_OPTIONS_MAX) return { error: `${no}번 문항의 보기는 ${SURVEY_OPTIONS_MAX}개까지 넣을 수 있습니다.` };
      question.options = options;
    }
    questions.push(question);
  }

  const audience = body?.audience === 'users' ? 'users' : 'all';
  let targetIds = [];
  if (audience === 'users') {
    const ids = Array.isArray(body?.targetIds) ? [...new Set(body.targetIds.filter((x) => typeof x === 'string'))] : [];
    if (ids.length === 0) return { error: '설문을 받을 사람을 고르세요.' };
    if (ids.length > SURVEY_TARGETS_MAX) return { error: `대상은 ${SURVEY_TARGETS_MAX}명까지 고를 수 있습니다.` };
    if (ids.some((x) => !eligibleIds.has(x))) return { error: '설문을 받을 수 없는 사람이 있습니다.' };
    targetIds = ids;
  }

  let closesAt = null;
  if (body?.closesAt != null) {
    const ms = typeof body.closesAt === 'number' ? body.closesAt : NaN;
    if (!Number.isFinite(ms)) return { error: '마감 시각이 올바르지 않습니다.' };
    if (ms <= now.getTime()) return { error: '마감은 지금 이후로 정하세요.' };
    if (ms - now.getTime() > SURVEY_CLOSE_MAX_MS) return { error: '마감은 1년 안으로 정하세요.' };
    closesAt = new Date(ms);
  }
  const resultVisibility = SURVEY_RESULT_VISIBILITY.includes(body?.resultVisibility) ? body.resultVisibility : 'creator';
  return {
    values: {
      title,
      description: description || null,
      questions,
      anonymous: body?.anonymous === true,
      resultVisibility,
      audience,
      targetIds,
      closesAt,
    },
  };
}

/** 설문이 닫혔는지(마감했거나 마감 시각이 지남). */
export function isSurveyClosed(survey, now = new Date()) {
  if (survey.closedAt) return true;
  return !!survey.closesAt && new Date(survey.closesAt).getTime() <= now.getTime();
}

/** [userId]가 이 설문의 대상인지 — 'all'이면 범위의 정회원 이상 모두([eligibleIds]). */
export function isSurveyTarget(survey, userId, eligibleIds) {
  if (survey.audience === 'users') return (survey.targetIds ?? []).includes(userId);
  return eligibleIds.has(userId);
}

/** 대상 사람 id 목록. */
export function surveyTargetIds(survey, eligibleIds) {
  if (survey.audience === 'users') return (survey.targetIds ?? []).filter((id) => eligibleIds.has(id));
  return [...eligibleIds];
}

/**
 * 응답 검사 → `{ answers }`(정리한 값 — 모르는 문항·빈 값은 뺀다) | `{ error }`. 필수 문항을 비우면 막는다.
 */
export function parseAnswers(survey, input) {
  if (input == null || typeof input !== 'object' || Array.isArray(input)) return { error: '응답이 올바르지 않습니다.' };
  const answers = {};
  for (const [index, q] of (survey.questions ?? []).entries()) {
    const no = index + 1;
    const v = input[q.id];
    const empty = v == null || v === '' || (Array.isArray(v) && v.length === 0);
    if (empty) {
      if (q.required) return { error: `${no}번 문항에 답하세요.` };
      continue;
    }
    const optionIds = new Set((q.options ?? []).map((o) => o.id));
    if (q.kind === 'single') {
      if (typeof v !== 'string' || !optionIds.has(v)) return { error: `${no}번 문항의 보기를 다시 고르세요.` };
      answers[q.id] = v;
    } else if (q.kind === 'multiple') {
      if (!Array.isArray(v) || v.some((x) => typeof x !== 'string' || !optionIds.has(x))) {
        return { error: `${no}번 문항의 보기를 다시 고르세요.` };
      }
      answers[q.id] = (q.options ?? []).map((o) => o.id).filter((id) => v.includes(id));
    } else if (q.kind === 'text') {
      const text = typeof v === 'string' ? v.trim() : '';
      if (!text) {
        if (q.required) return { error: `${no}번 문항에 답하세요.` };
        continue;
      }
      if (len(text) > SURVEY_TEXT_ANSWER_MAX) return { error: `${no}번 문항은 ${SURVEY_TEXT_ANSWER_MAX}자까지 쓸 수 있습니다.` };
      answers[q.id] = text;
    } else if (q.kind === 'rating') {
      if (!Number.isInteger(v) || v < 1 || v > SURVEY_RATING_MAX) return { error: `${no}번 문항은 1~${SURVEY_RATING_MAX}점으로 답하세요.` };
      answers[q.id] = v;
    }
  }
  return { answers };
}

/**
 * 결과를 볼 수 있는지 — 만든 사람·관리자는 늘, 'all'이면 대상 누구나, 'respondents'면 응답한 사람.
 */
export function canViewSurveyResults({ survey, userId, isManager, isTarget, responded }) {
  if (survey.createdBy === userId || isManager) return true;
  if (survey.resultVisibility === 'all') return isTarget;
  if (survey.resultVisibility === 'respondents') return responded;
  return false;
}

/**
 * 결과 집계 — 문항마다 { id, kind, title, answered, options?: [{ id, text, count }], average?, distribution?(1~5),
 * texts?: [{ name|null, text }] }. 익명 설문이면 글 응답에 이름을 붙이지 않는다. [names]는 userId → 이름.
 */
export function summarizeSurvey(survey, responses, { names = new Map() } = {}) {
  return (survey.questions ?? []).map((q) => {
    const values = responses.map((r) => ({ userId: r.userId, value: r.answers?.[q.id] })).filter((x) => x.value != null);
    const base = { id: q.id, kind: q.kind, title: q.title, answered: values.length };
    if (q.kind === 'single' || q.kind === 'multiple') {
      const counts = new Map((q.options ?? []).map((o) => [o.id, 0]));
      for (const { value } of values) {
        for (const id of Array.isArray(value) ? value : [value]) if (counts.has(id)) counts.set(id, counts.get(id) + 1);
      }
      return { ...base, options: (q.options ?? []).map((o) => ({ id: o.id, text: o.text, count: counts.get(o.id) ?? 0 })) };
    }
    if (q.kind === 'rating') {
      const distribution = [0, 0, 0, 0, 0];
      let sum = 0;
      for (const { value } of values) {
        if (Number.isInteger(value) && value >= 1 && value <= 5) {
          distribution[value - 1] += 1;
          sum += value;
        }
      }
      const n = distribution.reduce((a, b) => a + b, 0);
      return { ...base, average: n === 0 ? null : Math.round((sum / n) * 10) / 10, distribution };
    }
    const texts = values.map(({ userId, value }) => ({
      name: survey.anonymous ? null : (names.get(userId) ?? null),
      text: String(value),
    }));
    // 익명이면 응답한 순서로 누가 썼는지 짐작하지 못하게 글 순서로 늘어놓는다.
    if (survey.anonymous) texts.sort((a, b) => a.text.localeCompare(b.text, 'ko'));
    return { ...base, texts };
  });
}
