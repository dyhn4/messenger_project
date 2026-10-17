// 그룹웨어 설문·업무일지 규칙 — 설문 입력(문항·보기·대상·마감), 응답 검사, 결과 집계·공개 범위, 업무일지 기간·본문·볼 수 있는 사람.
// `node --test test/surveyRules.test.js`(DB 없이).
import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  canViewSurveyResults,
  isSurveyClosed,
  isSurveyTarget,
  parseAnswers,
  parseSurveyInput,
  summarizeSurvey,
  surveyTargetIds,
} from '../src/surveyRules.js';
import {
  adjacentPeriod,
  canViewReport,
  currentPeriodStart,
  parseReportBody,
  parseReportPeriod,
  periodEndOf,
  periodStartOf,
  reportRoster,
} from '../src/workReportRules.js';

const kst = (s) => new Date(`${s.replace(' ', 'T')}:00+09:00`);
const now = kst('2026-10-07 10:00'); // 수요일

const questions = [
  { kind: 'single', title: '만족도', options: ['좋음', '보통', '나쁨'] },
  { kind: 'multiple', title: '좋았던 점', options: [{ text: '강의' }, { text: '실습' }], required: false },
  { kind: 'text', title: '건의', required: false },
  { kind: 'rating', title: '추천 점수' },
];

test('설문 입력 — 제목·문항·보기·대상·마감 검사, id를 붙인다', () => {
  const eligibleIds = new Set(['a', 'b']);
  const { values } = parseSurveyInput({ title: ' 교육 만족도 ', questions, closesAt: now.getTime() + 3600000 }, { now, eligibleIds });
  assert.equal(values.title, '교육 만족도');
  assert.equal(values.questions.length, 4);
  assert.match(values.questions[0].id, /^q[a-z0-9]+$/);
  assert.equal(values.questions[0].options.length, 3);
  assert.match(values.questions[0].options[0].id, /^o[a-z0-9]+$/);
  assert.equal(values.questions[1].required, false);
  assert.equal(values.questions[3].required, true);
  assert.equal(values.audience, 'all');
  assert.equal(values.resultVisibility, 'creator');
  const err = (body) => parseSurveyInput({ title: 't', questions, ...body }, { now, eligibleIds }).error;
  assert.match(parseSurveyInput({ title: '', questions }, { now }).error, /제목/);
  assert.match(err({ questions: [] }), /문항/);
  assert.match(err({ questions: [{ kind: 'single', title: 'x', options: ['하나'] }] }), /보기를 2개/);
  assert.match(err({ questions: [{ kind: 'single', title: 'x', options: ['a', 'a'] }] }), /같은 보기/);
  assert.match(err({ questions: [{ kind: 'nope', title: 'x' }] }), /종류/);
  assert.match(err({ closesAt: now.getTime() - 1 }), /이후/);
  assert.match(err({ audience: 'users', targetIds: [] }), /고르세요/);
  assert.match(err({ audience: 'users', targetIds: ['z'] }), /받을 수 없는/);
  assert.deepEqual(parseSurveyInput({ title: 't', questions, audience: 'users', targetIds: ['a', 'a'] }, { now, eligibleIds }).values.targetIds, ['a']);
});

test('설문 대상·마감 — 모두/고른 사람, 마감 시각·마감함', () => {
  const eligible = new Set(['a', 'b', 'c']);
  assert.equal(isSurveyTarget({ audience: 'all' }, 'c', eligible), true);
  assert.equal(isSurveyTarget({ audience: 'users', targetIds: ['a'] }, 'c', eligible), false);
  assert.deepEqual(surveyTargetIds({ audience: 'users', targetIds: ['a', 'gone'] }, eligible), ['a']);
  assert.equal(isSurveyClosed({ closesAt: kst('2026-10-07 09:00') }, now), true);
  assert.equal(isSurveyClosed({ closesAt: kst('2026-10-08 09:00') }, now), false);
  assert.equal(isSurveyClosed({ closedAt: now }, now), true);
});

test('응답 검사·집계 — 필수 문항, 보기 id, 별점 범위, 익명이면 이름 없이', () => {
  const survey = { ...parseSurveyInput({ title: 't', questions }, { now }).values, createdBy: 'boss' };
  const [q1, q2, q3, q4] = survey.questions;
  const ok = parseAnswers(survey, { [q1.id]: q1.options[0].id, [q2.id]: [q2.options[1].id, q2.options[0].id], [q4.id]: 4 });
  assert.deepEqual(ok.answers[q2.id], [q2.options[0].id, q2.options[1].id], '보기 순서로 정리');
  assert.equal(q3.id in ok.answers, false, '안 한 선택 문항은 뺀다');
  assert.match(parseAnswers(survey, { [q4.id]: 3 }).error, /1번 문항에 답하세요/);
  assert.match(parseAnswers(survey, { [q1.id]: 'oxxxxxxx', [q4.id]: 3 }).error, /보기/);
  assert.match(parseAnswers(survey, { [q1.id]: q1.options[0].id, [q4.id]: 6 }).error, /1~5점/);
  assert.match(parseAnswers(survey, null).error, /응답/);

  const responses = [
    { userId: 'a', answers: { [q1.id]: q1.options[0].id, [q3.id]: '실습 더', [q4.id]: 5 } },
    { userId: 'b', answers: { [q1.id]: q1.options[0].id, [q2.id]: [q2.options[1].id], [q3.id]: '간식', [q4.id]: 4 } },
  ];
  const names = new Map([
    ['a', '김가'],
    ['b', '이나'],
  ]);
  const [s1, s2, s3, s4] = summarizeSurvey(survey, responses, { names });
  assert.deepEqual(s1.options.map((o) => o.count), [2, 0, 0]);
  assert.deepEqual(s2.options.map((o) => o.count), [0, 1]);
  assert.equal(s2.answered, 1);
  assert.deepEqual(s3.texts, [
    { name: '김가', text: '실습 더' },
    { name: '이나', text: '간식' },
  ]);
  assert.equal(s4.average, 4.5);
  assert.deepEqual(s4.distribution, [0, 0, 0, 1, 1]);
  const anon = summarizeSurvey({ ...survey, anonymous: true }, responses, { names })[2];
  assert.deepEqual(anon.texts, [
    { name: null, text: '간식' },
    { name: null, text: '실습 더' },
  ]);

  const view = (extra) => canViewSurveyResults({ survey, userId: 'x', isManager: false, isTarget: true, responded: false, ...extra });
  assert.equal(view({}), false);
  assert.equal(view({ userId: 'boss' }), true);
  assert.equal(view({ isManager: true }), true);
  assert.equal(canViewSurveyResults({ survey: { ...survey, resultVisibility: 'respondents' }, userId: 'x', responded: true }), true);
  assert.equal(canViewSurveyResults({ survey: { ...survey, resultVisibility: 'all' }, userId: 'x', isTarget: true }), true);
});

test('업무일지 기간 — 일일은 그 날, 주간은 월요일, 앞으로의 기간은 막는다', () => {
  assert.equal(periodStartOf('weekly', '2026-10-07'), '2026-10-05');
  assert.equal(periodStartOf('weekly', '2026-10-11'), '2026-10-05', '일요일은 그 주');
  assert.equal(periodStartOf('weekly', '2026-10-05'), '2026-10-05');
  assert.equal(periodEndOf('weekly', '2026-10-05'), '2026-10-11');
  assert.equal(currentPeriodStart('daily', now), '2026-10-07');
  assert.equal(currentPeriodStart('weekly', now), '2026-10-05');
  assert.equal(adjacentPeriod('weekly', '2026-10-05', -1), '2026-09-28');
  assert.equal(adjacentPeriod('daily', '2026-10-01', -1), '2026-09-30');
  assert.deepEqual(parseReportPeriod('daily', undefined, now), { kind: 'daily', periodStart: '2026-10-07' });
  assert.match(parseReportPeriod('weekly', '2026-10-06', now).error, /월요일/);
  assert.match(parseReportPeriod('daily', '2026-10-08', now).error, /아직/);
  assert.match(parseReportPeriod('monthly', '2026-10-01', now).error, /종류/);
  assert.match(parseReportPeriod('daily', '2026-13-01', now).error, /형식/);
});

test('업무일지 본문·볼 수 있는 사람·팀 현황 순서', () => {
  assert.deepEqual(parseReportBody({ done: ' 회의 ', plan: '', issues: null }).values, { done: '회의', plan: null, issues: null });
  assert.match(parseReportBody({ issues: '이슈만' }).error, /한 일이나 할 일/);
  assert.match(parseReportBody({ done: 'x'.repeat(5001) }).error, /5000자/);
  assert.equal(canViewReport({ writerId: 'a', viewerId: 'a', reviewerIds: [], isManager: false }), true);
  assert.equal(canViewReport({ writerId: 'a', viewerId: 'm', reviewerIds: ['m'], isManager: false }), true);
  assert.equal(canViewReport({ writerId: 'a', viewerId: 'x', reviewerIds: ['m'], isManager: false }), false);
  assert.equal(canViewReport({ writerId: 'a', viewerId: 'x', reviewerIds: [], isManager: true }), true);
  const roster = reportRoster(
    [
      { id: 'a', name: '나다' },
      { id: 'b', name: '가나' },
      { id: 'c', name: '다라' },
    ],
    [{ userId: 'a', id: 'r1' }],
  );
  assert.deepEqual(roster.map((r) => [r.name, !!r.report]), [
    ['가나', false],
    ['다라', false],
    ['나다', true],
  ]);
});
