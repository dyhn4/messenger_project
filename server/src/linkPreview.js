import dns from 'node:dns/promises';
import net from 'node:net';

const URL_REGEX = /https?:\/\/[^\s<>"']+/i;

/** 텍스트에서 처음 나오는 http(s) URL 하나만 뽑는다(문장 끝의 마침표/쉼표 등은 잘라낸다). */
export function extractFirstUrl(text) {
  if (!text) return null;
  const m = text.match(URL_REGEX);
  if (!m) return null;
  return m[0].replace(/[.,;:!?)\]}'"]+$/, '');
}

/** 텍스트에 나오는 http(s) URL 전부 — 나온 순서대로, 같은 주소는 한 번만("링크" 모아보기). */
export function extractUrls(text) {
  if (!text) return [];
  const all = text.match(new RegExp(URL_REGEX.source, 'gi')) ?? [];
  return [...new Set(all.map((u) => u.replace(/[.,;:!?)\]}'"]+$/, '')))];
}

/**
 * "링크" 모아보기의 검색어([q], 소문자)가 펼친 한 줄(메시지의 링크 하나)에 해당하는지. 메시지 단위 SQL 조건은 "그 메시지의 어느 글자든
 * 맞으면" 통과시키므로, 링크가 여럿인 메시지에서 검색어가 한 주소에만 들어 있으면 나머지 주소 줄도 딸려 나온다. 그래서 줄마다 다시 본다:
 * 그 주소·그 줄의 미리보기 제목/사이트 이름에 있거나, 주소를 뺀 본문(링크에 곁들인 설명)에 있으면 해당한다. q가 없으면 항상 해당.
 */
export function linkRowMatchesQuery(q, { url, text, urls = [], title = null, siteName = null }) {
  if (!q) return true;
  const has = (s) => typeof s === 'string' && s.toLowerCase().includes(q);
  if (has(url) || has(title) || has(siteName)) return true;
  let body = text ?? '';
  for (const u of urls) body = body.split(u).join(' ');
  return has(body);
}

/** SSRF 방지 — 사설/루프백/링크로컬 IP로는 절대 요청을 보내지 않는다(내부망 스캔에 쓰이는 걸
 * 막는다). 호스트명이 아니라 실제로 접속하는 IP를 봐야 하므로 dns.lookup 결과를 검사한다. */
function isPrivateIp(ip) {
  if (net.isIPv4(ip)) {
    const [a, b] = ip.split('.').map(Number);
    if (a === 10) return true;
    if (a === 127) return true;
    if (a === 0) return true;
    if (a === 169 && b === 254) return true; // 링크 로컬(클라우드 메타데이터 등)
    if (a === 172 && b >= 16 && b <= 31) return true;
    if (a === 192 && b === 168) return true;
    return false;
  }
  if (net.isIPv6(ip)) {
    const lower = ip.toLowerCase();
    if (lower === '::1' || lower === '::') return true;
    if (lower.startsWith('fe80')) return true; // 링크 로컬
    if (/^f[cd][0-9a-f]{2}:/.test(lower)) return true; // fc00::/7 고유 로컬
    if (lower.startsWith('::ffff:')) {
      const v4 = lower.slice(7);
      if (net.isIPv4(v4)) return isPrivateIp(v4);
    }
    return false;
  }
  return true; // 알 수 없는 형태는 안전하게 차단.
}

/** 호스트가 사설 IP로 풀리면 null을 돌려준다(호출부가 요청 자체를 건너뛰게). */
async function resolvesToPrivateIp(hostname) {
  let addresses;
  try {
    addresses = await dns.lookup(hostname, { all: true });
  } catch {
    return true; // DNS 실패도 안전하게 "위험"으로 취급해서 요청 안 보낸다.
  }
  return addresses.length === 0 || addresses.some((a) => isPrivateIp(a.address));
}

/** redirect:'manual'로 직접 따라가면서, 매 홉마다 DNS를 다시 확인한다 — fetch의 자동
 * 리다이렉트를 그냥 쓰면 첫 URL만 검사하고 "거기서 사설 IP로 302 리다이렉트"하는 SSRF
 * 우회에 뚫린다. */
async function safeFetch(startUrl, maxRedirects = 3) {
  let url = startUrl;
  for (let i = 0; i <= maxRedirects; i++) {
    const parsed = new URL(url);
    if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') return null;
    if (await resolvesToPrivateIp(parsed.hostname)) return null;

    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 5000);
    let res;
    try {
      res = await fetch(url, {
        signal: controller.signal,
        redirect: 'manual',
        headers: { 'User-Agent': 'Mozilla/5.0 (compatible; TangoTalkLinkPreview/1.0)' },
      });
    } finally {
      clearTimeout(timer);
    }
    if (res.status >= 300 && res.status < 400) {
      const location = res.headers.get('location');
      if (!location) return null;
      url = new URL(location, url).toString();
      continue;
    }
    return res;
  }
  return null; // 리다이렉트가 너무 많음 — 포기.
}

async function readLimited(res, maxBytes) {
  const reader = res.body?.getReader?.();
  if (!reader) return await res.text();
  let received = 0;
  const chunks = [];
  while (received < maxBytes) {
    const { done, value } = await reader.read();
    if (done) break;
    chunks.push(value);
    received += value.length;
  }
  try {
    await reader.cancel();
  } catch {
    // 이미 끝났거나 취소 불가 — 무시.
  }
  return Buffer.concat(chunks.map((c) => Buffer.from(c))).toString('utf8');
}

function decodeHtmlEntities(str) {
  return str
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#0?39;/g, "'");
}

/** <meta property="og:x" content="..."> / <meta content="..." property="og:x"> 둘 다(속성
 * 순서가 페이지마다 다름) 정규식으로 잡는다 — cheerio 같은 HTML 파서 의존성을 새로 추가하지
 * 않고 오픈그래프 태그만 가볍게 긁어오는 용도라 이 정도면 충분하다. */
function extractMetaContent(html, property) {
  const escaped = property.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const patterns = [
    new RegExp(`<meta[^>]+(?:property|name)=["']${escaped}["'][^>]*content=["']([^"']*)["']`, 'i'),
    new RegExp(`<meta[^>]+content=["']([^"']*)["'][^>]*(?:property|name)=["']${escaped}["']`, 'i'),
  ];
  for (const re of patterns) {
    const m = html.match(re);
    if (m) return decodeHtmlEntities(m[1].trim());
  }
  return null;
}

function parseOgTags(html, pageUrl) {
  const title =
    extractMetaContent(html, 'og:title') ??
    html.match(/<title[^>]*>([^<]*)<\/title>/i)?.[1]?.trim() ??
    null;
  const description = extractMetaContent(html, 'og:description') ?? extractMetaContent(html, 'description');
  let imageUrl = extractMetaContent(html, 'og:image');
  const siteName = extractMetaContent(html, 'og:site_name');

  if (imageUrl) {
    try {
      imageUrl = new URL(imageUrl, pageUrl).toString();
      if (imageUrl.startsWith('javascript:')) imageUrl = null;
    } catch {
      imageUrl = null;
    }
  }
  if (!title && !description && !imageUrl) return null;

  return {
    url: pageUrl,
    title: title ? title.slice(0, 200) : null,
    description: description ? description.slice(0, 500) : null,
    imageUrl,
    siteName: (siteName ?? new URL(pageUrl).hostname).slice(0, 100),
  };
}

/** [url]의 오픈그래프 정보를 가져온다. 뭐든 실패하면(네트워크, SSRF 차단, HTML 아님, 태그
 * 없음 등) 조용히 null을 돌려준다 — 링크 미리보기는 "있으면 좋은" 부가 기능이라 실패해도
 * 메시지 전송 자체에는 전혀 영향이 없어야 한다(socket.js에서 fire-and-forget으로 부른다). */
export async function fetchLinkPreview(url) {
  try {
    const res = await safeFetch(url);
    if (!res || !res.ok) return null;
    const contentType = res.headers.get('content-type') || '';
    if (!contentType.includes('text/html')) return null;
    const html = await readLimited(res, 1024 * 1024);
    return parseOgTags(html, res.url || url);
  } catch {
    return null;
  }
}
