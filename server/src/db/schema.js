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
  // 비밀번호 찾기 시 이메일 일치 확인에 더해 한 번 더 확인하는 보안 질문. 이 컬럼이 도입되기
  // 전에 가입한 계정은 null로 남아있고, reset-password에서는 null이면 답변 확인을 건너뛴다.
  securityQuestion: text('security_question'),
  securityAnswerHash: text('security_answer_hash'),
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
  // 비밀 대화(E2EE) 방인지 — 새 RoomType을 만들지 않고 dm 위에 얹는 플래그로 둔다(isPublic과
  // 같은 방식). true면 messages/messageComments.text는 클라이언트가 만든 암호문 JSON이다.
  isSecret: boolean('is_secret').notNull().default(false),
  // 비밀 대화에서 "상대방도 나가기"를 체크하지 않고 혼자 나간 경우, 남은 멤버 쪽 화면에서
  // Room.displayName()이 "(알 수 없음)" 대신 "OOO님 (나갔음)"을 보여줄 수 있도록 나간 사람의
  // 정보를 남겨둔다(비밀 대화 DM은 멤버가 2명뿐이라 한 명이 나가면 members에선 완전히
  // 빠지므로, 이 컬럼이 없으면 누가 나갔었는지 알 방법이 없다).
  secretDepartedMemberId: uuid('secret_departed_member_id'),
  secretDepartedMemberName: text('secret_departed_member_name'),
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
    // 알림 끄기도 마찬가지로 개인 설정 — 이 방을 뮤트한 멤버에게는 FCM 푸시를 안 보낸다(push.js).
    muted: boolean('muted').notNull().default(false),
    // 평문 DM의 "채팅방 숨기기"/"채팅방 나가기" — 멤버십은 그대로 두고 이 플래그만 켠다.
    // 원래는 removeRoomMember로 진짜 멤버를 뺐는데, DM은 멤버가 나+상대 둘뿐이라 그러면
    // 상대 쪽 화면에서 방 이름이 "(알 수 없음)"이 되고 상대가 보낸 메시지도 안 받게 되는
    // 문제가 있었다(내 소켓이 그 방에서 나가버림) — 상대에게는 아무 영향이 없어야 하므로
    // 이제 순전히 내 개인 설정으로만 다룬다(즐겨찾기/뮤트와 같은 방식). 상대가 새 메시지를
    // 보내면 서버가 자동으로 false로 되돌린다(rooms.js unhideDmForOtherMembers 참고).
    hidden: boolean('hidden').notNull().default(false),
  },
  (t) => [primaryKey({ columns: [t.roomId, t.userId] }), index('room_members_user_id_idx').on(t.userId)],
);

/**
 * DM(평문, 비밀 대화 아님)에서 "숨기기"가 아니라 진짜 "나가기"를 선택한 사람의 개인별 기록
 * 시작선. room_options_menu.dart의 나가기 대화상자에서 "나가기"를 체크하면(기본은 체크 안 함
 * = 숨기기) 이 테이블에 (roomId, userId) → 그 시각을 남긴다 — 나중에 상대가 다시 말을 걸어
 * 방이 복원돼도, 이 사람에게는 이 시각 이전 메시지/파일/검색 결과가 전부 안 보인다(rooms.js
 * getDmHistoryFloor 사용처 참고). "숨기기"는 이 테이블에 아무것도 안 남기므로 평소처럼 예전
 * 내용이 그대로 복원된다. 같은 사람이 나중에 또 진짜 나가기를 하면 시각만 최신으로 덮어쓴다
 * (upsert) — 그 사이 숨기기를 했더라도 이 시작선 자체는 그대로 유지된다.
 */
export const dmHistoryFloors = pgTable(
  'dm_history_floors',
  {
    roomId: text('room_id')
      .notNull()
      .references(() => rooms.id, { onDelete: 'cascade' }),
    userId: uuid('user_id')
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
    hiddenBeforeAt: timestamp('hidden_before_at', { withTimezone: true }).notNull(),
  },
  (t) => [primaryKey({ columns: [t.roomId, t.userId] })],
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
    // 이미지 메시지의 축소 미리보기(채팅 버블용). fileUrl은 항상 원본 그대로 두고, 이 컬럼은
    // 클라이언트가 미리 축소·재인코딩해서 별도로 올린 썸네일 경로다(없으면 null — 이미지가
    // 아니거나, 썸네일 생성에 실패해서 원본만 있는 경우). 비밀 대화면 이것도 원본과 마찬가지로
    // 암호화된 바이트를 가리킨다.
    thumbnailUrl: text('thumbnail_url'),
    createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
    // 작성 후 5분 이내 본인만 수정/삭제 가능(messages.js 참고). 삭제는 소프트 삭제 — 행은 남고
    // 내용만 비운다(댓글 스레드가 이 메시지를 계속 참조하기 때문).
    editedAt: timestamp('edited_at', { withTimezone: true }),
    deletedAt: timestamp('deleted_at', { withTimezone: true }),
    // 비밀 대화 자동 삭제 타이머용(secretExpiry.js 참고). readAt은 상대방이 실제로 이 메시지를
    // 본 시각(최초 1회만 기록), expiresAt은 그 시각 + 방의 selfDestructSeconds. 비밀 대화는
    // 항상 멤버가 2명뿐이라 별도 message_reads 조인 테이블 없이 컬럼 하나로 충분하다.
    readAt: timestamp('read_at', { withTimezone: true }),
    expiresAt: timestamp('expires_at', { withTimezone: true }),
    // "메시지 공유"(다른 방으로 원본을 인용) — 원본이 이 메시지와 다른 방(멤버가 아닐 수도
    // 있음)에 있을 수 있어 실시간 조인 대신 공유 당시의 스냅샷을 저장한다. 원본이 나중에
    // 수정/삭제돼도 공유된 인용문은 그대로 남고, 방을 넘나드는 권한 문제도 없다.
    quotedSenderName: text('quoted_sender_name'),
    quotedPreview: text('quoted_preview'),
    // "메시지 전달" — 전달 화면의 "포함" 토글을 켠 경우에만 채워진다(끄면 일반 메시지와
    // 완전히 동일해진다). 내용(text/fileUrl 등)은 별도 스냅샷 없이 이 메시지 자신의 필드에
    // 원본을 그대로 복사해서 넣는다(전달 전에 편집 가능).
    forwardedFromSenderName: text('forwarded_from_sender_name'),
    forwardedFromCreatedAt: timestamp('forwarded_from_created_at', { withTimezone: true }),
  },
  (t) => [
    index('messages_room_id_created_at_idx').on(t.roomId, t.createdAt),
    index('messages_sender_id_idx').on(t.senderId),
    index('messages_expires_at_idx').on(t.expiresAt),
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
    thumbnailUrl: text('thumbnail_url'), // messages.thumbnailUrl과 동일한 용도.
    createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
    // messages와 동일한 규칙: 작성 후 5분 이내 본인만 수정/삭제 가능(comments.js 참고). 삭제는
    // 소프트 삭제 — 행은 남기고 deletedAt만 찍는다(text/첨부는 그대로 두되 응답에서 가린다).
    editedAt: timestamp('edited_at', { withTimezone: true }),
    deletedAt: timestamp('deleted_at', { withTimezone: true }),
  },
  (t) => [index('message_comments_message_id_idx').on(t.messageId, t.createdAt)],
);

/**
 * 비밀 대화(E2EE)에 쓰는 기기 신원. deviceId는 클라이언트가 생성한 UUID(로그인 계정과 별개로
 * "이 기기"를 가리킴). identityPublicKey(X25519)/signingPublicKey(Ed25519)는 공개키만 저장 —
 * 개인키는 절대 서버에 오지 않는다(client/lib/services/device_identity.dart 참고).
 */
export const devices = pgTable(
  'devices',
  {
    id: text('id').primaryKey(),
    userId: uuid('user_id')
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
    name: text('name'),
    identityPublicKey: text('identity_public_key').notNull(),
    signingPublicKey: text('signing_public_key').notNull(),
    createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
    lastSeenAt: timestamp('last_seen_at', { withTimezone: true }),
    // 기기를 폐기(로그아웃/분실 신고 등)하면 이후 소켓 인증/비밀 대화 기능에서 거부된다.
    revokedAt: timestamp('revoked_at', { withTimezone: true }),
    // FCM 푸시 토큰(안드로이드 전용 — Windows는 FCM을 공식 지원하지 않아 항상 null).
    // 앱이 완전히 종료된 상태에서도 새 메시지를 알리기 위한 용도로, 소켓 연결이 없을 때만 쓴다.
    fcmToken: text('fcm_token'),
  },
  (t) => [index('devices_user_id_idx').on(t.userId)],
);

/**
 * 비밀 대화 방 하나당 하나. 서버는 여기 공개키/서명/상태값만 들고 있고, 실제 공유비밀·체인키는
 * 절대 서버에 오지 않는다(클라이언트가 로컬에서 유도해 flutter_secure_storage에만 저장).
 */
export const secretSessions = pgTable('secret_sessions', {
  roomId: text('room_id')
    .primaryKey()
    .references(() => rooms.id, { onDelete: 'cascade' }),
  initiatorUserId: uuid('initiator_user_id')
    .notNull()
    .references(() => users.id, { onDelete: 'cascade' }),
  initiatorDeviceId: text('initiator_device_id')
    .notNull()
    .references(() => devices.id, { onDelete: 'cascade' }),
  responderUserId: uuid('responder_user_id')
    .notNull()
    .references(() => users.id, { onDelete: 'cascade' }),
  responderDeviceId: text('responder_device_id').references(() => devices.id, { onDelete: 'cascade' }),
  status: text('status').notNull().default('pending'), // 'pending' | 'active' | 'rejected' | 'terminated'
  initiatorEphemeralPublicKey: text('initiator_ephemeral_public_key').notNull(),
  initiatorEphemeralSignature: text('initiator_ephemeral_signature').notNull(),
  responderEphemeralPublicKey: text('responder_ephemeral_public_key'),
  responderEphemeralSignature: text('responder_ephemeral_signature'),
  // 재키잉마다 1씩 증가 — 메시지 암호문 봉투의 epoch 필드와 대응(secretRekeys 이력 참고).
  keyEpoch: integer('key_epoch').notNull().default(0),
  // null이면 자동 삭제 꺼짐. 1~604800(1초~1주). 이후 읽는 메시지부터 적용된다.
  selfDestructSeconds: integer('self_destruct_seconds'),
  createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
  acceptedAt: timestamp('accepted_at', { withTimezone: true }),
});

/** 재키잉 제안/수락 이력(append-only) — 재연결 중 재키잉이 겹친 경우를 클라이언트가 따라잡는 용도. */
export const secretRekeys = pgTable(
  'secret_rekeys',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    roomId: text('room_id')
      .notNull()
      .references(() => rooms.id, { onDelete: 'cascade' }),
    keyEpoch: integer('key_epoch').notNull(),
    proposerUserId: uuid('proposer_user_id')
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
    proposerEphemeralPublicKey: text('proposer_ephemeral_public_key').notNull(),
    proposerEphemeralSignature: text('proposer_ephemeral_signature').notNull(),
    responderEphemeralPublicKey: text('responder_ephemeral_public_key'),
    responderEphemeralSignature: text('responder_ephemeral_signature'),
    status: text('status').notNull().default('proposed'), // 'proposed' | 'acked'
    createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [index('secret_rekeys_room_id_epoch_idx').on(t.roomId, t.keyEpoch)],
);
