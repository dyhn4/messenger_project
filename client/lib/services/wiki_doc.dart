import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'ot_text.dart';

/// 위키 동시 편집의 소켓 통로(서버 server/src/wiki.js registerWikiSocket) — 앱은 ChatSocket이, 테스트는 가짜 서버가 맡는다.
abstract class WikiTransport {
  /// 응답(ack)을 기다리는 요청 — [onAck]는 소켓의 다른 이벤트와 같은 차례로 곧바로(동기로) 불러야 한다. 연산 확인과 다른 사람의
  /// 연산이 섞여 와도 순서가 맞아야 OT가 맞는다.
  void request(
    String event,
    Map<String, dynamic> payload,
    void Function(Map<String, dynamic> ack) onAck,
  );

  /// 응답 없이 보내기(커서·나가기).
  void emit(String event, Map<String, dynamic> payload);

  /// 서버가 보내는 wiki:* 이벤트 — `{ 'type': 'op'|'presence'|'cursor'|'title'|'removed', ...데이터 }`.
  Stream<Map<String, dynamic>> get events;

  /// 연결이 끊겼다 다시 붙었다.
  Stream<void> get reconnected;
}

class WikiEditor {
  final String userId;
  final String name;
  final String color;
  const WikiEditor({
    required this.userId,
    required this.name,
    required this.color,
  });

  static List<WikiEditor> listFromJson(Object? json) => [
    for (final e in (json as List? ?? const []))
      if (e is Map && e['userId'] is String)
        WikiEditor(
          userId: e['userId'] as String,
          name: e['name'] as String? ?? '',
          color: e['color'] as String? ?? '#868E96',
        ),
  ];
}

/// 다른 사람의 커서(지금 내 글 기준 위치).
class WikiRemoteCursor {
  final String userId;
  final String name;
  final String color;
  final int anchor;
  final int head;
  const WikiRemoteCursor({
    required this.userId,
    required this.name,
    required this.color,
    required this.anchor,
    required this.head,
  });

  WikiRemoteCursor moved(TextOp op) => WikiRemoteCursor(
    userId: userId,
    name: name,
    color: color,
    anchor: transformIndex(anchor, op),
    head: transformIndex(head, op),
  );
}

String _randomOpId() {
  final r = math.Random();
  return List.generate(16, (_) => r.nextInt(36).toRadixString(36)).join();
}

/// 위키 페이지 하나의 동시 편집 상태 — ot.js의 클라이언트와 같은 세 상태(맞음 / 확인 기다림 / 확인 기다림 + 쌓인 변경):
///  - 내 변경은 확인받지 못한 것이 없으면 바로 보내고(outstanding), 있으면 모아 둔다(buffer — 확인이 오면 하나로 보낸다).
///  - 다른 사람의 연산이 오면 outstanding·buffer에 대해 맞춘 뒤(transform(내 것, 서버 것)) 내 글에 적용한다.
///  - 끊겼다 다시 붙으면 아는 판 번호로 다시 들어가 그 뒤 연산을 받고(내 연산은 opId로 확인으로 친다), 기억 밖이면 본문을 통째로 받는다.
/// 화면은 [text]를 그리고, 다른 사람 때문에 글이 바뀌면 [remoteChanges]로 그 연산을 받아 커서를 옮긴다.
class WikiDocSession extends ChangeNotifier {
  final WikiTransport transport;
  final String pageId;
  final String Function() _newOpId;

  WikiDocSession(this.transport, this.pageId, {String Function()? newOpId})
    : _newOpId = newOpId ?? _randomOpId;

  String text = '';
  int revision = 0;
  String title = '';
  bool canEdit = false;
  bool joined = false;
  String? error;

  /// 다른 사람이 페이지를 휴지통으로 옮겼다 — 화면을 닫는다.
  bool removed = false;

  /// 끊긴 동안 너무 많이 바뀌어 내 확인 안 된 변경을 버리고 다시 받았다(화면이 한 번 알린다).
  bool lostLocalEdits = false;
  List<WikiEditor> editors = const [];
  final cursors = <String, WikiRemoteCursor>{};

  TextOp? _outstanding;
  String? _outstandingId;
  TextOp? _buffer;
  bool _sending = false;
  bool _disposed = false;
  StreamSubscription<Map<String, dynamic>>? _eventsSub;
  StreamSubscription<void>? _reconnectSub;
  final _remote = StreamController<TextOp>.broadcast();

  /// 다른 사람 때문에(또는 다시 받아서) 바뀐 연산 — 화면이 커서·조합 중인 글자 범위를 옮긴다.
  Stream<TextOp> get remoteChanges => _remote.stream;

  /// 서버가 내 변경을 모두 받았는지.
  bool get synced => _outstanding == null && _buffer == null;

  /// 들어간다 — 첫 본문을 받으면 끝난다(실패면 [error]).
  Future<void> open() {
    _eventsSub ??= transport.events.listen(_onEvent);
    _reconnectSub ??= transport.reconnected.listen((_) => _join(resume: true));
    return _join();
  }

  Future<void> _join({bool resume = false}) {
    final done = Completer<void>();
    transport.request(
      'wiki:join',
      {'pageId': pageId, if (resume && joined) 'sinceRevision': revision},
      (ack) {
        if (_disposed) return done.complete();
        if (ack['ok'] != true) {
          error = ack['error']?.toString() ?? '페이지를 열지 못했습니다.';
          _notify();
          return done.complete();
        }
        error = null;
        title = ack['title'] as String? ?? title;
        canEdit = ack['canEdit'] == true;
        editors = WikiEditor.listFromJson(ack['editors']);
        final ops = ack['ops'];
        if (resume && joined && ops is List) {
          for (final o in ops) {
            if (o is! Map) continue;
            final rev = (o['revision'] as num?)?.toInt() ?? 0;
            if (rev <= revision) continue;
            if (o['opId'] != null && o['opId'] == _outstandingId) {
              // 끊기기 전에 보낸 내 연산이 서버에 닿아 있었다 — 확인으로 친다.
              revision = rev;
              _outstanding = null;
              _outstandingId = null;
              _sending = false;
              continue;
            }
            final op = opFromJson(o['op']);
            if (op == null) continue;
            _applyRemote(op, rev);
          }
          revision = (ack['revision'] as num?)?.toInt() ?? revision;
          // 확인 못 받은 내 연산(또는 쌓인 변경)을 지금 판 기준으로 다시 보낸다 — 서버는 같은 opId를 두 번 적용하지 않는다.
          _sending = false;
          _flush();
        } else {
          final body = ack['body'] as String? ?? '';
          if (joined && !synced && body != text) lostLocalEdits = true;
          final old = text;
          text = body;
          revision = (ack['revision'] as num?)?.toInt() ?? 0;
          _outstanding = null;
          _outstandingId = null;
          _buffer = null;
          _sending = false;
          if (joined && old != body) _remote.add(diffOp(old, body));
        }
        joined = true;
        _notify();
        done.complete();
      },
    );
    return done.future;
  }

  /// 입력칸의 새 글 — 바뀐 부분을 연산으로 만들어 보낸다(확인을 기다리는 중이면 모아 둔다).
  void localEdit(String newText) {
    if (!canEdit || !joined || newText == text) return;
    final op = diffOp(text, newText);
    text = newText;
    // 다른 사람 커서도 내 변경만큼 옮긴다.
    for (final id in cursors.keys.toList()) {
      cursors[id] = cursors[id]!.moved(op);
    }
    if (_outstanding == null) {
      _outstanding = op;
    } else {
      _buffer = _buffer == null ? op : composeOps(_buffer!, op);
    }
    _flush();
    _notify();
  }

  void _flush() {
    if (_sending || _disposed) return;
    if (_outstanding == null && _buffer != null) {
      _outstanding = _buffer;
      _buffer = null;
    }
    final op = _outstanding;
    if (op == null) return;
    final id = _outstandingId ??= _newOpId();
    _sending = true;
    transport.request(
      'wiki:op',
      {'pageId': pageId, 'revision': revision, 'op': op, 'opId': id},
      (ack) {
        if (_disposed || _outstandingId != id) return;
        _sending = false;
        if (ack['ok'] == true) {
          revision = (ack['revision'] as num?)?.toInt() ?? revision + 1;
          _outstanding = null;
          _outstandingId = null;
          _flush();
          _notify();
          return;
        }
        switch (ack['error']) {
          case 'read_only':
            canEdit = false;
            _outstanding = null;
            _outstandingId = null;
            _buffer = null;
            _join();
          case 'too_fast':
            Timer(const Duration(milliseconds: 500), _flush);
          default:
            // 판이 맞지 않음 등 — 본문을 통째로 다시 받는다(드문 경우).
            _join();
        }
        _notify();
      },
    );
  }

  void _onEvent(Map<String, dynamic> e) {
    if (_disposed || e['pageId'] != pageId) return;
    switch (e['type']) {
      case 'op':
        final rev = (e['revision'] as num?)?.toInt() ?? 0;
        if (rev <= revision) return; // 이미 받은 것(다시 붙으며 받았다).
        if (rev != revision + 1) {
          // 중간 연산을 놓쳤다 — 아는 판에서 다시 따라잡는다.
          _join(resume: true);
          return;
        }
        final op = opFromJson(e['op']);
        if (op == null) return;
        _applyRemote(op, rev);
        _notify();
      case 'presence':
        editors = WikiEditor.listFromJson(e['editors']);
        cursors.removeWhere((id, _) => !editors.any((x) => x.userId == id));
        _notify();
      case 'cursor':
        final userId = e['userId'] as String?;
        // 다른 판 기준의 커서는 위치가 어긋나니 버린다(곧 다음 커서가 온다).
        final sameRevision = (e['revision'] as num?)?.toInt() == revision;
        if (userId == null || !sameRevision) return;
        cursors[userId] = WikiRemoteCursor(
          userId: userId,
          name: e['name'] as String? ?? '',
          color: e['color'] as String? ?? '#868E96',
          anchor: ((e['anchor'] as num?)?.toInt() ?? 0).clamp(0, text.length),
          head: ((e['head'] as num?)?.toInt() ?? 0).clamp(0, text.length),
        );
        _notify();
      case 'title':
        title = e['title'] as String? ?? title;
        _notify();
      case 'removed':
        removed = true;
        _notify();
    }
  }

  void _applyRemote(TextOp op, int rev) {
    var incoming = op;
    if (_outstanding != null) {
      final (mine, theirs) = transformOps(_outstanding!, incoming);
      _outstanding = mine;
      incoming = theirs;
    }
    if (_buffer != null) {
      final (mine, theirs) = transformOps(_buffer!, incoming);
      _buffer = mine;
      incoming = theirs;
    }
    text = applyOp(text, incoming);
    revision = rev;
    for (final id in cursors.keys.toList()) {
      cursors[id] = cursors[id]!.moved(incoming);
    }
    _remote.add(incoming);
  }

  Timer? _cursorTimer;
  (int, int)? _pendingCursor;

  /// 내 커서(선택)를 알린다 — 잦으면 0.15초에 한 번.
  void sendCursor(int anchor, int head) {
    _pendingCursor = (anchor, head);
    _cursorTimer ??= Timer(const Duration(milliseconds: 150), () {
      _cursorTimer = null;
      final c = _pendingCursor;
      if (c == null || _disposed || !joined) return;
      transport.emit('wiki:cursor', {
        'pageId': pageId,
        'anchor': c.$1,
        'head': c.$2,
      });
    });
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _cursorTimer?.cancel();
    _eventsSub?.cancel();
    _reconnectSub?.cancel();
    _remote.close();
    if (joined) transport.emit('wiki:leave', {'pageId': pageId});
    super.dispose();
  }
}
