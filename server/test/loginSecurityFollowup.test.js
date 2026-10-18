// 로그인 보안 후속 규칙 — SAML(설정·메타데이터·프로필 읽기·관리자 입력), 디렉터리 그룹 규칙(그룹 맞추기·할 일 정하기), 보안 키(RP·이름·
// 둘째 단계 방법), Microsoft 로그아웃 주소·프런트 채널 로그아웃, LDAP memberOf. `node --test test/*.test.js`(DB·네트워크 없이 돈다).
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { cnOf, groupMatches, matchingMappings, parseGroupMapping, planGroupSync } from '../src/groupSyncRules.js';
import { entryToProfile, ldapAttributes } from '../src/ldapRules.js';
import { parseLoginSecurityInput } from '../src/loginSecurityRules.js';
import { certToPem, parseCertList, parseIdpMetadata, samlButtonLabel, samlConfigProblem, samlIdentity, samlSpEndpoints } from '../src/samlRules.js';
import { enabledSsoProviders, frontChannelLogoutSession, microsoftLogoutUrl, SSO_PROVIDERS } from '../src/ssoRules.js';
import { defaultPasskeyName, fromB64url, parsePasskeyName, secondFactorMethods, toB64url, webauthnRp } from '../src/webauthnRules.js';

const CERT_BODY = 'MIIC'.padEnd(200, 'A');
const PEM = certToPem(CERT_BODY);
const TENANT = '11111111-2222-3333-4444-555555555555';

test('SAML 설정 — 주소·인증서가 있어야 켜고, 인증서는 PEM 여럿·머리줄 없는 base64 모두', () => {
  assert.equal(samlConfigProblem({ samlEntryPoint: 'https://idp/sso', samlIdpCert: PEM }), null);
  assert.ok(samlConfigProblem({ samlEntryPoint: 'http://idp/sso', samlIdpCert: PEM }), 'http');
  assert.ok(samlConfigProblem({ samlEntryPoint: 'https://idp/sso', samlIdpCert: '아무 글' }));
  assert.ok(samlConfigProblem({ samlEntryPoint: 'https://idp/sso', samlIdpCert: PEM, samlLogoutUrl: 'ftp://x' }));
  assert.deepEqual(parseCertList(`${PEM}\n${certToPem(`${CERT_BODY}B`)}\n${PEM}`), [CERT_BODY, `${CERT_BODY}B`], '겹친 것은 하나로');
  assert.deepEqual(parseCertList(CERT_BODY.match(/.{1,64}/g).join('\n')), [CERT_BODY]);
  assert.deepEqual(samlSpEndpoints('https://chat.example.com/'), {
    entityId: 'https://chat.example.com/auth/sso/saml/metadata',
    metadataUrl: 'https://chat.example.com/auth/sso/saml/metadata',
    acsUrl: 'https://chat.example.com/auth/sso/saml/acs',
    sloUrl: 'https://chat.example.com/auth/sso/saml/slo',
  });
  assert.equal(samlSpEndpoints(null), null);
  assert.equal(samlButtonLabel({ samlLabel: ' Okta로 로그인 ' }), 'Okta로 로그인');
  assert.equal(samlButtonLabel({}), '회사 계정(SAML)');
  // 켜고 값이 다 있어야 로그인 단추에 나온다.
  assert.deepEqual(enabledSsoProviders({ samlEnabled: true, samlEntryPoint: 'https://idp/sso', samlIdpCert: PEM }), ['saml']);
  assert.deepEqual(enabledSsoProviders({ samlEnabled: true, samlEntryPoint: 'https://idp/sso' }), []);
  assert.ok(SSO_PROVIDERS.includes('saml'));
});

test('IdP 메타데이터 — entityID·Redirect 바인딩 로그인/로그아웃 주소·서명 인증서(암호화용은 뺀다)', () => {
  const xml = `<?xml version="1.0"?>
<md:EntityDescriptor xmlns:md="urn:oasis:names:tc:SAML:2.0:metadata" xmlns:ds="http://www.w3.org/2000/09/xmldsig#" entityID="http://adfs.company.local/adfs/services/trust">
 <md:IDPSSODescriptor protocolSupportEnumeration="urn:oasis:names:tc:SAML:2.0:protocol">
  <md:KeyDescriptor use="encryption"><ds:KeyInfo><ds:X509Data><ds:X509Certificate>ENC${CERT_BODY}</ds:X509Certificate></ds:X509Data></ds:KeyInfo></md:KeyDescriptor>
  <md:KeyDescriptor use="signing"><ds:KeyInfo><ds:X509Data><ds:X509Certificate>
   ${CERT_BODY}
  </ds:X509Certificate></ds:X509Data></ds:KeyInfo></md:KeyDescriptor>
  <md:SingleLogoutService Binding="urn:oasis:names:tc:SAML:2.0:bindings:HTTP-POST" Location="https://adfs.company.com/adfs/ls/post"/>
  <md:SingleLogoutService Location="https://adfs.company.com/adfs/ls/" Binding="urn:oasis:names:tc:SAML:2.0:bindings:HTTP-Redirect"/>
  <md:SingleSignOnService Binding="urn:oasis:names:tc:SAML:2.0:bindings:HTTP-Redirect" Location="https://adfs.company.com/adfs/ls/"/>
 </md:IDPSSODescriptor>
</md:EntityDescriptor>`;
  assert.deepEqual(parseIdpMetadata(xml), {
    entityId: 'http://adfs.company.local/adfs/services/trust',
    entryPoint: 'https://adfs.company.com/adfs/ls/',
    logoutUrl: 'https://adfs.company.com/adfs/ls/',
    certs: [CERT_BODY],
  });
  assert.ok(parseIdpMetadata('<html/>').error);
  assert.ok(parseIdpMetadata(xml.replace(/<md:SingleSignOnService[^>]*>/, '')).error, '로그인 주소 없음');
});

test('SAML 프로필 → 사람 정보: 속성 이름 대체, 이메일 형식 NameID, 일회용 NameID는 거절', () => {
  const profile = {
    issuer: 'https://idp',
    nameID: 'E12345',
    nameIDFormat: 'urn:oasis:names:tc:SAML:2.0:nameid-format:persistent',
    sessionIndex: '_s1',
    'http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress': 'Kim@Company.com',
    'http://schemas.microsoft.com/identity/claims/displayname': '김철수',
    'http://schemas.microsoft.com/ws/2008/06/identity/claims/groups': ['g1', 'g2'],
  };
  const r = samlIdentity(profile, { samlEmailAttr: 'email', samlNameAttr: 'displayName', samlGroupsAttr: 'groups' });
  assert.deepEqual(r.identity, {
    subject: 'https://idp|E12345',
    email: 'kim@company.com',
    name: '김철수',
    groups: ['g1', 'g2'],
    sessionIndex: '_s1',
    nameId: 'E12345',
    nameIdFormat: 'urn:oasis:names:tc:SAML:2.0:nameid-format:persistent',
  });
  assert.equal(samlIdentity({ issuer: 'i', nameID: 'lee@company.com' }, {}).identity.email, 'lee@company.com', 'NameID가 이메일');
  assert.ok(samlIdentity({ issuer: 'i', nameID: 'x', nameIDFormat: 'urn:oasis:names:tc:SAML:2.0:nameid-format:transient' }, {}).error);
  assert.ok(samlIdentity(null, {}).error);
});

test('관리자 입력 — SAML 칸·그룹 규칙·보안 키·로그아웃 연동 켜기', () => {
  const r = parseLoginSecurityInput({
    samlEnabled: true,
    samlLabel: 'Okta',
    samlEntryPoint: 'https://okta/sso',
    samlIdpCert: `  ${PEM}  `,
    samlGroupsAttr: 'memberOf',
    groupSyncEnabled: true,
    groupSyncRemove: false,
    passkeyLoginEnabled: false,
    ssoIdpLogout: true,
  });
  assert.equal(r.fields.samlEnabled, true);
  assert.equal(r.fields.samlIdpCert, PEM, 'PEM으로 가지런히');
  assert.equal(r.fields.samlGroupsAttr, 'memberOf');
  assert.equal(r.fields.groupSyncEnabled, true);
  assert.equal(r.fields.passkeyLoginEnabled, false);
  assert.equal(r.fields.ssoIdpLogout, true);
  assert.ok(parseLoginSecurityInput({ samlEntryPoint: 'http://okta' }).error);
  assert.ok(parseLoginSecurityInput({ samlIdpCert: '인증서 아님' }).error);
  assert.ok(parseLoginSecurityInput({ samlEmailAttr: '' }).error);
  assert.ok(parseLoginSecurityInput({ groupSyncEnabled: 'yes' }).error);
});

test('그룹 규칙 입력 — 그룹 이름 필수, 팀이나 등급 중 하나, 아는 출처·등급만', () => {
  assert.deepEqual(parseGroupMapping({ group: ' 영업팀 ', teamId: '11111111-2222-3333-4444-555555555555' }), {
    fields: { source: 'any', group: '영업팀', teamId: '11111111-2222-3333-4444-555555555555', accountRole: null },
  });
  assert.deepEqual(parseGroupMapping({ source: 'ldap', group: 'CN=Admins,DC=c', accountRole: 'admin' }).fields.accountRole, 'admin');
  assert.ok(parseGroupMapping({ group: '영업팀' }).error, '팀·등급 없음');
  assert.ok(parseGroupMapping({ group: '', teamId: '11111111-2222-3333-4444-555555555555' }).error);
  assert.ok(parseGroupMapping({ group: 'g', accountRole: 'owner' }).error);
  assert.ok(parseGroupMapping({ group: 'g', source: 'google', accountRole: 'member' }).error);
  assert.ok(parseGroupMapping({ group: 'g', teamId: 'nope' }).error);
});

test('그룹 맞추기 — 대소문자 무시, LDAP은 DN 전체나 CN만으로도', () => {
  const dn = 'CN=영업팀,OU=Groups,DC=company,DC=local';
  assert.equal(cnOf(dn), '영업팀');
  assert.equal(cnOf('CN=A\\, B,OU=x'), 'A, B');
  assert.equal(cnOf('영업팀'), null);
  assert.equal(groupMatches('영업팀', dn, 'ldap'), true);
  assert.equal(groupMatches('cn=영업팀, ou=groups, dc=company, dc=local', dn, 'ldap'), true, 'DN 공백·대소문자');
  assert.equal(groupMatches('CN=영업팀,OU=Other,DC=company,DC=local', dn, 'ldap'), false, '다른 OU의 같은 이름');
  assert.equal(groupMatches('Sales', 'sales', 'saml'), true);
  assert.equal(groupMatches('Sales', 'Sales Team', 'saml'), false);
  const mappings = [
    { source: 'ldap', group: '영업팀', teamId: 't1', accountRole: null },
    { source: 'saml', group: '영업팀', teamId: 't2', accountRole: null },
    { source: 'any', group: 'Admins', teamId: null, accountRole: 'admin' },
  ];
  assert.deepEqual(
    matchingMappings(mappings, 'ldap', [dn, 'CN=Admins,DC=x']).map((m) => m.teamId),
    ['t1', null],
    '출처가 다른 규칙은 맞추지 않는다',
  );
});

test('할 일 정하기 — 넣을 팀·뺄 팀(규칙으로 넣은 것만)·등급(가장 높은 것, 되돌리기는 규칙이 준 등급일 때만)', () => {
  const mappings = [
    { source: 'any', group: 'sales', teamId: 't1', accountRole: 'member' },
    { source: 'any', group: 'it', teamId: 't2', accountRole: 'admin' },
    { source: 'any', group: 'partners', teamId: 't3', accountRole: 'guest' },
  ];
  const base = { mappings, source: 'saml', currentTeamIds: ['t9'], grantedTeamIds: [], currentRole: 'member', defaultRole: 'member' };
  assert.deepEqual(planGroupSync({ ...base, groups: ['sales', 'it'] }), { addTeamIds: ['t1', 't2'], removeTeamIds: [], role: 'admin', roleReason: 'grant' });
  assert.deepEqual(planGroupSync({ ...base, groups: ['sales'], currentTeamIds: ['t1'] }), { addTeamIds: [], removeTeamIds: [], role: null, roleReason: null });
  // 그룹에서 빠짐 — 빼기가 꺼져 있으면 그대로, 켜져 있으면 규칙으로 넣은 팀만 뺀다(t9는 사람이 넣은 팀).
  const left = { ...base, groups: [], currentTeamIds: ['t1', 't9'], grantedTeamIds: ['t1'], currentRole: 'admin', syncedRole: 'admin' };
  assert.deepEqual(planGroupSync(left), { addTeamIds: [], removeTeamIds: [], role: null, roleReason: null });
  assert.deepEqual(planGroupSync({ ...left, removeUnmatched: true }), { addTeamIds: [], removeTeamIds: ['t1'], role: 'member', roleReason: 'revert' });
  // 관리자가 손으로 올린 등급(규칙이 준 것이 아님)은 되돌리지 않는다.
  assert.equal(planGroupSync({ ...left, removeUnmatched: true, syncedRole: null }).role, null);
  // 이 출처의 규칙이 하나도 없으면 아무것도 안 한다.
  assert.deepEqual(planGroupSync({ ...base, mappings: [{ source: 'ldap', group: 'x', teamId: 't1' }], groups: [] }), {
    addTeamIds: [],
    removeTeamIds: [],
    role: null,
    roleReason: null,
  });
});

test('보안 키 — RP는 웹 앱 주소의 도메인, 이름 검사·기본 이름, 둘째 단계 방법, base64url', () => {
  assert.deepEqual(webauthnRp('https://chat.example.com'), { rpID: 'chat.example.com', origin: 'https://chat.example.com' });
  assert.deepEqual(webauthnRp('https://chat.example.com:8443/'), { rpID: 'chat.example.com', origin: 'https://chat.example.com:8443' });
  assert.equal(webauthnRp('http://chat.example.com'), null);
  assert.equal(webauthnRp('https://192.168.0.10'), null, 'IP 주소는 RP가 될 수 없다');
  assert.equal(webauthnRp(null), null);
  assert.deepEqual(parsePasskeyName('  YubiKey 5 '), { name: 'YubiKey 5' });
  assert.deepEqual(parsePasskeyName(''), { name: '보안 키' });
  assert.ok(parsePasskeyName('가'.repeat(41)).error);
  assert.equal(defaultPasskeyName({ backedUp: true }), '패스키');
  assert.equal(defaultPasskeyName({ transports: ['usb', 'nfc'] }), '보안 키');
  assert.equal(defaultPasskeyName({ transports: ['internal'] }), '이 기기(생체 인증)');
  assert.deepEqual(secondFactorMethods({ totpEnabledAt: new Date(), totpSecretEnc: 'x' }, 2), ['totp', 'webauthn']);
  assert.deepEqual(secondFactorMethods({}, 1), ['webauthn']);
  assert.deepEqual(secondFactorMethods({ totpEnabledAt: new Date() }, 0), [], '비밀 없이 켜짐 표시만 있으면 아님');
  const bytes = new Uint8Array([0, 1, 250, 255]);
  assert.deepEqual(fromB64url(toB64url(bytes)), bytes);
});

test('로그아웃 연동 — Microsoft 로그아웃 주소, 프런트 채널 로그아웃(발급자 확인)', () => {
  assert.equal(
    microsoftLogoutUrl({ ssoMicrosoftTenantId: TENANT }, 'https://chat.example.com/auth/sso/logged-out'),
    `https://login.microsoftonline.com/${TENANT}/oauth2/v2.0/logout?post_logout_redirect_uri=${encodeURIComponent('https://chat.example.com/auth/sso/logged-out')}`,
  );
  assert.equal(microsoftLogoutUrl({ ssoMicrosoftTenantId: 'common' }, null), null);
  const settings = { ssoMicrosoftTenantId: TENANT };
  assert.equal(frontChannelLogoutSession({ sid: 'abc', iss: `https://login.microsoftonline.com/${TENANT}/v2.0` }, settings), 'abc');
  assert.equal(frontChannelLogoutSession({ sid: 'abc' }, settings), 'abc', 'iss 없이도');
  assert.equal(frontChannelLogoutSession({ sid: 'abc', iss: 'https://login.microsoftonline.com/other/v2.0' }, settings), null);
  assert.equal(frontChannelLogoutSession({}, settings), null);
});

test('LDAP — memberOf를 그룹으로 읽고, 가져올 속성에 넣는다', () => {
  const settings = { ldapNameAttr: 'displayName', ldapEmailAttr: 'mail', ldapDepartmentAttr: 'department', ldapTitleAttr: 'title' };
  assert.ok(ldapAttributes(settings).includes('memberOf'));
  const p = entryToProfile({ dn: 'CN=김,OU=U,DC=c', memberOf: ['CN=영업팀,OU=G,DC=c', Buffer.from('CN=전체,OU=G,DC=c')] }, settings);
  assert.deepEqual(p.groups, ['CN=영업팀,OU=G,DC=c', 'CN=전체,OU=G,DC=c']);
  assert.deepEqual(entryToProfile({ dn: 'CN=a' }, settings).groups, []);
});

test('브라우저 페이지 스크립트(보안 키·OAuth 승인)가 문법에 맞는다', async () => {
  process.env.DATABASE_URL ??= 'postgres://test:test@127.0.0.1:1/test';
  const [{ CEREMONY_PAGE_JS }, { AUTHORIZE_JS }] = await Promise.all([import('../src/webauthn.js'), import('../src/oauth.js')]);
  assert.doesNotThrow(() => new Function(CEREMONY_PAGE_JS));
  assert.doesNotThrow(() => new Function(AUTHORIZE_JS));
  assert.ok(CEREMONY_PAGE_JS.includes(".replace(/\\+/g,'-')"), 'base64url 바꾸기(+ → -)');
});
