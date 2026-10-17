import 'dart:async';

import 'package:flutter/services.dart';

import 'app_platform.dart';

/// 다른 앱에서 공유받은 파일 하나 — 안드로이드가 이 앱의 캐시 폴더에 복사해 둔 경로(MainActivity.kt / ShareIntake.kt).
class SharedFile {
  final String path;
  final String name;
  final String? mimeType;
  final int? size;
  const SharedFile({
    required this.path,
    required this.name,
    this.mimeType,
    this.size,
  });

  bool get isImage => (mimeType ?? '').startsWith('image/');
}

/// "공유 → TangoTalk"으로 받은 것 — 글(링크 포함)과 파일들.
class SharedPayload {
  final String? text;
  final List<SharedFile> files;
  const SharedPayload({this.text, this.files = const []});

  bool get isEmpty => (text ?? '').trim().isEmpty && files.isEmpty;

  /// 채널에서 받은 모양 → 값. 글은 제목(EXTRA_SUBJECT)이 따로 오면 앞에 붙인다(브라우저의 "페이지 공유" 등).
  static SharedPayload? fromChannel(Object? raw) {
    if (raw is! Map) return null;
    final text = raw['text'] as String?;
    final subject = raw['subject'] as String?;
    final joined = [
      if ((subject ?? '').trim().isNotEmpty && !(text ?? '').contains(subject!))
        subject.trim(),
      if ((text ?? '').trim().isNotEmpty) text!.trim(),
    ].join('\n');
    final files = [
      for (final f in raw['files'] as List? ?? const [])
        if (f is Map && f['path'] is String)
          SharedFile(
            path: f['path'] as String,
            name: f['name'] as String? ?? '파일',
            mimeType: f['mimeType'] as String?,
            size: (f['size'] as num?)?.toInt(),
          ),
    ];
    final payload = SharedPayload(
      text: joined.isEmpty ? null : joined,
      files: files,
    );
    return payload.isEmpty ? null : payload;
  }
}

/// 안드로이드의 "공유 → TangoTalk"과 홈 화면 위젯에서 누른 방을 받는다(채널 tangotalk/share — MainActivity.kt). 앱이 막 켜졌을 때
/// 온 것은 [takeInitial]로, 켜져 있을 때 온 것은 [onShare]·[onOpenRoom]으로. 다른 플랫폼에서는 아무것도 하지 않는다.
class ShareIntake {
  ShareIntake({MethodChannel? channel, bool? enabled})
    : _channel = channel ?? const MethodChannel('tangotalk/share'),
      _enabled = enabled ?? AppPlatform.isAndroid;

  final MethodChannel _channel;
  final bool _enabled;

  /// 받을 곳을 걸고, 앱이 켜지기 전에 온 것을 가져온다.
  Future<void> start({
    required void Function(SharedPayload payload) onShare,
    required void Function(String roomId) onOpenRoom,
  }) async {
    if (!_enabled) return;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'shareReceived':
          final payload = SharedPayload.fromChannel(call.arguments);
          if (payload != null) onShare(payload);
        case 'openRoom':
          final roomId = call.arguments;
          if (roomId is String && roomId.isNotEmpty) onOpenRoom(roomId);
      }
      return null;
    });
    try {
      final initial = await _channel.invokeMethod<Object?>('takeInitial');
      if (initial is! Map) return;
      final payload = SharedPayload.fromChannel(initial['share']);
      if (payload != null) onShare(payload);
      final roomId = initial['openRoomId'];
      if (roomId is String && roomId.isNotEmpty) onOpenRoom(roomId);
    } on MissingPluginException {
      // 예전 앱 껍데기(채널 없음) — 무시.
    } on PlatformException {
      // 무시.
    }
  }
}
