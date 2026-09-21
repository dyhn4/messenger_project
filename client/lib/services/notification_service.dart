import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:conversation_shortcuts/conversation_shortcuts.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:win32/win32.dart'
    show
        FindWindow,
        GetForegroundWindow,
        SW_RESTORE,
        SetForegroundWindow,
        ShowWindow,
        TEXT;

import '../widgets/avatar_utils.dart' show parseHexColor;

/// 비밀 대화 자물쇠 배지를 아바타의 어느 모서리에 그릴지 — _badgeWithLock 문서 참고.
enum _BadgeCorner { topLeft, bottomRight }

/// 앱이 살아있는 동안(포그라운드/백그라운드) 새 메시지를 로컬 알림으로 보여준다.
/// 완전히 종료된 앱을 깨우는 진짜 푸시(FCM)는 범위 밖 — Session이 소켓으로 받은
/// 메시지에 대해서만 호출된다.
class NotificationService {
  /// 통화 수신 알림의 payload 앞에 붙는 표시 — 알림을 눌러 앱이 켜졌을 때 "그 방 열기"와
  /// "그 방 통화에 참여"를 구분하는 데 쓴다(main.dart의 _openRoomFromNotification).
  static const callPayloadPrefix = 'call:';

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
      appName: 'TangoTalk',
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

  /// 프로젝트 알림 payload 앞에 붙는 표시 — 알림을 눌렀을 때 방이 아니라 프로젝트 창을 연다.
  static const projectPayloadPrefix = 'project:';

  /// 프로젝트 알림(업무 배정/댓글/마감 임박 등) 한 건을 보여준다 — 대화 알림과 달리 단순한
  /// 제목+본문이고, 채널도 따로 둬서 OS 설정에서 채팅 알림과 따로 끄고 켤 수 있다.
  Future<void> showProjectNotification({
    required String title,
    required String body,
    required String projectId,
  }) async {
    await _plugin.show(
      id: 'project:${DateTime.now().microsecondsSinceEpoch}'.hashCode,
      title: title,
      body: body,
      notificationDetails: NotificationDetails(
        android: const AndroidNotificationDetails(
          'project_updates',
          '프로젝트 알림',
          channelDescription: '업무 배정·댓글·마감 임박 등 프로젝트 알림',
          importance: Importance.high,
          priority: Priority.high,
        ),
        windows: const WindowsNotificationDetails(),
      ),
      payload: '$projectPayloadPrefix$projectId',
    );
  }

  /// 걸려온 화상회의를 "전화처럼" 알린다 — 잠금화면에서도 바로 뜨도록 전체화면 인텐트를
  /// 쓰고(fullScreenIntent), 카테고리를 call로 줘서 OS가 통화 알림으로 취급하게 한다.
  /// 화면이 켜져 있으면 OS가 전체화면 대신 헤드업 알림으로 보여준다(안드로이드 규칙).
  ///
  /// payload에 [callPayloadPrefix]를 붙여서, 알림을 눌러 앱이 켜졌을 때 "방 열기"가 아니라
  /// "통화 참여"로 분기할 수 있게 한다(main.dart의 _openRoomFromNotification).
  ///
  /// Windows에는 전체화면 인텐트 개념이 없어서 일반 토스트로 뜬다 — PC는 앱이 트레이에
  /// 상주하는 구조라 대부분 소켓으로 수신 화면을 직접 띄운다(home_screen.dart).
  Future<void> showIncomingCall({
    required String roomId,
    required String callerName,
    String? conversationTitle,
  }) async {
    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        'calls',
        '화상회의 수신',
        channelDescription: '걸려온 화상회의 알림',
        importance: Importance.max,
        priority: Priority.max,
        category: AndroidNotificationCategory.call,
        fullScreenIntent: true,
        // 사용자가 받거나 끊기 전까지 알림이 유지되게 한다(스와이프로 지워지지 않음).
        ongoing: true,
        autoCancel: false,
        timeoutAfter: 45000, // 서버 푸시 ttl과 같은 45초 — 지나간 전화는 저절로 사라진다.
      ),
      windows: const WindowsNotificationDetails(),
    );
    await _plugin.show(
      id: 'call:$roomId'.hashCode,
      title: callerName,
      body: conversationTitle == null
          ? '화상회의 요청'
          : '$conversationTitle · 화상회의 요청',
      notificationDetails: details,
      payload: '$callPayloadPrefix$roomId',
    );
  }

  /// 통화 수신 알림을 지운다(받았거나, 상대가 끊었을 때).
  Future<void> cancelIncomingCall(String roomId) =>
      _plugin.cancel(id: 'call:$roomId'.hashCode);

  /// 방마다 아직 안 지운(=사용자가 확인 안 한) 알림 메시지 기록 — 같은 방에서 메시지가 여러 개
  /// 와도 알림 id는 방 하나당 하나(roomId.hashCode)라 새 메시지가 이전 알림을 덮어써서, 예전엔
  /// 알림 한 줄·런처 아이콘 배지 "1"로만 보였다. 이 기록에 쌓아서 알림에 최근 메시지를 전부 보여주고
  /// 배지 숫자([AndroidNotificationDetails.number])를 실제 개수로 올린다.
  /// 앱이 꺼져있을 때 FCM 백그라운드 isolate(main.dart)에서도 이어서 쌓아야 해서, isolate끼리
  /// 값이 유지되는 SharedPreferencesAsync에 저장한다(fcm 핸들러가 쓰는 것과 같은 방식).
  static const _historyKeyPrefix = 'notif_history:';
  static const _historyMax = 30;
  late final _historyPrefs = SharedPreferencesAsync();

  Future<List<({String name, String body, int ms})>> _appendHistory(
    String roomId,
    String name,
    String body,
  ) async {
    final key = '$_historyKeyPrefix$roomId';
    var stored = await _historyPrefs.getStringList(key) ?? <String>[];
    // 사용자가 알림을 옆으로 밀어서 지웠거나 다른 경로로 사라졌으면(이 앱은 그걸 알림 삭제
    // 이벤트로 못 받는다) 화면에 알림이 실제로 없는 것이므로 기록도 새로 시작한다.
    try {
      final active = await _plugin.getActiveNotifications();
      if (!active.any((n) => n.id == roomId.hashCode)) stored = <String>[];
    } catch (_) {}
    stored = [
      ...stored,
      jsonEncode({
        'n': name,
        'b': body,
        't': DateTime.now().millisecondsSinceEpoch,
      }),
    ];
    if (stored.length > _historyMax) {
      stored = stored.sublist(stored.length - _historyMax);
    }
    await _historyPrefs.setStringList(key, stored);
    return [
      for (final raw in stored)
        () {
          final m = jsonDecode(raw) as Map<String, dynamic>;
          return (
            name: m['n'] as String,
            body: m['b'] as String,
            ms: m['t'] as int,
          );
        }(),
    ];
  }

  /// [avatarUrl]은 이미 절대경로로 resolve된 URL이어야 한다(Session이 resolveUrl 적용해서 넘김).
  /// 업로드 사진('photo')은 그대로 받아오고, 캐릭터('character')는 이모지+배경색을 직접
  /// 원형 PNG로 그려서 아이콘으로 쓴다. 그 외(기본 이니셜)는 앱 아이콘 그대로.
  ///
  /// [isSecret]이면(비밀 대화) 아바타 오른쪽 아래에 room_avatar.dart와 같은 모양의 초록 자물쇠
  /// 배지를 그려 넣는다 — 알림 제목은 OS가 그리는 일반 텍스트라 위젯처럼 색 있는 아이콘을
  /// 나란히 붙일 수 없어서, 그 대신 아바타 이미지 쪽에 배지를 합성하는 방식으로 표현한다.
  /// [senderName]/[conversationTitle]은 안드로이드의 "대화(conversation)" 알림 레이아웃을
  /// 만들기 위해 [title]("보낸사람 [방]")을 쪼개서 받는 것이다 — 안 주면 [title]로 폴백한다.
  Future<void> showMessage({
    required String title,
    required String body,
    required String roomId,
    String? senderName,
    String? conversationTitle,
    String avatarType = 'initial',
    String? avatarEmoji,
    String? avatarColor,
    String? avatarUrl,
    bool isSecret = false,
  }) async {
    final baseAvatarBytes = await _resolveAvatarBytes(
      avatarType: avatarType,
      avatarEmoji: avatarEmoji,
      avatarColor: avatarColor,
      avatarUrl: avatarUrl,
      fallbackLabel: senderName ?? title,
    );
    // 안드로이드의 "대화" 레이아웃은 오른쪽 아래에 시스템 앱 아이콘 배지를 항상 따로
    // 덧그려서 그 자리의 배지를 가려버리므로(_badgeWithLock 문서 참고) 안드로이드는 계속
    // 왼쪽 위에 그린다. Windows 토스트에는 그런 시스템 배지가 없어서 오른쪽 아래로
    // 옮길 수 있다 — room_avatar.dart의 다른 배지들과도 위치가 더 잘 맞는다.
    var avatarBytes = baseAvatarBytes;
    Uint8List? windowsAvatarBytes;
    var windowsBadged = false;
    if (isSecret) {
      avatarBytes = await _badgedOrFallback(
        baseAvatarBytes,
        corner: _BadgeCorner.topLeft,
        fallbackLabel: senderName ?? title,
      );
      if (Platform.isWindows) {
        windowsAvatarBytes = await _badgedOrFallback(
          baseAvatarBytes,
          corner: _BadgeCorner.bottomRight,
          fallbackLabel: senderName ?? title,
        );
        windowsBadged = true;
      }
    }

    final windowsImageUri = Platform.isWindows
        ? await _writeTempPng(windowsAvatarBytes ?? avatarBytes)
        : null;

    // 안드로이드: 프로필 사진을 largeIcon으로만 주면 알림 "오른쪽"에 따로 떨어져 나온다.
    // 참고 이미지처럼 프로필 사진이 왼쪽 큰 원으로 오고 앱 아이콘이 그 모서리에 작은 배지로
    // 붙는 건 OS의 "대화(conversation)" 레이아웃이고, 그건 MessagingStyle + (Android 11+에서는)
    // 같은 id의 long-lived 단축키(shortcut)가 있어야 적용된다 — MainActivity에서 방마다
    // 단축키를 등록해두고(conversation_shortcuts.dart) 여기서 그 id를 참조한다.
    final sender = Person(
      key: senderName ?? title,
      name: senderName ?? title,
      important: true,
      icon: ByteArrayAndroidIcon(avatarBytes),
    );
    final history = Platform.isAndroid
        ? await _appendHistory(roomId, senderName ?? title, body)
        : null;
    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        'messages',
        '새 메시지',
        channelDescription: '새 채팅 메시지 알림',
        importance: Importance.high,
        priority: Priority.high,
        shortcutId: roomId,
        // 런처 아이콘 배지 숫자 — 안 지운 이 방 메시지 개수(위 _appendHistory 참고).
        number: history?.length,
        styleInformation: MessagingStyleInformation(
          const Person(name: '나'),
          conversationTitle: conversationTitle,
          // conversationTitle은 groupConversation이 true일 때만 화면에 표시된다.
          groupConversation: conversationTitle != null,
          messages: history == null
              ? [Message(body, DateTime.now(), sender)]
              : [
                  for (var i = 0; i < history.length; i++)
                    Message(
                      history[i].body,
                      DateTime.fromMillisecondsSinceEpoch(history[i].ms),
                      // 가장 최근 것만 아바타 아이콘이 있는 Person을 쓴다(위 sender).
                      i == history.length - 1
                          ? sender
                          : Person(name: history[i].name, key: history[i].name),
                    ),
                ],
        ),
      ),
      windows: WindowsNotificationDetails(
        images: [
          if (windowsImageUri != null)
            WindowsImage(
              windowsImageUri,
              altText: title,
              placement: WindowsImagePlacement.appLogoOverride,
              crop: windowsBadged ? null : WindowsImageCrop.circle,
            )
          else
            WindowsImage(
              WindowsImage.getAssetUri('assets/icon.png'),
              altText: 'TangoTalk',
              placement: WindowsImagePlacement.appLogoOverride,
              crop: WindowsImageCrop.circle,
            ),
        ],
      ),
    );
    // 위 MessagingStyle이 실제 "대화" 레이아웃으로 승격되려면 알림보다 먼저 같은 id의
    // long-lived 단축키가 등록돼 있어야 한다(ConversationShortcuts 주석 참고).
    if (Platform.isAndroid) {
      await ConversationShortcuts.push(
        id: roomId,
        // 단축키는 사람이 아니라 "대화방"을 가리킨다. 이 라벨이 알림 윗줄(대화방 이름)로도
        // 쓰여서, 아랫줄의 보낸사람 이름과 겹치지 않게 방 이름을 그대로 넣는다.
        label: conversationTitle ?? senderName ?? title,
        icon: avatarBytes,
      );
    }

    // Windows 토스트는 아바타 이미지와 달리 제목 글자에 임의의 색을 입힐 방법이 OS API
    // 자체에 없다(라이트/다크 테마 일관성을 위해 텍스트 색은 시스템이 강제로 정한다) —
    // 그래서 "녹색 자물쇠"를 색으로는 못 넣고, 대신 이름 왼쪽에 자물쇠 이모지를 붙여서
    // 비밀 대화라는 표시를 준다. 안드로이드는 MessagingStyle이 title을 그대로 안 쓰고
    // 자체 레이아웃(Person 이름)으로 그리므로 안 건드린다.
    final windowsTitle = (isSecret && Platform.isWindows) ? '🔒 $title' : title;
    await _plugin.show(
      id: roomId.hashCode,
      title: windowsTitle,
      body: body,
      notificationDetails: details,
      payload: roomId,
    );

    if (Platform.isWindows) _flashWindowsTaskbar();
  }

  /// 방을 열 때(또는 다시 포그라운드로 돌아와 그 방을 계속 보고 있을 때) 그 방으로 떠있는
  /// 알림을 지운다 — showMessage와 같은 id(roomId.hashCode)를 써야 같은 알림을 가리킨다.
  Future<void> cancelForRoom(String roomId) async {
    await _plugin.cancel(id: roomId.hashCode);
    if (Platform.isAndroid) {
      await _historyPrefs.remove('$_historyKeyPrefix$roomId');
    }
  }

  /// [fallbackLabel]의 첫 글자로 만든 원형 아바타를 마지막 대안으로 쓴다(위젯의 "이니셜"
  /// 아바타와 같은 개념) — 이게 없으면(예: avatarType이 'initial'인, 즉 대다수 회원의
  /// 기본값인 경우) avatarBytes가 계속 null이 되어, showMessage가 [isSecret]이어도
  /// `avatarBytes != null` 조건에 걸려 초록 자물쇠 배지를 아예 못 그리는 문제가 있었다.
  Future<Uint8List> _resolveAvatarBytes({
    required String avatarType,
    String? avatarEmoji,
    String? avatarColor,
    String? avatarUrl,
    required String fallbackLabel,
  }) async {
    if (avatarType == 'photo' && avatarUrl != null) {
      try {
        final res = await http
            .get(Uri.parse(avatarUrl))
            .timeout(const Duration(seconds: 3));
        if (res.statusCode == 200) return res.bodyBytes;
      } catch (_) {
        // 프로필 사진을 못 받아오면 아래 이니셜 아바타로 대체한다.
      }
    } else if (avatarType == 'character' && avatarEmoji != null) {
      return _renderCharacterAvatar(
        emoji: avatarEmoji,
        color: parseHexColor(avatarColor) ?? const ui.Color(0xFF9AA6B2),
      );
    }
    return _renderInitialAvatar(
      fallbackLabel.isNotEmpty ? fallbackLabel[0] : '?',
    );
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

  /// 프로필 사진도 캐릭터도 안 고른(기본 "이니셜") 사람 몫의 마지막 대안 — 위젯의
  /// AvatarView와 같은 느낌으로 회색 원 위에 이름 첫 글자를 그린다.
  Future<Uint8List> _renderInitialAvatar(String letter) async {
    const size = 128.0;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    canvas.drawCircle(
      const Offset(size / 2, size / 2),
      size / 2,
      Paint()..color = const ui.Color(0xFF9AA6B2),
    );

    final textPainter = TextPainter(
      text: TextSpan(
        text: letter,
        style: const TextStyle(
          fontSize: size * 0.45,
          color: ui.Color(0xFFFFFFFF),
          fontWeight: FontWeight.w600,
        ),
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

  /// [avatarBytes]를 디코딩해서 자물쇠 배지를 얹어보고, 손상/미지원 형식이라 디코딩에
  /// 실패하면(실제 프로필 사진이 원인일 수 있음) 항상 그릴 수 있는 이니셜 아바타에라도
  /// 배지를 붙여서 "이건 비밀 대화다"라는 표시만은 반드시 나오게 한다.
  Future<Uint8List> _badgedOrFallback(
    Uint8List avatarBytes, {
    required _BadgeCorner corner,
    required String fallbackLabel,
  }) async {
    try {
      return await _badgeWithLock(avatarBytes, corner: corner);
    } catch (_) {
      final fallback = await _renderInitialAvatar(
        fallbackLabel.isNotEmpty ? fallbackLabel[0] : '?',
      );
      return _badgeWithLock(fallback, corner: corner);
    }
  }

  /// [avatarBytes]를 원형으로 오려서 캔버스 가운데 그리고, [corner] 자리에 흰 테두리+초록
  /// 원 배지를 얹어 그 안에 자물쇠 모양을 그린다 — room_avatar.dart의 비밀 대화 배지(초록
  /// Icons.lock)와 같은 느낌. 배지가 들어갈 여백을 남기려고 아바타는 캔버스 전체가 아니라
  /// 살짝 작은 반지름으로 그린다.
  ///
  /// 안드로이드는 왼쪽 위([_BadgeCorner.topLeft])로 그린다: 안드로이드 알림의 "대화"
  /// 레이아웃은 오른쪽 아래에 앱 아이콘(우리가 못 바꾸는 시스템 배지)을 항상 별도 레이어로
  /// 덧그리는데, 거기에 우리 배지를 겹쳐 그리면 그 시스템 배지에 완전히 가려져 안 보인다
  /// (실제로 확인함 — 자리를 옮기는 것 말고는 피할 방법이 없다). Windows 토스트에는 그런
  /// 시스템 배지가 없어서 오른쪽 아래([_BadgeCorner.bottomRight])로 그릴 수 있다.
  Future<Uint8List> _badgeWithLock(
    Uint8List avatarBytes, {
    required _BadgeCorner corner,
  }) async {
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

    const badgeRadius = size * 0.125;
    final badgeCenter = corner == _BadgeCorner.topLeft
        ? Offset(
            avatarCenter.dx - avatarRadius * 0.78,
            avatarCenter.dy - avatarRadius * 0.78,
          )
        : Offset(
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
    if (hwnd == 0 || GetForegroundWindow() == hwnd) {
      return; // 창이 없거나 이미 보고 있으면 건너뜀
    }

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
