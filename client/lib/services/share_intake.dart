import 'dart:async';
import 'dart:io';

import 'package:app_links/app_links.dart';
import 'package:flutter/services.dart';

import 'app_platform.dart';
import 'file_type_utils.dart';
import '../l10n/tr.dart';

/// 다른 앱에서 공유받은 파일 하나 — 안드로이드는 이 앱의 캐시 폴더에 복사해 둔 경로(MainActivity.kt / ShareIntake.kt — [temporary]),
/// Windows는 탐색기 "보내기"로 고른 원본 파일의 경로(지우면 안 된다).
class SharedFile {
  final String path;
  final String name;
  final String? mimeType;
  final int? size;

  /// 올린 뒤 지워도 되는 복사본인지(안드로이드).
  final bool temporary;
  const SharedFile({
    required this.path,
    required this.name,
    this.mimeType,
    this.size,
    this.temporary = false,
  });

  bool get isImage =>
      (mimeType ?? '').startsWith('image/') ||
      (mimeType == null && looksLikeImagePath(name));
}

/// 한 번에 받는 파일 수(안드로이드 ShareIntake.kt와 같다).
const sharedFilesMax = 20;

/// Windows "보내기 → TangoTalk"(설치 프로그램이 SendTo 폴더에 만든 바로가기 — 인자 `--share` 뒤에 고른 파일 경로들)의 시작 인자 → 값.
/// 폴더·없는 파일은 빼고 [sharedFilesMax]개까지. `--share`가 아니면 null.
SharedPayload? sharedPayloadFromArgs(List<String> args) {
  if (args.isEmpty || args.first != '--share') return null;
  return _payloadFromPaths(args.skip(1));
}

/// 이미 떠 있는 창에 넘어온 "보내기"(windows/runner/main.cpp가 `tangotalk://share?file=…&file=…` 링크로 바꿔 넘긴다) → 값.
SharedPayload? sharedPayloadFromLink(Uri uri) {
  if (uri.scheme != 'tangotalk' || uri.host != 'share') return null;
  return _payloadFromPaths(uri.queryParametersAll['file'] ?? const []);
}

SharedPayload? _payloadFromPaths(Iterable<String> paths) {
  final files = <SharedFile>[];
  for (final path in paths) {
    if (files.length >= sharedFilesMax) break;
    final file = File(path);
    int size;
    try {
      if (!file.existsSync()) continue;
      size = file.lengthSync();
    } catch (_) {
      continue;
    }
    final name = path.split(RegExp(r'[\\/]')).last;
    files.add(SharedFile(path: path, name: name, size: size));
  }
  return files.isEmpty ? null : SharedPayload(files: files);
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
            name: f['name'] as String? ?? tr('파일'),
            mimeType: f['mimeType'] as String?,
            size: (f['size'] as num?)?.toInt(),
            temporary: true,
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
/// 온 것은 [takeInitial]로, 켜져 있을 때 온 것은 [onShare]·[onOpenRoom]으로. Windows는 탐색기 "보내기 → TangoTalk"을 받는다 — 앱이 막
/// 켜졌으면 시작 인자([launchArgs] — main()이 넣는다)로, 떠 있는 창이면 링크([links] — app_links)로. 그 밖의 플랫폼에서는 아무것도 하지 않는다.
class ShareIntake {
  ShareIntake({
    MethodChannel? channel,
    bool? enabled,
    bool? windows,
    this.args,
    this.links,
  }) : _channel = channel ?? const MethodChannel('tangotalk/share'),
       // [enabled]는 안드로이드 채널, [windows]는 "보내기" — 시험에서 바꿔 끼운다.
       _enabled = enabled ?? AppPlatform.isAndroid,
       _windows = windows ?? AppPlatform.isWindows;

  /// 앱 시작 인자(main(args) — Windows "보내기"면 `--share` 뒤에 파일 경로들).
  static List<String> launchArgs = const [];

  final MethodChannel _channel;
  final bool _enabled;
  final bool _windows;

  /// 시작 인자·링크 흐름 — 비우면 [launchArgs]·app_links(시험에서 바꿔 끼운다).
  final List<String>? args;
  final Stream<Uri>? links;
  StreamSubscription<Uri>? _linkSub;

  /// 받을 곳을 걸고, 앱이 켜지기 전에 온 것을 가져온다.
  Future<void> start({
    required void Function(SharedPayload payload) onShare,
    required void Function(String roomId) onOpenRoom,
  }) async {
    if (!_enabled && _windows) {
      final initial = sharedPayloadFromArgs(args ?? launchArgs);
      if (initial != null) onShare(initial);
      _linkSub = (links ?? AppLinks().uriLinkStream).listen((uri) {
        final payload = sharedPayloadFromLink(uri);
        if (payload != null) onShare(payload);
      });
      return;
    }
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

  void dispose() => _linkSub?.cancel();
}
