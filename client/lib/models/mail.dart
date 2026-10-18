// 웹메일의 데이터 모양 — 서버 webmail.js·webmailRules.js(계정·폴더·목록·읽기)를 옮긴 것과 답장·전달 쓰기 도우미.

import '../l10n/tr.dart';

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

/// 미리 정한 메일 서비스(네이버·Gmail 등).
class MailPreset {
  final String key;
  final String label;
  final MailEndpoint imap;
  final MailEndpoint smtp;
  final String hint;
  const MailPreset({
    required this.key,
    required this.label,
    required this.imap,
    required this.smtp,
    this.hint = '',
  });

  factory MailPreset.fromJson(Map<String, dynamic> json) => MailPreset(
    key: json['key'] as String,
    label: json['label'] as String? ?? '',
    imap: MailEndpoint.fromJson(json['imap']),
    smtp: MailEndpoint.fromJson(json['smtp']),
    hint: json['hint'] as String? ?? '',
  );
}

/// 연결한 메일 계정(비밀번호는 오지 않는다).
class MailAccount {
  final String email;
  final String? displayName;
  final String provider;
  final String providerLabel;
  final MailEndpoint imap;
  final MailEndpoint smtp;
  final String username;
  final bool notify;
  final String? lastError;
  const MailAccount({
    required this.email,
    this.displayName,
    this.provider = 'custom',
    this.providerLabel = '',
    required this.imap,
    required this.smtp,
    this.username = '',
    this.notify = true,
    this.lastError,
  });

  static MailAccount? fromJson(Object? json) {
    if (json is! Map) return null;
    return MailAccount(
      email: json['email'] as String? ?? '',
      displayName: json['displayName'] as String?,
      provider: json['provider'] as String? ?? 'custom',
      providerLabel: json['providerLabel'] as String? ?? '',
      imap: MailEndpoint.fromJson(json['imap']),
      smtp: MailEndpoint.fromJson(json['smtp']),
      username: json['username'] as String? ?? '',
      notify: json['notify'] != false,
      lastError: json['lastError'] as String?,
    );
  }
}

/// 폴더 — [specialUse] '\\Inbox' | '\\Sent' | '\\Drafts' | '\\Junk' | '\\Trash' | … 또는 null.
class MailFolder {
  final String path;
  final String name;
  final String? specialUse;
  final int? unseen;
  final int? total;
  const MailFolder({
    required this.path,
    required this.name,
    this.specialUse,
    this.unseen,
    this.total,
  });

  factory MailFolder.fromJson(Map<String, dynamic> json) => MailFolder(
    path: json['path'] as String,
    name: json['name'] as String? ?? json['path'] as String,
    specialUse: json['specialUse'] as String?,
    unseen: (json['unseen'] as num?)?.toInt(),
    total: (json['total'] as num?)?.toInt(),
  );

  bool get isInbox => specialUse == r'\Inbox';
  bool get isSent => specialUse == r'\Sent';
  bool get isTrash => specialUse == r'\Trash';
}

/// 목록 한 줄.
class MailSummary {
  final int uid;
  final String subject;
  final MailAddress from;
  final List<MailAddress> to;
  final DateTime? date;
  final bool seen;
  final bool flagged;
  final bool answered;
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
    this.hasAttachments = false,
  });

  factory MailSummary.fromJson(Map<String, dynamic> json) => MailSummary(
    uid: (json['uid'] as num).toInt(),
    subject: json['subject'] as String? ?? tr('(제목 없음)'),
    from: MailAddress.fromJson(json['from']),
    to: _addresses(json['to']),
    date: json['date'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch((json['date'] as num).toInt()),
    seen: json['seen'] == true,
    flagged: json['flagged'] == true,
    answered: json['answered'] == true,
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
    hasAttachments: hasAttachments,
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

/// 읽기 — 본문은 글자(HTML 메일은 서버가 글자로 바꾼 것 — [wasHtml]).
class MailMessage {
  final int uid;
  final String subject;
  final MailAddress from;
  final List<MailAddress> to;
  final List<MailAddress> cc;
  final List<MailAddress> replyTo;
  final DateTime? date;
  final String text;
  final bool truncated;
  final bool wasHtml;
  final String? messageId;
  final List<String> references;
  final List<MailAttachment> attachments;
  final bool flagged;
  const MailMessage({
    required this.uid,
    required this.subject,
    required this.from,
    this.to = const [],
    this.cc = const [],
    this.replyTo = const [],
    this.date,
    this.text = '',
    this.truncated = false,
    this.wasHtml = false,
    this.messageId,
    this.references = const [],
    this.attachments = const [],
    this.flagged = false,
  });

  factory MailMessage.fromJson(Map<String, dynamic> json) => MailMessage(
    uid: (json['uid'] as num).toInt(),
    subject: json['subject'] as String? ?? tr('(제목 없음)'),
    from: MailAddress.fromJson(json['from']),
    to: _addresses(json['to']),
    cc: _addresses(json['cc']),
    replyTo: _addresses(json['replyTo']),
    date: json['date'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch((json['date'] as num).toInt()),
    text: json['text'] as String? ?? '',
    truncated: json['truncated'] == true,
    wasHtml: json['html'] == true,
    messageId: json['messageId'] as String?,
    references: [
      for (final r in json['references'] as List? ?? const [])
        if (r is String) r,
    ],
    attachments: [
      for (final a in json['attachments'] as List? ?? const [])
        MailAttachment.fromJson((a as Map).cast<String, dynamic>()),
    ],
    flagged: json['flagged'] == true,
  );
}

/// 쓰기 창에 채울 값 — 새 메일·답장·전체 답장·전달.
class MailDraft {
  final List<MailAddress> to;
  final List<MailAddress> cc;
  final String subject;
  final String text;
  final String? inReplyTo;
  final List<String> references;

  /// 답장한 원래 메일(보낸 뒤 답장 표시) — 폴더와 uid.
  final ({String folder, int uid})? answered;
  const MailDraft({
    this.to = const [],
    this.cc = const [],
    this.subject = '',
    this.text = '',
    this.inReplyTo,
    this.references = const [],
    this.answered,
  });
}

enum MailReplyKind { reply, replyAll, forward }

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
  );
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
