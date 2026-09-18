import bcrypt from 'bcryptjs';
import { Router } from 'express';
import { issueTokenPair } from './auth.js';
import { decryptField, encryptField, lookupHash } from './crypto.js';
import { renameSenderMessages } from './db/queries/messages.js';
import { findOtherUserByEmailLookup, findUserById, listActiveUsers, updateUser } from './db/queries/users.js';
import { findTeamMember, listTeamIdsForUser, listTeamsForUser } from './db/queries/teams.js';
import { listPositionOptions } from './db/queries/positionOptions.js';
import { isOnline } from './presence.js';
import { accountRole, canCreateProject, canCreateTeamInviteLink } from './permissions.js';
import { getServerSettings } from './db/queries/serverSettings.js';
import { broadcastMemberUpdate } from './rooms.js';
import { signFileUrl } from './upload.js';

const VALID_AVATAR_TYPES = new Set(['initial', 'character', 'photo']);
const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
export const DELETED_USER_NAME = '탈퇴한 사용자';

/** 비밀번호 등 민감 정보를 뺀, 다른 곳에 내려줘도 되는 사용자 정보. */
export function publicUser(u) {
  return {
    id: u.id,
    username: u.username,
    name: u.name ?? u.username,
    email: u.emailEnc ? decryptField(u.emailEnc) : null,
    avatarType: u.avatarType ?? 'initial',
    avatarEmoji: u.avatarEmoji ?? null,
    avatarColor: u.avatarColor ?? null,
    avatarUrl: signFileUrl(u.avatarUrl) ?? null,
    online: isOnline(u.id),
    // 계정 등급 — 팀 설정의 "팀원 추가"나 조직도에서 등급을 보여주는 데 쓴다.
    // 바꾸는 것은 서버 운영자만 가능하다(admin.js).
    role: accountRole(u),
  };
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

/** io를 캡처해 프로필(이름/이메일/아바타)이 바뀌면 이 사람이 속한 모든 방에 최신 멤버
 * 정보를 브로드캐스트한다 — 안 그러면 다른 기기/다른 사람 화면의 방 목록·채팅방 제목이
 * 예전 이름/아바타로 남아있게 된다. */
export function createUsersRouter(io) {
  const router = Router();

  /**
   * 방 멤버 선택(그룹/DM 생성)·멤버 패널·조직도에 쓸 전체 가입자 목록. 탈퇴한 사용자는
   * 로그인도 못 하고 새로 대화를 걸 수도 없으니 여기서 뺀다 — 다만 예전에 같이 있던 방의
   * 멤버 목록/과거 메시지 작성자 표시(publicUser 자체)에서는 계속 "탈퇴한 사용자"로 보여야
   * 하므로 그쪽(rooms.js의 listRoomMemberUsers 등)은 건드리지 않는다.
   *
   * 직책(position)은 이 목록이 "특정 팀 안"이 아니라 서버 전체를 훑는 목록이라, 팀마다 다를
   * 수 있는 값(orgScope='team')은 하나로 못 정해서 뺀다 — 계정 단위로 관리하는 서버
   * (orgScope='account')일 때만, 사람마다 값이 하나뿐이니 그대로 실어준다(조직도 "멤버" 탭이
   * 이 값을 쓴다).
   */
  router.get('/users', async (req, res) => {
    const settings = await getServerSettings();
    const users = await listActiveUsers();
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
   * 이 사람이 속한 팀들 — 프로필 카드의 "팀" 항목이 쓴다. 본인이면 전부, 남이면 노출 범위를
   * 다르게 둔다: 대상이 계정 등급 관리자면 관리자는 보통 여러 팀에 걸쳐 있어서 나와 겹치는
   * 팀만(내가 이미 알 수 있는 관계로 제한), 정회원·준회원이면 소속이 단순해서 전체를 그대로
   * 보여준다. "조직도"(관리자 이상 전용, GET /org-chart/teams)와 달리 이건 누구나 호출할 수
   * 있는 대신, 위 규칙으로 노출 범위를 스스로 제한한다.
   */
  router.get('/users/:id/teams', async (req, res) => {
    const target = await findUserById(req.params.id);
    if (!target || target.deletedAt) return res.status(404).json({ error: '사용자를 찾을 수 없습니다.' });

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
      ...publicUser(user),
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
    if (!password || !(await bcrypt.compare(password, user.passwordHash))) {
      return res.status(401).json({ error: '비밀번호가 올바르지 않습니다.' });
    }
    res.json({ ok: true });
  });

  /**
   * 내 프로필 갱신. avatarType이 오면 아바타 상태를 통째로 바꾸고(초기화/캐릭터 선택/사진
   * 업로드가 서로 다른 필드 조합을 쓰므로 부분 수정 대신 전체 교체), name/email은 각각
   * 왔을 때만 독립적으로 갱신한다.
   */
  router.patch('/users/me', async (req, res) => {
    const user = await findUserById(req.user.sub);
    if (!user) return res.status(404).json({ error: '사용자를 찾을 수 없습니다.' });

    const { avatarType, avatarEmoji, avatarColor, avatarUrl, name, email, currentPassword } =
      req.body ?? {};
    const patch = {};

    if (avatarType !== undefined) {
      if (!VALID_AVATAR_TYPES.has(avatarType)) {
        return res.status(400).json({ error: '잘못된 avatarType입니다.' });
      }
      patch.avatarType = avatarType;
      patch.avatarEmoji = avatarEmoji ?? null;
      patch.avatarColor = avatarColor ?? null;
      patch.avatarUrl = avatarUrl ?? null;
    }

    if (name !== undefined) {
      if (!String(name).trim()) {
        return res.status(400).json({ error: '이름을 입력하세요.' });
      }
      patch.name = String(name).trim();
    }

    if (email !== undefined) {
      // 이메일은 아이디/비밀번호 찾기에 쓰이는 계정 복구 수단이라, 이름/아바타와 달리
      // 현재 비밀번호로 본인 확인을 한 번 더 받는다(비밀번호 변경과 같은 정책).
      if (!currentPassword || !(await bcrypt.compare(currentPassword, user.passwordHash))) {
        return res.status(401).json({ error: '현재 비밀번호가 올바르지 않습니다.' });
      }
      if (!EMAIL_PATTERN.test(email)) {
        return res.status(400).json({ error: '이메일 형식이 올바르지 않습니다.' });
      }
      const emailLookup = lookupHash(email);
      const taken = await findOtherUserByEmailLookup(emailLookup, user.id);
      if (taken) {
        return res.status(409).json({ error: '이미 사용 중인 이메일입니다.' });
      }
      patch.emailEnc = encryptField(email);
      patch.emailLookup = emailLookup;
    }

    const updated = await updateUser(user.id, patch);

    // 이 사람이 속한 모든 방(다른 기기 포함, 그 방의 멤버 전원)에 갱신된 멤버 정보를 알린다.
    await broadcastMemberUpdate(io, user.id);

    res.json(publicUser(updated));
  });

  /**
   * 비밀번호 변경(로그인된 상태). 현재 비밀번호 확인 후 바꾸고, 다른 기기의 세션은
   * tokenVersion을 올려서 즉시 끊는다(reset-password와 같은 정책) — 단, 지금 이 요청을
   * 보낸 기기는 로그아웃시키지 않고 새 토큰 쌍을 바로 응답에 실어줘서 매끄럽게 이어지게 한다.
   */
  router.post('/users/me/change-password', async (req, res) => {
    const user = await findUserById(req.user.sub);
    if (!user) return res.status(404).json({ error: '사용자를 찾을 수 없습니다.' });

    const { currentPassword, newPassword } = req.body ?? {};
    if (!newPassword || newPassword.length < 4) {
      return res.status(400).json({ error: '새 비밀번호는 4자 이상이어야 합니다.' });
    }
    if (!currentPassword || !(await bcrypt.compare(currentPassword, user.passwordHash))) {
      return res.status(401).json({ error: '현재 비밀번호가 올바르지 않습니다.' });
    }

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
   *  1) 로그인 차단 — deletedAt을 기록해두면 /auth/login이 거부한다.
   *  2) 세션/토큰 즉시 폐기 — tokenVersion을 올리고 지금 연결된 소켓도 끊는다
   *     (비밀번호 변경과 같은 메커니즘).
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
    if (!password || !(await bcrypt.compare(password, user.passwordHash))) {
      return res.status(401).json({ error: '비밀번호가 올바르지 않습니다.' });
    }

    await updateUser(user.id, {
      deletedAt: new Date(),
      tokenVersion: (user.tokenVersion ?? 0) + 1,
      name: DELETED_USER_NAME,
      emailEnc: null,
      emailLookup: null,
      avatarType: 'initial',
      avatarEmoji: null,
      avatarColor: null,
      avatarUrl: null,
    });
    await renameSenderMessages(user.id, DELETED_USER_NAME);

    io.in(`user:${user.id}`).disconnectSockets(true);
    await broadcastMemberUpdate(io, user.id);

    res.json({ ok: true });
  });

  return router;
}
