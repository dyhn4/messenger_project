import 'message.dart';

/// 투표 목록 패널 필터 — 상태(진행 중/마감)와 참여 여부. 서버 `GET /api/polls`의 `status`·`participated` 값과 같은 이름이다.
enum PollStatusFilter { all, open, closed }

enum PollParticipationFilter { all, yes, no }

/// 투표 목록 패널 정렬 — 생성 순(만든 시각 최근 순, 기본) / 기한 순(진행 중은 마감이 가까운 순, 그 뒤 마감된 투표는 최근에
/// 끝난 순). 서버 `GET /api/polls`의 `sort` 값(created | deadline)과 같은 이름이다.
enum PollSort { created, deadline }

extension PollSortLabel on PollSort {
  String get label => switch (this) {
    PollSort.created => '생성 순',
    PollSort.deadline => '기한 순',
  };
}

extension PollStatusFilterLabel on PollStatusFilter {
  String get label => switch (this) {
    PollStatusFilter.all => '전체',
    PollStatusFilter.open => '진행 중',
    PollStatusFilter.closed => '마감',
  };
}

extension PollParticipationFilterLabel on PollParticipationFilter {
  String get label => switch (this) {
    PollParticipationFilter.all => '전체',
    PollParticipationFilter.yes => '참여함',
    PollParticipationFilter.no => '참여 안 함',
  };
}

/// 투표 목록의 한 장 — 방 메시지(`poll` 포함, 보는 사람 기준 myOptionIds/favorite)에 받는 사람 기준 방 이름이 붙어 온다.
class PollListItem {
  final Message message;
  final String? roomName;
  const PollListItem({required this.message, this.roomName});

  String get roomId => message.roomId;

  factory PollListItem.fromJson(Map<String, dynamic> json) => PollListItem(
    message: Message.fromJson(json),
    roomName: json['roomName'] as String?,
  );
}

/// `GET /api/polls` 한 쪽. [total]은 조건에 맞는 전체 개수, [nextBefore]는 다음 쪽을 받을 때 `before`로 넘기는 커서.
class PollListPage {
  final List<PollListItem> items;
  final bool hasMore;
  final int total;
  final String? nextBefore;
  const PollListPage({
    required this.items,
    required this.hasMore,
    required this.total,
    this.nextBefore,
  });

  factory PollListPage.fromJson(Map<String, dynamic> json) => PollListPage(
    items: [
      for (final e in (json['items'] as List? ?? const []))
        PollListItem.fromJson(Map<String, dynamic>.from(e as Map)),
    ],
    hasMore: json['hasMore'] as bool? ?? false,
    total: (json['total'] as num?)?.toInt() ?? 0,
    nextBefore: json['nextBefore'] as String?,
  );
}
