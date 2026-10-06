import dns from 'node:dns/promises';
import http from 'node:http';
import https from 'node:https';
import net from 'node:net';
import zlib from 'node:zlib';
import ipaddr from 'ipaddr.js';
import { EXTERNAL_ADDRESS } from './config.js';

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

/**
 * SSRF 방지 — 공인 유니캐스트 주소가 아니면(사설·루프백·링크로컬·CGNAT·멀티캐스트·예약·NAT64 등 전부) 요청을
 * 보내지 않는다. 사용자가 보낸 링크로 서버가 사내망(공유기 관리 화면·DB·LiveKit 등)이나 이 서버 자신을 찌르는 데
 * 쓰이지 않게 하려는 것. IPv4가 들어 있는 IPv6(::ffff:a.b.c.d 등)는 그 IPv4로 다시 본다.
 */
export function isBlockedIp(ip) {
  let addr;
  try {
    addr = ipaddr.parse(ip);
  } catch {
    return true; // 알 수 없는 형태는 안전하게 차단.
  }
  if (addr.kind() === 'ipv6' && addr.isIPv4MappedAddress()) addr = addr.toIPv4Address();
  if (addr.range() !== 'unicast') return true;
  if (addr.kind() === 'ipv4' && EXTRA_BLOCKED_V4.some((cidr) => addr.match(cidr))) return true;
  // 이 서버의 공인 주소(공유기 WAN) — 공유기가 안으로 되돌려 보내면(헤어핀 NAT) 공유기 관리 화면이나 이 서버의
  // 다른 포트에 닿는다.
  return selfPublicIps.has(addr.toNormalizedString());
}

/** ipaddr.js가 'unicast'로 보는 특수 대역 — 장비 시험용(198.18/15)·문서 예시용·IETF 예약. */
const EXTRA_BLOCKED_V4 = ['192.0.0.0/24', '192.0.2.0/24', '198.18.0.0/15', '198.51.100.0/24', '203.0.113.0/24'].map(
  (c) => ipaddr.parseCIDR(c),
);

/** 이 서버 자신의 공인 IP들(.env의 EXTERNAL_ADDRESS가 IP면 그것, 도메인이면 처음 한 번 푼 값). */
const selfPublicIps = new Set();
if (EXTERNAL_ADDRESS?.host) {
  if (net.isIP(EXTERNAL_ADDRESS.host)) {
    selfPublicIps.add(ipaddr.parse(EXTERNAL_ADDRESS.host).toNormalizedString());
  } else {
    dns
      .lookup(EXTERNAL_ADDRESS.host, { all: true })
      .then((list) => list.forEach((a) => selfPublicIps.add(ipaddr.parse(a.address).toNormalizedString())))
      .catch(() => {});
  }
}

/**
 * http.request의 lookup — 이름을 풀어서 **실제로 접속할 그 IP**를 검사한다. 검사와 접속 사이에 다시 이름을 풀지
 * 않으므로, 처음엔 공인 IP를 주고 접속할 때 사설 IP를 주는 DNS 리바인딩으로도 우회할 수 없다.
 */
function guardedLookup(hostname, options, callback) {
  dns
    .lookup(hostname, { all: true })
    .then((list) => {
      const usable = list.filter((a) => !isBlockedIp(a.address));
      if (list.length === 0 || usable.length !== list.length) {
        const err = new Error(`차단된 주소입니다: ${hostname}`);
        err.code = 'EBLOCKED';
        throw err;
      }
      if (options?.all) return callback(null, usable);
      callback(null, usable[0].address, usable[0].family);
    })
    .catch((err) => callback(err));
}

const PREVIEW_DEADLINE_MS = 8000; // 리다이렉트·본문까지 통틀어 한 번의 미리보기에 쓰는 최대 시간.
const PREVIEW_MAX_BYTES = 1024 * 1024; // 압축을 푼 본문 기준.
const PREVIEW_MAX_CONCURRENT = 5; // 동시에 받는 미리보기 수 — 넘으면 이번 것은 건너뛴다(부가 기능이라).
let activePreviews = 0;

/**
 * GET 한 번 — 리다이렉트는 따라가지 않고 그대로 돌려준다(호출부가 매 홉 다시 검사). 80/443 포트만 허용한다.
 * 본문은 [maxBytes]까지만 읽고(압축 해제 후 기준), [deadline](ms 시각)이 지나면 끊는다.
 */
function requestOnce(url, deadline, maxBytes) {
  return new Promise((resolve, reject) => {
    const parsed = new URL(url);
    const isHttps = parsed.protocol === 'https:';
    const port = parsed.port ? Number(parsed.port) : isHttps ? 443 : 80;
    if (port !== 80 && port !== 443) return reject(new Error('허용하지 않는 포트입니다.'));
    // 주소창에 IP를 직접 적은 경우는 lookup을 안 거치므로 여기서 본다.
    const literal = parsed.hostname.replace(/^\[|\]$/g, '');
    if (net.isIP(literal) && isBlockedIp(literal)) return reject(new Error('차단된 주소입니다.'));

    const req = (isHttps ? https : http).request(
      {
        protocol: parsed.protocol,
        hostname: parsed.hostname,
        port,
        path: `${parsed.pathname}${parsed.search}`,
        method: 'GET',
        lookup: guardedLookup,
        headers: {
          'User-Agent': 'Mozilla/5.0 (compatible; TangoTalkLinkPreview/1.0)',
          Accept: 'text/html,application/xhtml+xml;q=0.9,*/*;q=0.1',
          'Accept-Encoding': 'gzip, deflate, br',
        },
      },
      (res) => {
        const status = res.statusCode ?? 0;
        const headers = res.headers;
        if (status >= 300 && status < 400) {
          res.resume();
          return resolve({ status, headers, body: '' });
        }
        const encoding = String(headers['content-encoding'] ?? '').toLowerCase();
        const stream =
          encoding === 'gzip'
            ? res.pipe(zlib.createGunzip())
            : encoding === 'deflate'
              ? res.pipe(zlib.createInflate())
              : encoding === 'br'
                ? res.pipe(zlib.createBrotliDecompress())
                : res;
        const chunks = [];
        let received = 0;
        stream.on('data', (chunk) => {
          received += chunk.length;
          chunks.push(chunk);
          if (received >= maxBytes) {
            // 필요한 만큼은 받았다 — 나머지는 버리고 끝낸다(og 태그는 보통 <head>에 있다).
            req.destroy();
            resolve({ status, headers, body: Buffer.concat(chunks).subarray(0, maxBytes).toString('utf8') });
          }
        });
        stream.on('end', () => resolve({ status, headers, body: Buffer.concat(chunks).toString('utf8') }));
        stream.on('error', reject);
      },
    );
    const remaining = deadline - Date.now();
    if (remaining <= 0) {
      req.destroy();
      return reject(new Error('시간 초과'));
    }
    req.setTimeout(remaining, () => req.destroy(new Error('시간 초과')));
    const timer = setTimeout(() => req.destroy(new Error('시간 초과')), remaining);
    req.on('close', () => clearTimeout(timer));
    req.on('error', reject);
    req.end();
  });
}

/** 리다이렉트를 직접 따라가며(최대 3번) 매 홉 주소·포트를 다시 검사한다. 응답이 없거나 막히면 null. */
async function safeFetch(startUrl, maxRedirects = 3) {
  const deadline = Date.now() + PREVIEW_DEADLINE_MS;
  let url = startUrl;
  for (let i = 0; i <= maxRedirects; i++) {
    const parsed = new URL(url);
    if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') return null;
    const res = await requestOnce(url, deadline, PREVIEW_MAX_BYTES);
    if (res.status >= 300 && res.status < 400) {
      const location = res.headers.location;
      if (!location) return null;
      url = new URL(location, url).toString();
      continue;
    }
    return { ...res, url };
  }
  return null; // 리다이렉트가 너무 많음 — 포기.
}

/** 미리보기 그림 주소로 써도 되는지 — http(s)만, 사설 IP를 직접 적은 주소는 뺀다(보는 사람의 앱·브라우저가 그 주소를
 * 불러오게 되므로, 사내 기기를 찌르는 데 쓰이지 않게). 안 되면 null. */
function safeImageUrl(u) {
  try {
    const parsed = new URL(u);
    if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') return null;
    const host = parsed.hostname.replace(/^\[|\]$/g, '');
    if (net.isIP(host) && isBlockedIp(host)) return null;
    return parsed.toString();
  } catch {
    return null;
  }
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

/** og:image가 없는 페이지(더쿠 등 일부 커뮤니티 게시판 — 글 안에 사진은 있는데 오픈그래프
 * 태그를 안 채움)를 위해, 본문에 있는 첫 실제 사진을 썸네일 대신 쓴다. 로고·아이콘·이모티콘
 * 같은 작은 UI 이미지는 width/height·src 이름으로 걸러낸다. */
function extractFallbackImage(html, pageUrl) {
  const imgRe = /<img\b[^>]*>/gi;
  let m;
  while ((m = imgRe.exec(html))) {
    const tag = m[0];
    const src = tag.match(/\bsrc=["']([^"']+)["']/i)?.[1];
    if (!src || src.startsWith('data:')) continue;
    const width = Number(tag.match(/\bwidth=["']?(\d+)/i)?.[1] ?? NaN);
    const height = Number(tag.match(/\bheight=["']?(\d+)/i)?.[1] ?? NaN);
    if ((Number.isFinite(width) && width < 150) || (Number.isFinite(height) && height < 150)) continue;
    if (/logo|icon|avatar|emoticon|emoji|sprite|spacer|blank|pixel\.(gif|png)/i.test(src)) continue;
    try {
      const resolved = safeImageUrl(new URL(src, pageUrl).toString());
      if (!resolved) continue;
      return resolved;
    } catch {
      continue;
    }
  }
  return null;
}

/** @visibleForTesting — fetchLinkPreview의 네트워크 요청 없이 HTML 파싱만 단위 테스트하기
 * 위해 내보낸다. */
export function parseOgTags(html, pageUrl) {
  const title =
    extractMetaContent(html, 'og:title') ??
    html.match(/<title[^>]*>([^<]*)<\/title>/i)?.[1]?.trim() ??
    null;
  const description = extractMetaContent(html, 'og:description') ?? extractMetaContent(html, 'description');
  let imageUrl = extractMetaContent(html, 'og:image');
  const siteName = extractMetaContent(html, 'og:site_name');

  if (imageUrl) {
    try {
      imageUrl = safeImageUrl(new URL(imageUrl, pageUrl).toString());
    } catch {
      imageUrl = null;
    }
  }
  if (!imageUrl) imageUrl = extractFallbackImage(html, pageUrl);
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
  if (activePreviews >= PREVIEW_MAX_CONCURRENT) return null;
  activePreviews++;
  try {
    const res = await safeFetch(url);
    if (!res || res.status < 200 || res.status >= 300) return null;
    const contentType = String(res.headers['content-type'] ?? '');
    if (!contentType.includes('text/html')) return null;
    return parseOgTags(res.body, res.url || url);
  } catch {
    return null;
  } finally {
    activePreviews--;
  }
}
