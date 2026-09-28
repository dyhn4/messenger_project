import 'package:client/screens/project/note_markdown.dart';
import 'package:client/widgets/rich_text_format.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  String roundTrip(String md) {
    final r = noteMarkdownToRich(md);
    return noteRichToMarkdown(r.text, r.runs);
  }

  test('줄 서식은 편집기에서 기호 없이, 저장하면 그대로 돌아온다', () {
    const md =
        '# 큰 제목\n## 중간\n### 작은\n> 인용 글\n- 글머리\n  - 들여쓴 글머리\n'
        '- [ ] 할 일\n- [x] 한 일\n1. 번호\n---\n| 채널 | 예산 |\n| --- | --- |\n| 네이버 | 100 |\n'
        '![배너](/uploads/a.png)\n\n보통 글';
    final r = noteMarkdownToRich(md);
    expect(r.text.contains('#'), isFalse);
    expect(r.text.contains('> '), isFalse);
    expect(r.text, contains('• 글머리'));
    expect(r.text, contains('☐ 할 일'));
    expect(r.text, contains('☑ 한 일'));
    expect(r.text, contains(noteRule));
    expect(r.text, contains('🖼 배너'));
    expect(r.text, contains('| 채널 | 예산 |')); // 표는 그대로
    expect(roundTrip(md), md);
  });

  test('글자 서식(굵게·기울임·밑줄·취소선·코드·링크·글자색)도 왕복한다', () {
    const md =
        '**굵게** <i>기울임</i> <u>밑줄</u> ~~취소~~ `코드` [링크](https://a.com) '
        '<span style="color:#E53935">빨강</span> **<i>둘 다</i>**';
    final r = noteMarkdownToRich(md);
    expect(r.text, '굵게 기울임 밑줄 취소 코드 링크 빨강 둘 다');
    expect(roundTrip(md), md);
    // 예전 노트의 *기울임*도 읽는다.
    final old = noteMarkdownToRich('앞 *기울임* 뒤');
    expect(old.text, '앞 기울임 뒤');
    expect(old.runs.single.flags & Fmt.italic, Fmt.italic);
  });

  test('편집기에서 제목·색을 넣으면 마크다운으로 저장된다', () {
    final c = RichTextEditingController();
    c.load('제목\n본문', null);
    c.selection = const TextSelection.collapsed(offset: 1);
    c.toggleHeading(2);
    c.selection = const TextSelection(baseOffset: 3, extentOffset: 5);
    c.applyColor(0x1E88E5);
    final f = c.formatted();
    expect(
      noteRichToMarkdown(f.text, f.format),
      '## 제목\n<span style="color:#1E88E5">본문</span>',
    );
  });

  test('예전에 저장된 링크 글의 짝 없는 "["도 예전처럼 링크로 읽는다', () {
    const url = 'https://x.com';
    // 글 | 서식 구간(시작-끝:서식:주소) 목록.
    String read(String md) {
      final r = noteMarkdownToRich(md);
      final runs = [
        for (final x in r.runs) '${x.start}-${x.end}:${x.flags}:${x.href}',
      ];
      return '${r.text} | ${runs.join(', ')}';
    }

    expect(read('배열 [a[0]($url) 끝'), '배열 a[0 끝 | 3-6:0:$url');
    expect(read('[a[b]($url)'), 'a[b | 0-3:0:$url');
    expect(read('[`a[0`]($url)'), 'a[0 | 0-3:${Fmt.code}:$url');
    // 다시 저장하면 짝 없는 "["는 전각이 되어, 앞뒤 글과 상관없이 같은 링크로 읽힌다.
    expect(roundTrip('배열 [a[0]($url) 끝'), '배열 [a［0]($url) 끝');
    expect(read('배열 [a［0]($url) 끝'), '배열 a［0 끝 | 3-6:0:$url');
    // 링크를 대괄호로 감싼 글은 안쪽만 링크 — 짝 맞는 대괄호 링크 글도 그대로.
    expect(read('[참고 [TA-1 제목]($url)]'), '[참고 TA-1 제목] | 4-11:0:$url');
    expect(roundTrip('[참고 [TA-1 제목]($url)]'), '[참고 [TA-1 제목]($url)]');
    expect(read('[[긴급] 점검]($url)'), '[긴급] 점검 | 0-7:0:$url');
    expect(read('[x] 할 일 [링크]($url)'), '[x] 할 일 링크 | 8-10:0:$url');
  });

  test('미리보기에서는 기호가 빠진다', () {
    expect(notePlainPreview('# 제목\n**굵게** 글\n- 항목'), '제목 굵게 글 • 항목');
  });

  testWidgets('본문 그리기: 표·체크·그림·제목이 오류 없이 그려진다', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: NoteBody(
              '# 제목\n- [x] 끝\n| a | b |\n| --- | --- |\n| 1 | 2 |\n'
              '![그림](/files/x)\n**굵게**',
              resolveUrl: (u) => 'https://test.local$u',
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(Table), findsOneWidget);
    expect(find.byIcon(Icons.check_box), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('제목', findRichText: true), findsOneWidget);
  });
}
