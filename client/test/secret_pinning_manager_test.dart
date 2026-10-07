import 'dart:async';
import 'dart:convert';

import 'package:client/models/room.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/chat_socket.dart';
import 'package:client/services/device_identity.dart';
import 'package:client/services/secret_chat_crypto.dart' as crypto;
import 'package:client/services/secret_key_store.dart';
import 'package:client/services/secret_peer_store.dart';
import 'package:client/services/secret_ratchet.dart';
import 'package:client/services/secret_session_manager.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 비밀 대화 상대 기기 고정(S5)의 판단 — 두 기기(앨리스·밥)와 서버 흉내로 핸드셰이크를 실제로 돌려, 서버가 기기
/// 키·사용자를 바꿔치기하면 세션 키를 만들지 않고 멈추는지, 맥락 서명(v2)이 있으면 v1은 보지 않는지 본다. 둘 다 새
/// 앱이면 초대에 실린 규약 번호와 v3 수락 맥락 서명으로 새 규약(v3 — 더블 래칫)을 맺고, 예전 앱(v2 없음)·규약 번호를
/// 전하지 않는 예전 서버와는 예전 규약(v1)으로 대화하되 표시하며 재키잉 없이 계속 풀리는지, 앱을 다시 켠 뒤에도 저장된
/// 묶음·세션으로 서버에 묻지 않고 이어 가는지 본다. 같은 기기를 두 곳에서 동시에 처음 고정하다 서버가 다른 키를 알려
/// 오면 덮어쓰지 않고 멈추는지, 멈춤이 서버가 보내는 값으로 풀리지 않는지, 같은 방의 보내기·받기가 겹쳐도 래칫이
/// 어긋나지 않는지, "상대 기기 키 다시 받기"로 같은 기기와 다시 대화할 수 있는지도 본다.

class _MemoryStorage extends Fake implements FlutterSecureStorage {
  final Map<String, String> data = {};

  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      data.remove(key);
    } else {
      data[key] = value;
    }
  }

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => data[key];

  @override
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => data.remove(key);

  @override
  Future<Map<String, String>> readAll({
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => Map.of(data);
}

/// [tripKey]를 처음 읽은 직후 [onTrip]을 한 번 돌리는 저장소 — 핸드셰이크가 고정을 읽은 뒤 서명을 확인하는 사이
/// 다른 곳(사용자의 "상대 기기 키 다시 받기"·다른 방에서 드러난 다툼)이 그 고정을 바꾸는 흉내.
class _TrippingStorage extends _MemoryStorage {
  String? tripKey;
  void Function(Map<String, String> data)? onTrip;

  /// 이 키를 다음에 쓸 때 한 번 실패한다(저장소 오류 흉내).
  String? failWriteKey;

  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (key == failWriteKey) {
      failWriteKey = null;
      throw Exception('저장소 쓰기 실패');
    }
    await super.write(key: key, value: value);
  }

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    final value = data[key];
    if (key == tripKey) {
      final trip = onTrip;
      tripKey = null;
      onTrip = null;
      trip?.call(data);
    }
    return value;
  }
}

http.Response _json(Object? body, [int status = 200]) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: const {'content-type': 'application/json'},
);

Map<String, dynamic> _user(String id) => {
  'id': id,
  'username': id,
  'name': switch (id) {
    'u-alice' => '앨리스',
    'u-bob' => '밥',
    _ => id,
  },
};

Map<String, dynamic> _roomJson(
  String id, {
  String status = 'active',
  String initiator = 'u-alice',
  String? initiatorDevice,
  String? responder,
  String? responderDevice,
}) => {
  'id': id,
  'teamId': 't1',
  'type': 'dm',
  'name': null,
  'members': [_user('u-alice'), _user('u-bob')],
  'createdAt': 1,
  'isSecret': true,
  'secretStatus': status,
  'secretInitiatorUserId': initiator,
  'secretInitiatorDeviceId': initiatorDevice,
  'secretResponderUserId': responder,
  'secretResponderDeviceId': responderDevice,
};

/// 서버 흉내 — 기기 키 조회(테스트가 바꿔치기할 수 있다)에 답하고, 비밀 대화 시작·수락 본문을 적어 둔다.
class _Server {
  /// 기기 id → (주인, 서명 공개키) — `GET /api/devices/:id/public-key`의 답.
  final devices = <String, (String, String)>{};
  final keyLookups = <String>[];
  final started = <Map<String, dynamic>>[];
  final accepted = <String, Map<String, dynamic>>{};
  int acceptStatus = 200;
  String nextRoomId = 'room-1';

  /// 다음 기기 키 조회 하나의 답을 그때의 값으로 정해 둔 채 이것이 끝날 때까지 붙잡는다 — 악의적인 서버가 답을
  /// 늦게 풀어 두 곳의 "처음 고정"이 겹치게 만드는 흉내. 붙잡은 요청이 도착하면 [heldLookupArrived]가 끝난다.
  Completer<void>? holdNextKeyLookup;
  final heldLookupArrived = Completer<void>();

  late final http.Client client = MockClient((request) async {
    final path = request.url.path;
    final keyMatch = RegExp(
      r'^/api/devices/([^/]+)/public-key$',
    ).firstMatch(path);
    if (request.method == 'GET' && keyMatch != null) {
      final id = Uri.decodeComponent(keyMatch.group(1)!);
      keyLookups.add(id);
      final device = devices[id];
      final hold = holdNextKeyLookup;
      if (hold != null) {
        holdNextKeyLookup = null;
        heldLookupArrived.complete();
        await hold.future;
      }
      if (device == null) return _json({'error': '기기를 찾을 수 없습니다.'}, 404);
      return _json({
        'userId': device.$1,
        'identityPublicKey': 'AAAA',
        'signingPublicKey': device.$2,
      });
    }
    if (request.method == 'POST' && path == '/api/secret-chats') {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      started.add(body);
      return _json(_roomJson(nextRoomId, status: 'pending'), 201);
    }
    final acceptMatch = RegExp(
      r'^/api/secret-chats/([^/]+)/accept$',
    ).firstMatch(path);
    if (request.method == 'POST' && acceptMatch != null) {
      if (acceptStatus >= 400) {
        return _json({'error': '수락할 수 있는 비밀 대화 요청이 없습니다.'}, acceptStatus);
      }
      accepted[acceptMatch.group(1)!] =
          jsonDecode(request.body) as Map<String, dynamic>;
      return _json({'ok': true});
    }
    return _json({'error': '없는 경로'}, 404);
  });
}

/// 기기 하나 — 이 사용자의 기기 신원·비밀 대화 저장소·매니저. [identityStorage]·[keyStorage]를 넘기면 같은 기기를
/// 다시 켠 것이다(같은 기기 id·키, 저장된 상태 그대로).
class _Device {
  _Device._(
    this.userId,
    this.server,
    this.identityStorage,
    this.keyStorage,
    this.identity,
    this.store,
    this.manager,
    this.rooms,
  );

  final String userId;
  final _Server server;
  final _MemoryStorage identityStorage;
  final _MemoryStorage keyStorage;
  final DeviceIdentity identity;
  final SecretKeyStore store;
  final SecretSessionManager manager;

  /// 이 기기의 방 목록(Session.rooms 대신) — 매니저가 방 멤버·핸드셰이크 기기 정보를 여기서 찾는다.
  final Map<String, Room> rooms;

  String get deviceId => identity.deviceId;

  static Future<_Device> open(
    String userId,
    _Server server, {
    _MemoryStorage? identityStorage,
    _MemoryStorage? keyStorage,
  }) async {
    final idStorage = identityStorage ?? _MemoryStorage();
    final kStorage = keyStorage ?? _MemoryStorage();
    final identity = DeviceIdentity(storage: idStorage);
    await identity.ensureLoaded();
    // 기기 등록(POST /api/devices) — 서버가 알게 된 진짜 키.
    server.devices[identity.deviceId] = (
      userId,
      await publicKeyBase64(identity.signingKeyPair),
    );
    final store = SecretKeyStore(storage: kStorage);
    final rooms = <String, Room>{};
    final manager = SecretSessionManager(
      ApiClient(
        baseUrl: 'https://test.local',
        token: 't',
        httpClient: server.client,
      ),
      identity,
      keyStore: store,
      userId: userId,
      roomLookup: (id) => rooms[id],
    );
    addTearDown(manager.dispose);
    return _Device._(
      userId,
      server,
      idStorage,
      kStorage,
      identity,
      store,
      manager,
      rooms,
    );
  }

  /// 같은 기기를 다시 켠다 — 메모리에 들고 있던 것은 모두 사라지고 저장소만 남는다.
  Future<_Device> restart() => _Device.open(
    userId,
    server,
    identityStorage: identityStorage,
    keyStorage: keyStorage,
  );

  Future<String> get signingKey => publicKeyBase64(identity.signingKeyPair);
}

/// [from]이 [targetUserId]에게 비밀 대화를 걸고, 서버가 상대에게 보낼 secret:invite를 만든다 — 서버는 시작 요청에
/// 실린 규약 번호(새 앱은 v3)를 초대에 그대로 실어 전한다.
Future<SecretInviteEvent> _start(
  _Device from,
  String targetUserId, {
  String roomId = 'room-1',
}) async {
  from.server.nextRoomId = roomId;
  final room = await from.manager.startSecretChat(targetUserId, 't1');
  from.rooms[room.id] = room;
  final body = from.server.started.last;
  return SecretInviteEvent(
    roomId: room.id,
    initiatorUserId: from.userId,
    initiatorDeviceId: body['deviceId'] as String,
    initiatorEphemeralPublicKey: body['initiatorEphemeralPublicKey'] as String,
    initiatorEphemeralSignature: body['initiatorEphemeralSignature'] as String,
    initiatorContextSignature: body['initiatorContextSignature'] as String?,
    initiatorProtocol: body['protocol'] as int?,
  );
}

/// 상대가 수락한 뒤 서버가 방 전체에 보낼 secret:accepted.
SecretAcceptedEvent _accepted(
  _Device responder,
  String roomId, {
  bool withContext = true,
  String? responderUserId,
}) {
  final body = responder.server.accepted[roomId]!;
  return SecretAcceptedEvent(
    roomId: roomId,
    responderDeviceId: body['deviceId'] as String,
    responderEphemeralPublicKey: body['responderEphemeralPublicKey'] as String,
    responderEphemeralSignature: body['responderEphemeralSignature'] as String,
    responderContextSignature: withContext
        ? body['responderContextSignature'] as String?
        : null,
    responderUserId: responderUserId ?? responder.userId,
  );
}

/// 규약 번호를 전하지 않는 예전 서버가 보낸 것 같은 초대 — 맥락 서명(v2)은 그대로라, 새 앱끼리도 예전 규약(v1)으로
/// 맺는다.
SecretInviteEvent _withoutProtocol(SecretInviteEvent invite) =>
    SecretInviteEvent(
      roomId: invite.roomId,
      initiatorUserId: invite.initiatorUserId,
      initiatorDeviceId: invite.initiatorDeviceId,
      initiatorEphemeralPublicKey: invite.initiatorEphemeralPublicKey,
      initiatorEphemeralSignature: invite.initiatorEphemeralSignature,
      initiatorContextSignature: invite.initiatorContextSignature,
    );

/// [alice]가 [bob]에게 걸고 [bob]이 수락해 양쪽 모두 세션 키를 만든다 — 둘 다 새 앱이라 새 규약(v3)으로 맺는다.
/// [v3]가 false면 서버가 초대의 규약 번호를 전하지 않은 것처럼(예전 서버) 해서 예전 규약(v1)으로 맺는다 — 이
/// 업데이트 전에 맺은 대화도 v1이다.
Future<void> _handshake(
  _Device alice,
  _Device bob, {
  String roomId = 'room-1',
  bool v3 = true,
}) async {
  final invite = await _start(alice, bob.userId, roomId: roomId);
  bob.rooms[roomId] = Room.fromJson(_roomJson(roomId, status: 'pending'));
  expect(
    await bob.manager.acceptInvite(v3 ? invite : _withoutProtocol(invite)),
    SecretHandshakeOutcome.established,
  );
  expect(
    await alice.manager.handleAccepted(_accepted(bob, roomId)),
    SecretHandshakeOutcome.established,
  );
  final protocol = v3 ? crypto.secretProtocolV3 : 1;
  expect(await alice.store.sessionProtocol(roomId), protocol);
  expect(await bob.store.sessionProtocol(roomId), protocol);
}

/// [from]이 암호화한 것을 [to]가 풀어 같은 글이 나오는지 — Session처럼 서버가 알려 준 보낸 사람도 함께 준다.
Future<void> _expectRoundTrip(
  _Device from,
  _Device to,
  String roomId,
  String text,
) async {
  final envelope = await from.manager.encryptForRoom(roomId, text);
  expect(envelope, isNotNull, reason: '보내는 쪽 세션이 없다');
  expect(
    await to.manager.decryptForRoom(
      roomId,
      envelope!,
      senderUserId: from.userId,
    ),
    text,
  );
}

/// [device]에 방 [roomId]의 세션 키가 하나도 없는지 — 예전 규약(v1) 체인도, 새 규약(v3) 래칫도.
Future<void> _expectNoSession(_Device device, String roomId) async {
  expect(
    await device.store.readChainState(roomId),
    isNull,
    reason: 'v1 체인이 있다',
  );
  expect(
    (await device.store.readRatchetState(roomId)).present,
    isFalse,
    reason: 'v3 래칫이 있다',
  );
  expect(await device.store.hasSession(roomId), isFalse);
}

/// 서버(또는 공격자)가 [claimedDeviceId] 기기인 척 [signer] 키로 서명해 끼워 넣는 초대 — 새 앱의 초대처럼 맥락
/// 서명(v2)과 규약 번호(v3)를 싣는다. [ephemeral]을 주면 그 임시키로 건다(맺어진 대화에 서버가 글을 끼워 넣을 때).
Future<SecretInviteEvent> _forgedInvite({
  required String roomId,
  required String claimedUserId,
  required String claimedDeviceId,
  required String responderUserId,
  required SimpleKeyPair signer,
  SimpleKeyPair? ephemeral,
}) async {
  final ephemeralPublicKey = await publicKeyBase64(
    ephemeral ?? await X25519().newKeyPair(),
  );
  return SecretInviteEvent(
    roomId: roomId,
    initiatorUserId: claimedUserId,
    initiatorDeviceId: claimedDeviceId,
    initiatorEphemeralPublicKey: ephemeralPublicKey,
    initiatorEphemeralSignature: await crypto.signEphemeralKey(
      signer,
      base64Decode(ephemeralPublicKey),
    ),
    initiatorContextSignature: await crypto.signContext(
      signer,
      crypto.secretInitContext(
        initiatorUserId: claimedUserId,
        initiatorDeviceId: claimedDeviceId,
        responderUserId: responderUserId,
        initiatorEphemeralPublicKey: ephemeralPublicKey,
      ),
    ),
    initiatorProtocol: crypto.secretProtocolV3,
  );
}

/// [invite]의 서명만 바꾼 초대. 맥락 서명(v2)이 없으면 예전 앱의 초대라 규약 번호도 싣지 않는다(예전 앱은 보내지
/// 않는다).
SecretInviteEvent _withSignatures(
  SecretInviteEvent invite, {
  required String v1,
  required String? v2,
}) => SecretInviteEvent(
  roomId: invite.roomId,
  initiatorUserId: invite.initiatorUserId,
  initiatorDeviceId: invite.initiatorDeviceId,
  initiatorEphemeralPublicKey: invite.initiatorEphemeralPublicKey,
  initiatorEphemeralSignature: v1,
  initiatorContextSignature: v2,
  initiatorProtocol: v2 == null ? null : invite.initiatorProtocol,
);

void main() {
  late _Server server;
  late _Device alice;
  late _Device bob;

  setUp(() async {
    server = _Server();
    alice = await _Device.open('u-alice', server);
    bob = await _Device.open('u-bob', server);
  });

  test(
    '둘 다 새 앱 — 맥락 서명(v2)으로 핸드셰이크해 새 규약(v3)으로 맺고, 상대 기기를 고정해 묶으며, 서로 주고받는 글이 풀린다',
    () async {
      await _handshake(alice, bob);
      expect(server.started.single['initiatorContextSignature'], isA<String>());
      expect(
        server.started.single['initiatorEphemeralSignature'],
        isA<String>(),
      );
      expect(server.started.single['protocol'], crypto.secretProtocolV3);
      expect(
        server.accepted['room-1']!['responderContextSignature'],
        isA<String>(),
      );
      // 새 규약의 래칫만 있고 예전 규약의 체인은 만들지 않았다.
      for (final device in [alice, bob]) {
        expect(
          (await device.store.readRatchetState('room-1')).state,
          isNotNull,
        );
        expect(await device.store.readChainState('room-1'), isNull);
      }
      await _expectRoundTrip(alice, bob, 'room-1', '안녕하세요');
      await _expectRoundTrip(bob, alice, 'room-1', '반갑습니다');

      final bobTrust = await bob.manager.loadTrust('room-1');
      expect(bobTrust.peerUserId, 'u-alice');
      expect(bobTrust.peerDeviceId, alice.deviceId);
      expect(bobTrust.blocked, isFalse);
      expect(bobTrust.showLegacyNotice, isFalse);
      expect(bobTrust.legacyProtocol, isFalse);
      expect(bobTrust.showProtocolNotice, isFalse);
      expect(bobTrust.verified, isFalse);
      final aliceTrust = await alice.manager.loadTrust('room-1');
      expect(aliceTrust.peerDeviceId, bob.deviceId);
      expect(aliceTrust.security.legacyPeer, isFalse);
      expect(aliceTrust.legacyProtocol, isFalse);
      expect(
        (await bob.store.readDevicePin(alice.deviceId))?.signingPublicKey,
        await alice.signingKey,
      );
      // 양쪽 화면의 보안 코드가 같다.
      final fromAlice = await alice.manager.safetyInfo('room-1');
      final fromBob = await bob.manager.safetyInfo('room-1');
      expect(fromAlice!.groups, fromBob!.groups);
      expect(fromBob.peerUserId, 'u-alice');
    },
  );

  test(
    '이미 고정한 기기는 고정한 키만 쓴다 — 서버가 그 기기 키를 자기 키로 바꿔 답하고 그 키로 서명한 초대를 끼워 넣으면 멈춘다',
    () async {
      await _handshake(alice, bob);
      final mallory = await Ed25519().newKeyPair();
      server.devices[alice.deviceId] = (
        'u-alice',
        await publicKeyBase64(mallory),
      );
      server.keyLookups.clear();
      bob.rooms['room-2'] = Room.fromJson(
        _roomJson('room-2', status: 'pending'),
      );
      final forged = await _forgedInvite(
        roomId: 'room-2',
        claimedUserId: 'u-alice',
        claimedDeviceId: alice.deviceId,
        responderUserId: 'u-bob',
        signer: mallory,
      );

      expect(
        await bob.manager.acceptInvite(forged),
        SecretHandshakeOutcome.blocked,
      );
      expect(server.keyLookups, isEmpty, reason: '고정한 기기는 서버에 다시 묻지 않는다');
      await _expectNoSession(bob, 'room-2');
      expect(server.accepted.containsKey('room-2'), isFalse);
      final trust = await bob.manager.loadTrust('room-2');
      expect(trust.blocked, isTrue);
      expect(trust.security.blockedReason, SecretBlockReason.badSignature);
      await expectLater(
        bob.manager.encryptForRoom('room-2', '보내면 안 된다'),
        throwsA(isA<SecretChatBlockedException>()),
      );
      // 고정한 키는 그대로 — 원래 대화는 계속된다.
      expect(
        (await bob.store.readDevicePin(alice.deviceId))?.signingPublicKey,
        await alice.signingKey,
      );
      await _expectRoundTrip(alice, bob, 'room-1', '원래 대화는 그대로');
      // 멈춘 방은 진짜 초대가 와도 다시 진행하지 않는다(되돌리는 방법은 없다).
      final genuine = await _start(alice, 'u-bob', roomId: 'room-2');
      expect(
        await bob.manager.acceptInvite(genuine),
        SecretHandshakeOutcome.blocked,
      );
      await _expectNoSession(bob, 'room-2');
    },
  );

  test('처음 보는 기기의 주인이 대화 상대가 아니라고 서버가 답하면 멈추고, 그 키를 고정하지 않는다', () async {
    server.devices[alice.deviceId] = ('u-mallory', await alice.signingKey);
    final invite = await _start(alice, 'u-bob');
    bob.rooms['room-1'] = Room.fromJson(_roomJson('room-1', status: 'pending'));

    expect(
      await bob.manager.acceptInvite(invite),
      SecretHandshakeOutcome.blocked,
    );
    expect(server.keyLookups, [alice.deviceId]);
    final trust = await bob.manager.loadTrust('room-1');
    expect(trust.security.blockedReason, SecretBlockReason.userMismatch);
    expect(await bob.store.readDevicePin(alice.deviceId), isNull);
    await _expectNoSession(bob, 'room-1');
  });

  test('초대를 보낸 사람이 이 방의 상대가 아니면(서버가 꾸민 초대) 멈춘다', () async {
    final invite = await _start(alice, 'u-bob');
    bob.rooms['room-1'] = Room.fromJson(_roomJson('room-1', status: 'pending'));
    final carol = await _Device.open('u-carol', server);
    final forged = await _forgedInvite(
      roomId: 'room-1',
      claimedUserId: 'u-carol',
      claimedDeviceId: carol.deviceId,
      responderUserId: 'u-bob',
      signer: carol.identity.signingKeyPair,
    );
    expect(
      await bob.manager.acceptInvite(forged),
      SecretHandshakeOutcome.blocked,
    );
    expect(
      (await bob.manager.loadTrust('room-1')).security.blockedReason,
      SecretBlockReason.peerMismatch,
    );
    await _expectNoSession(bob, 'room-1');
    expect(server.accepted.containsKey('room-1'), isFalse);
    expect(invite.initiatorUserId, 'u-alice');
  });

  test(
    '맥락 서명(v2)이 있으면 그것만 본다 — v1이 틀려도 v2가 맞으면 진행하고, 다른 상대에게 낸 v2를 끼워 넣으면 v1이 맞아도 멈춘다',
    () async {
      final someoneElse = await Ed25519().newKeyPair();
      final invite = await _start(alice, 'u-bob');
      bob.rooms['room-1'] = Room.fromJson(
        _roomJson('room-1', status: 'pending'),
      );
      final wrongV1 = await crypto.signEphemeralKey(
        someoneElse,
        base64Decode(invite.initiatorEphemeralPublicKey),
      );
      expect(
        await bob.manager.acceptInvite(
          _withSignatures(
            invite,
            v1: wrongV1,
            v2: invite.initiatorContextSignature,
          ),
        ),
        SecretHandshakeOutcome.established,
      );
      expect(
        await alice.manager.handleAccepted(_accepted(bob, 'room-1')),
        SecretHandshakeOutcome.established,
      );
      // 틀린 v1은 규약도 끌어내리지 않는다 — v2가 맞아 새 규약(v3)으로 맺었다.
      expect(
        await bob.store.sessionProtocol('room-1'),
        crypto.secretProtocolV3,
      );
      expect(
        await alice.store.sessionProtocol('room-1'),
        crypto.secretProtocolV3,
      );
      await _expectRoundTrip(alice, bob, 'room-1', 'v2만 확인');

      // 앨리스가 캐럴에게 낸 초대 서명(v1은 키만 서명해서 그대로 맞다)을 서버가 밥의 방에 다시 끼워 넣는다.
      final toCarol = await _start(alice, 'u-carol', roomId: 'room-c');
      bob.rooms['room-2'] = Room.fromJson(
        _roomJson('room-2', status: 'pending'),
      );
      final replayed = SecretInviteEvent(
        roomId: 'room-2',
        initiatorUserId: 'u-alice',
        initiatorDeviceId: alice.deviceId,
        initiatorEphemeralPublicKey: toCarol.initiatorEphemeralPublicKey,
        initiatorEphemeralSignature: toCarol.initiatorEphemeralSignature,
        initiatorContextSignature: toCarol.initiatorContextSignature,
        initiatorProtocol: toCarol.initiatorProtocol,
      );
      expect(
        await crypto.verifyEphemeralKey(
          signingPublicKeyBase64: await alice.signingKey,
          ephemeralPublicKeyBytes: base64Decode(
            replayed.initiatorEphemeralPublicKey,
          ),
          signatureBase64: replayed.initiatorEphemeralSignature,
        ),
        isTrue,
        reason: 'v1만 봤다면 통했을 서명',
      );
      expect(
        await bob.manager.acceptInvite(replayed),
        SecretHandshakeOutcome.blocked,
      );
      await _expectNoSession(bob, 'room-2');
    },
  );

  test(
    '상대가 예전 앱이라 v2가 없으면 고정한 키로 v1을 확인해 예전 규약(v1)으로 진행하고 "예전 앱"으로 표시한다 — 예전 앱의 v1이라도 고정한 키로 맞지 않으면 멈춘다',
    () async {
      final invite = await _start(alice, 'u-bob');
      bob.rooms['room-1'] = Room.fromJson(
        _roomJson('room-1', status: 'pending'),
      );
      expect(
        await bob.manager.acceptInvite(
          _withSignatures(
            invite,
            v1: invite.initiatorEphemeralSignature,
            v2: null,
          ),
        ),
        SecretHandshakeOutcome.established,
      );
      expect(await bob.store.sessionProtocol('room-1'), 1);
      final bobTrust = await bob.manager.loadTrust('room-1');
      expect(bobTrust.security.legacyPeer, isTrue);
      expect(bobTrust.showLegacyNotice, isTrue);
      expect(bobTrust.legacyProtocol, isTrue);
      // 상대가 예전 앱이면 새로 시작해도 예전 규약이라 "예전 방식" 안내 대신 "예전 앱" 안내만 보인다.
      expect(bobTrust.showProtocolNotice, isFalse);

      // 앨리스 쪽에서도 밥이 예전 앱인 것처럼(수락에 v2 없음).
      expect(
        await alice.manager.handleAccepted(
          _accepted(bob, 'room-1', withContext: false),
        ),
        SecretHandshakeOutcome.established,
      );
      expect(await alice.store.sessionProtocol('room-1'), 1);
      expect(
        (await alice.manager.loadTrust('room-1')).security.legacyPeer,
        isTrue,
      );
      await _expectRoundTrip(alice, bob, 'room-1', '예전 앱과도 대화');
      await _expectRoundTrip(bob, alice, 'room-1', '답장');

      // 예전 앱의 v1이라도 고정한 키로 맞지 않으면 멈춘다.
      final mallory = await Ed25519().newKeyPair();
      final forged = await _forgedInvite(
        roomId: 'room-2',
        claimedUserId: 'u-alice',
        claimedDeviceId: alice.deviceId,
        responderUserId: 'u-bob',
        signer: mallory,
      );
      bob.rooms['room-2'] = Room.fromJson(
        _roomJson('room-2', status: 'pending'),
      );
      expect(
        await bob.manager.acceptInvite(
          _withSignatures(
            forged,
            v1: forged.initiatorEphemeralSignature,
            v2: null,
          ),
        ),
        SecretHandshakeOutcome.blocked,
      );
      await _expectNoSession(bob, 'room-2');
    },
  );

  test('앱을 다시 켠 뒤에도 저장된 묶음·세션으로 이어 간다 — 방 정보에 기기 칸이 없어도, 서버에 묻지 않고', () async {
    await _handshake(alice, bob);
    await _expectRoundTrip(alice, bob, 'room-1', '다시 켜기 전');
    final codeBefore = (await bob.manager.safetyInfo('room-1'))!.groups;

    final bob2 = await bob.restart();
    // 예전 서버 모양의 방 정보(기기 칸 없음) — 묶음이 저장돼 있지 않으면 상대 기기를 찾을 수 없다.
    bob2.rooms['room-1'] = Room.fromJson(_roomJson('room-1'));
    expect(bob2.deviceId, bob.deviceId);
    server.keyLookups.clear();

    final trust = await bob2.manager.loadTrust('room-1');
    expect(trust.peerUserId, 'u-alice');
    expect(trust.peerDeviceId, alice.deviceId);
    expect(trust.blocked, isFalse);
    expect(trust.legacyProtocol, isFalse);
    expect((await bob2.manager.safetyInfo('room-1'))!.groups, codeBefore);
    expect(server.keyLookups, isEmpty, reason: '저장된 묶음·고정만 쓴다');

    // 대화는 양쪽으로 이어진다(래칫도 저장된 상태에서 이어 간다).
    await _expectRoundTrip(alice, bob2, 'room-1', '다시 켠 뒤');
    await _expectRoundTrip(bob2, alice, 'room-1', '답장');
    await _expectRoundTrip(alice, bob2, 'room-1', '여전히 풀린다');
    // 보낸 사람도 저장된 묶음으로 확인한다 — 이 방의 상대가 아닌 사람이 보냈다는 글은 풀지 않는다(래칫도 그대로).
    final envelope = (await alice.manager.encryptForRoom('room-1', '누가 보냈나'))!;
    expect(
      await bob2.manager.decryptForRoom(
        'room-1',
        envelope,
        senderUserId: 'u-carol',
      ),
      isNull,
    );
    expect(
      await bob2.manager.decryptForRoom(
        'room-1',
        envelope,
        senderUserId: 'u-alice',
      ),
      '누가 보냈나',
    );
    expect(server.keyLookups, isEmpty);
  });

  test('예전 규약(v1)으로 맺은 대화는 예전 재키잉 기준(글 100개)을 넘겨도 재키잉하지 않고 계속 주고받는다', () async {
    // 규약 번호를 전하지 않는 예전 서버 — 둘 다 새 앱이어도 예전 규약으로 맺는다.
    await _handshake(alice, bob, v3: false);
    for (var i = 0; i < 105; i++) {
      await _expectRoundTrip(alice, bob, 'room-1', '글 $i');
    }
    await _expectRoundTrip(bob, alice, 'room-1', '답장');
    await _expectRoundTrip(alice, bob, 'room-1', '그 뒤 글');
    for (final device in [alice, bob]) {
      final state = (await device.store.readChainState('room-1'))!;
      expect(state.epoch, 0, reason: '재키잉하지 않아 처음 체인 그대로다');
      expect(state.n, 107);
      expect(
        device.keyStorage.data.keys.where((k) => k.contains('pendingRekey')),
        isEmpty,
        reason: '재키잉을 제안하며 남기던 임시키가 없다',
      );
      final trust = await device.manager.loadTrust('room-1');
      expect(trust.legacyProtocol, isTrue);
      expect(trust.showProtocolNotice, isTrue);
    }
  });

  test('수락했다는 사람이 초대한 상대가 아니면(서버가 꾸밈) 초대자는 세션 키를 만들지 않고 멈춘다', () async {
    final invite = await _start(alice, 'u-bob');
    bob.rooms['room-1'] = Room.fromJson(_roomJson('room-1', status: 'pending'));
    await bob.manager.acceptInvite(invite);
    expect(
      await alice.manager.handleAccepted(
        _accepted(bob, 'room-1', responderUserId: 'u-carol'),
      ),
      SecretHandshakeOutcome.blocked,
    );
    await _expectNoSession(alice, 'room-1');
    expect(
      (await alice.manager.loadTrust('room-1')).security.blockedReason,
      SecretBlockReason.peerMismatch,
    );
    // 대기 중이던 임시 개인키도 남기지 않는다.
    expect(await alice.store.readPendingEphemeralSeed('room-1'), isNull);
  });

  test('서버가 수락을 받지 않으면(내 다른 기기가 먼저 수락함 등) 이 기기에 적은 키와 묶음을 되돌린다', () async {
    server.acceptStatus = 409;
    final invite = await _start(alice, 'u-bob');
    bob.rooms['room-1'] = Room.fromJson(_roomJson('room-1', status: 'pending'));
    await expectLater(
      bob.manager.acceptInvite(invite),
      throwsA(isA<SecretChatRefusedException>()),
    );
    await _expectNoSession(bob, 'room-1');
    expect(await bob.store.readRoomBinding('room-1'), isNull);
    // 서명을 확인한 상대 기기 고정은 남는다(사실이므로).
    expect(await bob.store.readDevicePin(alice.deviceId), isNotNull);
  });

  test('이미 진행 중인 대화를 서버가 돌려주면(200) 새 임시키를 대기시키지 않는다', () async {
    await _handshake(alice, bob);
    final existing = MockClient(
      (request) async => _json(_roomJson('room-1'), 200),
    );
    final manager = SecretSessionManager(
      ApiClient(baseUrl: 'https://test.local', httpClient: existing),
      alice.identity,
      keyStore: alice.store,
      userId: 'u-alice',
    );
    addTearDown(manager.dispose);
    final room = await manager.startSecretChat('u-bob', 't1');
    expect(room.id, 'room-1');
    expect(await alice.store.readPendingEphemeralSeed('room-1'), isNull);
    expect(
      await alice.store.sessionProtocol('room-1'),
      crypto.secretProtocolV3,
    );
    await _expectRoundTrip(alice, bob, 'room-1', '기존 대화 그대로');
  });

  test(
    '업데이트 전에 성립한 대화 — 방 정보의 양쪽 기기로 상대 기기를 찾아(주인 확인) 묶고 고정하며, 그 대화를 이어 가고 보안 코드를 보여 준다',
    () async {
      // 업데이트 전 대화는 예전 규약(v1)이고, 밥 쪽에 묶음·고정 기록이 없다(그때는 메모리에만 있었다).
      await _handshake(alice, bob, v3: false);
      bob.keyStorage.data.remove('secret/room-1/peer');
      bob.keyStorage.data.remove('secret/room-1/security');
      bob.keyStorage.data.remove('secretpin/${alice.deviceId}');
      final bob2 = await bob.restart();
      bob2.rooms['room-1'] = Room.fromJson(
        _roomJson(
          'room-1',
          initiatorDevice: alice.deviceId,
          responder: 'u-bob',
          responderDevice: bob.deviceId,
        ),
      );
      server.keyLookups.clear();

      // 보안 코드를 보려 하면 묶는다 — 처음 보는 기기라 서버에 물어 주인이 앨리스인지 확인하고 고정한다.
      final fromBob = await bob2.manager.safetyInfo('room-1');
      expect(server.keyLookups, [alice.deviceId]);
      expect(
        await bob2.store.readRoomBinding('room-1'),
        SecretRoomBinding(
          peerUserId: 'u-alice',
          peerDeviceId: alice.deviceId,
          myDeviceId: bob.deviceId,
        ),
      );
      final pin = await bob2.store.readDevicePin(alice.deviceId);
      expect(pin?.userId, 'u-alice');
      expect(pin?.signingPublicKey, await alice.signingKey);
      // 양쪽 보안 코드가 같다.
      expect(fromBob, isNotNull);
      expect(fromBob!.peerDeviceId, alice.deviceId);
      expect(
        fromBob.groups,
        (await alice.manager.safetyInfo('room-1'))!.groups,
      );

      // 예전 대화도 그대로 이어 가고, 묶은 뒤로는 서버에 다시 묻지 않는다.
      await _expectRoundTrip(alice, bob2, 'room-1', '예전 대화도 이어 간다');
      await _expectRoundTrip(bob2, alice, 'room-1', '답장');
      final trust = await bob2.manager.loadTrust('room-1');
      expect(trust.peerDeviceId, alice.deviceId);
      expect(trust.blocked, isFalse);
      expect(trust.legacyProtocol, isTrue);
      expect(server.keyLookups, [alice.deviceId]);
    },
  );

  test('업데이트 전 대화를 묶을 때 서버가 다른 사람의 기기라고 답하면 멈춘다', () async {
    await _handshake(alice, bob, v3: false);
    bob.keyStorage.data.remove('secret/room-1/peer');
    bob.keyStorage.data.remove('secretpin/${alice.deviceId}');
    final bob2 = await bob.restart();
    bob2.rooms['room-1'] = Room.fromJson(
      _roomJson(
        'room-1',
        initiatorDevice: alice.deviceId,
        responder: 'u-bob',
        responderDevice: bob.deviceId,
      ),
    );
    server.devices[alice.deviceId] = ('u-mallory', await alice.signingKey);
    // 앱을 켤 때 묶다가 멈춘 방을 알려 준다(Session이 토스트로 알린다) — 한 번만.
    expect(await bob2.manager.bootstrapBindings(['room-1']), ['room-1']);
    expect(await bob2.manager.bootstrapBindings(['room-1']), isEmpty);
    final trust = await bob2.manager.loadTrust('room-1');
    expect(trust.blocked, isTrue);
    expect(trust.security.blockedReason, SecretBlockReason.userMismatch);
    expect(await bob2.store.readRoomBinding('room-1'), isNull);
    await expectLater(
      bob2.manager.encryptForRoom('room-1', '보내면 안 된다'),
      throwsA(isA<SecretChatBlockedException>()),
    );
  });

  test('보안 코드를 확인한 상대가 다른 기기로 대화를 맺으면 "기기가 바뀜"을 알리고, 새 기기를 확인하면 꺼진다', () async {
    await _handshake(alice, bob);
    await bob.manager.setPeerVerified('room-1', true);
    expect(bob.manager.trustOf('room-1')!.verified, isTrue);
    expect(
      (await alice.manager.loadTrust('room-1')).verified,
      isFalse,
      reason: '확인은 표시한 기기에만',
    );
    expect((await bob.manager.safetyInfo('room-1'))!.verified, isTrue);

    // 앨리스가 앱을 새로 설치했다 — 새 기기 id·키.
    final aliceNew = await _Device.open('u-alice', server);
    expect(
      await bob.manager.isUnverifiedDeviceOfVerifiedPeer(
        'u-alice',
        aliceNew.deviceId,
      ),
      isTrue,
    );
    expect(
      await bob.manager.isUnverifiedDeviceOfVerifiedPeer(
        'u-alice',
        alice.deviceId,
      ),
      isFalse,
    );
    final invite = await _start(aliceNew, 'u-bob', roomId: 'room-2');
    bob.rooms['room-2'] = Room.fromJson(_roomJson('room-2', status: 'pending'));
    expect(
      await bob.manager.acceptInvite(invite),
      SecretHandshakeOutcome.establishedOnChangedDevice,
    );
    expect(
      (await bob.manager.loadTrust('room-2')).showDeviceChangedNotice,
      isTrue,
    );
    await bob.manager.setPeerVerified('room-2', true);
    expect(bob.manager.trustOf('room-2')!.showDeviceChangedNotice, isFalse);
    expect(bob.manager.trustOf('room-2')!.verified, isTrue);
  });

  test(
    '내가 수락한 것이 되돌아온 secret:accepted는 무시하고, 내 다른 기기가 먼저 수락했으면 이 기기에 남은 키를 치운다',
    () async {
      final invite = await _start(alice, 'u-bob');
      bob.rooms['room-1'] = Room.fromJson(
        _roomJson('room-1', status: 'pending'),
      );
      await bob.manager.acceptInvite(invite);
      final echo = _accepted(bob, 'room-1');
      expect(
        await bob.manager.handleAccepted(echo),
        SecretHandshakeOutcome.ignored,
      );
      expect(
        await bob.store.sessionProtocol('room-1'),
        crypto.secretProtocolV3,
      );

      // 밥의 다른 기기가 수락한 것으로 서버가 알려 온다(이 기기의 수락은 응답을 못 받아 키만 남은 경우).
      final otherDevice = SecretAcceptedEvent(
        roomId: 'room-1',
        responderDeviceId: 'd-bob-tablet',
        responderEphemeralPublicKey: echo.responderEphemeralPublicKey,
        responderEphemeralSignature: echo.responderEphemeralSignature,
        responderUserId: 'u-bob',
      );
      expect(
        await bob.manager.handleAccepted(otherDevice),
        SecretHandshakeOutcome.ignored,
      );
      await _expectNoSession(bob, 'room-1');
      expect(await bob.store.readRoomBinding('room-1'), isNull);
    },
  );

  test('앱을 켤 때 방 정보상 내 다른 기기가 수락한 대화면, 이 기기에 남은 키(응답을 못 받은 수락)를 치운다', () async {
    // room-1: 이 기기도 수락을 보냈지만 서버가 받은 것은 밥의 다른 기기(태블릿)의 수락이었다.
    final invite = await _start(alice, 'u-bob');
    bob.rooms['room-1'] = Room.fromJson(_roomJson('room-1', status: 'pending'));
    await bob.manager.acceptInvite(invite);
    bob.rooms['room-1'] = Room.fromJson(
      _roomJson(
        'room-1',
        initiatorDevice: alice.deviceId,
        responder: 'u-bob',
        responderDevice: 'd-bob-tablet',
      ),
    );
    // room-2: 이 기기가 수락한 대화 — 그대로 둔다.
    await _handshake(alice, bob, roomId: 'room-2');
    bob.rooms['room-2'] = Room.fromJson(
      _roomJson(
        'room-2',
        initiatorDevice: alice.deviceId,
        responder: 'u-bob',
        responderDevice: bob.deviceId,
      ),
    );

    await bob.manager.bootstrapBindings(['room-1', 'room-2']);
    await _expectNoSession(bob, 'room-1');
    expect(await bob.store.readRoomBinding('room-1'), isNull);
    expect(await bob.store.sessionProtocol('room-2'), crypto.secretProtocolV3);
    expect(
      (await bob.store.readRoomBinding('room-2'))?.peerDeviceId,
      alice.deviceId,
    );
    await _expectRoundTrip(alice, bob, 'room-2', '이 기기의 대화는 그대로');
  });

  test('같은 방의 보내기·받기가 겹쳐도 차례로 처리해 양쪽 래칫이 어긋나지 않는다', () async {
    await _handshake(alice, bob);
    // 받기는 래칫을 한 걸음 돌려 보내는 체인까지 바꾼다 — 한 줄로 처리하지 않으면 옛 상태를 읽은 쪽이 새 상태를
    // 덮어써 같은 메시지 키를 다시 쓰거나 양쪽 래칫이 갈라진다. 그래서 모두 하나가 끝나기를 기다리지 않고 한꺼번에
    // 시작한다.
    final fromAlice = [
      for (final e in await Future.wait([
        for (var i = 0; i < 3; i++)
          alice.manager.encryptForRoom('room-1', '앨리스 $i'),
      ]))
        e!,
    ];
    final bobSide = await Future.wait<String?>([
      for (var i = 0; i < 3; i++) ...[
        bob.manager.decryptForRoom(
          'room-1',
          fromAlice[i],
          senderUserId: 'u-alice',
        ),
        bob.manager.encryptForRoom('room-1', '밥 $i'),
      ],
    ]);
    expect(
      [for (var i = 0; i < 3; i++) bobSide[2 * i]],
      ['앨리스 0', '앨리스 1', '앨리스 2'],
    );
    final fromBob = [for (var i = 0; i < 3; i++) bobSide[2 * i + 1]!];
    // 같은 메시지 키를 두 번 쓰지 않았다 — 한 체인 안의 번호가 모두 다르다.
    for (final sent in [fromAlice, fromBob]) {
      expect({for (final e in sent) jsonDecode(e)['n']}, hasLength(3));
    }

    // 앨리스도 밥의 글을 받는 것과 동시에 답한다.
    final aliceSide = await Future.wait<String?>([
      for (var i = 0; i < 3; i++) ...[
        alice.manager.decryptForRoom(
          'room-1',
          fromBob[i],
          senderUserId: 'u-bob',
        ),
        alice.manager.encryptForRoom('room-1', '앨리스 답 $i'),
      ],
    ]);
    expect(
      [for (var i = 0; i < 3; i++) aliceSide[2 * i]],
      ['밥 0', '밥 1', '밥 2'],
    );
    final replies = [for (var i = 0; i < 3; i++) aliceSide[2 * i + 1]!];

    // 밥이 그 답을 한꺼번에 받아도 모두 풀린다.
    expect(
      await Future.wait([
        for (final e in replies)
          bob.manager.decryptForRoom('room-1', e, senderUserId: 'u-alice'),
      ]),
      ['앨리스 답 0', '앨리스 답 1', '앨리스 답 2'],
    );
    // 받은 번호를 잃지 않았다 — 이미 받은 글을 서버가 다시 보내도 다시 풀지 않는다.
    for (final e in [...fromAlice, ...replies]) {
      expect(
        await bob.manager.decryptForRoom('room-1', e, senderUserId: 'u-alice'),
        isNull,
      );
    }
    for (final e in fromBob) {
      expect(
        await alice.manager.decryptForRoom('room-1', e, senderUserId: 'u-bob'),
        isNull,
      );
    }
    // 그 뒤에도 양쪽이 이어 간다.
    await _expectRoundTrip(bob, alice, 'room-1', '그 뒤 글');
    await _expectRoundTrip(alice, bob, 'room-1', '답장');
  });

  test(
    '앱을 켤 때 예전 대화를 묶으려 물은 답을 서버가 붙잡아 둔 사이 같은 기기를 자기 키로 꾸민 초대를 수락시켜도, 늦게 푼 진짜 키가 고정을 덮어쓰지 않고 그 기기와의 대화를 모두 멈춘다',
    () async {
      // 업데이트 전에 성립한 대화(room-0, 예전 규약) — 밥 쪽에 묶음·고정 기록이 없다.
      await _handshake(alice, bob, roomId: 'room-0', v3: false);
      bob.keyStorage.data.remove('secret/room-0/peer');
      bob.keyStorage.data.remove('secret/room-0/security');
      bob.keyStorage.data.remove('secretpin/${alice.deviceId}');
      final bob2 = await bob.restart();
      bob2.rooms['room-0'] = Room.fromJson(
        _roomJson(
          'room-0',
          initiatorDevice: alice.deviceId,
          responder: 'u-bob',
          responderDevice: bob.deviceId,
        ),
      );
      final blockedElsewhere = <String>[];
      bob2.manager.onRoomsBlocked = blockedElsewhere.addAll;

      // 로그인 때 묶기 — 서버는 앨리스 기기의 진짜 키로 답을 정해 두고 붙잡는다.
      final hold = Completer<void>();
      server.holdNextKeyLookup = hold;
      final bootstrap = bob2.manager.bootstrapBindings(['room-0']);
      await server.heldLookupArrived.future;

      // 그 사이 서버는 같은 기기를 자기 키로 답하고, 그 키로 서명한 초대를 끼워 넣는다 — 처음 보는 기기라 여기까지는
      // 서명만으로 막을 수 없다(그래서 보안 코드가 필요하다).
      final mallory = await Ed25519().newKeyPair();
      final malloryKey = await publicKeyBase64(mallory);
      server.devices[alice.deviceId] = ('u-alice', malloryKey);
      bob2.rooms['room-1'] = Room.fromJson(
        _roomJson('room-1', status: 'pending'),
      );
      final malloryEphemeral = await X25519().newKeyPair();
      final forged = await _forgedInvite(
        roomId: 'room-1',
        claimedUserId: 'u-alice',
        claimedDeviceId: alice.deviceId,
        responderUserId: 'u-bob',
        signer: mallory,
        ephemeral: malloryEphemeral,
      );
      expect(
        await bob2.manager.acceptInvite(forged),
        SecretHandshakeOutcome.established,
      );
      expect(
        (await bob2.store.readDevicePin(alice.deviceId))!.signingPublicKey,
        malloryKey,
      );
      // 서버는 이 대화의 상대 쪽 키를 모두 쥐었다(꾸민 초대의 임시키 + 밥이 수락에 실은 임시키) — 상대인 척 보낸 글이
      // 지금은 풀린다.
      expect(
        await bob2.store.sessionProtocol('room-1'),
        crypto.secretProtocolV3,
      );
      final bobEphemeral =
          server.accepted['room-1']!['responderEphemeralPublicKey'] as String;
      final rootKey = await crypto.deriveRootKeyV3(
        myEphemeralKeyPair: malloryEphemeral,
        theirEphemeralPublicKey: base64Decode(bobEphemeral),
        roomId: 'room-1',
        transcript: crypto.secretRootTranscriptV3(
          roomId: 'room-1',
          initiatorUserId: 'u-alice',
          initiatorDeviceId: alice.deviceId,
          initiatorEphemeralPublicKey: forged.initiatorEphemeralPublicKey,
          responderUserId: 'u-bob',
          responderDeviceId: bob.deviceId,
          responderEphemeralPublicKey: bobEphemeral,
        ),
      );
      final serverSide = await SecretRatchetState.forInitiator(
        rootKey: rootKey!,
        responderEphemeralPublicKey: bobEphemeral,
      );
      // 새 규약은 글을 놓일 자리와 함께 싸서 암호화한다(SecretTextPlace) — 서버도 그렇게 싸면 된다.
      final first = await serverSide!.encrypt(
        roomId: 'room-1',
        plainText: jsonEncode({'t': '앨리스인 척', 'k': 'm'}),
      );
      expect(
        await bob2.manager.decryptForRoom(
          'room-1',
          jsonEncode(first.envelope),
          senderUserId: 'u-alice',
        ),
        '앨리스인 척',
      );

      // 멈추기 전에 저장된 래칫 상태 — 멈추면 이 기기에서 세션 키를 지우므로 미리 읽어 둔다(아래에서 "멈추지 않았다면
      // 풀렸을 글"인지 보는 데 쓴다).
      final storedBeforeBlock = (await bob2.store.readRatchetState(
        'room-1',
      )).state!;
      // 붙잡아 둔 진짜 키를 늦게 푼다 — 덮어쓰면 room-1의 보안 코드가 진짜 코드처럼 바뀌어 비교로도 못 잡는다.
      hold.complete();
      expect(await bootstrap, ['room-0']);
      final pin = (await bob2.store.readDevicePin(alice.deviceId))!;
      expect(pin.signingPublicKey, malloryKey, reason: '먼저 적은 고정을 덮어쓰지 않는다');
      expect(pin.disputed, isTrue);
      final room0 = await bob2.manager.loadTrust('room-0');
      expect(room0.security.blockedReason, SecretBlockReason.keyMismatch);
      // 그 기기에 묶인 다른 대화(서버와 맺어진 room-1)도 함께 멈추고, 따로 알린다.
      final room1 = await bob2.manager.loadTrust('room-1');
      expect(room1.security.blockedReason, SecretBlockReason.keyMismatch);
      expect(blockedElsewhere, ['room-1']);
      await expectLater(
        bob2.manager.encryptForRoom('room-1', '보내면 안 된다'),
        throwsA(isA<SecretChatBlockedException>()),
      );
      // 서버가 room-1에 상대인 척 보낸 다음 글도 이제는 풀어 보여 주지 않는다 — 멈추기 전의 래칫으로는 풀리는(멈추지
      // 않았다면 보였을) 글이다. 멈춘 방의 세션 키는 이 기기에서 지웠다.
      final next = await first.state.encrypt(
        roomId: 'room-1',
        plainText: jsonEncode({'t': '앨리스인 척 2', 'k': 'm'}),
      );
      final stored = storedBeforeBlock;
      expect(
        await stored.decrypt(
          roomId: 'room-1',
          envelope: SecretEnvelopeV3.tryParse(next.envelope)!,
        ),
        isNotNull,
      );
      expect(
        await bob2.manager.decryptForRoom(
          'room-1',
          jsonEncode(next.envelope),
          senderUserId: 'u-alice',
        ),
        isNull,
      );
      // room-1의 보안 코드는 진짜(밥 ↔ 앨리스 기기의 진짜 키) 코드가 아니다 — 비교하면 다르게 나온다.
      final genuineCode = await crypto.computeSafetyNumber(
        crypto.safetyNumberEntry(
          userId: 'u-bob',
          deviceId: bob.deviceId,
          signingPublicKey: await bob.signingKey,
        ),
        crypto.safetyNumberEntry(
          userId: 'u-alice',
          deviceId: alice.deviceId,
          signingPublicKey: await alice.signingKey,
        ),
      );
      expect(
        (await bob2.manager.safetyInfo('room-1'))!.groups,
        isNot(genuineCode),
      );

      // 다툼 중인 기기와는 사용자가 키를 다시 받기 전까지 새 대화도 맺지 않는다(서버에 다시 묻지도 않는다).
      server.keyLookups.clear();
      final nextInvite = await _start(alice, 'u-bob', roomId: 'room-2');
      bob2.rooms['room-2'] = Room.fromJson(
        _roomJson('room-2', status: 'pending'),
      );
      expect(
        await bob2.manager.acceptInvite(nextInvite),
        SecretHandshakeOutcome.blocked,
      );
      expect(server.keyLookups, isEmpty);
      await _expectNoSession(bob2, 'room-2');
      expect((await bob2.manager.loadTrust('room-2')).canResetPeerKey, isTrue);
    },
  );

  test(
    '같은 처음 보는 기기의 초대 두 개를 서버가 다른 키로 답하면, 나중에 고정하려는 쪽이 덮어쓰지 않고 멈추며 그 기기에 묶인 대화도 멈춘다',
    () async {
      final mallory = await Ed25519().newKeyPair();
      final malloryKey = await publicKeyBase64(mallory);
      // room-1: 서버가 자기 키로 꾸민 초대 — 그 기기 키 조회의 답(자기 키)을 붙잡아 둔다.
      server.devices[alice.deviceId] = ('u-alice', malloryKey);
      bob.rooms['room-1'] = Room.fromJson(
        _roomJson('room-1', status: 'pending'),
      );
      final forged = await _forgedInvite(
        roomId: 'room-1',
        claimedUserId: 'u-alice',
        claimedDeviceId: alice.deviceId,
        responderUserId: 'u-bob',
        signer: mallory,
      );
      final hold = Completer<void>();
      server.holdNextKeyLookup = hold;
      final firstAccept = bob.manager.acceptInvite(forged);
      await server.heldLookupArrived.future;

      // room-2: 앨리스의 진짜 초대 — 서버는 이번엔 진짜 키로 답한다.
      server.devices[alice.deviceId] = ('u-alice', await alice.signingKey);
      final genuine = await _start(alice, 'u-bob', roomId: 'room-2');
      bob.rooms['room-2'] = Room.fromJson(
        _roomJson('room-2', status: 'pending'),
      );
      expect(
        await bob.manager.acceptInvite(genuine),
        SecretHandshakeOutcome.established,
      );

      hold.complete();
      expect(await firstAccept, SecretHandshakeOutcome.blocked);
      final pin = (await bob.store.readDevicePin(alice.deviceId))!;
      expect(pin.signingPublicKey, await alice.signingKey);
      expect(pin.disputed, isTrue);
      await _expectNoSession(bob, 'room-1');
      expect(server.accepted.containsKey('room-1'), isFalse);
      expect(
        (await bob.manager.loadTrust('room-1')).security.blockedReason,
        SecretBlockReason.keyMismatch,
      );
      expect(
        (await bob.manager.loadTrust('room-2')).security.blockedReason,
        SecretBlockReason.keyMismatch,
      );
    },
  );

  test(
    '고정한 키를 읽고 서명을 확인하는 사이 그 고정이 지워지거나 다툼이 적히면, 그 키로 대화를 맺지 않고 멈춘다',
    () async {
      final storage = _TrippingStorage();
      final bobT = await _Device.open('u-bob', server, keyStorage: storage);
      await _handshake(alice, bobT);
      final pinKey = 'secretpin/${alice.deviceId}';

      // 1) 사용자가 그 사이 "상대 기기 키 다시 받기"로 고정을 지웠다.
      storage
        ..tripKey = pinKey
        ..onTrip = (data) => data.remove(pinKey);
      final invite2 = await _start(alice, 'u-bob', roomId: 'room-2');
      bobT.rooms['room-2'] = Room.fromJson(
        _roomJson('room-2', status: 'pending'),
      );
      expect(
        await bobT.manager.acceptInvite(invite2),
        SecretHandshakeOutcome.blocked,
      );
      expect(
        (await bobT.manager.loadTrust('room-2')).security.blockedReason,
        SecretBlockReason.keyReset,
      );
      await _expectNoSession(bobT, 'room-2');
      expect(server.accepted.containsKey('room-2'), isFalse);

      // 2) 그 사이 다른 방에서 다툼이 드러나 고정에 다툼이 적혔다.
      final repinned = SecretDevicePin.firstSeen(
        userId: 'u-alice',
        signingPublicKey: await alice.signingKey,
      );
      storage.data[pinKey] = repinned.encode();
      storage
        ..tripKey = pinKey
        ..onTrip = (data) =>
            data[pinKey] = repinned.markDisputed(DateTime.now()).encode();
      final invite3 = await _start(alice, 'u-bob', roomId: 'room-3');
      bobT.rooms['room-3'] = Room.fromJson(
        _roomJson('room-3', status: 'pending'),
      );
      expect(
        await bobT.manager.acceptInvite(invite3),
        SecretHandshakeOutcome.blocked,
      );
      expect(
        (await bobT.manager.loadTrust('room-3')).security.blockedReason,
        SecretBlockReason.keyMismatch,
      );
      await _expectNoSession(bobT, 'room-3');
      expect(server.accepted.containsKey('room-3'), isFalse);
    },
  );

  test('예전 대화를 묶다가 상대 기기 고정을 적지 못하면 묶음도 거두고, 다음에 다시 묶는다', () async {
    final storage = _TrippingStorage();
    final bobT = await _Device.open('u-bob', server, keyStorage: storage);
    // 업데이트 전 대화(예전 규약) 모양으로 — 묶음·고정 기록이 없다.
    await _handshake(alice, bobT, v3: false);
    storage.data.remove('secret/room-1/peer');
    storage.data.remove('secret/room-1/security');
    storage.data.remove('secretpin/${alice.deviceId}');
    final bob2 = await bobT.restart();
    bob2.rooms['room-1'] = Room.fromJson(
      _roomJson(
        'room-1',
        initiatorDevice: alice.deviceId,
        responder: 'u-bob',
        responderDevice: bobT.deviceId,
      ),
    );

    storage.failWriteKey = 'secretpin/${alice.deviceId}';
    expect(await bob2.manager.bootstrapBindings(['room-1']), isEmpty);
    expect(await bob2.store.readRoomBinding('room-1'), isNull);
    expect(await bob2.store.readDevicePin(alice.deviceId), isNull);
    expect(await bob2.manager.isBlocked('room-1'), isFalse);

    // 다음에는(저장소가 회복됨) 다시 묶고 고정한다.
    expect(await bob2.manager.bootstrapBindings(['room-1']), isEmpty);
    expect(
      (await bob2.store.readRoomBinding('room-1'))?.peerDeviceId,
      alice.deviceId,
    );
    expect(
      (await bob2.store.readDevicePin(alice.deviceId))?.signingPublicKey,
      await alice.signingKey,
    );
  });

  test(
    '멈춘 방은 서버가 보내는 값(내 다른 기기가 수락했다는 알림·방 정보)으로 키를 치우는 일이 생겨도 멈춤이 풀리지 않는다',
    () async {
      final invite = await _start(alice, 'u-bob');
      bob.rooms['room-1'] = Room.fromJson(
        _roomJson('room-1', status: 'pending'),
      );
      expect(
        await bob.manager.acceptInvite(invite),
        SecretHandshakeOutcome.established,
      );
      // 서버가 이 방의 상대가 아닌 사람 이름으로 같은 방에 초대를 다시 끼워 넣다 들켜 멈췄다 — 멈춘 방의 세션 키는 이
      // 기기에서 지운다(되살릴 수 없는 대화라 쓸 일이 없다).
      expect(
        await bob.manager.acceptInvite(
          await _forgedInvite(
            roomId: 'room-1',
            claimedUserId: 'u-carol',
            claimedDeviceId: 'd-carol',
            responderUserId: 'u-bob',
            signer: await Ed25519().newKeyPair(),
          ),
        ),
        SecretHandshakeOutcome.blocked,
      );
      expect(await bob.manager.isBlocked('room-1'), isTrue);
      expect(await bob.store.hasSession('room-1'), isFalse);

      // 1) "밥의 다른 기기가 수락했다"는 꾸민 secret:accepted.
      final echo = _accepted(bob, 'room-1');
      expect(
        await bob.manager.handleAccepted(
          SecretAcceptedEvent(
            roomId: 'room-1',
            responderDeviceId: 'd-bob-tablet',
            responderEphemeralPublicKey: echo.responderEphemeralPublicKey,
            responderEphemeralSignature: echo.responderEphemeralSignature,
            responderUserId: 'u-bob',
          ),
        ),
        SecretHandshakeOutcome.ignored,
      );
      expect(await bob.manager.isBlocked('room-1'), isTrue);

      // 2) 방 정보로 "수락한 기기는 밥의 태블릿"이라고 알려 온다(앱을 켤 때 정리).
      bob.rooms['room-1'] = Room.fromJson(
        _roomJson(
          'room-1',
          initiatorDevice: alice.deviceId,
          responder: 'u-bob',
          responderDevice: 'd-bob-tablet',
        ),
      );
      expect(await bob.manager.bootstrapBindings(['room-1']), isEmpty);
      expect(await bob.manager.isBlocked('room-1'), isTrue);

      // 다시 켜도 멈춰 있고, 같은 방에 다시 온 초대도 진행하지 않는다.
      final bob2 = await bob.restart();
      bob2.rooms['room-1'] = bob.rooms['room-1']!;
      final trust = await bob2.manager.loadTrust('room-1');
      expect(trust.security.blockedReason, SecretBlockReason.peerMismatch);
      expect(
        await bob2.manager.acceptInvite(invite),
        SecretHandshakeOutcome.blocked,
      );
    },
  );

  test(
    '상대가 같은 기기 id로 키만 바꿨으면(예전 앱의 키 재생성) 새 대화가 멈춘다 — "상대 기기 키 다시 받기"로 그 키를 지우면 그 키로 맺은 대화는 멈추고, 새 대화는 새 키로 맺어 보안 코드가 맞는다',
    () async {
      await _handshake(alice, bob);
      // 앨리스 기기가 같은 기기 id로 서명 키만 새로 만들었다(서버에도 새 키로 다시 등록).
      final regenerated = _MemoryStorage()
        ..data.addAll(alice.identityStorage.data)
        ..data['secret_signing_seed'] = base64Encode(
          List<int>.generate(32, (i) => i + 1),
        );
      final aliceNewKey = await _Device.open(
        'u-alice',
        server,
        identityStorage: regenerated,
      );
      expect(aliceNewKey.deviceId, alice.deviceId);
      expect(await aliceNewKey.signingKey, isNot(await alice.signingKey));

      final invite2 = await _start(aliceNewKey, 'u-bob', roomId: 'room-2');
      bob.rooms['room-2'] = Room.fromJson(
        _roomJson('room-2', status: 'pending'),
      );
      expect(
        await bob.manager.acceptInvite(invite2),
        SecretHandshakeOutcome.blocked,
      );
      final blocked = await bob.manager.loadTrust('room-2');
      expect(blocked.security.blockedReason, SecretBlockReason.badSignature);
      expect(blocked.resetDeviceId, alice.deviceId);
      // 원래 대화(room-1)에서는 "코드가 다릅니다"로 지울 수 있는 기기다.
      expect(
        (await bob.manager.loadTrust('room-1')).resetDeviceId,
        alice.deviceId,
      );

      expect(await bob.manager.resetPeerDevicePin('room-2'), alice.deviceId);
      expect(await bob.store.readDevicePin(alice.deviceId), isNull);
      // 지운 키로 맺은 대화는 멈춘다.
      final room1 = await bob.manager.loadTrust('room-1');
      expect(room1.security.blockedReason, SecretBlockReason.keyReset);
      expect(room1.canResetPeerKey, isFalse);
      final room2 = await bob.manager.loadTrust('room-2');
      expect(room2.blocked, isTrue);
      expect(room2.canResetPeerKey, isFalse);
      expect(room2.peerKeyAlreadyReset, isTrue);

      // 새 대화는 새 키를 처음 보는 기기처럼 고정해 맺고, 양쪽 보안 코드가 같다.
      final invite3 = await _start(aliceNewKey, 'u-bob', roomId: 'room-3');
      bob.rooms['room-3'] = Room.fromJson(
        _roomJson('room-3', status: 'pending'),
      );
      expect(
        await bob.manager.acceptInvite(invite3),
        SecretHandshakeOutcome.established,
      );
      expect(
        await aliceNewKey.manager.handleAccepted(_accepted(bob, 'room-3')),
        SecretHandshakeOutcome.established,
      );
      await _expectRoundTrip(aliceNewKey, bob, 'room-3', '다시 대화');
      expect(
        (await bob.manager.safetyInfo('room-3'))!.groups,
        (await aliceNewKey.manager.safetyInfo('room-3'))!.groups,
      );
      // 예전에 멈춘 방에서 다시 눌러도 새로 받은 고정은 지우지 않는다.
      expect(await bob.manager.resetPeerDevicePin('room-2'), isNull);
      expect(
        (await bob.store.readDevicePin(alice.deviceId))?.signingPublicKey,
        await aliceNewKey.signingKey,
      );
      expect((await bob.manager.loadTrust('room-3')).blocked, isFalse);

      // 보안 코드가 다르다고 하면(멈추지 않은 방) 그 키를 지우고 그 대화도 멈춘다.
      expect(await bob.manager.resetPeerDevicePin('room-3'), alice.deviceId);
      expect(
        (await bob.manager.loadTrust('room-3')).security.blockedReason,
        SecretBlockReason.keyReset,
      );
      await expectLater(
        bob.manager.encryptForRoom('room-3', '멈춘 대화'),
        throwsA(isA<SecretChatBlockedException>()),
      );
    },
  );
}
