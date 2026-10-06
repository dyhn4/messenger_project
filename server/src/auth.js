import bcrypt from "bcryptjs";
import { Router } from "express";
import jwt from "jsonwebtoken";
import { AUDIT, recordAudit } from "./audit.js";
import {
  clientIp,
  isLanAddress,
  limits,
  minutesText,
  rateLimit,
  tooMany,
  userKey,
} from "./authGuard.js";
import { JWT_SECRET } from "./config.js";
import { encryptField, lookupHash } from "./crypto.js";
import { PASSWORD_MIN_LENGTH, passwordPolicyError } from "./passwordPolicy.js";
import { accountState } from "./authState.js";
import {
  findUserByEmailLookup,
  findUserById,
  findUserByUsername,
  findUserByUsernameAndEmailLookup,
  hasNoServerAdmin,
  insertUser,
  updateUser,
} from "./db/queries/users.js";
import {
  findTeamInviteLinkByToken,
  isTeamInviteLinkValid,
  consumeTeamInviteLink,
} from "./db/queries/teamInviteLinks.js";
import { findInviteLinkByToken, isInviteLinkValid } from "./db/queries/inviteLinks.js";
import { addTeamMembers } from "./db/queries/teams.js";
import { addRoomMembers, listAutoInviteTopics, listRoomMemberIds } from "./db/queries/rooms.js";
import { findDefaultPositionOption } from "./db/queries/positionOptions.js";
import { notifyMembership, postSystemMessage } from "./rooms.js";
import { announceTeamJoin } from "./selfRoomNotices.js";
import { teamAccess } from "./access.js";
import { canManageTeam, ROLE_RANK } from "./permissions.js";

const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const USERNAME_LENGTH_ERROR = "아이디는 4~20자여야 합니다.";

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

// 없는 아이디로 로그인할 때도 bcrypt 비교 한 번만큼 시간을 쓰게 하는 더미 해시 — 응답 시간
// 차이로 "이 아이디는 있다/없다"를 알아내지 못하게 한다.
const DUMMY_PASSWORD_HASH = bcrypt.hashSync("dummy-password-for-timing", 10);

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
 */
function recoveryGuard(req, res, username) {
  const ip = clientIp(req);
  const external = !isLanAddress(ip);
  const uk = userKey(username);
  const ipUser = `${ip}|${uk}`;
  const wait = Math.max(
    limits.recoveryIpUser.blockedFor(ipUser),
    external ? limits.recoveryUserExternal.blockedFor(uk) : 0,
  );
  if (wait > 0) {
    tooMany(res, wait, "확인 시도");
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
    },
    succeed() {
      limits.recoveryIpUser.reset(ipUser);
    },
  };
}

/**
 * 팀 초대 링크를 만든 사람이 지금도 그 링크를 만들 수 있는 사람인지 — 링크는 7일 동안 살아 있는데, 그 사이 만든 사람이
 * 팀에서 빠지거나 등급이 내려가면 그 사람이 더는 줄 수 없는 팀 합류·등급을 링크가 계속 주게 된다(teamInvites.js의 발급
 * 조건과 같다: 그 팀을 관리할 수 있고, 부여 등급이 자기 등급 이하 — 서버 운영자는 등급 제한 없음).
 */
async function inviteCreatorStillAllowed(link) {
  if (!link?.createdBy) return false;
  const creator = await teamAccess(link.teamId, link.createdBy);
  if (!creator.user || creator.user.deletedAt || creator.user.suspendedAt) return false;
  if (!creator.isMember || !canManageTeam(creator)) return false;
  return creator.isServerAdmin || ROLE_RANK[link.assignedRole] <= ROLE_RANK[creator.role];
}

/** 지금 유효한 초대 링크(팀 초대 또는 설치 초대)의 토큰인지. */
async function isValidInviteToken(token) {
  if (typeof token !== "string" || !token) return false;
  if (isTeamInviteLinkValid(await findTeamInviteLinkByToken(token))) return true;
  return isInviteLinkValid(await findInviteLinkByToken(token));
}

/** 보안 질문이 없는(이 기능 전에 가입한) 계정은 아이디+이메일만으로 재설정되므로 사내망에서만 허용한다. */
const NO_QUESTION_EXTERNAL_ERROR =
  "보안 질문이 등록되지 않은 계정은 사내 와이파이에서만 비밀번호를 재설정할 수 있습니다. 서버 운영자에게 문의하세요.";

export function issueTokenPair(user) {
  const tokenVersion = user.tokenVersion ?? 0;
  const accessToken = jwt.sign(
    { sub: user.id, username: user.username, tokenVersion, type: "access" },
    JWT_SECRET,
    { expiresIn: ACCESS_TOKEN_TTL },
  );
  const refreshToken = jwt.sign(
    { sub: user.id, tokenVersion, type: "refresh" },
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
    const username = req.query.username ?? "";
    if (typeof username !== "string" || username.length < 4 || username.length > 20) {
      return res.json({ available: false, error: USERNAME_LENGTH_ERROR });
    }
    // 사내망 밖에서 초대 링크 없이 묻는 건 어차피 가입할 수 없는 사람이다 — 아이디가 있는지 알려주면 인터넷의
    // 누구나 직원 아이디 목록을 맞혀볼 수 있어서, DB를 보지 않고 "쓸 수 있음"으로만 답한다(실제 가입 때 다시
    // 검사해서 겹치면 그때 알린다). 초대 링크로 열린 앱은 그 토큰(inviteToken)을 같이 보낸다.
    if (!isLanAddress(clientIp(req)) && !(await isValidInviteToken(req.query.inviteToken))) {
      return res.json({ available: true });
    }
    const exists = await findUserByUsername(username);
    if (exists) {
      return res.json({
        available: false,
        error: "이미 사용 중인 아이디입니다.",
      });
    }
    res.json({ available: true });
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
    } = req.body ?? {};
    // 사내망 밖(LTE/5G)에서는 초대 링크(설치 초대·팀 초대)를 받은 사람만 가입할 수 있다 — 공유기
    // 포트를 열면 인터넷 누구나 가입 화면에 닿기 때문이다. 앱은 초대 링크로 열렸거나 "서버 주소
    // 변경"에 초대 코드를 넣어 페어링했을 때 그 코드를 teamInviteToken으로 보낸다.
    if (!isLanAddress(clientIp(req)) && !(await isValidInviteToken(teamInviteToken))) {
      return res.status(403).json({
        error:
          "사내 와이파이 밖에서는 초대 링크로만 가입할 수 있습니다. 초대 링크를 받아 그 코드로 서버에 연결하거나, 사내 와이파이에서 가입하세요.",
      });
    }
    if (!username || !password || !email || !name) {
      return res
        .status(400)
        .json({ error: "아이디, 이름, 비밀번호, 이메일을 입력하세요." });
    }
    if (username.length < 4 || username.length > 20) {
      return res.status(400).json({ error: USERNAME_LENGTH_ERROR });
    }
    const passwordError = passwordPolicyError(password, { username });
    if (passwordError) {
      return res.status(400).json({ error: passwordError });
    }
    if (!EMAIL_PATTERN.test(email)) {
      return res
        .status(400)
        .json({ error: "이메일 형식이 올바르지 않습니다." });
    }
    if (!securityQuestion?.trim() || !securityAnswer?.trim()) {
      return res.status(400).json({ error: "보안 질문과 답변을 입력하세요." });
    }
    // 답이 한 글자면 몇 번 만에 맞혀서 비밀번호를 바꿀 수 있다(사내망 밖에서도 재설정할 수 있어서).
    if (String(securityAnswer).trim().length < 2) {
      return res.status(400).json({ error: "보안 질문 답변은 2자 이상 입력하세요." });
    }

    const exists = await findUserByUsername(username);
    if (exists) {
      return res.status(409).json({ error: "이미 사용 중인 아이디입니다." });
    }
    const emailLookup = lookupHash(email);
    const emailTaken = await findUserByEmailLookup(emailLookup);
    if (emailTaken) {
      return res.status(409).json({ error: "이미 사용 중인 이메일입니다." });
    }

    // 서버가 완전히 비어 있는 상태(첫 가입)라면 그 계정이 서버 운영자가 된다 — 1단계에서
    // 기존 서버의 첫 계정에 표시를 찍은 마이그레이션(0020)과 같은 규칙이고, 이렇게 해야
    // 새로 설치한 서버에서도 아무도 관리자 콘솔에 못 들어가는 상태가 안 생긴다.
    const firstAccount = await hasNoServerAdmin();

    // 직책 목록(관리자 콘솔 "운영 현황")에 "기본값"으로 지정된 직책이 있으면 가입과 동시에
    // 부여한다 — '팀 단위' 서버에서는 이 값이 어디서도 안 쓰이지만(직책은 팀마다 따로 관리),
    // 나중에 '계정 단위'로 바뀌어도 바로 의미가 생기도록 항상 채워 둔다.
    const defaultPosition = await findDefaultPositionOption();

    const user = await insertUser({
      username,
      name: name.trim(),
      // 가입하면 준회원으로 시작한다 — 초대받은 방에서만 활동할 수 있고, 서버 운영자가
      // 관리자 콘솔에서 정회원 이상으로 올려줘야 방을 만들거나 팀을 만들 수 있다.
      // 다만 서버의 첫 계정(=운영자)은 스스로 올려줄 사람이 없으므로 관리자로 시작한다.
      role: firstAccount ? 'admin' : 'guest',
      isServerAdmin: firstAccount,
      position: defaultPosition?.label ?? null,
      emailEnc: encryptField(email),
      emailLookup,
      passwordHash: await bcrypt.hash(password, 10),
      securityQuestion: securityQuestion.trim(),
      securityAnswerHash: await bcrypt.hash(
        normalizeAnswer(securityAnswer),
        10,
      ),
      avatarType: "character",
      avatarEmoji: randomOf(CHARACTER_EMOJIS),
      avatarColor: randomOf(CHARACTER_COLORS),
    });

    // 가입만으로는 어느 팀에도 들어가지 않는다 — 팀은 본인이 직접 만들거나(만든 사람이 그
    // 팀의 소유자가 된다), 소유자/관리자가 팀에 넣어줘야 들어간다(teams.js의 멤버 추가).
    // 공개 토픽 자동 가입도 이제 "서버 전체"가 아니라 "그 팀에 들어올 때" 일어난다.
    //
    // 예외: "팀 초대 링크"로 왔다면 그 팀에 자동으로 합류시키고, 링크에 미리 정해둔 등급을
    // 부여한다(서버 운영자가 일일이 등급을 올려주는 수고를 줄이는 게 이 기능의 목적).
    // 토큰이 있어도 유효하지 않으면(만료·폐기·오타) 조용히 무시한다 — 가입 자체는 원래
    // 초대 없이도 열려 있으므로 가입을 실패시킬 이유가 없다. 서버의 첫 계정(운영자)은 이미
    // role: 'admin'으로 시작하고 팀 개념과 무관하므로 건너뛴다.
    if (!firstAccount && typeof teamInviteToken === "string" && teamInviteToken) {
      const link = await findTeamInviteLinkByToken(teamInviteToken);
      // 자리를 먼저 차지한다(consumeTeamInviteLink) — 인원이 다 찼으면 가입만 되고 팀에는 안 들어간다.
      if (isTeamInviteLinkValid(link) && (await inviteCreatorStillAllowed(link)) && (await consumeTeamInviteLink(link.id))) {
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
    if (typeof email !== "string" || email.length > 200) {
      return res.status(400).json({ error: "이메일을 확인하세요." });
    }
    const user = await findUserByEmailLookup(lookupHash(email));
    if (!user) {
      return res.status(404).json({ error: "일치하는 계정이 없습니다." });
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
    const user = await findUserByUsernameAndEmailLookup(
      username,
      lookupHash(email),
    );
    if (!user) {
      return res
        .status(404)
        .json({ error: "아이디와 이메일이 일치하는 계정이 없습니다." });
    }
    if (!user.securityAnswerHash && !isLanAddress(clientIp(req))) {
      return res.status(403).json({ error: NO_QUESTION_EXTERNAL_ERROR });
    }
    res.json({ question: user.securityQuestion ?? null });
  });

  /**
   * 보안 질문 답변만 검증한다(비밀번호는 바꾸지 않음) — 재설정 화면에서 답변이 맞을
   * 때만 새 비밀번호 입력칸을 보여주기 위해 쓴다. 계정에 보안 질문이 없으면(컬럼 생기기
   * 전 가입) 항상 통과시킨다 — /reset-password의 검증 로직과 동일하게 맞춘다.
   */
  router.post("/verify-security-answer", async (req, res) => {
    const { username, email, securityAnswer } = req.body ?? {};
    const guard = recoveryGuard(req, res, username);
    if (!guard) return;
    const user = await findUserByUsernameAndEmailLookup(
      username,
      lookupHash(email),
    );
    if (!user) {
      guard.fail(null);
      return res
        .status(400)
        .json({ error: "아이디와 이메일이 일치하는 계정이 없습니다." });
    }
    if (user.securityAnswerHash) {
      const matches =
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
  });

  /**
   * 이메일 인증 없이 앱 안에서 바로 비밀번호를 재설정한다 (서버에 메일 발송 기능이 없음).
   * 아이디와 이메일이 둘 다 일치해야 통과하고, 계정에 보안 질문이 설정돼 있으면 그 답변까지
   * 맞아야 한다(이 컬럼이 생기기 전 가입한 계정은 답변 확인을 건너뛴다).
   */
  router.post("/reset-password", async (req, res) => {
    const { username, email, securityAnswer, newPassword } = req.body ?? {};
    const passwordError = passwordPolicyError(newPassword, { username });
    if (passwordError) {
      return res.status(400).json({ error: passwordError });
    }

    const guard = recoveryGuard(req, res, username);
    if (!guard) return;
    const user = await findUserByUsernameAndEmailLookup(
      username,
      lookupHash(email),
    );
    if (!user) {
      guard.fail(null);
      return res
        .status(400)
        .json({ error: "아이디와 이메일이 일치하는 계정이 없습니다." });
    }
    if (user.securityAnswerHash) {
      const matches =
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

    // 비밀번호가 바뀌었으니 이전에 발급된 모든 토큰을 무효화한다: AccessToken은 남은
    // 유효기간(최대 1시간) 뒤에, RefreshToken은 즉시(다음 재발급 시도부터) 막히고,
    // 지금 연결돼있는 소켓도 바로 끊어서 실시간 세션도 함께 정리한다.
    await updateUser(user.id, {
      passwordHash: await bcrypt.hash(newPassword, 10),
      tokenVersion: (user.tokenVersion ?? 0) + 1,
    });
    io.in(`user:${user.id}`).disconnectSockets(true);

    res.json({ ok: true });
  });

  router.post("/login", async (req, res) => {
    const { username, password } = req.body ?? {};
    // 아이디·비밀번호 칸 길이(20자)를 한참 넘는 값은 바로 거절한다 — 제한 기록의 키로 쓰이므로, 아주 긴 값을
    // 계속 바꿔 보내 서버 메모리를 채우는 걸 막는다.
    if (typeof username !== "string" || username.length > 64 || (password != null && String(password).length > 200)) {
      return res.status(400).json({ error: "아이디 또는 비밀번호가 올바르지 않습니다." });
    }
    // 무차별 대입 방어(authGuard.js) — 같은 IP·아이디, 같은 IP(여러 아이디), 사내망 밖에서
    // 한 아이디, 사내망 밖 전체 네 갈래로 센다. 막혀 있는 동안은 비밀번호가 맞아도 들여보내지 않는다.
    const ip = clientIp(req);
    const external = !isLanAddress(ip);
    const uk = userKey(username);
    const ipUser = `${ip}|${uk}`;
    const wait = Math.max(
      limits.loginIpUser.blockedFor(ipUser),
      limits.loginIp.blockedFor(ip),
      external ? limits.loginUserExternal.blockedFor(uk) : 0,
      external ? limits.loginExternalGlobal.blockedFor("all") : 0,
    );
    if (wait > 0) return tooMany(res, wait, "로그인 시도");

    const user = await findUserByUsername(username);
    const passwordOk = await bcrypt.compare(
      String(password ?? ""),
      user?.passwordHash ?? DUMMY_PASSWORD_HASH,
    );
    if (!user || !passwordOk) {
      if (limits.loginIpUser.fail(ipUser)) {
        reportLockout({ ip, username: uk, user, detail: `비밀번호 5회 오류 — 이 IP에서 이 아이디 ${minutesText(limits.loginIpUser.blockMs)} 로그인 차단` });
      }
      if (limits.loginIp.fail(ip)) {
        reportLockout({ ip, username: uk, user, detail: `한 IP에서 여러 아이디로 비밀번호 20회 오류 — 이 IP ${minutesText(limits.loginIp.blockMs)} 로그인 차단` });
      }
      if (external && limits.loginUserExternal.fail(uk)) {
        reportLockout({ ip, username: uk, user, detail: `사내망 밖에서 이 아이디로 비밀번호 20회 오류 — 밖에서는 ${minutesText(limits.loginUserExternal.blockMs)} 로그인 차단(사내에서는 가능)` });
      }
      if (external && limits.loginExternalGlobal.fail("all")) {
        reportLockout({ ip, username: uk, user: null, detail: `사내망 밖 전체에서 비밀번호 오류가 15분에 300회를 넘음(여러 IP의 대입 공격 의심) — 밖에서의 로그인 ${minutesText(limits.loginExternalGlobal.blockMs)} 전부 차단(사내에서는 가능)` });
      }
      return res
        .status(401)
        .json({ error: "아이디 또는 비밀번호가 올바르지 않습니다." });
    }
    limits.loginIpUser.reset(ipUser);
    if (user.deletedAt) {
      return res.status(403).json({ error: "탈퇴한 계정입니다." });
    }
    if (user.suspendedAt) {
      return res
        .status(403)
        .json({ error: "정지된 계정입니다. 서버 운영자에게 문의하세요." });
    }
    // 최소 길이를 8자로 올리기 전에 정한 짧은 비밀번호는 사내에서만 받는다 — 밖에서는 맞히기 너무 쉽다.
    if (external && String(password).length < PASSWORD_MIN_LENGTH) {
      return res.status(403).json({
        error: `비밀번호가 ${PASSWORD_MIN_LENGTH}자보다 짧아 사내망 밖에서는 로그인할 수 없습니다. 사내에서 로그인해 비밀번호를 바꾼 뒤 다시 시도하세요.`,
      });
    }

    res.json({
      ...issueTokenPair(user),
      userId: user.id,
      username: user.username,
    });
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

    res.json({ accessToken: issueTokenPair(user).accessToken });
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
  const token = header.startsWith("Bearer ") ? header.slice(7) : null;
  if (!token) return res.status(401).json({ error: "토큰이 없습니다." });

  let payload;
  try {
    payload = jwt.verify(token, JWT_SECRET);
    if (payload.type !== "access") throw new Error("invalid token type");
  } catch {
    return res.status(401).json({ error: "토큰이 유효하지 않습니다." });
  }
  // 정지·탈퇴·강제 로그아웃·비밀번호 변경(토큰 버전이 오른 것) 뒤의 토큰은 만료 전이라도 바로 막는다(authState.js —
  // 30초 캐시라 요청마다 DB를 읽지는 않는다). 401이면 앱은 RefreshToken으로 갱신을 시도하고, 그것도 같은 이유로
  // 거절되면 로그아웃된다.
  const state = await accountState(payload.sub);
  if (state.blocked || state.tokenVersion !== (payload.tokenVersion ?? 0)) {
    return res.status(401).json({ error: "토큰이 유효하지 않습니다." });
  }
  req.user = payload;
  next();
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
  return payload;
}
