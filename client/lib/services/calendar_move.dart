import '../models/calendar.dart';

// 일정 드래그 이동의 순수 계산 — 위젯 없이 테스트할 수 있도록 "어디로 옮기면 start/end가 얼마가 되나"만 모았다.
//
// 규칙(models/calendar.dart의 종일 규약과 같다):
//  - 종일 일정의 start/end는 날짜를 UTC 자정으로 본 ms라서, 옮길 때도 UTC에서 (일수 × 24h)만 더한다.
//    기기 시간대를 거치지 않으므로 어느 시간대에서든 날짜가 어긋나지 않는다.
//  - 시간 일정은 기기 시간대의 "벽시계"를 유지한 채 날짜만 옮긴다(일광절약시간 전환일에도 시각이 그대로).
//  - 시간표에서 시각까지 옮길 때는 10분 단위로 맞추고 길이를 유지한다.

const _dayMs = 86400000;

/// 시간표에서 옮긴 시각을 맞추는 단위(분).
const kMoveSnapMinutes = 10;

/// 옮긴 결과 — 서버로 보낼 start/end/allDay.
class EventMove {
  final int start;
  final int end;
  final bool allDay;
  const EventMove({
    required this.start,
    required this.end,
    required this.allDay,
  });

  /// `PATCH /api/events/:id` 본문(반복이 아니므로 scope 없음).
  Map<String, dynamic> toFields() => {
    'start': start,
    'end': end,
    'allDay': allDay,
  };

  /// [e]를 이 자리로 옮긴 복사본(낙관적 표시용).
  EventOccurrence applyTo(EventOccurrence e) =>
      e.copyWith(start: start, end: end);

  /// 원래 자리와 같은지(= 안 옮긴 것).
  bool isSameAs(EventOccurrence e) => start == e.start && end == e.end;

  @override
  bool operator ==(Object other) =>
      other is EventMove &&
      other.start == start &&
      other.end == end &&
      other.allDay == allDay;

  @override
  int get hashCode => Object.hash(start, end, allDay);

  @override
  String toString() => 'EventMove($start..$end, allDay=$allDay)';
}

/// 드래그로 옮길 수 있는 일정인지 — 내가 만든/수정할 수 있는 사용자 일정이고 반복이 아니며 가려진(비공개 제한)
/// 일정이 아니어야 한다. 공휴일·생일, 수정 권한이 없는 일정, 반복 일정은 안 된다.
bool canDragEvent(EventOccurrence e) =>
    e.isUserEvent &&
    e.eventId != null &&
    e.canEdit &&
    !e.restricted &&
    !e.recurring;

/// 반복 일정이라 드래그는 안 되지만 수정 권한은 있는 일정 — "상세에서 수정하세요" 안내를 붙인다.
bool isDragBlockedByRecurrence(EventOccurrence e) =>
    e.isUserEvent && e.recurring && e.canEdit && !e.restricted;

/// 날짜 [a]에서 [b]까지의 일수(b가 뒤면 양수). 일광절약시간 전환일(하루가 23/25시간)에도 정확하도록
/// 두 날짜를 UTC로 옮겨 센다.
int daysBetween(DateTime a, DateTime b) =>
    (DateTime.utc(b.year, b.month, b.day).millisecondsSinceEpoch -
        DateTime.utc(a.year, a.month, a.day).millisecondsSinceEpoch) ~/
    _dayMs;

/// [e]를 [days]일 옮긴다(시각·길이 유지). 여러 날 일정은 시작을 옮긴 일수만큼 전체가 같이 간다.
EventMove moveEventByDays(EventOccurrence e, int days) {
  if (e.allDay) {
    return EventMove(
      start: e.start + days * _dayMs,
      end: e.end + days * _dayMs,
      allDay: true,
    );
  }
  int shift(int ms) {
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    return DateTime(
      t.year,
      t.month,
      t.day + days,
      t.hour,
      t.minute,
      t.second,
      t.millisecond,
    ).millisecondsSinceEpoch;
  }

  return EventMove(start: shift(e.start), end: shift(e.end), allDay: false);
}

/// [e]의 시작이 [newFirstDay](날짜)가 되도록 옮긴다.
EventMove moveEventToDay(EventOccurrence e, DateTime newFirstDay) =>
    moveEventByDays(e, daysBetween(e.firstDay, newFirstDay));

/// [minutes]를 [step]분 단위로 가장 가까운 값에 맞춘다.
int snapMinutes(int minutes, {int step = kMoveSnapMinutes}) =>
    ((minutes / step).round()) * step;

/// 시간 일정 [e]를 [day]의 [startMinutes]분(0시부터)에 시작하도록 옮긴다. 시각은 10분 단위로 맞추고 길이는
/// 그대로이며, 그 날 안에 머물도록(자정을 넘기지 않게) 위아래 끝에서 멈춘다.
EventMove moveTimedEventTo(
  EventOccurrence e,
  DateTime day,
  int startMinutes, {
  int step = kMoveSnapMinutes,
}) {
  assert(!e.allDay, '종일 일정은 moveEventByDays로 날짜만 옮긴다');
  final durationMs = e.end - e.start;
  final durationMin = (durationMs / 60000).ceil();
  final latest = (1440 - durationMin).clamp(0, 1440 - step).toInt();
  final snapped = snapMinutes(
    startMinutes,
    step: step,
  ).clamp(0, latest).toInt();
  final start = DateTime(day.year, day.month, day.day, 0, snapped);
  return EventMove(
    start: start.millisecondsSinceEpoch,
    end: start.millisecondsSinceEpoch + durationMs,
    allDay: false,
  );
}

/// 그 날 0시부터 [e]가 시작하는 분(시간 일정, 시작한 날 기준).
int minutesIntoDay(EventOccurrence e) {
  final t = e.startTime;
  return t.hour * 60 + t.minute;
}
