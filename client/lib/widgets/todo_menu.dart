import 'package:flutter/material.dart';

import '../models/todo.dart';
import 'compact_menu.dart';
import 'todo_widgets.dart';
import '../l10n/tr.dart';

// 할 일 더보기 메뉴(상세 머리의 ••• · 목록/일정 카드의 ⋯)가 같이 쓰는 조각 — 항목(todoMenuItems)·삭제 확인
// (confirmTodoDelete)·카드의 ⋯ 단추(TodoCardMenuButton). 두 메뉴는 항목·권한·모양이 같고, 고른 뒤의 동작은 상세
// (_TodoDetailState)와 목록 패널(TodosPanel)이 각자 맡는다 — 수정은 [showTodoEditor], 내려받기는
// downloadTodoAttachments, 삭제 확인은 [confirmTodoDelete]를 함께 쓴다.

/// 할 일 더보기 메뉴의 항목. 항목 키는 `todo-menu-<name>`(`todo-menu-favorite` …).
enum TodoMenuAction { favorite, edit, download, upload, delete }

/// 더보기 메뉴의 폭 — 상세 •••와 카드 ⋯가 같다.
const todoMenuConstraints = BoxConstraints(minWidth: 160, maxWidth: 240);

/// 더보기 메뉴 항목(잔디) — `즐겨찾기`/`즐겨찾기 해제`(누구나) · `할 일 수정`(만든 사람·담당자 — [Todo.canEdit]) ·
/// `파일 다운로드`(첨부가 있을 때, [downloading]이면 꺼짐) · `파일 업로드`(만든 사람·담당자 — 결과물을 업로드 경로로, 없으면
/// 만든 사람에게 메시지로 — todo_upload.dart) · `할 일 삭제`(만든 사람 — [Todo.canManage], 빨강). 작은 아이콘(흐린 색) +
/// 13px 글자의 간결한 메뉴([CompactMenu]) 모양.
List<PopupMenuEntry<TodoMenuAction>> todoMenuItems(
  BuildContext context,
  Todo todo, {
  bool downloading = false,
}) {
  final theme = Theme.of(context);
  PopupMenuItem<TodoMenuAction> item(
    TodoMenuAction value,
    String label,
    IconData icon, {
    Color? color,
    Color? iconColor,
    bool enabled = true,
  }) => PopupMenuItem<TodoMenuAction>(
    key: ValueKey('todo-menu-${value.name}'),
    value: value,
    enabled: enabled,
    height: CompactMenu.itemHeight,
    padding: CompactMenu.itemPadding,
    child: Row(
      children: [
        Icon(icon, size: 16, color: iconColor ?? color ?? theme.hintColor),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: color == null
                ? CompactMenu.textStyle
                : CompactMenu.textStyle.copyWith(color: color),
          ),
        ),
      ],
    ),
  );
  return [
    item(
      TodoMenuAction.favorite,
      todo.favorite ? tr('즐겨찾기 해제') : tr('즐겨찾기'),
      todo.favorite ? Icons.star : Icons.star_border,
      iconColor: todo.favorite ? Colors.amber : null,
    ),
    if (todo.canEdit)
      item(TodoMenuAction.edit, tr('할 일 수정'), Icons.edit_outlined),
    if (todo.attachments.isNotEmpty)
      item(
        TodoMenuAction.download,
        tr('파일 다운로드'),
        Icons.file_download_outlined,
        enabled: !downloading,
      ),
    if (todo.canEdit)
      item(TodoMenuAction.upload, tr('파일 업로드'), Icons.file_upload_outlined),
    if (todo.canManage)
      item(
        TodoMenuAction.delete,
        tr('할 일 삭제'),
        Icons.delete_outline,
        color: theme.colorScheme.error,
      ),
  ];
}

/// 할 일 삭제 확인(`"제목" 할 일을 삭제할까요?` [취소]/[삭제]) — [삭제]를 눌렀으면 true. 창은 루트 Navigator(창 전체)에
/// 뜬다. [onRoute]는 떠 있는 동안의 창 라우트를 받는다(닫히면 부르지 않는다) — 띄운 화면이 먼저 닫히면(지워졌다는 알림·
/// 팀 전환) 쓰는 쪽이 그 라우트를 [closeTodoRoute]로 치운다(결과 null — 지우지 않는다).
Future<bool> confirmTodoDelete(
  BuildContext context,
  Todo todo, {
  ValueChanged<Route<Object?>?>? onRoute,
}) async {
  var open = true;
  final ok = await showDialog<bool>(
    context: context,
    builder: (dialogContext) {
      // 닫히는 동안 다시 그려져도 닫힌 창을 다시 넘기지 않게 [open]일 때만.
      if (open) onRoute?.call(ModalRoute.of(dialogContext));
      return AlertDialog(
        title: Text(tr('할 일 삭제')),
        content: Text(
          tr('"{todo.title}" 할 일을 삭제할까요?\n삭제하면 되돌릴 수 없습니다.', {
            'todo.title': todo.title,
          }),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(tr('취소')),
          ),
          FilledButton(
            key: const ValueKey('todo-confirm-delete'),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(tr('삭제')),
          ),
        ],
      );
    },
  );
  open = false;
  return ok == true;
}

/// 목록·일정 카드에서 ⋯ 메뉴를 고른 뒤의 손잡이 — 할 일 패널이 만든다(수정 화면을 띄울 자리·컨트롤러를 안다).
class TodoCardActions {
  /// 고른 항목을 처리한다.
  final void Function(Todo todo, TodoMenuAction action) onSelected;

  /// 그 할 일의 첨부를 받는 중인지 — 메뉴를 열 때 물어 `파일 다운로드`를 끈다.
  final bool Function(Todo todo)? isDownloading;

  const TodoCardActions({required this.onSelected, this.isDownloading});
}

/// 카드 오른쪽 위의 ⋯(더보기) — 누르면 상세 •••와 같은 메뉴([todoMenuItems])를 [showTodoMenu]로 띄운다: 창 전체(루트
/// Navigator)에 떠서 바깥 어디를(PC 할 일 패널이면 채팅 쪽까지) 눌러도 닫히고 그 누름은 아래로 가지 않으며, 자리는 단추
/// 오른쪽 끝에 맞춰 패널 안. 누름은 카드(상세 열기)로 가지 않는다. 키는 `todo-card-menu-<id>`.
class TodoCardMenuButton extends StatefulWidget {
  final Todo todo;
  final TodoCardActions actions;

  const TodoCardMenuButton({
    super.key,
    required this.todo,
    required this.actions,
  });

  /// 단추 한 변 — 카드 첫 줄(진행률·생성일)에 맞춘 작은 크기.
  static const size = 28.0;

  @override
  State<TodoCardMenuButton> createState() => _TodoCardMenuButtonState();
}

class _TodoCardMenuButtonState extends State<TodoCardMenuButton> {
  bool _open = false;

  Future<void> _show() async {
    if (_open) return;
    final todo = widget.todo;
    final actions = widget.actions;
    setState(() => _open = true);
    final picked = await showTodoMenu<TodoMenuAction>(
      context,
      items: todoMenuItems(
        context,
        todo,
        downloading: actions.isDownloading?.call(todo) ?? false,
      ),
      constraints: todoMenuConstraints,
    );
    if (mounted) setState(() => _open = false);
    if (picked != null) actions.onSelected(todo, picked);
  }

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    return Semantics(
      expanded: _open,
      child: SizedBox.square(
        dimension: TodoCardMenuButton.size,
        child: IconButton(
          key: ValueKey('todo-card-menu-${widget.todo.id}'),
          tooltip: tr('더보기'),
          padding: EdgeInsets.zero,
          iconSize: 18,
          style: IconButton.styleFrom(
            minimumSize: const Size.square(TodoCardMenuButton.size),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          icon: Icon(Icons.more_horiz, color: hint),
          onPressed: _show,
        ),
      ),
    );
  }
}
