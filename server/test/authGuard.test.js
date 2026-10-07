// 로그인·계정 복구 무차별 대입 방어(authGuard.js) 단위 테스트 — `node --test test/*.test.js` (DB·서버 없이 돈다).
import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  FailureLimiter,
  RateLimiter,
  beginAttempts,
  ipKey,
  isLanAddress,
  minutesText,
  rateLimit,
  retryLater,
  userKey,
  waitBeforeAttempt,
  waitText,
} from '../src/authGuard.js';

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

test('막혀 있는 동안 끝난 실패는 차단을 풀지도 늘리지도 않는다(예전엔 기록을 새로 시작해 차단이 풀렸다)', () => {
  const c = clock();
  const l = new FailureLimiter({ max: 3, windowMs: 1000, blockMs: 5000, now: c.now });
  l.fail('k');
  l.fail('k');
  assert.equal(l.fail('k'), true);
  c.advance(100);
  // 막히기 전에 시작해 막힌 뒤에 끝난 확인들의 실패.
  for (let i = 0; i < 10; i += 1) assert.equal(l.fail('k'), false);
  assert.equal(l.blockedFor('k'), 4900);
  // 창(1초)이 지나도 차단 중이면 그대로다.
  c.advance(2000);
  assert.equal(l.fail('k'), false);
  assert.equal(l.blockedFor('k'), 2900);
  // 차단이 끝나면 처음부터 다시 센다.
  c.advance(2900);
  assert.equal(l.fail('k'), false);
  assert.equal(l.failures('k'), 1);
});

test('확인 중(begin)까지 세어 max가 차면 더 시작하지 않고, 놓으면(release) 다시 된다 — release는 한 번만 센다', () => {
  const c = clock();
  const l = new FailureLimiter({ max: 3, windowMs: 1000, blockMs: 7000, now: c.now });
  l.fail('k');
  const a = l.begin('k');
  assert.equal(l.waitToBegin('k'), 0);
  const b = l.begin('k');
  // 실패 1 + 확인 중 2 = 3 — 둘이 다 틀리면 그것만으로 막히므로 더 시작하지 않는다(확인은 금방 끝나니 5초 뒤에 다시).
  assert.equal(l.waitToBegin('k'), 5000);
  a();
  a(); // 두 번 불러도 하나만 놓는다
  assert.equal(l.pending.get('k'), 1);
  assert.equal(l.waitToBegin('k'), 0);
  b();
  assert.equal(l.pending.size, 0);
  // 막혀 있으면 남은 차단 시간.
  l.fail('k');
  l.fail('k');
  assert.equal(l.waitToBegin('k'), 7000);
  c.advance(4000);
  assert.equal(l.waitToBegin('k'), 3000);
  // 창이 지난 실패는 세지 않는다.
  const fresh = new FailureLimiter({ max: 2, windowMs: 1000, blockMs: 5000, now: c.now });
  fresh.fail('x');
  c.advance(1001);
  fresh.begin('x');
  assert.equal(fresh.waitToBegin('x'), 0);
});

test('beginAttempts: 여러 칸에 한꺼번에 걸고, 하나라도 막혔거나 꽉 찼으면 아무것도 걸지 않는다', () => {
  const ipUser = new FailureLimiter({ max: 2, windowMs: 1000, blockMs: 5000 });
  const ip = new FailureLimiter({ max: 5, windowMs: 1000, blockMs: 5000 });
  const slots = [
    [ipUser, '1.2.3.4|kim'],
    [ip, '1.2.3.4'],
  ];
  const first = beginAttempts(slots);
  const second = beginAttempts(slots);
  assert.equal(first.wait, 0);
  assert.equal(second.wait, 0);
  const third = beginAttempts(slots);
  assert.ok(third.wait > 0);
  assert.equal(third.release, undefined);
  // 꽉 찬 ipUser 때문에 거절된 시도는 ip 칸에도 걸리지 않았다.
  assert.equal(ip.pending.get('1.2.3.4'), 2);
  assert.equal(waitBeforeAttempt(slots), third.wait);
  first.release();
  second.release();
  assert.equal(ipUser.pending.size + ip.pending.size, 0);
  assert.equal(waitBeforeAttempt(slots), 0);
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

test('IP 키: 밖의 IPv6는 /64로 묶고, IPv4·IPv4-mapped·사내 주소는 주소 그대로', () => {
  assert.equal(ipKey('203.0.113.5'), '203.0.113.5');
  assert.equal(ipKey('::ffff:203.0.113.5'), '203.0.113.5'); // 같은 사람이 IPv4로 오든 이 모양으로 오든 같은 키
  assert.equal(ipKey('::ffff:192.168.0.7'), '192.168.0.7');
  assert.equal(ipKey('2001:db8:1:2:3:4:5:6'), '2001:db8:1:2::/64');
  assert.equal(ipKey('2001:DB8:1:2::9'), '2001:db8:1:2::/64');
  assert.equal(ipKey('2001:0db8:0001:0002:ffff:ffff:ffff:ffff'), '2001:db8:1:2::/64');
  assert.equal(ipKey('2001:db8::1'), '2001:db8:0:0::/64');
  assert.notEqual(ipKey('2001:db8:1:3::1'), ipKey('2001:db8:1:2::1'));
  assert.equal(ipKey('64:ff9b::1.2.3.4'), '64:ff9b:0:0::/64');
  // 사내 IPv6는 사무실 전체가 /64 하나라 묶지 않는다.
  assert.equal(ipKey('fd12:3456::1'), 'fd12:3456::1');
  assert.equal(ipKey('fe80::1%eth0'), 'fe80::1%eth0');
  assert.equal(ipKey('::1'), '::1');
  for (const v of ['unknown', '', undefined, null]) assert.equal(ipKey(v), 'unknown', String(v));
});

test('rateLimit 미들웨어는 같은 /64의 다른 주소를 같은 곳으로 센다', () => {
  const limiter = new RateLimiter({ max: 1, windowMs: 1000 });
  const mw = rateLimit(limiter, '시도');
  const call = (ip) => {
    const out = { next: false, status: 200, headers: {} };
    const res = {
      set(k, v) {
        out.headers[k] = v;
        return res;
      },
      status(code) {
        out.status = code;
        return res;
      },
      json(body) {
        out.body = body;
        return res;
      },
    };
    mw({ socket: { remoteAddress: ip } }, res, () => (out.next = true));
    return out;
  };
  assert.equal(call('2001:db8:5:6::1').next, true);
  const second = call('2001:db8:5:6::2');
  assert.equal(second.next, false);
  assert.equal(second.status, 429);
  assert.ok(second.headers['Retry-After']);
  assert.equal(call('2001:db8:5:7::1').next, true); // 옆 /64는 따로
  assert.equal(call('203.0.113.1').next, true);
});

test('아이디 키는 대소문자·공백을 무시한다(제한 우회 방지)', () => {
  assert.equal(userKey('  Admin '), 'admin');
  assert.equal(userKey(undefined), '');
});

test('남은 시간 표기', () => {
  assert.equal(minutesText(60 * 1000), '1분');
  assert.equal(minutesText(14 * 60 * 1000 + 1), '15분');
  assert.equal(minutesText(24 * 60 * 60 * 1000), '24시간');
  // 1분이 안 되면 초로 — "5초 후"면 될 것을 "1분 후"라고 하지 않는다.
  assert.equal(waitText(4200), '5초');
  assert.equal(waitText(1), '1초');
  assert.equal(waitText(59 * 1000), '59초');
  assert.equal(waitText(60 * 1000), '1분');
  assert.equal(waitText(15 * 60 * 1000), '15분');
});

test('retryLater: 429 + Retry-After(초, 최소 1) + 준 문구 그대로', () => {
  const out = { headers: {} };
  const res = {
    set(k, v) {
      out.headers[k] = v;
      return res;
    },
    status(code) {
      out.status = code;
      return res;
    },
    json(body) {
      out.body = body;
      return res;
    },
  };
  retryLater(res, 2500, '잠시 후 다시 시도하세요.');
  assert.deepEqual(out, { headers: { 'Retry-After': '3' }, status: 429, body: { error: '잠시 후 다시 시도하세요.' } });
  retryLater(res, 0, 'x');
  assert.equal(out.headers['Retry-After'], '1');
});
