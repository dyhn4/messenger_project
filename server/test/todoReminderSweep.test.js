// 할 일 알림 점검(검토 S19) 테스트 — `node --test test/todoReminderSweep.test.js` (DB·서버 없이 돈다).
// 예전 점검은 1분에 서버 전체에서 가장 이른 알림 200건만 찜했고, 하루 넘게 늦어진 알림은 아무 표시 없이 버렸다. 그래서
// 누군가 알림을 한꺼번에 몰아 두면 남의 알림이 밀리다가 사라졌다. 여기서는 (1) 한 바퀴에 밀린 것을 다 보내는지(시간을 다
// 쓰면 다음 바퀴가 이어서), (2) 할 일을 만든 사람마다 돌아가며 골라 남의 알림이 첫 묶음에 드는지, (3) "너무 오래 묵은
// 알림"을 늦어진 시간이 아니라 서버(점검)가 멈춰 있던 시간으로 판단하는지, (4) 만들기·알림 추가의 횟수 제한과 알림 개수
// 상한이 보통 쓰임에는 걸리지 않는지를 본다. 찜하기는 실제로는 SQL(db/queries/todos.js claimDueTodoReminders)이라, 아래
// FakeReminderStore가 그 SQL과 같은 순서(만든 사람마다의 차례 → 이른 순 → id)로 고른다.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { RateLimiter, tooMany } from '../src/authGuard.js';
import {
  drainDueReminders,
  planReminders,
  reminderUptimeAfterSweep,
  schedulesReminders,
  shouldDeliverReminder,
  TODO_CREATE_RATE,
  TODO_PENDING_REMINDERS_ERROR,
  TODO_PENDING_REMINDERS_MAX,
  TODO_REMINDER_EDIT_RATE,
  TODO_REMINDER_STALE_MS,
  TODO_REMINDER_SWEEP_BATCH,
  TODO_REMINDER_SWEEP_BUDGET_MS,
  TODO_REMINDER_UPTIME_START,
  TODO_REMINDERS_MAX,
} from '../src/todoRules.js';

const MIN = 60 * 1000;
const HOUR = 60 * MIN;
const T0 = 1_800_000_000_000; // 서버가 켜진(점검이 처음 성공한) 시각.

/** 찜하기 SQL과 같은 규칙의 메모리 저장소 — 아직 안 보낸 것 중 때가 된 것을, 만든 사람마다 돌아가며 [limit]건까지. */
class FakeReminderStore {
  constructor() {
    this.rows = [];
    this.nextId = 1;
    this.down = false; // true면 DB에 닿지 못하는 것처럼 찜이 실패한다.
  }

  add(creatorId, remindAt, count = 1) {
    for (let i = 0; i < count; i += 1) {
      this.rows.push({ id: `r${String(this.nextId++).padStart(6, '0')}`, creatorId, remindAt, sentAt: null });
    }
  }

  claim(at, limit) {
    if (this.down) throw new Error('DB에 닿지 못함');
    const due = this.rows.filter((r) => r.sentAt === null && r.remindAt <= at);
    const byTime = (a, b) => a.remindAt - b.remindAt || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0);
    // row_number() over (partition by creator_id order by remind_at, id)
    const turnOf = new Map();
    const seen = new Map();
    for (const r of [...due].sort(byTime)) {
      const n = (seen.get(r.creatorId) ?? 0) + 1;
      seen.set(r.creatorId, n);
      turnOf.set(r.id, n);
    }
    // order by turn, remind_at, id limit [limit]
    const picked = due.sort((a, b) => turnOf.get(a.id) - turnOf.get(b.id) || byTime(a, b)).slice(0, limit);
    for (const r of picked) r.sentAt = at;
    return { reminders: picked.map((r) => ({ ...r })), more: picked.length >= limit };
  }

  get pending() {
    return this.rows.filter((r) => r.sentAt === null).length;
  }
}

/** 손으로 움직이는 시계. */
function clock(start) {
  let t = start;
  return { now: () => t, advance: (ms) => (t += ms), set: (ms) => (t = ms) };
}

/**
 * todos.js sweepTodoReminders와 같은 짜임 — 찜이 성공할 때마다 가동 상태를 갱신하고(실패하면 그대로), 보내기는 그 상태로
 * shouldDeliverReminder를 본다. 보낸 알림은 [sent]에 { id, creatorId, remindAt, at(찜한 시각), batch }로 쌓는다.
 */
function sweeper(store, { clock: c, deliverMs = 0, budgetMs = TODO_REMINDER_SWEEP_BUDGET_MS, batch = TODO_REMINDER_SWEEP_BATCH } = {}) {
  const state = { uptime: TODO_REMINDER_UPTIME_START, sent: [], dropped: [], batches: 0 };
  const run = () =>
    drainDueReminders({
      now: c.now,
      budgetMs,
      claim: async (at) => {
        const claimed = store.claim(at, batch);
        state.uptime = reminderUptimeAfterSweep(state.uptime, at);
        return claimed;
      },
      deliver: async (reminders, at) => {
        state.batches += 1;
        let delivered = 0;
        const { upSince, downSince } = state.uptime;
        for (const r of reminders) {
          if (shouldDeliverReminder({ progress: 0, remindAt: r.remindAt, upSince, downSince })) {
            state.sent.push({ id: r.id, creatorId: r.creatorId, remindAt: r.remindAt, at, batch: state.batches });
            delivered += 1;
          } else {
            state.dropped.push(r.id);
          }
        }
        c.advance(deliverMs);
        return delivered;
      },
    });
  return { state, run };
}

// ── 너무 오래 묵은 알림: 늦어진 시간이 아니라 서버가 꺼져 있던 시간으로 ───────────────────

test('shouldDeliverReminder (S19): 서버가 도는 동안 때가 된 알림은 점검이 아무리 밀려도 보낸다', () => {
  const up = { upSince: T0, downSince: null };
  // 켜진 지 1시간 뒤에 때가 됐는데 점검이 밀려 30시간 뒤에야 찜했다 — 예전에는 하루가 넘었다고 버렸다.
  assert.ok(shouldDeliverReminder({ progress: 0, remindAt: T0 + HOUR, now: T0 + 31 * HOUR, ...up }));
  assert.ok(!shouldDeliverReminder({ progress: 0, remindAt: T0 + HOUR, now: T0 + 31 * HOUR }), '예전 판단(가동 상태 없음)');
  assert.ok(shouldDeliverReminder({ progress: 50, remindAt: T0 + HOUR, now: T0 + 30 * 24 * HOUR, ...up }));
  // 켜진 바로 그때 때가 된 것도.
  assert.ok(shouldDeliverReminder({ progress: 0, remindAt: T0, now: T0 + 48 * HOUR, ...up }));
  // 완료된 할 일은 언제든 보내지 않는다.
  assert.ok(!shouldDeliverReminder({ progress: 100, remindAt: T0 + HOUR, now: T0 + 2 * HOUR, ...up }));
});

test('shouldDeliverReminder (S19): 서버가 꺼져 있는 동안 때가 됐으면 다시 켜질 때까지 하루를 넘겼을 때만 넘긴다', () => {
  const up = { upSince: T0, downSince: null }; // 서버를 막 켬 — 그 전은 모두 꺼져 있던 것으로 본다.
  // 켜지기 23시간 전 → 보냄(얼마 뒤에 찜하든), 25시간 전 → 넘김, 정확히 하루 전 → 보냄(경계 포함).
  assert.ok(shouldDeliverReminder({ progress: 0, remindAt: T0 - 23 * HOUR, now: T0 + 10 * HOUR, ...up }));
  assert.ok(!shouldDeliverReminder({ progress: 0, remindAt: T0 - 25 * HOUR, now: T0, ...up }));
  assert.ok(shouldDeliverReminder({ progress: 0, remindAt: T0 - TODO_REMINDER_STALE_MS, now: T0 + HOUR, ...up }));
  assert.ok(!shouldDeliverReminder({ progress: 0, remindAt: T0 - TODO_REMINDER_STALE_MS - 1, now: T0, ...up }));
});

test('shouldDeliverReminder (S19): 켜져 있던 서버의 점검이 하루 넘게 끊겼으면(DB 끊김) 그 구간에 때가 된 것만 넘긴다', () => {
  const L = T0 + 5 * HOUR; // 마지막으로 점검이 성공한 시각.
  const T = L + 30 * HOUR; // 다시 성공한 시각.
  const up = { upSince: T, downSince: L };
  // 끊기기 전에 때가 됐는데 밀려 있던 것 → 보냄.
  assert.ok(shouldDeliverReminder({ progress: 0, remindAt: L - 2 * HOUR, now: T, ...up }));
  assert.ok(shouldDeliverReminder({ progress: 0, remindAt: L, now: T, ...up }));
  // 끊긴 동안 때가 됐고 다시 성공할 때까지 하루가 넘음 → 넘김. 하루가 안 됨 → 보냄. 다시 켜진 뒤 → 보냄.
  assert.ok(!shouldDeliverReminder({ progress: 0, remindAt: L + HOUR, now: T, ...up }));
  assert.ok(shouldDeliverReminder({ progress: 0, remindAt: T - 23 * HOUR, now: T, ...up }));
  assert.ok(shouldDeliverReminder({ progress: 0, remindAt: T + HOUR, now: T + 2 * HOUR, ...up }));
});

test('shouldDeliverReminder: 가동 상태를 안 주면 예전처럼 "지금 막 켜진 것"으로 본다', () => {
  assert.ok(shouldDeliverReminder({ progress: 0, remindAt: T0 - 1000, now: T0 }));
  assert.ok(!shouldDeliverReminder({ progress: 0, remindAt: T0 - 25 * HOUR, now: T0 }));
  // null로 줘도 같다(지금 기준) — 모든 알림을 보내 버리지 않는다.
  assert.ok(!shouldDeliverReminder({ progress: 0, remindAt: T0 - 25 * HOUR, now: T0, upSince: null, downSince: null }));
});

test('reminderUptimeAfterSweep: 처음 성공 = 켜짐, 하루 안의 끊김은 같은 구간, 하루 넘게 끊겼으면 그 사이를 꺼진 구간으로', () => {
  let s = reminderUptimeAfterSweep(TODO_REMINDER_UPTIME_START, T0);
  assert.deepEqual(s, { lastOkAt: T0, upSince: T0, downSince: null });
  assert.deepEqual(reminderUptimeAfterSweep(null, T0), s);
  // 1분마다 성공 — 구간은 그대로, 마지막 성공 시각만.
  s = reminderUptimeAfterSweep(s, T0 + MIN);
  assert.deepEqual(s, { lastOkAt: T0 + MIN, upSince: T0, downSince: null });
  // 몇 시간 끊겼다가(하루 이내) 다시 성공 — 그새 때가 된 알림은 하루를 넘길 수 없으니 같은 구간.
  s = reminderUptimeAfterSweep(s, T0 + MIN + TODO_REMINDER_STALE_MS);
  assert.deepEqual(s, { lastOkAt: T0 + MIN + TODO_REMINDER_STALE_MS, upSince: T0, downSince: null });
  // 하루 넘게 끊김 → 새 구간(끊긴 시각 = 마지막 성공).
  const last = s.lastOkAt;
  const back = last + TODO_REMINDER_STALE_MS + 1;
  s = reminderUptimeAfterSweep(s, back);
  assert.deepEqual(s, { lastOkAt: back, upSince: back, downSince: last });
  // 처음 값은 바뀌지 않는다(공유 상수).
  assert.deepEqual(TODO_REMINDER_UPTIME_START, { lastOkAt: null, upSince: null, downSince: null });
});

// ── 한 바퀴에 다 보내기·돌아가며 고르기 ─────────────────────────────────────────

test('drainDueReminders (S19): 검토의 공격 — 1만 2천 건을 몰아 둬도 한 바퀴에 전부 보내고, 남의 알림은 첫 묶음에 든다', async () => {
  const store = new FakeReminderStore();
  const at = T0 + 9 * HOUR;
  // 공격자: 할 일 2,400개 × 알림 5개를 다른 사람들보다 1분 앞에.
  store.add('attacker', at - MIN, 2400 * TODO_REMINDERS_MAX);
  // 다른 사람 50명의 알림(정각).
  for (let i = 0; i < 50; i += 1) store.add(`user${i}`, at);
  const c = clock(at);
  const { state, run } = sweeper(store, { clock: c, deliverMs: 100 });
  state.uptime = reminderUptimeAfterSweep(TODO_REMINDER_UPTIME_START, T0); // 서버는 아침부터 돌고 있었다.

  const result = await run();
  assert.equal(result.outOfTime, false);
  assert.equal(result.claimed, 12_050);
  assert.equal(result.delivered, 12_050);
  assert.equal(store.pending, 0);
  // 예전 점검은 1분에 200건만 — 남의 알림은 공격자 것 1만 2천 건 뒤라 1시간쯤 밀렸다. 이제는 첫 묶음.
  const others = state.sent.filter((s) => s.creatorId !== 'attacker');
  assert.equal(others.length, 50);
  assert.ok(others.every((s) => s.batch === 1), '다른 사람의 알림이 첫 묶음에 들어야 한다');
});

test('drainDueReminders (S19): 시간을 다 쓰면 멈추고 다음 바퀴가 이어서 보낸다', async () => {
  const store = new FakeReminderStore();
  const at = T0 + HOUR;
  store.add('flood', at, 12_000);
  store.add('victim', at + 2 * MIN); // 셋째 점검 때 때가 된다 — 홍수가 아직 다 안 빠졌을 때.
  const c = clock(at);
  // 한 묶음 보내는 데 2초 — 50초면 25묶음(5,000건)에서 멈춘다.
  const { state, run } = sweeper(store, { clock: c, deliverMs: 2000 });

  const first = await run();
  assert.equal(first.outOfTime, true);
  assert.equal(first.claimed, 25 * TODO_REMINDER_SWEEP_BATCH);
  assert.equal(store.pending, 12_001 - first.claimed);

  // 1분 간격 점검이 이어서 보낸다.
  let runs = 1;
  while (store.pending > 0) {
    c.set(at + runs * MIN);
    await run();
    runs += 1;
    if (runs > 20) assert.fail('끝나지 않는다');
  }
  assert.equal(runs, 3);
  assert.equal(state.dropped.length, 0);
  assert.equal(state.sent.length, 12_001);
  // 피해자의 알림은 때가 된 바로 그 점검의 첫 묶음(앞의 두 바퀴 50묶음 다음)에서 나간다 — 남은 홍수 2천 건보다 먼저.
  const victim = state.sent.find((s) => s.creatorId === 'victim');
  assert.equal(victim.at, victim.remindAt);
  assert.equal(victim.batch, 2 * 25 + 1);
});

test('drainDueReminders (S19): 점검이 밀려 하루 넘게 늦어져도, 서버가 도는 동안 때가 된 알림은 버리지 않는다', async () => {
  const store = new FakeReminderStore();
  const at = T0 + HOUR;
  // 아주 느린 서버 — 한 바퀴에 한 건씩만, 1분마다. 1,500건이면 마지막 건은 25시간 뒤에야 찜한다.
  store.add('flood', at, 1500);
  const c = clock(at);
  const { state, run } = sweeper(store, { clock: c, deliverMs: MIN, batch: 1 });
  while (store.pending > 0) await run();
  const last = state.sent.at(-1);
  assert.ok(last.at - last.remindAt > TODO_REMINDER_STALE_MS, '정말 하루 넘게 늦어졌다');
  assert.equal(state.dropped.length, 0, '서버가 켜져 있는 동안 때가 된 알림은 늦어도 보낸다');
  assert.equal(state.sent.length, 1500);
  // 예전 판단(찜한 시각 - 때가 된 시각 > 하루 → 버림)이었다면 버렸을 개수.
  const oldDropped = state.sent.filter((s) => !shouldDeliverReminder({ progress: 0, remindAt: s.remindAt, now: s.at }));
  assert.ok(oldDropped.length > 0);
});

test('drainDueReminders (S19): 서버를 켜기 전 하루 넘게 지난 알림은 넘기고, 켜기 전 하루 안의 것과 켠 뒤 것은 보낸다', async () => {
  const store = new FakeReminderStore();
  store.add('a', T0 - 30 * HOUR, 3); // 서버가 꺼져 있는 동안, 켜질 때 이미 하루가 넘음 → 넘김
  store.add('b', T0 - 2 * HOUR, 2); // 꺼져 있던 동안이지만 하루 안 → 보냄
  store.add('c', T0 + 5 * MIN, 1); // 켠 뒤
  const c = clock(T0);
  const { state, run } = sweeper(store, { clock: c });
  await run();
  c.set(T0 + 10 * MIN);
  await run();
  assert.equal(state.dropped.length, 3);
  assert.deepEqual(state.sent.map((s) => s.creatorId).sort(), ['b', 'b', 'c']);
});

test('drainDueReminders (S19): 켜진 채로 DB에 하루 넘게 못 닿았으면 그동안 때가 된 오래된 것만 넘긴다', async () => {
  const store = new FakeReminderStore();
  const c = clock(T0);
  const { state, run } = sweeper(store, { clock: c });
  await run(); // 서버가 켜짐(처음 성공).
  const lastOk = T0 + HOUR;
  c.set(lastOk);
  await run(); // 마지막으로 성공한 점검.
  // 끊기기 전에 때가 됐는데 아직 못 보낸 것(밀린 것) → 보냄.
  store.add('before', lastOk - 10 * MIN);
  store.add('during-old', lastOk + HOUR); // 끊긴 동안, 다시 닿을 때 하루가 넘음 → 넘김
  store.add('during-new', lastOk + 20 * HOUR); // 끊긴 동안이지만 다시 닿을 때 하루 안 → 보냄
  store.down = true;
  for (let h = 1; h <= 30; h += 1) {
    c.set(lastOk + h * HOUR);
    await assert.rejects(run());
  }
  store.down = false;
  c.set(lastOk + 30 * HOUR + MIN);
  await run();
  assert.equal(state.dropped.length, 1);
  assert.deepEqual(state.sent.map((s) => s.creatorId).sort(), ['before', 'during-new']);
  assert.equal(state.uptime.downSince, lastOk);
});

test('drainDueReminders: 묶음마다 "지금"을 새로 재서 오래 도는 동안 때가 된 알림도 같은 바퀴에서 찜한다', async () => {
  const store = new FakeReminderStore();
  store.add('busy', T0, 1000); // 5묶음
  store.add('late', T0 + 3 * MIN); // 넷째 묶음을 찜할 때 때가 된다
  const c = clock(T0);
  const { state, run } = sweeper(store, { clock: c, deliverMs: MIN, budgetMs: 10 * MIN });
  const result = await run();
  assert.equal(result.outOfTime, false);
  assert.equal(result.claimed, 1001);
  assert.equal(state.sent.find((s) => s.creatorId === 'late').batch, 4);
});

test('drainDueReminders: 고른 것을 다른 서버가 먼저 찜해 묶음이 비면 헛돌지 않고 끝낸다, 찜 오류는 그대로 올린다', async () => {
  let calls = 0;
  const result = await drainDueReminders({
    claim: async () => {
      calls += 1;
      return { reminders: [], more: true };
    },
    deliver: async () => assert.fail('보낼 것이 없다'),
  });
  assert.equal(calls, 1);
  assert.deepEqual(result, { claimed: 0, delivered: 0, batches: 1, outOfTime: false });

  await assert.rejects(
    drainDueReminders({
      claim: async () => {
        throw new Error('DB 끊김');
      },
      deliver: async () => 0,
    }),
    /DB 끊김/,
  );
});

test('drainDueReminders: 마지막 묶음이 덜 찼으면(more=false) 더 묻지 않는다', async () => {
  const store = new FakeReminderStore();
  store.add('x', T0, TODO_REMINDER_SWEEP_BATCH * 2 + 7);
  const c = clock(T0);
  const { run } = sweeper(store, { clock: c });
  const result = await run();
  assert.equal(result.batches, 3);
  assert.equal(result.claimed, TODO_REMINDER_SWEEP_BATCH * 2 + 7);
});

// ── 횟수 제한·알림 개수 상한 ────────────────────────────────────────────────

test('할 일 만들기 횟수 제한: 사람이 하나씩 만드는 속도로는 안 걸리고, 찍어내면 10분에 60개에서 429', () => {
  let t = T0;
  const human = new RateLimiter({ ...TODO_CREATE_RATE, now: () => t });
  // 한 시간 동안 12초에 하나씩(300개) — 한 번도 안 막힌다.
  for (let i = 0; i < 300; i += 1) {
    assert.equal(human.hit('me'), 0, `${i}번째`);
    t += 12 * 1000;
  }
  t = T0;
  const script = new RateLimiter({ ...TODO_CREATE_RATE, now: () => t });
  for (let i = 0; i < TODO_CREATE_RATE.max; i += 1) assert.equal(script.hit('bot'), 0);
  const wait = script.hit('bot');
  assert.ok(wait > 0 && wait <= TODO_CREATE_RATE.windowMs);
  // 사람마다 따로 — 남은 그대로 만든다.
  assert.equal(script.hit('someone-else'), 0);
  // 검토의 공격(할 일 2,400개)은 이제 최소 400분이 걸린다.
  assert.ok((2400 / TODO_CREATE_RATE.max) * TODO_CREATE_RATE.windowMs >= 400 * MIN);
  assert.deepEqual(TODO_CREATE_RATE, { max: 60, windowMs: 10 * MIN });
  assert.deepEqual(TODO_REMINDER_EDIT_RATE, { max: 60, windowMs: 10 * MIN });
});

test('횟수 제한 응답: 429 + Retry-After + 한국어 문구(할 일 추가·알림 추가)', () => {
  const fakeRes = () => {
    const res = { headers: {}, statusCode: 0, body: null };
    res.set = (k, v) => ((res.headers[k] = v), res);
    res.status = (code) => ((res.statusCode = code), res);
    res.json = (body) => ((res.body = body), res);
    return res;
  };
  const a = tooMany(fakeRes(), 9 * MIN + 1000, '할 일 추가');
  assert.equal(a.statusCode, 429);
  assert.equal(a.headers['Retry-After'], String(9 * 60 + 1));
  assert.equal(a.body.error, '할 일 추가가 너무 많습니다. 10분 후 다시 시도하세요.');
  assert.equal(tooMany(fakeRes(), 30 * 1000, '알림 추가').body.error, '알림 추가가 너무 많습니다. 1분 후 다시 시도하세요.');
});

test('아직 보내지 않은 알림 상한: 할 일 200개에 5개씩까지는 되고, 문구에 상한이 보인다', () => {
  assert.equal(TODO_PENDING_REMINDERS_MAX, 1000);
  assert.ok(200 * TODO_REMINDERS_MAX <= TODO_PENDING_REMINDERS_MAX);
  assert.ok(TODO_PENDING_REMINDERS_ERROR.includes(`${TODO_PENDING_REMINDERS_MAX}개`));
  // 검토의 공격(알림 1만 2천 건)은 한 계정으로는 이제 쌓을 수 없다.
  assert.ok(TODO_PENDING_REMINDERS_MAX < 12_000);
});

test('schedulesReminders: 알림을 새로 넣거나 시각을 바꾸는 수정만 — 지우기·그대로는 세지 않는다', () => {
  const NOW = T0;
  const existing = [
    { id: 'a', remindAt: NOW + 5000, sent: false },
    { id: 'b', remindAt: NOW - 5000, sent: true },
  ];
  const same = [
    { id: 'a', remindAt: NOW + 5000 },
    { id: 'b', remindAt: NOW - 5000 },
  ];
  // 그대로 보냄 → 바뀐 것 없음.
  assert.equal(schedulesReminders(planReminders(existing, same, NOW)), false);
  // 지우기만.
  assert.equal(schedulesReminders(planReminders(existing, [same[0]], NOW)), false);
  assert.equal(schedulesReminders(planReminders(existing, [], NOW)), false);
  // 새 알림·시각 변경(보낸 알림을 다시 울리게 하는 것 포함).
  assert.equal(schedulesReminders(planReminders(existing, [{ remindAt: NOW + 9000 }], NOW)), true);
  assert.equal(schedulesReminders(planReminders(existing, [{ id: 'b', remindAt: NOW + 9000 }], NOW)), true);
  // 알림을 안 건드린 수정(계획 없음).
  assert.equal(schedulesReminders(undefined), false);
});
