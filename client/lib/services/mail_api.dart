import '../models/mail.dart';
import 'api_client.dart';

/// 웹메일 API(server/src/webmail.js) — 사람마다 연결한 메일 계정 하나를 다룬다(팀과 상관없음). 메일 서버 오류는 502로 오고
/// ApiException 글에 고칠 방법이 실린다.
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

  Future<MailAccount?> account() async =>
      MailAccount.fromJson((await _map('GET', '/api/mail/account'))['account']);

  /// 연결·바꾸기 — 서버가 IMAP·SMTP 로그인을 해 보고 저장한다(실패하면 ApiException에 이유). [password]가 null이면 지금 비밀번호.
  Future<MailAccount> connect({
    required String email,
    String? displayName,
    required String provider,
    MailEndpoint? imap,
    MailEndpoint? smtp,
    String? username,
    String? password,
  }) async => MailAccount.fromJson(
    (await _map('PUT', '/api/mail/account', {
      'email': email,
      'displayName': ?displayName,
      'provider': provider,
      if (imap != null) 'imap': imap.toJson(),
      if (smtp != null) 'smtp': smtp.toJson(),
      'username': ?username,
      'password': ?password,
    }))['account'],
  )!;

  Future<MailAccount> setNotify(bool notify) async => MailAccount.fromJson(
    (await _map('PATCH', '/api/mail/account', {'notify': notify}))['account'],
  )!;

  /// 주소록 — 같은 팀에서 메일 계정을 연결한 사람(그 주소).
  Future<List<({String name, String email})>> directory() async => [
    for (final d
        in await _api.requestJson('GET', '/api/mail/directory') as List)
      if (d is Map)
        (name: d['name'] as String? ?? '', email: d['email'] as String? ?? ''),
  ];

  Future<void> disconnect() => _api.requestJson('DELETE', '/api/mail/account');

  /// 받은편지함 안 읽은 수 — 계정이 없으면 connected false.
  Future<({bool connected, int unseen, String? error})> status() async {
    final m = await _map('GET', '/api/mail/status');
    return (
      connected: m['connected'] == true,
      unseen: (m['unseen'] as num?)?.toInt() ?? 0,
      error: m['error'] as String?,
    );
  }

  Future<List<MailFolder>> folders() async => [
    for (final f in await _api.requestJson('GET', '/api/mail/folders') as List)
      MailFolder.fromJson((f as Map).cast<String, dynamic>()),
  ];

  Future<({List<MailSummary> messages, int? nextBefore})> messages(
    String folder, {
    int? before,
    String? query,
    int limit = 30,
  }) async {
    final m = await _map(
      'GET',
      '/api/mail/messages${_q({'folder': folder, 'before': before?.toString(), 'q': query, 'limit': '$limit'})}',
    );
    return (
      messages: [
        for (final s in m['messages'] as List? ?? const [])
          MailSummary.fromJson((s as Map).cast<String, dynamic>()),
      ],
      nextBefore: (m['nextBefore'] as num?)?.toInt(),
    );
  }

  Future<MailMessage> message(String folder, int uid) async =>
      MailMessage.fromJson(
        await _map(
          'GET',
          '/api/mail/message${_q({'folder': folder, 'uid': '$uid'})}',
        ),
      );

  /// 첨부 내려받기 경로(session.downloadAuthedFile에 넘긴다).
  static String attachmentPath(String folder, int uid, int index) =>
      '/api/mail/attachment${_q({'folder': folder, 'uid': '$uid', 'index': '$index'})}';

  Future<void> setFlags(
    String folder,
    List<int> uids, {
    bool? seen,
    bool? flagged,
  }) => _api.requestJson(
    'POST',
    '/api/mail/flags',
    body: {'folder': folder, 'uids': uids, 'seen': ?seen, 'flagged': ?flagged},
  );

  Future<void> move(String folder, List<int> uids, String to) =>
      _api.requestJson(
        'POST',
        '/api/mail/move',
        body: {'folder': folder, 'uids': uids, 'to': to},
      );

  /// 지우기 → 'trash'(휴지통으로) | 'deleted'(아주 지움).
  Future<String> delete(String folder, List<int> uids) async =>
      (await _map('POST', '/api/mail/delete', {
            'folder': folder,
            'uids': uids,
          }))['result']
          as String? ??
      'trash';

  /// 보내기 — [attachments]는 올린 파일(uploadFile 결과)의 `{ fileUrl, fileName, mimeType }`.
  Future<void> send({
    required List<String> to,
    List<String> cc = const [],
    List<String> bcc = const [],
    required String subject,
    required String text,
    List<Map<String, dynamic>> attachments = const [],
    String? inReplyTo,
    List<String> references = const [],
    ({String folder, int uid})? answered,
  }) => _api.requestJson(
    'POST',
    '/api/mail/send',
    body: {
      'to': to,
      'cc': cc,
      'bcc': bcc,
      'subject': subject,
      'text': text,
      'attachments': attachments,
      'inReplyTo': ?inReplyTo,
      if (references.isNotEmpty) 'references': references,
      if (answered != null)
        'answered': {'folder': answered.folder, 'uid': answered.uid},
    },
  );
}
