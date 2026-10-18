import 'dart:async';

import 'package:geolocator/geolocator.dart';

/// 기기 위치 한 번 재기(그룹웨어 출퇴근 — 외근 위치 확인·사무실과의 거리, 서버 workLocation.js). geolocator로 Android·iOS·
/// Windows(geolocator_windows)·웹에서 같은 방식으로 잰다.
///
/// 위치는 "되면 보내는" 것이라 이 서비스는 절대 던지지 않는다 — 위치 서비스가 꺼졌거나, 권한을 거절했거나, [current]의 시간 안에
/// 못 쟀거나, 플러그인이 없는 환경(테스트 등)이면 null. 출퇴근 화면은 null이면 위치 없이 보내고, 범위가 외근 위치를 필수로 했을 때만
/// 출근을 막는다(attendance_tab.dart).
///
/// 테스트는 [instance]를 가짜로 바꿔 끼운다(위치를 정해 주거나 null을 돌려주게).
class DeviceLocation {
  const DeviceLocation();

  /// 앱 전체가 쓰는 하나 — 테스트에서 바꿔 끼울 수 있다.
  static DeviceLocation instance = const DeviceLocation();

  /// 위치를 잴 수 있게 한다 — 위치 서비스가 켜져 있고, 권한이 있거나(없으면 한 번 묻고) 받았으면 true. 영영 거절(deniedForever)이면
  /// 다시 묻지 않고 false(설정에서 켜야 한다). 어떤 오류든 false.
  Future<bool> ensurePermission() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return false;
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      return permission == LocationPermission.whileInUse ||
          permission == LocationPermission.always;
    } catch (_) {
      return false;
    }
  }

  /// 지금 위치(위도·경도, 정확도 m — 모르면 null). [timeout] 안에 못 재면 null — 출퇴근 단추를 오래 붙잡지 않게 한다. 권한을 묻는
  /// 창이 떠 있는 동안도 이 시간에 든다(사람이 답하는 동안 기다리게 — 그래서 기본 8초).
  Future<({double lat, double lng, double? accuracy})?> current({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    try {
      return await _measure(timeout).timeout(timeout, onTimeout: () => null);
    } catch (_) {
      return null;
    }
  }

  Future<({double lat, double lng, double? accuracy})?> _measure(
    Duration timeout,
  ) async {
    if (!await ensurePermission()) return null;
    final position = await Geolocator.getCurrentPosition(
      locationSettings: LocationSettings(
        accuracy: LocationAccuracy.high,
        timeLimit: timeout,
      ),
    );
    return (
      lat: position.latitude,
      lng: position.longitude,
      // 정확도를 모르는 기기는 0을 준다 — 서버에 0m로 보내지 않게 없음으로.
      accuracy: position.accuracy > 0 ? position.accuracy : null,
    );
  }
}
