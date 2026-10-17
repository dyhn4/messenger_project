// 오프라인 대응과 임시 저장 동기화(앱) — 오프라인 보기 저장소(자르기·덧붙이기·다시 읽기·지우기), 보내기 대기열(임시 id·연결 문제는 기다림·
// 거절은 실패·다시 보내기·되돌아온 메시지로 지움·앱을 다시 켜도 남음), 임시 저장 동기화(나중에 고친 쪽·지운 것·내 기기 변경 무시·비밀 대화
// 제외), 대기 말풍선·연결 끊김 띠.
import 'dart:convert';
import 'dart:io';

import 'package:client/models/message.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/chat_draft_store.dart';
import 'package:client/services/chat_socket.dart' show MessageSendException;
import 'package:client/services/draft_sync.dart';
import 'package:client/services/message_outbox.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/offline_cache.dart';
import 'package:client/services/session.dart';
import 'package:client/widgets/outbox_strip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

ChatDraft _draft(String text) => (text: text, format: null, mentions: const []);

Message _echo(String roomId, String clientId) => Message.fromJson({
  'id': 'm-$clientId',
  'roomId': roomId,
  'senderId': 'U-me',
  'senderName': '나',
  'type': 'text',
  'text': 'x',
  'createdAt': DateTime(2026, 10, 18).millisecondsSinceEpoch,
  'clientId': clientId,
});

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('오프라인 보기 저장소', () {
    late Directory tmp;
    setUp(
      () async =>
          tmp = await Directory.systemTemp.createTemp('offline_cache_test'),
    );
    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test(
      '방마다 최근 50개만, 실시간 메시지는 덧붙이고(같은 id는 바꿈), 디스크에서 다시 읽고, 로그아웃하면 지움',
      () async {
        final cache = OfflineCache(baseDir: () async => tmp);
        await cache.configure('https://192.168.0.5:3000', 'U-me');
        expect(cache.enabled, isTrue);
        cache.saveTeams([
          {'id': 'T1', 'name': '본사'},
        ]);
        cache.saveMessages('R1', [
          for (var i = 0; i < 60; i++) {'id': 'm$i', 'text': '$i'},
        ]);
        expect((await cache.messages('R1')).first['id'], 'm10');
        await cache.appendMessage('R1', {'id': 'm59', 'text': '고침'});
        await cache.appendMessage('R1', {'id': 'm60', 'text': '새것'});
        final list = await cache.messages('R1');
        expect(list.length, 50);
        expect(list.last['id'], 'm60');
        expect(list[list.length - 2]['text'], '고침');
        await cache.flush();
        // 새로 켠 앱 — 디스크에서.
        final again = OfflineCache(baseDir: () async => tmp);
        await again.configure('https://192.168.0.5:3000', 'U-me');
        expect((await again.teams()).single['name'], '본사');
        expect((await again.messages('R1')).last['text'], '새것');
        // 다른 사람은 따로.
        final other = OfflineCache(baseDir: () async => tmp);
        await other.configure('https://192.168.0.5:3000', 'U-other');
        expect(await other.teams(), isEmpty);
        await again.forgetRoom('R1');
        expect(await again.messages('R1'), isEmpty);
        await again.clear();
        expect(again.enabled, isFalse);
        final cleared = OfflineCache(baseDir: () async => tmp);
        await cleared.configure('https://192.168.0.5:3000', 'U-me');
        expect(await cleared.teams(), isEmpty);
      },
    );

    test('저장소가 없으면(웹) 아무것도 하지 않음', () async {
      final cache = OfflineCache(baseDir: () async => null);
      await cache.configure('s', 'u');
      expect(cache.enabled, isFalse);
      cache.saveTeams([{}]);
      expect(await cache.teams(), isEmpty);
    });
  });

  group('보내기 대기열', () {
    test('임시 id를 붙여 보내고, 연결 문제면 기다렸다 붙으면 다시 — 같은 임시 id로', () async {
      final sent = <Map<String, dynamic>>[];
      var online = false;
      final outbox = MessageOutbox(
        send: (p) async {
          sent.add(p);
          if (!online) {
            throw const MessageSendException(
              '서버와 연결되어 있지 않습니다.',
              transient: true,
            );
          }
          return null;
        },
      );
      final item = outbox.submit(
        roomId: 'R1',
        payload: {'type': 'text', 'text': '안녕'},
      );
      await Future<void>.delayed(Duration.zero);
      expect(item.clientId, matches(RegExp(r'^[A-Za-z0-9_-]{8,64}$')));
      expect(sent.single['clientId'], item.clientId);
      expect(sent.single['roomId'], 'R1');
      expect(outbox.forRoom('R1').single.state, OutboxState.waiting);
      outbox.submit(
        roomId: 'R1',
        payload: {'type': 'sticker', 'text': 'smile'},
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        sent.every((p) => p['type'] == 'text'),
        isTrue,
        reason: '앞의 것이 기다리는 동안 뒤의 것은 보내지 않는다',
      );
      online = true;
      await outbox.drain();
      expect(outbox.items, isEmpty);
      final tries = sent.where((p) => p['clientId'] == item.clientId).length;
      expect(tries, greaterThanOrEqualTo(2), reason: '같은 임시 id로 다시');
      expect(sent.last['type'], 'sticker', reason: '쓴 순서대로');
    });

    test('서버가 거절하면 실패로 — 다시 보내기·지우기, 되돌아온 메시지는 지움', () async {
      var reject = true;
      final outbox = MessageOutbox(
        send: (p) async {
          if (reject) throw const MessageSendException('읽기 전용 토픽입니다.');
          return null;
        },
      );
      final a = outbox.submit(
        roomId: 'R1',
        payload: {'type': 'text', 'text': 'a'},
      );
      await Future<void>.delayed(Duration.zero);
      expect(outbox.forRoom('R1').single.state, OutboxState.failed);
      expect(outbox.forRoom('R1').single.error, '읽기 전용 토픽입니다.');
      reject = false;
      outbox.retry(a.clientId);
      await Future<void>.delayed(Duration.zero);
      expect(outbox.items, isEmpty);
      // 지우기.
      reject = true;
      final b = outbox.submit(
        roomId: 'R2',
        payload: {'type': 'text', 'text': 'b'},
      );
      await Future<void>.delayed(Duration.zero);
      outbox.discard(b.clientId);
      expect(outbox.items, isEmpty);
      // 응답보다 소켓으로 먼저 되돌아오면 그때 지운다.
      final never = MessageOutbox(
        send: (p) => Future<Message?>.delayed(const Duration(days: 1)),
      );
      final c = never.submit(
        roomId: 'R3',
        payload: {'type': 'text', 'text': 'c'},
      );
      expect(never.items.single.state, OutboxState.sending);
      never.handleIncoming(_echo('R3', c.clientId));
      expect(never.items, isEmpty);
    });

    test('앱을 다시 켜도 남는다(보내던 것은 기다림으로), 방이 없어지면 버림, 미리보기', () async {
      final prefs = await SharedPreferences.getInstance();
      final first = MessageOutbox(
        send: (p) async =>
            throw const MessageSendException('끊김', transient: true),
      );
      await first.load(prefs, 'U-me');
      first.submit(roomId: 'R1', payload: {'type': 'text', 'text': '남아라'});
      first.submit(
        roomId: 'R2',
        payload: {
          'type': 'image',
          'attachments': [
            {'fileUrl': '/u/a.png', 'fileName': 'a.png'},
            {'fileUrl': '/u/b.png', 'fileName': 'b.png'},
          ],
          'text': '여행',
        },
      );
      await Future<void>.delayed(Duration.zero);
      final saved =
          jsonDecode(prefs.getString(MessageOutbox.prefsKey('U-me'))!) as List;
      expect(saved.length, 2);
      final second = MessageOutbox(send: (p) async => null);
      await second.load(prefs, 'U-me');
      expect(second.items.map((i) => i.preview), ['남아라', '사진 2장 · 여행']);
      expect(second.items.every((i) => i.state == OutboxState.waiting), isTrue);
      second.dropRoom('R1');
      expect(second.items.single.roomId, 'R2');
      expect(outboxPreviewOf({'type': 'file', 'fileName': '견적.pdf'}), '견적.pdf');
      expect(outboxPreviewOf({'type': 'sticker', 'text': 'x'}), '이모티콘');
    });
  });

  group('임시 저장 동기화', () {
    late ChatDraftStore store;
    late List<({String roomId, String? text, String? deviceId})> pushed;
    late List<Map<String, dynamic>> remote;
    late DraftSync sync;
    setUp(() {
      store = ChatDraftStore();
      pushed = [];
      remote = [];
      sync = DraftSync(
        store: store,
        push: (roomId, draft, deviceId) async {
          pushed.add((roomId: roomId, text: draft?.text, deviceId: deviceId));
          return DateTime.now().millisecondsSinceEpoch;
        },
        fetchAll: () async => remote,
        deviceId: () => 'dev-A',
        delay: Duration.zero,
      );
    });

    test('이 기기에서 고치면 잠깐 뒤 보내고(지우면 빈 글), 비밀 대화는 보내지 않음', () async {
      store.put('R1', _draft('쓰는 중'));
      store.put('S1', _draft('비밀'), persist: false);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(pushed, [(roomId: 'R1', text: '쓰는 중', deviceId: 'dev-A')]);
      store.put('R1', null);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(pushed.last, (roomId: 'R1', text: null, deviceId: 'dev-A'));
    });

    test('로그인할 때 — 나중에 고친 쪽이 남는다(서버가 나중이면 받고, 이 기기가 나중이면 보냄), 지운 것도', () async {
      final now = DateTime.now();
      store.put('R-old', _draft('이 기기의 옛 글'));
      store.put('R-new', _draft('이 기기의 새 글'));
      store.put('R-deleted', _draft('다른 기기에서 지움'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      pushed.clear();
      final later = now.add(const Duration(minutes: 5)).millisecondsSinceEpoch;
      final earlier = now
          .subtract(const Duration(minutes: 5))
          .millisecondsSinceEpoch;
      remote = [
        {'roomId': 'R-old', 'text': '다른 기기의 새 글', 'updatedAt': later},
        {'roomId': 'R-new', 'text': '다른 기기의 옛 글', 'updatedAt': earlier},
        {'roomId': 'R-deleted', 'text': null, 'updatedAt': later},
        {'roomId': 'R-only-remote', 'text': '다른 기기에서만', 'updatedAt': later},
      ];
      await sync.start();
      expect(store.get('R-old')!.text, '다른 기기의 새 글');
      expect(store.get('R-new')!.text, '이 기기의 새 글');
      expect(store.get('R-deleted'), isNull);
      expect(store.get('R-only-remote')!.text, '다른 기기에서만');
      expect(pushed.map((p) => p.roomId), [
        'R-new',
      ], reason: '이 기기가 더 나중인 것만 보냄');
    });

    test('소켓으로 — 내 기기가 보낸 것은 무시, 다른 기기 것은 받아 알림(입력칸이 새 글로 바꿀 수 있게)', () async {
      final changed = <String>[];
      final sub = store.remoteChanges.listen(changed.add);
      final at = DateTime.now()
          .add(const Duration(seconds: 1))
          .millisecondsSinceEpoch;
      sync.handleRemote({
        'roomId': 'R1',
        'text': '내가 보낸 것',
        'updatedAt': at,
        'deviceId': 'dev-A',
      });
      expect(store.get('R1'), isNull);
      sync.handleRemote({
        'roomId': 'R1',
        'text': '휴대폰에서',
        'updatedAt': at,
        'deviceId': 'dev-B',
      });
      expect(store.get('R1')!.text, '휴대폰에서');
      await Future<void>.delayed(Duration.zero);
      expect(changed, ['R1']);
      expect(pushed, isEmpty, reason: '받은 것은 다시 보내지 않음');
      // 이 기기에서 지운 뒤 늦게 온 옛 글은 되살리지 않는다.
      store.put('R1', null);
      sync.handleRemote({
        'roomId': 'R1',
        'text': '늦게 온 옛 글',
        'updatedAt': at - 5000,
        'deviceId': 'dev-B',
      });
      expect(store.get('R1'), isNull);
      // 비밀 대화의 글(메모리에만)은 건드리지 않는다.
      store.put('S1', _draft('비밀'), persist: false);
      sync.handleRemote({
        'roomId': 'S1',
        'text': '덮어쓰기',
        'updatedAt': at + 9999,
        'deviceId': 'dev-B',
      });
      expect(store.get('S1')!.text, '비밀');
      await sub.cancel();
    });

    test('못 보낸 것은 다시 연결될 때 보낸다', () async {
      var offline = true;
      final pushes = <String>[];
      final s2 = DraftSync(
        store: store,
        push: (roomId, draft, deviceId) async {
          if (offline) throw Exception('offline');
          pushes.add(roomId);
          return 1;
        },
        fetchAll: () async => [],
        deviceId: () => 'dev-A',
        delay: Duration.zero,
      );
      store.put('R9', _draft('끊긴 동안'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(s2.hasPending, isTrue);
      offline = false;
      await s2.start();
      expect(pushes, ['R9']);
      expect(s2.hasPending, isFalse);
    });
  });

  group('화면', () {
    testWidgets('대기 말풍선 — 기다림은 취소, 실패는 이유와 다시 보내기·지우기', (tester) async {
      final session = Session(
        notifications: NotificationService(),
        settings: AppSettings(),
      );
      var reject = true;
      session.chatSocket.debugSendOverride = (payload) async => reject
          ? {'ok': false, 'error': '보드 뷰 토픽에는 게시글만 올릴 수 있습니다.'}
          : {'ok': true};
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                const Spacer(),
                OutboxStrip(session: session, roomId: 'R1'),
                ConnectionLostBanner(session: session),
              ],
            ),
          ),
        ),
      );
      expect(find.byKey(const ValueKey('outbox-strip')), findsNothing);
      // 대기열의 send는 연결이 없으면 바로 실패하므로, 이 시험은 debugSendOverride(연결 검사 전)를 쓰는 sendPayload를 직접 부른다.
      final outbox = MessageOutbox(
        send: (p) => session.chatSocket.sendPayload(p),
      );
      final item = outbox.submit(
        roomId: 'R1',
        payload: {'type': 'text', 'text': '보드에 글'},
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListenableBuilder(
              listenable: outbox,
              builder: (context, _) => Column(
                children: [
                  for (final i in outbox.forRoom('R1'))
                    Text('${i.preview}|${i.state.name}|${i.error ?? ''}'),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('보드에 글|failed|보드 뷰 토픽에는 게시글만 올릴 수 있습니다.'),
        findsOneWidget,
      );
      reject = false;
      outbox.retry(item.clientId);
      await tester.pumpAndSettle();
      expect(outbox.items, isEmpty);

      // 세션의 대기열 — 연결이 없으니 기다림(가짜 응답을 걷어 낸다).
      session.chatSocket.debugSendOverride = null;
      session.outbox.submit(
        roomId: 'R1',
        payload: {'type': 'text', 'text': '연결되면'},
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                const Spacer(),
                OutboxStrip(session: session, roomId: 'R1'),
                ConnectionLostBanner(session: session),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final waiting = session.outbox.forRoom('R1').single;
      expect(find.text('연결되면'), findsOneWidget);
      expect(find.text('연결되면 보냅니다'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('connection-lost-banner')),
        findsNothing,
      );
      session.connectionLost = true;
      session.notifyListeners();
      await tester.pump();
      expect(
        find.byKey(const ValueKey('connection-lost-banner')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(ValueKey('outbox-discard-${waiting.clientId}')),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('outbox-strip')), findsNothing);
    });
  });
}
