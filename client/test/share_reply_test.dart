// 공유·위젯 후속(앱 쪽) — 공유 화면에서 여러 방(비밀 대화 포함)에 한꺼번에 보내기와 못 보낸 방 남기기, Windows 탐색기 "보내기"(시작 인자·
// 떠 있는 창에 넘어온 링크), 알림에서 바로 답장(요청 모양·표가 거절되면 토큰으로 다시), 위젯을 앱이 앞으로 올 때 다시 넘기기.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:client/models/room.dart';
import 'package:client/models/team.dart';
import 'package:client/screens/share_target_screen.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/home_widget_bridge.dart';
import 'package:client/services/notification_reply.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:client/services/share_intake.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _QuietNotifications extends NotificationService {
  @override
  Future<void> cancelForRoom(String roomId) async {}
}

Room _room(
  String id, {
  String? name,
  bool secret = false,
  String type = 'group',
}) => Room.fromJson({
  'id': id,
  'teamId': 't1',
  'type': type,
  'name': name,
  'members': [
    {'id': 'me', 'username': 'me', 'name': '나'},
    {'id': 'u2', 'username': 'kim', 'name': '김철수'},
  ],
  'createdAt': DateTime(2026, 1, 1).millisecondsSinceEpoch,
  'lastActivityAt': DateTime(2026, 10, 18, 10).millisecondsSinceEpoch,
  'isSecret': secret,
});

Session _session(MockClient client, List<Room> rooms) {
  final session = Session(
    notifications: _QuietNotifications(),
    settings: AppSettings(),
  );
  session.api = ApiClient(
    baseUrl: 'https://test.local',
    token: 't',
    httpClient: client,
  );
  session.userId = 'me';
  session.accountRole = AccountRole.member;
  final team = Team(id: 't1', name: '영업팀', createdAt: DateTime(2026));
  session.teams.add(team);
  session.currentTeam = team;
  session.rooms.addAll(rooms);
  return session;
}

http.Response _json(Object body, {int status = 200}) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: const {'content-type': 'application/json'},
);

Future<void> _open(
  WidgetTester tester,
  Session session,
  SharedPayload payload,
  void Function(List<Room>?) onResult,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => onResult(
            await showShareTargetScreen(
              context,
              session: session,
              payload: payload,
            ),
          ),
          child: const Text('열기'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('열기'));
  await tester.pumpAndSettle();
}

Future<void> _pick(WidgetTester tester, String tab, String name) async {
  await tester.tap(find.byType(InkWell).first);
  await tester.pumpAndSettle();
  await tester.tap(find.text(tab).last);
  await tester.pumpAndSettle();
  await tester.tap(find.text(name).last);
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('공유 화면 — 여러 방', () {
    testWidgets('여러 방과 비밀 대화를 골라 한꺼번에 보내고, 같은 방을 다시 누르면 뺀다', (tester) async {
      final session = _session(MockClient((_) async => _json([])), [
        _room('g1', name: '영업 1팀'),
        _room('g2', name: '영업 2팀'),
        _room('s1', secret: true, type: 'dm'),
      ]);
      List<Room>? result;
      await _open(
        tester,
        session,
        const SharedPayload(text: '공유할 글'),
        (r) => result = r,
      );
      await _pick(tester, '그룹채팅', '영업 1팀');
      await _pick(tester, '그룹채팅', '영업 2팀');
      // 비밀 대화도 목록에 있다(자물쇠).
      await _pick(tester, '채팅', '김철수');
      expect(find.byKey(const ValueKey('share-room-s1')), findsOneWidget);
      expect(find.text('3곳에 보내기'), findsOneWidget);
      // 고른 방을 다시 누르면 뺀다.
      await _pick(tester, '그룹채팅', '영업 2팀');
      expect(find.byKey(const ValueKey('share-room-g2')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('share-send')));
      await tester.pumpAndSettle();
      expect(result?.map((r) => r.id), ['g1', 's1']);
      expect(session.outbox.forRoom('g1').single.payload['text'], '공유할 글');
      expect(session.outbox.forRoom('s1').single.payload['text'], '공유할 글');
    });

    testWidgets('파일을 올리지 못하면 닫지 않고 못 보낸 방과 이유를 남긴다(복사본도 지우지 않음)', (
      tester,
    ) async {
      final dir = Directory.systemTemp.createTempSync('share_fail');
      final file = File('${dir.path}${Platform.pathSeparator}a.txt')
        ..writeAsStringSync('hello');
      final session = _session(
        MockClient(
          (req) async => req.url.path.contains('upload')
              ? _json({'error': '저장 공간이 부족합니다.'}, status: 507)
              : _json([]),
        ),
        [_room('g1', name: '영업 1팀')],
      );
      var closed = false;
      await tester.runAsync(() async {
        await _open(
          tester,
          session,
          SharedPayload(
            files: [
              SharedFile(
                path: file.path,
                name: 'a.txt',
                size: 5,
                temporary: true,
              ),
            ],
          ),
          (_) => closed = true,
        );
        await _pick(tester, '그룹채팅', '영업 1팀');
        await tester.tap(find.byKey(const ValueKey('share-send')));
        for (
          var i = 0;
          i < 20 &&
              find.byKey(const ValueKey('share-error')).evaluate().isEmpty;
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          await tester.pump();
        }
      });
      expect(closed, isFalse);
      expect(find.byKey(const ValueKey('share-error')), findsOneWidget);
      expect(find.textContaining('영업 1팀: '), findsOneWidget);
      expect(find.byKey(const ValueKey('share-room-g1')), findsOneWidget);
      expect(file.existsSync(), isTrue);
      dir.deleteSync(recursive: true);
    });
  });

  group('Windows "보내기"', () {
    test('시작 인자 — --share 뒤의 파일만(폴더·없는 파일 빼고), 원본이라 지우지 않는 파일', () {
      final dir = Directory.systemTemp.createTempSync('sendto');
      final sep = Platform.pathSeparator;
      final pic = File('${dir.path}$sep사진.png')..writeAsBytesSync([1, 2, 3]);
      final doc = File('${dir.path}${sep}b.pdf')..writeAsBytesSync([1]);
      final p = sharedPayloadFromArgs([
        '--share',
        pic.path,
        dir.path,
        '${dir.path}$sep없음.txt',
        doc.path,
      ])!;
      expect(p.files.map((f) => f.name), ['사진.png', 'b.pdf']);
      expect(p.files.first.size, 3);
      expect(p.files.first.isImage, isTrue);
      expect(p.files.last.isImage, isFalse);
      expect(p.files.every((f) => !f.temporary), isTrue);
      expect(sharedPayloadFromArgs([pic.path]), isNull);
      expect(sharedPayloadFromArgs(['--share']), isNull);
      expect(sharedPayloadFromArgs([]), isNull);
      // 20개까지.
      expect(
        sharedPayloadFromArgs([
          '--share',
          for (var i = 0; i < 25; i++) pic.path,
        ])!.files.length,
        sharedFilesMax,
      );
      dir.deleteSync(recursive: true);
    });

    test('떠 있는 창 — tangotalk://share 링크로 넘어온 파일, 시작 인자와 함께 받는다', () async {
      final dir = Directory.systemTemp.createTempSync('sendto_link');
      final f = File('${dir.path}${Platform.pathSeparator}보고서 1.docx')
        ..writeAsBytesSync([1, 2]);
      final link = Uri(
        scheme: 'tangotalk',
        host: 'share',
        queryParameters: {
          'file': [f.path],
        },
      );
      expect(sharedPayloadFromLink(link)!.files.single.name, '보고서 1.docx');
      expect(
        sharedPayloadFromLink(Uri.parse('tangotalk://pair?address=a&code=1')),
        isNull,
      );
      final links = StreamController<Uri>();
      final got = <SharedPayload>[];
      final intake = ShareIntake(
        enabled: false,
        windows: true,
        args: ['--share', f.path],
        links: links.stream,
      );
      await intake.start(onShare: got.add, onOpenRoom: (_) {});
      expect(got.single.files.single.path, f.path);
      links.add(link);
      links.add(Uri.parse('tangotalk://pair?address=a&code=1'));
      await Future<void>.delayed(Duration.zero);
      expect(got.length, 2);
      intake.dispose();
      await links.close();
      dir.deleteSync(recursive: true);
    });
  });

  group('알림에서 바로 답장', () {
    test('요청 — 표가 있으면 표로(토큰 없이), 없으면 토큰과 방, 둘 다 없으면 null', () {
      final byTicket = pushReplyRequest(
        roomId: 'R1',
        text: '네',
        clientId: 'cid12345',
        ticket: 'v1.a.b',
        token: 'tok',
      )!;
      expect(byTicket.body, {
        'ticket': 'v1.a.b',
        'text': '네',
        'clientId': 'cid12345',
      });
      expect(byTicket.headers.containsKey('Authorization'), isFalse);
      final byToken = pushReplyRequest(
        roomId: 'R1',
        text: '네',
        clientId: 'cid12345',
        token: 'tok',
      )!;
      expect(byToken.body, {
        'roomId': 'R1',
        'text': '네',
        'clientId': 'cid12345',
      });
      expect(byToken.headers['Authorization'], 'Bearer tok');
      expect(pushReplyRequest(roomId: 'R1', text: '네', clientId: 'c'), isNull);
    });

    test(
      '표가 거절되면(401) 같은 임시 id로 토큰으로 한 번 더, 서버 오류는 그 글로, 연결 실패도 알린다',
      () async {
        final calls = <Map<String, dynamic>>[];
        Future<({int status, String body})> post(
          Uri uri,
          Map<String, String> headers,
          String body,
        ) async {
          expect(uri.toString(), 'https://s.local/api/push-reply');
          final m = jsonDecode(body) as Map<String, dynamic>;
          calls.add({...m, 'auth': headers['Authorization']});
          if (m['ticket'] != null) {
            return (status: 401, body: jsonEncode({'error': '기한 지남'}));
          }
          return (status: 201, body: jsonEncode({'id': 'M1'}));
        }

        final ok = await sendPushReply(
          serverUrl: 'https://s.local',
          roomId: 'R1',
          text: '확인했습니다',
          ticket: 'v1.a.b',
          token: 'tok',
          post: post,
        );
        expect(ok.error, isNull);
        expect(calls.length, 2);
        expect(calls[1]['auth'], 'Bearer tok');
        expect(calls[1]['roomId'], 'R1');
        expect(calls[0]['clientId'], calls[1]['clientId']);

        final denied = await sendPushReply(
          serverUrl: 'https://s.local',
          roomId: 'R1',
          text: '네',
          token: 'tok',
          post: (_, _, _) async =>
              (status: 400, body: jsonEncode({'error': '읽기 전용 토픽입니다.'})),
        );
        expect(denied.error, '읽기 전용 토픽입니다.');
        final offline = await sendPushReply(
          serverUrl: 'https://s.local',
          roomId: 'R1',
          text: '네',
          ticket: 'v1.a.b',
          post: (_, _, _) async => throw const SocketException('없음'),
        );
        expect(offline.status, 0);
        expect(offline.error, isNotNull);
        final noAuth = await sendPushReply(
          serverUrl: 'https://s.local',
          roomId: 'R1',
          text: '네',
          post: post,
        );
        expect(noAuth.status, 401);
      },
    );
  });

  test('위젯 — 앱이 앞으로 오면 같은 내용이어도 한 번 다시 넘긴다(꺼진 동안 안드로이드가 올린 숫자를 덮게)', () async {
    const channel = MethodChannel('test/widget-resume');
    var pushed = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          pushed++;
          return null;
        });
    final session = Session(
      notifications: _QuietNotifications(),
      settings: AppSettings(),
    );
    final bridge = HomeWidgetBridge(session, channel: channel, enabled: true);
    await bridge.push();
    await bridge.push();
    expect(pushed, 1);
    bridge.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await bridge.push();
    expect(pushed, 2);
    bridge.stop();
  });
}
