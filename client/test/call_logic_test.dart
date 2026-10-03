import 'package:client/models/message.dart';
import 'package:client/screens/call/call_logic.dart';
import 'package:client/services/call_hands.dart';
import 'package:flutter_test/flutter_test.dart';

CallPerson _p(
  String id, {
  bool me = false,
  bool speaking = false,
  DateTime? hand,
}) => CallPerson(
  id: id,
  name: id,
  isMe: me,
  speaking: speaking,
  handRaisedAt: hand,
);

Message _msg(String id, DateTime at, {String? sender, MessageType? type}) =>
    Message(
      id: id,
      roomId: 'r',
      senderId: sender,
      senderName: sender ?? '',
      type: type ?? MessageType.text,
      text: 'x',
      createdAt: at,
    );

void main() {
  group('보기 모드', () {
    test('고른 게 없으면 다른 사람의 화면 공유가 있을 때만 스피커 보기', () {
      expect(
        effectiveViewMode(null, hasRemoteScreenShare: true),
        CallViewMode.speaker,
      );
      expect(
        effectiveViewMode(null, hasRemoteScreenShare: false),
        CallViewMode.gallery,
      );
    });

    test('사용자가 고른 보기는 화면 공유 여부와 상관없이 유지된다', () {
      expect(
        effectiveViewMode(CallViewMode.gallery, hasRemoteScreenShare: true),
        CallViewMode.gallery,
      );
      expect(
        effectiveViewMode(CallViewMode.speaker, hasRemoteScreenShare: false),
        CallViewMode.speaker,
      );
    });
  });

  group('참가자 패널 정렬', () {
    test('손든 사람(든 순서) → 말하는 사람 → 나머지(원래 순서)', () {
      final t0 = DateTime(2026, 1, 1, 10);
      final people = [
        _p('me', me: true),
        _p('a'),
        _p('b', speaking: true),
        _p('c', hand: t0.add(const Duration(seconds: 5))),
        _p('d', hand: t0),
        _p('e', speaking: true, hand: t0.add(const Duration(seconds: 9))),
      ];
      expect(sortForParticipantPanel(people).map((p) => p.id).toList(), [
        'd',
        'c',
        'e',
        'b',
        'me',
        'a',
      ]);
    });

    test('원본 목록은 바꾸지 않는다', () {
      final people = [_p('a'), _p('b', speaking: true)];
      sortForParticipantPanel(people);
      expect(people.first.id, 'a');
    });
  });

  group('SpeakerFocus (메인 타일 선택)', () {
    final t0 = DateTime(2026, 1, 1, 10);
    Duration ms(int v) => Duration(milliseconds: v);
    const all = ['me', 'a', 'b'];

    test('처음엔 말하는 사람, 없으면 나를 뺀 첫 참가자', () {
      final f = SpeakerFocus();
      expect(
        f.update(now: t0, available: all, speakingIds: [], selfId: 'me'),
        'a',
      );
      final g = SpeakerFocus();
      expect(
        g.update(now: t0, available: all, speakingIds: ['b'], selfId: 'me'),
        'b',
      );
    });

    test('나 혼자뿐이면 내가 메인', () {
      final f = SpeakerFocus();
      expect(
        f.update(now: t0, available: ['me'], speakingIds: ['me'], selfId: 'me'),
        'me',
      );
    });

    test('말하는 사람이 바뀌어도 1.5초는 메인을 유지하고 그 뒤에 바꾼다', () {
      final f = SpeakerFocus();
      f.update(now: t0, available: all, speakingIds: ['a'], selfId: 'me');
      expect(f.mainId, 'a');

      // 0.5초 뒤 b가 말해도 a가 메인, 1초 뒤에 다시 계산하라고 알려 준다.
      expect(
        f.update(
          now: t0.add(ms(500)),
          available: all,
          speakingIds: ['b'],
          selfId: 'me',
        ),
        'a',
      );
      expect(f.pendingDelay, ms(1000));

      // 1.5초가 지나고도 b가 말하면 b로 바뀐다.
      expect(
        f.update(
          now: t0.add(ms(1500)),
          available: all,
          speakingIds: ['b'],
          selfId: 'me',
        ),
        'b',
      );
      expect(f.pendingDelay, isNull);
    });

    test('아무도 말하지 않거나 내가 말해도 메인은 그대로', () {
      final f = SpeakerFocus();
      f.update(now: t0, available: all, speakingIds: ['a'], selfId: 'me');
      expect(
        f.update(
          now: t0.add(ms(5000)),
          available: all,
          speakingIds: ['me'],
          selfId: 'me',
        ),
        'a',
      );
      expect(
        f.update(
          now: t0.add(ms(6000)),
          available: all,
          speakingIds: [],
          selfId: 'me',
        ),
        'a',
      );
    });

    test('메인이 통화를 나가면 즉시 다른 사람으로', () {
      final f = SpeakerFocus();
      f.update(now: t0, available: all, speakingIds: ['a'], selfId: 'me');
      expect(
        f.update(
          now: t0.add(ms(100)),
          available: ['me', 'b'],
          speakingIds: [],
          selfId: 'me',
        ),
        'b',
      );
    });
  });

  group('갤러리 격자', () {
    test('한 명이면 영역을 최대한 채운다', () {
      final l = galleryLayout(count: 1, width: 1000, height: 560);
      expect(l.columns, 1);
      expect(l.scrolls, isFalse);
      expect(l.tileWidth, closeTo(560 * 16 / 9, 1));
    });

    test('가로 영역에 네 명이면 2x2', () {
      final l = galleryLayout(count: 4, width: 1000, height: 560);
      expect(l.columns, 2);
      expect(l.rows, 2);
    });

    test('좁은 세로 화면에서 두 명은 위아래로 쌓는다', () {
      final l = galleryLayout(count: 2, width: 344, height: 560);
      expect(l.columns, 1);
      expect(l.rows, 2);
    });

    test('타일이 너무 작아질 만큼 많으면 스크롤 모드', () {
      final l = galleryLayout(count: 40, width: 360, height: 500);
      expect(l.scrolls, isTrue);
      expect(l.columns, 2);
      expect(l.tileWidth, greaterThanOrEqualTo(150));
    });

    test('모든 타일이 영역 안에 들어간다', () {
      for (var n = 1; n <= 12; n++) {
        final l = galleryLayout(count: n, width: 900, height: 600);
        if (l.scrolls) continue;
        expect(l.columns * l.rows, greaterThanOrEqualTo(n));
        expect(
          l.columns * l.tileWidth + (l.columns - 1) * 8,
          lessThanOrEqualTo(900.01),
        );
        expect(
          l.rows * l.tileHeight + (l.rows - 1) * 8,
          lessThanOrEqualTo(600.01),
        );
      }
    });
  });

  group('손들기 신호', () {
    test('메시지는 {type:hand, raised} JSON', () {
      expect(decodeHandMessage(encodeHandMessage(true)), isTrue);
      expect(decodeHandMessage(encodeHandMessage(false)), isFalse);
    });

    test('다른 종류·깨진 메시지는 무시(null)', () {
      expect(
        decodeHandMessage('{"type":"chat","raised":true}'.codeUnits),
        isNull,
      );
      expect(decodeHandMessage('not json'.codeUnits), isNull);
      expect(decodeHandMessage('{"type":"hand"}'.codeUnits), isNull);
      expect(decodeHandMessage('[1]'.codeUnits), isNull);
    });

    test('HandRaiseBook: 새로 든 때만 true, 내리면 지워진다', () {
      final b = HandRaiseBook();
      final t = DateTime(2026);
      expect(b.apply('a', true, t), isTrue);
      expect(b.apply('a', true, t.add(const Duration(seconds: 1))), isFalse);
      expect(b.raised['a'], t); // 처음 든 시각을 유지
      expect(b.isRaised('a'), isTrue);
      b.apply('a', false, t);
      expect(b.isRaised('a'), isFalse);
      b.apply('b', true, t);
      b.apply('c', true, t);
      b.remove('b');
      expect(b.raised.keys, ['c']);
      b.clear();
      expect(b.isEmpty, isTrue);
    });
  });

  group('통화 채팅 안읽음', () {
    final base = DateTime(2026, 1, 1, 10);
    test('기준 시각 이후 남이 보낸 일반 메시지만 센다', () {
      final msgs = [
        _msg('old', base.subtract(const Duration(minutes: 1)), sender: 'a'),
        _msg('new1', base.add(const Duration(seconds: 1)), sender: 'a'),
        _msg('mine', base.add(const Duration(seconds: 2)), sender: 'me'),
        _msg(
          'sys',
          base.add(const Duration(seconds: 3)),
          type: MessageType.system,
        ),
        _msg('new2', base.add(const Duration(seconds: 4)), sender: 'b'),
      ];
      expect(countUnreadSince(msgs, base, 'me'), 2);
    });

    test('기준이 없으면 0, 최신 시각을 구할 수 있다', () {
      final msgs = [_msg('x', base, sender: 'a')];
      expect(countUnreadSince(msgs, null, 'me'), 0);
      expect(latestMessageTime(msgs), base);
      expect(latestMessageTime(const []), isNull);
    });
  });
}
