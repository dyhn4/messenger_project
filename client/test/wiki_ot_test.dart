import 'dart:async';
import 'dart:math';

import 'package:client/services/ot_text.dart';
import 'package:client/services/wiki_doc.dart';
import 'package:flutter_test/flutter_test.dart';

/// 위키 동시 편집 — OT(ot_text.dart, 서버 otText.js와 같은 규칙)와 앱 쪽 상태(wiki_doc.dart). 가짜 서버(server/src/wikiDocs.js와 같은
/// 방식 — 늦게 온 연산을 적용한 것에 맞춤)에 앱 셋이 무작위 차례로 고치고 받아도 끝에 모두 같은 글이 되는지 본다.

const _alphabet = 'ab가나 \n😀';

String _randomString(Random r, [int max = 6]) {
  final n = 1 + r.nextInt(max);
  final out = StringBuffer();
  for (var i = 0; i < n; i++) {
    out.write(_alphabet[r.nextInt(_alphabet.length)]);
  }
  return out.toString();
}

TextOp _randomOp(Random r, String doc) {
  final op = <Object>[];
  var left = doc.length;
  while (left > 0) {
    final n = 1 + r.nextInt(left < 5 ? left : 5);
    final pick = r.nextDouble();
    if (pick < 0.2) {
      op.add(_randomString(r));
    } else if (pick < 0.5) {
      op.add(-n);
    } else {
      op.add(n);
    }
    if (pick >= 0.2) left -= n;
  }
  if (r.nextDouble() < 0.3) op.add(_randomString(r));
  return normalizeOp(op);
}

/// 서버 하나 — 요청은 받은 차례로 처리하고, 앱마다 보낼 것(확인·이벤트)을 차례대로 쌓아 둔다.
class _FakeServer {
  String body;
  int revision = 0;
  final history = <({int revision, TextOp op, String? opId})>[];
  final inbox =
      <
        ({
          _FakeClient from,
          String event,
          Map<String, dynamic> payload,
          void Function(Map<String, dynamic>) onAck,
        })
      >[];
  final clients = <_FakeClient>[];
  _FakeServer(this.body);

  /// [client]가 보낸 요청 중 가장 먼저 온 것 하나(한 앱의 요청은 보낸 차례대로 — 소켓 하나의 순서).
  void processNextOf(_FakeClient client) {
    final i = inbox.indexWhere((r) => identical(r.from, client));
    if (i >= 0) process(i);
  }

  void process(int index) {
    final req = inbox.removeAt(index);
    final client = req.from;
    if (req.event == 'wiki:join') {
      final since = req.payload['sinceRevision'] as int?;
      Map<String, dynamic> ack;
      if (since != null &&
          since >= revision - history.length &&
          since <= revision) {
        final ops = history
            .where((h) => h.revision > since)
            .map((h) => {'revision': h.revision, 'op': h.op, 'opId': h.opId})
            .toList();
        ack = {
          'ok': true,
          'revision': revision,
          'title': 't',
          'canEdit': true,
          'ops': ops,
          'editors': <Object>[],
        };
      } else {
        ack = {
          'ok': true,
          'revision': revision,
          'title': 't',
          'canEdit': true,
          'body': body,
          'editors': <Object>[],
        };
      }
      client.queue.add(() => req.onAck(ack));
      return;
    }
    // wiki:op
    final opId = req.payload['opId'] as String?;
    final seen = history.where((h) => h.opId == opId).firstOrNull;
    if (seen != null) {
      client.queue.add(
        () => req.onAck({'ok': true, 'revision': seen.revision}),
      );
      return;
    }
    final base = req.payload['revision'] as int;
    var op = opFromJson(req.payload['op'])!;
    for (final h in history.where((h) => h.revision > base)) {
      op = transformOps(op, h.op).$1;
    }
    body = applyOp(body, op);
    revision += 1;
    history.add((revision: revision, op: op, opId: opId));
    final rev = revision;
    client.queue.add(() => req.onAck({'ok': true, 'revision': rev}));
    for (final other in clients) {
      if (identical(other, client) || !other.joined) continue;
      final sent = op;
      other.queue.add(
        () => other.eventsController.add({
          'type': 'op',
          'pageId': 'p',
          'revision': rev,
          'op': sent,
          'opId': opId,
        }),
      );
    }
  }
}

class _FakeClient implements WikiTransport {
  final _FakeServer server;
  final queue = <void Function()>[];
  // 앱의 ChatSocket과 같게 동기 스트림 — 확인과 이벤트가 같은 차례로 처리된다.
  final eventsController = StreamController<Map<String, dynamic>>.broadcast(
    sync: true,
  );
  final _reconnected = StreamController<void>.broadcast(sync: true);
  bool joined = false;
  bool connected = true;
  _FakeClient(this.server) {
    server.clients.add(this);
  }

  @override
  void request(
    String event,
    Map<String, dynamic> payload,
    void Function(Map<String, dynamic>) onAck,
  ) {
    if (!connected) return; // 끊긴 동안 보낸 것은 사라진다.
    if (event == 'wiki:join') joined = true;
    server.inbox.add((
      from: this,
      event: event,
      payload: payload,
      onAck: onAck,
    ));
  }

  @override
  void emit(String event, Map<String, dynamic> payload) {}

  @override
  Stream<Map<String, dynamic>> get events => eventsController.stream;

  @override
  Stream<void> get reconnected => _reconnected.stream;

  /// 끊긴다 — 쌓여 있던 것(확인·이벤트)도 잃는다. 다시 붙으면 앱이 아는 판에서 다시 들어간다.
  void drop() {
    connected = false;
    joined = false;
    queue.clear();
    server.inbox.removeWhere((r) => identical(r.from, this));
  }

  void reconnect() {
    connected = true;
    _reconnected.add(null);
  }
}

void main() {
  group('OT', () {
    test('적용·짧은 꼴·같은 자리 동시 넣기', () {
      expect(applyOp('hello', [5, ' world']), 'hello world');
      expect(applyOp('hello', [1, -3, 'ipp', 1]), 'hippo');
      expect(() => applyOp('hi', [5]), throwsStateError);
      expect(normalizeOp([1, 2, 'a', 'b', -1, -2]), [3, 'ab', -3]);
      expect(normalizeOp([2, -1, 'x', 1]), [2, 'x', -1, 1]);
      final (ap, bp) = transformOps([1, 'X', 1], [1, 'Y', 1]);
      expect(applyOp(applyOp('ac', [1, 'X', 1]), bp), 'aXYc');
      expect(applyOp(applyOp('ac', [1, 'Y', 1]), ap), 'aXYc');
      expect(opFromJson([1, 'a', -2]), [1, 'a', -2]);
      expect(opFromJson([0]), isNull);
      expect(opFromJson('x'), isNull);
    });

    test('무작위 — transform 수렴·compose(2000번), 서버와 같은 바꾸기 연산·커서', () {
      final r = Random(20261018);
      for (var k = 0; k < 2000; k++) {
        final doc = r.nextDouble() < 0.1 ? '' : _randomString(r, 20);
        final a = _randomOp(r, doc);
        final b = _randomOp(r, doc);
        final (ap, bp) = transformOps(a, b);
        expect(
          applyOp(applyOp(doc, a), bp),
          applyOp(applyOp(doc, b), ap),
          reason: 'transform #$k',
        );
        final after = applyOp(doc, a);
        final c = _randomOp(r, after);
        expect(
          applyOp(doc, composeOps(a, c)),
          applyOp(after, c),
          reason: 'compose #$k',
        );
      }
      expect(diffOp('hello world', 'hello brave world'), [6, 'brave ', 5]);
      expect(diffOp('abcdef', 'abXef'), [2, 'X', -2, 2]);
      expect(diffOp('', 'new'), ['new']);
      expect(transformIndex(3, ['ab', 5]), 5);
      expect(transformIndex(3, [3, 'ab', 2]), 3);
      expect(transformIndex(3, [2, -3]), 2);
    });
  });

  group('WikiDocSession', () {
    test('세 앱이 무작위 차례로 고치고 받고 끊겼다 붙어도 모두 같은 글', () async {
      for (var round = 0; round < 40; round++) {
        final r = Random(round);
        final server = _FakeServer(_randomString(r, 10));
        final clients = [for (var i = 0; i < 3; i++) _FakeClient(server)];
        var seq = 0;
        final sessions = [
          for (final c in clients)
            WikiDocSession(c, 'p', newOpId: () => 'op${seq++}'),
        ];
        final opened = [for (final s in sessions) s.open()];
        // 들어가기 요청을 처리하고 확인을 전한다.
        while (server.inbox.isNotEmpty) {
          server.process(0);
        }
        for (final c in clients) {
          while (c.queue.isNotEmpty) {
            c.queue.removeAt(0)();
          }
        }
        await Future.wait(opened);
        for (var step = 0; step < 300; step++) {
          final pick = r.nextDouble();
          final i = r.nextInt(3);
          if (pick < 0.35) {
            final s = sessions[i];
            if (!s.joined || !clients[i].connected) continue;
            final op = _randomOp(r, s.text);
            s.localEdit(applyOp(s.text, op));
          } else if (pick < 0.65) {
            server.processNextOf(clients[i]);
          } else if (pick < 0.97) {
            final c = clients[i];
            if (c.queue.isNotEmpty) c.queue.removeAt(0)();
          } else {
            final c = clients[i];
            if (c.connected) {
              c.drop();
            } else {
              c.reconnect();
            }
          }
        }
        // 끝 — 모두 다시 붙이고 남은 것을 다 처리한다.
        for (final c in clients) {
          if (!c.connected) c.reconnect();
        }
        for (var guard = 0; guard < 10000; guard++) {
          final idle =
              server.inbox.isEmpty && clients.every((c) => c.queue.isEmpty);
          if (idle) break;
          if (server.inbox.isNotEmpty) server.process(0);
          for (final c in clients) {
            while (c.queue.isNotEmpty) {
              c.queue.removeAt(0)();
            }
          }
        }
        for (final (i, s) in sessions.indexed) {
          expect(s.synced, isTrue, reason: 'round $round 앱 $i 아직 보낼 것이 있다');
          expect(s.text, server.body, reason: 'round $round 앱 $i');
          expect(s.revision, server.revision, reason: 'round $round 앱 $i 판');
        }
        for (final s in sessions) {
          s.dispose();
        }
      }
    });

    test('다른 사람 연산은 바뀐 범위를 알리고, 읽기 전용이면 보내지 않는다', () async {
      final server = _FakeServer('hello');
      final a = _FakeClient(server);
      final b = _FakeClient(server);
      final sa = WikiDocSession(a, 'p');
      final sb = WikiDocSession(b, 'p');
      final o1 = sa.open();
      final o2 = sb.open();
      while (server.inbox.isNotEmpty) {
        server.process(0);
      }
      for (final c in [a, b]) {
        while (c.queue.isNotEmpty) {
          c.queue.removeAt(0)();
        }
      }
      await Future.wait([o1, o2]);
      final changes = <TextOp>[];
      sb.remoteChanges.listen(changes.add);
      sa.localEdit('hello world');
      expect(sa.synced, isFalse);
      server.process(0);
      for (final c in [a, b]) {
        while (c.queue.isNotEmpty) {
          c.queue.removeAt(0)();
        }
      }
      await Future<void>.delayed(Duration.zero);
      expect(sa.synced, isTrue);
      expect(sb.text, 'hello world');
      expect(changes.single, [5, ' world']);
      sb.canEdit = false;
      sb.localEdit('x');
      expect(server.inbox, isEmpty);
      sa.dispose();
      sb.dispose();
    });
  });
}
