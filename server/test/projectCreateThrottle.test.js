// 프로젝트 만들기 횟수 제한과 공개 프로젝트 생성 알림(미루기·시간당 상한) 테스트 — `node --test test/projectCreateThrottle.test.js`
// (DB·서버 없이 돈다). 공개 프로젝트를 만들고 바로 지우기를 되풀이해 팀 전체에 끌 수 없는 푸시를 보내던 문제(S15)의 규칙이다:
// 만들기는 사람마다 10분 상한, 알림은 몇 분 뒤에 그때도 공개 프로젝트로 남아 있을 때만, 만든 사람·팀마다 시간당 몇 번까지만.
// 프로젝트를 다시 읽어 보내도 되는지 정하는 부분(projects.js의 prepare — 지웠는지·비공개·종료·만든 사람 상태)은 DB가 있어야
// 해서, 여기서는 그 결과를 흉내 낸 prepare로 엔진(ProjectCreatedAnnouncer)이 결과대로 움직이는지를 본다.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  PROJECT_CREATE_MAX,
  PROJECT_CREATE_WINDOW_MS,
  PROJECT_CREATED_NOTIFY_DELAY_MS,
  PROJECT_CREATED_NOTIFY_PER_CREATOR,
  PROJECT_CREATED_NOTIFY_PER_TEAM,
  PROJECT_CREATED_NOTIFY_WINDOW_MS,
  ProjectCreatedAnnouncer,
  createProjectCreateLimiter,
} from '../src/projectNotifications.js';

const MIN = 60 * 1000;
const silent = { warn() {}, error() {} };

/** 손으로 돌리는 시계·타이머 — advance(ms)로 시간을 보내면 그때까지 걸린 타이머가 차례로 돈다. */
function fakeClock(start = Date.parse('2026-10-07T00:00:00Z')) {
  let t = start;
  let seq = 0;
  const timers = new Map(); // id → { at, fn }
  return {
    now: () => t,
    setTimer(fn, ms) {
      seq += 1;
      timers.set(seq, { at: t + ms, fn });
      return seq;
    },
    clearTimer(id) {
      timers.delete(id);
    },
    pending: () => timers.size,
    /** [ms]만큼 시간을 보내고, 그 사이 시각이 된 타이머를 돌린 뒤 그 콜백이 낸 비동기 일까지 끝나기를 기다린다. */
    async advance(ms) {
      t += ms;
      for (const [id, timer] of [...timers].sort((a, b) => a[1].at - b[1].at)) {
        if (timer.at > t) continue;
        timers.delete(id);
        timer.fn();
      }
      for (let i = 0; i < 10; i += 1) await new Promise((resolve) => setImmediate(resolve));
    },
  };
}

/**
 * 알림 엔진 + 기록. [projects]는 projectId → 프로젝트(지우면 delete) — prepare는 projects.js처럼 시각이 됐을 때 다시 읽어서
 * 없거나 비공개·종료면 null을 준다(이름도 그때의 이름을 쓴다).
 */
function announcer(clock, options = {}) {
  const projects = new Map();
  const sent = [];
  const prepared = [];
  const a = new ProjectCreatedAnnouncer({
    prepare: async (job) => {
      prepared.push(job.projectId);
      const p = projects.get(job.projectId);
      return p && p.isPublic && !p.archivedAt ? { project: { ...p }, creatorId: job.creatorId } : null;
    },
    send: async ({ project, creatorId }) => {
      sent.push({ projectId: project.id, name: project.name, creatorId });
    },
    now: clock.now,
    setTimer: clock.setTimer,
    clearTimer: clock.clearTimer,
    log: silent,
    ...options,
  });
  const create = (id, { teamId = 'team-1', creatorId = 'u1', name = `프로젝트 ${id}` } = {}) => {
    projects.set(id, { id, teamId, name, isPublic: true, archivedAt: null });
    a.schedule({ projectId: id, teamId, creatorId });
  };
  return { a, projects, sent, prepared, create };
}

test('만들기 횟수: 사람마다 10분에 15개까지, 창이 지나면 다시 된다', () => {
  assert.equal(PROJECT_CREATE_MAX, 15);
  assert.equal(PROJECT_CREATE_WINDOW_MS, 10 * MIN);
  let t = 0;
  const limiter = createProjectCreateLimiter({ now: () => t });
  for (let i = 0; i < PROJECT_CREATE_MAX; i += 1) assert.equal(limiter.hit('u1'), 0, `${i + 1}번째`);
  const wait = limiter.hit('u1');
  assert.ok(wait > 0 && wait <= PROJECT_CREATE_WINDOW_MS, '16번째는 막히고 창이 끝날 때까지 기다린다');
  // 다른 사람은 따로 센다(남이 대신 막을 수 없다).
  assert.equal(limiter.hit('u2'), 0);
  t += PROJECT_CREATE_WINDOW_MS;
  assert.equal(limiter.hit('u1'), 0);
});

test('생성 알림 기본값: 몇 분 미루고, 만든 사람·팀마다 시간당 몇 번까지만', () => {
  assert.ok(PROJECT_CREATED_NOTIFY_DELAY_MS >= MIN && PROJECT_CREATED_NOTIFY_DELAY_MS <= 10 * MIN);
  assert.equal(PROJECT_CREATED_NOTIFY_WINDOW_MS, 60 * MIN);
  assert.ok(PROJECT_CREATED_NOTIFY_PER_CREATOR >= 1 && PROJECT_CREATED_NOTIFY_PER_CREATOR <= 5);
  assert.ok(PROJECT_CREATED_NOTIFY_PER_TEAM > PROJECT_CREATED_NOTIFY_PER_CREATOR);
});

test('생성 알림은 바로 가지 않고 미룬 시간이 지난 뒤에, 그때의 이름으로 간다', async () => {
  const clock = fakeClock();
  const { projects, sent, create } = announcer(clock);
  create('p1', { name: '처음 이름' });
  await clock.advance(PROJECT_CREATED_NOTIFY_DELAY_MS - 1);
  assert.deepEqual(sent, [], '미룬 시간 전에는 보내지 않는다');
  // 그 사이 이름을 고쳤으면 고친 이름으로 보낸다(시각이 됐을 때 다시 읽는다).
  projects.get('p1').name = '고친 이름';
  await clock.advance(1);
  assert.deepEqual(sent, [{ projectId: 'p1', name: '고친 이름', creatorId: 'u1' }]);
  assert.equal(clock.pending(), 0);
});

test('만들고 곧 지우거나 비공개·종료로 돌리면 아무에게도 안 가고 상한도 쓰지 않는다', async () => {
  const clock = fakeClock();
  const { a, projects, sent, prepared, create } = announcer(clock);
  // 만들고 지우기를 아무리 되풀이해도(공격) 알림은 하나도 안 나간다.
  for (let i = 0; i < 50; i += 1) {
    create(`gone-${i}`);
    projects.delete(`gone-${i}`);
  }
  create('private');
  projects.get('private').isPublic = false;
  create('archived');
  projects.get('archived').archivedAt = new Date();
  await clock.advance(PROJECT_CREATED_NOTIFY_DELAY_MS);
  assert.deepEqual(sent, []);
  assert.equal(prepared.length, 52, '시각이 되면 하나씩 다시 읽어 본다');
  // 보내지 않은 알림은 시간당 상한을 쓰지 않았다 — 같은 사람이 이어서 만든 진짜 공개 프로젝트 알림은 그대로 간다.
  for (let i = 0; i < PROJECT_CREATED_NOTIFY_PER_CREATOR; i += 1) create(`real-${i}`);
  await clock.advance(PROJECT_CREATED_NOTIFY_DELAY_MS);
  assert.equal(sent.length, PROJECT_CREATED_NOTIFY_PER_CREATOR);
  assert.equal(await a.fire({ projectId: 'gone-0', teamId: 'team-1', creatorId: 'u1' }), 'gone');
});

test('지우면 미뤄 둔 타이머를 바로 치운다(cancel), 같은 프로젝트를 다시 걸면 하나만 남는다', async () => {
  const clock = fakeClock();
  const { a, prepared, sent, create } = announcer(clock);
  create('p1');
  create('p1');
  assert.equal(clock.pending(), 1);
  a.cancel('p1');
  assert.equal(clock.pending(), 0);
  a.cancel('p1'); // 없는 것을 또 취소해도 괜찮다.
  await clock.advance(PROJECT_CREATED_NOTIFY_DELAY_MS * 2);
  assert.deepEqual(prepared, []);
  assert.deepEqual(sent, []);
});

test('만든 사람·팀마다 시간당 3번까지 — 넘친 알림은 건너뛰고, 한 시간이 지나면 다시 간다', async () => {
  const clock = fakeClock();
  const { a, sent, create } = announcer(clock);
  for (let i = 0; i < 6; i += 1) create(`p${i}`);
  await clock.advance(PROJECT_CREATED_NOTIFY_DELAY_MS);
  assert.deepEqual(
    sent.map((s) => s.projectId),
    ['p0', 'p1', 'p2'],
  );
  // 같은 사람이라도 다른 팀은 따로 센다.
  create('other-team', { teamId: 'team-2' });
  await clock.advance(PROJECT_CREATED_NOTIFY_DELAY_MS);
  assert.equal(sent.at(-1).projectId, 'other-team');
  assert.equal(await a.fire({ projectId: 'p5', teamId: 'team-1', creatorId: 'u1' }), 'throttled');
  // 한 시간 창이 지나면 다시 보낸다.
  await clock.advance(PROJECT_CREATED_NOTIFY_WINDOW_MS);
  create('later');
  await clock.advance(PROJECT_CREATED_NOTIFY_DELAY_MS);
  assert.equal(sent.at(-1).projectId, 'later');
});

test('팀 전체 상한 — 여러 계정으로 나눠도 묶이고, 한 사람이 넘친 만큼 다른 사람 몫을 쓰지 않는다', async () => {
  const clock = fakeClock();
  const { sent, create } = announcer(clock, { perCreator: 3, perTeam: 10 });
  // u1이 20개를 만들어도 u1 몫(3)만 나가고 나머지는 팀 몫을 쓰지 않는다.
  for (let i = 0; i < 20; i += 1) create(`a${i}`, { creatorId: 'u1' });
  await clock.advance(PROJECT_CREATED_NOTIFY_DELAY_MS);
  assert.equal(sent.length, 3);
  // 다른 사람들은 팀 몫(10)이 찰 때까지 보낸다 — 이미 쓴 3 + 7.
  for (const creatorId of ['u2', 'u3', 'u4']) {
    for (let i = 0; i < 3; i += 1) create(`${creatorId}-${i}`, { creatorId });
  }
  await clock.advance(PROJECT_CREATED_NOTIFY_DELAY_MS);
  assert.equal(sent.length, 10);
  assert.deepEqual(
    sent.slice(3).map((s) => s.creatorId),
    ['u2', 'u2', 'u2', 'u3', 'u3', 'u3', 'u4'],
  );
});

test('다시 읽기·보내기가 실패해도 던지지 않는다(타이머에서 돈다)', async () => {
  const clock = fakeClock();
  const errors = [];
  const a = new ProjectCreatedAnnouncer({
    prepare: async (job) => {
      if (job.projectId === 'boom') throw new Error('db down');
      return { ok: true };
    },
    send: async () => {
      throw new Error('push down');
    },
    now: clock.now,
    setTimer: clock.setTimer,
    clearTimer: clock.clearTimer,
    log: { warn() {}, error: (...args) => errors.push(args.join(' ')) },
  });
  assert.equal(await a.fire({ projectId: 'boom', teamId: 't', creatorId: 'u' }), 'failed');
  assert.equal(await a.fire({ projectId: 'ok', teamId: 't', creatorId: 'u' }), 'failed');
  a.schedule({ projectId: 'boom', teamId: 't', creatorId: 'u' });
  await clock.advance(PROJECT_CREATED_NOTIFY_DELAY_MS);
  assert.equal(errors.length, 3);
});
