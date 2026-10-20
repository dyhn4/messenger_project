/**
 * 알림에서 바로 답장(안드로이드 — 알림의 "답장" 칸)의 순수 규칙 — 답장 표 만들기·검사, 답장을 받는 알림인지, 위젯 칸. DB 없이 `node --test`로
 * 시험한다(test/pushReply.test.js).
 *
 * 앱이 꺼져 있으면 알림에서 답장하는 코드(client main.dart의 백그라운드 isolate)는 로그인 토큰을 쓸 수 없다 — AccessToken은 1시간이면
 * 끝나고, 거기서 RefreshToken으로 갱신하면 메인 앱이 들고 있던 RefreshToken이 낡아 로그아웃될 수 있다. 그래서 서버가 채팅 푸시마다
 * **그 기기·그 사람·그 방에서 글 하나를 보내는 것만** 되는 답장 표(replyTicket)를 FCM data에 실어 보낸다(push.js — 기기마다 따로).
 * 표는 `v1.<본문>.<서명>`(base64url) — 본문 `{ u: 사람, r: 방, d: 기기, v: 토큰 버전, e: 만료 epoch ms }`, 서명은 서버 비밀값에서 이 용도로
 * 따로 뽑은 열쇠의 HMAC-SHA256이라 로그인 토큰(JWT)으로는 쓸 수 없고 로그인 토큰도 표로 쓸 수 없다. 받는 쪽(pushReply.js)은 서명·만료와
 * 함께 그 사람이 지금도 로그인할 수 있는지(정지·탈퇴·비밀번호 변경으로 토큰 버전이 올랐는지)·그 기기가 아직 로그인돼 있는지를 본다.
 */
import crypto from 'node:crypto';

/** 답장 표가 쓰이는 기간 — 알림은 며칠씩 남아 있기도 해서 넉넉히, 그래도 오래 새지 않게 3일. */
export const REPLY_TICKET_TTL_MS = 3 * 24 * 60 * 60 * 1000;

const PREFIX = 'v1';
const b64 = (buf) => Buffer.from(buf).toString('base64url');
const keyOf = (secret) => crypto.createHmac('sha256', String(secret)).update('push-reply-ticket:v1').digest();
const sign = (secret, body) => b64(crypto.createHmac('sha256', keyOf(secret)).update(body).digest());

/** 답장 표 — [secret]은 서버 비밀값(config.js JWT_SECRET), 나머지는 표에 묶을 사람·방·기기·토큰 버전. */
export function signReplyTicket(secret, { userId, roomId, deviceId, tokenVersion = 0 }, now = Date.now()) {
  const body = b64(JSON.stringify({ u: userId, r: roomId, d: deviceId, v: tokenVersion, e: now + REPLY_TICKET_TTL_MS }));
  return `${PREFIX}.${body}.${sign(secret, body)}`;
}

/** 답장 표 검사 → `{ userId, roomId, deviceId, tokenVersion }` | null(모양·서명이 틀렸거나 기한이 지남). */
export function verifyReplyTicket(secret, ticket, now = Date.now()) {
  if (typeof ticket !== 'string' || ticket.length > 1024) return null;
  const parts = ticket.split('.');
  if (parts.length !== 3 || parts[0] !== PREFIX) return null;
  const [, body, mac] = parts;
  const expected = Buffer.from(sign(secret, body));
  const given = Buffer.from(mac);
  if (expected.length !== given.length || !crypto.timingSafeEqual(expected, given)) return null;
  let p;
  try {
    p = JSON.parse(Buffer.from(body, 'base64url').toString('utf8'));
  } catch {
    return null;
  }
  if (!p || typeof p.u !== 'string' || typeof p.r !== 'string' || typeof p.d !== 'string' || !Number.isFinite(p.e)) return null;
  if (p.e <= now) return null;
  return { userId: p.u, roomId: p.r, deviceId: p.d, tokenVersion: Number.isInteger(p.v) ? p.v : 0 };
}

/**
 * 이 채팅 푸시에 답장 칸을 둘지 — 새 메시지([kind] 'message')만. 댓글·멘션·공지는 답장이 어느 글에 붙을지 헷갈려서, 비밀 대화는 백그라운드에서
 * 암호화할 수 없어서(알림에도 내용 대신 "새 메시지가 있습니다"만 온다) 두지 않는다.
 */
export const replyAllowed = (kind, room) => kind === 'message' && !room?.isSecret;

/** 안 읽은 수를 하나 올리는 채팅 푸시 — 방의 안 읽은 수(메시지·댓글)에 들어가는 것. 멘션 푸시는 그 글의 메시지·댓글 푸시를 대신한다. */
const UNREAD_KINDS = new Set(['message', 'comment', 'mention', 'mention_all']);
export const unreadDeltaOf = (kind) => (UNREAD_KINDS.has(kind) ? 1 : 0);

/**
 * 홈 화면 위젯(client UnreadWidgetProvider.kt)이 그 방을 보일 이름 — 1:1은 보낸 사람, 그 밖에는 방 이름표([roomTag] — push.js roomTagFor),
 * 그것도 없으면 보낸 사람. 비밀 대화는 위젯이 이름 대신 "비밀 대화"로 보인다(isSecret).
 */
export function widgetNameOf(room, roomTag, senderName) {
  if (room?.type === 'dm' && !room.isSelf) return senderName ?? '';
  return roomTag ?? senderName ?? '';
}
