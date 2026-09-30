import { boolean, index, integer, jsonb, pgTable, primaryKey, text, timestamp, uniqueIndex, uuid } from 'drizzle-orm/pg-core';

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
  // 팀 아이콘 — 사용자 아바타와 같은 방식(이모지+배경색, 둘 다 없으면 이름 앞 2글자 이니셜).
  // iconUrl(업로드한 사진, 미서명 /uploads/ 경로)이 있으면 그게 우선이다.
  iconEmoji: text('icon_emoji'),
  iconColor: text('icon_color'),
  iconUrl: text('icon_url'),
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
  // 프로젝트를 만들 수 있는 최소 계정 등급 — teamCreation과 같은 값 집합
  // ('member' | 'admin' | 'serverAdmin'). 준회원은 어느 값이든 만들 수 없다.
  projectCreation: text('project_creation').notNull().default('member'),
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
    // 그룹채팅 아이콘 — 만들 때만 고를 수 있다(new_chat_screen.dart). 'members'(기본값, null과
    // 동일 취급 — 기존처럼 멤버 아바타 두 개를 겹쳐 보여줌) | 'initial'(그룹 이름 앞 2글자) |
    // 'emoji'(iconEmoji 사용, 팀과 안 겹치는 별도 이모지 목록) | 'photo'(iconUrl — 업로드한
    // 사진의 미서명 /uploads/ 경로). iconColor는 initial·emoji의 배경색(room_avatar.dart
    // 참고). 토픽/DM은 이 컬럼들을 쓰지 않는다(항상 null).
    iconType: text('icon_type'),
    iconEmoji: text('icon_emoji'),
    iconColor: text('icon_color'),
    iconUrl: text('icon_url'),
    // ── 아래는 토픽에서만 의미가 있다(그룹/DM은 항상 기본값) ──
    // 보기 방식 — 'chat'(챗 뷰, 메시지를 주고받는 대화방) | 'board'(보드 뷰, 제목 있는 게시글만
    // 올리는 게시판 — messages.type = 'post'). 이미 쌓인 글의 모양이 달라서 만든 뒤에는 못 바꾼다.
    viewMode: text('view_mode').notNull().default('chat'),
    // 읽기 전용 — 토픽을 관리할 수 있는 사람(토픽 관리자·팀 관리자)만 글을 쓴다(socket.js).
    // 댓글은 계속 달 수 있다(공지 아래 질문·답글은 막지 않기로 함).
    readOnly: boolean('read_only').notNull().default(false),
    // 정회원 자동 초대 — 새로 팀에 들어오는 정회원 이상을 이 토픽에 자동으로 넣는다(teams.js).
    // 공개 토픽에서만 의미가 있어 비공개면 항상 false로 둔다.
    autoInvite: boolean('auto_invite').notNull().default(false),
    // 조용히 나가기 — 멤버가 나가거나 내보내져도 "OOO 님이 나갔습니다/내보냈습니다" 안내를 안 남긴다.
    quietLeave: boolean('quiet_leave').notNull().default(false),
    // 토픽 보관 — 찍혀 있으면 목록의 '보관된 토픽'으로 옮겨지고 읽기 전용처럼 동작한다(내용은 그대로).
    archivedAt: timestamp('archived_at', { withTimezone: true }),
    // 나와의 대화 — 팀마다 사람마다 하나씩 있는, 나 혼자만 멤버인 DM(type 'dm', dmKey '{나}:{나}').
    // 메모·파일 보관용이라 초대·나가기·숨기기 등은 막고(rooms.js), 팀 관리자 알림도 여기로 온다.
    isSelf: boolean('is_self').notNull().default(false),
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
    // 그룹채팅방 이름을 "나에게만" 다르게 부르는 개인 별칭 — 방 자체의 name은 그대로고 다른
    // 멤버에게는 영향이 없다(즐겨찾기/뮤트와 같은 방식). null이면 원래 이름을 쓴다.
    customName: text('custom_name'),
    // 평문 DM의 "채팅방 숨기기"/"채팅방 나가기" — 멤버십은 그대로 두고 이 플래그만 켠다.
    // 원래는 removeRoomMember로 진짜 멤버를 뺐는데, DM은 멤버가 나+상대 둘뿐이라 그러면
    // 상대 쪽 화면에서 방 이름이 "(알 수 없음)"이 되고 상대가 보낸 메시지도 안 받게 되는
    // 문제가 있었다(내 소켓이 그 방에서 나가버림) — 상대에게는 아무 영향이 없어야 하므로
    // 이제 순전히 내 개인 설정으로만 다룬다(즐겨찾기/뮤트와 같은 방식). 상대가 새 메시지를
    // 보내면 서버가 자동으로 false로 되돌린다(rooms.js unhideDmForOtherMembers 참고).
    hidden: boolean('hidden').notNull().default(false),
    // 토픽 안에서의 역할 — 'admin'(토픽 관리자, 여러 명 가능) | 'member'. 토픽을 만든 사람이
    // 'admin'으로 시작한다. 팀 관리자는 이 값과 무관하게 모든 토픽을 관리할 수 있다
    // (permissions.js canManageTopic). 그룹/DM은 항상 'member'.
    role: text('role').notNull().default('member'),
  },
  (t) => [primaryKey({ columns: [t.roomId, t.userId] }), index('room_members_user_id_idx').on(t.userId)],
);

/**
 * 사이드바 토픽 폴더 — **개인 설정**이라 사람마다(팀마다) 따로 만든다(project_folders와 같은
 * 방식). 폴더를 지워도 안에 있던 토픽은 그대로 두고 폴더 밖 목록으로 돌아간다(topic_folder_items만
 * cascade).
 */
export const topicFolders = pgTable(
  'topic_folders',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    teamId: uuid('team_id')
      .notNull()
      .references(() => teams.id, { onDelete: 'cascade' }),
    userId: uuid('user_id')
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
    name: text('name').notNull(),
    position: integer('position').notNull().default(0),
    // 접어둔 폴더인지 — PC와 모바일에서 같은 모양으로 보이도록 서버에 둔다.
    collapsed: boolean('collapsed').notNull().default(false),
    createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [index('topic_folders_user_team_idx').on(t.userId, t.teamId)],
);

/** 어느 토픽을 내 어느 폴더에 넣었는지 — 한 토픽은 내 폴더 중 하나에만 들어간다. 토픽에서
 * 나가거나 내보내지면 그 사람의 행도 같이 지운다(rooms.js). */
export const topicFolderItems = pgTable(
  'topic_folder_items',
  {
    folderId: uuid('folder_id')
      .notNull()
      .references(() => topicFolders.id, { onDelete: 'cascade' }),
    roomId: text('room_id')
      .notNull()
      .references(() => rooms.id, { onDelete: 'cascade' }),
    userId: uuid('user_id')
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
  },
  (t) => [
    uniqueIndex('topic_folder_items_user_room_idx').on(t.userId, t.roomId),
    index('topic_folder_items_folder_idx').on(t.folderId),
  ],
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
    type: text('type').notNull(), // 'text' | 'image' | 'file' | 'sticker' | 'system' | 'post'(보드 뷰 게시글)
    // 보드 뷰 게시글(type = 'post')의 제목 — 본문은 text, 첨부는 message_attachments. 그 밖의 메시지는 null.
    title: text('title'),
    text: text('text'),
    // 글자 서식 구간 — [{s, e, f, h?}] (textFormat.js 참고). 본문은 평문 그대로라 미리보기·검색은 그대로 쓴다.
    textFormat: jsonb('text_format'),
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
    // 링크 미리보기(오픈그래프) — 텍스트 메시지에 URL이 있으면 서버가 백그라운드로 그 페이지의
    // og:title/og:description/og:image/og:site_name을 긁어와 채운다(linkPreview.js). 메시지
    // 전송 자체는 이 결과를 기다리지 않고, 나중에 결과가 오면 message:linkPreview로 따로
    // 브로드캐스트한다(editedAt은 안 건드린다 — 사용자가 수정한 게 아니므로 "(수정됨)" 표시가
    // 붙으면 안 된다).
    linkPreviewUrl: text('link_preview_url'),
    linkPreviewTitle: text('link_preview_title'),
    linkPreviewDescription: text('link_preview_description'),
    linkPreviewImageUrl: text('link_preview_image_url'),
    linkPreviewSiteName: text('link_preview_site_name'),
    // "팀장에게 문의하기"로 보낸 메시지 표시용(inquiries.js) — true면 클라이언트가 일반
    // 텍스트 옆에 "문의함 바로가기" 링크를 붙여서 누르면 그 문의로 바로 이동한다.
    isInquiryNotice: boolean('is_inquiry_notice').notNull().default(false),
    inquiryId: uuid('inquiry_id').references(() => inquiries.id, { onDelete: 'set null' }),
    // 보드 뷰에서 "게시글 고정"한 시각 — 토픽을 관리할 수 있는 사람만 고정/해제한다(messages.js).
    // 고정 목록은 이 시각이 아니라 게시글 작성 시각 최신순으로 보여준다.
    pinnedAt: timestamp('pinned_at', { withTimezone: true }),
  },
  (t) => [
    index('messages_room_id_created_at_idx').on(t.roomId, t.createdAt),
    index('messages_sender_id_idx').on(t.senderId),
    index('messages_expires_at_idx').on(t.expiresAt),
  ],
);

/** 메시지 하나에 딸린 첨부들. 예전에는 messages.fileUrl 한 칸에 첨부 하나만 넣었는데,
 * 사진 여러 장을 한 말풍선에 격자로 보여주려면 여러 개가 필요해서 따로 뺐다.
 *
 * 예전 메시지에는 이 행이 없다 — 그때는 messages의 fileUrl/fileName/thumbnailUrl을 그대로
 * 첨부 하나로 본다(messages.js의 toMessageDto 참고). 새로 보내는 메시지는 첫 번째 첨부를
 * messages 쪽에도 그대로 넣어둔다(파일 모아보기·검색·알림 미리보기가 그 칸을 쓰고 있다). */
export const messageAttachments = pgTable(
  'message_attachments',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    messageId: uuid('message_id')
      .notNull()
      .references(() => messages.id, { onDelete: 'cascade' }),
    // 'image' | 'file'
    kind: text('kind').notNull(),
    fileUrl: text('file_url').notNull(),
    fileName: text('file_name'),
    fileSize: integer('file_size'),
    mimeType: text('mime_type'),
    thumbnailUrl: text('thumbnail_url'),
    position: integer('position').notNull().default(0),
  },
  (t) => [index('message_attachments_message_id_idx').on(t.messageId, t.position)],
);

/** 사람마다 따로 담아두는 "즐겨찾기한 파일". 대화방 즐겨찾기(rooms.favorite)와 달리 첨부
 * 단위이고, 메시지가 지워지면 같이 사라진다. 어떤 첨부인지는 메시지 + 파일 경로로 가린다
 * (예전 메시지는 message_attachments 행이 없어서 id로는 못 가리킨다). */
export const favoriteFiles = pgTable(
  'favorite_files',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    userId: uuid('user_id')
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
    messageId: uuid('message_id')
      .notNull()
      .references(() => messages.id, { onDelete: 'cascade' }),
    fileUrl: text('file_url').notNull(),
    fileName: text('file_name'),
    createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [uniqueIndex('favorite_files_user_file_idx').on(t.userId, t.messageId, t.fileUrl)],
);

/**
 * 메시지 예약 발송 — 정한 시각(15분 단위, 최대 90일 뒤)에 서버가 대신 보낸다(scheduledMessages.js).
 * 만든 사람만 보고 고칠 수 있다. 보내고 나면 행을 지우고, 못 보냈으면 'failed' + 이유로 남겨 목록의
 * '발송 실패'에 보여준다. 'sending'은 발송 중에 잠깐 거치는 상태(두 번 보내지 않도록 먼저 찜한다).
 * 방이 지워져도 행은 남겨 실패로 알려야 해서 roomId는 set null이고, 표시용 방 이름을 따로 둔다.
 * attachments는 채팅 첨부와 같은 모양 [{id, kind, fileUrl, fileName, fileSize, mimeType, thumbnailUrl}]
 * (미서명 /uploads/ 경로 — 응답에 낼 때만 서명한다).
 */
export const scheduledMessages = pgTable(
  'scheduled_messages',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    teamId: uuid('team_id')
      .notNull()
      .references(() => teams.id, { onDelete: 'cascade' }),
    roomId: text('room_id').references(() => rooms.id, { onDelete: 'set null' }),
    roomName: text('room_name'),
    userId: uuid('user_id')
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
    // 보드 뷰 토픽에 올릴 게시글의 제목 — 그 밖의 방은 null.
    title: text('title'),
    text: text('text').notNull(),
    textFormat: jsonb('text_format'),
    attachments: jsonb('attachments').notNull().default([]),
    sendAt: timestamp('send_at', { withTimezone: true }).notNull(),
    // 'scheduled' | 'sending' | 'failed'
    status: text('status').notNull().default('scheduled'),
    failReason: text('fail_reason'),
    createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
    updatedAt: timestamp('updated_at', { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [
    index('scheduled_messages_user_team_idx').on(t.userId, t.teamId),
    index('scheduled_messages_status_send_at_idx').on(t.status, t.sendAt),
  ],
);

/**
 * 토픽방 공지 — 카카오톡 공지와 같은 개념. 여러 개를 쓸 수 있고(히스토리로 남음), pinned인
 * 것(방마다 최대 1개)이 "지금 고정된 공지"다. 작성 본인만 수정/삭제/내리기를 할 수 있다
 * (announcements.js의 requireOwnAnnouncement).
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
    // "공지 자동 내리기" — 작성 시점에 고른 시간이 지나면 announcementAutoUnpin.js의 주기적
    // 스윕이 "공지 내리기"와 똑같이 pinned를 false로 바꾼다(수동 내리기와 동일 이벤트로
    // 브로드캐스트). null이면 자동으로 안 내려간다(기본값).
    autoUnpinAt: timestamp('auto_unpin_at', { withTimezone: true }),
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

/**
 * "팀장에게 문의하기" — 팀원이 자기 팀의 "팀장" 직책인 사람에게만 보낼 수 있는 문의(미니
 * 티켓). 실제 대화는 그 DM방(roomId)에 일반 메시지로도 남지만(chat_input_bar.dart가 문의
 * API 호출과 별개로 메시지도 보낸다), 이 테이블은 "누가 누구에게 언제 무슨 문의를 보냈고
 * 지금 처리 상태가 어떤지"만 따로 추적한다 — 대화 목록에 묻혀 놓치지 않도록.
 */
export const inquiries = pgTable(
  'inquiries',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    teamId: uuid('team_id')
      .notNull()
      .references(() => teams.id, { onDelete: 'cascade' }),
    roomId: text('room_id')
      .notNull()
      .references(() => rooms.id, { onDelete: 'cascade' }),
    senderId: uuid('sender_id').references(() => users.id, { onDelete: 'set null' }),
    senderName: text('sender_name').notNull(),
    recipientId: uuid('recipient_id').references(() => users.id, { onDelete: 'set null' }),
    recipientName: text('recipient_name').notNull(),
    category: text('category').notNull(),
    title: text('title').notNull(),
    content: text('content').notNull(),
    // 'open'(대기) | 'in_progress'(처리중) | 'resolved'(완료) — 받는 사람(팀장)만 바꿀 수 있다.
    status: text('status').notNull().default('open'),
    createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
    statusUpdatedAt: timestamp('status_updated_at', { withTimezone: true }),
    // 첨부(선택) — 클라이언트가 /api/upload로 먼저 올린 뒤 그 결과 URL만 여기 저장한다
    // (messages 테이블의 첨부 컬럼과 같은 방식). 없으면 전부 null.
    fileUrl: text('file_url'),
    fileName: text('file_name'),
    fileSize: integer('file_size'),
    mimeType: text('mime_type'),
    thumbnailUrl: text('thumbnail_url'),
  },
  (t) => [
    index('inquiries_recipient_id_idx').on(t.recipientId, t.status),
    index('inquiries_sender_id_idx').on(t.senderId),
  ],
);

/**
 * 프로젝트 — 토픽(대화방)이 "주제별 대화"라면, 프로젝트는 "업무를 계획·추적하는 공간"이다.
 * 대화방과 완전히 별개의 테이블이라 방 목록/검색/파일에는 전혀 안 섞인다. 방과 마찬가지로
 * 팀에 속하고(teamId), 초대된 사람(project_members)만 볼 수 있다.
 */
export const projects = pgTable(
  'projects',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    teamId: uuid('team_id')
      .notNull()
      .references(() => teams.id, { onDelete: 'cascade' }),
    name: text('name').notNull(),
    description: text('description'),
    // 업무 번호 앞에 붙는 짧은 식별자(예: 'MKT' → MKT-1001). 팀 안에서 유일해야 한다.
    identifier: text('identifier').notNull(),
    // 사이드바/카드에서 프로젝트를 구분해 주는 대표 색('#RRGGBB').
    color: text('color').notNull().default('#5B8DEF'),
    // 공개 프로젝트 — 팀 안의 정회원 이상 모두가 참여 절차 없이 자동으로 구성원이 된다
    // (project_members.auto). 비공개(기본)는 초대받은 구성원만 볼 수 있다.
    isPublic: boolean('is_public').notNull().default(false),
    // 다음에 만들 업무에 줄 번호. 업무를 지워도 번호를 재사용하지 않도록 프로젝트에 들고 있다
    // (tasks에서 MAX(seq)+1로 계산하면 삭제 후 번호가 겹친다).
    // 다음 업무 번호 — 1001부터 네 자리로 매긴다("MKT-1001").
    nextTaskSeq: integer('next_task_seq').notNull().default(1001),
    // 다음 노트 번호("MKT-N10"의 10) — 업무 번호와 따로 센다.
    nextNoteSeq: integer('next_note_seq').notNull().default(1),
    // 이 프로젝트를 만든(또는 이 프로젝트를 저장해 만든) 프로젝트 템플릿 — 설정 > 필드 / 상태의
    // "업무 템플릿" 칸에 그 카드를 보여 주는 데만 쓴다. 템플릿을 지우면 null로 돌아간다.
    templateId: uuid('template_id').references(() => projectTemplates.id, { onDelete: 'set null' }),
    // 노트 수정·삭제 권한 — 'all'(구성원 모두) | 'creator_admin'(작성자 본인과 프로젝트 관리자만).
    // 기본값은 이 설정이 생기기 전 동작 그대로 — 수정은 누구나, 삭제는 작성자와 관리자만(0068).
    noteEditPermission: text('note_edit_permission').notNull().default('all'),
    noteDeletePermission: text('note_delete_permission').notNull().default('creator_admin'),
    createdBy: uuid('created_by').references(() => users.id, { onDelete: 'set null' }),
    createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
    archivedAt: timestamp('archived_at', { withTimezone: true }),
  },
  (t) => [
    index('projects_team_id_idx').on(t.teamId),
    uniqueIndex('projects_team_identifier_idx').on(t.teamId, t.identifier),
  ],
);

/**
 * 프로젝트 구성원. [role]은 팀 멤버십과 같은 방식으로 'owner'(만든 사람 = 프로젝트 담당자)
 * 또는 'member'다 — 프로젝트 설정/삭제는 담당자와 팀 소유자·관리자만 할 수 있다.
 * [favorite]은 개인 설정(사이드바 "즐겨찾기")이라 사람마다 다르다(room_members.favorite와 동일).
 */
export const projectMembers = pgTable(
  'project_members',
  {
    projectId: uuid('project_id')
      .notNull()
      .references(() => projects.id, { onDelete: 'cascade' }),
    userId: uuid('user_id')
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
    role: text('role').notNull().default('member'), // 'owner' | 'member'
    favorite: boolean('favorite').notNull().default(false),
    // 공개 프로젝트라서 자동으로 들어온 행이면 true(초대·생성으로 들어온 사람은 false).
    // 비공개로 바뀌면 이 표시가 있는 일반 구성원만 빠지고, 초대받은 사람·담당자는 남는다.
    auto: boolean('auto').notNull().default(false),
    createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [primaryKey({ columns: [t.projectId, t.userId] }), index('project_members_user_id_idx').on(t.userId)],
);

/**
 * 사이드바 프로젝트 폴더 — **개인 설정**이라 사람마다(팀마다) 따로 만든다. 폴더를 지워도
 * 안에 있던 프로젝트는 그대로 두고 폴더 밖 목록으로 돌아간다(project_folder_items만 cascade).
 */
export const projectFolders = pgTable(
  'project_folders',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    teamId: uuid('team_id')
      .notNull()
      .references(() => teams.id, { onDelete: 'cascade' }),
    userId: uuid('user_id')
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
    name: text('name').notNull(),
    position: integer('position').notNull().default(0),
    // 접어둔 폴더인지 — 다른 기기에서도 같은 모양으로 보이도록 서버에 둔다.
    collapsed: boolean('collapsed').notNull().default(false),
    createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [index('project_folders_user_team_idx').on(t.userId, t.teamId)],
);

/** 어느 프로젝트를 내 어느 폴더에 넣었는지 — 한 프로젝트는 내 폴더 중 하나에만 들어간다. */
export const projectFolderItems = pgTable(
  'project_folder_items',
  {
    folderId: uuid('folder_id')
      .notNull()
      .references(() => projectFolders.id, { onDelete: 'cascade' }),
    projectId: uuid('project_id')
      .notNull()
      .references(() => projects.id, { onDelete: 'cascade' }),
    userId: uuid('user_id')
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
  },
  (t) => [
    uniqueIndex('project_folder_items_user_project_idx').on(t.userId, t.projectId),
    index('project_folder_items_folder_idx').on(t.folderId),
  ],
);

/** 프로젝트 안의 업무(태스크). 화면에 보이는 번호는 `<프로젝트 identifier>-<seq>`로 만든다. */
/**
 * 업무 유형(Bug/Feature/행사 등) — 프로젝트마다 이름과 색을 직접 관리한다. 유형을 지워도 업무는
 * 남고 유형만 비워진다(on delete set null).
 */
export const taskTypes = pgTable(
  'task_types',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    projectId: uuid('project_id')
      .notNull()
      .references(() => projects.id, { onDelete: 'cascade' }),
    name: text('name').notNull(),
    // '#RRGGBB' — 화면에서 뱃지 배경/글자색으로 쓴다.
    color: text('color').notNull().default('#607D8B'),
    position: integer('position').notNull().default(0),
    createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [uniqueIndex('task_types_project_name_idx').on(t.projectId, t.name)],
);

/**
 * 프로젝트별 업무 상태 — 이름/색은 자유지만 반드시 세 분류(category) 중 하나에 속한다.
 * 진행률·완료 집계·"내 업무" 등 기존 로직은 tasks.status(=분류)만 보므로, 상태를 마음대로
 * 추가해도 통계가 깨지지 않는다. 칸반보드의 열이 이 목록이다.
 */
export const taskStatuses = pgTable(
  'task_statuses',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    projectId: uuid('project_id')
      .notNull()
      .references(() => projects.id, { onDelete: 'cascade' }),
    name: text('name').notNull(),
    color: text('color').notNull().default('#94A3B8'),
    // 'todo' | 'doing' | 'done'
    category: text('category').notNull().default('todo'),
    position: integer('position').notNull().default(0),
    createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [uniqueIndex('task_statuses_project_name_idx').on(t.projectId, t.name)],
);

/**
 * 프로젝트별 업무 우선순위 — 이름/색은 자유지만 반드시 세 단계(level) 중 하나에 속한다.
 * 정렬·대시보드 통계·자동화 조건은 tasks.priority(=level)만 보므로, 우선순위를 마음대로
 * 추가해도 기존 로직이 깨지지 않는다(task_statuses와 같은 방식).
 */
export const taskPriorities = pgTable(
  'task_priorities',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    projectId: uuid('project_id')
      .notNull()
      .references(() => projects.id, { onDelete: 'cascade' }),
    name: text('name').notNull(),
    color: text('color').notNull().default('#94A3B8'),
    // 'low' | 'normal' | 'high'
    level: text('level').notNull().default('normal'),
    position: integer('position').notNull().default(0),
    createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [uniqueIndex('task_priorities_project_name_idx').on(t.projectId, t.name)],
);

/** 프로젝트별 사용자 정의 필드 정의 — 값은 tasks.custom_values(jsonb)에 {필드id: 값}으로 저장한다. */
export const taskFields = pgTable(
  'task_fields',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    projectId: uuid('project_id')
      .notNull()
      .references(() => projects.id, { onDelete: 'cascade' }),
    name: text('name').notNull(),
    // 'text' | 'number' | 'date' | 'select'
    kind: text('kind').notNull().default('text'),
    // kind가 'select'일 때의 선택지(문자열 배열).
    options: jsonb('options').notNull().default([]),
    position: integer('position').notNull().default(0),
    createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [uniqueIndex('task_fields_project_name_idx').on(t.projectId, t.name)],
);

export const tasks = pgTable(
  'tasks',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    projectId: uuid('project_id')
      .notNull()
      .references(() => projects.id, { onDelete: 'cascade' }),
    // 프로젝트 안에서의 업무 번호(projects.nextTaskSeq에서 받아온다).
    seq: integer('seq').notNull(),
    title: text('title').notNull(),
    description: text('description'),
    // 담당자 — 아직 안 정했으면 null(대시보드의 "내가 담당한 업무"에는 안 잡힌다).
    assigneeId: uuid('assignee_id').references(() => users.id, { onDelete: 'set null' }),
    // 'todo'(할 일) | 'doing'(진행 중) | 'done'(완료). 칸반보드의 열과 1:1로 맞춘다(다음 단계).
    status: text('status').notNull().default('todo'),
    // 'low' | 'normal'(기본) | 'high'
    priority: text('priority').notNull().default('normal'),
    // 업무 유형 — 없으면 null. 프로젝트별 task_types 중 하나.
    typeId: uuid('type_id').references(() => taskTypes.id, { onDelete: 'set null' }),
    // 프로젝트별 상태(task_statuses) — status(분류)는 항상 이 상태의 category와 같게 유지한다.
    statusId: uuid('status_id').references(() => taskStatuses.id, { onDelete: 'set null' }),
    // 프로젝트별 우선순위(task_priorities) — priority(단계)는 항상 이 우선순위의 level과 같다.
    priorityId: uuid('priority_id').references(() => taskPriorities.id, { onDelete: 'set null' }),
    // 사용자 정의 필드 값 {fieldId: 값}.
    customValues: jsonb('custom_values').notNull().default({}),
    startDate: timestamp('start_date', { withTimezone: true }),
    dueDate: timestamp('due_date', { withTimezone: true }),
    createdBy: uuid('created_by').references(() => users.id, { onDelete: 'set null' }),
    createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
    updatedAt: timestamp('updated_at', { withTimezone: true }),
    completedAt: timestamp('completed_at', { withTimezone: true }),
    // "마감 임박" 알림을 이미 보낸 마감일 — dueDate와 다르면(마감일이 바뀌면) 다시 보낸다.
    dueRemindedFor: timestamp('due_reminded_for', { withTimezone: true }),
    // 하위 업무면 부모 업무. 하위 업무도 자기 번호·상태·담당자를 갖는 온전한 업무이고,
    // 이 칸만 부모를 가리킨다(부모를 지우면 하위 업무도 같이 지워진다).
    // AnyPgColumn 주석은 self-reference라 타입 추론이 순환하는 걸 끊어주는 용도다.
    parentTaskId: uuid('parent_task_id').references(() => tasks.id, { onDelete: 'cascade' }),
    // 보관한 시각 — 값이 있으면 목록에서 빠지고 "보관된 업무" 필터로만 보인다.
    archivedAt: timestamp('archived_at', { withTimezone: true }),
    // 칸반 열 안에서의 순서(0부터, 작을수록 위). 아직 한 번도 옮기지 않은 업무는 null(열 맨 아래).
    boardPosition: integer('board_position'),
  },
  (t) => [
    index('tasks_project_id_idx').on(t.projectId, t.status),
    index('tasks_assignee_id_idx').on(t.assigneeId, t.dueDate),
    index('tasks_parent_id_idx').on(t.parentTaskId),
    uniqueIndex('tasks_project_seq_idx').on(t.projectId, t.seq),
  ],
);

/** 업무 하나에 딸린 체크리스트 항목. 진행률은 업무 상세에만 보여주고 전체/대시보드 집계에는
 * 넣지 않는다(체크리스트는 그 업무를 하는 사람의 메모에 가깝다). */
export const taskChecklistItems = pgTable(
  'task_checklist_items',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    taskId: uuid('task_id')
      .notNull()
      .references(() => tasks.id, { onDelete: 'cascade' }),
    text: text('text').notNull(),
    done: boolean('done').notNull().default(false),
    position: integer('position').notNull().default(0),
    createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [index('task_checklist_task_id_idx').on(t.taskId, t.position)],
);

/** 업무 카드에 달린 댓글. [projectId]는 "최근 댓글"을 프로젝트 기준으로 모을 때 조인을 피하려고 같이 둔다. */
/** 업무 참조자 — 담당자는 아니지만 알고 있어야 하는 사람들. "내 업무"에 담당 업무와 같이 뜬다. */
export const taskReferences = pgTable(
  'task_references',
  {
    taskId: uuid('task_id')
      .notNull()
      .references(() => tasks.id, { onDelete: 'cascade' }),
    userId: uuid('user_id')
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
  },
  (t) => [primaryKey({ columns: [t.taskId, t.userId] }), index('task_references_user_idx').on(t.userId)],
);

/** 프로젝트 노트 — 프로젝트 구성원이 같이 쓰고 고치는 문서(회의록·가이드 등). */
export const projectNotes = pgTable(
  'project_notes',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    projectId: uuid('project_id')
      .notNull()
      .references(() => projects.id, { onDelete: 'cascade' }),
    title: text('title').notNull(),
    body: text('body').notNull().default(''),
    // 프로젝트 안에서의 노트 번호(projects.nextNoteSeq에서 받아온다) — "MKT-N10".
    seq: integer('seq'),
    createdBy: uuid('created_by').references(() => users.id, { onDelete: 'set null' }),
    updatedBy: uuid('updated_by').references(() => users.id, { onDelete: 'set null' }),
    createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
    updatedAt: timestamp('updated_at', { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [index('project_notes_project_idx').on(t.projectId, t.updatedAt)],
);

/** 프로젝트 알림함 — 업무 배정/참조/댓글/상태 변경/마감 임박 알림(받는 사람마다 한 줄). */
export const projectNotifications = pgTable(
  'project_notifications',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    userId: uuid('user_id')
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
    projectId: uuid('project_id')
      .notNull()
      .references(() => projects.id, { onDelete: 'cascade' }),
    taskId: uuid('task_id').references(() => tasks.id, { onDelete: 'cascade' }),
    // 'assigned' | 'referenced' | 'comment' | 'status' | 'due' | 'project_created'(공개 프로젝트 생성, task 없음) 등
    kind: text('kind').notNull(),
    title: text('title').notNull(),
    body: text('body').notNull(),
    actorId: uuid('actor_id').references(() => users.id, { onDelete: 'set null' }),
    createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
    readAt: timestamp('read_at', { withTimezone: true }),
  },
  (t) => [index('project_notifications_user_idx').on(t.userId, t.createdAt)],
);

/**
 * 프로젝트 알림 정책 — 프로젝트 담당자·팀 관리자가 정하고 **그 프로젝트의 모든 멤버에게**
 * 적용된다. 여기서 끈 종류는 아무에게도 알림이 가지 않는다(행이 없으면 전부 켜짐).
 * 개인이 더 조용히 받고 싶으면 projectNotificationSettings.muted로 자기 것만 끈다.
 */
export const projectNotificationPolicies = pgTable('project_notification_policies', {
  projectId: uuid('project_id')
    .primaryKey()
    .references(() => projects.id, { onDelete: 'cascade' }),
  // 업무 변경 — 담당자/참조자에게
  onStatus: boolean('on_status').notNull().default(true),
  onPriority: boolean('on_priority').notNull().default(true),
  onAssigned: boolean('on_assigned').notNull().default(true),
  onReferenced: boolean('on_referenced').notNull().default(true),
  onDueDate: boolean('on_due_date').notNull().default(true),
  onTaskType: boolean('on_task_type').notNull().default(true),
  onCustomField: boolean('on_custom_field').notNull().default(true),
  // 업무 생성·삭제 — 프로젝트 담당자(와 삭제된 업무의 담당자)에게
  onCreated: boolean('on_created').notNull().default(true),
  onDeleted: boolean('on_deleted').notNull().default(true),
  // 댓글 — 담당자/생성자/참조자에게
  onComment: boolean('on_comment').notNull().default(true),
  // 마감 임박 — 담당자에게
  onDue: boolean('on_due').notNull().default(true),
});

/** 사람 × 프로젝트별 개인 설정 — 지금은 "이 프로젝트 알림 끄기" 하나뿐이다. */
export const projectNotificationSettings = pgTable(
  'project_notification_settings',
  {
    userId: uuid('user_id')
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
    projectId: uuid('project_id')
      .notNull()
      .references(() => projects.id, { onDelete: 'cascade' }),
    // true면 이 프로젝트의 알림을 나만 전부 받지 않는다(정책과 별개).
    muted: boolean('muted').notNull().default(false),
  },
  (t) => [primaryKey({ columns: [t.userId, t.projectId] })],
);

/** 업무 템플릿 — "새 업무"에서 불러와 제목/설명/우선순위/유형/담당자/마감(오늘+N일)을 미리 채운다. */
/**
 * 프로젝트 템플릿(팀 공유) — 프로젝트의 상태·유형·우선순위·사용자 정의 필드 구성을 저장해 두고,
 * 새 프로젝트를 만들 때 기본값 대신 이 구성으로 채운다. 만든 프로젝트는 projects.templateId로
 * 어느 템플릿에서 왔는지만 기억하고 구성은 따로 논다(템플릿을 고치거나 지워도 프로젝트는 그대로).
 * statuses: [{name, color, category}], types: [{name, color}], priorities: [{name, color, level}],
 * fields: [{name, kind, options: [문자열]}] — 각 배열의 순서가 곧 표시 순서다.
 */
export const projectTemplates = pgTable(
  'project_templates',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    teamId: uuid('team_id')
      .notNull()
      .references(() => teams.id, { onDelete: 'cascade' }),
    name: text('name').notNull(),
    description: text('description'),
    statuses: jsonb('statuses').notNull().default([]),
    types: jsonb('types').notNull().default([]),
    priorities: jsonb('priorities').notNull().default([]),
    fields: jsonb('fields').notNull().default([]),
    createdBy: uuid('created_by').references(() => users.id, { onDelete: 'set null' }),
    createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
    updatedAt: timestamp('updated_at', { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [index('project_templates_team_idx').on(t.teamId, t.createdAt)],
);

export const taskTemplates = pgTable(
  'task_templates',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    projectId: uuid('project_id')
      .notNull()
      .references(() => projects.id, { onDelete: 'cascade' }),
    name: text('name').notNull(),
    title: text('title').notNull().default(''),
    description: text('description'),
    priority: text('priority').notNull().default('normal'),
    typeId: uuid('type_id').references(() => taskTypes.id, { onDelete: 'set null' }),
    assigneeId: uuid('assignee_id').references(() => users.id, { onDelete: 'set null' }),
    // 등록일로부터 며칠 뒤가 마감인지 — 없으면 마감일을 안 채운다.
    dueOffsetDays: integer('due_offset_days'),
    createdBy: uuid('created_by').references(() => users.id, { onDelete: 'set null' }),
    createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [uniqueIndex('task_templates_project_name_idx').on(t.projectId, t.name)],
);

/**
 * 프로젝트 자동화 규칙 — "업무가 만들어졌을 때 / 상태가 바뀌었을 때"(+조건) → 동작들을 실행한다.
 * trigger: 'task_created' | 'status_changed'(triggerStatusId가 있으면 그 상태로 바뀔 때만).
 * condition: {priority?, typeId?} — 있으면 업무가 일치할 때만.
 * actions: [{kind, ...}] — kind: set_assignee{userId} | set_status{statusId} | set_priority{priority}
 *          | add_reference{userId} | add_comment{text} | notify{userId}
 * 자동화가 일으킨 변화는 다시 자동화를 부르지 않는다(무한 반복 방지).
 * graph가 있으면 노드 편집기로 만든 규칙이다(트리거 → IF 조건 → 액션 그래프, projectAutomation.js).
 * 그때 trigger는 트리거 노드의 종류이고 triggerStatusId·condition·actions는 쓰지 않는다.
 */
export const projectAutomations = pgTable(
  'project_automations',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    projectId: uuid('project_id')
      .notNull()
      .references(() => projects.id, { onDelete: 'cascade' }),
    name: text('name').notNull(),
    enabled: boolean('enabled').notNull().default(true),
    trigger: text('trigger').notNull(),
    triggerStatusId: uuid('trigger_status_id').references(() => taskStatuses.id, { onDelete: 'cascade' }),
    condition: jsonb('condition').notNull().default({}),
    actions: jsonb('actions').notNull().default([]),
    // {nodes: [{id, kind, type, config, x, y}], edges: [{from, port, to}]} — null이면 예전 방식 규칙.
    graph: jsonb('graph'),
    createdBy: uuid('created_by').references(() => users.id, { onDelete: 'set null' }),
    createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [index('project_automations_project_idx').on(t.projectId)],
);

/** 노트 댓글. */
export const noteComments = pgTable(
  'note_comments',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    noteId: uuid('note_id')
      .notNull()
      .references(() => projectNotes.id, { onDelete: 'cascade' }),
    senderId: uuid('sender_id').references(() => users.id, { onDelete: 'set null' }),
    senderName: text('sender_name').notNull(),
    text: text('text').notNull(),
    // 글자 서식 구간(messages.textFormat과 동일).
    textFormat: jsonb('text_format'),
    // 답글이면 그 댓글(한 단계까지만). 댓글을 지우면 답글도 지워진다.
    parentCommentId: uuid('parent_comment_id').references(() => noteComments.id, { onDelete: 'cascade' }),
    createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
    editedAt: timestamp('edited_at', { withTimezone: true }),
  },
  (t) => [index('note_comments_note_idx').on(t.noteId, t.createdAt)],
);

/** 노트 수정 이력 — 고치기 직전의 제목/본문을 한 줄씩 남긴다(노트당 최근 30개). */
export const noteVersions = pgTable(
  'note_versions',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    noteId: uuid('note_id')
      .notNull()
      .references(() => projectNotes.id, { onDelete: 'cascade' }),
    title: text('title').notNull(),
    body: text('body').notNull().default(''),
    // 이 버전을 쓴 사람과 그 시각(= 바뀌기 전 노트의 updatedBy/updatedAt).
    editedBy: uuid('edited_by').references(() => users.id, { onDelete: 'set null' }),
    editedAt: timestamp('edited_at', { withTimezone: true }).notNull(),
  },
  (t) => [index('note_versions_note_idx').on(t.noteId, t.editedAt)],
);

/** 자동화 실행 기록 — 규칙이 언제 어떤 업무에 무엇을 했는지(프로젝트당 최근 100개). */
export const automationRuns = pgTable(
  'automation_runs',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    projectId: uuid('project_id')
      .notNull()
      .references(() => projects.id, { onDelete: 'cascade' }),
    automationName: text('automation_name').notNull(),
    taskId: uuid('task_id').references(() => tasks.id, { onDelete: 'set null' }),
    taskKey: text('task_key'),
    trigger: text('trigger').notNull(),
    // 실행한 동작들을 한 줄로 요약(예: "담당자 지정 → 댓글 남기기").
    summary: text('summary').notNull(),
    ok: boolean('ok').notNull().default(true),
    createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [index('automation_runs_project_idx').on(t.projectId, t.createdAt)],
);

export const taskComments = pgTable(
  'task_comments',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    taskId: uuid('task_id')
      .notNull()
      .references(() => tasks.id, { onDelete: 'cascade' }),
    projectId: uuid('project_id')
      .notNull()
      .references(() => projects.id, { onDelete: 'cascade' }),
    // messages.senderId와 같은 규칙 — 탈퇴해도 댓글은 남고 senderId만 null이 된다.
    senderId: uuid('sender_id').references(() => users.id, { onDelete: 'set null' }),
    senderName: text('sender_name').notNull(),
    text: text('text').notNull(),
    // 답글이면 그 댓글. 답글에는 다시 답글을 달 수 없다(한 단계까지). 댓글을 지우면 답글도 지워진다.
    parentCommentId: uuid('parent_comment_id').references(() => taskComments.id, { onDelete: 'cascade' }),
    // 글자 서식 구간(messages.textFormat과 동일).
    textFormat: jsonb('text_format'),
    createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
    // 수정한 시각 — 값이 있으면 "(수정됨)"을 붙인다.
    editedAt: timestamp('edited_at', { withTimezone: true }),
  },
  (t) => [index('task_comments_task_id_idx').on(t.taskId, t.createdAt), index('task_comments_project_id_idx').on(t.projectId, t.createdAt)],
);

/** 업무 기록 — 업무 상세의 "기록" 탭. 누가 언제 무엇을 바꿨는지 한 줄 문장으로 남긴다. */
export const taskActivities = pgTable(
  'task_activities',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    taskId: uuid('task_id')
      .notNull()
      .references(() => tasks.id, { onDelete: 'cascade' }),
    actorId: uuid('actor_id').references(() => users.id, { onDelete: 'set null' }),
    actorName: text('actor_name').notNull(),
    // 예: "상태를 '진행 중'(으)로 변경했습니다."
    text: text('text').notNull(),
    // 무엇에 대한 기록인지 — 'created' | 'status' | 'title' | 'description' | null(그 밖의 항목).
    // 기록 탭이 'created'·'status'를 상태 구간의 머리줄로 쓰고, 제목·설명은 새 내용을 상자로 보여준다.
    kind: text('kind'),
    // 바뀐 뒤의 값 — 제목·설명은 새 글, 상태는 상태 이름.
    detail: text('detail'),
    // 바뀌기 전 값 — 제목은 이전 제목, 상태는 이전 상태 이름(기록 탭의 "이전 › 새" 표시).
    previous: text('previous'),
    // 상태 기록의 상태 색(#RRGGBB) — 그때 색으로 남겨 둔다.
    color: text('color'),
    createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [index('task_activities_task_idx').on(t.taskId, t.createdAt)],
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
    textFormat: jsonb('text_format'), // messages.textFormat과 동일.
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
