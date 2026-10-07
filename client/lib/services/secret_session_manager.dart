import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;

import '../models/message.dart';
import '../models/room.dart';
import 'api_client.dart';
import 'chat_socket.dart';
import 'device_identity.dart';
import 'secret_chat_crypto.dart' as crypto;
import 'secret_key_store.dart';
import 'secret_peer_store.dart';

/// 보안 확인에 실패해 멈춘 비밀 대화로 보내려 할 때 — 화면에 그대로 보여 줄 문구를 담는다.
class SecretChatBlockedException extends ApiException {
  const SecretChatBlockedException()
    : super(
        '보안 확인에 실패해 멈춘 비밀 대화입니다. 이 비밀 대화를 끝내고 상대와 보안 코드를 비교한 뒤 새로 시작해 주세요.',
      );
}

/// 핸드셰이크(초대 수락·수락 확인)나 재키잉 하나를 처리한 결과 — Session이 안내(토스트)를 고르는 데 쓴다.
enum SecretHandshakeOutcome {
  /// 확인을 마치고 체인키를 만들었다(재키잉이면 새 epoch로 넘어갔다).
  established,

  /// [established]인데, 상대가 이 기기가 예전에 보안 코드를 확인한 기기가 아닌 다른 기기로 맺었다 — 보안 코드를
  /// 다시 비교하라고 알린다.
  establishedOnChangedDevice,

  /// 이 기기와 상관없거나(내 다른 기기·이미 처리됨·지난 epoch) 아직 처리할 수 없어 아무것도 하지 않았다.
  ignored,

  /// 보안 확인에 실패해 이 대화를 멈췄다 — 체인키는 만들지 않았다.
  blocked,
}

/// 상대 기기의 서명 검증키를 찾은 결과.
///  - 고정해 둔 키: [signingPublicKey]와 [pin]이 있다.
///  - 서버에 처음 물어 주인까지 확인한 키: [signingPublicKey]만 있다(서명을 확인한 뒤 고정한다).
///  - 확인 실패: [failure]가 있다. 고정해 둔 기록 때문에 실패했으면(다툼 중·깨짐) [pinInvolved] — 그 고정이 [pin].
///  - 고정이 없어 확인할 수 없음(재키잉은 처음 보는 키를 믿지 않는다): 아무것도 없다.
class _PeerKey {
  _PeerKey.pinned(SecretDevicePin pinned)
    : signingPublicKey = pinned.signingPublicKey,
      pin = pinned,
      failure = null,
      pinInvolved = true;
  const _PeerKey.firstSeen(String this.signingPublicKey)
    : pin = null,
      failure = null,
      pinInvolved = false;
  const _PeerKey.failed(
    SecretBlockReason this.failure, {
    this.pin,
    this.pinInvolved = false,
  }) : signingPublicKey = null;
  const _PeerKey.unpinned()
    : signingPublicKey = null,
      pin = null,
      failure = null,
      pinInvolved = false;

  final String? signingPublicKey;
  final SecretDevicePin? pin;
  final SecretBlockReason? failure;

  /// 이 기기에 그 기기의 고정 기록이 있었다(읽을 수 없었어도) — 멈출 때 "상대 기기 키 다시 받기" 대상으로 적는다.
  final bool pinInvolved;

  bool get pinned => pin != null && failure == null;
}

/// 비밀 대화(E2EE) 방 하나의 핸드셰이크/재키잉 상태 머신. 공유비밀/체인키 계산은 전부 여기서
/// 로컬로만 이뤄지고, 서버로는 공개키/서명만 나간다. Session이 메시지 송수신 경계에서 이
/// 매니저의 encryptForRoom/decryptForRoom을 호출하는 얇은 통합만 한다.
///
/// 서버를 믿지 않는다(S5): 상대 기기의 서명 검증키는 처음 본 기기일 때만 서버에 묻고(그 기기의 주인이 이 대화의
/// 상대인지 함께 확인), 그 뒤로는 이 기기에 고정해 둔 키만 쓴다(secret_peer_store.dart). 방마다 묶인 상대
/// 기기도 저장해 두어 재시작 뒤 재키잉에도 쓴다. 핸드셰이크에서 서명이 고정한 키로 맞지 않거나, 이벤트가 방에 묶인
/// 상대가 아닌 사람·기기를 가리키면 체인키를 만들지 않고 그 방을 멈춘다(되돌리는 방법은 없다 — 끝내고 새로 시작한
/// 뒤 보안 코드를 비교해야 한다). 재키잉의 서명이 맞지 않으면 멈추지 않고 무시한다 — 체인은 그대로라 안전은 같고,
/// 재키잉에는 사용자 id만 실려 와서 상대의 다른(남은) 기기가 보낸 것일 수도 있다.
class SecretSessionManager {
  final ApiClient _api;
  final ChatSocket _socket;
  final DeviceIdentity _identity;
  final SecretKeyStore _keyStore;

  /// 로그인한 내 사용자 id — 맥락 서명(누가 누구에게)을 만들고 확인하는 데 쓴다.
  final String? _myUserId;

  /// 방 id로 지금 아는 방 정보(멤버·핸드셰이크 양쪽 기기)를 찾는다 — Session의 방 목록. 초대·수락을 보낸 사람이
  /// 그 방의 상대가 맞는지 보고, 이 업데이트 전에 성립한 대화를 상대 기기에 묶는 데 쓴다.
  final Room? Function(String roomId)? _lookupRoom;

  /// 방의 신뢰 상태([trustOf])가 바뀌었을 때 — Session이 화면(방 안내·더보기 메뉴)을 다시 그리게 한다.
  void Function(String roomId)? onTrustChanged;

  /// 처리하던 방이 아닌 다른 방들을 함께 멈췄을 때(서버가 같은 상대 기기를 다른 키로 알려 와 그 기기와의 대화를 모두
  /// 멈춤) — 처리하던 방은 결과([SecretHandshakeOutcome.blocked])로 알리고, 함께 멈춘 방은 이걸로 알린다(Session이
  /// 토스트로 알린다 — 그 방을 보고 있지 않아도 알게).
  void Function(List<String> roomIds)? onRoomsBlocked;

  // 방 id → 묶인 상대 기기·보안 상태(저장소의 값을 한 번 읽어 들고 있는다 — 메시지마다 저장소를 읽지 않게).
  final Map<String, SecretRoomBinding> _bindings = {};
  final Map<String, SecretRoomSecurity> _securities = {};
  final Map<String, SecretRoomTrust> _trust = {};

  // 방 정보로 상대 기기를 찾아 묶는 중인 방 — 같은 방을 동시에 두 번 묻지 않게.
  final Map<String, Future<SecretRoomBinding?>> _bootstraps = {};

  // 방마다 핸드셰이크·재키잉·암복호화를 한 줄로 세운다 — 재키잉이 체인 상태를 바꾸는 동안 메시지 암호화가 옛 상태를
  // 읽고 덮어쓰면 양쪽 체인이 어긋난다. 줄 안에서 다시 같은 방 줄을 서면 멈추므로, 줄 안의 도우미는 줄을 서지 않는다.
  final Map<String, Future<void>> _roomQueues = {};

  // 재키잉 트리거 판단용 — 방마다 이번 epoch에서 처리한 메시지 수/epoch 시작 시각.
  final Map<String, int> _epochMessageCount = {};
  final Map<String, DateTime> _epochStartedAt = {};

  // 방마다 지금 수락을 기다리는 재키잉 제안을 마지막으로 보낸 시각 — 같은 제안을 메시지마다 다시 보내지 않게.
  final Map<String, DateTime> _rekeyProposalSentAt = {};

  /// 수락이 오지 않은 재키잉 제안을 다시 보내기까지 기다리는 시간(그 사이에도 메시지가 오가야 다시 보낸다).
  static const _rekeyResendInterval = Duration(seconds: 30);

  // "roomId|epoch|n" -> 내가 방금 보낸 평문. encryptForRoom은 전송 즉시 로컬 체인키를
  // 한 칸 전진시켜 저장하는데(다음 메시지를 위해), 서버가 그 메시지를 내 소켓에도 그대로
  // 되돌려주면(다른 멤버들과 동일하게 echo됨) 그 시점엔 이미 내 state.n이 그 메시지의 n보다
  // 앞서 있어서 한 방향 래칫으로는 "뒤로" 못 감는다(의도된 동작 — 순방향 비밀성의 핵심).
  // 그래서 내가 보낸 메시지만 예외적으로 여기 잠깐 캐싱해뒀다가, echo가 돌아오면 바로 이걸
  // 돌려준다(래칫 상태는 건드리지 않음 — 이미 encryptForRoom에서 전진시켰으므로).
  final Map<String, String> _recentlySentPlaintext = {};

  bool _disposed = false;

  String _envelopeCacheKey(String roomId, int epoch, int n) =>
      '$roomId|$epoch|$n';

  /// [keyStore]는 테스트가 저장소를 바꿔 끼울 때만 준다. [userId]는 로그인한 내 id, [roomLookup]은 Session의 방
  /// 목록 — 핸드셰이크·재키잉에 꼭 필요하다(평문 캐시만 다루는 곳에서는 없어도 된다).
  SecretSessionManager(
    this._api,
    this._socket,
    this._identity, {
    SecretKeyStore? keyStore,
    String? userId,
    Room? Function(String roomId)? roomLookup,
  }) : _keyStore = keyStore ?? SecretKeyStore(),
       _myUserId = userId,
       _lookupRoom = roomLookup;

  String get _me {
    final me = _myUserId;
    if (me == null) {
      throw StateError('비밀 대화 핸드셰이크에는 로그인한 사용자 id가 필요합니다.');
    }
    return me;
  }

  /// 이 기기 id — 아직 불러오지 않았으면 null(평문 캐시만 다루는 테스트 등).
  String? get _myDeviceIdOrNull {
    try {
      return _identity.deviceId;
    } on StateError {
      return null;
    }
  }

  Future<T> _inRoom<T>(String roomId, Future<T> Function() op) {
    final previous = _roomQueues[roomId] ?? Future<void>.value();
    final result = previous.then((_) => op());
    final tail = result.then<void>((_) {}, onError: (Object _) {});
    _roomQueues[roomId] = tail;
    unawaited(
      tail.whenComplete(() {
        if (identical(_roomQueues[roomId], tail)) _roomQueues.remove(roomId);
      }),
    );
    return result;
  }

  // ---- 방에 묶인 상대 기기·보안 상태 ----

  Future<SecretRoomBinding?> _bindingOf(String roomId) async {
    final cached = _bindings[roomId];
    if (cached != null) return cached;
    final stored = await _keyStore.readRoomBinding(roomId);
    if (stored != null) _bindings[roomId] = stored;
    return stored;
  }

  Future<void> _saveBinding(String roomId, SecretRoomBinding binding) async {
    await _keyStore.saveRoomBinding(roomId, binding);
    _bindings[roomId] = binding;
  }

  Future<SecretRoomSecurity> _securityOf(String roomId) async {
    final cached = _securities[roomId];
    if (cached != null) return cached;
    final stored = await _keyStore.readRoomSecurity(roomId);
    return _securities[roomId] = stored;
  }

  /// 보안 상태를 적는다 — 저장소가 이미 적힌 멈춤은 지키며 적고(다른 방의 일로 그 사이 멈췄을 수 있다) 실제로 적힌
  /// 값을 돌려주므로, 들고 있는 값도 그것으로 맞춘다.
  Future<void> _saveSecurity(String roomId, SecretRoomSecurity security) async {
    if (await _securityOf(roomId) == security) return;
    _securities[roomId] = await _keyStore.saveRoomSecurity(roomId, security);
  }

  /// 보안 확인에 실패한 방을 멈춘다 — 처음 멈춘 이유를 남기고, 더 쓸 일이 없는 대기 중인 임시 개인키는 지운다.
  /// 이 기기에 고정해 둔 키 때문에 멈췄으면 그 상대 기기 [deviceId]와 그 고정 [pin]을 함께 적어 둔다("상대 기기 키
  /// 다시 받기"가 그 고정에만 쓰이게 — 깨진 고정이었으면 [pin]은 null).
  Future<SecretHandshakeOutcome> _block(
    String roomId,
    SecretBlockReason reason, {
    String? deviceId,
    SecretDevicePin? pin,
  }) async {
    final current = await _securityOf(roomId);
    if (!current.blocked) {
      await _saveSecurity(
        roomId,
        current.blockedWith(
          reason,
          DateTime.now(),
          deviceId: reason.allowsKeyReset ? deviceId : null,
          pinSeenAt: pin?.firstSeenAt,
        ),
      );
    }
    await _keyStore.clearPendingEphemeralSeed(roomId);
    await _keyStore.clearPendingRekeySeed(roomId);
    _rekeyProposalSentAt.remove(roomId);
    await _refreshTrust(roomId);
    return SecretHandshakeOutcome.blocked;
  }

  /// [key] 확인에 실패해 방을 멈춘다 — 고정 기록 때문이면 그 기기를 "다시 받기" 대상으로 적는다.
  Future<SecretHandshakeOutcome> _blockForKey(
    String roomId,
    String deviceId,
    _PeerKey key,
    SecretBlockReason reason,
  ) => _block(
    roomId,
    reason,
    deviceId: key.pinInvolved ? deviceId : null,
    pin: key.pin,
  );

  /// 상대 기기 [deviceId]에 묶인 방(이 기기에 저장된 묶음 전부와 지금 들고 있는 묶음)을 [reason]으로 멈추고, 새로
  /// 멈춘 방 id를 돌려준다 — [except] 방은 부른 쪽이 따로 다룬다. [notify]면 [onRoomsBlocked]로도 알린다.
  Future<List<String>> _blockRoomsBoundTo(
    String deviceId,
    SecretBlockReason reason, {
    SecretDevicePin? pin,
    String? except,
    bool notify = true,
  }) async {
    final roomIds = <String>{
      ...await _keyStore.roomIdsBoundToDevice(deviceId),
      for (final entry in _bindings.entries)
        if (entry.value.peerDeviceId == deviceId) entry.key,
    }..remove(except);
    final newlyBlocked = <String>[];
    for (final roomId in roomIds) {
      if ((await _securityOf(roomId)).blocked) {
        // 이미 멈춘 방도 그 기기의 고정이 바뀌었으니(다툼·지움) 화면에 보일 상태를 다시 맞춘다.
        await _refreshTrust(roomId);
        continue;
      }
      await _block(roomId, reason, deviceId: deviceId, pin: pin);
      newlyBlocked.add(roomId);
    }
    if (notify && newlyBlocked.isNotEmpty && !_disposed) {
      onRoomsBlocked?.call(newlyBlocked);
    }
    return newlyBlocked;
  }

  /// 보안 확인에 실패해 멈춘 방인지.
  Future<bool> isBlocked(String roomId) async =>
      (await _securityOf(roomId)).blocked;

  /// 방 [roomId]의 상대 기기 — 저장된 것이 없으면, 이 업데이트 전에 성립한 대화일 수 있어 방 정보로 찾아 묶는다
  /// ([_bootstrapBinding]). 찾지 못하면(서버가 기기 정보를 안 주는 예전 서버, 이 기기의 대화가 아님, 오프라인) null.
  Future<SecretRoomBinding?> _bindingFor(String roomId) async {
    final known = await _bindingOf(roomId);
    if (known != null) return known;
    final running = _bootstraps[roomId];
    if (running != null) return running;
    final bootstrap = _bootstrapBinding(roomId);
    _bootstraps[roomId] = bootstrap;
    try {
      return await bootstrap;
    } finally {
      if (identical(_bootstraps[roomId], bootstrap)) _bootstraps.remove(roomId);
    }
  }

  /// 이 업데이트 전에 성립한 비밀 대화를 상대 기기에 묶는다 — 그때는 상대 기기를 메모리에만 들고 있어서 저장된 것이
  /// 없다. 서버가 방 정보로 알려 주는 양쪽 사용자·기기 중 이 기기 쪽이 맞을 때만, 상대 기기의 키를(처음 보는 기기면
  /// 서버에 물어 주인이 그 상대인지 확인하고) 고정한다. 서명으로 확인할 것이 없어 처음 믿는 키다 — 그래서 보안 코드
  /// 비교가 필요하다. 주인이 다르면 그 방을 멈춘다.
  Future<SecretRoomBinding?> _bootstrapBinding(String roomId) async {
    final room = _lookupRoom?.call(roomId);
    final me = _myUserId;
    final myDeviceId = _myDeviceIdOrNull;
    if (room == null ||
        !room.isSecret ||
        room.secretStatus != 'active' ||
        me == null ||
        myDeviceId == null) {
      return null;
    }
    // 이 기기에 그 대화의 세션이 없으면 묶을 것도 없다(핸드셰이크가 새로 묶는다).
    if (await _keyStore.readChainState(roomId) == null) return null;
    if ((await _securityOf(roomId)).blocked) return null;
    String? peerUserId;
    String? peerDeviceId;
    if (room.secretInitiatorUserId == me &&
        room.secretInitiatorDeviceId == myDeviceId) {
      peerUserId = room.secretResponderUserId;
      peerDeviceId = room.secretResponderDeviceId;
    } else if (room.secretResponderUserId == me &&
        room.secretResponderDeviceId == myDeviceId) {
      peerUserId = room.secretInitiatorUserId;
      peerDeviceId = room.secretInitiatorDeviceId;
    }
    if (peerUserId == null || peerDeviceId == null || peerUserId == me) {
      return null;
    }
    // 상대가 이미 나간 방(멤버에 없음)은 재키잉할 상대가 없다.
    if (!room.members.any((m) => m.id == peerUserId)) return null;
    final _PeerKey key;
    try {
      key = await _peerKeyFor(peerDeviceId, peerUserId);
    } catch (_) {
      return null; // 오프라인 등 — 다음에 다시 묶어 본다.
    }
    final failure = key.failure;
    if (failure != null) {
      await _blockForKey(roomId, peerDeviceId, key, failure);
      return null;
    }
    // 묻는 사이 핸드셰이크가 먼저 묶었으면 그것을 쓴다.
    final raced = await _bindingOf(roomId);
    if (raced != null) return raced;
    // 먼저 묶고 그다음 고정한다(acceptInvite와 같은 까닭 — 다른 방에서 드러난 키 다툼이 이 방을 빠뜨리지 않게).
    final binding = SecretRoomBinding(
      peerUserId: peerUserId,
      peerDeviceId: peerDeviceId,
      myDeviceId: myDeviceId,
    );
    await _saveBinding(roomId, binding);
    // 서버가 이 답을 붙잡아 두는 사이 다른 방의 핸드셰이크가 같은 기기를 다른 키로 먼저 고정했으면 — 덮어쓰지
    // 않고(그러면 그 방의 보안 코드가 진짜처럼 바뀐다) 이 방과 그 기기와의 대화를 모두 멈춘다.
    final ({
      SecretBlockReason? failure,
      SecretDevicePin? pin,
      bool deviceChanged,
    })
    pinned;
    try {
      pinned = await _pinPeerDevice(
        roomId,
        peerDeviceId,
        peerUserId,
        key,
        checkDeviceChange: false,
      );
    } catch (_) {
      // 고정을 적지 못했으면(저장소 오류) 묶음도 거둔다 — 고정 없는 묶음으로 남으면 다음에 다시 묶지 않는다.
      _bindings.remove(roomId);
      try {
        await _keyStore.deleteRoomBinding(roomId);
      } catch (_) {}
      return null;
    }
    final pinFailure = pinned.failure;
    if (pinFailure != null) {
      await _block(roomId, pinFailure, deviceId: peerDeviceId, pin: pinned.pin);
      return null;
    }
    await _refreshTrust(roomId);
    return binding;
  }

  /// 앱을 켤 때 — 내 다른 기기가 수락한 대화에 이 기기의 키가 남아 있으면 치우고([_dropStaleResponderKeys]), 이
  /// 업데이트 전에 성립한 대화들을 상대 기기에 미리 묶어 둔다(재키잉이 오기 전에). 실패해도 다음에 필요할 때(재키잉·
  /// 보안 코드 화면) 다시 해 본다. 묶다가 보안 확인에 실패해 이번에 멈춘 방 id를 돌려준다(Session이 알린다).
  Future<List<String>> bootstrapBindings(Iterable<String> roomIds) async {
    final blocked = <String>[];
    for (final roomId in roomIds.toList()) {
      if (_disposed) break;
      try {
        await _dropStaleResponderKeys(roomId);
        final wasBlocked = await isBlocked(roomId);
        await _bindingFor(roomId);
        if (!wasBlocked && await isBlocked(roomId)) blocked.add(roomId);
      } catch (_) {}
    }
    return blocked;
  }

  /// 이 기기가 수락을 보냈다가 응답을 못 받아(시간 초과) 키를 남겨 둔 사이, 실제로는 내 다른 기기가 수락했고 그 알림
  /// (secret:accepted)도 꺼져 있어 놓쳤으면 — 방 정보의 "수락한 기기"가 이 기기가 아니다. 그 키를 남겨 두면 상대의
  /// 재키잉에 이 기기도 응답하고(이 기기 키로 서명), 상대 쪽에서는 묶인 기기의 서명이 아니어서 받아 주지 않는다.
  /// 서버가 꾸민 값이면 이 기기의 대화만 끊길 뿐(서버는 원래 메시지를 안 전해 줄 수도 있다) 내용은 새지 않는다. 멈춘
  /// 방은 건드리지 않는다 — 서버가 준 값으로 멈춤을 풀 수 있으면 안 된다.
  Future<void> _dropStaleResponderKeys(String roomId) =>
      _inRoom(roomId, () async {
        final room = _lookupRoom?.call(roomId);
        final me = _myUserId;
        final myDeviceId = _myDeviceIdOrNull;
        if (room == null || me == null || myDeviceId == null) return;
        if ((await _securityOf(roomId)).blocked) return;
        final responderDeviceId = room.secretResponderDeviceId;
        if (room.secretStatus != 'active' ||
            room.secretResponderUserId != me ||
            responderDeviceId == null ||
            responderDeviceId == myDeviceId) {
          return;
        }
        // 이 기기가 지금의 id로 수락해 둔 대화일 때만(공용 PC에서 id가 바뀐 예전 대화 등은 건드리지 않는다).
        if ((await _bindingOf(roomId))?.myDeviceId != myDeviceId) return;
        if (await _keyStore.readChainState(roomId) == null) return;
        await _keyStore.clearSessionKeys(roomId);
        _forgetRoomCaches(roomId);
        await _refreshTrust(roomId);
      });

  // ---- 상대 기기 키 ----

  /// 기기 [deviceId]의 서명 검증키. 이미 고정한 기기면 고정한 키만 쓰고 서버에 다시 묻지 않는다(서버가 그 기기의
  /// 키를 바꿔 답해도 듣지 않는다). 그 고정이 다툼 중이거나 읽을 수 없으면 확인 실패다(어느 키를 믿을지 모른다).
  /// 처음 보는 기기면 — 핸드셰이크([firstUse])일 때만 — 서버에 물어 그 기기의 주인이 [expectedUserId]인지 확인한다.
  /// 고정은 서명을 확인한 뒤에 한다([_pinFirstSeen] — 맞지 않는 키를 고정해 두면 그 기기와는 대화할 수 없다).
  /// 재키잉은 처음 보는 키를 믿지 않는다(방에 묶인 기기는 묶을 때 이미 고정했다). 네트워크 오류는 던진다.
  Future<_PeerKey> _peerKeyFor(
    String deviceId,
    String expectedUserId, {
    bool firstUse = true,
  }) async {
    final entry = await _keyStore.readDevicePinEntry(deviceId);
    if (entry.present) {
      final pin = entry.pin;
      if (pin == null || pin.disputed) {
        return _PeerKey.failed(
          SecretBlockReason.keyMismatch,
          pin: pin,
          pinInvolved: true,
        );
      }
      return pin.userId == expectedUserId
          ? _PeerKey.pinned(pin)
          : const _PeerKey.failed(SecretBlockReason.userMismatch);
    }
    if (!firstUse) return const _PeerKey.unpinned();
    final info = await _api.fetchDeviceSigningPublicKey(deviceId);
    if (info.userId != expectedUserId) {
      return const _PeerKey.failed(SecretBlockReason.userMismatch);
    }
    return _PeerKey.firstSeen(info.signingPublicKey);
  }

  /// 서명을 확인한 처음 보는 기기를 고정한다 — 없을 때만 적는다(SecretKeyStore.pinDeviceIfAbsent). 서버에 묻는 사이
  /// 다른 곳(다른 방의 핸드셰이크·예전 대화 묶기)이 같은 기기를 다른 키·주인으로 먼저 고정했으면, 서버가 같은 기기를
  /// 두 가지로 알려 온 것이다 — 어느 쪽이 진짜인지 모르니 그 고정에 다툼이 적히고, 그 기기에 묶인 다른 방도 모두
  /// 멈춘다(먼저 고정된 쪽이 서버의 키였다면 그 방은 서버와 맺어진 것이다). [ok]가 false면 부른 쪽이 [roomId]를
  /// 멈춘다. [pin]은 지금 고정된 값(깨진 고정이면 null).
  Future<({bool ok, SecretDevicePin? pin})> _pinFirstSeen(
    String roomId,
    String deviceId,
    String userId,
    String signingPublicKey,
  ) async {
    final candidate = SecretDevicePin.firstSeen(
      userId: userId,
      signingPublicKey: signingPublicKey,
    );
    final stored = await _keyStore.pinDeviceIfAbsent(deviceId, candidate);
    if (stored != null && !stored.disputed && stored.sameKeyAs(candidate)) {
      return (ok: true, pin: stored);
    }
    await _blockRoomsBoundTo(
      deviceId,
      SecretBlockReason.keyMismatch,
      pin: stored,
      except: roomId,
    );
    return (ok: false, pin: stored);
  }

  /// 방 [roomId]를 상대 기기에 묶은 뒤 부른다 — 서명을 확인한 그 기기를 고정하고(처음 본 기기면 [_pinFirstSeen]),
  /// 이미 고정한 기기면 그 고정이 아직 그대로인지 다시 본다. 고정한 키를 읽은 뒤 서명을 확인하는 사이 사용자가 그 키를
  /// 지웠거나("상대 기기 키 다시 받기") 다른 방에서 다툼이 드러났으면, 그 일이 이 방을 찾기 전이었을 수 있어서다(묶은
  /// 뒤라 그 뒤의 일은 이 방을 찾아 멈춘다). 실패하면 [failure]. [checkDeviceChange]면 이 사람의 다른 기기를 이 기기에서
  /// 보안 코드로 확인한 적이 있는데 이 기기는 확인하지 않았을 때 [deviceChanged](상대 기기가 바뀌었다고 알린다).
  Future<
    ({SecretBlockReason? failure, SecretDevicePin? pin, bool deviceChanged})
  >
  _pinPeerDevice(
    String roomId,
    String deviceId,
    String userId,
    _PeerKey key, {
    bool checkDeviceChange = true,
  }) async {
    SecretDevicePin? pin;
    if (key.pinned) {
      final entry = await _keyStore.readDevicePinEntry(deviceId);
      final current = entry.pin;
      if (!entry.present) {
        return (
          failure: SecretBlockReason.keyReset,
          pin: null,
          deviceChanged: false,
        );
      }
      if (current == null ||
          current.disputed ||
          !current.isSamePinAs(key.pin!)) {
        return (
          failure: SecretBlockReason.keyMismatch,
          pin: current,
          deviceChanged: false,
        );
      }
      pin = current;
    } else {
      final pinned = await _pinFirstSeen(
        roomId,
        deviceId,
        userId,
        key.signingPublicKey!,
      );
      if (!pinned.ok) {
        return (
          failure: SecretBlockReason.keyMismatch,
          pin: pinned.pin,
          deviceChanged: false,
        );
      }
      pin = pinned.pin;
    }
    if (!checkDeviceChange) {
      return (failure: null, pin: pin, deviceChanged: false);
    }
    final myDeviceId = _identity.deviceId;
    final changed =
        pin?.verifiedAtFor(myDeviceId) == null &&
        await _otherDeviceVerified(userId, deviceId, myDeviceId);
    return (failure: null, pin: pin, deviceChanged: changed);
  }

  Future<bool> _otherDeviceVerified(
    String userId,
    String deviceId,
    String myDeviceId,
  ) async {
    final pins = await _keyStore.devicePinsOfUser(userId);
    return pins.any(
      (e) => e.$1 != deviceId && e.$2.verifiedAtFor(myDeviceId) != null,
    );
  }

  /// [userId]의 기기 [deviceId]가 이 기기가 보안 코드를 확인하지 않은 기기인데, 같은 사람의 다른 기기는 확인한 적이
  /// 있는지 — 초대 대화상자가 "상대가 새 기기에서 요청했다"고 미리 알리는 데 쓴다(서버가 알려 준 기기 id라 참고용).
  Future<bool> isUnverifiedDeviceOfVerifiedPeer(
    String userId,
    String deviceId,
  ) async {
    final myDeviceId = _myDeviceIdOrNull;
    if (myDeviceId == null) return false;
    try {
      final pin = await _keyStore.readDevicePin(deviceId);
      if (pin != null &&
          pin.userId == userId &&
          pin.verifiedAtFor(myDeviceId) != null) {
        return false;
      }
      return await _otherDeviceVerified(userId, deviceId, myDeviceId);
    } catch (_) {
      return false;
    }
  }

  /// 상대가 보낸 서명을 확인한다 — 맥락 서명(v2)을 보냈으면 그것만 본다(키만 서명한 v1은 다른 세션에 다시 끼워
  /// 넣어도 맞으므로 v2가 있으면 보지 않는다). 맥락은 서버가 준 값이 아니라 이 기기가 아는 값으로 만든 [context]다.
  /// v2가 없으면(예전 앱) v1을 고정한 키로 확인하고 [legacy]로 알린다.
  Future<({bool ok, bool legacy})> _verifyPeer({
    required String signingPublicKey,
    required String? contextSignature,
    required String Function() context,
    required String ephemeralPublicKey,
    required String ephemeralSignature,
  }) async {
    if (contextSignature != null) {
      final String text;
      try {
        text = context();
      } on ArgumentError {
        return (ok: false, legacy: false);
      }
      final ok = await crypto.verifyContext(
        signingPublicKeyBase64: signingPublicKey,
        context: text,
        signatureBase64: contextSignature,
      );
      return (ok: ok, legacy: false);
    }
    final ok = await crypto.verifyEphemeralKey(
      signingPublicKeyBase64: signingPublicKey,
      ephemeralPublicKeyBytes: base64Decode(ephemeralPublicKey),
      signatureBase64: ephemeralSignature,
    );
    return (ok: ok, legacy: true);
  }

  /// X25519 공개키(base64, 32바이트) — 모양이 틀리면 null(서버가 꾸민 값 — 서명 확인 실패와 같이 다룬다).
  static List<int>? _x25519Bytes(String base64Key) {
    try {
      final bytes = base64Decode(base64Key);
      return bytes.length == 32 ? bytes : null;
    } on FormatException {
      return null;
    }
  }

  /// 방 [roomId]가 알려진 방이면 [userId]가 그 방 멤버인지(모르는 방이면 확인하지 않는다).
  bool _isMemberOfKnownRoom(String roomId, String userId) {
    final room = _lookupRoom?.call(roomId);
    if (room == null || room.members.isEmpty) return true;
    return room.members.any((m) => m.id == userId);
  }

  /// 알려진 방이면 나를 뺀 멤버 한 명(비밀 대화의 상대).
  String? _otherMemberOf(String roomId) {
    final room = _lookupRoom?.call(roomId);
    if (room == null) return null;
    final others = [
      for (final m in room.members)
        if (m.id != _myUserId) m.id,
    ];
    return others.length == 1 ? others.single : null;
  }

  // ---- 핸드셰이크 ----

  /// 내가 상대에게 비밀 대화를 걸 때. 방이 만들어진 뒤 서버가 돌려준 roomId로 임시키를 저장한다.
  /// [teamId]는 내가 지금 속해 있어야 하는 팀(서버 NOT NULL 제약을 만족시키기 위한 부가
  /// 정보일 뿐 — 상대는 그 팀 소속이 아니어도 된다, server/src/secretChats.js).
  Future<Room> startSecretChat(String targetUserId, String teamId) async {
    final me = _me;
    final myDeviceId = _identity.deviceId;
    final ephemeral = await X25519().newKeyPair();
    final ephemeralPublicKey = await publicKeyBase64(ephemeral);
    final signature = await crypto.signEphemeralKey(
      _identity.signingKeyPair,
      base64Decode(ephemeralPublicKey),
    );
    final contextSignature = await crypto.signContext(
      _identity.signingKeyPair,
      crypto.secretInitContext(
        initiatorUserId: me,
        initiatorDeviceId: myDeviceId,
        responderUserId: targetUserId,
        initiatorEphemeralPublicKey: ephemeralPublicKey,
      ),
    );

    final result = await _api.startSecretChat(
      targetUserId: targetUserId,
      deviceId: myDeviceId,
      initiatorEphemeralPublicKey: ephemeralPublicKey,
      initiatorEphemeralSignature: signature,
      initiatorContextSignature: contextSignature,
      teamId: teamId,
    );
    // 이미 진행 중인 대화가 있어 서버가 그 방을 돌려줬으면(created가 false) 서버는 이번 임시키를 받지 않았다 — 상대는
    // 그 방의 원래 임시키로 수락하므로, 여기서 새 키를 대기시키면 수락이 와도 체인이 어긋난다.
    if (result.created) {
      await _keyStore.savePendingEphemeralSeed(
        result.room.id,
        await ephemeral.extractPrivateKeyBytes(),
        targetUserId: targetUserId,
        myDeviceId: myDeviceId,
      );
    }
    return result.room;
  }

  /// 상대의 초대(secret:invite)를 수락한다 — 서명을 먼저 검증하고, 통과해야만 진행한다.
  /// 서버가 수락을 받지 않으면(내 다른 기기가 먼저 수락함 등) 이 기기에 적은 키를 되돌리고
  /// [SecretChatRefusedException]을 던진다.
  Future<SecretHandshakeOutcome> acceptInvite(SecretInviteEvent invite) =>
      _inRoom(invite.roomId, () async {
        final roomId = invite.roomId;
        final me = _me;
        final myDeviceId = _identity.deviceId;
        if ((await _securityOf(roomId)).blocked) {
          return SecretHandshakeOutcome.blocked;
        }
        final peerUserId = invite.initiatorUserId;
        final peerDeviceId = invite.initiatorDeviceId;
        // 초대를 보낸 사람이 이 방의 상대가 맞는지 — 나 자신이거나 방에 없는 사람이면 서버가 꾸민 초대다.
        if (peerUserId == me || !_isMemberOfKnownRoom(roomId, peerUserId)) {
          return _block(roomId, SecretBlockReason.peerMismatch);
        }
        final existing = await _bindingOf(roomId);
        if (existing != null &&
            (existing.peerUserId != peerUserId ||
                existing.peerDeviceId != peerDeviceId)) {
          return _block(roomId, SecretBlockReason.deviceMismatch);
        }
        final theirEphemeralBytes = _x25519Bytes(
          invite.initiatorEphemeralPublicKey,
        );
        if (theirEphemeralBytes == null) {
          return _block(roomId, SecretBlockReason.badSignature);
        }
        final key = await _peerKeyFor(peerDeviceId, peerUserId);
        final keyFailure = key.failure;
        if (keyFailure != null) {
          return _blockForKey(roomId, peerDeviceId, key, keyFailure);
        }
        final check = await _verifyPeer(
          signingPublicKey: key.signingPublicKey!,
          contextSignature: invite.initiatorContextSignature,
          context: () => crypto.secretInitContext(
            initiatorUserId: peerUserId,
            initiatorDeviceId: peerDeviceId,
            responderUserId: me,
            initiatorEphemeralPublicKey: invite.initiatorEphemeralPublicKey,
          ),
          ephemeralPublicKey: invite.initiatorEphemeralPublicKey,
          ephemeralSignature: invite.initiatorEphemeralSignature,
        );
        // 서버가 키를 바꿔치기했거나 변조됨 — 절대 진행하지 않는다.
        if (!check.ok) {
          return _blockForKey(
            roomId,
            peerDeviceId,
            key,
            SecretBlockReason.badSignature,
          );
        }
        // 상대 기기에 먼저 묶고 그다음 고정한다 — 다른 방에서 이 기기의 키 다툼이 드러나면 그 기기에 묶인 방을 모두
        // 멈추는데, 고정과 묶음 사이에 그 일이 끼어도 이 방이 빠지지 않게. 고정은 체인키를 적기 전에 — 같은 기기를
        // 다른 키로 먼저 고정한 곳이 있으면 여기서 멈춘다(묶음은 멈춘 방에 남아도 쓰이지 않는다).
        await _saveBinding(
          roomId,
          SecretRoomBinding(
            peerUserId: peerUserId,
            peerDeviceId: peerDeviceId,
            myDeviceId: myDeviceId,
          ),
        );
        final pinned = await _pinPeerDevice(
          roomId,
          peerDeviceId,
          peerUserId,
          key,
        );
        final pinFailure = pinned.failure;
        if (pinFailure != null) {
          return _block(
            roomId,
            pinFailure,
            deviceId: peerDeviceId,
            pin: pinned.pin,
          );
        }
        final deviceChanged = pinned.deviceChanged;

        final myEphemeral = await X25519().newKeyPair();
        final myEphemeralPublicKey = await publicKeyBase64(myEphemeral);
        final mySignature = await crypto.signEphemeralKey(
          _identity.signingKeyPair,
          base64Decode(myEphemeralPublicKey),
        );
        final myContextSignature = await crypto.signContext(
          _identity.signingKeyPair,
          crypto.secretAcceptContext(
            roomId: roomId,
            initiatorUserId: peerUserId,
            initiatorDeviceId: peerDeviceId,
            initiatorEphemeralPublicKey: invite.initiatorEphemeralPublicKey,
            responderUserId: me,
            responderDeviceId: myDeviceId,
            responderEphemeralPublicKey: myEphemeralPublicKey,
          ),
        );

        final chainKey = await crypto.deriveInitialChainKey(
          myEphemeralKeyPair: myEphemeral,
          theirEphemeralPublicKey: SimplePublicKey(
            theirEphemeralBytes,
            type: KeyPairType.x25519,
          ),
          roomId: roomId,
        );
        // 묶음(위)은 체인키보다 먼저 적혀 있다 — 체인키가 있는데 묶인 기기가 없으면 예전 대화로 보고 방 정보로
        // 묶으려 하기 때문이다.
        await _saveSecurity(
          roomId,
          (await _securityOf(roomId)).copyWith(
            legacyPeer: check.legacy,
            peerDeviceChanged: deviceChanged,
          ),
        );
        await _keyStore.saveChainState(
          roomId,
          SecretChainState(epoch: 0, n: 0, chainKey: chainKey),
        );
        _epochMessageCount[roomId] = 0;
        _epochStartedAt[roomId] = DateTime.now();

        try {
          await _api.acceptSecretChat(
            roomId: roomId,
            deviceId: myDeviceId,
            responderEphemeralPublicKey: myEphemeralPublicKey,
            responderEphemeralSignature: mySignature,
            responderContextSignature: myContextSignature,
          );
        } on SecretChatRefusedException {
          // 서버가 이 기기의 수락을 받지 않았다 — 이 기기는 이 대화의 기기가 아니다. 키를 남겨 두면 상대의 재키잉에
          // 이 기기도 응답해(다른 기기 키로 서명) 상대 쪽에서 가로채기로 보고 대화가 멈춘다. 응답이 없었던 경우
          // (시간 초과)는 처리됐을 수 있어 그대로 둔다.
          await _keyStore.clearSessionKeys(roomId);
          _forgetRoomCaches(roomId);
          rethrow;
        } finally {
          await _refreshTrust(roomId);
        }
        return deviceChanged
            ? SecretHandshakeOutcome.establishedOnChangedDevice
            : SecretHandshakeOutcome.established;
      });

  Future<void> rejectInvite(String roomId) async {
    await _api.rejectSecretChat(roomId);
    await _inRoom(roomId, () => _keyStore.clearRoom(roomId));
    _forgetRoomCaches(roomId);
  }

  /// 상대가 내 초대를 수락했다는 브로드캐스트(secret:accepted)를 받았을 때 — 이제 나도 체인키를
  /// 계산할 수 있다(내가 처음 만들었던 임시 개인키 + 상대의 임시 공개키).
  Future<SecretHandshakeOutcome> handleAccepted(
    SecretAcceptedEvent event,
  ) => _inRoom(event.roomId, () async {
    final roomId = event.roomId;
    final me = _me;
    final myDeviceId = _identity.deviceId;
    if (event.responderUserId == me) {
      if (event.responderDeviceId != myDeviceId &&
          await _keyStore.readPendingEphemeralSeed(roomId) == null &&
          !(await _securityOf(roomId)).blocked) {
        // 내 다른 기기가 이 초대를 수락했다 — 이 기기가 수락을 보냈다가 응답을 못 받아 남은 키가 있다면 이 대화의
        // 것이 아니다(남겨 두면 상대의 재키잉에 응답해 상대와 어긋난다). 멈춘 방은 건드리지 않는다 — 이 알림은 서버가
        // 보내는 값이라, 이것으로 키를 치우다 멈춤까지 풀리면 가로채려다 들킨 서버가 멈춤을 풀 수 있다.
        if (await _keyStore.readChainState(roomId) != null &&
            (await _bindingOf(roomId))?.myDeviceId == myDeviceId) {
          await _keyStore.clearSessionKeys(roomId);
          _forgetRoomCaches(roomId);
          await _refreshTrust(roomId);
        }
      }
      return SecretHandshakeOutcome.ignored; // 내가(이 기기 또는 다른 기기) 수락한 것이 되돌아온 것.
    }
    final myPendingSeed = await _keyStore.readPendingEphemeralSeed(roomId);
    if (myPendingSeed == null) {
      return SecretHandshakeOutcome.ignored; // 이미 처리됐거나 이 기기가 초대자가 아님.
    }
    // 이미 성립한 대화에 늦게 온(또는 꾸민) 수락 — 체인을 새로 만들면 지금 대화가 깨진다.
    if (await _keyStore.readChainState(roomId) != null) {
      return SecretHandshakeOutcome.ignored;
    }
    // 이미 멈춘 방 — 아무것도 하지 않는다(멈췄다는 안내는 처음 멈출 때 한 번만).
    if ((await _securityOf(roomId)).blocked) {
      return SecretHandshakeOutcome.ignored;
    }
    final pendingInit = await _keyStore.readPendingInit(roomId);
    // 수락한 사람은 내가 초대한 사람이어야 한다 — 서버가 알려 주는 수락자를 그대로 믿지 않는다. 업데이트 전에 건
    // 초대(초대한 상대를 적어 두지 않음)면 방의 상대 멤버로 본다.
    final expected = pendingInit.targetUserId ?? _otherMemberOf(roomId);
    final peerUserId = event.responderUserId ?? expected;
    if (peerUserId == null) {
      return SecretHandshakeOutcome.ignored; // 누구와의 대화인지 모르면 확인할 수 없다.
    }
    if ((expected != null && peerUserId != expected) ||
        !_isMemberOfKnownRoom(roomId, peerUserId)) {
      return _block(roomId, SecretBlockReason.peerMismatch);
    }
    final peerDeviceId = event.responderDeviceId;
    final existing = await _bindingOf(roomId);
    if (existing != null &&
        (existing.peerUserId != peerUserId ||
            existing.peerDeviceId != peerDeviceId)) {
      return _block(roomId, SecretBlockReason.deviceMismatch);
    }
    final theirEphemeralBytes = _x25519Bytes(event.responderEphemeralPublicKey);
    if (theirEphemeralBytes == null) {
      return _block(roomId, SecretBlockReason.badSignature);
    }
    final key = await _peerKeyFor(peerDeviceId, peerUserId);
    final keyFailure = key.failure;
    if (keyFailure != null) {
      return _blockForKey(roomId, peerDeviceId, key, keyFailure);
    }

    final myEphemeral = await X25519().newKeyPairFromSeed(myPendingSeed);
    final myEphemeralPublicKey = await publicKeyBase64(myEphemeral);
    // 초대할 때 쓴 이 기기 id — 그 뒤 이 기기의 id가 바뀌었어도 상대는 초대에 실린 id로 서명했다.
    final initiatorDeviceId = pendingInit.myDeviceId ?? myDeviceId;
    final check = await _verifyPeer(
      signingPublicKey: key.signingPublicKey!,
      contextSignature: event.responderContextSignature,
      context: () => crypto.secretAcceptContext(
        roomId: roomId,
        initiatorUserId: me,
        initiatorDeviceId: initiatorDeviceId,
        initiatorEphemeralPublicKey: myEphemeralPublicKey,
        responderUserId: peerUserId,
        responderDeviceId: peerDeviceId,
        responderEphemeralPublicKey: event.responderEphemeralPublicKey,
      ),
      ephemeralPublicKey: event.responderEphemeralPublicKey,
      ephemeralSignature: event.responderEphemeralSignature,
    );
    if (!check.ok) {
      return _blockForKey(
        roomId,
        peerDeviceId,
        key,
        SecretBlockReason.badSignature,
      );
    }
    // 상대 기기에 먼저 묶고 그다음 고정한다(acceptInvite와 같은 까닭 — 다른 방에서 드러난 키 다툼이 이 방을 빠뜨리지
    // 않게). 고정은 체인키를 적기 전에 — 같은 기기를 다른 키로 먼저 고정한 곳이 있으면 여기서 멈춘다.
    await _saveBinding(
      roomId,
      SecretRoomBinding(
        peerUserId: peerUserId,
        peerDeviceId: peerDeviceId,
        myDeviceId: initiatorDeviceId,
      ),
    );
    final pinned = await _pinPeerDevice(roomId, peerDeviceId, peerUserId, key);
    final pinFailure = pinned.failure;
    if (pinFailure != null) {
      return _block(
        roomId,
        pinFailure,
        deviceId: peerDeviceId,
        pin: pinned.pin,
      );
    }
    final deviceChanged = pinned.deviceChanged;

    final chainKey = await crypto.deriveInitialChainKey(
      myEphemeralKeyPair: myEphemeral,
      theirEphemeralPublicKey: SimplePublicKey(
        theirEphemeralBytes,
        type: KeyPairType.x25519,
      ),
      roomId: roomId,
    );
    await _saveSecurity(
      roomId,
      (await _securityOf(
        roomId,
      )).copyWith(legacyPeer: check.legacy, peerDeviceChanged: deviceChanged),
    );
    await _keyStore.saveChainState(
      roomId,
      SecretChainState(epoch: 0, n: 0, chainKey: chainKey),
    );
    await _keyStore.clearPendingEphemeralSeed(roomId);
    _epochMessageCount[roomId] = 0;
    _epochStartedAt[roomId] = DateTime.now();
    await _refreshTrust(roomId);
    return deviceChanged
        ? SecretHandshakeOutcome.establishedOnChangedDevice
        : SecretHandshakeOutcome.established;
  });

  Future<bool> hasActiveSession(String roomId) async =>
      await _keyStore.readChainState(roomId) != null;

  // ---- 평문 캐시(secret_key_store.dart) ----

  /// 이미 한 번 복호화에 성공한 메시지/댓글의 평문을 재사용한다(한 방향 래칫이라 두 번째부터는
  /// 암호문을 다시 복호화할 수 없기 때문 — secret_key_store.dart 참고). 서버가 지운 메시지의 평문이
  /// 이 기기에 남지 않도록 방·작성 시각·삭제 예정 시각을 함께 적어 둔다.
  Future<String?> readCachedDecryptedText(SecretTextRef ref) =>
      _keyStore.readDecryptedText(ref);

  Future<void> cacheDecryptedText(SecretTextRef ref, String text) =>
      _keyStore.saveDecryptedText(ref, text);

  /// 메시지·댓글이 지워졌을 때(message:deleted / comment:deleted).
  Future<void> forgetDecryptedText(String roomId, String id) =>
      _keyStore.deleteDecryptedText(roomId, id);

  /// 서버가 메시지를 완전히 지웠을 때(message:expired) — 그 댓글 평문까지.
  Future<void> forgetExpiredMessage(String roomId, String messageId) =>
      _keyStore.deleteMessageTexts(roomId, messageId);

  /// 서버가 메시지 읽음을 확정했을 때(secret:message-read) — 그 자동 삭제 시각을 적어 둔다.
  Future<void> noteMessageRead(String messageId, DateTime? expiresAt) =>
      _keyStore.noteMessageRead(messageId, expiresAt);

  /// 이 기기가 타이머가 켜진 방에서 메시지 읽음을 보냈을 때 — 확정 알림을 못 받아도 지워지게 어림한
  /// 삭제 예정 시각을 먼저 적어 둔다.
  Future<void> noteLocalRead(String messageId, Duration selfDestruct) =>
      _keyStore.noteLocalRead(messageId, selfDestruct);

  /// 히스토리를 요청하기 직전에 잡아 두는 평문 캐시 저장 순번([reconcileHistoryPage]에 넘긴다).
  int get textCacheGeneration => _keyStore.textCacheGeneration;

  /// 히스토리 한 페이지로 서버가 더 이상 주지 않는(지운) 메시지·댓글의 평문을 지운다 — SecretKeyStore 참고.
  Future<List<SecretCachedTextInfo>> reconcileHistoryPage({
    required String roomId,
    required List<Message> page,
    required DateTime? before,
    required int limit,
    required int sinceGeneration,
  }) => _keyStore.reconcileHistoryPage(
    roomId: roomId,
    page: page,
    before: before,
    limit: limit,
    sinceGeneration: sinceGeneration,
  );

  /// 삭제 예정 시각이 지난 평문을 지운다(앱 시작·방 열기·포그라운드 복귀 때, 그리고 스스로 타이머로).
  Future<List<SecretCachedTextInfo>> purgeExpiredTexts() =>
      _keyStore.purgeExpiredTexts();

  /// 삭제 예정 시각이 지나 지운 항목을 알려 줄 곳(열려 있는 방 화면에서도 빼도록).
  set onExpiredTextsPurged(
    void Function(List<SecretCachedTextInfo> removed)? callback,
  ) => _keyStore.onExpiredTextsPurged = callback;

  /// 이 기기의 비밀 대화 평문 캐시 — Session이 방 화면 없이 서버와 맞추는 뒷정리(서버 시각 알려 주기, 히스토리
  /// 페이지 반영, 남은 방 찾기, 예전 형식 정리)에 쓴다. 방이 없어졌을 때는 키까지 지우는 [forgetRoom]을 쓴다.
  SecretKeyStore get textCache => _keyStore;

  /// 로그아웃·재로그인으로 이 매니저를 버릴 때 — 평문 정리 타이머를 멈춘다.
  void dispose() {
    _disposed = true;
    onTrustChanged = null;
    _keyStore.dispose();
  }

  // ---- 암복호화 ----

  /// 메시지/댓글 전송 직전 — 평문을 암호문 봉투(JSON)로 바꾸고, 필요하면 재키잉을 함께 트리거한다.
  /// 세션이 아직 성립되지 않았으면(핸드셰이크 진행 중) null을 돌려준다 — 호출자는 전송을 보류해야 한다.
  /// 보안 확인에 실패해 멈춘 방이면 [SecretChatBlockedException]을 던진다.
  Future<String?> encryptForRoom(String roomId, String plainText) => _inRoom(
    roomId,
    () async {
      if ((await _securityOf(roomId)).blocked) {
        throw const SecretChatBlockedException();
      }
      final state = await _keyStore.readChainState(roomId);
      if (state == null) return null;

      final step = await crypto.ratchetStep(state.chainKey);
      final envelope = await crypto.encryptEnvelope(
        msgKey: step.msgKey,
        plainText: plainText,
        roomId: roomId,
        epoch: state.epoch,
        n: state.n,
      );
      await _keyStore.saveChainState(
        roomId,
        SecretChainState(
          epoch: state.epoch,
          n: state.n + 1,
          chainKey: step.nextChainKey,
          prevEpoch: state.prevEpoch,
          prevChainKeySnapshot: state.prevChainKeySnapshot,
        ),
      );
      _recentlySentPlaintext[_envelopeCacheKey(roomId, state.epoch, state.n)] =
          plainText;

      await _maybeTriggerRekey(roomId, state.epoch);
      return jsonEncode(envelope);
    },
  );

  /// 수신한 암호문 봉투를 평문으로. 실패(다른 세션/변조/너무 오래된 epoch)하면 null.
  Future<String?> decryptForRoom(String roomId, String envelopeJson) =>
      _inRoom(roomId, () async {
        final envelope = jsonDecode(envelopeJson) as Map<String, dynamic>;
        final epoch = envelope['epoch'] as int;
        final n = envelope['n'] as int;

        // 내가 방금 보낸 메시지의 echo면(server가 보낸 사람에게도 그대로 돌려줌) 여기서
        // 바로 끝낸다 — 래칫 상태는 encryptForRoom에서 이미 전진해있어서 아래 상태 기반 로직으로는
        // (한 방향이라) 다시 계산할 수 없다.
        final cached = _recentlySentPlaintext.remove(
          _envelopeCacheKey(roomId, epoch, n),
        );
        if (cached != null) return cached;

        // 멈춘 대화는 새로 받은 것도 풀지 않는다 — 상대 기기 키를 믿을 수 없게 돼 멈췄으면(키 다툼·사용자가 키를 지움)
        // 이 체인을 서버와 맺었을 수 있어, 서버가 상대인 척 보낸 글을 그대로 보여 주게 된다. 이미 풀어 둔 평문은
        // 평문 캐시에서 그대로 보인다.
        if ((await _securityOf(roomId)).blocked) return null;

        final state = await _keyStore.readChainState(roomId);
        if (state == null) return null;

        List<int>? msgKey;
        if (epoch == state.epoch) {
          msgKey = await crypto.catchUpTo(state.chainKey, n - state.n);
          if (msgKey != null && n >= state.n) {
            // 이 메시지까지 감았으므로, 로컬 체인키도 그만큼 전진시켜 저장(순서대로 도착하는
            // 일반적인 경우 다음 ratchetStep 호출과 중복 계산되지 않게).
            var key = state.chainKey;
            for (var i = 0; i <= n - state.n; i++) {
              key = (await crypto.ratchetStep(key)).nextChainKey;
            }
            await _keyStore.saveChainState(
              roomId,
              SecretChainState(
                epoch: state.epoch,
                n: n + 1,
                chainKey: key,
                prevEpoch: state.prevEpoch,
                prevChainKeySnapshot: state.prevChainKeySnapshot,
              ),
            );
          }
        } else if (state.prevEpoch == epoch &&
            state.prevChainKeySnapshot != null) {
          msgKey = await crypto.catchUpTo(state.prevChainKeySnapshot!, n);
        }
        if (msgKey == null) return null;

        return crypto.decryptEnvelope(
          msgKey: msgKey,
          envelope: envelope,
          roomId: roomId,
        );
      });

  // ---- 재키잉 ----

  /// 메시지 수·시간이 차면(또는 [force]) 새 임시키로 재키잉을 제안한다. 방 줄 안에서만 부른다.
  Future<void> _maybeTriggerRekey(
    String roomId,
    int currentEpoch, {
    bool force = false,
  }) async {
    final count = (_epochMessageCount[roomId] ?? 0) + 1;
    _epochMessageCount[roomId] = count;
    final startedAt = _epochStartedAt[roomId] ??= DateTime.now();
    final dueByCount = count >= crypto.rekeyMessageThreshold;
    final dueByTime =
        DateTime.now().difference(startedAt) >= crypto.rekeyTimeThreshold;
    if (!force && !dueByCount && !dueByTime) return;

    final me = _myUserId;
    if (me == null) return;
    // 상대 기기를 모르면 상대의 응답(ack)을 확인할 수 없다 — 응답한 상대만 새 epoch로 넘어가 대화가 어긋나므로 제안을
    // 미룬다(예전 대화면 방 정보로 묶어 두고 다음 메시지 때 다시 본다). 서버에 묻는 동안 메시지 전송을 붙잡지 않는다.
    final binding = await _bindingOf(roomId);
    if (binding == null) {
      unawaited(_bindingFor(roomId).then((_) {}, onError: (Object _) {}));
      return;
    }
    // 대화를 맺은 뒤 이 기기의 id·키가 바뀌었다 — 상대는 예전 키를 고정해 두어서 새 키로 서명한 제안은 상대 쪽에서
    // 받아 주지 않는다. 재키잉 없이 지금 체인을 계속 쓴다.
    final myDeviceId = _identity.deviceId;
    if (binding.myDeviceId != null && binding.myDeviceId != myDeviceId) return;

    final newEpoch = currentEpoch + 1;
    final pending = await _keyStore.readPendingRekeySeed(roomId);
    final SimpleKeyPair ephemeral;
    if (pending != null && pending.$1 == newEpoch) {
      // 이미 이 epoch로 제안해 두고 수락을 기다리는 중이다. 새 임시키로 또 제안하면, 상대가 먼저 받은 제안에 답한
      // 수락이 오는 사이 대기 중인 키가 바뀌어 있어 체인이 어긋나고, 수락의 맥락 서명(제안한 임시 공개키가 들어
      // 있다)도 맞지 않는다. 같은 제안을 그대로 다시 보낸다 — 상대가 못 받았을 수 있다(서버는 끊겨 있던 기기에 다시
      // 보내 주지 않는다). 상대는 이미 넘어간 epoch의 제안을 무시하므로 여러 번 가도 되지만, 메시지마다 보내지는 않는다.
      final sentAt = _rekeyProposalSentAt[roomId];
      if (!force &&
          sentAt != null &&
          DateTime.now().difference(sentAt) < _rekeyResendInterval) {
        return;
      }
      ephemeral = await X25519().newKeyPairFromSeed(pending.$2);
    } else {
      ephemeral = await X25519().newKeyPair();
      await _keyStore.savePendingRekeySeed(
        roomId,
        newEpoch,
        await ephemeral.extractPrivateKeyBytes(),
      );
    }
    // Ed25519 서명은 같은 키·같은 내용이면 늘 같아서, 다시 보내는 제안도 처음 것과 같다.
    final ephemeralPublicKey = await publicKeyBase64(ephemeral);
    final signature = await crypto.signEphemeralKey(
      _identity.signingKeyPair,
      base64Decode(ephemeralPublicKey),
    );
    final contextSignature = await crypto.signContext(
      _identity.signingKeyPair,
      crypto.secretRekeyProposeContext(
        roomId: roomId,
        keyEpoch: newEpoch,
        proposerUserId: me,
        proposerDeviceId: myDeviceId,
        proposerEphemeralPublicKey: ephemeralPublicKey,
      ),
    );
    _socket.proposeSecretRekey(
      roomId: roomId,
      keyEpoch: newEpoch,
      ephemeralPublicKey: ephemeralPublicKey,
      ephemeralSignature: signature,
      ephemeralContextSignature: contextSignature,
    );
    _rekeyProposalSentAt[roomId] = DateTime.now();
  }

  /// 테스트용 — 메시지 수·시간과 상관없이 지금 재키잉을 제안한다.
  @visibleForTesting
  Future<void> proposeRekeyNow(String roomId) => _inRoom(roomId, () async {
    final state = await _keyStore.readChainState(roomId);
    if (state == null) return;
    await _maybeTriggerRekey(roomId, state.epoch, force: true);
  });

  /// 재키잉 이벤트를 처리하기 전 공통 확인 — 이 방이 묶인 상대 기기(아니면 null과 함께 결과). 서버에 물을 수 있는
  /// 일(예전 대화를 방 정보로 묶기)은 방 줄 밖에서 먼저 해 둔다.
  Future<(SecretRoomBinding?, SecretHandshakeOutcome?)> _rekeyBinding(
    SecretRekeyEvent event,
  ) async {
    final roomId = event.roomId;
    // 이미 멈춘 방 — 아무것도 하지 않는다(멈췄다는 안내는 처음 멈출 때 한 번만).
    if ((await _securityOf(roomId)).blocked) {
      return (null, SecretHandshakeOutcome.ignored);
    }
    final binding = await _bindingOf(roomId);
    // 세션이 성립되지 않은 방에서 온 재키잉 — 무시.
    if (binding == null) return (null, SecretHandshakeOutcome.ignored);
    // 재키잉은 사용자 id만 실려 온다 — 이 방에 묶인 상대가 아닌 사람이면 서버가 꾸민 것이다.
    if (event.userId != binding.peerUserId) {
      return (null, await _block(roomId, SecretBlockReason.peerMismatch));
    }
    // 대화를 맺은 뒤 이 기기의 id·키가 바뀌었다 — 응답(새 키로 서명)하면 상대 쪽에서 막히므로 응답하지 않는다.
    if (binding.myDeviceId != null &&
        binding.myDeviceId != _identity.deviceId) {
      return (null, SecretHandshakeOutcome.ignored);
    }
    return (binding, null);
  }

  /// 재키잉을 확인할 상대 기기 키 — 방에 묶인 기기의 고정한 키만 쓴다(재키잉으로는 서버가 알려 주는 키를 처음 믿지
  /// 않는다). 그 고정이 주인이 다르거나 다툼 중·깨짐이면 방을 멈추고 그 결과를, 고정이 없으면(저장소가 깨짐 등) 무시
  /// 결과를 함께 돌려준다.
  Future<(String?, SecretHandshakeOutcome?)> _rekeyPeerKey(
    String roomId,
    SecretRoomBinding binding,
  ) async {
    final key = await _peerKeyFor(
      binding.peerDeviceId,
      binding.peerUserId,
      firstUse: false,
    );
    final keyFailure = key.failure;
    if (keyFailure != null) {
      return (
        null,
        await _blockForKey(roomId, binding.peerDeviceId, key, keyFailure),
      );
    }
    final signingKey = key.signingPublicKey;
    if (signingKey == null) return (null, SecretHandshakeOutcome.ignored);
    return (signingKey, null);
  }

  /// 확인에 실패한 재키잉 제안·수락을 무시한다 — 방을 멈추지 않는다. 무시하면 체인은 그대로라 멈추는 것과 안전은
  /// 같고, 재키잉에는 사용자 id만 실려 와서 상대의 다른 기기(예전 앱에서 같은 초대를 두 기기로 수락해 남은 기기 등)가
  /// 자기 키로 보낸 것일 수 있다 — 그런 기기 하나 때문에 정상 대화가 영영 멈추면 안 된다. 핸드셰이크 실패와 고정의
  /// 주인이 다른 경우는 그대로 멈춘다.
  SecretHandshakeOutcome _ignoreUnverifiedRekey(
    SecretRekeyEvent event,
    String kind,
  ) {
    debugPrint(
      '[secret] 확인되지 않은 재키잉 $kind 무시: room=${event.roomId} epoch=${event.keyEpoch}',
    );
    return SecretHandshakeOutcome.ignored;
  }

  /// 상대가 재키잉을 제안했을 때 — 서명 검증 후 내 임시키로 응답(ack)한다.
  Future<SecretHandshakeOutcome> handleRekeyPropose(
    SecretRekeyEvent event,
  ) async {
    final roomId = event.roomId;
    // 내 다른 기기(이 방의 세션이 없는 기기)가 보낸 것 — 관계없다.
    if (event.userId == _myUserId || _myUserId == null) {
      return SecretHandshakeOutcome.ignored;
    }
    if (await _keyStore.readChainState(roomId) == null) {
      return SecretHandshakeOutcome.ignored;
    }
    // 이 업데이트 전에 성립한 대화면 방 정보로 상대 기기를 묶어 둔다(서버에 물을 수 있어 방 줄 밖에서).
    try {
      await _bindingFor(roomId);
    } catch (_) {}
    return _inRoom(roomId, () async {
      final me = _me;
      final state = await _keyStore.readChainState(roomId);
      if (state == null) return SecretHandshakeOutcome.ignored;
      final (binding, early) = await _rekeyBinding(event);
      if (binding == null) return early!;
      // 지난 epoch의 제안(재전송) — 서명이 맞아도 지난 키로 체인을 다시 만들면 안 된다.
      if (event.keyEpoch <= state.epoch) return SecretHandshakeOutcome.ignored;
      final theirEphemeralBytes = _x25519Bytes(event.ephemeralPublicKey);
      if (theirEphemeralBytes == null) {
        return _ignoreUnverifiedRekey(event, '제안(임시키 모양이 틀림)');
      }
      final (signingKey, keyOutcome) = await _rekeyPeerKey(roomId, binding);
      if (signingKey == null) return keyOutcome!;
      final check = await _verifyPeer(
        signingPublicKey: signingKey,
        contextSignature: event.contextSignature,
        context: () => crypto.secretRekeyProposeContext(
          roomId: roomId,
          keyEpoch: event.keyEpoch,
          proposerUserId: binding.peerUserId,
          proposerDeviceId: binding.peerDeviceId,
          proposerEphemeralPublicKey: event.ephemeralPublicKey,
        ),
        ephemeralPublicKey: event.ephemeralPublicKey,
        ephemeralSignature: event.ephemeralSignature,
      );
      if (!check.ok) return _ignoreUnverifiedRekey(event, '제안');

      // 동시 제안 충돌: 상대와 내가 근접한 시점에 각자 제안했다면 deviceId 사전순으로 낮은
      // 쪽이 이긴다 — 내가 이미 같은 epoch로 제안 중이고 내 deviceId가 더 작으면(=우선순위가
      // 높으면) 내 제안을 유지하고 상대 제안은 무시한다.
      final myDeviceId = _identity.deviceId;
      final myPending = await _keyStore.readPendingRekeySeed(roomId);
      if (myPending != null && myPending.$1 == event.keyEpoch) {
        // 내가 우선 — 상대가 내 제안에 ack하기를 기다린다.
        if (myDeviceId.compareTo(binding.peerDeviceId) < 0) {
          return SecretHandshakeOutcome.ignored;
        }
        // 내 제안을 접고 상대 걸 받아들인다.
        await _keyStore.clearPendingRekeySeed(roomId);
        _rekeyProposalSentAt.remove(roomId);
      }

      final myEphemeral = await X25519().newKeyPair();
      final myEphemeralPublicKey = await publicKeyBase64(myEphemeral);
      final mySignature = await crypto.signEphemeralKey(
        _identity.signingKeyPair,
        base64Decode(myEphemeralPublicKey),
      );
      final myContextSignature = await crypto.signContext(
        _identity.signingKeyPair,
        crypto.secretRekeyAckContext(
          roomId: roomId,
          keyEpoch: event.keyEpoch,
          responderUserId: me,
          responderDeviceId: myDeviceId,
          proposerEphemeralPublicKey: event.ephemeralPublicKey,
          responderEphemeralPublicKey: myEphemeralPublicKey,
        ),
      );

      final newChainKey = await crypto.deriveRekeyChainKey(
        myNewEphemeralKeyPair: myEphemeral,
        theirNewEphemeralPublicKey: SimplePublicKey(
          theirEphemeralBytes,
          type: KeyPairType.x25519,
        ),
        previousChainKeyLastValue: state.chainKey,
        newEpoch: event.keyEpoch,
      );
      await _keyStore.saveChainState(
        roomId,
        SecretChainState(
          epoch: event.keyEpoch,
          n: 0,
          chainKey: newChainKey,
          prevEpoch: state.epoch,
          prevChainKeySnapshot: state.chainKey,
        ),
      );
      await _noteLegacy(roomId, check.legacy);
      _epochMessageCount[roomId] = 0;
      _epochStartedAt[roomId] = DateTime.now();

      _socket.ackSecretRekey(
        roomId: roomId,
        keyEpoch: event.keyEpoch,
        ephemeralPublicKey: myEphemeralPublicKey,
        ephemeralSignature: mySignature,
        ephemeralContextSignature: myContextSignature,
      );
      return SecretHandshakeOutcome.established;
    });
  }

  /// 내가 먼저 제안했던 재키잉을 상대가 수락(ack)했을 때 — 이제 나도 새 체인키를 계산한다.
  Future<SecretHandshakeOutcome> handleRekeyAck(SecretRekeyEvent event) async {
    final roomId = event.roomId;
    // 내가 보낸 ack가 되돌아온 것(서버는 방 전체에 보낸다) 또는 내 다른 기기 — 관계없다.
    if (event.userId == _myUserId || _myUserId == null) {
      return SecretHandshakeOutcome.ignored;
    }
    final pendingBefore = await _keyStore.readPendingRekeySeed(roomId);
    if (pendingBefore == null || pendingBefore.$1 != event.keyEpoch) {
      return SecretHandshakeOutcome.ignored;
    }
    try {
      await _bindingFor(roomId);
    } catch (_) {}
    return _inRoom(roomId, () async {
      final pending = await _keyStore.readPendingRekeySeed(roomId);
      if (pending == null || pending.$1 != event.keyEpoch) {
        return SecretHandshakeOutcome.ignored;
      }
      final state = await _keyStore.readChainState(roomId);
      if (state == null) return SecretHandshakeOutcome.ignored;
      final (binding, early) = await _rekeyBinding(event);
      if (binding == null) return early!;
      final theirEphemeralBytes = _x25519Bytes(event.ephemeralPublicKey);
      if (theirEphemeralBytes == null) {
        return _ignoreUnverifiedRekey(event, '수락(임시키 모양이 틀림)');
      }
      final (signingKey, keyOutcome) = await _rekeyPeerKey(roomId, binding);
      if (signingKey == null) return keyOutcome!;
      final myEphemeral = await X25519().newKeyPairFromSeed(pending.$2);
      final myEphemeralPublicKey = await publicKeyBase64(myEphemeral);
      final check = await _verifyPeer(
        signingPublicKey: signingKey,
        contextSignature: event.contextSignature,
        context: () => crypto.secretRekeyAckContext(
          roomId: roomId,
          keyEpoch: event.keyEpoch,
          responderUserId: binding.peerUserId,
          responderDeviceId: binding.peerDeviceId,
          proposerEphemeralPublicKey: myEphemeralPublicKey,
          responderEphemeralPublicKey: event.ephemeralPublicKey,
        ),
        ephemeralPublicKey: event.ephemeralPublicKey,
        ephemeralSignature: event.ephemeralSignature,
      );
      // 대기 중인 제안은 그대로 둔다 — 묶인 기기의 진짜 수락이 뒤이어 오면 그것으로 넘어간다.
      if (!check.ok) return _ignoreUnverifiedRekey(event, '수락');

      final newChainKey = await crypto.deriveRekeyChainKey(
        myNewEphemeralKeyPair: myEphemeral,
        theirNewEphemeralPublicKey: SimplePublicKey(
          theirEphemeralBytes,
          type: KeyPairType.x25519,
        ),
        previousChainKeyLastValue: state.chainKey,
        newEpoch: event.keyEpoch,
      );
      await _keyStore.saveChainState(
        roomId,
        SecretChainState(
          epoch: event.keyEpoch,
          n: 0,
          chainKey: newChainKey,
          prevEpoch: state.epoch,
          prevChainKeySnapshot: state.chainKey,
        ),
      );
      await _keyStore.clearPendingRekeySeed(roomId);
      _rekeyProposalSentAt.remove(roomId);
      await _noteLegacy(roomId, check.legacy);
      _epochMessageCount[roomId] = 0;
      _epochStartedAt[roomId] = DateTime.now();
      return SecretHandshakeOutcome.established;
    });
  }

  /// 상대가 이번에 맥락 서명(v2)을 보냈는지 적는다 — 보냈으면 "예전 앱" 안내를 끄고, 안 보냈으면 켠다.
  Future<void> _noteLegacy(String roomId, bool legacy) async {
    final security = await _securityOf(roomId);
    if (security.legacyPeer == legacy) return;
    await _saveSecurity(roomId, security.copyWith(legacyPeer: legacy));
    await _refreshTrust(roomId);
  }

  // ---- 화면에 보여 줄 신뢰 상태·보안 코드 ----

  /// 방 [roomId]의 신뢰 상태 — [loadTrust]로 읽어 둔 값(아직 안 읽었으면 null).
  SecretRoomTrust? trustOf(String roomId) => _trust[roomId];

  /// 방 [roomId]의 신뢰 상태를 저장소에서 읽는다(예전 대화면 방 정보로 상대 기기를 묶어 본다). 바뀌었으면
  /// [onTrustChanged]로 알린다.
  Future<SecretRoomTrust> loadTrust(String roomId) async {
    try {
      await _bindingFor(roomId);
    } catch (_) {}
    await _refreshTrust(roomId);
    return _trust[roomId] ?? const SecretRoomTrust();
  }

  Future<void> _refreshTrust(String roomId) async {
    final binding = await _bindingOf(roomId);
    final security = await _securityOf(roomId);
    final myDeviceId = _myDeviceIdOrNull;
    final boundPin = await _boundPinOf(binding);
    // 다툼 중인 고정은 "확인함"으로 보이지 않는다 — 그 키가 진짜인지부터 알 수 없다.
    final verifiedAt =
        boundPin == null || boundPin.disputed || myDeviceId == null
        ? null
        : boundPin.verifiedAtFor(myDeviceId);
    final reset = await _keyResetState(binding, boundPin, security);
    final trust = SecretRoomTrust(
      peerUserId: binding?.peerUserId,
      peerDeviceId: binding?.peerDeviceId,
      verifiedAt: verifiedAt,
      security: security,
      resetDeviceId: reset.deviceId,
      peerKeyAlreadyReset: reset.alreadyReset,
    );
    if (_trust[roomId] == trust) return;
    _trust[roomId] = trust;
    if (!_disposed) onTrustChanged?.call(roomId);
  }

  /// [binding]이 묶인 상대 기기의 고정(없거나, 주인이 묶인 상대와 다르면 null).
  Future<SecretDevicePin?> _boundPinOf(SecretRoomBinding? binding) async {
    if (binding == null) return null;
    final pin = await _keyStore.readDevicePin(binding.peerDeviceId);
    return pin != null && pin.userId == binding.peerUserId ? pin : null;
  }

  /// "상대 기기 키 다시 받기"로 고정을 지울 수 있는 상대 기기와, 멈춘 방이면 그 원인이던 고정을 이미 지웠는지(또는 그
  /// 뒤 새로 받았는지). 멈춘 방은 고정해 둔 키 때문에 멈췄고([SecretRoomSecurity.blockedDeviceId]) 그 고정이 그때
  /// 그대로일 때만 지울 수 있다 — 지우고 다시 받은 새 고정을, 예전에 멈춘 이 방에서 또 지워 버리지 않게. 멈추지 않은
  /// 방은 이 방이 묶인 기기의 고정이다(보안 코드가 다를 때).
  Future<({String? deviceId, bool alreadyReset})> _keyResetState(
    SecretRoomBinding? binding,
    SecretDevicePin? boundPin,
    SecretRoomSecurity security,
  ) async {
    if (security.blocked) {
      final device = security.blockedDeviceId;
      if (device == null || !security.blockedReason!.allowsKeyReset) {
        return (deviceId: null, alreadyReset: false);
      }
      final entry = await _keyStore.readDevicePinEntry(device);
      // 깨진 고정 때문에 멈췄으면 고정 시각이 없다 — 아직 깨진 채로 있을 때만 같은 고정으로 본다.
      final samePin =
          entry.present &&
          entry.pin?.firstSeenAt.millisecondsSinceEpoch ==
              security.blockedPinSeenAt?.millisecondsSinceEpoch;
      return samePin
          ? (deviceId: device, alreadyReset: false)
          : (deviceId: null, alreadyReset: true);
    }
    return (
      deviceId: boundPin == null ? null : binding?.peerDeviceId,
      alreadyReset: false,
    );
  }

  /// 방 [roomId]의 보안 코드 — 상대 기기가 아직 묶이지 않았으면(핸드셰이크 전, 예전 대화를 묶지 못함) null.
  Future<SecretSafetyInfo?> safetyInfo(String roomId) async {
    final binding = await _bindingFor(roomId);
    if (binding == null) return null;
    final pin = await _keyStore.readDevicePin(binding.peerDeviceId);
    if (pin == null || pin.userId != binding.peerUserId) return null;
    final me = _me;
    final myDeviceId = _identity.deviceId;
    final groups = await crypto.computeSafetyNumber(
      crypto.safetyNumberEntry(
        userId: me,
        deviceId: myDeviceId,
        signingPublicKey: await publicKeyBase64(_identity.signingKeyPair),
      ),
      crypto.safetyNumberEntry(
        userId: binding.peerUserId,
        deviceId: binding.peerDeviceId,
        signingPublicKey: pin.signingPublicKey,
      ),
    );
    return SecretSafetyInfo(
      groups: groups,
      peerUserId: binding.peerUserId,
      peerDeviceId: binding.peerDeviceId,
      // 다툼이 생긴(서버가 두 가지 키를 알려 온) 키는 "확인함"으로 보이지 않는다 — _refreshTrust와 같은 기준.
      verifiedAt: pin.disputed ? null : pin.verifiedAtFor(myDeviceId),
      myKeyChanged:
          binding.myDeviceId != null && binding.myDeviceId != myDeviceId,
    );
  }

  /// 방 [roomId]의 상대 기기를 보안 코드로 확인했다고 표시하거나([verified]) 지운다. 확인하면 "상대 기기가 바뀜"
  /// 안내도 끈다. 같은 기기에 묶인 다른 방의 표시도 함께 바뀐다(확인은 기기 단위).
  Future<void> setPeerVerified(String roomId, bool verified) async {
    final binding = await _bindingOf(roomId);
    if (binding == null) return;
    final pin = await _boundPinOf(binding);
    if (pin == null || pin.disputed) return;
    final myDeviceId = _identity.deviceId;
    // 확인 표시만 바꾼다(고정한 키는 이걸로도 바뀌지 않는다) — 그 사이 고정을 지웠거나 다시 받았으면 아무것도 안 한다.
    final changed = await _keyStore.setDevicePinVerified(
      binding.peerDeviceId,
      pin,
      myDeviceId: myDeviceId,
      verifiedAt: verified ? DateTime.now() : null,
    );
    if (changed && verified) {
      final security = await _securityOf(roomId);
      if (security.peerDeviceChanged) {
        await _saveSecurity(
          roomId,
          security.copyWith(peerDeviceChanged: false),
        );
      }
    }
    for (final entry in _bindings.entries.toList()) {
      if (entry.value.peerDeviceId == binding.peerDeviceId) {
        await _refreshTrust(entry.key);
      }
    }
    await _refreshTrust(roomId);
  }

  /// "예전 앱" 안내를 닫는다.
  Future<void> dismissLegacyNotice(String roomId) async {
    final security = await _securityOf(roomId);
    await _saveSecurity(roomId, security.copyWith(legacyNoticeDismissed: true));
    await _refreshTrust(roomId);
  }

  /// "상대 기기가 바뀜" 안내를 닫는다.
  Future<void> dismissDeviceChangedNotice(String roomId) async {
    final security = await _securityOf(roomId);
    await _saveSecurity(roomId, security.copyWith(peerDeviceChanged: false));
    await _refreshTrust(roomId);
  }

  /// "상대 기기 키 다시 받기" — 방 [roomId]의 상대 기기([SecretRoomTrust.resetDeviceId])를 이 기기에 고정해 둔 키를
  /// 지운다. 사용자가 보안 코드가 다르다고 했거나, 상대가 앱을 다시 설치하는 등으로 그 기기의 키가 바뀐 것을 상대에게
  /// 직접 확인했을 때만 부른다(화면이 확인 창을 거친다) — 고정이 영영 맞지 않는 기기와 다시 대화할 길은 이것뿐이다.
  /// 그 키를 믿고 맺은 대화(그 기기에 묶인 방)는 더 믿을 근거가 없어 모두 멈춘다. 다음 새 대화에서 서버가 알려 주는
  /// 키를 처음 보는 기기처럼 다시 고정하므로, 그 대화에서 보안 코드를 꼭 비교해야 한다. 지운 기기 id(지울 수 있는
  /// 고정이 없었으면 null — 아무것도 하지 않는다).
  Future<String?> resetPeerDevicePin(String roomId) async {
    final binding = await _bindingOf(roomId);
    final security = await _securityOf(roomId);
    final target = (await _keyResetState(
      binding,
      await _boundPinOf(binding),
      security,
    )).deviceId;
    if (target == null) return null;
    await _keyStore.deleteDevicePin(target);
    await _blockRoomsBoundTo(
      target,
      SecretBlockReason.keyReset,
      notify: false, // 사용자가 고른 일이라 "보안 확인에 실패" 알림은 띄우지 않는다.
    );
    // 그 고정 때문에 멈춰 있던 방(묶이지 않은 방 포함)의 "다시 받기" 표시도 바뀐다 — 화면이 읽어 둔 방을 다시 본다.
    for (final id in {..._trust.keys, roomId}) {
      await _refreshTrust(id);
    }
    return target;
  }

  void _forgetRoomCaches(String roomId) {
    _bindings.remove(roomId);
    _securities.remove(roomId);
    _trust.remove(roomId);
    _epochMessageCount.remove(roomId);
    _epochStartedAt.remove(roomId);
    _rekeyProposalSentAt.remove(roomId);
    _recentlySentPlaintext.removeWhere((key, _) => key.startsWith('$roomId|'));
  }

  /// 방이 없어졌을 때(종료·거절·나가기) — 그 방의 키 상태·묶인 상대 기기·보안 상태와 이 기기에 저장해 둔 평문까지
  /// 지운다. 상대 기기 고정은 남긴다(같은 기기와 새로 대화해도 그 키만 믿는다).
  Future<void> forgetRoom(String roomId) async {
    await _inRoom(roomId, () => _keyStore.clearRoom(roomId));
    _forgetRoomCaches(roomId);
    if (!_disposed) onTrustChanged?.call(roomId);
  }
}
