import 'dart:async';

import 'package:flutter/material.dart';

import '../models/announcement.dart';
import '../models/app_user.dart';
import '../models/room.dart';
import '../services/app_platform.dart';
import '../services/chat_socket.dart'
    show AnnouncementRemovedEvent, SimpleCommentDeleted;
import '../services/session.dart';
import '../services/time_format.dart';
import '../widgets/announcement_image.dart';
import '../widgets/app_toast.dart';
import '../widgets/avatar_utils.dart';
import '../widgets/board_view.dart'
    show BoardColors, PinnedPostTag, boardCardDecoration;
import '../widgets/compact_menu.dart';
import '../widgets/post_comments.dart';
import '../widgets/rich_text_format.dart' show FormattedText;
import '../widgets/room_options_menu.dart' show closeOwnRoute;
import 'announcement_editor_dialog.dart';
import 'home_screen.dart' show wideBreakpoint;
import '../l10n/tr.dart';

/// 공지 "상세보기" — 배너·공지 패널·알림 센터에서 연다. 잔디의 게시글 상세처럼 카드 하나에 작성자 아바타·이름·
/// `2026/10/01 AM 3:44`, 오른쪽 위 ⋯(작성자만: 수정하기·공지 내리기·삭제하기 …), 본문, 사진(있으면), 구분선,
/// `댓글 N`과 댓글 목록을 담고, 맨 아래에 고정된 댓글 입력칸이 있다.
///
/// 이 함수(배너·알림 센터)는 PC면 대화상자(머리 `공지 … ✕`), 모바일이면 전체 화면(머리 `← 공지`)으로 연다. 공지 패널은
/// 이 함수 대신 [AnnouncementDetailScreen]을 직접 띄운다 — PC는 패널 안 화면(`← 공지 … ✕`, ←는 목록으로, ✕는 패널 닫기),
/// 모바일은 이것과 같은 전체 화면이다(announcement_list_screen.dart). [onDeleted]는 공지를 지워서 닫힐 때 부른다.
Future<void> showAnnouncementDetailScreen(
  BuildContext context,
  Session session,
  Room room,
  Announcement announcement, {
  VoidCallback? onDeleted,
}) {
  final isWide = MediaQuery.sizeOf(context).width >= wideBreakpoint;
  if (isWide) {
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: 520,
          height: 680,
          child: AnnouncementDetailScreen(
            session: session,
            room: room,
            announcement: announcement,
            onClose: () => Navigator.of(dialogContext).pop(),
            onDeleted: onDeleted,
          ),
        ),
      ),
    );
  }
  return pushAnnouncementDetailPage(
    Navigator.of(context),
    session,
    room,
    announcement,
    onDeleted: onDeleted,
  );
}

/// 모바일 전체 화면 상세 — 앱바 대신 패널 안 화면과 같은 머리(`← 공지`)를 그린다. 공지 패널(모바일)도 이걸 쓴다.
Future<void> pushAnnouncementDetailPage(
  NavigatorState navigator,
  Session session,
  Room room,
  Announcement announcement, {
  VoidCallback? onDeleted,
}) {
  return navigator.push(
    MaterialPageRoute<void>(
      builder: (routeContext) => Scaffold(
        body: SafeArea(
          bottom: false,
          child: AnnouncementDetailScreen(
            session: session,
            room: room,
            announcement: announcement,
            onBack: () => Navigator.of(routeContext).maybePop(),
            onDeleted: onDeleted,
          ),
        ),
      ),
    ),
  );
}

// ── ⋯ 더보기 메뉴(상세와 공지 패널 카드가 같이 쓴다) ─────────────────────────────

/// 공지 ⋯ 메뉴의 동작 — 수정하기 · 공지 내리기 / 현재 채팅방에 공유하기 / 삭제하기.
enum AnnouncementMoreAction { share, edit, unpin, delete }

/// [AnnouncementMoreAction]을 한 뒤 공지가 어떻게 됐는지 — 부른 쪽이 다시 그리거나(changed) 닫거나 목록에서 뺀다(deleted).
enum AnnouncementActionResult { none, changed, deleted }

/// 지금 사용자가 [announcement]의 ⋯에서 할 수 있는 동작 — 작성자만 모두 할 수 있다(Session.canManageAnnouncement,
/// 서버와 같은 규칙). "공지 내리기"는 지금 채팅방에 고정된 공지에만. 빈 목록이면 ⋯를 아예 숨긴다.
List<AnnouncementMoreAction> announcementMoreActions(
  Session session,
  Announcement announcement,
) {
  if (!session.canManageAnnouncement(announcement)) return const [];
  return [
    AnnouncementMoreAction.edit,
    if (announcement.pinned) AnnouncementMoreAction.unpin,
    AnnouncementMoreAction.share,
    AnnouncementMoreAction.delete,
  ];
}

/// 공지 ⋯ 더보기 단추 — 토픽방 머리의 ⋯ 메뉴(room_options_menu.dart)와 같은 간결한 메뉴([CompactMenu]: 흰 바탕·작은
/// 글씨·작고 흐린 아이콘, 묶음 사이 구분선). 묶음은 수정하기·공지 내리기 / 현재 채팅방에 공유하기 / 삭제하기(빨강) 중
/// [announcementMoreActions]가 허락한 것만이고, 하나도 없으면 아무것도 그리지 않는다. 메뉴는 창 전체(루트 Navigator)에
/// 띄운다 — 공지 패널 안 화면(중첩 Navigator)에서도 바깥(채팅 쪽)을 누르면 닫힌다. 상세(작성자 줄 오른쪽)와 공지 패널의
/// 카드(오른쪽 위)가 같이 쓴다 — 고른 동작은 [onSelected]로 넘기고, 보통 [runAnnouncementMoreAction]으로 한다.
class AnnouncementMoreButton extends StatelessWidget {
  final Session session;
  final Announcement announcement;
  final ValueChanged<AnnouncementMoreAction> onSelected;

  /// 아이콘 크기·색과 누르는 칸(정사각형 한 변) — 카드처럼 좁은 자리는 작게 준다. null이면 IconButton 기본.
  final double? iconSize;
  final Color? iconColor;
  final double? buttonSize;

  /// 안쪽 PopupMenuButton의 키(테스트가 단추를 찾는 데 쓴다).
  final Key? buttonKey;

  const AnnouncementMoreButton({
    super.key,
    this.buttonKey,
    required this.session,
    required this.announcement,
    required this.onSelected,
    this.iconSize,
    this.iconColor,
    this.buttonSize,
  });

  @override
  Widget build(BuildContext context) {
    final actions = announcementMoreActions(session, announcement);
    if (actions.isEmpty) return const SizedBox.shrink();
    final hasEditGroup =
        actions.contains(AnnouncementMoreAction.edit) ||
        actions.contains(AnnouncementMoreAction.unpin);
    final hasShare = actions.contains(AnnouncementMoreAction.share);
    final hasDelete = actions.contains(AnnouncementMoreAction.delete);
    final size = buttonSize;
    return PopupMenuButton<AnnouncementMoreAction>(
      key: buttonKey,
      icon: Icon(Icons.more_horiz, size: iconSize, color: iconColor),
      tooltip: tr('더보기'),
      padding: EdgeInsets.zero,
      iconSize: iconSize,
      style: size == null
          ? null
          : IconButton.styleFrom(
              fixedSize: Size.square(size),
              minimumSize: Size.square(size),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
      useRootNavigator: true,
      color: CompactMenu.color(context),
      shape: CompactMenu.shape,
      menuPadding: CompactMenu.menuPadding,
      constraints: CompactMenu.constraints,
      onSelected: onSelected,
      itemBuilder: (context) => [
        if (actions.contains(AnnouncementMoreAction.edit))
          CompactMenu.item(
            context,
            icon: Icons.edit_outlined,
            label: tr('수정하기'),
            value: AnnouncementMoreAction.edit,
          ),
        if (actions.contains(AnnouncementMoreAction.unpin))
          CompactMenu.item(
            context,
            icon: Icons.push_pin_outlined,
            label: tr('공지 내리기'),
            value: AnnouncementMoreAction.unpin,
          ),
        if (hasEditGroup && (hasShare || hasDelete)) CompactMenu.divider,
        if (hasShare)
          CompactMenu.item(
            context,
            icon: Icons.forward_outlined,
            label: tr('현재 채팅방에 공유하기'),
            value: AnnouncementMoreAction.share,
          ),
        if (hasShare && hasDelete) CompactMenu.divider,
        if (hasDelete)
          CompactMenu.item(
            context,
            icon: Icons.delete_outline,
            label: tr('삭제하기'),
            color: Colors.redAccent,
            value: AnnouncementMoreAction.delete,
          ),
      ],
    );
  }
}

/// ⋯에서 고른 [action]을 한다 — 확인 창·서버 요청·실패 토스트까지. 고치거나 내리면 [announcement] 객체의 값을 그
/// 자리에서 바꾸고 [AnnouncementActionResult.changed], 지웠으면 [AnnouncementActionResult.deleted], 취소·실패·공유는
/// [AnnouncementActionResult.none]을 돌려준다. [context]는 확인 창·토스트를 띄울 자리(상세 화면이나 공지 패널).
Future<AnnouncementActionResult> runAnnouncementMoreAction(
  BuildContext context,
  Session session,
  Room room,
  Announcement announcement,
  AnnouncementMoreAction action,
) async {
  switch (action) {
    case AnnouncementMoreAction.share:
      await _shareAnnouncementToRoom(context, session, room, announcement);
      return AnnouncementActionResult.none;
    case AnnouncementMoreAction.edit:
      return await _editAnnouncement(context, session, room, announcement)
          ? AnnouncementActionResult.changed
          : AnnouncementActionResult.none;
    case AnnouncementMoreAction.unpin:
      return await _unpinAnnouncement(context, session, room, announcement)
          ? AnnouncementActionResult.changed
          : AnnouncementActionResult.none;
    case AnnouncementMoreAction.delete:
      return await _deleteAnnouncement(context, session, room, announcement)
          ? AnnouncementActionResult.deleted
          : AnnouncementActionResult.none;
  }
}

/// 현재 채팅방에 공유하기 — 공지를 인용한 메시지를 그 방에 보낸다.
Future<void> _shareAnnouncementToRoom(
  BuildContext context,
  Session session,
  Room room,
  Announcement announcement,
) async {
  try {
    await session.chatSocket.send(
      roomId: room.id,
      type: 'text',
      // 서버가 이 공지를 내가 읽을 수 있는지 확인하고 인용 카드의 작성자·미리보기를 공지에서 채운다
      // (server/src/messageAttribution.js). 아래 두 값은 업데이트 전 서버만 쓴다.
      quotedAnnouncementId: announcement.id,
      quotedSenderName: announcement.authorName,
      quotedPreview: announcement.previewText,
    );
    if (context.mounted) showAppToast(context, tr('현재 채팅방에 공유했습니다.'));
  } catch (e) {
    if (context.mounted) showAppToast(context, tr('공유하지 못했습니다: {e}', {'e': e}));
  }
}

/// 공지 내리기 — 묻고 나서 채팅방 상단에서 내린다(목록에는 남는다). 내렸으면 true.
Future<bool> _unpinAnnouncement(
  BuildContext context,
  Session session,
  Room room,
  Announcement announcement,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(tr('공지 내리기')),
      content: Text(tr('이 공지를 채팅방 상단에서 내릴까요? 목록에는 그대로 남습니다.')),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(tr('취소')),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(tr('내리기')),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return false;
  try {
    await session.api!.unpinAnnouncement(room.id, announcement.id);
    announcement.pinned = false;
    return true;
  } catch (e) {
    if (context.mounted) {
      showAppToast(context, tr('공지를 내리지 못했습니다: {e}', {'e': e}));
    }
    return false;
  }
}

/// 수정 — 공지 쓰기와 같은 틀의 창(announcement_editor_dialog.dart)에서 글을 고친다. 고쳤으면 true.
Future<bool> _editAnnouncement(
  BuildContext context,
  Session session,
  Room room,
  Announcement announcement,
) async {
  var changed = false;
  await showAnnouncementEditor(
    context,
    session: session,
    room: room,
    announcement: announcement,
    onSubmit: (draft) async {
      final updated = await session.api!.updateAnnouncement(
        room.id,
        announcement.id,
        draft.text,
        textFormat: draft.format,
      );
      announcement.text = updated.text;
      announcement.textFormat = updated.textFormat;
      announcement.editedAt = updated.editedAt;
      changed = true;
    },
  );
  return changed;
}

/// 삭제 — 묻고 나서 지운다(댓글도 함께). 지웠으면 true.
Future<bool> _deleteAnnouncement(
  BuildContext context,
  Session session,
  Room room,
  Announcement announcement,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(tr('공지 삭제')),
      content: Text(tr('이 공지를 삭제할까요? 댓글도 함께 삭제되며 되돌릴 수 없습니다.')),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(tr('취소')),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(tr('삭제'), style: TextStyle(color: Colors.redAccent)),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return false;
  try {
    await session.api!.deleteAnnouncement(room.id, announcement.id);
    return true;
  } catch (e) {
    if (context.mounted) showAppToast(context, tr('삭제하지 못했습니다: {e}', {'e': e}));
    return false;
  }
}

class AnnouncementDetailScreen extends StatefulWidget {
  final Session session;
  final Room room;
  final Announcement announcement;

  /// 머리 왼쪽 ←(뒤로) — 주면 보인다(모바일 전체 화면·패널 안 화면: 목록으로 돌아간다).
  final VoidCallback? onBack;

  /// 머리 오른쪽 ✕(닫기) — 주면 보인다(PC 대화상자는 대화상자를, 패널 안 화면은 패널 전체를 닫는다).
  final VoidCallback? onClose;

  /// 이 공지를 지워서(여기서 삭제했거나 다른 기기에서 지워져) 상세가 닫힐 때 — 목록이 그 카드를 뺀다.
  final VoidCallback? onDeleted;

  const AnnouncementDetailScreen({
    super.key,
    required this.session,
    required this.room,
    required this.announcement,
    this.onBack,
    this.onClose,
    this.onDeleted,
  });

  @override
  State<AnnouncementDetailScreen> createState() =>
      _AnnouncementDetailScreenState();
}

class _AnnouncementDetailScreenState extends State<AnnouncementDetailScreen> {
  late Announcement _announcement;
  List<AnnouncementComment>? _comments;
  String? _error;
  final _commentController = TextEditingController();
  bool _sending = false;

  StreamSubscription<AnnouncementComment>? _commentSub;
  StreamSubscription<AnnouncementComment>? _commentEditedSub;
  StreamSubscription<SimpleCommentDeleted>? _commentDeletedSub;
  StreamSubscription<Announcement>? _updatedSub;
  StreamSubscription<AnnouncementRemovedEvent>? _unpinnedSub;
  StreamSubscription<AnnouncementRemovedEvent>? _deletedSub;

  @override
  void initState() {
    super.initState();
    _announcement = widget.announcement;
    _load();
    // 상세를 실제로 열었다는 뜻 — 알림 센터의 "안 읽은 공지" 표시를 지운다(배너에서 바로 열 때도 같다).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.session.markAnnouncementsRead(widget.room);
    });
    _commentSub = widget.session.chatSocket.announcementComments.listen((c) {
      if (c.announcementId != _announcement.id || !mounted) return;
      setState(() {
        final comments = _comments;
        if (comments == null || comments.any((e) => e.id == c.id)) return;
        _comments = [...comments, c];
        _announcement.commentCount += 1;
      });
    });
    _commentEditedSub = widget.session.chatSocket.announcementCommentEdited
        .listen((c) {
          if (c.announcementId != _announcement.id || !mounted) return;
          setState(() => _replaceComment(c));
        });
    _commentDeletedSub = widget.session.chatSocket.announcementCommentDeleted
        .listen((e) {
          if (e.parentId != _announcement.id || !mounted) return;
          setState(() => _removeComment(e.id));
        });
    _updatedSub = widget.session.chatSocket.announcementUpdated.listen((a) {
      if (a.id != _announcement.id || !mounted) return;
      setState(() {
        _announcement.text = a.text;
        _announcement.textFormat = a.textFormat;
        _announcement.editedAt = a.editedAt;
      });
    });
    _unpinnedSub = widget.session.chatSocket.announcementUnpinned.listen((e) {
      if (e.id != _announcement.id || !mounted) return;
      setState(() => _announcement.pinned = false);
    });
    // 보고 있는 공지가 (작성자의 다른 기기 등에서) 지워지면 닫는다.
    _deletedSub = widget.session.chatSocket.announcementDeleted.listen((e) {
      if (e.id != _announcement.id || !mounted) return;
      _close();
    });
  }

  @override
  void dispose() {
    _commentSub?.cancel();
    _commentEditedSub?.cancel();
    _commentDeletedSub?.cancel();
    _updatedSub?.cancel();
    _unpinnedSub?.cancel();
    _deletedSub?.cancel();
    _commentController.dispose();
    super.dispose();
  }

  bool _closed = false;

  /// 공지가 지워져 상세를 닫는다 — 삭제 응답과 소켓 알림이 둘 다 오니 한 번만(두 번 닫으면 뒤 화면까지 닫힌다). 이 화면의
  /// 라우트(대화상자·전체 화면·패널 안 화면)만 닫는다 — 위에 메뉴가 떠 있어도 엉뚱한 것을 닫지 않게.
  void _close() {
    if (_closed || !mounted) return;
    _closed = true;
    widget.onDeleted?.call();
    closeOwnRoute(context);
  }

  Future<void> _load() async {
    unawaited(_loadReaders());
    try {
      final comments = await widget.session.api!.fetchAnnouncementComments(
        widget.room.id,
        _announcement.id,
      );
      if (mounted) setState(() => _comments = comments);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  /// 읽음 확인(읽은 사람·안 읽은 사람) — 못 받으면(예전 서버 등) 표시만 하지 않는다.
  AnnouncementReaders? _readers;

  Future<void> _loadReaders() async {
    try {
      final readers = await widget.session.api!.fetchAnnouncementReaders(
        widget.room.id,
        _announcement.id,
      );
      // 지금 보고 있는 나는 읽은 쪽이다(열면서 보낸 읽음이 서버에 닿기 전에 받은 목록일 수 있다).
      final mine = readers.markRead(widget.session.userId, DateTime.now());
      if (mounted) setState(() => _readers = mine);
    } catch (_) {
      // 부가 표시라 조용히 넘어간다.
    }
  }

  Future<void> _postComment() async {
    final text = _commentController.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    _commentController.clear();
    try {
      final created = await widget.session.api!.postAnnouncementComment(
        widget.room.id,
        _announcement.id,
        text,
      );
      if (!mounted) return;
      setState(() {
        final comments = _comments ?? [];
        if (comments.any((e) => e.id == created.id)) return;
        _comments = [...comments, created];
        _announcement.commentCount += 1;
      });
    } catch (e) {
      if (mounted) showAppToast(context, tr('댓글을 등록하지 못했습니다: {e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  AppUser? _memberOf(String? userId) {
    if (userId == null) return null;
    for (final m in widget.room.members) {
      if (m.id == userId) return m;
    }
    return null;
  }

  /// ⋯에서 고른 동작 — 공지 패널 카드의 ⋯와 같은 코드([runAnnouncementMoreAction]). 지웠으면 상세를 닫는다.
  Future<void> _onMore(AnnouncementMoreAction action) async {
    final result = await runAnnouncementMoreAction(
      context,
      widget.session,
      widget.room,
      _announcement,
      action,
    );
    if (!mounted) return;
    switch (result) {
      case AnnouncementActionResult.changed:
        setState(() {});
      case AnnouncementActionResult.deleted:
        _close();
      case AnnouncementActionResult.none:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = BoardColors.of(theme);
    // 패널 안 화면은 밀려 들어오는 동안 아래 목록이 비치지 않게 제 바탕을 칠한다.
    return Material(
      color: theme.colorScheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHeader(context),
          const Divider(height: 1),
          Expanded(
            child: ColoredBox(
              color: colors.background,
              child: _buildBody(context, colors),
            ),
          ),
          _buildCommentInput(context),
        ],
      ),
    );
  }

  /// 머리 — `← 공지 … ✕`. ←는 [AnnouncementDetailScreen.onBack], ✕는 [AnnouncementDetailScreen.onClose]가 있을 때만.
  /// 높이·여백은 다른 패널 머리(SidePanelHeader)·할 일 패널 안 화면 머리(TodoPageHeader)와 같다.
  Widget _buildHeader(BuildContext context) {
    final back = widget.onBack;
    final close = widget.onClose;
    return Padding(
      // ←가 있으면 단추 안쪽 여백만큼 덜 띄워 화살표를 본문 왼쪽 끝에 맞춘다.
      padding: EdgeInsets.fromLTRB(back == null ? 16 : 8, 12, 8, 12),
      child: Row(
        children: [
          if (back != null) ...[
            IconButton(
              key: const ValueKey('announcement-detail-back'),
              icon: const Icon(Icons.arrow_back),
              tooltip: tr('뒤로'),
              onPressed: back,
            ),
            const SizedBox(width: 4),
          ],
          Expanded(
            child: Text(
              tr('공지'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          if (close != null)
            IconButton(
              key: const ValueKey('announcement-detail-close'),
              icon: const Icon(Icons.close),
              tooltip: tr('닫기'),
              onPressed: close,
            ),
          // 머리 높이를 다른 패널과 같게(단추가 하나도 없어도).
          if (back == null && close == null)
            const SizedBox(height: kMinInteractiveDimension),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context, BoardColors colors) {
    if (_error != null) return Center(child: Text(_error!));
    final comments = _comments;
    final count = comments?.length ?? _announcement.commentCount;
    final hasText = _announcement.text.trim().isNotEmpty;

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        DecoratedBox(
          key: const ValueKey('announcement-detail-card'),
          decoration: boardCardDecoration(colors),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 8, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildAuthorRow(
                  context,
                  avatarUser: _memberOf(_announcement.authorId),
                  authorName: _announcement.authorName,
                  time: _announcement.createdAt,
                  edited: _announcement.editedAt != null,
                  avatarRadius: 20,
                  trailing: [
                    if (_announcement.pinned) ...[
                      const PinnedPostTag(),
                      const SizedBox(width: 2),
                    ],
                    // ⋯ — 할 수 있는 게 없으면(작성자가 아니면) 그리지 않는다.
                    AnnouncementMoreButton(
                      buttonKey: const ValueKey('announcement-detail-more'),
                      session: widget.session,
                      announcement: _announcement,
                      onSelected: _onMore,
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (hasText) ...[
                        const SizedBox(height: 14),
                        // Windows(마우스)에서는 끌어서 바로 고를 수 있게(게시글 상세와 같은 규칙).
                        // 공지 쓰기 창에서 서식을 입혔으면 서식대로(선택 가능 여부는 같은 규칙).
                        _announcement.textFormat != null
                            ? FormattedText(
                                _announcement.text,
                                key: const ValueKey('announcement-detail-text'),
                                format: _announcement.textFormat,
                                selectable: AppPlatform.isWindows,
                                style: const TextStyle(
                                  fontSize: 15,
                                  height: 1.6,
                                ),
                              )
                            : AppPlatform.isWindows
                            ? SelectableText(
                                _announcement.text,
                                key: const ValueKey('announcement-detail-text'),
                                style: const TextStyle(
                                  fontSize: 15,
                                  height: 1.6,
                                ),
                              )
                            : Text(
                                _announcement.text,
                                key: const ValueKey('announcement-detail-text'),
                                style: const TextStyle(
                                  fontSize: 15,
                                  height: 1.6,
                                ),
                              ),
                      ],
                      if (_announcement.hasImage) ...[
                        const SizedBox(height: 14),
                        _buildImageCard(context),
                      ],
                      const SizedBox(height: 14),
                    ],
                  ),
                ),
                Divider(height: 1, color: colors.border),
                Padding(
                  padding: const EdgeInsets.fromLTRB(0, 12, 8, 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: PostCommentCount(
                          count,
                          textKey: const ValueKey('announcement-comment-count'),
                        ),
                      ),
                      if (_readers case final readers?)
                        TextButton.icon(
                          key: const ValueKey('announcement-readers'),
                          style: TextButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                          ),
                          icon: const Icon(Icons.done_all, size: 16),
                          label: Text(
                            tr(
                              '읽음 {readers.read.length} · 안 읽음 {readers.unread.length}',
                              {
                                'readers.read.length': readers.read.length,
                                'readers.unread.length': readers.unread.length,
                              },
                            ),
                          ),
                          onPressed: () {
                            unawaited(_loadReaders());
                            showAnnouncementReadersDialog(context, readers);
                          },
                        ),
                    ],
                  ),
                ),
                PostCommentList<AnnouncementComment>(
                  comments: comments,
                  itemBuilder: (c) => _buildComment(context, c),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 사진 공지의 사진 — 잔디의 첨부 카드처럼 옅은 바탕의 둥근 카드 안에(누르면 기존 이미지 뷰어).
  Widget _buildImageCard(BuildContext context) {
    final theme = Theme.of(context);
    final name = _announcement.imageName;
    return Container(
      key: const ValueKey('announcement-detail-image-card'),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AnnouncementImage(
            session: widget.session,
            announcement: _announcement,
            maxHeight: 280,
            maxWidth: 400,
          ),
          if (name != null && name.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: theme.hintColor),
            ),
          ],
        ],
      ),
    );
  }

  /// 작성자 줄 — 아바타 + 이름 + `yyyy/MM/dd AM h:mm`(수정됨), 오른쪽에 [trailing](고정 표시·⋯).
  Widget _buildAuthorRow(
    BuildContext context, {
    required AppUser? avatarUser,
    required String authorName,
    required DateTime time,
    required bool edited,
    required double avatarRadius,
    List<Widget> trailing = const [],
  }) {
    final hint = Theme.of(context).hintColor;
    return Row(
      children: [
        AvatarView(
          username: authorName,
          avatarType: avatarUser?.avatarType ?? 'initial',
          avatarEmoji: avatarUser?.avatarEmoji,
          avatarColor: avatarUser?.avatarColor,
          avatarUrl: avatarUser?.avatarUrl,
          resolveUrl: widget.session.resolveUrl,
          radius: avatarRadius,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                authorName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                ),
              ),
              Text(
                edited
                    ? tr('{p0} (수정됨)', {'p0': formatPostDateTime(time)})
                    : formatPostDateTime(time),
                style: TextStyle(fontSize: 12, color: hint),
              ),
            ],
          ),
        ),
        ...trailing,
      ],
    );
  }

  /// 댓글 한 줄 — ⋯는 고치거나 지울 수 있을 때만(작성자는 수정·삭제, 관리자는 삭제 — [simpleCommentPermissions]).
  Widget _buildComment(BuildContext context, AnnouncementComment c) {
    final can = simpleCommentPermissions(
      widget.session,
      widget.room,
      c.authorId,
    );
    return PostCommentTile(
      key: ValueKey('announcement-comment-${c.id}'),
      commentId: c.id,
      avatarUser: _memberOf(c.authorId),
      authorName: c.authorName,
      createdAt: c.createdAt,
      editedAt: c.editedAt,
      text: c.text,
      resolveUrl: widget.session.resolveUrl,
      onEdit: can.edit ? (text) => _editComment(c, text) : null,
      onDelete: can.delete ? () => _deleteComment(c) : null,
    );
  }

  Future<void> _editComment(AnnouncementComment c, String text) async {
    final updated = await widget.session.api!.updateAnnouncementComment(
      widget.room.id,
      _announcement.id,
      c.id,
      text,
    );
    if (mounted) setState(() => _replaceComment(updated));
  }

  Future<void> _deleteComment(AnnouncementComment c) async {
    await widget.session.api!.deleteAnnouncementComment(
      widget.room.id,
      _announcement.id,
      c.id,
    );
    if (mounted) setState(() => _removeComment(c.id));
  }

  /// 고친 댓글로 바꾼다(소켓 소식과 내 응답이 둘 다 와도 같은 값이다).
  void _replaceComment(AnnouncementComment c) {
    final comments = _comments;
    if (comments == null) return;
    _comments = [for (final e in comments) e.id == c.id ? c : e];
  }

  /// 지운 댓글을 뺀다 — 목록에 있었을 때만 댓글 수를 내린다(내 응답과 소켓 소식이 둘 다 와도 한 번만). 공지바의 실시간
  /// 댓글 수도 같은 인스턴스면 같이 맞춘다.
  void _removeComment(String id) {
    final comments = _comments;
    if (comments == null || !comments.any((e) => e.id == id)) return;
    _comments = [
      for (final e in comments)
        if (e.id != id) e,
    ];
    if (_announcement.commentCount > 0) _announcement.commentCount -= 1;
    _announcement.noteDeletedComment(id);
  }

  /// 맨 아래 고정된 댓글 입력칸 — 둥근 테두리, "댓글을 입력하세요....".
  Widget _buildCommentInput(BuildContext context) => PostCommentInput(
    controller: _commentController,
    sending: _sending,
    onSubmit: _postComment,
    inputKey: const ValueKey('announcement-comment-input'),
    sendKey: const ValueKey('announcement-comment-send'),
  );
}

/// 공지 읽음 확인 대화상자 — "읽음 N"·"안 읽음 M" 두 탭에 이름(읽은 쪽은 읽은 시각도)을 늘어놓는다.
/// 보드 게시글의 읽음 확인(message_thread_screen.dart)도 같은 모양이라 [title]만 바꿔 쓴다.
Future<void> showAnnouncementReadersDialog(
  BuildContext context,
  AnnouncementReaders readers, {
  String title = '공지 읽음 확인',
}) => showDialog<void>(
  context: context,
  builder: (dialogContext) {
    final hint = Theme.of(dialogContext).hintColor;
    Widget empty(String text) => Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(text, style: TextStyle(color: hint)),
      ),
    );
    return AlertDialog(
      title: Text(tr(title)),
      contentPadding: const EdgeInsets.fromLTRB(0, 8, 0, 0),
      content: SizedBox(
        width: 360,
        height: 420,
        child: DefaultTabController(
          length: 2,
          child: Column(
            children: [
              TabBar(
                tabs: [
                  Tab(
                    key: const ValueKey('announcement-readers-read-tab'),
                    text: tr('읽음 {readers.read.length}', {
                      'readers.read.length': readers.read.length,
                    }),
                  ),
                  Tab(
                    key: const ValueKey('announcement-readers-unread-tab'),
                    text: tr('안 읽음 {readers.unread.length}', {
                      'readers.unread.length': readers.unread.length,
                    }),
                  ),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    readers.read.isEmpty
                        ? empty(tr('아직 읽은 사람이 없습니다.'))
                        : ListView(
                            children: [
                              for (final r in readers.read)
                                ListTile(
                                  dense: true,
                                  leading: const Icon(Icons.done, size: 18),
                                  title: Text(r.name),
                                  trailing: Text(
                                    formatPostDateTime(r.readAt),
                                    style: TextStyle(fontSize: 11, color: hint),
                                  ),
                                ),
                            ],
                          ),
                    readers.unread.isEmpty
                        ? empty(tr('모두 읽었습니다.'))
                        : ListView(
                            children: [
                              for (final r in readers.unread)
                                ListTile(
                                  dense: true,
                                  leading: Icon(
                                    Icons.schedule,
                                    size: 18,
                                    color: hint,
                                  ),
                                  title: Text(r.name),
                                ),
                            ],
                          ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: Text(tr('닫기')),
        ),
      ],
    );
  },
);
