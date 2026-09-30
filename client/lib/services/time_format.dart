/// 그룹채팅/채팅 목록 오른쪽에 보여주는 마지막 활동 시각 — 오늘이면 "PM 02:47"처럼 시:분,
/// 그 전이면 "2026/08/28"처럼 날짜로 표시한다. room_list_screen.dart, room_picker_screen.dart
/// 둘 다 같은 규칙을 쓴다.
String formatRoomActivityTime(DateTime dt) {
  final now = DateTime.now();
  final isToday =
      dt.year == now.year && dt.month == now.month && dt.day == now.day;
  if (isToday) {
    final isPm = dt.hour >= 12;
    final hour12 = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    return '${isPm ? 'PM' : 'AM'} ${hour12.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
  return '${dt.year}/${dt.month.toString().padLeft(2, '0')}/${dt.day.toString().padLeft(2, '0')}';
}

/// "27분 전"/"3시간 전"/"5일 전"처럼 상대적인 경과 시간 — 공지 상세보기(작성자/시간 표시)에서
/// 쓴다. 7일이 넘으면(오래된 글) formatRoomActivityTime과 동일하게 절대 날짜로 바꾼다.
String formatRelativeTime(DateTime dt) {
  final diff = DateTime.now().difference(dt);
  if (diff.inSeconds < 60) return '방금 전';
  if (diff.inMinutes < 60) return '${diff.inMinutes}분 전';
  if (diff.inHours < 24) return '${diff.inHours}시간 전';
  if (diff.inDays < 7) return '${diff.inDays}일 전';
  return formatRoomActivityTime(dt);
}

/// "2026/09/09 14:32"처럼 날짜와 시각을 함께 — 감사 로그/운영 현황처럼 언제였는지가 정확히
/// 중요한 화면에서 쓴다(formatRoomActivityTime은 오늘이면 시각만 보여줘서 로그엔 부적합).
String formatDateTime(DateTime dt) {
  final date =
      '${dt.year}/${dt.month.toString().padLeft(2, '0')}/${dt.day.toString().padLeft(2, '0')}';
  final time =
      '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  return '$date $time';
}

const _koreanWeekdays = ['월', '화', '수', '목', '금', '토', '일'];

/// 예약 메시지의 날짜 — "10월 2일 (목)". 올해가 아니면 앞에 "2027년 "을 붙인다(90일 뒤까지라
/// 해를 넘길 수 있다).
String formatScheduleDate(DateTime dt, {DateTime? now}) {
  final thisYear = (now ?? DateTime.now()).year;
  final year = dt.year == thisYear ? '' : '${dt.year}년 ';
  return '$year${dt.month}월 ${dt.day}일 (${_koreanWeekdays[dt.weekday - 1]})';
}

/// 예약 메시지의 시각 — "오전 9:00"/"오후 12:30"(15분 단위 시간 목록도 이 모양).
String formatScheduleClock(DateTime dt) {
  final hour12 = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
  final minute = dt.minute.toString().padLeft(2, '0');
  return '${dt.hour < 12 ? '오전' : '오후'} $hour12:$minute';
}

/// 예약 메시지 목록·토스트에 쓰는 발송 시각 — "10월 2일 (목) 오전 9:00".
String formatScheduleTime(DateTime dt, {DateTime? now}) =>
    '${formatScheduleDate(dt, now: now)} ${formatScheduleClock(dt)}';
