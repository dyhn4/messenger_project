import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:win32/win32.dart'
    show
        FindWindow,
        GetForegroundWindow,
        SW_RESTORE,
        SetForegroundWindow,
        ShowWindow,
        TEXT;

import '../widgets/avatar_utils.dart' show parseHexColor;

/// 앱이 살아있는 동안(포그라운드/백그라운드) 새 메시지를 로컬 알림으로 보여준다.
/// 완전히 종료된 앱을 깨우는 진짜 푸시(FCM)는 범위 밖 — Session이 소켓으로 받은
/// 메시지에 대해서만 호출된다.
class NotificationService {
  final _plugin = FlutterLocalNotificationsPlugin();

  /// [requestPermission]을 false로 주면 권한 요청을 건너뛴다 — main.dart의 FCM 백그라운드
  /// 핸들러(앱이 완전히 꺼진 상태에서 별도의 헤드리스 isolate로 실행됨)에서 쓰는 경로다.
  /// 그 isolate엔 화면/Activity가 없어서 권한 요청 다이얼로그를 띄울 수 없고, 실제로
  /// 시도하면 플러그인 내부에서 Context가 null이라 NullPointerException으로 죽는다
  /// (앱을 완전히 종료했을 때 푸시 알림이 하나도 안 뜨던 원인이 바로 이거였다). 권한은
  /// 이미 앱을 처음 켰을 때(메인 isolate)의 이 함수 호출에서 요청/획득돼 있으므로, 백그라운드
  /// 경로에서는 요청 없이 그냥 알림을 그리기만 하면 된다.
  Future<void> init({
    required void Function(String roomId) onTap,
    bool requestPermission = true,
  }) async {
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const windows = WindowsInitializationSettings(
      appName: '메신저',
      appUserModelId: 'com.messenger.client',
      guid: 'ae1f2c84-355a-42fa-8166-f9b7e1d1feba',
    );

    await _plugin.initialize(
      settings: const InitializationSettings(
        android: android,
        windows: windows,
      ),
      onDidReceiveNotificationResponse: (response) {
        if (Platform.isWindows) _bringWindowToFront();
        final roomId = response.payload;
        if (roomId != null) onTap(roomId);
      },
    );

    if (!requestPermission) return;
    await _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.requestNotificationsPermission();
  }

  /// 앱이 완전히 종료된 상태에서 알림을 눌러 새로 켜진 경우, 그 알림의 payload(roomId)를
  /// 돌려준다. 이 경우 [init]에 넘긴 onTap 콜백은 안 불린다 — 그 콜백을 등록한 건 알림을
  /// 눌러서 새로 뜬 이번 프로세스인데, 콜백은 "이미 실행 중이던 앱을 포그라운드로 끌어올린"
  /// 탭에만 반응하기 때문이다. 대신 시작 시 이 메서드로 "무엇을 눌러서 켜졌는지" 직접 물어야 한다.
  Future<String?> getLaunchPayload() async {
    final details = await _plugin.getNotificationAppLaunchDetails();
    if (details?.didNotificationLaunchApp != true) return null;
    return details?.notificationResponse?.payload;
  }

  /// [avatarUrl]은 이미 절대경로로 resolve된 URL이어야 한다(Session이 resolveUrl 적용해서 넘김).
  /// 업로드 사진('photo')은 그대로 받아오고, 캐릭터('character')는 이모지+배경색을 직접
  /// 원형 PNG로 그려서 아이콘으로 쓴다. 그 외(기본 이니셜)는 앱 아이콘 그대로.
  ///
  /// [isSecret]이면(비밀 대화) 아바타 오른쪽 아래에 room_avatar.dart와 같은 모양의 초록 자물쇠
  /// 배지를 그려 넣는다 — 알림 제목은 OS가 그리는 일반 텍스트라 위젯처럼 색 있는 아이콘을
  /// 나란히 붙일 수 없어서, 그 대신 아바타 이미지 쪽에 배지를 합성하는 방식으로 표현한다.
  Future<void> showMessage({
    required String title,
    required String body,
    required String roomId,
    String avatarType = 'initial',
    String? avatarEmoji,
    String? avatarColor,
    String? avatarUrl,
    bool isSecret = false,
  }) async {
    var avatarBytes = await _resolveAvatarBytes(
      avatarType: avatarType,
      avatarEmoji: avatarEmoji,
      avatarColor: avatarColor,
      avatarUrl: avatarUrl,
    );
    // 배지를 직접 그려 넣은 뒤에는 Windows 쪽 자체 원형 크롭(WindowsImageCrop.circle)을
    // 끈다 — 그 크롭이 이미지 전체 사각형 기준으로 원을 오려내서, 모서리에 그린 배지가
    // 잘려나가기 때문이다(우리가 이미 원형으로 오려서 그렸으므로 다시 자를 필요 없음).
    var badged = false;
    if (isSecret && avatarBytes != null) {
      avatarBytes = await _badgeWithLock(avatarBytes);
      badged = true;
    }

    Uri? windowsImageUri;
    if (avatarBytes != null && Platform.isWindows) {
      windowsImageUri = await _writeTempPng(avatarBytes);
    }

    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        'messages',
        '새 메시지',
        channelDescription: '새 채팅 메시지 알림',
        importance: Importance.high,
        priority: Priority.high,
        largeIcon: avatarBytes != null
            ? ByteArrayAndroidBitmap(avatarBytes)
            : null,
      ),
      windows: WindowsNotificationDetails(
        images: [
          if (windowsImageUri != null)
            WindowsImage(
              windowsImageUri,
              altText: title,
              placement: WindowsImagePlacement.appLogoOverride,
              crop: badged ? null : WindowsImageCrop.circle,
            )
          else
            WindowsImage(
              WindowsImage.getAssetUri('assets/icon.png'),
              altText: '메신저',
              placement: WindowsImagePlacement.appLogoOverride,
              crop: WindowsImageCrop.circle,
            ),
        ],
      ),
    );
    await _plugin.show(
      id: roomId.hashCode,
      title: title,
      body: body,
      notificationDetails: details,
      payload: roomId,
    );

    if (Platform.isWindows) _flashWindowsTaskbar();
  }

  Future<Uint8List?> _resolveAvatarBytes({
    required String avatarType,
    String? avatarEmoji,
    String? avatarColor,
    String? avatarUrl,
  }) async {
    if (avatarType == 'photo' && avatarUrl != null) {
      try {
        final res = await http
            .get(Uri.parse(avatarUrl))
            .timeout(const Duration(seconds: 3));
        if (res.statusCode == 200) return res.bodyBytes;
      } catch (_) {
        // 프로필 사진을 못 받아오면 조용히 기본 아이콘으로 대체한다.
      }
      return null;
    }
    if (avatarType == 'character' && avatarEmoji != null) {
      return _renderCharacterAvatar(
        emoji: avatarEmoji,
        color: parseHexColor(avatarColor) ?? const ui.Color(0xFF9AA6B2),
      );
    }
    return null;
  }

  /// 이모지+배경색을 원형 PNG로 직접 그린다(위젯 트리 없이 dart:ui Canvas만 사용).
  Future<Uint8List> _renderCharacterAvatar({
    required String emoji,
    required ui.Color color,
  }) async {
    const size = 128.0;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    canvas.drawCircle(
      const Offset(size / 2, size / 2),
      size / 2,
      Paint()..color = color,
    );

    final textPainter = TextPainter(
      text: TextSpan(
        text: emoji,
        style: const TextStyle(fontSize: size * 0.55),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    textPainter.paint(
      canvas,
      Offset(
        size / 2 - textPainter.width / 2,
        size / 2 - textPainter.height / 2,
      ),
    );

    final picture = recorder.endRecording();
    final image = await picture.toImage(size.toInt(), size.toInt());
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    return byteData!.buffer.asUint8List();
  }

  /// [avatarBytes]를 원형으로 오려서 캔버스 가운데 그리고, 오른쪽 아래에 흰 테두리+초록 원
  /// 배지를 얹어 그 안에 자물쇠 모양을 그린다 — room_avatar.dart의 비밀 대화 배지(초록
  /// Icons.lock)와 같은 자리/느낌. 배지가 들어갈 여백을 남기려고 아바타는 캔버스 전체가
  /// 아니라 살짝 작은 반지름으로 그린다.
  Future<Uint8List> _badgeWithLock(Uint8List avatarBytes) async {
    final codec = await ui.instantiateImageCodec(avatarBytes);
    final frame = await codec.getNextFrame();
    final source = frame.image;

    const size = 128.0;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    const avatarRadius = size * 0.42;
    const avatarCenter = Offset(size / 2, size / 2);
    canvas.save();
    canvas.clipPath(
      Path()
        ..addOval(Rect.fromCircle(center: avatarCenter, radius: avatarRadius)),
    );
    // 원본이 정사각형이 아니면(세로/가로로 긴 사진) 짧은 변에 맞춰 가운데를 정사각형으로
    // 잘라서 채운다 — 프로필 사진이 찌그러지지 않게.
    final srcSize = math.min(source.width.toDouble(), source.height.toDouble());
    final srcRect = Rect.fromCenter(
      center: Offset(source.width / 2, source.height / 2),
      width: srcSize,
      height: srcSize,
    );
    canvas.drawImageRect(
      source,
      srcRect,
      Rect.fromCircle(center: avatarCenter, radius: avatarRadius),
      Paint(),
    );
    canvas.restore();

    // 흰 테두리(badgeRadius * 1.18)까지 포함해서 캔버스(size x size) 밖으로 안 나가야 한다 —
    // 전에는 0.2였는데 테두리가 캔버스 경계를 넘어가서 잘렸다. avatarCenter + avatarRadius*0.78
    // (배지 중심 오프셋) + badgeRadius*1.18(테두리 반지름)이 size/2보다 여유 있게 작도록 줄였다.
    const badgeRadius = size * 0.125;
    final badgeCenter = Offset(
      avatarCenter.dx + avatarRadius * 0.78,
      avatarCenter.dy + avatarRadius * 0.78,
    );
    canvas.drawCircle(
      badgeCenter,
      badgeRadius * 1.18,
      Paint()..color = const ui.Color(0xFFFFFFFF),
    );
    canvas.drawCircle(
      badgeCenter,
      badgeRadius,
      Paint()..color = const ui.Color(0xFF2E7D32),
    );
    _paintLockGlyph(canvas, badgeCenter, badgeRadius * 0.62);

    final picture = recorder.endRecording();
    final image = await picture.toImage(size.toInt(), size.toInt());
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    return byteData!.buffer.asUint8List();
  }

  /// Icons.lock 모양을 단순화해서 흰색으로 직접 그린다(몸통 = 둥근 사각형, 고리 = 반원 아치).
  /// 이모지 글리프 대신 벡터로 그려서, 플랫폼/폰트에 상관없이 항상 같은 모양이 나온다.
  void _paintLockGlyph(Canvas canvas, Offset center, double r) {
    final bodyPaint = Paint()..color = const ui.Color(0xFFFFFFFF);
    final bodyRect = Rect.fromCenter(
      center: Offset(center.dx, center.dy + r * 0.28),
      width: r * 1.7,
      height: r * 1.3,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(bodyRect, Radius.circular(r * 0.25)),
      bodyPaint,
    );

    final shacklePaint = Paint()
      ..color = const ui.Color(0xFFFFFFFF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = r * 0.32
      ..strokeCap = StrokeCap.round;
    final shackleRect = Rect.fromCenter(
      center: Offset(center.dx, center.dy - r * 0.18),
      width: r * 1.15,
      height: r * 1.15,
    );
    canvas.drawArc(shackleRect, math.pi, math.pi, false, shacklePaint);
  }

  Future<Uri> _writeTempPng(Uint8List bytes) async {
    final path =
        '${Directory.systemTemp.path}${Platform.pathSeparator}msg_avatar_${DateTime.now().microsecondsSinceEpoch}.png';
    final file = File(path);
    await file.writeAsBytes(bytes);
    return Uri.file(file.path, windows: true);
  }

  int _findOurWindow() {
    final classNamePtr = TEXT('FLUTTER_RUNNER_WIN32_WINDOW');
    try {
      return FindWindow(classNamePtr, nullptr);
    } finally {
      calloc.free(classNamePtr);
    }
  }

  void _bringWindowToFront() {
    final hwnd = _findOurWindow();
    if (hwnd == 0) return;
    ShowWindow(hwnd, SW_RESTORE);
    SetForegroundWindow(hwnd);
  }

  void _flashWindowsTaskbar() {
    final hwnd = _findOurWindow();
    if (hwnd == 0 || GetForegroundWindow() == hwnd)
      return; // 창이 없거나 이미 보고 있으면 건너뜀

    final info = calloc<_FLASHWINFO>();
    try {
      info.ref
        ..cbSize = sizeOf<_FLASHWINFO>()
        ..hwnd = hwnd
        ..dwFlags = _flashwAll | _flashwTimerNoFg
        ..uCount = 0
        ..dwTimeout = 0;
      _flashWindowEx(info);
    } finally {
      calloc.free(info);
    }
  }
}

// win32 5.x 패키지 바인딩에 FlashWindowEx가 아직 없어서, 여기서만 필요한
// 최소한의 FFI 선언을 직접 추가했다 (다른 Win32 호출은 전부 win32 패키지 것을 그대로 씀).
const _flashwAll = 0x00000003; // FLASHW_CAPTION | FLASHW_TRAY
const _flashwTimerNoFg = 0x0000000C; // 포커스를 받을 때까지 계속 깜빡임

final class _FLASHWINFO extends Struct {
  @Uint32()
  external int cbSize;
  @IntPtr()
  external int hwnd;
  @Uint32()
  external int dwFlags;
  @Uint32()
  external int uCount;
  @Uint32()
  external int dwTimeout;
}

typedef _FlashWindowExNative = Int32 Function(Pointer<_FLASHWINFO>);
typedef _FlashWindowExDart = int Function(Pointer<_FLASHWINFO>);

final _user32 = DynamicLibrary.open('user32.dll');
final _flashWindowEx = _user32
    .lookupFunction<_FlashWindowExNative, _FlashWindowExDart>('FlashWindowEx');
