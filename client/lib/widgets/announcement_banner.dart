import 'package:flutter/material.dart';

import '../models/room.dart';
import '../screens/announcement_detail_screen.dart';
import '../services/announcement_view_prefs.dart';
import '../services/session.dart';
import '../services/time_format.dart';
import 'announcement_image.dart';

/// 토픽 채팅 상단에 고정된 공지 — 잔디처럼 몸통을 누르면 **상세보기가 바로 열리고**, 오른쪽 끝의 **X(숨기기)**
/// 하나만 있다.
///
/// - 몸통(글·사진 썸네일·작성자/시각 줄 전체)을 누르면 이 공지의 상세보기(announcement_detail_screen.dart)가 열린다.
///   공지 목록은 토픽 메뉴의 "공지"에서 연다. 수정·내리기·삭제는 상세보기의 ⋯(작성자만)에서 한다.
/// - X(숨기기): **나에게만** 이 공지를 배너에서 치운다. 공지 자체는 그대로고(다른 사람과 공지 목록엔 계속 보인다)
///   새 공지가 올라오면 다시 보인다 — 숨김은 공지 id에 걸려 있어서 id가 바뀌면 저절로 풀린다. 이 기기에 저장돼
///   앱을 다시 켜도 남는다(announcement_view_prefs.dart).
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
    _loadSavedHidden();
  }

  @override
  void didUpdateWidget(AnnouncementBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.room.id != widget.room.id) _loadSavedHidden();
  }

  /// 이 기기에 저장된 숨김을 방 인스턴스에 한 번만 읽어 온다(화면을 오가도 방 인스턴스가 들고 있다).
  Future<void> _loadSavedHidden() async {
    final room = widget.room;
    if (room.announcementViewLoaded) return;
    room.announcementViewLoaded = true;
    final hiddenId = await AnnouncementViewPrefs.loadHiddenId(
      widget.session.userId,
      room.id,
    );
    // 읽는 동안 사용자가 이미 눌렀다면 그 값을 덮어쓰지 않는다.
    room.dismissedAnnouncementId ??= hiddenId;
    if (mounted) setState(() {});
  }

  void _hide(String announcementId) {
    setState(() => widget.room.dismissedAnnouncementId = announcementId);
    AnnouncementViewPrefs.saveHiddenId(
      widget.session.userId,
      widget.room.id,
      announcementId,
    );
  }

  @override
  Widget build(BuildContext context) {
    final room = widget.room;
    final announcement = room.latestAnnouncement;
    if (announcement == null ||
        announcement.id == room.dismissedAnnouncementId) {
      return const SizedBox.shrink();
    }
    final onContainer = Theme.of(context).colorScheme.onPrimaryContainer;
    final hasText = announcement.text.trim().isNotEmpty;

    return Material(
      color: Theme.of(context).colorScheme.primaryContainer,
      child: InkWell(
        key: const ValueKey('announcement-open'),
        onTap: () => showAnnouncementDetailScreen(
          context,
          widget.session,
          widget.room,
          announcement,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(
                  Icons.campaign_outlined,
                  size: 18,
                  color: onContainer,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
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
                      // 썸네일을 눌러도 이미지 뷰어가 아니라 배너 몸통처럼 상세보기가 열린다(사진은 상세에서 크게 본다).
                      IgnorePointer(
                        child: AnnouncementImage(
                          session: widget.session,
                          announcement: announcement,
                        ),
                      ),
                    ],
                    const SizedBox(height: 4),
                    Text(
                      '${announcement.authorName} · '
                      '${formatPostDateTime(announcement.createdAt)}',
                      key: const ValueKey('announcement-meta'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: onContainer.withValues(alpha: 0.7),
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                key: const ValueKey('announcement-hide'),
                icon: Icon(Icons.close, size: 18, color: onContainer),
                tooltip: '이번 공지 숨기기 (나에게만)',
                visualDensity: VisualDensity.compact,
                onPressed: () => _hide(announcement.id),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
