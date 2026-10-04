import 'dart:async';

import 'package:flutter/material.dart';

import '../models/app_user.dart';
import '../models/file_category.dart';
import '../models/room.dart';
import '../services/session.dart';
import 'compact_menu_anchor.dart';
import 'date_range_calendar_panel.dart';
import 'filter_dropdown.dart';

/// 검색·파일·링크 패널 상단이 공유하는 조각들 — 기간 필터(직접 설정은 프로젝트 "새 업무"의 기간
/// 달력), 멤버 필터, 정렬 드롭다운(설정 메뉴와 같은 모양), 파일 형식 메뉴, 결과 줄.

// ── 기간 ───────────────────────────────────────────────────────────

enum PeriodPreset { week, month, threeMonths, year, all, custom }

extension PeriodPresetLabel on PeriodPreset {
  String get label => switch (this) {
    PeriodPreset.week => '1주일',
    PeriodPreset.month => '1개월',
    PeriodPreset.threeMonths => '3개월',
    PeriodPreset.year => '1년 (기본)',
    PeriodPreset.all => '설정 안 함',
    PeriodPreset.custom => '직접 설정',
  };
}

String formatPanelDate(DateTime d) =>
    '${d.year}/${d.month.toString().padLeft(2, '0')}/${d.day.toString().padLeft(2, '0')}';

/// 패널에서 고른 기간 — 프리셋 하나, 또는 "직접 설정"한 시작일~종료일.
class PanelPeriod {
  final PeriodPreset preset;
  final DateTimeRange? custom;
  const PanelPeriod([this.preset = PeriodPreset.year, this.custom]);

  const PanelPeriod.custom(DateTimeRange range)
    : preset = PeriodPreset.custom,
      custom = range;

  bool get isCustom => preset == PeriodPreset.custom && custom != null;

  /// 서버에 보내는 시작 시각(없으면 시작 제한 없음). [now]는 테스트용.
  DateTime? since([DateTime? now]) {
    final base = now ?? DateTime.now();
    return switch (preset) {
      PeriodPreset.week => base.subtract(const Duration(days: 7)),
      PeriodPreset.month => base.subtract(const Duration(days: 30)),
      PeriodPreset.threeMonths => base.subtract(const Duration(days: 90)),
      PeriodPreset.year => base.subtract(const Duration(days: 365)),
      PeriodPreset.all => null,
      PeriodPreset.custom => custom?.start,
    };
  }

  /// 직접 설정한 종료일은 그날 끝까지 포함한다.
  DateTime? get until {
    final end = isCustom ? custom!.end : null;
    if (end == null) return null;
    return DateTime(end.year, end.month, end.day, 23, 59, 59, 999);
  }

  /// "직접 설정"했을 때만 결과 줄 오른쪽에 보이는 `2025/02/26 ~ 2026/02/26`.
  String? get rangeText => isCustom
      ? '${formatPanelDate(custom!.start)} ~ ${formatPanelDate(custom!.end)}'
      : null;

  String get label => preset.label;
}

/// 기간 필터 단추. 프리셋 목록의 "직접 설정"을 누르면 같은 패널이 프로젝트 "새 업무"의 기간 달력
/// (시작일 → 마감일 차례로 고르는 [DateRangeCalendarPanel])으로 바뀌고, 종료일까지 고르면 닫힌다.
class PeriodFilterButton extends StatelessWidget {
  final PanelPeriod period;
  final ValueChanged<PanelPeriod> onChanged;
  const PeriodFilterButton({
    super.key,
    required this.period,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return FilterDropdownButton(
      label: period.label,
      expand: true,
      alignEnd: true,
      panelBuilder: (close) =>
          _PeriodPanel(period: period, close: close, onChanged: onChanged),
    );
  }
}

class _PeriodPanel extends StatefulWidget {
  final PanelPeriod period;
  final VoidCallback close;
  final ValueChanged<PanelPeriod> onChanged;
  const _PeriodPanel({
    required this.period,
    required this.close,
    required this.onChanged,
  });

  @override
  State<_PeriodPanel> createState() => _PeriodPanelState();
}

class _PeriodPanelState extends State<_PeriodPanel> {
  bool _calendar = false;
  DateTime? _start;
  DateTime? _end;

  @override
  Widget build(BuildContext context) {
    if (!_calendar) {
      return FilterPanelShell(
        width: 200,
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final p in PeriodPreset.values)
              ListTile(
                key: ValueKey('period-${p.name}'),
                dense: true,
                title: Text(p.label),
                trailing: widget.period.preset == p
                    ? const Icon(Icons.check, size: 18)
                    : null,
                onTap: () {
                  if (p == PeriodPreset.custom) {
                    setState(() {
                      _calendar = true;
                      _start = widget.period.custom?.start;
                      _end = widget.period.custom?.end;
                    });
                    return;
                  }
                  widget.onChanged(PanelPeriod(p));
                  widget.close();
                },
              ),
          ],
        ),
      );
    }
    final hint = Theme.of(context).hintColor;
    // 프로젝트 "새 업무"의 기간 칸에 붙어 펼쳐지는 달력과 같은 틀(폭 300, 둥근 12).
    return Material(
      key: const ValueKey('period-calendar'),
      elevation: 6,
      borderRadius: BorderRadius.circular(12),
      color: Theme.of(context).colorScheme.surface,
      child: Container(
        width: 300,
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _start == null || _end != null ? '시작일을 선택하세요' : '종료일을 선택하세요',
              style: TextStyle(color: hint, fontSize: 12),
            ),
            const SizedBox(height: 6),
            DateRangeCalendarPanel(
              start: _start,
              end: _end,
              lastDate: DateTime.now(),
              onChanged: (start, end) {
                setState(() {
                  _start = start;
                  _end = end;
                });
                if (start != null && end != null) {
                  widget.onChanged(
                    PanelPeriod.custom(DateTimeRange(start: start, end: end)),
                  );
                  widget.close();
                }
              },
            ),
          ],
        ),
      ),
    );
  }
}

// ── 멤버 ───────────────────────────────────────────────────────────

/// "모든 멤버" 필터 — [users]는 패널이 정한 후보(검색 패널은 팀 전체, 파일·링크 패널은 지금 범위의 방 멤버).
class MemberFilterButton extends StatelessWidget {
  final List<AppUser>? users;
  final String? selectedSenderId;
  final ValueChanged<String?> onSelected;

  /// true면 펼침 패널을 단추 오른쪽 끝에 맞춘다(줄 오른쪽 끝 칸 — [FilterDropdownButton.alignEnd]).
  final bool alignEnd;
  const MemberFilterButton({
    super.key,
    required this.users,
    required this.selectedSenderId,
    required this.onSelected,
    this.alignEnd = false,
  });

  /// 펼침 패널 폭.
  static const panelWidth = 220.0;

  String get _label {
    final id = selectedSenderId;
    if (id == null) return '모든 멤버';
    for (final u in users ?? const <AppUser>[]) {
      if (u.id == id) return u.name;
    }
    return '모든 멤버';
  }

  @override
  Widget build(BuildContext context) {
    return FilterDropdownButton(
      label: _label,
      expand: true,
      alignEnd: alignEnd,
      panelWidth: panelWidth,
      panelBuilder: (close) => FilterPanelShell(
        width: panelWidth,
        child: _MemberFilterPanel(
          users: users ?? const <AppUser>[],
          selectedSenderId: selectedSenderId,
          onSelected: (id) {
            onSelected(id);
            close();
          },
        ),
      ),
    );
  }
}

class _MemberFilterPanel extends StatefulWidget {
  final List<AppUser> users;
  final String? selectedSenderId;
  final ValueChanged<String?> onSelected;
  const _MemberFilterPanel({
    required this.users,
    required this.selectedSenderId,
    required this.onSelected,
  });

  @override
  State<_MemberFilterPanel> createState() => _MemberFilterPanelState();
}

class _MemberFilterPanelState extends State<_MemberFilterPanel> {
  String _filter = '';

  @override
  Widget build(BuildContext context) {
    final list =
        widget.users
            .where(
              (u) =>
                  _filter.isEmpty ||
                  u.name.toLowerCase().contains(_filter.toLowerCase()),
            )
            .toList()
          ..sort((a, b) => a.name.compareTo(b.name));

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        filterSearchBox((v) => setState(() => _filter = v)),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(
                dense: true,
                title: const Text('모든 멤버'),
                trailing: widget.selectedSenderId == null
                    ? const Icon(Icons.check, size: 18)
                    : null,
                onTap: () => widget.onSelected(null),
              ),
              const Divider(height: 1),
              for (final u in list)
                ListTile(
                  dense: true,
                  leading: CircleAvatar(
                    radius: 12,
                    child: Text(u.name.isNotEmpty ? u.name[0] : '?'),
                  ),
                  title: Text(
                    u.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: widget.selectedSenderId == u.id
                      ? const Icon(Icons.check, size: 18)
                      : null,
                  onTap: () => widget.onSelected(u.id),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 파일·링크 패널의 "모든 멤버" 후보 — 방을 하나 골랐으면 그 방 멤버만, 전체면 비밀 아닌 내 방들의
/// 멤버를 모아 보여준다(검색 패널과 달리 조직 전체 사용자 목록은 쓰지 않는다). [teamId]를 주면 그 팀의
/// 방만 본다 — session.rooms에는 모든 팀의 방이 들어 있어서, 팀 안에서만 찾는 패널(할 일)은 다른 팀
/// 사람을 골라도 결과가 없다.
List<AppUser> memberChoicesFor(
  Session session,
  String? roomId, {
  String? teamId,
}) {
  bool inTeam(Room r) => teamId == null || r.teamId == teamId;
  if (roomId != null) {
    for (final r in session.rooms) {
      if (r.id == roomId && inTeam(r)) return r.members;
    }
  }
  final byId = <String, AppUser>{};
  for (final Room r in session.rooms.where((r) => !r.isSecret && inTeam(r))) {
    for (final m in r.members) {
      byId[m.id] = m;
    }
  }
  return byId.values.toList();
}

// ── 정렬 · 파일 형식 메뉴 ───────────────────────────────────────────

/// 결과 정렬(최신 순/과거 순) 단추 — 누르면 메시지 예약 패널의 정렬 메뉴와 같은 드롭다운([CompactMenuAnchor])이
/// 단추 오른쪽 끝에 맞춰 바로 뜬다. [spaced]면 "최신 순", 아니면 "최신순"(파일·링크 패널 표기).
class PanelSortButton extends StatelessWidget {
  final bool newestFirst;
  final ValueChanged<bool> onChanged;
  final bool spaced;
  const PanelSortButton({
    super.key,
    required this.newestFirst,
    required this.onChanged,
    this.spaced = true,
  });

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    final newest = spaced ? '최신 순' : '최신순';
    final oldest = spaced ? '과거 순' : '과거순';
    return CompactMenuAnchor<bool>(
      alignEnd: true,
      selected: newestFirst,
      onSelected: onChanged,
      entries: [
        CompactMenuOption(value: true, label: newest),
        CompactMenuOption(value: false, label: oldest),
      ],
      builder: (context, open, toggle) => _MenuLabelButton(
        buttonKey: const ValueKey('panel-sort'),
        tooltip: '정렬',
        open: open,
        onTap: toggle,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.swap_vert, size: 16, color: hint),
            const SizedBox(width: 2),
            Text(
              newestFirst ? newest : oldest,
              style: Theme.of(
                context,
              ).textTheme.labelMedium?.copyWith(color: hint),
            ),
          ],
        ),
      ),
    );
  }
}

/// 드롭다운을 여는 작은 글자 단추 — 툴팁, 펼침 여부(접근성), 누르기, 위아래 8·좌우 4 여백.
class _MenuLabelButton extends StatelessWidget {
  /// 누르는 칸(InkWell)의 키 — 테스트가 단추를 찾는 데 쓴다.
  final Key? buttonKey;
  final String tooltip;
  final bool open;
  final VoidCallback onTap;
  final EdgeInsetsGeometry padding;
  final Widget child;
  const _MenuLabelButton({
    this.buttonKey,
    required this.tooltip,
    required this.open,
    required this.onTap,
    this.padding = const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      expanded: open,
      child: Tooltip(
        message: tooltip,
        child: InkWell(
          key: buttonKey,
          onTap: onTap,
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

/// 검색 범위(현재 팀 / 모든 팀 / ─ / 가입한 팀 이름들) 단추 — [PanelSortButton]과 같은 폰트·크기(라벨 12px,
/// 흐린 색)에 글자 오른쪽 꺽쇠. 누르면 같은 모양의 드롭다운이 뜬다. [teams]를 주면 구분선 아래에 팀 이름이
/// 하나씩 붙어 그 팀 하나만 골라 찾을 수 있고, 골랐으면([teamId]) 단추 글자가 그 팀 이름이 된다.
/// 가입한 팀이 하나뿐이면 호출하는 쪽이 아예 그리지 않는다.
class PanelScopeButton extends StatelessWidget {
  final bool allTeams;
  final ValueChanged<bool> onChanged;

  /// 특정 팀 선택지(가입한 팀 전부) — 비어 있으면 현재 팀 / 모든 팀만.
  final List<({String id, String name})> teams;

  /// 고른 특정 팀 id — null이면 [allTeams]에 따라 현재 팀 또는 모든 팀.
  final String? teamId;
  final ValueChanged<String>? onTeamSelected;
  const PanelScopeButton({
    super.key,
    required this.allTeams,
    required this.onChanged,
    this.teams = const [],
    this.teamId,
    this.onTeamSelected,
  });

  // 메뉴 값 — 팀 id와 겹치지 않게 콜론으로 시작한다.
  static const _current = ':current';
  static const _all = ':all';

  /// 단추 글자 — 고른 팀이 목록에 없으면(그 사이 팀을 나간 경우 등) 현재 팀 / 모든 팀으로.
  String get _label {
    final id = teamId;
    if (id != null) {
      for (final t in teams) {
        if (t.id == id) return t.name;
      }
    }
    return allTeams ? '모든 팀' : '현재 팀';
  }

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    final picked = teamId != null && teams.any((t) => t.id == teamId);
    final value = picked ? teamId! : (allTeams ? _all : _current);
    return CompactMenuAnchor<String>(
      alignEnd: true,
      maxWidth: 220,
      selected: value,
      onSelected: (v) {
        if (v == _current || v == _all) {
          onChanged(v == _all);
        } else {
          onTeamSelected?.call(v);
        }
      },
      entries: [
        const CompactMenuOption(
          key: ValueKey('panel-scope-current'),
          value: _current,
          label: '현재 팀',
        ),
        const CompactMenuOption(
          key: ValueKey('panel-scope-all'),
          value: _all,
          label: '모든 팀',
        ),
        if (teams.isNotEmpty && onTeamSelected != null) ...[
          const CompactMenuDivider(),
          for (final t in teams)
            CompactMenuOption(
              key: ValueKey('panel-scope-team-${t.id}'),
              value: t.id,
              label: t.name,
            ),
        ],
      ],
      builder: (context, open, toggle) => _MenuLabelButton(
        buttonKey: const ValueKey('panel-scope'),
        tooltip: '검색 범위',
        open: open,
        onTap: toggle,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 팀 이름이 길면 말줄임 — 탭 줄·결과 줄을 밀어내지 않게.
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 120),
              child: Text(
                _label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.labelMedium?.copyWith(color: hint),
              ),
            ),
            Icon(Icons.keyboard_arrow_down, size: 16, color: hint),
          ],
        ),
      ),
    );
  }
}

/// 파일 형식 메뉴(전체 파일 / 이미지 / 문서 / … / 기타) — [child]를 누르면 정렬 메뉴와 같은 모양의 드롭다운
/// ([CompactMenuAnchor], 항목마다 형식 아이콘)이 뜬다.
class FileCategoryMenu extends StatelessWidget {
  final FileCategory selected;
  final ValueChanged<FileCategory> onSelected;
  final Widget child;
  final String tooltip;
  const FileCategoryMenu({
    super.key,
    required this.selected,
    required this.onSelected,
    required this.child,
    this.tooltip = '파일 형식',
  });

  @override
  Widget build(BuildContext context) {
    return CompactMenuAnchor<FileCategory>(
      maxWidth: 220,
      selected: selected,
      onSelected: onSelected,
      entries: [
        for (final c in FileCategory.values)
          CompactMenuOption(
            key: ValueKey('file-kind-${c.name}'),
            value: c,
            label: c.label,
            icon: c.icon,
          ),
      ],
      builder: (context, open, toggle) => _MenuLabelButton(
        buttonKey: const ValueKey('panel-file-kind'),
        tooltip: tooltip,
        open: open,
        onTap: toggle,
        padding: EdgeInsets.zero,
        child: child,
      ),
    );
  }
}

/// 파일 패널 필터 줄 아래의 "파일 ⌄" 단추 — 눌러서 파일 형식 메뉴를 연다. 형식을 고르면 이름이 바뀐다.
class FileCategoryButton extends StatelessWidget {
  final FileCategory category;
  final ValueChanged<FileCategory> onSelected;
  const FileCategoryButton({
    super.key,
    required this.category,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final active = category != FileCategory.all;
    final color = active ? theme.colorScheme.primary : theme.hintColor;
    return FileCategoryMenu(
      selected: category,
      onSelected: onSelected,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 0, 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              category.buttonLabel,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
            Icon(Icons.keyboard_arrow_down, size: 18, color: color),
          ],
        ),
      ),
    );
  }
}

// ── 파일·링크 패널 상단 ──────────────────────────────────────────────

/// 파일·링크 패널의 상단 — 위에서부터 검색칸, 필터 줄(참여 대화방 / 모든 멤버 / 기간), 그 아래
/// 줄(왼쪽 [leading] — 파일 패널은 "파일 ⌄" — 과 맨 오른쪽 정렬 단추). 검색어는 입력을 멈추고
/// 잠깐 뒤(또는 엔터)에 [onQueryChanged]로 알린다.
class PanelFilterBar extends StatefulWidget {
  final String searchHint;

  /// 처음에 채워 둘 검색어 — 파일 패널이 "메시지" 미리보기에서 돌아올 때 이 줄이 새로 그려져도 지금
  /// 걸어 둔 검색어가 칸에 남아 있게 한다.
  final String initialQuery;
  final ValueChanged<String> onQueryChanged;
  final Session session;
  final String? roomId;
  final ValueChanged<String?> onRoomChanged;
  final List<AppUser> members;
  final String? senderId;
  final ValueChanged<String?> onSenderChanged;
  final PanelPeriod period;
  final ValueChanged<PanelPeriod> onPeriodChanged;
  final Widget? leading;

  /// true면 [leading]이 정렬 단추를 뺀 줄 나머지를 다 차지한다(즐겨찾기 패널의 가로 스크롤 종류 탭).
  final bool leadingExpands;

  /// 종류에 따라 걸 수 없는 필터는 흐리게 막는다(즐겨찾기 패널 — 멤버 탭은 대화방 필터가 안 먹는다 등).
  final bool roomEnabled;
  final bool memberEnabled;
  final bool periodEnabled;
  final bool newestFirst;
  final ValueChanged<bool> onSortChanged;

  /// false면 맨 위 검색칸을 그리지 않는다(검색어 없이 필터만 쓰는 투표 목록·내가 쓴 글 패널).
  final bool showSearch;

  /// false면 필터 줄에서 "모든 멤버" 칸을 뺀다(보낸 사람이 늘 나인 내가 쓴 글 패널).
  final bool showMember;

  const PanelFilterBar({
    super.key,
    required this.searchHint,
    this.initialQuery = '',
    required this.onQueryChanged,
    required this.session,
    required this.roomId,
    required this.onRoomChanged,
    required this.members,
    required this.senderId,
    required this.onSenderChanged,
    required this.period,
    required this.onPeriodChanged,
    this.leading,
    this.leadingExpands = false,
    this.roomEnabled = true,
    this.memberEnabled = true,
    this.periodEnabled = true,
    required this.newestFirst,
    required this.onSortChanged,
    this.showSearch = true,
    this.showMember = true,
  });

  @override
  State<PanelFilterBar> createState() => _PanelFilterBarState();
}

class _PanelFilterBarState extends State<PanelFilterBar> {
  late final _controller = TextEditingController(text: widget.initialQuery);
  Timer? _debounce;
  late String _sent = widget.initialQuery;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _emit() {
    _debounce?.cancel();
    final text = _controller.text.trim();
    if (text == _sent) return;
    _sent = text;
    widget.onQueryChanged(text);
  }

  void _onChanged(String _) {
    setState(() {}); // 지우기(X) 단추 표시
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), _emit);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(16, widget.showSearch ? 16 : 12, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.showSearch) ...[
            TextField(
              key: const ValueKey('panel-search-field'),
              controller: _controller,
              decoration: InputDecoration(
                hintText: widget.searchHint,
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: _controller.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        tooltip: '지우기',
                        onPressed: () {
                          _controller.clear();
                          setState(() {});
                          _emit();
                        },
                      ),
                border: const OutlineInputBorder(),
              ),
              textInputAction: TextInputAction.search,
              onChanged: _onChanged,
              onSubmitted: (_) => _emit(),
            ),
            const SizedBox(height: 12),
          ],
          Row(
            children: [
              Expanded(
                child: _Disableable(
                  enabled: widget.roomEnabled,
                  child: RoomFilterButton(
                    session: widget.session,
                    selectedRoomId: widget.roomId,
                    expand: true,
                    onSelected: widget.onRoomChanged,
                  ),
                ),
              ),
              if (widget.showMember) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: _Disableable(
                    enabled: widget.memberEnabled,
                    child: MemberFilterButton(
                      users: widget.members,
                      selectedSenderId: widget.senderId,
                      onSelected: widget.onSenderChanged,
                    ),
                  ),
                ),
              ],
              const SizedBox(width: 8),
              Expanded(
                child: _Disableable(
                  enabled: widget.periodEnabled,
                  child: PeriodFilterButton(
                    period: widget.period,
                    onChanged: widget.onPeriodChanged,
                  ),
                ),
              ),
            ],
          ),
          Row(
            children: [
              if (widget.leadingExpands && widget.leading != null)
                Expanded(child: widget.leading!)
              else ...[
                ?widget.leading,
                const Spacer(),
              ],
              PanelSortButton(
                spaced: false,
                newestFirst: widget.newestFirst,
                onChanged: widget.onSortChanged,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// [enabled]가 false면 흐리게 하고 눌리지 않게 한다.
class _Disableable extends StatelessWidget {
  final bool enabled;
  final Widget child;
  const _Disableable({required this.enabled, required this.child});

  @override
  Widget build(BuildContext context) {
    if (enabled) return child;
    return IgnorePointer(child: Opacity(opacity: 0.4, child: child));
  }
}

// ── 결과 줄 ─────────────────────────────────────────────────────────

/// 목록 바로 위 줄 — 왼쪽에 건수 문구, 오른쪽에 (직접 설정한) 기간.
class PanelResultLine extends StatelessWidget {
  final Widget summary;
  final String? rangeText;

  /// 오른쪽 끝에 더 붙일 단추(좁은 폭에서 탭 줄에 못 둔 검색 범위 단추). 기간 표시와 함께 있어 좁으면
  /// 둘이 위아래로 줄바꿈된다(기간 표시 위, 단추 아래).
  final Widget? trailing;
  const PanelResultLine({
    super.key,
    required this.summary,
    this.rangeText,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final range = rangeText == null
        ? null
        : Text(
            rangeText!,
            key: const ValueKey('panel-range-text'),
            style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
          );
    return Container(
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
      padding: EdgeInsets.fromLTRB(
        16,
        trailing == null ? 10 : 2,
        16,
        trailing == null ? 10 : 2,
      ),
      child: Row(
        children: [
          Expanded(child: summary),
          if (trailing != null)
            Flexible(
              child: Wrap(
                alignment: WrapAlignment.end,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                children: [?range, trailing!],
              ),
            )
          else if (range != null) ...[
            const SizedBox(width: 8),
            range,
          ],
        ],
      ),
    );
  }
}

// ── 종류 ────────────────────────────────────────────────────────────

/// 종류(전체 / 메시지 / 댓글 …) 고르기 단추 — 즐겨찾기·내가 쓴 글 패널이 정렬 단추 줄 왼쪽 끝에 둔다. [PanelSortButton]과
/// 같은 폰트·크기(라벨 12px, 흐린 색)에 글자 오른쪽 꺽쇠, 누르면 같은 모양의 드롭다운(설정 메뉴 모양, 지금 종류에 체크)이
/// 뜬다. [values]에 null(전체)이 들어 있어도 되게 메뉴 값은 순번으로 다룬다.
class PanelKindButton<T> extends StatelessWidget {
  final List<T> values;
  final T selected;
  final String Function(T value) labelOf;
  final ValueChanged<T> onChanged;
  final String tooltip;

  /// 메뉴 항목마다 붙일 키(테스트가 항목을 찾는 데 쓴다).
  final Key? Function(T value)? itemKey;
  const PanelKindButton({
    super.key,
    required this.values,
    required this.selected,
    required this.labelOf,
    required this.onChanged,
    this.tooltip = '종류',
    this.itemKey,
  });

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    final current = values.indexOf(selected);
    return CompactMenuAnchor<int>(
      selected: current < 0 ? null : current,
      onSelected: (i) => onChanged(values[i]),
      entries: [
        for (final (i, v) in values.indexed)
          CompactMenuOption(key: itemKey?.call(v), value: i, label: labelOf(v)),
      ],
      builder: (context, open, toggle) => _MenuLabelButton(
        tooltip: tooltip,
        open: open,
        onTap: toggle,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              labelOf(selected),
              style: Theme.of(
                context,
              ).textTheme.labelMedium?.copyWith(color: hint),
            ),
            Icon(Icons.keyboard_arrow_down, size: 16, color: hint),
          ],
        ),
      ),
    );
  }
}
