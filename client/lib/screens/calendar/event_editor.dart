import 'dart:convert';

import 'package:flutter/material.dart';

import '../../models/app_user.dart';
import '../../models/calendar.dart';
import '../../models/team.dart' show AccountRole;
import '../../services/api_client.dart' show ApiException;
import '../../services/calendar_controller.dart';
import '../../services/calendar_layout.dart';
import '../../services/session.dart';
import '../../services/time_format.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/date_drop_calendar.dart';
import '../../widgets/floating_dialog.dart';
import '../home_screen.dart' show wideBreakpoint;
import '../invite_members_screen.dart' show showPickMembers;
import 'calendar_common.dart';

/// 일정 만들기 화면 항목의 글자 수 한도 — 서버 규약과 같다.
const kEventTitleMax = 50;
const kEventLocationMax = 50;
const kEventDescriptionMax = 500;

/// 반복 횟수 상한(서버 규약: count ≤ 500)과 간격 범위(1~99).
const kRecurrenceCountMax = 500;
const kRecurrenceIntervalMax = 99;

/// 일정 만들기([editing]이 없을 때)·수정 창을 연다 — 넓은 창(PC)은 대화상자, 좁은 창(모바일)은 전체
/// 화면. [initialStart]는 누른 날짜(시각이 있으면 그 시각, 없으면 기본 시각)이고 [calendarId]는 미리
/// 고를 캘린더. 반복 일정을 고칠 때는 [scope]로 적용 범위를 함께 넘긴다. 저장했으면 true.
Future<bool> showEventEditor(
  BuildContext context,
  Session session,
  CalendarController controller, {
  EventOccurrence? editing,
  RecurrenceScope? scope,
  DateTime? initialStart,
  String? calendarId,
}) async {
  final wide = MediaQuery.sizeOf(context).width >= wideBreakpoint;
  final editor = EventEditor(
    session: session,
    controller: controller,
    editing: editing,
    scope: scope,
    initialStart: initialStart,
    calendarId: calendarId,
    asDialog: wide,
  );
  final saved = wide
      ? await showDialog<bool>(
          context: context,
          // 바깥을 잘못 눌러 쓰던 내용이 날아가지 않게 — 닫기는 ✕·취소·Esc(내용이 있으면 확인 후)로만.
          barrierDismissible: false,
          builder: (_) => editor,
        )
      : await Navigator.of(context).push<bool>(
          MaterialPageRoute(fullscreenDialog: true, builder: (_) => editor),
        );
  if (saved == true && context.mounted) {
    showAppToast(context, editing == null ? '일정을 만들었습니다.' : '일정을 수정했습니다.');
  }
  return saved == true;
}

/// 새 일정의 기본 시작 시각 — [day]가 오늘이면 다음 정시, 아니면 그 날 오전 9시. 하루를 넘기지 않는다.
DateTime defaultEventStart(DateTime day, DateTime now) {
  final d = dateOnly(day);
  if (sameDay(d, now)) {
    final hour = (now.hour + 1).clamp(0, 22);
    return DateTime(d.year, d.month, d.day, hour);
  }
  return DateTime(d.year, d.month, d.day, 9);
}

enum _Repeat { none, daily, weekly, monthly, yearly, custom }

enum _RepeatEnd { never, until, count }

/// 일정 만들기·수정 폼. 대화상자([asDialog])와 전체 화면 둘 다 같은 몸통을 쓴다.
class EventEditor extends StatefulWidget {
  final Session session;
  final CalendarController controller;
  final EventOccurrence? editing;
  final RecurrenceScope? scope;
  final DateTime? initialStart;
  final String? calendarId;
  final bool asDialog;

  const EventEditor({
    super.key,
    required this.session,
    required this.controller,
    this.editing,
    this.scope,
    this.initialStart,
    this.calendarId,
    this.asDialog = false,
  });

  @override
  State<EventEditor> createState() => EventEditorState();
}

class EventEditorState extends State<EventEditor> {
  final _title = TextEditingController();
  final _location = TextEditingController();
  final _description = TextEditingController();
  final _interval = TextEditingController(text: '1');
  final _count = TextEditingController(text: '10');
  final _search = TextEditingController();

  String? _calendarId;
  String? _colorHex;
  bool _colorTouched = false;
  late DateTime _start;
  late DateTime _end;
  bool _allDay = false;
  String _visibility = 'public';

  /// 참석자(id → 이름), 고른 순서를 유지한다.
  final Map<String, String> _attendees = {};
  List<AppUser>? _members;
  bool _membersLoading = false;

  _Repeat _repeat = _Repeat.none;
  String _customFreq = 'daily';
  final Set<int> _weekdays = {};
  bool _weekdaysTouched = false;
  _RepeatEnd _repeatEnd = _RepeatEnd.never;
  late DateTime _until;

  bool _saving = false;
  bool _dirty = false;
  String? _error;
  String? _titleError;

  // 수정할 때 바뀐 것만 보내려고 처음 값을 기억해 둔다.
  String _initTitle = '';
  String _initDescription = '';
  String _initLocation = '';
  String _initVisibility = 'public';
  String? _initCalendarId;
  String? _initColor;
  Set<String> _initAttendeeIds = {};
  String _initRecurrenceJson = 'null';

  EventOccurrence? get _editing => widget.editing;
  bool get _isEdit => _editing != null;

  /// "이 일정만" 고치는 중 — 반복 규칙은 건드릴 수 없다(그 회차만 반복 없는 새 일정이 된다).
  bool get _thisOnly => _isEdit && widget.scope == RecurrenceScope.thisOnly;

  bool get _isGuest => widget.session.accountRole == AccountRole.guest;

  @override
  void initState() {
    super.initState();
    final e = _editing;
    final now = DateTime.now();
    if (e != null) {
      _title.text = e.title;
      _location.text = e.location ?? '';
      _description.text = e.description ?? '';
      _calendarId = e.calendarId;
      _colorHex = e.color;
      _allDay = e.allDay;
      if (e.allDay) {
        _start = e.firstDay;
        _end = e.lastDay;
      } else {
        _start = e.startTime;
        _end = e.endTime;
      }
      _visibility = e.visibility;
      for (final a in e.attendees) {
        _attendees[a.userId] = a.name;
      }
      _initRecurrenceFrom(e.recurrence);
    } else {
      final base = widget.initialStart;
      // 시각까지 정해서 들어오면(시간표를 눌렀다) 그대로, 날짜만이면 기본 시각으로.
      _start = base == null
          ? defaultEventStart(now, now)
          : (base.hour == 0 && base.minute == 0)
          ? defaultEventStart(base, now)
          : floorToMinutes(base);
      _end = DateTime(
        _start.year,
        _start.month,
        _start.day,
        _start.hour + 1,
        _start.minute,
      );
      _calendarId = widget.calendarId ?? _defaultCalendarId();
      _colorHex = widget.controller.calendarById(_calendarId ?? '')?.color;
    }
    _until = addDays(_start, 30);
    if (_weekdays.isEmpty) _weekdays.add(weekdayIndex(_start));

    _initTitle = _title.text;
    _initDescription = _description.text;
    _initLocation = _location.text;
    _initVisibility = _visibility;
    _initCalendarId = _calendarId;
    _initColor = _colorHex;
    _initAttendeeIds = _attendees.keys.toSet();
    // 서버로 보내는 모양(시간 일정의 반복 요일은 한국 달력 기준 — kstWeekdayShift)으로 맞춰 둬야 안 바꿨을 때 같다고 본다.
    _initRecurrenceJson = jsonEncode(
      _editing?.recurrence?.toJson(
        weekdayShift: e == null || e.allDay ? 0 : kstWeekdayShift(e.start),
      ),
    );

    for (final c in [_title, _location, _description, _interval, _count]) {
      c.addListener(_markDirty);
    }
  }

  String? _defaultCalendarId() {
    final writable = widget.controller.writableCalendars;
    return writable.isEmpty ? null : writable.first.id;
  }

  void _initRecurrenceFrom(Recurrence? r) {
    if (r == null) return;
    _weekdays
      ..clear()
      ..addAll(r.byWeekday);
    _weekdaysTouched = r.byWeekday.isNotEmpty;
    final plain = r.interval == 1 && r.until == null && r.count == null;
    if (plain && r.freq != 'weekly') {
      _repeat = switch (r.freq) {
        'monthly' => _Repeat.monthly,
        'yearly' => _Repeat.yearly,
        _ => _Repeat.daily,
      };
    } else if (plain) {
      _repeat = _Repeat.weekly;
    } else {
      _repeat = _Repeat.custom;
      _customFreq = r.freq;
      _interval.text = '${r.interval}';
      if (r.until != null) {
        _repeatEnd = _RepeatEnd.until;
        _until = r.until!;
      } else if (r.count != null) {
        _repeatEnd = _RepeatEnd.count;
        _count.text = '${r.count}';
      }
    }
  }

  @override
  void dispose() {
    for (final c in [
      _title,
      _location,
      _description,
      _interval,
      _count,
      _search,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  void _markDirty() {
    if (!_dirty) _dirty = true;
  }

  void _change(VoidCallback fn) => setState(() {
    fn();
    _dirty = true;
    _error = null;
  });

  // ---- 날짜·시간 ----

  void _setStart(DateTime v) {
    final minutes = _end.difference(_start).inMinutes;
    _change(() {
      _start = v;
      _end = DateTime(v.year, v.month, v.day, v.hour, v.minute + minutes);
      if (!_weekdaysTouched) {
        _weekdays
          ..clear()
          ..add(weekdayIndex(v));
      }
    });
  }

  void _setEnd(DateTime v) {
    _change(() {
      var end = v;
      if (_allDay) {
        if (dateOnly(end).isBefore(dateOnly(_start))) {
          end = DateTime(
            _start.year,
            _start.month,
            _start.day,
            v.hour,
            v.minute,
          );
        }
      } else if (!end.isAfter(_start)) {
        // 종료가 시작보다 앞서지 못한다 — 시작 10분 뒤로 맞춘다.
        end = DateTime(
          _start.year,
          _start.month,
          _start.day,
          _start.hour,
          _start.minute + 10,
        );
      }
      _end = end;
    });
  }

  DateTime _withMinutes(DateTime day, int minutes) =>
      DateTime(day.year, day.month, day.day, minutes ~/ 60, minutes % 60);

  // ---- 참석자 ----

  Future<void> _loadMembers() async {
    if (_members != null || _membersLoading) return;
    _membersLoading = true;
    try {
      final list = await widget.session.fetchTeamMembers();
      if (mounted) setState(() => _members = list);
    } catch (_) {
      if (mounted) setState(() => _members = const []);
    } finally {
      _membersLoading = false;
    }
  }

  List<AppUser> get _suggestions {
    final q = _search.text.trim().toLowerCase();
    if (q.isEmpty) return const [];
    return [
      for (final u in _members ?? const <AppUser>[])
        if (u.id != widget.session.userId &&
            !_attendees.containsKey(u.id) &&
            (u.name.toLowerCase().contains(q) ||
                u.username.toLowerCase().contains(q)))
          u,
    ].take(6).toList();
  }

  Future<void> _pickFromOrg() async {
    final picked = await showPickMembers(
      context,
      widget.session,
      title: '참석자 선택',
      initialSelected: _attendees.keys.toList(),
    );
    if (picked == null || !mounted) return;
    _change(() {
      _attendees
        ..clear()
        ..addEntries(picked.map((u) => MapEntry(u.id, u.name)));
    });
  }

  // ---- 반복 ----

  /// 폼의 반복 설정을 Recurrence로. 잘못된 값이면 error에 사유.
  ({Recurrence? value, String? error}) _buildRecurrence() {
    switch (_repeat) {
      case _Repeat.none:
        return (value: null, error: null);
      case _Repeat.daily:
        return (value: const Recurrence(freq: 'daily'), error: null);
      case _Repeat.monthly:
        return (value: const Recurrence(freq: 'monthly'), error: null);
      case _Repeat.yearly:
        return (value: const Recurrence(freq: 'yearly'), error: null);
      case _Repeat.weekly:
        if (_weekdays.isEmpty) {
          return (value: null, error: '반복할 요일을 하나 이상 고르세요.');
        }
        return (
          value: Recurrence(freq: 'weekly', byWeekday: _weekdays.toList()),
          error: null,
        );
      case _Repeat.custom:
        final interval = int.tryParse(_interval.text.trim());
        if (interval == null ||
            interval < 1 ||
            interval > kRecurrenceIntervalMax) {
          return (
            value: null,
            error: '반복 간격은 1~$kRecurrenceIntervalMax 사이의 숫자여야 합니다.',
          );
        }
        if (_customFreq == 'weekly' && _weekdays.isEmpty) {
          return (value: null, error: '반복할 요일을 하나 이상 고르세요.');
        }
        DateTime? until;
        int? count;
        if (_repeatEnd == _RepeatEnd.until) {
          until = dateOnly(_until);
          if (until.isBefore(dateOnly(_start))) {
            return (value: null, error: '반복 종료일은 시작일 이후여야 합니다.');
          }
        } else if (_repeatEnd == _RepeatEnd.count) {
          count = int.tryParse(_count.text.trim());
          if (count == null || count < 1 || count > kRecurrenceCountMax) {
            return (
              value: null,
              error: '반복 횟수는 1~$kRecurrenceCountMax 사이의 숫자여야 합니다.',
            );
          }
        }
        return (
          value: Recurrence(
            freq: _customFreq,
            interval: interval,
            byWeekday: _customFreq == 'weekly' ? _weekdays.toList() : const [],
            until: until,
            count: count,
          ),
          error: null,
        );
    }
  }

  // ---- 저장 ----

  int get _startMs =>
      _allDay ? allDayToMs(_start) : _start.millisecondsSinceEpoch;

  /// 종일이면 마지막 날의 다음 날 자정(배타), 시간 일정이면 끝 시각.
  int get _endMs =>
      _allDay ? allDayToMs(addDays(_end, 1)) : _end.millisecondsSinceEpoch;

  String? _validate() {
    final title = _title.text.trim();
    if (title.isEmpty) {
      _titleError = '제목을 입력하세요.';
      return _titleError;
    }
    if (title.characters.length > kEventTitleMax) {
      _titleError = '제목은 $kEventTitleMax자까지 입력할 수 있습니다.';
      return _titleError;
    }
    if (_calendarId == null) return '일정을 만들 수 있는 캘린더가 없습니다.';
    if (_allDay
        ? dateOnly(_end).isBefore(dateOnly(_start))
        : !_end.isAfter(_start)) {
      return '종료 시각은 시작 시각보다 뒤여야 합니다.';
    }
    if (_location.text.characters.length > kEventLocationMax) {
      return '장소는 $kEventLocationMax자까지 입력할 수 있습니다.';
    }
    if (_description.text.characters.length > kEventDescriptionMax) {
      return '설명은 $kEventDescriptionMax자까지 입력할 수 있습니다.';
    }
    if (!_thisOnly) {
      final r = _buildRecurrence();
      if (r.error != null) return r.error;
    }
    return null;
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _titleError = null;
      final problem = _validate();
      // 제목 문제는 제목 칸 아래에만 보인다(폼 아래 오류줄에 또 적지 않는다).
      _error = _titleError == null ? problem : null;
    });
    if (_error != null || _titleError != null) return;

    setState(() => _saving = true);
    try {
      if (_isEdit) {
        await _saveEdit();
      } else {
        await widget.controller.createEvent(
          _calendarId!,
          EventInput(
            title: _title.text.trim(),
            description: _description.text.trim(),
            location: _location.text.trim(),
            start: _startMs,
            end: _endMs,
            allDay: _allDay,
            visibility: _visibility,
            attendeeIds: _isGuest ? const [] : _attendees.keys.toList(),
            recurrence: _buildRecurrence().value,
            color: _colorTouched ? _colorHex : null,
          ),
        );
      }
      if (!mounted) return;
      _dirty = false;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e is ApiException ? e.message : '저장하지 못했습니다. 잠시 후 다시 시도하세요.';
      });
    }
  }

  Future<void> _saveEdit() async {
    final e = _editing!;
    final fields = <String, dynamic>{};
    final title = _title.text.trim();
    if (title != _initTitle.trim()) fields['title'] = title;
    if (_description.text.trim() != _initDescription.trim()) {
      fields['description'] = _description.text.trim();
    }
    if (_location.text.trim() != _initLocation.trim()) {
      fields['location'] = _location.text.trim();
    }
    if (_visibility != _initVisibility) fields['visibility'] = _visibility;
    if (!_isGuest && !_sameSet(_attendees.keys.toSet(), _initAttendeeIds)) {
      fields['attendeeIds'] = _attendees.keys.toList();
    }
    if (!_thisOnly) {
      final recurrence = _buildRecurrence().value;
      final wire = recurrence?.toJson(
        weekdayShift: _allDay ? 0 : kstWeekdayShift(_startMs),
      );
      if (jsonEncode(wire) != _initRecurrenceJson) {
        fields['recurrence'] = wire;
      }
    }
    if (_calendarId != _initCalendarId) fields['calendarId'] = _calendarId;
    if (_colorTouched && _colorHex != _initColor) fields['color'] = _colorHex;

    // 시간은 바뀌었을 때만 보낸다. 반복 일정이면 서버가 start/end를 "고친 회차의 값"으로 읽는다
    // (scope=all이면 새 start - occurrenceStart 만큼 원본을 옮긴다).
    final timeChanged =
        _startMs != e.start || _endMs != e.end || _allDay != e.allDay;
    if (timeChanged) {
      fields['start'] = _startMs;
      fields['end'] = _endMs;
      fields['allDay'] = _allDay;
    }
    if (fields.isEmpty) return;

    // 색만 바꾸는 요청은 내 개인 설정일 뿐 일정 자체를 안 바꾸므로 범위(scope)를 붙이지 않는다 —
    // 붙이면 서버가 "이 일정만/이후 일정"으로 새 일정을 만들어 버린다.
    final colorOnly = fields.length == 1 && fields.containsKey('color');
    final scope = e.recurring && !colorOnly ? widget.scope : null;
    // "이 일정만"·"이후 일정"은 서버가 이 회차를 기준으로 새 일정/새 마스터를 만드니, 시간을 안 바꿨어도
    // 이 회차의 시간을 함께 보내 새 일정이 이 회차 자리에서 시작하게 한다.
    if ((scope == RecurrenceScope.thisOnly ||
            scope == RecurrenceScope.following) &&
        !fields.containsKey('start')) {
      fields['start'] = _startMs;
      fields['end'] = _endMs;
      fields['allDay'] = _allDay;
    }
    await widget.controller.updateEvent(
      e.eventId!,
      fields,
      scope: scope,
      occurrenceStart: e.recurring ? e.start : null,
    );
  }

  bool _sameSet(Set<String> a, Set<String> b) =>
      a.length == b.length && a.containsAll(b);

  Future<bool> _confirmDiscard() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('작성을 그만할까요?'),
        content: const Text('입력한 내용이 저장되지 않습니다.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('계속 작성'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('나가기'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  /// 쓰던 내용이 있는데 닫으려 할 때 — 확인을 받고 닫는다.
  Future<void> _discardAndClose() async {
    if (!await _confirmDiscard() || !mounted) return;
    setState(() => _dirty = false);
    Navigator.of(context).pop(false);
  }

  // ---- 화면 ----

  @override
  Widget build(BuildContext context) {
    final title = _isEdit ? '일정 수정' : '일정 만들기';
    final form = _buildForm(context);
    final footer = _buildFooter(context);
    final body = PopScope(
      canPop: !_dirty || _saving,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _discardAndClose();
      },
      child: widget.asDialog
          ? FloatingDialog(
              title: title,
              maxWidth: 560,
              maxHeight: 780,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Flexible(
                    child: SingleChildScrollView(
                      // 위 여백 — 맨 위 "제목" 칸의 떠 있는 라벨이 스크롤 영역 위 끝에 잘리지 않게.
                      padding: const EdgeInsets.only(top: 8, right: 4),
                      child: form,
                    ),
                  ),
                  const SizedBox(height: 12),
                  footer,
                ],
              ),
            )
          : Scaffold(
              appBar: AppBar(
                title: Text(title),
                actions: [
                  TextButton(
                    key: const ValueKey('event-save'),
                    onPressed: _saving ? null : _save,
                    child: _saving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('저장'),
                  ),
                ],
              ),
              body: SafeArea(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [form, if (_error != null) _errorText(context)],
                  ),
                ),
              ),
            ),
    );
    return body;
  }

  Widget _errorText(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: Text(
      _error!,
      key: const ValueKey('event-error'),
      style: TextStyle(color: Theme.of(context).colorScheme.error),
    ),
  );

  Widget _buildFooter(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_error != null) _errorText(context),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              key: const ValueKey('event-cancel'),
              onPressed: _saving
                  ? null
                  : () => Navigator.of(context).maybePop(),
              child: const Text('취소'),
            ),
            const SizedBox(width: 8),
            FilledButton(
              key: const ValueKey('event-save'),
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('저장'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildForm(BuildContext context) {
    final theme = Theme.of(context);
    final calendars = _calendarChoices();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const ValueKey('event-title'),
          controller: _title,
          maxLength: kEventTitleMax,
          autofocus: !_isEdit,
          decoration: InputDecoration(
            labelText: '제목',
            hintText: '일정 제목 (필수)',
            errorText: _titleError,
            border: const OutlineInputBorder(),
          ),
          onChanged: (_) {
            if (_titleError != null) setState(() => _titleError = null);
          },
        ),
        const SizedBox(height: 4),
        _label('캘린더'),
        _calendarDropdown(calendars),
        const SizedBox(height: 14),
        _label('색'),
        CalendarColorGrid(
          selected: _colorHex,
          size: 26,
          onSelected: (hex) => _change(() {
            _colorHex = hex;
            _colorTouched = true;
          }),
        ),
        const SizedBox(height: 14),
        _label('기간'),
        _buildDateTimeRow(
          keyPrefix: 'event-start',
          value: _start,
          onDate: (d) => _setStart(
            DateTime(d.year, d.month, d.day, _start.hour, _start.minute),
          ),
          onMinutes: (m) => _setStart(_withMinutes(_start, m)),
        ),
        const SizedBox(height: 8),
        _buildDateTimeRow(
          keyPrefix: 'event-end',
          value: _end,
          onDate: (d) =>
              _setEnd(DateTime(d.year, d.month, d.day, _end.hour, _end.minute)),
          onMinutes: (m) => _setEnd(_withMinutes(_end, m)),
          isEnd: true,
        ),
        SwitchListTile(
          key: const ValueKey('event-allday'),
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('종일'),
          value: _allDay,
          onChanged: (v) => _change(() => _allDay = v),
        ),
        if (!_isGuest) ...[
          const SizedBox(height: 6),
          _label('참석자'),
          _buildAttendees(theme),
        ],
        const SizedBox(height: 14),
        TextField(
          key: const ValueKey('event-location'),
          controller: _location,
          maxLength: kEventLocationMax,
          decoration: const InputDecoration(
            labelText: '장소',
            prefixIcon: Icon(Icons.place_outlined),
            border: OutlineInputBorder(),
          ),
        ),
        if (!_thisOnly) ...[
          const SizedBox(height: 4),
          _label('반복'),
          _buildRepeat(theme),
        ] else
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 8),
            child: Text(
              '이 일정만 수정합니다. 수정한 일정은 반복되지 않는 별도 일정이 됩니다.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.hintColor,
              ),
            ),
          ),
        const SizedBox(height: 10),
        TextField(
          key: const ValueKey('event-description'),
          controller: _description,
          maxLength: kEventDescriptionMax,
          minLines: 3,
          maxLines: 6,
          decoration: const InputDecoration(
            labelText: '설명',
            alignLabelWithHint: true,
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 4),
        _label('공개 설정'),
        SegmentedButton<String>(
          key: const ValueKey('event-visibility'),
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(
              value: 'public',
              icon: Icon(Icons.public, size: 18),
              label: Text('공개'),
            ),
            ButtonSegment(
              value: 'private',
              icon: Icon(Icons.lock_outline, size: 18),
              label: Text('비공개'),
            ),
          ],
          selected: {_visibility},
          onSelectionChanged: (s) => _change(() => _visibility = s.first),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            _visibility == 'private'
                ? '비공개 일정은 초대된 사람만 자세한 내용을 볼 수 있습니다.'
                : '캘린더를 볼 수 있는 모든 사람이 자세한 내용을 볼 수 있습니다.',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
          ),
        ),
      ],
    );
  }

  Widget _label(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(
      text,
      style: Theme.of(
        context,
      ).textTheme.labelMedium?.copyWith(color: Theme.of(context).hintColor),
    ),
  );

  /// 고를 수 있는 캘린더 — 일정을 만들 수 있는 것들 + (수정 중이면) 원래 캘린더.
  List<CalendarInfo> _calendarChoices() {
    final list = [...widget.controller.writableCalendars];
    final current = _calendarId;
    if (current != null && !list.any((c) => c.id == current)) {
      final c = widget.controller.calendarById(current);
      if (c != null) list.add(c);
    }
    return list;
  }

  Widget _calendarDropdown(List<CalendarInfo> calendars) {
    if (calendars.isEmpty) {
      return Text(
        '일정을 만들 수 있는 캘린더가 없습니다.',
        style: TextStyle(color: Theme.of(context).colorScheme.error),
      );
    }
    // 반복 일정의 "이 일정만"·"이후 일정" 수정은 캘린더를 옮길 수 없다(서버 규약: scope=all일 때만).
    final locked =
        _isEdit && (_editing!.recurring) && widget.scope != RecurrenceScope.all;
    return InputDecorator(
      decoration: const InputDecoration(
        border: OutlineInputBorder(),
        isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          key: const ValueKey('event-calendar'),
          value: _calendarId,
          isExpanded: true,
          isDense: true,
          onChanged: locked
              ? null
              : (id) {
                  if (id == null) return;
                  _change(() {
                    _calendarId = id;
                    if (!_colorTouched) {
                      _colorHex = widget.controller.calendarById(id)?.color;
                    }
                  });
                },
          items: [
            for (final c in calendars)
              DropdownMenuItem(
                value: c.id,
                child: Row(
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: calendarColor(c.color),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(c.name, overflow: TextOverflow.ellipsis),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 날짜 칸 + (종일이 아니면) 시각 칸 한 줄.
  Widget _buildDateTimeRow({
    required String keyPrefix,
    required DateTime value,
    required ValueChanged<DateTime> onDate,
    required ValueChanged<int> onMinutes,
    bool isEnd = false,
  }) {
    final theme = Theme.of(context);
    Widget box(Widget child, {IconData? icon}) => Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outline),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, size: 16, color: theme.hintColor),
            const SizedBox(width: 8),
          ],
          Expanded(child: child),
        ],
      ),
    );
    final minutes = value.hour * 60 + value.minute;
    final times = <int>{for (var m = 0; m < 1440; m += 10) m, minutes}.toList()
      ..sort();
    return Row(
      children: [
        Expanded(
          flex: 5,
          child: DateDropButton(
            key: ValueKey('$keyPrefix-date'),
            value: value,
            allowClear: false,
            onPicked: (d) {
              if (d != null) onDate(d);
            },
            child: box(
              Text(
                formatScheduleDate(value),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              icon: Icons.calendar_today_outlined,
            ),
          ),
        ),
        if (!_allDay) ...[
          const SizedBox(width: 8),
          Expanded(
            flex: 4,
            child: box(
              DropdownButtonHideUnderline(
                child: DropdownButton<int>(
                  key: ValueKey('$keyPrefix-time'),
                  value: minutes,
                  isExpanded: true,
                  isDense: true,
                  menuMaxHeight: 320,
                  onChanged: (m) {
                    if (m != null) onMinutes(m);
                  },
                  items: [
                    for (final m in times)
                      DropdownMenuItem(
                        value: m,
                        // 종료 시각은 시작 시각 이하를 고를 수 없다.
                        enabled:
                            !isEnd || _withMinutes(value, m).isAfter(_start),
                        child: Text(
                          formatScheduleClock(_withMinutes(value, m)),
                          style:
                              !isEnd || _withMinutes(value, m).isAfter(_start)
                              ? null
                              : TextStyle(color: theme.disabledColor),
                        ),
                      ),
                  ],
                ),
              ),
              icon: Icons.schedule,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildAttendees(ThemeData theme) {
    final suggestions = _suggestions;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const ValueKey('event-attendee-search'),
                controller: _search,
                decoration: const InputDecoration(
                  isDense: true,
                  hintText: '이름으로 검색',
                  prefixIcon: Icon(Icons.search, size: 20),
                  border: OutlineInputBorder(),
                ),
                onTap: _loadMembers,
                onChanged: (_) {
                  _loadMembers();
                  setState(() {});
                },
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              key: const ValueKey('event-attendee-org'),
              onPressed: _pickFromOrg,
              icon: const Icon(Icons.account_tree_outlined, size: 18),
              label: const Text('조직도'),
            ),
          ],
        ),
        if (suggestions.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(top: 4),
            decoration: BoxDecoration(
              border: Border.all(color: theme.dividerColor),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Column(
              children: [
                for (final u in suggestions)
                  ListTile(
                    key: ValueKey('event-suggest-${u.id}'),
                    dense: true,
                    visualDensity: VisualDensity.compact,
                    title: Text(u.name),
                    subtitle: u.orgLine == null ? null : Text(u.orgLine!),
                    onTap: () => _change(() {
                      _attendees[u.id] = u.name;
                      _search.clear();
                    }),
                  ),
              ],
            ),
          ),
        if (_attendees.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final entry in _attendees.entries)
                  InputChip(
                    key: ValueKey('event-attendee-${entry.key}'),
                    label: Text(entry.value),
                    onDeleted: () =>
                        _change(() => _attendees.remove(entry.key)),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildRepeat(ThemeData theme) {
    const labels = {
      _Repeat.none: '반복 안 함',
      _Repeat.daily: '매일',
      _Repeat.weekly: '매주',
      _Repeat.monthly: '매월',
      _Repeat.yearly: '매년',
      _Repeat.custom: '사용자 정의',
    };
    final rec = _buildRecurrence();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InputDecorator(
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            isDense: true,
            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<_Repeat>(
              key: const ValueKey('event-repeat'),
              value: _repeat,
              isExpanded: true,
              isDense: true,
              onChanged: (v) {
                if (v != null) _change(() => _repeat = v);
              },
              items: [
                for (final entry in labels.entries)
                  DropdownMenuItem(value: entry.key, child: Text(entry.value)),
              ],
            ),
          ),
        ),
        if (_repeat == _Repeat.weekly) ..._weekdayChips(),
        if (_repeat == _Repeat.custom) ..._customRepeat(theme),
        if (rec.value != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              rec.value!.summary(startDay: dateOnly(_start)),
              key: const ValueKey('event-repeat-summary'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ),
      ],
    );
  }

  List<Widget> _weekdayChips() => [
    const SizedBox(height: 8),
    Wrap(
      spacing: 6,
      children: [
        for (var i = 0; i < 7; i++)
          FilterChip(
            key: ValueKey('event-weekday-$i'),
            label: Text(weekdayShortKo(i)),
            selected: _weekdays.contains(i),
            showCheckmark: false,
            onSelected: (on) => _change(() {
              _weekdaysTouched = true;
              if (on) {
                _weekdays.add(i);
              } else {
                _weekdays.remove(i);
              }
            }),
          ),
      ],
    ),
  ];

  List<Widget> _customRepeat(ThemeData theme) {
    const freqLabels = {
      'daily': '일',
      'weekly': '주',
      'monthly': '개월',
      'yearly': '년',
    };
    return [
      const SizedBox(height: 10),
      Row(
        children: [
          const Text('반복 주기'),
          const SizedBox(width: 12),
          SizedBox(
            width: 64,
            child: TextField(
              key: const ValueKey('event-interval'),
              controller: _interval,
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
          const SizedBox(width: 8),
          DropdownButton<String>(
            key: const ValueKey('event-custom-freq'),
            value: _customFreq,
            onChanged: (v) {
              if (v != null) _change(() => _customFreq = v);
            },
            items: [
              for (final entry in freqLabels.entries)
                DropdownMenuItem(
                  value: entry.key,
                  child: Text('${entry.value}마다'),
                ),
            ],
          ),
        ],
      ),
      if (_customFreq == 'weekly') ..._weekdayChips(),
      const SizedBox(height: 10),
      Row(
        children: [
          const Text('종료'),
          const SizedBox(width: 12),
          DropdownButton<_RepeatEnd>(
            key: const ValueKey('event-repeat-end'),
            value: _repeatEnd,
            onChanged: (v) {
              if (v != null) _change(() => _repeatEnd = v);
            },
            items: const [
              DropdownMenuItem(value: _RepeatEnd.never, child: Text('종료 없음')),
              DropdownMenuItem(value: _RepeatEnd.until, child: Text('날짜')),
              DropdownMenuItem(value: _RepeatEnd.count, child: Text('횟수')),
            ],
          ),
          const SizedBox(width: 12),
          if (_repeatEnd == _RepeatEnd.until)
            Flexible(
              child: DateDropButton(
                key: const ValueKey('event-until'),
                value: _until,
                allowClear: false,
                onPicked: (d) {
                  if (d != null) _change(() => _until = d);
                },
                child: Container(
                  height: 40,
                  alignment: Alignment.centerLeft,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    border: Border.all(color: theme.colorScheme.outline),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(formatScheduleDate(_until)),
                ),
              ),
            ),
          if (_repeatEnd == _RepeatEnd.count) ...[
            SizedBox(
              width: 72,
              child: TextField(
                key: const ValueKey('event-count'),
                controller: _count,
                keyboardType: TextInputType.number,
                textAlign: TextAlign.center,
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(width: 6),
            const Text('회'),
          ],
        ],
      ),
    ];
  }
}
