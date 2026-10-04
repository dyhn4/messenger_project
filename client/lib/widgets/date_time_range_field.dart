import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/time_format.dart' show formatScheduleClock;

/// 시간 목록의 간격(분) — 오전 12:00 … 오후 11:45.
const dateTimeRangeSlotMinutes = 15;

/// 기간 한 끝의 기본 표기 — 시각([minutes], 자정부터 분)이 있으면 `yyyy/MM/dd 오전|오후 h:mm`, 없으면 `yyyy/MM/dd`.
String formatRangePoint(DateTime date, int? minutes) {
  final day =
      '${date.year}/${date.month.toString().padLeft(2, '0')}/${date.day.toString().padLeft(2, '0')}';
  return minutes == null ? day : '$day ${formatRangeClock(minutes)}';
}

/// 시각(자정부터 분)의 기본 표기 — `오전|오후 h:mm`.
String formatRangeClock(int minutes) =>
    formatScheduleClock(DateTime(2000, 1, 1, 0, minutes));

/// [now] 이후(이미 15분 단위면 그대로)의 가장 가까운 15분 단위 시각(자정부터 분) — 날짜를 새로 고를 때 비어 있던 시간에
/// 채우는 기본값. 자정을 넘기면 그날의 마지막 칸(오후 11:45)에 둔다.
int nextRangeSlotMinutes(DateTime now) {
  final exact = now.second == 0 && now.millisecond == 0 && now.microsecond == 0;
  final minutes = now.hour * 60 + now.minute;
  final up = minutes % dateTimeRangeSlotMinutes == 0 && exact
      ? minutes
      : (minutes ~/ dateTimeRangeSlotMinutes + 1) * dateTimeRangeSlotMinutes;
  return math.min(up, 24 * 60 - dateTimeRangeSlotMinutes);
}

DateTime _dayOf(DateTime t) => DateTime(t.year, t.month, t.day);

bool _sameDay(DateTime? a, DateTime? b) =>
    a == null || b == null ? a == b : _dayOf(a) == _dayOf(b);

/// 기간 값 — 시작일·종료일(날짜만)과 각자의 시각(자정부터 분, null이면 `시간 없음`). 시각은 그 날짜가 있을 때만 있다.
@immutable
class DateTimeRangeSelection {
  final DateTime? start;
  final DateTime? end;
  final int? startMinutes;
  final int? endMinutes;
  const DateTimeRangeSelection({
    this.start,
    this.end,
    this.startMinutes,
    this.endMinutes,
  });

  bool get isEmpty => start == null && end == null;

  /// 달력에서 [day]를 눌렀을 때의 값 — 처음 누르면(또는 기간이 다 정해진 뒤 다시 누르면) 시작일, 그다음은 종료일(시작일보다
  /// 빠르면 그 날로 시작일을 다시 잡는다 — 프로젝트 "새 업무"의 기간 달력과 같은 규칙). 날짜가 바뀌었고 그 시간이 비어
  /// 있으면 [defaultMinutes]로 채우고, 날짜가 비면 그 시간도 지운다. 이미 시간이 있던 날짜를 옮기면 시간은 그대로.
  DateTimeRangeSelection pick(DateTime day, int Function() defaultMinutes) {
    final d = _dayOf(day);
    DateTime? s = start;
    DateTime? e = end;
    if (s == null || e != null || d.isBefore(_dayOf(s))) {
      s = d;
      e = null;
    } else {
      e = d;
    }
    int? minutesFor(DateTime? now, DateTime? before, int? minutes) {
      if (now == null) return null;
      if (!_sameDay(now, before) && minutes == null) return defaultMinutes();
      return minutes;
    }

    return DateTimeRangeSelection(
      start: s,
      end: e,
      startMinutes: minutesFor(s, start, startMinutes),
      endMinutes: minutesFor(e, end, endMinutes),
    );
  }
}

/// 기간(시작일 시각 ~ 종료일 시각)을 **한 칸**에서 고르는 입력 — 칸에는 `2026/10/13 오전 9:00 ~ 2026/10/14 오후 6:00`
/// (좁으면 `~` 뒤에서 두 줄), 비어 있으면 [placeholder], 정했으면 오른쪽에 ✕(날짜와 시간을 모두 지운다). 누르면 칸 바로
/// 아래(자리가 모자라면 위 — 칸을 덮지 않게)에 판이 뜬다: 기간 달력(첫 누름 시작일, 둘째 누름 종료일 — 사이는 옅은 띠)과
/// 그 아래 `시작 시간`, 바로 밑에 `종료 시간` 칸(높이 36, 글자 14, 시계 아이콘 · ▾ — 그 날짜가 없으면 꺼짐). 시간 칸을
/// 누르면 시간 목록(첫 줄 `시간 없음`, 그다음 15분 단위 — 지금 값에 체크, 그 자리로 스크롤해 연다)이 칸 바로 위로 판
/// 안에서 달력을 덮으며 펼쳐진다(판 크기가 그대로라 화면 밖으로 안 나간다). 예약 메시지·투표 마감 시각의 날짜·시각 칸
/// (ScheduleDateTimeField)과 같은 모양이다.
///
/// 판은 창 전체(루트 Overlay)에 띄우고 그 아래를 투명한 막이 덮는다 — 바깥(PC 할 일 패널 안 화면이면 패널 밖 채팅 쪽까지)을
/// 누르면 닫히고 그 누름은 아래로 가지 않는다. 날짜·시간을 골라도 판은 열린 채이고, 바깥이나 칸을 누르거나 Esc로 닫는다
/// (시간 목록이 열려 있으면 Esc·판 안의 다른 곳 누르기는 목록만 닫는다). 자리는 가장 가까운 Overlay(패널 안 화면이면 패널)
/// 안으로 맞춘다. 키는 [keyPrefix]를 앞에 붙인 `-period-field`(칸) · `-period-clear`(✕) · `-period-popup`(판) ·
/// `-period-day-<년>-<월>-<일>` · `-period-prev`/`-period-next`(달 이동) · `-time-start`/`-time-end`(시간 칸) ·
/// `-time-list` · `-time-option-none`/`-time-option-<분>`.
class DateTimeRangeField extends StatefulWidget {
  final DateTimeRangeSelection value;
  final ValueChanged<DateTimeRangeSelection> onChanged;
  final bool enabled;
  final String placeholder;
  final String keyPrefix;

  /// 날짜를 새로 골랐는데 그 시간이 비어 있을 때 채우는 시각(자정부터 분) — 기본은 지금 이후의 가장 가까운 15분 단위.
  final int Function() defaultMinutes;

  /// 칸에 보이는 한 끝(`2026/10/13 오전 9:00`)과 시간 칸·목록의 시각(`오전 9:00`) 표기.
  final String Function(DateTime date, int? minutes) formatPoint;
  final String Function(int minutes) formatClock;

  /// 칸 모양 — 높이·모서리·테두리 색(기본 outlineVariant, 펼친 동안은 primary 1.5).
  final double height;
  final double radius;
  final Color? borderColor;

  const DateTimeRangeField({
    super.key,
    required this.value,
    required this.onChanged,
    this.enabled = true,
    this.placeholder = '기간을 선택하세요',
    this.keyPrefix = 'range',
    this.defaultMinutes = _nowSlot,
    this.formatPoint = formatRangePoint,
    this.formatClock = formatRangeClock,
    this.height = 50,
    this.radius = 8,
    this.borderColor,
  });

  static int _nowSlot() => nextRangeSlotMinutes(DateTime.now());

  @override
  State<DateTimeRangeField> createState() => DateTimeRangeFieldState();
}

/// 판 안의 시간 칸 — 시작 / 종료.
enum _TimeSide { start, end }

class DateTimeRangeFieldState extends State<DateTimeRangeField>
    with WidgetsBindingObserver {
  final _overlay = OverlayPortalController();
  final _link = LayerLink();

  /// 판을 열 때 포커스를 이 칸으로 옮긴다 — 글을 쓰던 중이면 휴대폰 화상 키보드가 내려가서 펼친 판을 가리지 않고, Esc가
  /// 이 칸으로 온다.
  final _focus = FocusNode(debugLabel: 'date-time-range');

  /// 칸 위에 펼치는지, 위·아래 자리가 다 모자라 칸 쪽으로 밀어 넣은 세로 거리, 오른쪽 끝을 넘지 않게 옮긴 가로 거리 —
  /// [_place]가 정한다.
  bool _above = false;
  double _dy = 6;
  double _dx = 0;

  /// 판 안에서 펼쳐 둔 시간 목록(없으면 null).
  _TimeSide? _timeOpen;

  /// 판 크기 — 폭, 달력이 가장 길 때(6주)의 높이와 시간 칸 두 줄의 높이(자리를 잴 때 쓴다).
  static const _width = 296.0;
  static const _calendarMaxHeight = _RangeCalendar.maxHeight;
  static const _timeSectionHeight = 1 + _TimeBoxes.height;
  static const _popupMaxHeight = _calendarMaxHeight + _timeSectionHeight;

  /// 판과 칸 사이 · 판과 화면 끝 사이.
  static const _gap = 6.0;
  static const _margin = 8.0;

  bool get isOpen => _overlay.isShowing;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _focus.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(DateTimeRangeField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 꺼지면(저장하는 중 등) 펼친 판도 닫는다.
    if (!widget.enabled && _overlay.isShowing) {
      WidgetsBinding.instance.addPostFrameCallback((_) => hidePopup());
    }
  }

  /// 창 크기가 바뀌거나 화상 키보드가 오르내리면 칸이 움직일 수 있다 — 그 프레임이 그려진 뒤 판 자리를 다시 정한다.
  @override
  void didChangeMetrics() {
    if (!_overlay.isShowing) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _overlay.isShowing) setState(_place);
    });
  }

  /// 펼친 판(과 시간 목록)을 닫았으면 true — 편집기의 뒤로 가기가 편집기보다 판을 먼저 닫게.
  bool hidePopup() {
    if (!_overlay.isShowing) return false;
    _overlay.hide();
    _timeOpen = null;
    if (mounted) setState(() {});
    return true;
  }

  /// 칸 아래에 다 들어가면 아래, 아니면 위에 다 들어가면 위로 펼친다. 둘 다 모자라면(창이 낮을 때) 넓은 쪽으로 펴되 화면
  /// 끝을 넘지 않게 칸 쪽으로 밀어 넣는다(칸을 조금 덮는다). 가로는 칸 왼쪽 끝에 맞추고 오른쪽 끝을 넘지 않게. 기준은 가장
  /// 가까운 Overlay(PC 할 일 패널 안 화면이면 패널)다.
  void _place() {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize || !box.attached) return;
    final origin = box.localToGlobal(Offset.zero);
    // 창 — 루트 Overlay의 자리(PC 할 일 패널은 MediaQuery를 패널 크기로 바꿔 두어 그 크기는 창이 아니다).
    Rect? rectOf(OverlayState? overlay) {
      final o = overlay?.context.findRenderObject();
      return o is RenderBox && o.hasSize && o.attached
          ? o.localToGlobal(Offset.zero) & o.size
          : null;
    }

    final screen =
        rectOf(Overlay.maybeOf(context, rootOverlay: true)) ??
        Offset.zero & MediaQuery.sizeOf(context);
    final nearest = rectOf(Overlay.maybeOf(context));
    final area = nearest == null ? screen : screen.intersect(nearest);
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    final bottom = math.min(area.bottom, screen.bottom - keyboard);
    final below = bottom - origin.dy - box.size.height - _gap - _margin;
    final above = origin.dy - area.top - _gap - _margin;
    const h = _popupMaxHeight;
    if (below >= h) {
      _above = false;
      _dy = _gap;
    } else if (above >= h) {
      _above = true;
      _dy = -_gap;
    } else if (below >= above) {
      _above = false;
      _dy = _gap - (h - below);
    } else {
      _above = true;
      _dy = -_gap + (h - above);
    }
    final minLeft = area.left + _margin;
    final maxLeft = math.max(minLeft, area.right - _width - _margin);
    _dx = origin.dx.clamp(minLeft, maxLeft) - origin.dx;
  }

  void _toggle() {
    if (hidePopup()) return;
    _focus.requestFocus();
    setState(_place);
    _overlay.show();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.escape ||
        !_overlay.isShowing) {
      return KeyEventResult.ignored;
    }
    if (_timeOpen != null) {
      setState(() => _timeOpen = null);
    } else {
      hidePopup();
    }
    return KeyEventResult.handled;
  }

  void _pickDay(DateTime day) =>
      widget.onChanged(widget.value.pick(day, widget.defaultMinutes));

  void _pickTime(_TimeSide side, int? minutes) {
    final v = widget.value;
    setState(() => _timeOpen = null);
    widget.onChanged(
      DateTimeRangeSelection(
        start: v.start,
        end: v.end,
        startMinutes: side == _TimeSide.start ? minutes : v.startMinutes,
        endMinutes: side == _TimeSide.end ? minutes : v.endMinutes,
      ),
    );
  }

  Key _key(String suffix) => ValueKey('${widget.keyPrefix}-$suffix');

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onKey,
      child: OverlayPortal(
        controller: _overlay,
        overlayLocation: OverlayChildLocation.rootOverlay,
        overlayChildBuilder: _buildPopupLayer,
        child: CompositedTransformTarget(
          link: _link,
          child: _buildField(context),
        ),
      ),
    );
  }

  /// 칸 — 옅은 테두리 상자(펼친 동안은 강조)에 기간 글자 · ✕ · ▾.
  Widget _buildField(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hint = theme.hintColor;
    final v = widget.value;
    final open = _overlay.isShowing;
    final border = widget.borderColor ?? scheme.outlineVariant;
    return Semantics(
      button: true,
      expanded: open,
      child: InkWell(
        key: _key('period-field'),
        focusNode: _focus,
        borderRadius: BorderRadius.circular(widget.radius),
        onTap: widget.enabled ? _toggle : null,
        child: Container(
          height: widget.height,
          padding: const EdgeInsets.only(left: 12, right: 6),
          decoration: BoxDecoration(
            border: Border.all(
              color: !widget.enabled
                  ? border.withValues(alpha: 0.6)
                  : open
                  ? scheme.primary
                  : border,
              width: open ? 1.5 : 1,
            ),
            borderRadius: BorderRadius.circular(widget.radius),
          ),
          child: Row(
            children: [
              Expanded(
                child: v.isEmpty
                    ? Text(
                        widget.placeholder,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: hint,
                        ),
                      )
                    : _RangeText(
                        start: v.start == null
                            ? null
                            : widget.formatPoint(v.start!, v.startMinutes),
                        end: v.end == null
                            ? null
                            : widget.formatPoint(v.end!, v.endMinutes),
                        color: widget.enabled
                            ? scheme.onSurface
                            : theme.disabledColor,
                      ),
              ),
              if (!v.isEmpty && widget.enabled)
                IconButton(
                  key: _key('period-clear'),
                  icon: const Icon(Icons.close, size: 16),
                  tooltip: '기간 지우기',
                  color: hint,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 32,
                    height: 32,
                  ),
                  style: IconButton.styleFrom(
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: () =>
                      widget.onChanged(const DateTimeRangeSelection()),
                ),
              Icon(
                open ? Icons.arrow_drop_up : Icons.arrow_drop_down,
                size: 20,
                color: widget.enabled ? hint : theme.disabledColor,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 창 전체를 덮는 투명한 막(누르면 닫힘 — 그 누름은 아래로 가지 않는다)과 칸에 붙어 따라다니는 판.
  Widget _buildPopupLayer(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            key: _key('period-barrier'),
            behavior: HitTestBehavior.opaque,
            onTap: hidePopup,
          ),
        ),
        CompositedTransformFollower(
          link: _link,
          showWhenUnlinked: false,
          targetAnchor: _above ? Alignment.topLeft : Alignment.bottomLeft,
          followerAnchor: _above ? Alignment.bottomLeft : Alignment.topLeft,
          offset: Offset(_dx, _dy),
          child: Align(
            alignment: _above ? Alignment.bottomLeft : Alignment.topLeft,
            child: _buildPopup(context),
          ),
        ),
      ],
    );
  }

  Widget _buildPopup(BuildContext context) {
    final theme = Theme.of(context);
    final v = widget.value;
    final pickingStart = v.start == null || v.end != null;
    final open = _timeOpen;
    return Material(
      key: _key('period-popup'),
      elevation: 8,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      color: theme.colorScheme.surfaceContainerHigh,
      child: SizedBox(
        width: _width,
        child: Stack(
          children: [
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _RangeCalendar(
                  keyPrefix: widget.keyPrefix,
                  start: v.start,
                  end: v.end,
                  caption: pickingStart ? '시작일을 선택하세요' : '종료일을 선택하세요',
                  onPicked: _pickDay,
                ),
                Divider(height: 1, color: theme.dividerColor),
                _TimeBoxes(
                  keyPrefix: widget.keyPrefix,
                  startMinutes: v.startMinutes,
                  endMinutes: v.endMinutes,
                  startEnabled: v.start != null,
                  endEnabled: v.end != null,
                  open: open,
                  formatClock: widget.formatClock,
                  onTap: (side) => setState(
                    () => _timeOpen = _timeOpen == side ? null : side,
                  ),
                ),
              ],
            ),
            // 목록이 열려 있으면 판 안의 다른 곳을 눌러도 목록만 닫는다.
            if (open != null)
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => setState(() => _timeOpen = null),
                ),
              ),
            // 시간 목록은 그 칸 바로 위로, 달력을 덮으며 펼친다(판 크기가 바뀌지 않아 화면 밖으로 안 나간다).
            if (open != null)
              Positioned(
                left: 12,
                right: 12,
                bottom:
                    (open == _TimeSide.start
                        ? _TimeBoxes.startBoxBottom
                        : _TimeBoxes.endBoxBottom) +
                    4,
                child: _TimeList(
                  key: _key('time-list'),
                  keyPrefix: widget.keyPrefix,
                  minutes: open == _TimeSide.start
                      ? v.startMinutes
                      : v.endMinutes,
                  formatClock: widget.formatClock,
                  onPicked: (m) => _pickTime(open, m),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 칸 안의 기간 글자 — 한 줄(`시작 ~ 종료`)에 들어가면 한 줄, 좁으면 `~` 뒤에서 두 줄로 나눈다(날짜가 잘리지 않게).
/// 한쪽만 있으면 `2026/10/13 ~` · `~ 2026/10/14`.
class _RangeText extends StatelessWidget {
  final String? start;
  final String? end;
  final Color color;
  const _RangeText({
    required this.start,
    required this.end,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(
      context,
    ).textTheme.bodyMedium?.copyWith(color: color);
    final first = start == null ? '~' : '$start ~';
    final second = end;
    final one = second == null ? first : '$first $second';
    Text line(String text, [TextStyle? s]) => Text(
      text,
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.fade,
      style: s ?? style,
    );
    if (second == null) return line(one);
    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: TextSpan(
            text: one,
            style: DefaultTextStyle.of(context).style.merge(style),
          ),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
          maxLines: 1,
        )..layout();
        final fits = painter.width <= constraints.maxWidth;
        painter.dispose();
        if (fits) return line(one);
        final tight = style?.copyWith(height: 1.25);
        return Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [line(first, tight), line(second, tight)],
        );
      },
    );
  }
}

const _weekdayHeaders = ['일', '월', '화', '수', '목', '금', '토'];

/// 기간 달력 — 예약 메시지 달력과 같은 모양(`‹ 2026년 10월 ›`, 일~토 머리(일 빨강 · 토 파랑), 높이 36의 칸, 오늘은 옅은
/// 테두리 원)에 위로 지금 고를 쪽 안내(`시작일을 선택하세요`/`종료일을 선택하세요`). 시작일·종료일은 채운 원, 그 사이는 옅은 띠.
/// 앞뒤 달의 자리는 비운다.
class _RangeCalendar extends StatefulWidget {
  /// 6주 달의 높이 — 위 여백 8 · 안내 20 · 달 머리 40 · 4 · 요일 16 · 4 · 6×36 · 아래 여백 8.
  static const maxHeight = 8 + 20 + 40 + 4 + 16 + 4 + 6 * 36 + 8.0;

  final String keyPrefix;
  final DateTime? start;
  final DateTime? end;
  final String caption;
  final ValueChanged<DateTime> onPicked;
  const _RangeCalendar({
    required this.keyPrefix,
    required this.start,
    required this.end,
    required this.caption,
    required this.onPicked,
  });

  @override
  State<_RangeCalendar> createState() => _RangeCalendarState();
}

class _RangeCalendarState extends State<_RangeCalendar> {
  late DateTime _month = () {
    final anchor = widget.start ?? widget.end ?? DateTime.now();
    return DateTime(anchor.year, anchor.month);
  }();

  void _move(int months) =>
      setState(() => _month = DateTime(_month.year, _month.month + months));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hint = theme.hintColor;
    final today = _dayOf(DateTime.now());
    final start = widget.start == null ? null : _dayOf(widget.start!);
    final end = widget.end == null ? null : _dayOf(widget.end!);
    final hasRange = start != null && end != null && end.isAfter(start);
    final band = scheme.primary.withValues(alpha: 0.14);
    final leading = _month.weekday % 7;
    final firstCell = DateTime(_month.year, _month.month, 1 - leading);
    final daysInMonth = DateTime(_month.year, _month.month + 1, 0).day;
    final rows = ((leading + daysInMonth) / 7).ceil();

    Widget arrow(String key, IconData icon, String tooltip, int months) =>
        SizedBox(
          width: 40,
          height: 40,
          child: IconButton(
            key: ValueKey('${widget.keyPrefix}-period-$key'),
            icon: Icon(icon, size: 20),
            tooltip: tooltip,
            visualDensity: VisualDensity.compact,
            onPressed: () => _move(months),
          ),
        );

    Widget cell(DateTime day) {
      final isStart = day == start;
      final isEnd = day == end;
      final endpoint = isStart || isEnd;
      final inRange = hasRange && day.isAfter(start) && day.isBefore(end);
      final bandLeft = hasRange && (inRange || isEnd);
      final bandRight = hasRange && (inRange || isStart);
      final isToday = day == today;
      return InkWell(
        key: ValueKey(
          '${widget.keyPrefix}-period-day-${day.year}-${day.month}-${day.day}',
        ),
        onTap: () => widget.onPicked(day),
        borderRadius: BorderRadius.circular(999),
        child: SizedBox(
          height: 36,
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (bandLeft || bandRight)
                Positioned(
                  left: 0,
                  right: 0,
                  top: 2,
                  bottom: 2,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: ColoredBox(
                          color: bandLeft ? band : Colors.transparent,
                        ),
                      ),
                      Expanded(
                        child: ColoredBox(
                          color: bandRight ? band : Colors.transparent,
                        ),
                      ),
                    ],
                  ),
                ),
              Container(
                width: 32,
                height: 32,
                alignment: Alignment.center,
                decoration: endpoint
                    ? BoxDecoration(
                        shape: BoxShape.circle,
                        color: scheme.primary,
                      )
                    : isToday
                    ? BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: scheme.primary.withValues(alpha: 0.5),
                        ),
                      )
                    : null,
                child: Text(
                  '${day.day}',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: endpoint || isToday
                        ? FontWeight.w700
                        : FontWeight.normal,
                    color: endpoint ? scheme.onPrimary : null,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 20,
            child: Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Text(
                widget.caption,
                key: ValueKey('${widget.keyPrefix}-period-caption'),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: hint,
                ),
              ),
            ),
          ),
          SizedBox(
            height: 40,
            child: Row(
              children: [
                arrow('prev', Icons.chevron_left, '이전 달', -1),
                Expanded(
                  child: Text(
                    '${_month.year}년 ${_month.month}월',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                ),
                arrow('next', Icons.chevron_right, '다음 달', 1),
              ],
            ),
          ),
          const SizedBox(height: 4),
          SizedBox(
            height: 16,
            child: Row(
              children: [
                for (final (i, label) in _weekdayHeaders.indexed)
                  Expanded(
                    child: Center(
                      child: Text(
                        label,
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.2,
                          color: i == 0
                              ? Colors.red.shade400
                              : i == 6
                              ? Colors.blue.shade400
                              : hint,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          for (var row = 0; row < rows; row++)
            Row(
              children: [
                for (var col = 0; col < 7; col++)
                  Expanded(
                    child: Builder(
                      builder: (context) {
                        final day = DateTime(
                          firstCell.year,
                          firstCell.month,
                          firstCell.day + row * 7 + col,
                        );
                        if (day.month != _month.month) {
                          return const SizedBox(height: 36);
                        }
                        return cell(day);
                      },
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

/// 달력 밑의 `시작 시간` 칸과 바로 밑의 `종료 시간` 칸 — 작은 이름표 아래 높이 36의 테두리 상자(시계 아이콘 · 지금 값
/// `오후 6:00`/`시간 없음` · ▾, 글자 14). 그 날짜가 없으면 꺼진다. 누르면 [_TimeList]가 그 칸 바로 위로 펼쳐진다(판 안 —
/// 따로 띄우는 메뉴의 항목을 누르는 것은 판 밖을 누른 것으로 잡혀 판이 먼저 닫혀 버린다).
class _TimeBoxes extends StatelessWidget {
  static const _labelHeight = 24.0;
  static const _boxHeight = 36.0;
  static const _rowGap = 6.0;
  static const _top = 8.0;
  static const _bottom = 12.0;

  /// 두 줄 전체 높이와, 판 아래 끝에서 각 칸 위 끝까지의 거리(목록을 그 위로 편다).
  static const height =
      _top + 2 * (_labelHeight + _boxHeight) + _rowGap + _bottom;
  static const endBoxBottom = _bottom + _boxHeight;
  static const startBoxBottom =
      endBoxBottom + _labelHeight + _rowGap + _boxHeight;

  final String keyPrefix;
  final int? startMinutes;
  final int? endMinutes;
  final bool startEnabled;
  final bool endEnabled;
  final _TimeSide? open;
  final String Function(int minutes) formatClock;
  final ValueChanged<_TimeSide> onTap;
  const _TimeBoxes({
    required this.keyPrefix,
    required this.startMinutes,
    required this.endMinutes,
    required this.startEnabled,
    required this.endEnabled,
    required this.open,
    required this.formatClock,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    List<Widget> one(
      _TimeSide side,
      String id,
      String label,
      int? m,
      bool enabled,
    ) {
      final active = open == side;
      final color = !enabled
          ? theme.disabledColor
          : active
          ? scheme.primary
          : scheme.outline;
      // 강조 테두리(2px)가 되어도 안의 글자가 움직이지 않게 그만큼 안쪽 여백을 줄인다.
      final width = active ? 2.0 : 1.0;
      return [
        SizedBox(
          height: _labelHeight,
          child: Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: theme.hintColor,
              ),
            ),
          ),
        ),
        Semantics(
          button: true,
          expanded: active,
          label: label,
          child: InkWell(
            key: ValueKey('$keyPrefix-time-$id'),
            borderRadius: BorderRadius.circular(4),
            onTap: enabled ? () => onTap(side) : null,
            child: Container(
              height: _boxHeight,
              padding: EdgeInsets.only(left: 13 - width, right: 7 - width),
              decoration: BoxDecoration(
                border: Border.all(color: color, width: width),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.schedule,
                    size: 16,
                    color: enabled ? theme.hintColor : color,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      m == null ? '시간 없음' : formatClock(m),
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.fade,
                      style: TextStyle(
                        fontSize: _TimeList.fontSize,
                        color: !enabled
                            ? theme.disabledColor
                            : m == null
                            ? theme.hintColor
                            : scheme.onSurface,
                      ),
                    ),
                  ),
                  Icon(
                    active ? Icons.arrow_drop_up : Icons.arrow_drop_down,
                    size: 20,
                    color: enabled ? theme.hintColor : theme.disabledColor,
                  ),
                ],
              ),
            ),
          ),
        ),
      ];
    }

    return SizedBox(
      height: height,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, _top, 12, _bottom),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ...one(
              _TimeSide.start,
              'start',
              '시작 시간',
              startMinutes,
              startEnabled,
            ),
            const SizedBox(height: _rowGap),
            ...one(_TimeSide.end, 'end', '종료 시간', endMinutes, endEnabled),
          ],
        ),
      ),
    );
  }
}

/// 시간 목록 — 첫 줄 `시간 없음`, 그다음 15분 단위(오전 12:00 … 오후 11:45). 단위 밖의 시각(다른 기기에서 정한 17:40
/// 등)이면 그 시각도 제자리에 넣어 체크가 보이게 한다. 지금 값에 체크하고, 그 값이 둘째 줄쯤 오게 스크롤해 연다.
class _TimeList extends StatefulWidget {
  static const height = 216.0;
  static const fontSize = 14.0;
  static const _rowHeight = 36.0;
  static const _padding = 4.0;

  final String keyPrefix;
  final int? minutes;
  final String Function(int minutes) formatClock;
  final ValueChanged<int?> onPicked;
  const _TimeList({
    super.key,
    required this.keyPrefix,
    required this.minutes,
    required this.formatClock,
    required this.onPicked,
  });

  @override
  State<_TimeList> createState() => _TimeListState();
}

class _TimeListState extends State<_TimeList> {
  late final List<int?> _items = () {
    final current = widget.minutes;
    return <int?>[
      null,
      ...[
        for (var m = 0; m < 24 * 60; m += dateTimeRangeSlotMinutes) m,
        if (current != null && current % dateTimeRangeSlotMinutes != 0) current,
      ]..sort(),
    ];
  }();

  late final _scroll = ScrollController(
    initialScrollOffset: () {
      final index = math.max(0, _items.indexOf(widget.minutes));
      final max =
          _items.length * _TimeList._rowHeight +
          2 * _TimeList._padding -
          _TimeList.height;
      return ((index - 1) * _TimeList._rowHeight).clamp(0.0, max);
    }(),
  );

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      elevation: 4,
      color: scheme.surface,
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        height: _TimeList.height,
        child: ListView.builder(
          controller: _scroll,
          padding: const EdgeInsets.symmetric(vertical: _TimeList._padding),
          itemExtent: _TimeList._rowHeight,
          itemCount: _items.length,
          itemBuilder: (context, i) {
            final m = _items[i];
            final selected = m == widget.minutes;
            return InkWell(
              key: ValueKey('${widget.keyPrefix}-time-option-${m ?? 'none'}'),
              onTap: () => widget.onPicked(m),
              child: Container(
                color: selected ? scheme.primaryContainer : null,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        m == null ? '시간 없음' : widget.formatClock(m),
                        maxLines: 1,
                        style: TextStyle(
                          fontSize: _TimeList.fontSize,
                          fontWeight: selected
                              ? FontWeight.w700
                              : FontWeight.normal,
                          color: selected
                              ? scheme.onPrimaryContainer
                              : m == null
                              ? theme.hintColor
                              : null,
                        ),
                      ),
                    ),
                    if (selected)
                      Icon(
                        Icons.check,
                        size: 16,
                        color: scheme.onPrimaryContainer,
                      ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
