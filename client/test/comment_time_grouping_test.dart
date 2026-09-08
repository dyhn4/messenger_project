import 'package:client/models/comment.dart';
import 'package:client/widgets/message_comments_card.dart';
import 'package:flutter_test/flutter_test.dart';

/// 댓글 시간 묶기 규칙 — 같은 사람이 같은 분(分)에 연달아 단 댓글은 그 묶음의 마지막 댓글에만
/// 시간을 보여준다(채팅 메시지와 동일한 규칙, 인라인 댓글 카드와 스레드 패널이 공유한다).
void main() {
  Comment at(String senderId, String time) => Comment(
    id: '$senderId-$time',
    messageId: 'm1',
    roomId: 'r1',
    senderId: senderId,
    senderName: senderId,
    createdAt: DateTime.parse(time),
  );

  test('마지막 댓글은 항상 시간을 보여준다', () {
    final comments = [at('a', '2026-09-08 10:00:00')];
    expect(showCommentTimeAt(comments, 0), isTrue);
  });

  test('같은 사람이 같은 분에 연달아 달면 마지막 댓글에만 보여준다', () {
    final comments = [
      at('a', '2026-09-08 10:00:05'),
      at('a', '2026-09-08 10:00:30'),
      at('a', '2026-09-08 10:00:59'),
    ];
    expect(showCommentTimeAt(comments, 0), isFalse);
    expect(showCommentTimeAt(comments, 1), isFalse);
    expect(showCommentTimeAt(comments, 2), isTrue);
  });

  test('분이 바뀌면 그 앞에서도 보여준다', () {
    final comments = [
      at('a', '2026-09-08 10:00:59'),
      at('a', '2026-09-08 10:01:00'),
    ];
    expect(showCommentTimeAt(comments, 0), isTrue);
  });

  test('보낸 사람이 바뀌면 같은 분이어도 그 앞에서 보여준다', () {
    final comments = [
      at('a', '2026-09-08 10:00:05'),
      at('b', '2026-09-08 10:00:10'),
      at('a', '2026-09-08 10:00:20'),
    ];
    expect(showCommentTimeAt(comments, 0), isTrue);
    expect(showCommentTimeAt(comments, 1), isTrue);
  });

  test('시/일이 달라 분 숫자만 같은 경우도 그 앞에서 보여준다', () {
    final comments = [
      at('a', '2026-09-08 10:05:00'),
      at('a', '2026-09-08 11:05:00'),
      at('a', '2026-09-09 11:05:00'),
    ];
    expect(showCommentTimeAt(comments, 0), isTrue);
    expect(showCommentTimeAt(comments, 1), isTrue);
  });
}
