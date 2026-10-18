import 'package:flutter/foundation.dart';
import '../l10n/tr.dart';

/// 앱 안을 가리키는 링크 — 노트와 업무.
///
///   tangotalk://note/<노트 id>?key=MKT-N10&title=제목&project=프로젝트명&color=%23EC4899&person=작성자
///   tangotalk://task/<업무 id>?key=MKT-1001&title=제목&project=…&color=…&person=담당자
///
/// 번호 칩을 누르면 이 주소가 복사되고, 서식 입력칸(채팅·댓글·업무 댓글)에 붙여넣으면
/// "[MKT-N10] 제목" 링크 글자로 바뀐다(RichTextEditingController). 링크를 누르면 [handler]가
/// 연다 — 메인 창은 프로젝트 창을 띄워 그 노트·업무로, 프로젝트 창은 바로 그 노트·업무로.
/// 프로젝트 이름·색·사람은 메시지의 미리보기 카드에 쓰려고 복사할 때의 값을 같이 담아 둔다.
abstract final class AppLinks {
  static const scheme = 'tangotalk';

  /// 이 창에서 앱 링크를 여는 방법(창마다 시작할 때 정한다). 없으면 눌러도 아무 일 없다.
  static void Function(String href)? handler;

  /// 프로젝트 창 안에서 "이 노트·업무를 열어 달라"는 요청 — ProjectDialog가 듣는다. 같은 것을
  /// 두 번 눌러도 다시 열리게 번호(tick)를 같이 올린다.
  static final request = ValueNotifier<({String kind, String id, int tick})?>(
    null,
  );
  static int _tick = 0;

  /// [href]를 프로젝트 창 안의 요청으로 바꾼다(노트·업무가 아니면 무시).
  static void requestOpen(String href) {
    final link = parse(href);
    if (link == null || (link.kind != 'note' && link.kind != 'task')) return;
    request.value = (kind: link.kind, id: link.id, tick: ++_tick);
  }

  static String _build(
    String kind, {
    required String id,
    String? key,
    required String title,
    String? project,
    String? color,
    String? person,
  }) => Uri(
    scheme: scheme,
    host: kind,
    path: '/$id',
    queryParameters: {
      'key': ?key,
      'title': title,
      'project': ?project,
      'color': ?color,
      'person': ?person,
    },
  ).toString();

  static String note({
    required String id,
    String? key,
    required String title,
    String? project,
    String? color,
    String? person,
  }) => _build(
    'note',
    id: id,
    key: key,
    title: title,
    project: project,
    color: color,
    person: person,
  );

  static String task({
    required String id,
    String? key,
    required String title,
    String? project,
    String? color,
    String? person,
  }) => _build(
    'task',
    id: id,
    key: key,
    title: title,
    project: project,
    color: color,
    person: person,
  );

  static bool isAppLink(String? s) => s != null && s.startsWith('$scheme://');

  static ({
    String kind,
    String id,
    String? key,
    String? title,
    String? project,
    String? color,
    String? person,
  })?
  parse(String s) {
    final uri = Uri.tryParse(s.trim());
    if (uri == null || uri.scheme != scheme || uri.pathSegments.isEmpty) {
      return null;
    }
    final q = uri.queryParameters;
    return (
      kind: uri.host,
      id: uri.pathSegments.first,
      key: q['key'],
      title: q['title'],
      project: q['project'],
      color: q['color'],
      person: q['person'],
    );
  }

  /// 입력칸에 붙여넣었을 때 보일 글 — "[MKT-N10] 제목". 앱 링크가 아니면 null.
  static String? displayText(String s) {
    final t = s.trim();
    if (t.contains(RegExp(r'\s'))) return null;
    final p = parse(t);
    if (p == null) return null;
    final title = p.title ?? (p.kind == 'task' ? tr('업무') : tr('노트'));
    return p.key == null ? title : '[${p.key}] $title';
  }

  /// [href]가 앱 링크면 [handler]로 열고 true.
  static bool open(String href) {
    if (!isAppLink(href)) return false;
    handler?.call(href);
    return true;
  }
}
