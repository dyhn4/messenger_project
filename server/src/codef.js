import crypto from 'node:crypto';
import {
  CODEF_CARD_APPROVAL_PATH,
  CODEF_CASH_RECEIPT_PATH,
  CODEF_CLIENT_ID,
  CODEF_CLIENT_SECRET,
  CODEF_ENV,
  CODEF_PUBLIC_KEY,
  CODEF_TAX_INVOICE_PATH,
} from './config.js';
import { codefDay, codefList } from './taxDocRules.js';

/**
 * CODEF(코드에프) 중계 — 카드사·홈택스 계정을 CODEF에 연결해(connectedId) 법인카드 승인내역·홈택스 현금영수증·전자세금계산서 목록을 가져온다.
 * 관리자가 `server/.env`에 CODEF와 계약해 받은 값(config.js CODEF_*)을 넣었을 때만 켜진다. 카드사 아이디·비밀번호는 CODEF 공개 키로 암호화해
 * CODEF에만 보내고(계정 연결) 이 서버에는 남기지 않는다 — 남는 것은 connectedId(financeSettings — 암호화)뿐이다.
 *
 * 요청 본문은 JSON을 URL 인코딩한 글, 응답도 URL 인코딩된 JSON이다(CODEF 규약). 응답 `result.code`가 'CF-00000'이면 성공. 토큰(OAuth
 * client_credentials — 일주일)은 만료 1분 전까지 다시 쓴다. 키·토큰·계정 정보는 오류·로그에 넣지 않는다.
 *
 * 상품 주소·응답 칸 이름은 계약한 상품의 개발 가이드를 따른다 — 응답은 taxDocRules.js codefCardRow·codefTaxDocRow가 흔한 칸 이름을 차례로
 * 보고 맞춘다. 실제 계약 전에는 실서비스 응답으로 확인하지 못했다(README).
 */

const OAUTH_URL = 'https://oauth.codef.io/oauth/token';
const API_BASE = { production: 'https://api.codef.io', development: 'https://development.codef.io', sandbox: 'https://sandbox.codef.io' };
const TIMEOUT_MS = 60_000;

export class CodefError extends Error {
  constructor(message, { status = 502, code = null } = {}) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

export const codefEnabled = () => Boolean(CODEF_CLIENT_ID && CODEF_CLIENT_SECRET);
/** 홈택스 상품 주소가 있어 그 종류를 가져올 수 있는지. */
export const codefHometaxKinds = () => [...(CODEF_CASH_RECEIPT_PATH ? ['cash_receipt'] : []), ...(CODEF_TAX_INVOICE_PATH ? ['tax_invoice'] : [])];
export const codefStatus = () => ({
  enabled: codefEnabled(),
  env: CODEF_ENV,
  canConnect: codefEnabled() && Boolean(CODEF_PUBLIC_KEY),
  hometaxKinds: codefEnabled() ? codefHometaxKinds() : [],
});

let token = null;

async function accessToken(fetchImpl = fetch) {
  if (token && token.expiresAt > Date.now() + 60_000) return token.value;
  const res = await fetchImpl(OAUTH_URL, {
    method: 'POST',
    headers: {
      Accept: 'application/json',
      'Content-Type': 'application/x-www-form-urlencoded',
      Authorization: `Basic ${Buffer.from(`${CODEF_CLIENT_ID}:${CODEF_CLIENT_SECRET}`).toString('base64')}`,
    },
    body: 'grant_type=client_credentials&scope=read',
    signal: AbortSignal.timeout(TIMEOUT_MS),
  });
  if (!res.ok) throw new CodefError('CODEF 인증에 실패했습니다. server/.env의 CODEF_CLIENT_ID·CODEF_CLIENT_SECRET을 확인하세요.', { status: 502 });
  const json = await res.json();
  if (!json?.access_token) throw new CodefError('CODEF 인증 응답을 읽지 못했습니다.');
  token = { value: json.access_token, expiresAt: Date.now() + Math.max(60, Number(json.expires_in) || 3600) * 1000 };
  return token.value;
}

/** URL 인코딩된 응답 글 → JSON. */
export function decodeCodefBody(text) {
  let decoded = text;
  try {
    decoded = decodeURIComponent(String(text).replace(/\+/g, ' '));
  } catch {
    // 이미 풀린 글.
  }
  return JSON.parse(decoded);
}

/** 상품 하나를 부른다 — 성공이면 data, 아니면 CodefError(CODEF의 message·extraMessage). */
export async function callCodef(path, params, { fetchImpl = fetch, retried = false } = {}) {
  if (!codefEnabled()) throw new CodefError('카드사·홈택스 연동이 꺼져 있습니다(server/.env의 CODEF_*).', { status: 503 });
  const res = await fetchImpl(`${API_BASE[CODEF_ENV]}${path}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${await accessToken(fetchImpl)}` },
    body: encodeURIComponent(JSON.stringify(params)),
    signal: AbortSignal.timeout(TIMEOUT_MS),
  });
  const text = await res.text();
  let body = null;
  try {
    body = decodeCodefBody(text);
  } catch {
    body = null;
  }
  if (res.status === 401 && !retried) {
    token = null;
    return callCodef(path, params, { fetchImpl, retried: true });
  }
  if (!res.ok || !body) throw new CodefError(`CODEF 응답 오류(${res.status})입니다. 잠시 뒤 다시 하세요.`);
  const code = body?.result?.code ?? null;
  if (code !== 'CF-00000') {
    const message = [body?.result?.message, body?.result?.extraMessage].filter(Boolean).join(' — ') || '알 수 없는 오류';
    throw new CodefError(`CODEF: ${message}`, { status: 502, code });
  }
  return body.data;
}

/** CODEF 공개 키로 비밀번호 암호화(RSA PKCS#1 v1.5 — CODEF 규약). */
function encryptForCodef(plain) {
  const key = String(CODEF_PUBLIC_KEY ?? '').replace(/-----(BEGIN|END) PUBLIC KEY-----/g, '');
  return crypto
    .publicEncrypt({ key: `-----BEGIN PUBLIC KEY-----\n${key}\n-----END PUBLIC KEY-----`, padding: crypto.constants.RSA_PKCS1_PADDING }, Buffer.from(String(plain)))
    .toString('base64');
}

/**
 * 계정 연결 — 카드사 기업 회원 아이디·비밀번호로 CODEF에 계정을 만들고(또는 이미 있는 connectedId에 더하고) connectedId를 돌려준다.
 * [organization]은 CODEF 기관 코드(카드사), [businessType]은 'CD'(카드), clientType 'B'(기업), loginType '1'(아이디·비밀번호).
 */
export async function connectCodefAccount({ organization, loginId, password, connectedId = null, businessType = 'CD', fetchImpl = fetch }) {
  if (!CODEF_PUBLIC_KEY) throw new CodefError('server/.env에 CODEF_PUBLIC_KEY가 없어 계정을 연결할 수 없습니다.', { status: 503 });
  const account = { countryCode: 'KR', businessType, clientType: 'B', organization, loginType: '1', id: loginId, password: encryptForCodef(password) };
  const data = await callCodef(connectedId ? '/v1/account/add' : '/v1/account/create', { accountList: [account], ...(connectedId && { connectedId }) }, { fetchImpl });
  const id = data?.connectedId ?? connectedId;
  if (!id) throw new CodefError('CODEF가 connectedId를 돌려주지 않았습니다.');
  return id;
}

/** 법인카드 승인내역 — 카드사([organization]) 하나의 [from]~[to](YYYY-MM-DD) 줄들(전체 카드). */
export async function fetchCardApprovals({ connectedId, organization, from, to, fetchImpl = fetch }) {
  const data = await callCodef(
    CODEF_CARD_APPROVAL_PATH,
    { connectedId, organization, startDate: codefDay(from), endDate: codefDay(to), orderBy: '0', inquiryType: '1', memberStoreInfoType: '1' },
    { fetchImpl },
  );
  return codefList(data);
}

/** 홈택스 목록([kind] — 'cash_receipt' | 'tax_invoice') — [from]~[to] 매입([direction])의 줄들. */
export async function fetchHometaxDocs({ connectedId, kind, direction = 'purchase', from, to, fetchImpl = fetch }) {
  const path = kind === 'cash_receipt' ? CODEF_CASH_RECEIPT_PATH : CODEF_TAX_INVOICE_PATH;
  if (!path) throw new CodefError('이 종류의 홈택스 상품 주소가 server/.env에 없습니다.', { status: 503 });
  const data = await callCodef(
    path,
    { connectedId, organization: '0001', startDate: codefDay(from), endDate: codefDay(to), orderBy: '0', inquiryType: direction === 'sale' ? '0' : '1' },
    { fetchImpl },
  );
  return codefList(data);
}
