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
