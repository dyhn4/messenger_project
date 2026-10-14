import 'package:client/services/app_settings.dart';
import 'package:client/services/network_type.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:client/widgets/data_usage_warning.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  late Session session;

  setUp(() {
    session = Session(
      notifications: NotificationService(),
      settings: AppSettings(),
    );
  });
  tearDown(() => debugIsOnCellularOverride = null);

  const big = kCellularDownloadWarnBytes;

  /// [items]로 확인을 받는 버튼 하나짜리 화면을 띄우고 누른다 — 결과는 [result]에 담긴다.
  Future<List<bool>> pump(
    WidgetTester tester,
    List<DownloadSizeItem> items,
  ) async {
    final result = <bool>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => result.add(
              await confirmCellularDownload(
                context,
                session: session,
                items: items,
              ),
            ),
            child: const Text('받기'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('받기'));
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('Wi-Fi면 큰 파일도 묻지 않는다', (tester) async {
    debugIsOnCellularOverride = false;
    final result = await pump(tester, [(url: 'u', size: big * 10)]);
    expect(find.text('데이터 사용 경고'), findsNothing);
    expect(result, [true]);
  });

  testWidgets('휴대폰 데이터라도 작은 파일은 묻지 않는다', (tester) async {
    debugIsOnCellularOverride = true;
    final result = await pump(tester, [(url: 'u', size: big - 1)]);
    expect(find.text('데이터 사용 경고'), findsNothing);
    expect(result, [true]);
  });

  testWidgets('휴대폰 데이터로 큰 파일 — 경고를 띄우고 확인을 눌러야 받는다', (tester) async {
    debugIsOnCellularOverride = true;
    final result = await pump(tester, [(url: 'u', size: big)]);
    expect(find.text('데이터 사용 경고'), findsOneWidget);
    expect(result, isEmpty);
    await tester.tap(find.text('확인'));
    await tester.pumpAndSettle();
    expect(result, [true]);
  });

  testWidgets('경고에서 취소하면 받지 않는다', (tester) async {
    debugIsOnCellularOverride = true;
    final result = await pump(tester, [(url: 'u', size: big)]);
    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();
    expect(result, [false]);
  });

  testWidgets('여러 파일은 합계로 판단하고, 크기를 모르면 서버에 물어본다(HEAD)', (tester) async {
    debugIsOnCellularOverride = true;
    final heads = <String>[];
    final client = MockClient((req) async {
      heads.add('${req.method} ${req.url.path}');
      return http.Response(
        '',
        200,
        headers: {'content-length': '${big ~/ 2}'},
      );
    });
    late List<bool> result;
    await http.runWithClient(
      () async => result = await pump(tester, [
        (url: 'https://test.local/files/a', size: null),
        (url: 'https://test.local/files/b', size: big ~/ 2),
      ]),
      () => client,
    );
    expect(heads, ['HEAD /files/a']);
    expect(find.textContaining('파일 2개'), findsOneWidget);
    await tester.tap(find.text('확인'));
    await tester.pumpAndSettle();
    expect(result, [true]);
  });
}
