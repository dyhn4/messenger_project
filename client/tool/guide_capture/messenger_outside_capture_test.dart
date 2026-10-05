// 초보자용 도움말 "메신저 이용법"의 "사내 와이파이 밖에서 쓰기" 장과 초대 링크 그림을 찍는다.
//
// 다시 찍기(client 폴더에서):
//   flutter test tool/guide_capture/messenger_outside_capture_test.dart
// 한 장만:
//   flutter test tool/guide_capture/messenger_outside_capture_test.dart --plain-name "초대 링크 만들기"
// 결과: ../server/guide/images/messenger-outside-*.png
//
// 외부 주소는 예시(tango.iptime.org)다 — 실제 주소는 회사마다 다르다. 초대 코드도 서버가 만드는
// 것과 같은 모양(24자리 16진수)의 예시 값이다.
import 'package:client/screens/login_screen.dart';
import 'package:client/screens/server_setup_screen.dart';
import 'package:client/screens/team_select_screen.dart';
import 'package:client/services/deep_link_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'guide_capture.dart';
import 'messenger_demo.dart';

const _externalAddress = 'https://tango.iptime.org:3000';
const _inviteCode = '7f3a9c2e51d84b06a1e9c3f2';

/// 테스트 엔진에는 클립보드가 없다 — "링크 복사"가 부르는 Clipboard.setData를 조용히 받아 준다.
void _mockClipboard(WidgetTester tester) {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async => null,
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
}

/// [i]번째로 뜬 대화상자(Dialog)의 카드 부분.
Finder _dialogCardAt(int i) => find
    .descendant(of: find.byType(Dialog).at(i), matching: find.byType(Material))
    .first;

/// 떠 있는 AlertDialog의 카드 부분(AlertDialog 위젯 자체는 화면 전체 크기라 잘라낼 때는 이걸 쓴다).
Finder get _alertCard => find
    .descendant(of: find.byType(AlertDialog), matching: find.byType(Material))
    .first;

/// 가짜 초대 링크(서버 invites.js 응답 모양).
Map<String, dynamic> _inviteJson(
  String id,
  String label, {
  required DateTime createdAt,
  required DateTime expiresAt,
  bool valid = true,
  int used = 0,
}) => {
  'id': id,
  'token': '${id}5d0c3b7e9a1f24680aceb1',
  'label': label,
  'createdByName': me.name,
  'createdAt': createdAt.millisecondsSinceEpoch,
  'expiresAt': expiresAt.millisecondsSinceEpoch,
  'revoked': false,
  'usedCount': used,
  'valid': valid,
  'url': 'http://192.168.0.10:3001/invite/${id}5d0c3b7e9a1f24680aceb1',
  'externalUrl':
      'http://tango.iptime.org:3001/invite/${id}5d0c3b7e9a1f24680aceb1',
};

void main() {
  // ── 밖에서 처음 연결하기: 서버 주소 변경 창(PC) ──
  guideCapture('밖에서 서버 주소 변경', const GuideSurface(Size(620, 560)), (
    tester,
  ) async {
    final session = guideSession(name: '김민지', username: 'minji.kim');
    // 초대 페이지의 "TangoTalk 열기"로 앱이 열린 것처럼 — 로그인 화면이 "서버 주소 변경" 창을
    // 외부 주소와 코드로 채워서 띄운다.
    session.setPendingPairRequest(
      const PairRequest(address: _externalAddress, code: _inviteCode),
    );
    await pumpGuideApp(tester, LoginScreen(session: session));
    await settleGuide(tester);
    FocusManager.instance.primaryFocus?.unfocus();
    await settleGuide(tester);
    final dialog = find.byType(AlertDialog);
    final address = find.descendant(
      of: dialog,
      matching: find.byType(TextField),
    );
    await saveGuideShot(
      tester,
      'messenger-outside-server-address',
      callouts: [
        fieldCallout(tester, address.at(0), 1),
        fieldCallout(tester, address.at(1), 2),
        GuideCallout.box(
          find.descendant(of: dialog, matching: buttonWith('연결')),
          number: 3,
          badge: CalloutBadge.top,
        ),
      ],
      crop: cropAround(tester, [_alertCard], margin: 8),
    );
  });

  // ── 밖에서 처음 연결하기: 휴대폰 서버 연결 화면 ──
  guideCapture('휴대폰 서버 연결(외부 주소)', GuideSurface.phone, (tester) async {
    final session = demoSession(inTeam: false);
    session.setPendingPairRequest(
      const PairRequest(address: _externalAddress, code: _inviteCode),
    );
    await pumpGuideApp(tester, ServerSetupScreen(session: session));
    FocusManager.instance.primaryFocus?.unfocus();
    await settleGuide(tester);
    final address = find.widgetWithText(TextField, '서버 주소');
    final code = find.byType(TextField).at(1);
    await saveGuideShot(
      tester,
      'messenger-outside-phone-setup',
      callouts: [
        fieldCallout(tester, address, 1, badge: CalloutBadge.topRight),
        fieldCallout(tester, code, 2, badge: CalloutBadge.topRight),
        GuideCallout.box(
          buttonWith('연결'),
          number: 3,
          badge: CalloutBadge.topRight,
        ),
      ],
      // 화면 위 제목(서버 연결)부터 연결 버튼까지 — 가운데 빈 곳은 잘라 내고 제목 줄은 남긴다.
      crop: Rect.fromLTRB(
        0,
        tester.getRect(find.textContaining('서버(npm start)')).top - 20,
        390,
        tester.getRect(buttonWith('연결')).bottom + 24,
      ),
    );
  });

  // ── 초대 링크: ☰ 메뉴 → 초대 링크 생성 → 만들기 → 복사 알림 ──
  guideCapture('초대 링크 만들기', desktop, (tester) async {
    _mockClipboard(tester);
    final now = DateTime.now();
    final created = _inviteJson(
      'a1',
      '10월 신입',
      createdAt: now,
      expiresAt: now.add(const Duration(days: 7)),
    );
    final api = demoApi(
      extra: (api) => api
        ..get('/api/invite-links', [
          _inviteJson(
            'b2',
            '9월 신입',
            createdAt: now.subtract(const Duration(days: 3)),
            expiresAt: now.add(const Duration(days: 4, hours: 2)),
            used: 3,
          ),
          _inviteJson(
            'c3',
            '8월 신입',
            createdAt: now.subtract(const Duration(days: 40)),
            expiresAt: now.subtract(const Duration(days: 33)),
            valid: false,
            used: 5,
          ),
        ])
        ..post('/api/invite-links', created),
    );
    final session = demoSession(api: api);
    // 팀 소유자에게 "초대 링크 생성"이 보인다.
    session.teams.first.isOwner = true;
    await openDesktop(tester, roomName: null, session: session);

    // 1) ☰ 메뉴
    final button = topBarButton('설정');
    final buttonRect = tester.getRect(button);
    await tester.tap(button);
    await settleGuide(tester);
    Finder item(String text) => find.ancestor(
      of: find.text(text),
      matching: find.byType(PopupMenuItem<void>),
    );
    await saveGuideShot(
      tester,
      'messenger-outside-invite-menu',
      callouts: [
        GuideCallout.rect(
          buttonRect.deflate(2),
          number: 1,
          badge: CalloutBadge.left,
        ),
        menuItemCallout(tester, item('초대 링크 생성'), 2),
      ],
      crop: clampToScreen(
        tester,
        Rect.fromLTRB(
          tester.getRect(topBarButton('알림 센터')).left - 16,
          0,
          buttonRect.right + 16,
          tester.getRect(item('로그아웃')).bottom + 16,
        ),
      ),
    );

    // 2) 초대 링크 창 → 만들기 창(두 장을 이어 붙인다)
    await tester.tap(find.text('초대 링크 생성'));
    await settleGuide(tester);
    final parts = createGuideTempDir();
    final window = _dialogCardAt(0);
    final first = await saveGuideShot(
      tester,
      'invite-window',
      dir: parts,
      callouts: [
        GuideCallout.box(
          buttonWith('초대 링크 만들기'),
          number: 3,
          badge: CalloutBadge.right,
        ),
      ],
      crop: cropAround(tester, [window], margin: 16),
    );
    await tester.tap(buttonWith('초대 링크 만들기'));
    await settleGuide(tester);
    final memo = find.widgetWithText(TextField, '메모 (선택)');
    await tester.enterText(memo, '10월 신입');
    FocusManager.instance.primaryFocus?.unfocus();
    await settleGuide(tester);
    final createDialog = find.byType(AlertDialog);
    final second = await saveGuideShot(
      tester,
      'invite-create',
      dir: parts,
      callouts: [
        fieldCallout(tester, memo, 4),
        GuideCallout.box(
          find.descendant(of: createDialog, matching: buttonWith('만들기')),
          number: 5,
          badge: CalloutBadge.top,
        ),
      ],
      crop: cropAround(tester, [_alertCard], margin: 16),
    );
    composeShots([first, second], 'messenger-outside-invite-create');

    // 3) 만들면 링크가 바로 복사되고 아래에 알림이 뜬다.
    await tester.tap(
      find.descendant(of: createDialog, matching: buttonWith('만들기')),
    );
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final toast = find.text('링크를 복사했습니다. 원하는 곳에 붙여넣어 보내세요.');
    expect(toast, findsOneWidget);
    // 창 높이를 줄여 아래쪽 알림을 초대 링크 창 가까이로 — 사이의 빈 곳이 덜 찍히게.
    tester.view.physicalSize =
        const Size(1280, 700) * tester.view.devicePixelRatio;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    final copyIcon = find.byTooltip('링크 복사').first;
    final revokeIcon = find.byTooltip('링크 취소').first;
    await saveGuideShot(
      tester,
      'messenger-outside-invite-copied',
      callouts: [
        GuideCallout.box(
          find.ancestor(of: toast, matching: find.byType(Container)).first,
          number: 6,
          badge: CalloutBadge.top,
          padding: 4,
        ),
        GuideCallout.box(
          copyIcon,
          number: 7,
          badge: CalloutBadge.top,
          padding: 0,
        ),
        GuideCallout.box(
          revokeIcon,
          number: 8,
          badge: CalloutBadge.right,
          padding: 0,
        ),
      ],
      crop: clampToScreen(
        tester,
        unionRect(tester, [window, toast], padding: 24),
      ),
    );
    // 알림이 사라질 때까지 흘려보낸다(남은 타이머가 있으면 테스트가 실패한다).
    await tester.pump(const Duration(seconds: 3));
  });

  // ── 팀 초대 링크: 팀 리스트 → 설정 → 팀 초대 링크 생성 → 팀 초대 링크 만들기 ──
  guideCapture('팀 초대 링크', desktop, (tester) async {
    ignoreBenignErrors();
    _mockClipboard(tester);
    final api = demoApi(
      extra: (api) => api..get('/api/team-invite-links', <Object>[]),
    );
    final session = demoSession(api: api, inTeam: false);
    session.teams.first.isOwner = true;
    session.canCreateTeamInviteLink = true;
    // 내 직책(대리) 이하만 부여할 수 있다 — 직책 고르기가 보이게 채운다.
    session.myPosition = '대리';
    await pumpGuideApp(tester, TeamSelectScreen(session: session));
    await tester.tap(buttonWith('설정'));
    await settleGuide(tester);
    final teamButton = buttonWith('팀 초대 링크 생성');
    final section = find.text('팀 초대 링크');
    // 제목('팀 초대 링크')과 설명까지 보이게 그 부분을 목록 가운데로 굴린다.
    // ignore: unawaited_futures
    Scrollable.ensureVisible(tester.element(section), alignment: 0.4);
    await settleGuide(tester);
    final parts = createGuideTempDir();
    final settingsCard = _dialogCardAt(0);
    final cardRect = tester.getRect(settingsCard);
    final first = await saveGuideShot(
      tester,
      'team-settings',
      dir: parts,
      callouts: [
        GuideCallout.box(teamButton, number: 1, badge: CalloutBadge.right),
      ],
      crop: Rect.fromLTRB(
        cardRect.left,
        tester.getRect(section).top - 16,
        cardRect.right,
        tester.getRect(teamButton).bottom + 16,
      ),
    );
    await tester.tap(teamButton);
    await settleGuide(tester);
    await tester.tap(buttonWith('팀 초대 링크 만들기'));
    await settleGuide(tester);
    final createDialog = find.byType(AlertDialog);
    await tester.tap(
      find.descendant(of: createDialog, matching: find.text('사원')),
    );
    await tester.enterText(
      find.widgetWithText(TextField, '메모 (선택)'),
      '10월 마케팅 신입',
    );
    FocusManager.instance.primaryFocus?.unfocus();
    await settleGuide(tester);
    final second = await saveGuideShot(
      tester,
      'team-invite-create',
      dir: parts,
      callouts: [
        GuideCallout.box(
          find.descendant(
            of: createDialog,
            matching: find.byType(DropdownButtonFormField<String>),
          ),
          number: 2,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(
          find.descendant(
            of: createDialog,
            matching: find.byWidgetPredicate((w) => w is SegmentedButton),
          ),
          number: 3,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(
          find.descendant(of: createDialog, matching: find.byType(Wrap)).first,
          number: 4,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(
          find.descendant(of: createDialog, matching: buttonWith('만들기')),
          number: 5,
          badge: CalloutBadge.top,
        ),
      ],
      crop: cropAround(tester, [_alertCard], margin: 10),
    );
    composeShots([first, second], 'messenger-outside-team-invite');
  });

  tearDownAll(printGuideImagesSize);
}
