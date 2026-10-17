import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../models/mail.dart';
import '../../services/api_client.dart' show ApiException;
import '../../services/mail_api.dart';
import '../../services/session.dart';
import '../../widgets/app_toast.dart';

/// 메일 쓰기 — 받는 사람·참조·숨은 참조(쉼표로 여러 명, "주소록"으로 같은 팀에서 메일을 연결한 사람 고르기), 제목, 본문, 첨부(20MB까지). 답장·전달이면 [draft]에
/// 채워 온다(mail.dart draftFrom). 보냈으면 true.
Future<bool> showMailCompose(
  BuildContext context, {
  required Session session,
  MailApi? api,
  MailDraft draft = const MailDraft(),
}) async {
  final sent = await Navigator.of(context).push<bool>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => MailComposeScreen(
        session: session,
        api: api ?? session.mailApi,
        draft: draft,
      ),
    ),
  );
  return sent == true;
}

/// 첨부 합계 상한 — 서버 webmailRules.js SEND_ATTACHMENTS_BYTES_MAX.
const kMailAttachmentsBytesMax = 20 * 1024 * 1024;
const kMailAttachmentsMax = 10;

/// 쉼표·세미콜론·줄바꿈으로 나눈 주소들(빈 것은 뺌).
List<String> splitAddresses(String text) => [
  for (final part in text.split(RegExp(r'[,;\n]')))
    if (part.trim().isNotEmpty) part.trim(),
];

/// 주소 모양이 아닌 첫 항목(없으면 null) — "이름 <주소>"도 된다.
String? firstBadAddress(List<String> list) {
  final re = RegExp(r'^(?:.*<\s*)?[^\s@<>]+@[^\s@<>]+\.[^\s@<>]+(?:\s*>)?$');
  for (final a in list) {
    if (!re.hasMatch(a)) return a;
  }
  return null;
}

class MailComposeScreen extends StatefulWidget {
  final Session session;
  final MailApi api;
  final MailDraft draft;
  const MailComposeScreen({
    super.key,
    required this.session,
    required this.api,
    this.draft = const MailDraft(),
  });

  @override
  State<MailComposeScreen> createState() => _MailComposeScreenState();
}

class _MailComposeScreenState extends State<MailComposeScreen> {
  late final _to = TextEditingController(
    text: widget.draft.to.map((a) => a.wire).join(', '),
  );
  late final _cc = TextEditingController(
    text: widget.draft.cc.map((a) => a.wire).join(', '),
  );
  final _bcc = TextEditingController();
  late final _subject = TextEditingController(text: widget.draft.subject);
  late final _body = TextEditingController(text: widget.draft.text);
  late bool _showCc = widget.draft.cc.isNotEmpty;
  final _attachments =
      <({String url, String name, int size, String? mimeType})>[];
  bool _uploading = false;
  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_to, _cc, _bcc, _subject, _body]) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _dirty =>
      _to.text.trim().isNotEmpty ||
      _subject.text.trim() != widget.draft.subject.trim() ||
      _body.text.trim() != widget.draft.text.trim() ||
      _attachments.isNotEmpty;

  /// 주소록(같은 팀에서 메일 계정을 연결한 사람 — server webmail.js /mail/directory)에서 골라 [field]에 더한다.
  Future<void> _pickMembers(TextEditingController field) async {
    final picked = await showDialog<List<MailAddress>>(
      context: context,
      builder: (_) => _DirectoryDialog(api: widget.api),
    );
    if (picked == null || picked.isEmpty || !mounted) return;
    final existing = splitAddresses(field.text);
    final have = {for (final a in existing) a.toLowerCase()};
    field.text = [
      ...existing,
      for (final a in picked)
        if (!have.any((h) => h.contains(a.address.toLowerCase()))) a.wire,
    ].join(', ');
    setState(() {});
  }

  Future<void> _attach() async {
    final picked = await FilePicker.pickFiles(allowMultiple: true);
    final files = [
      for (final f in picked?.files ?? const <PlatformFile>[])
        if (f.path != null || f.bytes != null) f.xFile,
    ];
    if (files.isEmpty) return;
    if (_attachments.length + files.length > kMailAttachmentsMax) {
      if (mounted) showAppToast(context, '첨부는 $kMailAttachmentsMax개까지입니다.');
      return;
    }
    setState(() => _uploading = true);
    try {
      for (final f in files) {
        final up = await widget.session.api!.uploadFile(f);
        _attachments.add((
          url: up.url,
          name: up.fileName,
          size: up.size,
          mimeType: up.mimeType,
        ));
        if (mounted) setState(() {});
      }
    } catch (e) {
      if (mounted) showAppToast(context, '첨부하지 못했습니다: $e');
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _send() async {
    final to = splitAddresses(_to.text);
    final cc = splitAddresses(_cc.text);
    final bcc = splitAddresses(_bcc.text);
    final bad = firstBadAddress([...to, ...cc, ...bcc]);
    String? problem;
    if (to.isEmpty && cc.isEmpty && bcc.isEmpty) {
      problem = '받는 사람을 넣으세요.';
    } else if (bad != null) {
      problem = '주소가 올바르지 않습니다: $bad';
    } else if (_subject.text.trim().isEmpty && _body.text.trim().isEmpty) {
      problem = '제목이나 본문을 넣으세요.';
    } else if (_attachments.fold<int>(0, (s, a) => s + a.size) >
        kMailAttachmentsBytesMax) {
      problem = '첨부는 모두 합쳐 20MB까지입니다.';
    }
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await widget.api.send(
        to: to,
        cc: cc,
        bcc: bcc,
        subject: _subject.text.trim(),
        text: _body.text,
        attachments: [
          for (final a in _attachments)
            {'fileUrl': a.url, 'fileName': a.name, 'mimeType': ?a.mimeType},
        ],
        inReplyTo: widget.draft.inReplyTo,
        references: widget.draft.references,
        answered: widget.draft.answered,
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _sending = false;
          _error = e is ApiException ? e.message : '보내지 못했습니다.';
        });
      }
    }
  }

  Future<void> _close() async {
    if (!_dirty) {
      Navigator.of(context).pop(false);
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('쓰기를 그만할까요?'),
        content: const Text('쓴 내용은 저장되지 않습니다.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('계속 쓰기'),
          ),
          FilledButton(
            key: const ValueKey('mail-compose-discard'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('그만두기'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) Navigator.of(context).pop(false);
  }

  Widget _addressField(
    TextEditingController c,
    String label,
    String key, {
    Widget? trailing,
  }) => Row(
    children: [
      Expanded(
        child: TextField(
          key: ValueKey(key),
          controller: c,
          keyboardType: TextInputType.emailAddress,
          decoration: InputDecoration(
            labelText: label,
            hintText: '쉼표로 여러 명',
            isDense: true,
          ),
        ),
      ),
      IconButton(
        tooltip: '주소록',
        icon: const Icon(Icons.contacts_outlined),
        onPressed: () => _pickMembers(c),
      ),
      ?trailing,
    ],
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final account = widget.draft;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            tooltip: '닫기',
            icon: const Icon(Icons.close),
            onPressed: _close,
          ),
          title: Text(account.inReplyTo != null ? '답장' : '메일 쓰기'),
          actions: [
            IconButton(
              key: const ValueKey('mail-compose-attach'),
              tooltip: '파일 첨부',
              icon: const Icon(Icons.attach_file),
              onPressed: _uploading || _sending ? null : _attach,
            ),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilledButton.icon(
                key: const ValueKey('mail-compose-send'),
                onPressed: _sending || _uploading ? null : _send,
                icon: _sending
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.send, size: 18),
                label: const Text('보내기'),
              ),
            ),
          ],
        ),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 860),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                _addressField(
                  _to,
                  '받는 사람',
                  'mail-compose-to',
                  trailing: TextButton(
                    key: const ValueKey('mail-compose-show-cc'),
                    onPressed: () => setState(() => _showCc = !_showCc),
                    child: const Text('참조'),
                  ),
                ),
                if (_showCc) ...[
                  _addressField(_cc, '참조', 'mail-compose-cc'),
                  _addressField(_bcc, '숨은 참조', 'mail-compose-bcc'),
                ],
                TextField(
                  key: const ValueKey('mail-compose-subject'),
                  controller: _subject,
                  maxLength: 300,
                  decoration: const InputDecoration(
                    labelText: '제목',
                    counterText: '',
                  ),
                ),
                if (_attachments.isNotEmpty || _uploading)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        for (final a in _attachments)
                          InputChip(
                            avatar: const Icon(
                              Icons.insert_drive_file_outlined,
                              size: 16,
                            ),
                            label: Text('${a.name} (${mailSizeText(a.size)})'),
                            onDeleted: () =>
                                setState(() => _attachments.remove(a)),
                          ),
                        if (_uploading)
                          const Padding(
                            padding: EdgeInsets.all(6),
                            child: SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ),
                      ],
                    ),
                  ),
                const SizedBox(height: 8),
                TextField(
                  key: const ValueKey('mail-compose-body'),
                  controller: _body,
                  minLines: 12,
                  maxLines: null,
                  keyboardType: TextInputType.multiline,
                  decoration: const InputDecoration(
                    hintText: '내용',
                    border: OutlineInputBorder(),
                  ),
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      _error!,
                      key: const ValueKey('mail-compose-error'),
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 주소록 고르기 — 이름·주소로 거르고 여러 명을 고른다. 같은 팀에서 메일 계정을 연결한 사람만 나온다.
class _DirectoryDialog extends StatefulWidget {
  final MailApi api;
  const _DirectoryDialog({required this.api});

  @override
  State<_DirectoryDialog> createState() => _DirectoryDialogState();
}

class _DirectoryDialogState extends State<_DirectoryDialog> {
  List<({String name, String email})>? _people;
  final _picked = <String>{};
  final _filter = TextEditingController();
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.api
        .directory()
        .then((list) {
          if (mounted) setState(() => _people = list);
        })
        .catchError((Object e) {
          if (mounted) {
            setState(() => _error = e is ApiException ? e.message : '$e');
          }
        });
  }

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    final q = _filter.text.trim().toLowerCase();
    final people = [
      for (final p in _people ?? const <({String name, String email})>[])
        if (q.isEmpty ||
            p.name.toLowerCase().contains(q) ||
            p.email.toLowerCase().contains(q))
          p,
    ];
    return AlertDialog(
      title: const Text('주소록'),
      content: SizedBox(
        width: 400,
        height: 420,
        child: Column(
          children: [
            TextField(
              key: const ValueKey('mail-directory-filter'),
              controller: _filter,
              decoration: const InputDecoration(
                isDense: true,
                prefixIcon: Icon(Icons.search, size: 20),
                hintText: '이름·주소',
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: _people == null
                  ? Center(
                      child: _error != null
                          ? Text(_error!)
                          : const CircularProgressIndicator(),
                    )
                  : people.isEmpty
                  ? Center(
                      child: Text(
                        '같은 팀에서 메일 계정을 연결한 사람이 없습니다.',
                        style: TextStyle(color: hint),
                        textAlign: TextAlign.center,
                      ),
                    )
                  : ListView(
                      children: [
                        for (final p in people)
                          CheckboxListTile(
                            key: ValueKey('mail-directory-${p.email}'),
                            dense: true,
                            value: _picked.contains(p.email),
                            title: Text(p.name),
                            subtitle: Text(p.email),
                            onChanged: (v) => setState(
                              () => v == true
                                  ? _picked.add(p.email)
                                  : _picked.remove(p.email),
                            ),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        FilledButton(
          key: const ValueKey('mail-directory-done'),
          onPressed: () => Navigator.of(context).pop([
            for (final p in _people ?? const <({String name, String email})>[])
              if (_picked.contains(p.email))
                MailAddress(name: p.name, address: p.email),
          ]),
          child: Text('더하기 (${_picked.length})'),
        ),
      ],
    );
  }
}
