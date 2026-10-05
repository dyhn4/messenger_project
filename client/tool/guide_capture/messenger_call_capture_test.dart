// 초보자용 도움말 "메신저 이용법"(server/guide/messenger.html)의 "화상회의" 장 그림을 찍는다.
//
// 다시 찍기(client 폴더에서):
//   flutter test tool/guide_capture/messenger_call_capture_test.dart
// 한 장만:
//   flutter test tool/guide_capture/messenger_call_capture_test.dart --plain-name "통화 화면"
// 결과: ../server/guide/images/messenger-call-*.png
//
// 통화 화면(CallScreen)은 LiveKit에 실제로 연결돼야(callController.room) 그려지므로, 여기서는
// CallScreen.build와 똑같은 배치(어두운 AppBar + 보기 메뉴, CallStage, 안내 띠·알림, CallControlBar,
// 오른쪽 패널)를 [_CallShell]로 다시 쌓고, 그 안에는 진짜 통화 위젯(CallStage · CallControlBar ·
// CallParticipantsPanel · CallWhiteboardView · CallMicRequestBanner · CallToast · ChatPanel)만 넣는다.
// call_screen.dart의 배치를 바꾸면 [_CallShell]도 맞춰 줄 것. 영상 트랙은 만들 수 없어서 모두 카메라를
// 끈 상태(프로필 그림)로 찍는다.
import 'dart:async';
import 'dart:math' as math;

import 'package:client/models/app_user.dart';
import 'package:client/models/room.dart';
import 'package:client/screens/call/call_control_bar.dart';
import 'package:client/screens/call/call_logic.dart';
import 'package:client/screens/call/call_participants_panel.dart';
import 'package:client/screens/call/call_snapshot.dart';
import 'package:client/screens/call/call_stage.dart';
import 'package:client/screens/call/call_whiteboard_view.dart';
import 'package:client/screens/home_screen.dart';
import 'package:client/services/call_whiteboard.dart';
import 'package:client/services/chat_socket.dart';
import 'package:client/services/session.dart';
import 'package:client/widgets/call_button.dart';
import 'package:client/widgets/chat_input_bar.dart';
import 'package:client/widgets/chat_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'guide_capture.dart';
import 'messenger_demo.dart';

// ───────────────────────────── 예시 데이터 ─────────────────────────────

/// 통화 참가자 — 마케팅팀 토픽 멤버 다섯 명. 카메라는 모두 꺼 둔다(프로필 그림으로 보인다).
CallPerson _person(
  AppUser u, {
  bool isMe = false,
  bool mic = true,
  bool speaking = false,
  bool host = false,
  DateTime? hand,
}) => CallPerson(
  id: u.id,
  name: u.name,
  isMe: isMe,
  micOn: mic,
  camOn: false,
  speaking: speaking,
  isHost: host,
  handRaisedAt: hand,
  user: u,
);

/// 들어온 순서(나 먼저) — 이도현이 말하는 중, 박서연은 마이크 끔, 최준호는 손을 들었다.
/// [meHost]면 내가 진행자(참가자 패널에서 다른 사람 마이크를 켜고 끌 수 있다), 아니면 이도현이 진행자.
List<CallPerson> _people({bool meHost = true, bool juneHand = true}) => [
  _person(me, isMe: true, host: meHost),
  _person(doHyun, speaking: true, host: !meHost),
  _person(seoYeon, mic: false),
  _person(junHo, hand: juneHand ? at(14, 6) : null),
  _person(jiWoo),
];

List<CallTileData> _tiles(List<CallPerson> people) => [
  for (final p in people) CallTileData(p),
];

/// 마케팅팀 토픽(통화하는 방).
Room _marketing(Session s) => s.rooms.firstWhere((r) => r.id == 'r-mkt');

int _ms(DateTime t) => t.millisecondsSinceEpoch;

Map<String, dynamic> _event(DateTime t, AppUser u, String kind) => {
  'at': _ms(t),
  'userId': u.id,
  'name': u.name,
  'kind': kind,
};

/// 화상회의 기록 카드 메시지(서버 callCards.js가 올리는 시스템 메시지와 같은 모양).
Map<String, dynamic> _callCardMessage(
  String id,
  String roomId,
  DateTime startedAt,
  Map<String, dynamic> card,
) => {
  'id': id,
  'roomId': roomId,
  'senderId': null,
  'senderName': '시스템',
  'type': 'system',
  'text': '화상회의',
  'createdAt': _ms(startedAt),
  'comments': const [],
  'callCard': {'startedAt': _ms(startedAt), ...card},
};

// ───────────────────────────── 통화 화면 틀 ─────────────────────────────

/// CallScreen.build와 같은 배치 — call_screen.dart 참고(이 화면은 LiveKit 연결 없이는 안 그려진다).
class _CallShell extends StatelessWidget {
  final String title;
  final List<CallPerson> people;
  final CallViewMode mode;
  final List<String> speakingIds;
  final CallPanel panel;

  /// 열린 패널의 내용(참가자 목록이나 채팅) — 넓은 화면이면 오른쪽 340 칸에 붙는다.
  final Widget? panelBody;
  final bool handRaised;
  final bool micRequested;
  final String? toast;
  final CallWhiteboard? whiteboard;
  final int chatUnread;

  const _CallShell({
    required this.title,
    required this.people,
    this.mode = CallViewMode.gallery,
    this.speakingIds = const [],
    this.panel = CallPanel.none,
    this.panelBody,
    this.handRaised = false,
    this.micRequested = false,
    this.toast,
    this.whiteboard,
    this.chatUnread = 0,
  });

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final meMicOn = people.firstWhere((p) => p.isMe).micOn;
    void noop() {}
    return Scaffold(
      backgroundColor: callStageColor,
      appBar: AppBar(
        backgroundColor: callStageColor,
        foregroundColor: Colors.white,
        title: Text(title),
        actions: [
          PopupMenuButton<CallViewMode>(
            key: const ValueKey('call-view-menu'),
            tooltip: '보기',
            icon: Icon(
              mode == CallViewMode.speaker ? Icons.person_pin : Icons.grid_view,
            ),
            itemBuilder: (_) => [
              CheckedPopupMenuItem(
                value: CallViewMode.speaker,
                checked: mode == CallViewMode.speaker,
                child: const Text('스피커 보기'),
              ),
              CheckedPopupMenuItem(
                value: CallViewMode.gallery,
                checked: mode == CallViewMode.gallery,
                child: const Text('갤러리 보기'),
              ),
            ],
          ),
        ],
      ),
      body: Row(
        children: [
          Expanded(
            child: Column(
              children: [
                Expanded(
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: whiteboard != null
                            ? CallWhiteboardView(
                                board: whiteboard!,
                                onClose: noop,
                              )
                            : CallStage(
                                tiles: _tiles(people),
                                speakingIds: speakingIds,
                                mode: mode,
                              ),
                      ),
                      if (micRequested)
                        Positioned(
                          left: 16,
                          right: 16,
                          top: 12,
                          child: Center(
                            child: CallMicRequestBanner(
                              onAccept: noop,
                              onDecline: noop,
                            ),
                          ),
                        ),
                      if (toast != null)
                        Positioned(
                          left: 16,
                          right: 16,
                          bottom: 12,
                          child: IgnorePointer(
                            child: Center(
                              child: CallToast(
                                message: toast!,
                                hand: toast!.endsWith('손을 들었습니다'),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                CallControlBar(
                  micOn: meMicOn,
                  camOn: false,
                  sharing: false,
                  handRaised: handRaised,
                  whiteboardOpen: whiteboard != null,
                  viewMode: mode,
                  panel: panel,
                  participantCount: people.length,
                  chatUnread: chatUnread,
                  onToggleMic: noop,
                  onToggleCamera: noop,
                  onToggleShare: noop,
                  onToggleParticipants: noop,
                  onToggleChat: noop,
                  onToggleHand: noop,
                  onToggleWhiteboard: noop,
                  onToggleView: noop,
                  onLeave: noop,
                ),
              ],
            ),
          ),
          if (wide && panel != CallPanel.none && panelBody != null)
            SizedBox(width: 340, child: panelBody),
        ],
      ),
    );
  }
}

/// 통화 화면을 띄운다 — showCallScreen처럼 전체 화면 대화상자 라우트로 올려서, 왼쪽 위에 화면 닫기(X)가
/// 실제 앱과 똑같이 붙는다.
Future<void> _pumpCall(
  WidgetTester tester,
  Widget Function(BuildContext context) builder,
) async {
  await pumpGuideApp(tester, const Scaffold(body: SizedBox.expand()));
  final navigator = tester.state<NavigatorState>(find.byType(Navigator).first);
  unawaited(
    navigator.push(
      MaterialPageRoute<void>(fullscreenDialog: true, builder: builder),
    ),
  );
  await settleGuide(tester);
}

/// 통화 화면의 참가자 패널(CallScreen._panelBody와 같은 것).
Widget _participantsPanel(List<CallPerson> people, {bool host = true}) =>
    CallParticipantsPanel(
      people: people,
      onClose: () {},
      canControlOthers: host,
      onToggleMic: (_) {},
    );

/// 통화 화면의 채팅 패널(CallScreen._panelBody와 같은 것) — 이 방의 평소 채팅 패널을 그대로 붙인다.
Widget _chatPanel(BuildContext context, Session session, Room room) =>
    ColoredBox(
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        children: [
          CallPanelHeader(title: '채팅', onClose: () {}),
          Expanded(
            child: ChatPanel(
              key: ValueKey('call-chat-${room.id}'),
              session: session,
              room: room,
            ),
          ),
        ],
      ),
    );

/// 컨트롤바 단추(키로 찾는다 — 'call-mic' 등).
Finder _bar(String key) => find.byKey(ValueKey(key));

/// 단추의 둥근 아이콘 부분(라벨 제외) — 번호 배지를 원 오른쪽 위에 붙일 때.
Finder _barCircle(String key) =>
    find.descendant(of: _bar(key), matching: find.byType(Material)).first;

/// 칠판 그림 — 회의에서 그린 흐름도(상자 세 개와 화살표, 동그라미 강조).
void _drawSampleBoard(CallWhiteboard board) {
  var n = 0;
  void stroke(AppUser who, int color, double width, List<Offset> pts) {
    final id = 'wb${n++}';
    if (who.id == me.id) {
      board.beginStroke(pts.first, color: color, width: width);
      for (final p in pts.skip(1)) {
        board.extendStroke(p);
      }
      board.endStroke();
      return;
    }
    board.receive(
      who.id,
      WhiteboardBegin(id: id, color: color, width: width, points: [pts.first]),
    );
    board.receive(who.id, WhiteboardAdd(id: id, points: pts.skip(1).toList()));
  }

  List<Offset> box(double l, double t, double r, double b) => [
    Offset(l, t),
    Offset(r, t),
    Offset(r, b),
    Offset(l, b),
    Offset(l, t),
  ];
  List<Offset> arrow(double x1, double x2, double y) => [
    Offset(x1, y),
    Offset(x2, y),
    Offset(x2 - 0.025, y - 0.04),
    Offset(x2, y),
    Offset(x2 - 0.025, y + 0.04),
  ];
  List<Offset> circle(double cx, double cy, double rx, double ry) => [
    for (var i = 0; i <= 40; i++)
      Offset(
        cx + rx * math.cos(i / 40 * 2 * math.pi),
        cy + ry * math.sin(i / 40 * 2 * math.pi),
      ),
  ];

  const black = 0xFF212121;
  const red = 0xFFE53935;
  const blue = 0xFF1E88E5;
  const green = 0xFF43A047;
  stroke(doHyun, black, 0.004, box(0.08, 0.32, 0.28, 0.58));
  stroke(doHyun, black, 0.004, box(0.40, 0.32, 0.60, 0.58));
  stroke(doHyun, black, 0.004, box(0.72, 0.32, 0.92, 0.58));
  stroke(doHyun, blue, 0.004, arrow(0.29, 0.39, 0.45));
  stroke(doHyun, blue, 0.004, arrow(0.61, 0.71, 0.45));
  // 상자 안의 짧은 줄(글씨 대신).
  for (final (l, r) in [(0.12, 0.24), (0.44, 0.56), (0.76, 0.88)]) {
    stroke(doHyun, black, 0.002, [Offset(l, 0.42), Offset(r, 0.42)]);
    stroke(doHyun, black, 0.002, [Offset(l, 0.48), Offset(r - 0.04, 0.48)]);
  }
  // 내가 그린 강조 동그라미와 체크 표시.
  stroke(me, red, 0.004, circle(0.50, 0.45, 0.15, 0.22));
  stroke(me, green, 0.008, [
    const Offset(0.76, 0.72),
    const Offset(0.80, 0.78),
    const Offset(0.88, 0.66),
  ]);
}

// ───────────────────────────── 캡처 ─────────────────────────────

/// 컨트롤바·안내 띠처럼 화면 아래위만 보여 줄 때 — 라벨이 붙는 폭(780 이상)이면서 본문 폭에 가깝게.
const _barSurface = GuideSurface(Size(800, 520));

void main() {
  // ── 화상회의 시작 · 참여 ──

  guideCapture('화상회의 시작 버튼', compact, (tester) async {
    final session = demoSession()..callsEnabled = true;
    await openDesktop(tester, session: session);
    final input = tester.getRect(find.byType(ChatInputBar));
    await saveGuideShot(
      tester,
      'messenger-call-start',
      callouts: [
        GuideCallout.box(
          find.byType(CallButton),
          number: 1,
          badge: CalloutBadge.top,
          padding: 0,
        ),
      ],
      crop: clampToScreen(
        tester,
        Rect.fromLTRB(input.left, input.top - 40, input.right, input.bottom),
      ),
    );
  });

  guideCapture('진행 중인 화상회의 참여', compact, (tester) async {
    final started = DateTime.now().subtract(const Duration(minutes: 12));
    final api = demoApi(
      extra: (api) => api.get(
        '/api/rooms/r-mkt/messages',
        (_) => [
          ...marketingMessages(),
          _callCardMessage('call-live', 'r-mkt', started, {
            'status': 'active',
            'answered': true,
            'events': [
              _event(started, doHyun, 'start'),
              _event(started.add(const Duration(minutes: 1)), jiWoo, 'join'),
            ],
          }),
        ],
      ),
    );
    final session = demoSession(api: api)..callsEnabled = true;
    session.callStates['r-mkt'] = CallState(
      roomId: 'r-mkt',
      active: true,
      startedBy: doHyun.id,
      startedAt: started,
      participantIds: [doHyun.id, jiWoo.id],
      hostId: doHyun.id,
    );
    await openDesktop(tester, session: session);
    final input = tester.getRect(find.byType(ChatInputBar));
    final card = tester.getRect(
      find.byKey(const ValueKey('call-card-call-live')),
    );
    await saveGuideShot(
      tester,
      'messenger-call-join',
      callouts: [
        GuideCallout.box(
          find.byKey(const ValueKey('call-card-join')),
          number: 1,
          badge: CalloutBadge.top,
        ),
        GuideCallout.box(
          find.byType(CallButton),
          number: 2,
          badge: CalloutBadge.top,
          padding: 0,
        ),
      ],
      crop: clampToScreen(
        tester,
        Rect.fromLTRB(input.left, card.top - 40, input.right, input.bottom),
      ),
    );
  });

  guideCapture('화상회의 요청 창', desktop, (tester) async {
    ignoreBenignErrors();
    final session = demoSession()..callsEnabled = true;
    await pumpGuideApp(tester, HomeScreen(session: session));
    // ignore: invalid_use_of_visible_for_testing_member
    session.debugApplyCallState(
      CallState(
        roomId: 'r-tf',
        active: true,
        startedBy: doHyun.id,
        startedAt: at(14, 0),
        participantIds: [doHyun.id],
        hostId: doHyun.id,
      ),
    );
    await settleGuide(tester);
    expect(find.byType(AlertDialog), findsOneWidget);
    await saveGuideShot(
      tester,
      'messenger-call-incoming',
      callouts: [
        GuideCallout.box(
          buttonWith('참여'),
          number: 1,
          badge: CalloutBadge.bottom,
        ),
        GuideCallout.box(
          buttonWith('거절'),
          number: 2,
          badge: CalloutBadge.bottom,
        ),
      ],
      crop: tester.getRect(dialogCard).inflate(24),
    );
  });

  // ── 통화 화면(PC) ──

  guideCapture('통화 화면', desktop, (tester) async {
    final session = demoSession();
    await _pumpCall(
      tester,
      (context) => _CallShell(
        title: _marketing(session).displayName(me.id),
        people: _people(),
        speakingIds: [doHyun.id],
        toast: '최준호님이 손을 들었습니다',
      ),
    );
    await saveGuideShot(
      tester,
      'messenger-call-screen',
      callouts: [
        GuideCallout.box(
          find.byTooltip('Close'),
          number: 1,
          badge: CalloutBadge.bottom,
          padding: 0,
        ),
        GuideCallout.box(
          find.byKey(const ValueKey('call-view-menu')),
          number: 2,
          badge: CalloutBadge.left,
          padding: 0,
        ),
        GuideCallout.box(
          find.byKey(const ValueKey('gallery-u-dh')),
          number: 3,
          badge: CalloutBadge.topLeft,
          padding: 2,
        ),
        GuideCallout.box(
          find.descendant(
            of: find.byKey(const ValueKey('gallery-u-jh')),
            matching: find.byType(CallHandBadge),
          ),
          number: 4,
          badge: CalloutBadge.right,
          padding: 3,
        ),
        GuideCallout.box(
          find.byType(CallToast),
          number: 5,
          badge: CalloutBadge.left,
        ),
        GuideCallout.rect(
          unionRect(tester, [_bar('call-mic'), _bar('call-view')], padding: 6),
          number: 6,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(
          find.byKey(const ValueKey('call-leave')),
          number: 7,
          badge: CalloutBadge.top,
        ),
      ],
    );
  });

  guideCapture('컨트롤바', _barSurface, (tester) async {
    final session = demoSession();
    await _pumpCall(
      tester,
      (context) => _CallShell(
        title: _marketing(session).displayName(me.id),
        people: _people(),
        speakingIds: [doHyun.id],
        chatUnread: 2,
      ),
    );
    final bar = tester.getRect(find.byType(CallControlBar));
    const keys = [
      'call-mic',
      'call-camera',
      'call-share',
      'call-participants',
      'call-chat',
      'call-hand',
      'call-whiteboard',
      'call-view',
    ];
    await saveGuideShot(
      tester,
      'messenger-call-bar',
      callouts: [
        for (final (i, k) in keys.indexed)
          GuideCallout.dot(
            _barCircle(k),
            number: i + 1,
            badge: CalloutBadge.topLeft,
          ),
        GuideCallout.dot(
          find.byKey(const ValueKey('call-leave')),
          number: 9,
          badge: CalloutBadge.topLeft,
        ),
      ],
      crop: Rect.fromLTRB(bar.left, bar.top - 22, bar.right, bar.bottom),
    );
  });

  guideCapture('참가자 패널', desktop, (tester) async {
    final session = demoSession();
    final people = _people();
    await _pumpCall(
      tester,
      (context) => _CallShell(
        title: _marketing(session).displayName(me.id),
        people: people,
        speakingIds: [doHyun.id],
        panel: CallPanel.participants,
        panelBody: _participantsPanel(people),
      ),
    );
    final panel = tester.getRect(find.byType(CallParticipantsPanel));
    final lastRow = tester.getRect(
      find.byKey(ValueKey('participant-${jiWoo.id}')),
    );
    await saveGuideShot(
      tester,
      'messenger-call-participants',
      callouts: [
        // 진행자 표시는 이름 바로 옆이라 상자를 두르면 이름 끝 글자가 가려진다 — 번호만.
        GuideCallout.dot(
          find.byKey(const ValueKey('host-badge')),
          number: 1,
          badge: CalloutBadge.right,
        ),
        GuideCallout.box(
          find.descendant(
            of: find.byKey(ValueKey('participant-${junHo.id}')),
            matching: find.byType(CallHandBadge),
          ),
          number: 2,
          badge: CalloutBadge.left,
          padding: 3,
        ),
        GuideCallout.box(
          find.byKey(ValueKey('participant-mic-${seoYeon.id}')),
          number: 3,
          badge: CalloutBadge.left,
          padding: 1,
        ),
        GuideCallout.box(
          find.byKey(ValueKey('participant-mic-${doHyun.id}')),
          number: 4,
          badge: CalloutBadge.left,
          padding: 1,
        ),
      ],
      crop: Rect.fromLTRB(
        panel.left - 16,
        panel.top - 8,
        panel.right,
        lastRow.bottom + 24,
      ),
    );
  });

  guideCapture('진행자 마이크 요청과 입장 알림', _barSurface, (tester) async {
    final session = demoSession();
    await _pumpCall(
      tester,
      (context) => _CallShell(
        title: _marketing(session).displayName(me.id),
        people: [
          _person(me, isMe: true, mic: false),
          _person(doHyun, speaking: true, host: true),
          _person(seoYeon, mic: false),
          _person(jiWoo),
        ],
        speakingIds: [doHyun.id],
        micRequested: true,
        toast: '박서연님이 들어왔습니다',
      ),
    );
    final bar = tester.getRect(find.byType(CallControlBar));
    await saveGuideShot(
      tester,
      'messenger-call-mic-request',
      callouts: [
        GuideCallout.box(
          find.byType(CallMicRequestBanner),
          number: 1,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(
          find.byType(CallToast),
          number: 2,
          badge: CalloutBadge.left,
        ),
      ],
      crop: Rect.fromLTRB(0, 0, bar.right, bar.top),
    );
  });

  guideCapture('통화 중 채팅과 스피커 보기', desktop, (tester) async {
    ignoreBenignErrors();
    final api = demoApi(
      extra: (api) => api.get(
        '/api/rooms/r-mkt/messages',
        (_) => [
          ...marketingMessages(),
          message(
            'cm1',
            'r-mkt',
            jiWoo,
            at(14, 8),
            text: '방금 말씀하신 고객사 자료 링크 여기 올려 둘게요.',
          ),
          message('cm2', 'r-mkt', me, at(14, 9), text: '감사합니다! 회의 끝나고 볼게요.'),
        ],
      ),
    );
    final session = demoSession(api: api);
    final room = _marketing(session);
    final people = _people(juneHand: false);
    await _pumpCall(
      tester,
      (context) => _CallShell(
        title: room.displayName(me.id),
        people: people,
        mode: CallViewMode.speaker,
        speakingIds: [doHyun.id],
        panel: CallPanel.chat,
        panelBody: _chatPanel(context, session, room),
      ),
    );
    await settleGuide(tester);
    await saveGuideShot(
      tester,
      'messenger-call-chat',
      callouts: [
        GuideCallout.box(
          find.byKey(ValueKey('main-${doHyun.id}')),
          number: 1,
          badge: CalloutBadge.topLeft,
          padding: 2,
        ),
        GuideCallout.box(
          find.byKey(const ValueKey('speaker-thumbnails')),
          number: 2,
          badge: CalloutBadge.topLeft,
          padding: 2,
        ),
        GuideCallout.box(
          find.byType(ChatPanel),
          number: 3,
          badge: CalloutBadge.topLeft,
          padding: -2,
        ),
        GuideCallout.box(
          _barCircle('call-chat'),
          number: 4,
          badge: CalloutBadge.topLeft,
          padding: 3,
        ),
      ],
    );
  });

  guideCapture('화이트보드', const GuideSurface(Size(960, 600)), (tester) async {
    final session = demoSession();
    final board = CallWhiteboard(myId: me.id, send: (m, {to}) async {});
    _drawSampleBoard(board);
    await _pumpCall(
      tester,
      (context) => _CallShell(
        title: _marketing(session).displayName(me.id),
        people: _people(juneHand: false),
        whiteboard: board,
      ),
    );
    Finder key(String k) => find.byKey(ValueKey(k));
    await saveGuideShot(
      tester,
      'messenger-call-whiteboard',
      callouts: [
        GuideCallout.rect(
          unionRect(tester, [
            key('whiteboard-pen'),
            key('whiteboard-eraser'),
          ], padding: 2),
          number: 1,
          badge: CalloutBadge.bottom,
        ),
        GuideCallout.rect(
          unionRect(tester, [
            key('whiteboard-color-0'),
            key('whiteboard-color-5'),
          ], padding: 2),
          number: 2,
          badge: CalloutBadge.bottom,
        ),
        GuideCallout.rect(
          unionRect(tester, [
            key('whiteboard-width-0'),
            key('whiteboard-width-2'),
          ], padding: 2),
          number: 3,
          badge: CalloutBadge.bottom,
        ),
        GuideCallout.rect(
          unionRect(tester, [
            key('whiteboard-undo'),
            key('whiteboard-clear'),
          ], padding: 2),
          number: 4,
          badge: CalloutBadge.bottom,
        ),
        GuideCallout.box(
          key('whiteboard-close'),
          number: 5,
          badge: CalloutBadge.bottom,
          padding: 2,
        ),
        GuideCallout.box(
          _barCircle('call-whiteboard'),
          number: 6,
          badge: CalloutBadge.topLeft,
          padding: 3,
        ),
      ],
    );
  });

  // ── 휴대폰 ──

  guideCapture('휴대폰 통화 화면', GuideSurface.phone, (tester) async {
    final session = demoSession();
    await _pumpCall(
      tester,
      (context) => _CallShell(
        title: _marketing(session).displayName(me.id),
        people: _people(),
        speakingIds: [doHyun.id],
        handRaised: true,
      ),
    );
    await saveGuideShot(
      tester,
      'messenger-call-phone',
      callouts: [
        GuideCallout.dot(
          _barCircle('call-mic'),
          number: 1,
          badge: CalloutBadge.top,
        ),
        GuideCallout.dot(
          _barCircle('call-camera'),
          number: 2,
          badge: CalloutBadge.top,
        ),
        GuideCallout.dot(
          _barCircle('call-participants'),
          number: 3,
          badge: CalloutBadge.top,
        ),
        GuideCallout.dot(
          _barCircle('call-chat'),
          number: 4,
          badge: CalloutBadge.top,
        ),
        GuideCallout.box(
          _barCircle('call-more'),
          number: 5,
          badge: CalloutBadge.top,
          padding: 3,
        ),
        GuideCallout.dot(
          find.byKey(const ValueKey('call-leave')),
          number: 6,
          badge: CalloutBadge.top,
        ),
      ],
    );
  });

  guideCapture('휴대폰 더보기 메뉴', GuideSurface.phone, (tester) async {
    final session = demoSession();
    await _pumpCall(
      tester,
      (context) => _CallShell(
        title: _marketing(session).displayName(me.id),
        people: _people(),
        speakingIds: [doHyun.id],
        handRaised: true,
      ),
    );
    await tester.tap(_bar('call-more'));
    await settleGuide(tester);
    final sheet = find.byType(BottomSheet);
    await saveGuideShot(
      tester,
      'messenger-call-phone-more',
      callouts: [
        GuideCallout.rect(
          tester.getRect(sheet).deflate(6),
          number: 1,
          badge: CalloutBadge.topLeft,
        ),
      ],
    );
  });

  // ── 화상회의 기록 카드 ──

  guideCapture('화상회의 기록 카드', compact, (tester) async {
    final t0 = at(14, 0);
    final t1 = at(16, 30);
    final api = demoApi(
      extra: (api) => api.get(
        '/api/rooms/r-tf/messages',
        (_) => [
          message(
            'tf1',
            'r-tf',
            doHyun,
            at(13, 50),
            text: '2시에 화상회의로 시안 같이 보겠습니다.',
          ),
          _callCardMessage('call-1', 'r-tf', t0, {
            'status': 'ended',
            'endedAt': _ms(t0.add(const Duration(minutes: 18))),
            'durationMs': const Duration(minutes: 18).inMilliseconds,
            'answered': true,
            'events': [
              _event(t0, doHyun, 'start'),
              _event(t0.add(const Duration(minutes: 1)), me, 'join'),
              _event(t0.add(const Duration(minutes: 1)), seoYeon, 'join'),
              _event(t0.add(const Duration(minutes: 2)), jiWoo, 'decline'),
              _event(t0.add(const Duration(minutes: 15)), seoYeon, 'leave'),
              _event(t0.add(const Duration(minutes: 18)), me, 'leave'),
              _event(t0.add(const Duration(minutes: 18)), doHyun, 'leave'),
            ],
          }),
          message(
            'tf2',
            'r-tf',
            seoYeon,
            at(14, 20),
            text: '회의 때 나온 수정 사항 반영해서 다시 올릴게요.',
          ),
          _callCardMessage('call-2', 'r-tf', t1, {
            'status': 'ended',
            'endedAt': _ms(t1.add(const Duration(seconds: 45))),
            'durationMs': 45000,
            'answered': false,
            'events': [_event(t1, jiWoo, 'start')],
          }),
        ],
      ),
    );
    final session = demoSession(api: api)..callsEnabled = true;
    await openDesktop(tester, roomName: '3분기 캠페인 TF', session: session);
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('call-card-call-1')),
        matching: find.byKey(const ValueKey('call-card-toggle')),
      ),
    );
    await settleGuide(tester);
    final first = tester.getRect(
      find.byKey(const ValueKey('call-card-call-1')),
    );
    final second = tester.getRect(
      find.byKey(const ValueKey('call-card-call-2')),
    );
    final panel = tester.getRect(find.byType(ChatPanel));
    await saveGuideShot(
      tester,
      'messenger-call-card',
      callouts: [
        GuideCallout.box(
          find.byKey(const ValueKey('call-card-call-1')),
          number: 1,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(
          find.byKey(const ValueKey('call-card-call-2')),
          number: 2,
          badge: CalloutBadge.left,
        ),
      ],
      crop: clampToScreen(
        tester,
        Rect.fromLTRB(
          panel.left,
          first.top - 12,
          panel.right,
          second.bottom + 16,
        ),
      ),
    );
  });

  tearDownAll(printGuideImagesSize);
}
