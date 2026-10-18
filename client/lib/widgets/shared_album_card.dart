import 'package:flutter/material.dart';

import '../models/album.dart';
import '../services/session.dart';
import 'albums_panel.dart' show openSharedAlbum;
import '../l10n/tr.dart';

/// 앨범 카드의 강조색(왼쪽 막대·아이콘) — 잔디 앨범 카드의 분홍.
const albumAccentColor = Color(0xFFEC5A8C);

/// 앨범 카드 — 왼쪽 분홍 막대, 앨범 아이콘(또는 대표 이미지), 제목(+ 아래 한 줄). "앨범 공유" 창의 "공유 앨범"과
/// 공유된 메시지의 카드가 같이 쓴다. [onTap]이 없으면 누를 수 없다.
class AlbumShareCard extends StatelessWidget {
  final String title;
  final String? subtitle;

  /// 대표 이미지의 절대 주소 — 없으면 앨범 아이콘.
  final String? coverUrl;
  final VoidCallback? onTap;

  /// 지워진 앨범 — 제목을 흐리게, 아이콘을 회색으로.
  final bool dimmed;
  final double maxWidth;

  const AlbumShareCard({
    super.key,
    required this.title,
    this.subtitle,
    this.coverUrl,
    this.onTap,
    this.dimmed = false,
    this.maxWidth = 360,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final accent = dimmed ? theme.hintColor : albumAccentColor;
    final cover = coverUrl;
    final icon = Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: accent.withValues(alpha: dark ? 0.22 : 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(Icons.photo_library_rounded, size: 22, color: accent),
    );
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Material(
        color: dark ? Colors.white.withValues(alpha: 0.06) : Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: theme.dividerColor.withValues(alpha: 0.6)),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(width: 4, color: accent),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(10, 10, 12, 10),
                    child: Row(
                      children: [
                        if (cover == null)
                          icon
                        else
                          ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: SizedBox(
                              width: 40,
                              height: 40,
                              child: Image.network(
                                cover,
                                fit: BoxFit.cover,
                                cacheWidth: 120,
                                errorBuilder: (context, error, stack) => icon,
                              ),
                            ),
                          ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: dimmed ? theme.hintColor : null,
                                ),
                              ),
                              if (subtitle != null) ...[
                                const SizedBox(height: 2),
                                Text(
                                  subtitle!,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: theme.hintColor,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 공유된 앨범 메시지의 아래쪽 — 구분선, "{팀 이름}에서 공유된 앨범입니다."(회색), 파란 "앨범 보기", 앨범 카드.
/// 메시지 본문(사람이 쓴 글)은 말풍선이 위에 그린다. 앨범이 지워졌으면 카드만 흐리게 남고 열 수 없다.
class SharedAlbumSection extends StatelessWidget {
  final Session session;
  final SharedAlbum album;
  const SharedAlbumSection({
    super.key,
    required this.session,
    required this.album,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final id = album.id;
    final open = id == null
        ? null
        : () => openSharedAlbum(context, session, id);
    final team = album.teamName;
    // 구분선은 가로를 다 채우려 해서, 폭을 카드에 맞춰 두지 않으면 PC 말풍선이 창 끝까지 늘어난다.
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 360),
      child: _buildColumn(context, theme, id, open, team),
    );
  }

  Widget _buildColumn(
    BuildContext context,
    ThemeData theme,
    String? id,
    VoidCallback? open,
    String? team,
  ) {
    return Column(
      key: const ValueKey('shared-album-section'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        const Divider(height: 1),
        const SizedBox(height: 8),
        Text(
          team == null
              ? tr('공유된 앨범입니다.')
              : tr('{team}에서 공유된 앨범입니다.', {'team': team}),
          style: TextStyle(fontSize: 12, color: theme.hintColor),
        ),
        if (open != null) ...[
          const SizedBox(height: 2),
          InkWell(
            key: const ValueKey('shared-album-open'),
            onTap: open,
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 2),
              child: Text(
                tr('앨범 보기'),
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF2F80ED),
                ),
              ),
            ),
          ),
        ],
        const SizedBox(height: 6),
        AlbumShareCard(
          key: const ValueKey('shared-album-card'),
          title: album.title,
          subtitle: id == null ? tr('삭제된 앨범입니다.') : null,
          dimmed: id == null,
          onTap: open,
        ),
      ],
    );
  }
}
