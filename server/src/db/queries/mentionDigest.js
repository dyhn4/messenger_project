import { and, desc, eq, gt, inArray, isNotNull, isNull, lt, or, sql } from 'drizzle-orm';
import { db } from '../client.js';
import { devices, notificationSettings, notifications, roomMembers, rooms, teams, users } from '../schema.js';

const MENTION_KINDS = ['mention', 'mention_all'];

/**
 * 멘션 요약 메일을 받을 수도 있는 사람들 — 이메일을 확인했고, 탈퇴·정지되지 않았고, 요약 메일을 끄지 않았고, 지난 요약이
 * [sentBefore]보다 오래됐고(또는 받은 적 없고), [since] 뒤에 온 안 읽은 멘션이 있는 사람. "오래 접속하지 않았는지"는 기기의
 * 마지막 접속까지 같이 봐야 해서 부르는 쪽(mentionDigestRules.js digestDue)이 거른다 — 그래서 그 값들을 함께 돌려준다.
 */
export async function listMentionDigestCandidates({ sentBefore, since }) {
  const deviceLastSeen = db
    .select({ userId: devices.userId, lastSeenAt: sql`max(${devices.lastSeenAt})`.as('device_last_seen') })
    .from(devices)
    .groupBy(devices.userId)
    .as('device_seen');
  const hasUnreadMention = sql`exists (
    select 1 from ${notifications}
    where ${notifications.userId} = ${users.id}
      and ${notifications.readAt} is null
      and ${notifications.kind} in ('mention', 'mention_all')
      and ${notifications.createdAt} > ${since}
  )`;
  return db
    .select({
      id: users.id,
      name: users.name,
      emailEnc: users.emailEnc,
      createdAt: users.createdAt,
      lastSeenAt: users.lastSeenAt,
      deviceLastSeenAt: deviceLastSeen.lastSeenAt,
      sentAt: users.mentionDigestSentAt,
      mentionAll: sql`coalesce(${notificationSettings.mentionAll}, true)`.mapWith(Boolean),
    })
    .from(users)
    .leftJoin(notificationSettings, eq(notificationSettings.userId, users.id))
    .leftJoin(deviceLastSeen, eq(deviceLastSeen.userId, users.id))
    .where(
      and(
        isNotNull(users.emailVerifiedAt),
        isNotNull(users.emailEnc),
        isNull(users.deletedAt),
        isNull(users.suspendedAt),
        sql`coalesce(${notificationSettings.emailDigest}, true)`,
        or(isNull(users.mentionDigestSentAt), lt(users.mentionDigestSentAt, sentBefore)),
        hasUnreadMention,
      ),
    );
}

/**
 * 요약에 넣을 이 사람의 안 읽은 멘션(최신순) — [since] 뒤에 온 것, 지금도 멤버인 방, 비밀 대화가 아닌 방만(비밀 대화 내용은
 * 서버도 모르고 메일로도 내보내지 않는다 — 원래 멘션 알림이 안 생기지만 한 번 더 막는다).
 */
export async function listUnreadMentionsForDigest(userId, since, limit = 500) {
  return db
    .select({
      kind: notifications.kind,
      roomName: notifications.roomName,
      actorName: notifications.actorName,
      preview: notifications.preview,
      createdAt: notifications.createdAt,
      teamName: teams.name,
    })
    .from(notifications)
    .innerJoin(rooms, and(eq(rooms.id, notifications.roomId), eq(rooms.isSecret, false)))
    .innerJoin(roomMembers, and(eq(roomMembers.roomId, notifications.roomId), eq(roomMembers.userId, notifications.userId)))
    .leftJoin(teams, eq(teams.id, notifications.teamId))
    .where(
      and(
        eq(notifications.userId, userId),
        isNull(notifications.readAt),
        inArray(notifications.kind, MENTION_KINDS),
        gt(notifications.createdAt, since),
      ),
    )
    .orderBy(desc(notifications.createdAt))
    .limit(limit);
}

/** 요약을 보냈다고 적는다. */
export async function markMentionDigestSent(userId, at = new Date()) {
  await db.update(users).set({ mentionDigestSentAt: at }).where(eq(users.id, userId));
}

/** 앱이 붙어 있던 시각을 적는다(socket.js — 붙을 때와 마지막 연결이 끊길 때). */
export async function touchUserLastSeen(userId, at = new Date()) {
  await db.update(users).set({ lastSeenAt: at }).where(eq(users.id, userId));
}
