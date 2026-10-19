// 오프라인 후속 — 이 기기 메시지 DB(SQLite — 전체 기록·위로 넘겨 보기·찾기), 올리지 못한 첨부·고치기·지우기·공감·비밀 대화를
// 대기열로, 저장한 사진 미리보기 보관(고정 캐시 열쇠), 연결 오류 가리기.
import 'dart:convert';
import 'dart:io';

import 'package:client/models/app_user.dart';
import 'package:client/models/room.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/chat_image_cache.dart';
import 'package:client/services/chat_socket.dart' show MessageSendException;
import 'package:client/services/connection_errors.dart';
import 'package:client/services/local_message_store.dart';
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

Map<String, dynamic> _msg(
  String id,
  String room,
  int minute, {
  String text = '',
  String type = 'text',
  String? fileName,
  bool deleted = false,
}) => {
  'id': id,
  'roomId': room,
  'senderId': 'u2',
  'senderName': 'Sam',
  'type': type,
  'text': text,
  'fileName': ?fileName,
  'deleted': deleted,
  'createdAt': DateTime(2026, 10, 18, 9, minute).millisecondsSinceEpoch,
};

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('이 기기 메시지 DB', () {
    late Directory tmp;
    late LocalMessageStore store;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('local_store_');
      store = LocalMessageStore.open('${tmp.path}/m.sqlite')!;
    });
    tearDown(() {
      store.close();
      tmp.deleteSync(recursive: true);
    });

    test('넣고·바꾸고, 방의 최근 것과 그보다 오래된 것을 차례대로', () {
      store.upsertAll('R1', [
        for (var i = 0; i < 30; i++) _msg('m$i', 'R1', i, text: '글 $i'),
      ]);
      store.upsertAll('R2', [_msg('x', 'R2', 1, text: '다른 방')]);
      expect(store.count('R1'), 30);
      final latest = store.latest('R1', limit: 10);
      expect(latest.map((m) => m['id']), [for (var i = 20; i < 30; i++) 'm$i']);
      final older = store.older('R1', DateTime(2026, 10, 18, 9, 20), limit: 5);
      expect(older.map((m) => m['id']), ['m15', 'm16', 'm17', 'm18', 'm19']);
      store.upsertAll('R1', [_msg('m29', 'R1', 29, text: '고친 글')]);
      expect(store.latest('R1', limit: 1).single['text'], '고친 글');
      expect(store.count('R1'), 30);
      store.update(
        'm28',
        (raw) => {
          ...raw,
          'reactions': ['x'],
        },
      );
      expect(store.latest('R1', limit: 2).first['reactions'], ['x']);
    });

    test('찾기 — 세 글자 이상은 전문 검색(한국어 중간 글자), 짧으면 LIKE, 방 거르기, 지운 것·이모티콘 제외', () {
      store.upsertAll('R1', [
        _msg('a', 'R1', 1, text: '내일 오전 주간회의는 3층에서'),
        _msg('b', 'R1', 2, text: '회의록 올렸습니다'),
        _msg('c', 'R1', 3, type: 'file', fileName: '견적서_최종.pdf'),
        _msg('d', 'R1', 4, text: '회의 취소', deleted: true),
        _msg('e', 'R1', 5, type: 'sticker', text: '회의'),
      ]);
      store.upsertAll('R2', [_msg('f', 'R2', 6, text: '주간회의 자료')]);
      expect(store.search('주간회의').map((m) => m['id']), ['f', 'a']);
      expect(store.search('주간회의', roomIds: ['R1']).map((m) => m['id']), ['a']);
      expect(store.search('회의').map((m) => m['id']), ['f', 'b', 'a']);
      expect(store.search('견적서').single['id'], 'c', reason: '파일 이름');
      expect(store.search('"따옴표'), isEmpty);
      expect(store.search('  '), isEmpty);
      expect(store.search('회의', roomIds: const []), isEmpty);
    });

    test('방을 잊으면 그 방만 지운다', () {
      store.upsertAll('R1', [_msg('a', 'R1', 1, text: '하나')]);
      store.upsertAll('R2', [_msg('b', 'R2', 1, text: '하나')]);
      store.forgetRoom('R1');
      expect(store.count(), 1);
      expect(store.search('하나').single['id'], 'b');
    });
  });

  group('오프라인 보기 저장소 — 메시지는 DB로', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('offline_db_'));
    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('최근 페이지와 더 오래된 페이지가 함께 쌓이고, 위로 넘겨 보기·찾기, 로그아웃하면 지움', () async {
      final cache = OfflineCache(baseDir: () async => tmp);
      await cache.configure('https://s:3000', 'U1');
      cache.saveMessages('R1', [
        for (var i = 50; i < 100; i++) _msg('m$i', 'R1', i, text: '최근 $i'),
      ]);
      cache.saveMessages('R1', [
        for (var i = 0; i < 50; i++) _msg('m$i', 'R1', i, text: '예전 $i'),
      ]);
      expect((await cache.messages('R1')).first['id'], 'm50');
      final older = await cache.olderMessages(
        'R1',
        DateTime(2026, 10, 18, 9, 50),
        limit: 3,
      );
      expect(older.map((m) => m['id']), ['m47', 'm48', 'm49']);
      expect(
        (await cache.searchMessages('예전 1')).map((m) => m['id']),
        containsAll(['m1', 'm10', 'm19']),
      );
      cache.updateMessage('m99', (raw) => {...raw, 'deleted': true});
      expect(await cache.searchMessages('최근 99'), isEmpty);
      await cache.clear();
      final again = OfflineCache(baseDir: () async => tmp);
      await again.configure('https://s:3000', 'U1');
      expect(await again.messages('R1'), isEmpty);
      again.close();
    });
  });

  group('보내기 대기열 — 고치기·지우기·공감·첨부·비밀 대화', () {
    test('고치기·지우기·공감은 deliver로, 공감은 같은 메시지의 앞 것을 바꿔 끼움', () async {
      final done = <String>[];
      var online = false;
      final outbox = MessageOutbox(
        send: (p) async => null,
        deliver: (item) async {
          if (!online) {
            throw const MessageSendException('끊김', transient: true);
          }
          done.add(
            '${item.kind}:${item.payload['emoji'] ?? item.payload['text'] ?? ''}',
          );
        },
        isTransient: isConnectionError,
      );
      outbox.submitAction(
        roomId: 'R1',
        kind: OutboxKind.edit,
        payload: {'messageId': 'm1', 'text': '고침'},
        preview: '메시지 수정 · 고침',
      );
      outbox.submitAction(
        roomId: 'R1',
        kind: OutboxKind.reaction,
        payload: {'messageId': 'm2', 'emoji': '👍'},
        preview: '공감',
      );
      outbox.submitAction(
        roomId: 'R1',
        kind: OutboxKind.reaction,
        payload: {'messageId': 'm2', 'emoji': '❤️'},
        preview: '공감',
      );
      outbox.submitAction(
        roomId: 'R1',
        kind: OutboxKind.delete,
        payload: {'messageId': 'm3'},
        preview: '메시지 삭제',
      );
      await Future<void>.delayed(Duration.zero);
      expect(outbox.items.length, 3, reason: '공감은 마지막 것만 남는다');
      expect(outbox.pendingActionFor('m1')?.kind, OutboxKind.edit);
      expect(outbox.pendingActionFor('m2'), isNull, reason: '공감은 말풍선에 이미 보인다');
      online = true;
      await outbox.drain();
      expect(done, ['edit:고침', 'reaction:❤️', 'delete:']);
      expect(outbox.items, isEmpty);
    });

    test('서버가 거절하면(연결 문제가 아니면) 실패로 — 버리면 onDiscarded', () async {
      final discarded = <OutboxItem>[];
      final outbox = MessageOutbox(
        send: (p) async => null,
        deliver: (item) async =>
            throw const ApiException('수정할 수 있는 시간이 지났습니다.', statusCode: 403),
        isTransient: isConnectionError,
        onDiscarded: discarded.add,
      );
      final item = outbox.submitAction(
        roomId: 'R1',
        kind: OutboxKind.edit,
        payload: {'messageId': 'm1', 'text': '고침'},
        preview: '메시지 수정',
      );
      await Future<void>.delayed(Duration.zero);
      expect(item.state, OutboxState.failed);
      expect(item.error, contains('시간이 지났습니다'));
      outbox.discard(item.clientId);
      expect(discarded.single.kind, OutboxKind.edit);
    });

    test('비밀 대화 것은 저장하지 않는다(평문) — 다시 켜면 없음, 보통 것은 남음', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final outbox = MessageOutbox(
        send: (p) async =>
            throw const MessageSendException('끊김', transient: true),
        deliver: (item) async =>
            throw const MessageSendException('끊김', transient: true),
      );
      await outbox.load(prefs, 'U1');
      outbox.submit(
        roomId: 'R1',
        payload: {'type': 'text', 'text': '비밀'},
        secret: true,
      );
      outbox.submit(roomId: 'R2', payload: {'type': 'text', 'text': '보통'});
      await Future<void>.delayed(Duration.zero);
      expect(outbox.items.length, 2);
      final raw = prefs.getString(MessageOutbox.prefsKey('U1'))!;
      expect(raw.contains('비밀'), isFalse);
      final again = MessageOutbox(send: (p) async => null);
      await again.load(prefs, 'U1');
      expect(again.items.single.payload['text'], '보통');
    });

    test('올리지 못한 첨부 — 저장했다 다시 읽고, 미리보기에 수를 더하고, 하나만 남으면 예전 모양으로', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final outbox = MessageOutbox(
        send: (p) async => null,
        deliver: (item) async =>
            throw const MessageSendException('끊김', transient: true),
      );
      await outbox.load(prefs, 'U1');
      final item = outbox.submit(
        roomId: 'R1',
        payload: {
          'type': 'image',
          'attachments': [
            {'kind': 'image', 'fileUrl': '/uploads/a.png', 'fileName': 'a.png'},
          ],
        },
        files: const [
          OutboxFile(path: '/x/0.bin', name: 'b.jpg', size: 10, isImage: true),
        ],
      );
      expect(item.preview, '사진 2장');
      await Future<void>.delayed(Duration.zero);
      final again = MessageOutbox(send: (p) async => null);
      await again.load(prefs, 'U1');
      expect(again.items.single.files.single.name, 'b.jpg');
      final single = sendableOutboxPayload({
        'type': 'image',
        'text': '캡션',
        'clientId': 'c1',
        'attachments': [
          {
            'kind': 'image',
            'fileUrl': '/uploads/a.png',
            'fileName': 'a.png',
            'fileSize': 3,
            'thumbnailUrl': '/uploads/t.png',
          },
        ],
      });
      expect(single, {
        'type': 'image',
        'text': '캡션',
        'clientId': 'c1',
        'fileUrl': '/uploads/a.png',
        'fileName': 'a.png',
        'fileSize': 3,
        'thumbnailUrl': '/uploads/t.png',
      });
      final two = {
        'attachments': [{}, {}],
      };
      expect(sendableOutboxPayload(two), same(two));
    });

    test('첨부를 앱 폴더에 복사하고 치운다', () async {
      final tmp = Directory.systemTemp.createTempSync('outbox_files_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      outboxFilesBaseDir = () async => tmp;
      final files = await stashFilesForOutbox('c-1', [
        (
          bytes: [1, 2, 3],
          name: '사진.jpg',
          mimeType: 'image/jpeg',
          isImage: true,
        ),
        (bytes: [4], name: '문서.pdf', mimeType: null, isImage: false),
      ]);
      expect(files!.map((f) => f.name), ['사진.jpg', '문서.pdf']);
      expect(await outboxFileExists(files.first.path), isTrue);
      expect(File(files.first.path).readAsBytesSync(), [1, 2, 3]);
      await deleteOutboxFiles('c-1');
      expect(await outboxFileExists(files.first.path), isFalse);
    });
  });

  test('연결 오류 가리기', () {
    expect(isConnectionError(http.ClientException('x')), isTrue);
    expect(isConnectionError(const SocketException('x')), isTrue);
    expect(isConnectionError(const ApiTimeoutException('시간 초과')), isTrue);
    expect(isConnectionError(const ApiException('x', statusCode: 503)), isTrue);
    expect(
      isConnectionError(const ApiException('x', statusCode: 403)),
      isFalse,
    );
    expect(isConnectionError(const ApiException('x')), isFalse);
    expect(isConnectionError(StateError('x')), isFalse);
  });

  test('사진 미리보기 캐시 열쇠 — 서명 링크가 아니라 첨부 id로 고정', () {
    expect(chatImageCacheKey('a1'), 'chat-image:a1:t');
    expect(chatImageCacheKey('a1', thumbnail: false), 'chat-image:a1:o');
  });

  group('세션·컨트롤러 — 오프라인 중 고치기·지우기·공감', () {
    const serverUrl = 'https://192.168.0.10:3000';
    late List<http.Request> requests;
    late bool offline;

    Session build() {
      requests = [];
      offline = true;
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
          if (request.url.path.endsWith('/messages')) {
            return http.Response.bytes(
              utf8.encode(
                jsonEncode([
                  {
                    'id': 'm1',
                    'roomId': 'r1',
                    'senderId': 'u1',
                    'senderName': 'Riley',
                    'type': 'text',
                    'text': '원래 글',
                    'createdAt': DateTime(2026, 10, 18).millisecondsSinceEpoch,
                  },
                ]),
              ),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }
          return http.Response('{}', 200);
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

    test('서버에 닿지 않으면 화면에 먼저 고치고·지우고 대기열에 넣는다', () async {
      final session = build();
      offline = false;
      final controller = session.controllerFor(session.rooms.single);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(controller.messages.single.text, '원래 글');
      offline = true;
      await controller.editMessage('m1', '고친 글');
      expect(controller.messages.single.text, '고친 글');
      expect(controller.messages.single.editedAt, isNotNull);
      final edit = session.outbox.items.single;
      expect(edit.kind, OutboxKind.edit);
      expect(edit.payload['text'], '고친 글');
      await controller.deleteMessage('m1');
      expect(controller.messages.single.deleted, isTrue);
      expect(session.outbox.items.map((i) => i.kind), [
        OutboxKind.edit,
        OutboxKind.delete,
      ]);
      final m = controller.messages.single;
      await session.toggleMessageReaction(m, '👍');
      expect(m.reactions.single.emoji, '👍', reason: '화면에 보인 그대로');
      expect(session.outbox.items.last.kind, OutboxKind.reaction);
    });
  });

  testWidgets('대기 말풍선 — 고치기는 "연결되면 반영합니다", 실패한 공감만 보이고, 비밀 대화는 "앱을 끄면 사라집니다"', (
    tester,
  ) async {
    final session = Session(
      notifications: NotificationService(),
      settings: AppSettings(),
    );
    session.outbox.submitAction(
      roomId: 'r1',
      kind: OutboxKind.edit,
      payload: {'messageId': 'm1', 'text': '고침'},
      preview: '메시지 수정 · 고침',
    );
    session.outbox.submitAction(
      roomId: 'r1',
      kind: OutboxKind.reaction,
      payload: {'messageId': 'm2', 'emoji': '👍'},
      preview: '공감 👍',
    );
    final secret = session.outbox.submit(
      roomId: 'r1',
      payload: {'type': 'text', 'text': '비밀 글'},
      secret: true,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: OutboxStrip(session: session, roomId: 'r1'),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('메시지 수정 · 고침'), findsOneWidget);
    expect(find.textContaining('연결되면 반영합니다'), findsOneWidget);
    expect(find.text('공감 👍'), findsNothing);
    expect(
      tester
          .widget<Text>(
            find.byKey(ValueKey('outbox-status-${secret.clientId}')),
          )
          .data,
      contains('앱을 끄면 사라집니다'),
    );
  });
}
