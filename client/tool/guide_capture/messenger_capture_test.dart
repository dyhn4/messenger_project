// 초보자용 도움말 "메신저 이용법"(server/guide/messenger.html)의 스크린샷을 찍는다.
//
// 다시 찍기(client 폴더에서):
//   flutter test tool/guide_capture/messenger_capture_test.dart
// 한 장만:
//   flutter test tool/guide_capture/messenger_capture_test.dart --plain-name "화면 구성"
// 결과: ../server/guide/images/messenger-*.png (같은 이름이면 덮어쓴다 — 앱 화면이 바뀌면
// 다시 실행한다). 그림의 빨간 번호는 messenger.html의 순서 번호와 짝이 맞아야 하므로, 번호를
// 바꾸면 HTML도 같이 고친다.
//
// 진짜 앱 화면(DesktopHomeScreen, LoginScreen, RoomListScreen 등)을 가짜 서버 응답
// (GuideFakeApi)과 예시 데이터(탱고컴퍼니 · 김민지 등 — messenger_demo.dart)로 채워 그린다
// (guide_capture.dart 참고). 토픽 만들기 · 토픽 관리 · 보드 뷰 · 토픽 폴더 그림은
// messenger_topic_capture_test.dart, 로그인 · 회원가입은 messenger_login_capture_test.dart가 찍는다.
import 'dart:io';
import 'dart:math' as math;

import 'package:client/models/app_user.dart';
import 'package:client/screens/chat_screen.dart';
import 'package:client/screens/room_list_screen.dart';
import 'package:client/screens/server_setup_screen.dart';
import 'package:client/screens/team_select_screen.dart';
import 'package:client/widgets/account_menu_button.dart';
import 'package:client/widgets/chat_input_bar.dart';
import 'package:client/widgets/chat_panel.dart';
import 'package:client/widgets/filter_dropdown.dart';
import 'package:client/widgets/hover_toolbar.dart';
import 'package:client/widgets/rich_text_format.dart';
import 'package:client/widgets/room_options_menu.dart';
import 'package:client/widgets/team_switcher.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:package_info_plus/package_info_plus.dart';

import 'guide_capture.dart';
import 'messenger_demo.dart';

void main() {
  setUpAll(() {
    // 환경설정 창의 버전 표시용(테스트 엔진에는 플랫폼 플러그인이 없다).
    // ignore: invalid_use_of_visible_for_testing_member
    PackageInfo.setMockInitialValues(
      appName: 'TangoTalk',
      packageName: 'com.tangotalk.client',
      version: '1.0.0',
      buildNumber: '1',
      buildSignature: '',
    );
  });

  // ── 1. 시작하기(로그인·회원가입은 messenger_login_capture_test.dart) ──

  guideCapture('서버 연결', const GuideSurface(Size(640, 440)), (tester) async {
    final session = demoSession(inTeam: false);
    await pumpGuideApp(tester, ServerSetupScreen(session: session));
    final address = find.widgetWithText(TextField, '서버 주소');
    final code = find.byType(TextField).at(1);
    await tester.enterText(address, 'https://192.168.0.10:3000');
    await tester.enterText(code, '4827');
    FocusManager.instance.primaryFocus?.unfocus();
    await settleGuide(tester);
    final connect = buttonWith('연결');
    await saveGuideShot(
      tester,
      'messenger-server-setup',
      callouts: [
        fieldCallout(tester, address, 1, badge: CalloutBadge.topRight),
        fieldCallout(tester, code, 2, badge: CalloutBadge.topRight),
        GuideCallout.box(connect, number: 3, badge: CalloutBadge.topRight),
      ],
      crop: clampToScreen(
        tester,
        Rect.fromLTRB(
          0,
          tester.getRect(find.textContaining('서버(npm start)')).top - 20,
          640,
          tester.getRect(connect).bottom + 24,
        ),
      ),
    );
  });

  // 창을 본문 폭(약 750px)보다 좁게 — 팀 목록은 창 폭을 따라 줄어서 양옆 빈 곳 없이 크게 보인다.
  guideCapture('팀 고르기', const GuideSurface(Size(720, 560)), (tester) async {
    ignoreBenignErrors();
    final session = demoSession(inTeam: false);
    await pumpGuideApp(tester, TeamSelectScreen(session: session));
    final create = find
        .ancestor(of: find.text('팀 생성하기'), matching: find.byType(InkWell))
        .first;
    await saveGuideShot(
      tester,
      'messenger-team-select',
      callouts: [
        GuideCallout.box(
          buttonWith('팀으로 가기'),
          number: 1,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(
          create,
          number: 2,
          badge: CalloutBadge.left,
          padding: 3,
        ),
      ],
      crop: clampToScreen(
        tester,
        Rect.fromLTRB(0, 0, 720, tester.getRect(create).bottom + 36),
      ),
    );
  });

  // ── 2. 화면 구성 ──

  guideCapture('화면 구성', desktop, (tester) async {
    await openDesktop(tester);
    final chat = tester.getRect(find.byType(ChatPanel));
    final input = tester.getRect(find.byType(ChatInputBar));
    final icons = unionRect(tester, [
      topBarButton('프로젝트'),
      topBarButton('설정'),
    ], padding: 2);
    await saveGuideShot(
      tester,
      'messenger-overview',
      callouts: [
        GuideCallout.box(
          find.byType(TeamSwitcher),
          number: 1,
          badge: CalloutBadge.right,
          padding: 6,
        ),
        GuideCallout.rect(
          tester.getRect(sidebar).deflate(4),
          number: 2,
          badge: CalloutBadge.topRight,
        ),
        GuideCallout.rect(
          Rect.fromLTRB(chat.left, chat.top, chat.right, input.top).deflate(6),
          number: 3,
          badge: CalloutBadge.topRight,
        ),
        GuideCallout.rect(
          input.deflate(3),
          number: 4,
          badge: CalloutBadge.topRight,
        ),
        GuideCallout.rect(icons, number: 5, badge: CalloutBadge.left),
      ],
    );
  });

  guideCapture('오른쪽 위 아이콘', desktop, (tester) async {
    // 방을 열지 않은 상태 — 아래쪽에 대화방 머리글(⋮)이 같이 잘려 들어오지 않게.
    await openDesktop(tester, roomName: null);
    final tips = ['프로젝트', '알림 센터', '멤버', '검색', '메뉴', '설정'];
    final row = unionRect(tester, [
      for (final t in tips) topBarButton(t),
    ], padding: 0);
    await saveGuideShot(
      tester,
      'messenger-topbar',
      callouts: [
        for (final (i, t) in tips.indexed)
          GuideCallout.box(
            topBarButton(t),
            number: i + 1,
            badge: CalloutBadge.bottom,
            padding: 1,
          ),
      ],
      crop: clampToScreen(
        tester,
        Rect.fromLTRB(
          row.left - 24,
          row.top - 14,
          row.right + 16,
          row.bottom + 44,
        ),
      ),
    );
  });

  guideCapture('내 메뉴', desktop, (tester) async {
    await openDesktop(tester, roomName: null);
    final button = topBarButton('설정');
    final buttonRect = tester.getRect(button);
    await tester.tap(button);
    await settleGuide(tester);
    Finder item(String text) => find.ancestor(
      of: find.text(text),
      matching: find.byType(PopupMenuItem<void>),
    );
    final menu = unionRect(tester, [item(me.name), item('로그아웃')], padding: 8);
    await saveGuideShot(
      tester,
      'messenger-account-menu',
      callouts: [
        GuideCallout.rect(
          buttonRect.deflate(2),
          number: 1,
          badge: CalloutBadge.left,
        ),
        menuItemCallout(tester, item(me.name), 2),
        menuItemCallout(tester, item('환경설정'), 3),
        menuItemCallout(tester, item('도움말'), 4),
        menuItemCallout(tester, item('로그아웃'), 5),
      ],
      crop: clampToScreen(
        tester,
        Rect.fromLTRB(
          tester.getRect(topBarButton('알림 센터')).left - 16,
          0,
          1280,
          menu.bottom + 20,
        ),
      ),
    );
  });

  guideCapture('팀 전환', desktop, (tester) async {
    await openDesktop(tester);
    final switcher = find.byType(TeamSwitcher);
    final switcherRect = tester.getRect(switcher);
    await tester.tap(switcher);
    await settleGuide(tester);
    Finder item(String text) => find.ancestor(
      of: find.text(text),
      matching: find.byType(PopupMenuItem<Object>),
    );
    final menu = unionRect(tester, [item('탱고컴퍼니'), item('팀 리스트')]);
    await saveGuideShot(
      tester,
      'messenger-team-switch',
      callouts: [
        GuideCallout.rect(
          switcherRect.inflate(4),
          number: 1,
          badge: CalloutBadge.right,
        ),
        menuItemCallout(tester, item('디자인랩'), 2, badge: CalloutBadge.right),
        menuItemCallout(tester, item('팀 리스트'), 3, badge: CalloutBadge.right),
      ],
      crop: clampToScreen(
        tester,
        Rect.fromLTRB(
          0,
          0,
          math.max(menu.right, switcherRect.right) + 70,
          menu.bottom + 14,
        ),
      ),
    );
  });

  // ── 3. 대화 시작하기 ──

  guideCapture('1대1 대화', desktop, (tester) async {
    await openDesktop(tester, roomName: null);
    final plus = plusButton('새 대화');
    final plusRect = tester.getRect(plus);
    await tester.tap(plus);
    await settleGuide(tester);
    final dialog = find.byType(Dialog);
    final row = find.descendant(
      of: dialog,
      matching: find.widgetWithText(ListTile, doHyun.name),
    );
    await tester.tap(row);
    await settleGuide(tester);
    final card = tester.getRect(dialogCard);
    await saveGuideShot(
      tester,
      'messenger-new-dm',
      callouts: [
        GuideCallout.rect(
          plusRect.inflate(2),
          number: 1,
          badge: CalloutBadge.top,
        ),
        GuideCallout.box(row, number: 2, badge: CalloutBadge.left),
        GuideCallout.box(
          buttonWith('대화 시작하기'),
          number: 3,
          badge: CalloutBadge.bottom,
        ),
      ],
      crop: clampToScreen(
        tester,
        Rect.fromLTRB(0, card.top - 20, card.right + 24, card.bottom + 20),
      ),
    );
  });

  guideCapture('그룹 대화', desktop, (tester) async {
    await openDesktop(tester, roomName: null);
    final plus = plusButton('새 그룹채팅');
    final plusRect = tester.getRect(plus);
    await tester.tap(plus);
    await settleGuide(tester);
    final dialog = find.byType(Dialog);
    Finder row(AppUser u) => find.descendant(
      of: dialog,
      matching: find.widgetWithText(ListTile, u.name),
    );
    for (final u in [seoYeon, junHo, yuNa]) {
      await tester.tap(row(u));
      await tester.pump();
    }
    await settleGuide(tester);
    final nameField = find.descendant(
      of: dialog,
      matching: find.byType(TextField),
    );
    await tester.enterText(nameField, '신규 캠페인 준비');
    FocusManager.instance.primaryFocus?.unfocus();
    await settleGuide(tester);
    final card = tester.getRect(dialogCard);
    await saveGuideShot(
      tester,
      'messenger-new-group',
      callouts: [
        GuideCallout.rect(
          plusRect.inflate(2),
          number: 1,
          badge: CalloutBadge.top,
        ),
        GuideCallout.rect(
          unionRect(tester, [row(seoYeon), row(yuNa)]),
          number: 2,
          badge: CalloutBadge.left,
        ),
        GuideCallout.rect(
          unionRect(tester, [
            find.descendant(of: dialog, matching: find.text('그룹 아이콘')),
            nameField,
          ], padding: 10),
          number: 3,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(
          buttonWith('대화 시작하기'),
          number: 4,
          badge: CalloutBadge.bottom,
        ),
      ],
      crop: clampToScreen(
        tester,
        Rect.fromLTRB(0, card.top - 20, card.right + 24, card.bottom + 20),
      ),
    );
  });

  // 토픽 만들기 · 참여 가능한 토픽 보기 · 멤버 초대하기 그림은 messenger_topic_capture_test.dart.

  // ── 4. 메시지 보내기 ──

  guideCapture('메시지 입력', compact, (tester) async {
    await openDesktop(tester);
    final field = find.byKey(const ValueKey('chat-input'));
    await tester.enterText(field, '회의 자료 확인했습니다. 수정본은 오후에 올릴게요!');
    await tester.pump(const Duration(milliseconds: 300));
    final input = tester.getRect(find.byType(ChatInputBar));
    final count = find.descendant(of: myLastBubble, matching: find.text('1'));
    final bubble = tester.getRect(bubbleBoxOf(myLastText));
    await saveGuideShot(
      tester,
      'messenger-send-text',
      callouts: [
        GuideCallout.box(field, number: 1, badge: CalloutBadge.topLeft),
        GuideCallout.box(
          find.byTooltip('보내기'),
          number: 2,
          badge: CalloutBadge.top,
        ),
        GuideCallout.box(count, number: 3, badge: CalloutBadge.top, padding: 5),
      ],
      crop: clampToScreen(
        tester,
        Rect.fromLTRB(input.left, bubble.top - 56, input.right, input.bottom),
      ),
    );
  });

  guideCapture('파일 보내기', compact, (tester) async {
    mockPathProvider(tester);
    await openDesktop(tester);
    final dir = Directory.systemTemp.createTempSync('guide_files_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final sheet = File('${dir.path}/고객사_반응_정리.xlsx')
      ..writeAsBytesSync(List.filled(186 * 1024, 7));
    final photo = File('${dir.path}/배너_시안.jpg')
      ..writeAsBytesSync(img.encodeJpg(bannerImage(), quality: 90));
    final state = tester.state<ChatInputBarState>(find.byType(ChatInputBar));
    await tester.runAsync(() async {
      state.addDroppedFiles([photo, sheet]);
      await Future<void>.delayed(const Duration(seconds: 3));
    });
    await tester.pump();
    // 사진 미리보기(Image.memory)는 엔진이 실제 시간에 풀어 준다 — 잠깐 실제 시간을 흘려보낸다.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 800)),
    );
    await tester.pump();
    await settleGuide(tester);
    final input = tester.getRect(find.byType(ChatInputBar));
    final cards = find.descendant(
      of: find.byType(ChatInputBar),
      matching: find.byType(ListView),
    );
    final cardsRect = tester.getRect(cards);
    await saveGuideShot(
      tester,
      'messenger-send-file',
      callouts: [
        GuideCallout.box(
          find.byTooltip('파일 보내기'),
          number: 1,
          badge: CalloutBadge.top,
        ),
        GuideCallout.rect(
          Rect.fromLTRB(
            cardsRect.left,
            cardsRect.top,
            cardsRect.left + 330,
            cardsRect.bottom,
          ).inflate(4),
          number: 2,
          badge: CalloutBadge.right,
        ),
        GuideCallout.box(
          find.byTooltip('보내기'),
          number: 3,
          badge: CalloutBadge.top,
        ),
      ],
      crop: clampToScreen(
        tester,
        Rect.fromLTRB(input.left, input.top - 16, input.right, input.bottom),
      ),
    );
  });

  guideCapture('이모티콘', compact, (tester) async {
    await openDesktop(tester);
    await tester.tap(find.byTooltip('이모티콘'));
    await settleGuide(tester);
    final input = tester.getRect(find.byType(ChatInputBar));
    final picker = byTypeName('StickerPicker');
    final pickerRect = tester.getRect(picker);
    final wink = find.descendant(of: picker, matching: find.text('😉')).first;
    await saveGuideShot(
      tester,
      'messenger-emoji-pick',
      callouts: [
        GuideCallout.box(
          find.byTooltip('이모티콘'),
          number: 1,
          badge: CalloutBadge.topRight,
        ),
        GuideCallout.box(
          wink,
          number: 2,
          badge: CalloutBadge.bottom,
          padding: 6,
        ),
      ],
      crop: clampToScreen(
        tester,
        Rect.fromLTRB(
          input.left,
          pickerRect.top - 30,
          pickerRect.right + 140,
          input.bottom,
        ),
      ),
    );
    await tester.tap(wink);
    await settleGuide(tester);
    final preview = byTypeName('StickerPreviewCard');
    final previewRect = tester.getRect(preview);
    await saveGuideShot(
      tester,
      'messenger-emoji-send',
      callouts: [
        GuideCallout.box(preview, number: 3, badge: CalloutBadge.right),
        GuideCallout.box(
          find.byTooltip('보내기'),
          number: 4,
          badge: CalloutBadge.top,
        ),
      ],
      crop: clampToScreen(
        tester,
        Rect.fromLTRB(
          input.left,
          previewRect.top - 30,
          input.right,
          input.bottom,
        ),
      ),
    );
  });

  guideCapture('글자 꾸미기', compact, (tester) async {
    await openDesktop(tester);
    await tester.tap(find.byTooltip('서식 도구'));
    await settleGuide(tester);
    final field = find.byKey(const ValueKey('chat-input'));
    const text = '이번 주 목표: 신규 가입 20% 늘리기';
    await tester.enterText(field, text);
    await tester.pump();
    final controller = tester.widget<TextField>(field).controller!;
    controller.selection = TextSelection(
      baseOffset: text.indexOf('신규'),
      extentOffset: text.length,
    );
    await tester.pump();
    await tester.tap(find.byTooltip('굵게 (Ctrl+B)'));
    await tester.pump();
    controller.selection = const TextSelection.collapsed(offset: text.length);
    await tester.pump(const Duration(milliseconds: 300));
    final input = tester.getRect(find.byType(ChatInputBar));
    await saveGuideShot(
      tester,
      'messenger-format',
      callouts: [
        GuideCallout.box(
          find.byTooltip('서식 도구 닫기'),
          number: 1,
          badge: CalloutBadge.right,
        ),
        GuideCallout.rect(
          tester.getRect(find.byType(RichFormatToolbar).first).inflate(2),
          number: 2,
          badge: CalloutBadge.topLeft,
        ),
      ],
      crop: clampToScreen(
        tester,
        Rect.fromLTRB(input.left, input.top - 20, input.right, input.bottom),
      ),
    );
  });

  guideCapture('화면 캡처', compact, (tester) async {
    final parts = createGuideTempDir();
    await openDesktop(tester);
    final button = find.byTooltip('화면 캡처');
    final buttonRect = tester.getRect(button);
    final input = tester.getRect(find.byType(ChatInputBar));
    final before = await saveGuideShot(
      tester,
      'capture-a',
      dir: parts,
      callouts: [
        GuideCallout.rect(
          buttonRect.deflate(2),
          number: 1,
          badge: CalloutBadge.top,
        ),
      ],
      crop: Rect.fromLTRB(
        input.left,
        buttonRect.top - 40,
        buttonRect.right + 90,
        input.bottom,
      ),
    );
    await tester.tap(button);
    await settleGuide(tester);
    Finder item(String text) => find.ancestor(
      of: find.text(text),
      matching: find.byType(PopupMenuItem<bool>),
    );
    final menu = unionRect(tester, [
      item('메신저 창 숨기고 캡처'),
      item('메신저 창 포함하여 캡처'),
    ], padding: 6);
    final after = await saveGuideShot(
      tester,
      'capture-b',
      dir: parts,
      callouts: [GuideCallout.rect(menu, number: 2, badge: CalloutBadge.right)],
      crop: clampToScreen(
        tester,
        Rect.fromLTRB(
          menu.left - 20,
          menu.top - 20,
          menu.right + 50,
          menu.bottom + 20,
        ),
      ),
    );
    composeShots([before, after], 'messenger-capture');
  });

  // ── 5. 메시지 활용 ──

  guideCapture('메시지 더보기 메뉴', compact, (tester) async {
    await openDesktop(tester);
    final textRect = tester.getRect(
      find.textContaining(myLastText, findRichText: true).first,
    );
    await mouseAt(tester, textRect.center);
    await tester.pump(const Duration(milliseconds: 200));
    final more = find.descendant(
      of: find.byType(HoverToolbar),
      matching: find.byIcon(Icons.more_vert),
    );
    await tester.tap(more);
    await tester.pump(const Duration(milliseconds: 300));
    final menuItems = find.byType(MenuItemButton);
    final menu = unionRect(tester, [
      menuItems.first,
      menuItems.last,
    ], padding: 8);
    final bubbleBox = tester.getRect(bubbleBoxOf(myLastText));
    await saveGuideShot(
      tester,
      'messenger-message-menu',
      callouts: [
        GuideCallout.rect(
          bubbleBox.inflate(4),
          number: 1,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(
          more,
          number: 2,
          badge: CalloutBadge.bottom,
          padding: 2,
        ),
        GuideCallout.rect(menu, number: 3, badge: CalloutBadge.right),
      ],
      crop: clampToScreen(
        tester,
        Rect.fromLTRB(
          math.max(282, bubbleBox.left - 70),
          math.min(menu.top, bubbleBox.top) - 30,
          math.max(menu.right, bubbleBox.right) + 90,
          math.max(menu.bottom, bubbleBox.bottom) + 60,
        ),
      ),
    );
  });

  guideCapture('댓글', desktop, (tester) async {
    await openDesktop(tester, api: demoApi(withComments: true));
    final caption = find.textContaining('기획안 초안', findRichText: true).first;
    final gesture = await mouseAt(tester, tester.getRect(caption).center);
    await tester.pump(const Duration(milliseconds: 200));
    final commentButton = find.descendant(
      of: find.byType(HoverToolbar),
      matching: find.byIcon(Icons.mode_comment_outlined),
    );
    await tester.tap(commentButton);
    await settleGuide(tester);
    // 오른쪽 댓글 패널이 열리며 대화 영역이 좁아졌다 — 마우스를 같은 메시지 위로 다시 옮긴다.
    await gesture.moveTo(tester.getRect(caption).center);
    await tester.pump(const Duration(milliseconds: 200));
    final thread = byTypeName('MessageThreadScreen');
    final commentField = find.descendant(
      of: thread,
      matching: find.byType(TextField),
    );
    await tester.enterText(commentField, '일정표 추가해서 다시 올렸습니다!');
    await tester.pump(const Duration(milliseconds: 300));
    final card = find.textContaining('개 댓글 모두 보기');
    await saveGuideShot(
      tester,
      'messenger-comments',
      callouts: [
        GuideCallout.box(
          commentButton.first,
          number: 1,
          badge: CalloutBadge.top,
          padding: 3,
        ),
        GuideCallout.rect(
          tester.getRect(thread).deflate(4),
          number: 2,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(commentField, number: 3, badge: CalloutBadge.left),
        GuideCallout.box(card.first, number: 4, badge: CalloutBadge.right),
      ],
      crop: clampToScreen(tester, const Rect.fromLTRB(281, 62, 1280, 800)),
    );
    // 호버·강조 타이머가 남지 않게 화면을 내리고 시간을 흘려보낸다.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  // ── 6. 알림 ──

  guideCapture('안 읽은 메시지', desktop, (tester) async {
    await openDesktop(tester);
    final header = textIn(sidebar, '토픽 4');
    final headerBadge = find.descendant(
      of: find.ancestor(of: header, matching: find.byType(Row)).first,
      matching: find.text('15'),
    );
    final roomBadge = textIn(sidebar, '12');
    final side = tester.getRect(sidebar);
    await saveGuideShot(
      tester,
      'messenger-unread',
      callouts: [
        GuideCallout.box(
          headerBadge,
          number: 1,
          badge: CalloutBadge.right,
          padding: 4,
        ),
        GuideCallout.box(
          roomBadge,
          number: 2,
          badge: CalloutBadge.right,
          padding: 4,
        ),
      ],
      crop: clampToScreen(
        tester,
        Rect.fromLTRB(
          0,
          side.top - 1,
          side.right + 1,
          tester.getRect(textIn(sidebar, '3분기 캠페인 TF')).bottom + 30,
        ),
      ),
    );
  });

  guideCapture('알림 센터', desktop, (tester) async {
    await openDesktop(tester);
    final bell = topBarButton('알림 센터');
    await tester.tap(bell);
    await settleGuide(tester);
    final panel = byTypeName('NotificationsPanel');
    final otherTeamRow = find.ancestor(
      of: find.text('디자인 리뷰'),
      matching: byTypeName('_NotificationRow'),
    );
    final panelRect = tester.getRect(panel);
    await saveGuideShot(
      tester,
      'messenger-notification-center',
      callouts: [
        // 번호는 종 아래에 — 왼쪽에 두면 바로 옆 프로젝트 아이콘을 가린다.
        GuideCallout.box(bell, number: 1, badge: CalloutBadge.bottom),
        GuideCallout.rect(
          Rect.fromLTRB(
            panelRect.left,
            panelRect.top,
            panelRect.right,
            panelRect.top + 500,
          ).deflate(4),
          number: 2,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(
          otherTeamRow,
          number: 3,
          badge: CalloutBadge.left,
          padding: 0,
        ),
      ],
      crop: clampToScreen(
        tester,
        Rect.fromLTRB(panelRect.left - 40, 0, 1280, panelRect.top + 520),
      ),
    );
  });

  guideCapture('방 메뉴', desktop, (tester) async {
    await openDesktop(tester);
    final tile = find.ancestor(
      of: textIn(sidebar, '점심 메뉴 정하기'),
      matching: find.byType(ListTile),
    );
    final tileRect = tester.getRect(tile);
    await mouseAt(tester, tileRect.center);
    // 줄의 오른쪽 아래를 누른다 — 메뉴가 누른 곳에서 열려서, 방 이름과 표시 상자를 덮지 않게.
    await tester.tapAt(
      Offset(tileRect.right - 60, tileRect.bottom - 3),
      buttons: kSecondaryMouseButton,
      kind: PointerDeviceKind.mouse,
    );
    await settleGuide(tester);
    Finder item(String text) => find.ancestor(
      of: find.text(text),
      matching: find.byWidgetPredicate((w) => w is PopupMenuItem),
    );
    final menu = unionRect(tester, [item('대화창 분할하기'), item('나가기')], padding: 8);
    await saveGuideShot(
      tester,
      'messenger-room-menu',
      callouts: [
        GuideCallout.rect(
          tileRect.deflate(1),
          number: 1,
          badge: CalloutBadge.topLeft,
        ),
        GuideCallout.rect(menu, number: 2, badge: CalloutBadge.right),
      ],
      crop: clampToScreen(
        tester,
        Rect.fromLTRB(
          0,
          math.min(tileRect.top, menu.top) - 42,
          menu.right + 70,
          math.max(tileRect.bottom, menu.bottom) + 30,
        ),
      ),
    );
  });

  // 대화방 위쪽(머리글) 오른쪽의 버튼들 — 멤버 N · 알림 · 멤버 초대 · ⋮(더보기). 내가 토픽
  // 관리자인 마케팅팀 토픽이라 ⋮ 메뉴에 "정보 변경하기"까지 보인다. 메뉴는 버튼 위를 덮으며
  // 열려서, 머리글과 메뉴를 두 장으로 나눠 찍는다.
  guideCapture('대화방 위쪽 버튼', compact, (tester) async {
    await openDesktop(
      tester,
      session: demoSession(rooms: demoRoomsWith(replace: [managedMarketing()])),
    );
    final header = find.byType(RoomOptionsMenu);
    Finder inHeader(Finder f) => find.descendant(of: header, matching: f);
    final more = inHeader(find.byTooltip('더보기'));
    final chat = tester.getRect(find.byType(ChatPanel));
    final row = tester.getRect(header);
    await saveGuideShot(
      tester,
      'messenger-room-header',
      callouts: [
        GuideCallout.box(
          inHeader(find.byTooltip('멤버')),
          number: 1,
          badge: CalloutBadge.bottom,
        ),
        GuideCallout.box(
          inHeader(find.byTooltip('알림 끄기')),
          number: 2,
          badge: CalloutBadge.bottom,
        ),
        GuideCallout.box(
          inHeader(find.byTooltip('멤버 초대')),
          number: 3,
          badge: CalloutBadge.bottom,
        ),
        GuideCallout.box(more, number: 4, badge: CalloutBadge.bottom),
      ],
      crop: Rect.fromLTRB(chat.left, row.top - 14, 1000, row.bottom + 48),
    );
    await tester.tap(more);
    await settleGuide(tester);
    final items = find.byWidgetPredicate((w) => w is PopupMenuItem);
    final menu = unionRect(tester, [items.first, items.last], padding: 8);
    await saveGuideShot(
      tester,
      'messenger-room-options',
      callouts: [GuideCallout.rect(menu, number: 5, badge: CalloutBadge.left)],
      crop: clampToScreen(
        tester,
        Rect.fromLTRB(
          menu.left - 50,
          menu.top - 20,
          menu.right + 16,
          menu.bottom + 20,
        ),
      ),
    );
  });

  // ── 7. 검색과 파일 ──

  guideCapture('검색', desktop, (tester) async {
    await openDesktop(tester);
    final searchIcon = topBarButton('검색');
    final iconRect = tester.getRect(searchIcon);
    await tester.tap(searchIcon);
    await settleGuide(tester);
    final panel = byTypeName('SearchScreen');
    final field = find.descendant(of: panel, matching: find.byType(TextField));
    await tester.enterText(field, '기획안');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await settleGuide(tester);
    final firstResult = byTypeName('_SearchResultRow').first;
    await tester.tap(firstResult);
    // 검색 결과를 누르면 그 메시지로 이동해 3초 동안 노랗게 표시된다 — 색이 바뀌는 중간에
    // 찍히지 않게 두 번에 나눠 흘려보낸다.
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump(const Duration(milliseconds: 600));
    final filterButtons = find.descendant(
      of: panel,
      matching: find.byType(FilterDropdownButton),
    );
    await saveGuideShot(
      tester,
      'messenger-search',
      callouts: [
        GuideCallout.rect(
          iconRect.deflate(2),
          number: 1,
          badge: CalloutBadge.bottom,
        ),
        GuideCallout.box(field, number: 2, badge: CalloutBadge.left),
        GuideCallout.rect(
          unionRect(tester, [filterButtons.first, filterButtons.last]),
          number: 3,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(
          firstResult,
          number: 4,
          badge: CalloutBadge.left,
          padding: 0,
        ),
        GuideCallout.box(
          bubbleBoxOf('기획안 초안'),
          number: 5,
          badge: CalloutBadge.left,
        ),
      ],
      crop: clampToScreen(tester, const Rect.fromLTRB(281, 0, 1280, 800)),
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  guideCapture('파일 모아 보기', desktop, (tester) async {
    await openDesktop(tester, roomName: null);
    final menuButton = topBarButton('메뉴');
    final menuRect = tester.getRect(menuButton);
    await tester.tap(menuButton);
    await settleGuide(tester);
    await tester.tap(find.text('파일'));
    await settleGuide(tester);
    final panel = byTypeName('FilesScreen');
    final filterButtons = find.descendant(
      of: panel,
      matching: find.byType(FilterDropdownButton),
    );
    final row = byTypeName('_FileResultRow').at(1);
    final panelRect = tester.getRect(panel);
    await saveGuideShot(
      tester,
      'messenger-files',
      callouts: [
        GuideCallout.rect(
          menuRect.deflate(2),
          number: 1,
          badge: CalloutBadge.left,
        ),
        GuideCallout.rect(
          unionRect(tester, [filterButtons.first, filterButtons.last]),
          number: 2,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(row, number: 3, badge: CalloutBadge.left, padding: 0),
      ],
      crop: clampToScreen(
        tester,
        Rect.fromLTRB(panelRect.left - 40, 0, 1280, panelRect.top + 470),
      ),
    );
  });

  // ── 8. 공지 ──

  guideCapture('공지 배너', compact, (tester) async {
    await openDesktop(tester, roomName: '전사 공지');
    final banner = byTypeName('_AnnouncementBanner');
    final bannerRect = tester.getRect(banner);
    final header = tester.getRect(find.byType(RoomOptionsMenu));
    await saveGuideShot(
      tester,
      'messenger-announcement-banner',
      callouts: [
        GuideCallout.rect(
          Rect.fromLTRB(
            bannerRect.left,
            bannerRect.top,
            bannerRect.right - 50,
            bannerRect.bottom,
          ).deflate(2),
          number: 1,
          badge: CalloutBadge.bottom,
        ),
        GuideCallout.box(
          find.byTooltip('공지 닫기'),
          number: 2,
          badge: CalloutBadge.bottom,
        ),
      ],
      crop: clampToScreen(
        tester,
        Rect.fromLTRB(
          bannerRect.left,
          header.top - 12,
          bannerRect.right,
          bannerRect.bottom + 44,
        ),
      ),
    );
  });

  guideCapture('공지 목록', desktop, (tester) async {
    await openDesktop(tester, roomName: '전사 공지');
    await tester.tap(byTypeName('_AnnouncementBanner'));
    await settleGuide(tester);
    final pinned = byTypeName('_AnnouncementTile').first;
    final card = tester.getRect(dialogCard);
    await saveGuideShot(
      tester,
      'messenger-announcement-list',
      callouts: [
        GuideCallout.box(
          pinned,
          number: 3,
          badge: CalloutBadge.left,
          padding: 6,
        ),
        GuideCallout.box(
          buttonWith('글쓰기'),
          number: 4,
          badge: CalloutBadge.left,
        ),
      ],
      crop: clampToScreen(
        tester,
        Rect.fromLTRB(
          card.left - 30,
          card.top - 24,
          card.right + 24,
          card.top + 420,
        ),
      ),
    );
  });

  // ── 9. 사람과 프로필 ──

  guideCapture('멤버와 프로필', desktop, (tester) async {
    await openDesktop(tester);
    final membersIcon = topBarButton('멤버');
    final iconRect = tester.getRect(membersIcon);
    await tester.tap(membersIcon);
    await settleGuide(tester);
    final panel = byTypeName('_MembersPanel');
    final row = find.ancestor(
      of: textIn(panel, doHyun.name),
      matching: byTypeName('_MemberRow'),
    );
    final rowRect = tester.getRect(row);
    await tester.tap(row);
    await settleGuide(tester);
    final card = tester.getRect(dialogCard);
    await saveGuideShot(
      tester,
      'messenger-member-profile',
      callouts: [
        // 번호는 아이콘 아래에 — 왼쪽에 두면 바로 옆 알림 센터(종) 아이콘을 가린다.
        GuideCallout.rect(
          iconRect.deflate(2),
          number: 1,
          badge: CalloutBadge.bottom,
        ),
        GuideCallout.rect(rowRect, number: 2, badge: CalloutBadge.left),
        GuideCallout.box(
          buttonWith('1:1 메시지'),
          number: 3,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(
          buttonWith('비밀 대화 시작'),
          number: 4,
          badge: CalloutBadge.left,
        ),
      ],
      crop: clampToScreen(tester, Rect.fromLTRB(card.left - 40, 0, 1280, 800)),
    );
  });

  guideCapture('내 프로필', desktop, (tester) async {
    await openDesktop(tester);
    await tester.tap(topBarButton('설정'));
    await settleGuide(tester);
    await tester.tap(find.text(me.name).last);
    await settleGuide(tester);
    final dialog = find.byType(Dialog);
    await saveGuideShot(
      tester,
      'messenger-my-profile',
      callouts: [
        GuideCallout.box(
          find.descendant(of: dialog, matching: find.byIcon(Icons.camera_alt)),
          number: 1,
          badge: CalloutBadge.right,
          padding: 3,
        ),
        GuideCallout.box(
          find.descendant(
            of: dialog,
            matching: find.byIcon(Icons.edit_outlined),
          ),
          number: 2,
          badge: CalloutBadge.right,
          padding: 2,
        ),
        GuideCallout.box(
          find
              .ancestor(
                of: find.text('개인정보 설정'),
                matching: find.byType(InkWell),
              )
              .first,
          number: 3,
          badge: CalloutBadge.left,
          padding: 0,
        ),
        GuideCallout.box(
          buttonWith('로그아웃'),
          number: 4,
          badge: CalloutBadge.left,
        ),
      ],
      crop: cropAround(tester, [dialogCard], margin: 30),
    );
  });

  // ── 10. 환경설정 ──

  // 환경설정 창(settings_screen.dart) — 왼쪽에서 "메신저 설정 / 시스템 설정"을 고르면 오른쪽에 그
  // 항목들이 보인다. 창을 연 뒤 창 크기를 줄여서(대화상자가 창 폭을 따라 줄어든다) 본문 폭에 맞춘다.
  guideCapture('환경설정', desktop, (tester) async {
    await openDesktop(tester);
    await tester.tap(topBarButton('설정'));
    await settleGuide(tester);
    await tester.tap(find.text('환경설정'));
    await settleGuide(tester);
    await resizeGuideWindow(tester, const Size(780, 800));
    Finder item(String label) => find
        .ancestor(of: find.text(label), matching: byTypeName('_Item'))
        .first;
    Finder nav(String label) =>
        find.ancestor(of: find.text(label), matching: byTypeName('_NavItem'));
    // 오른쪽 칸의 스크롤 영역 — 항목 상자를 이 안으로 잘라서 스크롤에 가려진 부분까지 그리지 않는다.
    Finder pane() => find
        .descendant(
          of: find.byType(Dialog),
          matching: find.byType(SingleChildScrollView),
        )
        .last;
    GuideCallout section(String label, int number) => GuideCallout.rect(
      tester
          .getRect(item(label))
          .inflate(6)
          .intersect(tester.getRect(pane()).deflate(3)),
      number: number,
      badge: CalloutBadge.left,
    );
    await saveGuideShot(
      tester,
      'messenger-settings',
      callouts: [
        GuideCallout.rect(
          unionRect(tester, [
            nav('메신저 설정'),
            nav('시스템 설정'),
          ], padding: 3),
          number: 1,
          badge: CalloutBadge.left,
        ),
        section('팀 전환 방식', 2),
        section('메시지 내용 미리보기', 3),
        section('메시지 전송 옵션 설정', 4),
        GuideCallout.box(
          buttonWith('저장하기'),
          number: 5,
          badge: CalloutBadge.left,
        ),
      ],
      crop: cropAround(tester, [dialogCard], margin: 20),
    );

    // 시스템 설정 — 항목이 길어서 오른쪽 칸이 스크롤된다. 처음 보이는 네 항목(창 전체)과, "파일
    // 다운로드"부터 보이게 내린 오른쪽 칸(다음 두 항목 — 맨 아래 버전 정보는 글로만 설명)을 따로 찍는다.
    await tester.tap(nav('시스템 설정'));
    await settleGuide(tester);
    await saveGuideShot(
      tester,
      'messenger-settings-system',
      callouts: [
        section('시작 시 자동 실행', 1),
        section('항상 위로', 2),
        section('화면 테마', 3),
        section('반투명', 4),
      ],
      crop: cropAround(tester, [dialogCard], margin: 20),
    );
    final position = tester
        .state<ScrollableState>(
          find.descendant(of: pane(), matching: find.byType(Scrollable)).first,
        )
        .position;
    final download = tester.getRect(item('파일 다운로드'));
    position.jumpTo(
      (download.top - tester.getRect(pane()).top + position.pixels - 12).clamp(
        0,
        position.maxScrollExtent,
      ),
    );
    await settleGuide(tester);
    // 오른쪽 칸만 — 스크롤 영역에 칸 제목("시스템 설정") 줄과 테두리까지 더한다.
    final scroll = tester.getRect(pane());
    await saveGuideShot(
      tester,
      'messenger-settings-system-2',
      callouts: [
        section('파일 다운로드', 5),
        section('자동 잠금', 6),
      ],
      crop: clampToScreen(
        tester,
        Rect.fromLTRB(
          scroll.left - 23,
          scroll.top - 80,
          scroll.right + 23,
          scroll.bottom + 23,
        ),
      ),
    );
  });

  // ── 11. 안드로이드 ──

  guideCapture('휴대폰 첫 화면', GuideSurface.phone, (tester) async {
    final session = demoSession();
    await pumpGuideApp(tester, RoomListScreen(session: session));
    await tester.tap(find.text('채팅'));
    await settleGuide(tester);
    await saveGuideShot(
      tester,
      'messenger-phone-home',
      callouts: [
        GuideCallout.box(
          find.byType(TeamSwitcher),
          number: 1,
          badge: CalloutBadge.bottom,
        ),
        GuideCallout.box(
          find.byTooltip('알림 센터'),
          number: 2,
          badge: CalloutBadge.bottom,
          padding: 0,
        ),
        GuideCallout.box(
          find.byTooltip('메뉴'),
          number: 3,
          badge: CalloutBadge.bottom,
          padding: 0,
        ),
        GuideCallout.box(
          find.byType(AccountMenuButton),
          number: 4,
          badge: CalloutBadge.bottom,
          padding: 0,
        ),
        GuideCallout.box(
          byTypeName('_SearchBox'),
          number: 5,
          badge: CalloutBadge.bottom,
          padding: 0,
        ),
        GuideCallout.box(
          find.byType(FloatingActionButton),
          number: 6,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(
          find.byType(NavigationBar),
          number: 7,
          badge: CalloutBadge.top,
          padding: 0,
        ),
      ],
    );
  });

  guideCapture('휴대폰 메시지 길게 누르기', GuideSurface.phone, (tester) async {
    final session = demoSession();
    await pumpGuideApp(
      tester,
      ChatScreen(
        session: session,
        room: session.rooms.firstWhere((r) => r.id == 'r-mkt'),
      ),
    );
    await settleGuide(tester);
    final bubbleRect = tester.getRect(bubbleBoxOf('다들 좋은 아침입니다'));
    // 글자 위가 아니라 말풍선 여백을 누른다(테스트 PC에서는 글자가 "마우스로 긁어 선택할 수
    // 있는 글"로 그려져서, 글자 위를 길게 누르면 글자 선택이 먼저 잡힌다).
    await tester.longPressAt(bubbleRect.topLeft + const Offset(5, 4));
    await settleGuide(tester);
    final sheet = find.byType(BottomSheet);
    await saveGuideShot(
      tester,
      'messenger-phone-long-press',
      callouts: [
        GuideCallout.rect(
          bubbleRect.inflate(4),
          number: 1,
          badge: CalloutBadge.topLeft,
        ),
        GuideCallout.rect(
          tester.getRect(sheet).deflate(6),
          number: 2,
          badge: CalloutBadge.topLeft,
        ),
      ],
    );
  });

  tearDownAll(printGuideImagesSize);
}
