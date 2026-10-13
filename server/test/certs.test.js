// 자체 서명 인증서 만들기·다시 만들기(certs.js) — `node --test test/*.test.js`. 임시 폴더에서만 돈다.
// 외부 주소를 넣어 인증서를 다시 만들 때 키가 그대로인지(앱이 공개키를 핀닝하므로 — client pinned_tls.dart)를 본다.
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, test } from 'node:test';
import { ensureTlsCredentials } from '../src/certs.js';

const dirs = [];
function tempDir() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'tangotalk-certs-'));
  dirs.push(dir);
  return dir;
}
afterEach(() => {
  while (dirs.length) fs.rmSync(dirs.pop(), { recursive: true, force: true });
});

/** 인증서의 공개키(SPKI DER) — 앱이 핀닝하는 값. */
const spki = (certPem) => new crypto.X509Certificate(certPem).publicKey.export({ type: 'spki', format: 'der' });

test('처음에는 키와 인증서를 새로 만들고, 주소가 이미 있으면 그대로 쓴다', async () => {
  const dir = tempDir();
  const first = await ensureTlsCredentials({ extraHosts: ['chat.example.org'], dir });
  assert.ok(new crypto.X509Certificate(first.cert).checkHost('chat.example.org'));
  assert.ok(new crypto.X509Certificate(first.cert).checkPrivateKey(crypto.createPrivateKey(first.key)));

  const again = await ensureTlsCredentials({ extraHosts: ['chat.example.org'], dir });
  assert.equal(again.cert, first.cert);
  assert.equal(again.key, first.key);
  assert.deepEqual(fs.readdirSync(dir).sort(), ['cert.pem', 'key.pem']);
});

test('외부 주소를 더하면 키는 그대로 두고 인증서만 새로 만든다', async () => {
  const dir = tempDir();
  const before = await ensureTlsCredentials({ extraHosts: ['old.example.org'], dir });
  const after = await ensureTlsCredentials({ extraHosts: ['new.example.org'], dir });

  assert.notEqual(after.cert, before.cert);
  assert.equal(after.key, before.key);
  assert.equal(fs.readFileSync(path.join(dir, 'key.pem'), 'utf8'), before.key);
  assert.deepEqual(spki(after.cert), spki(before.cert));

  const x509 = new crypto.X509Certificate(after.cert);
  assert.ok(x509.checkHost('new.example.org'));
  assert.ok(x509.checkHost('old.example.org'), '예전 인증서의 주소도 그대로 들어 있어야 한다');
  assert.ok(x509.checkPrivateKey(crypto.createPrivateKey(after.key)));

  // 예전 인증서만 남긴다(키는 바뀌지 않았으니 백업할 것이 없다).
  const backups = fs.readdirSync(dir).filter((f) => f.includes('.bak-'));
  assert.equal(backups.length, 1);
  assert.match(backups[0], /^cert\.pem\.bak-/);
  assert.equal(fs.readFileSync(path.join(dir, backups[0]), 'utf8'), before.cert);
});

test('예전 버전이 만든 PKCS#1 키(BEGIN RSA PRIVATE KEY)도 그대로 이어 쓴다', async () => {
  const dir = tempDir();
  const first = await ensureTlsCredentials({ dir });
  const pkcs1 = crypto.createPrivateKey(first.key).export({ type: 'pkcs1', format: 'pem' });
  fs.writeFileSync(path.join(dir, 'key.pem'), pkcs1);

  const after = await ensureTlsCredentials({ extraHosts: ['chat.example.org'], dir });
  assert.equal(after.key, pkcs1);
  assert.equal(fs.readFileSync(path.join(dir, 'key.pem'), 'utf8'), pkcs1);
  assert.deepEqual(spki(after.cert), spki(first.cert));
  assert.ok(new crypto.X509Certificate(after.cert).checkPrivateKey(crypto.createPrivateKey(pkcs1)));
});
