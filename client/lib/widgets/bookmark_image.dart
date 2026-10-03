import 'package:flutter/material.dart';

import '../services/session.dart';
import 'external_image.dart';

/// 북마크 이미지 한 장(정사각형) — 없으면 링크 아이콘 자리표시. 직접 올린 사진(서명된 /files/… 링크)은 우리 서버에서,
/// 자동으로 가져온 외부 사이트 이미지는 [ExternalImage]로 받는다(앱의 전역 인증서 핀닝이 공인 인증서 사이트 이미지를
/// 막기 때문 — external_image.dart 참고).
class BookmarkImage extends StatelessWidget {
  final Session session;
  final String? imageUrl;
  final double size;

  const BookmarkImage({
    super.key,
    required this.session,
    required this.imageUrl,
    this.size = 56,
  });

  bool get _isExternal {
    final url = imageUrl ?? '';
    return url.startsWith('http://') || url.startsWith('https://');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final placeholder = Container(
      width: size,
      height: size,
      color: theme.colorScheme.surfaceContainerHighest,
      child: Icon(
        Icons.link_rounded,
        size: size * 0.45,
        color: theme.hintColor,
      ),
    );
    final url = imageUrl;
    final Widget child;
    if (url == null || url.isEmpty) {
      child = placeholder;
    } else if (_isExternal && !_isOurServer(url)) {
      child = ExternalImage(
        url: url,
        width: size,
        height: size,
        placeholder: placeholder,
      );
    } else {
      child = Image.network(
        session.resolveUrl(url),
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => placeholder,
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(width: size, height: size, child: child),
    );
  }

  /// 서버가 내려준 절대 주소(드문 경우)면 외부 이미지로 보지 않는다.
  bool _isOurServer(String url) {
    final base = session.serverUrl;
    return base != null && base.isNotEmpty && url.startsWith(base);
  }
}
