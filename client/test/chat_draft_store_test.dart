// 대화방 임시 저장(chat_draft_store.dart) — 앱을 껐다 켜도 남고(사람별로 이 기기에), 비밀 대화는 메모리에만, 오래된 것은 버리고,
// 방 목록의 ✏️ 표시를 위해 글이 생기거나 없어질 때만(한 박자 뒤에) 알린다.
import 'dart:convert';

import 'package:client/models/mention.dart';
import 'package:client/models/text_format.dart';
import 'package:client/services/chat_draft_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

ChatDraft _draft(
  String text, {
  List<TextFormatRun>? format,
  List<Mention> mentions = const [],
}) => (text: text, format: format, mentions: mentions);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('저장하면 같은 사람이 다시 로그인했을 때 글·서식·멘션이 돌아온다', () async {
    final prefs = await SharedPreferences.getInstance();
    final first = ChatDraftStore();
    await first.load(prefs, 'u1');
    first.put(
      'r1',
      _draft(
        '@김철수 굵게',
        format: const [TextFormatRun(5, 7, Fmt.bold)],
        mentions: const [Mention.user('a', start: 0, end: 4)],
      ),
    );
    await first.flush();

    final again = ChatDraftStore();
    await again.load(prefs, 'u1');
    final d = again.get('r1')!;
    expect(d.text, '@김철수 굵게');
    expect(d.format!.single.flags, Fmt.bold);
    expect(d.mentions.single.userId, 'a');
    expect(again.has('r1'), isTrue);

    // 다른 사람에게는 보이지 않는다.
    final other = ChatDraftStore();
    await other.load(prefs, 'u2');
    expect(other.has('r1'), isFalse);
  });

  test('비우면 지워지고, 비밀 대화(persist: false)는 저장소에 쓰지 않는다', () async {
    final prefs = await SharedPreferences.getInstance();
    final store = ChatDraftStore();
    await store.load(prefs, 'u1');
    store.put('r1', _draft('보낼 글'));
    store.put('secret', _draft('비밀 글'), persist: false);
    await store.flush();
    final saved = jsonDecode(prefs.getString(ChatDraftStore.prefsKey('u1'))!)
        as Map;
    expect(saved.keys, ['r1']);
    expect(store.get('secret')!.text, '비밀 글', reason: '메모리에는 남는다');

    store.put('r1', _draft('   '));
    expect(store.has('r1'), isFalse);
    await store.flush();
    expect(prefs.getString(ChatDraftStore.prefsKey('u1')), isNull);
  });

  test('30일 지난 글과 망가진 값은 불러오지 않는다', () async {
    final old = DateTime.now().subtract(const Duration(days: 31));
    SharedPreferences.setMockInitialValues({
      ChatDraftStore.prefsKey('u1'): jsonEncode({
        'old': {'text': '옛 글', 'savedAt': old.millisecondsSinceEpoch},
        'new': {
          'text': '새 글',
          'savedAt': DateTime.now().millisecondsSinceEpoch,
        },
        'bad': {'text': 3},
      }),
    });
    final store = ChatDraftStore();
    await store.load(await SharedPreferences.getInstance(), 'u1');
    expect(store.has('old'), isFalse);
    expect(store.has('bad'), isFalse);
    expect(store.get('new')!.text, '새 글');
  });

  test('글이 생기거나 없어질 때만, 한 박자 뒤에 한 번 알린다(글자마다 알리지 않는다)', () async {
    var notified = 0;
    final store = ChatDraftStore(onChanged: () => notified++);
    store.put('r1', _draft('가'));
    expect(notified, 0, reason: '바로 부르지 않는다(입력칸 dispose 중일 수 있다)');
    await Future<void>.delayed(Duration.zero);
    expect(notified, 1);
    store.put('r1', _draft('가나'));
    store.put('r1', _draft('가나다'));
    await Future<void>.delayed(Duration.zero);
    expect(notified, 1, reason: '이미 있던 방의 글이 바뀐 것은 알리지 않는다');
    store.put('r1', null);
    store.put('r2', _draft('다른 방'));
    await Future<void>.delayed(Duration.zero);
    expect(notified, 2, reason: '같은 순간 여러 방이 바뀌어도 한 번');
  });

  test('로그아웃하면 메모리에서만 비우고, 남은 저장은 먼저 마친다', () async {
    final prefs = await SharedPreferences.getInstance();
    final store = ChatDraftStore();
    await store.load(prefs, 'u1');
    store.put('r1', _draft('쓰던 글'));
    await store.reset();
    expect(store.has('r1'), isFalse);
    final again = ChatDraftStore();
    await again.load(prefs, 'u1');
    expect(again.get('r1')!.text, '쓰던 글');
  });
}
