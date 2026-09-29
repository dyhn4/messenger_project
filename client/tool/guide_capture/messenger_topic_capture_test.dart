// 초보자용 도움말 "메신저 이용법"(server/guide/messenger.html)의 토픽 그림 — 토픽 만들기 · 멤버
// 초대하기 · 참여 가능한 토픽 보기, 토픽 관리하기(참여 멤버 · 정보 변경하기 · 토픽 관리자 · 읽기
// 전용 · 보관), 보드 뷰 토픽(게시글 · 고정 · 댓글), 토픽 폴더(PC · 휴대폰)를 찍는다. 나머지 메신저
// 그림은 messenger_capture_test.dart, 예시 데이터는 messenger_demo.dart.
//
// 다시 찍기(client 폴더에서):
//   flutter test tool/guide_capture/messenger_topic_capture_test.dart
// 한 장만:
//   flutter test tool/guide_capture/messenger_topic_capture_test.dart --plain-name "보드 화면"
// 결과: ../server/guide/images/messenger-*.png — 그림의 빨간 번호는 messenger.html의 순서 번호와
// 짝이 맞아야 하므로, 번호를 바꾸면 HTML도 같이 고친다.
import 'dart:io';
import 'dart:math' as math;

import 'package:client/models/app_user.dart';
import 'package:client/models/room.dart';
import 'package:client/models/topic_folder.dart';
import 'package:client/screens/post_editor_dialog.dart';
import 'package:client/screens/room_list_screen.dart';
import 'package:client/widgets/board_view.dart';
import 'package:client/widgets/chat_panel.dart';
import 'package:client/widgets/rich_text_format.dart';
import 'package:client/widgets/room_options_menu.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'guide_capture.dart';
import 'messenger_demo.dart';

// ───────────────────────────── 예시 데이터 ─────────────────────────────

/// 내 토픽 폴더 — "우리 팀"(펼침: 마케팅팀 · 주간회의), "사내 모임"(접힘: 사내 동호회).
List<TopicFolder> demoFolders() => [
  TopicFolder(
    id: 'f-team',
    name: '우리 팀',
    position: 0,
    roomIds: ['r-mkt', 'r-weekly'],
  ),
  TopicFolder(
    id: 'f-club',
    name: '사내 모임',
    position: 1,
    collapsed: true,
    roomIds: ['r-club'],
  ),
];

/// 보드 뷰 토픽 "마케팅 자료실" — 나(김민지)와 이도현이 토픽 관리자(보드 뷰는 조용히 나가기가
/// 처음부터 켜져 있다).
Room boardTopic() => topic(
  'r-board',
  '마케팅 자료실',
  description: '캠페인 자료와 보고서를 모아 두는 게시판',
  board: true,
  quietLeave: true,
  active: at(10, 5),
  members: [me, doHyun, seoYeon, junHo, yuNa, jiWoo],
  admins: [me.id, doHyun.id],
);

/// 토픽 폴더 그림용 방 목록 — 기본 방들에 사내 동호회(폴더 안) · 보드 뷰 토픽 · 보관된 토픽을 더한다.
List<Room> folderRooms() => demoRoomsWith(
  extra: [
    topic(
      'r-club',
      '사내 동호회',
      description: '등산 · 볼링 · 보드게임 모임',
      unread: 4,
      active: at(9, 10),
    ),
    boardTopic(),
    topic(
      'r-party',
      '2025 송년회 준비',
      description: '지난 송년회 준비방',
      archived: true,
      active: at(18, 0, day: 20),
    ),
  ],
);

/// 새로 만든 토픽(서버 POST /api/rooms 응답) — 만든 사람만 멤버이고 토픽 관리자다.
Map<String, dynamic> createdTopicJson() => {
  'id': 'r-new',
  'teamId': tango.id,
  'type': 'topic',
  'name': '브랜드 리뉴얼',
  'description': '새 로고 · 색상 · 슬로건을 정하는 토픽',
  'isPublic': true,
  'members': [userJson(me)],
  'createdAt': at(11, 30).millisecondsSinceEpoch,
  'viewMode': 'chat',
  'adminIds': [me.id],
  'createdBy': me.id,
};

/// 팀 멤버 전체(멤버 초대하기 창의 목록) — 기본 인물에 아직 토픽에 없는 사람들을 더한다.
List<AppUser> teamMembers() => [...everyone, minSu, soHee, seHoon];

/// 토픽 그림용 가짜 서버 — 팀 멤버를 늘리고, 새 토픽 만들기 응답을 정해 둔다.
GuideFakeApi topicApi({void Function(GuideFakeApi api)? extra}) => demoApi(
  extra: (api) {
    extra?.call(api);
    api
      ..get('/api/teams/:id/members', [
        for (final u in teamMembers()) userJson(u),
      ])
      ..post('/api/rooms', (_) => createdTopicJson())
      ..get('/api/rooms/folders', <Object>[]);
  },
);

// ── 보드 뷰 토픽 예시 데이터 ──

/// 지금보다 [minutes]분(또는 [hours]시간 · [days]일) 전 — 게시글 카드의 "25분 전" 같은 상대 시각이
/// 다시 찍어도 같게 나오도록 지금 시각을 기준으로 잡는다.
DateTime ago({int days = 0, int hours = 0, int minutes = 0}) => DateTime.now()
    .subtract(Duration(days: days, hours: hours, minutes: minutes));

Map<String, dynamic> postComment(
  String id,
  String postId,
  AppUser sender,
  DateTime time,
  String text,
) => {
  'id': id,
  'messageId': postId,
  'roomId': 'r-board',
  'senderId': sender.id,
  'senderName': sender.name,
  'type': 'text',
  'text': text,
  'createdAt': time.millisecondsSinceEpoch,
};

/// 보드 게시글(서버 type 'post').
Map<String, dynamic> post(
  String id,
  AppUser author,
  DateTime time, {
  required String title,
  String text = '',
  bool pinned = false,
  List<Map<String, dynamic>> attachments = const [],
  List<Map<String, dynamic>> comments = const [],
}) => {
  'id': id,
  'roomId': 'r-board',
  'senderId': author.id,
  'senderName': author.name,
  'type': 'post',
  'title': title,
  'text': text,
  'createdAt': time.millisecondsSinceEpoch,
  'pinnedAt': pinned
      ? time.add(const Duration(minutes: 5)).millisecondsSinceEpoch
      : null,
  'attachments': attachments,
  'comments': comments,
};

/// 게시글 사진(썸네일 주소까지) — 사진은 [seedBoardImages]로 미리 캐시에 넣어 둔다.
Map<String, dynamic> postImage(String id) => {
  'id': 'a-$id',
  'kind': 'image',
  'fileUrl': '/uploads/$id.png',
  'fileName': '$id.png',
  'fileSize': 820 * 1024,
  'thumbnailUrl': '/uploads/${id}_t.jpg',
};

Map<String, dynamic> postFile(String id, String name, int kb) => {
  'id': 'a-$id',
  'kind': 'file',
  'fileUrl': '/uploads/$id',
  'fileName': name,
  'fileSize': kb * 1024,
};

const resultTitle = '3분기 캠페인 결과 보고';

/// 게시글들 — 고정 4개(맨 위 "고정된 게시글"에는 3개만 보이고 "더 보기")와 최근 글 2개.
List<Map<String, dynamic>> boardPosts() => [
  post(
    'p4',
    jiWoo,
    ago(days: 12),
    title: '고객사 미팅 체크리스트',
    text: '미팅 전에 확인할 항목을 정리했습니다.',
    pinned: true,
  ),
  post(
    'p3',
    yuNa,
    ago(days: 8),
    title: '보도자료 작성 양식',
    text: '보도자료는 이 양식으로 작성해 주세요.',
    pinned: true,
    attachments: [postFile('f-press', '보도자료_양식.docx', 42)],
  ),
  post(
    'p2',
    seoYeon,
    ago(days: 5),
    title: '브랜드 가이드라인 v2',
    text: '로고 · 색상 · 글꼴 규칙이 바뀌었습니다.',
    pinned: true,
    attachments: [postFile('f-guide', '브랜드_가이드라인_v2.pdf', 3200)],
    comments: [
      postComment('c21', 'p2', me, ago(days: 5), '잘 봤습니다!'),
    ],
  ),
  post(
    'p1',
    doHyun,
    ago(days: 2),
    title: '[필독] 10월 마케팅 일정표',
    text: '10월 캠페인 · 행사 일정입니다. 일정이 바뀌면 이 글을 고칩니다.',
    pinned: true,
    comments: [
      postComment('c11', 'p1', junHo, ago(days: 2), '확인했습니다.'),
      postComment('c12', 'p1', yuNa, ago(days: 1), '14일 행사 장소도 추가해 주세요.'),
      postComment('c13', 'p1', doHyun, ago(days: 1), '반영했습니다 🙂'),
    ],
  ),
  post(
    'p6',
    junHo,
    ago(hours: 3),
    title: '신제품 촬영 일정 안내',
    text: '신제품 사진 촬영은 다음 주 화요일 오후 2시, 3층 스튜디오에서 합니다.',
  ),
  post(
    'p5',
    me,
    ago(minutes: 25),
    title: resultTitle,
    text:
        '3분기 캠페인 결과를 정리했습니다.\n'
        '신규 가입은 목표보다 12% 많았고, 광고 클릭률도 함께 올랐습니다.\n'
        '자세한 수치는 첨부한 엑셀 파일을 확인해 주세요.',
    attachments: [
      postImage('chart-signup'),
      postImage('chart-click'),
      postImage('banner-final'),
      postFile('f-result', '3분기_캠페인_결과.xlsx', 186),
    ],
    comments: [
      postComment(
        'c51',
        'p5',
        doHyun,
        ago(minutes: 12),
        '정리 감사합니다! 4분기 계획에 반영하겠습니다.',
      ),
      postComment(
        'c52',
        'p5',
        jiWoo,
        ago(minutes: 5),
        '영업팀에서 받은 고객 반응도 댓글로 덧붙여 둘게요.',
      ),
    ],
  ),
];

/// 막대그래프 모양의 예시 사진(게시글 첨부).
img.Image chartImage(List<int> bars, img.Color color) {
  final image = img.Image(width: 480, height: 360);
  img.fill(image, color: img.ColorRgb8(248, 249, 252));
  img.drawLine(
    image,
    x1: 40,
    y1: 320,
    x2: 450,
    y2: 320,
    color: img.ColorRgb8(170, 176, 190),
    thickness: 3,
  );
  for (final (i, h) in bars.indexed) {
    final x = 70 + i * 76;
    img.fillRect(image, x1: x, y1: 320 - h, x2: x + 46, y2: 318, color: color);
  }
  return image;
}

/// 보드 그림의 사진 썸네일을 이미지 캐시에 넣는다(서버 없이도 사진이 보이게).
Future<void> seedBoardImages(WidgetTester tester) async {
  const base = 'https://192.168.0.10:3000';
  await seedGuideNetworkImage(
    tester,
    '$base/uploads/chart-signup_t.jpg',
    chartImage([120, 160, 150, 210, 260], img.ColorRgb8(76, 110, 245)),
  );
  await seedGuideNetworkImage(
    tester,
    '$base/uploads/chart-click_t.jpg',
    chartImage([90, 140, 190, 170, 230], img.ColorRgb8(18, 184, 134)),
  );
  await seedGuideNetworkImage(
    tester,
    '$base/uploads/banner-final_t.jpg',
    bannerImage(),
  );
}

/// 보드 그림용 가짜 서버 — 게시글 목록과 고정된 게시글.
GuideFakeApi boardApi() => topicApi(
  extra: (api) {
    final posts = boardPosts();
    api
      ..get('/api/rooms/r-board/messages', (_) => posts)
      ..get('/api/rooms/r-board/pinned-posts', (_) {
        final pinned = posts.where((p) => p['pinnedAt'] != null).toList()
          ..sort(
            (a, b) => (b['createdAt'] as int).compareTo(a['createdAt'] as int),
          );
        return pinned;
      });
  },
);

/// 보드 뷰 토픽을 연 PC 화면.
Future<void> openBoard(WidgetTester tester) async {
  mockPathProvider(tester);
  await seedBoardImages(tester);
  await openDesktop(
    tester,
    roomName: '마케팅 자료실',
    session: demoSession(
      api: boardApi(),
      rooms: demoRoomsWith(extra: [boardTopic()]),
    ),
  );
  // 사진 썸네일이 나타나는 애니메이션까지 흘려보낸다.
  await settleGuide(tester);
}

/// 토픽 폴더 그림용 PC 화면 — 방을 열지 않고, 사이드바의 토픽 칸을 아래로 늘려(칸 사이 가로줄을
/// 끌어서) 폴더와 "보관된 토픽"까지 한 번에 보이게 한다.
Future<void> openFolders(WidgetTester tester) async {
  await openDesktop(
    tester,
    roomName: null,
    session: demoSession(rooms: folderRooms(), folders: demoFolders()),
  );
  await tester.drag(
    byTypeName('_ResizeDivider').first,
    const Offset(0, 170),
  );
  await settleGuide(tester);
}

// ───────────────────────────── 캡처 ─────────────────────────────

/// 대화상자를 크게 여는 PC 창 — 세로를 늘려 대화상자가 자기 최대 높이까지 커지게 한다(대화상자만
/// 잘라 쓴다). 그래도 안쪽이 스크롤되는 긴 창은 위 · 아래 두 장으로 나눠 찍는다.
const tall = GuideSurface(Size(1280, 1000));

void main() {
  // ── 3. 대화 시작하기: 토픽 만들기 · 멤버 초대하기 · 참여 가능한 토픽 보기 ──

  guideCapture('토픽 메뉴', desktop, (tester) async {
    final parts = createGuideTempDir();
    await openDesktop(tester, roomName: null);
    final plus = plusButton('토픽 추가');
    final plusRect = tester.getRect(plus);
    final header = tester.getRect(textIn(sidebar, '토픽 4'));
    final before = await saveGuideShot(
      tester,
      'topic-menu-a',
      dir: parts,
      callouts: [
        GuideCallout.rect(
          plusRect.inflate(2),
          number: 1,
          badge: CalloutBadge.left,
        ),
      ],
      crop: Rect.fromLTRB(
        0,
        header.top - 26,
        282,
        tester.getRect(textIn(sidebar, '마케팅팀')).bottom + 14,
      ),
    );
    await tester.tap(plus);
    await settleGuide(tester);
    Finder item(String text) => find.ancestor(
      of: find.text(text),
      matching: find.byType(PopupMenuItem<void>),
    );
    final menu = unionRect(tester, [item('새로운 토픽 생성하기'), item('폴더 생성')]);
    final after = await saveGuideShot(
      tester,
      'topic-menu-b',
      dir: parts,
      // 나머지 두 항목(참여 가능한 토픽 보기 · 폴더 생성)에는 번호를 달지 않는다 — 바로 다음 그림
      // (새로운 토픽 생성하기 창)의 번호와 겹치지 않게. 각각 다른 절에서 설명한다.
      callouts: [
        menuItemCallout(tester, item('새로운 토픽 생성하기'), 2, badge: CalloutBadge.right),
      ],
      crop: clampToScreen(
        tester,
        Rect.fromLTRB(
          menu.left - 6,
          menu.top - 20,
          menu.right + 50,
          menu.bottom + 20,
        ),
      ),
    );
    composeShots([before, after], 'messenger-topic-menu');
  });

  guideCapture('새로운 토픽 생성하기', tall, (tester) async {
    await openDesktop(
      tester,
      roomName: null,
      session: demoSession(api: topicApi(), folders: demoFolders()),
    );
    await tester.tap(plusButton('토픽 추가'));
    await settleGuide(tester);
    await tester.tap(find.text('새로운 토픽 생성하기'));
    await settleGuide(tester);
    final name = find.byKey(const ValueKey('create-topic-name'));
    final desc = find.byKey(const ValueKey('create-topic-description'));
    final folder = find.byKey(const ValueKey('create-topic-folder'));
    final submit = find.byKey(const ValueKey('create-topic-submit'));
    await tester.enterText(name, '브랜드 리뉴얼');
    await tester.enterText(desc, '새 로고 · 색상 · 슬로건을 정하는 토픽');
    // 폴더 선택 — "우리 팀" 폴더에 바로 넣기.
    await tester.tap(folder);
    await settleGuide(tester);
    await tester.tap(find.text('우리 팀').last);
    await settleGuide(tester);
    FocusManager.instance.primaryFocus?.unfocus();
    await settleGuide(tester);
    // 창 안의 스크롤 영역 — 항목 상자를 이 안으로 잘라서 가려진 부분까지 그리지 않는다.
    final scrollView = find
        .descendant(
          of: find.byType(Dialog),
          matching: find.byType(SingleChildScrollView),
        )
        .first;
    // 굵은 항목 이름("토픽 설명  (선택)"처럼 뒤에 회색 "(선택)"이 붙기도 한다).
    Finder label(String text) => find.byWidgetPredicate(
      (w) =>
          w is RichText &&
          (w.text.toPlainText() == text ||
              w.text.toPlainText().startsWith('$text  (')),
    );
    // 위아래만 자른다 — 스크롤 영역은 왼쪽 여백이 없어서 좌우까지 자르면 선이 글자에 붙는다. 위쪽은
    // 스크롤 영역보다 조금(6px) 더 올라가도 된다 — 맨 위 항목 이름(스크롤 영역 맨 위에 붙어 있다)을
    // 상자 선이 가르지 않게.
    GuideCallout area(List<Finder> parts, int number) {
      final r = unionRect(tester, parts, padding: 5);
      final view = tester.getRect(scrollView);
      return GuideCallout.rect(
        Rect.fromLTRB(
          r.left,
          math.max(r.top, view.top - 6),
          r.right,
          math.min(r.bottom, view.bottom - 2),
        ),
        number: number,
        badge: CalloutBadge.left,
      );
    }
    final card = tester.getRect(dialogCard);
    // 창이 길어서(설정이 많다) 안쪽이 스크롤된다 — 위쪽(이름~토픽 설명)과, 끝까지 내린 아래쪽
    // (폴더 선택~생성)을 두 장으로 나눠 찍는다.
    await saveGuideShot(
      tester,
      'messenger-topic-create',
      callouts: [
        area([label('이름'), name], 3),
        area([
          label('보기 방식'),
          find.byKey(const ValueKey('create-topic-view-board')),
          find.textContaining('보기 방식은 만든 뒤에'),
        ], 4),
        area([
          label('공개 여부'),
          find.byKey(const ValueKey('create-topic-private')),
        ], 5),
        area([label('토픽 설명'), desc], 6),
      ],
      crop: Rect.fromLTRB(
        card.left - 24,
        card.top - 20,
        card.right + 24,
        tester.getRect(desc).bottom + 40,
      ),
    );
    final scrollable = find
        .descendant(of: scrollView, matching: find.byType(Scrollable))
        .first;
    final position = tester.state<ScrollableState>(scrollable).position;
    position.jumpTo(position.maxScrollExtent);
    await settleGuide(tester);
    await saveGuideShot(
      tester,
      'messenger-topic-create-2',
      callouts: [
        area([label('폴더 선택'), folder], 7),
        area([
          find.byKey(const ValueKey('create-topic-auto-invite')),
          find.byKey(const ValueKey('create-topic-read-only')),
        ], 8),
        GuideCallout.box(submit, number: 9, badge: CalloutBadge.top),
      ],
      crop: Rect.fromLTRB(
        card.left - 24,
        tester.getRect(label('폴더 선택')).top - 36,
        card.right + 24,
        card.bottom + 20,
      ),
    );

    // 생성 → 만든 토픽이 열리고 "멤버 초대하기" 창이 바로 뜬다(만든 사람만 멤버라서).
    await tester.tap(submit);
    await settleGuide(tester);
    expect(find.text('멤버 초대하기'), findsWidgets);
    // 대화상자는 창 폭을 따라 줄어든다 — 두 칸(팀 멤버 · 선택된 멤버)이 유지되는 폭까지 좁힌다.
    await resizeGuideWindow(tester, const Size(770, 860));
    for (final u in [doHyun, minSu, soHee]) {
      await tester.tap(find.byKey(ValueKey('invite-member-${u.id}')));
      await tester.pump();
    }
    await settleGuide(tester);
    final dialog = find.byType(Dialog);
    Finder inDialog(Finder f) => find.descendant(of: dialog, matching: f);
    Rect labeled(String text, Finder field) =>
        unionRect(tester, [inDialog(find.text(text)), field], padding: 4);
    final memberList = inDialog(find.byType(ListView)).first;
    final selectedPane = unionRect(tester, [
      inDialog(find.textContaining('선택된 멤버 ')),
      find.byKey(ValueKey('invite-selected-${soHee.id}')),
    ], padding: 4);
    await saveGuideShot(
      tester,
      'messenger-invite-members',
      callouts: [
        GuideCallout.rect(
          labeled('멤버 검색', find.byKey(const ValueKey('invite-search'))),
          number: 1,
          badge: CalloutBadge.left,
        ),
        GuideCallout.rect(
          labeled('직책', find.byKey(const ValueKey('invite-position'))),
          number: 2,
          badge: CalloutBadge.topRight,
        ),
        GuideCallout.box(
          buttonWith('검색 조건 초기화'),
          number: 3,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(
          find.byKey(const ValueKey('invite-select-all')),
          number: 4,
          badge: CalloutBadge.left,
        ),
        GuideCallout.rect(
          tester.getRect(memberList).deflate(2),
          number: 5,
          badge: CalloutBadge.left,
        ),
        GuideCallout.rect(selectedPane, number: 6, badge: CalloutBadge.right),
        GuideCallout.box(
          buttonWith('초대하기 (3)'),
          number: 7,
          badge: CalloutBadge.top,
        ),
      ],
      crop: cropAround(tester, [dialogCard], margin: 18),
    );
  });

  guideCapture('참여 가능한 토픽 보기', desktop, (tester) async {
    await openDesktop(tester, roomName: null);
    await tester.tap(plusButton('토픽 추가'));
    await settleGuide(tester);
    await tester.tap(find.text('참여 가능한 토픽 보기'));
    await settleGuide(tester);
    final dialog = find.byType(Dialog);
    Finder inDialog(Finder f) => find.descendant(of: dialog, matching: f);
    Finder row(String id) => find.byKey(ValueKey('topic-browse-$id'));
    final boardName = unionRect(tester, [
      find.descendant(of: row('r-design'), matching: find.text('디자인 가이드')),
      find.descendant(of: row('r-design'), matching: find.text('보드 뷰')),
    ], padding: 4);
    await saveGuideShot(
      tester,
      'messenger-topic-browse',
      callouts: [
        GuideCallout.box(
          find.byKey(const ValueKey('topic-browse-search')),
          number: 1,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(
          buttonWith('새로운 토픽 생성하기'),
          number: 2,
          badge: CalloutBadge.top,
        ),
        GuideCallout.rect(
          tester.getRect(inDialog(find.byType(TabBar))).deflate(1),
          number: 3,
          badge: CalloutBadge.left,
        ),
        GuideCallout.rect(boardName, number: 4, badge: CalloutBadge.right),
        GuideCallout.box(
          find
              .ancestor(
                of: find.descendant(
                  of: row('r-club'),
                  matching: find.text('참여하기'),
                ),
                matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
              )
              .first,
          number: 5,
          badge: CalloutBadge.left,
        ),
      ],
      crop: cropAround(tester, [dialogCard], margin: 24),
    );
  });

  // ── 토픽 관리하기 ──

  guideCapture('참여 멤버', desktop, (tester) async {
    await openDesktop(
      tester,
      session: demoSession(
        api: topicApi(),
        rooms: demoRoomsWith(replace: [managedMarketing()]),
      ),
    );
    await tester.tap(
      find.descendant(
        of: find.byType(RoomOptionsMenu),
        matching: find.byTooltip('멤버'),
      ),
    );
    await settleGuide(tester);
    Finder row(AppUser u) => find.byKey(ValueKey('topic-member-${u.id}'));
    await saveGuideShot(
      tester,
      'messenger-topic-members',
      callouts: [
        GuideCallout.box(
          find.byKey(const ValueKey('topic-members-search')),
          number: 1,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(
          buttonWith('멤버 초대하기'),
          number: 2,
          badge: CalloutBadge.left,
        ),
        GuideCallout.rect(
          unionRect(tester, [row(me), row(seHoon)], padding: 2),
          number: 3,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(
          find.descendant(of: row(junHo), matching: find.text('내보내기')),
          number: 4,
          badge: CalloutBadge.right,
        ),
      ],
      crop: cropAround(tester, [dialogCard], margin: 24),
    );
  });

  guideCapture('토픽 정보 변경하기', tall, (tester) async {
    await openDesktop(
      tester,
      session: demoSession(
        api: topicApi(),
        rooms: demoRoomsWith(replace: [managedMarketing()]),
      ),
    );
    await tester.tap(
      find.descendant(
        of: find.byType(RoomOptionsMenu),
        matching: find.byTooltip('더보기'),
      ),
    );
    await settleGuide(tester);
    await tester.tap(find.text('정보 변경하기'));
    await settleGuide(tester);
    final dialog = find.byType(Dialog);
    Finder inDialog(Finder f) => find.descendant(of: dialog, matching: f);
    final scrollView = inDialog(find.byType(SingleChildScrollView)).first;
    Finder label(String text) => find.byWidgetPredicate(
      (w) =>
          w is RichText &&
          (w.text.toPlainText() == text ||
              w.text.toPlainText().startsWith('$text  (')),
    );
    GuideCallout area(List<Finder> parts, int number) {
      final r = unionRect(tester, parts, padding: 5);
      final view = tester.getRect(scrollView);
      return GuideCallout.rect(
        Rect.fromLTRB(
          r.left,
          math.max(r.top, view.top - 6),
          r.right,
          math.min(r.bottom, view.bottom - 2),
        ),
        number: number,
        badge: CalloutBadge.left,
      );
    }

    final tabs = inDialog(find.byType(TabBar));
    final card = tester.getRect(dialogCard);
    await saveGuideShot(
      tester,
      'messenger-topic-settings',
      callouts: [
        GuideCallout.rect(
          tester.getRect(tabs).deflate(1),
          number: 1,
          badge: CalloutBadge.left,
        ),
        area([
          label('이름'),
          find.byKey(const ValueKey('topic-settings-description')),
        ], 2),
        area([
          label('보기 방식'),
          find.byKey(const ValueKey('topic-settings-view-mode')),
        ], 3),
        area([
          label('공개 여부'),
          find.byKey(const ValueKey('topic-settings-private')),
        ], 4),
      ],
      crop: cropAround(tester, [dialogCard], margin: 24),
    );

    // 끝까지 내리면 설정 스위치 · 저장과 보관 · 삭제 칸이 보인다.
    final position = tester
        .state<ScrollableState>(
          find
              .descendant(of: scrollView, matching: find.byType(Scrollable))
              .first,
        )
        .position;
    position.jumpTo(position.maxScrollExtent);
    await settleGuide(tester);
    final view = tester.getRect(scrollView);
    await saveGuideShot(
      tester,
      'messenger-topic-settings-2',
      callouts: [
        area([
          find.byKey(const ValueKey('topic-settings-quiet-leave')),
          find.byKey(const ValueKey('topic-settings-read-only')),
        ], 5),
        GuideCallout.box(
          find.byKey(const ValueKey('topic-settings-save')),
          number: 6,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(
          find.byKey(const ValueKey('topic-settings-archive')),
          number: 7,
          badge: CalloutBadge.right,
        ),
        GuideCallout.box(
          find.byKey(const ValueKey('topic-settings-delete')),
          number: 8,
          badge: CalloutBadge.right,
        ),
      ],
      crop: Rect.fromLTRB(
        card.left - 24,
        view.top - 16,
        card.right + 24,
        card.bottom + 20,
      ),
    );

    // 두 번째 탭 — 토픽 관리자 지정(체크한 사람이 토픽 관리자). 한지우를 새로 체크해 둔다.
    await tester.tap(inDialog(find.text('토픽 멤버 관리')));
    await settleGuide(tester);
    await tester.tap(find.byKey(ValueKey('topic-admin-${jiWooOwner.id}')));
    await settleGuide(tester);
    final segments = inDialog(
      find.byWidgetPredicate((w) => w is SegmentedButton),
    );
    final list = inDialog(find.byType(ListView)).first;
    await saveGuideShot(
      tester,
      'messenger-topic-admins',
      callouts: [
        GuideCallout.box(
          inDialog(find.text('토픽 멤버 관리')),
          number: 1,
          badge: CalloutBadge.right,
          padding: 8,
        ),
        GuideCallout.box(segments, number: 2, badge: CalloutBadge.left),
        GuideCallout.rect(
          tester.getRect(list).deflate(2),
          number: 3,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(
          find.byKey(const ValueKey('topic-admins-save')),
          number: 4,
          badge: CalloutBadge.left,
        ),
      ],
      crop: cropAround(tester, [dialogCard], margin: 24),
    );
  });

  // 읽기 전용 토픽을 일반 멤버(토픽 관리자 아님)가 본 모습 — 입력칸 대신 안내가 보인다.
  guideCapture('읽기 전용 토픽', compact, (tester) async {
    final notice = demoRooms().firstWhere((r) => r.id == 'r-notice');
    await openDesktop(
      tester,
      roomName: '전사 공지',
      session: demoSession(
        rooms: demoRoomsWith(
          replace: [
            topic(
              'r-notice',
              '전사 공지',
              description: notice.description,
              favorite: true,
              active: at(8, 30),
              announcement: notice.latestAnnouncement,
              readOnly: true,
              admins: [yuNa.id],
            ),
          ],
        ),
      ),
    );
    final chat = tester.getRect(find.byType(ChatPanel));
    final header = tester.getRect(find.byType(RoomOptionsMenu));
    await saveGuideShot(
      tester,
      'messenger-topic-read-only',
      callouts: [
        GuideCallout.box(
          find.byKey(const ValueKey('topic-chip-read-only')),
          number: 1,
          badge: CalloutBadge.right,
        ),
        GuideCallout.box(
          find.byKey(const ValueKey('chat-input-read-only-notice')),
          number: 2,
          badge: CalloutBadge.top,
        ),
      ],
      crop: clampToScreen(
        tester,
        Rect.fromLTRB(chat.left, header.top - 14, chat.right, chat.bottom),
      ),
    );
  });

  // ── 보드 뷰 토픽 ──

  guideCapture('보드 화면', const GuideSurface(Size(1000, 800)), (tester) async {
    await openBoard(tester);
    final chat = tester.getRect(find.byType(ChatPanel));
    final header = tester.getRect(find.byType(RoomOptionsMenu));
    final card = find.byKey(const ValueKey('post-p5'));
    await saveGuideShot(
      tester,
      'messenger-board',
      callouts: [
        GuideCallout.box(
          find.byKey(const ValueKey('topic-chip-board')),
          number: 1,
          badge: CalloutBadge.right,
        ),
        GuideCallout.box(
          find.byKey(const ValueKey('board-pinned')),
          number: 2,
          badge: CalloutBadge.left,
          padding: 6,
        ),
        GuideCallout.box(
          card,
          number: 3,
          badge: CalloutBadge.left,
          padding: 3,
        ),
        GuideCallout.rect(
          unionRect(tester, [
            find.descendant(
              of: card,
              matching: find.byIcon(Icons.mode_comment_outlined),
            ),
            find.descendant(of: card, matching: find.text('댓글 2')),
          ], padding: 5),
          number: 4,
          badge: CalloutBadge.right,
        ),
        GuideCallout.box(
          find.byKey(const ValueKey('board-compose')),
          number: 5,
          badge: CalloutBadge.top,
        ),
      ],
      crop: clampToScreen(
        tester,
        Rect.fromLTRB(chat.left, header.top - 14, chat.right, chat.bottom),
      ),
    );
  });

  guideCapture('게시글 작성', desktop, (tester) async {
    await openBoard(tester);
    await tester.tap(find.byKey(const ValueKey('board-compose')));
    await settleGuide(tester);
    // 대화상자는 창 크기를 따라 줄어든다 — 본문 폭(약 750px)에 들어가게 창을 좁힌다.
    await resizeGuideWindow(tester, const Size(740, 800));
    await tester.enterText(
      find.byKey(const ValueKey('post-title')),
      '10월 SNS 이벤트 기획안',
    );
    await tester.enterText(
      find.byKey(const ValueKey('post-body')),
      '10월 둘째 주에 시작할 SNS 이벤트 기획안입니다.\n'
      '참여 방법과 경품은 첨부한 기획안에 정리했습니다.\n'
      '의견은 댓글로 남겨 주세요!',
    );
    final dir = Directory.systemTemp.createTempSync('guide_post_');
    addTearDown(() {
      // 사진 미리보기가 파일을 잠깐 붙잡고 있을 수 있다 — 못 지우면 운영체제 임시 폴더 정리에 맡긴다.
      try {
        dir.deleteSync(recursive: true);
      } on FileSystemException catch (_) {}
    });
    final banner = File('${dir.path}/이벤트_배너.png')
      ..writeAsBytesSync(img.encodePng(bannerImage()));
    final plan = File('${dir.path}/SNS_이벤트_기획안.pptx')
      ..writeAsBytesSync(List.filled(2400 * 1024, 7));
    final editor = tester.state<PostEditorState>(find.byType(PostEditor));
    // 첨부는 붙이자마자 올라간다(가짜 서버) — 사진 미리보기와 업로드는 실제 시간으로 흘려보낸다.
    await tester.runAsync(() async {
      editor.addFiles([banner, plan]);
      await Future<void>.delayed(const Duration(seconds: 3));
    });
    // 사진 미리보기(Image.file)는 파일 읽기와 그림 풀기가 실제 시간에 번갈아 일어난다 — 실제
    // 시간과 화면 그리기를 몇 번 번갈아 흘려보낸다.
    for (var i = 0; i < 6; i++) {
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
    }
    await settleGuide(tester);
    final dialog = find.byType(Dialog);
    Finder inDialog(Finder f) => find.descendant(of: dialog, matching: f);
    final body = find.byKey(const ValueKey('post-body'));
    await saveGuideShot(
      tester,
      'messenger-post-editor',
      callouts: [
        GuideCallout.box(
          find.byKey(const ValueKey('post-title')),
          number: 1,
          badge: CalloutBadge.left,
          padding: 3,
        ),
        GuideCallout.rect(
          unionRect(tester, [
            inDialog(find.byType(RichFormatToolbar)),
            body,
          ], padding: 3),
          number: 2,
          badge: CalloutBadge.left,
        ),
        GuideCallout.rect(
          unionRect(tester, [
            inDialog(find.text('첨부 파일')),
            find.byKey(const ValueKey('post-attach')),
            byTypeName('_ImageDraftTile'),
            byTypeName('_FileDraftTile'),
          ], padding: 6),
          number: 3,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(
          find.byKey(const ValueKey('post-submit')),
          number: 4,
          badge: CalloutBadge.top,
        ),
      ],
      crop: cropAround(tester, [find.byType(PostEditor)], margin: 18),
    );
  });

  guideCapture('게시글 메뉴', const GuideSurface(Size(1000, 800)), (tester) async {
    await openBoard(tester);
    final card = find.byKey(const ValueKey('post-p5'));
    final more = find.descendant(of: card, matching: find.byTooltip('더보기'));
    final cardRect = tester.getRect(card);
    await tester.tap(more);
    await settleGuide(tester);
    final items = find.byType(MenuItemButton);
    final menu = unionRect(tester, [items.first, items.last], padding: 6);
    await saveGuideShot(
      tester,
      'messenger-post-menu',
      callouts: [
        GuideCallout.box(more, number: 1, badge: CalloutBadge.top, padding: 1),
        GuideCallout.rect(menu, number: 2, badge: CalloutBadge.left),
      ],
      crop: clampToScreen(
        tester,
        Rect.fromLTRB(
          cardRect.left - 12,
          cardRect.top - 14,
          math.max(cardRect.right, menu.right) + 14,
          math.max(cardRect.top + 170, menu.bottom + 16),
        ),
      ),
    );
  });

  guideCapture('게시글 상세', tall, (tester) async {
    await openBoard(tester);
    await tester.tap(find.text(resultTitle).first);
    await settleGuide(tester);
    final panel = byTypeName('MessageThreadScreen');
    final panelRect = tester.getRect(panel);
    final head = find.byType(PostDetailHead);
    final commentField = find.descendant(
      of: panel,
      matching: find.byType(TextField),
    );
    await tester.enterText(commentField, '수고 많으셨습니다! 🎉');
    await tester.pump(const Duration(milliseconds: 300));
    final title = find.descendant(of: head, matching: find.text(resultTitle));
    final text = find.descendant(
      of: head,
      matching: find.textContaining('3분기 캠페인 결과를 정리했습니다', findRichText: true),
    );
    final images = byTypeName('ChatImageAttachments');
    final files = byTypeName('ChatFileAttachments');
    // 댓글 묶음 — "댓글 2" 제목부터 마지막 댓글까지(목록이 보이는 곳 안으로 자른다).
    final list = tester.getRect(
      find.descendant(of: panel, matching: find.byType(ListView)).first,
    );
    final lastComment = tester.getRect(
      find.textContaining('고객 반응도', findRichText: true).first,
    );
    await saveGuideShot(
      tester,
      'messenger-post-detail',
      callouts: [
        GuideCallout.rect(
          unionRect(tester, [title, text], padding: 6),
          number: 1,
          badge: CalloutBadge.left,
        ),
        GuideCallout.rect(
          unionRect(tester, [images, files], padding: 6),
          number: 2,
          badge: CalloutBadge.left,
        ),
        GuideCallout.rect(
          Rect.fromLTRB(
            panelRect.left + 8,
            tester
                    .getRect(
                      find.descendant(of: panel, matching: find.text('댓글 2')),
                    )
                    .top -
                6,
            panelRect.right - 8,
            math.min(lastComment.bottom + 14, list.bottom - 3),
          ),
          number: 3,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(commentField, number: 4, badge: CalloutBadge.left),
      ],
      crop: clampToScreen(
        tester,
        Rect.fromLTRB(
          panelRect.left - 150,
          panelRect.top,
          panelRect.right,
          panelRect.bottom,
        ),
      ),
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  // ── 대화방 정리하기: 토픽 폴더 ──

  guideCapture('토픽 폴더', desktop, (tester) async {
    await openFolders(tester);
    final folder = find.byKey(const ValueKey('topic-folder-f-team'));
    final menuButton = find.descendant(
      of: folder,
      matching: find.byTooltip('폴더 메뉴'),
    );
    await tester.tap(menuButton);
    await settleGuide(tester);
    final items = find.byType(MenuItemButton);
    final menu = unionRect(tester, [items.first, items.last], padding: 5);
    final club = find.byKey(const ValueKey('topic-folder-f-club'));
    final archived = find.byKey(const ValueKey('topic-folder-archived'));
    final lock = find.descendant(
      of: find.byKey(const ValueKey('topic-row-r-launch')),
      matching: find.byKey(const ValueKey('private-topic-lock')),
    );
    final header = tester.getRect(textIn(sidebar, '토픽 7'));
    await saveGuideShot(
      tester,
      'messenger-topic-folders',
      callouts: [
        // 번호는 오른쪽에 — 왼쪽에 두면 접기 화살표와 폴더 아이콘을 가린다.
        GuideCallout.rect(
          tester.getRect(folder).deflate(1),
          number: 1,
          badge: CalloutBadge.right,
        ),
        GuideCallout.rect(menu, number: 2, badge: CalloutBadge.right),
        GuideCallout.rect(
          tester.getRect(club).deflate(1),
          number: 3,
          badge: CalloutBadge.right,
        ),
        GuideCallout.box(lock, number: 4, badge: CalloutBadge.right, padding: 3),
        GuideCallout.rect(
          tester.getRect(archived).deflate(1),
          number: 5,
          badge: CalloutBadge.right,
        ),
      ],
      crop: clampToScreen(
        tester,
        Rect.fromLTRB(
          0,
          header.top - 10,
          math.max(282, menu.right + 50),
          tester.getRect(archived).bottom + 12,
        ),
      ),
    );
  });

  guideCapture('토픽을 폴더로 끌기', desktop, (tester) async {
    await openFolders(tester);
    final row = find.byKey(const ValueKey('topic-row-r-board'));
    final folder = find.byKey(const ValueKey('topic-folder-f-team'));
    final rowRect = tester.getRect(row);
    final folderRect = tester.getRect(folder);
    // 마우스로 토픽 줄을 눌러 "우리 팀" 폴더 머리글 위로 끌고 온 채로(놓기 전) 찍는다.
    final gesture = await tester.startGesture(
      rowRect.center,
      kind: PointerDeviceKind.mouse,
    );
    addTearDown(gesture.removePointer);
    await tester.pump();
    await gesture.moveBy(const Offset(0, -12));
    await tester.pump();
    await gesture.moveTo(folderRect.centerLeft + const Offset(110, 2));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    final header = tester.getRect(textIn(sidebar, '토픽 7'));
    await saveGuideShot(
      tester,
      'messenger-topic-drag',
      callouts: [
        GuideCallout.rect(
          rowRect.deflate(1),
          number: 1,
          badge: CalloutBadge.right,
        ),
        GuideCallout.rect(
          folderRect.deflate(1),
          number: 2,
          badge: CalloutBadge.right,
        ),
      ],
      crop: clampToScreen(
        tester,
        Rect.fromLTRB(0, header.top - 10, 330, rowRect.bottom + 6),
      ),
    );
    // 끌던 줄을 제자리에 놓는다(아무 폴더에도 넣지 않고 끝낸다).
    await gesture.moveTo(rowRect.center);
    await tester.pump();
    await gesture.up();
    await settleGuide(tester);
  });

  guideCapture('폴더로 이동 메뉴', desktop, (tester) async {
    await openFolders(tester);
    final row = find.byKey(const ValueKey('topic-row-r-weekly'));
    final rowRect = tester.getRect(row);
    await mouseAt(tester, rowRect.center);
    // 줄의 오른쪽 아래를 누른다 — 메뉴가 누른 곳에서 열려서, 줄 이름을 덮지 않게.
    await tester.tapAt(
      Offset(rowRect.right - 60, rowRect.bottom - 3),
      buttons: kSecondaryMouseButton,
      kind: PointerDeviceKind.mouse,
    );
    await settleGuide(tester);
    final move = find.ancestor(
      of: find.text('폴더로 이동'),
      matching: find.byWidgetPredicate((w) => w is PopupMenuItem),
    );
    final removeItem = find.ancestor(
      of: find.text('폴더에서 빼기'),
      matching: find.byWidgetPredicate((w) => w is PopupMenuItem),
    );
    final moveRect = tester.getRect(move);
    final removeRect = tester.getRect(removeItem);
    final menuTop = tester.getRect(
      find
          .ancestor(
            of: find.text('대화창 분할하기'),
            matching: find.byWidgetPredicate((w) => w is PopupMenuItem),
          )
          .first,
    );
    final menuBottom = tester.getRect(
      find
          .ancestor(
            of: find.text('나가기'),
            matching: find.byWidgetPredicate((w) => w is PopupMenuItem),
          )
          .first,
    );
    await tester.tap(move);
    await settleGuide(tester);
    // 하위 메뉴의 항목(폴더 머리글에도 같은 이름이 있어서 맨 위에 뜬 것 — 마지막 것).
    final sub = unionRect(tester, [
      find.text('우리 팀').last,
      find.text('새 폴더…'),
    ], padding: 0);
    final submenu = Rect.fromLTRB(
      sub.left - 44,
      sub.top - 12,
      math.max(sub.right + 20, sub.left + 130),
      sub.bottom + 12,
    );
    await saveGuideShot(
      tester,
      'messenger-topic-move',
      callouts: [
        GuideCallout.rect(
          rowRect.deflate(1),
          number: 1,
          badge: CalloutBadge.left,
        ),
        GuideCallout.rect(
          moveRect.deflate(3),
          number: 2,
          badge: CalloutBadge.left,
        ),
        GuideCallout.rect(submenu, number: 3, badge: CalloutBadge.right),
        GuideCallout.rect(
          removeRect.deflate(3),
          number: 4,
          badge: CalloutBadge.left,
        ),
      ],
      crop: clampToScreen(
        tester,
        Rect.fromLTRB(
          0,
          math.min(rowRect.top - 8, menuTop.top - 20),
          submenu.right + 50,
          math.max(menuBottom.bottom, submenu.bottom) + 20,
        ),
      ),
    );
  });

  // ── 안드로이드 휴대폰: 토픽 탭 ──

  guideCapture('휴대폰 토픽 탭', GuideSurface.phone, (tester) async {
    final parts = createGuideTempDir();
    final session = demoSession(rooms: folderRooms(), folders: demoFolders());
    await pumpGuideApp(tester, RoomListScreen(session: session));
    await settleGuide(tester);
    final fab = find.byType(FloatingActionButton);
    final list = await saveGuideShot(
      tester,
      'phone-topics-a',
      dir: parts,
      callouts: [
        GuideCallout.box(
          find.byKey(const ValueKey('topic-folder-f-team')),
          number: 1,
          badge: CalloutBadge.topLeft,
          padding: 0,
        ),
        GuideCallout.box(
          find.byKey(const ValueKey('topic-folder-archived')),
          number: 2,
          badge: CalloutBadge.topLeft,
          padding: 0,
        ),
        GuideCallout.box(fab, number: 3, badge: CalloutBadge.left),
      ],
    );
    await tester.tap(fab);
    await settleGuide(tester);
    final sheet = tester.getRect(find.byType(BottomSheet));
    final sheetShot = await saveGuideShot(
      tester,
      'phone-topics-b',
      dir: parts,
      callouts: [
        GuideCallout.rect(sheet.deflate(6), number: 4, badge: CalloutBadge.top),
      ],
    );
    composeShots([list, sheetShot], 'messenger-phone-topics', ratio: 2);
  });

  guideCapture('휴대폰 토픽 길게 누르기', GuideSurface.phone, (tester) async {
    final session = demoSession(rooms: folderRooms(), folders: demoFolders());
    await pumpGuideApp(tester, RoomListScreen(session: session));
    await settleGuide(tester);
    final row = find.byKey(const ValueKey('topic-row-r-weekly'));
    final rowRect = tester.getRect(row);
    await tester.longPress(row);
    await settleGuide(tester);
    final sheet = find.byType(BottomSheet);
    Finder tile(String text) =>
        find.descendant(of: sheet, matching: find.widgetWithText(ListTile, text));
    await saveGuideShot(
      tester,
      'messenger-phone-topic-long-press',
      callouts: [
        GuideCallout.rect(
          rowRect.deflate(1),
          number: 1,
          badge: CalloutBadge.topLeft,
        ),
        GuideCallout.rect(
          unionRect(tester, [tile('폴더로 이동'), tile('폴더에서 빼기')], padding: 0)
              .deflate(3),
          number: 2,
          badge: CalloutBadge.right,
        ),
      ],
    );
  });

  tearDownAll(printGuideImagesSize);
}
