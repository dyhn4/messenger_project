import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../models/mail.dart';
import '../../services/api_client.dart' show ApiException;
import '../../services/mail_api.dart';
import '../../services/session.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/rich_text_format.dart';
import '../../l10n/tr.dart';

/// 쓰기 창을 닫은 결과 — 보냄·임시 저장함·그냥 닫음.
enum MailComposeOutcome { sent, saved, closed }

/// 메일 쓰기 — 보내는 계정(여럿이면 고름), 받는 사람·참조·숨은 참조(쉼표로 여러 명, 쓰는 동안 자동 완성 — 같은 팀 주소록과 보낸 적 있는
/// 바깥 주소, "주소록"으로 같은 팀에서 메일을 연결한 사람 고르기), 제목, 본문(서식 — 굵게·기울임·밑줄·취소선·글자색·제목·인용·목록·링크,
/// 공지와 같은 도구모음 — 서식을 쓰면 서버가 HTML 본문도 함께 보낸다. 계정의 서명이 저절로 — 새 메일은 끝, 답장·전달은 인용 앞),
/// 첨부(20MB까지). 답장·전달·임시 저장본 이어 쓰기면 [draft]에 채워 온다(mail.dart draftFrom·draftFromSaved). **임시 저장**은
/// 단추·닫을 때 묻기·1분마다(바뀐 게 있으면) 임시보관함에 넣는다(앞의 저장본은 서버가 지운다).
Future<MailComposeOutcome> showMailCompose(
  BuildContext context, {
  required Session session,
  MailApi? api,
  MailDraft draft = const MailDraft(),
  List<MailAccount> accounts = const [],
}) async {
  final result = await Navigator.of(context).push<MailComposeOutcome>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => MailComposeScreen(
        session: session,
        api: api ?? session.mailApi,
        draft: draft,
        accounts: accounts,
      ),
    ),
  );
  return result ?? MailComposeOutcome.closed;
}

/// 첨부 합계 상한 — 서버 webmailRules.js SEND_ATTACHMENTS_BYTES_MAX.
const kMailAttachmentsBytesMax = 20 * 1024 * 1024;
const kMailAttachmentsMax = 10;

/// 바뀐 게 있으면 이만큼마다 저절로 임시 저장한다.
const kMailAutosaveInterval = Duration(minutes: 1);

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

/// 쓰는 중인 마지막 주소(마지막 쉼표·세미콜론 뒤) — 자동 완성이 찾을 글.
String lastAddressToken(String text) {
  final i = text.lastIndexOf(RegExp(r'[,;\n]'));
  return text.substring(i + 1).trim();
}

/// 마지막 주소를 [wire]로 바꾸고 다음 주소를 쓸 수 있게 ", "를 붙인다.
String replaceLastAddress(String text, String wire) {
  final i = text.lastIndexOf(RegExp(r'[,;\n]'));
  final head = i < 0 ? '' : '${text.substring(0, i + 1).trimRight()} ';
  return '$head$wire, ';
}

class MailComposeScreen extends StatefulWidget {
  final Session session;
  final MailApi api;
  final MailDraft draft;

  /// 보낼 수 있는 계정들 — 둘 이상이면 보내는 계정을 고른다(비면 서버의 기본 계정).
  final List<MailAccount> accounts;
  const MailComposeScreen({
    super.key,
    required this.session,
    required this.api,
    this.draft = const MailDraft(),
    this.accounts = const [],
  });

  @override
  State<MailComposeScreen> createState() => _MailComposeScreenState();
}

typedef _Upload = ({String url, String name, int size, String? mimeType});

class _MailComposeScreenState extends State<MailComposeScreen> {
  late String _accountId =
      widget.draft.accountId ??
      (widget.accounts.isNotEmpty ? widget.accounts.first.id : '');
  late final _to = TextEditingController(
    text: widget.draft.to.map((a) => a.wire).join(', '),
  );
  late final _cc = TextEditingController(
    text: widget.draft.cc.map((a) => a.wire).join(', '),
  );
  late final _bcc = TextEditingController(
    text: widget.draft.bcc.map((a) => a.wire).join(', '),
  );
  late final _subject = TextEditingController(text: widget.draft.subject);
  late final _body = RichTextEditingController(
    text: withSignature(
      widget.draft.text,
      _signatureFor(_accountId),
      widget.draft.signatureSlot,
    ),
  );
  final _bodyFocus = FocusNode();
  late bool _showCc = widget.draft.cc.isNotEmpty || widget.draft.bcc.isNotEmpty;
  final _uploads = <_Upload>[];

  /// 이어 쓰는 임시 저장본과 그 안의 첨부(보낼 때 서버가 꺼내 싣는다).
  late ({String folder, int uid})? _saved = widget.draft.saved;
  late final _savedAttachments = [...widget.draft.savedAttachments];
  bool _uploading = false;
  bool _sending = false;
  bool _saving = false;
  String? _error;
  Timer? _autosave;

  /// 마지막으로 저장한(또는 연) 내용 — 바뀌었는지 볼 때.
  late String _savedSnapshot;

  @override
  void initState() {
    super.initState();
    // 서식 있는 임시 저장본을 이어 쓰면 서식을 되살린다(서명은 이미 들어 있어 본문 그대로).
    final format = widget.draft.format;
    if (format != null &&
        widget.draft.signatureSlot == MailSignatureSlot.none) {
      _body.load(widget.draft.text, format);
    }
    _savedSnapshot = _snapshot();
    _autosave = Timer.periodic(kMailAutosaveInterval, (_) {
      if (_changedSinceSave && !_sending && !_saving && !_uploading) {
        unawaited(_saveDraft(quiet: true));
      }
    });
  }

  @override
  void dispose() {
    _autosave?.cancel();
    for (final c in [_to, _cc, _bcc, _subject, _body]) {
      c.dispose();
    }
    _bodyFocus.dispose();
    super.dispose();
  }

  MailAccount? _accountOf(String id) {
    for (final a in widget.accounts) {
      if (a.id == id) return a;
    }
    return null;
  }

  /// 이 계정에서 이 초안에 붙일 서명(꺼져 있으면 빈 글).
  String _signatureFor(String id) {
    final a = _accountOf(id);
    if (a == null) return '';
    return switch (widget.draft.signatureSlot) {
      MailSignatureSlot.fresh => a.signatureOnNew ? a.signature : '',
      MailSignatureSlot.reply => a.signatureOnReply ? a.signature : '',
      MailSignatureSlot.none => '',
    };
  }

  String _snapshot() => [
    _accountId,
    _to.text,
    _cc.text,
    _bcc.text,
    _subject.text,
    _body.text,
    jsonEncode(textFormatToJson(_body.snapshot().format)),
    _uploads.length,
    _savedAttachments.length,
  ].join('\u0000');

  bool get _changedSinceSave => _snapshot() != _savedSnapshot;

  bool get _dirty =>
      _to.text.trim().isNotEmpty ||
      _subject.text.trim() != widget.draft.subject.trim() ||
      _body.text.trim() !=
          withSignature(
            widget.draft.text,
            _signatureFor(_accountId),
            widget.draft.signatureSlot,
          ).trim() ||
      _uploads.isNotEmpty;

  void _switchAccount(String id) {
    if (id == _accountId) return;
    final slot = widget.draft.signatureSlot == MailSignatureSlot.none
        ? MailSignatureSlot.fresh
        : widget.draft.signatureSlot;
    _body.text = swapSignature(
      _body.text,
      _signatureFor(_accountId),
      _signatureFor(id),
      slot,
    );
    setState(() => _accountId = id);
  }

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
    if (_uploads.length + _savedAttachments.length + files.length >
        kMailAttachmentsMax) {
      if (mounted) {
        showAppToast(
          context,
          tr('첨부는 {kMailAttachmentsMax}개까지입니다.', {
            'kMailAttachmentsMax': kMailAttachmentsMax,
          }),
        );
      }
      return;
    }
    setState(() => _uploading = true);
    try {
      for (final f in files) {
        final up = await widget.session.api!.uploadFile(f);
        _uploads.add((
          url: up.url,
          name: up.fileName,
          size: up.size,
          mimeType: up.mimeType,
        ));
        if (mounted) setState(() {});
      }
    } catch (e) {
      if (mounted) showAppToast(context, tr('첨부하지 못했습니다: {e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  List<Map<String, dynamic>> get _uploadBodies => [
    for (final a in _uploads)
      {'fileUrl': a.url, 'fileName': a.name, 'mimeType': ?a.mimeType},
  ];

  int get _attachmentBytes =>
      _uploads.fold<int>(0, (s, a) => s + a.size) +
      _savedAttachments.fold<int>(0, (s, a) => s + a.size);

  /// 보낼(저장할) 본문 — 앞뒤 빈 줄까지 그대로(답장은 인용 앞에 빈 줄이 있다)와 서식 구간.
  ({String text, List<Map<String, dynamic>>? format}) get _bodyOut {
    final b = _body.snapshot();
    return (text: b.text, format: textFormatToJson(b.format));
  }

  /// 임시 저장 — 새 저장본을 기억하고(올린 첨부는 이제 저장본 안에 있다), [quiet]가 아니면 알린다. 저장했으면 true.
  Future<bool> _saveDraft({bool quiet = false}) async {
    if (_saving) return false;
    setState(() => _saving = true);
    try {
      final body = _bodyOut;
      final saved = await widget.api.saveDraft(
        account: _accountId,
        to: splitAddresses(_to.text),
        cc: splitAddresses(_cc.text),
        bcc: splitAddresses(_bcc.text),
        subject: _subject.text.trim(),
        text: body.text,
        format: body.format,
        attachments: _uploadBodies,
        savedAttachments: [for (final a in _savedAttachments) a.index],
        saved: _saved,
        inReplyTo: widget.draft.inReplyTo,
        references: widget.draft.references,
      );
      if (!mounted) return true;
      // 새 저장본의 첨부 차례 — 올린 파일들 다음에 이어 온 첨부(서버 webmail.js collectAttachments와 같은 차례).
      final next = <MailAttachment>[
        for (final (i, a) in _uploads.indexed)
          MailAttachment(
            index: i,
            fileName: a.name,
            contentType: a.mimeType,
            size: a.size,
          ),
        for (final (j, a) in _savedAttachments.indexed)
          MailAttachment(
            index: _uploads.length + j,
            fileName: a.fileName,
            contentType: a.contentType,
            size: a.size,
          ),
      ];
      setState(() {
        _saved = saved;
        _uploads.clear();
        _savedAttachments
          ..clear()
          ..addAll(next);
        _saving = false;
        _savedSnapshot = _snapshot();
        if (!quiet) _error = null;
      });
      if (!quiet) showAppToast(context, tr('임시보관함에 저장했습니다.'));
      return true;
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          if (!quiet) {
            _error = e is ApiException
                ? trServer(e.message)
                : tr('임시 저장하지 못했습니다.');
          }
        });
      }
      return false;
    }
  }

  Future<void> _send() async {
    final to = splitAddresses(_to.text);
    final cc = splitAddresses(_cc.text);
    final bcc = splitAddresses(_bcc.text);
    final bad = firstBadAddress([...to, ...cc, ...bcc]);
    String? problem;
    if (to.isEmpty && cc.isEmpty && bcc.isEmpty) {
      problem = tr('받는 사람을 넣으세요.');
    } else if (bad != null) {
      problem = tr('주소가 올바르지 않습니다: {bad}', {'bad': bad});
    } else if (_subject.text.trim().isEmpty && _body.text.trim().isEmpty) {
      problem = tr('제목이나 본문을 넣으세요.');
    } else if (_attachmentBytes > kMailAttachmentsBytesMax) {
      problem = tr('첨부는 모두 합쳐 20MB까지입니다.');
    }
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    final body = _bodyOut;
    try {
      await widget.api.send(
        account: _accountId,
        to: to,
        cc: cc,
        bcc: bcc,
        subject: _subject.text.trim(),
        text: body.text,
        format: body.format,
        attachments: _uploadBodies,
        savedAttachments: [for (final a in _savedAttachments) a.index],
        saved: _saved,
        inReplyTo: widget.draft.inReplyTo,
        references: widget.draft.references,
        answered: widget.draft.answered,
      );
      if (!mounted) return;
      Navigator.of(context).pop(MailComposeOutcome.sent);
    } catch (e) {
      if (mounted) {
        setState(() {
          _sending = false;
          _error = e is ApiException ? trServer(e.message) : tr('보내지 못했습니다.');
        });
      }
    }
  }

  Future<void> _close() async {
    if (!_dirty || !_changedSinceSave) {
      Navigator.of(context).pop(
        _saved != null && _saved != widget.draft.saved
            ? MailComposeOutcome.saved
            : MailComposeOutcome.closed,
      );
      return;
    }
    final choice = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr('쓰기를 그만할까요?')),
        content: Text(tr('임시 저장하면 임시보관함에서 이어 쓸 수 있습니다.')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(tr('계속 쓰기')),
          ),
          TextButton(
            key: const ValueKey('mail-compose-discard'),
            onPressed: () => Navigator.of(dialogContext).pop('discard'),
            child: Text(tr('저장 안 함')),
          ),
          FilledButton(
            key: const ValueKey('mail-compose-keep-draft'),
            onPressed: () => Navigator.of(dialogContext).pop('save'),
            child: Text(tr('임시 저장')),
          ),
        ],
      ),
    );
    if (!mounted || choice == null) return;
    if (choice == 'save') {
      if (await _saveDraft(quiet: true) && mounted) {
        showAppToast(context, tr('임시보관함에 저장했습니다.'));
        Navigator.of(context).pop(MailComposeOutcome.saved);
      }
      return;
    }
    Navigator.of(context).pop(MailComposeOutcome.closed);
  }

  Widget _addressField(
    TextEditingController c,
    String label,
    String key, {
    Widget? trailing,
  }) => Row(
    children: [
      Expanded(
        child: _AddressAutocomplete(
          controller: c,
          fieldKey: key,
          label: label,
          api: widget.api,
          onChanged: () => setState(() {}),
        ),
      ),
      IconButton(
        tooltip: tr('주소록'),
        icon: const Icon(Icons.contacts_outlined),
        onPressed: () => _pickMembers(c),
      ),
      ?trailing,
    ],
  );

  /// 본문 — 위에 서식 도구모음(공지·노트와 같은 것 — 글자색·제목까지), 아래 입력칸(Ctrl+B·I·U, 인용 줄의 세로줄).
  Widget _bodyEditor(ThemeData theme) => Container(
    decoration: BoxDecoration(
      border: Border.all(color: theme.colorScheme.outline),
      borderRadius: BorderRadius.circular(4),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        RichFormatToolbar(
          key: const ValueKey('mail-compose-toolbar'),
          controller: _body,
          focusNode: _bodyFocus,
          showColor: true,
          showHeadings: true,
          showRule: true,
        ),
        Divider(height: 1, color: theme.dividerColor),
        RichFieldWrapper(
          controller: _body,
          child: TextField(
            key: const ValueKey('mail-compose-body'),
            controller: _body,
            focusNode: _bodyFocus,
            minLines: 12,
            maxLines: null,
            keyboardType: TextInputType.multiline,
            decoration: InputDecoration(
              hintText: tr('내용'),
              border: InputBorder.none,
              contentPadding: const EdgeInsets.all(12),
            ),
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final draft = widget.draft;
    final busy = _sending || _uploading || _saving;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            tooltip: tr('닫기'),
            icon: const Icon(Icons.close),
            onPressed: _close,
          ),
          title: Text(
            draft.saved != null
                ? tr('이어 쓰기')
                : draft.inReplyTo != null
                ? tr('답장')
                : tr('메일 쓰기'),
          ),
          actions: [
            IconButton(
              key: const ValueKey('mail-compose-attach'),
              tooltip: tr('파일 첨부'),
              icon: const Icon(Icons.attach_file),
              onPressed: busy ? null : _attach,
            ),
            IconButton(
              key: const ValueKey('mail-compose-save-draft'),
              tooltip: tr('임시 저장'),
              icon: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_outlined),
              onPressed: busy ? null : () => _saveDraft(),
            ),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilledButton.icon(
                key: const ValueKey('mail-compose-send'),
                onPressed: busy ? null : _send,
                icon: _sending
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.send, size: 18),
                label: Text(tr('보내기')),
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
                if (widget.accounts.length > 1)
                  DropdownButtonFormField<String>(
                    key: const ValueKey('mail-compose-from'),
                    initialValue: _accountId,
                    decoration: InputDecoration(
                      labelText: tr('보내는 계정'),
                      isDense: true,
                    ),
                    items: [
                      for (final a in widget.accounts)
                        DropdownMenuItem(
                          value: a.id,
                          child: Text(
                            a.displayName != null && a.displayName!.isNotEmpty
                                ? '${a.displayName} <${a.email}>'
                                : a.email,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    // 이어 쓰는 임시 저장본은 그 계정의 임시보관함에 있다 — 다른 계정으로 바꾸지 않는다.
                    onChanged: _saved != null
                        ? null
                        : (v) => _switchAccount(v ?? _accountId),
                  ),
                _addressField(
                  _to,
                  tr('받는 사람'),
                  'mail-compose-to',
                  trailing: TextButton(
                    key: const ValueKey('mail-compose-show-cc'),
                    onPressed: () => setState(() => _showCc = !_showCc),
                    child: Text(tr('참조')),
                  ),
                ),
                if (_showCc) ...[
                  _addressField(_cc, tr('참조'), 'mail-compose-cc'),
                  _addressField(_bcc, tr('숨은 참조'), 'mail-compose-bcc'),
                ],
                TextField(
                  key: const ValueKey('mail-compose-subject'),
                  controller: _subject,
                  maxLength: 300,
                  decoration: InputDecoration(
                    labelText: tr('제목'),
                    counterText: '',
                  ),
                ),
                if (_uploads.isNotEmpty ||
                    _savedAttachments.isNotEmpty ||
                    _uploading)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        for (final a in _savedAttachments)
                          InputChip(
                            key: ValueKey('mail-compose-saved-${a.index}'),
                            avatar: const Icon(
                              Icons.insert_drive_file_outlined,
                              size: 16,
                            ),
                            label: Text(
                              '${a.fileName} (${mailSizeText(a.size)})',
                            ),
                            onDeleted: () =>
                                setState(() => _savedAttachments.remove(a)),
                          ),
                        for (final a in _uploads)
                          InputChip(
                            avatar: const Icon(
                              Icons.insert_drive_file_outlined,
                              size: 16,
                            ),
                            label: Text('${a.name} (${mailSizeText(a.size)})'),
                            onDeleted: () => setState(() => _uploads.remove(a)),
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
                _bodyEditor(theme),
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

/// 받는 사람 칸 — 쓰는 동안 마지막 주소로 후보를 찾는다(같은 팀 주소록·보낸 적 있는 바깥 주소 — server /mail/contacts). 고르면
/// 그 주소로 바꾸고 ", "를 붙인다. 바깥 주소 후보는 ✕로 자동 완성에서 지운다.
class _AddressAutocomplete extends StatefulWidget {
  final TextEditingController controller;
  final String fieldKey;
  final String label;
  final MailApi api;
  final VoidCallback onChanged;
  const _AddressAutocomplete({
    required this.controller,
    required this.fieldKey,
    required this.label,
    required this.api,
    required this.onChanged,
  });

  @override
  State<_AddressAutocomplete> createState() => _AddressAutocompleteState();
}

class _AddressAutocompleteState extends State<_AddressAutocomplete> {
  final _focus = FocusNode();
  final _forgotten = <String>{};

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  Future<Iterable<MailContact>> _options(TextEditingValue value) async {
    final token = lastAddressToken(value.text);
    if (token.isEmpty || token.contains('<')) return const [];
    try {
      final list = await widget.api.contacts(token);
      return [
        for (final c in list)
          if (!_forgotten.contains(c.address)) c,
      ];
    } catch (_) {
      return const [];
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return RawAutocomplete<MailContact>(
      textEditingController: widget.controller,
      focusNode: _focus,
      optionsBuilder: _options,
      displayStringForOption: (c) =>
          replaceLastAddress(widget.controller.text, c.wire),
      onSelected: (_) => widget.onChanged(),
      fieldViewBuilder: (context, controller, focusNode, onSubmitted) =>
          TextField(
            key: ValueKey(widget.fieldKey),
            controller: controller,
            focusNode: focusNode,
            keyboardType: TextInputType.emailAddress,
            onChanged: (_) => widget.onChanged(),
            decoration: InputDecoration(
              labelText: widget.label,
              hintText: tr('쉼표로 여러 명'),
              isDense: true,
            ),
          ),
      optionsViewBuilder: (context, onSelected, options) => Align(
        alignment: Alignment.topLeft,
        child: Material(
          elevation: 4,
          borderRadius: BorderRadius.circular(8),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 260, maxWidth: 480),
            child: ListView(
              padding: EdgeInsets.zero,
              shrinkWrap: true,
              children: [
                for (final c in options)
                  ListTile(
                    key: ValueKey('mail-suggest-${c.address}'),
                    dense: true,
                    leading: Icon(
                      c.member ? Icons.badge_outlined : Icons.history,
                      size: 18,
                      color: theme.hintColor,
                    ),
                    title: Text(c.name.isNotEmpty ? c.name : c.address),
                    subtitle: c.name.isNotEmpty ? Text(c.address) : null,
                    trailing: c.member
                        ? null
                        : IconButton(
                            tooltip: tr('자동 완성에서 지우기'),
                            icon: const Icon(Icons.close, size: 16),
                            onPressed: () async {
                              setState(() => _forgotten.add(c.address));
                              try {
                                await widget.api.forgetContact(c.address);
                              } catch (_) {}
                            },
                          ),
                    onTap: () => onSelected(c),
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
            setState(
              () => _error = e is ApiException ? trServer(e.message) : '$e',
            );
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
      title: Text(tr('주소록')),
      content: SizedBox(
        width: 400,
        height: 420,
        child: Column(
          children: [
            TextField(
              key: const ValueKey('mail-directory-filter'),
              controller: _filter,
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 20),
                hintText: tr('이름·주소'),
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
                        tr('같은 팀에서 메일 계정을 연결한 사람이 없습니다.'),
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
          child: Text(tr('취소')),
        ),
        FilledButton(
          key: const ValueKey('mail-directory-done'),
          onPressed: () => Navigator.of(context).pop([
            for (final p in _people ?? const <({String name, String email})>[])
              if (_picked.contains(p.email))
                MailAddress(name: p.name, address: p.email),
          ]),
          child: Text(
            tr('더하기 ({_picked.length})', {'_picked.length': _picked.length}),
          ),
        ),
      ],
    );
  }
}
