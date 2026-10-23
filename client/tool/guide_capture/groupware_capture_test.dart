// 도움말 "그룹웨어 · 업무 도구"(server/guide/groupware.html)의 그룹웨어 탭 그림을 찍는다.
//
// 다시 찍기(client 폴더에서):
//   flutter test tool/guide_capture/groupware_capture_test.dart
// 결과: ../server/guide/images/groupware-*.png
//
// 그룹웨어 화면(GroupwareScreen)을 가짜 서버 응답(GuideFakeApi)으로 채운다. 응답 모양은 client/test/의
// groupware_test.dart·groupware_resources_test.dart·groupware_finance_test.dart·groupware_forms_test.dart와 같다.
import 'dart:io';

import 'package:client/screens/groupware/groupware_screen.dart';
import 'package:client/services/groupware_api.dart';
import 'package:client/widgets/app_menu_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'guide_capture.dart';

// ───────────────────────────── 가짜 데이터 ─────────────────────────────

const _me = 'u-me';
const _lead = 'u-lead';
const _boss = 'u-boss';

final _now = DateTime.now();
int _ms(DateTime d) => d.millisecondsSinceEpoch;
int _todayAt(int h, [int m = 0]) =>
    _ms(DateTime(_now.year, _now.month, _now.day, h, m));
String _ymd(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
String get _today => _ymd(_now);
String get _month => _today.substring(0, 7);

Map<String, dynamic> _context() => {
  'scope': 'team',
  'scopeSetting': 'org',
  'teamId': 't1',
  'teamName': '마케팅팀',
  'isManager': false,
  'workStart': 540,
  'workEnd': 1080,
  'today': _today,
  'hireDate': '2021-03-02',
  'pendingForMe': 2,
  'leaveTypes': [
    {'key': 'annual', 'label': '연차', 'deducts': true, 'half': false},
    {'key': 'half_am', 'label': '오전 반차', 'deducts': true, 'half': true},
    {'key': 'half_pm', 'label': '오후 반차', 'deducts': true, 'half': true},
    {'key': 'sick', 'label': '병가', 'deducts': false, 'half': false},
    {'key': 'family', 'label': '경조사', 'deducts': false, 'half': false},
  ],
  'expenseCategories': ['교통비', '식대', '비품', '소모품', '출장비', '교육비', '접대비', '기타'],
  'limits': {'approversMax': 10, 'ccMax': 10, 'attachmentsMax': 5},
  'inLan': true,
  'payroll': {'canManage': false},
  'cards': {'total': 3, 'mine': 1},
  'receiptOcr': true,
};

Map<String, dynamic> _step(
  String id,
  int order,
  String approverId,
  String name,
  String status, {
  String? role,
  int? decidedAt,
}) => {
  'id': id,
  'order': order,
  'approverId': approverId,
  'approverName': name,
  'status': status,
  'role': ?role,
  'decidedAt': ?decidedAt,
};

Map<String, dynamic> _doc({
  required String id,
  required String kind,
  required String title,
  required Map<String, dynamic> payload,
  String status = 'pending',
  String authorId = _me,
  String authorName = '김하나',
  required DateTime createdAt,
  required List<Map<String, dynamic>> steps,
  bool myTurn = false,
  bool canWithdraw = false,
  String? docNo,
  String body = '',
}) => {
  'id': id,
  'kind': kind,
  'title': title,
  'body': body,
  'payload': payload,
  'attachments': [],
  'status': status,
  'authorId': authorId,
  'authorName': authorName,
  'createdAt': _ms(createdAt),
  'steps': steps,
  'myTurn': myTurn,
  'canWithdraw': canWithdraw,
  'canCancel': false,
  'docNo': ?docNo,
};

List<Map<String, dynamic>> _documents() {
  final d = _now;
  return [
    _doc(
      id: 'D1',
      kind: 'leave',
      title: '연차 신청 (11/3~11/4, 2일)',
      body: '가족 여행',
      payload: {
        'leaveType': 'annual',
        'startDate': '${d.year}-11-03',
        'endDate': '${d.year}-11-04',
        'halfDays': 4,
      },
      authorId: 'u-park',
      authorName: '박지훈',
      createdAt: d.subtract(const Duration(hours: 3)),
      docNo: '휴가-${d.year}-0041',
      myTurn: true,
      steps: [
        _step('s1', 0, _me, '김하나', 'pending'),
        _step('s2', 1, _boss, '최민호', 'waiting'),
      ],
    ),
    _doc(
      id: 'D2',
      kind: 'expense',
      title: '거래처 미팅 식대',
      payload: {'amount': 86000, 'category': '접대비', 'spentOn': _today},
      authorId: 'u-lee',
      authorName: '이서연',
      createdAt: d.subtract(const Duration(hours: 5)),
      docNo: '지출-${d.year}-0118',
      myTurn: true,
      steps: [
        _step('s3', 0, _me, '김하나', 'pending'),
        _step('s4', 1, _boss, '최민호', 'waiting'),
      ],
    ),
  ];
}

final _balance = {
  'hireDate': '2021-03-02',
  'period': {
    'year': 6,
    'start': '${_now.year}-03-02',
    'end': '${_now.year + 1}-03-02',
  },
  'statutoryHalfDays': 34,
  'adjustmentHalfDays': 0,
  'grantedHalfDays': 34,
  'usedHalfDays': 13,
  'pendingHalfDays': 4,
  'remainingHalfDays': 17,
  'adjustments': [],
};

// ── 휴가 달력 ──
Map<String, dynamic> _leaveMonth() {
  final y = _now.year;
  final m = _now.month.toString().padLeft(2, '0');
  String day(int d) => '$y-$m-${d.toString().padLeft(2, '0')}';
  Map<String, dynamic> leave(
    String id,
    String uid,
    String name,
    String label,
    int from,
    int to, {
    String status = 'approved',
    bool mine = false,
  }) => {
    'documentId': id,
    'userId': uid,
    'name': name,
    'label': label,
    'startDate': day(from),
    'endDate': day(to),
    'status': status,
    if (mine) 'mine': true,
  };
  return {
    'month': '$y-$m',
    'holidays': [
      if (_now.month == 10) {'date': day(3), 'name': '개천절'},
      if (_now.month == 10) {'date': day(9), 'name': '한글날'},
    ],
    'leaves': [
      leave('L1', 'u-park', '박지훈', '연차', 6, 7),
      leave('L2', 'u-lee', '이서연', '오전 반차', 14, 14),
      leave('L3', 'u-jung', '정다은', '연차', 20, 21),
      leave('L4', 'u-choi', '최민준', '병가', 21, 21),
      leave('L5', 'u-han', '한지민', '연차', 21, 21),
      leave('L6', _me, '김하나', '연차', 29, 30, status: 'pending', mine: true),
    ],
    'trips': [
      {
        'documentId': 'T1',
        'userId': 'u-lee',
        'name': '이서연',
        'destination': '부산',
        'startDate': day(16),
        'endDate': day(17),
      },
      {
        'documentId': 'T2',
        'userId': 'u-park',
        'name': '박지훈',
        'destination': '판교',
        'startDate': day(27),
        'endDate': day(27),
      },
    ],
  };
}

// ── 출퇴근 ──
int _at(DateTime d, int h, int m) =>
    _ms(DateTime(d.year, d.month, d.day, h, m));

Map<String, dynamic> _record(
  DateTime d,
  int inH,
  int inM,
  int? outH,
  int? outM, {
  bool late = false,
}) {
  final worked = outH == null ? 0 : (outH * 60 + outM!) - (inH * 60 + inM);
  return {
    'id': 'R${d.day}',
    'workDate': _ymd(d),
    'clockInAt': _at(d, inH, inM),
    'clockOutAt': outH == null ? null : _at(d, outH, outM!),
    'clockInLan': true,
    'clockOutLan': outH == null ? null : true,
    'clockInMode': 'office',
    'late': late,
    'earlyLeave': false,
    'workedMinutes': worked,
    'missingClockOut': false,
    'breaks': [],
    'onBreak': false,
    if (outH != null)
      'breakdown': {
        'workedMinutes': worked,
        'breakMinutes': 60,
        'netMinutes': worked - 60,
        'breakRecorded': false,
      },
  };
}

Map<String, dynamic> _attendanceToday() => {
  'today': _today,
  'record': _record(_now, 8, 52, null, null),
  'openRecord': null,
  'canClockIn': false,
  'canClockOut': true,
  'canBreakStart': true,
  'canBreakEnd': false,
  'inLan': true,
  'workStart': 540,
  'workEnd': 1080,
  'week': {
    'weekStart': _ymd(_now.subtract(Duration(days: _now.weekday - 1))),
    'weekEnd': _ymd(_now.add(Duration(days: 7 - _now.weekday))),
    'netMinutes': 1560,
    'overtimeMinutes': 120,
    'status': 'ok',
  },
  'weeklyLimitMinutes': 3120,
  'overtimeGuard': 'warn',
  'requireFieldLocation': false,
  'officeLocationSet': false,
};

Map<String, dynamic> _attendanceMonth() {
  final first = DateTime(_now.year, _now.month, 1);
  final days = <Map<String, dynamic>>[];
  for (var d = first; !d.isAfter(_now); d = d.add(const Duration(days: 1))) {
    final weekend = d.weekday >= 6;
    final holiday = _now.month == 10 && (d.day == 3 || d.day == 9);
    Map<String, dynamic>? record;
    if (!weekend && !holiday) {
      if (d.day == _now.day) {
        record = _record(d, 8, 52, null, null);
      } else if (d.day == 14) {
        record = _record(d, 9, 12, 18, 30, late: true);
      } else {
        record = _record(d, 8, 40 + d.day % 15, 18, 5 + d.day % 40);
      }
    }
    days.add({
      'date': _ymd(d),
      'holiday': holiday ? (d.day == 3 ? '개천절' : '한글날') : null,
      'leave': null,
      'record': record,
    });
  }
  return {
    'month': _month,
    'days': days,
    'summary': {
      'daysWorked': 14,
      'workedMinutes': 8040,
      'netMinutes': 7200,
      'late': 1,
      'earlyLeave': 0,
      'missingClockOut': 0,
      'absent': 0,
      'leaveHalfDays': 0,
      'tripDays': 0,
      'actualOvertimeMinutes': 180,
    },
    'weeks': [],
    'weeklyLimitMinutes': 3120,
    'periods': [],
  };
}

// ── 예약 ──
Map<String, dynamic> _resource(
  String id,
  String name,
  String kind, {
  String location = '3층',
  int? capacity,
  bool approval = false,
}) => {
  'id': id,
  'kind': kind,
  'name': name,
  'location': location,
  'capacity': capacity,
  'enabled': true,
  if (approval) 'requiresApproval': true,
};

Map<String, dynamic> _booking(
  String id,
  String resourceId,
  String resourceName,
  int start,
  int end,
  String title, {
  bool mine = false,
  String userName = '박지훈',
}) => {
  'id': id,
  'resourceId': resourceId,
  'resourceName': resourceName,
  'resourceKind': 'room',
  'title': title,
  'userId': mine ? _me : 'u-x',
  'userName': mine ? '김하나' : userName,
  'start': start,
  'end': end,
  'status': 'confirmed',
  'mine': mine,
  'canCancel': mine,
};

List<Map<String, dynamic>> _bookings() => [
  _booking(
    'B1',
    'R1',
    '대회의실',
    _todayAt(10),
    _todayAt(11, 30),
    '주간 회의',
    userName: '최민호',
  ),
  _booking('B2', 'R1', '대회의실', _todayAt(14), _todayAt(15), '고객 미팅', mine: true),
  _booking(
    'B3',
    'R2',
    '소회의실 A',
    _todayAt(9, 30),
    _todayAt(10, 30),
    '1:1 면담',
    userName: '이서연',
  ),
  _booking(
    'B4',
    'R2',
    '소회의실 A',
    _todayAt(16),
    _todayAt(17),
    '디자인 리뷰',
    userName: '정다은',
  ),
  _booking(
    'B5',
    'R3',
    '소회의실 B',
    _todayAt(13),
    _todayAt(14),
    '채용 인터뷰',
    userName: '박지훈',
  ),
  _booking(
    'B6',
    'R4',
    '법인차 (12가 3456)',
    _todayAt(9),
    _todayAt(13),
    '고객사 방문',
    userName: '최민준',
  ),
];

// ── 지출 · 법인카드 ──
Map<String, dynamic> _tx(
  String id,
  int amount,
  String merchant,
  int day,
  int h, {
  int receipts = 0,
  String? memo,
  String? category,
}) => {
  'id': id,
  'cardId': 'C1',
  'cardName': '마케팅팀 카드',
  'issuer': '신한',
  'last4': '5678',
  'usedAt': _ms(DateTime(_now.year, _now.month, day, h, 20)),
  'usedOn': _ymd(DateTime(_now.year, _now.month, day)),
  'merchant': merchant,
  'amount': amount,
  'approvalNo': '30${id.hashCode % 9000 + 1000}',
  'source': 'excel',
  'userId': _me,
  'userName': '김하나',
  'memo': memo,
  'category': category,
  'receipts': [
    for (var i = 0; i < receipts; i++)
      {
        'fileUrl': '/files/r$id$i',
        'fileName': '영수증.jpg',
        'mimeType': 'image/jpeg',
      },
  ],
  'mismatches': [],
  'status': 'open',
  'canEdit': true,
  'canClaim': true,
  'unassigned': false,
};

Map<String, dynamic> _cardPage() {
  final items = [
    _tx(
      'T1',
      86000,
      '한우마을 강남점',
      _now.day - 1,
      19,
      receipts: 1,
      memo: '거래처 미팅',
      category: '접대비',
    ),
    _tx(
      'T2',
      15400,
      '카카오T 택시',
      _now.day - 2,
      21,
      receipts: 1,
      memo: '야근 귀가',
      category: '교통비',
    ),
    _tx('T3', 32000, '오피스디포', _now.day - 4, 11),
  ];
  final total = items.fold<int>(0, (s, t) => s + (t['amount'] as int));
  return {
    'month': null,
    'items': items,
    'totals': {'all': total, 'open': total, 'openCount': items.length},
  };
}

// ── 급여 ──
Map<String, dynamic> _slip(String id, int month, {bool viewed = true}) => {
  'id': id,
  'runId': 'RUN$month',
  'userId': _me,
  'userName': '김하나',
  'employeeNo': 'M-0217',
  'department': '마케팅팀',
  'position': '대리',
  'revision': 1,
  'viewedAt': viewed ? _ms(DateTime(_now.year, month, 25, 10)) : null,
  'gross': 3580000,
  'taxable': 3380000,
  'taxFree': 200000,
  'deductionTotal': 412880,
  'net': 3167120,
  'run': {
    'id': 'RUN$month',
    'title': '${_now.year}년 $month월 급여',
    'payMonth': '${_now.year}-${month.toString().padLeft(2, '0')}',
    'payDate': '${_now.year}-${month.toString().padLeft(2, '0')}-25',
    'status': 'published',
    'slipCount': 12,
    'viewedCount': 9,
  },
  'companyName': '탱고 주식회사',
};

// ── 설문 ──
Map<String, dynamic> _survey(
  String id,
  String title,
  String creator, {
  required bool pending,
  int responses = 8,
  int targets = 12,
  int? closesInDays,
}) => {
  'id': id,
  'title': title,
  'creatorId': 'u-$id',
  'creatorName': creator,
  'questionCount': 5,
  'createdAt': _ms(_now.subtract(const Duration(days: 2))),
  'responseCount': responses,
  'targetCount': targets,
  'responded': !pending,
  'pending': pending,
  if (closesInDays != null)
    'closesAt': _ms(
      DateTime(_now.year, _now.month, _now.day + closesInDays, 18),
    ),
};

// ── 업무일지 ──
Map<String, dynamic> _workReport(String kind) {
  final weekly = kind == 'weekly';
  final monday = _now.subtract(Duration(days: _now.weekday - 1));
  final start = weekly ? _ymd(monday) : _today;
  final end = weekly ? _ymd(monday.add(const Duration(days: 6))) : _today;
  return {
    'kind': kind,
    'periodStart': start,
    'periodEnd': end,
    'currentPeriodStart': start,
    'previousPeriodStart': weekly
        ? _ymd(monday.subtract(const Duration(days: 7)))
        : _ymd(_now.subtract(const Duration(days: 1))),
    'report': {
      'id': 'WR1',
      'userId': _me,
      'userName': '김하나',
      'kind': kind,
      'periodStart': start,
      'periodEnd': end,
      'done':
          '- 11월 프로모션 배너 시안 2종 확정\n- 거래처(한빛유통) 미팅 — 단가 협의\n- 10월 광고 성과 보고서 초안',
      'plan': '- 프로모션 랜딩 페이지 문구 정리\n- 광고 성과 보고서 팀장 검토 반영',
      'issues': '랜딩 페이지 개발 일정이 하루 밀릴 수 있음',
      'reads': [
        {'userId': _boss, 'name': '최민호'},
      ],
    },
    'reviewers': [
      {'userId': _boss, 'name': '최민호'},
    ],
  };
}

// ── 결재 양식 ──
Map<String, dynamic> _field(
  String key,
  String label,
  String type, {
  bool required = false,
}) => {'key': key, 'label': label, 'type': type, 'required': required};

List<Map<String, dynamic>> _forms() => [
  {
    'id': 'builtin:draft',
    'kind': 'draft',
    'builtin': true,
    'name': '일반 기안서',
    'description': '형식이 정해지지 않은 품의 · 보고 · 협조 요청',
    'fields': [
      _field('content', '기안 내용', 'textarea', required: true),
      _field('budget', '예산(원)', 'money'),
    ],
    'allowAttachments': true,
    'enabled': true,
  },
  {
    'id': 'builtin:trip',
    'kind': 'trip',
    'builtin': true,
    'name': '출장 신청',
    'description': '출장지 · 기간 · 목적',
    'fields': [_field('destination', '출장지', 'text', required: true)],
    'allowAttachments': true,
    'enabled': true,
  },
  {
    'id': 'builtin:purchase',
    'kind': 'purchase',
    'builtin': true,
    'name': '구매 요청',
    'description': '품목 표로 금액 · 합계 계산',
    'fields': [_field('items', '구매 품목', 'items', required: true)],
    'allowAttachments': true,
    'enabled': true,
  },
  {
    'id': 'builtin:overtime',
    'kind': 'overtime',
    'builtin': true,
    'name': '연장근무 신청',
    'description': '연장 · 야간 · 휴일근무',
    'fields': [_field('workDate', '근무일', 'date', required: true)],
    'allowAttachments': false,
    'enabled': true,
  },
];

GuideFakeApi _api() {
  final api = GuideFakeApi()
    ..get('/api/groupware/leave/month', (_) => _leaveMonth())
    ..get('/api/groupware/leave/promotions/mine', [])
    ..get('/api/groupware/attendance/today', (_) => _attendanceToday())
    ..get('/api/groupware/attendance/month', (_) => _attendanceMonth())
    ..get('/api/groupware/resources', [
      _resource('R1', '대회의실', 'room', capacity: 12),
      _resource('R2', '소회의실 A', 'room', capacity: 6),
      _resource('R3', '소회의실 B', 'room', capacity: 4),
      _resource(
        'R4',
        '법인차 (12가 3456)',
        'vehicle',
        location: '지하 2층',
        approval: true,
      ),
      _resource('R5', '빔프로젝터', 'equipment', location: '총무팀'),
    ])
    ..get('/api/groupware/bookings/mine', (_) => [_bookings()[1]])
    ..get('/api/groupware/bookings/pending', [])
    ..get('/api/groupware/bookings', (_) => _bookings())
    ..get('/api/groupware/card-transactions', (_) => _cardPage())
    ..get('/api/groupware/payroll/mine', {
      'canManage': false,
      'items': [
        _slip('P10', 10 > _now.month ? _now.month : 10, viewed: false),
        _slip('P9', 9),
        _slip('P8', 8),
        _slip('P7', 7),
      ],
    })
    ..get('/api/groupware/surveys', {
      'items': [
        _survey('s1', '연말 워크숍 장소·일정 조사', '최민호', pending: true, closesInDays: 3),
        _survey(
          's2',
          '사내 교육 만족도 조사',
          '정다은',
          pending: false,
          responses: 11,
          closesInDays: 7,
        ),
        _survey('s3', '새 사무실 좌석 배치 의견', '박지훈', pending: false, responses: 12),
      ],
      'pendingCount': 1,
    })
    ..get(
      '/api/groupware/work-reports',
      (req) => _workReport(req.url.queryParameters['kind'] ?? 'daily'),
    )
    ..get(
      '/api/groupware/work-reports/:id',
      (_) => {
        ...(_workReport('daily')['report'] as Map<String, dynamic>),
        'comments': [
          {
            'id': 'c1',
            'userName': '최민호',
            'text': '보고서 초안 오후에 같이 봐요.',
            'createdAt': _ms(_now.subtract(const Duration(hours: 1))),
          },
        ],
        'canEdit': true,
      },
    )
    ..get('/api/groupware/forms', _forms())
    ..get('/api/groupware/approval-lines', {
      'lines': [
        {
          'id': 'L1',
          'name': '팀장 → 본부장',
          'approverIds': [_lead, _boss],
          'ccIds': [],
        },
      ],
      'suggested': {
        'approverIds': [_lead, _boss],
        'ccIds': [],
        'source': 'org',
      },
    })
    ..get('/api/groupware/documents/:id', (req) {
      final id = req.url.pathSegments.last;
      return _documents().firstWhere((d) => d['id'] == id);
    })
    ..get('/api/groupware/context', _context())
    ..get('/api/groupware/documents', (req) {
      final q = req.url.queryParameters;
      return [
        for (final d in _documents())
          if ((q['box'] ?? 'inbox') == 'inbox'
              ? d['myTurn'] == true
              : d['authorId'] == _me)
            if (q['kind'] == null || q['kind'] == d['kind']) d,
      ];
    })
    ..get('/api/groupware/leave/balance', _balance)
    ..get('/api/groupware/leave/calendar', [])
    ..get('/api/groupware/candidates', [
      {'id': _lead, 'name': '이수진', 'username': 'sujin.lee'},
      {'id': _boss, 'name': '최민호', 'username': 'minho.choi'},
    ]);
  api.fallback = (req) {
    // ignore: avoid_print
    print('[fake] 등록 안 됨: ${req.method} ${req.url}');
    return req.method == 'GET' ? [] : {};
  };
  return api;
}

Future<void> _openGroupware(WidgetTester tester, GuideFakeApi api) async {
  final session = guideSession(api: api);
  await pumpGuideApp(
    tester,
    GroupwareScreen(
      session: session,
      api: GroupwareApi(session.api!, teamId: 't1'),
    ),
  );
  await settleGuide(tester);
}

Future<void> _tab(WidgetTester tester, String label) async {
  await tester.tap(find.widgetWithText(Tab, label));
  await settleGuide(tester);
}

void main() {
  setUpAll(() {
    if (Platform.environment['GUIDE_DRAFT'] == '1') {
      guideImagesDirOverride = Directory.systemTemp.createTempSync('guide_gw_');
    }
  });
  tearDownAll(() {
    guideImagesDirOverride = null;
    printGuideImagesSize();
  });

  guideCapture('메뉴 › 툴 묶음', GuideSurface.desktopSmall, (tester) async {
    final session = guideSession(api: _api());
    await pumpGuideApp(
      tester,
      Scaffold(
        appBar: AppBar(
          title: const Text('마케팅팀'),
          actions: [
            AppMenuButton(session: session),
            const SizedBox(width: 8),
          ],
        ),
        body: const SizedBox.shrink(),
      ),
    );
    final button = find.byTooltip('메뉴');
    final buttonRect = tester.getRect(button);
    await tester.tap(button);
    await settleGuide(tester);
    final tools = ['그룹웨어', '드라이브', '위키', '메일']
        .map(
          (t) => find
              .ancestor(of: find.text(t), matching: find.byType(InkWell))
              .first,
        )
        .toList();
    final popup = find.byType(PopupMenuItem<void>).first;
    await saveGuideShot(
      tester,
      'groupware-menu',
      callouts: [
        GuideCallout.rect(buttonRect.deflate(2), number: 1),
        for (final (i, t) in tools.indexed)
          GuideCallout.box(t, number: i + 2, badge: CalloutBadge.left),
      ],
      crop: cropAround(tester, [popup, button], margin: 12),
    );
  });

  guideCapture('결재 탭 — 결재함', _wide, (tester) async {
    await _openGroupware(tester, _api());
    await saveGuideShot(
      tester,
      'groupware-approval',
      callouts: [
        GuideCallout.box(find.byType(TabBar), number: 1),
        GuideCallout.box(find.widgetWithText(FilledButton, '새 결재'), number: 2),
        GuideCallout.box(
          find.byTooltip('결재 설정'),
          number: 3,
          badge: CalloutBadge.top,
        ),
        GuideCallout.rect(
          unionRect(tester, [
            find.textContaining('결재할 문서').first,
            find.text('보관함'),
          ], padding: 16),
          number: 4,
          badge: CalloutBadge.topRight,
        ),
        GuideCallout.rect(
          unionRect(tester, [
            find.text('연차 신청 (11/3~11/4, 2일)'),
            find.textContaining('김하나 결재 차례').first,
          ], padding: 8),
          number: 5,
          badge: CalloutBadge.left,
        ),
      ],
      crop: const Rect.fromLTWH(0, 0, 1000, 330),
    );
  });

  guideCapture('새 결재 — 고르기와 휴가 신청 창', _wide, (tester) async {
    await _openGroupware(tester, _api());
    await tester.tap(find.widgetWithText(FilledButton, '새 결재'));
    await settleGuide(tester);
    final chooser = _dialogSurface();
    await saveGuideShot(
      tester,
      'groupware-approval-new',
      callouts: [
        GuideCallout.rect(
          unionRect(tester, [
            find.byKey(const ValueKey('new-approval-leave')),
            find.byKey(const ValueKey('new-approval-expense')),
          ], padding: 0),
          number: 1,
          badge: CalloutBadge.left,
        ),
        GuideCallout.rect(
          unionRect(tester, [
            find.text('일반 기안서'),
            find.text('연장 · 야간 · 휴일근무'),
          ], padding: 10),
          number: 2,
          badge: CalloutBadge.left,
        ),
      ],
      crop: cropAround(tester, [chooser], margin: 12),
    );

    // 휴가 신청 창 — 사유를 쓰고, 두 번째 결재자의 역할을 전결로 바꿔 본다(결재 → 합의 → 전결).
    await tester.tap(find.byKey(const ValueKey('new-approval-leave')));
    await settleGuide(tester);
    await tester.enterText(find.widgetWithText(TextField, '사유'), '가족 여행');
    final secondRole = find.byKey(const ValueKey('approval-line-role-$_boss'));
    for (var i = 0; i < 2; i++) {
      await tester.tap(secondRole);
      await settleGuide(tester);
    }
    await saveGuideShot(
      tester,
      'groupware-approval-leave',
      callouts: [
        GuideCallout.rect(
          tester
              .getRect(find.byType(DropdownButtonFormField<String>).first)
              .inflate(4),
          number: 1,
          badge: CalloutBadge.left,
        ),
        GuideCallout.rect(
          unionRect(tester, [
            find.ancestor(
              of: find.text('시작'),
              matching: find.byType(OutlinedButton),
            ),
            find.ancestor(
              of: find.text('끝'),
              matching: find.byType(OutlinedButton),
            ),
          ], padding: 4),
          number: 2,
          badge: CalloutBadge.left,
        ),
        GuideCallout.rect(
          (() {
            final r = unionRect(tester, [
              find.text('이수진').last,
              find.byKey(const ValueKey('approval-line-role-$_lead')),
              secondRole,
            ], padding: 6);
            return Rect.fromLTRB(r.left - 44, r.top, r.right + 120, r.bottom);
          })(),
          number: 3,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(secondRole, number: 4, badge: CalloutBadge.bottom),
        GuideCallout.box(
          find.widgetWithText(FilledButton, '결재 올리기'),
          number: 5,
        ),
      ],
      crop: cropAround(tester, [_dialogSurface()], margin: 12),
    );
  });

  guideCapture('결재 문서 — 승인 · 반려', _wide, (tester) async {
    await _openGroupware(tester, _api());
    await tester.tap(find.text('연차 신청 (11/3~11/4, 2일)'));
    await settleGuide(tester);
    await saveGuideShot(
      tester,
      'groupware-approval-detail',
      callouts: [
        GuideCallout.rect(
          unionRect(
            tester,
            [find.text('결재 1').last, find.text('결재 2').last],
            padding: 2,
          ).expandToInclude(tester.getRect(find.text('최민호').first).inflate(14)),
          number: 1,
          badge: CalloutBadge.left,
        ),
        GuideCallout.rect(
          unionRect(tester, [
            find.text('결재선'),
            find.textContaining('최민호 · 결재').first,
          ], padding: 8),
          number: 2,
          badge: CalloutBadge.left,
        ),
        GuideCallout.rect(
          unionRect(tester, [
            find.widgetWithText(OutlinedButton, '반려'),
            find.widgetWithText(FilledButton, '승인'),
          ], padding: 4),
          number: 3,
        ),
        GuideCallout.rect(
          unionRect(tester, [
            find.byIcon(Icons.print_outlined),
            find.byIcon(Icons.verified_user_outlined),
          ], padding: 6),
          number: 4,
          badge: CalloutBadge.left,
        ),
      ],
      crop: cropAround(tester, [_dialogSurface()], margin: 12),
    );
  });

  guideCapture('휴가 탭', _tall, (tester) async {
    await _openGroupware(tester, _api());
    await _tab(tester, '휴가');
    await saveGuideShot(
      tester,
      'groupware-leave',
      callouts: [
        GuideCallout.box(
          find.text('남은 연차'),
          number: 1,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(
          find.widgetWithText(FilledButton, '휴가 신청'),
          number: 2,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(
          find.text('앞으로 30일'),
          number: 3,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(find.text('최민준'), number: 4, badge: CalloutBadge.left),
      ],
      crop: _below(tester, tester.getRect(find.text('이날 휴가 신청')).bottom + 12),
    );
  });

  guideCapture('출퇴근 탭', _wide, (tester) async {
    await _openGroupware(tester, _api());
    await _tab(tester, '출퇴근');
    await saveGuideShot(
      tester,
      'groupware-attendance',
      callouts: [
        GuideCallout.rect(
          unionRect(tester, [
            find.widgetWithIcon(FilledButton, Icons.login),
            find.widgetWithIcon(FilledButton, Icons.logout),
          ], padding: 4),
          number: 1,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(
          find.widgetWithIcon(OutlinedButton, Icons.free_breakfast_outlined),
          number: 2,
        ),
        GuideCallout.box(
          find.textContaining('이번 주'),
          number: 3,
          badge: CalloutBadge.left,
        ),
        GuideCallout.rect(
          unionRect(tester, [
            find.textContaining('출근 1'),
            find.textContaining('연장 3'),
          ], padding: 8),
          number: 4,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(find.text('수정 요청').at(1), number: 5),
      ],
      crop: _below(tester, 560),
    );
  });

  guideCapture('지출 탭', _wide, (tester) async {
    await _openGroupware(tester, _api());
    await _tab(tester, '지출');
    await saveGuideShot(
      tester,
      'groupware-expense',
      callouts: [
        GuideCallout.box(
          find.byType(Checkbox).first,
          number: 1,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(find.byIcon(Icons.receipt_long).first, number: 2),
        GuideCallout.box(
          _buttonOf(find.textContaining('지출 결재로 청구')),
          number: 3,
        ),
        GuideCallout.box(
          _buttonOf(find.textContaining('지출 결재 올리기')),
          number: 4,
        ),
      ],
      crop: _below(
        tester,
        tester.getRect(find.textContaining('지출 결재 올리기')).bottom + 24,
      ),
    );
  });

  guideCapture('급여 탭', _wide, (tester) async {
    await _openGroupware(tester, _api());
    await _tab(tester, '급여');
    await saveGuideShot(
      tester,
      'groupware-payroll',
      callouts: [
        GuideCallout.box(find.byIcon(Icons.visibility_outlined), number: 1),
        GuideCallout.box(
          _tileOf(find.text('연말정산 공제 자료')),
          number: 2,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(
          _tileOf(find.textContaining('10월 급여').first),
          number: 3,
          badge: CalloutBadge.left,
        ),
      ],
      crop: _below(tester, 470),
    );
  });

  guideCapture('예약 탭', _wide, (tester) async {
    await _openGroupware(tester, _api());
    await _tab(tester, '예약');
    await saveGuideShot(
      tester,
      'groupware-resource',
      callouts: [
        GuideCallout.rect(
          unionRect(tester, [
            find.byWidgetPredicate(
              (w) => w is Text && RegExp(r'^\d+월 \d+일').hasMatch(w.data ?? ''),
            ),
            find.byIcon(Icons.chevron_right).first,
          ], padding: 6),
          number: 1,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(_buttonOf(find.textContaining('예약하기')), number: 2),
        GuideCallout.box(
          find
              .ancestor(
                of: find.textContaining('14:00 고객').first,
                matching: find.byType(Container),
              )
              .first,
          number: 3,
        ),
        GuideCallout.box(
          find.text('내 예약'),
          number: 4,
          badge: CalloutBadge.left,
        ),
      ],
      crop: _below(tester, tester.getRect(find.text('내 예약')).bottom + 60),
    );
  });

  guideCapture('설문 탭', _wide, (tester) async {
    await _openGroupware(tester, _api());
    await _tab(tester, '설문');
    await saveGuideShot(
      tester,
      'groupware-survey',
      callouts: [
        GuideCallout.box(
          _buttonOf(find.textContaining('새 설문')),
          number: 1,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(
          _tileOf(find.text('연말 워크숍 장소·일정 조사')),
          number: 2,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(
          find.text('응답하기'),
          number: 3,
          badge: CalloutBadge.left,
        ),
      ],
      crop: _below(tester, 340),
    );
  });

  guideCapture('업무일지 탭', _wide, (tester) async {
    await _openGroupware(tester, _api());
    await _tab(tester, '업무일지');
    await saveGuideShot(
      tester,
      'groupware-report',
      callouts: [
        GuideCallout.rect(
          unionRect(tester, [find.text('일일'), find.text('주간')], padding: 10),
          number: 1,
          badge: CalloutBadge.left,
        ),
        GuideCallout.rect(
          unionRect(tester, [
            find.byIcon(Icons.chevron_left).first,
            find.byIcon(Icons.chevron_right).first,
          ], padding: 4),
          number: 2,
          badge: CalloutBadge.left,
        ),
        GuideCallout.rect(
          (() {
            final r = unionRect(tester, [
              find.text('한 일'),
              find.textContaining('랜딩 페이지 개발'),
            ], padding: 4);
            return Rect.fromLTRB(
              r.left - 10,
              r.top + 2,
              r.right + 10,
              r.bottom + 40,
            );
          })(),
          number: 3,
          badge: CalloutBadge.left,
        ),
        GuideCallout.rect(
          unionRect(tester, [
            find.textContaining('받는 사람'),
            find.textContaining('확인:'),
          ], padding: 2),
          number: 4,
          badge: CalloutBadge.right,
        ),
        GuideCallout.box(
          find.text('팀 현황'),
          number: 5,
          badge: CalloutBadge.right,
        ),
      ],
      crop: _below(tester, 640),
    );
  });
}

/// 탭 막대 바로 아래부터 [bottom]까지 잘라내는 영역(그룹웨어 탭 그림).
Rect _below(WidgetTester tester, double bottom) {
  final top = tester.getRect(find.byType(TabBar)).bottom;
  return Rect.fromLTRB(0, top, 1000, bottom);
}

/// [label]이 든 단추 전체(Filled·Outlined·Text 단추).
Finder _buttonOf(Finder label) => find
    .ancestor(of: label, matching: find.bySubtype<ButtonStyleButton>())
    .first;

/// [label]이 든 목록 한 줄(ListTile) — 표시 상자를 줄 전체에 두를 때.
Finder _tileOf(Finder label) =>
    find.ancestor(of: label, matching: find.byType(ListTile)).first;

/// 지금 떠 있는 대화상자의 바탕(둥근 판) — 잘라낼 때 쓴다(AlertDialog 자체는 화면 전체를 차지한다).
Finder _dialogSurface() => find
    .descendant(of: find.byType(Dialog), matching: find.byType(Material))
    .first;

/// 그룹웨어 탭 그림 — 본문 폭(약 750px)에 맞게 1000px 창으로 찍는다.
const _wide = GuideSurface(Size(1000, 700));

/// 휴가 탭처럼 아래로 긴 화면.
const _tall = GuideSurface(Size(1000, 1000));
