/**
 * DDNS(DuckDNS) 자동 갱신 — 공유기의 공인 IP가 바뀌어도 외부 접속 주소(xxx.duckdns.org — .env의 EXTERNAL_ADDRESS,
 * 아이폰용 웹 앱 주소 WEB_DOMAIN)가 이 서버를 가리키게, 서버가 켜져 있는 동안 주기적으로 DuckDNS에 알린다. 예전에는
 * 이 PC의 작업 스케줄러(PowerShell)로 하던 일이다. 설정(도메인·토큰·켜기)은 관리자 콘솔 "DDNS" 탭에서 하고 DB에
 * 둔다(ddnsService.js가 DB와 이어 준다 — 이 파일은 DB를 모르게 둬서 시험하기 쉽게 했다).
 *
 * DuckDNS 갱신 주소: https://www.duckdns.org/update?domains=<이름,...>&token=<토큰>&verbose=true — ip를 비우면
 * DuckDNS가 요청이 온 공인 IP로 맞춘다(이 서버가 공유기 뒤에서 보내므로 그게 곧 외부 주소). verbose 응답은
 * "OK\n<IPv4>\n<IPv6>\nUPDATED|NOCHANGE", 실패면 "KO"뿐이다(도메인이 그 토큰 것이 아니거나 토큰이 틀림).
 */

/** 몇 분마다 갱신하는지 — DuckDNS 안내(5분)와 같다. */
export const DDNS_INTERVAL_MS = 5 * 60 * 1000;
const REQUEST_TIMEOUT_MS = 15 * 1000;
/** 한 번에 갱신할 수 있는 도메인 수 — DuckDNS 무료 계정 한도(5개). */
export const DDNS_MAX_DOMAINS = 5;

const SUFFIX = '.duckdns.org';

/**
 * 관리자가 넣은 도메인 글을 DuckDNS 이름 목록으로 — "tangotalk, tangotalk-dev.duckdns.org"처럼 쉼표·공백으로 나눈
 * 이름이나 전체 주소(https://…, 뒤 경로·포트도)를 받아 ".duckdns.org"를 뗀 소문자 이름으로 바꾼다. 겹치면 하나만.
 * 형식이 틀리면 { error }.
 */
export function parseDuckDnsDomains(raw) {
  if (typeof raw !== 'string') return { error: '도메인은 글자로 넣어야 합니다.' };
  const names = [];
  for (const piece of raw.split(/[\s,]+/)) {
    let name = piece
      .trim()
      .toLowerCase()
      .replace(/^https?:\/\//, '')
      .replace(/[/:?#].*$/, '');
    if (!name) continue;
    if (name.endsWith(SUFFIX)) name = name.slice(0, -SUFFIX.length);
    if (!/^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(name)) {
      return { error: `DuckDNS 도메인 이름이 올바르지 않습니다: ${piece.trim()} (예: tangotalk 또는 tangotalk.duckdns.org)` };
    }
    if (!names.includes(name)) names.push(name);
  }
  if (names.length > DDNS_MAX_DOMAINS) {
    return { error: `도메인은 ${DDNS_MAX_DOMAINS}개까지 넣을 수 있습니다.` };
  }
  return { names };
}

/** DuckDNS 토큰 모양(UUID — DuckDNS 첫 화면의 "token"). */
export function isDuckDnsToken(value) {
  return typeof value === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value.trim());
}

/** verbose 응답을 읽는다 — { ok, ip, changed } 또는 { ok: false }. */
export function parseDuckDnsResponse(text) {
  const lines = String(text ?? '').split(/\r?\n/).map((l) => l.trim());
  if (lines[0] !== 'OK') return { ok: false };
  return { ok: true, ip: lines[1] || null, changed: lines[3] === 'UPDATED' };
}

/**
 * 한 번 갱신한다. [fetchImpl]은 시험용. 실패하면 사람이 읽을 이유로 예외를 던진다 — 토큰은 글에 넣지 않는다
 * (요청 주소에 들어 있어서, 연결 오류를 그대로 옮기지 않고 원인만 남긴다).
 */
export async function updateDuckDns({ domains, token, fetchImpl = fetch }) {
  const url = new URL('https://www.duckdns.org/update');
  url.searchParams.set('domains', domains.join(','));
  url.searchParams.set('token', token);
  url.searchParams.set('ip', '');
  url.searchParams.set('verbose', 'true');
  let res;
  try {
    res = await fetchImpl(url, { signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS) });
  } catch (e) {
    const reason = e?.name === 'TimeoutError' ? '응답이 없습니다' : (e?.cause?.code ?? e?.code ?? '연결 실패');
    throw new Error(`DuckDNS에 연결하지 못했습니다(${reason}).`);
  }
  if (!res.ok) throw new Error(`DuckDNS가 오류로 답했습니다(HTTP ${res.status}).`);
  const result = parseDuckDnsResponse(await res.text());
  if (!result.ok) {
    throw new Error('DuckDNS가 갱신을 거절했습니다 — 도메인 이름이 이 토큰의 계정 것인지, 토큰이 맞는지 확인하세요.');
  }
  return result;
}

/**
 * 주기 갱신기. [loadSettings]는 지금 설정 { enabled, domains: [이름], token, tokenError? }을 준다(설정이 바뀌면 다음
 * 실행부터 그대로 반영된다). 서버를 켤 때 [start], 관리자가 설정을 바꾸거나 "지금 갱신"을 누르면 [runNow] —
 * 이미 갱신 중이면 그 결과를 같이 기다린다(DuckDNS에 겹쳐 묻지 않게). 실패해도 다음 주기에 다시 한다.
 * [setTimer]·[clearTimer]·[now]·[fetchImpl]은 시험용.
 */
export function createDdnsUpdater({
  loadSettings,
  fetchImpl = fetch,
  now = () => Date.now(),
  intervalMs = DDNS_INTERVAL_MS,
  setTimer = (fn, ms) => setTimeout(fn, ms).unref?.() ?? null,
  clearTimer = (handle) => clearTimeout(handle),
  log = console,
}) {
  const state = {
    enabled: false,
    domains: [],
    lastAttemptAt: null,
    lastSuccessAt: null,
    ok: null, // 마지막 시도가 성공했는지(아직 안 했으면 null)
    ip: null,
    changed: false,
    error: null,
    nextAttemptAt: null,
  };
  let timer = null;
  let running = null;
  let stopped = false;

  function schedule() {
    if (timer) clearTimer(timer);
    timer = null;
    state.nextAttemptAt = null;
    if (stopped || !state.enabled) return;
    state.nextAttemptAt = now() + intervalMs;
    timer = setTimer(() => {
      timer = null;
      runNow().catch(() => {});
    }, intervalMs);
  }

  async function run() {
    let settings;
    try {
      settings = await loadSettings();
    } catch (e) {
      log.error?.('[ddns] 설정을 읽지 못했습니다:', e?.message ?? e);
      state.ok = false;
      state.error = '설정을 읽지 못했습니다.';
      return;
    }
    const wasEnabled = state.enabled;
    state.enabled = !!settings.enabled;
    state.domains = settings.domains ?? [];
    if (!state.enabled) {
      // 꺼지면 지난 결과도 비운다 — 켜 둔 것처럼 보이지 않게.
      Object.assign(state, { lastAttemptAt: null, lastSuccessAt: null, ok: null, ip: null, changed: false, error: null });
      return;
    }
    if (!wasEnabled) Object.assign(state, { lastSuccessAt: null, ip: null });
    state.lastAttemptAt = now();
    if (settings.tokenError || !settings.token || state.domains.length === 0) {
      state.ok = false;
      state.changed = false;
      state.error = settings.tokenError ?? (state.domains.length === 0 ? '도메인이 없습니다.' : '토큰이 없습니다.');
      return;
    }
    try {
      const result = await updateDuckDns({ domains: state.domains, token: settings.token, fetchImpl });
      const ipChanged = state.ip !== null && state.ip !== result.ip;
      Object.assign(state, { ok: true, ip: result.ip, changed: result.changed, error: null, lastSuccessAt: now() });
      if (ipChanged || result.changed) log.log?.(`[ddns] ${state.domains.join(', ')} → ${result.ip ?? '?'} 갱신`);
    } catch (e) {
      Object.assign(state, { ok: false, changed: false, error: e.message });
      log.warn?.(`[ddns] 갱신 실패: ${e.message}`);
    }
  }

  function runNow() {
    if (!running) {
      running = run().finally(() => {
        running = null;
        schedule();
      });
    }
    return running;
  }

  return {
    start: () => {
      stopped = false;
      return runNow();
    },
    runNow,
    stop: () => {
      stopped = true;
      if (timer) clearTimer(timer);
      timer = null;
      state.nextAttemptAt = null;
    },
    /** 관리자 콘솔에 보일 상태(시각은 ms). */
    status: () => ({ ...state, domains: [...state.domains], intervalMinutes: Math.round(intervalMs / 60000) }),
  };
}
