import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../models/room.dart';
import '../models/topic_folder.dart';
import '../services/app_platform.dart';
import '../services/session.dart';
import 'app_toast.dart';
import 'unread_badge.dart';

// 토픽 목록의 개인 폴더 — 데스크톱 사이드바(desktop_home_screen.dart)와 모바일 토픽 탭
// (room_list_screen.dart)이 같이 쓰는 묶기 규칙, 폴더 머리글, 이름 입력 창, 폴더 작업 도우미.
// 폴더 상태(접기·이름·순서·안의 토픽)는 Session이 먼저 바꾸고 서버가 거절하면 되돌리므로,
// 여기서는 부르고 실패를 토스트로 알리기만 한다.

// ───────────────────────────── 묶기 ─────────────────────────────

/// 즐겨찾기한 방을 먼저, 각 묶음 안에서는 최근 활동 순으로(방 목록 공통 규칙 — 채팅 중이거나
/// 알림이 온 방이 자기 묶음의 맨 위로 올라온다).
List<Room> favoriteFirst(Iterable<Room> rooms) {
  int byRecent(Room a, Room b) => b.lastActivityAt.compareTo(a.lastActivityAt);
  final favorites = rooms.where((r) => r.favorite).toList()..sort(byRecent);
  final others = rooms.where((r) => !r.favorite).toList()..sort(byRecent);
  return [...favorites, ...others];
}

/// 폴더 하나와 그 안에 보일 토픽들(보관된 토픽은 빠진다).
class TopicFolderGroup {
  final TopicFolder folder;
  final List<Room> rooms;
  const TopicFolderGroup(this.folder, this.rooms);

  /// 접었을 때 머리글에 보여줄 안 읽은 수 합계.
  int get unreadCount => rooms.fold(0, (sum, r) => sum + r.unreadCount);
}

/// 토픽 목록을 내 폴더 → 폴더 밖 토픽 → 보관된 토픽으로 나눈 결과.
class TopicGroups {
  final List<TopicFolderGroup> folders;

  /// 어느 폴더에도 없는(보관 안 된) 토픽.
  final List<Room> loose;

  /// 보관된 토픽 — 폴더에 들어 있어도 여기에만 보인다.
  final List<Room> archived;

  const TopicGroups({
    required this.folders,
    required this.loose,
    required this.archived,
  });

  int get archivedUnread => archived.fold(0, (sum, r) => sum + r.unreadCount);
}

/// [topics](지금 팀의 보이는 토픽 전부)를 [folders](position 순) 기준으로 나눈다. 폴더 안과
/// 폴더 밖 모두 즐겨찾기 먼저 → 최근 활동 순이다.
TopicGroups groupTopics(Iterable<Room> topics, List<TopicFolder> folders) {
  // 한 토픽은 내 폴더 한 곳에만 들어간다 — 혹시 겹치면 앞 폴더(Session.topicFolderOf와 같다).
  final folderOf = <String, String>{};
  for (final f in folders) {
    for (final id in f.roomIds) {
      folderOf.putIfAbsent(id, () => f.id);
    }
  }
  final active = topics.where((r) => !r.isArchived).toList();
  return TopicGroups(
    folders: [
      for (final f in folders)
        TopicFolderGroup(
          f,
          favoriteFirst(active.where((r) => folderOf[r.id] == f.id)),
        ),
    ],
    loose: favoriteFirst(active.where((r) => !folderOf.containsKey(r.id))),
    archived: favoriteFirst(topics.where((r) => r.isArchived)),
  );
}

// ───────────────────────────── 폴더 작업(토스트까지) ─────────────────────────────

/// "폴더로 이동" 목록에서 "새 폴더…"를 골랐을 때 돌려주는 값(폴더 id와 겹치지 않는다).
const kNewTopicFolderChoice = '__new_topic_folder__';

/// 폴더 이름 입력 창 — "폴더 생성"과 "폴더 이름 변경"이 같이 쓴다. 다듬은 이름, 취소하면 null.
Future<String?> askTopicFolderName(
  BuildContext context, {
  required String title,
  required String action,
  String initial = '',
}) => showDialog<String>(
  context: context,
  builder: (_) =>
      TopicFolderNameDialog(title: title, action: action, initial: initial),
);

/// 새 폴더를 만든다(이름을 먼저 묻는다). [moveIn]을 주면(토픽 메뉴의 "폴더로 이동 > 새 폴더…")
/// 만든 폴더에 그 토픽을 바로 넣는다. 만든 폴더를 돌려준다(취소·실패면 null).
///
/// [context]는 작업이 끝날 때까지 살아 있는 화면의 것을 넘긴다 — 폴더 조작은 목록을 먼저
/// 바꿔서, 누른 줄 자체는 응답이 오기 전에 사라질 수 있다(실패 토스트를 띄울 곳이 없어진다).
Future<TopicFolder?> createTopicFolderFlow(
  BuildContext context,
  Session session, {
  Room? moveIn,
}) async {
  final name = await askTopicFolderName(context, title: '폴더 생성', action: '생성');
  if (name == null || !context.mounted) return null;
  final TopicFolder folder;
  try {
    folder = await session.createTopicFolder(name);
  } catch (e) {
    if (context.mounted) showAppToast(context, '폴더를 만들지 못했습니다: $e');
    return null;
  }
  if (moveIn != null) {
    try {
      await session.moveTopicToFolder(moveIn, folder.id);
    } catch (e) {
      // 폴더는 이미 생겼다 — "못 만들었다"고 하면 다시 눌러 같은 폴더가 또 생기므로 옮기기만
      // 실패했다고 알린다.
      if (context.mounted) {
        showAppToast(context, '폴더는 만들었지만 토픽을 옮기지 못했습니다: $e');
      }
    }
  }
  return folder;
}

Future<void> renameTopicFolderFlow(
  BuildContext context,
  Session session,
  TopicFolder folder,
) async {
  final name = await askTopicFolderName(
    context,
    title: '폴더 이름 변경',
    action: '변경',
    initial: folder.name,
  );
  if (name == null || name == folder.name || !context.mounted) return;
  try {
    await session.renameTopicFolder(folder.id, name);
  } catch (e) {
    if (context.mounted) showAppToast(context, '폴더 이름을 바꾸지 못했습니다: $e');
  }
}

/// 폴더 삭제 — 확인을 받고 지운다. 안의 토픽은 폴더 밖 목록으로 돌아간다.
Future<void> deleteTopicFolderFlow(
  BuildContext context,
  Session session,
  TopicFolder folder,
) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text("'${folder.name}' 폴더 삭제"),
      content: const Text('폴더만 삭제되고 안의 토픽은 목록에 그대로 남습니다.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('삭제'),
        ),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;
  try {
    await session.deleteTopicFolder(folder.id);
  } catch (e) {
    if (context.mounted) showAppToast(context, '폴더를 삭제하지 못했습니다: $e');
  }
}

/// 폴더 접기/펴기 — 화면엔 바로 반영되고 서버엔 PATCH 한 번만 간다(Session). 다음에 열어도,
/// 다른 기기에서도 그대로다.
Future<void> toggleTopicFolderFlow(
  BuildContext context,
  Session session,
  TopicFolder folder,
) async {
  try {
    await session.setTopicFolderCollapsed(folder.id, !folder.collapsed);
  } catch (e) {
    if (context.mounted) showAppToast(context, '폴더 상태를 저장하지 못했습니다: $e');
  }
}

/// 토픽을 폴더 [folderId]로 옮긴다. null이면 폴더에서 뺀다(폴더 밖 목록으로).
Future<void> moveTopicToFolderFlow(
  BuildContext context,
  Session session,
  Room room,
  String? folderId,
) async {
  try {
    await session.moveTopicToFolder(room, folderId);
  } catch (e) {
    if (!context.mounted) return;
    showAppToast(
      context,
      folderId == null ? '폴더에서 빼지 못했습니다: $e' : '폴더로 옮기지 못했습니다: $e',
    );
  }
}

/// 폴더 [draggedId]를 [targetId]가 있던 자리로 옮긴다(폴더 머리글을 다른 머리글에 끌어다 놓기) —
/// 아래로 끌면 대상 뒤로, 위로 끌면 대상 앞으로 들어간다.
Future<void> reorderTopicFolderFlow(
  BuildContext context,
  Session session, {
  required String draggedId,
  required String targetId,
}) async {
  final ids = [for (final f in session.topicFolders) f.id];
  final from = ids.indexOf(draggedId);
  final to = ids.indexOf(targetId);
  if (from < 0 || to < 0 || from == to) return;
  ids
    ..removeAt(from)
    ..insert(to, draggedId);
  try {
    await session.reorderTopicFolders(ids);
  } catch (e) {
    if (context.mounted) showAppToast(context, '폴더 순서를 바꾸지 못했습니다: $e');
  }
}

/// 모바일 "폴더로 이동" — 내 폴더 목록(지금 든 폴더는 체크 표시·비활성)과 "새 폴더…"를 아래
/// 시트로 보여준다. 고른 폴더 id, "새 폴더…"면 [kNewTopicFolderChoice], 닫으면 null.
Future<String?> showTopicFolderPickerSheet(
  BuildContext context,
  Session session,
  Room room,
) {
  final current = session.topicFolderOf(room.id)?.id;
  final folders = List<TopicFolder>.of(session.topicFolders);
  return showModalBottomSheet<String>(
    context: context,
    // 폴더가 많으면 화면 높이까지 늘어나서 목록 안에서 스크롤된다.
    isScrollControlled: true,
    builder: (sheetContext) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.7,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Text(
                '폴더로 이동',
                style: Theme.of(sheetContext).textTheme.titleMedium,
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final f in folders)
                    ListTile(
                      leading: Icon(
                        f.id == current ? Icons.check : Icons.folder_outlined,
                      ),
                      title: Text(
                        f.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      enabled: f.id != current,
                      onTap: () => Navigator.of(sheetContext).pop(f.id),
                    ),
                ],
              ),
            ),
            if (folders.isNotEmpty) const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.create_new_folder_outlined),
              title: const Text('새 폴더…'),
              onTap: () =>
                  Navigator.of(sheetContext).pop(kNewTopicFolderChoice),
            ),
          ],
        ),
      ),
    ),
  );
}

// ───────────────────────────── 이름 입력 창 ─────────────────────────────

/// 폴더 이름 입력 — 비어 있으면 확인 버튼이 잠긴다. 확인하면 다듬은 이름을, 취소하면 null.
class TopicFolderNameDialog extends StatefulWidget {
  final String title;
  final String action;
  final String initial;
  const TopicFolderNameDialog({
    super.key,
    required this.title,
    required this.action,
    this.initial = '',
  });

  @override
  State<TopicFolderNameDialog> createState() => _TopicFolderNameDialogState();
}

class _TopicFolderNameDialogState extends State<TopicFolderNameDialog> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String get _name => _controller.text.trim();

  void _submit() {
    if (_name.isEmpty) return;
    Navigator.of(context).pop(_name);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 320,
        child: TextField(
          controller: _controller,
          autofocus: true,
          maxLength: topicFolderNameMaxLength,
          decoration: const InputDecoration(hintText: '폴더 이름'),
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _submit(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: _name.isEmpty ? null : _submit,
          child: Text(widget.action),
        ),
      ],
    );
  }
}

// ───────────────────────────── 폴더 머리글 ─────────────────────────────

/// 폴더 머리글 — 꺽쇠·폴더 아이콘·이름·토픽 수, 접혀 있으면 안 읽은 수 합계. 누르면 접었다
/// 펴고, 마우스를 올리면(모바일·터치 기기는 늘) ⋯(이름 변경 / 폴더 삭제)가 보인다. 길게 눌러도
/// 같은 메뉴가 열린다. [archived]면 "보관된 토픽" 묶음 — 보관 아이콘에 메뉴가 없다.
class TopicFolderHeader extends StatefulWidget {
  final String name;
  final int count;
  final int unreadCount;
  final bool collapsed;
  final bool archived;

  /// 끌어 온 토픽/폴더를 여기에 놓을 수 있는 상태(마우스가 위에 있음) — 옅은 강조색을 깐다.
  final bool dropActive;

  /// 모바일 토픽 탭 — 줄이 높고 글자가 크며 ⋯가 늘 보인다.
  final bool mobile;
  final VoidCallback onToggle;
  final VoidCallback? onRename;
  final VoidCallback? onDelete;

  const TopicFolderHeader({
    super.key,
    required this.name,
    required this.count,
    this.unreadCount = 0,
    required this.collapsed,
    this.archived = false,
    this.dropActive = false,
    this.mobile = false,
    required this.onToggle,
    this.onRename,
    this.onDelete,
  });

  @override
  State<TopicFolderHeader> createState() => _TopicFolderHeaderState();
}

class _TopicFolderHeaderState extends State<TopicFolderHeader> {
  bool _hovering = false;
  final _menu = MenuController();

  bool get _hasMenu => widget.onRename != null || widget.onDelete != null;

  void _toggleMenu() =>
      setState(() => _menu.isOpen ? _menu.close() : _menu.open());

  Widget _menuItem(IconData icon, String label, VoidCallback onPressed) =>
      MenuItemButton(
        leadingIcon: Icon(icon, size: 18),
        onPressed: onPressed,
        child: Padding(
          padding: const EdgeInsets.only(right: 20),
          child: Text(label),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final mobile = widget.mobile;
    final collapsed = widget.collapsed;
    // 끌어 온 것을 놓으려는 중(강조 표시)에는 ⋯를 숨겨 놓을 자리를 깔끔하게 보여 준다.
    final menuVisible =
        _hasMenu &&
        !widget.dropActive &&
        (mobile || _hovering || _menu.isOpen || isTouchPlatform);
    final icon = widget.archived
        ? Icons.inventory_2_outlined
        : (!collapsed || widget.dropActive
              ? Icons.folder_open_outlined
              : Icons.folder_outlined);
    // 데스크톱 줄은 방 줄(ListTile)과 같은 자리에 맞춘다 — 오른쪽 끝 24px 여백 안쪽에 ⋯(방 줄의
    // 호버 X와 같은 자리), 그 왼쪽에 안 읽은 수(방 줄의 안 읽은 수와 같은 세로줄). 메뉴가 없는
    // "보관된 토픽"도 그 자리를 비워 둬서 안 읽은 수가 같은 줄에 선다. 모바일은 ⋯가 늘 보여서
    // 메뉴가 있을 때만 그 왼쪽으로 비킨다.
    final endInset = mobile ? 8.0 : 24.0;
    final menuSlot = mobile ? 40.0 : 28.0;
    final rightPadding = mobile && !_hasMenu ? 24.0 : endInset + menuSlot + 4;
    // 호버 배경도 방 줄과 같은 색. 끌어다 놓는 중이면 강조색이 보이게 비운다.
    final background =
        !mobile && !widget.dropActive && (_hovering || _menu.isOpen)
        ? theme.colorScheme.onSurface.withValues(alpha: 0.08)
        : Colors.transparent;
    final nameStyle = mobile
        ? theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)
        : theme.textTheme.bodyMedium?.copyWith(
            fontSize: 13,
            fontWeight: FontWeight.w600,
          );

    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: TopicDropHighlight(
        active: widget.dropActive,
        child: SizedBox(
          height: mobile ? 48 : 36,
          // ⋯ 버튼(과 그 메뉴)은 InkWell 바깥에 겹쳐 둔다 — 안에 두면 메뉴를 닫을 때 포커스가 그
          // 버튼으로 돌아오면서 머리글 전체가 "포커스됨" 회색으로 남는다(프로젝트 폴더와 같은 이유).
          child: Stack(
            alignment: Alignment.centerRight,
            children: [
              Positioned.fill(
                child: Material(
                  color: background,
                  child: InkWell(
                    onTap: widget.onToggle,
                    // 길게 눌러 메뉴 열기는 터치에서만 — 마우스로 누른 채 잠깐 멈췄다 끌면 메뉴가
                    // 끌기를 가로채지 않게(데스크톱은 호버 ⋯가 있다).
                    onLongPress: _hasMenu && (mobile || isTouchPlatform)
                        ? _toggleMenu
                        : null,
                    hoverColor: Colors.transparent,
                    child: Padding(
                      padding: EdgeInsets.only(
                        left: mobile ? 16 : 10,
                        right: rightPadding,
                      ),
                      child: Row(
                        children: [
                          // 접으면 오른쪽(▸), 펴면 아래(▾)로 부드럽게 돈다.
                          AnimatedRotation(
                            turns: collapsed ? -0.25 : 0,
                            duration: const Duration(milliseconds: 150),
                            child: Icon(
                              Icons.expand_more,
                              size: mobile ? 20 : 16,
                              color: hint,
                            ),
                          ),
                          SizedBox(width: mobile ? 4 : 2),
                          Icon(
                            icon,
                            size: mobile ? 22 : 18,
                            color: widget.dropActive
                                ? theme.colorScheme.primary
                                : hint,
                          ),
                          SizedBox(width: mobile ? 12 : 8),
                          Expanded(
                            child: Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    widget.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: nameStyle,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  '${widget.count}',
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: hint,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (collapsed && widget.unreadCount > 0) ...[
                            const SizedBox(width: 6),
                            UnreadBadge(count: widget.unreadCount),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              if (_hasMenu)
                Positioned(
                  right: endInset,
                  child: Opacity(
                    opacity: menuVisible ? 1 : 0,
                    child: MenuAnchor(
                      controller: _menu,
                      onClose: () {
                        if (mounted) setState(() {});
                      },
                      menuChildren: [
                        if (widget.onRename != null)
                          _menuItem(
                            Icons.edit_outlined,
                            '이름 변경',
                            widget.onRename!,
                          ),
                        if (widget.onDelete != null)
                          _menuItem(
                            Icons.delete_outline,
                            '폴더 삭제',
                            widget.onDelete!,
                          ),
                      ],
                      builder: (context, controller, _) => SizedBox(
                        width: menuSlot,
                        height: menuSlot,
                        child: IconButton(
                          padding: EdgeInsets.zero,
                          iconSize: mobile ? 20 : 16,
                          tooltip: '폴더 메뉴',
                          icon: Icon(Icons.more_horiz, color: hint),
                          onPressed: _toggleMenu,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 폴더 안의 줄들 — 접고 펼 때 높이가 부드럽게 줄고 는다. 다 접히면 줄을 트리에서 뺀다(안 보이는
/// 줄이 포커스·검색에 걸리지 않게).
class TopicFolderBody extends StatefulWidget {
  final bool expanded;
  final List<Widget> children;
  const TopicFolderBody({
    super.key,
    required this.expanded,
    required this.children,
  });

  @override
  State<TopicFolderBody> createState() => _TopicFolderBodyState();
}

class _TopicFolderBodyState extends State<TopicFolderBody>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
    value: widget.expanded ? 1 : 0,
  );
  late final _height = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeInOut,
  );

  @override
  void didUpdateWidget(TopicFolderBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.expanded != oldWidget.expanded) {
      widget.expanded ? _controller.forward() : _controller.reverse();
    }
  }

  @override
  void dispose() {
    _height.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        if (_controller.isDismissed) return const SizedBox.shrink();
        return ClipRect(
          child: Align(
            alignment: Alignment.topCenter,
            heightFactor: _height.value,
            child: child,
          ),
        );
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: widget.children,
      ),
    );
  }
}

/// 끌어 온 토픽/폴더를 놓을 수 있는 자리 위에 있을 때 옅은 강조색과 테두리를 깐다.
class TopicDropHighlight extends StatelessWidget {
  final bool active;
  final Widget child;
  const TopicDropHighlight({
    super.key,
    required this.active,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: active ? primary.withValues(alpha: 0.12) : null,
        border: active
            ? Border.all(color: primary.withValues(alpha: 0.6))
            : null,
        borderRadius: BorderRadius.circular(8),
      ),
      child: child,
    );
  }
}

/// 끄는 딱지를 마우스 끝의 오른쪽 아래에 띄운다 — 놓을 자리(폴더 이름)를 가리지 않게.
Offset topicDragAnchor(
  Draggable<Object> draggable,
  BuildContext context,
  Offset position,
) => const Offset(-14, -18);

/// 끄는 동안 마우스 끝에 따라다니는 작은 딱지(아이콘 + 이름).
class TopicDragFeedback extends StatelessWidget {
  final IconData icon;
  final String label;
  const TopicDragFeedback({super.key, required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(8),
      color: theme.colorScheme.surface,
      child: Container(
        width: 200,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Icon(icon, size: 16, color: theme.hintColor),
            const SizedBox(width: 8),
            Expanded(
              child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
      ),
    );
  }
}

// ───────────────────────────── 대화 헤더 상태 칩 ─────────────────────────────

/// 대화 헤더의 토픽 이름 옆 작은 상태 표시 — '보드 뷰'·'읽기 전용'·'보관됨'이 같은 모양
/// (옅은 바탕 + 가는 테두리)으로 붙는다.
class TopicStatusChip extends StatelessWidget {
  final String label;
  final IconData icon;
  const TopicStatusChip({super.key, required this.label, required this.icon});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = scheme.onSurfaceVariant;
    return Container(
      height: 20,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 3),
          Text(
            label,
            maxLines: 1,
            style: TextStyle(
              fontSize: 11,
              height: 1.2,
              fontWeight: FontWeight.w500,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

/// [room]에 붙일 상태 칩들(토픽이 아니거나 해당 없으면 빈 목록).
List<Widget> topicStatusChips(Room room) => [
  if (room.isBoard)
    const TopicStatusChip(
      key: ValueKey('topic-chip-board'),
      label: '보드 뷰',
      icon: Icons.dashboard_outlined,
    ),
  if (room.type == RoomType.topic && room.readOnly)
    const TopicStatusChip(
      key: ValueKey('topic-chip-read-only'),
      label: '읽기 전용',
      icon: Icons.edit_off_outlined,
    ),
  if (room.type == RoomType.topic && room.isArchived)
    const TopicStatusChip(
      key: ValueKey('topic-chip-archived'),
      label: '보관됨',
      icon: Icons.inventory_2_outlined,
    ),
];

// ───────────────────────────── 마우스 끌기 ─────────────────────────────

/// 안드로이드·iOS(터치) — 호버가 없어 "마우스를 올리면 보이는 ⋯"가 영영 안 보이므로 늘 보여 준다.
/// 테스트가 TargetPlatformVariant(debugDefaultTargetPlatformOverride)로 바꿔 볼 수 있게 그 값이
/// 있으면 먼저 따른다.
bool get isTouchPlatform {
  final override = debugDefaultTargetPlatformOverride;
  if (override != null) {
    return override == TargetPlatform.android || override == TargetPlatform.iOS;
  }
  return AppPlatform.isAndroid || AppPlatform.isIOS;
}

/// 마우스로 이만큼(논리 픽셀) 넘게 움직여야 끌기로 본다 — 그보다 적게 흔들린 클릭은 그대로 연다.
const kTopicDragSlop = 6.0;

/// 사이드바 토픽 줄·폴더 머리글 끌기. 기본 Draggable은 마우스에서 1px만 움직여도 끌기가 시작돼
/// 살짝 흔들린 클릭(토픽 열기·폴더 접기)이 씹힌다 — 작은 문턱을 둔다. 터치는 목록 스크롤과 겹치지
/// 않게 끌기를 받지 않는다(터치에서는 메뉴의 "폴더로 이동"을 쓴다).
class TopicMouseDraggable<T extends Object> extends Draggable<T> {
  const TopicMouseDraggable({
    super.key,
    required super.child,
    required super.feedback,
    super.data,
    super.dragAnchorStrategy,
    super.onDragStarted,
    super.onDragEnd,
  });

  @override
  MultiDragGestureRecognizer createRecognizer(
    GestureMultiDragStartCallback onStart,
  ) => _TopicSlopDragRecognizer()..onStart = onStart;
}

class _TopicSlopDragRecognizer extends MultiDragGestureRecognizer {
  _TopicSlopDragRecognizer()
    : super(debugOwner: null, supportedDevices: {PointerDeviceKind.mouse});

  @override
  MultiDragPointerState createNewPointerState(PointerDownEvent event) =>
      _TopicSlopPointerState(event.position, event.kind, gestureSettings);

  @override
  String get debugDescription => 'topic drag';
}

class _TopicSlopPointerState extends MultiDragPointerState {
  _TopicSlopPointerState(
    super.initialPosition,
    super.kind,
    super.gestureSettings,
  );

  @override
  void checkForResolutionAfterMove() {
    if (pendingDelta!.distance > kTopicDragSlop) {
      resolve(GestureDisposition.accepted);
    }
  }

  @override
  void accepted(GestureMultiDragStartCallback starter) {
    starter(initialPosition);
  }
}
