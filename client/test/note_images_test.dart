import 'package:client/screens/project/note_markdown.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// 노트 그림 — 이 서버 파일(/files/<토큰>, 예전 /uploads/<이름>)만 내려받아 그리고, 그 밖의 주소는
// 링크로만 보여 준다(노트를 연 사람의 앱이 바깥 서버·사내 기기로 요청을 보내지 않게). 서버도 저장·
// 전달할 때 같은 규칙으로 바깥 그림을 링크로 바꾸지만, 그 전에 저장된 노트가 그대로 와도 받지 않아야 한다.
void main() {
  test('noteImageIsLocal: 이 서버 파일 경로 한 마디만', () {
    for (final ok in [
      '/files/AbC-_09xyz',
      '/files/eyJhbGciOiJIUzI1NiJ9.eyJmaWxlIjoiYS5wbmcifQ.sig',
      '/uploads/3f1c0d2e-1111-4222-8333-944445555666.png',
    ]) {
      expect(noteImageIsLocal(ok), isTrue, reason: ok);
    }
    for (final bad in [
      'http://attacker.test/t.png?n=42',
      'https://attacker.test/t.png',
      'http://192.168.0.1/admin.png',
      '//attacker.test/t.png',
      // 서버 주소 뒤에 그대로 붙이면 다른 서버가 되는 글.
      '.attacker.test/t.png',
      '@attacker.test/t.png',
      'files/a.png',
      '/files/',
      '/uploads/a/b.png',
      '/files/../x',
      r'/uploads\a.png',
      '/filesx/a',
      'javascript:alert(1)',
      'data:image/png;base64,AAAA',
      '',
    ]) {
      expect(noteImageIsLocal(bad), isFalse, reason: bad);
    }
  });

  Future<List<String>> pumpNote(WidgetTester tester, String md) async {
    final requested = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: NoteBody(
              md,
              resolveUrl: (u) {
                requested.add(u);
                return 'https://test.local$u';
              },
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return requested;
  }

  testWidgets('바깥 주소 그림은 내려받지 않고 링크 글자로 보여 준다', (tester) async {
    final requested = await pumpNote(
      tester,
      '![추적](http://attacker.test/t.png?n=42)\n'
      '## ![공유기](http://192.168.0.1/a.png)\n'
      '![](.attacker.test/x.png)',
    );
    expect(find.byType(Image), findsNothing);
    // 서버 주소를 붙여 받을 그림 주소로 만들지도 않는다.
    expect(requested, isEmpty);
    expect(find.text('🖼 추적', findRichText: true), findsOneWidget);
    expect(find.text('🖼 공유기', findRichText: true), findsOneWidget);
    expect(find.text('🖼 그림', findRichText: true), findsOneWidget);
    // 링크처럼 눌러서 열 수 있다(여는 것은 다른 링크와 같은 주소 검사를 거친다). Text.rich가
    // 바깥에 기본 글꼴 조각을 한 겹 씌우므로 글자가 든 조각을 찾아서 본다.
    final link = tester.widget<RichText>(
      find.text('🖼 추적', findRichText: true),
    );
    TextSpan? inner;
    link.text.visitChildren((s) {
      if (s is TextSpan && s.text == '🖼 추적') {
        inner = s;
        return false;
      }
      return true;
    });
    expect(inner, isNotNull);
    expect(inner!.recognizer, isNotNull);
    expect(inner!.style?.decoration, TextDecoration.underline);
  });

  testWidgets('이 서버 그림은 그대로 그리고, 섞여 있으면 이 서버 것만 받는다', (tester) async {
    final requested = await pumpNote(
      tester,
      '![도면](/files/AbC-_09)\n'
      '![밖](https://cdn.attacker.test/b.png)\n'
      '![예전](/uploads/3f1c.png)',
    );
    expect(find.byType(Image), findsNWidgets(2));
    expect(requested, ['/files/AbC-_09', '/uploads/3f1c.png']);
    expect(find.text('🖼 밖', findRichText: true), findsOneWidget);
  });
}
