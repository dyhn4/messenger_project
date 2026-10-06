import assert from 'node:assert/strict';
import { test } from 'node:test';

import { isBlockedIp, parseOgTags } from '../src/linkPreview.js';

// 링크 미리보기가 서버를 사내망·자기 자신을 찌르는 데 쓰이지 않게 — 공인 유니캐스트가 아니면 전부 막는다.
test('사설·루프백·링크로컬·CGNAT·멀티캐스트·예약 대역은 막는다', () => {
  for (const ip of [
    '127.0.0.1',
    '10.1.2.3',
    '172.16.0.1',
    '192.168.0.1',
    '169.254.169.254',
    '100.64.0.1',
    '0.0.0.0',
    '224.0.0.1',
    '255.255.255.255',
    '198.18.0.1',
    '::1',
    '::',
    'fe80::1',
    'fd00::1',
    '::ffff:127.0.0.1',
    '::ffff:7f00:1',
    '64:ff9b::7f00:1',
    '2002:7f00:1::',
    'not-an-ip',
  ]) {
    assert.equal(isBlockedIp(ip), true, ip);
  }
});

test('공인 주소는 통과시킨다', () => {
  for (const ip of ['8.8.8.8', '1.1.1.1', '2606:4700:4700::1111', '::ffff:8.8.8.8']) {
    assert.equal(isBlockedIp(ip), false, ip);
  }
});

test('미리보기 그림은 http(s)만, 사설 IP를 직접 적은 주소는 뺀다', () => {
  const page = 'https://example.com/a';
  const og = (src) =>
    parseOgTags(`<meta property="og:title" content="t"><meta property="og:image" content="${src}">`, page);
  assert.equal(og('https://cdn.example.com/x.png').imageUrl, 'https://cdn.example.com/x.png');
  assert.equal(og('/rel.png').imageUrl, 'https://example.com/rel.png');
  assert.equal(og('data:image/png;base64,AAAA').imageUrl, null);
  assert.equal(og('file:///etc/passwd').imageUrl, null);
  assert.equal(og('http://192.168.0.1/admin.png').imageUrl, null);
  assert.equal(og('javascript:alert(1)').imageUrl, null);
});
