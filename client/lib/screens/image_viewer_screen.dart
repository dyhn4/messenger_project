import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:photo_view/photo_view.dart';

/// 이미지 확대/축소 뷰어. 채팅 버블에서 이미지를 탭하면 열립니다.
class ImageViewerScreen extends StatelessWidget {
  final String imageUrl;
  const ImageViewerScreen({super.key, required this.imageUrl});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: PhotoView(
        imageProvider: CachedNetworkImageProvider(imageUrl),
        minScale: PhotoViewComputedScale.contained,
        maxScale: PhotoViewComputedScale.covered * 3,
        loadingBuilder: (context, event) => const Center(child: CircularProgressIndicator()),
        errorBuilder: (context, error, stackTrace) =>
            const Center(child: Icon(Icons.broken_image, color: Colors.white54, size: 48)),
      ),
    );
  }
}
