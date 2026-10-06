import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:client/widgets/esc_to_minimize.dart';

/// ESC로 창 최소화(카카오톡 PC와 같다) — 위에 뜬 화면이나 ESC를 먼저 쓰는 위젯이 있으면 그쪽이 먼저다.
void main() {
  late int minimized;
  late GlobalKey<NavigatorState> navigatorKey;

  setUp(() {
    minimized = 0;
    navigatorKey = GlobalKey<NavigatorState>();
  });

  Widget app(Widget home) => MaterialApp(
    navigatorKey: navigatorKey,
    builder: (context, child) => EscToMinimize(
      navigatorKey: navigatorKey,
      enabled: true,
      onMinimize: () => minimized++,
      child: child!,
    ),
    home: home,
  );

  Future<void> esc(WidgetTester tester) async {
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
  }

  testWidgets('위에 뜬 것이 없으면 ESC로 최소화한다(입력칸에 포커스가 있어도)', (tester) async {
    await tester.pumpWidget(
      app(const Scaffold(body: TextField(autofocus: true))),
    );
    await esc(tester);
    expect(minimized, 1);
  });

  testWidgets('아무 데도 포커스가 없어도 ESC로 최소화한다', (tester) async {
    await tester.pumpWidget(app(const Scaffold(body: Text('빈 화면'))));
    await esc(tester);
    expect(minimized, 1);
  });

  testWidgets('대화상자가 떠 있으면 ESC는 대화상자만 닫고, 그다음 ESC에 최소화한다', (tester) async {
    await tester.pumpWidget(app(const Scaffold(body: Text('홈'))));
    showDialog<void>(
      context: navigatorKey.currentContext!,
      builder: (_) => const AlertDialog(content: Text('대화상자')),
    );
    await tester.pumpAndSettle();
    await esc(tester);
    expect(find.text('대화상자'), findsNothing);
    expect(minimized, 0);
    await esc(tester);
    expect(minimized, 1);
  });

  testWidgets('ESC로 안 닫히는 대화상자가 떠 있어도 최소화하지 않는다', (tester) async {
    await tester.pumpWidget(app(const Scaffold(body: Text('홈'))));
    showDialog<void>(
      context: navigatorKey.currentContext!,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(content: Text('닫히지 않는 대화상자')),
    );
    await tester.pumpAndSettle();
    await esc(tester);
    expect(find.text('닫히지 않는 대화상자'), findsOneWidget);
    expect(minimized, 0);
  });

  testWidgets('전체 화면 페이지가 위에 있으면 최소화하지 않는다', (tester) async {
    await tester.pumpWidget(app(const Scaffold(body: Text('홈'))));
    navigatorKey.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: TextField(autofocus: true)),
      ),
    );
    await tester.pumpAndSettle();
    await esc(tester);
    expect(minimized, 0);
  });

  testWidgets('화면 안에서 ESC를 먼저 쓰는 위젯(목록 닫기 등)이 있으면 그쪽만 처리한다', (tester) async {
    var closed = 0;
    await tester.pumpWidget(
      app(
        Scaffold(
          body: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.escape): () => closed++,
            },
            child: const TextField(autofocus: true),
          ),
        ),
      ),
    );
    await esc(tester);
    expect(closed, 1);
    expect(minimized, 0);
  });

  testWidgets('꺼져 있으면(Windows가 아니면) ESC를 건드리지 않는다', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        builder: (context, child) => EscToMinimize(
          navigatorKey: navigatorKey,
          enabled: false,
          onMinimize: () => minimized++,
          child: child!,
        ),
        home: const Scaffold(body: TextField(autofocus: true)),
      ),
    );
    await esc(tester);
    expect(minimized, 0);
  });
}
