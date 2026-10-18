import 'package:flutter/material.dart';

import '../../models/calendar.dart';
import '../../services/calendar_controller.dart';
import '../../services/calendar_search.dart';
import 'calendar_common.dart';
import '../../l10n/tr.dart';

/// 캘린더 일정 검색 화면 조각 — PC 툴바의 검색창([CalendarSearchField])과 그 아래 결과 패널, 모바일 전체 화면 검색
/// ([CalendarSearchScreen])이 같은 [CalendarSearchResults]를 쓴다. 일정 **제목**만 검색한다(참석자·내용은 안 됨).

/// 결과 한 줄에서 "이동"을 눌렀다 — 캘린더를 그 일정이 등록된 날짜로 옮긴다.
typedef SearchItemCallback = void Function(CalendarSearchItem item);

/// 검색 입력칸. 입력은 300ms 멈추면 검색되고(엔터는 바로), 지우기(x)로 비운다.
class CalendarSearchField extends StatefulWidget {
  final CalendarSearchController controller;
  final FocusNode? focusNode;
  final bool autofocus;

  /// 칸을 눌러 포커스를 얻거나 글자를 바꿀 때(PC는 결과 패널을 연다).
  final VoidCallback? onActivate;

  /// 칸 너비. null이면 부모가 정한다.
  final double? width;

  const CalendarSearchField({
    super.key,
    required this.controller,
    this.focusNode,
    this.autofocus = false,
    this.onActivate,
    this.width,
  });

  @override
  State<CalendarSearchField> createState() => _CalendarSearchFieldState();
}

class _CalendarSearchFieldState extends State<CalendarSearchField> {
  late final TextEditingController _text = TextEditingController(
    text: widget.controller.query,
  );

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_syncFromController);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_syncFromController);
    _text.dispose();
    super.dispose();
  }

  /// 컨트롤러가 비워졌으면(팀 전환 등) 입력칸도 비운다.
  void _syncFromController() {
    if (widget.controller.query.isEmpty && _text.text.isNotEmpty) {
      _text.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final field = ListenableBuilder(
      listenable: _text,
      builder: (context, _) => TextField(
        key: const ValueKey('cal-search-field'),
        controller: _text,
        focusNode: widget.focusNode,
        autofocus: widget.autofocus,
        textInputAction: TextInputAction.search,
        style: const TextStyle(fontSize: 14),
        decoration: InputDecoration(
          isDense: true,
          hintText: tr('일정 제목 검색'),
          prefixIcon: const Icon(Icons.search, size: 20),
          prefixIconConstraints: const BoxConstraints(minWidth: 36),
          suffixIcon: _text.text.isEmpty
              ? null
              : IconButton(
                  key: const ValueKey('cal-search-clear'),
                  tooltip: tr('지우기'),
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () {
                    _text.clear();
                    widget.controller.clear();
                    widget.onActivate?.call();
                  },
                ),
          border: const OutlineInputBorder(),
          contentPadding: const EdgeInsets.symmetric(vertical: 8),
        ),
        onTap: widget.onActivate,
        onChanged: (v) {
          widget.controller.setQuery(v);
          widget.onActivate?.call();
        },
        onSubmitted: (v) {
          widget.controller.setQuery(v);
          widget.controller.search();
        },
      ),
    );
    return widget.width == null
        ? field
        : SizedBox(width: widget.width, child: field);
  }
}

/// 검색 결과 목록 — 안내/불러오는 중/오류/결과 없음/결과와 "더 보기".
class CalendarSearchResults extends StatelessWidget {
  final CalendarSearchController controller;
  final SearchItemCallback onOpen;
  final SearchItemCallback onMove;

  /// 패널(높이 제한이 있는 곳)은 true, 화면을 채우는 곳은 false.
  final bool shrinkWrap;

  const CalendarSearchResults({
    super.key,
    required this.controller,
    required this.onOpen,
    required this.onMove,
    this.shrinkWrap = true,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => _body(context),
    );
  }

  Widget _message(BuildContext context, String text, {Widget? action}) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(color: theme.hintColor),
            ),
            ?action,
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final c = controller;
    if (!c.hasQuery) {
      return _message(context, tr('일정 제목의 일부를 입력하세요.\n참석자·내용으로는 검색되지 않습니다.'));
    }
    final items = c.visibleItems;
    if (c.loading && items.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(
              key: ValueKey('cal-search-loading'),
              strokeWidth: 2.5,
            ),
          ),
        ),
      );
    }
    if (c.error != null && items.isEmpty) {
      return _message(
        context,
        c.error!,
        action: TextButton(
          key: const ValueKey('cal-search-retry'),
          onPressed: c.search,
          child: Text(tr('다시 시도')),
        ),
      );
    }
    if (!c.searched) {
      // 입력 직후 디바운스를 기다리는 중.
      return const SizedBox(height: 56);
    }
    if (items.isEmpty && !c.hasMore) {
      return _message(context, tr('검색 결과가 없습니다.'));
    }
    return ListView(
      key: const ValueKey('cal-search-list'),
      shrinkWrap: shrinkWrap,
      padding: const EdgeInsets.symmetric(vertical: 4),
      children: [
        if (c.loading) const LinearProgressIndicator(minHeight: 2),
        for (final item in items)
          CalendarSearchTile(
            key: ValueKey('cal-search-item-${item.eventId}'),
            item: item,
            onOpen: () => onOpen(item),
            onMove: () => onMove(item),
          ),
        if (c.error != null)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              c.error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        if (c.hasMore)
          Center(
            child: c.loadingMore
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : TextButton(
                    key: const ValueKey('cal-search-more'),
                    onPressed: c.loadMore,
                    child: Text(tr('더 보기')),
                  ),
          ),
      ],
    );
  }
}

/// 참석자 문구 — 두 명까지는 이름, 더 많으면 인원수. 없으면 null.
String? searchAttendeeText(CalendarSearchItem item) {
  final names = [for (final a in item.attendees) a.name];
  if (names.isEmpty) return null;
  return names.length <= 2
      ? tr('참석자 {p0}', {'p0': names.join(', ')})
      : tr('참석자 {names.length}명', {'names.length': names.length});
}

/// 결과 한 줄 — 색 점 + 제목, 날짜·시간, 캘린더 이름, 반복·참석자 표시, 오른쪽 "이동" 버튼.
class CalendarSearchTile extends StatelessWidget {
  final CalendarSearchItem item;
  final VoidCallback onOpen;
  final VoidCallback onMove;

  const CalendarSearchTile({
    super.key,
    required this.item,
    required this.onOpen,
    required this.onMove,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    final occurrence = item.toOccurrence();
    final attendees = searchAttendeeText(item);
    final color = calendarColor(item.color);
    return InkWell(
      onTap: onOpen,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              margin: const EdgeInsets.only(top: 5, right: 10),
              width: 10,
              height: 10,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    formatEventPeriod(occurrence),
                    key: ValueKey('cal-search-period-${item.eventId}'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: hint,
                  ),
                  const SizedBox(height: 2),
                  Wrap(
                    spacing: 8,
                    runSpacing: 2,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (item.calendarName.isNotEmpty)
                        Text(item.calendarName, style: hint),
                      if (item.recurring)
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.repeat,
                              size: 13,
                              color: theme.hintColor,
                            ),
                            const SizedBox(width: 2),
                            Text(tr('반복'), style: hint),
                          ],
                        ),
                      if (attendees != null) Text(attendees, style: hint),
                    ],
                  ),
                ],
              ),
            ),
            TextButton(
              key: ValueKey('cal-search-move-${item.eventId}'),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                minimumSize: const Size(48, 32),
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              onPressed: onMove,
              child: Text(tr('이동')),
            ),
          ],
        ),
      ),
    );
  }
}

/// 모바일 전체 화면 검색 — 입력 + 결과. "이동"을 누르면 그 날짜를 돌려주며 닫힌다. 일정을 누르면 [onOpen]이
/// (이 화면 위에) 상세를 연다.
class CalendarSearchScreen extends StatefulWidget {
  final CalendarController controller;
  final SearchItemCallback onOpen;

  const CalendarSearchScreen({
    super.key,
    required this.controller,
    required this.onOpen,
  });

  @override
  State<CalendarSearchScreen> createState() => _CalendarSearchScreenState();
}

class _CalendarSearchScreenState extends State<CalendarSearchScreen> {
  @override
  Widget build(BuildContext context) {
    final search = widget.controller.search;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Padding(
          padding: const EdgeInsets.only(right: 12),
          child: CalendarSearchField(controller: search, autofocus: true),
        ),
      ),
      body: SafeArea(
        child: CalendarSearchResults(
          controller: search,
          shrinkWrap: false,
          onOpen: widget.onOpen,
          onMove: (item) => Navigator.of(context).pop(item.firstDay),
        ),
      ),
    );
  }
}
