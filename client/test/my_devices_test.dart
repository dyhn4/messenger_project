// "로그인한 기기"(my_devices_dialog.dart) — 서버 GET/DELETE /api/devices·POST /api/devices/logout-others를 가짜 HTTP로 흉내 내고
// 목록(이 기기 맨 위·로그아웃시킨 기기 감춤)·기기 로그아웃·다른 모든 기기 로그아웃(새 토큰으로 바꿈)을 본다.
import 'dart:convert';

import 'package:client/models/my_device.dart';
import 'package:client/screens/my_devices_dialog.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

http.Response _json(Object? body, {int status = 200}) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

Map<String, dynamic> _device(
  String id, {
  String? kind,
  bool current = false,
  bool revoked = false,
  bool online = false,
  int lastSeenDaysAgo = 0,
}) => {
  'id': id,
  'name': 'x',
  'kind': kind,
  'createdAt': DateTime(2026, 9, 1).millisecondsSinceEpoch,
  'lastSeenAt': DateTime(
    2026,
    10,
    17,
  ).subtract(Duration(days: lastSeenDaysAgo)).millisecondsSinceEpoch,
  'revoked': revoked,
  'current': current,
  'online': online,
};

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('모델', () {
    test('종류별 이름, 이 기기 맨 위·나머지는 최근 순, 로그아웃시킨 기기는 감춘다', () {
      final list = activeDevicesFirstCurrent([
        MyDevice.fromJson(_device('old', kind: 'android', lastSeenDaysAgo: 9)),
        MyDevice.fromJson(_device('gone', kind: 'web-desktop', revoked: true)),
        MyDevice.fromJson(_device('new', kind: 'web-mobile')),
        MyDevice.fromJson(
          _device('me', kind: 'windows', lastSeenDaysAgo: 30),
          currentId: 'me',
        ),
      ]);
      expect(list.map((d) => d.id), ['me', 'new', 'old']);
      expect(list.first.current, isTrue, reason: '서버가 몰라도 앱이 아는 기기 id로');
      expect(list.map((d) => d.label), [
        'Windows PC',
        '휴대폰·태블릿 웹 브라우저',
        'Android 앱',
      ]);
      expect(MyDevice.fromJson(_device('x')).label, 'x', reason: '종류를 모르면 이름');
    });
  });

  group('대화상자', () {
    late List<http.Request> requests;
    late List<Map<String, dynamic>> devices;
    late Session session;

    setUp(() async {
      requests = [];
      devices = [
        _device('pc', kind: 'windows', current: true, online: true),
        _device('phone', kind: 'android', lastSeenDaysAgo: 2),
        _device('web', kind: 'web-desktop', lastSeenDaysAgo: 5),
      ];
      session = Session(
        notifications: NotificationService(),
        settings: AppSettings(),
      );
      await session.init();
      session.serverUrl = null; // 소켓은 다시 붙이지 않는다.
      session.token = 'old-access';
      session.refreshToken = 'old-refresh';
      session.api = ApiClient(
        baseUrl: 'https://test.local',
        token: 'old-access',
        httpClient: MockClient((request) async {
          requests.add(request);
          final path = request.url.path;
          if (request.method == 'GET' && path == '/api/devices') {
            return _json(devices);
          }
          if (request.method == 'DELETE' && path.startsWith('/api/devices/')) {
            final id = path.substring('/api/devices/'.length);
            devices = [
              for (final d in devices)
                d['id'] == id ? {...d, 'revoked': true} : d,
            ];
            return _json({'ok': true});
          }
          if (request.method == 'POST' &&
              path == '/api/devices/logout-others') {
            devices = [
              for (final d in devices)
                d['current'] == true ? d : {...d, 'revoked': true},
            ];
            return _json({
              'accessToken': 'new-access',
              'refreshToken': 'new-refresh',
              'revokedCount': 2,
            });
          }
          return _json({'error': 'no route'}, status: 404);
        }),
      );
    });

    Future<void> open(WidgetTester tester) async {
      tester.view.physicalSize = const Size(900, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: MyDevicesDialog(session: session))),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('목록 — 이 기기·사용 중 표시, 기기마다 로그아웃 단추', (tester) async {
      await open(tester);
      expect(find.text('Windows PC'), findsOneWidget);
      expect(find.text('이 기기 · 사용 중'), findsOneWidget);
      expect(find.text('Android 앱'), findsOneWidget);
      expect(find.text('PC 웹 브라우저'), findsOneWidget);
      expect(find.byKey(const ValueKey('my-device-logout-phone')), findsOne);
      expect(find.textContaining('(2대)'), findsOneWidget);
    });

    testWidgets('다른 기기를 로그아웃시키면 확인 뒤 DELETE하고 목록에서 빠진다', (tester) async {
      await open(tester);
      await tester.tap(find.byKey(const ValueKey('my-device-logout-phone')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('my-devices-confirm')));
      await tester.pumpAndSettle();
      expect(
        requests.where((r) => r.method == 'DELETE').single.url.path,
        '/api/devices/phone',
      );
      expect(find.text('Android 앱'), findsNothing);
      expect(session.token, 'old-access', reason: '이 기기는 그대로');
      await tester.pump(const Duration(seconds: 5)); // 토스트가 사라지도록.
    });

    testWidgets('다른 모든 기기에서 로그아웃 — 새 토큰으로 바꾸고 이 기기만 남는다', (tester) async {
      await open(tester);
      await tester.tap(find.byKey(const ValueKey('my-devices-logout-others')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('my-devices-confirm')));
      await tester.pumpAndSettle();
      expect(session.token, 'new-access');
      expect(session.refreshToken, 'new-refresh');
      expect(session.api!.token, 'new-access');
      expect(find.text('Android 앱'), findsNothing);
      expect(find.text('PC 웹 브라우저'), findsNothing);
      expect(find.text('Windows PC'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('확인 창에서 취소하면 아무것도 보내지 않는다', (tester) async {
      await open(tester);
      await tester.tap(find.byKey(const ValueKey('my-device-logout-web')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('취소'));
      await tester.pumpAndSettle();
      expect(requests.where((r) => r.method != 'GET'), isEmpty);
    });
  });
}
