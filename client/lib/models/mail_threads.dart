// 메일 목록을 대화(스레드)로 묶기 — 서버가 목록 줄마다 실어 주는 Message-ID·In-Reply-To·References(webmailRules.js messageSummary,
// localMailRules.js localSummaryOf)로, 지금 불러온 목록 안에서 서로 이어진 메일끼리 하나로 묶는다. 같은 메시지 id를 하나라도 함께
// 가리키면 같은 대화다(맨 처음 메일이 목록에 없어도 같은 References로 이어진다). 제목만 같은 메일은 묶지 않는다(엉뚱한 메일이
// 섞이지 않게). 폴더 안에서만 묶는다 — 보낸편지함의 내 답장은 그 폴더에서 따로 보인다.

import 'mail.dart';

/// 대화 하나 — [messages]는 목록 차례(새것부터). 맨 앞이 대표로 보이는 메일.
class MailThread {
  final List<MailSummary> messages;
  const MailThread(this.messages);

  MailSummary get latest => messages.first;
  int get count => messages.length;
  bool get unread => messages.any((m) => !m.seen);
  bool get flagged => messages.any((m) => m.flagged);
  bool get hasAttachments => messages.any((m) => m.hasAttachments);
  List<int> get uids => [for (final m in messages) m.uid];

  /// 화면에서 대화를 가리키는 열쇠(펼침 상태 — 새 메일이 와도 그대로이게 가장 오래된 메일로).
  String get key => 'thread-${messages.last.uid}';
}

/// [list](새것부터)를 대화로 묶는다 — 대화의 차례는 그 안의 가장 새 메일 차례.
List<MailThread> groupMailThreads(List<MailSummary> list) {
  final parent = List<int>.generate(list.length, (i) => i);
  int find(int i) {
    while (parent[i] != i) {
      parent[i] = parent[parent[i]];
      i = parent[i];
    }
    return i;
  }

  void union(int a, int b) {
    final ra = find(a), rb = find(b);
    if (ra == rb) return;
    // 앞(새) 쪽을 대표로 — 대화의 차례가 가장 새 메일을 따르게.
    if (ra < rb) {
      parent[rb] = ra;
    } else {
      parent[ra] = rb;
    }
  }

  final owner = <String, int>{};
  for (var i = 0; i < list.length; i++) {
    final m = list[i];
    for (final id in [?m.messageId, ?m.inReplyTo, ...m.references]) {
      if (id.isEmpty) continue;
      final seen = owner[id];
      if (seen == null) {
        owner[id] = i;
      } else {
        union(i, seen);
      }
    }
  }
  final groups = <int, List<MailSummary>>{};
  final order = <int>[];
  for (var i = 0; i < list.length; i++) {
    final root = find(i);
    final g = groups[root];
    if (g == null) {
      groups[root] = [list[i]];
      order.add(root);
    } else {
      g.add(list[i]);
    }
  }
  return [for (final root in order) MailThread(groups[root]!)];
}
