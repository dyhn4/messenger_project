import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

import 'api_client.dart';
import 'app_platform.dart';

const _kDeviceId = 'secret_device_id';
const _kIdentitySeed = 'secret_identity_seed'; // X25519 개인키(32바이트 시드).
const _kSigningSeed = 'secret_signing_seed'; // Ed25519 개인키(32바이트 시드).

/// 비밀 대화(E2EE)에 쓰는 "이 기기"의 신원. 로그인 계정과 별개로 기기 하나당 하나씩 존재하고,
/// 여러 기기 동기화를 안 하는 것(요구사항)의 근거가 된다 — 개인키가 이 기기의
/// flutter_secure_storage(Windows DPAPI / Android Keystore)에만 있고 절대 다른 곳으로 안 나간다.
class DeviceIdentity {
  final FlutterSecureStorage _storage;
  DeviceIdentity({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  String? _deviceId;
  SimpleKeyPair? _identityKeyPair; // X25519 — 핸드셰이크 ECDH의 신원 인증용 서명 대상.
  SimpleKeyPair? _signingKeyPair; // Ed25519 — 임시 공개키 서명/검증용.

  String get deviceId {
    final id = _deviceId;
    if (id == null) {
      throw StateError('DeviceIdentity.ensureLoaded()를 먼저 호출해야 합니다.');
    }
    return id;
  }

  SimpleKeyPair get identityKeyPair => _identityKeyPair!;
  SimpleKeyPair get signingKeyPair => _signingKeyPair!;

  /// 없으면 새로 만들고, 있으면 저장된 걸 그대로 불러온다. 앱 시작 시 한 번만 호출.
  Future<void> ensureLoaded() async {
    if (_deviceId != null) return;

    var deviceId = await _storage.read(key: _kDeviceId);
    if (deviceId == null) {
      deviceId = const Uuid().v4();
      await _storage.write(key: _kDeviceId, value: deviceId);
    }
    _deviceId = deviceId;

    _identityKeyPair = await _loadOrCreateKeyPair(X25519(), _kIdentitySeed);
    _signingKeyPair = await _loadOrCreateKeyPair(Ed25519(), _kSigningSeed);
  }

  /// X25519/Ed25519 둘 다 32바이트 시드로 키쌍을 만들 수 있어서(newKeyPairFromSeed), 저장은
  /// 그 시드 하나만 base64로 남기고 필요할 때마다 다시 만든다 — 개인키 그 자체를 직렬화해서
  /// 들고 다니는 것보다 이 패키지의 정석적인 재생성 방식이다.
  Future<SimpleKeyPair> _loadOrCreateKeyPair(
    dynamic algorithm,
    String storageKey,
  ) async {
    final stored = await _storage.read(key: storageKey);
    if (stored != null) {
      return await algorithm.newKeyPairFromSeed(base64Decode(stored))
          as SimpleKeyPair;
    }
    final keyPair = await algorithm.newKeyPair() as SimpleKeyPair;
    final seed = await keyPair.extractPrivateKeyBytes();
    await _storage.write(key: storageKey, value: base64Encode(seed));
    return keyPair;
  }

  /// 이 기기를 서버에 등록(멱등)하고, 실패해도(오프라인 등) 앱 시작을 막지 않도록 조용히 무시한다
  /// — 실제 비밀 대화를 시작/수락하려는 시점에 다시 시도되면 된다.
  Future<void> registerWithServer(ApiClient api, {String? name}) async {
    try {
      await api.registerDevice(
        deviceId: deviceId,
        name: name ?? AppPlatform.operatingSystem,
        identityPublicKey: await publicKeyBase64(identityKeyPair),
        signingPublicKey: await publicKeyBase64(signingKeyPair),
      );
    } catch (_) {
      // 오프라인 등으로 실패해도 앱 사용 자체는 계속돼야 한다.
    }
  }
}

Future<String> publicKeyBase64(SimpleKeyPair keyPair) async {
  final publicKey = await keyPair.extractPublicKey();
  return base64Encode(publicKey.bytes);
}
