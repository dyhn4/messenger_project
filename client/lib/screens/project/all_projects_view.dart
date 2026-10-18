import 'package:flutter/material.dart';

import '../../models/project.dart';
import '../../widgets/muted_scrollbar.dart';
import '../../l10n/tr.dart';

/// 왼쪽 메뉴 [+] > 전체 프로젝트 — 내가 참여 중인 프로젝트를 한눈에(진행 중, 그 아래 종료된
/// 프로젝트). 줄을 누르면 그 프로젝트를 연다. 공개 프로젝트는 정회원 이상이면 자동으로
/// 멤버가 되어 이 목록에 이미 들어 있으므로 따로 찾아 참여하는 버튼은 없다.
class AllProjectsView extends StatefulWidget {
  /// 진행 중인 프로젝트(불러오는 중이면 null).
  final List<Project>? projects;
  final List<Project> archivedProjects;
  final ValueChanged<Project> onOpen;
  final ValueChanged<Project> onToggleFavorite;

  const AllProjectsView({
    super.key,
    required this.projects,
    required this.archivedProjects,
    required this.onOpen,
    required this.onToggleFavorite,
  });

  @override
  State<AllProjectsView> createState() => _AllProjectsViewState();
}

class _AllProjectsViewState extends State<AllProjectsView> {
  final _search = TextEditingController();
  final _scroll = ScrollController();

  /// 종료된 프로젝트 묶음을 펼쳤는지.
  bool _showArchived = false;

  @override
  void dispose() {
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  bool _matches(Project p) {
    final q = _search.text.trim().toLowerCase();
    if (q.isEmpty) return true;
    return p.name.toLowerCase().contains(q) ||
        p.identifier.toLowerCase().contains(q) ||
        (p.description ?? '').toLowerCase().contains(q);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final all = widget.projects;
    if (all == null) return const Center(child: CircularProgressIndicator());
    // 사이드바와 같은 순서 — 즐겨찾기 먼저.
    final active = [
      ...all.where((p) => p.favorite),
      ...all.where((p) => !p.favorite),
    ].where(_matches).toList();
    final archived = widget.archivedProjects.where(_matches).toList();
    final searching = _search.text.trim().isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
          child: Wrap(
            spacing: 16,
            runSpacing: 12,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    tr('전체 프로젝트'),
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    tr('내가 참여 중인 프로젝트 {all.length}개{p0}', {
                      'all.length': all.length,
                      'p0': widget.archivedProjects.isEmpty
                          ? ''
                          : tr(
                              ' · 종료된 프로젝트 {widget.archivedProjects.length}개',
                              {
                                'widget.archivedProjects.length':
                                    widget.archivedProjects.length,
                              },
                            ),
                    }),
                    style: TextStyle(fontSize: 13, color: hint),
                  ),
                ],
              ),
              SizedBox(
                width: 240,
                child: TextField(
                  controller: _search,
                  onChanged: (_) => setState(() {}),
                  style: const TextStyle(fontSize: 13),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: tr('프로젝트 이름·키 검색'),
                    prefixIcon: const Icon(Icons.search, size: 18),
                    prefixIconConstraints: const BoxConstraints(minWidth: 36),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    contentPadding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1, indent: 16, endIndent: 16),
        Expanded(
          child: MutedScrollbar(
            controller: _scroll,
            child: ListView(
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                const _HeaderRow(),
                if (active.isEmpty)
                  _Empty(
                    searching ? tr('검색 결과가 없습니다.') : tr('아직 참여 중인 프로젝트가 없습니다.'),
                  )
                else
                  for (final p in active)
                    _ProjectRow(
                      project: p,
                      onOpen: () => widget.onOpen(p),
                      onToggleFavorite: () => widget.onToggleFavorite(p),
                    ),
                if (widget.archivedProjects.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  InkWell(
                    borderRadius: BorderRadius.circular(6),
                    // 검색 중에는 종료된 프로젝트도 늘 펼쳐서 보여준다.
                    onTap: searching
                        ? null
                        : () => setState(() => _showArchived = !_showArchived),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 8,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            _showArchived || searching
                                ? Icons.expand_more
                                : Icons.chevron_right,
                            size: 18,
                            color: hint,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            tr('종료된 프로젝트 {widget.archivedProjects.length}', {
                              'widget.archivedProjects.length':
                                  widget.archivedProjects.length,
                            }),
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: hint,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (_showArchived || searching)
                    if (archived.isEmpty)
                      _Empty(tr('검색 결과가 없습니다.'))
                    else
                      for (final p in archived)
                        _ProjectRow(
                          project: p,
                          archived: true,
                          onOpen: () => widget.onOpen(p),
                        ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

const _keyW = 90.0;
const _progressW = 150.0;
const _visibilityW = 64.0;
const _starW = 44.0;

class _HeaderRow extends StatelessWidget {
  const _HeaderRow();

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(fontSize: 12, color: Theme.of(context).hintColor);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      child: Row(
        children: [
          Expanded(child: Text(tr('프로젝트'), style: style)),
          SizedBox(
            width: _keyW,
            child: Text(tr('키'), style: style),
          ),
          SizedBox(
            width: _progressW,
            child: Text(tr('진행률'), style: style),
          ),
          SizedBox(
            width: _visibilityW,
            child: Center(child: Text(tr('공개'), style: style)),
          ),
          const SizedBox(width: _starW),
        ],
      ),
    );
  }
}

/// 프로젝트 한 줄 — 색 점·이름·설명, 키, 진행률, 공개 여부, 즐겨찾기 별. 줄을 누르면 연다.
class _ProjectRow extends StatelessWidget {
  final Project project;
  final bool archived;
  final VoidCallback onOpen;
  final VoidCallback? onToggleFavorite;

  const _ProjectRow({
    required this.project,
    required this.onOpen,
    this.onToggleFavorite,
    this.archived = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final p = project;
    final percent = (p.progress * 100).round();
    final description = p.description?.trim() ?? '';
    final color = parseTypeColor(p.color);
    return Opacity(
      opacity: archived ? 0.6 : 1,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          key: ValueKey('all-project-${p.id}'),
          borderRadius: BorderRadius.circular(8),
          onTap: onOpen,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
            child: Row(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: color,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              p.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            if (description.isNotEmpty) ...[
                              const SizedBox(height: 2),
                              Text(
                                description,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 12, color: hint),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  width: _keyW,
                  child: Text(
                    p.identifier,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: hint,
                    ),
                  ),
                ),
                SizedBox(
                  width: _progressW,
                  child: Row(
                    children: [
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(999),
                          child: LinearProgressIndicator(
                            value: p.progress,
                            minHeight: 6,
                            color: color,
                            backgroundColor: theme.brightness == Brightness.dark
                                ? theme.colorScheme.surfaceContainerHighest
                                : const Color(0xFFF0F1F4),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 40,
                        child: Text(
                          '$percent%',
                          textAlign: TextAlign.right,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  width: _visibilityW,
                  child: Tooltip(
                    message: p.isPublic ? tr('공개 프로젝트') : tr('비공개 프로젝트'),
                    child: Icon(
                      p.isPublic ? Icons.public : Icons.lock_outline,
                      size: 16,
                      color: hint,
                    ),
                  ),
                ),
                SizedBox(
                  width: _starW,
                  child: onToggleFavorite == null
                      ? null
                      : IconButton(
                          tooltip: p.favorite ? tr('즐겨찾기 해제') : tr('즐겨찾기'),
                          visualDensity: VisualDensity.compact,
                          onPressed: onToggleFavorite,
                          icon: Icon(
                            p.favorite
                                ? Icons.star_rounded
                                : Icons.star_outline_rounded,
                            size: 20,
                            color: p.favorite ? const Color(0xFFF5A623) : hint,
                          ),
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

class _Empty extends StatelessWidget {
  final String text;
  const _Empty(this.text);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 32),
    child: Center(
      child: Text(
        text,
        style: TextStyle(fontSize: 13, color: Theme.of(context).hintColor),
      ),
    ),
  );
}
