import 'package:flutter/material.dart';

import '../../models/groupware.dart';
import '../../models/groupware_resources.dart';
import '../../models/team.dart' show AccountRole;
import '../../services/api_client.dart' show ApiException;
import '../../services/groupware_api.dart';
import '../../services/session.dart';
import '../../widgets/app_toast.dart';
import 'groupware_screen.dart' show GroupwareChanges, GroupwareSectionHeader;

/// 그룹웨어 "예약" 탭 — 회의실·장비·차량을 날마다 시간표로 보고 빈 시간을 눌러 잡는다(서버 groupwareResources.js). 캘린더 일정에 붙인
/// 예약도 같은 시간표에 보인다(일정 편집 창의 "회의실·자원"). 겹치는 예약은 서버가 막는다(409 — 누구 예약인지 알려 줌).
///
/// 관리 탭의 자원 관리([ResourcesAdminSection])도 이 파일에 있다.

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

const _weekdays = ['월', '화', '수', '목', '금', '토', '일'];

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
        setState(() => _error = e is ApiException ? e.message : '$e');
      }
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
    if (resources.isEmpty) return;
    final made = await showBookingDialog(
      context,
      api: widget.api,
      resources: resources,
      resource: resource ?? resources.first,
      start: start ?? _defaultStart(),
    );
    if (made == null || !mounted) return;
    showAppToast(context, '${made.resourceName}을(를) 예약했습니다.');
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

  Future<void> _showBooking(ResourceBooking b) async {
    final cancel = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(b.title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${b.resourceName} · ${bookingRangeText(b)}'),
            const SizedBox(height: 4),
            Text('잡은 사람: ${b.userName}'),
            if (b.fromEvent)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '캘린더 일정에 붙은 예약입니다 — 시간을 바꾸려면 그 일정을 고치세요. 취소하면 일정은 남고 회의실만 빠집니다.',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(dialogContext).hintColor,
                  ),
                ),
              ),
          ],
        ),
        actions: [
          if (b.canCancel)
            TextButton(
              key: const ValueKey('booking-cancel'),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(b.mine ? '예약 취소' : '관리자 취소'),
            ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('닫기'),
          ),
        ],
      ),
    );
    if (cancel != true || !mounted) return;
    try {
      await widget.api.cancelBooking(b.id);
      if (mounted) showAppToast(context, '예약을 취소했습니다.');
      _load();
    } catch (e) {
      if (mounted) {
        showAppToast(context, e is ApiException ? e.message : '취소하지 못했습니다.');
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
                  tooltip: '전날',
                  icon: const Icon(Icons.chevron_left),
                  onPressed: () => _shift(-1),
                ),
                TextButton(
                  key: const ValueKey('resource-day'),
                  onPressed: _pickDay,
                  child: Text(
                    '${_day.month}월 ${_day.day}일 (${_weekdays[_day.weekday - 1]})',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  tooltip: '다음 날',
                  icon: const Icon(Icons.chevron_right),
                  onPressed: () => _shift(1),
                ),
                if (!isToday)
                  TextButton(
                    onPressed: () {
                      setState(() => _day = _today());
                      _load();
                    },
                    child: const Text('오늘'),
                  ),
                const Spacer(),
                if (!_isGuest && resources.isNotEmpty)
                  FilledButton.icon(
                    key: const ValueKey('resource-book'),
                    onPressed: () => _book(),
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('예약하기'),
                  ),
              ],
            ),
          ),
          if (resources.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                widget.ctx.isManager
                    ? '아직 자원이 없습니다. 관리 탭 → 회의실·자원에서 회의실·장비·차량을 더하세요.'
                    : '아직 예약할 수 있는 회의실·자원이 없습니다.',
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
              onTapFree: _isGuest
                  ? null
                  : (start) => _book(resource: r, start: start),
              onTapBooking: _showBooking,
            ),
          if (_isGuest)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                '준회원은 현황만 볼 수 있습니다.',
                style: TextStyle(fontSize: 12, color: hint),
              ),
            ),
          const GroupwareSectionHeader('내 예약'),
          if (_mine.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text('앞으로 잡아 둔 예약이 없습니다.', style: TextStyle(color: hint)),
            ),
          for (final b in _mine)
            ListTile(
              key: ValueKey('my-booking-${b.id}'),
              dense: true,
              leading: Icon(_kindIcon(b.resourceKind)),
              title: Text('${b.resourceName} · ${b.title}'),
              subtitle: Text(
                '${bookingRangeText(b)}${b.fromEvent ? ' · 캘린더 일정' : ''}',
              ),
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

/// 자원 하나의 하루 시간표 — 07:00~22:00 막대 위에 예약을 칠하고, 빈 곳을 누르면 그 30분부터 잡는다.
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
            ],
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
                                message:
                                    '${bookingRangeText(b)} ${b.title} — ${b.userName}',
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 4,
                                  ),
                                  alignment: Alignment.centerLeft,
                                  decoration: BoxDecoration(
                                    color: b.mine
                                        ? theme.colorScheme.primary
                                        : theme.colorScheme.secondary
                                              .withValues(alpha: 0.55),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    '${clockText(b.startTime)} ${b.title}',
                                    maxLines: 1,
                                    overflow: TextOverflow.clip,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: b.mine
                                          ? theme.colorScheme.onPrimary
                                          : theme.colorScheme.onSecondary,
                                    ),
                                  ),
                                ),
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
                  Text('$h시', style: TextStyle(fontSize: 10, color: hint)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 30분 단위 시각 목록(분) — 0:00~24:00.
final _halfHours = [for (var m = 0; m <= 24 * 60; m += 30) m];

/// 예약 창 — 자원·날짜·시작·끝·제목. 잡으면 그 예약, 그만두면 null. 겹치면 창 안에 서버 글을 보인다.
Future<ResourceBooking?> showBookingDialog(
  BuildContext context, {
  required GroupwareApi api,
  required List<GroupwareResource> resources,
  required GroupwareResource resource,
  required DateTime start,
}) => showDialog<ResourceBooking>(
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
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  DateTime get _start => _startDay.add(Duration(minutes: _startMinutes));
  DateTime get _end => _endDay.add(Duration(minutes: _endMinutes));

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
    });
  }

  Future<void> _save() async {
    if (!_end.isAfter(_start)) {
      setState(() => _error = '끝 시각은 시작 시각보다 뒤여야 합니다.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final made = await widget.api.book(
        resourceId: _resourceId,
        start: _start.millisecondsSinceEpoch,
        end: _end.millisecondsSinceEpoch,
        title: _title.text.trim().isEmpty ? null : _title.text.trim(),
      );
      if (mounted) Navigator.of(context).pop(made);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = e is ApiException ? e.message : '예약하지 못했습니다.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
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
      }),
    );
    final multiDay = _endDay.isAfter(_startDay);
    return AlertDialog(
      title: const Text('회의실·자원 예약'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<String>(
              key: const ValueKey('booking-resource'),
              initialValue: _resourceId,
              decoration: const InputDecoration(labelText: '자원'),
              items: [
                for (final r in widget.resources)
                  DropdownMenuItem(
                    value: r.id,
                    child: Text('${r.name} (${r.kindLabel})'),
                  ),
              ],
              onChanged: (v) => setState(() => _resourceId = v ?? _resourceId),
            ),
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
                  child: const Text('여러 날 (차량·장비 대여)'),
                ),
              ),
            TextField(
              key: const ValueKey('booking-title'),
              controller: _title,
              maxLength: 50,
              decoration: const InputDecoration(
                labelText: '제목 (비우면 "자원 이름 예약")',
              ),
            ),
            if (_error != null)
              Text(
                _error!,
                key: const ValueKey('booking-error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        FilledButton(
          key: const ValueKey('booking-save'),
          onPressed: _saving ? null : _save,
          child: const Text('예약'),
        ),
      ],
    );
  }
}

// ── 관리 탭: 회의실·자원 ─────────────────────────────────────────────────

class ResourcesAdminSection extends StatefulWidget {
  final GroupwareApi api;
  final GroupwareChanges changes;
  const ResourcesAdminSection({
    super.key,
    required this.api,
    required this.changes,
  });

  @override
  State<ResourcesAdminSection> createState() => _ResourcesAdminSectionState();
}

class _ResourcesAdminSectionState extends State<ResourcesAdminSection> {
  List<GroupwareResource>? _resources;

  @override
  void initState() {
    super.initState();
    _load();
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
      builder: (_) => _ResourceDialog(resource: r),
    );
    if (fields == null || !mounted) return;
    try {
      await widget.api.saveResource(r?.id, fields);
      if (mounted) {
        showAppToast(
          context,
          r == null ? '${fields['name']}을(를) 더했습니다.' : '저장했습니다.',
        );
      }
      await _load();
    } catch (e) {
      if (mounted) {
        showAppToast(context, e is ApiException ? e.message : '저장하지 못했습니다.');
      }
    }
  }

  Future<void> _delete(GroupwareResource r) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('${r.name}을(를) 지울까요?'),
        content: const Text(
          '잡혀 있던 예약도 모두 지워지고, 앞으로의 예약을 잡은 사람에게 알립니다. 잠시 못 쓰게 하려면 지우지 말고 끄세요.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            key: const ValueKey('resource-delete-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('지우기'),
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
        showAppToast(context, e is ApiException ? e.message : '지우지 못했습니다.');
      }
    }
  }

  Future<void> _toggle(GroupwareResource r, bool enabled) async {
    try {
      await widget.api.saveResource(r.id, {'enabled': enabled});
      await _load();
    } catch (e) {
      if (mounted) {
        showAppToast(context, e is ApiException ? e.message : '저장하지 못했습니다.');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final resources = _resources;
    final hint = Theme.of(context).hintColor;
    if (resources == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GroupwareSectionHeader(
          '회의실·자원',
          trailing: TextButton.icon(
            key: const ValueKey('resource-add'),
            onPressed: () => _edit(),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('더하기'),
          ),
        ),
        if (resources.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(
              '회의실·장비·차량을 더하면 "예약" 탭과 캘린더 일정에서 잡을 수 있습니다.',
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
                if (!r.enabled) '꺼짐',
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
                  key: ValueKey('resource-delete-${r.id}'),
                  tooltip: '지우기',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => _delete(r),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _ResourceDialog extends StatefulWidget {
  final GroupwareResource? resource;
  const _ResourceDialog({this.resource});

  @override
  State<_ResourceDialog> createState() => _ResourceDialogState();
}

class _ResourceDialogState extends State<_ResourceDialog> {
  late String _kind = widget.resource?.kind ?? 'room';
  late final _name = TextEditingController(text: widget.resource?.name ?? '');
  late final _location = TextEditingController(
    text: widget.resource?.location ?? '',
  );
  late final _capacity = TextEditingController(
    text: widget.resource?.capacity?.toString() ?? '',
  );
  late final _description = TextEditingController(
    text: widget.resource?.description ?? '',
  );
  String? _error;

  @override
  void dispose() {
    for (final c in [_name, _location, _capacity, _description]) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '이름을 넣으세요.');
      return;
    }
    final capacityText = _capacity.text.trim();
    final capacity = capacityText.isEmpty ? null : int.tryParse(capacityText);
    if (capacityText.isNotEmpty && (capacity == null || capacity < 1)) {
      setState(() => _error = '수용 인원은 1 이상의 숫자로 넣으세요.');
      return;
    }
    Navigator.of(context).pop({
      'kind': _kind,
      'name': name,
      'location': _location.text.trim(),
      'capacity': capacity,
      'description': _description.text.trim(),
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.resource == null ? '회의실·자원 더하기' : '회의실·자원 고치기'),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SegmentedButton<String>(
                key: const ValueKey('resource-kind'),
                segments: [
                  for (final e in resourceKindLabels.entries)
                    ButtonSegment(value: e.key, label: Text(e.value)),
                ],
                selected: {_kind},
                onSelectionChanged: (s) => setState(() => _kind = s.first),
              ),
              TextField(
                key: const ValueKey('resource-name'),
                controller: _name,
                maxLength: 30,
                decoration: const InputDecoration(labelText: '이름'),
              ),
              TextField(
                key: const ValueKey('resource-location'),
                controller: _location,
                maxLength: 50,
                decoration: const InputDecoration(labelText: '위치 (예: 3층)'),
              ),
              TextField(
                key: const ValueKey('resource-capacity'),
                controller: _capacity,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: '수용 인원'),
              ),
              TextField(
                key: const ValueKey('resource-description'),
                controller: _description,
                maxLength: 200,
                decoration: const InputDecoration(labelText: '설명 (장비 목록 등)'),
              ),
              if (_error != null)
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        FilledButton(
          key: const ValueKey('resource-save'),
          onPressed: _save,
          child: const Text('저장'),
        ),
      ],
    );
  }
}
