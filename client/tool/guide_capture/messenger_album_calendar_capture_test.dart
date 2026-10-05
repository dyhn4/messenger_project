// 초보자용 도움말 "메신저 이용법"(server/guide/messenger.html)의 앨범 · 캘린더 · 즐겨찾기와 북마크 그림을 찍는다.
//
// 다시 찍기(client 폴더에서):
//   flutter test tool/guide_capture/messenger_album_calendar_capture_test.dart
// 한 장만:
//   flutter test tool/guide_capture/messenger_album_calendar_capture_test.dart --plain-name "앨범 목록"
// 결과: ../server/guide/images/messenger-album-* · messenger-calendar-* · messenger-saved-*.png
// 그림의 빨간 번호는 messenger.html의 순서 번호와 짝이 맞아야 하므로, 번호를 바꾸면 HTML도 같이 고친다.
//
// 진짜 앱 화면(DesktopHomeScreen의 앨범·즐겨찾기·북마크 패널, CalendarScreen 등)을 가짜 서버 응답
// (GuideFakeApi)과 예시 데이터(messenger_demo.dart의 탱고컴퍼니 · 김민지 등)로 채워 그린다. 앨범 사진·북마크
// 그림은 이 파일이 만든 예시 그림을 이미지 캐시에 미리 넣어 둔다(진짜 서버에 연결하지 않으므로).
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:client/models/app_user.dart';
import 'package:client/screens/calendar/calendar_screen.dart';
import 'package:client/screens/my_profile_dialog.dart';
import 'package:client/services/session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

import 'guide_capture.dart';
import 'messenger_demo.dart';

// ───────────────────────────── 예시 그림 ─────────────────────────────

/// 앨범 "사진" 한 장 — 하늘 그라데이션 · 해 · 언덕 두 겹으로 그린 풍경(번호마다 색이 다르다).
img.Image photo(int seed, {int width = 480, int height = 360}) {
  const palettes = [
    // (하늘 위, 하늘 아래, 먼 언덕, 가까운 언덕, 해)
    [0xFF5B8DEF, 0xFFBFD7FF, 0xFF7FB77E, 0xFF4E8F4A, 0xFFFFE066],
    [0xFFFF8A5B, 0xFFFFD6A5, 0xFF9C6644, 0xFF6F4E37, 0xFFFFF3B0],
    [0xFF2B2D42, 0xFF8D99AE, 0xFF4A5568, 0xFF2D3748, 0xFFF1F3F5],
    [0xFF48CAE4, 0xFFCAF0F8, 0xFFE9C46A, 0xFFF4A261, 0xFFFFFFFF],
    [0xFF9D4EDD, 0xFFFFC8DD, 0xFF6A994E, 0xFF386641, 0xFFFFD166],
    [0xFF00B4D8, 0xFFE0FBFC, 0xFF2A9D8F, 0xFF264653, 0xFFFFE8A3],
  ];
  final p = palettes[seed % palettes.length];
  img.ColorRgb8 c(int v) =>
      img.ColorRgb8((v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF);
  int mix(int a, int b, double t, int shift) =>
      (((a >> shift) & 0xFF) * (1 - t) + ((b >> shift) & 0xFF) * t).round();
  final image = img.Image(width: width, height: height);
  final rnd = math.Random(seed);
  for (var y = 0; y < height; y++) {
    final t = y / height;
    for (var x = 0; x < width; x++) {
      image.setPixelRgb(
        x,
        y,
        mix(p[0], p[1], t, 16),
        mix(p[0], p[1], t, 8),
        mix(p[0], p[1], t, 0),
      );
    }
  }
  img.fillCircle(
    image,
    x: (width * (0.25 + 0.5 * rnd.nextDouble())).round(),
    y: (height * 0.3).round(),
    radius: (height * 0.11).round(),
    color: c(p[4]),
  );
  void hill(double base, double amp, double freq, double phase, int color) {
    for (var x = 0; x < width; x++) {
      final top =
          (height * base + amp * height * math.sin(x / width * freq + phase))
              .round();
      for (var y = top.clamp(0, height); y < height; y++) {
        image.setPixel(x, y, c(color));
      }
    }
  }

  hill(0.62, 0.07, 5 + seed % 3, seed.toDouble(), p[2]);
  hill(0.78, 0.05, 3 + seed % 2, seed * 1.7, p[3]);
  return image;
}

/// 북마크 그림 — 색 바탕에 흰 도형(사이트 로고 흉내).
img.Image logo(int color, {int shape = 0}) {
  final image = img.Image(width: 160, height: 160);
  img.fill(
    image,
    color: img.ColorRgb8(
      (color >> 16) & 0xFF,
      (color >> 8) & 0xFF,
      color & 0xFF,
    ),
  );
  final white = img.ColorRgb8(255, 255, 255);
  switch (shape) {
    case 0:
      img.fillCircle(image, x: 80, y: 80, radius: 42, color: white);
    case 1:
      img.fillRect(image, x1: 44, y1: 44, x2: 116, y2: 116, color: white);
    default:
      img.fillPolygon(
        image,
        vertices: [img.Point(80, 36), img.Point(126, 120), img.Point(34, 120)],
        color: white,
      );
  }
  return image;
}

/// 화면이 `Image.network(url, cacheWidth: …)`로 그리는 그림을 이미지 캐시에 미리 넣는다 — 캐시 키가
/// cacheWidth까지 담고 있어서(ResizeImage) 화면과 같은 값으로 키를 만든다. [url]은 서버 상대 경로.
Future<void> seedImage(
  WidgetTester tester,
  Session session,
  String url,
  img.Image image, {
  int? cacheWidth,
}) async {
  final full = session.resolveUrl(url);
  final ImageProvider provider = cacheWidth == null
      ? NetworkImage(full)
      : ResizeImage(NetworkImage(full), width: cacheWidth);
  final png = img.encodePng(image);
  final decoded = await tester.runAsync(() async {
    final codec = await ui.instantiateImageCodec(png);
    try {
      return (await codec.getNextFrame()).image;
    } finally {
      codec.dispose();
    }
  });
  final key = await provider.obtainKey(ImageConfiguration.empty);
  PaintingBinding.instance.imageCache.putIfAbsent(
    key,
    () => OneFrameImageStreamCompleter(
      SynchronousFuture(ImageInfo(image: decoded!)),
    ),
  );
}

// ───────────────────────────── 앨범 데이터 ─────────────────────────────

int ms(DateTime d) => d.millisecondsSinceEpoch;

/// 앨범 하나(서버 GET /api/albums의 항목 모양). 나(김민지)가 만든 앨범은 고치기·지우기까지 된다.
Map<String, dynamic> albumJson(
  String id,
  String title, {
  required String roomId,
  required String roomName,
  required AppUser creator,
  required int count,
  required DateTime created,
  DateTime? updated,
  String? description,
  bool cover = true,
}) {
  final mine = creator.id == me.id;
  return {
    'id': id,
    'teamId': tango.id,
    'roomId': roomId,
    'roomName': roomName,
    'creatorId': creator.id,
    'creatorName': creator.name,
    'title': title,
    'description': ?description,
    'coverItemId': cover ? 'cover-$id' : null,
    'coverUrl': cover ? '/files/album/$id-cover.jpg' : null,
    'itemCount': count,
    'createdAt': ms(created),
    'updatedAt': ms(updated ?? created),
    'canEdit': mine,
    'canDelete': mine,
    'canDeleteAnyItem': mine,
    'canShare': true,
  };
}

const workshopTitle = '9월 팀 워크숍';

/// 앨범 id → 대표 이미지 그림 번호.
const albumCoverSeeds = {
  'al-workshop': 0,
  'al-shoot': 3,
  'al-campaign': 1,
  'al-hiking': 4,
};

List<Map<String, dynamic>> demoAlbums() => [
  albumJson(
    'al-workshop',
    workshopTitle,
    roomId: 'r-mkt',
    roomName: '마케팅팀',
    creator: me,
    count: 12,
    created: DateTime(2026, 9, 19, 18, 0),
    updated: DateTime(2026, 9, 29, 9, 0),
    description: '양평 워크숍에서 찍은 사진과 영상을 모았습니다. 자유롭게 올려 주세요!',
  ),
  albumJson(
    'al-shoot',
    '신제품 촬영 B컷',
    roomId: 'r-launch',
    roomName: '신제품 런칭',
    creator: doHyun,
    count: 38,
    created: DateTime(2026, 9, 22, 14, 0),
    updated: DateTime(2026, 9, 28, 17, 0),
  ),
  albumJson(
    'al-campaign',
    '3분기 캠페인 현장',
    roomId: 'r-tf',
    roomName: '3분기 캠페인 TF',
    creator: jiWoo,
    count: 15,
    created: DateTime(2026, 9, 10, 11, 0),
    updated: DateTime(2026, 9, 26, 16, 0),
  ),
  albumJson(
    'al-hiking',
    '사내 동호회 가을 산행',
    roomId: 'r-mkt',
    roomName: '마케팅팀',
    creator: junHo,
    count: 9,
    created: DateTime(2026, 9, 5, 9, 0),
    updated: DateTime(2026, 9, 20, 12, 0),
  ),
];

/// 워크숍 앨범의 사진·영상 12개 — 4번째는 영상(1분 23초), 7번째는 GIF.
List<Map<String, dynamic>> workshopItems() => [
  for (var i = 0; i < 12; i++)
    {
      'id': 'it$i',
      'albumId': 'al-workshop',
      'uploaderId': i.isEven ? me.id : doHyun.id,
      'uploaderName': i.isEven ? me.name : doHyun.name,
      'kind': i == 3 ? 'video' : 'image',
      'fileUrl': '/files/album/it$i${_ext(i)}',
      'fileName': 'workshop_$i${_ext(i)}',
      'fileSize': 2 * 1024 * 1024,
      'mimeType': i == 3 ? 'video/mp4' : (i == 6 ? 'image/gif' : 'image/jpeg'),
      'thumbnailUrl': '/files/album/it$i-thumb.jpg',
      'width': 1600,
      'height': 1200,
      if (i == 3) 'durationMs': 83000,
      'createdAt': ms(DateTime(2026, 9, 19, 15, i)),
      'canDelete': true,
    },
];

String _ext(int i) => i == 3 ? '.mp4' : (i == 6 ? '.gif' : '.jpg');

/// 앨범 화면이 부르는 API — 앨범 목록 · 상세 · 항목.
void albumRoutes(GuideFakeApi api) {
  api
    ..get('/api/albums', (_) => {'albums': demoAlbums(), 'hasMore': false})
    ..get(
      '/api/albums/:id',
      (req) =>
          demoAlbums().firstWhere((a) => a['id'] == req.url.pathSegments.last),
    )
    ..get(
      '/api/albums/:id/items',
      (_) => {'items': workshopItems(), 'hasMore': false},
    );
}

/// 앨범 대표 이미지(카드는 cacheWidth 400, "앨범 공유" 창의 카드는 120)와 항목 썸네일(격자는 300)을 캐시에 넣는다.
Future<void> seedAlbumImages(WidgetTester tester, Session session) async {
  for (final MapEntry(key: id, value: seed) in albumCoverSeeds.entries) {
    final cover = '/files/album/$id-cover.jpg';
    await seedImage(tester, session, cover, photo(seed), cacheWidth: 400);
    await seedImage(tester, session, cover, photo(seed), cacheWidth: 120);
  }
  for (var i = 0; i < 12; i++) {
    await seedImage(
      tester,
      session,
      '/files/album/it$i-thumb.jpg',
      photo(i + 2, width: 300, height: 300),
      cacheWidth: 300,
    );
  }
}

/// 앨범 예시가 들어간 PC 화면을 띄우고 메뉴 › 앨범으로 앨범 패널을 연다.
Future<Session> openAlbums(
  WidgetTester tester, {
  void Function(GuideFakeApi api)? extra,
  String? roomName,
}) async {
  final api = demoApi(
    extra: (api) {
      extra?.call(api);
      albumRoutes(api);
    },
  );
  final session = demoSession(api: api);
  await seedAlbumImages(tester, session);
  await openDesktop(tester, roomName: roomName, session: session);
  await tester.tap(topBarButton('메뉴'));
  await settleGuide(tester);
  await tester.tap(find.byKey(const ValueKey('menu-albums')));
  await settleGuide(tester);
  return session;
}

Finder byKey(String key) => find.byKey(ValueKey(key));

// ───────────────────────────── 캘린더 데이터 ─────────────────────────────

/// 캘린더 그림의 "오늘" — 2026년 10월 7일(수) 오전 10시. 날짜를 고정해서 다시 찍어도 같은 달이 나오게 한다.
final calendarToday = DateTime(2026, 10, 7, 10);

const tall = GuideSurface(Size(1280, 1000));

Map<String, dynamic> calendarJson(
  String id,
  String kind,
  String name,
  String color, {
  String role = 'admin',
  bool canCreate = true,
  bool canEditSettings = false,
  bool canDelete = false,
  AppUser? owner,
  bool isPublic = true,
}) => {
  'id': id,
  'teamId': tango.id,
  'kind': kind,
  'name': name,
  'color': color,
  'defaultColor': color,
  'isPublic': isPublic,
  'ownerId': owner?.id,
  'ownerName': owner?.name,
  'role': role,
  'hidden': false,
  'canCreateEvents': canCreate,
  'canDelete': canDelete,
  'canEditSettings': canEditSettings,
};

const _calColors = {
  'cal-me': '#4C6EF5',
  'cal-team': '#12B886',
  'cal-mkt': '#F59F00',
  'cal-dh': '#7950F2',
};

/// 나의 캘린더(기본 · 팀 · 공유)와 구독 캘린더(이도현의 기본 캘린더). 국가 공휴일 · 멤버 생일은 앱이 붙인다.
Map<String, dynamic> demoCalendars() => {
  'mine': [
    calendarJson(
      'cal-me',
      'personal',
      me.name,
      _calColors['cal-me']!,
      canEditSettings: true,
      owner: me,
    ),
    calendarJson(
      'cal-team',
      'team',
      '팀 캘린더',
      _calColors['cal-team']!,
      role: 'read',
      canCreate: false,
    ),
    calendarJson(
      'cal-mkt',
      'shared',
      '마케팅팀 일정',
      _calColors['cal-mkt']!,
      canEditSettings: true,
      canDelete: true,
      owner: me,
    ),
  ],
  'subscribed': [
    calendarJson(
      'cal-dh',
      'personal',
      doHyun.name,
      _calColors['cal-dh']!,
      role: 'subscriber',
      canCreate: false,
      owner: doHyun,
    ),
  ],
};

int _utcDay(DateTime d) =>
    DateTime.utc(d.year, d.month, d.day).millisecondsSinceEpoch;

/// 일정 한 회차(GET .../calendar/events의 항목). 종일 일정은 [last]까지(포함).
Map<String, dynamic> eventJson(
  String id,
  String calendarId,
  String title,
  DateTime start, {
  DateTime? end,
  DateTime? last,
  bool allDay = false,
  String source = 'event',
  String? location,
  String? description,
  List<AppUser> attendees = const [],
  AppUser? creator,
  bool canEdit = true,
  Map<String, dynamic>? recurrence,
}) {
  final color = switch (source) {
    'holiday' => '#E53935',
    'birthday' => '#F06292',
    _ => _calColors[calendarId] ?? '#4285F4',
  };
  return {
    'key': '$id:${allDay ? _utcDay(start) : ms(start)}',
    'eventId': source == 'event' ? id : null,
    'calendarId': calendarId,
    'source': source,
    'title': title,
    'description': description,
    'location': location,
    'start': allDay ? _utcDay(start) : ms(start),
    'end': allDay
        ? _utcDay((last ?? start).add(const Duration(days: 1)))
        : ms(end!),
    'allDay': allDay,
    'visibility': 'public',
    'restricted': false,
    'recurring': recurrence != null,
    'recurrence': recurrence,
    'creatorId': source == 'event' ? (creator ?? me).id : null,
    'creatorName': source == 'event' ? (creator ?? me).name : null,
    'attendees': [
      for (final a in attendees) {'userId': a.id, 'name': a.name},
    ],
    'color': color,
    'canEdit': source == 'event' && canEdit,
    'canDelete': source == 'event' && canEdit,
  };
}

DateTime _d(int month, int day, [int h = 0, int m = 0]) =>
    DateTime(2026, month, day, h, m);

final _checkMeeting = eventJson(
  'ev-check',
  'cal-me',
  '캠페인 중간 점검',
  _d(10, 7, 14),
  end: _d(10, 7, 15),
  location: '회의실 A',
  description: '3분기 캠페인 성과 지표와 남은 일정을 함께 확인합니다.',
  attendees: [doHyun, seoYeon, junHo],
);

/// 2026년 10월(달력 격자의 앞뒤 날짜 포함) 일정 — 공휴일 · 생일 · 반복 일정 · 여러 날 일정이 섞여 있다.
List<Map<String, dynamic>> demoEvents() => [
  eventJson(
    'hol-1003',
    'holidays',
    '개천절',
    _d(10, 3),
    allDay: true,
    source: 'holiday',
  ),
  eventJson(
    'hol-1005',
    'holidays',
    '대체공휴일(개천절)',
    _d(10, 5),
    allDay: true,
    source: 'holiday',
  ),
  eventJson(
    'hol-1009',
    'holidays',
    '한글날',
    _d(10, 9),
    allDay: true,
    source: 'holiday',
  ),
  eventJson(
    'bd-sy',
    'birthdays',
    '${seoYeon.name} 님의 생일',
    _d(10, 14),
    allDay: true,
    source: 'birthday',
  ),
  eventJson(
    'ev-townhall',
    'cal-team',
    '전 직원 타운홀 미팅',
    _d(10, 2, 15),
    end: _d(10, 2, 16),
    location: '대회의실',
    creator: yuNa,
    canEdit: false,
  ),
  for (final day in [28, 5, 12, 19, 26])
    eventJson(
      'ev-weekly',
      'cal-mkt',
      '주간회의',
      day == 28 ? _d(9, 28, 10) : _d(10, day, 10),
      end: day == 28 ? _d(9, 28, 11) : _d(10, day, 11),
      creator: doHyun,
      recurrence: {
        'freq': 'weekly',
        'interval': 1,
        'byWeekday': [1],
      },
    ),
  eventJson('ev-lunch', 'cal-me', '디자인팀 점심', _d(10, 7, 12), end: _d(10, 7, 13)),
  _checkMeeting,
  eventJson(
    'ev-client',
    'cal-dh',
    '고객사 미팅',
    _d(10, 8, 11),
    end: _d(10, 8, 12),
    creator: doHyun,
    canEdit: false,
  ),
  eventJson(
    'ev-leave',
    'cal-me',
    '연차 휴가',
    _d(10, 15),
    last: _d(10, 16),
    allDay: true,
  ),
  eventJson(
    'ev-banner',
    'cal-mkt',
    '배너 시안 리뷰',
    _d(10, 16, 16),
    end: _d(10, 16, 17),
  ),
  eventJson(
    'ev-launch',
    'cal-mkt',
    '신제품 런칭 행사 준비',
    _d(10, 20),
    last: _d(10, 22),
    allDay: true,
  ),
  eventJson(
    'ev-edu',
    'cal-team',
    '하반기 정보보안 교육',
    _d(10, 23, 13, 30),
    end: _d(10, 23, 15, 30),
    creator: yuNa,
    canEdit: false,
  ),
  eventJson(
    'ev-dinner',
    'cal-team',
    '10월 회식',
    _d(10, 30, 18, 30),
    end: _d(10, 30, 21),
    creator: doHyun,
    canEdit: false,
  ),
];

/// 일정 제목 검색 결과(GET .../calendar/search) — "캠페인".
Map<String, dynamic> calendarSearchResult() {
  Map<String, dynamic> item(
    String id,
    String calendarId,
    String calendarName,
    String title,
    DateTime start,
    DateTime end, {
    List<AppUser> attendees = const [],
  }) => {
    'eventId': id,
    'calendarId': calendarId,
    'calendarName': calendarName,
    'color': _calColors[calendarId],
    'title': title,
    'start': ms(start),
    'end': ms(end),
    'allDay': false,
    'recurring': false,
    'attendees': [
      for (final a in attendees) {'userId': a.id, 'name': a.name},
    ],
    'creatorName': me.name,
    'canEdit': true,
  };
  return {
    'items': [
      item(
        'ev-report',
        'cal-team',
        '팀 캘린더',
        '3분기 캠페인 결과 보고',
        _d(11, 3, 10),
        _d(11, 3, 11),
      ),
      item(
        'ev-check',
        'cal-me',
        me.name,
        '캠페인 중간 점검',
        _d(10, 7, 14),
        _d(10, 7, 15),
        attendees: [doHyun, seoYeon, junHo],
      ),
      item(
        'ev-kickoff',
        'cal-mkt',
        '마케팅팀 일정',
        '3분기 캠페인 킥오프',
        _d(7, 14, 10),
        _d(7, 14, 11, 30),
        attendees: [doHyun, jiWoo],
      ),
    ],
    'nextBefore': null,
  };
}

/// 캘린더 화면이 부르는 API.
void calendarRoutes(GuideFakeApi api) {
  api
    ..get('/api/teams/:id/calendars', (_) => demoCalendars())
    ..get('/api/teams/:id/calendar/events', (_) => demoEvents())
    ..get('/api/teams/:id/calendar/search', (_) => calendarSearchResult())
    ..get('/api/events/:id', (_) => _checkMeeting)
    ..get('/api/calendars/:id/members', [
      {'userId': me.id, 'name': me.name, 'role': 'admin', 'isOwner': true},
      {
        'userId': doHyun.id,
        'name': doHyun.name,
        'role': 'write',
        'isOwner': false,
      },
      {
        'userId': junHo.id,
        'name': junHo.name,
        'role': 'write',
        'isOwner': false,
      },
      {
        'userId': seoYeon.id,
        'name': seoYeon.name,
        'role': 'read',
        'isOwner': false,
      },
    ]);
}

/// 캘린더 화면(PC — 메뉴 › 캘린더로 대화 목록·채팅 자리에 열리는 모양)을 띄운다. "오늘"을 [calendarToday]로 고정하려고
/// 홈 화면 대신 캘린더 화면만 올린다.
Future<Session> openCalendar(WidgetTester tester) async {
  ignoreBenignErrors();
  final session = demoSession(api: demoApi(extra: calendarRoutes));
  await pumpGuideApp(
    tester,
    CalendarScreen(session: session, embedded: true, now: calendarToday),
  );
  await settleGuide(tester);
  return session;
}

// ───────────────────────────── 즐겨찾기 · 북마크 데이터 ─────────────────────────────

/// 통합 즐겨찾기 목록(GET /api/favorites의 items) — 메시지 · 파일 · 댓글 · 대화방 · 멤버.
List<Map<String, dynamic>> demoFavorites() {
  final msgs = marketingMessages(withComments: true);
  final greeting = msgs.firstWhere((m) => m['id'] == 'm1');
  final plan = msgs.firstWhere((m) => m['id'] == 'm3');
  return [
    {
      'type': 'message',
      'favoritedAt': ms(at(9, 35)),
      'roomId': 'r-mkt',
      'roomName': '마케팅팀',
      'message': greeting,
    },
    {
      'type': 'file',
      'favoritedAt': ms(at(9, 45)),
      'roomId': 'r-mkt',
      'roomName': '마케팅팀',
      'message': plan,
      'fileUrl': '/uploads/m3',
      'fileName': planFile,
    },
    {
      'type': 'comment',
      'favoritedAt': ms(at(9, 53)),
      'roomId': 'r-mkt',
      'roomName': '마케팅팀',
      'comment': comment(
        'c1',
        'm3',
        doHyun,
        at(9, 52),
        '잘 봤어요. 일정표만 한 장 추가해 주세요.',
      ),
      'parentMessage': {
        'senderName': me.name,
        'text': '기획안 초안 공유드립니다. 검토 부탁드려요!',
      },
    },
    {
      'type': 'room',
      'roomId': 'r-notice',
      'roomName': '전사 공지',
      'roomType': 'topic',
    },
    {
      'type': 'member',
      'favoritedAt': ms(at(16, 0, day: 25)),
      'teamId': tango.id,
      'user': userJson(seoYeon),
    },
  ];
}

Map<String, dynamic> bookmarkJson(
  String id,
  String kind,
  String title,
  String url, {
  String? image,
  int position = 0,
  AppUser? creator,
  bool canEdit = false,
}) => {
  'id': id,
  'teamId': tango.id,
  'kind': kind,
  'title': title,
  'url': url,
  'imageUrl': image,
  'position': position,
  'creator': {'id': (creator ?? me).id, 'name': (creator ?? me).name},
  'canEdit': canEdit,
  'canReorder': kind == 'personal',
};

/// 북마크 이미지(직접 올린 사진 — 서버의 /files/… 링크).
const bookmarkLogos = {
  '/files/bm/wiki.png': (0xFF4263EB, 0),
  '/files/bm/figma.png': (0xFFE64980, 2),
  '/files/bm/dashboard.png': (0xFF1FAE85, 1),
  '/files/bm/preview.png': (0xFF212529, 1),
};

Future<void> seedBookmarkImages(WidgetTester tester, Session session) async {
  for (final MapEntry(key: url, value: (color, shape))
      in bookmarkLogos.entries) {
    await seedImage(tester, session, url, logo(color, shape: shape));
  }
}

/// 즐겨찾기 · 북마크 패널이 부르는 API.
void savedRoutes(GuideFakeApi api) {
  api
    ..get('/api/favorites/ids', {
      'messages': ['m1'],
      'comments': ['c1'],
      'members': [
        {'teamId': tango.id, 'userId': seoYeon.id},
      ],
    })
    ..get('/api/favorites', (_) => {'items': demoFavorites(), 'hasMore': false})
    ..get('/api/bookmarks', {
      'team': [
        bookmarkJson(
          'bm-wiki',
          'team',
          '사내 위키',
          'https://wiki.tango.example/home',
          image: '/files/bm/wiki.png',
          creator: yuNa,
        ),
        bookmarkJson(
          'bm-figma',
          'team',
          '브랜드 디자인 가이드',
          'https://www.figma.com/file/tango-brand',
          image: '/files/bm/figma.png',
          position: 1,
          canEdit: true,
        ),
        bookmarkJson(
          'bm-dash',
          'team',
          '3분기 캠페인 대시보드',
          'https://analytics.tango.example/q3',
          image: '/files/bm/dashboard.png',
          position: 2,
          creator: doHyun,
        ),
        bookmarkJson(
          'bm-vacation',
          'team',
          '휴가 신청 (그룹웨어)',
          'https://gw.tango.example/vacation',
          position: 3,
          creator: yuNa,
        ),
      ],
      'personal': [
        bookmarkJson(
          'bm-note',
          'personal',
          '내 업무 노트',
          'https://www.notion.so/minji/notes',
          canEdit: true,
        ),
      ],
    })
    ..post('/api/bookmarks/preview', {
      'title': '4분기 마케팅 계획',
      'imageUrl': '/files/bm/preview.png',
      'siteName': 'Notion',
    });
}

void main() {
  setUpAll(() {
    // 캘린더가 내장 캘린더(공휴일·생일) 숨김 상태를 기기 저장소에서 읽는다.
    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues({});
  });

  // ── 앨범 ──

  guideCapture('앨범 목록', desktop, (tester) async {
    await openAlbums(tester);
    final panel = byTypeName('AlbumsPanel');
    final panelRect = tester.getRect(panel);
    final menuRect = tester.getRect(topBarButton('메뉴'));
    final filter = find.descendant(
      of: panel,
      matching: byTypeName('RoomFilterButton'),
    );
    await saveGuideShot(
      tester,
      'messenger-album-list',
      palette: false,
      callouts: [
        GuideCallout.rect(
          menuRect.deflate(2),
          number: 1,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(
          byKey('album-create-button'),
          number: 2,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(filter, number: 3, badge: CalloutBadge.left),
        GuideCallout.rect(
          unionRect(tester, [
            byKey('album-view-grid'),
            byKey('album-view-list'),
          ], padding: 2),
          number: 4,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(
          byKey('album-sort'),
          number: 5,
          badge: CalloutBadge.left,
          padding: 2,
        ),
        GuideCallout.box(
          byKey('album-card-al-workshop'),
          number: 6,
          badge: CalloutBadge.left,
        ),
      ],
      crop: clampToScreen(
        tester,
        Rect.fromLTRB(panelRect.left - 40, 0, 1280, panelRect.top + 560),
      ),
    );
  });

  guideCapture('앨범 생성', desktop, (tester) async {
    await openAlbums(tester);
    await tester.tap(byKey('album-create-button'));
    await settleGuide(tester);
    // 대화방 칸을 눌러 목록에서 마케팅팀을 고른다.
    await tester.tap(byKey('album-room-field'));
    await settleGuide(tester);
    await tester.tap(find.text('마케팅팀').last);
    await settleGuide(tester);
    await tester.enterText(byKey('album-title-field'), '10월 체육대회');
    await tester.enterText(
      byKey('album-description-field'),
      '체육대회 사진과 영상을 함께 모아요.',
    );
    FocusManager.instance.primaryFocus?.unfocus();
    await settleGuide(tester);
    await saveGuideShot(
      tester,
      'messenger-album-create',
      callouts: [
        GuideCallout.box(
          byKey('album-room-field'),
          number: 1,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(
          byKey('album-title-field'),
          number: 2,
          badge: CalloutBadge.left,
          padding: 3,
        ),
        GuideCallout.box(
          byKey('album-description-field'),
          number: 3,
          badge: CalloutBadge.left,
          padding: 3,
        ),
        GuideCallout.box(
          byKey('album-editor-submit'),
          number: 4,
          badge: CalloutBadge.topLeft,
        ),
      ],
      crop: cropAround(tester, [dialogCard], margin: 24),
    );
  });

  guideCapture('앨범 상세', desktop, (tester) async {
    await openAlbums(tester);
    await tester.tap(byKey('album-card-al-workshop'));
    await settleGuide(tester);
    final panelRect = tester.getRect(byTypeName('AlbumsPanel'));
    await saveGuideShot(
      tester,
      'messenger-album-detail',
      palette: false,
      callouts: [
        GuideCallout.box(
          byKey('album-add-files'),
          number: 1,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(
          byKey('album-drop-zone'),
          number: 2,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(
          byKey('album-item-it0'),
          number: 3,
          badge: CalloutBadge.left,
          padding: 2,
        ),
        GuideCallout.box(
          byKey('album-select'),
          number: 4,
          badge: CalloutBadge.top,
        ),
        GuideCallout.box(
          byKey('album-more'),
          number: 5,
          badge: CalloutBadge.left,
          padding: 0,
        ),
      ],
      crop: clampToScreen(
        tester,
        Rect.fromLTRB(
          panelRect.left - 30,
          panelRect.top,
          1280,
          panelRect.top + 600,
        ),
      ),
    );
  });

  guideCapture('앨범 항목 선택', desktop, (tester) async {
    await openAlbums(tester);
    await tester.tap(byKey('album-card-al-workshop'));
    await settleGuide(tester);
    await tester.tap(byKey('album-select'));
    await settleGuide(tester);
    for (final id in ['it0', 'it4', 'it5']) {
      await tester.tap(byKey('album-item-$id'));
      await tester.pump();
    }
    await settleGuide(tester);
    final panelRect = tester.getRect(byTypeName('AlbumsPanel'));
    final bar = byKey('album-selection-bar');
    await saveGuideShot(
      tester,
      'messenger-album-select',
      palette: false,
      callouts: [
        GuideCallout.box(
          byKey('album-item-it4'),
          number: 1,
          badge: CalloutBadge.left,
          padding: 2,
        ),
        GuideCallout.box(
          byKey('album-select-all'),
          number: 2,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(bar, number: 3, badge: CalloutBadge.top, padding: -2),
      ],
      crop: clampToScreen(
        tester,
        Rect.fromLTRB(
          panelRect.left - 30,
          tester.getRect(byKey('album-selected-count')).top - 70,
          1280,
          800,
        ),
      ),
    );
  });

  guideCapture('앨범 공유', desktop, (tester) async {
    await openAlbums(tester);
    await tester.tap(byKey('album-card-al-workshop'));
    await settleGuide(tester);
    final parts = createGuideTempDir();
    final more = byKey('album-more');
    await tester.tap(more);
    await settleGuide(tester);
    final share = find.text('앨범 공유');
    final menuItem = find
        .ancestor(
          of: share,
          matching: find.byWidgetPredicate((w) => w is PopupMenuItem),
        )
        .first;
    final menuRect = unionRect(tester, [
      find.text('전체 다운로드'),
      find.text('앨범 삭제'),
    ], padding: 16);
    final moreRect = tester.getRect(more);
    final part1 = await saveGuideShot(
      tester,
      'part-menu',
      dir: parts,
      callouts: [
        GuideCallout.rect(
          moreRect.deflate(2),
          number: 1,
          badge: CalloutBadge.left,
        ),
        menuItemCallout(tester, menuItem, 2),
      ],
      crop: clampToScreen(
        tester,
        Rect.fromLTRB(
          math.min(menuRect.left, moreRect.left) - 60,
          moreRect.top - 16,
          math.max(menuRect.right, moreRect.right) + 70,
          menuRect.bottom + 16,
        ),
      ),
    );
    await tester.tap(share);
    await settleGuide(tester);
    await tester.tap(byKey('album-message-share-room'));
    await settleGuide(tester);
    await tester.tap(find.text('주간회의').last);
    await settleGuide(tester);
    await tester.enterText(
      byKey('album-message-share-text'),
      '워크숍 사진 앨범 공유드려요! 📸',
    );
    FocusManager.instance.primaryFocus?.unfocus();
    await settleGuide(tester);
    final dialog = byKey('album-message-share-dialog');
    final card = find
        .descendant(of: dialog, matching: find.byType(Material))
        .first;
    final part2 = await saveGuideShot(
      tester,
      'part-dialog',
      dir: parts,
      callouts: [
        GuideCallout.box(
          byKey('album-message-share-room'),
          number: 3,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(
          byKey('album-message-share-text'),
          number: 4,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(
          byKey('album-message-share-send'),
          number: 5,
          badge: CalloutBadge.topLeft,
        ),
      ],
      crop: cropAround(tester, [card], margin: 20),
    );
    composeShots([part1, part2], 'messenger-album-share');
  });

  guideCapture('공유된 앨범 메시지', compact, (tester) async {
    final api = demoApi(
      extra: (api) {
        albumRoutes(api);
        api.get(
          '/api/rooms/r-mkt/messages',
          (_) => [
            ...marketingMessages(),
            {
              ...message(
                'm7',
                'r-mkt',
                me,
                at(10, 20),
                text: '워크숍 사진 앨범 공유드려요! 📸',
              ),
              'sharedAlbum': {
                'id': 'al-workshop',
                'title': workshopTitle,
                'teamName': tango.name,
              },
            },
          ],
        );
      },
    );
    await openDesktop(tester, api: api);
    final box = tester.getRect(bubbleBoxOf('워크숍 사진 앨범'));
    await saveGuideShot(
      tester,
      'messenger-album-card',
      callouts: [
        GuideCallout.box(
          byKey('shared-album-open'),
          number: 1,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(
          byKey('shared-album-card'),
          number: 2,
          badge: CalloutBadge.left,
        ),
      ],
      crop: clampToScreen(
        tester,
        Rect.fromLTRB(
          box.left - 60,
          box.top - 8,
          box.right + 110,
          box.bottom + 16,
        ),
      ),
    );
  });

  // ── 캘린더 ──

  guideCapture('캘린더 화면', desktop, (tester) async {
    await openCalendar(tester);
    final toolbarLeft = unionRect(tester, [
      byKey('cal-today'),
      byKey('cal-title'),
    ], padding: 3);
    await saveGuideShot(
      tester,
      'messenger-calendar-overview',
      callouts: [
        GuideCallout.rect(
          tester.getRect(byTypeName('CalendarListPanel')).deflate(3),
          number: 1,
          badge: CalloutBadge.topRight,
        ),
        GuideCallout.rect(toolbarLeft, number: 2, badge: CalloutBadge.bottom),
        GuideCallout.box(
          byKey('cal-search-field'),
          number: 3,
          badge: CalloutBadge.bottom,
          padding: 2,
        ),
        GuideCallout.box(
          byKey('cal-modes'),
          number: 4,
          badge: CalloutBadge.bottom,
          padding: 2,
        ),
        GuideCallout.box(
          byKey('cal-create'),
          number: 5,
          badge: CalloutBadge.bottom,
          padding: 2,
        ),
        GuideCallout.box(
          byKey('cal-close'),
          number: 6,
          badge: CalloutBadge.bottom,
          padding: 2,
        ),
      ],
    );
  });

  guideCapture('일정 만들기', tall, (tester) async {
    await openCalendar(tester);
    await tester.tap(byKey('cal-create'));
    await settleGuide(tester);
    await tester.enterText(byKey('event-title'), '디자인팀 협업 회의');
    // 캘린더 고르기 — 마케팅팀 일정.
    await tester.tap(byKey('event-calendar'));
    await settleGuide(tester);
    await tester.tap(find.text('마케팅팀 일정').last);
    await settleGuide(tester);
    // 참석자 — 이름으로 찾아 고른다.
    await tester.enterText(byKey('event-attendee-search'), '박서');
    await settleGuide(tester);
    await tester.tap(byKey('event-suggest-${seoYeon.id}'));
    await settleGuide(tester);
    await tester.enterText(byKey('event-location'), '회의실 B');
    // 반복 — 매주.
    await tester.tap(byKey('event-repeat'));
    await settleGuide(tester);
    await tester.tap(find.text('매주').last);
    await settleGuide(tester);
    FocusManager.instance.primaryFocus?.unfocus();
    await settleGuide(tester);
    // 일정 만들기 창은 길어서 안에서 스크롤된다 — 위쪽(제목~참석자)과 끝까지 내린 아래쪽(장소~저장)을 두 장으로 찍는다.
    final card = tester.getRect(dialogCard);
    final titleRect = tester.getRect(byKey('event-title'));
    // 드롭다운은 테두리 칸보다 좁게 잡혀서, 칸 폭(제목 칸과 같다)으로 넓혀 두른다.
    Rect fieldRow(List<Finder> parts, {double top = 5, double bottom = 5}) {
      final r = unionRect(tester, parts, padding: 0);
      return Rect.fromLTRB(
        titleRect.left - 5,
        r.top - top,
        titleRect.right + 5,
        r.bottom + bottom,
      );
    }

    final period = fieldRow([
      byKey('event-start-date'),
      byKey('event-end-time'),
      byKey('event-allday'),
    ]);
    final attendees = fieldRow([
      byKey('event-attendee-search'),
      byKey('event-attendee-${seoYeon.id}'),
    ]);
    await saveGuideShot(
      tester,
      'messenger-calendar-editor',
      callouts: [
        GuideCallout.rect(
          fieldRow(
            [
              byKey('event-title'),
              find.descendant(
                of: byKey('event-title'),
                matching: find.text('제목'),
              ),
            ],
            top: 6,
            bottom: 2,
          ),
          number: 1,
          badge: CalloutBadge.left,
        ),
        GuideCallout.rect(
          fieldRow([byKey('event-calendar')], top: 6, bottom: 6),
          number: 2,
          badge: CalloutBadge.left,
        ),
        GuideCallout.rect(period, number: 3, badge: CalloutBadge.left),
        GuideCallout.rect(attendees, number: 4, badge: CalloutBadge.left),
      ],
      crop: Rect.fromLTRB(
        card.left - 20,
        card.top - 20,
        card.right + 20,
        attendees.bottom + 24,
      ),
    );

    final scroll = tester
        .state<ScrollableState>(
          find
              .descendant(of: dialogCard, matching: find.byType(Scrollable))
              .first,
        )
        .position;
    scroll.jumpTo(scroll.maxScrollExtent);
    await settleGuide(tester);
    final repeat = fieldRow([
      byKey('event-repeat'),
      find.byKey(const ValueKey('event-repeat-summary')).evaluate().isEmpty
          ? byKey('event-repeat')
          : byKey('event-repeat-summary'),
    ], top: 6);
    final location = tester.getRect(byKey('event-location'));
    await saveGuideShot(
      tester,
      'messenger-calendar-editor-2',
      callouts: [
        GuideCallout.rect(repeat, number: 5, badge: CalloutBadge.left),
        GuideCallout.rect(
          fieldRow([byKey('event-visibility')], top: 4, bottom: 30),
          number: 6,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(
          byKey('event-save'),
          number: 7,
          badge: CalloutBadge.topLeft,
          padding: 2,
        ),
      ],
      crop: Rect.fromLTRB(
        card.left - 20,
        location.top - 40,
        card.right + 20,
        card.bottom + 20,
      ),
    );
  });

  guideCapture('일정 상세', desktop, (tester) async {
    await openCalendar(tester);
    await tester.tap(find.textContaining('캠페인 중간 점검').first);
    await settleGuide(tester);
    await saveGuideShot(
      tester,
      'messenger-calendar-detail',
      callouts: [
        GuideCallout.box(
          find.byTooltip('수정하기'),
          number: 1,
          badge: CalloutBadge.bottom,
          padding: 0,
        ),
        GuideCallout.box(
          find.byTooltip('삭제하기'),
          number: 2,
          badge: CalloutBadge.bottom,
          padding: 0,
        ),
      ],
      crop: cropAround(tester, [dialogCard], margin: 20),
    );
  });

  guideCapture('일정 검색', desktop, (tester) async {
    await openCalendar(tester);
    await tester.tap(byKey('cal-search-field'));
    await tester.pump();
    await tester.enterText(byKey('cal-search-field'), '캠페인');
    // 검색은 입력을 멈추고 0.3초 뒤에 시작한다.
    await tester.pump(const Duration(milliseconds: 400));
    await settleGuide(tester);
    final panel = byKey('cal-search-panel');
    await saveGuideShot(
      tester,
      'messenger-calendar-search',
      callouts: [
        GuideCallout.box(
          byKey('cal-search-field'),
          number: 1,
          badge: CalloutBadge.left,
          padding: 2,
        ),
        GuideCallout.box(
          byKey('cal-search-item-ev-check'),
          number: 2,
          badge: CalloutBadge.left,
          padding: 0,
        ),
        GuideCallout.box(
          byKey('cal-search-move-ev-check'),
          number: 3,
          badge: CalloutBadge.left,
          padding: 2,
        ),
      ],
      crop: clampToScreen(
        tester,
        unionRect(tester, [byKey('cal-search-field'), panel], padding: 40),
      ),
    );
  });

  guideCapture('캘린더 설정', tall, (tester) async {
    await openCalendar(tester);
    await tester.tap(byKey('cal-menu-cal-mkt'));
    await settleGuide(tester);
    await tester.tap(find.text('캘린더 설정'));
    await settleGuide(tester);
    await saveGuideShot(
      tester,
      'messenger-calendar-settings',
      callouts: [
        GuideCallout.box(
          byKey('cal-settings-name'),
          number: 1,
          badge: CalloutBadge.left,
          padding: 3,
        ),
        GuideCallout.box(
          byKey('cal-settings-public'),
          number: 2,
          badge: CalloutBadge.left,
          padding: 0,
        ),
        GuideCallout.box(
          byKey('cal-member-search'),
          number: 3,
          badge: CalloutBadge.left,
          padding: 3,
        ),
        GuideCallout.box(
          byKey('cal-member-role-${doHyun.id}'),
          number: 4,
          badge: CalloutBadge.left,
          padding: 2,
        ),
      ],
      crop: cropAround(tester, [dialogCard], margin: 20),
    );
  });

  guideCapture('생일 입력', const GuideSurface(Size(960, 760)), (tester) async {
    final session = demoSession(
      api: demoApi(
        extra: (api) =>
            api.patch('/api/users/me/birthday', {'birthday': '05-03'}),
      ),
    );
    session.email = 'minji.kim@tango.example';
    await pumpGuideApp(
      tester,
      Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => PersonalInfoDialog(
                  session: session,
                  verifiedPassword: 'pw',
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await settleGuide(tester);
    final parts = createGuideTempDir();
    final infoCard = find
        .descendant(
          of: find.byType(PersonalInfoDialog),
          matching: find.byType(Material),
        )
        .first;
    final part1 = await saveGuideShot(
      tester,
      'part-info',
      dir: parts,
      callouts: [
        GuideCallout.box(
          byKey('profile-birthday'),
          number: 1,
          badge: CalloutBadge.left,
          padding: -1,
        ),
      ],
      crop: cropAround(tester, [infoCard], margin: 16),
    );
    await tester.tap(byKey('profile-birthday'));
    await settleGuide(tester);
    await tester.tap(byKey('birthday-month'));
    await settleGuide(tester);
    await tester.tap(find.text('5월').last);
    await settleGuide(tester);
    await tester.tap(byKey('birthday-day-5'));
    await settleGuide(tester);
    await tester.tap(find.text('3일').last);
    await settleGuide(tester);
    final alert = find
        .descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(Material),
        )
        .first;
    final part2 = await saveGuideShot(
      tester,
      'part-birthday',
      dir: parts,
      callouts: [
        GuideCallout.rect(
          // 칸 위 테두리에 걸친 '월'·'일' 글자를 가리지 않게 위쪽을 더 띄운다.
          Rect.fromLTRB(
            tester.getRect(byKey('birthday-month')).left - 4,
            tester.getRect(byKey('birthday-month')).top - 10,
            tester.getRect(byKey('birthday-day-5')).right + 4,
            tester.getRect(byKey('birthday-day-5')).bottom + 4,
          ),
          number: 2,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(
          byKey('birthday-save'),
          number: 3,
          badge: CalloutBadge.topLeft,
          padding: 2,
        ),
      ],
      crop: cropAround(tester, [alert], margin: 16),
    );
    composeShots([part1, part2], 'messenger-calendar-birthday');
  });

  // ── 즐겨찾기와 북마크 ──

  guideCapture('즐겨찾기 모아 보기', desktop, (tester) async {
    await openDesktop(
      tester,
      roomName: null,
      session: demoSession(api: demoApi(extra: savedRoutes)),
    );
    final menuRect = tester.getRect(topBarButton('메뉴'));
    await tester.tap(topBarButton('메뉴'));
    await settleGuide(tester);
    await tester.tap(byKey('menu-favorites'));
    await settleGuide(tester);
    final panel = byTypeName('FavoritesScreen');
    final panelRect = tester.getRect(panel);
    final tiles = byTypeName('_FavoriteTile');
    await saveGuideShot(
      tester,
      'messenger-saved-favorites',
      callouts: [
        GuideCallout.rect(
          menuRect.deflate(2),
          number: 1,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(
          find.descendant(
            of: panel,
            matching: byTypeName('PanelKindButton<FavoriteKind?>'),
          ),
          number: 2,
          badge: CalloutBadge.left,
          padding: 2,
        ),
        GuideCallout.box(
          tiles.first,
          number: 3,
          badge: CalloutBadge.left,
          padding: 1,
        ),
        GuideCallout.box(
          byKey('favorite-unstar-message:m1'),
          number: 4,
          badge: CalloutBadge.left,
          padding: 0,
        ),
      ],
      crop: clampToScreen(
        tester,
        Rect.fromLTRB(panelRect.left - 40, 0, 1280, panelRect.top + 640),
      ),
    );
  });

  guideCapture('북마크', desktop, (tester) async {
    final session = demoSession(api: demoApi(extra: savedRoutes));
    await seedBookmarkImages(tester, session);
    await openDesktop(tester, roomName: null, session: session);
    await tester.tap(topBarButton('메뉴'));
    await settleGuide(tester);
    await tester.tap(byKey('menu-bookmarks'));
    await settleGuide(tester);
    final panel = byTypeName('BookmarksPanel');
    final panelRect = tester.getRect(panel);
    await saveGuideShot(
      tester,
      'messenger-saved-bookmarks',
      palette: false,
      callouts: [
        GuideCallout.box(
          byKey('bookmark-add'),
          number: 1,
          badge: CalloutBadge.left,
        ),
        GuideCallout.rect(
          unionRect(tester, [
            byKey('bookmark-tab-team'),
            byKey('bookmark-tab-personal'),
          ], padding: 0),
          number: 2,
          badge: CalloutBadge.left,
        ),
        GuideCallout.box(
          byKey('bookmark-bm-wiki'),
          number: 3,
          badge: CalloutBadge.left,
          padding: 0,
        ),
        GuideCallout.box(
          byKey('bookmark-menu-bm-figma'),
          number: 4,
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

  guideCapture('북마크 추가', desktop, (tester) async {
    final session = demoSession(api: demoApi(extra: savedRoutes));
    await seedBookmarkImages(tester, session);
    await openDesktop(tester, roomName: null, session: session);
    await tester.tap(topBarButton('메뉴'));
    await settleGuide(tester);
    await tester.tap(byKey('menu-bookmarks'));
    await settleGuide(tester);
    await tester.tap(byKey('bookmark-add'));
    await settleGuide(tester);
    await tester.enterText(
      byKey('bookmark-url'),
      'https://www.notion.so/tango/q4-marketing-plan',
    );
    // 주소를 넣고 잠시 기다리면 제목·이미지를 알아서 가져온다.
    await tester.pump(const Duration(milliseconds: 800));
    await settleGuide(tester);
    FocusManager.instance.primaryFocus?.unfocus();
    await settleGuide(tester);
    await saveGuideShot(
      tester,
      'messenger-saved-bookmark-editor',
      palette: false,
      callouts: [
        GuideCallout.box(
          byKey('bookmark-kind'),
          number: 1,
          badge: CalloutBadge.left,
          padding: 3,
        ),
        fieldCallout(tester, byKey('bookmark-url'), 2),
        GuideCallout.box(
          byKey('bookmark-fetch'),
          number: 3,
          badge: CalloutBadge.left,
          padding: 1,
        ),
        fieldCallout(tester, byKey('bookmark-title'), 4),
        GuideCallout.box(
          byKey('bookmark-save'),
          number: 5,
          badge: CalloutBadge.topLeft,
          padding: 2,
        ),
      ],
      crop: cropAround(tester, [dialogCard], margin: 20),
    );
  });
}
