import { SAML, ValidateInResponseTo } from '@node-saml/node-saml';
import selfsigned from 'selfsigned';
import { decryptField, encryptField } from './crypto.js';
import { getServerSettings, updateServerSettings } from './db/queries/serverSettings.js';
import { parseCertList, samlIdentity, samlSpEndpoints } from './samlRules.js';
import { getWebPublicUrl } from './webAddress.js';

/**
 * 회사 계정 로그인(SAML 2.0) — 이 서버가 SP(서비스 제공자)로서 IdP(ADFS·Okta·OneLogin·Keycloak 등)에 로그인을 청하고 받은 응답을
 * 확인한다. 서명·암호 계산은 @node-saml/node-saml(XML 서명 감싸기 공격 등을 막는 검증된 구현)이 하고, 여기서는 설정을 이어 준다.
 * 흐름(SP가 먼저 청하는 방식만 — IdP가 먼저 보낸 응답은 받지 않는다):
 *  1. 앱이 /auth/sso/start로 시작 → 서버가 AuthnRequest를 담은 IdP 로그인 주소(HTTP-Redirect, RelayState=로그인 state)를 준다.
 *  2. IdP가 로그인 뒤 서명한 응답을 브라우저로 /auth/sso/saml/acs에 POST → 그 로그인이 보낸 요청(InResponseTo)에 대한 응답인지, 서명·
 *     발급자·대상(이 서버 entityID)·시각을 확인한다(로그인마다 따로 둔 요청 id 보관함 — 다른 로그인의 응답을 끼워 넣지 못하게).
 *  3. NameID·속성(이메일·이름·그룹)으로 계정을 고른다(sso.js — Google·Microsoft와 같다).
 * 로그아웃(SLO — /auth/sso/saml/slo): IdP가 보낸 LogoutRequest(서명 확인)로 그 세션을 끝내고 LogoutResponse로 답한다(ssoSessions.js).
 * 이 앱에서 로그아웃할 때 회사 계정에서도 로그아웃하게 하면 서명한 LogoutRequest 주소를 만든다.
 *
 * 이 서버의 서명 키(AuthnRequest·LogoutRequest에 서명 — IdP가 서명을 요구할 때)와 인증서는 처음 필요할 때 만들어 server_settings에
 * 둔다(키는 암호화). SP 메타데이터(/auth/sso/saml/metadata)에 그 인증서가 들어간다.
 */

/** 이 서버(SP)의 서명 키·인증서 — 없으면 만든다(10년). `{ privateKey, cert }`. */
export async function ensureSpKeys(settings = null) {
  const s = settings ?? (await getServerSettings());
  const existing = s.samlSpPrivateKeyEnc ? decryptField(s.samlSpPrivateKeyEnc) : null;
  if (existing && s.samlSpCert) return { privateKey: existing, cert: s.samlSpCert };
  const notAfter = new Date();
  notAfter.setFullYear(notAfter.getFullYear() + 10);
  const pems = await selfsigned.generate([{ name: 'commonName', value: 'tangotalk-saml-sp' }], {
    keySize: 2048,
    algorithm: 'sha256',
    notAfterDate: notAfter,
  });
  await updateServerSettings({ samlSpPrivateKeyEnc: encryptField(pems.private), samlSpCert: pems.cert });
  return { privateKey: pems.private, cert: pems.cert };
}

/**
 * 로그인 하나의 요청 id 보관함(node-saml cacheProvider) — 그 로그인이 보낸 AuthnRequest의 id만 든다. 응답의 InResponseTo가 이것과
 * 맞아야 받는다(ValidateInResponseTo.always).
 */
export function requestIdStore() {
  const map = new Map();
  return {
    async saveAsync(key, value) {
      if (map.has(key)) return null;
      map.set(key, { value, createdAt: Date.now() });
      return { value, createdAt: Date.now() };
    },
    async getAsync(key) {
      return map.get(key)?.value ?? null;
    },
    async removeAsync(key) {
      if (!key) return null;
      const had = map.get(key)?.value ?? null;
      map.delete(key);
      return had;
    },
  };
}

/** node-saml 하나 — 이 서버의 주소·키와 IdP 설정으로. [webBase]는 시험이 웹 앱 주소 대신 넣는다. */
export function samlClient(
  settings,
  keys,
  { cacheProvider = requestIdStore(), validateInResponseTo = ValidateInResponseTo.always, webBase = getWebPublicUrl() } = {},
) {
  const ep = samlSpEndpoints(webBase);
  if (!ep) throw new Error('웹 앱 주소(WEB_DOMAIN)가 없습니다.');
  return new SAML({
    entryPoint: settings.samlEntryPoint,
    issuer: ep.entityId,
    callbackUrl: ep.acsUrl,
    audience: ep.entityId,
    idpCert: parseCertList(settings.samlIdpCert),
    idpIssuer: settings.samlIdpIssuer || undefined,
    privateKey: keys.privateKey,
    publicCert: keys.cert,
    signatureAlgorithm: 'sha256',
    digestAlgorithm: 'sha256',
    wantAssertionsSigned: true,
    wantAuthnResponseSigned: false,
    validateInResponseTo,
    requestIdExpirationPeriodMs: 10 * 60 * 1000,
    cacheProvider,
    // NameID 형식은 IdP가 정하게 둔다(일회용이면 samlRules.js가 거절한다). ADFS가 "비밀번호 로그인" 요구에 걸리지 않게 인증 방식 요청은 뺀다.
    identifierFormat: null,
    disableRequestedAuthnContext: true,
    acceptedClockSkewMs: 2 * 60 * 1000,
    maxAssertionAgeMs: 10 * 60 * 1000,
    logoutUrl: settings.samlLogoutUrl || settings.samlEntryPoint,
    logoutCallbackUrl: ep.sloUrl,
  });
}

/** 로그인 주소 — [state]를 RelayState로 실어 IdP가 돌려보내게 한다. [store]는 이 로그인의 요청 id 보관함. */
export async function samlAuthorizeUrl({ state, store, settings = null }) {
  const s = settings ?? (await getServerSettings());
  const keys = await ensureSpKeys(s);
  return samlClient(s, keys, { cacheProvider: store }).getAuthorizeUrlAsync(state, undefined, {});
}

/**
 * ACS에 온 응답 확인 → `{ identity }` | `{ error }`. [store]는 그 로그인의 요청 id 보관함(다른 로그인의 응답·IdP가 먼저 보낸 응답은
 * InResponseTo가 맞지 않아 거절된다).
 */
export async function validateSamlLogin({ body, store, settings = null }) {
  const s = settings ?? (await getServerSettings());
  const keys = await ensureSpKeys(s);
  try {
    const { profile } = await samlClient(s, keys, { cacheProvider: store }).validatePostResponseAsync({ SAMLResponse: body.SAMLResponse });
    return samlIdentity(profile, s);
  } catch (err) {
    console.warn('[saml] 응답 확인 실패:', err?.message ?? err);
    const status = err?.xmlStatus ? ` — IdP 상태 ${String(err.xmlStatus).split(':').pop()}` : '';
    return { error: `회사 계정(SAML) 확인에 실패했습니다${status}. 시간이 지났으면 처음부터 다시 하세요.` };
  }
}

/** SP 메타데이터 XML — IdP에 이 서버를 등록할 때 쓴다(entityID·ACS·SLO·서명 인증서). */
export async function samlMetadataXml(settings = null) {
  const s = settings ?? (await getServerSettings());
  const keys = await ensureSpKeys(s);
  return samlClient({ ...s, samlIdpCert: s.samlIdpCert || 'x'.repeat(120), samlEntryPoint: s.samlEntryPoint || 'https://idp.invalid/' }, keys, {
    validateInResponseTo: ValidateInResponseTo.never,
  }).generateServiceProviderMetadata(null, keys.cert);
}

/** 이 앱에서 로그아웃할 때 IdP로 보낼 서명한 LogoutRequest 주소 — [session]은 sso_sessions 행(NameID·SessionIndex). */
export async function samlLogoutUrl(settings, session) {
  const keys = await ensureSpKeys(settings);
  return samlClient(settings, keys, { validateInResponseTo: ValidateInResponseTo.never }).getLogoutUrlAsync(
    {
      issuer: settings.samlIdpIssuer ?? '',
      nameID: session.nameId,
      nameIDFormat: session.nameIdFormat ?? 'urn:oasis:names:tc:SAML:1.1:nameid-format:unspecified',
      sessionIndex: session.idpSessionId ?? undefined,
    },
    '',
    {},
  );
}

/**
 * SLO 주소에 온 것 확인 — IdP가 보낸 LogoutRequest면 `{ request: { nameId, sessionIndex }, respond(): Promise<주소> }`, 이 서버가 보낸
 * 로그아웃의 답(LogoutResponse)이면 `{ loggedOut: true }`, 아니면 `{ error }`. [method] 'GET'(Redirect — 서명은 쿼리에) | 'POST'.
 */
export async function validateSamlLogout({ method, query, originalQuery, body, settings = null }) {
  const s = settings ?? (await getServerSettings());
  const keys = await ensureSpKeys(s);
  const client = samlClient(s, keys, { validateInResponseTo: ValidateInResponseTo.never });
  try {
    let result;
    if (method === 'GET') result = await client.validateRedirectAsync(query, originalQuery);
    else if (body?.SAMLRequest) result = await client.validatePostRequestAsync(body);
    else result = await client.validatePostResponseAsync(body);
    const profile = result?.profile;
    if (profile && (query?.SAMLRequest || body?.SAMLRequest)) {
      return {
        request: { nameId: profile.nameID, sessionIndex: profile.sessionIndex ?? null },
        respond: () => client.getLogoutResponseUrlAsync(profile, query?.RelayState ?? body?.RelayState ?? '', {}, true),
      };
    }
    return { loggedOut: !!result?.loggedOut || !profile };
  } catch (err) {
    console.warn('[saml] 로그아웃 확인 실패:', err?.message ?? err);
    return { error: '회사 계정(SAML) 로그아웃 요청을 확인하지 못했습니다.' };
  }
}
