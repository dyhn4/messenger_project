import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:photo_view/photo_view.dart';

/// 이미지 확대/축소 뷰어. 채팅 버블에서 이미지를 탭하면 열립니다.
class ImageViewerScreen extends StatelessWidget {
  final String imageUrl;

  /// 비밀 대화 이미지는 서버가 암호화된 바이트만 갖고 있어서, 복호화한 바이트를 여기로 넘겨받는다
  /// (다시 네트워크에서 받아 캐시 이미지로 그리면 안 됨 — 그 URL 응답은 여전히 암호문이다).
  /// 버블 미리보기는 이미 축소 썸네일로 다운로드해둔 상태라, 원본은 이 화면을 열 때(탭하는
  /// 시점)에야 비로소 다운로드+복호화하는 게 자연스럽다 — 그래서 이미 완료된 값이 아니라
  /// Future로 받아 로딩 중엔 이 화면 자체에서 스피너를 보여준다.
  final Future<Uint8List>? imageBytesFuture;
  const ImageViewerScreen({
    super.key,
    required this.imageUrl,
    this.imageBytesFuture,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: imageBytesFuture == null
          ? PhotoView(
              imageProvider: CachedNetworkImageProvider(imageUrl),
              minScale: PhotoViewComputedScale.contained,
              maxScale: PhotoViewComputedScale.covered * 3,
              loadingBuilder: (context, event) =>
                  const Center(child: CircularProgressIndicator()),
              errorBuilder: (context, error, stackTrace) => const Center(
                child: Icon(
                  Icons.broken_image,
                  color: Colors.white54,
                  size: 48,
                ),
              ),
            )
          : FutureBuilder<Uint8List>(
              future: imageBytesFuture,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return const Center(
                    child: Icon(
                      Icons.broken_image,
                      color: Colors.white54,
                      size: 48,
                    ),
                  );
                }
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                return PhotoView(
                  imageProvider: MemoryImage(snapshot.data!),
                  minScale: PhotoViewComputedScale.contained,
                  maxScale: PhotoViewComputedScale.covered * 3,
                  errorBuilder: (context, error, stackTrace) => const Center(
                    child: Icon(
                      Icons.broken_image,
                      color: Colors.white54,
                      size: 48,
                    ),
                  ),
                );
              },
            ),
    );
  }
}
