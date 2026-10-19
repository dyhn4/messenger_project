// 웹메일 후속 2(앱) — 대화로 묶어 보기(묶기 규칙·펼치기·끄기), 여러 통 고르기(읽음·옮기기·지우기를 한꺼번에), 폴더 만들기·이름
// 바꾸기·지우기, 서식 있는 메일 쓰기(보낼 때 서식 구간·임시 저장본에서 되살리기), 보낸 쪽 확인 경고(스팸 아님), 관리자 웹메일 칸의
// 스팸 거르기·DKIM. 서버는 가짜 HTTP.
import 'dart:convert';

import 'package:client/models/mail.dart';
import 'package:client/models/mail_threads.dart';
import 'package:client/screens/admin_webmail_section.dart';
import 'package:client/screens/mail/mail_compose.dart';
import 'package:client/screens/mail/mail_screen.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:client/widgets/rich_text_format.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

http.Response _json(Object? body, {int status = 200}) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

Map<String, dynamic> _acc(String id, String email) => {
  'id': id,
  'email': email,
  'displayName': null,
  'provider': 'naver',
  'providerLabel': '네이버 메일',
  'authType': 'password',
  'imap': {'host': 'imap.naver.com', 'port': 993, 'security': 'ssl'},
  'smtp': {'host': 'smtp.naver.com', 'port': 465, 'security': 'ssl'},
  'username': email,
  'notify': true,
  'signature': '',
  'signatureOnNew': true,
  'signatureOnReply': true,
  'trustedSenders': [],
  'lastError': null,
};

List<Map<String, dynamic>> _folderRows({
  List<String> custom = const ['News'],
}) => [
  {
    'path': 'INBOX',
    'name': '받은편지함',
    'specialUse': r'\Inbox',
    'unseen': 1,
    'total': 3,
  },
  {'path': 'Sent', 'name': '보낸편지함', 'specialUse': r'\Sent'},
  {'path': 'Junk', 'name': '스팸편지함', 'specialUse': r'\Junk'},
  for (final c in custom) {'path': c, 'name': c, 'editable': true, 'depth': 0},
];

Map<String, dynamic> _summary(
  int uid,
  String subject, {
  String? messageId,
  String? inReplyTo,
  List<String> references = const [],
  bool seen = false,
}) => {
  'uid': uid,
  'subject': subject,
  'from': {'name': '김', 'address': 'kim@x.kr'},
  'to': [
    {'name': '', 'address': 'me@corp.kr'},
  ],
  'date': DateTime(2026, 10, 17, 9, uid).millisecondsSinceEpoch,
  'seen': seen,
  'flagged': false,
  'answered': false,
  'draft': false,
  'hasAttachments': false,
  'messageId': ?messageId,
  'inReplyTo': ?inReplyTo,
  'references': references,
};

Map<String, dynamic> _detail(int uid, {Map<String, dynamic>? auth}) => {
  'uid': uid,
  'subject': '제목 $uid',
  'from': {'name': '김', 'address': 'kim@x.kr'},
  'to': [
    {'name': '', 'address': 'me@corp.kr'},
  ],
  'cc': [],
  'replyTo': [],
  'date': DateTime(2026, 10, 17, 9, 5).millisecondsSinceEpoch,
  'text': '본문',
  'truncated': false,
  'html': false,
  'rich': null,
  'messageId': '<m$uid@x.kr>',
  'references': [],
  'attachments': [],
  'flagged': false,
  'draft': false,
  'auth': ?auth,
};

class _Harness {
  final requests = <http.Request>[];
  final routes = <String, http.Response Function(http.Request)>{};
  late final Session session;
  List<Map<String, dynamic>> folders = _folderRows();
  List<Map<String, dynamic>> inbox = [
    // 9가 8에 대한 답장, 7은 따로.
    _summary(
      9,
      'Re: 회의',
      messageId: '<m9@x.kr>',
      inReplyTo: '<m8@x.kr>',
      references: ['<m8@x.kr>'],
    ),
    _summary(8, '회의', messageId: '<m8@x.kr>'),
    _summary(7, '다른 일', messageId: '<m7@x.kr>'),
  ];
  _Harness() {
    session = Session(
      notifications: NotificationService(),
      settings: AppSettings(),
    );
    session.serverUrl = 'https://test.local';
    session.api = ApiClient(
      baseUrl: 'https://test.local',
      token: 't',
      httpClient: MockClient((request) async {
        requests.add(request);
        final route = routes['${request.method} ${request.url.path}'];
        return route != null
            ? route(request)
            : _json({'error': 'no route'}, status: 404);
      }),
    );
    session.token = 't';
    session.userId = 'U-me';
    routes['GET /api/mail/accounts'] = (_) => _json({
      'accounts': [_acc('A1', 'me@corp.kr')],
      'max': 5,
    });
    routes['GET /api/mail/status'] = (_) =>
        _json({'connected': true, 'unseen': 1, 'accounts': []});
    routes['GET /api/mail/folders'] = (_) => _json(folders);
    routes['GET /api/mail/messages'] = (r) => _json({
      'messages': r.url.queryParameters['folder'] == 'Junk'
          ? [_summary(4, '당첨!')]
          : inbox,
      'nextBefore': null,
    });
    routes['GET /api/mail/message'] = (r) {
      final uid = int.parse(r.url.queryParameters['uid']!);
      return _json(
        _detail(
          uid,
          auth: uid == 4
              ? {
                  'verdict': 'junk',
                  'reason': '보낸 서버가 그 도메인의 메일 서버가 아닙니다(SPF 실패).',
                }
              : null,
        ),
      );
    };
    routes['GET /api/mail/contacts'] = (_) => _json([]);
    for (final p in ['/api/mail/flags', '/api/mail/move']) {
      routes['POST $p'] = (_) => _json({'ok': true});
    }
    routes['POST /api/mail/delete'] = (_) => _json({'result': 'trash'});
  }

  List<http.Request> called(String method, String path) =>
      requests.where((r) => r.method == method && r.url.path == path).toList();
  Map<String, dynamic> lastBody(String method, String path) =>
      jsonDecode(called(method, path).last.body) as Map<String, dynamic>;
}

Future<void> _pumpScreen(WidgetTester tester, _Harness h) async {
  tester.view.physicalSize = const Size(1400, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: MailScreen(session: h.session, api: h.session.mailApi),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('대화로 묶기(mail_threads.dart)', () {
    MailSummary s(
      int uid, {
      String? id,
      String? reply,
      List<String> refs = const [],
      bool seen = true,
    }) => MailSummary(
      uid: uid,
      subject: 's$uid',
      from: const MailAddress(address: 'a@b.c'),
      messageId: id,
      inReplyTo: reply,
      references: refs,
      seen: seen,
    );

    test(
      'In-Reply-To·References로 이어진 메일끼리, 맨 처음 메일이 목록에 없어도 묶고, 차례는 가장 새 메일',
      () {
        final threads = groupMailThreads([
          s(10, id: '<c>', refs: ['<root>', '<b>']),
          s(9, id: '<x>'),
          s(8, id: '<b>', reply: '<root>', refs: ['<root>'], seen: false),
          s(7, id: '<y>', refs: ['<root>']),
          s(6),
        ]);
        expect(
          [for (final t in threads) t.uids],
          [
            [10, 8, 7],
            [9],
            [6],
          ],
        );
        expect(threads.first.count, 3);
        expect(threads.first.unread, isTrue);
        expect(threads.first.latest.uid, 10);
        expect(threads.first.key, 'thread-7');
      },
    );

    test('제목만 같은 메일·id가 없는 메일은 묶지 않는다', () {
      final threads = groupMailThreads([
        const MailSummary(
          uid: 2,
          subject: '안녕',
          from: MailAddress(address: 'a@b'),
        ),
        const MailSummary(
          uid: 1,
          subject: '안녕',
          from: MailAddress(address: 'a@b'),
        ),
      ]);
      expect(threads.length, 2);
    });
  });

  testWidgets('목록 — 답장끼리 한 줄(수와 펼치기), 펼치면 지난 메일, 묶기를 끄면 모두 따로', (tester) async {
    final h = _Harness();
    await _pumpScreen(tester, h);
    expect(find.byKey(const ValueKey('mail-item-9')), findsOneWidget);
    expect(find.byKey(const ValueKey('mail-item-8')), findsNothing);
    expect(find.byKey(const ValueKey('mail-item-7')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('mail-thread-count-9')),
        matching: find.text('2'),
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('mail-thread-toggle-9')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mail-item-8')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('mail-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mail-menu-threads')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mail-thread-count-9')), findsNothing);
    expect(find.byKey(const ValueKey('mail-item-8')), findsOneWidget);
    expect(
      (await SharedPreferences.getInstance()).getBool(kMailThreadedPrefsKey),
      isFalse,
    );
    // 알림(토스트)이 사라질 때까지.
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('여러 통 고르기 — 길게 눌러 시작, 대화는 통째로, 읽음·옮기기·지우기를 한꺼번에', (tester) async {
    final h = _Harness();
    await _pumpScreen(tester, h);
    await tester.longPress(find.byKey(const ValueKey('mail-item-9')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mail-picking-bar')), findsOneWidget);
    expect(find.text('2통 고름'), findsOneWidget); // 대화(9·8)를 통째로
    await tester.tap(find.byKey(const ValueKey('mail-item-7')));
    await tester.pumpAndSettle();
    expect(find.text('3통 고름'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('mail-bulk-seen')));
    await tester.pumpAndSettle();
    var body = h.lastBody('POST', '/api/mail/flags');
    expect(body['uids'], [9, 8, 7]);
    expect(body['seen'], true);
    expect(find.byKey(const ValueKey('mail-picking-bar')), findsNothing);

    // [선택] 단추 → 하나 고르고 옮기기
    await tester.tap(find.byKey(const ValueKey('mail-select')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mail-pick-7')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mail-bulk-move')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mail-bulk-move-News')));
    await tester.pumpAndSettle();
    body = h.lastBody('POST', '/api/mail/move');
    expect(
      [body['uids'], body['to'], body['folder']],
      [
        [7],
        'News',
        'INBOX',
      ],
    );

    // 모두 고르기 → 지우기
    await tester.tap(find.byKey(const ValueKey('mail-select')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mail-pick-all')));
    await tester.pumpAndSettle();
    expect(find.text('3통 고름'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('mail-bulk-delete')));
    await tester.pumpAndSettle();
    expect(h.lastBody('POST', '/api/mail/delete')['uids'], [9, 8, 7]);
    expect(find.text('3통을 휴지통으로 옮겼습니다.'), findsOneWidget);
    // 알림(토스트)이 사라질 때까지.
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('폴더 — 만들기, 사람이 만든 폴더의 이름 바꾸기(열어 둔 폴더면 새 경로로)·지우기', (
    tester,
  ) async {
    final h = _Harness();
    h.routes['POST /api/mail/folders'] = (r) {
      final name = (jsonDecode(r.body) as Map)['name'] as String;
      h.folders = _folderRows(custom: ['News', name]);
      return _json({'path': name, 'folders': h.folders});
    };
    h.routes['POST /api/mail/folders/rename'] = (r) {
      final name = (jsonDecode(r.body) as Map)['name'] as String;
      h.folders = _folderRows(custom: [name]);
      return _json({'path': name, 'folders': h.folders});
    };
    h.routes['POST /api/mail/folders/delete'] = (_) {
      h.folders = _folderRows(custom: []);
      return _json({'folders': h.folders});
    };
    await _pumpScreen(tester, h);
    // 기본 폴더에는 ⋮ 메뉴가 없다.
    expect(find.byKey(const ValueKey('mail-folder-menu-INBOX')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('mail-folder-new')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('mail-folder-name')),
      ' 거래처 ',
    );
    await tester.tap(find.byKey(const ValueKey('mail-folder-name-ok')));
    await tester.pumpAndSettle();
    expect(h.lastBody('POST', '/api/mail/folders')['name'], '거래처');
    expect(find.byKey(const ValueKey('mail-folder-거래처')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('mail-folder-News')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mail-folder-menu-News')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mail-folder-rename')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('mail-folder-name')),
      '소식',
    );
    await tester.tap(find.byKey(const ValueKey('mail-folder-name-ok')));
    await tester.pumpAndSettle();
    expect(h.lastBody('POST', '/api/mail/folders/rename'), {
      'account': 'A1',
      'path': 'News',
      'name': '소식',
    });
    expect(find.text('메일 · 소식'), findsOneWidget); // 열어 둔 폴더가 새 경로로

    await tester.tap(find.byKey(const ValueKey('mail-folder-menu-소식')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mail-folder-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mail-folder-delete-confirm')));
    await tester.pumpAndSettle();
    expect(h.lastBody('POST', '/api/mail/folders/delete')['path'], '소식');
    expect(find.text('메일 · 받은편지함'), findsOneWidget);
    // 알림(토스트)이 사라질 때까지.
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('스팸편지함 — 보낸 쪽 확인 경고와 "스팸 아님"(받은편지함으로)', (tester) async {
    final h = _Harness();
    await _pumpScreen(tester, h);
    await tester.tap(find.byKey(const ValueKey('mail-folder-Junk')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mail-item-4')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mail-auth-banner')), findsOneWidget);
    expect(find.textContaining('SPF 실패'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('mail-not-spam')));
    await tester.pumpAndSettle();
    expect(h.lastBody('POST', '/api/mail/move'), {
      'account': 'A1',
      'folder': 'Junk',
      'uids': [4],
      'to': 'INBOX',
    });
    // 알림(토스트)이 사라질 때까지.
    await tester.pump(const Duration(seconds: 5));
  });

  Future<void> openCompose(
    WidgetTester tester,
    _Harness h,
    MailDraft draft,
  ) async {
    tester.view.physicalSize = const Size(900, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showMailCompose(
              context,
              session: h.session,
              api: h.session.mailApi,
              draft: draft,
              accounts: [MailAccount.fromJson(_acc('A1', 'me@corp.kr'))!],
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  RichTextEditingController bodyController(WidgetTester tester) =>
      tester
              .widget<TextField>(
                find.byKey(const ValueKey('mail-compose-body')),
              )
              .controller!
          as RichTextEditingController;

  testWidgets('서식 있는 쓰기 — 도구모음이 있고, 보낼 때 본문 서식 구간이 실린다(서식이 없으면 안 실림)', (
    tester,
  ) async {
    final h = _Harness();
    h.routes['POST /api/mail/send'] = (_) =>
        _json({'ok': true, 'savedToSent': true}, status: 201);
    await openCompose(tester, h, const MailDraft());
    expect(find.byKey(const ValueKey('mail-compose-toolbar')), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('mail-compose-to')),
      'a@b.com',
    );
    await tester.enterText(
      find.byKey(const ValueKey('mail-compose-subject')),
      '제목',
    );
    await tester.enterText(
      find.byKey(const ValueKey('mail-compose-body')),
      '굵은 글 보통',
    );
    final c = bodyController(tester);
    c.selection = const TextSelection(baseOffset: 0, extentOffset: 4);
    c.toggle(Fmt.bold);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('mail-compose-send')));
    await tester.pumpAndSettle();
    final body = h.lastBody('POST', '/api/mail/send');
    expect(body['text'], '굵은 글 보통');
    expect(body['format'], [
      {'s': 0, 'e': 4, 'f': Fmt.bold},
    ]);
    // 알림(토스트)이 사라질 때까지.
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('서식 있는 임시 저장본 — 이어 쓰면 서식을 되살리고, 다시 저장할 때 서식을 싣는다', (
    tester,
  ) async {
    final h = _Harness();
    h.routes['POST /api/mail/drafts'] = (_) =>
        _json({'folder': 'Drafts', 'uid': 12}, status: 201);
    await openCompose(
      tester,
      h,
      const MailDraft(
        to: [MailAddress(address: 'x@y.com')],
        subject: '초안',
        text: '중요한 안내',
        format: [TextFormatRun(0, 2, Fmt.italic)],
        saved: (folder: 'Drafts', uid: 11),
        signatureSlot: MailSignatureSlot.none,
      ),
    );
    expect(textFormatToJson(bodyController(tester).snapshot().format), [
      {'s': 0, 'e': 2, 'f': Fmt.italic},
    ]);
    await tester.tap(find.byKey(const ValueKey('mail-compose-save-draft')));
    await tester.pumpAndSettle();
    final body = h.lastBody('POST', '/api/mail/drafts');
    expect(body['format'], [
      {'s': 0, 'e': 2, 'f': Fmt.italic},
    ]);
    expect(body['draft'], {'folder': 'Drafts', 'uid': 11});
    // 알림(토스트)이 사라질 때까지.
    await tester.pump(const Duration(seconds: 5));
  });

  test('읽기 모양 — 서식 구간·보낸 쪽 확인 결과, 폴더의 깊이·바꿀 수 있는지', () {
    final m = MailMessage.fromJson({
      ..._detail(1, auth: {'verdict': 'warn', 'reason': null}),
      'format': [
        {'s': 0, 'e': 1, 'f': 1},
      ],
    });
    expect(m.authVerdict, 'warn');
    expect(m.format!.single.flags, 1);
    expect(MailMessage.fromJson(_detail(2)).authVerdict, isNull);
    final f = MailFolder.fromJson({
      'path': 'A/B',
      'name': 'B',
      'depth': 1,
      'editable': true,
    });
    expect([f.depth, f.editable], [1, true]);
    expect(MailFolder.fromJson({'path': 'INBOX'}).editable, isFalse);
  });

  testWidgets('관리자 웹메일 칸 — 스팸 거르기 켜고 끄기, DKIM 레코드·DNS 확인·켜기', (tester) async {
    final h = _Harness();
    Map<String, dynamic> view({bool spam = true, bool dkim = false}) => {
      'local': {
        'enabled': true,
        'domains': 'corp.kr',
        'port': 25,
        'maxMessageMb': 25,
        'quotaMb': 2048,
        'status': {
          'listening': true,
          'port': 25,
          'received': 10,
          'rejected': 2,
          'junked': 3,
        },
        'hints': [],
        'outboundReady': true,
        'spamFilter': spam,
        'dkim': {
          'enabled': dkim,
          'selector': 'tangotalk',
          'records': [
            {
              'domain': 'corp.kr',
              'name': 'tangotalk._domainkey.corp.kr',
              'value': 'v=DKIM1; k=rsa; p=PUB',
            },
          ],
        },
      },
      'oauth': {
        'redirectUri': null,
        'google': {'enabled': false},
        'microsoft': {'enabled': false},
      },
    };
    h.routes['GET /api/admin/webmail'] = (_) => _json(view());
    h.routes['PATCH /api/admin/webmail'] = (r) {
      final local = (jsonDecode(r.body) as Map)['local'] as Map;
      return _json(
        view(
          spam: local['spamFilter'] ?? true,
          dkim: local['dkimEnabled'] ?? false,
        ),
      );
    };
    h.routes['POST /api/admin/webmail/dkim-check'] = (_) => _json({
      'results': [
        {'domain': 'corp.kr', 'ok': false, 'found': null},
      ],
    });
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: AdminWebmailSection(session: h.session),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('스팸 3통'), findsOneWidget);
    expect(find.text('v=DKIM1; k=rsa; p=PUB'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('admin-webmail-spam')));
    await tester.pumpAndSettle();
    expect(
      (h.lastBody('PATCH', '/api/admin/webmail')['local'] as Map)['spamFilter'],
      false,
    );

    await tester.tap(find.byKey(const ValueKey('admin-webmail-dkim-check')));
    await tester.pumpAndSettle();
    expect(find.textContaining('DNS에서 찾지 못했습니다'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('admin-webmail-dkim')));
    await tester.pumpAndSettle();
    expect(
      (h.lastBody('PATCH', '/api/admin/webmail')['local']
          as Map)['dkimEnabled'],
      true,
    );
    // 알림(토스트)이 사라질 때까지.
    await tester.pump(const Duration(seconds: 5));
  });
}
