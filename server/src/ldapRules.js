/**
 * 사내 디렉터리(LDAP/Active Directory) 로그인의 **순수 규칙** — 검색 조건 만들기, 받은 항목을 사람 정보로 읽기. 실제 연결은
 * ldapAuth.js가 한다(ldapts). `node --test`로 시험한다(test/loginSecurity.test.js).
 */

/** LDAP 주소 — ldap://호스트[:포트] 또는 ldaps://호스트[:포트]만. */
export function isLdapUrl(value) {
  if (typeof value !== 'string') return false;
  try {
    const u = new URL(value.trim());
    return (u.protocol === 'ldap:' || u.protocol === 'ldaps:') && !!u.hostname && (u.pathname === '' || u.pathname === '/');
  } catch {
    return false;
  }
}

/**
 * 검색 조건에 넣을 값 이스케이프(RFC 4515) — 아이디 칸에 `*`·`(`·`)`·`\`를 넣어 조건을 바꾸거나 남의 계정을 고르지 못하게.
 */
export function escapeLdapFilterValue(value) {
  return String(value).replace(/[\\*()\0]/g, (ch) => `\\${ch.charCodeAt(0).toString(16).padStart(2, '0')}`);
}

/**
 * 저장해 둔 [subject]로 다시 찾을 때의 검색 — 'guid:<base64>'면 objectGUID 바이트를 하나씩 역슬래시+16진수로 이스케이프한 조건(위치는
 * Base DN 아래 전체), 'dn:<DN>'이면 그 DN 하나. `{ base, scope, filter }` | null.
 */
export function subjectSearch(subject, baseDn) {
  const s = String(subject ?? '');
  if (s.startsWith('guid:')) {
    const bytes = Buffer.from(s.slice(5), 'base64');
    if (bytes.length === 0) return null;
    const escaped = [...bytes].map((b) => '\\' + b.toString(16).padStart(2, '0')).join('');
    return { base: String(baseDn ?? '').trim(), scope: 'sub', filter: `(objectGUID=${escaped})` };
  }
  if (s.startsWith('dn:')) return { base: s.slice(3), scope: 'base', filter: '(objectClass=*)' };
  return null;
}

/** 사용자 검색 조건 — 템플릿의 `{username}`을 이스케이프한 아이디로. 템플릿이 괄호로 감싸여 있지 않으면 감싼다. */
export function buildUserFilter(template, username) {
  const t = String(template ?? '').trim() || '(sAMAccountName={username})';
  const filled = t.split('{username}').join(escapeLdapFilterValue(username));
  return filled.startsWith('(') ? filled : `(${filled})`;
}

/** 검색 조건 템플릿 검사 — `{username}`이 들어 있고 괄호 짝이 맞아야 한다. 문제면 그 글, 괜찮으면 null. */
export function userFilterProblem(template) {
  const t = String(template ?? '').trim();
  if (!t.includes('{username}')) return '사용자 검색 조건에 {username}을 넣으세요(예: (sAMAccountName={username})).';
  let depth = 0;
  for (const ch of t) {
    if (ch === '(') depth += 1;
    if (ch === ')') depth -= 1;
    if (depth < 0) return '사용자 검색 조건의 괄호 짝이 맞지 않습니다.';
  }
  return depth === 0 ? null : '사용자 검색 조건의 괄호 짝이 맞지 않습니다.';
}

/** 항목 속성 값 하나 — 배열이면 첫 값, Buffer면 UTF-8 글자. 없으면 null. */
export function attrText(entry, name) {
  if (!name) return null;
  const key = Object.keys(entry ?? {}).find((k) => k.toLowerCase() === String(name).toLowerCase());
  if (!key) return null;
  let v = entry[key];
  if (Array.isArray(v)) v = v[0];
  if (v == null) return null;
  if (Buffer.isBuffer(v)) v = v.toString('utf8');
  const s = String(v).trim();
  return s ? s : null;
}

/** 항목 속성 값 전부(memberOf처럼 여럿인 것) — 글 목록. */
export function attrList(entry, name) {
  const key = Object.keys(entry ?? {}).find((k) => k.toLowerCase() === String(name).toLowerCase());
  if (!key) return [];
  const v = entry[key];
  return (Array.isArray(v) ? v : [v])
    .map((x) => (Buffer.isBuffer(x) ? x.toString('utf8') : x == null ? '' : String(x)).trim())
    .filter(Boolean);
}

/** Active Directory userAccountControl의 "사용 안 함"(ACCOUNTDISABLE = 0x2). */
export function isDisabledEntry(entry) {
  const uac = Number(attrText(entry, 'userAccountControl'));
  return Number.isFinite(uac) && (uac & 0x2) === 0x2;
}

/** objectGUID(AD — 16바이트) → base64. 없으면 null. */
export function entryGuid(entry) {
  const key = Object.keys(entry ?? {}).find((k) => k.toLowerCase() === 'objectguid');
  let v = key ? entry[key] : null;
  if (Array.isArray(v)) v = v[0];
  if (Buffer.isBuffer(v) && v.length > 0) return v.toString('base64');
  if (typeof v === 'string' && v) return v;
  return null;
}

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

/**
 * 받은 항목 → 사람 정보 `{ subject, dn, name, email, department, title, disabled, groups }`([groups]는 memberOf의 그룹 DN들 —
 * 그룹 규칙(groupSync.js)이 쓴다). [subject]는 바뀌지 않는 objectGUID(없으면
 * DN — 사람이 부서를 옮겨 DN이 바뀌면 새 사람으로 보이니 AD는 GUID를 쓴다).
 */
export function entryToProfile(entry, settings) {
  const guid = entryGuid(entry);
  const email = attrText(entry, settings.ldapEmailAttr);
  return {
    subject: guid ? `guid:${guid}` : `dn:${String(entry.dn ?? '').toLowerCase()}`,
    dn: entry.dn,
    name: attrText(entry, settings.ldapNameAttr),
    email: email && EMAIL_RE.test(email) ? email.toLowerCase() : null,
    department: attrText(entry, settings.ldapDepartmentAttr),
    title: attrText(entry, settings.ldapTitleAttr),
    disabled: isDisabledEntry(entry),
    groups: attrList(entry, 'memberOf').slice(0, 1000),
  };
}

/** 검색에서 가져올 속성들. */
export function ldapAttributes(settings) {
  return [
    ...new Set(
      ['dn', 'objectGUID', 'userAccountControl', 'memberOf', settings.ldapNameAttr, settings.ldapEmailAttr, settings.ldapDepartmentAttr, settings.ldapTitleAttr].filter(
        Boolean,
      ),
    ),
  ];
}

/** 연결 값(바뀌면 시험을 다시 해야 하는 것) — 메일 설정과 같은 규칙. */
export const LDAP_CONNECTION_FIELDS = Object.freeze(['ldapUrl', 'ldapBindDn', 'ldapBindPasswordEnc', 'ldapBaseDn', 'ldapUserFilter', 'ldapTlsVerify']);

/** 켤 수 있을 만큼 값이 다 있는지 — 문제면 그 글, 괜찮으면 null. */
export function ldapConfigProblem(settings) {
  if (!isLdapUrl(settings.ldapUrl)) return 'LDAP 서버 주소(ldap://… 또는 ldaps://…)를 넣으세요.';
  if (!String(settings.ldapBaseDn ?? '').trim()) return '검색 위치(Base DN — 예: DC=company,DC=local)를 넣으세요.';
  if (settings.ldapBindDn && !settings.ldapBindPasswordEnc) return '서비스 계정 비밀번호를 넣으세요.';
  return userFilterProblem(settings.ldapUserFilter);
}
