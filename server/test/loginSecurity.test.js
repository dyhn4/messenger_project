// 로그인 보안 규칙 — 2단계 인증(TOTP — RFC 6238 시험 값), 회사 계정(SSO) ID 토큰 확인, 사내 디렉터리(LDAP) 검색 조건, 관리자 입력
// 검사. `node --test test/*.test.js`(DB·네트워크 없이 돈다).
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import { test } from 'node:test';
import {
  base32Decode,
  base32Encode,
  generateRecoveryCodes,
  hashRecoveryCodes,
  hotp,
  normalizeTotpCode,
  otpauthUri,
  totpAt,
  totpStep,
  useRecoveryCode,
  verifyTotp,
} from '../src/totp.js';
import {
  buildAuthorizeUrl,
  decodeJwtPayload,
  enabledSsoProviders,
  pkceChallenge,
  ssoConfigProblem,
  usernameFromEmail,
  validateIdTokenClaims,
} from '../src/ssoRules.js';
import {
  buildUserFilter,
  entryToProfile,
  escapeLdapFilterValue,
  isLdapUrl,
  ldapConfigProblem,
  subjectSearch,
  userFilterProblem,
} from '../src/ldapRules.js';
import {
  ldapConnectionChanged,
  localPasswordBlockedText,
  loginMethodsView,
  loginSecurityView,
  otpRequiredFor,
  parseLoginSecurityInput,
  usesLocalPassword,
} from '../src/loginSecurityRules.js';

const keyHash = (s) => crypto.createHmac('sha256', 'test').update(s).digest('hex');

test('TOTP — RFC 6238 부록 B의 SHA1 시험 값(앞 6자리), base32 왕복', () => {
  const secret = base32Encode(Buffer.from('12345678901234567890'));
  assert.equal(secret, 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ');
  assert.deepEqual(base32Decode(secret.toLowerCase().replace(/(.{4})/g, '$1 ')), Buffer.from('12345678901234567890'));
  for (const [t, code] of [
    [59, '287082'],
    [1111111109, '081804'],
    [1111111111, '050471'],
    [1234567890, '005924'],
    [2000000000, '279037'],
  ]) {
    assert.equal(totpAt(secret, t * 1000), code, `t=${t}`);
  }
  assert.equal(hotp(Buffer.from('12345678901234567890'), 0), '755224', 'RFC 4226 부록 D');
  assert.equal(base32Decode('1!'), null);
});

test('TOTP 확인 — 앞뒤 한 칸까지, 이미 쓴 칸은 거절, 모양이 틀리면 거절', () => {
  const secret = base32Encode(Buffer.from('12345678901234567890'));
  const now = 1234567890 * 1000;
  const code = totpAt(secret, now);
  const r = verifyTotp(secret, `${code.slice(0, 3)} ${code.slice(3)}`, { nowMs: now });
  assert.equal(r.ok, true);
  assert.equal(r.step, totpStep(now));
  assert.equal(verifyTotp(secret, totpAt(secret, now - 30_000), { nowMs: now }).ok, true, '휴대폰 시계가 30초 늦어도');
  assert.equal(verifyTotp(secret, totpAt(secret, now - 90_000), { nowMs: now }).ok, false, '3칸 전은 안 된다');
  assert.equal(verifyTotp(secret, code, { nowMs: now, lastStep: r.step }).ok, false, '같은 칸의 코드를 다시 쓰지 못한다');
  assert.equal(verifyTotp(secret, '12345', { nowMs: now }).ok, false);
  assert.equal(normalizeTotpCode('12a456'), null);
  const uri = otpauthUri({ secret, account: 'hong' });
  assert.match(uri, /^otpauth:\/\/totp\/TangoTalk%3Ahong\?secret=GEZD.*&issuer=TangoTalk.*digits=6.*period=30/);
});

test('복구 코드 — 10개, 한 번 쓰면 빠지고 다시 못 쓴다, 대소문자·하이픈은 봐준다', () => {
  const codes = generateRecoveryCodes();
  assert.equal(codes.length, 10);
  assert.ok(codes.every((c) => /^[a-z2-9]{5}-[a-z2-9]{5}$/.test(c)));
  const hashes = hashRecoveryCodes(codes, keyHash);
  const first = useRecoveryCode(hashes, codes[3].toUpperCase().replace('-', ' '), keyHash);
  assert.equal(first.ok, true);
  assert.equal(first.remaining.length, 9);
  assert.equal(useRecoveryCode(first.remaining, codes[3], keyHash).ok, false);
  assert.equal(useRecoveryCode(hashes, 'short', keyHash).ok, false);
});

const google = {
  ssoGoogleEnabled: true,
  ssoGoogleClientId: 'gid.apps.googleusercontent.com',
  ssoGoogleClientSecretEnc: 'enc',
  ssoGoogleDomains: 'company.com',
};
const tenant = '11111111-2222-3333-4444-555555555555';
const microsoft = {
  ssoMicrosoftEnabled: true,
  ssoMicrosoftTenantId: tenant,
  ssoMicrosoftClientId: 'mid',
  ssoMicrosoftClientSecretEnc: 'enc',
};

test('SSO 설정 — 값이 다 있어야 켜지고, Google은 회사 도메인이 꼭 있어야 한다', () => {
  assert.equal(ssoConfigProblem('google', google), null);
  assert.match(ssoConfigProblem('google', { ...google, ssoGoogleDomains: '' }), /회사 도메인/);
  assert.match(ssoConfigProblem('microsoft', { ...microsoft, ssoMicrosoftTenantId: 'common' }), /테넌트/);
  assert.deepEqual(enabledSsoProviders({ ...google, ...microsoft }), ['google', 'microsoft']);
  assert.deepEqual(enabledSsoProviders({ ...google, ssoGoogleEnabled: false }), []);
  const url = new URL(
    buildAuthorizeUrl({
      provider: 'google',
      settings: google,
      redirectUri: 'https://chat.company.com/auth/sso/callback',
      state: 's',
      nonce: 'n',
      codeChallenge: pkceChallenge('v'.repeat(43)),
    }),
  );
  assert.equal(url.origin, 'https://accounts.google.com');
  assert.equal(url.searchParams.get('hd'), 'company.com');
  assert.equal(url.searchParams.get('code_challenge_method'), 'S256');
  assert.equal(url.searchParams.get('scope'), 'openid email profile');
});

test('SSO ID 토큰 — 발급자·대상·만료·nonce·회사(hd/tid)를 모두 본다', () => {
  const now = Date.now();
  const sec = Math.floor(now / 1000);
  const base = { iss: 'https://accounts.google.com', aud: google.ssoGoogleClientId, exp: sec + 600, iat: sec, nonce: 'n' };
  const ok = validateIdTokenClaims({
    provider: 'google',
    settings: google,
    claims: { ...base, sub: '123', email: 'Hong@Company.com', email_verified: true, hd: 'company.com', name: '홍길동' },
    nonce: 'n',
    nowMs: now,
  });
  assert.deepEqual(ok.identity, { subject: '123', email: 'hong@company.com', name: '홍길동' });
  const bad = (claims, nonce = 'n') =>
    validateIdTokenClaims({ provider: 'google', settings: google, claims: { ...base, sub: '1', email_verified: true, hd: 'company.com', ...claims }, nonce, nowMs: now }).error;
  assert.ok(bad({ iss: 'https://evil.example' }));
  assert.ok(bad({ aud: 'other-client' }));
  assert.ok(bad({ exp: sec - 3600 }));
  assert.ok(bad({}, 'other-nonce'));
  assert.match(bad({ hd: undefined }), /허용한 회사/, '개인 Gmail(hd 없음)은 안 된다');
  assert.match(bad({ hd: 'other.com' }), /허용한 회사/);
  assert.ok(bad({ email_verified: false }));

  const ms = validateIdTokenClaims({
    provider: 'microsoft',
    settings: microsoft,
    claims: {
      iss: `https://login.microsoftonline.com/${tenant}/v2.0`,
      aud: 'mid',
      exp: sec + 600,
      nonce: 'n',
      tid: tenant,
      oid: 'ABC',
      preferred_username: 'kim@company.com',
      name: '김철수',
    },
    nonce: 'n',
    nowMs: now,
  });
  assert.deepEqual(ms.identity, { subject: `${tenant}:abc`, email: 'kim@company.com', name: '김철수' });
  assert.match(
    validateIdTokenClaims({
      provider: 'microsoft',
      settings: microsoft,
      claims: { iss: `https://login.microsoftonline.com/${tenant}/v2.0`, aud: 'mid', exp: sec + 600, nonce: 'n', tid: 'other', oid: 'x' },
      nonce: 'n',
      nowMs: now,
    }).error,
    /허용한 회사/,
  );
  assert.equal(decodeJwtPayload('a.b'), null);
  assert.deepEqual(decodeJwtPayload(`x.${Buffer.from('{"a":1}').toString('base64url')}.y`), { a: 1 });
});

test('회사 계정 이메일로 새 아이디 — 규칙에 맞게 다듬고, 있으면 숫자를 붙인다', async () => {
  const taken = new Set(['hong', 'hong2']);
  assert.equal(await usernameFromEmail('Hong@company.com', async (u) => taken.has(u)), 'hong3');
  assert.equal(await usernameFromEmail('a.b@x.com', async () => false), 'usera.b');
  assert.equal(await usernameFromEmail('_홍_kim+tag@x.com', async () => false), 'kimtag');
});

test('LDAP — 검색 조건 이스케이프(조건을 바꾸거나 남의 계정을 고르지 못하게), 항목 읽기, 다시 찾기', () => {
  assert.equal(escapeLdapFilterValue('a*)(uid=*'), 'a\\2a\\29\\28uid=\\2a');
  assert.equal(buildUserFilter('(&(objectClass=user)(sAMAccountName={username}))', 'kim'), '(&(objectClass=user)(sAMAccountName=kim))');
  assert.equal(buildUserFilter('uid={username}', 'x\\y'), '(uid=x\\5cy)');
  assert.match(userFilterProblem('(uid=x)'), /\{username\}/);
  assert.match(userFilterProblem('((uid={username})'), /괄호/);
  assert.equal(isLdapUrl('ldaps://dc01.company.local:636'), true);
  assert.equal(isLdapUrl('http://dc01'), false);
  const settings = { ldapNameAttr: 'displayName', ldapEmailAttr: 'mail', ldapDepartmentAttr: 'department', ldapTitleAttr: 'title' };
  const guid = Buffer.from('0123456789abcdef');
  const p = entryToProfile(
    {
      dn: 'CN=Kim,OU=Dev,DC=company,DC=local',
      objectGUID: guid,
      displayName: ['김철수'],
      mail: 'Kim@Company.com',
      department: '개발팀',
      title: '대리',
      userAccountControl: '514',
    },
    settings,
  );
  assert.equal(p.subject, `guid:${guid.toString('base64')}`);
  assert.equal(p.email, 'kim@company.com');
  assert.equal(p.disabled, true, '514 = 512(일반) + 2(사용 안 함)');
  assert.equal(entryToProfile({ dn: 'CN=A', userAccountControl: '512' }, settings).subject, 'dn:cn=a');
  assert.equal(subjectSearch(p.subject, 'DC=company,DC=local').filter, '(objectGUID=\\30\\31\\32\\33\\34\\35\\36\\37\\38\\39\\61\\62\\63\\64\\65\\66)');
  assert.deepEqual(subjectSearch('dn:CN=A', 'x'), { base: 'CN=A', scope: 'base', filter: '(objectClass=*)' });
  assert.equal(ldapConfigProblem({ ldapUrl: 'ldap://dc', ldapBaseDn: 'DC=a', ldapUserFilter: '(sAMAccountName={username})' }), null);
  assert.match(ldapConfigProblem({ ldapUrl: 'ldap://dc', ldapBaseDn: 'DC=a', ldapBindDn: 'CN=svc', ldapUserFilter: '(a={username})' }), /비밀번호/);
});

test('2단계 인증 정책·로그인 방법', () => {
  assert.equal(otpRequiredFor('optional', { role: 'admin' }), false);
  assert.equal(otpRequiredFor('admins', { role: 'admin' }), true);
  assert.equal(otpRequiredFor('admins', { role: 'member', isServerAdmin: true }), true);
  assert.equal(otpRequiredFor('admins', { role: 'member' }), false);
  assert.equal(otpRequiredFor('all', { role: 'guest' }), true);
  assert.equal(usesLocalPassword({ authSource: 'local' }), true);
  assert.equal(usesLocalPassword({}), true, '예전 계정(컬럼 전)도 아이디 계정');
  assert.equal(usesLocalPassword({ authSource: 'ldap' }), false);
  assert.match(localPasswordBlockedText({ authSource: 'sso' }), /비밀번호가 없습니다/);
  assert.equal(localPasswordBlockedText({ authSource: 'local' }), null);
});

test('관리자 입력 검사 — 값 모양, 비밀값은 평문 칸으로(저장 전에 암호화), 연결 값이 바뀌었는지', () => {
  assert.deepEqual(parseLoginSecurityInput({ otpPolicy: 'admins' }).fields, { otpPolicy: 'admins' });
  assert.ok(parseLoginSecurityInput({ otpPolicy: 'always' }).error);
  assert.match(parseLoginSecurityInput({ ssoGoogleDomains: 'gmail.com' }).error, /gmail/);
  assert.equal(parseLoginSecurityInput({ ssoGoogleDomains: 'A.com, b.co.kr' }).fields.ssoGoogleDomains, 'a.com, b.co.kr');
  assert.match(parseLoginSecurityInput({ ssoMicrosoftTenantId: 'contoso.com' }).error, /GUID/);
  assert.match(parseLoginSecurityInput({ ldapUrl: 'http://x' }).error, /ldap/);
  assert.ok(parseLoginSecurityInput({ ldapUserFilter: '(uid=x)' }).error);
  assert.ok(parseLoginSecurityInput({ ldapDefaultRole: 'admin' }).error, '자동 생성 계정은 관리자가 될 수 없다');
  assert.ok(parseLoginSecurityInput({ ssoSessionDays: 0 }).error);
  assert.deepEqual(parseLoginSecurityInput({ ldapBindPassword: 'pw', ssoGoogleClientSecret: '' }).fields, {
    ldapBindPassword: 'pw',
    ssoGoogleClientSecret: null,
  });
  assert.equal(ldapConnectionChanged({ ldapUrl: 'ldap://a' }, { ldapUrl: 'ldap://b' }), true);
  assert.equal(ldapConnectionChanged({ ldapUrl: 'ldap://a' }, { ldapUrl: 'ldap://a', ldapAutoCreate: false }), false);
  const view = loginSecurityView({ ...google, ldapBindPasswordEnc: 'x', ldapUrl: 'ldap://dc' }, { redirectUri: 'https://x/auth/sso/callback' });
  assert.equal(view.sso.google.hasClientSecret, true);
  assert.equal(view.ldap.hasBindPassword, true);
  assert.ok(!JSON.stringify(view).includes('"enc"'), '비밀값은 내려보내지 않는다');
  assert.deepEqual(loginMethodsView({ ...google, otpPolicy: 'all' }, { redirectReady: false }), { sso: [], ldap: false, otpPolicy: 'all' });
});

test('연결: 로그인은 디렉터리·2단계 인증을 거치고, DTO는 비밀값을 싣지 않는다', () => {
  const auth = fs.readFileSync(new URL('../src/auth.js', import.meta.url), 'utf8');
  assert.match(auth, /return completeLogin\(res, user, \{ method: directory\.profile \? "ldap" : "password" \}\)/);
  assert.match(auth, /user\.authSource === "ldap" && !\(await directoryAccountActive\(user\)\)/);
  const users = fs.readFileSync(new URL('../src/users.js', import.meta.url), 'utf8');
  assert.ok(!/totpSecretEnc|totpRecoveryHashes/.test(users.slice(users.indexOf('export function selfUser'), users.indexOf('export function selfUser') + 900)));
});
