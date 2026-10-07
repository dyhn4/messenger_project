import 'dart:convert';
import 'dart:math';

import 'package:client/services/secret_chat_crypto.dart' as crypto;
import 'package:client/services/secret_ratchet.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

// 새 규약(v3) 더블 래칫(secret_ratchet.dart) 상태 기계 시험.
//
// 두 기기를 실제 핸드셰이크 값(임시키 두 개 → 핸드셰이크 기록 → 루트키)으로 맞춰 놓고 주고받는다. 봉투는 늘 JSON
// 문자열을 한 번 거쳐(서버를 지나는 것처럼) SecretEnvelopeV3.tryParse로 읽고, 받는 쪽은 앱
// (SecretSessionManager._decryptV3)처럼 복호화에 성공했을 때만 돌려받은 상태로 바꾼다 — 실패하면 들고 있던 상태가
// 그대로 남아야 한다(_recv가 매번 확인한다).

const _room = 'room-ratchet-1';

/// 기기 하나 — 지금 래칫 상태를 들고 있다(앱에서는 SecretKeyStore에 저장된 값).
class _Device {
  _Device(this.name, this.state);
  final String name;
  SecretRatchetState state;
}

/// 핸드셰이크를 마친 두 기기 — [alice]는 초대한 기기('i'), [bob]은 수락한 기기('r').
class _Pair {
  _Pair(this.alice, this.bob, this.responderEphemeralPublicKey);
  final _Device alice;
  final _Device bob;

  /// 수락한 기기의 핸드셰이크 임시 공개키(표준 base64) — 수락한 기기의 첫 래칫 키다.
  final String responderEphemeralPublicKey;
}

Future<String> _publicKeyBase64(SimpleKeyPair keyPair) async =>
    base64Encode((await keyPair.extractPublicKey()).bytes);

/// 초대·수락을 마친 두 기기 — 앱처럼 양쪽이 각자 루트키를 계산하고(같아야 한다), 초대한 기기는 수락한 기기의
/// 임시 공개키를, 수락한 기기는 자기 임시키 쌍을 넘겨 래칫을 시작한다.
Future<_Pair> _handshake({String roomId = _room}) async {
  final initiatorEphemeral = await X25519().newKeyPair();
  final responderEphemeral = await X25519().newKeyPair();
  final initiatorPublic = await _publicKeyBase64(initiatorEphemeral);
  final responderPublic = await _publicKeyBase64(responderEphemeral);
  final transcript = crypto.secretRootTranscriptV3(
    roomId: roomId,
    initiatorUserId: 'u-alice',
    initiatorDeviceId: 'd-alice',
    initiatorEphemeralPublicKey: initiatorPublic,
    responderUserId: 'u-bob',
    responderDeviceId: 'd-bob',
    responderEphemeralPublicKey: responderPublic,
  );
  final initiatorRoot = await crypto.deriveRootKeyV3(
    myEphemeralKeyPair: initiatorEphemeral,
    theirEphemeralPublicKey: base64Decode(responderPublic),
    roomId: roomId,
    transcript: transcript,
  );
  final responderRoot = await crypto.deriveRootKeyV3(
    myEphemeralKeyPair: responderEphemeral,
    theirEphemeralPublicKey: base64Decode(initiatorPublic),
    roomId: roomId,
    transcript: transcript,
  );
  expect(initiatorRoot, isNotNull);
  expect(responderRoot, equals(initiatorRoot));
  final alice = await SecretRatchetState.forInitiator(
    rootKey: initiatorRoot!,
    responderEphemeralPublicKey: responderPublic,
  );
  expect(alice, isNotNull);
  final bob = await SecretRatchetState.forResponder(
    rootKey: responderRoot!,
    myEphemeralKeyPair: responderEphemeral,
  );
  return _Pair(_Device('alice', alice!), _Device('bob', bob), responderPublic);
}

/// 서버를 지난 것처럼 — JSON 문자열로 적었다가 다시 읽는다.
Map<String, dynamic> _wire(Map<String, dynamic> envelope) =>
    jsonDecode(jsonEncode(envelope)) as Map<String, dynamic>;

/// [from]이 [text]를 보낸다 — 새 상태를 들고, 선을 거친 봉투를 돌려준다.
Future<Map<String, dynamic>> _send(
  _Device from,
  String text, {
  String roomId = _room,
}) async {
  final before = from.state.encode();
  final out = await from.state.encrypt(roomId: roomId, plainText: text);
  expect(
    from.state.encode(),
    before,
    reason: '${from.name}: encrypt가 들고 있던 상태를 고쳤다',
  );
  from.state = out.state;
  return _wire(out.envelope);
}

/// [from]이 [count]개를 이어 보낸다 — 글은 '$prefix$i'.
Future<List<Map<String, dynamic>>> _sendMany(
  _Device from,
  int count,
  String prefix,
) async => [for (var i = 0; i < count; i++) await _send(from, '$prefix$i')];

/// [to]가 [envelope]를 받는다 — 풀리면 평문, 아니면 null. 앱처럼 풀렸을 때만 돌려받은 상태로 바꾸고, 어느 쪽이든
/// decrypt가 들고 있던 상태 값을 고치지 않았는지 본다. 봉투는 모양으로는 늘 맞아야 한다(모양 시험은 tryParse 묶음).
Future<String?> _recv(
  _Device to,
  Map<String, dynamic> envelope, {
  String roomId = _room,
}) async {
  final parsed = SecretEnvelopeV3.tryParse(_wire(envelope));
  expect(parsed, isNotNull, reason: '${to.name}: 봉투 모양이 틀렸다 — $envelope');
  final before = to.state.encode();
  final opened = await to.state.decrypt(roomId: roomId, envelope: parsed!);
  expect(
    to.state.encode(),
    before,
    reason: '${to.name}: decrypt가 들고 있던 상태를 고쳤다',
  );
  if (opened == null) return null;
  to.state = opened.state;
  return opened.plainText;
}

/// 실패한 시도 전후로 상태가 그대로인지 보려고 — 상태 전체를 저장 형식으로.
String _snapshot(_Device device) => device.state.encode();

/// 앱을 껐다 켠 것처럼 — 저장 형식으로 적었다가 다시 읽는다(같은 값이어야 한다).
void _restore(_Device device) {
  final raw = device.state.encode();
  final restored = SecretRatchetState.decode(raw);
  expect(restored, isNotNull, reason: '${device.name}: 저장한 상태를 다시 읽지 못했다');
  expect(restored!.encode(), raw);
  device.state = restored;
}

/// base64로 적은 바이트 중 [index]번째의 한 비트를 뒤집는다.
String _flipByte(String base64, int index) {
  final bytes = base64Decode(base64);
  bytes[index] ^= 0x01;
  return base64Encode(bytes);
}

/// X25519 공개키(base64)의 맨 윗비트만 뒤집는다 — 글자는 다르지만 X25519는 이 비트를 무시해 같은 점이다.
String _flipTopBit(String publicKey) {
  final bytes = base64Decode(publicKey);
  bytes[31] ^= 0x80;
  return base64Encode(bytes);
}

/// [first]와 [second]가 번갈아 [rounds]차례 — 차례마다 1~3개를 이어 보내고 상대는 받은 순서대로 푼다. 이 대화
/// 안에서 두 번째 차례부터는 그 사이 상대 메시지를 받았으니 한 번도 쓰지 않은 새 래칫 키의 0번부터 보내고, pn은
/// 바로 전 체인에서 보낸 수다. (부르기 전에 오가던 메시지는 모두 받은 상태여야 한다.)
Future<void> _alternate(
  _Device first,
  _Device second, {
  required int rounds,
}) async {
  final lastTurn = <_Device, List<Map<String, dynamic>>>{};
  final usedKeys = <String>{};
  var from = first;
  var to = second;
  for (var round = 0; round < rounds; round++) {
    final burst = 1 + round % 3;
    final texts = [
      for (var k = 0; k < burst; k++) '${from.name} $round-$k 안녕하세요 👋',
    ];
    final sent = [for (final t in texts) await _send(from, t)];
    for (var k = 1; k < burst; k++) {
      expect(sent[k]['n'], (sent[0]['n'] as int) + k);
      expect(sent[k]['dh'], sent[0]['dh']);
      expect(sent[k]['pn'], sent[0]['pn']);
    }
    final dh = sent[0]['dh'] as String;
    final previous = lastTurn[from];
    if (previous != null) {
      expect(usedKeys.contains(dh), isFalse, reason: '래칫 키를 다시 썼다');
      expect(sent[0]['n'], 0);
      expect(sent[0]['pn'], (previous.last['n'] as int) + 1);
    }
    usedKeys.add(dh);
    for (var k = 0; k < burst; k++) {
      expect(await _recv(to, sent[k]), texts[k]);
    }
    lastTurn[from] = sent;
    (from, to) = (to, from);
  }
}

/// [envelope]를 한 군데씩 바꾼 것(암호문·태그·nonce·n·pn·dh·방)이 모두 풀리지 않고 상태도 그대로인지 본 뒤,
/// 마지막에 진짜 [envelope]가 [text]로 풀리는지 본다.
Future<void> _expectTamperingRejected(
  _Device to,
  Map<String, dynamic> envelope,
  String text, {
  required List<String> otherKeys,
}) async {
  final before = _snapshot(to);
  final cipher = envelope['ciphertext'] as String;
  final cipherLength = base64Decode(cipher).length;
  final n = envelope['n'] as int;
  final pn = envelope['pn'] as int;
  final forged = <String, Map<String, dynamic>>{
    '암호문 첫 바이트': {...envelope, 'ciphertext': _flipByte(cipher, 0)},
    '태그 마지막 바이트': {
      ...envelope,
      'ciphertext': _flipByte(cipher, cipherLength - 1),
    },
    '암호문 한 바이트 모자람': {
      ...envelope,
      'ciphertext': base64Encode(
        base64Decode(cipher).sublist(0, cipherLength - 1),
      ),
    },
    'nonce 한 바이트': {
      ...envelope,
      'nonce': _flipByte(envelope['nonce'] as String, 5),
    },
    'n + 1': {...envelope, 'n': n + 1},
    if (n > 0) 'n - 1': {...envelope, 'n': n - 1},
    'pn + 1': {...envelope, 'pn': pn + 1},
    if (pn > 0) 'pn - 1': {...envelope, 'pn': pn - 1},
    'dh 맨 윗비트': {...envelope, 'dh': _flipTopBit(envelope['dh'] as String)},
    for (final (i, key) in otherKeys.indexed)
      'dh 바꿈 #$i': {...envelope, 'dh': key},
  };
  for (final entry in forged.entries) {
    expect(await _recv(to, entry.value), isNull, reason: entry.key);
    expect(_snapshot(to), before, reason: entry.key);
  }
  expect(
    await _recv(to, envelope, roomId: '$_room-other'),
    isNull,
    reason: '다른 방',
  );
  expect(_snapshot(to), before);
  expect(await _recv(to, envelope), text);
}

void main() {
  group('새 규약(v3) 래칫 — 처음 맞추기', () {
    test(
      '수락한 기기는 자기 임시키가 첫 래칫 키, 초대한 기기는 그 키의 0번 체인을 받는 체인으로 두고 새 키로 보낸다',
      () async {
        final p = await _handshake();
        final a = p.alice.state;
        final b = p.bob.state;
        expect(a.role, secretRoleInitiator);
        expect(b.role, secretRoleResponder);
        expect(a.peerRole, secretRoleResponder);
        expect(b.peerRole, secretRoleInitiator);
        // 수락한 기기 — 핸드셰이크 임시키 그대로, 받는 체인은 아직 없다.
        expect(b.sendingPublicKey, p.responderEphemeralPublicKey);
        expect(b.receivingPublicKey, isNull);
        expect(b.receivingChainKey, isNull);
        // 초대한 기기 — 상대 임시키와 그 0번 체인을 받는 쪽에 두고, 보내는 키는 새로 만들었다.
        expect(a.receivingPublicKey, p.responderEphemeralPublicKey);
        expect(a.receivingChainKey, equals(b.sendingChainKey));
        expect(a.sendingPublicKey, isNot(p.responderEphemeralPublicKey));
        expect(a.sendingChainKey, isNot(equals(b.sendingChainKey)));
        // 초대한 기기는 시작할 때 이미 루트를 한 걸음 나아갔다.
        expect(a.rootKey, isNot(equals(b.rootKey)));
        for (final s in [a, b]) {
          expect(s.sendCount, 0);
          expect(s.previousSendCount, 0);
          expect(s.receiveCount, 0);
          expect(s.skipped, isEmpty);
        }
      },
    );

    test(
      'forInitiator: 상대 임시키가 표준 base64의 32바이트가 아니거나 작은 차수의 점이면 null',
      () async {
        final rootKey = List<int>.filled(32, 1);
        Future<SecretRatchetState?> init(String key) =>
            SecretRatchetState.forInitiator(
              rootKey: rootKey,
              responderEphemeralPublicKey: key,
            );
        // '+'와 '/'가 들어가는 바이트라 URL-safe로 적으면 글자가 달라진다.
        final bytes = List<int>.filled(32, 0xfb);
        final canonical = base64Encode(bytes);
        expect(await init(canonical), isNotNull);
        final urlSafe = base64Url.encode(bytes);
        expect(urlSafe, isNot(canonical));
        // Dart의 base64Decode는 URL-safe·'%3D' 패딩도 같은 바이트로 읽는다 — 다시 적어 비교해야 거른다.
        expect(base64Decode(urlSafe), equals(bytes));
        expect(await init(urlSafe), isNull);
        final percent = '${canonical.substring(0, canonical.length - 1)}%3D';
        expect(base64Decode(percent), equals(bytes));
        expect(await init(percent), isNull);
        expect(await init(canonical.replaceAll('=', '')), isNull);
        expect(await init('***'), isNull);
        expect(await init(''), isNull);
        expect(await init(base64Encode(List<int>.filled(31, 0xfb))), isNull);
        expect(await init(base64Encode(List<int>.filled(33, 0xfb))), isNull);
        // 공유비밀이 0뿐인 키.
        expect(await init(base64Encode(List<int>.filled(32, 0))), isNull);
      },
    );

    test('encrypt·decrypt는 들고 있던 상태를 고치지 않고 새 상태를 돌려준다 — 저장은 부른 쪽 몫', () async {
      final p = await _handshake();
      final s0 = p.bob.state;
      final raw = s0.encode();
      final first = await s0.encrypt(roomId: _room, plainText: '첫 번째');
      final again = await s0.encrypt(roomId: _room, plainText: '다시');
      expect(s0.encode(), raw);
      expect(first.state.sendCount, 1);
      // 같은 상태에서 다시 하면 같은 번호 — 그래서 부른 쪽이 돌려받은 상태를 저장해야 한다.
      expect(first.envelope['n'], 0);
      expect(again.envelope['n'], 0);
      // 받는 쪽은 그 번호를 한 번만 받는다.
      expect(await _recv(p.alice, _wire(first.envelope)), '첫 번째');
      expect(await _recv(p.alice, _wire(again.envelope)), isNull);
    });
  });

  group('새 규약(v3) 래칫 — 주고받기', () {
    test('수락한 기기가 먼저(0번 체인으로) 보내도 대화가 이어지고, 차례마다 새 래칫 키·pn이 맞다', () async {
      final p = await _handshake();
      final first = await _send(p.bob, '먼저 보낸 글');
      expect(first['v'], crypto.secretProtocolV3);
      expect(first['s'], secretRoleResponder);
      expect(first['dh'], p.responderEphemeralPublicKey);
      expect(first['pn'], 0);
      expect(first['n'], 0);
      // 예전 앱이 봉투를 읽다 멈추지 않게 두는 정수 epoch, 12바이트 nonce, 평문 + 16바이트 태그.
      expect(first['epoch'], isA<int>());
      expect(base64Decode(first['nonce'] as String).length, 12);
      expect(
        base64Decode(first['ciphertext'] as String).length,
        utf8.encode('먼저 보낸 글').length + 16,
      );
      expect(await _recv(p.alice, first), '먼저 보낸 글');
      // 초대한 기기의 첫 답은 시작할 때 만든 키 그대로(0번 체인은 기다리던 체인이라 래칫이 넘어가지 않는다).
      final reply = await _send(p.alice, '답');
      expect(reply['s'], secretRoleInitiator);
      expect(reply['dh'], isNot(p.responderEphemeralPublicKey));
      expect(reply['pn'], 0);
      expect(reply['n'], 0);
      expect(await _recv(p.bob, reply), '답');
      // 수락한 기기는 답을 받으며 래칫을 넘겼다 — 다음 글은 새 키, pn은 0번 체인에서 보낸 수.
      final next = await _send(p.bob, '다음');
      expect(next['dh'], isNot(p.responderEphemeralPublicKey));
      expect(next['pn'], 1);
      expect(next['n'], 0);
      expect(await _recv(p.alice, next), '다음');
      await _alternate(p.alice, p.bob, rounds: 40);
    });

    test('초대한 기기가 먼저 보내도 대화가 이어진다', () async {
      final p = await _handshake();
      final first = await _send(p.alice, '초대한 쪽이 먼저');
      expect(first['s'], secretRoleInitiator);
      expect(first['dh'], p.alice.state.sendingPublicKey);
      expect(first['dh'], isNot(p.responderEphemeralPublicKey));
      expect(first['pn'], 0);
      expect(first['n'], 0);
      expect(await _recv(p.bob, first), '초대한 쪽이 먼저');
      // 수락한 기기는 0번 체인으로 하나도 보내지 않았으니 pn은 0.
      final reply = await _send(p.bob, '답');
      expect(reply['dh'], isNot(p.responderEphemeralPublicKey));
      expect(reply['pn'], 0);
      expect(await _recv(p.alice, reply), '답');
      await _alternate(p.alice, p.bob, rounds: 40);
    });

    test('처음부터 두 기기가 서로 받기 전에 보내도 각자 상대 메시지를 푼다', () async {
      final p = await _handshake();
      final fromBob = await _sendMany(p.bob, 2, 'b-');
      final fromAlice = await _sendMany(p.alice, 2, 'a-');
      // 번호는 겹쳐도 체인(래칫 키)이 다르다 — 수락한 기기는 자기 임시키, 초대한 기기는 시작할 때 만든 키.
      expect(fromBob[0]['n'], fromAlice[0]['n']);
      expect(fromBob[0]['dh'], p.responderEphemeralPublicKey);
      expect(fromAlice[0]['dh'], isNot(fromBob[0]['dh']));
      expect(await _recv(p.bob, fromAlice[1]), 'a-1');
      expect(await _recv(p.alice, fromBob[0]), 'b-0');
      expect(await _recv(p.bob, fromAlice[0]), 'a-0');
      expect(await _recv(p.alice, fromBob[1]), 'b-1');
      await _alternate(p.alice, p.bob, rounds: 12);
    });

    test('대화 중에 동시에 여러 개씩 보내고 엇갈려 받아도 풀리고, 그 뒤로도 이어진다', () async {
      final p = await _handshake();
      await _alternate(p.bob, p.alice, rounds: 3);
      for (var phase = 0; phase < 5; phase++) {
        final aliceTexts = [for (var i = 0; i < 3; i++) '동시 a$phase-$i'];
        final bobTexts = [for (var i = 0; i < 3; i++) '동시 b$phase-$i'];
        final fromAlice = [for (final t in aliceTexts) await _send(p.alice, t)];
        final fromBob = [for (final t in bobTexts) await _send(p.bob, t)];
        for (final i in [2, 0, 1]) {
          expect(await _recv(p.alice, fromBob[i]), bobTexts[i]);
        }
        for (final i in [0, 2, 1]) {
          expect(await _recv(p.bob, fromAlice[i]), aliceTexts[i]);
        }
      }
      // 한쪽이 상대 것을 받자마자 또 보내, 새 체인 메시지가 이전 체인 메시지보다 먼저 가는 경우.
      final x = await _sendMany(p.alice, 2, 'x');
      final y = await _send(p.bob, 'y');
      expect(await _recv(p.alice, y), 'y');
      final z = await _send(p.alice, 'z');
      expect(z['dh'], isNot(x[0]['dh']));
      expect(await _recv(p.bob, z), 'z');
      expect(await _recv(p.bob, x[1]), 'x1');
      expect(await _recv(p.bob, x[0]), 'x0');
      await _alternate(p.alice, p.bob, rounds: 8);
      await _alternate(p.bob, p.alice, rounds: 8);
    });

    test('빈 글·긴 글·이모지·줄바꿈·봉투처럼 생긴 글도 그대로 풀린다', () async {
      final p = await _handshake();
      final texts = [
        '',
        ' ',
        '줄\n바꿈\t탭\r\n',
        '😀👍🏽 한글 漢字 العربية',
        '{"v":3,"s":"r","n":0}',
        'ㄱ' * 50000,
      ];
      for (final t in texts) {
        final envelope = await _send(p.bob, t);
        expect(
          base64Decode(envelope['ciphertext'] as String).length,
          utf8.encode(t).length + 16,
        );
        expect(await _recv(p.alice, envelope), t);
      }
      for (final t in texts.reversed) {
        expect(await _recv(p.bob, await _send(p.alice, t)), t);
      }
    });
  });

  group('새 규약(v3) 래칫 — 순서 뒤바뀜·늦게 온 메시지', () {
    test('한 체인 안에서 순서가 뒤바뀌어도(2번이 0·1번보다 먼저) 모두 풀린다', () async {
      final p = await _handshake();
      // 수락한 기기의 0번 체인.
      final b = await _sendMany(p.bob, 3, 'b');
      expect(await _recv(p.alice, b[2]), 'b2');
      expect(p.alice.state.receiveCount, 3);
      expect([for (final k in p.alice.state.skipped) k.n], [0, 1]);
      expect(await _recv(p.alice, b[0]), 'b0');
      expect(await _recv(p.alice, b[1]), 'b1');
      expect(p.alice.state.skipped, isEmpty);

      // 받는 쪽이 래칫을 넘겨야 하는 새 체인 — 처음 받은 것이 그 체인의 3번이다.
      final a = await _sendMany(p.alice, 4, 'a');
      expect(await _recv(p.bob, a[3]), 'a3');
      expect(p.bob.state.skipped.length, 3);
      expect(p.bob.state.skipped.every((k) => k.chain == a[0]['dh']), isTrue);
      for (final i in [1, 0, 2]) {
        expect(await _recv(p.bob, a[i]), 'a$i');
      }
      expect(p.bob.state.skipped, isEmpty);
      await _alternate(p.bob, p.alice, rounds: 4);
    });

    test(
      '상대가 래칫을 넘긴 뒤에 온 이전 체인 메시지는 pn만큼 남겨 둔 키로 풀린다 — 상태를 저장·복원해도 그대로',
      () async {
        final p = await _handshake();
        final old = await _sendMany(p.bob, 3, 'old'); // 0번 체인
        expect(await _recv(p.alice, old[0]), 'old0');
        // 초대한 기기가 답하고, 수락한 기기가 받아 래칫을 넘긴 뒤 보낸다.
        expect(await _recv(p.bob, await _send(p.alice, '답')), '답');
        final next = await _send(p.bob, 'new0');
        expect(next['dh'], isNot(old[0]['dh']));
        expect(next['pn'], 3); // 0번 체인에서 보낸 수
        expect(next['n'], 0);
        expect(await _recv(p.alice, next), 'new0');
        // 0번 체인의 1·2번 키를 남겨 두었다.
        final oldChain = old[0]['dh'] as String;
        expect(
          [for (final k in p.alice.state.skipped) (k.chain, k.n)],
          [(oldChain, 1), (oldChain, 2)],
        );
        // 저장·복원 — 남겨 둔 키도 상태 JSON 안에 있다.
        final stored = p.alice.state.encode();
        expect((jsonDecode(stored) as Map)['sk'], isNotNull);
        _restore(p.alice);
        expect(await _recv(p.alice, old[2]), 'old2');
        _restore(p.alice);
        expect(await _recv(p.alice, old[1]), 'old1');
        expect(p.alice.state.skipped, isEmpty);
        expect(
          (jsonDecode(p.alice.state.encode()) as Map).containsKey('sk'),
          isFalse,
        );
        await _alternate(p.alice, p.bob, rounds: 6);
      },
    );

    test('두 걸음 전 체인에서 늦게 온 메시지도 남겨 둔 키로 풀린다', () async {
      final p = await _handshake();
      expect(await _recv(p.bob, await _send(p.alice, 'a0')), 'a0');
      final chain1 = await _sendMany(p.bob, 2, 'c1-'); // 수락한 기기의 두 번째 체인
      expect(chain1[0]['pn'], 0);
      expect(await _recv(p.alice, chain1[0]), 'c1-0');
      expect(await _recv(p.bob, await _send(p.alice, 'a1')), 'a1');
      final chain2 = await _send(p.bob, 'c2-0');
      expect(chain2['pn'], 2);
      expect(await _recv(p.alice, chain2), 'c2-0');
      expect(await _recv(p.bob, await _send(p.alice, 'a2')), 'a2');
      final chain3 = await _send(p.bob, 'c3-0');
      expect(chain3['pn'], 1);
      _restore(p.alice);
      expect(await _recv(p.alice, chain3), 'c3-0');
      // chain1의 1번은 받는 체인이 두 번 바뀐 뒤에 온다.
      expect(p.alice.state.receivingPublicKey, chain3['dh']);
      expect(
        [for (final k in p.alice.state.skipped) (k.chain, k.n)],
        [(chain1[0]['dh'] as String, 1)],
      );
      _restore(p.alice);
      expect(await _recv(p.alice, chain1[1]), 'c1-1');
      expect(p.alice.state.skipped, isEmpty);
      await _alternate(p.alice, p.bob, rounds: 4);
    });
  });

  group('새 규약(v3) 래칫 — 같은 메시지가 또 옴', () {
    test('같은 봉투가 두 번 오면 두 번째는 null — 상태는 그대로이고 다음 메시지도 풀린다', () async {
      final p = await _handshake();
      // 같은 체인 안(래칫 없음).
      final b0 = await _send(p.bob, 'b0');
      expect(await _recv(p.alice, b0), 'b0');
      final aliceBefore = _snapshot(p.alice);
      expect(await _recv(p.alice, b0), isNull);
      expect(_snapshot(p.alice), aliceBefore);
      expect(await _recv(p.alice, await _send(p.bob, 'b1')), 'b1');

      // 받는 쪽이 래칫을 넘기게 한 메시지(새 체인의 첫 메시지).
      final a0 = await _send(p.alice, 'a0');
      expect(await _recv(p.bob, a0), 'a0');
      final bobBefore = _snapshot(p.bob);
      expect(await _recv(p.bob, a0), isNull);
      expect(_snapshot(p.bob), bobBefore);
      expect(await _recv(p.bob, await _send(p.alice, 'a1')), 'a1');

      // 체인이 몇 번 바뀐 뒤에 다시 온 예전 메시지 — 처음 보는 래칫 키처럼 보이지만 풀리지 않고 루트도 그대로.
      await _alternate(p.bob, p.alice, rounds: 4);
      for (final (to, envelope) in [(p.alice, b0), (p.bob, a0)]) {
        final before = _snapshot(to);
        expect(await _recv(to, envelope), isNull);
        expect(_snapshot(to), before);
      }
      await _alternate(p.alice, p.bob, rounds: 4);
    });

    test('남겨 둔 키로 푼 메시지가 또 오면 null — 남겨 둔 키는 한 번 쓰면 지운다', () async {
      final p = await _handshake();
      final b = await _sendMany(p.bob, 2, 'b');
      expect(await _recv(p.alice, b[1]), 'b1');
      expect(await _recv(p.alice, b[0]), 'b0'); // 남겨 둔 키로
      expect(p.alice.state.skipped, isEmpty);
      final before = _snapshot(p.alice);
      expect(await _recv(p.alice, b[0]), isNull);
      expect(_snapshot(p.alice), before);

      // 래칫을 넘긴 뒤 남겨 둔 키로 푼 이전 체인 메시지도.
      final old = await _sendMany(p.bob, 2, 'old');
      expect(await _recv(p.alice, old[0]), 'old0');
      expect(await _recv(p.bob, await _send(p.alice, 'x')), 'x');
      expect(await _recv(p.alice, await _send(p.bob, 'new')), 'new');
      expect(await _recv(p.alice, old[1]), 'old1');
      final before2 = _snapshot(p.alice);
      expect(await _recv(p.alice, old[1]), isNull);
      expect(_snapshot(p.alice), before2);
      expect(await _recv(p.alice, await _send(p.bob, 'new2')), 'new2');
    });
  });

  group('새 규약(v3) 래칫 — 변조·자기 메시지', () {
    test(
      '암호문·태그·nonce 한 바이트, n·pn·dh·방 중 하나라도 바뀌면 풀리지 않고, 상태가 그대로라 진짜는 그 뒤에도 풀린다',
      () async {
        final p = await _handshake();
        final stranger = await _publicKeyBase64(await X25519().newKeyPair());
        // 1) 받는 체인 그대로(0번 체인)의 메시지 — 0번은 늦게 오게 남겨 둔다.
        final b = await _sendMany(p.bob, 2, '0번 체인 ');
        await _expectTamperingRejected(
          p.alice,
          b[1],
          '0번 체인 1',
          otherKeys: [stranger, p.alice.state.sendingPublicKey],
        );
        // 2) 받는 쪽이 래칫을 넘겨야 하는 새 체인의 첫 메시지(수락한 기기는 아직 받는 체인이 없다).
        final a = await _send(p.alice, '첫 래칫');
        await _expectTamperingRejected(
          p.bob,
          a,
          '첫 래칫',
          otherKeys: [stranger, p.responderEphemeralPublicKey],
        );
        // 3) 받는 체인이 있는 쪽이 래칫을 넘길 메시지(pn = 2).
        final next = await _send(p.bob, '두 번째 체인');
        expect(next['pn'], 2);
        await _expectTamperingRejected(
          p.alice,
          next,
          '두 번째 체인',
          otherKeys: [
            stranger,
            b[0]['dh'] as String, // 0번 체인 — 남겨 둔 0번 키에 걸린다
            p.alice.state.sendingPublicKey,
          ],
        );
        // 4) 남겨 둔 키로 풀 늦은 메시지(0번 체인의 0번) — 변조된 것에 키를 쓰지 않는다.
        await _expectTamperingRejected(
          p.alice,
          b[0],
          '0번 체인 0',
          otherKeys: [stranger, next['dh'] as String],
        );
        expect(p.alice.state.skipped, isEmpty);
        // 5) 앞 번호를 받고 다음 번호를 기다릴 때 — n을 이미 받은 번호로 낮춘 봉투('n - 1')가 기다리던 번호의
        //    키로 풀리면 안 된다(이미 받은 번호 검사와 AAD의 n이 함께 막는다).
        final c = await _sendMany(p.bob, 2, '같은 체인 ');
        expect(await _recv(p.alice, c[0]), '같은 체인 0');
        expect(p.alice.state.receiveCount, c[1]['n']);
        await _expectTamperingRejected(
          p.alice,
          c[1],
          '같은 체인 1',
          otherKeys: [stranger],
        );
        await _alternate(p.alice, p.bob, rounds: 6);
      },
    );

    test(
      '보낸 쪽 표시(s)를 바꾸면 — 받는 쪽 자기 표시가 되거나, 되돌아온 자기 메시지가 되어 풀리지 않는다',
      () async {
        final p = await _handshake();
        final b0 = await _send(p.bob, 'b0');
        final a0 = await _send(p.alice, 'a0');
        // 상대 메시지의 표시를 받는 쪽 자기 것으로 — 자기가 보낸 것으로 보고 거른다.
        var before = _snapshot(p.alice);
        expect(await _recv(p.alice, {...b0, 's': secretRoleInitiator}), isNull);
        expect(_snapshot(p.alice), before);
        // 자기가 보낸 것의 표시를 상대 것으로 바꿔 되돌려 보냄(반사) — 래칫 키가 자기 것이라 풀리지 않는다.
        before = _snapshot(p.alice);
        expect(await _recv(p.alice, {...a0, 's': secretRoleResponder}), isNull);
        expect(_snapshot(p.alice), before);
        before = _snapshot(p.bob);
        expect(await _recv(p.bob, {...b0, 's': secretRoleInitiator}), isNull);
        expect(_snapshot(p.bob), before);
        // 's' 값이 둘 중 하나가 아니면 모양부터 틀렸다.
        expect(SecretEnvelopeV3.tryParse({...b0, 's': 'x'}), isNull);
        // 진짜는 그대로 풀린다.
        expect(await _recv(p.alice, b0), 'b0');
        expect(await _recv(p.bob, a0), 'a0');
        await _alternate(p.bob, p.alice, rounds: 4);
      },
    );

    test(
      'dh의 맨 윗비트만 바꾼 봉투 — X25519에서는 같은 점이라 공유비밀이 같아도, 머리(AAD)에 묶여 있어 풀리지 않는다',
      () async {
        final p = await _handshake();
        // 받는 쪽(수락한 기기)이 이 메시지로 래칫을 넘겨야 한다 — 바꾼 키로 넘어가면 진짜 키의 메시지를 못 풀게 된다.
        final a0 = await _send(p.alice, 'a0');
        final dh = a0['dh'] as String;
        final flipped = _flipTopBit(dh);
        expect(flipped, isNot(dh));
        expect(SecretEnvelopeV3.tryParse({...a0, 'dh': flipped}), isNotNull);
        // 같은 점이다 — 수락한 기기의 래칫 키로 계산한 공유비밀이 같다(그래서 막는 것은 AAD뿐이다).
        final bobKey = await X25519().newKeyPairFromSeed(
          p.bob.state.sendingKeySeed,
        );
        expect(
          await crypto.x25519SharedSecret(bobKey, base64Decode(flipped)),
          equals(await crypto.x25519SharedSecret(bobKey, base64Decode(dh))),
        );
        final before = _snapshot(p.bob);
        expect(await _recv(p.bob, {...a0, 'dh': flipped}), isNull);
        expect(_snapshot(p.bob), before);
        expect(await _recv(p.bob, a0), 'a0');
        expect(await _recv(p.bob, await _send(p.alice, 'a1')), 'a1');
        await _alternate(p.bob, p.alice, rounds: 4);
      },
    );

    test('다른 핸드셰이크(다른 대화)의 기기는 같은 방 이름이라도 풀지 못한다', () async {
      final p1 = await _handshake();
      final p2 = await _handshake();
      final fromAlice = await _send(p1.alice, '첫 대화의 비밀');
      final fromBob = await _send(p1.bob, '첫 대화의 비밀 2');
      for (final (device, envelope) in [
        (p2.bob, fromAlice),
        (p2.alice, fromBob),
      ]) {
        final before = _snapshot(device);
        expect(await _recv(device, envelope), isNull);
        expect(_snapshot(device), before);
      }
      expect(await _recv(p1.bob, fromAlice), '첫 대화의 비밀');
      expect(await _recv(p1.alice, fromBob), '첫 대화의 비밀 2');
      // 두 번째 대화는 그대로 쓸 수 있다.
      await _alternate(p2.alice, p2.bob, rounds: 3);
    });

    test('자기가 보낸 봉투(보낸 쪽 == 자기 역할)는 풀지 않는다 — 상태도 그대로', () async {
      final p = await _handshake();
      final a0 = await _send(p.alice, 'a0');
      final b0 = await _send(p.bob, 'b0');
      for (final (device, envelope) in [(p.alice, a0), (p.bob, b0)]) {
        final parsed = SecretEnvelopeV3.tryParse(envelope)!;
        expect(parsed.sender, device.state.role);
        final before = _snapshot(device);
        expect(
          await device.state.decrypt(roomId: _room, envelope: parsed),
          isNull,
        );
        expect(_snapshot(device), before);
      }
      expect(await _recv(p.bob, a0), 'a0');
      expect(await _recv(p.alice, b0), 'b0');
      // 대화가 오간 뒤에도.
      final a1 = await _send(p.alice, 'a1');
      expect(await _recv(p.alice, a1), isNull);
      expect(await _recv(p.bob, a1), 'a1');
      final b1 = await _send(p.bob, 'b1');
      expect(await _recv(p.bob, b1), isNull);
      expect(await _recv(p.alice, b1), 'b1');
    });
  });

  group('새 규약(v3) 래칫 — 건너뛰기 상한', () {
    test(
      '한 체인에서 한 번에 건너뛸 수 있는 번호는 secretRatchetMaxSkip개까지 — 하나라도 넘으면 풀지 않는다',
      () async {
        expect(secretRatchetMaxSkip, 2000);
        final p = await _handshake();
        final m = await _sendMany(p.bob, secretRatchetMaxSkip + 2, 'm');
        final before = _snapshot(p.alice);
        // 0번부터 2000번까지 2001개를 건너뛰어야 한다 — 거른다.
        expect(await _recv(p.alice, m[secretRatchetMaxSkip + 1]), isNull);
        expect(_snapshot(p.alice), before);
        // 꼭 2000개면 받는다.
        expect(await _recv(p.alice, m[secretRatchetMaxSkip]), 'm2000');
        expect(p.alice.state.skipped.length, secretRatchetMaxSkip);
        // 이제 바로 다음 번호.
        expect(await _recv(p.alice, m[secretRatchetMaxSkip + 1]), 'm2001');
        // 건너뛴 것들은 남겨 둔 키로 — 저장·복원해도.
        expect(await _recv(p.alice, m[0]), 'm0');
        _restore(p.alice);
        expect(await _recv(p.alice, m[1999]), 'm1999');
        expect(await _recv(p.alice, m[1000]), 'm1000');
        expect(p.alice.state.skipped.length, secretRatchetMaxSkip - 3);
      },
    );

    test(
      '새 래칫 키의 pn이 지금 받는 체인을 secretRatchetMaxSkip개 넘게 건너뛰게 하면 풀지 않는다',
      () async {
        final p = await _handshake();
        // 0번 체인 2001개 — 초대한 기기는 하나도 못 받았다.
        final chain0 = await _sendMany(p.bob, secretRatchetMaxSkip + 1, 'z');
        expect(await _recv(p.bob, await _send(p.alice, 'a0')), 'a0');
        final c = await _send(p.bob, 'c0');
        expect(c['pn'], secretRatchetMaxSkip + 1);
        final before = _snapshot(p.alice);
        expect(await _recv(p.alice, c), isNull);
        expect(_snapshot(p.alice), before);
        // 0번 체인에서 하나를 받고 나면 건너뛸 것이 꼭 2000개라 받는다.
        expect(await _recv(p.alice, chain0[0]), 'z0');
        expect(await _recv(p.alice, c), 'c0');
        expect(p.alice.state.skipped.length, secretRatchetMaxSkip);
        expect(await _recv(p.alice, chain0[secretRatchetMaxSkip]), 'z2000');
        expect(await _recv(p.alice, chain0[1]), 'z1');
        await _alternate(p.alice, p.bob, rounds: 4);
      },
    );

    test(
      '꾸민 큰 번호(n·pn = 2^31 - 1)는 계산을 오래 하지 않고 바로 거르고, 2^31 이상은 읽지도 않는다',
      () async {
        final p = await _handshake();
        const huge = (1 << 31) - 1;
        final b0 = await _send(p.bob, 'b0');
        expect(await _recv(p.alice, {...b0, 'n': huge}), isNull);
        final a0 = await _send(p.alice, 'a0');
        expect(await _recv(p.bob, a0), 'a0');
        final c0 = await _send(p.bob, 'c0'); // 새 래칫 키, pn = 1
        expect(await _recv(p.alice, {...c0, 'pn': huge}), isNull);
        expect(await _recv(p.alice, {...c0, 'n': huge}), isNull);
        // 상한 바로 안쪽(꼭 2000개)이라도 꾸민 머리는 AAD가 맞지 않아 풀리지 않는다(남긴 키도 저장되지 않는다).
        expect(
          await _recv(p.alice, {...b0, 'n': secretRatchetMaxSkip}),
          isNull,
        );
        expect(
          await _recv(p.alice, {...c0, 'pn': secretRatchetMaxSkip}),
          isNull,
        );
        expect(p.alice.state.skipped, isEmpty);
        expect(SecretEnvelopeV3.tryParse({...b0, 'n': 1 << 31}), isNull);
        expect(SecretEnvelopeV3.tryParse({...c0, 'pn': 1 << 31}), isNull);
        // 진짜는 그대로.
        expect(await _recv(p.alice, b0), 'b0');
        expect(await _recv(p.alice, c0), 'c0');
      },
      // 상한이 없으면 2^31번을 감느라 끝나지 않는다.
      timeout: const Timeout(Duration(seconds: 20)),
    );

    test(
      '남겨 둔 키는 secretRatchetMaxStoredSkipped개까지 — 넘으면 가장 오래된 것부터 버려 그 메시지는 더는 풀 수 없다',
      () async {
        expect(secretRatchetMaxStoredSkipped, 2000);
        final p = await _handshake();
        final m = await _sendMany(p.bob, 2101, 'k');
        expect(await _recv(p.alice, m[1500]), 'k1500'); // 0~1499 (1500개)
        // 1501~2099 (599개) — 모두 2099개라 가장 오래된 99개(0~98)를 버린다.
        expect(await _recv(p.alice, m[2100]), 'k2100');
        final skipped = p.alice.state.skipped;
        expect(skipped.length, secretRatchetMaxStoredSkipped);
        expect(skipped.first.n, 99);
        expect(skipped.last.n, 2099);
        expect(await _recv(p.alice, m[98]), isNull);
        expect(await _recv(p.alice, m[0]), isNull);
        for (final i in [99, 1499, 1501, 2099]) {
          expect(await _recv(p.alice, m[i]), 'k$i');
        }
        expect(p.alice.state.skipped.length, secretRatchetMaxStoredSkipped - 4);
      },
    );

    test(
      '한 메시지로 건너뛰는 수는 이전 체인 나머지(pn까지)와 새 체인 앞쪽(n까지)을 합해 secretRatchetMaxSkip까지 — 넘으면 풀지 않고, 상태도 그대로라 앞쪽 메시지를 받으면 다시 풀린다',
      () async {
        final p = await _handshake();
        // 0번 체인 1500개 — 하나도 못 받았다.
        final old = await _sendMany(p.bob, 1500, 'old');
        expect(await _recv(p.bob, await _send(p.alice, 'a0')), 'a0');
        // 새 체인 600개 — 마지막 것을 먼저 받으면 이전 체인 1500 + 새 체인 599 = 2099개를 건너뛰어야 한다.
        final fresh = await _sendMany(p.bob, 600, 'new');
        expect(fresh.first['pn'], 1500);
        final before = p.alice.state.encode();
        expect(await _recv(p.alice, fresh.last), isNull);
        expect(p.alice.state.encode(), before, reason: '못 푼 메시지는 상태를 바꾸지 않는다');
        // 이전 체인 1500 + 새 체인 500 = 2000 — 딱 상한이라 풀린다.
        expect(await _recv(p.alice, fresh[500]), 'new500');
        expect(p.alice.state.skipped.length, 2000);
        // 남겨 둔 키로 나머지도 다 풀린다(이전 체인·새 체인 앞쪽), 그 뒤 것은 차례대로.
        expect(await _recv(p.alice, old.first), 'old0');
        expect(await _recv(p.alice, old.last), 'old1499');
        expect(await _recv(p.alice, fresh.first), 'new0');
        expect(await _recv(p.alice, fresh[499]), 'new499');
        expect(await _recv(p.alice, fresh[501]), 'new501');
        expect(await _recv(p.alice, fresh.last), 'new599');
      },
    );
  });

  group('남겨 둔 키 도우미', () {
    List<int> keyOf(int seed) =>
        List<int>.generate(32, (i) => (seed * 31 + i) & 0xff);
    List<SecretSkippedKey> make(String chain, int from, int count) => [
      for (var i = from; i < from + count; i++)
        SecretSkippedKey(chain, i, keyOf(i)),
    ];

    test(
      'encodeSkippedKeys → decodeSkippedKeys: 같은 체인 값은 한 번만 적고, JSON을 거쳐도 순서·값이 그대로',
      () {
        final keys = [
          SecretSkippedKey('chain-A', 0, keyOf(1)),
          SecretSkippedKey('chain-B', 7, keyOf(2)),
          SecretSkippedKey('chain-A', 2, keyOf(3)),
          SecretSkippedKey('e3', 5, keyOf(4)),
        ];
        final encoded = encodeSkippedKeys(keys) as Map;
        expect(encoded['c'], ['chain-A', 'chain-B', 'e3']);
        expect(encoded['e'], hasLength(4));
        final decoded = decodeSkippedKeys(jsonDecode(jsonEncode(encoded)));
        expect(decoded, isNotNull);
        expect(decoded!.length, keys.length);
        for (var i = 0; i < keys.length; i++) {
          expect(decoded[i].chain, keys[i].chain);
          expect(decoded[i].n, keys[i].n);
          expect(decoded[i].key, equals(keys[i].key));
        }
        expect(decodeSkippedKeys(encodeSkippedKeys(const [])), isEmpty);
      },
    );

    test(
      'decodeSkippedKeys: null이면 빈 목록, 모양이 틀리면 null, 깨진 항목은 빼고 나머지를 읽는다',
      () {
        expect(decodeSkippedKeys(null), isNotNull);
        expect(decodeSkippedKeys(null), isEmpty);
        for (final bad in <Object>[
          'x',
          3,
          const <Object>[],
          <String, Object>{},
          {'c': 'x', 'e': <Object>[]},
          {'c': <Object>[], 'e': 'x'},
          {
            'c': ['a'],
          },
          {'e': <Object>[]},
        ]) {
          expect(decodeSkippedKeys(bad), isNull, reason: '$bad');
        }
        final good = base64Encode(keyOf(9));
        final raw = {
          'c': ['A', 5, 'B'],
          'e': [
            [0, 1, good], // 그대로
            [0, 2], // 칸 수가 틀림
            [0, 3, good, 'x'], // 칸 수가 틀림
            [3, 4, good], // 없는 체인 자리
            [-1, 5, good], // 음수 체인 자리
            [1, 6, good], // 체인 값이 글자가 아님
            ['0', 7, good], // 체인 자리가 정수가 아님
            [0, '8', good], // 번호가 정수가 아님
            [0, 9, 42], // 키가 글자가 아님
            [0, 10, '***'], // base64가 아님
            [0, 11, base64Encode(List<int>.filled(16, 1))], // 32바이트가 아님
            'not-a-list',
            [2, 12, good], // 그대로
          ],
        };
        final decoded = decodeSkippedKeys(jsonDecode(jsonEncode(raw)));
        expect(decoded, isNotNull);
        expect(
          [for (final k in decoded!) (k.chain, k.n)],
          [('A', 1), ('B', 12)],
        );
        expect(decoded.first.key, equals(keyOf(9)));
      },
    );

    test(
      'appendSkippedKeys: 뒤에 붙이고, secretRatchetMaxStoredSkipped를 넘으면 가장 오래된 것부터 버린다',
      () {
        const cap = secretRatchetMaxStoredSkipped;
        final existing = make('old', 0, cap - 1);
        // 더할 것이 없으면 그대로.
        expect(
          identical(appendSkippedKeys(existing, const []), existing),
          isTrue,
        );
        // 상한 안이면 그대로 이어 붙는다.
        final one = appendSkippedKeys(existing, make('new', 0, 1));
        expect(one.length, cap);
        expect((one.first.chain, one.first.n), ('old', 0));
        expect((one.last.chain, one.last.n), ('new', 0));
        // 넘으면 오래된 것(앞)부터 버린다.
        final over = appendSkippedKeys(existing, make('new', 0, 3));
        expect(over.length, cap);
        expect((over.first.chain, over.first.n), ('old', 2));
        expect((over.last.chain, over.last.n), ('new', 2));
        // 더하는 것만으로 상한을 넘으면 그중 새 것만 남는다.
        final flood = appendSkippedKeys(const [], make('flood', 0, cap + 500));
        expect(flood.length, cap);
        expect(flood.first.n, 500);
        expect(flood.last.n, cap + 499);
        // 원래 목록은 고치지 않는다.
        expect(existing.length, cap - 1);
        expect(existing.first.n, 0);
      },
    );

    test('indexOfSkippedKey: 체인 값과 번호가 둘 다 맞아야 찾는다', () {
      final keys = [
        SecretSkippedKey('A', 1, keyOf(1)),
        SecretSkippedKey('B', 1, keyOf(2)),
        SecretSkippedKey('A', 2, keyOf(3)),
      ];
      expect(indexOfSkippedKey(keys, 'A', 1), 0);
      expect(indexOfSkippedKey(keys, 'B', 1), 1);
      expect(indexOfSkippedKey(keys, 'A', 2), 2);
      expect(indexOfSkippedKey(keys, 'B', 2), -1);
      expect(indexOfSkippedKey(keys, 'C', 1), -1);
      expect(indexOfSkippedKey(const [], 'A', 1), -1);
    });
  });

  group('래칫 상태 저장 형식(encode/decode)', () {
    test(
      'encode → decode는 같은 값이고, 복원한 상태로 대화가 그대로 이어진다(첫 래칫·늦은 메시지 포함)',
      () async {
        final p = await _handshake();
        // 수락한 기기의 처음 상태(받는 체인 없음) — 복원한 시드로 첫 래칫을 넘길 수 있어야 한다.
        final bobInitial = jsonDecode(p.bob.state.encode()) as Map;
        expect(bobInitial.containsKey('dr'), isFalse);
        expect(bobInitial.containsKey('cr'), isFalse);
        expect(bobInitial.containsKey('sk'), isFalse);
        _restore(p.bob);
        _restore(p.alice);
        final a = await _sendMany(p.alice, 3, 'a');
        expect(await _recv(p.bob, a[2]), 'a2'); // 래칫 + 2개 남김
        final b = await _sendMany(p.bob, 2, 'b');
        expect(await _recv(p.alice, b[1]), 'b1'); // 래칫 + 1개 남김
        for (final device in [p.alice, p.bob]) {
          final role = device.state.role;
          final skipped = device.state.skipped.length;
          _restore(device);
          expect(device.state.role, role);
          expect(device.state.skipped.length, skipped);
        }
        expect(await _recv(p.bob, a[0]), 'a0');
        expect(await _recv(p.alice, b[0]), 'b0');
        expect(await _recv(p.bob, a[1]), 'a1');
        // 복원한 시드로 다음 래칫들도 넘어간다.
        await _alternate(p.alice, p.bob, rounds: 6);
        _restore(p.alice);
        _restore(p.bob);
        await _alternate(p.bob, p.alice, rounds: 6);
      },
    );

    test(
      '깨진 상태는 decode가 null — JSON 아님·v·role·키 길이·숫자 타입·받는 체인과 상대 키의 짝',
      () async {
        final p = await _handshake();
        // 받는 체인·남겨 둔 키까지 있는 상태를 만든다.
        final b = await _sendMany(p.bob, 2, 'b');
        expect(await _recv(p.alice, b[1]), 'b1');
        final good = jsonDecode(p.alice.state.encode()) as Map<String, dynamic>;
        expect(
          good.keys,
          containsAll([
            'v',
            'role',
            'rk',
            'ds',
            'dp',
            'cs',
            'ns',
            'pn',
            'dr',
            'cr',
            'nr',
            'sk',
          ]),
        );
        expect(SecretRatchetState.decode(jsonEncode(good)), isNotNull);

        for (final raw in ['', 'not json', '{', '[]', 'null', '"state"', '3']) {
          expect(SecretRatchetState.decode(raw), isNull, reason: raw);
        }
        Map<String, dynamic> without(String field) => {...good}..remove(field);
        Map<String, dynamic> withField(String field, Object? value) => {
          ...good,
          field: value,
        };
        final short = base64Encode(List<int>.filled(31, 1));
        final long = base64Encode(List<int>.filled(33, 1));
        final cases = <String, Map<String, dynamic>>{
          'v 없음': without('v'),
          'v = 2': withField('v', 2),
          "v = '3'": withField('v', '3'),
          'role 없음': without('role'),
          "role = 'x'": withField('role', 'x'),
          "role = 'I'": withField('role', 'I'),
          'role = null': withField('role', null),
          for (final field in ['rk', 'ds', 'cs']) ...{
            '$field 없음': without(field),
            '$field 31바이트': withField(field, short),
            '$field 33바이트': withField(field, long),
            '$field base64 아님': withField(field, '***'),
            '$field 숫자': withField(field, 7),
          },
          'dp 없음': without('dp'),
          'dp 숫자': withField('dp', 7),
          for (final field in ['ns', 'pn', 'nr']) ...{
            '$field 없음': without(field),
            '$field 글자': withField(field, '1'),
            '$field 실수': withField(field, 1.5),
          },
          '받는 체인 없이 상대 키만': without('cr'),
          '상대 키 없이 받는 체인만': without('dr'),
          'cr 31바이트': withField('cr', short),
          'cr base64 아님': withField('cr', '***'),
          'dr 숫자': withField('dr', 7),
          'sk 목록': withField('sk', <Object>[]),
          'sk 글자': withField('sk', 'x'),
          'sk 칸 없음': withField('sk', <String, Object>{}),
        };
        for (final entry in cases.entries) {
          expect(
            SecretRatchetState.decode(jsonEncode(entry.value)),
            isNull,
            reason: entry.key,
          );
        }
        // 남겨 둔 키 중 깨진 항목만 있으면 그것만 빼고 읽는다.
        final sk = good['sk'] as Map<String, dynamic>;
        final withBrokenEntry = withField('sk', {
          'c': sk['c'],
          'e': [
            ...(sk['e'] as List),
            [0, 1],
          ],
        });
        final restored = SecretRatchetState.decode(jsonEncode(withBrokenEntry));
        expect(restored, isNotNull);
        expect(restored!.skipped.length, 1);
        expect(restored.skipped.single.n, 0);
      },
    );
  });

  group('SecretEnvelopeV3.tryParse', () {
    late Map<String, dynamic> good;
    setUp(() async {
      final p = await _handshake();
      good = await _send(p.alice, '봉투 모양');
    });

    test('제대로 된 v3 봉투는 머리 값을 그대로 읽는다', () {
      final e = SecretEnvelopeV3.tryParse(good);
      expect(e, isNotNull);
      expect(e!.sender, secretRoleInitiator);
      expect(e.ratchetPublicKey, good['dh']);
      expect(e.ratchetKeyBytes, equals(base64Decode(good['dh'] as String)));
      expect(e.previousCount, good['pn']);
      expect(e.n, good['n']);
      expect(e.nonce, equals(base64Decode(good['nonce'] as String)));
      expect(e.nonce.length, 12);
      expect(e.cipherText, equals(base64Decode(good['ciphertext'] as String)));
      // epoch(예전 앱을 위한 자리값)는 없어도 된다.
      expect(SecretEnvelopeV3.tryParse({...good}..remove('epoch')), isNotNull);
    });

    test('v·s가 틀리거나, 칸이 빠졌거나, 타입이 틀리면 null', () {
      for (final v in [1, 2, 4, '3', null]) {
        expect(
          SecretEnvelopeV3.tryParse({...good, 'v': v}),
          isNull,
          reason: 'v=$v',
        );
      }
      for (final s in ['x', 'I', 'R', '', 'ir', null, 1]) {
        expect(
          SecretEnvelopeV3.tryParse({...good, 's': s}),
          isNull,
          reason: 's=$s',
        );
      }
      for (final field in ['v', 's', 'dh', 'pn', 'n', 'nonce', 'ciphertext']) {
        expect(
          SecretEnvelopeV3.tryParse({...good}..remove(field)),
          isNull,
          reason: '$field 없음',
        );
      }
      for (final (field, value) in <(String, Object?)>[
        ('dh', 7),
        ('dh', <int>[1, 2, 3]),
        ('dh', null),
        ('nonce', 12),
        ('nonce', null),
        ('ciphertext', true),
        ('ciphertext', null),
        ('pn', '0'),
        ('pn', 1.0),
        ('pn', 0.5),
        ('pn', null),
        ('n', '0'),
        ('n', 2.0),
        ('n', true),
        ('n', null),
      ]) {
        expect(
          SecretEnvelopeV3.tryParse({...good, field: value}),
          isNull,
          reason: '$field=$value',
        );
      }
      // JSON의 실수("1.0")도 정수로 보지 않는다.
      final floatN = jsonDecode('{"n": 1.0}') as Map<String, dynamic>;
      expect(SecretEnvelopeV3.tryParse({...good, ...floatN}), isNull);
    });

    test(
      'dh는 표준 base64로 적은 32바이트만 — 패딩 빠짐·URL-safe·%3D·길이 다름·base64 아님이면 null',
      () {
        // '+'와 '/'가 들어가는 키로 바꿔 모양만 본다(복호화는 하지 않는다).
        final bytes = List<int>.filled(32, 0xfb);
        final canonical = base64Encode(bytes);
        expect(canonical, contains('+'));
        expect(canonical, contains('/'));
        expect(
          SecretEnvelopeV3.tryParse({
            ...good,
            'dh': canonical,
          })?.ratchetPublicKey,
          canonical,
        );
        // Dart의 base64Decode는 URL-safe·'%3D' 패딩도 같은 바이트로 읽는다 — 다시 적어 비교해야 거른다.
        final urlSafe = base64Url.encode(bytes);
        expect(base64Decode(urlSafe), equals(bytes));
        expect(SecretEnvelopeV3.tryParse({...good, 'dh': urlSafe}), isNull);
        final percent = '${canonical.substring(0, canonical.length - 1)}%3D';
        expect(base64Decode(percent), equals(bytes));
        expect(SecretEnvelopeV3.tryParse({...good, 'dh': percent}), isNull);
        for (final bad in [
          canonical.replaceAll('=', ''), // 패딩 빠짐
          ' $canonical',
          '$canonical\n',
          base64Encode(List<int>.filled(31, 0xfb)),
          base64Encode(List<int>.filled(33, 0xfb)),
          base64Encode(List<int>.filled(64, 0xfb)),
          '',
          '***',
        ]) {
          expect(
            SecretEnvelopeV3.tryParse({...good, 'dh': bad}),
            isNull,
            reason: bad,
          );
        }
      },
    );

    test('nonce는 12바이트, 암호문(태그 포함)은 16바이트 이상만', () {
      for (final length in [0, 11, 13, 16]) {
        expect(
          SecretEnvelopeV3.tryParse({
            ...good,
            'nonce': base64Encode(List<int>.filled(length, 1)),
          }),
          isNull,
          reason: 'nonce $length바이트',
        );
      }
      expect(SecretEnvelopeV3.tryParse({...good, 'nonce': '***'}), isNull);
      for (final length in [0, 1, 15]) {
        expect(
          SecretEnvelopeV3.tryParse({
            ...good,
            'ciphertext': base64Encode(List<int>.filled(length, 1)),
          }),
          isNull,
          reason: '암호문 $length바이트',
        );
      }
      expect(SecretEnvelopeV3.tryParse({...good, 'ciphertext': '***'}), isNull);
      // 16바이트(빈 평문 + 태그)는 모양으로는 받는다 — 풀리는지는 복호화가 가린다.
      expect(
        SecretEnvelopeV3.tryParse({
          ...good,
          'ciphertext': base64Encode(List<int>.filled(16, 1)),
        }),
        isNotNull,
      );
    });

    test('pn·n은 0 이상 2^31 미만의 정수만', () {
      for (final field in ['pn', 'n']) {
        for (final bad in [-1, -(1 << 40), 1 << 31, (1 << 31) + 1, 1 << 53]) {
          expect(
            SecretEnvelopeV3.tryParse({...good, field: bad}),
            isNull,
            reason: '$field=$bad',
          );
        }
        for (final ok in [0, 1, 1999, (1 << 31) - 1]) {
          final e = SecretEnvelopeV3.tryParse({...good, field: ok});
          expect(e, isNotNull, reason: '$field=$ok');
          expect(field == 'pn' ? e!.previousCount : e!.n, ok);
        }
      }
    });
  });

  group('작은 차수의 점', () {
    test('머리의 dh가 0 같은 작은 차수의 점이면 공유비밀이 0이라 풀지 않고, 상태도 그대로다', () async {
      final p = await _handshake();
      // 리틀 엔디언 32바이트 u 좌표.
      List<int> u(BigInt value) => [
        for (var i = 0; i < 32; i++)
          ((value >> (8 * i)) & BigInt.from(0xff)).toInt(),
      ];
      final prime = (BigInt.one << 255) - BigInt.from(19);
      final lowOrder = <String, List<int>>{
        'u = 0': u(BigInt.zero),
        'u = 1': u(BigInt.one),
        'u = p - 1 (차수 2)': u(prime - BigInt.one),
        '차수 8의 점 ①': u(
          BigInt.parse(
            '325606250916557431795983626356110631294008115727848805560023387167927233504',
          ),
        ),
        '차수 8의 점 ②': u(
          BigInt.parse(
            '39382357235489614581723060781553021112529911719440698176882885853963445705823',
          ),
        ),
        // 같은 점을 다르게 적은 것 — p(= 0), p + 1(= 1), 맨 윗비트만 켠 0(X25519는 윗비트를 무시한다).
        'u = p': u(prime),
        'u = p + 1': u(prime + BigInt.one),
        'u = 0 + 윗비트': u(BigInt.one << 255),
      };
      final b0 = await _send(p.bob, 'b0');
      final a0 = await _send(p.alice, 'a0');
      for (final entry in lowOrder.entries) {
        final dh = base64Encode(entry.value);
        // 받는 체인이 있는 초대한 기기 — 지금 체인을 pn만큼 감은 뒤 DH에서 걸린다.
        var before = _snapshot(p.alice);
        expect(
          await _recv(p.alice, {...b0, 'dh': dh, 'pn': 3}),
          isNull,
          reason: entry.key,
        );
        expect(_snapshot(p.alice), before);
        // 아직 받는 체인이 없는 수락한 기기.
        before = _snapshot(p.bob);
        expect(
          await _recv(p.bob, {...a0, 'dh': dh}),
          isNull,
          reason: entry.key,
        );
        expect(_snapshot(p.bob), before);
      }
      expect(await _recv(p.alice, b0), 'b0');
      expect(await _recv(p.bob, a0), 'a0');
      // 대화 중에도 — 래칫을 넘길 메시지의 dh만 바꿔서.
      final b1 = await _send(p.bob, 'b1');
      final before = _snapshot(p.alice);
      expect(
        await _recv(p.alice, {
          ...b1,
          'dh': base64Encode(List<int>.filled(32, 0)),
        }),
        isNull,
      );
      expect(_snapshot(p.alice), before);
      expect(await _recv(p.alice, b1), 'b1');
    });
  });

  group('무작위로 엇갈린 대화', () {
    for (final seed in const [1, 7, 42, 2026, 31337]) {
      test(
        'seed $seed: 아무 때나 보내고 늦게·뒤섞여·두 번 와도 모든 메시지가 꼭 한 번, 제 글로 풀린다',
        () async {
          const messages = 320;
          final stats = await _simulate(seed, messages: messages);
          expect(stats.decrypted, messages);
          // 시나리오가 충분히 엇갈렸는지(순서는 seed로 정해져 늘 같다) — 래칫이 여러 번 넘어갔고, 늦게 온 메시지를
          // 남겨 둔 키로 풀었고(이전 체인 것 포함), 두 번 온 것·꾸민 것이 끼어들었고, 중간에 껐다 켰다.
          expect(stats.ratchetKeys.length, greaterThan(20));
          expect(stats.viaSkipped, greaterThan(0));
          expect(stats.lateAcrossChains, greaterThan(0));
          expect(stats.duplicatesRejected, greaterThan(0));
          expect(stats.forgedRejected, greaterThan(0));
          expect(stats.restores, greaterThan(0));
        },
      );
    }
  });
  group('남겨 둔 키의 수명·중복', () {
    Future<String?> recvAt(
      _Device to,
      Map<String, dynamic> envelope,
      int nowMs,
    ) async {
      final opened = await to.state.decrypt(
        roomId: _room,
        envelope: SecretEnvelopeV3.tryParse(_wire(envelope))!,
        nowMs: nowMs,
      );
      if (opened == null) return null;
      to.state = opened.state;
      return opened.plainText;
    }

    test(
      '남겨 둔 키는 남긴 때부터 secretSkippedKeyLifetime(30일)이 지나면 버린다 — 그 전에는 늦게 온 메시지가 풀린다',
      () async {
        final p = await _handshake();
        final sent = await _sendMany(p.bob, 3, 'late');
        const t0 = 1800000000000;
        final day = const Duration(days: 1).inMilliseconds;
        expect(await recvAt(p.alice, sent[2], t0), 'late2');
        expect(p.alice.state.skipped, hasLength(2));
        expect(p.alice.state.skipped.every((k) => k.storedAtMs == t0), isTrue);
        expect(await recvAt(p.alice, sent[0], t0 + 29 * day), 'late0');
        // 31일 뒤 — 남겨 둔 키가 버려져 풀 수 없다.
        expect(await recvAt(p.alice, sent[1], t0 + 31 * day), isNull);
        // 그 뒤 다른 메시지를 받을 때 버린 키는 저장할 상태에서도 빠진다.
        final fresh = await _send(p.bob, 'fresh');
        final opened = await p.alice.state.decrypt(
          roomId: _room,
          envelope: SecretEnvelopeV3.tryParse(_wire(fresh))!,
          nowMs: t0 + 31 * day,
        );
        expect(opened?.plainText, 'fresh');
        expect(opened!.skippedChanged, isTrue);
        expect(opened.state.skipped, isEmpty);
      },
    );

    test('차례대로 받으면 남겨 둔 키가 바뀌지 않았다고 알린다(저장소가 그 칸을 다시 쓰지 않게)', () async {
      final p = await _handshake();
      final first = await _send(p.bob, 'b0');
      final opened = await p.alice.state.decrypt(
        roomId: _room,
        envelope: SecretEnvelopeV3.tryParse(_wire(first))!,
      );
      expect(opened?.plainText, 'b0');
      expect(opened!.skippedChanged, isFalse);
    });

    test(
      'appendSkippedKeys는 이미 있는 체인·번호를 다시 넣지 않는다(저장하다 끊겨 같은 키를 다시 만든 경우)',
      () {
        final key = List<int>.filled(32, 1);
        final keys = [
          SecretSkippedKey('c', 0, key),
          SecretSkippedKey('c', 1, key),
        ];
        final out = appendSkippedKeys(keys, [
          SecretSkippedKey('c', 1, key),
          SecretSkippedKey('c', 2, key),
          SecretSkippedKey('d', 1, key),
        ]);
        expect(
          [for (final k in out) '${k.chain}${k.n}'],
          ['c0', 'c1', 'c2', 'd1'],
        );
      },
    );

    test(
      'pruneExpiredSkippedKeys: 버릴 것이 없으면 같은 목록(같은 객체)을, 남긴 시각을 모르는 키는 그대로 둔다',
      () {
        final key = List<int>.filled(32, 1);
        const now = 1800000000000;
        final old = now - const Duration(days: 40).inMilliseconds;
        final keys = [
          SecretSkippedKey('c', 0, key, storedAtMs: now),
          SecretSkippedKey('c', 1, key),
        ];
        expect(identical(pruneExpiredSkippedKeys(keys, now), keys), isTrue);
        final withOld = [
          ...keys,
          SecretSkippedKey('c', 2, key, storedAtMs: old),
        ];
        final pruned = pruneExpiredSkippedKeys(withOld, now);
        expect([for (final k in pruned) k.n], [0, 1]);
      },
    );

    test('남긴 시각은 저장 형식에도 적히고(4칸), 시각이 없는 3칸 항목도 읽는다', () {
      final key = List<int>.filled(32, 7);
      final encoded =
          jsonDecode(
                jsonEncode(
                  encodeSkippedKeys([
                    SecretSkippedKey('c', 0, key, storedAtMs: 123),
                    SecretSkippedKey('c', 1, key),
                  ]),
                ),
              )
              as Map<String, dynamic>;
      expect((encoded['e'] as List)[0], hasLength(4));
      expect((encoded['e'] as List)[1], hasLength(3));
      final decoded = decodeSkippedKeys(encoded)!;
      expect(decoded[0].storedAtMs, 123);
      expect(decoded[1].storedAtMs, isNull);
      // 시각 칸이 숫자가 아니면 그 항목만 뺀다.
      final broken = decodeSkippedKeys({
        'c': ['c'],
        'e': [
          [0, 0, base64Encode(key), 'x'],
          [0, 1, base64Encode(key), 5],
        ],
      })!;
      expect([for (final k in broken) k.n], [1]);
    });

    test(
      '봉투의 nonce·암호문도 표준 base64만 받는다 — 같은 바이트를 URL 안전 글자로 다시 적은 봉투는 거른다',
      () async {
        final p = await _handshake();
        final envelope = await _send(p.alice, '글');
        String urlSafe(String v) =>
            base64Url.encode(base64Decode(v)).replaceAll('=', '');
        for (final field in ['nonce', 'ciphertext']) {
          final variant = urlSafe(envelope[field] as String);
          if (variant == envelope[field]) continue;
          expect(
            SecretEnvelopeV3.tryParse({...envelope, field: variant}),
            isNull,
            reason: field,
          );
        }
        expect(await _recv(p.bob, envelope), '글');
      },
    );
  });
}

/// 무작위 시험에서 배달하는 것 — 진짜(또는 서버가 다시 보낸 같은 것), 꾸민 것, 보낸 기기에게 되돌아온 것.
enum _Kind { copy, forged, reflected }

class _Packet {
  _Packet({
    required this.id,
    required this.to,
    required this.wire,
    required this.deliverAt,
    required this.kind,
    this.roomId = _room,
  });
  final int id;
  final _Device to;
  final String wire;
  final int deliverAt;
  final _Kind kind;
  final String roomId;
}

class _Stats {
  int decrypted = 0;
  int duplicatesRejected = 0;
  int forgedRejected = 0;
  int viaSkipped = 0;
  int lateAcrossChains = 0;
  int restores = 0;
  final ratchetKeys = <String>{};
}

/// 메시지 하나를 한 군데 꾸민 것과, 그것을 풀 방.
(Map<String, dynamic>, String) _forge(
  Map<String, dynamic> envelope,
  Random rng,
  List<String> strangers,
) {
  final forged = {...envelope};
  switch (rng.nextInt(7)) {
    case 0:
      final bytes = base64Decode(envelope['ciphertext'] as String);
      bytes[rng.nextInt(bytes.length)] ^= 1 << rng.nextInt(8);
      forged['ciphertext'] = base64Encode(bytes);
    case 1:
      final bytes = base64Decode(envelope['nonce'] as String);
      bytes[rng.nextInt(bytes.length)] ^= 1 << rng.nextInt(8);
      forged['nonce'] = base64Encode(bytes);
    case 2:
      forged['n'] = (envelope['n'] as int) + 1 + rng.nextInt(3);
    case 3:
      final n = envelope['n'] as int;
      forged['n'] = n > 0 ? n - 1 : n + 1;
    case 4:
      forged['pn'] = (envelope['pn'] as int) + 1 + rng.nextInt(3);
    case 5:
      forged['dh'] = strangers[rng.nextInt(strangers.length)];
    default:
      return (forged, '$_room-elsewhere');
  }
  return (forged, _room);
}

/// 무작위로 엇갈린 대화 — 두 기기가 아무 때나(가끔은 한꺼번에 여러 개) 보내고, 메시지는 정해진 범위 안에서 늦게·
/// 뒤섞여 온다. 가끔 같은 것이 두 번 오고(진짜보다 먼저일 수도 있다), 꾸민 것·보낸 기기에게 되돌아온 것이 끼어들고,
/// 기기를 껐다 켠다(저장·복원). 순서는 [seed]로 정해진다(키는 매번 새로 만들지만 순서에는 영향이 없다).
Future<_Stats> _simulate(int seed, {required int messages}) async {
  final rng = Random(seed);
  final p = await _handshake();
  final peer = {p.alice: p.bob, p.bob: p.alice};
  final sendChance = {
    p.alice: 0.1 + rng.nextDouble() * 0.5,
    p.bob: 0.1 + rng.nextDouble() * 0.5,
  };
  // 첫 배달이 늦을 수 있는 최대 틱. 한 틱에 한 기기가 많아야 12개를 보내니, 한 체인에서 한 번에 건너뛸 번호나
  // 남겨 둘 키는 12 × (maxDelay + 1)개를 넘지 않는다(secretRatchetMaxSkip·상한보다 훨씬 적다). 다시 보낸 것은
  // 3 × maxDelay까지 늦지만 이미 받은 번호라 키를 남기지 않는다.
  final maxDelay = 8 + rng.nextInt(20);
  final strangers = [
    for (var i = 0; i < 3; i++)
      await _publicKeyBase64(await X25519().newKeyPair()),
  ];
  final texts = <int, String>{};
  final opened = <int>{};
  final openedTexts = <String>{};
  final inFlight = <_Packet>[];
  final stats = _Stats();
  var sent = 0;
  var tick = 0;
  while (sent < messages || inFlight.isNotEmpty) {
    tick++;
    int later(int bound) => tick + rng.nextInt(bound + 1);
    for (final from in [p.alice, p.bob]..shuffle(rng)) {
      if (sent >= messages || rng.nextDouble() >= sendChance[from]!) continue;
      final burst = rng.nextDouble() < 0.1 ? 1 + rng.nextInt(12) : 1;
      for (var k = 0; k < burst && sent < messages; k++) {
        final id = sent++;
        final text = '[$seed:$id] ${from.name} 메시지 ${'ㅋ' * (id % 4)}';
        texts[id] = text;
        final envelope = await _send(from, text);
        stats.ratchetKeys.add(envelope['dh'] as String);
        final wire = jsonEncode(envelope);
        final to = peer[from]!;
        inFlight.add(
          _Packet(
            id: id,
            to: to,
            wire: wire,
            deliverAt: later(maxDelay),
            kind: _Kind.copy,
          ),
        );
        if (rng.nextDouble() < 0.12) {
          // 서버가 한 번 더 보냄 — 진짜보다 먼저 올 수도, 한참 뒤에 올 수도 있다.
          inFlight.add(
            _Packet(
              id: id,
              to: to,
              wire: wire,
              deliverAt: later(3 * maxDelay),
              kind: _Kind.copy,
            ),
          );
        }
        if (rng.nextDouble() < 0.08) {
          final (forged, roomId) = _forge(envelope, rng, strangers);
          inFlight.add(
            _Packet(
              id: id,
              to: to,
              wire: jsonEncode(forged),
              deliverAt: later(maxDelay),
              kind: _Kind.forged,
              roomId: roomId,
            ),
          );
        }
        if (rng.nextDouble() < 0.03) {
          // 보낸 기기에게 되돌아옴 — 그대로거나, 보낸 쪽 표시를 상대 것으로 바꿔서.
          final reflected = rng.nextBool()
              ? envelope
              : {...envelope, 's': to.state.role};
          inFlight.add(
            _Packet(
              id: id,
              to: from,
              wire: jsonEncode(reflected),
              deliverAt: later(maxDelay),
              kind: _Kind.reflected,
            ),
          );
        }
      }
    }
    final due = [
      for (final m in inFlight)
        if (m.deliverAt <= tick) m,
    ]..shuffle(rng);
    for (final m in due) {
      inFlight.remove(m);
      final envelope = jsonDecode(m.wire) as Map<String, dynamic>;
      final receiver = m.to;
      final skippedBefore = receiver.state.skipped.length;
      final chainBefore = receiver.state.receivingPublicKey;
      final plain = await _recv(receiver, envelope, roomId: m.roomId);
      switch (m.kind) {
        case _Kind.forged || _Kind.reflected:
          expect(
            plain,
            isNull,
            reason: 'seed $seed: 꾸민 것·되돌아온 것(${m.id})이 풀렸다',
          );
          stats.forgedRejected++;
        case _Kind.copy when opened.contains(m.id):
          expect(plain, isNull, reason: 'seed $seed: ${m.id}가 두 번 풀렸다');
          stats.duplicatesRejected++;
        case _Kind.copy:
          expect(
            plain,
            texts[m.id],
            reason: 'seed $seed: ${m.id}가 풀리지 않았거나 다른 글로 풀렸다',
          );
          expect(openedTexts.add(plain!), isTrue);
          opened.add(m.id);
          stats.decrypted++;
          if (receiver.state.skipped.length < skippedBefore) {
            stats.viaSkipped++;
            if (envelope['dh'] != chainBefore) stats.lateAcrossChains++;
          }
      }
    }
    for (final device in [p.alice, p.bob]) {
      if (rng.nextDouble() < 0.03) {
        _restore(device);
        stats.restores++;
      }
    }
  }
  expect(opened.length, messages);
  // 모두 받았으니 남겨 둔 키도 모두 썼다.
  expect(p.alice.state.skipped, isEmpty);
  expect(p.bob.state.skipped, isEmpty);
  return stats;
}
