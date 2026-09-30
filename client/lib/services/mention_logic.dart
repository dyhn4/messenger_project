import '../models/app_user.dart';
import '../models/mention.dart';
import '../models/room.dart';

// 멘션 구간 추적·자동완성 후보 고르기 — 화면(입력창 컨트롤러, 자동완성 패널)에서 떼어 낸 순수 함수들.
// 글이 바뀌면 멘션 구간이 어떻게 따라가고(밀리고, 어긋나면 풀리고), "@" 뒤 글자로 누구를 보여 줄지를
// 여기서 정하므로 위젯 없이 단위 시험을 한다(test/mention_logic_test.dart).

/// 멘션을 쓸 수 있는 방인지 — 비밀 대화는 서버가 본문을 몰라서 멘션을 지원하지 않는다.
bool roomAllowsMention(Room room) => !room.isSecret;

/// `@all`을 쓸 수 있는 방인지 — 토픽·그룹채팅만(1:1, 나와의 대화, 비밀 대화는 안 된다).
bool roomAllowsMentionAll(Room room) =>
    !room.isSecret &&
    !room.isSelf &&
    (room.type == RoomType.topic || room.type == RoomType.group);

/// 글의 [at, at+removed)가 [inserted] 글자로 바뀌었을 때 멘션 구간을 따라 옮긴다.
///   - 구간 앞쪽에서 바뀌면 그만큼 밀고, 뒤쪽에서 바뀌면 그대로 둔다.
///   - 구간 끝에 이어서 치거나 구간 바로 앞에 끼우는 건 구간을 건드리지 않는다.
///   - 구간 안을 지우거나 고치거나 그 한가운데 끼우면 그 멘션은 풀린다(잔디처럼 이름을 지우면 멘션이 풀림).
List<Mention> remapMentionsForEdit(
  List<Mention> mentions,
  int at,
  int removed,
  int inserted,
) {
  final editEnd = at + removed;
  final delta = inserted - removed;
  final out = <Mention>[];
  for (final m in mentions) {
    if (m.end <= at) {
      out.add(m);
    } else if (m.start >= editEnd) {
      out.add(delta == 0 ? m : m.shifted(delta));
    }
    // 그 밖(구간과 겹침)은 풀린다.
  }
  return out;
}

/// [start, end) 안에 온전히 들어 있는 멘션만 골라 [start]를 0으로 옮긴다 — 보낼 글의 앞뒤 공백을 떼면서
/// 위치가 같이 당겨지게(RichTextEditingController.formatted와 같은 기준).
List<Mention> sliceMentions(List<Mention> mentions, int start, int end) => [
  for (final m in mentions)
    if (m.start >= start && m.end <= end) m.shifted(-start),
];

/// 보내기 전에 한 번 더 거른다 — 글 길이 밖이거나 '@'로 시작하지 않는(어긋난) 것, 겹치는 것,
/// 같은 사람의 두 번째 멘션(서버도 하나로 합친다), 허용되지 않는 @all, 자기 자신, 50개 초과는 뺀다.
List<Mention> sanitizeMentions(
  List<Mention> mentions,
  String text, {
  bool allowAll = true,
  String? selfUserId,
  int max = 50,
}) {
  final sorted = [...mentions]..sort((a, b) => a.start.compareTo(b.start));
  final out = <Mention>[];
  final seenUsers = <String>{};
  var sawAll = false;
  var lastEnd = 0;
  for (final m in sorted) {
    if (out.length >= max) break;
    if (m.start < lastEnd || m.end > text.length || m.end <= m.start) continue;
    if (text.codeUnitAt(m.start) != 0x40) continue; // '@'
    if (m.isAll) {
      if (!allowAll || sawAll) continue;
      sawAll = true;
    } else {
      final id = m.userId;
      if (id == null || id == selfUserId || !seenUsers.add(id)) continue;
    }
    out.add(m);
    lastEnd = m.end;
  }
  return out;
}

/// 입력칸에서 지금 "@이름"을 치고 있는 자리 — [start]는 '@'의 위치, [query]는 '@'와 커서 사이 글자.
class MentionQuery {
  final int start;
  final String query;
  const MentionQuery(this.start, this.query);

  @override
  bool operator ==(Object other) =>
      other is MentionQuery && other.start == start && other.query == query;

  @override
  int get hashCode => Object.hash(start, query);

  @override
  String toString() => 'MentionQuery($start, "$query")';
}

bool _isSpace(int c) =>
    c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 || c == 0x3000;

/// "@"를 치고 있는 중인지 본다. 커서 앞으로 공백 없이 이어진 글자 끝에 '@'가 있고 그 앞이 글 처음이거나
/// 공백일 때만이다(이메일 "a@b"는 해당 없음). 이미 멘션이 된 글자([existing]) 안이면 아니다.
/// [maxQuery]보다 길게 이어 치면 찾는 게 아니라 그냥 글로 본다.
MentionQuery? activeMentionQuery(
  String text,
  int caret, {
  List<Mention> existing = const [],
  int maxQuery = 30,
}) {
  if (caret <= 0 || caret > text.length) return null;
  var i = caret - 1;
  while (i >= 0) {
    final c = text.codeUnitAt(i);
    if (c == 0x40) break; // '@'
    if (_isSpace(c) || caret - i > maxQuery + 1) return null;
    i--;
  }
  if (i < 0) return null;
  if (i > 0 && !_isSpace(text.codeUnitAt(i - 1))) return null;
  for (final m in existing) {
    if (i >= m.start && i < m.end) return null;
  }
  return MentionQuery(i, text.substring(i + 1, caret));
}

/// 자동완성 목록의 한 줄 — 사람([user]) 또는 @all.
class MentionCandidate {
  final MentionType type;
  final AppUser? user;
  const MentionCandidate.user(AppUser this.user) : type = MentionType.user;
  const MentionCandidate.all() : type = MentionType.all, user = null;

  bool get isAll => type == MentionType.all;

  /// 본문에 들어가는 글자('@' 제외) — 사람은 이름, @all은 "all".
  String get label => isAll ? 'all' : user!.name;

  String? get userId => user?.id;
}

/// "@" 뒤에 [query]를 친 사람에게 보여 줄 후보 — 이름·아이디에 [query]가 들어 있는 방 멤버(나 제외)를
/// 이름이 [query]로 시작하는 순으로. [allowAll]이면 @all이 맨 앞에 붙는다(query가 비었거나 all/전체/모두를 치는 중일 때).
List<MentionCandidate> mentionCandidates({
  required List<AppUser> members,
  required String? myUserId,
  required bool allowAll,
  required String query,
  int limit = 8,
}) {
  final q = query.trim().toLowerCase();
  final out = <MentionCandidate>[];
  if (allowAll &&
      (q.isEmpty ||
          'all'.startsWith(q) ||
          '전체'.startsWith(q) ||
          '모두'.startsWith(q))) {
    out.add(const MentionCandidate.all());
  }
  final matched = <(int, AppUser)>[];
  for (final u in members) {
    if (u.id == myUserId) continue;
    final name = u.name.toLowerCase();
    final username = u.username.toLowerCase();
    int rank;
    if (q.isEmpty) {
      rank = 2;
    } else if (name.startsWith(q)) {
      rank = 0;
    } else if (username.startsWith(q)) {
      rank = 1;
    } else if (name.contains(q) || username.contains(q)) {
      rank = 2;
    } else {
      continue;
    }
    matched.add((rank, u));
  }
  matched.sort((a, b) {
    final r = a.$1.compareTo(b.$1);
    return r != 0 ? r : a.$2.name.compareTo(b.$2.name);
  });
  for (final (_, u) in matched) {
    if (out.length >= limit) break;
    out.add(MentionCandidate.user(u));
  }
  return out;
}
