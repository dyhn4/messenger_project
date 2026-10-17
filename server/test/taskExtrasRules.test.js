// 업무 기능 보강 규칙 — 반복 업무 다음 회차, 선후행 순환, 소요 시간 입력·타이머·보고 기간, 그리고 하위 라우터 주소가 프로젝트
// 입구(준회원 막기) 아래에 있는지. `node --test test/taskExtrasRules.test.js`(DB 없이).
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { test } from 'node:test';
import { PROJECT_ROUTE_PREFIXES } from '../src/projectNotifications.js';
import {
  kstDateKey,
  minutesLabel,
  nextOccurrence,
  nextOccurrenceDates,
  parseEstimate,
  parseRecurrence,
  parseReportRange,
  parseTimeEntry,
  recurrenceLabel,
  recurrenceOf,
  timerEntry,
  wouldCreateCycle,
} from '../src/taskExtrasRules.js';

/** 한국 시각 'YYYY-MM-DD HH:MM' → Date. */
const kst = (s) => new Date(`${s.replace(' ', 'T')}:00+09:00`);

test('반복 규칙 입력 — 주기·간격·요일·종료일, null은 끄기', () => {
  assert.deepEqual(parseRecurrence(null), { recurrence: null });
  assert.deepEqual(parseRecurrence({ freq: 'weekly', byWeekday: [3, 1, 1] }).recurrence, {
    freq: 'weekly',
    interval: 1,
    byWeekday: [1, 3],
  });
  // 요일은 매주에만.
  assert.deepEqual(parseRecurrence({ freq: 'daily', interval: 2, byWeekday: [1] }).recurrence, { freq: 'daily', interval: 2 });
  assert.match(parseRecurrence({ freq: 'hourly' }).error, /주기/);
  assert.match(parseRecurrence({ freq: 'daily', interval: 0 }).error, /간격/);
  assert.match(parseRecurrence({ freq: 'daily', interval: 100 }).error, /간격/);
  assert.match(parseRecurrence({ freq: 'weekly', byWeekday: [7] }).error, /요일/);
  assert.match(parseRecurrence({ freq: 'daily', until: '2026-02-30' }).error, /종료일/);
  assert.match(parseRecurrence('daily').error, /규칙/);
  assert.equal(recurrenceOf({ recurrence: { freq: 'nope' } }), null);
  assert.equal(recurrenceLabel({ freq: 'weekly', interval: 1, byWeekday: [1, 3] }), '매주 월·수');
  assert.equal(recurrenceLabel({ freq: 'monthly', interval: 3, until: '2026-12-31' }), '3개월마다 (~2026-12-31)');
});

test('다음 회차 — 주기별 날짜, 달 끝 날짜, 늦게 끝내면 오늘 이후로, 종료일', () => {
  const done = kst('2026-10-05 10:00');
  assert.equal(nextOccurrence({ freq: 'daily', interval: 1 }, '2026-10-05', done).key, '2026-10-06');
  // 월(1)·수(3) — 2026-10-05는 월요일.
  assert.equal(nextOccurrence({ freq: 'weekly', interval: 1, byWeekday: [1, 3] }, '2026-10-05', done).key, '2026-10-07');
  assert.equal(nextOccurrence({ freq: 'weekly', interval: 1, byWeekday: [1, 3] }, '2026-10-07', done).key, '2026-10-12');
  // 2주마다 월요일 — 다음 주는 건너뛴다.
  assert.equal(nextOccurrence({ freq: 'weekly', interval: 2, byWeekday: [1] }, '2026-10-05', done).key, '2026-10-19');
  assert.equal(nextOccurrence({ freq: 'weekly', interval: 1 }, '2026-10-05', done).key, '2026-10-12');
  // 1월 31일 매월 → 2월 28일(그 달 마지막 날).
  const jan = kst('2026-01-31 09:00');
  assert.equal(nextOccurrence({ freq: 'monthly', interval: 1 }, '2026-01-31', jan).key, '2026-02-28');
  assert.equal(nextOccurrence({ freq: 'yearly', interval: 1 }, '2024-02-29', kst('2024-02-29 09:00')).key, '2025-02-28');
  // 마감이 9월 1일인 매일 업무를 10월 5일에 끝냄 — 밀린 회차를 만들지 않고 오늘부터.
  assert.equal(nextOccurrence({ freq: 'daily', interval: 1 }, '2026-09-01', done).key, '2026-10-05');
  assert.equal(nextOccurrence({ freq: 'monthly', interval: 1 }, '2026-08-15', done).key, '2026-10-15');
  // 종료일을 넘으면 반복 끝.
  assert.equal(nextOccurrence({ freq: 'daily', interval: 1, until: '2026-10-05' }, '2026-10-05', done), null);
});

test('다음 회차 날짜 — 시작일·마감일을 같은 날 수만큼(시각 그대로), 날짜가 없으면 다음 날 18시 마감', () => {
  const rule = { freq: 'weekly', interval: 1 };
  const task = { startDate: kst('2026-10-01 09:00'), dueDate: kst('2026-10-02 18:00') };
  const next = nextOccurrenceDates(task, rule, kst('2026-10-02 17:00'));
  assert.deepEqual(next, { startDate: kst('2026-10-08 09:00'), dueDate: kst('2026-10-09 18:00') });
  const onlyStart = nextOccurrenceDates({ startDate: kst('2026-10-01 09:00') }, rule, kst('2026-10-01 10:00'));
  assert.deepEqual(onlyStart, { startDate: kst('2026-10-08 09:00'), dueDate: null });
  const none = nextOccurrenceDates({}, { freq: 'daily', interval: 1 }, kst('2026-10-05 23:30'));
  assert.deepEqual(none, { startDate: null, dueDate: kst('2026-10-06 18:00') });
  // 한국 날짜 기준 — UTC로는 아직 전날인 새벽에 끝내도 그 한국 날짜로 센다.
  assert.equal(kstDateKey(kst('2026-10-05 01:00')), '2026-10-05');
});

test('선후행 — 자기 자신·순환(간접 포함)은 막는다', () => {
  // B는 A를 기다리고, C는 B를 기다린다.
  const edges = [
    { taskId: 'B', dependsOnId: 'A' },
    { taskId: 'C', dependsOnId: 'B' },
  ];
  assert.equal(wouldCreateCycle(edges, 'A', 'A'), true);
  assert.equal(wouldCreateCycle(edges, 'A', 'C'), true, 'A가 C를 기다리면 A→C→B→A');
  assert.equal(wouldCreateCycle(edges, 'A', 'B'), true);
  assert.equal(wouldCreateCycle(edges, 'C', 'A'), false, '이미 간접으로 기다리는 것을 직접 더해도 순환은 아니다');
  assert.equal(wouldCreateCycle(edges, 'D', 'C'), false);
});

test('소요 시간 — 분·날짜·메모 검사, 타이머 기록, 예상 시간, 보고 기간', () => {
  const now = kst('2026-10-05 12:00');
  assert.deepEqual(parseTimeEntry({ minutes: 90 }, now).entry, { minutes: 90, workDate: '2026-10-05', note: null });
  assert.deepEqual(parseTimeEntry({ minutes: 30, workDate: '2026-10-01', note: ' 회의 ' }, now).entry, {
    minutes: 30,
    workDate: '2026-10-01',
    note: '회의',
  });
  assert.match(parseTimeEntry({ minutes: 0 }, now).error, /1분/);
  assert.match(parseTimeEntry({ minutes: 1.5 }, now).error, /1분/);
  assert.match(parseTimeEntry({ minutes: 24 * 60 + 1 }, now).error, /24시간/);
  assert.match(parseTimeEntry({ minutes: 10, workDate: '2026-10-06' }, now).error, /앞으로/);
  assert.match(parseTimeEntry({ minutes: 10, note: 'x'.repeat(201) }, now).error, /200자/);
  assert.equal(timerEntry(kst('2026-10-05 09:00'), kst('2026-10-05 09:00')), null, '1분이 안 되면 버린다');
  assert.deepEqual(timerEntry(kst('2026-10-04 23:30'), kst('2026-10-05 01:00')), { minutes: 90, workDate: '2026-10-04' });
  assert.equal(timerEntry(kst('2026-10-01 09:00'), kst('2026-10-05 09:00')).minutes, 1440, '하루로 자른다');
  assert.deepEqual(parseEstimate(null), { value: null });
  assert.deepEqual(parseEstimate(120), { value: 120 });
  assert.match(parseEstimate(0).error, /예상/);
  assert.equal(minutesLabel(150), '2시간 30분');
  assert.equal(minutesLabel(45), '45분');
  assert.equal(minutesLabel(180), '3시간');
  assert.deepEqual(parseReportRange({}, now), { from: '2026-10-01', to: '2026-10-05' });
  assert.match(parseReportRange({ from: '2026-10-05', to: '2026-10-01' }, now).error, /늦/);
  assert.match(parseReportRange({ from: '2024-01-01', to: '2026-10-01' }, now).error, /1년/);
});

test('하위 라우터(taskExtras.js)의 주소는 모두 프로젝트 입구 목록 아래다', () => {
  const source = fs.readFileSync(new URL('../src/taskExtras.js', import.meta.url), 'utf8');
  const routes = [...source.matchAll(/router\.(get|post|put|patch|delete)\(\s*'([^']+)'/g)].map((m) => m[2]);
  assert.ok(routes.length >= 9, `라우트 ${routes.length}개`);
  assert.doesNotMatch(source, /router\.(get|post|put|patch|delete)\(\s*[^'\s]/);
  const covered = (path) => PROJECT_ROUTE_PREFIXES.some((p) => path === p || path.startsWith(`${p}/`));
  assert.deepEqual(routes.filter((p) => !covered(p)), []);
  // 하위 라우터는 입구 바로 뒤, /tasks/:id 라우트보다 먼저 붙는다(GET /tasks/timer가 업무 id로 읽히지 않게).
  const projects = fs.readFileSync(new URL('../src/projects.js', import.meta.url), 'utf8');
  const guard = projects.indexOf('router.use(PROJECT_ROUTE_PREFIXES');
  const mount = projects.indexOf('router.use(taskExtras.router)');
  const detail = projects.indexOf("router.get('/tasks/:id'");
  assert.ok(guard > 0 && mount > guard && mount < detail);
});
