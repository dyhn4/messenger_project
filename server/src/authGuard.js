import net from 'node:net';
import { PASSWORD_MIN_LENGTH } from './passwordPolicy.js';

/**
 * 로그인·계정 복구처럼 인증 없이 열려 있는 경로를 무차별 대입(비밀번호·보안 질문 답·페어링
 * 코드를 계속 바꿔 넣어보기)에서 지킨다. 사내망 밖(LTE/5G)에서 접속할 수 있게 공유기 포트를
 * 열면 이 경로들이 인터넷 전체에 노출되기 때문이다.
 *
 * 상태는 메모리에만 둔다(서버를 재시작하면 풀린다) — 서버가 한 대뿐이고, 공격을 늦추는 게
 * 목적이라 영구 저장까지는 필요 없다. 클라이언트 IP는 소켓 주소(req.socket.remoteAddress)만
 * 믿는다: 앞단 프록시가 없는 구조라 X-Forwarded-For는 공격자가 마음대로 꾸밀 수 있다.
 *
 * 사내 IP(사설 대역)에서 온 요청은 **계정 단위 잠금**에서 뺀다 — 밖의 공격자가 직원 계정을
 * 일부러 잠가서 사내에서도 못 쓰게 만드는 걸 막기 위해서다. IP 단위 제한은 사내에도 똑같이 건다.
 *
 * 횟수는 끝난 실패만이 아니라 지금 확인 중인 시도까지 센다(FailureLimiter.begin, beginAttempts) — 그래야 요청을 한꺼번에
 * 보내도 정한 횟수보다 많이 맞춰 보지 못한다.
 *
 * DB를 안 건드리는 모듈이라 로그인 판단 순서(runLoginAttempt)·로그인한 사람의 비밀번호 재확인(runReauthAttempt)과 아이디
 * 규칙도 여기 두고 단위 테스트한다(test/authGuard.test.js, test/loginGuard.test.js, test/reauthGuard.test.js,
 * test/usernameRules.test.js).
 */

/** 사설·루프백·링크 로컬 주소인지(IPv4, IPv4-mapped IPv6, IPv6 ULA/링크 로컬). */
export function isLanAddress(ip) {
  if (!ip) return false;
  const v4 = ip.startsWith('::ffff:') ? ip.slice(7) : ip;
  if (net.isIPv4(v4)) {
    return /^(10\.|127\.|192\.168\.|169\.254\.|172\.(1[6-9]|2\d|3[01])\.)/.test(v4);
  }
  const lower = ip.toLowerCase();
  return lower === '::1' || /^f[cd]/.test(lower) || /^fe[89ab]/.test(lower);
}

export function clientIp(req) {
  return req.socket?.remoteAddress ?? 'unknown';
}

/** IPv6 주소(net.isIPv6로 이미 확인한 것) → 16비트 칸 8개. 끝이 IPv4 점 표기(64:ff9b::1.2.3.4)여도 읽는다. */
function ipv6Groups(ip) {
  let s = ip.split('%')[0]; // 링크 로컬의 영역 표시(fe80::1%eth0)는 뗀다.
  const dotted = /^(.*:)(\d{1,3}(?:\.\d{1,3}){3})$/.exec(s);
  if (dotted) {
    const [a, b, c, d] = dotted[2].split('.').map(Number);
    s = `${dotted[1]}${((a << 8) | b).toString(16)}:${((c << 8) | d).toString(16)}`;
  }
  const halves = s.split('::');
  if (halves.length > 2) return null;
  const head = halves[0] ? halves[0].split(':') : [];
  const tail = halves.length === 2 && halves[1] ? halves[1].split(':') : [];
  const fill = halves.length === 2 ? 8 - head.length - tail.length : 0;
  if (fill < 0) return null;
  const groups = [...head, ...Array(fill).fill('0'), ...tail].map((g) => parseInt(g, 16));
  return groups.length === 8 && groups.every((g) => Number.isInteger(g) && g >= 0 && g <= 0xffff) ? groups : null;
}

/**
 * IP를 횟수 제한의 키로 바꾼다. 사내망 밖의 IPv6는 앞 64비트(/64)로 묶는다 — 가정·휴대폰 회선은 보통 /64를 통째로 받아서,
 * 주소 끝자리만 바꿔 가며 보내면 IP마다 세는 제한(아래 limits의 …Ip)을 매번 새로 받을 수 있기 때문이다. 사내(사설) 주소는
 * 그대로 둔다 — 사내 IPv6는 사무실 전체가 /64 하나라, 묶으면 사무실 전체가 한 사람처럼 세진다. IPv4-mapped 주소
 * (::ffff:1.2.3.4)는 그 IPv4로 본다(같은 사람이 IPv4로 오든 이 모양으로 오든 같은 키).
 * 사내 주소인지(isLanAddress)는 이 키가 아니라 원래 주소로 따진다.
 */
export function ipKey(ip) {
  if (typeof ip !== 'string' || !ip) return 'unknown';
  const lower = ip.toLowerCase();
  if (lower.startsWith('::ffff:') && net.isIPv4(lower.slice(7))) return lower.slice(7);
  if (!net.isIPv6(lower) || isLanAddress(lower)) return lower;
  const groups = ipv6Groups(lower);
  return groups ? `${groups.slice(0, 4).map((g) => g.toString(16)).join(':')}::/64` : lower;
}

/** 이 요청을 IP 단위로 셀 때의 키(ipKey). */
export function clientIpKey(req) {
  return ipKey(clientIp(req));
}

/**
 * 확인 중인 시도로 남은 횟수가 다 찼을 때(FailureLimiter.waitToBegin) 다시 해 보라고 할 시간 — 비밀번호 확인 하나는 1초도
 * 안 걸린다. 그 확인들이 다 틀렸으면 그때부터는 정해진 차단 시간을 알려 준다.
 */
const ATTEMPT_BUSY_RETRY_MS = 5 * 1000;

/**
 * 실패 횟수 기반 차단. [windowMs] 안에 [max]번 실패하면 [blockMs] 동안 막는다. 차단이 풀리면
 * 처음부터 다시 센다. [now]는 테스트용.
 *
 * 비밀번호·보안 질문 답은 확인(DB 조회·bcrypt)을 기다리는 동안엔 실패가 아직 세어지지 않는다. 그래서 확인을 시작할 때
 * begin()으로 "확인 중"을 함께 세고, 창 안의 실패와 확인 중을 더해 [max]가 차면 더 시작하지 않는다(waitToBegin —
 * beginAttempts가 둘을 묶어 쓴다). 예전엔 막혔는지만 보고 들어가서, 한꺼번에 100개를 보내면 100개 모두 "아직 0번 틀림"을
 * 보고 비밀번호를 맞춰 봤다(5번 제한인데 100개).
 */
export class FailureLimiter {
  constructor({ max, windowMs, blockMs, now = () => Date.now() }) {
    Object.assign(this, { max, windowMs, blockMs, now });
    this.entries = new Map(); // key → { count, firstAt, blockedUntil }
    this.pending = new Map(); // key → 지금 확인 중인(결과가 아직 안 난) 시도 수
  }

  /** 막혀 있으면 남은 ms, 아니면 0. */
  blockedFor(key) {
    const e = this.entries.get(key);
    if (!e?.blockedUntil) return 0;
    const left = e.blockedUntil - this.now();
    if (left > 0) return left;
    this.entries.delete(key);
    return 0;
  }

  /** 지금 창 안에서 센 실패 수 — 막혀 있거나(그건 blockedFor가 먼저 거른다) 창이 지났으면 0. */
  failures(key) {
    const e = this.entries.get(key);
    if (!e || e.blockedUntil || this.now() - e.firstAt > this.windowMs) return 0;
    return e.count;
  }

  /**
   * 확인을 하나 더 시작해도 되는지 — 막혀 있으면 남은 ms. 막히지 않았어도 창 안의 실패와 확인 중인 시도를 더해 이미 [max]면
   * ATTEMPT_BUSY_RETRY_MS(확인 중인 것이 모두 틀리면 그것만으로 막히므로 그보다 많이 한꺼번에 맞춰 보지 못하게). 아니면 0.
   */
  waitToBegin(key) {
    const blocked = this.blockedFor(key);
    if (blocked > 0) return blocked;
    return this.failures(key) + (this.pending.get(key) ?? 0) >= this.max ? ATTEMPT_BUSY_RETRY_MS : 0;
  }

  /**
   * 확인 하나를 "확인 중"으로 센다 — 결과가 나면(맞든 틀리든, 오류로 끝나든) 돌려준 함수를 부른다. 여러 번 불러도 한 번만
   * 놓는다. 틀렸으면 그 전에 fail()로 센다.
   */
  begin(key) {
    this.pending.set(key, (this.pending.get(key) ?? 0) + 1);
    let held = true;
    return () => {
      if (!held) return;
      held = false;
      const left = (this.pending.get(key) ?? 1) - 1;
      if (left > 0) this.pending.set(key, left);
      else this.pending.delete(key);
    };
  }

  /**
   * 실패 한 번. 이번 실패로 막히기 시작했으면 true. 이미 막혀 있으면 차단을 그대로 둔다(풀지도 늘리지도 않는다) — 예전엔
   * 막힌 뒤에 끝난 확인의 실패가 기록을 처음부터(1번 틀림) 다시 시작해서 차단을 슬쩍 풀어 버렸다.
   */
  fail(key) {
    const t = this.now();
    let e = this.entries.get(key);
    if (e && e.blockedUntil > t) return false;
    if (!e || e.blockedUntil || t - e.firstAt > this.windowMs) {
      e = { count: 0, firstAt: t, blockedUntil: 0 };
      this.entries.set(key, e);
    }
    e.count += 1;
    if (e.count >= this.max) {
      e.blockedUntil = t + this.blockMs;
      return true;
    }
    return false;
  }

  reset(key) {
    this.entries.delete(key);
  }

  /** 오래된 기록 정리(주기적으로 부른다). 확인 중인 수(pending)는 시간이 아니라 begin()이 돌려준 함수로만 줄어든다. */
  prune() {
    const t = this.now();
    for (const [key, e] of this.entries) {
      if (e.blockedUntil ? e.blockedUntil <= t : t - e.firstAt > this.windowMs) this.entries.delete(key);
    }
  }
}

/** [limiter, key] 쌍들 가운데 가장 오래 기다려야 하는 ms(FailureLimiter.waitToBegin) — 0이면 확인을 시작해도 된다. */
export function waitBeforeAttempt(slots) {
  return slots.reduce((wait, [limiter, key]) => Math.max(wait, limiter.waitToBegin(key)), 0);
}

/**
 * 비밀번호·답 확인 하나를 [limiter, key] 쌍마다 "확인 중"으로 건다. 하나라도 막혔거나 꽉 찼으면 아무것도 걸지 않고 `{ wait }`(ms),
 * 아니면 `{ wait: 0, release }` — 결과가 나면 release()를 꼭 부른다(try/finally: 오류로 끝나도 놓아야 그 키가 꽉 찬 채로 남지
 * 않는다). 보는 것과 거는 것 사이에 await가 없어서, 한꺼번에 온 요청들이 같은 빈자리를 함께 보고 들어오지 못한다.
 */
export function beginAttempts(slots) {
  const wait = waitBeforeAttempt(slots);
  if (wait > 0) return { wait };
  const releases = slots.map(([limiter, key]) => limiter.begin(key));
  return { wait: 0, release: () => releases.forEach((release) => release()) };
}

/** 요청 횟수 제한(성공·실패 무관). [windowMs] 안에 [max]번 넘게 오면 그 창이 끝날 때까지 막는다. */
export class RateLimiter {
  constructor({ max, windowMs, now = () => Date.now() }) {
    Object.assign(this, { max, windowMs, now });
    this.entries = new Map(); // key → { count, resetAt }
  }

  /** 이번 요청을 세고, 막혀야 하면 남은 ms(아니면 0). */
  hit(key) {
    const t = this.now();
    let e = this.entries.get(key);
    if (!e || e.resetAt <= t) {
      e = { count: 0, resetAt: t + this.windowMs };
      this.entries.set(key, e);
    }
    e.count += 1;
    return e.count > this.max ? e.resetAt - t : 0;
  }

  prune() {
    const t = this.now();
    for (const [key, e] of this.entries) if (e.resetAt <= t) this.entries.delete(key);
  }
}

const MIN = 60 * 1000;
const HOUR = 60 * MIN;
const DAY = 24 * HOUR;

/** 차례를 못 받은 요청에 다시 해 보라고 할 가장 짧은 시간. */
const MIN_RETRY_MS = 1000;

/**
 * 사내망 밖 전체의 비밀번호 오류가 많을 때 — 막지 않고, **처음 보는 곳의 밖 로그인을 한 줄로 세워 일정한 간격으로만** 비밀번호
 * 확인에 들여보낸다. 예전엔 15분에 300번이 넘으면 밖에서의 로그인을 15분 동안 모두 막아서, 누구든 IP 몇 개로 틀린 비밀번호
 * 300번만 보내면 모든 직원의 밖 로그인을 계속 막아 둘 수 있었다(하나뿐인 키라 공격자와 직원이 같은 칸을 쓴다). 한동안은
 * 요청마다 몇 초씩 기다리게만 했는데, 기다림은 한꺼번에 보내면 공짜라(1,000개를 동시에 보내면 1초 뒤 1,000개가 다 확인된다)
 * 수많은 IP로 나눠 보내는 공격의 속도를 줄이지 못했다.
 *
 * 지금은 최근 [windowMs] 동안의 오류가 [budget]에 닿으면 "차례 받기"를 켠다. 처음 보는 곳(그 IP 키에서 그 아이디로 최근 로그인에
 * 성공한 적이 없는 곳)의 밖 로그인은 take()로 차례를 받아 [baseIntervalMs]에 하나씩만 확인에 들어간다 — 기본값(15분에 300번,
 * 3초에 하나)이면 처음 보는 곳의 비밀번호 확인은 몇 개를 동시에 보내든 15분에 300번 남짓으로, 예전 통째 차단과 같은 상한이다.
 * 오류가 budget의 2배·4배…로 늘면 간격도 두 배씩 [maxIntervalMs]까지 늘린다. 차례가 [maxWaitMs]보다 멀리 밀렸으면(줄이 꽉
 * 찼으면) 기다리게 하지 않고 언제 다시 하면 되는지 알려 준다(429). 한 IP 키는 한 번에 한 차례만 기다릴 수 있다 — IP 하나로
 * 줄을 다 차지하지 못하게. 최근 그곳에서 로그인에 성공한 사람(RecentLogins)과 사내는 줄을 서지 않는다. 오류가 budget의 절반
 * 아래로 줄어야 끈다 — 기준선에서 켜졌다 꺼졌다 하면 꺼진 틈마다 한꺼번에 몰려 들어올 수 있어서다. 오류는 1분 칸([bucketMs])
 * 으로 나눠 세서 기억하는 양이 작다. [now]는 테스트용.
 *
 * 켤지 정할 때는 끝난 오류에 **아직 결과가 안 난 확인(inFlight)**도 더한다(pressure) — 끝난 오류만 보면, 켜지기 직전에 한꺼번에
 * 보낸 요청은 모두 이미 확인에 들어간 뒤라 동시에 보낸 만큼(수천 개) 그대로 맞춰 볼 수 있었다. 지금은 켜지기 전에도 확인 중인
 * 것까지 budget에 닿는 순간 줄을 세운다.
 */
export class LoginSlowdown {
  constructor({ budget, windowMs, baseIntervalMs, maxIntervalMs, maxWaitMs, bucketMs = MIN, now = () => Date.now() }) {
    Object.assign(this, { budget, windowMs, baseIntervalMs, maxIntervalMs, maxWaitMs, bucketMs, now });
    // 간격이 [maxIntervalMs]에 닿는 단계 — 그 위로는 간격이 같으니 단계도 더 올리지 않는다(운영자에게 같은 안내를 또 하지 않게).
    this.maxLevel = 1 + Math.max(0, Math.ceil(Math.log2(maxIntervalMs / baseIntervalMs)));
    this.buckets = []; // [{ slot, count }] — 오래된 칸부터
    this.active = false; // 차례 받기가 켜져 있는지
    this.reportedLevel = 0; // 운영자에게 알린 단계(같은 단계를 다시 알리지 않으려고)
    this.nextAt = 0; // 다음 차례를 줄 수 있는 가장 이른 시각
    this.waiting = new Map(); // IP 키 → 그 IP 키가 받은 차례의 시각(그 시각이 지나면 다시 줄을 설 수 있다)
    this.inFlight = 0; // 차례를 받고 아직 결과가 안 난 처음 보는 곳의 확인 수
  }

  /** 최근 [windowMs] 동안의 오류 수. */
  count() {
    this.dropOldBuckets();
    return this.buckets.reduce((n, b) => n + b.count, 0);
  }

  /** 켤지·몇 단계인지 정하는 수 — 최근 오류에 아직 결과가 안 난 확인을 더한다(그것들도 다 틀릴 수 있다). */
  pressure() {
    return this.count() + this.inFlight;
  }

  /**
   * 0 = 평소, 1 = 차례 받기, 2 = [pressure]가 budget의 2배 이상, 3 = 4배 이상 … (maxLevel까지). budget에 닿으면 켜고, budget의
   * 절반 아래로 줄면 끈다.
   */
  level(pressure = this.pressure()) {
    if (pressure >= this.budget) this.active = true;
    else if (pressure < this.budget / 2) this.active = false;
    if (!this.active) {
      this.reportedLevel = 0;
      return 0;
    }
    return pressure < this.budget ? 1 : Math.min(this.maxLevel, 1 + Math.floor(Math.log2(pressure / this.budget)));
  }

  /** [level] 단계의 차례 간격(ms) — 0이면 줄을 세우지 않는다. */
  intervalFor(level) {
    return level === 0 ? 0 : Math.min(this.maxIntervalMs, this.baseIntervalMs * 2 ** (level - 1));
  }

  /** 지금의 차례 간격(ms) — 평소엔 0. */
  intervalMs() {
    return this.intervalFor(this.level());
  }

  /**
   * 처음 보는 곳의 밖 로그인 하나에 차례를 준다 — `{ waitMs, finished }`: waitMs만큼 기다린 뒤 비밀번호를 확인하고, 결과가
   * 나면(실패로 세기 전에 — 같은 시도를 두 번 세지 않게) 그리고 어떻게 끝나든 finished()를 부른다(여러 번 불러도 한 번만 뺀다).
   * 차례를 줄 수 없으면 `{ retryMs }` — 줄이 꽉 찼거나 이 IP 키가 이미 차례를 기다리는 중이라, 그만큼 뒤에 다시 하라고 알린다.
   * 평소엔 늘 바로(waitMs 0) 주되, 확인 중인 수(inFlight)는 늘 센다.
   */
  take(ipk) {
    const interval = this.intervalMs();
    let waitMs = 0;
    if (interval > 0) {
      const t = this.now();
      const heldAt = this.waiting.get(ipk);
      if (heldAt > t) return { retryMs: Math.max(MIN_RETRY_MS, heldAt - t) };
      const at = Math.max(t, this.nextAt);
      if (at - t > this.maxWaitMs) return { retryMs: Math.max(MIN_RETRY_MS, at - t - this.maxWaitMs) };
      this.nextAt = at + interval;
      waitMs = at - t;
      if (waitMs > 0) this.waiting.set(ipk, at);
      else this.waiting.delete(ipk);
    }
    this.inFlight += 1;
    let open = true;
    return {
      waitMs,
      finished: () => {
        if (!open) return;
        open = false;
        this.inFlight -= 1;
      },
    };
  }

  /**
   * 오류 한 번. 이번 오류로 차례 받기가 켜졌거나 한 단계 더 엄해졌으면 운영자에게 알릴 { level, count, inFlight, intervalMs },
   * 아니면 null.
   */
  fail() {
    const slot = Math.floor(this.now() / this.bucketMs);
    const last = this.buckets.at(-1);
    if (last?.slot === slot) last.count += 1;
    else this.buckets.push({ slot, count: 1 });
    const count = this.count();
    const level = this.level(count + this.inFlight);
    if (level === 0 || level <= this.reportedLevel) return null;
    this.reportedLevel = level;
    return { level, count, inFlight: this.inFlight, intervalMs: this.intervalFor(level) };
  }

  dropOldBuckets() {
    const oldest = Math.floor((this.now() - this.windowMs) / this.bucketMs);
    while (this.buckets.length > 0 && this.buckets[0].slot <= oldest) this.buckets.shift();
  }

  /** 오래된 기록 정리(주기적으로 부른다) — 지난 칸과, 차례 시각이 지난 기다림. */
  prune() {
    this.dropOldBuckets();
    const t = this.now();
    for (const [ipk, at] of this.waiting) if (at <= t) this.waiting.delete(ipk);
  }
}

/**
 * 최근 로그인에 성공한 곳 — 키는 `IP 키|아이디`(loginKeys). 사내망 밖 전체가 공격받아 처음 보는 곳의 로그인을 줄 세울 때
 * (LoginSlowdown)도 여기 있는 곳은 줄을 서지 않는다. 비밀번호를 맞혀야만 생기는 기록이라 공격자가 남의 아이디로 만들어 둘 수
 * 없다. 앱은 로그인할 때 아이디·비밀번호 말고는 기기를 알아볼 값(기기 id·RefreshToken)을 보내지 않아서 "같은 기기" 대신
 * "같은 곳(IP 키)의 같은 아이디"로 본다 — 집·사무실 회선은 대개 그대로 알아보고, 주소가 자주 바뀌는 LTE는 줄을 설 수 있다.
 * [ttlMs]가 지나면 잊고, [maxEntries]를 넘으면 가장 오래된 것부터 잊는다. [now]는 테스트용.
 */
export class RecentLogins {
  constructor({ ttlMs, maxEntries, now = () => Date.now() }) {
    Object.assign(this, { ttlMs, maxEntries, now });
    this.entries = new Map(); // key → 마지막 성공 시각(마지막 성공 순서대로 들어 있다)
  }

  remember(key) {
    this.entries.delete(key);
    this.entries.set(key, this.now());
    if (this.entries.size > this.maxEntries) this.entries.delete(this.entries.keys().next().value);
  }

  has(key) {
    const at = this.entries.get(key);
    if (at === undefined) return false;
    if (this.now() - at <= this.ttlMs) return true;
    this.entries.delete(key);
    return false;
  }

  prune() {
    const t = this.now();
    for (const [key, at] of this.entries) {
      if (t - at <= this.ttlMs) break; // 성공 순서대로라 처음 만난 살아 있는 기록 뒤는 다 살아 있다.
      this.entries.delete(key);
    }
  }
}

/** 이 서버가 쓰는 제한값 — 숫자를 한곳에서 보고 고칠 수 있게 모아둔다. */
export const limits = {
  // 비밀번호: 같은 IP·같은 아이디로 5번 틀리면 15분.
  loginIpUser: new FailureLimiter({ max: 5, windowMs: 15 * MIN, blockMs: 15 * MIN }),
  // 비밀번호: 한 IP가 여러 아이디에 걸쳐 20번 틀리면 30분(아이디를 바꿔가며 흔한 비밀번호를 넣어보는 공격).
  loginIp: new FailureLimiter({ max: 20, windowMs: 15 * MIN, blockMs: 30 * MIN }),
  // 비밀번호: 한 아이디가 사내망 밖 여러 IP에서 20번 틀리면 1시간 — 사내에서는 그대로 로그인된다.
  loginUserExternal: new FailureLimiter({ max: 20, windowMs: HOUR, blockMs: HOUR }),
  // 비밀번호: 사내망 밖 전체에서 15분에 300번 틀리면(아직 결과가 안 난 확인도 함께 센다), 밖에서 처음 보는 곳의 로그인은 줄을 세워 3초에 하나씩만(15분에
  // 300번 = 3초에 1번) 비밀번호를 확인하고, 오류가 더 늘면 간격을 두 배씩 24초까지 늘린다. 차례가 15초 넘게 밀리면 언제 다시
  // 하면 되는지 알려 준다(LoginSlowdown) — 수많은 IP로 나눠서 아이디마다 흔한 비밀번호를 몇 개씩 넣어보는 공격(위 IP·아이디
  // 단위 제한에 안 걸린다)의 속도를 동시에 몇 개를 보내든 이 간격으로 묶는다. 예전처럼 밖 로그인을 통째로 막지는 않는다(그러면
  // 공격자가 모든 직원을 밖에서 못 들어오게 만들 수 있었다). 최근 그곳에서 로그인에 성공한 사람(recentLogins)과 사내는 줄을
  // 서지 않는다. 오류가 150번(절반) 아래로 줄면 풀린다.
  loginExternalSlowdown: new LoginSlowdown({
    budget: 300,
    windowMs: 15 * MIN,
    baseIntervalMs: (15 * MIN) / 300,
    maxIntervalMs: 24 * 1000,
    maxWaitMs: 15 * 1000,
  }),
  // 밖에서 로그인에 성공한 곳(IP 키|아이디) — 30일 동안(RefreshToken 유효기간과 같다), 최대 2만 곳까지 기억한다.
  recentLogins: new RecentLogins({ ttlMs: 30 * DAY, maxEntries: 20_000 }),
  // 보안 질문 답(비밀번호 재설정): 답은 짧고 추측하기 쉬워 더 엄격하게 — 같은 IP·아이디로 3번 틀리면 30분.
  recoveryIpUser: new FailureLimiter({ max: 3, windowMs: 30 * MIN, blockMs: 30 * MIN }),
  // 보안 질문 답: 한 아이디가 사내망 밖에서 하루에 10번 틀리면 하루 동안 밖에서는 재설정 불가.
  recoveryUserExternal: new FailureLimiter({ max: 10, windowMs: 24 * HOUR, blockMs: 24 * HOUR }),
  // 로그인한 사용자의 비밀번호 재확인(화면 잠금 해제·비밀번호 변경·이메일 변경·탈퇴): 10번 틀리면 15분(확인 중인 시도도 함께
  // 센다 — runReauthAttempt).
  reauthUser: new FailureLimiter({ max: 10, windowMs: 15 * MIN, blockMs: 15 * MIN }),
  // 계정 조회류(아이디 찾기·보안 질문 조회): 이메일로 아이디를 캐내는 걸 늦춘다.
  lookupIp: new RateLimiter({ max: 20, windowMs: 15 * MIN }),
  // 아이디 중복 확인: 입력하면서 여러 번 누르므로 넉넉하게.
  usernameCheckIp: new RateLimiter({ max: 60, windowMs: MIN }),
  // 회원가입: 한 IP에서 한 시간에 10개까지.
  registerIp: new RateLimiter({ max: 10, windowMs: HOUR }),
  // 페어링 코드(메인 HTTPS 포트 — 밖에서도 닿는다): 4자리 코드를 맞혀보는 걸 막는다. 성공한 요청도 세고, 사무실 안에서 외부
  // 주소로 붙으면 공유기 헤어핀 NAT 때문에 여러 기기가 한 IP로 보여서 10번으로는 기기 몇 대 재페어링에도 막혔다 — 100번으로
  // 늘렸다(코드는 5분 1회용이라, 한 IP가 코드 하나의 유효 시간 동안 맞힐 확률은 1만 개 중 100개 남짓 = 약 1%).
  pairIp: new RateLimiter({ max: 100, windowMs: 15 * MIN }),
  // 초대 링크 안내 페이지·설치 파일(평문 페어링 포트, 사내망 밖에서 온 요청만): 초대 토큰 맞혀보기를 늦춘다.
  invitePageIp: new RateLimiter({ max: 60, windowMs: 15 * MIN }),
  // 내 일정 ICS 구독 주소(로그인 없이 열린다 — calendarFeeds.js): 토큰은 맞힐 수 없는 길이라, 피드 계산을 반복시키는 것만 늦춘다.
  calendarFeedIp: new RateLimiter({ max: 120, windowMs: 15 * MIN }),
  // 메일 보내기(확인 코드·아이디 찾기) — 서버의 메일 계정으로 아무 주소에나 메일을 쏟아붓지 못하게(그 계정이 스팸 발송으로
  // 막힌다). 로그인 없이 부르는 길은 한 IP에서 15분에 10통.
  mailSendIp: new RateLimiter({ max: 10, windowMs: 15 * MIN }),
  // 한 주소로는 어느 목적이든 한 시간에 5통(emailCodes.js — 키는 주소의 조회용 해시).
  mailSendAddress: new RateLimiter({ max: 5, windowMs: HOUR }),
  // 로그인한 사람의 이메일 확인·변경 코드 — 한 계정에서 한 시간에 10통.
  mailSendUser: new RateLimiter({ max: 10, windowMs: HOUR }),
  // 초대 메일 — 한 계정에서 한 시간에 50통(한 번에 최대 20명 — mailRules.js INVITE_MAIL_MAX_RECIPIENTS).
  inviteMailUser: new RateLimiter({ max: 50, windowMs: HOUR }),
  // 결재 올리기(groupware.js) — 한 계정에서 한 시간에 30건(결재자에게 알림이 가서 남발하면 그대로 괴롭힘이 된다).
  approvalCreateUser: new RateLimiter({ max: 30, windowMs: HOUR }),
};

setInterval(() => {
  for (const l of Object.values(limits)) l.prune();
}, 10 * MIN).unref();

export function minutesText(ms) {
  const minutes = Math.ceil(ms / MIN);
  return minutes >= 60 ? `${Math.ceil(minutes / 60)}시간` : `${minutes}분`;
}

/** 남은 시간 표기 — 1분이 안 되면 초(예: 5초), 그 이상은 minutesText. 몇 초 뒤면 되는데 "1분 후"라고 하지 않으려고. */
export function waitText(ms) {
  return ms < MIN ? `${Math.max(1, Math.ceil(ms / 1000))}초` : minutesText(ms);
}

/** 429 응답(Retry-After 포함). */
export function tooMany(res, ms, what = '시도') {
  res.set('Retry-After', String(Math.ceil(ms / 1000)));
  return res.status(429).json({ error: `${what}가 너무 많습니다. ${minutesText(ms)} 후 다시 시도하세요.` });
}

/** 429 응답 — Retry-After(초)와 문구([error])를 직접 준다(로그인 차례 기다리기처럼 tooMany의 문구가 맞지 않을 때). */
export function retryLater(res, ms, error) {
  res.set('Retry-After', String(Math.max(1, Math.ceil(ms / 1000))));
  return res.status(429).json({ error });
}

/** RateLimiter를 Express 미들웨어로 — IP 단위(밖의 IPv6는 /64 단위 — ipKey). */
export function rateLimit(limiter, what) {
  return (req, res, next) => {
    const wait = limiter.hit(clientIpKey(req));
    if (wait > 0) return tooMany(res, wait, what);
    next();
  };
}

/** 아이디는 대소문자·공백만 다르게 넣어 제한을 피하지 못하게 정규화해서 키로 쓴다. */
export function userKey(username) {
  return String(username ?? '').trim().toLowerCase();
}

/**
 * 새로 정하는 아이디의 규칙 — 영문·숫자와 . _ - 만, 4~20자. 아이디는 다른 사람이 "이 사람이 맞는지" 확인하는 유일한 값이라,
 * 띄어쓰기·대소문자·모양이 비슷한 다른 글자(키릴 문자 а 등)로 기존 아이디를 흉내 내지 못하게 한다. 대소문자만 다른 아이디도
 * 같은 아이디로 보고 새로 받지 않는다(auth.js 가입·중복 확인). 이 규칙 전에 가입한 계정은 다른 글자가 들어 있을 수 있어서
 * 로그인은 그대로 받는다(pickUsernameMatch). 클라이언트 login_screen.dart의 kSignupUsernamePattern과 같게 맞춘다.
 */
export const USERNAME_PATTERN = /^[A-Za-z0-9._-]{4,20}$/;
export const USERNAME_RULE_ERROR =
  '아이디는 영문·숫자와 . _ - 만 써서 4~20자로 정하세요(한글·띄어쓰기·그 밖의 기호는 쓸 수 없습니다).';

/** 가입·중복 확인에 온 아이디 — 앞뒤 공백을 떼고 규칙(USERNAME_PATTERN)을 본다. `{ username }` | `{ error }`. */
export function parseNewUsername(value) {
  if (typeof value !== 'string') return { error: USERNAME_RULE_ERROR };
  const username = value.trim();
  return USERNAME_PATTERN.test(username) ? { username } : { error: USERNAME_RULE_ERROR };
}

/**
 * 로그인·비밀번호 찾기에서 아이디로 계정 고르기 — [candidates]는 아이디가 [input](앞뒤 공백을 뗀 값)과 대소문자를 무시하고
 * 같은 계정들(글자까지 같은 계정도 들어 있을 수 있다). 글자까지 같은 계정이 있으면 그것, 없으면 대소문자만 다른 계정이 하나일
 * 때만 그것이다. 둘 이상이면(이 규칙 전에 'Kim'과 'kim'이 따로 가입한 서버) 누구인지 모르니 고르지 않는다(ambiguous) — 그때는
 * 대소문자까지 똑같이 넣어야 한다. scripts/grant-server-admin.mjs의 decideGrant와 같은 규칙이다. `{ user, ambiguous }`.
 */
export function pickUsernameMatch(candidates, input) {
  const name = typeof input === 'string' ? input.trim() : '';
  if (!name) return { user: null, ambiguous: false };
  const exact = candidates.find((c) => c.username === name);
  if (exact) return { user: exact, ambiguous: false };
  const folded = name.toLowerCase();
  const loose = candidates.filter((c) => typeof c.username === 'string' && c.username.toLowerCase() === folded);
  return loose.length === 1 ? { user: loose[0], ambiguous: false } : { user: null, ambiguous: loose.length > 1 };
}

export const LOGIN_FAILED_ERROR = '아이디 또는 비밀번호가 올바르지 않습니다.';
/**
 * 사내망 밖에서 짧은 비밀번호로 로그인하려 할 때 — 비밀번호가 맞든 틀리든 같은 문구다(맞는지는 보지도 않는다). 예전엔 맞혔을
 * 때만 이 안내가 나와서, 밖의 공격자가 짧은 옛 비밀번호를 맞혀 보면 "틀림"과 "맞았지만 짧음"이 갈려 비밀번호를 알아낼 수 있었다.
 */
export const OUTSIDE_SHORT_PASSWORD_ERROR =
  `사내망 밖에서는 ${PASSWORD_MIN_LENGTH}자 이상인 비밀번호로만 로그인할 수 있습니다. ` +
  `비밀번호가 ${PASSWORD_MIN_LENGTH}자보다 짧다면 사내 와이파이에서 로그인해 비밀번호를 바꾼 뒤 다시 시도하세요.`;

/** 로그인 제한 기록의 키들 — IP는 ipKey, 아이디는 userKey. */
export function loginKeys(ip, username) {
  const ipk = ipKey(ip);
  const uk = userKey(username);
  return { external: !isLanAddress(ip), ipk, uk, ipUser: `${ipk}|${uk}` };
}

const sleepMs = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/** 로그인 429 문구 — 막혔거나, 확인 중인 시도로 남은 횟수가 다 찼을 때. */
const loginTooManyError = (ms) => `로그인 시도가 너무 많습니다. ${waitText(ms)} 후 다시 시도하세요.`;

/**
 * 사내망 밖 전체가 공격받아 처음 보는 곳의 로그인을 차례대로 받는 중인데 차례를 못 받았을 때(LoginSlowdown.take) — 직원이
 * 보더라도 무엇을 하면 되는지 알 수 있게, 언제 다시 하면 되는지와 사내에서는 바로 된다는 것을 함께 알려 준다.
 */
export const outsideLoginQueueError = (ms) =>
  `지금 사내망 밖에서 로그인 시도가 몰려 차례대로 받고 있습니다. ${waitText(ms)} 후 다시 시도하세요. ` +
  '사내 와이파이에서는 바로 로그인됩니다.';

/**
 * 로그인 한 번의 판단 순서를 한곳에 둔다(auth.js POST /auth/login이 부른다). DB·bcrypt·기록은 넘겨받는다:
 *  - [findAccount](username) → 계정 또는 null
 *  - [checkPassword](password, user | null) → 맞으면 true(계정이 없을 때도 더미 해시와 비교해 걸리는 시간을 맞춘다)
 *  - [report]({ ip, username, user, detail }) → 잠금·차례 받기 시작을 콘솔·감사 로그에
 * 순서: ① 막혔거나 확인 중인 시도로 남은 횟수가 다 찼으면 429 ② 밖에서 짧은 비밀번호는 계정을 찾지도, 비밀번호를 맞춰 보지도
 * 않고 늘 같은 문구로 거절하고 실패로 센다 ③ 밖 전체가 공격받는 중이면 처음 보는 곳은 차례를 받아 기다린다(LoginSlowdown —
 * 차례를 못 받으면 429) ④ ①을 다시 보면서 이 확인을 "확인 중"으로 걸고(beginAttempts) 계정·비밀번호를 확인한다 ⑤ 탈퇴·정지
 * 안내 ⑥ 성공일 때만 실패 기록을 지우고 "최근 성공한 곳"으로 기억한다(탈퇴·정지·짧은 비밀번호는 성공이 아니다).
 * 돌려주는 값: `{ wait, error }`(429 — ms와 문구) | `{ status, error }` | `{ user }`(성공).
 */
export async function runLoginAttempt({ ip, username, password, findAccount, checkPassword, report, guard = limits, sleep = sleepMs }) {
  const { external, ipk, uk, ipUser } = loginKeys(ip, username);
  // 같은 IP·아이디, 같은 IP(여러 아이디), 사내망 밖에서 한 아이디 — 막혀 있는 동안은 비밀번호가 맞아도 들여보내지 않는다.
  const slots = [
    [guard.loginIpUser, ipUser],
    [guard.loginIp, ipk],
  ];
  if (external) slots.push([guard.loginUserExternal, uk]);
  const tooManyAttempts = (wait) => ({ wait, error: loginTooManyError(wait) });

  // ① 차례를 기다리기 전에 먼저 본다 — 어차피 못 들어갈 요청이 아래 줄의 자리를 쓰지 않게.
  const early = waitBeforeAttempt(slots);
  if (early > 0) return tooManyAttempts(early);

  // [global]: 밖 전체의 오류(차례 받기를 켜는 수)에도 넣을지.
  const countFailure = (user, { global }) => {
    if (guard.loginIpUser.fail(ipUser)) {
      report({ ip, username: uk, user, detail: `비밀번호 5회 오류 — 이 IP에서 이 아이디 ${minutesText(guard.loginIpUser.blockMs)} 로그인 차단` });
    }
    if (guard.loginIp.fail(ipk)) {
      report({ ip, username: uk, user, detail: `한 IP에서 여러 아이디로 비밀번호 20회 오류 — 이 IP ${minutesText(guard.loginIp.blockMs)} 로그인 차단` });
    }
    if (!external) return;
    if (guard.loginUserExternal.fail(uk)) {
      report({ ip, username: uk, user, detail: `사내망 밖에서 이 아이디로 비밀번호 20회 오류 — 밖에서는 ${minutesText(guard.loginUserExternal.blockMs)} 로그인 차단(사내에서는 가능)` });
    }
    if (!global) return;
    const slowdown = guard.loginExternalSlowdown;
    const raised = slowdown.fail();
    if (raised) {
      report({
        ip,
        username: uk,
        user: null,
        detail:
          `사내망 밖 전체에서 최근 ${minutesText(slowdown.windowMs)} 동안 비밀번호 오류 ${raised.count}회` +
          `${raised.inFlight > 0 ? `와 확인 중인 시도 ${raised.inFlight}개` : ''}(기준 ${slowdown.budget}회) — ` +
          `여러 IP에서 비밀번호를 넣어 보는 공격으로 보여, 밖에서 처음 보는 곳의 로그인은 줄을 세워 ${waitText(raised.intervalMs)}에 ` +
          `하나씩만 비밀번호를 확인합니다(차례가 ${waitText(slowdown.maxWaitMs)} 넘게 밀리면 잠시 뒤 다시 하라고 안내). ` +
          '최근 그곳에서 로그인에 성공한 사람과 사내에서는 그대로 로그인됩니다. ' +
          `오류가 ${Math.ceil(slowdown.budget / 2)}회 아래로 줄면 저절로 풀립니다.`,
      });
    }
  };

  // ② 밖에서 짧은 비밀번호 — 맞는지 보지 않으니 알아낼 것이 없다. IP·아이디 제한에는 실패로 세지만 밖 전체의 오류에는 넣지
  // 않는다: 아무것도 맞춰 보지 못하는 값싼 요청만으로 직원들의 밖 로그인을 줄 세우거나 간격을 늘리지 못하게.
  if (external && String(password ?? '').length < PASSWORD_MIN_LENGTH) {
    countFailure(null, { global: false });
    return { status: 401, error: OUTSIDE_SHORT_PASSWORD_ERROR };
  }

  // ③ 밖에서 처음 보는 곳은 차례를 받는다 — 평소엔 바로 받지만(확인 중인 수만 센다), 밖 전체가 공격받는 중이면 몇 개를 동시에
  // 보내든 정해진 간격으로만 확인에 들어간다.
  const turn = external && !guard.recentLogins.has(ipUser) ? guard.loginExternalSlowdown.take(ipk) : null;
  if (turn?.retryMs) return { wait: turn.retryMs, error: outsideLoginQueueError(turn.retryMs) };
  try {
    if (turn?.waitMs > 0) await sleep(turn.waitMs);

    // ④ 이 확인을 "확인 중"으로 건다 — 기다리는 사이 막혔을 수 있어 다시 보고, 보는 것과 거는 것 사이에 await가 없어서 한꺼번에
    // 보낸 요청들이 남은 횟수보다 많이 비밀번호를 맞춰 보지 못한다. 오류로 끝나도 finally에서 놓는다.
    const attempt = beginAttempts(slots);
    if (attempt.wait > 0) return tooManyAttempts(attempt.wait);
    try {
      const user = await findAccount(username);
      const passwordOk = await checkPassword(String(password ?? ''), user);
      // 결과가 났다 — 밖 전체의 오류로 세기 전에 "확인 중"에서 뺀다(같은 시도를 두 번 세지 않게).
      turn?.finished();
      if (!user || !passwordOk) {
        countFailure(user, { global: true });
        return { status: 401, error: LOGIN_FAILED_ERROR };
      }
      if (user.deletedAt) return { status: 403, error: '탈퇴한 계정입니다.' };
      if (user.suspendedAt) return { status: 403, error: '정지된 계정입니다. 서버 운영자에게 문의하세요.' };
      guard.loginIpUser.reset(ipUser);
      if (external) guard.recentLogins.remember(ipUser);
      return { user };
    } finally {
      attempt.release();
    }
  } finally {
    turn?.finished();
  }
}

/** 비밀번호 재확인 429 문구 — 막혔거나, 확인 중인 시도로 남은 횟수가 다 찼을 때(예전 문구 그대로, 1분이 안 남았으면 초로). */
export const reauthTooManyError = (ms) => `비밀번호 확인 시도가 너무 많습니다. ${waitText(ms)} 후 다시 시도하세요.`;

/**
 * 로그인한 사람의 비밀번호 재확인 한 번(화면 잠금 해제·이메일 변경·비밀번호 변경·탈퇴 — users.js checkCurrentPassword). 훔친
 * AccessToken만 가진 사람이 비밀번호를 맞혀 보지 못하게 계정마다([key] — 계정 id) [guard.reauthUser]로 센다(10번 틀리면 15분).
 *
 * 로그인(runLoginAttempt)·비밀번호 찾기(auth.js recoveryGuard)와 같이 확인을 시작하기 전에 "확인 중"으로 걸어 둔다(beginAttempts).
 * 예전엔 막혔는지만 보고 bcrypt를 기다린 뒤에야 틀린 것을 세서, 한꺼번에 보낸 요청 N개가 모두 "아직 0번 틀림"을 보고 들어가
 * 15분에 10번 제한인데도 N번을 맞춰 볼 수 있었다. 이제는 창 안의 실패와 확인 중인 시도를 더해 10이 차면 더 시작하지 않는다 —
 * 확인 중인 것이 모두 틀리면 그것만으로 막히므로, 몇 개를 한꺼번에 보내든 그보다 많이 맞춰 보지 못한다. 보는 것과 거는 것
 * 사이에 await가 없다(beginAttempts).
 *
 * [checkPassword](password) → 맞으면 true. 비밀번호가 비었으면 맞춰 보지 않고 틀린 것으로 센다(예전과 같다). checkPassword가 던지면
 * 실패로 세지 않고 그대로 던진다. 어떻게 끝나든 "확인 중"은 finally에서 놓는다 — 안 놓으면 그 계정의 칸이 꽉 찬 채로 남아 본인도
 * 다시 확인하지 못한다. 틀린 것은 놓기 전에 센다(놓은 틈에 다른 요청이 빈자리를 보고 들어오지 못하게).
 * 돌려주는 값: `{ wait, error }`(429 — ms와 문구) | `{ ok: false }`(틀림 — 실패로 셌다) | `{ ok: true }`(맞음 — 틀린 기록을 지웠다).
 */
export async function runReauthAttempt({ key, password, checkPassword, guard = limits }) {
  const attempt = beginAttempts([[guard.reauthUser, key]]);
  if (attempt.wait > 0) return { wait: attempt.wait, error: reauthTooManyError(attempt.wait) };
  try {
    if (!password || !(await checkPassword(String(password)))) {
      guard.reauthUser.fail(key);
      return { ok: false };
    }
    guard.reauthUser.reset(key);
    return { ok: true };
  } finally {
    attempt.release();
  }
}
