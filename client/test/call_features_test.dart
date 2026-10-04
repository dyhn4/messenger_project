import 'package:client/screens/call/call_control_bar.dart';
import 'package:client/screens/call/call_logic.dart';
import 'package:client/screens/call/call_participants_panel.dart';
import 'package:client/screens/call/call_stage.dart' show CallMicRequestBanner;
import 'package:client/screens/call/call_whiteboard_view.dart';
import 'package:client/services/call_quality.dart';
import 'package:client/services/call_whiteboard.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' show VideoParametersPresets;

/// 화상회의 추가 기능 — 참가자 수에 따른 화질 단계(call_quality.dart), 화이트보드(call_whiteboard.dart·
/// call_whiteboard_view.dart), 진행자의 참가자 마이크 켜기/끄기(참가자 패널).

/// 화이트보드가 보낸 메시지를 모아 두는 가짜 데이터 채널.
class _Sent {
  final messages = <(WhiteboardMessage, List<String>?)>[];
  Future<void> send(WhiteboardMessage m, {List<String>? to}) async =>
      messages.add((m, to));
  List<WhiteboardMessage> get all => [for (final (m, _) in messages) m];
}

/// JSON으로 한 번 오가게 해서(실제 데이터 채널처럼) 다른 참가자의 판에 반영한다.
WhiteboardMessage _roundTrip(WhiteboardMessage m) =>
    WhiteboardMessage.decode(m.encode())!;

void main() {
  group('화질 단계', () {
    test('참가자 수 기준 — 4명까지 1080p, 8명까지 720p, 16명까지 540p, 그 이상 360p', () {
      expect(callVideoTierForParticipants(1), CallVideoTier.fhd);
      expect(callVideoTierForParticipants(4), CallVideoTier.fhd);
      expect(callVideoTierForParticipants(5), CallVideoTier.hd);
      expect(callVideoTierForParticipants(8), CallVideoTier.hd);
      expect(callVideoTierForParticipants(9), CallVideoTier.sd);
      expect(callVideoTierForParticipants(16), CallVideoTier.sd);
      expect(callVideoTierForParticipants(17), CallVideoTier.ld);
    });

    test('서버 값과 직접 센 값 중 낮은 쪽, 서버 값이 없거나 모르는 값이면 직접 센 값', () {
      expect(
        lowerCallVideoTier(CallVideoTier.fhd, CallVideoTier.sd),
        CallVideoTier.sd,
      );
      expect(
        lowerCallVideoTier(CallVideoTier.ld, CallVideoTier.hd),
        CallVideoTier.ld,
      );
      expect(lowerCallVideoTier(CallVideoTier.hd, null), CallVideoTier.hd);
      expect(callVideoTierFromWire('sd'), CallVideoTier.sd);
      expect(callVideoTierFromWire('4k'), isNull);
      expect(callVideoTierFromWire(null), isNull);
    });

    test('단계마다 카메라·화면 공유 최대치 — 1080p일 때만 화면 공유 30fps', () {
      expect(
        callVideoSpecFor(CallVideoTier.fhd).camera,
        VideoParametersPresets.h1080_169,
      );
      expect(
        callVideoSpecFor(CallVideoTier.fhd).screen.encoding!.maxFramerate,
        30,
      );
      expect(
        callVideoSpecFor(CallVideoTier.hd).camera,
        VideoParametersPresets.h720_169,
      );
      expect(
        callVideoSpecFor(CallVideoTier.hd).screen.encoding!.maxFramerate,
        15,
      );
      expect(
        callVideoSpecFor(CallVideoTier.ld).camera,
        VideoParametersPresets.h360_169,
      );
    });

    test('줄임 비율 — 찍는 높이 / 보낼 높이, 키우지는 않는다', () {
      expect(callScaleDownBy(1080, VideoParametersPresets.h720_169), 1.5);
      expect(callScaleDownBy(1080, VideoParametersPresets.h360_169), 3);
      expect(callScaleDownBy(720, VideoParametersPresets.h1080_169), 1);
      expect(callScaleDownBy(0, VideoParametersPresets.h720_169), 1);
    });

    test('카메라는 1080p로 찍고 simulcast 아래 층은 360p·720p', () {
      expect(callCameraCaptureOptions.params, VideoParametersPresets.h1080_169);
      expect(callVideoPublishOptions.videoSimulcastLayers, [
        VideoParametersPresets.h360_169,
        VideoParametersPresets.h720_169,
      ]);
      expect(callVideoPublishOptions.screenShareEncoding!.maxFramerate, 30);
    });
  });

  group('화이트보드 — 판과 메시지', () {
    test('메시지는 JSON으로 오가고 좌표는 0~1 비율(10000 눈금)로 보존된다', () {
      const begin = WhiteboardBegin(
        id: 's1',
        color: 0xFFE53935,
        width: 0.004,
        points: [Offset(0.1234, 0.5), Offset(1.2, -0.1)],
      );
      final back = _roundTrip(begin) as WhiteboardBegin;
      expect(back.id, 's1');
      expect(back.color, 0xFFE53935);
      expect(back.width, 0.004);
      // 판 밖 좌표는 판 끝으로 붙는다.
      expect(back.points, [const Offset(0.1234, 0.5), const Offset(1, 0)]);
      expect(
        _roundTrip(const WhiteboardErase(['a', 'b'])),
        isA<WhiteboardErase>(),
      );
      expect(_roundTrip(const WhiteboardClear()), isA<WhiteboardClear>());
      expect(_roundTrip(const WhiteboardOpened()), isA<WhiteboardOpened>());
      expect(WhiteboardMessage.decode('not json'.codeUnits), isNull);
      expect(WhiteboardMessage.decode('{"t":"hand"}'.codeUnits), isNull);
    });

    test('begin → add로 획이 이어지고, erase·clear로 지워진다 — 작성자는 보낸 사람', () {
      final book = WhiteboardBook();
      expect(
        book.apply(
          'u1',
          const WhiteboardBegin(
            id: 's1',
            color: 1,
            width: 0.004,
            points: [Offset(0.1, 0.1)],
          ),
        ),
        isTrue,
      );
      book.apply(
        'u1',
        const WhiteboardAdd(id: 's1', points: [Offset(0.2, 0.2)]),
      );
      // 없는 획에 잇는 점은 버린다(늦게 들어와 begin을 못 받은 경우).
      expect(
        book.apply(
          'u2',
          const WhiteboardAdd(id: 'nope', points: [Offset(0.2, 0.2)]),
        ),
        isFalse,
      );
      expect(book['s1']!.points, hasLength(2));
      expect(book['s1']!.authorId, 'u1');
      book.apply('u2', const WhiteboardBegin(id: 's2', color: 1, width: 0.004));
      expect(book.lastStrokeBy('u1')!.id, 's1');
      expect(book.apply('u2', const WhiteboardErase(['s1'])), isTrue);
      expect(book['s1'], isNull);
      expect(book.apply('u2', const WhiteboardClear()), isTrue);
      expect(book.isEmpty, isTrue);
      expect(book.apply('u2', const WhiteboardClear()), isFalse);
    });

    test('지우개는 획 근처만 맞힌다(굵기 포함)', () {
      final book = WhiteboardBook()
        ..apply(
          'u1',
          const WhiteboardBegin(
            id: 'line',
            color: 1,
            width: 0.004,
            points: [Offset(0.1, 0.5), Offset(0.9, 0.5)],
          ),
        );
      expect(book.strokesNear(const Offset(0.5, 0.505), 0.01), ['line']);
      expect(book.strokesNear(const Offset(0.5, 0.8), 0.01), isEmpty);
      expect(book.strokesNear(const Offset(0.95, 0.5), 0.01), isEmpty);
    });

    test('늦게 들어온 사람에게 보내는 판 — 긴 획은 begin + add로 나눠 같은 판이 된다', () {
      final points = [for (var i = 0; i < 1000; i++) Offset(i / 1000, 0.5)];
      final source = WhiteboardBook()
        ..apply(
          'u1',
          WhiteboardBegin(id: 'long', color: 7, width: 0.002, points: points),
        )
        ..apply(
          'u2',
          const WhiteboardBegin(
            id: 'dot',
            color: 8,
            width: 0.008,
            points: [Offset(0.3, 0.3)],
          ),
        );
      final messages = source.snapshotMessages();
      expect(messages.whereType<WhiteboardBegin>(), hasLength(2));
      expect(
        messages.whereType<WhiteboardAdd>(),
        hasLength(2),
      ); // 400 + 400 + 200
      for (final m in messages) {
        final add = m;
        if (add is WhiteboardBegin) {
          expect(
            add.points.length,
            lessThanOrEqualTo(whiteboardPointsPerMessage),
          );
        }
      }
      final target = WhiteboardBook();
      for (final m in messages) {
        target.apply('sender', _roundTrip(m));
      }
      expect(target['long']!.points, hasLength(1000));
      expect(target['dot']!.color, 8);
      expect([for (final s in target.strokes) s.id], ['long', 'dot']);
    });

    test('판을 다시 보낼 사람은 이미 있던 참가자 중 identity가 가장 작은 한 명', () {
      expect(whiteboardSnapshotSender(['c', 'a', 'b']), 'a');
      expect(whiteboardSnapshotSender(const []), isNull);
    });
  });

  group('화이트보드 — 그리기(CallWhiteboard)', () {
    test('그리는 점은 판에 바로, 데이터 채널에는 모아서 보내고 떼면 남은 점을 보낸다', () async {
      final sent = _Sent();
      final board = CallWhiteboard(myId: 'me', send: sent.send);
      board.beginStroke(const Offset(0.1, 0.1), color: 1, width: 0.004);
      board.extendStroke(const Offset(0.2, 0.2));
      board.extendStroke(const Offset(0.3, 0.3));
      expect(board.book.strokes.single.points, hasLength(3));
      expect(sent.all, hasLength(1)); // begin만
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(sent.all, hasLength(2));
      expect((sent.all[1] as WhiteboardAdd).points, hasLength(2));
      board.extendStroke(const Offset(0.4, 0.4));
      board.endStroke();
      expect(sent.all, hasLength(3));
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(sent.all, hasLength(3));

      // 다른 참가자의 판에 그대로 옮기면 같은 획이 된다.
      final other = WhiteboardBook();
      for (final m in sent.all) {
        other.apply('me', _roundTrip(m));
      }
      expect(other.strokes.single.points, hasLength(4));
      expect(other.strokes.single.authorId, 'me');
      board.dispose();
    });

    test('되돌리기는 내 마지막 획만, 남이 그린 건 건드리지 않는다', () {
      final sent = _Sent();
      final board = CallWhiteboard(myId: 'me', send: sent.send);
      board.receive(
        'other',
        const WhiteboardBegin(id: 'theirs', color: 1, width: 0.004),
      );
      expect(board.canUndo, isFalse);
      board.beginStroke(const Offset(0.5, 0.5), color: 1, width: 0.004);
      board.endStroke();
      expect(board.canUndo, isTrue);
      board.undo();
      expect(board.canUndo, isFalse);
      expect([for (final s in board.book.strokes) s.id], ['theirs']);
      expect(sent.all.last, isA<WhiteboardErase>());
      board.undo(); // 내 획이 없으면 아무것도 안 보낸다.
      expect(sent.all.whereType<WhiteboardErase>(), hasLength(1));
    });

    test('모두 지우기·늦게 들어온 사람에게 판 보내기', () async {
      final sent = _Sent();
      final board = CallWhiteboard(myId: 'me', send: sent.send);
      board.beginStroke(const Offset(0.5, 0.5), color: 1, width: 0.004);
      board.endStroke();
      await board.sendSnapshotTo('late');
      expect(sent.messages.last.$2, ['late']);
      expect(sent.messages.last.$1, isA<WhiteboardBegin>());
      board.clearAll();
      expect(board.book.isEmpty, isTrue);
      expect(sent.all.last, isA<WhiteboardClear>());
    });
  });

  group('화이트보드 화면', () {
    Future<(CallWhiteboard, _Sent, List<String>)> pump(
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final sent = _Sent();
      final board = CallWhiteboard(myId: 'me', send: sent.send);
      final log = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CallWhiteboardView(
              board: board,
              onClose: () => log.add('close'),
            ),
          ),
        ),
      );
      return (board, sent, log);
    }

    testWidgets('판을 끌어 그리면 획이 생기고 보낸다 — 고른 색으로', (tester) async {
      final (board, sent, _) = await pump(tester);
      await tester.tap(find.byKey(const ValueKey('whiteboard-color-1')));
      await tester.pump();
      final canvas = find.byKey(const ValueKey('whiteboard-canvas'));
      final rect = tester.getRect(canvas);
      final gesture = await tester.startGesture(rect.center);
      await gesture.moveBy(const Offset(80, 0));
      await gesture.moveBy(const Offset(80, 40));
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 100));
      final stroke = board.book.strokes.single;
      expect(stroke.color, whiteboardColors[1]);
      expect(stroke.points.first.dx, closeTo(0.5, 0.01));
      expect(stroke.points.first.dy, closeTo(0.5, 0.01));
      expect(stroke.points.length, greaterThanOrEqualTo(3));
      expect(sent.all.first, isA<WhiteboardBegin>());
    });

    testWidgets('지우개로 문지르면 지워지고, 되돌리기·모두 지우기(확인)·닫기', (tester) async {
      final (board, sent, log) = await pump(tester);
      final rect = tester.getRect(
        find.byKey(const ValueKey('whiteboard-canvas')),
      );
      Future<void> drawAcross(double y) async {
        final g = await tester.startGesture(Offset(rect.left + 40, y));
        await g.moveTo(Offset(rect.right - 40, y));
        await g.up();
        await tester.pump(const Duration(milliseconds: 100));
      }

      await drawAcross(rect.top + rect.height * 0.3);
      await drawAcross(rect.top + rect.height * 0.7);
      expect(board.book.strokes, hasLength(2));

      await tester.tap(find.byKey(const ValueKey('whiteboard-eraser')));
      await tester.pump();
      final g = await tester.startGesture(
        Offset(rect.center.dx, rect.top + rect.height * 0.3 - 20),
      );
      await g.moveBy(const Offset(0, 40));
      await g.up();
      await tester.pump();
      expect(board.book.strokes, hasLength(1));
      expect(sent.all.whereType<WhiteboardErase>(), hasLength(1));

      await tester.tap(find.byKey(const ValueKey('whiteboard-undo')));
      await tester.pump();
      expect(board.book.isEmpty, isTrue);

      await tester.tap(find.byKey(const ValueKey('whiteboard-pen')));
      await tester.pump();
      await drawAcross(rect.center.dy);
      await tester.tap(find.byKey(const ValueKey('whiteboard-clear')));
      await tester.pumpAndSettle();
      expect(find.text('화이트보드 지우기'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('whiteboard-clear-confirm')));
      await tester.pumpAndSettle();
      expect(board.book.isEmpty, isTrue);
      expect(sent.all.last, isA<WhiteboardClear>());

      await tester.tap(find.byKey(const ValueKey('whiteboard-close')));
      expect(log, ['close']);
    });

    testWidgets('다른 사람이 그린 획도 판에 그려진다', (tester) async {
      final (board, _, _) = await pump(tester);
      board.receive(
        'other',
        const WhiteboardBegin(
          id: 'x',
          color: 0xFF1E88E5,
          width: 0.004,
          points: [Offset(0.1, 0.1), Offset(0.9, 0.9)],
        ),
      );
      await tester.pump();
      // 되돌리기는 내 획이 없어서 꺼져 있고, 모두 지우기는 켜진다.
      expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('whiteboard-undo')))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('whiteboard-clear')))
            .onPressed,
        isNotNull,
      );
    });
  });

  group('진행자 — 참가자 패널의 마이크', () {
    CallPerson p(
      String id, {
      bool me = false,
      bool host = false,
      bool mic = true,
    }) => CallPerson(id: id, name: '이름$id', isMe: me, isHost: host, micOn: mic);

    Future<List<String>> pump(
      WidgetTester tester, {
      required bool canControlOthers,
    }) async {
      final toggled = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CallParticipantsPanel(
              people: [
                p('me', me: true, host: canControlOthers),
                p('a'),
                p('b', mic: false, host: !canControlOthers),
              ],
              onClose: () {},
              canControlOthers: canControlOthers,
              onToggleMic: (person) => toggled.add(person.id),
            ),
          ),
        ),
      );
      return toggled;
    }

    testWidgets('진행자는 다른 사람의 마이크 단추를 눌러 켜고 끈다 — 진행자 표시', (tester) async {
      final toggled = await pump(tester, canControlOthers: true);
      expect(find.text('진행자'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('participant-me')),
          matching: find.byKey(const ValueKey('host-badge')),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('participant-mic-a')));
      await tester.tap(find.byKey(const ValueKey('participant-mic-b')));
      await tester.tap(find.byKey(const ValueKey('participant-mic-me')));
      expect(toggled, ['a', 'b', 'me']);
      expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('participant-mic-a')))
            .tooltip,
        '이름a님의 마이크 끄기',
      );
      expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('participant-mic-b')))
            .tooltip,
        '이름b님에게 마이크 켜기 요청',
      );
    });

    testWidgets('진행자가 아니면 내 마이크만 단추이고 다른 사람은 표시만', (tester) async {
      final toggled = await pump(tester, canControlOthers: false);
      expect(find.byKey(const ValueKey('participant-mic-a')), findsNothing);
      expect(find.byKey(const ValueKey('participant-mic-b')), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('participant-b')),
          matching: find.byKey(const ValueKey('host-badge')),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('participant-mic-me')));
      expect(toggled, ['me']);
    });
  });

  testWidgets('마이크 켜기 요청 안내 띠 — [마이크 켜기] / [그대로 두기]', (tester) async {
    final log = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: CallMicRequestBanner(
              onAccept: () => log.add('accept'),
              onDecline: () => log.add('decline'),
            ),
          ),
        ),
      ),
    );
    expect(find.text('진행자가 마이크를 켜 달라고 요청했습니다'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('call-mic-request-accept')));
    await tester.tap(find.byKey(const ValueKey('call-mic-request-decline')));
    expect(log, ['accept', 'decline']);
  });

  testWidgets('폰 폭(360)에서도 안내 띠가 넘치지 않는다', (tester) async {
    tester.view.physicalSize = const Size(360, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Center(
              child: CallMicRequestBanner(onAccept: () {}, onDecline: () {}),
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const ValueKey('call-mic-request-accept')),
      findsOneWidget,
    );
  });

  testWidgets('컨트롤바의 화이트보드 단추 — 열려 있으면 선택 표시', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    var toggled = 0;
    Widget bar(bool open) => MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: CallControlBar(
            micOn: true,
            camOn: true,
            sharing: false,
            handRaised: false,
            whiteboardOpen: open,
            viewMode: CallViewMode.gallery,
            panel: CallPanel.none,
            participantCount: 2,
            chatUnread: 0,
            onToggleMic: () {},
            onToggleCamera: () {},
            onToggleShare: () {},
            onToggleParticipants: () {},
            onToggleChat: () {},
            onToggleHand: () {},
            onToggleWhiteboard: () => toggled++,
            onToggleView: () {},
            onLeave: () {},
          ),
        ),
      ),
    );
    await tester.pumpWidget(bar(false));
    expect(find.text('화이트보드'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('call-whiteboard')));
    expect(toggled, 1);
    await tester.pumpWidget(bar(true));
    expect(
      tester
          .widget<CallBarButton>(find.byKey(const ValueKey('call-whiteboard')))
          .selected,
      isTrue,
    );
  });
}
