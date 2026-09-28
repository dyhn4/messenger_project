// 초보자용 도움말(server/guide/*.html)에 넣을 스크린샷을 "진짜 앱 위젯"으로 찍는 도구.
//
// 사용법(client 폴더에서):
//   flutter test tool/guide_capture/<이름>_test.dart
// 결과: ../server/guide/images/<이름>.png (같은 이름이면 덮어쓴다 — 앱 화면이 바뀌면 다시 실행)
//
// 왜 위젯 테스트로 찍나: 실제 앱을 띄워 손으로 캡처하면 서버·DB·계정이 필요하고, 화면이 바뀔
// 때마다 다시 찍기도 어렵다. 여기서는 진짜 화면 위젯을 가짜 서버 응답(MockClient)으로 채워
// 그리고, 빨간 번호 표시(callout)를 실제 위젯 위치(tester.getRect)에 맞춰 PNG에 바로 그린다.
//
// 이 폴더는 client/test/가 아니라서 평소 `flutter test`(전체 테스트)에는 끼지 않는다.
// 예시: sample_capture_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:client/models/room.dart';
import 'package:client/models/team.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;

// ───────────────────────────── 화면 크기 ─────────────────────────────

/// 스크린샷 한 장의 화면(논리 크기 · 배율 · 플랫폼).
class GuideSurface {
  /// 논리 크기(dp). 저장되는 PNG는 이 크기 × [pixelRatio] 픽셀이다.
  final Size size;
  final double pixelRatio;

  /// Theme.platform에 들어갈 값 — PC(windows)는 글꼴이 'Segoe UI'이고 밀도가 조밀하며
  /// 마우스용 스크롤바가 붙는 등 실제 Windows 앱과 같아진다.
  final TargetPlatform platform;

  const GuideSurface(
    this.size, {
    this.pixelRatio = 1.5,
    this.platform = TargetPlatform.windows,
  });

  /// PC 앱 창(1280×800, 1.5배 → 1920×1200 PNG).
  static const desktop = GuideSurface(Size(1280, 800));

  /// 작은 PC 창 — 대화상자·메뉴처럼 화면 일부만 보여줄 때 여백을 줄이려고.
  static const desktopSmall = GuideSurface(Size(960, 640));

  /// 안드로이드 휴대폰(390×844, 2배 → 780×1688 PNG). 앱은 창 폭으로 모바일 배치를 고른다.
  static const phone = GuideSurface(
    Size(390, 844),
    pixelRatio: 2,
    platform: TargetPlatform.android,
  );
}

// ───────────────────────────── 글꼴 ─────────────────────────────

bool _fontsLoaded = false;

String get _flutterRoot {
  final env = Platform.environment['FLUTTER_ROOT'];
  if (env != null && env.isNotEmpty) return env;
  // flutter test는 보통 FLUTTER_ROOT를 넣어 주지만, 없으면 실행 파일 위치에서 거슬러 찾는다.
  final exe = File(Platform.resolvedExecutable).absolute.path;
  final marker = '${Platform.pathSeparator}bin${Platform.pathSeparator}cache';
  final i = exe.indexOf(marker);
  return i > 0 ? exe.substring(0, i) : 'C:/flutter';
}

String get _windowsFonts =>
    '${Platform.environment['WINDIR'] ?? 'C:/Windows'}/Fonts';

Future<void> _loadFamily(String family, List<String> paths) async {
  final loader = FontLoader(family);
  var added = 0;
  for (final p in paths) {
    final f = File(p);
    if (!f.existsSync()) continue;
    loader.addFont(Future.value(ByteData.sublistView(f.readAsBytesSync())));
    added++;
  }
  if (added == 0) {
    // 글꼴이 없으면 글자가 네모(□)로 찍힌다 — 조용히 넘어가지 말고 바로 알린다.
    throw StateError('$family 글꼴 파일을 찾을 수 없습니다: ${paths.join(', ')}');
  }
  await loader.load();
}

/// 앱이 실제로 쓰는 글꼴을 테스트 엔진에 올린다(한 번만).
///
/// - Windows 앱: 기본 글꼴 'Segoe UI'(Typography의 Windows 기본) → 한글처럼 없는 글자는
///   main.dart가 붙인 fontFamilyFallback 'NanumBarunGothicYetHangul'(앱에 번들된 글꼴)로 그린다.
/// - 안드로이드 화면: 'Roboto'(Flutter SDK에 들어 있는 것).
/// - 아이콘: MaterialIcons(Flutter SDK의 materialicons-regular.otf).
/// - 테스트 엔진에는 운영체제 글꼴 대체가 없어서, 실제 PC가 해주는 대체(맑은 고딕·이모지·
///   기호)를 [guideFontFallback]으로 흉내 낸다.
///
/// 주의: 테마를 거치지 않고 글꼴 이름 없이 그린 글자(CustomPainter 안의 맨 TextStyle 등)는
/// 테스트 엔진의 기본 글꼴(네모 □)로 찍힌다 — 앱 화면은 전부 테마 글꼴을 써서 해당이 없지만,
/// 캡처에 네모가 보이면 그 글자가 어디서 그려지는지부터 확인할 것.
Future<void> loadGuideFonts() async {
  if (_fontsLoaded) return;
  final win = _windowsFonts;
  final sdkFonts = '$_flutterRoot/bin/cache/artifacts/material_fonts';
  final appFonts = '${_clientRoot.path}/assets/fonts';
  await _loadFamily('MaterialIcons', ['$sdkFonts/materialicons-regular.otf']);
  await _loadFamily('Segoe UI', [
    '$win/segoeui.ttf',
    '$win/segoeuib.ttf',
    '$win/seguisb.ttf',
    '$win/segoeuil.ttf',
    '$win/segoeuii.ttf',
  ]);
  await _loadFamily('Roboto', [
    '$sdkFonts/roboto-regular.ttf',
    '$sdkFonts/roboto-medium.ttf',
    '$sdkFonts/roboto-bold.ttf',
    '$sdkFonts/roboto-light.ttf',
    '$sdkFonts/roboto-italic.ttf',
  ]);
  await _loadFamily('NanumBarunGothicYetHangul', [
    '$appFonts/NanumBarunGothic-YetHangul.ttf',
  ]);
  await _loadFamily('Malgun Gothic', ['$win/malgun.ttf', '$win/malgunbd.ttf']);
  await _loadFamily('Segoe UI Emoji', ['$win/seguiemj.ttf']);
  await _loadFamily('Segoe UI Symbol', ['$win/seguisym.ttf']);
  // 코드 블록(rich_text_format.dart)은 'Consolas', 텍스트 뷰어는 'monospace'를 쓴다.
  await _loadFamily('Consolas', ['$win/consola.ttf', '$win/consolab.ttf']);
  await _loadFamily('monospace', ['$win/consola.ttf', '$win/consolab.ttf']);
  _fontsLoaded = true;
}

/// client 폴더(pubspec.yaml이 있는 곳) — flutter test는 보통 여기서 실행되지만, 다른 곳에서
/// 실행해도 찾아 올라간다.
Directory get _clientRoot {
  var dir = Directory.current.absolute;
  while (!File('${dir.path}/pubspec.yaml').existsSync() &&
      dir.parent.path != dir.path) {
    dir = dir.parent;
  }
  return dir;
}

/// 앱 테마의 대체 글꼴 + 운영체제 글꼴 대체 흉내(맑은 고딕 → 이모지 → 기호).
const guideFontFallback = [
  'NanumBarunGothicYetHangul',
  'Malgun Gothic',
  'Segoe UI Emoji',
  'Segoe UI Symbol',
];

// ───────────────────────────── 테마 ─────────────────────────────

ThemeData _withFallback(ThemeData theme) => theme.copyWith(
  textTheme: theme.textTheme.apply(fontFamilyFallback: guideFontFallback),
  primaryTextTheme: theme.primaryTextTheme.apply(
    fontFamilyFallback: guideFontFallback,
  ),
);

/// client/lib/main.dart의 MaterialApp theme/darkTheme과 같은 테마(그쪽 _withOldHangulFallback는
/// 비공개라 여기서 똑같이 만든다 — main.dart 테마를 바꾸면 여기도 맞춰 줄 것).
ThemeData guideTheme({Brightness brightness = Brightness.light}) {
  if (brightness == Brightness.dark) {
    final dark = ColorScheme.fromSeed(
      seedColor: Colors.indigo,
      brightness: Brightness.dark,
    );
    return _withFallback(
      ThemeData(
        colorScheme: dark,
        useMaterial3: true,
        popupMenuTheme: PopupMenuThemeData(color: dark.surfaceContainerHigh),
      ),
    );
  }
  return _withFallback(
    ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
      useMaterial3: true,
    ),
  );
}

// ───────────────────────────── 테스트 선언 ─────────────────────────────

/// 스크린샷 한 벌을 찍는 테스트를 선언한다 — [testWidgets]에 글꼴 로드, 화면 크기·배율,
/// 플랫폼(PC면 windows) 설정을 얹은 것.
///
/// ```dart
/// guideCapture('로그인 화면', GuideSurface.desktop, (tester) async {
///   await pumpGuideApp(tester, LoginScreen(session: guideSession()));
///   await saveGuideShot(tester, 'messenger-login', callouts: [
///     GuideCallout.box(find.byType(TextField).first, number: 1),
///   ]);
/// });
/// ```
void guideCapture(
  String description,
  GuideSurface surface,
  Future<void> Function(WidgetTester tester) body, {
  Timeout? timeout,
  bool skip = false,
}) {
  testWidgets(
    description,
    (tester) async {
      await loadGuideFonts();
      tester.view.physicalSize = surface.size * surface.pixelRatio;
      tester.view.devicePixelRatio = surface.pixelRatio;
      addTearDown(tester.view.reset);
      _currentSurface = surface;
      // 위젯 테스트는 그림자를 굵은 검은 테두리로 바꿔 그린다(골든 비교용) — 실제 앱처럼
      // 보이도록 캡처하는 동안만 끄고, 테스트가 끝날 때 검사하는 값으로 되돌린다.
      debugDisableShadows = false;
      try {
        await body(tester);
      } finally {
        debugDisableShadows = true;
      }
    },
    variant: TargetPlatformVariant.only(surface.platform),
    timeout: timeout ?? const Timeout(Duration(minutes: 2)),
    skip: skip,
  );
}

GuideSurface _currentSurface = GuideSurface.desktop;

// ───────────────────────────── 화면 올리기 ─────────────────────────────

final _frameKey = GlobalKey(debugLabel: 'guide-capture-frame');
final _callouts = ValueNotifier<_CalloutScene?>(null);

/// [home]을 앱과 같은 테마의 MaterialApp에 넣어 올린다(디버그 띠 없음).
/// 대화상자·팝업 메뉴도 이 MaterialApp의 Navigator 위에 뜨므로 함께 찍힌다.
Future<void> pumpGuideApp(
  WidgetTester tester,
  Widget home, {
  Brightness brightness = Brightness.light,
  bool settle = true,
}) {
  return pumpGuideWidget(
    tester,
    MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'TangoTalk',
      theme: guideTheme(),
      darkTheme: guideTheme(brightness: Brightness.dark),
      themeMode: brightness == Brightness.dark
          ? ThemeMode.dark
          : ThemeMode.light,
      home: home,
    ),
    settle: settle,
  );
}

/// 이미 MaterialApp을 직접 만든 경우(라우트가 필요한 화면 등) — 그 위젯을 캡처 틀에 넣어
/// 올린다. MaterialApp에 `debugShowCheckedModeBanner: false`와 [guideTheme]을 꼭 넣을 것.
Future<void> pumpGuideWidget(
  WidgetTester tester,
  Widget app, {
  bool settle = true,
}) async {
  _callouts.value = null;
  await tester.pumpWidget(
    RepaintBoundary(
      key: _frameKey,
      child: Stack(
        textDirection: TextDirection.ltr,
        children: [
          Positioned.fill(child: app),
          Positioned.fill(
            child: IgnorePointer(
              child: ValueListenableBuilder<_CalloutScene?>(
                valueListenable: _callouts,
                builder: (context, scene, _) => CustomPaint(
                  painter: scene == null ? null : _CalloutPainter(scene),
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
  if (settle) await settleGuide(tester);
}

/// 창 크기만 바꾼다(배율은 그대로) — 넓은 창에서 프로젝트를 열어 둔 뒤 좁은 창으로 줄여서,
/// 대화상자처럼 창 폭을 따라 줄어드는 화면을 본문 폭(약 750px)에 맞게 찍을 때.
Future<void> resizeGuideWindow(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size * tester.view.devicePixelRatio;
  await settleGuide(tester);
}

/// 애니메이션·가짜 서버 응답이 끝날 때까지 기다린다. 커서 깜빡임처럼 끝나지 않는 애니메이션이
/// 있으면 pumpAndSettle이 시간 초과로 실패하므로, 그럴 땐 정해진 만큼만 흘려보낸다.
Future<void> settleGuide(
  WidgetTester tester, [
  Duration max = const Duration(seconds: 3),
]) async {
  try {
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      max,
    );
  } on FlutterError {
    await tester.pump(const Duration(milliseconds: 300));
  }
}

// ───────────────────────────── 빨간 번호 표시 ─────────────────────────────

/// 번호 배지를 상자의 어느 모서리/변에 붙일지.
enum CalloutBadge {
  topLeft,
  topRight,
  bottomLeft,
  bottomRight,
  left,
  right,
  top,
  bottom,

  /// 상자 없이 대상의 한가운데에 번호만(작은 아이콘 버튼 등).
  center,
}

/// 스크린샷 위에 그릴 표시 하나 — 빨간 테두리 상자와 번호 배지.
/// 도움말 글의 순서 번호(<ol class="steps">)와 같은 숫자를 쓴다.
class GuideCallout {
  final Finder? finder;
  final Rect? rect;
  final int? number;
  final CalloutBadge badge;

  /// 상자를 그릴지(false면 번호 배지만).
  final bool outline;

  /// 대상 위젯 둘레에 둘 여백(논리 px).
  final double padding;

  /// 번호 없는 설명 글(배지 옆에 흰 말풍선으로) — 되도록 쓰지 말고 도움말 본문에 적는다.
  final String? label;

  const GuideCallout._({
    this.finder,
    this.rect,
    this.number,
    this.badge = CalloutBadge.topLeft,
    this.outline = true,
    this.padding = 4,
    this.label,
  });

  /// [finder] 위젯을 빨간 상자로 두르고 [number] 배지를 붙인다.
  factory GuideCallout.box(
    Finder finder, {
    int? number,
    CalloutBadge badge = CalloutBadge.topLeft,
    double padding = 4,
    String? label,
  }) => GuideCallout._(
    finder: finder,
    number: number,
    badge: badge,
    padding: padding,
    label: label,
  );

  /// 상자 없이 번호 배지만(아이콘처럼 작은 대상에 — 기본은 대상의 오른쪽 위).
  factory GuideCallout.dot(
    Finder finder, {
    required int number,
    CalloutBadge badge = CalloutBadge.topRight,
  }) => GuideCallout._(
    finder: finder,
    number: number,
    badge: badge,
    outline: false,
    padding: 0,
  );

  /// 위젯이 아닌 임의의 영역(논리 좌표) — 여러 위젯을 한 상자로 묶을 때.
  factory GuideCallout.rect(
    Rect rect, {
    int? number,
    CalloutBadge badge = CalloutBadge.topLeft,
    String? label,
  }) => GuideCallout._(rect: rect, number: number, badge: badge, label: label);

  Rect resolve(WidgetTester tester) {
    if (rect != null) return rect!;
    final f = finder!;
    final count = f.evaluate().length;
    if (count != 1) {
      throw StateError('표시 대상은 정확히 하나여야 합니다($count개 찾음): $f');
    }
    return tester.getRect(f).inflate(padding);
  }
}

/// 여러 위젯의 영역을 하나로 합친다(GuideCallout.rect에 넘길 때).
Rect unionRect(
  WidgetTester tester,
  List<Finder> finders, {
  double padding = 4,
}) {
  var r = tester.getRect(finders.first);
  for (final f in finders.skip(1)) {
    r = r.expandToInclude(tester.getRect(f));
  }
  return r.inflate(padding);
}

class _ResolvedCallout {
  final Rect rect;
  final GuideCallout spec;
  const _ResolvedCallout(this.rect, this.spec);
}

class _CalloutScene {
  final List<_ResolvedCallout> items;
  final bool spotlight;

  /// 저장될 영역(잘라낼 영역, 없으면 화면 전체) — 배지가 이 밖으로 나가 잘리지 않게 한다.
  final Rect bounds;
  const _CalloutScene(this.items, this.spotlight, this.bounds);
}

/// 도움말 CSS의 --mark와 같은 빨강.
const guideMarkColor = Color(0xFFE03131);

class _CalloutPainter extends CustomPainter {
  final _CalloutScene scene;
  _CalloutPainter(this.scene);

  static const _badgeRadius = 14.0;

  @override
  void paint(Canvas canvas, Size size) {
    if (scene.spotlight) {
      // 표시한 곳만 밝게 — 나머지를 살짝 어둡게 덮는다.
      final dim = Path()..addRect(Offset.zero & size);
      for (final c in scene.items.where((c) => c.spec.outline)) {
        dim.addRRect(RRect.fromRectAndRadius(c.rect, const Radius.circular(8)));
      }
      dim.fillType = PathFillType.evenOdd;
      canvas.drawPath(dim, Paint()..color = const Color(0x59000000));
    }
    for (final c in scene.items) {
      if (c.spec.outline) {
        final rr = RRect.fromRectAndRadius(c.rect, const Radius.circular(8));
        // 흰 테두리를 먼저 깔아서 어두운 배경·빨간 버튼 위에서도 선이 보이게.
        canvas.drawRRect(
          rr,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 5
            ..color = const Color(0xCCFFFFFF),
        );
        canvas.drawRRect(
          rr,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3
            ..color = guideMarkColor,
        );
      }
    }
    // 배지는 상자들보다 위에(겹쳐도 번호가 가려지지 않게).
    for (final c in scene.items) {
      final n = c.spec.number;
      if (n == null && c.spec.label == null) continue;
      final center = _badgeCenter(c.rect, c.spec.badge, scene.bounds);
      if (n != null) _drawBadge(canvas, center, '$n');
      if (c.spec.label != null) {
        _drawLabel(canvas, center, c.spec.label!, size);
      }
    }
  }

  Offset _badgeCenter(Rect r, CalloutBadge where, Rect bounds) {
    const g = _badgeRadius;
    final p = switch (where) {
      CalloutBadge.topLeft => r.topLeft,
      CalloutBadge.topRight => r.topRight,
      CalloutBadge.bottomLeft => r.bottomLeft,
      CalloutBadge.bottomRight => r.bottomRight,
      CalloutBadge.left => r.centerLeft - const Offset(g + 2, 0),
      CalloutBadge.right => r.centerRight + const Offset(g + 2, 0),
      CalloutBadge.top => r.topCenter - const Offset(0, g + 2),
      CalloutBadge.bottom => r.bottomCenter + const Offset(0, g + 2),
      CalloutBadge.center => r.center,
    };
    // 그림(잘라낸 영역) 밖으로 잘리지 않게 안쪽으로 당긴다.
    return Offset(
      p.dx.clamp(bounds.left + g + 2, bounds.right - g - 2),
      p.dy.clamp(bounds.top + g + 2, bounds.bottom - g - 2),
    );
  }

  void _drawBadge(Canvas canvas, Offset c, String text) {
    const r = _badgeRadius;
    canvas.drawCircle(
      c + const Offset(0, 1.5),
      r + 1,
      Paint()
        ..color = const Color(0x55000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.5),
    );
    canvas.drawCircle(c, r + 2, Paint()..color = Colors.white);
    canvas.drawCircle(c, r, Paint()..color = guideMarkColor);
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontFamily: 'Segoe UI',
          fontFamilyFallback: guideFontFallback,
          fontSize: text.length > 1 ? 13 : 16,
          fontWeight: FontWeight.w700,
          color: Colors.white,
          height: 1,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, c - Offset(tp.width / 2, tp.height / 2));
  }

  void _drawLabel(Canvas canvas, Offset badge, String text, Size size) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(
          fontFamily: 'Segoe UI',
          fontFamilyFallback: guideFontFallback,
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: Colors.white,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: 260);
    const pad = EdgeInsets.symmetric(horizontal: 8, vertical: 4);
    var left = badge.dx + _badgeRadius + 6;
    if (left + tp.width + pad.horizontal > size.width) {
      left = badge.dx - _badgeRadius - 6 - tp.width - pad.horizontal;
    }
    final box = Rect.fromLTWH(
      left,
      badge.dy - (tp.height + pad.vertical) / 2,
      tp.width + pad.horizontal,
      tp.height + pad.vertical,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(box, const Radius.circular(6)),
      Paint()..color = guideMarkColor,
    );
    tp.paint(canvas, box.topLeft + Offset(pad.left, pad.top));
  }

  @override
  bool shouldRepaint(_CalloutPainter old) => old.scene != scene;
}

// ───────────────────────────── 저장 ─────────────────────────────

/// 그림을 도움말 폴더 대신 다른 곳에 저장할 때(예시 캡처처럼 배포하지 않을 그림) — null이면
/// server/guide/images. 이 폴더는 설치 파일·업데이트 묶음에 통째로 들어가므로, 도움말 페이지가
/// 쓰지 않는 그림을 거기에 남기지 않으려고 둔다.
Directory? guideImagesDirOverride;

/// 도움말 그림 폴더(server/guide/images).
Directory get guideImagesDir {
  final out =
      guideImagesDirOverride ??
      Directory('${_clientRoot.parent.path}/server/guide/images');
  out.createSync(recursive: true);
  return out;
}

/// 지금 화면을 [callouts]를 얹어 `server/guide/images/<name>.png`로 저장한다.
///
/// - [crop]: 논리 좌표로 잘라낼 영역(메뉴·대화상자만 보여줄 때). 화면 밖은 알아서 잘린다.
///   표시 상자와 번호 배지는 이 영역 안으로 당겨 그려서 가장자리에서 잘리지 않는다.
/// - [spotlight]: 상자로 표시한 곳 밖을 살짝 어둡게.
/// - [palette]: 256색 PNG로 줄인다(글자·아이콘 위주 화면은 거의 티가 안 나고 용량이 크게
///   준다). 사진·그라데이션이 많은 화면이면 false.
/// - [erase]: 논리 좌표 영역을 그 바로 왼쪽 픽셀 색으로 칠해 지운다. 캡처는 Windows에서 돌아서
///   휴대폰 그림에도 Windows 전용 버튼(화면 캡처·줄바꿈 안내 등)이 그려지는데, 그 자리가 실제
///   안드로이드에서는 빈 배경이라 배경색으로 덮는다. 표시 상자와 겹치지 않는 곳에만 쓸 것.
/// 저장한 파일을 돌려준다. 저장 뒤에는 표시를 지우므로 같은 화면에서 이어서 다른 장을 찍을 수 있다.
Future<File> saveGuideShot(
  WidgetTester tester,
  String name, {
  List<GuideCallout> callouts = const [],
  Rect? crop,
  bool spotlight = false,
  bool palette = true,
  List<Rect> erase = const [],
}) async {
  // 캡처 중에 창 크기를 바꿀 수도 있어서(tester.view.physicalSize) 처음 크기가 아니라 지금 크기로.
  final screen =
      Offset.zero & (tester.view.physicalSize / tester.view.devicePixelRatio);
  final bounds = crop == null ? screen : crop.intersect(screen);
  // 흰 테두리(5px)까지 그림 안에 들어오게 가장자리에서 3px 안쪽으로 당긴다.
  final inner = bounds.deflate(3);
  Rect clampToBounds(Rect r) => Rect.fromLTRB(
    math.max(r.left, inner.left),
    math.max(r.top, inner.top),
    math.min(r.right, inner.right),
    math.min(r.bottom, inner.bottom),
  );
  final resolved = [
    for (final c in callouts)
      _ResolvedCallout(
        c.outline ? clampToBounds(c.resolve(tester)) : c.resolve(tester),
        c,
      ),
  ];
  _callouts.value = _CalloutScene(resolved, spotlight, bounds);
  await tester.pump();

  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_frameKey),
  );
  final ratio = _currentSurface.pixelRatio;
  final bytes = await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: ratio);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      return (data!, image.width, image.height);
    } finally {
      image.dispose();
    }
  });
  _callouts.value = null;
  await tester.pump();

  final (data, width, height) = bytes!;
  var shot = img.Image.fromBytes(
    width: width,
    height: height,
    bytes: data.buffer,
    numChannels: 4,
    order: img.ChannelOrder.rgba,
  );
  for (final r in erase) {
    final x1 = (r.left * ratio).round().clamp(0, width - 1);
    final y1 = (r.top * ratio).round().clamp(0, height - 1);
    final x2 = (r.right * ratio).round().clamp(0, width - 1);
    final y2 = (r.bottom * ratio).round().clamp(0, height - 1);
    final p = shot.getPixel(math.max(0, x1 - 3), (y1 + y2) ~/ 2);
    img.fillRect(
      shot,
      x1: x1,
      y1: y1,
      x2: x2,
      y2: y2,
      color: img.ColorRgba8(p.r.toInt(), p.g.toInt(), p.b.toInt(), p.a.toInt()),
    );
  }
  if (crop != null) {
    final px = Rect.fromLTRB(
      math.max(0, crop.left * ratio),
      math.max(0, crop.top * ratio),
      math.min(width.toDouble(), crop.right * ratio),
      math.min(height.toDouble(), crop.bottom * ratio),
    );
    shot = img.copyCrop(
      shot,
      x: px.left.round(),
      y: px.top.round(),
      width: px.width.round(),
      height: px.height.round(),
    );
  }
  // 투명한 곳(화면 밖 등)이 없도록 알파를 버린다 — 파일도 작아진다.
  shot = shot.convert(numChannels: 3);
  if (palette) {
    shot = img.quantize(
      shot,
      numberOfColors: 256,
      method: img.QuantizeMethod.octree,
    );
  }
  final file = File('${guideImagesDir.path}/$name.png');
  file.writeAsBytesSync(img.encodePng(shot, level: 9));
  // HTML의 width/height는 논리 크기(PNG 픽셀 ÷ 배율)로 — 그래야 고해상도 화면에서도 선명하고
  // 앱에서 보이는 실제 크기로 나온다(본문 폭보다 넓으면 CSS가 줄여 준다).
  final w = (shot.width / ratio).round();
  final h = (shot.height / ratio).round();
  // ignore: avoid_print
  print(
    '[guide] ${file.path} (${shot.width}×${shot.height}px, '
    '${(file.lengthSync() / 1024).toStringAsFixed(0)} KB)\n'
    '        <img src="images/$name.png" alt="" width="$w" height="$h" loading="lazy">',
  );
  return file;
}

/// 여러 위젯을 감싸는 영역에 여백을 더한 잘라내기 영역(saveGuideShot의 crop에).
Rect cropAround(
  WidgetTester tester,
  List<Finder> finders, {
  double margin = 24,
}) => unionRect(tester, finders, padding: margin);

// ───────────────────────────── 가짜 서버 · 세션 ─────────────────────────────

/// 화면이 부르는 REST API에 미리 정해 둔 JSON을 돌려주는 가짜 서버(MockClient).
///
/// ```dart
/// final api = GuideFakeApi()
///   ..get('/api/projects', [project1, project2])
///   ..get('/api/projects/:id', (req) => projectById(req.url.pathSegments.last))
///   ..post('/api/projects/:id/tasks', (req) => {'id': 'new', ...});
/// final session = guideSession(api: api);
/// ```
/// 경로의 `:이름` 칸은 아무 값과 맞는다(마지막 칸 `*`는 나머지 전부). 먼저 등록한 것이 이긴다.
/// 등록하지 않은 GET은 [fallback](기본: 경로가 /messages로 끝나면 {"messages": []}, 알림 목록은
/// {"unreadCount":0,"items":[]}, 나머지는 [])을 돌려준다 — 화면이 기대하는 모양이 다르면 등록할 것.
class GuideFakeApi {
  final _routes = <(String, List<String>, Object? Function(http.Request))>[];

  /// 받은 요청 기록(어떤 API를 부르는지 확인할 때).
  final requests = <http.Request>[];

  /// 등록 안 된 요청에 줄 응답 본문(JSON으로 바꿀 값).
  Object? Function(http.Request req) fallback = _defaultFallback;

  static Object? _defaultFallback(http.Request req) {
    final path = req.url.path;
    if (path.endsWith('/messages')) return {'messages': []};
    if (path == '/api/project-notifications') {
      return {'unreadCount': 0, 'items': []};
    }
    return req.method == 'GET' ? [] : {};
  }

  void on(String method, String path, Object? body) {
    _routes.add((
      method.toUpperCase(),
      _segments(path),
      body is Object? Function(http.Request) ? body : (_) => body,
    ));
  }

  void get(String path, Object? body) => on('GET', path, body);
  void post(String path, Object? body) => on('POST', path, body);
  void patch(String path, Object? body) => on('PATCH', path, body);
  void put(String path, Object? body) => on('PUT', path, body);
  void delete(String path, Object? body) => on('DELETE', path, body);

  static List<String> _segments(String p) =>
      p.split('/').where((s) => s.isNotEmpty).toList();

  static bool _match(List<String> pattern, List<String> actual) {
    for (var i = 0; i < pattern.length; i++) {
      if (pattern[i] == '*') return true;
      if (i >= actual.length) return false;
      if (pattern[i].startsWith(':')) continue;
      if (pattern[i] != actual[i]) return false;
    }
    return pattern.length == actual.length;
  }

  http.Client get client => MockClient((request) async {
    requests.add(request);
    final segs = _segments(request.url.path);
    for (final (method, pattern, handler) in _routes) {
      if (method == request.method && _match(pattern, segs)) {
        return _json(handler(request));
      }
    }
    return _json(fallback(request));
  });

  static http.Response _json(Object? body) {
    if (body is http.Response) return body;
    return http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  }
}

/// 로그인까지 끝난 것처럼 채운 [Session] — 기존 위젯 테스트(test/project_topbar_test.dart 등)가
/// 쓰는 방식과 같다. 소켓은 연결하지 않으므로 실시간 이벤트가 필요한 화면은 session의
/// 필드(rooms, teams …)를 직접 채운 뒤 `session.notifyListeners()`로 다시 그리게 하면 된다.
Session guideSession({
  GuideFakeApi? api,
  String serverUrl = 'https://192.168.0.10:3000',
  String userId = 'u-me',
  String username = 'hana.kim',
  String name = '김하나',
  AccountRole role = AccountRole.member,
  bool serverAdmin = false,
  List<Team>? teams,
  Team? currentTeam,
  List<Room> rooms = const [],
}) {
  final fake = api ?? GuideFakeApi();
  final session = Session(
    notifications: NotificationService(),
    settings: AppSettings(),
  );
  session.serverUrl = serverUrl;
  session.api = ApiClient(
    baseUrl: serverUrl,
    token: 'guide-token',
    httpClient: fake.client,
  );
  session.userId = userId;
  session.username = username;
  session.name = name;
  session.accountRole = role;
  session.isServerAdmin = serverAdmin;
  session.canCreateProject = role != AccountRole.guest || serverAdmin;
  final teamList =
      teams ?? [Team(id: 't1', name: '마케팅팀', createdAt: DateTime(2026, 3, 2))];
  session.teams.addAll(teamList);
  session.currentTeam = currentTeam ?? teamList.first;
  session.rooms.addAll(rooms);
  return session;
}

/// 도움말 PNG 전체 용량(목표: 10MB 미만)을 출력한다 — 캡처 파일 끝의 tearDownAll에서 불러 쓰면 좋다.
void printGuideImagesSize() {
  final files = guideImagesDir.listSync().whereType<File>().where(
    (f) => f.path.endsWith('.png'),
  );
  final total = files.fold<int>(0, (s, f) => s + f.lengthSync());
  // ignore: avoid_print
  print(
    '[guide] images: ${files.length}개, '
    '${(total / 1024 / 1024).toStringAsFixed(2)} MB',
  );
}

/// 디버그 확인용: 지금 화면에서 [finder]의 위치를 출력한다(표시 좌표를 맞출 때).
void debugPrintRect(WidgetTester tester, Finder finder) {
  debugPrint('$finder → ${tester.getRect(finder)}');
}
