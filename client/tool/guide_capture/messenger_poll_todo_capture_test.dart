// 초보자용 도움말 "메신저 이용법"(server/guide/messenger.html)의 투표 · 할 일 그림 — 투표 만들기 ·
// 투표하기 · 투표 메뉴 · 투표 목록, 할 일 목록 · 할 일 만들기 · 할 일 카드 · 할 일 상세 · 메시지에서
// 할 일로 등록 · 할 일 일정을 찍는다. 예시 데이터는 messenger_demo.dart(김민지 = 나, 마케팅팀 토픽).
//
// 다시 찍기(client 폴더에서):
//   flutter test tool/guide_capture/messenger_poll_todo_capture_test.dart
// 한 장만:
//   flutter test tool/guide_capture/messenger_poll_todo_capture_test.dart --plain-name "투표 카드"
// 결과: ../server/guide/images/messenger-poll-*.png · messenger-todo-*.png — 그림의 빨간 번호는
// messenger.html의 순서 번호와 짝이 맞아야 하므로, 번호를 바꾸면 HTML도 같이 고친다.
//
// 투표 마감 시각 · 할 일 기한은 "오늘"을 기준으로 만든다(투표는 마감 전이어야 투표할 수 있고, 할 일
// 일정 화면은 이번 달을 연다) — 그래서 다시 찍으면 그림 속 날짜가 그날에 맞춰 바뀐다.
// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'dart:io';
import 'dart:math' as math;

import 'package:client/models/app_user.dart';
import 'package:client/models/room.dart';
import 'package:client/models/todo.dart';
import 'package:client/screens/todo_editor_dialog.dart';
import 'package:client/services/session.dart';
import 'package:client/widgets/chat_input_bar.dart';
import 'package:client/widgets/filter_dropdown.dart';
import 'package:client/widgets/hover_toolbar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'guide_capture.dart';
import 'messenger_demo.dart';

// ───────────────────────────── 날짜 ─────────────────────────────

/// 오늘(자정) — 투표 마감 · 할 일 기한의 기준.
DateTime get today {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day);
}

/// 오늘에서 [days]일 뒤 [hour]:[minute].
DateTime dayAt(int days, int hour, [int minute = 0]) =>
    DateTime(today.year, today.month, today.day + days, hour, minute);

String ymd(DateTime d) => todoDateWire(d);

// ───────────────────────────── 투표 데이터 ─────────────────────────────

Map<String, dynamic> voter(AppUser u) => {'userId': u.id, 'name': u.name};

Map<String, dynamic> option(
  String id,
  String text,
  List<AppUser> voters, {
  bool anonymous = false,
}) => {
  'id': id,
  'text': text,
  'voteCount': voters.length,
  if (!anonymous) 'voters': [for (final v in voters) voter(v)],
};

/// 마케팅팀의 "워크숍 장소" 투표(이도현이 만든 기명 · 한 개 고르기). [voted]면 내가 양평 리조트에 투표한 뒤.
Map<String, dynamic> workshopPoll({bool voted = false}) => {
  'id': 'p-workshop',
  'title': '10월 팀 워크숍 장소를 골라 주세요',
  'description': '1박 2일 일정입니다. 가장 많이 나온 곳으로 예약할게요.',
  'anonymous': false,
  'multiple': false,
  'closesAt': dayAt(3, 18).millisecondsSinceEpoch,
  'closedAt': null,
  'closed': false,
  'creatorId': doHyun.id,
  'voterCount': voted ? 5 : 4,
  'options': [
    option('o1', '양평 리조트', [doHyun, seoYeon, jiWoo, if (voted) me]),
    option('o2', '가평 글램핑', [junHo]),
    option('o3', '강릉 바닷가 호텔', []),
  ],
  'myOptionIds': voted ? ['o1'] : <String>[],
  'favorite': false,
};

/// 점심 메뉴 방의 복수 선택 투표(최준호가 만들었고 아직 내가 안 했다).
Map<String, dynamic> lunchPoll() => {
  'id': 'p-lunch',
  'title': '금요일 팀 점심, 먹고 싶은 메뉴를 모두 골라 주세요',
  'anonymous': false,
  'multiple': true,
  'closesAt': dayAt(1, 11, 30).millisecondsSinceEpoch,
  'closedAt': null,
  'closed': false,
  'creatorId': junHo.id,
  'voterCount': 3,
  'options': [
    option('l1', '칼국수', [doHyun, junHo]),
    option('l2', '돈가스', [junHo, yuNa]),
    option('l3', '샐러드', [yuNa]),
  ],
  'myOptionIds': <String>[],
  'favorite': false,
};

/// 전사 공지의 익명 투표(이미 마감됨).
Map<String, dynamic> surveyPoll() => {
  'id': 'p-survey',
  'title': '사내 카페 새 메뉴 선호도 조사',
  'anonymous': true,
  'multiple': false,
  'closesAt': dayAt(-2, 18).millisecondsSinceEpoch,
  'closedAt': null,
  'closed': true,
  'creatorId': yuNa.id,
  'voterCount': 31,
  'options': [
    {'id': 's1', 'text': '아이스 바닐라 라떼', 'voteCount': 17},
    {'id': 's2', 'text': '자몽 에이드', 'voteCount': 9},
    {'id': 's3', 'text': '말차 라떼', 'voteCount': 5},
  ],
  'myOptionIds': ['s2'],
  'favorite': true,
};

Map<String, dynamic> pollMessage(
  String id,
  String roomId,
  AppUser sender,
  DateTime time,
  Map<String, dynamic> poll,
) => {
  'id': id,
  'roomId': roomId,
  'senderId': sender.id,
  'senderName': sender.name,
  'type': 'poll',
  'text': poll['title'],
  'createdAt': time.millisecondsSinceEpoch,
  'poll': poll,
  'attachments': const <Object>[],
  'comments': const <Object>[],
};

/// 마케팅팀 대화 끝에 워크숍 투표가 올라와 있다.
List<Map<String, dynamic>> pollRoomMessages({bool voted = false}) => [
  ...marketingMessages(),
  pollMessage('mp1', 'r-mkt', doHyun, at(10, 20), workshopPoll(voted: voted)),
];

/// 투표 그림용 방 목록 — 마케팅팀은 나와 이도현이 토픽 관리자(투표 마감 · 삭제 메뉴가 보인다).
List<Room> pollRooms() => demoRoomsWith(replace: [managedMarketing()]);

GuideFakeApi pollApi({bool voted = false}) => demoApi(
  extra: (api) => api
    ..get('/api/rooms/r-mkt/messages', (_) => pollRoomMessages(voted: voted))
    ..put('/api/polls/:id/vote', (_) => workshopPoll(voted: true))
    ..get('/api/polls', {
      'items': [
        {
          ...pollMessage('mp1', 'r-mkt', doHyun, at(10, 20), workshopPoll()),
          'roomName': '마케팅팀',
        },
        {
          ...pollMessage('mp2', 'r-lunch', junHo, at(9, 10), lunchPoll()),
          'roomName': '점심 메뉴 정하기',
        },
        {
          ...pollMessage(
            'mp3',
            'r-notice',
            yuNa,
            at(14, 0, day: 22),
            surveyPoll(),
          ),
          'roomName': '전사 공지',
        },
      ],
      'hasMore': false,
      'total': 3,
    }),
);

Future<Session> openPollRoom(WidgetTester tester, {bool voted = false}) =>
    openDesktop(
      tester,
      session: demoSession(
        api: pollApi(voted: voted),
        rooms: pollRooms(),
      ),
    );

/// 채팅에 그려진 워크숍 투표 카드.
Finder get workshopCard =>
    find.byKey(const ValueKey('poll-card-p-workshop')).first;

/// 투표 카드를 감싼 말풍선(바탕이 칠해진 상자).
Finder get workshopBubble => bubbleBoxOf('10월 팀 워크숍 장소를');

// ───────────────────────────── 할 일 데이터 ─────────────────────────────

Map<String, dynamic> assignee(AppUser u, int progress) => {
  ...userJson(u),
  'progress': progress,
  'completedAt': progress >= 100 ? dayAt(-1, 16).millisecondsSinceEpoch : null,
};

/// 서버 할 일 DTO 한 건(보는 사람 = 나). 담당자가 있으면 전체 진척률은 담당자들의 평균(모두 100이면 100, 모두 0이면 0).
Map<String, dynamic> todoJson({
  required String id,
  required String roomId,
  required String roomName,
  required String title,
  String? description,
  DateTime? start,
  int? startMinutes,
  DateTime? due,
  int? dueMinutes,
  required AppUser creator,
  Map<AppUser, int> assignees = const {},
  int progress = 0,
  bool favorite = false,
  List<(String, int)> files = const [],
  List<DateTime> reminders = const [],
  String? sourceMessageId,
  String? uploadPath,
  required DateTime createdAt,
}) {
  final mine = assignees.keys.any((a) => a.id == me.id);
  final byMe = creator.id == me.id;
  final values = assignees.values.toList();
  final total = values.isEmpty
      ? progress
      : values.every((v) => v >= 100)
      ? 100
      : values.every((v) => v == 0)
      ? 0
      : (values.reduce((a, b) => a + b) / values.length).round().clamp(1, 99);
  final myProgress = mine
      ? assignees.entries.firstWhere((e) => e.key.id == me.id).value
      : (byMe && assignees.isEmpty ? progress : null);
  return {
    'id': id,
    'teamId': tango.id,
    'roomId': roomId,
    'roomName': roomName,
    'title': title,
    'description': description,
    'startDate': start == null ? null : ymd(start),
    'startTime': startMinutes == null ? null : todoTimeWire(startMinutes),
    'dueDate': due == null ? null : ymd(due),
    'dueTime': dueMinutes == null ? null : todoTimeWire(dueMinutes),
    'progress': total,
    'completedAt': total >= 100 ? dayAt(-1, 16).millisecondsSinceEpoch : null,
    'creator': userJson(creator),
    'assignees': [for (final e in assignees.entries) assignee(e.key, e.value)],
    'myProgress': myProgress,
    'canSetProgress': myProgress != null,
    'favorite': favorite,
    'attachments': [
      for (final (i, (name, size)) in files.indexed)
        {
          'id': 'ta-$id-$i',
          'kind': 'file',
          'fileUrl': '/uploads/todo-$id-$i',
          'fileName': name,
          'fileSize': size,
        },
    ],
    'reminders': [
      for (final (i, r) in reminders.indexed)
        {
          'id': 'tr-$id-$i',
          'remindAt': r.millisecondsSinceEpoch,
          'sent': r.isBefore(DateTime.now()),
        },
    ],
    'sourceMessageId': sourceMessageId,
    'uploadPath': uploadPath,
    'myRole': byMe ? 'creator' : (mine ? 'assignee' : 'viewer'),
    'canEdit': byMe || mine,
    'canManage': byMe,
    'createdAt': createdAt.millisecondsSinceEpoch,
    'updatedAt': createdAt.millisecondsSinceEpoch,
  };
}

const bannerTitle = '10월 캠페인 배너 시안 확정';

/// 이도현이 만들어 나(김민지)와 박서연에게 맡긴 할 일 — 박서연은 끝냈고 나는 진행 50%.
Map<String, dynamic> bannerTodo() => todoJson(
  id: 't-banner',
  roomId: 'r-mkt',
  roomName: '마케팅팀',
  title: bannerTitle,
  description: '배너 A안 · B안 중 하나로 확정해서 인쇄소에 넘겨 주세요.\n사이즈는 사양서를 참고하세요.',
  start: dayAt(-1, 0),
  startMinutes: 9 * 60,
  due: dayAt(2, 0),
  dueMinutes: 18 * 60,
  creator: doHyun,
  assignees: {me: 50, seoYeon: 100},
  favorite: true,
  files: [('배너_시안_v2.pdf', 2400 * 1024), ('인쇄_사양서.xlsx', 86 * 1024)],
  reminders: [dayAt(1, 18)],
  createdAt: dayAt(-1, 10, 25),
);

List<Map<String, dynamic>> demoTodos() => [
  bannerTodo(),
  todoJson(
    id: 't-report',
    roomId: 'r-tf',
    roomName: '3분기 캠페인 TF',
    title: '고객사 반응 자료 정리',
    description: '설문 결과와 영업팀 인터뷰 내용을 한 장으로 정리',
    start: dayAt(0, 0),
    due: dayAt(5, 0),
    creator: me,
    assignees: {jiWoo: 50, me: 0},
    createdAt: dayAt(-2, 15, 10),
  ),
  todoJson(
    id: 't-ads',
    roomId: 'r-mkt',
    roomName: '마케팅팀',
    title: '9월 광고비 정산',
    due: dayAt(-1, 0),
    creator: doHyun,
    assignees: {me: 25},
    files: [('9월_광고비.xlsx', 52 * 1024)],
    createdAt: dayAt(-6, 9, 40),
  ),
  todoJson(
    id: 't-minutes',
    roomId: 'r-weekly',
    roomName: '주간회의',
    title: '주간회의 회의록 공유',
    start: dayAt(-3, 0),
    due: dayAt(-3, 0),
    creator: me,
    assignees: {me: 100},
    createdAt: dayAt(-4, 11, 0),
  ),
];

/// 할 일을 만들면 대화방에 올라가는 할 일 카드 메시지(일반 글 + sharedTodo).
Map<String, dynamic> todoCardMessage() {
  const text = '[할 일] $bannerTitle\n담당: @김민지 @박서연';
  final at1 = text.indexOf('@김민지');
  final at2 = text.indexOf('@박서연');
  final t = bannerTodo();
  return {
    'id': 'mt1',
    'roomId': 'r-mkt',
    'senderId': doHyun.id,
    'senderName': doHyun.name,
    'type': 'text',
    'text': text,
    'mentions': [
      {'type': 'user', 'userId': me.id, 's': at1, 'e': at1 + 4},
      {'type': 'user', 'userId': seoYeon.id, 's': at2, 'e': at2 + 4},
    ],
    'createdAt': at(10, 25).millisecondsSinceEpoch,
    'comments': const <Object>[],
    'sharedTodo': {
      'id': t['id'],
      'title': t['title'],
      'description': t['description'],
      'startDate': t['startDate'],
      'startTime': t['startTime'],
      'dueDate': t['dueDate'],
      'dueTime': t['dueTime'],
      'attachments': [
        for (final a in t['attachments'] as List)
          {'kind': 'file', 'fileName': a['fileName']},
      ],
      'attachmentCount': (t['attachments'] as List).length,
      'assigneeNames': [me.name, seoYeon.name],
    },
  };
}

Map<String, dynamic> todoComment(
  String id,
  AppUser author,
  DateTime time,
  String text,
) => {
  'id': id,
  'todoId': 't-banner',
  'roomId': 'r-mkt',
  'authorId': author.id,
  'authorName': author.name,
  'text': text,
  'createdAt': time.millisecondsSinceEpoch,
};

GuideFakeApi todoApi() => demoApi(
  extra: (api) => api
    ..get(
      '/api/rooms/r-mkt/messages',
      (_) => [...marketingMessages(), todoCardMessage()],
    )
    ..get('/api/todos/t-banner/comments', [
      todoComment(
        'tc1',
        seoYeon,
        dayAt(0, 9, 12),
        'B안으로 최종 파일 올려 두었습니다. 확인 부탁드려요!',
      ),
      todoComment('tc2', doHyun, dayAt(0, 9, 30), '좋습니다. 민지 님이 인쇄소에 넘겨 주세요 🙂'),
    ])
    ..get('/api/todos/:id/comments', <Object>[])
    ..get('/api/todos/:id', (http.Request req) {
      final id = req.url.pathSegments.last;
      return demoTodos().firstWhere((t) => t['id'] == id);
    })
    ..get('/api/todos', (http.Request req) {
      final items = demoTodos();
      return {'items': items, 'hasMore': false, 'total': items.length};
    }),
);

Future<Session> openTodoRoom(WidgetTester tester) =>
    openDesktop(tester, session: demoSession(api: todoApi()));

/// 오른쪽 위 메뉴(점 아홉 개) › 할 일 — 할 일 패널을 연다.
Future<void> openTodosPanel(WidgetTester tester) async {
  await tester.tap(topBarButton('메뉴'));
  await settleGuide(tester);
  await tester.tap(find.byKey(const ValueKey('menu-todos')));
  await settleGuide(tester);
}

// ───────────────────────────── 캡처 ─────────────────────────────

void main() {
  // ── 투표 ──

  guideCapture('투표 단추', compact, (tester) async {
    await openPollRoom(tester);
    final input = tester.getRect(find.byType(ChatInputBar));
    await saveGuideShot(
      tester,
      'messenger-poll-button',
      callouts: [
        GuideCallout.box(
          find.byKey(const ValueKey('chat-poll')),
          number: 1,
          badge: CalloutBadge.top,
          padding: 2,
        ),
      ],
      crop: clampToScreen(
        tester,
        Rect.fromLTRB(input.left, input.top - 40, input.right, input.bottom),
      ),
    );
  });

  guideCapture('투표 만들기', tall, (tester) async {
    await openPollRoom(tester);
    await tester.tap(find.byKey(const ValueKey('chat-poll')));
    await settleGuide(tester);
    await tester.enterText(
      find.byKey(const ValueKey('poll-title-field')),
      '10월 팀 워크숍 장소를 골라 주세요',
    );
    await tester.enterText(
      find.byKey(const ValueKey('poll-option-field-0')),
      '양평 리조트',
    );
    await tester.enterText(
      find.byKey(const ValueKey('poll-option-field-1')),
      '가평 글램핑',
    );
    await tester.tap(find.byKey(const ValueKey('poll-add-option')));
    await settleGuide(tester);
    await tester.enterText(
      find.byKey(const ValueKey('poll-option-field-2')),
      '강릉 바닷가 호텔',
    );
    // 입력칸 깜빡이는 커서가 찍히지 않게 포커스를 뺀다.
    FocusManager.instance.primaryFocus?.unfocus();
    await settleGuide(tester);
    final card = tester.getRect(dialogCard);
    await saveGuideShot(
      tester,
      'messenger-poll-create',
      callouts: [
        GuideCallout.box(
          find.byKey(const ValueKey('poll-room-field')),
          number: 2,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(
          find.byKey(const ValueKey('poll-title-field')),
          number: 3,
          badge: CalloutBadge.left,
        ),
        GuideCallout.rect(
          unionRect(tester, [
            find.byKey(const ValueKey('poll-option-field-0')),
            find.byKey(const ValueKey('poll-option-field-2')),
          ]),
          number: 4,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(
          find.byKey(const ValueKey('poll-add-option')),
          number: 5,
          badge: CalloutBadge.left,
          padding: 2,
        ),
      ],
      crop: clampToScreen(
        tester,
        Rect.fromLTRB(
          card.left - 30,
          card.top - 16,
          card.right + 16,
          card.bottom + 16,
        ),
      ),
    );

    // 아래쪽(마감 시각 · 옵션 · 만들기)까지 내린다 — 복수 선택을 켠 모습.
    await tester.drag(
      find.descendant(of: find.byType(Dialog), matching: find.byType(ListView)),
      const Offset(0, -600),
    );
    await settleGuide(tester);
    await tester.tap(find.byKey(const ValueKey('poll-multiple-switch')));
    await settleGuide(tester);
    final closes = find.byKey(const ValueKey('poll-closes-hint'));
    final dateField = find.ancestor(
      of: closes,
      matching: find.byType(ListView),
    );
    expect(dateField, findsOneWidget);
    await saveGuideShot(
      tester,
      'messenger-poll-create-options',
      callouts: [
        GuideCallout.rect(
          unionRect(tester, [find.text('마감 시각'), closes]),
          number: 6,
          badge: CalloutBadge.left,
        ),
        GuideCallout.rect(
          unionRect(tester, [
            find.byKey(const ValueKey('poll-description-switch')),
            find.byKey(const ValueKey('poll-multiple-switch')),
          ]),
          number: 7,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(
          find.byKey(const ValueKey('poll-create-submit')),
          number: 8,
          badge: CalloutBadge.top,
        ),
      ],
      crop: clampToScreen(
        tester,
        Rect.fromLTRB(
          card.left - 30,
          card.top - 16,
          card.right + 16,
          card.bottom + 16,
        ),
      ),
    );
  });

  guideCapture('투표 카드', compact, (tester) async {
    await openPollRoom(tester);
    await tester.tap(find.byKey(const ValueKey('poll-option-o1')));
    await settleGuide(tester);
    final bubble = tester.getRect(workshopBubble);
    await saveGuideShot(
      tester,
      'messenger-poll-card',
      callouts: [
        GuideCallout.box(
          find.byKey(const ValueKey('poll-option-o1')),
          number: 1,
          badge: CalloutBadge.left,
          padding: 3,
        ),
        GuideCallout.box(
          find.byKey(const ValueKey('poll-vote-button')),
          number: 2,
          badge: CalloutBadge.left,
          padding: 3,
        ),
        GuideCallout.box(
          find.byKey(const ValueKey('poll-count-o2')),
          number: 3,
          badge: CalloutBadge.right,
          padding: 3,
        ),
        GuideCallout.box(
          find.byKey(const ValueKey('poll-more')),
          number: 4,
          badge: CalloutBadge.right,
          padding: 2,
        ),
      ],
      crop: clampToScreen(
        tester,
        Rect.fromLTRB(
          math.max(283, bubble.left - 64),
          bubble.top - 40,
          bubble.right + 90,
          bubble.bottom + 16,
        ),
      ),
    );
  });

  guideCapture('투표한 뒤', compact, (tester) async {
    await openPollRoom(tester, voted: true);
    // 서버에 이미 내 표가 들어간 모습(다시 받은 목록) — 투표하기를 누른 직후와 같다.
    final bubble = tester.getRect(workshopBubble);
    await saveGuideShot(
      tester,
      'messenger-poll-voted',
      callouts: [
        GuideCallout.box(
          find.byKey(const ValueKey('poll-option-o1')),
          number: 5,
          badge: CalloutBadge.left,
          padding: 3,
        ),
        GuideCallout.box(
          find.byKey(const ValueKey('poll-revote-button')),
          number: 6,
          badge: CalloutBadge.left,
          padding: 3,
        ),
      ],
      crop: clampToScreen(
        tester,
        Rect.fromLTRB(
          math.max(283, bubble.left - 64),
          bubble.top - 40,
          bubble.right + 90,
          bubble.bottom + 16,
        ),
      ),
    );
  });

  guideCapture('투표 메뉴', compact, (tester) async {
    await openPollRoom(tester, voted: true);
    final bubble = tester.getRect(workshopBubble);
    await tester.tap(find.byKey(const ValueKey('poll-more')));
    await settleGuide(tester);
    Finder item(String text) => find
        .ancestor(
          of: find.text(text),
          matching: find.byType(PopupMenuItem<String>),
        )
        .first;
    final menu = unionRect(tester, [item('댓글'), item('삭제')], padding: 8);
    await saveGuideShot(
      tester,
      'messenger-poll-menu',
      callouts: [
        menuItemCallout(tester, item('댓글'), 1, badge: CalloutBadge.right),
        menuItemCallout(tester, item('즐겨찾기'), 2, badge: CalloutBadge.right),
        menuItemCallout(tester, item('투표 마감'), 3, badge: CalloutBadge.right),
        menuItemCallout(tester, item('삭제'), 4, badge: CalloutBadge.right),
      ],
      crop: clampToScreen(
        tester,
        Rect.fromLTRB(
          math.max(283, bubble.left - 64),
          bubble.top - 40,
          math.max(bubble.right + 90, menu.right + 60),
          math.max(bubble.bottom, menu.bottom) + 16,
        ),
      ),
    );
  });

  guideCapture('투표 목록', desktop, (tester) async {
    await openPollRoom(tester);
    final menuButton = topBarButton('메뉴');
    final menuRect = tester.getRect(menuButton);
    await tester.tap(menuButton);
    await settleGuide(tester);
    await tester.tap(find.byKey(const ValueKey('menu-poll')));
    await settleGuide(tester);
    final panel = byTypeName('PollsScreen');
    final panelRect = tester.getRect(panel);
    await saveGuideShot(
      tester,
      'messenger-poll-list',
      callouts: [
        GuideCallout.rect(
          menuRect.deflate(2),
          number: 1,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(
          find.byKey(const ValueKey('polls-create')),
          number: 2,
          badge: CalloutBadge.left,
          padding: 2,
        ),
        GuideCallout.rect(
          unionRect(tester, [
            find.byType(RoomFilterButton),
            find.byKey(const ValueKey('polls-participated')),
          ], padding: 3),
          number: 3,
          badge: CalloutBadge.left,
        ),
        GuideCallout.rect(
          unionRect(tester, [
            find.byKey(const ValueKey('polls-exclude-closed')),
            find.byKey(const ValueKey('polls-sort')),
          ], padding: 3),
          number: 4,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(
          find.byKey(const ValueKey('polls-goto-mp1')),
          number: 5,
          badge: CalloutBadge.left,
          padding: 1,
        ),
      ],
      crop: clampToScreen(
        tester,
        Rect.fromLTRB(panelRect.left - 40, 0, 1280, 800),
      ),
    );
  });

  // ── 할 일 ──

  guideCapture('할 일 목록', desktop, (tester) async {
    await openTodoRoom(tester);
    final menuRect = tester.getRect(topBarButton('메뉴'));
    await openTodosPanel(tester);
    final panel = byTypeName('TodosPanel');
    final panelRect = tester.getRect(panel);
    final card = find.byKey(const ValueKey('todo-card-frame-t-banner'));
    await saveGuideShot(
      tester,
      'messenger-todo-list',
      callouts: [
        GuideCallout.rect(
          menuRect.deflate(2),
          number: 1,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(
          find.byKey(const ValueKey('todo-calendar-toggle')),
          number: 2,
          badge: CalloutBadge.right,
          padding: 2,
        ),
        GuideCallout.box(
          find.byKey(const ValueKey('todo-create')),
          number: 3,
          badge: CalloutBadge.left,
          padding: 2,
        ),
        GuideCallout.rect(
          unionRect(tester, [
            find.descendant(of: panel, matching: find.byType(RoomFilterButton)),
            find.byKey(const ValueKey('todo-scope')),
          ], padding: 3),
          number: 4,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(card, number: 5, badge: CalloutBadge.left, padding: 2),
        GuideCallout.box(
          find.byKey(const ValueKey('todo-card-menu-t-banner')),
          number: 6,
          badge: CalloutBadge.bottom,
          padding: 1,
        ),
      ],
      crop: clampToScreen(
        tester,
        Rect.fromLTRB(panelRect.left - 40, 0, 1280, 800),
      ),
    );
  });

  guideCapture('할 일 만들기', tall, (tester) async {
    mockPathProvider(tester);
    // 날짜를 고르면 비어 있던 시간에 "지금 이후 가장 가까운 15분"이 채워진다 — 오전 9:00이 되게 한다.
    final clock = todoClock;
    todoClock = () => dayAt(0, 8, 50);
    addTearDown(() => todoClock = clock);
    await openTodoRoom(tester);
    await openTodosPanel(tester);
    await tester.tap(find.byKey(const ValueKey('todo-create')));
    await settleGuide(tester);

    await tester.enterText(
      find.byKey(const ValueKey('todo-title-field')),
      '11월 뉴스레터 원고 작성',
    );
    await tester.enterText(
      find.byKey(const ValueKey('todo-description-field')),
      '신제품 소개 2꼭지 + 고객 사례 1꼭지\n초안은 공유 폴더에 올려 주세요.',
    );
    final dir = Directory.systemTemp.createTempSync('guide_todo_files_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/뉴스레터_기획안.docx')
      ..writeAsBytesSync(List.filled(312 * 1024, 7));
    final editor = tester.state<TodoEditorState>(find.byType(TodoEditor));
    await tester.runAsync(() async {
      editor.addFiles([file]);
      await Future<void>.delayed(const Duration(seconds: 2));
    });
    editor.setUploadPath(r'\\fileserver\마케팅\뉴스레터\11월');
    editor.setAssignees([me, junHo]);
    FocusManager.instance.primaryFocus?.unfocus();
    await settleGuide(tester);

    final card = tester.getRect(dialogCard);
    final cropRect = clampToScreen(
      tester,
      Rect.fromLTRB(
        card.left - 30,
        card.top - 16,
        card.right + 16,
        card.bottom + 16,
      ),
    );
    GuideCallout row(String id, int n) => GuideCallout.box(
      fieldRow(id),
      number: n,
      badge: CalloutBadge.left,
      padding: 4,
    );
    await saveGuideShot(
      tester,
      'messenger-todo-create',
      callouts: [
        row('room', 1),
        GuideCallout.rect(
          unionRect(tester, [fieldRow('title'), fieldRow('description')]),
          number: 2,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(
          find.byKey(const ValueKey('todo-attach')),
          number: 3,
          badge: CalloutBadge.left,
          padding: 3,
        ),
        GuideCallout.box(
          find.byKey(const ValueKey('todo-upload-path-button')),
          number: 4,
          badge: CalloutBadge.left,
          padding: 3,
        ),
      ],
      crop: cropRect,
    );

    // 기간: 칸을 눌러 달력에서 시작일 · 종료일을 고르고, 종료 시간을 오후 6:00으로.
    final scroll = find.descendant(
      of: find.byType(Dialog),
      matching: find.byType(SingleChildScrollView),
    );
    await tester.drag(scroll.first, const Offset(0, -900));
    await settleGuide(tester);
    await tester.tap(find.byKey(const ValueKey('todo-period-field')));
    await settleGuide(tester);
    String dayKey(DateTime d) =>
        'todo-period-day-${d.year}-${d.month}-${d.day}';
    final start = dayAt(1, 0);
    final end = dayAt(4, 0);
    await tester.tap(find.byKey(ValueKey(dayKey(start))));
    await settleGuide(tester);
    if (end.month != start.month) {
      await tester.tap(find.byKey(const ValueKey('todo-period-next')));
      await settleGuide(tester);
    }
    await tester.tap(find.byKey(ValueKey(dayKey(end))));
    await settleGuide(tester);
    await tester.tap(find.byKey(const ValueKey('todo-time-end')));
    await settleGuide(tester);
    final sixPm = find.byKey(const ValueKey('todo-time-option-1080'));
    await tester.scrollUntilVisible(
      sixPm,
      120,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('todo-time-list')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await settleGuide(tester);
    await tester.tap(sixPm);
    await settleGuide(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settleGuide(tester);
    if (find.byKey(const ValueKey('todo-period-popup')).evaluate().isNotEmpty) {
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settleGuide(tester);
    }

    // 알림: 기한 하루 전.
    await tester.tap(find.byKey(const ValueKey('todo-reminder-add')));
    await settleGuide(tester);
    await tester.tap(find.byKey(const ValueKey('todo-reminder-option-day')));
    await settleGuide(tester);
    await tester.drag(scroll.first, const Offset(0, -900));
    await settleGuide(tester);

    await saveGuideShot(
      tester,
      'messenger-todo-create-more',
      callouts: [
        row('assignees', 5),
        row('period', 6),
        row('reminders', 7),
        GuideCallout.box(
          find.byKey(const ValueKey('todo-announce')),
          number: 8,
          badge: CalloutBadge.left,
          padding: 2,
        ),
        GuideCallout.box(
          find.byKey(const ValueKey('todo-submit')),
          number: 9,
          badge: CalloutBadge.top,
          padding: 3,
        ),
      ],
      crop: cropRect,
    );
  });

  guideCapture('할 일 카드', compact, (tester) async {
    await openTodoRoom(tester);
    final card = find.byKey(const ValueKey('todo-card-mt1'));
    final cardRect = tester.getRect(card);
    await saveGuideShot(
      tester,
      'messenger-todo-card',
      callouts: [
        GuideCallout.box(card, number: 1, badge: CalloutBadge.left, padding: 4),
        GuideCallout.box(
          find.byKey(const ValueKey('todo-card-progress')),
          number: 2,
          badge: CalloutBadge.right,
          padding: 3,
        ),
      ],
      crop: clampToScreen(
        tester,
        Rect.fromLTRB(
          math.max(283, cardRect.left - 80),
          cardRect.top - 50,
          cardRect.right + 110,
          cardRect.bottom + 24,
        ),
      ),
    );
  });

  guideCapture('할 일 상세', detailSurface, (tester) async {
    await openTodoRoom(tester);
    await tester.tap(find.byKey(const ValueKey('todo-card-mt1')));
    await settleGuide(tester);
    final panel = byTypeName('TodosPanel');
    final panelRect = tester.getRect(panel);
    expect(find.byKey(const ValueKey('todo-detail-title')), findsOneWidget);
    await saveGuideShot(
      tester,
      'messenger-todo-detail',
      callouts: [
        GuideCallout.rect(
          unionRect(tester, [
            find.byKey(const ValueKey('todo-detail-star')),
            find.byKey(const ValueKey('todo-detail-menu')),
          ], padding: 2),
          number: 1,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(
          find.byKey(const ValueKey('todo-detail-my-progress')),
          number: 2,
          badge: CalloutBadge.left,
          padding: 3,
        ),
        GuideCallout.rect(
          () {
            final r = unionRect(tester, [
              find.byKey(const ValueKey('todo-detail-period')),
              find.byKey(const ValueKey('todo-detail-reminders')),
            ], padding: 4);
            return Rect.fromLTRB(r.left - 30, r.top, r.right, r.bottom);
          }(),
          number: 3,
          badge: CalloutBadge.left,
        ),
        GuideCallout.rect(
          () {
            final label = tester.getRect(
              find.descendant(of: panel, matching: find.text('첨부')),
            );
            final last = tester.getRect(
              find.descendant(of: panel, matching: find.text('인쇄_사양서.xlsx')),
            );
            return Rect.fromLTRB(
              label.left - 6,
              label.top - 6,
              panelRect.right - 16,
              last.bottom + 20,
            );
          }(),
          number: 4,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(
          find.byKey(const ValueKey('todo-comment-input')),
          number: 5,
          badge: CalloutBadge.left,
          padding: 4,
        ),
      ],
      crop: clampToScreen(
        tester,
        Rect.fromLTRB(
          panelRect.left - 40,
          panelRect.top,
          panelRect.right,
          panelRect.bottom,
        ),
      ),
    );

    // 내 진척률 고르기(대기 · 진행 · 완료).
    await tester.tap(find.byKey(const ValueKey('todo-detail-my-progress')));
    await settleGuide(tester);
    final options = [
      for (final p in todoProgressSteps)
        find.byKey(ValueKey('todo-progress-option-$p')),
    ];
    final menu = unionRect(tester, [options.first, options.last], padding: 8);
    final select = tester.getRect(
      find.byKey(const ValueKey('todo-detail-my-progress')),
    );
    await saveGuideShot(
      tester,
      'messenger-todo-progress',
      callouts: [
        menuItemCallout(tester, options.last, 6, badge: CalloutBadge.left),
      ],
      crop: clampToScreen(
        tester,
        Rect.fromLTRB(
          panelRect.left,
          math.min(menu.top, select.top) - 60,
          panelRect.right,
          math.max(menu.bottom, select.bottom) + 24,
        ),
      ),
    );
  });

  guideCapture('할 일로 등록', GuideSurface(Size(1100, 1000)), (tester) async {
    await openTodoRoom(tester);
    // 파일이 붙은 메시지(기획안 초안)의 ⋮ › 할 일로 등록 — 메시지 메뉴 그림은 messenger-message-menu.
    final caption = find.textContaining('기획안 초안 공유', findRichText: true).first;
    await mouseAt(tester, tester.getRect(caption).center);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(
      find.descendant(
        of: find.byType(HoverToolbar),
        matching: find.byIcon(Icons.more_vert),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(
      find
          .ancestor(
            of: find.text('할 일로 등록'),
            matching: find.byType(MenuItemButton),
          )
          .first,
    );
    await settleGuide(tester);
    FocusManager.instance.primaryFocus?.unfocus();
    await settleGuide(tester);
    final card = tester.getRect(dialogCard);
    final files = tester.getRect(fieldRow('files'));
    await saveGuideShot(
      tester,
      'messenger-todo-from-message',
      callouts: [
        GuideCallout.box(
          find.byKey(const ValueKey('todo-room-locked')),
          number: 1,
          badge: CalloutBadge.left,
          padding: 3,
        ),
        GuideCallout.rect(
          unionRect(tester, [fieldRow('title'), fieldRow('description')]),
          number: 2,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(
          byTypeName('_FileTile'),
          number: 3,
          badge: CalloutBadge.left,
          padding: 3,
        ),
      ],
      crop: clampToScreen(
        tester,
        Rect.fromLTRB(
          card.left - 30,
          card.top - 16,
          card.right + 16,
          files.bottom + 24,
        ),
      ),
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  guideCapture('할 일 일정', detailSurface, (tester) async {
    await openTodoRoom(tester);
    await openTodosPanel(tester);
    await tester.tap(find.byKey(const ValueKey('todo-calendar-toggle')));
    await settleGuide(tester);
    final panel = byTypeName('TodosPanel');
    final panelRect = tester.getRect(panel);
    final groups = find.byWidgetPredicate(
      (w) =>
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('todo-cal-room-'),
    );
    await saveGuideShot(
      tester,
      'messenger-todo-calendar',
      callouts: [
        GuideCallout.rect(
          unionRect(tester, [
            find.byKey(const ValueKey('todo-cal-prev-year')),
            find.byKey(const ValueKey('todo-cal-next-year')),
          ], padding: 3),
          number: 1,
          badge: CalloutBadge.right,
        ),
        GuideCallout.box(
          find.byKey(const ValueKey('todo-cal-today')),
          number: 2,
          badge: CalloutBadge.left,
          padding: 2,
        ),
        GuideCallout.box(
          find.byKey(const ValueKey('todo-cal-selected')),
          number: 3,
          badge: CalloutBadge.topLeft,
          padding: 4,
        ),
        GuideCallout.rect(
          unionRect(tester, [
            find.byKey(const ValueKey('todo-cal-day-count')),
            groups.last,
          ], padding: 4),
          number: 4,
          badge: CalloutBadge.left,
        ),
      ],
      crop: clampToScreen(
        tester,
        Rect.fromLTRB(
          panelRect.left - 40,
          panelRect.top,
          panelRect.right,
          tester.getRect(groups.last).bottom + 30,
        ),
      ),
    );
  });
}

/// 할 일 패널 안 화면(상세 · 일정)을 한 장에 담으려고 키를 높인 PC 창.
const detailSurface = GuideSurface(Size(1280, 1000));

/// 대화상자가 잘리지 않게 키를 높인 PC 창(투표 · 할 일 만들기 창은 높이가 780까지 늘어난다).
const tall = GuideSurface(Size(1100, 860));

/// 할 일 만들기 창의 한 줄(왼쪽 회색 아이콘 + 칸) — [id]는 room · title · description · files · assignees · period · reminders.
Finder fieldRow(String id) => find
    .ancestor(
      of: find.byKey(ValueKey('todo-label-$id')),
      matching: byTypeName('_FieldRow'),
    )
    .first;
