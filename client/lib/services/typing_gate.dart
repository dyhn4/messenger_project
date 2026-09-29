import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

/// 한글처럼 IME로 글자를 "조합"하며 빠르게 치는 동안에는, 화면을 크게 다시 그리게 하는 알림
/// (Session·RoomChatController의 notifyListeners)을 잠깐 모아 두었다가 손을 멈추면 내보낸다.
///
/// 왜: Windows에서 Flutter는 키를 누를 때마다 먼저 Dart 쪽에 물어보고, 답을 받은 뒤에야 그 키를
/// IME(한글 입력기)에 넘긴다. 그 순간 UI 스레드가 다른 일 — 읽음 표시·접속 상태·다른 방 새 메시지
/// 같은 세션 알림 하나에 방 목록과 대화 목록 전체를 다시 그리는 일 — 로 30ms쯤만 붙잡혀 있어도
/// 키가 늦게 넘어가면서 조합이 꼬여 글자가 빠지거나 뭉개진다("안녕하세요" → "안하셍"). 영어처럼
/// 조합이 없는 입력은 같은 상황에서도 멀쩡했다(재현 결과 — 입력칸 코드와는 무관).
///
/// 그래서 조합이 이어지는 동안에는 알림을 모아 두고(같은 대상은 하나로 합친다), [pause]만큼 손을
/// 멈추면 한 번에 내보낸다. 쉬지 않고 계속 쳐도 [maxHold]가 지나면 다음에 글자가 확정될 때
/// (띄어쓰기 등 — 글자 한가운데가 아니라 경계라서 조합을 덜 건드린다) 내보내고, 그런 때가 없어도
/// [hardMaxHold]에는 내보내서 새 메시지·읽음 표시가 너무 늦게 보이지 않게 한다. 메시지를 보낼
/// 때는 바로 내보낸다([flush]).
class TypingGate {
  TypingGate._();
  static final instance = TypingGate._();

  static const pause = Duration(milliseconds: 400);
  static const maxHold = Duration(seconds: 2);
  static const hardMaxHold = Duration(seconds: 5);

  Timer? _timer;
  DateTime? _holdStart;
  final _pending = LinkedHashMap<Object, VoidCallback>.identity();

  /// 지금 알림을 모으고 있는지.
  bool get holding => _timer != null;

  /// 입력칸의 글자가 IME 조합 중에 바뀔 때마다 부른다 — 모으기를 시작하거나 연장한다.
  void composing() {
    final now = DateTime.now();
    final start = _holdStart ??= now;
    if (now.difference(start) >= hardMaxHold) {
      flush();
      _holdStart = now;
    }
    _timer?.cancel();
    _timer = Timer(pause, flush);
  }

  /// 조합이 끝나 글자가 확정됐을 때(띄어쓰기·문장부호 등) 부른다 — 오래([maxHold]) 모았으면
  /// 다음 글자를 조합하기 전인 지금 내보낸다.
  void committed() {
    final start = _holdStart;
    if (start != null && DateTime.now().difference(start) >= maxHold) flush();
  }

  /// [owner]의 알림 [notify]를 지금 내보내거나, 조합 중이면 모아 둔다(같은 owner는 한 번만).
  void run(Object owner, VoidCallback notify) {
    if (!holding) {
      notify();
      return;
    }
    _pending[owner] = notify;
  }

  /// 모아 둔 알림을 지금 전부 내보낸다.
  void flush() {
    _timer?.cancel();
    _timer = null;
    _holdStart = null;
    if (_pending.isEmpty) return;
    final notifies = _pending.values.toList();
    _pending.clear();
    for (final notify in notifies) {
      notify();
    }
  }

  /// [owner]가 dispose될 때 — 모아 둔 알림을 버린다(dispose된 뒤에 알리면 안 된다).
  void cancel(Object owner) => _pending.remove(owner);

  @visibleForTesting
  void reset() {
    _timer?.cancel();
    _timer = null;
    _holdStart = null;
    _pending.clear();
  }
}
