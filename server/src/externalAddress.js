import net from 'node:net';

/**
 * 외부(LTE/5G 등 사내망 밖)에서 이 서버에 접속할 주소 — .env의 EXTERNAL_ADDRESS.
 * 공유기에서 포트포워딩을 해두고 DDNS 도메인(예: xxx.iptime.org)이나 고정 공인 IP를 적는다.
 *
 * 받는 형식: "xxx.iptime.org", "203.0.113.5", "xxx.iptime.org:8443", "https://xxx.iptime.org:3000/"
 * — 사람이 주소창에서 복사해 붙여넣어도 되게 앞의 https://와 뒤의 경로·슬래시는 떼어낸다.
 * 포트를 안 적으면 서버 포트(PORT)를 그대로 쓴다(공유기에서 같은 번호로 포워딩한 경우).
 *
 * 이 값은 두 군데 쓰인다: ①TLS 인증서의 주소 목록(certs.js — 없으면 인증서를 새로 만든다)
 * ②앱이 /server-info로 받아가서 저장해두는 외부 주소(사내 주소로 연결이 안 되면 이걸로 전환).
 *
 * @returns {{ host: string, port: number, url: string } | null} 비어 있으면 null,
 *   형식이 잘못됐으면 예외(서버가 잘못된 설정으로 조용히 뜨지 않게 한다).
 */
export function parseExternalAddress(raw, defaultPort) {
  let value = String(raw ?? '').trim();
  if (!value) return null;

  value = value.replace(/^https?:\/\//i, '').replace(/[/?#].*$/, '');

  let host = value;
  let port = Number(defaultPort);
  const portMatch = value.match(/^(.+):(\d{1,5})$/);
  if (portMatch && !net.isIPv6(value)) {
    host = portMatch[1];
    port = Number(portMatch[2]);
  }
  host = host.toLowerCase();

  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw new Error(`EXTERNAL_ADDRESS의 포트가 올바르지 않습니다: ${raw}`);
  }
  // IPv4이거나 도메인(영문·숫자·하이픈, 점으로 구분)만 받는다. IPv6 공인 주소는 지금은 안 받는다.
  const isDomain = /^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$/.test(host);
  if (!net.isIPv4(host) && !isDomain) {
    throw new Error(`EXTERNAL_ADDRESS 형식이 올바르지 않습니다(도메인 또는 IPv4만 가능): ${raw}`);
  }

  return { host, port, url: `https://${host}:${port}` };
}
