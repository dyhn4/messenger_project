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
 * 방에 다른 사람을 초대할 수 있는지 — 팀 설정(invitePolicy)에 따라 달라진다.
 * 'member'(기본)면 정회원 이상, 'admin'이면 그 팀을 관리할 수 있는 사람만. 준회원은 항상 불가.
 */
export function canInviteMembers({ role, isOwner, team }) {
  if (team?.invitePolicy === 'admin') return canManageTeam({ role, isOwner });
  return canCreateRooms(role);
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
