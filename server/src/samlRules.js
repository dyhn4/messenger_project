/**
 * 회사 계정 로그인(SAML 2.0 — OIDC를 못 쓰는 IdP: ADFS·Okta·OneLogin·Keycloak·Google Workspace SAML 등)의 **순수 규칙** — 설정 검사,
 * 이 서버(SP)의 주소들, IdP 메타데이터 XML에서 값 꺼내기, 받은 프로필(NameID·속성)을 사람 정보로 읽기. 서명 확인·요청 만들기는
 * saml.js가 @node-saml/node-saml로 한다. DB·네트워크 없이 시험한다(test/samlRules.test.js).
 */

export const SAML_DEFAULT_LABEL = '회사 계정(SAML)';

/** 이 서버(SP)의 주소들 — 웹 앱 주소(WEB_DOMAIN, 정식 인증서) 아래. IdP에 그대로 넣는다. */
export function samlSpEndpoints(webBase) {
  const base = String(webBase ?? '').replace(/\/+$/, '');
  if (!base) return null;
  return {
    entityId: `${base}/auth/sso/saml/metadata`,
    metadataUrl: `${base}/auth/sso/saml/metadata`,
    acsUrl: `${base}/auth/sso/saml/acs`,
    sloUrl: `${base}/auth/sso/saml/slo`,
  };
}

const PEM_RE = /-----BEGIN CERTIFICATE-----([\s\S]*?)-----END CERTIFICATE-----/g;

/**
 * IdP 서명 인증서 글 → 인증서 본문(base64) 목록. PEM(여럿 이어 붙여도 됨)이나 머리줄 없는 base64 한 덩어리를 받는다(IdP가 인증서를
 * 바꾸는 동안 옛것·새것을 함께 넣을 수 있게). 모양이 아니면 빈 목록.
 */
export function parseCertList(text) {
  const s = String(text ?? '');
  const out = [];
  for (const m of s.matchAll(PEM_RE)) {
    const body = m[1].replace(/\s+/g, '');
    if (/^[A-Za-z0-9+/=]{100,}$/.test(body)) out.push(body);
  }
  if (out.length === 0) {
    const body = s.replace(/\s+/g, '');
    if (/^[A-Za-z0-9+/=]{100,}$/.test(body)) out.push(body);
  }
  return [...new Set(out)];
}

/** 인증서 본문 → PEM. */
export const certToPem = (body) => `-----BEGIN CERTIFICATE-----\n${body.match(/.{1,64}/g).join('\n')}\n-----END CERTIFICATE-----`;

const isHttpsUrl = (v) => {
  try {
    return new URL(String(v ?? '')).protocol === 'https:';
  } catch {
    return false;
  }
};

/** SAML을 켤 수 있을 만큼 값이 다 있는지 — 문제면 그 글, 괜찮으면 null. */
export function samlConfigProblem(settings) {
  if (!isHttpsUrl(settings.samlEntryPoint)) return 'IdP 로그인 주소(SSO URL — https://…)를 넣으세요.';
  if (parseCertList(settings.samlIdpCert).length === 0) return 'IdP 서명 인증서(X.509 — PEM)를 넣으세요.';
  if (settings.samlLogoutUrl && !isHttpsUrl(settings.samlLogoutUrl)) return 'IdP 로그아웃 주소는 https://로 시작해야 합니다.';
  return null;
}

/** 로그인 단추에 보일 IdP 이름 — 관리자가 정한 것(예: "Okta" — 앱이 "Okta 로그인"으로 보인다), 없으면 기본. */
export const samlButtonLabel = (settings) => String(settings.samlLabel ?? '').trim() || SAML_DEFAULT_LABEL;

/** XML 요소 하나의 속성들(이름은 접두어를 뗀다). */
function attrsOf(tag) {
  const out = {};
  for (const m of tag.matchAll(/([A-Za-z_:][\w.:-]*)\s*=\s*("([^"]*)"|'([^']*)')/g)) {
    out[m[1].replace(/^.*:/, '')] = m[3] ?? m[4] ?? '';
  }
  return out;
}

const REDIRECT_BINDING = 'urn:oasis:names:tc:SAML:2.0:bindings:HTTP-Redirect';

/**
 * IdP 메타데이터 XML → 채울 값 `{ entityId, entryPoint, logoutUrl, certs }` | `{ error }` — 관리자가 메타데이터를 붙여 넣으면 칸을
 * 채워 주는 데만 쓴다(채운 값은 관리자가 보고 저장한다 — 서명은 여기서 보지 않는다). 로그인·로그아웃 주소는 HTTP-Redirect 바인딩의
 * 것, 인증서는 서명용(use="signing" 또는 use 없음) KeyDescriptor의 것.
 */
export function parseIdpMetadata(xml) {
  const s = String(xml ?? '');
  if (!/EntityDescriptor/.test(s)) return { error: 'IdP 메타데이터(EntityDescriptor XML)가 아닙니다.' };
  if (s.length > 2_000_000) return { error: '메타데이터가 너무 큽니다.' };
  const entity = s.match(/<(?:\w+:)?EntityDescriptor\b[^>]*>/);
  const entityId = entity ? (attrsOf(entity[0]).entityID ?? null) : null;
  const idp = s.match(/<(?:\w+:)?IDPSSODescriptor\b[\s\S]*?<\/(?:\w+:)?IDPSSODescriptor>/);
  if (!idp) return { error: '메타데이터에 IdP 정보(IDPSSODescriptor)가 없습니다.' };
  const block = idp[0];
  const location = (name) => {
    for (const m of block.matchAll(new RegExp(`<(?:\\w+:)?${name}\\b[^>]*>`, 'g'))) {
      const a = attrsOf(m[0]);
      if (a.Binding === REDIRECT_BINDING && a.Location) return a.Location;
    }
    return null;
  };
  const certs = [];
  for (const m of block.matchAll(/<(?:\w+:)?KeyDescriptor\b([^>]*)>([\s\S]*?)<\/(?:\w+:)?KeyDescriptor>/g)) {
    const use = attrsOf(`<x ${m[1]}>`).use;
    if (use && use !== 'signing') continue;
    for (const c of m[2].matchAll(/<(?:\w+:)?X509Certificate>([\s\S]*?)<\/(?:\w+:)?X509Certificate>/g)) {
      const body = c[1].replace(/\s+/g, '');
      if (body && !certs.includes(body)) certs.push(body);
    }
  }
  const entryPoint = location('SingleSignOnService');
  if (!entryPoint) return { error: '메타데이터에 HTTP-Redirect 로그인 주소(SingleSignOnService)가 없습니다.' };
  if (certs.length === 0) return { error: '메타데이터에 서명 인증서가 없습니다.' };
  return { entityId, entryPoint, logoutUrl: location('SingleLogoutService'), certs };
}

/** 속성 이름을 찾아볼 순서 — 관리자가 정한 이름 다음에 흔한 표준 이름들(ADFS·Entra·Okta·eduPerson). */
const FALLBACK_ATTRS = {
  email: [
    'email',
    'mail',
    'emailaddress',
    'http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress',
    'urn:oid:0.9.2342.19200300.100.1.3',
  ],
  name: [
    'displayName',
    'name',
    'http://schemas.microsoft.com/identity/claims/displayname',
    'http://schemas.xmlsoap.org/ws/2005/05/identity/claims/name',
    'urn:oid:2.16.840.1.113730.3.1.241',
    'cn',
  ],
  groups: ['groups', 'memberOf', 'http://schemas.microsoft.com/ws/2008/06/identity/claims/groups', 'urn:oid:1.3.6.1.4.1.5923.1.5.1.1'],
};

/** 프로필의 속성 값들(대소문자 무시) — 배열·글 모두 글 목록으로. */
function attrValues(profile, name) {
  if (!name) return [];
  const key = Object.keys(profile ?? {}).find((k) => k.toLowerCase() === String(name).toLowerCase());
  if (!key) return [];
  const v = profile[key];
  const list = Array.isArray(v) ? v : [v];
  return list
    .map((x) => (typeof x === 'string' ? x : x && typeof x === 'object' && typeof x._ === 'string' ? x._ : null))
    .filter((x) => typeof x === 'string' && x.trim())
    .map((x) => x.trim());
}

function firstAttr(profile, preferred, fallbacks) {
  for (const name of [preferred, ...fallbacks]) {
    const v = attrValues(profile, name)[0];
    if (v) return v;
  }
  return null;
}

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

/**
 * 확인을 마친 SAML 프로필(node-saml) → `{ identity: { subject, email, name, groups, sessionIndex, nameId, nameIdFormat } }` | `{ error }`.
 * [subject]는 IdP의 NameID(앞에 발급자를 붙여 다른 IdP의 같은 값과 섞이지 않게) — 일회용(transient) NameID는 사람마다 같은 값이 아니라
 * 계정을 고를 수 없어 거절한다(IdP에서 persistent·이메일 형식으로 보내게 정한다).
 */
export function samlIdentity(profile, settings) {
  if (!profile || typeof profile.nameID !== 'string' || !profile.nameID.trim()) {
    return { error: '회사 계정 확인에 실패했습니다(NameID 없음).' };
  }
  if (String(profile.nameIDFormat ?? '').endsWith(':transient')) {
    return { error: 'IdP가 일회용(transient) NameID를 보냈습니다. IdP에서 NameID를 persistent나 이메일 형식으로 정해 달라고 관리자에게 알리세요.' };
  }
  const nameId = profile.nameID.trim();
  const issuer = String(profile.issuer ?? settings.samlIdpIssuer ?? '').trim();
  const mail = firstAttr(profile, settings.samlEmailAttr, FALLBACK_ATTRS.email) ?? (EMAIL_RE.test(nameId) ? nameId : null);
  const groups = [...new Set([settings.samlGroupsAttr, ...FALLBACK_ATTRS.groups].flatMap((n) => attrValues(profile, n)))].slice(0, 500);
  return {
    identity: {
      subject: `${issuer}|${nameId}`.slice(0, 1000),
      email: mail && EMAIL_RE.test(mail) ? mail.toLowerCase() : null,
      name: firstAttr(profile, settings.samlNameAttr, FALLBACK_ATTRS.name),
      groups,
      sessionIndex: typeof profile.sessionIndex === 'string' ? profile.sessionIndex : null,
      nameId,
      nameIdFormat: typeof profile.nameIDFormat === 'string' ? profile.nameIDFormat : null,
    },
  };
}

/** 관리자 콘솔 입력 → 바꿀 칸 `{ fields }` | `{ error }`(loginSecurityRules.js parseLoginSecurityInput이 부른다). */
export function parseSamlInput(b) {
  const fields = {};
  const text = (key, max = 2000) => {
    if (!(key in b)) return undefined;
    const v = b[key];
    if (v === null || v === '') return null;
    if (typeof v !== 'string' || v.length > max) return { bad: true };
    return v.trim() || null;
  };
  if ('samlEnabled' in b) {
    if (typeof b.samlEnabled !== 'boolean') return { error: 'samlEnabled는 참/거짓이어야 합니다.' };
    fields.samlEnabled = b.samlEnabled;
  }
  for (const key of ['samlLabel', 'samlIdpIssuer']) {
    const v = text(key, key === 'samlLabel' ? 40 : 1000);
    if (v?.bad) return { error: 'SAML 값이 올바르지 않습니다.' };
    if (v !== undefined) fields[key] = v;
  }
  for (const key of ['samlEntryPoint', 'samlLogoutUrl']) {
    const v = text(key, 2000);
    if (v?.bad || (v && !isHttpsUrl(v))) return { error: 'IdP 주소는 https://로 시작해야 합니다.' };
    if (v !== undefined) fields[key] = v;
  }
  if ('samlIdpCert' in b) {
    const v = text('samlIdpCert', 50_000);
    if (v?.bad) return { error: 'IdP 인증서 값이 올바르지 않습니다.' };
    if (v && parseCertList(v).length === 0) return { error: 'IdP 인증서는 PEM(-----BEGIN CERTIFICATE-----…) 모양으로 넣으세요.' };
    fields.samlIdpCert = v ? parseCertList(v).map(certToPem).join('\n') : null;
  }
  for (const key of ['samlEmailAttr', 'samlNameAttr', 'samlGroupsAttr']) {
    if (key in b) {
      const v = text(key, 300);
      if (!v || v.bad) return { error: 'SAML 속성 이름을 넣으세요(예: email).' };
      fields[key] = v;
    }
  }
  return { fields };
}
