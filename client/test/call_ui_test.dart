import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:client/screens/call/call_control_bar.dart';
import 'package:client/screens/call/call_logic.dart';
import 'package:client/screens/call/call_participants_panel.dart';
import 'package:client/screens/call/call_snapshot.dart';
import 'package:client/screens/call/call_stage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

CallPerson _p(
  String id, {
  bool me = false,
  bool mic = true,
  bool cam = true,
  bool speaking = false,
  bool sharing = false,
  DateTime? hand,
}) => CallPerson(
  id: id,
  name: '이름$id',
  isMe: me,
  micOn: mic,
  camOn: cam,
  speaking: speaking,
  sharing: sharing,
  handRaisedAt: hand,
);

CallTileData _t(CallPerson p, {bool share = false}) =>
    CallTileData(p, isScreenShare: share);

void _size(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Widget _app(Widget child) => MaterialApp(
  theme: ThemeData.dark(),
  home: Scaffold(backgroundColor: callStageColor, body: child),
);

CallControlBar _bar({
  bool micOn = true,
  bool camOn = true,
  bool sharing = false,
  bool handRaised = false,
  CallViewMode viewMode = CallViewMode.gallery,
  CallPanel panel = CallPanel.none,
  int participants = 3,
  int unread = 0,
  List<String>? log,
}) {
  void l(String s) => log?.add(s);
  return CallControlBar(
    micOn: micOn,
    camOn: camOn,
    sharing: sharing,
    handRaised: handRaised,
    viewMode: viewMode,
    panel: panel,
    participantCount: participants,
    chatUnread: unread,
    onToggleMic: () => l('mic'),
    onToggleCamera: () => l('camera'),
    onToggleShare: () => l('share'),
    onToggleParticipants: () => l('participants'),
    onToggleChat: () => l('chat'),
    onToggleHand: () => l('hand'),
    onToggleWhiteboard: () => l('whiteboard'),
    onToggleView: () => l('view'),
    onLeave: () => l('leave'),
  );
}

void main() {
  group('컨트롤바', () {
    testWidgets('넓은 화면: 라벨·배지가 보이고 단추마다 동작한다', (tester) async {
      _size(tester, const Size(1100, 700));
      final log = <String>[];
      await tester.pumpWidget(
        _app(
          Align(
            alignment: Alignment.bottomCenter,
            child: _bar(log: log, unread: 4),
          ),
        ),
      );

      for (final label in [
        '음소거',
        '비디오 중지',
        '화면 공유',
        '참가자',
        '채팅',
        '손들기',
        '스피커 보기',
        '나가기',
      ]) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      expect(find.text('3'), findsOneWidget); // 참가자 수 배지
      expect(find.text('4'), findsOneWidget); // 안 읽은 채팅 배지

      for (final key in [
        'mic',
        'camera',
        'share',
        'participants',
        'chat',
        'hand',
        'view',
      ]) {
        final id = switch (key) {
          'camera' => 'call-camera',
          'view' => 'call-view',
          _ => 'call-$key',
        };
        await tester.tap(find.byKey(ValueKey(id)));
      }
      await tester.tap(find.byKey(const ValueKey('call-leave')));
      expect(log, [
        'mic',
        'camera',
        'share',
        'participants',
        'chat',
        'hand',
        'view',
        'leave',
      ]);
    });

    testWidgets('꺼짐/켜짐 상태가 아이콘·라벨로 드러난다', (tester) async {
      _size(tester, const Size(1100, 700));
      await tester.pumpWidget(_app(_bar(micOn: false, camOn: false)));
      expect(find.byIcon(Icons.mic_off), findsOneWidget);
      expect(find.byIcon(Icons.mic), findsNothing);
      expect(find.byIcon(Icons.videocam_off), findsOneWidget);
      expect(find.text('음소거 해제'), findsOneWidget);
      expect(find.text('비디오 시작'), findsOneWidget);

      await tester.pumpWidget(
        _app(
          _bar(sharing: true, handRaised: true, viewMode: CallViewMode.speaker),
        ),
      );
      expect(find.text('공유 중지'), findsOneWidget);
      expect(find.text('손 내리기'), findsOneWidget);
      expect(find.text('갤러리 보기'), findsOneWidget); // 스피커 보기 중에는 갤러리로 전환하는 단추
    });

    testWidgets('채팅 안읽음이 0이면 배지가 없다', (tester) async {
      _size(tester, const Size(1100, 700));
      await tester.pumpWidget(_app(_bar(participants: 1, unread: 0)));
      expect(find.text('0'), findsNothing);
      await tester.pumpWidget(_app(_bar(participants: 1, unread: 120)));
      expect(find.text('99+'), findsOneWidget);
    });

    testWidgets('마우스를 올리면 툴팁이 뜬다', (tester) async {
      _size(tester, const Size(1100, 700));
      await tester.pumpWidget(
        _app(Align(alignment: Alignment.bottomCenter, child: _bar())),
      );
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await gesture.moveTo(
        tester.getCenter(find.byKey(const ValueKey('call-hand'))),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('손들기'), findsNWidgets(2)); // 라벨 + 툴팁
    });

    testWidgets('폰 폭(360): 주요 단추 + 더보기 + 나가기가 겹치지 않고 화면 안에 다 들어간다', (
      tester,
    ) async {
      _size(tester, const Size(360, 640));
      final log = <String>[];
      await tester.pumpWidget(
        _app(
          Align(
            alignment: Alignment.bottomCenter,
            child: _bar(log: log, unread: 2),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('call-bar-scroll')), findsNothing);
      // 라벨 없이 단추만, 더보기로 옮긴 기능은 바에 없다.
      expect(find.text('손들기'), findsNothing);
      expect(find.byKey(const ValueKey('call-share')), findsNothing);

      final keys = [
        'call-mic',
        'call-camera',
        'call-participants',
        'call-chat',
        'call-more',
        'call-leave',
      ];
      Rect? prev;
      for (final k in keys) {
        final r = tester.getRect(find.byKey(ValueKey(k)));
        expect(r.left, greaterThanOrEqualTo(0), reason: k);
        expect(r.right, lessThanOrEqualTo(360), reason: k);
        // 배지(오른쪽 위로 4 튀어나옴)까지 이웃 단추와 겹치지 않을 만큼 띄운다.
        if (prev != null) {
          expect(r.left - prev.right, greaterThanOrEqualTo(8), reason: k);
        }
        prev = r;
      }

      for (final k in keys) {
        await tester.tap(find.byKey(ValueKey(k)));
        await tester.pumpAndSettle();
        if (k == 'call-more') {
          await tester.tapAt(const Offset(180, 20)); // 메뉴 바깥을 눌러 닫는다.
          await tester.pumpAndSettle();
        }
      }
      expect(log, ['mic', 'camera', 'participants', 'chat', 'leave']);
    });

    testWidgets('폰 폭(360): 더보기 메뉴에서 화면 공유·손들기·화이트보드·보기 전환', (
      tester,
    ) async {
      _size(tester, const Size(360, 640));
      final log = <String>[];
      await tester.pumpWidget(
        _app(Align(alignment: Alignment.bottomCenter, child: _bar(log: log))),
      );
      for (final (key, expected) in [
        ('call-share', 'share'),
        ('call-hand', 'hand'),
        ('call-whiteboard', 'whiteboard'),
        ('call-view', 'view'),
      ]) {
        await tester.tap(find.byKey(const ValueKey('call-more')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(find.byKey(ValueKey(key)));
        await tester.pumpAndSettle();
        // 누르면 메뉴는 닫힌다.
        expect(find.byKey(ValueKey(key)), findsNothing, reason: key);
        expect(log.last, expected);
      }
    });

    testWidgets('폰 폭(360): 더보기 안의 기능이 켜져 있으면 더보기에 점, 메뉴엔 현재 상태', (
      tester,
    ) async {
      _size(tester, const Size(360, 640));
      await tester.pumpWidget(
        _app(Align(alignment: Alignment.bottomCenter, child: _bar())),
      );
      expect(find.byKey(const ValueKey('call-bar-dot')), findsNothing);

      await tester.pumpWidget(
        _app(
          Align(
            alignment: Alignment.bottomCenter,
            child: _bar(sharing: true, handRaised: true),
          ),
        ),
      );
      expect(find.byKey(const ValueKey('call-bar-dot')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('call-more')));
      await tester.pumpAndSettle();
      expect(find.text('화면 공유 중지'), findsOneWidget);
      expect(find.text('손 내리기'), findsOneWidget);
    });
  });

  group('영상 영역', () {
    testWidgets('갤러리 보기: 타일을 사람 수만큼 균등하게 깐다', (tester) async {
      _size(tester, const Size(1000, 600));
      final tiles = [
        _t(_p('나', me: true)),
        _t(_p('a')),
        _t(_p('b')),
        _t(_p('c')),
      ];
      await tester.pumpWidget(
        _app(
          CallStage(
            tiles: tiles,
            speakingIds: const [],
            mode: CallViewMode.gallery,
          ),
        ),
      );
      expect(find.byType(CallVideoTile), findsNWidgets(4));
      final sizes = {
        for (final t in tiles)
          tester.getSize(find.byKey(ValueKey('gallery-${t.key}'))),
      };
      expect(sizes.length, 1); // 모두 같은 크기
      // 가로로 놓인 2x2 격자.
      final a = tester.getTopLeft(find.byKey(const ValueKey('gallery-a')));
      final b = tester.getTopLeft(find.byKey(const ValueKey('gallery-b')));
      final c = tester.getTopLeft(find.byKey(const ValueKey('gallery-c')));
      expect(
        a.dy,
        b.dy -
            tester.getSize(find.byKey(const ValueKey('gallery-a'))).height -
            8,
      );
      expect(c.dy, b.dy);
    });

    testWidgets('스피커 보기: 말하는 사람이 메인, 나머지는 썸네일 줄', (tester) async {
      _size(tester, const Size(1000, 600));
      final tiles = [_t(_p('나', me: true)), _t(_p('a')), _t(_p('b'))];
      await tester.pumpWidget(
        _app(
          CallStage(
            tiles: tiles,
            speakingIds: const ['b'],
            mode: CallViewMode.speaker,
          ),
        ),
      );
      expect(find.byKey(const ValueKey('main-b')), findsOneWidget);
      expect(find.byKey(const ValueKey('thumb-a')), findsOneWidget);
      expect(find.byKey(const ValueKey('thumb-나')), findsOneWidget);
      final main = tester.getSize(find.byKey(const ValueKey('main-b')));
      final thumb = tester.getSize(find.byKey(const ValueKey('thumb-a')));
      expect(main.width, greaterThan(thumb.width * 2));
    });

    testWidgets('스피커 보기: 다른 사람의 화면 공유가 있으면 공유 화면이 메인', (tester) async {
      _size(tester, const Size(1000, 600));
      final b = _p('b', sharing: true);
      final tiles = [
        _t(_p('나', me: true)),
        _t(_p('a', speaking: true)),
        _t(b),
        _t(b, share: true),
      ];
      await tester.pumpWidget(
        _app(
          CallStage(
            tiles: tiles,
            speakingIds: const ['a'],
            mode: CallViewMode.speaker,
          ),
        ),
      );
      expect(find.byKey(const ValueKey('main-b#screen')), findsOneWidget);
      expect(find.byKey(const ValueKey('thumb-a')), findsOneWidget);
      expect(find.byKey(const ValueKey('thumb-b')), findsOneWidget);
    });

    testWidgets('스피커 보기: 말하는 사람이 바뀌어도 1.5초 동안 메인이 안 바뀐다', (tester) async {
      _size(tester, const Size(1000, 600));
      var now = DateTime(2026, 1, 1, 10);
      final tiles = [_t(_p('나', me: true)), _t(_p('a')), _t(_p('b'))];
      Widget stage(List<String> speaking) => _app(
        CallStage(
          tiles: tiles,
          speakingIds: speaking,
          mode: CallViewMode.speaker,
          now: () => now,
        ),
      );

      await tester.pumpWidget(stage(['a']));
      expect(find.byKey(const ValueKey('main-a')), findsOneWidget);

      now = now.add(const Duration(milliseconds: 500));
      await tester.pumpWidget(stage(['b']));
      expect(find.byKey(const ValueKey('main-a')), findsOneWidget); // 아직 유지

      // 유지 시간이 끝나면 따로 다시 그리지 않아도 스스로 바뀐다.
      now = now.add(const Duration(milliseconds: 1100));
      await tester.pump(const Duration(milliseconds: 1100));
      expect(find.byKey(const ValueKey('main-b')), findsOneWidget);
      expect(find.byKey(const ValueKey('thumb-a')), findsOneWidget);
    });

    testWidgets('혼자 있으면 썸네일 줄 없이 메인만', (tester) async {
      _size(tester, const Size(1000, 600));
      await tester.pumpWidget(
        _app(
          CallStage(
            tiles: [_t(_p('나', me: true))],
            speakingIds: const [],
            mode: CallViewMode.speaker,
          ),
        ),
      );
      expect(find.byKey(const ValueKey('main-나')), findsOneWidget);
      expect(find.byKey(const ValueKey('speaker-thumbnails')), findsNothing);
    });

    testWidgets('좁은 세로 화면의 스피커 보기는 썸네일이 위쪽 가로 줄', (tester) async {
      _size(tester, const Size(360, 640));
      final tiles = [_t(_p('나', me: true)), _t(_p('a')), _t(_p('b'))];
      await tester.pumpWidget(
        _app(
          CallStage(
            tiles: tiles,
            speakingIds: const ['a'],
            mode: CallViewMode.speaker,
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      final main = tester.getTopLeft(find.byKey(const ValueKey('main-a')));
      final thumb = tester.getTopLeft(find.byKey(const ValueKey('thumb-나')));
      expect(thumb.dy, lessThan(main.dy));
    });

    testWidgets('타일: 이름, 마이크 꺼짐, 손든 배지, 말하는 중 테두리', (tester) async {
      _size(tester, const Size(600, 400));
      final person = _p('a', mic: false, hand: DateTime(2026));
      await tester.pumpWidget(
        _app(
          SizedBox(
            width: 300,
            height: 200,
            child: CallVideoTile(tile: _t(person)),
          ),
        ),
      );
      expect(find.text('이름a'), findsOneWidget);
      expect(find.byIcon(Icons.mic_off), findsOneWidget);
      expect(find.byType(CallHandBadge), findsOneWidget);

      // 마이크가 켜져 있고 말하는 중이면 초록 테두리.
      await tester.pumpWidget(
        _app(
          SizedBox(
            width: 300,
            height: 200,
            child: CallVideoTile(tile: _t(_p('b', speaking: true))),
          ),
        ),
      );
      final box = tester.widget<Container>(
        find
            .descendant(
              of: find.byType(CallVideoTile),
              matching: find.byType(Container),
            )
            .first,
      );
      final deco = box.foregroundDecoration as BoxDecoration;
      expect((deco.border as Border).top.color, callSpeakingColor);
      expect(find.byIcon(Icons.mic_off), findsNothing);
    });

    testWidgets('내 화면 공유 타일은 영상 대신 안내만 (거울 속 거울 방지)', (tester) async {
      _size(tester, const Size(600, 400));
      final me = _p('나', me: true, sharing: true);
      await tester.pumpWidget(
        _app(
          SizedBox(
            width: 300,
            height: 200,
            child: CallVideoTile(tile: _t(me, share: true)),
          ),
        ),
      );
      expect(find.text('내 화면을 공유하고 있습니다'), findsOneWidget);
      expect(find.text('이름나의 화면 공유'), findsOneWidget);
    });
  });

  group('참가자 패널', () {
    testWidgets('참가자 (N) 제목과 손든 사람 → 말하는 사람 → 나머지 순서', (tester) async {
      _size(tester, const Size(400, 700));
      final t0 = DateTime(2026, 1, 1, 10);
      final people = [
        _p('나', me: true),
        _p('a'),
        _p('b', speaking: true),
        _p('c', hand: t0),
      ];
      var closed = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CallParticipantsPanel(
              people: people,
              onClose: () => closed = true,
            ),
          ),
        ),
      );
      expect(find.text('참가자 (4)'), findsOneWidget);

      double y(String id) =>
          tester.getTopLeft(find.byKey(ValueKey('participant-$id'))).dy;
      expect(y('c'), lessThan(y('b')));
      expect(y('b'), lessThan(y('나')));
      expect(y('나'), lessThan(y('a')));

      expect(find.text('이름나 (나)'), findsOneWidget);
      expect(find.byType(CallHandBadge), findsOneWidget);
      expect(find.byKey(const ValueKey('speaking-indicator')), findsOneWidget);

      await tester.tap(find.byIcon(Icons.close));
      expect(closed, isTrue);
    });

    testWidgets('마이크·카메라 켜짐/꺼짐과 화면 공유 중 표시', (tester) async {
      _size(tester, const Size(400, 700));
      final people = [_p('a', mic: false, cam: false), _p('b', sharing: true)];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CallParticipantsPanel(people: people, onClose: () {}),
          ),
        ),
      );
      expect(find.byIcon(Icons.mic_off), findsOneWidget);
      expect(find.byIcon(Icons.mic), findsOneWidget);
      expect(find.byIcon(Icons.videocam_off), findsOneWidget);
      expect(find.byIcon(Icons.videocam), findsOneWidget);
      expect(find.byIcon(Icons.screen_share), findsOneWidget);
    });
  });

  testWidgets('손들기 토스트 문구', (tester) async {
    await tester.pumpWidget(
      _app(const Center(child: CallToast(message: '이름a님이 손을 들었습니다'))),
    );
    expect(find.text('이름a님이 손을 들었습니다'), findsOneWidget);
  });
}
