// 웹 인증서 발급·갱신 일정(acmeRenewal.js) 테스트 — `node --test test/*.test.js`. 가짜 시계·타이머·발급 함수로 규칙만 본다
// (Let's Encrypt·네트워크·DB 없음). 인증서 파일 저장소는 임시 폴더를 쓰는 진짜 것과 메모리 가짜 둘 다 쓴다.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { before, test } from 'node:test';
import selfsigned from 'selfsigned';
import {
  ATTEMPT_GUARD_MS,
  BACKOFF_MAX_MS,
  BACKOFF_MIN_MS,
  CHECK_INTERVAL_MS,
  CLOCK_RETRY_MS,
  CLOCK_SKEW_TOLERANCE_MS,
  MAX_RETRY_AFTER_MS,
  backoffDelay,
  createCertificateRenewer,
  createCertificateStore,
  inspectCertificate,
  isStagingIssuer,
  renewWindowMs,
} from '../src/acmeRenewal.js';

const DOMAIN = 'xxx.iptime.org';
const HOUR = 60 * 60 * 1000;
const DAY = 24 * HOUR;
const T0 = Math.floor(Date.now() / 1000) * 1000;

async function makeCert({ domain = DOMAIN, notBefore = T0 - HOUR, notAfter, commonName = domain } = {}) {
  const pems = await selfsigned.generate([{ name: 'commonName', value: commonName }], {
    keyType: 'ec',
    algorithm: 'sha256',
    notBeforeDate: new Date(notBefore),
    notAfterDate: new Date(notAfter),
    extensions: [{ name: 'subjectAltName', altNames: [{ type: 2, value: domain }] }],
  });
  return { certPem: pems.cert, keyPem: pems.private };
}

const certs = {};
before(async () => {
  certs.fresh = await makeCert({ notAfter: T0 + 90 * DAY });
  certs.renewed = await makeCert({ notAfter: T0 + 200 * DAY });
  certs.renewedLater = await makeCert({ notAfter: T0 + 300 * DAY });
  certs.dueSoon = await makeCert({ notAfter: T0 + 20 * DAY, notBefore: T0 - 70 * DAY });
  certs.expired = await makeCert({ notBefore: T0 - 100 * DAY, notAfter: T0 - DAY });
  certs.otherDomain = await makeCert({ domain: 'other.example.com', notAfter: T0 + 90 * DAY });
  certs.staging = await makeCert({ commonName: '(STAGING) Pretend Pear X1', notAfter: T0 + 90 * DAY });
});

/** 가짜 시계 — setTimer로 건 일을 advance()가 시각 순서대로 실행한다. */
function fakeClock(start = T0) {
  let now = start;
  let nextId = 1;
  const timers = new Map();
  const flush = async () => {
    for (let i = 0; i < 5; i += 1) await new Promise((resolve) => setImmediate(resolve));
  };
  return {
    now: () => now,
    setTimer: (fn, ms) => {
      const id = nextId++;
      timers.set(id, { at: now + Math.max(0, ms), fn });
      return { id, unref() {} };
    },
    clearTimer: (handle) => {
      if (handle) timers.delete(handle.id);
    },
    flush,
    async advance(ms) {
      const target = now + ms;
      for (;;) {
        const due = [...timers.entries()].filter(([, t]) => t.at <= target).sort((a, b) => a[1].at - b[1].at)[0];
        if (!due) break;
        timers.delete(due[0]);
        now = Math.max(now, due[1].at);
        due[1].fn();
        await flush();
      }
      now = target;
      await flush();
    },
    /** 벽시계만 바꾼다(관리자가 시계를 고침) — 이미 건 타이머는 남은 시간 그대로 흐른다(setTimeout은 벽시계와 상관없다). */
    async jump(delta) {
      now += delta;
      for (const t of timers.values()) t.at += delta;
      await flush();
    },
    pendingDelays: () => [...timers.values()].map((t) => t.at - now).sort((a, b) => a - b),
  };
}

function memoryStore({ cert = null, state = null } = {}) {
  const data = { cert, state };
  const writes = [];
  return {
    certFile: 'certs/web.crt',
    keyFile: 'certs/web.key',
    stateFile: 'certs/acme-state.json',
    data,
    writes,
    failWrites: false,
    readCertificate() {
      return data.cert;
    },
    writeCertificate(c) {
      if (this.failWrites) throw new Error('EACCES');
      data.cert = c;
    },
    readState() {
      return data.state ? JSON.parse(JSON.stringify(data.state)) : null;
    },
    writeState(s) {
      if (this.failWrites) throw new Error('EACCES');
      data.state = JSON.parse(JSON.stringify(s));
      writes.push(data.state);
    },
  };
}

const quietLog = { log() {}, warn() {}, error() {} };

/** 발급 함수 흉내 — 부를 때마다 calls에 남기고 results 차례대로(Error면 던짐, 'hang'이면 끝나지 않음). */
function fakeIssuer(results) {
  const calls = [];
  const queue = [...results];
  const issue = async (opts) => {
    calls.push(opts);
    const next = queue.length > 1 ? queue.shift() : queue[0];
    if (next === 'hang') return new Promise(() => {});
    if (next instanceof Error) throw next;
    return typeof next === 'function' ? next() : next;
  };
  return { issue, calls };
}

const challengeFailure = () => Object.assign(new Error('[http-01] Let\'s Encrypt가 접속하지 못했습니다'), { kind: 'challenge', detail: 'Timeout during connect' });
const rateLimited = (retryAfterMs) => Object.assign(new Error('Let\'s Encrypt 발급 한도에 걸렸습니다(rateLimited).'), { kind: 'rateLimited', retryAfterMs });

function makeRenewer({ clock, store, issuer, staging = false, domain = DOMAIN, types = () => ['tls-alpn-01', 'http-01'], ...rest }) {
  const applied = [];
  const renewer = createCertificateRenewer({
    domain,
    staging,
    store,
    issue: issuer.issue,
    getChallengeTypes: types,
    onCertificate: (cert) => applied.push(cert),
    now: clock.now,
    setTimer: clock.setTimer,
    clearTimer: clock.clearTimer,
    log: quietLog,
    ...rest,
  });
  return { renewer, applied };
}

test('백오프는 1시간에서 두 배씩, 24시간에서 멈춘다', () => {
  assert.deepEqual([1, 2, 3, 4, 5, 6, 7, 30].map(backoffDelay), [1, 2, 4, 8, 16, 24, 24, 24].map((h) => h * HOUR));
  assert.equal(backoffDelay(0), HOUR, '0이나 이상한 값도 최소 1시간');
});

test('갱신 시작: 90일짜리는 만료 30일 전, 짧은 인증서는 수명의 1/3 전(발급 직후 갱신을 되풀이하지 않게)', () => {
  assert.equal(renewWindowMs({ notBefore: 0, notAfter: 90 * DAY }), 30 * DAY);
  assert.equal(renewWindowMs({ notBefore: 0, notAfter: 45 * DAY }), 15 * DAY);
  assert.equal(renewWindowMs({ notBefore: 0, notAfter: 6 * DAY }), 2 * DAY);
});

test('시험용(staging) 발급자 이름을 알아본다', () => {
  assert.equal(isStagingIssuer('C=US\nO=(STAGING) Let\'s Encrypt\nCN=(STAGING) Counterfeit Cashew R10'), true);
  assert.equal(isStagingIssuer('CN=Fake LE Intermediate X1'), true);
  assert.equal(isStagingIssuer('C=US\nO=Let\'s Encrypt\nCN=R11'), false);
});

test('inspectCertificate: 도메인·키 짝·형식을 확인하고 날짜를 돌려준다', () => {
  const ok = inspectCertificate(certs.fresh, { domain: DOMAIN });
  assert.equal(ok.ok, true);
  assert.ok(Math.abs(ok.notAfter - (T0 + 90 * DAY)) < 2000);
  assert.equal(ok.staging, false);
  assert.equal(inspectCertificate(certs.otherDomain, { domain: DOMAIN }).reason, 'domain');
  assert.equal(inspectCertificate({ certPem: certs.fresh.certPem, keyPem: certs.renewed.keyPem }, { domain: DOMAIN }).reason, 'key');
  assert.equal(inspectCertificate({ certPem: 'garbage', keyPem: 'x' }, { domain: DOMAIN }).reason, 'parse');
  assert.equal(inspectCertificate(certs.staging, { domain: DOMAIN }).staging, true);
});

test('인증서가 없으면 시작하자마자 받고, 받은 인증서를 저장·적용한 뒤 상태가 valid가 된다', async () => {
  const clock = fakeClock();
  const store = memoryStore();
  const issuer = fakeIssuer([{ ...certs.fresh, challengeType: 'tls-alpn-01' }]);
  const { renewer, applied } = makeRenewer({ clock, store, issuer });
  assert.equal(renewer.status().status, 'pending');
  renewer.start();
  await clock.flush();
  assert.equal(issuer.calls.length, 1);
  assert.deepEqual(issuer.calls[0].challengeTypes, ['tls-alpn-01', 'http-01']);
  assert.equal(applied.length, 1);
  assert.equal(store.data.cert.certPem, certs.fresh.certPem);
  assert.equal(store.data.state.nextAttemptAt, null);
  assert.equal(store.data.state.preferredChallenge, 'tls-alpn-01');
  const status = renewer.status();
  assert.equal(status.status, 'valid');
  assert.equal(status.lastError, null);
  assert.ok(Math.abs(status.expiresAt - (T0 + 90 * DAY)) < 2000);
  assert.ok(Math.abs(status.nextAttemptAt - (T0 + 60 * DAY)) < 2000, '갱신은 만료 30일 전부터');
  assert.equal(renewer.hasPublicCertificate(), true);
  assert.deepEqual(clock.pendingDelays(), [CHECK_INTERVAL_MS], '12시간마다 확인');
  renewer.stop();
});

test('유효한 인증서가 있으면 12시간마다 확인만 하다가, 만료 30일 전이 되면 갱신한다(지난번 성공한 방식을 먼저)', async () => {
  const clock = fakeClock();
  const store = memoryStore({ cert: certs.fresh, state: { domain: DOMAIN, staging: false, failures: 0, preferredChallenge: 'http-01' } });
  const issuer = fakeIssuer([{ ...certs.renewed, challengeType: 'http-01' }]);
  const { renewer, applied } = makeRenewer({ clock, store, issuer });
  assert.ok(renewer.current, '저장된 인증서를 바로 쓴다');
  renewer.start();
  await clock.flush();
  assert.equal(issuer.calls.length, 0);
  await clock.advance(59 * DAY);
  assert.equal(issuer.calls.length, 0, '아직 갱신 전');
  assert.equal(renewer.status().status, 'valid');
  await clock.advance(DAY + HOUR);
  assert.equal(issuer.calls.length, 1, '만료 30일 전이 지나 갱신');
  assert.deepEqual(issuer.calls[0].challengeTypes, ['http-01', 'tls-alpn-01']);
  assert.equal(applied.at(-1).certPem, certs.renewed.certPem);
  assert.equal(renewer.status().status, 'valid');
  renewer.stop();
});

test('실패하면 1h → 2h → 4h … 24h 간격으로만 다시 시도하고, 시도할 때마다 다음 시각을 남긴다', async () => {
  const clock = fakeClock();
  const store = memoryStore();
  const issuer = fakeIssuer([challengeFailure()]);
  const { renewer } = makeRenewer({ clock, store, issuer });
  renewer.start();
  await clock.flush();
  const attemptTimes = [clock.now()];
  let last = issuer.calls.length;
  for (let i = 0; i < 4 * 24; i += 1) {
    await clock.advance(HOUR);
    if (issuer.calls.length !== last) {
      attemptTimes.push(clock.now());
      last = issuer.calls.length;
    }
  }
  const gaps = attemptTimes.slice(1).map((t, i) => Math.round((t - attemptTimes[i]) / HOUR));
  assert.deepEqual(gaps.slice(0, 7), [1, 2, 4, 8, 16, 24, 24]);
  const status = renewer.status();
  assert.equal(status.status, 'error');
  assert.match(status.lastError, /http-01/);
  assert.equal(store.data.state.failures, issuer.calls.length);
  assert.equal(store.data.state.nextAttemptAt, status.nextAttemptAt);
  renewer.stop();
});

test('rateLimited: Retry-After(3일)까지는 절대 다시 묻지 않고, 없으면 하루, 아주 짧아도 백오프(1시간)는 지킨다', async () => {
  for (const [retryAfterMs, expectedGap] of [
    [3 * DAY, 3 * DAY],
    [null, DAY],
    [10 * 1000, HOUR],
    [400 * DAY, 8 * DAY], // 터무니없이 긴 값은 8일로 자른다
  ]) {
    const clock = fakeClock();
    const store = memoryStore();
    const issuer = fakeIssuer([rateLimited(retryAfterMs), challengeFailure()]);
    const { renewer } = makeRenewer({ clock, store, issuer });
    renewer.start();
    await clock.flush();
    assert.equal(issuer.calls.length, 1);
    const status = renewer.status();
    assert.equal(status.nextAttemptAt - T0, expectedGap, `Retry-After ${retryAfterMs}`);
    assert.equal(store.data.state.nextAttemptAt - T0, expectedGap, '파일에도 남는다');
    assert.equal(store.data.state.lastErrorKind, 'rateLimited');
    await clock.advance(expectedGap - 1000);
    assert.equal(issuer.calls.length, 1, '그 전에는 묻지 않는다');
    await clock.advance(2000);
    assert.equal(issuer.calls.length, 2, '시각이 되면 묻는다');
    renewer.stop();
  }
});

test('재시작해도 저장된 다음 시도 시각 전에는 묻지 않는다 — 발급 도중에 죽어도(먼저 적어 둔 시각) 마찬가지', async () => {
  // 1) 실패 후 재시작
  const store = memoryStore();
  const clock = fakeClock();
  const first = makeRenewer({ clock, store, issuer: fakeIssuer([rateLimited(2 * DAY)]) });
  first.renewer.start();
  await clock.flush();
  first.renewer.stop();
  const issuer = fakeIssuer([{ ...certs.fresh, challengeType: 'http-01' }]);
  const second = makeRenewer({ clock, store, issuer });
  second.renewer.start();
  await clock.flush();
  assert.equal(issuer.calls.length, 0, '재시작해도 바로 묻지 않는다');
  assert.equal(second.renewer.status().nextAttemptAt, T0 + 2 * DAY);
  await clock.advance(2 * DAY);
  assert.equal(issuer.calls.length, 1);
  assert.equal(second.renewer.status().status, 'valid');
  second.renewer.stop();

  // 2) 발급 도중 죽음 — 발급 함수가 끝나지 않는 사이에 같은 파일로 새로 시작해 본다.
  const store2 = memoryStore();
  const clock2 = fakeClock();
  const hung = makeRenewer({ clock: clock2, store: store2, issuer: fakeIssuer(['hang']) });
  hung.renewer.start();
  await clock2.flush();
  assert.equal(store2.data.state.nextAttemptAt, T0 + HOUR, '시도 전에 "실패하면 1시간 뒤"를 먼저 적었다');
  assert.equal(store2.data.state.lastAttemptAt, T0);
  hung.renewer.stop();
  const restarted = fakeIssuer([{ ...certs.fresh }]);
  const after = makeRenewer({ clock: clock2, store: store2, issuer: restarted });
  after.renewer.start();
  await clock2.flush();
  assert.equal(restarted.calls.length, 0, '재시작 직후 또 묻지 않는다');
  await clock2.advance(HOUR);
  assert.equal(restarted.calls.length, 1);
  after.renewer.stop();
});

test('도메인이나 staging 설정이 바뀌면 예전 대기 시각은 버리고 바로 시도한다', async () => {
  const clock = fakeClock();
  const store = memoryStore({ state: { domain: 'old.iptime.org', staging: false, failures: 5, nextAttemptAt: T0 + 5 * DAY } });
  const issuer = fakeIssuer([{ ...certs.fresh }]);
  const { renewer } = makeRenewer({ clock, store, issuer });
  renewer.start();
  await clock.flush();
  assert.equal(issuer.calls.length, 1);
  assert.equal(store.data.state.domain, DOMAIN);
  renewer.stop();

  const stagingStore = memoryStore({ state: { domain: DOMAIN, staging: true, failures: 3, nextAttemptAt: T0 + DAY } });
  const issuer2 = fakeIssuer([{ ...certs.fresh }]);
  const r2 = makeRenewer({ clock, store: stagingStore, issuer: issuer2 });
  r2.renewer.start();
  await clock.flush();
  assert.equal(issuer2.calls.length, 1, 'staging → 정식으로 바꾸면 바로');
  r2.renewer.stop();
});

test('저장된 인증서: 다른 도메인·만료·시험용(정식 설정일 때)은 쓰지 않고 새로 받는다, 시험용 설정이면 시험용도 쓴다', async () => {
  for (const cert of [certs.otherDomain, certs.expired, certs.staging]) {
    const clock = fakeClock();
    const issuer = fakeIssuer([{ ...certs.fresh }]);
    const { renewer } = makeRenewer({ clock, store: memoryStore({ cert }), issuer });
    assert.equal(renewer.current, null);
    renewer.start();
    await clock.flush();
    assert.equal(issuer.calls.length, 1);
    renewer.stop();
  }
  const clock = fakeClock();
  const issuer = fakeIssuer([{ ...certs.fresh }]);
  const { renewer } = makeRenewer({ clock, store: memoryStore({ cert: certs.staging }), issuer, staging: true });
  assert.ok(renewer.current);
  assert.equal(renewer.hasPublicCertificate(), false, '시험용은 공개 주소로 알리지 않는다');
  renewer.start();
  await clock.flush();
  assert.equal(issuer.calls.length, 0);
  assert.equal(renewer.status().certificateStaging, true);
  renewer.stop();
});

test('상태 변화: pending → error(실패) → valid(성공) → expiring(만료 30일 전, 갱신 실패 중) → error(만료)', async () => {
  const clock = fakeClock();
  const store = memoryStore();
  const issuer = fakeIssuer([challengeFailure(), { ...certs.fresh }, challengeFailure()]);
  const { renewer } = makeRenewer({ clock, store, issuer });
  assert.equal(renewer.status().status, 'pending');
  renewer.start();
  await clock.flush();
  assert.equal(renewer.status().status, 'error');
  await clock.advance(HOUR);
  assert.equal(issuer.calls.length, 2);
  let status = renewer.status();
  assert.equal(status.status, 'valid');
  assert.equal(status.lastError, null);
  // 만료 29일 전 — 갱신을 시도하지만 실패하는 중(인증서는 아직 유효)
  await clock.advance(61 * DAY);
  status = renewer.status();
  assert.equal(status.status, 'expiring');
  assert.match(status.lastError, /http-01/);
  assert.ok(issuer.calls.length >= 3);
  await clock.advance(30 * DAY);
  status = renewer.status();
  assert.equal(status.status, 'error', '만료됐고 갱신도 실패 중');
  assert.match(status.lastError, /http-01/);
  assert.equal(renewer.current, null);
  assert.equal(renewer.hasPublicCertificate(), false);
  renewer.stop();
});

test('인증 방식으로 쓸 포트가 없으면 묻지 않고 이유를 보여 주다가, poke()로 포트가 열린 걸 알리면 바로 시도한다', async () => {
  const clock = fakeClock();
  const store = memoryStore();
  const issuer = fakeIssuer([{ ...certs.fresh }]);
  let types = [];
  const { renewer } = makeRenewer({ clock, store, issuer, types: () => types, getWaitingReason: () => '포트 443을 열지 못했습니다.' });
  renewer.start();
  await clock.flush();
  assert.equal(issuer.calls.length, 0);
  assert.equal(renewer.status().lastError, '포트 443을 열지 못했습니다.');
  assert.equal(store.data.state, null, '묻지 않았으니 기록도 없다');
  types = ['http-01'];
  renewer.poke();
  await clock.flush();
  assert.equal(issuer.calls.length, 1);
  assert.deepEqual(issuer.calls[0].challengeTypes, ['http-01']);
  renewer.stop();
});

test('시도 기록을 남길 수 없으면(certs 폴더 권한 등) Let\'s Encrypt에 묻지 않는다 — 재시작마다 발급받아 한도를 태우지 않게', async () => {
  const clock = fakeClock();
  const store = memoryStore();
  store.failWrites = true;
  const issuer = fakeIssuer([{ ...certs.fresh }]);
  const { renewer } = makeRenewer({ clock, store, issuer });
  renewer.start();
  await clock.flush();
  assert.equal(issuer.calls.length, 0);
  assert.match(renewer.status().lastError, /기록을 남길 수 없어/);
  assert.ok(clock.pendingDelays()[0] >= HOUR - 1000, '촘촘히 다시 돌지 않는다');
  renewer.stop();
});

test('발급이 30분 넘게 안 끝나면 실패로 치고 다음 시도를 잡되, 늦게라도 도착한 인증서는 버리지 않는다', async () => {
  const clock = fakeClock();
  const store = memoryStore();
  let finish;
  const issuer = fakeIssuer([() => new Promise((resolve) => (finish = resolve))]);
  const { renewer, applied } = makeRenewer({ clock, store, issuer });
  renewer.start();
  await clock.flush();
  assert.equal(renewer.status().attempting, true);
  await clock.advance(ATTEMPT_GUARD_MS);
  let status = renewer.status();
  assert.equal(status.attempting, false);
  assert.equal(status.status, 'error');
  assert.match(status.lastError, /30분/);
  assert.equal(status.nextAttemptAt, clock.now() - ATTEMPT_GUARD_MS + HOUR);
  finish({ ...certs.fresh });
  await clock.flush();
  status = renewer.status();
  assert.equal(status.status, 'valid', '늦게 온 인증서를 썼다');
  assert.equal(applied.length, 1);
  renewer.stop();
});

test('인증서를 받았는데 파일로 못 남기면 이번 실행에서는 쓰되, 재시작 직후 다시 받지 않게 하루를 띄운다', async () => {
  const clock = fakeClock();
  const store = memoryStore();
  const issuer = fakeIssuer([{ ...certs.fresh }]);
  const { renewer, applied } = makeRenewer({ clock, store, issuer });
  const realWrite = store.writeCertificate;
  store.writeCertificate = () => {
    throw new Error('EPERM');
  };
  renewer.start();
  await clock.flush();
  assert.equal(applied.length, 1);
  assert.equal(store.data.state.nextAttemptAt, T0 + BACKOFF_MAX_MS);
  assert.match(renewer.status().lastError, /저장하지 못했습니다/);
  store.writeCertificate = realWrite;
  renewer.stop();
});

test('받은 인증서가 이 PC 시계로 이미 만료면(시계가 틀림) 쓰지 않고 이유를 알린 뒤 이틀을 기다린다 — 백오프(1시간~)마다 받아 버리지 않는다', async () => {
  const clock = fakeClock();
  const store = memoryStore();
  const issuer = fakeIssuer([{ ...certs.expired }]);
  const { renewer, applied } = makeRenewer({ clock, store, issuer });
  renewer.start();
  await clock.flush();
  assert.equal(applied.length, 0);
  const status = renewer.status();
  assert.equal(status.status, 'error');
  assert.match(status.lastError, /시계/);
  assert.equal(store.data.state.lastErrorKind, 'clock');
  assert.equal(status.nextAttemptAt, T0 + CLOCK_RETRY_MS);
  assert.equal(store.data.cert, null, '쓸 수 없는 인증서는 저장하지 않는다');
  await clock.advance(CLOCK_RETRY_MS - 1000);
  assert.equal(issuer.calls.length, 1, '시계를 고치기 전에는 그 사이(12시간마다 확인)에 다시 받지 않는다');
  await clock.advance(2000);
  assert.equal(issuer.calls.length, 2);
  assert.equal(store.data.state.nextAttemptAt, T0 + 2 * CLOCK_RETRY_MS, '여전히 틀리면 또 이틀');
  renewer.stop();
});

test('방금 받은 인증서가 이 PC 시계로 벌써 갱신할 때면(시계가 두 달 넘게 앞섬) 걸어서 쓰되, 12시간마다 새로 받지 않고 이틀에 한 번만', async () => {
  const clock = fakeClock();
  const store = memoryStore();
  // 이 PC 시계로는 70일 전에 발급돼 20일 남은 것처럼 보이는 새 인증서
  const issuer = fakeIssuer([{ ...certs.dueSoon }]);
  const { renewer, applied } = makeRenewer({ clock, store, issuer });
  renewer.start();
  await clock.flush();
  assert.equal(applied.length, 1, '브라우저 시계로는 멀쩡한 인증서라 건다');
  assert.equal(store.data.cert.certPem, certs.dueSoon.certPem);
  const status = renewer.status();
  assert.equal(status.status, 'expiring');
  assert.match(status.lastError, /시계/);
  assert.equal(status.nextAttemptAt, T0 + CLOCK_RETRY_MS);
  assert.equal(store.data.state.lastErrorKind, 'clock');
  assert.equal(store.data.state.nextAttemptAt, T0 + CLOCK_RETRY_MS, '파일에도 남아 재시작해도 앞당기지 않는다');
  await clock.advance(CLOCK_RETRY_MS - 1000);
  assert.equal(issuer.calls.length, 1);
  await clock.advance(2000);
  assert.equal(issuer.calls.length, 2);
  renewer.stop();
});

test('재시작: 시계가 앞서 가던 때 적힌 기록(먼 미래의 다음 시도)은 버리고 1시간 뒤에 시도한다 — 시계를 고친 뒤 그날까지 갱신이 멈추지 않게', async () => {
  const clockError = '받은 인증서가 이 PC 시계로는 이미 만료입니다 — 서버 PC의 날짜·시간·시간대를 확인하세요.';
  for (const { saved, keepsError } of [
    // 시계가 400일 앞서 있던 동안의 시계 오류 기록
    { saved: { nextAttemptAt: T0 + 400 * DAY, lastAttemptAt: T0 + 398 * DAY, lastError: clockError, lastErrorKind: 'clock' }, keepsError: false },
    // 시계를 이틀 뒤로 고침 — 다음 시도(Retry-After 3일)는 8일 안쪽이지만 마지막 시도가 미래라 그 기록의 시각을 믿지 않는다
    { saved: { nextAttemptAt: T0 + 5 * DAY, lastAttemptAt: T0 + 2 * DAY, lastError: '한도', lastErrorKind: 'rateLimited' }, keepsError: true },
    // 깨졌거나 손댄 파일의 엉뚱한 값
    { saved: { nextAttemptAt: T0 + 10 * 365 * DAY, lastAttemptAt: null, lastError: '실패', lastErrorKind: 'challenge' }, keepsError: true },
  ]) {
    const clock = fakeClock();
    const store = memoryStore({ state: { domain: DOMAIN, staging: false, failures: 3, ...saved } });
    const issuer = fakeIssuer([{ ...certs.fresh }]);
    const { renewer } = makeRenewer({ clock, store, issuer });
    // 만들자마자(시작 전에) 바로잡아 파일에도 남긴다.
    assert.equal(store.data.state.nextAttemptAt, T0 + BACKOFF_MIN_MS, JSON.stringify(saved));
    assert.equal(store.data.state.lastAttemptAt, saved.lastAttemptAt && saved.lastAttemptAt > T0 ? null : saved.lastAttemptAt);
    assert.equal(store.data.state.lastError, keepsError ? saved.lastError : null, '시계 오류만 지운다');
    assert.equal(store.data.state.failures, 3, '실패 횟수는 그대로(백오프가 이어진다)');
    renewer.start();
    await clock.flush();
    assert.equal(issuer.calls.length, 0, '바로 묻지는 않는다');
    assert.equal(renewer.status().nextAttemptAt, T0 + BACKOFF_MIN_MS);
    await clock.advance(BACKOFF_MIN_MS);
    assert.equal(issuer.calls.length, 1);
    assert.equal(renewer.status().status, 'valid');
    renewer.stop();
  }
});

test('서버가 도는 중에 앞서 가던 시계를 고쳐도 — 관리자 콘솔을 보면 바로, 아니면 다음 12시간 확인 때 알아채고 곧 다시 시도한다', async () => {
  const skew = 400 * DAY;
  for (const viaStatus of [true, false]) {
    const clock = fakeClock(T0 + skew); // 이 PC 시계가 400일 앞서 있다
    const store = memoryStore();
    const issuer = fakeIssuer([{ ...certs.fresh }]); // 진짜 시각(T0) 기준 90일짜리 — 이 PC 시계로는 이미 만료
    const { renewer, applied } = makeRenewer({ clock, store, issuer });
    renewer.start();
    await clock.flush();
    assert.equal(issuer.calls.length, 1);
    assert.equal(applied.length, 0);
    assert.equal(store.data.state.lastErrorKind, 'clock');
    assert.equal(store.data.state.nextAttemptAt, T0 + skew + CLOCK_RETRY_MS);

    await clock.jump(-skew); // 관리자가 시계를 고친다
    if (viaStatus) {
      const status = renewer.status();
      assert.equal(status.status, 'pending', '시계 오류는 지웠다');
      assert.equal(status.lastError, null);
      assert.equal(status.nextAttemptAt, T0 + BACKOFF_MIN_MS);
      assert.equal(store.data.state.nextAttemptAt, T0 + BACKOFF_MIN_MS, '파일에도 바로 남긴다');
      assert.deepEqual(clock.pendingDelays(), [BACKOFF_MIN_MS], '일정을 다시 잡았다');
      await clock.advance(BACKOFF_MIN_MS);
    } else {
      await clock.advance(CHECK_INTERVAL_MS);
      assert.equal(store.data.state.nextAttemptAt, T0 + CHECK_INTERVAL_MS + BACKOFF_MIN_MS, '다음 확인 때 알아챘다');
      assert.equal(issuer.calls.length, 1);
      await clock.advance(BACKOFF_MIN_MS);
    }
    assert.equal(issuer.calls.length, 2, `${viaStatus ? '콘솔' : '12시간 확인'} 뒤 다시 받았다`);
    assert.equal(renewer.status().status, 'valid');
    assert.equal(applied.length, 1);
    renewer.stop();
  }
});

test('정상 기록은 건드리지 않는다 — 8일짜리 Retry-After, NTP가 몇십 분 되돌린 시계', async () => {
  for (const saved of [
    { nextAttemptAt: T0 + MAX_RETRY_AFTER_MS, lastAttemptAt: T0 - 1000 },
    { nextAttemptAt: T0 + 3 * DAY, lastAttemptAt: T0 + CLOCK_SKEW_TOLERANCE_MS - 1000 },
  ]) {
    const clock = fakeClock();
    const store = memoryStore({ state: { domain: DOMAIN, staging: false, failures: 1, lastError: '한도', lastErrorKind: 'rateLimited', ...saved } });
    const issuer = fakeIssuer([{ ...certs.fresh }]);
    const { renewer } = makeRenewer({ clock, store, issuer });
    renewer.start();
    await clock.flush();
    const status = renewer.status();
    assert.equal(issuer.calls.length, 0);
    assert.equal(status.nextAttemptAt, saved.nextAttemptAt);
    assert.equal(status.lastAttemptAt, saved.lastAttemptAt);
    assert.equal(store.writes.length, 0, '기록을 고쳐 쓰지 않았다');
    renewer.stop();
  }
});

test('확인 중에 예기치 못한 예외가 나도 다음 확인 타이머는 다시 걸린다(갱신이 영영 멈추지 않게)', async () => {
  const clock = fakeClock();
  const store = memoryStore({ cert: certs.fresh });
  const issuer = fakeIssuer([{ ...certs.renewed }]);
  let throwOnce = true;
  const { renewer } = makeRenewer({
    clock,
    store,
    issuer,
    onChange: () => {
      if (throwOnce) {
        throwOnce = false;
        throw new Error('boom');
      }
    },
  });
  renewer.start();
  await clock.flush();
  assert.equal(clock.pendingDelays().length, 1, '타이머가 살아 있다');
  await clock.advance(61 * DAY);
  assert.equal(issuer.calls.length, 1, '때가 되면 여전히 갱신한다');
  renewer.stop();
});

test('진짜 파일 저장소: 인증서·키·기록을 certs 폴더에 쓰고 다시 읽는다(깨진 기록은 없는 것으로)', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'webtls-store-'));
  try {
    const store = createCertificateStore({ certsDir: path.join(dir, 'certs') });
    assert.equal(store.readCertificate(), null);
    assert.equal(store.readState(), null);
    store.writeCertificate(certs.fresh);
    store.writeState({ domain: DOMAIN, nextAttemptAt: 123 });
    assert.deepEqual(store.readCertificate(), certs.fresh);
    assert.deepEqual(store.readState(), { domain: DOMAIN, nextAttemptAt: 123 });
    assert.deepEqual(fs.readdirSync(path.join(dir, 'certs')).sort(), ['acme-state.json', 'web.crt', 'web.key'], '임시 파일이 남지 않는다');
    fs.writeFileSync(store.stateFile, '{not json');
    assert.equal(store.readState(), null);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
