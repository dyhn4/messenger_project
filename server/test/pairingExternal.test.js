// 평문 페어링 서버를 사내망 밖에 열었을 때 열어줄 경로(pairingPaths.js) 단위 테스트 — `node --test test/*.test.js`.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { allowedFromOutside } from '../src/pairingPaths.js';

test('밖에서는 초대 안내 페이지·설치 파일·도움말만 열린다', () => {
  for (const p of ['/invite/abc123', '/invite/abc123/', '/invite/abc123/download/android', '/team-invite/t1/download/windows', '/guide', '/guide/', '/guide/img/a.png']) {
    assert.equal(allowedFromOutside(p), true, p);
  }
});

test('인증서를 평문으로 주는 /pair, 코드 발급, 그 밖의 경로는 밖에서 막힌다', () => {
  for (const p of ['/pair/1234', '/pair/abc123', '/admin/generate', '/', '/guidex', '/invite', '/invite/a/b', '/invite/a/download/../../x']) {
    assert.equal(allowedFromOutside(p), false, p);
  }
});
