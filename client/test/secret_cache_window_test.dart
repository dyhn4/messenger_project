import 'package:client/models/comment.dart';
import 'package:client/models/message.dart';
import 'package:client/services/secret_key_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// 비밀 대화 평문 캐시 재조정(S34)의 "범위" 판단 — 히스토리 한 페이지가 실제로 훑은 범위 안에서 응답에
/// 없는 항목만 서버에서 없어졌다고 본다(secretCacheIdsGoneFromPage). 서버 규칙은 server/src/rooms.js의
/// GET /rooms/:id/messages: before보다 앞선 최근 limit개(최대 200), 창 메시지의 댓글 전부, 창 시간대의
/// 댓글은 부모가 창 밖이어도(outOfWindow) 함께 온다.

DateTime _at(int ms) => DateTime.fromMillisecondsSinceEpoch(ms);

Message _msg(
  String id,
  int createdAtMs, {
  bool outOfWindow = false,
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
  outOfWindow: outOfWindow,
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

SecretCachedTextInfo _entry(String id, int createdAtMs, {String? parentId}) =>
    SecretCachedTextInfo(
      roomId: 'r1',
      id: id,
      parentId: parentId,
      createdAtMs: createdAtMs,
    );

Set<String> _gone(
  List<SecretCachedTextInfo> entries,
  List<Message> page, {
  DateTime? before,
  required int limit,
}) => secretCacheIdsGoneFromPage(
  entries: entries,
  page: page,
  before: before,
  limit: limit,
);

void main() {
  group('최신 페이지(before 없음)', () {
    test('꽉 찬 페이지 — 가장 오래된 창 메시지보다 새것 중 응답에 없는 것만 없어진 것으로 본다', () {
      final page = [_msg('m3', 300), _msg('m4', 400), _msg('m5', 500)];
      final gone = _gone(
        [
          _entry('m1', 100), // 창보다 오래됨 — 이번 요청이 안 훑었다.
          _entry('tie', 300), // 가장 오래된 창 메시지와 같은 시각 — 동점이 창 밖에 남았을 수 있다.
          _entry('m3', 300),
          _entry('expired', 450),
          _entry('m5', 500),
          _entry('newest', 900), // 요청 전에 저장된 항목이라 있었다면 응답에 왔다.
        ],
        page,
        limit: 3,
      );
      expect(gone, {'expired', 'newest'});
    });

    test('덜 찬 페이지 — 방의 처음까지 다 받은 것이라 더 오래된 항목도 응답에 없으면 없어진 것', () {
      final page = [_msg('m3', 300), _msg('m5', 500)];
      final gone = _gone(
        [_entry('m1', 100), _entry('m3', 300), _entry('m4', 400)],
        page,
        limit: 50,
      );
      expect(gone, {'m1', 'm4'});
    });

    test('빈 페이지 — 방에 메시지가 하나도 없다는 답이므로 넘긴 항목(요청 전에 저장한 것)은 모두 없어진 것', () {
      final gone = _gone(
        [_entry('m1', 100), _entry('c1', 150, parentId: 'm1')],
        const [],
        limit: 50,
      );
      expect(gone, {'m1', 'c1'});
    });

    test('창 밖 부모(outOfWindow)는 페이지 크기와 아래 경계 계산에 넣지 않는다', () {
      // 창 메시지 2개(limit 2 — 꽉 참) + 창 시간대 댓글 때문에 딸려 온 오래된 부모 하나.
      final page = [
        _msg('old', 50, outOfWindow: true),
        _msg('m4', 400),
        _msg('m5', 500),
      ];
      final gone = _gone(
        [_entry('old', 50), _entry('m2', 200), _entry('m45', 450)],
        page,
        limit: 2,
      );
      // m2(200)는 창(400 초과) 밖이라 남고, old는 응답에 있으니 남는다.
      expect(gone, {'m45'});
    });

    test('서버는 한 번에 200개까지만 주므로 그보다 크게 요청해도 200개면 꽉 찬 페이지다', () {
      final page = [for (var i = 0; i < 200; i++) _msg('p$i', 1000 + i)];
      final gone = _gone(
        [_entry('older', 10), _entry('inside', 1100)],
        page,
        limit: 500,
      );
      expect(gone, {'inside'});
    });
  });

  group('과거 페이지(before)', () {
    test('before 이상은 이번 요청 범위 밖 — 응답에 없어도 남긴다', () {
      final page = [_msg('m7', 700), _msg('m8', 800)];
      final gone = _gone(
        [
          _entry('m6', 600), // 꽉 찬 페이지의 아래 경계보다 오래됨.
          _entry('gone75', 750),
          _entry('atBefore', 1000),
          _entry('after', 1200),
        ],
        page,
        before: _at(1000),
        limit: 2,
      );
      expect(gone, {'gone75'});
    });

    test('빈 페이지 — before 이전엔 메시지가 없다는 답이라 그 앞 항목만 없어진 것', () {
      final gone = _gone(
        [_entry('a', 500), _entry('b', 1000), _entry('c', 1500)],
        const [],
        before: _at(1000),
        limit: 50,
      );
      expect(gone, {'a'});
    });
  });

  group('댓글', () {
    // before 1000, limit 2(꽉 참) — 창은 (500, 1000). p0은 창 시간대 댓글(c0w) 때문에 딸려 온 창 밖 부모.
    final page = [
      _msg('p0', 100, outOfWindow: true, comments: [_comment('c0w', 'p0', 550)]),
      _msg('p1', 500, comments: [_comment('c1', 'p1', 1200)]),
      _msg('p2', 600),
    ];
    final entries = [
      _entry('c1', 1200, parentId: 'p1'),
      // 창 안 메시지(p1)의 댓글은 언제 달렸든 전부 오므로, 없으면 없어진 것.
      _entry('c1gone', 1500, parentId: 'p1'),
      // 창 밖 부모(p0)의 댓글은 창 시간대 것만 온다.
      _entry('c0old', 300, parentId: 'p0'),
      _entry('c0gone', 560, parentId: 'p0'),
      _entry('c0late', 1100, parentId: 'p0'),
      // 창 안에서 없어진 메시지 — 서버가 댓글째 지웠다(댓글 시각이 창 밖이어도).
      _entry('g', 550),
      _entry('cg', 1500, parentId: 'g'),
      // 부모를 모르는 댓글 — 창 시간대에 달린 것이면 있었다면 부모와 함께 왔다.
      _entry('cy', 700, parentId: 'py'),
      _entry('cz', 1100, parentId: 'pz'),
    ];

    test('창 안 메시지의 댓글·없어진 메시지의 댓글·창 시간대 댓글만 없어진 것으로 본다', () {
      final gone = _gone(entries, page, before: _at(1000), limit: 2);
      expect(gone, {'c1gone', 'c0gone', 'g', 'cg', 'cy'});
    });

    test('덜 찬 페이지면 before 이전 댓글은 응답에 없으면 모두 없어진 것(부모가 다 창 안에 있다)', () {
      final gone = _gone(
        [
          _entry('early', 300, parentId: 'p1'),
          _entry('orphan', 50, parentId: 'unknown'),
          _entry('afterBefore', 1100, parentId: 'unknown'),
        ],
        [_msg('p1', 200)],
        before: _at(1000),
        limit: 50,
      );
      expect(gone, {'early', 'orphan'});
    });
  });
}
