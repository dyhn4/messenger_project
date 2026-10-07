import 'package:client/models/message.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/chat_socket.dart';
import 'package:client/services/device_identity.dart';
import 'package:client/services/secret_key_store.dart';
import 'package:client/services/secret_peer_store.dart';
import 'package:client/services/secret_session_manager.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

/// 비밀 대화 상대 기기 고정(S5)의 저장 — 기기 고정·방 묶음·보안 상태가 다시 켜도 남는지, 방을 잊으면 방의 것만
/// 지워지고 기기 고정은 남는지, 평문 캐시 정리(번들 3의 색인·만료·재조정)가 기기 고정을 건드리지 않는지 본다.

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

DateTime _at(int ms) => DateTime.fromMillisecondsSinceEpoch(ms);

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
  late _MemoryStorage storage;
  late SecretKeyStore store;

  setUp(() {
    storage = _MemoryStorage();
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
        ChatSocket(),
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
}
