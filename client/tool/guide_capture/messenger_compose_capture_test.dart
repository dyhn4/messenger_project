// 초보자용 도움말 "메신저 이용법"(server/guide/messenger.html)의 기존 장에 새로 끼울 절의 그림을 찍는다 —
// 메시지 예약, 멘션과 알림 센터의 멘션·보드 알림, 표 붙여넣기, 새 이모티콘 세트와 캐릭터, 사진·파일 메시지
// 고치기와 파일 삭제, 공지 댓글, 내가 쓴 글.
//
// 다시 찍기(client 폴더에서):
//   flutter test tool/guide_capture/messenger_compose_capture_test.dart
// 한 장만:
//   flutter test tool/guide_capture/messenger_compose_capture_test.dart --plain-name "메시지 예약 창"
// 결과: ../server/guide/images/messenger-compose-*.png
//
// 진짜 앱 화면(DesktopHomeScreen 등)을 가짜 서버 응답과 예시 데이터(messenger_demo.dart)로 채워
// 그린다. 이 파일에만 필요한 가짜 응답(예약 메시지, 알림, 공지 댓글, 내가 쓴 글 등)은 아래에 둔다.
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:client/data/stickers.dart';
import 'package:client/models/sticker_pack.dart';
import 'package:client/models/team.dart';
import 'package:client/screens/my_profile_dialog.dart';
import 'package:client/services/clipboard_paste.dart';
import 'package:client/services/session.dart';
import 'package:client/widgets/attachment_widgets.dart' show DownloadableFile;
import 'package:client/widgets/chat_input_bar.dart';
import 'package:client/widgets/filter_dropdown.dart';
import 'package:client/widgets/hover_toolbar.dart';
import 'package:client/widgets/message_bubble.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'guide_capture.dart';
import 'messenger_demo.dart';

// ───────────────────────────── 예시 데이터 ─────────────────────────────

/// 지금 시각 기준 [days]일 뒤 [hour]시 [minute]분 — 예약은 앞으로의 시각이어야 화면이 "지난 시각"이라고
/// 하지 않는다(예약 화면은 실제 시계를 쓴다).
DateTime _ahead(int days, int hour, [int minute = 0]) {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day + days, hour, minute);
}

Map<String, dynamic> _scheduled(
  String id,
  String roomId,
  String roomName,
  String text,
  DateTime sendAt, {
  String status = 'scheduled',
  String? failReason,
  int files = 0,
}) => {
  'id': id,
  'teamId': tango.id,
  'roomId': roomId,
  'roomName': roomName,
  'text': text,
  'sendAt': sendAt.millisecondsSinceEpoch,
  'status': status,
  'failReason': ?failReason,
  'createdAt': DateTime.now()
      .subtract(const Duration(hours: 2))
      .millisecondsSinceEpoch,
  'attachments': [
    for (var i = 0; i < files; i++)
      {
        'id': '$id-a$i',
        'kind': 'file',
        'fileUrl': '/uploads/$id-$i',
        'fileName': '주간보고_$i.xlsx',
        'fileSize': 120000,
      },
  ],
};

/// 내 예약 — 발송 실패 하나, 마케팅팀에 둘, 1:1에 하나.
List<Map<String, dynamic>> _scheduledList() => [
  _scheduled(
    's-fail',
    'r-weekly',
    '주간회의',
    '이번 주 회의는 2층 소회의실에서 진행합니다.',
    _ahead(0, 9),
    status: 'failed',
    failReason: '읽기 전용 토픽이라 보내지 못했습니다.',
  ),
  _scheduled(
    's1',
    'r-mkt',
    '마케팅팀',
    '오늘 오후 2시 3분기 캠페인 중간 점검 회의 잊지 마세요!',
    _ahead(1, 9),
  ),
  _scheduled(
    's2',
    'r-mkt',
    '마케팅팀',
    '주간 보고서 초안 올려 두었습니다. 금요일까지 의견 부탁드려요.',
    _ahead(3, 10, 30),
    files: 1,
  ),
  _scheduled('s3', 'r-dm-dh', '이도현', '팀장님, 다음 주 휴가 일정 공유드립니다.', _ahead(4, 17)),
];

/// 서버 알림 한 건(server notifications 표 모양).
Map<String, dynamic> _notification(
  String id,
  String kind, {
  required String roomId,
  required String roomName,
  String roomType = 'topic',
  required String actorId,
  required String actorName,
  required String preview,
  required DateTime time,
  bool read = false,
}) => {
  'id': id,
  'kind': kind,
  'teamId': tango.id,
  'teamName': tango.name,
  'roomId': roomId,
  'roomName': roomName,
  'roomType': roomType,
  'messageId': 'msg-$id',
  'actorId': actorId,
  'actorName': actorName,
  'preview': preview,
  'createdAt': time.millisecondsSinceEpoch,
  if (read)
    'readAt': time.add(const Duration(minutes: 5)).millisecondsSinceEpoch,
};

final _mentionNotifications = [
  _notification(
    'n1',
    'mention',
    roomId: 'r-mkt',
    roomName: '마케팅팀',
    actorId: doHyun.id,
    actorName: doHyun.name,
    preview: '@김민지 기획안에 일정표 한 장만 추가해 주세요.',
    time: at(10, 42),
  ),
  _notification(
    'n2',
    'mention_all',
    roomId: 'r-notice',
    roomName: '전사 공지',
    actorId: yuNa.id,
    actorName: yuNa.name,
    preview: '@all 내일 오전 10시에 소방 훈련이 있습니다.',
    time: at(9, 10),
  ),
  _notification(
    'n3',
    'mention',
    roomId: 'r-tf',
    roomName: '3분기 캠페인 TF',
    roomType: 'group',
    actorId: jiWoo.id,
    actorName: jiWoo.name,
    preview: '@김민지 고객사 사례 정리본 확인 부탁드려요.',
    time: at(16, 30, day: 28),
    read: true,
  ),
];

final _boardNotifications = [
  _notification(
    'b1',
    'board_post',
    roomId: 'r-design',
    roomName: '디자인 가이드',
    actorId: seoYeon.id,
    actorName: seoYeon.name,
    preview: '10월 브랜드 컬러 가이드 업데이트',
    time: at(10, 5),
  ),
];

/// 가짜 서버 — 데모 응답에 이 파일의 응답(예약 · 알림 · 공지 댓글 · 내가 쓴 글 · 이모티콘)을 더한다.
GuideFakeApi _composeApi({
  void Function(GuideFakeApi api)? extra,
  bool withComments = false,
}) => demoApi(
  withComments: withComments,
  extra: (api) {
    extra?.call(api);
    api
      ..get('/api/scheduled-messages', (_) => _scheduledList())
      ..get('/api/notifications/unread-counts', {
        'mention': 2,
        'mentionPersonal': 1,
        'mentionAll': 1,
        'board': 1,
      })
      ..get('/api/notifications', (req) {
        final kind = req.url.queryParameters['kind'] ?? 'mention';
        final items = switch (kind) {
          'board' => _boardNotifications,
          'mention_personal' => [
            for (final n in _mentionNotifications)
              if (n['kind'] == 'mention') n,
          ],
          'mention_all' => [
            for (final n in _mentionNotifications)
              if (n['kind'] == 'mention_all') n,
          ],
          _ => _mentionNotifications,
        };
        return {'items': items, 'hasMore': false};
      })
      ..get('/api/notification-settings', {
        'mentionAll': true,
        'boardLevel': 'important',
      })
      ..get('/api/rooms/r-notice/announcements/an1/comments', [
        _announcementComment(
          'ac1',
          junHo,
          '대회의실 자리가 부족하면 2층 라운지도 열어 두나요?',
          at(8, 40),
        ),
        _announcementComment(
          'ac2',
          yuNa,
          '네, 라운지에서도 화면으로 함께 볼 수 있게 준비하겠습니다.',
          at(8, 52),
        ),
        _announcementComment(
          'ac3',
          doHyun,
          '마케팅팀은 3시 10분 전까지 모이겠습니다.',
          at(9, 5),
        ),
      ])
      ..get('/api/my-posts', (_) => _myPosts());
  },
);

Map<String, dynamic> _announcementComment(
  String id,
  dynamic author,
  String text,
  DateTime time,
) => {
  'id': id,
  'announcementId': 'an1',
  'roomId': 'r-notice',
  'authorId': author.id,
  'authorName': author.name,
  'text': text,
  'createdAt': time.millisecondsSinceEpoch,
};

Map<String, dynamic> _myPosts() => {
  'items': [
    {
      'kind': 'message',
      'id': 'm6',
      'messageId': 'm6',
      'roomId': 'r-mkt',
      'roomName': '마케팅팀',
      'roomType': 'topic',
      'teamId': tango.id,
      'text': myLastText,
      'createdAt': at(10, 15).millisecondsSinceEpoch,
    },
    {
      'kind': 'comment',
      'id': 'c2',
      'messageId': 'm3',
      'roomId': 'r-mkt',
      'roomName': '마케팅팀',
      'roomType': 'topic',
      'teamId': tango.id,
      'text': '네, 회의 전까지 반영하겠습니다!',
      'parent': '기획안 초안 공유드립니다. 검토 부탁드려요!',
      'createdAt': at(9, 55).millisecondsSinceEpoch,
    },
    {
      'kind': 'message',
      'id': 'm3',
      'messageId': 'm3',
      'roomId': 'r-mkt',
      'roomName': '마케팅팀',
      'roomType': 'topic',
      'teamId': tango.id,
      'text': '기획안 초안 공유드립니다. 검토 부탁드려요!',
      'createdAt': at(9, 41).millisecondsSinceEpoch,
      'editedAt': at(9, 43).millisecondsSinceEpoch,
    },
    {
      'kind': 'message',
      'id': 'p1',
      'messageId': 'p1',
      'roomId': 'r-lunch',
      'roomName': '점심 메뉴 정하기',
      'roomType': 'group',
      'teamId': tango.id,
      'text': '저는 칼국수 좋아요! 12시 10분에 1층에서 만나요.',
      'createdAt': at(11, 4, day: 28).millisecondsSinceEpoch,
    },
    {
      'kind': 'comment',
      'id': 'c9',
      'messageId': 's2',
      'roomId': 'r-tf',
      'roomName': '3분기 캠페인 TF',
      'roomType': 'group',
      'teamId': tango.id,
      'text': '사례 세 곳 모두 기획안 부록에 넣겠습니다.',
      'parent': '기획안에 들어갈 고객사 사례 세 곳 정리했습니다.',
      'createdAt': at(16, 41, day: 26).millisecondsSinceEpoch,
    },
  ],
  'hasMore': false,
};

/// 방을 연 PC 화면 — [api]로 이 파일의 가짜 서버를 쓰고, 예약 목록을 받아 둔다.
Future<Session> _open(
  WidgetTester tester, {
  String? roomName = '마케팅팀',
  GuideFakeApi? api,
  void Function(Session session)? prepare,
}) async {
  final session = demoSession(api: api ?? _composeApi());
  prepare?.call(session);
  await openDesktop(tester, roomName: roomName, session: session);
  await session.loadScheduledMessages();
  await settleGuide(tester);
  return session;
}

/// 메시지를 고치고 지울 수 있는 시간을 넉넉히 둔 팀 — 예시 메시지는 날짜가 고정(9월 29일)이라 기본(5분)이면
/// "시간이 지나 고칠 수 없다"는 안내가 뜬다.
void _allowLateEdits(Session session) {
  final relaxed = Team(
    id: tango.id,
    name: tango.name,
    iconEmoji: tango.iconEmoji,
    iconColor: tango.iconColor,
    createdAt: tango.createdAt,
    memberCount: tango.memberCount,
    messageEditDeleteWindowSeconds: 10 * 365 * 24 * 3600,
  );
  final i = session.teams.indexWhere((t) => t.id == tango.id);
  session.teams[i] = relaxed;
  session.currentTeam = relaxed;
}

// ───────────────────────────── 그림 이모티콘 ─────────────────────────────

/// "뚕뚕" 같은 동글동글한 캐릭터 그림(투명 바탕) — 서버에 올린 이모티콘 대신.
img.Image _blob({
  required int color,
  int mood = 0,
  bool blush = true,
  int size = 160,
}) {
  final image = img.Image(width: size, height: size, numChannels: 4);
  img.fill(image, color: img.ColorRgba8(0, 0, 0, 0));
  final c = img.ColorRgba8(
    (color >> 16) & 0xFF,
    (color >> 8) & 0xFF,
    color & 0xFF,
    255,
  );
  final dark = img.ColorRgba8(52, 58, 64, 255);
  final s = size / 160;
  int p(num v) => (v * s).round();
  // 몸통(아래가 살짝 넓은 동그라미) + 귀 두 개.
  img.fillCircle(image, x: p(52), y: p(40), radius: p(20), color: c);
  img.fillCircle(image, x: p(108), y: p(40), radius: p(20), color: c);
  img.fillCircle(image, x: p(80), y: p(88), radius: p(62), color: c);
  img.fillCircle(image, x: p(80), y: p(104), radius: p(52), color: c);
  // 눈.
  if (mood == 2) {
    // 웃는 눈(^ ^).
    for (final x in [58, 102]) {
      img.drawLine(
        image,
        x1: p(x - 9),
        y1: p(84),
        x2: p(x),
        y2: p(76),
        color: dark,
        thickness: 4 * s,
      );
      img.drawLine(
        image,
        x1: p(x),
        y1: p(76),
        x2: p(x + 9),
        y2: p(84),
        color: dark,
        thickness: 4 * s,
      );
    }
  } else {
    img.fillCircle(image, x: p(58), y: p(82), radius: p(8), color: dark);
    img.fillCircle(image, x: p(102), y: p(82), radius: p(8), color: dark);
    img.fillCircle(
      image,
      x: p(60),
      y: p(79),
      radius: p(3),
      color: img.ColorRgba8(255, 255, 255, 255),
    );
    img.fillCircle(
      image,
      x: p(104),
      y: p(79),
      radius: p(3),
      color: img.ColorRgba8(255, 255, 255, 255),
    );
  }
  if (blush) {
    final pink = img.ColorRgba8(255, 135, 160, 150);
    img.fillCircle(image, x: p(44), y: p(100), radius: p(9), color: pink);
    img.fillCircle(image, x: p(116), y: p(100), radius: p(9), color: pink);
  }
  // 입.
  switch (mood) {
    case 1: // 놀람(동그란 입)
      img.fillCircle(image, x: p(80), y: p(108), radius: p(9), color: dark);
    case 3: // 시무룩(ㅅ)
      img.drawLine(
        image,
        x1: p(70),
        y1: p(112),
        x2: p(80),
        y2: p(104),
        color: dark,
        thickness: 4 * s,
      );
      img.drawLine(
        image,
        x1: p(80),
        y1: p(104),
        x2: p(90),
        y2: p(112),
        color: dark,
        thickness: 4 * s,
      );
    default: // 웃음(∪)
      for (var a = 0; a <= 180; a += 10) {
        final r = a * math.pi / 180;
        img.fillCircle(
          image,
          x: p(80 + 11 * math.cos(r)),
          y: p(102 + 9 * math.sin(r)),
          radius: p(2.4),
          color: dark,
        );
      }
  }
  return image;
}

/// 이모티콘 세트 그림들 — (id, 그림).
List<(String, img.Image)> _ddungStickers() => [
  ('dd1', _blob(color: 0xFFD8A8)),
  ('dd2', _blob(color: 0xFFE066, mood: 2)),
  ('dd3', _blob(color: 0xB2F2BB, mood: 1)),
  ('dd4', _blob(color: 0xA5D8FF, mood: 3)),
  ('dd5', _blob(color: 0xFCC2D7, mood: 2)),
  ('dd6', _blob(color: 0xD0BFFF)),
  ('dd7', _blob(color: 0xFFC078, mood: 1)),
  ('dd8', _blob(color: 0x96F2D7, mood: 2)),
];

List<(String, img.Image)> _characterSet() => [
  ('ch1', _blob(color: 0xFFD8A8, mood: 2, size: 160)),
  ('ch2', _blob(color: 0xA5D8FF, size: 160)),
  ('ch3', _blob(color: 0xB2F2BB, mood: 2, size: 160)),
  ('ch4', _blob(color: 0xFCC2D7, size: 160)),
  ('ch5', _blob(color: 0xD0BFFF, mood: 2, size: 160)),
  ('ch6', _blob(color: 0xFFE066, size: 160)),
];

String _stickerUrl(String id) =>
    'https://192.168.0.10:3000/files/stickers/$id.png';

/// 그림 이모티콘을 화면이 찾는 그대로의 이미지 캐시 키로 넣어 둔다 — StickerView는 이모티콘 id를 캐시 키로
/// (주소는 매번 바뀌는 서명 링크라서) 쓰고, 목록에서는 그리는 크기로 줄여 디코딩한다([logicalSizes]마다 따로).
Future<void> _seedSticker(
  WidgetTester tester,
  String serverId,
  img.Image image, {
  List<double?> logicalSizes = const [null],
}) async {
  final png = img.encodePng(image);
  final decoded = await tester.runAsync(() async {
    final codec = await ui.instantiateImageCodec(png);
    try {
      return (await codec.getNextFrame()).image;
    } finally {
      codec.dispose();
    }
  });
  final base = CachedNetworkImageProvider(
    _stickerUrl(serverId),
    cacheKey: 'sticker-$serverStickerPrefix$serverId',
  );
  for (final size in logicalSizes) {
    final ImageProvider provider = size == null
        ? base
        : ResizeImage.resizeIfNeeded((size * 1.5).round(), null, base);
    final key = await provider.obtainKey(ImageConfiguration.empty);
    PaintingBinding.instance.imageCache.putIfAbsent(
      key,
      () => OneFrameImageStreamCompleter(
        SynchronousFuture(ImageInfo(image: decoded!.clone())),
      ),
    );
  }
}

Map<String, dynamic> _packJson(
  String id,
  String name,
  String kind,
  List<(String, img.Image)> stickers,
) => {
  'id': id,
  'name': name,
  'kind': kind,
  'stickers': [
    for (final (sid, _) in stickers)
      {
        'id': sid,
        'packId': id,
        'url': '/files/stickers/$sid.png',
        'fileName': '$sid.png',
      },
  ],
};

void main() {
  // ── 4. 메시지 보내기 › 메시지 예약 ──

  guideCapture('예약 단추', compact, (tester) async {
    await _open(tester);
    final field = find.byKey(const ValueKey('chat-input'));
    await tester.enterText(field, '내일 오전 회의 자료는 공유 폴더에 올려 두었습니다.');
    await tester.pump(const Duration(milliseconds: 300));
    final input = tester.getRect(find.byType(ChatInputBar));
    await saveGuideShot(
      tester,
      'messenger-compose-schedule-button',
      callouts: [
        GuideCallout.box(
          find.byKey(const ValueKey('chat-schedule')),
          number: 1,
          badge: CalloutBadge.top,
        ),
        GuideCallout.box(
          find.byKey(const ValueKey('scheduled-room-bar')),
          number: 7,
          badge: CalloutBadge.left,
          padding: 2,
        ),
      ],
      crop: clampToScreen(
        tester,
        Rect.fromLTRB(input.left, input.top - 12, input.right, input.bottom),
      ),
    );
  });

  guideCapture('메시지 예약 창', desktop, (tester) async {
    await _open(tester);
    final field = find.byKey(const ValueKey('chat-input'));
    await tester.enterText(field, '내일 오전 회의 자료는 공유 폴더에 올려 두었습니다.');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const ValueKey('chat-schedule')));
    await settleGuide(tester);
    // 빠른 선택 "내일 오전 9:00"을 누른 모습.
    await tester.tap(find.text('내일 오전 9:00'));
    await settleGuide(tester);
    final message = find.byKey(const ValueKey('schedule-message'));
    await saveGuideShot(
      tester,
      'messenger-compose-schedule-editor',
      callouts: [
        GuideCallout.box(
          find.byKey(const ValueKey('schedule-room')),
          number: 2,
          badge: CalloutBadge.left,
        ),
        GuideCallout.rect(
          unionRect(tester, [
            message,
            find.byKey(const ValueKey('mention-button')).last,
          ]),
          number: 3,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(
          find.byKey(const ValueKey('schedule-attach')),
          number: 4,
          badge: CalloutBadge.left,
        ),
        GuideCallout.rect(
          unionRect(tester, [
            find.text('발송 시간'),
            find.text('다음 주 월요일 오전 9:00'),
            find.byKey(const ValueKey('schedule-time-hint')),
          ], padding: 6),
          number: 5,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(buttonWith('예약'), number: 6, badge: CalloutBadge.top),
      ],
      crop: cropAround(tester, [dialogCard], margin: 24),
    );
  });

  guideCapture('메시지 예약 목록', desktop, (tester) async {
    await _open(tester);
    final menu = topBarButton('메뉴');
    await tester.tap(menu);
    await settleGuide(tester);
    final tile = find.byKey(const ValueKey('menu-schedule'));
    await saveGuideShot(
      tester,
      'messenger-compose-menu',
      callouts: [
        GuideCallout.box(menu, number: 1, badge: CalloutBadge.left),
        GuideCallout.box(tile, number: 2, badge: CalloutBadge.left),
      ],
      crop: clampToScreen(
        tester,
        cropAround(tester, [
          menu,
          find.byKey(const ValueKey('menu-myposts')),
        ], margin: 30),
      ),
    );
    await tester.tap(tile);
    await settleGuide(tester);
    final panel = byTypeName('ScheduledPanel');
    final panelRect = tester.getRect(panel);
    // 두 번째 카드의 ⋯ 메뉴를 연 모습(메뉴 글자는 글꼴 이름 없이 그려져서 덧그린다).
    await tester.tap(find.byKey(const ValueKey('scheduled-panel-more-s1')));
    await tester.pump(const Duration(milliseconds: 300));
    final items = find.byType(MenuItemButton);
    final menuRect = unionRect(tester, [items.first, items.last], padding: 6);
    patchUnnamedFontText(tester, within: items);
    await tester.pump();
    await saveGuideShot(
      tester,
      'messenger-compose-schedule-list',
      callouts: [
        GuideCallout.box(
          find.byKey(const ValueKey('scheduled-panel-create')),
          number: 3,
          badge: CalloutBadge.left,
          padding: 2,
        ),
        GuideCallout.rect(
          unionRect(tester, [
            find.byKey(const ValueKey('scheduled-panel-room')),
            find.byKey(const ValueKey('scheduled-panel-status')),
          ], padding: 3),
          number: 4,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(
          find.byKey(const ValueKey('scheduled-panel-card-s-fail')),
          number: 5,
          badge: CalloutBadge.left,
          padding: 1,
        ),
        GuideCallout.box(
          find.byKey(const ValueKey('scheduled-panel-more-s1')),
          number: 6,
          badge: CalloutBadge.top,
          padding: 0,
        ),
        GuideCallout.rect(menuRect, number: 7, badge: CalloutBadge.left),
      ],
      crop: clampToScreen(
        tester,
        Rect.fromLTRB(panelRect.left - 30, panelRect.top, panelRect.right, 800),
      ),
    );
    clearTextPatches();
  });

  // ── 4. 메시지 보내기 › 멘션 ──

  guideCapture('멘션 자동완성', compact, (tester) async {
    await _open(tester);
    final field = find.byKey(const ValueKey('chat-input'));
    await tester.enterText(field, '회의 시간 확인 부탁드려요 @');
    await tester.pump(const Duration(milliseconds: 300));
    await settleGuide(tester);
    final rows = byTypeName('_MentionRow');
    final input = tester.getRect(find.byType(ChatInputBar));
    final list = unionRect(tester, [rows.first, rows.last], padding: 2);
    await saveGuideShot(
      tester,
      'messenger-compose-mention',
      callouts: [
        GuideCallout.box(
          field,
          number: 1,
          badge: CalloutBadge.right,
          padding: 2,
        ),
        GuideCallout.box(
          rows.first,
          number: 2,
          badge: CalloutBadge.right,
          padding: 0,
        ),
        GuideCallout.box(
          rows.at(1),
          number: 3,
          badge: CalloutBadge.right,
          padding: 0,
        ),
      ],
      crop: clampToScreen(
        tester,
        Rect.fromLTRB(input.left, list.top - 24, input.right, input.bottom),
      ),
    );
  });

  guideCapture('멘션 받은 메시지', compact, (tester) async {
    final api = _composeApi(
      extra: (api) => api.get('/api/rooms/r-mkt/messages', (_) {
        final list = marketingMessages();
        list.add(
          message(
              'm7',
              'r-mkt',
              doHyun,
              at(10, 42),
              text: '@김민지 기획안에 일정표 한 장만 추가해 주세요.',
            )
            ..['mentions'] = [
              {'type': 'user', 'userId': me.id, 's': 0, 'e': 4},
            ],
        );
        return list;
      }),
    );
    await _open(
      tester,
      api: api,
      prepare: (session) {
        final weekly = session.rooms.firstWhere((r) => r.id == 'r-weekly');
        weekly.unreadMentionCount = 1;
      },
    );
    final bubble = bubbleBoxOf('기획안에 일정표');
    final marker = find.byKey(const ValueKey('mention-marker'));
    await saveGuideShot(
      tester,
      'messenger-compose-mention-received',
      callouts: [
        GuideCallout.box(
          marker,
          number: 1,
          badge: CalloutBadge.bottom,
          padding: 3,
        ),
        GuideCallout.box(
          bubble,
          number: 2,
          badge: CalloutBadge.left,
          padding: 3,
        ),
      ],
      crop: clampToScreen(
        tester,
        Rect.fromLTRB(
          0,
          tester.getRect(textIn(sidebar, '토픽 4')).top - 16,
          tester.getRect(bubble).right + 100,
          tester.getRect(bubble).bottom + 30,
        ),
      ),
    );
  });

  // ── 6. 알림 › 알림 센터의 멘션 · 보드 알림 ──

  guideCapture('알림 센터 멘션 탭', desktop, (tester) async {
    await _open(tester);
    final bell = topBarButton('알림 센터');
    await tester.tap(bell);
    await settleGuide(tester);
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('notif-tab-mention')),
        matching: find.text('멘션'),
      ),
    );
    await settleGuide(tester);
    final panel = byTypeName('NotificationsPanel');
    final panelRect = tester.getRect(panel);
    await saveGuideShot(
      tester,
      'messenger-compose-notif-mention',
      callouts: [
        GuideCallout.box(
          find.byKey(const ValueKey('notif-tabs')),
          number: 1,
          badge: CalloutBadge.left,
          padding: 0,
        ),
        GuideCallout.box(
          find.byKey(const ValueKey('notif-mention-filter')),
          number: 2,
          badge: CalloutBadge.bottom,
          padding: 0,
        ),
        GuideCallout.box(
          find.byKey(const ValueKey('notif-n1')),
          number: 3,
          badge: CalloutBadge.left,
          padding: 0,
        ),
        GuideCallout.box(
          find.byKey(const ValueKey('notif-read-all')),
          number: 4,
          badge: CalloutBadge.left,
          padding: 0,
        ),
        GuideCallout.box(
          find.byKey(const ValueKey('notif-settings')),
          number: 5,
          badge: CalloutBadge.left,
          padding: 0,
        ),
      ],
      crop: clampToScreen(
        tester,
        Rect.fromLTRB(
          panelRect.left - 40,
          panelRect.top,
          1280,
          panelRect.top + 470,
        ),
      ),
    );
  });

  guideCapture('알림 설정', desktop, (tester) async {
    await _open(tester);
    await tester.tap(topBarButton('알림 센터'));
    await settleGuide(tester);
    await tester.tap(find.byKey(const ValueKey('notif-settings')));
    await settleGuide(tester);
    final dialog = find.byType(AlertDialog);
    await saveGuideShot(
      tester,
      'messenger-compose-notif-settings',
      callouts: [
        GuideCallout.rect(
          unionRect(tester, [
            find.descendant(of: dialog, matching: find.text('안 읽은 알림만 표시')),
            find.byKey(const ValueKey('notif-setting-unread-only-project')),
          ], padding: 4),
          number: 1,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(
          find.byKey(const ValueKey('notif-setting-mention-all')),
          number: 2,
          badge: CalloutBadge.left,
          padding: 2,
        ),
        GuideCallout.rect(
          unionRect(tester, [
            find.descendant(of: dialog, matching: find.text('보드 알림')),
            find.byKey(const ValueKey('notif-setting-board-new')),
          ], padding: 4),
          number: 3,
          badge: CalloutBadge.left,
        ),
      ],
      crop: cropAround(tester, [dialogCard], margin: 24),
    );
  });

  // ── 4. 메시지 보내기 › 표 붙여넣기 ──

  guideCapture('표 붙여넣기', compact, (tester) async {
    mockPathProvider(tester);
    // 붙여넣을 때 읽는 클립보드를 엑셀에서 복사한 것 같은 탭 글자로 바꾼다(테스트용으로 열어 둔 자리).
    // ignore: invalid_use_of_visible_for_testing_member
    final original = ChatInputBar.clipboardReader;
    // ignore: invalid_use_of_visible_for_testing_member
    addTearDown(() => ChatInputBar.clipboardReader = original);
    // ignore: invalid_use_of_visible_for_testing_member
    ChatInputBar.clipboardReader = () async => const ClipboardSnapshot(
      text:
          '채널\t방문자\n'
          '검색 광고\t12,480\n'
          'SNS\t9,120\n'
          '이메일\t3,045\n',
    );
    await _open(tester);
    final field = find.byKey(const ValueKey('chat-input'));
    await tester.tap(field);
    await tester.pump();
    await tester.runAsync(() async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await Future<void>.delayed(const Duration(seconds: 3));
    });
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 800)),
    );
    await tester.pump();
    await settleGuide(tester);
    final input = tester.getRect(find.byType(ChatInputBar));
    final cards = find.descendant(
      of: find.byType(ChatInputBar),
      matching: find.byType(ListView),
    );
    final cardsRect = tester.getRect(cards);
    await saveGuideShot(
      tester,
      'messenger-compose-table-paste',
      callouts: [
        GuideCallout.rect(
          Rect.fromLTRB(
            cardsRect.left,
            cardsRect.top,
            cardsRect.left + 170,
            cardsRect.bottom,
          ).inflate(4),
          number: 1,
          badge: CalloutBadge.right,
        ),
        GuideCallout.box(
          find.byTooltip('보내기'),
          number: 2,
          badge: CalloutBadge.top,
        ),
      ],
      crop: clampToScreen(
        tester,
        Rect.fromLTRB(input.left, input.top - 16, input.right, input.bottom),
      ),
    );
  });

  // ── 4. 메시지 보내기 › 새 이모티콘 세트 ──

  guideCapture('그림 이모티콘 세트', compact, (tester) async {
    final stickers = _ddungStickers();
    for (final (id, image) in stickers) {
      await _seedSticker(tester, id, image, logicalSizes: const [64, null]);
    }
    final session = await _open(tester);
    serverStickers.replace([
      ServerStickerPack.fromJson(_packJson('p-dd', '뚕뚕', 'sticker', stickers)),
    ], session.resolveUrl);
    addTearDown(() => serverStickers.replace(const [], (u) => u));
    await settleGuide(tester);
    await tester.tap(find.byTooltip('이모티콘'));
    await settleGuide(tester);
    final picker = byTypeName('StickerPicker');
    final pickerRect = tester.getRect(picker);
    final input = tester.getRect(find.byType(ChatInputBar));
    final tab = find.descendant(of: picker, matching: find.text('뚕뚕'));
    await saveGuideShot(
      tester,
      'messenger-compose-sticker-set',
      callouts: [
        GuideCallout.box(
          tab,
          number: 1,
          badge: CalloutBadge.bottom,
          padding: 6,
        ),
        GuideCallout.box(
          find.byTooltip('이모티콘'),
          number: 2,
          badge: CalloutBadge.topRight,
        ),
      ],
      palette: false,
      crop: clampToScreen(
        tester,
        Rect.fromLTRB(
          input.left,
          pickerRect.top - 24,
          pickerRect.right + 24,
          input.bottom,
        ),
      ),
    );
  });

  guideCapture('캐릭터 프로필 사진', const GuideSurface(Size(720, 720)), (
    tester,
  ) async {
    final chars = _characterSet();
    for (final (id, image) in chars) {
      await _seedSticker(tester, id, image, logicalSizes: const [44, null]);
    }
    final api = _composeApi(
      extra: (api) => api.get('/api/stickers', [
        _packJson('p-ch', '뚕뚕 캐릭터', 'character', chars),
      ]),
    );
    final session = demoSession(api: api);
    ignoreBenignErrors();
    await pumpGuideApp(
      tester,
      Scaffold(
        body: Center(child: CharacterPickerDialog(session: session)),
      ),
    );
    await tester.tap(find.text('뚕뚕 캐릭터').first);
    await settleGuide(tester);
    final circles = byTypeName('_PickCircle');
    await tester.tap(circles.at(2));
    await settleGuide(tester);
    final dialog = find.byType(Dialog);
    await saveGuideShot(
      tester,
      'messenger-compose-character',
      callouts: [
        GuideCallout.box(
          find.descendant(of: dialog, matching: find.text('뚕뚕 캐릭터')).first,
          number: 1,
          badge: CalloutBadge.right,
          padding: 6,
        ),
        GuideCallout.box(
          circles.at(2),
          number: 2,
          badge: CalloutBadge.bottom,
          padding: 2,
        ),
        GuideCallout.box(
          buttonWith('확인'),
          number: 3,
          badge: CalloutBadge.right,
        ),
      ],
      palette: false,
      crop: cropAround(tester, [dialogCard], margin: 24),
    );
  });

  // ── 5. 메시지 활용하기 › 사진·파일 메시지 고치기, 파일 삭제 ──

  guideCapture('첨부 고치기', compact, (tester) async {
    final api = _composeApi(
      extra: (api) => api.get('/api/rooms/r-mkt/messages', (_) {
        final list = marketingMessages();
        final files = message(
          'm8',
          'r-mkt',
          me,
          at(10, 20),
          type: 'file',
          text: '회의 자료 세 가지 올립니다.',
          fileName: '회의_안건.docx',
        );
        files['attachments'] = [
          for (final (i, name) in [
            '회의_안건.docx',
            '캠페인_일정표.xlsx',
            '예전_시안.pdf',
          ].indexed)
            {
              'id': 'm8-a$i',
              'kind': 'file',
              'fileUrl': '/uploads/m8-$i',
              'fileName': name,
              'fileSize': (i + 1) * 240 * 1024,
            },
        ];
        list.add(files);
        return list;
      }),
    );
    await _open(tester, api: api, prepare: _allowLateEdits);
    final caption = find.textContaining('회의 자료 세 가지', findRichText: true).first;
    final gesture = await mouseAt(tester, tester.getRect(caption).center);
    await tester.pump(const Duration(milliseconds: 200));
    final more = find.descendant(
      of: find.byType(HoverToolbar),
      matching: find.byIcon(Icons.more_vert),
    );
    await tester.tap(more.last);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('수정').last);
    await settleGuide(tester);
    final remove = find.byTooltip('첨부 삭제');
    await tester.tap(remove.at(2));
    await settleGuide(tester);
    // 말풍선 위 도구 상자가 첨부를 가리지 않게 마우스를 사이드바로 옮긴다.
    await gesture.moveTo(const Offset(100, 600));
    await tester.pump(const Duration(milliseconds: 300));
    final strip = byTypeName('EditAttachmentStrip');
    final editor = find
        .ancestor(of: strip, matching: find.byType(MessageBubble))
        .first;
    final editorRect = tester.getRect(editor);
    await saveGuideShot(
      tester,
      'messenger-compose-edit-attachments',
      callouts: [
        GuideCallout.box(
          remove.first,
          number: 1,
          badge: CalloutBadge.top,
          padding: 1,
        ),
        GuideCallout.box(
          find.byKey(const ValueKey('edit-attachment-m8-a2')),
          number: 2,
          badge: CalloutBadge.bottom,
          padding: 3,
        ),
        GuideCallout.box(
          buttonWith('저장'),
          number: 3,
          badge: CalloutBadge.right,
        ),
      ],
      crop: clampToScreen(
        tester,
        Rect.fromLTRB(282, editorRect.top - 20, 1000, editorRect.bottom + 16),
      ),
    );
  });

  guideCapture('파일 삭제', compact, (tester) async {
    final api = _composeApi(
      extra: (api) => api.get('/api/rooms/r-mkt/messages', (_) {
        final list = marketingMessages();
        final files = message(
          'm9',
          'r-mkt',
          me,
          at(10, 20),
          type: 'file',
          text: '배너 시안 1차·2차입니다.',
          fileName: '배너_시안_v2.pdf',
        );
        files['attachments'] = [
          {
            'id': 'm9-a0',
            'kind': 'file',
            'fileUrl': '',
            'fileName': '배너_시안_v1.pdf',
            'deleted': true,
          },
          {
            'id': 'm9-a1',
            'kind': 'file',
            'fileUrl': '/uploads/m9-1',
            'fileName': '배너_시안_v2.pdf',
            'fileSize': 820 * 1024,
          },
        ];
        list.add(files);
        return list;
      }),
    );
    await _open(tester, api: api);
    final deleted = find.byKey(const ValueKey('deleted-file-card'));
    final file = find.text('배너_시안_v2.pdf').last;
    await mouseAt(tester, tester.getRect(file).center);
    await tester.pump(const Duration(milliseconds: 200));
    // 파일 칸에 마우스를 올리면 그 칸 오른쪽 위에 다운로드 · ⋮(더보기)가 뜬다 — 말풍선의 ⋮와 다르다.
    final more = find.descendant(
      of: find.ancestor(of: file, matching: find.byType(DownloadableFile)),
      matching: find.byTooltip('더보기'),
    );
    await tester.tap(more.last);
    await tester.pump(const Duration(milliseconds: 300));
    final items = find.byType(MenuItemButton);
    final delete = find.ancestor(
      of: find.text('삭제'),
      matching: find.byType(MenuItemButton),
    );
    final menu = unionRect(tester, [items.first, items.last], padding: 8);
    final deleteRect = tester.getRect(delete).inflate(1);
    final deletedRect = tester.getRect(deleted);
    patchUnnamedFontText(tester, within: items);
    await tester.pump();
    await saveGuideShot(
      tester,
      'messenger-compose-file-delete',
      callouts: [
        GuideCallout.box(
          more.last,
          number: 1,
          badge: CalloutBadge.bottom,
          padding: 1,
        ),
        GuideCallout.rect(deleteRect, number: 2, badge: CalloutBadge.right),
        GuideCallout.box(
          deleted,
          number: 3,
          badge: CalloutBadge.left,
          padding: 3,
        ),
      ],
      crop: clampToScreen(
        tester,
        Rect.fromLTRB(
          282,
          math.min(menu.top, deletedRect.top) - 50,
          math.max(menu.right, deletedRect.right) + 60,
          math.max(menu.bottom, deletedRect.bottom) + 70,
        ),
      ),
    );
    clearTextPatches();
  });

  // ── 9. 공지 › 공지 댓글 ──

  guideCapture('공지 댓글', desktop, (tester) async {
    await _open(tester, roomName: '전사 공지');
    await tester.tap(find.byKey(const ValueKey('announcement-open')));
    await settleGuide(tester);
    final panel = byTypeName('AnnouncementsPanel');
    final panelRect = tester.getRect(panel);
    final field = find.descendant(of: panel, matching: find.byType(TextField));
    await tester.enterText(field.last, '저도 라운지에서 보겠습니다 🙂');
    await tester.pump(const Duration(milliseconds: 300));
    await saveGuideShot(
      tester,
      'messenger-compose-notice-comments',
      callouts: [
        GuideCallout.rect(
          unionRect(tester, [
            find.descendant(of: panel, matching: find.text(junHo.name)),
            find.textContaining('10분 전까지'),
          ], padding: 8),
          number: 1,
          badge: CalloutBadge.top,
        ),
        GuideCallout.box(
          field.last,
          number: 2,
          badge: CalloutBadge.top,
          padding: 2,
        ),
      ],
      crop: clampToScreen(
        tester,
        Rect.fromLTRB(panelRect.left - 30, panelRect.top, panelRect.right, 800),
      ),
    );
  });

  // ── 12. 동료와 내 프로필 › 내가 쓴 글 ──

  guideCapture('내가 쓴 글', desktop, (tester) async {
    await _open(tester);
    await tester.tap(topBarButton('메뉴'));
    await settleGuide(tester);
    await tester.tap(find.byKey(const ValueKey('menu-myposts')));
    await settleGuide(tester);
    final panel = byTypeName('MyPostsScreen');
    final panelRect = tester.getRect(panel);
    await saveGuideShot(
      tester,
      'messenger-compose-myposts',
      callouts: [
        GuideCallout.rect(
          unionRect(tester, [
            find
                .descendant(
                  of: panel,
                  matching: find.byType(FilterDropdownButton),
                )
                .first,
            find
                .descendant(
                  of: panel,
                  matching: find.byType(FilterDropdownButton),
                )
                .last,
          ], padding: 3),
          number: 1,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(
          find.byKey(const ValueKey('my-posts-kind')),
          number: 2,
          badge: CalloutBadge.left,
          padding: 2,
        ),
        GuideCallout.box(
          find.byKey(const ValueKey('my-post-c:c2')),
          number: 3,
          badge: CalloutBadge.left,
          padding: 0,
        ),
      ],
      crop: clampToScreen(
        tester,
        Rect.fromLTRB(
          panelRect.left - 30,
          panelRect.top,
          panelRect.right,
          panelRect.top + 560,
        ),
      ),
    );
  });
}
