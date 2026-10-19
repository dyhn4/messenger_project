// 통화 녹화·회의록 — 녹화 상태(call:state)·카드의 녹화 목록·회의록 화면, 화이트보드를 그림으로 저장(대기열로 대화방에).
import 'dart:convert';
import 'dart:io';

import 'package:client/models/call_card.dart';
import 'package:client/models/call_recording.dart';
import 'package:client/models/message.dart';
import 'package:client/models/room.dart';
import 'package:client/screens/call/call_recording_widgets.dart';
import 'package:client/screens/call/call_whiteboard_view.dart';
import 'package:client/screens/call_minutes_screen.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/call_controller.dart';
import 'package:client/services/call_whiteboard.dart';
import 'package:client/services/chat_socket.dart' show CallState;
import 'package:client/services/message_outbox.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/outbox_files_io.dart' show outboxFilesBaseDir;
import 'package:client/services/session.dart';
import 'package:client/widgets/call_message_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

class _QuietNotifications extends NotificationService {
  @override
  Future<void> cancelForRoom(String roomId) async {}
}

const _serverUrl = 'https://192.168.0.10:3000';

Room _room({String id = 'r1', String viewMode = 'chat'}) => Room.fromJson({
  'id': id,
  'teamId': 't1',
  'type': 'topic',
  'name': '개발팀',
  'viewMode': viewMode,
  'members': [],
  'createdAt': 1000,
});

Session _session(Future<http.Response> Function(http.Request) handler) {
  final s = Session(
    notifications: _QuietNotifications(),
    settings: AppSettings(),
  );
  s.serverUrl = _serverUrl;
  s.userId = 'me';
  s.callsEnabled = true;
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

final _t0 = DateTime(2026, 10, 19, 14, 5);

Map<String, dynamic> _recordingJson({
  String minutesStatus = 'done',
  String? summary = '## 요약\n견적 회의.\n## 할 일\n- 홍길동: 견적 보내기',
  String? transcript = '[00:00] 시작합니다.',
  bool canRetry = false,
  String? minutesError,
}) => {
  'id': 'rec1',
  'roomId': 'r1',
  'callMessageId': 'm1',
  'startedBy': 'me',
  'startedByName': '홍길동',
  'startedAt': _t0.millisecondsSinceEpoch,
  'endedAt': _t0.add(const Duration(minutes: 12)).millisecondsSinceEpoch,
  'durationMs': 12 * 60000,
  'audioOnly': false,
  'status': 'done',
  'error': null,
  'messageId': 'file1',
  'minutesStatus': minutesStatus,
  'minutesError': minutesError,
  'participantNames': ['홍길동', '김철수'],
  'transcript': transcript,
  'summary': summary,
  'canRetry': canRetry,
};

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('모델', () {
    test('call:state의 녹화 — 없으면 null', () {
      final state = CallState.fromJson({
        'roomId': 'r1',
        'active': true,
        'participantIds': ['me'],
        'recording': {
          'id': 'rec1',
          'byId': 'me',
          'byName': '홍길동',
          'startedAt': _t0.millisecondsSinceEpoch,
          'audioOnly': true,
          'minutes': true,
        },
      });
      expect(state.recording!.id, 'rec1');
      expect(state.recording!.byName, '홍길동');
      expect(state.recording!.startedAt, _t0);
      expect(state.recording!.audioOnly, isTrue);
      expect(state.recording!.minutes, isTrue);
      expect(
        CallState.fromJson({'roomId': 'r1', 'active': true}).recording,
        isNull,
      );
    });

    test('화상회의 카드의 녹화 목록·녹화 한 건', () {
      final card = CallCard.fromJson({
        'status': 'ended',
        'startedAt': _t0.millisecondsSinceEpoch,
        'events': [],
        'recordings': [
          {
            'id': 'rec1',
            'at': _t0.millisecondsSinceEpoch,
            'userId': 'me',
            'name': '홍길동',
            'audioOnly': false,
            'status': 'done',
            'minutes': 'summarizing',
            'messageId': 'f1',
          },
          {'id': 'rec2', 'status': 'weird', 'minutes': 'none'},
          'garbage',
        ],
      })!;
      expect(card.recordings, hasLength(2));
      expect(card.recordings.first.status, CallRecordingStatus.done);
      expect(card.recordings.first.minutes, CallMinutesStage.summarizing);
      expect(card.recordings.first.messageId, 'f1');
      expect(card.recordings.last.status, CallRecordingStatus.failed);
      expect(callMinutesInProgress(CallMinutesStage.summarizing), isTrue);
      expect(callMinutesInProgress(CallMinutesStage.done), isFalse);
      // 예전 서버의 카드 — 녹화 목록 없음.
      expect(
        CallCard.fromJson({'status': 'active', 'startedAt': 1})!.recordings,
        isEmpty,
      );

      final rec = CallRecording.fromJson(_recordingJson());
      expect(rec.duration, const Duration(minutes: 12));
      expect(rec.participantNames, ['홍길동', '김철수']);
      expect(rec.minutesStatus, CallMinutesStage.done);
    });

    test('회의록 마크다운 — 회의 정보, 요약, 받아쓰기', () {
      final md = callMinutesMarkdown(
        CallRecording.fromJson(_recordingJson()),
        roomName: '개발팀',
      );
      expect(md, startsWith('# 회의록 — 개발팀 2026-10-19 14:05\n'));
      expect(md, contains('- 일시: 2026-10-19 14:05 (12분)'));
      expect(md, contains('- 참석자: 홍길동, 김철수'));
      expect(md, contains('- 녹화: 홍길동'));
      expect(md, contains('## 할 일\n- 홍길동: 견적 보내기'));
      expect(md, endsWith('## 받아쓰기\n\n[00:00] 시작합니다.\n'));
      final noSummary = callMinutesMarkdown(
        CallRecording.fromJson(_recordingJson(summary: null)),
        roomName: '개발팀',
      );
      expect(noSummary, isNot(contains('## 요약')));
      expect(noSummary, contains('## 받아쓰기'));
    });

    test('대기열 — 게시글은 첨부가 하나여도 첨부 목록 그대로', () {
      final post = {
        'type': 'post',
        'title': '화이트보드',
        'attachments': [
          {'kind': 'image', 'fileUrl': '/uploads/a.png'},
        ],
      };
      expect(sendableOutboxPayload(post), same(post));
    });
  });

  group('진행자·녹화 알림(CallController)', () {
    test('들어왔을 때 이미 녹화 중이면 그렇게, 그 뒤로는 누가 시작·멈춤', () async {
      final controller = CallController(
        () => ApiClient(baseUrl: _serverUrl, token: 't'),
      );
      final notices = <String>[];
      final sub = controller.notices.listen(notices.add);
      CallRecordingLive rec(String id, {bool audio = false}) =>
          CallRecordingLive(
            id: id,
            byId: 'h',
            byName: '홍길동',
            startedAt: _t0,
            audioOnly: audio,
          );
      controller.applyServerCallState(hostId: 'h', recording: rec('a'));
      controller.applyServerCallState(hostId: 'h', recording: rec('a'));
      controller.applyServerCallState(hostId: 'h');
      controller.applyServerCallState(
        hostId: 'h',
        recording: rec('b', audio: true),
      );
      controller.applyServerCallState(hostId: 'h', recording: rec('c'));
      await Future<void>.delayed(Duration.zero);
      expect(notices, [
        '이 화상회의는 녹화되고 있습니다',
        '녹화를 멈췄습니다',
        '홍길동님이 녹음을 시작했습니다',
        '홍길동님이 녹화를 시작했습니다',
      ]);
      expect(controller.recording!.id, 'c');
      // LiveKit에 붙지 않았으니 내가 누군지 몰라 멈출 수 없다.
      expect(controller.canStopRecording, isFalse);
      await sub.cancel();
    });
  });

  group('화이트보드 저장', () {
    test('판이 바뀌면 저장하지 않은 그림이 있다고 알고, 그리면 1920×1080 PNG', () async {
      final board = CallWhiteboard(myId: 'me', send: (_, {to}) async {});
      addTearDown(board.dispose);
      expect(board.hasUnsavedChanges, isFalse, reason: '빈 판');
      board.beginStroke(const Offset(0.1, 0.5), color: 0xFFE53935, width: 0.01);
      board.extendStroke(const Offset(0.9, 0.5));
      board.endStroke();
      expect(board.hasUnsavedChanges, isTrue);
      final png = await board.renderPng();
      expect(board.hasUnsavedChanges, isFalse, reason: '저장했다');
      final image = img.decodePng(png)!;
      expect(image.width, 1920);
      expect(image.height, 1080);
      final mid = image.getPixel(960, 540);
      expect((mid.r, mid.g, mid.b), (0xE5, 0x39, 0x35), reason: '빨간 획');
      final corner = image.getPixel(5, 5);
      expect((corner.r, corner.g, corner.b), (255, 255, 255), reason: '흰 바탕');
      // 다른 사람이 그려도 다시 "저장 안 함".
      board.receive(
        'other',
        const WhiteboardBegin(
          id: 'x',
          color: 0xFF000000,
          width: 0.004,
          points: [Offset(0.2, 0.2)],
        ),
      );
      expect(board.hasUnsavedChanges, isTrue);
    });

    test('그림을 대기열에 넣어 대화방에 — 보드 뷰 토픽은 게시글로', () async {
      final tmp = Directory.systemTemp.createTempSync('wb_outbox_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      outboxFilesBaseDir = () async => tmp;
      // 서버에 닿지 않아 대기열에 남는다.
      final session = _session(
        (_) async => throw http.ClientException('연결 안 됨'),
      );
      session.rooms.addAll([_room(), _room(id: 'b1', viewMode: 'board')]);
      final png = Uint8List.fromList([137, 80, 78, 71]);
      await session.postWhiteboardImage('r1', png, now: _t0);
      await session.postWhiteboardImage('b1', png, auto: true, now: _t0);
      final items = session.outbox.items;
      expect(items, hasLength(2));
      final chat = items.first;
      expect(chat.roomId, 'r1');
      expect(chat.payload['type'], 'image');
      expect(chat.payload['text'], '화상회의 화이트보드');
      expect(chat.files.single.name, '화이트보드 2026-10-19 14.05.png');
      expect(chat.files.single.isImage, isTrue);
      expect(File(chat.files.single.path).readAsBytesSync(), [137, 80, 78, 71]);
      final post = items.last;
      expect(post.payload['type'], 'post');
      expect(post.payload['title'], '화상회의 화이트보드(통화가 끝나 저절로 저장)');
    });

    testWidgets('도구 줄의 [저장] — 판이 비면 못 누르고, 누르면 부른다', (tester) async {
      final board = CallWhiteboard(myId: 'me', send: (_, {to}) async {});
      addTearDown(board.dispose);
      var saved = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CallWhiteboardView(
              board: board,
              onClose: () {},
              onSave: () async => saved++,
            ),
          ),
        ),
      );
      final save = find.byKey(const ValueKey('whiteboard-save'));
      expect(tester.widget<IconButton>(save).onPressed, isNull);
      board.beginStroke(
        const Offset(0.5, 0.5),
        color: 0xFF000000,
        width: 0.004,
      );
      board.endStroke();
      await tester.pump();
      await tester.tap(save);
      await tester.pump();
      expect(saved, 1);
    });
  });

  group('통화 화면 조각', () {
    testWidgets('녹화 중 표시 — 지난 시간이 흐르고, 멈출 수 있으면 누른다', (tester) async {
      var stopped = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CallRecordingPill(
              recording: CallRecordingLive(
                id: 'r',
                byId: 'h',
                byName: '홍길동',
                startedAt: DateTime.now().subtract(
                  const Duration(minutes: 1, seconds: 5),
                ),
                minutes: true,
              ),
              onStop: () => stopped++,
            ),
          ),
        ),
      );
      expect(find.textContaining('녹화 중 01:0'), findsOneWidget);
      expect(find.byIcon(Icons.description_outlined), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('call-recording-pill')));
      expect(stopped, 1);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('녹화 시작 창 — 소리만·회의록을 고른다(받아쓰기가 없으면 회의록 칸이 없다)', (tester) async {
      CallRecordingChoice? choice;
      Future<void> open({required bool minutes}) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () async =>
                    choice = await showCallRecordingStartDialog(
                      context,
                      minutesAvailable: minutes,
                      summaryAvailable: true,
                    ),
                child: const Text('열기'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('열기'));
        await tester.pumpAndSettle();
      }

      await open(minutes: true);
      expect(find.text('끝나면 회의록 만들기'), findsOneWidget);
      expect(find.text('녹음을 받아쓰고 요약합니다(결정 사항·할 일)'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('call-record-audio')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('call-record-start')));
      await tester.pumpAndSettle();
      expect(choice, (audioOnly: true, minutes: true));

      await open(minutes: false);
      expect(find.text('끝나면 회의록 만들기'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('call-record-start')));
      await tester.pumpAndSettle();
      expect(choice, (audioOnly: false, minutes: false));
    });
  });

  group('카드·회의록 화면', () {
    Message cardMessage(List<Map<String, dynamic>> recordings) =>
        Message.fromJson({
          'id': 'm1',
          'roomId': 'r1',
          'senderId': null,
          'senderName': '시스템',
          'type': 'system',
          'text': '화상회의',
          'createdAt': _t0.millisecondsSinceEpoch,
          'callCard': {
            'status': 'ended',
            'startedAt': _t0.millisecondsSinceEpoch,
            'endedAt': _t0
                .add(const Duration(minutes: 30))
                .millisecondsSinceEpoch,
            'durationMs': 30 * 60000,
            'answered': true,
            'events': [
              {
                'at': _t0.millisecondsSinceEpoch,
                'userId': 'me',
                'name': '홍길동',
                'kind': 'start',
              },
            ],
            'recordings': recordings,
          },
        });

    testWidgets('카드에 녹화 줄과 회의록 단계, [회의록]을 누르면 요약·받아쓰기', (tester) async {
      final requests = <http.Request>[];
      final session = _session((request) async {
        requests.add(request);
        if (request.url.path == '/api/call-recordings/rec1') {
          return _json({'recording': _recordingJson()});
        }
        if (request.url.path == '/api/wiki') {
          return _json({
            'id': 'p1',
            'parentId': null,
            'title': 'x',
            'depth': 0,
          }, 201);
        }
        return _json({});
      });
      final room = _room();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CallMessageCard(
              session: session,
              room: room,
              message: cardMessage([
                {
                  'id': 'rec1',
                  'at': _t0.millisecondsSinceEpoch,
                  'userId': 'me',
                  'name': '홍길동',
                  'status': 'done',
                  'minutes': 'done',
                },
                {
                  'id': 'rec2',
                  'at': _t0.millisecondsSinceEpoch,
                  'name': '김철수',
                  'audioOnly': true,
                  'status': 'processing',
                  'minutes': 'transcribing',
                },
                {
                  'id': 'rec3',
                  'at': _t0.millisecondsSinceEpoch,
                  'name': '김철수',
                  'status': 'failed',
                  'minutes': 'none',
                },
              ]),
            ),
          ),
        ),
      );
      expect(find.textContaining('녹화 · 홍길동'), findsOneWidget);
      expect(
        find.textContaining(RegExp(r'^녹음 · 김철수 · .+ · 파일 마무리 중$')),
        findsOneWidget,
      );
      expect(find.textContaining('· 실패'), findsOneWidget);
      expect(find.text('받아쓰는 중'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('call-card-minutes-rec3')),
        findsNothing,
      );

      await tester.tap(find.byKey(const ValueKey('call-card-minutes-rec1')));
      await tester.pumpAndSettle();
      expect(find.text('견적 회의.'), findsOneWidget);
      expect(find.text('참석자: 홍길동, 김철수'), findsOneWidget);
      // 요약이 있으면 받아쓰기는 접혀 있다.
      expect(find.text('[00:00] 시작합니다.'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('minutes-transcript-toggle')));
      await tester.pump();
      expect(find.text('[00:00] 시작합니다.'), findsOneWidget);

      // 복사 — 마크다운 전체.
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      await tester.tap(find.byKey(const ValueKey('minutes-copy')));
      await tester.pump();
      expect(copied, startsWith('# 회의록 — 개발팀 2026-10-19 14:05'));

      // 팀 위키에 새 페이지로.
      await tester.tap(find.byKey(const ValueKey('minutes-wiki')));
      await tester.pumpAndSettle();
      final wiki = requests.lastWhere((r) => r.url.path == '/api/wiki');
      final body = jsonDecode(wiki.body) as Map<String, dynamic>;
      expect(body['teamId'], 't1');
      expect(body['title'], '회의록 개발팀 2026-10-19 14:05');
      expect(body['body'], contains('## 받아쓰기'));
      expect(find.text('팀 위키에 새 페이지로 저장했습니다'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('못 만든 회의록 — 이유와 [다시 만들기], 만드는 동안 다시 읽는다', (tester) async {
      var stage = 'failed';
      var gets = 0;
      final session = _session((request) async {
        if (request.method == 'POST' &&
            request.url.path == '/api/call-recordings/rec1/minutes/retry') {
          stage = 'transcribing';
          return _json({
            'recording': _recordingJson(
              minutesStatus: stage,
              summary: null,
              transcript: null,
            ),
          });
        }
        if (request.url.path == '/api/call-recordings/rec1') {
          gets++;
          return _json({
            'recording': stage == 'failed'
                ? _recordingJson(
                    minutesStatus: 'failed',
                    summary: null,
                    transcript: null,
                    canRetry: true,
                    minutesError: '받아쓰기 서비스가 500로 거절했습니다',
                  )
                : _recordingJson(),
          });
        }
        return _json({});
      });
      await tester.pumpWidget(
        MaterialApp(
          home: CallMinutesScreen(
            session: session,
            room: _room(),
            recordingId: 'rec1',
            pollInterval: const Duration(seconds: 1),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('받아쓰기 서비스가 500로 거절했습니다'), findsOneWidget);
      expect(find.byKey(const ValueKey('minutes-copy')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('minutes-retry')));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('받아쓰는 중… 끝나면 여기에 나옵니다.'), findsOneWidget);
      stage = 'done';
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      await tester.pump();
      expect(gets, 2);
      expect(find.text('견적 회의.'), findsOneWidget);
      expect(find.byKey(const ValueKey('minutes-copy')), findsOneWidget);
    });
  });
}
