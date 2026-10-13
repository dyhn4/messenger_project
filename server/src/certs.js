import crypto from 'node:crypto';
import fs from 'node:fs';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import selfsigned from 'selfsigned';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const certsDir = path.join(__dirname, '..', 'certs');
const certPath = path.join(certsDir, 'cert.pem');

/** 지금 이 PC의 LAN IPv4 주소들. 인증서 SAN에 넣어서, 클라이언트가 그 주소로 접속해도 인증서가 유효하게 한다. */
function currentLanIps() {
  return Object.values(os.networkInterfaces())
    .flat()
    .filter((i) => i && i.family === 'IPv4' && !i.internal)
    .map((i) => i.address);
}

/** 인증서 SAN에 들어 있는 도메인/IPv4 목록. IPv6는 Node가 펼친 형태(0:0:...:1)로 보여줘서
 * 그대로 다시 넣기 애매하므로 뺀다(필요한 ::1은 새로 만들 때 어차피 기본으로 들어간다). */
function sanEntries(certPem) {
  const san = new crypto.X509Certificate(certPem).subjectAltName ?? '';
  return san
    .split(',')
    .map((s) => s.trim())
    .map((s) => s.replace(/^DNS:/, '').replace(/^IP Address:/, ''))
    .filter((s) => s && !net.isIPv6(s));
}

/** [hosts] 중 이 인증서로는 접속할 수 없는(SAN에 없는) 주소들. */
function hostsMissingFrom(certPem, hosts) {
  const x509 = new crypto.X509Certificate(certPem);
  return hosts.filter((h) => !(net.isIP(h) ? x509.checkIP(h) : x509.checkHost(h)));
}

/**
 * 인증서를 만들어 [dir]에 저장한다. [existingKeyPem]을 주면 그 키로 인증서만 새로 만들고 key.pem은 건드리지 않는다 —
 * 앱은 인증서가 아니라 공개키를 핀닝하므로(client pinned_tls.dart) 키가 같으면 주소만 늘어난 새 인증서에도 그대로 붙는다.
 * 예전 버전(node-forge)이 만든 PKCS#1 키도 읽을 수 있게 PKCS#8로 바꿔서 넘긴다.
 */
async function generateAndSave(dir, hosts, existingKeyPem = null) {
  const names = [...new Set(['localhost', '127.0.0.1', '::1', ...currentLanIps(), ...hosts])];
  const altNames = names.map((n) => (net.isIP(n) ? { type: 7, ip: n } : { type: 2, value: n }));

  const notBefore = new Date();
  const notAfter = new Date(notBefore);
  notAfter.setFullYear(notAfter.getFullYear() + 10);

  let keyPair;
  if (existingKeyPem) {
    const privateKey = crypto.createPrivateKey(existingKeyPem);
    keyPair = {
      privateKey: privateKey.export({ type: 'pkcs8', format: 'pem' }),
      publicKey: crypto.createPublicKey(privateKey).export({ type: 'spki', format: 'pem' }),
    };
  }

  const pems = await selfsigned.generate([{ name: 'commonName', value: 'messenger-server' }], {
    keySize: 2048,
    algorithm: 'sha256',
    notBeforeDate: notBefore,
    notAfterDate: notAfter,
    keyPair,
    extensions: [
      { name: 'basicConstraints', cA: false, critical: true },
      { name: 'keyUsage', digitalSignature: true, keyEncipherment: true, critical: true },
      { name: 'extKeyUsage', serverAuth: true },
      { name: 'subjectAltName', altNames },
    ],
  });

  fs.mkdirSync(dir, { recursive: true });
  const key = existingKeyPem ?? pems.private;
  if (!existingKeyPem) fs.writeFileSync(path.join(dir, 'key.pem'), key, { mode: 0o600 });
  fs.writeFileSync(path.join(dir, 'cert.pem'), pems.cert);

  console.log(
    existingKeyPem
      ? '[certs] 같은 키로 자체 서명 TLS 인증서를 새로 만들었습니다 (certs/cert.pem — certs/key.pem은 그대로).'
      : '[certs] 자체 서명 TLS 인증서를 새로 만들었습니다 (certs/cert.pem, certs/key.pem).',
  );
  console.log(`[certs] 포함된 주소: ${names.join(', ')}`);

  return { key, cert: pems.cert };
}

/**
 * 자체 서명 TLS 인증서/키를 certs/에서 읽어오거나, 없으면 새로 만들어 저장합니다.
 * LAN IP가 바뀌지 않는 한(홈/사무실 공유기는 보통 같은 기기에 같은 IP를 계속 배정합니다)
 * 한 번 만들면 계속 재사용됩니다 — 유효기간을 길게(10년) 잡은 이유이기도 합니다.
 *
 * [extraHosts](.env의 EXTERNAL_ADDRESS — DDNS 도메인/공인 IP)가 지금 인증서에 없으면 그
 * 주소를 넣어 인증서를 **새로 만듭니다**. 기존 인증서에 있던 주소는 전부 그대로 다시 넣고,
 * 예전 파일은 certs/*.bak-<시각>으로 남겨둡니다. 한 번 넣은 주소는 EXTERNAL_ADDRESS를
 * 지워도 인증서에 남아 있을 뿐이라(해가 없음) 다시 만들지 않습니다.
 *
 * 다시 만들 때는 **키(key.pem)를 그대로 쓰고** 인증서만 바꿉니다. 클라이언트 앱은 이 인증서의
 * 공개키를 고정(핀닝)하므로(client pinned_tls.dart), 공개키 핀닝을 하는 버전의 앱은 다시 연결할
 * 필요가 없습니다. 인증서 파일 자체를 고정하던 예전 버전의 앱만 페어링 코드로 다시 연결해야 합니다.
 * 키를 바꾸려면(유출 의심 등) certs/의 key.pem·cert.pem을 지우고 서버를 다시 시작하세요 — 그때는
 * 모든 앱이 다시 연결해야 하고, 그게 맞는 동작입니다.
 *
 * [dir]은 시험용이다(기본은 server/certs).
 */
export async function ensureTlsCredentials({ extraHosts = [], dir = certsDir } = {}) {
  const keyFile = path.join(dir, 'key.pem');
  const certFile = path.join(dir, 'cert.pem');
  if (!fs.existsSync(keyFile) || !fs.existsSync(certFile)) {
    const created = await generateAndSave(dir, extraHosts);
    console.log('[certs] 클라이언트 앱을 이 인증서로 다시 빌드하거나, 페어링 코드로 다시 연결해야 접속됩니다.');
    return created;
  }

  const existing = { key: fs.readFileSync(keyFile, 'utf8'), cert: fs.readFileSync(certFile, 'utf8') };
  const missing = hostsMissingFrom(existing.cert, extraHosts);
  if (missing.length === 0) return existing;

  const stamp = new Date().toISOString().replace(/[-:]/g, '').replace(/\..*$/, '');
  fs.copyFileSync(certFile, `${certFile}.bak-${stamp}`);
  console.log(`[certs] 지금 인증서에 외부 접속 주소(${missing.join(', ')})가 없어 인증서를 새로 만듭니다(키는 그대로). 예전 인증서는 certs/cert.pem.bak-${stamp}로 남겨둡니다.`);

  const created = await generateAndSave(dir, [...sanEntries(existing.cert), ...extraHosts], existing.key);
  console.log('[certs] 키가 같아서 최신 앱은 그대로 접속됩니다. 공개키 핀닝 전 버전의 앱만 "서버 주소 변경"에서');
  console.log('[certs]   페어링 코드로 다시 연결해야 합니다. 이 콘솔에 "pair"를 입력하면 코드가 나옵니다.');
  return created;
}

/**
 * 이 PC의 사내 IPv4 중 [certPem]으로 접속할 수 있는 것들(/server-info의 internalUrls). 사내망 밖에서
 * 외부 주소로 페어링한 앱이 사내로 돌아왔을 때 붙을 주소다. 링크 로컬(169.254.*)은 빼고,
 * 공유기가 흔히 주는 대역(192.168.*, 10.*, 172.16~31.*)을 앞에 둔다.
 */
export function lanAddressesInCert(certPem) {
  const x509 = new crypto.X509Certificate(certPem);
  const rank = (ip) => (/^192\.168\./.test(ip) ? 0 : /^10\./.test(ip) ? 1 : /^172\.(1[6-9]|2\d|3[01])\./.test(ip) ? 2 : 3);
  return currentLanIps()
    .filter((ip) => !ip.startsWith('169.254.') && x509.checkIP(ip))
    .sort((a, b) => rank(a) - rank(b));
}

// certsDir: 웹 앱 전용 포트의 공인 인증서·Let's Encrypt 계정 키도 같은 폴더에 둔다(webTls.js) — 설치 프로그램이 거는 관리자 전용
// 권한(Folder-Acl.ps1)이 그대로 적용되게.
export { certPath, certsDir };
