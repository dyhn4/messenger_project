// "내 기기"(로그인한 기기 목록) 한 대 — 서버 GET /api/devices(server/src/devices.js toDeviceDto).

/// 내 계정으로 로그인한 기기 한 대.
class MyDevice {
  final String id;

  /// 운영체제 이름(windows·android·web) — 앱이 등록할 때 보낸 값.
  final String? name;

  /// 'windows' | 'android' | 'ios' | 'web-desktop' | 'web-android' | 'web-mobile' — 예전 앱은 null(모름).
  final String? kind;
  final DateTime createdAt;
  final DateTime? lastSeenAt;

  /// 로그아웃시킨 기기 — 화면은 감춘다.
  final bool revoked;

  /// 지금 이 앱이 쓰는 기기.
  final bool current;

  /// 지금 앱이 붙어 있는지(소켓 연결).
  final bool online;

  const MyDevice({
    required this.id,
    this.name,
    this.kind,
    required this.createdAt,
    this.lastSeenAt,
    this.revoked = false,
    this.current = false,
    this.online = false,
  });

  factory MyDevice.fromJson(Map<String, dynamic> j, {String? currentId}) {
    DateTime? at(Object? v) =>
        v is num ? DateTime.fromMillisecondsSinceEpoch(v.toInt()) : null;
    final id = j['id'] as String;
    return MyDevice(
      id: id,
      name: j['name'] as String?,
      kind: j['kind'] as String?,
      createdAt: at(j['createdAt']) ?? DateTime.now(),
      lastSeenAt: at(j['lastSeenAt']),
      revoked: j['revoked'] == true,
      // 서버는 이 기기에 묶인 토큰일 때만 안다 — 아직 묶이기 전(예전 토큰)이면 앱이 아는 기기 id로 맞춘다.
      current: j['current'] == true || (currentId != null && id == currentId),
      online: j['online'] == true,
    );
  }

  /// 목록에 보일 이름 — "Windows PC", "Android 앱", "PC 웹 브라우저" 등.
  String get label => switch (kind) {
    'windows' => 'Windows PC',
    'android' => 'Android 앱',
    'ios' => 'iPhone 앱',
    'web-desktop' => 'PC 웹 브라우저',
    'web-android' => 'Android 웹 브라우저',
    'web-mobile' => '휴대폰·태블릿 웹 브라우저',
    _ => switch (name) {
      'windows' => 'Windows PC',
      'android' => 'Android 앱',
      'ios' => 'iPhone 앱',
      'web' => '웹 브라우저',
      final n? when n.isNotEmpty => n,
      _ => '알 수 없는 기기',
    },
  };

  /// 마지막으로 앱이 붙어 있던 때(없으면 처음 등록한 때) — 목록을 최근 순으로 놓는 기준.
  DateTime get lastActiveAt => lastSeenAt ?? createdAt;
}

/// 로그아웃시키지 않은 기기만, 이 기기를 맨 위에 두고 나머지는 최근에 쓴 순으로.
List<MyDevice> activeDevicesFirstCurrent(List<MyDevice> devices) {
  final active = [
    for (final d in devices)
      if (!d.revoked) d,
  ];
  active.sort((a, b) {
    if (a.current != b.current) return a.current ? -1 : 1;
    return b.lastActiveAt.compareTo(a.lastActiveAt);
  });
  return active;
}
