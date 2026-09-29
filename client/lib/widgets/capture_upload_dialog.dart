import 'dart:io';

import 'package:flutter/material.dart';

import '../models/room.dart';
import '../screens/message_forward_screen.dart' show canForwardTo;
import '../services/session.dart';

/// 화면 캡처 "파일 업로드" 대화상자에서 고른 결과.
class CaptureUploadChoice {
  final Room room;
  final String message;
  const CaptureUploadChoice(this.room, this.message);
}

/// 캡처한 파일을 어느 대화방에 어떤 메시지와 함께 올릴지 고르는 대화상자. 취소하면 null.
Future<CaptureUploadChoice?> showCaptureUploadDialog(
  BuildContext context, {
  required Session session,
  required Room initialRoom,
  required File file,
}) {
  return showDialog<CaptureUploadChoice>(
    context: context,
    builder: (_) => _CaptureUploadDialog(
      session: session,
      initialRoom: initialRoom,
      file: file,
    ),
  );
}

class _CaptureUploadDialog extends StatefulWidget {
  final Session session;
  final Room initialRoom;
  final File file;
  const _CaptureUploadDialog({
    required this.session,
    required this.initialRoom,
    required this.file,
  });

  @override
  State<_CaptureUploadDialog> createState() => _CaptureUploadDialogState();
}

class _CaptureUploadDialogState extends State<_CaptureUploadDialog> {
  static const _maxLength = 5000;
  final _message = TextEditingController();
  late Room _room = widget.initialRoom;
  late final List<Room> _rooms = _candidateRooms();

  List<Room> _candidateRooms() {
    final teamId = widget.session.currentTeam?.id;
    final myId = widget.session.userId ?? '';
    // 보드 뷰 토픽(게시글만 받음)과 내가 쓸 수 없는 읽기 전용·보관된 토픽은 서버가 거절하므로
    // 공유·전달과 같은 규칙으로 뺀다. 캡처를 시작한 방은 입력칸이 있던 방이라 늘 둔다.
    final list = widget.session.rooms
        .where(
          (r) =>
              !r.hidden &&
              (teamId == null || r.teamId == teamId) &&
              canForwardTo(widget.session, r),
        )
        .toList();
    if (!list.any((r) => r.id == widget.initialRoom.id)) {
      list.add(widget.initialRoom);
    }
    list.sort((a, b) => a.displayName(myId).compareTo(b.displayName(myId)));
    return list;
  }

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final myId = widget.session.userId ?? '';
    final hint = Theme.of(context).hintColor;
    final fileName = widget.file.uri.pathSegments.last;
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '파일 업로드',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              const Text(
                '공유 대화방',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<Room>(
                initialValue: _rooms.firstWhere(
                  (r) => r.id == _room.id,
                  orElse: () => _room,
                ),
                isExpanded: true,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                ),
                items: [
                  for (final r in _rooms)
                    DropdownMenuItem(
                      value: r,
                      child: Text(
                        r.displayName(myId),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (r) {
                  if (r != null) setState(() => _room = r);
                },
              ),
              const SizedBox(height: 16),
              const Text('파일', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: SizedBox(
                        width: 44,
                        height: 44,
                        child: Image.file(widget.file, fit: BoxFit.cover),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(fileName, overflow: TextOverflow.ellipsis),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              const Text('메시지', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              TextField(
                controller: _message,
                autofocus: true,
                minLines: 3,
                maxLines: 5,
                maxLength: _maxLength,
                buildCounter:
                    (
                      context, {
                      required currentLength,
                      required isFocused,
                      maxLength,
                    }) => Text(
                      '$currentLength/$maxLength',
                      style: TextStyle(color: hint, fontSize: 12),
                    ),
                decoration: const InputDecoration(border: OutlineInputBorder()),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('취소'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () => Navigator.of(
                      context,
                    ).pop(CaptureUploadChoice(_room, _message.text.trim())),
                    child: const Text('업로드'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
