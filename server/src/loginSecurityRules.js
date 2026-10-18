import { isLdapUrl, LDAP_CONNECTION_FIELDS, ldapConfigProblem, userFilterProblem } from './ldapRules.js';
import { parseSamlInput, samlButtonLabel, samlSpEndpoints } from './samlRules.js';
import { enabledSsoProviders, isDomainName, isTenantId, parseDomainList, ssoConfigProblem } from './ssoRules.js';

/**
 * 로그인 보안(2단계 인증 정책·회사 계정 SSO(OIDC·SAML)·사내 디렉터리 LDAP·그룹 규칙·보안 키·로그아웃 연동) 설정의 **순수 규칙** — 관리자 콘솔 "로그인 보안" 입력 검사와
 * 화면에 보낼 모양(비밀값은 정했는지만). `node --test`로 시험한다(test/loginSecurity.test.js).
 */

export const OTP_POLICIES = Object.freeze(['optional', 'admins', 'all']);
export const AUTO_CREATE_ROLES = Object.freeze(['guest', 'member']);
export const AUTH_SOURCES = Object.freeze(['local', 'ldap', 'sso']);
/** 디렉터리로 부서를 맞출 방식 — 부서 속성 글자(맨 위 부서로)·OU 경로(트리로)·안 맞춤. */
export const LDAP_ORG_SOURCES = Object.freeze(['attribute', 'ou', 'off']);

/** 이 사람이 2단계 인증을 꼭 써야 하는지 — 'admins'는 계정 등급 관리자와 서버 운영자. */
export function otpRequiredFor(policy, user) {
  if (policy === 'all') return true;
  if (policy === 'admins') return user?.role === 'admin' || !!user?.isServerAdmin;
  return false;
}

/** 이 앱의 비밀번호로 로그인할 수 있는 계정인지 — 디렉터리·회사 계정 전용 계정은 그쪽 비밀번호로만. */
export const usesLocalPassword = (user) => (user?.authSource ?? 'local') === 'local';

/** 비밀번호 바꾸기·찾기·보안 질문을 막을 때의 안내(로그인 방법별). null이면 막지 않는다. */
export function localPasswordBlockedText(user) {
  if (user?.authSource === 'ldap') return '회사(Windows 도메인) 계정으로 로그인하는 계정입니다. 비밀번호는 회사 계정에서 바꾸세요.';
  if (user?.authSource === 'sso') return '회사 계정(Google·Microsoft·SAML)으로 로그인하는 계정이라 이 앱의 비밀번호가 없습니다.';
  return null;
}

const MAX_TEXT = 500;
const SESSION_DAYS_MIN = 1;
const SESSION_DAYS_MAX = 90;

function textField(body, key, { max = MAX_TEXT, required = false } = {}) {
  if (!(key in body)) return { skip: true };
  const v = body[key];
  if (v === null || v === '') return required ? { error: true } : { value: null };
  if (typeof v !== 'string' || v.length > max) return { error: true };
  return { value: v.trim() || null };
}

/**
 * 관리자 콘솔 입력 → 바꿀 칸 `{ fields }` | `{ error }`. 넘긴 것만 바뀐다. 비밀값(보안 비밀·암호·서비스 계정 비밀번호)은 평문
 * 그대로 `…Secret`·`ldapBindPassword` 칸에 담아 돌려주고, 저장 전에 부른 쪽이 암호화한다(빈 값이면 지움).
 */
export function parseLoginSecurityInput(body) {
  const b = body ?? {};
  const fields = {};
  const fail = (error) => ({ error });

  if ('otpPolicy' in b) {
    if (!OTP_POLICIES.includes(b.otpPolicy)) return fail('2단계 인증 정책 값이 올바르지 않습니다.');
    fields.otpPolicy = b.otpPolicy;
  }
  for (const [key, col] of [
    ['ssoGoogleEnabled', 'ssoGoogleEnabled'],
    ['ssoMicrosoftEnabled', 'ssoMicrosoftEnabled'],
    ['ssoAutoCreate', 'ssoAutoCreate'],
    ['ldapEnabled', 'ldapEnabled'],
    ['ldapTlsVerify', 'ldapTlsVerify'],
    ['ldapAutoCreate', 'ldapAutoCreate'],
    ['groupSyncEnabled', 'groupSyncEnabled'],
    ['groupSyncRemove', 'groupSyncRemove'],
    ['passkeyLoginEnabled', 'passkeyLoginEnabled'],
    ['ssoIdpLogout', 'ssoIdpLogout'],
  ]) {
    if (key in b) {
      if (typeof b[key] !== 'boolean') return fail(`${key}는 참/거짓이어야 합니다.`);
      fields[col] = b[key];
    }
  }
  for (const key of ['ssoDefaultRole', 'ldapDefaultRole']) {
    if (key in b) {
      if (!AUTO_CREATE_ROLES.includes(b[key])) return fail('새 계정 등급은 준회원 또는 정회원이어야 합니다.');
      fields[key] = b[key];
    }
  }
  if ('ssoSessionDays' in b) {
    const n = Number(b.ssoSessionDays);
    if (!Number.isInteger(n) || n < SESSION_DAYS_MIN || n > SESSION_DAYS_MAX) {
      return fail(`회사 계정 다시 확인 주기는 ${SESSION_DAYS_MIN}~${SESSION_DAYS_MAX}일이어야 합니다.`);
    }
    fields.ssoSessionDays = n;
  }

  // Google
  for (const key of ['ssoGoogleClientId', 'ssoGoogleClientSecret']) {
    const r = textField(b, key);
    if (r.error) return fail('Google 클라이언트 값이 올바르지 않습니다.');
    if (!r.skip) fields[key] = r.value;
  }
  if ('ssoGoogleDomains' in b) {
    const r = textField(b, 'ssoGoogleDomains');
    if (r.error) return fail('회사 도메인 값이 올바르지 않습니다.');
    const list = parseDomainList(r.value);
    if (list.some((d) => !isDomainName(d))) return fail('회사 도메인은 company.com처럼 넣으세요(여럿이면 쉼표로).');
    if (list.some((d) => d === 'gmail.com' || d === 'googlemail.com')) {
      return fail('gmail.com은 회사 도메인이 아닙니다 — Google Workspace의 회사 도메인을 넣으세요.');
    }
    fields.ssoGoogleDomains = list.length ? list.join(', ') : null;
  }
  // Microsoft
  if ('ssoMicrosoftTenantId' in b) {
    const r = textField(b, 'ssoMicrosoftTenantId');
    if (r.error || (r.value && !isTenantId(r.value))) {
      return fail('디렉터리(테넌트) ID는 GUID(예: 1234abcd-…)여야 합니다 — Entra 관리 센터의 "개요"에 있습니다.');
    }
    fields.ssoMicrosoftTenantId = r.value ? r.value.toLowerCase() : null;
  }
  for (const key of ['ssoMicrosoftClientId', 'ssoMicrosoftClientSecret']) {
    const r = textField(b, key);
    if (r.error) return fail('Microsoft 클라이언트 값이 올바르지 않습니다.');
    if (!r.skip) fields[key] = r.value;
  }
  // SAML
  const saml = parseSamlInput(b);
  if (saml.error) return fail(saml.error);
  Object.assign(fields, saml.fields);
  // LDAP
  if ('ldapUrl' in b) {
    const r = textField(b, 'ldapUrl');
    if (r.error || (r.value && !isLdapUrl(r.value))) return fail('LDAP 서버 주소는 ldap://호스트 또는 ldaps://호스트 모양이어야 합니다.');
    fields.ldapUrl = r.value;
  }
  for (const key of ['ldapBindDn', 'ldapBindPassword', 'ldapBaseDn']) {
    const r = textField(b, key);
    if (r.error) return fail('LDAP 연결 값이 올바르지 않습니다.');
    if (!r.skip) fields[key] = r.value;
  }
  if ('ldapUserFilter' in b) {
    const r = textField(b, 'ldapUserFilter', { required: true });
    if (r.error) return fail('사용자 검색 조건을 넣으세요.');
    const problem = userFilterProblem(r.value);
    if (problem) return fail(problem);
    fields.ldapUserFilter = r.value;
  }
  // 사내 디렉터리로 조직도 맞추기(orgDirectorySync.js).
  if ('ldapOrgSource' in b) {
    if (!LDAP_ORG_SOURCES.includes(b.ldapOrgSource)) return fail('부서를 맞출 방식이 올바르지 않습니다.');
    fields.ldapOrgSource = b.ldapOrgSource;
  }
  if ('ldapOrgBaseDn' in b) {
    const r = textField(b, 'ldapOrgBaseDn');
    if (r.error) return fail('부서 트리의 시작 위치(DN)가 올바르지 않습니다.');
    fields.ldapOrgBaseDn = r.value;
  }
  if ('ldapManagerSync' in b) {
    if (typeof b.ldapManagerSync !== 'boolean') return fail('ldapManagerSync는 참/거짓이어야 합니다.');
    fields.ldapManagerSync = b.ldapManagerSync;
  }
  for (const key of ['ldapNameAttr', 'ldapEmailAttr', 'ldapDepartmentAttr', 'ldapTitleAttr', 'ldapManagerAttr']) {
    if (key in b) {
      const r = textField(b, key, { max: 60, required: true });
      if (r.error || !/^[A-Za-z][A-Za-z0-9-]*$/.test(r.value ?? '')) return fail('속성 이름은 영문·숫자(예: displayName)로 넣으세요.');
      fields[key] = r.value;
    }
  }
  return { fields };
}

/** LDAP 연결 값이 바뀌는지 — 바뀌면 시험 결과를 지우고 끈다(admin.js). [fields]는 암호화까지 끝난 저장 칸. */
export function ldapConnectionChanged(current, fields) {
  return LDAP_CONNECTION_FIELDS.some((k) => k in fields && (fields[k] ?? null) !== (current[k] ?? null));
}

/**
 * 관리자 콘솔에 보낼 모양 — 비밀값은 정했는지만, 켤 수 없는 이유와 돌아올 주소를 같이. [webBase]는 웹 앱 주소(SAML SP 주소·로그아웃
 * 주소를 보여 준다).
 */
export function loginSecurityView(settings, { redirectUri = null, webBase = null } = {}) {
  const base = webBase ? String(webBase).replace(/\/+$/, '') : null;
  return {
    otpPolicy: settings.otpPolicy ?? 'optional',
    passkeyLoginEnabled: settings.passkeyLoginEnabled !== false,
    passkeysAvailable: !!base,
    groupSync: { enabled: !!settings.groupSyncEnabled, removeUnmatched: !!settings.groupSyncRemove },
    logout: {
      idpLogout: !!settings.ssoIdpLogout,
      // Microsoft 앱 등록의 "프런트 채널 로그아웃 URL"에 넣을 주소.
      frontChannelUrl: base ? `${base}/auth/sso/frontchannel-logout` : null,
    },
    saml: {
      enabled: !!settings.samlEnabled,
      label: settings.samlLabel ?? '',
      buttonLabel: samlButtonLabel(settings),
      entryPoint: settings.samlEntryPoint ?? '',
      idpIssuer: settings.samlIdpIssuer ?? '',
      idpCert: settings.samlIdpCert ?? '',
      logoutUrl: settings.samlLogoutUrl ?? '',
      emailAttr: settings.samlEmailAttr ?? 'email',
      nameAttr: settings.samlNameAttr ?? 'displayName',
      groupsAttr: settings.samlGroupsAttr ?? 'groups',
      // IdP에 넣을 이 서버(SP)의 값 — entityID·ACS·SLO·메타데이터 주소.
      sp: base ? samlSpEndpoints(base) : null,
      problem: ssoConfigProblem('saml', settings),
    },
    sso: {
      redirectUri,
      autoCreate: !!settings.ssoAutoCreate,
      defaultRole: settings.ssoDefaultRole ?? 'member',
      sessionDays: settings.ssoSessionDays ?? 7,
      google: {
        enabled: !!settings.ssoGoogleEnabled,
        clientId: settings.ssoGoogleClientId ?? '',
        hasClientSecret: !!settings.ssoGoogleClientSecretEnc,
        domains: settings.ssoGoogleDomains ?? '',
        problem: ssoConfigProblem('google', settings),
      },
      microsoft: {
        enabled: !!settings.ssoMicrosoftEnabled,
        tenantId: settings.ssoMicrosoftTenantId ?? '',
        clientId: settings.ssoMicrosoftClientId ?? '',
        hasClientSecret: !!settings.ssoMicrosoftClientSecretEnc,
        problem: ssoConfigProblem('microsoft', settings),
      },
    },
    ldap: {
      enabled: !!settings.ldapEnabled,
      url: settings.ldapUrl ?? '',
      bindDn: settings.ldapBindDn ?? '',
      hasBindPassword: !!settings.ldapBindPasswordEnc,
      baseDn: settings.ldapBaseDn ?? '',
      userFilter: settings.ldapUserFilter ?? '',
      nameAttr: settings.ldapNameAttr ?? 'displayName',
      emailAttr: settings.ldapEmailAttr ?? 'mail',
      departmentAttr: settings.ldapDepartmentAttr ?? 'department',
      titleAttr: settings.ldapTitleAttr ?? 'title',
      tlsVerify: settings.ldapTlsVerify !== false,
      autoCreate: settings.ldapAutoCreate !== false,
      defaultRole: settings.ldapDefaultRole ?? 'member',
      testedAt: settings.ldapTestedAt ? new Date(settings.ldapTestedAt).getTime() : null,
      // 조직도 맞추기 — 부서 방식·부서 트리의 시작 OU·상위자(manager) 맞추기와 그 속성. 계정 단위 조직도에서만 쓴다([orgSyncAvailable]).
      orgSource: settings.ldapOrgSource ?? 'attribute',
      orgBaseDn: settings.ldapOrgBaseDn ?? '',
      managerSync: !!settings.ldapManagerSync,
      managerAttr: settings.ldapManagerAttr ?? 'manager',
      orgSyncAvailable: settings.orgScope === 'account',
      problem: ldapConfigProblem(settings),
    },
  };
}

/** 로그인 화면에 알릴 로그인 방법(/server-info) — 켜져 있고 쓸 수 있는 것만. */
export function loginMethodsView(settings, { redirectReady }) {
  return {
    sso: redirectReady ? enabledSsoProviders(settings) : [],
    // SAML 단추에 보일 IdP 이름(관리자가 정한 것)과 보안 키·패스키로 바로 로그인할 수 있는지(웹 앱 주소가 있어야 한다).
    samlLabel: samlButtonLabel(settings),
    passkey: redirectReady && settings.passkeyLoginEnabled !== false,
    ldap: !!settings.ldapEnabled && !!settings.ldapTestedAt && !ldapConfigProblem(settings),
    otpPolicy: settings.otpPolicy ?? 'optional',
  };
}
