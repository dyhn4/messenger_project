// 웹 앱의 오프라인 저장(IndexedDB) — 메시지 DB(message_db_web.dart)와 보내기 대기열의 첨부(outbox_files_web.dart).
// 브라우저에서만 돈다: `flutter test --platform chrome test/web/message_db_web_test.dart`.
@TestOn('browser')
library;

import 'package:client/services/message_db.dart';
import 'package:client/services/message_db_web.dart';
import 'package:client/services/offline_cache.dart';
import 'package:client/services/outbox_files_web.dart' as files;
import 'package:flutter_test/flutter_test.dart';

final _t0 = DateTime(2026, 10, 21, 9);

Map<String, dynamic> _msg(
  String id,
  String room,
  int minute, {
  String text = '',
  String type = 'text',
  bool deleted = false,
}) => {
  'id': id,
  'roomId': room,
  'senderId': 'u2',
  'senderName': 'Sam',
  'type': type,
  'text': text,
  'deleted': deleted,
  'createdAt': _t0.add(Duration(minutes: minute)).millisecondsSinceEpoch,
};

void main() {
  var n = 0;
  late String scope;
  late MessageDb db;
  setUp(() async {
    scope = 'test_${DateTime.now().microsecondsSinceEpoch}_${n++}';
    db = (await openMessageDb(scope, null))!;
  });
  tearDown(() => db.destroy());

  test('넣고·바꾸고, 방의 최근 것과 더 오래된 것, 찾기(지운 것·이모티콘·다른 방 제외), 지우기', () async {
    await db.upsertAll('R1', [
      for (var i = 0; i < 30; i++) _msg('m$i', 'R1', i, text: '회의록 $i번째'),
    ]);
    await db.upsertAll('R2', [_msg('x', 'R2', 5, text: '다른 방 회의록')]);
    await db.upsertAll('R1', [
      _msg('s', 'R1', 40, text: '회의록', type: 'sticker'),
      _msg('d', 'R1', 41, text: '회의록', deleted: true),
    ]);
    expect(await db.count('R1'), 32);
    expect((await db.latest('R1', limit: 3)).map((m) => m['id']), [
      'm29',
      's',
      'd',
    ]);
    expect(
      (await db.older(
        'R1',
        _t0.add(const Duration(minutes: 20)),
        limit: 3,
      )).map((m) => m['id']),
      ['m17', 'm18', 'm19'],
    );
    final found = await db.search('회의록 1', roomIds: ['R1']);
    expect(found.first['id'], 'm19', reason: '새것부터');
    expect(found.map((m) => m['id']), containsAll(['m1', 'm10', 'm19']));
    expect(found.map((m) => m['id']), isNot(contains('x')));
    final all = await db.search('회의록');
    expect(all.map((m) => m['id']), isNot(contains('s')));
    expect(all.map((m) => m['id']), isNot(contains('d')));
    expect(all.map((m) => m['id']), contains('x'));

    await db.update('m29', (raw) => {...raw, 'text': '고친 글'});
    expect((await db.latest('R1', limit: 3)).first['text'], '고친 글');
    expect(
      (await db.newestByRoom())['R1'],
      _t0.add(const Duration(minutes: 41)),
    );

    await db.forgetBefore('R1', _t0.add(const Duration(minutes: 10)));
    expect(await db.count('R1'), 22);
    await db.forgetRoom('R1');
    expect(await db.count('R1'), 0);
    expect(await db.count('R2'), 1);
  });

  test('서버가 완전히 지운 메시지 — id로 지운다(없는 id는 넘어감)', () async {
    await db.upsertAll('R1', [
      _msg('a', 'R1', 1, text: '첫 글'),
      _msg('b', 'R1', 2, text: '둘째 글'),
    ]);
    await db.remove(['a', '없는 id']);
    expect((await db.latest('R1')).map((m) => m['id']), ['b']);
    expect(await db.search('첫 글'), isEmpty);
  });

  test('방마다 최근 5000통만', () async {
    await db.upsertAll('R1', [
      for (var i = 0; i < messageDbPerRoomMax + 20; i++) _msg('m$i', 'R1', i),
    ]);
    expect(await db.count('R1'), messageDbPerRoomMax);
    final oldest = await db.older(
      'R1',
      _t0.add(const Duration(minutes: 21)),
      limit: 5,
    );
    expect(oldest.map((m) => m['id']), ['m20']);
  });

  test('오프라인 보기 저장소 — 웹은 팀·방 목록·동기화 자리도 IndexedDB에, 로그아웃하면 DB째 지움', () async {
    db.close();
    final cache = OfflineCache(openDb: (s, dir) => openMessageDb(scope, dir));
    await cache.configure('https://s:3000', 'U1');
    expect(cache.enabled, isTrue);
    cache.saveTeams([
      {'id': 't1', 'name': '팀'},
    ]);
    await cache.saveMessages('R1', [_msg('m1', 'R1', 1)]);
    await cache.markSyncPoints();
    await cache.flush();

    final again = OfflineCache(openDb: (s, dir) => openMessageDb(scope, dir));
    await again.configure('https://s:3000', 'U1');
    expect((await again.teams()).single['name'], '팀');
    expect((await again.messages('R1')).single['id'], 'm1');
    expect(
      (await again.syncPoints())['R1'],
      _t0.add(const Duration(minutes: 1)),
    );
    cache.close();
    await again.clear();

    final cleared = OfflineCache(openDb: (s, dir) => openMessageDb(scope, dir));
    await cleared.configure('https://s:3000', 'U1');
    expect(await cleared.teams(), isEmpty);
    expect(await cleared.messages('R1'), isEmpty);
    db = cleared.db!; // tearDown이 지운다.
  });

  test('보내기 대기열의 첨부 — IndexedDB에 담았다가 원래 이름으로 꺼내고 치운다', () async {
    final stashed = await files.stashFilesForOutbox('c-web-1', [
      (bytes: [1, 2, 3], name: '사진.jpg', mimeType: 'image/jpeg', isImage: true),
      (bytes: [4], name: '문서.pdf', mimeType: null, isImage: false),
    ]);
    expect(stashed!.map((f) => f.path), ['idb:c-web-1/0', 'idb:c-web-1/1']);
    final opened = await files.openOutboxFile(stashed.first);
    expect(opened!.name, '사진.jpg');
    expect(await opened.readAsBytes(), [1, 2, 3]);
    await files.deleteOutboxFile(stashed.first.path);
    expect(await files.outboxFileExists(stashed.first.path), isFalse);
    expect(await files.outboxFileExists(stashed.last.path), isTrue);
    await files.deleteOutboxFiles('c-web-1');
    expect(await files.outboxFileExists(stashed.last.path), isFalse);
  });
}
