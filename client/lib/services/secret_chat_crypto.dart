import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// 비밀 대화(E2EE)의 순수 암호화 로직 — 상태를 들고 있지 않고 항상 입력을 받아 출력만 낸다.
/// 상태(체인키/epoch/n)는 SecretKeyStore가, 핸드셰이크/재키잉 흐름은 SecretSessionManager가 맡는다.
///
/// 설계(계획서 참고): X25519 ECDH로 얻은 공유비밀을 HKDF로 체인키에 넣고, 메시지마다
/// "한 방향 해시 래칫"으로 새 체인키를 유도한 뒤 이전 체인키는 버린다(나중에 기기가 털려도
/// 과거 메시지는 복호화 불가 — 순방향 비밀성). 텔레그램 MTProto처럼 100개 메시지 또는 24시간마다
/// 새 X25519 임시키로 명시적 재키잉을 한다(시그널의 매 메시지 DH 래칫보다는 단순한 모델).

const rekeyMessageThreshold = 100;
const rekeyTimeThreshold = Duration(hours: 24);
const _maxCatchUpSteps = 500; // 오프라인 중 놓친 이전 epoch 메시지를 뒤쫓아갈 때의 상한.

final _x25519 = X25519();
final _ed25519 = Ed25519();
final _hkdf32 = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
final _aesGcm = AesGcm.with256bits();
final _sha256 = Sha256();

Future<List<int>> _saltFor(String roomId) async =>
    (await _sha256.hash(utf8.encode('secretchat-v1|$roomId'))).bytes;

Future<List<int>> _hkdf(List<int> ikm, List<int> salt, String info) async {
  final key = await _hkdf32.deriveKey(
    secretKey: SecretKey(ikm),
    nonce: salt,
    info: utf8.encode(info),
  );
  return key.extractBytes();
}

/// 핸드셰이크 성립 시 최초 체인키 — 양쪽이 같은 두 임시 공개키로부터 각자 독립적으로 계산해도
/// 항상 같은 값이 나온다(ECDH 대칭성 + 결정적 HKDF).
Future<List<int>> deriveInitialChainKey({
  required SimpleKeyPair myEphemeralKeyPair,
  required SimplePublicKey theirEphemeralPublicKey,
  required String roomId,
}) async {
  final shared = await _x25519.sharedSecretKey(
    keyPair: myEphemeralKeyPair,
    remotePublicKey: theirEphemeralPublicKey,
  );
  final ikm = await shared.extractBytes();
  final salt = await _saltFor(roomId);
  return _hkdf(ikm, salt, 'secretchat-init-chain-key-v1');
}

/// 재키잉: 새 공유비밀(Z')과 "재키잉 직전 체인키의 마지막 값"을 함께 섞어서, DH가 주는
/// 순방향비밀성과 기존 래칫의 연속성을 모두 가져간다.
Future<List<int>> deriveRekeyChainKey({
  required SimpleKeyPair myNewEphemeralKeyPair,
  required SimplePublicKey theirNewEphemeralPublicKey,
  required List<int> previousChainKeyLastValue,
  required int newEpoch,
}) async {
  final shared = await _x25519.sharedSecretKey(
    keyPair: myNewEphemeralKeyPair,
    remotePublicKey: theirNewEphemeralPublicKey,
  );
  final ikm = await shared.extractBytes();
  return _hkdf(
    ikm,
    previousChainKeyLastValue,
    'secretchat-rekey-v1|epoch=$newEpoch',
  );
}

class RatchetStep {
  final List<int> msgKey;
  final List<int> nextChainKey;
  const RatchetStep(this.msgKey, this.nextChainKey);
}

/// 한 방향 해시 래칫 한 걸음. 호출자는 반환된 msgKey로 이번 메시지를 암/복호화하고,
/// nextChainKey로 저장을 갱신한 뒤 이번 chainKey는 폐기해야 한다(그래야 순방향 비밀성이 성립).
Future<RatchetStep> ratchetStep(List<int> chainKey) async {
  final msgKey = await _hkdf(chainKey, const [], 'secretchat-msg-key-v1');
  final nextChainKey = await _hkdf(
    chainKey,
    const [],
    'secretchat-chain-advance-v1',
  );
  return RatchetStep(msgKey, nextChainKey);
}

/// n 단계만큼 순방향으로 래칫을 감아서 목표 메시지 키를 구한다(재키잉을 놓쳤던 이전 epoch의
/// 메시지 뒤쫓아가기용). steps가 너무 크면(변조/오류) 계산을 포기한다.
Future<List<int>?> catchUpTo(List<int> chainKey, int steps) async {
  if (steps < 0 || steps > _maxCatchUpSteps) return null;
  var key = chainKey;
  for (var i = 0; i < steps; i++) {
    key = (await ratchetStep(key)).nextChainKey;
  }
  return (await ratchetStep(key)).msgKey;
}

/// 메시지/댓글 text에 저장되는 암호문 봉투. 서버는 이 JSON을 opaque한 문자열로만 취급한다.
Future<Map<String, dynamic>> encryptEnvelope({
  required List<int> msgKey,
  required String plainText,
  required String roomId,
  required int epoch,
  required int n,
}) async {
  final nonce = _aesGcm.newNonce();
  final aad = utf8.encode('$roomId|$epoch|$n');
  final box = await _aesGcm.encrypt(
    utf8.encode(plainText),
    secretKey: SecretKey(msgKey),
    nonce: nonce,
    aad: aad,
  );
  final combined = Uint8List.fromList([...box.cipherText, ...box.mac.bytes]);
  return {
    'v': 1,
    'epoch': epoch,
    'n': n,
    'nonce': base64Encode(nonce),
    'ciphertext': base64Encode(combined),
  };
}

/// 복호화 실패(다른 세션/다른 기기/변조 등)하면 null을 돌려준다 — 호출자는 Message.decryptFailed로
/// 표시해 "복호화할 수 없습니다" 플레이스홀더를 보여준다.
Future<String?> decryptEnvelope({
  required List<int> msgKey,
  required Map<String, dynamic> envelope,
  required String roomId,
}) async {
  try {
    final epoch = envelope['epoch'] as int;
    final n = envelope['n'] as int;
    final nonce = base64Decode(envelope['nonce'] as String);
    final combined = base64Decode(envelope['ciphertext'] as String);
    if (combined.length < 16) return null;
    final cipherText = combined.sublist(0, combined.length - 16);
    final mac = Mac(combined.sublist(combined.length - 16));
    final aad = utf8.encode('$roomId|$epoch|$n');
    final plainBytes = await _aesGcm.decrypt(
      SecretBox(cipherText, nonce: nonce, mac: mac),
      secretKey: SecretKey(msgKey),
      aad: aad,
    );
    return utf8.decode(plainBytes);
  } catch (_) {
    return null;
  }
}

/// 첨부파일(이미지/파일) 암호화 — 방의 래칫과는 독립적인, 파일 하나마다 새로 만드는 랜덤 키.
class EncryptedAttachment {
  final Uint8List cipherBytes; // 업로드할 실제 바이트(암호문+태그) — 서버는 opaque 블롭으로만 취급.
  final String keyBase64;
  final String nonceBase64;
  const EncryptedAttachment(this.cipherBytes, this.keyBase64, this.nonceBase64);
}

Future<EncryptedAttachment> encryptAttachment(Uint8List plainBytes) async {
  final secretKey = await _aesGcm.newSecretKey();
  final nonce = _aesGcm.newNonce();
  final box = await _aesGcm.encrypt(
    plainBytes,
    secretKey: secretKey,
    nonce: nonce,
  );
  final combined = Uint8List.fromList([...box.cipherText, ...box.mac.bytes]);
  final keyBytes = await secretKey.extractBytes();
  return EncryptedAttachment(
    combined,
    base64Encode(keyBytes),
    base64Encode(nonce),
  );
}

Future<Uint8List?> decryptAttachment({
  required Uint8List cipherBytes,
  required String keyBase64,
  required String nonceBase64,
}) async {
  try {
    if (cipherBytes.length < 16) return null;
    final cipherText = cipherBytes.sublist(0, cipherBytes.length - 16);
    final mac = Mac(cipherBytes.sublist(cipherBytes.length - 16));
    final plainBytes = await _aesGcm.decrypt(
      SecretBox(cipherText, nonce: base64Decode(nonceBase64), mac: mac),
      secretKey: SecretKey(base64Decode(keyBase64)),
    );
    return Uint8List.fromList(plainBytes);
  } catch (_) {
    return null;
  }
}

/// 핸드셰이크/재키잉의 임시 공개키를 기기 장기 신원키(Ed25519)로 서명 — 서버가 (해킹되거나
/// 악의적으로) 임시 공개키를 바꿔치기하는 중간자 공격을 막는다. 안전번호 비교 UI 없이 이
/// 서명 검증만 자동으로 한다(사용자가 확정한 절충).
Future<String> signEphemeralKey(
  SimpleKeyPair signingKeyPair,
  List<int> ephemeralPublicKeyBytes,
) async {
  final signature = await _ed25519.sign(
    ephemeralPublicKeyBytes,
    keyPair: signingKeyPair,
  );
  return base64Encode(signature.bytes);
}

Future<bool> verifyEphemeralKey({
  required String signingPublicKeyBase64,
  required List<int> ephemeralPublicKeyBytes,
  required String signatureBase64,
}) async {
  try {
    final publicKey = SimplePublicKey(
      base64Decode(signingPublicKeyBase64),
      type: KeyPairType.ed25519,
    );
    final signature = Signature(
      base64Decode(signatureBase64),
      publicKey: publicKey,
    );
    return await _ed25519.verify(ephemeralPublicKeyBytes, signature: signature);
  } catch (_) {
    return false;
  }
}
