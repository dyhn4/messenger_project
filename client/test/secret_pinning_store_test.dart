import 'dart:convert';

import 'package:client/models/message.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/device_identity.dart';
import 'package:client/services/secret_key_store.dart';
import 'package:client/services/secret_peer_store.dart';
import 'package:client/services/secret_ratchet.dart';
import 'package:client/services/secret_session_manager.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

/// 비밀 대화 상대 기기 고정(S5)의 저장 — 기기 고정·방 묶음·보안 상태가 다시 켜도 남는지, 방을 잊으면 방의 것만
/// 지워지고 기기 고정은 남는지, 평문 캐시 정리(번들 3의 색인·만료·재조정)가 기기 고정을 건드리지 않는지 본다.
/// 새 규약(v3)의 저장 — 래칫 상태·예전 규약에서 남겨 둔 메시지 키·세션의 규약·"예전 방식 대화" 안내를 닫은 표시·
/// 초대에 실어 보낸 규약 번호, 예전 재키잉 임시키 정리도 본다.

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

/// 쓰기·지우기를 차례대로 적어 두는 메모리 저장소 — 할 일이 없을 때 저장소에 손대지 않는지, 어떤 순서로 적는지 본다
/// (Windows 구현은 쓰기·지우기마다 파일 전체를 다시 쓴다).
class _RecordingStorage extends _MemoryStorage {
  final List<String> mutations = [];

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
  }) {
    mutations.add('write $key');
    return super.write(key: key, value: value);
  }

  @override
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) {
    mutations.add('delete $key');
    return super.delete(key: key);
  }
}

/// [failDeleteOf] 키를 지우려 하면 실패하는 저장소(저장소 오류 흉내).
class _FailingDeleteStorage extends _RecordingStorage {
  String? failDeleteOf;

  @override
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (key == failDeleteOf) throw Exception('저장소 오류');
    await super.delete(key: key);
  }
}

DateTime _at(int ms) => DateTime.fromMillisecondsSinceEpoch(ms);

/// 예전 규약(v1) 방의 체인 상태.
SecretChainState _v1Chain({int n = 0}) =>
    SecretChainState(epoch: 0, n: n, chainKey: List.filled(32, 1 + n));

/// 새 규약(v3) 방의 래칫 상태 — 수락한 쪽이 막 맺은 것.
Future<SecretRatchetState> _v3Ratchet() async =>
    SecretRatchetState.forResponder(
      rootKey: List.filled(32, 2),
      myEphemeralKeyPair: await X25519().newKeyPair(),
    );

/// 늦게 올 메시지를 위해 남겨 둔 메시지 키 하나.
SecretSkippedKey _skipped(String chain, int n) =>
    SecretSkippedKey(chain, n, List.filled(32, n + 1));

/// 남겨 둔 키들을 견주기 쉬운 모양으로.
List<List<Object>> _plain(List<SecretSkippedKey> keys) => [
  for (final k in keys) [k.chain, k.n, k.key],
];

SecretDevicePin _pin(String userId, {String key = 'S0VZ'}) => SecretDevicePin(
  userId: userId,
  signingPublicKey: key,
  firstSeenAt: _at(1000),
);

const _binding = SecretRoomBinding(
  peerUserId: 'u-alice',
  peerDeviceId: 'd-alice',
  myDeviceId: 'd-bob',
);

void main() {
  late _RecordingStorage storage;
  late SecretKeyStore store;

  setUp(() {
    storage = _RecordingStorage();
    store = SecretKeyStore(storage: storage);
  });

  tearDown(() => store.dispose());

  test('기기 고정·방 묶음·보안 상태·대기 중인 초대 정보는 저장소에 남아 앱을 다시 켜도 그대로다', () async {
    await store.saveDevicePin('d-alice', _pin('u-alice', key: 'QUxJQ0U='));
    await store.saveRoomBinding('r1', _binding);
    await store.saveRoomSecurity(
      'r1',
      const SecretRoomSecurity(legacyPeer: true, peerDeviceChanged: true),
    );
    await store.savePendingEphemeralSeed(
      'r2',
      [1, 2, 3],
      targetUserId: 'u-carol',
      myDeviceId: 'd-bob',
    );

    final restarted = SecretKeyStore(storage: storage);
    addTearDown(restarted.dispose);
    final pin = await restarted.readDevicePin('d-alice');
    expect(pin?.userId, 'u-alice');
    expect(pin?.signingPublicKey, 'QUxJQ0U=');
    expect(pin?.firstSeenAt, _at(1000));
    expect(await restarted.readRoomBinding('r1'), _binding);
    final security = await restarted.readRoomSecurity('r1');
    expect(security.legacyPeer, isTrue);
    expect(security.peerDeviceChanged, isTrue);
    expect(security.blocked, isFalse);
    final pending = await restarted.readPendingInit('r2');
    expect(pending.targetUserId, 'u-carol');
    expect(pending.myDeviceId, 'd-bob');
    expect(await restarted.readPendingEphemeralSeed('r2'), [1, 2, 3]);
    // 기기 고정은 방별 키(secret/<방>/…)가 아니라 따로 둔다.
    expect(storage.data.keys, contains('secretpin/d-alice'));
    expect(storage.data['secret/r1/peer'], isNotNull);
  });

  test('방을 잊으면(clearRoom) 그 방의 묶음·보안 상태·대기 정보는 지우고 기기 고정은 남긴다', () async {
    await store.saveDevicePin('d-alice', _pin('u-alice'));
    await store.saveRoomBinding('r1', _binding);
    await store.saveRoomSecurity(
      'r1',
      SecretRoomSecurity.none.blockedWith(
        SecretBlockReason.badSignature,
        _at(5),
      ),
    );
    await store.savePendingEphemeralSeed('r1', [9], targetUserId: 'u-alice');
    await store.saveChainState(
      'r1',
      const SecretChainState(epoch: 0, n: 0, chainKey: [1, 2]),
    );

    await store.clearRoom('r1');
    expect(storage.data.keys.where((k) => k.startsWith('secret/r1/')), isEmpty);
    expect(await store.readRoomBinding('r1'), isNull);
    expect((await store.readRoomSecurity('r1')).blocked, isFalse);
    expect((await store.readPendingInit('r1')).targetUserId, isNull);
    expect(await store.readDevicePin('d-alice'), isNotNull);
  });

  test(
    '매니저의 forgetRoom도 방의 묶음만 지우고 기기 고정은 남긴다(같은 기기와 새로 대화해도 그 키만 믿는다)',
    () async {
      final manager = SecretSessionManager(
        ApiClient(baseUrl: 'https://test.local'),
        DeviceIdentity(storage: _MemoryStorage()),
        keyStore: store,
        userId: 'u-bob',
      );
      await store.saveDevicePin('d-alice', _pin('u-alice'));
      await store.saveRoomBinding('r1', _binding);
      await store.saveRoomSecurity(
        'r1',
        const SecretRoomSecurity(legacyPeer: true),
      );
      await manager.forgetRoom('r1');
      expect(await store.readRoomBinding('r1'), isNull);
      expect((await store.readRoomSecurity('r1')).legacyPeer, isFalse);
      expect(await store.readDevicePin('d-alice'), isNotNull);
    },
  );

  test('되돌리기(clearSessionKeys)는 키·묶음과 세션 안내만 지우고 평문 캐시·계정 표시·멈춤은 둔다', () async {
    await store.saveRoomBinding('r1', _binding);
    await store.saveChainState(
      'r1',
      const SecretChainState(epoch: 0, n: 0, chainKey: [1, 2]),
    );
    await store.saveRoomSecurity(
      'r1',
      const SecretRoomSecurity(legacyPeer: true, peerDeviceChanged: true),
    );
    await store.noteRoomOwner('r1', 'u-bob');
    await store.saveDecryptedText(
      SecretTextRef(roomId: 'r1', id: 'm1', createdAt: _at(1000)),
      '평문',
    );
    await store.clearSessionKeys('r1');
    expect(await store.readChainState('r1'), isNull);
    expect(await store.readRoomBinding('r1'), isNull);
    expect(storage.data['secret/r1/security'], isNull);
    expect(storage.data['secret/r1/owner'], 'u-bob');
    expect(storage.data['secretcache/r1/m1'], isNotNull);

    // 멈춘 방 — 이 되돌리기는 서버가 보내는 값을 보고 일어나서, 멈춤까지 지우면 서버가 멈춤을 풀 수 있다.
    await store.saveChainState(
      'r2',
      const SecretChainState(epoch: 0, n: 0, chainKey: [1, 2]),
    );
    await store.saveRoomSecurity(
      'r2',
      const SecretRoomSecurity(
        legacyPeer: true,
      ).blockedWith(SecretBlockReason.peerMismatch, _at(5)),
    );
    await store.clearSessionKeys('r2');
    expect(await store.readChainState('r2'), isNull);
    final r2 = await store.readRoomSecurity('r2');
    expect(r2.blockedReason, SecretBlockReason.peerMismatch);
    expect(r2.blockedAt, _at(5));
    expect(r2.legacyPeer, isFalse, reason: '되돌린 세션의 안내는 지운다');
    // 깨진 보안 상태 값(멈춘 것으로 읽힌다)도 그대로 둔다.
    storage.data['secret/r3/security'] = '깨진 값';
    await store.clearSessionKeys('r3');
    expect(storage.data['secret/r3/security'], '깨진 값');
    expect((await store.readRoomSecurity('r3')).blocked, isTrue);
  });

  test('보안 상태를 다시 적어도 이미 적힌 멈춤은 처음 이유 그대로 남는다', () async {
    final first = SecretRoomSecurity.none.blockedWith(
      SecretBlockReason.keyMismatch,
      _at(5),
      deviceId: 'd-alice',
      pinSeenAt: _at(1000),
    );
    expect(await store.saveRoomSecurity('r1', first), first);
    // 다른 일(안내 표시 고치기)이 멈추기 전에 읽은 값으로 적는다.
    final written = await store.saveRoomSecurity(
      'r1',
      const SecretRoomSecurity(legacyPeer: true),
    );
    expect(written.blockedReason, SecretBlockReason.keyMismatch);
    expect(written.legacyPeer, isTrue);
    // 다른 이유로 다시 멈춰도 처음 이유를 지킨다.
    await store.saveRoomSecurity(
      'r1',
      SecretRoomSecurity.none.blockedWith(
        SecretBlockReason.badSignature,
        _at(9),
      ),
    );
    final stored = await store.readRoomSecurity('r1');
    expect(stored.blockedReason, SecretBlockReason.keyMismatch);
    expect(stored.blockedAt, _at(5));
    expect(stored.blockedDeviceId, 'd-alice');
    expect(stored.blockedPinSeenAt, _at(1000));
    // 깨진 값은 덮어쓰지 않는다(멈춘 것으로 읽힌다).
    storage.data['secret/r2/security'] = '깨진 값';
    expect(
      (await store.saveRoomSecurity('r2', SecretRoomSecurity.none)).blocked,
      isTrue,
    );
    expect(storage.data['secret/r2/security'], '깨진 값');
  });

  test(
    '처음 고정(pinDeviceIfAbsent)은 없을 때만 적는다 — 같은 키면 먼저 것을 그대로 두고, 다른 키·주인이면 덮어쓰지 않고 다툼을 적는다',
    () async {
      final first = SecretDevicePin.firstSeen(
        userId: 'u-alice',
        signingPublicKey: 'S0FMSUNF',
        at: _at(1000),
      );
      expect(await store.pinDeviceIfAbsent('d-alice', first), first);
      // 같은 키를 다른 곳이 조금 뒤에 고정하려 한다 — 먼저 것(고정 시각 포함) 그대로.
      final same = await store.pinDeviceIfAbsent(
        'd-alice',
        SecretDevicePin.firstSeen(
          userId: 'u-alice',
          signingPublicKey: 'S0FMSUNF',
          at: _at(2000),
        ),
      );
      expect(same!.firstSeenAt, _at(1000));
      expect(same.disputed, isFalse);

      // 서버가 같은 기기를 다른 키로 알려 왔다.
      final conflict = await store.pinDeviceIfAbsent(
        'd-alice',
        SecretDevicePin.firstSeen(
          userId: 'u-alice',
          signingPublicKey: 'U0VSVkVS',
        ),
      );
      expect(conflict!.signingPublicKey, 'S0FMSUNF');
      expect(conflict.disputed, isTrue);
      final stored = (await store.readDevicePin('d-alice'))!;
      expect(stored.signingPublicKey, 'S0FMSUNF');
      expect(stored.firstSeenAt, _at(1000));
      expect(stored.disputed, isTrue);
      // 다툼 중인 고정은 같은 키가 와도 그대로 다툼이다.
      expect(
        (await store.pinDeviceIfAbsent('d-alice', first))!.disputed,
        isTrue,
      );

      // 주인이 다르게 와도 다툼이다.
      await store.pinDeviceIfAbsent('d-bob', _pin('u-bob', key: 'Qk9C'));
      final otherOwner = await store.pinDeviceIfAbsent(
        'd-bob',
        _pin('u-mallory', key: 'Qk9C'),
      );
      expect(otherOwner!.userId, 'u-bob');
      expect(otherOwner.disputed, isTrue);

      // 깨진 고정은 덮어쓰지 않고 null — 확인할 수 없는 것으로 다룬다.
      storage.data['secretpin/d-broken'] = '{깨짐';
      expect(await store.pinDeviceIfAbsent('d-broken', first), isNull);
      expect(storage.data['secretpin/d-broken'], '{깨짐');
      final entry = await store.readDevicePinEntry('d-broken');
      expect(entry.present, isTrue);
      expect(entry.pin, isNull);
      expect((await store.readDevicePinEntry('d-none')).present, isFalse);
    },
  );

  test('"확인함" 표시는 같은 고정일 때만 바뀌고, 고정 키는 그대로다', () async {
    final pin = SecretDevicePin.firstSeen(
      userId: 'u-alice',
      signingPublicKey: 'S0FMSUNF',
      at: _at(1000),
    );
    await store.pinDeviceIfAbsent('d-alice', pin);
    expect(
      await store.setDevicePinVerified(
        'd-alice',
        pin,
        myDeviceId: 'd-bob',
        verifiedAt: _at(3000),
      ),
      isTrue,
    );
    final verified = (await store.readDevicePin('d-alice'))!;
    expect(verified.verifiedAtFor('d-bob'), _at(3000));
    expect(verified.signingPublicKey, 'S0FMSUNF');
    expect(
      await store.setDevicePinVerified(
        'd-alice',
        pin,
        myDeviceId: 'd-bob',
        verifiedAt: null,
      ),
      isTrue,
    );
    expect((await store.readDevicePin('d-alice'))!.verifiedAt, isNull);

    // 지우고 다시 받은 고정(같은 키라도 다른 고정)이면 예전에 읽은 값으로는 바꾸지 않는다.
    await store.deleteDevicePin('d-alice');
    expect(await store.readDevicePin('d-alice'), isNull);
    await store.pinDeviceIfAbsent(
      'd-alice',
      SecretDevicePin.firstSeen(
        userId: 'u-alice',
        signingPublicKey: 'S0FMSUNF',
        at: _at(5000),
      ),
    );
    expect(
      await store.setDevicePinVerified(
        'd-alice',
        pin,
        myDeviceId: 'd-bob',
        verifiedAt: _at(6000),
      ),
      isFalse,
    );
    expect((await store.readDevicePin('d-alice'))!.verifiedAt, isNull);
    // 다툼 중인 고정은 확인함으로 표시하지 않는다.
    await store.pinDeviceIfAbsent('d-alice', _pin('u-alice', key: 'T1RIRVI='));
    final disputed = (await store.readDevicePin('d-alice'))!;
    expect(
      await store.setDevicePinVerified(
        'd-alice',
        disputed,
        myDeviceId: 'd-bob',
        verifiedAt: _at(7000),
      ),
      isFalse,
    );
  });

  test('roomIdsBoundToDevice는 그 상대 기기에 묶인 방만 돌려준다', () async {
    await store.saveRoomBinding('r1', _binding);
    await store.saveRoomBinding('r2', _binding);
    await store.saveRoomBinding(
      'r3',
      const SecretRoomBinding(peerUserId: 'u-carol', peerDeviceId: 'd-carol'),
    );
    storage.data['secret/r4/peer'] = '깨진 값';
    expect((await store.roomIdsBoundToDevice('d-alice')).toSet(), {'r1', 'r2'});
    expect(await store.roomIdsBoundToDevice('d-carol'), ['r3']);
    expect(await store.roomIdsBoundToDevice('d-none'), isEmpty);
    // 묶음만 거두면 그 방은 빠진다.
    await store.deleteRoomBinding('r1');
    expect(await store.readRoomBinding('r1'), isNull);
    expect(await store.roomIdsBoundToDevice('d-alice'), ['r2']);
  });

  test('고정·보안 상태의 새 칸(다툼·멈춘 원인 기기)도 저장했다 다시 읽으면 그대로다', () {
    final pin = SecretDevicePin.firstSeen(
      userId: 'u-alice',
      signingPublicKey: 'S0FMSUNF',
      at: _at(1000),
    ).markVerified('d-bob', _at(2000)).markDisputed(_at(3000));
    final decoded = SecretDevicePin.decode(pin.encode())!;
    expect(decoded.disputedAt, _at(3000));
    expect(decoded.verifiedAtFor('d-bob'), _at(2000));
    expect(decoded.isSamePinAs(pin), isTrue);
    // 확인 표시를 지워도 다툼은 남는다.
    expect(decoded.clearVerified().disputed, isTrue);
    // 다툼 칸이 숫자가 아니어도 다툼으로 읽는다(풀어 주는 쪽으로 틀리지 않게).
    expect(
      SecretDevicePin.decode('{"u":"u-a","k":"S0VZ","f":1,"x":"?"}')!.disputed,
      isTrue,
    );

    final security = SecretRoomSecurity.none.blockedWith(
      SecretBlockReason.badSignature,
      _at(5),
      deviceId: 'd-alice',
      pinSeenAt: _at(1000),
    );
    expect(SecretRoomSecurity.decode(security.encode()), security);
    // 기기 없이 멈추면 고정 시각도 적지 않는다.
    expect(
      SecretRoomSecurity.none
          .blockedWith(
            SecretBlockReason.peerMismatch,
            _at(5),
            pinSeenAt: _at(1),
          )
          .blockedPinSeenAt,
      isNull,
    );
    expect(SecretBlockReason.badSignature.allowsKeyReset, isTrue);
    expect(SecretBlockReason.keyMismatch.allowsKeyReset, isTrue);
    expect(SecretBlockReason.peerMismatch.allowsKeyReset, isFalse);
    expect(SecretBlockReason.userMismatch.allowsKeyReset, isFalse);
    expect(SecretBlockReason.keyReset.allowsKeyReset, isFalse);
  });

  test('평문 캐시 정리(색인 읽기·만료·히스토리 재조정)는 기기 고정을 방으로 보지도, 지우지도 않는다', () async {
    storage.data['secretpin/d-alice'] = _pin('u-alice').encode();
    // 깨진 고정 값도 평문 캐시 정리가 지우지 않는다(정리는 secretcache/의 깨진 값만 지운다).
    storage.data['secretpin/d-broken'] = '{깨짐';
    storage.data['secretcache/r1/m1'] = '{"t":"평문","c":1000,"e":1}';
    storage.data['secret/r1/peer'] = _binding.encode();

    expect(await store.ensureTextIndex(), isTrue);
    expect(store.localSecretRoomIds, {'r1'});
    final purged = await store.purgeExpiredTexts(
      now: _at(10 * 60 * 1000),
      serverNow: _at(10 * 60 * 1000),
    );
    expect(purged.map((e) => e.id), ['m1']);
    await store.reconcileHistoryPage(
      roomId: 'r1',
      page: const <Message>[],
      before: null,
      limit: 50,
      sinceGeneration: store.textCacheGeneration,
    );
    expect(storage.data['secretpin/d-alice'], isNotNull);
    expect(storage.data['secretpin/d-broken'], '{깨짐');
    expect(storage.data['secret/r1/peer'], isNotNull);
    expect(await store.readDevicePin('d-broken'), isNull);
    expect((await store.readDevicePin('d-alice'))?.userId, 'u-alice');
  });

  test('devicePinsOfUser는 그 사용자의 기기 고정만 돌려준다', () async {
    await store.saveDevicePin('d-alice-1', _pin('u-alice'));
    await store.saveDevicePin('d-alice-2', _pin('u-alice'));
    await store.saveDevicePin('d-carol', _pin('u-carol'));
    final pins = await store.devicePinsOfUser('u-alice');
    expect(pins.map((e) => e.$1).toSet(), {'d-alice-1', 'd-alice-2'});
  });

  test(
    '"확인함" 표시는 표시한 이 기기 id에만 붙는다 — 이 기기 키가 바뀌었거나 같은 저장소의 다른 계정이면 확인 안 한 것',
    () {
      final verified = _pin('u-alice').markVerified('d-bob', _at(2000));
      expect(verified.verifiedAtFor('d-bob'), _at(2000));
      expect(verified.verifiedAtFor('d-bob-new'), isNull);
      final decoded = SecretDevicePin.decode(verified.encode())!;
      expect(decoded.verifiedAtFor('d-bob'), _at(2000));
      expect(decoded.signingPublicKey, verified.signingPublicKey);
      expect(decoded.clearVerified().verifiedAtFor('d-bob'), isNull);
    },
  );

  test(
    '보안 상태 값이 깨졌거나 모르는 멈춤 사유면 멈춘 것으로 읽는다(저장소 오류로 멈춘 방이 다시 풀리면 안 된다)',
    () async {
      storage.data['secret/r1/security'] = '깨진 값';
      expect((await store.readRoomSecurity('r1')).blocked, isTrue);
      storage.data['secret/r2/security'] = '{"b":"새-사유"}';
      expect((await store.readRoomSecurity('r2')).blocked, isTrue);
      storage.data['secret/r3/security'] = '{"l":true}';
      final r3 = await store.readRoomSecurity('r3');
      expect(r3.blocked, isFalse);
      expect(r3.legacyPeer, isTrue);
    },
  );

  test('"예전 방식 대화" 안내를 닫은 표시(pd)도 저장했다 다시 읽으면 그대로고, 같은 값인지 견줄 때도 본다', () {
    const dismissed = SecretRoomSecurity(protocolNoticeDismissed: true);
    expect(jsonDecode(dismissed.encode()), {'pd': true});
    final decoded = SecretRoomSecurity.decode(dismissed.encode())!;
    expect(decoded.protocolNoticeDismissed, isTrue);
    expect(decoded, dismissed);
    expect(decoded.hashCode, dismissed.hashCode);
    expect(decoded == SecretRoomSecurity.none, isFalse);
    // 닫지 않았으면 적지 않고, 그 칸이 없는(이 표시가 생기기 전의) 값은 닫지 않은 것으로 읽는다.
    expect(SecretRoomSecurity.none.encode(), '{}');
    expect(
      SecretRoomSecurity.decode('{"l":true}')!.protocolNoticeDismissed,
      isFalse,
    );
    // 다른 안내 표시와 함께 적어도 그대로고, copyWith는 고치지 않은 칸을 그대로 둔다.
    final all = const SecretRoomSecurity(
      legacyPeer: true,
      legacyNoticeDismissed: true,
      peerDeviceChanged: true,
    ).copyWith(protocolNoticeDismissed: true);
    expect(all.legacyPeer && all.legacyNoticeDismissed, isTrue);
    expect(SecretRoomSecurity.decode(all.encode()), all);
    expect(
      all.copyWith(peerDeviceChanged: false).protocolNoticeDismissed,
      isTrue,
    );
  });

  test(
    '멈출 때(blockedWith)와 멈춤을 옮겨 적을 때(withBlockOf)는 "예전 방식 대화" 안내를 닫은 표시를 지키고, 멈춤만 남길 때(blockOnly)는 뺀다',
    () async {
      const dismissed = SecretRoomSecurity(
        legacyPeer: true,
        protocolNoticeDismissed: true,
      );
      final blocked = dismissed.blockedWith(
        SecretBlockReason.peerMismatch,
        _at(5),
      );
      expect(blocked.blockedReason, SecretBlockReason.peerMismatch);
      expect(blocked.protocolNoticeDismissed, isTrue);
      expect(SecretRoomSecurity.decode(blocked.encode()), blocked);

      final stored = SecretRoomSecurity.none.blockedWith(
        SecretBlockReason.keyMismatch,
        _at(7),
        deviceId: 'd-alice',
        pinSeenAt: _at(1000),
      );
      final rewritten = dismissed.withBlockOf(stored);
      expect(rewritten.blockedReason, SecretBlockReason.keyMismatch);
      expect(rewritten.blockedAt, _at(7));
      expect(rewritten.blockedDeviceId, 'd-alice');
      expect(rewritten.blockedPinSeenAt, _at(1000));
      expect(rewritten.legacyPeer, isTrue);
      expect(rewritten.protocolNoticeDismissed, isTrue);

      final only = blocked.blockOnly();
      expect(
        only,
        SecretRoomSecurity.none.blockedWith(
          SecretBlockReason.peerMismatch,
          _at(5),
        ),
      );
      expect(only.protocolNoticeDismissed, isFalse);

      // 저장소에서도 — 멈춘 방에 닫은 표시를 적으면 처음 멈춤은 그대로 두고 표시는 남기며, 되돌리면(clearSessionKeys)
      // 멈춤만 남는다.
      await store.saveRoomSecurity('r1', stored);
      final written = await store.saveRoomSecurity(
        'r1',
        SecretRoomSecurity.none.copyWith(protocolNoticeDismissed: true),
      );
      expect(written, stored.copyWith(protocolNoticeDismissed: true));
      expect(await store.readRoomSecurity('r1'), written);
      await store.clearSessionKeys('r1');
      expect(await store.readRoomSecurity('r1'), stored);
    },
  );

  test(
    '"예전 방식 대화" 안내(showProtocolNotice)는 예전 규약 대화에서만 — 멈췄거나, 상대가 예전 앱이거나(그 안내를 닫았어도), 닫았으면 보이지 않는다',
    () {
      const v1 = SecretRoomTrust(legacyProtocol: true);
      expect(v1.showProtocolNotice, isTrue);
      expect(const SecretRoomTrust().showProtocolNotice, isFalse);
      expect(
        SecretRoomTrust(
          legacyProtocol: true,
          security: SecretRoomSecurity.none.blockedWith(
            SecretBlockReason.badSignature,
            _at(5),
          ),
        ).showProtocolNotice,
        isFalse,
      );
      expect(
        const SecretRoomTrust(
          legacyProtocol: true,
          security: SecretRoomSecurity(protocolNoticeDismissed: true),
        ).showProtocolNotice,
        isFalse,
      );
      for (final legacyDismissed in [false, true]) {
        final legacy = SecretRoomTrust(
          legacyProtocol: true,
          security: SecretRoomSecurity(
            legacyPeer: true,
            legacyNoticeDismissed: legacyDismissed,
          ),
        );
        expect(legacy.showLegacyNotice, !legacyDismissed);
        expect(legacy.showProtocolNotice, isFalse);
      }
      // 규약이 다르면 다른 신뢰 상태다(바뀌면 화면을 다시 그린다).
      expect(v1, const SecretRoomTrust(legacyProtocol: true));
      expect(v1 == const SecretRoomTrust(), isFalse);
    },
  );

  test(
    '세션의 규약(sessionProtocol·hasSession) — 없으면 null, 예전 규약 체인이면 1, 더블 래칫 상태가 있으면 깨졌어도 3',
    () async {
      expect(await store.sessionProtocol('r1'), isNull);
      expect(await store.hasSession('r1'), isFalse);
      // 초대에 응답을 기다리는 중(대기 중인 임시키만 있음)이면 아직 세션이 아니다.
      await store.savePendingEphemeralSeed(
        'r1',
        [1, 2, 3],
        targetUserId: 'u-alice',
        offeredProtocol: 3,
      );
      expect(await store.sessionProtocol('r1'), isNull);
      expect(await store.hasSession('r1'), isFalse);

      await store.saveChainState('r2', _v1Chain());
      expect(await store.sessionProtocol('r2'), 1);
      expect(await store.hasSession('r2'), isTrue);

      await store.saveRatchetState('r3', await _v3Ratchet());
      expect(await store.sessionProtocol('r3'), 3);
      expect(await store.hasSession('r3'), isTrue);

      // 깨진 래칫 상태도 3이다 — 세션이 없다고 보면 다시 맺거나 예전 대화로 잘못 묶는다.
      storage.data['secret/r4/ratchet'] = '깨진 값';
      expect(await store.sessionProtocol('r4'), 3);
      expect(await store.hasSession('r4'), isTrue);
    },
  );

  test(
    '더블 래칫 상태(readRatchetState) — 없으면 present가 false, 적은 값은 다시 켜도 그대로, 깨졌으면 present는 true에 state만 null',
    () async {
      final none = await store.readRatchetState('r1');
      expect(none.present, isFalse);
      expect(none.state, isNull);

      final state = await _v3Ratchet();
      await store.saveRatchetState('r1', state);
      final restarted = SecretKeyStore(storage: storage);
      addTearDown(restarted.dispose);
      final read = await restarted.readRatchetState('r1');
      expect(read.present, isTrue);
      expect(read.state?.role, secretRoleResponder);
      expect(read.state?.encode(), state.encode());

      for (final broken in [
        '깨진 값',
        '{"v":3,"role":"r"}',
        state.encode().replaceFirst('"v":3', '"v":1'),
      ]) {
        storage.data['secret/r1/ratchet'] = broken;
        final entry = await store.readRatchetState('r1');
        expect(entry.present, isTrue, reason: broken);
        expect(entry.state, isNull, reason: broken);
      }
    },
  );

  test(
    '예전 규약 방에 남겨 둔 메시지 키(skipped) — 적은 순서 그대로 다시 켜도 읽히고, 빈 목록을 적으면 지우며, 깨졌으면 빈 목록이다',
    () async {
      expect(await store.readV1SkippedKeys('r1'), isEmpty);
      final keys = [_skipped('e0', 3), _skipped('e0', 5), _skipped('e1', 0)];
      await store.saveV1SkippedKeys('r1', keys);
      final restarted = SecretKeyStore(storage: storage);
      addTearDown(restarted.dispose);
      expect(_plain(await restarted.readV1SkippedKeys('r1')), _plain(keys));

      await store.saveV1SkippedKeys('r1', const []);
      expect(storage.data.containsKey('secret/r1/skipped'), isFalse);
      expect(await store.readV1SkippedKeys('r1'), isEmpty);

      for (final broken in ['깨진 값', '[1,2]', '{"c":"e0","e":[]}']) {
        storage.data['secret/r1/skipped'] = broken;
        expect(await store.readV1SkippedKeys('r1'), isEmpty, reason: broken);
      }
    },
  );

  test(
    '체인 상태를 남겨 둔 키와 함께 적으면(saveChainState skipped) 키를 먼저 적고, 빈 목록이면 지우며, 안 주면 남겨 둔 키는 그대로다',
    () async {
      await store.saveChainState(
        'r1',
        _v1Chain(),
        skipped: [_skipped('e0', 0)],
      );
      final skippedAt = storage.mutations.indexOf('write secret/r1/skipped');
      expect(skippedAt, isNonNegative);
      // 체인 상태는 한 값(secret/<방>/chain)이라 한 번에 바뀐다 — 예전처럼 칸마다(epoch·n·chainKey) 따로 쓰지 않는다.
      expect(
        skippedAt,
        lessThan(storage.mutations.indexOf('write secret/r1/chain')),
      );
      expect(
        storage.mutations.where(
          (m) => m.startsWith('write secret/r1/chainKey'),
        ),
        isEmpty,
      );
      expect(
        _plain(await store.readV1SkippedKeys('r1')),
        _plain([_skipped('e0', 0)]),
      );

      await store.saveChainState('r1', _v1Chain(n: 1));
      expect((await store.readChainState('r1'))!.n, 1);
      expect(await store.readV1SkippedKeys('r1'), hasLength(1));

      storage.mutations.clear();
      await store.saveChainState('r1', _v1Chain(n: 2), skipped: const []);
      expect(storage.mutations.first, 'delete secret/r1/skipped');
      expect(storage.data.containsKey('secret/r1/skipped'), isFalse);
      expect((await store.readChainState('r1'))!.n, 2);
      expect(await store.sessionProtocol('r1'), 1);
    },
  );

  test(
    '되돌리기(clearSessionKeys)와 방 잊기(clearRoom)는 더블 래칫 상태와 예전 규약에서 남겨 둔 키도 지운다',
    () async {
      Future<void> seed(String v3Room, String v1Room) async {
        await store.saveRatchetState(v3Room, await _v3Ratchet());
        await store.saveChainState(
          v1Room,
          _v1Chain(),
          skipped: [_skipped('e0', 1)],
        );
      }

      await seed('r1', 'r2');
      await store.clearSessionKeys('r1');
      await store.clearSessionKeys('r2');
      await seed('r3', 'r4');
      await store.clearRoom('r3');
      await store.clearRoom('r4');
      for (final id in ['r1', 'r2', 'r3', 'r4']) {
        expect(
          storage.data.keys.where((k) => k.startsWith('secret/$id/')),
          isEmpty,
          reason: id,
        );
        expect(await store.hasSession(id), isFalse, reason: id);
        expect((await store.readRatchetState(id)).present, isFalse, reason: id);
        expect(await store.readV1SkippedKeys(id), isEmpty, reason: id);
      }
    },
  );

  test(
    '예전 재키잉 임시키 정리(clearStaleRekeySeed) — 없으면 저장소에 쓰지도 지우지도 않고 false, 하나라도 있으면 둘 다 지우고 true',
    () async {
      await store.saveChainState('r1', _v1Chain());
      storage.mutations.clear();
      expect(await store.clearStaleRekeySeed('r1'), isFalse);
      expect(storage.mutations, isEmpty);

      storage.data['secret/r1/pendingRekeyEpoch'] = '1';
      storage.data['secret/r1/pendingRekeySeed'] = 'c2VlZA==';
      expect(await store.clearStaleRekeySeed('r1'), isTrue);
      expect(storage.data.containsKey('secret/r1/pendingRekeyEpoch'), isFalse);
      expect(storage.data.containsKey('secret/r1/pendingRekeySeed'), isFalse);
      // 체인 상태는 그대로다.
      expect((await store.readChainState('r1'))?.n, 0);

      // 한쪽만 남아 있어도 지운다.
      storage.data['secret/r2/pendingRekeySeed'] = 'c2VlZA==';
      expect(await store.clearStaleRekeySeed('r2'), isTrue);
      expect(storage.data.containsKey('secret/r2/pendingRekeySeed'), isFalse);

      // 지운 뒤에는 다시 false고, 저장소에 손대지 않는다.
      storage.mutations.clear();
      expect(await store.clearStaleRekeySeed('r1'), isFalse);
      expect(await store.clearStaleRekeySeed('r2'), isFalse);
      expect(storage.mutations, isEmpty);
    },
  );

  test(
    '대기 중인 초대 정보는 실어 보낸 규약 번호(offeredProtocol)도 남기고, 그 칸이 없는 예전 값은 null로 읽는다',
    () async {
      await store.savePendingEphemeralSeed(
        'r1',
        [1, 2, 3],
        targetUserId: 'u-alice',
        myDeviceId: 'd-bob',
        offeredProtocol: 3,
      );
      final restarted = SecretKeyStore(storage: storage);
      addTearDown(restarted.dispose);
      expect(await restarted.readPendingInit('r1'), (
        targetUserId: 'u-alice',
        myDeviceId: 'd-bob',
        offeredProtocol: 3,
      ));

      // 규약 번호만 있어도 적는다.
      await store.savePendingEphemeralSeed('r2', [4], offeredProtocol: 3);
      expect(await store.readPendingInit('r2'), (
        targetUserId: null,
        myDeviceId: null,
        offeredProtocol: 3,
      ));

      // 이 칸이 생기기 전(업데이트 전)에 건 초대 — 상대·기기 id는 그대로 읽고 규약 번호는 null.
      storage.data['secret/r3/pendingInit'] = jsonEncode({
        't': 'u-alice',
        'd': 'd-bob',
      });
      expect(await store.readPendingInit('r3'), (
        targetUserId: 'u-alice',
        myDeviceId: 'd-bob',
        offeredProtocol: null,
      ));
      // 숫자가 아닌 규약 번호도 null.
      storage.data['secret/r4/pendingInit'] = jsonEncode({
        't': 'u-alice',
        'p': '3',
      });
      expect((await store.readPendingInit('r4')).offeredProtocol, isNull);

      // 초대를 거두면(clearPendingEphemeralSeed) 함께 지운다.
      await store.clearPendingEphemeralSeed('r1');
      expect(await store.readPendingInit('r1'), (
        targetUserId: null,
        myDeviceId: null,
        offeredProtocol: null,
      ));
      expect(await store.readPendingEphemeralSeed('r1'), isNull);
    },
  );

  test(
    '예전 규약 체인 상태는 한 값(chain)으로 적는다 — 이 업데이트 전 형식(칸마다 따로)도 읽고, 다음에 적을 때 예전 칸을 지운다',
    () async {
      storage.data['secret/r1/epoch'] = '0';
      storage.data['secret/r1/n'] = '7';
      storage.data['secret/r1/chainKey'] = base64Encode(List.filled(32, 5));
      storage.data['secret/r1/prevEpoch'] = '0';
      storage.data['secret/r1/prevChainKeySnapshot'] = base64Encode(
        List.filled(32, 6),
      );
      expect(await store.sessionProtocol('r1'), 1);
      final legacy = (await store.readChainState('r1'))!;
      expect(legacy.epoch, 0);
      expect(legacy.n, 7);
      expect(legacy.chainKey, List.filled(32, 5));

      storage.mutations.clear();
      await store.saveChainState(
        'r1',
        SecretChainState(epoch: 0, n: 8, chainKey: List.filled(32, 9)),
      );
      // 새 값을 먼저 적고 예전 칸을 지운다.
      expect(storage.mutations.first, 'write secret/r1/chain');
      for (final field in [
        'epoch',
        'n',
        'chainKey',
        'prevEpoch',
        'prevChainKeySnapshot',
      ]) {
        expect(
          storage.data.containsKey('secret/r1/$field'),
          isFalse,
          reason: field,
        );
      }
      final restarted = SecretKeyStore(storage: storage);
      addTearDown(restarted.dispose);
      final state = (await restarted.readChainState('r1'))!;
      expect(state.n, 8);
      expect(state.chainKey, List.filled(32, 9));
      expect(await restarted.sessionProtocol('r1'), 1);

      // 한 번 옮긴 뒤로는 적을 때 예전 칸을 다시 지우지 않는다(지울 것이 없다).
      storage.mutations.clear();
      await restarted.saveChainState(
        'r1',
        SecretChainState(epoch: 0, n: 9, chainKey: List.filled(32, 3)),
      );
      expect(storage.mutations, ['write secret/r1/chain']);

      // 깨진 값은 읽지 못한다(세션은 있는 것으로 둔다).
      storage.data['secret/r1/chain'] = '{깨짐';
      expect(await restarted.readChainState('r1'), isNull);
      expect(await restarted.sessionProtocol('r1'), 1);
      // 예전 형식의 깨진 값(숫자가 아님·키 길이가 틀림)도.
      storage.data.remove('secret/r1/chain');
      storage.data['secret/r2/epoch'] = '0';
      storage.data['secret/r2/n'] = 'x';
      storage.data['secret/r2/chainKey'] = base64Encode(List.filled(32, 5));
      expect(await restarted.readChainState('r2'), isNull);
      storage.data['secret/r2/n'] = '1';
      storage.data['secret/r2/chainKey'] = base64Encode(List.filled(8, 5));
      expect(await restarted.readChainState('r2'), isNull);
    },
  );

  test('새 규약 래칫 상태는 남겨 둔 키를 따로 적고, 키가 바뀌었을 때만 그 칸을 다시 쓴다 — 읽을 때 붙인다', () async {
    final state = (await _v3Ratchet()).withSkipped([_skipped('dhA', 0)]);
    await store.saveRatchetState('r1', state);
    expect(storage.data['secret/r1/skipped'], isNotNull);
    final rawState =
        jsonDecode(storage.data['secret/r1/ratchet']!) as Map<String, dynamic>;
    expect(rawState.containsKey('sk'), isFalse);
    expect(
      _plain((await store.readRatchetState('r1')).state!.skipped),
      _plain([_skipped('dhA', 0)]),
    );

    storage.mutations.clear();
    await store.saveRatchetState('r1', state, skippedChanged: false);
    expect(storage.mutations, ['write secret/r1/ratchet']);

    await store.saveRatchetState('r1', state.withSkipped(const []));
    expect(storage.data.containsKey('secret/r1/skipped'), isFalse);
    expect((await store.readRatchetState('r1')).state!.skipped, isEmpty);
  });

  test(
    '수락 응답 대기 표시 — 적고 지울 수 있고, 없을 때 지우면 쓰지 않으며, 되돌리기(clearSessionKeys)가 함께 지운다',
    () async {
      expect(await store.hasAcceptPending('r1'), isFalse);
      await store.markAcceptPending('r1');
      expect(await store.hasAcceptPending('r1'), isTrue);
      await store.clearAcceptPending('r1');
      expect(await store.hasAcceptPending('r1'), isFalse);
      storage.mutations.clear();
      await store.clearAcceptPending('r1');
      expect(storage.mutations, isEmpty);
      await store.markAcceptPending('r1');
      await store.clearSessionKeys('r1');
      expect(await store.hasAcceptPending('r1'), isFalse);
    },
  );

  test(
    '세션 키 재료만 지우기(멈춘 방) — 두 규약의 상태·남겨 둔 키·예전 재키잉 임시키는 지우고 묶음·보안 상태·대기 중인 초대는 둔다',
    () async {
      await store.saveChainState(
        'r1',
        _v1Chain(),
        skipped: [_skipped('e0', 0)],
      );
      await store.saveRatchetState('r1', await _v3Ratchet());
      storage.data['secret/r1/epoch'] = '0';
      storage.data['secret/r1/pendingRekeySeed'] = base64Encode([1]);
      await store.saveRoomBinding('r1', _binding);
      await store.saveRoomSecurity(
        'r1',
        const SecretRoomSecurity(legacyPeer: true),
      );
      await store.savePendingEphemeralSeed('r1', [4, 5, 6]);
      await store.deleteSessionKeyMaterial('r1');
      for (final field in [
        'chain',
        'ratchet',
        'skipped',
        'epoch',
        'pendingRekeySeed',
      ]) {
        expect(
          storage.data.containsKey('secret/r1/$field'),
          isFalse,
          reason: field,
        );
      }
      expect(await store.hasSession('r1'), isFalse);
      expect(await store.readRoomBinding('r1'), _binding);
      expect((await store.readRoomSecurity('r1')).legacyPeer, isTrue);
      expect(await store.readPendingEphemeralSeed('r1'), [4, 5, 6]);
    },
  );

  test('예전 재키잉 임시키 정리 표시는 계정마다 한 번 — 방·평문·고정으로 읽히지 않는 이름이다', () async {
    expect(await store.staleRekeyCleanupDone('me'), isFalse);
    await store.markStaleRekeyCleanupDone('me');
    expect(await store.staleRekeyCleanupDone('me'), isTrue);
    expect(await store.staleRekeyCleanupDone('other'), isFalse);
    final key = storage.data.keys.single;
    expect(key.startsWith('secret/'), isFalse);
    expect(key.startsWith('secretcache/'), isFalse);
    expect(key.startsWith('secretpin/'), isFalse);
    final restarted = SecretKeyStore(storage: storage);
    addTearDown(restarted.dispose);
    expect(await restarted.ensureTextIndex(), isTrue);
    expect(restarted.localSecretRoomIds, isEmpty);
    expect(await restarted.staleRekeyCleanupDone('me'), isTrue);
  });

  test(
    '저장해 둔 평문은 같은 방·같은 보낸 쪽·같은 봉투로 읽을 때만 준다 — 봉투 지문이 같아야만(requireEnvelopeMatch) 주는 읽기도 있다',
    () async {
      await store.saveDecryptedText(
        SecretTextRef(
          roomId: 'r1',
          id: 'm1',
          createdAt: _at(1),
          envelope: 'E1',
          fromMe: true,
        ),
        '내 글',
      );
      final stored =
          jsonDecode(storage.data['secretcache/r1/m1']!)
              as Map<String, dynamic>;
      expect(stored['o'], isTrue);
      expect((stored['h'] as String).length, 24); // 16바이트의 base64
      expect(
        stored.toString().contains('E1'),
        isFalse,
        reason: '봉투 자체는 적지 않는다',
      );
      SecretTextRef ref({
        String roomId = 'r1',
        String? envelope = 'E1',
        bool? fromMe = true,
      }) => SecretTextRef(
        roomId: roomId,
        id: 'm1',
        createdAt: _at(1),
        envelope: envelope,
        fromMe: fromMe,
      );
      expect(await store.readDecryptedText(ref()), '내 글');
      expect(await store.readDecryptedText(ref(roomId: 'r2')), isNull);
      expect(await store.readDecryptedText(ref(fromMe: false)), isNull);
      expect(await store.readDecryptedText(ref(envelope: 'E2')), isNull);
      // 모르면(null) 확인하지 않는다.
      expect(
        await store.readDecryptedText(ref(envelope: null, fromMe: null)),
        '내 글',
      );
      expect(
        await store.readDecryptedText(ref(), requireEnvelopeMatch: true),
        '내 글',
      );
      expect(
        await store.readDecryptedText(
          ref(envelope: 'E2'),
          requireEnvelopeMatch: true,
        ),
        isNull,
      );
      expect(
        await store.readDecryptedText(
          ref(envelope: null),
          requireEnvelopeMatch: true,
        ),
        isNull,
      );
      // 맞지 않는 읽기가 저장한 평문을 지우지 않았다.
      expect(await store.readDecryptedText(ref()), '내 글');
    },
  );

  test(
    '저장해 둔 평문은 원본 메시지(댓글)와 보낸 사람까지 같을 때만 준다 — 서버가 댓글을 다른 글 아래로 옮기거나 보낸 사람을 바꿔 붙이면 주지 않는다',
    () async {
      await store.saveDecryptedText(
        SecretTextRef(
          roomId: 'r1',
          id: 'c1',
          parentId: 'm1',
          createdAt: _at(1),
          envelope: 'E1',
          fromMe: false,
          senderId: 'u-alice',
        ),
        '댓글',
      );
      SecretTextRef ref({
        String? parentId = 'm1',
        bool? fromMe = false,
        String? senderId = 'u-alice',
      }) => SecretTextRef(
        roomId: 'r1',
        id: 'c1',
        parentId: parentId,
        createdAt: _at(1),
        envelope: 'E1',
        fromMe: fromMe,
        senderId: senderId,
      );
      expect(await store.readDecryptedText(ref()), '댓글');
      expect(await store.readDecryptedText(ref(parentId: 'm2')), isNull);
      expect(
        await store.readDecryptedText(ref(parentId: null)),
        isNull,
        reason: '댓글을 메시지로 보여 주면 안 된다',
      );
      expect(await store.readDecryptedText(ref(senderId: 'u-mallory')), isNull);
      expect(await store.readDecryptedText(ref(fromMe: true)), isNull);
      // 보낸 사람을 모르면(탈퇴한 사람 등) 그것만 확인하지 않는다.
      expect(await store.readDecryptedText(ref(senderId: null)), '댓글');
      expect(await store.readDecryptedText(ref()), '댓글');
    },
  );

  test(
    '읽음 확정으로 삭제 예정 시각을 다시 적어도(noteMessageRead) 봉투 지문·보낸 쪽은 그대로 남는다 — 그 뒤에도 다른 봉투로는 주지 않는다',
    () async {
      SecretTextRef ref({String envelope = 'E1'}) => SecretTextRef(
        roomId: 'r1',
        id: 'm1',
        createdAt: _at(1),
        envelope: envelope,
        fromMe: false,
        senderId: 'u-alice',
      );
      await store.saveDecryptedText(ref(), '글');
      final before =
          jsonDecode(storage.data['secretcache/r1/m1']!)
              as Map<String, dynamic>;
      final expiresAt = DateTime.now().add(const Duration(days: 1));
      await store.noteMessageRead('m1', expiresAt);
      final after =
          jsonDecode(storage.data['secretcache/r1/m1']!)
              as Map<String, dynamic>;
      expect(after, isNot(before), reason: '삭제 예정 시각을 적었다');
      for (final field in ['h', 'o', 's']) {
        expect(after[field], before[field], reason: field);
      }
      expect(await store.readDecryptedText(ref()), '글');
      expect(await store.readDecryptedText(ref(envelope: 'E2')), isNull);
    },
  );

  test(
    '예전 칸을 지우다 실패해도 새 체인 상태는 적힌 것으로 보고 다음에 적을 때 다시 지운다 — 다시 켠 뒤 남은 체인키를 찾아서도 지운다',
    () async {
      final failing = _FailingDeleteStorage();
      final s = SecretKeyStore(storage: failing);
      addTearDown(s.dispose);
      failing.data['secret/r1/epoch'] = '0';
      failing.data['secret/r1/n'] = '7';
      failing.data['secret/r1/chainKey'] = base64Encode(List.filled(32, 5));
      failing.data['secret/r1/prevChainKeySnapshot'] = base64Encode(
        List.filled(32, 6),
      );
      expect((await s.readChainState('r1'))!.n, 7);
      failing.failDeleteOf = 'secret/r1/prevChainKeySnapshot';
      // 보내기·받기가 실패하지 않는다 — 새 상태는 적혔다.
      await s.saveChainState('r1', _v1Chain(n: 8));
      expect((await s.readChainState('r1'))!.n, 8);
      expect(
        failing.data['secret/r1/chainKey'],
        isNotNull,
        reason: '체인키는 마지막에 지운다 — 남아 있으면 다 지우지 못한 것',
      );
      failing.failDeleteOf = null;
      await s.saveChainState('r1', _v1Chain(n: 9));
      for (final field in [
        'epoch',
        'n',
        'chainKey',
        'prevEpoch',
        'prevChainKeySnapshot',
      ]) {
        expect(
          failing.data.containsKey('secret/r1/$field'),
          isFalse,
          reason: field,
        );
      }
      // 지우던 중 앱이 꺼져 체인키가 남았다 — 다시 켜서 읽을 때 찾아 두고 다음에 적을 때 지운다.
      failing.data['secret/r1/chainKey'] = base64Encode(List.filled(32, 5));
      final restarted = SecretKeyStore(storage: failing);
      addTearDown(restarted.dispose);
      expect((await restarted.readChainState('r1'))!.n, 9);
      await restarted.saveChainState('r1', _v1Chain(n: 10));
      expect(failing.data.containsKey('secret/r1/chainKey'), isFalse);
      // 한 번 본 뒤로는 읽을 때마다 다시 보지 않는다.
      failing.mutations.clear();
      await restarted.readChainState('r1');
      await restarted.saveChainState('r1', _v1Chain(n: 11));
      expect(failing.mutations, ['write secret/r1/chain']);
    },
  );

  test(
    '남겨 둔 키를 상태 안에 함께 적은 래칫 값(이 형식을 정하기 전의 시험판)은 읽을 때 따로 적는 칸으로 옮긴다 — 그 뒤 키가 바뀌지 않은 저장에도 잃지 않는다',
    () async {
      final state = (await _v3Ratchet()).withSkipped([_skipped('dhA', 0)]);
      storage.data['secret/r1/ratchet'] = state.encode();
      storage.data['secret/r1/skipped'] = jsonEncode(
        encodeSkippedKeys([_skipped('dhB', 3)]),
      );
      final read = (await store.readRatchetState('r1')).state!;
      final expected = _plain([_skipped('dhB', 3), _skipped('dhA', 0)]);
      expect(_plain(read.skipped), expected);
      final rawState =
          jsonDecode(storage.data['secret/r1/ratchet']!)
              as Map<String, dynamic>;
      expect(rawState.containsKey('sk'), isFalse);
      await store.saveRatchetState('r1', read, skippedChanged: false);
      expect(
        _plain((await store.readRatchetState('r1')).state!.skipped),
        expected,
      );
    },
  );

  test(
    '저장소를 처음 훑을 때(평문 색인) 예전 앱이 남긴 재키잉 임시키를 모든 방에서 지운다 — 목록에 없는 방의 것도, 다른 칸은 두고',
    () async {
      storage.data['secret/gone/pendingRekeySeed'] = base64Encode([1]);
      storage.data['secret/gone/pendingRekeyEpoch'] = '2';
      storage.data['secret/r1/pendingRekeySeed'] = base64Encode([2]);
      await store.saveChainState('r1', _v1Chain());
      expect(await store.ensureTextIndex(), isTrue);
      expect(
        storage.data.keys.where((k) => k.contains('pendingRekey')),
        isEmpty,
      );
      expect((await store.readChainState('r1'))!.n, 0);
    },
  );
}
