import crypto from 'node:crypto';
import dns from 'node:dns';
import { authenticate, dkimSign } from 'mailauth';
import { decryptField, encryptField } from './crypto.js';

/**
 * 자체 메일 서버의 보낸 쪽 확인과 DKIM 서명.
 *
 * 받을 때(localMailServer.js) — mailauth로 SPF(보낸 서버가 그 도메인의 메일 서버인지)·DKIM(내용에 그 도메인의 서명이 맞는지)·
 * DMARC(보낸 사람 주소의 도메인이 정한 정책)를 보고 [mailAuthVerdict]로 정한다:
 *   - reject — DMARC 확인에 실패했고 그 도메인이 거절(p=reject)하라고 했다 → 받지 않는다(550).
 *   - junk   — DMARC 실패 + 격리(p=quarantine), 우리 회사 도메인을 사칭(우리 도메인인데 SPF·DKIM이 그 도메인으로 확인되지 않음 —
 *              우리끼리 보낸 메일은 바깥을 거치지 않고 바로 들어오므로 25번 포트로 오는 우리 도메인 메일은 바깥에서 온 것),
 *              SPF가 실패했는데 DKIM 서명도 맞지 않음 → 스팸편지함.
 *   - warn   — 어느 것으로도 확인되지 않음(SPF 없음·중립·약한 실패, 서명 없음, DMARC 실패지만 정책이 none) → 받은편지함, 읽을 때 알림.
 *   - pass   — 확인됨.
 * 확인 결과는 메일 앞에 Authentication-Results 머리로 붙이고 표(local_mail_messages.auth)에도 남긴다(읽기 화면의 경고). DNS를 못
 * 읽는 등 확인 자체가 실패하면 그냥 받는다(none — 확인 못 했다고 메일을 버리지 않는다).
 *
 * 보낼 때(webmail.js sendFromLocal) — 관리자가 켜면 회사 메일함에서 바깥으로 보내는 메일에 이 서버의 키로 DKIM 서명을 한다. 키는
 * 처음 볼 때 만들어 암호화해 두고(server_settings.localMailDkimKey), 관리자 콘솔이 DNS에 올릴 TXT 레코드를 보여 준다.
 */

export const DKIM_SELECTOR_DEFAULT = 'tangotalk';
const SELECTOR_RE = /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/i;
const DNS_TIMEOUT_MS = 5000;

/** 선택자 모양(DNS 이름 한 칸) — 맞으면 소문자, 아니면 null. */
export const normalizeDkimSelector = (v) => (typeof v === 'string' && SELECTOR_RE.test(v.trim()) ? v.trim().toLowerCase() : null);

const lower = (v) => String(v ?? '').toLowerCase();

/** [domain]이 [base]와 같거나 그 아래 도메인인지. */
export const isSameOrSubdomain = (domain, base) => {
  const d = lower(domain);
  const b = lower(base);
  return !!d && !!b && (d === b || d.endsWith(`.${b}`));
};

/** mailauth 결과에서 보낸 사람 주소의 도메인(From 머리). */
function fromDomainOf(result) {
  const fromDmarc = result?.dmarc?.status?.header?.from;
  if (fromDmarc) return lower(fromDmarc);
  const from = [].concat(result?.dkim?.headerFrom ?? [])[0];
  const at = String(from ?? '').lastIndexOf('@');
  return at >= 0 ? lower(String(from).slice(at + 1)) : null;
}

/**
 * mailauth authenticate 결과 → `{ spf, dkim, dmarc, from, verdict, reason }`(위의 규칙). [localDomains]는 우리 회사 도메인들. 순수 함수 —
 * DNS 없이 시험한다.
 */
export function mailAuthVerdict(result, { localDomains = [] } = {}) {
  const spf = result?.spf?.status?.result ?? 'none';
  const spfDomain = lower(result?.spf?.domain);
  const dkimRows = Array.isArray(result?.dkim?.results) ? result.dkim.results : [];
  const dkimPassDomains = dkimRows.filter((r) => r?.status?.result === 'pass').map((r) => lower(r.signingDomain));
  const dkim = dkimPassDomains.length ? 'pass' : (dkimRows.find((r) => r?.status?.result && r.status.result !== 'none')?.status.result ?? 'none');
  const dmarc = result?.dmarc ? (result.dmarc.status?.result ?? 'none') : 'none';
  const policy = lower(result?.dmarc?.policy);
  const from = fromDomainOf(result);
  const base = { spf, dkim, dmarc, from };

  if (dmarc === 'fail' && policy === 'reject') {
    return { ...base, verdict: 'reject', reason: `보낸 도메인(${from})의 DMARC 정책이 "거절"인데 보낸 쪽 확인에 실패했습니다.` };
  }
  if (dmarc === 'fail' && policy === 'quarantine') {
    return { ...base, verdict: 'junk', reason: `보낸 도메인(${from})의 DMARC 정책이 "격리"인데 보낸 쪽 확인에 실패했습니다.` };
  }
  const ours = from && localDomains.some((d) => isSameOrSubdomain(from, d));
  // 우리 도메인을 쓴 메일은 그 도메인으로 맞춰 확인돼야 한다(DMARC를 안 올렸어도 — 바깥에서 오는 우리 도메인 메일은 사칭이기 쉽다).
  const aligned =
    dmarc === 'pass' ||
    dkimPassDomains.some((d) => from && (isSameOrSubdomain(d, from) || isSameOrSubdomain(from, d))) ||
    (spf === 'pass' && from && (isSameOrSubdomain(spfDomain, from) || isSameOrSubdomain(from, spfDomain)));
  if (ours && !aligned) {
    return { ...base, verdict: 'junk', reason: `우리 회사 도메인(${from})을 쓴 메일인데 그 도메인에서 보낸 것으로 확인되지 않았습니다(사칭일 수 있음).` };
  }
  if (spf === 'fail' && dkim !== 'pass') {
    return { ...base, verdict: 'junk', reason: '보낸 서버가 그 도메인의 메일 서버가 아닙니다(SPF 실패).' };
  }
  if (dmarc === 'pass' || spf === 'pass' || dkim === 'pass') return { ...base, verdict: 'pass', reason: null };
  return { ...base, verdict: 'warn', reason: '보낸 사람을 확인하지 못했습니다(SPF·DKIM 확인 안 됨).' };
}

/** DNS 조회(시간 제한) — mailauth의 resolver 모양 `(name, rrtype) → Promise`. */
function timedResolver() {
  const resolver = new dns.promises.Resolver({ timeout: DNS_TIMEOUT_MS, tries: 2 });
  return (name, rrtype) => resolver.resolve(name, rrtype);
}

let resolverHook = null;

/** 시험용 — 가짜 DNS(`(name, rrtype) → Promise`)를 끼운다(null이면 실제 DNS). */
export function __setMailAuthResolver(fn) {
  resolverHook = fn;
}

/**
 * 받은 메일 [raw] 확인 — [ip]·[helo]는 보낸 서버, [mailFrom]은 봉투의 보내는 사람, [mta]는 이 서버 이름(Authentication-Results에 쓴다).
 * → `{ verdict, reason, spf, dkim, dmarc, from, headers }`([headers]는 메일 앞에 붙일 머리 글). 확인 자체가 실패하면 verdict 'none'.
 */
export async function checkInboundMail(raw, { ip, helo, mailFrom, mta, localDomains = [] }) {
  try {
    const result = await authenticate(raw, {
      ip,
      helo: helo || undefined,
      sender: mailFrom || undefined,
      mta,
      resolver: resolverHook ?? timedResolver(),
      disableArc: true,
      disableBimi: true,
    });
    return { ...mailAuthVerdict(result, { localDomains }), headers: result.headers ?? '' };
  } catch (err) {
    console.error('[local-mail] 보낸 쪽 확인 실패:', err?.message ?? err);
    return { verdict: 'none', reason: null, spf: null, dkim: null, dmarc: null, from: null, headers: '' };
  }
}

/** 표에 남길 확인 결과(머리 글 없이). */
export const authRecordOf = (v) => (v && v.verdict !== 'none' ? { spf: v.spf, dkim: v.dkim, dmarc: v.dmarc, verdict: v.verdict, reason: v.reason } : null);

// ── DKIM 서명 ──

/** 개인키 PEM → DNS에 올릴 공개키(base64 DER — "p=" 값). */
export function dkimPublicKeyOf(privateKeyPem) {
  return crypto.createPublicKey(privateKeyPem).export({ type: 'spki', format: 'der' }).toString('base64');
}

/** DNS TXT 레코드 값. */
export const dkimRecordValue = (publicKey) => `v=DKIM1; k=rsa; p=${publicKey}`;

/**
 * 서버 설정의 DKIM 키 — 없으면 새로 만들어 [save](patch)로 저장한다(RSA 2048). → `{ privateKey, publicKey, selector }`.
 */
export async function ensureDkimKey(settings, save) {
  const selector = normalizeDkimSelector(settings?.localMailDkimSelector) ?? DKIM_SELECTOR_DEFAULT;
  let privateKey = settings?.localMailDkimKey ? decryptField(settings.localMailDkimKey) : null;
  if (!privateKey) {
    privateKey = crypto.generateKeyPairSync('rsa', {
      modulusLength: 2048,
      publicKeyEncoding: { type: 'spki', format: 'pem' },
      privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
    }).privateKey;
    await save({ localMailDkimKey: encryptField(privateKey), localMailDkimSelector: selector });
  }
  return { privateKey, publicKey: dkimPublicKeyOf(privateKey), selector };
}

/** 관리자 콘솔에 보일 도메인마다의 DKIM 레코드 `[{ domain, name, value }]`. */
export const dkimRecords = (domains, selector, publicKey) =>
  domains.map((domain) => ({ domain, name: `${selector}._domainkey.${domain}`, value: dkimRecordValue(publicKey) }));

/** 보낼 원문 [raw]에 [domain]으로 DKIM 서명을 붙인 원문(서명하지 못하면 원래 원문 — 보내기는 막지 않는다). */
export async function signOutgoing(raw, { domain, selector, privateKey }) {
  try {
    const { signatures, errors } = await dkimSign(raw, {
      canonicalization: 'relaxed/relaxed',
      signatureData: [{ signingDomain: domain, selector, privateKey, algorithm: 'rsa-sha256', canonicalization: 'relaxed/relaxed' }],
    });
    if (errors?.length || !signatures?.trim()) {
      console.error('[local-mail] DKIM 서명 실패:', errors?.[0]?.err?.message ?? errors?.[0] ?? '서명 없음');
      return raw;
    }
    return Buffer.concat([Buffer.from(signatures), Buffer.isBuffer(raw) ? raw : Buffer.from(raw)]);
  } catch (err) {
    console.error('[local-mail] DKIM 서명 실패:', err?.message ?? err);
    return raw;
  }
}

/**
 * DNS에 DKIM 레코드가 올라가 있는지 — 도메인마다 `{ domain, ok, found }`(found는 찾은 p= 앞부분 — 다르면 관리자가 견줘 본다).
 * [resolveTxt]는 시험에서 바꿔 끼운다.
 */
export async function checkDkimRecords(records, publicKey, resolveTxt = (name) => new dns.promises.Resolver({ timeout: DNS_TIMEOUT_MS, tries: 2 }).resolveTxt(name)) {
  return Promise.all(
    records.map(async ({ domain, name }) => {
      try {
        const rows = (await resolveTxt(name)).map((parts) => [].concat(parts).join(''));
        const p = rows.map((r) => /(?:^|;)\s*p=([^;\s]*)/i.exec(r)?.[1] ?? null).find((v) => v !== null) ?? null;
        return { domain, ok: p === publicKey, found: p ? `${p.slice(0, 24)}…` : null };
      } catch {
        return { domain, ok: false, found: null };
      }
    }),
  );
}
