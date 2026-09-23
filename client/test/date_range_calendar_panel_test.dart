import 'package:client/widgets/date_range_calendar_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);

  /// 오늘 칸의 동그라미 색 — 표시가 없으면 null.
  Color? todayCircleColor(WidgetTester tester) {
    final containers = tester.widgetList<Container>(
      find.descendant(
        of: find.ancestor(
          of: find.text('${today.day}'),
          matching: find.byType(InkWell),
        ),
        matching: find.byType(Container),
      ),
    );
    for (final c in containers) {
      final d = c.decoration;
      if (d is BoxDecoration && d.shape == BoxShape.circle) return d.color;
    }
    return null;
  }

  Future<void> pump(
    WidgetTester tester, {
    required DateTime? start,
    required DateTime? end,
    required void Function(DateTime?, DateTime?) onChanged,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            child: DateRangeCalendarPanel(
              start: start,
              end: end,
              onChanged: onChanged,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('달력을 열면 오늘이 회색 동그라미로 표시된다', (tester) async {
    await pump(tester, start: null, end: null, onChanged: (_, _) {});
    final color = todayCircleColor(tester);
    expect(color, isNotNull, reason: '오늘 칸에 동그라미 표시가 없습니다');
    // 고른 날(검은색)과 구분되는 회색이어야 한다.
    expect(color, isNot(Colors.black87));
    expect(color!.a, lessThan(1.0));
  });

  testWidgets('오늘을 시작일로 고르면 회색 대신 검은 동그라미가 된다', (tester) async {
    await pump(tester, start: today, end: null, onChanged: (_, _) {});
    expect(todayCircleColor(tester), Colors.black87);
  });

  testWidgets('"오늘" 버튼을 누르면 오늘이 선택된다', (tester) async {
    DateTime? gotStart;
    DateTime? gotEnd;
    var calls = 0;
    await pump(
      tester,
      start: null,
      end: null,
      onChanged: (s, e) {
        calls++;
        gotStart = s;
        gotEnd = e;
      },
    );

    await tester.tap(find.text('오늘'));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(gotStart, today); // 비어 있었으니 시작일이 된다
    expect(gotEnd, isNull);
  });

  testWidgets('시작일이 이미 있으면 "오늘" 버튼은 마감일을 채운다', (tester) async {
    final lastWeek = today.subtract(const Duration(days: 7));
    DateTime? gotStart;
    DateTime? gotEnd;
    await pump(
      tester,
      start: lastWeek,
      end: null,
      onChanged: (s, e) {
        gotStart = s;
        gotEnd = e;
      },
    );

    await tester.tap(find.text('오늘'));
    await tester.pumpAndSettle();
    expect(gotStart, lastWeek);
    expect(gotEnd, today);
  });
}
