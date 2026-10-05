// 초보자용 도움말 "프로젝트 이용법"(server/guide/project.html)의 스크린샷을 찍는다.
//
// 다시 찍기(client 폴더에서):
//   flutter test tool/guide_capture/project_capture_test.dart
// 한 장만: flutter test tool/guide_capture/project_capture_test.dart --plain-name "새 프로젝트"
// 결과: ../server/guide/images/project-*.png (앱 화면이 바뀌면 다시 실행해서 덮어쓴다)
//
// 진짜 프로젝트 창(ProjectDialog)을 가짜 서버 응답(GuideFakeApi)과 예시 데이터(탱고컴퍼니 ·
// 김민지 · 신제품 출시(NPL) 등)로 채워 그린다 — guide_capture.dart 참고. 사람 이름·팀 이름은
// 메신저 이용법(messenger_capture_test.dart)과 같게 맞춘다.
import 'dart:math' as math;

import 'package:client/models/app_user.dart';
import 'package:client/models/room.dart';
import 'package:client/models/team.dart';
import 'package:client/screens/chat_screen.dart';
import 'package:client/screens/desktop_home_screen.dart';
import 'package:client/screens/project/filter_controls.dart';
import 'package:client/screens/project/project_dialog.dart';
import 'package:client/screens/project/task_detail_panel.dart';
import 'package:client/screens/project/task_views.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:client/widgets/dashed_add_button.dart';
import 'package:client/widgets/message_bubble.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'guide_capture.dart';

// ───────────────────────────── 테스트 환경 ─────────────────────────────

/// 캡처와 상관없는 디버그 경고를 걸러 낸다 — PC(windows) 모드에서 컨트롤러 없이 붙은
/// 스크롤바가 "ScrollPosition이 없다"는 디버그 단언을 낸다. 대시보드·설정 칸 등은 앱에서 고쳤지만
/// 다른 화면에 남아 있어도 그림에는 영향이 없어 안전하게 그대로 둔다. 나머지 오류는 테스트 실패로 둔다.
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

// ───────────────────────────── 예시 데이터 ─────────────────────────────

/// 날짜는 "오늘" 기준으로 정한다 — 홈 화면의 "이번 주 나의 업무"·지연 표시가 실제 날짜로 계산되기 때문.
final DateTime today = () {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day);
}();
DateTime day(int offset, [int hour = 9, int minute = 0]) =>
    DateTime(today.year, today.month, today.day + offset, hour, minute);
int ms(DateTime d) => d.millisecondsSinceEpoch;

AppUser person(String id, String name, String color) => AppUser(
  id: id,
  username: id,
  name: name,
  avatarColor: color,
  role: 'member',
);

final me = person('u-me', '김민지', '#F06595');
final doHyun = person('u-dh', '이도현', '#339AF0');
final seoYeon = person('u-sy', '박서연', '#51CF66');
final junHo = person('u-jh', '최준호', '#FF922B');
final yuNa = person('u-yn', '정유나', '#845EF7');
final jiWoo = person('u-jw', '한지우', '#20C997');
final everyone = [me, doHyun, seoYeon, junHo, yuNa, jiWoo];

Map<String, dynamic> userJson(AppUser u, {String? projectRole}) => {
  'id': u.id,
  'username': u.username,
  'name': u.name,
  'avatarType': 'initial',
  'avatarColor': u.avatarColor,
  'role': u.role,
  'projectRole': ?projectRole,
};

final tango = Team(
  id: 't-tango',
  name: '탱고컴퍼니',
  iconEmoji: '🚀',
  iconColor: '#4C6EF5',
  createdAt: DateTime(2025, 3, 2),
);

/// 자동화 "채팅방 알림"에서 고를 수 있는 대화방.
final launchRoom = Room(
  id: 'r-launch',
  teamId: tango.id,
  type: RoomType.topic,
  name: '신제품 런칭',
  members: everyone,
  createdAt: DateTime(2025, 3, 2),
  lastRead: const {},
);

// ── 프로젝트 ──

class DemoProject {
  final String id;
  final String name;
  final String key;
  final String color;
  final String? description;
  final bool isPublic;
  final bool favorite;
  final bool owner;
  final bool archived;
  final int total;
  final int done;
  const DemoProject(
    this.id,
    this.name,
    this.key,
    this.color, {
    this.description,
    this.isPublic = true,
    this.favorite = false,
    this.owner = false,
    this.archived = false,
    this.total = 0,
    this.done = 0,
  });
}

const npl = DemoProject(
  'p-npl',
  '신제품 출시',
  'NPL',
  '#5B8DEF',
  description: '가을 신제품 출시 준비 — 기획부터 홍보까지 함께 챙겨요.',
  favorite: true,
  owner: true,
  total: 10,
  done: 2,
);
const web = DemoProject(
  'p-web',
  '홈페이지 개편',
  'WEB',
  '#10B981',
  description: '회사 홈페이지를 새 디자인으로 바꿉니다.',
  isPublic: false,
  total: 8,
  done: 5,
);
const csr = DemoProject(
  'p-csr',
  '고객 설문 조사',
  'CSR',
  '#F59E0B',
  total: 6,
  done: 1,
);
const edu = DemoProject(
  'p-edu',
  '신입 사원 교육',
  'EDU',
  '#A78BFA',
  owner: true,
  total: 4,
  done: 4,
);
const evt = DemoProject(
  'p-evt',
  '연말 행사 준비',
  'EVT',
  '#F472B6',
  description: '12월 송년회와 시상식을 준비합니다.',
  isPublic: false,
  owner: true,
  total: 5,
  done: 0,
);
const ws = DemoProject(
  'p-ws',
  '상반기 워크숍',
  'WS',
  '#64748B',
  archived: true,
  total: 7,
  done: 7,
);

const activeProjects = [npl, web, csr, edu, evt];
const allProjects = [...activeProjects, ws];

/// 프로젝트별 구성원(역할). 공개 프로젝트는 정회원 이상 팀원 모두가 멤버다.
Map<String, String> membersOf(DemoProject p) => switch (p.id) {
  'p-evt' => {
    'u-me': 'owner',
    'u-yn': 'owner',
    'u-sy': 'member',
    'u-jw': 'member',
  },
  'p-web' => {'u-jh': 'owner', 'u-me': 'member', 'u-sy': 'member'},
  'p-npl' => {
    'u-me': 'owner',
    'u-dh': 'owner',
    'u-sy': 'member',
    'u-jh': 'member',
    'u-yn': 'member',
    'u-jw': 'member',
  },
  _ => {
    for (final u in everyone)
      u.id: u.id == 'u-me' && p.owner ? 'owner' : 'member',
  },
};

const demoTemplate = {
  'id': 'tpl-launch',
  'name': '제품 출시 기본',
  'description': '기획 → 디자인 → 개발 → 홍보 순서로 진행하는 출시 프로젝트',
  'creatorName': '이도현',
  'canEdit': false,
  'statuses': [
    {'name': '할 일', 'color': '#94A3B8', 'category': 'todo'},
    {'name': '진행 중', 'color': '#F59E0B', 'category': 'doing'},
    {'name': '검토', 'color': '#8B5CF6', 'category': 'doing'},
    {'name': '완료', 'color': '#10B981', 'category': 'done'},
  ],
  'types': [
    {'name': '기획', 'color': '#5B8DEF'},
    {'name': '디자인', 'color': '#F472B6'},
    {'name': '개발', 'color': '#10B981'},
    {'name': '홍보', 'color': '#F59E0B'},
  ],
  'priorities': [
    {'name': '긴급', 'color': '#DC2626', 'level': 'high'},
    {'name': '높음', 'color': '#EF4444', 'level': 'high'},
    {'name': '보통', 'color': '#5B8DEF', 'level': 'normal'},
    {'name': '낮음', 'color': '#94A3B8', 'level': 'low'},
  ],
  'fields': [],
};

/// [demoTemplate]의 구성을 이름만 바꿔 쓴다.
Map<String, dynamic> _templateLike(
  String id,
  String name,
  String description,
  String creator,
  List<(String, String)> types,
) => {
  ...demoTemplate,
  'id': id,
  'name': name,
  'description': description,
  'creatorName': creator,
  'types': [
    for (final (n, c) in types) {'name': n, 'color': c},
  ],
};

final otherTemplates = [
  _templateLike('tpl-event', '사내 행사', '행사 준비용 — 섭외 · 준비물 · 당일 진행', '정유나', [
    ('섭외', '#5B8DEF'),
    ('준비물', '#F59E0B'),
    ('당일 진행', '#10B981'),
  ]),
  _templateLike('tpl-web', '웹사이트 제작', '디자인 시안부터 오픈까지', '최준호', [
    ('디자인', '#F472B6'),
    ('개발', '#10B981'),
    ('콘텐츠', '#5B8DEF'),
  ]),
];

Map<String, dynamic> projectJson(DemoProject p, {bool detail = false}) {
  final roles = membersOf(p);
  return {
    'id': p.id,
    'teamId': tango.id,
    'name': p.name,
    'description': p.description,
    'identifier': p.key,
    'color': p.color,
    'isPublic': p.isPublic,
    'archived': p.archived,
    'favorite': p.favorite,
    'myRole': p.owner ? 'owner' : 'member',
    'taskTotal': p.total,
    'taskDone': p.done,
    'createdAt': ms(day(-40)),
    'noteEditPermission': 'all',
    'noteDeletePermission': 'creator_admin',
    if (p.id == npl.id) 'templateId': demoTemplate['id'],
    if (detail && p.id == npl.id) 'template': demoTemplate,
    if (detail)
      'members': [
        for (final u in everyone)
          if (roles.containsKey(u.id)) userJson(u, projectRole: roles[u.id]),
      ],
  };
}

// ── 상태 · 유형 · 우선순위(프로젝트마다 같은 구성을 쓴다 — "제품 출시 기본" 템플릿) ──

typedef Def = ({String id, String name, String color, String cat});

const statuses = <Def>[
  (id: 's-todo', name: '할 일', color: '#94A3B8', cat: 'todo'),
  (id: 's-doing', name: '진행 중', color: '#F59E0B', cat: 'doing'),
  (id: 's-review', name: '검토', color: '#8B5CF6', cat: 'doing'),
  (id: 's-done', name: '완료', color: '#10B981', cat: 'done'),
];
const types = <Def>[
  (id: 'ty-plan', name: '기획', color: '#5B8DEF', cat: ''),
  (id: 'ty-design', name: '디자인', color: '#F472B6', cat: ''),
  (id: 'ty-dev', name: '개발', color: '#10B981', cat: ''),
  (id: 'ty-pr', name: '홍보', color: '#F59E0B', cat: ''),
];
const priorities = <Def>[
  (id: 'pr-urgent', name: '긴급', color: '#DC2626', cat: 'high'),
  (id: 'pr-high', name: '높음', color: '#EF4444', cat: 'high'),
  (id: 'pr-normal', name: '보통', color: '#5B8DEF', cat: 'normal'),
  (id: 'pr-low', name: '낮음', color: '#94A3B8', cat: 'low'),
];

Def def(List<Def> list, String id) => list.firstWhere((d) => d.id == id);

List<Map<String, dynamic>> statusesJson(String projectId) => [
  for (final (i, s) in statuses.indexed)
    {
      'id': s.id,
      'projectId': projectId,
      'name': s.name,
      'color': s.color,
      'category': s.cat,
      'position': i,
    },
];
List<Map<String, dynamic>> typesJson(String projectId) => [
  for (final (i, t) in types.indexed)
    {
      'id': t.id,
      'projectId': projectId,
      'name': t.name,
      'color': t.color,
      'position': i,
    },
];
List<Map<String, dynamic>> prioritiesJson(String projectId) => [
  for (final (i, p) in priorities.indexed)
    {
      'id': p.id,
      'projectId': projectId,
      'name': p.name,
      'color': p.color,
      'level': p.cat,
      'position': i,
    },
];

// ── 업무 ──

class DemoTask {
  final int seq;
  final String title;
  final String status;
  final String? type;
  final String? priority;
  final AppUser? assignee;
  final List<AppUser> refs;
  final int? start;
  final int? due;
  final int comments;
  final int checkDone;
  final int checkTotal;
  final AppUser creator;
  final int created;
  final DemoProject project;
  final bool archived;
  const DemoTask(
    this.seq,
    this.title,
    this.status, {
    this.type,
    this.priority,
    this.assignee,
    this.refs = const [],
    this.start,
    this.due,
    this.comments = 0,
    this.checkDone = 0,
    this.checkTotal = 0,
    required this.creator,
    this.created = -10,
    this.project = npl,
    this.archived = false,
  });

  String get id => 't-${project.key.toLowerCase()}-$seq';
  String get key => '${project.key}-$seq';
}

final nplTasks = [
  DemoTask(
    1001,
    '출시 일정 확정 회의',
    's-done',
    type: 'ty-plan',
    priority: 'pr-urgent',
    assignee: me,
    start: -12,
    due: -9,
    creator: doHyun,
    created: -14,
  ),
  DemoTask(
    1002,
    '제품 소개 페이지 문구 작성',
    's-doing',
    type: 'ty-plan',
    priority: 'pr-high',
    assignee: me,
    refs: [doHyun],
    start: -3,
    due: 2,
    comments: 3,
    checkDone: 2,
    checkTotal: 4,
    creator: doHyun,
    created: -8,
  ),
  DemoTask(
    1003,
    '출시 이벤트 배너 디자인',
    's-review',
    type: 'ty-design',
    priority: 'pr-normal',
    assignee: seoYeon,
    start: -5,
    due: 1,
    comments: 2,
    creator: me,
    created: -7,
  ),
  DemoTask(
    1004,
    'SNS 티저 영상 제작',
    's-doing',
    type: 'ty-design',
    priority: 'pr-high',
    assignee: jiWoo,
    start: -6,
    due: -1,
    comments: 1,
    creator: me,
    created: -7,
  ),
  DemoTask(
    1005,
    '보도자료 초안 작성',
    's-todo',
    type: 'ty-pr',
    priority: 'pr-high',
    assignee: me,
    start: 1,
    due: 5,
    creator: doHyun,
    created: -6,
  ),
  DemoTask(
    1006,
    '쇼핑몰 상품 등록',
    's-todo',
    type: 'ty-dev',
    priority: 'pr-normal',
    assignee: junHo,
    start: 3,
    due: 8,
    creator: doHyun,
    created: -5,
  ),
  DemoTask(
    1007,
    '패키지 사진 촬영',
    's-done',
    type: 'ty-design',
    priority: 'pr-normal',
    assignee: seoYeon,
    start: -10,
    due: -6,
    creator: me,
    created: -12,
  ),
  DemoTask(
    1008,
    '가격 정책 검토',
    's-review',
    type: 'ty-plan',
    priority: 'pr-urgent',
    assignee: doHyun,
    refs: [me],
    start: -2,
    due: 3,
    comments: 4,
    creator: doHyun,
    created: -4,
  ),
  DemoTask(
    1009,
    '체험단 모집 공고',
    's-todo',
    type: 'ty-pr',
    priority: 'pr-low',
    assignee: yuNa,
    start: 4,
    due: 10,
    creator: me,
    created: -3,
  ),
  DemoTask(
    1010,
    '고객 문의 응대 매뉴얼',
    's-doing',
    type: 'ty-plan',
    priority: 'pr-normal',
    assignee: junHo,
    start: 0,
    due: 6,
    creator: yuNa,
    created: -2,
  ),
];

/// 다른 프로젝트에서 내가 맡은 업무(홈 · 내 업무용).
final otherMyTasks = [
  DemoTask(
    1003,
    '메인 화면 시안 검토',
    's-review',
    type: 'ty-design',
    priority: 'pr-high',
    assignee: me,
    start: -1,
    due: 1,
    creator: junHo,
    project: web,
  ),
  DemoTask(
    1002,
    '설문 문항 초안',
    's-doing',
    type: 'ty-plan',
    priority: 'pr-normal',
    assignee: me,
    start: 0,
    due: 3,
    creator: doHyun,
    project: csr,
  ),
];

Map<String, dynamic> taskJson(DemoTask t, {bool detail = false}) {
  final s = def(statuses, t.status);
  final ty = t.type == null ? null : def(types, t.type!);
  final pr = t.priority == null ? null : def(priorities, t.priority!);
  return {
    'id': t.id,
    'projectId': t.project.id,
    'projectName': t.project.name,
    'key': t.key,
    'title': t.title,
    'status': s.cat,
    'statusId': s.id,
    'statusName': s.name,
    'statusColor': s.color,
    'priority': pr?.cat ?? 'normal',
    'priorityId': pr?.id,
    'priorityName': pr?.name,
    'priorityColor': pr?.color,
    'typeId': ty?.id,
    'typeName': ty?.name,
    'typeColor': ty?.color,
    'assigneeId': t.assignee?.id,
    'assigneeName': t.assignee?.name,
    'assigneeAvatarColor': t.assignee?.avatarColor,
    'referenceIds': [for (final u in t.refs) u.id],
    'creatorId': t.creator.id,
    'creatorName': t.creator.name,
    'creatorAvatarColor': t.creator.avatarColor,
    'startDate': t.start == null ? null : ms(day(t.start!)),
    'dueDate': t.due == null ? null : ms(day(t.due!, 18)),
    'createdAt': ms(day(t.created, 10, 20)),
    'commentCount': t.comments,
    'checklistDone': t.checkDone,
    'checklistTotal': t.checkTotal,
    'archived': t.archived,
    'description': ?(detail ? taskDescription(t) : null),
    if (detail) ...{
      'checklist': checklistOf(t),
      'subtasks': <Map<String, dynamic>>[],
      'comments': commentsOf(t),
      'activities': <Map<String, dynamic>>[],
    },
  };
}

String? taskDescription(DemoTask t) => t.seq == 1002 && t.project == npl
    ? '제품 소개 페이지에 들어갈 문구를 씁니다.\n핵심 기능 3가지와 가격 안내를 포함해 주세요.'
    : null;

List<Map<String, dynamic>> checklistOf(DemoTask t) {
  if (!(t.seq == 1002 && t.project == npl)) return const [];
  const items = [
    ('핵심 기능 3가지 정리', true),
    ('제품 이름 표기 확인', true),
    ('가격 안내 문구', false),
    ('법무팀 검토 요청', false),
  ];
  return [
    for (final (i, (text, done)) in items.indexed)
      {'id': 'c$i', 'taskId': t.id, 'text': text, 'done': done, 'position': i},
  ];
}

List<Map<String, dynamic>> commentsOf(DemoTask t) {
  if (!(t.seq == 1002 && t.project == npl)) return const [];
  Map<String, dynamic> c(String id, AppUser u, DateTime at, String text) => {
    'id': id,
    'taskId': t.id,
    'projectId': npl.id,
    'senderId': u.id,
    'senderName': u.name,
    'text': text,
    'createdAt': ms(at),
  };
  final now = DateTime.now();
  return [
    c(
      'tc1',
      doHyun,
      now.subtract(const Duration(days: 1, hours: 3)),
      '초안 나오면 공유 부탁해요. 금요일 회의 때 같이 봐요.',
    ),
    c(
      'tc2',
      me,
      now.subtract(const Duration(days: 1, hours: 2, minutes: 40)),
      '네, 목요일까지 올려 두겠습니다!',
    ),
    c(
      'tc3',
      seoYeon,
      now.subtract(const Duration(minutes: 5)),
      '배너에 들어갈 문구도 같이 맞춰 주시면 좋겠어요 🙂',
    ),
  ];
}

// ── 노트 ──

Map<String, dynamic> noteJson(
  String id,
  int no,
  String title,
  String preview,
  AppUser author,
  DateTime updated, {
  DemoProject project = npl,
  String? body,
}) => {
  'id': id,
  'key': '${project.key}-N$no',
  'projectId': project.id,
  'projectName': project.name,
  'projectColor': project.color,
  'title': title,
  'preview': preview,
  'body': ?body,
  'createdBy': author.id,
  'createdByName': author.name,
  'createdByAvatarType': 'initial',
  'createdByAvatarColor': author.avatarColor,
  'updatedByName': author.name,
  'createdAt': ms(updated.subtract(const Duration(days: 1))),
  'updatedAt': ms(updated),
  'canEdit': true,
  'canDelete': author.id == me.id,
};

const meetingBody =
    '## 결정한 것\n'
    '- 출시일은 **10월 20일**로 확정\n'
    '- 사전 예약은 10월 13일부터\n'
    '\n'
    '## 할 일\n'
    '- [x] 보도자료 일정 공유\n'
    '- [ ] 체험단 모집 공고 올리기\n'
    '- [ ] 쇼핑몰 상품 등록 확인\n'
    '\n'
    '> 다음 회의: 금요일 오후 2시';

List<Map<String, dynamic>> demoNotes() => [
  noteJson(
    'n-meeting',
    3,
    '출시 준비 회의록',
    '출시일은 10월 20일로 확정 · 사전 예약은 10월 13일부터',
    me,
    day(-1, 17, 40),
    body: meetingBody,
  ),
  noteJson(
    'n-press',
    2,
    '보도자료 작성 가이드',
    '제목은 30자 이내로, 첫 문단에 핵심을 담아요',
    doHyun,
    day(-2, 15, 10),
  ),
  noteJson(
    'n-tone',
    1,
    '브랜드 톤앤매너',
    '친근하지만 가볍지 않게 — 존댓말, 짧은 문장',
    seoYeon,
    day(-6, 11, 0),
  ),
  noteJson(
    'n-sitemap',
    1,
    '사이트맵 초안',
    '회사 소개 · 제품 · 고객 지원 · 채용',
    junHo,
    day(-3, 17, 40),
    project: web,
  ),
];

// ── 알림 ──

List<Map<String, dynamic>> demoNotifications() {
  Map<String, dynamic> n(
    String id,
    String kind,
    DemoProject p,
    String? taskKey,
    String body,
    DateTime at, {
    bool read = false,
    String? taskId,
  }) => {
    'id': id,
    'projectId': p.id,
    'projectName': p.name,
    'projectColor': p.color,
    'taskId': taskId,
    'kind': kind,
    'title': taskKey == null ? p.name : '${p.name} · $taskKey',
    'body': body,
    'createdAt': ms(at),
    'read': read,
  };
  final now = DateTime.now();
  return [
    n(
      'pn1',
      'comment',
      npl,
      'NPL-1002',
      '박서연: 배너에 들어갈 문구도 같이 맞춰 주시면 좋겠어요 🙂',
      now.subtract(const Duration(minutes: 5)),
      taskId: 't-npl-1002',
    ),
    n(
      'pn2',
      'assigned',
      npl,
      'NPL-1005',
      '이도현님이 업무를 배정했습니다: 보도자료 초안 작성',
      now.subtract(const Duration(minutes: 42)),
      taskId: 't-npl-1005',
    ),
    n(
      'pn3',
      'due',
      web,
      'WEB-1003',
      '마감이 임박했습니다: 메인 화면 시안 검토',
      now.subtract(const Duration(hours: 2)),
      taskId: 't-web-1003',
    ),
    n(
      'pn4',
      'status',
      npl,
      'NPL-1003',
      "박서연님이 상태를 '검토'(으)로 바꿨습니다: 출시 이벤트 배너 디자인",
      now.subtract(const Duration(hours: 5)),
      read: true,
      taskId: 't-npl-1003',
    ),
    n(
      'pn5',
      'project_created',
      csr,
      null,
      '이도현님이 공개 프로젝트를 만들었습니다: 고객 설문 조사',
      now.subtract(const Duration(days: 1, hours: 2)),
      read: true,
    ),
  ];
}

// ── 가짜 서버 ──

List<DemoTask> tasksOf(String projectId) => [
  for (final t in [...nplTasks, ...otherMyTasks])
    if (t.project.id == projectId) t,
];

DemoTask? taskById(String id) =>
    [...nplTasks, ...otherMyTasks].where((t) => t.id == id).firstOrNull;

DemoProject? projectById(String id) =>
    allProjects.where((p) => p.id == id).firstOrNull;

GuideFakeApi demoApi() {
  final myTasks = [
    for (final t in [...nplTasks, ...otherMyTasks])
      if (t.assignee?.id == me.id) t,
  ];
  final api = GuideFakeApi()
    // 더 구체적인 경로를 먼저 — '/api/projects/:id'가 'home'·'folders'·'templates'를 삼키지 않게.
    ..get('/api/projects/home', {
      'stats': {'total': 5, 'done': 1, 'doing': 3, 'overdue': 0},
      'projects': [for (final p in activeProjects) projectJson(p)],
      'myTasks': [for (final t in myTasks) taskJson(t)],
      'recentComments': [
        {
          'id': 'rc1',
          'taskId': 't-npl-1002',
          'projectId': npl.id,
          'senderId': seoYeon.id,
          'senderName': seoYeon.name,
          'text': '배너에 들어갈 문구도 같이 맞춰 주시면 좋겠어요 🙂',
          'createdAt': ms(DateTime.now().subtract(const Duration(minutes: 5))),
          'taskTitle': '제품 소개 페이지 문구 작성',
          'taskKey': 'NPL-1002',
          'projectName': npl.name,
        },
        {
          'id': 'rc2',
          'taskId': 't-npl-1008',
          'projectId': npl.id,
          'senderId': doHyun.id,
          'senderName': doHyun.name,
          'text': '경쟁사 가격표 첨부했습니다. 확인 부탁드려요.',
          'createdAt': ms(day(-1, 17, 30)),
          'taskTitle': '가격 정책 검토',
          'taskKey': 'NPL-1008',
          'projectName': npl.name,
        },
      ],
    })
    ..get('/api/projects/folders', [
      {
        'id': 'f-mkt',
        'name': '마케팅',
        'position': 0,
        'collapsed': false,
        'projectIds': [web.id, csr.id],
      },
    ])
    ..get('/api/projects/templates', [demoTemplate, ...otherTemplates])
    ..get('/api/projects', (http.Request req) {
      final archived = req.url.queryParameters['archived'] == '1';
      return [
        for (final p in allProjects)
          if (p.archived == archived) projectJson(p),
      ];
    })
    ..get('/api/projects/:id/tasks', (http.Request req) {
      final id = req.url.pathSegments[2];
      return [for (final t in tasksOf(id)) taskJson(t)];
    })
    ..get('/api/projects/:id/task-statuses', (http.Request req) {
      return statusesJson(req.url.pathSegments[2]);
    })
    ..get('/api/projects/:id/task-types', (http.Request req) {
      return typesJson(req.url.pathSegments[2]);
    })
    ..get('/api/projects/:id/task-priorities', (http.Request req) {
      return prioritiesJson(req.url.pathSegments[2]);
    })
    ..get('/api/projects/:id/task-fields', <Object>[])
    ..get('/api/projects/:id/task-templates', <Object>[])
    ..get('/api/projects/:id/notification-policy', <String, Object>{})
    ..get('/api/projects/:id/notification-settings', {'muted': false})
    ..get('/api/projects/:id/automations', (http.Request req) => demoRules())
    ..get('/api/projects/:id/automation-runs', <Object>[])
    ..get('/api/projects/:id', (http.Request req) {
      final p = projectById(req.url.pathSegments.last) ?? npl;
      return projectJson(p, detail: true);
    })
    ..get('/api/tasks/team', [
      for (final t in [...nplTasks, ...otherMyTasks]) taskJson(t),
    ])
    ..get('/api/tasks/mine', [
      for (final t in [...nplTasks, ...otherMyTasks])
        if (t.assignee?.id == me.id || t.refs.contains(me)) taskJson(t),
    ])
    ..get('/api/tasks/:id', (http.Request req) {
      final t = taskById(req.url.pathSegments.last) ?? nplTasks[1];
      return taskJson(t, detail: true);
    })
    ..get('/api/notes/:id/comments', <Object>[])
    ..get('/api/notes/:id/versions', <Object>[])
    ..get('/api/notes/:id', (http.Request req) {
      final id = req.url.pathSegments.last;
      return demoNotes().firstWhere((n) => n['id'] == id);
    })
    ..get('/api/notes', (http.Request req) {
      final projectId = req.url.queryParameters['projectId'];
      return [
        for (final n in demoNotes())
          if (projectId == null || n['projectId'] == projectId) n,
      ];
    })
    ..get('/api/project-notifications', {
      'unreadCount': 3,
      'items': demoNotifications(),
    })
    ..get('/api/teams/:id/members', [for (final u in everyone) userJson(u)])
    ..get('/api/rooms/:id/messages', (http.Request req) => launchMessages());
  return api;
}

/// "신제품 런칭" 대화방의 메시지(휴대폰 그림).
List<Map<String, dynamic>> launchMessages() {
  Map<String, dynamic> m(String id, AppUser u, int minute, String text) => {
    'id': id,
    'roomId': launchRoom.id,
    'senderId': u.id,
    'senderName': u.name,
    'type': 'text',
    'text': text,
    'createdAt': ms(day(0, 10, minute)),
    'comments': <Object>[],
  };
  return [
    m('lm1', doHyun, 5, '다들 좋은 아침입니다 ☀️ 출시까지 3주 남았어요.'),
    m('lm2', seoYeon, 18, '배너 시안 두 가지 올려 두었습니다.'),
    m('lm3', doHyun, 31, '출시 기념 할인 쿠폰도 준비해야 할 것 같아요. 할인율이랑 기간 정리해 주실 분 계실까요?'),
    // 길게 누를 lm3 뒤에 메시지가 더 있어야 lm3가 아래에서 올라오는 메뉴에 가려지지 않는다.
    m('lm4', seoYeon, 36, '좋아요! 쿠폰 디자인은 제가 맡을게요.'),
    m('lm5', junHo, 42, '쿠폰 기간은 출시일부터 2주 정도면 어떨까요?'),
    // 메뉴 항목이 늘어(즐겨찾기 · 할 일로 등록 …) 메뉴가 높아져서 몇 개 더 둔다.
    m('lm6', doHyun, 45, '좋습니다 👍'),
    m('lm7', yuNa, 47, '사내 공지도 같이 준비할게요.'),
  ];
}

/// 자동화 규칙 두 개 — 설정 > 자동화 목록과 편집기 그림에 쓴다.
List<Map<String, dynamic>> demoRules() => [
  {
    'id': 'a1',
    'projectId': npl.id,
    'name': '완료되면 채팅방에 알리기',
    'enabled': true,
    'trigger': 'field_changed',
    'actions': [],
    'graph': {
      'nodes': [
        {
          'id': 'n1',
          'kind': 'trigger',
          'type': 'field_changed',
          'config': {
            'fields': ['status'],
          },
          'x': 0,
          'y': 30,
        },
        {
          'id': 'n2',
          'kind': 'condition',
          'type': 'if',
          'config': {'field': 'status', 'op': 'eq', 'value': 's-done'},
          'x': 245,
          'y': 150,
        },
        {
          'id': 'n3',
          'kind': 'action',
          'type': 'chat_message',
          'config': {
            'roomId': launchRoom.id,
            'text': '{{task.key}} {{task.title}} 업무가 완료되었습니다 🎉',
          },
          'x': 490,
          'y': 280,
        },
      ],
      'edges': [
        {'from': 'n1', 'port': 'out', 'to': 'n2'},
        {'from': 'n2', 'port': 'yes', 'to': 'n3'},
      ],
    },
  },
  {
    'id': 'a2',
    'projectId': npl.id,
    'name': '새 업무는 검토자 지정',
    'enabled': false,
    'trigger': 'task_created',
    'actions': [],
    'graph': {
      'nodes': [
        {
          'id': 'n1',
          'kind': 'trigger',
          'type': 'task_created',
          'config': {},
          'x': 40,
          'y': 120,
        },
        {
          'id': 'n2',
          'kind': 'action',
          'type': 'set_field',
          'config': {'field': 'assignee', 'value': doHyun.id},
          'x': 330,
          'y': 120,
        },
      ],
      'edges': [
        {'from': 'n1', 'port': 'out', 'to': 'n2'},
      ],
    },
  },
];

/// 로그인까지 끝난 김민지(정회원)의 세션.
/// guide_capture.dart의 guideSession과 같은 방식이되, 대화 화면이 부르는 OS 알림 플러그인을
/// 건드리지 않는 알림 서비스를 쓴다(테스트 엔진에는 그 플러그인이 없다).
Session demoSession({GuideFakeApi? api}) {
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
  session.avatarColor = me.avatarColor;
  session.teams.add(tango);
  session.currentTeam = tango;
  session.rooms.add(launchRoom);
  session.projectUnread = 3;
  return session;
}

class _QuietNotifications extends NotificationService {
  @override
  Future<void> cancelForRoom(String roomId) async {}
}

/// 프로젝트 창(Windows에서는 따로 뜨는 창)을 그대로 올린다.
Future<Session> pumpProjectWindow(
  WidgetTester tester, {
  Session? session,
}) async {
  ignoreBenignErrors();
  final s = session ?? demoSession();
  await pumpGuideApp(tester, ProjectDialog(session: s, embedInWindow: true));
  await settleGuide(tester);
  return s;
}

/// 사이드바의 프로젝트 줄(즐겨찾기·폴더에 같이 있으면 맨 위 것).
Finder sidebarProject(String name) => find.widgetWithText(ListTile, name).first;

Future<void> openProject(WidgetTester tester, String name) async {
  await tester.tap(sidebarProject(name));
  await settleGuide(tester);
}

/// 마우스를 [f] 위에 올려 둔다(마우스를 올려야 보이는 ⋯ 버튼 등).
Future<TestGesture> hover(WidgetTester tester, Finder f) async {
  final g = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await g.addPointer(location: tester.getCenter(f));
  addTearDown(g.removePointer);
  await tester.pump();
  return g;
}

/// 테마를 거치지 않고 그린 글자(버튼의 styleFrom(textStyle: …) 등, 글꼴 이름이 없는 글자)는 테스트
/// 엔진의 기본 글꼴로 그려져 네모(□)가 된다. 실제 앱은 이런 글자를 운영체제 기본 글꼴(Windows는
/// Segoe UI + 맑은 고딕, 안드로이드는 Roboto)로 그리므로, 찍기 직전에 그 글자들만 같은 글꼴로 바꿔
/// 그린다(다시 빌드되면 원래대로 돌아가므로 그림에만 영향이 있다).
void fixDefaultFonts(WidgetTester tester, {String family = 'Segoe UI'}) {
  for (final r in tester.allRenderObjects.whereType<RenderParagraph>()) {
    final span = r.text;
    if (span is! TextSpan || span.style?.fontFamily != null) continue;
    r.text = TextSpan(
      style: TextStyle(
        fontFamily: family,
        fontFamilyFallback: guideFontFallback,
      ),
      children: [span],
    );
  }
}

/// [fixDefaultFonts] 후 저장.
Future<void> shot(
  WidgetTester tester,
  String name, {
  List<GuideCallout> callouts = const [],
  Rect? crop,
  bool android = false,
  List<Rect> erase = const [],
}) async {
  fixDefaultFonts(tester, family: android ? 'Roboto' : 'Segoe UI');
  await tester.pump();
  await saveGuideShot(
    tester,
    name,
    callouts: callouts,
    crop: crop,
    erase: erase,
  );
}

/// 떠 있는 대화상자의 흰 판(그림을 잘라낼 때).
Finder get dialogSurface => find
    .descendant(of: find.byType(Dialog), matching: find.byType(Material))
    .first;

Finder inDialog(Finder f) =>
    find.descendant(of: find.byType(Dialog), matching: f);

/// 위젯 종류 이름으로 찾기(화면 안의 비공개 위젯).
Finder byTypeName(String name) =>
    find.byWidgetPredicate((w) => w.runtimeType.toString() == name);

/// 같은 글자가 여러 곳에 있을 때 가장 오른쪽 / 왼쪽 것.
Finder rightMost(WidgetTester tester, Finder f) => _byX(tester, f, true);
Finder leftMost(WidgetTester tester, Finder f) => _byX(tester, f, false);

Finder _byX(WidgetTester tester, Finder f, bool right) {
  Element? best;
  var bestX = right ? double.negativeInfinity : double.infinity;
  for (final e in f.evaluate()) {
    final box = e.renderObject;
    if (box is! RenderBox || !box.hasSize) continue;
    final x = box.localToGlobal(Offset.zero).dx;
    if (right ? x > bestX : x < bestX) {
      bestX = x;
      best = e;
    }
  }
  return find.byElementPredicate((e) => e == best);
}

/// 대화의 말풍선 상자([text]가 든 메시지) — messenger_capture_test.dart와 같은 방식.
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

/// 리스트 표에서 [title] 업무가 있는 줄.
Finder listRow(String title) =>
    find.ancestor(of: find.text(title), matching: byTypeName('_TaskTableRow'));

/// 본문 폭(약 750px)에 맞게 찍을 때의 창 — 왼쪽 메뉴(220px)는 그대로 보이는 폭이라, 오른쪽
/// 내용만 잘라 내면([contentCrop]) 740px쯤이 된다(1280px 창 전체를 넣으면 60%로 줄어 글자가 작다).
const compactWindow = GuideSurface(Size(960, 720));

/// 창 위쪽 막대(검색·알림)와 왼쪽 메뉴를 뺀 가운데 내용 영역.
Rect contentCrop(WidgetTester tester, {double? bottom}) {
  final size = tester.view.physicalSize / tester.view.devicePixelRatio;
  return Rect.fromLTRB(221, 57, size.width, bottom ?? size.height);
}

/// 프로젝트 설정 창을 본문 폭에 맞게 찍으려고 창을 줄인다 — 설정 창은 창 폭 - 80px(최대 1000px)
/// 이라 780px 창이면 700px가 된다. 프로젝트를 연 뒤에 줄인다(좁은 창은 왼쪽 목록이 접힌다).
/// 멤버 목록처럼 700px에서는 이름이 잘리는 칸은 [width]를 넓히고 [settingsPaneCrop]으로 오른쪽
/// 칸만 잘라 낸다.
Future<void> narrowForSettings(WidgetTester tester, {double width = 780}) =>
    resizeGuideWindow(tester, Size(width, 800));

/// 설정 창의 오른쪽 칸(왼쪽 메뉴와 창 제목을 뺀 부분) — 표시할 곳이 모두 이 칸 안에 있을 때.
Rect settingsPaneCrop(WidgetTester tester, {double? bottom}) {
  final dialog = tester.getRect(dialogSurface);
  final nav = tester.getRect(
    find.ancestor(of: find.text('기본 정보'), matching: byTypeName('_NavItem')),
  );
  return Rect.fromLTRB(
    nav.right + 12,
    dialog.top + 60,
    dialog.right - 8,
    bottom ?? dialog.bottom - 8,
  );
}

Future<void> openSettings(WidgetTester tester, String section) async {
  await tester.tap(find.byTooltip('프로젝트 설정'));
  await settleGuide(tester);
  await tester.tap(inDialog(find.text(section)).first);
  await settleGuide(tester);
}

// ───────────────────────────── 캡처 ─────────────────────────────

void main() {
  // ── 1. 프로젝트 창 열기 · 둘러보기 ──

  guideCapture('메신저에서 프로젝트 열기', GuideSurface.desktop, (tester) async {
    ignoreBenignErrors();
    final session = demoSession();
    await pumpGuideApp(tester, DesktopHomeScreen(session: session));
    await settleGuide(tester);
    // 프로젝트는 오른쪽 위 "메뉴"(격자) › 툴 묶음의 "프로젝트" 타일에 있다(menu_entries.dart).
    final button = find.byTooltip('메뉴');
    final r = tester.getRect(button);
    await tester.tap(button);
    await settleGuide(tester);
    final tile = find.byKey(const ValueKey('menu-project'));
    final menu = tester.getRect(
      find.ancestor(of: tile, matching: find.byType(PopupMenuItem<void>)),
    );
    await shot(
      tester,
      'project-open',
      callouts: [
        GuideCallout.rect(r.deflate(2), number: 1, badge: CalloutBadge.left),
        GuideCallout.box(
          tile,
          number: 2,
          badge: CalloutBadge.right,
          padding: 2,
        ),
      ],
      crop: Rect.fromLTRB(
        math.min(menu.left, r.left) - 50,
        0,
        1280,
        menu.bottom + 16,
      ),
    );
  });

  guideCapture('화면 구성(홈)', GuideSurface.desktop, (tester) async {
    await pumpProjectWindow(tester);
    final menu = unionRect(tester, [
      find.widgetWithText(ListTile, '홈'),
      find.widgetWithText(ListTile, '노트'),
    ], padding: 2);
    final plus = tester.getRect(find.byTooltip('추가'));
    final last = tester.getRect(find.widgetWithText(ListTile, '연말 행사 준비'));
    await shot(
      tester,
      'project-overview',
      callouts: [
        GuideCallout.rect(
          Rect.fromLTRB(4, menu.top, 216, menu.bottom),
          number: 1,
          badge: CalloutBadge.right,
        ),
        GuideCallout.rect(
          Rect.fromLTRB(4, plus.top - 2, 216, last.bottom + 2),
          number: 2,
          badge: CalloutBadge.right,
        ),
        // 돋보기까지 칸 전체를 두르고 번호는 칸 바깥 왼쪽에 — 돋보기를 가리지 않게.
        GuideCallout.box(
          find.ancestor(
            of: find.text('검색어를 입력하세요.'),
            matching: find.byType(TextField),
          ),
          number: 3,
          padding: 3,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(
          find.byTooltip('알림'),
          number: 4,
          badge: CalloutBadge.left,
        ),
        GuideCallout.rect(
          const Rect.fromLTRB(234, 70, 1266, 790),
          number: 5,
          badge: CalloutBadge.topLeft,
        ),
      ],
    );
  });

  // ── 2. 프로젝트 만들기 ──

  guideCapture('[+] 메뉴', GuideSurface.desktop, (tester) async {
    await pumpProjectWindow(tester);
    final plus = find.byTooltip('추가');
    await tester.tap(plus);
    await settleGuide(tester);
    await shot(
      tester,
      'project-plus-menu',
      callouts: [
        GuideCallout.box(plus, number: 1, badge: CalloutBadge.left),
        GuideCallout.box(
          find.widgetWithText(MenuItemButton, '프로젝트 생성'),
          number: 2,
          badge: CalloutBadge.right,
        ),
      ],
      crop: const Rect.fromLTRB(0, 280, 470, 690),
    );
  });

  guideCapture('새 프로젝트 창', GuideSurface.desktop, (tester) async {
    await pumpProjectWindow(tester);
    await tester.tap(find.byTooltip('추가'));
    await settleGuide(tester);
    await tester.tap(find.widgetWithText(MenuItemButton, '프로젝트 생성'));
    await settleGuide(tester);
    final fields = inDialog(find.byType(TextField));
    await tester.enterText(fields.at(0), '신제품 출시');
    await tester.enterText(fields.at(1), 'NPL');
    await tester.enterText(fields.at(2), '가을 신제품 출시 준비 — 기획부터 홍보까지 함께 챙겨요.');
    // 커서가 칸에 남지 않게 포커스를 뺀다.
    FocusManager.instance.primaryFocus?.unfocus();
    await settleGuide(tester);
    final colors = unionRect(tester, [
      inDialog(find.text('대표 색상')),
    ], padding: 0);
    await shot(
      tester,
      'project-new-dialog',
      callouts: [
        GuideCallout.box(fields.at(0), number: 3, badge: CalloutBadge.left),
        GuideCallout.rect(
          Rect.fromLTWH(colors.left - 6, colors.bottom + 2, 304, 46),
          number: 4,
          badge: CalloutBadge.right,
        ),
        GuideCallout.box(fields.at(1), number: 5, badge: CalloutBadge.left),
        GuideCallout.box(
          inDialog(find.byType(DropdownMenu<bool>)),
          number: 6,
          badge: CalloutBadge.left,
        ),
        GuideCallout.rect(
          Rect.fromLTRB(
            tester.getRect(find.text('프로젝트 템플릿')).left - 14,
            tester.getRect(find.text('프로젝트 템플릿')).top - 16,
            tester.getRect(find.text('새 템플릿')).right + 26,
            tester.getRect(find.text('디자인 시안부터 오픈까지')).bottom + 20,
          ),
          number: 7,
          badge: CalloutBadge.topRight,
        ),
        GuideCallout.box(
          find.widgetWithText(FilledButton, '프로젝트 생성'),
          number: 8,
          badge: CalloutBadge.left,
        ),
      ],
      crop: cropAround(tester, [dialogSurface], margin: 20),
    );
  });

  guideCapture('프로젝트 템플릿 화면', compactWindow, (tester) async {
    await pumpProjectWindow(tester);
    await tester.tap(find.byTooltip('추가'));
    await settleGuide(tester);
    await tester.tap(find.widgetWithText(MenuItemButton, '템플릿'));
    await settleGuide(tester);
    await shot(
      tester,
      'project-templates',
      callouts: [
        GuideCallout.box(
          find.widgetWithText(FilledButton, '새 템플릿 만들기'),
          number: 1,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(
          find
              .ancestor(
                of: find.text('이 템플릿으로 만들기').first,
                matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
              )
              .first,
          number: 2,
          badge: CalloutBadge.left,
        ),
      ],
      crop: contentCrop(
        tester,
        bottom: tester.getRect(find.text('이 템플릿으로 만들기').last).bottom + 44,
      ),
    );
  });

  // ── 3. 프로젝트 화면 ──

  guideCapture('프로젝트 화면(칸반보드)', GuideSurface.desktop, (tester) async {
    await pumpProjectWindow(tester);
    await openProject(tester, '신제품 출시');
    await tester.tap(find.text('칸반보드'));
    await settleGuide(tester);
    final tabsText = unionRect(tester, [
      find.text('대시보드'),
      find.text('캘린더').last,
    ], padding: 8);
    final tabs = Rect.fromLTRB(
      tabsText.left - 26,
      tabsText.top,
      tabsText.right,
      tabsText.bottom,
    );
    await shot(
      tester,
      'project-screen',
      callouts: [
        GuideCallout.rect(
          unionRect(tester, [
            find.text('신제품 출시').last,
            find.byTooltip('즐겨찾기 해제'),
            find.text(npl.description!),
          ], padding: 6),
          number: 1,
          badge: CalloutBadge.left,
        ),
        GuideCallout.rect(tabs, number: 2, badge: CalloutBadge.bottomLeft),
        GuideCallout.box(
          find
              .ancestor(
                of: find.text('노트').last,
                matching: find.byType(InkWell),
              )
              .first,
          number: 3,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(
          find.text('필터링'),
          number: 4,
          padding: 10,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(
          find.widgetWithText(FilledButton, '새 업무'),
          number: 5,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(
          find.byTooltip('프로젝트 설정'),
          number: 6,
          badge: CalloutBadge.top,
        ),
      ],
    );
  });

  // ── 4. 업무 만들기 ──

  guideCapture('새 업무 버튼', GuideSurface.desktop, (tester) async {
    await pumpProjectWindow(tester);
    await openProject(tester, '신제품 출시');
    final button = find.widgetWithText(FilledButton, '새 업무');
    final r = tester.getRect(button);
    await shot(
      tester,
      'project-new-task-button',
      callouts: [GuideCallout.box(button, number: 1, badge: CalloutBadge.left)],
      crop: Rect.fromLTRB(r.left - 330, r.top - 40, 1280, r.bottom + 70),
    );
  });

  guideCapture('새 업무 창', GuideSurface.desktop, (tester) async {
    await pumpProjectWindow(tester);
    await openProject(tester, '신제품 출시');
    await tester.tap(find.widgetWithText(FilledButton, '새 업무'));
    await settleGuide(tester);
    Finder hinted(String hint) => find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.hintText == hint,
    );
    final titleField = hinted('업무 입력');
    final descField = hinted('설명을 추가하세요...');
    await tester.enterText(titleField, '출시 기념 할인 쿠폰 기획');
    await tester.tap(find.text('나에게 할당'));
    await settleGuide(tester);
    await tester.tap(inDialog(find.widgetWithText(ChoiceChip, '홍보')));
    await tester.tap(inDialog(find.widgetWithText(ChoiceChip, '높음')));
    await settleGuide(tester);
    await tester.enterText(descField, '쿠폰 할인율과 사용 기간을 정리해 주세요.');
    FocusManager.instance.primaryFocus?.unfocus();
    await settleGuide(tester);
    Rect row(String label) {
      final l = tester.getRect(inDialog(find.text(label)).first);
      final card = tester.getRect(inDialog(find.text('담당자')).first);
      final right = tester.getRect(titleField).right;
      return Rect.fromLTRB(card.left - 10, l.top - 8, right - 4, l.bottom + 8);
    }

    final statusTop = row('상태');
    final prioBottom = row('우선순위');
    await shot(
      tester,
      'project-new-task',
      callouts: [
        GuideCallout.box(titleField, number: 2, badge: CalloutBadge.left),
        GuideCallout.rect(row('담당자'), number: 3, badge: CalloutBadge.left),
        GuideCallout.rect(row('기간'), number: 4, badge: CalloutBadge.left),
        GuideCallout.rect(
          Rect.fromLTRB(
            statusTop.left,
            statusTop.top,
            statusTop.right,
            prioBottom.bottom,
          ),
          number: 5,
          badge: CalloutBadge.left,
        ),
        GuideCallout.rect(row('참조'), number: 6, badge: CalloutBadge.left),
        GuideCallout.box(descField, number: 7, badge: CalloutBadge.left),
        GuideCallout.box(
          inDialog(find.widgetWithText(FilledButton, '생성')),
          number: 8,
          badge: CalloutBadge.top,
        ),
      ],
      crop: cropAround(tester, [dialogSurface], margin: 20),
    );
  });

  // ── 5. 업무 보기 ──

  guideCapture('칸반보드 끌어 옮기기', GuideSurface.desktop, (tester) async {
    await pumpProjectWindow(tester);
    await openProject(tester, '신제품 출시');
    await tester.tap(find.text('칸반보드'));
    await settleGuide(tester);
    final card = find.text('보도자료 초안 작성');
    final doingHeader = tester.getRect(find.text('진행 중').first);
    final g = await tester.startGesture(
      tester.getCenter(card),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await g.moveBy(const Offset(30, 10));
    await tester.pump();
    await g.moveTo(doingHeader.center + const Offset(0, 330));
    await tester.pump(const Duration(milliseconds: 200));
    final dragged = tester.getRect(find.text('보도자료 초안 작성').last);
    await shot(
      tester,
      'project-kanban-drag',
      callouts: [
        GuideCallout.rect(
          Rect.fromLTWH(dragged.left - 20, dragged.top - 40, 270, 110),
          number: 2,
          badge: CalloutBadge.right,
        ),
        GuideCallout.box(
          find
              .ancestor(of: card.first, matching: byTypeName('_KanbanCard'))
              .first,
          number: 1,
          badge: CalloutBadge.left,
        ),
      ],
      // 할 일 · 진행 중 두 열과 끌고 가는 카드만(본문 폭에 맞게).
      crop: const Rect.fromLTRB(221, 215, 960, 720),
    );
    await g.cancel();
    await settleGuide(tester);
  });

  guideCapture('리스트 배지 바꾸기', GuideSurface.desktop, (tester) async {
    await pumpProjectWindow(tester);
    await openProject(tester, '신제품 출시');
    await tester.tap(find.text('리스트'));
    await settleGuide(tester);
    final row = listRow('보도자료 초안 작성');
    final pill = find.descendant(of: row, matching: find.text('할 일'));
    final pillRect = tester.getRect(pill).inflate(8);
    await tester.tap(pill);
    await settleGuide(tester);
    await shot(
      tester,
      'project-list',
      callouts: [
        GuideCallout.rect(pillRect, number: 1, badge: CalloutBadge.left),
        GuideCallout.rect(
          unionRect(tester, [
            find.widgetWithText(MenuItemButton, '할 일'),
            find.widgetWithText(MenuItemButton, '완료'),
          ], padding: 4),
          number: 2,
          badge: CalloutBadge.right,
        ),
      ],
      crop: const Rect.fromLTRB(221, 137, 1010, 770),
    );
  });

  guideCapture('내 업무', compactWindow, (tester) async {
    // 아래에서 넓힌 "업무" 열 폭은 표 바깥(정적 변수)에 남으므로 뒤 캡처에 이어지지 않게 지운다.
    // ignore: invalid_use_of_visible_for_testing_member
    addTearDown(TaskListTable.resetRememberedWidths);
    await pumpProjectWindow(tester);
    await tester.tap(find.widgetWithText(ListTile, '내 업무'));
    await settleGuide(tester);
    // 960px 창에서는 "업무" 열이 좁아 제목이 잘린다 — 실제 앱에서 하듯 구분선을 끌어 넓힌다.
    final handle = await tester.startGesture(
      tester.getCenter(byTypeName('_ColumnResizeHandle').first),
      kind: PointerDeviceKind.mouse,
    );
    await handle.moveBy(const Offset(60, 0));
    await tester.pump();
    await handle.moveBy(const Offset(70, 0));
    await tester.pump();
    await handle.up();
    await settleGuide(tester);
    await shot(
      tester,
      'project-my-tasks',
      callouts: [
        GuideCallout.box(
          find.text('필터링'),
          number: 1,
          padding: 10,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(
          find.widgetWithText(FilledButton, '새 업무'),
          number: 2,
          badge: CalloutBadge.left,
        ),
      ],
      crop: contentCrop(tester),
    );
  });

  guideCapture('간트차트', compactWindow, (tester) async {
    await pumpProjectWindow(tester);
    await tester.tap(find.widgetWithText(ListTile, '간트차트'));
    await settleGuide(tester);
    // 한 주 단위로 보면 막대가 길어 알아보기 쉽다.
    await tester.tap(find.text('주'));
    await settleGuide(tester);
    await shot(
      tester,
      'project-gantt',
      callouts: [
        GuideCallout.rect(
          unionRect(tester, [find.text('일'), find.text('분기')], padding: 14),
          number: 1,
          badge: CalloutBadge.bottom,
        ),
        GuideCallout.box(
          find.text('오늘').first,
          number: 2,
          padding: 12,
          badge: CalloutBadge.bottom,
        ),
        // 동그라미까지 토글 전체를 두르고, 번호는 오른쪽 위 모서리에(아래는 달력 머리글을,
        // 바로 위는 안내 문장 끝을 가린다).
        GuideCallout.box(
          find
              .ancestor(
                of: find.text('내 업무').last,
                matching: find.byType(InkWell),
              )
              .first,
          number: 3,
          padding: 2,
          badge: CalloutBadge.topRight,
        ),
      ],
      crop: contentCrop(tester),
    );
  });

  // ── 6. 업무 패널 ──

  Future<void> openTaskPanel(WidgetTester tester) async {
    await pumpProjectWindow(tester);
    await openProject(tester, '신제품 출시');
    await tester.tap(find.text('리스트'));
    await settleGuide(tester);
    await tester.tap(find.text('제품 소개 페이지 문구 작성'));
    await settleGuide(tester);
  }

  guideCapture('업무 패널 위', GuideSurface.desktop, (tester) async {
    await openTaskPanel(tester);
    final panel = tester.getRect(find.byType(TaskDetailPanel));
    Rect row(String label) {
      final l = tester.getRect(
        find
            .descendant(
              of: find.byType(TaskDetailPanel),
              matching: find.text(label),
            )
            .first,
      );
      return Rect.fromLTRB(
        panel.left + 8,
        l.top - 7,
        panel.right - 8,
        l.bottom + 7,
      );
    }

    final status = row('상태');
    final prio = row('우선순위');
    await shot(
      tester,
      'project-task-panel',
      callouts: [
        GuideCallout.box(
          find
              .ancestor(
                of: find.text('NPL-1002').last,
                matching: find.byType(InkWell),
              )
              .first,
          number: 1,
          badge: CalloutBadge.right,
        ),
        GuideCallout.dot(
          find.byTooltip('업무 메뉴'),
          number: 2,
          badge: CalloutBadge.bottom,
        ),
        GuideCallout.dot(
          find.byTooltip('크게 보기'),
          number: 3,
          badge: CalloutBadge.bottom,
        ),
        GuideCallout.rect(row('담당자'), number: 4, badge: CalloutBadge.left),
        GuideCallout.rect(row('참조'), number: 5, badge: CalloutBadge.left),
        GuideCallout.rect(row('기간'), number: 6, badge: CalloutBadge.left),
        GuideCallout.rect(
          Rect.fromLTRB(status.left, status.top, status.right, prio.bottom),
          number: 7,
          badge: CalloutBadge.left,
        ),
      ],
      crop: Rect.fromLTRB(
        panel.left - 30,
        panel.top,
        1280,
        tester.getRect(find.text('체크리스트 (2/4)')).top - 18,
      ),
    );
  });

  guideCapture('업무 패널 아래', GuideSurface.desktop, (tester) async {
    await openTaskPanel(tester);
    final panelFinder = find.byType(TaskDetailPanel);
    tester
        .state<ScrollableState>(
          find
              .descendant(of: panelFinder, matching: find.byType(Scrollable))
              .first,
        )
        .position
        .jumpTo(400);
    await settleGuide(tester);
    final panel = tester.getRect(panelFinder);
    Rect band(Finder top, Finder bottom, {double pad = 10}) => Rect.fromLTRB(
      panel.left + 8,
      tester.getRect(top).top - pad,
      panel.right - 12,
      tester.getRect(bottom).bottom + pad,
    );
    await shot(
      tester,
      'project-task-panel-2',
      callouts: [
        GuideCallout.rect(
          band(
            find.text('체크리스트 (2/4)'),
            find.byWidgetPredicate(
              (w) =>
                  w is TextField &&
                  w.decoration?.hintText == '+ 새 체크리스트 항목 추가 (Enter)',
            ),
            pad: 14,
          ),
          number: 1,
          badge: CalloutBadge.left,
        ),
        GuideCallout.rect(
          band(
            find.text('하위 업무 (0)'),
            find.byWidgetPredicate(
              (w) =>
                  w is TextField &&
                  w.decoration?.hintText == '+ 새 하위 업무 (Enter)',
            ),
          ),
          number: 2,
          badge: CalloutBadge.left,
        ),
        GuideCallout.rect(
          band(find.text('댓글 (3)'), find.text('댓글 (3)')),
          number: 3,
          badge: CalloutBadge.left,
        ),
      ],
      crop: Rect.fromLTRB(panel.left - 30, panel.top, 1280, 800),
    );
  });

  guideCapture('업무 메뉴', GuideSurface.desktop, (tester) async {
    await openTaskPanel(tester);
    await tester.tap(find.byTooltip('업무 메뉴'));
    await settleGuide(tester);
    final panel = tester.getRect(find.byType(TaskDetailPanel));
    await shot(
      tester,
      'project-task-menu',
      callouts: [
        GuideCallout.box(
          find.widgetWithText(MenuItemButton, '업무 보관'),
          number: 1,
          badge: CalloutBadge.left,
        ),
      ],
      crop: Rect.fromLTRB(panel.left - 30, panel.top, 1280, panel.top + 300),
    );
  });

  // ── 7. 필터 ──

  guideCapture('필터링', GuideSurface.desktop, (tester) async {
    await pumpProjectWindow(tester);
    await openProject(tester, '신제품 출시');
    await tester.tap(find.text('리스트'));
    await settleGuide(tester);
    await tester.tap(find.text('필터링'));
    await settleGuide(tester);
    await tester.tap(find.text('내 업무').last);
    await settleGuide(tester);
    final button = find.textContaining('필터링: ');
    await shot(
      tester,
      'project-filter',
      callouts: [
        GuideCallout.box(
          button,
          number: 1,
          padding: 10,
          badge: CalloutBadge.left,
        ),
        GuideCallout.rect(
          unionRect(tester, [
            find.text('빠른 필터링'),
            find.text('보관된 업무'),
          ], padding: 6),
          number: 2,
          badge: CalloutBadge.left,
        ),
        GuideCallout.rect(
          unionRect(tester, [
            find.descendant(
              of: byTypeName('FilterPanel'),
              matching: find.text('상태'),
            ),
            find
                .descendant(
                  of: byTypeName('FilterPanel'),
                  matching: find.byType(FilterDropdown<String>),
                )
                .last,
          ], padding: 6),
          number: 3,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(
          find.text('필터 추가'),
          number: 4,
          badge: CalloutBadge.left,
        ),
      ],
      crop: const Rect.fromLTRB(560, 100, 1280, 700),
    );
  });

  // ── 8. 즐겨찾기 · 폴더 ──

  guideCapture('프로젝트 메뉴와 폴더', GuideSurface.desktop, (tester) async {
    await pumpProjectWindow(tester);
    final item = find.widgetWithText(ListTile, '신입 사원 교육');
    await hover(tester, item);
    final more = find.descendant(
      of: find.ancestor(of: item, matching: byTypeName('_ProjectItem')),
      matching: find.byTooltip('프로젝트 메뉴'),
    );
    await tester.tap(more);
    await settleGuide(tester);
    await tester.tap(find.text('폴더로 이동'));
    await settleGuide(tester);
    await shot(
      tester,
      'project-sidebar-menu',
      callouts: [
        GuideCallout.box(more, number: 1, badge: CalloutBadge.left),
        GuideCallout.box(
          find.widgetWithText(MenuItemButton, '즐겨찾기'),
          number: 2,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(
          find.widgetWithText(SubmenuButton, '폴더로 이동'),
          number: 3,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(
          find.widgetWithText(MenuItemButton, '프로젝트 설정'),
          number: 4,
          badge: CalloutBadge.left,
        ),
      ],
      crop: const Rect.fromLTRB(0, 400, 760, 800),
    );
  });

  // ── 9. 노트 ──

  guideCapture('노트 보기', compactWindow, (tester) async {
    await pumpProjectWindow(tester);
    await tester.tap(find.widgetWithText(ListTile, '노트'));
    await settleGuide(tester);
    await tester.tap(find.text('출시 준비 회의록'));
    await settleGuide(tester);
    await shot(
      tester,
      'project-notes',
      callouts: [
        // 번호는 버튼 왼쪽 빈 곳에(아래에 두면 '계층형' 동그라미를 가린다).
        GuideCallout.box(
          find.byType(DashedAddButton),
          number: 1,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(
          find
              .ancestor(of: find.text('NPL-N3'), matching: find.byType(InkWell))
              .first,
          number: 2,
          badge: CalloutBadge.right,
        ),
        GuideCallout.dot(
          find.byTooltip('수정 이력'),
          number: 3,
          badge: CalloutBadge.bottom,
        ),
        GuideCallout.dot(
          find.byTooltip('더보기'),
          number: 4,
          badge: CalloutBadge.bottom,
        ),
      ],
      crop: contentCrop(tester),
    );
  });

  guideCapture('노트 업무 링크', GuideSurface.desktop, (tester) async {
    await pumpProjectWindow(tester);
    await tester.tap(find.widgetWithText(ListTile, '노트'));
    await settleGuide(tester);
    await tester.tap(find.text('+ 새 노트'));
    await settleGuide(tester);
    final title = find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.hintText == '제목을 입력하세요',
    );
    final body = find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.hintText == '내용을 입력하세요',
    );
    await tester.enterText(title, '금요일 회의 안건');
    await tester.showKeyboard(body);
    await tester.pump();
    Future<void> type(String text) async {
      tester.testTextInput.updateEditingValue(
        TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: text.length),
        ),
      );
      await tester.pump();
    }

    await type('1. 출시 일정 점검\n2. ');
    await type('1. 출시 일정 점검\n2. /');
    await settleGuide(tester);
    final popup = unionRect(tester, [
      find.text('업무 링크'),
      find.text('↑↓ 이동 · Enter 넣기 · Esc 닫기'),
    ], padding: 10);
    await shot(
      tester,
      'project-note-slash',
      callouts: [
        // 방금 친 "/" — 목록은 그 바로 아래에 뜬다.
        GuideCallout.rect(
          Rect.fromLTWH(popup.left - 32, popup.top - 34, 52, 30),
          number: 1,
          // 커서 오른쪽의 빈 줄에 — 왼쪽은 그림 가장자리, 위는 윗줄 글자다.
          badge: CalloutBadge.right,
        ),
        GuideCallout.rect(popup, number: 2, badge: CalloutBadge.right),
      ],
      // 왼쪽 노트 목록은 빼고 편집기 부분만(본문 폭에 맞게).
      crop: const Rect.fromLTRB(508, 57, 1100, 600),
    );
  });

  // ── 10. 알림 ──

  guideCapture('알림 목록', GuideSurface.desktop, (tester) async {
    await pumpProjectWindow(tester);
    final bell = find.byTooltip('알림');
    await tester.tap(bell);
    await settleGuide(tester);
    await shot(
      tester,
      'project-notifications',
      callouts: [
        GuideCallout.box(bell, number: 1, badge: CalloutBadge.left),
        GuideCallout.box(
          find.text('모두 읽음'),
          number: 2,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(
          find.widgetWithText(ListTile, '신제품 출시 · NPL-1002'),
          number: 3,
          padding: 0,
          badge: CalloutBadge.left,
        ),
      ],
      crop: const Rect.fromLTRB(780, 0, 1280, 560),
    );
  });

  // ── 11. 프로젝트 설정 ──

  guideCapture('설정 노트 권한', GuideSurface.desktop, (tester) async {
    await pumpProjectWindow(tester);
    await openProject(tester, '신제품 출시');
    await openSettings(tester, '노트');
    await narrowForSettings(tester);
    await shot(
      tester,
      'project-settings-notes',
      callouts: [
        // 메뉴 줄 전체(아이콘 포함)를 두르고 번호는 그 바깥 왼쪽 여백에 — 노트 아이콘을 가리지 않게.
        GuideCallout.box(
          find.ancestor(of: find.text('노트'), matching: byTypeName('_NavItem')),
          number: 1,
          padding: 2,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(
          find.text('노트 수정 권한'),
          number: 2,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(
          find.text('노트 삭제 권한'),
          number: 3,
          badge: CalloutBadge.left,
        ),
      ],
      crop: cropAround(tester, [dialogSurface], margin: 20),
    );
  });

  guideCapture('설정 필드 상태', GuideSurface.desktop, (tester) async {
    await pumpProjectWindow(tester);
    await openProject(tester, '신제품 출시');
    await openSettings(tester, '필드 / 상태');
    await narrowForSettings(tester);
    final bottom = tester.getRect(dialogSurface).bottom - 28;
    Rect card(String title) {
      final r = tester.getRect(
        find
            .ancestor(of: find.text(title), matching: find.byType(Container))
            .first,
      );
      // 스크롤 영역 밖으로 내려간 부분은 창 아래에서 자른다.
      return Rect.fromLTRB(r.left, r.top, r.right, r.bottom.clamp(0, bottom));
    }

    await shot(
      tester,
      'project-settings-fields',
      callouts: [
        GuideCallout.rect(
          card('기본 필드'),
          number: 1,
          badge: CalloutBadge.topLeft,
        ),
        GuideCallout.rect(
          card('사용자 정의 필드'),
          number: 2,
          badge: CalloutBadge.topLeft,
        ),
        GuideCallout.rect(
          card('업무 템플릿'),
          number: 3,
          badge: CalloutBadge.topLeft,
        ),
      ],
      crop: cropAround(tester, [dialogSurface], margin: 20),
    );
  });

  guideCapture('설정 멤버', GuideSurface.desktop, (tester) async {
    await pumpProjectWindow(tester);
    await openProject(tester, '연말 행사 준비');
    await openSettings(tester, '멤버');
    await narrowForSettings(tester, width: 1000);
    await shot(
      tester,
      'project-settings-members',
      callouts: [
        GuideCallout.box(
          find.widgetWithText(FilledButton, '멤버 초대하기'),
          number: 1,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(
          find.text('프로젝트 멤버'),
          number: 2,
          badge: CalloutBadge.left,
        ),
        GuideCallout.rect(
          unionRect(tester, [find.byTooltip('담당자로'), find.byTooltip('멤버로')]),
          number: 3,
          badge: CalloutBadge.top,
        ),
        GuideCallout.box(
          find.text('프로젝트 담당자'),
          number: 4,
          badge: CalloutBadge.left,
        ),
      ],
      crop: settingsPaneCrop(tester),
    );
  });

  guideCapture('설정 자동화 목록', GuideSurface.desktop, (tester) async {
    await pumpProjectWindow(tester);
    await openProject(tester, '신제품 출시');
    await openSettings(tester, '자동화');
    await narrowForSettings(tester, width: 1000);
    await shot(
      tester,
      'project-automation-list',
      callouts: [
        // 번호를 버튼 위에 — 왼쪽에 두면 안내 문장을 가린다.
        GuideCallout.box(
          find.widgetWithText(FilledButton, '새 자동화'),
          number: 1,
          badge: CalloutBadge.top,
        ),
        GuideCallout.box(
          find.byType(Switch).first,
          number: 2,
          badge: CalloutBadge.left,
        ),
      ],
      // 규칙 두 줄 아래의 빈 곳은 잘라 낸다.
      crop: settingsPaneCrop(
        tester,
        bottom: tester.getRect(find.text('업무 생성 → 필드 변경')).bottom + 40,
      ),
    );
  });

  guideCapture('자동화 편집기', GuideSurface.desktop, (tester) async {
    await pumpProjectWindow(tester);
    await openProject(tester, '신제품 출시');
    await openSettings(tester, '자동화');
    await tester.tap(find.text('완료되면 채팅방에 알리기'));
    await settleGuide(tester);
    // 캔버스의 "채팅방 알림" 카드를 눌러 오른쪽에 설정이 보이게 한다(왼쪽 팔레트에도 같은 이름이 있다).
    await tester.tap(rightMost(tester, find.text('채팅방 알림')));
    await settleGuide(tester);
    final paletteTop = tester.getRect(find.text('트리거').first);
    final paletteBottom = tester.getRect(leftMost(tester, find.text('채팅방 알림')));
    final settings = tester.getRect(find.text('노드 설정'));
    final chatCard = tester.getRect(
      find.ancestor(
        of: find.descendant(
          of: byTypeName('_NodeCard'),
          matching: find.text('채팅방 알림'),
        ),
        matching: byTypeName('_NodeCard'),
      ),
    );
    final ifCard = tester.getRect(
      find.ancestor(
        of: rightMost(tester, find.text('IF 조건')),
        matching: byTypeName('_NodeCard'),
      ),
    );
    // 1280px 창 전체를 한 장에 넣으면 본문 폭에서 60%로 줄어 팔레트 글자를 읽기 어렵다 —
    // 왼쪽(제목 · 팔레트 · 캔버스, 1~3)과 오른쪽(고른 카드와 노드 설정 · 활성 · 저장, 4~6) 두 장으로
    // 나눈다(세 번째 카드는 오른쪽 그림에 온전히 나온다).
    const leftRight = 750.0;
    await shot(
      tester,
      'project-automation-editor',
      callouts: [
        GuideCallout.box(
          find.byKey(const ValueKey('rule-name')),
          number: 1,
          badge: CalloutBadge.right,
        ),
        GuideCallout.rect(
          Rect.fromLTRB(6, paletteTop.top - 10, 194, paletteBottom.bottom + 14),
          number: 2,
          badge: CalloutBadge.right,
        ),
        GuideCallout.rect(
          Rect.fromLTRB(214, 70, leftRight - 8, ifCard.bottom + 40),
          number: 3,
          badge: CalloutBadge.topLeft,
        ),
      ],
      crop: Rect.fromLTRB(0, 0, leftRight, paletteBottom.bottom + 30),
    );
    final settingsBottom = tester.getRect(find.textContaining('규칙 이름')).bottom;
    await shot(
      tester,
      'project-automation-editor-2',
      callouts: [
        GuideCallout.rect(
          Rect.fromLTRB(
            settings.left - 14,
            settings.top - 14,
            1274,
            settingsBottom + 16,
          ),
          number: 4,
          // 왼쪽에는 고른 카드가 붙어 있어서 번호는 아래 모서리에.
          badge: CalloutBadge.bottomLeft,
        ),
        GuideCallout.box(
          byTypeName('_ActiveToggle'),
          number: 5,
          badge: CalloutBadge.bottom,
        ),
        GuideCallout.box(
          find.widgetWithText(FilledButton, '저장'),
          number: 6,
          badge: CalloutBadge.bottom,
        ),
      ],
      crop: Rect.fromLTRB(chatCard.left - 24, 0, 1280, settingsBottom + 40),
    );
  });

  // ── 12. 휴대폰(안드로이드) ──

  guideCapture('휴대폰 메시지를 업무로', GuideSurface.phone, (tester) async {
    ignoreBenignErrors();
    final session = demoSession();
    await pumpGuideApp(tester, ChatScreen(session: session, room: launchRoom));
    await settleGuide(tester);
    // 실제 안드로이드에서는 말풍선 어디를 길게 눌러도 메뉴가 뜬다. 테스트는 Windows에서 돌아서
    // 글자가 "선택 가능한 글자"로 그려지므로(글자 위 길게 누르기 = 단어 선택), 말풍선 여백을 누른다.
    final bubble = tester.getRect(bubbleBoxOf('할인 쿠폰도'));
    await tester.longPressAt(bubble.topLeft + const Offset(5, 4));
    await settleGuide(tester);
    // 길게 누른 말풍선이 아래에서 올라온 메뉴에 가려지지 않았는지(가려지면 다음 그림의 설명이
    // 어디서 왔는지 알 수 없다) — 뒤에 메시지를 더 두어 위로 밀어 올려 두었다.
    expect(
      bubble.bottom < tester.getRect(find.byType(BottomSheet)).top,
      isTrue,
    );
    await shot(
      tester,
      'project-phone-message',
      android: true,
      callouts: [
        // 번호는 말풍선 왼쪽 빈 곳에(위쪽 모서리에 두면 보낸 사람 이름을 가린다).
        GuideCallout.rect(
          bubble.inflate(2),
          number: 1,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(
          find.widgetWithText(ListTile, '업무로 등록'),
          number: 2,
          padding: 0,
          badge: CalloutBadge.right,
        ),
      ],
    );
    await tester.tap(find.text('업무로 등록'));
    await settleGuide(tester);
    Finder hinted(String hint) => find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.hintText == hint,
    );
    FocusManager.instance.primaryFocus?.unfocus();
    await settleGuide(tester);
    // 대화상자 뒤 입력칸 아래 줄의 화면 캡처 버튼 · "Shift + Enter 로 줄바꿈"은 Windows에만 있다
    // (테스트가 Windows에서 돌아 그려진다) — 실제 안드로이드처럼 그 자리를 배경색으로 지운다.
    // 줄바꿈 안내는 버튼들을 놓고 남은 자리에 통째로 들어갈 때만 보여서(chat_input_bar.dart의
    // _SendKeyHint) 없을 수도 있다 — 없으면 캡처 버튼 자리만 지운다.
    final capture = tester.getRect(find.byTooltip('화면 캡처'));
    final hintFinder = find.text('Shift + Enter 로 줄바꿈');
    final hint = hintFinder.evaluate().isEmpty
        ? capture
        : tester.getRect(hintFinder);
    await shot(
      tester,
      'project-phone-new-task',
      android: true,
      erase: [
        Rect.fromLTRB(
          capture.left,
          math.min(capture.top, hint.top),
          math.max(capture.right, hint.right) + 4,
          math.max(capture.bottom, hint.bottom),
        ),
      ],
      callouts: [
        GuideCallout.box(
          find.byType(DropdownMenu<String>),
          number: 3,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(hinted('업무 입력'), number: 4, badge: CalloutBadge.left),
        GuideCallout.box(
          hinted('설명을 추가하세요...'),
          number: 5,
          badge: CalloutBadge.left,
        ),
      ],
    );
  });

  tearDownAll(printGuideImagesSize);
}
