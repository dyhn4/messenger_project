import bcrypt from 'bcryptjs';
import { Router } from 'express';
import { issueTokenPair } from './auth.js';
import { decryptField, encryptField, lookupHash } from './crypto.js';
import { renameSenderMessages } from './db/queries/messages.js';
import { findOtherUserByEmailLookup, findUserById, listActiveUsers, updateUser } from './db/queries/users.js';
import { isOnline } from './presence.js';
import { accountRole } from './permissions.js';
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

/** io를 캡처해 프로필(이름/이메일/아바타)이 바뀌면 이 사람이 속한 모든 방에 최신 멤버
 * 정보를 브로드캐스트한다 — 안 그러면 다른 기기/다른 사람 화면의 방 목록·채팅방 제목이
 * 예전 이름/아바타로 남아있게 된다. */
export function createUsersRouter(io) {
  const router = Router();

  /**
   * 방 멤버 선택(그룹/DM 생성)·멤버 패널에 쓸 전체 가입자 목록. 탈퇴한 사용자는 로그인도
   * 못 하고 새로 대화를 걸 수도 없으니 여기서 뺀다 — 다만 예전에 같이 있던 방의 멤버
   * 목록/과거 메시지 작성자 표시(publicUser 자체)에서는 계속 "탈퇴한 사용자"로 보여야
   * 하므로 그쪽(rooms.js의 listRoomMemberUsers 등)은 건드리지 않는다.
   */
  router.get('/users', async (req, res) => {
    res.json((await listActiveUsers()).map(publicUser));
  });

  /** 내 프로필(아바타 포함) 조회. 내 화면에서만 쓰는 값이라 서버 운영자 여부도 여기 실어준다
   * (다른 사람의 publicUser에는 넣지 않는다 — 누가 운영자인지는 관리자 콘솔에서만 본다). */
  router.get('/users/me', async (req, res) => {
    const user = await findUserById(req.user.sub);
    if (!user) return res.status(404).json({ error: '사용자를 찾을 수 없습니다.' });
    res.json({ ...publicUser(user), isServerAdmin: !!user.isServerAdmin });
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
