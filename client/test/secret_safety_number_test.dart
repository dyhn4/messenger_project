import 'package:client/services/secret_chat_crypto.dart' as crypto;
import 'package:client/services/secret_peer_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// 비밀 대화 보안 코드(S5) — 두 기기의 (사용자·기기·서명 공개키)로 만든 60자리 숫자가 정해진 계산 그대로이고(다른
/// 구현으로 계산한 고정값과 같다), 어느 기기에서 계산해도 같으며, 어느 한 값이 바뀌어도 달라지는지 본다.

const _keyA = 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8='; // 0..31
const _keyB = 'ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8='; // 32..63

String _alice({
  String userId = 'user-alice',
  String deviceId = 'device-alice-1',
  String key = _keyA,
}) => crypto.safetyNumberEntry(
  userId: userId,
  deviceId: deviceId,
  signingPublicKey: key,
);

String _bob({
  String userId = 'user-bob',
  String deviceId = 'device-bob-1',
  String key = _keyB,
}) => crypto.safetyNumberEntry(
  userId: userId,
  deviceId: deviceId,
  signingPublicKey: key,
);

void main() {
  test('항목 형식은 "사용자 id:기기 id:서명 공개키"다', () {
    expect(_alice(), 'user-alice:device-alice-1:$_keyA');
  });

  test('고정값 — Node(crypto SHA-512 + BigInt)로 따로 계산한 12묶음과 같다', () async {
    // SHA-512("tangotalk-safety-v1|user-alice:…|user-bob:…")의 앞 60바이트를 5바이트씩 빅엔디언 40비트로 읽어
    // 100000으로 나눈 나머지(5자리 — 7번째 묶음처럼 앞자리 0도 채운다).
    expect(await crypto.computeSafetyNumber(_alice(), _bob()), [
      '26374',
      '91972',
      '45845',
      '36625',
      '42467',
      '53727',
      '09896',
      '91309',
      '86314',
      '43620',
      '24597',
      '78458',
    ]);
  });

  test('양쪽 기기에서 계산해도 같다(항목 순서와 상관없다)', () async {
    final fromAlice = await crypto.computeSafetyNumber(_alice(), _bob());
    final fromBob = await crypto.computeSafetyNumber(_bob(), _alice());
    expect(fromBob, fromAlice);
    expect(fromAlice, hasLength(crypto.safetyNumberGroupCount));
    for (final group in fromAlice) {
      expect(group, matches(RegExp(r'^\d{5}$')));
    }
  });

  test('사용자·기기·키 중 하나라도 바뀌면(서버가 키를 바꿔치기함 등) 다른 코드가 나온다', () async {
    final original = await crypto.computeSafetyNumber(_alice(), _bob());
    for (final (a, b) in [
      (_alice(userId: 'user-mallory'), _bob()),
      (_alice(deviceId: 'device-alice-2'), _bob()),
      (_alice(key: _keyB), _bob()),
      (_alice(), _bob(key: _keyA)),
      (_alice(), _bob(deviceId: 'device-bob-2')),
    ]) {
      expect(await crypto.computeSafetyNumber(a, b), isNot(original));
    }
  });

  test('화면에는 4묶음씩 3줄로 나눈다', () {
    final info = SecretSafetyInfo(
      groups: [for (var i = 0; i < 12; i++) '${10000 + i}'],
      peerUserId: 'user-bob',
      peerDeviceId: 'device-bob-1',
    );
    expect(info.rows, [
      ['10000', '10001', '10002', '10003'],
      ['10004', '10005', '10006', '10007'],
      ['10008', '10009', '10010', '10011'],
    ]);
    expect(info.verified, isFalse);
  });
}
