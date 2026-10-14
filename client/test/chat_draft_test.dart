// 채팅 입력칸의 쓰다 만 글 — 다른 방에 갔다 와도 남도록 ChatInputBar가 RichTextEditingController.snapshot()으로
// 꺼내 RoomChatController.draft에 맡겼다가 load()로 되살린다. 그 왕복에서 글(앞뒤 공백 포함)·서식·멘션이 그대로인지 본다.
import 'package:client/models/mention.dart';
import 'package:client/widgets/rich_text_format.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('snapshot → load 하면 글·서식·멘션이 그대로 돌아온다(앞뒤 공백도 다듬지 않는다)', () {
    const text = ' @김철수 굵게 \n';
    final source = RichTextEditingController()..mentionsEnabled = true;
    source.load(
      text,
      const [TextFormatRun(6, 8, Fmt.bold)],
      mentions: const [Mention.user('a', start: 1, end: 5)],
    );

    final draft = source.snapshot();
    expect(draft.text, text);

    final restored = RichTextEditingController()..mentionsEnabled = true;
    restored.load(draft.text, draft.format, mentions: draft.mentions);
    expect(restored.text, text);
    expect(restored.selection.baseOffset, text.length); // 커서는 글 끝에.
    final runs = restored.snapshot().format!;
    expect(runs, hasLength(1));
    expect(
      (runs.single.start, runs.single.end, runs.single.flags),
      (6, 8, Fmt.bold),
    );
    final mentions = restored.mentions;
    expect(mentions, hasLength(1));
    expect(
      (mentions.single.userId, mentions.single.start, mentions.single.end),
      ('a', 1, 5),
    );
  });

  test('서식이 없으면 format은 null, 서식을 못 쓰는 입력칸(비밀 대화)도 null', () {
    final plain = RichTextEditingController()..load('그냥 글', null);
    expect(plain.snapshot().format, isNull);

    final secret = RichTextEditingController()
      ..formattingEnabled = false
      ..load('굵게', const [TextFormatRun(0, 2, Fmt.bold)]);
    expect(secret.snapshot().format, isNull);
    expect(secret.snapshot().text, '굵게');
  });
}
