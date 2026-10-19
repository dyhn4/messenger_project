import 'dart:async';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MissingPluginException;
import 'package:flutter_cache_manager/flutter_cache_manager.dart'
    show BaseCacheManager, HttpExceptionWithStatus;

/// 서버에 다시 연결되면(Session._resyncAfterReconnect) 올라가는 값 — 못 불러온 그림이 이 신호를 받으면 곧바로 다시 시도한다.
final imageRetrySignal = ValueNotifier<int>(0);

/// 만료된 파일 링크(/files/<토큰> — 서버 signFileUrl, 최대 2시간)를 새로 서명받아 절대 주소로 돌려준다. Session이 만들어질 때
/// 채운다(로그인 전·테스트에서는 null일 수 있다).
Future<String> Function(String url)? fileUrlResigner;

/// [CachedNetworkImage]와 같지만, 못 불러왔을 때 스스로 다시 시도한다.
///
/// [CachedNetworkImage]는 한 번 실패하면 깨진 그림을 띄운 채 그 위젯이 새로 만들어질 때까지(방을 다시 열거나 앱을 다시
/// 켤 때까지) 다시 받지 않는다. 그래서 PC를 켜자마자 자동 실행된 앱이 네트워크가 덜 잡힌 순간에 받으려던 첨부 그림·
/// 그림 이모티콘이 앱을 끌 때까지 깨진 채 남았다. 이제는
/// - 링크가 만료됐으면(401) 새 링크를 받아 한 번 더,
/// - 연결 문제(응답 없음·서버 오류·잠시 막힘)면 2초·5초·15초·30초·1분… 뒤에 다시(최대 [_maxTimedRetries]번),
/// - 서버에 다시 연결되면([imageRetrySignal]) 곧바로 다시
/// 받는다. 파일이 없거나(404) 볼 수 없는 것(403 등)은 다시 해도 같으므로 깨진 그림 그대로 둔다.
class RetryingNetworkImage extends StatefulWidget {
  final String imageUrl;
  final String? cacheKey;

  /// 다른 캐시에 둘 때(대화 사진 — chat_image_cache.dart). 없으면 기본 캐시.
  final BaseCacheManager? cacheManager;
  final double? width;
  final double? height;
  final BoxFit? fit;
  final Alignment alignment;
  final FilterQuality filterQuality;
  final int? memCacheWidth;
  final Duration fadeInDuration;
  final PlaceholderWidgetBuilder? placeholder;
  final LoadingErrorWidgetBuilder? errorWidget;

  /// 다시 시도할 때마다(새로 받기 시작할 때) 그 링크(새로 서명받았으면 새 링크)로 불린다 — 같은 그림을 따로 풀어 크기를
  /// 재는 곳이 함께 다시 재도록.
  final ValueChanged<String>? onRetry;

  const RetryingNetworkImage({
    super.key,
    required this.imageUrl,
    this.cacheKey,
    this.cacheManager,
    this.width,
    this.height,
    this.fit,
    this.alignment = Alignment.center,
    this.filterQuality = FilterQuality.low,
    this.memCacheWidth,
    this.fadeInDuration = const Duration(milliseconds: 500),
    this.placeholder,
    this.errorWidget,
    this.onRetry,
  });

  @override
  State<RetryingNetworkImage> createState() => _RetryingNetworkImageState();
}

/// 연결 문제로 실패했을 때 다시 시도하기까지 기다리는 시간(초) — 끝 값을 넘으면 그 값으로 계속.
const _retryDelays = [2, 5, 15, 30, 60];
const _maxTimedRetries = 8;

/// 그림을 못 불러왔을 때 할 일.
enum ImageRetryAction {
  /// 링크가 만료됐다(401) — 새 링크를 받아 다시.
  resign,

  /// 연결 문제(응답 없음·서버 오류·잠시 막힘) — 잠시 뒤 다시.
  later,

  /// 파일이 없거나(404) 볼 수 없거나(403 등), 그림을 받을 수 없는 환경(플러그인 없음) — 다시 해도 같다.
  giveUp,
}

ImageRetryAction imageRetryActionFor(Object error) {
  final status = error is HttpExceptionWithStatus ? error.statusCode : null;
  if (status == 401) return ImageRetryAction.resign;
  if (status != null && status < 500 && status != 408 && status != 429) {
    return ImageRetryAction.giveUp;
  }
  if (error is MissingPluginException) return ImageRetryAction.giveUp;
  return ImageRetryAction.later;
}

/// [retries]번 다시 해 본 뒤 다음 시도까지 기다릴 시간 — 다 써서 더 하지 않으면 null(그 뒤로는 다시 연결될 때만).
Duration? imageRetryDelay(int retries) {
  if (retries >= _maxTimedRetries) return null;
  return Duration(
    seconds: _retryDelays[math.min(retries, _retryDelays.length - 1)],
  );
}

class _RetryingNetworkImageState extends State<RetryingNetworkImage> {
  /// 바뀌면 [CachedNetworkImage]를 새로 만들어 다시 받는다(실패한 그림은 이미지 캐시에서 빠져 있다).
  int _attempt = 0;

  /// 새로 서명받은 링크 — 있으면 [RetryingNetworkImage.imageUrl] 대신 쓴다.
  String? _freshUrl;
  bool _resigned = false;

  /// 이번 시도가 실패했는지 — 실패한 동안 errorWidget이 다시 그려질 때마다 또 처리하지 않게.
  bool _failed = false;
  int _timedRetries = 0;
  Timer? _timer;

  String get _url => _freshUrl ?? widget.imageUrl;

  @override
  void initState() {
    super.initState();
    imageRetrySignal.addListener(_onReconnect);
  }

  @override
  void didUpdateWidget(RetryingNetworkImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 다른 그림(또는 화면이 새 링크를 받아 온 같은 그림)이면 처음부터.
    if (oldWidget.imageUrl != widget.imageUrl) {
      _timer?.cancel();
      _freshUrl = null;
      _resigned = false;
      _failed = false;
      _timedRetries = 0;
    }
  }

  @override
  void dispose() {
    imageRetrySignal.removeListener(_onReconnect);
    _timer?.cancel();
    super.dispose();
  }

  void _onReconnect() {
    if (!_failed || !mounted) return;
    _timedRetries = 0;
    _retry();
  }

  void _retry() {
    _timer?.cancel();
    if (!mounted) return;
    setState(() {
      _attempt++;
      _failed = false;
    });
    widget.onRetry?.call(_url);
  }

  /// errorWidget을 그리는 중에 불린다 — 화면을 바꾸는 일은 이번 프레임이 끝난 뒤에.
  void _onError(Object error) {
    if (_failed) return;
    _failed = true;
    final failedAttempt = _attempt;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _failed && _attempt == failedAttempt) {
        unawaited(_handleFailure(error));
      }
    });
  }

  Future<void> _handleFailure(Object error) async {
    final action = imageRetryActionFor(error);
    if (action == ImageRetryAction.resign) {
      // 만료된 링크 — 새 링크로 한 번만(새 링크도 401이면 더 하지 않는다).
      final resign = fileUrlResigner;
      if (_resigned || resign == null || !_isFileLink(_url)) return;
      final attempt = _attempt;
      try {
        final fresh = await resign(_url);
        if (!mounted || _attempt != attempt) return;
        _resigned = true;
        _freshUrl = fresh;
        _retry();
      } catch (_) {
        // 새 링크를 못 받았으면(연결 문제 등) 잠시 뒤 다시 — 그때도 401이면 새 링크부터 다시 받는다.
        if (mounted && _attempt == attempt) _scheduleRetry();
      }
      return;
    }
    if (action == ImageRetryAction.later) _scheduleRetry();
  }

  void _scheduleRetry() {
    final delay = imageRetryDelay(_timedRetries);
    if (delay == null) return;
    _timedRetries++;
    _timer?.cancel();
    _timer = Timer(delay, _retry);
  }

  static bool _isFileLink(String url) =>
      Uri.tryParse(url)?.path.startsWith('/files/') ?? false;

  @override
  Widget build(BuildContext context) {
    final errorWidget = widget.errorWidget;
    return CachedNetworkImage(
      key: ValueKey(_attempt),
      imageUrl: _url,
      cacheKey: widget.cacheKey,
      cacheManager: widget.cacheManager,
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      alignment: widget.alignment,
      filterQuality: widget.filterQuality,
      memCacheWidth: widget.memCacheWidth,
      fadeInDuration: widget.fadeInDuration,
      placeholder: widget.placeholder,
      errorWidget: (context, url, error) {
        _onError(error);
        return errorWidget?.call(context, url, error) ??
            const Icon(Icons.broken_image_outlined);
      },
    );
  }
}
