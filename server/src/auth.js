import bcrypt from 'bcryptjs';
import { Router } from 'express';
import jwt from 'jsonwebtoken';
import { randomUUID } from 'node:crypto';
import { db } from './db.js';
import { JWT_SECRET } from './config.js';
import { encryptField, lookupHash } from './crypto.js';
import { nameOf, notifyMembership, postSystemMessage } from './rooms.js';

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

// AccessToken은 짧게(매 API 요청마다 DB 조회 없이 서명/만료만 검증), RefreshToken은
// 길게(만료되거나 재시작했을 때만 새 AccessToken을 받아오며, 이때만 tokenVersion을 DB와
// 대조한다) 가져가는 이중 토큰 구조. 비밀번호 변경 시 tokenVersion을 올리면, 이미 나가있는
// AccessToken은 최대 그 유효기간(1시간)만큼만 더 쓰이고, RefreshToken은 그 즉시 막힌다.
const ACCESS_TOKEN_TTL = '1h';
const REFRESH_TOKEN_TTL = '30d';

function issueTokenPair(user) {
  const tokenVersion = user.tokenVersion ?? 0;
  const accessToken = jwt.sign(
    { sub: user.id, username: user.username, tokenVersion, type: 'access' },
    JWT_SECRET,
    { expiresIn: ACCESS_TOKEN_TTL },
  );
  const refreshToken = jwt.sign(
    { sub: user.id, tokenVersion, type: 'refresh' },
    JWT_SECRET,
    { expiresIn: REFRESH_TOKEN_TTL },
  );
  return { accessToken, refreshToken };
}

/** io를 캡처해, 회원가입 시 기존 공개 토픽 전체에 자동으로 가입시키고 알립니다. */
export function createAuthRouter(io) {
  const router = Router();

  router.post('/register', async (req, res) => {
    const { username, password, email, name } = req.body ?? {};
    if (!username || !password || !email || !name) {
      return res.status(400).json({ error: '아이디, 이름, 비밀번호, 이메일을 입력하세요.' });
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
    const emailLookup = lookupHash(email);
    const emailTaken = db.data.users.find((u) => u.emailLookup === emailLookup);
    if (emailTaken) {
      return res.status(409).json({ error: '이미 사용 중인 이메일입니다.' });
    }

    const user = {
      id: randomUUID(),
      username,
      name: name.trim(),
      emailEnc: encryptField(email),
      emailLookup,
      passwordHash: await bcrypt.hash(password, 10),
      tokenVersion: 0,
      createdAt: Date.now(),
      avatarType: 'character',
      avatarEmoji: randomOf(CHARACTER_EMOJIS),
      avatarColor: randomOf(CHARACTER_COLORS),
      avatarUrl: null,
    };
    db.data.users.push(user);

    // 기존 공개 토픽 전체에 자동으로 가입시킨다(새로 만든 공개 토픽에 지금 회원 전원이
    // 들어가는 것과 대칭 — 공개 토픽은 항상 "가입된 모든 회원"이 멤버가 되도록 유지한다).
    const publicTopics = db.data.rooms.filter((r) => r.type === 'topic' && r.isPublic !== false);
    for (const room of publicTopics) {
      room.memberIds.push(user.id);
    }
    await db.write();

    for (const room of publicTopics) {
      notifyMembership(io, room);
      await postSystemMessage(io, room, `${nameOf(user.id)} 님이 참여했습니다.`);
    }

    res.status(201).json({ ...issueTokenPair(user), userId: user.id, username: user.username });
  });

  /** 이메일로 아이디를 찾는다. 가입할 때 등록해둔 이메일이 있어야 동작한다. */
  router.post('/find-id', (req, res) => {
    const { email } = req.body ?? {};
    const user = db.data.users.find((u) => u.emailLookup === lookupHash(email));
    if (!user) {
      return res.status(404).json({ error: '일치하는 계정이 없습니다.' });
    }
    res.json({ username: user.username });
  });

  /**
   * 이메일 인증 없이 앱 안에서 바로 비밀번호를 재설정한다 (서버에 메일 발송 기능이 없음).
   * 아이디와 이메일이 둘 다 일치해야 통과한다.
   */
  router.post('/reset-password', async (req, res) => {
    const { username, email, newPassword } = req.body ?? {};
    if (!newPassword || newPassword.length < 4) {
      return res.status(400).json({ error: '비밀번호는 4자 이상이어야 합니다.' });
    }

    const user = db.data.users.find((u) => u.username === username && u.emailLookup === lookupHash(email));
    if (!user) {
      return res.status(400).json({ error: '아이디와 이메일이 일치하는 계정이 없습니다.' });
    }

    user.passwordHash = await bcrypt.hash(newPassword, 10);
    // 비밀번호가 바뀌었으니 이전에 발급된 모든 토큰을 무효화한다: AccessToken은 남은
    // 유효기간(최대 1시간) 뒤에, RefreshToken은 즉시(다음 재발급 시도부터) 막히고,
    // 지금 연결돼있는 소켓도 바로 끊어서 실시간 세션도 함께 정리한다.
    user.tokenVersion = (user.tokenVersion ?? 0) + 1;
    await db.write();
    io.in(`user:${user.id}`).disconnectSockets(true);

    res.json({ ok: true });
  });

  router.post('/login', async (req, res) => {
    const { username, password } = req.body ?? {};
    const user = db.data.users.find((u) => u.username === username);
    if (!user || !(await bcrypt.compare(password ?? '', user.passwordHash))) {
      return res.status(401).json({ error: '아이디 또는 비밀번호가 올바르지 않습니다.' });
    }

    res.json({ ...issueTokenPair(user), userId: user.id, username: user.username });
  });

  /** AccessToken이 만료됐을 때 RefreshToken으로 새 AccessToken을 받아온다. */
  router.post('/refresh', async (req, res) => {
    const { refreshToken } = req.body ?? {};
    if (!refreshToken) {
      return res.status(400).json({ error: 'refreshToken이 없습니다.' });
    }

    let payload;
    try {
      payload = jwt.verify(refreshToken, JWT_SECRET);
    } catch {
      return res.status(401).json({ error: '세션이 만료되었습니다. 다시 로그인해주세요.' });
    }
    if (payload.type !== 'refresh') {
      return res.status(401).json({ error: '세션이 만료되었습니다. 다시 로그인해주세요.' });
    }

    const user = db.data.users.find((u) => u.id === payload.sub);
    if (!user || (user.tokenVersion ?? 0) !== payload.tokenVersion) {
      // 비밀번호 변경/강제 로그아웃 등으로 이 RefreshToken 자체가 이미 폐기된 경우.
      return res.status(401).json({ error: '세션이 만료되었습니다. 다시 로그인해주세요.' });
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
export function requireAuth(req, res, next) {
  const header = req.headers.authorization ?? '';
  const token = header.startsWith('Bearer ') ? header.slice(7) : null;
  if (!token) return res.status(401).json({ error: '토큰이 없습니다.' });

  try {
    const payload = jwt.verify(token, JWT_SECRET);
    if (payload.type !== 'access') throw new Error('invalid token type');
    req.user = payload;
    next();
  } catch {
    res.status(401).json({ error: '토큰이 유효하지 않습니다.' });
  }
}

/**
 * Socket.io 연결 시점에 handshake.auth.token을 확인합니다.
 * 소켓 연결은(매 메시지가 아니라) 앱 시작/재연결 시에만 일어나는 저빈도 경로라, 여기서는
 * tokenVersion까지 DB와 대조해서 비밀번호 변경 직후 캐시된 AccessToken으로 재연결을
 * 시도하는 것까지 막는다.
 */
export function verifySocketToken(token) {
  const payload = jwt.verify(token, JWT_SECRET); // 서명/만료 실패 시 throw
  if (payload.type !== 'access') {
    throw new Error('invalid token type');
  }
  const user = db.data.users.find((u) => u.id === payload.sub);
  if (!user || (user.tokenVersion ?? 0) !== payload.tokenVersion) {
    throw new Error('unauthorized');
  }
  return payload;
}
