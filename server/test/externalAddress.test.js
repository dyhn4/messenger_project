// 외부 접속 주소(.env EXTERNAL_ADDRESS) 해석 단위 테스트 — `node --test test/*.test.js` (DB·서버 없이 돈다).
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { parseExternalAddress } from '../src/externalAddress.js';

test('비어 있으면 외부 접속을 안 쓰는 것(null)', () => {
  assert.equal(parseExternalAddress(undefined, 3000), null);
  assert.equal(parseExternalAddress('   ', 3000), null);
});

test('포트를 안 적으면 서버 포트를 그대로 쓴다', () => {
  assert.deepEqual(parseExternalAddress('xxx.iptime.org', 3000), {
    host: 'xxx.iptime.org',
    port: 3000,
    url: 'https://xxx.iptime.org:3000',
  });
  assert.equal(parseExternalAddress('203.0.113.5', '3000').url, 'https://203.0.113.5:3000');
});

test('포트를 적으면 그 포트(공유기에서 다른 번호로 포워딩한 경우)', () => {
  assert.equal(parseExternalAddress('xxx.iptime.org:8443', 3000).url, 'https://xxx.iptime.org:8443');
});

test('주소창에서 복사한 https://와 뒤의 경로·슬래시, 대문자는 정리한다', () => {
  assert.equal(parseExternalAddress(' https://XXX.iptime.org:3000/ ', 3000).url, 'https://xxx.iptime.org:3000');
  assert.equal(parseExternalAddress('http://203.0.113.5/login', 3000).url, 'https://203.0.113.5:3000');
});

test('형식이 잘못되면 서버가 조용히 뜨지 않게 예외', () => {
  assert.throws(() => parseExternalAddress('xxx.iptime.org:99999', 3000));
  assert.throws(() => parseExternalAddress('my server', 3000));
  assert.throws(() => parseExternalAddress('2001:db8::1', 3000));
});
