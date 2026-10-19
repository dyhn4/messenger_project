import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/call_recording.dart';
import '../../l10n/tr.dart';

/// "녹화 중 12:34" — 통화 화면 왼쪽 위에 녹화하는 동안 모두에게 보인다(Egress는 숨은 참가자라 참가자 목록에는 안 보인다).
/// [onStop]을 주면(진행자·시작한 사람) 눌러서 멈출 수 있다.
class CallRecordingPill extends StatefulWidget {
  final CallRecordingLive recording;
  final VoidCallback? onStop;
  const CallRecordingPill({super.key, required this.recording, this.onStop});

  @override
  State<CallRecordingPill> createState() => _CallRecordingPillState();
}

class _CallRecordingPillState extends State<CallRecordingPill> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  static String _clock(Duration d) {
    final s = d.inSeconds < 0 ? 0 : d.inSeconds;
    String two(int n) => n.toString().padLeft(2, '0');
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    return h > 0 ? '$h:${two(m)}:${two(s % 60)}' : '${two(m)}:${two(s % 60)}';
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.recording;
    final label = r.audioOnly ? tr('녹음 중') : tr('녹화 중');
    final elapsed = _clock(DateTime.now().difference(r.startedAt));
    final tooltip = [
      tr('{name}님이 시작', {'name': r.byName}),
      if (r.minutes) tr('끝나면 회의록을 만듭니다'),
      if (widget.onStop != null) tr('누르면 멈춥니다'),
    ].join(' · ');
    return Tooltip(
      message: tooltip,
      child: Material(
        key: const ValueKey('call-recording-pill'),
        color: Colors.black54,
        shape: const StadiumBorder(),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: widget.onStop,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.fiber_manual_record,
                  color: Colors.redAccent,
                  size: 14,
                ),
                const SizedBox(width: 5),
                Text(
                  '$label $elapsed',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                if (r.minutes) ...[
                  const SizedBox(width: 6),
                  const Icon(
                    Icons.description_outlined,
                    color: Colors.white70,
                    size: 14,
                  ),
                ],
                if (widget.onStop != null) ...[
                  const SizedBox(width: 6),
                  const Icon(Icons.stop, color: Colors.white, size: 16),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 녹화를 어떻게 할지 — [audioOnly]면 소리만(mp3), [minutes]면 끝난 뒤 회의록.
typedef CallRecordingChoice = ({bool audioOnly, bool minutes});

/// [녹화]를 눌렀을 때의 창 — 영상/소리만과 "끝나면 회의록 만들기"(서버에 받아쓰기가 있을 때만)를 고른다. 취소하면 null.
Future<CallRecordingChoice?> showCallRecordingStartDialog(
  BuildContext context, {
  required bool minutesAvailable,
  required bool summaryAvailable,
}) {
  return showDialog<CallRecordingChoice>(
    context: context,
    builder: (_) => _StartDialog(
      minutesAvailable: minutesAvailable,
      summaryAvailable: summaryAvailable,
    ),
  );
}

class _StartDialog extends StatefulWidget {
  final bool minutesAvailable;
  final bool summaryAvailable;
  const _StartDialog({
    required this.minutesAvailable,
    required this.summaryAvailable,
  });

  @override
  State<_StartDialog> createState() => _StartDialogState();
}

class _StartDialogState extends State<_StartDialog> {
  bool _audioOnly = false;
  late bool _minutes = widget.minutesAvailable;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return AlertDialog(
      title: Text(tr('녹화 시작')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            RadioGroup<bool>(
              groupValue: _audioOnly,
              onChanged: (v) => setState(() => _audioOnly = v ?? false),
              child: Column(
                children: [
                  RadioListTile<bool>(
                    key: const ValueKey('call-record-video'),
                    contentPadding: EdgeInsets.zero,
                    value: false,
                    title: Text(tr('영상과 소리(mp4)')),
                  ),
                  RadioListTile<bool>(
                    key: const ValueKey('call-record-audio'),
                    contentPadding: EdgeInsets.zero,
                    value: true,
                    title: Text(tr('소리만(mp3)')),
                  ),
                ],
              ),
            ),
            if (widget.minutesAvailable)
              CheckboxListTile(
                key: const ValueKey('call-record-minutes'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _minutes,
                onChanged: (v) => setState(() => _minutes = v ?? false),
                title: Text(tr('끝나면 회의록 만들기')),
                subtitle: Text(
                  widget.summaryAvailable
                      ? tr('녹음을 받아쓰고 요약합니다(결정 사항·할 일)')
                      : tr('녹음을 받아씁니다'),
                ),
              ),
            const SizedBox(height: 8),
            Text(
              tr(
                '녹화하는 동안 참가자 모두의 화면에 "녹화 중"이 보입니다. 멈추거나 통화가 끝나면 녹화 파일이 이 대화방에 올라갑니다.',
              ),
              style: small,
            ),
            if (widget.minutesAvailable && _minutes) ...[
              const SizedBox(height: 6),
              Text(
                tr('회의록을 만들려고 녹음을 서버에 설정된 받아쓰기·요약 서비스로 보냅니다.'),
                style: small,
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr('취소')),
        ),
        FilledButton.icon(
          key: const ValueKey('call-record-start'),
          style: FilledButton.styleFrom(backgroundColor: Colors.red),
          onPressed: () => Navigator.of(context).pop((
            audioOnly: _audioOnly,
            minutes: widget.minutesAvailable && _minutes,
          )),
          icon: const Icon(Icons.fiber_manual_record, size: 16),
          label: Text(tr('녹화 시작')),
        ),
      ],
    );
  }
}
