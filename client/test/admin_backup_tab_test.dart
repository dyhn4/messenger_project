import 'dart:convert';

import 'package:client/screens/admin_backup_tab.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 관리자 콘솔 "백업" 탭 — 상태·경고·목록을 보여 주고, 예약 설정은 그냥, 백업 암호·외부 위치는 운영자 비밀번호를 다시 받아
/// 저장하고, "지금 백업" 뒤에는 끝날 때까지 진행 상황을 다시 받는다. 이 기능이 없는 예전 서버(404)면 업데이트하라고 한다.
void main() {
  const serverUrl = 'https://192.168.0.10:3000';
  const jsonHeaders = {'content-type': 'application/json; charset=utf-8'};
  final success = DateTime(2026, 10, 14, 3, 0);
  final next = DateTime(2026, 10, 15, 3, 0);

  Map<String, dynamic> view({
    bool passwordConfigured = true,
    String? destination = r'E:\TangoTalk백업',
    String? result = 'ok',
    String? error,
    bool running = false,
    List<String> warnings = const [],
    bool fromServerPc = false,
  }) => {
    'enabled': true,
    'hour': 3,
    'keep': 14,
    'keepMin': 3,
    'keepMax': 60,
    'passwordMin': 8,
    'destination': destination,
    'passwordConfigured': passwordConfigured,
    'passwordError': null,
    'localDir': r'C:\TangoTalk-Server\backups',
    'fromServerPc': fromServerPc,
    'run': {
      'running': running,
      'elsewhere': false,
      'kind': running ? 'manual' : null,
      'phase': running ? '첨부파일 복사 중' : null,
      'progress': running ? {'done': 40, 'total': 100} : null,
    },
    'status': {
      'lastAttemptAt': result == null ? null : success.millisecondsSinceEpoch,
      'lastSuccessAt': result == 'failed' || result == null
          ? null
          : success.millisecondsSinceEpoch,
      'result': result,
      'error': error,
      'lastBackup': result == null
          ? null
          : {'name': 'tangotalk_20261014_030000', 'bytes': 5 * 1024 * 1024},
      'external': destination == null || result == null
          ? null
          : {
              'path': destination,
              'ok': result == 'ok',
              'error': result == 'partial' ? error : null,
              'uploads': {
                'total': 1234,
                'copied': 3,
                'bytes': 2 * 1024 * 1024 * 1024,
              },
            },
    },
    'nextRunAt': passwordConfigured ? next.millisecondsSinceEpoch : null,
    'warnings': warnings,
    'backups': result == null
        ? []
        : [
            {
              'name': 'tangotalk_20261014_030000',
              'createdAt': success.millisecondsSinceEpoch,
              'kind': 'scheduled',
              'bytes': 5 * 1024 * 1024,
            },
          ],
  };

  late List<http.Request> requests;
  late List<Map<String, dynamic>> getQueue;
  late Map<String, dynamic> Function(Map<String, dynamic> body) patchResponse;
  late Map<String, dynamic> runResponse;

  Session buildSession() {
    final client = MockClient((request) async {
      requests.add(request);
      final path = request.url.path;
      if (path == '/api/admin/backup' && request.method == 'GET') {
        final body = getQueue.length > 1
            ? getQueue.removeAt(0)
            : getQueue.first;
        return http.Response(jsonEncode(body), 200, headers: jsonHeaders);
      }
      if (path == '/api/admin/backup' && request.method == 'PATCH') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode(patchResponse(body)),
          200,
          headers: jsonHeaders,
        );
      }
      if (path == '/api/admin/backup/run') {
        return http.Response(
          jsonEncode(runResponse),
          200,
          headers: jsonHeaders,
        );
      }
      return http.Response('', 404, headers: {'content-type': 'text/html'});
    });
    final session = Session(
      notifications: NotificationService(),
      settings: AppSettings(),
    );
    session.serverUrl = serverUrl;
    session.api = ApiClient(baseUrl: serverUrl, token: 't', httpClient: client);
    session.userId = 'u1';
    session.isServerAdmin = true;
    return session;
  }

  setUp(() {
    requests = [];
    getQueue = [view()];
    patchResponse = (_) => view();
    runResponse = view(running: true);
  });

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AdminBackupTab(session: buildSession())),
      ),
    );
    await tester.pumpAndSettle();
  }

  List<Map<String, dynamic>> patches() => [
    for (final r in requests.where((r) => r.method == 'PATCH'))
      jsonDecode(r.body) as Map<String, dynamic>,
  ];
  Finder field(String label) => find.widgetWithText(TextField, label);

  testWidgets('정상이면 마지막 백업·외부 위치·다음 예약과 목록을 보여 준다', (tester) async {
    await pump(tester);
    expect(find.textContaining('정상'), findsOneWidget);
    expect(find.text('마지막 백업: 2026/10/14 03:00 · 5.0MB'), findsOneWidget);
    expect(
      find.text(r'외부 위치: E:\TangoTalk백업 — 첨부파일 1234개(2.0GB)'),
      findsOneWidget,
    );
    expect(find.text('다음 자동 백업: 2026/10/15 03:00'), findsOneWidget);
    expect(find.text('tangotalk_20261014_030000'), findsOneWidget);
    expect(find.text('자동 · 5.0MB'), findsOneWidget);
    expect(
      tester.widget<TextField>(field('외부 백업 위치')).controller!.text,
      r'E:\TangoTalk백업',
    );
  });

  testWidgets('외부 위치 실패와 경고를 보여 준다', (tester) async {
    getQueue = [
      view(
        result: 'partial',
        error: '외부 백업 위치를 찾을 수 없습니다',
        warnings: ['외부 백업 위치가 서버와 같은 드라이브에 있습니다'],
      ),
    ];
    await pump(tester);
    expect(find.textContaining('일부 실패'), findsOneWidget);
    expect(find.text('외부 위치 복사 실패: 외부 백업 위치를 찾을 수 없습니다'), findsOneWidget);
    expect(find.text('외부 백업 위치가 서버와 같은 드라이브에 있습니다'), findsOneWidget);
  });

  testWidgets('암호가 없으면 "설정 필요" — 지금 백업은 막고, 암호를 정할 때 두 번 입력과 계정 비밀번호를 받는다', (
    tester,
  ) async {
    getQueue = [
      view(passwordConfigured: false, result: null, destination: null),
    ];
    patchResponse = (_) => view();
    await pump(tester);
    expect(find.textContaining('설정 필요'), findsOneWidget);
    final runButton = tester.widget<FilledButton>(
      find.ancestor(
        of: find.text('지금 백업'),
        matching: find.byType(FilledButton),
      ),
    );
    expect(runButton.onPressed, isNull);

    await tester.tap(find.text('암호 정하기'));
    await tester.pumpAndSettle();
    await tester.enterText(field('새 백업 암호'), 'backup-pass-1');
    await tester.enterText(field('새 백업 암호 확인'), 'backup-pass-2');
    await tester.enterText(field('내 계정 비밀번호'), 'my-login');
    await tester.tap(find.widgetWithText(FilledButton, '저장').last);
    await tester.pump();
    expect(find.text('두 칸의 암호가 다릅니다.'), findsOneWidget);
    expect(patches(), isEmpty);

    await tester.enterText(field('새 백업 암호 확인'), 'backup-pass-1');
    await tester.tap(find.widgetWithText(FilledButton, '저장').last);
    await tester.pumpAndSettle();
    expect(patches().single, {
      'password': 'backup-pass-1',
      'accountPassword': 'my-login',
    });
    expect(find.textContaining('매일 3시에 백업합니다'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('예약 설정은 계정 비밀번호 없이 저장한다', (tester) async {
    await pump(tester);
    await tester.tap(find.text('매일 자동으로 백업'));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '저장'));
    await tester.pumpAndSettle();
    expect(patches().single, {'enabled': false, 'hour': 3, 'keep': 14});
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('외부 위치는 바뀌었을 때만, 계정 비밀번호를 받은 뒤 저장한다', (tester) async {
    await pump(tester);
    await tester.tap(find.text('확인 후 저장'));
    await tester.pump();
    expect(find.text('바뀐 내용이 없습니다.'), findsOneWidget);
    expect(patches(), isEmpty);
    await tester.pump(const Duration(seconds: 3));

    await tester.enterText(field('외부 백업 위치'), r'F:\백업');
    await tester.tap(find.text('확인 후 저장'));
    await tester.pumpAndSettle();
    expect(find.text('외부 백업 위치 저장'), findsOneWidget);
    await tester.enterText(field('내 계정 비밀번호'), 'my-login');
    await tester.tap(find.widgetWithText(FilledButton, '확인'));
    await tester.pumpAndSettle();
    expect(patches().single, {
      'destination': r'F:\백업',
      'accountPassword': 'my-login',
    });
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('"지금 백업" 뒤에는 끝날 때까지 진행 상황을 다시 받고, 끝나면 알린다', (tester) async {
    await pump(tester);
    getQueue = [view(running: true), view()];
    await tester.tap(find.text('지금 백업'));
    await tester.pump();
    await tester.pump();
    expect(
      requests.where((r) => r.url.path == '/api/admin/backup/run'),
      hasLength(1),
    );
    expect(find.text('첨부파일 복사 중 (40/100)'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(find.text('첨부파일 복사 중 (40/100)'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(find.text('백업했습니다.'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    final gets = requests.where((r) => r.method == 'GET').length;
    await tester.pump(const Duration(seconds: 6));
    expect(
      requests.where((r) => r.method == 'GET').length,
      gets,
      reason: '끝나면 더 받지 않는다',
    );
  });

  testWidgets('예전 서버(404)면 업데이트하라고 한다', (tester) async {
    tester.view.physicalSize = const Size(1000, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final session = Session(
      notifications: NotificationService(),
      settings: AppSettings(),
    );
    session.serverUrl = serverUrl;
    session.api = ApiClient(
      baseUrl: serverUrl,
      token: 't',
      httpClient: MockClient(
        (_) async =>
            http.Response('', 404, headers: {'content-type': 'text/html'}),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AdminBackupTab(session: session)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('서버를 업데이트하세요'), findsOneWidget);
  });
}
