import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/bookmark.dart';
import '../screens/bookmark_editor_dialog.dart';
import '../services/bookmark_api.dart';
import '../services/bookmark_controller.dart';
import '../services/session.dart';
import 'app_toast.dart';
import 'bookmark_image.dart';
import 'side_panel_header.dart';

/// 북마크 패널(side_panels.dart의 'bookmarks') — 잔디의 북마크와 같다. 이미지·제목·링크 카드를 팀 북마크/개인 북마크
/// 탭으로 나눠 보여 주고, 카드를 누르면 외부 브라우저로 연다. 수정·삭제는 만든 사람과 팀 관리자만(⋯ 메뉴), "순서 변경"은
/// PC에서만 있고 팀 북마크 순서는 팀 관리자만 바꾼다(드래그 후 "완료").
///
/// 상태는 패널이 열릴 때 만드는 [BookmarkController]가 들고 있고(Session에는 두지 않는다), 서버의 bookmark:changed
/// 알림이 오면 조용히 다시 받는다. [controller]·[isDesktop]·[openUrl]은 테스트가 바꿔 끼우는 값이다.
class BookmarksPanel extends StatefulWidget {
  final Session session;
  final VoidCallback? onClose;
  final BookmarkController? controller;

  /// 순서 변경 단추를 보일지(PC) — 안 주면 안드로이드·iOS가 아니면 PC로 본다.
  final bool? isDesktop;
  final Future<void> Function(Uri uri)? openUrl;

  const BookmarksPanel({
    super.key,
    required this.session,
    this.onClose,
    this.controller,
    this.isDesktop,
    this.openUrl,
  });

  @override
  State<BookmarksPanel> createState() => _BookmarksPanelState();
}

class _BookmarksPanelState extends State<BookmarksPanel> {
  late BookmarkController _controller;
  bool _ownsController = false;
  BookmarkKind _kind = BookmarkKind.team;

  /// 순서 변경 중이면 그 탭의 목록 사본 — 드래그는 이 사본만 바꾸고 "완료"에서 서버에 보낸다.
  List<Bookmark>? _draft;
  bool _savingOrder = false;

  bool get _desktop =>
      widget.isDesktop ?? !(Platform.isAndroid || Platform.isIOS);
  bool get _reordering => _draft != null;

  @override
  void initState() {
    super.initState();
    _attach();
    widget.session.addListener(_onSessionChanged);
  }

  void _attach() {
    final injected = widget.controller;
    if (injected != null) {
      _controller = injected;
      _ownsController = false;
    } else {
      final session = widget.session;
      _controller = BookmarkController(
        api: RemoteBookmarkApi(session.api!),
        teamId: session.currentTeam!.id,
        changed: session.chatSocket.bookmarkChanged,
        reconnected: session.chatSocket.reconnected,
      );
      _ownsController = true;
    }
    _controller.addListener(_onChanged);
    if (!_controller.loaded) _controller.load();
  }

  void _detach() {
    _controller.removeListener(_onChanged);
    if (_ownsController) _controller.dispose();
  }

  /// 보고 있는 팀이 바뀌면 그 팀의 북마크로 새로 시작한다(내 컨트롤러일 때만).
  void _onSessionChanged() {
    if (!_ownsController) return;
    final teamId = widget.session.currentTeam?.id;
    if (teamId == null || teamId == _controller.teamId) return;
    _detach();
    setState(() {
      _draft = null;
      _attach();
    });
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.session.removeListener(_onSessionChanged);
    _detach();
    super.dispose();
  }

  // ---- 동작 ----

  Future<void> _open(Bookmark b) async {
    final uri = Uri.tryParse(b.url);
    if (uri == null) return;
    final opener = widget.openUrl;
    try {
      if (opener != null) {
        await opener(uri);
      } else {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (_) {
      if (mounted) showAppToast(context, '링크를 열지 못했습니다.');
    }
  }

  Future<void> _add() async {
    final saved = await showBookmarkEditor(
      context,
      session: widget.session,
      controller: _controller,
      initialKind: _kind,
    );
    if (saved && mounted) showAppToast(context, '북마크를 추가했습니다.');
  }

  Future<void> _edit(Bookmark b) async {
    final saved = await showBookmarkEditor(
      context,
      session: widget.session,
      controller: _controller,
      editing: b,
    );
    if (saved && mounted) showAppToast(context, '북마크를 수정했습니다.');
  }

  Future<void> _delete(Bookmark b) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('북마크 삭제'),
        content: Text('"${b.title}" 북마크를 삭제할까요?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            key: const ValueKey('confirm-delete-bookmark'),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _controller.remove(b);
      if (mounted) showAppToast(context, '북마크를 삭제했습니다.');
    } catch (e) {
      if (mounted) showAppToast(context, '북마크를 삭제하지 못했습니다: $e');
    }
  }

  /// 이 탭의 순서를 바꿀 수 있는지 — 팀 북마크는 팀 관리자만, 개인 북마크는 본인.
  bool get _canReorderHere {
    final list = _controller.of(_kind);
    if (list.isNotEmpty) return list.every((b) => b.canReorder);
    return _kind == BookmarkKind.personal ||
        widget.session.canManageCurrentTeam;
  }

  void _toggleReorder() {
    if (_reordering) {
      _finishReorder();
    } else {
      setState(() => _draft = List.of(_controller.of(_kind)));
    }
  }

  Future<void> _finishReorder() async {
    final draft = _draft;
    if (draft == null || _savingOrder) return;
    final before = _controller.of(_kind).map((b) => b.id).toList();
    final after = draft.map((b) => b.id).toList();
    if (before.join(',') == after.join(',')) {
      setState(() => _draft = null);
      return;
    }
    setState(() => _savingOrder = true);
    try {
      await _controller.reorder(_kind, after);
      if (mounted) showAppToast(context, '순서를 바꿨습니다.');
    } catch (e) {
      if (mounted) showAppToast(context, '순서를 바꾸지 못했습니다: $e');
    } finally {
      if (mounted) {
        setState(() {
          _savingOrder = false;
          _draft = null;
        });
      }
    }
  }

  void _selectKind(BookmarkKind kind) {
    if (_reordering || kind == _kind) return;
    setState(() => _kind = kind);
  }

  // ---- 화면 ----

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ColoredBox(
      color: theme.colorScheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SidePanelHeader(title: '북마크', onClose: widget.onClose),
          const Divider(height: 1),
          _actionBar(context),
          _tabs(context),
          const Divider(height: 1),
          Expanded(child: _content(context)),
        ],
      ),
    );
  }

  Widget _actionBar(BuildContext context) {
    final reorderButton = _desktop ? _reorderButton() : null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 12, 4),
      child: Row(
        children: [
          FilledButton.icon(
            key: const ValueKey('bookmark-add'),
            onPressed: _reordering ? null : _add,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('북마크 추가'),
          ),
          const Spacer(),
          ?reorderButton,
        ],
      ),
    );
  }

  Widget _reorderButton() {
    final canReorder = _canReorderHere;
    final enough = _controller.of(_kind).length >= 2;
    final enabled = _reordering || (canReorder && enough);
    final tooltip = _reordering
        ? ''
        : !canReorder
        ? '팀 북마크 순서는 관리자만 바꿀 수 있어요'
        : !enough
        ? '순서를 바꿀 북마크가 둘 이상 있어야 해요'
        : '';
    return Tooltip(
      message: tooltip,
      child: TextButton.icon(
        key: const ValueKey('bookmark-reorder'),
        onPressed: enabled && !_savingOrder ? _toggleReorder : null,
        icon: Icon(_reordering ? Icons.check : Icons.swap_vert, size: 18),
        label: Text(_reordering ? '완료' : '순서 변경'),
      ),
    );
  }

  Widget _tabs(BuildContext context) {
    return Row(
      children: [
        for (final kind in BookmarkKind.values)
          Expanded(child: _tab(context, kind)),
      ],
    );
  }

  Widget _tab(BuildContext context, BookmarkKind kind) {
    final theme = Theme.of(context);
    final selected = kind == _kind;
    final color = selected ? theme.colorScheme.primary : theme.hintColor;
    return InkWell(
      key: ValueKey('bookmark-tab-${kind.wire}'),
      onTap: _reordering ? null : () => _selectKind(kind),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: selected ? theme.colorScheme.primary : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Text(
          kind.label,
          style: theme.textTheme.titleSmall?.copyWith(
            color: color,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    );
  }

  Widget _content(BuildContext context) {
    final c = _controller;
    if (!c.loaded) {
      if (c.error != null) {
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(c.error!, textAlign: TextAlign.center),
              ),
              const SizedBox(height: 8),
              OutlinedButton(onPressed: c.load, child: const Text('다시 시도')),
            ],
          ),
        );
      }
      return const Center(child: CircularProgressIndicator());
    }
    final items = _draft ?? c.of(_kind);
    if (items.isEmpty) return _empty(context);
    if (_reordering) {
      return ReorderableListView.builder(
        key: const ValueKey('bookmark-reorder-list'),
        padding: const EdgeInsets.symmetric(vertical: 8),
        buildDefaultDragHandles: false,
        itemCount: items.length,
        onReorderItem: (from, to) => setState(() {
          final draft = _draft!;
          draft.insert(to, draft.removeAt(from));
        }),
        itemBuilder: (context, i) => _BookmarkCard(
          key: ValueKey('bookmark-${items[i].id}'),
          session: widget.session,
          bookmark: items[i],
          handle: ReorderableDragStartListener(
            index: i,
            child: const MouseRegion(
              cursor: SystemMouseCursors.grab,
              child: Padding(
                padding: EdgeInsets.all(8),
                child: Icon(Icons.drag_indicator),
              ),
            ),
          ),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: items.length,
      itemBuilder: (context, i) => _BookmarkCard(
        key: ValueKey('bookmark-${items[i].id}'),
        session: widget.session,
        bookmark: items[i],
        onTap: () => _open(items[i]),
        onEdit: items[i].canEdit ? () => _edit(items[i]) : null,
        onDelete: items[i].canEdit ? () => _delete(items[i]) : null,
      ),
    );
  }

  Widget _empty(BuildContext context) {
    final theme = Theme.of(context);
    final team = _kind == BookmarkKind.team;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.bookmark_border, size: 40, color: theme.hintColor),
            const SizedBox(height: 12),
            Text(
              team ? '등록된 팀 북마크가 없어요.' : '등록된 개인 북마크가 없어요.',
              key: const ValueKey('bookmark-empty'),
              style: theme.textTheme.bodyLarge,
            ),
            const SizedBox(height: 4),
            Text(
              team
                  ? '팀이 함께 쓰는 링크를 북마크로 추가해 보세요.'
                  : '자주 가는 링크를 나만 보는 북마크로 추가해 보세요.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.hintColor,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 북마크 카드 한 장 — 왼쪽 정사각 이미지, 제목, 도메인, 오른쪽 ⋯(수정·삭제). 순서 변경 중에는 [handle]이 앞에 붙고
/// 누르기·⋯는 없다.
class _BookmarkCard extends StatelessWidget {
  final Session session;
  final Bookmark bookmark;
  final VoidCallback? onTap;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final Widget? handle;

  const _BookmarkCard({
    super.key,
    required this.session,
    required this.bookmark,
    this.onTap,
    this.onEdit,
    this.onDelete,
    this.handle,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasMenu = onEdit != null || onDelete != null;
    return Material(
      color: theme.colorScheme.surface,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
          child: Row(
            children: [
              ?handle,
              BookmarkImage(session: session, imageUrl: bookmark.imageUrl),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      bookmark.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      bookmark.host,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.hintColor,
                      ),
                    ),
                  ],
                ),
              ),
              if (hasMenu)
                PopupMenuButton<String>(
                  key: ValueKey('bookmark-menu-${bookmark.id}'),
                  tooltip: '더보기',
                  icon: const Icon(Icons.more_vert),
                  onSelected: (v) =>
                      v == 'edit' ? onEdit?.call() : onDelete?.call(),
                  itemBuilder: (context) => [
                    if (onEdit != null)
                      const PopupMenuItem(value: 'edit', child: Text('수정')),
                    if (onDelete != null)
                      PopupMenuItem(
                        value: 'delete',
                        child: Text(
                          '삭제',
                          style: TextStyle(color: theme.colorScheme.error),
                        ),
                      ),
                  ],
                )
              else
                const SizedBox(width: 8),
            ],
          ),
        ),
      ),
    );
  }
}
