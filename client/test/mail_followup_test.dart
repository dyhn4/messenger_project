// 웹메일 후속(앱) — 계정 여러 개(바꾸기·기본 계정), HTML 메일 서식 보기(그림 가리기·그림 보기·늘 보기·글자로 보기·링크 확인), 서명
// (새 메일·답장·계정 바꾸기), 임시 저장(저장·닫을 때 저장·이어 쓰기·보내면 저장본 지움), 받는 사람 자동 완성, 받는 규칙·서명 창,
// OAuth 연결(브라우저 → 결과 묻기), 대화방으로 보내기 화면, 관리자 웹메일 칸, 새 메일 소켓(계정별 수). 서버는 가짜 HTTP.
import 'dart:convert';
import 'dart:typed_data';

import 'package:client/models/mail.dart';
import 'package:client/screens/admin_webmail_section.dart';
import 'package:client/screens/mail/mail_account_dialog.dart';
import 'package:client/screens/mail/mail_compose.dart';
import 'package:client/screens/mail/mail_rich_view.dart';
import 'package:client/screens/mail/mail_screen.dart';
import 'package:client/screens/mail/mail_share.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _json(Object? body, {int status = 200}) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

Map<String, dynamic> _acc(
  String id,
  String email, {
  String signature = '',
  bool onNew = true,
  bool onReply = true,
  String authType = 'password',
  List<String> trusted = const [],
}) => {
  'id': id,
  'email': email,
  'displayName': null,
  'provider': authType == 'local' ? 'local' : 'naver',
  'providerLabel': authType == 'local' ? '회사 메일함' : '네이버 메일',
  'authType': authType,
  'imap': authType == 'local'
      ? null
      : {'host': 'imap.naver.com', 'port': 993, 'security': 'ssl'},
  'smtp': authType == 'local'
      ? null
      : {'host': 'smtp.naver.com', 'port': 465, 'security': 'ssl'},
  'username': email,
  'notify': true,
  'signature': signature,
  'signatureOnNew': onNew,
  'signatureOnReply': onReply,
  'trustedSenders': trusted,
  'lastError': null,
};

final _folders = [
  {
    'path': 'INBOX',
    'name': '받은편지함',
    'specialUse': r'\Inbox',
    'unseen': 1,
    'total': 2,
  },
  {'path': 'Drafts', 'name': '임시보관함', 'specialUse': r'\Drafts'},
  {'path': 'Sent', 'name': '보낸편지함', 'specialUse': r'\Sent'},
  {'path': 'News', 'name': 'News'},
];

Map<String, dynamic> _summary(int uid, String subject, {bool draft = false}) =>
    {
      'uid': uid,
      'subject': subject,
      'from': {'name': '뉴스', 'address': 'news@news.example'},
      'to': [
        {'name': '', 'address': 'me@corp.kr'},
      ],
      'date': DateTime(2026, 10, 17, 9, 5).millisecondsSinceEpoch,
      'seen': false,
      'flagged': false,
      'answered': false,
      'draft': draft,
      'hasAttachments': false,
    };

/// HTML 메일 — 제목·굵은 글·링크·목록·표·바깥 그림·본문 그림(cid 1).
Map<String, dynamic> _richDetail(int uid) => {
  'uid': uid,
  'subject': '소식지',
  'from': {'name': '뉴스', 'address': 'news@news.example'},
  'to': [
    {'name': '', 'address': 'me@corp.kr'},
  ],
  'cc': [],
  'replyTo': [],
  'date': DateTime(2026, 10, 17, 9, 5).millisecondsSinceEpoch,
  'text': '안녕하세요 글자 본문',
  'truncated': false,
  'html': true,
  'rich': {
    'doc': {
      'b': 'div',
      'c': [
        {
          'b': 'h1',
          'c': [
            {'x': '이달의 소식'},
          ],
        },
        {
          'b': 'p',
          'c': [
            {'x': '안녕 '},
            {
              'x': '굵게',
              's': {'b': 1},
            },
            {'x': ' '},
            {'x': '자세히', 'h': 'https://news.example/a'},
            {'x': ' '},
            {'x': '답장', 'h': 'mailto:reply@news.example?subject=hi'},
          ],
        },
        {
          'b': 'ul',
          'c': [
            {
              'b': 'li',
              'c': [
                {'x': '하나'},
              ],
            },
          ],
        },
        {
          'b': 'table',
          'c': [
            {
              'b': 'tr',
              'c': [
                {
                  'b': 'td',
                  'wp': 50,
                  'c': [
                    {'x': '왼쪽'},
                  ],
                },
                {
                  'b': 'td',
                  'wp': 50,
                  'c': [
                    {'x': '오른쪽'},
                  ],
                },
              ],
            },
          ],
        },
        {
          'b': 'img',
          'src': {'url': 'https://news.example/banner.png'},
          'alt': '배너',
          'w': 300,
        },
        {
          'b': 'img',
          'src': {'cid': 1},
          'alt': '로고',
        },
      ],
    },
    'remoteImages': 1,
    'truncated': false,
  },
  'messageId': '<n$uid@news.example>',
  'references': [],
  'attachments': [
    {
      'index': 0,
      'fileName': '안내.pdf',
      'contentType': 'application/pdf',
      'size': 1024,
    },
  ],
  'flagged': false,
  'draft': false,
};

Map<String, dynamic> _draftDetail(int uid) => {
  'uid': uid,
  'subject': '초안 제목',
  'from': {'name': '', 'address': 'me@corp.kr'},
  'to': [
    {'name': '', 'address': 'x@y.com'},
  ],
  'cc': [],
  'bcc': [
    {'name': '', 'address': 'hidden@y.com'},
  ],
  'replyTo': [],
  'date': DateTime(2026, 10, 17, 9, 5).millisecondsSinceEpoch,
  'text': '쓰던 글\n\n-- \n나 드림',
  'truncated': false,
  'html': false,
  'rich': null,
  'messageId': '<d$uid@corp.kr>',
  'references': [],
  'attachments': [
    {
      'index': 0,
      'fileName': '보고서.pdf',
      'contentType': 'application/pdf',
      'size': 2048,
    },
  ],
  'flagged': false,
  'draft': true,
};

// 1x1 PNG
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII=',
);

/// 기기 알림을 실제로 띄우지 않고 남겨 두기만.
class _RecordingNotifications extends NotificationService {
  final mails = <String>[];

  @override
  Future<void> showMailNotification({
    required String title,
    required String body,
  }) async => mails.add(title);
}

class _Harness {
  final requests = <http.Request>[];
  final routes = <String, http.Response Function(http.Request)>{};
  late final Session session;
  _Harness({
    List<Map<String, dynamic>>? accounts,
    NotificationService? notifications,
  }) {
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
    final list = accounts ?? [_acc('A1', 'me@corp.kr')];
    routes['GET /api/mail/presets'] = (_) => _json([
      {
        'key': 'gmail',
        'label': 'Gmail',
        'imap': {'host': 'imap.gmail.com', 'port': 993, 'security': 'ssl'},
        'smtp': {'host': 'smtp.gmail.com', 'port': 465, 'security': 'ssl'},
        'hint': '앱 비밀번호를 넣으세요.',
        'oauth': 'google',
      },
    ]);
    routes['GET /api/mail/accounts'] = (_) =>
        _json({'accounts': list, 'max': 5});
    routes['GET /api/mail/status'] = (_) =>
        _json({'connected': true, 'unseen': 1, 'accounts': []});
    routes['GET /api/mail/folders'] = (_) => _json(_folders);
    routes['GET /api/mail/messages'] = (r) {
      final folder = r.url.queryParameters['folder'];
      if (folder == 'Drafts') {
        return _json({
          'messages': [_summary(9, '초안 제목', draft: true)],
          'nextBefore': null,
        });
      }
      return _json({
        'messages': [_summary(5, '소식지')],
        'nextBefore': null,
      });
    };
    routes['GET /api/mail/message'] = (r) {
      final uid = int.parse(r.url.queryParameters['uid']!);
      return _json(uid == 9 ? _draftDetail(uid) : _richDetail(uid));
    };
    routes['GET /api/mail/contacts'] = (_) => _json([]);
  }

  List<http.Request> called(String method, String path) =>
      requests.where((r) => r.method == method && r.url.path == path).toList();
  Map<String, dynamic> lastBody(String method, String path) =>
      jsonDecode(called(method, path).last.body) as Map<String, dynamic>;
}

Future<void> _pumpScreen(
  WidgetTester tester,
  _Harness h, {
  double width = 1400,
}) async {
  tester.view.physicalSize = Size(width, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: MailScreen(session: h.session, api: h.session.mailApi),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _openCompose(
  WidgetTester tester,
  _Harness h, {
  MailDraft draft = const MailDraft(),
  List<MailAccount> accounts = const [],
}) async {
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
            draft: draft,
            accounts: accounts,
          ),
          child: const Text('쓰기'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('쓰기'));
  await tester.pumpAndSettle();
}

String _fieldText(WidgetTester tester, String key) =>
    tester.widget<TextField>(find.byKey(ValueKey(key))).controller!.text;

void main() {
  group('모양·도우미', () {
    test('계정 — 회사 메일함·OAuth·그림 허용', () {
      final local = MailAccount.fromJson(
        _acc('L', 'bob@corp.test', authType: 'local'),
      )!;
      expect(local.isLocal, isTrue);
      expect(local.imap, isNull);
      final a = MailAccount.fromJson(
        _acc('A', 'me@x.kr', trusted: ['@news.example', 'boss@x.kr']),
      )!;
      expect(a.trusts('Promo@News.Example'), isTrue);
      expect(a.trusts('boss@x.kr'), isTrue);
      expect(a.trusts('other@x.kr'), isFalse);
    });

    test('서명 — 새 메일은 끝, 답장은 인용 앞, 계정을 바꾸면 바꿔 끼움, 이미 있으면 그대로', () {
      expect(
        withSignature('', '홍길동 드림', MailSignatureSlot.fresh),
        '\n\n-- \n홍길동 드림',
      );
      expect(
        withSignature('\n\n> 인용', '홍', MailSignatureSlot.reply),
        '\n\n-- \n홍\n\n> 인용',
      );
      expect(withSignature('본문', '  ', MailSignatureSlot.fresh), '본문');
      expect(withSignature('본문', '홍', MailSignatureSlot.none), '본문');
      final once = withSignature('본문', '홍', MailSignatureSlot.fresh);
      expect(withSignature(once, '홍', MailSignatureSlot.fresh), once);
      expect(
        swapSignature(once, '홍', '김', MailSignatureSlot.fresh),
        '본문\n\n-- \n김',
      );
      expect(swapSignature(once, '홍', '', MailSignatureSlot.fresh), '본문');
      expect(
        swapSignature('본문', '', '김', MailSignatureSlot.fresh),
        '본문\n\n-- \n김',
      );
    });

    test('임시 저장본 이어 쓰기·대화방 글·규칙 모양·주소 자동 완성 도우미', () {
      final m = MailMessage.fromJson(_draftDetail(9));
      final d = draftFromSaved(m, folder: 'Drafts', accountId: 'A1');
      expect(d.saved, (folder: 'Drafts', uid: 9));
      expect(d.bcc.single.address, 'hidden@y.com');
      expect(d.savedAttachments.single.fileName, '보고서.pdf');
      expect(d.signatureSlot, MailSignatureSlot.none);
      final rich = MailMessage.fromJson(_richDetail(5));
      expect(rich.remoteImages, 1);
      expect(rich.rich!['b'], 'div');
      final share = mailShareText(rich);
      expect(share, startsWith('[메일] 소식지\n보낸 사람: "뉴스" <news@news.example>'));
      expect(share, contains('안녕하세요 글자 본문'));
      final rule = MailRule.fromJson({
        'id': 'R1',
        'name': '뉴스',
        'enabled': true,
        'match': 'any',
        'conditions': [
          {'field': 'from', 'op': 'contains', 'value': 'news'},
        ],
        'actions': {'moveTo': 'News', 'markSeen': true},
        'stop': true,
      });
      expect(rule.toJson(), {
        'name': '뉴스',
        'enabled': true,
        'match': 'any',
        'conditions': [
          {'field': 'from', 'op': 'contains', 'value': 'news'},
        ],
        'actions': {
          'moveTo': 'News',
          'markSeen': true,
          'flag': false,
          'skipNotify': false,
        },
        'stop': true,
      });
      expect(lastAddressToken('a@x.kr, "김" <k@x.kr>; ki'), 'ki');
      expect(
        replaceLastAddress('a@x.kr, ki', '"김" <kim@x.kr>'),
        'a@x.kr, "김" <kim@x.kr>, ',
      );
      expect(replaceLastAddress('ki', 'kim@x.kr'), 'kim@x.kr, ');
    });
  });

  testWidgets('서식 보기 — 제목·굵은 글·목록·표, 바깥 그림은 가리고 본문 그림은 받음, 링크는 콜백', (
    tester,
  ) async {
    final loaded = <String>[];
    final links = <String>[];
    Widget view(bool remote) => MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: MailRichView(
            doc: (_richDetail(5)['rich'] as Map)['doc'] as Map<String, dynamic>,
            showRemoteImages: remote,
            cidPath: (i) => 'cid-$i',
            remotePath: (u) => 'remote-$u',
            loadBytes: (path) async {
              loaded.add(path);
              return Uint8List.fromList(_png);
            },
            onLink: links.add,
          ),
        ),
      ),
    );
    await tester.pumpWidget(view(false));
    await tester.pumpAndSettle();
    expect(find.text('이달의 소식'), findsOneWidget);
    expect(find.textContaining('굵게', findRichText: true), findsWidgets);
    expect(find.text('왼쪽'), findsOneWidget);
    expect(find.text('•'), findsOneWidget);
    expect(find.text('배너'), findsOneWidget, reason: '바깥 그림은 대체 글만');
    expect(loaded, ['cid-1']);
    // 링크 누르기.
    final rich = tester
        .widgetList<RichText>(find.byType(RichText))
        .firstWhere((r) => r.text.toPlainText().contains('자세히'));
    void tapSpan(String text) {
      (rich.text as TextSpan).visitChildren((span) {
        if (span is TextSpan && span.text == text) {
          (span.recognizer as dynamic).onTap();
          return false;
        }
        return true;
      });
    }

    tapSpan('자세히');
    expect(links, ['https://news.example/a']);
    // 그림 보기.
    await tester.pumpWidget(view(true));
    await tester.pumpAndSettle();
    expect(loaded, contains('remote-https://news.example/banner.png'));
    expect(find.text('배너'), findsNothing);
  });

  testWidgets('계정 여러 개 — 폴더 칸 위에서 바꾸면 그 계정의 폴더·목록, 기본 계정으로', (tester) async {
    final h = _Harness(
      accounts: [
        _acc('A1', 'me@corp.kr'),
        _acc('A2', 'me@gmail.com'),
        _acc('L1', 'me@corp.test', authType: 'local'),
      ],
    );
    h.routes['POST /api/mail/accounts/order'] = (r) => _json({
      'accounts': [
        _acc('A2', 'me@gmail.com'),
        _acc('A1', 'me@corp.kr'),
        _acc('L1', 'me@corp.test', authType: 'local'),
      ],
    });
    await _pumpScreen(tester, h);
    expect(
      h.called('GET', '/api/mail/folders').last.url.queryParameters['account'],
      'A1',
    );
    await tester.tap(find.byKey(const ValueKey('mail-account-switch')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mail-account-add')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('mail-account-me@gmail.com')));
    await tester.pumpAndSettle();
    expect(
      h.called('GET', '/api/mail/messages').last.url.queryParameters['account'],
      'A2',
    );
    await tester.tap(find.byKey(const ValueKey('mail-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mail-menu-default')));
    await tester.pumpAndSettle();
    expect(h.lastBody('POST', '/api/mail/accounts/order'), {
      'ids': ['A2', 'A1', 'L1'],
    });
    // 회사 메일함으로 바꾸면 "연결 끊기"·"계정 바꾸기"가 없다.
    await tester.tap(find.byKey(const ValueKey('mail-account-switch')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mail-account-me@corp.test')));
    await tester.pumpAndSettle();
    expect(find.text('회사 메일함'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('mail-menu')));
    await tester.pumpAndSettle();
    expect(find.text('연결 끊기'), findsNothing);
    expect(find.text('계정 바꾸기'), findsNothing);
    expect(find.byKey(const ValueKey('mail-menu-rules')), findsOneWidget);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
  });

  testWidgets('HTML 메일 읽기 — 그림 가리기·그림 보기·늘 보기·글자로 보기·링크는 묻고 열기', (
    tester,
  ) async {
    final h = _Harness();
    final opened = <Uri>[];
    final prevOpen = mailOpenLink;
    mailOpenLink = (uri) async {
      opened.add(uri);
      return true;
    };
    addTearDown(() => mailOpenLink = prevOpen);
    h.routes['GET /api/mail/inline'] = (_) =>
        http.Response.bytes(_png, 200, headers: {'content-type': 'image/png'});
    h.routes['GET /api/mail/remote-image'] = (_) =>
        http.Response.bytes(_png, 200, headers: {'content-type': 'image/png'});
    h.routes['POST /api/mail/accounts/A1/trusted'] = (_) => _json({
      'account': _acc('A1', 'me@corp.kr', trusted: ['news@news.example']),
    });
    await _pumpScreen(tester, h);
    await tester.tap(find.byKey(const ValueKey('mail-item-5')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mail-rich-view')), findsOneWidget);
    expect(find.byKey(const ValueKey('mail-images-banner')), findsOneWidget);
    expect(h.called('GET', '/api/mail/remote-image'), isEmpty);
    expect(h.called('GET', '/api/mail/inline').single.url.queryParameters, {
      'account': 'A1',
      'folder': 'INBOX',
      'uid': '5',
      'index': '1',
    });
    await tester.tap(find.byKey(const ValueKey('mail-show-images')));
    await tester.pumpAndSettle();
    expect(
      h
          .called('GET', '/api/mail/remote-image')
          .single
          .url
          .queryParameters['url'],
      'https://news.example/banner.png',
    );
    expect(find.byKey(const ValueKey('mail-images-banner')), findsNothing);
    // 링크 — 실제 주소를 보이고 물은 뒤 연다.
    final rich = tester
        .widgetList<RichText>(find.byType(RichText))
        .firstWhere((r) => r.text.toPlainText().contains('자세히'));
    (rich.text as TextSpan).visitChildren((span) {
      if (span is TextSpan && span.text == '자세히') {
        (span.recognizer as dynamic).onTap();
        return false;
      }
      return true;
    });
    await tester.pumpAndSettle();
    expect(find.text('https://news.example/a'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('mail-link-open')));
    await tester.pumpAndSettle();
    expect(opened.single.toString(), 'https://news.example/a');
    // 글자로 보기.
    await tester.tap(find.byKey(const ValueKey('mail-view-toggle')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mail-rich-view')), findsNothing);
    expect(find.text('안녕하세요 글자 본문'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('mail-view-toggle')));
    await tester.pumpAndSettle();
    // 다른 메일을 열었다가 돌아오면 다시 가린다 — "늘 보기"를 누르면 계정에 남는다.
    await tester.tap(find.byKey(const ValueKey('mail-folder-INBOX')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mail-item-5')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mail-trust-sender')));
    await tester.pumpAndSettle();
    expect(h.lastBody('POST', '/api/mail/accounts/A1/trusted'), {
      'sender': 'news@news.example',
      'add': true,
    });
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('쓰기 — 서명이 저절로, 계정을 바꾸면 그 계정 서명, 보내는 계정이 실림', (tester) async {
    final h = _Harness();
    h.routes['POST /api/mail/send'] = (_) =>
        _json({'ok': true, 'savedToSent': true}, status: 201);
    final accounts = [
      MailAccount.fromJson(_acc('A1', 'me@corp.kr', signature: '김 드림'))!,
      MailAccount.fromJson(
        _acc('A2', 'me@gmail.com', signature: 'Kim', onNew: true),
      )!,
    ];
    await _openCompose(
      tester,
      h,
      draft: const MailDraft(accountId: 'A1'),
      accounts: accounts,
    );
    expect(_fieldText(tester, 'mail-compose-body'), '\n\n-- \n김 드림');
    await tester.tap(find.byKey(const ValueKey('mail-compose-from')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('me@gmail.com').last);
    await tester.pumpAndSettle();
    expect(_fieldText(tester, 'mail-compose-body'), '\n\n-- \nKim');
    await tester.enterText(
      find.byKey(const ValueKey('mail-compose-to')),
      'a@x.kr',
    );
    await tester.enterText(
      find.byKey(const ValueKey('mail-compose-subject')),
      '안녕',
    );
    await tester.tap(find.byKey(const ValueKey('mail-compose-send')));
    await tester.pumpAndSettle();
    final sent = h.lastBody('POST', '/api/mail/send');
    expect(sent['account'], 'A2');
    expect(sent['text'], '\n\n-- \nKim');
  });

  testWidgets('쓰기 — 답장은 인용 앞에 서명(답장에 넣기를 끄면 없음)', (tester) async {
    final h = _Harness();
    final m = MailMessage.fromJson(_richDetail(5));
    final reply = draftFrom(
      m,
      MailReplyKind.reply,
      folder: 'INBOX',
      myEmail: 'me@corp.kr',
      accountId: 'A1',
    );
    await _openCompose(
      tester,
      h,
      draft: reply,
      accounts: [
        MailAccount.fromJson(_acc('A1', 'me@corp.kr', signature: '김 드림'))!,
      ],
    );
    expect(
      _fieldText(tester, 'mail-compose-body'),
      startsWith('\n\n-- \n김 드림\n\n2026. 10. 17.'),
    );
    await tester.tap(find.byTooltip('닫기'));
    await tester.pumpAndSettle();
    final h2 = _Harness();
    await _openCompose(
      tester,
      h2,
      draft: reply,
      accounts: [
        MailAccount.fromJson(
          _acc('A1', 'me@corp.kr', signature: '김 드림', onReply: false),
        )!,
      ],
    );
    expect(
      _fieldText(tester, 'mail-compose-body'),
      startsWith('\n\n2026. 10. 17.'),
    );
  });

  testWidgets('임시 저장 — 단추로 저장하고, 다시 저장하면 앞 저장본을 바꾸고, 닫을 때 저장', (tester) async {
    final h = _Harness();
    var n = 0;
    h.routes['POST /api/mail/drafts'] = (_) {
      n += 1;
      return _json({'folder': 'Drafts', 'uid': 100 + n}, status: 201);
    };
    await _openCompose(
      tester,
      h,
      draft: const MailDraft(accountId: 'A1'),
      accounts: [MailAccount.fromJson(_acc('A1', 'me@corp.kr'))!],
    );
    await tester.enterText(
      find.byKey(const ValueKey('mail-compose-to')),
      'x@y.com',
    );
    await tester.enterText(
      find.byKey(const ValueKey('mail-compose-subject')),
      '초안',
    );
    await tester.tap(find.byKey(const ValueKey('mail-compose-save-draft')));
    await tester.pumpAndSettle();
    expect(find.text('임시보관함에 저장했습니다.'), findsOneWidget);
    expect(h.lastBody('POST', '/api/mail/drafts'), {
      'account': 'A1',
      'to': ['x@y.com'],
      'cc': [],
      'bcc': [],
      'subject': '초안',
      'text': '',
      'attachments': [],
    });
    // 바꾸지 않고 닫으면 묻지 않는다.
    await tester.enterText(
      find.byKey(const ValueKey('mail-compose-body')),
      '더 씀',
    );
    await tester.tap(find.byTooltip('닫기'));
    await tester.pumpAndSettle();
    expect(find.text('쓰기를 그만할까요?'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('mail-compose-keep-draft')));
    await tester.pumpAndSettle();
    final second = h.lastBody('POST', '/api/mail/drafts');
    expect(second['draft'], {'folder': 'Drafts', 'uid': 101});
    expect(second['text'], '더 씀');
    expect(find.byType(MailComposeScreen), findsNothing);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('임시보관함 — 열면 "이어 쓰기", 숨은 참조·첨부를 채우고 보내면 저장본과 첨부 번호를 보냄', (
    tester,
  ) async {
    final h = _Harness();
    h.routes['POST /api/mail/send'] = (_) =>
        _json({'ok': true, 'savedToSent': true}, status: 201);
    await _pumpScreen(tester, h);
    await tester.tap(find.byKey(const ValueKey('mail-folder-Drafts')));
    await tester.pumpAndSettle();
    expect(find.text('[임시]'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('mail-item-9')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mail-reply')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('mail-resume-draft')));
    await tester.pumpAndSettle();
    expect(find.text('이어 쓰기'), findsWidgets);
    expect(_fieldText(tester, 'mail-compose-to'), 'x@y.com');
    expect(_fieldText(tester, 'mail-compose-bcc'), 'hidden@y.com');
    expect(_fieldText(tester, 'mail-compose-body'), '쓰던 글\n\n-- \n나 드림');
    expect(find.byKey(const ValueKey('mail-compose-saved-0')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('mail-compose-send')));
    await tester.pumpAndSettle();
    final sent = h.lastBody('POST', '/api/mail/send');
    expect(sent['draft'], {'folder': 'Drafts', 'uid': 9});
    expect(sent['draftAttachments'], [0]);
    expect(sent['bcc'], ['hidden@y.com']);
    expect(find.text('메일을 보냈습니다.'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('자동 완성 — 쓰는 동안 후보, 고르면 마지막 주소를 바꾸고 ", "', (tester) async {
    final h = _Harness();
    h.routes['GET /api/mail/contacts'] = (r) => _json(
      r.url.queryParameters['q'] == 'ki'
          ? [
              {'name': '김철수', 'address': 'kim@corp.kr', 'member': true},
              {'name': '', 'address': 'kiwi@fruit.com', 'member': false},
            ]
          : [],
    );
    h.routes['DELETE /api/mail/contacts'] = (_) => _json({'ok': true});
    await _openCompose(tester, h);
    await tester.enterText(
      find.byKey(const ValueKey('mail-compose-to')),
      'a@x.kr, ki',
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('mail-suggest-kim@corp.kr')),
      findsOneWidget,
    );
    // 바깥 주소는 ✕로 지운다.
    await tester.tap(find.byTooltip('자동 완성에서 지우기'));
    await tester.pumpAndSettle();
    expect(h.lastBody('DELETE', '/api/mail/contacts'), {
      'address': 'kiwi@fruit.com',
    });
    await tester.tap(find.byKey(const ValueKey('mail-suggest-kim@corp.kr')));
    await tester.pumpAndSettle();
    expect(
      _fieldText(tester, 'mail-compose-to'),
      'a@x.kr, "김철수" <kim@corp.kr>, ',
    );
  });

  testWidgets('받는 규칙·서명 창 — 규칙을 만들고 지금 적용, 서명 저장', (tester) async {
    final h = _Harness();
    final rules = <Map<String, dynamic>>[];
    h.routes['GET /api/mail/rules'] = (_) => _json({'rules': rules});
    h.routes['POST /api/mail/rules'] = (r) {
      final body = jsonDecode(r.body) as Map<String, dynamic>;
      final rule = {...body, 'id': 'R${rules.length + 1}'};
      rules.add(rule);
      return _json({'rule': rule}, status: 201);
    };
    h.routes['POST /api/mail/rules/apply'] = (_) =>
        _json({'matched': 3, 'moved': 2});
    h.routes['PATCH /api/mail/accounts/A1'] = (r) => _json({
      'account': _acc(
        'A1',
        'me@corp.kr',
        signature: (jsonDecode(r.body) as Map)['signature'] as String,
      ),
    });
    await _pumpScreen(tester, h);
    await tester.tap(find.byKey(const ValueKey('mail-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mail-menu-rules')));
    await tester.pumpAndSettle();
    expect(find.textContaining('규칙이 없습니다'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('mail-rules-add')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('mail-rule-name')), '뉴스');
    await tester.enterText(
      find.byKey(const ValueKey('mail-rule-value-0')),
      'news.example',
    );
    await tester.tap(find.byKey(const ValueKey('mail-rule-move')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('News').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mail-rule-seen')));
    await tester.tap(find.byKey(const ValueKey('mail-rule-save')));
    await tester.pumpAndSettle();
    expect(h.lastBody('POST', '/api/mail/rules'), {
      'name': '뉴스',
      'enabled': true,
      'match': 'all',
      'conditions': [
        {'field': 'from', 'op': 'contains', 'value': 'news.example'},
      ],
      'actions': {
        'moveTo': 'News',
        'markSeen': true,
        'flag': false,
        'skipNotify': false,
      },
      'stop': false,
      'account': 'A1',
    });
    expect(find.textContaining('News(으)로 옮기기'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('mail-rules-apply')));
    await tester.pumpAndSettle();
    expect(find.textContaining('3통에 규칙을 걸었습니다'), findsOneWidget);
    await tester.tap(find.text('닫기'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 5));
    // 서명.
    await tester.tap(find.byKey(const ValueKey('mail-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mail-menu-signature')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('mail-signature-text')),
      '홍길동 드림',
    );
    await tester.tap(find.byKey(const ValueKey('mail-signature-reply')));
    await tester.tap(find.byKey(const ValueKey('mail-signature-save')));
    await tester.pumpAndSettle();
    expect(h.lastBody('PATCH', '/api/mail/accounts/A1'), {
      'signature': '홍길동 드림',
      'signatureOnNew': true,
      'signatureOnReply': false,
    });
    expect(find.text('서명을 저장했습니다.'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('OAuth 연결 — Google로 로그인을 누르면 브라우저를 열고 결과를 물어 연결', (tester) async {
    final h = _Harness();
    final opened = <Uri>[];
    final prevOpen = mailOAuthOpenUrl;
    final prevPoll = mailOAuthPollInterval;
    mailOAuthOpenUrl = (uri) async {
      opened.add(uri);
      return true;
    };
    mailOAuthPollInterval = const Duration(milliseconds: 10);
    addTearDown(() {
      mailOAuthOpenUrl = prevOpen;
      mailOAuthPollInterval = prevPoll;
    });
    h.routes['POST /api/mail/oauth/start'] = (_) => _json({
      'state': 'st-1',
      'authUrl': 'https://accounts.google.com/o/oauth2/v2/auth?x=1',
    });
    var polls = 0;
    h.routes['GET /api/mail/oauth/poll'] = (_) {
      polls += 1;
      return polls < 2
          ? _json({'status': 'pending'})
          : _json({
              'status': 'done',
              'account': {
                ..._acc('A9', 'me@gmail.com'),
                'authType': 'oauth',
                'oauthProvider': 'google',
              },
            });
    };
    MailAccount? result;
    tester.view.physicalSize = const Size(900, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => result = await showMailAccountDialog(
              context,
              api: h.session.mailApi,
            ),
            child: const Text('연결'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('연결'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mail-provider')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Gmail').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mail-oauth-google')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();
    expect(h.lastBody('POST', '/api/mail/oauth/start'), {'provider': 'google'});
    expect(opened.single.host, 'accounts.google.com');
    expect(result?.email, 'me@gmail.com');
    expect(result?.isOAuth, isTrue);
  });

  testWidgets('대화방으로 보내기 화면 — 메일 요약 글과 첨부 고르기', (tester) async {
    final h = _Harness();
    tester.view.physicalSize = const Size(900, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: MailToRoomScreen(
          session: h.session,
          api: h.session.mailApi,
          account: 'A1',
          folder: 'INBOX',
          message: MailMessage.fromJson(_richDetail(5)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(_fieldText(tester, 'mail-share-text'), startsWith('[메일] 소식지'));
    final tile = tester.widget<CheckboxListTile>(
      find.byKey(const ValueKey('mail-share-attachment-0')),
    );
    expect(tile.value, isTrue);
    expect(
      tester
          .widget<CheckboxListTile>(
            find.byKey(const ValueKey('mail-share-eml')),
          )
          .value,
      isFalse,
    );
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('mail-share-send')))
          .onPressed,
      isNull,
      reason: '대화방을 고르기 전에는 못 보냄',
    );
  });

  testWidgets('관리자 웹메일 칸 — 자체 메일 서버 설정·켜기, MX 안내, OAuth 켜기', (tester) async {
    final h = _Harness();
    var view = <String, dynamic>{
      'local': {
        'enabled': false,
        'domains': '',
        'port': 25,
        'maxMessageMb': 25,
        'quotaMb': 2048,
        'status': {
          'listening': false,
          'port': null,
          'error': null,
          'received': 0,
          'rejected': 0,
        },
        'hints': [],
        'outboundReady': false,
      },
      'oauth': {
        'redirectUri': 'https://web.example/auth/sso/callback',
        'google': {'enabled': false, 'problem': null},
        'microsoft': {
          'enabled': false,
          'problem': '로그인 보안 탭에 Microsoft 테넌트 ID·클라이언트 ID·클라이언트 암호를 먼저 넣으세요.',
        },
      },
    };
    h.routes['GET /api/admin/webmail'] = (_) => _json(view);
    h.routes['PATCH /api/admin/webmail'] = (r) {
      final body = jsonDecode(r.body) as Map<String, dynamic>;
      final local = body['local'] as Map?;
      if (local != null) {
        view = {
          ...view,
          'local': {
            ...(view['local'] as Map),
            if (local['domains'] != null) 'domains': local['domains'],
            if (local['port'] != null) 'port': local['port'],
            if (local['enabled'] != null) 'enabled': local['enabled'],
            if (local['enabled'] == true)
              'status': {
                'listening': true,
                'port': 2525,
                'error': null,
                'received': 0,
                'rejected': 0,
              },
            'hints': [
              {
                'domain': 'corp.kr',
                'mx': 'corp.kr. MX 10 mail.corp.kr.',
                'note': 'MX를 넣으세요.',
              },
            ],
          },
        };
      }
      return _json(view);
    };
    tester.view.physicalSize = const Size(900, 1400);
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
    expect(find.textContaining('Microsoft 테넌트 ID'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('admin-webmail-domains')),
      'corp.kr',
    );
    await tester.enterText(
      find.byKey(const ValueKey('admin-webmail-port')),
      '2525',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('admin-webmail-save')));
    await tester.pumpAndSettle();
    expect(h.lastBody('PATCH', '/api/admin/webmail'), {
      'local': {
        'domains': 'corp.kr',
        'port': 2525,
        'maxMessageMb': 25,
        'quotaMb': 2048,
      },
    });
    expect(find.text('corp.kr. MX 10 mail.corp.kr.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('admin-webmail-local')));
    await tester.pumpAndSettle();
    expect(h.lastBody('PATCH', '/api/admin/webmail'), {
      'local': {'enabled': true},
    });
    expect(find.textContaining('2525번 포트로 받는 중'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('admin-webmail-oauth-google')));
    await tester.pumpAndSettle();
    expect(h.lastBody('PATCH', '/api/admin/webmail'), {
      'oauth': {'google': true},
    });
    await tester.pump(const Duration(seconds: 5));
  });

  test('새 메일 소켓 — 계정별 수가 오면 모든 계정의 합을 다시 받는다', () async {
    final notifications = _RecordingNotifications();
    final h = _Harness(notifications: notifications);
    h.routes['GET /api/mail/status'] = (_) =>
        _json({'connected': true, 'unseen': 7, 'accounts': []});
    h.session.handleMailNew({
      'accountId': 'A2',
      'email': 'me@gmail.com',
      'count': 1,
      'unseen': 2,
      'latest': [
        {'from': '대표', 'subject': '안녕'},
      ],
    });
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(h.session.mailUnread, 7);
    expect(notifications.mails.single, '새 메일 — 대표');
  });
}
