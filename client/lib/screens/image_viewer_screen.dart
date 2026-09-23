import 'dart:async';
import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:photo_view/photo_view.dart';

import '../models/message.dart';
import '../services/session.dart';
import '../widgets/file_actions.dart';
import '../models/room.dart';
import 'message_thread_screen.dart';

/// 뷰어에서 넘겨볼 이미지 한 장. 비밀 대화 이미지는 서버가 암호문만 갖고 있어서 복호화한
/// 바이트를 [bytesFuture]로 받는다(그 URL을 그대로 받아 그리면 암호문이 그려진다).
class ViewerImage {
  final String url;
  final Future<Uint8List>? bytesFuture;

  /// 상단 바에 이름/크기를 쓰고, 다운로드·전달·인쇄가 쓴다.
  final String fileName;
  final int? fileSize;
  const ViewerImage({
    required this.url,
    this.bytesFuture,
    this.fileName = 'image.png',
    this.fileSize,
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
/// 한 말풍선에 여러 장이 있으면 좌우 화살표로 넘기고, 왼쪽 위에 "2 / 5"로 몇 번째인지
/// 보여줍니다. 배율은 100%(원본 픽셀 크기)에서 시작하고, 아래 도구모음은 마우스를 올렸을
/// 때만 뜹니다 — 배율 숫자를 누르면 다시 100%로 돌아옵니다.
class ImageViewerScreen extends StatefulWidget {
  final List<ViewerImage> images;
  final int initialIndex;

  /// 상단 바(보낸 사람·시각)와 댓글·전달에 필요 — 없으면 그 버튼들은 안 보인다.
  final Session? session;
  final Message? message;

  /// 댓글 패널을 열려면 방도 있어야 한다(그 방의 컨트롤러로 댓글을 읽고 쓴다).
  final Room? room;

  const ImageViewerScreen({
    super.key,
    required this.images,
    this.initialIndex = 0,
    this.session,
    this.message,
    this.room,
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
       initialIndex = 0;

  @override
  State<ImageViewerScreen> createState() => _ImageViewerScreenState();
}

class _ImageViewerScreenState extends State<ImageViewerScreen> {
  late final PageController _page = PageController(
    initialPage: widget.initialIndex,
  );
  late int _index = widget.initialIndex;

  /// 지금 보고 있는 장의 확대/회전 상태. 장을 넘기면 새로 만든다(각 장이 따로 기억하지 않음).
  PhotoViewController _photo = PhotoViewController();
  double _scale = 1;

  /// 도구모음은 열리자마자 잠깐 보여주고 3초 뒤 흐려진다 — 마우스를 창 위로 움직이면 다시 뜬다.
  bool _toolbarVisible = true;
  Timer? _hideToolbar;

  /// 오른쪽 댓글 패널이 열려 있는지.
  bool _commentsOpen = false;

  @override
  void initState() {
    super.initState();
    _photo.outputStateStream.listen(_onPhotoChanged);
    _scheduleHide();
  }

  @override
  void dispose() {
    _hideToolbar?.cancel();
    _page.dispose();
    _photo.dispose();
    super.dispose();
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
    final scale = value.scale ?? 1;
    if (mounted && (scale - _scale).abs() > 0.001) {
      setState(() => _scale = scale);
    }
  }

  void _goto(int index) {
    if (index < 0 || index >= widget.images.length) return;
    _page.animateToPage(
      index,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
    );
  }

  void _onPageChanged(int index) {
    final old = _photo;
    setState(() {
      _index = index;
      _photo = PhotoViewController();
      _scale = 1;
    });
    _photo.outputStateStream.listen(_onPhotoChanged);
    old.dispose();
  }

  void _zoom(double factor) {
    final next = (_photo.scale ?? 1) * factor;
    _photo.scale = next.clamp(0.1, 10.0);
  }

  /// 배율 숫자를 누르면 원본 크기(100%)로 되돌린다.
  void _resetScale() => _photo.scale = 1;

  /// 화면에 맞춤 — 긴 변이 화면에 들어오도록 줄인다.
  void _fit() {
    _photo.scale = null; // null이면 PhotoView가 contained 배율로 되돌린다.
    setState(() => _scale = 1);
  }

  void _rotate() => _photo.rotation = _photo.rotation + 1.5707963267948966;

  Widget _page0(ViewerImage image) {
    Widget viewer(ImageProvider provider) => PhotoView(
      key: ValueKey(image.url),
      controller: _photo,
      imageProvider: provider,
      // 100%(원본 픽셀 크기)에서 시작한다 — 아래 도구모음의 "화면 맞춤"으로 줄일 수 있다.
      initialScale: 1.0,
      minScale: 0.1,
      maxScale: 10.0,
      enableRotation: true,
      backgroundDecoration: const BoxDecoration(color: Colors.black),
      loadingBuilder: (context, event) =>
          const Center(child: CircularProgressIndicator()),
      errorBuilder: (context, error, stackTrace) => const Center(
        child: Icon(Icons.broken_image, color: Colors.white54, size: 48),
      ),
    );

    if (image.bytesFuture == null) {
      return viewer(CachedNetworkImageProvider(image.url));
    }
    return FutureBuilder<Uint8List>(
      future: image.bytesFuture,
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

  Widget _arrow(IconData icon, VoidCallback? onTap) => Material(
    color: Colors.white10,
    shape: const CircleBorder(),
    child: InkWell(
      customBorder: const CircleBorder(),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Icon(
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

  FileActions? _actions() {
    final session = widget.session;
    final message = widget.message;
    if (session == null || message == null) return null;
    final image = widget.images[_index];
    return FileActions(
      session: session,
      message: message,
      url: image.url,
      fileName: image.fileName,
      attachmentKey: message.attachmentKey,
      attachmentNonce: message.attachmentNonce,
    );
  }

  /// 맨 위 흰 줄 — 왼쪽에 뒤로가기·보낸 사람·시각·파일 이름/크기, 오른쪽에 파일 버튼들.
  Widget _topBar(BuildContext context) {
    final message = widget.message;
    final image = widget.images[_index];
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
                if (widget.room != null)
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
              ],
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final many = widget.images.length > 1;
    final message = widget.message;
    final session = widget.session;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Column(
        children: [
          _topBar(context),
          Expanded(
            child: Row(
              children: [
                Expanded(child: _viewerArea(context, many)),
                if (_commentsOpen &&
                    message != null &&
                    session != null &&
                    widget.room != null)
                  SizedBox(
                    width: 380,
                    child: Material(
                      color: Theme.of(context).colorScheme.surface,
                      child: MessageThreadScreen(
                        session: session,
                        room: widget.room!,
                        message: message,
                        controller: session.controllerFor(widget.room!),
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
    );
  }

  /// 이미지와 그 위에 얹히는 것들(쪽 번호·화살표·도구모음).
  Widget _viewerArea(BuildContext context, bool many) {
    return MouseRegion(
      onHover: (_) => _showToolbar(),
      child: Stack(
        children: [
          Positioned.fill(
            child: PageView.builder(
              controller: _page,
              onPageChanged: _onPageChanged,
              physics: many
                  ? const PageScrollPhysics()
                  : const NeverScrollableScrollPhysics(),
              itemCount: widget.images.length,
              itemBuilder: (context, i) => _page0(widget.images[i]),
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
                    '${_index + 1} / ${widget.images.length}',
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
                  _index == 0 ? null : () => _goto(_index - 1),
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
                  _index == widget.images.length - 1
                      ? null
                      : () => _goto(_index + 1),
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
