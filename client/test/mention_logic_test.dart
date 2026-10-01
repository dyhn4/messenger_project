import 'package:client/models/app_user.dart';
import 'package:client/models/comment.dart';
import 'package:client/models/mention.dart';
import 'package:client/models/message.dart';
import 'package:client/models/room.dart';
import 'package:client/models/scheduled_message.dart';
import 'package:client/services/mention_logic.dart';
import 'package:client/widgets/rich_text_format.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

AppUser _u(String id, String name, {String? username}) =>
    AppUser(id: id, username: username ?? id, name: name);

Room _room(
  RoomType type, {
  bool secret = false,
  bool self = false,
  List<AppUser>? members,
}) => Room(
  id: 'r',
  teamId: 't',
  type: type,
  name: 'x',
  members: members ?? [_u('me', '나'), _u('a', '김철수')],
  createdAt: DateTime(2026),
  lastRead: {},
  isSecret: secret,
  isSelf: self,
);

/// 입력칸에 글을 "쳐 넣는" 것처럼 값을 바꾼다(컨트롤러의 글 따라가기를 타게).
void _type(RichTextEditingController c, String text, [int? caret]) {
  c.value = TextEditingValue(
    text: text,
    selection: TextSelection.collapsed(offset: caret ?? text.length),
  );
}

void main() {
  group('Mention JSON', () {
    test('user·all 모양을 읽고 그대로 내보낸다', () {
      final list = parseMentions([
        {'type': 'all', 's': 10, 'e': 14},
        {'type': 'user', 'userId': 'u1', 's': 0, 'e': 4},
      ]);
      // 시작 위치순으로 정렬된다.
      expect(list.map((m) => m.start), [0, 10]);
      expect(list[0].type, MentionType.user);
      expect(list[0].userId, 'u1');
      expect(list[1].isAll, isTrue);
      expect(mentionsToJson(list), [
        {'type': 'user', 'userId': 'u1', 's': 0, 'e': 4},
        {'type': 'all', 's': 10, 'e': 14},
      ]);
    });

    test('모르는 종류·깨진 항목은 그 항목만 빠지고 나머지는 남는다', () {
      final list = parseMentions([
        {'type': 'department', 'id': 'd', 's': 0, 'e': 3},
        {'type': 'user', 's': 0, 'e': 3}, // userId 없음
        {'type': 'user', 'userId': 'u', 's': 5, 'e': 5}, // 빈 구간
        'x',
        {'type': 'user', 'userId': 'ok', 's': 2, 'e': 6},
      ]);
      expect(list, hasLength(1));
      expect(list.single.userId, 'ok');
      expect(parseMentions(null), isEmpty);
      expect(parseMentions('x'), isEmpty);
    });

    test('비어 있으면 JSON은 null(필드를 안 보낸다)', () {
      expect(mentionsToJson(const []), isNull);
      expect(mentionsToJson(null), isNull);
    });

    test('Message·Comment·ScheduledMessage가 mentions를 읽고, 없으면 빈 목록', () {
      final m = Message.fromJson({
        'id': 'm',
        'roomId': 'r',
        'senderId': 's',
        'senderName': '나',
        'type': 'text',
        'text': '@홍길동 안녕',
        'createdAt': 1,
        'mentions': [
          {'type': 'user', 'userId': 'u1', 's': 0, 'e': 4},
        ],
      });
      expect(m.mentions.single.userId, 'u1');
      final none = Message.fromJson({
        'id': 'm',
        'roomId': 'r',
        'senderName': '나',
        'type': 'text',
        'createdAt': 1,
      });
      expect(none.mentions, isEmpty);
      final c = Comment.fromJson({
        'id': 'c',
        'messageId': 'm',
        'roomId': 'r',
        'senderName': '나',
        'createdAt': 1,
        'mentions': [
          {'type': 'all', 's': 0, 'e': 4},
        ],
      });
      expect(c.mentions.single.isAll, isTrue);
      final s = ScheduledMessage.fromJson({
        'id': 's',
        'text': '@all 공지',
        'sendAt': 1,
        'mentions': [
          {'type': 'all', 's': 0, 'e': 4},
        ],
      });
      expect(s.mentions.single.isAll, isTrue);
      expect(
        s.withStatus(ScheduledMessageStatus.failed).mentions,
        hasLength(1),
      );
    });

    test('방 DTO의 unreadMentionCount — 없으면 0, 방 병합은 개인 값일 때만 덮는다', () {
      final json = {
        'id': 'r',
        'teamId': 't',
        'type': 'topic',
        'name': '토픽',
        'members': [
          {'id': 'me', 'username': 'me', 'name': '나'},
        ],
        'createdAt': 1,
      };
      final room = Room.fromJson({...json, 'unreadMentionCount': 2});
      expect(room.unreadMentionCount, 2);
      expect(Room.fromJson(json).unreadMentionCount, 0);
      // 브로드캐스트(개인 값 없음)는 기존 값을 지우지 않는다.
      room.mergeServerState(Room.fromJson(json));
      expect(room.unreadMentionCount, 2);
      room.mergeServerState(Room.fromJson(json), includePersonal: true);
      expect(room.unreadMentionCount, 0);
    });
  });

  group('멘션 구간 추적(remapMentionsForEdit)', () {
    // "@홍길동 안녕" — 멘션은 0..4.
    const name = Mention.user('u1', start: 0, end: 4);

    test('앞쪽에 글자를 넣으면 구간이 그만큼 밀린다', () {
      final out = remapMentionsForEdit([name], 0, 0, 3);
      expect(out.single.start, 3);
      expect(out.single.end, 7);
    });

    test('구간 끝에 이어 치거나 뒤쪽을 고치면 구간은 그대로다', () {
      expect(remapMentionsForEdit([name], 4, 0, 1).single, name);
      expect(remapMentionsForEdit([name], 5, 2, 0).single, name);
      expect(remapMentionsForEdit([name], 9, 0, 4).single, name);
    });

    test('앞쪽을 지우면 구간이 당겨진다', () {
      const m = Mention.user('u1', start: 6, end: 10);
      final out = remapMentionsForEdit([m], 0, 3, 0);
      expect(out.single.start, 3);
      expect(out.single.end, 7);
    });

    test('이름 글자를 지우거나 고치거나 한가운데 끼우면 멘션이 풀린다', () {
      expect(remapMentionsForEdit([name], 3, 1, 0), isEmpty); // 끝 글자 삭제
      expect(remapMentionsForEdit([name], 1, 1, 1), isEmpty); // 글자 바꾸기
      expect(remapMentionsForEdit([name], 2, 0, 1), isEmpty); // 한가운데 끼우기
      expect(remapMentionsForEdit([name], 0, 1, 0), isEmpty); // '@' 지우기
      expect(remapMentionsForEdit([name], 0, 4, 2), isEmpty); // 통째로 바꾸기
    });

    test('여러 멘션 중 건드린 것만 풀린다', () {
      const a = Mention.user('a', start: 0, end: 3);
      const b = Mention.user('b', start: 4, end: 8);
      final out = remapMentionsForEdit([a, b], 5, 1, 1);
      expect(out, [a]);
    });
  });

  group('sliceMentions·sanitizeMentions', () {
    test('앞뒤 공백을 뗀 만큼 구간을 당기고, 밖에 있던 것은 버린다', () {
      const m = Mention.user('u', start: 2, end: 6);
      expect(sliceMentions([m], 2, 10).single.start, 0);
      expect(sliceMentions([m], 3, 10), isEmpty);
      expect(sliceMentions([m], 0, 5), isEmpty);
    });

    test('@로 시작하지 않는 것·범위 밖·겹침·중복·자기 자신·허용 안 되는 @all을 뺀다', () {
      const text = '@철수 @영희 @철수 @all x';
      final all = [
        const Mention.user('a', start: 0, end: 3),
        const Mention.user('b', start: 4, end: 7),
        const Mention.user('a', start: 8, end: 11), // 같은 사람 두 번째
        const Mention.all(start: 12, end: 16),
        const Mention.user('c', start: 17, end: 18), // 'x' — @ 아님
        const Mention.user('d', start: 20, end: 99), // 범위 밖
      ];
      final out = sanitizeMentions(all, text, selfUserId: 'b');
      expect(out.map((m) => m.userId ?? 'all'), ['a', 'all']);
      final noAll = sanitizeMentions(all, text, allowAll: false);
      expect(noAll.any((m) => m.isAll), isFalse);
      final overlap = sanitizeMentions([
        const Mention.user('a', start: 0, end: 5),
        const Mention.user('b', start: 3, end: 7),
      ], text);
      expect(overlap.map((m) => m.userId), ['a']);
    });

    test('최대 50개', () {
      final text = List.generate(60, (i) => '@u$i').join(' ');
      var at = 0;
      final list = <Mention>[];
      for (var i = 0; i < 60; i++) {
        final len = '@u$i'.length;
        list.add(Mention.user('u$i', start: at, end: at + len));
        at += len + 1;
      }
      expect(sanitizeMentions(list, text), hasLength(50));
    });
  });

  group('activeMentionQuery', () {
    test('@ 뒤에 공백 없이 이어 친 글자를 찾는다', () {
      expect(activeMentionQuery('@', 1), const MentionQuery(0, ''));
      expect(activeMentionQuery('@철', 2), const MentionQuery(0, '철'));
      expect(activeMentionQuery('안녕 @철수', 6), const MentionQuery(3, '철수'));
      expect(activeMentionQuery('줄\n@a', 4), const MentionQuery(2, 'a'));
    });

    test('이메일처럼 글자에 붙은 @나 공백 뒤는 해당 없다', () {
      expect(activeMentionQuery('a@b', 3), isNull);
      expect(activeMentionQuery('@철수 안', 6), isNull);
      expect(activeMentionQuery('안녕', 2), isNull);
      expect(activeMentionQuery('', 0), isNull);
    });

    test('이미 멘션이 된 글자 안이면 다시 열지 않는다', () {
      const m = Mention.user('u', start: 0, end: 4);
      expect(activeMentionQuery('@철수야', 4, existing: [m]), isNull);
    });

    test('너무 길게 이어지면 글로 본다', () {
      final long = '@${'a' * 40}';
      expect(activeMentionQuery(long, long.length), isNull);
    });
  });

  group('mentionCandidates', () {
    final members = [
      _u('me', '나', username: 'me'),
      _u('a', '김철수', username: 'chulsoo'),
      _u('b', '이영희', username: 'younghee'),
      _u('c', '박철민', username: 'cm'),
    ];

    test('나는 빠지고, 토픽·그룹이면 @all이 맨 앞에 붙는다', () {
      final out = mentionCandidates(
        members: members,
        myUserId: 'me',
        allowAll: true,
        query: '',
      );
      expect(out.first.isAll, isTrue);
      expect(out.skip(1).map((c) => c.user!.name), ['김철수', '박철민', '이영희']);
      final dm = mentionCandidates(
        members: members,
        myUserId: 'me',
        allowAll: false,
        query: '',
      );
      expect(dm.any((c) => c.isAll), isFalse);
    });

    test('이름·아이디에 들어 있는 사람만, 앞에서 시작하는 사람이 먼저', () {
      final byName = mentionCandidates(
        members: members,
        myUserId: 'me',
        allowAll: true,
        query: '철',
      );
      expect(byName.map((c) => c.label), ['김철수', '박철민']);
      final byUsername = mentionCandidates(
        members: members,
        myUserId: 'me',
        allowAll: false,
        query: 'young',
      );
      expect(byUsername.single.label, '이영희');
      final startsFirst = mentionCandidates(
        members: [
          _u('x', '김영', username: 'k'),
          _u('y', '영수', username: 'y'),
        ],
        myUserId: 'me',
        allowAll: false,
        query: '영',
      );
      expect(startsFirst.map((c) => c.label), ['영수', '김영']);
    });

    test('@all은 all/전체/모두를 치는 동안만 보이고, 없는 이름이면 빈 목록', () {
      bool hasAll(String q) => mentionCandidates(
        members: members,
        myUserId: 'me',
        allowAll: true,
        query: q,
      ).any((c) => c.isAll);
      expect(hasAll('a'), isTrue);
      expect(hasAll('ALL'), isTrue);
      expect(hasAll('전'), isTrue);
      expect(hasAll('모'), isTrue);
      expect(hasAll('철'), isFalse);
      expect(
        mentionCandidates(
          members: members,
          myUserId: 'me',
          allowAll: false,
          query: '없는사람',
        ),
        isEmpty,
      );
    });

    test('개수 제한', () {
      final many = [for (var i = 0; i < 30; i++) _u('u$i', '멤버$i')];
      expect(
        mentionCandidates(
          members: many,
          myUserId: null,
          allowAll: true,
          query: '',
          limit: 8,
        ),
        hasLength(8),
      );
    });
  });

  group('방 종류별 허용', () {
    test('멘션·@all은 토픽·그룹에서만 — 1:1·나와의 대화·비밀 대화는 안 된다', () {
      expect(roomAllowsMentionAll(_room(RoomType.topic)), isTrue);
      expect(roomAllowsMentionAll(_room(RoomType.group)), isTrue);
      expect(roomAllowsMentionAll(_room(RoomType.dm)), isFalse);
      expect(roomAllowsMentionAll(_room(RoomType.dm, self: true)), isFalse);
      expect(
        roomAllowsMentionAll(_room(RoomType.topic, secret: true)),
        isFalse,
      );
      expect(roomAllowsMention(_room(RoomType.topic)), isTrue);
      expect(roomAllowsMention(_room(RoomType.group)), isTrue);
      expect(roomAllowsMention(_room(RoomType.dm)), isFalse);
      expect(roomAllowsMention(_room(RoomType.dm, self: true)), isFalse);
      expect(roomAllowsMention(_room(RoomType.dm, secret: true)), isFalse);
      expect(roomAllowsMention(_room(RoomType.group, secret: true)), isFalse);
    });
  });

  group('RichTextEditingController 멘션 추적', () {
    RichTextEditingController make() =>
        RichTextEditingController()..mentionsEnabled = true;

    test('insertMention — "@이름 "이 들어가고 구간이 잡히며 커서는 그 뒤', () {
      final c = make();
      _type(c, '안녕 @철');
      c.insertMention(start: 3, end: 5, label: '김철수', userId: 'a');
      expect(c.text, '안녕 @김철수 ');
      expect(c.mentions.single, const Mention.user('a', start: 3, end: 7));
      expect(c.selection.baseOffset, c.text.length);
      expect(c.text.substring(3, 7), '@김철수');
    });

    test('뒤에 이미 공백이 있으면 공백을 더 넣지 않는다', () {
      final c = make();
      _type(c, '@ 끝', 1);
      c.insertMention(start: 0, end: 1, label: 'all');
      expect(c.text, '@all 끝');
      expect(c.mentions.single.isAll, isTrue);
      expect(c.selection.baseOffset, 5);
    });

    test('앞에 글을 더 치면 구간이 따라 밀린다', () {
      final c = make();
      _type(c, '@철');
      c.insertMention(start: 0, end: 2, label: '김철수', userId: 'a');
      _type(c, '안녕 ${c.text}', 3);
      expect(c.mentions.single.start, 3);
      expect(
        c.text.substring(c.mentions.single.start, c.mentions.single.end),
        '@김철수',
      );
    });

    test('이름을 지우면 그 멘션은 풀리고 다른 멘션은 남는다', () {
      final c = make();
      _type(c, '@철');
      c.insertMention(start: 0, end: 2, label: '김철수', userId: 'a');
      _type(c, '${c.text}@영');
      c.insertMention(start: 5, end: 7, label: '이영희', userId: 'b');
      expect(c.mentions, hasLength(2));
      // 첫 이름의 글자 하나를 지운다.
      final t = c.text;
      _type(c, t.replaceRange(1, 2, ''), 1);
      expect(c.mentions.map((m) => m.userId), ['b']);
      final m = c.mentions.single;
      expect(c.text.substring(m.start, m.end), '@이영희');
    });

    test('공백·줄바꿈 등 이름 밖을 고쳐도 멘션은 유지된다', () {
      final c = make();
      _type(c, '@철');
      c.insertMention(start: 0, end: 2, label: '김철수', userId: 'a');
      _type(c, '${c.text}반가워요');
      expect(c.mentions, hasLength(1));
      _type(c, c.text.replaceFirst(' 반가워요', ''));
      expect(c.mentions, hasLength(1));
    });

    test('formattedMentions — 앞뒤 공백을 뗀 글에 맞춰 위치를 당긴다', () {
      final c = make();
      _type(c, '  @철');
      c.insertMention(start: 2, end: 4, label: '김철수', userId: 'a');
      final body = c.formatted().text;
      expect(body, '@김철수');
      final m = c.formattedMentions();
      expect(m.single, const Mention.user('a', start: 0, end: 4));
      expect(body.substring(m.single.start, m.single.end), '@김철수');
    });

    test('formattedMentions — 자기 자신과 허용 안 되는 @all은 뺀다', () {
      final c = make();
      _type(c, '@철');
      c.insertMention(start: 0, end: 2, label: '나', userId: 'me');
      _type(c, '${c.text}@a');
      c.insertMention(start: 3, end: 5, label: 'all');
      expect(
        c.formattedMentions(selfUserId: 'me', allowAll: true).single.isAll,
        isTrue,
      );
      expect(c.formattedMentions(selfUserId: 'me', allowAll: false), isEmpty);
    });

    test('load — 수정 화면이 기존 멘션을 이어 받는다(어긋난 것은 버린다)', () {
      final c = make();
      c.load(
        '@홍길동 안녕 @김철수',
        null,
        mentions: const [
          Mention.user('a', start: 0, end: 4),
          Mention.user('b', start: 8, end: 12),
          Mention.user('bad', start: 5, end: 7), // '@'로 시작하지 않음
        ],
      );
      expect(c.mentions.map((m) => m.userId), ['a', 'b']);
      // 이름을 고치면 그 멘션만 풀린다.
      _type(c, c.text.replaceRange(1, 2, '이'));
      expect(c.mentions.map((m) => m.userId), ['b']);
    });

    test('멘션을 끈 입력칸(비밀 대화 등)은 추적도 전송도 하지 않는다', () {
      final c = RichTextEditingController();
      _type(c, '@철');
      c.insertMention(start: 0, end: 2, label: '김철수', userId: 'a');
      expect(c.text, '@철'); // 그대로
      expect(c.mentions, isEmpty);
      expect(c.formattedMentions(), isEmpty);
    });

    test('clear — 보낸 뒤 입력칸을 비우면 멘션도 비운다', () {
      final c = make();
      _type(c, '@철');
      c.insertMention(start: 0, end: 2, label: '김철수', userId: 'a');
      c.clear();
      expect(c.mentions, isEmpty);
    });
  });
}
