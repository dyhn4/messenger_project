/// 메시지 공감(이모지 반응) — 카카오톡 공감처럼 한 사람이 한 메시지에 하나만 고른다(server/src/reactionRules.js).
///
/// 고를 수 있는 이모지와 그 순서 — 서버의 REACTION_EMOJIS와 글자 하나까지 같아야 한다(test/message_reactions_test.dart가 서버 파일을
/// 읽어 맞춰 본다). 앞의 [quickReactionCount]개는 고르는 줄에 바로 보이고, 나머지는 "+"를 눌러 펼친다. 말풍선 아래 줄도 이 순서다.
const reactionEmojis = [
  '👍', '❤️', '😂', '😮', '😢', '✅', //
  '👏', '🙏', '🎉', '🔥', '💯', '👀', '🙌', '💪', //
  '🤝', '👌', '✌️', '🙆', '🙇', '🤔', '😊', '😍', //
  '🥰', '😆', '😅', '🤣', '😭', '😱', '😡', '🥺', //
  '😎', '🤗', '😴', '🤯', '🥳', '👎', '❌', '⭕', //
  '❗', '❓', '⚠️', '💡', '📌', '⏰', '☕', '🍀', //
  '⭐', '🚀',
];

/// 고르는 줄에 바로 보이는 공감 수 — 예전부터 있던 여섯 개(서버 QUICK_REACTION_COUNT).
const quickReactionCount = 6;

/// 이모지 하나에 공감한 사람들 — [userIds]는 누른 순서.
class MessageReaction {
  final String emoji;
  final List<String> userIds;

  const MessageReaction({required this.emoji, required this.userIds});

  int get count => userIds.length;

  static MessageReaction? fromJson(Object? json) {
    if (json is! Map) return null;
    final emoji = json['emoji'];
    final users = json['userIds'];
    if (emoji is! String || users is! List) return null;
    final ids = users.whereType<String>().toList();
    if (ids.isEmpty) return null;
    return MessageReaction(emoji: emoji, userIds: ids);
  }
}

/// 서버가 준 공감 목록 — 키가 없거나 모양이 틀리면 빈 목록.
List<MessageReaction> parseReactions(Object? json) {
  if (json is! List) return const [];
  return [for (final item in json) ?MessageReaction.fromJson(item)];
}

/// [reactions]에서 [userId]가 고른 이모지 — 없으면 null.
String? myReaction(List<MessageReaction> reactions, String? userId) {
  if (userId == null) return null;
  for (final r in reactions) {
    if (r.userIds.contains(userId)) return r.emoji;
  }
  return null;
}

/// [userId]의 공감을 [emoji]로 바꾼(null이면 뺀) 목록 — 서버 답을 기다리지 않고 화면에 먼저 보일 때 쓴다(서버 규칙과 같이:
/// 한 사람 하나, 정해 둔 순서, 바꾼 사람은 그 이모지의 맨 뒤).
List<MessageReaction> reactionsWith(
  List<MessageReaction> reactions,
  String userId,
  String? emoji,
) {
  final byEmoji = <String, List<String>>{
    for (final r in reactions)
      r.emoji: [
        for (final id in r.userIds)
          if (id != userId) id,
      ],
  };
  if (emoji != null) (byEmoji[emoji] ??= []).add(userId);
  return [
    for (final e in reactionEmojis)
      if (byEmoji[e]?.isNotEmpty ?? false)
        MessageReaction(emoji: e, userIds: byEmoji[e]!),
  ];
}

/// 두 목록이 같은지(이모지·사람·순서까지).
bool sameReactions(List<MessageReaction> a, List<MessageReaction> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i].emoji != b[i].emoji) return false;
    final x = a[i].userIds;
    final y = b[i].userIds;
    if (x.length != y.length) return false;
    for (var j = 0; j < x.length; j++) {
      if (x[j] != y[j]) return false;
    }
  }
  return true;
}
