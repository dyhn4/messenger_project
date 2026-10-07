import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

/**
 * 웹 앱 전용 주소(WEB_DOMAIN)의 Let's Encrypt 인증서를 언제 받고 언제 다시 시도할지 정하는 쪽(webTls.js가 쓴다). 실제 발급
 * (acme-client)은 [issue]로 받아서 부르기만 하므로, 테스트는 가짜 시계·타이머·발급 함수로 이 규칙만 확인할 수 있다.
 *
 * 규칙:
 *  - 서버를 켤 때와 12시간마다 확인해서, 인증서가 없거나 만료까지 30일(수명이 짧은 인증서면 수명의 1/3)보다 적게 남았으면 받는다.
 *  - 실패하면 1시간 → 2시간 → … → 최대 24시간 간격으로 다시 시도한다. Let's Encrypt가 발급 한도(rateLimited)로 거절하면서
 *    Retry-After를 주면 그 시각 전에는 절대 다시 묻지 않는다.
 *  - 다음 시도 시각을 certs/acme-state.json에 남긴다 — 시도하기 **전에** 먼저 "실패하면 이때 다시"를 적어 두므로, 발급 도중에
 *    서버가 죽거나 서비스가 계속 재시작해도 Let's Encrypt에 연달아 요청하지 않는다.
 *  - 서버 PC 시계가 틀린 경우: 받은 인증서가 이 PC 시계로 이미 만료이거나 받자마자 갱신할 때면(시계가 몇 달 앞서 있음) 이틀에 한 번만
 *    다시 받는다. 시계가 앞서 있던 동안 적힌 기록(먼 미래의 다음 시도 시각)은 시계를 고친 뒤 알아채고 버린다(reconcileClock).
 */

const MINUTE = 60 * 1000;
const HOUR = 60 * MINUTE;
const DAY = 24 * HOUR;

export const CHECK_INTERVAL_MS = 12 * HOUR;
export const RENEW_BEFORE_MS = 30 * DAY;
export const BACKOFF_MIN_MS = HOUR;
export const BACKOFF_MAX_MS = 24 * HOUR;
// Let's Encrypt가 준 Retry-After의 상한 — 주간 한도도 7일이면 풀린다. 이상한 값 하나로 몇 달씩 멈춰 있지 않게 자른다.
export const MAX_RETRY_AFTER_MS = 8 * DAY;
// 한도에 걸렸는데 언제 풀리는지 안 알려 주면 하루 뒤에 다시 묻는다.
export const RATE_LIMIT_DEFAULT_MS = DAY;
// 발급 한 번이 이보다 오래 걸리면(정상은 1분 안쪽) 실패로 치고 다음 시도를 잡는다 — 어디선가 응답이 영영 안 와도 갱신이 멈추지 않게.
export const ATTEMPT_GUARD_MS = 30 * MINUTE;
// 시계가 틀려서(받은 인증서가 이 PC 시계로 이미 만료이거나 받자마자 갱신할 때) 생긴 일 뒤에는 이만큼 기다린다 — 시계를 고치기 전에는
// 다시 받아도 똑같아서 Let's Encrypt의 "같은 이름 인증서 7일에 5장" 한도만 쓴다(이틀 간격이면 일주일에 3~4장으로 그 안쪽이다).
// 시계를 뒤로 고치면 reconcileClock이 알아채고 이 대기를 앞당긴다.
export const CLOCK_RETRY_MS = 2 * DAY;
// 기록된 시각이 지금보다 이만큼 넘게 뒤면 시계가 뒤로 바뀐 것(앞서 가던 시계로 적은 기록)으로 본다 — NTP가 몇 초·몇 분 고치는 건 무시.
export const CLOCK_SKEW_TOLERANCE_MS = HOUR;
// 기록에 남길 수 있는 시각의 상한(JavaScript Date의 끝) — 깨진 파일의 엉뚱한 큰 수는 없는 값으로 본다.
const MAX_TIME_MS = 8.64e15;
// 타이머 간격의 하한 — 계산이 어긋나도 1초보다 촘촘히 돌지 않는다.
const MIN_TIMER_MS = 1000;

const STATE_VERSION = 1;

/** [failures]번째 연속 실패 뒤 기다릴 시간 — 1시간에서 두 배씩, 최대 24시간. */
export function backoffDelay(failures) {
  const n = Math.max(1, Math.floor(failures));
  return Math.min(BACKOFF_MIN_MS * 2 ** Math.min(n - 1, 16), BACKOFF_MAX_MS);
}

/** 이만큼 남았으면 갱신한다 — 보통의 90일짜리는 30일, 그보다 짧은 인증서는 수명의 1/3(발급 직후부터 갱신을 되풀이하지 않게). */
export function renewWindowMs({ notBefore, notAfter }) {
  const lifetime = notAfter - notBefore;
  return lifetime > 0 ? Math.min(RENEW_BEFORE_MS, Math.floor(lifetime / 3)) : RENEW_BEFORE_MS;
}

/** Let's Encrypt 시험용(staging) 인증서인지 — 발급자 이름에 "(STAGING)"(예전엔 "Fake LE")이 붙는다. 브라우저가 신뢰하지 않는다. */
export function isStagingIssuer(issuer) {
  return /\(STAGING\)|Fake LE/i.test(String(issuer ?? ''));
}

/**
 * 인증서(PEM, 체인 가능)와 개인키가 [domain]용으로 쓸 수 있는 짝인지 본다. 유효기간은 여기서 판단하지 않고 날짜만 돌려준다.
 * @returns {{ok: true, notBefore: number, notAfter: number, issuer: string, staging: boolean, fingerprint: string}
 *   | {ok: false, reason: 'parse'|'domain'|'key', message: string}}
 */
export function inspectCertificate({ certPem, keyPem }, { domain }) {
  let x509;
  try {
    x509 = new crypto.X509Certificate(certPem);
  } catch (e) {
    return { ok: false, reason: 'parse', message: `인증서를 읽지 못했습니다(${e.message})` };
  }
  if (!x509.checkHost(domain)) return { ok: false, reason: 'domain', message: `인증서가 ${domain}용이 아닙니다` };
  try {
    if (!x509.checkPrivateKey(crypto.createPrivateKey(keyPem))) {
      return { ok: false, reason: 'key', message: '인증서와 개인키가 짝이 맞지 않습니다' };
    }
  } catch (e) {
    return { ok: false, reason: 'key', message: `개인키를 읽지 못했습니다(${e.message})` };
  }
  const notBefore = x509.validFromDate?.getTime() ?? Date.parse(x509.validFrom);
  const notAfter = x509.validToDate?.getTime() ?? Date.parse(x509.validTo);
  if (!Number.isFinite(notBefore) || !Number.isFinite(notAfter)) {
    return { ok: false, reason: 'parse', message: '인증서의 유효기간을 읽지 못했습니다' };
  }
  const staging = isStagingIssuer(x509.issuer);
  return { ok: true, notBefore, notAfter, issuer: x509.issuer, staging, fingerprint: x509.fingerprint256 };
}

/**
 * certs/ 안의 파일들 — 웹 인증서(web.crt 체인·web.key)와 시도 기록(acme-state.json). 기존 자체 서명 인증서(cert.pem·key.pem)와
 * 같은 폴더라 설치 프로그램이 거는 관리자 전용 권한(Folder-Acl.ps1)이 그대로 적용된다.
 */
export function createCertificateStore({ certsDir }) {
  const certFile = path.join(certsDir, 'web.crt');
  const keyFile = path.join(certsDir, 'web.key');
  const stateFile = path.join(certsDir, 'acme-state.json');

  return {
    certFile,
    keyFile,
    stateFile,
    /** 저장된 인증서·키(PEM). 없으면 null — 읽다가 난 다른 오류는 그대로 던진다(권한 문제 등은 로그로 알려야 한다). */
    readCertificate() {
      try {
        return { certPem: fs.readFileSync(certFile, 'utf8'), keyPem: fs.readFileSync(keyFile, 'utf8') };
      } catch (e) {
        if (e.code === 'ENOENT') return null;
        throw e;
      }
    },
    writeCertificate({ certPem, keyPem }) {
      fs.mkdirSync(certsDir, { recursive: true });
      // 키를 먼저 쓴다 — 둘 사이에 꺼져서 짝이 안 맞으면 다음 실행 때 inspectCertificate가 걸러 내고 새로 받는다.
      writeFileAtomic(keyFile, keyPem, 0o600);
      writeFileAtomic(certFile, certPem, 0o644);
    },
    readState() {
      try {
        const parsed = JSON.parse(fs.readFileSync(stateFile, 'utf8'));
        return parsed && typeof parsed === 'object' ? parsed : null;
      } catch {
        return null; // 없거나 깨졌으면 처음부터 — 다음 시도 시각만 잃는다(최악이어도 지금 한 번 묻는다).
      }
    },
    writeState(state) {
      fs.mkdirSync(certsDir, { recursive: true });
      writeFileAtomic(stateFile, `${JSON.stringify(state, null, 2)}\n`, 0o600);
    },
  };
}

/** 임시 파일에 쓰고 이름을 바꾼다 — 쓰는 도중에 꺼져도 반쯤 쓴 파일이 남지 않게. 백신 등이 파일을 잡고 있어 바꾸지 못하면 바로 쓴다. */
function writeFileAtomic(file, data, mode) {
  const tmp = `${file}.${process.pid}.tmp`;
  try {
    fs.writeFileSync(tmp, data, { mode });
    fs.renameSync(tmp, file);
  } catch (e) {
    try {
      fs.rmSync(tmp, { force: true });
    } catch {
      /* 임시 파일 정리는 실패해도 그만 */
    }
    if (e.code !== 'EPERM' && e.code !== 'EBUSY' && e.code !== 'EACCES') throw e;
    fs.writeFileSync(file, data, { mode });
  }
}

/** 시도 기록을 지금 설정에 맞춘다 — 도메인이나 staging 설정이 바뀌었으면 예전 기록(대기 시각·실패 횟수)은 상관없으니 새로 시작한다. */
function normalizeState(saved, { domain, staging }) {
  const fresh = {
    version: STATE_VERSION,
    domain,
    staging,
    failures: 0,
    nextAttemptAt: null,
    lastAttemptAt: null,
    lastError: null,
    lastErrorKind: null,
    preferredChallenge: null,
  };
  if (!saved || saved.domain !== domain || !!saved.staging !== staging) return { fresh: true, state: fresh };
  // 지금 시각과 견줘 말이 되는지는 여기가 아니라 reconcileClock이 본다(시계는 서버가 도는 중에도 바뀐다).
  const num = (v) => (Number.isFinite(v) && v > 0 && v <= MAX_TIME_MS ? v : null);
  return {
    fresh: false,
    state: {
      ...fresh,
      failures: Number.isInteger(saved.failures) && saved.failures > 0 ? saved.failures : 0,
      nextAttemptAt: num(saved.nextAttemptAt),
      lastAttemptAt: num(saved.lastAttemptAt),
      lastError: typeof saved.lastError === 'string' ? saved.lastError : null,
      lastErrorKind: typeof saved.lastErrorKind === 'string' ? saved.lastErrorKind : null,
      preferredChallenge: typeof saved.preferredChallenge === 'string' ? saved.preferredChallenge : null,
    },
  };
}

/** 로그·안내 문구용 시각(서버 PC의 시간대). */
export function formatTime(ms) {
  return new Date(ms).toLocaleString('ko-KR', { hour12: false });
}

function formatDuration(ms) {
  if (ms >= DAY) return `${Math.round(ms / DAY)}일`;
  if (ms >= HOUR) return `${Math.round(ms / HOUR)}시간`;
  return `${Math.max(1, Math.round(ms / MINUTE))}분`;
}

/**
 * 인증서 발급·갱신 일정. 만들 때 저장된 인증서와 시도 기록을 읽고([current]), start()부터 확인을 시작한다.
 *
 * @param {object} o
 * @param {string} o.domain
 * @param {boolean} o.staging Let's Encrypt 시험용 디렉터리를 쓰는지(그때만 시험용 인증서도 "쓸 수 있는 것"으로 본다)
 * @param {ReturnType<typeof createCertificateStore>} o.store
 * @param {(opts: {challengeTypes: string[]}) => Promise<{certPem: string, keyPem: string, challengeType?: string}>} o.issue
 *   실패하면 {kind, message, retryAfterMs, detail}을 가진 오류를 던진다(acme.js의 AcmeIssueError).
 * @param {() => string[]} o.getChallengeTypes 지금 쓸 수 있는 인증 방식(열린 포트 기준, 먼저 시도할 순서대로). 비었으면 발급하지 않는다.
 * @param {() => string|null} [o.getWaitingReason] 인증 방식이 없을 때 상태에 보여 줄 이유.
 * @param {(cert) => void} [o.onCertificate] 새 인증서를 받았을 때(웹 포트에 바로 건다).
 * @param {() => void} [o.onChange] 상태가 바뀔 때마다(공개 주소 갱신용).
 */
export function createCertificateRenewer({
  domain,
  staging,
  store,
  issue,
  getChallengeTypes,
  getWaitingReason = () => null,
  onCertificate = () => {},
  onChange = () => {},
  now = () => Date.now(),
  setTimer = setTimeout,
  clearTimer = clearTimeout,
  log = console,
}) {
  const tag = '[web-tls]';
  const loaded = normalizeState(safely(() => store.readState(), null), { domain, staging });
  let state = loaded.state;
  let current = null; // { certPem, keyPem, notBefore, notAfter, issuer, staging, fingerprint }
  let timer = null;
  let running = false;
  let started = false;
  let stopped = false;

  function safely(fn, fallback) {
    try {
      return fn();
    } catch (e) {
      log.error(`${tag} 인증서 파일을 다루다 오류가 났습니다:`, e?.message ?? e);
      return fallback;
    }
  }

  // 저장된 인증서 — 이 도메인용이고 짝이 맞고 아직 유효하면 바로 쓴다. 시험용(staging) 인증서는 staging 설정일 때만.
  const stored = safely(() => store.readCertificate(), null);
  if (stored) {
    const info = inspectCertificate(stored, { domain });
    const t = now();
    if (!info.ok) {
      log.warn(`${tag} 저장된 인증서(${store.certFile})를 쓸 수 없습니다: ${info.message} — 새로 받습니다.`);
    } else if (info.staging && !staging) {
      log.log(`${tag} 저장된 인증서는 시험용(staging)이라 정식 인증서를 새로 받습니다.`);
    } else if (t >= info.notAfter) {
      log.log(`${tag} 저장된 인증서가 ${formatTime(info.notAfter)}에 만료되어 새로 받습니다.`);
    } else {
      current = { ...stored, ...info };
      const left = formatDuration(info.notAfter - t);
      log.log(`${tag} 저장된 인증서를 씁니다 — 만료 ${formatTime(info.notAfter)} (${left} 남음)${info.staging ? ', 시험용(staging)' : ''}.`);
    }
  }
  // 시계가 앞서 가던 때 적힌 기록이면(시계를 고치고 재시작) 그 먼 미래의 대기 시각은 버린다 — 그대로 믿으면 그날까지 갱신이 멈춘다.
  reconcileClock(now());
  if (!loaded.fresh && state.nextAttemptAt && state.nextAttemptAt > now() && isDue(now())) {
    const at = formatTime(state.nextAttemptAt);
    log.log(`${tag} 지난번 발급이 실패(또는 중단)해 ${at}에 다시 시도합니다(재시작해도 앞당기지 않습니다 — Let's Encrypt 요청 한도 보호).`);
  }

  /** 시도 기록을 파일에 남긴다. 못 남겼으면 false. */
  function saveState() {
    return safely(() => {
      store.writeState(state);
      return true;
    }, false);
  }

  function isValid(t = now()) {
    return !!current && t < current.notAfter;
  }

  function renewAt() {
    return current ? current.notAfter - renewWindowMs(current) : null;
  }

  function isDue(t) {
    return !isValid(t) || t >= renewAt();
  }

  /**
   * 서버 PC 시계가 크게 뒤로 바뀌었으면(앞서 가던 시계로 적힌 기록이면) 그 기록의 시각을 버린다. 시계가 몇 달 앞서 있던 동안 적힌 "다음
   * 시도 시각"을 그대로 믿으면 시계를 고친 뒤에도(재시작해도) 그 날짜까지 갱신이 멈춰 인증서가 만료되고, certs/acme-state.json을 지우는
   * 것 말고는 풀 방법이 없다. 정상 기록이라면 다음 시도는 지금부터 길어야 MAX_RETRY_AFTER_MS 안이고(그보다 길게 적는 곳이 없다) 마지막
   * 시도는 지금보다 앞이다 — 어긋나면 다음 시도를 BACKOFF_MIN_MS 뒤로 당기고 로그로 알린다. 시계 때문에 난 오류(lastErrorKind
   * 'clock')는 시계가 바뀌었으니 지운다(아직도 틀렸으면 다음 시도에서 다시 알게 된다).
   * @returns {boolean} 기록을 바로잡았는지
   */
  function reconcileClock(t) {
    const nextTooFar = state.nextAttemptAt !== null && state.nextAttemptAt > t + MAX_RETRY_AFTER_MS + CLOCK_SKEW_TOLERANCE_MS;
    const lastInFuture = state.lastAttemptAt !== null && state.lastAttemptAt > t + CLOCK_SKEW_TOLERANCE_MS;
    if (!nextTooFar && !lastInFuture) return false;
    const recorded = nextTooFar ? state.nextAttemptAt : state.lastAttemptAt;
    state = {
      ...state,
      nextAttemptAt: state.nextAttemptAt === null ? null : Math.min(state.nextAttemptAt, t + BACKOFF_MIN_MS),
      lastAttemptAt: lastInFuture ? null : state.lastAttemptAt,
      ...(state.lastErrorKind === 'clock' ? { lastError: null, lastErrorKind: null } : {}),
    };
    saveState();
    const then = state.nextAttemptAt > t ? `${formatTime(state.nextAttemptAt)}부터 다시 시도합니다` : '일정을 다시 잡습니다';
    log.warn(`${tag} 서버 PC 시계가 뒤로 바뀐 것 같습니다(기록된 시각 ${formatTime(recorded)}이 지금보다 한참 뒤입니다) — 그 기록을 버리고 ${then}.`);
    return true;
  }

  /** 다음에 확인할 시각 — 12시간 뒤, 갱신 시작 시각, 만료 시각, 대기 중인 재시도 시각 중 가장 이른 때. */
  function schedule() {
    if (stopped) return;
    if (timer) clearTimer(timer);
    const t = now();
    let at = t + CHECK_INTERVAL_MS;
    if (isValid(t)) {
      if (t < renewAt()) at = Math.min(at, renewAt());
      at = Math.min(at, current.notAfter);
    }
    if (state.nextAttemptAt && state.nextAttemptAt > t) at = Math.min(at, state.nextAttemptAt);
    const delay = Math.min(Math.max(at - t, MIN_TIMER_MS), CHECK_INTERVAL_MS);
    timer = setTimer(() => {
      timer = null;
      runCheck();
    }, delay);
    timer?.unref?.();
  }

  /** check()를 부르되, 예기치 못한 예외가 나도 다음 확인 타이머는 다시 건다 — 한 번의 오류로 갱신이 영영 멈추지 않게. */
  function runCheck() {
    return check().catch((err) => {
      log.error(`${tag} 인증서 확인 중 예기치 못한 오류:`, err);
      schedule();
    });
  }

  async function check() {
    if (stopped || running) return;
    const t = now();
    // 서버가 도는 중에 시계를 고친 경우 — 타이머는 벽시계와 상관없이 돌므로 다음 확인(최대 12시간 뒤) 때 여기서 알아챈다.
    reconcileClock(t);
    if (!isDue(t)) {
      onChange();
      return schedule();
    }
    if (state.nextAttemptAt && t < state.nextAttemptAt) {
      onChange();
      return schedule();
    }
    const available = getChallengeTypes();
    if (!available.length) {
      onChange();
      return schedule(); // 포트가 열리면 webTls.js가 poke()로 다시 부른다.
    }
    // 지난번에 성공한 방식을 먼저 — 통신사가 80을 막는 곳이면 매번 HTTP-01부터 실패하고 넘어가지 않게.
    const preferred = state.preferredChallenge;
    const challengeTypes = available.includes(preferred) ? [preferred, ...available.filter((type) => type !== preferred)] : available;
    await attempt(challengeTypes, t);
    onChange();
    schedule();
  }

  async function attempt(challengeTypes, t) {
    // 시도하기 전에 "이번이 실패하면 언제 다시"를 먼저 적어 둔다 — 발급 도중 꺼지거나 재시작을 되풀이해도 그때까지 다시 묻지 않는다.
    // 적어 둘 수 없으면(certs 폴더 권한 등) 아예 묻지 않는다 — 재시작할 때마다 새로 발급받아 한도를 태우는 일이 없게.
    const writeAhead = { ...state, nextAttemptAt: t + backoffDelay(state.failures + 1) };
    state = writeAhead;
    if (!saveState()) {
      const lastError = `인증서 폴더(${path.dirname(store.stateFile)})에 기록을 남길 수 없어 발급을 미룹니다 — 폴더 권한·디스크를 확인하세요.`;
      state = { ...writeAhead, lastError, lastErrorKind: 'storage' };
      log.error(`${tag} ✖ ${lastError}`);
      return;
    }
    running = true;
    state = { ...state, lastAttemptAt: t };
    saveState();
    const reason = isValid(t) ? `만료까지 ${formatDuration(current.notAfter - t)} 남아 갱신합니다` : '인증서가 없어 발급받습니다';
    log.log(`${tag} ${reason} — Let's Encrypt${staging ? '(시험용 staging)' : ''}에 요청(인증 방식: ${challengeTypes.join(' → ')}).`);

    const work = Promise.resolve().then(() => issue({ challengeTypes }));
    let guardTimer = null;
    const guard = new Promise((_, reject) => {
      const timeout = Object.assign(new Error('인증서 발급이 30분 넘게 끝나지 않아 실패로 처리했습니다. 다음 시도 때 다시 받습니다.'), { kind: 'timeout' });
      guardTimer = setTimer(() => reject(timeout), ATTEMPT_GUARD_MS);
      guardTimer?.unref?.();
    });
    try {
      const result = await Promise.race([work, guard]);
      accept(result);
    } catch (err) {
      fail(err, t);
      // 시간 초과로 포기했어도 그 발급이 늦게라도 끝나면 그 인증서는 버리지 않고 쓴다(한도를 아끼려고).
      if (err?.kind === 'timeout') {
        work.then(
          (result) => {
            try {
              accept(result);
              onChange();
              schedule();
            } catch (e) {
              log.error(`${tag} 늦게 도착한 인증서를 쓰지 못했습니다: ${e?.message ?? e}`);
            }
          },
          () => {},
        );
      }
    } finally {
      if (guardTimer) clearTimer(guardTimer);
      running = false;
    }
  }

  /** 받은 인증서를 확인하고 저장한 뒤 건다. 확인에 실패하면 던진다(발급 실패로 처리된다). */
  function accept(result) {
    const info = inspectCertificate(result, { domain });
    if (!info.ok) throw Object.assign(new Error(`받은 인증서를 쓸 수 없습니다: ${info.message}`), { kind: 'other' });
    const t = now();
    // 방금 받은 인증서가 이 PC 시계로 이미 만료면 시계가 틀린 것이다 — 그대로 두면 다시 받을 때마다 버리며 한도를 태운다(fail()이
    // CLOCK_RETRY_MS를 띄운다).
    if (info.notAfter <= t) {
      const message = `받은 인증서(만료 ${formatTime(info.notAfter)})가 이 PC 시계로는 이미 만료입니다 — 서버 PC의 날짜·시간·시간대를 확인하세요.`;
      throw Object.assign(new Error(message), { kind: 'clock' });
    }
    current = { certPem: result.certPem, keyPem: result.keyPem, ...info };
    const saved = safely(() => {
      store.writeCertificate(result);
      return true;
    }, false);
    state = {
      ...state,
      failures: 0,
      nextAttemptAt: null,
      lastError: null,
      lastErrorKind: null,
      preferredChallenge: result.challengeType ?? state.preferredChallenge,
    };
    const kind = info.staging ? ', 시험용(staging)' : '';
    log.log(`${tag} ✔ 인증서를 받았습니다 — 만료 ${formatTime(info.notAfter)}${kind}. 웹 포트에 바로 적용합니다(재시작 필요 없음).`);
    // 방금 받은 인증서가 이 PC 시계로 벌써 갱신할 때여도(수명의 2/3이 지난 것으로 보임 — 시계가 두 달쯤 넘게 앞서 있다) 시계 문제다.
    // 인증서 자체는 브라우저 시계로 멀쩡하니 그대로 쓰되, 그냥 두면 12시간마다 새로 받으며 한도를 태우므로 다음 갱신은 CLOCK_RETRY_MS 뒤로.
    if (t >= renewAt()) {
      const lastError =
        `받은 인증서(만료 ${formatTime(info.notAfter)})가 이 PC 시계로는 벌써 갱신할 때입니다 — 서버 PC의 날짜·시간·시간대를 확인하세요. ` +
        `시계를 고칠 때까지 갱신은 ${formatDuration(CLOCK_RETRY_MS)}에 한 번만 시도합니다.`;
      state = { ...state, nextAttemptAt: t + CLOCK_RETRY_MS, lastError, lastErrorKind: 'clock' };
      log.warn(`${tag} ⚠ ${lastError}`);
    }
    if (!saved) {
      // 이번 실행에서는 메모리의 인증서로 계속 돌지만, 재시작하면 없어진다 — 재시작 직후 곧바로 또 발급받지 않도록 하루를 띄운다.
      const lastError = `인증서를 받았지만 ${store.certFile}에 저장하지 못했습니다 — 폴더 권한을 확인하세요(서버를 재시작하면 다시 받아야 합니다).`;
      state = { ...state, nextAttemptAt: Math.max(state.nextAttemptAt ?? 0, t + BACKOFF_MAX_MS), lastError, lastErrorKind: 'storage' };
      log.error(`${tag} ✖ ${lastError}`);
    }
    saveState();
    try {
      onCertificate(current);
    } catch (e) {
      // 받은 인증서·기록은 이미 저장됐다 — 거는 것만 실패했으면 발급 실패로 세지 않는다(다음 재시작 때 저장된 것으로 뜬다).
      log.error(`${tag} 새 인증서를 웹 포트에 걸지 못했습니다(서버를 다시 시작하면 적용됩니다): ${e?.message ?? e}`);
    }
  }

  function fail(err, t) {
    const failures = state.failures + 1;
    let delay = backoffDelay(failures);
    const hasRetryAfter = Number.isFinite(err?.retryAfterMs) && err.retryAfterMs > 0;
    const retryAfterMs = hasRetryAfter ? Math.min(err.retryAfterMs, MAX_RETRY_AFTER_MS) : null;
    // Retry-After는 "이 시각 전에는 묻지 말라"는 뜻이라 백오프보다 길면 그만큼 기다린다(짧으면 백오프를 지킨다 — 촘촘히 돌지 않게).
    if (retryAfterMs) delay = Math.max(delay, retryAfterMs);
    else if (err?.kind === 'rateLimited') delay = Math.max(delay, RATE_LIMIT_DEFAULT_MS);
    // 시계가 틀려 받은 인증서를 버렸다면 시계를 고치기 전에는 다시 받아도 또 버린다 — 백오프(1시간~)대로 되풀이하면 그때마다 진짜
    // 인증서가 하나씩 버려져 같은 이름 인증서 한도를 다 쓴다. 시계를 뒤로 고치면 reconcileClock이 이 대기를 앞당긴다.
    if (err?.kind === 'clock') delay = Math.max(delay, CLOCK_RETRY_MS);
    const message = typeof err?.message === 'string' && err.message ? err.message : '인증서 발급에 실패했습니다.';
    state = { ...state, failures, nextAttemptAt: t + delay, lastError: message, lastErrorKind: err?.kind ?? 'other' };
    saveState();
    log.error(`${tag} ✖ 인증서 발급 실패: ${message}`);
    if (err?.detail) log.error(`${tag}   Let's Encrypt 응답: ${err.detail}`);
    // 분류되지 않은 오류(코드 버그 등)는 원인을 찾을 수 있게 통째로 남긴다.
    if (!err?.kind) log.error(`${tag}  `, err);
    log.error(`${tag}   다음 시도: ${formatTime(t + delay)} (${formatDuration(delay)} 뒤, 연속 ${failures}번째 실패)`);
  }

  return {
    /** 지금 쓸 수 있는(유효한) 인증서 — 없으면 null. */
    get current() {
      return isValid() ? current : null;
    },
    /** 브라우저가 신뢰하는 정식 인증서가 지금 걸려 있는지(유효하고 시험용이 아님). */
    hasPublicCertificate() {
      return isValid() && !current.staging;
    },
    start() {
      if (started || stopped) return;
      started = true;
      runCheck();
    },
    /** 포트가 새로 열리는 등 조건이 바뀌었을 때 — 다음 시도 시각 규칙은 그대로 지킨다. */
    poke() {
      if (!started || stopped || running) return;
      runCheck();
    },
    stop() {
      stopped = true;
      if (timer) clearTimer(timer);
      timer = null;
    },
    /** 테스트·관리자 콘솔용 지금 상태. */
    status() {
      const t = now();
      // 관리자가 시계를 고친 뒤 콘솔을 다시 볼 때 — 다음 확인(최대 12시간 뒤)을 기다리지 않고 바로 기록을 바로잡고 일정을 다시 잡는다.
      // 발급 중에는 건드리지 않는다(끝나면 check()가 다시 본다).
      if (!running && reconcileClock(t) && started) schedule();
      let status;
      if (isValid(t)) status = t >= renewAt() ? 'expiring' : 'valid';
      else status = state.lastError ? 'error' : 'pending';
      let nextAttemptAt = null;
      if (!running) {
        if (!isDue(t)) nextAttemptAt = renewAt();
        else if (state.nextAttemptAt && state.nextAttemptAt > t) nextAttemptAt = state.nextAttemptAt;
        else if (getChallengeTypes().length) nextAttemptAt = t;
      }
      const waitingReason = !running && isDue(t) && !getChallengeTypes().length ? getWaitingReason() : null;
      return {
        status,
        expiresAt: current ? current.notAfter : null,
        certificateStaging: current ? current.staging : null,
        lastAttemptAt: state.lastAttemptAt,
        lastError: state.lastError ?? waitingReason,
        nextAttemptAt,
        attempting: running,
        failures: state.failures,
      };
    },
  };
}
