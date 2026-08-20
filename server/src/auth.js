import bcrypt from 'bcryptjs';
import { Router } from 'express';
import jwt from 'jsonwebtoken';
import { randomUUID } from 'node:crypto';
import { db } from './db.js';
import { JWT_SECRET } from './config.js';

export const authRouter = Router();

const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

// 클라이언트의 "캐릭터 선택하기" 화면(client/lib/screens/my_profile_dialog.dart)과 같은 구성.
const CHARACTER_EMOJIS = [
  '🧑‍🦰', '👮', '🧑‍🌾', '👩‍🦰', '🧑‍✈️', '👩‍💼',
  '🧑‍💼', '👩‍🦱', '🧔', '👩‍🎤', '🧑‍🎨', '🧑‍🔬',
];
const CHARACTER_COLORS = [
  '#9AA6B2', '#4C6EF5', '#15AABF', '#FAB005', '#FF6B35',
  '#37B24D', '#0CA678', '#E64980', '#9775FA', '#8D6E63',
];
const randomOf = (list) => list[Math.floor(Math.random() * list.length)];

function issueToken(user) {
  return jwt.sign({ sub: user.id, username: user.username }, JWT_SECRET, { expiresIn: '30d' });
}

authRouter.post('/register', async (req, res) => {
  const { username, password, email } = req.body ?? {};
  if (!username || !password || !email) {
    return res.status(400).json({ error: '아이디, 비밀번호, 이메일을 입력하세요.' });
  }
  if (password.length < 4) {
    return res.status(400).json({ error: '비밀번호는 4자 이상이어야 합니다.' });
  }
  if (!EMAIL_PATTERN.test(email)) {
    return res.status(400).json({ error: '이메일 형식이 올바르지 않습니다.' });
  }

  const exists = db.data.users.find((u) => u.username === username);
  if (exists) {
    return res.status(409).json({ error: '이미 사용 중인 아이디입니다.' });
  }
  const emailTaken = db.data.users.find((u) => u.email === email);
  if (emailTaken) {
    return res.status(409).json({ error: '이미 사용 중인 이메일입니다.' });
  }

  const user = {
    id: randomUUID(),
    username,
    email,
    passwordHash: await bcrypt.hash(password, 10),
    createdAt: Date.now(),
    avatarType: 'character',
    avatarEmoji: randomOf(CHARACTER_EMOJIS),
    avatarColor: randomOf(CHARACTER_COLORS),
    avatarUrl: null,
  };
  db.data.users.push(user);
  await db.write();

  res.status(201).json({ token: issueToken(user), userId: user.id, username: user.username });
});

/** 이메일로 아이디를 찾는다. 가입할 때 등록해둔 이메일이 있어야 동작한다. */
authRouter.post('/find-id', (req, res) => {
  const { email } = req.body ?? {};
  const user = db.data.users.find((u) => u.email === email);
  if (!user) {
    return res.status(404).json({ error: '일치하는 계정이 없습니다.' });
  }
  res.json({ username: user.username });
});

/**
 * 이메일 인증 없이 앱 안에서 바로 비밀번호를 재설정한다 (서버에 메일 발송 기능이 없음).
 * 아이디와 이메일이 둘 다 일치해야 통과한다.
 */
authRouter.post('/reset-password', async (req, res) => {
  const { username, email, newPassword } = req.body ?? {};
  if (!newPassword || newPassword.length < 4) {
    return res.status(400).json({ error: '비밀번호는 4자 이상이어야 합니다.' });
  }

  const user = db.data.users.find((u) => u.username === username && u.email === email);
  if (!user) {
    return res.status(400).json({ error: '아이디와 이메일이 일치하는 계정이 없습니다.' });
  }

  user.passwordHash = await bcrypt.hash(newPassword, 10);
  await db.write();

  res.json({ ok: true });
});

authRouter.post('/login', async (req, res) => {
  const { username, password } = req.body ?? {};
  const user = db.data.users.find((u) => u.username === username);
  if (!user || !(await bcrypt.compare(password ?? '', user.passwordHash))) {
    return res.status(401).json({ error: '아이디 또는 비밀번호가 올바르지 않습니다.' });
  }

  res.json({ token: issueToken(user), userId: user.id, username: user.username });
});

/** Express용 인증 미들웨어. Authorization: Bearer <token> 헤더를 확인합니다. */
export function requireAuth(req, res, next) {
  const header = req.headers.authorization ?? '';
  const token = header.startsWith('Bearer ') ? header.slice(7) : null;
  if (!token) return res.status(401).json({ error: '토큰이 없습니다.' });

  try {
    req.user = jwt.verify(token, JWT_SECRET);
    next();
  } catch {
    res.status(401).json({ error: '토큰이 유효하지 않습니다.' });
  }
}

/** Socket.io 연결 시점에 handshake.auth.token을 확인합니다. */
export function verifySocketToken(token) {
  return jwt.verify(token, JWT_SECRET); // 실패 시 throw
}
