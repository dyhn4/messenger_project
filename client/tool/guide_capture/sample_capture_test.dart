// 도움말 스크린샷 캡처 예시 — 새 캡처 파일을 만들 때 이 파일을 복사해서 시작한다.
//
// 다시 찍기(client 폴더에서):
//   flutter test tool/guide_capture/sample_capture_test.dart
// 결과: 임시 폴더의 sample-account-menu.png(경로는 실행 결과에 찍힌다). 예시일 뿐이라 도움말 그림
// 폴더(server/guide/images)에는 쓰지 않는다 — 그 폴더는 설치 파일·업데이트 묶음에 통째로 들어간다.
// 새 캡처 파일을 만들 때는 아래 setUpAll(임시 폴더로 돌리기)을 지우고 시작한다.
//
// 흐름: guideCapture(화면 크기·글꼴·플랫폼 준비) → guideSession/GuideFakeApi(가짜 로그인·서버)
// → pumpGuideApp(앱과 같은 테마로 진짜 위젯 올리기) → 탭 등으로 원하는 상태 만들기
// → saveGuideShot(빨간 번호 표시를 얹어 PNG 저장).
import 'dart:io';

import 'package:client/models/team.dart';
import 'package:client/widgets/account_menu_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'guide_capture.dart';

void main() {
  // 예시 그림은 배포하지 않는다 — 운영체제 임시 폴더에 저장한다(열어 볼 수 있게 지우지는 않는다).
  setUpAll(() {
    guideImagesDirOverride = Directory.systemTemp.createTempSync(
      'guide_sample_',
    );
  });
  tearDownAll(() => guideImagesDirOverride = null);

  guideCapture('예시: 오른쪽 위 ☰ 메뉴의 도움말', GuideSurface.desktopSmall, (
    tester,
  ) async {
    // 메뉴를 여는 동안 부르는 API는 없다 — 필요하면 GuideFakeApi()..post(경로, 응답)처럼 정해 둔다.
    final api = GuideFakeApi();
    final session = guideSession(api: api, role: AccountRole.admin);

    await pumpGuideApp(
      tester,
      Scaffold(
        appBar: AppBar(
          title: const Text('마케팅팀'),
          actions: [AccountMenuButton(session: session)],
        ),
        body: const Center(child: Text('대화방을 골라 주세요 😊')),
      ),
    );

    // ① ☰ 버튼을 누르면 ② 메뉴가 열린다.
    final menuButton = find.byTooltip('설정');
    final menuRect = tester.getRect(menuButton);
    await tester.tap(menuButton);
    await settleGuide(tester);

    final help = find.ancestor(
      of: find.text('도움말'),
      matching: find.byType(PopupMenuItem<void>),
    );
    expect(help, findsOneWidget);

    await saveGuideShot(
      tester,
      'sample-account-menu',
      callouts: [
        GuideCallout.rect(menuRect.deflate(2), number: 1),
        GuideCallout.box(help, number: 2, badge: CalloutBadge.left),
      ],
      // 창 오른쪽 위만 잘라서 보여준다.
      crop: Rect.fromLTRB(
        tester.getSize(find.byType(Scaffold)).width - 420,
        0,
        tester.getSize(find.byType(Scaffold)).width,
        460,
      ),
    );
  });
}
