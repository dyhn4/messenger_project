import 'package:flutter/material.dart';

import '../models/board_category.dart';
import '../models/room.dart';
import '../services/session.dart';
import '../widgets/app_toast.dart';
import '../l10n/tr.dart';

/// 보드 뷰 토픽의 말머리 관리(토픽을 관리할 수 있는 사람만) — 이름·색을 고치고, 더하고, 지우고, 끌어서 순서를 바꾼다.
/// 저장하면 목록을 통째로 보낸다(서버 PATCH /rooms/:id의 boardCategories — 있던 말머리는 id를 그대로 보내서
/// 그 말머리를 든 게시글이 따라가고, 지운 말머리의 게시글은 말머리 없이 보인다). 저장했으면 true.
Future<bool> showBoardCategoriesDialog(
  BuildContext context,
  Session session,
  Room room,
) async {
  final saved = await showDialog<bool>(
    context: context,
    builder: (_) => BoardCategoriesDialog(session: session, room: room),
  );
  return saved == true;
}

class BoardCategoriesDialog extends StatefulWidget {
  final Session session;
  final Room room;

  const BoardCategoriesDialog({
    super.key,
    required this.session,
    required this.room,
  });

  @override
  State<BoardCategoriesDialog> createState() => _BoardCategoriesDialogState();
}

/// 편집 중인 말머리 한 줄 — 새로 더한 줄은 id가 없다. [key]는 끌어 옮기기(ReorderableListView)용.
class _Row {
  final String? id;
  final TextEditingController name;
  String color;
  final Key key = UniqueKey();

  _Row({this.id, required String name, required this.color})
    : name = TextEditingController(text: name);
}

class _BoardCategoriesDialogState extends State<BoardCategoriesDialog> {
  late final List<_Row> _rows = [
    for (final c in widget.room.boardCategories)
      _Row(id: c.id, name: c.name, color: c.color),
  ];
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    for (final r in _rows) {
      r.name.dispose();
    }
    super.dispose();
  }

  /// 새 말머리 — 아직 안 쓴 색부터 고른다.
  void _add() {
    if (_rows.length >= boardCategoriesMax) return;
    final used = {for (final r in _rows) r.color};
    final color = boardCategoryColors.firstWhere(
      (c) => !used.contains(c),
      orElse: () =>
          boardCategoryColors[_rows.length % boardCategoryColors.length],
    );
    setState(() {
      _rows.add(_Row(name: '', color: color));
      _error = null;
    });
  }

  void _remove(_Row row) {
    setState(() {
      _rows.remove(row);
      _error = null;
    });
    // 지운 줄의 입력칸이 화면에서 빠진 다음 프레임에 정리한다.
    WidgetsBinding.instance.addPostFrameCallback((_) => row.name.dispose());
  }

  /// 서버와 같은 규칙으로 먼저 걸러 칸 아래에 알린다(서버 boardRules.js가 다시 검사한다).
  String? _validate() {
    final seen = <String>{};
    for (final r in _rows) {
      final name = r.name.text.trim();
      if (name.isEmpty) return tr('말머리 이름을 입력하세요.');
      if (name.characters.length > boardCategoryNameMax) {
        return tr('말머리 이름은 {boardCategoryNameMax}자까지 쓸 수 있습니다.', {
          'boardCategoryNameMax': boardCategoryNameMax,
        });
      }
      if (!seen.add(name)) {
        return tr('같은 이름의 말머리가 있습니다: \'{name}\'', {'name': name});
      }
    }
    return null;
  }

  Future<void> _save() async {
    if (_saving) return;
    final error = _validate();
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.session.updateBoardCategories(widget.room.id, [
        for (final r in _rows)
          BoardCategory(id: r.id, name: r.name.text.trim(), color: r.color),
      ]);
      if (!mounted) return;
      showAppToast(context, tr('말머리를 저장했습니다.'));
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _colorButton(_Row row) {
    return PopupMenuButton<String>(
      tooltip: tr('색 고르기'),
      enabled: !_saving,
      onSelected: (c) => setState(() => row.color = c),
      itemBuilder: (_) => [
        for (final c in boardCategoryColors)
          PopupMenuItem<String>(
            value: c,
            height: 40,
            child: Row(
              children: [
                CircleAvatar(
                  radius: 9,
                  backgroundColor: parseBoardCategoryColor(c),
                ),
                if (c == row.color) ...[
                  const SizedBox(width: 10),
                  const Icon(Icons.check, size: 18),
                ],
              ],
            ),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: CircleAvatar(
          radius: 10,
          backgroundColor: parseBoardCategoryColor(row.color),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    return AlertDialog(
      title: Text(tr('말머리 관리')),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              tr(
                '게시글을 쓸 때 고르는 분류입니다. 보드 위에서 말머리별로 모아 볼 수 있습니다. 지운 말머리의 게시글은 말머리 없이 보입니다.',
              ),
              style: TextStyle(fontSize: 13, color: hint),
            ),
            const SizedBox(height: 12),
            if (_rows.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 20),
                child: Text(
                  tr('아직 말머리가 없습니다.'),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: hint),
                ),
              )
            else
              Flexible(
                child: ReorderableListView.builder(
                  shrinkWrap: true,
                  buildDefaultDragHandles: false,
                  itemCount: _rows.length,
                  onReorderItem: (from, to) =>
                      setState(() => _rows.insert(to, _rows.removeAt(from))),
                  itemBuilder: (context, i) {
                    final row = _rows[i];
                    return Padding(
                      key: row.key,
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        children: [
                          ReorderableDragStartListener(
                            index: i,
                            child: Padding(
                              padding: const EdgeInsets.all(4),
                              child: Icon(Icons.drag_indicator, color: hint),
                            ),
                          ),
                          _colorButton(row),
                          Expanded(
                            child: TextField(
                              key: ValueKey('board-category-name-$i'),
                              controller: row.name,
                              enabled: !_saving,
                              autofocus: row.id == null,
                              maxLength: boardCategoryNameMax,
                              decoration: InputDecoration(
                                hintText: tr('말머리 이름'),
                                isDense: true,
                                counterText: '',
                                border: OutlineInputBorder(),
                              ),
                              onChanged: (_) {
                                if (_error != null) {
                                  setState(() => _error = null);
                                }
                              },
                            ),
                          ),
                          IconButton(
                            tooltip: tr('삭제'),
                            onPressed: _saving ? null : () => _remove(row),
                            icon: const Icon(Icons.close, size: 20),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const ValueKey('board-category-add'),
                onPressed: _saving || _rows.length >= boardCategoriesMax
                    ? null
                    : _add,
                icon: const Icon(Icons.add),
                label: Text(
                  _rows.length >= boardCategoriesMax
                      ? tr('말머리는 {boardCategoriesMax}개까지', {
                          'boardCategoriesMax': boardCategoriesMax,
                        })
                      : tr('말머리 추가'),
                ),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  _error!,
                  style: TextStyle(
                    color: theme.colorScheme.error,
                    fontSize: 13,
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: Text(tr('취소')),
        ),
        FilledButton(
          key: const ValueKey('board-category-save'),
          onPressed: _saving ? null : _save,
          child: Text(tr('저장')),
        ),
      ],
    );
  }
}
