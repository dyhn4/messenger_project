import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import '../l10n/tr.dart';

/// 비밀 대화(E2EE)의 순수 암호화 로직 — 상태를 들고 있지 않고 항상 입력을 받아 출력만 낸다.
/// 상태는 SecretKeyStore가, 핸드셰이크 흐름과 규약 고르기는 SecretSessionManager가, 새 규약(v3)의 래칫 한 걸음은
/// secret_ratchet.dart가 맡는다.
///
/// 규약은 두 가지다.
///  - 예전 규약(v1): X25519 ECDH로 얻은 공유비밀을 HKDF로 체인키에 넣고, 메시지마다 "한 방향 해시 래칫"으로 새
///    체인키를 유도한 뒤 이전 체인키는 버린다(순방향 비밀성). 다만 두 사람이 체인 하나를 함께 써서, 거의 동시에
///    보낸 두 메시지가 같은 번호·같은 키를 쓰고, 100개·24시간마다 하던 재키잉은 서로의 체인 위치가 조금만 어긋나도
///    양쪽 체인이 갈라져 대화가 깨졌다. 그래서 이제 재키잉은 하지 않고(secret_session_manager.dart), 이 규약은
///    예전 앱과 이미 맺은 대화에만 쓴다.
///  - 새 규약(v3): 시그널의 더블 래칫. 보내는 쪽마다 체인이 따로 있고, 메시지마다 보낸 쪽의 래칫 공개키가 실려
///    상대가 새 키를 처음 보면 새 X25519 공유비밀로 루트키를 한 걸음 나아간다(재키잉 신호가 따로 없어서 순서가
///    엇갈려도 양쪽이 같은 키에 닿는다). 늦게 온 메시지의 키는 정해진 개수까지만 남겨 둔다.

/// 예전 규약(v1)에서 오프라인 중 놓친 메시지를 뒤쫓아갈 때의 상한 — 이 안의 키는 늦게 올 메시지를 위해 남겨 둔다.
const v1MaxCatchUpSteps = 2000;

final _x25519 = X25519();
final _ed25519 = Ed25519();
final _hkdf32 = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
final _hkdf64 = Hkdf(hmac: Hmac.sha256(), outputLength: 64);
final _hmacSha256 = Hmac.sha256();
final _aesGcm = AesGcm.with256bits();
final _sha256 = Sha256();
final _sha512 = Sha512();

/// 표준 base64(패딩까지 — 앱의 base64Encode가 만드는 모양) 그대로인지. dart:convert의 base64Decode는 URL 안전 글자(-_)와
/// `%3D` 패딩도 읽어서, 같은 바이트를 다른 글자로 적은 값(서버가 바꿔 끼운 것)을 가르려면 다시 인코딩해 견준다.
bool isCanonicalBase64(String value) {
  try {
    return base64Encode(base64Decode(value)) == value;
  } on FormatException {
    return false;
  }
}

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
  if (steps < 0 || steps > v1MaxCatchUpSteps) return null;
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
/// 악의적으로) 임시 공개키를 바꿔치기하는 중간자 공격을 막는다.
///
/// 이것은 키 바이트만 서명하는 예전 형식(v1)이다 — 어느 방·누구·몇 번째 재키잉의 키인지는 서명에 들어가지
/// 않아서, 서버가 서명된 키를 다른 세션에 다시 끼워 넣어도 서명은 맞는다. 그래서 지금은 아래 맥락 서명(v2)을
/// 함께 보내고 상대가 v2를 보냈으면 v2만 확인한다. v1은 예전 앱이 계속 확인할 수 있게 함께 보낸다.
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

// ---- 맥락 서명(v2) ----
//
// 임시 공개키만이 아니라 "어느 방에서, 누가(사용자·기기), 누구에게, 몇 번째 키로" 낸 키인지까지 한 줄로 이어
// 서명한다 — 서버가 서명된 키를 다른 방·다른 epoch·다른 상대에게 다시 끼워 넣으면 받는 쪽이 만든 맥락과 달라
// 검증이 실패한다. 받는 쪽은 서버가 준 값이 아니라 자기가 아는(자기 id, 고정해 둔 상대 기기, 방 id, epoch,
// 자기 임시키) 값으로 맥락을 다시 만들어 확인한다. 형식은 서버와 함께 정한 약속이라 글자 하나도 바꾸면 안
// 된다(공개키는 전송한 base64 문자열 그대로, id는 서버가 쓰는 문자열 그대로, '|'로 잇는다).

/// 맥락 서명 문자열의 머리 — 이 앱 비밀 대화의 v2 서명이라는 표시(다른 용도의 서명과 섞이지 않게).
const secretContextPrefix = 'tangotalk-secret-v2';

/// 맥락의 칸 하나 — '|'가 들어 있으면 칸 경계가 흐려져(서로 다른 값 묶음이 같은 문자열이 될 수 있다) 받지 않는다.
/// 실제 id(uuid)·base64 키·epoch에는 '|'가 없다. 서명 확인 쪽은 이 예외를 "검증 실패"로 다룬다.
String _contextField(String value) {
  if (value.contains('|')) {
    throw ArgumentError.value(value, 'value', tr('맥락 서명 칸에는 \'|\'를 쓸 수 없습니다'));
  }
  return value;
}

String _context(List<String> fields) =>
    [secretContextPrefix, for (final f in fields) _contextField(f)].join('|');

/// 초대(비밀 대화 시작) — 방이 아직 없을 때 서명하므로 방 id 대신 받는 사람을 넣는다.
String secretInitContext({
  required String initiatorUserId,
  required String initiatorDeviceId,
  required String responderUserId,
  required String initiatorEphemeralPublicKey,
}) => _context([
  'init',
  initiatorUserId,
  initiatorDeviceId,
  responderUserId,
  initiatorEphemeralPublicKey,
]);

/// 수락 — 방 id와 양쪽 사용자·기기·임시키를 모두 묶는다(초대자는 자기 임시키가 들어 있어야 믿는다).
String secretAcceptContext({
  required String roomId,
  required String initiatorUserId,
  required String initiatorDeviceId,
  required String initiatorEphemeralPublicKey,
  required String responderUserId,
  required String responderDeviceId,
  required String responderEphemeralPublicKey,
}) => _context([
  'accept',
  roomId,
  initiatorUserId,
  initiatorDeviceId,
  initiatorEphemeralPublicKey,
  responderUserId,
  responderDeviceId,
  responderEphemeralPublicKey,
]);

/// 재키잉 제안 — 방 id와 새 epoch를 묶어 지난 제안을 다시 보내도(재전송) 다른 epoch로는 통하지 않게 한다.
String secretRekeyProposeContext({
  required String roomId,
  required int keyEpoch,
  required String proposerUserId,
  required String proposerDeviceId,
  required String proposerEphemeralPublicKey,
}) => _context([
  'rekey-propose',
  roomId,
  '$keyEpoch',
  proposerUserId,
  proposerDeviceId,
  proposerEphemeralPublicKey,
]);

/// 재키잉 수락 — 제안자의 임시키까지 묶어, 이 응답이 바로 그 제안에 대한 것임을 보인다.
String secretRekeyAckContext({
  required String roomId,
  required int keyEpoch,
  required String responderUserId,
  required String responderDeviceId,
  required String proposerEphemeralPublicKey,
  required String responderEphemeralPublicKey,
}) => _context([
  'rekey-ack',
  roomId,
  '$keyEpoch',
  responderUserId,
  responderDeviceId,
  proposerEphemeralPublicKey,
  responderEphemeralPublicKey,
]);

/// 맥락 문자열(UTF-8)을 기기 장기 서명키(Ed25519)로 서명한다(base64, 64바이트).
Future<String> signContext(SimpleKeyPair signingKeyPair, String context) async {
  final signature = await _ed25519.sign(
    utf8.encode(context),
    keyPair: signingKeyPair,
  );
  return base64Encode(signature.bytes);
}

/// 맥락 서명을 확인한다 — 키·서명 모양이 틀리거나(길이·base64) 맞지 않으면 false.
Future<bool> verifyContext({
  required String signingPublicKeyBase64,
  required String context,
  required String signatureBase64,
}) async {
  try {
    final publicKeyBytes = base64Decode(signingPublicKeyBase64);
    final signatureBytes = base64Decode(signatureBase64);
    if (publicKeyBytes.length != 32 || signatureBytes.length != 64) {
      return false;
    }
    return await _ed25519.verify(
      utf8.encode(context),
      signature: Signature(
        signatureBytes,
        publicKey: SimplePublicKey(publicKeyBytes, type: KeyPairType.ed25519),
      ),
    );
  } catch (_) {
    return false;
  }
}

// ---- 새 규약(v3) — 더블 래칫 ----
//
// 핸드셰이크(초대·수락의 임시키 두 개)로 루트키를 만들고, 그 뒤로는 secret_ratchet.dart가 메시지마다 아래 함수로
// 한 걸음씩 나아간다. 초대할 때 "v3를 안다"고 알리고(서버의 initiatorProtocol), 받는 쪽이 v3로 수락하면 수락 맥락
// 서명을 v3 머리([secretContextPrefixV3])로 만든다 — 초대한 쪽은 v3 맥락이 맞을 때만 v3로 대화한다(서버가 맥락을
// 바꿔 끼우면 어느 쪽 서명도 맞지 않는다). 형식은 양쪽 앱의 약속이라 글자 하나도 바꾸면 안 된다.

/// 새 규약 번호 — 초대에 실어 보내고(api_client startSecretChat), 이 번호 이상을 아는 초대만 v3로 수락한다.
const secretProtocolV3 = 3;

/// v3 맥락 문자열의 머리 — v2([secretContextPrefix])와 섞이지 않게 따로 둔다.
const secretContextPrefixV3 = 'tangotalk-secret-v3';

String _contextV3(List<String> fields) =>
    [secretContextPrefixV3, for (final f in fields) _contextField(f)].join('|');

/// v3 수락 — 칸은 v2 수락([secretAcceptContext])과 같고 머리만 다르다. 이 서명이 맞으면 받는 쪽이 v3로 대화를
/// 시작했다는 뜻이다.
String secretAcceptContextV3({
  required String roomId,
  required String initiatorUserId,
  required String initiatorDeviceId,
  required String initiatorEphemeralPublicKey,
  required String responderUserId,
  required String responderDeviceId,
  required String responderEphemeralPublicKey,
}) => _contextV3([
  'accept',
  roomId,
  initiatorUserId,
  initiatorDeviceId,
  initiatorEphemeralPublicKey,
  responderUserId,
  responderDeviceId,
  responderEphemeralPublicKey,
]);

/// 루트키를 만들 때 함께 넣는 핸드셰이크 기록 — 양쪽 사용자·기기·임시키를 모두 묶어, 같은 공유비밀이라도 다른
/// 대화·다른 상대로는 같은 루트키가 나오지 않게 한다.
String secretRootTranscriptV3({
  required String roomId,
  required String initiatorUserId,
  required String initiatorDeviceId,
  required String initiatorEphemeralPublicKey,
  required String responderUserId,
  required String responderDeviceId,
  required String responderEphemeralPublicKey,
}) => _contextV3([
  'root',
  roomId,
  initiatorUserId,
  initiatorDeviceId,
  initiatorEphemeralPublicKey,
  responderUserId,
  responderDeviceId,
  responderEphemeralPublicKey,
]);

/// X25519 공유비밀 — 상대 공개키가 작은 차수의 점 같은 이상한 값이라 결과가 0뿐이면 null(그런 키는 받지 않는다).
Future<List<int>?> x25519SharedSecret(
  SimpleKeyPair mine,
  List<int> theirPublicKey,
) async {
  final shared = await _x25519.sharedSecretKey(
    keyPair: mine,
    remotePublicKey: SimplePublicKey(theirPublicKey, type: KeyPairType.x25519),
  );
  final bytes = await shared.extractBytes();
  return bytes.every((b) => b == 0) ? null : bytes;
}

/// 핸드셰이크의 두 임시키로 만드는 첫 루트키 — 양쪽이 각자 계산해도 같다. 공유비밀이 0뿐이면 null.
Future<List<int>?> deriveRootKeyV3({
  required SimpleKeyPair myEphemeralKeyPair,
  required List<int> theirEphemeralPublicKey,
  required String roomId,
  required String transcript,
}) async {
  final shared = await x25519SharedSecret(
    myEphemeralKeyPair,
    theirEphemeralPublicKey,
  );
  if (shared == null) return null;
  final salt = (await _sha256.hash(
    utf8.encode('$secretContextPrefixV3|root-salt|$roomId'),
  )).bytes;
  return _hkdf(shared, salt, transcript);
}

/// 받는 쪽(수락한 기기)이 첫 래칫 전에 보내는 "0번 체인" — 초대한 쪽이 먼저 보내든 받는 쪽이 먼저 보내든 바로
/// 보낼 수 있게, 받는 쪽의 첫 체인은 루트키에서 바로 만든다(secret_ratchet.dart 참고).
Future<List<int>> deriveResponderInitialChainV3(List<int> rootKey) =>
    _hkdf(rootKey, const [], '$secretContextPrefixV3|chain0');

/// 루트 체인 한 걸음 — 지금 루트키와 새 X25519 공유비밀로 (새 루트키, 새 체인키).
Future<(List<int>, List<int>)> kdfRootV3(
  List<int> rootKey,
  List<int> dhOutput,
) async {
  final key = await _hkdf64.deriveKey(
    secretKey: SecretKey(dhOutput),
    nonce: rootKey,
    info: utf8.encode('$secretContextPrefixV3|root-step'),
  );
  final bytes = await key.extractBytes();
  return (bytes.sublist(0, 32), bytes.sublist(32, 64));
}

/// 메시지 체인 한 걸음 — (이 메시지의 키, 다음 체인키). 쓴 체인키는 버려야 순방향 비밀성이 선다.
Future<RatchetStep> kdfChainV3(List<int> chainKey) async {
  final secret = SecretKey(chainKey);
  final msgKey = await _hmacSha256.calculateMac(const [1], secretKey: secret);
  final next = await _hmacSha256.calculateMac(const [2], secretKey: secret);
  return RatchetStep(msgKey.bytes, next.bytes);
}

/// v3 봉투의 머리 — 보낸 쪽([sender] — 'i' 초대한 기기, 'r' 수락한 기기), 보낸 쪽의 래칫 공개키, 그 직전 체인에서
/// 보낸 수([previousCount]), 이 체인에서의 번호([n]). 모두 AAD로 묶여 바꾸면 풀리지 않는다.
String _aadV3({
  required String roomId,
  required String sender,
  required String ratchetPublicKey,
  required int previousCount,
  required int n,
}) =>
    '$secretContextPrefixV3|msg|$roomId|$sender|$ratchetPublicKey|$previousCount|$n';

/// v3 메시지 암호문 봉투. 'epoch'는 예전 앱이 봉투를 읽다 멈추지 않게 두는 자리값이다(예전 앱 기기에는 이 대화의
/// 키가 없어서 "복호화할 수 없음"으로 보인다 — 같은 계정의 다른 기기 등).
Future<Map<String, dynamic>> encryptEnvelopeV3({
  required List<int> msgKey,
  required String plainText,
  required String roomId,
  required String sender,
  required String ratchetPublicKey,
  required int previousCount,
  required int n,
}) async {
  final nonce = _aesGcm.newNonce();
  final box = await _aesGcm.encrypt(
    utf8.encode(plainText),
    secretKey: SecretKey(msgKey),
    nonce: nonce,
    aad: utf8.encode(
      _aadV3(
        roomId: roomId,
        sender: sender,
        ratchetPublicKey: ratchetPublicKey,
        previousCount: previousCount,
        n: n,
      ),
    ),
  );
  return {
    'v': secretProtocolV3,
    's': sender,
    'dh': ratchetPublicKey,
    'pn': previousCount,
    'n': n,
    'epoch': 0,
    'nonce': base64Encode(nonce),
    'ciphertext': base64Encode([...box.cipherText, ...box.mac.bytes]),
  };
}

/// v3 봉투를 [msgKey]로 푼다 — 머리 값은 부른 쪽이 이미 확인한 것을 넘긴다. 맞지 않으면(키·머리·내용이 다름) null.
Future<String?> decryptEnvelopeV3({
  required List<int> msgKey,
  required String roomId,
  required String sender,
  required String ratchetPublicKey,
  required int previousCount,
  required int n,
  required List<int> nonce,
  required List<int> cipherTextWithMac,
}) async {
  try {
    if (cipherTextWithMac.length < 16) return null;
    final split = cipherTextWithMac.length - 16;
    final plainBytes = await _aesGcm.decrypt(
      SecretBox(
        cipherTextWithMac.sublist(0, split),
        nonce: nonce,
        mac: Mac(cipherTextWithMac.sublist(split)),
      ),
      secretKey: SecretKey(msgKey),
      aad: utf8.encode(
        _aadV3(
          roomId: roomId,
          sender: sender,
          ratchetPublicKey: ratchetPublicKey,
          previousCount: previousCount,
          n: n,
        ),
      ),
    );
    return utf8.decode(plainBytes);
  } catch (_) {
    return null;
  }
}

// ---- 보안 코드(안전 번호) ----
//
// 서명은 "서버가 알려 준 그 기기 키"가 맞는지까지만 보장한다 — 처음 만난 기기의 키를 서버가 처음부터 자기
// 키로 알려 주면 서명만으로는 알 수 없다. 그래서 두 기기의 (사용자, 기기, 서명 공개키)를 한 숫자로 줄여 양쪽
// 화면에 보여 주고, 사람이 만나서·전화로 같은지 비교하게 한다. 같은 두 기기면 어느 쪽에서 계산해도 같은
// 숫자가 나온다(두 항목을 정렬해서 잇는다).

/// 보안 코드 묶음 수와 한 묶음의 자릿수 — 12묶음 × 5자리 = 60자리(4묶음씩 3줄로 보여 준다).
const safetyNumberGroupCount = 12;
const safetyNumberGroupDigits = 5;

/// 한 묶음을 만드는 데 쓰는 해시 바이트 수(40비트) — 12묶음이면 SHA-512 64바이트 중 앞 60바이트.
const _safetyGroupBytes = 5;

/// 보안 코드의 한 기기 항목 — "사용자 id:기기 id:서명 공개키(base64)".
String safetyNumberEntry({
  required String userId,
  required String deviceId,
  required String signingPublicKey,
}) => '$userId:$deviceId:$signingPublicKey';

/// 두 기기 항목([entryA]·[entryB] — [safetyNumberEntry])의 보안 코드 12묶음(각 5자리 숫자 문자열).
/// 항목 순서와 상관없이 같은 값이 나온다.
///
/// SHA-512("tangotalk-safety-v1|" + 정렬한 두 항목을 '|'로 이은 것)의 앞 60바이트를 5바이트씩 끊어, 각각을
/// 빅엔디언 40비트 정수로 읽고 100000으로 나눈 나머지를 5자리로 채운다. 40비트를 비트 이동이 아니라 곱셈으로
/// 쌓는다 — 웹(자바스크립트)에서는 비트 연산이 32비트로 잘린다(2^40은 곱셈으로는 정확히 담긴다).
Future<List<String>> computeSafetyNumber(String entryA, String entryB) async {
  final entries = [entryA, entryB]..sort();
  final digest = (await _sha512.hash(
    utf8.encode('tangotalk-safety-v1|${entries.join('|')}'),
  )).bytes;
  return [
    for (var i = 0; i < safetyNumberGroupCount; i++)
      _safetyGroup(digest, i * _safetyGroupBytes),
  ];
}

String _safetyGroup(List<int> digest, int offset) {
  var value = 0;
  for (var j = offset; j < offset + _safetyGroupBytes; j++) {
    value = value * 256 + digest[j];
  }
  return (value % 100000).toString().padLeft(safetyNumberGroupDigits, '0');
}
