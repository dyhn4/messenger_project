import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import 'secret_chat_crypto.dart' as crypto;

/// 새 규약(v3)의 더블 래칫 — 방 하나에서 이 기기 쪽 상태와, 메시지 하나를 암호화·복호화하는 한 걸음. 상태는 늘 새
/// 값으로 돌려주고(들고 있는 값을 고치지 않는다) 저장은 부른 쪽(SecretSessionManager → SecretKeyStore)이 한다 —
/// 복호화에 실패하면 돌려준 것이 없으니 저장된 상태가 그대로 남는다(가짜·깨진 메시지가 체인을 밀어내지 못한다).
///
/// 시그널의 더블 래칫과 같다(https://signal.org/docs/specifications/doubleratchet/):
///  - 보내는 쪽마다 체인이 따로 있다 — 두 사람이 거의 동시에 보내도 번호·키가 겹치지 않는다.
///  - 메시지 머리에 보낸 쪽의 래칫 공개키가 실린다. 받는 쪽은 처음 보는 키면 그 키와 자기 래칫 키의 공유비밀로 루트키를
///    한 걸음 나아가 받는 체인을 만들고, 자기도 새 래칫 키를 만들어 보내는 체인을 바꾼다. 재키잉 신호가 따로 없어서
///    메시지가 어떤 순서로 와도 양쪽이 같은 루트키에 닿는다. 한 번 오간 뒤에는 예전 키가 새어도 새 메시지를 풀 수 없다.
///  - 건너뛴 번호(늦게 올 메시지)의 키는 [secretRatchetMaxStoredSkipped]개까지, [secretSkippedKeyLifetime] 동안 남겨
///    두었다가 그 메시지가 오면 쓰고 지운다(오래 남길수록 기기가 털렸을 때 그 메시지를 풀 수 있게 된다).
///
/// 처음은 이렇게 맞춘다 — 받는 쪽(수락한 기기, 'r')은 자기 임시키를 첫 래칫 키로 쓰고, 루트키에서 바로 만든 "0번
/// 체인"으로 보낸다. 초대한 쪽('i')은 수락을 확인하면 새 래칫 키로 한 걸음 나아가 보내는 체인을 만들고, 받는 쪽의
/// 0번 체인을 받는 체인으로 둔다. 그래서 어느 쪽이 먼저 보내도 된다.

/// 한 메시지를 받으며 건너뛸 수 있는 번호 수 — 상대가 새 래칫 키로 넘어갔으면 지금 받는 체인의 나머지(pn까지)와 새
/// 체인 앞쪽(n까지)을 합한 수다. 넘으면 그 메시지는 풀지 않는다(서버가 큰 번호를 끼워 넣어 계산을 오래 시키지 못하게).
const secretRatchetMaxSkip = 2000;

/// 방 하나에 남겨 두는 건너뛴 메시지 키의 최대 수 — 넘으면 오래된 것부터 버린다(그 메시지는 더는 풀 수 없다).
const secretRatchetMaxStoredSkipped = 2000;

/// 건너뛴 메시지 키를 남겨 두는 기간 — 지나면 버린다(서버가 일부 메시지를 일부러 늦게 주고 그사이 기기를 털면 그
/// 메시지를 풀 수 있게 되므로 무한정 들고 있지 않는다). 히스토리를 위로 올려 늦게 푸는 정도는 넉넉히 기다린다.
const secretSkippedKeyLifetime = Duration(days: 30);

/// 보낸 쪽 표시 — 초대한 기기와 수락한 기기.
const secretRoleInitiator = 'i';
const secretRoleResponder = 'r';

/// 남겨 둔 메시지 키 하나 — [chain]은 그 체인을 가리키는 값(v3는 보낸 쪽 래칫 공개키, 예전 규약은 `e{epoch}`),
/// [n]은 그 체인에서의 번호, [storedAtMs]는 남겨 둔 시각(모르면 null — 개수 상한으로만 버린다).
class SecretSkippedKey {
  const SecretSkippedKey(this.chain, this.n, this.key, {this.storedAtMs});
  final String chain;
  final int n;
  final List<int> key;
  final int? storedAtMs;
}

/// 남겨 둔 메시지 키들(오래된 것부터)을 저장 형식으로 — 같은 체인 값은 한 번만 적는다.
Object encodeSkippedKeys(List<SecretSkippedKey> keys) {
  final chains = <String>[];
  final index = <String, int>{};
  final entries = <List<Object>>[];
  for (final k in keys) {
    final i = index.putIfAbsent(k.chain, () {
      chains.add(k.chain);
      return chains.length - 1;
    });
    entries.add([i, k.n, base64Encode(k.key), ?k.storedAtMs]);
  }
  return {'c': chains, 'e': entries};
}

/// [encodeSkippedKeys]의 반대 — 깨진 항목은 빼고 읽는다(남은 키는 그대로 쓸 수 있다). 모양 자체가 틀리면 null.
List<SecretSkippedKey>? decodeSkippedKeys(Object? raw) {
  if (raw == null) return const [];
  if (raw is! Map) return null;
  final chains = raw['c'];
  final entries = raw['e'];
  if (chains is! List || entries is! List) return null;
  final out = <SecretSkippedKey>[];
  for (final e in entries) {
    if (e is! List || (e.length != 3 && e.length != 4)) continue;
    final i = e[0];
    final n = e[1];
    final key = e[2];
    final at = e.length == 4 ? e[3] : null;
    if (i is! int || i < 0 || i >= chains.length) continue;
    final chain = chains[i];
    if (chain is! String || n is! int || key is! String) continue;
    if (at != null && at is! int) continue;
    try {
      final bytes = base64Decode(key);
      if (bytes.length != 32) continue;
      out.add(SecretSkippedKey(chain, n, bytes, storedAtMs: at as int?));
    } on FormatException {
      continue;
    }
  }
  return out;
}

/// [keys] 뒤에 [added]를 붙이고(이미 있는 체인·번호는 다시 넣지 않는다 — 저장하다 끊겨 같은 키를 다시 만든 경우),
/// [secretRatchetMaxStoredSkipped]를 넘으면 오래된 것부터 버린다.
List<SecretSkippedKey> appendSkippedKeys(
  List<SecretSkippedKey> keys,
  List<SecretSkippedKey> added,
) {
  if (added.isEmpty) return keys;
  final present = {for (final k in keys) '${k.chain}|${k.n}'};
  final all = [
    ...keys,
    for (final k in added)
      if (present.add('${k.chain}|${k.n}')) k,
  ];
  if (all.length <= secretRatchetMaxStoredSkipped) return all;
  return all.sublist(all.length - secretRatchetMaxStoredSkipped);
}

/// [secretSkippedKeyLifetime]이 지난 키를 뺀 목록 — 지난 것이 없으면 [keys] 그대로(같은 객체)를 돌려준다.
List<SecretSkippedKey> pruneExpiredSkippedKeys(
  List<SecretSkippedKey> keys,
  int nowMs,
) {
  final oldest = nowMs - secretSkippedKeyLifetime.inMilliseconds;
  bool expired(SecretSkippedKey k) {
    final at = k.storedAtMs;
    return at != null && at < oldest;
  }

  if (!keys.any(expired)) return keys;
  return [
    for (final k in keys)
      if (!expired(k)) k,
  ];
}

/// [keys]에서 ([chain], [n])의 자리(없으면 -1).
int indexOfSkippedKey(List<SecretSkippedKey> keys, String chain, int n) {
  for (var i = 0; i < keys.length; i++) {
    if (keys[i].n == n && keys[i].chain == chain) return i;
  }
  return -1;
}

/// 받은 v3 봉투 — 머리 값을 확인해 둔 것. [tryParse]가 모양이 틀린 봉투(서버가 꾸민 값 등)를 걸러 낸다.
class SecretEnvelopeV3 {
  const SecretEnvelopeV3._({
    required this.sender,
    required this.ratchetPublicKey,
    required this.ratchetKeyBytes,
    required this.previousCount,
    required this.n,
    required this.nonce,
    required this.cipherText,
  });

  /// 보낸 쪽([secretRoleInitiator]·[secretRoleResponder]).
  final String sender;

  /// 보낸 쪽 래칫 공개키(base64 — 늘 표준 형식으로 왔는지 확인했다).
  final String ratchetPublicKey;
  final List<int> ratchetKeyBytes;

  /// 보낸 쪽이 바로 전 체인에서 보낸 수.
  final int previousCount;
  final int n;
  final List<int> nonce;
  final List<int> cipherText;

  /// 번호의 상한(2^31) — JSON 정수가 지나치게 커서 계산이 넘치지 않게(이만큼 보내는 일은 없다). 비트 이동(1 << 31)으로
  /// 쓰면 웹(자바스크립트)에서는 32비트로 잘려 음수가 되어 모든 봉투를 버린다 — 그래서 숫자로 적는다.
  static const _maxIndex = 2147483648;

  /// v3 봉투가 아니거나 모양이 틀리면 null.
  static SecretEnvelopeV3? tryParse(Map<String, dynamic> json) {
    if (json['v'] != crypto.secretProtocolV3) return null;
    final sender = json['s'];
    if (sender != secretRoleInitiator && sender != secretRoleResponder) {
      return null;
    }
    final dh = json['dh'];
    final pn = json['pn'];
    final n = json['n'];
    final nonce = json['nonce'];
    final cipherText = json['ciphertext'];
    if (dh is! String ||
        pn is! int ||
        n is! int ||
        nonce is! String ||
        cipherText is! String) {
      return null;
    }
    if (pn < 0 || pn >= _maxIndex || n < 0 || n >= _maxIndex) return null;
    // 같은 바이트를 다른 글자로 적은 값(패딩 빠짐·URL 안전 글자 등)은 받지 않는다 — 래칫 키는 체인을 찾지 못하고 새
    // 키로 보게 되고, nonce·암호문은 같은 봉투를 다른 글자로 다시 보내 "다른 메시지"처럼 보이게 할 수 있다.
    if (!crypto.isCanonicalBase64(dh) ||
        !crypto.isCanonicalBase64(nonce) ||
        !crypto.isCanonicalBase64(cipherText)) {
      return null;
    }
    try {
      final dhBytes = base64Decode(dh);
      if (dhBytes.length != 32) return null;
      final nonceBytes = base64Decode(nonce);
      final cipherBytes = base64Decode(cipherText);
      if (nonceBytes.length != 12 || cipherBytes.length < 16) return null;
      return SecretEnvelopeV3._(
        sender: sender as String,
        ratchetPublicKey: dh,
        ratchetKeyBytes: dhBytes,
        previousCount: pn,
        n: n,
        nonce: nonceBytes,
        cipherText: cipherBytes,
      );
    } on FormatException {
      return null;
    }
  }
}

/// 방 하나의 더블 래칫 상태(이 기기 쪽) — `secret/<방>/ratchet`에 JSON으로 둔다. 남겨 둔 메시지 키([skipped])는
/// 저장소가 `secret/<방>/skipped`에 따로 두어(바뀔 때만 다시 쓴다) 읽을 때 붙인다(SecretKeyStore).
class SecretRatchetState {
  const SecretRatchetState({
    required this.role,
    required this.rootKey,
    required this.sendingKeySeed,
    required this.sendingPublicKey,
    required this.sendingChainKey,
    this.sendCount = 0,
    this.previousSendCount = 0,
    this.receivingPublicKey,
    this.receivingChainKey,
    this.receiveCount = 0,
    this.skipped = const [],
  });

  /// 이 기기가 초대한 쪽인지 수락한 쪽인지([secretRoleInitiator]·[secretRoleResponder]) — 봉투의 보낸 쪽 표시.
  final String role;
  final List<int> rootKey;

  /// 지금 래칫 키(X25519)의 개인키 시드와 공개키(base64) — 보내는 메시지 머리에 공개키가 실린다.
  final List<int> sendingKeySeed;
  final String sendingPublicKey;
  final List<int> sendingChainKey;

  /// 지금 보내는 체인에서 보낸 수(다음 번호)와, 바로 전 보내는 체인에서 보낸 수.
  final int sendCount;
  final int previousSendCount;

  /// 상대의 지금 래칫 공개키와 그 받는 체인 — 수락한 쪽은 첫 메시지를 받기 전에는 없다.
  final String? receivingPublicKey;
  final List<int>? receivingChainKey;

  /// 지금 받는 체인에서 다음에 올 번호.
  final int receiveCount;

  /// 건너뛴 번호의 메시지 키(오래된 것부터).
  final List<SecretSkippedKey> skipped;

  String get peerRole =>
      role == secretRoleInitiator ? secretRoleResponder : secretRoleInitiator;

  SecretRatchetState _copy({
    List<int>? rootKey,
    List<int>? sendingKeySeed,
    String? sendingPublicKey,
    List<int>? sendingChainKey,
    int? sendCount,
    int? previousSendCount,
    String? receivingPublicKey,
    List<int>? receivingChainKey,
    int? receiveCount,
    List<SecretSkippedKey>? skipped,
  }) => SecretRatchetState(
    role: role,
    rootKey: rootKey ?? this.rootKey,
    sendingKeySeed: sendingKeySeed ?? this.sendingKeySeed,
    sendingPublicKey: sendingPublicKey ?? this.sendingPublicKey,
    sendingChainKey: sendingChainKey ?? this.sendingChainKey,
    sendCount: sendCount ?? this.sendCount,
    previousSendCount: previousSendCount ?? this.previousSendCount,
    receivingPublicKey: receivingPublicKey ?? this.receivingPublicKey,
    receivingChainKey: receivingChainKey ?? this.receivingChainKey,
    receiveCount: receiveCount ?? this.receiveCount,
    skipped: skipped ?? this.skipped,
  );

  /// 저장 형식 — [includeSkipped]가 false면 남겨 둔 키를 빼고 적는다(저장소가 따로 적을 때).
  String encode({bool includeSkipped = true}) => jsonEncode({
    'v': crypto.secretProtocolV3,
    'role': role,
    'rk': base64Encode(rootKey),
    'ds': base64Encode(sendingKeySeed),
    'dp': sendingPublicKey,
    'cs': base64Encode(sendingChainKey),
    'ns': sendCount,
    'pn': previousSendCount,
    'dr': ?receivingPublicKey,
    if (receivingChainKey != null) 'cr': base64Encode(receivingChainKey!),
    'nr': receiveCount,
    if (includeSkipped && skipped.isNotEmpty) 'sk': encodeSkippedKeys(skipped),
  });

  /// 남겨 둔 키만 [keys]로 바꾼 값(저장소가 따로 읽은 키를 붙일 때).
  SecretRatchetState withSkipped(List<SecretSkippedKey> keys) =>
      _copy(skipped: keys);

  /// 깨진 값이면 null(그 대화는 더 이어 갈 수 없다 — 끝내고 새로 시작해야 한다).
  static SecretRatchetState? decode(String raw) {
    try {
      final json = jsonDecode(raw);
      if (json is! Map || json['v'] != crypto.secretProtocolV3) return null;
      final role = json['role'];
      if (role != secretRoleInitiator && role != secretRoleResponder) {
        return null;
      }
      List<int>? key(Object? v) {
        if (v is! String) return null;
        final bytes = base64Decode(v);
        return bytes.length == 32 ? bytes : null;
      }

      final rootKey = key(json['rk']);
      final seed = key(json['ds']);
      final sendingPublic = json['dp'];
      final sendingChain = key(json['cs']);
      final ns = json['ns'];
      final pn = json['pn'];
      final nr = json['nr'];
      final receivingPublic = json['dr'];
      final receivingChain = json['cr'] == null ? null : key(json['cr']);
      final skipped = decodeSkippedKeys(json['sk']);
      if (rootKey == null ||
          seed == null ||
          sendingPublic is! String ||
          sendingChain == null ||
          ns is! int ||
          pn is! int ||
          nr is! int ||
          (receivingPublic != null && receivingPublic is! String) ||
          (json['cr'] != null && receivingChain == null) ||
          // 받는 체인과 상대 래칫 키는 늘 함께 있다.
          ((receivingPublic == null) != (receivingChain == null)) ||
          skipped == null) {
        return null;
      }
      return SecretRatchetState(
        role: role as String,
        rootKey: rootKey,
        sendingKeySeed: seed,
        sendingPublicKey: sendingPublic,
        sendingChainKey: sendingChain,
        sendCount: ns,
        previousSendCount: pn,
        receivingPublicKey: receivingPublic as String?,
        receivingChainKey: receivingChain,
        receiveCount: nr,
        skipped: skipped,
      );
    } on FormatException {
      return null;
    }
  }

  /// 초대한 기기 — 수락을 확인한 뒤. 새 래칫 키로 한 걸음 나아가 보내는 체인을 만들고, 수락한 기기의 임시키
  /// ([responderEphemeralPublicKey] — 받은 그대로의 base64)와 그 0번 체인을 받는 쪽으로 둔다. 공유비밀이 0뿐이면 null.
  static Future<SecretRatchetState?> forInitiator({
    required List<int> rootKey,
    required String responderEphemeralPublicKey,
  }) async {
    final List<int> theirKey;
    try {
      theirKey = base64Decode(responderEphemeralPublicKey);
    } on FormatException {
      return null;
    }
    if (theirKey.length != 32 ||
        base64Encode(theirKey) != responderEphemeralPublicKey) {
      return null;
    }
    final mine = await X25519().newKeyPair();
    final shared = await crypto.x25519SharedSecret(mine, theirKey);
    if (shared == null) return null;
    final (nextRoot, sendingChain) = await crypto.kdfRootV3(rootKey, shared);
    return SecretRatchetState(
      role: secretRoleInitiator,
      rootKey: nextRoot,
      sendingKeySeed: await mine.extractPrivateKeyBytes(),
      sendingPublicKey: await _publicKeyOf(mine),
      sendingChainKey: sendingChain,
      receivingPublicKey: responderEphemeralPublicKey,
      receivingChainKey: await crypto.deriveResponderInitialChainV3(rootKey),
    );
  }

  /// 수락한 기기 — 자기 임시키([myEphemeralKeyPair])가 첫 래칫 키고, 루트키에서 바로 만든 0번 체인으로 보낸다.
  static Future<SecretRatchetState> forResponder({
    required List<int> rootKey,
    required SimpleKeyPair myEphemeralKeyPair,
  }) async => SecretRatchetState(
    role: secretRoleResponder,
    rootKey: rootKey,
    sendingKeySeed: await myEphemeralKeyPair.extractPrivateKeyBytes(),
    sendingPublicKey: await _publicKeyOf(myEphemeralKeyPair),
    sendingChainKey: await crypto.deriveResponderInitialChainV3(rootKey),
  );

  /// [plainText]를 암호화한 봉투와 그 뒤의 상태.
  Future<({SecretRatchetState state, Map<String, dynamic> envelope})> encrypt({
    required String roomId,
    required String plainText,
  }) async {
    final step = await crypto.kdfChainV3(sendingChainKey);
    final envelope = await crypto.encryptEnvelopeV3(
      msgKey: step.msgKey,
      plainText: plainText,
      roomId: roomId,
      sender: role,
      ratchetPublicKey: sendingPublicKey,
      previousCount: previousSendCount,
      n: sendCount,
    );
    return (
      state: _copy(sendingChainKey: step.nextChainKey, sendCount: sendCount + 1),
      envelope: envelope,
    );
  }

  /// 상대가 보낸 [envelope]를 푼 평문과 그 뒤의 상태. 풀 수 없으면(이 기기가 보낸 것·이미 받은 번호·너무 많이 건너뜀·
  /// 키가 다름·변조) null — 그러면 상태를 저장하지 않는다. [skippedChanged]는 남겨 둔 키가 바뀌었는지(늘었거나 쓰였거나
  /// 수명이 다해 빠짐 — 저장소가 그때만 다시 쓴다). [nowMs]는 남겨 둔 키의 수명을 잴 지금 시각(테스트가 준다).
  Future<({SecretRatchetState state, String plainText, bool skippedChanged})?>
  decrypt({
    required String roomId,
    required SecretEnvelopeV3 envelope,
    int? nowMs,
  }) async {
    // 이 기기가 보낸 메시지는 보내는 체인이 이미 지나가 다시 풀 수 없다(부른 쪽이 보낸 평문을 따로 들고 있다).
    if (envelope.sender == role) return null;
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final live = pruneExpiredSkippedKeys(skipped, now);
    final known = indexOfSkippedKey(
      live,
      envelope.ratchetPublicKey,
      envelope.n,
    );
    if (known >= 0) {
      final plain = await _open(live[known].key, roomId, envelope);
      if (plain == null) return null;
      return (
        state: _copy(skipped: [...live]..removeAt(known)),
        plainText: plain,
        skippedChanged: true,
      );
    }

    final added = <SecretSkippedKey>[];
    // 이 메시지 하나로 건너뛸 수 있는 남은 수 — 이전 체인의 나머지와 새 체인 앞쪽을 합해 [secretRatchetMaxSkip]까지.
    var budget = secretRatchetMaxSkip;
    var root = rootKey;
    var seed = sendingKeySeed;
    var sendingPublic = sendingPublicKey;
    var sendingChain = sendingChainKey;
    var ns = sendCount;
    var pn = previousSendCount;
    var receivingPublic = receivingPublicKey;
    var receivingChain = receivingChainKey;
    var nr = receiveCount;

    if (envelope.ratchetPublicKey != receivingPublic) {
      // 상대가 새 래칫 키로 넘어갔다 — 지금 받는 체인에서 상대가 그 전에 보낸 나머지([previousCount]까지)의 키를
      // 남겨 두고, 새 키로 루트키를 두 걸음(받는 체인·보내는 체인) 나아간다.
      if (receivingChain != null && receivingPublic != null) {
        final skippedTo = await _skip(
          chain: receivingPublic,
          chainKey: receivingChain,
          from: nr,
          until: envelope.previousCount,
          into: added,
          budget: budget,
          atMs: now,
        );
        if (skippedTo == null) return null;
        budget -= added.length;
      }
      final current = await X25519().newKeyPairFromSeed(seed);
      final receiveShared = await crypto.x25519SharedSecret(
        current,
        envelope.ratchetKeyBytes,
      );
      if (receiveShared == null) return null;
      final (rootAfterReceive, newReceivingChain) = await crypto.kdfRootV3(
        root,
        receiveShared,
      );
      final next = await X25519().newKeyPair();
      final sendShared = await crypto.x25519SharedSecret(
        next,
        envelope.ratchetKeyBytes,
      );
      if (sendShared == null) return null;
      final (rootAfterSend, newSendingChain) = await crypto.kdfRootV3(
        rootAfterReceive,
        sendShared,
      );
      pn = ns;
      ns = 0;
      nr = 0;
      receivingPublic = envelope.ratchetPublicKey;
      receivingChain = newReceivingChain;
      root = rootAfterSend;
      sendingChain = newSendingChain;
      seed = await next.extractPrivateKeyBytes();
      sendingPublic = await _publicKeyOf(next);
    } else if (envelope.n < nr) {
      // 이미 받은 번호(남겨 둔 키도 없다) — 같은 메시지가 또 왔거나 서버가 다시 보낸 것.
      return null;
    }

    // 여기서는 늘 받는 체인이 [envelope]의 래칫 키다(위에서 새로 만들었거나 원래 같았다).
    final skippedTo = await _skip(
      chain: envelope.ratchetPublicKey,
      chainKey: receivingChain!,
      from: nr,
      until: envelope.n,
      into: added,
      budget: budget,
      atMs: now,
    );
    if (skippedTo == null) return null;
    final step = await crypto.kdfChainV3(skippedTo);
    final plain = await _open(step.msgKey, roomId, envelope);
    if (plain == null) return null;
    final skippedChanged = added.isNotEmpty || !identical(live, skipped);
    return (
      state: SecretRatchetState(
        role: role,
        rootKey: root,
        sendingKeySeed: seed,
        sendingPublicKey: sendingPublic,
        sendingChainKey: sendingChain,
        sendCount: ns,
        previousSendCount: pn,
        receivingPublicKey: receivingPublic,
        receivingChainKey: step.nextChainKey,
        receiveCount: envelope.n + 1,
        skipped: appendSkippedKeys(live, added),
      ),
      plainText: plain,
      skippedChanged: skippedChanged,
    );
  }

  static Future<String?> _open(
    List<int> msgKey,
    String roomId,
    SecretEnvelopeV3 envelope,
  ) => crypto.decryptEnvelopeV3(
    msgKey: msgKey,
    roomId: roomId,
    sender: envelope.sender,
    ratchetPublicKey: envelope.ratchetPublicKey,
    previousCount: envelope.previousCount,
    n: envelope.n,
    nonce: envelope.nonce,
    cipherTextWithMac: envelope.cipherText,
  );

  /// [chain]의 받는 체인을 [from]번에서 [until]번 앞까지 감으며 그 키를 [into]에 남기고(남긴 시각 [atMs]), [until]번의
  /// 체인키를 돌려준다. 건너뛸 수가 [budget]을 넘으면 null. [until]이 [from]보다 작으면 그대로 돌려준다.
  static Future<List<int>?> _skip({
    required String chain,
    required List<int> chainKey,
    required int from,
    required int until,
    required List<SecretSkippedKey> into,
    required int budget,
    required int atMs,
  }) async {
    if (until <= from) return chainKey;
    if (until - from > budget) return null;
    var key = chainKey;
    for (var i = from; i < until; i++) {
      final step = await crypto.kdfChainV3(key);
      into.add(SecretSkippedKey(chain, i, step.msgKey, storedAtMs: atMs));
      key = step.nextChainKey;
    }
    return key;
  }
}

Future<String> _publicKeyOf(SimpleKeyPair keyPair) async =>
    base64Encode((await keyPair.extractPublicKey()).bytes);
