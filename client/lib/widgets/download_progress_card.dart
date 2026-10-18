import 'dart:async';

import 'package:flutter/material.dart';

import '../services/download_progress.dart';
import 'attachment_widgets.dart' show formatFileSize;
import '../l10n/tr.dart';

/// 내려받는 동안 화면 구석에 뜨는 진행 카드 — 파일 이름(여러 개면 "파일 N개"), 진행 막대, "3.2 MB / 10.5 MB · 31%"
/// (여러 개면 "2/5개 · 받은 양"), 멈추는 X. 다 받으면 사라지고, 끝난 알림은 지금처럼 알약(토스트)으로 뜬다.
/// 말풍선의 다운로드 단추처럼 자기 자리에 진행을 그리는 것([DownloadTask.inline] — [DownloadProgressPill])은 여기 띄우지
/// 않는다 — 앨범·할 일의 전체 다운로드, 더보기 메뉴의 다운로드처럼 그럴 자리가 없는 것만.
///
/// PC처럼 넓은 화면은 오른쪽 아래(가운데 아래에 뜨는 알약과 겹치지 않게), 휴대폰은 입력칸을 가리지 않게 위쪽에 둔다.
/// 금방 끝나는 작은 파일까지 번쩍 떴다 사라지지 않게, 시작하고 [_showDelay]가 지난 것만 보인다.
/// MaterialApp.builder(main.dart)에서 모든 화면 위에 얹는다.
class DownloadProgressCard extends StatefulWidget {
  const DownloadProgressCard({super.key});

  @override
  State<DownloadProgressCard> createState() => _DownloadProgressCardState();
}

const _showDelay = Duration(milliseconds: 400);

class _DownloadProgressCardState extends State<DownloadProgressCard> {
  final _progress = DownloadProgress.instance;

  /// 처음 보고 [_showDelay]가 지나 카드에 보이는 것, 아직 기다리는 것(그 타이머).
  final _shown = <DownloadTask>{};
  final _waiting = <DownloadTask, Timer>{};

  @override
  void initState() {
    super.initState();
    _progress.addListener(_changed);
  }

  @override
  void dispose() {
    _progress.removeListener(_changed);
    for (final timer in _waiting.values) {
      timer.cancel();
    }
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    final tasks = _progress.tasks.toSet();
    // 끝난 것은 잊는다.
    _shown.retainAll(tasks);
    _waiting.removeWhere((t, timer) {
      if (tasks.contains(t)) return false;
      timer.cancel();
      return true;
    });
    for (final t in tasks) {
      if (_shown.contains(t) || _waiting.containsKey(t)) continue;
      // 받은 양이 그동안 안 바뀌어도(느린 연결) 때가 되면 보이게 타이머로.
      _waiting[t] = Timer(_showDelay, () {
        if (!mounted || _waiting.remove(t) == null) return;
        setState(() => _shown.add(t));
      });
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final visible = [
      for (final t in _progress.tasks)
        if (_shown.contains(t) && !t.inline) t,
    ];
    if (visible.isEmpty) return const SizedBox.shrink();
    final size = MediaQuery.sizeOf(context);
    final padding = MediaQuery.paddingOf(context);
    final wide = size.width >= 600;
    final cards = Material(
      key: const ValueKey('download-progress'),
      elevation: 6,
      borderRadius: BorderRadius.circular(12),
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (i, t) in visible.indexed) ...[
              if (i > 0) const SizedBox(height: 10),
              _TaskRow(task: t),
            ],
          ],
        ),
      ),
    );
    return wide
        ? Positioned(
            right: 16 + padding.right,
            bottom: 24 + padding.bottom,
            width: 320,
            child: cards,
          )
        : Positioned(
            left: 12 + padding.left,
            right: 12 + padding.right,
            top: padding.top + 64,
            child: cards,
          );
  }
}

class _TaskRow extends StatelessWidget {
  final DownloadTask task;
  const _TaskRow({required this.task});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final fraction = task.fraction;
    final detail = downloadDetailText(task);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Icon(
              Icons.download_rounded,
              size: 18,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                task.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            _CancelButton(task: task),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            // 크기를 모르면(서버가 알려 주지 않음) 움직이는 막대.
            value: fraction,
            minHeight: 6,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          tr('다운로드 중 · {detail}', {'detail': detail}),
          key: const ValueKey('download-progress-detail'),
          style: theme.textTheme.bodySmall?.copyWith(color: hint),
        ),
      ],
    );
  }
}

/// "3.2MB / 10.5MB · 31%"(여러 개면 "2/5개 · 받은 양 · 40%") — 크기를 모르면 받은 양만.
String downloadDetailText(DownloadTask task) {
  final fraction = task.fraction;
  final total = task.total;
  return [
    if (task.fileCount > 1)
      tr('{p0}/{task.fileCount}개', {
        'p0': (task.filesDone + 1).clamp(1, task.fileCount),
        'task.fileCount': task.fileCount,
      }),
    if (task.fileCount <= 1 && total != null)
      '${formatFileSize(task.received)} / ${formatFileSize(total)}'
    else
      formatFileSize(task.receivedBytes),
    if (fraction != null) '${(fraction * 100).floor()}%',
  ].join(' · ');
}

/// 내려받기를 멈추는 작은 X.
class _CancelButton extends StatelessWidget {
  final DownloadTask task;
  const _CancelButton({required this.task});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      key: const ValueKey('download-cancel'),
      tooltip: tr('다운로드 취소'),
      onPressed: task.cancelled ? null : task.cancel,
      icon: const Icon(Icons.close, size: 16),
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 26, height: 26),
    );
  }
}

/// 말풍선의 다운로드 단추 바로 왼쪽에 붙는 작은 진행 표시 — 진행 막대, "31%"(여러 개면 "2/5개 · 31%"), 멈추는 X.
/// 마우스를 올리면 받은 양("3.2MB / 10.5MB")이 풍선 도움말로 보인다. 단추 옆의 떠 있는 툴바와 같은 높이·모양이다.
/// 다 받으면(저장 창이 떠 있는 동안 포함) 스스로 사라진다.
class DownloadProgressPill extends StatelessWidget {
  final DownloadTask task;

  /// 진행 막대 폭 — 자리가 넉넉한 "전체 다운로드" 줄은 조금 길게.
  final double barWidth;

  /// 이 폭 안에 들어가게 진행 막대를 줄인다(작은 사진 칸) — 아주 좁으면 막대 없이 숫자와 X만.
  final double? maxWidth;
  const DownloadProgressPill({
    super.key,
    required this.task,
    this.barWidth = 56,
    this.maxWidth,
  });

  /// 막대를 뺀 나머지(좌우 여백·숫자·X·사이 간격)의 대략적인 폭.
  static const _restWidth = 96.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: task,
      builder: (context, _) {
        if (task.finished) return const SizedBox.shrink();
        final limit = maxWidth;
        final bar = limit == null
            ? barWidth
            : (limit - _restWidth).clamp(0.0, barWidth);
        final fraction = task.fraction;
        final short = [
          if (task.fileCount > 1)
            tr('{p0}/{task.fileCount}개', {
              'p0': (task.filesDone + 1).clamp(1, task.fileCount),
              'task.fileCount': task.fileCount,
            }),
          fraction != null
              ? '${(fraction * 100).floor()}%'
              : formatFileSize(task.receivedBytes),
        ].join(' · ');
        return Tooltip(
          message: tr('다운로드 중 · {p0}', {'p0': downloadDetailText(task)}),
          child: Material(
            key: const ValueKey('download-pill'),
            elevation: 3,
            shadowColor: Colors.black.withValues(alpha: 0.3),
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(18),
            child: Container(
              height: 32,
              padding: const EdgeInsets.only(left: 10, right: 2),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: theme.dividerColor),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (bar >= 16) ...[
                    // 자리가 모자라면(좁은 말풍선) 막대가 줄어든다 — 숫자와 X는 그대로.
                    Flexible(
                      child: SizedBox(
                        width: bar,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(3),
                          child: LinearProgressIndicator(
                            value: fraction,
                            minHeight: 5,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                  Text(
                    short,
                    key: const ValueKey('download-pill-text'),
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  _CancelButton(task: task),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
