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

    test('뒤쫓아가기는 2000걸음까지만(v1) — 넘거나 음수면 포기한다', () async {
      final chainKey = List<int>.filled(32, 3);
      expect(await crypto.catchUpTo(chainKey, -1), isNull);
      expect(
        await crypto.catchUpTo(chainKey, crypto.v1MaxCatchUpSteps + 1),
        isNull,
      );
      expect(crypto.v1MaxCatchUpSteps, 2000);
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

  group('새 규약(v3) 키 유도', () {
    String transcript(String roomId, String e1, String e2) =>
        crypto.secretRootTranscriptV3(
          roomId: roomId,
          initiatorUserId: 'u-a',
          initiatorDeviceId: 'd-a',
          initiatorEphemeralPublicKey: e1,
          responderUserId: 'u-b',
          responderDeviceId: 'd-b',
          responderEphemeralPublicKey: e2,
        );

    test('루트키: 양쪽이 같은 값을 계산하고, 방·핸드셰이크 기록이 다르면 다르다', () async {
      final a = await X25519().newKeyPair();
      final b = await X25519().newKeyPair();
      final aPub = base64Encode((await a.extractPublicKey()).bytes);
      final bPub = base64Encode((await b.extractPublicKey()).bytes);
      final t = transcript('room-1', aPub, bPub);
      final rootA = await crypto.deriveRootKeyV3(
        myEphemeralKeyPair: a,
        theirEphemeralPublicKey: base64Decode(bPub),
        roomId: 'room-1',
        transcript: t,
      );
      final rootB = await crypto.deriveRootKeyV3(
        myEphemeralKeyPair: b,
        theirEphemeralPublicKey: base64Decode(aPub),
        roomId: 'room-1',
        transcript: t,
      );
      expect(rootA, isNotNull);
      expect(rootA, equals(rootB));
      expect(rootA!.length, 32);
      final otherRoom = await crypto.deriveRootKeyV3(
        myEphemeralKeyPair: a,
        theirEphemeralPublicKey: base64Decode(bPub),
        roomId: 'room-2',
        transcript: transcript('room-2', aPub, bPub),
      );
      expect(otherRoom, isNot(equals(rootA)));
      // 같은 공유비밀이라도 기록(상대·기기)이 다르면 다른 루트키.
      final otherTranscript = await crypto.deriveRootKeyV3(
        myEphemeralKeyPair: a,
        theirEphemeralPublicKey: base64Decode(bPub),
        roomId: 'room-1',
        transcript: transcript('room-1', bPub, aPub),
      );
      expect(otherTranscript, isNot(equals(rootA)));
      // 예전 규약의 첫 체인키와도 다르다(같은 임시키 두 개로 만들어도).
      final v1 = await crypto.deriveInitialChainKey(
        myEphemeralKeyPair: a,
        theirEphemeralPublicKey: await b.extractPublicKey(),
        roomId: 'room-1',
      );
      expect(v1, isNot(equals(rootA)));
    });

    test('공유비밀이 0뿐인 상대 키(작은 차수의 점)는 받지 않는다', () async {
      final a = await X25519().newKeyPair();
      expect(
        await crypto.x25519SharedSecret(a, List<int>.filled(32, 0)),
        isNull,
      );
      expect(
        await crypto.deriveRootKeyV3(
          myEphemeralKeyPair: a,
          theirEphemeralPublicKey: List<int>.filled(32, 0),
          roomId: 'room-1',
          transcript: 'x',
        ),
        isNull,
      );
    });

    test('루트 한 걸음·체인 한 걸음: 같은 입력이면 같은 값, 메시지 키와 다음 체인키는 서로 다르다', () async {
      final root = List<int>.filled(32, 5);
      final dh = List<int>.filled(32, 6);
      final (r1, c1) = await crypto.kdfRootV3(root, dh);
      final (r2, c2) = await crypto.kdfRootV3(root, dh);
      expect(r1, equals(r2));
      expect(c1, equals(c2));
      expect(r1, isNot(equals(c1)));
      expect(r1, isNot(equals(root)));
      final (r3, _) = await crypto.kdfRootV3(root, List<int>.filled(32, 7));
      expect(r3, isNot(equals(r1)));

      final step = await crypto.kdfChainV3(c1);
      expect(step.msgKey.length, 32);
      expect(step.nextChainKey.length, 32);
      expect(step.msgKey, isNot(equals(step.nextChainKey)));
      expect(step.msgKey, isNot(equals(c1)));
      final again = await crypto.kdfChainV3(c1);
      expect(again.msgKey, equals(step.msgKey));
      final next = await crypto.kdfChainV3(step.nextChainKey);
      expect(next.msgKey, isNot(equals(step.msgKey)));
    });

    test('v3 봉투: 머리(보낸 쪽·래칫 키·이전 수·번호·방)를 하나라도 바꾸면 풀리지 않는다', () async {
      final key = List<int>.filled(32, 8);
      final dh = base64Encode(List<int>.filled(32, 9));
      final otherDh = base64Encode(List<int>.filled(32, 10));
      final env = await crypto.encryptEnvelopeV3(
        msgKey: key,
        plainText: '안녕 v3',
        roomId: 'room-1',
        sender: 'i',
        ratchetPublicKey: dh,
        previousCount: 2,
        n: 5,
      );
      expect(env['v'], crypto.secretProtocolV3);
      expect(env['s'], 'i');
      expect(env['dh'], dh);
      expect(env['pn'], 2);
      expect(env['n'], 5);
      // 예전 앱이 봉투를 읽다 멈추지 않게 정수 epoch가 있다.
      expect(env['epoch'], isA<int>());
      Future<String?> open({
        String roomId = 'room-1',
        String sender = 'i',
        String? ratchet,
        int pn = 2,
        int n = 5,
        List<int>? withKey,
      }) => crypto.decryptEnvelopeV3(
        msgKey: withKey ?? key,
        roomId: roomId,
        sender: sender,
        ratchetPublicKey: ratchet ?? dh,
        previousCount: pn,
        n: n,
        nonce: base64Decode(env['nonce'] as String),
        cipherTextWithMac: base64Decode(env['ciphertext'] as String),
      );
      expect(await open(), '안녕 v3');
      expect(await open(roomId: 'room-2'), isNull);
      expect(await open(sender: 'r'), isNull);
      expect(await open(ratchet: otherDh), isNull);
      expect(await open(pn: 3), isNull);
      expect(await open(n: 6), isNull);
      expect(await open(withKey: List<int>.filled(32, 1)), isNull);
    });

    test('v3 수락 맥락은 v2와 머리만 다르다 — 서로 바꿔 끼울 수 없다', () {
      String build(
        String Function({
          required String roomId,
          required String initiatorUserId,
          required String initiatorDeviceId,
          required String initiatorEphemeralPublicKey,
          required String responderUserId,
          required String responderDeviceId,
          required String responderEphemeralPublicKey,
        })
        f,
      ) => f(
        roomId: 'room-1',
        initiatorUserId: 'u-a',
        initiatorDeviceId: 'd-a',
        initiatorEphemeralPublicKey: 'EA',
        responderUserId: 'u-b',
        responderDeviceId: 'd-b',
        responderEphemeralPublicKey: 'EB',
      );
      final v2 = build(crypto.secretAcceptContext);
      final v3 = build(crypto.secretAcceptContextV3);
      expect(v2, 'tangotalk-secret-v2|accept|room-1|u-a|d-a|EA|u-b|d-b|EB');
      expect(v3, 'tangotalk-secret-v3|accept|room-1|u-a|d-a|EA|u-b|d-b|EB');
      expect(
        build(crypto.secretRootTranscriptV3),
        'tangotalk-secret-v3|root|room-1|u-a|d-a|EA|u-b|d-b|EB',
      );
    });
  });
}
