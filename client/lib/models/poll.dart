import 'package:flutter/widgets.dart' show StringCharacters;

/// 투표 제목·설명·보기 한도 — 서버 polls 라우트가 같은 값으로 다시 검사한다.
const pollTitleMaxLength = 100;
const pollDescriptionMaxLength = 1000;
const pollOptionMaxLength = 100;
const pollOptionsMinCount = 2;
const pollOptionsMaxCount = 20;
const pollAttachmentsMaxCount = 30;
const pollMaxDaysAhead = 90;

/// 기명 투표에서 한 보기에 표를 준 사람 한 명.
class PollVoter {
  final String userId;
  final String name;
  const PollVoter({required this.userId, required this.name});

  factory PollVoter.fromJson(Map<String, dynamic> json) => PollVoter(
    userId: json['userId'] as String,
    name: json['name'] as String? ?? '',
  );
}

/// 투표 보기 하나 — [voters]는 기명 투표일 때만 채워지고 익명 투표는 null(서버가 키 자체를 안 준다).
class PollOption {
  final String id;
  final String text;
  final int voteCount;
  final List<PollVoter>? voters;

  const PollOption({
    required this.id,
    required this.text,
    this.voteCount = 0,
    this.voters,
  });

  factory PollOption.fromJson(Map<String, dynamic> json) => PollOption(
    id: json['id'] as String,
    text: json['text'] as String? ?? '',
    voteCount: (json['voteCount'] as num?)?.toInt() ?? 0,
    voters: (json['voters'] as List?)
        ?.map((e) => PollVoter.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList(),
  );
}

/// 메시지(type 'poll')에 붙는 투표 — 서버 toMessageDto의 `poll` 필드. `myOptionIds`·`favorite`은
/// 보는 사람마다 다른 값이라, 소켓으로 온 값은 [applyUpdate]의 규칙대로 합쳐서 쓴다.
class Poll {
  final String id;
  final String title;
  final String? description;
  final bool anonymous;
  final bool multiple;
  final DateTime closesAt;

  /// 만든 사람이나 관리자가 일찍 마감한 시각(그렇지 않으면 null).
  final DateTime? closedAt;

  /// 서버가 계산한 마감 여부 — 표시할 때는 [isClosed]로 지금 시각도 함께 본다.
  final bool closed;
  final String? creatorId;

  /// 투표한 사람 수(중복 제거).
  final int voterCount;
  final List<PollOption> options;

  /// 보는 사람이 고른 보기 id들(없으면 빈 목록).
  final List<String> myOptionIds;

  /// 보는 사람이 즐겨찾기했는지.
  final bool favorite;

  const Poll({
    required this.id,
    required this.title,
    this.description,
    this.anonymous = false,
    this.multiple = false,
    required this.closesAt,
    this.closedAt,
    this.closed = false,
    this.creatorId,
    this.voterCount = 0,
    this.options = const [],
    this.myOptionIds = const [],
    this.favorite = false,
  });

  factory Poll.fromJson(Map<String, dynamic> json) => Poll(
    id: json['id'] as String,
    title: json['title'] as String? ?? '',
    description: json['description'] as String?,
    anonymous: json['anonymous'] as bool? ?? false,
    multiple: json['multiple'] as bool? ?? false,
    closesAt: DateTime.fromMillisecondsSinceEpoch(
      (json['closesAt'] as num).toInt(),
    ),
    closedAt: (json['closedAt'] as num?) != null
        ? DateTime.fromMillisecondsSinceEpoch((json['closedAt'] as num).toInt())
        : null,
    closed: json['closed'] as bool? ?? false,
    creatorId: json['creatorId'] as String?,
    voterCount: (json['voterCount'] as num?)?.toInt() ?? 0,
    options:
        (json['options'] as List?)
            ?.map(
              (e) => PollOption.fromJson(Map<String, dynamic>.from(e as Map)),
            )
            .toList() ??
        const [],
    myOptionIds:
        (json['myOptionIds'] as List?)?.whereType<String>().toList() ??
        const [],
    favorite: json['favorite'] as bool? ?? false,
  );

  /// 마감됐는지 — 서버가 준 값에 더해, 마감 시각이 지났으면 서버가 따로 알리지 않아도 마감으로 본다.
  bool isClosed([DateTime? now]) =>
      closed || closedAt != null || !closesAt.isAfter(now ?? DateTime.now());

  /// 내가 이미 투표했는지.
  bool get hasVoted => myOptionIds.isNotEmpty;

  /// 득표 비율(0~1) — 익명·기명 모두 "투표한 사람 수" 기준이라 복수 선택이면 합이 1을 넘을 수 있다.
  double ratioOf(PollOption option) =>
      voterCount <= 0 ? 0 : (option.voteCount / voterCount).clamp(0.0, 1.0);

  /// 화면에 보이는 값이 [other]와 같은지 — 다시 받은 목록(REST)이 지금 값과 달라졌는지 볼 때 쓴다.
  bool sameContentAs(Poll other) {
    if (id != other.id ||
        closed != other.closed ||
        closedAt != other.closedAt ||
        favorite != other.favorite ||
        voterCount != other.voterCount ||
        options.length != other.options.length ||
        myOptionIds.length != other.myOptionIds.length) {
      return false;
    }
    for (var i = 0; i < options.length; i++) {
      if (options[i].id != other.options[i].id ||
          options[i].voteCount != other.options[i].voteCount ||
          (options[i].voters?.length ?? 0) !=
              (other.options[i].voters?.length ?? 0)) {
        return false;
      }
    }
    return myOptionIds.toSet().containsAll(other.myOptionIds);
  }

  Poll copyWith({
    List<PollOption>? options,
    int? voterCount,
    List<String>? myOptionIds,
    bool? favorite,
    bool? closed,
    DateTime? closedAt,
  }) => Poll(
    id: id,
    title: title,
    description: description,
    anonymous: anonymous,
    multiple: multiple,
    closesAt: closesAt,
    closedAt: closedAt ?? this.closedAt,
    closed: closed ?? this.closed,
    creatorId: creatorId,
    voterCount: voterCount ?? this.voterCount,
    options: options ?? this.options,
    myOptionIds: myOptionIds ?? this.myOptionIds,
    favorite: favorite ?? this.favorite,
  );

  /// 소켓 `poll:updated`를 받았을 때의 새 값 — "받는 쪽 규칙"(docs 규약 A)대로 합친다.
  /// 이벤트의 poll은 모두에게 같은 중립값(myOptionIds 빈 목록, favorite false)이고 표 수는 그때의
  /// 절대값이라(더하는 값이 아니다) 같은 투표의 알림을 두 번 받아도 표가 두 번 세어지지 않는다.
  /// 보는 사람별 값은 이벤트로 덮어쓰지 않고 직전 값을 유지하되 내가 투표한 이벤트(actorId가 나)일
  /// 때만 actorOptionIds로 갈아 끼운다(다른 기기에서 투표한 경우도 여기서 따라간다).
  /// 서버는 actorId·actorOptionIds를 투표한 사람의 기기(user 룸)로 가는 알림에만 싣고 방 전체에는
  /// null로 보낸다 — 익명 투표에서 누가 무엇을 골랐는지가 새지 않게. 옛 서버처럼 남의 actorId가
  /// 와도 내 선택에는 쓰지 않는다.
  static Poll applyUpdate(
    Poll? current,
    Poll incoming, {
    String? actorId,
    List<String>? actorOptionIds,
    String? myUserId,
  }) {
    final mine = actorId != null && myUserId != null && actorId == myUserId
        ? (actorOptionIds ?? const <String>[])
        : (current?.myOptionIds ?? const <String>[]);
    return incoming.copyWith(
      myOptionIds: List<String>.of(mine),
      favorite: current?.favorite ?? false,
    );
  }
}

/// 소켓 `poll:updated` — 누가 투표했거나 투표가 마감됐다. 방 전체로 오는 알림(남의 투표·마감)은
/// [actorId]·[actorOptionIds]가 null이고(누가 투표했는지는 알리지 않는다), 내가 투표했을 때 내
/// 기기들로 오는 알림에만 내 id와 내가 고른 보기(취소면 빈 목록)가 들어 있다.
class PollUpdatedEvent {
  final String roomId;
  final String messageId;
  final String pollId;
  final Poll poll;
  final String? actorId;
  final List<String>? actorOptionIds;

  const PollUpdatedEvent({
    required this.roomId,
    required this.messageId,
    required this.pollId,
    required this.poll,
    this.actorId,
    this.actorOptionIds,
  });

  factory PollUpdatedEvent.fromJson(Map<String, dynamic> json) =>
      PollUpdatedEvent(
        roomId: json['roomId'] as String,
        messageId: json['messageId'] as String,
        pollId: json['pollId'] as String,
        poll: Poll.fromJson(Map<String, dynamic>.from(json['poll'] as Map)),
        actorId: json['actorId'] as String?,
        actorOptionIds: (json['actorOptionIds'] as List?)
            ?.whereType<String>()
            .toList(),
      );
}

/// 소켓 `poll:favorite` — 내 다른 기기에서 즐겨찾기를 바꿨다(user 룸으로만 온다).
class PollFavoriteEvent {
  final String messageId;
  final String pollId;
  final bool favorite;
  const PollFavoriteEvent({
    required this.messageId,
    required this.pollId,
    required this.favorite,
  });

  factory PollFavoriteEvent.fromJson(Map<String, dynamic> json) =>
      PollFavoriteEvent(
        messageId: json['messageId'] as String,
        pollId: json['pollId'] as String,
        favorite: json['favorite'] as bool? ?? false,
      );
}

/// 투표 만들기 검증 — 화면과 테스트가 같이 쓴다. 보기는 앞뒤 공백을 뗀 뒤 비교한다.
class PollDraftCheck {
  final String? titleError;
  final String? optionsError;

  /// 보기 칸별 오류(칸 순서대로, 없으면 null) — 중복된 보기에 표시한다.
  final List<String?> optionErrors;
  final String? closesAtError;

  const PollDraftCheck({
    this.titleError,
    this.optionsError,
    this.optionErrors = const [],
    this.closesAtError,
  });

  bool get ok =>
      titleError == null &&
      optionsError == null &&
      closesAtError == null &&
      optionErrors.every((e) => e == null);
}

PollDraftCheck checkPollDraft({
  required String title,
  required List<String> options,
  required DateTime? closesAt,
  DateTime? now,
}) {
  final current = now ?? DateTime.now();
  final trimmedTitle = title.trim();
  final titleError = trimmedTitle.isEmpty
      ? '투표 제목을 입력하세요.'
      : _graphemeLength(trimmedTitle) > pollTitleMaxLength
      ? '투표 제목은 $pollTitleMaxLength자까지 쓸 수 있습니다.'
      : null;

  final seen = <String>{};
  final errors = <String?>[];
  var filled = 0;
  for (final raw in options) {
    final text = raw.trim();
    if (text.isEmpty) {
      errors.add(null);
      continue;
    }
    filled++;
    if (_graphemeLength(text) > pollOptionMaxLength) {
      errors.add('보기는 $pollOptionMaxLength자까지 쓸 수 있습니다.');
    } else if (!seen.add(text)) {
      errors.add('같은 보기가 있습니다.');
    } else {
      errors.add(null);
    }
  }
  final optionsError = filled < pollOptionsMinCount
      ? '보기를 $pollOptionsMinCount개 이상 입력하세요.'
      : null;

  String? closesAtError;
  if (closesAt == null) {
    closesAtError = '마감 시각을 선택하세요.';
  } else if (!closesAt.isAfter(current)) {
    closesAtError = '마감 시각은 지금보다 늦어야 합니다.';
  } else if (closesAt.isAfter(
    current.add(const Duration(days: pollMaxDaysAhead)),
  )) {
    closesAtError = '마감 시각은 지금부터 $pollMaxDaysAhead일 안이어야 합니다.';
  }
  return PollDraftCheck(
    titleError: titleError,
    optionsError: optionsError,
    optionErrors: errors,
    closesAtError: closesAtError,
  );
}

/// 눈에 보이는 글자 단위 길이 — 서버(graphemes)와 같게 센다. 이모지 하나를 1자로 본다.
int _graphemeLength(String s) => s.characters.length;

/// 방 목록·알림·검색 결과에 쓰는 한 줄 미리보기 — 서버 push.js·rooms.js와 같은 "[투표] 제목".
String pollPreviewText(String? title) => '[투표] ${title ?? ''}';

/// "5월 30일 오후 6:00" — 마감 시각 표시. 올해가 아니면 연도를 붙인다. intl 로케일 초기화에
/// 기대지 않고(위젯 테스트·백그라운드에서도 같은 결과) 직접 만든다.
String formatPollTime(DateTime t, {DateTime? now}) {
  final local = t.toLocal();
  final year = (now ?? DateTime.now()).year;
  final hour12 = local.hour % 12 == 0 ? 12 : local.hour % 12;
  final meridiem = local.hour < 12 ? '오전' : '오후';
  final minute = local.minute.toString().padLeft(2, '0');
  final prefix = local.year == year ? '' : '${local.year}년 ';
  return '$prefix${local.month}월 ${local.day}일 $meridiem $hour12:$minute';
}
