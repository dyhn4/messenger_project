// 로그인 판단 순서(authGuard.js runLoginAttempt)와 사내망 밖 전체 오류의 차례 받기(LoginSlowdown·RecentLogins) 단위 테스트 —
// `node --test test/*.test.js` (DB·서버 없이 돈다 — 계정 찾기·비밀번호 확인은 가짜를 넘긴다).
//
// 지키려는 것:
//  - 사내망 밖에서 짧은(8자 미만) 비밀번호는 맞든 틀리든 같은 답이고 계정도 찾지 않는다 — 예전엔 맞혔을 때만 다른 안내가 나와서
//    짧은 옛 비밀번호를 밖에서 맞혀 볼 수 있었다. 실패로 세고, 실패 기록은 진짜로 로그인했을 때만 지운다.
//  - 요청을 한꺼번에 보내도 키마다 정한 횟수(같은 IP·아이디 5, 한 IP 20, 밖에서 한 아이디 20)보다 많이 비밀번호를 맞춰 보지
//    못한다 — 예전엔 확인을 기다리는 동안 실패가 안 세어져서, 동시에 100개를 보내면 100개가 다 확인됐다.
//  - 사내망 밖 전체의 오류가 많아도 밖 로그인을 통째로 막지 않는다(예전엔 300번 틀리면 15분 동안 모든 직원이 밖에서 못 들어왔다)
//    — 처음 보는 곳만 줄을 세워 정해진 간격으로 확인하고(동시에 몇 개를 보내든 그 속도를 넘지 못한다), 최근 그곳에서 로그인에
//    성공한 사람과 사내는 줄을 서지 않는다.
//  - 밖의 IPv6는 /64 단위로 센다(주소 끝만 바꿔 가며 IP 제한을 새로 받지 못하게).
import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  FailureLimiter,
  LOGIN_FAILED_ERROR,
  LoginSlowdown,
  OUTSIDE_SHORT_PASSWORD_ERROR,
  RecentLogins,
  limits,
  outsideLoginQueueError,
  runLoginAttempt,
} from '../src/authGuard.js';
import { PASSWORD_MIN_LENGTH } from '../src/passwordPolicy.js';

const SEC = 1000;
const MIN = 60 * SEC;
const OUTSIDE = '203.0.113.7';
const OUTSIDE_2 = '198.51.100.9';
const OUTSIDE_3 = '192.0.2.44';
const LAN = '192.168.0.20';

function clock(start = 1_000_000_000_000) {
  let t = start;
  return { now: () => t, advance: (ms) => (t += ms) };
}

/** 사내망 밖의 서로 다른 IPv4 주소(198.18.0.0/15 — 사내 대역이 아니다) [i]번째. */
const outsideIp = (i) => `198.${18 + (Math.floor(i / 65536) % 2)}.${Math.floor(i / 256) % 256}.${i % 256}`;

/** 이 서버의 제한값(limits)과 같은 숫자로 새로 만든 제한 기록 — 테스트마다 따로, 시계는 [c]. */
function freshGuard(c) {
  const failure = (l) => new FailureLimiter({ max: l.max, windowMs: l.windowMs, blockMs: l.blockMs, now: c.now });
  const s = limits.loginExternalSlowdown;
  return {
    loginIpUser: failure(limits.loginIpUser),
    loginIp: failure(limits.loginIp),
    loginUserExternal: failure(limits.loginUserExternal),
    loginExternalSlowdown: new LoginSlowdown({
      budget: s.budget,
      windowMs: s.windowMs,
      baseIntervalMs: s.baseIntervalMs,
      maxIntervalMs: s.maxIntervalMs,
      maxWaitMs: s.maxWaitMs,
      now: c.now,
    }),
    recentLogins: new RecentLogins({ ttlMs: limits.recentLogins.ttlMs, maxEntries: limits.recentLogins.maxEntries, now: c.now }),
  };
}

/**
 * 가짜 서버 하나 — [accounts]는 아이디 → { id, password, ...상태 }. runLoginAttempt에 넘긴 계정 찾기·비밀번호 확인·기록·기다리기를
 * 세어 둔다(sleeps에 기다린 ms, reports에 운영자에게 남긴 문구). 기본으로는 기다리면 그만큼 시계가 간다(한 번에 하나씩 보낼 때).
 * [timeStands]면 시계를 그대로 둔다 — 한꺼번에 보낸 요청들이 모두 같은 순간에 차례를 받는 모습.
 * [gate]를 주면 비밀번호 확인이 그 약속이 풀릴 때까지 기다린다(확인 중인 요청이 쌓인 모습).
 */
function fakeServer(accounts = {}, { timeStands = false } = {}) {
  const c = clock();
  const guard = freshGuard(c);
  const calls = { findAccount: 0, checkPassword: 0 };
  const sleeps = [];
  const reports = [];
  let gate = null;
  const login = (ip, username, password) =>
    runLoginAttempt({
      ip,
      username,
      password,
      guard,
      findAccount: async (name) => {
        calls.findAccount += 1;
        return accounts[name.trim()] ?? null;
      },
      checkPassword: async (pw, user) => {
        calls.checkPassword += 1;
        if (gate) await gate.promise;
        return !!user && user.password === pw;
      },
      report: (r) => reports.push(r),
      sleep: async (ms) => {
        sleeps.push(ms);
        if (!timeStands) c.advance(ms);
      },
    });
  const hold = () => {
    let open;
    gate = { promise: new Promise((resolve) => (open = resolve)) };
    return () => {
      gate = null;
      open();
    };
  };
  return { c, guard, calls, sleeps, reports, login, hold };
}

/** 마이크로태스크가 다 돌 때까지 — 한꺼번에 보낸 요청들이 비밀번호 확인까지 갈 수 있는 데까지 가게. */
const settle = () => new Promise((resolve) => setImmediate(resolve));

/** 밖 전체의 오류를 [n]번 세어 차례 받기를 켠다(실제 요청 없이). */
function attackUnderway(guard, n = limits.loginExternalSlowdown.budget) {
  for (let i = 0; i < n; i += 1) guard.loginExternalSlowdown.fail();
}

const kim = { id: 'u-kim', username: 'kim', password: 'correct-horse-9' };
const lee = { id: 'u-lee', username: 'lee', password: 'lee-password-77' };
// 최소 길이를 8자로 올리기 전에 정해 둔 짧은 비밀번호를 아직 쓰는 계정.
const old = { id: 'u-old', username: 'oldie', password: 'abc123' };

test('밖에서 짧은 비밀번호는 맞든 틀리든 같은 답 — 계정을 찾지도, 비밀번호를 맞춰 보지도 않는다', async () => {
  const s = fakeServer({ oldie: old });
  assert.ok(old.password.length < PASSWORD_MIN_LENGTH);
  const right = await s.login(OUTSIDE, 'oldie', old.password);
  const wrong = await s.login(OUTSIDE_2, 'oldie', 'abc124');
  const nobody = await s.login(OUTSIDE_2, 'no-such-user', 'abc123');
  for (const r of [right, wrong, nobody]) {
    assert.deepEqual(r, { status: 401, error: OUTSIDE_SHORT_PASSWORD_ERROR });
  }
  assert.deepEqual(s.calls, { findAccount: 0, checkPassword: 0 });
  // 문구는 이 사람의 비밀번호가 짧다고 말하지 않는다 — 어떤 짧은 비밀번호를 넣어도 나오는 안내다.
  assert.match(OUTSIDE_SHORT_PASSWORD_ERROR, /8자 이상인 비밀번호로만/);
  assert.match(OUTSIDE_SHORT_PASSWORD_ERROR, /짧다면 사내 와이파이에서 로그인해 비밀번호를 바꾼/);
});

test('밖에서 짧은 비밀번호도 실패로 센다 — 같은 IP·아이디로 5번이면 막힌다(밖 전체의 오류에는 넣지 않는다)', async () => {
  const s = fakeServer({ oldie: old });
  for (let i = 0; i < 5; i += 1) {
    assert.equal((await s.login(OUTSIDE, 'oldie', old.password)).status, 401, `${i + 1}번째`);
  }
  const blocked = await s.login(OUTSIDE, 'oldie', old.password);
  assert.ok(blocked.wait > 0);
  assert.match(blocked.error, /^로그인 시도가 너무 많습니다\. 15분 후 다시 시도하세요\.$/);
  assert.ok(s.reports.some((r) => /비밀번호 5회 오류/.test(r.detail)));
  // 아무것도 맞춰 보지 못하는 요청이라, 이것만으로는 직원들의 밖 로그인을 줄 세우지 못한다.
  assert.equal(s.guard.loginExternalSlowdown.count(), 0);
  assert.equal(s.guard.loginUserExternal.failures('oldie'), 5);
});

test('사내에서는 짧은 옛 비밀번호로도 그대로 로그인된다', async () => {
  const s = fakeServer({ oldie: old });
  const r = await s.login(LAN, 'oldie', old.password);
  assert.equal(r.user, old);
  assert.equal((await s.login(LAN, 'oldie', 'abc124')).error, LOGIN_FAILED_ERROR);
});

test('실패 기록은 진짜로 로그인했을 때만 지운다 — 정지·탈퇴 계정에 맞는 비밀번호는 성공이 아니다', async () => {
  const suspended = { ...kim, suspendedAt: new Date() };
  const s = fakeServer({ kim: suspended });
  for (let i = 0; i < 4; i += 1) await s.login(OUTSIDE, 'kim', 'wrong-password-1');
  const r = await s.login(OUTSIDE, 'kim', kim.password);
  assert.deepEqual(r, { status: 403, error: '정지된 계정입니다. 서버 운영자에게 문의하세요.' });
  // 기록이 그대로라 한 번 더 틀리면 다섯 번째로 막힌다.
  await s.login(OUTSIDE, 'kim', 'wrong-password-1');
  assert.ok((await s.login(OUTSIDE, 'kim', kim.password)).wait > 0);
  // 정지·탈퇴 계정은 "최근 성공한 곳"도 되지 않는다.
  assert.equal(s.guard.recentLogins.has(`${OUTSIDE}|kim`), false);

  const withdrawn = fakeServer({ kim: { ...kim, deletedAt: new Date() } });
  assert.equal((await withdrawn.login(LAN, 'kim', kim.password)).error, '탈퇴한 계정입니다.');
});

test('성공하면 그 IP·아이디의 실패 기록을 지우고, 밖이면 "최근 성공한 곳"으로 기억한다', async () => {
  const s = fakeServer({ kim });
  for (let i = 0; i < 4; i += 1) await s.login(OUTSIDE, 'kim', 'wrong-password-1');
  assert.equal((await s.login(OUTSIDE, 'kim', kim.password)).user, kim);
  for (let i = 0; i < 4; i += 1) {
    assert.equal((await s.login(OUTSIDE, 'kim', 'wrong-password-1')).status, 401, `다시 ${i + 1}번째`);
  }
  assert.equal(s.guard.recentLogins.has(`${OUTSIDE}|kim`), true);
  // 아이디는 대소문자·앞뒤 공백을 무시한 키로 센다(authGuard.js userKey).
  assert.equal(s.guard.loginIpUser.entries.has(`${OUTSIDE}|kim`), true);
  // 사내 성공은 기억하지 않는다(줄 세우기는 밖에만 걸린다).
  await s.login(LAN, 'kim', kim.password);
  assert.equal(s.guard.recentLogins.has(`${LAN}|kim`), false);
  // 확인이 끝나면 "확인 중"은 모두 놓인다.
  for (const l of [s.guard.loginIpUser, s.guard.loginIp, s.guard.loginUserExternal]) assert.equal(l.pending.size, 0);
});

test('한꺼번에 100개를 보내도 같은 IP·아이디로는 5개만 비밀번호를 맞춰 보고, 그 뒤엔 막힌다', async () => {
  const s = fakeServer({ kim });
  const open = s.hold();
  const pending = Array.from({ length: 100 }, (_, i) => s.login(OUTSIDE, 'kim', `wrong-password-${i}`));
  await settle();
  // 확인이 끝나기 전 — 다섯 개만 확인 중이고 나머지는 이미 429로 돌아갔다.
  assert.equal(s.calls.checkPassword, 5);
  assert.equal(s.guard.loginIpUser.pending.get(`${OUTSIDE}|kim`), 5);
  open();
  const results = await Promise.all(pending);
  assert.equal(s.calls.checkPassword, 5);
  assert.equal(results.filter((r) => r.status === 401).length, 5);
  const refused = results.filter((r) => r.wait > 0);
  assert.equal(refused.length, 95);
  assert.match(refused[0].error, /^로그인 시도가 너무 많습니다\. 5초 후 다시 시도하세요\.$/);
  // 다섯 개가 다 틀렸으니 이제 15분 동안 막혀 있고, 확인 중은 모두 놓였다.
  const after = await s.login(OUTSIDE, 'kim', kim.password);
  assert.ok(after.wait > 14 * MIN, String(after.wait));
  assert.equal(s.guard.loginIpUser.pending.size, 0);
  assert.equal(s.calls.checkPassword, 5);
  assert.equal(s.reports.filter((r) => /비밀번호 5회 오류/.test(r.detail)).length, 1);
});

test('한꺼번에 보내도 한 IP(여러 아이디)는 20개, 밖의 여러 IP에서 한 아이디는 20개까지만 맞춰 본다', async () => {
  const byIp = fakeServer();
  let open = byIp.hold();
  let pending = Array.from({ length: 100 }, (_, i) => byIp.login(OUTSIDE, `user${i}`, 'wrong-password-1'));
  await settle();
  assert.equal(byIp.calls.checkPassword, 20);
  open();
  await Promise.all(pending);
  assert.equal(byIp.calls.checkPassword, 20);
  assert.ok((await byIp.login(OUTSIDE, 'someone-else', 'wrong-password-1')).wait > 29 * MIN);

  const byUser = fakeServer({ kim });
  open = byUser.hold();
  pending = Array.from({ length: 100 }, (_, i) => byUser.login(outsideIp(i), 'kim', 'wrong-password-1'));
  await settle();
  assert.equal(byUser.calls.checkPassword, 20);
  open();
  await Promise.all(pending);
  assert.equal(byUser.calls.checkPassword, 20);
  assert.ok((await byUser.login(outsideIp(500), 'kim', kim.password)).wait > 59 * MIN);
  // 사내에서는 그대로 들어온다(밖에서 한 아이디를 막는 제한은 사내에 걸지 않는다).
  assert.equal((await byUser.login(LAN, 'kim', kim.password)).user, kim);
});

test('확인 중에 오류가 나도(DB 오류 등) "확인 중"을 놓는다 — 그 키가 꽉 찬 채로 남지 않는다', async () => {
  const c = clock();
  const guard = freshGuard(c);
  const broken = () =>
    runLoginAttempt({
      ip: OUTSIDE,
      username: 'kim',
      password: 'wrong-password-1',
      guard,
      findAccount: async () => {
        throw new Error('DB가 응답하지 않습니다');
      },
      checkPassword: async () => false,
      report: () => {},
    });
  for (let i = 0; i < 10; i += 1) await assert.rejects(broken(), /DB가 응답하지 않습니다/);
  for (const l of [guard.loginIpUser, guard.loginIp, guard.loginUserExternal]) assert.equal(l.pending.size, 0);
  assert.equal(guard.loginExternalSlowdown.inFlight, 0);
  // 실패로 세지도 않았다(확인을 못 했으니).
  assert.equal(guard.loginIpUser.failures(`${OUTSIDE}|kim`), 0);
});

test('밖 전체에서 15분에 300번 틀리면 막지 않고 처음 보는 곳만 줄을 세운다(3초에 하나) — 운영자에게 알린다', async () => {
  const s = fakeServer({ kim, lee });
  // 공격 전에 kim은 집(OUTSIDE)에서 로그인한 적이 있다.
  assert.equal((await s.login(OUTSIDE, 'kim', kim.password)).user, kim);
  for (let i = 0; i < 299; i += 1) assert.equal((await s.login(outsideIp(i), `spray${i}`, 'wrong-password-1')).status, 401);
  assert.deepEqual(s.sleeps, []);
  assert.equal(s.reports.length, 0);
  assert.equal((await s.login(outsideIp(299), 'spray299', 'wrong-password-1')).status, 401);
  assert.equal(s.reports.length, 1);
  const { detail } = s.reports[0];
  assert.match(detail, /사내망 밖 전체에서 최근 15분 동안 비밀번호 오류 300회\(기준 300회\)/);
  assert.match(detail, /처음 보는 곳의 로그인은 줄을 세워 3초에 하나씩만 비밀번호를 확인합니다/);
  assert.match(detail, /차례가 15초 넘게 밀리면/);
  assert.match(detail, /사내에서는 그대로 로그인됩니다/);
  assert.match(detail, /150회 아래로 줄면 저절로 풀립니다/);

  // 처음 보는 곳(다른 IP의 lee)은 줄이 비어 있어 바로 들어오고 — 429가 아니다 — 다음 차례는 3초 뒤다.
  assert.equal((await s.login(OUTSIDE_2, 'lee', lee.password)).user, lee);
  assert.deepEqual(s.sleeps, []);
  // 바로 다음의 처음 보는 곳(OUTSIDE_3)은 3초를 기다린 뒤 확인한다.
  assert.equal((await s.login(OUTSIDE_3, 'lee', 'wrong-password-1')).status, 401);
  assert.deepEqual(s.sleeps, [3 * SEC]);
  // 최근 그곳에서 성공한 kim과 사내는 줄을 서지 않는다.
  assert.equal((await s.login(OUTSIDE, 'kim', kim.password)).user, kim);
  assert.equal((await s.login(LAN, 'lee', lee.password)).user, lee);
  assert.deepEqual(s.sleeps, [3 * SEC]);
});

test('줄 세우기: 한꺼번에 몰려도 3초에 하나씩만 확인하고, 15초 넘게 밀리면 언제 다시 할지 알려 준다(한 IP는 한 차례만)', async () => {
  const s = fakeServer({ kim, lee }, { timeStands: true });
  assert.equal((await s.login(OUTSIDE, 'kim', kim.password)).user, kim); // 최근 성공한 곳 하나
  attackUnderway(s.guard);
  const flood = Array.from({ length: 50 }, (_, i) => s.login(outsideIp(i), `spray${i}`, 'wrong-password-1'));
  // 같은 IP의 두 번째 요청은 그 IP가 기다리는 동안 차례를 받지 못한다.
  const sameIpAgain = s.login(outsideIp(1), 'spray-again', 'wrong-password-1');
  // 줄이 꽉 차도 최근 그곳에서 성공한 kim과 사내는 바로 들어온다.
  const kimAgain = s.login(OUTSIDE, 'kim', kim.password);
  const lan = s.login(LAN, 'lee', lee.password);
  const results = await Promise.all(flood);
  // 줄에 선 것은 0·3·6·9·12·15초 뒤의 여섯 차례뿐(첫 차례는 기다리지 않는다).
  assert.deepEqual(s.sleeps, [3, 6, 9, 12, 15].map((n) => n * SEC));
  assert.equal(results.filter((r) => r.status === 401).length, 6);
  const turnedAway = results.filter((r) => r.wait > 0);
  assert.equal(turnedAway.length, 44);
  assert.equal(turnedAway[0].wait, 3 * SEC); // 3초 뒤면 15초 안의 차례가 하나 빈다.
  assert.equal(turnedAway[0].error, outsideLoginQueueError(3 * SEC));
  assert.match(turnedAway[0].error, /로그인 시도가 몰려 차례대로 받고 있습니다\. 3초 후 다시 시도하세요\. 사내 와이파이에서는 바로 로그인됩니다\./);
  const again = await sameIpAgain;
  assert.equal(again.wait, 3 * SEC);
  assert.equal(again.error, outsideLoginQueueError(3 * SEC));
  assert.equal((await kimAgain).user, kim);
  assert.equal((await lan).user, lee);
  // 확인한 비밀번호는 줄에 선 여섯 개와 kim·사내 둘(그리고 처음 kim 한 번)뿐이다.
  assert.equal(s.calls.checkPassword, 6 + 3);
  // 끝난 확인은 "확인 중"에서 모두 빠졌다.
  assert.equal(s.guard.loginExternalSlowdown.inFlight, 0);
});

test('켜지기 직전에 한꺼번에 보내도 — 확인 중인 것까지 세어 300개에 닿는 순간부터 줄을 세운다', async () => {
  const s = fakeServer({}, { timeStands: true });
  const open = s.hold();
  // 오류가 하나도 없는 평소 상태에서 처음 보는 곳 1,000곳이 동시에 보낸다(확인이 끝나기 전이라 아직 오류는 0번).
  const burst = Array.from({ length: 1000 }, (_, i) => s.login(outsideIp(i), `burst${i}`, 'wrong-password-1'));
  await settle();
  // 300개가 확인 중이 되는 순간 줄이 켜져, 그 뒤로는 바로 하나·3~15초 뒤 다섯 개만 차례를 받았다.
  assert.equal(s.guard.loginExternalSlowdown.inFlight, 300 + 6);
  assert.equal(s.calls.checkPassword, 300 + 6);
  open();
  const results = await Promise.all(burst);
  assert.equal(results.filter((r) => r.status === 401).length, 306);
  assert.equal(results.filter((r) => r.wait > 0).length, 694);
  assert.equal(s.guard.loginExternalSlowdown.inFlight, 0);
  assert.equal(s.guard.loginExternalSlowdown.count(), 306);
  // 운영자에게는 확인 중인 것까지 기준에 닿았을 때 한 번 알렸다.
  const raised = s.reports.filter((r) => /사내망 밖 전체에서/.test(r.detail));
  assert.equal(raised.length, 1);
  assert.match(raised[0].detail, /비밀번호 오류 1회와 확인 중인 시도 305개\(기준 300회\)/);
});

test('줄 세우기는 처리량을 묶는다 — 15분 동안 매초 50개씩(4만 5천 개) 보내도 확인은 300개 남짓이고, 그래도 차례는 계속 돈다', async () => {
  const s = fakeServer({}, { timeStands: true });
  attackUnderway(s.guard);
  let sent = 0;
  for (let second = 0; second < 15 * 60; second += 1) {
    await Promise.all(Array.from({ length: 50 }, () => s.login(outsideIp(sent++), `spray${sent}`, 'wrong-password-1')));
    s.c.advance(SEC);
  }
  assert.equal(sent, 45_000);
  // 3초에 하나(15분에 300개)와 처음 줄을 채운 여섯 개 — 그사이 오류가 늘어 간격이 6초로 늘면 그보다 적다.
  assert.ok(s.calls.checkPassword <= 15 * 60 / 3 + 6, String(s.calls.checkPassword));
  // 통째로 막는 게 아니라 차례가 계속 돈다(이 동안 처음 보는 곳의 직원도 줄을 서면 들어올 수 있다).
  assert.ok(s.calls.checkPassword >= 100, String(s.calls.checkPassword));
});

test('기다리는 사이 같은 곳이 막혔으면 기다린 뒤에도 들여보내지 않는다', async () => {
  const s = fakeServer({ kim });
  attackUnderway(s.guard);
  const ahead = s.guard.loginExternalSlowdown.take('someone-ahead'); // 앞 차례 하나 — 이 로그인은 3초를 기다린다.
  let blockDuringSleep = null;
  const r = await runLoginAttempt({
    ip: OUTSIDE,
    username: 'kim',
    password: kim.password,
    guard: s.guard,
    findAccount: async () => kim,
    checkPassword: async () => true,
    report: () => {},
    sleep: async () => {
      // 한꺼번에 보낸 다른 요청들이 그사이 이 IP·아이디로 다섯 번 틀렸다.
      for (let i = 0; i < 5; i += 1) s.guard.loginIpUser.fail(`${OUTSIDE}|kim`);
      blockDuringSleep = s.guard.loginIpUser.blockedFor(`${OUTSIDE}|kim`);
    },
  });
  assert.ok(blockDuringSleep > 0);
  assert.ok(r.wait > 0);
  assert.equal(r.user, undefined);
  // 들어가지 못한 차례도 "확인 중"에서 빠졌다(남은 것은 앞 차례 하나).
  assert.equal(s.guard.loginExternalSlowdown.inFlight, 1);
  ahead.finished();
  assert.equal(s.guard.loginExternalSlowdown.inFlight, 0);
});

test('밖의 IPv6는 /64 단위로 센다 — 주소 끝만 바꿔도 같은 IP로 막힌다(사내 IPv6는 주소 그대로)', async () => {
  const s = fakeServer();
  for (let i = 1; i <= 20; i += 1) {
    assert.equal((await s.login(`2001:db8:1:2::${i.toString(16)}`, `v6user${i}`, 'wrong-password-1')).status, 401);
  }
  assert.ok((await s.login('2001:db8:1:2:aaaa:bbbb:cccc:dddd', 'someone', 'whatever-123')).wait > 0);
  assert.ok(s.reports.some((r) => /한 IP에서 여러 아이디로 비밀번호 20회 오류/.test(r.detail)));
  // 옆 /64는 다른 곳이다.
  assert.equal((await s.login('2001:db8:1:3::1', 'someone', 'whatever-123')).status, 401);

  const lan = fakeServer();
  for (let i = 1; i <= 20; i += 1) await lan.login(`fd00::${i.toString(16)}`, `lanuser${i}`, 'wrong-password-1');
  assert.equal((await lan.login('fd00::99', 'someone', 'whatever-123')).status, 401);
});

test('LoginSlowdown: 오류가 기준의 2배·4배·8배면 간격을 3→6→12→24초로 늘리고(24초까지), 오류가 사라지면 끈다', () => {
  const c = clock();
  const p = limits.loginExternalSlowdown;
  const slow = new LoginSlowdown({
    budget: p.budget,
    windowMs: p.windowMs,
    baseIntervalMs: p.baseIntervalMs,
    maxIntervalMs: p.maxIntervalMs,
    maxWaitMs: p.maxWaitMs,
    now: c.now,
  });
  const raised = [];
  const failMany = (n) => {
    for (let i = 0; i < n; i += 1) {
      const r = slow.fail();
      if (r) raised.push(r);
    }
  };
  failMany(299);
  assert.equal(slow.intervalMs(), 0);
  failMany(1);
  assert.equal(slow.intervalMs(), 3 * SEC);
  failMany(300); // 600 — 2배
  assert.equal(slow.intervalMs(), 6 * SEC);
  failMany(600); // 1,200 — 4배
  assert.equal(slow.intervalMs(), 12 * SEC);
  failMany(1200); // 2,400 — 8배
  assert.equal(slow.intervalMs(), 24 * SEC);
  failMany(2400); // 4,800 — 16배라도 24초까지만
  assert.equal(slow.intervalMs(), 24 * SEC);
  // 단계마다 한 번씩만 알렸고, 간격이 더 늘지 않는 단계(24초 뒤)는 다시 알리지 않는다.
  assert.deepEqual(
    raised.map((r) => [r.level, r.intervalMs]),
    [
      [1, 3 * SEC],
      [2, 6 * SEC],
      [3, 12 * SEC],
      [4, 24 * SEC],
    ],
  );
  // 15분이 지나 오류가 사라지면 풀린다 — 다시 줄 없이 바로 확인한다.
  c.advance(15 * MIN);
  assert.equal(slow.count(), 0);
  assert.equal(slow.intervalMs(), 0);
  assert.equal(slow.take('anyone').waitMs, 0);
  assert.equal(slow.take('anyone').waitMs, 0);
});

test('LoginSlowdown: 기준(300)을 넘었다 조금 줄어도(150 이상) 계속 줄을 세운다 — 기준선에서 켜졌다 꺼졌다 하지 않게', () => {
  const c = clock();
  const slow = new LoginSlowdown({ budget: 10, windowMs: 15 * MIN, baseIntervalMs: 3 * SEC, maxIntervalMs: 24 * SEC, maxWaitMs: 15 * SEC, now: c.now });
  for (let i = 0; i < 4; i += 1) slow.fail(); // 처음 1분 칸에 4
  c.advance(5 * MIN);
  for (let i = 0; i < 6; i += 1) slow.fail(); // 5분 뒤 칸에 6 — 합 10, 켜진다
  assert.equal(slow.intervalMs(), 3 * SEC);
  c.advance(10 * MIN + 1); // 처음 칸이 빠져 6 — 기준(10) 아래지만 절반(5) 이상이라 그대로
  assert.equal(slow.count(), 6);
  assert.equal(slow.intervalMs(), 3 * SEC);
  c.advance(5 * MIN); // 다 빠져 0 — 끈다
  assert.equal(slow.intervalMs(), 0);
  // 다시 켜지면 다시 알린다.
  let report = null;
  for (let i = 0; i < 10; i += 1) report = slow.fail() ?? report;
  assert.equal(report?.level, 1);
  assert.ok(slow.buckets.length <= 16);
});

test('LoginSlowdown.take: 차례 간격·줄 길이·한 IP 한 차례(차례 시각이 지나면 다시), 확인 중인 수', () => {
  const c = clock();
  const slow = new LoginSlowdown({ budget: 100, windowMs: 15 * MIN, baseIntervalMs: 3 * SEC, maxIntervalMs: 24 * SEC, maxWaitMs: 15 * SEC, now: c.now });
  const idle = slow.take('a'); // 평소(오류 없음)엔 줄이 없다 — 그래도 확인 중으로는 센다
  assert.equal(idle.waitMs, 0);
  assert.equal(slow.inFlight, 1);
  idle.finished();
  idle.finished(); // 여러 번 불러도 한 번만 뺀다
  assert.equal(slow.inFlight, 0);
  for (let i = 0; i < 100; i += 1) slow.fail();
  const first = slow.take('a');
  assert.equal(first.waitMs, 0); // 줄이 비어 있으면 바로 — 기다리지 않으니 이 IP를 잡아 두지도 않는다
  assert.equal(slow.waiting.size, 0);
  const second = slow.take('a');
  assert.equal(second.waitMs, 3 * SEC);
  assert.deepEqual(slow.take('a'), { retryMs: 3 * SEC }); // 이 IP는 이미 차례를 기다리는 중
  for (const [ip, wait] of [['b', 6], ['c', 9], ['d', 12], ['e', 15]]) assert.equal(slow.take(ip).waitMs, wait * SEC, ip);
  assert.deepEqual(slow.take('f'), { retryMs: 3 * SEC }); // 15초를 넘는 차례는 주지 않는다
  assert.equal(slow.inFlight, 6); // 차례를 받은 여섯(못 받은 것은 세지 않는다)
  c.advance(3 * SEC);
  // a의 차례 시각이 됐다 — 이제 a도 다시 줄을 설 수 있다(맨 뒤).
  assert.equal(slow.take('a').waitMs, 15 * SEC);
  // 차례 시각이 지난 기다림은 정리된다.
  c.advance(60 * SEC);
  slow.prune();
  assert.equal(slow.waiting.size, 0);
});

test('LoginSlowdown: 확인 중인 것도 켜는 수에 들어가고, 다 성공해 빠지면 다시 끈다', () => {
  const c = clock();
  const slow = new LoginSlowdown({ budget: 4, windowMs: 15 * MIN, baseIntervalMs: 3 * SEC, maxIntervalMs: 24 * SEC, maxWaitMs: 15 * SEC, now: c.now });
  const turns = [slow.take('a'), slow.take('b'), slow.take('c'), slow.take('d')];
  assert.ok(turns.every((t) => t.waitMs === 0));
  assert.equal(slow.pressure(), 4);
  const e = slow.take('e');
  assert.equal(e.waitMs, 0); // 켜졌다 — 줄이 비어 있어 바로지만, 다음 차례는 3초 뒤
  const f = slow.take('f');
  assert.equal(f.waitMs, 3 * SEC);
  // 모두 성공으로 끝나(실패로 세지 않았으니) 확인 중이 절반(2) 아래로 줄면 다시 끈다.
  for (const t of turns) t.finished();
  assert.equal(slow.inFlight, 2);
  assert.equal(slow.intervalMs(), 3 * SEC);
  e.finished();
  assert.equal(slow.intervalMs(), 0);
  f.finished();
  assert.equal(slow.inFlight, 0);
});

test('RecentLogins: 30일이 지나면 잊고, 너무 많으면 가장 오래된 곳부터 잊는다', () => {
  const c = clock();
  const recent = new RecentLogins({ ttlMs: 30 * 24 * 60 * MIN, maxEntries: 2, now: c.now });
  recent.remember('a');
  c.advance(MIN);
  recent.remember('b');
  recent.remember('a'); // 다시 성공하면 맨 뒤로
  recent.remember('c'); // 셋째 — 가장 오래된 b를 잊는다
  assert.equal(recent.has('b'), false);
  assert.equal(recent.has('a'), true);
  assert.equal(recent.has('c'), true);
  c.advance(30 * 24 * 60 * MIN + 1);
  recent.prune();
  assert.equal(recent.entries.size, 0);
  assert.equal(recent.has('a'), false);
});

test('이 서버의 값: 밖 전체 300번/15분부터 3초에 하나(최대 24초), 15초까지 줄, 성공한 곳은 30일 — 예전의 통째 차단은 없다', () => {
  const p = limits.loginExternalSlowdown;
  assert.deepEqual(
    { budget: p.budget, windowMs: p.windowMs, baseIntervalMs: p.baseIntervalMs, maxIntervalMs: p.maxIntervalMs, maxWaitMs: p.maxWaitMs },
    { budget: 300, windowMs: 15 * MIN, baseIntervalMs: 3 * SEC, maxIntervalMs: 24 * SEC, maxWaitMs: 15 * SEC },
  );
  // 3초에 하나면 15분에 300번 — 예전 통째 차단(15분에 300번)과 같은 상한이다.
  assert.equal(p.windowMs / p.baseIntervalMs, p.budget);
  assert.equal(limits.recentLogins.ttlMs, 30 * 24 * 60 * MIN);
  assert.equal('loginExternalGlobal' in limits, false);
  for (const l of Object.values(limits)) assert.equal(typeof l.prune, 'function');
});
