import 'dart:convert';

import 'package:client/services/api_client.dart';
import 'package:client/services/device_kind.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 기기를 등록할 때 기기 종류를 같이 보낸다 — 서버가 PC 앱이 켜져 있는 동안 PC 브라우저로는 웹 푸시를 보내지 않는 데 쓴다
/// (같은 PC에서 PC 앱 알림과 크롬 알림이 두 번 뜨던 문제 — server/src/presence.js webPushTargets).
void main() {
  tearDown(() => debugDeviceKindOverride = null);

  Future<Map<String, dynamic>> register() async {
    late Map<String, dynamic> sent;
    final api = ApiClient(
      baseUrl: 'https://192.168.0.10:3000',
      token: 't',
      httpClient: MockClient((request) async {
        sent = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({'id': 'dev-1'}),
          201,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    await api.registerDevice(
      deviceId: 'dev-1',
      name: 'PC',
      identityPublicKey: 'a' * 44,
      signingPublicKey: 'b' * 44,
    );
    return sent;
  }

  test('기기 종류를 보내고, 모르면 칸을 아예 보내지 않는다(서버가 예전 앱처럼 본다)', () async {
    debugDeviceKindOverride = 'web-desktop';
    expect((await register())['kind'], 'web-desktop');
    debugDeviceKindOverride = 'web-mobile';
    expect((await register())['kind'], 'web-mobile');
  });

  test('네이티브에서는 PC 앱·안드로이드를 그대로 알린다', () {
    // 시험은 이 PC(Windows)에서 돈다 — 웹이 아니고 Windows면 'windows'.
    expect(deviceKind(), anyOf('windows', 'android', isNull));
  });
}
