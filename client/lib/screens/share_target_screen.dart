import 'dart:io';

import 'package:cross_file/cross_file.dart';
import 'package:flutter/material.dart';

import '../models/room.dart';
import '../services/api_client.dart' show ApiException;
import '../services/session.dart';
import '../services/share_intake.dart';
import '../widgets/room_picker_field.dart';
import 'message_forward_screen.dart' show canForwardTo;

/// 다른 앱에서 "공유 → TangoTalk"으로 받은 글·파일을 보낼 대화방을 고르는 화면(안드로이드 — share_intake.dart). 글은 고쳐서 보낼 수
/// 있고 파일은 뺄 수 있다. 사진은 한 말풍선에 모아, 그 밖의 파일은 따로 모아 보낸다(입력칸과 같다). 비밀 대화·보드 뷰·쓸 수 없는
/// 토픽은 고를 수 없다(메시지 전달과 같은 규칙). 보냈으면 그 방을 돌려준다(호출부가 연다).
Future<Room?> showShareTargetScreen(
  BuildContext context, {
  required Session session,
  required SharedPayload payload,
}) => Navigator.of(context).push<Room>(
  MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => ShareTargetScreen(session: session, payload: payload),
  ),
);

class ShareTargetScreen extends StatefulWidget {
  final Session session;
  final SharedPayload payload;
  const ShareTargetScreen({
    super.key,
    required this.session,
    required this.payload,
  });

  @override
  State<ShareTargetScreen> createState() => _ShareTargetScreenState();
}

class _ShareTargetScreenState extends State<ShareTargetScreen> {
  Room? _room;
  late final _text = TextEditingController(text: widget.payload.text ?? '');
  late final _files = [...widget.payload.files];
  bool _sending = false;
  String? _error;
  String? _progress;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  bool get _canSend =>
      _room != null &&
      !_sending &&
      (_files.isNotEmpty || _text.text.trim().isNotEmpty);

  Future<void> _send() async {
    final room = _room;
    if (room == null) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    final controller = widget.session.controllerFor(room);
    try {
      final text = _text.text.trim();
      if (_files.isEmpty) {
        await controller.sendText(text);
      } else {
        final uploaded = await controller.uploadLocalFiles(
          [
            for (final f in _files)
              XFile(f.path, name: f.name, mimeType: f.mimeType),
          ],
          onProgress: (index, sent, total) {
            if (mounted) {
              setState(() => _progress = '올리는 중 ${index + 1}/${_files.length}');
            }
          },
        );
        final images = [
          for (final u in uploaded)
            if (u.isImage) u,
        ];
        final others = [
          for (final u in uploaded)
            if (!u.isImage) u,
        ];
        var caption = text.isEmpty ? null : text;
        if (images.isNotEmpty) {
          await controller.sendUploadedAttachments(images, caption: caption);
          caption = null;
        }
        if (others.isNotEmpty) {
          await controller.sendUploadedAttachments(others, caption: caption);
        }
        // 올렸으니 복사본은 지운다(남은 것은 안드로이드 쪽이 하루 뒤 정리한다).
        for (final f in _files) {
          try {
            await File(f.path).delete();
          } catch (_) {}
        }
      }
      if (mounted) Navigator.of(context).pop(room);
    } catch (e) {
      if (mounted) {
        setState(() {
          _sending = false;
          _progress = null;
          _error = e is ApiException
              ? e.message
              : '보내지 못했습니다. 연결을 확인하고 다시 시도하세요. ($e)';
        });
      }
    }
  }

  String _size(int? bytes) {
    if (bytes == null) return '';
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).round()}KB';
    return '$bytes바이트';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('공유하기'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              key: const ValueKey('share-send'),
              onPressed: _canSend ? _send : null,
              child: _sending
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('보내기'),
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
            key: const ValueKey('share-text'),
            controller: _text,
            minLines: 2,
            maxLines: 8,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              labelText: '메시지',
              border: OutlineInputBorder(),
            ),
          ),
          if (_files.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text('파일 ${_files.length}개', style: theme.textTheme.titleSmall),
            for (final f in _files)
              ListTile(
                key: ValueKey('share-file-${f.name}'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: f.isImage
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: Image.file(
                          File(f.path),
                          width: 40,
                          height: 40,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) =>
                              const Icon(Icons.image_outlined),
                        ),
                      )
                    : const Icon(Icons.insert_drive_file_outlined),
                title: Text(f.name, overflow: TextOverflow.ellipsis),
                subtitle: Text(_size(f.size)),
                trailing: IconButton(
                  tooltip: '빼기',
                  icon: const Icon(Icons.close),
                  onPressed: _sending
                      ? null
                      : () => setState(() => _files.remove(f)),
                ),
              ),
          ],
          if (_progress != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_progress!, style: TextStyle(color: theme.hintColor)),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _error!,
                key: const ValueKey('share-error'),
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
          const SizedBox(height: 8),
          Text(
            '비밀 대화·보드 뷰 토픽·쓸 수 없는 토픽은 고를 수 없습니다.',
            style: TextStyle(fontSize: 12, color: theme.hintColor),
          ),
        ],
      ),
    );
  }
}
