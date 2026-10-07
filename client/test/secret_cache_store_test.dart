import 'dart:convert';

import 'package:client/models/comment.dart';
import 'package:client/models/message.dart';
import 'package:client/services/secret_key_store.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

/// 비밀 대화 평문 캐시(S34) — 서버가 지운(자동 삭제 만료·삭제) 메시지의 평문이 그 실시간 알림을 놓쳐도
/// 이 기기에 남지 않는지, 타이머 없는 비밀 대화의 평문은 재시작 뒤에도 그대로 남는지(SecretKeyStore).

/// flutter_secure_storage를 흉내 내는 메모리 저장소. [racy]면 Windows 구현처럼 쓰기·지우기마다 "전체 읽기 →
/// 고치기 → 전체 쓰기"를 비동기로 나눠 해서, 작업이 겹치면 늦게 끝난 쪽이 앞 변경을 덮어쓴다.
class _MemoryStorage extends Fake implements FlutterSecureStorage {
  _MemoryStorage([Map<String, String>? initial, this.racy = false])
    : data = {...?initial};

  final Map<String, String> data;
  final bool racy;
  int readAllCalls = 0;

  Future<Map<String, String>> _load() async {
    if (racy) await Future<void>.delayed(Duration.zero);
    return Map.of(data);
  }

  Future<void> _save(Map<String, String> next) async {
    if (racy) await Future<void>.delayed(Duration.zero);
    data
      ..clear()
      ..addAll(next);
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    final map = await _load();
    if (value == null) {
      map.remove(key);
    } else {
      map[key] = value;
    }
    await _save(map);
  }

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => (await _load())[key];

  @override
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    final map = await _load();
    map.remove(key);
    await _save(map);
  }

  @override
  Future<Map<String, String>> readAll({
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) {
    readAllCalls++;
    return _load();
  }

  Map<String, dynamic>? entry(String roomId, String id) {
    final raw = data['secretcache/$roomId/$id'];
    return raw == null ? null : jsonDecode(raw) as Map<String, dynamic>;
  }
}

DateTime _at(int ms) => DateTime.fromMillisecondsSinceEpoch(ms);

SecretTextRef _ref(
  String id,
  int createdAtMs, {
  String roomId = 'r1',
  String? parentId,
  bool expiryKnown = false,
  DateTime? expiresAt,
}) => SecretTextRef(
  roomId: roomId,
  id: id,
  parentId: parentId,
  createdAt: _at(createdAtMs),
  expiryKnown: expiryKnown,
  expiresAt: expiresAt,
);

Message _msg(
  String id,
  int createdAtMs, {
  bool deleted = false,
  List<Comment> comments = const [],
}) => Message(
  id: id,
  roomId: 'r1',
  senderId: 'u2',
  senderName: '상대',
  type: MessageType.text,
  text: deleted ? null : '암호문',
  createdAt: _at(createdAtMs),
  deleted: deleted,
  comments: [...comments],
);

Comment _comment(String id, String messageId, int createdAtMs) => Comment(
  id: id,
  messageId: messageId,
  roomId: 'r1',
  senderId: 'u2',
  senderName: '상대',
  text: '암호문',
  createdAt: _at(createdAtMs),
);

const _grace = secretTextExpiryGrace;

void main() {
  late _MemoryStorage storage;
  late SecretKeyStore store;

  setUp(() {
    storage = _MemoryStorage();
    store = SecretKeyStore(storage: storage);
  });

  tearDown(() => store.dispose());

  test('타이머 없는 비밀 대화의 평문은 방·작성 시각과 함께 남고, 다시 켜도(새 저장소) 지워지지 않고 읽힌다', () async {
    await store.saveDecryptedText(_ref('m1', 1000), '안녕하세요');
    expect(storage.entry('r1', 'm1'), {'t': '안녕하세요', 'c': 1000});

    final restarted = SecretKeyStore(storage: storage);
    addTearDown(restarted.dispose);
    final farFuture = DateTime.now().add(const Duration(days: 3650));
    final removed = await restarted.purgeExpiredTexts(
      now: farFuture,
      serverNow: farFuture,
    );
    expect(removed, isEmpty);
    expect(await restarted.readDecryptedText(_ref('m1', 1000)), '안녕하세요');
  });

  test('저장소 전체 읽기는 처음 한 번뿐이고, 저장해 둔 적 없는 메시지는 저장소를 읽지 않는다', () async {
    await store.saveDecryptedText(_ref('m1', 1000), '하나');
    expect(await store.readDecryptedText(_ref('nope', 2000)), isNull);
    expect(await store.readDecryptedText(_ref('m1', 1000)), '하나');
    expect(storage.readAllCalls, 1);
  });

  test(
    '예전 형식(secretmsg/<id>)은 다시 읽을 때 새 형식으로 옮기고, 방을 모르는 동안은 지우지 않는다',
    () async {
      storage.data['secretmsg/m1'] = '옛 평문';
      storage.data['secretmsg/m2'] = '안 열어 본 평문';
      storage.data['secretmsg/m3'] = '지워진 메시지 평문';

      // 어느 방 것인지 모르니 만료·재조정 대상이 아니다.
      expect(await store.purgeExpiredTexts(now: _at(1 << 50)), isEmpty);
      await store.reconcileHistoryPage(
        roomId: 'r1',
        page: const [],
        before: null,
        limit: 50,
        sinceGeneration: store.textCacheGeneration,
      );
      expect(storage.data['secretmsg/m2'], '안 열어 본 평문');

      expect(await store.readDecryptedText(_ref('m1', 1000)), '옛 평문');
      expect(storage.data.containsKey('secretmsg/m1'), isFalse);
      expect(storage.entry('r1', 'm1'), {'t': '옛 평문', 'c': 1000});

      // 이 방 히스토리가 지워진 것으로 표시해 보내면(소프트 삭제) 예전 형식 값도 지운다.
      await store.reconcileHistoryPage(
        roomId: 'r1',
        page: [_msg('m3', 3000, deleted: true)],
        before: null,
        limit: 50,
        sinceGeneration: store.textCacheGeneration,
      );
      expect(storage.data.containsKey('secretmsg/m3'), isFalse);
      expect(storage.data['secretmsg/m2'], '안 열어 본 평문');
    },
  );

  test('서버가 정한 자동 삭제 시각이 지나면(유예 뒤) 알림 없이 지워지고, 댓글도 원본 시각을 따른다', () async {
    // 실제 시계로 도는 정리 타이머가 끼어들지 않게 내일 시각으로 두고, 정리는 그 뒤의 서버 시각을 넘겨 부른다.
    final expiresAt = DateTime.now().add(const Duration(days: 1));
    final removedEvents = <List<SecretCachedTextInfo>>[];
    store.onExpiredTextsPurged = removedEvents.add;

    await store.saveDecryptedText(
      _ref('m1', 1000, expiryKnown: true, expiresAt: expiresAt),
      '곧 사라질 메시지',
    );
    // 실시간 댓글처럼 원본을 모르고 저장해도 이미 적어 둔 원본 시각을 물려받는다.
    await store.saveDecryptedText(_ref('c1', 1500, parentId: 'm1'), '댓글');
    await store.saveDecryptedText(_ref('m2', 2000), '타이머 없는 메시지');
    expect(storage.entry('r1', 'c1')!['e'], expiresAt.millisecondsSinceEpoch);

    // 유예(서버의 message:expired가 먼저 오도록 기다리는 시간) 안이면 아직 남긴다.
    expect(
      await store.purgeExpiredTexts(
        serverNow: expiresAt.add(_grace - const Duration(seconds: 1)),
      ),
      isEmpty,
    );

    final removed = await store.purgeExpiredTexts(
      serverNow: expiresAt.add(_grace + const Duration(seconds: 1)),
    );
    expect(removed.map((r) => r.id).toSet(), {'m1', 'c1'});
    expect(removedEvents.single.map((r) => r.id).toSet(), {'m1', 'c1'});
    expect(storage.entry('r1', 'm1'), isNull);
    expect(storage.entry('r1', 'c1'), isNull);
    expect(await store.readDecryptedText(_ref('m2', 2000)), '타이머 없는 메시지');
  });

  test(
    'secret:message-read로 알게 된 시각은 이미 저장된 메시지와 그 댓글에 적히고, 다시 켜도 그 시각에 지워진다',
    () async {
      await store.saveDecryptedText(_ref('m1', 1000), '내 메시지');
      await store.saveDecryptedText(_ref('c1', 1500, parentId: 'm1'), '댓글');
      final expiresAt = DateTime.now().add(const Duration(days: 1));
      await store.noteMessageRead('m1', expiresAt);
      expect(storage.entry('r1', 'm1')!['e'], expiresAt.millisecondsSinceEpoch);
      expect(storage.entry('r1', 'm1')!['f'], isTrue);
      expect(storage.entry('r1', 'c1')!['e'], expiresAt.millisecondsSinceEpoch);

      final restarted = SecretKeyStore(storage: storage);
      addTearDown(restarted.dispose);
      final removed = await restarted.purgeExpiredTexts(
        serverNow: expiresAt.add(_grace * 2),
      );
      expect(removed.map((r) => r.id).toSet(), {'m1', 'c1'});
    },
  );

  test('히스토리가 알려 준(readAt 있는) 시각이 저장된 값과 다르면 읽을 때 맞추고, 댓글에도 맞춘다', () async {
    await store.saveDecryptedText(_ref('m1', 1000), '메시지');
    await store.saveDecryptedText(_ref('c1', 1500, parentId: 'm1'), '댓글');
    final expiresAt = DateTime.now().add(const Duration(days: 1));
    expect(
      await store.readDecryptedText(
        _ref('m1', 1000, expiryKnown: true, expiresAt: expiresAt),
      ),
      '메시지',
    );
    expect(storage.entry('r1', 'm1')!['e'], expiresAt.millisecondsSinceEpoch);
    expect(storage.entry('r1', 'c1')!['e'], expiresAt.millisecondsSinceEpoch);
  });

  test('이 기기가 읽음을 보낸 메시지는 방 타이머로 어림해 두고, 서버 값이 오면 그것으로 바뀐다', () async {
    final now = DateTime.now().add(const Duration(days: 1));
    final nowMs = now.millisecondsSinceEpoch;
    await store.saveDecryptedText(_ref('m1', 1000), '상대 메시지');
    await store.noteLocalRead('m1', const Duration(seconds: 30), now: now);
    expect(storage.entry('r1', 'm1')!['e'], nowMs + 30000);
    expect(storage.entry('r1', 'm1')!.containsKey('f'), isFalse);

    // 다시 읽음을 보내도(방을 다시 봄) 처음 어림한 값 그대로.
    await store.noteLocalRead(
      'm1',
      const Duration(seconds: 30),
      now: now.add(const Duration(seconds: 10)),
    );
    expect(storage.entry('r1', 'm1')!['e'], nowMs + 30000);

    await store.noteMessageRead('m1', _at(nowMs + 40000));
    expect(storage.entry('r1', 'm1')!['e'], nowMs + 40000);
    await store.noteLocalRead('m1', const Duration(seconds: 30), now: now);
    expect(storage.entry('r1', 'm1')!['e'], nowMs + 40000);
  });

  test('서버가 타이머 없이 읽혔다고 하면(expiresAt null) 어림 값을 지우고 계속 남긴다', () async {
    final now = DateTime.now().add(const Duration(days: 1));
    await store.saveDecryptedText(_ref('m1', 1000), '상대 메시지');
    await store.noteLocalRead('m1', const Duration(seconds: 30), now: now);
    await store.noteMessageRead('m1', null);
    expect(storage.entry('r1', 'm1')!.containsKey('e'), isFalse);
    await store.noteLocalRead('m1', const Duration(seconds: 30), now: now);
    expect(storage.entry('r1', 'm1')!.containsKey('e'), isFalse);
    expect(await store.purgeExpiredTexts(now: _at(1 << 50)), isEmpty);
  });

  test(
    '히스토리 재조정 — 범위 안에서 응답에 없는 항목과 지워진 표시가 온 항목만 지우고, 요청 뒤에 저장된 항목은 남긴다',
    () async {
      await store.saveDecryptedText(_ref('m1', 100), '서버에서 만료됨');
      await store.saveDecryptedText(_ref('m2', 200), '소프트 삭제됨');
      await store.saveDecryptedText(_ref('m3', 300), '그대로');
      await store.saveDecryptedText(_ref('x1', 150, roomId: 'r2'), '다른 방');
      final generation = store.textCacheGeneration;
      // 요청을 보낸 뒤 실시간으로 도착한 메시지 — 응답(요청 시점의 서버 상태)에는 없을 수 있다.
      await store.saveDecryptedText(_ref('m4', 400), '요청 뒤 도착');

      final removed = await store.reconcileHistoryPage(
        roomId: 'r1',
        page: [_msg('m2', 200, deleted: true), _msg('m3', 300)],
        before: null,
        limit: 50,
        sinceGeneration: generation,
      );
      expect(removed.map((r) => r.id).toSet(), {'m1', 'm2'});
      expect(storage.entry('r1', 'm1'), isNull);
      expect(storage.entry('r1', 'm2'), isNull);
      expect(storage.entry('r1', 'm3'), isNotNull);
      expect(storage.entry('r1', 'm4'), isNotNull);
      expect(storage.entry('r2', 'x1'), isNotNull);
    },
  );

  test('메시지 완전 삭제는 댓글 평문까지, 방이 없어지면(clearRoom) 그 방 평문과 키 상태를 지운다', () async {
    await store.saveChainState(
      'r1',
      const SecretChainState(epoch: 0, n: 3, chainKey: [1, 2, 3]),
    );
    await store.saveDecryptedText(_ref('m1', 100), '메시지');
    await store.saveDecryptedText(_ref('c1', 150, parentId: 'm1'), '댓글');
    await store.saveDecryptedText(_ref('m2', 200), '남는 메시지');
    await store.saveDecryptedText(_ref('y1', 100, roomId: 'r2'), '다른 방');

    await store.deleteMessageTexts('r1', 'm1');
    expect(storage.entry('r1', 'm1'), isNull);
    expect(storage.entry('r1', 'c1'), isNull);
    expect(storage.entry('r1', 'm2'), isNotNull);

    await store.deleteDecryptedText('r1', 'm2');
    expect(storage.entry('r1', 'm2'), isNull);

    await store.saveDecryptedText(_ref('m5', 500), '방과 함께 사라질 메시지');
    await store.noteRoomOwner('r1', 'me');
    expect(storage.data['secret/r1/owner'], 'me');
    await store.clearRoom('r1');
    expect(storage.entry('r1', 'm5'), isNull);
    expect(await store.readChainState('r1'), isNull);
    expect(storage.data.containsKey('secret/r1/owner'), isFalse);
    expect(store.localSecretRoomIds, {'r2'});
    expect(storage.entry('r2', 'y1'), isNotNull);
  });

  test(
    '앱을 켤 때 이전 실행에서 저장한 항목 중 시각이 지난 것만 지운다 — 서버 시각을 받기 전에는 서버가 정한 시각을 하루 늦춰 잰다',
    () async {
      final past = DateTime.now().subtract(const Duration(hours: 1));
      final future = DateTime.now().add(const Duration(days: 1));
      storage.data['secretcache/r1/old'] = jsonEncode({
        't': '한 시간 전 만료',
        'c': 100,
        'e': past.millisecondsSinceEpoch,
        'f': true,
      });
      // 꺼진 채 오프라인으로 켜서 서버 시각을 못 받아도, 이 기기 시계로 하루(secretDeviceClockTolerance)가 넘게 지난 것은 지운다.
      storage.data['secretcache/r1/ancient'] = jsonEncode({
        't': '이틀 전 만료',
        'c': 50,
        'e': DateTime.now()
            .subtract(secretDeviceClockTolerance + const Duration(days: 1))
            .millisecondsSinceEpoch,
        'f': true,
      });
      storage.data['secretcache/r1/later'] = jsonEncode({
        't': '내일 만료',
        'c': 200,
        'e': future.millisecondsSinceEpoch,
        'f': true,
      });
      // 이 기기가 읽음을 보내며 어림한 시각(서버 확정 전) — 이 기기 시계로 잰다.
      storage.data['secretcache/r1/guessed'] = jsonEncode({
        't': '어림 만료',
        'c': 300,
        'e': past.millisecondsSinceEpoch,
      });
      storage.data['secretcache/r1/broken'] = '형식이 깨진 값';
      storage.data['secret/r1/epoch'] = '0';

      // 서버 시각을 아직 모른다 — 이 기기 시계만으로는 서버가 정한 시각이 한 시간 전에 지났는지 믿지 않는다.
      expect((await store.purgeExpiredTexts()).map((r) => r.id).toSet(), {
        'guessed',
        'ancient',
      });
      expect(storage.data.containsKey('secretcache/r1/old'), isTrue);

      store.noteServerTime(DateTime.now());
      final removed = await store.purgeExpiredTexts();
      expect(removed.map((r) => r.id), ['old']);
      expect(storage.data.containsKey('secretcache/r1/old'), isFalse);
      expect(storage.data.containsKey('secretcache/r1/broken'), isFalse);
      expect(storage.data['secret/r1/epoch'], '0');
      expect(await store.readDecryptedText(_ref('later', 200)), '내일 만료');
    },
  );

  test(
    '이 기기 시계가 서버보다 빨라도 서버가 정한 시각은 서버의 지금이 지나야 지운다(어림한 시각은 이 기기 시계로)',
    () async {
      // 서버 시각 기준 1시간 타이머 — 상대가 방금 읽었다.
      final serverNow = DateTime.now().add(const Duration(days: 1));
      final expiresAt = serverNow.add(const Duration(hours: 1));
      await store.saveDecryptedText(
        _ref('m1', 1000, expiryKnown: true, expiresAt: expiresAt),
        '1시간 뒤 사라질 메시지',
      );
      await store.saveDecryptedText(_ref('m2', 2000), '이 기기가 읽은 메시지');
      await store.noteLocalRead(
        'm2',
        const Duration(hours: 1),
        now: serverNow.add(const Duration(hours: 2)),
      );
      // 이 기기 시계가 2시간 빠르다 — 이 기기 시계로는 m1의 시각이 이미 지났지만 서버로는 아직 1시간 남았다.
      final deviceNow = serverNow.add(const Duration(hours: 2));
      expect(
        await store.purgeExpiredTexts(now: deviceNow, serverNow: serverNow),
        isEmpty,
      );
      // 어림한 시각은 이 기기 시계로 쟀으니 이 기기 시계로 1시간이 지나면 지운다(서버 시각과 상관없이).
      final removed = await store.purgeExpiredTexts(
        now: deviceNow.add(const Duration(hours: 1)).add(_grace),
        serverNow: serverNow,
      );
      expect(removed.map((r) => r.id), ['m2']);
      // 서버로 1시간(+유예)이 지나야 m1을 지운다.
      expect(
        (await store.purgeExpiredTexts(
          serverNow: expiresAt.add(_grace + const Duration(seconds: 1)),
        )).map((r) => r.id),
        ['m1'],
      );
    },
  );

  test('서버 시각은 받은 값 중 가장 늦은 것에 흐른 시간을 더해 어림하고, 더 이른 값으로 되돌리지 않는다', () async {
    final serverTime = DateTime.now().add(const Duration(days: 2));
    await store.saveDecryptedText(
      _ref(
        'due',
        1000,
        expiryKnown: true,
        expiresAt: serverTime.subtract(_grace + const Duration(seconds: 10)),
      ),
      '지울 때가 된 메시지',
    );
    await store.saveDecryptedText(
      _ref(
        'later',
        2000,
        expiryKnown: true,
        expiresAt: serverTime.add(const Duration(hours: 1)),
      ),
      '아직 남을 메시지',
    );
    store.noteServerTime(serverTime);
    // 늦게 도착한 옛 시각(지연된 알림 등)은 무시한다.
    store.noteServerTime(serverTime.subtract(const Duration(days: 1)));
    final removed = await store.purgeExpiredTexts();
    expect(removed.map((r) => r.id), ['due']);
    expect(storage.entry('r1', 'later'), isNotNull);
  });

  test(
    '히스토리 정보만 반영(applyHistoryMetadata) — 복호화 없이 서버가 정한 시각을 적고, 예전 형식을 방·시각과 함께 옮긴다',
    () async {
      final expiresA = DateTime.now().add(const Duration(days: 1));
      final expiresB = DateTime.now().add(const Duration(days: 2));
      storage.data['secretmsg/m1'] = '옛 메시지';
      storage.data['secretmsg/c1'] = '옛 댓글';
      storage.data['secretmsg/m3'] = '지워진 옛 메시지';
      await store.saveDecryptedText(_ref('m2', 2000), '내 메시지');
      await store.saveDecryptedText(_ref('c2', 2500, parentId: 'm2'), '내 댓글');

      await store.applyHistoryMetadata('r1', [
        _msg('m1', 1000, comments: [_comment('c1', 'm1', 1500)])
          ..readAt = expiresA.subtract(const Duration(hours: 1))
          ..expiresAt = expiresA,
        _msg('m2', 2000, comments: [_comment('c2', 'm2', 2500)])
          ..readAt = expiresB.subtract(const Duration(hours: 1))
          ..expiresAt = expiresB,
        _msg('m3', 3000, deleted: true),
      ]);
      expect(storage.entry('r1', 'm1'), {
        't': '옛 메시지',
        'c': 1000,
        'e': expiresA.millisecondsSinceEpoch,
        'f': true,
      });
      expect(storage.entry('r1', 'c1'), {
        't': '옛 댓글',
        'c': 1500,
        'p': 'm1',
        'e': expiresA.millisecondsSinceEpoch,
        'f': true,
      });
      expect(storage.data.containsKey('secretmsg/m1'), isFalse);
      expect(storage.data.containsKey('secretmsg/c1'), isFalse);
      expect(storage.entry('r1', 'm2')!['e'], expiresB.millisecondsSinceEpoch);
      expect(storage.entry('r1', 'c2')!['e'], expiresB.millisecondsSinceEpoch);
      expect(storage.entry('r1', 'c2')!['f'], isTrue);
      // 지워진 것으로 온 메시지는 옮기지 않는다(재조정이 지운다).
      expect(storage.data['secretmsg/m3'], '지워진 옛 메시지');
    },
  );

  test('삭제 예정 시각만 바꿔도 저장 순번은 그대로라, 그 뒤 재조정이 서버에서 없어진 댓글을 놓치지 않는다', () async {
    await store.saveDecryptedText(_ref('m1', 1000), '메시지');
    await store.saveDecryptedText(_ref('c1', 1500, parentId: 'm1'), '지워질 댓글');
    final generation = store.textCacheGeneration;
    final page = [
      _msg('m1', 1000)
        ..readAt = DateTime.now()
        ..expiresAt = DateTime.now().add(const Duration(days: 1)),
    ];
    await store.applyHistoryMetadata('r1', page);
    expect(storage.entry('r1', 'c1')!['f'], isTrue);
    final removed = await store.reconcileHistoryPage(
      roomId: 'r1',
      page: page,
      before: null,
      limit: 50,
      sinceGeneration: generation,
    );
    expect(removed.map((r) => r.id), ['c1']);
  });

  test('이 기기에 남은 비밀 대화방 — 키만·평문만·계정 표시만 있어도 세고, 계정 표시는 다시 켜도 남는다', () async {
    storage.data['secret/rA/chainKey'] = 'AQID';
    storage.data['secretcache/rB/x'] = jsonEncode({'t': '평문', 'c': 1});
    storage.data['secret_device_id'] = '기기 키(비밀 대화방 아님)';
    await store.noteRoomOwner('rC', 'me');
    expect(store.localSecretRoomIds, {'rA', 'rB', 'rC'});
    expect(store.roomOwner('rC'), 'me');
    expect(store.roomOwner('rA'), isNull);

    final restarted = SecretKeyStore(storage: storage);
    addTearDown(restarted.dispose);
    expect(await restarted.ensureTextIndex(), isTrue);
    expect(restarted.localSecretRoomIds, {'rA', 'rB', 'rC'});
    expect(restarted.roomOwner('rC'), 'me');
  });

  test(
    '다시 맞춰 볼 방 — 언제 지워질지 모르는 평문이나, 이 기기 시계로는 시각이 지났는데 아직 남은 평문이 있는 방',
    () async {
      final now = DateTime.now();
      await store.saveDecryptedText(
        _ref(
          'a',
          1,
          roomId: 'fixedFuture',
          expiryKnown: true,
          expiresAt: now.add(const Duration(days: 1)),
        ),
        '서버가 정한 내일',
      );
      await store.saveDecryptedText(_ref('b', 1, roomId: 'unknown'), '모름');
      await store.saveDecryptedText(_ref('c', 1, roomId: 'guessed'), '어림');
      await store.noteLocalRead('c', const Duration(days: 1), now: now);
      await store.saveDecryptedText(
        _ref(
          'd',
          1,
          roomId: 'fixedPast',
          expiryKnown: true,
          expiresAt: now.subtract(const Duration(hours: 1)),
        ),
        '서버가 정한 한 시간 전',
      );
      await store.saveDecryptedText(
        _ref('e', 1, roomId: 'neverExpires', expiryKnown: true),
        '타이머 없이 읽힘',
      );
      expect(store.roomsNeedingReconcile(now: now), {
        'unknown',
        'guessed',
        'fixedPast',
        'neverExpires',
      });
    },
  );

  test('예전 형식 정리 — 다 훑었다는 표시는 다시 켜도 남고, 남은 예전 형식을 지우면 표시도 함께 치운다', () async {
    storage.data['secretmsg/x1'] = '하나';
    storage.data['secretmsg/x2'] = '둘';
    expect(await store.ensureTextIndex(), isTrue);
    expect(store.hasLegacyTexts, isTrue);
    await store.markLegacySwept('me');

    final restarted = SecretKeyStore(storage: storage);
    addTearDown(restarted.dispose);
    expect(await restarted.ensureTextIndex(), isTrue);
    expect(restarted.legacySweptFor('me'), isTrue);
    expect(restarted.legacySweptFor('other'), isFalse);
    expect(await restarted.deleteLegacyTexts(), 2);
    expect(restarted.hasLegacyTexts, isFalse);
    expect(
      storage.data.keys.where(
        (k) =>
            k.startsWith('secretmsg/') || k.startsWith('secretcache-legacy/'),
      ),
      isEmpty,
    );
  });

  test('저장소 접근이 겹쳐도(Windows 저장소처럼 전체 읽기→쓰기) 체인키 저장이 평문 정리에 덮이지 않는다', () async {
    final racy = _MemoryStorage(null, true);
    // 전제 확인 — 이 가짜 저장소에서 두 쓰기를 동시에 하면 하나가 사라진다.
    await Future.wait([
      racy.write(key: 'a', value: '1'),
      racy.write(key: 'b', value: '2'),
    ]);
    expect(racy.data.length, 1);
    racy.data.clear();

    final racyStore = SecretKeyStore(storage: racy);
    addTearDown(racyStore.dispose);
    racyStore.noteServerTime(DateTime.now());
    final expired = DateTime.now().subtract(const Duration(hours: 1));
    await racyStore.saveDecryptedText(
      _ref('m1', 100, expiryKnown: true, expiresAt: expired),
      '만료된 평문',
    );
    await Future.wait([
      racyStore.saveChainState(
        'r1',
        SecretChainState(epoch: 0, n: 2, chainKey: List.filled(32, 9)),
      ),
      racyStore.purgeExpiredTexts(),
      racyStore.saveDecryptedText(_ref('m2', 200), '새 평문'),
      racyStore.savePendingEphemeralSeed('r1', [7]),
    ]);
    final state = await racyStore.readChainState('r1');
    expect(state?.n, 2);
    expect(state?.chainKey, List.filled(32, 9));
    expect(await racyStore.readPendingEphemeralSeed('r1'), [7]);
    expect(racy.entry('r1', 'm1'), isNull);
    expect(racy.entry('r1', 'm2'), isNotNull);
  });
}
