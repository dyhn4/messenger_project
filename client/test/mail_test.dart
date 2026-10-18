// 웹메일(앱) — 모양 읽기, 답장·전체 답장·전달 초안, 주소 나누기, 계정 연결 창, 메일 화면(폴더·목록·읽기·답장·지우기·찾기·더 보기),
// 쓰기 검사, 새 메일 소켓 알림. 서버(webmail.js)는 가짜 HTTP.
import 'dart:convert';

import 'package:client/models/mail.dart';
import 'package:client/screens/mail/mail_compose.dart';
import 'package:client/screens/mail/mail_screen.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:client/widgets/menu_entries.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _json(Object? body, {int status = 200}) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

class _RecordingNotifications extends NotificationService {
  final mails = <({String title, String body})>[];

  @override
  Future<void> showMailNotification({
    required String title,
    required String body,
  }) async => mails.add((title: title, body: body));
}

const _account = {
  'id': 'A1',
  'email': 'me@corp.kr',
  'displayName': '나',
  'provider': 'naver',
  'providerLabel': '네이버 메일',
  'imap': {'host': 'imap.naver.com', 'port': 993, 'security': 'ssl'},
  'smtp': {'host': 'smtp.naver.com', 'port': 465, 'security': 'ssl'},
  'username': 'me@corp.kr',
  'notify': true,
  'lastError': null,
};

final _presets = [
  {
    'key': 'naver',
    'label': '네이버 메일',
    'imap': {'host': 'imap.naver.com', 'port': 993, 'security': 'ssl'},
    'smtp': {'host': 'smtp.naver.com', 'port': 465, 'security': 'ssl'},
    'hint': '네이버 메일 → 환경설정에서 IMAP 사용을 켜세요.',
  },
  {
    'key': 'gmail',
    'label': 'Gmail',
    'imap': {'host': 'imap.gmail.com', 'port': 993, 'security': 'ssl'},
    'smtp': {'host': 'smtp.gmail.com', 'port': 465, 'security': 'ssl'},
    'hint': '앱 비밀번호를 넣으세요.',
  },
];

Map<String, dynamic> _summary(
  int uid,
  String subject, {
  bool seen = false,
  String from = 'kim@x.kr',
  String name = '김부장',
  bool attachments = false,
}) => {
  'uid': uid,
  'subject': subject,
  'from': {'name': name, 'address': from},
  'to': [
    {'name': '', 'address': 'me@corp.kr'},
  ],
  'date': DateTime(2026, 10, 17, 9, 5).millisecondsSinceEpoch,
  'seen': seen,
  'flagged': false,
  'answered': false,
  'hasAttachments': attachments,
};

Map<String, dynamic> _detail(int uid) => {
  'uid': uid,
  'subject': '견적서 송부',
  'from': {'name': '이대리', 'address': 'lee@x.kr'},
  'to': [
    {'name': '나', 'address': 'me@corp.kr'},
    {'name': '박과장', 'address': 'park@x.kr'},
  ],
  'cc': [
    {'name': '', 'address': 'boss@x.kr'},
  ],
  'replyTo': [],
  'date': DateTime(2026, 10, 17, 9, 5).millisecondsSinceEpoch,
  'text': '첨부 확인 바랍니다.\n\n감사합니다.',
  'truncated': false,
  'html': true,
  'messageId': '<m$uid@x.kr>',
  'references': ['<r0@x.kr>'],
  'attachments': [
    {
      'index': 0,
      'fileName': '견적.pdf',
      'contentType': 'application/pdf',
      'size': 2048,
    },
  ],
  'flagged': false,
};

class _Harness {
  final requests = <http.Request>[];
  final routes = <String, http.Response Function(http.Request)>{};
  late final Session session;
  _Harness({NotificationService? notifications}) {
    session = Session(
      notifications: notifications ?? NotificationService(),
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
    routes['GET /api/mail/presets'] = (_) => _json(_presets);
  }

  void withAccount() {
    routes['GET /api/mail/accounts'] = (_) => _json({
      'accounts': [_account],
      'max': 5,
    });
    routes['GET /api/mail/status'] = (_) =>
        _json({'connected': true, 'unseen': 2, 'accounts': []});
    routes['GET /api/mail/folders'] = (_) => _json([
      {
        'path': 'INBOX',
        'name': '받은편지함',
        'specialUse': r'\Inbox',
        'unseen': 2,
        'total': 3,
      },
      {'path': 'Sent', 'name': '보낸편지함', 'specialUse': r'\Sent'},
      {'path': 'Trash', 'name': '휴지통', 'specialUse': r'\Trash'},
      {'path': 'Work', 'name': 'Work'},
    ]);
    routes['GET /api/mail/messages'] = (r) {
      final q = r.url.queryParameters;
      if (q['q'] == '견적') {
        return _json({
          'messages': [_summary(2, '견적서 송부', attachments: true)],
          'nextBefore': null,
        });
      }
      if (q['before'] == '2') {
        return _json({
          'messages': [_summary(1, '주간 보고', seen: true)],
          'nextBefore': null,
        });
      }
      return _json({
        'messages': [
          _summary(3, '점심', from: 'park@x.kr', name: '박과장'),
          _summary(2, '견적서 송부', attachments: true),
        ],
        'nextBefore': 2,
      });
    };
    routes['GET /api/mail/message'] = (r) =>
        _json(_detail(int.parse(r.url.queryParameters['uid']!)));
  }

  List<http.Request> called(String method, String path) =>
      requests.where((r) => r.method == method && r.url.path == path).toList();
  Map<String, dynamic> lastBody(String method, String path) =>
      jsonDecode(called(method, path).last.body) as Map<String, dynamic>;
}

Future<void> _pump(
  WidgetTester tester,
  _Harness h, {
  double width = 1400,
}) async {
  tester.view.physicalSize = Size(width, 1000);
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
  group('모양·초안', () {
    final m = MailMessage.fromJson(_detail(2));

    test('읽기 모양', () {
      expect(m.from.label, '이대리');
      expect(m.cc.single.label, 'boss@x.kr');
      expect(m.wasHtml, isTrue);
      expect(m.attachments.single.fileName, '견적.pdf');
      expect(m.references, ['<r0@x.kr>']);
      final s = MailSummary.fromJson(_summary(5, '안녕', seen: true));
      expect(s.from.wire, '"김부장" <kim@x.kr>');
      expect(s.copyWith(seen: false).seen, isFalse);
      expect(
        MailFolder.fromJson({'path': 'INBOX', 'specialUse': r'\Inbox'}).isInbox,
        isTrue,
      );
    });

    test('답장 — 보낸 사람에게, Re: 한 번만, 인용·답장 머리', () {
      final d = draftFrom(
        m,
        MailReplyKind.reply,
        folder: 'INBOX',
        myEmail: 'me@corp.kr',
      );
      expect(d.to.map((a) => a.address), ['lee@x.kr']);
      expect(d.cc, isEmpty);
      expect(d.subject, 'Re: 견적서 송부');
      expect(d.inReplyTo, '<m2@x.kr>');
      expect(d.references, ['<r0@x.kr>', '<m2@x.kr>']);
      expect(d.answered, (folder: 'INBOX', uid: 2));
      expect(d.text, contains('"이대리" <lee@x.kr> 님이 작성:'));
      expect(d.text, contains('> 첨부 확인 바랍니다.\n>\n> 감사합니다.'));
      expect(prefixedSubject('RE: 견적', 'Re:'), 'RE: 견적');
      expect(prefixedSubject('답장: 견적', 'Re:'), '답장: 견적');
      expect(prefixedSubject('Fw: 자료', 'Fwd:'), 'Fw: 자료');
    });

    test('전체 답장 — 나는 빼고 받는 사람·참조를 참조로, 회신 주소가 있으면 그쪽으로', () {
      final d = draftFrom(
        m,
        MailReplyKind.replyAll,
        folder: 'INBOX',
        myEmail: 'ME@corp.kr',
      );
      expect(d.to.map((a) => a.address), ['lee@x.kr']);
      expect(d.cc.map((a) => a.address), ['park@x.kr', 'boss@x.kr']);
      final withReplyTo = MailMessage.fromJson({
        ..._detail(3),
        'replyTo': [
          {'name': '', 'address': 'noreply-reply@x.kr'},
        ],
      });
      expect(
        draftFrom(
          withReplyTo,
          MailReplyKind.reply,
          folder: 'INBOX',
          myEmail: 'me@corp.kr',
        ).to.single.address,
        'noreply-reply@x.kr',
      );
    });

    test('전달 — 받는 사람 없이, 원래 머리와 본문', () {
      final d = draftFrom(
        m,
        MailReplyKind.forward,
        folder: 'INBOX',
        myEmail: 'me@corp.kr',
      );
      expect(d.to, isEmpty);
      expect(d.subject, 'Fwd: 견적서 송부');
      expect(d.text, contains('---------- 전달된 메일 ----------'));
      expect(d.text, contains('참조: boss@x.kr'));
      expect(d.inReplyTo, isNull);
      expect(d.answered, isNull);
    });

    test('주소 나누기·검사·목록 시각·크기', () {
      expect(splitAddresses('a@x.kr, "나" <b@x.kr>;\nc@x.kr, '), [
        'a@x.kr',
        '"나" <b@x.kr>',
        'c@x.kr',
      ]);
      expect(firstBadAddress(['a@x.kr', '"나" <b@x.kr>']), isNull);
      expect(firstBadAddress(['a@x.kr', '홍길동']), '홍길동');
      final now = DateTime(2026, 10, 17, 15);
      expect(mailListTime(DateTime(2026, 10, 17, 9, 5), now), '오전 9:05');
      expect(mailListTime(DateTime(2026, 10, 17, 13, 0), now), '오후 1:00');
      expect(mailListTime(DateTime(2026, 3, 1), now), '3월 1일');
      expect(mailListTime(DateTime(2025, 3, 1), now), '2025. 3. 1.');
      expect(mailSizeText(2048), '2KB');
      expect(mailSizeText(3 * 1024 * 1024), '3.0MB');
    });
  });

  testWidgets('계정이 없으면 연결 안내 — 서비스를 고르면 안내, 직접 입력은 서버 칸, 실패하면 이유를 창에', (
    tester,
  ) async {
    final h = _Harness();
    h.routes['GET /api/mail/accounts'] = (_) =>
        _json({'accounts': [], 'max': 5});
    var attempts = 0;
    h.routes['POST /api/mail/accounts'] = (_) {
      attempts += 1;
      if (attempts == 1) {
        return _json({
          'error': '받는 메일(IMAP) — 로그인에 실패했습니다. "앱 비밀번호"를 넣어야 합니다.',
        }, status: 400);
      }
      h.withAccount();
      return _json({'account': _account}, status: 201);
    };
    await _pump(tester, h);
    await tester.tap(find.byKey(const ValueKey('mail-connect')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mail-provider-hint')), findsOneWidget);
    expect(find.byKey(const ValueKey('mail-imap-host')), findsNothing);
    await tester.enterText(
      find.byKey(const ValueKey('mail-email')),
      'me@corp.kr',
    );
    await tester.tap(find.byKey(const ValueKey('mail-account-save')));
    await tester.pumpAndSettle();
    expect(find.text('비밀번호(앱 비밀번호)를 넣으세요.'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('mail-password')), 'pw');
    await tester.tap(find.byKey(const ValueKey('mail-account-save')));
    await tester.pumpAndSettle();
    expect(find.textContaining('앱 비밀번호"를 넣어야'), findsOneWidget);
    expect(h.lastBody('POST', '/api/mail/accounts'), {
      'email': 'me@corp.kr',
      'displayName': '',
      'provider': 'naver',
      'password': 'pw',
    });
    // 직접 입력 — 서버 칸이 나온다.
    await tester.tap(find.byKey(const ValueKey('mail-provider')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('직접 입력(회사 메일 서버)').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('mail-imap-host')),
      'mail.corp.kr',
    );
    await tester.enterText(
      find.byKey(const ValueKey('mail-smtp-host')),
      'mail.corp.kr',
    );
    await tester.enterText(find.byKey(const ValueKey('mail-smtp-port')), '587');
    await tester.tap(find.byKey(const ValueKey('mail-smtp-security')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('STARTTLS').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mail-account-save')));
    await tester.pumpAndSettle();
    final body = h.lastBody('POST', '/api/mail/accounts');
    expect(body['provider'], 'custom');
    expect(body['imap'], {
      'host': 'mail.corp.kr',
      'port': 993,
      'security': 'ssl',
    });
    expect(body['smtp'], {
      'host': 'mail.corp.kr',
      'port': 587,
      'security': 'starttls',
    });
    // 연결되면 받은편지함.
    expect(find.byKey(const ValueKey('mail-item-3')), findsOneWidget);
    expect(find.textContaining('me@corp.kr을(를) 연결했습니다'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('넓은 화면 — 폴더·목록·읽기, 열면 읽음, 더 보기, 찾기', (tester) async {
    final h = _Harness();
    h.withAccount();
    await _pump(tester, h);
    expect(find.byKey(const ValueKey('mail-folder-INBOX')), findsOneWidget);
    expect(find.text('메일 · 받은편지함'), findsOneWidget);
    expect(h.session.mailUnread, 2);
    await tester.tap(find.byKey(const ValueKey('mail-item-2')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mail-reader')), findsOneWidget);
    expect(find.text('견적서 송부'), findsWidgets);
    expect(find.text('보낸 사람: "이대리" <lee@x.kr>'), findsOneWidget);
    expect(find.textContaining('HTML 메일을 글자로'), findsOneWidget);
    expect(find.byKey(const ValueKey('mail-attachment-0')), findsOneWidget);
    expect(h.session.mailUnread, 1, reason: '연 메일만큼 줄어든다');
    expect(h.called('GET', '/api/mail/message').last.url.queryParameters, {
      'account': 'A1',
      'folder': 'INBOX',
      'uid': '2',
    });
    // 더 보기.
    await tester.tap(find.byKey(const ValueKey('mail-more')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mail-item-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('mail-more')), findsNothing);
    // 찾기.
    await tester.enterText(find.byKey(const ValueKey('mail-search')), '견적');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mail-item-3')), findsNothing);
    expect(find.byKey(const ValueKey('mail-item-2')), findsOneWidget);
    // 폴더 바꾸기.
    await tester.tap(find.byKey(const ValueKey('mail-folder-Work')));
    await tester.pumpAndSettle();
    expect(
      h.called('GET', '/api/mail/messages').last.url.queryParameters['folder'],
      'Work',
    );
  });

  testWidgets('읽기 — 전체 답장을 쓰면 답장 머리와 함께 보내고, 지우면 닫힘', (tester) async {
    final h = _Harness();
    h.withAccount();
    h.routes['POST /api/mail/send'] = (_) =>
        _json({'ok': true, 'savedToSent': true}, status: 201);
    h.routes['POST /api/mail/delete'] = (_) => _json({'result': 'trash'});
    h.routes['POST /api/mail/flags'] = (_) => _json({'ok': true});
    await _pump(tester, h);
    await tester.tap(find.byKey(const ValueKey('mail-item-2')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mail-reader-flag')));
    await tester.pumpAndSettle();
    expect(h.lastBody('POST', '/api/mail/flags'), {
      'account': 'A1',
      'folder': 'INBOX',
      'uids': [2],
      'flagged': true,
    });
    await tester.tap(find.byKey(const ValueKey('mail-reply-all')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('mail-compose-to')))
          .controller!
          .text,
      '"이대리" <lee@x.kr>',
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('mail-compose-cc')))
          .controller!
          .text,
      '"박과장" <park@x.kr>, boss@x.kr',
    );
    await tester.enterText(
      find.byKey(const ValueKey('mail-compose-body')),
      '확인했습니다.',
    );
    await tester.tap(find.byKey(const ValueKey('mail-compose-send')));
    await tester.pumpAndSettle();
    final sent = h.lastBody('POST', '/api/mail/send');
    expect(sent['to'], ['"이대리" <lee@x.kr>']);
    expect(sent['cc'], ['"박과장" <park@x.kr>', 'boss@x.kr']);
    expect(sent['subject'], 'Re: 견적서 송부');
    expect(sent['text'], '확인했습니다.');
    expect(sent['inReplyTo'], '<m2@x.kr>');
    expect(sent['answered'], {'folder': 'INBOX', 'uid': 2});
    expect(sent['account'], 'A1');
    expect(find.text('메일을 보냈습니다.'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await tester.tap(find.byKey(const ValueKey('mail-delete')));
    await tester.pumpAndSettle();
    expect(h.lastBody('POST', '/api/mail/delete'), {
      'account': 'A1',
      'folder': 'INBOX',
      'uids': [2],
    });
    expect(find.byKey(const ValueKey('mail-reader')), findsNothing);
    expect(find.text('왼쪽에서 메일을 고르세요.'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('좁은 화면 — 눌러서 읽기 화면으로, 쓰기 단추는 아래', (tester) async {
    final h = _Harness();
    h.withAccount();
    await _pump(tester, h, width: 420);
    expect(find.byKey(const ValueKey('mail-folders')), findsNothing);
    expect(find.byType(FloatingActionButton), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('mail-item-3')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mail-reader')), findsOneWidget);
    expect(find.byKey(const ValueKey('mail-reader-body')), findsOneWidget);
  });

  testWidgets('쓰기 — 받는 사람이 없거나 주소가 틀리면 보내지 않음, 쓰다 닫으면 묻는다', (tester) async {
    final h = _Harness();
    tester.view.physicalSize = const Size(900, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showMailCompose(context, session: h.session),
            child: const Text('쓰기'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('쓰기'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mail-compose-send')));
    await tester.pumpAndSettle();
    expect(find.text('받는 사람을 넣으세요.'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('mail-compose-to')),
      'a@x.kr, 홍길동',
    );
    await tester.tap(find.byKey(const ValueKey('mail-compose-send')));
    await tester.pumpAndSettle();
    expect(find.text('주소가 올바르지 않습니다: 홍길동'), findsOneWidget);
    expect(h.called('POST', '/api/mail/send'), isEmpty);
    await tester.tap(find.byTooltip('닫기'));
    await tester.pumpAndSettle();
    expect(find.text('쓰기를 그만할까요?'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('mail-compose-discard')));
    await tester.pumpAndSettle();
    expect(find.byType(MailComposeScreen), findsNothing);
  });

  testWidgets('쓰기 — 주소록에서 고르면 받는 사람에 더한다(이미 있는 주소는 또 넣지 않음)', (tester) async {
    final h = _Harness();
    h.routes['GET /api/mail/directory'] = (_) => _json([
      {'userId': 'U1', 'name': '김부장', 'email': 'kim@corp.kr'},
      {'userId': 'U2', 'name': '이대리', 'email': 'lee@corp.kr'},
    ]);
    tester.view.physicalSize = const Size(900, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showMailCompose(
              context,
              session: h.session,
              draft: const MailDraft(to: [MailAddress(address: 'lee@corp.kr')]),
            ),
            child: const Text('쓰기'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('쓰기'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('주소록').first);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('mail-directory-filter')),
      '김',
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('mail-directory-lee@corp.kr')),
      findsNothing,
    );
    await tester.tap(find.byKey(const ValueKey('mail-directory-kim@corp.kr')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('mail-directory-filter')),
      '',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mail-directory-lee@corp.kr')));
    await tester.tap(find.byKey(const ValueKey('mail-directory-done')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('mail-compose-to')))
          .controller!
          .text,
      'lee@corp.kr, "김부장" <kim@corp.kr>',
    );
  });

  test('새 메일 소켓 — 배지·토스트·기기 알림(알림을 끈 창은 토스트만)', () async {
    final notifications = _RecordingNotifications();
    final session = Session(
      notifications: notifications,
      settings: AppSettings(),
    );
    final toasts = <String>[];
    final sub = session.toasts.listen(toasts.add);
    var events = 0;
    final eventSub = session.mailEvents.listen((_) => events += 1);
    session.handleMailNew({
      'count': 2,
      'unseen': 5,
      'latest': [
        {'from': '대표', 'subject': '긴급 회의'},
        {'from': '인사팀', 'subject': '연말정산'},
      ],
    });
    await Future<void>.delayed(Duration.zero);
    expect(session.mailUnread, 5);
    expect(toasts.single, '새 메일 2통 · 대표: 긴급 회의 외');
    expect(notifications.mails.single.title, '새 메일 2통');
    expect(events, 1);
    final quiet = _RecordingNotifications();
    final second = Session(
      notifications: quiet,
      settings: AppSettings(),
      suppressNotifications: true,
    );
    second.handleMailNew({
      'count': 1,
      'unseen': 1,
      'latest': [
        {'from': '대표', 'subject': '안녕'},
      ],
    });
    expect(quiet.mails, isEmpty);
    expect(second.mailUnread, 1);
    await sub.cancel();
    await eventSub.cancel();
  });

  test('메뉴에 메일 — 숫자는 받은편지함 안 읽은 수, 알림 payload', () {
    final session = Session(
      notifications: NotificationService(),
      settings: AppSettings(),
    );
    final entry = menuEntries.firstWhere((e) => e.key == 'mail');
    expect(entry.label, '메일');
    session.setMailUnread(4);
    expect(entry.badge!(session), 4);
    expect(NotificationService.mailPayload, 'mail:');
  });
}
