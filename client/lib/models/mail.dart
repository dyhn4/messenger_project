// 웹메일의 데이터 모양 — 서버 webmail.js·webmailRules.js(계정·폴더·목록·읽기·받는 규칙·자동 완성)를 옮긴 것과 답장·전달·임시 저장본 쓰기
// 도우미, 서명 넣기.

import '../l10n/tr.dart';
import 'text_format.dart';

/// 주소 하나 — 이름이 없을 수 있다.
class MailAddress {
  final String name;
  final String address;
  const MailAddress({this.name = '', required this.address});

  factory MailAddress.fromJson(Object? json) {
    final m = json is Map ? json : const {};
    return MailAddress(
      name: m['name'] as String? ?? '',
      address: m['address'] as String? ?? '',
    );
  }

  /// 화면에 보일 이름 — 이름이 없으면 주소.
  String get label => name.isNotEmpty ? name : address;

  /// 서버에 보낼 글 — "이름 <주소>" 또는 주소.
  String get wire => name.isNotEmpty ? '"$name" <$address>' : address;

  @override
  bool operator ==(Object other) =>
      other is MailAddress &&
      other.address.toLowerCase() == address.toLowerCase();

  @override
  int get hashCode => address.toLowerCase().hashCode;
}

List<MailAddress> _addresses(Object? list) => [
  for (final a in list as List? ?? const []) MailAddress.fromJson(a),
];

/// 연결 끝점 — [security] 'ssl' | 'starttls'.
class MailEndpoint {
  final String host;
  final int port;
  final String security;
  const MailEndpoint({
    required this.host,
    required this.port,
    this.security = 'ssl',
  });

  factory MailEndpoint.fromJson(Object? json) {
    final m = json is Map ? json : const {};
    return MailEndpoint(
      host: m['host'] as String? ?? '',
      port: (m['port'] as num?)?.toInt() ?? 993,
      security: m['security'] as String? ?? 'ssl',
    );
  }

  Map<String, dynamic> toJson() => {
    'host': host,
    'port': port,
    'security': security,
  };
}

/// 미리 정한 메일 서비스(네이버·Gmail 등). [oauth]는 그 서비스를 Google·Microsoft 로그인으로 연결할 수 있으면 그 제공자
/// ('google'|'microsoft' — 관리자가 켰을 때).
class MailPreset {
  final String key;
  final String label;
  final MailEndpoint imap;
  final MailEndpoint smtp;
  final String hint;
  final String? oauth;
  const MailPreset({
    required this.key,
    required this.label,
    required this.imap,
    required this.smtp,
    this.hint = '',
    this.oauth,
  });

  factory MailPreset.fromJson(Map<String, dynamic> json) => MailPreset(
    key: json['key'] as String,
    label: json['label'] as String? ?? '',
    imap: MailEndpoint.fromJson(json['imap']),
    smtp: MailEndpoint.fromJson(json['smtp']),
    hint: json['hint'] as String? ?? '',
    oauth: json['oauth'] as String?,
  );
}

/// 연결한 메일 계정(비밀번호·토큰은 오지 않는다). [authType] — 'password' | 'oauth'(Google·Microsoft 로그인) | 'local'(이 서버가
/// 직접 받는 회사 메일함 — 연결 값이 없고 끊을 수 없다).
class MailAccount {
  /// 예전 서버(계정 하나)는 id가 없다 — 그때는 빈 글.
  final String id;
  final String email;
  final String? displayName;
  final String provider;
  final String providerLabel;
  final String authType;
  final String? oauthProvider;
  final MailEndpoint? imap;
  final MailEndpoint? smtp;
  final String username;
  final bool notify;
  final String signature;
  final bool signatureOnNew;
  final bool signatureOnReply;

  /// 바깥 그림을 늘 보여 줄 보낸 사람 — 'a@b.com' 또는 '@b.com'.
  final List<String> trustedSenders;
  final String? lastError;
  const MailAccount({
    this.id = '',
    required this.email,
    this.displayName,
    this.provider = 'custom',
    this.providerLabel = '',
    this.authType = 'password',
    this.oauthProvider,
    this.imap,
    this.smtp,
    this.username = '',
    this.notify = true,
    this.signature = '',
    this.signatureOnNew = true,
    this.signatureOnReply = true,
    this.trustedSenders = const [],
    this.lastError,
  });

  static MailAccount? fromJson(Object? json) {
    if (json is! Map) return null;
    return MailAccount(
      id: json['id'] as String? ?? '',
      email: json['email'] as String? ?? '',
      displayName: json['displayName'] as String?,
      provider: json['provider'] as String? ?? 'custom',
      providerLabel: json['providerLabel'] as String? ?? '',
      authType: json['authType'] as String? ?? 'password',
      oauthProvider: json['oauthProvider'] as String?,
      imap: json['imap'] == null ? null : MailEndpoint.fromJson(json['imap']),
      smtp: json['smtp'] == null ? null : MailEndpoint.fromJson(json['smtp']),
      username: json['username'] as String? ?? '',
      notify: json['notify'] != false,
      signature: json['signature'] as String? ?? '',
      signatureOnNew: json['signatureOnNew'] != false,
      signatureOnReply: json['signatureOnReply'] != false,
      trustedSenders: [
        for (final t in json['trustedSenders'] as List? ?? const [])
          if (t is String) t,
      ],
      lastError: json['lastError'] as String?,
    );
  }

  bool get isLocal => authType == 'local';
  bool get isOAuth => authType == 'oauth';

  /// 이 보낸 사람의 바깥 그림을 늘 보여 주는지(주소나 '@도메인'이 맞음).
  bool trusts(String address) {
    final a = address.trim().toLowerCase();
    final at = a.lastIndexOf('@');
    if (at < 0) return false;
    return trustedSenders.contains(a) ||
        trustedSenders.contains(a.substring(at));
  }
}

/// 폴더 — [specialUse] '\\Inbox' | '\\Sent' | '\\Drafts' | '\\Junk' | '\\Trash' | … 또는 null.
///
/// [depth]는 하위 폴더 깊이(들여쓰기), [editable]이면 이름을 바꾸거나 지울 수 있다(사람이 만든 폴더 — 예전 서버는 모름, false).
class MailFolder {
  final String path;
  final String name;
  final String? specialUse;
  final int? unseen;
  final int? total;
  final int depth;
  final bool editable;
  const MailFolder({
    required this.path,
    required this.name,
    this.specialUse,
    this.unseen,
    this.total,
    this.depth = 0,
    this.editable = false,
  });

  factory MailFolder.fromJson(Map<String, dynamic> json) => MailFolder(
    path: json['path'] as String,
    name: json['name'] as String? ?? json['path'] as String,
    specialUse: json['specialUse'] as String?,
    unseen: (json['unseen'] as num?)?.toInt(),
    total: (json['total'] as num?)?.toInt(),
    depth: (json['depth'] as num?)?.toInt() ?? 0,
    editable: json['editable'] == true,
  );

  MailFolder copyWith({int? unseen}) => MailFolder(
    path: path,
    name: name,
    specialUse: specialUse,
    unseen: unseen ?? this.unseen,
    total: total,
    depth: depth,
    editable: editable,
  );

  bool get isInbox => specialUse == r'\Inbox';
  bool get isSent => specialUse == r'\Sent';
  bool get isTrash => specialUse == r'\Trash';
  bool get isDrafts => specialUse == r'\Drafts';
}

/// 목록 한 줄. [messageId]·[inReplyTo]·[references]는 대화로 묶는 데 쓴다(mailThreads — 예전 서버는 비어 있다).
class MailSummary {
  final int uid;
  final String? messageId;
  final String? inReplyTo;
  final List<String> references;
  final String subject;
  final MailAddress from;
  final List<MailAddress> to;
  final DateTime? date;
  final bool seen;
  final bool flagged;
  final bool answered;
  final bool draft;
  final bool hasAttachments;
  const MailSummary({
    required this.uid,
    required this.subject,
    required this.from,
    this.to = const [],
    this.date,
    this.seen = false,
    this.flagged = false,
    this.answered = false,
    this.draft = false,
    this.hasAttachments = false,
    this.messageId,
    this.inReplyTo,
    this.references = const [],
  });

  factory MailSummary.fromJson(Map<String, dynamic> json) => MailSummary(
    uid: (json['uid'] as num).toInt(),
    messageId: json['messageId'] as String?,
    inReplyTo: json['inReplyTo'] as String?,
    references: [
      for (final r in json['references'] as List? ?? const [])
        if (r is String) r,
    ],
    subject: json['subject'] as String? ?? tr('(제목 없음)'),
    from: MailAddress.fromJson(json['from']),
    to: _addresses(json['to']),
    date: json['date'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch((json['date'] as num).toInt()),
    seen: json['seen'] == true,
    flagged: json['flagged'] == true,
    answered: json['answered'] == true,
    draft: json['draft'] == true,
    hasAttachments: json['hasAttachments'] == true,
  );

  MailSummary copyWith({bool? seen, bool? flagged}) => MailSummary(
    uid: uid,
    subject: subject,
    from: from,
    to: to,
    date: date,
    seen: seen ?? this.seen,
    flagged: flagged ?? this.flagged,
    answered: answered,
    draft: draft,
    hasAttachments: hasAttachments,
    messageId: messageId,
    inReplyTo: inReplyTo,
    references: references,
  );
}

class MailAttachment {
  final int index;
  final String fileName;
  final String? contentType;
  final int size;
  const MailAttachment({
    required this.index,
    required this.fileName,
    this.contentType,
    this.size = 0,
  });

  factory MailAttachment.fromJson(Map<String, dynamic> json) => MailAttachment(
    index: (json['index'] as num).toInt(),
    fileName: json['fileName'] as String? ?? tr('첨부'),
    contentType: json['contentType'] as String?,
    size: (json['size'] as num?)?.toInt() ?? 0,
  );
}

/// 읽기 — 본문은 글자([text] — HTML 메일은 서버가 글자로 바꾼 것)와, HTML 메일이면 서버가 걸러 낸 서식 문서([rich] — 서버
/// webmailHtml.js, 그리는 곳은 mail_rich_view.dart). [remoteImages]는 "그림 보기"를 눌러야 받는 바깥 그림 수.
class MailMessage {
  final int uid;
  final String subject;
  final MailAddress from;
  final List<MailAddress> to;
  final List<MailAddress> cc;
  final List<MailAddress> bcc;
  final List<MailAddress> replyTo;
  final DateTime? date;
  final String text;
  final bool truncated;
  final bool wasHtml;
  final Map<String, dynamic>? rich;
  final int remoteImages;
  final bool richTruncated;
  final String? messageId;
  final String? inReplyTo;
  final List<String> references;
  final List<MailAttachment> attachments;
  final bool flagged;

  /// 임시 저장본(\Draft) — 읽기 대신 "이어 쓰기".
  final bool draft;

  /// 이 앱이 임시 저장한 서식 있는 메일의 서식 구간(이어 쓸 때 되살린다 — 서버 mailFormatHtml.js). 그 밖에는 null.
  final List<TextFormatRun>? format;

  /// 회사 메일함이 받을 때 본 보낸 쪽 확인(SPF·DKIM·DMARC — 서버 localMailAuth.js)이 통과하지 못했으면 'warn'|'junk', 그 이유.
  final String? authVerdict;
  final String? authReason;
  const MailMessage({
    required this.uid,
    required this.subject,
    required this.from,
    this.to = const [],
    this.cc = const [],
    this.bcc = const [],
    this.replyTo = const [],
    this.date,
    this.text = '',
    this.truncated = false,
    this.wasHtml = false,
    this.rich,
    this.remoteImages = 0,
    this.richTruncated = false,
    this.messageId,
    this.inReplyTo,
    this.references = const [],
    this.attachments = const [],
    this.flagged = false,
    this.draft = false,
    this.format,
    this.authVerdict,
    this.authReason,
  });

  factory MailMessage.fromJson(Map<String, dynamic> json) {
    final auth = json['auth'] is Map ? json['auth'] as Map : null;
    final rich = json['rich'] is Map
        ? (json['rich'] as Map).cast<String, dynamic>()
        : null;
    return MailMessage(
      uid: (json['uid'] as num).toInt(),
      subject: json['subject'] as String? ?? tr('(제목 없음)'),
      from: MailAddress.fromJson(json['from']),
      to: _addresses(json['to']),
      cc: _addresses(json['cc']),
      bcc: _addresses(json['bcc']),
      replyTo: _addresses(json['replyTo']),
      date: json['date'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch((json['date'] as num).toInt()),
      text: json['text'] as String? ?? '',
      truncated: json['truncated'] == true,
      wasHtml: json['html'] == true,
      rich: rich?['doc'] is Map
          ? (rich!['doc'] as Map).cast<String, dynamic>()
          : null,
      remoteImages: (rich?['remoteImages'] as num?)?.toInt() ?? 0,
      richTruncated: rich?['truncated'] == true,
      messageId: json['messageId'] as String?,
      inReplyTo: json['inReplyTo'] as String?,
      references: [
        for (final r in json['references'] as List? ?? const [])
          if (r is String) r,
      ],
      attachments: [
        for (final a in json['attachments'] as List? ?? const [])
          MailAttachment.fromJson((a as Map).cast<String, dynamic>()),
      ],
      flagged: json['flagged'] == true,
      draft: json['draft'] == true,
      format: parseTextFormat(json['format']),
      authVerdict: auth?['verdict'] as String?,
      authReason: auth?['reason'] as String?,
    );
  }
}

/// 쓰기 창에 채울 값 — 새 메일·답장·전체 답장·전달·임시 저장본 이어 쓰기.
class MailDraft {
  final List<MailAddress> to;
  final List<MailAddress> cc;
  final List<MailAddress> bcc;
  final String subject;
  final String text;

  /// [text]의 서식 구간(이어 쓰는 서식 있는 임시 저장본 — 새 메일·답장은 null).
  final List<TextFormatRun>? format;
  final String? inReplyTo;
  final List<String> references;

  /// 답장한 원래 메일(보낸 뒤 답장 표시) — 폴더와 uid.
  final ({String folder, int uid})? answered;

  /// 이어 쓰는 임시 저장본(다시 저장·보내면 지운다)과 그 안의 첨부(보낼 때 서버가 저장본에서 꺼내 싣는다).
  final ({String folder, int uid})? saved;
  final List<MailAttachment> savedAttachments;

  /// 이 메일을 쓸 계정(없으면 쓰기 창이 정한다 — 보고 있던 계정).
  final String? accountId;

  /// 서명을 넣을 자리 — 답장·전달이면 인용 앞, 새 메일이면 끝. 이어 쓰기는 이미 들어 있어 넣지 않는다.
  final MailSignatureSlot signatureSlot;
  const MailDraft({
    this.to = const [],
    this.cc = const [],
    this.bcc = const [],
    this.subject = '',
    this.text = '',
    this.format,
    this.inReplyTo,
    this.references = const [],
    this.answered,
    this.saved,
    this.savedAttachments = const [],
    this.accountId,
    this.signatureSlot = MailSignatureSlot.fresh,
  });
}

/// 서명을 어디에 넣을지 — 새 메일(끝)·답장/전달(인용 앞)·넣지 않음(이어 쓰기).
enum MailSignatureSlot { fresh, reply, none }

enum MailReplyKind { reply, replyAll, forward }

/// 서명 머리(관례 — "-- " 한 줄).
const kMailSignatureMark = '-- ';

/// 서명 덩어리 — 빈 줄 하나, "-- ", 서명.
String mailSignatureBlock(String signature) =>
    '\n\n$kMailSignatureMark\n${signature.trim()}';

/// [text]에 [signature]를 넣는다 — [slot]이 reply면 맨 앞(인용 앞), fresh면 끝. 이미 같은 서명이 있거나 서명이 비면 그대로.
String withSignature(String text, String signature, MailSignatureSlot slot) {
  final sig = signature.trim();
  if (sig.isEmpty || slot == MailSignatureSlot.none) return text;
  final block = mailSignatureBlock(sig);
  if (text.contains(block)) return text;
  return slot == MailSignatureSlot.reply ? '$block$text' : '$text$block';
}

/// 계정을 바꿨을 때 — 본문의 [from] 서명 덩어리를 [to] 서명으로 바꾼다(없으면 [slot] 자리에 새로).
String swapSignature(
  String text,
  String from,
  String to,
  MailSignatureSlot slot,
) {
  final old = from.trim().isEmpty ? null : mailSignatureBlock(from);
  if (old != null && text.contains(old)) {
    return text.replaceFirst(
      old,
      to.trim().isEmpty ? '' : mailSignatureBlock(to),
    );
  }
  return withSignature(text, to, slot);
}

/// "2026. 10. 17. 오전 9:05" 같은 인용 머리용 시각.
String mailQuoteTime(DateTime? d) {
  if (d == null) return '';
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  final m = d.minute.toString().padLeft(2, '0');
  return '${d.year}. ${d.month}. ${d.day}. ${d.hour < 12 ? tr('오전') : tr('오후')} $h:$m';
}

/// 제목 앞머리 — 이미 "Re:"/"Fwd:"(대소문자·"RE :"·"답장:" 등)가 있으면 또 붙이지 않는다.
String prefixedSubject(String subject, String prefix) {
  final s = subject.trim();
  final re = prefix == 'Re:'
      ? RegExp(r'^(re|답장)\s*:', caseSensitive: false)
      : RegExp(r'^(fwd?|전달)\s*:', caseSensitive: false);
  return re.hasMatch(s) ? s : '$prefix $s';
}

/// 원래 메일로 답장·전체 답장·전달 초안을 만든다 — [myEmail]은 전체 답장에서 나를 빼는 데 쓴다.
MailDraft draftFrom(
  MailMessage m,
  MailReplyKind kind, {
  required String folder,
  required String myEmail,
  String? accountId,
}) {
  final quotedHeader = tr('{p0}, {m.from.wire} 님이 작성:', {
    'p0': mailQuoteTime(m.date),
    'm.from.wire': m.from.wire,
  });
  final quoted = m.text
      .trimRight()
      .split('\n')
      .map((l) => l.isEmpty ? '>' : '> $l')
      .join('\n');
  if (kind == MailReplyKind.forward) {
    final header = [
      tr('---------- 전달된 메일 ----------'),
      tr('보낸 사람: {m.from.wire}', {'m.from.wire': m.from.wire}),
      if (m.date != null) tr('날짜: {p0}', {'p0': mailQuoteTime(m.date)}),
      tr('제목: {m.subject}', {'m.subject': m.subject}),
      if (m.to.isNotEmpty)
        tr('받는 사람: {p0}', {'p0': m.to.map((a) => a.wire).join(', ')}),
      if (m.cc.isNotEmpty)
        tr('참조: {p0}', {'p0': m.cc.map((a) => a.wire).join(', ')}),
    ].join('\n');
    return MailDraft(
      subject: prefixedSubject(m.subject, 'Fwd:'),
      text: '\n\n$header\n\n${m.text.trimRight()}',
      accountId: accountId,
      signatureSlot: MailSignatureSlot.reply,
    );
  }
  final me = myEmail.toLowerCase();
  final replyTarget = m.replyTo.isNotEmpty ? m.replyTo : [m.from];
  final to = <MailAddress>[
    for (final a in replyTarget)
      if (a.address.isNotEmpty) a,
  ];
  final cc = <MailAddress>[];
  if (kind == MailReplyKind.replyAll) {
    for (final a in [...m.to, ...m.cc]) {
      if (a.address.isEmpty || a.address.toLowerCase() == me) continue;
      if (to.contains(a) || cc.contains(a)) continue;
      cc.add(a);
    }
  }
  final refs = [...m.references, if (m.messageId != null) m.messageId!];
  return MailDraft(
    to: to,
    cc: cc,
    subject: prefixedSubject(m.subject, 'Re:'),
    text: '\n\n$quotedHeader\n$quoted',
    inReplyTo: m.messageId,
    references: refs.length > 20 ? refs.sublist(refs.length - 20) : refs,
    answered: (folder: folder, uid: m.uid),
    accountId: accountId,
    signatureSlot: MailSignatureSlot.reply,
  );
}

/// 임시 저장본을 이어 쓰는 초안 — 받는 사람·숨은 참조·제목·본문·첨부를 그대로(서명은 이미 들어 있다).
MailDraft draftFromSaved(
  MailMessage m, {
  required String folder,
  String? accountId,
}) => MailDraft(
  to: m.to,
  cc: m.cc,
  bcc: m.bcc,
  subject: m.subject,
  text: m.text,
  format: m.format,
  inReplyTo: m.inReplyTo,
  references: m.references,
  saved: (folder: folder, uid: m.uid),
  savedAttachments: m.attachments,
  accountId: accountId,
  signatureSlot: MailSignatureSlot.none,
);

/// 메일을 대화방·할 일로 보낼 때의 글 — 제목, 보낸 사람·시각, 본문 앞부분([max]자).
String mailShareText(MailMessage m, {int max = 1000}) {
  final body = m.text.trim();
  final cut = body.length > max ? '${body.substring(0, max)}…' : body;
  return [
    tr('[메일] {subject}', {'subject': m.subject}),
    tr('보낸 사람: {from}', {'from': m.from.wire}),
    if (m.date != null) tr('날짜: {p0}', {'p0': mailQuoteTime(m.date)}),
    if (cut.isNotEmpty) '\n$cut',
  ].join('\n');
}

/// 목록의 시각 — 오늘이면 "오전 9:05", 올해면 "10월 3일", 아니면 "2025. 3. 1.".
String mailListTime(DateTime? d, DateTime now) {
  if (d == null) return '';
  if (d.year == now.year && d.month == now.month && d.day == now.day) {
    final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
    return '${d.hour < 12 ? tr('오전') : tr('오후')} $h:${d.minute.toString().padLeft(2, '0')}';
  }
  if (d.year == now.year) {
    return tr('{d.month}월 {d.day}일', {'d.month': d.month, 'd.day': d.day});
  }
  return '${d.year}. ${d.month}. ${d.day}.';
}

/// 바이트 → "1.2MB" / "34KB".
String mailSizeText(int bytes) {
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
  }
  if (bytes >= 1024) return '${(bytes / 1024).round()}KB';
  return tr('{bytes}바이트', {'bytes': bytes});
}

// ── 받는 규칙 ──

/// 규칙의 조건 — [field] 'from'|'to'|'subject', [op] 'contains'|'not_contains'|'is'.
class MailRuleCondition {
  final String field;
  final String op;
  final String value;
  const MailRuleCondition({
    this.field = 'from',
    this.op = 'contains',
    this.value = '',
  });

  factory MailRuleCondition.fromJson(Object? json) {
    final m = json is Map ? json : const {};
    return MailRuleCondition(
      field: m['field'] as String? ?? 'from',
      op: m['op'] as String? ?? 'contains',
      value: m['value'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {'field': field, 'op': op, 'value': value};
}

/// 받는 규칙 — 새로 온 받은편지함 메일에 차례대로 건다(서버 webmailRules.js planRules).
class MailRule {
  final String id;
  final String name;
  final bool enabled;

  /// 'all'(모두 맞으면) | 'any'(하나라도 맞으면).
  final String match;
  final List<MailRuleCondition> conditions;
  final String? moveTo;
  final bool markSeen;
  final bool flag;
  final bool skipNotify;
  final bool stop;
  const MailRule({
    this.id = '',
    required this.name,
    this.enabled = true,
    this.match = 'all',
    this.conditions = const [],
    this.moveTo,
    this.markSeen = false,
    this.flag = false,
    this.skipNotify = false,
    this.stop = false,
  });

  factory MailRule.fromJson(Map<String, dynamic> json) {
    final a = json['actions'] is Map ? json['actions'] as Map : const {};
    return MailRule(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      enabled: json['enabled'] != false,
      match: json['match'] as String? ?? 'all',
      conditions: [
        for (final c in json['conditions'] as List? ?? const [])
          MailRuleCondition.fromJson(c),
      ],
      moveTo: a['moveTo'] as String?,
      markSeen: a['markSeen'] == true,
      flag: a['flag'] == true,
      skipNotify: a['skipNotify'] == true,
      stop: json['stop'] == true,
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'enabled': enabled,
    'match': match,
    'conditions': [for (final c in conditions) c.toJson()],
    'actions': {
      'moveTo': moveTo,
      'markSeen': markSeen,
      'flag': flag,
      'skipNotify': skipNotify,
    },
    'stop': stop,
  };
}

/// 받는 사람 자동 완성 후보 — [member]면 같은 팀 사람(주소록), 아니면 내가 보낸 적 있는 바깥 주소.
class MailContact {
  final String name;
  final String address;
  final bool member;
  const MailContact({
    this.name = '',
    required this.address,
    this.member = false,
  });

  factory MailContact.fromJson(Object? json) {
    final m = json is Map ? json : const {};
    return MailContact(
      name: m['name'] as String? ?? '',
      address: m['address'] as String? ?? '',
      member: m['member'] == true,
    );
  }

  String get wire => MailAddress(name: name, address: address).wire;
}
