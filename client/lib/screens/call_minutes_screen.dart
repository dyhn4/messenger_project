import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/call_card.dart' show formatCallDuration;
import '../models/call_recording.dart';
import '../models/room.dart';
import '../services/api_client.dart' show ApiException;
import '../services/session.dart';
import '../widgets/app_toast.dart';
import 'project/note_markdown.dart' show NoteBody;
import '../l10n/tr.dart';

/// 회의록 화면 열기 — 화상회의 카드의 [회의록](call_message_card.dart).
Future<void> showCallMinutesScreen(
  BuildContext context,
  Session session,
  Room room,
  String recordingId,
) {
  return Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => CallMinutesScreen(
        session: session,
        room: room,
        recordingId: recordingId,
      ),
    ),
  );
}

String _two(int n) => n.toString().padLeft(2, '0');

String _stamp(DateTime d) =>
    '${d.year}-${_two(d.month)}-${_two(d.day)} ${_two(d.hour)}:${_two(d.minute)}';

/// 회의록 한 편을 마크다운으로 — 복사·위키 저장에 쓴다. 회의 정보, 요약(있으면), 받아쓰기 순.
String callMinutesMarkdown(CallRecording r, {required String roomName}) {
  final lines = <String>[
    '# ${tr('회의록')} — $roomName ${_stamp(r.startedAt)}',
    '',
    '- ${tr('일시')}: ${_stamp(r.startedAt)}${r.duration != null ? ' (${formatCallDuration(r.duration!)})' : ''}',
    if (r.participantNames.isNotEmpty)
      '- ${tr('참석자')}: ${r.participantNames.join(', ')}',
    '- ${r.audioOnly ? tr('녹음') : tr('녹화')}: ${r.startedByName}',
    '',
    if (r.summary?.isNotEmpty == true) ...[r.summary!.trim(), ''],
    if (r.transcript?.isNotEmpty == true) ...[
      '## ${tr('받아쓰기')}',
      '',
      r.transcript!.trim(),
    ],
  ];
  return '${lines.join('\n').trimRight()}\n';
}

/// 회의록 — 화상회의 녹화 한 번의 받아쓰기·요약(서버 callMinutes.js). 만드는 중이면 몇 초마다 다시 읽고, 다 되면 복사하거나 팀
/// 위키에 새 페이지로 저장할 수 있다. 못 만들었으면 이유와 [다시 만들기](녹화를 시작한 사람·토픽 관리자).
class CallMinutesScreen extends StatefulWidget {
  final Session session;
  final Room room;
  final String recordingId;

  /// 만드는 중일 때 다시 읽는 간격.
  final Duration pollInterval;

  const CallMinutesScreen({
    super.key,
    required this.session,
    required this.room,
    required this.recordingId,
    this.pollInterval = const Duration(seconds: 5),
  });

  @override
  State<CallMinutesScreen> createState() => _CallMinutesScreenState();
}

class _CallMinutesScreenState extends State<CallMinutesScreen> {
  CallRecording? _rec;
  String? _error;
  Timer? _poll;
  bool _busy = false;
  bool _showTranscript = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final rec = await widget.session.api!.fetchCallRecording(
        widget.recordingId,
      );
      if (!mounted) return;
      setState(() {
        _rec = rec;
        _error = null;
        // 요약이 없으면 받아쓰기를 펼쳐 둔다.
        if (rec.summary?.isNotEmpty != true) _showTranscript = true;
      });
      _schedulePoll(rec);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e is ApiException ? e.message : e.toString());
    }
  }

  void _schedulePoll(CallRecording rec) {
    _poll?.cancel();
    final working =
        callMinutesInProgress(rec.minutesStatus) ||
        rec.status == CallRecordingStatus.recording ||
        rec.status == CallRecordingStatus.processing;
    if (working) _poll = Timer(widget.pollInterval, _load);
  }

  String get _markdown =>
      callMinutesMarkdown(_rec!, roomName: _roomName(widget.room));

  String _roomName(Room room) => room.displayName(widget.session.userId ?? '');

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _markdown));
    if (mounted) showAppToast(context, tr('회의록을 복사했습니다'));
  }

  Future<void> _saveToWiki() async {
    final rec = _rec;
    if (rec == null) return;
    setState(() => _busy = true);
    try {
      await widget.session.api!.createWikiPage(
        widget.room.teamId,
        '${tr('회의록')} ${_roomName(widget.room)} ${_stamp(rec.startedAt)}',
        body: _markdown,
      );
      if (mounted) showAppToast(context, tr('팀 위키에 새 페이지로 저장했습니다'));
    } catch (e) {
      if (mounted) {
        showAppToast(
          context,
          tr('위키에 저장하지 못했습니다: {e}', {'e': e is ApiException ? e.message : e}),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _retry() async {
    setState(() => _busy = true);
    try {
      final rec = await widget.session.api!.retryCallMinutes(
        widget.recordingId,
      );
      if (!mounted) return;
      setState(() => _rec = rec);
      _schedulePoll(rec);
    } catch (e) {
      if (mounted) {
        showAppToast(context, e is ApiException ? e.message : e.toString());
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final rec = _rec;
    final done = rec?.minutesStatus == CallMinutesStage.done;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('회의록')),
        actions: [
          if (done) ...[
            IconButton(
              key: const ValueKey('minutes-copy'),
              tooltip: tr('복사'),
              icon: const Icon(Icons.copy),
              onPressed: _copy,
            ),
            IconButton(
              key: const ValueKey('minutes-wiki'),
              tooltip: tr('팀 위키에 저장'),
              icon: const Icon(Icons.menu_book_outlined),
              onPressed: _busy ? null : _saveToWiki,
            ),
          ],
          IconButton(
            tooltip: tr('새로 고침'),
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
        ],
      ),
      body: _error != null && rec == null
          ? Center(child: Text(_error!))
          : rec == null
          ? const Center(child: CircularProgressIndicator())
          : _body(context, rec),
    );
  }

  Widget _body(BuildContext context, CallRecording rec) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final info = [
      _stamp(rec.startedAt),
      if (rec.duration != null) formatCallDuration(rec.duration!),
      tr('{name} {what}', {
        'name': rec.startedByName,
        'what': rec.audioOnly ? tr('녹음') : tr('녹화'),
      }),
    ].join(' · ');
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        Text(_roomName(widget.room), style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(info, style: muted),
        if (rec.participantNames.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(
            tr('참석자: {names}', {'names': rec.participantNames.join(', ')}),
            style: muted,
          ),
        ],
        const SizedBox(height: 12),
        if (rec.status == CallRecordingStatus.failed && rec.error != null)
          _notice(
            context,
            Icons.error_outline,
            scheme.error,
            tr('녹화에 실패했습니다: {e}', {'e': rec.error!}),
          ),
        if (callMinutesInProgress(rec.minutesStatus) ||
            rec.status == CallRecordingStatus.recording ||
            rec.status == CallRecordingStatus.processing)
          _notice(
            context,
            Icons.hourglass_top,
            scheme.primary,
            rec.status == CallRecordingStatus.recording
                ? tr('아직 녹화 중입니다. 녹화를 멈추면 회의록을 만듭니다.')
                : rec.status == CallRecordingStatus.processing
                ? tr('녹화 파일을 마무리하는 중입니다.')
                : tr('{stage}… 끝나면 여기에 나옵니다.', {
                    'stage': callMinutesStageLabel(rec.minutesStatus),
                  }),
            busy: true,
          ),
        if (rec.minutesStatus == CallMinutesStage.failed) ...[
          _notice(
            context,
            Icons.error_outline,
            scheme.error,
            tr('회의록을 만들지 못했습니다: {e}', {
              'e': rec.minutesError ?? tr('알 수 없는 오류'),
            }),
          ),
          if (rec.canRetry)
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonalIcon(
                key: const ValueKey('minutes-retry'),
                onPressed: _busy ? null : _retry,
                icon: const Icon(Icons.refresh),
                label: Text(tr('다시 만들기')),
              ),
            ),
          const SizedBox(height: 12),
        ],
        if (rec.minutesStatus == CallMinutesStage.none)
          _notice(
            context,
            Icons.info_outline,
            scheme.onSurfaceVariant,
            tr('이 녹화는 회의록을 만들지 않았습니다.'),
          ),
        if (rec.summary?.isNotEmpty == true) ...[
          NoteBody(rec.summary!),
          const SizedBox(height: 16),
        ],
        if (rec.transcript?.isNotEmpty == true) ...[
          const Divider(),
          InkWell(
            key: const ValueKey('minutes-transcript-toggle'),
            onTap: () => setState(() => _showTranscript = !_showTranscript),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      tr('받아쓰기 전문'),
                      style: theme.textTheme.titleSmall,
                    ),
                  ),
                  Icon(_showTranscript ? Icons.expand_less : Icons.expand_more),
                ],
              ),
            ),
          ),
          if (_showTranscript)
            SelectableText(
              rec.transcript!,
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
            ),
        ],
      ],
    );
  }

  Widget _notice(
    BuildContext context,
    IconData icon,
    Color color,
    String text, {
    bool busy = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          busy
              ? SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: color,
                  ),
                )
              : Icon(icon, color: color, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}
