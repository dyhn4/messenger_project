import 'package:client/l10n/server_en.dart';
import 'package:client/l10n/strings_en.dart';
import 'package:client/l10n/tr.dart';
import 'package:client/models/groupware.dart';
import 'package:client/models/message.dart';
import 'package:client/services/api_client.dart';
import 'package:client/widgets/language_picker.dart';
import 'package:client/widgets/system_message_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 다국어(lib/l10n/tr.dart) — 한국어가 기본이고 원문 그대로, 영어면 표에서 찾고 값은 {이름} 자리에 넣는다. 서버 글은 그대로 같은 글·
/// 틀({0}) 둘 다 옮긴다. 표(strings_en.dart·server_en.dart)는 tool/l10n/build.mjs가 만든다.

void main() {
  tearDown(() {
    AppLocale.apply('ko');
    debugResetServerTemplates();
  });

  test('한국어(기본) — 원문 그대로, 자리에는 값만 넣는다', () {
    expect(AppLocale.current, AppLanguage.ko);
    expect(tr('취소'), '취소');
    expect(tr('{name}님이 참여했습니다', {'name': '김가'}), '김가님이 참여했습니다');
    expect(tr('번역이 없는 글'), '번역이 없는 글');
    expect(trServer('이 팀의 멤버가 아닙니다.'), '이 팀의 멤버가 아닙니다.');
  });

  test('영어 — 표에서 찾고, 없으면 원문, 자리는 이름으로', () {
    AppLocale.apply('en');
    expect(AppLocale.current, AppLanguage.en);
    expect(tr('취소'), stringsEn['취소']);
    expect(tr('취소'), isNot('취소'));
    expect(tr('번역이 없는 글'), '번역이 없는 글');
    final key = stringsEn.keys.firstWhere((k) => k.contains('{name}'));
    final out = tr(key, {'name': 'Jane'});
    expect(out, contains('Jane'));
    expect(out, isNot(contains('{name}')));
    // 없는 이름의 자리는 그대로 둔다.
    expect(fillPlaceholders('{a} {b}', {'a': 1}), '1 {b}');
    // 영어에 없는 조사는 빈 글로 옮긴다.
    expect(tr('을'), '');
  });

  test('서버 글 — 그대로 같은 글과 {0} 틀을 옮기고, 모르는 글은 그대로', () {
    AppLocale.apply('en');
    final exact = serverEn.keys.first;
    expect(trServer(exact), serverEn[exact]);
    // 틀 하나를 골라 서버처럼 값을 넣어 본다.
    final template = serverTemplatesEn.keys.firstWhere(
      (k) => RegExp(r'^[^{}]*\{0\}[^{}]+$').hasMatch(k),
    );
    final sent = template.replaceAll('{0}', '보고서.pdf');
    final english = trServer(sent);
    expect(english, contains('보고서.pdf'));
    expect(english, serverTemplatesEn[template]!.replaceAll('{0}', '보고서.pdf'));
    expect(trServer('서버가 처음 보내는 글'), '서버가 처음 보내는 글');
    expect(trServer(null), '');
  });

  test('ApiException — 화면에 보일 때 지금 언어로', () {
    const e = ApiException('이 팀의 멤버가 아닙니다.');
    expect('$e', '이 팀의 멤버가 아닙니다.');
    AppLocale.apply('en');
    expect('$e', trServer('이 팀의 멤버가 아닙니다.'));
    expect(e.message, '이 팀의 멤버가 아닙니다.', reason: '비교용 원문은 그대로');
  });

  test('enum 이름 — 읽는 자리에서 옮긴다', () {
    expect(ApprovalStatus.rejected.label, '반려');
    AppLocale.apply('en');
    expect(ApprovalStatus.rejected.label, stringsEn['반려']);
  });

  test('설정 값 — 저장·읽기, 모르는 값은 한국어, 기기 언어 따르기', () async {
    SharedPreferences.setMockInitialValues({});
    await AppLocale.save('en');
    expect(AppLocale.setting, 'en');
    AppLocale.apply('ko');
    await AppLocale.load();
    expect(AppLocale.current, AppLanguage.en);
    AppLocale.apply('xx');
    expect(AppLocale.setting, 'ko');
    AppLocale.apply('system');
    expect(AppLocale.setting, 'system');
    // 테스트 기기 언어는 영어(en_US) — 한국어가 아니면 영어.
    expect(AppLocale.current, AppLanguage.en);
  });

  testWidgets('언어를 고르면 바로 바뀐다 — 시스템 메시지도 영어로', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final text = serverEn.keys.first;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              const LanguagePicker(),
              ValueListenableBuilder(
                valueListenable: AppLocale.changes,
                builder: (context, _, _) => SystemMessageRow(
                  message: Message(
                    id: 'm1',
                    roomId: 'r1',
                    senderName: '',
                    type: MessageType.system,
                    text: text,
                    createdAt: DateTime(2026, 10, 7, 9),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.text(text), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('language-picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('English').last);
    await tester.pumpAndSettle();
    expect(AppLocale.current, AppLanguage.en);
    expect(find.text(serverEn[text]!), findsOneWidget);
    expect(find.text('Use device language'), findsNothing, reason: '메뉴는 닫혔다');
  });
}
