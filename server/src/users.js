import { Router } from 'express';
import { db } from './db.js';

export const usersRouter = Router();

const VALID_AVATAR_TYPES = new Set(['initial', 'character', 'photo']);

/** 비밀번호 등 민감 정보를 뺀, 다른 곳에 내려줘도 되는 사용자 정보. */
export function publicUser(u) {
  return {
    id: u.id,
    username: u.username,
    email: u.email,
    avatarType: u.avatarType ?? 'initial',
    avatarEmoji: u.avatarEmoji ?? null,
    avatarColor: u.avatarColor ?? null,
    avatarUrl: u.avatarUrl ?? null,
  };
}

/** 방 멤버 선택(그룹/DM 생성)에 쓸 전체 가입자 목록. */
usersRouter.get('/users', (req, res) => {
  res.json(db.data.users.map(publicUser));
});

/** 내 프로필(아바타 포함) 조회. */
usersRouter.get('/users/me', (req, res) => {
  const user = db.data.users.find((u) => u.id === req.user.sub);
  if (!user) return res.status(404).json({ error: '사용자를 찾을 수 없습니다.' });
  res.json(publicUser(user));
});

/**
 * 내 프로필 사진 갱신. 매번 avatarType과 함께 전체 아바타 상태를 통째로 바꾼다
 * (초기화/캐릭터 선택/사진 업로드가 서로 다른 필드 조합을 쓰므로 부분 수정 대신 전체 교체).
 */
usersRouter.patch('/users/me', async (req, res) => {
  const user = db.data.users.find((u) => u.id === req.user.sub);
  if (!user) return res.status(404).json({ error: '사용자를 찾을 수 없습니다.' });

  const { avatarType, avatarEmoji, avatarColor, avatarUrl } = req.body ?? {};
  if (!VALID_AVATAR_TYPES.has(avatarType)) {
    return res.status(400).json({ error: '잘못된 avatarType입니다.' });
  }
  user.avatarType = avatarType;
  user.avatarEmoji = avatarEmoji ?? null;
  user.avatarColor = avatarColor ?? null;
  user.avatarUrl = avatarUrl ?? null;
  await db.write();

  res.json(publicUser(user));
});
