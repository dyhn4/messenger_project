import bcrypt from 'bcryptjs';
import crypto from 'node:crypto';
import { Router } from 'express';
import jwt from 'jsonwebtoken';
import { accessPayload, issueTokenPair } from './auth.js';
import { limits, retryLater, USERNAME_PATTERN, waitText } from './authGuard.js';
import { JWT_SECRET } from './config.js';
import { decryptField, encryptField, lookupHash } from './crypto.js';
import { findDefaultPositionOption } from './db/queries/positionOptions.js';
import { getServerSettings } from './db/queries/serverSettings.js';
import { departmentForText } from './orgTree.js';
import { findIdentity, findIdentityForUser, linkIdentity, touchIdentity } from './db/queries/userIdentities.js';
import {
  claimTotpStep,
  findUserByEmailLookup,
  findUserById,
  insertRegisteredUser,
  isUsernameTakenIgnoringCase,
  replaceRecoveryHashes,
  updateUser,
} from './db/queries/users.js';
import { ldapStillActive } from './ldapAuth.js';
import { ldapConfigProblem } from './ldapRules.js';
import { otpRequiredFor, usesLocalPassword } from './loginSecurityRules.js';
import { usernameFromEmail } from './ssoRules.js';
import {
  generateRecoveryCodes,
  generateTotpSecret,
  hashRecoveryCodes,
  otpauthUri,
  useRecoveryCode,
  verifyTotp,
} from './totp.js';

/**
 * 로그인 보안 — 2단계 인증(OTP), 로그인 마무리(비밀번호·디렉터리 다음에 2단계 인증을 물을지), 사내 디렉터리(LDAP) 로그인의 계정
 * 연결·생성, 디렉터리 계정이 아직 살아 있는지. 회사 계정(SSO)은 sso.js, 규칙은 loginSecurityRules.js·totp.js·ldapRules.js.
 *
 * 2단계 인증 흐름: 비밀번호(또는 디렉터리)가 맞으면 토큰 대신 짧게 사는(10분) "확인 표"(otpTicket)를 준다. 앱이 그 표와 인증 앱의
 * 6자리 코드(또는 복구 코드)를 /auth/login/otp로 보내면 토큰이 나온다. 정책상 꼭 써야 하는데 아직 안 켠 사람은 표로 그 자리에서
 * 켠다(/auth/otp/setup → /auth/otp/enable). 업데이트 전 앱은 이 단계를 모르므로 403과 안내 문구를 받는다.
 */

const OTP_TICKET_TTL = '10m';
const OTP_FAILED_ERROR = '코드가 맞지 않습니다. 인증 앱의 지금 코드를 넣으세요(휴대폰 시간이 맞는지도 확인하세요).';
const UPDATE_APP_ERROR = '2단계 인증을 쓰는 계정입니다. 앱을 최신 버전으로 업데이트한 뒤 다시 로그인하세요.';

/** 확인 표 — 비밀번호는 맞았고 2단계 인증만 남은 사람. [purpose] 'login'(코드 확인) | 'setup'(그 자리에서 켜기). */
export function issueOtpTicket(user, purpose) {
  return jwt.sign({ sub: user.id, tv: user.tokenVersion ?? 0, purpose, type: 'otp' }, JWT_SECRET, { expiresIn: OTP_TICKET_TTL });
}

/** 확인 표 → 그 사람(아직 쓸 수 있는 계정이고 토큰 버전이 같을 때만) | null. */
export async function userFromOtpTicket(ticket, purpose) {
  if (typeof ticket !== 'string' || ticket.length > 2000) return null;
  let payload;
  try {
    payload = jwt.verify(ticket, JWT_SECRET);
  } catch {
    return null;
  }
  if (payload.type !== 'otp' || payload.purpose !== purpose) return null;
  const user = await findUserById(payload.sub);
  if (!user || user.deletedAt || user.suspendedAt || (user.tokenVersion ?? 0) !== payload.tv) return null;
  return user;
}

const tokensFor = (user) => ({ ...issueTokenPair(user), userId: user.id, username: user.username });

/**
 * 로그인 마무리 — 비밀번호·디렉터리를 통과한 [user]에게 토큰을 주거나, 2단계 인증이 남았으면 확인 표를 준다. 회사 계정(SSO —
 * [method] 'sso')은 그쪽의 2단계 인증을 쓰므로 묻지 않는다. 응답은 이 함수가 끝낸다.
 */
export async function completeLogin(res, user, { method = 'password' } = {}) {
  if (method !== 'sso') {
    if (user.totpEnabledAt && user.totpSecretEnc) {
      return res.status(403).json({
        error: UPDATE_APP_ERROR,
        code: 'otp_required',
        otpRequired: true,
        otpTicket: issueOtpTicket(user, 'login'),
        username: user.username,
      });
    }
    const settings = await getServerSettings();
    if (otpRequiredFor(settings.otpPolicy, user)) {
      return res.status(403).json({
        error: UPDATE_APP_ERROR,
        code: 'otp_setup_required',
        otpSetupRequired: true,
        otpTicket: issueOtpTicket(user, 'setup'),
        username: user.username,
      });
    }
  }
  return res.json(tokensFor(user));
}

/** 막혀 있으면 429를 보내고 true. */
function otpBlocked(res, userId) {
  const wait = limits.otpUser.blockedFor(userId);
  if (wait <= 0) return false;
  retryLater(res, wait, `코드를 너무 많이 틀렸습니다. ${waitText(wait)} 뒤에 다시 시도하세요.`);
  return true;
}

/**
 * 코드 또는 복구 코드 확인 — 맞으면 쓴 것으로 적고(같은 30초 칸·같은 복구 코드를 두 번 못 쓰게 — 동시에 보내도 하나만 통과)
 * `{ ok: true, recoveryLeft? }`, 틀리면 실패를 센다.
 */
async function checkSecondFactor(user, { code, recoveryCode }) {
  if (recoveryCode) {
    const r = useRecoveryCode(user.totpRecoveryHashes, recoveryCode, lookupHash);
    if (r.ok && (await replaceRecoveryHashes(user.id, user.totpRecoveryHashes ?? [], r.remaining))) {
      limits.otpUser.reset(user.id);
      return { ok: true, recoveryLeft: r.remaining.length };
    }
  } else {
    const secret = decryptField(user.totpSecretEnc);
    const r = secret ? verifyTotp(secret, code, { lastStep: user.totpLastStep ?? null }) : { ok: false };
    if (r.ok && (await claimTotpStep(user.id, r.step))) {
      limits.otpUser.reset(user.id);
      return { ok: true };
    }
  }
  limits.otpUser.fail(user.id);
  return { ok: false };
}

/** Bearer 토큰의 그 사람 | null(401을 보낸다). */
async function bearerUser(req, res) {
  const payload = await accessPayload(req);
  const user = payload ? await findUserById(payload.sub) : null;
  if (!user) {
    res.status(401).json({ error: '토큰이 유효하지 않습니다.' });
    return null;
  }
  req.user = payload;
  return user;
}

/** 켜기 단계(설정·켜기)의 그 사람 — 확인 표(로그인 중 그 자리에서 켜기) 또는 Bearer(내 프로필에서 켜기). */
async function setupUser(req, res) {
  const ticket = req.body?.ticket;
  if (ticket) {
    const user = await userFromOtpTicket(ticket, 'setup');
    if (!user) res.status(401).json({ error: '확인 시간이 지났습니다. 처음부터 다시 로그인하세요.' });
    return user;
  }
  return bearerUser(req, res);
}

export function createLoginSecurityRouter() {
  const router = Router();

  /** 로그인 둘째 단계 — 확인 표 + 6자리 코드(또는 복구 코드) → 토큰. */
  router.post('/login/otp', async (req, res) => {
    const { ticket, code, recoveryCode } = req.body ?? {};
    const user = await userFromOtpTicket(ticket, 'login');
    if (!user || !user.totpSecretEnc) return res.status(401).json({ error: '확인 시간이 지났습니다. 처음부터 다시 로그인하세요.' });
    if (otpBlocked(res, user.id)) return;
    const checked = await checkSecondFactor(user, { code, recoveryCode });
    if (!checked.ok) {
      return res.status(400).json({ error: recoveryCode ? '복구 코드가 맞지 않거나 이미 쓴 코드입니다.' : OTP_FAILED_ERROR });
    }
    res.json({ ...tokensFor(user), ...(checked.recoveryLeft !== undefined ? { recoveryCodesLeft: checked.recoveryLeft } : {}) });
  });

  /** 내 2단계 인증 상태. */
  router.get('/otp/status', async (req, res) => {
    const user = await bearerUser(req, res);
    if (!user) return;
    const settings = await getServerSettings();
    res.json({
      enabled: !!user.totpEnabledAt,
      required: otpRequiredFor(settings.otpPolicy, user),
      policy: settings.otpPolicy,
      recoveryCodesLeft: Array.isArray(user.totpRecoveryHashes) ? user.totpRecoveryHashes.length : 0,
    });
  });

  /** 켜기 1단계 — 새 비밀 키(인증 앱에 넣을 글자와 QR 주소). 켜기 전까지는 대기 칸에만 있다. */
  router.post('/otp/setup', async (req, res) => {
    const user = await setupUser(req, res);
    if (!user) return;
    if (user.totpEnabledAt) return res.status(409).json({ error: '2단계 인증이 이미 켜져 있습니다.' });
    const secret = generateTotpSecret();
    await updateUser(user.id, { totpPendingEnc: encryptField(secret) });
    res.json({ secret, uri: otpauthUri({ secret, account: user.username }) });
  });

  /** 켜기 2단계 — 인증 앱의 코드로 확인하면 켜고 복구 코드 10개를 한 번만 보여 준다. 로그인 중이었으면(확인 표) 토큰도 준다. */
  router.post('/otp/enable', async (req, res) => {
    const user = await setupUser(req, res);
    if (!user) return;
    if (user.totpEnabledAt) return res.status(409).json({ error: '2단계 인증이 이미 켜져 있습니다.' });
    const pending = decryptField(user.totpPendingEnc);
    if (!pending) return res.status(400).json({ error: '먼저 비밀 키를 받으세요(처음부터 다시).' });
    if (otpBlocked(res, user.id)) return;
    const r = verifyTotp(pending, req.body?.code);
    if (!r.ok) {
      limits.otpUser.fail(user.id);
      return res.status(400).json({ error: OTP_FAILED_ERROR });
    }
    limits.otpUser.reset(user.id);
    const codes = generateRecoveryCodes();
    const updated = await updateUser(user.id, {
      totpSecretEnc: user.totpPendingEnc,
      totpPendingEnc: null,
      totpEnabledAt: new Date(),
      totpLastStep: r.step,
      totpRecoveryHashes: hashRecoveryCodes(codes, lookupHash),
    });
    res.json({ recoveryCodes: codes, ...(req.body?.ticket ? tokensFor(updated) : {}) });
  });

  /** 끄기 — 지금 코드(또는 복구 코드)와, 이 앱의 비밀번호를 쓰는 계정이면 비밀번호까지. 정책상 꼭 써야 하면 끌 수 없다. */
  router.post('/otp/disable', async (req, res) => {
    const user = await bearerUser(req, res);
    if (!user) return;
    if (!user.totpEnabledAt) return res.json({ enabled: false });
    const settings = await getServerSettings();
    if (otpRequiredFor(settings.otpPolicy, user)) {
      return res.status(403).json({ error: '관리자가 2단계 인증을 꼭 쓰게 정해서 끌 수 없습니다.' });
    }
    if (usesLocalPassword(user)) {
      const password = req.body?.password;
      if (typeof password !== 'string' || !(await bcrypt.compare(password, user.passwordHash))) {
        return res.status(400).json({ error: '비밀번호가 맞지 않습니다.' });
      }
    }
    if (otpBlocked(res, user.id)) return;
    const checked = await checkSecondFactor(user, { code: req.body?.code, recoveryCode: req.body?.recoveryCode });
    if (!checked.ok) return res.status(400).json({ error: OTP_FAILED_ERROR });
    await updateUser(user.id, {
      totpSecretEnc: null,
      totpPendingEnc: null,
      totpEnabledAt: null,
      totpLastStep: null,
      totpRecoveryHashes: null,
    });
    res.json({ enabled: false });
  });

  /** 복구 코드 새로 받기 — 지금 코드로 확인. 예전 복구 코드는 모두 못 쓰게 된다. */
  router.post('/otp/recovery-codes', async (req, res) => {
    const user = await bearerUser(req, res);
    if (!user) return;
    if (!user.totpEnabledAt) return res.status(400).json({ error: '2단계 인증이 꺼져 있습니다.' });
    if (otpBlocked(res, user.id)) return;
    const checked = await checkSecondFactor(user, { code: req.body?.code });
    if (!checked.ok) return res.status(400).json({ error: OTP_FAILED_ERROR });
    const codes = generateRecoveryCodes();
    await updateUser(user.id, { totpRecoveryHashes: hashRecoveryCodes(codes, lookupHash) });
    res.json({ recoveryCodes: codes });
  });

  return router;
}

// ── 회사 계정·디렉터리로 들어온 사람의 계정 ───────────────────────────────

const CHARACTER_EMOJIS = ['🧑‍💼', '👩‍💼', '🧑‍🔬', '🧑‍🎨', '🧔', '👩‍🦱'];
const CHARACTER_COLORS = ['#4C6EF5', '#15AABF', '#37B24D', '#0CA678', '#9775FA', '#FF6B35'];
const pick = (list) => list[crypto.randomInt(list.length)];

/**
 * 회사 계정·디렉터리로 처음 들어온 사람의 계정을 만든다 — 이 앱의 비밀번호는 없다(아무도 모르는 무작위 해시). 이메일은 이미
 * 다른 계정이 쓰고 있으면 비워 둔다(이메일은 계정마다 하나). [usernameHint]가 아이디 규칙에 맞고 비어 있으면 그것, 아니면
 * 이메일 앞부분으로 만든다. `{ user }` | `{ error }`.
 */
/**
 * 디렉터리가 알려 준 부서 글자 → 계정 칸 `{ department, departmentId }` — 계정 단위 조직도면 같은 이름 부서에 잇는다(없으면 맨 위에
 * 만든다 — orgTree.js departmentForText). 디렉터리가 부서의 기준이라 로그인할 때마다 맞춘다.
 */
async function directoryDepartmentFields(department) {
  const settings = await getServerSettings();
  const dept = settings.orgScope === 'account' && department ? await departmentForText('server', department) : null;
  return { department: dept?.name ?? department ?? null, departmentId: dept?.id ?? null };
}

export async function provisionExternalUser({ usernameHint, email, name, role, authSource, department = null, position = null }) {
  const isTaken = (u) => isUsernameTakenIgnoringCase(u);
  let username = null;
  const hint = String(usernameHint ?? '').trim();
  if (USERNAME_PATTERN.test(hint) && !(await isTaken(hint))) username = hint;
  if (!username) username = await usernameFromEmail(email ?? hint, isTaken);
  const emailFree = email ? !(await findUserByEmailLookup(lookupHash(email))) : false;
  const defaultPosition = position ? null : await findDefaultPositionOption();
  const fields = {
    username,
    name: (name ?? '').trim().slice(0, 40) || username,
    role,
    isServerAdmin: false,
    authSource,
    ...(await directoryDepartmentFields(department ? department.slice(0, 60) : null)),
    position: position ? position.slice(0, 40) : (defaultPosition?.label ?? null),
    emailEnc: emailFree ? encryptField(email) : null,
    emailLookup: emailFree ? lookupHash(email) : null,
    emailVerifiedAt: emailFree ? new Date() : null,
    passwordHash: await bcrypt.hash(crypto.randomBytes(32).toString('base64url'), 10),
    avatarType: 'character',
    avatarEmoji: pick(CHARACTER_EMOJIS),
    avatarColor: pick(CHARACTER_COLORS),
  };
  const { user, usernameTaken } = await insertRegisteredUser(fields, { role: 'admin', isServerAdmin: true });
  if (usernameTaken) return { error: '계정을 만드는 사이 같은 아이디가 생겼습니다. 다시 로그인하세요.' };
  return { user };
}

/**
 * 디렉터리(LDAP) 로그인이 맞았을 때 이 앱 계정 고르기 → `{ user }` | `{ status, error }`.
 *  1. 이미 연결된 디렉터리 계정이면 그 사람(이름·부서·직책은 디렉터리 값으로 맞춘다).
 *  2. 같은 아이디의 계정이 있으면 — 이메일이 디렉터리와 같을 때만 잇고 그 계정을 디렉터리 로그인으로 바꾼다(이 앱의 비밀번호로는
 *     더 못 들어온다 — 퇴사로 회사 계정을 막으면 여기서도 막히게). 이메일이 다르면 다른 사람일 수 있어 잇지 않는다.
 *  3. 없으면 — 자동 생성이 켜져 있을 때만 만든다.
 */
export async function resolveDirectoryLogin({ localUser, typedUsername, profile, settings }) {
  const identity = await findIdentity('ldap', profile.subject);
  if (identity) {
    const user = await findUserById(identity.userId);
    if (!user) return { status: 401, error: '계정을 찾을 수 없습니다.' };
    await touchIdentity(identity.id);
    const patch = {};
    if (profile.name && profile.name !== user.name) patch.name = profile.name.slice(0, 40);
    if (profile.department && profile.department !== user.department) patch.department = profile.department.slice(0, 60);
    if (profile.title && profile.title !== user.position) patch.position = profile.title.slice(0, 40);
    if (user.authSource !== 'ldap') patch.authSource = 'ldap';
    if ('department' in patch) Object.assign(patch, await directoryDepartmentFields(patch.department));
    return { user: Object.keys(patch).length ? await updateUser(user.id, patch) : user };
  }
  if (localUser?.id) {
    const localEmail = localUser.emailEnc ? String(decryptField(localUser.emailEnc) ?? '').toLowerCase() : null;
    if (localUser.authSource === 'sso' || !profile.email || !localEmail || localEmail !== profile.email) {
      return {
        status: 409,
        error:
          '같은 아이디의 계정이 이미 있는데 회사 계정과 이메일이 달라 연결하지 않았습니다. 이 앱의 비밀번호로 로그인하거나 관리자에게 문의하세요.',
      };
    }
    const linked = await linkIdentity({
      userId: localUser.id,
      provider: 'ldap',
      subject: profile.subject,
      emailEnc: encryptField(profile.email),
    });
    if (!linked) return { status: 409, error: '이 회사 계정은 이미 다른 계정에 연결되어 있습니다. 관리자에게 문의하세요.' };
    return { user: await updateUser(localUser.id, { authSource: 'ldap' }) };
  }
  if (!settings.ldapAutoCreate) {
    return { status: 403, error: '회사 계정은 확인했지만 이 서버에 계정이 없습니다. 관리자에게 계정을 만들어 달라고 하세요.' };
  }
  const made = await provisionExternalUser({
    usernameHint: typedUsername,
    email: profile.email,
    name: profile.name,
    role: settings.ldapDefaultRole ?? 'member',
    authSource: 'ldap',
    department: profile.department,
    position: profile.title,
  });
  if (made.error) return { status: 409, error: made.error };
  const linked = await linkIdentity({
    userId: made.user.id,
    provider: 'ldap',
    subject: profile.subject,
    emailEnc: profile.email ? encryptField(profile.email) : null,
  });
  if (!linked) return { status: 409, error: '이 회사 계정은 이미 다른 계정에 연결되어 있습니다. 관리자에게 문의하세요.' };
  return { user: made.user };
}

/** 디렉터리 로그인을 지금 쓸 수 있는지(켜져 있고, 시험을 통과했고, 값이 다 있다). */
export const ldapUsable = (settings) => !!settings.ldapEnabled && !!settings.ldapTestedAt && !ldapConfigProblem(settings);

const DIRECTORY_CHECK_MS = 10 * 60 * 1000;
const directoryChecks = new Map(); // userId → { at, active }

/**
 * 디렉터리 계정이 아직 살아 있는지(토큰 갱신 때 — authSource 'ldap'). 10분 동안 기억한다. 디렉터리에 못 붙거나 디렉터리 로그인이
 * 꺼져 있으면 막지 않는다(서버가 잠깐 안 될 때 모두가 로그아웃되지 않게 — 그 사이 새로 로그인은 못 한다).
 */
export async function directoryAccountActive(user, { stillActive = ldapStillActive } = {}) {
  const hit = directoryChecks.get(user.id);
  if (hit && Date.now() - hit.at < DIRECTORY_CHECK_MS) return hit.active;
  const settings = await getServerSettings();
  if (!ldapUsable(settings)) return true;
  const identity = await findIdentityForUser(user.id, 'ldap');
  if (!identity) return true;
  const r = await stillActive({ settings, subject: identity.subject });
  if (r.unavailable) return true;
  directoryChecks.set(user.id, { at: Date.now(), active: r.active });
  if (directoryChecks.size > 10_000) directoryChecks.delete(directoryChecks.keys().next().value);
  return r.active;
}
