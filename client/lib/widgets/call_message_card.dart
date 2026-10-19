import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/call_card.dart';
import '../models/call_recording.dart';
import '../models/message.dart';
import '../models/room.dart';
import '../screens/call_minutes_screen.dart';
import '../screens/call_screen.dart';
import '../services/session.dart';
import 'app_toast.dart';
import '../l10n/tr.dart';

final _timeFormat = DateFormat('a h:mm');

/// 대화방에 통화 한 통마다 한 장 올라오는 화상회의 기록 카드(서버 callCards.js). 대화에 시작·참여·거절·나감을
/// 줄줄이 남기는 대신, 이 카드 한 장에 요약("진행 중 · 12분" / "종료 · 18분" / "부재중")과 [참여] 단추를 두고,
/// 누르면 그 통화의 시간순 기록을 펼쳐 보여 준다. 진행 중에는 call:card로 내용이 그 자리에서 바뀐다
/// (RoomChatController.applyCallCard).
class CallMessageCard extends StatefulWidget {
  final Session session;
  final Room room;
  final Message message;
  const CallMessageCard({
    super.key,
    required this.session,
    required this.room,
    required this.message,
  });

  @override
  State<CallMessageCard> createState() => _CallMessageCardState();
}

class _CallMessageCardState extends State<CallMessageCard> {
  bool _expanded = false;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _syncTicker();
  }

  @override
  void didUpdateWidget(CallMessageCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncTicker();
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  /// 진행 중인 동안만 30초마다 다시 그려 "진행 중 · N분"을 올린다.
  void _syncTicker() {
    final active = widget.message.callCard?.active ?? false;
    if (active && _tick == null) {
      _tick = Timer.periodic(const Duration(seconds: 30), (_) {
        if (mounted) setState(() {});
      });
    } else if (!active) {
      _tick?.cancel();
      _tick = null;
    }
  }

  /// [camera]가 false면 카메라를 끈 채(음성으로) 들어간다.
  Future<void> _join({bool camera = true}) async {
    final session = widget.session;
    if (session.callController.roomId != widget.room.id) {
      try {
        await session.joinCall(widget.room.id, camera: camera);
      } catch (e) {
        if (mounted) showAppToast(context, tr('통화에 참여하지 못했습니다: {e}', {'e': e}));
        return;
      }
    }
    if (mounted) await showCallScreen(context, session, widget.room);
  }

  @override
  Widget build(BuildContext context) {
    final card = widget.message.callCard;
    if (card == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final missed = !card.active && !card.answered;

    final (IconData icon, Color color, String title) = card.active
        ? (
            Icons.videocam,
            Colors.green,
            tr('화상회의 진행 중 · {p0}', {'p0': _elapsedText(card)}),
          )
        : missed
        ? (Icons.missed_video_call, scheme.error, tr('부재중 화상회의'))
        : (
            Icons.videocam_off_outlined,
            scheme.onSurfaceVariant,
            tr('화상회의 종료 · {p0}', {
              'p0': formatCallDuration(card.duration ?? Duration.zero),
            }),
          );
    final parts = <String>[
      tr('{card.starterName} 시작', {'card.starterName': card.starterName}),
      if (card.joinedCount > 1)
        tr('참여 {card.joinedCount}명', {'card.joinedCount': card.joinedCount}),
      if (card.declinedCount > 0)
        tr('거절 {card.declinedCount}명', {
          'card.declinedCount': card.declinedCount,
        }),
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Material(
            key: ValueKey('call-card-${widget.message.id}'),
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              key: const ValueKey('call-card-toggle'),
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        CircleAvatar(
                          radius: 18,
                          backgroundColor: color.withValues(alpha: 0.15),
                          child: Icon(icon, color: color, size: 20),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                title,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '${parts.join(' · ')} · ${_timeFormat.format(card.startedAt)}',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (card.active) _joinButton(),
                        Icon(
                          _expanded ? Icons.expand_less : Icons.expand_more,
                          color: scheme.onSurfaceVariant,
                        ),
                      ],
                    ),
                    // 녹화·회의록 — 접어 둬도 보인다(회의록은 통화가 끝난 뒤에 나온다).
                    for (final r in card.recordings)
                      _RecordingRow(
                        entry: r,
                        onOpenMinutes: () => showCallMinutesScreen(
                          context,
                          widget.session,
                          widget.room,
                          r.id,
                        ),
                      ),
                    if (_expanded) ...[
                      const SizedBox(height: 8),
                      const Divider(height: 1),
                      const SizedBox(height: 6),
                      for (final e in card.events)
                        _TimelineRow(
                          time: e.at,
                          name: e.name,
                          label: e.label,
                          kind: e.kind,
                        ),
                      if (!card.active && card.endedAt != null)
                        _TimelineRow(
                          time: card.endedAt!,
                          name: '',
                          label: tr('통화 종료'),
                        ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 진행 중일 때의 [참여] — 이미 이 통화에 들어와 있으면 통화 화면으로 돌아가는 단추로 바뀐다.
  Widget _joinButton() {
    return ListenableBuilder(
      listenable: widget.session,
      builder: (context, _) {
        if (!widget.session.callsEnabled) return const SizedBox.shrink();
        final joined = widget.session.callController.roomId == widget.room.id;
        return Padding(
          padding: const EdgeInsets.only(left: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 음성으로 참여(카메라 끔) — 이미 들어와 있으면 필요 없다.
              if (!joined)
                IconButton(
                  key: const ValueKey('call-card-join-voice'),
                  tooltip: tr('음성으로 참여(카메라 끔)'),
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.mic_none, color: Colors.green),
                  onPressed: () => _join(camera: false),
                ),
              FilledButton(
                key: const ValueKey('call-card-join'),
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.green,
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                ),
                onPressed: _join,
                child: Text(joined ? tr('통화 화면') : tr('참여')),
              ),
            ],
          ),
        );
      },
    );
  }

  static String _elapsedText(CallCard card) {
    final elapsed = DateTime.now().difference(card.startedAt);
    return elapsed.inMinutes < 1 ? tr('방금 시작') : formatCallDuration(elapsed);
  }
}

/// 카드의 녹화 한 줄 — "● 녹화 · 홍길동 · 오후 2:03"와 상태(녹화 중·마무리 중·실패), 회의록 단추(만드는 중이면 그 단계).
class _RecordingRow extends StatelessWidget {
  final CallRecordingEntry entry;
  final VoidCallback onOpenMinutes;
  const _RecordingRow({required this.entry, required this.onOpenMinutes});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final small = theme.textTheme.bodySmall;
    final what = entry.audioOnly ? tr('녹음') : tr('녹화');
    final (String state, Color color) = switch (entry.status) {
      CallRecordingStatus.recording => (
        entry.audioOnly ? tr('녹음 중') : tr('녹화 중'),
        Colors.red,
      ),
      CallRecordingStatus.processing => (
        tr('파일 마무리 중'),
        scheme.onSurfaceVariant,
      ),
      CallRecordingStatus.done => ('', scheme.onSurfaceVariant),
      CallRecordingStatus.failed => (tr('실패'), scheme.error),
    };
    final minutes = entry.minutes;
    return Padding(
      key: ValueKey('call-card-recording-${entry.id}'),
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          Icon(
            entry.audioOnly ? Icons.mic : Icons.fiber_manual_record,
            size: 14,
            color: entry.status == CallRecordingStatus.recording
                ? Colors.red
                : scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              [
                what,
                entry.name,
                _timeFormat.format(entry.at),
                if (state.isNotEmpty) state,
              ].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: small?.copyWith(
                color: state.isNotEmpty ? color : scheme.onSurfaceVariant,
              ),
            ),
          ),
          if (minutes != CallMinutesStage.none)
            TextButton.icon(
              key: ValueKey('call-card-minutes-${entry.id}'),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                foregroundColor: minutes == CallMinutesStage.failed
                    ? scheme.error
                    : null,
              ),
              onPressed: onOpenMinutes,
              icon: callMinutesInProgress(minutes)
                  ? const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 1.5),
                    )
                  : Icon(
                      minutes == CallMinutesStage.failed
                          ? Icons.error_outline
                          : Icons.description_outlined,
                      size: 16,
                    ),
              label: Text(callMinutesStageLabel(minutes)),
            ),
        ],
      ),
    );
  }
}

/// 펼친 기록의 한 줄 — "오후 2:03  이영희  참여".
class _TimelineRow extends StatelessWidget {
  final DateTime time;
  final String name;
  final String label;
  final CallCardEventKind? kind;
  const _TimelineRow({
    required this.time,
    required this.name,
    required this.label,
    this.kind,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final labelColor = switch (kind) {
      CallCardEventKind.start || CallCardEventKind.join => Colors.green,
      CallCardEventKind.decline => scheme.error,
      _ => scheme.onSurfaceVariant,
    };
    final small = theme.textTheme.bodySmall;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 64,
            child: Text(
              _timeFormat.format(time),
              style: small?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          Expanded(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: small,
            ),
          ),
          Text(
            label,
            style: small?.copyWith(
              color: labelColor,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
