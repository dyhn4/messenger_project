/// 화상회의 기록 카드 — 통화 한 통마다 대화방에 한 장 올라오는 시스템 메시지의 내용(서버 callEvents.js·
/// callCards.js). 시작·참여·거절·나감을 [events]에 쌓고, 진행 중에는 call:card로 그 자리에서 바뀐다.
library;

import '../l10n/tr.dart';
import 'call_recording.dart';

enum CallCardEventKind { start, join, leave, decline }

class CallCardEvent {
  final DateTime at;
  final String userId;
  final String name;
  final CallCardEventKind kind;
  const CallCardEvent({
    required this.at,
    required this.userId,
    required this.name,
    required this.kind,
  });

  static CallCardEvent? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final kind = switch (raw['kind']) {
      'start' => CallCardEventKind.start,
      'join' => CallCardEventKind.join,
      'leave' => CallCardEventKind.leave,
      'decline' => CallCardEventKind.decline,
      _ => null,
    };
    final at = raw['at'];
    if (kind == null || at is! num) return null;
    return CallCardEvent(
      at: DateTime.fromMillisecondsSinceEpoch(at.toInt()),
      userId: raw['userId'] as String? ?? '',
      name: raw['name'] as String? ?? tr('알 수 없음'),
      kind: kind,
    );
  }

  /// 타임라인에 쓰는 말.
  String get label => switch (kind) {
    CallCardEventKind.start => tr('시작'),
    CallCardEventKind.join => tr('참여'),
    CallCardEventKind.leave => tr('나감'),
    CallCardEventKind.decline => tr('거절'),
  };
}

class CallCard {
  final bool active;
  final DateTime startedAt;
  final DateTime? endedAt;
  final Duration? duration;

  /// 건 사람 말고 누가 한 번이라도 들어왔는지 — 끝났는데 false면 부재중.
  final bool answered;
  final List<CallCardEvent> events;

  /// 이 통화에서 한 녹화들(시작 순) — 녹화 파일·회의록 상태(서버 callCards.js refreshCallCardRecordings).
  final List<CallRecordingEntry> recordings;

  const CallCard({
    required this.active,
    required this.startedAt,
    this.endedAt,
    this.duration,
    this.answered = false,
    this.events = const [],
    this.recordings = const [],
  });

  static CallCard? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final startedAt = raw['startedAt'];
    if (startedAt is! num) return null;
    final endedAt = raw['endedAt'];
    final durationMs = raw['durationMs'];
    return CallCard(
      active: raw['status'] == 'active',
      startedAt: DateTime.fromMillisecondsSinceEpoch(startedAt.toInt()),
      endedAt: endedAt is num
          ? DateTime.fromMillisecondsSinceEpoch(endedAt.toInt())
          : null,
      duration: durationMs is num
          ? Duration(milliseconds: durationMs.toInt())
          : null,
      answered: raw['answered'] == true,
      events: [
        for (final e in (raw['events'] as List? ?? const []))
          ?CallCardEvent.fromJson(e),
      ],
      recordings: [
        for (final r in (raw['recordings'] as List? ?? const []))
          ?CallRecordingEntry.fromJson(r),
      ],
    );
  }

  /// 통화를 시작한 사람 이름.
  String get starterName => events
      .firstWhere(
        (e) => e.kind == CallCardEventKind.start,
        orElse: () => events.isEmpty
            ? CallCardEvent(
                at: startedAt,
                userId: '',
                name: tr('알 수 없음'),
                kind: CallCardEventKind.start,
              )
            : events.first,
      )
      .name;

  /// 한 번이라도 들어온 사람 수(시작한 사람 포함, 같은 사람이 다시 들어와도 한 번).
  int get joinedCount => {
    for (final e in events)
      if (e.kind == CallCardEventKind.start || e.kind == CallCardEventKind.join)
        e.userId,
  }.length;

  /// 거절한 사람 수(같은 사람이 여러 번 거절해도 한 번).
  int get declinedCount => {
    for (final e in events)
      if (e.kind == CallCardEventKind.decline) e.userId,
  }.length;
}

/// "12초" / "5분" / "1시간 3분" — 카드의 통화 길이 표시.
String formatCallDuration(Duration d) {
  if (d.inSeconds < 60) {
    return tr('{d.inSeconds}초', {'d.inSeconds': d.inSeconds});
  }
  if (d.inMinutes < 60) {
    return tr('{d.inMinutes}분', {'d.inMinutes': d.inMinutes});
  }
  final m = d.inMinutes % 60;
  return m == 0
      ? tr('{d.inHours}시간', {'d.inHours': d.inHours})
      : tr('{d.inHours}시간 {m}분', {'d.inHours': d.inHours, 'm': m});
}
