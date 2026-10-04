import '../models/my_post.dart';
import '../models/poll_list.dart';
import 'api_client.dart';

/// 투표 목록 패널·내가 쓴 글 패널의 서버 호출 — api_client.dart를 더 키우지 않으려고 [ApiClient]의 확장으로 둔다
/// (calendar_api.dart 등과 같은 방식: 인증·401 재시도·에러 처리는 [ApiClient.requestJson]이 그대로 한다).
extension PanelListsApi on ApiClient {
  /// `GET /api/polls` — 이 팀에서 내가 멤버인 방의 투표를 만든 시각순(기본) 또는 기한 순([sort])으로. 필터(방·상태·작성자·
  /// 참여 여부·기간)는 모두 서버에서 걸러 오고 — [since]/[until]을 안 주면 기간 제한 없이 전체 — [before]는 이전 쪽 응답의
  /// `nextBefore`(무한 스크롤 커서)다. [newestFirst]는 생성 순일 때의 방향이다(기한 순은 늘 마감이 가까운 것부터).
  Future<PollListPage> fetchPollList({
    required String teamId,
    String? roomId,
    PollStatusFilter status = PollStatusFilter.all,
    String? creatorId,
    PollParticipationFilter participated = PollParticipationFilter.all,
    DateTime? since,
    DateTime? until,
    PollSort sort = PollSort.created,
    bool newestFirst = true,
    String? before,
    int limit = 20,
  }) async {
    final query = <String, String>{
      'teamId': teamId,
      'roomId': ?roomId,
      if (status != PollStatusFilter.all) 'status': status.name,
      'creatorId': ?creatorId,
      if (participated != PollParticipationFilter.all)
        'participated': participated.name,
      'since': ?since?.millisecondsSinceEpoch.toString(),
      'until': ?until?.millisecondsSinceEpoch.toString(),
      if (sort != PollSort.created) 'sort': sort.name,
      'order': newestFirst ? 'desc' : 'asc',
      'before': ?before,
      'limit': '$limit',
    };
    final path = Uri(path: '/api/polls', queryParameters: query);
    return PollListPage.fromJson(
      Map<String, dynamic>.from(
        await requestJson('GET', path.toString()) as Map,
      ),
    );
  }

  /// `GET /api/my-posts` — 내가 쓴 메시지·댓글을 쓴 시각순으로. [kind]로 종류(전체/메시지/댓글)를, [roomId]·[since]·[until]로
  /// 참여 대화방·기간을 서버에서 걸러 온다. [before]는 이전 쪽 응답의 `nextBefore`.
  Future<MyPostsPage> fetchMyPosts({
    required String teamId,
    String? roomId,
    MyPostKind kind = MyPostKind.all,
    DateTime? since,
    DateTime? until,
    bool newestFirst = true,
    String? before,
    int limit = 30,
  }) async {
    final query = <String, String>{
      'teamId': teamId,
      'roomId': ?roomId,
      if (kind != MyPostKind.all) 'kind': kind.name,
      'since': ?since?.millisecondsSinceEpoch.toString(),
      'until': ?until?.millisecondsSinceEpoch.toString(),
      'order': newestFirst ? 'desc' : 'asc',
      'before': ?before,
      'limit': '$limit',
    };
    final path = Uri(path: '/api/my-posts', queryParameters: query);
    return MyPostsPage.fromJson(
      Map<String, dynamic>.from(
        await requestJson('GET', path.toString()) as Map,
      ),
    );
  }
}
