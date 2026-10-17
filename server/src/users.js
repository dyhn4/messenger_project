import bcrypt from 'bcryptjs';
import { Router } from 'express';
import { issueTokenPair } from './auth.js';
import { limits, retryLater, runReauthAttempt, waitText } from './authGuard.js';
import { checkEmailCode, consumeEmailCode, issueEmailCode } from './emailCodes.js';
import { sendMail } from './mailer.js';
import { mailReady, maskEmail } from './mailRules.js';
import { emailChangedMail } from './mailTemplates.js';
import { passwordPolicyError } from './passwordPolicy.js';
import { decryptField, encryptField, lookupHash } from './crypto.js';
import { renameSenderMessages } from './db/queries/messages.js';
import {
  findOtherUserByEmailLookup,
  findUserById,
  listActiveUsers,
  listActiveUsersByIds,
  updateUser,
  updateUserUnlessLastServerAdmin,
} from './db/queries/users.js';
import { findTeamMember, listCoTeamMemberIds, listTeamIdsForUser, listTeamsForUser } from './db/queries/teams.js';
import { clearTopicAdminRoles } from './db/queries/rooms.js';
import { deleteScheduledMessagesForUser } from './db/queries/scheduledMessages.js';
import { listPositionOptions } from './db/queries/positionOptions.js';
import { findStickerWithPack } from './db/queries/stickers.js';
import { findUploaders } from './db/queries/uploads.js';
import { clearPushTargetsForUser } from './db/queries/devices.js';
import { isOnline } from './presence.js';
import { accountRole, canCreateProject, canCreateTeamInviteLink } from './permissions.js';
import { getServerSettings } from './db/queries/serverSettings.js';
import { broadcastMemberUpdate } from './rooms.js';
import { notifyBirthdayChanged } from './calendars.js';
import { endUserCallAccess } from './callAccess.js';
import { ownedUploadClaims, signFileUrl, uploadFileNameOf } from './upload.js';
import { AVATAR_PHOTO_ERROR, parseUserName, planAvatarUpdate, safeAvatarColor } from './avatarRules.js';
import { canSeeUser, directoryUserIds, seesWholeDirectory } from './userDirectory.js';
import { dndDto, parseDndInput, parseStatusInput, statusDto } from './statusRules.js';

const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
// 이메일 칸 길이 상한 — 가입·아이디 찾기(auth.js EMAIL_MAX_LENGTH)와 같다. 예전엔 바꿀 때만 길이를 안 봐서, 로그인한 사람이 본문
// 상한(bodyLimit.js)만큼 긴 값을 이메일로 저장할 수 있었다(그러면 아이디 찾기도 그 이메일로는 안 된다).
const EMAIL_MAX_LENGTH = 200;
export const DELETED_USER_NAME = '탈퇴한 사용자';

/**
 * 다른 사람에게 내려줘도 되는 사용자 정보 — 비밀번호는 물론 이메일·생일도 뺀다. 이메일은 아이디·비밀번호
 * 찾기에 쓰는 값이라 남에게 보이면 계정을 노리는 발판이 되고(전체 회원 목록 GET /users로 서버의 모든
 * 이메일이 새던 문제), 생일은 캘린더가 팀 단위로 따로 받는다(calendars.js의 listTeamBirthdays). 본인 것은
 * [selfUser]로 내려준다.
 *
 * 아바타 칸은 내보낼 때 한 번 더 거른다(avatarRules.js) — 배경색은 앱이 그릴 수 있는 '#RRGGBB'만(검사가 생기기 전에 저장된
 * 이상한 값 하나로 이 사람을 그리는 다른 사람 화면이 깨지지 않게), 사진 링크는 아바타가 사진일 때만(사진이 아닌 아바타에 남은
 * 경로까지 매번 새 다운로드 링크로 서명해 주지 않게 — 앱도 사진일 때만 그 링크를 쓴다).
 */
export function publicUser(u) {
  return {
    id: u.id,
    username: u.username,
    name: u.name ?? u.username,
    avatarType: u.avatarType ?? 'initial',
    avatarEmoji: u.avatarEmoji ?? null,
    avatarColor: safeAvatarColor(u.avatarColor),
    avatarUrl: u.avatarType === 'photo' ? (signFileUrl(u.avatarUrl) ?? null) : null,
    online: isOnline(u.id),
    // 계정 등급 — 팀 설정의 "팀원 추가"나 조직도에서 등급을 보여주는 데 쓴다.
    // 바꾸는 것은 서버 운영자만 가능하다(admin.js).
    role: accountRole(u),
    // 상태 메시지 { emoji, text, until } — 없거나 지울 시각이 지났으면 null(statusRules.js).
    status: statusDto(u, Date.now()),
    // 방해 금지 { until, schedule } — 꺼져 있으면 null. 앱이 지금 방해 금지 중인지를 같은 규칙으로 계산해 🌙로 보인다.
    dnd: dndDto(u, Date.now()),
  };
}

/**
 * 상태 메시지·방해 금지가 바뀌었음을 그 사람과 팀을 같이 쓰는 사람들(접속 표시와 같은 범위 — presence.js)과 내 다른 기기에
 * 알린다(user:status). 프로필 변경처럼 방 목록을 통째로 다시 보내지 않고(broadcastMemberUpdate) 이 두 값만 보낸다 — 상태는
 * 하루에도 여러 번 바뀐다.
 */
async function broadcastStatus(io, user) {
  const ids = new Set(await listCoTeamMemberIds(user.id));
  ids.add(user.id);
  const now = Date.now();
  io.to([...ids].map((id) => `user:${id}`)).emit('user:status', {
    userId: user.id,
    status: statusDto(user, now),
    dnd: dndDto(user, now),
  });
}

/**
 * 본인 프로필(GET/PATCH /users/me 등) — [publicUser]에 본인만 보는 이메일·이메일 확인 여부와 생일('MM-DD', 없으면 null)을
 * 더한다. emailVerified는 메일이 켜진 서버에서 앱이 "이메일을 확인하세요"를 띄울지 정하는 데 쓴다.
 */
export function selfUser(u) {
  return {
    ...publicUser(u),
    email: u.emailEnc ? decryptField(u.emailEnc) : null,
    emailVerified: !!u.emailEnc && !!u.emailVerifiedAt,
    birthday: u.birthday ?? null,
  };
}

/** 로그인한 사람이 메일(확인 코드)을 요청할 때의 계정 단위 제한 — 막혔으면 429를 보내고 true. */
function mailUserLimited(res, userId) {
  const wait = limits.mailSendUser.hit(userId);
  if (wait <= 0) return false;
  retryLater(res, wait, `메일을 너무 많이 요청했습니다. ${waitText(wait)} 뒤에 다시 시도하세요.`);
  return true;
}

/**
 * 프로필의 생일 값 검사 — 'MM-DD'(연도 없음)만 받고, 없는 날짜는 거절한다(2월 29일은 윤년 생일이라 허용).
 * null/빈 문자열은 삭제. 통과하면 `{ value }`(삭제면 null), 아니면 `{ error }`.
 */
export function parseBirthday(raw) {
  if (raw === null || raw === '') return { value: null };
  if (typeof raw !== 'string') return { error: '생일 형식이 올바르지 않습니다.' };
  const match = /^(\d{2})-(\d{2})$/.exec(raw.trim());
  if (!match) return { error: '생일은 MM-DD 형식으로 입력하세요.' };
  const month = Number(match[1]);
  const day = Number(match[2]);
  // 2024는 윤년이라 2월 29일까지 유효한 날짜로 본다.
  const probe = new Date(Date.UTC(2024, month - 1, day));
  if (month < 1 || month > 12 || day < 1 || probe.getUTCMonth() !== month - 1) {
    return { error: '존재하지 않는 날짜입니다.' };
  }
  return { value: `${match[1]}-${match[2]}` };
}

/** GET /users/:id/teams용 최소 팀 DTO — 클라이언트의 Team.fromJson과 필드를 맞추되(그래야
 * 재사용할 수 있다), isOwner/memberCount처럼 "그 팀 안에서"만 의미 있는 값은 이 목록 성격상
 * 필요 없어 기본값으로 채운다. */
function toTeamRefDto(team) {
  return {
    id: team.id,
    name: team.name,
    iconEmoji: team.iconEmoji ?? null,
    iconColor: team.iconColor ?? null,
    iconUrl: signFileUrl(team.iconUrl) ?? null,
    topicCreationPolicy: team.topicCreationPolicy ?? 'member',
    topicCreatorIds: [],
    messageEditDeleteEnabled: team.messageEditDeleteEnabled !== false,
    messageEditDeleteWindowSeconds: team.messageEditDeleteWindowSeconds ?? 300,
    createdBy: team.createdBy ?? null,
    createdAt: new Date(team.createdAt).getTime(),
    isOwner: false,
    memberCount: null,
  };
}

/**
 * 내 프로필 카드의 "팀"/"직책" 표시용 값 — orgScope(팀 단위/계정 단위)에 따라 저장 위치가
 * 달라서, 클라이언트가 분기하지 않아도 되도록 서버가 미리 정리해서 내려준다. 계정 단위면
 * 값이 하나뿐이라 department/position에 바로 담고, 팀 단위면 사람이 여러 팀에 속해 있고
 * 팀마다 부서/직책이 다를 수 있어 teamPositions 배열(팀별 한 행씩)로 담는다.
 */
async function myOrgInfo(user, settings) {
  if (settings.orgScope === 'account') {
    return {
      orgScope: 'account',
      department: user.department ?? null,
      position: user.position ?? null,
      teamPositions: [],
    };
  }
  const rows = await listTeamsForUser(user.id);
  const teamPositions = await Promise.all(
    rows.map(async ({ team }) => {
      const member = await findTeamMember(team.id, user.id);
      return {
        teamId: team.id,
        teamName: team.name,
        department: member?.department ?? null,
        position: member?.position ?? null,
      };
    }),
  );
  return { orgScope: 'team', department: null, position: null, teamPositions };
}

/**
 * 로그인한 상태에서 현재 비밀번호를 다시 확인한다(화면 잠금 해제·이메일 변경·비밀번호 변경·탈퇴).
 * 훔친 토큰으로 비밀번호를 맞혀보는 걸 막으려고 틀린 횟수를 센다(authGuard.js runReauthAttempt — 10번 틀리면
 * 15분). 확인(bcrypt)을 시작할 때 "확인 중"으로 함께 세서, 요청을 한꺼번에 보내도 그보다 많이 맞춰 보지 못한다(예전엔
 * bcrypt가 끝난 뒤에야 세서 동시에 보낸 만큼 맞춰 볼 수 있었다). 막혔거나 틀렸으면 응답을 보내고 false.
 * 관리자 콘솔의 백업 암호·외부 백업 위치 변경도 이것으로 운영자 비밀번호를 다시 확인한다(admin.js).
 */
export async function checkCurrentPassword(res, user, password, wrongMessage) {
  const result = await runReauthAttempt({
    key: user.id,
    password,
    checkPassword: (plain) => bcrypt.compare(plain, user.passwordHash),
  });
  if (result.wait) {
    retryLater(res, result.wait, result.error);
    return false;
  }
  if (!result.ok) {
    // 401이 아니라 403 — 앱은 401을 "토큰이 만료됐다"로 보고 토큰을 새로 받아 같은 요청을 한 번 더 보내서(api_client.dart _send),
    // 비밀번호를 한 번 잘못 쳐도 두 번 틀린 것으로 세어져 실제 사용자가 절반만 틀려도 잠겼다. 앱은 상태 코드와 상관없이 이 문구를
    // 그대로 보여 준다(예전 앱도 같다).
    res.status(403).json({ error: wrongMessage });
    return false;
  }
  return true;
}

/** io를 캡처해 프로필(이름/이메일/아바타)이 바뀌면 이 사람이 속한 모든 방에 최신 멤버
 * 정보를 브로드캐스트한다 — 안 그러면 다른 기기/다른 사람 화면의 방 목록·채팅방 제목이
 * 예전 이름/아바타로 남아있게 된다. */
export function createUsersRouter(io) {
  const router = Router();

  /**
   * [me]가 회원 목록·프로필에서 볼 수 있는 계정 id(Set) — 서버 전체를 보는 사람(계정 등급 관리자·서버 운영자)이면 null(제한 없음),
   * 그 밖에는 팀을 하나라도 같이 쓰는 사람과 자기 자신(userDirectory.js).
   */
  async function visibleUserIds(me) {
    if (seesWholeDirectory(me)) return null;
    return directoryUserIds(me.id, await listCoTeamMemberIds(me.id));
  }

  /**
   * 회원 목록. 탈퇴한 사용자는 로그인도 못 하고 새로 대화를 걸 수도 없으니 여기서 뺀다 — 다만 예전에
   * 같이 있던 방의 멤버 목록/과거 메시지 작성자 표시(publicUser 자체)에서는 계속 "탈퇴한 사용자"로
   * 보여야 하므로 그쪽(rooms.js의 listRoomMemberUsers 등)은 건드리지 않는다.
   *
   * 누구에게 얼마나 보여 줄지는 userDirectory.js — 계정 등급 관리자와 서버 운영자는 서버 전체(조직도의
   * "미소속" 회원까지), 그 밖에는 팀을 같이 쓰는 사람과 자기 자신만이다. 예전엔 로그인한 누구에게나
   * (팀이 없는 준회원에게도) 서버 전체 회원의 아이디·등급·접속 상태를 줬다. 앱은 이 목록을 조직도
   * (관리자 이상 전용)와 처음 접속 상태 채우기(같은 팀 사람만 의미가 있다)에만 쓴다 — 팀원 추가 후보는
   * 아직 그 팀에 없는 사람이라 따로 받는다(teams.js GET /teams/:id/member-candidates). 이 변경 전의 앱은 팀원
   * 추가 후보도 이 목록에서 골랐다 — 그 앱에서는 관리자 이상이 아닌 소유자에게 팀을 같이 쓰는 사람만 후보로
   * 보이고 팀 밖 사람을 찾을 방법이 없으니, 서버와 함께 앱(웹 앱 포함)도 새 버전으로 올려야 한다.
   *
   * 아이디(username)는 준회원에게도 그대로 싣는다: 이 목록이 팀을 같이 쓰는 사람으로 좁혀졌고, 그 사람들의
   * 아이디는 팀 멤버 목록(GET /teams/:id/members)·방 멤버 목록에도 이미 실려 있어(멘션 자동완성이 아이디로도
   * 찾는다) 여기서만 빼도 더 막히는 것이 없다 — 앱의 AppUser도 아이디를 꼭 받아야 읽힌다.
   *
   * 직책(position)은 이 목록이 "특정 팀 안"이 아니라 여러 팀을 훑는 목록이라, 팀마다 다를
   * 수 있는 값(orgScope='team')은 하나로 못 정해서 뺀다 — 계정 단위로 관리하는 서버
   * (orgScope='account')일 때만, 사람마다 값이 하나뿐이니 그대로 실어준다(조직도 "멤버" 탭이
   * 이 값을 쓴다).
   */
  router.get('/users', async (req, res) => {
    const me = await findUserById(req.user.sub);
    if (!me) return res.status(404).json({ error: '사용자를 찾을 수 없습니다.' });
    const settings = await getServerSettings();
    const visible = await visibleUserIds(me);
    const users = visible === null ? await listActiveUsers() : await listActiveUsersByIds([...visible]);
    res.json(
      users.map((u) => ({
        ...publicUser(u),
        position: settings.orgScope === 'account' ? (u.position ?? null) : null,
      })),
    );
  });

  /** 직책 목록(서열순) — 관리자 콘솔의 '직책 목록' 관리(admin.js)와 달리 서버 운영자가
   * 아니어도 누구나 읽을 수 있다. "팀 초대 링크 만들기"가 "부여할 직책"을 고르는 데 쓴다. */
  router.get('/position-options', async (req, res) => {
    res.json(await listPositionOptions());
  });

  /**
   * 이 사람이 속한 팀들 — 프로필 카드의 "팀" 항목이 쓴다. 먼저 그 사람을 볼 수 있어야 한다(회원 목록과
   * 같은 범위 — 본인, 팀을 같이 쓰는 사람, 그리고 계정 등급 관리자·서버 운영자는 누구든). 못 보는 사람이면
   * 없는 사람과 같게 404로 답한다(예전엔 id만 알면 누구의 소속 팀이든 볼 수 있었다). 볼 수 있으면 남의 것은
   * 노출 범위를 다르게 둔다: 대상이 계정 등급 관리자면 관리자는 보통 여러 팀에 걸쳐 있어서 나와 겹치는
   * 팀만(내가 이미 알 수 있는 관계로 제한), 정회원·준회원이면 소속이 단순해서 전체를 그대로
   * 보여준다. "조직도"(관리자 이상 전용, GET /org-chart/teams)와 달리 이건 누구나 호출할 수
   * 있는 대신, 위 규칙으로 노출 범위를 스스로 제한한다.
   */
  router.get('/users/:id/teams', async (req, res) => {
    const target = await findUserById(req.params.id);
    if (!target || target.deletedAt) return res.status(404).json({ error: '사용자를 찾을 수 없습니다.' });
    if (target.id !== req.user.sub) {
      const me = await findUserById(req.user.sub);
      if (!me || !canSeeUser(await visibleUserIds(me), target.id)) {
        return res.status(404).json({ error: '사용자를 찾을 수 없습니다.' });
      }
    }

    const targetRows = await listTeamsForUser(target.id);
    let visibleTeams = targetRows.map((r) => r.team);
    if (target.id !== req.user.sub && accountRole(target) === 'admin') {
      const myTeamIds = new Set(await listTeamIdsForUser(req.user.sub));
      visibleTeams = visibleTeams.filter((team) => myTeamIds.has(team.id));
    }
    res.json(visibleTeams.map(toTeamRefDto));
  });

  /** 내 프로필(아바타 포함) 조회. 내 화면에서만 쓰는 값이라 서버 운영자 여부도 여기 실어준다
   * (다른 사람의 publicUser에는 넣지 않는다 — 누가 운영자인지는 관리자 콘솔에서만 본다). */
  router.get('/users/me', async (req, res) => {
    const user = await findUserById(req.user.sub);
    if (!user) return res.status(404).json({ error: '사용자를 찾을 수 없습니다.' });
    // "팀 초대 링크 생성" 메뉴를 보여줄지는 서버 설정(팀 초대 링크 생성 권한)에 달려 있어서
    // 클라이언트가 로컬 상태만으로 판단할 수 없다 — 여기서 서버가 최종 판정해서 내려준다
    // (실제로 만들 때는 teamInvites.js가 매 요청마다 다시 확인한다, 이건 화면 표시용).
    const settings = await getServerSettings();
    const orgInfo = await myOrgInfo(user, settings);
    res.json({
      ...selfUser(user),
      isServerAdmin: !!user.isServerAdmin,
      canCreateTeamInviteLink: canCreateTeamInviteLink({
        role: accountRole(user),
        isServerAdmin: !!user.isServerAdmin,
        teamInviteLinkCreation: settings.teamInviteLinkCreation,
      }),
      // "프로젝트" 창의 "+새 프로젝트" 버튼을 보여줄지 — 서버 설정(프로젝트 생성 권한)에
      // 달려 있어서 클라이언트가 자기 등급만으로는 판단할 수 없다(실제 생성 때 projects.js가
      // 다시 확인한다, 이건 화면 표시용).
      canCreateProject: canCreateProject({
        role: accountRole(user),
        isServerAdmin: !!user.isServerAdmin,
        projectCreation: settings.projectCreation,
      }),
      ...orgInfo,
    });
  });

  /**
   * 현재 비밀번호가 맞는지만 확인한다(다른 부수효과 없음) — "이메일 변경" 흐름이 1단계
   * (비밀번호 확인)와 2단계(새 이메일 입력)로 나뉘어 있어서, 1단계에서 바로 맞고 틀림을
   * 알려주는 데 쓴다. 실제 이메일 변경은 여전히 PATCH /users/me가 currentPassword를 같이
   * 받아 한 번 더 검증한다(이 확인은 UX용이지 그 자체로 인증서가 되는 건 아니다).
   */
  router.post('/users/me/verify-password', async (req, res) => {
    const user = await findUserById(req.user.sub);
    if (!user) return res.status(404).json({ error: '사용자를 찾을 수 없습니다.' });
    const { password } = req.body ?? {};
    if (!(await checkCurrentPassword(res, user, password, '비밀번호가 올바르지 않습니다.'))) return;
    res.json({ ok: true });
  });

  /**
   * 이메일 확인 코드 보내기(메일이 켜진 서버에서만). [email]이 없으면 지금 이메일을 확인하는 코드('verify')를 지금 주소로,
   * 있으면 그 주소로 바꾸려는 코드('change')를 새 주소로 보낸다 — 바꾸는 쪽은 현재 비밀번호를 같이 받는다(이메일 변경과 같은
   * 정책). 실제 확인은 POST /users/me/email/verify, 변경은 PATCH /users/me(emailCode).
   */
  router.post('/users/me/email/send-code', async (req, res) => {
    const user = await findUserById(req.user.sub);
    if (!user) return res.status(404).json({ error: '사용자를 찾을 수 없습니다.' });
    if (!mailReady(await getServerSettings())) return res.status(409).json({ error: '이 서버는 메일 기능이 꺼져 있습니다.' });
    const { email, currentPassword } = req.body ?? {};
    if (email === undefined || email === null) {
      if (!user.emailEnc) return res.status(400).json({ error: '등록된 이메일이 없습니다. 먼저 이메일을 등록하세요.' });
      if (user.emailVerifiedAt) return res.status(409).json({ error: '이미 확인된 이메일입니다.' });
      if (mailUserLimited(res, user.id)) return;
      const address = decryptField(user.emailEnc);
      const sent = await issueEmailCode(res, { purpose: 'verify', email: address, userId: user.id });
      if (sent) res.json({ ...sent, email: maskEmail(address) });
      return;
    }
    if (!(await checkCurrentPassword(res, user, currentPassword, '현재 비밀번호가 올바르지 않습니다.'))) return;
    if (typeof email !== 'string' || email.length > EMAIL_MAX_LENGTH || !EMAIL_PATTERN.test(email)) {
      return res.status(400).json({ error: '이메일 형식이 올바르지 않습니다.' });
    }
    const emailLookup = lookupHash(email);
    if (await findOtherUserByEmailLookup(emailLookup, user.id)) {
      return res.status(409).json({ error: '이미 사용 중인 이메일입니다.' });
    }
    if (mailUserLimited(res, user.id)) return;
    const sent = await issueEmailCode(res, { purpose: 'change', email, userId: user.id, emailEnc: encryptField(email) });
    if (sent) res.json({ ...sent, email: maskEmail(email) });
  });

  /** 지금 이메일로 받은 확인 코드('verify')를 넣어 이메일을 확인한다 — 확인되면 비밀번호·아이디를 메일로 찾는다. */
  router.post('/users/me/email/verify', async (req, res) => {
    const user = await findUserById(req.user.sub);
    if (!user) return res.status(404).json({ error: '사용자를 찾을 수 없습니다.' });
    if (!user.emailEnc) return res.status(400).json({ error: '등록된 이메일이 없습니다.' });
    if (user.emailVerifiedAt) return res.json(selfUser(user));
    const checked = await checkEmailCode({
      purpose: 'verify',
      email: decryptField(user.emailEnc),
      userId: user.id,
      code: req.body?.code,
    });
    if (!checked.ok) return res.status(400).json({ error: checked.error });
    await consumeEmailCode(checked.row);
    res.json(selfUser(await updateUser(user.id, { emailVerifiedAt: new Date() })));
  });

  /**
   * 내 프로필 갱신. avatarType이 오면 아바타 상태를 통째로 바꾸고(초기화/캐릭터 선택/사진
   * 업로드가 서로 다른 필드 조합을 쓰므로 부분 수정 대신 전체 교체), name/email은 각각
   * 왔을 때만 독립적으로 갱신한다.
   *
   * 아바타·이름 값 검사는 avatarRules.js — 예전엔 보낸 그대로 저장해서, 남이 올린 파일 경로를 프로필 사진으로
   * 걸어 두면 내 프로필이 그 파일의 새 다운로드 링크를 계속 실어 줬다. 이제 새 프로필 사진은 내가 올린 파일
   * (uploads 표)이어야 하고, 지금 쓰는 사진을 다시 보내는 것만 그대로 둔다.
   */
  router.patch('/users/me', async (req, res) => {
    const user = await findUserById(req.user.sub);
    if (!user) return res.status(404).json({ error: '사용자를 찾을 수 없습니다.' });

    const { avatarType, name, email, currentPassword, birthday, emailCode } = req.body ?? {};
    const patch = {};
    // 이메일을 바꿀 때 메일이 켜진 서버면 새 주소로 받은 코드가 맞아야 한다(POST /users/me/email/send-code) — 바꾼 뒤에 쓴다.
    let changeCode = null;
    let previousVerifiedEmail = null;

    if (avatarType !== undefined) {
      const avatar = planAvatarUpdate(req.body, {
        currentAvatarUrl: user.avatarType === 'photo' ? user.avatarUrl : null,
      });
      if (avatar.error) return res.status(400).json({ error: avatar.error });
      if (avatar.uploadToVerify) {
        // 새 사진은 내가 POST /upload로 올린 파일이어야 한다(그 기록이 uploads 표에 남는다 — upload.js).
        const uploaders = await findUploaders([uploadFileNameOf(avatar.uploadToVerify)]);
        const owned = ownedUploadClaims([{ path: avatar.uploadToVerify, ownerId: user.id }], uploaders);
        if (owned.length === 0) return res.status(400).json({ error: AVATAR_PHOTO_ERROR });
      }
      Object.assign(patch, avatar.patch);
    }

    if (name !== undefined) {
      const parsed = parseUserName(name);
      if (parsed.error) return res.status(400).json({ error: parsed.error });
      patch.name = parsed.value;
    }

    if (birthday !== undefined) {
      const parsed = parseBirthday(birthday);
      if (parsed.error) return res.status(400).json({ error: parsed.error });
      patch.birthday = parsed.value;
    }

    if (email !== undefined) {
      // 이메일은 아이디/비밀번호 찾기에 쓰이는 계정 복구 수단이라, 이름/아바타와 달리
      // 현재 비밀번호로 본인 확인을 한 번 더 받는다(비밀번호 변경과 같은 정책).
      if (!(await checkCurrentPassword(res, user, currentPassword, '현재 비밀번호가 올바르지 않습니다.'))) return;
      // 문자열이 아닌 값도 형식 오류로 — ['a@b.c'] 같은 배열은 정규식을 통과해서, 예전엔 그 글자 모양('a@b.c')으로 저장됐다.
      if (typeof email !== 'string' || email.length > EMAIL_MAX_LENGTH || !EMAIL_PATTERN.test(email)) {
        return res.status(400).json({ error: '이메일 형식이 올바르지 않습니다.' });
      }
      const emailLookup = lookupHash(email);
      const taken = await findOtherUserByEmailLookup(emailLookup, user.id);
      if (taken) {
        return res.status(409).json({ error: '이미 사용 중인 이메일입니다.' });
      }
      patch.emailEnc = encryptField(email);
      patch.emailLookup = emailLookup;
      // 메일이 켜진 서버는 새 주소로 받은 코드로 확인된 주소만 받는다(그러면 바로 "확인됨"). 꺼진 서버는 예전처럼 바로 바꾸고,
      // 새 주소는 아직 확인 전이다 — 나중에 메일이 켜지면 확인을 권한다.
      if (mailReady(await getServerSettings())) {
        if (typeof emailCode !== 'string' || !emailCode) {
          return res.status(400).json({ error: '새 이메일로 받은 확인 코드를 넣으세요.' });
        }
        const checked = await checkEmailCode({ purpose: 'change', email, userId: user.id, code: emailCode });
        if (!checked.ok) return res.status(400).json({ error: checked.error });
        changeCode = checked.row;
        patch.emailVerifiedAt = new Date();
        if (user.emailVerifiedAt && user.emailEnc && user.emailLookup !== emailLookup) {
          previousVerifiedEmail = decryptField(user.emailEnc);
        }
      } else {
        patch.emailVerifiedAt = user.emailLookup === emailLookup ? user.emailVerifiedAt : null;
      }
    }

    if (changeCode && !(await consumeEmailCode(changeCode))) {
      return res.status(400).json({ error: '확인 코드가 없거나 만료되었습니다. 코드를 다시 받으세요.' });
    }
    const updated = await updateUser(user.id, patch);
    // 확인된 예전 주소로 "이메일이 바뀌었다"고 알린다 — 남이 바꿨을 때 알아챌 수 있게. 못 보내도 변경은 그대로다.
    if (previousVerifiedEmail) {
      sendMail(previousVerifiedEmail, emailChangedMail(maskEmail(email))).catch(() => {});
    }

    // 생일이 바뀌면 팀원들의 캘린더(멤버 생일)를 새로 고치게 알린다.
    if (patch.birthday !== undefined && patch.birthday !== (user.birthday ?? null)) {
      await notifyBirthdayChanged(io, user.id);
    }

    // 이 사람이 속한 모든 방(다른 기기 포함, 그 방의 멤버 전원)에 갱신된 멤버 정보를 알린다.
    await broadcastMemberUpdate(io, user.id);

    res.json(selfUser(updated));
  });

  /**
   * 서버 운영자가 올린 "캐릭터" 세트(stickers.js, kind:'character')에서 그림 하나를 내 프로필
   * 사진으로 고른다. 실제로는 "사진 올리기"와 똑같이 avatarType:'photo' + avatarUrl만 바꾸는
   * 것이라(렌더링 쪽은 손댈 필요가 없다 — publicUser가 매번 새로 서명해서 내려준다) 그 캐릭터
   * 그림의 원본 경로(avatarUrl과 같은 미서명 /uploads/ 형식 — stickers.js의 fileUrl)를 그대로
   * 복사해 넣는다. 세트가 나중에 숨겨지거나 삭제돼도, 이미 고른 사람의 프로필 사진은 독립된
   * 값이라 그대로 남는다(파일 자체를 지우지 않는 한 — 세트 삭제도 소프트 삭제라 괜찮다).
   */
  router.post('/users/me/avatar/character/:stickerId', async (req, res) => {
    const user = await findUserById(req.user.sub);
    if (!user) return res.status(404).json({ error: '사용자를 찾을 수 없습니다.' });

    const found = await findStickerWithPack(req.params.stickerId);
    if (
      !found ||
      found.pack.kind !== 'character' ||
      found.pack.deletedAt ||
      found.pack.hidden ||
      found.hidden ||
      found.deletedAt
    ) {
      return res.status(404).json({ error: '캐릭터를 찾을 수 없습니다.' });
    }

    const updated = await updateUser(user.id, {
      avatarType: 'photo',
      avatarEmoji: null,
      avatarColor: null,
      // 프로필 사진은 작게만 그려지므로 썸네일이 있으면 그걸 복사한다(없으면 원본).
      avatarUrl: found.thumbnailUrl ?? found.fileUrl,
    });
    await broadcastMemberUpdate(io, user.id);
    res.json(selfUser(updated));
  });

  /**
   * 비밀번호 변경(로그인된 상태). 현재 비밀번호 확인 후 바꾸고, 다른 기기의 세션은
   * tokenVersion을 올려서 즉시 끊는다(reset-password와 같은 정책) — 단, 지금 이 요청을
   * 보낸 기기는 로그아웃시키지 않고 새 토큰 쌍을 바로 응답에 실어줘서 매끄럽게 이어지게 한다.
   */
  /**
   * 내 상태 메시지 — `{ emoji, text, until }`(until은 지울 시각 ms, null이면 직접 지울 때까지). 이모지와 글이 둘 다 없으면
   * 지운다. 같은 팀 사람들에게 user:status로 알린다.
   */
  router.put('/users/me/status', async (req, res) => {
    const parsed = parseStatusInput(req.body ?? {}, Date.now());
    if (parsed.error) return res.status(400).json({ error: parsed.error });
    const updated = await updateUser(req.user.sub, parsed.value);
    if (!updated) return res.status(404).json({ error: '사용자를 찾을 수 없습니다.' });
    await broadcastStatus(io, updated);
    res.json(selfUser(updated));
  });

  /**
   * 내 방해 금지 — `{ until }`(이 시각까지 — null이면 끔)과 `{ schedule }`(매일 정한 시간 — null이면 지움) 중 넘긴 것만 바꾼다.
   * 방해 금지 중에는 푸시를 보내지 않고(push.js) 앱도 알림을 띄우지 않는다. 같은 팀 사람들에게 user:status로 알린다.
   */
  router.put('/users/me/dnd', async (req, res) => {
    const parsed = parseDndInput(req.body ?? {}, Date.now());
    if (parsed.error) return res.status(400).json({ error: parsed.error });
    const updated = await updateUser(req.user.sub, parsed.value);
    if (!updated) return res.status(404).json({ error: '사용자를 찾을 수 없습니다.' });
    await broadcastStatus(io, updated);
    res.json(selfUser(updated));
  });

  router.post('/users/me/change-password', async (req, res) => {
    const user = await findUserById(req.user.sub);
    if (!user) return res.status(404).json({ error: '사용자를 찾을 수 없습니다.' });

    const { currentPassword, newPassword } = req.body ?? {};
    const passwordError = passwordPolicyError(newPassword, { username: user.username });
    if (passwordError) return res.status(400).json({ error: `새 ${passwordError}` });
    if (!(await checkCurrentPassword(res, user, currentPassword, '현재 비밀번호가 올바르지 않습니다.'))) return;

    const updated = await updateUser(user.id, {
      passwordHash: await bcrypt.hash(newPassword, 10),
      tokenVersion: (user.tokenVersion ?? 0) + 1,
    });

    // 이 기기가 방금 쓴 소켓 연결도 tokenVersion이 바뀌어 곧 끊길 테니, 새 토큰으로
    // 다시 붙을 수 있도록 응답에 새 토큰 쌍을 실어 보낸다. 다른 기기는 여기서 끊고 끝.
    io.in(`user:${user.id}`).disconnectSockets(true);

    res.json({ ...issueTokenPair(updated), userId: updated.id, username: updated.username });
  });

  /**
   * 회원 탈퇴. 정책:
   *  0) 마지막(탈퇴·정지 안 된 운영자가 나 하나뿐인) 서버 운영자는 탈퇴할 수 없다 — 아무도 관리자 콘솔에
   *     못 들어가게 되고, 예전엔 그 뒤의 첫 가입자가 서버 운영자가 됐다(auth.js). 다른 사람을 운영자로
   *     지정한 뒤에 탈퇴한다.
   *  1) 로그인 차단 — deletedAt을 기록해두면 /auth/login이 거부한다.
   *  2) 세션/토큰 즉시 폐기 — tokenVersion을 올리고 지금 연결된 소켓도 끊는다
   *     (비밀번호 변경과 같은 메커니즘). 기기들의 푸시 토큰·웹 푸시 구독도 지우고, 진행 중인 화상회의에서도 내보낸다.
   *  3) 이메일·이름·프로필 익명화.
   *  4) 메시지는 삭제하지 않고 그대로 둔다(1년 뒤 보존기간 만료 시 retention.js가 처리).
   *  5) 과거 메시지의 작성자 표시도 "탈퇴한 사용자"로 바꾼다 — 방 멤버 목록을 통한 조회에만
   *     의존하면(나중에 멤버 목록에서 빠지는 경우 등) 예전 실명이 그대로 남을 수 있어서,
   *     메시지 자체에 박제된 senderName도 지금 시점에 다시 써둔다.
   *  6) 첨부 파일은 지우지 않는다(보존 정책).
   *  7) 별도 백업/검색 색인이 없는 구조라 위 변경이 곧 전체 반영이다(search.js도 같은 DB를
   *     그대로 조회).
   */
  router.post('/users/me/withdraw', async (req, res) => {
    const user = await findUserById(req.user.sub);
    if (!user) return res.status(404).json({ error: '사용자를 찾을 수 없습니다.' });
    if (user.deletedAt) return res.status(400).json({ error: '이미 탈퇴한 계정입니다.' });

    const { password } = req.body ?? {};
    if (!(await checkCurrentPassword(res, user, password, '비밀번호가 올바르지 않습니다.'))) return;

    const withdrawn = await updateUserUnlessLastServerAdmin(user.id, {
      deletedAt: new Date(),
      tokenVersion: (user.tokenVersion ?? 0) + 1,
      name: DELETED_USER_NAME,
      emailEnc: null,
      emailLookup: null,
      emailVerifiedAt: null,
      avatarType: 'initial',
      avatarEmoji: null,
      avatarColor: null,
      avatarUrl: null,
    });
    if (!withdrawn) {
      return res.status(400).json({
        error: '마지막 서버 운영자는 탈퇴할 수 없습니다. 관리자 콘솔에서 다른 회원을 서버 운영자로 지정한 뒤 탈퇴하세요.',
      });
    }
    // 탈퇴한 계정에는 어떤 알림도 보내지 않는다 — 보내는 쪽은 이미 탈퇴·정지 계정을 거르지만(db/queries/devices.js), 이
    // 계정 기기들의 푸시 토큰·웹 푸시 구독도 지워서 그 기기(폰·브라우저)로 갈 길 자체를 없앤다. 뒷정리라서 실패해도(드문 DB
    // 오류) 기록만 남기고 아래 탈퇴 처리는 이어 간다.
    await clearPushTargetsForUser(user.id).catch((err) =>
      console.error('[users] 탈퇴 계정 푸시 토큰·구독 지우기 실패:', user.id, err?.message ?? err),
    );
    await renameSenderMessages(user.id, DELETED_USER_NAME);
    // 탈퇴한 사람은 토픽을 관리할 수 없다 — 토픽 관리자 역할은 거둔다(아래 방 정보 재전송에 같이 반영).
    await clearTopicAdminRoles(user.id);
    // 예약 메시지는 탈퇴한 계정으로는 영영 못 보낸다(scheduledMessages.js) — 발송 실패로 쌓아 두지 말고 지운다.
    await deleteScheduledMessagesForUser(user.id);

    io.in(`user:${user.id}`).disconnectSockets(true);
    // 진행 중인 화상회의에서도 내보낸다 — 소켓을 끊어도 이미 연결된 통화 미디어는 그대로 오가기 때문이다(callAccess.js).
    await endUserCallAccess(io, user.id);
    await broadcastMemberUpdate(io, user.id);

    res.json({ ok: true });
  });

  return router;
}
