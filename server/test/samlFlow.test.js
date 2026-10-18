// 회사 계정 로그인(SAML 2.0) — 시험 안에서 IdP를 흉내 내 서명한 응답을 만들고, 이 서버의 설정(saml.js samlClient)이 그것을 받고
// 남의 로그인 응답·고친 응답·서명 없는 응답·다른 대상의 응답은 거절하는지 본다(실제 서명 확인은 @node-saml/node-saml). 로그아웃 요청
// 주소에 서명이 붙는지, SP 메타데이터에 entityID·ACS가 들어가는지도. DB·네트워크 없이 돈다(DB 모듈은 불러오기만 한다).
import assert from 'node:assert/strict';
import { test } from 'node:test';
import zlib from 'node:zlib';
import selfsigned from 'selfsigned';
import { SignedXml } from 'xml-crypto';
import { samlIdentity } from '../src/samlRules.js';

process.env.DATABASE_URL ??= 'postgres://test:test@127.0.0.1:1/test';
const { requestIdStore, samlClient } = await import('../src/saml.js');

const WEB = 'https://chat.example.com';
const ENTITY = `${WEB}/auth/sso/saml/metadata`;
const ACS = `${WEB}/auth/sso/saml/acs`;
const IDP = 'https://idp.example.com/saml';

const idp = await selfsigned.generate([{ name: 'commonName', value: 'idp.example.com' }], { keySize: 2048, algorithm: 'sha256' });
const sp = await selfsigned.generate([{ name: 'commonName', value: 'sp' }], { keySize: 2048, algorithm: 'sha256' });
const spKeys = { privateKey: sp.private, cert: sp.cert };
const settings = {
  samlEntryPoint: `${IDP}/sso`,
  samlIdpIssuer: IDP,
  samlIdpCert: idp.cert,
  samlLogoutUrl: `${IDP}/slo`,
  samlEmailAttr: 'email',
  samlNameAttr: 'displayName',
  samlGroupsAttr: 'groups',
};

/** 이 로그인의 요청 id 보관함 + 저장된 요청 id를 엿볼 수 있게. */
function storeWithIds() {
  const store = requestIdStore();
  const ids = [];
  const save = store.saveAsync.bind(store);
  store.saveAsync = async (key, value) => {
    ids.push(key);
    return save(key, value);
  };
  return { store, ids };
}

const client = (store) => samlClient(settings, spKeys, { cacheProvider: store, webBase: WEB });

/** IdP처럼 — [inResponseTo]에 대한 응답을 만들고 Assertion에 서명한다. */
function idpResponse({ inResponseTo, nameId = 'kim@company.com', audience = ENTITY, sign = true, key = idp.private, cert = idp.cert }) {
  const now = new Date();
  const later = new Date(now.getTime() + 5 * 60 * 1000).toISOString();
  const before = new Date(now.getTime() - 60 * 1000).toISOString();
  const xml =
    `<samlp:Response xmlns:samlp="urn:oasis:names:tc:SAML:2.0:protocol" xmlns:saml="urn:oasis:names:tc:SAML:2.0:assertion" ID="_resp${Date.now()}" Version="2.0" IssueInstant="${now.toISOString()}" Destination="${ACS}" InResponseTo="${inResponseTo}">` +
    `<saml:Issuer>${IDP}</saml:Issuer><samlp:Status><samlp:StatusCode Value="urn:oasis:names:tc:SAML:2.0:status:Success"/></samlp:Status>` +
    `<saml:Assertion ID="_as${Date.now()}" Version="2.0" IssueInstant="${now.toISOString()}"><saml:Issuer>${IDP}</saml:Issuer>` +
    `<saml:Subject><saml:NameID Format="urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress">${nameId}</saml:NameID>` +
    `<saml:SubjectConfirmation Method="urn:oasis:names:tc:SAML:2.0:cm:bearer"><saml:SubjectConfirmationData InResponseTo="${inResponseTo}" NotOnOrAfter="${later}" Recipient="${ACS}"/></saml:SubjectConfirmation></saml:Subject>` +
    `<saml:Conditions NotBefore="${before}" NotOnOrAfter="${later}"><saml:AudienceRestriction><saml:Audience>${audience}</saml:Audience></saml:AudienceRestriction></saml:Conditions>` +
    `<saml:AuthnStatement AuthnInstant="${now.toISOString()}" SessionIndex="_session42"><saml:AuthnContext><saml:AuthnContextClassRef>urn:oasis:names:tc:SAML:2.0:ac:classes:Password</saml:AuthnContextClassRef></saml:AuthnContext></saml:AuthnStatement>` +
    `<saml:AttributeStatement><saml:Attribute Name="displayName"><saml:AttributeValue>김철수</saml:AttributeValue></saml:Attribute>` +
    `<saml:Attribute Name="groups"><saml:AttributeValue>영업팀</saml:AttributeValue><saml:AttributeValue>관리자</saml:AttributeValue></saml:Attribute></saml:AttributeStatement>` +
    `</saml:Assertion></samlp:Response>`;
  if (!sign) return Buffer.from(xml).toString('base64');
  const sig = new SignedXml({
    privateKey: key,
    publicCert: cert,
    signatureAlgorithm: 'http://www.w3.org/2001/04/xmldsig-more#rsa-sha256',
    canonicalizationAlgorithm: 'http://www.w3.org/2001/10/xml-exc-c14n#',
  });
  sig.addReference({
    xpath: "//*[local-name(.)='Assertion']",
    digestAlgorithm: 'http://www.w3.org/2001/04/xmlenc#sha256',
    transforms: ['http://www.w3.org/2000/09/xmldsig#enveloped-signature', 'http://www.w3.org/2001/10/xml-exc-c14n#'],
  });
  sig.computeSignature(xml, { location: { reference: "//*[local-name(.)='Assertion']/*[local-name(.)='Issuer']", action: 'after' } });
  return Buffer.from(sig.getSignedXml()).toString('base64');
}

/** 로그인 하나 시작 — IdP 로그인 주소와 그 요청 id. */
async function startLogin(state = 'state-1') {
  const { store, ids } = storeWithIds();
  const url = await client(store).getAuthorizeUrlAsync(state, undefined, {});
  return { store, url: new URL(url), requestId: ids[0] };
}

test('로그인 주소 — IdP 주소로, RelayState는 로그인 state, AuthnRequest는 이 서버의 entityID·ACS로(서명 포함)', async () => {
  const { url, requestId } = await startLogin('my-state');
  assert.equal(`${url.origin}${url.pathname}`, `${IDP}/sso`);
  assert.equal(url.searchParams.get('RelayState'), 'my-state');
  assert.ok(url.searchParams.get('Signature'), '서명한 요청');
  const request = zlib.inflateRawSync(Buffer.from(url.searchParams.get('SAMLRequest'), 'base64')).toString('utf8');
  assert.match(request, new RegExp(`ID="${requestId}"`));
  assert.match(request, new RegExp(`AssertionConsumerServiceURL="${ACS}"`));
  assert.match(request, new RegExp(`<saml:Issuer[^>]*>${ENTITY}</saml:Issuer>`));
});

test('IdP가 서명한 응답 → NameID·이메일·이름·그룹·세션 번호', async () => {
  const { store, requestId } = await startLogin();
  const { profile } = await client(store).validatePostResponseAsync({ SAMLResponse: idpResponse({ inResponseTo: requestId }) });
  const r = samlIdentity(profile, settings);
  assert.equal(r.identity.subject, `${IDP}|kim@company.com`);
  assert.equal(r.identity.email, 'kim@company.com');
  assert.equal(r.identity.name, '김철수');
  assert.deepEqual(r.identity.groups, ['영업팀', '관리자']);
  assert.equal(r.identity.sessionIndex, '_session42');
  // 같은 응답을 다시 보내면(되보내기) 요청 id를 이미 써서 거절된다.
  await assert.rejects(client(store).validatePostResponseAsync({ SAMLResponse: idpResponse({ inResponseTo: requestId }) }));
});

test('다른 로그인의 응답·서명 없음·고친 응답·다른 IdP 키·다른 대상은 거절', async () => {
  const a = await startLogin('a');
  const b = await startLogin('b');
  await assert.rejects(
    client(b.store).validatePostResponseAsync({ SAMLResponse: idpResponse({ inResponseTo: a.requestId }) }),
    '다른 로그인이 보낸 요청에 대한 응답',
  );
  await assert.rejects(client(a.store).validatePostResponseAsync({ SAMLResponse: idpResponse({ inResponseTo: a.requestId, sign: false }) }));
  const tampered = Buffer.from(
    Buffer.from(idpResponse({ inResponseTo: a.requestId }), 'base64').toString('utf8').replace('kim@company.com</saml:NameID>', 'boss@company.com</saml:NameID>'),
  ).toString('base64');
  await assert.rejects(client(a.store).validatePostResponseAsync({ SAMLResponse: tampered }), '서명 뒤에 NameID를 바꿈');
  const other = await selfsigned.generate([{ name: 'commonName', value: 'evil' }], { keySize: 2048, algorithm: 'sha256' });
  await assert.rejects(
    client(a.store).validatePostResponseAsync({ SAMLResponse: idpResponse({ inResponseTo: a.requestId, key: other.private, cert: other.cert }) }),
    '등록하지 않은 키로 서명',
  );
  const c = await startLogin('c');
  await assert.rejects(
    client(c.store).validatePostResponseAsync({ SAMLResponse: idpResponse({ inResponseTo: c.requestId, audience: 'https://other.example/sp' }) }),
    '다른 서비스(대상)에 준 응답',
  );
});

test('로그아웃 요청 주소에 서명이 붙고, SP 메타데이터에 entityID·ACS·SLO가 들어간다', async () => {
  const c = samlClient(settings, spKeys, { webBase: WEB });
  const url = new URL(
    await c.getLogoutUrlAsync(
      { issuer: IDP, nameID: 'kim@company.com', nameIDFormat: 'urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress', sessionIndex: '_session42' },
      '',
      {},
    ),
  );
  assert.equal(`${url.origin}${url.pathname}`, `${IDP}/slo`);
  assert.ok(url.searchParams.get('Signature'));
  const xml = c.generateServiceProviderMetadata(null, sp.cert);
  assert.match(xml, new RegExp(`entityID="${ENTITY}"`));
  assert.match(xml, new RegExp(`Location="${ACS}"`));
  assert.match(xml, new RegExp(`Location="${WEB}/auth/sso/saml/slo"`));
});
