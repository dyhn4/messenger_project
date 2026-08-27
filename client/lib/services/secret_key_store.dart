import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 비밀 대화 방 하나의 현재 래칫 상태. chainKey는 항상 "다음 메시지에 쓸" 체인키를 가리킨다
/// (secret_chat_crypto.dart의 ratchet 함수가 매 메시지 후 이 자리를 갱신한다).
class SecretChainState {
  final int epoch;
  final int n;
  final List<int> chainKey;
  final int? prevEpoch;
  final List<int>? prevChainKeySnapshot; // 오프라인 중 재키잉을 놓쳤을 때 뒤쫓아가기용 스냅샷.
  const SecretChainState({
    required this.epoch,
    required this.n,
    required this.chainKey,
    this.prevEpoch,
    this.prevChainKeySnapshot,
  });
}

/// flutter_secure_storage(Windows DPAPI / Android Keystore)에 방별 네임스페이스로 래칫 상태를
/// 저장한다. 여러 기기 동기화를 안 하는 요구사항의 핵심 — 이 값들은 이 기기에만 있고, 서버에는
/// 절대 올라가지 않는다.
class SecretKeyStore {
  final FlutterSecureStorage _storage;
  SecretKeyStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  String _k(String roomId, String field) => 'secret/$roomId/$field';

  Future<void> saveChainState(String roomId, SecretChainState state) async {
    await _storage.write(
      key: _k(roomId, 'epoch'),
      value: state.epoch.toString(),
    );
    await _storage.write(key: _k(roomId, 'n'), value: state.n.toString());
    await _storage.write(
      key: _k(roomId, 'chainKey'),
      value: base64Encode(state.chainKey),
    );
    if (state.prevEpoch != null) {
      await _storage.write(
        key: _k(roomId, 'prevEpoch'),
        value: state.prevEpoch.toString(),
      );
    }
    if (state.prevChainKeySnapshot != null) {
      await _storage.write(
        key: _k(roomId, 'prevChainKeySnapshot'),
        value: base64Encode(state.prevChainKeySnapshot!),
      );
    }
  }

  Future<SecretChainState?> readChainState(String roomId) async {
    final epoch = await _storage.read(key: _k(roomId, 'epoch'));
    final n = await _storage.read(key: _k(roomId, 'n'));
    final chainKey = await _storage.read(key: _k(roomId, 'chainKey'));
    if (epoch == null || n == null || chainKey == null) return null;
    final prevEpoch = await _storage.read(key: _k(roomId, 'prevEpoch'));
    final prevChainKey = await _storage.read(
      key: _k(roomId, 'prevChainKeySnapshot'),
    );
    return SecretChainState(
      epoch: int.parse(epoch),
      n: int.parse(n),
      chainKey: base64Decode(chainKey),
      prevEpoch: prevEpoch != null ? int.parse(prevEpoch) : null,
      prevChainKeySnapshot: prevChainKey != null
          ? base64Decode(prevChainKey)
          : null,
    );
  }

  /// 핸드셰이크/재키잉 중에는 REST 왕복 사이 이 기기의 임시 개인키(시드)를 잠깐 들고 있어야
  /// 한다 — 상대가 응답하면 그때 공유비밀을 계산하고 즉시 지운다.
  Future<void> savePendingEphemeralSeed(String roomId, List<int> seed) =>
      _storage.write(
        key: _k(roomId, 'pendingEphemeralSeed'),
        value: base64Encode(seed),
      );

  Future<List<int>?> readPendingEphemeralSeed(String roomId) async {
    final v = await _storage.read(key: _k(roomId, 'pendingEphemeralSeed'));
    return v == null ? null : base64Decode(v);
  }

  Future<void> clearPendingEphemeralSeed(String roomId) =>
      _storage.delete(key: _k(roomId, 'pendingEphemeralSeed'));

  Future<void> savePendingRekeySeed(
    String roomId,
    int epoch,
    List<int> seed,
  ) async {
    await _storage.write(
      key: _k(roomId, 'pendingRekeyEpoch'),
      value: epoch.toString(),
    );
    await _storage.write(
      key: _k(roomId, 'pendingRekeySeed'),
      value: base64Encode(seed),
    );
  }

  Future<(int, List<int>)?> readPendingRekeySeed(String roomId) async {
    final epoch = await _storage.read(key: _k(roomId, 'pendingRekeyEpoch'));
    final seed = await _storage.read(key: _k(roomId, 'pendingRekeySeed'));
    if (epoch == null || seed == null) return null;
    return (int.parse(epoch), base64Decode(seed));
  }

  Future<void> clearPendingRekeySeed(String roomId) async {
    await _storage.delete(key: _k(roomId, 'pendingRekeyEpoch'));
    await _storage.delete(key: _k(roomId, 'pendingRekeySeed'));
  }

  /// 방 나가기/비밀 대화 거절 시 이 방의 모든 로컬 키 상태를 흔적 없이 지운다.
  Future<void> clearRoom(String roomId) async {
    for (final field in [
      'epoch',
      'n',
      'chainKey',
      'prevEpoch',
      'prevChainKeySnapshot',
      'pendingEphemeralSeed',
      'pendingRekeyEpoch',
      'pendingRekeySeed',
    ]) {
      await _storage.delete(key: _k(roomId, field));
    }
  }

  // ---- 복호화된 평문 캐시 ----
  //
  // 한 방향 래칫은 한 번 지나간 메시지의 키를 다시 계산할 수 없다(그게 순방향 비밀성의 핵심).
  // 그런데 채팅 화면은 방을 열 때마다(+재연결/앱 재시작 후) 서버에서 히스토리를 다시 받아와
  // 매번 복호화를 시도한다 — 그 시점의 로컬 래칫은 이미 최신 메시지 위치까지 전진해 있어서,
  // "이미 한 번 성공적으로 복호화했던" 과거 메시지들은 다시 시도하면 전부 실패한다(앱을
  // 재시작하면 그동안 주고받은 메시지가 전부 "복호화할 수 없음"으로 보이는 문제).
  // 그래서 메시지 하나를 처음 복호화하는 데 성공한 그 순간의 평문을 messageId로 이 기기에만
  // 영구 저장해두고, 이후에는(재시작해도) 암호문을 다시 복호화하지 않고 이 캐시를 그대로
  // 쓴다 — Session.decryptInPlace/decryptCommentInPlace 참고.
  Future<void> saveDecryptedText(String messageId, String text) =>
      _storage.write(key: 'secretmsg/$messageId', value: text);

  Future<String?> readDecryptedText(String messageId) =>
      _storage.read(key: 'secretmsg/$messageId');

  /// 메시지가 삭제되거나(수정/삭제 기능) 자동 삭제 타이머로 만료됐을 때, 로컬에 남아있는
  /// 평문 캐시도 함께 지운다 — 안 그러면 "삭제"가 이 기기에서는 사실 안 지워진 게 된다.
  Future<void> deleteDecryptedText(String messageId) =>
      _storage.delete(key: 'secretmsg/$messageId');
}
