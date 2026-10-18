import 'dart:convert';
import '../l10n/tr.dart';

/// 비밀 대화 상대 기기를 이 기기에 "고정"해 두는 값들(S5)의 모양과 저장 형식. 실제 읽고 쓰기는 같은 저장소 줄을
/// 쓰는 SecretKeyStore가 한다(flutter_secure_storage의 Windows 구현은 파일 하나를 통째로 다시 써서, 저장소 접근이
/// 한 줄로 서지 않으면 서로의 변경을 덮어쓴다 — secret_key_store.dart 참고).
///
/// 왜 고정하나: 예전에는 상대 기기의 서명 검증키를 핸드셰이크마다 서버에 물어 메모리에만 들고 있었다. 그러면
/// 서버(해킹됐거나 악의적인)가 그 질문에 자기 키를 답하고 자기 임시키·서명을 끼워 넣어, 양쪽이 서로가 아니라
/// 서버와 체인을 만들게 할 수 있었다(서버가 모든 비밀 메시지를 읽고 다시 암호화해 넘긴다). 이제는 처음 본 기기의
/// 키를 이 기기에 영구히 고정하고(TOFU — 처음 믿은 키), 그 뒤로는 그 기기에 대해 서버의 말을 듣지 않는다. 기기
/// id와 키는 늘 함께 만들어지고 초기화하면 새 id가 생기므로(device_identity.dart) 같은 기기 id의 키가 바뀌는 정상
/// 경우는 없다 — 바뀌었다면 가로채기를 의심하고 그 대화를 멈춘다. 처음 만난 기기를 서버가 처음부터 속이는 것은
/// 서명으로는 알 수 없어서, 양쪽이 보안 코드(secret_chat_crypto.dart computeSafetyNumber)를 비교하게 한다.
///
/// 고정은 "없을 때만 적기"로 한 번에 한다(SecretKeyStore.pinDeviceIfAbsent) — 같은 기기를 두 곳에서 동시에 처음
/// 고정하다가 서버가 서로 다른 키를 알려 온 것이 드러나면, 덮어쓰지 않고 그 고정에 다툼을 적은 뒤 그 기기와의 대화를
/// 모두 멈춘다. 고정을 지우는 것은 사용자가 "상대 기기 키 다시 받기"를 눌렀을 때뿐이다(보안 코드가 다르거나, 상대가
/// 앱을 다시 설치해 같은 기기 id의 키가 바뀐 것을 확인했을 때 — 그 키로 맺은 대화는 함께 멈춘다).

/// 상대 기기 하나의 고정 정보 — `secretpin/<기기 id>`에 JSON으로 둔다. 방이 없어져도 지우지 않는다(같은 기기와 새
/// 비밀 대화를 시작할 때도 이 키만 믿어야 한다). 한 번 적은 키·주인은 바꾸지 않는다 — 바뀌는 것은 "확인함"·다툼
/// 표시뿐이고, 고정을 없애는 것은 사용자가 "상대 기기 키 다시 받기"를 눌렀을 때뿐이다(SecretKeyStore 참고).
class SecretDevicePin {
  const SecretDevicePin({
    required this.userId,
    required this.signingPublicKey,
    required this.firstSeenAt,
    this.verifiedAt,
    this.verifiedByDeviceId,
    this.disputedAt,
    this.speaksV3 = false,
  });

  /// 지금 처음 고정하는 값 — 고정 시각은 저장 형식(밀리초)에 맞춰 둔다. 고정 시각은 고정 하나를 가리키는 값으로도
  /// 쓰여서([isSamePinAs]), 저장했다 다시 읽은 값과 견줄 때 밀리초 아래 자리 때문에 어긋나면 안 된다.
  factory SecretDevicePin.firstSeen({
    required String userId,
    required String signingPublicKey,
    DateTime? at,
  }) => SecretDevicePin(
    userId: userId,
    signingPublicKey: signingPublicKey,
    firstSeenAt: DateTime.fromMillisecondsSinceEpoch(
      (at ?? DateTime.now()).millisecondsSinceEpoch,
    ),
  );

  /// 이 기기의 주인 — 처음 고정할 때 서버가 알려 준 주인이 그 대화의 상대와 같은지 확인한 값.
  final String userId;

  /// 서명 검증키(Ed25519 공개키, base64).
  final String signingPublicKey;
  final DateTime firstSeenAt;

  /// 사용자가 보안 코드를 비교해 "확인함"으로 표시한 시각.
  final DateTime? verifiedAt;

  /// 그 표시를 한 이 기기의 id — 보안 코드에는 이 기기의 키도 들어가서, 이 기기의 id·키가 바뀌었으면(공용 PC에서
  /// 계정을 바꿔 새 기기 키를 만듦 등) 예전 비교는 지금 코드와 다르다. 같은 저장소를 쓰는 다른 계정의 확인도 내
  /// 확인으로 보지 않게 한다.
  final String? verifiedByDeviceId;

  /// 서버가 이 기기를 고정한 것과 다른 키(또는 다른 주인)로 알려 온 시각. 정상 기기는 기기 id 하나에 키 하나라서
  /// (device_identity.dart), 다르게 알려 왔다는 것 자체가 서버가 한쪽에서 거짓말을 했다는 뜻이다. 어느 쪽이 진짜인지
  /// 알 수 없으니, 사용자가 이 고정을 지우기 전까지 이 기기와는 핸드셰이크·재키잉을 하지 않는다.
  final DateTime? disputedAt;

  /// 이 기기가 새 규약(v3)으로 말하는 것을 이 기기가 직접 확인했다(v3 수락 서명이 맞음·v3로 보낸 글이 풀림 — 서버가 꾸밀
  /// 수 없는 증거). 그 뒤 이 기기와 예전 규약으로 맺게 되면 서버가 규약을 내린 것으로 보고 멈춘다(SecretBlockReason
  /// .downgrade). 한 번 적으면 지우지 않는다 — 고정을 지우면("상대 기기 키 다시 받기") 함께 사라진다.
  final bool speaksV3;

  bool get disputed => disputedAt != null;

  /// [myDeviceId]인 이 기기가 보안 코드를 확인한 시각(아니면 null).
  DateTime? verifiedAtFor(String myDeviceId) =>
      verifiedByDeviceId == myDeviceId ? verifiedAt : null;

  /// 같은 주인·같은 서명 검증키인지.
  bool sameKeyAs(SecretDevicePin other) =>
      userId == other.userId && signingPublicKey == other.signingPublicKey;

  /// 같은 고정인지 — 키가 같아도 지우고 다시 받은 고정(고정 시각이 다름)은 다른 것으로 본다.
  bool isSamePinAs(SecretDevicePin other) =>
      sameKeyAs(other) &&
      firstSeenAt.millisecondsSinceEpoch ==
          other.firstSeenAt.millisecondsSinceEpoch;

  SecretDevicePin _copy({
    DateTime? verifiedAt,
    String? verifiedByDeviceId,
    bool clearVerified = false,
    DateTime? disputedAt,
    bool? speaksV3,
  }) => SecretDevicePin(
    userId: userId,
    signingPublicKey: signingPublicKey,
    firstSeenAt: firstSeenAt,
    verifiedAt: clearVerified ? null : (verifiedAt ?? this.verifiedAt),
    verifiedByDeviceId: clearVerified
        ? null
        : (verifiedByDeviceId ?? this.verifiedByDeviceId),
    disputedAt: disputedAt ?? this.disputedAt,
    speaksV3: speaksV3 ?? this.speaksV3,
  );

  SecretDevicePin markVerified(String myDeviceId, DateTime at) =>
      _copy(verifiedAt: at, verifiedByDeviceId: myDeviceId);

  SecretDevicePin clearVerified() => _copy(clearVerified: true);

  SecretDevicePin markDisputed(DateTime at) => _copy(disputedAt: at);

  SecretDevicePin markSpeaksV3() => _copy(speaksV3: true);

  String encode() => jsonEncode({
    'u': userId,
    'k': signingPublicKey,
    'f': firstSeenAt.millisecondsSinceEpoch,
    if (verifiedAt != null) 'v': verifiedAt!.millisecondsSinceEpoch,
    if (verifiedByDeviceId != null) 'vb': verifiedByDeviceId,
    if (disputedAt != null) 'x': disputedAt!.millisecondsSinceEpoch,
    if (speaksV3) 'v3': true,
  });

  /// 깨진 값이면 null.
  static SecretDevicePin? decode(String raw) {
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return null;
      final userId = json['u'];
      final key = json['k'];
      final firstSeen = json['f'];
      if (userId is! String || key is! String || firstSeen is! num) {
        return null;
      }
      final verified = json['v'];
      final verifiedBy = json['vb'];
      final disputed = json['x'];
      return SecretDevicePin(
        userId: userId,
        signingPublicKey: key,
        firstSeenAt: DateTime.fromMillisecondsSinceEpoch(firstSeen.toInt()),
        verifiedAt: verified is num
            ? DateTime.fromMillisecondsSinceEpoch(verified.toInt())
            : null,
        verifiedByDeviceId: verifiedBy is String ? verifiedBy : null,
        // 다툼 표시가 깨져 있으면(숫자가 아님) 다툼으로 본다 — 풀어 주는 쪽으로 틀리면 안 된다.
        disputedAt: disputed == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(
                disputed is num ? disputed.toInt() : 0,
              ),
        speaksV3: json['v3'] == true,
      );
    } on FormatException {
      return null;
    }
  }
}

/// 비밀 대화방 하나가 묶인 상대(사용자·기기)와, 이 기기가 그 대화에 쓴 기기 id — `secret/<방>/peer`. 비밀 대화는
/// 방 하나에 기기 한 쌍이 고정이라(여러 기기 동기화 없음), 보안 코드·신뢰 안내가 어느 기기의 고정 키를 볼지 이걸로
/// 정한다. 앱을 다시 켜도 남는다.
class SecretRoomBinding {
  const SecretRoomBinding({
    required this.peerUserId,
    required this.peerDeviceId,
    this.myDeviceId,
  });

  final String peerUserId;
  final String peerDeviceId;

  /// 핸드셰이크 때 이 기기가 쓴 기기 id. 그 뒤 이 기기의 id·키가 바뀌었으면(공용 PC에서 계정을 바꿈 등) 상대는
  /// 예전 키로 고정해 두었으므로 보안 코드가 서로 맞지 않는다고 알린다. 예전에 성립한 대화를 방 정보로 묶은 것이면
  /// 그때의 이 기기 id다.
  final String? myDeviceId;

  String encode() => jsonEncode({
    'u': peerUserId,
    'd': peerDeviceId,
    if (myDeviceId != null) 'm': myDeviceId,
  });

  static SecretRoomBinding? decode(String raw) {
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return null;
      final userId = json['u'];
      final deviceId = json['d'];
      final mine = json['m'];
      if (userId is! String || deviceId is! String) return null;
      return SecretRoomBinding(
        peerUserId: userId,
        peerDeviceId: deviceId,
        myDeviceId: mine is String ? mine : null,
      );
    } on FormatException {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is SecretRoomBinding &&
      other.peerUserId == peerUserId &&
      other.peerDeviceId == peerDeviceId &&
      other.myDeviceId == myDeviceId;

  @override
  int get hashCode => Object.hash(peerUserId, peerDeviceId, myDeviceId);
}

/// 비밀 대화를 멈춘 이유 — 저장값([code])과 방 안내에 덧붙이는 짧은 설명([description]).
enum SecretBlockReason {
  /// 상대 기기의 서명이 고정한(또는 막 받은) 키로 맞지 않는다.
  badSignature('signature', '상대 기기의 서명이 맞지 않습니다.'),

  /// 서버가 알려 준 기기 주인이, 이 대화의 상대가 아니다(또는 고정해 둔 주인과 다르다).
  userMismatch('user', '상대 기기의 주인이 대화 상대와 다릅니다.'),

  /// 초대·수락·재키잉을 보낸 사람이 이 방의 상대가 아니다.
  peerMismatch('peer', '이 대화의 상대가 아닌 사람이 보낸 요청입니다.'),

  /// 이 방이 묶인 상대 기기가 아닌 다른 기기의 요청이다.
  deviceMismatch('device', '이 대화를 맺은 상대 기기가 아닌 다른 기기의 요청입니다.'),

  /// 서버가 같은 상대 기기를 이 기기에 고정해 둔 것과 다른 키·주인으로 알려 왔다(같은 기기를 두 곳에서 동시에 처음
  /// 고정하다 드러났다) — 또는 그 기기의 고정이 그 일로 다툼 중이거나 읽을 수 없다.
  keyMismatch('key', '서버가 상대 기기의 키를 이 기기에 고정해 둔 것과 다르게 알려 왔습니다.'),

  /// 사용자가 "상대 기기 키 다시 받기"로 그 기기의 고정을 지웠다 — 그 키를 믿고 맺은 대화는 더 믿을 근거가 없다.
  keyReset('reset', '상대 기기 키를 다시 받기로 해서, 예전 키로 맺은 이 대화를 멈췄습니다.'),

  /// 새 규약(v3)으로 말하는 것을 확인한 상대 기기와 예전 규약으로 맺게 됐다 — 서버가 초대·수락에서 새 규약 표시나 서명을
  /// 빼 보호가 약한 예전 방식으로 내리려 한 것이다(상대가 앱을 예전 버전으로 되돌렸을 수도 있다).
  downgrade(
    'downgrade',
    '새 방식으로 대화하던 상대 기기와 예전 방식으로 맺게 하려 했습니다(서버가 바꿨을 수 있습니다).',
  );

  const SecretBlockReason(this.code, this._descriptionKo);
  final String code;
  final String _descriptionKo;

  /// 화면에 보일 이름(지금 언어 — l10n/tr.dart).
  String get description => tr(_descriptionKo);

  /// 이 이유로 멈춘 방에서 "상대 기기 키 다시 받기"를 권할 수 있는지 — 고정해 둔 키로 확인이 안 됐을 때만이다(상대가
  /// 앱을 다시 설치하는 등으로 같은 기기 id의 키가 바뀌었을 수 있다). 다른 이유는 키를 다시 받아도 풀리지 않는다.
  bool get allowsKeyReset =>
      this == badSignature || this == keyMismatch || this == downgrade;

  static SecretBlockReason? fromCode(Object? code) {
    for (final r in values) {
      if (r.code == code) return r;
    }
    return null;
  }
}

/// 비밀 대화방 하나의 보안 상태 — `secret/<방>/security`. 방이 없어지면(forgetRoom) 함께 지운다. 멈춤은 방이 없어질
/// 때만 지워진다 — 저장소가 다시 적을 때도 이미 적힌 멈춤은 그대로 둔다(SecretKeyStore.saveRoomSecurity).
class SecretRoomSecurity {
  const SecretRoomSecurity({
    this.blockedReason,
    this.blockedAt,
    this.blockedDeviceId,
    this.blockedPinSeenAt,
    this.legacyPeer = false,
    this.legacyNoticeDismissed = false,
    this.peerDeviceChanged = false,
    this.protocolNoticeDismissed = false,
  });

  static const none = SecretRoomSecurity();

  /// 보안 확인에 실패해 이 대화를 멈춘 이유 — 있으면 더는 핸드셰이크·재키잉을 진행하지도, 주고받지도 않는다(되돌리는
  /// 방법은 없다 — 끝내고 새로 시작한 뒤 보안 코드를 비교해야 한다).
  final SecretBlockReason? blockedReason;
  final DateTime? blockedAt;

  /// 이 기기에 고정해 둔 키 때문에 멈췄으면(고정한 키로 서명이 맞지 않음·고정이 다툼 중이거나 깨짐) 그 상대 기기와,
  /// 그때 그 고정의 고정 시각(깨진 고정이었으면 null). "상대 기기 키 다시 받기"를 그 고정에만 쓰게 한다 — 지우고 다시
  /// 받은 새 고정을, 예전에 멈춘 이 방에서 또 지워 버리지 않게. 고정과 상관없이 멈췄으면 둘 다 null.
  final String? blockedDeviceId;
  final DateTime? blockedPinSeenAt;

  /// 상대가 맥락 서명(v2)을 보내지 않았다(예전 앱) — 키만 서명한 v1을 고정한 키로 확인했다. 상대가 v2를 보내면 꺼진다.
  final bool legacyPeer;

  /// "예전 앱" 안내를 닫았는지.
  final bool legacyNoticeDismissed;

  /// "예전 방식으로 맺은 대화" 안내(SecretRoomTrust.showProtocolNotice)를 닫았는지.
  final bool protocolNoticeDismissed;

  /// 상대가, 이 기기가 예전에 보안 코드를 확인한 기기가 아닌 다른 기기로 이 대화를 맺었다 — 보안 코드를 다시
  /// 비교하라고 알린다(그 기기를 확인하거나 안내를 닫으면 꺼진다).
  final bool peerDeviceChanged;

  bool get blocked => blockedReason != null;

  SecretRoomSecurity copyWith({
    bool? legacyPeer,
    bool? legacyNoticeDismissed,
    bool? peerDeviceChanged,
    bool? protocolNoticeDismissed,
  }) => SecretRoomSecurity(
    blockedReason: blockedReason,
    blockedAt: blockedAt,
    blockedDeviceId: blockedDeviceId,
    blockedPinSeenAt: blockedPinSeenAt,
    legacyPeer: legacyPeer ?? this.legacyPeer,
    legacyNoticeDismissed: legacyNoticeDismissed ?? this.legacyNoticeDismissed,
    peerDeviceChanged: peerDeviceChanged ?? this.peerDeviceChanged,
    protocolNoticeDismissed:
        protocolNoticeDismissed ?? this.protocolNoticeDismissed,
  );

  /// [reason]으로 멈춘 값. [deviceId]·[pinSeenAt]은 고정해 둔 키 때문에 멈췄을 때만 준다([blockedDeviceId] 참고).
  SecretRoomSecurity blockedWith(
    SecretBlockReason reason,
    DateTime at, {
    String? deviceId,
    DateTime? pinSeenAt,
  }) => SecretRoomSecurity(
    blockedReason: reason,
    blockedAt: at,
    blockedDeviceId: deviceId,
    blockedPinSeenAt: deviceId == null ? null : pinSeenAt,
    legacyPeer: legacyPeer,
    legacyNoticeDismissed: legacyNoticeDismissed,
    peerDeviceChanged: peerDeviceChanged,
    protocolNoticeDismissed: protocolNoticeDismissed,
  );

  /// 멈춤은 [other]의 것으로 바꾼 값 — 이미 멈춘 방에 안내 표시만 고쳐 적을 때, 처음 멈춘 이유를 지키려고 쓴다.
  SecretRoomSecurity withBlockOf(SecretRoomSecurity other) =>
      SecretRoomSecurity(
        blockedReason: other.blockedReason,
        blockedAt: other.blockedAt,
        blockedDeviceId: other.blockedDeviceId,
        blockedPinSeenAt: other.blockedPinSeenAt,
        legacyPeer: legacyPeer,
        legacyNoticeDismissed: legacyNoticeDismissed,
        peerDeviceChanged: peerDeviceChanged,
        protocolNoticeDismissed: protocolNoticeDismissed,
      );

  /// 멈춤만 남긴 값 — 되돌린 세션에 붙어 있던 안내(예전 앱·상대 기기 바뀜)는 뺀다.
  SecretRoomSecurity blockOnly() => SecretRoomSecurity.none.withBlockOf(this);

  String encode() => jsonEncode({
    if (blockedReason != null) 'b': blockedReason!.code,
    if (blockedAt != null) 'ba': blockedAt!.millisecondsSinceEpoch,
    if (blockedDeviceId != null) 'bd': blockedDeviceId,
    if (blockedPinSeenAt != null)
      'bp': blockedPinSeenAt!.millisecondsSinceEpoch,
    if (legacyPeer) 'l': true,
    if (legacyNoticeDismissed) 'ld': true,
    if (peerDeviceChanged) 'c': true,
    if (protocolNoticeDismissed) 'pd': true,
  });

  /// 깨진 값이면 null. 알 수 없는 차단 사유(새 버전이 쓴 값)도 멈춘 것으로 본다 — 풀어 주는 쪽으로 틀리면 안 된다.
  static SecretRoomSecurity? decode(String raw) {
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return null;
      final code = json['b'];
      final blockedAt = json['ba'];
      final blockedDevice = json['bd'];
      final blockedPin = json['bp'];
      return SecretRoomSecurity(
        blockedReason: code == null
            ? null
            : SecretBlockReason.fromCode(code) ??
                  SecretBlockReason.badSignature,
        blockedAt: blockedAt is num
            ? DateTime.fromMillisecondsSinceEpoch(blockedAt.toInt())
            : null,
        blockedDeviceId: blockedDevice is String ? blockedDevice : null,
        blockedPinSeenAt: blockedPin is num
            ? DateTime.fromMillisecondsSinceEpoch(blockedPin.toInt())
            : null,
        legacyPeer: json['l'] == true,
        legacyNoticeDismissed: json['ld'] == true,
        peerDeviceChanged: json['c'] == true,
        protocolNoticeDismissed: json['pd'] == true,
      );
    } on FormatException {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is SecretRoomSecurity &&
      other.blockedReason == blockedReason &&
      other.blockedAt == blockedAt &&
      other.blockedDeviceId == blockedDeviceId &&
      other.blockedPinSeenAt == blockedPinSeenAt &&
      other.legacyPeer == legacyPeer &&
      other.legacyNoticeDismissed == legacyNoticeDismissed &&
      other.peerDeviceChanged == peerDeviceChanged &&
      other.protocolNoticeDismissed == protocolNoticeDismissed;

  @override
  int get hashCode => Object.hash(
    blockedReason,
    blockedAt,
    blockedDeviceId,
    blockedPinSeenAt,
    legacyPeer,
    legacyNoticeDismissed,
    peerDeviceChanged,
    protocolNoticeDismissed,
  );
}

/// 화면(방 안내·더보기 메뉴)이 보는 비밀 대화방 하나의 신뢰 상태 — SecretSessionManager가 저장된 값으로 만든다.
class SecretRoomTrust {
  const SecretRoomTrust({
    this.peerUserId,
    this.peerDeviceId,
    this.verifiedAt,
    this.security = SecretRoomSecurity.none,
    this.resetDeviceId,
    this.peerKeyAlreadyReset = false,
    this.legacyProtocol = false,
  });

  /// 이 방이 묶인 상대(아직 핸드셰이크 전이거나 예전 대화를 묶지 못했으면 null).
  final String? peerUserId;
  final String? peerDeviceId;

  /// 이 기기가 상대 기기의 보안 코드를 확인한 시각.
  final DateTime? verifiedAt;
  final SecretRoomSecurity security;

  /// "상대 기기 키 다시 받기"로 고정을 지울 수 있는 상대 기기(없으면 null) — 멈춘 방이면 고정해 둔 키로 확인이 안 된
  /// 그 기기(그 고정이 아직 그대로일 때만), 멈추지 않은 방이면 이 방이 묶인 기기(보안 코드가 다를 때).
  final String? resetDeviceId;

  /// 멈춘 원인이던 상대 기기의 고정을 이미 지웠다(또는 그 뒤 새로 받았다) — 이 대화를 끝내고 새로 시작하면 된다.
  final bool peerKeyAlreadyReset;

  /// 이 대화가 예전 규약(v1 — 두 사람이 체인 하나를 함께 씀)으로 맺어졌다(이 업데이트 전에 맺었거나 상대가 예전 앱).
  final bool legacyProtocol;

  bool get bound => peerDeviceId != null;
  bool get verified => verifiedAt != null;
  bool get blocked => security.blocked;
  bool get canResetPeerKey => resetDeviceId != null;

  /// "예전 앱" 안내를 보일지.
  bool get showLegacyNotice =>
      !blocked && security.legacyPeer && !security.legacyNoticeDismissed;

  /// "상대 기기가 바뀜" 안내를 보일지 — 그 기기를 확인했으면 보이지 않는다.
  bool get showDeviceChangedNotice =>
      !blocked && security.peerDeviceChanged && !verified;

  /// "예전 방식으로 맺은 대화" 안내를 보일지 — 새로 시작하면 새 규약으로 바뀐다고 알린다. 상대가 예전 앱이면 새로
  /// 시작해도 그대로라 "예전 앱" 안내([showLegacyNotice])만 보인다(그 안내를 닫아도 이 안내로 바뀌지 않는다).
  bool get showProtocolNotice =>
      !blocked &&
      legacyProtocol &&
      !security.legacyPeer &&
      !security.protocolNoticeDismissed;

  @override
  bool operator ==(Object other) =>
      other is SecretRoomTrust &&
      other.peerUserId == peerUserId &&
      other.peerDeviceId == peerDeviceId &&
      other.verifiedAt == verifiedAt &&
      other.security == security &&
      other.resetDeviceId == resetDeviceId &&
      other.peerKeyAlreadyReset == peerKeyAlreadyReset &&
      other.legacyProtocol == legacyProtocol;

  @override
  int get hashCode => Object.hash(
    peerUserId,
    peerDeviceId,
    verifiedAt,
    security,
    resetDeviceId,
    peerKeyAlreadyReset,
    legacyProtocol,
  );
}

/// 보안 코드 화면에 보여 줄 값 — [groups]는 5자리 숫자 12묶음(secret_chat_crypto.dart computeSafetyNumber).
class SecretSafetyInfo {
  const SecretSafetyInfo({
    required this.groups,
    required this.peerUserId,
    required this.peerDeviceId,
    this.verifiedAt,
    this.myKeyChanged = false,
  });

  final List<String> groups;
  final String peerUserId;
  final String peerDeviceId;
  final DateTime? verifiedAt;

  /// 이 대화를 맺은 뒤 이 기기의 id·키가 바뀌었다 — 상대가 보는 코드는 예전 키로 계산돼서 서로 맞지 않는다.
  final bool myKeyChanged;

  bool get verified => verifiedAt != null;

  /// 4묶음씩 3줄.
  List<List<String>> get rows => [
    for (var i = 0; i < groups.length; i += 4)
      groups.sublist(i, i + 4 > groups.length ? groups.length : i + 4),
  ];
}
