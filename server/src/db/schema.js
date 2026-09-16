import { boolean, index, integer, pgTable, primaryKey, text, timestamp, uniqueIndex, uuid } from 'drizzle-orm/pg-core';

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
  /**
   * 계정 등급 — 'guest'(준회원) | 'member'(정회원) | 'admin'(관리자).
   * **서버 운영자만** 바꿀 수 있고(관리자 콘솔), 이 서버 전체에서 그 사람이 무엇을 할 수
   * 있는지를 정한다(방/팀 생성, 초대, 팀 관리, 콘텐츠 관리 — permissions.js 참고).
   * 회원가입하면 준회원으로 시작하므로, 운영자가 정회원 이상으로 올려줘야 정상 활동한다.
   *
   * 예전에는 이 등급이 팀마다 따로 있었지만(team_members.role), 한 사람이 팀마다 다른
   * 등급을 갖는 게 사내 메신저에는 오히려 헷갈려서 계정 단위로 올렸다. 팀 단위로 남은 것은
   * "그 팀의 소유자인지"뿐이다.
   */
  role: text('role').notNull().default('guest'),
  // 부서/직책을 계정 단위로 관리하는 설정(server_settings.orgScope='account')일 때 쓰는 값.
  // 'team'이면 team_members 쪽 값을 쓰고 여기는 안 쓴다.
  department: text('department'),
  position: text('position'),
  // 서버 전체 운영자(관리자 콘솔 접근 권한). 계정 등급(role)과도 별개로,
  // 회원 관리·팀 관리·감사 로그·운영 현황을 볼 수 있는 사람이다. 마이그레이션에서 가장 먼저
  // 가입한 계정에 표시되고, 이후에는 운영자가 다른 사람을 지정한다(admin.js 참고).
  isServerAdmin: boolean('is_server_admin').notNull().default(false),
  // 운영자가 계정을 정지시킨 시각. 찍혀 있으면 로그인/토큰 재발급/소켓 연결이 모두 막힌다
  // (탈퇴(deletedAt)와 달리 되돌릴 수 있고, 이름/메시지는 그대로 남는다).
  suspendedAt: timestamp('suspended_at', { withTimezone: true }),
  // 탈퇴한 사용자: deletedAt이 찍히면 로그인 차단 + 이름/이메일/프로필 익명화.
  deletedAt: timestamp('deleted_at', { withTimezone: true }),
  // 탈퇴 후 보존기간(1년) 만료로 메시지가 파기되면 찍힌다(retention.js) — 중복 파기 방지용.
  messagesPurgedAt: timestamp('messages_purged_at', { withTimezone: true }),
});

/**
 * 팀(워크스페이스). 사내 메신저라 한 서버 안에 여러 팀이 있을 수 있고, 방/조직도/검색/파일이
 * 전부 팀 단위로 나뉜다. 한 계정은 여러 팀에 속할 수 있다(team_members).
 * 팀을 만든 사람이 그 팀의 소유자가 된다(잔디와 동일 — 별도 소유자 비밀번호는 없다).
 */
export const teams = pgTable('teams', {
  id: uuid('id').primaryKey().defaultRandom(),
  name: text('name').notNull(),
  // 팀 아이콘 — 사용자 아바타와 같은 방식(이모지+배경색)으로 가볍게 시작한다.
  iconEmoji: text('icon_emoji'),
  iconColor: text('icon_color'),
  // 새 토픽을 만들 수 있는 최소 등급 — 'member'(정회원도 가능, 기본) | 'admin'(관리자만) |
  // 'owner'(소유자만) | 'designated'(아래 topicCreators에 콕 집어 등록된 사람만). 그룹채팅은
  // 이 설정과 무관하게 항상 정회원 이상 가능하다(permissions.js canCreateTopic 참고).
  topicCreationPolicy: text('topic_creation_policy').notNull().default('member'),
  // [메시지 설정] 메시지 수정/삭제 허용 여부. false면 그 팀에서는 아무도(소유자·관리자 포함)
  // 메시지/댓글을 고치거나 지울 수 없다 — 대화 기록을 그대로 남겨야 하는 팀을 위한 스위치.
  messageEditDeleteEnabled: boolean('message_edit_delete_enabled').notNull().default(true),
  // 작성 후 이 시간 안에서만 수정/삭제할 수 있다(초 단위). 기본 300초(5분) — 예전에 코드에
  // 박혀 있던 값과 같아서 설정을 안 건드리면 동작이 그대로다. 고를 수 있는 값은
  // permissions.js의 EDIT_DELETE_WINDOW_OPTIONS 참고.
  messageEditDeleteWindowSeconds: integer('message_edit_delete_window_seconds').notNull().default(300),
  createdBy: uuid('created_by').references(() => users.id, { onDelete: 'set null' }),
  createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
});

/**
 * 팀 멤버십. [role]은 이제 "그 팀의 소유자인지"만 나타낸다 — 'owner'(팀을 만든 사람) 또는
 * 'member'(그냥 멤버). 준회원/정회원/관리자 같은 **등급은 계정 단위**(users.role)로 올라갔고,
 * 서버 운영자만 바꾼다. 팀 설정을 바꿀 수 있는 사람은 "그 팀의 소유자 + 계정 등급이 관리자인
 * 사람"이다(permissions.js의 canManageTeam 참고).
 */
export const teamMembers = pgTable(
  'team_members',
  {
    teamId: uuid('team_id')
      .notNull()
      .references(() => teams.id, { onDelete: 'cascade' }),
    userId: uuid('user_id')
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
    role: text('role').notNull().default('member'), // 'owner' | 'member' (소유자 여부만)
    // 부서/직책 — server_settings.orgScope가 'team'일 때 쓰는 값(팀마다 다른 직책을 둘 수
    // 있다). 'account'면 users.department/position을 쓰고 여기는 안 쓴다.
    department: text('department'),
    position: text('position'),
    joinedAt: timestamp('joined_at', { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [primaryKey({ columns: [t.teamId, t.userId] }), index('team_members_user_id_idx').on(t.userId)],
);

/**
 * teams.topicCreationPolicy가 'designated'일 때만 의미가 있는, "이 팀에서 토픽을 만들어도
 * 되는 사람"으로 콕 집어 지정된 목록(정회원 이상 중에서 팀을 관리할 수 있는 사람이 고른다 —
 * team_settings_dialog.dart). 정책을 다른 값으로 바꿔도 이 목록 자체는 지우지 않는다 —
 * 나중에 다시 'designated'로 돌아오면 이전에 골라둔 사람들이 그대로 남아있는 편이 매번
 * 새로 고르는 것보다 편하다.
 */
export const topicCreators = pgTable(
  'topic_creators',
  {
    teamId: uuid('team_id')
      .notNull()
      .references(() => teams.id, { onDelete: 'cascade' }),
    userId: uuid('user_id')
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
  },
  (t) => [primaryKey({ columns: [t.teamId, t.userId] }), index('topic_creators_user_id_idx').on(t.userId)],
);

/**
 * 서버 운영자가 관리하는 "직책 목록" — 관리자 콘솔 "회원" 탭, 팀 설정의 "직책 수정", 프로필
 * 카드의 직책 수정, "팀 초대 링크"의 "부여할 직책"이 전부 이 목록에서 고르게 한다(자유 입력
 * 대신, 오탈자/표기 불일치 방지). orgScope(팀/계정 단위)와 무관하게 항상 이 목록을 쓴다 —
 * orgScope는 고른 값을 어디(users vs team_members)에 저장할지만 가른다.
 */
export const positionOptions = pgTable('position_options', {
  id: uuid('id').primaryKey().defaultRandom(),
  label: text('label').notNull().unique(),
  // 서열 — **작을수록 서열이 낮다**(기본 목록이 사원(0)→대표(7) 순으로 들어있는 것과 같은
  // 방향). 관리자 콘솔에서 직책을 클릭해 좌우로 옮기면 이웃과 값을 맞바꿔 이 순서를 조정한다.
  // 관리자 콘솔의 "직책 수정"(서버 운영자 전용)만 빼고, 나머지 모든 직책 부여 화면(팀 설정의
  // 직책 수정, 프로필 카드, 팀 초대 링크)은 "자신의 직책과 같거나 이 값이 더 작은(=서열이
  // 같거나 낮은) 직책만" 남에게 줄 수 있다 — 등급의 "자신보다 높은 등급 부여 불가"와 같은
  // 권한 상승 방지 규칙이다(server/src/teams.js, server/src/teamInvites.js).
  sortOrder: integer('sort_order').notNull().default(0),
  // 한 번에 하나만 true — 회원가입 시 이 직책이 자동으로 부여된다(auth.js).
  isDefault: boolean('is_default').notNull().default(false),
  createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
});

/**
 * 서버 전체 설정(항상 한 행만 있고 id는 늘 1). 팀 설정(teams)과 달리 서버 운영자만 바꾼다.
 * 값이 없으면(설치 직후) 기본값으로 동작하므로, 읽는 쪽은 행이 없을 수도 있다고 보고 다뤄야
 * 한다(db/queries/serverSettings.js의 getServerSettings 참고).
 */
export const serverSettings = pgTable('server_settings', {
  id: integer('id').primaryKey(),
  // 팀을 만들 수 있는 최소 계정 등급 — 'member'(정회원 이상, 기본) | 'admin'(관리자 이상) |
  // 'serverAdmin'(서버 운영자만). 준회원은 어느 값이든 팀을 만들 수 없다.
  teamCreation: text('team_creation').notNull().default('member'),
  // 팀 초대 링크(가입 시 팀 자동 합류 + 등급 자동 부여)를 만들 수 있는 최소 계정 등급 —
  // teamCreation과 같은 값 집합. 등급/팀 합류를 동시에 부여하는 힘이라 teamCreation보다
  // 기본값을 더 보수적으로(관리자 이상) 둔다.
  teamInviteLinkCreation: text('team_invite_link_creation').notNull().default('admin'),
  // 부서/직책을 어디에 두는지 — 'team'(기본, 팀마다 다르게: team_members) |
  // 'account'(계정 하나로: users). 회사 조직도가 하나뿐이면 'account'가 단순하다.
  orgScope: text('org_scope').notNull().default('team'),
  // FCM(푸시 알림) 설정 — 예전엔 클라이언트 빌드에 google-services.json을 박아넣고 서버
  // 파일로 firebase-service-account.json을 직접 놓아야 했는데, 이 제품을 여러 고객사에
  // 자체 호스팅으로 판매하면서 고객사마다 앱을 따로 빌드해줘야 하는 문제가 생겼다. 그래서
  // 클라이언트 초기화용 4개 값(apiKey/appId/projectId/messagingSenderId — Android 클라이언트
  // API 키는 패키지명+SHA-1로 제한돼 비밀값이 아니다)은 여기 DB에 두고 앱이 서버에서
  // 받아가게 하고(GET /firebase-client-config, push.js), 서버가 FCM을 보낼 때 쓰는 서비스
  // 계정 키(private_key 포함, 진짜 비밀값)도 관리자 콘솔에서 붙여넣어 여기 저장한다
  // (fcmServiceAccountJson). 그러면 APK 하나로 모든 고객사가 쓰고, 고객사가 자기 Firebase
  // 프로젝트 값을 스스로 입력하는 것으로 끝난다 — 벤더가 고객사 키를 받아 재빌드할 필요가
  // 없다(server/src/admin.js의 /admin/fcm-settings 참고).
  fcmApiKey: text('fcm_api_key'),
  fcmAppId: text('fcm_app_id'),
  fcmProjectId: text('fcm_project_id'),
  fcmMessagingSenderId: text('fcm_messaging_sender_id'),
  fcmServiceAccountJson: text('fcm_service_account_json'),
  updatedAt: timestamp('updated_at', { withTimezone: true }).notNull().defaultNow(),
});

/**
 * 감사 로그 — "누가 언제 무엇을 했는지"의 추가 전용 기록. 관리자 권한으로 한 일(남의 메시지
 * 삭제, 등급 변경, 팀원 제외, 팀 삭제, 계정 정지 등)만 남긴다. 일반 대화/메시지 작성은 남기지
 * 않는다(그건 메시지 자체가 기록이므로).
 *
 * actorId/teamId는 계정이나 팀이 지워져도 로그는 남아야 하므로 set null이고, 대신 그 시점의
 * 이름을 스냅샷으로 같이 저장한다(messages.senderName과 같은 방식).
 */
export const auditLogs = pgTable(
  'audit_logs',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    actorId: uuid('actor_id').references(() => users.id, { onDelete: 'set null' }),
    actorName: text('actor_name').notNull(),
    // 'message.delete' | 'comment.delete' | 'team.member.role' | 'team.member.remove' |
    // 'team.delete' | 'team.transferOwner' | 'user.suspend' | 'user.role' 등(audit.js의 AUDIT 참고).
    action: text('action').notNull(),
    teamId: uuid('team_id').references(() => teams.id, { onDelete: 'set null' }),
    teamName: text('team_name'),
    // 무엇에 대한 행위였는지 — 'user' | 'message' | 'comment' | 'team' | 'room'.
    targetType: text('target_type'),
    targetId: text('target_id'),
    targetLabel: text('target_label'), // 사람이 읽을 이름 스냅샷(사용자명/방 이름 등).
    detail: text('detail'), // "정회원 → 관리자"처럼 한 줄 설명.
    createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [index('audit_logs_created_at_idx').on(t.createdAt), index('audit_logs_actor_id_idx').on(t.actorId)],
);

/**
 * 초대 링크 — "설치→가입"을 한 번에 되게 해주는 링크. 팀 합류는 여기 포함하지 않는다
 * (합류는 항상 소유자·관리자가 팀 설정 → 팀원 추가에서 수동으로 한다).
 *
 * 링크가 실제로 해주는 일은 딱 하나 — 아직 이 서버를 모르는 기기가 자체 서명 인증서를
 * 받아서 신뢰하게 만드는 것(pairing.js의 기존 페어링 코드와 완전히 같은 메커니즘을 공유한다).
 * 회원가입 자체는 이미 누구나 열려 있어서 별도 토큰이 필요 없다.
 *
 * token은 사람이 외워서 입력하는 4자리 페어링 코드와 달리 사람이 직접 입력할 일이 거의
 * 없고(복사해서 붙여넣거나 링크를 그대로 열음) 훨씬 오래(기본 7일) 살아있어야 하므로,
 * 무작위 대입을 막기 위해 충분히 긴 무작위 문자열로 만든다(pairing.js 참고).
 */
export const inviteLinks = pgTable(
  'invite_links',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    token: text('token').notNull().unique(),
    createdBy: uuid('created_by').references(() => users.id, { onDelete: 'set null' }),
    createdByName: text('created_by_name').notNull(), // 만든 사람이 탈퇴해도 남는 이름 스냅샷.
    label: text('label'), // "9월 신입"처럼 관리자가 구분하려고 붙이는 메모. 선택.
    expiresAt: timestamp('expires_at', { withTimezone: true }).notNull(),
    revokedAt: timestamp('revoked_at', { withTimezone: true }),
    // 여러 기기(여러 신입)가 같은 링크로 나눠 받을 수 있어 1회용이 아니다 — 매번 쓸 때마다 갱신.
    usedCount: integer('used_count').notNull().default(0),
    lastUsedAt: timestamp('last_used_at', { withTimezone: true }),
    createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [index('invite_links_created_by_idx').on(t.createdBy)],
);

/**
 * 팀 초대 링크 — 위 inviteLinks("설치→가입")와 달리 **가입과 동시에 특정 팀에 자동
 * 합류시키고 계정 등급까지 자동으로 부여한다**. 서버 운영자가 회원 등급을 일일이 올려주는
 * 번거로움을 줄이기 위한 기능이라, 만들 수 있는 사람은 server_settings.teamInviteLinkCreation
 * 최소 등급을 만족해야 한다(permissions.js의 canCreateTeamInviteLink).
 *
 * assignedRole은 users.role과 같은 값 집합('guest'|'member'|'admin')이지만, isServerAdmin은
 * 여기서 절대 부여하지 않는다 — 서버 운영자 지정은 관리자 콘솔에서만(admin.js) 하도록 남겨둔
 * 기존 설계("등급이 아니라 isServerAdmin 하나로만 한다")를 그대로 따른다.
 *
 * 나머지 필드/메커니즘(token, 만료, 폐기, 다회 사용)은 inviteLinks와 동일하다.
 */
export const teamInviteLinks = pgTable(
  'team_invite_links',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    token: text('token').notNull().unique(),
    teamId: uuid('team_id').notNull().references(() => teams.id, { onDelete: 'cascade' }),
    assignedRole: text('assigned_role').notNull().default('member'),
    // 직책 목록(position_options)의 label 중 하나(선택 사항) — 가입과 동시에 이 직책도
    // 부여한다. 만든 사람의 직책보다 서열이 높은 값은 서버가 거부한다(teamInvites.js).
    assignedPosition: text('assigned_position'),
    createdBy: uuid('created_by').references(() => users.id, { onDelete: 'set null' }),
    createdByName: text('created_by_name').notNull(),
    label: text('label'),
    expiresAt: timestamp('expires_at', { withTimezone: true }).notNull(),
    revokedAt: timestamp('revoked_at', { withTimezone: true }),
    usedCount: integer('used_count').notNull().default(0),
    lastUsedAt: timestamp('last_used_at', { withTimezone: true }),
    createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [
    index('team_invite_links_created_by_idx').on(t.createdBy),
    index('team_invite_links_team_id_idx').on(t.teamId),
  ],
);

export const rooms = pgTable(
  'rooms',
  {
    // 'general'이라는 리터럴 문자열 시드 방이 있어서 uuid가 아니라 text.
    id: text('id').primaryKey(),
    // 이 방이 속한 팀. 방/검색/파일/조직도가 전부 팀 단위로 갈리는 기준점이다.
    teamId: uuid('team_id')
      .notNull()
      .references(() => teams.id, { onDelete: 'cascade' }),
    type: text('type').notNull(), // 'topic' | 'group' | 'dm'
    name: text('name'),
    description: text('description'),
    isPublic: boolean('is_public'), // 토픽에서만 의미 있음.
    // DM 두 명의 정렬된 id 쌍 — 같은 DM 중복 생성 방지. 팀이 생기면서 "팀 안에서만" 유일해야
    // 한다(같은 두 사람이 팀 A와 팀 B에서 각각 1:1 대화를 가질 수 있다) — 그래서 컬럼 단독
    // unique가 아니라 (team_id, dm_key) 복합 unique로 둔다(아래 uniqueIndex).
    dmKey: text('dm_key'),
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
  },
  (t) => [
    index('rooms_team_id_idx').on(t.teamId),
    uniqueIndex('rooms_team_id_dm_key_idx').on(t.teamId, t.dmKey),
  ],
);

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
    // 공지 안읽음(알림 센터) 전용 — 메시지 lastReadAt과 별개다. 방에 들어와 있기만 해도
    // lastReadAt은 계속 올라가버려서, 그걸 그대로 쓰면 배너만 보고 실제로 "공지" 화면을 열어본
    // 적 없어도 읽음 처리돼버린다. 그래서 공지 목록/상세를 실제로 열었을 때만
    // (announcements.js, socket.js의 announcement:read) 이 값을 갱신한다.
    lastReadAnnouncementAt: timestamp('last_read_announcement_at', { withTimezone: true }),
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

/**
 * 토픽방 공지 — 카카오톡 공지와 같은 개념. 여러 개를 쓸 수 있고(히스토리로 남음), **가장
 * 최근에 쓴 것이 자동으로 "지금 고정된 공지"**가 된다(별도 "고정" 토글은 없다 — rooms.js의
 * latestAnnouncementForRoom이 createdAt 최신 1건을 그 방의 고정 공지로 쓴다). 수정/삭제는
 * 지금 범위 밖 — 잘못 쓰면 새로 하나 더 쓰는 것으로 대신한다.
 */
export const announcements = pgTable(
  'announcements',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    roomId: text('room_id')
      .notNull()
      .references(() => rooms.id, { onDelete: 'cascade' }),
    authorId: uuid('author_id').references(() => users.id, { onDelete: 'set null' }),
    authorName: text('author_name').notNull(),
    text: text('text').notNull(),
    // 한 방에 pinned=true인 행은 최대 하나뿐이다 — 그게 채팅방 상단 배너/목록의 "고정됨"이다.
    // 새 공지를 쓰면 기존 pinned 행을 자동으로 내리고 새 글이 pinned=true가 된다(announcements.js
    // insertAnnouncement). "공지 내리기"는 삭제하지 않고 이 값만 false로 바꾼다 — 히스토리에는
    // 남지만 배너에선 사라진다(그리고 그 뒤로 자동으로 다른 글이 다시 고정되지 않는다).
    pinned: boolean('pinned').notNull().default(true),
    createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
    editedAt: timestamp('edited_at', { withTimezone: true }),
    deletedAt: timestamp('deleted_at', { withTimezone: true }),
  },
  (t) => [index('announcements_room_id_created_at_idx').on(t.roomId, t.createdAt)],
);

/** 공지에 달린 댓글 — message_comments와 같은 모양이지만 부모가 메시지가 아니라 공지다.
 * 수정/삭제는 지원하지 않는다(공지 댓글은 단순 의견 남기기 용도로만 요청받았다). */
export const announcementComments = pgTable(
  'announcement_comments',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    announcementId: uuid('announcement_id')
      .notNull()
      .references(() => announcements.id, { onDelete: 'cascade' }),
    roomId: text('room_id')
      .notNull()
      .references(() => rooms.id, { onDelete: 'cascade' }), // 조인 없이 방 기준 필터링하려고 중복 보관.
    authorId: uuid('author_id').references(() => users.id, { onDelete: 'set null' }),
    authorName: text('author_name').notNull(),
    text: text('text').notNull(),
    createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [index('announcement_comments_announcement_id_idx').on(t.announcementId, t.createdAt)],
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
