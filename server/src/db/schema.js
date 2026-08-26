import { boolean, index, integer, pgTable, primaryKey, text, timestamp, uuid } from 'drizzle-orm/pg-core';

/**
 * 스키마의 원본(source of truth). `npm run db:generate`가 이 파일을 이전 스냅샷과 비교해서
 * server/drizzle/에 SQL 마이그레이션을 자동 생성한다 — 여기를 고치면 항상 그것부터 하고,
 * 손으로 SQL을 직접 쓰지 않는다.
 */

export const users = pgTable('users', {
  id: uuid('id').primaryKey().defaultRandom(),
  username: text('username').notNull().unique(),
  name: text('name').notNull(),
  // 이메일은 암호화 저장(emailEnc) + 조회용 해시(emailLookup)로 나뉜다 — crypto.js 참고.
  emailEnc: text('email_enc'),
  emailLookup: text('email_lookup').unique(),
  passwordHash: text('password_hash').notNull(),
  // 로그아웃/비밀번호 변경/탈퇴 시 기존 토큰을 한꺼번에 무효화하는 데 쓴다.
  tokenVersion: integer('token_version').notNull().default(0),
  avatarType: text('avatar_type').notNull().default('initial'),
  avatarEmoji: text('avatar_emoji'),
  avatarColor: text('avatar_color'),
  avatarUrl: text('avatar_url'),
  createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
  // 탈퇴한 사용자: deletedAt이 찍히면 로그인 차단 + 이름/이메일/프로필 익명화.
  deletedAt: timestamp('deleted_at', { withTimezone: true }),
  // 탈퇴 후 보존기간(1년) 만료로 메시지가 파기되면 찍힌다(retention.js) — 중복 파기 방지용.
  messagesPurgedAt: timestamp('messages_purged_at', { withTimezone: true }),
});

export const rooms = pgTable('rooms', {
  // 'general'이라는 리터럴 문자열 시드 방이 있어서 uuid가 아니라 text.
  id: text('id').primaryKey(),
  type: text('type').notNull(), // 'topic' | 'group' | 'dm'
  name: text('name'),
  description: text('description'),
  isPublic: boolean('is_public'), // 토픽에서만 의미 있음.
  dmKey: text('dm_key').unique(), // DM 두 명의 정렬된 id 쌍 — 같은 DM 중복 생성 방지.
  createdBy: text('created_by'),
  createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
});

/** 방 멤버십 + 그 사람이 그 방을 마지막으로 읽은 시각을 한 테이블로 합친다(멤버가 아니면 읽음
 * 기록도 의미가 없으므로 예전 room.lastRead 맵을 여기 흡수). */
export const roomMembers = pgTable(
  'room_members',
  {
    roomId: text('room_id')
      .notNull()
      .references(() => rooms.id, { onDelete: 'cascade' }),
    userId: uuid('user_id')
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
    lastReadAt: timestamp('last_read_at', { withTimezone: true }),
    // 즐겨찾기는 그 사람 혼자만의 표시 설정이라 방 자체가 아니라 멤버십에 붙는다.
    favorite: boolean('favorite').notNull().default(false),
  },
  (t) => [primaryKey({ columns: [t.roomId, t.userId] }), index('room_members_user_id_idx').on(t.userId)],
);

export const messages = pgTable(
  'messages',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    roomId: text('room_id')
      .notNull()
      .references(() => rooms.id, { onDelete: 'cascade' }),
    // null이면 시스템 메시지(예전의 senderId: 'system' 문자열 센티널 대신). type='system'이
    // 이미 판별 기준이라 표시 로직은 안 바뀐다.
    senderId: uuid('sender_id').references(() => users.id, { onDelete: 'set null' }),
    senderName: text('sender_name').notNull(),
    type: text('type').notNull(), // 'text' | 'image' | 'file' | 'system'
    text: text('text'),
    fileUrl: text('file_url'),
    fileName: text('file_name'),
    fileSize: integer('file_size'),
    mimeType: text('mime_type'),
    createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
    // 작성 후 5분 이내 본인만 수정/삭제 가능(messages.js 참고). 삭제는 소프트 삭제 — 행은 남고
    // 내용만 비운다(댓글 스레드가 이 메시지를 계속 참조하기 때문).
    editedAt: timestamp('edited_at', { withTimezone: true }),
    deletedAt: timestamp('deleted_at', { withTimezone: true }),
  },
  (t) => [
    index('messages_room_id_created_at_idx').on(t.roomId, t.createdAt),
    index('messages_sender_id_idx').on(t.senderId),
  ],
);

/** 특정 메시지에 달린 댓글(스레드 답글). */
export const messageComments = pgTable(
  'message_comments',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    messageId: uuid('message_id')
      .notNull()
      .references(() => messages.id, { onDelete: 'cascade' }),
    roomId: text('room_id')
      .notNull()
      .references(() => rooms.id, { onDelete: 'cascade' }), // 조인 없이 방 기준 필터링하려고 중복 보관.
    // messages.senderId와 동일 규칙: 탈퇴해도 댓글 자체는 남고 senderId만 null이 된다.
    senderId: uuid('sender_id').references(() => users.id, { onDelete: 'set null' }),
    senderName: text('sender_name').notNull(),
    type: text('type').notNull().default('text'), // 'text' | 'image' | 'file' — messages.type과 동일 규칙.
    text: text('text'), // 첨부만 있고 캡션이 없는 댓글도 있어서 nullable(messages.text와 동일).
    fileUrl: text('file_url'),
    fileName: text('file_name'),
    fileSize: integer('file_size'),
    mimeType: text('mime_type'),
    createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
    // messages와 동일한 규칙: 작성 후 5분 이내 본인만 수정/삭제 가능(comments.js 참고). 삭제는
    // 소프트 삭제 — 행은 남기고 deletedAt만 찍는다(text/첨부는 그대로 두되 응답에서 가린다).
    editedAt: timestamp('edited_at', { withTimezone: true }),
    deletedAt: timestamp('deleted_at', { withTimezone: true }),
  },
  (t) => [index('message_comments_message_id_idx').on(t.messageId, t.createdAt)],
);
