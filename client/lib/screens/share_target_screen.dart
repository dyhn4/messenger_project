import 'dart:io';

import 'package:cross_file/cross_file.dart';
import 'package:flutter/material.dart';

import '../models/room.dart';
import '../services/api_client.dart' show ApiException;
import '../models/uploaded_attachment.dart';
import '../services/session.dart';
import '../services/share_intake.dart';
import '../widgets/room_picker_field.dart';
import 'message_forward_screen.dart' show canForwardTo;
import '../l10n/tr.dart';

/// 한 번에 보낼 수 있는 대화방 수.
const shareRoomsMax = 10;

/// 다른 앱에서 받은 글·파일(안드로이드 "공유 → TangoTalk", Windows 탐색기 "보내기 → TangoTalk" — share_intake.dart)을 보낼 대화방을
/// 고르는 화면. 대화방은 [shareRoomsMax]곳까지 골라 한꺼번에 보내고, 비밀 대화도 고를 수 있다(이 기기에서 방마다 암호화해 보낸다 — 입력칸과
/// 같은 길). 글은 고쳐서 보낼 수 있고 파일은 뺄 수 있다. 사진은 한 말풍선에 모아, 그 밖의 파일은 따로 모아 보낸다(입력칸과 같다). 파일은
/// 일반 방들에 한 번, 비밀 대화들에 한 번(암호화해서)만 올리고 같은 첨부를 방마다 보낸다. 보드 뷰·쓸 수 없는 토픽은 고를 수 없다.
/// 다 보냈으면 보낸 방들을 돌려준다(호출부가 한 곳이면 그 방을 연다). 일부 방에 못 보냈으면 화면을 닫지 않고 못 보낸 방만 남겨 이유를 보인다.
Future<List<Room>?> showShareTargetScreen(
  BuildContext context, {
  required Session session,
  required SharedPayload payload,
}) => Navigator.of(context).push<List<Room>>(
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
  final _rooms = <Room>[];
  late final _text = TextEditingController(text: widget.payload.text ?? '');
  late final _files = [...widget.payload.files];

  /// 앞에서 보낸 방들 — 일부만 보냈을 때 다시 보내면 이것과 합쳐 돌려준다.
  final _sent = <Room>[];
  bool _sending = false;
  String? _error;
  String? _progress;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  bool get _canSend =>
      _rooms.isNotEmpty &&
      !_sending &&
      (_files.isNotEmpty || _text.text.trim().isNotEmpty);

  String _name(Room r) => r.displayName(widget.session.userId ?? '');

  void _add(Room room) {
    if (_rooms.any((r) => r.id == room.id)) {
      setState(() => _rooms.removeWhere((r) => r.id == room.id));
      return;
    }
    if (_rooms.length >= shareRoomsMax) {
      setState(
        () => _error = tr('대화방은 {n}곳까지 고를 수 있습니다.', {'n': shareRoomsMax}),
      );
      return;
    }
    setState(() {
      _rooms.add(room);
      _error = null;
    });
  }

  Future<void> _send() async {
    if (_rooms.isEmpty) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    final text = _text.text.trim();
    final targets = [..._rooms];
    final failed = <(Room, String)>[];
    // 일반 방에 올린 첨부와 비밀 대화에 올린(암호화한) 첨부 — 같은 종류의 방끼리는 한 번 올린 것을 그대로 보낸다.
    List<UploadedAttachment>? plainUploads;
    List<UploadedAttachment>? secretUploads;
    for (var i = 0; i < targets.length; i++) {
      final room = targets[i];
      if (mounted && targets.length > 1) {
        setState(
          () => _progress = tr('보내는 중 {i}/{n} — {room}', {
            'i': i + 1,
            'n': targets.length,
            'room': _name(room),
          }),
        );
      }
      final controller = widget.session.controllerFor(room);
      try {
        if (_files.isEmpty) {
          await controller.sendText(text);
        } else {
          final uploaded = room.isSecret
              ? secretUploads ??= await _upload(room)
              : plainUploads ??= await _upload(room);
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
        }
        _sent.add(room);
      } catch (e) {
        failed.add((
          room,
          e is ApiException
              ? e.message
              : tr('보내지 못했습니다. 연결을 확인하고 다시 시도하세요. ({e})', {'e': e}),
        ));
      }
    }
    if (failed.isEmpty) {
      // 다 보냈으니 안드로이드가 복사해 둔 파일은 지운다(남은 것은 안드로이드 쪽이 하루 뒤 정리한다). Windows의 원본은 그대로 둔다.
      for (final f in _files) {
        if (!f.temporary) continue;
        try {
          await File(f.path).delete();
        } catch (_) {}
      }
      if (mounted) Navigator.of(context).pop([..._sent]);
      return;
    }
    if (!mounted) return;
    setState(() {
      _sending = false;
      _progress = null;
      _rooms
        ..clear()
        ..addAll(failed.map((f) => f.$1));
      _error = [
        if (_sent.isNotEmpty)
          tr('{n}곳에 보냈습니다. 남은 대화방은 다시 보내세요.', {'n': _sent.length}),
        for (final (room, reason) in failed) '${_name(room)}: $reason',
      ].join('\n');
    });
  }

  Future<List<UploadedAttachment>> _upload(Room room) => widget.session
      .controllerFor(room)
      .uploadLocalFiles(
        [
          for (final f in _files)
            XFile(f.path, name: f.name, mimeType: f.mimeType),
        ],
        onProgress: (index, sent, total) {
          if (mounted) {
            setState(
              () => _progress = tr('올리는 중 {p0}/{_files.length}', {
                'p0': index + 1,
                '_files.length': _files.length,
              }),
            );
          }
        },
      );

  String _size(int? bytes) {
    if (bytes == null) return '';
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).round()}KB';
    return tr('{bytes}바이트', {'bytes': bytes});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('공유하기')),
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
                  : Text(
                      _rooms.length > 1
                          ? tr('{n}곳에 보내기', {'n': _rooms.length})
                          : tr('보내기'),
                    ),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          RoomPickerField(
            session: widget.session,
            value: null,
            placeholder: _rooms.isEmpty
                ? tr('대화방 선택')
                : tr('대화방 더하기 ({n}/{max})', {
                    'n': _rooms.length,
                    'max': shareRoomsMax,
                  }),
            includeSecret: true,
            selectedIds: {for (final r in _rooms) r.id},
            filter: (r) => canForwardTo(widget.session, r),
            onChanged: _sending ? (_) {} : _add,
          ),
          if (_rooms.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final r in _rooms)
                    InputChip(
                      key: ValueKey('share-room-${r.id}'),
                      avatar: r.isSecret
                          ? Icon(
                              Icons.lock,
                              size: 16,
                              color: Colors.green.shade700,
                            )
                          : null,
                      label: Text(_name(r), overflow: TextOverflow.ellipsis),
                      onDeleted: _sending
                          ? null
                          : () => setState(() => _rooms.remove(r)),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('share-text'),
            controller: _text,
            minLines: 2,
            maxLines: 8,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: tr('메시지'),
              border: OutlineInputBorder(),
            ),
          ),
          if (_files.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              tr('파일 {_files.length}개', {'_files.length': _files.length}),
              style: theme.textTheme.titleSmall,
            ),
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
                  tooltip: tr('빼기'),
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
            tr(
              '대화방은 {max}곳까지 골라 한꺼번에 보냅니다. 비밀 대화는 이 기기에서 암호화해 보냅니다. 보드 뷰 토픽·쓸 수 없는 토픽은 고를 수 없습니다.',
              {'max': shareRoomsMax},
            ),
            style: TextStyle(fontSize: 12, color: theme.hintColor),
          ),
        ],
      ),
    );
  }
}
