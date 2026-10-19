import 'dart:typed_data';

import '../l10n/tr.dart';
import '../models/mail.dart';
import 'api_client.dart';

/// 웹메일 API(server/src/webmail.js) — 사람마다 연결한 메일 계정(여럿 — 회사 메일함 포함)을 다룬다(팀과 상관없음). 요청마다
/// [account](계정 id)로 계정을 고르고, 비우면 서버가 기본(처음) 계정을 쓴다(예전 서버는 계정이 하나라 id가 없다). 메일 서버 오류는
/// 502로 오고 ApiException 글에 고칠 방법이 실린다.
class MailApi {
  final ApiClient _api;
  MailApi(this._api);

  static String _q(Map<String, String?> params) {
    final p = {...params}..removeWhere((_, v) => v == null || v.isEmpty);
    if (p.isEmpty) return '';
    return '?${p.entries.map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value!)}').join('&')}';
  }

  Future<Map<String, dynamic>> _map(
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async => (await _api.requestJson(method, path, body: body) as Map)
      .cast<String, dynamic>();

  Future<List<MailPreset>> presets() async => [
    for (final p in await _api.requestJson('GET', '/api/mail/presets') as List)
      MailPreset.fromJson((p as Map).cast<String, dynamic>()),
  ];

  /// 내 계정들(순서대로 — 처음 것이 기본). 예전 서버(이 경로가 없음 — 오류)면 계정 하나(/mail/account — [legacy]) — 그것도 안
  /// 되면 그 오류.
  Future<({List<MailAccount> accounts, bool legacy})> accountList() async {
    Map<String, dynamic> m;
    try {
      m = await _map('GET', '/api/mail/accounts');
    } catch (_) {
      final one = await account();
      return (accounts: [?one], legacy: true);
    }
    return (
      accounts: [
        for (final a in m['accounts'] as List? ?? const [])
          ?MailAccount.fromJson(a),
      ],
      legacy: false,
    );
  }

  Future<List<MailAccount>> accounts() async => (await accountList()).accounts;

  /// 기본 계정 하나(예전 서버).
  Future<MailAccount?> account() async =>
      MailAccount.fromJson((await _map('GET', '/api/mail/account'))['account']);

  /// 연결·바꾸기 — 서버가 IMAP·SMTP 로그인을 해 보고 저장한다(실패하면 ApiException에 이유). [password]가 null이면 지금 비밀번호.
  /// [accountId]가 있으면 그 계정을 바꾸고, 없으면 새 계정([legacy] — 예전 서버면 하나뿐인 계정을 바꾼다).
  Future<MailAccount> connect({
    String? accountId,
    required String email,
    String? displayName,
    required String provider,
    MailEndpoint? imap,
    MailEndpoint? smtp,
    String? username,
    String? password,
    bool legacy = false,
  }) async {
    final body = {
      'email': email,
      'displayName': ?displayName,
      'provider': provider,
      if (imap != null) 'imap': imap.toJson(),
      if (smtp != null) 'smtp': smtp.toJson(),
      'username': ?username,
      'password': ?password,
    };
    final m = legacy
        ? await _map('PUT', '/api/mail/account', body)
        : accountId == null || accountId.isEmpty
        ? await _map('POST', '/api/mail/accounts', body)
        : await _map('PUT', '/api/mail/accounts/$accountId', body);
    return MailAccount.fromJson(m['account'])!;
  }

  /// 연결 시험 없이 바꾸는 설정 — 알림·보내는 이름·서명.
  Future<MailAccount> updateAccount(
    String accountId, {
    bool? notify,
    String? signature,
    bool? signatureOnNew,
    bool? signatureOnReply,
  }) async => MailAccount.fromJson(
    (await _map(
      'PATCH',
      accountId.isEmpty ? '/api/mail/account' : '/api/mail/accounts/$accountId',
      {
        'notify': ?notify,
        'signature': ?signature,
        'signatureOnNew': ?signatureOnNew,
        'signatureOnReply': ?signatureOnReply,
      },
    ))['account'],
  )!;

  Future<MailAccount> setNotify(String accountId, bool notify) =>
      updateAccount(accountId, notify: notify);

  /// 계정 순서(처음 것이 기본).
  Future<List<MailAccount>> reorder(List<String> ids) async => [
    for (final a
        in (await _map('POST', '/api/mail/accounts/order', {
                  'ids': ids,
                }))['accounts']
                as List? ??
            const [])
      ?MailAccount.fromJson(a),
  ];

  /// 바깥 그림을 늘 볼 보낸 사람 — [sender]는 주소나 '@도메인'.
  Future<MailAccount> trustSender(
    String accountId,
    String sender, {
    bool add = true,
  }) async => MailAccount.fromJson(
    (await _map('POST', '/api/mail/accounts/$accountId/trusted', {
      'sender': sender,
      'add': add,
    }))['account'],
  )!;

  Future<void> disconnect(String accountId) => _api.requestJson(
    'DELETE',
    accountId.isEmpty ? '/api/mail/account' : '/api/mail/accounts/$accountId',
  );

  /// OAuth로 연결 시작 — 브라우저로 열 주소. [accountId]면 그 OAuth 계정을 다시 로그인.
  Future<({String state, String authUrl})> oauthStart(
    String provider, {
    String? accountId,
  }) async {
    final m = await _map('POST', '/api/mail/oauth/start', {
      'provider': provider,
      'account': ?accountId,
    });
    return (state: m['state'] as String, authUrl: m['authUrl'] as String);
  }

  /// OAuth 결과 — 'pending' | 'done'(계정) | 'error'(이유).
  Future<({String status, MailAccount? account, String? error})> oauthPoll(
    String state,
  ) async {
    final m = await _map('GET', '/api/mail/oauth/poll${_q({'state': state})}');
    return (
      status: m['status'] as String? ?? 'error',
      account: MailAccount.fromJson(m['account']),
      error: m['error'] as String?,
    );
  }

  /// 주소록 — 같은 팀에서 메일 계정을 연결한 사람(그 주소).
  Future<List<({String name, String email})>> directory() async => [
    for (final d
        in await _api.requestJson('GET', '/api/mail/directory') as List)
      if (d is Map)
        (name: d['name'] as String? ?? '', email: d['email'] as String? ?? ''),
  ];

  /// 받는 사람 자동 완성 후보(같은 팀 주소록 + 내가 보낸 바깥 주소).
  Future<List<MailContact>> contacts(String q) async => [
    for (final c
        in await _api.requestJson('GET', '/api/mail/contacts${_q({'q': q})}')
            as List)
      MailContact.fromJson(c),
  ];

  /// 자동 완성에서 지우기.
  Future<void> forgetContact(String address) => _api.requestJson(
    'DELETE',
    '/api/mail/contacts',
    body: {'address': address},
  );

  /// 받은편지함 안 읽은 수(계정 모두의 합) — 계정이 없으면 connected false.
  Future<({bool connected, int unseen, String? error})> status() async {
    final m = await _map('GET', '/api/mail/status');
    return (
      connected: m['connected'] == true,
      unseen: (m['unseen'] as num?)?.toInt() ?? 0,
      error: m['error'] as String?,
    );
  }

  List<MailFolder> _folderList(Object? list) => [
    for (final f in list as List? ?? const [])
      MailFolder.fromJson((f as Map).cast<String, dynamic>()),
  ];

  /// 폴더 만들기 — [parent](위 폴더 경로)가 있으면 그 아래(바깥 메일 서버만). → 만든 경로와 새 폴더 목록.
  Future<({String path, List<MailFolder> folders})> createFolder(
    String account,
    String name, {
    String? parent,
  }) async {
    final m = await _map('POST', '/api/mail/folders', {
      if (account.isNotEmpty) 'account': account,
      'name': name,
      'parent': ?parent,
    });
    return (path: m['path'] as String, folders: _folderList(m['folders']));
  }

  /// 폴더 이름 바꾸기(같은 위 폴더 안에서 마지막 칸 이름만) — 그 폴더로 옮기던 받는 규칙은 서버가 따라 고친다. → 새 경로와 목록.
  Future<({String path, List<MailFolder> folders})> renameFolder(
    String account,
    String path,
    String name,
  ) async {
    final m = await _map('POST', '/api/mail/folders/rename', {
      if (account.isNotEmpty) 'account': account,
      'path': path,
      'name': name,
    });
    return (path: m['path'] as String, folders: _folderList(m['folders']));
  }

  /// 폴더 지우기 — 비어 있고 받는 규칙이 쓰지 않을 때만(아니면 ApiException에 이유). → 새 폴더 목록.
  Future<List<MailFolder>> deleteFolder(String account, String path) async =>
      _folderList(
        (await _map('POST', '/api/mail/folders/delete', {
          if (account.isNotEmpty) 'account': account,
          'path': path,
        }))['folders'],
      );

  Future<List<MailFolder>> folders(String account) async => [
    for (final f
        in await _api.requestJson(
              'GET',
              '/api/mail/folders${_q({'account': account})}',
            )
            as List)
      MailFolder.fromJson((f as Map).cast<String, dynamic>()),
  ];

  Future<({List<MailSummary> messages, int? nextBefore})> messages(
    String account,
    String folder, {
    int? before,
    String? query,
    int limit = 30,
  }) async {
    final m = await _map(
      'GET',
      '/api/mail/messages${_q({'account': account, 'folder': folder, 'before': before?.toString(), 'q': query, 'limit': '$limit'})}',
    );
    return (
      messages: [
        for (final s in m['messages'] as List? ?? const [])
          MailSummary.fromJson((s as Map).cast<String, dynamic>()),
      ],
      nextBefore: (m['nextBefore'] as num?)?.toInt(),
    );
  }

  Future<MailMessage> message(
    String account,
    String folder,
    int uid,
  ) async => MailMessage.fromJson(
    await _map(
      'GET',
      '/api/mail/message${_q({'account': account, 'folder': folder, 'uid': '$uid'})}',
    ),
  );

  /// 첨부 내려받기 경로(session.downloadAuthedFile에 넘긴다).
  static String attachmentPath(
    String account,
    String folder,
    int uid,
    int index,
  ) =>
      '/api/mail/attachment${_q({'account': account, 'folder': folder, 'uid': '$uid', 'index': '$index'})}';

  /// 본문 안 그림(cid) 경로.
  static String inlinePath(String account, String folder, int uid, int index) =>
      '/api/mail/inline${_q({'account': account, 'folder': folder, 'uid': '$uid', 'index': '$index'})}';

  /// 바깥 그림을 서버가 대신 받아 주는 경로("그림 보기"를 눌렀을 때만).
  static String remoteImagePath(String url) =>
      '/api/mail/remote-image${_q({'url': url})}';

  /// 로그인한 채로 받는 바이트(본문 그림) — 실패하면 ApiException.
  Future<Uint8List> bytes(String path) async {
    final res = await _api.downloadAuthed(path);
    if (res.statusCode != 200) {
      await res.stream.drain<void>();
      throw ApiException(tr('그림을 받지 못했습니다.'), statusCode: res.statusCode);
    }
    return res.stream.toBytes();
  }

  Future<void> setFlags(
    String account,
    String folder,
    List<int> uids, {
    bool? seen,
    bool? flagged,
  }) => _api.requestJson(
    'POST',
    '/api/mail/flags',
    body: {
      if (account.isNotEmpty) 'account': account,
      'folder': folder,
      'uids': uids,
      'seen': ?seen,
      'flagged': ?flagged,
    },
  );

  Future<void> move(String account, String folder, List<int> uids, String to) =>
      _api.requestJson(
        'POST',
        '/api/mail/move',
        body: {
          if (account.isNotEmpty) 'account': account,
          'folder': folder,
          'uids': uids,
          'to': to,
        },
      );

  /// 지우기 → 'trash'(휴지통으로) | 'deleted'(아주 지움).
  Future<String> delete(String account, String folder, List<int> uids) async =>
      (await _map('POST', '/api/mail/delete', {
            if (account.isNotEmpty) 'account': account,
            'folder': folder,
            'uids': uids,
          }))['result']
          as String? ??
      'trash';

  Map<String, dynamic> _composeBody({
    required String account,
    required List<String> to,
    required List<String> cc,
    required List<String> bcc,
    required String subject,
    required String text,
    List<Map<String, dynamic>>? format,
    required List<Map<String, dynamic>> attachments,
    required List<int> savedAttachments,
    ({String folder, int uid})? saved,
    String? inReplyTo,
    List<String> references = const [],
  }) => {
    if (account.isNotEmpty) 'account': account,
    'to': to,
    'cc': cc,
    'bcc': bcc,
    'subject': subject,
    'text': text,
    'format': ?format,
    'attachments': attachments,
    if (savedAttachments.isNotEmpty) 'draftAttachments': savedAttachments,
    if (saved != null) 'draft': {'folder': saved.folder, 'uid': saved.uid},
    'inReplyTo': ?inReplyTo,
    if (references.isNotEmpty) 'references': references,
  };

  /// 보내기 — [attachments]는 올린 파일(uploadFile 결과)의 `{ fileUrl, fileName, mimeType }`, [savedAttachments]는 이어 쓰는
  /// 임시 저장본([saved])의 첨부 번호(서버가 저장본에서 꺼내 싣고, 보낸 뒤 저장본을 지운다). [format]은 본문의 서식 구간
  /// (textFormatToJson — 있으면 서버가 HTML 본문도 함께 보낸다).
  Future<void> send({
    String account = '',
    required List<String> to,
    List<String> cc = const [],
    List<String> bcc = const [],
    required String subject,
    required String text,
    List<Map<String, dynamic>>? format,
    List<Map<String, dynamic>> attachments = const [],
    List<int> savedAttachments = const [],
    ({String folder, int uid})? saved,
    String? inReplyTo,
    List<String> references = const [],
    ({String folder, int uid})? answered,
  }) => _api.requestJson(
    'POST',
    '/api/mail/send',
    body: {
      ..._composeBody(
        account: account,
        to: to,
        cc: cc,
        bcc: bcc,
        subject: subject,
        text: text,
        format: format,
        attachments: attachments,
        savedAttachments: savedAttachments,
        saved: saved,
        inReplyTo: inReplyTo,
        references: references,
      ),
      if (answered != null)
        'answered': {'folder': answered.folder, 'uid': answered.uid},
    },
  );

  /// 임시 저장 → 새 저장본(앞의 [saved]는 서버가 지운다).
  Future<({String folder, int uid})> saveDraft({
    String account = '',
    List<String> to = const [],
    List<String> cc = const [],
    List<String> bcc = const [],
    String subject = '',
    String text = '',
    List<Map<String, dynamic>>? format,
    List<Map<String, dynamic>> attachments = const [],
    List<int> savedAttachments = const [],
    ({String folder, int uid})? saved,
    String? inReplyTo,
    List<String> references = const [],
  }) async {
    final m = await _map(
      'POST',
      '/api/mail/drafts',
      _composeBody(
        account: account,
        to: to,
        cc: cc,
        bcc: bcc,
        subject: subject,
        text: text,
        format: format,
        attachments: attachments,
        savedAttachments: savedAttachments,
        saved: saved,
        inReplyTo: inReplyTo,
        references: references,
      ),
    );
    return (folder: m['folder'] as String, uid: (m['uid'] as num).toInt());
  }

  /// 임시 저장본 버리기(휴지통을 거치지 않음).
  Future<void> discardDraft(String account, String folder, int uid) =>
      _api.requestJson(
        'POST',
        '/api/mail/drafts/discard',
        body: {
          if (account.isNotEmpty) 'account': account,
          'folder': folder,
          'uid': uid,
        },
      );

  /// 메일의 첨부(·원문 .eml)를 내 업로드 파일로 — 대화방·할 일에 붙일 것 `[{ url, fileName, size, mimeType }]`.
  Future<List<({String url, String fileName, int size, String? mimeType})>>
  export(
    String account,
    String folder,
    int uid, {
    List<int> attachments = const [],
    bool eml = false,
  }) async {
    final m = await _map('POST', '/api/mail/export', {
      if (account.isNotEmpty) 'account': account,
      'folder': folder,
      'uid': uid,
      'attachments': attachments,
      'eml': eml,
    });
    return [
      for (final f in m['files'] as List? ?? const [])
        if (f is Map)
          (
            url: f['url'] as String? ?? '',
            fileName: f['fileName'] as String? ?? '',
            size: (f['size'] as num?)?.toInt() ?? 0,
            mimeType: f['mimeType'] as String?,
          ),
    ];
  }

  // ── 받는 규칙 ──

  Future<List<MailRule>> rules(String account) async => [
    for (final r
        in (await _map(
                  'GET',
                  '/api/mail/rules${_q({'account': account})}',
                ))['rules']
                as List? ??
            const [])
      MailRule.fromJson((r as Map).cast<String, dynamic>()),
  ];

  /// 규칙 만들기([rule.id]가 비면)·고치기.
  Future<MailRule> saveRule(String account, MailRule rule) async {
    final m = rule.id.isEmpty
        ? await _map('POST', '/api/mail/rules', {
            ...rule.toJson(),
            if (account.isNotEmpty) 'account': account,
          })
        : await _map('PUT', '/api/mail/rules/${rule.id}', rule.toJson());
    return MailRule.fromJson((m['rule'] as Map).cast<String, dynamic>());
  }

  Future<void> deleteRule(String id) =>
      _api.requestJson('DELETE', '/api/mail/rules/$id');

  Future<List<MailRule>> reorderRules(String account, List<String> ids) async =>
      [
        for (final r
            in (await _map('POST', '/api/mail/rules/order', {
                      if (account.isNotEmpty) 'account': account,
                      'ids': ids,
                    }))['rules']
                    as List? ??
                const [])
          MailRule.fromJson((r as Map).cast<String, dynamic>()),
      ];

  /// 받은편지함(최근 500통)에 지금 걸기 → 맞은 수·옮긴 수.
  Future<({int matched, int moved})> applyRules(String account) async {
    final m = await _map('POST', '/api/mail/rules/apply', {
      if (account.isNotEmpty) 'account': account,
    });
    return (
      matched: (m['matched'] as num?)?.toInt() ?? 0,
      moved: (m['moved'] as num?)?.toInt() ?? 0,
    );
  }
}
