// 도움말 "그룹웨어 · 업무 도구"(server/guide/groupware.html)의 조직도 · 위키 · 드라이브 · 메일 그림을 찍는다.
//
// 다시 찍기(client 폴더에서):
//   flutter test tool/guide_capture/tools_capture_test.dart
// 결과: ../server/guide/images/tools-*.png
//
// 응답 모양은 client/test/의 org_tree_test.dart · wiki_screen_test.dart · drive_test.dart · mail_test.dart와 같다.
import 'dart:async';
import 'dart:io';

import 'package:client/screens/drive/drive_screen.dart';
import 'package:client/screens/mail/mail_screen.dart';
import 'package:client/screens/org_chart_screen.dart';
import 'package:client/screens/wiki/wiki_screen.dart';
import 'package:client/services/wiki_doc.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'guide_capture.dart';

final _now = DateTime.now();
int _ago(Duration d) => _now.subtract(d).millisecondsSinceEpoch;

// ───────────────────────────── 조직도 ─────────────────────────────

Map<String, dynamic> _dept(
  String id,
  String name, {
  String? parent,
  String? head,
  int order = 0,
}) => {
  'id': id,
  'parentId': parent,
  'name': name,
  'headId': head,
  'sortOrder': order,
};

Map<String, dynamic> _member(
  String id,
  String name, {
  String? dept,
  String? effective,
  String? position,
}) => {
  'id': id,
  'name': name,
  'username': id,
  'role': 'member',
  'avatarType': 'initial',
  'position': position,
  'departmentId': dept,
  'managerId': null,
  'effectiveManagerId': effective,
};

final _orgTree = {
  'scope': 'server',
  'scopeKey': 'server',
  'teamId': null,
  'canEdit': false,
  'departments': [
    _dept('ceo', '대표실', head: 'u-ceo'),
    _dept('biz', '사업본부', parent: 'ceo', head: 'u-boss'),
    _dept('mkt', '마케팅팀', parent: 'biz', head: 'u-lead'),
    _dept('sales', '영업팀', parent: 'biz', head: 'u-sales', order: 1),
    _dept('mgmt', '경영지원팀', parent: 'ceo', head: 'u-mgmt', order: 1),
  ],
  'members': [
    _member('u-ceo', '강대표', dept: 'ceo', position: '대표'),
    _member('u-boss', '최민호', dept: 'biz', effective: 'u-ceo', position: '본부장'),
    _member('u-lead', '이수진', dept: 'mkt', effective: 'u-boss', position: '팀장'),
    _member('u-me', '김하나', dept: 'mkt', effective: 'u-lead', position: '대리'),
    _member('u-park', '박지훈', dept: 'mkt', effective: 'u-lead', position: '사원'),
    _member('u-lee', '이서연', dept: 'mkt', effective: 'u-lead', position: '주임'),
    _member(
      'u-sales',
      '정우진',
      dept: 'sales',
      effective: 'u-boss',
      position: '팀장',
    ),
    _member(
      'u-choi',
      '최민준',
      dept: 'sales',
      effective: 'u-sales',
      position: '대리',
    ),
    _member('u-mgmt', '한지민', dept: 'mgmt', effective: 'u-ceo', position: '팀장'),
    _member('u-jung', '정다은', dept: 'mgmt', effective: 'u-mgmt', position: '사원'),
  ],
};

// ───────────────────────────── 위키 ─────────────────────────────

/// 위키 동시 편집 통로 흉내 — 페이지에 들어가면(wiki:join) 바로 본문과 함께 보는 사람을 돌려준다.
class _FakeWikiTransport implements WikiTransport {
  final _events = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  final _reconnected = StreamController<void>.broadcast(sync: true);

  @override
  void request(
    String event,
    Map<String, dynamic> payload,
    void Function(Map<String, dynamic>) onAck,
  ) {
    if (event == 'wiki:join') {
      onAck({
        'ok': true,
        'revision': 12,
        'title': '신규 입사자 온보딩',
        'canEdit': true,
        'body': _wikiBody,
        'editors': [
          {'userId': 'u-me', 'name': '김하나', 'color': '#1971C2'},
          {'userId': 'u-lee', 'name': '이서연', 'color': '#E8590C'},
        ],
      });
    } else {
      onAck({'ok': true});
    }
  }

  @override
  void emit(String event, Map<String, dynamic> payload) {}

  @override
  Stream<Map<String, dynamic>> get events => _events.stream;

  @override
  Stream<void> get reconnected => _reconnected.stream;
}

const _wikiBody = '''# 신규 입사자 온보딩

첫 주에 해야 할 일을 정리했습니다. 궁금한 점은 #마케팅팀 토픽에 물어보세요.

## 첫날
- 노트북 · 사원증 받기(경영지원팀)
- TangoTalk 설치하고 팀에 들어가기
- 그룹웨어에서 **출근** 누르기

## 첫 주
- 팀 위키의 업무 매뉴얼 읽기
- 공유 드라이브 > 마케팅 > 브랜드 가이드 확인
''';

// ───────────────────────────── 드라이브 ─────────────────────────────

Map<String, dynamic> _file(
  String id,
  String name,
  int size, {
  int version = 1,
  String by = '이서연',
  int daysAgo = 1,
}) => {
  'id': id,
  'name': name,
  'folderId': null,
  'version': version,
  'size': size,
  'updatedByName': by,
  'updatedAt': _ago(Duration(days: daysAgo, hours: 2)),
  'url': '/files/token-$id',
  'createdBy': 'u-me',
};

Map<String, dynamic> _folder(String id, String name) => {
  'id': id,
  'name': name,
  'createdBy': 'u-me',
  'updatedAt': _ago(const Duration(days: 3)),
};

final _driveListing = {
  'folder': null,
  'path': <Object>[],
  'folders': [
    _folder('f1', '2026 캠페인'),
    _folder('f2', '브랜드 가이드'),
    _folder('f3', '회의록'),
  ],
  'files': [
    _file('x1', '10월 광고 성과 보고서.xlsx', 182 * 1024, version: 4, by: '김하나'),
    _file(
      'x2',
      '11월 프로모션 기획안.pptx',
      4 * 1024 * 1024 + 300 * 1024,
      version: 2,
      daysAgo: 2,
    ),
    _file('x3', '로고 원본.ai', 12 * 1024 * 1024, by: '박지훈', daysAgo: 20),
    _file('x4', '보도자료 초안.docx', 64 * 1024, version: 3, by: '이수진', daysAgo: 5),
  ],
  'canWrite': true,
  'isManager': false,
  'usageBytes': 1536 * 1024 * 1024,
};

// ───────────────────────────── 메일 ─────────────────────────────

const _mailAccount = {
  'id': 'A1',
  'email': 'hana.kim@tangocorp.kr',
  'displayName': '김하나',
  'provider': 'naverworks',
  'providerLabel': '네이버웍스',
  'imap': {'host': 'imap.worksmobile.com', 'port': 993, 'security': 'ssl'},
  'smtp': {'host': 'smtp.worksmobile.com', 'port': 465, 'security': 'ssl'},
  'username': 'hana.kim@tangocorp.kr',
  'notify': true,
  'lastError': null,
};

Map<String, dynamic> _mail(
  int uid,
  String subject,
  String name,
  String address, {
  required Duration ago,
  bool seen = true,
  bool flagged = false,
  bool attachments = false,
}) => {
  'uid': uid,
  'subject': subject,
  'from': {'name': name, 'address': address},
  'to': [
    {'name': '김하나', 'address': 'hana.kim@tangocorp.kr'},
  ],
  'date': _ago(ago),
  'seen': seen,
  'flagged': flagged,
  'answered': false,
  'hasAttachments': attachments,
  'messageId': '<m$uid@x.kr>',
};

final _mails = [
  _mail(
    9,
    '[한빛유통] 11월 프로모션 단가 견적서 송부',
    '오태식 과장',
    'ts.oh@hanbit.co.kr',
    ago: const Duration(minutes: 25),
    seen: false,
    attachments: true,
  ),
  _mail(
    8,
    '광고 대행 계약 갱신 안내',
    '그린애드',
    'contract@greenad.kr',
    ago: const Duration(hours: 3),
    seen: false,
  ),
  _mail(
    7,
    'Re: 브랜드 가이드 v3 검토 의견',
    '이수진',
    'sujin.lee@tangocorp.kr',
    ago: const Duration(hours: 6),
    flagged: true,
  ),
  _mail(
    6,
    '10월 광고 집행 내역(확정)',
    '네이버 광고',
    'noreply@searchad.naver.com',
    ago: const Duration(days: 1, hours: 2),
    attachments: true,
  ),
  _mail(
    5,
    '세미나 초대 — 2026 디지털 마케팅 트렌드',
    '마케팅인사이트',
    'event@minsight.kr',
    ago: const Duration(days: 2),
  ),
];

Map<String, dynamic> _mailDetail(int uid) => {
  'uid': uid,
  'subject': '[한빛유통] 11월 프로모션 단가 견적서 송부',
  'from': {'name': '오태식 과장', 'address': 'ts.oh@hanbit.co.kr'},
  'to': [
    {'name': '김하나', 'address': 'hana.kim@tangocorp.kr'},
  ],
  'cc': [
    {'name': '이수진', 'address': 'sujin.lee@tangocorp.kr'},
  ],
  'replyTo': [],
  'date': _ago(const Duration(minutes: 25)),
  'text':
      '김하나 대리님, 안녕하세요.\n한빛유통 오태식입니다.\n\n지난주 미팅에서 말씀 나눈 11월 프로모션 단가 견적서를 첨부드립니다.\n'
      '수량별 단가는 2페이지에 정리했습니다.\n\n검토 후 회신 부탁드립니다.\n감사합니다.\n\n오태식 드림',
  'truncated': false,
  'html': false,
  'messageId': '<m$uid@x.kr>',
  'references': [],
  'attachments': [
    {
      'index': 0,
      'fileName': '11월 프로모션 견적서.pdf',
      'contentType': 'application/pdf',
      'size': 412 * 1024,
    },
  ],
  'flagged': false,
};

GuideFakeApi _api() => GuideFakeApi()
  ..get('/api/org-tree', _orgTree)
  ..get('/api/wiki', {
    'pages': [
      {
        'id': 'p1',
        'title': '신규 입사자 온보딩',
        'depth': 0,
        'updatedAt': _ago(const Duration(hours: 1)),
      },
      {
        'id': 'p2',
        'parentId': 'p1',
        'title': '장비 · 계정 신청',
        'depth': 1,
        'updatedAt': _ago(const Duration(days: 2)),
      },
      {
        'id': 'p3',
        'title': '업무 매뉴얼',
        'depth': 0,
        'updatedAt': _ago(const Duration(days: 4)),
      },
      {
        'id': 'p4',
        'parentId': 'p3',
        'title': '광고 집행 절차',
        'depth': 1,
        'updatedAt': _ago(const Duration(days: 4)),
      },
      {
        'id': 'p5',
        'parentId': 'p3',
        'title': '보도자료 쓰는 법',
        'depth': 1,
        'updatedAt': _ago(const Duration(days: 9)),
      },
      {
        'id': 'p6',
        'title': '회의록',
        'depth': 0,
        'updatedAt': _ago(const Duration(days: 1)),
      },
    ],
    'canEdit': true,
    'isManager': false,
  })
  ..get('/api/wiki/:id', {
    'id': 'p1',
    'title': '신규 입사자 온보딩',
    'body': _wikiBody,
    'revision': 12,
    'path': <Object>[],
    'canEdit': true,
    'canRemove': true,
    'updatedByName': '이서연',
    'updatedAt': _ago(const Duration(hours: 1)),
  })
  ..get('/api/drive', _driveListing)
  ..get('/api/mail/presets', [])
  ..get('/api/mail/accounts', {
    'accounts': [_mailAccount],
    'max': 5,
  })
  ..get('/api/mail/status', {'connected': true, 'unseen': 2, 'accounts': []})
  ..get('/api/mail/folders', [
    {
      'path': 'INBOX',
      'name': '받은편지함',
      'specialUse': r'\Inbox',
      'unseen': 2,
      'total': 5,
    },
    {'path': 'Sent', 'name': '보낸편지함', 'specialUse': r'\Sent'},
    {'path': 'Drafts', 'name': '임시보관함', 'specialUse': r'\Drafts'},
    {'path': 'Junk', 'name': '스팸편지함', 'specialUse': r'\Junk'},
    {'path': 'Trash', 'name': '휴지통', 'specialUse': r'\Trash'},
    {'path': '거래처', 'name': '거래처'},
  ])
  ..get('/api/mail/messages', {'messages': _mails, 'nextBefore': null})
  ..get(
    '/api/mail/message',
    (req) => _mailDetail(int.parse(req.url.queryParameters['uid'] ?? '9')),
  )
  ..post('/api/mail/flags', {'ok': true});

void main() {
  setUpAll(() {
    if (Platform.environment['GUIDE_DRAFT'] == '1') {
      guideImagesDirOverride = Directory.systemTemp.createTempSync(
        'guide_tools_',
      );
    }
  });
  tearDownAll(() {
    guideImagesDirOverride = null;
    printGuideImagesSize();
  });

  guideCapture('조직도 — 부서 탭', const GuideSurface(Size(1000, 760)), (
    tester,
  ) async {
    final session = guideSession(api: _api());
    session.orgScope = 'account';
    await pumpGuideApp(
      tester,
      Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: FilledButton(
              onPressed: () => showOrgChartScreen(context, session),
              child: const Text('조직도'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('조직도'));
    await settleGuide(tester);
    // 사업본부 › 마케팅팀을 펼친다.
    await tester.tap(find.text('사업본부'));
    await settleGuide(tester);
    await tester.tap(find.text('마케팅팀'));
    await settleGuide(tester);
    final dialog = find
        .descendant(of: find.byType(Dialog), matching: find.byType(Material))
        .first;
    await saveGuideShot(
      tester,
      'tools-org',
      callouts: [
        GuideCallout.box(find.byType(TextField), number: 1),
        GuideCallout.box(
          find.byTooltip('그림으로 보기'),
          number: 2,
          badge: CalloutBadge.left,
        ),
        GuideCallout.rect(
          unionRect(tester, [
            find.text('마케팅팀'),
            find.text('부서장 이수진'),
          ], padding: 6),
          number: 3,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(
          find.textContaining('상위자 이수진').first,
          number: 4,
          badge: CalloutBadge.right,
        ),
      ],
      crop: cropAround(tester, [dialog], margin: 8),
    );
  });

  guideCapture('위키', const GuideSurface(Size(1100, 720)), (tester) async {
    final session = guideSession(api: _api());
    await pumpGuideApp(
      tester,
      WikiScreen(
        session: session,
        teamId: 't1',
        teamName: '마케팅팀',
        transport: _FakeWikiTransport(),
      ),
    );
    await settleGuide(tester);
    await tester.tap(find.byKey(const ValueKey('wiki-row-p1')));
    await settleGuide(tester);
    await saveGuideShot(
      tester,
      'tools-wiki',
      callouts: [
        GuideCallout.rect(
          unionRect(tester, [
            find.text('신규 입사자 온보딩').first,
            find.text('회의록'),
          ], padding: 8),
          number: 1,
          badge: CalloutBadge.right,
        ),
        GuideCallout.box(find.byTooltip('새 페이지'), number: 2),
        GuideCallout.box(
          find.byKey(const ValueKey('wiki-edit')),
          number: 3,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(
          find.byKey(const ValueKey('wiki-presence')),
          number: 4,
          badge: CalloutBadge.right,
        ),
        GuideCallout.box(find.byTooltip('더보기').last, number: 5),
      ],
    );
  });

  guideCapture('드라이브', const GuideSurface(Size(1000, 640)), (tester) async {
    final session = guideSession(api: _api());
    await pumpGuideApp(
      tester,
      DriveScreen(session: session, teamId: 't1', teamName: '마케팅팀'),
    );
    await settleGuide(tester);
    await saveGuideShot(
      tester,
      'tools-drive',
      callouts: [
        GuideCallout.box(
          find.byKey(const ValueKey('drive-new-folder')),
          number: 1,
          badge: CalloutBadge.bottom,
        ),
        GuideCallout.box(
          find.byKey(const ValueKey('drive-upload')),
          number: 2,
          badge: CalloutBadge.bottom,
        ),
        GuideCallout.box(
          find.byKey(const ValueKey('drive-file-x1')),
          number: 3,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(
          find.byTooltip('휴지통'),
          number: 4,
          badge: CalloutBadge.bottom,
        ),
        GuideCallout.box(
          find.byTooltip('찾기'),
          number: 5,
          badge: CalloutBadge.bottom,
        ),
      ],
      crop: const Rect.fromLTWH(0, 0, 1000, 600),
    );
  });

  guideCapture('메일', const GuideSurface(Size(1280, 760)), (tester) async {
    final session = guideSession(api: _api());
    await pumpGuideApp(
      tester,
      MailScreen(session: session, api: session.mailApi),
    );
    await settleGuide(tester);
    await tester.tap(find.text('[한빛유통] 11월 프로모션 단가 견적서 송부').first);
    await settleGuide(tester);
    await saveGuideShot(
      tester,
      'tools-mail',
      callouts: [
        GuideCallout.rect(
          unionRect(tester, [
            find.text('hana.kim@tangocorp.kr'),
            find.text('네이버웍스'),
          ], padding: 8),
          number: 1,
          badge: CalloutBadge.right,
        ),
        GuideCallout.rect(
          unionRect(tester, [
            find.text('받은편지함').last,
            find.text('폴더 만들기'),
          ], padding: 8),
          number: 2,
          badge: CalloutBadge.right,
        ),
        GuideCallout.rect(
          unionRect(tester, [
            find.text('오태식 과장').first,
            find.text('세미나 초대 — 2026 디지털 마케팅 트렌드'),
          ], padding: 10),
          number: 3,
          badge: CalloutBadge.bottom,
        ),
        GuideCallout.rect(
          unionRect(tester, [find.text('답장'), find.text('전달')], padding: 14),
          number: 4,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(
          find
              .ancestor(
                of: find.text('메일 쓰기'),
                matching: find.bySubtype<ButtonStyleButton>(),
              )
              .first,
          number: 5,
          badge: CalloutBadge.left,
        ),
      ],
      crop: const Rect.fromLTWH(0, 0, 1280, 560),
    );
  });
}
