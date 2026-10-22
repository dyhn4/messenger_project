// 통화 녹화·회의록 후속 — 회의록 할 일을 할 일로(담당자 찾기), 녹화 파일 보관(카드·관리자 콘솔), 화이트보드 여러 쪽·저장한 판
// 불러오기, 실시간 자막(최근 줄만 잠깐).

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:client/models/app_user.dart';
import 'package:client/models/call_recording.dart';
import 'package:client/models/room.dart';
import 'package:client/screens/admin_call_recordings_section.dart';
import 'package:client/screens/call/call_recording_widgets.dart';
import 'package:client/screens/call_minutes_screen.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/call_whiteboard.dart';
import 'package:client/services/message_outbox.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/outbox_files_io.dart' show outboxFilesBaseDir;
import 'package:client/services/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _serverUrl = 'https://192.168.0.10:3000';

Session _session(Future<http.Response> Function(http.Request) handler) {
  final s = Session(
    notifications: NotificationService(),
    settings: AppSettings(),
  );
  s.serverUrl = _serverUrl;
  s.userId = 'me';
  s.api = ApiClient(
    baseUrl: _serverUrl,
    token: 't',
    httpClient: MockClient(handler),
  );
  return s;
}

http.Response _json(Object body, [int status = 200]) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

AppUser _user(String id, String name) =>
    AppUser(id: id, username: id, name: name);

Room _room() => Room.fromJson({
  'id': 'room1',
  'teamId': 't1',
  'type': 'topic',
  'name': '개발팀',
  'members': [],
  'createdAt': 1000,
});

/// 보낸 화이트보드 메시지(받는 사람과 함께).
class _Sent {
  final messages = <(WhiteboardMessage, List<String>?)>[];
  Future<void> send(WhiteboardMessage m, {List<String>? to}) async =>
      messages.add((m, to));
  List<WhiteboardMessage> get all => [for (final (m, _) in messages) m];
}

WhiteboardMessage _roundTrip(WhiteboardMessage m) =>
    WhiteboardMessage.decode(m.encode())!;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('회의록 할 일', () {
    test('담당자 글을 방 멤버로 — 같은 이름·님 뗀 이름·한 명만 맞을 때만', () {
      final members = [
        _user('a', '김민수'),
        _user('b', '박지영'),
        _user('c', '이수진'),
        _user('d', '이수'),
      ];
      List<String> ids(String? owner) => [
        for (final u in callActionItemOwners(owner, members)) u.id,
      ];
      expect(ids('김민수'), ['a']);
      expect(ids('박지영님'), ['b']);
      expect(ids('김민수, 박지영'), ['a', 'b']);
      expect(ids('이수진'), ['c'], reason: '같은 이름이 있으면 그 사람');
      expect(ids('수진'), ['c']);
      expect(ids('이수'), ['d']);
      expect(ids('최영희'), isEmpty);
      expect(ids(null), isEmpty);
      expect(ids('김'), isEmpty, reason: '한 글자는 고르지 않는다');
    });

    test('응답의 할 일·카드의 지운 녹화 파일을 읽는다', () {
      final rec = CallRecording.fromJson({
        'id': 'r1',
        'roomId': 'room',
        'startedByName': 'A',
        'startedAt': 0,
        'status': 'done',
        'actionItems': [
          {
            'text': '견적서 보내기',
            'owner': '김민수',
            'dueText': '10/30',
            'due': '2026-10-30',
          },
          {'text': '서버 점검'},
          {'nope': true},
        ],
      });
      expect(rec.actionItems.length, 2);
      expect(rec.actionItems.first.due, DateTime(2026, 10, 30));
      expect(rec.actionItems.last.owner, isNull);
      final entry = CallRecordingEntry.fromJson({
        'id': 'r1',
        'at': 0,
        'name': 'A',
        'status': 'done',
        'purged': 'size',
      });
      expect(entry!.purged, 'size');
    });

    testWidgets('회의록 화면 — 요약의 할 일마다 [할 일로]', (tester) async {
      final session = _session(
        (request) async => _json({
          'recording': {
            'id': 'r1',
            'roomId': 'room1',
            'startedByName': '김민수',
            'startedAt': DateTime(2026, 10, 22, 10).millisecondsSinceEpoch,
            'status': 'done',
            'minutesStatus': 'done',
            'summary': '## 할 일\n- 김민수: 견적서 보내기 (10/30)',
            'transcript': '[00:01] 김민수: 시작',
            'actionItems': [
              {
                'text': '견적서 보내기',
                'owner': '김민수',
                'dueText': '10/30',
                'due': '2026-10-30',
              },
            ],
          },
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: CallMinutesScreen(
            session: session,
            room: _room(),
            recordingId: 'r1',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('minutes-action-items')), findsOne);
      expect(find.text('담당: 김민수 · 기한: 10/30'), findsOne);
      expect(find.byKey(const ValueKey('minutes-make-todo-0')), findsOne);
    });
  });

  group('녹화 파일 보관(관리자 콘솔)', () {
    testWidgets('녹화가 켜진 서버에서만 — 기간·용량을 적어 저장', (tester) async {
      final patches = <Map<String, dynamic>>[];
      var enabled = true;
      final session = _session((request) async {
        if (request.method == 'PATCH') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          patches.add(body);
          return _json({
            'enabled': true,
            'retentionDays': body['retentionDays'],
            'maxGb': body['maxGb'],
            'count': 1,
            'totalBytes': 2048,
            'purgedCount': 3,
          });
        }
        return _json({
          'enabled': enabled,
          'retentionDays': null,
          'maxGb': 200,
          'count': 4,
          'totalBytes': 4096,
          'purgedCount': 0,
        });
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: AdminCallRecordingsSection(session: session),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('admin-call-recordings')), findsOne);
      expect(find.text('200'), findsOne);
      await tester.enterText(find.byType(TextField).first, '90');
      await tester.enterText(find.byType(TextField).last, '');
      await tester.tap(
        find.byKey(const ValueKey('admin-call-recordings-save')),
      );
      await tester.pumpAndSettle();
      expect(patches.single, {'retentionDays': 90, 'maxGb': null});
      expect(find.textContaining('지금까지 지운 것 3개'), findsOne);
      await tester.pump(const Duration(seconds: 3));

      enabled = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AdminCallRecordingsSection(
              key: const ValueKey('off'),
              session: session,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('admin-call-recordings')), findsNothing);
    });
  });

  group('화이트보드 여러 쪽·저장한 판', () {
    test('쪽마다 획 — 모르는 쪽의 획은 쪽을 만들고, 쪽 지우기·전체 지우기(예전 앱)·빼기·비우기', () {
      final book = WhiteboardBook();
      expect(book.pageIds, [whiteboardFirstPage]);
      book.apply(
        'u1',
        const WhiteboardBegin(
          id: 's1',
          color: 1,
          width: 0.004,
          points: [Offset(0.1, 0.1)],
        ),
      );
      book.apply(
        'u2',
        _roundTrip(
          const WhiteboardBegin(
            id: 's2',
            color: 2,
            width: 0.004,
            points: [Offset(0.2, 0.2)],
            page: 'x-p2',
          ),
        ),
      );
      expect(book.pageIds, [whiteboardFirstPage, 'x-p2']);
      expect([for (final s in book.strokesOf('x-p2')) s.id], ['s2']);
      expect(book.strokesNear(const Offset(0.2, 0.2), 0.01), isEmpty);
      expect(book.strokesNear(const Offset(0.2, 0.2), 0.01, page: 'x-p2'), [
        's2',
      ]);
      // 첫 쪽의 획은 pg를 싣지 않는다(예전 앱과 같은 모양).
      expect(
        jsonDecode(
          utf8.decode(
            const WhiteboardBegin(id: 'a', color: 1, width: 0.004).encode(),
          ),
        ),
        isNot(contains('pg')),
      );

      expect(
        book.apply('u1', _roundTrip(const WhiteboardClear(page: 'x-p2'))),
        isTrue,
      );
      expect(book.isPageEmpty('x-p2'), isTrue);
      expect(book.isPageEmpty(whiteboardFirstPage), isFalse);
      expect(
        book.apply('u1', _roundTrip(const WhiteboardClear())),
        isTrue,
        reason: '쪽 없는 지우기는 판 전체',
      );
      expect(book.isEmpty, isTrue);
      expect(
        book.apply('u1', const WhiteboardPageRemove(whiteboardFirstPage)),
        isFalse,
      );
      expect(book.apply('u1', const WhiteboardPageRemove('x-p2')), isTrue);
      expect(book.pageIds, [whiteboardFirstPage]);
      book.apply('u1', const WhiteboardPageAdd('p3'));
      expect(book.apply('u1', _roundTrip(const WhiteboardReset())), isTrue);
      expect(book.pageIds, [whiteboardFirstPage]);
    });

    test('늦게 들어온 사람에게 쪽째로, 저장 모양은 앞 점과의 차이로 줄여 같은 판으로 돌아온다', () {
      final source = WhiteboardBook()
        ..apply(
          'u1',
          WhiteboardBegin(
            id: 'long',
            color: 7,
            width: 0.002,
            points: [for (var i = 0; i < 900; i++) Offset(i / 1000, 0.5)],
          ),
        )
        ..apply('u1', const WhiteboardPageAdd('u1-p2'))
        ..apply(
          'u2',
          const WhiteboardBegin(
            id: 'dot',
            color: 8,
            width: 0.008,
            points: [Offset(0.3, 0.3)],
            page: 'u1-p2',
          ),
        );
      final messages = source.snapshotMessages();
      expect(messages.first, isA<WhiteboardPageAdd>());
      final target = WhiteboardBook();
      for (final m in messages) {
        target.apply('sender', _roundTrip(m));
      }
      expect(target.pageIds, [whiteboardFirstPage, 'u1-p2']);
      expect(target['long']!.points, hasLength(900));
      expect([for (final s in target.strokesOf('u1-p2')) s.id], ['dot']);

      final saved = jsonDecode(jsonEncode(source.toSavedJson()));
      final points = (saved['pages'][0]['strokes'][0]['p'] as List).cast<int>();
      expect(points.take(4), [0, 5000, 10, 0], reason: '첫 점 그대로, 다음부터 차이');
      final loaded = WhiteboardBook()..loadSavedJson(saved);
      expect(loaded.pageIds, [whiteboardFirstPage, 'u1-p2']);
      final a = source['long']!.points;
      final b = loaded['long']!.points;
      expect(b.length, a.length);
      for (var i = 0; i < a.length; i++) {
        expect((a[i] - b[i]).distance, lessThan(0.0002));
      }
      expect(loaded['dot']!.authorId, 'u2');
      expect(loaded['dot']!.color, 8);
    });

    test('쪽 더하기·넘기기·빼기, 내 획은 보던 쪽에, 보던 쪽이 빠지면 앞 쪽으로', () {
      final sent = _Sent();
      final board = CallWhiteboard(myId: 'me', send: sent.send);
      addTearDown(board.dispose);
      board.beginStroke(const Offset(0.1, 0.1), color: 1, width: 0.004);
      board.endStroke();
      expect(board.addPage(), isTrue);
      final page2 = board.currentPage;
      expect(sent.all.whereType<WhiteboardPageAdd>().single.id, page2);
      board.beginStroke(const Offset(0.5, 0.5), color: 1, width: 0.004);
      board.endStroke();
      expect(
        sent.all.whereType<WhiteboardBegin>().last.page,
        page2,
        reason: '보던 쪽에 그린다',
      );
      expect(board.currentStrokes, hasLength(1));
      expect(board.book.strokesOf(page2), hasLength(1));
      expect(board.canUndo, isTrue);

      // 서버에 저장했다 — 모두에게 판 id를 알린다(누가 다시 저장해도 같은 판을 고친다).
      board.markSaved('wb1', '판');
      expect(sent.all.last, isA<WhiteboardBoardInfo>());
      expect(board.savedBoardId, 'wb1');
      board.showPage(whiteboardFirstPage);
      expect(board.currentPageIndex, 0);
      board.showPage(page2);
      board.removeCurrentPage();
      expect(board.currentPage, whiteboardFirstPage);
      expect(sent.all.last, isA<WhiteboardPageRemove>());
      expect(board.canRemovePage, isFalse);

      // 다른 사람이 내가 보던 쪽을 빼면 앞 쪽으로.
      board.receive('u2', const WhiteboardPageAdd('u2-p'));
      board.showPage('u2-p');
      board.receive('u2', const WhiteboardPageRemove('u2-p'));
      expect(board.currentPage, whiteboardFirstPage);
    });

    test('저장한 판 불러오기 — 모두에게 비우기·판 정보·판 전체를 보내고, 불러온 그대로는 저장한 것', () async {
      final sent = _Sent();
      final board = CallWhiteboard(myId: 'me', send: sent.send);
      addTearDown(board.dispose);
      board.beginStroke(const Offset(0.9, 0.9), color: 1, width: 0.004);
      board.endStroke();
      final saved =
          (WhiteboardBook()
                ..apply(
                  'u1',
                  const WhiteboardBegin(
                    id: 'old',
                    color: 3,
                    width: 0.004,
                    points: [Offset(0.4, 0.4), Offset(0.5, 0.5)],
                  ),
                )
                ..apply('u1', const WhiteboardPageAdd('u1-p2')))
              .toSavedJson();
      sent.messages.clear();
      await board.loadSaved(id: 'wb9', title: '지난 회의', data: saved);
      expect(sent.all.first, isA<WhiteboardReset>());
      expect((sent.all[1] as WhiteboardBoardInfo).id, 'wb9');
      expect(sent.all.whereType<WhiteboardPageAdd>().single.id, 'u1-p2');
      expect(sent.all.whereType<WhiteboardBegin>().single.id, 'old');
      expect([for (final s in board.book.strokes) s.id], ['old']);
      expect(board.hasUnsavedChanges, isFalse);
      expect(board.savedBoardTitle, '지난 회의');
      // 쪽만 넘기는 것은 저장할 변화가 아니다.
      board.showPage('u1-p2');
      board.showPage(whiteboardFirstPage);
      expect(board.hasUnsavedChanges, isFalse);
      board.beginStroke(const Offset(0.2, 0.2), color: 1, width: 0.004);
      board.endStroke();
      expect(board.hasUnsavedChanges, isTrue);

      // 다른 사람이 받으면 같은 판이 되고(그 사람이 그리던 것은 비워진다) 그 판의 id를 안다.
      final other = CallWhiteboard(myId: 'u2', send: _Sent().send);
      addTearDown(other.dispose);
      other.beginStroke(const Offset(0.1, 0.1), color: 1, width: 0.004);
      other.endStroke();
      for (final m in sent.all) {
        other.receive('me', _roundTrip(m));
      }
      expect(other.book.strokes.first.id, 'old');
      expect(other.book.strokes, hasLength(2), reason: '불러온 것 + 불러온 뒤 내가 그린 것');
      expect(other.savedBoardId, 'wb9');
      expect(other.book.pageIds, [whiteboardFirstPage, 'u1-p2']);
    });

    test('쪽이 여럿이면 그림도 여러 장 — 한 메시지에 "(2쪽)"을 붙인 이름으로', () async {
      final tmp = Directory.systemTemp.createTempSync('wb_pages_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      outboxFilesBaseDir = () async => tmp;
      final session = _session(
        (_) async => throw http.ClientException('연결 안 됨'),
      );
      final png = Uint8List.fromList([137, 80, 78, 71]);
      await session.postWhiteboardImages('r1', [
        png,
        png,
      ], now: DateTime(2026, 10, 22, 9, 5));
      final item = session.outbox.items.single;
      expect(item.files.map((f) => f.name), [
        '화이트보드 2026-10-22 09.05 (1쪽).png',
        '화이트보드 2026-10-22 09.05 (2쪽).png',
      ]);
      expect(item.preview, '사진 2장 · 화상회의 화이트보드');
      for (
        var i = 0;
        i < 200 &&
            session.outbox.items.any((it) => it.state == OutboxState.sending);
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
  });

  group('실시간 자막', () {
    test('call:state의 자막과 call:caption을 읽는다', () {
      expect(
        CallCaptionsLive.fromJson({'byId': 'u1', 'byName': 'A'})!.byId,
        'u1',
      );
      expect(CallCaptionsLive.fromJson({'nope': 1}), isNull);
      final c = CallCaption.fromJson({
        'roomId': 'r1',
        'userId': 'u2',
        'name': '박지영',
        'text': '안녕하세요',
        'at': 1000,
      })!;
      expect(
        (c.name, c.text, c.at.millisecondsSinceEpoch),
        ('박지영', '안녕하세요', 1000),
      );
      expect(CallCaption.fromJson({'roomId': 'r1'}), isNull);
    });

    test('최근 세 줄만, 자막을 끄면 비운다', () {
      final session = _session((_) async => _json({}));
      final controller = session.callController;
      controller.applyServerCallState(
        hostId: 'me',
        captions: CallCaptionsLive(
          byId: 'me',
          byName: '나',
          startedAt: DateTime(2026),
        ),
      );
      final now = DateTime.now();
      for (var i = 0; i < 5; i++) {
        controller.addCaption(
          CallCaption(
            roomId: 'r1',
            userId: 'u',
            name: '김민수',
            text: '말 $i',
            at: now,
          ),
          now: now,
        );
      }
      expect(controller.recentCaptions.map((c) => c.text), [
        '말 2',
        '말 3',
        '말 4',
      ]);
      controller.setShowCaptions(false);
      expect(controller.showCaptions, isFalse);
      controller.applyServerCallState(hostId: 'me');
      expect(controller.captions, isNull);
      expect(controller.recentCaptions, isEmpty);
    });

    testWidgets('자막 칸 — 이름과 말', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CallCaptionsOverlay(
              lines: [
                CallCaption(
                  roomId: 'r1',
                  userId: 'u2',
                  name: '박지영',
                  text: '자료 공유할게요',
                  at: DateTime(2026),
                ),
              ],
            ),
          ),
        ),
      );
      expect(find.textContaining('박지영'), findsOne);
      expect(find.textContaining('자료 공유할게요'), findsOne);
    });
  });
}
