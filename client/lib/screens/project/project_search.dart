import 'package:flutter/material.dart';

import '../../models/project.dart';
import '../../services/session.dart';
import 'task_views.dart' show taskStatusDisplayColor;

/// 프로젝트 창 맨 위 가운데 검색칸 — 내가 참여한 이 팀의 모든 프로젝트 업무를 제목이나 업무
/// 번호(TA-12)로 찾는다. 결과를 누르면 [onOpen]으로 그 업무를 넘긴다.
///
/// 팀 업무 전체를 한 번 받아와서(GET /tasks/team) 그 안에서 걸러낸다 — 글자를 칠 때마다 서버에
/// 묻지 않으려는 것이고, 검색칸에서 포커스가 빠지면 받아둔 목록을 버려서 다음 검색 때 새로 받는다.
class ProjectSearchField extends StatefulWidget {
  final Session session;
  final String teamId;
  final void Function(Task task) onOpen;

  const ProjectSearchField({
    super.key,
    required this.session,
    required this.teamId,
    required this.onOpen,
  });

  @override
  State<ProjectSearchField> createState() => _ProjectSearchFieldState();
}

class _ProjectSearchFieldState extends State<ProjectSearchField> {
  List<Task>? _cache;
  Future<List<Task>>? _loading;
  TextEditingController? _controller;

  Future<List<Task>> _tasks() {
    final cached = _cache;
    if (cached != null) return Future.value(cached);
    return _loading ??= widget.session.api!
        .fetchTeamTasks(widget.teamId)
        .then((list) {
          _cache = list;
          _loading = null;
          return list;
        })
        .catchError((Object _) {
          _loading = null;
          return <Task>[];
        });
  }

  Iterable<Task> _match(List<Task> tasks, String raw) {
    final q = raw.trim().toLowerCase();
    if (q.isEmpty) return const [];
    return tasks
        .where(
          (t) =>
              t.title.toLowerCase().contains(q) ||
              (t.key ?? '').toLowerCase().contains(q),
        )
        .take(12);
  }

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    return Autocomplete<Task>(
      displayStringForOption: (t) => t.title,
      optionsBuilder: (value) async {
        if (value.text.trim().isEmpty) return const <Task>[];
        return _match(await _tasks(), value.text);
      },
      onSelected: (task) {
        // 고른 업무를 열고 검색칸은 비워 둔다(제목이 그대로 남아 있으면 다음 검색에 방해된다).
        _controller?.clear();
        FocusManager.instance.primaryFocus?.unfocus();
        widget.onOpen(task);
      },
      fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
        _controller = controller;
        return Focus(
          onFocusChange: (has) {
            if (!has) _cache = null;
          },
          child: TextField(
            controller: controller,
            focusNode: focusNode,
            decoration: InputDecoration(
              hintText: '검색어를 입력하세요.',
              hintStyle: TextStyle(color: hint, fontSize: 13),
              prefixIcon: Icon(Icons.search, size: 18, color: hint),
              isDense: true,
              filled: true,
              fillColor: Theme.of(context).colorScheme.surfaceContainerLow,
              contentPadding: const EdgeInsets.symmetric(vertical: 10),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(999),
                borderSide: BorderSide(color: Theme.of(context).dividerColor),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(999),
                borderSide: BorderSide(color: Theme.of(context).dividerColor),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(999),
                borderSide: BorderSide(
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
            onSubmitted: (_) => onFieldSubmitted(),
          ),
        );
      },
      optionsViewBuilder: (context, onSelected, options) => Align(
        alignment: Alignment.topLeft,
        child: Material(
          elevation: 4,
          borderRadius: BorderRadius.circular(10),
          clipBehavior: Clip.antiAlias,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 360, maxWidth: 520),
            child: ListView(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              children: [
                for (final t in options)
                  ListTile(
                    dense: true,
                    leading: Container(
                      width: 10,
                      height: 10,
                      margin: const EdgeInsets.only(top: 6),
                      decoration: BoxDecoration(
                        color: taskStatusDisplayColor(t),
                        shape: BoxShape.circle,
                      ),
                    ),
                    title: Text(
                      t.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      [?t.projectName, ?t.key, t.statusLabel].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: hint, fontSize: 11),
                    ),
                    onTap: () => onSelected(t),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
