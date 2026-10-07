import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

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

/// 비밀 대화 규약 협상과 세션 — 새 규약(v3, 더블 래칫)과 예전 규약(v1, 두 사람이 체인 하나를 함께 씀)을 두 기기(앨리스·
/// 밥)와 서버 흉내로 끝까지 돌려 본다.
///  - 새 앱끼리는 v3로 맺고, 동시에 보내기·긴 대화·히스토리를 최신 것부터 풀기·앱 다시 켜기를 거쳐도 모두 풀리는지.
///  - 내 글이 되돌아온 것(echo)과 상대 글을 보낸 사람(서버가 알려 준 senderUserId)으로 가리는지.
///  - 서버가 규약 표시·서명을 빼거나 붙여도(예전 서버·예전 앱·악의적인 서버) 두 기기가 같은 규약으로 맺거나, 서로 풀지
///    못할 뿐 엉뚱한 글을 보이지 않는지.
///  - 예전 규약(v1) 대화의 보완(같은 번호로 동시에 보낸 글, 늦게 온 글, 가짜 큰 번호, 재키잉 없이 긴 대화)과 뒷정리(남은
///    재키잉 임시키·안내 닫기·깨진 상태·멈춘 방·방 지우기).
/// 마지막 묶음('구현 버그 의심')은 지금 구현이 기대와 다르게 동작하는 경우를 재현해 두어 실패하는 것이 맞다 — 고치면 통과한다.

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

/// 서버 흉내 — 기기 키 조회에 답하고 비밀 대화 시작·수락 본문을 적어 둔다. 초대(secret:invite)·수락(secret:accepted)
/// 이벤트는 테스트가 이 본문으로 서버처럼 만든다(server/src/secretContextRules.js secretInvitePayload·
/// secretAcceptedPayload).
class _Server {
  /// 기기 id → (주인, 서명 공개키) — `GET /api/devices/:id/public-key`의 답.
  final devices = <String, (String, String)>{};
  final started = <Map<String, dynamic>>[];
  final accepted = <String, Map<String, dynamic>>{};
  int acceptStatus = 200;
  String nextRoomId = 'room-1';

  /// 수락 요청(POST …/accept)을 받은 수 — 다시 온 초대에 서버까지 다시 수락하지 않는지 본다.
  int acceptCalls = 0;

  /// 방 id → 수락한 사람 — `GET /api/secret-chats/:id/accepted`(초대한 사람이 놓친 수락 다시 받기)의 답에 싣는다. 없으면 404.
  final acceptedUser = <String, String>{};

  /// 놓친 수락 다시 받기의 답을 서버가 바꿔 주는 흉내.
  Map<String, dynamic> Function(Map<String, dynamic> payload)? acceptedRelay;

  /// 기기 키 조회를 붙잡아 두는 흉내 — 있으면 조회가 왔다고 [keyLookupArrived]로 알리고, 이것이 끝날 때까지 답하지 않는다.
  Completer<void>? holdKeyLookup;
  Completer<void>? keyLookupArrived;

  late final http.Client client = MockClient((request) async {
    final path = request.url.path;
    final keyMatch = RegExp(
      r'^/api/devices/([^/]+)/public-key$',
    ).firstMatch(path);
    if (request.method == 'GET' && keyMatch != null) {
      final hold = holdKeyLookup;
      if (hold != null) {
        final arrived = keyLookupArrived;
        if (arrived != null && !arrived.isCompleted) arrived.complete();
        await hold.future;
      }
      final device = devices[Uri.decodeComponent(keyMatch.group(1)!)];
      if (device == null) return _json({'error': '기기를 찾을 수 없습니다.'}, 404);
      return _json({
        'userId': device.$1,
        'identityPublicKey': 'AAAA',
        'signingPublicKey': device.$2,
      });
    }
    if (request.method == 'POST' && path == '/api/secret-chats') {
      started.add(jsonDecode(request.body) as Map<String, dynamic>);
      return _json(_roomJson(nextRoomId, status: 'pending'), 201);
    }
    final acceptMatch = RegExp(
      r'^/api/secret-chats/([^/]+)/accept$',
    ).firstMatch(path);
    if (request.method == 'POST' && acceptMatch != null) {
      acceptCalls++;
      if (acceptStatus >= 400) {
        return _json({'error': '수락할 수 있는 비밀 대화 요청이 없습니다.'}, acceptStatus);
      }
      accepted[acceptMatch.group(1)!] =
          jsonDecode(request.body) as Map<String, dynamic>;
      return _json({'ok': true});
    }
    final acceptedMatch = RegExp(
      r'^/api/secret-chats/([^/]+)/accepted$',
    ).firstMatch(path);
    if (request.method == 'GET' && acceptedMatch != null) {
      final roomId = acceptedMatch.group(1)!;
      final body = accepted[roomId];
      final user = acceptedUser[roomId];
      if (body == null || user == null) {
        return _json({'error': '수락된 비밀 대화가 없습니다.'}, 404);
      }
      final payload = <String, dynamic>{
        'roomId': roomId,
        'responderUserId': user,
        'responderDeviceId': body['deviceId'],
        'responderEphemeralPublicKey': body['responderEphemeralPublicKey'],
        'responderEphemeralSignature': body['responderEphemeralSignature'],
        'responderContextSignature': body['responderContextSignature'],
      };
      return _json(acceptedRelay == null ? payload : acceptedRelay!(payload));
    }
    return _json({'error': '없는 경로'}, 404);
  });
}

/// 기기 하나 — 이 사용자의 기기 신원·비밀 대화 저장소·매니저·방 목록. [restart]는 같은 기기를 다시 켠 것이다(같은 기기
/// id·키, 저장소 그대로 — 메모리에 들고 있던 보낸 글 평문·v1 보낼 때 쓴 키는 사라진다).
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

  Future<String> get signingKey => publicKeyBase64(identity.signingKeyPair);

  static Future<_Device> open(
    String userId,
    _Server server, {
    _MemoryStorage? identityStorage,
    _MemoryStorage? keyStorage,
    Map<String, Room>? rooms,
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
    final roomMap = rooms ?? <String, Room>{};
    final manager = SecretSessionManager(
      ApiClient(
        baseUrl: 'https://test.local',
        token: 't',
        httpClient: server.client,
      ),
      identity,
      keyStore: store,
      userId: userId,
      roomLookup: (id) => roomMap[id],
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
      roomMap,
    );
  }

  Future<_Device> restart() => _Device.open(
    userId,
    server,
    identityStorage: identityStorage,
    keyStorage: keyStorage,
    rooms: Map.of(rooms),
  );

  /// [text]를 암호화한 봉투 — 보낼 세션이 없으면(null) 실패로 본다.
  Future<String> send(String text, {String roomId = 'room-1'}) async {
    final envelope = await manager.encryptForRoom(roomId, text);
    expect(envelope, isNotNull, reason: '$userId: 보낼 세션이 없다');
    return envelope!;
  }

  /// 봉투를 푼다 — [from]은 서버가 알려 준 보낸 사람(null이면 모르는 경로).
  Future<String?> receive(
    String envelope, {
    String? from,
    String roomId = 'room-1',
  }) => manager.decryptForRoom(roomId, envelope, senderUserId: from);

  /// 저장소의 방별 키 상태 한 칸(`secret/<방>/<칸>`).
  String? stored(String field, {String roomId = 'room-1'}) =>
      keyStorage.data['secret/$roomId/$field'];

  /// 저장된 세션의 규약(3·1, 없으면 null).
  Future<int?> protocol([String roomId = 'room-1']) =>
      store.sessionProtocol(roomId);
}

/// 서버가 이벤트 본문을 바꿔(빼거나 붙여) 전하는 흉내.
typedef _Relay = Map<String, dynamic> Function(Map<String, dynamic> payload);

/// 서버가 본문에서 [field]를 빼고 전한다(예전 서버·서버가 뺌).
_Relay _without(String field) =>
    (payload) => Map.of(payload)..remove(field);

/// 서버가 본문의 [field]를 [value]로 바꿔(붙여) 전한다.
_Relay _with(String field, Object? value) =>
    (payload) => Map.of(payload)..[field] = value;

/// [from]이 [targetUserId]에게 비밀 대화를 걸고, 서버가 그 POST 본문으로 상대에게 보낼 secret:invite를 만든다 — 진짜
/// 서버처럼 규약 번호(protocol)를 initiatorProtocol로 싣는다. [relay]로 서버가 바꾼 값을 흉내 낸다.
Future<SecretInviteEvent> _start(
  _Device from,
  String targetUserId, {
  String roomId = 'room-1',
  _Relay? relay,
}) async {
  from.server.nextRoomId = roomId;
  final room = await from.manager.startSecretChat(targetUserId, 't1');
  from.rooms[room.id] = room;
  final body = from.server.started.last;
  final payload = <String, dynamic>{
    'roomId': room.id,
    'initiatorUserId': from.userId,
    'initiatorDeviceId': body['deviceId'],
    'initiatorEphemeralPublicKey': body['initiatorEphemeralPublicKey'],
    'initiatorEphemeralSignature': body['initiatorEphemeralSignature'],
    'initiatorContextSignature': body['initiatorContextSignature'],
    'initiatorProtocol': body['protocol'],
  };
  return SecretInviteEvent.fromJson(relay == null ? payload : relay(payload));
}

/// [responder]가 수락한 뒤 서버가 방 전체에 보낼 secret:accepted — [relay]로 서버가 바꾼 값을 흉내 낸다.
SecretAcceptedEvent _accepted(
  _Device responder,
  String roomId, {
  _Relay? relay,
}) {
  final body = responder.server.accepted[roomId]!;
  final payload = <String, dynamic>{
    'roomId': roomId,
    'responderUserId': responder.userId,
    'responderDeviceId': body['deviceId'],
    'responderEphemeralPublicKey': body['responderEphemeralPublicKey'],
    'responderEphemeralSignature': body['responderEphemeralSignature'],
    'responderContextSignature': body['responderContextSignature'],
  };
  return SecretAcceptedEvent.fromJson(relay == null ? payload : relay(payload));
}

/// [alice]가 [bob]에게 걸고 [bob]이 수락해 양쪽 모두 세션을 만든다. [inviteRelay]·[acceptedRelay]는 서버가 중계하며
/// 바꾼 값.
Future<SecretInviteEvent> _handshake(
  _Device alice,
  _Device bob, {
  String roomId = 'room-1',
  _Relay? inviteRelay,
  _Relay? acceptedRelay,
}) async {
  final invite = await _start(
    alice,
    bob.userId,
    roomId: roomId,
    relay: inviteRelay,
  );
  bob.rooms[roomId] = Room.fromJson(_roomJson(roomId, status: 'pending'));
  expect(
    await bob.manager.acceptInvite(invite),
    SecretHandshakeOutcome.established,
    reason: '밥의 수락',
  );
  expect(
    await alice.manager.handleAccepted(
      _accepted(bob, roomId, relay: acceptedRelay),
    ),
    SecretHandshakeOutcome.established,
    reason: '앨리스의 수락 확인',
  );
  return invite;
}

/// [protocol] 규약으로 맺는다 — 1이면 서버가 초대의 규약 표시를 빼고 전한 것(예전 서버)이다.
Future<void> _establish(
  _Device alice,
  _Device bob,
  int protocol, {
  String roomId = 'room-1',
}) async {
  await _handshake(
    alice,
    bob,
    roomId: roomId,
    inviteRelay: protocol == 1 ? _without('initiatorProtocol') : null,
  );
  expect(await alice.protocol(roomId), protocol, reason: '앨리스의 규약');
  expect(await bob.protocol(roomId), protocol, reason: '밥의 규약');
}

/// [from]이 보낸 글을 [to]가 받아 같은 글이 나오는지 — 보낸 쪽에 되돌아온 자기 글도 같은지.
Future<void> _roundTrip(
  _Device from,
  _Device to,
  String text, {
  String roomId = 'room-1',
}) async {
  final envelope = await from.send(text, roomId: roomId);
  expect(
    await to.receive(envelope, from: from.userId, roomId: roomId),
    text,
    reason: '${to.userId}가 받은 글',
  );
  expect(
    await from.receive(envelope, from: from.userId, roomId: roomId),
    text,
    reason: '${from.userId}에게 되돌아온 자기 글',
  );
}

/// 앨리스와 밥이 서로 상대 글을 받기 전에 [aliceTexts]·[bobTexts]를 모두 암호화한다(거의 동시에 보냄). 그다음 각자
/// 되돌아온 내 글과 상대 글을 받는다 — [peerFirst]면 상대 글을 먼저, [reversed]면 상대 글을 늦게 보낸 것부터 받는다.
/// 받은 글은 늘 상대가 보낸 그 글이어야 한다(내 글로 보이면 안 된다). 보낸 사람은 번갈아 알려 주거나(senderUserId)
/// 모르는 경로(null)로 준다.
Future<void> _simultaneous(
  _Device alice,
  _Device bob,
  List<String> aliceTexts,
  List<String> bobTexts, {
  bool peerFirst = false,
  bool reversed = false,
}) async {
  final fromAlice = [for (final t in aliceTexts) await alice.send(t)];
  final fromBob = [for (final t in bobTexts) await bob.send(t)];
  Future<void> receivePeer(
    _Device me,
    _Device peer,
    List<String> envelopes,
    List<String> texts,
  ) async {
    final order = [for (var i = 0; i < envelopes.length; i++) i];
    for (final i in reversed ? order.reversed : order) {
      expect(
        await me.receive(envelopes[i], from: i.isEven ? peer.userId : null),
        texts[i],
        reason: '${me.userId}가 받은 ${peer.userId}의 $i번째 글',
      );
    }
  }

  Future<void> echoes(
    _Device me,
    List<String> envelopes,
    List<String> texts,
  ) async {
    for (var i = 0; i < envelopes.length; i++) {
      expect(
        await me.receive(envelopes[i], from: me.userId),
        texts[i],
        reason: '${me.userId}에게 되돌아온 $i번째 자기 글',
      );
    }
  }

  if (peerFirst) {
    await receivePeer(alice, bob, fromBob, bobTexts);
    await receivePeer(bob, alice, fromAlice, aliceTexts);
    await echoes(alice, fromAlice, aliceTexts);
    await echoes(bob, fromBob, bobTexts);
  } else {
    await echoes(alice, fromAlice, aliceTexts);
    await echoes(bob, fromBob, bobTexts);
    await receivePeer(alice, bob, fromBob, bobTexts);
    await receivePeer(bob, alice, fromAlice, aliceTexts);
  }
}

/// [_converse]가 끝난 뒤의 두 기기(다시 켰으면 새 것)와, 그 대화가 실제로 거친 것 — 테스트가 그 경로를 정말
/// 지났는지 본다: 다시 켠 횟수, 오간 래칫 키 수(v3 — 방향이 바뀔 때마다 새 키), 한 번에 몰아 보낸 최대 수, 늦게 보낸
/// 글이 먼저 간 횟수, 두 기기가 같은 자리(번호)의 키로 보낸 글 수(v1 — 거의 동시에 보냄).
typedef _Conversation = ({
  _Device alice,
  _Device bob,
  int restarts,
  int ratchetKeys,
  int maxBurst,
  int outOfOrder,
  int sameIndex,
});

/// 앨리스·밥이 [perSide]개씩 주고받는 긴 대화. 고정한 시드로 보내기(가끔 몰아서 여러 개)·상대에게 전하기·내 글이
/// 되돌아오기(서버 echo)를 섞는다. [reorder]면 한 방향 안에서도 가끔 늦게 보낸 글이 먼저 간다. [restartChance]만큼
/// 가끔 한쪽 기기를 다시 켠다 — 그 기기가 보낸 글의 평문은 메모리에서 사라져, 되돌아와도 엉뚱한 글이 아니라 null이어야
/// 한다. 받은 글은 늘 보낸 글과 같아야 한다.
Future<_Conversation> _converse(
  _Device alice,
  _Device bob, {
  required int perSide,
  required int seed,
  bool reorder = false,
  double restartChance = 0,
  String roomId = 'room-1',
}) async {
  final rng = math.Random(seed);
  final devices = [alice, bob];
  final sent = [0, 0];
  final received = [0, 0];
  // 받을 기기마다 아직 전하지 않은 (봉투, 평문).
  final inbox = [<(String, String)>[], <(String, String)>[]];
  // 보낸 기기마다 아직 되돌아오지 않은 자기 글.
  final echoes = [<(String, String)>[], <(String, String)>[]];
  final positions = [<String>{}, <String>{}];
  final ratchetKeys = <String>{};
  var restarts = 0;
  var maxBurst = 0;
  var outOfOrder = 0;
  bool finished() =>
      sent.every((s) => s >= perSide) &&
      inbox.every((box) => box.isEmpty) &&
      echoes.every((box) => box.isEmpty);
  for (var step = 0; !finished(); step++) {
    expect(step, lessThan(100000), reason: '대화가 끝나지 않는다');
    final side = rng.nextInt(2);
    final peer = 1 - side;
    final me = devices[side];
    switch (rng.nextInt(6)) {
      case 0 || 1:
        final burst = rng.nextInt(8) == 0
            ? 5 + rng.nextInt(12)
            : 1 + rng.nextInt(3);
        var burstSent = 0;
        for (var i = 0; i < burst && sent[side] < perSide; i++) {
          final text = '${me.userId} ${sent[side]++}번째 ${'글' * rng.nextInt(4)}';
          final envelope = await me.send(text, roomId: roomId);
          inbox[peer].add((envelope, text));
          echoes[side].add((envelope, text));
          positions[side].add(_position(envelope));
          final ratchetKey = _decode(envelope)['dh'];
          if (ratchetKey is String) ratchetKeys.add(ratchetKey);
          burstSent++;
        }
        maxBurst = math.max(maxBurst, burstSent);
      case 2 || 3 || 4:
        final box = inbox[side];
        if (box.isEmpty) break;
        // 가끔은 쌓인 것을 한꺼번에(다시 연결된 뒤처럼), 보통은 몇 개씩.
        var count = rng.nextInt(4) == 0
            ? box.length
            : 1 + rng.nextInt(math.min(box.length, 3));
        while (count-- > 0 && box.isNotEmpty) {
          final index = reorder ? rng.nextInt(math.min(box.length, 4)) : 0;
          if (index > 0) outOfOrder++;
          final (envelope, text) = box.removeAt(index);
          final from = rng.nextInt(5) == 0 ? null : devices[peer].userId;
          expect(
            await me.receive(envelope, from: from, roomId: roomId),
            text,
            reason: '${me.userId}가 받은 글',
          );
          received[side]++;
        }
      default:
        final box = echoes[side];
        if (box.isEmpty) break;
        final (envelope, text) = box.removeAt(0);
        expect(
          await me.receive(envelope, from: me.userId, roomId: roomId),
          text,
          reason: '${me.userId}에게 되돌아온 자기 글',
        );
    }
    if (restartChance > 0 && rng.nextDouble() < restartChance) {
      final who = rng.nextInt(2);
      devices[who] = await devices[who].restart();
      restarts++;
      for (final (envelope, _) in echoes[who]) {
        expect(
          await devices[who].receive(
            envelope,
            from: rng.nextBool() ? devices[who].userId : null,
            roomId: roomId,
          ),
          isNull,
          reason: '다시 켠 ${devices[who].userId}는 보낸 글 평문을 잊었다',
        );
      }
      echoes[who].clear();
    }
  }
  expect(received, [perSide, perSide]);
  return (
    alice: devices[0],
    bob: devices[1],
    restarts: restarts,
    ratchetKeys: ratchetKeys.length,
    maxBurst: maxBurst,
    outOfOrder: outOfOrder,
    sameIndex: positions[0].intersection(positions[1]).length,
  );
}

/// [sender]가 [order] 길이만큼 보내고, [receiver]가 [order](보낸 차례 번호) 순서로 받는다 — 모두 보낸 글 그대로
/// 풀리는지. [restartAfter]개를 받은 뒤 받는 기기를 다시 켠다. 받는 기기(다시 켰으면 새 것)를 돌려준다.
Future<_Device> _receiveInOrder(
  _Device sender,
  _Device receiver,
  List<int> order, {
  required String label,
  int? restartAfter,
}) async {
  final texts = [
    for (var i = 0; i < order.length; i++) '${sender.userId} $label $i',
  ];
  final envelopes = [for (final t in texts) await sender.send(t)];
  var device = receiver;
  for (var k = 0; k < order.length; k++) {
    if (k == restartAfter) device = await device.restart();
    final i = order[k];
    expect(
      await device.receive(envelopes[i], from: sender.userId),
      texts[i],
      reason: '$label — $i번째 글($k번째로 받음)',
    );
  }
  return device;
}

/// 첫 히스토리 페이지(최신 50개 — 화면은 오래된 것부터 그린다)를 먼저 풀고 그 전 페이지(나머지 10개)를 푸는 순서.
final _firstPageThenOlder = [
  for (var i = 10; i < 60; i++) i,
  for (var i = 0; i < 10; i++) i,
];

/// 가장 늦게 보낸 것부터 하나씩 거꾸로.
final _newestFirst = [for (var i = 59; i >= 0; i--) i];

typedef _AcceptContext =
    String Function({
      required String roomId,
      required String initiatorUserId,
      required String initiatorDeviceId,
      required String initiatorEphemeralPublicKey,
      required String responderUserId,
      required String responderDeviceId,
      required String responderEphemeralPublicKey,
    });

/// [responder]가 서버에 보낸 수락의 맥락 서명이 [build](v2 secretAcceptContext·v3 secretAcceptContextV3)로 만든
/// 맥락에 맞는지.
Future<bool> _acceptSignedWith(
  _AcceptContext build,
  SecretInviteEvent invite,
  _Device responder,
) async {
  final body = responder.server.accepted[invite.roomId]!;
  final signature = body['responderContextSignature'];
  if (signature is! String) return false;
  return crypto.verifyContext(
    signingPublicKeyBase64: await responder.signingKey,
    context: build(
      roomId: invite.roomId,
      initiatorUserId: invite.initiatorUserId,
      initiatorDeviceId: invite.initiatorDeviceId,
      initiatorEphemeralPublicKey: invite.initiatorEphemeralPublicKey,
      responderUserId: responder.userId,
      responderDeviceId: responder.deviceId,
      responderEphemeralPublicKey:
          body['responderEphemeralPublicKey'] as String,
    ),
    signatureBase64: signature,
  );
}

/// 저장된 v3 래칫 상태.
SecretRatchetState _ratchetOf(_Device device, [String roomId = 'room-1']) {
  final raw = device.stored('ratchet', roomId: roomId);
  expect(raw, isNotNull, reason: '${device.userId}: v3 래칫 상태가 없다');
  final state = SecretRatchetState.decode(raw!);
  expect(state, isNotNull, reason: '${device.userId}: v3 래칫 상태를 읽을 수 없다');
  // 남겨 둔 키는 따로 적는다(secret/<방>/skipped) — 붙여서 본다.
  final skipped = device.stored('skipped', roomId: roomId);
  if (skipped == null) return state!;
  return state!.withSkipped(decodeSkippedKeys(jsonDecode(skipped)) ?? const []);
}

/// 예전 규약(v1) 체인 상태 — secret/<방>/chain(JSON 한 값).
SecretChainState _chainOf(_Device device, [String roomId = 'room-1']) {
  final raw = device.stored('chain', roomId: roomId);
  expect(raw, isNotNull, reason: '${device.userId}: v1 체인 상태가 없다');
  final state = SecretChainState.decode(raw!);
  expect(state, isNotNull, reason: '${device.userId}: v1 체인 상태를 읽을 수 없다');
  return state!;
}

Map<String, dynamic> _decode(String envelope) =>
    jsonDecode(envelope) as Map<String, dynamic>;

/// 봉투의 번호(n).
int _index(String envelope) => _decode(envelope)['n'] as int;

/// 봉투가 쓴 키의 자리 — (래칫 키, epoch, 번호).
String _position(String envelope) {
  final json = _decode(envelope);
  return '${json['dh']}|${json['epoch']}|${json['n']}';
}

String _flipFirstByte(String base64Value) {
  final bytes = base64Decode(base64Value);
  bytes[0] ^= 0x01;
  return base64Encode(bytes);
}

/// 예전 앱 흉내 — 예전 규약(v1) 체인 하나를 들고 차례대로 보내고 받는다(건너뛴 키·동시에 보낸 번호 처리 없음).
class _OldAppChain {
  _OldAppChain(this.roomId, this._chainKey);

  final String roomId;
  List<int> _chainKey;
  int n = 0;

  Future<String> encrypt(String text) async {
    final step = await crypto.ratchetStep(_chainKey);
    final envelope = await crypto.encryptEnvelope(
      msgKey: step.msgKey,
      plainText: text,
      roomId: roomId,
      epoch: 0,
      n: n,
    );
    _chainKey = step.nextChainKey;
    n++;
    return jsonEncode(envelope);
  }

  Future<String?> decrypt(String envelopeJson) async {
    final envelope = _decode(envelopeJson);
    final target = envelope['n'];
    if (envelope['epoch'] != 0 || target is! int || target < n) return null;
    var key = _chainKey;
    for (var i = n; i < target; i++) {
      key = (await crypto.ratchetStep(key)).nextChainKey;
    }
    final step = await crypto.ratchetStep(key);
    final plain = await crypto.decryptEnvelope(
      msgKey: step.msgKey,
      envelope: envelope,
      roomId: roomId,
    );
    if (plain != null) {
      _chainKey = step.nextChainKey;
      n = target + 1;
    }
    return plain;
  }
}

/// 예전 앱 쪽 체인 — 자기 임시키와 상대 임시 공개키(base64)로 예전 규약의 첫 체인키를 만든다.
Future<_OldAppChain> _oldAppChain(
  SimpleKeyPair mine,
  String theirPublicKey,
  String roomId,
) async => _OldAppChain(
  roomId,
  await crypto.deriveInitialChainKey(
    myEphemeralKeyPair: mine,
    theirEphemeralPublicKey: SimplePublicKey(
      base64Decode(theirPublicKey),
      type: KeyPairType.x25519,
    ),
    roomId: roomId,
  ),
);

/// 예전 앱이 [from] 기기로 건 초대(서버가 상대에게 전한 secret:invite). [withContext]면 맥락 서명(v2)까지 아는 이
/// 업데이트 전 앱, 아니면 키만 서명한 v1 서명뿐인 더 예전 앱이다. [protocol]은 서버가 붙인 규약 표시.
Future<(SecretInviteEvent, SimpleKeyPair)> _oldAppInvite(
  _Device from,
  String targetUserId, {
  String roomId = 'room-1',
  bool withContext = false,
  int? protocol,
}) async {
  final ephemeral = await X25519().newKeyPair();
  final publicKey = await publicKeyBase64(ephemeral);
  final signer = from.identity.signingKeyPair;
  final invite = SecretInviteEvent.fromJson({
    'roomId': roomId,
    'initiatorUserId': from.userId,
    'initiatorDeviceId': from.deviceId,
    'initiatorEphemeralPublicKey': publicKey,
    'initiatorEphemeralSignature': await crypto.signEphemeralKey(
      signer,
      base64Decode(publicKey),
    ),
    'initiatorContextSignature': withContext
        ? await crypto.signContext(
            signer,
            crypto.secretInitContext(
              initiatorUserId: from.userId,
              initiatorDeviceId: from.deviceId,
              responderUserId: targetUserId,
              initiatorEphemeralPublicKey: publicKey,
            ),
          )
        : null,
    'initiatorProtocol': protocol,
  });
  return (invite, ephemeral);
}

/// 이 업데이트 전 앱(맥락 서명 v2는 알지만 v3는 모름)이 [responder] 기기로 [invite]를 수락한 secret:accepted — 초대의
/// 규약 표시는 모르고 지나쳐 수락 맥락을 v2로 서명한다.
Future<(SecretAcceptedEvent, SimpleKeyPair)> _previousAppAccept(
  _Device responder,
  SecretInviteEvent invite,
) async {
  final ephemeral = await X25519().newKeyPair();
  final publicKey = await publicKeyBase64(ephemeral);
  final signer = responder.identity.signingKeyPair;
  final event = SecretAcceptedEvent.fromJson({
    'roomId': invite.roomId,
    'responderUserId': responder.userId,
    'responderDeviceId': responder.deviceId,
    'responderEphemeralPublicKey': publicKey,
    'responderEphemeralSignature': await crypto.signEphemeralKey(
      signer,
      base64Decode(publicKey),
    ),
    'responderContextSignature': await crypto.signContext(
      signer,
      crypto.secretAcceptContext(
        roomId: invite.roomId,
        initiatorUserId: invite.initiatorUserId,
        initiatorDeviceId: invite.initiatorDeviceId,
        initiatorEphemeralPublicKey: invite.initiatorEphemeralPublicKey,
        responderUserId: responder.userId,
        responderDeviceId: responder.deviceId,
        responderEphemeralPublicKey: publicKey,
      ),
    ),
  });
  return (event, ephemeral);
}

void main() {
  late _Server server;
  late _Device alice;
  late _Device bob;

  setUp(() async {
    server = _Server();
    alice = await _Device.open('u-alice', server);
    bob = await _Device.open('u-bob', server);
  });

  group('새 앱끼리 — 새 규약(v3, 더블 래칫)', () {
    test(
      '초대에 규약 3을 싣고 밥은 v3 맥락(v2 아님)으로 서명해 수락한다 — 두 기기 모두 래칫 상태만 두고, 글이 양쪽으로 풀리며 '
      '예전 방식 안내는 없다',
      () async {
        final invite = await _start(alice, 'u-bob');
        expect(server.started.single['protocol'], crypto.secretProtocolV3);
        expect(invite.initiatorProtocol, crypto.secretProtocolV3);
        expect(invite.initiatorContextSignature, isA<String>());
        final pending = await alice.store.readPendingInit('room-1');
        expect(pending.offeredProtocol, crypto.secretProtocolV3);
        expect(pending.targetUserId, 'u-bob');
        expect(pending.myDeviceId, alice.deviceId);

        bob.rooms['room-1'] = Room.fromJson(
          _roomJson('room-1', status: 'pending'),
        );
        expect(
          await bob.manager.acceptInvite(invite),
          SecretHandshakeOutcome.established,
        );
        expect(
          await _acceptSignedWith(crypto.secretAcceptContextV3, invite, bob),
          isTrue,
        );
        expect(
          await _acceptSignedWith(crypto.secretAcceptContext, invite, bob),
          isFalse,
          reason: 'v3로 수락한 서명은 v2 맥락으로는 맞지 않아야 한다',
        );
        expect(
          await alice.manager.handleAccepted(_accepted(bob, 'room-1')),
          SecretHandshakeOutcome.established,
        );

        for (final device in [alice, bob]) {
          expect(
            await device.protocol(),
            crypto.secretProtocolV3,
            reason: device.userId,
          );
          expect(device.stored('ratchet'), isNotNull, reason: device.userId);
          for (final v1Field in ['chainKey', 'epoch', 'n', 'skipped']) {
            expect(
              device.stored(v1Field),
              isNull,
              reason: '${device.userId}: $v1Field',
            );
          }
        }
        expect(alice.stored('pendingEphemeralSeed'), isNull);
        expect(alice.stored('pendingInit'), isNull);
        expect(_ratchetOf(alice).role, secretRoleInitiator);
        expect(_ratchetOf(bob).role, secretRoleResponder);

        // 수락한 쪽(밥)이 먼저 보내도 된다.
        final first = await bob.send('먼저 보냅니다');
        expect(_decode(first)['v'], crypto.secretProtocolV3);
        expect(_decode(first)['s'], secretRoleResponder);
        expect(await alice.receive(first, from: 'u-bob'), '먼저 보냅니다');
        final reply = await alice.send('안녕하세요');
        expect(_decode(reply)['s'], secretRoleInitiator);
        expect(await bob.receive(reply, from: 'u-alice'), '안녕하세요');
        for (final text in [
          '',
          '이모지 😀👍 그리고\n두 줄',
          '긴 글 ${'가나다' * 2000}',
          jsonEncode({'v': 1, 'epoch': 0, 'n': 0}),
        ]) {
          await _roundTrip(alice, bob, text);
          await _roundTrip(bob, alice, text);
        }

        for (final device in [alice, bob]) {
          final trust = await device.manager.loadTrust('room-1');
          expect(trust.legacyProtocol, isFalse, reason: device.userId);
          expect(trust.showProtocolNotice, isFalse, reason: device.userId);
          expect(trust.showLegacyNotice, isFalse, reason: device.userId);
          expect(trust.blocked, isFalse, reason: device.userId);
        }
      },
    );

    test('초대를 보낸 뒤(수락 전) 앱을 다시 켜도 제안한 규약을 기억해 v3로 맺는다', () async {
      final invite = await _start(alice, 'u-bob');
      alice = await alice.restart();
      bob.rooms['room-1'] = Room.fromJson(
        _roomJson('room-1', status: 'pending'),
      );
      expect(
        await bob.manager.acceptInvite(invite),
        SecretHandshakeOutcome.established,
      );
      bob = await bob.restart();
      expect(
        await alice.manager.handleAccepted(_accepted(bob, 'room-1')),
        SecretHandshakeOutcome.established,
      );
      expect(await alice.protocol(), 3);
      expect(await bob.protocol(), 3);
      await _roundTrip(alice, bob, '다시 켠 뒤 처음');
      await _roundTrip(bob, alice, '다시 켠 뒤 답장');
    });

    test(
      '동시에 보내도(둘 다 상대 글을 받기 전에 암호화) 각자 상대 글만 받는다 — 맺자마자·여러 개씩·받는 순서를 바꿔도',
      () async {
        await _handshake(alice, bob);
        // 맺자마자 — 앨리스는 첫 래칫 키, 밥은 0번 체인으로 동시에.
        await _simultaneous(alice, bob, ['앨리스 동시 1'], ['밥 동시 1']);
        await _simultaneous(
          alice,
          bob,
          ['앨리스 2-1', '앨리스 2-2', '앨리스 2-3'],
          ['밥 2-1', '밥 2-2'],
          peerFirst: true,
        );
        await _roundTrip(alice, bob, '사이에 한 번');
        await _simultaneous(
          alice,
          bob,
          ['앨리스 3'],
          ['밥 3-1', '밥 3-2', '밥 3-3', '밥 3-4'],
          reversed: true,
        );
        await _simultaneous(
          alice,
          bob,
          ['앨리스 4-1', '앨리스 4-2', '앨리스 4-3', '앨리스 4-4'],
          ['밥 4'],
          peerFirst: true,
          reversed: true,
        );
        await _roundTrip(bob, alice, '이어서');
        expect(await alice.protocol(), 3);
        expect(await bob.protocol(), 3);
        // 늦게 온 글까지 다 받았으니 남겨 둔 키도 없다.
        expect(_ratchetOf(alice).skipped, isEmpty);
        expect(_ratchetOf(bob).skipped, isEmpty);
      },
    );

    test(
      '한 기기에서 보내기·받기를 한꺼번에 겹쳐 불러도 방마다 차례로 처리한다 — 같은 키를 두 번 쓰지 않고 모두 풀린다',
      () async {
        await _handshake(alice, bob);
        final texts = [for (var i = 0; i < 12; i++) '겹친 글 $i'];
        final envelopes = await Future.wait([
          for (final t in texts) alice.manager.encryptForRoom('room-1', t),
        ]);
        expect({for (final e in envelopes) _position(e!)}, hasLength(12));
        final opened = await Future.wait([
          for (final e in envelopes.reversed)
            bob.manager.decryptForRoom('room-1', e!, senderUserId: 'u-alice'),
        ]);
        expect(opened, texts.reversed.toList());

        final more = [for (var i = 0; i < 4; i++) await alice.send('더 $i')];
        final results = await Future.wait<String?>([
          bob.manager.decryptForRoom(
            'room-1',
            more[3],
            senderUserId: 'u-alice',
          ),
          bob.manager.encryptForRoom('room-1', '겹친 답장 1'),
          bob.manager.decryptForRoom(
            'room-1',
            more[1],
            senderUserId: 'u-alice',
          ),
          bob.manager.encryptForRoom('room-1', '겹친 답장 2'),
          bob.manager.decryptForRoom('room-1', more[0]),
          bob.manager.decryptForRoom(
            'room-1',
            more[2],
            senderUserId: 'u-alice',
          ),
        ]);
        expect(results[0], '더 3');
        expect(results[2], '더 1');
        expect(results[4], '더 0');
        expect(results[5], '더 2');
        expect(await alice.receive(results[3]!, from: 'u-bob'), '겹친 답장 2');
        expect(await alice.receive(results[1]!, from: 'u-bob'), '겹친 답장 1');
        expect(await bob.receive(results[1]!, from: 'u-bob'), '겹친 답장 1');
      },
    );

    test(
      '긴 대화 — 고정한 시드로 보내기(가끔 몰아서)·받기·되돌아온 내 글을 섞어 양쪽 160개씩 주고받아도 모두 풀린다',
      () async {
        await _handshake(alice, bob);
        final result = await _converse(
          alice,
          bob,
          perSide: 160,
          seed: 20261007,
        );
        alice = result.alice;
        bob = result.bob;
        // 방향이 여러 번 바뀌어 래칫 키가 계속 새로 나왔고, 몰아서 보낸 적도 있다. 두 기기가 같은 키 자리를 쓴 적은 없다.
        expect(result.ratchetKeys, greaterThan(15));
        expect(result.maxBurst, greaterThanOrEqualTo(5));
        expect(result.sameIndex, 0);
        // 이어서 한 개씩 번갈아 60번 — 방향이 바뀔 때마다 새 래칫 키로 넘어간다.
        final pingPongKeys = <String>{};
        for (var i = 0; i < 60; i++) {
          for (final (from, to) in [(alice, bob), (bob, alice)]) {
            final text = '${from.userId} 번갈아 $i';
            final envelope = await from.send(text);
            pingPongKeys.add(_decode(envelope)['dh'] as String);
            expect(await to.receive(envelope, from: from.userId), text);
          }
        }
        expect(pingPongKeys, hasLength(120));
        expect(await alice.protocol(), 3);
        expect(await bob.protocol(), 3);
        expect(_ratchetOf(alice).skipped, isEmpty);
        expect(_ratchetOf(bob).skipped, isEmpty);
        await _roundTrip(alice, bob, '긴 대화 뒤');
        await _roundTrip(bob, alice, '긴 대화 뒤 답장');
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    test(
      '긴 대화 — 한 방향 안에서도 순서가 가끔 뒤바뀌고(서버가 늦게 보낸 글을 먼저 줌) 가끔 앱을 다시 켜도 양쪽 160개씩 모두 풀린다',
      () async {
        await _handshake(alice, bob);
        final result = await _converse(
          alice,
          bob,
          perSide: 160,
          seed: 4242,
          reorder: true,
          restartChance: 0.02,
        );
        alice = result.alice;
        bob = result.bob;
        expect(result.restarts, greaterThan(0));
        expect(result.outOfOrder, greaterThan(50));
        expect(result.ratchetKeys, greaterThan(15));
        expect(result.sameIndex, 0);
        expect(_ratchetOf(alice).skipped, isEmpty);
        expect(_ratchetOf(bob).skipped, isEmpty);
        await _roundTrip(alice, bob, '긴 대화 뒤');
        await _roundTrip(bob, alice, '긴 대화 뒤 답장');
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    test('내 글·상대 글 가리기 — 나라는 봉투는 보낸 평문으로만(두 번 와도), 상대·다른 사람이라는 봉투는 묶인 상대의 키로만 '
        '풀고, 보낸 사람을 모르면(null) 상대의 키로만 푼다(내 글로 보지 않는다)', () async {
      await _handshake(alice, bob);
      final mine = await alice.send('내가 보낸 글');
      final theirs1 = await bob.send('밥이 보낸 글 1');
      final theirs2 = await bob.send('밥이 보낸 글 2');

      // 서버가 내 봉투를 밥이 보낸 것이라고 붙이면 풀지 않는다(내 체인은 상대 키로 풀리지 않는다).
      expect(await alice.receive(mine, from: 'u-bob'), isNull);
      // 내 글이 되돌아옴(echo) — 다시 받기(재연결 뒤 히스토리)로 또 와도 같은 평문.
      expect(await alice.receive(mine, from: 'u-alice'), '내가 보낸 글');
      expect(await alice.receive(mine, from: 'u-alice'), '내가 보낸 글');
      // 보낸 사람이 없다는 내 봉투는 내 글로 보지 않는다 — 서버가 내 글을 보낸 사람 없이(다른 이름으로) 다시 보내 상대 글처럼
      // 보이게 하지 못하게(실제 내 메시지에는 늘 내 id가 붙는다).
      expect(await alice.receive(mine), isNull);

      // 밥의 봉투를 내가 보냈다고 하면, 다른 사람(캐럴)이 보냈다고 하면 풀지 않는다.
      expect(await alice.receive(theirs1, from: 'u-alice'), isNull);
      expect(await alice.receive(theirs1, from: 'u-carol'), isNull);
      // 위에서 풀지 않은 것은 상태를 바꾸지 않았다 — 제대로 오면 풀린다(보낸 사람을 몰라도).
      expect(await alice.receive(theirs1), '밥이 보낸 글 1');
      expect(await alice.receive(theirs2, from: 'u-bob'), '밥이 보낸 글 2');
      // 이미 받은 상대 글이 또 오면 풀지 않는다(Session은 평문 캐시를 쓴다) — 대화는 그대로 이어진다.
      expect(await alice.receive(theirs1, from: 'u-bob'), isNull);
      expect(await alice.receive(theirs2), isNull);

      // 밥 쪽도 같다.
      expect(await bob.receive(mine, from: 'u-bob'), isNull);
      expect(await bob.receive(mine, from: 'u-carol'), isNull);
      expect(await bob.receive(theirs1, from: 'u-alice'), isNull);
      expect(await bob.receive(theirs1, from: 'u-bob'), '밥이 보낸 글 1');
      expect(await bob.receive(theirs2), isNull);
      expect(await bob.receive(theirs2, from: 'u-bob'), '밥이 보낸 글 2');
      expect(await bob.receive(mine, from: 'u-alice'), '내가 보낸 글');

      await _roundTrip(alice, bob, '이어서');
      await _roundTrip(bob, alice, '이어서 2');
    });

    test(
      '보낸 글을 아주 많이 쌓아 둬도 최근 것은 되돌아오면 내 글로 보이고, 오래돼 잊은 것도 엉뚱한 글이 아니다',
      () async {
        await _handshake(alice, bob);
        final envelopes = [
          for (var i = 0; i < 300; i++) await alice.send('쌓인 글 $i'),
        ];
        for (var i = 299; i >= 100; i--) {
          expect(await alice.receive(envelopes[i], from: 'u-alice'), '쌓인 글 $i');
        }
        expect(
          await alice.receive(envelopes[0], from: 'u-alice'),
          anyOf(isNull, '쌓인 글 0'),
        );
        expect(await alice.receive(envelopes[0]), anyOf(isNull, '쌓인 글 0'));
        // 밥은 300개 모두 받는다.
        for (var i = 0; i < 300; i++) {
          expect(await bob.receive(envelopes[i], from: 'u-alice'), '쌓인 글 $i');
        }
      },
    );

    test('가짜·변조·너무 앞선 봉투는 풀지 않고 래칫 상태도 바꾸지 않는다 — 그 뒤 진짜 글은 그대로 풀린다', () async {
      await _handshake(alice, bob);
      await _roundTrip(alice, bob, '처음');
      await _roundTrip(bob, alice, '답장');
      final real = await alice.send('진짜 글');
      final realJson = _decode(real);
      final fakeRatchetKey = await publicKeyBase64(await X25519().newKeyPair());
      final nonce = base64Encode(List<int>.filled(12, 7));
      final garbage = base64Encode(List<int>.filled(48, 3));
      final bad = <Object>[
        // 암호문 한 바이트 변조.
        {
          ...realJson,
          'ciphertext': _flipFirstByte(realJson['ciphertext'] as String),
        },
        // 머리(번호·이전 수·보낸 쪽) 변조 — AAD로 묶여 있다.
        {...realJson, 'n': (realJson['n'] as int) + 1},
        {...realJson, 'pn': (realJson['pn'] as int) + 1},
        {...realJson, 's': secretRoleResponder},
        // 처음 보는 래칫 키와 큰 번호(계산을 많이 시키는 가짜) — 한계 안.
        {
          'v': 3,
          's': secretRoleInitiator,
          'dh': fakeRatchetKey,
          'pn': secretRatchetMaxSkip - 1,
          'n': secretRatchetMaxSkip - 1,
          'epoch': 0,
          'nonce': nonce,
          'ciphertext': garbage,
        },
        // 한계를 넘는 번호.
        {...realJson, 'n': (realJson['n'] as int) + secretRatchetMaxSkip + 1},
        // 모양이 틀린 봉투.
        {'v': 3},
        {...realJson, 'dh': 'AAAA'},
        {...realJson, 'nonce': base64Encode(List<int>.filled(8, 1))},
        {...realJson, 'n': -1},
        {...realJson, 'v': 1},
        '봉투가 아님',
        '[1, 2, 3]',
      ];
      final before = bob.stored('ratchet');
      for (final envelope in bad) {
        final text = envelope is String ? envelope : jsonEncode(envelope);
        expect(await bob.receive(text, from: 'u-alice'), isNull, reason: text);
        expect(bob.stored('ratchet'), before, reason: '상태가 바뀌었다: $text');
      }
      expect(await bob.receive(real, from: 'u-alice'), '진짜 글');
      // 이미 받은 진짜 글을 다시 보내도(재전송) 풀지 않고 상태를 바꾸지 않는다.
      final after = bob.stored('ratchet');
      expect(await bob.receive(real, from: 'u-alice'), isNull);
      expect(bob.stored('ratchet'), after);
      await _roundTrip(bob, alice, '그 뒤로도');
      await _roundTrip(alice, bob, '그 뒤로도 2');
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  group('히스토리·다시 켜기', () {
    for (final protocol in [3, 1]) {
      test(
        'v$protocol: 히스토리를 최신 페이지부터 — 상대가 보낸 60개 중 최신 50개를 먼저 풀고 그 전 10개를 풀어도, 하나씩 '
        '거꾸로 풀어도 양쪽 방향 모두 풀린다',
        () async {
          await _establish(alice, bob, protocol);
          bob = await _receiveInOrder(
            alice,
            bob,
            _firstPageThenOlder,
            label: '최신 페이지 먼저',
          );
          if (protocol == 3) {
            // 첫 페이지를 푼 순간 건너뛴 10개의 키를 남겨 뒀다가 다 썼다.
            expect(_ratchetOf(bob).skipped, isEmpty);
          } else {
            expect(bob.stored('skipped'), isNull);
          }
          alice = await _receiveInOrder(
            bob,
            alice,
            _firstPageThenOlder,
            label: '최신 페이지 먼저(답장)',
          );
          bob = await _receiveInOrder(alice, bob, _newestFirst, label: '거꾸로');
          alice = await _receiveInOrder(
            bob,
            alice,
            _newestFirst,
            label: '거꾸로(답장)',
          );
          await _roundTrip(alice, bob, '히스토리 뒤 실시간');
          await _roundTrip(bob, alice, '히스토리 뒤 실시간 2');
          expect(await alice.protocol(), protocol);
          expect(await bob.protocol(), protocol);
        },
      );

      test(
        'v$protocol: 최신 페이지를 푼 뒤 앱을 다시 켜고 그 전 페이지를 풀어도 남겨 둔 키(저장됨)로 풀린다',
        () async {
          await _establish(alice, bob, protocol);
          final texts = [for (var i = 0; i < 60; i++) '히스토리 $i'];
          final envelopes = [for (final t in texts) await alice.send(t)];
          for (var i = 10; i < 60; i++) {
            expect(await bob.receive(envelopes[i], from: 'u-alice'), texts[i]);
          }
          if (protocol == 3) {
            expect(_ratchetOf(bob).skipped, hasLength(10));
          } else {
            expect(bob.stored('skipped'), isNotNull);
          }
          bob = await bob.restart();
          for (var i = 0; i < 10; i++) {
            expect(
              await bob.receive(envelopes[i], from: 'u-alice'),
              texts[i],
              reason: '다시 켠 뒤 $i번째',
            );
          }
          if (protocol == 3) {
            expect(_ratchetOf(bob).skipped, isEmpty);
          } else {
            expect(bob.stored('skipped'), isNull);
          }
          // 반대 방향도 — 가장 늦은 것부터 30개를 풀고 다시 켠 뒤 나머지.
          alice = await _receiveInOrder(
            bob,
            alice,
            _newestFirst,
            label: '거꾸로, 중간에 다시 켬',
            restartAfter: 30,
          );
          await _roundTrip(alice, bob, '다시 켠 뒤 실시간');
          await _roundTrip(bob, alice, '다시 켠 뒤 실시간 2');
        },
      );

      test(
        'v$protocol: 대화 중에 한쪽·양쪽을 다시 켜도(보낸 뒤 상대가 받기 전 포함) 저장된 상태로 이어 간다',
        () async {
          await _establish(alice, bob, protocol);
          await _roundTrip(alice, bob, '켜기 전 1');
          await _roundTrip(bob, alice, '켜기 전 2');

          // 앨리스가 보낸 뒤, 밥이 받기 전에 밥을 다시 켠다.
          final a1 = await alice.send('보낸 뒤 밥이 다시 켬');
          bob = await bob.restart();
          expect(await bob.receive(a1, from: 'u-alice'), '보낸 뒤 밥이 다시 켬');
          expect(await alice.receive(a1, from: 'u-alice'), '보낸 뒤 밥이 다시 켬');

          // 밥이 보낸 뒤 밥 자신을 다시 켠다 — 앨리스는 그대로 받고, 밥에게 되돌아온 자기 글은(평문을 잊어) 풀지 않는다.
          final b1 = await bob.send('보낸 뒤 내가 다시 켬');
          bob = await bob.restart();
          expect(await alice.receive(b1, from: 'u-bob'), '보낸 뒤 내가 다시 켬');
          expect(await bob.receive(b1, from: 'u-bob'), isNull);
          expect(await bob.receive(b1), isNull);

          // 보내기 사이에 다시 켜도 같은 키를 다시 쓰지 않는다.
          final a2 = await alice.send('켜기 전 마지막');
          alice = await alice.restart();
          final a3 = await alice.send('켠 뒤 처음');
          expect(_position(a3), isNot(_position(a2)));
          expect(await bob.receive(a3, from: 'u-alice'), '켠 뒤 처음');
          expect(await bob.receive(a2, from: 'u-alice'), '켜기 전 마지막');

          // 둘 다 다시 켜고 방향을 바꿔 가며 이어 간다.
          alice = await alice.restart();
          bob = await bob.restart();
          for (var i = 0; i < 4; i++) {
            await _roundTrip(alice, bob, '둘 다 켠 뒤 $i');
            await _roundTrip(bob, alice, '둘 다 켠 뒤 답장 $i');
            if (i.isEven) {
              alice = await alice.restart();
            } else {
              bob = await bob.restart();
            }
          }
          expect(await alice.protocol(), protocol);
          expect(await bob.protocol(), protocol);
          final trust = await bob.manager.loadTrust('room-1');
          expect(trust.legacyProtocol, protocol == 1);
          expect(trust.blocked, isFalse);
        },
      );
    }
  });

  group('규약 협상 — 예전 서버·예전 앱·서버가 바꾼 값', () {
    test(
      '서버가 초대의 규약 표시를 빼고 전하면(예전 서버) 양쪽 모두 v1로 맺고 서로 풀리며, 두 기기 모두 "예전 방식" 안내를 '
      '띄운다(상대가 예전 앱은 아니다)',
      () async {
        final invite = await _handshake(
          alice,
          bob,
          inviteRelay: _without('initiatorProtocol'),
        );
        expect(server.started.single['protocol'], 3);
        expect(invite.initiatorProtocol, isNull);
        expect(
          await _acceptSignedWith(crypto.secretAcceptContext, invite, bob),
          isTrue,
        );
        expect(
          await _acceptSignedWith(crypto.secretAcceptContextV3, invite, bob),
          isFalse,
        );
        for (final device in [alice, bob]) {
          expect(await device.protocol(), 1, reason: device.userId);
          expect(device.stored('ratchet'), isNull, reason: device.userId);
          expect(device.stored('chain'), isNotNull, reason: device.userId);
          expect(device.stored('chainKey'), isNull, reason: device.userId);
          final trust = await device.manager.loadTrust('room-1');
          expect(trust.legacyProtocol, isTrue, reason: device.userId);
          expect(trust.security.legacyPeer, isFalse, reason: device.userId);
          expect(trust.showProtocolNotice, isTrue, reason: device.userId);
          expect(trust.showLegacyNotice, isFalse, reason: device.userId);
        }
        for (var i = 0; i < 5; i++) {
          await _roundTrip(alice, bob, '예전 방식 $i');
          await _roundTrip(bob, alice, '예전 방식 답장 $i');
        }
      },
    );

    test(
      '서버가 전한 규약 번호가 3 이상의 정수일 때만 v3 — 빠졌거나 숫자가 아니거나 3보다 작으면 v1이고, 어느 쪽이든 두 기기가 '
      '같은 규약으로 맺어 서로 풀린다',
      () async {
        final cases = <(Object?, int)>[
          (null, 1),
          ('3', 1),
          (2, 1),
          (1, 1),
          (0, 1),
          (3, 3),
          (4, 3),
        ];
        for (var i = 0; i < cases.length; i++) {
          final (relayed, expected) = cases[i];
          final roomId = 'room-p$i';
          await _handshake(
            alice,
            bob,
            roomId: roomId,
            inviteRelay: _with('initiatorProtocol', relayed),
          );
          expect(
            await alice.protocol(roomId),
            expected,
            reason: '서버가 $relayed를 전함 — 앨리스',
          );
          expect(
            await bob.protocol(roomId),
            expected,
            reason: '서버가 $relayed를 전함 — 밥',
          );
          await _roundTrip(alice, bob, '$relayed 앨리스', roomId: roomId);
          await _roundTrip(bob, alice, '$relayed 밥', roomId: roomId);
        }
      },
    );

    test(
      '예전 앱(맥락 서명·규약 표시 없음)이 건 초대 — 밥은 v1로 맺고 "예전 앱"으로 표시하며(예전 방식 안내는 아님), 그 앱과 '
      '글이 오간다',
      () async {
        final (invite, aliceEphemeral) = await _oldAppInvite(alice, 'u-bob');
        expect(invite.initiatorContextSignature, isNull);
        expect(invite.initiatorProtocol, isNull);
        bob.rooms['room-1'] = Room.fromJson(
          _roomJson('room-1', status: 'pending'),
        );
        expect(
          await bob.manager.acceptInvite(invite),
          SecretHandshakeOutcome.established,
        );
        expect(await bob.protocol(), 1);
        expect(bob.stored('ratchet'), isNull);
        expect(
          await _acceptSignedWith(crypto.secretAcceptContext, invite, bob),
          isTrue,
        );
        expect(
          await _acceptSignedWith(crypto.secretAcceptContextV3, invite, bob),
          isFalse,
        );
        final trust = await bob.manager.loadTrust('room-1');
        expect(trust.legacyProtocol, isTrue);
        expect(trust.security.legacyPeer, isTrue);
        expect(trust.showLegacyNotice, isTrue);
        expect(trust.showProtocolNotice, isFalse);

        // 예전 앱(앨리스 흉내)은 밥의 v1 서명을 확인하고 같은 체인키를 만든다.
        final acceptBody = server.accepted['room-1']!;
        final bobEphemeral =
            acceptBody['responderEphemeralPublicKey'] as String;
        expect(
          await crypto.verifyEphemeralKey(
            signingPublicKeyBase64: await bob.signingKey,
            ephemeralPublicKeyBytes: base64Decode(bobEphemeral),
            signatureBase64:
                acceptBody['responderEphemeralSignature'] as String,
          ),
          isTrue,
        );
        final oldAlice = await _oldAppChain(
          aliceEphemeral,
          bobEphemeral,
          'room-1',
        );
        for (var i = 0; i < 3; i++) {
          final a = await oldAlice.encrypt('예전 앱 $i');
          expect(await bob.receive(a, from: 'u-alice'), '예전 앱 $i');
          final b = await bob.send('새 앱 $i');
          expect(await oldAlice.decrypt(b), '새 앱 $i');
          expect(await bob.receive(b, from: 'u-bob'), '새 앱 $i');
        }
        // 같은 번호로 거의 동시에 보내도 밥은 예전 앱의 글을 그 글로 받는다.
        final fromOld = await oldAlice.encrypt('예전 앱 동시');
        final fromBob = await bob.send('새 앱 동시');
        expect(_index(fromOld), _index(fromBob));
        expect(await bob.receive(fromBob, from: 'u-bob'), '새 앱 동시');
        expect(await bob.receive(fromOld, from: 'u-alice'), '예전 앱 동시');
        final next = await bob.send('그다음');
        expect(await oldAlice.decrypt(next), '그다음');
      },
    );

    test(
      '서버가 예전 앱의 초대(맥락 서명 없음)에 규약 3을 붙여도 밥은 v3로 맺지 않는다(v1) — 예전 앱과 그대로 대화한다',
      () async {
        final (invite, aliceEphemeral) = await _oldAppInvite(
          alice,
          'u-bob',
          protocol: 3,
        );
        expect(invite.initiatorProtocol, 3);
        expect(invite.initiatorContextSignature, isNull);
        bob.rooms['room-1'] = Room.fromJson(
          _roomJson('room-1', status: 'pending'),
        );
        expect(
          await bob.manager.acceptInvite(invite),
          SecretHandshakeOutcome.established,
        );
        expect(await bob.protocol(), 1);
        expect(bob.stored('ratchet'), isNull);
        expect(
          await _acceptSignedWith(crypto.secretAcceptContext, invite, bob),
          isTrue,
        );
        expect(
          await _acceptSignedWith(crypto.secretAcceptContextV3, invite, bob),
          isFalse,
        );
        expect(
          (await bob.manager.loadTrust('room-1')).security.legacyPeer,
          isTrue,
        );
        final oldAlice = await _oldAppChain(
          aliceEphemeral,
          server.accepted['room-1']!['responderEphemeralPublicKey'] as String,
          'room-1',
        );
        final a = await oldAlice.encrypt('예전 앱');
        expect(await bob.receive(a, from: 'u-alice'), '예전 앱');
        final b = await bob.send('새 앱');
        expect(await oldAlice.decrypt(b), '새 앱');
      },
    );

    test(
      '서버가 이 업데이트 전 앱(v2는 알지만 v3는 모름)의 초대에 규약 3을 붙이면 밥은 v3로 수락하지만, 그 수락 서명은 v2 맥락으로 '
      '맞지 않아 예전 앱은 믿지 않는다 — 서로 다른 규약으로 대화하지 않는다(서비스 거부일 뿐)',
      () async {
        final (invite, _) = await _oldAppInvite(
          alice,
          'u-bob',
          withContext: true,
          protocol: 3,
        );
        bob.rooms['room-1'] = Room.fromJson(
          _roomJson('room-1', status: 'pending'),
        );
        expect(
          await bob.manager.acceptInvite(invite),
          SecretHandshakeOutcome.established,
        );
        expect(await bob.protocol(), 3);
        expect(
          await _acceptSignedWith(crypto.secretAcceptContext, invite, bob),
          isFalse,
          reason: '예전 앱은 v2 맥락으로만 확인한다',
        );
        expect(
          await _acceptSignedWith(crypto.secretAcceptContextV3, invite, bob),
          isTrue,
        );
      },
    );

    test(
      'v3를 제안했는데 밥이 v2 맥락으로 수락하면(규약 표시가 빠진 초대를 받음) 앨리스도 v1로 맺어 서로 맞는다 — 동시에 보내도',
      () async {
        final invite = await _start(
          alice,
          'u-bob',
          relay: _without('initiatorProtocol'),
        );
        expect(server.started.single['protocol'], 3);
        expect(
          (await alice.store.readPendingInit('room-1')).offeredProtocol,
          3,
        );
        bob.rooms['room-1'] = Room.fromJson(
          _roomJson('room-1', status: 'pending'),
        );
        expect(
          await bob.manager.acceptInvite(invite),
          SecretHandshakeOutcome.established,
        );
        expect(
          await _acceptSignedWith(crypto.secretAcceptContext, invite, bob),
          isTrue,
        );
        expect(
          await _acceptSignedWith(crypto.secretAcceptContextV3, invite, bob),
          isFalse,
        );
        expect(
          await alice.manager.handleAccepted(_accepted(bob, 'room-1')),
          SecretHandshakeOutcome.established,
        );
        expect(await alice.protocol(), 1);
        expect(await bob.protocol(), 1);
        expect(alice.stored('ratchet'), isNull);
        expect(alice.stored('pendingInit'), isNull);
        final trust = await alice.manager.loadTrust('room-1');
        expect(trust.security.legacyPeer, isFalse);
        expect(trust.legacyProtocol, isTrue);
        expect(trust.showProtocolNotice, isTrue);
        await _roundTrip(alice, bob, 'v1로 맞춤');
        await _roundTrip(bob, alice, 'v1로 맞춤 답장');
        await _simultaneous(alice, bob, ['앨리스 동시'], ['밥 동시']);
        await _roundTrip(alice, bob, '동시 뒤');
      },
    );

    test('이 업데이트 전 앱(v2는 알지만 v3는 모름)이 수락하면 앨리스는 v1로 맺고 그 앱과 글이 오간다', () async {
      final invite = await _start(alice, 'u-bob');
      final (accepted, bobEphemeral) = await _previousAppAccept(bob, invite);
      expect(
        await alice.manager.handleAccepted(accepted),
        SecretHandshakeOutcome.established,
      );
      expect(await alice.protocol(), 1);
      final trust = await alice.manager.loadTrust('room-1');
      expect(trust.security.legacyPeer, isFalse);
      expect(trust.showProtocolNotice, isTrue);
      final previousBob = await _oldAppChain(
        bobEphemeral,
        invite.initiatorEphemeralPublicKey,
        'room-1',
      );
      for (var i = 0; i < 3; i++) {
        final a = await alice.send('새 앱 $i');
        expect(await previousBob.decrypt(a), '새 앱 $i');
        final b = await previousBob.encrypt('예전 앱 $i');
        expect(await alice.receive(b, from: 'u-bob'), '예전 앱 $i');
      }
      // 예전 앱이 같은 번호로 거의 동시에 보낸 글도 앨리스는 그 글로 받는다.
      final fromAlice = await alice.send('새 앱 동시');
      final fromOld = await previousBob.encrypt('예전 앱 동시');
      expect(_index(fromAlice), _index(fromOld));
      expect(await alice.receive(fromOld, from: 'u-bob'), '예전 앱 동시');
      expect(await alice.receive(fromAlice, from: 'u-alice'), '새 앱 동시');
    });

    test(
      '밥은 v3로 수락했는데 서버가 secret:accepted에서 맥락 서명을 빼면 앨리스는 예전 서명 칸(v3 맥락 서명이 들어 있다)으로도 '
      '확인하지 못해 멈춘다 — 한쪽만 v3인 채로 맺어지지 않고, 엉뚱한 글도 나오지 않는다',
      () async {
        final invite = await _start(alice, bob.userId);
        bob.rooms['room-1'] = Room.fromJson(
          _roomJson('room-1', status: 'pending'),
        );
        expect(
          await bob.manager.acceptInvite(invite),
          SecretHandshakeOutcome.established,
        );
        expect(await bob.protocol(), 3);
        // 밥은 예전 서명 칸에도 v3 맥락 서명을 넣었다(키만 서명한 값이 아니다).
        final body = server.accepted['room-1']!;
        expect(
          body['responderEphemeralSignature'],
          body['responderContextSignature'],
        );
        expect(
          await alice.manager.handleAccepted(
            _accepted(
              bob,
              'room-1',
              relay: _without('responderContextSignature'),
            ),
          ),
          SecretHandshakeOutcome.blocked,
        );
        expect(await alice.protocol(), isNull);
        final aliceTrust = await alice.manager.loadTrust('room-1');
        expect(aliceTrust.blocked, isTrue);
        expect(
          aliceTrust.security.blockedReason,
          SecretBlockReason.badSignature,
        );
        await expectLater(
          alice.manager.encryptForRoom('room-1', '보내면 안 된다'),
          throwsA(isA<SecretChatBlockedException>()),
        );
        // 밥이 보낸 글을 앨리스는 풀지 않는다(엉뚱한 글이 아니라 null).
        final b = await bob.send('밥 글');
        expect(await alice.receive(b, from: 'u-bob'), isNull);
      },
    );

    test('앨리스가 규약 표시 없이 건 초대(업데이트 전에 걸어 둠)에 서버가 규약 3을 붙여 밥이 v3로 수락하면, 앨리스는 v3를 '
        '제안한 적이 없어 그 수락을 믿지 않고 멈춘다 — 서로 다른 규약으로 대화하지 않는다', () async {
      final invite = await _start(alice, 'u-bob');
      // 업데이트 전 앱이 남긴 대기 정보처럼 — 실어 보낸 규약 번호가 없다.
      alice.keyStorage.data['secret/room-1/pendingInit'] = jsonEncode({
        't': 'u-bob',
        'd': alice.deviceId,
      });
      expect(
        (await alice.store.readPendingInit('room-1')).offeredProtocol,
        isNull,
      );
      bob.rooms['room-1'] = Room.fromJson(
        _roomJson('room-1', status: 'pending'),
      );
      expect(
        await bob.manager.acceptInvite(invite),
        SecretHandshakeOutcome.established,
      );
      expect(await bob.protocol(), 3);
      expect(
        await alice.manager.handleAccepted(_accepted(bob, 'room-1')),
        SecretHandshakeOutcome.blocked,
      );
      expect(await alice.manager.hasActiveSession('room-1'), isFalse);
      expect((await alice.manager.loadTrust('room-1')).blocked, isTrue);
    });

    test('업데이트 전에 건 초대(규약 표시 없음)를 서버가 그대로 전하면 업데이트한 앨리스와 밥은 v1로 맺는다', () async {
      final invite = await _start(
        alice,
        'u-bob',
        relay: _without('initiatorProtocol'),
      );
      alice.keyStorage.data['secret/room-1/pendingInit'] = jsonEncode({
        't': 'u-bob',
        'd': alice.deviceId,
      });
      bob.rooms['room-1'] = Room.fromJson(
        _roomJson('room-1', status: 'pending'),
      );
      expect(
        await bob.manager.acceptInvite(invite),
        SecretHandshakeOutcome.established,
      );
      expect(
        await alice.manager.handleAccepted(_accepted(bob, 'room-1')),
        SecretHandshakeOutcome.established,
      );
      expect(await alice.protocol(), 1);
      expect(await bob.protocol(), 1);
      await _roundTrip(alice, bob, '업데이트 전 초대');
      await _roundTrip(bob, alice, '업데이트 전 초대 답장');
    });

    test(
      '서버가 새 앱의 초대에서 맥락 서명을 빼면(규약 표시는 남기든 빼든) 밥은 예전 앱의 초대로 보고 v1로 맺고, 앨리스도 v1로 '
      '맞춰 서로 풀린다 — 밥에게는 "예전 앱" 안내가 보인다',
      () async {
        final relays = <String, _Relay>{
          'room-c1': _without('initiatorContextSignature'),
          'room-c2': (payload) => Map.of(payload)
            ..remove('initiatorContextSignature')
            ..remove('initiatorProtocol'),
        };
        for (final MapEntry(key: roomId, value: relay) in relays.entries) {
          await _handshake(alice, bob, roomId: roomId, inviteRelay: relay);
          expect(await alice.protocol(roomId), 1, reason: roomId);
          expect(await bob.protocol(roomId), 1, reason: roomId);
          final bobTrust = await bob.manager.loadTrust(roomId);
          expect(bobTrust.security.legacyPeer, isTrue, reason: roomId);
          expect(bobTrust.showLegacyNotice, isTrue, reason: roomId);
          final aliceTrust = await alice.manager.loadTrust(roomId);
          expect(aliceTrust.security.legacyPeer, isFalse, reason: roomId);
          expect(aliceTrust.showProtocolNotice, isTrue, reason: roomId);
          await _roundTrip(alice, bob, '$roomId 앨리스', roomId: roomId);
          await _roundTrip(bob, alice, '$roomId 밥', roomId: roomId);
        }
      },
    );

    test(
      '서버가 secret:accepted의 맥락 서명을 다른 값으로 바꾸면(서명 모양은 맞음) 앨리스는 v3로도 v2로도 확인하지 못해 맺지 않고 '
      '멈춘다',
      () async {
        final invite = await _start(alice, 'u-bob');
        bob.rooms['room-1'] = Room.fromJson(
          _roomJson('room-1', status: 'pending'),
        );
        expect(
          await bob.manager.acceptInvite(invite),
          SecretHandshakeOutcome.established,
        );
        // 밥이 같은 키로 서명했지만 다른 맥락(v2)인 서명 — 모양도 서명자도 맞는데 이 수락의 v3 맥락이 아니다.
        final wrongContext = await crypto.signContext(
          bob.identity.signingKeyPair,
          crypto.secretAcceptContext(
            roomId: 'room-1',
            initiatorUserId: 'u-alice',
            initiatorDeviceId: alice.deviceId,
            initiatorEphemeralPublicKey: invite.initiatorEphemeralPublicKey,
            responderUserId: 'u-bob',
            responderDeviceId: bob.deviceId,
            responderEphemeralPublicKey: await publicKeyBase64(
              await X25519().newKeyPair(),
            ),
          ),
        );
        expect(
          await alice.manager.handleAccepted(
            _accepted(
              bob,
              'room-1',
              relay: _with('responderContextSignature', wrongContext),
            ),
          ),
          SecretHandshakeOutcome.blocked,
        );
        expect(await alice.manager.hasActiveSession('room-1'), isFalse);
        expect((await alice.manager.loadTrust('room-1')).blocked, isTrue);
      },
    );
  });

  group('예전 규약(v1) 대화의 보완', () {
    test(
      'v1: 같은 번호로 동시에 보낸 글 — 각자 그 번호로 보낼 때 쓴 키로 상대 글을 풀어, 상대 글 그대로 보인다(내 글로 보이지 '
      '않는다)',
      () async {
        await _establish(alice, bob, 1);
        final a = await alice.send('앨리스 0번');
        final b = await bob.send('밥 0번');
        expect(_index(a), 0);
        expect(_index(b), 0);
        // 상대 글이 먼저 오고 내 글이 나중에 되돌아와도, 그 반대여도.
        expect(await alice.receive(b, from: 'u-bob'), '밥 0번');
        expect(await alice.receive(a, from: 'u-alice'), '앨리스 0번');
        expect(await bob.receive(b, from: 'u-bob'), '밥 0번');
        expect(await bob.receive(a, from: 'u-alice'), '앨리스 0번');
        // 보낸 사람을 모르는 경로(null)로 와도 상대 글은 상대 글로.
        final a1 = await alice.send('앨리스 1번');
        final b1 = await bob.send('밥 1번');
        expect(_index(a1), _index(b1));
        expect(await alice.receive(b1), '밥 1번');
        expect(await bob.receive(a1), '앨리스 1번');
        expect(await alice.receive(a1, from: 'u-alice'), '앨리스 1번');
        expect(await bob.receive(b1, from: 'u-bob'), '밥 1번');
        // 몰아서 동시에, 받는 순서를 바꿔서.
        await _simultaneous(
          alice,
          bob,
          ['앨리스 a', '앨리스 b', '앨리스 c'],
          ['밥 a', '밥 b'],
        );
        await _simultaneous(
          alice,
          bob,
          ['앨리스 d'],
          ['밥 d', '밥 e', '밥 f', '밥 g'],
          reversed: true,
          peerFirst: true,
        );
        // 둘 다 같은 자리에서 이어 간다.
        expect(_chainOf(alice).n, _chainOf(bob).n);
        expect(alice.stored('skipped'), isNull);
        expect(bob.stored('skipped'), isNull);
        await _roundTrip(alice, bob, '동시 뒤 1');
        await _roundTrip(bob, alice, '동시 뒤 2');
      },
    );

    test(
      'v1: 같은 번호로 동시에 보낸 직후 앱을 다시 켜면 그 번호의 상대 글은 풀지 못한다(보낼 때 쓴 키는 메모리에만 잠깐 둔다) '
      '— 엉뚱한 글이 아니라 null이고, 대화는 이어진다',
      () async {
        await _establish(alice, bob, 1);
        final a = await alice.send('앨리스 동시');
        final b = await bob.send('밥 동시');
        alice = await alice.restart();
        expect(await alice.receive(b, from: 'u-bob'), isNull);
        expect(await alice.receive(b), isNull);
        expect(await bob.receive(a, from: 'u-alice'), '앨리스 동시');
        await _roundTrip(alice, bob, '그 뒤로는 그대로');
        await _roundTrip(bob, alice, '그 뒤로는 그대로 2');
      },
    );

    test(
      'v1: 늦게 온 글 — 5개 중 마지막을 먼저 풀고 앞의 4개를 나중에 풀어도 남겨 둔 키(저장됨)로 풀린다, 앱을 다시 켠 뒤에도',
      () async {
        await _establish(alice, bob, 1);
        final envelopes = [
          for (var i = 0; i < 5; i++) await alice.send('늦게 $i'),
        ];
        expect(await bob.receive(envelopes[4], from: 'u-alice'), '늦게 4');
        expect(_chainOf(bob).n, 5);
        expect(bob.stored('skipped'), isNotNull);
        for (var i = 0; i < 4; i++) {
          expect(await bob.receive(envelopes[i], from: 'u-alice'), '늦게 $i');
        }
        expect(bob.stored('skipped'), isNull, reason: '다 쓴 키는 지운다');
        // 이미 푼 글은 다시 풀지 않는다.
        expect(await bob.receive(envelopes[2], from: 'u-alice'), isNull);

        // 다시 켠 뒤에도.
        final more = [for (var i = 0; i < 5; i++) await alice.send('다시 늦게 $i')];
        expect(await bob.receive(more[4], from: 'u-alice'), '다시 늦게 4');
        bob = await bob.restart();
        for (final i in [1, 3, 0, 2]) {
          expect(
            await bob.receive(more[i], from: 'u-alice'),
            '다시 늦게 $i',
            reason: '다시 켠 뒤 $i번째',
          );
        }
        expect(bob.stored('skipped'), isNull);
        await _roundTrip(bob, alice, '늦은 글 뒤');
        await _roundTrip(alice, bob, '늦은 글 뒤 2');
      },
    );

    test(
      'v1: 가짜·변조된 봉투(큰 번호 포함)는 풀지 않고 체인을 밀지 않는다 — 그 뒤 진짜 글은 그대로 풀린다',
      () async {
        await _establish(alice, bob, 1);
        await _roundTrip(alice, bob, '처음');
        final real = await alice.send('진짜 글');
        final realJson = _decode(real);
        final n = realJson['n'] as int;
        final nonce = base64Encode(List<int>.filled(12, 1));
        final garbage = base64Encode(List<int>.filled(40, 2));
        final bad = <Object>[
          // 쓰레기 봉투 — 한계(2000) 안의 큰 번호라 키를 끝까지 감아 본다.
          {
            'v': 1,
            'epoch': 0,
            'n': n + 1500,
            'nonce': nonce,
            'ciphertext': garbage,
          },
          // 한계를 넘는 번호.
          {
            'v': 1,
            'epoch': 0,
            'n': n + crypto.v1MaxCatchUpSteps + 1,
            'nonce': nonce,
            'ciphertext': garbage,
          },
          // 진짜 봉투의 암호문·번호·epoch 변조.
          {
            ...realJson,
            'ciphertext': _flipFirstByte(realJson['ciphertext'] as String),
          },
          {...realJson, 'n': n + 1},
          {...realJson, 'epoch': 1},
          {...realJson, 'n': -1},
          {...realJson, 'n': '$n'},
          '봉투가 아님',
        ];
        final chainBefore = bob.stored('chain');
        for (final envelope in bad) {
          final text = envelope is String ? envelope : jsonEncode(envelope);
          expect(
            await bob.receive(text, from: 'u-alice'),
            isNull,
            reason: text,
          );
          expect(bob.stored('chain'), chainBefore, reason: '체인이 밀렸다: $text');
          expect(bob.stored('skipped'), isNull, reason: text);
        }
        expect(await bob.receive(real, from: 'u-alice'), '진짜 글');
        await _roundTrip(alice, bob, '그 뒤로도');
        await _roundTrip(bob, alice, '그 뒤로도 2');
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      'v1: 재키잉 없이 긴 대화 — 고정한 시드로 동시에 보내기·몰아서 보내기·순서 바뀜을 섞어 양쪽 160개씩 주고받아도 모두 '
      '풀리고 epoch는 그대로다',
      () async {
        await _establish(alice, bob, 1);
        final result = await _converse(
          alice,
          bob,
          perSide: 160,
          seed: 1337,
          reorder: true,
        );
        alice = result.alice;
        bob = result.bob;
        // 같은 번호로 거의 동시에 보낸 글·몰아 보낸 글·늦게 보낸 글이 먼저 간 경우를 실제로 거쳤다.
        expect(result.sameIndex, greaterThan(30));
        expect(result.maxBurst, greaterThanOrEqualTo(5));
        expect(result.outOfOrder, greaterThan(50));
        for (final device in [alice, bob]) {
          expect(_chainOf(device).epoch, 0, reason: device.userId);
          expect(device.stored('prevEpoch'), isNull, reason: device.userId);
          expect(device.stored('skipped'), isNull, reason: device.userId);
          expect(await device.protocol(), 1, reason: device.userId);
        }
        expect(_chainOf(alice).n, _chainOf(bob).n);
        expect(_chainOf(alice).n, greaterThan(160));
        await _roundTrip(alice, bob, '긴 대화 뒤');
        await _roundTrip(bob, alice, '긴 대화 뒤 답장');
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    test(
      'v1: 내 글·상대 글 가리기 — 나라는 봉투는 보낸 평문으로만, 상대 글을 나·다른 사람이 보냈다고 하면 풀지 않고, 보낸 사람이 '
      '없다는 내 봉투는 내 글로 보지 않는다',
      () async {
        await _establish(alice, bob, 1);
        final mine = await alice.send('내가 보낸 글');
        expect(await alice.receive(mine, from: 'u-alice'), '내가 보낸 글');
        expect(await alice.receive(mine, from: 'u-alice'), '내가 보낸 글');
        expect(await alice.receive(mine), isNull);
        final theirs = await bob.send('밥이 보낸 글');
        expect(await alice.receive(theirs, from: 'u-alice'), isNull);
        expect(await alice.receive(theirs, from: 'u-carol'), isNull);
        expect(await alice.receive(theirs), '밥이 보낸 글');
        expect(await alice.receive(theirs, from: 'u-bob'), isNull);
        expect(await bob.receive(mine, from: 'u-bob'), isNull);
        expect(await bob.receive(mine, from: 'u-carol'), isNull);
        expect(await bob.receive(mine, from: 'u-alice'), '내가 보낸 글');
        await _roundTrip(alice, bob, '이어서');
        await _roundTrip(bob, alice, '이어서 2');
      },
    );

    test(
      'v1: 서버가 내 봉투를 상대가 보낸 것으로 바꿔 붙여도 풀지 않는다(그 번호로 보낼 때 쓴 키를 내 봉투에는 쓰지 않는다) — '
      '같은 번호로 온 진짜 상대 글은 그 뒤에도, 그 전에 와도 풀린다',
      () async {
        await _establish(alice, bob, 1);
        // 바꿔 붙인 내 봉투가 먼저 오는 경우.
        final mine = await alice.send('앨리스가 보낸 글');
        final theirs = await bob.send('밥이 동시에 보낸 글');
        expect(_index(mine), _index(theirs));
        final relabeled = await alice.receive(mine, from: 'u-bob');
        final genuine = await alice.receive(theirs, from: 'u-bob');
        // (바꿔 붙인 내 봉투, 진짜 밥의 글) — 기대: (null, 밥의 글).
        expect(
          (relabeled, genuine),
          (null, '밥이 동시에 보낸 글'),
          reason: '바꿔 붙인 내 글이 상대 글로 보이거나, 진짜 상대 글을 풀지 못했다',
        );
        // 진짜 상대 글이 먼저 오는 경우.
        final mine2 = await bob.send('밥이 보낸 글');
        final theirs2 = await alice.send('앨리스가 동시에 보낸 글');
        expect(_index(mine2), _index(theirs2));
        expect(await bob.receive(theirs2, from: 'u-alice'), '앨리스가 동시에 보낸 글');
        expect(await bob.receive(mine2, from: 'u-alice'), isNull);
        // 보낸 사람이 없다는 내 봉투도 내 글로 보지 않는다(같은 번호로 보낼 때 쓴 내 키도 내 봉투에는 쓰지 않는다).
        expect(await bob.receive(mine2), isNull);
        expect(await bob.receive(mine2, from: 'u-bob'), '밥이 보낸 글');
        expect(await alice.receive(mine, from: 'u-alice'), '앨리스가 보낸 글');
        await _roundTrip(alice, bob, '이어서');
        await _roundTrip(bob, alice, '이어서 2');
      },
    );
  });

  group('뒷정리·깨진 상태', () {
    test(
      '예전 앱이 재키잉을 제안하며 남긴 임시 개인키는 앱을 켤 때(bootstrapBindings) 지운다 — 체인은 그대로 이어 간다',
      () async {
        await _establish(alice, bob, 1);
        await _roundTrip(alice, bob, '재키잉 제안 전');
        bob.keyStorage.data['secret/room-1/pendingRekeyEpoch'] = '1';
        bob.keyStorage.data['secret/room-1/pendingRekeySeed'] = base64Encode(
          List<int>.filled(32, 9),
        );
        // 세션이 없는 방에 하나만 남은 것도.
        bob.keyStorage.data['secret/room-2/pendingRekeySeed'] = base64Encode(
          List<int>.filled(32, 8),
        );
        final chainBefore = bob.stored('chain');
        expect(chainBefore, isNotNull);
        bob = await bob.restart();
        expect(
          await bob.manager.bootstrapBindings(['room-1', 'room-2']),
          isEmpty,
        );
        expect(bob.stored('pendingRekeyEpoch'), isNull);
        expect(bob.stored('pendingRekeySeed'), isNull);
        expect(bob.stored('pendingRekeySeed', roomId: 'room-2'), isNull);
        expect(bob.stored('chain'), chainBefore);
        expect(await bob.manager.isBlocked('room-1'), isFalse);
        await _roundTrip(alice, bob, '지운 뒤');
        await _roundTrip(bob, alice, '지운 뒤 답장');
      },
    );

    test('"예전 방식으로 맺은 대화" 안내를 닫으면 꺼지고, 앱을 다시 켜도 닫힌 채다(그 기기만)', () async {
      await _establish(alice, bob, 1);
      final before = await bob.manager.loadTrust('room-1');
      expect(before.legacyProtocol, isTrue);
      expect(before.showProtocolNotice, isTrue);
      final changed = <String>[];
      bob.manager.onTrustChanged = changed.add;
      await bob.manager.dismissProtocolNotice('room-1');
      expect(changed, contains('room-1'));
      final after = bob.manager.trustOf('room-1')!;
      expect(after.showProtocolNotice, isFalse);
      expect(after.legacyProtocol, isTrue);
      expect(after.security.protocolNoticeDismissed, isTrue);
      expect(after.security.legacyNoticeDismissed, isFalse);

      bob = await bob.restart();
      final reloaded = await bob.manager.loadTrust('room-1');
      expect(reloaded.showProtocolNotice, isFalse);
      expect(reloaded.legacyProtocol, isTrue);
      expect(reloaded.security.protocolNoticeDismissed, isTrue);
      // 앨리스 쪽 안내는 그대로(기기마다 따로 닫는다).
      expect(
        (await alice.manager.loadTrust('room-1')).showProtocolNotice,
        isTrue,
      );
      // 닫아도 대화는 그대로.
      await _roundTrip(alice, bob, '닫은 뒤');
      await _roundTrip(bob, alice, '닫은 뒤 답장');
    });

    test(
      '저장된 v3 래칫 상태가 깨지면(앱을 다시 켜 읽을 때) 보내기는 SecretChatBrokenException, 받기는 null이고 세션은 있는 '
      '것으로 둔다(다시 맺거나 예전 대화로 묶지 않게)',
      () async {
        await _handshake(alice, bob);
        await _roundTrip(alice, bob, '깨지기 전');
        final fromAlice = await alice.send('깨진 뒤 받을 글');
        final valid = _decode(bob.stored('ratchet')!);
        for (final broken in [
          '{깨진 JSON',
          jsonEncode([1, 2, 3]),
          jsonEncode({'v': 3, 'role': 'r'}),
          jsonEncode({...valid, 'rk': 'AAAA'}),
          jsonEncode({...valid, 'role': 'x'}),
          jsonEncode({...valid, 'v': 2}),
          jsonEncode({...valid, 'ns': '1'}),
        ]) {
          bob.keyStorage.data['secret/room-1/ratchet'] = broken;
          // 켜져 있는 동안은 처음 읽어 둔 상태를 그대로 쓴다(저장소를 메시지마다 다시 읽지 않는다) — 다시 켜야 읽는다.
          for (final device in [await bob.restart()]) {
            await expectLater(
              device.manager.encryptForRoom('room-1', '보내기'),
              throwsA(isA<SecretChatBrokenException>()),
              reason: broken,
            );
            expect(
              await device.receive(fromAlice, from: 'u-alice'),
              isNull,
              reason: broken,
            );
            expect(await device.manager.hasActiveSession('room-1'), isTrue);
            expect(await device.protocol(), 3);
            expect(device.stored('ratchet'), broken, reason: '깨진 값을 덮어썼다');
          }
        }
      },
    );

    for (final protocol in [3, 1]) {
      test(
        'v$protocol: 보안 확인에 실패해 멈춘 방 — 상대 글은 풀지 않고, 멈추기 전에 내가 보낸 글은 되돌아와도 보이며, 보내기는 '
        '막힌다',
        () async {
          await _establish(alice, bob, protocol);
          await _roundTrip(alice, bob, '멈추기 전');
          final mine = await bob.send('멈추기 전에 보낸 내 글');
          final theirs = await alice.send('멈추기 전에 앨리스가 보낸 글');
          final theirsLater = await alice.send('멈춘 뒤 받을 글');
          // 사용자가 "상대 기기 키 다시 받기"를 골랐다 — 그 키로 맺은 이 대화는 멈춘다.
          expect(
            await bob.manager.resetPeerDevicePin('room-1'),
            alice.deviceId,
          );
          expect(await bob.manager.isBlocked('room-1'), isTrue);
          final trust = bob.manager.trustOf('room-1')!;
          expect(trust.security.blockedReason, SecretBlockReason.keyReset);
          // 멈춘 방에는 "예전 방식" 안내 대신 멈춤 안내만 보인다.
          expect(trust.showProtocolNotice, isFalse);
          expect(await bob.receive(theirs, from: 'u-alice'), isNull);
          expect(await bob.receive(theirs), isNull);
          expect(await bob.receive(mine, from: 'u-bob'), '멈추기 전에 보낸 내 글');
          expect(await bob.receive(mine), isNull);
          await expectLater(
            bob.manager.encryptForRoom('room-1', '멈춘 뒤'),
            throwsA(isA<SecretChatBlockedException>()),
          );
          // 멈춘 대화의 세션 키는 지운다 — 되살릴 수 없는 대화라 쓸 일이 없다(기기가 털려도 그 대화를 풀 키가 없게).
          expect(await bob.manager.hasActiveSession('room-1'), isFalse);
          expect(bob.stored('ratchet'), isNull);
          expect(bob.stored('chain'), isNull);
          expect(bob.stored('skipped'), isNull);
          expect(bob.manager.trustOf('room-1')!.showProtocolNotice, isFalse);
          bob = await bob.restart();
          expect(await bob.manager.isBlocked('room-1'), isTrue);
          expect(await bob.receive(theirsLater, from: 'u-alice'), isNull);
        },
      );
    }

    test(
      'forgetRoom은 v3 래칫 상태(남겨 둔 키 포함)와 묶음·보안 상태, 보낸 글 평문까지 지운다 — 상대 기기 고정은 남긴다',
      () async {
        await _handshake(alice, bob);
        final envelopes = [
          for (var i = 0; i < 4; i++) await alice.send('지울 글 $i'),
        ];
        expect(await bob.receive(envelopes[3], from: 'u-alice'), '지울 글 3');
        expect(_ratchetOf(bob).skipped, hasLength(3));
        final mine = await bob.send('내 글');
        await bob.manager.forgetRoom('room-1');
        expect(
          bob.keyStorage.data.keys.where((k) => k.startsWith('secret/room-1/')),
          isEmpty,
        );
        expect(await bob.manager.hasActiveSession('room-1'), isFalse);
        expect(await bob.protocol(), isNull);
        expect(await bob.manager.encryptForRoom('room-1', '지운 뒤'), isNull);
        expect(await bob.receive(envelopes[0], from: 'u-alice'), isNull);
        expect(await bob.receive(mine, from: 'u-bob'), isNull);
        expect(await bob.receive(mine), isNull);
        expect(await bob.store.readDevicePin(alice.deviceId), isNotNull);
      },
    );

    test(
      'v1: clearSessionKeys·forgetRoom은 체인과 늦게 올 글을 위해 남겨 둔 키(skipped)까지 지운다',
      () async {
        await _establish(alice, bob, 1);
        // 양쪽 모두 남겨 둔 키가 생기게 — 마지막 글을 먼저 받는다.
        final fromAlice = [
          for (var i = 0; i < 5; i++) await alice.send('앨리스 $i'),
        ];
        expect(await bob.receive(fromAlice[4], from: 'u-alice'), '앨리스 4');
        final fromBob = [for (var i = 0; i < 3; i++) await bob.send('밥 $i')];
        expect(await alice.receive(fromBob[2], from: 'u-bob'), '밥 2');
        expect(bob.stored('skipped'), isNotNull);
        expect(alice.stored('skipped'), isNotNull);

        await bob.store.clearSessionKeys('room-1');
        for (final field in [
          'skipped',
          'chainKey',
          'epoch',
          'n',
          'peer',
          'security',
        ]) {
          expect(bob.stored(field), isNull, reason: '밥: $field');
        }
        expect(await bob.store.hasSession('room-1'), isFalse);
        bob = await bob.restart();
        expect(await bob.receive(fromAlice[0], from: 'u-alice'), isNull);

        await alice.manager.forgetRoom('room-1');
        expect(
          alice.keyStorage.data.keys.where(
            (k) => k.startsWith('secret/room-1/'),
          ),
          isEmpty,
        );
        expect(await alice.manager.hasActiveSession('room-1'), isFalse);
      },
    );

    test(
      '서버가 수락을 받지 않으면(내 다른 기기가 먼저 수락함) 이 기기에 적은 v3 래칫 상태와 묶음을 되돌린다',
      () async {
        final invite = await _start(alice, 'u-bob');
        bob.rooms['room-1'] = Room.fromJson(
          _roomJson('room-1', status: 'pending'),
        );
        server.acceptStatus = 409;
        await expectLater(
          bob.manager.acceptInvite(invite),
          throwsA(isA<SecretChatRefusedException>()),
        );
        expect(bob.stored('ratchet'), isNull);
        expect(bob.stored('peer'), isNull);
        expect(await bob.manager.hasActiveSession('room-1'), isFalse);
        expect(await bob.manager.encryptForRoom('room-1', '보내기'), isNull);
      },
    );
  });

  group('내 다른 기기가 수락한 대화', () {
    test(
      '내 다른 기기가 수락했다는 알림(secret:accepted)을 받으면, 응답을 못 받아 이 기기에 남은 v3 래칫 상태를 치운다 — '
      '수락한 기기의 대화는 그대로',
      () async {
        final tablet = await _Device.open('u-bob', server);
        final invite = await _start(alice, 'u-bob');
        for (final device in [bob, tablet]) {
          device.rooms['room-1'] = Room.fromJson(
            _roomJson('room-1', status: 'pending'),
          );
        }
        // 태블릿의 수락은 응답을 못 받았다(서버 오류) — 처리됐을 수 있어 키를 남겨 둔다.
        server.acceptStatus = 500;
        await expectLater(
          tablet.manager.acceptInvite(invite),
          throwsA(isA<ApiException>()),
        );
        expect(tablet.stored('ratchet'), isNotNull);
        // 실제로는 밥의 다른 기기가 수락했다.
        server.acceptStatus = 200;
        expect(
          await bob.manager.acceptInvite(invite),
          SecretHandshakeOutcome.established,
        );
        final accepted = _accepted(bob, 'room-1');
        expect(
          await alice.manager.handleAccepted(accepted),
          SecretHandshakeOutcome.established,
        );
        expect(
          await tablet.manager.handleAccepted(accepted),
          SecretHandshakeOutcome.ignored,
        );
        expect(tablet.stored('ratchet'), isNull);
        expect(await tablet.manager.hasActiveSession('room-1'), isFalse);
        expect(
          await bob.manager.handleAccepted(accepted),
          SecretHandshakeOutcome.ignored,
        );
        expect(await bob.protocol(), 3);
        await _roundTrip(alice, bob, '수락한 기기와는 그대로');
        await _roundTrip(bob, alice, '수락한 기기와는 그대로 2');
      },
    );

    test(
      '앱을 켤 때 방 정보상 내 다른 기기가 수락한 대화면, 이 기기에 남은 v3 래칫 상태(응답을 못 받은 수락)를 치운다',
      () async {
        final tablet = await _Device.open('u-bob', server);
        final invite = await _start(alice, 'u-bob');
        tablet.rooms['room-1'] = Room.fromJson(
          _roomJson('room-1', status: 'pending'),
        );
        server.acceptStatus = 500;
        await expectLater(
          tablet.manager.acceptInvite(invite),
          throwsA(isA<ApiException>()),
        );
        expect(tablet.stored('ratchet'), isNotNull);
        // 다시 켰더니 방 정보에는 밥의 다른 기기가 수락한 것으로 나온다.
        tablet.rooms['room-1'] = Room.fromJson(
          _roomJson(
            'room-1',
            initiatorDevice: alice.deviceId,
            responder: 'u-bob',
            responderDevice: bob.deviceId,
          ),
        );
        final restarted = await tablet.restart();
        expect(await restarted.manager.bootstrapBindings(['room-1']), isEmpty);
        expect(restarted.stored('ratchet'), isNull);
        expect(await restarted.manager.hasActiveSession('room-1'), isFalse);
      },
    );
  });

  group('같은 초대가 다시 올 때', () {
    // 이미 맺은 방에 같은 초대(secret:invite)가 다시 와서 사용자가 또 수락하는 경우 — 서버가 다시 보내거나, 수락이
    // 서버에 닿기 전에 방 목록을 다시 받아(ensurePendingSecretInvite) 같은 초대 창이 한 번 더 뜬 경우. 서버가 받았다고 답한
    // 수락이면 다시 수락하지 않는다(지금 세션을 덮어쓰고, 서버의 409에 세션까지 지워진다).

    test(
      '이미 v3로 맺은 방에 규약 표시가 빠진 같은 초대를 다시 수락해도 아무것도 하지 않는다 — v1 체인이 생기지 않고, 다시 켜도 v3 '
      '그대로 이어진다',
      () async {
        final invite = await _handshake(alice, bob);
        await _roundTrip(alice, bob, '처음');
        final replay = SecretInviteEvent(
          roomId: invite.roomId,
          initiatorUserId: invite.initiatorUserId,
          initiatorDeviceId: invite.initiatorDeviceId,
          initiatorEphemeralPublicKey: invite.initiatorEphemeralPublicKey,
          initiatorEphemeralSignature: invite.initiatorEphemeralSignature,
          initiatorContextSignature: invite.initiatorContextSignature,
        );
        final acceptsBefore = server.acceptCalls;
        expect(
          await bob.manager.acceptInvite(replay),
          SecretHandshakeOutcome.ignored,
        );
        expect(server.acceptCalls, acceptsBefore, reason: '서버에 다시 수락하지 않는다');
        expect(bob.stored('chain'), isNull);
        expect(await bob.protocol(), 3);
        await _roundTrip(alice, bob, '다시 온 초대 뒤');
        await _roundTrip(bob, alice, '다시 온 초대 뒤 답장');
        bob = await bob.restart();
        expect(await bob.protocol(), 3);
        await _roundTrip(alice, bob, '다시 켠 뒤');
        await _roundTrip(bob, alice, '다시 켠 뒤 답장');
      },
    );

    test(
      '이미 맺은 방에 같은 초대가 다시 와도 서버에 다시 수락하지 않아(서버라면 409) 맺어 둔 세션이 그대로다',
      () async {
        final invite = await _handshake(alice, bob);
        await _roundTrip(alice, bob, '처음');
        server.acceptStatus = 409;
        expect(
          await bob.manager.acceptInvite(invite),
          SecretHandshakeOutcome.ignored,
        );
        final fromAlice = await alice.send('다시 온 초대 뒤 앨리스 글');
        expect(await bob.manager.hasActiveSession('room-1'), isTrue);
        expect(
          await bob.receive(fromAlice, from: 'u-alice'),
          '다시 온 초대 뒤 앨리스 글',
        );
        expect(await bob.manager.hasEstablishedSession('room-1'), isTrue);
      },
    );

    test(
      '서버의 답을 못 받은 수락(그 사이 끊김)은 같은 초대로 다시 수락할 수 있다 — 예전 키(다른 규약 칸까지)를 비우고 새로 맺는다',
      () async {
        final invite = await _start(alice, bob.userId);
        bob.rooms['room-1'] = Room.fromJson(
          _roomJson('room-1', status: 'pending'),
        );
        server.acceptStatus = 500;
        await expectLater(
          bob.manager.acceptInvite(invite),
          throwsA(isA<ApiException>()),
        );
        expect(await bob.manager.hasActiveSession('room-1'), isTrue);
        expect(await bob.manager.hasEstablishedSession('room-1'), isFalse);
        expect(bob.stored('acceptPending'), isNotNull);
        final firstRatchet = bob.stored('ratchet');
        // 다시 수락 — 이번에는 서버가 받는다. 규약 표시가 빠진 초대여도 예전 v3 칸을 비우고 v1로 새로 맺는다.
        server.acceptStatus = 200;
        final replay = SecretInviteEvent(
          roomId: invite.roomId,
          initiatorUserId: invite.initiatorUserId,
          initiatorDeviceId: invite.initiatorDeviceId,
          initiatorEphemeralPublicKey: invite.initiatorEphemeralPublicKey,
          initiatorEphemeralSignature: invite.initiatorEphemeralSignature,
          initiatorContextSignature: invite.initiatorContextSignature,
        );
        expect(
          await bob.manager.acceptInvite(replay),
          SecretHandshakeOutcome.established,
        );
        expect(bob.stored('acceptPending'), isNull);
        expect(bob.stored('ratchet'), isNull, reason: '예전 v3 칸이 남았다');
        expect(firstRatchet, isNotNull);
        expect(await bob.protocol(), 1);
        expect(await bob.manager.hasEstablishedSession('room-1'), isTrue);
        expect(
          await alice.manager.handleAccepted(_accepted(bob, 'room-1')),
          SecretHandshakeOutcome.established,
        );
        expect(await alice.protocol(), 1);
        await _roundTrip(alice, bob, '다시 수락한 뒤');
        await _roundTrip(bob, alice, '다시 수락한 뒤 답장');
      },
    );
  });
  group('놓친 수락 다시 받기', () {
    // 초대해 두고 앱을 끈 사이 상대가 수락하면 secret:accepted는 그 순간 연결된 기기에만 가서 초대한 기기는 받지 못한다 —
    // 예전에는 그 대화를 영영 쓰지 못했다. 앱을 켤 때(bootstrapBindings)·보내려 할 때 서버에 다시 물어 맺는다.
    Future<void> inviteWhileOffline() async {
      final invite = await _start(alice, bob.userId);
      bob.rooms['room-1'] = Room.fromJson(
        _roomJson('room-1', status: 'pending'),
      );
      expect(
        await bob.manager.acceptInvite(invite),
        SecretHandshakeOutcome.established,
      );
      server.acceptedUser['room-1'] = bob.userId;
      // 다시 켠 앨리스의 방 목록에는 수락된 것으로 나온다(secret:accepted는 놓쳤다).
      alice = await alice.restart();
      alice.rooms['room-1'] = Room.fromJson(
        _roomJson(
          'room-1',
          initiatorDevice: alice.deviceId,
          responder: 'u-bob',
          responderDevice: bob.deviceId,
        ),
      );
      expect(await alice.manager.hasActiveSession('room-1'), isFalse);
    }

    test(
      '앱을 켤 때 내가 건 대화의 놓친 수락을 서버에 다시 물어 맺는다 — 소켓으로 받은 것과 똑같이 확인한다',
      () async {
        await inviteWhileOffline();
        expect(await alice.manager.bootstrapBindings(['room-1']), isEmpty);
        expect(await alice.protocol(), 3);
        expect(alice.stored('pendingEphemeralSeed'), isNull);
        await _roundTrip(alice, bob, '놓친 수락 뒤');
        await _roundTrip(bob, alice, '놓친 수락 뒤 답장');
        // 이미 맺었으면 다시 묻지 않는다.
        expect(await alice.manager.recoverMissedAcceptance('room-1'), isNull);
      },
    );

    test(
      '아직 수락되지 않았거나(서버 404), 내가 건 대화가 아니거나, 방이 pending이면 아무것도 하지 않는다',
      () async {
        final invite = await _start(alice, bob.userId);
        // 방 목록이 아직 pending — 묻지 않는다.
        expect(await alice.manager.recoverMissedAcceptance('room-1'), isNull);
        alice.rooms['room-1'] = Room.fromJson(_roomJson('room-1'));
        // active라고 나오지만 서버는 아직 수락이 없다고 한다.
        expect(await alice.manager.recoverMissedAcceptance('room-1'), isNull);
        expect(await alice.manager.hasActiveSession('room-1'), isFalse);
        // 밥 쪽(초대받은 사람)에서는 묻지 않는다.
        bob.rooms['room-1'] = Room.fromJson(_roomJson('room-1'));
        expect(await bob.manager.recoverMissedAcceptance('room-1'), isNull);
        expect(invite.initiatorUserId, 'u-alice');
      },
    );

    test('서버가 다시 준 수락의 서명을 바꿔 붙이면 소켓으로 받은 것처럼 멈춘다', () async {
      await inviteWhileOffline();
      final mallory = await Ed25519().newKeyPair();
      // 서버(또는 공격자)가 자기 키로 서명한 값을 끼워 넣는다 — 고정해 둔 밥의 기기 키로는 맞지 않는다.
      final forged = await crypto.signContext(
        mallory,
        'tangotalk-secret-v3|accept|forged',
      );
      server.acceptedRelay = (payload) => {
        ...payload,
        'responderContextSignature': forged,
        'responderEphemeralSignature': forged,
      };
      expect(
        await alice.manager.recoverMissedAcceptance('room-1'),
        SecretHandshakeOutcome.blocked,
      );
      expect(await alice.manager.isBlocked('room-1'), isTrue);
      expect(await alice.manager.hasActiveSession('room-1'), isFalse);
    });
  });

  group('이번 보완(서버가 바꿔 붙인 값·로그아웃·한 번만 하는 정리)', () {
    test(
      'v1: 서버가 내 봉투의 nonce·암호문을 같은 바이트의 다른 글자(URL 안전 글자 등)로 바꿔 상대가 보낸 것처럼 붙여도 풀지 않는다 '
      '— 같은 번호로 동시에 보낼 때 쓴 내 키로 풀려 내 글이 상대 글로 보이지 않게',
      () async {
        await _establish(alice, bob, 1);
        // 같은 번호로 동시에 보내 앨리스가 그 번호의 키를 들고 있게 한다.
        final mine = await alice.send('앨리스 비밀');
        final theirs = await bob.send('밥 글');
        expect(_index(mine), _index(theirs));
        final json = _decode(mine);
        String variant(String v) =>
            base64Url.encode(base64Decode(v)).replaceAll('=', '');
        for (final field in ['nonce', 'ciphertext']) {
          final changed = variant(json[field] as String);
          if (changed == json[field]) continue;
          expect(
            await alice.receive(
              jsonEncode({...json, field: changed}),
              from: 'u-bob',
            ),
            isNull,
            reason: field,
          );
        }
        // 진짜 상대 글은 그대로 풀린다.
        expect(await alice.receive(theirs, from: 'u-bob'), '밥 글');
      },
    );

    test(
      '로그아웃해 버린 매니저는 키 상태를 저장하지 않는다 — 새 매니저가 같은 방의 상태를 읽어 쓰는데 되돌리지 않게',
      () async {
        await _handshake(alice, bob);
        await _roundTrip(alice, bob, '버리기 전');
        final before = alice.stored('ratchet');
        alice.manager.dispose();
        await expectLater(
          alice.manager.encryptForRoom('room-1', '버린 뒤'),
          throwsA(isA<StateError>()),
        );
        expect(alice.stored('ratchet'), before);
        // 새로 켠 매니저로는 그대로 이어 간다.
        alice = await alice.restart();
        await _roundTrip(alice, bob, '새 매니저');
        await _roundTrip(bob, alice, '새 매니저 답장');
      },
    );

    test(
      '예전 재키잉 임시키 정리는 계정마다 한 번만 한다 — 다 치우면 표시를 남기고, 그 뒤 켤 때는 다시 읽지 않는다',
      () async {
        await _establish(alice, bob, 1);
        bob.keyStorage.data['secret/room-1/pendingRekeySeed'] = base64Encode(
          List<int>.filled(32, 9),
        );
        bob = await bob.restart();
        expect(await bob.manager.bootstrapBindings(['room-1']), isEmpty);
        expect(bob.stored('pendingRekeySeed'), isNull);
        expect(
          bob.keyStorage.data.keys.where((k) => k.startsWith('secretmeta/')),
          ['secretmeta/rekey-cleanup-v3/u-bob'],
        );
        // 새 앱은 재키잉 임시키를 만들지 않는다 — 다시 켜서는 찾지 않는다(남아 있어도 쓰이지 않는다).
        bob.keyStorage.data['secret/room-1/pendingRekeySeed'] = base64Encode(
          List<int>.filled(32, 8),
        );
        bob = await bob.restart();
        expect(await bob.manager.bootstrapBindings(['room-1']), isEmpty);
        expect(bob.stored('pendingRekeySeed'), isNotNull);
        await _roundTrip(alice, bob, '정리 뒤');
      },
    );

    test(
      '세션을 만든 뒤 지우지 못한(그 사이 꺼짐) 초대 임시키는 앱을 켤 때 지운다 — 그 키로 첫 루트키를 다시 만들 수 있다',
      () async {
        await _handshake(alice, bob);
        alice.keyStorage.data['secret/room-1/pendingEphemeralSeed'] =
            base64Encode(List<int>.filled(32, 3));
        alice = await alice.restart();
        alice.rooms['room-1'] = Room.fromJson(
          _roomJson(
            'room-1',
            initiatorDevice: alice.deviceId,
            responder: 'u-bob',
            responderDevice: bob.deviceId,
          ),
        );
        expect(await alice.manager.bootstrapBindings(['room-1']), isEmpty);
        expect(alice.stored('pendingEphemeralSeed'), isNull);
        await _roundTrip(alice, bob, '지운 뒤');
      },
    );
  });

  group('글의 자리 묶음·규약 낮추기 막기·로그아웃 중 핸드셰이크', () {
    Future<String?> receiveAt(
      _Device device,
      String envelope,
      SecretTextSlot slot, {
      String from = 'u-alice',
    }) => device.manager.decryptForRoom(
      'room-1',
      envelope,
      senderUserId: from,
      slot: slot,
    );

    Future<String> sendAt(
      _Device device,
      String text,
      SecretTextPlace place,
    ) async =>
        (await device.manager.encryptForRoom('room-1', text, place: place))!;

    test(
      'v3: 서버가 글을 다른 자리로 옮겨 붙이면(댓글을 다른 글 아래로·메시지를 댓글로·다른 글의 수정으로) 풀지 않고, 제자리로 오면 '
      '풀린다 — 되돌아온 내 글도 놓은 자리가 아니면 보낸 평문을 주지 않는다',
      () async {
        await _establish(alice, bob, 3);
        final comment = await sendAt(
          alice,
          '댓글',
          const SecretTextPlace.comment(parentId: 'm1'),
        );
        expect(
          await receiveAt(
            bob,
            comment,
            const SecretTextSlot.comment('c1', 'm2'),
          ),
          isNull,
          reason: '다른 글 아래로 옮김',
        );
        expect(
          await receiveAt(bob, comment, const SecretTextSlot.message('c1')),
          isNull,
          reason: '댓글을 메시지로',
        );
        // 키 상태는 그대로라 제자리로 오면 풀린다.
        expect(
          await receiveAt(
            bob,
            comment,
            const SecretTextSlot.comment('c1', 'm1'),
          ),
          '댓글',
        );

        final message = await sendAt(
          alice,
          '메시지',
          const SecretTextPlace.message(),
        );
        expect(
          await receiveAt(
            bob,
            message,
            const SecretTextSlot.comment('c2', 'm1'),
          ),
          isNull,
          reason: '메시지를 댓글로',
        );
        expect(
          await receiveAt(bob, message, const SecretTextSlot.message('m3')),
          '메시지',
        );

        final edit = await sendAt(
          alice,
          '고친 글',
          const SecretTextPlace.message(editOf: 'm1'),
        );
        expect(
          await receiveAt(bob, edit, const SecretTextSlot.message('m3')),
          isNull,
          reason: 'm1의 수정을 m3의 수정으로',
        );
        expect(
          await receiveAt(bob, edit, const SecretTextSlot.message('m1')),
          '고친 글',
        );

        // 댓글 수정은 원본 메시지를 몰라도(parentId 없이) 그 댓글 자리면 풀린다.
        final commentEdit = await sendAt(
          alice,
          '고친 댓글',
          const SecretTextPlace.comment(editOf: 'c1'),
        );
        expect(
          await receiveAt(
            bob,
            commentEdit,
            const SecretTextSlot.comment('c9', 'm1'),
          ),
          isNull,
        );
        expect(
          await receiveAt(
            bob,
            commentEdit,
            const SecretTextSlot.comment('c1', 'm1'),
          ),
          '고친 댓글',
        );

        // 되돌아온 내 글 — 보낼 때 놓은 자리가 아니면 주지 않고, 제자리면 준다.
        final mine = await sendAt(
          bob,
          '밥의 댓글',
          const SecretTextPlace.comment(parentId: 'm1'),
        );
        expect(
          await receiveAt(
            bob,
            mine,
            const SecretTextSlot.comment('c5', 'm2'),
            from: 'u-bob',
          ),
          isNull,
        );
        expect(
          await receiveAt(
            bob,
            mine,
            const SecretTextSlot.comment('c5', 'm1'),
            from: 'u-bob',
          ),
          '밥의 댓글',
        );
        expect(
          await receiveAt(
            alice,
            mine,
            const SecretTextSlot.comment('c5', 'm1'),
            from: 'u-bob',
          ),
          '밥의 댓글',
        );
      },
    );

    test(
      'v1: 예전 규약은 자리를 암호문에 넣지 않는다(예전 앱이 읽어야 한다) — 평문 그대로 보내고, 자리와 상관없이 풀린다',
      () async {
        await _establish(alice, bob, 1);
        final comment = await sendAt(
          alice,
          '댓글',
          const SecretTextPlace.comment(parentId: 'm1'),
        );
        expect(
          await receiveAt(bob, comment, const SecretTextSlot.message('x')),
          '댓글',
        );
      },
    );

    test('규약 낮추기 — 새 규약으로 말하는 것을 확인한 상대 기기가 예전 규약 초대를 보냈다고 오면(서버가 규약 표시를 뺌) 밥은 '
        '수락하지 않고 멈춘다 — "상대 기기 키 다시 받기"로 풀 수 있고, 원래 대화는 그대로다', () async {
      await _establish(alice, bob, 3);
      // 밥이 앨리스의 v3 글을 풀어 그 기기가 새 규약으로 말하는 것을 확인했다.
      await _roundTrip(alice, bob, 'v3 글');
      expect((await bob.store.readDevicePin(alice.deviceId))!.speaksV3, isTrue);
      final invite = await _start(
        alice,
        bob.userId,
        roomId: 'room-2',
        relay: _without('initiatorProtocol'),
      );
      bob.rooms['room-2'] = Room.fromJson(
        _roomJson('room-2', status: 'pending'),
      );
      expect(
        await bob.manager.acceptInvite(invite),
        SecretHandshakeOutcome.blocked,
      );
      final trust = await bob.manager.loadTrust('room-2');
      expect(trust.security.blockedReason, SecretBlockReason.downgrade);
      expect(trust.resetDeviceId, alice.deviceId);
      expect(await bob.protocol('room-2'), isNull);
      expect(server.accepted['room-2'], isNull, reason: '수락을 보내지 않았다');
      await _roundTrip(alice, bob, '원래 대화');
      await _roundTrip(bob, alice, '원래 대화 답장');
    });

    test('규약 낮추기 — 앨리스가 v3를 제안했는데 새 규약으로 수락했던 밥의 기기가 예전 규약으로 수락했다고 오면 앨리스는 맺지 '
        '않고 멈춘다 — 상대 기기 키를 다시 받으면 그 표시도 지워져 예전 방식 대화를 다시 맺을 수 있다', () async {
      await _establish(alice, bob, 3);
      // 앨리스는 밥 기기의 v3 수락 서명을 확인했다.
      expect((await alice.store.readDevicePin(bob.deviceId))!.speaksV3, isTrue);
      // 밥은 아직 앨리스의 v3 글을 받지 않아 낮춘 초대를 알아채지 못하고 v2로 수락한다.
      final invite = await _start(
        alice,
        bob.userId,
        roomId: 'room-2',
        relay: _without('initiatorProtocol'),
      );
      bob.rooms['room-2'] = Room.fromJson(
        _roomJson('room-2', status: 'pending'),
      );
      expect(
        await bob.manager.acceptInvite(invite),
        SecretHandshakeOutcome.established,
      );
      expect(
        await alice.manager.handleAccepted(_accepted(bob, 'room-2')),
        SecretHandshakeOutcome.blocked,
      );
      final trust = await alice.manager.loadTrust('room-2');
      expect(trust.security.blockedReason, SecretBlockReason.downgrade);
      expect(await alice.protocol('room-2'), isNull);
      expect(alice.stored('pendingEphemeralSeed', roomId: 'room-2'), isNull);

      expect(await alice.manager.resetPeerDevicePin('room-2'), bob.deviceId);
      await _handshake(
        alice,
        bob,
        roomId: 'room-3',
        inviteRelay: _without('initiatorProtocol'),
      );
      expect(await alice.protocol('room-3'), 1);
      expect(
        (await alice.store.readDevicePin(bob.deviceId))!.speaksV3,
        isFalse,
      );
      await _roundTrip(alice, bob, '다시 받은 뒤', roomId: 'room-3');
    });

    test(
      '업데이트 전에 걸어 둔 초대(새 규약을 알리지 않음)는 상대 기기가 새 규약으로 말해도 예전 규약으로 맺는다 — 낮춘 것이 아니다',
      () async {
        await _establish(alice, bob, 3);
        expect(
          (await alice.store.readDevicePin(bob.deviceId))!.speaksV3,
          isTrue,
        );
        final invite = await _start(
          alice,
          bob.userId,
          roomId: 'room-2',
          relay: _without('initiatorProtocol'),
        );
        // 업데이트 전 앱이 남긴 대기 정보에는 실어 보낸 규약 번호가 없다.
        final pendingKey = 'secret/room-2/pendingInit';
        final pending =
            jsonDecode(alice.keyStorage.data[pendingKey]!)
                as Map<String, dynamic>;
        alice.keyStorage.data[pendingKey] = jsonEncode(
          Map.of(pending)..remove('p'),
        );
        alice = await alice.restart();
        bob.rooms['room-2'] = Room.fromJson(
          _roomJson('room-2', status: 'pending'),
        );
        expect(
          await bob.manager.acceptInvite(invite),
          SecretHandshakeOutcome.established,
        );
        expect(
          await alice.manager.handleAccepted(_accepted(bob, 'room-2')),
          SecretHandshakeOutcome.established,
        );
        expect(await alice.protocol('room-2'), 1);
        await _roundTrip(alice, bob, '업데이트 전 초대', roomId: 'room-2');
      },
    );

    test(
      '로그아웃해 버린 매니저는 서버에 묻던 초대 수락을 이어 가지 않는다 — 수락을 보내거나 키·묶음·고정을 적지 않고, 새 매니저가 '
      '같은 초대를 처음부터 처리한다',
      () async {
        final invite = await _start(alice, bob.userId);
        bob.rooms['room-1'] = Room.fromJson(
          _roomJson('room-1', status: 'pending'),
        );
        server
          ..holdKeyLookup = Completer<void>()
          ..keyLookupArrived = Completer<void>();
        final accepting = bob.manager.acceptInvite(invite);
        await server.keyLookupArrived!.future;
        bob.manager.dispose();
        server.holdKeyLookup!.complete();
        await expectLater(accepting, throwsA(isA<StateError>()));
        expect(server.acceptCalls, 0);
        expect(await bob.protocol(), isNull);
        expect(bob.stored('peer'), isNull);
        expect(bob.stored('acceptPending'), isNull);
        expect(await bob.store.readDevicePin(alice.deviceId), isNull);

        server.holdKeyLookup = null;
        bob = await bob.restart();
        expect(
          await bob.manager.acceptInvite(invite),
          SecretHandshakeOutcome.established,
        );
        expect(
          await alice.manager.handleAccepted(_accepted(bob, 'room-1')),
          SecretHandshakeOutcome.established,
        );
        await _roundTrip(alice, bob, '다시 로그인한 뒤');
      },
    );

    test(
      '로그아웃해 버린 매니저는 서버에 묻던 수락 확인을 이어 가지 않는다 — 세션을 적거나 초대 임시키를 지우지 않아 새 매니저가 맺는다',
      () async {
        final invite = await _start(alice, bob.userId);
        bob.rooms['room-1'] = Room.fromJson(
          _roomJson('room-1', status: 'pending'),
        );
        expect(
          await bob.manager.acceptInvite(invite),
          SecretHandshakeOutcome.established,
        );
        server
          ..holdKeyLookup = Completer<void>()
          ..keyLookupArrived = Completer<void>();
        final handling = alice.manager.handleAccepted(_accepted(bob, 'room-1'));
        await server.keyLookupArrived!.future;
        alice.manager.dispose();
        server.holdKeyLookup!.complete();
        await expectLater(handling, throwsA(isA<StateError>()));
        expect(await alice.protocol(), isNull);
        expect(alice.stored('pendingEphemeralSeed'), isNotNull);
        expect(alice.stored('peer'), isNull);

        server.holdKeyLookup = null;
        alice = await alice.restart();
        expect(
          await alice.manager.handleAccepted(_accepted(bob, 'room-1')),
          SecretHandshakeOutcome.established,
        );
        await _roundTrip(alice, bob, '다시 로그인한 뒤');
        await _roundTrip(bob, alice, '다시 로그인한 뒤 답장');
      },
    );
  });
}
