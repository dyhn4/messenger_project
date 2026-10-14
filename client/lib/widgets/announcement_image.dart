import 'package:flutter/material.dart';

import '../models/announcement.dart';
import '../services/session.dart';
import 'retrying_network_image.dart';

/// 공지에 딸린 사진 한 장(이미지 메시지를 공지로 등록했을 때) — 축소본이 있으면 그걸 보여주고, 누르면 원본을
/// 크게 띄운다. 배너(펼친 모양)와 공지 상세가 함께 쓴다.
class AnnouncementImage extends StatelessWidget {
  final Session session;
  final Announcement announcement;
  final double maxHeight;
  final double maxWidth;

  const AnnouncementImage({
    super.key,
    required this.session,
    required this.announcement,
    this.maxHeight = 120,
    this.maxWidth = 240,
  });

  @override
  Widget build(BuildContext context) {
    final full = session.resolveUrl(announcement.imageUrl ?? '');
    final preview = session.resolveUrl(
      announcement.imageThumbnailUrl ?? announcement.imageUrl ?? '',
    );
    final placeholder = SizedBox(
      width: maxHeight,
      height: maxHeight * 0.75,
      child: const Icon(Icons.image_outlined),
    );
    return GestureDetector(
      key: const ValueKey('announcement-image'),
      onTap: () => showDialog<void>(
        context: context,
        builder: (dialogContext) => Dialog(
          insetPadding: const EdgeInsets.all(16),
          child: Stack(
            children: [
              InteractiveViewer(
                child: RetryingNetworkImage(
                  imageUrl: full,
                  fit: BoxFit.contain,
                  placeholder: (_, _) => placeholder,
                  errorWidget: (_, _, _) => placeholder,
                ),
              ),
              Positioned(
                top: 4,
                right: 4,
                child: IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: '닫기',
                  onPressed: () => Navigator.of(dialogContext).pop(),
                ),
              ),
            ],
          ),
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight, maxWidth: maxWidth),
          child: RetryingNetworkImage(
            imageUrl: preview,
            fit: BoxFit.contain,
            alignment: Alignment.centerLeft,
            placeholder: (_, _) => placeholder,
            errorWidget: (_, _, _) => placeholder,
          ),
        ),
      ),
    );
  }
}
