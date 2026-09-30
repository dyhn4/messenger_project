import 'package:flutter/material.dart';

import '../../models/calendar.dart';
import '../../services/calendar_controller.dart';
import '../../services/calendar_layout.dart' show weekStartOf;
import '../../services/time_format.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/avatar_utils.dart' show parseHexColor;

/// 캘린더 화면 전체가 같이 쓰는 작은 조각들 — 보기 종류, 색 팔레트, 날짜·기간 문구, 관리 훅.

/// 보기 4가지.
enum CalendarViewMode {
  month('월간'),
  week('주간'),
  day('일간'),
  list('목록');

  const CalendarViewMode(this.label);
  final String label;
}

/// 캘린더·일정 색 팔레트('#RRGGBB') — 캘린더 색 변경, 일정 색 고르기, 새 캘린더 만들기가 같이 쓴다.
const calendarPalette = <String>[
  '#E53935', // 빨강
  '#F06292', // 분홍
  '#FB8C00', // 주황
  '#F9A825', // 노랑
  '#7CB342', // 연두
  '#43A047', // 초록
  '#00897B', // 청록
  '#039BE5', // 하늘
  '#1E88E5', // 파랑
  '#3949AB', // 남색
  '#8E24AA', // 보라
  '#6D4C41', // 갈색
  '#757575', // 회색
  '#546E7A', // 청회색
];

/// '#RRGGBB' → Color. 잘못된 값이면 기본 파랑.
Color calendarColor(String? hex) {
  try {
    return parseHexColor(hex) ?? const Color(0xFF4285F4);
  } catch (_) {
    return const Color(0xFF4285F4);
  }
}

/// [background] 위에 올릴 글자색 — 밝은 색 막대에서는 검정, 진한 색에서는 흰색.
Color onCalendarColor(Color background) =>
    ThemeData.estimateBrightnessForColor(background) == Brightness.dark
    ? Colors.white
    : Colors.black87;

/// 일요일·공휴일 빨강, 토요일 파랑 — 날짜 숫자 색.
const kSundayColor = Color(0xFFE53935);
const kSaturdayColor = Color(0xFF1E88E5);

/// "2026년 9월" (월간·목록 제목).
String formatMonthTitle(DateTime d) => '${d.year}년 ${d.month}월';

/// "9월 30일 (수)" — [formatScheduleDate]는 올해가 아니면 앞에 연도를 붙인다.
String formatDayLabel(DateTime d) => formatScheduleDate(d);

/// 보기별 상단 제목 — 월간·목록은 "2026년 9월", 주간은 "2026년 9월 27일 – 10월 3일", 일간은 "2026년 9월 30일 (수)".
String formatViewTitle(CalendarViewMode mode, DateTime focused) {
  switch (mode) {
    case CalendarViewMode.month:
    case CalendarViewMode.list:
      return formatMonthTitle(focused);
    case CalendarViewMode.week:
      final s = weekStartOf(focused);
      final e = addDays(s, 6);
      final endText = e.year != s.year
          ? '${e.year}년 ${e.month}월 ${e.day}일'
          : e.month != s.month
          ? '${e.month}월 ${e.day}일'
          : '${e.day}일';
      return '${s.year}년 ${s.month}월 ${s.day}일 – $endText';
    case CalendarViewMode.day:
      return '${focused.year}년 ${formatScheduleDate(focused, now: focused)}';
  }
}

/// 일정 기간 문구 — "9월 30일 (수) 오전 10:00 – 오전 11:00" / "… · 종일" / 여러 날은 양쪽 날짜를 다 적는다.
String formatEventPeriod(EventOccurrence e) {
  final first = e.firstDay;
  final last = e.lastDay;
  if (e.isHoliday || e.isBirthday) return formatDayLabel(first);
  if (e.allDay) {
    if (!e.isMultiDay) return '${formatDayLabel(first)} · 종일';
    return '${formatDayLabel(first)} – ${formatDayLabel(last)} · 종일';
  }
  final s = e.startTime;
  final en = e.endTime;
  if (!e.isMultiDay) {
    return '${formatDayLabel(first)} ${formatScheduleClock(s)} – ${formatScheduleClock(en)}';
  }
  return '${formatDayLabel(first)} ${formatScheduleClock(s)} – ${formatDayLabel(last)} ${formatScheduleClock(en)}';
}

/// 목록·하루 일정 줄 앞에 붙는 시간 문구 — 종일/여러 날은 "종일", 시간 일정은 시작 시각.
String formatEventTimeShort(EventOccurrence e, {DateTime? onDay}) {
  if (e.allDay || e.isBirthday || e.isHoliday) return '종일';
  if (onDay != null && e.isMultiDay && !sameDay(e.firstDay, onDay)) {
    return '계속';
  }
  return formatScheduleClock(e.startTime);
}

/// 보이는 제목 — 비공개는 서버가 이미 "비공개 일정"으로 바꿔 주지만, 혹시 비어 있으면 같은 문구로.
String eventDisplayTitle(EventOccurrence e) =>
    e.restricted && e.title.trim().isEmpty ? '비공개 일정' : e.title;

/// 캘린더 관리 화면(새 캘린더·설정·멤버·구독 검색·삭제)을 붙이는 자리.
///
/// 캘린더 화면은 목록의 "+"/"⋯" 메뉴가 눌리면 여기 콜백을 부를 뿐이다. 실제 대화상자는
/// management/calendar_management.dart의 `buildCalendarManagementHooks(session)`가 만들며, 화면에 훅을
/// 따로 안 넘기고 [current]도 비어 있으면 CalendarScreen이 그것을 기본으로 쓴다. 콜백이 null이면
/// (테스트 등에서 일부만 연결한 경우) "아직 연결되지 않았다"는 토스트만 띄운다. 앱 전체 기본값을 바꾸려면
/// [CalendarManagementHooks.current]를 지정하고, 화면마다 다르게 하려면 CalendarScreen(hooks: …)로 넘긴다.
/// 각 콜백이 끝나면 목록은 [CalendarController]가 알아서 다시 받는다(createCalendar 등이 loadCalendars를 부른다).
class CalendarManagementHooks {
  /// "나의 캘린더" 옆 + — 새 캘린더 만들기.
  final Future<void> Function(
    BuildContext context,
    CalendarController controller,
  )?
  onCreateCalendar;

  /// "구독 캘린더" 옆 + — 구독할 캘린더 검색.
  final Future<void> Function(
    BuildContext context,
    CalendarController controller,
  )?
  onSearchSubscribe;

  /// ⋯ 메뉴 "캘린더 설정" — 이름·공개 여부·멤버.
  final Future<void> Function(
    BuildContext context,
    CalendarController controller,
    CalendarInfo calendar,
  )?
  onOpenSettings;

  /// ⋯ 메뉴 "구독 취소" / "나에게만 삭제" — 캘린더의 [CalendarInfo.isSubscriber]로 문구가 갈린다.
  final Future<void> Function(
    BuildContext context,
    CalendarController controller,
    CalendarInfo calendar,
  )?
  onLeave;

  /// ⋯ 메뉴 "삭제" — 소유자만(CalendarInfo.canDelete).
  final Future<void> Function(
    BuildContext context,
    CalendarController controller,
    CalendarInfo calendar,
  )?
  onDelete;

  const CalendarManagementHooks({
    this.onCreateCalendar,
    this.onSearchSubscribe,
    this.onOpenSettings,
    this.onLeave,
    this.onDelete,
  });

  /// 화면에 hooks를 따로 안 넘겼을 때 쓰는 앱 전체 기본값. null이면 CalendarScreen이 세션에 연결한
  /// 기본 관리 훅을 만들어 쓴다(그래서 평소엔 건드릴 일이 없다).
  static CalendarManagementHooks? current;

  /// 연결 안 된 동작을 눌렀을 때의 안내.
  static void notConnected(BuildContext context, String what) =>
      showAppToast(context, '$what 기능은 아직 연결되지 않았습니다.');
}

/// 색 고르기 — 팔레트를 격자로 보여 주고 고른 색('#RRGGBB')을 돌려준다. 취소하면 null.
Future<String?> showCalendarColorPicker(
  BuildContext context, {
  required String current,
  String title = '색 변경',
}) {
  return showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 300,
        child: CalendarColorGrid(
          selected: current,
          onSelected: (hex) => Navigator.of(dialogContext).pop(hex),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('취소'),
        ),
      ],
    ),
  );
}

/// 팔레트 색 격자 — 고른 색에는 체크 표시가 붙는다.
class CalendarColorGrid extends StatelessWidget {
  final String? selected;
  final ValueChanged<String> onSelected;
  final double size;
  const CalendarColorGrid({
    super.key,
    required this.selected,
    required this.onSelected,
    this.size = 32,
  });

  @override
  Widget build(BuildContext context) {
    final sel = selected?.toUpperCase();
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        for (final hex in calendarPalette)
          Semantics(
            button: true,
            selected: sel == hex,
            label: '색 $hex',
            child: InkWell(
              key: ValueKey('cal-color-$hex'),
              customBorder: const CircleBorder(),
              onTap: () => onSelected(hex),
              child: Container(
                width: size,
                height: size,
                decoration: BoxDecoration(
                  color: calendarColor(hex),
                  shape: BoxShape.circle,
                ),
                child: sel == hex
                    ? Icon(
                        Icons.check,
                        size: size * 0.6,
                        color: onCalendarColor(calendarColor(hex)),
                      )
                    : null,
              ),
            ),
          ),
      ],
    );
  }
}
