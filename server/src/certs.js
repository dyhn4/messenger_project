import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import selfsigned from 'selfsigned';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const certsDir = path.join(__dirname, '..', 'certs');
const keyPath = path.join(certsDir, 'key.pem');
const certPath = path.join(certsDir, 'cert.pem');

/** 지금 이 PC의 LAN IPv4 주소들. 인증서 SAN에 넣어서, 클라이언트가 그 주소로 접속해도 인증서가 유효하게 한다. */
function currentLanIps() {
  return Object.values(os.networkInterfaces())
    .flat()
    .filter((i) => i && i.family === 'IPv4' && !i.internal)
    .map((i) => i.address);
}

/**
 * 자체 서명 TLS 인증서/키를 certs/에서 읽어오거나, 없으면 새로 만들어 저장합니다.
 * LAN IP가 바뀌지 않는 한(홈/사무실 공유기는 보통 같은 기기에 같은 IP를 계속 배정합니다)
 * 한 번 만들면 계속 재사용됩니다 — 유효기간을 길게(10년) 잡은 이유이기도 합니다.
 *
 * 클라이언트 앱은 이 인증서(공개 부분, cert.pem)를 빌드에 내장해서 "이 인증서만" 신뢰하도록
 * 설정합니다(핀닝). 그래서 인증서를 새로 만들면 클라이언트도 그 새 cert.pem으로 다시
 * 빌드해야 접속이 됩니다 — LAN IP가 바뀌어서 재생성이 필요해지면 이 점을 꼭 기억하세요.
 */
export async function ensureTlsCredentials() {
  if (fs.existsSync(keyPath) && fs.existsSync(certPath)) {
    return { key: fs.readFileSync(keyPath, 'utf8'), cert: fs.readFileSync(certPath, 'utf8') };
  }

  const altNames = [
    { type: 2, value: 'localhost' },
    { type: 7, ip: '127.0.0.1' },
    { type: 7, ip: '::1' },
    ...currentLanIps().map((ip) => ({ type: 7, ip })),
  ];

  const notBefore = new Date();
  const notAfter = new Date(notBefore);
  notAfter.setFullYear(notAfter.getFullYear() + 10);

  const pems = await selfsigned.generate([{ name: 'commonName', value: 'messenger-server' }], {
    keySize: 2048,
    algorithm: 'sha256',
    notBeforeDate: notBefore,
    notAfterDate: notAfter,
    extensions: [
      { name: 'basicConstraints', cA: false, critical: true },
      { name: 'keyUsage', digitalSignature: true, keyEncipherment: true, critical: true },
      { name: 'extKeyUsage', serverAuth: true },
      { name: 'subjectAltName', altNames },
    ],
  });

  fs.mkdirSync(certsDir, { recursive: true });
  fs.writeFileSync(keyPath, pems.private, { mode: 0o600 });
  fs.writeFileSync(certPath, pems.cert);

  console.log('[certs] 자체 서명 TLS 인증서를 새로 만들었습니다 (certs/cert.pem, certs/key.pem).');
  console.log(`[certs] 포함된 주소: ${altNames.map((a) => a.value ?? a.ip).join(', ')}`);
  console.log('[certs] 클라이언트 앱을 이 인증서로 다시 빌드해야 접속됩니다 (client/assets/server_cert.pem 갱신 필요).');

  return { key: pems.private, cert: pems.cert };
}

export { certPath };
