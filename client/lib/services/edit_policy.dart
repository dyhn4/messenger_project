import '../models/team.dart';
import 'session.dart';
import '../l10n/tr.dart';

/// 메시지/댓글 **수정·삭제** 허용 여부와 허용 시간은 팀 설정([메시지 설정] → 메시지 수정/삭제,
/// 수정/삭제 가능 시간)을 따른다. 여기 함수들은 버튼을 누르자마자 바로 실패를 보여주기 위한
/// 클라이언트 쪽 사전 확인일 뿐이고, 최종 판단은 항상 서버가 한다(서버 moderation.js의
/// canModifyContent) — 클라이언트 시계가 서버보다 살짝 빠르면 여기선 통과해도 서버가 403으로
/// 거부할 수 있는데, 그건 그때 가서 스낵바로 보여준다.
///
/// 팀을 아직 안 골랐거나 설정을 못 읽었으면 기본값(허용, 5분)으로 본다.

/// 팀에서 메시지 수정/삭제 자체를 꺼두면 아무도(소유자·관리자 포함) 고치거나 지울 수 없다.
bool isEditDeleteAllowed(Session session) =>
    session.currentTeam?.messageEditDeleteEnabled ?? true;

Duration editDeleteWindowOf(Session session) => Duration(
  seconds:
      session.currentTeam?.messageEditDeleteWindowSeconds ??
      editDeleteWindowOptions.first,
);

bool isWithinEditDeleteWindow(Session session, DateTime createdAt) =>
    DateTime.now().difference(createdAt) <= editDeleteWindowOf(session);

/// "작성 후 24시간이 지나 메시지를 수정할 수 없습니다."처럼 서버와 같은 문구를 만든다.
/// [what]은 '메시지'/'댓글', [action]은 '수정'/'삭제'.
String editDeleteWindowExpiredMessage(
  Session session, {
  required String what,
  required String action,
}) => tr('작성 후 {p0}이 지나 {what}을 {action}할 수 없습니다.', {
  'p0': formatEditDeleteWindow(editDeleteWindowOf(session).inSeconds),
  'what': what,
  'action': action,
});

/// [메시지 수정/삭제]를 꺼둔 팀에서 수정/삭제를 시도했을 때의 안내 문구.
final editDeleteDisabledMessage = tr('이 팀은 메시지 수정/삭제를 사용하지 않도록 설정되어 있습니다.');
