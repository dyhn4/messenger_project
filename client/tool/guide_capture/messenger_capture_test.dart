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
// (GuideFakeApi)과 예시 데이터(탱고컴퍼니 · 김민지 등)로 채워 그린다 — guide_capture.dart 참고.
import 'dart:io';
import 'dart:math' as math;

import 'package:client/models/announcement.dart';
import 'package:client/models/app_user.dart';
import 'package:client/models/room.dart';
import 'package:client/models/team.dart';
import 'package:client/screens/chat_screen.dart';
import 'package:client/screens/desktop_home_screen.dart';
import 'package:client/screens/room_list_screen.dart';
import 'package:client/screens/server_setup_screen.dart';
import 'package:client/screens/team_select_screen.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:client/widgets/account_menu_button.dart';
import 'package:client/widgets/chat_input_bar.dart';
import 'package:client/widgets/chat_panel.dart';
import 'package:client/widgets/hover_toolbar.dart';
import 'package:client/widgets/filter_dropdown.dart';
import 'package:client/widgets/message_bubble.dart';
import 'package:client/widgets/rich_text_format.dart';
import 'package:client/widgets/room_options_menu.dart';
import 'package:client/widgets/team_switcher.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:package_info_plus/package_info_plus.dart';

import 'guide_capture.dart';

// ───────────────────────────── 테스트 환경 ─────────────────────────────

/// 테스트 엔진에는 OS 알림 플러그인이 없다 — 방을 열 때 부르는 "그 방 알림 지우기" 등을
/// 조용히 넘긴다(실제 알림은 도움말 그림과 상관없다).
class _QuietNotifications extends NotificationService {
  @override
  Future<void> cancelForRoom(String roomId) async {}

  @override
  Future<void> showMessage({
    required String title,
    required String body,
    required String roomId,
    String? senderName,
    String? conversationTitle,
    String avatarType = 'initial',
    String? avatarEmoji,
    String? avatarColor,
    String? avatarUrl,
    bool isSecret = false,
  }) async {}
}

/// 캡처와 상관없는 디버그 경고를 걸러 낸다 — PC(windows) 모드에서 컨트롤러 없이 붙은
/// 스크롤바(사이드바 목록 등)가 "ScrollPosition이 없다"는 디버그 단언을 내는데, 실제 앱에서도
/// 디버그 로그로만 남고 그림에는 영향이 없다. 나머지 오류는 그대로 테스트 실패로 둔다.
void ignoreBenignErrors() {
  final original = FlutterError.onError;
  FlutterError.onError = (details) {
    final text = details.exceptionAsString();
    if (text.contains('ScrollController has no ScrollPosition attached')) {
      return;
    }
    original?.call(details);
  };
  addTearDown(() => FlutterError.onError = original);
}

/// 비공개(_로 시작하는) 위젯도 타입 이름으로 찾는다 — 사이드바(_Sidebar) 등.
Finder byTypeName(String name) =>
    find.byWidgetPredicate((w) => w.runtimeType.toString() == name);

/// [of] 안에서 [text]를 찾는다(같은 글자가 화면 여러 곳에 있을 때).
Finder textIn(Finder of, String text) =>
    find.descendant(of: of, matching: find.text(text));

Finder get sidebar => byTypeName('_Sidebar');

/// 마우스 포인터를 [at]에 올려 둔다(호버 툴바처럼 마우스를 올려야 보이는 것을 찍을 때).
Future<TestGesture> mouseAt(WidgetTester tester, Offset at) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer(location: at);
  addTearDown(gesture.removePointer);
  await tester.pump();
  return gesture;
}

/// 화면 안으로 잘라낸 영역 — 잘라낼 영역이 화면 밖으로 나가지 않게.
Rect clampToScreen(WidgetTester tester, Rect r) {
  final size = tester.view.physicalSize / tester.view.devicePixelRatio;
  return Rect.fromLTRB(
    math.max(0, r.left),
    math.max(0, r.top),
    math.min(size.width, r.right),
    math.min(size.height, r.bottom),
  );
}

// ───────────────────────────── 예시 데이터 ─────────────────────────────

/// 말풍선 시간 표시용 시각 — 날짜를 고정해서 다시 찍어도 같은 그림이 나오게 한다.
DateTime at(int h, int m, {int day = 29}) => DateTime(2026, 9, day, h, m);

AppUser person(
  String id,
  String name, {
  String? emoji,
  String? color,
  String? dept,
  String? position,
}) => AppUser(
  id: id,
  username: id,
  name: name,
  avatarType: emoji == null ? 'initial' : 'character',
  avatarEmoji: emoji,
  avatarColor: color,
  role: 'member',
  department: dept,
  position: position,
);

final me = person(
  'u-me',
  '김민지',
  emoji: '🐰',
  color: '#FFDEEB',
  dept: '마케팅팀',
  position: '대리',
);
final doHyun = person(
  'u-dh',
  '이도현',
  emoji: '🐻',
  color: '#FFE8CC',
  dept: '마케팅팀',
  position: '팀장',
);
final seoYeon = person('u-sy', '박서연', dept: '디자인팀', position: '과장');
final junHo = person(
  'u-jh',
  '최준호',
  emoji: '🐶',
  color: '#D0EBFF',
  dept: '개발팀',
  position: '사원',
);
final yuNa = person('u-yn', '정유나', dept: '인사팀', position: '대리');
final jiWoo = person('u-jw', '한지우', dept: '영업팀', position: '차장');

final everyone = [me, doHyun, seoYeon, junHo, yuNa, jiWoo];

Map<String, dynamic> userJson(AppUser u) => {
  'id': u.id,
  'username': u.username,
  'name': u.name,
  'avatarType': u.avatarType,
  'avatarEmoji': u.avatarEmoji,
  'avatarColor': u.avatarColor,
  'role': u.role,
  'department': u.department,
  'position': u.position,
};

final tango = Team(
  id: 't-tango',
  name: '탱고컴퍼니',
  iconEmoji: '🚀',
  iconColor: '#4C6EF5',
  createdAt: DateTime(2025, 3, 2),
  memberCount: 42,
);
final designLab = Team(
  id: 't-lab',
  name: '디자인랩',
  iconEmoji: '🎨',
  iconColor: '#E64980',
  createdAt: DateTime(2025, 6, 11),
  memberCount: 8,
);

Map<String, dynamic> teamJson(Team t) => {
  'id': t.id,
  'name': t.name,
  'iconEmoji': t.iconEmoji,
  'iconColor': t.iconColor,
  'createdAt': t.createdAt.millisecondsSinceEpoch,
  'memberCount': t.memberCount,
};

/// 방 멤버들이 마지막으로 읽은 시각 — 말풍선 옆 "안 읽은 사람 수"(주황 숫자)가 여기서 나온다.
/// 최준호만 9시 50분 이후를 아직 안 읽었다.
Map<String, int> readState() => {
  me.id: at(10, 30).millisecondsSinceEpoch,
  doHyun.id: at(10, 20).millisecondsSinceEpoch,
  seoYeon.id: at(10, 20).millisecondsSinceEpoch,
  jiWoo.id: at(10, 20).millisecondsSinceEpoch,
  yuNa.id: at(10, 20).millisecondsSinceEpoch,
  junHo.id: at(9, 50).millisecondsSinceEpoch,
};

final townHall = Announcement(
  id: 'an1',
  roomId: 'r-notice',
  authorId: yuNa.id,
  authorName: yuNa.name,
  text: '10월 2일(금) 오후 3시 전 직원 타운홀 미팅이 있습니다. 대회의실로 모여 주세요.',
  createdAt: at(8, 20),
  commentCount: 3,
);

Room topic(
  String id,
  String name, {
  String? description,
  int unread = 0,
  bool favorite = false,
  DateTime? active,
  List<AppUser>? members,
  Announcement? announcement,
  String teamId = 't-tango',
  String? preview,
}) => Room(
  id: id,
  teamId: teamId,
  type: RoomType.topic,
  name: name,
  description: description,
  members: members ?? everyone,
  createdAt: DateTime(2025, 3, 2),
  lastRead: readState(),
  unreadCount: unread,
  favorite: favorite,
  lastActivityAt: active,
  latestAnnouncement: announcement,
  lastMessagePreview: preview,
);

Room group(
  String id,
  String? name,
  List<AppUser> members, {
  int unread = 0,
  String? iconEmoji,
  String? iconColor,
  String? preview,
  DateTime? active,
  bool muted = false,
}) => Room(
  id: id,
  teamId: tango.id,
  type: RoomType.group,
  name: name,
  members: [me, ...members],
  createdAt: DateTime(2026, 8, 1),
  lastRead: readState(),
  unreadCount: unread,
  muted: muted,
  iconType: iconEmoji != null ? 'emoji' : null,
  iconEmoji: iconEmoji,
  iconColor: iconColor,
  lastMessagePreview: preview,
  lastActivityAt: active,
);

Room dm(
  String id,
  AppUser other, {
  int unread = 0,
  String? preview,
  DateTime? active,
}) => Room(
  id: id,
  teamId: tango.id,
  type: RoomType.dm,
  name: null,
  members: [me, other],
  createdAt: DateTime(2026, 7, 1),
  lastRead: readState(),
  unreadCount: unread,
  lastMessagePreview: preview,
  lastActivityAt: active,
);

List<Room> demoRooms() => [
  topic(
    'r-notice',
    '전사 공지',
    description: '회사 전체 공지와 소식',
    favorite: true,
    active: at(8, 30),
    announcement: townHall,
  ),
  topic(
    'r-mkt',
    '마케팅팀',
    description: '마케팅팀 업무 이야기',
    active: at(10, 15),
    members: [me, doHyun, seoYeon, junHo, jiWoo],
  ),
  topic(
    'r-weekly',
    '주간회의',
    description: '매주 월요일 10시 주간회의',
    unread: 3,
    preview: '이번 주 안건 정리해서 올렸습니다',
    active: at(9, 40),
  ),
  topic(
    'r-launch',
    '신제품 런칭',
    description: '11월 신제품 출시 준비',
    unread: 12,
    preview: '출시 일정표 최신본 공유합니다',
    active: at(9, 55),
  ),
  group(
    'r-lunch',
    '점심 메뉴 정하기',
    [doHyun, junHo, yuNa],
    iconEmoji: '🍀',
    iconColor: '#37B24D',
    unread: 2,
    preview: '오늘은 칼국수 어때요?',
    active: at(11, 2),
  ),
  group(
    'r-tf',
    '3분기 캠페인 TF',
    [doHyun, seoYeon, jiWoo],
    iconEmoji: '🎉',
    iconColor: '#FAB005',
    preview: '시안 두 가지 올려 두었습니다',
    active: at(9, 20),
  ),
  dm(
    'r-dm-dh',
    doHyun,
    unread: 1,
    preview: '오후에 잠깐 통화 가능할까요?',
    active: at(10, 40),
  ),
  dm('r-dm-sy', seoYeon, preview: '배너 수정본 확인했어요 👍', active: at(9, 5)),
  dm('r-dm-jh', junHo, preview: '네 알겠습니다!', active: at(8, 50, day: 28)),
  // 다른 팀(디자인랩)의 방 — 알림 센터는 여러 팀의 안 읽은 방을 한꺼번에 보여준다.
  topic(
    'r-lab-review',
    '디자인 리뷰',
    teamId: designLab.id,
    unread: 5,
    preview: '로고 시안 피드백 부탁드려요',
    active: at(10, 50),
  ),
];

/// 공개 직책 목록 — '조장' 이상이면 1:1 목록에 직책 배지가 붙는다(position_badge.dart).
final positionOptions = [
  for (final (i, label) in ['사원', '대리', '조장', '과장', '차장', '팀장'].indexed)
    {'id': 'p$i', 'label': label, 'isDefault': i == 0},
];

Map<String, dynamic> message(
  String id,
  String roomId,
  AppUser sender,
  DateTime time, {
  String type = 'text',
  String? text,
  String? fileName,
  int? fileSize,
  List<Map<String, dynamic>> comments = const [],
}) => {
  'id': id,
  'roomId': roomId,
  'senderId': sender.id,
  'senderName': sender.name,
  'type': type,
  'text': text,
  if (fileName != null) ...{
    'fileUrl': '/uploads/$id',
    'fileName': fileName,
    'fileSize': fileSize ?? 1024 * 1024,
    'attachments': [
      {
        'id': 'a-$id',
        'kind': 'file',
        'fileUrl': '/uploads/$id',
        'fileName': fileName,
        'fileSize': fileSize ?? 1024 * 1024,
      },
    ],
  },
  'createdAt': time.millisecondsSinceEpoch,
  'comments': comments,
};

Map<String, dynamic> comment(
  String id,
  String messageId,
  AppUser sender,
  DateTime time,
  String text,
) => {
  'id': id,
  'messageId': messageId,
  'roomId': 'r-mkt',
  'senderId': sender.id,
  'senderName': sender.name,
  'type': 'text',
  'text': text,
  'createdAt': time.millisecondsSinceEpoch,
};

const planFile = '3분기_캠페인_기획안.pptx';
const myLastText = '좋습니다! 2시에 회의실에서 뵐게요.';

/// 마케팅팀 토픽의 대화. [withComments]면 기획안 메시지에 댓글 두 개가 달려 있다.
List<Map<String, dynamic>> marketingMessages({bool withComments = false}) => [
  message(
    'm1',
    'r-mkt',
    doHyun,
    at(9, 30),
    text: '다들 좋은 아침입니다 ☀️\n오늘 오후 2시에 3분기 캠페인 중간 점검 회의가 있습니다.',
  ),
  message(
    'm3',
    'r-mkt',
    me,
    at(9, 41),
    type: 'file',
    text: '기획안 초안 공유드립니다. 검토 부탁드려요!',
    fileName: planFile,
    fileSize: 4 * 1024 * 1024,
    comments: withComments
        ? [
            comment('c1', 'm3', doHyun, at(9, 52), '잘 봤어요. 일정표만 한 장 추가해 주세요.'),
            comment('c2', 'm3', me, at(9, 55), '네, 회의 전까지 반영하겠습니다!'),
          ]
        : const [],
  ),
  message(
    'm5',
    'r-mkt',
    jiWoo,
    at(10, 12),
    text: '영업팀에서도 고객사 반응 자료를 모아서 같이 보겠습니다.',
  ),
  message('m6', 'r-mkt', me, at(10, 15), text: myLastText),
];

List<Map<String, dynamic>> noticeMessages() => [
  message(
    'n1',
    'r-notice',
    yuNa,
    at(8, 22),
    text: '타운홀 미팅 안내를 공지로 올려 두었습니다. 위쪽 공지를 눌러 확인해 주세요 🙂',
  ),
  message(
    'n2',
    'r-notice',
    yuNa,
    at(8, 30),
    text: '10월 복지포인트 신청은 이번 주 금요일까지입니다.',
  ),
];

Map<String, dynamic> announcementJson(
  String id,
  String text,
  DateTime time, {
  bool pinned = false,
  int comments = 0,
}) => {
  'id': id,
  'roomId': 'r-notice',
  'authorId': yuNa.id,
  'authorName': yuNa.name,
  'text': text,
  'createdAt': time.millisecondsSinceEpoch,
  'pinned': pinned,
  'commentCount': comments,
};

/// 가짜 서버 — 화면이 부르는 API에 예시 데이터를 돌려준다.
GuideFakeApi demoApi({bool withComments = false}) {
  return GuideFakeApi()
    ..get('/api/position-options', positionOptions)
    ..get('/api/teams/:id/members', [for (final u in everyone) userJson(u)])
    ..get('/api/users/:id/teams', [teamJson(tango)])
    ..get(
      '/api/rooms/r-mkt/messages',
      (_) => marketingMessages(withComments: withComments),
    )
    ..get('/api/rooms/r-notice/messages', (_) => noticeMessages())
    ..get('/api/rooms/:id/messages', <Object>[])
    ..get('/api/rooms/r-notice/announcements', [
      announcementJson(
        'an1',
        townHall.text,
        townHall.createdAt,
        pinned: true,
        comments: 3,
      ),
      announcementJson(
        'an2',
        '추석 연휴(10/3~10/5) 사무실 출입 안내',
        at(15, 10, day: 24),
        comments: 1,
      ),
      announcementJson('an3', '하반기 정보보안 교육 이수 안내', at(9, 0, day: 15)),
    ])
    ..get('/api/rooms/browse', [
      {
        'id': 'r-notice',
        'name': '전사 공지',
        'description': '회사 전체 공지와 소식',
        'memberCount': 42,
        'joined': true,
      },
      {
        'id': 'r-club',
        'name': '사내 동호회',
        'description': '등산 · 볼링 · 보드게임 모임',
        'memberCount': 23,
        'joined': false,
      },
      {
        'id': 'r-it',
        'name': 'IT 도움방',
        'description': 'PC · 프린터 · 계정 문의',
        'memberCount': 35,
        'joined': false,
      },
      {
        'id': 'r-mkt',
        'name': '마케팅팀',
        'description': '마케팅팀 업무 이야기',
        'memberCount': 5,
        'joined': true,
      },
      {
        'id': 'r-launch',
        'name': '신제품 런칭',
        'description': '11월 신제품 출시 준비',
        'memberCount': 12,
        'joined': true,
      },
    ])
    ..get('/api/search', [
      {
        'id': 'm3',
        'roomId': 'r-mkt',
        'roomName': '마케팅팀',
        'senderId': me.id,
        'senderName': me.name,
        'text': '기획안 초안 공유드립니다. 검토 부탁드려요!',
        'createdAt': at(9, 41).millisecondsSinceEpoch,
      },
      {
        'id': 's2',
        'roomId': 'r-tf',
        'roomName': '3분기 캠페인 TF',
        'senderId': jiWoo.id,
        'senderName': jiWoo.name,
        'text': '기획안에 들어갈 고객사 사례 세 곳 정리했습니다.',
        'createdAt': at(16, 20, day: 26).millisecondsSinceEpoch,
      },
      {
        'id': 's3',
        'roomId': 'r-dm-dh',
        'roomName': '이도현',
        'senderId': doHyun.id,
        'senderName': doHyun.name,
        'text': '기획안은 이번 주 안에만 주시면 됩니다.',
        'createdAt': at(11, 5, day: 22).millisecondsSinceEpoch,
      },
    ])
    ..get('/api/attachments', [
      message('f1', 'r-mkt', me, at(9, 41), type: 'file', fileName: planFile),
      message(
        'f2',
        'r-tf',
        seoYeon,
        at(17, 2, day: 26),
        type: 'file',
        fileName: '배너_시안_v2.pdf',
      ),
      message(
        'f3',
        'r-weekly',
        doHyun,
        at(10, 40, day: 28),
        type: 'file',
        fileName: '주간회의_회의록_0928.docx',
      ),
      message(
        'f4',
        'r-tf',
        jiWoo,
        at(16, 20, day: 26),
        type: 'file',
        fileName: '고객사_반응_정리.xlsx',
      ),
    ])
    ..get('/api/favorite-files', [
      {'messageId': 'f1'},
    ])
    ..get('/auth/username-available', {'available': true})
    ..post(
      '/api/upload',
      (_) => {
        'url': '/uploads/new',
        'fileName': 'file',
        'size': 1000,
        'mimeType': 'application/octet-stream',
      },
    );
}

/// 로그인까지 끝난 김민지(정회원)의 세션 — guide_capture.dart의 guideSession과 같은 방식이되,
/// OS 알림 플러그인을 부르지 않는 알림 서비스를 쓴다.
Session demoSession({
  GuideFakeApi? api,
  List<Room>? rooms,
  bool inTeam = true,
}) {
  final fake = api ?? demoApi();
  final session = Session(
    notifications: _QuietNotifications(),
    settings: AppSettings(),
  );
  const serverUrl = 'https://192.168.0.10:3000';
  session.serverUrl = serverUrl;
  session.api = ApiClient(
    baseUrl: serverUrl,
    token: 'guide-token',
    httpClient: fake.client,
  );
  session.userId = me.id;
  session.username = 'minji.kim';
  session.name = me.name;
  session.accountRole = AccountRole.member;
  session.canCreateProject = true;
  session.avatarType = 'character';
  session.avatarEmoji = me.avatarEmoji;
  session.avatarColor = me.avatarColor;
  session.myTeamPositions = [
    TeamPosition(
      teamId: tango.id,
      teamName: tango.name,
      department: '마케팅팀',
      position: '대리',
    ),
  ];
  session.teams.addAll([tango, designLab]);
  if (inTeam) session.currentTeam = tango;
  session.rooms.addAll(rooms ?? demoRooms());
  session.onlineUserIds.addAll([doHyun.id, seoYeon.id, jiWoo.id]);
  session.settings.downloadFolder = r'C:\Users\minji\Downloads';
  return session;
}

/// PC 메인 화면을 띄우고 [roomName] 방을 연다.
Future<Session> openDesktop(
  WidgetTester tester, {
  String? roomName = '마케팅팀',
  GuideFakeApi? api,
}) async {
  ignoreBenignErrors();
  final session = demoSession(api: api);
  await pumpGuideApp(tester, DesktopHomeScreen(session: session));
  if (roomName != null) {
    await tester.tap(textIn(sidebar, roomName));
    await settleGuide(tester);
  }
  return session;
}

/// 사이드바 섹션 제목 옆 [+] 버튼(툴팁으로 찾는다).
Finder plusButton(String tooltip) =>
    find.descendant(of: sidebar, matching: find.byTooltip(tooltip));

/// 떠 있는 대화상자의 카드 부분 — Dialog 위젯 자체는 화면 전체 크기라 잘라낼 때는 이걸 쓴다.
Finder get dialogCard => find
    .descendant(of: find.byType(Dialog), matching: find.byType(Material))
    .first;

/// [text]가 적힌 버튼 전체(아이콘 포함).
Finder buttonWith(String text) => find
    .ancestor(
      of: find.text(text),
      matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
    )
    .first;

/// [text]로 시작하는 메시지의 말풍선(배경이 칠해진 상자) — 아바타의 AnimatedContainer와
/// 헷갈리지 않게 말풍선 애니메이션 길이(500ms)로 고른다.
Finder bubbleBoxOf(String text) => find
    .descendant(
      of: find
          .ancestor(
            of: find.textContaining(text, findRichText: true).first,
            matching: find.byType(MessageBubble),
          )
          .first,
      matching: find.byWidgetPredicate(
        (w) =>
            w is AnimatedContainer &&
            w.duration == const Duration(milliseconds: 500),
      ),
    )
    .first;

/// 보낸 사람이 나인 마지막 말풍선.
Finder get myLastBubble => find
    .ancestor(
      of: find.textContaining(myLastText, findRichText: true),
      matching: find.byType(MessageBubble),
    )
    .first;

/// 떠 있는 제목(라벨)이 테두리 위에 걸친 입력칸 — 라벨을 가리지 않게 상자 위쪽만 더 띄운다
/// (입력칸끼리 12px 간격이라 아래쪽은 바짝 붙인다).
GuideCallout fieldCallout(
  WidgetTester tester,
  Finder field,
  int number, {
  CalloutBadge badge = CalloutBadge.left,
}) {
  final r = tester.getRect(field);
  return GuideCallout.rect(
    Rect.fromLTRB(r.left - 4, r.top - 9, r.right + 4, r.bottom + 1),
    number: number,
    badge: badge,
  );
}

/// 메뉴 항목 하나(팝업 메뉴 항목들이 서로 붙어 있어서 상자를 살짝 안쪽으로 그린다).
GuideCallout menuItemCallout(
  WidgetTester tester,
  Finder item,
  int number, {
  CalloutBadge badge = CalloutBadge.left,
}) => GuideCallout.rect(
  tester.getRect(item).deflate(3),
  number: number,
  badge: badge,
);

/// 테스트 엔진에는 path_provider 플러그인이 없다 — 첨부 썸네일을 임시 파일로 쓸 때 부르는
/// "임시 폴더"를 테스트용 폴더로 돌려준다.
Directory mockPathProvider(WidgetTester tester) {
  final dir = Directory.systemTemp.createTempSync('guide_tmp_');
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    channel,
    (call) async => dir.path,
  );
  addTearDown(() {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      null,
    );
    dir.deleteSync(recursive: true);
  });
  return dir;
}

/// 메뉴가 버튼을 덮어서 한 장에 "누를 곳"과 "뜨는 메뉴"를 같이 못 보여줄 때 — 누르기 전
/// 그림과 누른 뒤 그림을 가로로 이어 붙이고 사이에 화살표를 그려 한 장으로 만든다.
/// [parts]는 saveGuideShot으로 저장한 임시 파일들이고, 합친 뒤 지운다.
void composeShots(List<File> parts, String name) {
  const ratio = 1.5; // GuideSurface.desktop의 배율.
  const gap = 84; // 화살표 칸(픽셀) — 논리 56px.
  const pad = 18;
  final images = [
    for (final f in parts)
      img.decodePng(f.readAsBytesSync())!.convert(numChannels: 3),
  ];
  final width =
      images.fold<int>(0, (s, i) => s + i.width) +
      gap * (images.length - 1) +
      pad * 2;
  final height = images.map((i) => i.height).reduce(math.max) + pad * 2;
  final canvas = img.Image(width: width, height: height);
  img.fill(canvas, color: img.ColorRgb8(241, 243, 245));
  final border = img.ColorRgb8(206, 212, 218);
  final arrow = img.ColorRgb8(73, 80, 87);
  var x = pad;
  for (final (i, part) in images.indexed) {
    final y = (height - part.height) ~/ 2;
    img.compositeImage(canvas, part, dstX: x, dstY: y);
    img.drawRect(
      canvas,
      x1: x - 1,
      y1: y - 1,
      x2: x + part.width,
      y2: y + part.height,
      color: border,
      thickness: 2,
    );
    x += part.width;
    if (i < images.length - 1) {
      final cy = height ~/ 2;
      img.drawLine(
        canvas,
        x1: x + 18,
        y1: cy,
        x2: x + gap - 30,
        y2: cy,
        color: arrow,
        thickness: 7,
      );
      img.fillPolygon(
        canvas,
        vertices: [
          img.Point(x + gap - 34, cy - 16),
          img.Point(x + gap - 14, cy),
          img.Point(x + gap - 34, cy + 16),
        ],
        color: arrow,
      );
      x += gap;
    }
  }
  final out = File('${guideImagesDir.path}/$name.png');
  out.writeAsBytesSync(
    img.encodePng(
      img.quantize(
        canvas,
        numberOfColors: 256,
        method: img.QuantizeMethod.octree,
      ),
      level: 9,
    ),
  );
  for (final f in parts) {
    f.deleteSync();
  }
  // ignore: avoid_print
  print(
    '[guide] ${out.path} (${canvas.width}×${canvas.height}px, '
    '${(out.lengthSync() / 1024).toStringAsFixed(0)} KB)\n'
    '        <img src="images/$name.png" alt="" '
    'width="${(canvas.width / ratio).round()}" '
    'height="${(canvas.height / ratio).round()}" loading="lazy">',
  );
}

/// "배너 시안" 예시 그림(파일 보내기 캡처용) — 채팅 입력칸 위에 작은 미리보기로 보인다.
img.Image bannerImage() {
  final noise = math.Random(7);
  final image = img.Image(width: 960, height: 540);
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      final t = x / image.width;
      final n = noise.nextInt(9) - 4;
      image.setPixelRgb(
        x,
        y,
        (76 + 120 * t).round() + n,
        (110 + 40 * (1 - t)).round() + n,
        245 - (60 * t).round() + n,
      );
    }
  }
  img.fillCircle(
    image,
    x: 720,
    y: 240,
    radius: 140,
    color: img.ColorRgb8(255, 212, 59),
  );
  img.fillRect(
    image,
    x1: 80,
    y1: 340,
    x2: 500,
    y2: 392,
    color: img.ColorRgb8(255, 255, 255),
  );
  img.fillRect(
    image,
    x1: 80,
    y1: 412,
    x2: 360,
    y2: 448,
    color: img.ColorRgb8(220, 228, 255),
  );
  return image;
}

// ───────────────────────────── 캡처 ─────────────────────────────

const desktop = GuideSurface.desktop;

/// 입력칸처럼 가로로 긴 부분만 잘라 보여줄 때 — 창을 조금 좁혀서(사이드바는 그대로 보이는 폭)
/// 잘라낸 그림이 본문 폭에서 덜 줄어들게 한다.
const compact = GuideSurface(Size(1000, 720));

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
      find.byTooltip('프로젝트'),
      find.byTooltip('설정'),
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
      for (final t in tips) find.byTooltip(t),
    ], padding: 0);
    await saveGuideShot(
      tester,
      'messenger-topbar',
      callouts: [
        for (final (i, t) in tips.indexed)
          GuideCallout.box(
            find.byTooltip(t),
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
    final button = find.byTooltip('설정');
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
          tester.getRect(find.byTooltip('알림 센터')).left - 16,
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

  guideCapture('토픽 메뉴', desktop, (tester) async {
    await openDesktop(tester, roomName: null);
    final plus = plusButton('토픽 추가');
    final plusRect = tester.getRect(plus);
    final header = tester.getRect(textIn(sidebar, '토픽 4'));
    final before = await saveGuideShot(
      tester,
      '_tmp-topic-menu-a',
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
    final menu = unionRect(tester, [item('토픽 만들기'), item('토픽 찾기')]);
    final after = await saveGuideShot(
      tester,
      '_tmp-topic-menu-b',
      // 토픽 찾기에는 번호를 달지 않는다 — 바로 다음 그림(새 토픽 생성 창)의 3번과 겹치지 않게
      // (토픽 찾기는 다음 절에서 따로 설명한다).
      callouts: [
        menuItemCallout(tester, item('토픽 만들기'), 2, badge: CalloutBadge.right),
      ],
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
    composeShots([before, after], 'messenger-topic-menu');
  });

  guideCapture('토픽 만들기', desktop, (tester) async {
    await openDesktop(tester, roomName: null);
    await tester.tap(plusButton('토픽 추가'));
    await settleGuide(tester);
    await tester.tap(find.text('토픽 만들기'));
    await settleGuide(tester);
    final name = find.widgetWithText(TextField, '토픽 이름');
    final desc = find.widgetWithText(TextField, '설명 (선택)');
    await tester.enterText(name, '고객 문의 대응');
    await tester.enterText(desc, '고객 문의를 함께 확인하고 답변을 나누는 방');
    FocusManager.instance.primaryFocus?.unfocus();
    await settleGuide(tester);
    await saveGuideShot(
      tester,
      'messenger-topic-create',
      callouts: [
        fieldCallout(tester, name, 3),
        fieldCallout(tester, desc, 4),
        GuideCallout.rect(
          unionRect(tester, [
            find.text('공개 여부'),
            find.widgetWithText(RadioListTile<bool>, '비공개'),
          ]),
          number: 5,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(
          buttonWith('만들기'),
          number: 6,
          badge: CalloutBadge.left,
        ),
      ],
      crop: cropAround(tester, [dialogCard], margin: 30),
    );
  });

  guideCapture('토픽 찾기', desktop, (tester) async {
    await openDesktop(tester, roomName: null);
    final plusRect = tester.getRect(plusButton('토픽 추가'));
    await tester.tap(plusButton('토픽 추가'));
    await settleGuide(tester);
    await tester.tap(find.text('토픽 찾기'));
    await settleGuide(tester);
    final join = find.descendant(
      of: find.widgetWithText(ListTile, '사내 동호회'),
      matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
    );
    final card = tester.getRect(dialogCard);
    await saveGuideShot(
      tester,
      'messenger-topic-browse',
      callouts: [
        GuideCallout.rect(
          plusRect.inflate(2),
          number: 1,
          badge: CalloutBadge.bottom,
        ),
        GuideCallout.box(join, number: 2, badge: CalloutBadge.left),
      ],
      crop: clampToScreen(
        tester,
        Rect.fromLTRB(
          0,
          math.min(card.top, plusRect.top) - 20,
          card.right + 24,
          card.bottom + 20,
        ),
      ),
    );
  });

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
    await openDesktop(tester);
    final button = find.byTooltip('화면 캡처');
    final buttonRect = tester.getRect(button);
    final input = tester.getRect(find.byType(ChatInputBar));
    final before = await saveGuideShot(
      tester,
      '_tmp-capture-a',
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
      '_tmp-capture-b',
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
    final bell = find.byTooltip('알림 센터');
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
        GuideCallout.box(bell, number: 1, badge: CalloutBadge.left),
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
    await tester.tapAt(
      tileRect.center + const Offset(40, 0),
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
          math.min(tileRect.top, menu.top) - 30,
          menu.right + 70,
          math.max(tileRect.bottom, menu.bottom) + 30,
        ),
      ),
    );
  });

  guideCapture('대화방 더보기', desktop, (tester) async {
    await openDesktop(tester);
    final button = find.byType(RoomOptionsMenu);
    final buttonRect = tester.getRect(button);
    final before = await saveGuideShot(
      tester,
      '_tmp-room-options-a',
      callouts: [
        GuideCallout.rect(
          buttonRect.deflate(2),
          number: 1,
          badge: CalloutBadge.left,
        ),
      ],
      crop: Rect.fromLTRB(
        buttonRect.left - 220,
        buttonRect.top - 30,
        1280,
        buttonRect.bottom + 30,
      ),
    );
    await tester.tap(button);
    await settleGuide(tester);
    final items = find.byWidgetPredicate((w) => w is PopupMenuItem);
    final menu = unionRect(tester, [items.first, items.last], padding: 8);
    final after = await saveGuideShot(
      tester,
      '_tmp-room-options-b',
      callouts: [GuideCallout.rect(menu, number: 2, badge: CalloutBadge.left)],
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
    composeShots([before, after], 'messenger-room-options');
  });

  // ── 7. 검색과 파일 ──

  guideCapture('검색', desktop, (tester) async {
    await openDesktop(tester);
    final searchIcon = find.byTooltip('검색');
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
    final menuButton = find.byTooltip('메뉴');
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
    final membersIcon = find.byTooltip('멤버');
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
    await tester.tap(find.byTooltip('설정'));
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

  guideCapture('환경설정', desktop, (tester) async {
    await openDesktop(tester);
    await tester.tap(find.byTooltip('설정'));
    await settleGuide(tester);
    await tester.tap(find.text('환경설정'));
    await settleGuide(tester);
    Finder pill(String label) => find.ancestor(
      of: find.text(label),
      matching: byTypeName('_PreviewModeOption'),
    );
    Rect section(String label, Finder last) =>
        unionRect(tester, [find.text(label), last], padding: 5);
    await saveGuideShot(
      tester,
      'messenger-settings',
      callouts: [
        GuideCallout.rect(
          section(
            '화면 테마',
            find.widgetWithText(RadioListTile<ThemeMode>, '다크 모드'),
          ),
          number: 1,
          badge: CalloutBadge.left,
        ),
        GuideCallout.rect(
          section('팀 전환 방식', pill('탭(전체 보기)')),
          number: 2,
          badge: CalloutBadge.left,
        ),
        GuideCallout.rect(
          section('메시지 내용 미리보기', pill('미리보기 안함')),
          number: 3,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(
          buttonWith('저장하기'),
          number: 4,
          badge: CalloutBadge.left,
        ),
      ],
      crop: cropAround(tester, [dialogCard], margin: 30),
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
