// 초보자용 도움말 "메신저 이용법"의 로그인·회원가입 그림을 찍는다(나머지 그림은
// messenger_capture_test.dart).
//
// 다시 찍기(client 폴더에서):
//   flutter test tool/guide_capture/messenger_login_capture_test.dart
// 결과: ../server/guide/images/messenger-login.png, messenger-signup.png
//
// 이 두 장만 파일을 나눈 이유: 로그인 카드(login_screen.dart)는 시스템 다크 모드에서도 글자가
// 흐려지지 않게 카드 안쪽에 새 ThemeData를 씌우는데, 그 테마에는 앱 테마의 한글 대체 글꼴
// 설정이 없다. 실제 Windows는 운영체제가 한글을 맑은 고딕으로 대신 그려 주지만 테스트 엔진은
// 그런 대체가 없어서 한글이 네모(□)로 찍힌다. 그래서 이 파일(= 별도 테스트 프로세스)에서만
// 기본 글꼴 이름('Segoe UI')에 맑은 고딕을 먼저 등록해 둔다 — 같은 이름의 글꼴 중 먼저
// 등록된 것이 쓰이므로 카드 안 글자가 맑은 고딕으로 그려진다(영문도 맑은 고딕 모양이 된다).
//
// 글꼴 이름이 아예 없는 글자(버튼 글자 크기만 따로 준 '중복 확인')는 테스트 엔진이 이름으로
// 글꼴을 찾지 않고 곧장 시험용 글꼴로 그려서 이 방법도 안 통한다 — 그 버튼 하나만 같은 모양의
// 버튼을 글꼴 이름을 붙여 그 자리에 덮어 그린다(_CheckButtonLookalike).
import 'dart:io';

import 'package:client/screens/login_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'guide_capture.dart';

/// 로그인 카드(가로 420)의 바깥 상자.
Finder get loginCard => find.byWidgetPredicate(
  (w) => w is ConstrainedBox && w.constraints.maxWidth == 420,
);

/// [text]가 적힌 버튼 전체.
Finder buttonWith(String text) => find
    .ancestor(
      of: find.text(text),
      matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
    )
    .first;

/// 떠 있는 제목(라벨)이 테두리 위에 걸친 입력칸 — 라벨을 가리지 않게 상자 위쪽만 더 띄운다
/// (입력칸끼리 12px 간격이라 아래쪽은 바짝 붙인다).
GuideCallout fieldCallout(
  WidgetTester tester,
  Finder field,
  int number, {
  CalloutBadge badge = CalloutBadge.left,
}) {
  final r = tester.getRect(field);
  return GuideCallout.rect(
    Rect.fromLTRB(r.left - 4, r.top - 9, r.right + 4, r.bottom + 1),
    number: number,
    badge: badge,
  );
}

/// login_screen.dart의 "중복 확인" 버튼과 같은 모양(초록 배경·흰 글씨·가로 여백 14·높이
/// 36·글자 13)에 글꼴 이름만 붙인 버튼 — 위 설명처럼 원래 버튼 위에 덮어 그린다.
class _CheckButtonLookalike extends StatelessWidget {
  const _CheckButtonLookalike();

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Theme(
        data: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
          useMaterial3: true,
        ),
        child: Material(
          type: MaterialType.transparency,
          child: FilledButton(
            onPressed: () {},
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF6FCF97),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              minimumSize: const Size(0, 36),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              textStyle: const TextStyle(fontSize: 13, fontFamily: 'Segoe UI'),
            ),
            child: const Text('중복 확인'),
          ),
        ),
      ),
    );
  }
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final fonts = '${Platform.environment['WINDIR'] ?? 'C:/Windows'}/Fonts';
    final loader = FontLoader('Segoe UI');
    for (final name in ['malgun.ttf', 'malgunbd.ttf']) {
      loader.addFont(
        Future.value(
          ByteData.sublistView(File('$fonts/$name').readAsBytesSync()),
        ),
      );
    }
    await loader.load();
  });

  guideCapture('로그인', const GuideSurface(Size(620, 640)), (tester) async {
    final session = guideSession(name: '김민지', username: 'minji.kim');
    await pumpGuideApp(tester, LoginScreen(session: session));
    final id = find.widgetWithText(TextField, '아이디');
    final pw = find.widgetWithText(TextField, '비밀번호');
    await tester.enterText(id, 'minji.kim');
    await tester.enterText(pw, 'tango1234');
    FocusManager.instance.primaryFocus?.unfocus();
    await settleGuide(tester);
    await saveGuideShot(
      tester,
      'messenger-login',
      callouts: [
        fieldCallout(tester, id, 1),
        fieldCallout(tester, pw, 2),
        GuideCallout.box(
          find.text('로그인 상태 유지'),
          number: 3,
          badge: CalloutBadge.bottom,
          padding: 6,
        ),
        GuideCallout.box(
          buttonWith('로그인'),
          number: 4,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(
          buttonWith('계정이 없으신가요? 회원가입'),
          number: 5,
          badge: CalloutBadge.left,
        ),
      ],
      crop: cropAround(tester, [loginCard], margin: 36),
    );
  });

  guideCapture('회원가입', const GuideSurface(Size(620, 1360)), (tester) async {
    final api = GuideFakeApi()
      ..get('/auth/username-available', {'available': true});
    final session = guideSession(api: api);
    final patch = ValueNotifier<Rect?>(null);
    await pumpGuideWidget(
      tester,
      Stack(
        textDirection: TextDirection.ltr,
        children: [
          Positioned.fill(
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: guideTheme(),
              home: LoginScreen(session: session),
            ),
          ),
          ValueListenableBuilder<Rect?>(
            valueListenable: patch,
            builder: (context, rect, _) => rect == null
                ? const SizedBox.shrink()
                : Positioned.fromRect(
                    rect: rect,
                    child: const _CheckButtonLookalike(),
                  ),
          ),
        ],
      ),
    );
    await tester.tap(find.text('계정이 없으신가요? 회원가입'));
    await settleGuide(tester);
    final id = find.widgetWithText(TextField, '아이디 입력 (4~20자)');
    await tester.enterText(id, 'minji.kim');
    await tester.tap(find.text('중복 확인'));
    await settleGuide(tester);
    final pw = find.widgetWithText(TextField, '비밀번호');
    final pw2 = find.widgetWithText(TextField, '비밀번호 확인');
    final name = find.widgetWithText(TextField, '이름');
    final mail = find.widgetWithText(TextField, '이메일 주소');
    await tester.enterText(pw, 'tango1234');
    await tester.enterText(pw2, 'tango1234');
    await tester.enterText(name, '김민지');
    await tester.enterText(mail, 'minji.kim');
    // "목록에서 선택"의 질문 글자도 글꼴 이름 없이 그려져서, 그림에는 "직접 작성"으로 적는다.
    await tester.tap(find.text('직접 작성'));
    await settleGuide(tester);
    await tester.enterText(
      find.widgetWithText(TextField, '질문을 직접 입력하세요'),
      '가장 좋아하는 음식은?',
    );
    final answer = find.widgetWithText(TextField, '답변');
    await tester.enterText(answer, '떡볶이');
    FocusManager.instance.primaryFocus?.unfocus();
    await settleGuide(tester);
    patch.value = tester.getRect(buttonWith('중복 확인'));
    await tester.pump();
    final mailRow = find.ancestor(of: mail, matching: find.byType(Row)).first;
    await saveGuideShot(
      tester,
      'messenger-signup',
      callouts: [
        GuideCallout.rect(
          unionRect(tester, [find.text('사용 가능한 아이디입니다.'), id]),
          number: 1,
          badge: CalloutBadge.left,
        ),
        GuideCallout.rect(
          () {
            final r = unionRect(tester, [pw, pw2], padding: 0);
            return Rect.fromLTRB(
              r.left - 4,
              r.top - 9,
              r.right + 4,
              r.bottom + 1,
            );
          }(),
          number: 2,
          badge: CalloutBadge.left,
        ),
        fieldCallout(tester, name, 3),
        GuideCallout.rect(
          unionRect(tester, [find.text('이메일 주소').first, mailRow]),
          number: 4,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(
          find.byWidgetPredicate(
            (w) => w.runtimeType.toString() == '_SecurityQuestionSection',
          ),
          number: 5,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(
          buttonWith('가입하기'),
          number: 6,
          badge: CalloutBadge.left,
        ),
      ],
      crop: cropAround(tester, [loginCard], margin: 36),
    );
  });

  tearDownAll(printGuideImagesSize);
}
