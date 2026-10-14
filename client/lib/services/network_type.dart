import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:flutter/services.dart';

import 'app_platform.dart';
import 'network_type_stub.dart'
    if (dart.library.js_interop) 'network_type_web.dart';

/// MainActivity.kt와 짝을 이루는 채널(지금 쓰는 망이 휴대폰 데이터인지).
const _channel = MethodChannel('tangotalk/network');

/// 테스트가 연결 종류를 정해 두는 자리 — null이면 실제로 알아본다.
@visibleForTesting
bool? debugIsOnCellularOverride;

/// 지금 Wi-Fi가 아니라 휴대폰 데이터(LTE·5G 등)로 인터넷을 쓰고 있는지 — 큰 첨부를 받기 전에 데이터
/// 사용 경고를 띄울지 정하는 데 쓴다(data_usage_warning.dart).
///
/// 안드로이드는 OS에 묻고, 웹은 브라우저가 알려 주는 연결 종류(navigator.connection.type — 안드로이드
/// 크롬 등)를 본다. 알 수 없으면(PC, 아이폰 Safari처럼 연결 종류를 알려 주지 않는 브라우저, 채널 오류)
/// false — 경고 없이 그냥 받는다.
Future<bool> isOnCellularData() async {
  final override = debugIsOnCellularOverride;
  if (override != null) return override;
  if (kIsWeb) return webConnectionIsCellular;
  if (!AppPlatform.isAndroid) return false;
  try {
    return await _channel.invokeMethod<bool>('isCellular') ?? false;
  } catch (_) {
    return false;
  }
}
