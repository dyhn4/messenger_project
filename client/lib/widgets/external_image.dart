import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import '../l10n/tr.dart';

/// 외부 웹사이트 이미지 — 그냥 Image.network를 쓰면 못 불러온다.
///
/// 링크 미리보기 그림(말풍선 카드·링크 모아보기)에는 더 쓰지 않는다 — 서버가 그림을 한 번 받아 서명된 /files 경로로 주고
/// (server/src/linkPreviewImage.js), 바깥 주소는 그리지 않는다(보는 사람마다 그 사이트에 직접 접속하게 된다). 지금은 업데이트
/// 전 서버가 준 바깥 북마크 이미지(bookmark_image.dart)에만 남아 있다.
/// main.dart가 앱 시작 시 PinnedTls.installGlobalHttpOverrides()로 전역 HttpClient를 "우리 서버
/// 자체 서명 인증서 하나만" 신뢰하도록 가로채놓는데(pinned_tls.dart), 이 override는 앱 전체
/// HttpClient에 다 걸려서 Image.network(CachedNetworkImage 포함)가 내부적으로 만드는 HttpClient도
/// 똑같이 적용된다 — 그래서 공인 인증서를 쓰는 일반 웹사이트 이미지는 전부 인증서 검증 실패로
/// 조용히 안 뜬다. 이 위젯은 별도 isolate(Isolate.run)에서 이미지를 받아온 뒤 Image.memory로
/// 그린다 — 새 isolate는 main isolate의 HttpOverrides.global을 안 물려받는(격리된 static 상태)
/// 덕분에 거기서 만드는 HttpClient는 평범한(공인 CA 신뢰) 기본 상태다. 우리 서버와의 통신
/// (API/소켓/첨부파일)에 쓰는 핀닝은 그대로 안전하게 유지된다.
///
/// (처음엔 HttpOverrides.runZoned로 "이 fetch만 전역 재정의를 벗어나게" 시도했는데, 그
/// zone의 createHttpClient 콜백 안에서 다시 HttpClient()를 호출하면 그 호출도 같은 zone
/// 안이라 자기 자신을 또 부르는 무한 재귀에 빠져 StackOverflowError가 났다(직접 재현해서
/// 확인함) — zone 기반 접근 자체가 이 용도에는 안 맞는 함정이었다.)
///
/// 받는 중이거나 못 받으면(원본이 지워짐·디코딩할 수 없는 형식) [placeholder]를 그린다. 같은
/// 주소는 한 번만 받는다(목록을 넘기며 다시 그려도 새로 받지 않게).
class ExternalImage extends StatefulWidget {
  final String url;
  final BoxFit fit;
  final double? width;
  final double? height;
  final Widget placeholder;

  const ExternalImage({
    super.key,
    required this.url,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.placeholder = const SizedBox.shrink(),
  });

  @override
  State<ExternalImage> createState() => _ExternalImageState();
}

class _ExternalImageState extends State<ExternalImage> {
  static const _maxBytes = 8 * 1024 * 1024; // 미리보기 이미지치고 과하게 크면 안전하게 포기.

  /// 받은(받는 중인) 이미지 — 주소마다 하나. 너무 많아지면 오래된 것부터 버린다.
  static final _cache = <String, Future<Uint8List>>{};
  static const _cacheLimit = 200;

  late final Future<Uint8List> _future = _load(widget.url);

  static Future<Uint8List> _load(String url) {
    final cached = _cache.remove(url);
    if (cached != null) return _cache[url] = cached; // 최근에 쓴 것으로 뒤에 다시 넣는다.
    if (_cache.length >= _cacheLimit) _cache.remove(_cache.keys.first);
    final future = _fetch(url);
    // 실패한 주소는 캐시에 남기지 않는다 — 다음에 다시 보이면 새로 시도한다.
    future.catchError((_) {
      _cache.remove(url);
      return Uint8List(0);
    });
    return _cache[url] = future;
  }

  static Future<Uint8List> _fetch(String url) {
    return Isolate.run(() async {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 8);
      try {
        final request = await client.getUrl(Uri.parse(url));
        final response = await request.close().timeout(
          const Duration(seconds: 8),
        );
        if (response.statusCode != 200) {
          throw Exception('HTTP ${response.statusCode}');
        }
        final bytes = <int>[];
        await for (final chunk in response) {
          bytes.addAll(chunk);
          if (bytes.length > _maxBytes) {
            throw Exception(tr('이미지가 너무 큽니다'));
          }
        }
        return Uint8List.fromList(bytes);
      } finally {
        client.close(force: true);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    // 웹은 우리 서버 인증서 핀닝(HttpOverrides)이 없어 위의 우회가 필요 없다. 다른 사이트 그림은
    // CORS를 안 열어 둔 곳이 많아서, 그럴 땐 <img> 요소로 그리게 둔다(fallback).
    if (kIsWeb) {
      return Image.network(
        widget.url,
        width: widget.width,
        height: widget.height,
        fit: widget.fit,
        webHtmlElementStrategy: WebHtmlElementStrategy.fallback,
        loadingBuilder: (_, child, progress) =>
            progress == null ? child : widget.placeholder,
        errorBuilder: (_, _, _) => widget.placeholder,
      );
    }
    return FutureBuilder<Uint8List>(
      future: _future,
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (snapshot.connectionState != ConnectionState.done ||
            bytes == null ||
            bytes.isEmpty) {
          return widget.placeholder;
        }
        return Image.memory(
          bytes,
          width: widget.width,
          height: widget.height,
          fit: widget.fit,
          errorBuilder: (_, _, _) => widget.placeholder,
        );
      },
    );
  }
}
