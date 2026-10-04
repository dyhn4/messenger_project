import 'dart:async';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:photo_view/photo_view.dart';

import '../models/message.dart';
import '../services/session.dart';
import '../widgets/file_actions.dart';
import '../models/room.dart';
import 'message_thread_screen.dart';

/// 뷰어에서 넘겨볼 이미지 한 장. 비밀 대화 이미지는 서버가 암호문만 갖고 있어서 복호화한
/// 바이트가 필요하다 — 이미 받아 둔 게 있으면 [bytesFuture]로, 그 장을 볼 때 받으면 되면
/// [loadBytes]로 준다(그 URL을 그대로 받아 그리면 암호문이 그려진다).
class ViewerImage {
  final String url;
  final Future<Uint8List>? bytesFuture;

  /// 그 장을 처음 볼 때 한 번만 부른다 — 방 전체 사진을 넘겨볼 때 안 볼 장까지 미리 받지 않게.
  final Future<Uint8List> Function()? loadBytes;

  /// 상단 바에 이름/크기를 쓰고, 다운로드·전달·인쇄가 쓴다.
  final String fileName;
  final int? fileSize;

  /// 이 장이 딸린 메시지 — 여러 메시지의 사진을 넘겨볼 때 상단 바(보낸 사람·시각)와
  /// 댓글·전달·다운로드가 지금 보이는 장의 메시지를 쓴다. 없으면 뷰어의 [ImageViewerScreen.message].
  final Message? message;

  /// 목록이 바뀌어도(과거 메시지를 더 불러와 앞에 붙어도) 같은 장을 찾기 위한 이름.
  final String id;

  /// 이 장이 메시지의 어느 첨부인지(파일 삭제용) — 첨부 하나짜리 옛 메시지나 모르면 null(메시지 id로 본다).
  final String? attachmentId;

  const ViewerImage({
    required this.url,
    this.attachmentId,
    this.bytesFuture,
    this.loadBytes,
    this.fileName = 'image.png',
    this.fileSize,
    this.message,
    String? id,
  }) : id = id ?? url;
}

/// 뷰어가 넘겨볼 사진 목록이 바뀔 수 있을 때(방의 대화 — 과거 메시지를 더 불러오거나 새 사진이
/// 올라온다) 그 목록을 주는 곳. [changes]가 알리면 [images]를 다시 읽는다.
class ViewerImageSource {
  final Listenable changes;
  final List<ViewerImage> Function() images;

  /// 서버에 더 오래된 메시지가 남아있는지.
  final bool Function() hasOlder;

  /// 더 오래된 메시지를 한 번 불러온다(사진이 없는 메시지뿐일 수도 있다).
  final Future<void> Function() loadOlder;

  const ViewerImageSource({
    required this.changes,
    required this.images,
    required this.hasOlder,
    required this.loadOlder,
  });
}

String formatFileSize(int? bytes) {
  if (bytes == null) return '';
  if (bytes < 1024) return '${bytes}bytes';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)}KB';
  return '${(bytes / 1024 / 1024).toStringAsFixed(1)}MB';
}

String _viewerDateTime(DateTime dt) {
  final isPm = dt.hour >= 12;
  final h12 = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
  String two(int v) => v.toString().padLeft(2, '0');
  return '${dt.year}/${two(dt.month)}/${two(dt.day)} '
      '${isPm ? 'PM' : 'AM'} ${two(h12)}:${two(dt.minute)}';
}

/// 이미지 확대/축소 뷰어. 채팅 버블에서 이미지를 탭하면 열립니다.
///
/// 여러 장이면 좌우 화살표(또는 키보드 ←/→)로 넘기고, 왼쪽 위에 "2 / 5"로 몇 번째인지
/// 보여줍니다. 채팅방에서 열면 [source]로 그 방의 앞뒤 메시지 사진까지 이어서 넘기고, 맨 앞에
/// 닿으면 과거 메시지를 더 불러옵니다. 배율은 100%(원본 픽셀 크기)에서 시작하되 원본이 뷰어보다
/// 크면 화면에 맞춰 열고, 아래 도구모음은 열 때 잠깐 보였다가 사라집니다 — 배율 숫자를 누르면
/// 100%로 돌아옵니다.
class ImageViewerScreen extends StatefulWidget {
  final List<ViewerImage> images;
  final int initialIndex;

  /// 상단 바(보낸 사람·시각)와 댓글·전달에 필요 — 없으면 그 버튼들은 안 보인다.
  final Session? session;
  final Message? message;

  /// 댓글 패널을 열려면 방도 있어야 한다(그 방의 컨트롤러로 댓글을 읽고 쓴다).
  final Room? room;

  /// 목록이 바뀔 수 있으면(방의 앞뒤 메시지 사진) — 없으면 [images]만 넘겨본다.
  final ViewerImageSource? source;

  /// 뷰어에서 사진 한 장을 지운 뒤 — 목록을 따로 들고 있는 화면(파일 패널)이 다시 받는다.
  final VoidCallback? onFileDeleted;

  const ImageViewerScreen({
    super.key,
    required this.images,
    this.initialIndex = 0,
    this.session,
    this.message,
    this.room,
    this.source,
    this.onFileDeleted,
  });

  /// 한 장짜리 예전 호출부를 그대로 쓰기 위한 편의 생성자.
  ImageViewerScreen.single({
    super.key,
    required String imageUrl,
    Future<Uint8List>? imageBytesFuture,
    String fileName = 'image.png',
    this.session,
    this.message,
    this.room,
  }) : images = [
         ViewerImage(
           url: imageUrl,
           bytesFuture: imageBytesFuture,
           fileName: fileName,
         ),
       ],
       initialIndex = 0,
       source = null,
       onFileDeleted = null;

  @override
  State<ImageViewerScreen> createState() => _ImageViewerScreenState();
}

class _ImageViewerScreenState extends State<ImageViewerScreen> {
  late List<ViewerImage> _images = widget.images;
  late int _index = widget.initialIndex;
  late PageController _page = PageController(initialPage: widget.initialIndex);

  /// 목록 앞에 사진이 붙어 지금 장의 번호가 바뀌면 PageView를 그 번호로 새로 만든다.
  int _pageGeneration = 0;

  /// 과거 메시지를 불러오는 중 — 왼쪽 화살표에 도는 표시를 띄운다.
  bool _loadingOlder = false;

  // 장마다 따로 두는 상태는 번호가 아니라 장의 id로 들고 있는다 — 앞에 사진이 붙어도 섞이지 않게.

  /// 장마다 따로 두는 확대/회전 상태 — 옆 장이 같이 그려지는 동안(넘기는 중) 서로 섞이지 않게.
  final _controllers = <String, PhotoViewController>{};

  /// 장마다 알아낸 원본 크기(픽셀). 알아야 "화면에 맞춤" 배율과 처음 배율을 정할 수 있다.
  final _imageSizes = <String, Size>{};
  final _sizeStreams = <String, (ImageStream, ImageStreamListener)>{};

  /// [ViewerImage.loadBytes]로 받는 장의 바이트 — 한 번만 받는다.
  final _bytes = <String, Future<Uint8List>>{};

  /// 이미지가 그려지는 영역의 크기(상단 바·댓글 패널을 뺀 자리).
  Size? _viewport;

  double _scale = 1;

  /// 지금 장을 마지막으로 그릴 때 100%(보간 없이)였는지 — 손가락으로 돌리기만 해서 배율은 그대로여도
  /// 이 값이 바뀌면 다시 그려 보간을 켜거나 끈다.
  bool _drawnActualSize = true;

  /// 도구모음은 열리자마자 잠깐 보여주고 3초 뒤 흐려진다 — 마우스를 창 위로 움직이면 다시 뜬다.
  bool _toolbarVisible = true;
  Timer? _hideToolbar;

  /// 오른쪽 댓글 패널이 열려 있는지.
  bool _commentsOpen = false;

  ViewerImage get _current => _images[_index];

  PhotoViewController _controllerFor(String id) =>
      _controllers.putIfAbsent(id, () {
        final controller = PhotoViewController();
        controller.outputStateStream.listen((value) {
          // 지금 보고 있는 장의 배율만 도구모음 숫자에 반영한다.
          if (id == _current.id) _onPhotoChanged(value);
        });
        return controller;
      });

  PhotoViewController get _photo => _controllerFor(_current.id);

  @override
  void initState() {
    super.initState();
    _scheduleHide();
    widget.source?.changes.addListener(_onSourceChanged);
    // 맨 앞 장에서 열었으면 그 앞(과거 메시지)의 사진을 미리 찾아 둔다(첫 프레임 뒤 — initState
    // 안에서는 setState를 부를 수 없다).
    if (_index <= 1) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_loadOlder());
      });
    }
  }

  @override
  void dispose() {
    widget.source?.changes.removeListener(_onSourceChanged);
    _hideToolbar?.cancel();
    for (final (stream, listener) in _sizeStreams.values) {
      stream.removeListener(listener);
    }
    for (final c in _controllers.values) {
      c.dispose();
    }
    _page.dispose();
    super.dispose();
  }

  /// 방의 메시지가 바뀌면(과거 메시지를 더 불러옴·새 사진·삭제) 목록을 다시 만들고, 지금 보던
  /// 장을 그대로 보여준다 — 앞에 사진이 붙어 번호가 밀렸으면 PageView를 그 번호로 새로 연다.
  void _onSourceChanged() {
    final source = widget.source;
    if (source == null || !mounted) return;
    final next = source.images();
    if (next.isEmpty) return;
    final currentId = _current.id;
    var index = next.indexWhere((v) => v.id == currentId);
    // 보던 장이 지워졌으면 그 자리.
    if (index < 0) index = math.min(_index, next.length - 1);
    setState(() {
      _images = next;
      if (index != _index) {
        _index = index;
        final old = _page;
        _page = PageController(initialPage: index);
        _pageGeneration++;
        WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
      }
    });
  }

  /// 과거 메시지를 불러와 지금 목록보다 앞의 사진을 찾는다. 불러온 묶음에 사진이 없으면 사진이
  /// 나오거나 방의 처음에 닿을 때까지 몇 번 더 불러온다. [thenGoBack]이면 찾은 뒤 한 장 앞으로 간다.
  Future<void> _loadOlder({bool thenGoBack = false}) async {
    final source = widget.source;
    if (source == null || _loadingOlder || !source.hasOlder()) return;
    setState(() => _loadingOlder = true);
    try {
      final firstBefore = _images.first.id;
      for (var i = 0; i < 10 && source.hasOlder(); i++) {
        await source.loadOlder();
        if (!mounted || _images.first.id != firstBefore) break;
      }
    } finally {
      if (mounted) setState(() => _loadingOlder = false);
    }
    if (!thenGoBack || !mounted) return;
    // 앞에 사진이 붙었으면 PageView를 새로 만들었으니 그게 붙은 뒤에 넘어간다.
    await WidgetsBinding.instance.endOfFrame;
    if (mounted && _index > 0 && _page.hasClients) _goto(_index - 1);
  }

  /// 3초 동안 아무 움직임이 없으면 도구모음을 흐린다.
  void _scheduleHide() {
    _hideToolbar?.cancel();
    _hideToolbar = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _toolbarVisible = false);
    });
  }

  void _showToolbar() {
    if (!_toolbarVisible) setState(() => _toolbarVisible = true);
    _scheduleHide();
  }

  void _onPhotoChanged(PhotoViewControllerValue value) {
    if (!mounted) return;
    final scale = value.scale ?? 1;
    final actualSize = _isActualSize(_current.id);
    if ((scale - _scale).abs() > 0.001 || actualSize != _drawnActualSize) {
      setState(() {
        _scale = scale;
        _drawnActualSize = actualSize;
      });
    }
  }

  /// 원본 크기를 알아낸다 — 뷰어가 그릴 때 쓰는 것과 같은 이미지 공급자라 두 번 받지 않는다.
  void _resolveSize(String id, ImageProvider provider) {
    if (_sizeStreams.containsKey(id)) return;
    // 이미 캐시에 있는 이미지면 addListener 안에서 곧바로 불린다 — 그때는 화면을 그리는 도중이라
    // setState를 부를 수 없으니 값만 채우고, 도구모음 숫자는 그 프레임이 끝난 뒤 다시 그린다.
    var synchronous = true;
    void record(Size size) {
      // 움직이는 GIF는 프레임마다 불린다 — 크기는 처음 한 번만 알면 된다.
      if (!mounted || _imageSizes.containsKey(id)) return;
      void apply() {
        _imageSizes[id] = size;
        // PhotoView는 처음 배율을 알림 없이 정하므로 도구모음 숫자는 여기서 맞춰 둔다.
        if (id == _current.id && !size.isEmpty) _scale = _initialScale(id);
      }

      if (!synchronous) return setState(apply);
      apply();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    }

    final stream = provider.resolve(const ImageConfiguration());
    final listener = ImageStreamListener(
      (info, _) => record(
        Size(info.image.width.toDouble(), info.image.height.toDouble()),
      ),
      // 못 읽는 이미지 — 크기를 모르는 채로 두면 PhotoView가 오류 표시를 맡는다.
      onError: (_, _) => record(Size.zero),
    );
    stream.addListener(listener);
    synchronous = false;
    _sizeStreams[id] = (stream, listener);
  }

  /// 뷰어 영역에 이미지가 꼭 맞게(가로나 세로가 꽉 차게) 들어가는 배율. 90°/270° 돌려 놓았으면
  /// 가로·세로를 바꿔서 잰다.
  double? _containedScale(String id, {double rotation = 0}) {
    final image = _imageSizes[id];
    final viewport = _viewport;
    if (image == null || image.isEmpty || viewport == null) return null;
    final quarterTurns = (rotation / (math.pi / 2)).round().abs() % 2 == 1;
    final w = quarterTurns ? image.height : image.width;
    final h = quarterTurns ? image.width : image.height;
    return math.min(viewport.width / w, viewport.height / h);
  }

  /// 처음 열 때의 배율 — 원본이 뷰어보다 크면(100%로 보면 잘려서 확대돼 보이면) 화면에 맞추고,
  /// 작거나 같으면 100% 그대로 둔다(작은 이미지를 억지로 키우면 흐려진다).
  double _initialScale(String id) => math.min(1.0, _containedScale(id) ?? 1.0);

  /// 그 장이 지금 100%(원본 픽셀 크기)이고 90° 단위로만 돌아가 있는지 — 그러면 보간 없이 그린다.
  bool _isActualSize(String id) {
    final value = _controllers[id]?.value;
    final scale = value?.scale ?? _initialScale(id);
    final turns = (value?.rotation ?? 0) / (math.pi / 2);
    return (scale - 1).abs() < 0.001 && (turns - turns.round()).abs() < 0.001;
  }

  bool get _canGoBack =>
      _index > 0 || ((widget.source?.hasOlder() ?? false) && !_loadingOlder);
  bool get _canGoForward => _index < _images.length - 1;

  void _goto(int index) {
    if (index < 0) {
      // 맨 앞 장 — 방에 더 오래된 메시지가 있으면 불러온 뒤 넘어간다.
      unawaited(_loadOlder(thenGoBack: true));
      return;
    }
    if (index >= _images.length) return;
    _page.animateToPage(
      index,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
    );
  }

  void _onPageChanged(int index) {
    setState(() {
      _index = index;
      _scale = _controllerFor(_current.id).scale ?? _initialScale(_current.id);
      _drawnActualSize = _isActualSize(_current.id);
    });
    // 앞쪽 끝에 가까워지면 그 앞(과거 메시지)의 사진을 미리 불러 둔다.
    if (index <= 1) unawaited(_loadOlder());
  }

  /// 키보드 ←/→로 앞뒤 장. 댓글 입력칸에 커서가 있으면 그쪽이 먼저 화살표를 쓴다(글자 사이 이동).
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      if (_canGoBack) _goto(_index - 1);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      if (_canGoForward) _goto(_index + 1);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _zoom(double factor) {
    final next = (_photo.scale ?? _initialScale(_current.id)) * factor;
    _photo.scale = next.clamp(0.05, 10.0);
  }

  /// 배율 숫자를 누르면 원본 크기(100%)로 되돌린다.
  void _resetScale() {
    _photo.position = Offset.zero;
    _photo.scale = 1;
  }

  /// 화면에 맞춤 — 지금 뷰어 창 크기에 맞춰 가로나 세로가 꽉 차게 한다(작은 이미지는 키운다).
  void _fit() {
    final contained = _containedScale(_current.id, rotation: _photo.rotation);
    if (contained == null) return;
    _photo.position = Offset.zero;
    _photo.scale = contained;
  }

  void _rotate() => _photo.rotation = _photo.rotation + math.pi / 2;

  Widget _page0(int index) {
    final image = _images[index];
    final id = image.id;

    Widget viewer(ImageProvider provider) {
      _resolveSize(id, provider);
      // 크기를 알기 전에는 그리지 않는다 — 100%로 먼저 그렸다가 맞춤으로 줄어드는 깜빡임을 막는다.
      if (!_imageSizes.containsKey(id)) {
        return const Center(child: CircularProgressIndicator());
      }
      return PhotoView(
        key: ValueKey(id),
        controller: _controllerFor(id),
        imageProvider: provider,
        initialScale: _initialScale(id),
        minScale: 0.05,
        maxScale: 10.0,
        enableRotation: true,
        // photo_view의 기본값(FilterQuality.none)은 확대·축소를 "가장 가까운 픽셀 고르기"로 해서,
        // 큰 사진을 화면에 맞춰 줄이면 선이 계단처럼 자글자글해진다. medium은 줄일 때 미리 줄여 둔
        // 단계(밉맵)를 섞어 쓰고 키울 때는 부드럽게 보간해서, 몇 배로 줄여도 깨끗하다(이 값이
        // none이 아니면 photo_view가 그 배율의 크기로 직접 그린다). 다만 100%(원본 크기)일 때는
        // 보간할 게 없고, 위치가 반 픽셀 어긋나면 오히려 번져 보이니 원본 픽셀 그대로 그린다.
        filterQuality: _isActualSize(id)
            ? FilterQuality.none
            : FilterQuality.medium,
        backgroundDecoration: const BoxDecoration(color: Colors.black),
        loadingBuilder: (context, event) =>
            const Center(child: CircularProgressIndicator()),
        errorBuilder: (context, error, stackTrace) => const Center(
          child: Icon(Icons.broken_image, color: Colors.white54, size: 48),
        ),
      );
    }

    final bytes =
        image.bytesFuture ??
        (image.loadBytes == null
            ? null
            : _bytes.putIfAbsent(id, image.loadBytes!));
    if (bytes == null) {
      return viewer(CachedNetworkImageProvider(image.url));
    }
    return FutureBuilder<Uint8List>(
      future: bytes,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const Center(
            child: Icon(Icons.broken_image, color: Colors.white54, size: 48),
          );
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        return viewer(MemoryImage(snapshot.data!));
      },
    );
  }

  Widget _arrow(IconData icon, VoidCallback? onTap, {bool busy = false}) =>
      Material(
        color: Colors.white10,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: busy
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: Padding(
                      padding: EdgeInsets.all(3),
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white70,
                      ),
                    ),
                  )
                : Icon(
                    icon,
                    color: onTap == null ? Colors.white24 : Colors.white,
                    size: 22,
                  ),
          ),
        ),
      );

  Widget _toolButton(IconData icon, String tooltip, VoidCallback onTap) =>
      IconButton(
        icon: Icon(icon, color: Colors.white, size: 20),
        tooltip: tooltip,
        onPressed: onTap,
      );

  /// 지금 보이는 장이 딸린 메시지(여러 메시지의 사진을 넘겨볼 때는 장마다 다르다).
  Message? get _message => _current.message ?? widget.message;

  /// 댓글 패널을 열 방 — 지금 보이는 장의 메시지가 있는 방이다. 파일 패널에서 연 뷰어는 여러 방의
  /// 사진을 넘겨 보므로, 처음 받은 방과 다르면 세션의 방 목록에서 그 방을 찾는다.
  Room? get _room {
    final message = _message, room = widget.room;
    if (message == null || room == null || message.roomId == room.id) {
      return room;
    }
    return widget.session?.rooms
        .where((r) => r.id == message.roomId)
        .firstOrNull;
  }

  FileActions? _actions() {
    final session = widget.session;
    final message = _message;
    if (session == null || message == null) return null;
    final image = _current;
    return FileActions(
      session: session,
      message: message,
      url: image.url,
      fileName: image.fileName,
      attachmentId: image.attachmentId,
      attachmentKey: message.attachmentKey,
      attachmentNonce: message.attachmentNonce,
      // 지운 사진은 더 볼 수 없으니 뷰어를 닫는다(말풍선은 서버 알림으로 "삭제된 파일입니다"가 된다).
      onDeleted: () {
        widget.onFileDeleted?.call();
        if (mounted) Navigator.of(context).pop();
      },
    );
  }

  /// 맨 위 흰 줄 — 왼쪽에 뒤로가기·보낸 사람·시각·파일 이름/크기, 오른쪽에 파일 버튼들.
  Widget _topBar(BuildContext context) {
    final message = _message;
    final image = _current;
    final actions = _actions();
    final size = formatFileSize(image.fileSize);
    return Material(
      color: Colors.white,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 6, 8, 6),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back),
                tooltip: '뒤로',
                onPressed: () => Navigator.of(context).pop(),
              ),
              if (message != null) ...[
                CircleAvatar(
                  radius: 16,
                  child: Text(
                    message.senderName.isEmpty
                        ? '?'
                        : message.senderName.substring(0, 1),
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (message != null)
                      Row(
                        children: [
                          Text(
                            message.senderName,
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 13,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _viewerDateTime(message.createdAt),
                            style: TextStyle(
                              color: Colors.grey.shade600,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    Text(
                      size.isEmpty
                          ? image.fileName
                          : '${image.fileName} · $size',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.grey.shade600,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              if (actions != null) ...[
                if (_room != null)
                  IconButton(
                    icon: Icon(
                      Icons.mode_comment_outlined,
                      color: _commentsOpen
                          ? Theme.of(context).colorScheme.primary
                          : null,
                    ),
                    tooltip: '댓글',
                    onPressed: () =>
                        setState(() => _commentsOpen = !_commentsOpen),
                  ),
                IconButton(
                  icon: const Icon(Icons.print_outlined),
                  tooltip: '인쇄',
                  onPressed: () => actions.printImage(context),
                ),
                IconButton(
                  icon: const Icon(Icons.download_outlined),
                  tooltip: '다운로드',
                  onPressed: () => actions.download(context),
                ),
                IconButton(
                  icon: const Icon(Icons.more_horiz),
                  tooltip: '파일 전달',
                  onPressed: () => actions.forward(context),
                ),
                // 올린 본인과 팀 관리자에게만 — 파일만 지우고 메시지와 댓글은 남는다.
                if (actions.canDelete)
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    tooltip: '삭제',
                    onPressed: () => actions.deleteFile(context),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final many = _images.length > 1 || (widget.source?.hasOlder() ?? false);
    final message = _message;
    final session = widget.session;
    final room = _room;
    return Scaffold(
      backgroundColor: Colors.black,
      // 키보드 ←/→ — 뷰어가 열리면 바로 받도록 포커스를 갖는다(버튼을 누른 뒤에도 그 버튼에서
      // 여기까지 올라온다).
      body: Focus(
        autofocus: true,
        onKeyEvent: _onKey,
        child: Column(
          children: [
            _topBar(context),
            Expanded(
              child: Row(
                children: [
                  Expanded(child: _viewerArea(context, many)),
                  // 새 컨트롤러를 만들지 않는 조회를 쓴다 — 보는 도중 방이 삭제·강퇴로 사라지면 댓글 칸만
                  // 닫히고, 다시 그릴 때 그 방의 컨트롤러를 되살려 대화 기록을 받아오지 않게.
                  if (_commentsOpen &&
                      message != null &&
                      session != null &&
                      room != null &&
                      session.existingControllerFor(room.id) != null)
                    SizedBox(
                      width: 380,
                      child: Material(
                        color: Theme.of(context).colorScheme.surface,
                        // 장을 넘기면 그 장의 메시지 댓글로 바뀐다.
                        child: MessageThreadScreen(
                          key: ValueKey('comments-${message.id}'),
                          session: session,
                          room: room,
                          message: message,
                          controller: session.existingControllerFor(room.id)!,
                          asPanel: true,
                          onClose: () => setState(() => _commentsOpen = false),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 이미지와 그 위에 얹히는 것들(쪽 번호·화살표·도구모음).
  Widget _viewerArea(BuildContext context, bool many) {
    return MouseRegion(
      onHover: (_) => _showToolbar(),
      child: Stack(
        children: [
          Positioned.fill(
            child: LayoutBuilder(
              builder: (context, constraints) {
                // "화면에 맞춤"과 처음 배율은 이미지가 그려지는 이 자리의 크기로 잰다
                // (댓글 패널을 열면 좁아진다).
                _viewport = constraints.biggest;
                return PageView.builder(
                  key: ValueKey(_pageGeneration),
                  controller: _page,
                  onPageChanged: _onPageChanged,
                  physics: _images.length > 1
                      ? const PageScrollPhysics()
                      : const NeverScrollableScrollPhysics(),
                  itemCount: _images.length,
                  itemBuilder: (context, i) => _page0(i),
                );
              },
            ),
          ),
          // 왼쪽 위: 몇 번째인지(한 장이면 "1 / 1").
          Positioned(
            left: 12,
            top: 12,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.photo_library_outlined,
                    color: Colors.white70,
                    size: 16,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${_index + 1} / ${_images.length}',
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  ),
                ],
              ),
            ),
          ),
          if (many) ...[
            Positioned(
              left: 12,
              top: 0,
              bottom: 0,
              child: Center(
                child: _arrow(
                  Icons.arrow_back,
                  _canGoBack ? () => _goto(_index - 1) : null,
                  busy: _loadingOlder && _index == 0,
                ),
              ),
            ),
            Positioned(
              right: 12,
              top: 0,
              bottom: 0,
              child: Center(
                child: _arrow(
                  Icons.arrow_forward,
                  _canGoForward ? () => _goto(_index + 1) : null,
                ),
              ),
            ),
          ],
          // 아래 도구모음 — 마우스를 올렸을 때만 보인다.
          Positioned(
            left: 0,
            right: 0,
            bottom: 24,
            child: Center(
              child: MouseRegion(
                onEnter: (_) => _showToolbar(),
                onHover: (_) => _showToolbar(),
                child: AnimatedOpacity(
                  opacity: _toolbarVisible ? 1 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.75),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _toolButton(
                          Icons.zoom_out,
                          '축소',
                          () => _zoom(1 / 1.25),
                        ),
                        TextButton(
                          onPressed: _resetScale,
                          child: Text(
                            '${(_scale * 100).round()}%',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        _toolButton(Icons.zoom_in, '확대', () => _zoom(1.25)),
                        _toolButton(Icons.fit_screen, '화면에 맞춤', _fit),
                        _toolButton(Icons.rotate_right, '회전', _rotate),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
