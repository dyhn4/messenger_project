import 'package:flutter/material.dart';

import '../../l10n/tr.dart';
import '../../models/mail.dart';
import '../../models/room.dart';
import '../../models/uploaded_attachment.dart';
import '../../services/api_client.dart' show ApiException;
import '../../services/mail_api.dart';
import '../../services/session.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/room_picker_field.dart';
import '../message_forward_screen.dart' show canForwardTo;
import '../todo_editor_dialog.dart' show showTodoEditor;

/// 메일을 대화방·할 일로 보내기 — 메일의 첨부(·원문 .eml)는 서버가 내 업로드 파일로 옮겨 주고(server webmail.js /mail/export), 그 파일과
/// 메일 요약 글(제목·보낸 사람·본문 앞부분 — mail.dart mailShareText)로 대화방 메시지나 할 일을 만든다. 비밀 대화·보드·쓸 수 없는
/// 토픽은 고를 수 없다(메시지 전달과 같은 규칙).

/// 내보낸 파일 → 대화방·할 일에 붙일 첨부.
List<UploadedAttachment> _uploadedOf(
  List<({String url, String fileName, int size, String? mimeType})> files,
) => [
  for (final f in files)
    UploadedAttachment(
      isImage: RegExp(
        r'^image/(png|jpe?g|gif|webp)$',
      ).hasMatch(f.mimeType ?? ''),
      url: f.url,
      fileName: f.fileName,
      size: f.size,
      mimeType: f.mimeType,
    ),
];

/// 첨부 고르기 칸 — 메일의 첨부마다와 "원문(.eml)".
class _AttachmentPicks extends StatelessWidget {
  final MailMessage message;
  final Set<int> picked;
  final bool eml;
  final ValueChanged<int> onToggle;
  final ValueChanged<bool> onEml;
  const _AttachmentPicks({
    required this.message,
    required this.picked,
    required this.eml,
    required this.onToggle,
    required this.onEml,
  });

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      for (final a in message.attachments)
        CheckboxListTile(
          key: ValueKey('mail-share-attachment-${a.index}'),
          dense: true,
          contentPadding: EdgeInsets.zero,
          value: picked.contains(a.index),
          title: Text('${a.fileName} (${mailSizeText(a.size)})'),
          onChanged: (_) => onToggle(a.index),
        ),
      CheckboxListTile(
        key: const ValueKey('mail-share-eml'),
        dense: true,
        contentPadding: EdgeInsets.zero,
        value: eml,
        title: Text(tr('메일 원문(.eml) 첨부')),
        subtitle: Text(tr('받는 사람이 메일 프로그램으로 원래 모양 그대로 열 수 있습니다.')),
        onChanged: (v) => onEml(v ?? false),
      ),
    ],
  );
}

/// 메일을 대화방으로 보내는 화면 — 보냈으면 그 방.
Future<Room?> showMailToRoom(
  BuildContext context, {
  required Session session,
  required MailApi api,
  required String account,
  required String folder,
  required MailMessage message,
}) => Navigator.of(context).push<Room>(
  MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => MailToRoomScreen(
      session: session,
      api: api,
      account: account,
      folder: folder,
      message: message,
    ),
  ),
);

class MailToRoomScreen extends StatefulWidget {
  final Session session;
  final MailApi api;
  final String account;
  final String folder;
  final MailMessage message;
  const MailToRoomScreen({
    super.key,
    required this.session,
    required this.api,
    required this.account,
    required this.folder,
    required this.message,
  });

  @override
  State<MailToRoomScreen> createState() => _MailToRoomScreenState();
}

class _MailToRoomScreenState extends State<MailToRoomScreen> {
  Room? _room;
  late final _text = TextEditingController(text: mailShareText(widget.message));
  late final _picked = {for (final a in widget.message.attachments) a.index};
  bool _eml = false;
  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final room = _room;
    if (room == null) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final files = _picked.isEmpty && !_eml
          ? const <
              ({String url, String fileName, int size, String? mimeType})
            >[]
          : await widget.api.export(
              widget.account,
              widget.folder,
              widget.message.uid,
              attachments: _picked.toList()..sort(),
              eml: _eml,
            );
      final controller = widget.session.controllerFor(room);
      final text = _text.text.trim();
      final uploaded = _uploadedOf(files);
      if (uploaded.isEmpty) {
        await controller.sendText(text);
      } else {
        final images = [
          for (final u in uploaded)
            if (u.isImage) u,
        ];
        final others = [
          for (final u in uploaded)
            if (!u.isImage) u,
        ];
        var caption = text.isEmpty ? null : text;
        if (others.isNotEmpty) {
          await controller.sendUploadedAttachments(others, caption: caption);
          caption = null;
        }
        if (images.isNotEmpty) {
          await controller.sendUploadedAttachments(images, caption: caption);
        }
      }
      if (mounted) Navigator.of(context).pop(room);
    } catch (e) {
      if (mounted) {
        setState(() {
          _sending = false;
          _error = e is ApiException
              ? trServer(e.message)
              : tr('보내지 못했습니다. 연결을 확인하고 다시 시도하세요. ({e})', {'e': e});
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('대화방으로 보내기')),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              key: const ValueKey('mail-share-send'),
              onPressed: _room == null || _sending ? null : _send,
              child: _sending
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(tr('보내기')),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          RoomPickerField(
            session: widget.session,
            value: _room,
            filter: (r) => canForwardTo(widget.session, r),
            onChanged: (r) => setState(() => _room = r),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('mail-share-text'),
            controller: _text,
            minLines: 3,
            maxLines: 12,
            decoration: InputDecoration(
              labelText: tr('메시지'),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          _AttachmentPicks(
            message: widget.message,
            picked: _picked,
            eml: _eml,
            onToggle: (i) => setState(
              () => _picked.contains(i) ? _picked.remove(i) : _picked.add(i),
            ),
            onEml: (v) => setState(() => _eml = v),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _error!,
                key: const ValueKey('mail-share-error'),
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
        ],
      ),
    );
  }
}

/// 메일로 할 일 만들기 — 첨부가 있으면 무엇을 붙일지 먼저 묻고(서버가 내 파일로 옮김), 제목은 메일 제목, 설명은 메일 요약으로 채운
/// 할 일 만들기 창을 연다(대화방·담당자·기간은 거기서). 만들었으면 true.
Future<bool> createTodoFromMail(
  BuildContext context, {
  required Session session,
  required MailApi api,
  required String account,
  required String folder,
  required MailMessage message,
}) async {
  var picked = <int>{};
  var eml = false;
  if (message.attachments.isNotEmpty) {
    final choice = await showDialog<({Set<int> picked, bool eml})>(
      context: context,
      builder: (_) => _TodoAttachmentDialog(message: message),
    );
    if (choice == null || !context.mounted) return false;
    picked = choice.picked;
    eml = choice.eml;
  }
  var attachments = const <UploadedAttachment>[];
  if (picked.isNotEmpty || eml) {
    try {
      attachments = _uploadedOf(
        await api.export(
          account,
          folder,
          message.uid,
          attachments: picked.toList()..sort(),
          eml: eml,
        ),
      );
    } catch (e) {
      if (context.mounted) {
        showAppToast(
          context,
          e is ApiException ? trServer(e.message) : tr('첨부를 옮기지 못했습니다.'),
        );
      }
      return false;
    }
  }
  if (!context.mounted) return false;
  final title = message.subject.length > 100
      ? message.subject.substring(0, 100)
      : message.subject;
  final description = mailShareText(message, max: 1500);
  final todo = await showTodoEditor(
    context,
    session: session,
    initialTitle: title,
    initialDescription: description.length > 2000
        ? description.substring(0, 2000)
        : description,
    initialAttachments: attachments,
  );
  return todo != null;
}

class _TodoAttachmentDialog extends StatefulWidget {
  final MailMessage message;
  const _TodoAttachmentDialog({required this.message});

  @override
  State<_TodoAttachmentDialog> createState() => _TodoAttachmentDialogState();
}

class _TodoAttachmentDialogState extends State<_TodoAttachmentDialog> {
  late final _picked = {for (final a in widget.message.attachments) a.index};
  bool _eml = false;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(tr('할 일에 붙일 첨부')),
    content: SizedBox(
      width: 420,
      child: SingleChildScrollView(
        child: _AttachmentPicks(
          message: widget.message,
          picked: _picked,
          eml: _eml,
          onToggle: (i) => setState(
            () => _picked.contains(i) ? _picked.remove(i) : _picked.add(i),
          ),
          onEml: (v) => setState(() => _eml = v),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: Text(tr('취소')),
      ),
      FilledButton(
        key: const ValueKey('mail-todo-next'),
        onPressed: () =>
            Navigator.of(context).pop((picked: {..._picked}, eml: _eml)),
        child: Text(tr('다음')),
      ),
    ],
  );
}
