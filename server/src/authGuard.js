import net from 'node:net';

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

/**
 * 실패 횟수 기반 차단. [windowMs] 안에 [max]번 실패하면 [blockMs] 동안 막는다. 차단이 풀리면
 * 처음부터 다시 센다. [now]는 테스트용.
 */
export class FailureLimiter {
  constructor({ max, windowMs, blockMs, now = () => Date.now() }) {
    Object.assign(this, { max, windowMs, blockMs, now });
    this.entries = new Map(); // key → { count, firstAt, blockedUntil }
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

  /** 실패 한 번. 이번 실패로 막히기 시작했으면 true. */
  fail(key) {
    const t = this.now();
    let e = this.entries.get(key);
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

  /** 오래된 기록 정리(주기적으로 부른다). */
  prune() {
    const t = this.now();
    for (const [key, e] of this.entries) {
      if (e.blockedUntil ? e.blockedUntil <= t : t - e.firstAt > this.windowMs) this.entries.delete(key);
    }
  }
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

/** 이 서버가 쓰는 제한값 — 숫자를 한곳에서 보고 고칠 수 있게 모아둔다. */
export const limits = {
  // 비밀번호: 같은 IP·같은 아이디로 5번 틀리면 15분.
  loginIpUser: new FailureLimiter({ max: 5, windowMs: 15 * MIN, blockMs: 15 * MIN }),
  // 비밀번호: 한 IP가 여러 아이디에 걸쳐 20번 틀리면 30분(아이디를 바꿔가며 흔한 비밀번호를 넣어보는 공격).
  loginIp: new FailureLimiter({ max: 20, windowMs: 15 * MIN, blockMs: 30 * MIN }),
  // 비밀번호: 한 아이디가 사내망 밖 여러 IP에서 20번 틀리면 1시간 — 사내에서는 그대로 로그인된다.
  loginUserExternal: new FailureLimiter({ max: 20, windowMs: HOUR, blockMs: HOUR }),
  // 보안 질문 답(비밀번호 재설정): 답은 짧고 추측하기 쉬워 더 엄격하게 — 같은 IP·아이디로 3번 틀리면 30분.
  recoveryIpUser: new FailureLimiter({ max: 3, windowMs: 30 * MIN, blockMs: 30 * MIN }),
  // 보안 질문 답: 한 아이디가 사내망 밖에서 하루에 10번 틀리면 하루 동안 밖에서는 재설정 불가.
  recoveryUserExternal: new FailureLimiter({ max: 10, windowMs: 24 * HOUR, blockMs: 24 * HOUR }),
  // 로그인한 사용자의 비밀번호 재확인(화면 잠금 해제·비밀번호 변경·이메일 변경·탈퇴): 10번 틀리면 15분.
  reauthUser: new FailureLimiter({ max: 10, windowMs: 15 * MIN, blockMs: 15 * MIN }),
  // 계정 조회류(아이디 찾기·보안 질문 조회): 이메일로 아이디를 캐내는 걸 늦춘다.
  lookupIp: new RateLimiter({ max: 20, windowMs: 15 * MIN }),
  // 아이디 중복 확인: 입력하면서 여러 번 누르므로 넉넉하게.
  usernameCheckIp: new RateLimiter({ max: 60, windowMs: MIN }),
  // 회원가입: 한 IP에서 한 시간에 10개까지.
  registerIp: new RateLimiter({ max: 10, windowMs: HOUR }),
  // 페어링 코드(메인 HTTPS 포트 — 밖에서도 닿는다): 4자리 코드를 맞혀보는 걸 막는다.
  pairIp: new RateLimiter({ max: 10, windowMs: 15 * MIN }),
  // 초대 링크 안내 페이지·설치 파일(평문 페어링 포트, 사내망 밖에서 온 요청만): 초대 토큰 맞혀보기를 늦춘다.
  invitePageIp: new RateLimiter({ max: 60, windowMs: 15 * MIN }),
};

setInterval(() => {
  for (const l of Object.values(limits)) l.prune();
}, 10 * MIN).unref();

export function minutesText(ms) {
  const minutes = Math.ceil(ms / MIN);
  return minutes >= 60 ? `${Math.ceil(minutes / 60)}시간` : `${minutes}분`;
}

/** 429 응답(Retry-After 포함). */
export function tooMany(res, ms, what = '시도') {
  res.set('Retry-After', String(Math.ceil(ms / 1000)));
  return res.status(429).json({ error: `${what}가 너무 많습니다. ${minutesText(ms)} 후 다시 시도하세요.` });
}

/** RateLimiter를 Express 미들웨어로. */
export function rateLimit(limiter, what) {
  return (req, res, next) => {
    const wait = limiter.hit(clientIp(req));
    if (wait > 0) return tooMany(res, wait, what);
    next();
  };
}

/** 아이디는 대소문자·공백만 다르게 넣어 제한을 피하지 못하게 정규화해서 키로 쓴다. */
export function userKey(username) {
  return String(username ?? '').trim().toLowerCase();
}
