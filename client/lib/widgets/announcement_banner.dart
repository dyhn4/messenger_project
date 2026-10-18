import 'package:flutter/material.dart';

import '../models/announcement.dart';
import '../models/app_user.dart';
import '../models/room.dart';
import '../screens/announcement_list_screen.dart' show openAnnouncementPanel;
import '../services/announcement_view_prefs.dart';
import '../services/session.dart';
import '../services/time_format.dart';
import 'pill_tag.dart';
import 'user_avatar.dart';
import 'retrying_network_image.dart';
import '../l10n/tr.dart';

/// 공지바 폭이 이보다 좁으면(폰 세로 화면 등) 작성자 이름을 빼고 시각을 짧게("27분 전"/"2026/09/30") 쓴다.
const double _compactWidth = 460;

/// 이보다 더 좁으면 시각까지 뺀다 — 공지 글이 들어갈 자리를 남기려고.
const double _tinyWidth = 300;

/// 토픽 채팅(과 보드 뷰) 맨 위에 고정된 공지 — 잔디 공지바처럼 **한 줄**이다.
///
///   [공지] 공지 글(한 줄, 넘치면 …)        시각  (💬 댓글 수)  (사진) 작성자  ✕
///
/// - "공지" 표시는 보드 뷰 "고정된 게시글"의 "고정" 표시와 같은 모양(pill_tag.dart).
/// - 시각은 공지·게시글에 쓰는 "2026/10/01 AM 3:44"(formatPostDateTime). 폭이 좁으면(모바일) 작성자 이름을 먼저
///   빼고 시각을 "27분 전"처럼 짧게(formatRelativeTime), 아주 좁으면 시각도 뺀다 — 넘치지 않고 공지 글이 줄어든다.
/// - 댓글 수는 댓글이 있을 때만 보이고(0이면 아이콘·숫자 모두 없다) 실시간으로 늘어난다
///   (Session.handleAnnouncementComment → Announcement.liveCommentCount).
///   작성자 사진·이름은 지금 방 멤버 정보를 먼저 쓰고(바뀐 이름·사진 반영), 방을 나간 사람이면 공지에 남은 이름으로.
/// - 몸통(✕ 말고 어디든)을 누르면 공지 패널(announcement_list_screen.dart)이 열리고 그 안에 이 공지의 상세가 바로
///   뜬다 — PC는 오른쪽 패널 안(←로 공지 목록), 모바일은 전체 화면 공지 목록 위(←로 목록). 수정·내리기·삭제는 상세나
///   목록 카드의 ⋯(작성자만)에서 한다.
/// - ✕(숨기기): **나에게만** 이 공지를 배너에서 치운다. 공지 자체는 그대로고(다른 사람과 공지 목록엔 계속 보인다)
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

  /// 작성자 — 지금 방 멤버면 그 정보(이름·사진이 바뀌었어도 최신), 아니면 공지에 남은 이름의 글자 아바타.
  AppUser _author(Announcement a) {
    final authorId = a.authorId;
    if (authorId != null) {
      for (final m in widget.room.members) {
        if (m.id == authorId) return m;
      }
    }
    return AppUser(
      id: authorId ?? '',
      username: a.authorName,
      name: a.authorName,
    );
  }

  @override
  Widget build(BuildContext context) {
    // 댓글 수·글 수정 같은 실시간 변화는 Session이 알린다 — 부모가 다시 그리지 않아도 바로 반영되게.
    return ListenableBuilder(
      listenable: widget.session,
      builder: (context, _) => _buildBar(context),
    );
  }

  Widget _buildBar(BuildContext context) {
    final room = widget.room;
    final announcement = room.latestAnnouncement;
    if (announcement == null ||
        announcement.id == room.dismissedAnnouncementId) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final hint = theme.hintColor;
    final metaStyle = TextStyle(fontSize: 12, color: hint);
    final author = _author(announcement);
    final commentCount = announcement.liveCommentCount;
    // 여러 줄 공지도 한 줄로 — 줄바꿈은 띄어쓰기로 바꿔서 첫 줄만 보이고 끝나지 않게.
    final line = announcement.previewText.trim().replaceAll(
      RegExp(r'\s*\n\s*'),
      ' ',
    );

    return Material(
      color: dark ? scheme.surfaceContainer : scheme.surfaceContainerLowest,
      child: InkWell(
        key: const ValueKey('announcement-open'),
        // 공지 패널을 열고 그 안에 이 공지의 상세를 바로 띄운다(←로 목록) — 패널을 여는 것이므로 안 읽은 공지 표시도 지운다.
        onTap: () => openAnnouncementPanel(
          context,
          widget.session,
          widget.room,
          initialAnnouncement: announcement,
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: theme.dividerColor)),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 2, 2, 2),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth;
                final compact = width < _compactWidth;
                final showTime = width >= _tinyWidth;
                return Row(
                  children: [
                    PillTag(
                      key: ValueKey('announcement-tag'),
                      icon: Icons.campaign,
                      label: tr('공지'),
                      tooltip: tr('고정된 공지'),
                    ),
                    const SizedBox(width: 8),
                    if (announcement.hasImage) ...[
                      // 사진 공지는 작은 축소본 — 누르면 사진 뷰어가 아니라 몸통처럼 상세보기가 열린다.
                      _Thumbnail(
                        session: widget.session,
                        announcement: announcement,
                      ),
                      const SizedBox(width: 6),
                    ],
                    Expanded(
                      child: Text(
                        line,
                        key: const ValueKey('announcement-text'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: scheme.onSurface,
                        ),
                      ),
                    ),
                    if (showTime) ...[
                      const SizedBox(width: 10),
                      Text(
                        compact
                            ? formatRelativeTime(announcement.createdAt)
                            : formatPostDateTime(announcement.createdAt),
                        key: const ValueKey('announcement-time'),
                        maxLines: 1,
                        style: metaStyle,
                      ),
                    ],
                    // 댓글 수 — 댓글이 있을 때만(0이면 아이콘·숫자 모두 뺀다). 실시간으로 늘면 그때 나타난다.
                    if (commentCount > 0) ...[
                      const SizedBox(width: 10),
                      Tooltip(
                        message: tr('댓글'),
                        child: Row(
                          key: const ValueKey('announcement-comments'),
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.mode_comment_outlined,
                              size: 14,
                              color: hint,
                            ),
                            const SizedBox(width: 3),
                            Text(
                              '$commentCount',
                              key: const ValueKey('announcement-comment-count'),
                              style: metaStyle,
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(width: 10),
                    Tooltip(
                      // 이름을 뺀 좁은 화면에서도 누가 썼는지 알 수 있게.
                      message: author.name,
                      child: UserAvatar(
                        key: const ValueKey('announcement-author-avatar'),
                        user: author,
                        resolveUrl: widget.session.resolveUrl,
                        radius: 10,
                      ),
                    ),
                    if (!compact) ...[
                      const SizedBox(width: 6),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 110),
                        child: Text(
                          author.name,
                          key: const ValueKey('announcement-author'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                    IconButton(
                      key: const ValueKey('announcement-hide'),
                      icon: Icon(Icons.close, size: 18, color: hint),
                      tooltip: tr('이번 공지 숨기기 (나에게만)'),
                      visualDensity: VisualDensity.compact,
                      onPressed: () => _hide(announcement.id),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// 사진 공지의 작은 축소본(22×22) — 터치는 무시하고(IgnorePointer) 공지바 몸통이 받는다.
class _Thumbnail extends StatelessWidget {
  final Session session;
  final Announcement announcement;
  const _Thumbnail({required this.session, required this.announcement});

  @override
  Widget build(BuildContext context) {
    final url = session.resolveUrl(
      announcement.imageThumbnailUrl ?? announcement.imageUrl ?? '',
    );
    final placeholder = ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Icon(
        Icons.image_outlined,
        size: 14,
        color: Theme.of(context).hintColor,
      ),
    );
    return IgnorePointer(
      child: ClipRRect(
        key: const ValueKey('announcement-image'),
        borderRadius: BorderRadius.circular(4),
        child: SizedBox(
          width: 22,
          height: 22,
          child: RetryingNetworkImage(
            imageUrl: url,
            fit: BoxFit.cover,
            placeholder: (_, _) => placeholder,
            errorWidget: (_, _, _) => placeholder,
          ),
        ),
      ),
    );
  }
}
