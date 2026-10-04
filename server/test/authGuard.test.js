// 로그인·계정 복구 무차별 대입 방어(authGuard.js) 단위 테스트 — `node --test test/*.test.js` (DB·서버 없이 돈다).
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { FailureLimiter, RateLimiter, isLanAddress, minutesText, userKey } from '../src/authGuard.js';

function clock(start = 0) {
  let t = start;
  return { now: () => t, advance: (ms) => (t += ms) };
}

test('정해진 횟수만큼 틀리면 막히고, 막히기 시작한 순간만 true', () => {
  const c = clock();
  const l = new FailureLimiter({ max: 3, windowMs: 1000, blockMs: 5000, now: c.now });
  assert.equal(l.fail('k'), false);
  assert.equal(l.fail('k'), false);
  assert.equal(l.blockedFor('k'), 0);
  assert.equal(l.fail('k'), true);
  assert.equal(l.blockedFor('k'), 5000);
  c.advance(4999);
  assert.equal(l.blockedFor('k'), 1);
  c.advance(1);
  assert.equal(l.blockedFor('k'), 0);
  // 풀리면 처음부터 다시 센다.
  assert.equal(l.fail('k'), false);
});

test('창이 지나면 틀린 횟수를 처음부터 센다', () => {
  const c = clock();
  const l = new FailureLimiter({ max: 3, windowMs: 1000, blockMs: 5000, now: c.now });
  l.fail('k');
  l.fail('k');
  c.advance(1001);
  assert.equal(l.fail('k'), false);
  assert.equal(l.blockedFor('k'), 0);
});

test('성공하면(reset) 기록을 지운다, 다른 키는 서로 영향이 없다', () => {
  const l = new FailureLimiter({ max: 2, windowMs: 1000, blockMs: 5000 });
  l.fail('a');
  l.reset('a');
  assert.equal(l.fail('a'), false);
  l.fail('b');
  assert.equal(l.fail('b'), true);
  assert.equal(l.blockedFor('a'), 0);
});

test('요청 횟수 제한은 창 안에서 max를 넘으면 창이 끝날 때까지 막는다', () => {
  const c = clock();
  const r = new RateLimiter({ max: 2, windowMs: 1000, now: c.now });
  assert.equal(r.hit('ip'), 0);
  assert.equal(r.hit('ip'), 0);
  assert.equal(r.hit('ip'), 1000);
  c.advance(400);
  assert.equal(r.hit('ip'), 600);
  c.advance(600);
  assert.equal(r.hit('ip'), 0);
});

test('prune은 끝난 기록만 지운다', () => {
  const c = clock();
  const l = new FailureLimiter({ max: 2, windowMs: 1000, blockMs: 5000, now: c.now });
  l.fail('blocked');
  l.fail('blocked');
  l.fail('counting');
  c.advance(500);
  l.prune();
  assert.equal(l.entries.size, 2); // 차단 중·창 안 기록은 남긴다
  c.advance(4500);
  l.prune();
  assert.equal(l.entries.size, 0);
});

test('사내(사설) 주소 판별 — 계정 잠금은 사내 IP에 걸지 않는다', () => {
  for (const ip of ['192.168.0.10', '10.1.2.3', '172.16.0.1', '172.31.255.255', '127.0.0.1', '::1', '::ffff:192.168.1.7', 'fd12::1', 'fe80::1']) {
    assert.equal(isLanAddress(ip), true, ip);
  }
  for (const ip of ['8.8.8.8', '203.0.113.5', '172.32.0.1', '::ffff:1.2.3.4', '2001:db8::1', '', undefined]) {
    assert.equal(isLanAddress(ip), false, String(ip));
  }
});

test('아이디 키는 대소문자·공백을 무시한다(제한 우회 방지)', () => {
  assert.equal(userKey('  Admin '), 'admin');
  assert.equal(userKey(undefined), '');
});

test('남은 시간 표기', () => {
  assert.equal(minutesText(60 * 1000), '1분');
  assert.equal(minutesText(14 * 60 * 1000 + 1), '15분');
  assert.equal(minutesText(24 * 60 * 60 * 1000), '24시간');
});
