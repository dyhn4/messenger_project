import 'dart:convert';
import 'dart:typed_data';

import 'package:client/services/secret_chat_crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('비밀 대화 암호화 라운드트립', () {
    test('X25519 핸드셰이크: 양쪽이 같은 초기 체인키를 계산한다', () async {
      final a = await X25519().newKeyPair();
      final b = await X25519().newKeyPair();
      final aPub = await a.extractPublicKey();
      final bPub = await b.extractPublicKey();

      final chainA = await crypto.deriveInitialChainKey(
        myEphemeralKeyPair: a,
        theirEphemeralPublicKey: bPub,
        roomId: 'room-1',
      );
      final chainB = await crypto.deriveInitialChainKey(
        myEphemeralKeyPair: b,
        theirEphemeralPublicKey: aPub,
        roomId: 'room-1',
      );
      expect(chainA, equals(chainB));

      // 방이 다르면(salt이 다르면) 같은 키 쌍이어도 다른 체인키가 나와야 한다.
      final chainOtherRoom = await crypto.deriveInitialChainKey(
        myEphemeralKeyPair: a,
        theirEphemeralPublicKey: bPub,
        roomId: 'room-2',
      );
      expect(chainOtherRoom, isNot(equals(chainA)));
    });

    test('메시지 암/복호화 라운드트립 + 한 방향 래칫', () async {
      var chainKey = List<int>.filled(32, 7);
      final step0 = await crypto.ratchetStep(chainKey);
      final envelope0 = await crypto.encryptEnvelope(
        msgKey: step0.msgKey,
        plainText: '안녕하세요',
        roomId: 'room-1',
        epoch: 0,
        n: 0,
      );
      final decrypted0 = await crypto.decryptEnvelope(
        msgKey: step0.msgKey,
        envelope: envelope0,
        roomId: 'room-1',
      );
      expect(decrypted0, '안녕하세요');

      // 다음 메시지는 다음 체인키에서 나온 다른 msgKey를 쓰므로, 이전 msgKey로는 복호화가 안 된다.
      final step1 = await crypto.ratchetStep(step0.nextChainKey);
      final envelope1 = await crypto.encryptEnvelope(
        msgKey: step1.msgKey,
        plainText: '두번째 메시지',
        roomId: 'room-1',
        epoch: 0,
        n: 1,
      );
      final wrongDecrypt = await crypto.decryptEnvelope(
        msgKey: step0.msgKey, // 일부러 이전 키 사용
        envelope: envelope1,
        roomId: 'room-1',
      );
      expect(wrongDecrypt, isNull);

      final rightDecrypt = await crypto.decryptEnvelope(
        msgKey: step1.msgKey,
        envelope: envelope1,
        roomId: 'room-1',
      );
      expect(rightDecrypt, '두번째 메시지');

      // roomId가 다르면(AAD가 달라지므로) 같은 키로도 복호화가 실패해야 한다.
      final wrongRoom = await crypto.decryptEnvelope(
        msgKey: step0.msgKey,
        envelope: envelope0,
        roomId: 'room-999',
      );
      expect(wrongRoom, isNull);
    });

    test('catchUpTo가 여러 단계 앞선 메시지 키를 정확히 재현한다', () async {
      final chainKey = List<int>.filled(32, 3);
      // 수동으로 5단계 전진.
      var key = chainKey;
      crypto.RatchetStep? last;
      for (var i = 0; i < 5; i++) {
        last = await crypto.ratchetStep(key);
        key = last.nextChainKey;
      }
      final manualMsgKey = (await crypto.ratchetStep(key)).msgKey;

      final caughtUp = await crypto.catchUpTo(chainKey, 5);
      expect(caughtUp, equals(manualMsgKey));
    });

    test('재키잉: 새 DH + 이전 체인키를 섞은 새 체인키를 양쪽이 동일하게 계산한다', () async {
      final a2 = await X25519().newKeyPair();
      final b2 = await X25519().newKeyPair();
      final a2Pub = await a2.extractPublicKey();
      final b2Pub = await b2.extractPublicKey();
      final prevChainKey = List<int>.filled(32, 9);

      final newChainA = await crypto.deriveRekeyChainKey(
        myNewEphemeralKeyPair: a2,
        theirNewEphemeralPublicKey: b2Pub,
        previousChainKeyLastValue: prevChainKey,
        newEpoch: 1,
      );
      final newChainB = await crypto.deriveRekeyChainKey(
        myNewEphemeralKeyPair: b2,
        theirNewEphemeralPublicKey: a2Pub,
        previousChainKeyLastValue: prevChainKey,
        newEpoch: 1,
      );
      expect(newChainA, equals(newChainB));
      expect(newChainA, isNot(equals(prevChainKey)));
    });

    test('Ed25519 서명/검증: 위조 감지', () async {
      final signer = await Ed25519().newKeyPair();
      final signerPub = await signer.extractPublicKey();
      final message = utf8.encode('ephemeral-public-key-bytes');

      final sig = await crypto.signEphemeralKey(signer, message);
      final ok = await crypto.verifyEphemeralKey(
        signingPublicKeyBase64: base64Encode(signerPub.bytes),
        ephemeralPublicKeyBytes: message,
        signatureBase64: sig,
      );
      expect(ok, isTrue);

      // 다른 신원의 서명 검증키로는 실패해야 한다(서버가 키를 바꿔치기하는 상황 시뮬레이션).
      final impostor = await Ed25519().newKeyPair();
      final impostorPub = await impostor.extractPublicKey();
      final failed = await crypto.verifyEphemeralKey(
        signingPublicKeyBase64: base64Encode(impostorPub.bytes),
        ephemeralPublicKeyBytes: message,
        signatureBase64: sig,
      );
      expect(failed, isFalse);

      // 메시지가 변조되면(공개키 바꿔치기) 같은 서명으로는 검증이 실패해야 한다.
      final tamperedMessage = utf8.encode('tampered-public-key-bytes!!');
      final tampered = await crypto.verifyEphemeralKey(
        signingPublicKeyBase64: base64Encode(signerPub.bytes),
        ephemeralPublicKeyBytes: tamperedMessage,
        signatureBase64: sig,
      );
      expect(tampered, isFalse);
    });

    test('첨부파일 암/복호화 라운드트립', () async {
      final original = Uint8List.fromList(List.generate(5000, (i) => i % 256));
      final encrypted = await crypto.encryptAttachment(original);
      final decrypted = await crypto.decryptAttachment(
        cipherBytes: encrypted.cipherBytes,
        keyBase64: encrypted.keyBase64,
        nonceBase64: encrypted.nonceBase64,
      );
      expect(decrypted, equals(original));

      // 틀린 키로는 복호화 실패(null)해야 한다.
      final wrongKeyResult = await crypto.decryptAttachment(
        cipherBytes: encrypted.cipherBytes,
        keyBase64: base64Encode(List.filled(32, 1)),
        nonceBase64: encrypted.nonceBase64,
      );
      expect(wrongKeyResult, isNull);
    });
  });
}
