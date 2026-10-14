import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/calendar.dart';
import '../../services/api_client.dart' show ApiException;
import '../../services/calendar_controller.dart';
import '../../widgets/app_toast.dart';

/// 외부 캘린더 연동 — 회사 일정을 Google·Outlook 등에서 관리하는 팀이 일정을 두 번 넣지 않게.
///  - 가져오기([showAddExternalCalendarDialog]): 외부 캘린더의 ICS 주소를 구독한다(나에게만 보이고 읽기 전용, 서버가 30분마다 받는다).
///  - 내보내기([showCalendarFeedDialog]): 내가 보는 일정을 ICS 구독 주소로 만들어 Google·Outlook 캘린더에 "URL로 추가"한다.
/// 서버는 server/src/externalCalendars.js·calendarFeeds.js.

/// "방금 전" / "12분 전" / "3시간 전" / "10/14" — 외부 캘린더를 마지막으로 받아 온 때.
String externalUpdatedLabel(DateTime at, {DateTime? now}) {
  final diff = (now ?? DateTime.now()).difference(at);
  if (diff.inMinutes < 1) return '방금 전';
  if (diff.inMinutes < 60) return '${diff.inMinutes}분 전';
  if (diff.inHours < 24) return '${diff.inHours}시간 전';
  return '${at.month}/${at.day}';
}

/// 목록 줄 아래의 작은 상태 문구 — 실패했으면 그 이유, 아니면 "calendar.google.com · 12분 전 업데이트".
String externalStatusLabel(CalendarInfo calendar, {DateTime? now}) {
  if (calendar.lastError != null) return calendar.lastError!;
  final parts = [
    if ((calendar.host ?? '').isNotEmpty) calendar.host!,
    if (calendar.lastSuccessAt != null)
      '${externalUpdatedLabel(calendar.lastSuccessAt!, now: now)} 업데이트',
  ];
  return parts.join(' · ');
}

/// 외부 캘린더(ICS 주소) 추가.
Future<void> showAddExternalCalendarDialog(
  BuildContext context,
  CalendarController controller,
) => showDialog<void>(
  context: context,
  builder: (_) => _AddExternalCalendarDialog(controller: controller),
);

class _AddExternalCalendarDialog extends StatefulWidget {
  final CalendarController controller;
  const _AddExternalCalendarDialog({required this.controller});

  @override
  State<_AddExternalCalendarDialog> createState() =>
      _AddExternalCalendarDialogState();
}

class _AddExternalCalendarDialogState
    extends State<_AddExternalCalendarDialog> {
  final _url = TextEditingController();
  final _name = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _url.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final url = _url.text.trim();
    if (url.isEmpty) {
      setState(() => _error = '구독 주소(ICS)를 입력하세요.');
      return;
    }
    final name = _name.text.trim();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final calendar = await widget.controller.addExternalCalendar(
        url,
        name: name.isEmpty ? null : name,
      );
      if (!mounted) return;
      Navigator.of(context).pop();
      showAppToast(context, '"${calendar.name}" 캘린더를 구독했습니다.');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e is ApiException ? e.message : '캘린더를 추가하지 못했습니다.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    return AlertDialog(
      title: const Text('외부 캘린더 추가'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Google·Outlook·iCloud 캘린더의 ICS 구독 주소를 넣으면 그 일정이 내 캘린더에 함께 보입니다. '
                '나에게만 보이고, 여기서는 고칠 수 없으며, 30분마다 새로 받아 옵니다.',
                style: hint,
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('ext-url'),
                controller: _url,
                autofocus: true,
                enabled: !_busy,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: '구독 주소 (https:// 또는 webcal://)',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('ext-name'),
                controller: _name,
                enabled: !_busy,
                maxLength: 30,
                decoration: const InputDecoration(
                  labelText: '이름 (비우면 캘린더 이름 그대로)',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    _error!,
                    key: const ValueKey('ext-error'),
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ),
              Text('주소 찾는 곳', style: theme.textTheme.labelLarge),
              const SizedBox(height: 4),
              Text(
                '• Google 캘린더: 설정 → 왼쪽에서 캘린더 선택 → "캘린더 통합" → "iCal 형식의 비공개 주소"\n'
                '• Outlook(웹): 설정 → 캘린더 → 공유 캘린더 → "캘린더 게시" → ICS 링크\n'
                '• 회사 공용 캘린더: 관리자에게 ICS(iCal) 구독 주소를 받으세요.\n'
                '비공개 주소는 비밀번호처럼 다른 사람에게 알려 주지 마세요.',
                style: hint,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        FilledButton(
          key: const ValueKey('ext-submit'),
          onPressed: _busy ? null : _submit,
          child: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('추가'),
        ),
      ],
    );
  }
}

/// 외부 캘린더 구독 해지 — 확인 후 끊는다.
Future<void> confirmRemoveExternalCalendar(
  BuildContext context,
  CalendarController controller,
  CalendarInfo calendar,
) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('구독 해지'),
      content: Text(
        '"${calendar.name}" 캘린더 구독을 해지할까요? 원래 캘린더(${calendar.host ?? '외부'})의 일정은 그대로입니다.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('취소'),
        ),
        FilledButton(
          key: const ValueKey('ext-remove-confirm'),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('해지'),
        ),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;
  try {
    await controller.removeExternalCalendar(calendar);
  } catch (e) {
    if (context.mounted) {
      showAppToast(context, e is ApiException ? e.message : '구독을 해지하지 못했습니다.');
    }
  }
}

/// 외부 캘린더를 지금 다시 받는다.
Future<void> refreshExternalCalendarNow(
  BuildContext context,
  CalendarController controller,
  CalendarInfo calendar,
) async {
  try {
    final updated = await controller.refreshExternalCalendar(calendar);
    if (!context.mounted) return;
    showAppToast(
      context,
      updated.lastError ?? '"${updated.name}" 캘린더를 새로 받았습니다.',
    );
  } catch (e) {
    if (context.mounted) {
      showAppToast(context, e is ApiException ? e.message : '새로 받지 못했습니다.');
    }
  }
}

/// 내 일정 내보내기 — ICS 구독 주소를 만들고 복사한다.
Future<void> showCalendarFeedDialog(
  BuildContext context,
  CalendarController controller,
) => showDialog<void>(
  context: context,
  builder: (_) => _CalendarFeedDialog(controller: controller),
);

class _CalendarFeedDialog extends StatefulWidget {
  final CalendarController controller;
  const _CalendarFeedDialog({required this.controller});

  @override
  State<_CalendarFeedDialog> createState() => _CalendarFeedDialogState();
}

class _CalendarFeedDialogState extends State<_CalendarFeedDialog> {
  CalendarFeed? _feed;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _run(widget.controller.fetchCalendarFeed);
  }

  Future<void> _run(
    Future<CalendarFeed> Function() action, {
    String? done,
  }) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final feed = await action();
      if (!mounted) return;
      setState(() {
        _feed = feed;
        _busy = false;
      });
      if (done != null) showAppToast(context, done);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e is ApiException ? e.message : '내보내기 주소를 처리하지 못했습니다.';
      });
    }
  }

  Future<void> _reset() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('새 주소로 바꾸기'),
        content: const Text(
          '지금 주소는 바로 끊기고, 그 주소로 구독한 곳(Google·Outlook 등)에서는 일정이 더 이상 갱신되지 않습니다. 바꿀까요?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            key: const ValueKey('feed-reset-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('바꾸기'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      await _run(
        widget.controller.createCalendarFeed,
        done: '새 주소를 만들었습니다. 구독한 곳에 새 주소를 다시 넣으세요.',
      );
    }
  }

  Future<void> _copy(String url) async {
    await Clipboard.setData(ClipboardData(text: url));
    if (mounted) showAppToast(context, '주소를 복사했습니다.');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    final feed = _feed;
    final url = feed?.url;
    final children = <Widget>[
      Text(
        '내가 앱에서 보는 일정(숨긴 캘린더·공휴일·생일·외부 캘린더 제외)을 ICS 구독 주소로 내보냅니다. '
        'Google·Outlook 캘린더에 이 주소를 추가하면 지난 60일부터 앞으로 1년까지의 일정이 따라옵니다(읽기 전용).',
        style: hint,
      ),
      const SizedBox(height: 12),
    ];
    if (feed == null) {
      children.add(
        _error != null
            ? Text(_error!, style: TextStyle(color: theme.colorScheme.error))
            : const Center(
                child: SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
      );
    } else if (url == null) {
      children.add(
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            key: const ValueKey('feed-create'),
            onPressed: _busy
                ? null
                : () => _run(
                    widget.controller.createCalendarFeed,
                    done: '내보내기 주소를 만들었습니다.',
                  ),
            icon: const Icon(Icons.link),
            label: const Text('주소 만들기'),
          ),
        ),
      );
    } else {
      children.addAll([
        Container(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
          decoration: BoxDecoration(
            border: Border.all(color: theme.dividerColor),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Expanded(
                child: SelectableText(
                  url,
                  key: const ValueKey('feed-url'),
                  style: theme.textTheme.bodySmall,
                ),
              ),
              IconButton(
                key: const ValueKey('feed-copy'),
                tooltip: '복사',
                icon: const Icon(Icons.copy, size: 18),
                onPressed: () => _copy(url),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '이 주소를 아는 사람은 누구나 내 일정을 볼 수 있습니다. 새어 나갔다면 "새 주소로 바꾸기"를 누르세요.',
          style: hint,
        ),
        if (!feed.publicAddress) ...[
          const SizedBox(height: 8),
          Text(
            '이 서버에는 공인 인증서가 걸린 웹 주소(도메인)가 없어, Google·Outlook 같은 인터넷 서비스가 이 주소를 받지 못할 수 '
            '있습니다. 서버 관리자에게 웹 주소 설정을 요청하세요(사내망의 Outlook 데스크톱 등은 될 수 있습니다).',
            key: const ValueKey('feed-no-public'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ],
        const SizedBox(height: 12),
        Text('추가하는 곳', style: theme.textTheme.labelLarge),
        const SizedBox(height: 4),
        Text(
          '• Google 캘린더: 왼쪽 "다른 캘린더" 옆 + → "URL로 추가"\n'
          '• Outlook: 캘린더 추가 → "웹에서 구독"\n'
          '구독한 쪽이 몇 시간마다 새로 받아 가므로, 바뀐 일정이 늦게 보일 수 있습니다.',
          style: hint,
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
        ],
      ]);
    }
    return AlertDialog(
      title: const Text('내 일정 내보내기'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: children,
          ),
        ),
      ),
      actions: [
        if (url != null) ...[
          TextButton(
            key: const ValueKey('feed-delete'),
            onPressed: _busy
                ? null
                : () => _run(
                    widget.controller.deleteCalendarFeed,
                    done: '내보내기를 껐습니다.',
                  ),
            child: const Text('끄기'),
          ),
          TextButton(
            key: const ValueKey('feed-reset'),
            onPressed: _busy ? null : _reset,
            child: const Text('새 주소로 바꾸기'),
          ),
        ],
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('닫기'),
        ),
      ],
    );
  }
}
