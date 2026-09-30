import '../services/session.dart';
import 'app_user.dart';
import 'room.dart';
import 'team.dart';

/// 토픽 권한 판정 — Room 모델이 Session을 직접 알지 않게 확장으로 따로 둔다(session.dart가
/// 이 파일을 다시 내보내므로 session.dart만 import해도 쓸 수 있다). 서버 canManageTopic 등과
/// 같은 규칙이고, 화면은 버튼을 감추는 데만 쓴다 — 실제 차단은 항상 서버가 다시 한다.
extension RoomPermissions on Room {
  /// 토픽을 관리할 수 있는 사람(토픽 관리자 또는 팀 관리자)인지 — 정보 변경·보관·삭제·멤버
  /// 내보내기·토픽 관리자 지정, 읽기 전용/보관된 토픽에 글쓰기. 토픽이 아니면 항상 false.
  bool canManage(Session s) {
    if (type != RoomType.topic) return false;
    return isTopicAdmin(s.userId) || _canManageTeamOf(s);
  }

  /// 이 방에 메시지/게시글을 쓸 수 있는지 — 토픽이 읽기 전용이거나 보관됐으면 토픽을 관리할
  /// 수 있는 사람만. 토픽이 아니면 항상 true(댓글은 이 판정과 무관하게 누구나 달 수 있다).
  bool canWrite(Session s) {
    if (type != RoomType.topic) return true;
    return (!readOnly && !isArchived) || canManage(s);
  }

  /// [userId]를 이 토픽에서 내보낼 수 있는지 — 토픽을 관리할 수 있는 사람만, 자기 자신은 안
  /// 되고, 팀 관리자가 아닌 토픽 관리자는 다른 토픽 관리자를 내보낼 수 없다(서버 POST
  /// /rooms/:id/kick과 같은 규칙).
  bool canKick(Session s, String userId) {
    if (!canManage(s) || userId == s.userId) return false;
    if (isTopicAdmin(userId) && !_canManageTeamOf(s)) return false;
    return members.any((m) => m.id == userId);
  }

  /// 그룹채팅 정보(이름·설명·아이콘)를 바꿀 수 있는지 — 그 방 멤버이면서 준회원이 아니어야 한다
  /// (서버 PATCH /rooms/:id와 같은 규칙). 그룹채팅이 아니면 항상 false. 준회원에게는 버튼을 막고
  /// [groupInfoGuestNotice]로 이유를 보여준다.
  bool canEditGroupInfo(Session s) =>
      type == RoomType.group &&
      s.accountRole != AccountRole.guest &&
      members.any((m) => m.id == s.userId);

  /// 이 방이 속한 팀을 내가 관리할 수 있는지(팀 관리자 = 소유자 또는 계정 등급 관리자). 방이
  /// 지금 보고 있는 팀이 아닐 수도 있어서(알림 센터 등) 방의 팀을 먼저 찾고, 못 찾으면 지금
  /// 팀 기준(canManageCurrentTeam)으로 본다.
  bool _canManageTeamOf(Session s) {
    Team? team;
    for (final t in s.teams) {
      if (t.id == teamId) {
        team = t;
        break;
      }
    }
    if (team == null && s.currentTeam?.id == teamId) team = s.currentTeam;
    return team?.canManage(s.accountRole) ?? s.canManageCurrentTeam;
  }
}

/// 준회원이 그룹채팅 정보를 바꾸려 할 때의 안내(서버 403 문구와 같다) — ⋮ 메뉴 툴팁·정보 변경 창이 같이 쓴다.
const groupInfoGuestNotice = '준회원은 채팅 정보를 바꿀 수 없습니다.';

/// 토픽 관리자로 지정할 수 있는 멤버인지 — 정회원 이상(준회원 제외, 서버 PUT /rooms/:id/admins와
/// 같은 규칙).
bool canBeTopicAdmin(AppUser user) =>
    user.role == 'member' || user.role == 'admin';
