/**
 * 권한 판정 규칙만 모아둔 곳. 자세한 설명은 README.md의 "권한 등급" 참고.
 *
 * 축이 두 개다:
 *  1. **계정 등급**(users.role) — 준회원/정회원/관리자. **서버 운영자만** 바꾼다.
 *     이 서버에서 그 사람이 무엇을 할 수 있는지의 기본값이고, 어느 팀에 있든 똑같다.
 *  2. **팀 소유자**(team_members.role === 'owner') — 그 팀을 만든 사람(또는 이양받은 사람).
 *  그리고 이 둘과 별개로 **서버 운영자**(users.is_server_admin)가 관리자 콘솔을 쓴다.
 *
 * 다른 모듈(teams/rooms/messages/comments/admin)은 반드시 여기 함수를 통해서만 판단한다 —
 * 규칙이 라우터마다 흩어지면 "관리자가 어디까지 할 수 있는지"가 금방 어긋나기 때문이다.
 * 이 파일은 아무것도 import하지 않는 순수 모듈이라 어느 라우터에서 가져다 써도 순환 참조가 없다.
 */

/** 계정 등급(서버 운영자가 지정). 위로 갈수록 강하다. */
export const ACCOUNT_ROLES = ['guest', 'member', 'admin'];

/** 등급 서열(숫자가 클수록 강함) — "나보다 위/같은 등급은 못 건드린다" 판정에 쓴다. */
export const ROLE_RANK = { guest: 0, member: 1, admin: 2 };

/** 모르는 값이 들어와도 가장 약한 등급으로 떨어뜨린다(새 등급을 먼저 배포해도 안전하도록). */
export function accountRole(user) {
  const role = user?.role;
  return ACCOUNT_ROLES.includes(role) ? role : 'guest';
}

/**
 * 팀 설정(이름·도메인·아이콘·초대 권한·메시지 설정)과 팀원 추가/제외를 할 수 있는지.
 * **그 팀의 소유자**이거나 **계정 등급이 관리자**면 된다.
 */
export function canManageTeam({ role, isOwner }) {
  return isOwner === true || role === 'admin';
}

/**
 * 초대 링크(설치→가입 링크)를 만들 수 있는지 — 서버 운영자, 계정 등급 관리자, 또는
 * 어느 팀이든 소유자인 사람. 팀 합류는 이 링크에 포함되지 않으므로(합류는 항상 소유자·
 * 관리자가 팀 설정에서 수동으로 한다) 여기서는 팀 범위를 따지지 않는다.
 */
export function canCreateInviteLink({ role, isServerAdmin, isOwnerOfAnyTeam }) {
  return isServerAdmin === true || role === 'admin' || isOwnerOfAnyTeam === true;
}

/**
 * 방(토픽/그룹/1:1)을 새로 만들거나 공개 토픽을 찾아 참여할 수 있는 등급인지.
 * 준회원은 초대받은 방에서만 활동하므로 어떤 방도 스스로 만들 수 없다.
 * 준회원에게 말을 거는 것 자체는 막지 않는다 — 정회원이 준회원과 1:1 대화를 시작하는 건 된다.
 */
export function canCreateRooms(role) {
  return role === 'member' || role === 'admin';
}

/** 공개 토픽을 찾아보고 스스로 참여할 수 있는 등급인지. */
export function canBrowseTopics(role) {
  return canCreateRooms(role);
}

/**
 * 새 토픽을 만들 수 있는지 — 팀 설정(topicCreationPolicy)이 정한 최소 등급을 넘어야 한다.
 * 'member'(기본)면 정회원 이상, 'admin'이면 그 팀을 관리할 수 있는 사람만, 'owner'면 그 팀의
 * 소유자만, 'designated'면 팀 관리자가 콕 집어 고른 사람만(db/queries/teams.js의
 * topicCreators — DB 조회가 필요해서 여기(순수 모듈)서는 판정 못 하고, 호출부가 미리 조회해
 * [isDesignatedTopicCreator]로 넘겨준다). **그룹채팅은 이 설정과 무관하게 항상 정회원
 * 이상이면 만들 수 있다**(canCreateRooms) — 토픽은 팀 전체에 공개되는 채널이라 만드는 사람을
 * 제한할 수 있어야 하지만, 그룹은 만든 사람이 스스로 고른 소수만 들어오는 사적인 대화라
 * 제한할 이유가 약하기 때문이다.
 */
export const TOPIC_CREATION_LEVELS = ['member', 'admin', 'owner', 'designated'];

export function canCreateTopic({ role, isOwner, isDesignatedTopicCreator, team }) {
  switch (team?.topicCreationPolicy) {
    case 'owner':
      return isOwner === true;
    case 'admin':
      return canManageTeam({ role, isOwner });
    case 'designated':
      return isDesignatedTopicCreator === true;
    default: // 'member'
      return canCreateRooms(role);
  }
}

/**
 * 토픽을 관리할 수 있는지(정보·설정 변경, 보관, 삭제, 멤버 내보내기, 토픽 관리자 지정, 게시글
 * 고정) — 그 토픽의 **토픽 관리자**(room_members.role === 'admin', 여러 명 가능)이거나 **팀
 * 관리자**(canManageTeam). 실제로는 여기에 더해 **그 토픽의 멤버**여야 한다(access.js의
 * topicAccess가 함께 판단) — 초대받지 않은 비공개 토픽은 팀 관리자도 볼 수 없으므로
 * canModerateContent와 같은 원칙이다.
 */
export function canManageTopic({ role, isOwner, isTopicAdmin }) {
  // 준회원은 토픽 관리자가 될 수 없다(rooms.js PUT /rooms/:id/admins) — 토픽 관리자였다가 준회원으로
  // 내려간 사람의 행이 혹시 남아 있어도 관리 권한으로 치지 않는다.
  return (isTopicAdmin === true && role !== 'guest') || canManageTeam({ role, isOwner });
}

/**
 * 읽기 전용이거나 보관된 토픽에 글을 쓰려 할 때의 거절 문구 — 쓸 수 있으면 null. 두 경우 모두
 * 토픽을 관리할 수 있는 사람([canManage])만 쓸 수 있다. 댓글은 여기 해당하지 않는다(멤버도
 * 공지성 글 아래에 질문·답글은 달 수 있게 하기로 함 — comments.js는 이 검사를 안 한다).
 */
export function topicWriteDenial({ room, canManage }) {
  if (room?.type !== 'topic' || canManage) return null;
  if (room.archivedAt) return '보관된 토픽에서는 토픽 관리자만 글을 쓸 수 있습니다.';
  if (room.readOnly) return '읽기 전용 토픽에서는 토픽 관리자만 글을 쓸 수 있습니다.';
  return null;
}

/**
 * 남의 메시지/댓글을 지울 수 있는지(콘텐츠 관리) — 팀을 관리할 수 있는 사람과 같다.
 * 실제로 지우려면 여기에 더해 **그 방의 멤버**여야 하고, **팀이 정한 수정/삭제 가능 시간
 * 안**이어야 한다 — 초대받지 않은 비공개 토픽/그룹/1:1 대화는 관리자도 볼 수 없고 관리할
 * 수도 없다. 비밀 대화(E2EE)는 서버가 내용을 아예 볼 수 없으므로 관리 대상에서 제외한다.
 * 세 조건을 한꺼번에 판단하는 곳은 moderation.js의 canModifyContent다.
 * (삭제만 해당한다 — 남의 메시지를 **수정**하는 것은 관리자도 절대 할 수 없다.)
 */
export function canModerateContent({ role, isOwner }) {
  return canManageTeam({ role, isOwner });
}

/**
 * 팀을 새로 만들 수 있는지 — 서버 설정(server_settings.teamCreation)이 정한 최소 등급을
 * 넘어야 한다. 서버 운영자는 설정과 무관하게 항상 만들 수 있다.
 */
export const TEAM_CREATION_LEVELS = ['member', 'admin', 'serverAdmin'];

export function canCreateTeam({ role, isServerAdmin, teamCreation }) {
  if (isServerAdmin) return true;
  switch (teamCreation) {
    case 'serverAdmin':
      return false; // 위에서 이미 걸러졌으므로 운영자가 아니면 불가.
    case 'admin':
      return role === 'admin';
    default: // 'member'
      return canCreateRooms(role);
  }
}

/**
 * 팀 초대 링크(가입 시 특정 팀 자동 합류 + 등급 자동 부여)를 만들 수 있는지 — 서버 설정
 * (server_settings.teamInviteLinkCreation)이 정한 최소 등급을 넘어야 한다. TEAM_CREATION_LEVELS와
 * 같은 값 집합을 쓴다. canCreateTeam과 규칙 구조가 같다(둘 다 "서버 설정이 정한 최소 등급").
 */
export function canCreateTeamInviteLink({ role, isServerAdmin, teamInviteLinkCreation }) {
  if (isServerAdmin) return true;
  switch (teamInviteLinkCreation) {
    case 'serverAdmin':
      return false;
    case 'admin':
      return role === 'admin';
    default: // 'member'
      return canCreateRooms(role);
  }
}

/**
 * 프로젝트를 새로 만들 수 있는지 — 서버 설정(server_settings.projectCreation)이 정한 최소
 * 등급을 넘어야 한다. canCreateTeam과 규칙 구조가 같고 값 집합도 TEAM_CREATION_LEVELS를
 * 그대로 쓴다(관리자 콘솔의 "프로젝트 생성 권한"). 준회원은 어느 설정에서도 못 만들고,
 * 서버 운영자는 설정과 무관하게 항상 만들 수 있다. 이미 만들어진 프로젝트에 초대받아
 * 참여하는 것은 이 설정과 무관하다(준회원도 초대받으면 그 프로젝트를 볼 수 있다).
 */
export function canCreateProject({ role, isServerAdmin, projectCreation }) {
  if (isServerAdmin) return true;
  switch (projectCreation) {
    case 'serverAdmin':
      return false;
    case 'admin':
      return role === 'admin';
    default: // 'member'
      return canCreateRooms(role);
  }
}

/**
 * 프로젝트 설정을 바꾸거나 지울 수 있는지 — 그 프로젝트의 담당자(project_members.role ===
 * 'owner')이거나, 그 팀을 관리할 수 있는 사람(팀 소유자·계정 등급 관리자).
 */
export function canManageProject({ role, isOwner, isProjectOwner }) {
  return isProjectOwner === true || canManageTeam({ role, isOwner });
}

/**
 * [메시지 설정] 수정/삭제 가능 시간으로 고를 수 있는 값(초). 클라이언트의 선택지
 * (team_settings_dialog.dart)와 같은 목록이어야 한다 — 서버는 이 목록 밖의 값을 거부한다.
 */
export const EDIT_DELETE_WINDOW_OPTIONS = [
  300, // 5분(기본 — 예전에 코드에 박혀 있던 값)
  1800, // 30분
  3600, // 1시간
  86400, // 24시간
  604800, // 7일
];

/** 팀 설정의 수정/삭제 가능 시간(초). 설정이 없거나 이상한 값이면 기본 5분으로 본다. */
export function editDeleteWindowSeconds(team) {
  const seconds = team?.messageEditDeleteWindowSeconds;
  return EDIT_DELETE_WINDOW_OPTIONS.includes(seconds) ? seconds : EDIT_DELETE_WINDOW_OPTIONS[0];
}

/** "5분"/"24시간"처럼 사람이 읽는 표기 — 수정/삭제 거부 안내 문구에 쓴다. */
export function formatWindow(seconds) {
  if (seconds % 86400 === 0) return `${seconds / 86400}일`;
  if (seconds % 3600 === 0) return `${seconds / 3600}시간`;
  return `${Math.round(seconds / 60)}분`;
}

/** 감사 로그/화면 문구용 한국어 등급 이름. */
export function roleLabel(role) {
  return { admin: '관리자', member: '정회원', guest: '준회원' }[role] ?? role;
}

// ── 토픽·게시글 글자 수 제한 ─────────────────────────────────────────────
// 앱 입력창(maxLength)은 글자 단위(이모지 한 덩어리 = 1자)로 세므로 서버도 같은 단위로 센다 —
// UTF-16 길이로 세면 앱에서 허용한 이모지 이름이 거절된다(projects.js의 폴더 이름과 같은 이유).
export const TOPIC_NAME_MAX = 60;
export const TOPIC_DESCRIPTION_MAX = 300;
export const TOPIC_FOLDER_NAME_MAX = 30;
export const TOPIC_FOLDER_MAX_PER_TEAM = 50;
export const POST_TITLE_MAX = 100;
export const POST_TEXT_MAX = 20000;
export const POST_ATTACHMENT_MAX = 30;
export const MESSAGE_ATTACHMENT_MAX = 20;

// 그룹채팅 이름·설명은 토픽과 같은 길이 제한을 쓴다(채팅 정보 변경 창의 글자 수 표시와 같은 기준).
export const GROUP_NAME_MAX = TOPIC_NAME_MAX;
export const GROUP_DESCRIPTION_MAX = TOPIC_DESCRIPTION_MAX;

/** 나와의 대화(나 혼자만 멤버인 방)에서 막는 기능(초대·나가기·숨기기·별칭 등)의 공통 거절 문구. */
export const SELF_ROOM_DENIAL = '나와의 대화에서는 할 수 없는 기능입니다.';

// ── 메시지 예약 발송(scheduledMessages.js) ─────────────────────────────
export const SCHEDULED_MAX_PER_TEAM = 30; // 한 사람이 한 팀에 둘 수 있는 예약(예약됨 + 발송 실패)
export const SCHEDULED_TEXT_MAX = 5000;
export const SCHEDULED_TITLE_MAX = 50; // 보드 뷰 게시글 제목
export const SCHEDULED_ATTACHMENT_MAX = 10;
export const SCHEDULED_STEP_MS = 15 * 60 * 1000; // 발송 시간은 15분 단위
export const SCHEDULED_MAX_AHEAD_MS = 90 * 24 * 60 * 60 * 1000; // 최대 90일 뒤까지

const graphemeSegmenter = new Intl.Segmenter('ko', { granularity: 'grapheme' });
export function graphemeLength(s) {
  let n = 0;
  for (const _ of graphemeSegmenter.segment(s)) n++;
  return n;
}

/**
 * 게시글 제목·본문 검사(작성 socket.js, 수정 messages.js 공용) — 앞뒤 공백을 뺀 값을 돌려준다.
 * 통과하면 `{ title, text }`, 아니면 `{ error }`.
 */
export function parsePostFields(rawTitle, rawText) {
  const title = typeof rawTitle === 'string' ? rawTitle.trim() : '';
  const text = typeof rawText === 'string' ? rawText.trim() : '';
  if (!title) return { error: '제목을 입력하세요.' };
  if (graphemeLength(title) > POST_TITLE_MAX) return { error: `제목은 ${POST_TITLE_MAX}자 이내로 입력하세요.` };
  if (!text) return { error: '본문을 입력하세요.' };
  if (graphemeLength(text) > POST_TEXT_MAX) return { error: `본문은 ${POST_TEXT_MAX}자 이내로 입력하세요.` };
  return { title, text };
}
