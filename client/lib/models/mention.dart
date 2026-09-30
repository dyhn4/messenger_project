// 멘션 — 본문(text)은 평문 그대로 두고 "어느 구간이 누구를 가리키는지"만 따로 든다(글자 서식
// textFormat과 같은 방식). 서버 규약(CONTRACT_NOTIF.md):
//
//   [ { "type": "user", "userId": "<uuid>", "s": 0, "e": 4 }, { "type": "all", "s": 10, "e": 14 } ]
//
// s·e는 본문의 UTF-16 위치(e는 포함 안 함)이고, 구간에는 '@'까지 들어간다("@홍길동").
// 나중에 department 같은 종류가 생겨도 되게 type으로 구분하지만, 지금은 user | all만 쓴다.

enum MentionType { user, all }

/// 멘션 한 건 — [type]이 user면 [userId]가 있다. [start, end)는 본문 안 위치.
class Mention {
  final MentionType type;
  final String? userId;
  final int start;
  final int end;

  const Mention({
    required this.type,
    this.userId,
    required this.start,
    required this.end,
  });

  const Mention.user(
    String this.userId, {
    required this.start,
    required this.end,
  }) : type = MentionType.user;

  const Mention.all({required this.start, required this.end})
    : type = MentionType.all,
      userId = null;

  bool get isAll => type == MentionType.all;

  int get length => end - start;

  Mention shifted(int delta) => Mention(
    type: type,
    userId: userId,
    start: start + delta,
    end: end + delta,
  );

  Map<String, dynamic> toJson() => {
    'type': type == MentionType.all ? 'all' : 'user',
    if (userId != null) 'userId': userId,
    's': start,
    'e': end,
  };

  /// 서버가 보낸 한 건을 읽는다. 모르는 종류(나중에 생길 department 등)나 모양이 틀린 건 null —
  /// 목록에서 그 항목만 빠지고 나머지는 그대로 보인다.
  static Mention? fromJson(Object? json) {
    if (json is! Map) return null;
    final s = json['s'], e = json['e'];
    if (s is! num || e is! num) return null;
    final start = s.toInt(), end = e.toInt();
    if (start < 0 || end <= start) return null;
    switch (json['type']) {
      case 'all':
        return Mention(type: MentionType.all, start: start, end: end);
      case 'user':
        final id = json['userId'];
        if (id is! String || id.isEmpty) return null;
        return Mention(
          type: MentionType.user,
          userId: id,
          start: start,
          end: end,
        );
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is Mention &&
      other.type == type &&
      other.userId == userId &&
      other.start == start &&
      other.end == end;

  @override
  int get hashCode => Object.hash(type, userId, start, end);

  @override
  String toString() => 'Mention($type, $userId, $start-$end)';
}

/// 서버에서 받은 mentions(JSON 배열)를 읽는다. 없거나 모양이 틀리면 빈 목록.
List<Mention> parseMentions(Object? json) {
  if (json is! List) return <Mention>[];
  final list = <Mention>[for (final m in json) ?Mention.fromJson(m)];
  list.sort((a, b) => a.start.compareTo(b.start));
  return list;
}

/// 보낼 JSON — 비어 있으면 null(필드를 아예 안 보낸다).
List<Map<String, dynamic>>? mentionsToJson(List<Mention>? mentions) =>
    mentions == null || mentions.isEmpty
    ? null
    : [for (final m in mentions) m.toJson()];

/// 이 글에서 [userId]를 가리키는 멘션이 있는지. [includeAll]이면 @all도 "나를 멘션"으로 본다.
bool mentionsUser(
  List<Mention> mentions,
  String? userId, {
  bool includeAll = true,
}) {
  if (userId == null) return false;
  for (final m in mentions) {
    if (m.type == MentionType.user && m.userId == userId) return true;
    if (includeAll && m.isAll) return true;
  }
  return false;
}
