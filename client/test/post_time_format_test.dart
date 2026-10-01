import 'package:client/services/time_format.dart';
import 'package:flutter_test/flutter_test.dart';

/// 보드 뷰 토픽의 게시글·댓글과 토픽 공지가 쓰는 작성 시각 — "2026/10/01 AM 3:44".
void main() {
  group('formatPostDateTime', () {
    test('자정은 AM 12:00, 정오는 PM 12:00', () {
      expect(formatPostDateTime(DateTime(2026, 10, 1)), '2026/10/01 AM 12:00');
      expect(
        formatPostDateTime(DateTime(2026, 10, 1, 12)),
        '2026/10/01 PM 12:00',
      );
    });

    test('시는 한 자리 그대로(0 채움 없음), 분은 항상 두 자리', () {
      expect(
        formatPostDateTime(DateTime(2026, 10, 1, 3, 44)),
        '2026/10/01 AM 3:44',
      );
      expect(
        formatPostDateTime(DateTime(2026, 10, 1, 3, 4)),
        '2026/10/01 AM 3:04',
      );
      expect(
        formatPostDateTime(DateTime(2026, 10, 1, 9, 0)),
        '2026/10/01 AM 9:00',
      );
      expect(
        formatPostDateTime(DateTime(2026, 10, 1, 12, 5)),
        '2026/10/01 PM 12:05',
      );
      expect(
        formatPostDateTime(DateTime(2026, 10, 1, 0, 5)),
        '2026/10/01 AM 12:05',
      );
    });

    test('오후는 12시간제로 — 13시는 PM 1:00, 23:59는 PM 11:59', () {
      expect(
        formatPostDateTime(DateTime(2026, 10, 1, 13)),
        '2026/10/01 PM 1:00',
      );
      expect(
        formatPostDateTime(DateTime(2026, 10, 1, 16, 42)),
        '2026/10/01 PM 4:42',
      );
      expect(
        formatPostDateTime(DateTime(2026, 10, 1, 23, 59)),
        '2026/10/01 PM 11:59',
      );
    });

    test('날짜는 yyyy/MM/dd — 월·일은 0 채움', () {
      expect(
        formatPostDateTime(DateTime(2022, 7, 5, 16, 42)),
        '2022/07/05 PM 4:42',
      );
      expect(
        formatPostDateTime(DateTime(2026, 12, 31, 8, 8)),
        '2026/12/31 AM 8:08',
      );
    });

    test('채팅 쪽 표기는 그대로 — formatRoomActivityTime은 따로 둔다', () {
      final old = DateTime(2020, 1, 2, 3, 4);
      expect(formatRoomActivityTime(old), '2020/01/02');
      expect(formatPostDateTime(old), isNot(formatRoomActivityTime(old)));
    });
  });
}
