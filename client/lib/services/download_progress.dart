import 'dart:async';

import 'package:flutter/foundation.dart';

/// 지금 내려받고 있는 것들.
///
/// 내려받는 쪽은 [trackDownload]로 일을 감싸기만 하면 된다. 그 안에서 불린 [fetchAttachmentBytes]
/// (attachment_widgets.dart)가 받은 바이트를 [DownloadTask.current]에 알리고, 파일 하나를 다 받을 때마다 한 칸씩 센다 —
/// 그래서 파일 하나 받기든 여러 개를 차례로 받는 "전체 다운로드"든 같은 방식으로 진행 상황이 보인다.
///
/// 말풍선의 다운로드 단추처럼 자기 자리에 진행을 그리는 곳은 [DownloadTask]를 직접 만들어(inline) 넘기고 그 작업을 듣는다
/// (download_progress_card.dart의 DownloadProgressPill). 그 밖의 것(앨범·할 일의 전체 다운로드, 더보기 메뉴의 다운로드 등)은
/// 화면 구석의 진행 카드(DownloadProgressCard)에 보인다.
class DownloadProgress extends ChangeNotifier {
  DownloadProgress._();
  static final instance = DownloadProgress._();

  final List<DownloadTask> _tasks = [];

  /// 진행 중인 것(시작한 순서).
  List<DownloadTask> get tasks => List.unmodifiable(_tasks);

  void _add(DownloadTask task) {
    _tasks.add(task);
    notifyListeners();
  }

  void _remove(DownloadTask task) {
    if (_tasks.remove(task)) notifyListeners();
  }

  void _changed() => notifyListeners();
}

/// 사용자가 X로 내려받기를 멈췄을 때 — 받던 요청도 끊는다.
class DownloadCancelled implements Exception {
  const DownloadCancelled();

  @override
  String toString() => '다운로드를 취소했습니다.';
}

/// 내려받기 하나(파일 여러 개를 차례로 받는 것도 하나).
class DownloadTask extends ChangeNotifier {
  /// 진행 표시에 보이는 이름 — 파일 하나면 파일 이름, 여러 개면 "파일 5개".
  final String label;

  /// 받을 파일 수.
  final int fileCount;

  /// 자기 자리(말풍선의 다운로드 단추 옆)에 진행을 그리는 작업인지 — 그러면 화면 구석의 카드에는 띄우지 않는다.
  final bool inline;

  /// 다 받은(또는 실패해 넘어간) 파일 수.
  int filesDone = 0;

  /// 지금 받는 파일에서 받은 바이트와 전체 크기(서버가 알려 주지 않았으면 null).
  int received = 0;
  int? total;

  /// 앞서 다 받은 파일들의 바이트 합 — 여러 개일 때 "받은 양"에 더한다.
  int doneBytes = 0;

  /// 받기가 끝났는지(다 받았거나 실패·취소) — 저장 창이 떠 있는 동안에는 진행 표시를 거둔다.
  bool finished = false;

  DownloadTask(this.label, {this.fileCount = 1, this.inline = false});

  static const _zoneKey = #downloadTask;

  /// 지금 코드가 [trackDownload] 안에서 돌고 있으면 그 내려받기.
  static DownloadTask? get current => Zone.current[_zoneKey] as DownloadTask?;

  final _cancel = Completer<void>();

  /// X를 눌렀는지.
  bool get cancelled => _cancel.isCompleted;

  /// X를 누르면 끝나는 Future — 받던 요청을 끊는 데 쓴다(http.AbortableRequest의 abortTrigger).
  Future<void> get whenCancelled => _cancel.future;

  /// 내려받기를 멈춘다 — 받던 파일 요청을 끊고, 남은 파일은 받지 않는다. 이미 저장한 파일은 그대로 둔다.
  void cancel() {
    if (cancelled) return;
    _cancel.complete();
    _notify();
  }

  /// 멈췄으면 [DownloadCancelled]를 던진다 — 받기 전·조각 사이에 확인한다.
  void throwIfCancelled() {
    if (cancelled) throw const DownloadCancelled();
  }

  /// 전체 진행률(0~1) — 파일 수로 나눈 칸에 지금 파일의 진행을 더한다. 지금 파일의 크기를 모르면 끝난 파일만큼만.
  double? get fraction {
    final t = total;
    final current = t != null && t > 0 ? (received / t).clamp(0.0, 1.0) : 0.0;
    if (fileCount <= 1) return t != null && t > 0 ? current : null;
    return ((filesDone + current) / fileCount).clamp(0.0, 1.0);
  }

  /// 지금까지 받은 바이트(앞서 받은 파일 포함).
  int get receivedBytes => doneBytes + received;

  /// 화면을 마지막으로 다시 그리게 한 뒤 지난 시간 — 조각(수십 KB)마다 다시 그리지 않게 0.1초에 한 번만.
  final _sinceNotify = Stopwatch();

  /// 파일 하나를 받는 동안 [fetchAttachmentBytes]가 부른다.
  void reportBytes(int received, int? total) {
    this.received = received;
    this.total = total;
    if (received == 0 ||
        received == total ||
        !_sinceNotify.isRunning ||
        _sinceNotify.elapsedMilliseconds >= 100) {
      _sinceNotify
        ..reset()
        ..start();
      _notify();
    }
  }

  /// 파일 하나를 다 받았거나(또는 실패해) 다음으로 넘어갈 때.
  /// 멈춰서 끝까지 받지 못한 파일은 세지 않는다(그래서 [filesDone]은 "다 받은 파일 수"로 알릴 수 있다).
  void fileFinished() {
    doneBytes += received;
    received = 0;
    total = null;
    if (!cancelled && filesDone < fileCount) filesDone++;
    _notify();
  }

  void _notify() {
    notifyListeners();
    DownloadProgress.instance._changed();
  }
}

/// [body]를 내려받기 하나로 묶어 진행을 보이게 한다. [task]를 주면 그 작업으로(말풍선 단추처럼 자기 자리에 진행을 그리는
/// 곳), 아니면 [label]·[fileCount]로 새로 만든다. 이미 다른 [trackDownload] 안이면(여러 개 받기 안에서 파일 하나 받기를
/// 부른 경우) 새로 만들지 않고 바깥 것에 이어 센다. 끝나면(실패·취소해도) 목록에서 빠진다.
Future<T> trackDownload<T>({
  String? label,
  int fileCount = 1,
  DownloadTask? task,
  required Future<T> Function() body,
}) async {
  if (DownloadTask.current != null) return body();
  final t = task ?? DownloadTask(label ?? '', fileCount: fileCount);
  DownloadProgress.instance._add(t);
  try {
    return await runZoned(body, zoneValues: {DownloadTask._zoneKey: t});
  } finally {
    t.finished = true;
    t._notify();
    DownloadProgress.instance._remove(t);
  }
}
