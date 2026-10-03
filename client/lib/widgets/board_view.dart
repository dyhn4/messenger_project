import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../models/app_user.dart';
import '../models/message.dart';
import '../models/room.dart';
import '../screens/message_thread_screen.dart';
import '../screens/poll_create_dialog.dart';
import '../screens/post_editor_dialog.dart';
import '../screens/scheduled_messages_screen.dart' show ScheduledRoomBar;
import '../services/edit_policy.dart';
import '../services/room_chat_controller.dart';
import '../services/session.dart';
import '../services/time_format.dart';
import 'app_toast.dart';
import 'attachment_widgets.dart';
import 'avatar_utils.dart';
import 'favorite_actions.dart';
import 'hover_toolbar.dart';
import 'mention_profile.dart';
import 'muted_scrollbar.dart';
import 'poll_card.dart';
import 'rich_text_format.dart';

/// 보드 목록 한 줄(카드)의 최대 폭 — 넓은 창에서 카드가 한없이 늘어나지 않게 가운데에 모은다.
const _boardMaxWidth = 820.0;

/// 고정된 게시글을 접어 둘 때 보여줄 개수.
const _pinnedPreviewCount = 3;

/// 보드 뷰 토픽(Room.isBoard)의 본문 — 채팅 목록 대신 제목이 있는 게시글(Message.isPost)을 최신 글이
/// 위로 오게 카드로 보여준다. 맨 위에는 고정된 게시글, 오른쪽 아래에는 글쓰기(연필) 버튼. 과거 글은
/// 아래로 내려가면 채팅과 같은 컨트롤러 페이지로 더 불러오고, 시스템 메시지(입장·퇴장 등)는 보드에서
/// 숨긴다. 새 글·수정·고정·삭제·댓글 수는 컨트롤러가 실시간으로 맞춘 목록을 그대로 다시 그린다.
class BoardView extends StatefulWidget {
  final Session session;
  final Room room;

  /// 검색 결과에서 열었을 때 — 그 게시글을 찾아 잠깐 강조하고 상세를 바로 연다.
  final String? highlightMessageId;

  /// 게시글 상세(본문+댓글)를 여는 방법 — 데스크톱은 오른쪽 댓글 패널, 모바일은 새 화면(ChatPanel의
  /// onOpenThread를 그대로 받는다). 없으면 여기서 새 화면으로 연다.
  final void Function(Message post)? onOpenPost;

  const BoardView({
    super.key,
    required this.session,
    required this.room,
    this.highlightMessageId,
    this.onOpenPost,
  });

  @override
  State<BoardView> createState() => BoardViewState();
}

/// 보드에 끌어다 놓은 파일로 새 글을 시작할 수 있게(chat_panel.dart) 공개해 둔다.
class BoardViewState extends State<BoardView> {
  /// 방이 사라지면(나가기·내보내짐) Session이 컨트롤러를 치우는데, 그 뒤에 controllerFor를 다시
  /// 부르면 새로 만들어져 버린다 — 처음 받은 것을 계속 쓴다.
  late final RoomChatController _c = widget.session.controllerFor(widget.room);

  /// 목록(컨트롤러)과 방 설정(세션)의 변경 알림 — 한 번만 만들어 둔다. 그릴 때마다 새로 합치면 다시
  /// 그릴 때마다 구독을 새로 거는데, 방이 사라져 컨트롤러가 치워진 뒤라면 그 구독이 오류가 된다.
  late final Listenable _changes = Listenable.merge([_c, widget.session]);
  final _scroll = ScrollController();
  bool _pinnedExpanded = false;
  String? _highlightedId;
  Timer? _highlightTimer;

  /// "3분 전" 같은 상대 시각이 멈춰 보이지 않게 1분마다 다시 그린다.
  Timer? _clock;

  /// 내용이 한 화면이 안 돼서 스크롤로는 더 불러올 수 없을 때 자동으로 한 번 더 불러온 시점의
  /// 메시지 수 — 같은 상태에서 되풀이하지 않게(실패가 이어질 때 서버를 계속 두드리지 않게).
  int? _autoLoadedAt;

  /// 지금까지 본 가장 최신 게시글의 작성 시각 — 이보다 새 글이 오면 "새 게시글" 알약을 띄운다.
  DateTime? _newestSeen;
  final _newPostsAbove = ValueNotifier<bool>(false);

  @override
  void initState() {
    super.initState();
    // 고정 목록은 보드를 열 때마다 새로 받는다 — 그 뒤로는 컨트롤러가 실시간으로 맞춘다.
    unawaited(_c.loadPinnedPosts());
    _newestSeen = _newestPost()?.createdAt;
    _c.addListener(_onPostsChanged);
    _clock = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
    _openHighlighted();
  }

  @override
  void didUpdateWidget(covariant BoardView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 같은 보드를 보는 채로 다른 검색 결과를 눌렀을 때.
    if (widget.highlightMessageId != null &&
        widget.highlightMessageId != oldWidget.highlightMessageId) {
      _openHighlighted();
    }
  }

  @override
  void dispose() {
    _c.removeListener(_onPostsChanged);
    _highlightTimer?.cancel();
    _clock?.cancel();
    _scroll.dispose();
    _newPostsAbove.dispose();
    super.dispose();
  }

  /// 보드에 보일 게시글 — 최신 글이 위, 지운 글·시스템 메시지·댓글 항목은 뺀다.
  List<Message> _posts() {
    final seen = <String>{};
    final posts = [
      for (final m in _c.messages)
        if ((m.isPost || m.isPoll) && !m.deleted && seen.add(m.id)) m,
    ]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return posts;
  }

  Message? _newestPost() {
    Message? newest;
    for (final m in _c.messages) {
      if ((!m.isPost && !m.isPoll) || m.deleted) continue;
      if (newest == null || m.createdAt.isAfter(newest.createdAt)) newest = m;
    }
    return newest;
  }

  Message? _findPost(String id) {
    for (final m in _c.messages) {
      if (m.id == id && (m.isPost || m.isPoll)) return m;
    }
    for (final m in _c.pinnedPosts) {
      if (m.id == id) return m;
    }
    return null;
  }

  void _onPostsChanged() {
    final newest = _newestPost();
    final seen = _newestSeen;
    if (newest == null || (seen != null && !newest.createdAt.isAfter(seen))) {
      return;
    }
    _newestSeen = newest.createdAt;
    if (seen == null) return; // 처음 불러온 목록 — 새 글 알림 대상이 아니다.
    if (newest.senderId != null && newest.senderId == widget.session.userId) {
      _scrollToTop(); // 내가 방금 올린 글은 바로 보이게.
    } else if (_scroll.hasClients && _scroll.offset > 120) {
      _newPostsAbove.value = true;
    }
  }

  void _scrollToTop() {
    _newPostsAbove.value = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.animateTo(
        0,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _openHighlighted() async {
    final id = widget.highlightMessageId;
    if (id == null) return;
    await _c.ensureMessageLoaded(id);
    if (!mounted || widget.highlightMessageId != id) return;
    final post = _findPost(id);
    if (post == null) return; // 보존기간 파기 등으로 이미 없으면 조용히 넘어간다.
    setState(() => _highlightedId = id);
    _highlightTimer?.cancel();
    _highlightTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _highlightedId = null);
    });
    _openPost(post);
  }

  void _openPost(Message post) {
    final open = widget.onOpenPost;
    if (open != null) {
      open(post);
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MessageThreadScreen(
          session: widget.session,
          room: widget.room,
          message: post,
          controller: _c,
        ),
      ),
    );
  }

  /// 새 게시글 쓰기 — 보드에 파일을 끌어다 놓으면(chat_panel.dart) 그 파일을 붙인 채로 연다.
  Future<void> compose({List<File> files = const []}) async {
    if (!widget.room.canWrite(widget.session)) return;
    await showPostEditor(
      context,
      session: widget.session,
      room: widget.room,
      initialFiles: files,
    );
  }

  /// 투표 만들기 — 보드 토픽이라 파일도 붙일 수 있다(최대 30개). 만들면 message:new로 카드가 나타난다.
  Future<void> composePoll() async {
    if (!canCreatePollIn(widget.session, widget.room)) return;
    await showPollCreator(context, session: widget.session, room: widget.room);
  }

  /// 목록 끝 근처에서 스크롤이 멈추면 과거 글을 더 불러온다(채팅과 같은 컨트롤러 페이지).
  void _maybeLoadOlder() {
    if (!_scroll.hasClients || !_c.hasMoreHistory || _c.loadingMore) return;
    if (_scroll.position.extentAfter < 600) _c.loadOlderMessages();
  }

  /// 불러온 페이지에 게시글이 적어(시스템 메시지만 있는 등) 스크롤할 거리가 없으면 스크롤로는 더
  /// 불러올 수 없으니, 화면이 채워질 때까지 알아서 이어 불러온다.
  void _scheduleAutoLoad() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_c.loading || _c.loadingMore || !_c.hasMoreHistory) return;
      if (_autoLoadedAt == _c.messages.length) return;
      final nearEnd = !_scroll.hasClients || _scroll.position.extentAfter < 600;
      if (!nearEnd) return;
      _autoLoadedAt = _c.messages.length;
      _c.loadOlderMessages();
      // 불러오기가 시작되지 않았으면(더 받을 게 없는 등) 알림도 없으니, 로딩 표시가 남지 않게 직접
      // 다시 그린다.
      if (!_c.loadingMore) setState(() {});
    });
  }

  Future<void> _refresh() async {
    // 처음 불러오기가 실패했으면 처음부터(과거 페이지 커서까지) 다시 받는다 — refresh는 최근
    // 글만 합친다.
    final timeline = _c.error != null && _c.messages.isEmpty
        ? _c.retryLoad()
        : _c.refresh();
    await Future.wait([timeline, _c.loadPinnedPosts()]);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      // 방 설정(읽기 전용·토픽 관리자)이 바뀌면 글쓰기 버튼·메뉴도 바로 바뀌어야 해서 세션도 듣는다.
      listenable: _changes,
      builder: (context, _) {
        final colors = BoardColors.of(Theme.of(context));
        final canWrite = widget.room.canWrite(widget.session);
        final bottomInset = MediaQuery.paddingOf(context).bottom;
        final board = ColoredBox(
          color: colors.background,
          child: LayoutBuilder(
            builder: (context, constraints) => Stack(
              children: [
                Positioned.fill(
                  child: _buildBody(context, canWrite, bottomInset),
                ),
                Positioned(
                  top: 12,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: ValueListenableBuilder<bool>(
                      valueListenable: _newPostsAbove,
                      builder: (context, show, _) => show
                          ? _NewPostsPill(onTap: _scrollToTop)
                          : const SizedBox.shrink(),
                    ),
                  ),
                ),
                if (canWrite)
                  Positioned(
                    right: 20,
                    bottom: 20 + bottomInset,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        // 투표 만들기 — 게시글 작성 버튼 바로 위의 작은 버튼(보드에는 채팅 입력칸이 없다).
                        FloatingActionButton.small(
                          key: const ValueKey('board-poll'),
                          heroTag: null,
                          tooltip: '투표 만들기',
                          onPressed: composePoll,
                          child: const Icon(Icons.poll_outlined),
                        ),
                        const SizedBox(height: 12),
                        _ComposeButton(
                          extended: constraints.maxWidth >= 600,
                          onPressed: compose,
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        );
        // 글을 쓸 수 없는 읽기 전용·보관된 보드 — 채팅 입력칸 자리의 안내(chat_input_bar.dart)와 같은
        // 문구를 아래에 둔다(보드에는 입력칸이 없어 글쓰기 버튼이 왜 없는지 알 수 없으니).
        final readOnly =
            !canWrite && (widget.room.readOnly || widget.room.isArchived);
        return Column(
          children: [
            // 이 보드에 예약해 둔 게시글이 있으면 맨 위에 "예약된 게시글 N개 · 보기"(없으면 자리도 없다).
            ColoredBox(
              color: colors.background,
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: _boardMaxWidth + 32,
                  ),
                  child: ScheduledRoomBar(
                    session: widget.session,
                    room: widget.room,
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  ),
                ),
              ),
            ),
            Expanded(child: board),
            if (readOnly) _ReadOnlyNotice(archived: widget.room.isArchived),
          ],
        );
      },
    );
  }

  Widget _buildBody(BuildContext context, bool canWrite, double bottomInset) {
    if (_c.loading) return const Center(child: CircularProgressIndicator());
    // 처음 불러오기가 실패했으면 계속 도는 로딩 대신 알리고 다시 시도하게 한다.
    if (_c.error != null && _c.messages.isEmpty) {
      return _BoardLoadError(onRetry: () => unawaited(_refresh()));
    }
    final posts = _posts();
    final pinned = [
      for (final p in _c.pinnedPosts)
        if (!p.deleted) p,
    ];
    _scheduleAutoLoad();
    if (posts.isEmpty && pinned.isEmpty) {
      final stillLoading =
          _c.loadingMore ||
          (_c.hasMoreHistory && _autoLoadedAt != _c.messages.length);
      if (stillLoading) return const Center(child: CircularProgressIndicator());
      return _EmptyBoard(canWrite: canWrite);
    }

    final hasPinned = pinned.isNotEmpty;
    final itemCount = (hasPinned ? 1 : 0) + posts.length + 1;
    final list = ListView.builder(
      key: const ValueKey('board-list'),
      controller: _scroll,
      physics: const AlwaysScrollableScrollPhysics(),
      // 아래는 글쓰기 버튼이 마지막 카드를 가리지 않을 만큼 비워 둔다.
      padding: EdgeInsets.fromLTRB(16, 16, 16, 96 + bottomInset),
      itemCount: itemCount,
      itemBuilder: (context, i) {
        final Widget item;
        if (hasPinned && i == 0) {
          item = _PinnedSection(
            session: widget.session,
            room: widget.room,
            posts: pinned,
            expanded: _pinnedExpanded,
            onToggle: () => setState(() => _pinnedExpanded = !_pinnedExpanded),
            onOpen: _openPost,
          );
        } else if (i == itemCount - 1) {
          return _c.loadingMore
              ? const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                )
              : const SizedBox.shrink();
        } else {
          final post = posts[i - (hasPinned ? 1 : 0)];
          item = post.isPoll
              ? PollBoardCard(
                  key: ValueKey('poll-${post.id}'),
                  session: widget.session,
                  room: widget.room,
                  poll: post,
                  highlighted: post.id == _highlightedId,
                  onOpen: () => _openPost(post),
                  onDelete: _c.deleteMessage,
                )
              : PostCard(
                  key: ValueKey('post-${post.id}'),
                  session: widget.session,
                  room: widget.room,
                  post: post,
                  highlighted: post.id == _highlightedId,
                  onOpen: () => _openPost(post),
                );
        }
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _boardMaxWidth),
            child: Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: item,
            ),
          ),
        );
      },
    );
    // PC는 채팅방처럼 늘 보이는 스크롤바를 붙이고, 휴대폰은 기본(스크롤할 때만) 그대로 둔다.
    final desktop = switch (Theme.of(context).platform) {
      TargetPlatform.windows ||
      TargetPlatform.macOS ||
      TargetPlatform.linux => true,
      _ => false,
    };
    return RefreshIndicator(
      onRefresh: _refresh,
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (n is ScrollEndNotification) _maybeLoadOlder();
          if (n is ScrollUpdateNotification && n.metrics.pixels < 40) {
            _newPostsAbove.value = false;
          }
          return false;
        },
        child: desktop
            ? MutedScrollbar(controller: _scroll, child: list)
            : list,
      ),
    );
  }
}

/// 보드 화면의 색 — 밝은 테마는 옅은 회색 바탕에 흰 카드(프로젝트 홈 카드와 같은 테두리·그림자),
/// 어두운 테마는 바탕보다 한 단계 밝은 카드.
class BoardColors {
  final Color background;
  final Color card;
  final Color border;
  final List<BoxShadow>? shadow;
  final Color pin;

  const BoardColors._({
    required this.background,
    required this.card,
    required this.border,
    required this.shadow,
    required this.pin,
  });

  factory BoardColors.of(ThemeData theme) {
    final dark = theme.brightness == Brightness.dark;
    final s = theme.colorScheme;
    return BoardColors._(
      background: dark ? s.surface : s.surfaceContainerLow,
      card: dark ? s.surfaceContainer : s.surfaceContainerLowest,
      border: dark ? theme.dividerColor : const Color(0xFFE6E8EC),
      shadow: dark
          ? null
          : [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.04),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
      pin: dark ? const Color(0xFFFFB74D) : const Color(0xFFE8590C),
    );
  }
}

AppUser? _memberOf(Room room, String? userId) {
  if (userId == null) return null;
  for (final m in room.members) {
    if (m.id == userId) return m;
  }
  return null;
}

/// 이름이 바뀌었을 수 있으니 게시글에 박제된 이름보다 지금 멤버 이름을 먼저 쓴다.
String _authorName(Room room, Message post) =>
    _memberOf(room, post.senderId)?.name ?? post.senderName;

Widget _authorAvatar(Session session, Room room, Message post, double radius) {
  final member = _memberOf(room, post.senderId);
  return AvatarView(
    username: member?.name ?? post.senderName,
    avatarType: member?.avatarType ?? 'initial',
    avatarEmoji: member?.avatarEmoji,
    avatarColor: member?.avatarColor,
    avatarUrl: member?.avatarUrl,
    resolveUrl: session.resolveUrl,
    radius: radius,
  );
}

int _visibleCommentCount(Message post) =>
    post.comments.where((c) => !c.deleted).length;

bool _isMine(Session session, Message post) =>
    post.senderId != null && post.senderId == session.userId;

/// 게시글 수정 — 본인 글이고, 이 토픽에 글을 쓸 수 있을 때(읽기 전용·보관이면 토픽을 관리할 수
/// 있는 사람만). 팀이 메시지 수정/삭제를 꺼두면 아무도 못 한다(서버 moderation.js와 같은 규칙).
bool canEditPost(Session session, Room room, Message post) =>
    !post.deleted &&
    _isMine(session, post) &&
    room.canWrite(session) &&
    isEditDeleteAllowed(session);

/// 게시글 삭제 — 본인 또는 토픽을 관리할 수 있는 사람. 게시글은 수정/삭제 가능 시간 제한이 없다.
bool canDeletePost(Session session, Room room, Message post) =>
    !post.deleted &&
    (_isMine(session, post) || room.canManage(session)) &&
    isEditDeleteAllowed(session);

/// 게시글 고정/해제 — 토픽을 관리할 수 있는 사람만.
bool canPinPost(Session session, Room room, Message post) =>
    !post.deleted && room.canManage(session);

Future<void> togglePostPin(
  BuildContext context,
  Session session,
  Room room,
  Message post,
) async {
  final pin = !post.isPinned;
  try {
    await session.setPostPinned(room, post.id, pin);
    if (context.mounted) {
      showAppToast(context, pin ? '게시글을 고정했습니다.' : '게시글 고정을 해제했습니다.');
    }
  } catch (e) {
    if (context.mounted) showAppToast(context, '$e');
  }
}

/// 한 번 더 묻고 게시글을 지운다. 지웠으면 true.
Future<bool> confirmAndDeletePost(
  BuildContext context,
  Session session,
  Room room,
  Message post,
) async {
  final title = post.title ?? '';
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('게시글 삭제'),
      content: Text(
        _isMine(session, post)
            ? "'$title' 게시글을 삭제할까요?"
            : "관리자 권한으로 ${_authorName(room, post)} 님의 게시글 '$title'을(를) 삭제합니다. 계속할까요?",
      ),
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
  if (confirmed != true) return false;
  try {
    await session.api!.deleteMessage(post.id);
  } catch (e) {
    if (context.mounted) showAppToast(context, '$e');
    return false;
  }
  // 서버 알림(message:deleted)을 기다리지 않고 바로 뺀다 — 같은 알림이 나중에 와도 결과는 같다.
  // 그 사이 방이 사라졌으면 치워진 컨트롤러를 다시 만들지 않는다.
  session.existingControllerFor(room.id)?.applyDelete(post.id);
  if (context.mounted) showAppToast(context, '게시글을 삭제했습니다.');
  return true;
}

/// 게시글 카드·상세의 "더보기"(⋯) — 고정/해제(토픽을 관리할 수 있는 사람), 수정(작성자), 삭제
/// (작성자 또는 토픽을 관리할 수 있는 사람). 할 수 있는 게 없으면 단추를 숨긴다.
class PostMoreButton extends StatelessWidget {
  final Session session;
  final Room room;
  final Message post;

  /// 지운 뒤 — 게시글 상세라면 닫는다.
  final VoidCallback? onDeleted;

  const PostMoreButton({
    super.key,
    required this.session,
    required this.room,
    required this.post,
    this.onDeleted,
  });

  @override
  Widget build(BuildContext context) {
    final canPin = canPinPost(session, room, post);
    final canEdit = canEditPost(session, room, post);
    final canDelete = canDeletePost(session, room, post);
    // 즐겨찾기는 누구나 켤 수 있어 이 단추는 이제 항상 보인다(favorite_actions.dart).
    final canFavorite = canFavoriteEntry(session, post, isComment: false);
    final favoriteOn = isEntryFavorite(session, post.id, isComment: false);
    if (!canPin && !canEdit && !canDelete && !canFavorite) {
      return const SizedBox(width: 8);
    }
    return MenuAnchor(
      style: hoverMenuStyle(context),
      menuChildren: [
        if (canFavorite)
          hoverMenuItem(
            icon: favoriteOn ? Icons.star : Icons.star_border,
            label: favoriteOn ? '즐겨찾기 해제' : '즐겨찾기',
            onPressed: () =>
                toggleEntryFavorite(context, session, post.id, isComment: false),
          ),
        if (canFavorite && (canPin || canEdit || canDelete)) hoverMenuDivider(),
        if (canPin)
          hoverMenuItem(
            icon: post.isPinned ? Icons.push_pin : Icons.push_pin_outlined,
            label: post.isPinned ? '게시글 고정 해제' : '게시글 고정',
            onPressed: () => togglePostPin(context, session, room, post),
          ),
        if (canEdit)
          hoverMenuItem(
            icon: Icons.edit_outlined,
            label: '수정',
            onPressed: () => showPostEditor(
              context,
              session: session,
              room: room,
              post: post,
            ),
          ),
        if (canDelete) ...[
          if (canPin || canEdit) hoverMenuDivider(),
          hoverMenuItem(
            icon: Icons.delete_outline,
            label: '삭제',
            color: Colors.redAccent,
            onPressed: () async {
              if (await confirmAndDeletePost(context, session, room, post)) {
                onDeleted?.call();
              }
            },
          ),
        ],
      ],
      builder: (context, controller, _) => IconButton(
        icon: const Icon(Icons.more_horiz),
        tooltip: '더보기',
        visualDensity: VisualDensity.compact,
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }
}

/// 카드 테두리 — 프로젝트 홈 카드와 같은 흰 바탕·옅은 테두리·그림자.
BoxDecoration _cardDecoration(
  BoardColors colors, {
  Color? border,
  double borderWidth = 1,
  Color? color,
}) => BoxDecoration(
  color: color ?? colors.card,
  borderRadius: BorderRadius.circular(14),
  border: Border.all(color: border ?? colors.border, width: borderWidth),
  boxShadow: colors.shadow,
);

/// 공지 목록 카드처럼 보드 밖에서 같은 카드 모양을 쓰는 화면용.
BoxDecoration boardCardDecoration(
  BoardColors colors, {
  Color? border,
  double borderWidth = 1,
  Color? color,
}) => _cardDecoration(
  colors,
  border: border,
  borderWidth: borderWidth,
  color: color,
);

/// 보드 목록의 게시글 카드 — 작성자·작성 시각(yyyy/MM/dd AM h:mm, 수정됨), 굵은 제목, 본문 세 줄, 첨부 미리보기(사진
/// 네 장까지 + 파일 N개), 댓글 수. 누르면 상세(본문+댓글)가 열린다.
class PostCard extends StatelessWidget {
  final Session session;
  final Room room;
  final Message post;
  final bool highlighted;
  final VoidCallback onOpen;

  const PostCard({
    super.key,
    required this.session,
    required this.room,
    required this.post,
    required this.onOpen,
    this.highlighted = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = BoardColors.of(theme);
    final primary = theme.colorScheme.primary;
    final hint = theme.hintColor;
    final text = post.text?.trim() ?? '';
    final comments = _visibleCommentCount(post);
    final commentColor = comments > 0 ? primary : hint;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      decoration: _cardDecoration(
        colors,
        border: highlighted ? primary : null,
        borderWidth: highlighted ? 1.5 : 1,
        color: highlighted
            ? Color.alphaBlend(primary.withValues(alpha: 0.06), colors.card)
            : null,
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onOpen,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 6, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _authorAvatar(session, room, post, 17),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  _authorName(room, post),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                    fontSize: 14,
                                  ),
                                ),
                              ),
                              if (post.isPinned) ...[
                                const SizedBox(width: 6),
                                const PinnedPostTag(),
                              ],
                            ],
                          ),
                          const SizedBox(height: 1),
                          Text(
                            '${formatPostDateTime(post.createdAt)}'
                            '${post.editedAt != null ? ' (수정됨)' : ''}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12, color: hint),
                          ),
                        ],
                      ),
                    ),
                    PostMoreButton(session: session, room: room, post: post),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 10),
                      Text(
                        post.title ?? '',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          height: 1.35,
                        ),
                      ),
                      if (text.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(
                          text,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            height: 1.5,
                            color: theme.colorScheme.onSurface.withValues(
                              alpha: 0.8,
                            ),
                          ),
                        ),
                      ],
                      if (post.liveAttachments.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        _AttachmentPreview(session: session, post: post),
                      ],
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Icon(
                            Icons.mode_comment_outlined,
                            size: 16,
                            color: commentColor,
                          ),
                          const SizedBox(width: 5),
                          Text(
                            '댓글 $comments',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: commentColor,
                            ),
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
      ),
    );
  }
}

/// 보드 목록의 투표 카드 — 게시글 카드와 같은 테두리·작성자 줄 아래에 투표 카드(PollCard)를 그대로
/// 넣는다(보기를 눌러 바로 투표한다). 댓글·즐겨찾기·마감·삭제는 PollCard의 더보기(⋯)에서 하고,
/// 댓글은 게시글처럼 오른쪽 상세(스레드)가 열린다.
class PollBoardCard extends StatelessWidget {
  final Session session;
  final Room room;
  final Message poll;
  final bool highlighted;
  final VoidCallback onOpen;
  final Future<void> Function(String messageId)? onDelete;

  const PollBoardCard({
    super.key,
    required this.session,
    required this.room,
    required this.poll,
    required this.onOpen,
    this.highlighted = false,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = BoardColors.of(theme);
    final primary = theme.colorScheme.primary;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
      decoration: _cardDecoration(
        colors,
        border: highlighted ? primary : null,
        borderWidth: highlighted ? 1.5 : 1,
        color: highlighted
            ? Color.alphaBlend(primary.withValues(alpha: 0.06), colors.card)
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _authorAvatar(session, room, poll, 17),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _authorName(room, poll),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      formatPostDateTime(poll.createdAt),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: theme.hintColor),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          PollCard(
            session: session,
            message: poll,
            room: room,
            onOpenThread: (_) => onOpen(),
            onDelete: onDelete,
            maxWidth: 560,
          ),
        ],
      ),
    );
  }
}

/// 카드의 첨부 미리보기 — 사진은 앞의 네 장까지 작은 정사각형(더 있으면 마지막 칸에 +N), 파일은
/// "파일 N개" 한 칸. 누르면 카드처럼 상세가 열린다(거기서 크게 보고 내려받는다).
class _AttachmentPreview extends StatelessWidget {
  final Session session;
  final Message post;
  const _AttachmentPreview({required this.session, required this.post});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final live = post.liveAttachments;
    final images = [
      for (final a in live)
        if (a.isImage) a,
    ];
    final files = live.length - images.length;
    const gap = 8.0;
    return LayoutBuilder(
      builder: (context, constraints) {
        // 사진 네 장이 한 줄에 들어가게 — 좁은 휴대폰에서는 칸을 조금 줄인다.
        final size = math.min(80.0, (constraints.maxWidth - gap * 3) / 4);
        final shown = images.take(4).toList();
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (var i = 0; i < shown.length; i++)
              _Thumbnail(
                session: session,
                attachment: shown[i],
                size: size,
                more: i == shown.length - 1 ? images.length - shown.length : 0,
              ),
            if (files > 0)
              Container(
                key: const ValueKey('post-files-tag'),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest.withValues(
                    alpha: 0.6,
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.attach_file,
                      size: 15,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '파일 $files개',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

class _Thumbnail extends StatelessWidget {
  final Session session;
  final MessageAttachment attachment;
  final double size;

  /// 이 칸 뒤에 더 있는 사진 수 — 0보다 크면 "+N"을 덮는다.
  final int more;
  const _Thumbnail({
    required this.session,
    required this.attachment,
    required this.size,
    this.more = 0,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fallback = SizedBox(
      width: size,
      height: size,
      child: Icon(Icons.image_outlined, color: scheme.onSurfaceVariant),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: size,
        height: size,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: scheme.surfaceContainerHighest),
            CachedNetworkImage(
              imageUrl: session.resolveUrl(
                attachment.thumbnailUrl ?? attachment.fileUrl,
              ),
              width: size,
              height: size,
              fit: BoxFit.cover,
              placeholder: (_, _) => const SizedBox.shrink(),
              errorWidget: (_, _, _) => fallback,
            ),
            if (more > 0)
              ColoredBox(
                color: Colors.black.withValues(alpha: 0.5),
                child: Center(
                  child: Text(
                    '+$more',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 이름 옆의 작은 "고정" 표시.
class PinnedPostTag extends StatelessWidget {
  const PinnedPostTag({super.key});

  @override
  Widget build(BuildContext context) {
    final color = BoardColors.of(Theme.of(context)).pin;
    return Tooltip(
      message: '고정된 게시글',
      child: Container(
        padding: const EdgeInsets.fromLTRB(5, 1, 7, 1),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.push_pin, size: 11, color: color),
            const SizedBox(width: 2),
            Text(
              '고정',
              style: TextStyle(
                fontSize: 11,
                height: 1.3,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 맨 위 "고정된 게시글 N" — 세 개까지 작은 카드로, 더 있으면 "더 보기"로 펼친다(게시글 작성 시각
/// 최신순, 서버 GET /rooms/:id/pinned-posts 순서 그대로).
class _PinnedSection extends StatelessWidget {
  final Session session;
  final Room room;
  final List<Message> posts;
  final bool expanded;
  final VoidCallback onToggle;
  final void Function(Message post) onOpen;

  const _PinnedSection({
    required this.session,
    required this.room,
    required this.posts,
    required this.expanded,
    required this.onToggle,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = BoardColors.of(theme);
    final shown = expanded ? posts : posts.take(_pinnedPreviewCount).toList();
    final hidden = posts.length - _pinnedPreviewCount;
    return Column(
      key: const ValueKey('board-pinned'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 0, 8),
          child: Row(
            children: [
              Icon(Icons.push_pin, size: 16, color: colors.pin),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '고정된 게시글 ${posts.length}',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (hidden > 0)
                TextButton.icon(
                  onPressed: onToggle,
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    // 테마 글꼴(한글 대체 글꼴 포함)을 그대로 쓰고 크기·굵기만 바꾼다 — 맨
                    // TextStyle을 주면 버튼 글자가 테마의 대체 글꼴을 잃는다.
                    textStyle: theme.textTheme.labelLarge?.copyWith(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  iconAlignment: IconAlignment.end,
                  icon: Icon(
                    expanded ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                  ),
                  label: Text(expanded ? '접기' : '더 보기'),
                ),
            ],
          ),
        ),
        for (var i = 0; i < shown.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          _PinnedPostTile(
            key: ValueKey('pinned-${shown[i].id}'),
            session: session,
            room: room,
            post: shown[i],
            onOpen: () => onOpen(shown[i]),
          ),
        ],
      ],
    );
  }
}

class _PinnedPostTile extends StatelessWidget {
  final Session session;
  final Room room;
  final Message post;
  final VoidCallback onOpen;
  const _PinnedPostTile({
    super.key,
    required this.session,
    required this.room,
    required this.post,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = BoardColors.of(theme);
    final hint = theme.hintColor;
    final comments = _visibleCommentCount(post);
    return DecoratedBox(
      decoration: _cardDecoration(colors),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onOpen,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 14, 10),
            child: Row(
              children: [
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: colors.pin.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.push_pin, size: 15, color: colors.pin),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        post.title ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${_authorName(room, post)} · ${formatPostDateTime(post.createdAt)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: hint),
                      ),
                    ],
                  ),
                ),
                if (comments > 0) ...[
                  const SizedBox(width: 8),
                  Icon(Icons.mode_comment_outlined, size: 14, color: hint),
                  const SizedBox(width: 3),
                  Text(
                    '$comments',
                    style: TextStyle(fontSize: 12, color: hint),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 게시글이 하나도 없을 때.
class _EmptyBoard extends StatelessWidget {
  final bool canWrite;
  const _EmptyBoard({required this.canWrite});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 88,
              height: 88,
              decoration: BoxDecoration(
                color: primary.withValues(alpha: 0.08),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.dashboard_outlined, size: 40, color: primary),
            ),
            const SizedBox(height: 18),
            Text(
              '아직 게시글이 없습니다.',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            if (canWrite) ...[
              const SizedBox(height: 6),
              Text(
                '오른쪽 아래 연필 버튼으로 첫 게시글을 작성해 보세요.',
                textAlign: TextAlign.center,
                style: TextStyle(color: theme.hintColor),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 게시글 목록을 처음 불러오지 못했을 때 — 계속 도는 로딩 대신 알리고 다시 시도하게 한다.
class _BoardLoadError extends StatelessWidget {
  final VoidCallback onRetry;
  const _BoardLoadError({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_outlined, size: 40, color: theme.hintColor),
            const SizedBox(height: 14),
            Text(
              '게시글을 불러오지 못했습니다.',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '연결 상태를 확인한 뒤 다시 시도해 주세요.',
              textAlign: TextAlign.center,
              style: TextStyle(color: theme.hintColor),
            ),
            const SizedBox(height: 16),
            FilledButton.tonalIcon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('다시 시도'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 읽기 전용·보관된 보드에서 글을 쓸 수 없는 멤버에게 보이는 아래쪽 안내 줄.
class _ReadOnlyNotice extends StatelessWidget {
  final bool archived;
  const _ReadOnlyNotice({required this.archived});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
        border: Border(top: BorderSide(color: theme.dividerColor)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                archived ? Icons.inventory_2_outlined : Icons.edit_off_outlined,
                size: 16,
                color: hint,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  archived
                      ? '보관된 토픽입니다. 토픽 관리자만 글을 쓸 수 있습니다.'
                      : '읽기 전용 토픽입니다. 토픽 관리자만 글을 쓸 수 있습니다.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: hint),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 오른쪽 아래 글쓰기(연필) 버튼 — 넓은 화면은 "게시글 작성" 글자까지, 좁은 화면은 동그란 버튼만.
class _ComposeButton extends StatelessWidget {
  final bool extended;
  final VoidCallback onPressed;
  const _ComposeButton({required this.extended, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    // heroTag: null — 목록 화면 등 다른 화면의 버튼과 화면 전환 애니메이션이 엮이지 않게.
    if (extended) {
      return FloatingActionButton.extended(
        key: const ValueKey('board-compose'),
        heroTag: null,
        tooltip: '게시글 작성',
        onPressed: onPressed,
        icon: const Icon(Icons.edit),
        label: const Text('게시글 작성'),
      );
    }
    return FloatingActionButton(
      key: const ValueKey('board-compose'),
      heroTag: null,
      tooltip: '게시글 작성',
      onPressed: onPressed,
      child: const Icon(Icons.edit),
    );
  }
}

/// 위로 스크롤해 둔 채 남이 새 글을 올렸을 때 뜨는 알약 — 누르면 맨 위로.
class _NewPostsPill extends StatelessWidget {
  final VoidCallback onTap;
  const _NewPostsPill({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(20),
      color: scheme.primaryContainer,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.arrow_upward,
                size: 16,
                color: scheme.onPrimaryContainer,
              ),
              const SizedBox(width: 6),
              Text(
                '새 게시글이 있습니다',
                style: TextStyle(
                  color: scheme.onPrimaryContainer,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 게시글 상세(댓글 스레드 화면 맨 위) — 작성자·작성 시각, 제목, 서식이 살아 있는 본문, 첨부(사진은
/// 채팅과 같은 격자·뷰어, 파일은 열기·내려받기). 오른쪽 위 ⋯로 고정·수정·삭제.
class PostDetailHead extends StatelessWidget {
  final Session session;
  final Room room;
  final Message post;

  /// 이 화면에서 게시글을 지웠을 때(상세를 닫는다).
  final VoidCallback? onDeleted;

  const PostDetailHead({
    super.key,
    required this.session,
    required this.room,
    required this.post,
    this.onDeleted,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final images = [
      for (final a in post.liveAttachments)
        if (a.isImage) a,
    ];
    final files = [
      for (final a in post.liveAttachments)
        if (!a.isImage) a,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _authorAvatar(session, room, post, 18),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _authorName(room, post),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                    ),
                  ),
                  Text(
                    '${formatPostDateTime(post.createdAt)}'
                    '${post.editedAt != null ? ' (수정됨)' : ''}',
                    style: TextStyle(fontSize: 12, color: hint),
                  ),
                ],
              ),
            ),
            if (post.isPinned) ...[
              const PinnedPostTag(),
              const SizedBox(width: 2),
            ],
            PostMoreButton(
              session: session,
              room: room,
              post: post,
              onDeleted: onDeleted,
            ),
          ],
        ),
        const SizedBox(height: 14),
        if (post.deleted)
          Text(
            '삭제된 게시글입니다.',
            style: TextStyle(fontStyle: FontStyle.italic, color: hint),
          )
        else ...[
          // Windows(마우스)에서는 제목·본문을 끌어서 바로 고를 수 있게(말풍선과 같은 규칙).
          Platform.isWindows
              ? SelectableText(post.title ?? '', style: _titleStyle(theme))
              : Text(post.title ?? '', style: _titleStyle(theme)),
          const SizedBox(height: 12),
          FormattedText(
            post.text ?? '',
            format: post.textFormat,
            style: const TextStyle(fontSize: 15, height: 1.6),
            linkColor: Colors.blue,
            selectable: Platform.isWindows,
            mentions: post.mentions,
            myUserId: session.userId,
            onMentionTap: (m) => openMentionProfile(
              context,
              session,
              roomId: room.id,
              mention: m,
            ),
          ),
          if (images.isNotEmpty) ...[
            const SizedBox(height: 16),
            ChatImageAttachments(
              session: session,
              attachments: images,
              message: post,
              room: room,
            ),
          ],
          if (files.isNotEmpty) ...[
            const SizedBox(height: 12),
            ChatFileAttachments(
              session: session,
              attachments: files,
              message: post,
            ),
          ],
        ],
      ],
    );
  }

  static TextStyle? _titleStyle(ThemeData theme) => theme.textTheme.titleLarge
      ?.copyWith(fontSize: 20, fontWeight: FontWeight.w700, height: 1.35);
}
