// 오프라인 후속(남은 것) — 오프라인 중 댓글 쓰기·사진/파일 메시지의 설명 고치기, 비밀 대화의 사진·파일 대기열(메모리에만), 이 기기
// 메시지 DB의 빠진 구간 메우기(기록 동기화). 웹 앱의 IndexedDB 저장은 브라우저에서 도는 test/web/message_db_web_test.dart.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:client/models/app_user.dart';
import 'package:client/models/room.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/chat_socket.dart' show MessageSendException;
import 'package:client/services/message_outbox.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/offline_cache.dart';
import 'package:client/services/outbox_files.dart';
import 'package:client/services/outbox_files_io.dart' show outboxFilesBaseDir;
import 'package:client/services/session.dart';
import 'package:client/widgets/outbox_strip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _t0 = DateTime(2026, 10, 21, 9);

Map<String, dynamic> _msg(String id, int minute, {String text = ''}) => {
  'id': id,
  'roomId': 'R1',
  'senderId': 'u2',
  'senderName': 'Sam',
  'type': 'text',
  'text': text,
  'createdAt': _t0.add(Duration(minutes: minute)).millisecondsSinceEpoch,
};

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('세션·컨트롤러 — 오프라인 중 댓글·사진/파일 설명 고치기', () {
    const serverUrl = 'https://192.168.0.10:3000';
    late List<http.Request> requests;
    late bool offline;

    Session build() {
      requests = [];
      offline = false;
      final session = Session(
        notifications: NotificationService(),
        settings: AppSettings(),
      );
      session.serverUrl = serverUrl;
      session.api = ApiClient(
        baseUrl: serverUrl,
        token: 't',
        httpClient: MockClient((request) async {
          requests.add(request);
          if (offline) throw http.ClientException('연결 안 됨');
          Object body = const {};
          final message = {
            'id': 'm1',
            'roomId': 'r1',
            'senderId': 'u1',
            'senderName': 'Riley',
            'type': 'image',
            'text': '원래 설명',
            'attachments': [
              {'id': 'a1', 'kind': 'image', 'fileUrl': '/uploads/1.png'},
              {'id': 'a2', 'kind': 'image', 'fileUrl': '/uploads/2.png'},
            ],
            'createdAt': DateTime(2026, 10, 21).millisecondsSinceEpoch,
          };
          if (request.method == 'PATCH') {
            body = message;
          } else if (request.method == 'GET' &&
              request.url.path.endsWith('/messages')) {
            body = [message];
          } else if (request.url.path.endsWith('/comments')) {
            body = {
              'id': 'c1',
              'messageId': 'm1',
              'roomId': 'r1',
              'senderId': 'u1',
              'senderName': 'Riley',
              'type': 'text',
              'text': 'x',
              'createdAt': DateTime(2026, 10, 21).millisecondsSinceEpoch,
            };
          }
          return http.Response.bytes(
            utf8.encode(jsonEncode(body)),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      session.userId = 'u1';
      session.rooms.add(
        Room(
          id: 'r1',
          teamId: 't1',
          type: RoomType.topic,
          name: '마케팅',
          members: [AppUser(id: 'u1', username: 'u1', name: 'Riley')],
          createdAt: DateTime(2026),
          lastRead: const {},
        ),
      );
      return session;
    }

    /// 대기열이 다 보낼 때까지(앞서 넣을 때 시작한 보내기가 아직 응답을 기다릴 수 있다).
    Future<void> settle(Session session) async {
      for (var i = 0; i < 100 && session.outbox.hasPending; i++) {
        await session.outbox.drain();
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }

    Map<String, dynamic> bodyOf(http.Request r) =>
        jsonDecode(r.body) as Map<String, dynamic>;

    test('댓글 — 연결 문제로 실패하면 같은 임시 id로 대기열에, 연결되면 그 id로 다시 단다', () async {
      final session = build();
      final controller = session.controllerFor(session.rooms.single);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      offline = true;
      await controller.postComment('m1', '오프라인 댓글');
      final tried = requests.where((r) => r.url.path.endsWith('/comments'));
      expect(tried.length, 1, reason: '먼저 보내 보고');
      final firstId = bodyOf(tried.single)['clientId'] as String;
      final item = session.outbox.items.single;
      expect(item.kind, OutboxKind.comment);
      expect(item.clientId, firstId, reason: '처음 보낸 임시 id 그대로');
      expect(item.preview, '댓글 · 오프라인 댓글');
      expect(item.isNew, isTrue);
      expect(session.outbox.commentsFor('m1'), [item]);
      expect(
        session.outbox.pendingActionFor('m1'),
        isNull,
        reason: '댓글은 원본 말풍선의 "반영 대기"가 아니다',
      );

      // 끊긴 것이 확인된 동안은 보내 보지 않고 바로 대기열로.
      session.connectionLost = true;
      await controller.postCommentSticker('m1', 'sticker-1');
      expect(requests.where((r) => r.url.path.endsWith('/comments')).length, 1);
      expect(session.outbox.items.last.payload['type'], 'sticker');
      session.connectionLost = false;

      offline = false;
      await settle(session);
      expect(session.outbox.items, isEmpty);
      final sent = [
        for (final r in requests)
          if (r.url.path.endsWith('/comments')) bodyOf(r),
      ];
      expect(sent.length, 3);
      expect(sent[1]['clientId'], firstId);
      expect(sent[1]['text'], '오프라인 댓글');
      expect(sent[2]['type'], 'sticker');
      expect(sent[2]['text'], 'sticker-1');
      expect(sent[2]['clientId'], isNot(firstId));
    });

    test('사진·파일 메시지의 설명 고치기 — 화면에 먼저(설명·지운 첨부), 연결되면 지울 첨부와 함께', () async {
      final session = build();
      final controller = session.controllerFor(session.rooms.single);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(controller.messages.single.attachments.length, 2);
      offline = true;
      await controller.editMediaMessage(
        'm1',
        '새 설명',
        removeAttachmentIds: const ['a1'],
      );
      final m = controller.messages.single;
      expect(m.text, '새 설명');
      expect(m.attachments.map((a) => a.id), ['a2']);
      expect(m.editedAt, isNotNull);
      final edit = session.outbox.items.single;
      expect(edit.kind, OutboxKind.edit);
      expect(edit.payload['removeAttachmentIds'], ['a1']);
      expect(session.outbox.pendingActionFor('m1'), same(edit));

      offline = false;
      await settle(session);
      final patch = requests.lastWhere((r) => r.method == 'PATCH');
      expect(patch.url.path, '/api/messages/m1');
      expect(bodyOf(patch), {
        'text': '새 설명',
        'mentions': [],
        'removeAttachmentIds': ['a1'],
      });
      expect(session.outbox.items, isEmpty);
    });
  });

  group('비밀 대화의 사진·파일 대기열', () {
    test('평문 바이트는 메모리에만 — 저장하지 않고, 올릴 파일은 그 바이트로', () async {
      final prefs = await SharedPreferences.getInstance();
      final outbox = MessageOutbox(
        send: (p) async => null,
        deliver: (item) async =>
            throw const MessageSendException('끊김', transient: true),
      );
      await outbox.load(prefs, 'U1');
      final bytes = Uint8List.fromList([1, 2, 3]);
      final file = OutboxFile(
        path: '',
        name: '계약서.pdf',
        size: 3,
        mimeType: 'application/pdf',
        isImage: false,
        bytes: bytes,
      );
      final item = outbox.submit(
        roomId: 'S1',
        payload: {'type': 'file', 'text': '설명'},
        files: [file],
        secret: true,
      );
      outbox.submit(roomId: 'R2', payload: {'type': 'text', 'text': '보통'});
      await Future<void>.delayed(Duration.zero);
      expect(item.preview, '계약서.pdf · 설명');
      expect(file.toJson().containsKey('bytes'), isFalse);
      final raw = prefs.getString(MessageOutbox.prefsKey('U1'))!;
      expect(raw.contains('계약서'), isFalse);
      final opened = await openOutboxFile(file);
      expect(await opened!.readAsBytes(), [1, 2, 3]);
      expect(opened.name, '계약서.pdf');

      // 올린 뒤(secretAttachment) — 미리보기는 서버 칸('encrypted')이 아니라 원래 이름.
      expect(
        outboxPreviewOf({
          'type': 'file',
          'secretAttachment': {'fileName': '견적.xlsx'},
        }),
        '견적.xlsx',
      );
    });
  });

  test('앱 폴더에 담은 첨부는 원래 이름으로 올라간다(예전엔 "0.bin")', () async {
    final tmp = Directory.systemTemp.createTempSync('outbox_names_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    outboxFilesBaseDir = () async => tmp;
    final files = await stashFilesForOutbox('c-2', [
      (bytes: [1], name: '회의 사진.jpg', mimeType: 'image/jpeg', isImage: true),
      (bytes: [2], name: 'a/b:c?.txt', mimeType: null, isImage: false),
    ]);
    expect((await openOutboxFile(files![0]))!.name, '회의 사진.jpg');
    expect((await openOutboxFile(files[1]))!.name, 'a_b_c_.txt');
    expect(files[1].name, 'a/b:c?.txt', reason: '보여 줄 이름은 그대로');
    await deleteOutboxFiles('c-2');
    expect(await openOutboxFile(files[0]), isNull);
  });

  group('빠진 구간 메우기(기록 동기화)', () {
    late Directory tmp;
    late OfflineCache cache;
    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('offline_sync_');
      cache = OfflineCache(baseDir: () async => tmp);
      await cache.configure('https://s:3000', 'U1');
    });
    tearDown(() async {
      cache.close();
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    /// 서버 — R1에 [total]통(1분 간격), before 앞의 최근 limit통을 준다.
    ({RawMessagePageFetcher fetch, List<DateTime?> calls}) server(int total) {
      final calls = <DateTime?>[];
      final all = [
        for (var i = 0; i < total; i++) _msg('m$i', i, text: '글 $i'),
      ];
      Future<List<Map<String, dynamic>>> fetch(
        DateTime? before,
        int limit,
      ) async {
        calls.add(before);
        final eligible = [
          for (final m in all)
            if (before == null ||
                (m['createdAt'] as int) < before.millisecondsSinceEpoch)
              m,
        ];
        return eligible.sublist(
          eligible.length > limit ? eligible.length - limit : 0,
        );
      }

      return (fetch: fetch, calls: calls);
    }

    test('끊길 때 적어 둔 자리까지 최근 페이지부터 거꾸로 받아 이어 붙인다', () async {
      await cache.saveMessages('R1', [
        for (var i = 0; i < 10; i++) _msg('m$i', i),
      ]);
      await cache.saveMessages('R2', [
        {..._msg('x', 3), 'roomId': 'R2'},
      ]);
      await cache.markSyncPoints();
      expect(
        (await cache.syncPoints())['R1'],
        _t0.add(const Duration(minutes: 9)),
      );
      // 이미 적힌 자리는 더 이른 쪽을 남긴다(아직 다 메우지 못한 동안 또 끊김).
      await cache.appendMessage('R1', _msg('m10', 10));
      await cache.markSyncPoints();
      expect(
        (await cache.syncPoints())['R1'],
        _t0.add(const Duration(minutes: 9)),
      );

      final s = server(260);
      final got = await cache.fillGap(
        'R1',
        (await cache.syncPoints())['R1']!,
        s.fetch,
        pageSize: 100,
      );
      expect(s.calls.length, 3, reason: '100·100·60(9분에 닿음)');
      expect(got, 260);
      expect(await cache.db!.count('R1'), 260);
      // 오프라인으로 위로 넘겨 보면 빈 곳 없이 이어진다.
      final older = await cache.olderMessages(
        'R1',
        _t0.add(const Duration(minutes: 150)),
        limit: 3,
      );
      expect(older.map((m) => m['id']), ['m147', 'm148', 'm149']);
      await cache.clearSyncPoint('R1');
      expect((await cache.syncPoints()).keys, ['R2']);
    });

    test('방의 처음에 닿으면 끝, 너무 많이 빠졌으면 이어지지 않는 옛 저장분을 지운다', () async {
      final short = server(30);
      expect(await cache.fillGap('R1', _t0, short.fetch, pageSize: 100), 30);
      expect(short.calls.length, 1);

      await cache.forgetRoom('R1');
      await cache.saveMessages('R1', [_msg('old', -1000)]);
      final long = server(400);
      await cache.fillGap(
        'R1',
        _t0.subtract(const Duration(minutes: 1000)),
        long.fetch,
        pageSize: 100,
        maxMessages: 200,
      );
      expect(long.calls.length, 2);
      expect(await cache.db!.count('R1'), 200, reason: '이어지지 않는 "old"는 지움');
      expect((await cache.messages('R1')).last['id'], 'm399');
    });

    test('연결이 끊기면 받은 만큼 남기고 오류를 그대로(자리는 남아 다음에 이어서)', () async {
      await cache.saveMessages('R1', [_msg('m0', 0)]);
      await cache.markSyncPoints();
      var n = 0;
      await expectLater(
        cache.fillGap('R1', _t0, (before, limit) async {
          if (n++ > 0) throw http.ClientException('끊김');
          return [for (var i = 300; i < 400; i++) _msg('m$i', i)];
        }, pageSize: 100),
        throwsA(isA<http.ClientException>()),
      );
      expect(await cache.db!.count('R1'), 101);
      expect((await cache.syncPoints()).containsKey('R1'), isTrue);
    });
  });

  testWidgets('댓글 화면의 대기 말풍선 — 그 메시지에 달 댓글만, "연결되면 보냅니다"', (tester) async {
    final session = Session(
      notifications: NotificationService(),
      settings: AppSettings(),
    );
    session.outbox.submitAction(
      roomId: 'r1',
      kind: OutboxKind.comment,
      payload: {'messageId': 'm1', 'type': 'text', 'text': '댓글 하나'},
      preview: '댓글 · 댓글 하나',
    );
    session.outbox.submitAction(
      roomId: 'r1',
      kind: OutboxKind.comment,
      payload: {'messageId': 'm2', 'type': 'text', 'text': '다른 글의 댓글'},
      preview: '댓글 · 다른 글의 댓글',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: OutboxStrip(session: session, roomId: 'r1', commentsOf: 'm1'),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('댓글 · 댓글 하나'), findsOneWidget);
    expect(find.text('댓글 · 다른 글의 댓글'), findsNothing);
    expect(find.textContaining('연결되면 보냅니다'), findsOneWidget);
  });
}
