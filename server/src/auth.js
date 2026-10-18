import bcrypt from "bcryptjs";
import { Router } from "express";
import jwt from "jsonwebtoken";
import { AUDIT, recordAudit } from "./audit.js";
import {
  LOGIN_FAILED_ERROR,
  beginAttempts,
  clientIp,
  clientIpKey,
  isLanAddress,
  limits,
  minutesText,
  parseNewUsername,
  pickUsernameMatch,
  rateLimit,
  retryLater,
  runLoginAttempt,
  userKey,
  waitText,
} from "./authGuard.js";
import { JWT_SECRET } from "./config.js";
import { decryptField, encryptField, lookupHash } from "./crypto.js";
import { getServerSettings } from "./db/queries/serverSettings.js";
import { checkEmailCode, consumeEmailCode, issueEmailCode, mailFailureText } from "./emailCodes.js";
import { sendMail } from "./mailer.js";
import { maskEmail, mailReady } from "./mailRules.js";
import { findIdMail } from "./mailTemplates.js";
import { passwordPolicyError } from "./passwordPolicy.js";
import { accountState, deviceActive, ssoSessionActive } from "./authState.js";
import { endSsoLogin } from "./ssoSessions.js";
import { syncDirectoryGroupsOnLogin } from "./groupSync.js";
import { syncDirectoryOrgForUser } from "./orgDirectorySync.js";
import { LDAP_REASON_TEXT, ldapAuthenticate } from "./ldapAuth.js";
import { completeLogin, directoryAccountActive, ldapUsable, resolveDirectoryLogin } from "./loginSecurity.js";
import { localPasswordBlockedText, usesLocalPassword } from "./loginSecurityRules.js";
import { parseUserName } from "./avatarRules.js";
import { endUserCallAccess } from "./callAccess.js";
import { clearPushTargetsForUser } from "./db/queries/devices.js";
import {
  findUserByEmailLookup,
  findUserById,
  insertRegisteredUser,
  isUsernameTakenIgnoringCase,
  listUsersByUsernameIgnoringCase,
  updateUser,
} from "./db/queries/users.js";
import { findTeamInviteLinkByToken, consumeTeamInviteLink } from "./db/queries/teamInviteLinks.js";
import { consumeInviteLink, findInviteLinkByToken } from "./db/queries/inviteLinks.js";
import { addTeamMembers } from "./db/queries/teams.js";
import { addRoomMembers, listAutoInviteTopics, listRoomMemberIds } from "./db/queries/rooms.js";
import { findDefaultPositionOption } from "./db/queries/positionOptions.js";
import { notifyMembership, postSystemMessage } from "./rooms.js";
import { announceTeamJoin } from "./selfRoomNotices.js";
import { inviteLinkJoinable } from "./invites.js";
import { teamInviteLinkJoinable } from "./teamInvites.js";

const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
// 이메일 칸 길이 상한 — 아이디 찾기(/find-id)와 같다. 그보다 긴 값은 볼 것도 없이 거절한다.
const EMAIL_MAX_LENGTH = 200;
// 보안 질문(직접 쓰는 질문 포함)·답 길이 상한 — 미리 준비된 질문은 30자 남짓이다. 가입 한 번으로 아주 긴 글을 쌓아 두지 못하게.
const SECURITY_QUESTION_MAX_LENGTH = 200;
const SECURITY_ANSWER_MAX_LENGTH = 100;
// 로그인·비밀번호 찾기에 온 아이디 길이 상한 — 입력칸(20자)을 한참 넘는 값은 제한 기록의 키로 쓰이기 전에 거절한다
// (아주 긴 값을 계속 바꿔 보내 서버 메모리를 채우지 못하게). 이 규칙 전의 아이디도 20자를 넘지 않는다.
const USERNAME_INPUT_MAX_LENGTH = 64;
const OUTSIDE_NEEDS_INVITE_ERROR =
  "사내 와이파이 밖에서는 초대 링크로만 가입할 수 있습니다. 초대 링크를 받아 그 코드로 서버에 연결하거나(아이폰은 초대 안내에 있는 웹 앱 주소로 열기), 사내 와이파이에서 가입하세요.";
const INVITE_UNUSABLE_ERROR =
  "초대 링크가 만료·취소되었거나 정해진 인원이 모두 가입해 더는 쓸 수 없습니다. 초대한 사람에게 새 링크를 요청하거나, 사내 와이파이에서 가입하세요.";

// 대소문자/앞뒤 공백 차이로 정답이 틀렸다고 나오지 않도록 정규화 후 해시/비교한다.
const normalizeAnswer = (s) =>
  String(s ?? "")
    .trim()
    .toLowerCase();

// 클라이언트의 "캐릭터 선택하기" 화면(client/lib/screens/my_profile_dialog.dart)과 같은 구성.
const CHARACTER_EMOJIS = [
  "🧑‍🦰",
  "👮",
  "🧑‍🌾",
  "👩‍🦰",
  "🧑‍✈️",
  "👩‍💼",
  "🧑‍💼",
  "👩‍🦱",
  "🧔",
  "👩‍🎤",
  "🧑‍🎨",
  "🧑‍🔬",
];
const CHARACTER_COLORS = [
  "#9AA6B2",
  "#4C6EF5",
  "#15AABF",
  "#FAB005",
  "#FF6B35",
  "#37B24D",
  "#0CA678",
  "#E64980",
  "#9775FA",
  "#8D6E63",
];
const randomOf = (list) => list[Math.floor(Math.random() * list.length)];

// AccessToken은 짧게(매 API 요청마다 DB 조회 없이 서명/만료만 검증), RefreshToken은
// 길게(만료되거나 재시작했을 때만 새 AccessToken을 받아오며, 이때만 tokenVersion을 DB와
// 대조한다) 가져가는 이중 토큰 구조. 비밀번호 변경 시 tokenVersion을 올리면, 이미 나가있는
// AccessToken은 최대 그 유효기간(1시간)만큼만 더 쓰이고, RefreshToken은 그 즉시 막힌다.
const ACCESS_TOKEN_TTL = "1h";
const REFRESH_TOKEN_TTL = "30d";

/**
 * 무차별 대입으로 막히기 시작한 순간을 콘솔과 감사 로그(관리자 콘솔)에 남긴다. 같은 키는
 * 차단이 풀릴 때까지 다시 안 찍히므로 공격이 계속돼도 기록이 넘치지 않는다.
 */
function reportLockout({ ip, username, user, detail }) {
  console.warn(`[보안] ${detail} — IP ${ip}, 아이디 "${username}"`);
  recordAudit({
    actorName: `IP ${ip}`,
    action: AUDIT.authLockout,
    targetType: "user",
    targetId: user?.id ?? null,
    targetLabel: username || null,
    detail,
  });
}

/**
 * 비밀번호 재설정(보안 질문) 경로의 무차별 대입 방어. 막혀 있으면 429를 보내고 null,
 * 아니면 실패/성공을 알릴 함수들을 돌려준다.
 *
 * 이 확인은 시작할 때 "확인 중"으로 걸어 둔다(authGuard.js beginAttempts) — 답을 확인하는(DB·bcrypt) 동안엔 실패가 아직
 * 세어지지 않아서, 예전엔 한꺼번에 보낸 요청들이 모두 "아직 0번 틀림"을 보고 들어가 3번 제한인데도 수십 개의 답을 맞춰 볼
 * 수 있었다. fail()/succeed()가 결과를 세면서 놓고, 다른 길로 끝나도 놓이게 라우트는 finally에서 release()를 부른다.
 */
function recoveryGuard(req, res, username) {
  const ip = clientIp(req);
  const external = !isLanAddress(ip);
  const uk = userKey(username);
  // IP 쪽은 밖의 IPv6를 /64로 묶은 키 — 주소 끝만 바꿔 가며 다시 시도하지 못하게(authGuard.js ipKey).
  const ipUser = `${clientIpKey(req)}|${uk}`;
  const slots = [[limits.recoveryIpUser, ipUser]];
  if (external) slots.push([limits.recoveryUserExternal, uk]);
  const attempt = beginAttempts(slots);
  if (attempt.wait > 0) {
    retryLater(res, attempt.wait, `확인 시도가 너무 많습니다. ${waitText(attempt.wait)} 후 다시 시도하세요.`);
    return null;
  }
  return {
    external,
    fail(user) {
      if (limits.recoveryIpUser.fail(ipUser)) {
        reportLockout({ ip, username: uk, user, detail: `비밀번호 재설정 확인 3회 실패 — 이 IP에서 ${minutesText(limits.recoveryIpUser.blockMs)} 차단` });
      }
      if (external && limits.recoveryUserExternal.fail(uk)) {
        reportLockout({ ip, username: uk, user, detail: `사내망 밖에서 비밀번호 재설정 확인 10회 실패 — 밖에서는 ${minutesText(limits.recoveryUserExternal.blockMs)} 재설정 불가` });
      }
      attempt.release();
    },
    succeed() {
      limits.recoveryIpUser.reset(ipUser);
      attempt.release();
    },
    // 여러 번 불러도 한 번만 놓는다.
    release: attempt.release,
  };
}

/** 토큰이 가리키는 초대 링크 — 팀 초대면 { teamLink }, 설치 초대면 { inviteLink }, 둘 다 아니면 null. */
async function findInviteByToken(token) {
  if (typeof token !== "string" || !token) return null;
  const teamLink = await findTeamInviteLinkByToken(token);
  if (teamLink) return { teamLink };
  const inviteLink = await findInviteLinkByToken(token);
  return inviteLink ? { inviteLink } : null;
}

/**
 * 지금 이 초대 링크로 가입할 수 있는지 — 만료·취소·인원 마감이 아니고, 만든 사람이 지금도 그 링크를 줄 수 있는 사람일
 * 때만(teamInvites.js의 teamInviteLinkJoinable, invites.js의 inviteLinkJoinable). 인원이 다 찬 링크로도 앱 연결
 * (인증서 받기·설치 — pairing.js)은 되지만, 가입은 여기서 인원까지 보고 막는다.
 */
async function inviteJoinable(invite) {
  if (invite?.teamLink) return teamInviteLinkJoinable(invite.teamLink);
  if (invite?.inviteLink) return inviteLinkJoinable(invite.inviteLink);
  return false;
}

/**
 * 가입 한 건에 그 초대 링크의 한 자리를 쓴다 — 지금도 그 링크로 가입할 수 있을 때만. 자리 확인과 차감은 한 문장이라 동시에
 * 여러 명이 가입해도 정한 인원을 넘지 않는다(consumeTeamInviteLink / consumeInviteLink). 썼으면 true.
 */
async function claimInviteSeat(invite) {
  if (!(await inviteJoinable(invite))) return false;
  return invite.teamLink ? consumeTeamInviteLink(invite.teamLink.id) : consumeInviteLink(invite.inviteLink.id);
}

/** 보안 질문이 없는(이 기능 전에 가입한) 계정은 아이디+이메일만으로 재설정되므로 사내망에서만 허용한다. */
const NO_QUESTION_EXTERNAL_ERROR =
  "보안 질문이 등록되지 않은 계정은 사내 와이파이에서만 비밀번호를 재설정할 수 있습니다. 서버 운영자에게 문의하세요.";
const RECOVERY_NO_MATCH_ERROR = "아이디와 이메일이 일치하는 계정이 없습니다.";

// 없는 아이디로 로그인할 때도 bcrypt 비교 한 번만큼 시간을 쓰게 하는 더미 해시 — 응답 시간
// 차이로 "이 아이디는 있다/없다"를 알아내지 못하게 한다.
const DUMMY_PASSWORD_HASH = bcrypt.hashSync("dummy-password-for-timing", 10);

/** 로그인·비밀번호 찾기에 온 아이디 값이 쓸 만한지 — 문자열이고 너무 길지 않아야 한다(앞뒤 공백은 찾을 때 뗀다). */
const usableUsernameInput = (value) => typeof value === "string" && value.length <= USERNAME_INPUT_MAX_LENGTH;

/**
 * 로그인할 계정을 아이디로 찾는다 — 앱처럼 앞뒤 공백을 떼고, 글자까지 같은 계정이 먼저, 없으면 대소문자만 다른 계정이 하나일
 * 때만 그 계정이다(authGuard.js pickUsernameMatch). 둘 이상이면(이 규칙 전에 'Kim'·'kim'이 따로 가입한 서버) 고르지 않는다 —
 * 대소문자까지 똑같이 넣어야 한다. 아이디 규칙이 생기기 전의 계정(한글 등)도 글자 그대로 넣으면 그대로 찾는다.
 * 있는 아이디든 없는 아이디든 늘 같은 조회 한 번이다 — "글자 그대로 먼저, 빗나가면 한 번 더"로 나누면 조회 횟수만큼 응답
 * 시간이 달라져, 더미 해시(DUMMY_PASSWORD_HASH)로 맞춰 둔 "이 아이디가 있는지"를 다시 알 수 있게 된다.
 */
async function findAccountByUsername(input) {
  const name = input.trim();
  if (!name) return null;
  return pickUsernameMatch(await listUsersByUsernameIgnoringCase(name), name).user;
}

/**
 * 비밀번호 찾기의 계정 — 아이디와 이메일이 둘 다 맞는 계정. 아이디는 로그인과 같은 규칙으로 보되(글자까지 같은 것 먼저, 없으면
 * 대소문자만 다른 것), 이메일이 같은 계정 안에서만 고른다(이메일은 계정마다 하나라 대소문자만 다른 아이디가 여럿이어도 헷갈리지
 * 않는다). 이메일은 lookupHash가 대소문자·앞뒤 공백을 무시해 비교한다. 로그인처럼 늘 같은 조회 한 번이다.
 */
async function findAccountForRecovery(usernameInput, email) {
  const name = usernameInput.trim();
  const emailLookup = lookupHash(email);
  if (!name || !emailLookup) return null;
  const sameEmail = (await listUsersByUsernameIgnoringCase(name)).filter((u) => u.emailLookup === emailLookup);
  return pickUsernameMatch(sameEmail, name).user;
}

/** 비밀번호 찾기 세 단계(질문 조회·답 확인·재설정)에 온 아이디·이메일 값 모양 — 문자열이고 너무 길지 않아야 한다. */
const usableRecoveryInput = (username, email) =>
  usableUsernameInput(username) && typeof email === "string" && email.length <= EMAIL_MAX_LENGTH;

/**
 * 이 계정은 비밀번호·아이디를 메일로 찾는지 — 서버에 메일이 켜져 있고 이메일을 확인한 계정만. 그런 계정은 보안 질문을 받지
 * 않는다(메일 코드가 보안 질문을 대신한다). 확인하지 않은 계정과 메일이 꺼진 서버는 예전처럼 보안 질문으로 찾는다.
 */
const usesEmailRecovery = (user, settings) => mailReady(settings) && !!user?.emailVerifiedAt && !!user?.emailEnc;

/** 업데이트 전 앱(메일 코드 단계를 모르는 앱)이 메일로 찾는 계정에 보안 질문 단계를 부를 때. */
const UPDATE_APP_FOR_EMAIL_RECOVERY_ERROR =
  "이 계정은 이메일로 받은 코드로 비밀번호를 찾습니다. 앱을 최신 버전으로 업데이트한 뒤 다시 시도하세요.";

/**
 * AccessToken·RefreshToken 한 쌍. [deviceId]를 주면 그 기기에 묶인 토큰(`did`)이 된다 — 그 기기를 "내 기기"에서 로그아웃시키면
 * (devices.js DELETE /devices/:id) 그 기기의 토큰만 REST·갱신·소켓에서 막힌다(authState.js deviceActive). 기기 등록 전에 받은
 * 토큰(로그인 직후·예전 앱)은 묶이지 않아서, 그런 토큰까지 끊으려면 "다른 모든 기기에서 로그아웃"(tokenVersion)을 쓴다.
 */
export function issueTokenPair(user, { deviceId = null, authAt = null, ssoSessionId = null } = {}) {
  const tokenVersion = user.tokenVersion ?? 0;
  // did — 묶인 기기, ssid — 회사 계정 로그인 세션(그쪽에서 로그아웃하면 이 토큰도 막힌다 — authState.js ssoSessionActive).
  const did = { ...(deviceId ? { did: deviceId } : {}), ...(ssoSessionId ? { ssid: ssoSessionId } : {}) };
  // aat — 처음 로그인(비밀번호·디렉터리·회사 계정)한 시각(초). 토큰을 다시 내줘도(갱신·기기 등록·비밀번호 변경) 그대로 이어서,
  // 회사 계정으로만 들어오는 계정은 이 시각에서 정한 날수가 지나면 다시 회사 계정으로 확인하게 한다(/refresh).
  const aat = Number.isInteger(authAt) ? authAt : Math.floor(Date.now() / 1000);
  const accessToken = jwt.sign(
    { sub: user.id, username: user.username, tokenVersion, ...did, aat, type: "access" },
    JWT_SECRET,
    { expiresIn: ACCESS_TOKEN_TTL },
  );
  const refreshToken = jwt.sign(
    { sub: user.id, tokenVersion, ...did, aat, type: "refresh" },
    JWT_SECRET,
    { expiresIn: REFRESH_TOKEN_TTL },
  );
  return { accessToken, refreshToken };
}

/** 가입/로그인/비밀번호 찾기. 팀이 생기면서 가입 시 방에 자동으로 넣는 처리는 없어졌다
 * (어느 팀에 들어갈지는 소유자/관리자가 정한다 — teams.js 참고). */
export function createAuthRouter(io) {
  const router = Router();

  /** 회원가입 폼에서 "중복 확인" 버튼이 누르는 참조용 가용성 체크. 실제 가입은 아니라 200으로
   *  응답하고, 이후 register에서도 (여기 통과 후 사이에 다른 사람이 선점했을 수 있으니) 다시
   *  한번 검사한다. */
  router.get("/username-available", rateLimit(limits.usernameCheckIp, "중복 확인 시도"), async (req, res) => {
    // 새 아이디 규칙(authGuard.js USERNAME_PATTERN — 영문·숫자·. _ -, 4~20자)에 안 맞으면 그 이유를 바로 알려준다 — 예전 앱도
    // 이 문구를 "중복 확인" 결과 자리에 그대로 보여 준다.
    const parsed = parseNewUsername(req.query.username ?? "");
    if (parsed.error) {
      return res.json({ available: false, error: parsed.error });
    }
    // 사내망 밖에서 초대 링크 없이 묻는 건 어차피 가입할 수 없는 사람이다 — 아이디가 있는지 알려주면 인터넷의
    // 누구나 직원 아이디 목록을 맞혀볼 수 있어서, DB를 보지 않고 "쓸 수 있음"으로만 답한다(실제 가입 때 다시
    // 검사해서 겹치면 그때 알린다). 초대 링크로 열린 앱은 그 토큰(inviteToken)을 같이 보낸다.
    if (!isLanAddress(clientIp(req)) && !(await inviteJoinable(await findInviteByToken(req.query.inviteToken)))) {
      return res.json({ available: true });
    }
    // 대소문자만 다른 아이디(Kim·kim)도 이미 있는 아이디로 본다 — 다른 사람 아이디를 흉내 낸 계정을 만들지 못하게.
    if (await isUsernameTakenIgnoringCase(parsed.username)) {
      return res.json({
        available: false,
        error: "이미 사용 중인 아이디입니다.",
      });
    }
    res.json({ available: true });
  });

  /**
   * 가입 전 이메일 확인 코드 보내기 — 메일이 켜진 서버에서만. 가입(register)은 이 코드를 함께 받아야 된다. 사내망 밖에서는
   * 가입처럼 지금 쓸 수 있는 초대 링크가 있어야 보낸다(인터넷의 아무나 서버 메일 계정으로 남에게 메일을 보내게 하지 않게).
   * 이미 가입된 이메일이면 보내지 않고 알린다 — 가입 화면도 같은 경우 "이미 사용 중인 이메일"이라고 알려 준다.
   */
  router.post("/email-code/signup", rateLimit(limits.mailSendIp, "메일 보내기 시도"), async (req, res) => {
    const { email, teamInviteToken } = req.body ?? {};
    if (!mailReady(await getServerSettings())) {
      return res.status(409).json({ error: "이 서버는 메일 기능이 꺼져 있습니다." });
    }
    if (!isLanAddress(clientIp(req)) && !(await inviteJoinable(await findInviteByToken(teamInviteToken)))) {
      const sentCode = typeof teamInviteToken === "string" && teamInviteToken;
      return res.status(403).json({ error: sentCode ? INVITE_UNUSABLE_ERROR : OUTSIDE_NEEDS_INVITE_ERROR });
    }
    if (typeof email !== "string" || email.length > EMAIL_MAX_LENGTH || !EMAIL_PATTERN.test(email)) {
      return res.status(400).json({ error: "이메일 형식이 올바르지 않습니다." });
    }
    if (await findUserByEmailLookup(lookupHash(email))) {
      return res.status(409).json({ error: "이미 사용 중인 이메일입니다." });
    }
    const sent = await issueEmailCode(res, { purpose: "signup", email });
    if (sent) res.json(sent);
  });

  router.post("/register", rateLimit(limits.registerIp, "가입 시도"), async (req, res) => {
    const {
      username,
      password,
      email,
      name,
      securityQuestion,
      securityAnswer,
      teamInviteToken,
      emailCode,
    } = req.body ?? {};
    // 사내망 밖(LTE/5G)에서는 지금 가입할 수 있는 초대 링크(설치 초대·팀 초대 — 인원까지 남은 것)를 받은
    // 사람만 가입할 수 있다 — 공유기 포트를 열면 인터넷 누구나 가입 화면에 닿기 때문이다. 앱은 초대 링크로
    // 열렸거나 "서버 주소 변경"에 초대 코드를 넣어 페어링했을 때 그 코드를 teamInviteToken으로 보낸다. 여기서는
    // 아이디 중복 등을 알려주기 전에 먼저 걸러내기만 하고, 링크의 자리는 계정을 넣기 직전에 잡는다(아래).
    const external = !isLanAddress(clientIp(req));
    const invite = await findInviteByToken(teamInviteToken);
    if (external && !(await inviteJoinable(invite))) {
      // 코드를 보냈는데 못 쓰는 경우는 링크가 있든 없든 같은 문구로 답한다(어떤 코드가 있는지 알려주지 않게).
      const sentCode = typeof teamInviteToken === "string" && teamInviteToken;
      return res.status(403).json({ error: sentCode ? INVITE_UNUSABLE_ERROR : OUTSIDE_NEEDS_INVITE_ERROR });
    }
    // 모두 문자열이어야 한다 — 예전엔 배열·객체도 길이만 맞으면 그 글자 모양("a,b")대로 저장됐다.
    const filled = (v) => typeof v === "string" && v.trim() !== "";
    if (!filled(username) || !filled(password) || !filled(email) || !filled(name)) {
      return res
        .status(400)
        .json({ error: "아이디, 이름, 비밀번호, 이메일을 입력하세요." });
    }
    // 앞뒤 공백을 떼고 새 아이디 규칙(영문·숫자·. _ -, 4~20자 — authGuard.js USERNAME_PATTERN)에 맞아야 한다.
    const parsedUsername = parseNewUsername(username);
    if (parsedUsername.error) {
      return res.status(400).json({ error: parsedUsername.error });
    }
    const newUsername = parsedUsername.username;
    // 이름은 프로필에서 바꿀 때(PATCH /users/me)와 같은 규칙 — 길이 상한, 화면을 어지럽히는 제어·방향·보이지 않는 글자 금지.
    const parsedName = parseUserName(name);
    if (parsedName.error) {
      return res.status(400).json({ error: parsedName.error });
    }
    const passwordError = passwordPolicyError(password, { username: newUsername });
    if (passwordError) {
      return res.status(400).json({ error: passwordError });
    }
    if (email.length > EMAIL_MAX_LENGTH || !EMAIL_PATTERN.test(email)) {
      return res
        .status(400)
        .json({ error: "이메일 형식이 올바르지 않습니다." });
    }
    // 메일이 켜진 서버에서는 이메일 확인 코드가 보안 질문을 대신한다 — 질문은 넣지 않아도 되고, 넣었으면 같은 규칙으로 본다.
    const mailOn = mailReady(await getServerSettings());
    const withQuestion = !mailOn || filled(securityQuestion) || filled(securityAnswer);
    if (withQuestion) {
      if (!filled(securityQuestion) || !filled(securityAnswer)) {
        return res.status(400).json({ error: "보안 질문과 답변을 입력하세요." });
      }
      // 답이 한 글자면 몇 번 만에 맞혀서 비밀번호를 바꿀 수 있다(사내망 밖에서도 재설정할 수 있어서).
      if (securityAnswer.trim().length < 2) {
        return res.status(400).json({ error: "보안 질문 답변은 2자 이상 입력하세요." });
      }
      if (securityQuestion.trim().length > SECURITY_QUESTION_MAX_LENGTH) {
        return res.status(400).json({ error: `보안 질문은 ${SECURITY_QUESTION_MAX_LENGTH}자 이내로 입력하세요.` });
      }
      if (securityAnswer.trim().length > SECURITY_ANSWER_MAX_LENGTH) {
        return res.status(400).json({ error: `보안 질문 답변은 ${SECURITY_ANSWER_MAX_LENGTH}자 이내로 입력하세요.` });
      }
    }

    // 대소문자만 다른 아이디(Kim·kim)도 이미 있는 아이디로 본다 — 계정을 넣을 때(insertRegisteredUser) 한 번 더 본다.
    if (await isUsernameTakenIgnoringCase(newUsername)) {
      return res.status(409).json({ error: "이미 사용 중인 아이디입니다." });
    }
    const emailLookup = lookupHash(email);
    const emailTaken = await findUserByEmailLookup(emailLookup);
    if (emailTaken) {
      return res.status(409).json({ error: "이미 사용 중인 이메일입니다." });
    }
    // 메일이 켜진 서버는 이 이메일로 받은 코드가 맞아야 가입된다(/email-code/signup). 코드는 계정이 들어간 뒤에 지운다 — 그 사이
    // 같은 코드로 두 번 가입해도 이메일이 같아 두 번째는 위의 중복 검사·unique에 걸린다.
    let signupCode = null;
    if (mailOn) {
      if (!filled(emailCode)) {
        return res.status(400).json({ error: "이메일로 받은 확인 코드를 넣으세요." });
      }
      const checked = await checkEmailCode({ purpose: "signup", email, code: emailCode });
      if (!checked.ok) return res.status(400).json({ error: checked.error });
      signupCode = checked.row;
    }

    // 직책 목록(관리자 콘솔 "운영 현황")에 "기본값"으로 지정된 직책이 있으면 가입과 동시에
    // 부여한다 — '팀 단위' 서버에서는 이 값이 어디서도 안 쓰이지만(직책은 팀마다 따로 관리),
    // 나중에 '계정 단위'로 바뀌어도 바로 의미가 생기도록 항상 채워 둔다.
    const defaultPosition = await findDefaultPositionOption();

    const fields = {
      username: newUsername,
      name: parsedName.value,
      // 가입하면 준회원으로 시작한다 — 초대받은 방에서만 활동할 수 있고, 서버 운영자가
      // 관리자 콘솔에서 정회원 이상으로 올려줘야 방을 만들거나 팀을 만들 수 있다.
      // 다만 서버의 첫 계정(=운영자)은 스스로 올려줄 사람이 없으므로 관리자로 시작한다(아래).
      role: "guest",
      isServerAdmin: false,
      position: defaultPosition?.label ?? null,
      emailEnc: encryptField(email),
      emailLookup,
      emailVerifiedAt: signupCode ? new Date() : null,
      passwordHash: await bcrypt.hash(password, 10),
      securityQuestion: withQuestion ? securityQuestion.trim() : null,
      securityAnswerHash: withQuestion ? await bcrypt.hash(normalizeAnswer(securityAnswer), 10) : null,
      avatarType: "character",
      avatarEmoji: randomOf(CHARACTER_EMOJIS),
      avatarColor: randomOf(CHARACTER_COLORS),
    };

    // 초대 링크로 왔으면 그 링크의 가입 인원 한 자리를 쓴다 — 계정을 넣기 직전에 잡아서, 입력 오류로
    // 실패한 시도는 자리를 쓰지 않는다. 사내망 밖에서는 이 자리가 곧 가입 자격이라, 그 사이 인원이
    // 다 찼거나 링크를 못 쓰게 됐으면 가입시키지 않는다. 사내에서는 링크 없이도 가입되므로 자리를 못
    // 잡아도 가입은 된다(팀 초대 링크였다면 팀에만 안 들어간다). 설치 초대 링크도 사내에서 그 링크로
    // 가입하면 한 자리를 쓴다 — 그래야 "가입 2/5명"이 어디서 가입했든 이 링크로 들어온 사람 수가 된다.
    const seated = invite ? await claimInviteSeat(invite) : false;
    if (external && !seated) {
      return res.status(403).json({ error: INVITE_UNUSABLE_ERROR });
    }

    // 서버에 계정이 하나도 없을 때(새로 설치했거나 데이터를 초기화한 서버의 첫 가입)만 그 계정이
    // 관리자 등급 + 서버 운영자가 된다 — 새 서버에서 아무도 관리자 콘솔에 못 들어가는 상태를 막는
    // 규칙으로, 기존 서버의 첫 계정에 표시를 찍은 마이그레이션(0020)과 같다. 예전엔 "운영자가 한
    // 명도 없으면"이 기준이라, 마지막 운영자가 탈퇴한 서버에서는 다음 가입자(밖에서 공유된 초대
    // 링크로 온 사람 포함)가 서버를 통째로 넘겨받았다 — 이제 마지막 운영자는 탈퇴·정지·해제할 수
    // 없다(users.js, admin.js). 그래도 운영자가 없는 서버(예전 규칙 때 마지막 운영자가 탈퇴한 경우 등)는
    // 서버 PC에서 scripts/grant-server-admin.mjs <아이디>로 이미 가입한 계정 하나를 운영자로 지정한다(활성
    // 운영자가 한 명도 없을 때만 동작한다 — .env를 읽을 수 있는 서버 PC 관리자만 돌릴 수 있다).
    const { user, firstAccount, usernameTaken } = await insertRegisteredUser(fields, { role: "admin", isServerAdmin: true });
    // 위에서 확인한 뒤 그 사이에 대소문자만 다른 같은 아이디가 먼저 가입한 경우(가입끼리 줄 세워 다시 본다 — users.js).
    if (usernameTaken) {
      return res.status(409).json({ error: "이미 사용 중인 아이디입니다." });
    }
    if (signupCode) await consumeEmailCode(signupCode);

    // 가입만으로는 어느 팀에도 들어가지 않는다 — 팀은 본인이 직접 만들거나(만든 사람이 그
    // 팀의 소유자가 된다), 소유자/관리자가 팀에 넣어줘야 들어간다(teams.js의 멤버 추가).
    // 공개 토픽 자동 가입도 이제 "서버 전체"가 아니라 "그 팀에 들어올 때" 일어난다.
    //
    // 예외: "팀 초대 링크"로 왔고 위에서 그 링크의 자리를 잡았다면 그 팀에 자동으로 합류시키고,
    // 링크에 미리 정해둔 등급을 부여한다(서버 운영자가 일일이 등급을 올려주는 수고를 줄이는 게 이
    // 기능의 목적). 서버의 첫 계정(운영자)은 이미 role: 'admin'으로 시작하고 팀 개념과 무관하므로
    // 건너뛴다.
    if (seated && invite.teamLink && !firstAccount) {
      const link = invite.teamLink;
      await addTeamMembers(link.teamId, [user.id], "member");
      const patch = {};
      if (link.assignedRole !== user.role) patch.role = link.assignedRole;
      // 직책 목록의 "기본값"(defaultPosition)보다 이 링크에 지정된 직책이 우선한다 —
      // 링크를 만든 사람이 이 사람을 위해 콕 집어 고른 값이라 더 구체적이다.
      if (link.assignedPosition) patch.position = link.assignedPosition;
      if (Object.keys(patch).length > 0) {
        await updateUser(user.id, patch);
      }
      // 준회원으로 부여됐다면(assignedRole === 'guest') 토픽 자동 가입 대상이
      // 아니다 — admin.js의 등급 상향 처리와 같은 규칙. 정회원 이상은 팀 멤버 추가(teams.js)와
      // 같이 '정회원 자동 초대'가 켜진 토픽에만 들어간다.
      if (link.assignedRole !== "guest") {
        for (const room of await listAutoInviteTopics(link.teamId)) {
          const memberIds = await listRoomMemberIds(room.id);
          if (memberIds.includes(user.id)) continue;
          await addRoomMembers(room.id, [user.id]);
          await notifyMembership(io, room);
          await postSystemMessage(io, room, `${user.name} 님이 참여했습니다.`);
        }
      }
      // 나와의 대화에 사용 안내, 그 팀 관리자들에게 참여 알림(스스로 들어온 것이라 관리자는 모두 받는다).
      await announceTeamJoin(io, { teamId: link.teamId, joinerIds: [user.id], actorId: user.id });
    }

    res.status(201).json({
      ...issueTokenPair(user),
      userId: user.id,
      username: user.username,
    });
  });

  /** 이메일로 아이디를 찾는다. 가입할 때 등록해둔 이메일이 있어야 동작한다. */
  router.post("/find-id", rateLimit(limits.lookupIp, "조회 시도"), async (req, res) => {
    const { email } = req.body ?? {};
    if (typeof email !== "string" || email.length > EMAIL_MAX_LENGTH) {
      return res.status(400).json({ error: "이메일을 확인하세요." });
    }
    // 이메일로 찾는다 — lookupHash가 대소문자·앞뒤 공백을 무시하고 비교하고, 이메일은 계정마다 하나라 헷갈릴 일이 없다.
    const user = await findUserByEmailLookup(lookupHash(email));
    if (!user) {
      return res.status(404).json({ error: "일치하는 계정이 없습니다." });
    }
    // 메일로 찾는 계정(메일이 켜졌고 이메일을 확인한 계정)은 화면에 보이지 않고 그 이메일로 아이디를 보낸다 — 이메일만 아는
    // 사람이 아이디를 알아내지 못한다. 앱은 sent를 보고 "메일을 보냈습니다"를 띄운다.
    if (usesEmailRecovery(user, await getServerSettings())) {
      const ipWait = limits.mailSendIp.hit(clientIpKey(req));
      if (ipWait > 0) return retryLater(res, ipWait, `메일 요청이 너무 많습니다. ${waitText(ipWait)} 후 다시 시도하세요.`);
      const addressWait = limits.mailSendAddress.hit(user.emailLookup);
      if (addressWait > 0) {
        return retryLater(res, addressWait, `이 주소로 메일을 너무 많이 보냈습니다. ${waitText(addressWait)} 뒤에 다시 시도하세요.`);
      }
      const address = decryptField(user.emailEnc);
      try {
        await sendMail(address, findIdMail(user.username));
      } catch (err) {
        return res.status(503).json({ error: mailFailureText(err) });
      }
      return res.json({ sent: true, email: maskEmail(address) });
    }
    // 사내망 밖에서는 앞 두 글자만 보여준다 — 이메일만 알면 아이디를 통째로 알아내 로그인·재설정 공격에 쓰는 걸
    // 막는다(본인은 앞부분만 봐도 대개 기억난다). 사내에서는 지금처럼 전부 보인다.
    const name = user.username;
    const shown = isLanAddress(clientIp(req)) ? name : name.slice(0, 2) + "*".repeat(Math.max(2, name.length - 2));
    res.json({ username: shown });
  });

  /**
   * 비밀번호를 재설정하기 전, 아이디+이메일이 일치하는 계정의 보안 질문을 가져온다.
   * 이 컬럼이 생기기 전에 가입한 계정은 질문이 없으므로 question: null을 돌려주고,
   * 클라이언트는 그 경우 답변 확인 단계 없이 바로 재설정하게 한다.
   */
  router.post("/security-question", rateLimit(limits.lookupIp, "조회 시도"), async (req, res) => {
    const { username, email } = req.body ?? {};
    const user = usableRecoveryInput(username, email) ? await findAccountForRecovery(username, email) : null;
    if (!user) {
      return res
        .status(404)
        .json({ error: RECOVERY_NO_MATCH_ERROR });
    }
    // 회사 계정·디렉터리로 로그인하는 계정은 이 앱의 비밀번호가 없다.
    if (!usesLocalPassword(user)) return res.status(400).json({ error: localPasswordBlockedText(user) });
    if (usesEmailRecovery(user, await getServerSettings())) {
      return res.status(409).json({ error: UPDATE_APP_FOR_EMAIL_RECOVERY_ERROR });
    }
    if (!user.securityAnswerHash && !isLanAddress(clientIp(req))) {
      return res.status(403).json({ error: NO_QUESTION_EXTERNAL_ERROR });
    }
    res.json({ question: user.securityQuestion ?? null });
  });

  /**
   * 비밀번호 찾기 첫 단계(새 앱) — 아이디+이메일이 맞는 계정이 어떻게 재설정하는지 알려 준다. 메일로 찾는 계정이면 그 이메일로
   * 재설정 코드를 보내고 `{ method: 'email', email(일부만), expiresInSeconds, resendInSeconds }`, 아니면 예전처럼
   * `{ method: 'question', question }`(질문이 없는 옛 계정은 null — 사내망에서만). 다시 부르면 코드를 다시 보낸다(1분 간격).
   */
  router.post("/password-reset/start", rateLimit(limits.lookupIp, "조회 시도"), async (req, res) => {
    const { username, email } = req.body ?? {};
    const user = usableRecoveryInput(username, email) ? await findAccountForRecovery(username, email) : null;
    if (!user) {
      return res.status(404).json({ error: RECOVERY_NO_MATCH_ERROR });
    }
    // 회사 계정·디렉터리로 로그인하는 계정은 이 앱의 비밀번호가 없다(찾을 것도 바꿀 것도 없다).
    if (!usesLocalPassword(user)) return res.status(400).json({ error: localPasswordBlockedText(user) });
    if (usesEmailRecovery(user, await getServerSettings())) {
      const ipWait = limits.mailSendIp.hit(clientIpKey(req));
      if (ipWait > 0) return retryLater(res, ipWait, `메일 요청이 너무 많습니다. ${waitText(ipWait)} 후 다시 시도하세요.`);
      const address = decryptField(user.emailEnc);
      const sent = await issueEmailCode(res, { purpose: "reset", email: address, userId: user.id });
      if (!sent) return;
      return res.json({ method: "email", email: maskEmail(address), ...sent });
    }
    if (!user.securityAnswerHash && !isLanAddress(clientIp(req))) {
      return res.status(403).json({ error: NO_QUESTION_EXTERNAL_ERROR });
    }
    res.json({ method: "question", question: user.securityQuestion ?? null });
  });

  /**
   * 메일로 받은 재설정 코드가 맞는지만 본다(비밀번호는 바꾸지 않음) — 맞을 때만 새 비밀번호 입력칸을 보여 주려고. 틀리면 보안
   * 질문 답과 같은 무차별 대입 제한(recoveryGuard)에 센다. 코드는 아직 쓰지 않는다 — 재설정(/reset-password)에서 다시 보고 쓴다.
   */
  router.post("/password-reset/verify-code", async (req, res) => {
    const { username, email, code } = req.body ?? {};
    if (!usableRecoveryInput(username, email)) {
      return res.status(400).json({ error: RECOVERY_NO_MATCH_ERROR });
    }
    const guard = recoveryGuard(req, res, username);
    if (!guard) return;
    try {
      const user = await findAccountForRecovery(username, email);
      if (!user) {
        guard.fail(null);
        return res.status(400).json({ error: RECOVERY_NO_MATCH_ERROR });
      }
      if (!usesEmailRecovery(user, await getServerSettings())) {
        return res.status(400).json({ error: "이 계정은 이메일 코드로 재설정하지 않습니다. 비밀번호 찾기를 처음부터 다시 하세요." });
      }
      const checked = await checkEmailCode({ purpose: "reset", email: decryptField(user.emailEnc), userId: user.id, code });
      if (!checked.ok) {
        if (checked.counted) guard.fail(user);
        return res.status(400).json({ error: checked.error });
      }
      res.json({ ok: true });
    } finally {
      guard.release();
    }
  });

  /**
   * 보안 질문 답변만 검증한다(비밀번호는 바꾸지 않음) — 재설정 화면에서 답변이 맞을
   * 때만 새 비밀번호 입력칸을 보여주기 위해 쓴다. 계정에 보안 질문이 없으면(컬럼 생기기
   * 전 가입) 항상 통과시킨다 — /reset-password의 검증 로직과 동일하게 맞춘다.
   */
  router.post("/verify-security-answer", async (req, res) => {
    const { username, email, securityAnswer } = req.body ?? {};
    if (!usableRecoveryInput(username, email)) {
      return res.status(400).json({ error: RECOVERY_NO_MATCH_ERROR });
    }
    const guard = recoveryGuard(req, res, username);
    if (!guard) return;
    try {
      const user = await findAccountForRecovery(username, email);
      if (!user) {
        guard.fail(null);
        return res
          .status(400)
          .json({ error: RECOVERY_NO_MATCH_ERROR });
      }
      // 메일로 찾는 계정은 보안 질문으로 재설정하지 않는다(메일 코드가 대신한다).
      if (usesEmailRecovery(user, await getServerSettings())) {
        return res.status(409).json({ error: UPDATE_APP_FOR_EMAIL_RECOVERY_ERROR });
      }
      if (user.securityAnswerHash) {
        const matches =
          typeof securityAnswer === "string" &&
          !!securityAnswer &&
          (await bcrypt.compare(
            normalizeAnswer(securityAnswer),
            user.securityAnswerHash,
          ));
        if (!matches) {
          guard.fail(user);
          return res
            .status(400)
            .json({ error: "보안 질문 답변이 일치하지 않습니다." });
        }
      } else if (guard.external) {
        return res.status(403).json({ error: NO_QUESTION_EXTERNAL_ERROR });
      }
      res.json({ ok: true });
    } finally {
      guard.release();
    }
  });

  /**
   * 비밀번호 재설정. 아이디와 이메일이 둘 다 일치해야 하고, 메일로 찾는 계정(usesEmailRecovery)은 그 이메일로 받은 코드
   * (emailCode)가, 그 밖의 계정은 보안 질문 답이 맞아야 한다(질문 컬럼이 생기기 전 가입한 계정은 사내망에서만 답 없이).
   */
  router.post("/reset-password", async (req, res) => {
    const { username, email, securityAnswer, emailCode, newPassword } = req.body ?? {};
    if (!usableRecoveryInput(username, email)) {
      return res.status(400).json({ error: RECOVERY_NO_MATCH_ERROR });
    }
    const passwordError = passwordPolicyError(newPassword, { username });
    if (passwordError) {
      return res.status(400).json({ error: passwordError });
    }

    const guard = recoveryGuard(req, res, username);
    if (!guard) return;
    let user;
    try {
      user = await findAccountForRecovery(username, email);
      if (!user) {
        guard.fail(null);
        return res
          .status(400)
          .json({ error: RECOVERY_NO_MATCH_ERROR });
      }
      if (!usesLocalPassword(user)) return res.status(400).json({ error: localPasswordBlockedText(user) });
      if (usesEmailRecovery(user, await getServerSettings())) {
        if (typeof emailCode !== "string" || !emailCode) {
          return res.status(409).json({ error: UPDATE_APP_FOR_EMAIL_RECOVERY_ERROR });
        }
        const checked = await checkEmailCode({ purpose: "reset", email: decryptField(user.emailEnc), userId: user.id, code: emailCode });
        if (!checked.ok) {
          if (checked.counted) guard.fail(user);
          return res.status(400).json({ error: checked.error });
        }
        // 바꾸기 전에 코드를 쓴다 — 같은 코드로 두 번 재설정하지 못하게(먼저 쓴 요청만 통과).
        if (!(await consumeEmailCode(checked.row))) {
          return res.status(400).json({ error: "확인 코드가 없거나 만료되었습니다. 코드를 다시 받으세요." });
        }
      } else if (user.securityAnswerHash) {
        const matches =
          typeof securityAnswer === "string" &&
          !!securityAnswer &&
          (await bcrypt.compare(
            normalizeAnswer(securityAnswer),
            user.securityAnswerHash,
          ));
        if (!matches) {
          guard.fail(user);
          return res
            .status(400)
            .json({ error: "보안 질문 답변이 일치하지 않습니다." });
        }
      } else if (guard.external) {
        return res.status(403).json({ error: NO_QUESTION_EXTERNAL_ERROR });
      }
      guard.succeed();
    } finally {
      guard.release();
    }

    // 비밀번호가 바뀌었으니 이전에 발급된 모든 토큰을 무효화한다: AccessToken은 남은
    // 유효기간(최대 1시간) 뒤에, RefreshToken은 즉시(다음 재발급 시도부터) 막히고,
    // 지금 연결돼있는 소켓도 바로 끊어서 실시간 세션도 함께 정리한다.
    await updateUser(user.id, {
      passwordHash: await bcrypt.hash(newPassword, 10),
      tokenVersion: (user.tokenVersion ?? 0) + 1,
    });
    io.in(`user:${user.id}`).disconnectSockets(true);
    // 비밀번호 찾기는 계정을 빼앗겼거나 폰을 잃어버렸을 때 쓰는 길이라, 로그아웃시킨 기기들로 가던 길도 함께 끊는다 —
    // 쫓겨난 기기는 인증이 막혀 자기 푸시 토큰을 못 지우므로 서버가 지운다(다시 로그인하면 앱이 새로 등록한다), 이미
    // 붙어 있는 화상회의 미디어도 소켓과 따로 오가므로 내보낸다(callAccess.js — 던지지 않는다). 뒷정리라서 실패해도
    // 기록만 남긴다.
    await clearPushTargetsForUser(user.id).catch((err) =>
      console.error("[auth] 비밀번호 재설정 뒤 푸시 토큰·구독 지우기 실패:", user.id, err?.message ?? err),
    );
    await endUserCallAccess(io, user.id);

    res.json({ ok: true });
  });

  router.post("/login", async (req, res) => {
    const { username, password } = req.body ?? {};
    // 아이디·비밀번호 칸 길이(20자)를 한참 넘는 값은 바로 거절한다 — 제한 기록의 키로 쓰이므로, 아주 긴 값을
    // 계속 바꿔 보내 서버 메모리를 채우는 걸 막는다. 비밀번호도 문자열이어야 한다(앱은 늘 문자열로 보낸다).
    if (
      !usableUsernameInput(username) ||
      (password != null && (typeof password !== "string" || password.length > 200))
    ) {
      return res.status(400).json({ error: LOGIN_FAILED_ERROR });
    }
    // 무차별 대입 방어와 판단 순서는 authGuard.js runLoginAttempt 한곳에 있다 — 같은 IP·아이디, 같은 IP(여러 아이디), 사내망
    // 밖에서 한 아이디로 세서 막고(확인 중인 시도까지 세서 한꺼번에 보내도 정한 횟수를 넘지 못한다), 사내망 밖 전체의 오류가
    // 많으면 처음 보는 곳은 줄을 세워 정해진 간격으로만 확인한다. 밖에서 최소 길이(8자)보다 짧은 비밀번호는 맞는지 보지도 않고
    // 늘 같은 문구로 거절한다(최소 길이를 올리기 전의 짧은 비밀번호는 사내에서만 받는다).
    //
    // 사내 디렉터리(LDAP) 로그인이 켜져 있으면 같은 자리에서 디렉터리로도 확인한다(loginSecurity.js):
    //  - 디렉터리 계정(authSource 'ldap')은 디렉터리 비밀번호로만, 이 앱의 아이디 계정은 이 앱의 비밀번호로 — 틀리면 디렉터리로도
    //    본다(같은 사람이면 이메일이 같을 때 연결된다).
    //  - 이 앱에 없는 아이디는 디렉터리에서 찾아(자동 생성이 켜져 있으면) 계정을 만든다.
    // 회사 계정 전용 계정(authSource 'sso')은 비밀번호가 없어 여기서는 늘 틀린다. 비밀번호(또는 디렉터리)가 맞으면 2단계 인증을
    // 물을지 본다(completeLogin).
    const settings = await getServerSettings();
    const ldapOn = ldapUsable(settings);
    const directory = { profile: null, reason: null };
    const result = await runLoginAttempt({
      ip: clientIp(req),
      username,
      password,
      findAccount: async (name) => {
        const local = await findAccountByUsername(name);
        if (local || !ldapOn) return local;
        // 이 앱에 없는 아이디 — 디렉터리에서 찾아볼 자리(제한·차례 규칙은 있는 계정과 같게 탄다).
        return name.trim() ? { id: null, username: name.trim(), directoryCandidate: true } : null;
      },
      checkPassword: async (pw, user) => {
        if (user && !user.directoryCandidate && user.authSource !== "ldap") {
          const localOk = usesLocalPassword(user) && (await bcrypt.compare(pw, user.passwordHash));
          if (localOk || !ldapOn) return localOk;
        } else if (!user || !ldapOn) {
          await bcrypt.compare(pw, DUMMY_PASSWORD_HASH);
          return false;
        }
        const r = await ldapAuthenticate({ settings, username: username.trim(), password: pw });
        directory.reason = r.reason ?? null;
        if (r.ok) directory.profile = r.profile;
        return r.ok;
      },
      report: reportLockout,
    });
    if (result.wait) return retryLater(res, result.wait, result.error);
    if (!result.user) {
      // 디렉터리 서버에 못 붙었으면 "비밀번호가 틀렸다"가 아니라 그 이유를 알린다.
      if (directory.reason === "unavailable") return res.status(503).json({ error: LDAP_REASON_TEXT.unavailable });
      return res.status(result.status).json({ error: result.error });
    }

    let user = result.user;
    if (directory.profile) {
      const resolved = await resolveDirectoryLogin({
        localUser: user.directoryCandidate ? null : user,
        typedUsername: username.trim(),
        profile: directory.profile,
        settings,
      });
      if (resolved.error) return res.status(resolved.status).json({ error: resolved.error });
      user = resolved.user;
      if (user.deletedAt) return res.status(403).json({ error: "탈퇴한 계정입니다." });
      if (user.suspendedAt) return res.status(403).json({ error: "정지된 계정입니다. 서버 운영자에게 문의하세요." });
      // 디렉터리 그룹으로 팀·등급 맞추기(groupSync.js — 꺼져 있으면 아무것도 안 한다).
      user = await syncDirectoryGroupsOnLogin(io, user, { source: "ldap", groups: directory.profile.groups });
      // 부서(OU 경로)·상위자(manager)도 디렉터리대로(orgDirectorySync.js — 켰을 때만).
      await syncDirectoryOrgForUser(io, user.id, directory.profile, settings);
    }
    return completeLogin(res, user, { method: directory.profile ? "ldap" : "password" });
  });

  /** AccessToken이 만료됐을 때 RefreshToken으로 새 AccessToken을 받아온다. */
  router.post("/refresh", async (req, res) => {
    const { refreshToken } = req.body ?? {};
    if (!refreshToken) {
      return res.status(400).json({ error: "refreshToken이 없습니다." });
    }

    let payload;
    try {
      payload = jwt.verify(refreshToken, JWT_SECRET);
    } catch {
      return res
        .status(401)
        .json({ error: "세션이 만료되었습니다. 다시 로그인해주세요." });
    }
    if (payload.type !== "refresh") {
      return res
        .status(401)
        .json({ error: "세션이 만료되었습니다. 다시 로그인해주세요." });
    }

    const user = await findUserById(payload.sub);
    if (!user || (user.tokenVersion ?? 0) !== payload.tokenVersion) {
      // 비밀번호 변경/강제 로그아웃 등으로 이 RefreshToken 자체가 이미 폐기된 경우.
      return res
        .status(401)
        .json({ error: "세션이 만료되었습니다. 다시 로그인해주세요." });
    }
    // 운영자가 정지시킨 계정은 남아있던 RefreshToken으로도 다시 들어올 수 없어야 한다
    // (정지 시 tokenVersion도 올리지만, 그 전에 발급된 토큰까지 여기서 한 번 더 막는다).
    if (user.suspendedAt || user.deletedAt) {
      return res
        .status(401)
        .json({ error: "세션이 만료되었습니다. 다시 로그인해주세요." });
    }
    // "내 기기"에서 로그아웃시킨 기기의 RefreshToken — 그 기기만 다시 로그인해야 한다.
    if (payload.did && !(await deviceActive(payload.did, user.id))) {
      return res
        .status(401)
        .json({ error: "세션이 만료되었습니다. 다시 로그인해주세요." });
    }
    const authAt = Number.isInteger(payload.aat) ? payload.aat : payload.iat;
    // 회사 계정 쪽에서 로그아웃한(또는 이 앱에서 로그아웃한) 로그인 세션의 토큰.
    if (payload.ssid && !(await ssoSessionActive(payload.ssid, user.id))) {
      return res
        .status(401)
        .json({ error: "회사 계정에서 로그아웃되었습니다. 다시 로그인해 주세요." });
    }
    // 사내 디렉터리 계정 — 퇴사 등으로 디렉터리에서 막혔거나 없어졌으면 여기서 끊는다(10분마다 한 번 확인 — 그때 그룹 규칙도 맞춘다).
    if (user.authSource === "ldap" && !(await directoryAccountActive(user, { io }))) {
      return res
        .status(401)
        .json({ error: "회사 계정을 쓸 수 없습니다. 다시 로그인하거나 관리자에게 문의하세요." });
    }
    // 회사 계정 전용 계정 — 정한 날수가 지나면 회사 계정으로 다시 확인한다(그쪽에서 막힌 퇴사자가 오래 남지 않게).
    if (user.authSource === "sso") {
      const days = (await getServerSettings()).ssoSessionDays ?? 7;
      if (Math.floor(Date.now() / 1000) - authAt > days * 86400) {
        return res
          .status(401)
          .json({ error: "회사 계정으로 다시 로그인해 주세요." });
      }
    }

    res.json({ accessToken: issueTokenPair(user, { deviceId: payload.did, authAt, ssoSessionId: payload.ssid ?? null }).accessToken });
  });

  /**
   * 로그아웃 — 앱이 토큰을 지우기 전에 부른다(AccessToken 또는 본문의 refreshToken). 회사 계정으로 들어온 로그인이면 그 세션을 끝내고
   * (그 세션의 토큰은 바로 못 쓴다), 관리자가 "회사 계정에서도 로그아웃"을 켰으면 브라우저로 열 그쪽 로그아웃 주소(`idpLogoutUrl`)를
   * 돌려준다. 토큰이 이미 만료됐어도 200(앱은 어차피 로그아웃한다).
   */
  router.post("/logout", async (req, res) => {
    let payload = await accessPayload(req);
    if (!payload && typeof req.body?.refreshToken === "string") {
      try {
        const p = jwt.verify(req.body.refreshToken, JWT_SECRET);
        if (p.type === "refresh") payload = p;
      } catch {
        payload = null;
      }
    }
    if (!payload?.ssid) return res.json({ ok: true, idpLogoutUrl: null });
    res.json({ ok: true, idpLogoutUrl: await endSsoLogin(payload.ssid, payload.sub, "app_logout") });
  });

  return router;
}

/**
 * Express용 인증 미들웨어. Authorization: Bearer <token> 헤더를 확인합니다.
 * 매 요청마다 걸리는 경로라 DB 조회 없이 서명/만료(그리고 AccessToken인지)만 검증한다 —
 * tokenVersion 대조는 RefreshToken 재발급 시점(/auth/refresh)과 소켓 연결 시점에만 한다.
 */
export async function requireAuth(req, res, next) {
  const header = req.headers.authorization ?? "";
  if (!header.startsWith("Bearer ")) return res.status(401).json({ error: "토큰이 없습니다." });
  const payload = await accessPayload(req);
  if (!payload) return res.status(401).json({ error: "토큰이 유효하지 않습니다." });
  req.user = payload;
  next();
}

/**
 * 요청의 AccessToken이 지금 쓸 수 있으면 그 내용, 아니면 null — requireAuth와 같은 확인을 미들웨어 없이(로그인 중에도 부르는
 * 경로 — 2단계 인증 켜기 등). 정지·탈퇴·강제 로그아웃·비밀번호 변경(토큰 버전이 오른 것) 뒤의 토큰은 만료 전이라도 바로 막는다
 * (authState.js — 30초 캐시라 요청마다 DB를 읽지는 않는다). 401이면 앱은 RefreshToken으로 갱신을 시도하고, 그것도 같은 이유로
 * 거절되면 로그아웃된다. 기기에 묶인 토큰이면 그 기기가 아직 로그인돼 있는지도 본다("내 기기"에서 로그아웃 — 같은 30초 캐시).
 */
export async function accessPayload(req) {
  const header = req.headers.authorization ?? "";
  const token = header.startsWith("Bearer ") ? header.slice(7) : null;
  if (!token) return null;
  let payload;
  try {
    payload = jwt.verify(token, JWT_SECRET);
    if (payload.type !== "access") return null;
  } catch {
    return null;
  }
  const state = await accountState(payload.sub);
  if (state.blocked || state.tokenVersion !== (payload.tokenVersion ?? 0)) return null;
  if (payload.did && !(await deviceActive(payload.did, payload.sub))) return null;
  if (payload.ssid && !(await ssoSessionActive(payload.ssid, payload.sub))) return null;
  return payload;
}

/** 요청에 유효한 AccessToken이 붙어 있는지만 본다(없거나 틀려도 거절하지 않는 공개 경로용 — /server-info 등). */
export function hasValidAccessToken(req) {
  const header = req.headers.authorization ?? "";
  if (!header.startsWith("Bearer ")) return false;
  try {
    return jwt.verify(header.slice(7), JWT_SECRET).type === "access";
  } catch {
    return false;
  }
}

/**
 * Socket.io 연결 시점에 handshake.auth.token을 확인합니다.
 * 소켓 연결은(매 메시지가 아니라) 앱 시작/재연결 시에만 일어나는 저빈도 경로라, 여기서는
 * tokenVersion까지 DB와 대조해서 비밀번호 변경 직후 캐시된 AccessToken으로 재연결을
 * 시도하는 것까지 막는다.
 */
export async function verifySocketToken(token) {
  const payload = jwt.verify(token, JWT_SECRET); // 서명/만료 실패 시 throw
  if (payload.type !== "access") {
    throw new Error("invalid token type");
  }
  const user = await findUserById(payload.sub);
  if (!user || (user.tokenVersion ?? 0) !== payload.tokenVersion) {
    throw new Error("unauthorized");
  }
  // 정지/탈퇴한 계정은 실시간 연결도 막는다.
  if (user.suspendedAt || user.deletedAt) {
    throw new Error("unauthorized");
  }
  // "내 기기"에서 로그아웃시킨 기기의 토큰.
  if (payload.did && !(await deviceActive(payload.did, user.id))) {
    throw new Error("unauthorized");
  }
  // 회사 계정 쪽에서 로그아웃한 로그인 세션.
  if (payload.ssid && !(await ssoSessionActive(payload.ssid, user.id))) {
    throw new Error("unauthorized");
  }
  return payload;
}
