import 'package:flutter/material.dart';

import '../../models/groupware.dart';
import '../../models/groupware_resources.dart';
import '../../models/team.dart' show AccountRole;
import '../../services/api_client.dart' show ApiException;
import '../../services/groupware_api.dart';
import '../../services/session.dart';
import '../../widgets/app_toast.dart';
import 'groupware_screen.dart' show GroupwareChanges, GroupwareSectionHeader;
import 'resource_admin_extras.dart';
import 'resource_booking_extras.dart';
import '../../l10n/tr.dart';

/// 그룹웨어 "예약" 탭 — 회의실·장비·차량을 날마다 시간표로 보고 빈 시간을 눌러 잡는다(서버 groupwareResources.js). 캘린더 일정에 붙인
/// 예약도 같은 시간표에 보인다(일정 편집 창의 "회의실·자원"). 겹치는 예약은 서버가 막는다(409 — 누구 예약인지 알려 줌).
///
/// 후속(서버 resourcePolicy.js): 자원마다 예약 규칙(예약할 수 있는 사람·요일·시간대·한 번에 쓸 수 있는 시간·관리자 승인)이 있어 예약 창이
/// 규칙을 보여 주고 못 잡는 자원은 막는다. 승인이 필요한 자원의 예약은 "승인 대기"(빗금·옅게)로 그 시간을 막아 두고, 승인할 사람에게는
/// 맨 위에 "승인 기다리는 예약"이 보인다(resource_booking_extras.dart). 매주·2주마다 반복 예약(겹치는 날 빼고 잡기), 참석 인원에 맞는
/// 회의실 추천, 반복 예약 취소(이 회차만 / 이후 모두).
///
/// 관리 탭의 자원 관리([ResourcesAdminSection])도 이 파일에 있다(규칙 편집·태블릿 화면·통계·알림은 resource_admin_extras.dart).

/// 시간표가 보여 주는 시간(07:00~22:00) — 그 밖의 예약은 끝에 붙여 그린다.
const _dayStartHour = 7;
const _dayEndHour = 22;

/// 기기 시각 "HH:MM".
String clockText(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// 예약 시간 글 — 같은 날이면 "10/20 10:00~11:00", 아니면 "10/20 10:00~10/21 09:00".
String bookingRangeText(ResourceBooking b) {
  final s = b.startTime;
  final e = b.endTime;
  final sameDay = s.year == e.year && s.month == e.month && s.day == e.day;
  final endText = sameDay
      ? clockText(e)
      : '${e.month}/${e.day} ${clockText(e)}';
  return '${s.month}/${s.day} ${clockText(s)}~$endText';
}

/// 예약 결과 알림 글 — 잡은 회차 수, 겹쳐서 뺀 날(반복 예약에서 "겹치는 날 빼고 잡기"), 승인 대기 안내.
String bookingResultText(SeriesBookingResult made) {
  final first = made.first;
  String dayOf(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.month}/${d.day}';
  }

  return [
    made.created > 1
        ? tr('{name}을(를) {n}회 예약했습니다.', {
            'name': first.resourceName,
            'n': made.created,
          })
        : tr('{made.resourceName}을(를) 예약했습니다.', {
            'made.resourceName': first.resourceName,
          }),
    if (made.skipped.isNotEmpty)
      tr('겹쳐서 뺀 날: {dates}', {
        'dates': made.skipped.map((s) => dayOf(s.start)).join(', '),
      }),
    if (first.pending) tr('승인을 기다립니다 — 승인되면 알려 드립니다.'),
  ].join(' ');
}

final _weekdays = [
  tr('월'),
  tr('화'),
  tr('수'),
  tr('목'),
  tr('금'),
  tr('토'),
  tr('일'),
];

class ResourceTab extends StatefulWidget {
  final GroupwareApi api;
  final GroupwareContext ctx;
  final GroupwareChanges changes;
  final Session session;
  const ResourceTab({
    super.key,
    required this.api,
    required this.ctx,
    required this.changes,
    required this.session,
  });

  @override
  State<ResourceTab> createState() => _ResourceTabState();
}

class _ResourceTabState extends State<ResourceTab> {
  late DateTime _day = _today();
  List<GroupwareResource>? _resources;
  List<ResourceBooking> _bookings = const [];
  List<ResourceBooking> _mine = const [];

  /// 내가 승인할 예약(서버가 거른다 — 승인할 사람·그룹웨어 관리자가 아니면 빈 목록).
  List<ResourceBooking> _pending = const [];
  String? _error;

  bool get _isGuest => widget.session.accountRole == AccountRole.guest;

  static DateTime _today() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  @override
  void initState() {
    super.initState();
    widget.changes.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    widget.changes.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final from = _day.millisecondsSinceEpoch;
    final to = DateTime(
      _day.year,
      _day.month,
      _day.day + 1,
    ).millisecondsSinceEpoch;
    _loadPending();
    try {
      final results = await Future.wait([
        widget.api.resources(),
        widget.api.bookings(from, to),
        widget.api.myBookings(),
      ]);
      if (!mounted) return;
      setState(() {
        _resources = [
          for (final r in results[0] as List<GroupwareResource>)
            if (r.enabled) r,
        ];
        _bookings = results[1] as List<ResourceBooking>;
        _mine = results[2] as List<ResourceBooking>;
        _error = null;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _error = e is ApiException ? trServer(e.message) : '$e');
      }
    }
  }

  /// 승인 기다리는 예약 — 따로 받는다(예전 서버·권한 없음이면 그냥 비워 둔다).
  Future<void> _loadPending() async {
    try {
      final pending = await widget.api.pendingBookings();
      if (mounted) setState(() => _pending = pending);
    } catch (_) {
      if (mounted && _pending.isNotEmpty) setState(() => _pending = const []);
    }
  }

  void _shift(int days) {
    setState(() => _day = DateTime(_day.year, _day.month, _day.day + days));
    _load();
  }

  Future<void> _pickDay() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _day,
      firstDate: _today().subtract(const Duration(days: 365)),
      lastDate: _today().add(const Duration(days: 180)),
    );
    if (picked == null) return;
    setState(() => _day = picked);
    _load();
  }

  Future<void> _book({GroupwareResource? resource, DateTime? start}) async {
    final resources = _resources ?? const [];
    final bookable = [
      for (final r in resources)
        if (r.canBook) r,
    ];
    if (bookable.isEmpty) {
      showAppToast(context, tr('내가 예약할 수 있는 자원이 없습니다 — 정해진 사람만 예약할 수 있습니다.'));
      return;
    }
    final made = await showBookingDialog(
      context,
      api: widget.api,
      resources: resources,
      resource: resource ?? bookable.first,
      start: start ?? _defaultStart(),
    );
    if (made == null || !mounted) return;
    showAppToast(
      context,
      bookingResultText(made),
      duration: made.skipped.isNotEmpty || made.first.pending
          ? const Duration(seconds: 4)
          : const Duration(milliseconds: 2000),
    );
    _load();
  }

  DateTime _defaultStart() {
    final now = DateTime.now();
    if (_day == _today()) {
      final minutes = (now.hour * 60 + now.minute + 29) ~/ 30 * 30;
      return DateTime(
        _day.year,
        _day.month,
        _day.day,
      ).add(Duration(minutes: minutes));
    }
    return DateTime(_day.year, _day.month, _day.day, 10);
  }

  /// 예약 자세히 — 취소(반복 예약이면 "이 회차만" / "이 회차와 이후 모두").
  Future<void> _showBooking(ResourceBooking b) async {
    final hintStyle = TextStyle(
      fontSize: 12,
      color: Theme.of(context).hintColor,
    );
    final series = b.seriesId != null;
    final action = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(b.title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${b.resourceName} · ${bookingRangeText(b)}'),
            const SizedBox(height: 4),
            Text(tr('잡은 사람: {b.userName}', {'b.userName': b.userName})),
            if (b.pending)
              Padding(
                key: const ValueKey('booking-detail-pending'),
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  tr('승인 대기 — 승인할 사람이 승인하면 확정됩니다. 그동안 이 시간은 다른 사람이 잡을 수 없습니다.'),
                  style: hintStyle,
                ),
              ),
            if (series)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(tr('반복 예약의 한 회차입니다.'), style: hintStyle),
              ),
            if (b.fromEvent)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  tr(
                    '캘린더 일정에 붙은 예약입니다 — 시간을 바꾸려면 그 일정을 고치세요. 취소하면 일정은 남고 회의실만 빠집니다.',
                  ),
                  style: hintStyle,
                ),
              ),
          ],
        ),
        actions: [
          if (b.canCancel && series) ...[
            TextButton(
              key: const ValueKey('booking-cancel'),
              onPressed: () => Navigator.of(dialogContext).pop('one'),
              child: Text(tr('이 회차만 취소')),
            ),
            TextButton(
              key: const ValueKey('booking-cancel-series'),
              onPressed: () => Navigator.of(dialogContext).pop('series'),
              child: Text(tr('이 회차와 이후 모두 취소')),
            ),
          ] else if (b.canCancel)
            TextButton(
              key: const ValueKey('booking-cancel'),
              onPressed: () => Navigator.of(dialogContext).pop('one'),
              child: Text(b.mine ? tr('예약 취소') : tr('관리자 취소')),
            ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(tr('닫기')),
          ),
        ],
      ),
    );
    if (action == null || !mounted) return;
    try {
      await widget.api.cancelBooking(b.id, series: action == 'series');
      if (mounted) {
        showAppToast(
          context,
          action == 'series' ? tr('이 회차와 이후 예약을 취소했습니다.') : tr('예약을 취소했습니다.'),
        );
      }
      _load();
    } catch (e) {
      if (mounted) {
        showAppToast(
          context,
          e is ApiException ? trServer(e.message) : tr('취소하지 못했습니다.'),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final resources = _resources;
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    if (resources == null) {
      return Center(
        child: _error != null
            ? Padding(padding: const EdgeInsets.all(24), child: Text(_error!))
            : const CircularProgressIndicator(),
      );
    }
    final isToday = _day == _today();
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 16, 0),
            child: Row(
              children: [
                IconButton(
                  tooltip: tr('전날'),
                  icon: const Icon(Icons.chevron_left),
                  onPressed: () => _shift(-1),
                ),
                Flexible(
                  child: TextButton(
                    key: const ValueKey('resource-day'),
                    onPressed: _pickDay,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        tr('{_day.month}월 {_day.day}일 ({p0})', {
                          '_day.month': _day.month,
                          '_day.day': _day.day,
                          'p0': _weekdays[_day.weekday - 1],
                        }),
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: tr('다음 날'),
                  icon: const Icon(Icons.chevron_right),
                  onPressed: () => _shift(1),
                ),
                if (!isToday)
                  TextButton(
                    onPressed: () {
                      setState(() => _day = _today());
                      _load();
                    },
                    child: Text(tr('오늘')),
                  ),
                const Spacer(),
                // 좁은 화면(폰)에서는 글 없이 + 단추만.
                if (!_isGuest && resources.isNotEmpty)
                  MediaQuery.sizeOf(context).width < 480
                      ? IconButton.filled(
                          key: const ValueKey('resource-book'),
                          tooltip: tr('예약하기'),
                          onPressed: () => _book(),
                          icon: const Icon(Icons.add),
                        )
                      : FilledButton.icon(
                          key: const ValueKey('resource-book'),
                          onPressed: () => _book(),
                          icon: const Icon(Icons.add, size: 18),
                          label: Text(tr('예약하기')),
                        ),
              ],
            ),
          ),
          PendingBookingsSection(
            api: widget.api,
            pending: _pending,
            onChanged: _load,
          ),
          if (resources.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                widget.ctx.isManager
                    ? tr('아직 자원이 없습니다. 관리 탭 → 회의실·자원에서 회의실·장비·차량을 더하세요.')
                    : tr('아직 예약할 수 있는 회의실·자원이 없습니다.'),
                style: TextStyle(color: hint),
                textAlign: TextAlign.center,
              ),
            ),
          for (final r in resources)
            _ResourceRow(
              resource: r,
              day: _day,
              bookings: [
                for (final b in _bookings)
                  if (b.resourceId == r.id) b,
              ],
              onTapFree: _isGuest || !r.canBook
                  ? null
                  : (start) => _book(resource: r, start: start),
              onTapBooking: _showBooking,
            ),
          if (_isGuest)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                tr('준회원은 현황만 볼 수 있습니다.'),
                style: TextStyle(fontSize: 12, color: hint),
              ),
            ),
          GroupwareSectionHeader(tr('내 예약')),
          if (_mine.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                tr('앞으로 잡아 둔 예약이 없습니다.'),
                style: TextStyle(color: hint),
              ),
            ),
          for (final b in _mine)
            ListTile(
              key: ValueKey('my-booking-${b.id}'),
              dense: true,
              leading: Icon(_kindIcon(b.resourceKind)),
              title: Text('${b.resourceName} · ${b.title}'),
              subtitle: Text(
                '${bookingRangeText(b)}${b.fromEvent ? tr(' · 캘린더 일정') : ''}',
              ),
              trailing: b.pending || b.seriesId != null
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (b.seriesId != null)
                          Tooltip(
                            message: tr('반복 예약'),
                            child: Icon(
                              Icons.repeat,
                              key: ValueKey('my-booking-series-${b.id}'),
                              size: 18,
                              color: hint,
                            ),
                          ),
                        if (b.pending) ...[
                          const SizedBox(width: 6),
                          _PendingBadge(
                            key: ValueKey('my-booking-pending-${b.id}'),
                          ),
                        ],
                      ],
                    )
                  : null,
              onTap: () => _showBooking(b),
            ),
        ],
      ),
    );
  }
}

IconData _kindIcon(String kind) => switch (kind) {
  'equipment' => Icons.devices_other_outlined,
  'vehicle' => Icons.directions_car_outlined,
  _ => Icons.meeting_room_outlined,
};

/// "승인 대기" 작은 표시.
class _PendingBadge extends StatelessWidget {
  const _PendingBadge({super.key});

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.tertiary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(tr('승인 대기'), style: TextStyle(fontSize: 11, color: color)),
    );
  }
}

/// 승인 대기 예약 막대의 빗금(옅게 칠한 위에 비스듬한 줄).
class _StripePainter extends CustomPainter {
  final Color color;
  const _StripePainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRRect(
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(4)),
    );
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2;
    for (var x = -size.height; x < size.width; x += 7) {
      canvas.drawLine(
        Offset(x, size.height),
        Offset(x + size.height, 0),
        paint,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_StripePainter old) => old.color != color;
}

/// 자원 하나의 하루 시간표 — 07:00~22:00 막대 위에 예약을 칠하고, 빈 곳을 누르면 그 30분부터 잡는다. 승인 대기 예약은 빗금·옅게,
/// 반복 예약은 반복 표시. 이름 아래 한 줄에 예약 규칙(정해진 사람만·승인 필요·요일·시간대·한 번에 쓸 수 있는 시간).
class _ResourceRow extends StatelessWidget {
  final GroupwareResource resource;
  final DateTime day;
  final List<ResourceBooking> bookings;
  final ValueChanged<DateTime>? onTapFree;
  final ValueChanged<ResourceBooking> onTapBooking;
  const _ResourceRow({
    required this.resource,
    required this.day,
    required this.bookings,
    required this.onTapFree,
    required this.onTapBooking,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final dayStart = DateTime(day.year, day.month, day.day, _dayStartHour);
    final dayEnd = DateTime(day.year, day.month, day.day, _dayEndHour);
    final span = dayEnd.difference(dayStart).inMinutes;
    double frac(DateTime t) =>
        (t.difference(dayStart).inMinutes / span).clamp(0.0, 1.0);
    final rules = [
      if (!resource.canBook) tr('정해진 사람만'),
      if (resource.needsApproval) tr('승인 필요'),
      ...resourceRuleParts(resource),
    ];
    return Padding(
      key: ValueKey('resource-${resource.id}'),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(_kindIcon(resource.kind), size: 18, color: hint),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  resource.name,
                  style: theme.textTheme.titleSmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (resource.detail.isNotEmpty) ...[
                const SizedBox(width: 8),
                Text(
                  resource.detail,
                  style: TextStyle(fontSize: 12, color: hint),
                ),
              ],
              if (!resource.canBook) ...[
                const SizedBox(width: 6),
                Icon(Icons.lock_outline, size: 14, color: hint),
              ],
            ],
          ),
          if (rules.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                rules.join(' · '),
                key: ValueKey('resource-rules-${resource.id}'),
                style: TextStyle(fontSize: 11, color: hint),
              ),
            ),
          const SizedBox(height: 6),
          LayoutBuilder(
            builder: (context, box) {
              final width = box.maxWidth;
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapUp: onTapFree == null
                    ? null
                    : (d) {
                        final minutes =
                            (d.localPosition.dx / width * span).floor() ~/
                            30 *
                            30;
                        onTapFree!(dayStart.add(Duration(minutes: minutes)));
                      },
                child: SizedBox(
                  height: 34,
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surfaceContainerHighest
                                .withValues(alpha: 0.5),
                            borderRadius: BorderRadius.circular(6),
                          ),
                        ),
                      ),
                      // 시각 눈금(2시간마다).
                      for (var h = _dayStartHour + 1; h < _dayEndHour; h++)
                        Positioned(
                          left:
                              width *
                              (h - _dayStartHour) /
                              (_dayEndHour - _dayStartHour),
                          top: 0,
                          bottom: 0,
                          child: Container(
                            width: 1,
                            color: theme.dividerColor.withValues(
                              alpha: h.isEven ? 0.6 : 0.25,
                            ),
                          ),
                        ),
                      for (final b in bookings)
                        if (b.endTime.isAfter(dayStart) &&
                            b.startTime.isBefore(dayEnd))
                          Positioned(
                            key: ValueKey('booking-${b.id}'),
                            left: width * frac(b.startTime),
                            width:
                                (width * (frac(b.endTime) - frac(b.startTime)))
                                    .clamp(4.0, width),
                            top: 2,
                            bottom: 2,
                            child: GestureDetector(
                              onTap: () => onTapBooking(b),
                              child: Tooltip(
                                message: [
                                  '${bookingRangeText(b)} ${b.title} — ${b.userName}',
                                  if (b.pending) tr('승인 대기'),
                                  if (b.seriesId != null) tr('반복 예약'),
                                ].join(' · '),
                                child: _bar(theme, b),
                              ),
                            ),
                          ),
                    ],
                  ),
                ),
              );
            },
          ),
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Row(
              children: [
                for (var h = _dayStartHour; h <= _dayEndHour; h += 3) ...[
                  if (h != _dayStartHour) const Spacer(),
                  Text(
                    tr('{h}시', {'h': h}),
                    style: TextStyle(fontSize: 10, color: hint),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 예약 막대 하나 — 확정은 진하게(내 것은 주 색), 승인 대기는 옅게 + 테두리 + 빗금, 반복이면 앞에 반복 표시.
  Widget _bar(ThemeData theme, ResourceBooking b) {
    final scheme = theme.colorScheme;
    final base = b.mine ? scheme.primary : scheme.secondary;
    final fill = b.pending
        ? base.withValues(alpha: 0.18)
        : (b.mine ? base : base.withValues(alpha: 0.55));
    final textColor = b.pending
        ? scheme.onSurface
        : (b.mine ? scheme.onPrimary : scheme.onSecondary);
    return CustomPaint(
      foregroundPainter: b.pending
          ? _StripePainter(base.withValues(alpha: 0.22))
          : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        alignment: Alignment.centerLeft,
        decoration: BoxDecoration(
          color: fill,
          border: b.pending ? Border.all(color: base, width: 1) : null,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text.rich(
          TextSpan(
            children: [
              if (b.seriesId != null)
                WidgetSpan(
                  alignment: PlaceholderAlignment.middle,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 2),
                    child: Icon(Icons.repeat, size: 11, color: textColor),
                  ),
                ),
              TextSpan(text: '${clockText(b.startTime)} '),
              if (b.pending) TextSpan(text: '${tr('승인 대기')} · '),
              TextSpan(text: b.title),
            ],
          ),
          maxLines: 1,
          overflow: TextOverflow.clip,
          style: TextStyle(fontSize: 11, color: textColor),
        ),
      ),
    );
  }
}

/// 30분 단위 시각 목록(분) — 0:00~24:00.
final _halfHours = [for (var m = 0; m <= 24 * 60; m += 30) m];

/// 반복 회차 고르기(2~26회 — 서버 SERIES_MAX).
final _repeatCounts = [for (var n = 2; n <= 26; n++) n];

/// 예약 창 — 자원·날짜·시작·끝·제목, 반복(매주·2주마다 몇 회, 겹치는 날 빼고), 참석 인원으로 회의실 추천. 잡으면 그 결과(첫 회차·잡힌
/// 회차 수·건너뛴 회차), 그만두면 null. 겹치거나 규칙에 막히면 창 안에 서버 글을 보인다.
Future<SeriesBookingResult?> showBookingDialog(
  BuildContext context, {
  required GroupwareApi api,
  required List<GroupwareResource> resources,
  required GroupwareResource resource,
  required DateTime start,
}) => showDialog<SeriesBookingResult>(
  context: context,
  builder: (_) => _BookingDialog(
    api: api,
    resources: resources,
    resource: resource,
    start: start,
  ),
);

class _BookingDialog extends StatefulWidget {
  final GroupwareApi api;
  final List<GroupwareResource> resources;
  final GroupwareResource resource;
  final DateTime start;
  const _BookingDialog({
    required this.api,
    required this.resources,
    required this.resource,
    required this.start,
  });

  @override
  State<_BookingDialog> createState() => _BookingDialogState();
}

class _BookingDialogState extends State<_BookingDialog> {
  late String _resourceId = widget.resource.id;

  /// 자원 칸을 바꿔 그릴 때마다 올린다(추천을 눌러 고르면 칸의 처음 값이 바뀌어야 해서).
  int _resourceFieldRev = 0;
  late DateTime _startDay = DateTime(
    widget.start.year,
    widget.start.month,
    widget.start.day,
  );
  late DateTime _endDay = _startDay;
  late int _startMinutes =
      widget.start.hour * 60 + widget.start.minute - (widget.start.minute % 30);
  late int _endMinutes = (_startMinutes + 60).clamp(30, 24 * 60);
  final _title = TextEditingController();

  /// 반복 — 0 반복 안 함, 1 매주, 2 2주마다. [_repeatCount]회(첫 회차 포함).
  int _repeatEvery = 0;
  int _repeatCount = 4;
  bool _skipConflicts = false;

  /// 회의실 추천 — 참석 인원, 받은 목록(누르기 전이면 null).
  final _attendees = TextEditingController();
  List<GroupwareResource>? _suggested;
  bool _suggesting = false;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _title.dispose();
    _attendees.dispose();
    super.dispose();
  }

  DateTime get _start => _startDay.add(Duration(minutes: _startMinutes));
  DateTime get _end => _endDay.add(Duration(minutes: _endMinutes));

  GroupwareResource? get _resource {
    for (final r in widget.resources) {
      if (r.id == _resourceId) return r;
    }
    return null;
  }

  Future<void> _pick(bool start) async {
    final base = start ? _startDay : _endDay;
    final picked = await showDatePicker(
      context: context,
      initialDate: base,
      firstDate: DateTime.now().subtract(const Duration(days: 1)),
      lastDate: DateTime.now().add(const Duration(days: 180)),
    );
    if (picked == null) return;
    setState(() {
      if (start) {
        final gap = _endDay.difference(_startDay);
        _startDay = picked;
        _endDay = picked.add(gap);
      } else {
        _endDay = picked.isBefore(_startDay) ? _startDay : picked;
      }
      _error = null;
      _suggested = null;
    });
  }

  Future<void> _suggest() async {
    if (!_end.isAfter(_start)) {
      setState(() => _error = tr('끝 시각은 시작 시각보다 뒤여야 합니다.'));
      return;
    }
    final text = _attendees.text.trim();
    final attendees = text.isEmpty ? 0 : int.tryParse(text);
    if (attendees == null || attendees < 0) {
      setState(() => _error = tr('참석 인원은 숫자로 넣으세요.'));
      return;
    }
    setState(() {
      _suggesting = true;
      _error = null;
    });
    try {
      final list = await widget.api.suggestResources(
        start: _start.millisecondsSinceEpoch,
        end: _end.millisecondsSinceEpoch,
        attendees: attendees,
      );
      if (mounted) setState(() => _suggested = list);
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = e is ApiException
              ? trServer(e.message)
              : tr('추천을 받지 못했습니다.'),
        );
      }
    } finally {
      if (mounted) setState(() => _suggesting = false);
    }
  }

  void _pickSuggested(GroupwareResource s) {
    if (!widget.resources.any((r) => r.id == s.id)) return;
    setState(() {
      _resourceId = s.id;
      _resourceFieldRev += 1;
      _error = null;
    });
  }

  Future<void> _save() async {
    if (!_end.isAfter(_start)) {
      setState(() => _error = tr('끝 시각은 시작 시각보다 뒤여야 합니다.'));
      return;
    }
    if (_resource?.canBook == false) {
      setState(() => _error = tr('이 자원은 정해진 사람만 예약할 수 있습니다.'));
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final title = _title.text.trim().isEmpty ? null : _title.text.trim();
    try {
      final SeriesBookingResult made;
      if (_repeatEvery == 0) {
        final first = await widget.api.book(
          resourceId: _resourceId,
          start: _start.millisecondsSinceEpoch,
          end: _end.millisecondsSinceEpoch,
          title: title,
        );
        made = (
          first: first,
          created: 1,
          skipped: const <({int start, int end, String conflict})>[],
        );
      } else {
        made = await widget.api.bookRepeating(
          resourceId: _resourceId,
          start: _start.millisecondsSinceEpoch,
          end: _end.millisecondsSinceEpoch,
          title: title,
          repeatWeeks: _repeatCount,
          everyWeeks: _repeatEvery,
          skipConflicts: _skipConflicts,
        );
      }
      if (mounted) Navigator.of(context).pop(made);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = e is ApiException ? trServer(e.message) : tr('예약하지 못했습니다.');
        });
      }
    }
  }

  /// 고른 자원의 안내 — 못 잡음(정해진 사람만), 승인 필요, 예약 규칙(요일·시간대·한 번에 쓸 수 있는 시간).
  List<Widget> _resourceInfo(GroupwareResource r) {
    final theme = Theme.of(context);
    final style = TextStyle(fontSize: 12, color: theme.hintColor);
    final rules = resourceRuleParts(r);
    return [
      if (!r.canBook)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            tr('이 자원은 정해진 사람만 예약할 수 있습니다.'),
            key: const ValueKey('booking-cannot'),
            style: TextStyle(fontSize: 12, color: theme.colorScheme.error),
          ),
        ),
      if (r.needsApproval)
        Padding(
          key: const ValueKey('booking-needs-approval'),
          padding: const EdgeInsets.only(top: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.hourglass_top, size: 14, color: theme.hintColor),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  tr('승인이 필요한 자원입니다 — 잡으면 승인을 기다리고, 승인되면 알려 드립니다.'),
                  style: style,
                ),
              ),
            ],
          ),
        ),
      if (rules.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            tr('예약 규칙: {rules}', {'rules': rules.join(' · ')}),
            key: const ValueKey('booking-rules'),
            style: style,
          ),
        ),
    ];
  }

  Widget _suggestions() {
    final theme = Theme.of(context);
    final list = _suggested;
    if (list == null) return const SizedBox.shrink();
    if (list.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text(
          tr('이 시간에 비어 있는 알맞은 회의실이 없습니다.'),
          key: const ValueKey('booking-suggest-empty'),
          style: TextStyle(fontSize: 12, color: theme.hintColor),
        ),
      );
    }
    return Column(
      key: const ValueKey('booking-suggestions'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final s in list)
          ListTile(
            key: ValueKey('booking-suggestion-${s.id}'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            selected: s.id == _resourceId,
            leading: Icon(_kindIcon(s.kind)),
            title: Text(s.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              [
                if (s.capacity != null) tr('{n}명', {'n': s.capacity}),
                if (s.spare != null) tr('{n}자리 남음', {'n': s.spare}),
                if (s.needsApproval) tr('승인 필요'),
              ].join(' · '),
            ),
            trailing: s.id == _resourceId
                ? const Icon(Icons.check, size: 18)
                : null,
            onTap: () => _pickSuggested(s),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    String dayText(DateTime d) =>
        '${d.month}/${d.day} (${_weekdays[d.weekday - 1]})';
    Widget time(
      int value,
      ValueChanged<int> onChanged,
      String key, {
      int min = 0,
    }) => DropdownButton<int>(
      key: ValueKey(key),
      value: value,
      items: [
        for (final m in _halfHours)
          if (m >= min)
            DropdownMenuItem(
              value: m,
              child: Text(m == 24 * 60 ? '24:00' : minutesText(m)),
            ),
      ],
      onChanged: (v) => setState(() {
        if (v != null) onChanged(v);
        _error = null;
        _suggested = null;
      }),
    );
    final multiDay = _endDay.isAfter(_startDay);
    final resource = _resource;
    return AlertDialog(
      title: Text(tr('회의실·자원 예약')),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              KeyedSubtree(
                key: ValueKey('booking-resource-field-$_resourceFieldRev'),
                child: DropdownButtonFormField<String>(
                  key: const ValueKey('booking-resource'),
                  initialValue: _resourceId,
                  isExpanded: true,
                  decoration: InputDecoration(labelText: tr('자원')),
                  items: [
                    for (final r in widget.resources)
                      DropdownMenuItem(
                        value: r.id,
                        enabled: r.canBook,
                        child: Text(
                          r.canBook
                              ? '${r.name} (${r.kindLabel})'
                              : '${r.name} (${r.kindLabel}) — ${tr('정해진 사람만')}',
                          overflow: TextOverflow.ellipsis,
                          style: r.canBook
                              ? null
                              : TextStyle(color: theme.disabledColor),
                        ),
                      ),
                  ],
                  onChanged: (v) => setState(() {
                    _resourceId = v ?? _resourceId;
                    _error = null;
                  }),
                ),
              ),
              if (resource != null) ..._resourceInfo(resource),
              const SizedBox(height: 12),
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  TextButton(
                    key: const ValueKey('booking-start-day'),
                    onPressed: () => _pick(true),
                    child: Text(dayText(_startDay)),
                  ),
                  time(_startMinutes.clamp(0, 24 * 60 - 30), (v) {
                    final length = _endMinutes - _startMinutes;
                    _startMinutes = v;
                    if (!multiDay) {
                      _endMinutes = (v + (length > 0 ? length : 60)).clamp(
                        30,
                        24 * 60,
                      );
                    }
                  }, 'booking-start'),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 6),
                    child: Text('~'),
                  ),
                  if (multiDay)
                    TextButton(
                      onPressed: () => _pick(false),
                      child: Text(dayText(_endDay)),
                    ),
                  time(
                    _endMinutes,
                    (v) => _endMinutes = v,
                    'booking-end',
                    min: multiDay ? 0 : _startMinutes + 30,
                  ),
                ],
              ),
              if (!multiDay)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    key: const ValueKey('booking-multi-day'),
                    onPressed: () => _pick(false),
                    child: Text(tr('여러 날 (차량·장비 대여)')),
                  ),
                ),
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 12,
                children: [
                  DropdownButton<int>(
                    key: const ValueKey('booking-repeat'),
                    value: _repeatEvery,
                    items: [
                      DropdownMenuItem(value: 0, child: Text(tr('반복 안 함'))),
                      DropdownMenuItem(value: 1, child: Text(tr('매주'))),
                      DropdownMenuItem(value: 2, child: Text(tr('2주마다'))),
                    ],
                    onChanged: (v) => setState(() {
                      _repeatEvery = v ?? 0;
                      _error = null;
                    }),
                  ),
                  if (_repeatEvery > 0)
                    DropdownButton<int>(
                      key: const ValueKey('booking-repeat-count'),
                      value: _repeatCount,
                      items: [
                        for (final n in _repeatCounts)
                          DropdownMenuItem(
                            value: n,
                            child: Text(tr('{n}회', {'n': n})),
                          ),
                      ],
                      onChanged: (v) => setState(() {
                        _repeatCount = v ?? _repeatCount;
                        _error = null;
                      }),
                    ),
                ],
              ),
              if (_repeatEvery > 0)
                CheckboxListTile(
                  key: const ValueKey('booking-skip-conflicts'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: _skipConflicts,
                  onChanged: (v) => setState(() {
                    _skipConflicts = v ?? false;
                    _error = null;
                  }),
                  title: Text(tr('겹치는 날 빼고 잡기')),
                  subtitle: Text(tr('끄면 한 회차라도 겹칠 때 아무것도 잡지 않습니다.')),
                ),
              const SizedBox(height: 4),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      key: const ValueKey('booking-attendees'),
                      controller: _attendees,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText: tr('참석 인원 (회의실 추천)'),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    key: const ValueKey('booking-suggest'),
                    onPressed: _suggesting ? null : _suggest,
                    icon: const Icon(Icons.auto_awesome_outlined, size: 18),
                    label: Text(tr('추천')),
                  ),
                ],
              ),
              _suggestions(),
              const SizedBox(height: 4),
              TextField(
                key: const ValueKey('booking-title'),
                controller: _title,
                maxLength: 50,
                decoration: InputDecoration(
                  labelText: tr('제목 (비우면 "자원 이름 예약")'),
                ),
              ),
              if (_error != null)
                Text(
                  _error!,
                  key: const ValueKey('booking-error'),
                  style: TextStyle(color: theme.colorScheme.error),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr('취소')),
        ),
        FilledButton(
          key: const ValueKey('booking-save'),
          onPressed: _saving || resource?.canBook == false ? null : _save,
          child: Text(tr('예약')),
        ),
      ],
    );
  }
}

// ── 관리 탭: 회의실·자원 ─────────────────────────────────────────────────

/// 관리 탭 "회의실·자원" — 자원 목록(켜기·끄기·지우기, 누르면 고치기 — 예약 규칙 포함), 자원마다 태블릿 화면, 예약 시작 전 알림,
/// 사용 통계. [serverUrl]은 태블릿 화면 주소 앞에 붙일 서버 주소(Session.serverUrl).
class ResourcesAdminSection extends StatefulWidget {
  final GroupwareApi api;
  final GroupwareChanges changes;
  final String? serverUrl;
  const ResourcesAdminSection({
    super.key,
    required this.api,
    required this.changes,
    this.serverUrl,
  });

  @override
  State<ResourcesAdminSection> createState() => _ResourcesAdminSectionState();
}

class _ResourcesAdminSectionState extends State<ResourcesAdminSection> {
  List<GroupwareResource>? _resources;

  @override
  void initState() {
    super.initState();
    widget.changes.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    widget.changes.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final r = await widget.api.resources();
      if (mounted) setState(() => _resources = r);
    } catch (_) {}
  }

  Future<void> _edit([GroupwareResource? r]) async {
    final fields = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => ResourceEditDialog(api: widget.api, resource: r),
    );
    if (fields == null || !mounted) return;
    try {
      await widget.api.saveResource(r?.id, fields);
      if (mounted) {
        showAppToast(
          context,
          r == null
              ? tr('{p0}을(를) 더했습니다.', {'p0': fields['name']})
              : tr('저장했습니다.'),
        );
      }
      await _load();
    } catch (e) {
      if (mounted) {
        showAppToast(
          context,
          e is ApiException ? trServer(e.message) : tr('저장하지 못했습니다.'),
        );
      }
    }
  }

  Future<void> _display(GroupwareResource r) async {
    final changed = await showDialog<GroupwareResource>(
      context: context,
      builder: (_) => ResourceDisplayDialog(
        api: widget.api,
        resource: r,
        serverUrl: widget.serverUrl,
      ),
    );
    if (changed != null) await _load();
  }

  Future<void> _delete(GroupwareResource r) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr('{r.name}을(를) 지울까요?', {'r.name': r.name})),
        content: Text(
          tr(
            '잡혀 있던 예약도 모두 지워지고, 앞으로의 예약을 잡은 사람에게 알립니다. 잠시 못 쓰게 하려면 지우지 말고 끄세요.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(tr('취소')),
          ),
          FilledButton(
            key: const ValueKey('resource-delete-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(tr('지우기')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await widget.api.deleteResource(r.id);
      await _load();
    } catch (e) {
      if (mounted) {
        showAppToast(
          context,
          e is ApiException ? trServer(e.message) : tr('지우지 못했습니다.'),
        );
      }
    }
  }

  Future<void> _toggle(GroupwareResource r, bool enabled) async {
    try {
      await widget.api.saveResource(r.id, {'enabled': enabled});
      await _load();
    } catch (e) {
      if (mounted) {
        showAppToast(
          context,
          e is ApiException ? trServer(e.message) : tr('저장하지 못했습니다.'),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final resources = _resources;
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    if (resources == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GroupwareSectionHeader(
          tr('회의실·자원'),
          trailing: TextButton.icon(
            key: const ValueKey('resource-add'),
            onPressed: () => _edit(),
            icon: const Icon(Icons.add, size: 18),
            label: Text(tr('더하기')),
          ),
        ),
        if (resources.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(
              tr('회의실·장비·차량을 더하면 "예약" 탭과 캘린더 일정에서 잡을 수 있습니다.'),
              style: TextStyle(fontSize: 12, color: hint),
            ),
          ),
        for (final r in resources)
          ListTile(
            key: ValueKey('resource-admin-${r.id}'),
            dense: true,
            leading: Icon(_kindIcon(r.kind)),
            title: Text(r.name),
            subtitle: Text(
              [
                r.kindLabel,
                if (r.detail.isNotEmpty) r.detail,
                if (!r.enabled) tr('꺼짐'),
                if (r.requiresApproval) tr('승인 필요'),
                if (r.allowedUserIds.isNotEmpty ||
                    r.availableDays != null ||
                    r.availableFrom != null ||
                    r.maxMinutes != null)
                  tr('규칙'),
              ].join(' · '),
            ),
            onTap: () => _edit(r),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Switch(
                  key: ValueKey('resource-enabled-${r.id}'),
                  value: r.enabled,
                  onChanged: (v) => _toggle(r, v),
                ),
                IconButton(
                  key: ValueKey('resource-display-${r.id}'),
                  tooltip: r.displayPath != null
                      ? tr('태블릿 화면 (켜짐)')
                      : tr('태블릿 화면'),
                  icon: Icon(
                    Icons.tablet_mac_outlined,
                    color: r.displayPath != null
                        ? theme.colorScheme.primary
                        : null,
                  ),
                  onPressed: () => _display(r),
                ),
                IconButton(
                  key: ValueKey('resource-delete-${r.id}'),
                  tooltip: tr('지우기'),
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => _delete(r),
                ),
              ],
            ),
          ),
        BookingReminderOption(api: widget.api),
        if (resources.isNotEmpty) ResourceStatsSection(api: widget.api),
      ],
    );
  }
}
