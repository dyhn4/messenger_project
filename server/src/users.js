import { Router } from 'express';
import { db } from './db.js';
import { decryptField, encryptField, lookupHash } from './crypto.js';
import { toRoomDto } from './rooms.js';
import { signFileUrl } from './upload.js';

const VALID_AVATAR_TYPES = new Set(['initial', 'character', 'photo']);
const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

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
  };
}

/** io를 캡처해 프로필(이름/이메일/아바타)이 바뀌면 이 사람이 속한 모든 방에 최신 멤버
 * 정보를 브로드캐스트한다 — 안 그러면 다른 기기/다른 사람 화면의 방 목록·채팅방 제목이
 * 예전 이름/아바타로 남아있게 된다. */
export function createUsersRouter(io) {
  const router = Router();

  /** 방 멤버 선택(그룹/DM 생성)에 쓸 전체 가입자 목록. */
  router.get('/users', (req, res) => {
    res.json(db.data.users.map(publicUser));
  });

  /** 내 프로필(아바타 포함) 조회. */
  router.get('/users/me', (req, res) => {
    const user = db.data.users.find((u) => u.id === req.user.sub);
    if (!user) return res.status(404).json({ error: '사용자를 찾을 수 없습니다.' });
    res.json(publicUser(user));
  });

  /**
   * 내 프로필 갱신. avatarType이 오면 아바타 상태를 통째로 바꾸고(초기화/캐릭터 선택/사진
   * 업로드가 서로 다른 필드 조합을 쓰므로 부분 수정 대신 전체 교체), name/email은 각각
   * 왔을 때만 독립적으로 갱신한다.
   */
  router.patch('/users/me', async (req, res) => {
    const user = db.data.users.find((u) => u.id === req.user.sub);
    if (!user) return res.status(404).json({ error: '사용자를 찾을 수 없습니다.' });

    const { avatarType, avatarEmoji, avatarColor, avatarUrl, name, email } = req.body ?? {};

    if (avatarType !== undefined) {
      if (!VALID_AVATAR_TYPES.has(avatarType)) {
        return res.status(400).json({ error: '잘못된 avatarType입니다.' });
      }
      user.avatarType = avatarType;
      user.avatarEmoji = avatarEmoji ?? null;
      user.avatarColor = avatarColor ?? null;
      user.avatarUrl = avatarUrl ?? null;
    }

    if (name !== undefined) {
      if (!String(name).trim()) {
        return res.status(400).json({ error: '이름을 입력하세요.' });
      }
      user.name = String(name).trim();
    }

    if (email !== undefined) {
      if (!EMAIL_PATTERN.test(email)) {
        return res.status(400).json({ error: '이메일 형식이 올바르지 않습니다.' });
      }
      const emailLookup = lookupHash(email);
      const taken = db.data.users.find((u) => u.id !== user.id && u.emailLookup === emailLookup);
      if (taken) {
        return res.status(409).json({ error: '이미 사용 중인 이메일입니다.' });
      }
      user.emailEnc = encryptField(email);
      user.emailLookup = emailLookup;
    }

    await db.write();

    // 이 사람이 속한 모든 방(다른 기기 포함, 그 방의 멤버 전원)에 갱신된 멤버 정보를 알린다.
    for (const room of db.data.rooms) {
      if (room.memberIds.includes(user.id)) {
        io.to(room.id).emit('room:created', toRoomDto(room));
      }
    }

    res.json(publicUser(user));
  });

  return router;
}
