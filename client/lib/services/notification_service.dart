import 'dart:ffi';
import 'dart:io';
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

  Future<void> init({required void Function(String roomId) onTap}) async {
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

    await _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.requestNotificationsPermission();
  }

  /// [avatarUrl]은 이미 절대경로로 resolve된 URL이어야 한다(Session이 resolveUrl 적용해서 넘김).
  /// 업로드 사진('photo')은 그대로 받아오고, 캐릭터('character')는 이모지+배경색을 직접
  /// 원형 PNG로 그려서 아이콘으로 쓴다. 그 외(기본 이니셜)는 앱 아이콘 그대로.
  Future<void> showMessage({
    required String title,
    required String body,
    required String roomId,
    String avatarType = 'initial',
    String? avatarEmoji,
    String? avatarColor,
    String? avatarUrl,
  }) async {
    final avatarBytes = await _resolveAvatarBytes(
      avatarType: avatarType,
      avatarEmoji: avatarEmoji,
      avatarColor: avatarColor,
      avatarUrl: avatarUrl,
    );

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
              crop: WindowsImageCrop.circle,
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
