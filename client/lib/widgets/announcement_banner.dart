import 'package:flutter/material.dart';

import '../models/announcement.dart';
import '../models/room.dart';
import '../screens/announcement_list_screen.dart';
import '../services/announcement_view_prefs.dart';
import '../services/session.dart';
import 'announcement_image.dart';
import 'app_toast.dart';

/// 토픽 채팅 상단에 고정된 공지 — 잔디처럼 **접어두기 / 숨기기 / 삭제하기**가 있다.
///
/// - 펼친 모양(기본): 공지 글(최대 3줄)과, 사진 공지면 사진 한 장. 배너를 누르면 공지 목록(히스토리)이 열린다.
/// - 접어두기: 한 줄로 줄인다(글 한 줄 + 펼치기 버튼). 같은 버튼으로 다시 펼친다.
/// - 숨기기: **나에게만** 이 공지를 배너에서 치운다. 공지 자체는 그대로고(다른 사람과 공지 목록엔 계속 보인다)
///   새 공지가 올라오면 다시 보인다 — 숨김·접힘은 공지 id에 걸려 있어서 id가 바뀌면 저절로 풀린다.
/// - 삭제하기: 작성한 본인만(서버 규칙, Session.canManageAnnouncement) — 히스토리에서도 사라진다.
/// 숨김·접힘은 이 기기에 저장돼 앱을 다시 켜도 남는다(announcement_view_prefs.dart).
class AnnouncementBanner extends StatefulWidget {
  final Session session;
  final Room room;
  const AnnouncementBanner({
    super.key,
    required this.session,
    required this.room,
  });

  @override
  State<AnnouncementBanner> createState() => _AnnouncementBannerState();
}

class _AnnouncementBannerState extends State<AnnouncementBanner> {
  @override
  void initState() {
    super.initState();
    _loadSavedView();
  }

  @override
  void didUpdateWidget(AnnouncementBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.room.id != widget.room.id) _loadSavedView();
  }

  /// 이 기기에 저장된 숨김·접힘을 방 인스턴스에 한 번만 읽어 온다(화면을 오가도 방 인스턴스가 들고 있다).
  Future<void> _loadSavedView() async {
    final room = widget.room;
    if (room.announcementViewLoaded) return;
    room.announcementViewLoaded = true;
    final saved = await AnnouncementViewPrefs.load(
      widget.session.userId,
      room.id,
    );
    // 읽는 동안 사용자가 이미 눌렀다면 그 값을 덮어쓰지 않는다.
    room.dismissedAnnouncementId ??= saved.hiddenId;
    room.collapsedAnnouncementId ??= saved.collapsedId;
    if (mounted) setState(() {});
  }

  void _save() => AnnouncementViewPrefs.save(
    widget.session.userId,
    widget.room.id,
    hiddenId: widget.room.dismissedAnnouncementId,
    collapsedId: widget.room.collapsedAnnouncementId,
  );

  void _toggleCollapsed(Announcement a) {
    final room = widget.room;
    setState(() {
      room.collapsedAnnouncementId = room.collapsedAnnouncementId == a.id
          ? null
          : a.id;
    });
    _save();
  }

  void _hide(Announcement a) {
    setState(() => widget.room.dismissedAnnouncementId = a.id);
    _save();
  }

  Future<void> _delete(Announcement a) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('공지 삭제'),
        content: const Text('이 공지를 삭제할까요?\n공지 목록에서도 사라집니다.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('삭제', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    try {
      await widget.session.api!.deleteAnnouncement(widget.room.id, a.id);
      if (overlay != null) showAppToastOnOverlay(overlay, '공지를 삭제했습니다.');
    } catch (e) {
      if (overlay != null) showAppToastOnOverlay(overlay, '삭제하지 못했습니다: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final room = widget.room;
    final announcement = room.latestAnnouncement;
    if (announcement == null ||
        announcement.id == room.dismissedAnnouncementId) {
      return const SizedBox.shrink();
    }
    final collapsed = room.collapsedAnnouncementId == announcement.id;
    final onContainer = Theme.of(context).colorScheme.onPrimaryContainer;
    final canDelete = widget.session.canManageAnnouncement(announcement);

    final hasText = announcement.text.trim().isNotEmpty;
    final body = collapsed
        ? Text(
            announcement.previewText,
            key: const ValueKey('announcement-text'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: onContainer),
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (hasText)
                Text(
                  announcement.text,
                  key: const ValueKey('announcement-text'),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: onContainer),
                ),
              if (announcement.hasImage) ...[
                if (hasText) const SizedBox(height: 6),
                AnnouncementImage(
                  session: widget.session,
                  announcement: announcement,
                ),
              ],
            ],
          );

    return Material(
      color: Theme.of(context).colorScheme.primaryContainer,
      child: InkWell(
        onTap: () =>
            showAnnouncementListScreen(context, widget.session, widget.room),
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            12,
            collapsed ? 4 : 8,
            4,
            collapsed ? 4 : 8,
          ),
          child: Row(
            crossAxisAlignment: collapsed
                ? CrossAxisAlignment.center
                : CrossAxisAlignment.start,
            children: [
              Padding(
                padding: EdgeInsets.only(top: collapsed ? 0 : 2),
                child: Icon(
                  Icons.campaign_outlined,
                  size: 18,
                  color: onContainer,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(child: body),
              IconButton(
                key: const ValueKey('announcement-collapse-toggle'),
                icon: Icon(
                  collapsed ? Icons.expand_more : Icons.expand_less,
                  size: 20,
                  color: onContainer,
                ),
                tooltip: collapsed ? '펼치기' : '접어두기',
                visualDensity: VisualDensity.compact,
                onPressed: () => _toggleCollapsed(announcement),
              ),
              PopupMenuButton<String>(
                key: const ValueKey('announcement-more'),
                icon: Icon(Icons.more_vert, size: 18, color: onContainer),
                tooltip: '공지 더보기',
                padding: EdgeInsets.zero,
                onSelected: (value) {
                  if (value == 'hide') _hide(announcement);
                  if (value == 'delete') _delete(announcement);
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'hide', child: Text('숨기기 (나에게만)')),
                  if (canDelete)
                    const PopupMenuItem(
                      value: 'delete',
                      child: Text(
                        '삭제하기',
                        style: TextStyle(color: Colors.redAccent),
                      ),
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
