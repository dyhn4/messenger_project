import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import '../models/room.dart';
import 'api_client.dart';
import 'chat_socket.dart';
import 'device_identity.dart';
import 'secret_chat_crypto.dart' as crypto;
import 'secret_key_store.dart';

/// 비밀 대화(E2EE) 방 하나의 핸드셰이크/재키잉 상태 머신. 공유비밀/체인키 계산은 전부 여기서
/// 로컬로만 이뤄지고, 서버로는 공개키/서명만 나간다. Session이 메시지 송수신 경계에서 이
/// 매니저의 encryptForRoom/decryptForRoom을 호출하는 얇은 통합만 한다.
class SecretSessionManager {
  final ApiClient _api;
  final ChatSocket _socket;
  final DeviceIdentity _identity;
  final SecretKeyStore _keyStore = SecretKeyStore();

  // deviceId -> signingPublicKey 캐시(핸드셰이크마다 서버에 새로 물어보지 않도록).
  final Map<String, String> _signingKeyCache = {};

  // roomId -> 상대방 기기의 deviceId. 비밀 대화는 방 하나에 기기 쌍이 고정이라(여러 기기
  // 동기화 없음) 재키잉 이벤트(userId만 실려옴)가 왔을 때 서명 검증키를 조회할 deviceId를
  // 여기서 찾는다 — 여러 비밀 대화방을 동시에 쓸 때 서로 다른 상대 기기를 구분하기 위해 필요.
  final Map<String, String> _otherDeviceIdForRoom = {};

  // 재키잉 트리거 판단용 — 방마다 이번 epoch에서 처리한 메시지 수/epoch 시작 시각.
  final Map<String, int> _epochMessageCount = {};
  final Map<String, DateTime> _epochStartedAt = {};

  // "roomId|epoch|n" -> 내가 방금 보낸 평문. encryptForRoom은 전송 즉시 로컬 체인키를
  // 한 칸 전진시켜 저장하는데(다음 메시지를 위해), 서버가 그 메시지를 내 소켓에도 그대로
  // 되돌려주면(다른 멤버들과 동일하게 echo됨) 그 시점엔 이미 내 state.n이 그 메시지의 n보다
  // 앞서 있어서 한 방향 래칫으로는 "뒤로" 못 감는다(의도된 동작 — 순방향 비밀성의 핵심).
  // 그래서 내가 보낸 메시지만 예외적으로 여기 잠깐 캐싱해뒀다가, echo가 돌아오면 바로 이걸
  // 돌려준다(래칫 상태는 건드리지 않음 — 이미 encryptForRoom에서 전진시켰으므로).
  final Map<String, String> _recentlySentPlaintext = {};

  String _envelopeCacheKey(String roomId, int epoch, int n) =>
      '$roomId|$epoch|$n';

  SecretSessionManager(this._api, this._socket, this._identity);

  Future<String> _signingKeyFor(String deviceId) async {
    return _signingKeyCache[deviceId] ??= await _api
        .fetchDeviceSigningPublicKey(deviceId);
  }

  /// 내가 상대에게 비밀 대화를 걸 때. 방이 만들어진 뒤 서버가 돌려준 roomId로 임시키를 저장한다.
  Future<Room> startSecretChat(String targetUserId) async {
    final ephemeral = await X25519().newKeyPair();
    final ephemeralPublicKey = await publicKeyBase64(ephemeral);
    final signature = await crypto.signEphemeralKey(
      _identity.signingKeyPair,
      base64Decode(ephemeralPublicKey),
    );

    final room = await _api.startSecretChat(
      targetUserId: targetUserId,
      deviceId: _identity.deviceId,
      initiatorEphemeralPublicKey: ephemeralPublicKey,
      initiatorEphemeralSignature: signature,
    );
    await _keyStore.savePendingEphemeralSeed(
      room.id,
      await ephemeral.extractPrivateKeyBytes(),
    );
    return room;
  }

  /// 상대의 초대(secret:invite)를 수락한다 — 서명을 먼저 검증하고, 통과해야만 진행한다.
  Future<bool> acceptInvite(SecretInviteEvent invite) async {
    final theirEphemeralBytes = base64Decode(
      invite.initiatorEphemeralPublicKey,
    );
    final signingKey = await _signingKeyFor(invite.initiatorDeviceId);
    final verified = await crypto.verifyEphemeralKey(
      signingPublicKeyBase64: signingKey,
      ephemeralPublicKeyBytes: theirEphemeralBytes,
      signatureBase64: invite.initiatorEphemeralSignature,
    );
    if (!verified) return false; // 서버가 키를 바꿔치기했거나 변조됨 — 절대 진행하지 않는다.
    _otherDeviceIdForRoom[invite.roomId] = invite.initiatorDeviceId;

    final myEphemeral = await X25519().newKeyPair();
    final myEphemeralPublicKey = await publicKeyBase64(myEphemeral);
    final mySignature = await crypto.signEphemeralKey(
      _identity.signingKeyPair,
      base64Decode(myEphemeralPublicKey),
    );

    final chainKey = await crypto.deriveInitialChainKey(
      myEphemeralKeyPair: myEphemeral,
      theirEphemeralPublicKey: SimplePublicKey(
        theirEphemeralBytes,
        type: KeyPairType.x25519,
      ),
      roomId: invite.roomId,
    );
    await _keyStore.saveChainState(
      invite.roomId,
      SecretChainState(epoch: 0, n: 0, chainKey: chainKey),
    );
    _epochMessageCount[invite.roomId] = 0;
    _epochStartedAt[invite.roomId] = DateTime.now();

    await _api.acceptSecretChat(
      roomId: invite.roomId,
      deviceId: _identity.deviceId,
      responderEphemeralPublicKey: myEphemeralPublicKey,
      responderEphemeralSignature: mySignature,
    );
    return true;
  }

  Future<void> rejectInvite(String roomId) async {
    await _api.rejectSecretChat(roomId);
    await _keyStore.clearRoom(roomId);
  }

  /// 상대가 내 초대를 수락했다는 브로드캐스트(secret:accepted)를 받았을 때 — 이제 나도 체인키를
  /// 계산할 수 있다(내가 처음 만들었던 임시 개인키 + 상대의 임시 공개키).
  Future<void> handleAccepted(SecretAcceptedEvent event) async {
    final myPendingSeed = await _keyStore.readPendingEphemeralSeed(
      event.roomId,
    );
    if (myPendingSeed == null) return; // 이미 처리됐거나 이 기기가 초대자가 아님.

    final signingKey = await _signingKeyFor(event.responderDeviceId);
    final theirEphemeralBytes = base64Decode(event.responderEphemeralPublicKey);
    final verified = await crypto.verifyEphemeralKey(
      signingPublicKeyBase64: signingKey,
      ephemeralPublicKeyBytes: theirEphemeralBytes,
      signatureBase64: event.responderEphemeralSignature,
    );
    if (!verified) return;
    _otherDeviceIdForRoom[event.roomId] = event.responderDeviceId;

    final myEphemeral = await X25519().newKeyPairFromSeed(myPendingSeed);
    final chainKey = await crypto.deriveInitialChainKey(
      myEphemeralKeyPair: myEphemeral,
      theirEphemeralPublicKey: SimplePublicKey(
        theirEphemeralBytes,
        type: KeyPairType.x25519,
      ),
      roomId: event.roomId,
    );
    await _keyStore.saveChainState(
      event.roomId,
      SecretChainState(epoch: 0, n: 0, chainKey: chainKey),
    );
    await _keyStore.clearPendingEphemeralSeed(event.roomId);
    _epochMessageCount[event.roomId] = 0;
    _epochStartedAt[event.roomId] = DateTime.now();
  }

  Future<bool> hasActiveSession(String roomId) async =>
      await _keyStore.readChainState(roomId) != null;

  /// 이미 한 번 복호화에 성공한 메시지/댓글의 평문을 messageId로 재사용한다(한 방향 래칫이라
  /// 두 번째부터는 암호문을 다시 복호화할 수 없기 때문 — secret_key_store.dart 참고).
  Future<String?> readCachedDecryptedText(String messageId) =>
      _keyStore.readDecryptedText(messageId);

  Future<void> cacheDecryptedText(String messageId, String text) =>
      _keyStore.saveDecryptedText(messageId, text);

  Future<void> forgetDecryptedText(String messageId) =>
      _keyStore.deleteDecryptedText(messageId);

  /// 메시지/댓글 전송 직전 — 평문을 암호문 봉투(JSON)로 바꾸고, 필요하면 재키잉을 함께 트리거한다.
  /// 세션이 아직 성립되지 않았으면(핸드셰이크 진행 중) null을 돌려준다 — 호출자는 전송을 보류해야 한다.
  Future<String?> encryptForRoom(String roomId, String plainText) async {
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
  }

  /// 수신한 암호문 봉투를 평문으로. 실패(다른 세션/변조/너무 오래된 epoch)하면 null.
  Future<String?> decryptForRoom(String roomId, String envelopeJson) async {
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
    } else if (state.prevEpoch == epoch && state.prevChainKeySnapshot != null) {
      msgKey = await crypto.catchUpTo(state.prevChainKeySnapshot!, n);
    }
    if (msgKey == null) return null;

    return crypto.decryptEnvelope(
      msgKey: msgKey,
      envelope: envelope,
      roomId: roomId,
    );
  }

  Future<void> _maybeTriggerRekey(String roomId, int currentEpoch) async {
    final count = (_epochMessageCount[roomId] ?? 0) + 1;
    _epochMessageCount[roomId] = count;
    final startedAt = _epochStartedAt[roomId] ??= DateTime.now();
    final dueByCount = count >= crypto.rekeyMessageThreshold;
    final dueByTime =
        DateTime.now().difference(startedAt) >= crypto.rekeyTimeThreshold;
    if (!dueByCount && !dueByTime) return;

    final newEpoch = currentEpoch + 1;
    final ephemeral = await X25519().newKeyPair();
    final ephemeralPublicKey = await publicKeyBase64(ephemeral);
    final signature = await crypto.signEphemeralKey(
      _identity.signingKeyPair,
      base64Decode(ephemeralPublicKey),
    );
    await _keyStore.savePendingRekeySeed(
      roomId,
      newEpoch,
      await ephemeral.extractPrivateKeyBytes(),
    );
    _socket.proposeSecretRekey(
      roomId: roomId,
      keyEpoch: newEpoch,
      ephemeralPublicKey: ephemeralPublicKey,
      ephemeralSignature: signature,
    );
  }

  /// 상대가 재키잉을 제안했을 때 — 서명 검증 후 내 임시키로 응답(ack)한다.
  Future<void> handleRekeyPropose(SecretRekeyEvent event) async {
    final state = await _keyStore.readChainState(event.roomId);
    if (state == null) return;

    final device = _otherDeviceIdForRoom[event.roomId];
    if (device == null) return; // 세션이 성립되지 않은 방에서 온 재키잉 — 무시.

    // 동시 제안 충돌: 상대와 내가 근접한 시점에 각자 제안했다면 deviceId 사전순으로 낮은
    // 쪽이 이긴다 — 내가 이미 같은 epoch로 제안 중이고 내 deviceId가 더 작으면(=우선순위가
    // 높으면) 내 제안을 유지하고 상대 제안은 무시한다.
    final myPending = await _keyStore.readPendingRekeySeed(event.roomId);
    if (myPending != null && myPending.$1 == event.keyEpoch) {
      if (_identity.deviceId.compareTo(device) < 0) {
        return; // 내가 우선 — 상대가 내 제안에 ack하기를 기다린다.
      }
      await _keyStore.clearPendingRekeySeed(
        event.roomId,
      ); // 내 제안을 접고 상대 걸 받아들인다.
    }
    final signingKey = await _signingKeyFor(device);
    final theirEphemeralBytes = base64Decode(event.ephemeralPublicKey);
    final verified = await crypto.verifyEphemeralKey(
      signingPublicKeyBase64: signingKey,
      ephemeralPublicKeyBytes: theirEphemeralBytes,
      signatureBase64: event.ephemeralSignature,
    );
    if (!verified) return;

    final myEphemeral = await X25519().newKeyPair();
    final myEphemeralPublicKey = await publicKeyBase64(myEphemeral);
    final mySignature = await crypto.signEphemeralKey(
      _identity.signingKeyPair,
      base64Decode(myEphemeralPublicKey),
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
      event.roomId,
      SecretChainState(
        epoch: event.keyEpoch,
        n: 0,
        chainKey: newChainKey,
        prevEpoch: state.epoch,
        prevChainKeySnapshot: state.chainKey,
      ),
    );
    _epochMessageCount[event.roomId] = 0;
    _epochStartedAt[event.roomId] = DateTime.now();

    _socket.ackSecretRekey(
      roomId: event.roomId,
      keyEpoch: event.keyEpoch,
      ephemeralPublicKey: myEphemeralPublicKey,
      ephemeralSignature: mySignature,
    );
  }

  /// 내가 먼저 제안했던 재키잉을 상대가 수락(ack)했을 때 — 이제 나도 새 체인키를 계산한다.
  Future<void> handleRekeyAck(SecretRekeyEvent event) async {
    final pending = await _keyStore.readPendingRekeySeed(event.roomId);
    if (pending == null || pending.$1 != event.keyEpoch) return;
    final state = await _keyStore.readChainState(event.roomId);
    if (state == null) return;

    final device = _otherDeviceIdForRoom[event.roomId];
    if (device == null) return; // 세션이 성립되지 않은 방에서 온 재키잉 — 무시.
    final signingKey = await _signingKeyFor(device);
    final theirEphemeralBytes = base64Decode(event.ephemeralPublicKey);
    final verified = await crypto.verifyEphemeralKey(
      signingPublicKeyBase64: signingKey,
      ephemeralPublicKeyBytes: theirEphemeralBytes,
      signatureBase64: event.ephemeralSignature,
    );
    if (!verified) return;

    final myEphemeral = await X25519().newKeyPairFromSeed(pending.$2);
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
      event.roomId,
      SecretChainState(
        epoch: event.keyEpoch,
        n: 0,
        chainKey: newChainKey,
        prevEpoch: state.epoch,
        prevChainKeySnapshot: state.chainKey,
      ),
    );
    await _keyStore.clearPendingRekeySeed(event.roomId);
    _epochMessageCount[event.roomId] = 0;
    _epochStartedAt[event.roomId] = DateTime.now();
  }

  Future<void> forgetRoom(String roomId) async {
    await _keyStore.clearRoom(roomId);
    _epochMessageCount.remove(roomId);
    _epochStartedAt.remove(roomId);
    _otherDeviceIdForRoom.remove(roomId);
    _recentlySentPlaintext.removeWhere((key, _) => key.startsWith('$roomId|'));
  }
}
