import 'dart:convert';

import 'package:client/services/secret_chat_crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

/// 비밀 대화 맥락 서명(v2, S5) — 서버와 함께 정한 맥락 문자열이 글자 그대로인지, 서명이 맥락의 어느 칸이 바뀌어도
/// 통하지 않는지, 다른 구현(Node의 Ed25519)과 같은 서명이 나오는지 본다.

const _keyA = 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=';
const _keyB = 'ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8=';

String _init({
  String initiatorUserId = 'u-alice',
  String initiatorDeviceId = 'd-alice',
  String responderUserId = 'u-bob',
  String initiatorEphemeralPublicKey = _keyA,
}) => crypto.secretInitContext(
  initiatorUserId: initiatorUserId,
  initiatorDeviceId: initiatorDeviceId,
  responderUserId: responderUserId,
  initiatorEphemeralPublicKey: initiatorEphemeralPublicKey,
);

String _accept({
  String roomId = 'room-1',
  String initiatorUserId = 'u-alice',
  String initiatorDeviceId = 'd-alice',
  String initiatorEphemeralPublicKey = _keyA,
  String responderUserId = 'u-bob',
  String responderDeviceId = 'd-bob',
  String responderEphemeralPublicKey = _keyB,
}) => crypto.secretAcceptContext(
  roomId: roomId,
  initiatorUserId: initiatorUserId,
  initiatorDeviceId: initiatorDeviceId,
  initiatorEphemeralPublicKey: initiatorEphemeralPublicKey,
  responderUserId: responderUserId,
  responderDeviceId: responderDeviceId,
  responderEphemeralPublicKey: responderEphemeralPublicKey,
);

String _propose({
  String roomId = 'room-1',
  int keyEpoch = 3,
  String proposerUserId = 'u-alice',
  String proposerDeviceId = 'd-alice',
  String proposerEphemeralPublicKey = _keyA,
}) => crypto.secretRekeyProposeContext(
  roomId: roomId,
  keyEpoch: keyEpoch,
  proposerUserId: proposerUserId,
  proposerDeviceId: proposerDeviceId,
  proposerEphemeralPublicKey: proposerEphemeralPublicKey,
);

String _ack({
  String roomId = 'room-1',
  int keyEpoch = 3,
  String responderUserId = 'u-bob',
  String responderDeviceId = 'd-bob',
  String proposerEphemeralPublicKey = _keyA,
  String responderEphemeralPublicKey = _keyB,
}) => crypto.secretRekeyAckContext(
  roomId: roomId,
  keyEpoch: keyEpoch,
  responderUserId: responderUserId,
  responderDeviceId: responderDeviceId,
  proposerEphemeralPublicKey: proposerEphemeralPublicKey,
  responderEphemeralPublicKey: responderEphemeralPublicKey,
);

Future<String> _publicKey(SimpleKeyPair keyPair) async =>
    base64Encode((await keyPair.extractPublicKey()).bytes);

void main() {
  test('맥락 문자열은 서버와 정한 형식 그대로다(접두사·종류·칸 순서·구분자)', () {
    expect(_init(), 'tangotalk-secret-v2|init|u-alice|d-alice|u-bob|$_keyA');
    expect(
      _accept(),
      'tangotalk-secret-v2|accept|room-1|u-alice|d-alice|$_keyA|u-bob|d-bob|$_keyB',
    );
    expect(
      _propose(),
      'tangotalk-secret-v2|rekey-propose|room-1|3|u-alice|d-alice|$_keyA',
    );
    expect(
      _ack(),
      'tangotalk-secret-v2|rekey-ack|room-1|3|u-bob|d-bob|$_keyA|$_keyB',
    );
  });

  test("칸에 '|'가 있으면 맥락을 만들지 않는다(칸 경계가 흐려져 다른 값 묶음과 같은 문자열이 될 수 있다)", () {
    expect(() => _init(initiatorUserId: 'u|alice'), throwsArgumentError);
    expect(() => _accept(roomId: 'room|1'), throwsArgumentError);
    expect(() => _propose(proposerDeviceId: 'd|x'), throwsArgumentError);
    expect(() => _ack(responderUserId: 'a|b'), throwsArgumentError);
  });

  test('서명·확인 왕복 — 맥락의 어느 칸이 바뀌어도, 다른 키로도 통하지 않는다', () async {
    final signer = await Ed25519().newKeyPair();
    final publicKey = await _publicKey(signer);
    final other = await _publicKey(await Ed25519().newKeyPair());

    Future<bool> verify(String context, String signature, [String? key]) =>
        crypto.verifyContext(
          signingPublicKeyBase64: key ?? publicKey,
          context: context,
          signatureBase64: signature,
        );

    final cases = <String, (String, List<String>)>{
      'init': (
        _init(),
        [
          _init(initiatorUserId: 'u-mallory'),
          _init(initiatorDeviceId: 'd-mallory'),
          _init(responderUserId: 'u-carol'),
          _init(initiatorEphemeralPublicKey: _keyB),
        ],
      ),
      'accept': (
        _accept(),
        [
          _accept(roomId: 'room-2'),
          _accept(initiatorUserId: 'u-mallory'),
          _accept(initiatorDeviceId: 'd-mallory'),
          _accept(initiatorEphemeralPublicKey: _keyB),
          _accept(responderUserId: 'u-carol'),
          _accept(responderDeviceId: 'd-carol'),
          _accept(responderEphemeralPublicKey: _keyA),
        ],
      ),
      'rekey-propose': (
        _propose(),
        [
          _propose(roomId: 'room-2'),
          _propose(keyEpoch: 4),
          _propose(proposerUserId: 'u-mallory'),
          _propose(proposerDeviceId: 'd-mallory'),
          _propose(proposerEphemeralPublicKey: _keyB),
        ],
      ),
      'rekey-ack': (
        _ack(),
        [
          _ack(roomId: 'room-2'),
          _ack(keyEpoch: 2),
          _ack(responderUserId: 'u-mallory'),
          _ack(responderDeviceId: 'd-mallory'),
          _ack(proposerEphemeralPublicKey: _keyB),
          _ack(responderEphemeralPublicKey: _keyA),
        ],
      ),
    };
    for (final MapEntry(key: kind, value: (context, tampered))
        in cases.entries) {
      final signature = await crypto.signContext(signer, context);
      expect(base64Decode(signature), hasLength(64), reason: kind);
      expect(await verify(context, signature), isTrue, reason: kind);
      expect(
        await verify(context, signature, other),
        isFalse,
        reason: '$kind — 다른 기기 키',
      );
      for (final changed in tampered) {
        expect(
          await verify(changed, signature),
          isFalse,
          reason: '$kind — 바뀐 맥락: $changed',
        );
      }
    }
    // 다른 종류의 맥락으로 옮겨 쓸 수도 없다(초대 서명을 재키잉 제안으로 등).
    final initSignature = await crypto.signContext(signer, _init());
    expect(await verify(_propose(), initSignature), isFalse);
  });

  test('모양이 틀린 키·서명은 확인 실패로 끝난다(예외 없이)', () async {
    final signer = await Ed25519().newKeyPair();
    final publicKey = await _publicKey(signer);
    final signature = await crypto.signContext(signer, _init());
    for (final (key, sig) in [
      (publicKey, 'not-base64!!'),
      (publicKey, base64Encode(List.filled(63, 1))),
      (publicKey, ''),
      ('짧은키', signature),
      (base64Encode(List.filled(31, 1)), signature),
    ]) {
      expect(
        await crypto.verifyContext(
          signingPublicKeyBase64: key,
          context: _init(),
          signatureBase64: sig,
        ),
        isFalse,
      );
    }
  });

  test(
    '다른 구현(Node crypto의 Ed25519)과 같은 서명이 나온다 — 맥락 문자열의 UTF-8 바이트를 그대로 서명한다',
    () async {
      // 시드 0x07×32 — Node에서 같은 시드·같은 맥락으로 만든 값(Ed25519 서명은 결정적이다).
      final signer = await Ed25519().newKeyPairFromSeed(List.filled(32, 7));
      final context = _init(
        initiatorUserId: 'user-alice',
        initiatorDeviceId: 'device-alice-1',
        responderUserId: 'user-bob',
        initiatorEphemeralPublicKey: _keyB,
      );
      expect(
        context,
        'tangotalk-secret-v2|init|user-alice|device-alice-1|user-bob|$_keyB',
      );
      expect(
        await _publicKey(signer),
        '6kpsY+KcUgq+9VB7Ey7F+ZVHdq6+vnuSQh7qaRRG0iw=',
      );
      final signature = await crypto.signContext(signer, context);
      expect(
        signature,
        'iKgJQdO/kb4rIdTfkavjUoI5jHUyIZA7NBGNYJFGI/K9e+JMHdE7Qq2J1fy4p+hXb6NyqA/+fI5rwHLV9K4+Ag==',
      );
      expect(
        await crypto.verifyContext(
          signingPublicKeyBase64:
              '6kpsY+KcUgq+9VB7Ey7F+ZVHdq6+vnuSQh7qaRRG0iw=',
          context: context,
          signatureBase64: signature,
        ),
        isTrue,
      );
    },
  );

  test('v1 서명(키 바이트만)은 맥락 서명으로 통하지 않고, 맥락 서명도 v1로 통하지 않는다', () async {
    final signer = await Ed25519().newKeyPair();
    final publicKey = await _publicKey(signer);
    final v1 = await crypto.signEphemeralKey(signer, base64Decode(_keyA));
    expect(
      await crypto.verifyContext(
        signingPublicKeyBase64: publicKey,
        context: _init(),
        signatureBase64: v1,
      ),
      isFalse,
    );
    final v2 = await crypto.signContext(signer, _init());
    expect(
      await crypto.verifyEphemeralKey(
        signingPublicKeyBase64: publicKey,
        ephemeralPublicKeyBytes: base64Decode(_keyA),
        signatureBase64: v2,
      ),
      isFalse,
    );
  });
}
