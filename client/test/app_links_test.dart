import 'package:client/models/message.dart';
import 'package:client/services/app_links.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:client/widgets/message_bubble.dart';
import 'package:client/widgets/rich_text_format.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final link = AppLinks.note(
    id: 'n10',
    key: 'MKT-N10',
    title: '제목이다',
    project: '신제품 런칭 캠페인',
    color: '#EC4899',
    person: '송병근',
  );

  test('노트 링크를 만들고 읽는다', () {
    expect(link, startsWith('tangotalk://note/n10?'));
    final p = AppLinks.parse(link)!;
    expect(p.kind, 'note');
    expect(p.id, 'n10');
    expect(p.key, 'MKT-N10');
    expect(p.title, '제목이다');
    expect(AppLinks.displayText(link), '[MKT-N10] 제목이다');
    expect(AppLinks.displayText('https://a.com'), isNull);
    expect(AppLinks.displayText('앞 $link'), isNull); // 글 사이에 섞이면 그대로
  });

  test('입력칸에 붙여넣으면 "[키] 제목" 링크 글자가 되고, 보내면 링크가 걸린 채로 간다', () {
    final c = RichTextEditingController();
    c.value = TextEditingValue(
      text: link,
      selection: TextSelection.collapsed(offset: link.length),
    );
    expect(c.text, '[MKT-N10] 제목이다');
    final f = c.formatted();
    expect(f.text, '[MKT-N10] 제목이다');
    expect(f.format!.single.href, link);
    expect(f.format!.single.start, 0);
    expect(f.format!.single.end, '[MKT-N10] 제목이다'.length);

    // 이어서 치는 글자는 링크가 아니다.
    c.value = TextEditingValue(
      text: '${c.text} 확인',
      selection: TextSelection.collapsed(offset: c.text.length + 3),
    );
    expect(c.formatted().format!.single.end, '[MKT-N10] 제목이다'.length);

    // 서식을 못 쓰는 입력칸(비밀 대화)은 주소 그대로 둔다.
    final plain = RichTextEditingController()..formattingEnabled = false;
    plain.value = TextEditingValue(
      text: link,
      selection: TextSelection.collapsed(offset: link.length),
    );
    expect(plain.text, link);
  });

  testWidgets('메시지·댓글의 노트 링크를 누르면 앱 안에서 연다', (tester) async {
    String? opened;
    AppLinks.handler = (href) => opened = href;
    addTearDown(() => AppLinks.handler = null);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FormattedText(
            '[MKT-N10] 제목이다',
            format: [TextFormatRun(0, 15, 0, link)],
          ),
        ),
      ),
    );
    await tester.tapAt(
      tester.getTopLeft(find.byType(FormattedText)) + const Offset(10, 8),
    );
    await tester.pump();
    expect(opened, link);
  });

  testWidgets('노트 링크를 보낸 메시지는 링크 글자 아래에 미리보기 카드가 붙는다', (tester) async {
    String? opened;
    AppLinks.handler = (href) => opened = href;
    addTearDown(() => AppLinks.handler = null);
    final session = Session(
      notifications: NotificationService(),
      settings: AppSettings(),
    );
    final message = Message(
      id: 'm1',
      roomId: 'r1',
      senderId: 'u1',
      senderName: '송병근',
      type: MessageType.text,
      text: '[MKT-N10] 제목이다',
      textFormat: [TextFormatRun(0, 15, 0, link)],
      createdAt: DateTime(2026, 9, 27, 12, 12),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MessageBubble(
              session: session,
              message: message,
              resolveUrl: (u) => u,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    // 카드: 프로젝트 색 점 · 프로젝트 이름 / 노트 · 작성자.
    expect(find.text('신제품 런칭 캠페인'), findsOneWidget);
    expect(find.text('노트  ·  작성자 송병근'), findsOneWidget);
    await tester.tap(find.text('신제품 런칭 캠페인'));
    await tester.pump();
    expect(opened, link);
  });

  test('업무 링크 — "[MKT-1001] 제목", 프로젝트 창 요청은 종류별로', () {
    final task = AppLinks.task(
      id: 't1',
      key: 'MKT-1001',
      title: '배너 제작',
      project: '신제품 런칭 캠페인',
      person: 'Mina',
    );
    expect(AppLinks.displayText(task), '[MKT-1001] 배너 제작');
    AppLinks.requestOpen(task);
    expect(AppLinks.request.value?.kind, 'task');
    expect(AppLinks.request.value?.id, 't1');
    AppLinks.requestOpen(link);
    expect(AppLinks.request.value?.kind, 'note');
  });

  test('Windows처럼 조합 영역이 빈 구간(0,0)으로 와도 붙여넣으면 링크 글자로 바뀐다', () {
    final c = RichTextEditingController();
    c.value = TextEditingValue(
      text: link,
      selection: TextSelection.collapsed(offset: link.length),
      composing: const TextRange.collapsed(0),
    );
    expect(c.text, '[MKT-N10] 제목이다');
  });
}
