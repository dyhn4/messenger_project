import { Client } from 'ldapts';
import { decryptField } from './crypto.js';
import { buildUserFilter, entryToProfile, ldapAttributes, subjectSearch } from './ldapRules.js';

/**
 * 사내 디렉터리(LDAP/Active Directory) 확인 — 서비스 계정으로 사람을 찾고(검색 조건 — ldapRules.js), 찾은 그 사람의 DN과 입력한
 * 비밀번호로 다시 붙어(bind) 비밀번호를 확인한다. 디렉터리 쪽 비밀번호는 이 서버에 남기지 않는다. 인터넷 없이 사내망 안에서
 * 동작한다. 실제 연결은 [clientFactory](기본 ldapts)로 만들어 시험에서는 가짜를 끼운다.
 *
 * ldap://는 비밀번호가 암호화되지 않고 사내망을 지나간다 — 되도록 ldaps://(636)를 쓴다(관리자 콘솔 안내).
 */

const TIMEOUT_MS = 8000;
const CONNECT_TIMEOUT_MS = 5000;

export function defaultLdapClient(settings) {
  const url = String(settings.ldapUrl ?? '').trim();
  return new Client({
    url,
    timeout: TIMEOUT_MS,
    connectTimeout: CONNECT_TIMEOUT_MS,
    tlsOptions: url.startsWith('ldaps:') ? { rejectUnauthorized: settings.ldapTlsVerify !== false } : undefined,
  });
}

async function closeQuietly(client) {
  try {
    await client.unbind();
  } catch {
    // 이미 끊겼으면 그만이다.
  }
}

/** 서비스 계정으로 붙어 [username]을 찾는다 → 항목 하나 | `{ error }`(못 찾음·여럿·연결 실패). */
function findEntry(settings, username, clientFactory) {
  return searchOne(
    settings,
    { base: String(settings.ldapBaseDn).trim(), scope: 'sub', filter: buildUserFilter(settings.ldapUserFilter, username) },
    clientFactory,
  );
}

/** 서비스 계정으로 붙어 [base]·[scope]·[filter]로 한 사람을 찾는다 → 항목 하나 | `{ error }`. */
async function searchOne(settings, { base, scope, filter }, clientFactory) {
  const client = clientFactory(settings);
  try {
    if (settings.ldapBindDn) {
      await client.bind(settings.ldapBindDn, decryptField(settings.ldapBindPasswordEnc) ?? '');
    }
    const { searchEntries } = await client.search(base, {
      scope,
      filter,
      attributes: ldapAttributes(settings),
      sizeLimit: 2,
    });
    if (searchEntries.length === 0) return { error: 'not_found' };
    if (searchEntries.length > 1) return { error: 'ambiguous' };
    return { entry: searchEntries[0] };
  } catch (err) {
    // 검색 결과가 둘 이상이라 sizeLimit에 걸려도 여기로 온다.
    if (err?.name === 'SizeLimitExceededError') return { error: 'ambiguous' };
    return { error: 'unavailable', detail: err?.message ?? String(err) };
  } finally {
    await closeQuietly(client);
  }
}

/**
 * 아이디·비밀번호 확인 → `{ ok: true, profile }` | `{ ok: false, reason, detail? }`. reason: 'empty_password' | 'not_found' |
 * 'ambiguous' | 'disabled' | 'bad_password' | 'unavailable'. 빈 비밀번호는 묻지도 않는다 — LDAP은 빈 비밀번호로 붙으면 "익명"으로
 * 성공해 버려서, 그대로 두면 비밀번호 없이 누구로든 들어온다.
 */
export async function ldapAuthenticate({ settings, username, password, clientFactory = defaultLdapClient }) {
  if (typeof password !== 'string' || password.length === 0) return { ok: false, reason: 'empty_password' };
  const found = await findEntry(settings, username, clientFactory);
  if (found.error) return { ok: false, reason: found.error, detail: found.detail };
  const profile = entryToProfile(found.entry, settings);
  if (profile.disabled) return { ok: false, reason: 'disabled' };
  const client = clientFactory(settings);
  try {
    await client.bind(profile.dn, password);
    return { ok: true, profile };
  } catch (err) {
    if (err?.name === 'InvalidCredentialsError') return { ok: false, reason: 'bad_password' };
    return { ok: false, reason: 'unavailable', detail: err?.message ?? String(err) };
  } finally {
    await closeQuietly(client);
  }
}

/**
 * 아직 디렉터리에 있고 쓸 수 있는 사람인지(토큰 갱신 때 — 퇴사로 계정을 막으면 그 뒤 갱신에서 로그아웃되게). 연결할 때 적어 둔
 * [subject](objectGUID·DN)로 찾는다 — 이 앱의 아이디가 디렉터리 아이디와 달라도 된다. `{ active: true|false }` |
 * `{ unavailable: true }`(디렉터리에 못 붙음). 찾았으면 [profile](그룹 포함)도.
 */
export async function ldapStillActive({ settings, subject, clientFactory = defaultLdapClient }) {
  const search = subjectSearch(subject, settings.ldapBaseDn);
  if (!search) return { unavailable: true };
  const found = await searchOne(settings, search, clientFactory);
  if (found.error === 'unavailable') return { unavailable: true };
  if (found.error) return { active: false };
  const profile = entryToProfile(found.entry, settings);
  // 사람 정보도 같이 — 그룹 규칙(groupSync.js)이 10분마다 그룹을 다시 맞춘다.
  return { active: !profile.disabled && profile.subject === subject, profile };
}

/**
 * 관리자 콘솔 "연결 시험" — 서비스 계정으로 붙어 보고, [username]을 주면 그 사람을 찾아 보며, [password]까지 주면 로그인도 해 본다.
 * `{ ok, connected, message, profile? }` — [connected]는 서비스 계정으로 붙는 데까지 됐는지(관리자 콘솔이 "시험 통과"로 적는 기준).
 */
export async function ldapTest({ settings, username = '', password = '', clientFactory = defaultLdapClient }) {
  const client = clientFactory(settings);
  try {
    if (settings.ldapBindDn) await client.bind(settings.ldapBindDn, decryptField(settings.ldapBindPasswordEnc) ?? '');
  } catch (err) {
    return {
      ok: false,
      connected: false,
      message:
        err?.name === 'InvalidCredentialsError'
          ? '서비스 계정 DN 또는 비밀번호가 맞지 않습니다.'
          : `LDAP 서버에 연결하지 못했습니다: ${err?.message ?? err}`,
    };
  } finally {
    await closeQuietly(client);
  }
  if (!username) return { ok: true, connected: true, message: '서비스 계정으로 연결했습니다.' };
  if (password) {
    const r = await ldapAuthenticate({ settings, username, password, clientFactory });
    if (r.ok) return { ok: true, connected: true, message: `${r.profile.name ?? username} 계정으로 로그인했습니다.`, profile: r.profile };
    return { ok: false, connected: r.reason !== 'unavailable', message: LDAP_REASON_TEXT[r.reason] ?? '로그인하지 못했습니다.' };
  }
  const found = await findEntry(settings, username, clientFactory);
  if (found.error) {
    return { ok: false, connected: found.error !== 'unavailable', message: LDAP_REASON_TEXT[found.error] ?? '사용자를 찾지 못했습니다.' };
  }
  const profile = entryToProfile(found.entry, settings);
  return {
    ok: true,
    connected: true,
    message: `사용자를 찾았습니다: ${profile.name ?? username}${profile.disabled ? ' (사용 안 함 계정)' : ''}`,
    profile,
  };
}

export const LDAP_REASON_TEXT = Object.freeze({
  empty_password: '비밀번호를 넣으세요.',
  not_found: '디렉터리에서 그 아이디를 찾지 못했습니다(검색 위치·검색 조건을 확인하세요).',
  ambiguous: '그 아이디로 찾은 사람이 여럿입니다 — 검색 조건을 더 좁히세요.',
  disabled: '디렉터리에서 사용 안 함으로 된 계정입니다.',
  bad_password: '비밀번호가 맞지 않습니다.',
  unavailable: '회사 디렉터리(LDAP) 서버에 연결하지 못했습니다. 잠시 뒤 다시 시도하세요.',
});

/**
 * 이미 연결된 디렉터리 계정([subject])의 비밀번호 확인 — 이메일 변경·탈퇴처럼 "지금 비밀번호를 한 번 더" 묻는 곳(users.js
 * checkCurrentPassword). 맞으면 true. 빈 비밀번호·못 찾음·사용 안 함·연결 실패는 false.
 */
export async function ldapCheckPasswordBySubject({ settings, subject, password, clientFactory = defaultLdapClient }) {
  if (typeof password !== 'string' || password.length === 0) return false;
  const search = subjectSearch(subject, settings.ldapBaseDn);
  if (!search) return false;
  const found = await searchOne(settings, search, clientFactory);
  if (found.error) return false;
  const profile = entryToProfile(found.entry, settings);
  if (profile.disabled) return false;
  const client = clientFactory(settings);
  try {
    await client.bind(profile.dn, password);
    return true;
  } catch {
    return false;
  } finally {
    await closeQuietly(client);
  }
}

/** [dn]의 사람 정보(서비스 계정으로) — 상위자(manager 속성의 DN)를 이 앱 계정으로 바꿀 때. 못 찾으면 null. */
export async function ldapProfileByDn({ settings, dn, clientFactory = defaultLdapClient }) {
  if (!dn) return null;
  const found = await searchOne(settings, { base: dn, scope: 'base', filter: '(objectClass=*)' }, clientFactory);
  return found.entry ? entryToProfile(found.entry, settings) : null;
}

/**
 * 디렉터리의 사람 전부(조직도 한꺼번에 맞추기 — 관리자 콘솔) — 사용자 검색 조건의 {username}을 *로 바꿔 Base DN 아래를 쪽 단위로 읽는다
 * ([max]명까지). 사람 정보 목록 | `{ error }`.
 */
export async function ldapListProfiles({ settings, max = 20_000, clientFactory = defaultLdapClient }) {
  const client = clientFactory(settings);
  try {
    if (settings.ldapBindDn) await client.bind(settings.ldapBindDn, decryptField(settings.ldapBindPasswordEnc) ?? '');
    const filter = String(settings.ldapUserFilter || '(objectClass=user)').split('{username}').join('*');
    const { searchEntries } = await client.search(String(settings.ldapBaseDn).trim(), {
      scope: 'sub',
      filter: filter.startsWith('(') ? filter : `(${filter})`,
      attributes: ldapAttributes(settings),
      paged: { pageSize: 500 },
      sizeLimit: max,
    });
    return searchEntries.slice(0, max).map((e) => entryToProfile(e, settings));
  } catch (err) {
    return { error: err?.message ?? String(err) };
  } finally {
    await closeQuietly(client);
  }
}
