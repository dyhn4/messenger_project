// 메신저 도움말 캡처(messenger_capture_test.dart · messenger_topic_capture_test.dart)가 같이 쓰는
// 예시 데이터(탱고컴퍼니 · 김민지 등)와 가짜 서버, 화면을 여는 도우미.
//
// 진짜 앱 화면(DesktopHomeScreen, RoomListScreen 등)을 가짜 서버 응답(GuideFakeApi)과 이 예시
// 데이터로 채워 그린다 — guide_capture.dart 참고. 데이터를 바꾸면 두 캡처 파일을 모두 다시 돌려서
// 그림이 도움말 글(messenger.html)과 여전히 맞는지 확인한다.
import 'dart:io';
import 'dart:math' as math;

import 'package:client/models/announcement.dart';
import 'package:client/models/app_user.dart';
import 'package:client/models/room.dart';
import 'package:client/models/team.dart';
import 'package:client/models/topic_folder.dart';
import 'package:client/screens/desktop_home_screen.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:client/widgets/message_bubble.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

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
    bool flashTaskbarUntilRoomOpened = false,
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

/// 창 맨 위 줄(프로젝트 · 알림 센터 · 멤버 · 검색 · 메뉴 · ☰)의 버튼 — 대화방 머리글에도 같은
/// 툴팁('멤버' 등)의 버튼이 있어서 맨 위 줄 안에서만 찾는다.
Finder topBarButton(String tooltip) => find.descendant(
  of: byTypeName('_TopBar'),
  matching: find.byTooltip(tooltip),
);

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

/// 예시 사람. [role]은 계정 등급('member' 정회원 · 'admin' 관리자 · 'guest' 준회원), [owner]는
/// 지금 팀의 소유자인지(참여 멤버 창의 '소유자' 배지).
AppUser person(
  String id,
  String name, {
  String? emoji,
  String? color,
  String? dept,
  String? position,
  String role = 'member',
  bool owner = false,
}) => AppUser(
  id: id,
  username: id,
  name: name,
  avatarType: emoji == null ? 'initial' : 'character',
  avatarEmoji: emoji,
  avatarColor: color,
  role: role,
  isOwner: owner,
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

// ── 토픽 관리 그림용(참여 멤버 창의 배지) — 같은 사람을 등급·소유자 정보까지 넣어 다시 만든다.
// 다른 그림(프로필 카드 등)은 위의 기본 인물을 그대로 쓴다.

/// 팀 소유자(참여 멤버 창의 '소유자' 배지).
final jiWooOwner = person(
  'u-jw',
  '한지우',
  dept: '영업팀',
  position: '차장',
  owner: true,
);

/// 계정 관리자('관리자' 배지).
final seoYeonAdmin = person(
  'u-sy',
  '박서연',
  dept: '디자인팀',
  position: '과장',
  role: 'admin',
);

/// 준회원 인턴('준회원' 배지) — 토픽 관리자로 지정할 수 없다.
final seHoon = person(
  'u-sh',
  '오세훈',
  dept: '마케팅팀',
  position: '인턴',
  role: 'guest',
);

/// 팀에는 있지만 아직 어느 토픽에도 없는 사람들(멤버 초대하기 창의 목록을 채운다).
final minSu = person('u-ms', '윤민수', dept: '마케팅팀', position: '사원');
final soHee = person('u-shh', '강소희', dept: '마케팅팀', position: '대리');

Map<String, dynamic> userJson(AppUser u) => {
  'id': u.id,
  'username': u.username,
  'name': u.name,
  'avatarType': u.avatarType,
  'avatarEmoji': u.avatarEmoji,
  'avatarColor': u.avatarColor,
  'role': u.role,
  'isOwner': u.isOwner,
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
  seHoon.id: at(10, 20).millisecondsSinceEpoch,
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

/// 토픽 하나. [admins]는 토픽 관리자 id들, [board]면 보드 뷰 토픽, [archived]면 보관된 토픽.
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
  bool isPublic = true,
  List<String> admins = const [],
  bool board = false,
  bool readOnly = false,
  bool archived = false,
  bool autoInvite = false,
  bool quietLeave = false,
  bool muted = false,
}) => Room(
  id: id,
  teamId: teamId,
  type: RoomType.topic,
  name: name,
  description: description,
  isPublic: isPublic,
  members: members ?? everyone,
  createdAt: DateTime(2025, 3, 2),
  lastRead: readState(),
  unreadCount: unread,
  favorite: favorite,
  muted: muted,
  lastActivityAt: active,
  latestAnnouncement: announcement,
  lastMessagePreview: preview,
  adminIds: admins,
  viewMode: board ? TopicViewMode.board : TopicViewMode.chat,
  readOnly: readOnly,
  archivedAt: archived ? DateTime(2026, 9, 1) : null,
  autoInvite: autoInvite,
  quietLeave: quietLeave,
  createdBy: admins.isEmpty ? null : admins.first,
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
    // 비공개 토픽 — 목록에서 이름 옆 회색 자물쇠를 보여 주려고.
    isPublic: false,
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

/// 토픽 관리 그림용 마케팅팀 토픽 — 나(김민지)와 이도현이 토픽 관리자이고, 팀 소유자 · 관리자 ·
/// 준회원이 섞여 있다(참여 멤버 창의 배지와 순서).
Room managedMarketing() => topic(
  'r-mkt',
  '마케팅팀',
  description: '마케팅팀 업무 이야기',
  active: at(10, 15),
  members: [me, doHyun, jiWooOwner, seoYeonAdmin, junHo, seHoon],
  admins: [me.id, doHyun.id],
);

/// [demoRooms]에서 같은 id의 방을 [replace]로 바꾸고 [extra]를 덧붙인 목록.
List<Room> demoRoomsWith({
  List<Room> replace = const [],
  List<Room> extra = const [],
}) {
  final byId = {for (final r in replace) r.id: r};
  return [for (final r in demoRooms()) byId[r.id] ?? r, ...extra];
}

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

/// 가짜 서버 — 화면이 부르는 API에 예시 데이터를 돌려준다. [extra]로 등록한 응답이 아래 기본
/// 응답보다 먼저 쓰인다(같은 경로면 먼저 등록한 것이 이긴다 — 그림마다 데이터를 바꿀 때).
GuideFakeApi demoApi({
  bool withComments = false,
  void Function(GuideFakeApi api)? extra,
}) {
  final api = GuideFakeApi();
  extra?.call(api);
  return api
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
    // 참여 가능한 토픽 보기 — 공개 토픽 중 아직 안 들어간 것(참여 가능한 토픽)과 들어가 있는
    // 것(참여 중인 토픽, 비공개 포함). 보드 뷰 · 읽기 전용 · 보관됨 배지가 하나씩 보이게 골랐다.
    ..get('/api/rooms/browse', [
      {
        'id': 'r-notice',
        'name': '전사 공지',
        'description': '회사 전체 공지와 소식',
        'memberCount': 42,
        'joined': true,
        'adminNames': [yuNa.name],
      },
      {
        'id': 'r-club',
        'name': '사내 동호회',
        'description': '등산 · 볼링 · 보드게임 모임',
        'memberCount': 23,
        'joined': false,
        'adminNames': [yuNa.name],
      },
      {
        'id': 'r-design',
        'name': '디자인 가이드',
        'description': '브랜드 가이드와 시안 모음',
        'memberCount': 18,
        'joined': false,
        'viewMode': 'board',
        'adminNames': [seoYeon.name],
      },
      {
        'id': 'r-hr',
        'name': '인사 · 총무 안내',
        'description': '휴가 · 복지 · 비품 안내',
        'memberCount': 41,
        'joined': false,
        'readOnly': true,
        'adminNames': [yuNa.name],
      },
      {
        'id': 'r-it',
        'name': 'IT 도움방',
        'description': 'PC · 프린터 · 계정 문의',
        'memberCount': 35,
        'joined': false,
        'adminNames': [junHo.name],
      },
      {
        'id': 'r-party',
        'name': '2025 송년회 준비',
        'description': '지난 송년회 준비방',
        'memberCount': 9,
        'joined': false,
        'archived': true,
        'adminNames': [jiWoo.name],
      },
      {
        'id': 'r-mkt',
        'name': '마케팅팀',
        'description': '마케팅팀 업무 이야기',
        'memberCount': 5,
        'joined': true,
        'adminNames': [me.name, doHyun.name],
      },
      {
        'id': 'r-weekly',
        'name': '주간회의',
        'description': '매주 월요일 10시 주간회의',
        'memberCount': 42,
        'joined': true,
        'adminNames': [doHyun.name],
      },
      {
        'id': 'r-launch',
        'name': '신제품 런칭',
        'description': '11월 신제품 출시 준비',
        'memberCount': 12,
        'joined': true,
        'isPublic': false,
        'adminNames': [doHyun.name],
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
  List<TopicFolder> folders = const [],
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
  // 내 토픽 폴더(개인 설정) — 팀을 고르며 서버에서 받아 오는 것을 미리 채워 둔다.
  session.topicFolders.addAll(folders);
  session.onlineUserIds.addAll([doHyun.id, seoYeon.id, jiWoo.id]);
  session.settings.downloadFolder = r'C:\Users\minji\Downloads';
  return session;
}

/// PC 메인 화면을 띄우고 [roomName] 방을 연다. [session]을 주면 그 세션으로(방·폴더를 바꾼 그림).
Future<Session> openDesktop(
  WidgetTester tester, {
  String? roomName = '마케팅팀',
  GuideFakeApi? api,
  Session? session,
}) async {
  ignoreBenignErrors();
  session ??= demoSession(api: api);
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
/// [parts]는 saveGuideShot으로 임시 폴더(createGuideTempDir)에 저장한 조각들이고, 합친 뒤 지운다.
/// [ratio]는 조각을 찍은 화면의 배율(PC 1.5, 휴대폰 2) — 화살표 칸과 여백도 그 배율로 그린다.
void composeShots(List<File> parts, String name, {double ratio = 1.5}) {
  final gap = (56 * ratio).round(); // 화살표 칸 — 논리 56px.
  final pad = (12 * ratio).round();
  final scale = ratio / 1.5; // 화살표 굵기·크기도 배율에 맞춘다.
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
      int s(num v) => (v * scale).round();
      img.drawLine(
        canvas,
        x1: x + s(18),
        y1: cy,
        x2: x + gap - s(30),
        y2: cy,
        color: arrow,
        thickness: 7 * scale,
      );
      img.fillPolygon(
        canvas,
        vertices: [
          img.Point(x + gap - s(34), cy - s(16)),
          img.Point(x + gap - s(14), cy),
          img.Point(x + gap - s(34), cy + s(16)),
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
