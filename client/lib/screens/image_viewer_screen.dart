import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:photo_view/photo_view.dart';

/// 이미지 확대/축소 뷰어. 채팅 버블에서 이미지를 탭하면 열립니다.
class ImageViewerScreen extends StatelessWidget {
  final String imageUrl;

  /// 비밀 대화 이미지는 서버가 암호화된 바이트만 갖고 있어서, 이미 복호화해둔 바이트를 여기로
  /// 그대로 넘겨받는다(다시 네트워크에서 받아 캐시 이미지로 그리면 안 됨 — 그 URL 응답은 여전히
  /// 암호문이다).
  final Uint8List? imageBytes;
  const ImageViewerScreen({super.key, required this.imageUrl, this.imageBytes});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: PhotoView(
        imageProvider: imageBytes != null
            ? MemoryImage(imageBytes!)
            : CachedNetworkImageProvider(imageUrl),
        minScale: PhotoViewComputedScale.contained,
        maxScale: PhotoViewComputedScale.covered * 3,
        loadingBuilder: (context, event) =>
            const Center(child: CircularProgressIndicator()),
        errorBuilder: (context, error, stackTrace) => const Center(
          child: Icon(Icons.broken_image, color: Colors.white54, size: 48),
        ),
      ),
    );
  }
}
