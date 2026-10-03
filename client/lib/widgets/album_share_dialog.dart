import 'package:flutter/material.dart';

import '../models/album.dart';
import '../models/room.dart';
import '../services/session.dart';
import 'app_toast.dart';
import 'floating_dialog.dart';
import 'room_picker_field.dart';

/// 앨범 항목을 보낼 수 있는 대화방인지 — 내가 멤버인 채팅·그룹·1:1·챗 뷰 토픽만 되고, 보드 뷰 토픽과 비밀 대화는 뺀다.
/// 읽기 전용·보관된 토픽은 관리자만 글을 쓰므로 내가 쓸 수 없으면 뺀다. 앨범과 같은 팀의 방이어야 한다(서버 규칙).
bool canShareAlbumTo(Session session, Room room, Album album) =>
    !room.isSecret &&
    !room.isBoard &&
    room.teamId == album.teamId &&
    room.canWrite(session);

/// "대화방에 공유" 창 — 대상 대화방을 고르면(검색 가능) 선택한 [itemIds]를 이미지/영상 메시지로 보낸다. 보냈으면 true.
Future<bool> showAlbumShareDialog(
  BuildContext context, {
  required Session session,
  required Album album,
  required List<String> itemIds,
}) async {
  final shared = await showDialog<bool>(
    context: context,
    builder: (_) =>
        AlbumShareDialog(session: session, album: album, itemIds: itemIds),
  );
  return shared ?? false;
}

class AlbumShareDialog extends StatefulWidget {
  final Session session;
  final Album album;
  final List<String> itemIds;
  const AlbumShareDialog({
    super.key,
    required this.session,
    required this.album,
    required this.itemIds,
  });

  @override
  State<AlbumShareDialog> createState() => _AlbumShareDialogState();
}

class _AlbumShareDialogState extends State<AlbumShareDialog> {
  Room? _room;
  bool _sending = false;
  String? _error;

  Future<void> _send() async {
    final room = _room;
    if (room == null || _sending) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    final overlay = Overlay.of(context);
    final myId = widget.session.userId ?? '';
    try {
      await widget.session.albums.shareItems(room.id, widget.itemIds);
      if (!mounted) return;
      Navigator.of(context).pop(true);
      showAppToastOnOverlay(
        overlay,
        "'${room.displayName(myId)}'에 ${widget.itemIds.length}개를 공유했습니다.",
      );
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FloatingDialog(
      title: '대화방에 공유',
      maxWidth: 420,
      maxHeight: 460,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '선택한 ${widget.itemIds.length}개를 이미지·영상 메시지로 보냅니다. 파일은 복사되지 않고 같은 파일을 가리킵니다.',
              style: TextStyle(fontSize: 12, color: theme.hintColor),
            ),
            const SizedBox(height: 12),
            const Text(
              '대화방',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            KeyedSubtree(
              key: const ValueKey('album-share-room-field'),
              child: IgnorePointer(
                ignoring: _sending,
                child: RoomPickerField(
                  session: widget.session,
                  value: _room,
                  filter: (r) =>
                      canShareAlbumTo(widget.session, r, widget.album),
                  onChanged: (r) => setState(() {
                    _room = r;
                    _error = null;
                  }),
                ),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error!,
                  key: const ValueKey('album-share-error'),
                  style: TextStyle(
                    fontSize: 13,
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: _sending
                      ? null
                      : () => Navigator.of(context).pop(false),
                  child: const Text('취소'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  key: const ValueKey('album-share-send'),
                  onPressed: _room == null || _sending ? null : _send,
                  child: _sending
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('공유'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
