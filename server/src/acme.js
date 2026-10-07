import { AsyncLocalStorage } from 'node:async_hooks';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import acme from 'acme-client';
import { formatTime } from './acmeRenewal.js';

/**
 * Let's Encrypt에서 웹 앱 전용 주소(WEB_DOMAIN)의 인증서를 실제로 받아 오는 쪽(acme-client). 언제 받을지는 acmeRenewal.js가,
 * 확인 요청에 답하는 포트는 webTls.js가 맡는다 — 여기서는 주문 하나를 끝까지 진행하고, 실패하면 운영자가 읽을 한국어 이유와
 * 다음 시도에 필요한 정보(종류·Retry-After)를 담은 AcmeIssueError를 던진다.
 *
 * 이 모듈은 WEB_DOMAIN이 있을 때만 webTls.js가 불러온다(acme-client를 아예 읽지 않게).
 */

const PROBLEM_PREFIX = 'urn:ietf:params:acme:error:';
export const RATE_LIMITED = `${PROBLEM_PREFIX}rateLimited`;

/** 챌린지 토큰 모양(base64url, RFC 8555 8.3) — webTls.js의 HTTP-01 응답도 같은 규칙으로 거른다. */
export const ACME_TOKEN_PATTERN = /^[A-Za-z0-9_-]{1,256}$/;

/**
 * 발급 실패. [kind]로 다음 행동이 갈린다:
 *  - 'challenge': 확인 접속 실패(포트포워딩 등) — 같은 시도 안에서 다른 인증 방식으로 바로 넘어갈 수 있다.
 *  - 'rateLimited': Let's Encrypt 한도 — [retryAfterMs] 전에는 다시 묻지 않는다.
 *  - 'dns' | 'caa' | 'rejected' | 'contact' | 'network' | 'server' | 'storage' | 'other'
 * [message]는 관리자 콘솔·로그에 그대로 보여 줄 한국어(비밀값 없음), [detail]은 Let's Encrypt가 준 원문(로그용).
 */
export class AcmeIssueError extends Error {
  constructor(message, { kind = 'other', problemType = null, detail = null, retryAfterMs = null, challengeType = null } = {}) {
    super(message);
    this.name = 'AcmeIssueError';
    this.kind = kind;
    this.problemType = problemType;
    this.detail = detail;
    this.retryAfterMs = retryAfterMs;
    this.challengeType = challengeType;
  }
}

const responseCapture = new AsyncLocalStorage();
let acmeHttpConfigured = false;

/** acme-client의 HTTP 설정을 한 번 바꾼다(이 프로세스에서 acme-client를 쓰는 곳은 여기뿐이다). */
function configureAcmeHttp() {
  if (acmeHttpConfigured) return;
  acmeHttpConfigured = true;
  // acme-client는 429·5xx를 받으면 Retry-After만큼 그 자리에서 잠들었다가 최대 5번 다시 보낸다 — Let's Encrypt 주간 한도면
  // 며칠씩 붙잡혀 있게 된다. 다시 시도는 우리 일정(acmeRenewal.js — 백오프·Retry-After·재시작 보호)이 맡으므로 끈다.
  acme.axios.defaults.acmeSettings.retryMaxAttempts = 0;
  // 응답이 영영 오지 않는 요청 하나가 발급(과 갱신 일정)을 멈춰 세우지 않게.
  acme.axios.defaults.timeout = 30 * 1000;
  // acme-client는 오류 응답에서 detail 문장만 남기고 오류 종류(type)와 Retry-After는 버린다 — 응답을 옆에서 봐 둔다.
  // 지금 진행 중인 주문(AsyncLocalStorage)에만 기록하므로 동시에 다른 요청이 섞여도 엇갈리지 않는다.
  acme.axios.interceptors.response.use((response) => {
    const capture = responseCapture.getStore();
    if (capture) {
      capture.responses += 1;
      capture.lastProblem = problemFromResponse(response);
    }
    return response;
  });
}

/** Retry-After 머리글(초 또는 HTTP 날짜) → 지금부터 기다릴 ms. 없거나 이상하면 null. */
export function parseRetryAfter(value, now = Date.now()) {
  const raw = String(value ?? '').trim();
  if (!raw) return null;
  if (/^\d+$/.test(raw)) {
    const seconds = Number(raw);
    return seconds > 0 ? seconds * 1000 : null;
  }
  const at = Date.parse(raw);
  return Number.isFinite(at) && at > now ? at - now : null;
}

/** Retry-After가 없을 때 Let's Encrypt 한도 문구의 "retry after 2026-10-09 12:00:00 UTC" 부분에서 시각을 읽는다. */
export function retryAfterFromDetail(detail, now = Date.now()) {
  const match = /retry after (\d{4}-\d{2}-\d{2})[ T](\d{2}:\d{2}:\d{2})(?:\.\d+)?\s*(?:UTC|Z)?/i.exec(String(detail ?? ''));
  if (!match) return null;
  const at = Date.parse(`${match[1]}T${match[2]}Z`);
  return Number.isFinite(at) && at > now ? at - now : null;
}

/** 응답 하나에서 ACME 문제 문서(RFC 8555 6.7)를 꺼낸다 — 오류 응답이거나, 확인이 invalid로 끝난 챌린지·인증 객체. */
export function problemFromResponse(response) {
  const status = Number(response?.status) || 0;
  const data = response?.data;
  const isObject = data && typeof data === 'object';
  const detail = (value) => (typeof value === 'string' ? value.slice(0, 1000) : '');
  if (status >= 400) {
    const retryAfterMs = parseRetryAfter(response?.headers?.['retry-after']);
    const problem = (type, text = '') => ({ type, detail: text, status, retryAfterMs, source: 'response' });
    if (isObject && typeof data.type === 'string') return problem(data.type, detail(data.detail));
    if (status === 429) return problem(RATE_LIMITED);
    return problem(status >= 500 ? `${PROBLEM_PREFIX}serverInternal` : 'unknown');
  }
  if (isObject && data.status === 'invalid') {
    const error = data.error ?? (Array.isArray(data.challenges) ? data.challenges.find((c) => c?.error)?.error : null);
    if (error && typeof error.type === 'string') {
      const errorStatus = Number(error.status) || null;
      return { type: error.type, detail: detail(error.detail), status: errorStatus, retryAfterMs: null, source: 'challenge' };
    }
  }
  return null;
}

const NETWORK_ERROR_CODES = [
  'ECONNREFUSED',
  'ECONNRESET',
  'ENOTFOUND',
  'EAI_AGAIN',
  'ETIMEDOUT',
  'ECONNABORTED',
  'EHOSTUNREACH',
  'ENETUNREACH',
  'EPIPE',
  'ERR_NETWORK',
];

/** acme-client 5.x는 응답 없는 네트워크 오류를 TypeError로 바꿔 던진다(재시도 가로채기가 없는 응답의 config를 읽음) — 둘 다 네트워크로 본다. */
function isNetworkError(err) {
  const codes = NETWORK_ERROR_CODES;
  if (codes.includes(err?.code) || codes.includes(err?.cause?.code)) return true;
  if (err?.isAxiosError && !err.response) return true;
  return err instanceof TypeError && /reading 'config'/.test(err.message);
}

function isSharedDdns(domain) {
  return /(^|\.)iptime\.org$/.test(domain);
}

/**
 * rateLimited 안내 — 운영자가 "왜 막혔고 무엇을 하면 되는지" 알 수 있게, Let's Encrypt가 준 문구([detail])로 어느 한도인지 가려
 * 말한다. 문구가 없으면(내용 없는 429) iptime.org는 가장 흔한 원인인 공유 주간 한도로 안내한다.
 */
export function rateLimitMessage(domain, retryAt, detail = '') {
  const when = retryAt ? `${formatTime(retryAt)} 이후에` : '나중에';
  const text = String(detail ?? '');
  if (/paused|prevented|unpause/i.test(text)) {
    return (
      'Let\'s Encrypt가 이 서버의 이 도메인 발급을 일시 중지했습니다(rateLimited — 확인 실패가 오래 계속됨). 포트포워딩을 고친 뒤 서버 ' +
      `로그의 "Let's Encrypt 응답"에 있는 안내 링크로 해제하면, ${when} 자동으로 다시 받습니다.`
    );
  }
  if (/failed authori[sz]ation/i.test(text)) {
    return (
      'Let\'s Encrypt 확인 실패가 너무 잦아 잠시 막혔습니다(rateLimited — 도메인당 1시간에 5번). 공유기 포트포워딩·방화벽을 고쳐 두면 ' +
      `${when} 자동으로 다시 시도합니다.`
    );
  }
  if (/exact set/i.test(text)) {
    return (
      'Let\'s Encrypt 발급 한도에 걸렸습니다(rateLimited — 같은 도메인 인증서는 7일에 5장). certs/web.crt가 지워지거나 서버를 다시 ' +
      `설치하는 일이 되풀이됐는지 확인하세요. ${when} 자동으로 다시 시도합니다.`
    );
  }
  if (isSharedDdns(domain) && (!text || /already issued for "/i.test(text) || /registered domain/i.test(text))) {
    return (
      'Let\'s Encrypt 발급 한도에 걸렸습니다(rateLimited). iptime.org는 공용 접미사 목록(PSL)에 없어서 Let\'s Encrypt의 ' +
      '"등록 도메인당 7일에 새 인증서 50장" 한도를 모든 iptime DDNS 사용자가 함께 씁니다 — 다른 사용자들이 이번 주 몫을 다 쓰면 ' +
      `첫 발급이 막힙니다(한 번 받은 뒤의 같은 이름 갱신은 이 한도에 걸리지 않습니다). ${when} 자동으로 다시 시도합니다. 계속 막히면 ` +
      `직접 산 도메인(예: chat.회사도메인.com)을 CNAME 레코드로 ${domain}에 연결하고 .env의 WEB_DOMAIN을 그 도메인으로 바꾼 뒤 서버를 다시 시작하세요.`
    );
  }
  return (
    `Let's Encrypt 발급 한도에 걸렸습니다(rateLimited) — 이 도메인(또는 같은 상위 도메인)으로 최근 너무 많이 요청했습니다. ${when} ` +
    '자동으로 다시 시도합니다. 여러 사람이 함께 쓰는 DDNS 도메인이라 다른 사용자들의 발급까지 함께 세어지는 것이라면, 직접 산 도메인을 ' +
    'CNAME으로 연결해 WEB_DOMAIN으로 쓰세요.'
  );
}

/** 확인 접속이 실패했을 때 인증 방식별로 무엇을 확인할지. */
function challengeFailureMessage(shortType, { domain, challengeType, ports }) {
  const http01 = challengeType === 'http-01';
  const externalPort = http01 ? 80 : 443;
  const localPort = http01 ? ports.http : ports.https;
  const forward = `공유기에서 외부 TCP ${externalPort} → 이 PC의 TCP ${localPort} 포트포워딩과 Windows 방화벽(인바운드 TCP ${localPort})을 확인하세요`;
  if (shortType === 'connection' || shortType === 'tls') {
    const ispNote = http01 ? ' 통신사가 80 포트를 막는 회선도 있습니다.' : '';
    return `[${challengeType}] Let's Encrypt가 ${domain}의 외부 ${externalPort} 포트로 접속해 확인하지 못했습니다 — ${forward}.${ispNote}`;
  }
  return (
    `[${challengeType}] Let's Encrypt가 ${domain}(외부 ${externalPort} 포트)에서 받은 확인 응답이 이 서버의 것이 아닙니다 — DDNS가 이 사무실의 ` +
    `공인 IP를 가리키는지, 외부 ${externalPort} 포트가 이 PC가 아닌 다른 기기(공유기의 원격 관리 페이지 등)로 가지 않는지 확인하세요(${forward}).`
  );
}

/** 문제 문서 → AcmeIssueError(한국어 안내). */
function errorFromProblem(problem, { domain, challengeType, ports, email }) {
  const short = problem.type.startsWith(PROBLEM_PREFIX) ? problem.type.slice(PROBLEM_PREFIX.length) : problem.type;
  const base = { problemType: problem.type, detail: problem.detail || null, challengeType };
  const serverBusy = () =>
    new AcmeIssueError("Let's Encrypt 서버가 잠시 요청을 처리하지 못했습니다 — 나중에 자동으로 다시 시도합니다.", {
      ...base,
      kind: 'server',
      retryAfterMs: problem.retryAfterMs,
    });
  switch (short) {
    case 'rateLimited': {
      const retryAfterMs = problem.retryAfterMs ?? retryAfterFromDetail(problem.detail);
      const message = rateLimitMessage(domain, retryAfterMs ? Date.now() + retryAfterMs : null, problem.detail);
      return new AcmeIssueError(message, { ...base, kind: 'rateLimited', retryAfterMs });
    }
    case 'connection':
    case 'tls':
    case 'unauthorized':
    case 'incorrectResponse':
      if (problem.source === 'challenge') {
        return new AcmeIssueError(challengeFailureMessage(short, { domain, challengeType, ports }), { ...base, kind: 'challenge' });
      }
      break;
    case 'dns':
      return new AcmeIssueError(
        `Let's Encrypt가 ${domain}을(를) DNS에서 찾지 못했습니다 — 공유기의 DDNS 등록 상태(이름·공인 IP)를 확인하세요.`,
        { ...base, kind: 'dns' },
      );
    case 'caa':
      return new AcmeIssueError(
        `${domain}의 CAA 설정이 Let's Encrypt의 발급을 허용하지 않습니다 — 도메인 DNS의 CAA 레코드를 확인하세요.`,
        { ...base, kind: 'caa' },
      );
    case 'rejectedIdentifier':
      return new AcmeIssueError(
        `Let's Encrypt가 ${domain} 이름으로는 인증서를 발급하지 않습니다(정책상 거부) — 다른 도메인을 WEB_DOMAIN으로 쓰세요.`,
        { ...base, kind: 'rejected' },
      );
    case 'invalidContact':
    case 'unsupportedContact':
      return new AcmeIssueError(
        `Let's Encrypt가 ACME_EMAIL(${email ?? '없음'})을 받지 않았습니다 — 비우거나 올바른 주소로 고치세요.`,
        { ...base, kind: 'contact' },
      );
    case 'serverInternal':
    case 'badNonce':
      return serverBusy();
    default:
      break;
  }
  if (problem.status >= 500) return serverBusy();
  const reason = problem.detail ? `: ${problem.detail.slice(0, 300)}` : '';
  return new AcmeIssueError(`Let's Encrypt가 요청을 거절했습니다(${short})${reason}`, { ...base, kind: 'other' });
}

/** acme-client가 던진 오류를 분류한다 — 이번 주문에서 마지막으로 본 응답(capture)이 진짜 이유를 갖고 있다. */
function classifyError(err, capture, context) {
  if (err instanceof AcmeIssueError) return err;
  if (capture.lastProblem) return errorFromProblem(capture.lastProblem, context);
  if (capture.responses === 0 || isNetworkError(err)) {
    const host = (() => {
      try {
        return new URL(context.directoryUrl).host;
      } catch {
        return "Let's Encrypt";
      }
    })();
    return new AcmeIssueError(
      `Let's Encrypt 서버(${host})에 연결하지 못했습니다 — 이 PC의 인터넷 연결·방화벽·프록시를 확인하세요. 나중에 자동으로 다시 시도합니다.`,
      { kind: 'network', detail: err?.message ?? String(err), challengeType: context.challengeType },
    );
  }
  return new AcmeIssueError(`인증서 발급 중 오류가 났습니다: ${err?.message ?? err}`, {
    kind: 'other',
    detail: err?.stack ?? null,
    challengeType: context.challengeType,
  });
}

/** 두 방식 모두 실패했으면 둘의 이유를 함께 보여 준다(운영자가 80·443 중 무엇이 막혔는지 한 번에 보게). */
function combineErrors(errors) {
  if (errors.length === 1) return errors[0];
  const last = errors[errors.length - 1];
  const retries = errors.map((e) => e.retryAfterMs).filter((ms) => Number.isFinite(ms) && ms > 0);
  return new AcmeIssueError(errors.map((e) => e.message).join(' / '), {
    kind: last.kind,
    problemType: last.problemType,
    detail: errors.map((e) => e.detail).filter(Boolean).join(' | ') || null,
    retryAfterMs: retries.length ? Math.max(...retries) : null,
    challengeType: null,
  });
}

/**
 * Let's Encrypt 계정 키(ECDSA P-256) — 처음 한 번 만들어 certs/acme-account.key에 두고 계속 쓴다(같은 계정이어야 이미 확인된 도메인
 * 인증을 다시 쓰고, 계정을 새로 만드는 한도에도 걸리지 않는다). 파일이 깨졌으면 옆에 남겨 두고 새로 만든다.
 */
export async function loadOrCreateAccountKey(file, log = console) {
  let existing = null;
  try {
    existing = fs.readFileSync(file, 'utf8');
  } catch (e) {
    if (e.code !== 'ENOENT') {
      throw new AcmeIssueError(`Let's Encrypt 계정 키(${file})를 읽지 못했습니다(${e.code ?? e.message}) — 파일 권한을 확인하세요.`, { kind: 'storage' });
    }
  }
  if (existing !== null) {
    try {
      crypto.createPrivateKey(existing);
      return existing;
    } catch {
      const backup = `${file}.broken-${Date.now()}`;
      try {
        fs.renameSync(file, backup);
      } catch (e) {
        throw new AcmeIssueError(`Let's Encrypt 계정 키(${file})가 깨져 있는데 옮기지 못했습니다(${e.code ?? e.message}).`, { kind: 'storage' });
      }
      log.warn(`[web-tls] Let's Encrypt 계정 키가 깨져 있어 ${backup}로 옮기고 새로 만듭니다.`);
    }
  }
  const pem = (await acme.crypto.createPrivateEcdsaKey('P-256')).toString();
  try {
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, pem, { mode: 0o600, flag: 'wx' });
  } catch (e) {
    throw new AcmeIssueError(`Let's Encrypt 계정 키를 ${file}에 저장하지 못했습니다(${e.code ?? e.message}) — 폴더 권한을 확인하세요.`, { kind: 'storage' });
  }
  log.log(`[web-tls] Let's Encrypt 계정 키를 새로 만들었습니다(${file}) — 이 파일은 공유하거나 지우지 마세요.`);
  log.log('[web-tls]   WEB_DOMAIN을 설정했으므로 Let\'s Encrypt 가입자 약관(https://letsencrypt.org/repository/)에 동의한 것으로 계정을 만듭니다.');
  return pem;
}

/**
 * 인증서 발급기를 만든다. issue({ challengeTypes, challenges })는 [challengeTypes] 순서대로 시도해 첫 성공을 돌려준다 — 확인 접속
 * 실패(kind 'challenge')면 같은 시도 안에서 다음 방식으로 넘어가고, 그 밖의 실패(한도·DNS 등)는 바로 던진다.
 * [challenges]는 webTls.js의 응답 창구: { 'http-01': { add(token, keyAuthorization), remove(token) },
 * 'tls-alpn-01': { add(token, { key, cert }), remove(token) } }.
 *
 * @param {object} o
 * @param {string} [o.directoryUrl] 테스트용(가짜 ACME 서버). 기본은 staging 여부에 따라 Let's Encrypt 정식/시험 주소.
 * @param {() => Promise<string|Buffer>} [o.createCertificateKey] 테스트용 — 인증서 개인키 만들기(기본 ECDSA P-256, 발급마다 새로).
 */
export function createAcmeIssuer({
  domain,
  email = null,
  staging = false,
  accountKeyFile,
  ports = { https: 443, http: 80 },
  directoryUrl = null,
  createCertificateKey = () => acme.crypto.createPrivateEcdsaKey('P-256'),
  log = console,
}) {
  configureAcmeHttp();
  const directory = directoryUrl ?? (staging ? acme.directory.letsencrypt.staging : acme.directory.letsencrypt.production);

  async function runOrder({ client, csr, challengeType, contactEmail, challenges }) {
    const capture = { responses: 0, lastProblem: null };
    const context = { domain, challengeType, ports, email: contactEmail, directoryUrl: directory };
    return responseCapture.run(capture, async () => {
      try {
        return await client.auto({
          csr,
          email: contactEmail ?? undefined,
          termsOfServiceAgreed: true,
          challengePriority: [challengeType],
          // acme-client의 자체 확인(이 PC에서 외부 주소로 접속해 보기)은 끈다 — 공유기가 안에서 바깥 주소로 되돌아오는 접속(NAT
          // 루프백)을 지원하지 않으면 실제로는 되는데도 여기서 막히고, 왜 실패했는지는 Let's Encrypt가 더 정확히 알려 준다.
          skipChallengeVerification: true,
          challengeCreateFn: async (authz, challenge, keyAuthorization) => {
            if (challenge.type !== challengeType) {
              const message = `Let's Encrypt가 ${challengeType} 확인을 내주지 않았습니다(${challenge.type}).`;
              throw new AcmeIssueError(message, { kind: 'other', challengeType });
            }
            if (authz?.identifier?.value !== domain || !ACME_TOKEN_PATTERN.test(String(challenge.token ?? ''))) {
              throw new AcmeIssueError('Let\'s Encrypt가 보낸 확인 요청의 형식이 예상과 다릅니다.', { kind: 'other', challengeType });
            }
            if (challengeType === 'http-01') {
              challenges['http-01'].add(challenge.token, keyAuthorization);
              log.log(
                `[web-tls]   http-01 확인 응답 준비 — Let's Encrypt가 http://${domain}/.well-known/acme-challenge/…` +
                  `(외부 80 → 이 PC ${ports.http})로 확인합니다.`,
              );
            } else {
              const alpnKey = await acme.crypto.createPrivateEcdsaKey('P-256');
              const [key, cert] = await acme.crypto.createAlpnCertificate(authz, keyAuthorization, alpnKey);
              challenges['tls-alpn-01'].add(challenge.token, { key: key.toString(), cert: cert.toString() });
              log.log(`[web-tls]   tls-alpn-01 확인 응답 준비 — Let's Encrypt가 ${domain}:443(외부 443 → 이 PC ${ports.https})으로 확인합니다.`);
            }
          },
          challengeRemoveFn: async (_authz, challenge) => {
            challenges[challenge.type]?.remove(challenge.token);
          },
        });
      } catch (err) {
        throw classifyError(err, capture, context);
      }
    });
  }

  async function issue({ challengeTypes, challenges }) {
    const accountKey = await loadOrCreateAccountKey(accountKeyFile, log);
    const client = new acme.Client({ directoryUrl: directory, accountKey, backoffAttempts: 10, backoffMin: 3000, backoffMax: 30000 });
    const certificateKey = String(await createCertificateKey());
    // CN은 64자까지라 긴 도메인은 SAN에만 넣는다(Let's Encrypt는 SAN만 본다).
    const csrFields = { commonName: domain.length <= 64 ? domain : undefined, altNames: [domain] };
    const [, csr] = await acme.crypto.createCsr(csrFields, certificateKey);

    const errors = [];
    let contactEmail = email;
    for (let i = 0; i < challengeTypes.length; i += 1) {
      const challengeType = challengeTypes[i];
      let certPem;
      try {
        certPem = await runOrder({ client, csr, challengeType, contactEmail, challenges });
      } catch (err) {
        if (err.kind === 'contact' && contactEmail) {
          // 연락처 이메일은 선택이다 — Let's Encrypt가 받지 않으면 빼고 같은 방식으로 한 번 더 한다(이메일 때문에 발급 자체가 막히지 않게).
          log.warn(`[web-tls] ${err.message} 이메일 없이 다시 시도합니다.`);
          contactEmail = null;
          i -= 1;
          continue;
        }
        errors.push(err);
        const next = challengeTypes[i + 1];
        if (err.kind !== 'challenge' || !next) break;
        log.warn(`[web-tls] ${err.message}`);
        if (err.detail) log.warn(`[web-tls]   Let's Encrypt 응답: ${err.detail}`);
        log.warn(`[web-tls]   → ${next} 방식으로 바로 다시 시도합니다.`);
        continue;
      }
      return { certPem: certPem.toString(), keyPem: certificateKey, challengeType };
    }
    throw combineErrors(errors.length ? errors : [new AcmeIssueError('쓸 수 있는 인증 방식이 없습니다.', { kind: 'other' })]);
  }

  return { issue, directoryUrl: directory };
}
