// Let's Encrypt 발급기(acme.js)의 응답 해석·안내 문구·계정 키 단위 테스트 — `node --test test/*.test.js` (네트워크·DB 없음).
// 실제 acme-client로 가짜 ACME 서버와 주고받는 흐름은 acmeFlow.test.js.
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import {
  ACME_TOKEN_PATTERN,
  RATE_LIMITED,
  loadOrCreateAccountKey,
  parseRetryAfter,
  problemFromResponse,
  rateLimitMessage,
  retryAfterFromDetail,
} from '../src/acme.js';

const NOW = Date.parse('2026-10-07T12:00:00Z');
const quietLog = { log() {}, warn() {}, error() {} };

test('Retry-After: 초·HTTP 날짜를 읽고, 지난 시각·이상한 값은 null', () => {
  assert.equal(parseRetryAfter('3600', NOW), 3600 * 1000);
  assert.equal(parseRetryAfter(' 86400 ', NOW), 86400 * 1000);
  assert.equal(parseRetryAfter('Thu, 08 Oct 2026 12:00:00 GMT', NOW), 24 * 3600 * 1000);
  assert.equal(parseRetryAfter('Tue, 06 Oct 2026 12:00:00 GMT', NOW), null);
  assert.equal(parseRetryAfter('0', NOW), null);
  assert.equal(parseRetryAfter('soon', NOW), null);
  assert.equal(parseRetryAfter(undefined, NOW), null);
});

test('Retry-After 머리글이 없으면 한도 문구의 "retry after <시각>"에서 읽는다', () => {
  const detail = 'too many certificates (50) already issued for "iptime.org" in the last 168h0m0s, retry after 2026-10-09 12:00:00 UTC: see https://letsencrypt.org/docs/rate-limits/';
  assert.equal(retryAfterFromDetail(detail, NOW), 2 * 24 * 3600 * 1000);
  assert.equal(retryAfterFromDetail('retry after 2026-10-07T13:30:00Z', NOW), 90 * 60 * 1000);
  assert.equal(retryAfterFromDetail('no hint here', NOW), null);
});

test('문제 문서 꺼내기: 오류 응답(종류·Retry-After), 내용 없는 429·5xx, invalid로 끝난 챌린지', () => {
  assert.deepEqual(
    problemFromResponse({ status: 429, headers: { 'retry-after': '7200' }, data: { type: RATE_LIMITED, detail: 'too many' } }),
    { type: RATE_LIMITED, detail: 'too many', status: 429, retryAfterMs: 7200 * 1000, source: 'response' },
  );
  assert.equal(problemFromResponse({ status: 429, headers: {}, data: '' }).type, RATE_LIMITED);
  assert.equal(problemFromResponse({ status: 503, headers: {}, data: 'busy' }).type, 'urn:ietf:params:acme:error:serverInternal');
  assert.deepEqual(
    problemFromResponse({
      status: 200,
      headers: {},
      data: { type: 'http-01', status: 'invalid', error: { type: 'urn:ietf:params:acme:error:connection', detail: 'Timeout during connect', status: 400 } },
    }),
    { type: 'urn:ietf:params:acme:error:connection', detail: 'Timeout during connect', status: 400, retryAfterMs: null, source: 'challenge' },
  );
  assert.equal(problemFromResponse({ status: 200, headers: {}, data: { status: 'valid' } }), null);
  assert.equal(problemFromResponse({ status: 201, headers: {}, data: 'PEM' }), null);
  assert.equal(problemFromResponse(undefined), null);
});

test('한도 안내: iptime.org 주간 한도는 모든 사용자가 함께 쓴다는 설명과 CNAME 제안, 다시 시도할 시각을 담는다', () => {
  const weekly = 'too many certificates (50) already issued for "iptime.org" in the last 168h0m0s, retry after 2026-10-09 12:00:00 UTC';
  for (const detail of [weekly, '']) {
    const msg = rateLimitMessage('xxx.iptime.org', NOW + 3600 * 1000, detail);
    assert.match(msg, /iptime\.org/);
    assert.match(msg, /50장/);
    assert.match(msg, /CNAME/);
    assert.match(msg, /갱신은 이 한도에 걸리지 않습니다/);
    assert.match(msg, /이후에 자동으로 다시 시도/);
  }
  const other = rateLimitMessage('chat.example.com', null, 'too many certificates (50) already issued for "example.com"');
  assert.doesNotMatch(other, /iptime/);
  assert.match(other, /나중에 자동으로 다시 시도/);
});

test('한도 안내: 다른 한도(확인 실패 잦음·같은 인증서 5장·일시 중지)는 iptime 주간 한도 탓을 하지 않고 할 일을 알려 준다', () => {
  const failed = rateLimitMessage('xxx.iptime.org', null, 'too many failed authorizations (5) for "xxx.iptime.org" in the last 1h0m0s');
  assert.match(failed, /1시간에 5번/);
  assert.doesNotMatch(failed, /50장/);
  const duplicate = rateLimitMessage('xxx.iptime.org', null, 'too many certificates (5) already issued for this exact set of identifiers in the last 168h0m0s');
  assert.match(duplicate, /7일에 5장/);
  assert.doesNotMatch(duplicate, /50장/);
  const paused = rateLimitMessage('xxx.iptime.org', null, 'Your account is temporarily prevented from requesting certificates for xxx.iptime.org; please visit https://portal.letsencrypt.org/sfe/v1/unpause?jwt=abc');
  assert.match(paused, /일시 중지/);
  assert.doesNotMatch(paused, /jwt=/, '해제 링크(토큰)는 상태 문구에 넣지 않는다 — 서버 로그에만');
});

test('챌린지 토큰은 base64url 글자만', () => {
  assert.ok(ACME_TOKEN_PATTERN.test(crypto.randomBytes(32).toString('base64url')));
  for (const bad of ['', 'a/b', 'a.b', '../x', 'a b', 'a?b', 'x'.repeat(257)]) assert.equal(ACME_TOKEN_PATTERN.test(bad), false, bad);
});

test('계정 키: 처음 한 번 ECDSA P-256으로 만들어 두고 다음부터 그대로 쓴다 — 깨진 파일은 옆에 남기고 새로', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'acme-key-'));
  try {
    const file = path.join(dir, 'certs', 'acme-account.key');
    const created = await loadOrCreateAccountKey(file, quietLog);
    const key = crypto.createPrivateKey(created);
    assert.equal(key.asymmetricKeyType, 'ec');
    assert.equal(key.asymmetricKeyDetails.namedCurve, 'prime256v1');
    assert.equal(await loadOrCreateAccountKey(file, quietLog), created, '같은 키를 계속 쓴다');

    fs.writeFileSync(file, 'not a key');
    const replaced = await loadOrCreateAccountKey(file, quietLog);
    assert.notEqual(replaced, created);
    assert.ok(fs.readdirSync(path.dirname(file)).some((name) => name.startsWith('acme-account.key.broken-')), '깨진 파일은 남겨 둔다');
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
