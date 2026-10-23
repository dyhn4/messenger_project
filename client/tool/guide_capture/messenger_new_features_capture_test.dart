// 도움말 "메신저 이용법"에 새로 넣은 부분의 그림 — 계정 보안(개인정보 설정 · 로그인한 기기), 다른 앱에서 공유하기,
// 게시판 말머리 · 필독 · 읽음 확인, 화상회의 녹화 · 회의록, 웹훅 · 앱, 언어 설정.
//
// 다시 찍기(client 폴더에서):
//   flutter test tool/guide_capture/messenger_new_features_capture_test.dart
// 결과: ../server/guide/images/messenger-*.png (이 파일이 찍는 이름은 아래 saveGuideShot 참고)
//
// 응답 모양은 client/test/의 my_devices_test.dart · share_widget_test.dart · board_extras_test.dart ·
// call_recording_test.dart · call_recording_followup_test.dart와 같다. 데모 사람 · 방은 messenger_demo.dart.
import 'dart:io';

import 'package:client/models/announcement.dart';
import 'package:client/models/room.dart';
import 'package:client/screens/announcement_detail_screen.dart'
    show showAnnouncementReadersDialog;
import 'package:client/screens/call/call_recording_widgets.dart';
import 'package:client/screens/call_minutes_screen.dart';
import 'package:client/screens/my_devices_dialog.dart';
import 'package:client/screens/my_profile_dialog.dart';
import 'package:client/screens/room_webhooks_dialog.dart';
import 'package:client/screens/settings_screen.dart';
import 'package:client/screens/share_target_screen.dart';
import 'package:client/services/share_intake.dart';
import 'package:client/widgets/chat_panel.dart';
import 'package:client/widgets/room_picker_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'guide_capture.dart';
import 'messenger_demo.dart';

final _now = DateTime.now();
int _ago(Duration d) => _now.subtract(d).millisecondsSinceEpoch;

/// 화면 가운데 단추 하나 — 눌러서 대화상자·화면을 연다(대화상자는 Navigator 위에 떠야 해서).
Widget _launcher(String label, void Function(BuildContext context) open) =>
    Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: FilledButton(
            onPressed: () => open(context),
            child: Text(label),
          ),
        ),
      ),
    );

Future<void> _launch(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  await settleGuide(tester);
}

// ── 게시판(보드 뷰 토픽) ──
final _boardRoomJson = {
  'id': 'r-board',
  'teamId': 't-tango',
  'type': 'topic',
  'name': '마케팅 자료실',
  'members': [for (final u in everyone) userJson(u)],
  'createdAt': DateTime(2025, 3, 2).millisecondsSinceEpoch,
  'viewMode': 'board',
  'adminIds': [me.id],
  'boardCategories': [
    {'id': 'knotice1', 'name': '공지', 'color': '#E53935'},
    {'id': 'kmeet001', 'name': '회의록', 'color': '#2B8A3E'},
    {'id': 'kquest01', 'name': '질문', 'color': '#5B8DEF'},
  ],
};

Map<String, dynamic> _post(
  String id,
  String title,
  String text,
  AppUserLike by, {
  required Duration ago,
  String? category,
  bool mustRead = false,
  bool? readByMe,
  int comments = 0,
}) => {
  'id': id,
  'roomId': 'r-board',
  'senderId': by.id,
  'senderName': by.name,
  'type': 'post',
  'title': title,
  'text': text,
  'createdAt': _ago(ago),
  'categoryId': category,
  'mustReadAt': mustRead ? _ago(ago) : null,
  'readByMe': ?readByMe,
  'comments': [
    for (var i = 0; i < comments; i++)
      {
        'id': '$id-c$i',
        'messageId': id,
        'roomId': 'r-board',
        'senderId': doHyun.id,
        'senderName': doHyun.name,
        'type': 'text',
        'text': '확인했습니다.',
        'createdAt': _ago(ago - const Duration(minutes: 30)),
      },
  ],
};

typedef AppUserLike = ({String id, String name});

void main() {
  setUpAll(() {
    // 환경설정 창의 버전 표시용(테스트 엔진에는 플랫폼 플러그인이 없다).
    // ignore: invalid_use_of_visible_for_testing_member
    PackageInfo.setMockInitialValues(
      appName: 'TangoTalk',
      packageName: 'com.tangotalk.client',
      version: '1.0.0',
      buildNumber: '1',
      buildSignature: '',
    );
    if (Platform.environment['GUIDE_DRAFT'] == '1') {
      guideImagesDirOverride = Directory.systemTemp.createTempSync(
        'guide_msg_',
      );
    }
  });
  tearDownAll(() {
    guideImagesDirOverride = null;
    printGuideImagesSize();
  });

  guideCapture('개인정보 설정 — 계정 보안 항목', GuideSurface.desktopSmall, (tester) async {
    final session = demoSession();
    await pumpGuideApp(
      tester,
      _launcher(
        '열기',
        (context) => showDialog<void>(
          context: context,
          builder: (_) =>
              PersonalInfoDialog(session: session, verifiedPassword: 'pw'),
        ),
      ),
    );
    await _launch(tester, '열기');
    Finder row(String label) => find
        .ancestor(of: find.text(label), matching: find.byType(InkWell))
        .first;
    await saveGuideShot(
      tester,
      'messenger-security',
      callouts: [
        GuideCallout.box(
          row('2단계 인증'),
          number: 1,
          badge: CalloutBadge.left,
          padding: 0,
        ),
        GuideCallout.box(
          row('보안 키·패스키'),
          number: 2,
          badge: CalloutBadge.left,
          padding: 0,
        ),
        GuideCallout.box(
          row('연결된 회사 계정'),
          number: 3,
          badge: CalloutBadge.left,
          padding: 0,
        ),
        GuideCallout.box(
          row('로그인한 기기'),
          number: 4,
          badge: CalloutBadge.left,
          padding: 0,
        ),
        GuideCallout.rect(
          unionRect(tester, [row('API 토큰'), row('연결된 앱')], padding: 0),
          number: 5,
          badge: CalloutBadge.left,
        ),
      ],
      crop: cropAround(tester, [dialogCard], margin: 24),
    );
  });

  guideCapture('로그인한 기기', GuideSurface.desktopSmall, (tester) async {
    Map<String, dynamic> device(
      String id,
      String kind,
      Duration ago, {
      bool current = false,
      bool online = false,
    }) => {
      'id': id,
      'name': 'x',
      'kind': kind,
      'createdAt': _ago(const Duration(days: 60)),
      'lastSeenAt': _ago(ago),
      'revoked': false,
      'current': current,
      'online': online,
    };
    final api = demoApi(
      extra: (api) => api.get('/api/devices', [
        device('pc', 'windows', Duration.zero, current: true, online: true),
        device('phone', 'android', const Duration(hours: 2), online: true),
        device('web', 'web-desktop', const Duration(days: 6)),
      ]),
    );
    final session = demoSession(api: api);
    await pumpGuideApp(
      tester,
      _launcher('열기', (context) => showMyDevicesDialog(context, session)),
    );
    await _launch(tester, '열기');
    await saveGuideShot(
      tester,
      'messenger-devices',
      callouts: [
        GuideCallout.rect(
          unionRect(tester, [
            find.text('Windows PC'),
            find.textContaining('이 기기'),
          ], padding: 6),
          number: 1,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(
          find.widgetWithText(TextButton, '로그아웃').at(1),
          number: 2,
        ),
        GuideCallout.box(
          find.textContaining('다른 모든 기기에서 로그아웃'),
          number: 3,
          badge: CalloutBadge.left,
        ),
      ],
      crop: cropAround(tester, [dialogCard], margin: 24),
    );
  });

  guideCapture('다른 앱에서 공유하기', const GuideSurface(Size(720, 760)), (
    tester,
  ) async {
    final session = demoSession();
    await pumpGuideApp(
      tester,
      ShareTargetScreen(
        session: session,
        payload: SharedPayload(
          text: '이번 캠페인 시안입니다.',
          files: [
            SharedFile(
              path: '${Directory.systemTemp.path}/campaign_a.png',
              name: '11월_캠페인_시안A.png',
              mimeType: 'image/png',
              size: 845 * 1024,
            ),
            SharedFile(
              path: '${Directory.systemTemp.path}/campaign_b.png',
              name: '11월_캠페인_시안B.png',
              mimeType: 'image/png',
              size: 912 * 1024,
            ),
          ],
        ),
      ),
    );
    await settleGuide(tester);
    for (final name in ['마케팅팀', '주간회의']) {
      await tester.tap(find.byType(RoomPickerField));
      await settleGuide(tester);
      await tester.tap(find.text(name).last);
      await settleGuide(tester);
    }
    await saveGuideShot(
      tester,
      'messenger-share',
      callouts: [
        GuideCallout.box(
          find.byType(RoomPickerField),
          number: 1,
          badge: CalloutBadge.left,
        ),
        GuideCallout.rect(
          unionRect(tester, [
            find.byType(InputChip).first,
            find.byType(InputChip).last,
          ], padding: 4),
          number: 2,
          badge: CalloutBadge.right,
        ),
        GuideCallout.box(
          find.byKey(const ValueKey('share-send')),
          number: 3,
          badge: CalloutBadge.left,
        ),
      ],
      crop: const Rect.fromLTWH(0, 0, 720, 440),
    );
  });

  guideCapture('게시판 — 말머리 · 필독', const GuideSurface(Size(900, 760)), (
    tester,
  ) async {
    ignoreBenignErrors();
    final room = Room.fromJson(_boardRoomJson);
    final hyun = (id: doHyun.id, name: doHyun.name);
    final sy = (id: seoYeon.id, name: seoYeon.name);
    final mine = (id: me.id, name: me.name);
    final api = demoApi(
      extra: (api) => api
        ..get('/api/rooms/r-board/messages', [
          _post(
            'p4',
            '11월 캠페인 일정 확정',
            '11/3 런칭, 11/10 1차 리포트입니다. 일정표를 꼭 확인해 주세요.',
            mine,
            ago: const Duration(hours: 2),
            category: 'knotice1',
            mustRead: true,
            comments: 2,
          ),
          _post(
            'p3',
            '주간 회의록 (10/20)',
            '- 배너 시안 A안으로 결정\n- 보도자료 초안 금요일까지',
            hyun,
            ago: const Duration(days: 2),
            category: 'kmeet001',
            readByMe: false,
            comments: 1,
          ),
          _post(
            'p2',
            '광고 소재 사이즈 규격 문의',
            '네이버 GFA 배너 규격이 바뀌었나요?',
            sy,
            ago: const Duration(days: 3),
            category: 'kquest01',
            comments: 3,
          ),
          _post(
            'p1',
            '브랜드 가이드 v3 공유',
            '로고 여백 규정이 바뀌었습니다. 첨부 문서를 참고하세요.',
            hyun,
            ago: const Duration(days: 6),
            mustRead: true,
            readByMe: false,
          ),
        ])
        ..get('/api/rooms/r-board/must-read', [
          {
            'id': 'p1',
            'title': '브랜드 가이드 v3 공유',
            'createdAt': _ago(const Duration(days: 6)),
            'mustReadAt': _ago(const Duration(days: 6)),
          },
        ]),
    );
    final session = demoSession(api: api, rooms: [room]);
    await pumpGuideApp(
      tester,
      Scaffold(
        body: ChatPanel(key: ValueKey(room.id), session: session, room: room),
      ),
    );
    await settleGuide(tester);
    await saveGuideShot(
      tester,
      'messenger-board-extras',
      callouts: [
        GuideCallout.rect(
          unionRect(tester, [
            find.text('전체').first,
            find.text('질문').first,
          ], padding: 10),
          number: 1,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(
          find.byTooltip('말머리 관리'),
          number: 2,
          badge: CalloutBadge.right,
        ),
        GuideCallout.box(
          find.byKey(const ValueKey('board-must-read')),
          number: 3,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(
          find.byKey(const ValueKey('must-read-tag')).first,
          number: 4,
          badge: CalloutBadge.right,
        ),
        GuideCallout.box(
          find.text('공지').at(1),
          number: 5,
          badge: CalloutBadge.left,
        ),
      ],
      crop: Rect.fromLTWH(
        0,
        0,
        900,
        tester.getRect(find.textContaining('보도자료 초안 금요일까지')).bottom + 70,
      ),
    );
  });

  guideCapture('읽음 확인 창', GuideSurface.desktopSmall, (tester) async {
    final readers = AnnouncementReaders(
      read: [
        (
          userId: doHyun.id,
          name: doHyun.name,
          readAt: _now.subtract(const Duration(hours: 1, minutes: 12)),
        ),
        (
          userId: seoYeon.id,
          name: seoYeon.name,
          readAt: _now.subtract(const Duration(minutes: 40)),
        ),
        (
          userId: jiWoo.id,
          name: jiWoo.name,
          readAt: _now.subtract(const Duration(minutes: 8)),
        ),
      ],
      unread: [
        (userId: junHo.id, name: junHo.name),
        (userId: yuNa.id, name: yuNa.name),
      ],
    );
    await pumpGuideApp(
      tester,
      _launcher(
        '열기',
        (context) => showAnnouncementReadersDialog(context, readers),
      ),
    );
    await _launch(tester, '열기');
    await saveGuideShot(
      tester,
      'messenger-readers',
      callouts: [
        GuideCallout.box(find.text('읽음 3'), number: 1),
        GuideCallout.box(find.text('안 읽음 2'), number: 2),
      ],
      crop: cropAround(tester, [dialogCard], margin: 24),
    );
  });

  guideCapture('녹화 시작 창', GuideSurface.desktopSmall, (tester) async {
    await pumpGuideApp(
      tester,
      _launcher(
        '열기',
        (context) => showCallRecordingStartDialog(
          context,
          minutesAvailable: true,
          summaryAvailable: true,
        ),
      ),
    );
    await _launch(tester, '열기');
    await saveGuideShot(
      tester,
      'messenger-call-record',
      callouts: [
        GuideCallout.rect(
          unionRect(tester, [
            find.text('영상과 소리(mp4)'),
            find.text('소리만(mp3)'),
          ], padding: 10).expandToInclude(
            tester.getRect(find.byType(Radio<bool>).first).inflate(6),
          ),
          number: 1,
          badge: CalloutBadge.left,
        ),
        GuideCallout.rect(
          unionRect(tester, [
            find.text('끝나면 회의록 만들기'),
            find.byType(Checkbox),
          ], padding: 8),
          number: 2,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(
          find.ancestor(
            of: find.text('녹화 시작').last,
            matching: find.bySubtype<ButtonStyleButton>(),
          ),
          number: 3,
          badge: CalloutBadge.left,
        ),
      ],
      crop: cropAround(tester, [dialogCard], margin: 24),
    );
  });

  guideCapture('회의록 화면', const GuideSurface(Size(900, 760)), (tester) async {
    final started = _now.subtract(const Duration(hours: 3));
    final api = demoApi(
      extra: (api) => api.get('/api/call-recordings/:id', {
        'recording': {
          'id': 'rec1',
          'roomId': 'r-mkt',
          'startedBy': me.id,
          'startedByName': me.name,
          'startedAt': started.millisecondsSinceEpoch,
          'endedAt': started
              .add(const Duration(minutes: 32))
              .millisecondsSinceEpoch,
          'durationMs': 32 * 60000,
          'audioOnly': false,
          'status': 'done',
          'minutesStatus': 'done',
          'participantNames': [me.name, doHyun.name, seoYeon.name, junHo.name],
          'summary':
              '## 요약\n11월 캠페인 배너 시안과 일정을 확정했다.\n\n'
              '## 논의한 내용\n- 배너 시안 A·B 비교 — A안이 클릭률 예상치가 높음\n- 보도자료 배포 시점\n\n'
              '## 결정 사항\n- 배너는 A안으로 진행\n- 11/3 런칭\n\n'
              '## 할 일\n- ${doHyun.name}: 보도자료 초안 (10/31)\n- ${seoYeon.name}: 배너 최종본 전달 (10/29)',
          'transcript':
              '[00:12] ${me.name}: 오늘은 11월 캠페인 시안부터 보겠습니다.\n'
              '[01:05] ${seoYeon.name}: A안은 버튼을 키웠고, B안은 문구를 줄였어요.\n'
              '[02:40] ${doHyun.name}: 지난번 테스트 기준이면 A안이 낫겠네요.',
          'actionItems': [
            {
              'text': '보도자료 초안',
              'owner': doHyun.name,
              'dueText': '10/31',
              'due': '${_now.year}-10-31',
            },
            {
              'text': '배너 최종본 전달',
              'owner': seoYeon.name,
              'dueText': '10/29',
              'due': '${_now.year}-10-29',
            },
          ],
          'canRetry': false,
        },
      }),
    );
    final session = demoSession(api: api);
    final room = session.rooms.firstWhere((r) => r.id == 'r-mkt');
    await pumpGuideApp(
      tester,
      CallMinutesScreen(session: session, room: room, recordingId: 'rec1'),
    );
    await settleGuide(tester);
    await saveGuideShot(
      tester,
      'messenger-call-minutes',
      callouts: [
        GuideCallout.rect(
          unionRect(tester, [
            find.text('요약'),
            find.textContaining('박서연: 배너 최종본 전달').first,
          ], padding: 8),
          number: 1,
          badge: CalloutBadge.right,
        ),
        GuideCallout.box(
          find.byTooltip('복사'),
          number: 2,
          badge: CalloutBadge.bottom,
        ),
        GuideCallout.box(
          find.byTooltip('팀 위키에 저장'),
          number: 3,
          badge: CalloutBadge.bottom,
        ),
        GuideCallout.box(
          find.text('할 일로').first,
          number: 4,
          badge: CalloutBadge.left,
        ),
      ],
      crop: Rect.fromLTWH(
        0,
        0,
        900,
        tester.getRect(find.text('할 일로').last).bottom + 40,
      ),
    );
  });

  guideCapture('웹훅 · 앱', GuideSurface.desktopSmall, (tester) async {
    final api = demoApi(
      extra: (api) => api
        ..get('/api/rooms/:id/webhooks', [
          {
            'id': 'w1',
            'kind': 'webhook',
            'teamId': 't-tango',
            'roomId': 'r-mkt',
            'name': '광고 성과 알림',
            'emoji': '📈',
            'tokenPrefix': 'whk_3f9a',
            'createdByName': me.name,
            'createdAt': _ago(const Duration(days: 12)),
            'lastUsedAt': _ago(const Duration(hours: 3)),
            'useCount': 41,
          },
          {
            'id': 'w2',
            'kind': 'webhook',
            'teamId': 't-tango',
            'roomId': 'r-mkt',
            'name': '설문 응답',
            'emoji': '📝',
            'tokenPrefix': 'whk_81c2',
            'createdByName': doHyun.name,
            'createdAt': _ago(const Duration(days: 30)),
            'lastUsedAt': _ago(const Duration(days: 2)),
            'useCount': 7,
          },
        ]),
    );
    final session = demoSession(api: api);
    final room = session.rooms.firstWhere((r) => r.id == 'r-mkt');
    await pumpGuideApp(
      tester,
      _launcher(
        '열기',
        (context) => showRoomWebhooksDialog(context, session, room),
      ),
    );
    await _launch(tester, '열기');
    await saveGuideShot(
      tester,
      'messenger-webhooks',
      callouts: [
        GuideCallout.box(find.byType(TabBar), number: 1),
        GuideCallout.rect(
          unionRect(tester, [
            find.text('광고 성과 알림'),
            find.textContaining('whk_3f9a'),
          ], padding: 8),
          number: 2,
          badge: CalloutBadge.right,
        ),
        GuideCallout.box(
          find.ancestor(
            of: find.text('웹훅 만들기'),
            matching: find.bySubtype<ButtonStyleButton>(),
          ),
          number: 3,
          badge: CalloutBadge.left,
        ),
      ],
      crop: cropAround(tester, [dialogCard], margin: 24),
    );
  });

  guideCapture('환경설정 — 언어', const GuideSurface(Size(780, 800)), (tester) async {
    final session = demoSession();
    await pumpGuideApp(
      tester,
      _launcher(
        '열기',
        (context) => showDialog<void>(
          context: context,
          builder: (_) => SettingsScreen(session: session),
        ),
      ),
    );
    await _launch(tester, '열기');
    await tester.tap(find.text('화면 설정'));
    await settleGuide(tester);
    final language = find.text('언어 (Language)');
    await Scrollable.ensureVisible(tester.element(language), alignment: 0.1);
    await settleGuide(tester);
    final languageItem = find
        .ancestor(
          of: language,
          matching: find.byWidgetPredicate(
            (w) => w.runtimeType.toString() == '_Item',
          ),
        )
        .first;
    await saveGuideShot(
      tester,
      'messenger-settings-language',
      callouts: [
        GuideCallout.box(
          find.text('화면 설정').first,
          number: 1,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(languageItem, number: 2, badge: CalloutBadge.left),
      ],
      crop: cropAround(tester, [dialogCard], margin: 20),
    );
  });
}
