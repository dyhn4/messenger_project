import { safeAvatarColor } from './avatarRules.js';
import { accountRole } from './permissions.js';
import { signFileUrl } from './upload.js';

/**
 * 회원 명단을 누구에게 얼마나 보여 줄지 — DB를 읽지 않는 순수 규칙이라 단위 테스트가 그대로 돌린다(test/userDirectory.test.js,
 * 팀원 추가 후보 라우트까지는 test/userDirectoryCandidates.test.js).
 * 팀을 같이 쓰는 사람 목록처럼 DB가 필요한 값은 호출부(users.js·teams.js)가 조회해서 넘긴다.
 *
 * 예전엔 GET /users가 로그인한 누구에게나(팀이 하나도 없는 준회원에게도) 서버 전체 회원의 아이디(로그인·비밀번호 찾기에 쓰는
 * 값)·이름·등급·접속 상태를 줬다 — 아이디 목록을 통째로 모아 흔한 비밀번호나 보안 질문을 맞혀 보는 발판이 됐다.
 */

/**
 * 서버 전체 회원 명단을 볼 수 있는 사람 — 계정 등급 관리자와 서버 운영자. 조직도(관리자 이상 전용, teams.js GET /org-chart/teams)가
 * "미소속" 회원까지 보여 주고, 관리자는 모든 팀을 관리할 수 있어서 팀이 없는 새 가입자도 찾아야 한다. 팀 소유자라는 것만으로는
 * 안 된다(아래 memberCandidateScope).
 */
export function seesWholeDirectory(user) {
  return !!user && (user.isServerAdmin === true || accountRole(user) === 'admin');
}

/**
 * 그 밖의 사람이 볼 수 있는 회원 id(Set) — 팀을 하나라도 같이 쓰는 사람([coTeamIds] — db/queries/teams.js listCoTeamMemberIds)과
 * 자기 자신. 팀 멤버 목록·방 멤버 목록으로 이미 알 수 있는 사람들이라 더 새는 것이 없다. 팀이 없으면 자기 자신뿐이다.
 */
export function directoryUserIds(viewerId, coTeamIds = []) {
  return new Set([viewerId, ...coTeamIds]);
}

/** [visibleIds](위 directoryUserIds, 서버 전체를 보는 사람이면 null)로 [targetId] 한 사람을 볼 수 있는지. */
export function canSeeUser(visibleIds, targetId) {
  return visibleIds === null || visibleIds.has(targetId);
}

/**
 * 팀 설정 "팀원 추가"의 후보를 어디까지 줄지(teams.js GET /teams/:id/member-candidates) — 서버 전체를 보는 사람(위
 * seesWholeDirectory)은 'all'(아직 이 팀에 없는 서버의 모든 회원), 그 밖의 팀 소유자는 'coTeam'(팀을 하나라도 같이 쓰는
 * 사람 — 회원 목록 GET /users와 같은 범위라 더 새는 것이 없다)이다.
 *
 * 소유자에게까지 서버 전체를 주면 GET /users를 좁힌 것이 소용없어진다: 기본 설정(server_settings.teamCreation 'member')에서는
 * 정회원 누구나 팀을 만들 수 있고 만든 사람이 곧 그 팀의 소유자라, 팀 하나만 만들면 이 목록으로 서버의 모든 아이디를 받아 갈
 * 수 있었다. 팀 밖의 사람은 아이디를 정확히 알 때만 한 명씩 찾는다(parseCandidateUsername, MEMBER_LOOKUP_RATE). 이름으로
 * 찾게 하지는 않는다 — 흔한 성·이름 앞글자를 차례로 넣어 보면 결국 서버 전체 명단이 나오고, 찾은 사람을 팀에 넣으면 팀 멤버
 * 목록에서 아이디까지 보이기 때문이다. 새로 가입할 사람은 팀 초대 링크로 그 팀에 바로 들어올 수 있다.
 */
export function memberCandidateScope(user) {
  return seesWholeDirectory(user) ? 'all' : 'coTeam';
}

/**
 * "아이디로 찾기"에 넣은 값 — 앞뒤 공백만 뗀다(앱이 로그인·가입 때도 그렇게 보낸다). 가입 규칙(auth.js — 4~20자)에 안 맞으면
 * 그런 계정은 없으니 null(DB에 묻지 않는다). 대소문자는 그대로 둔다 — 로그인처럼 정확히 같은 아이디만 찾는다.
 */
export function parseCandidateUsername(raw) {
  if (typeof raw !== 'string') return null;
  const username = raw.trim();
  return username.length >= 4 && username.length <= 20 ? username : null;
}

/**
 * 팀 밖 사람을 아이디로 찾는 횟수 — 사람마다 10분에 30번(authGuard.js RateLimiter). 아이디를 받아 적어 가며 한 명씩 찾는
 * 속도로는 닿지 않고, 있을 법한 아이디를 줄줄이 넣어 보며 어떤 아이디가 있는지 맞혀 보는 것은 늦춘다. 서버 전체를 보는
 * 사람('all')은 세지 않는다(이미 다 보인다).
 */
export const MEMBER_LOOKUP_RATE = { max: 30, windowMs: 10 * 60 * 1000 };

/**
 * 팀 설정 "팀원 추가"의 후보 — [users] 가운데 아직 이 팀에 없는([memberIds]) 사람 중 정지·탈퇴하지 않은 계정. 팀에 넣을 사람은
 * 아직 그 팀에 없으니 회원 목록(GET /users — 팀을 같이 쓰는 사람만)으로는 못 찾는다(회원가입만 한 사람은 어느 팀에도 없다).
 * 그래서 그 팀을 관리할 수 있는 사람에게만(teams.js GET /teams/:id/member-candidates) 이 목록을 따로 준다 — 어디까지 줄지는
 * 위 memberCandidateScope.
 *
 * 화면이 쓰는 칸만 싣는다(이름·아바타·등급 — 접속 상태·직책은 안 쓴다). 아이디는 싣는다: 이름은 겹칠 수 있어서 같은 이름 중
 * 누구를 넣는지 아이디로 가린다. 서버 전체가 아닌 사람에게 가는 후보는 팀을 같이 쓰는 사람(팀 멤버 목록에 이미 아이디가
 * 보인다)이나 그 아이디를 직접 넣어 찾은 사람뿐이다. 이름순으로 준다.
 */
export function teamMemberCandidates(users, memberIds) {
  const inTeam = new Set(memberIds);
  return users
    .filter((u) => !u.deletedAt && !u.suspendedAt && !inTeam.has(u.id))
    .map(toMemberCandidateDto)
    .sort((a, b) => a.name.localeCompare(b.name, 'ko'));
}

function toMemberCandidateDto(u) {
  return {
    id: u.id,
    username: u.username,
    name: u.name ?? u.username,
    avatarType: u.avatarType ?? 'initial',
    avatarEmoji: u.avatarEmoji ?? null,
    avatarColor: safeAvatarColor(u.avatarColor),
    avatarUrl: u.avatarType === 'photo' ? (signFileUrl(u.avatarUrl) ?? null) : null,
    role: accountRole(u),
  };
}
