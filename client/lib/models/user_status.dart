// 상태 메시지("🗓️ 회의 중")와 방해 금지 — 서버 server/src/statusRules.js와 같은 규칙. 특히 [DndState.isActiveAt]은 서버의
// isDndActive와 같아야 "방해 금지 중" 표시와 실제로 알림이 안 가는 것이 맞는다.

import '../l10n/tr.dart';

/// 상태 메시지에 고를 수 있는 이모지 — 서버 STATUS_EMOJIS와 같이 맞춘다.
const statusEmojis = [
  '🗓️',
  '🚗',
  '🏖️',
  '🍽️',
  '🏠',
  '🤒',
  '✈️',
  '🎯',
  '☕',
  '📚',
  '👶',
  '💬',
];

/// 상태 글 최대 길이(화면에 보이는 글자 단위).
const statusTextMax = 40;

/// 상태를 언제 지울지.
enum StatusClearAfter {
  never('지우지 않음'),
  minutes30('30분 뒤'),
  hour1('1시간 뒤'),
  hours4('4시간 뒤'),
  today('오늘까지'),
  thisWeek('이번 주까지');

  final String _labelKo;

  /// 화면에 보일 이름(지금 언어 — l10n/tr.dart).
  String get label => tr(_labelKo);
  const StatusClearAfter(this._labelKo);

  /// [now] 기준으로 지울 시각 — 지우지 않으면 null. "오늘"은 오늘 자정, "이번 주"는 이번 일요일 자정(다음 월요일 0시).
  DateTime? untilFrom(DateTime now) => switch (this) {
    never => null,
    minutes30 => now.add(const Duration(minutes: 30)),
    hour1 => now.add(const Duration(hours: 1)),
    hours4 => now.add(const Duration(hours: 4)),
    today => DateTime(now.year, now.month, now.day + 1),
    thisWeek => DateTime(now.year, now.month, now.day + 8 - now.weekday),
  };
}

/// 자주 쓰는 상태 — 고르면 이모지·글·지울 시점이 함께 채워진다.
final statusPresets = <({String emoji, String text, StatusClearAfter clear})>[
  (emoji: '🗓️', text: tr('회의 중'), clear: StatusClearAfter.hour1),
  (emoji: '🚗', text: tr('외근 중'), clear: StatusClearAfter.today),
  (emoji: '🍽️', text: tr('식사 중'), clear: StatusClearAfter.hour1),
  (emoji: '🏠', text: tr('재택 근무'), clear: StatusClearAfter.today),
  (emoji: '🏖️', text: tr('휴가 중'), clear: StatusClearAfter.never),
  (emoji: '🤒', text: tr('병가'), clear: StatusClearAfter.today),
];

/// 상태 메시지 — 서버 statusDto 모양.
class UserStatus {
  final String? emoji;
  final String? text;

  /// 지울 시각 — null이면 직접 지울 때까지.
  final DateTime? until;

  const UserStatus({this.emoji, this.text, this.until});

  static UserStatus? fromJson(Object? json) {
    if (json is! Map) return null;
    final emoji = json['emoji'] as String?;
    final text = json['text'] as String?;
    if ((emoji == null || emoji.isEmpty) && (text == null || text.isEmpty)) {
      return null;
    }
    final until = json['until'];
    return UserStatus(
      emoji: emoji,
      text: text,
      until: until is num
          ? DateTime.fromMillisecondsSinceEpoch(until.toInt())
          : null,
    );
  }

  /// [now]에 아직 보여야 하는지(지울 시각이 지나지 않았는지).
  bool isLiveAt(DateTime now) => until == null || now.isBefore(until!);

  /// "🗓️ 회의 중"처럼 한 줄로.
  String get label => [
    if (emoji != null && emoji!.isNotEmpty) emoji!,
    if (text != null && text!.isNotEmpty) text!,
  ].join(' ');
}

/// 방해 금지 일정 — 매일(고른 요일) start~end(하루 중 분) 동안. end가 start보다 작으면 밤을 넘긴다(시작한 요일 기준).
/// [days]는 0(일)~6(토), [offsetMinutes]는 정한 기기의 UTC 차이.
class DndSchedule {
  final bool enabled;
  final int start;
  final int end;
  final List<int> days;
  final int offsetMinutes;

  const DndSchedule({
    required this.enabled,
    required this.start,
    required this.end,
    required this.days,
    required this.offsetMinutes,
  });

  static DndSchedule? fromJson(Object? json) {
    if (json is! Map) return null;
    final start = json['start'];
    final end = json['end'];
    final days = json['days'];
    final offset = json['offsetMinutes'];
    if (start is! num || end is! num || days is! List || offset is! num) {
      return null;
    }
    return DndSchedule(
      enabled: json['enabled'] == true,
      start: start.toInt(),
      end: end.toInt(),
      days: days.whereType<num>().map((d) => d.toInt()).toList(),
      offsetMinutes: offset.toInt(),
    );
  }

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'start': start,
    'end': end,
    'days': days,
    'offsetMinutes': offsetMinutes,
  };

  /// [now]에 이 일정 안인지 — 서버 isDndActive의 일정 부분과 같은 계산(그 사람 시각 = UTC + offsetMinutes).
  bool coversAt(DateTime now) {
    if (!enabled || start == end) return false;
    final local = now.toUtc().add(Duration(minutes: offsetMinutes));
    // Dart weekday는 1(월)~7(일) — 서버(JS getUTCDay)의 0(일)~6(토)로 맞춘다.
    final day = local.weekday % 7;
    final minute = local.hour * 60 + local.minute;
    if (start < end) {
      return days.contains(day) && minute >= start && minute < end;
    }
    final previousDay = (day + 6) % 7;
    return (days.contains(day) && minute >= start) ||
        (days.contains(previousDay) && minute < end);
  }
}

/// 방해 금지 — "이 시각까지"([until])와 매일 일정([schedule]). 서버 dndDto 모양.
class DndState {
  final DateTime? until;
  final DndSchedule? schedule;

  const DndState({this.until, this.schedule});

  static DndState? fromJson(Object? json) {
    if (json is! Map) return null;
    final until = json['until'];
    final state = DndState(
      until: until is num
          ? DateTime.fromMillisecondsSinceEpoch(until.toInt())
          : null,
      schedule: DndSchedule.fromJson(json['schedule']),
    );
    return state.until == null && state.schedule == null ? null : state;
  }

  /// [now]에 방해 금지 중인지 — "이 시각까지"가 남았거나 일정 안이면.
  bool isActiveAt(DateTime now) =>
      (until != null && now.isBefore(until!)) ||
      (schedule?.coversAt(now) ?? false);
}

/// "19:00"처럼 하루 중 분을 시각으로.
String formatDayMinute(int minute) =>
    '${(minute ~/ 60).toString().padLeft(2, '0')}:${(minute % 60).toString().padLeft(2, '0')}';

/// 요일 이름(0=일 … 6=토).
final weekdayNames = [
  tr('일'),
  tr('월'),
  tr('화'),
  tr('수'),
  tr('목'),
  tr('금'),
  tr('토'),
];
