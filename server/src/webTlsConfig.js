import net from 'node:net';
import { domainToASCII } from 'node:url';

/**
 * 웹 앱 전용 HTTPS 포트(webTls.js) 설정 — .env의 WEB_DOMAIN·WEB_HTTPS_PORT·ACME_HTTP_PORT·ACME_EMAIL·ACME_STAGING을 읽는다.
 * config.js가 부르고, 테스트는 config.js(비밀값 파일을 읽는다) 없이 이 함수만 불러 확인한다.
 *
 * WEB_DOMAIN이 비어 있으면 기능 전체가 꺼진다 — 나머지 값은 보지도 않고(경고도 없이) 지금과 똑같이 돈다.
 * WEB_DOMAIN이나 웹 포트가 잘못됐으면 서버를 못 뜨게 하는 대신 이 기능만 끄고 이유를 [error]로 돌려준다(EXTERNAL_ADDRESS와 같은
 * 방식). 인증서 확인용 HTTP 포트·이메일·staging 값만 잘못됐으면 그 값만 빼고 기능은 켠다([warnings]).
 */
export function readWebTlsConfig(env, { port, pairingPort }) {
  const off = (error) => ({ domain: null, httpsPort: 443, httpPort: 80, email: null, staging: false, error, warnings: [] });
  const rawDomain = String(env.WEB_DOMAIN ?? '').trim();
  if (!rawDomain) return off(null);

  let domain;
  let httpsPort;
  try {
    domain = parseWebDomain(rawDomain);
    httpsPort = parsePortSetting(env.WEB_HTTPS_PORT, { name: 'WEB_HTTPS_PORT', fallback: 443 });
  } catch (e) {
    return off(e.message);
  }
  if (httpsPort === Number(port) || httpsPort === Number(pairingPort)) {
    return off(`WEB_HTTPS_PORT(${httpsPort})가 메인 포트(${port})·페어링 포트(${pairingPort})와 겹칩니다. 다른 번호(기본 443)를 쓰세요.`);
  }

  const warnings = [];
  let httpPort;
  try {
    httpPort = parsePortSetting(env.ACME_HTTP_PORT, { name: 'ACME_HTTP_PORT', fallback: 80, allowZero: true });
  } catch (e) {
    warnings.push(`${e.message} — 인증서 확인용 HTTP 포트 없이(TLS-ALPN-01만) 진행합니다.`);
    httpPort = 0;
  }
  if (httpPort !== 0 && [Number(port), Number(pairingPort), httpsPort].includes(httpPort)) {
    warnings.push(`ACME_HTTP_PORT(${httpPort})가 다른 포트와 겹칩니다 — 인증서 확인용 HTTP 포트 없이(TLS-ALPN-01만) 진행합니다.`);
    httpPort = 0;
  }

  let email = null;
  try {
    email = parseAcmeEmail(env.ACME_EMAIL);
  } catch (e) {
    warnings.push(`${e.message} — 이메일 없이 Let's Encrypt 계정을 만듭니다.`);
  }

  const rawStaging = String(env.ACME_STAGING ?? '').trim().toLowerCase();
  let staging = false;
  if (['1', 'true', 'yes', 'on'].includes(rawStaging)) staging = true;
  else if (!['', '0', 'false', 'no', 'off'].includes(rawStaging)) {
    warnings.push(`ACME_STAGING 값을 알 수 없습니다(${env.ACME_STAGING}) — 1(시험용) 또는 0(정식)만 씁니다. 정식 인증서로 진행합니다.`);
  }

  return { domain, httpsPort, httpPort, email, staging, error: null, warnings };
}

/**
 * WEB_DOMAIN — 도메인 이름만(예: xxx.iptime.org). 대소문자·앞뒤 공백·끝의 점은 정리하고, 한글 도메인은 퓨니코드로 바꾼다.
 * https://·포트·경로를 붙였거나, IP 주소·점 없는 이름·와일드카드면 예외 — Let's Encrypt가 HTTP-01/TLS-ALPN-01로 인증서를 줄 수
 * 있는 건 공개 DNS에 등록된 도메인 이름 하나뿐이고, 포트는 WEB_HTTPS_PORT로 따로 정한다.
 */
export function parseWebDomain(raw) {
  const value = String(raw ?? '').trim().toLowerCase().replace(/\.$/, '');
  if (!value) return null;
  const example = '도메인 이름만 적으세요(예: xxx.iptime.org — https://·포트·경로 없이)';
  if (/[/:?#@\s]/.test(value)) throw new Error(`WEB_DOMAIN 형식이 올바르지 않습니다: ${raw} — ${example}`);
  if (net.isIP(value)) throw new Error(`WEB_DOMAIN에는 IP 주소를 쓸 수 없습니다: ${raw} — ${example}`);
  if (value.includes('*')) throw new Error(`WEB_DOMAIN에는 와일드카드(*)를 쓸 수 없습니다: ${raw} — ${example}`);
  const ascii = domainToASCII(value);
  const label = '[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?';
  const isDomain = new RegExp(`^(?=.{1,253}$)${label}(\\.${label})+$`).test(ascii);
  // 마지막 칸(최상위 도메인)이 숫자뿐이면 도메인이 아니다(예: 1.2.3.4.5).
  if (!ascii || !isDomain || /^\d+$/.test(ascii.split('.').pop())) {
    throw new Error(`WEB_DOMAIN 형식이 올바르지 않습니다: ${raw} — ${example}`);
  }
  return ascii;
}

/** 포트 번호 설정 하나 — 비어 있으면 [fallback]. [allowZero]면 0(끔)도 받는다. */
export function parsePortSetting(raw, { name, fallback, allowZero = false }) {
  const value = String(raw ?? '').trim();
  if (!value) return fallback;
  const n = Number(value);
  if (!/^\d+$/.test(value) || !Number.isInteger(n) || n > 65535 || (n === 0 && !allowZero)) {
    throw new Error(`${name} 값이 올바르지 않습니다: ${raw} (${allowZero ? '0~65535, 0은 끔' : '1~65535'})`);
  }
  return n;
}

/** ACME_EMAIL(선택) — Let's Encrypt 계정 연락처. 형식이 틀리면 Let's Encrypt가 계정 만들기 자체를 거절하므로 미리 거른다. */
export function parseAcmeEmail(raw) {
  const value = String(raw ?? '').trim();
  if (!value) return null;
  if (value.length > 254 || !/^[^\s@<>()[\],;:"]+@[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$/i.test(value)) {
    throw new Error(`ACME_EMAIL 형식이 올바르지 않습니다: ${raw}`);
  }
  return value;
}

/** 웹 앱의 정식 주소(https://도메인[:포트]) — 443이면 포트를 적지 않는다. */
export function webOrigin(domain, httpsPort) {
  return Number(httpsPort) === 443 ? `https://${domain}` : `https://${domain}:${httpsPort}`;
}
