// 오프라인 후속(남은 것) 2 — 오프라인 중 사진·파일 댓글(대기열), 빠진 구간 밖에서 바뀐 것 맞추기(서버의 "이후 바뀐 것").

import 'dart:convert';
import 'dart:io';

import 'package:client/models/app_user.dart';
import 'package:client/models/room.dart';
import 'package:client/models/uploaded_attachment.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/message_outbox.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/offline_cache.dart';
import 'package:client/services/outbox_files_io.dart' show outboxFilesBaseDir;
import 'package:client/services/session.dart';
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

  group('오프라인 중 사진·파일 댓글', () {
    const serverUrl = 'https://192.168.0.10:3000';
    late List<http.Request> requests;
    late bool offline;
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('comment_files_');
      outboxFilesBaseDir = () async => tmp;
    });
    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

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
          final path = request.url.path;
          if (path == '/api/upload') {
            body = {
              'url': '/uploads/up-1',
              'fileName': '계약서.pdf',
              'size': 3,
              'mimeType': 'application/pdf',
            };
          } else if (request.method == 'GET' && path.endsWith('/messages')) {
            body = [
              {..._msg('m1', 0, text: '원본'), 'roomId': 'r1'},
            ];
          } else if (path.endsWith('/comments')) {
            body = {
              'id': 'c1',
              'messageId': 'm1',
              'roomId': 'r1',
              'senderId': 'u1',
              'senderName': 'Riley',
              'type': 'file',
              'createdAt': _t0.millisecondsSinceEpoch,
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

    Future<void> settle(Session session) async {
      for (var i = 0; i < 100 && session.outbox.hasPending; i++) {
        await session.outbox.drain();
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }

    Map<String, dynamic> bodyOf(http.Request r) =>
        jsonDecode(r.body) as Map<String, dynamic>;

    test('올리지 못한 첨부 — 이 기기에 담아 대기열에, 연결되면 올려서 같은 임시 id로 단다', () async {
      final session = build();
      await session.outbox.load(await SharedPreferences.getInstance(), 'u1');
      final controller = session.controllerFor(session.rooms.single);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      offline = true;
      final ok = await controller.queueCommentAttachment('m1', (
        bytes: [1, 2, 3],
        name: '계약서.pdf',
        mimeType: 'application/pdf',
        isImage: false,
      ), caption: ' 검토 부탁 ');
      expect(ok, isTrue);
      final item = session.outbox.items.single;
      expect(item.kind, OutboxKind.comment);
      expect(item.files.single.name, '계약서.pdf');
      expect(item.preview, '댓글 · 계약서.pdf · 검토 부탁');
      expect(session.outbox.commentsFor('m1'), [item]);
      // 담아 둔 파일은 앱을 다시 켜도 남게 저장된다(비밀 대화가 아니면).
      final saved = await SharedPreferences.getInstance();
      expect(
        saved.getString(MessageOutbox.prefsKey('u1'))!.contains('계약서.pdf'),
        isTrue,
      );

      offline = false;
      await settle(session);
      expect(session.outbox.items, isEmpty);
      final upload = requests.where((r) => r.url.path == '/api/upload');
      expect(upload.length, greaterThanOrEqualTo(1));
      final sent = bodyOf(
        requests.lastWhere((r) => r.url.path.endsWith('/comments')),
      );
      expect(sent, {
        'type': 'file',
        'text': '검토 부탁',
        'fileUrl': '/uploads/up-1',
        'fileName': '계약서.pdf',
        'fileSize': 3,
        'mimeType': 'application/pdf',
        'clientId': item.clientId,
      });
      // 다 올렸으니 담아 둔 폴더도 치웠다.
      expect(tmp.listSync(), isEmpty);
    });

    test('이미 올린 첨부의 댓글도 서버에 닿지 않으면 대기열로(임시 id 그대로)', () async {
      final session = build();
      final controller = session.controllerFor(session.rooms.single);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      offline = true;
      await controller.postUploadedCommentAttachment(
        'm1',
        UploadedAttachment(
          isImage: true,
          url: '/uploads/p.png',
          fileName: 'p.png',
          size: 10,
          mimeType: 'image/png',
          thumbnailUrl: '/uploads/p_t.png',
        ),
      );
      final tried = requests.where((r) => r.url.path.endsWith('/comments'));
      expect(tried.length, 1, reason: '먼저 달아 보고');
      final firstId = bodyOf(tried.single)['clientId'];
      final item = session.outbox.items.single;
      expect(item.clientId, firstId);
      expect(item.preview, '댓글 · 사진');

      offline = false;
      await settle(session);
      final sent = bodyOf(
        requests.lastWhere((r) => r.url.path.endsWith('/comments')),
      );
      expect(sent['clientId'], firstId);
      expect(sent['type'], 'image');
      expect(sent['fileUrl'], '/uploads/p.png');
      expect(sent['thumbnailUrl'], '/uploads/p_t.png');
      expect(sent.containsKey('text'), isFalse);
      expect(session.outbox.items, isEmpty);
    });

    test('버리면 담아 둔 파일도 치운다', () async {
      final session = build();
      final controller = session.controllerFor(session.rooms.single);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      session.connectionLost = true;
      offline = true;
      await controller.queueCommentAttachment('m1', (
        bytes: [9],
        name: 'a.txt',
        mimeType: null,
        isImage: false,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(tmp.listSync(), isNotEmpty);
      final item = session.outbox.items.single;
      // 끊긴 것이 확인된 동안이라 대기열에서 기다린다 — 실패로 바꿔 지운다.
      item.state = OutboxState.failed;
      session.outbox.discard(item.clientId);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(tmp.listSync(), isEmpty);
    });
  });

  group('빠진 구간 밖에서 바뀐 것 맞추기', () {
    late Directory tmp;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('offline_changes_');
    });
    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    Future<OfflineCache> open() async {
      final cache = OfflineCache(baseDir: () async => tmp);
      await cache.configure('https://s:3000', 'U1');
      return cache;
    }

    test('막 로그인(저장분 없음)이면 지금 자리만 받고, 다음부터 그 자리 뒤를', () async {
      final cache = await open();
      addTearDown(cache.close);
      await cache.saveMessages('R1', [_msg('m1', 1)]); // 로그인 뒤 받은 것.
      final calls = <String?>[];
      await cache.syncChanges((since) async {
        calls.add(since);
        return {'messages': [], 'removed': [], 'cursor': '500', 'more': false};
      });
      await cache.syncChanges((since) async {
        calls.add(since);
        return {'messages': [], 'removed': [], 'cursor': '900', 'more': false};
      });
      expect(calls, [null, '500']);
      expect(await cache.changesCursor(), '900');
    });

    test('저장해 둔 것만 바꾸고(새로 넣지 않음), 지운 것은 지우고, 대기 중인 것은 둔다', () async {
      final first = await open();
      await first.saveMessages('R1', [
        for (var i = 0; i < 4; i++) _msg('m$i', i, text: '글 $i'),
      ]);
      first.close();

      // 이 기능 전에 쌓인 저장분 — 커서가 없으면 처음('0')부터.
      final cache = await open();
      addTearDown(cache.close);
      final calls = <String?>[];
      final pages = [
        {
          'messages': [
            {
              ..._msg('m0', 0, text: '고친 글'),
              'editedAt': _t0.millisecondsSinceEpoch,
            },
            _msg('outside', -500, text: '저장 안 된 옛 메시지'),
          ],
          'removed': [
            {'id': 'm1', 'roomId': 'R1'},
          ],
          'cursor': '100:aaaa',
          'more': true,
        },
        {
          'messages': [
            {
              ..._msg('m2', 2, text: '글 2'),
              'comments': [
                {'id': 'c1', 'messageId': 'm2', 'text': '옛 메시지에 단 댓글'},
              ],
            },
            {..._msg('m3', 3), 'deleted': true, 'text': null},
          ],
          'removed': [],
          'cursor': '200',
          'more': false,
        },
      ];
      final n = await cache.syncChanges((since) async {
        calls.add(since);
        return pages[calls.length - 1];
      }, keepLocal: (id) => id == 'm3');
      expect(n, 2);
      expect(calls, ['0', '100:aaaa']);
      final stored = {for (final m in await cache.messages('R1')) m['id']: m};
      expect(stored.keys, ['m0', 'm2', 'm3'], reason: 'm1은 지움, outside는 넣지 않음');
      expect(stored['m0']!['text'], '고친 글');
      expect((stored['m2']!['comments'] as List).single['text'], '옛 메시지에 단 댓글');
      expect(
        stored['m3']!['deleted'],
        isNot(true),
        reason: '이 기기의 일이 기다리는 메시지',
      );
      expect(await cache.changesCursor(), '200');
      // 지운 메시지는 찾기에서도 빠진다.
      expect(await cache.searchMessages('글 1'), isEmpty);
    });

    test('끊기면 받은 페이지까지의 커서를 남기고 오류를 그대로', () async {
      final cache = await open();
      addTearDown(cache.close);
      await cache.saveMessages('R1', [_msg('m0', 0)]);
      await cache.syncChanges(
        (since) async => {
          'messages': [],
          'removed': [],
          'cursor': '10',
          'more': false,
        },
      );
      var n = 0;
      await expectLater(
        cache.syncChanges((since) async {
          if (n++ > 0) throw http.ClientException('끊김');
          return {
            'messages': [_msg('m0', 0, text: '바뀜')],
            'removed': [],
            'cursor': '20:bbbb',
            'more': true,
          };
        }),
        throwsA(isA<http.ClientException>()),
      );
      expect(await cache.changesCursor(), '20:bbbb');
      expect((await cache.messages('R1')).single['text'], '바뀜');
    });

    test('완전히 지운 메시지(message:expired) — 이 기기 메시지 DB에서도', () async {
      final cache = await open();
      addTearDown(cache.close);
      await cache.saveMessages('R1', [_msg('m0', 0), _msg('m1', 1)]);
      await cache.removeMessages(['m0', '없는 id']);
      expect((await cache.messages('R1')).map((m) => m['id']), ['m1']);
    });
  });
}
