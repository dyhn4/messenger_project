// OAuth 앱 규칙 — 돌아갈 주소 검사·맞춰 보기(이 PC 안 주소의 포트), 권한 글, PKCE, 승인 코드, 앱 확인 헤더.
// `node --test test/*.test.js`(DB·네트워크 없이 돈다).
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { test } from 'node:test';
import {
  clientCredentialsOf,
  generateUserCode,
  isCodeChallenge,
  normalizeUserCode,
  oauthRequestExpired,
  parseOAuthScope,
  parseRedirectUri,
  parseRedirectUris,
  redirectLabel,
  redirectUriMatches,
  redirectWith,
  verifyPkce,
} from '../src/oauthRules.js';

test('돌아갈 주소: https·이 PC 안 http·앱 스킴만, #·계정 정보는 안 된다', () => {
  assert.deepEqual(parseRedirectUri('https://dash.example.com/cb'), { uri: 'https://dash.example.com/cb' });
  assert.deepEqual(parseRedirectUri('http://127.0.0.1:8765/cb'), { uri: 'http://127.0.0.1:8765/cb' });
  assert.deepEqual(parseRedirectUri('http://localhost/cb'), { uri: 'http://localhost/cb' });
  assert.deepEqual(parseRedirectUri('com.example.tool:/oauth'), { uri: 'com.example.tool:/oauth' });
  assert.ok(parseRedirectUri('http://dash.example.com/cb').error, '바깥 http');
  assert.ok(parseRedirectUri('https://x.example/cb#frag').error);
  assert.ok(parseRedirectUri('https://u:p@x.example/cb').error);
  assert.ok(parseRedirectUri('javascript:alert(1)').error, '점 없는 스킴');
  assert.ok(parseRedirectUri('').error);
  assert.deepEqual(parseRedirectUris('https://a.example/cb\nhttps://a.example/cb, http://127.0.0.1/cb'), {
    uris: ['https://a.example/cb', 'http://127.0.0.1/cb'],
  });
  assert.deepEqual(parseRedirectUris(undefined), { uris: [] });
  assert.ok(parseRedirectUris(Array.from({ length: 11 }, (_, i) => `https://a.example/${i}`)).error);
});

test('돌아갈 주소 맞추기 — 그대로 같거나, 이 PC 안 http는 포트만 달라도 된다', () => {
  const reg = ['https://dash.example.com/cb', 'http://127.0.0.1/callback'];
  assert.equal(redirectUriMatches(reg, 'https://dash.example.com/cb'), true);
  assert.equal(redirectUriMatches(reg, 'https://dash.example.com/cb2'), false);
  assert.equal(redirectUriMatches(reg, 'http://127.0.0.1:53121/callback'), true, '빈 포트를 그때그때');
  assert.equal(redirectUriMatches(reg, 'http://127.0.0.1:53121/other'), false);
  assert.equal(redirectUriMatches(reg, 'http://localhost:53121/callback'), false, '등록한 호스트와 같아야');
  assert.equal(redirectUriMatches(reg, 'https://dash.example.com:8443/cb'), false, 'https는 포트도 같아야');
  assert.equal(redirectUriMatches(null, 'x'), false);
});

test('권한 글 — 비우면 읽기, write는 읽기 포함, 모르는 것은 invalid_scope', () => {
  assert.deepEqual(parseOAuthScope(''), { scopes: ['read'] });
  assert.deepEqual(parseOAuthScope('read write'), { scopes: ['read', 'write'] });
  assert.deepEqual(parseOAuthScope('write'), { scopes: ['read', 'write'] });
  assert.deepEqual(parseOAuthScope('admin'), { error: 'invalid_scope' });
});

test('PKCE(S256) — 같은 계산이면 맞고, 모양이 틀리면 거른다', () => {
  const verifier = crypto.randomBytes(32).toString('base64url');
  const challenge = crypto.createHash('sha256').update(verifier).digest('base64url');
  assert.equal(isCodeChallenge(challenge), true);
  assert.equal(verifyPkce(verifier, challenge), true);
  assert.equal(verifyPkce(`${verifier}x`, challenge), false);
  assert.equal(verifyPkce('short', challenge), false);
  assert.equal(verifyPkce(verifier, 'nope'), false);
});

test('승인 코드 — XXXX-XXXX, 넣을 때는 대소문자·띄어쓰기·대시를 가리지 않는다', () => {
  const code = generateUserCode();
  assert.match(code, /^[B-Z2-9]{4}-[B-Z2-9]{4}$/);
  assert.equal(normalizeUserCode(code.toLowerCase().replace('-', ' ')), code);
  assert.equal(normalizeUserCode('ABCD-EFGH'), null, '쓰지 않는 글자(A·E)');
  assert.equal(normalizeUserCode('BCD'), null);
  assert.equal(normalizeUserCode(null), null);
});

test('돌아갈 주소에 값 붙이기·앱 확인 헤더·만료·보이는 이름', () => {
  assert.equal(redirectWith('https://a.example/cb', { code: 'c 1', state: null }), 'https://a.example/cb?code=c%201');
  assert.equal(redirectWith('https://a.example/cb?x=1', { code: 'c', state: 's' }), 'https://a.example/cb?x=1&code=c&state=s');
  const basic = `Basic ${Buffer.from('ttc_id:tts_secret').toString('base64')}`;
  assert.deepEqual(clientCredentialsOf(basic, {}), { clientId: 'ttc_id', clientSecret: 'tts_secret' });
  assert.deepEqual(clientCredentialsOf(undefined, { client_id: 'ttc_id' }), { clientId: 'ttc_id', clientSecret: null });
  assert.equal(oauthRequestExpired({ expiresAt: new Date(1000) }, 2000), true);
  assert.equal(oauthRequestExpired({ expiresAt: new Date(3000) }, 2000), false);
  assert.equal(oauthRequestExpired(null), true);
  assert.equal(redirectLabel('https://dash.example.com/cb'), 'dash.example.com');
  assert.equal(redirectLabel('com.example.tool:/oauth'), 'com.example.tool');
});
