/// 화상회의 녹화·회의록 — 서버 callRecording.js·callMinutes.js. 녹화 한 번마다 대화방에 파일 메시지가 올라가고, 회의록을
/// 원했으면 녹음을 받아쓰고 요약한다. 통화 중에는 call:state의 recording([CallRecordingLive]), 대화방 화상회의 카드에는
/// 녹화마다 짧은 상태([CallRecordingEntry]), 회의록 화면은 녹화 한 건 전체([CallRecording])를 쓴다.
library;

import '../l10n/tr.dart';

/// 녹화 파일의 단계 — 녹화 중 → 마무리 중(Egress가 파일을 다 쓰고 대화방에 올림) → 완료 | 실패.
enum CallRecordingStatus { recording, processing, done, failed }

CallRecordingStatus _statusOf(Object? raw) => switch (raw) {
  'recording' => CallRecordingStatus.recording,
  'processing' => CallRecordingStatus.processing,
  'done' => CallRecordingStatus.done,
  _ => CallRecordingStatus.failed,
};

/// 회의록 단계 — 안 함 | 기다림 → 받아쓰는 중 → 요약하는 중 → 완료 | 실패.
enum CallMinutesStage { none, pending, transcribing, summarizing, done, failed }

CallMinutesStage _minutesOf(Object? raw) => switch (raw) {
  'pending' => CallMinutesStage.pending,
  'transcribing' => CallMinutesStage.transcribing,
  'summarizing' => CallMinutesStage.summarizing,
  'done' => CallMinutesStage.done,
  'failed' => CallMinutesStage.failed,
  _ => CallMinutesStage.none,
};

DateTime? _time(Object? raw) =>
    raw is num ? DateTime.fromMillisecondsSinceEpoch(raw.toInt()) : null;

/// 회의록을 만드는 중인지(기다림·받아쓰기·요약).
bool callMinutesInProgress(CallMinutesStage s) =>
    s == CallMinutesStage.pending ||
    s == CallMinutesStage.transcribing ||
    s == CallMinutesStage.summarizing;

/// 회의록 단계를 짧게 — 카드·회의록 화면에 쓴다.
String callMinutesStageLabel(CallMinutesStage s) => switch (s) {
  CallMinutesStage.none => '',
  CallMinutesStage.pending => tr('회의록 기다리는 중'),
  CallMinutesStage.transcribing => tr('받아쓰는 중'),
  CallMinutesStage.summarizing => tr('요약하는 중'),
  CallMinutesStage.done => tr('회의록'),
  CallMinutesStage.failed => tr('회의록을 만들지 못함'),
};

/// 지금 녹화 중인 것(call:state의 recording) — 통화 화면의 "녹화 중" 표시.
class CallRecordingLive {
  final String id;
  final String byId;
  final String byName;
  final DateTime startedAt;
  final bool audioOnly;
  final bool minutes;
  const CallRecordingLive({
    required this.id,
    required this.byId,
    required this.byName,
    required this.startedAt,
    this.audioOnly = false,
    this.minutes = false,
  });

  static CallRecordingLive? fromJson(Object? raw) {
    if (raw is! Map || raw['id'] is! String) return null;
    return CallRecordingLive(
      id: raw['id'] as String,
      byId: raw['byId'] as String? ?? '',
      byName: raw['byName'] as String? ?? tr('알 수 없음'),
      startedAt: _time(raw['startedAt']) ?? DateTime.now(),
      audioOnly: raw['audioOnly'] == true,
      minutes: raw['minutes'] == true,
    );
  }
}

/// 화상회의 카드에 실린 녹화 한 건(card.recordings).
class CallRecordingEntry {
  final String id;
  final DateTime at;
  final String? userId;
  final String name;
  final bool audioOnly;
  final CallRecordingStatus status;
  final CallMinutesStage minutes;
  final String? messageId;
  const CallRecordingEntry({
    required this.id,
    required this.at,
    this.userId,
    required this.name,
    this.audioOnly = false,
    required this.status,
    this.minutes = CallMinutesStage.none,
    this.messageId,
  });

  static CallRecordingEntry? fromJson(Object? raw) {
    if (raw is! Map || raw['id'] is! String) return null;
    return CallRecordingEntry(
      id: raw['id'] as String,
      at: _time(raw['at']) ?? DateTime.fromMillisecondsSinceEpoch(0),
      userId: raw['userId'] as String?,
      name: raw['name'] as String? ?? tr('알 수 없음'),
      audioOnly: raw['audioOnly'] == true,
      status: _statusOf(raw['status']),
      minutes: _minutesOf(raw['minutes']),
      messageId: raw['messageId'] as String?,
    );
  }
}

/// 녹화 한 건과 회의록(GET /api/call-recordings/:id).
class CallRecording {
  final String id;
  final String roomId;
  final String? callMessageId;
  final String? startedBy;
  final String startedByName;
  final DateTime startedAt;
  final DateTime? endedAt;
  final Duration? duration;
  final bool audioOnly;
  final CallRecordingStatus status;
  final String? error;
  final String? messageId;
  final CallMinutesStage minutesStatus;
  final String? minutesError;
  final List<String> participantNames;
  final String? transcript;
  final String? summary;

  /// 내가 못 만든 회의록을 다시 만들 수 있는지(시작한 사람·토픽 관리자, 녹음이 남아 있을 때).
  final bool canRetry;

  const CallRecording({
    required this.id,
    required this.roomId,
    this.callMessageId,
    this.startedBy,
    required this.startedByName,
    required this.startedAt,
    this.endedAt,
    this.duration,
    this.audioOnly = false,
    required this.status,
    this.error,
    this.messageId,
    this.minutesStatus = CallMinutesStage.none,
    this.minutesError,
    this.participantNames = const [],
    this.transcript,
    this.summary,
    this.canRetry = false,
  });

  factory CallRecording.fromJson(Map<String, dynamic> json) {
    final durationMs = json['durationMs'];
    return CallRecording(
      id: json['id'] as String,
      roomId: json['roomId'] as String? ?? '',
      callMessageId: json['callMessageId'] as String?,
      startedBy: json['startedBy'] as String?,
      startedByName: json['startedByName'] as String? ?? tr('알 수 없음'),
      startedAt: _time(json['startedAt']) ?? DateTime.now(),
      endedAt: _time(json['endedAt']),
      duration: durationMs is num
          ? Duration(milliseconds: durationMs.toInt())
          : null,
      audioOnly: json['audioOnly'] == true,
      status: _statusOf(json['status']),
      error: json['error'] as String?,
      messageId: json['messageId'] as String?,
      minutesStatus: _minutesOf(json['minutesStatus']),
      minutesError: json['minutesError'] as String?,
      participantNames: [
        for (final n in (json['participantNames'] as List? ?? const []))
          if (n is String) n,
      ],
      transcript: json['transcript'] as String?,
      summary: json['summary'] as String?,
      canRetry: json['canRetry'] == true,
    );
  }
}
